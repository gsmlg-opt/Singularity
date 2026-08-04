defmodule Singularity.Storage.Migrations.RetireSupersededUploadGrants do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    ALTER TABLE content.upload_grants
      ADD COLUMN retired_at timestamptz(6),
      ADD COLUMN cancelled_at timestamptz(6),
      ADD CONSTRAINT upload_grants_retirement_check
        CHECK (
          (
            cancelled_at IS NULL
            OR (
              consumed_at IS NULL
              AND cancelled_at >= inserted_at
              AND retired_at IS NOT NULL
              AND retired_at = cancelled_at
            )
          )
          AND (
            retired_at IS NULL
            OR (
              retired_at >= inserted_at
              AND (
                consumed_at IS NOT NULL
                OR expires_at <= retired_at
                OR cancelled_at = retired_at
              )
            )
          )
        )
    """)

    execute("""
    UPDATE content.upload_grants AS upload_grant
    SET retired_at = (
      SELECT min(newer.inserted_at)
      FROM content.upload_grants AS newer
      WHERE newer.vault_id = upload_grant.vault_id
        AND newer.idempotency_key = upload_grant.idempotency_key
        AND (newer.inserted_at, newer.id) >
            (upload_grant.inserted_at, upload_grant.id)
    )
    WHERE upload_grant.consumed_at IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM content.asset_stages AS stage
        WHERE stage.upload_grant_id = upload_grant.id
          AND stage.vault_id = upload_grant.vault_id
          AND stage.state = 'abandoned'
      )
      AND EXISTS (
        SELECT 1
        FROM content.upload_grants AS newer
        WHERE newer.vault_id = upload_grant.vault_id
          AND newer.idempotency_key = upload_grant.idempotency_key
          AND (newer.inserted_at, newer.id) >
              (upload_grant.inserted_at, upload_grant.id)
      )
    """)

    execute("""
    DROP INDEX content.upload_grants_active_idempotency_key
    """)

    execute("""
    DO $guard$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM content.upload_grants
        WHERE retired_at IS NULL
        GROUP BY vault_id, idempotency_key
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION
          'cannot enforce one current upload attempt: duplicate unretired idempotency keys remain';
      END IF;
    END
    $guard$
    """)

    execute("""
    CREATE UNIQUE INDEX upload_grants_active_idempotency_key
      ON content.upload_grants(vault_id, idempotency_key)
      WHERE retired_at IS NULL
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")
    execute("LOCK TABLE content.upload_grants IN ACCESS EXCLUSIVE MODE")

    execute("""
    DO $guard$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM content.upload_grants
        WHERE retired_at IS NOT NULL
      ) THEN
        RAISE EXCEPTION
          'cannot downgrade upload grant retirement while retired history exists';
      END IF;
    END
    $guard$
    """)

    execute("""
    DROP INDEX content.upload_grants_active_idempotency_key
    """)

    execute("""
    ALTER TABLE content.upload_grants
      DROP CONSTRAINT upload_grants_retirement_check,
      DROP COLUMN cancelled_at,
      DROP COLUMN retired_at
    """)

    execute("""
    CREATE UNIQUE INDEX upload_grants_active_idempotency_key
      ON content.upload_grants(vault_id, idempotency_key)
      WHERE consumed_at IS NULL
    """)

    execute("SET LOCAL ROLE NONE")
  end
end
