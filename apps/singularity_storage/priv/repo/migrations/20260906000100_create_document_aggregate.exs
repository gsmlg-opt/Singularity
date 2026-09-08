defmodule Singularity.Storage.Migrations.CreateDocumentAggregate do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    LOCK TABLE content.resources, content.resource_versions, content.note_versions
      IN ACCESS EXCLUSIVE MODE
    """)

    execute("""
    DO $preflight$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM content.resources AS resource
        WHERE (resource.kind = 'asset' AND resource.current_version_id IS NOT NULL)
          OR (resource.kind = 'note' AND NOT EXISTS (
            SELECT 1 FROM content.note_versions AS note
            JOIN content.resource_versions AS version
              ON (version.id, version.resource_id, version.vault_id, version.classification)
               = (note.resource_version_id, note.resource_id, note.vault_id, note.classification)
            WHERE (note.resource_version_id, note.resource_id, note.vault_id, note.classification)
                = (resource.current_version_id, resource.id, resource.vault_id, resource.classification)
          ))
      ) THEN
        RAISE EXCEPTION 'existing resource head is incompatible with typed knowledge'
          USING ERRCODE = '23514', CONSTRAINT = 'resources_document_preflight_check';
      END IF;
    END
    $preflight$
    """)

    create_document_versions()
    create_receipts()

    execute("""
    ALTER TABLE content.resources
      DROP CONSTRAINT resources_note_version_head_fkey,
      DROP CONSTRAINT resources_kind_check,
      DROP CONSTRAINT resources_note_head_check,
      ADD CONSTRAINT resources_kind_check CHECK (kind IN ('asset', 'note', 'document')),
      ADD CONSTRAINT resources_note_head_check CHECK (
        (kind = 'asset' AND current_version_id IS NULL)
        OR (kind IN ('note', 'document') AND current_version_id IS NOT NULL)
      ),
      ADD CONSTRAINT resources_version_head_fkey
        FOREIGN KEY (current_version_id, id, vault_id, classification)
        REFERENCES content.resource_versions(id, resource_id, vault_id, classification)
        DEFERRABLE INITIALLY DEFERRED
    """)

    create_typed_head_guard()
    create_source_guard()
    create_generic_identity_guard()
    create_receipt_guard()
    create_policies()
    execute("SET LOCAL ROLE NONE")
  end

  def down, do: raise(Ecto.MigrationError, "Document aggregate migration is forward-only")

  defp create_document_versions do
    execute("""
    CREATE TABLE content.document_versions (
      resource_version_id uuid PRIMARY KEY,
      resource_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      source_asset_id uuid NOT NULL,
      source_resource_id uuid NOT NULL,
      source_resource_version_id uuid NOT NULL,
      source_object_id uuid NOT NULL,
      source_digest bytea NOT NULL,
      source_byte_size bigint NOT NULL,
      media_type text NOT NULL,
      title text NOT NULL,
      created_by_principal_id uuid NOT NULL,
      state text NOT NULL DEFAULT 'pending',
      attempt_generation bigint NOT NULL DEFAULT 0,
      extraction_adapter text,
      extraction_format integer,
      extracted_text_digest bytea,
      detected_language text,
      failure_code text,
      attempt_finished_at timestamptz(6),
      inserted_at timestamptz(6) NOT NULL,
      CONSTRAINT document_versions_private_check CHECK (classification = 'private'),
      CONSTRAINT document_versions_source_digest_check CHECK (octet_length(source_digest) = 32),
      CONSTRAINT document_versions_source_byte_size_check CHECK (source_byte_size BETWEEN 0 AND 67108864),
      CONSTRAINT document_versions_media_type_check CHECK (media_type IN ('application/pdf', 'text/markdown', 'text/plain')),
      CONSTRAINT document_versions_title_check CHECK (btrim(title) <> '' AND octet_length(title) <= 255),
      CONSTRAINT document_versions_state_check CHECK (state IN ('pending', 'extracting', 'ready', 'failed', 'unsupported')),
      CONSTRAINT document_versions_attempt_generation_check CHECK (attempt_generation >= 0),
      CONSTRAINT document_versions_identity_aggregate_key UNIQUE (resource_version_id, resource_id, vault_id, classification),
      CONSTRAINT document_versions_receipt_identity_key UNIQUE (resource_version_id, resource_id, vault_id),
      CONSTRAINT document_versions_resource_version_fkey
        FOREIGN KEY (resource_version_id, resource_id, vault_id, classification)
        REFERENCES content.resource_versions(id, resource_id, vault_id, classification)
        DEFERRABLE INITIALLY DEFERRED,
      CONSTRAINT document_versions_source_asset_fkey
        FOREIGN KEY (source_asset_id, vault_id) REFERENCES content.assets(id, vault_id),
      CONSTRAINT document_versions_source_version_fkey
        FOREIGN KEY (source_resource_version_id, source_resource_id, vault_id, classification)
        REFERENCES content.resource_versions(id, resource_id, vault_id, classification),
      CONSTRAINT document_versions_source_association_fkey
        FOREIGN KEY (source_resource_version_id, source_asset_id)
        REFERENCES content.resource_assets(resource_version_id, asset_id),
      CONSTRAINT document_versions_source_object_fkey
        FOREIGN KEY (source_object_id, vault_id) REFERENCES content.asset_objects(id, vault_id),
      CONSTRAINT document_versions_created_by_membership_fkey
        FOREIGN KEY (created_by_principal_id, vault_id)
        REFERENCES core.vault_members(principal_id, vault_id)
    )
    """)
  end

  defp create_receipts do
    execute("""
    CREATE TABLE content.document_import_receipts (
      vault_id uuid NOT NULL,
      principal_id uuid NOT NULL,
      mutation_id uuid NOT NULL,
      request_fingerprint bytea NOT NULL,
      state text NOT NULL DEFAULT 'pending',
      resource_id uuid,
      version_id uuid,
      inserted_at timestamptz(6) NOT NULL,
      PRIMARY KEY (vault_id, principal_id, mutation_id),
      CONSTRAINT document_import_receipts_fingerprint_check CHECK (octet_length(request_fingerprint) = 32),
      CONSTRAINT document_import_receipts_state_check CHECK (state IN ('pending', 'completed')),
      CONSTRAINT document_import_receipts_result_shape_check CHECK (
        (state = 'pending' AND resource_id IS NULL AND version_id IS NULL)
        OR (state = 'completed' AND resource_id IS NOT NULL AND version_id IS NOT NULL)
      ),
      CONSTRAINT document_import_receipts_membership_fkey
        FOREIGN KEY (principal_id, vault_id) REFERENCES core.vault_members(principal_id, vault_id),
      CONSTRAINT document_import_receipts_version_fkey
        FOREIGN KEY (version_id, resource_id, vault_id)
        REFERENCES content.document_versions(resource_version_id, resource_id, vault_id)
        DEFERRABLE INITIALLY DEFERRED
    )
    """)
  end

  defp create_typed_head_guard do
    execute("""
    CREATE FUNCTION content.enforce_knowledge_typed_head()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content
    AS $function$
    DECLARE
      old_resource_id uuid;
      new_resource_id uuid;
      affected_id uuid;
      candidate content.resources%ROWTYPE;
    BEGIN
      IF TG_TABLE_NAME = 'resources' THEN
        IF TG_OP <> 'INSERT' THEN old_resource_id := OLD.id; END IF;
        IF TG_OP <> 'DELETE' THEN new_resource_id := NEW.id; END IF;
      ELSE
        IF TG_OP <> 'INSERT' THEN old_resource_id := OLD.resource_id; END IF;
        IF TG_OP <> 'DELETE' THEN new_resource_id := NEW.resource_id; END IF;
      END IF;

      FOR affected_id IN
        SELECT DISTINCT id FROM unnest(ARRAY[old_resource_id, new_resource_id]) AS ids(id)
        WHERE id IS NOT NULL ORDER BY id
      LOOP
        SELECT * INTO candidate FROM content.resources WHERE id = affected_id FOR UPDATE;
        IF NOT FOUND THEN CONTINUE; END IF;
        PERFORM pg_advisory_xact_lock(hashtextextended('singularity.note.aggregate:' || affected_id::text, 0));

        IF (candidate.kind = 'note' AND NOT EXISTS (
          SELECT 1 FROM content.note_versions AS typed
          WHERE (typed.resource_version_id, typed.resource_id, typed.vault_id, typed.classification)
              = (candidate.current_version_id, candidate.id, candidate.vault_id, candidate.classification)
        )) OR (candidate.kind = 'document' AND NOT EXISTS (
          SELECT 1 FROM content.document_versions AS typed
          WHERE (typed.resource_version_id, typed.resource_id, typed.vault_id, typed.classification)
              = (candidate.current_version_id, candidate.id, candidate.vault_id, candidate.classification)
        )) THEN
          RAISE EXCEPTION 'resource head requires its own typed version'
            USING ERRCODE = '23514', CONSTRAINT = 'resources_typed_head_check';
        END IF;

        IF (candidate.kind <> 'note' AND EXISTS (
          SELECT 1 FROM content.note_versions WHERE resource_id = candidate.id
        )) OR (candidate.kind <> 'document' AND EXISTS (
          SELECT 1 FROM content.document_versions WHERE resource_id = candidate.id
        )) THEN
          RAISE EXCEPTION 'typed version requires matching resource kind'
            USING ERRCODE = '23514', CONSTRAINT = 'knowledge_versions_resource_kind_check';
        END IF;
      END LOOP;
      RETURN NULL;
    END
    $function$
    """)

    for table <- ~w(resources note_versions document_versions) do
      execute("""
      CREATE CONSTRAINT TRIGGER #{table}_00_typed_head_check
      AFTER INSERT OR UPDATE OR DELETE ON content.#{table}
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
      EXECUTE FUNCTION content.enforce_knowledge_typed_head()
      """)
    end
  end

  defp create_source_guard do
    execute("""
    CREATE FUNCTION content.enforce_document_source()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content
    AS $function$
    DECLARE accepted_object_id uuid;
    BEGIN
      -- Match established source revalidation and deletion: Asset, object,
      -- then the remaining source references. Do not let the planner choose
      -- a conflicting row-lock order across a joined locking query.
      SELECT asset_object_id INTO accepted_object_id FROM content.assets
      WHERE id = NEW.source_asset_id AND vault_id = NEW.vault_id FOR SHARE;
      PERFORM 1 FROM content.asset_objects WHERE id = accepted_object_id FOR SHARE;
      PERFORM 1 FROM content.resources WHERE id = NEW.source_resource_id FOR SHARE;
      PERFORM 1 FROM content.resource_versions WHERE id = NEW.source_resource_version_id FOR SHARE;
      PERFORM 1 FROM content.resource_assets
      WHERE resource_version_id = NEW.source_resource_version_id AND asset_id = NEW.source_asset_id
      FOR SHARE;

      PERFORM 1
      FROM content.resources AS resource
      JOIN content.resource_versions AS version
        ON (version.resource_id, version.vault_id, version.classification)
         = (resource.id, resource.vault_id, resource.classification)
      JOIN content.assets AS asset
        ON asset.resource_version_id = version.id AND asset.vault_id = version.vault_id
      JOIN content.resource_assets AS association
        ON (association.resource_version_id, association.asset_id, association.vault_id)
         = (version.id, asset.id, asset.vault_id)
      JOIN content.asset_objects AS object
        ON (object.id, object.vault_id) = (asset.asset_object_id, asset.vault_id)
      WHERE resource.id = NEW.source_resource_id
        AND resource.kind = 'asset' AND resource.classification = 'private'
        AND resource.deleted_at IS NULL AND resource.vault_id = NEW.vault_id
        AND version.id = NEW.source_resource_version_id AND version.classification = 'private'
        AND asset.id = NEW.source_asset_id AND asset.classification = 'private'
        AND asset.state IN ('available', 'processing', 'ready')
        AND association.released_at IS NULL AND association.classification = 'private'
        AND object.id = NEW.source_object_id AND object.classification = 'private'
        AND object.lifecycle = 'available' AND object.deleted_at IS NULL
        AND object.plaintext_byte_size = NEW.source_byte_size;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Document source is not the accepted live Asset tuple'
          USING ERRCODE = '23514', CONSTRAINT = 'document_versions_source_check';
      END IF;
      RETURN NEW;
    END
    $function$
    """)

    execute("""
    CREATE TRIGGER document_versions_source_check
    BEFORE INSERT ON content.document_versions
    FOR EACH ROW EXECUTE FUNCTION content.enforce_document_source()
    """)
  end

  defp create_generic_identity_guard do
    execute("""
    CREATE FUNCTION content.enforce_document_resource_version_update()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content
    AS $function$
    DECLARE affected_id uuid;
    BEGIN
      FOR affected_id IN
        SELECT DISTINCT id FROM unnest(ARRAY[OLD.resource_id, NEW.resource_id]) AS ids(id)
        ORDER BY id
      LOOP
        PERFORM 1 FROM content.resources WHERE id = affected_id FOR UPDATE;
        PERFORM pg_advisory_xact_lock(hashtextextended('singularity.note.aggregate:' || affected_id::text, 0));
      END LOOP;

      IF (NEW.id, NEW.resource_id, NEW.vault_id, NEW.classification, NEW.revision)
         IS DISTINCT FROM (OLD.id, OLD.resource_id, OLD.vault_id, OLD.classification, OLD.revision)
         AND EXISTS (
           SELECT 1 FROM content.document_versions
           WHERE resource_version_id = OLD.id
         ) THEN
        RAISE EXCEPTION 'typed Document resource-version identity is immutable'
          USING ERRCODE = '23514', CONSTRAINT = 'resource_versions_document_identity_immutable_check';
      END IF;
      RETURN NEW;
    END
    $function$
    """)

    execute("""
    CREATE TRIGGER resource_versions_document_identity_immutable
    BEFORE UPDATE OF id, resource_id, vault_id, classification, revision
    ON content.resource_versions FOR EACH ROW
    EXECUTE FUNCTION content.enforce_document_resource_version_update()
    """)
  end

  defp create_receipt_guard do
    execute("""
    CREATE FUNCTION content.enforce_document_import_receipt()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content
    AS $function$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM content.document_import_receipts
        WHERE (vault_id, principal_id, mutation_id) = (NEW.vault_id, NEW.principal_id, NEW.mutation_id)
          AND state = 'pending'
      ) THEN
        RAISE EXCEPTION 'Document import receipt must complete in its transaction'
          USING ERRCODE = '23514', CONSTRAINT = 'document_import_receipts_completed_check';
      END IF;
      RETURN NULL;
    END
    $function$
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER document_import_receipts_completed_check
    AFTER INSERT OR UPDATE ON content.document_import_receipts
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION content.enforce_document_import_receipt()
    """)
  end

  defp create_policies do
    owner_predicate = """
    NULLIF(current_setting('singularity.principal_id', true), '') IS NOT NULL
    AND NULLIF(current_setting('singularity.vault_id', true), '') IS NOT NULL
    AND vault_id = NULLIF(current_setting('singularity.vault_id', true), '')::uuid
    AND core.principal_is_authorized(
      NULLIF(current_setting('singularity.principal_id', true), '')::uuid, vault_id)
    """

    for table <- ~w(document_versions document_import_receipts) do
      predicate =
        if table == "document_import_receipts",
          do:
            owner_predicate <>
              " AND principal_id = NULLIF(current_setting('singularity.principal_id', true), '')::uuid",
          else: owner_predicate

      execute("ALTER TABLE content.#{table} ENABLE ROW LEVEL SECURITY")
      execute("ALTER TABLE content.#{table} FORCE ROW LEVEL SECURITY")

      execute(
        "CREATE POLICY #{table}_table_owner ON content.#{table} FOR ALL TO singularity_table_owner USING (true) WITH CHECK (true)"
      )

      execute(
        "CREATE POLICY #{table}_vault_isolation ON content.#{table} FOR ALL TO singularity_web, singularity_worker USING (#{predicate}) WITH CHECK (#{predicate})"
      )

      execute(
        "REVOKE ALL ON content.#{table} FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth"
      )
    end

    for function <-
          ~w(enforce_knowledge_typed_head enforce_document_source enforce_document_resource_version_update enforce_document_import_receipt) do
      execute(
        "REVOKE ALL ON FUNCTION content.#{function}() FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth"
      )
    end
  end
end
