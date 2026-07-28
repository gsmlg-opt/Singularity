defmodule Singularity.Storage.Migrations.ExposeUploadStageAge do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")
    replace_recovery_function(true)
    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")
    replace_recovery_function(false)
    execute("SET LOCAL ROLE NONE")
  end

  defp replace_recovery_function(include_timestamp?) do
    execute("DROP FUNCTION content.list_open_upload_stages()")

    execute(recovery_function(include_timestamp?))

    execute("""
    REVOKE ALL ON FUNCTION content.list_open_upload_stages()
    FROM PUBLIC
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION content.list_open_upload_stages()
    TO singularity_worker
    """)
  end

  defp recovery_function(true) do
    """
    CREATE FUNCTION content.list_open_upload_stages()
    RETURNS TABLE (
      stage_id uuid,
      storage_ref text,
      stage_inserted_at timestamptz
    )
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, content, audit
    AS $function$
      SELECT
        stage.id,
        stage.storage_ref,
        stage.inserted_at
      FROM content.asset_stages AS stage
      JOIN content.upload_grants AS upload_grant
        ON upload_grant.id = stage.upload_grant_id
       AND upload_grant.vault_id = stage.vault_id
      WHERE stage.state = 'open'
        AND upload_grant.consumed_at IS NOT NULL
      ORDER BY stage.inserted_at, stage.id
    $function$
    """
  end

  defp recovery_function(false) do
    """
    CREATE FUNCTION content.list_open_upload_stages()
    RETURNS TABLE (
      stage_id uuid,
      storage_ref text
    )
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, content, audit
    AS $function$
      SELECT
        stage.id,
        stage.storage_ref
      FROM content.asset_stages AS stage
      JOIN content.upload_grants AS upload_grant
        ON upload_grant.id = stage.upload_grant_id
       AND upload_grant.vault_id = stage.vault_id
      WHERE stage.state = 'open'
        AND upload_grant.consumed_at IS NOT NULL
      ORDER BY stage.inserted_at, stage.id
    $function$
    """
  end
end
