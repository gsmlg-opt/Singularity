defmodule Singularity.Storage.Migrations.AllowRestoreOutboxRetirementReasons do
  use Ecto.Migration

  @legacy_reason "legacy_missing_principal_authorization_epoch_provenance"
  @restore_reflected_reason "restore_effect_already_reflected"
  @restore_destructive_reason "restore_stale_destructive"

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    ALTER TABLE core.outbox_events
      DROP CONSTRAINT outbox_events_retirement_shape_check,
      ADD CONSTRAINT outbox_events_retirement_shape_check
        CHECK (
          (retired_at IS NULL AND retirement_reason IS NULL)
          OR (
            retired_at IS NOT NULL
            AND retirement_reason IS NOT NULL
            AND retirement_reason IN (
              '#{@legacy_reason}',
              '#{@restore_reflected_reason}',
              '#{@restore_destructive_reason}'
            )
          )
        )
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    ALTER TABLE core.outbox_events
      DROP CONSTRAINT outbox_events_retirement_shape_check,
      ADD CONSTRAINT outbox_events_retirement_shape_check
        CHECK (
          (retired_at IS NULL AND retirement_reason IS NULL)
          OR (
            retired_at IS NOT NULL
            AND retirement_reason IS NOT NULL
            AND retirement_reason = '#{@legacy_reason}'
          )
        )
    """)

    execute("SET LOCAL ROLE NONE")
  end
end
