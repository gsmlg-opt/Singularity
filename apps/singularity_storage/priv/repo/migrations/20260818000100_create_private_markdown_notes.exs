defmodule Singularity.Storage.Migrations.CreatePrivateMarkdownNotes do
  use Ecto.Migration

  @note_tables ~w(note_versions note_conflicts note_search_documents note_mutation_receipts)

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    create_aggregate_tables()
    create_note_tables()
    create_deferred_constraints()
    create_note_version_aggregate_guard()
    create_note_aggregate_reference_guards()
    create_indexes()
    create_rls_and_grants()
    create_capability_reconciler()

    execute("SELECT core.reconcile_note_capabilities()")
    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    LOCK TABLE
      content.note_search_documents,
      content.note_mutation_receipts,
      content.note_conflicts,
      content.note_versions,
      content.resources
    IN ACCESS EXCLUSIVE MODE
    """)

    execute("""
    DO $guard$
    BEGIN
      IF EXISTS (SELECT 1 FROM content.resources WHERE kind = 'note')
         OR EXISTS (SELECT 1 FROM content.note_versions)
         OR EXISTS (SELECT 1 FROM content.note_conflicts) THEN
        RAISE EXCEPTION
          'cannot downgrade private notes while canonical note data exists';
      END IF;
    END
    $guard$
    """)

    remove_note_capabilities()

    execute(
      "REVOKE EXECUTE ON FUNCTION core.reconcile_note_capabilities() FROM singularity_migration"
    )

    execute("DROP FUNCTION core.reconcile_note_capabilities()")
    execute("REVOKE USAGE ON SCHEMA core FROM singularity_migration")

    execute("DROP TABLE content.note_search_documents")
    execute("DROP TABLE content.note_mutation_receipts")
    execute("DROP TABLE content.note_conflicts")

    execute("DROP TRIGGER resources_note_kind_immutable ON content.resources")

    execute("DROP TRIGGER resource_versions_note_identity_immutable ON content.resource_versions")

    execute("DROP FUNCTION content.enforce_note_resource_kind_update()")
    execute("DROP FUNCTION content.enforce_note_resource_version_update()")

    execute("ALTER TABLE content.resources DROP CONSTRAINT resources_note_version_head_fkey")
    execute("DROP TABLE content.note_versions")
    execute("DROP FUNCTION content.enforce_note_version_aggregate()")

    execute("DROP INDEX content.resources_note_trash")
    execute("DROP INDEX content.resource_versions_note_history")

    execute("""
    ALTER TABLE content.resource_versions
      DROP CONSTRAINT resource_versions_resource_classification_fkey,
      DROP CONSTRAINT resource_versions_identity_aggregate_key
    """)

    execute("""
    ALTER TABLE content.resources
      DROP CONSTRAINT resources_head_vault_classification_key,
      DROP CONSTRAINT resources_id_vault_classification_key,
      DROP CONSTRAINT resources_note_head_check,
      DROP CONSTRAINT resources_kind_check,
      DROP COLUMN current_version_id,
      DROP COLUMN kind
    """)

    execute("SET LOCAL ROLE NONE")
  end

  defp create_aggregate_tables do
    execute("""
    ALTER TABLE content.resources
      ADD COLUMN kind text NOT NULL DEFAULT 'asset',
      ADD COLUMN current_version_id uuid,
      ADD CONSTRAINT resources_kind_check CHECK (kind IN ('asset', 'note')),
      ADD CONSTRAINT resources_note_head_check
        CHECK (kind <> 'note' OR current_version_id IS NOT NULL),
      ADD CONSTRAINT resources_id_vault_classification_key
        UNIQUE (id, vault_id, classification),
      ADD CONSTRAINT resources_head_vault_classification_key
        UNIQUE (id, current_version_id, vault_id, classification)
    """)

    execute("""
    ALTER TABLE content.resource_versions
      ADD CONSTRAINT resource_versions_identity_aggregate_key
        UNIQUE (id, resource_id, vault_id, classification),
      ADD CONSTRAINT resource_versions_resource_classification_fkey
        FOREIGN KEY (resource_id, vault_id, classification)
        REFERENCES content.resources(id, vault_id, classification)
    """)
  end

  defp create_note_tables do
    execute("""
    CREATE TABLE content.note_versions (
      resource_version_id uuid PRIMARY KEY,
      resource_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      title text NOT NULL,
      markdown text NOT NULL,
      created_by_principal_id uuid NOT NULL,
      parent_version_id uuid,
      merge_parent_version_id uuid,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT note_versions_private_check
        CHECK (classification = 'private'),
      CONSTRAINT note_versions_title_check
        CHECK (btrim(title) <> '' AND octet_length(title) <= 255),
      CONSTRAINT note_versions_markdown_check
        CHECK (octet_length(markdown) <= 1048576),
      CONSTRAINT note_versions_parent_shape_check
        CHECK (parent_version_id IS NOT NULL OR merge_parent_version_id IS NULL),
      CONSTRAINT note_versions_merge_parents_distinct_check
        CHECK (merge_parent_version_id IS NULL OR merge_parent_version_id <> parent_version_id),
      CONSTRAINT note_versions_identity_aggregate_key
        UNIQUE (resource_version_id, resource_id, vault_id, classification),
      CONSTRAINT note_versions_resource_version_fkey
        FOREIGN KEY (resource_version_id, resource_id, vault_id, classification)
        REFERENCES content.resource_versions(id, resource_id, vault_id, classification),
      CONSTRAINT note_versions_created_by_principal_fkey
        FOREIGN KEY (created_by_principal_id)
        REFERENCES identity.principals(id)
    )
    """)

    execute("""
    CREATE TABLE content.note_conflicts (
      id uuid PRIMARY KEY,
      resource_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      base_version_id uuid NOT NULL,
      canonical_version_id uuid NOT NULL,
      competing_version_id uuid NOT NULL,
      state text NOT NULL,
      resolution_version_id uuid,
      created_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      resolved_at timestamptz(6),
      CONSTRAINT note_conflicts_private_check
        CHECK (classification = 'private'),
      CONSTRAINT note_conflicts_state_check
        CHECK (state IN ('open', 'resolved')),
      CONSTRAINT note_conflicts_lineage_distinct_check
        CHECK (
          base_version_id <> canonical_version_id
          AND base_version_id <> competing_version_id
          AND canonical_version_id <> competing_version_id
        ),
      CONSTRAINT note_conflicts_resolution_shape_check
        CHECK (
          (state = 'open' AND resolution_version_id IS NULL AND resolved_at IS NULL)
          OR
          (state = 'resolved' AND resolution_version_id IS NOT NULL AND resolved_at IS NOT NULL)
        ),
      CONSTRAINT note_conflicts_resolution_distinct_check
        CHECK (
          resolution_version_id IS NULL
          OR (
            resolution_version_id <> base_version_id
            AND resolution_version_id <> canonical_version_id
            AND resolution_version_id <> competing_version_id
          )
        )
    )
    """)

    execute("""
    CREATE TABLE content.note_search_documents (
      resource_id uuid PRIMARY KEY,
      resource_version_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      title text NOT NULL,
      markdown text NOT NULL,
      head_inserted_at timestamptz(6) NOT NULL,
      search_vector tsvector GENERATED ALWAYS AS (
        to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(markdown, ''))
      ) STORED,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT note_search_documents_private_check
        CHECK (classification = 'private'),
      CONSTRAINT note_search_documents_title_check
        CHECK (btrim(title) <> '' AND octet_length(title) <= 255),
      CONSTRAINT note_search_documents_markdown_check
        CHECK (octet_length(markdown) <= 1048576),
      CONSTRAINT note_search_documents_resource_head_fkey
        FOREIGN KEY (resource_id, resource_version_id, vault_id, classification)
        REFERENCES content.resources(id, current_version_id, vault_id, classification),
      CONSTRAINT note_search_documents_note_version_fkey
        FOREIGN KEY (resource_version_id, resource_id, vault_id, classification)
        REFERENCES content.note_versions(resource_version_id, resource_id, vault_id, classification)
    )
    """)

    execute("""
    CREATE TABLE content.note_mutation_receipts (
      vault_id uuid NOT NULL,
      principal_id uuid NOT NULL,
      mutation_id uuid NOT NULL,
      operation text NOT NULL,
      request_fingerprint bytea NOT NULL,
      state text NOT NULL,
      outcome text,
      resource_id uuid NOT NULL,
      version_id uuid,
      conflict_id uuid,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT note_mutation_receipts_pkey
        PRIMARY KEY (vault_id, principal_id, mutation_id),
      CONSTRAINT note_mutation_receipts_operation_check
        CHECK (operation IN ('create', 'save', 'merge', 'tombstone', 'restore')),
      CONSTRAINT note_mutation_receipts_fingerprint_check
        CHECK (octet_length(request_fingerprint) = 32),
      CONSTRAINT note_mutation_receipts_state_check
        CHECK (state IN ('pending', 'completed')),
      CONSTRAINT note_mutation_receipts_result_shape_check
        CHECK (
          (
            state = 'pending'
            AND outcome IS NULL
            AND version_id IS NULL
            AND conflict_id IS NULL
          )
          OR
          (
            state = 'completed'
            AND (
              (
                outcome = 'saved'
                AND operation IN ('create', 'save', 'merge')
                AND resource_id IS NOT NULL
                AND version_id IS NOT NULL
                AND conflict_id IS NULL
              )
              OR
              (
                outcome = 'conflict'
                AND operation = 'save'
                AND resource_id IS NOT NULL
                AND version_id IS NOT NULL
                AND conflict_id IS NOT NULL
              )
              OR
              (
                outcome = 'tombstoned'
                AND operation = 'tombstone'
                AND resource_id IS NOT NULL
                AND version_id IS NULL
                AND conflict_id IS NULL
              )
              OR
              (
                outcome = 'restored'
                AND operation = 'restore'
                AND resource_id IS NOT NULL
                AND version_id IS NOT NULL
                AND conflict_id IS NULL
              )
            )
          )
        ),
      CONSTRAINT note_mutation_receipts_membership_fkey
        FOREIGN KEY (principal_id, vault_id)
        REFERENCES core.vault_members(principal_id, vault_id)
        MATCH FULL
    )
    """)
  end

  defp create_deferred_constraints do
    execute("""
    ALTER TABLE content.note_versions
      ADD CONSTRAINT note_versions_parent_fkey
        FOREIGN KEY (parent_version_id, resource_id, vault_id, classification)
        REFERENCES content.note_versions(resource_version_id, resource_id, vault_id, classification)
        DEFERRABLE INITIALLY DEFERRED,
      ADD CONSTRAINT note_versions_merge_parent_fkey
        FOREIGN KEY (merge_parent_version_id, resource_id, vault_id, classification)
        REFERENCES content.note_versions(resource_version_id, resource_id, vault_id, classification)
        DEFERRABLE INITIALLY DEFERRED
    """)

    execute("""
    ALTER TABLE content.note_conflicts
      ADD CONSTRAINT note_conflicts_base_version_fkey
        FOREIGN KEY (base_version_id, resource_id, vault_id, classification)
        REFERENCES content.note_versions(resource_version_id, resource_id, vault_id, classification)
        DEFERRABLE INITIALLY DEFERRED,
      ADD CONSTRAINT note_conflicts_canonical_version_fkey
        FOREIGN KEY (canonical_version_id, resource_id, vault_id, classification)
        REFERENCES content.note_versions(resource_version_id, resource_id, vault_id, classification)
        DEFERRABLE INITIALLY DEFERRED,
      ADD CONSTRAINT note_conflicts_competing_version_fkey
        FOREIGN KEY (competing_version_id, resource_id, vault_id, classification)
        REFERENCES content.note_versions(resource_version_id, resource_id, vault_id, classification)
        DEFERRABLE INITIALLY DEFERRED,
      ADD CONSTRAINT note_conflicts_resolution_version_fkey
        FOREIGN KEY (resolution_version_id, resource_id, vault_id, classification)
        REFERENCES content.note_versions(resource_version_id, resource_id, vault_id, classification)
        DEFERRABLE INITIALLY DEFERRED
    """)

    execute("""
    ALTER TABLE content.resources
      ADD CONSTRAINT resources_note_version_head_fkey
        FOREIGN KEY (current_version_id, id, vault_id, classification)
        REFERENCES content.note_versions(resource_version_id, resource_id, vault_id, classification)
        DEFERRABLE INITIALLY DEFERRED
    """)
  end

  defp create_indexes do
    execute("""
    CREATE INDEX resource_versions_note_history
      ON content.resource_versions(vault_id, resource_id, revision DESC, id)
    """)

    execute("""
    CREATE INDEX resources_note_trash
      ON content.resources(vault_id, deleted_at DESC, id)
      WHERE kind = 'note' AND deleted_at IS NOT NULL
    """)

    execute("CREATE INDEX note_conflicts_resource_idx ON content.note_conflicts(resource_id)")

    execute("""
    CREATE INDEX note_conflicts_open_idx
      ON content.note_conflicts(vault_id, resource_id, created_at DESC, id)
      WHERE state = 'open'
    """)

    execute("""
    CREATE INDEX note_conflicts_history_idx
      ON content.note_conflicts(vault_id, resource_id, created_at DESC, id)
    """)

    execute("""
    CREATE INDEX note_search_documents_vector_index
      ON content.note_search_documents USING gin(search_vector)
    """)

    execute("""
    CREATE INDEX note_search_documents_vault_head
      ON content.note_search_documents(vault_id, head_inserted_at DESC, resource_id)
    """)

    execute("""
    CREATE INDEX note_mutation_receipts_principal_history
      ON content.note_mutation_receipts(vault_id, principal_id, inserted_at DESC, mutation_id)
    """)

    execute("""
    CREATE INDEX note_mutation_receipts_pending
      ON content.note_mutation_receipts(vault_id, inserted_at, mutation_id)
      WHERE state = 'pending'
    """)
  end

  defp create_note_version_aggregate_guard do
    execute("""
    CREATE FUNCTION content.enforce_note_version_aggregate()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, content
    AS $function$
    DECLARE
      resource_kind text;
      resource_revision bigint;
    BEGIN
      PERFORM pg_advisory_xact_lock(
        hashtextextended('singularity.note.aggregate:' || NEW.resource_id::text, 0)
      );

      SELECT resource.kind, version.revision
      INTO resource_kind, resource_revision
      FROM content.resources AS resource
      JOIN content.resource_versions AS version
        ON version.id = NEW.resource_version_id
       AND version.resource_id = NEW.resource_id
       AND version.vault_id = NEW.vault_id
       AND version.classification = NEW.classification
      WHERE resource.id = NEW.resource_id
        AND resource.vault_id = NEW.vault_id
        AND resource.classification = NEW.classification;

      IF NOT FOUND THEN
        RETURN NEW;
      END IF;

      IF resource_kind <> 'note' THEN
        RAISE EXCEPTION 'typed note version requires a note resource'
          USING ERRCODE = '23514',
                CONSTRAINT = 'note_versions_resource_kind_check';
      END IF;

      IF (resource_revision = 0) <>
         (NEW.parent_version_id IS NULL AND NEW.merge_parent_version_id IS NULL) THEN
        RAISE EXCEPTION 'only revision zero may be parentless'
          USING ERRCODE = '23514',
                CONSTRAINT = 'note_versions_initial_parent_check';
      END IF;

      RETURN NEW;
    END
    $function$
    """)

    execute("REVOKE ALL ON FUNCTION content.enforce_note_version_aggregate() FROM PUBLIC")

    execute("""
    CREATE CONSTRAINT TRIGGER note_versions_aggregate_check
    AFTER INSERT OR UPDATE
    ON content.note_versions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION content.enforce_note_version_aggregate()
    """)
  end

  defp create_note_aggregate_reference_guards do
    execute("""
    CREATE FUNCTION content.enforce_note_resource_kind_update()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, content
    AS $function$
    BEGIN
      PERFORM pg_advisory_xact_lock(
        hashtextextended('singularity.note.aggregate:' || OLD.id::text, 0)
      );

      IF NEW.kind IS DISTINCT FROM OLD.kind THEN
        RAISE EXCEPTION 'resource kind is immutable after creation'
          USING ERRCODE = '23514',
                CONSTRAINT = 'resources_note_kind_immutable_check';
      END IF;

      RETURN NEW;
    END
    $function$
    """)

    execute("REVOKE ALL ON FUNCTION content.enforce_note_resource_kind_update() FROM PUBLIC")

    execute("""
    CREATE TRIGGER resources_note_kind_immutable
    BEFORE UPDATE OF kind
    ON content.resources
    FOR EACH ROW
    EXECUTE FUNCTION content.enforce_note_resource_kind_update()
    """)

    execute("""
    CREATE FUNCTION content.enforce_note_resource_version_update()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, content
    AS $function$
    BEGIN
      PERFORM pg_advisory_xact_lock(
        hashtextextended('singularity.note.aggregate:' || OLD.resource_id::text, 0)
      );

      IF (
           NEW.id IS DISTINCT FROM OLD.id
           OR NEW.resource_id IS DISTINCT FROM OLD.resource_id
           OR NEW.vault_id IS DISTINCT FROM OLD.vault_id
           OR NEW.classification IS DISTINCT FROM OLD.classification
           OR NEW.revision IS DISTINCT FROM OLD.revision
         )
         AND EXISTS (
           SELECT 1
           FROM content.note_versions AS note_version
           WHERE note_version.resource_version_id = OLD.id
             AND note_version.resource_id = OLD.resource_id
             AND note_version.vault_id = OLD.vault_id
             AND note_version.classification = OLD.classification
         ) THEN
        RAISE EXCEPTION 'typed note resource-version identity is immutable'
          USING ERRCODE = '23514',
                CONSTRAINT = 'resource_versions_note_identity_immutable_check';
      END IF;

      RETURN NEW;
    END
    $function$
    """)

    execute("REVOKE ALL ON FUNCTION content.enforce_note_resource_version_update() FROM PUBLIC")

    execute("""
    CREATE TRIGGER resource_versions_note_identity_immutable
    BEFORE UPDATE OF id, resource_id, vault_id, classification, revision
    ON content.resource_versions
    FOR EACH ROW
    EXECUTE FUNCTION content.enforce_note_resource_version_update()
    """)
  end

  defp create_rls_and_grants do
    Enum.each(@note_tables, fn table ->
      execute("ALTER TABLE content.#{table} ENABLE ROW LEVEL SECURITY")
      execute("ALTER TABLE content.#{table} FORCE ROW LEVEL SECURITY")

      execute("""
      CREATE POLICY #{table}_table_owner
      ON content.#{table}
      FOR ALL
      TO singularity_table_owner
      USING (true)
      WITH CHECK (true)
      """)

      execute("""
      CREATE POLICY #{table}_vault_isolation
      ON content.#{table}
      FOR ALL
      TO singularity_web, singularity_worker
      USING (#{vault_policy()})
      WITH CHECK (#{vault_policy()})
      """)
    end)

    execute("GRANT SELECT, INSERT ON content.note_versions TO singularity_web")
    execute("GRANT SELECT ON content.note_versions TO singularity_worker")

    execute("GRANT SELECT, INSERT, UPDATE ON content.note_conflicts TO singularity_web")

    execute("""
    GRANT SELECT, INSERT, UPDATE, DELETE
    ON content.note_search_documents
    TO singularity_web, singularity_worker
    """)

    execute("GRANT SELECT, INSERT, UPDATE ON content.note_mutation_receipts TO singularity_web")
  end

  defp vault_policy do
    """
    NULLIF(current_setting('singularity.principal_id', true), '') IS NOT NULL
    AND NULLIF(current_setting('singularity.vault_id', true), '') IS NOT NULL
    AND vault_id = NULLIF(current_setting('singularity.vault_id', true), '')::uuid
    AND core.principal_is_authorized(
      NULLIF(current_setting('singularity.principal_id', true), '')::uuid,
      vault_id
    )
    """
  end

  defp create_capability_reconciler do
    execute("GRANT USAGE ON SCHEMA core TO singularity_migration")

    execute("""
    CREATE FUNCTION core.reconcile_note_capabilities()
    RETURNS integer
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, core, identity
    AS $function$
    DECLARE
      affected_count integer;
    BEGIN
      PERFORM pg_advisory_xact_lock(
        hashtextextended('singularity.reconcile_note_capabilities', 0)
      );

      IF NOT EXISTS (
        SELECT 1
        FROM core.principal_capabilities AS assignment
        JOIN core.capabilities AS capability
          ON capability.id = assignment.capability_id
         AND capability.name = 'vault.password_change'
        JOIN identity.principals AS principal
          ON principal.id = assignment.principal_id
         AND principal.kind = 'owner'
         AND principal.revoked_at IS NULL
        JOIN identity.accounts AS account
          ON account.id = principal.account_id
         AND account.status = 'active'
        JOIN core.vault_members AS membership
          ON membership.principal_id = assignment.principal_id
         AND membership.vault_id = assignment.vault_id
         AND membership.revoked_at IS NULL
        WHERE assignment.revoked_at IS NULL
      ) THEN
        RETURN 0;
      END IF;

      INSERT INTO core.capabilities (id, name, inserted_at)
      SELECT gen_random_uuid(), requested.name, CURRENT_TIMESTAMP
      FROM (VALUES ('note.export'), ('note.read'), ('note.write')) AS requested(name)
      ON CONFLICT (name) DO NOTHING;

      WITH eligible AS MATERIALIZED (
        SELECT DISTINCT
          principal.id AS principal_id,
          membership.vault_id
        FROM core.principal_capabilities AS assignment
        JOIN core.capabilities AS capability
          ON capability.id = assignment.capability_id
         AND capability.name = 'vault.password_change'
        JOIN identity.principals AS principal
          ON principal.id = assignment.principal_id
         AND principal.kind = 'owner'
         AND principal.revoked_at IS NULL
        JOIN identity.accounts AS account
          ON account.id = principal.account_id
         AND account.status = 'active'
        JOIN core.vault_members AS membership
          ON membership.principal_id = assignment.principal_id
         AND membership.vault_id = assignment.vault_id
         AND membership.revoked_at IS NULL
        WHERE assignment.revoked_at IS NULL
      ),
      requested_assignments AS MATERIALIZED (
        SELECT eligible.principal_id, eligible.vault_id, capability.id AS capability_id
        FROM eligible
        CROSS JOIN core.capabilities AS capability
        WHERE capability.name IN ('note.export', 'note.read', 'note.write')
      ),
      granted AS (
        INSERT INTO core.principal_capabilities (
          principal_id,
          vault_id,
          capability_id,
          revoked_at,
          inserted_at
        )
        SELECT principal_id, vault_id, capability_id, NULL, CURRENT_TIMESTAMP
        FROM requested_assignments
        ON CONFLICT (principal_id, vault_id, capability_id)
        DO UPDATE SET revoked_at = NULL
        WHERE core.principal_capabilities.revoked_at IS NOT NULL
        RETURNING principal_id, vault_id
      ),
      affected AS MATERIALIZED (
        SELECT DISTINCT principal_id, vault_id FROM granted
      ),
      updated_principals AS (
        UPDATE identity.principals AS principal
        SET authorization_epoch = principal.authorization_epoch + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE principal.id IN (SELECT principal_id FROM affected)
        RETURNING principal.id
      ),
      updated_vaults AS (
        UPDATE core.vaults AS vault
        SET authorization_epoch = vault.authorization_epoch + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE vault.id IN (SELECT vault_id FROM affected)
        RETURNING vault.id
      )
      SELECT
        (SELECT count(*) FROM affected)::integer
        + (SELECT count(*) * 0 FROM updated_principals)::integer
        + (SELECT count(*) * 0 FROM updated_vaults)::integer
      INTO affected_count;

      RETURN affected_count;
    END
    $function$
    """)

    execute("REVOKE ALL ON FUNCTION core.reconcile_note_capabilities() FROM PUBLIC")

    execute(
      "GRANT EXECUTE ON FUNCTION core.reconcile_note_capabilities() TO singularity_migration"
    )
  end

  defp remove_note_capabilities do
    execute("""
    WITH note_capabilities AS (
      SELECT id FROM core.capabilities
      WHERE name IN ('note.export', 'note.read', 'note.write')
    ),
    removed AS (
      DELETE FROM core.principal_capabilities AS assignment
      USING note_capabilities AS capability
      WHERE assignment.capability_id = capability.id
      RETURNING assignment.principal_id, assignment.vault_id
    ),
    affected AS MATERIALIZED (
      SELECT DISTINCT principal_id, vault_id FROM removed
    ),
    updated_principals AS (
      UPDATE identity.principals AS principal
      SET authorization_epoch = principal.authorization_epoch + 1,
          updated_at = CURRENT_TIMESTAMP
      WHERE principal.id IN (SELECT principal_id FROM affected)
      RETURNING principal.id
    ),
    updated_vaults AS (
      UPDATE core.vaults AS vault
      SET authorization_epoch = vault.authorization_epoch + 1,
          updated_at = CURRENT_TIMESTAMP
      WHERE vault.id IN (SELECT vault_id FROM affected)
      RETURNING vault.id
    )
    DELETE FROM core.capabilities
    WHERE id IN (SELECT id FROM note_capabilities)
      AND ((SELECT count(*) FROM updated_principals) >= 0)
      AND ((SELECT count(*) FROM updated_vaults) >= 0)
    """)
  end
end
