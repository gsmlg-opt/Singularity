defmodule Singularity.Storage.Migrations.UnifiedSearchReconciliation do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    CREATE FUNCTION content.reconcile_search_resource_internal(requested_owner uuid, requested_resource uuid)
    RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content
    AS $function$
    DECLARE target content.resources%ROWTYPE;
      projected_count bigint;
    BEGIN
      SELECT resource.* INTO target
      FROM content.resources AS resource
      WHERE resource.id = requested_resource AND resource.vault_id = requested_owner
        AND resource.classification = 'private' AND resource.kind IN ('note', 'document')
      FOR UPDATE;
      IF NOT FOUND THEN RETURN -1; END IF;

      IF target.kind = 'document' THEN
        PERFORM 1 FROM content.document_versions AS document
        WHERE document.resource_version_id = target.current_version_id
          AND document.resource_id = target.id AND document.vault_id = target.vault_id
          AND document.classification = target.classification
        FOR UPDATE;
      END IF;

      DELETE FROM content.search_entries
      WHERE resource_id = target.id AND vault_id = target.vault_id;

      IF target.kind = 'note' THEN
        INSERT INTO content.search_entries (
          entry_id, vault_id, classification, resource_id, resource_version_id,
          kind, note_resource_version_id, fragment_id, ordinal, title, body,
          locator, source_inserted_at, projection_version
        )
        SELECT 'note:' || version.id::text, target.vault_id, target.classification,
          target.id, version.id, 'note', version.id, NULL, 0, note.title, note.markdown,
          '{"version":1,"kind":"markdown","heading_path":[]}'::jsonb,
          version.inserted_at, 1
        FROM content.resource_versions AS version
        JOIN content.note_versions AS note
          ON note.resource_version_id = version.id AND note.resource_id = version.resource_id
          AND note.vault_id = version.vault_id AND note.classification = version.classification
        WHERE version.id = target.current_version_id AND version.resource_id = target.id
          AND version.vault_id = target.vault_id AND version.classification = target.classification
          AND target.deleted_at IS NULL;
      ELSE
        INSERT INTO content.search_entries (
          entry_id, vault_id, classification, resource_id, resource_version_id,
          kind, note_resource_version_id, fragment_id, ordinal, title, body,
          locator, source_inserted_at, projection_version
        )
        SELECT 'document:' || fragment.id, target.vault_id, target.classification,
          target.id, version.id, 'document', NULL, fragment.id, fragment.ordinal,
          document.title, fragment.text, fragment.locator, version.inserted_at, 1
        FROM content.resource_versions AS version
        JOIN content.document_versions AS document
          ON document.resource_version_id = version.id AND document.resource_id = version.resource_id
          AND document.vault_id = version.vault_id AND document.classification = version.classification
        JOIN content.document_fragments AS fragment
          ON fragment.resource_version_id = document.resource_version_id
          AND fragment.resource_id = document.resource_id AND fragment.vault_id = document.vault_id
          AND fragment.classification = document.classification
        WHERE version.id = target.current_version_id AND version.resource_id = target.id
          AND version.vault_id = target.vault_id AND version.classification = target.classification
          AND target.deleted_at IS NULL AND document.state = 'ready';
      END IF;

      GET DIAGNOSTICS projected_count = ROW_COUNT;
      RETURN projected_count;
    END
    $function$
    """)

    execute("""
    ALTER FUNCTION content.reconcile_search_resource_internal(uuid, uuid)
      OWNER TO singularity_table_owner
    """)

    execute("""
    REVOKE ALL ON FUNCTION content.reconcile_search_resource_internal(uuid, uuid)
      FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth
    """)

    create_read_entrypoint()
    create_note_write_entrypoint()

    for name <- ["reconcile_search_resource", "reconcile_note_search_resource"] do
      execute("ALTER FUNCTION content.#{name}(uuid) OWNER TO singularity_table_owner")

      execute("""
      REVOKE ALL ON FUNCTION content.#{name}(uuid)
        FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth
      """)

      execute("GRANT EXECUTE ON FUNCTION content.#{name}(uuid) TO singularity_web")
    end

    execute(
      "GRANT EXECUTE ON FUNCTION content.reconcile_note_search_resource(uuid) TO singularity_worker"
    )

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "Unified search reconciliation migration is forward-only")

  defp create_read_entrypoint do
    execute("""
    CREATE FUNCTION content.reconcile_search_resource(requested_resource uuid)
    RETURNS bigint LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE principal uuid; owner uuid; capabilities text[];
      resource_kind text; required_capability text;
    BEGIN
      #{scoped_authority_guard()}

      SELECT resource.kind INTO resource_kind
      FROM content.resources AS resource
      WHERE resource.id = requested_resource AND resource.vault_id = owner
        AND resource.classification = 'private' AND resource.kind IN ('note', 'document');
      IF NOT FOUND THEN RETURN -1; END IF;

      required_capability := CASE resource_kind WHEN 'note' THEN 'note.read' ELSE 'asset.read' END;
      IF NOT (required_capability = ANY(capabilities)) THEN
        RAISE EXCEPTION 'search reconciliation is not authorized' USING ERRCODE = '42501';
      END IF;

      RETURN content.reconcile_search_resource_internal(owner, requested_resource);
    END
    $function$
    """)
  end

  defp create_note_write_entrypoint do
    execute("""
    CREATE FUNCTION content.reconcile_note_search_resource(requested_resource uuid)
    RETURNS bigint LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE principal uuid; owner uuid; capabilities text[];
    BEGIN
      #{scoped_authority_guard()}

      IF NOT ('note.write' = ANY(capabilities)) THEN
        RAISE EXCEPTION 'search reconciliation is not authorized' USING ERRCODE = '42501';
      END IF;

      IF NOT EXISTS (
        SELECT FROM content.resources AS resource
        WHERE resource.id = requested_resource AND resource.vault_id = owner
          AND resource.classification = 'private' AND resource.kind = 'note'
      ) THEN RETURN -1; END IF;

      RETURN content.reconcile_search_resource_internal(owner, requested_resource);
    END
    $function$
    """)
  end

  defp scoped_authority_guard do
    """
    IF current_setting('transaction_isolation') <> 'read committed' OR requested_resource IS NULL THEN
      RAISE EXCEPTION 'search reconciliation is not authorized' USING ERRCODE = '42501';
    END IF;

    BEGIN
      principal := nullif(current_setting('singularity.principal_id', true), '')::uuid;
      owner := nullif(current_setting('singularity.vault_id', true), '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'search reconciliation is not authorized' USING ERRCODE = '42501';
    END;

    IF principal IS NULL OR owner IS NULL THEN
      RAISE EXCEPTION 'search reconciliation is not authorized' USING ERRCODE = '42501';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended(
      'singularity:authorization:' || principal::text || ':' || owner::text, 0));

    SELECT auth.capabilities INTO capabilities FROM core.live_principal_authorization() AS auth
    WHERE auth.principal_id = principal AND auth.vault_id = owner AND auth.principal_kind = 'owner'
      AND auth.principal_revoked_at IS NULL AND auth.membership_revoked_at IS NULL
      AND auth.clearance IN ('private', 'sensitive', 'restricted');

    IF NOT FOUND THEN
      RAISE EXCEPTION 'search reconciliation is not authorized' USING ERRCODE = '42501';
    END IF;
    """
  end
end
