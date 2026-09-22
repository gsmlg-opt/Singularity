defmodule Singularity.Storage.Migrations.BackupUnsupportedGuard do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    CREATE FUNCTION content.backup_has_unsupported_canonical_rows(requested_vault_id uuid)
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, content, core
    AS $function$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM core.live_principal_authorization() AS auth
        WHERE auth.vault_id = requested_vault_id
          AND auth.principal_revoked_at IS NULL
          AND auth.membership_revoked_at IS NULL
          AND 'backup.create' = ANY(auth.capabilities)
      ) THEN
        RAISE EXCEPTION 'backup authorization unavailable' USING ERRCODE = '42501';
      END IF;

      RETURN EXISTS (SELECT 1 FROM content.document_versions WHERE vault_id = requested_vault_id)
        OR EXISTS (SELECT 1 FROM content.document_fragments WHERE vault_id = requested_vault_id)
        OR EXISTS (SELECT 1 FROM content.document_import_receipts WHERE vault_id = requested_vault_id)
        OR EXISTS (SELECT 1 FROM content.note_attachments WHERE vault_id = requested_vault_id)
        OR EXISTS (SELECT 1 FROM content.note_citations WHERE vault_id = requested_vault_id)
        OR EXISTS (SELECT 1 FROM content.tags WHERE vault_id = requested_vault_id)
        OR EXISTS (SELECT 1 FROM content.resource_tags WHERE vault_id = requested_vault_id)
        OR EXISTS (SELECT 1 FROM content.relationships WHERE vault_id = requested_vault_id);
    END
    $function$
    """)

    execute(
      "REVOKE ALL ON FUNCTION content.backup_has_unsupported_canonical_rows(uuid) FROM PUBLIC"
    )

    for role <- ~w(singularity_web singularity_dispatcher singularity_pre_auth) do
      execute(
        "REVOKE ALL ON FUNCTION content.backup_has_unsupported_canonical_rows(uuid) FROM #{role}"
      )
    end

    execute(
      "GRANT EXECUTE ON FUNCTION content.backup_has_unsupported_canonical_rows(uuid) TO singularity_worker"
    )

    execute("SET LOCAL ROLE NONE")
  end

  def down, do: raise(Ecto.MigrationError, "Backup unsupported guard migration is forward-only")
end
