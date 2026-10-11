defmodule Singularity.Storage.Migrations.KnowledgeBackupReadGrants do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    for table <-
          ~w(document_versions document_fragments note_attachments note_citations tags resource_tags relationships) do
      execute("GRANT SELECT ON content.#{table} TO singularity_worker")
    end

    execute("""
    CREATE FUNCTION content.export_document_import_receipts_for_backup(requested_vault_id uuid)
    RETURNS TABLE (
      vault_id uuid,
      principal_id uuid,
      mutation_id uuid,
      request_fingerprint bytea,
      state text,
      resource_id uuid,
      version_id uuid,
      inserted_at timestamptz
    )
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, content, core
    AS $function$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM core.live_principal_authorization() AS auth
        WHERE auth.vault_id = requested_vault_id
          AND auth.principal_kind = 'owner'
          AND auth.principal_revoked_at IS NULL
          AND auth.membership_revoked_at IS NULL
          AND 'backup.create' = ANY(auth.capabilities)
      ) THEN
        RAISE EXCEPTION 'backup authorization unavailable' USING ERRCODE = '42501';
      END IF;

      RETURN QUERY
        SELECT receipt.vault_id, receipt.principal_id, receipt.mutation_id,
          receipt.request_fingerprint, receipt.state, receipt.resource_id,
          receipt.version_id, receipt.inserted_at
        FROM content.document_import_receipts AS receipt
        WHERE receipt.vault_id = requested_vault_id;
    END
    $function$
    """)

    execute("""
    REVOKE ALL ON FUNCTION content.export_document_import_receipts_for_backup(uuid)
    FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION content.export_document_import_receipts_for_backup(uuid)
    TO singularity_worker
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down, do: raise(Ecto.MigrationError, "Knowledge backup read grants are forward-only")
end
