defmodule Singularity.Storage.Migrations.DocumentSourcePinCount do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    CREATE FUNCTION content.document_source_pin_count(requested_object_id uuid, requested_vault_id uuid)
    RETURNS integer
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, content, core
    AS $function$
    DECLARE pin_count integer;
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM core.live_principal_authorization() AS auth
        WHERE auth.vault_id = requested_vault_id
          AND auth.principal_revoked_at IS NULL
          AND auth.membership_revoked_at IS NULL
          AND (
            (auth.principal_kind = 'owner' AND 'asset.write' = ANY(auth.capabilities))
            OR EXISTS (
              SELECT 1
              FROM core.object_cleanup_authorization(requested_vault_id) AS cleanup
              WHERE cleanup.principal_id = auth.principal_id
            )
          )
      ) THEN
        RAISE EXCEPTION 'Document source pin authorization unavailable'
          USING ERRCODE = '42501';
      END IF;

      SELECT count(*) INTO pin_count
      FROM content.document_versions
      WHERE source_object_id = requested_object_id
        AND vault_id = requested_vault_id;

      RETURN pin_count;
    END
    $function$
    """)

    execute(
      "REVOKE ALL ON FUNCTION content.document_source_pin_count(uuid,uuid) FROM PUBLIC, singularity_web, singularity_dispatcher, singularity_pre_auth"
    )

    execute(
      "GRANT EXECUTE ON FUNCTION content.document_source_pin_count(uuid,uuid) TO singularity_worker"
    )

    execute("SET LOCAL ROLE NONE")
  end

  def down, do: raise(Ecto.MigrationError, "Document source pin count migration is forward-only")
end
