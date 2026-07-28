defmodule Singularity.Storage.Migrations.SecureUploadGrantCsrf do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    ALTER TABLE content.upload_grants
      ADD COLUMN csrf_token_digest bytea
    """)

    execute("""
    UPDATE content.upload_grants
    SET
      csrf_token_digest =
        CASE
          WHEN consumed_at IS NULL THEN #{legacy_active_sentinel()}
          ELSE #{legacy_consumed_sentinel()}
        END,
      consumed_at = COALESCE(consumed_at, statement_timestamp())
    """)

    execute("""
    ALTER TABLE content.upload_grants
      ALTER COLUMN csrf_token_digest SET NOT NULL,
      ADD CONSTRAINT upload_grants_csrf_token_digest_check
        CHECK (octet_length(csrf_token_digest) = 32)
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    UPDATE content.upload_grants
    SET consumed_at = NULL
    WHERE csrf_token_digest = #{legacy_active_sentinel()}
    """)

    execute("""
    ALTER TABLE content.upload_grants
      DROP CONSTRAINT upload_grants_csrf_token_digest_check,
      DROP COLUMN csrf_token_digest
    """)

    execute("SET LOCAL ROLE NONE")
  end

  defp legacy_active_sentinel do
    """
    decode(
      md5('singularity:legacy-active-upload-csrf:' || id::text) ||
      md5('singularity:legacy-active-upload-csrf:2:' || id::text),
      'hex'
    )
    """
  end

  defp legacy_consumed_sentinel do
    """
    decode(
      md5('singularity:legacy-consumed-upload-csrf:' || id::text) ||
      md5('singularity:legacy-consumed-upload-csrf:2:' || id::text),
      'hex'
    )
    """
  end
end
