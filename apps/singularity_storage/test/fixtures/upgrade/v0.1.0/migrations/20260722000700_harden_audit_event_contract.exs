defmodule Singularity.Storage.Migrations.HardenAuditEventContract do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    ALTER TABLE audit.events
    ADD COLUMN system_principal_name text
    """)

    execute("ALTER TABLE audit.events DISABLE TRIGGER events_immutable")

    execute("""
    ALTER TABLE audit.events
      DROP CONSTRAINT events_actor_membership_fkey,
      DROP CONSTRAINT events_actor_check
    """)

    execute("""
    UPDATE audit.events
    SET
      metadata =
        CASE
          WHEN actor_kind = 'system' AND principal_id IS NOT NULL
          THEN metadata || jsonb_build_object(
            'initiating_principal_id',
            principal_id
          )
          ELSE metadata
        END,
      principal_id =
        CASE WHEN actor_kind = 'system' THEN NULL ELSE principal_id END,
      system_principal_name =
        CASE
          WHEN actor_kind = 'system' THEN 'singularity.system'
          ELSE NULL
        END,
      target_type = COALESCE(target_type, 'audit_event'),
      target_id = COALESCE(target_id, id)
    """)

    execute("""
    ALTER TABLE audit.events
      ALTER COLUMN target_type SET NOT NULL,
      ALTER COLUMN target_id SET NOT NULL
    """)

    execute("""
    ALTER TABLE audit.events
      ADD CONSTRAINT events_actor_membership_fkey
        FOREIGN KEY (principal_id, vault_id)
        REFERENCES core.vault_members(principal_id, vault_id)
        MATCH SIMPLE,
      ADD CONSTRAINT events_actor_check
        CHECK (
          (
            actor_kind = 'anonymous'
            AND principal_id IS NULL
            AND vault_id IS NULL
            AND octet_length(anonymous_fingerprint) = 32
            AND system_principal_name IS NULL
          )
          OR
          (
            actor_kind = 'principal'
            AND principal_id IS NOT NULL
            AND vault_id IS NOT NULL
            AND anonymous_fingerprint IS NULL
            AND system_principal_name IS NULL
          )
          OR
          (
            actor_kind = 'system'
            AND principal_id IS NULL
            AND vault_id IS NOT NULL
            AND anonymous_fingerprint IS NULL
            AND system_principal_name IS NOT NULL
            AND btrim(system_principal_name) <> ''
          )
        ),
      ADD CONSTRAINT events_target_check
        CHECK (btrim(target_type) <> '')
    """)

    execute("""
    CREATE OR REPLACE FUNCTION audit.normalize_legacy_event_insert()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, audit
    AS $function$
    BEGIN
      IF NEW.actor_kind = 'system'
         AND NEW.system_principal_name IS NULL
      THEN
        IF NEW.principal_id IS NOT NULL THEN
          NEW.metadata :=
            COALESCE(NEW.metadata, '{}'::jsonb)
            || jsonb_build_object(
              'initiating_principal_id',
              NEW.principal_id
            );
        END IF;

        NEW.principal_id := NULL;
        NEW.system_principal_name := 'singularity.system';
      END IF;

      IF NEW.target_type IS NULL THEN
        NEW.target_type := 'audit_event';
      END IF;

      IF NEW.target_id IS NULL THEN
        NEW.target_id := NEW.id;
      END IF;

      RETURN NEW;
    END;
    $function$
    """)

    execute("""
    CREATE TRIGGER events_normalize_legacy_insert
    BEFORE INSERT ON audit.events
    FOR EACH ROW
    EXECUTE FUNCTION audit.normalize_legacy_event_insert()
    """)

    execute("ALTER TABLE audit.events ENABLE TRIGGER events_immutable")

    execute("DROP POLICY outbox_definer_writes_audit ON audit.events")

    execute("""
    CREATE POLICY outbox_definer_writes_audit
    ON audit.events
    FOR INSERT
    TO singularity_outbox_definer
    WITH CHECK (
      actor_kind = 'system'
      AND principal_id IS NULL
      AND vault_id IS NOT NULL
      AND anonymous_fingerprint IS NULL
      AND system_principal_name = 'singularity.system'
    )
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DO $guard$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM audit.events AS event
        WHERE event.actor_kind = 'system'
          AND NOT EXISTS (
            SELECT 1
            FROM core.vault_members AS member
            WHERE member.vault_id = event.vault_id
              AND member.principal_id::text =
                event.metadata ->> 'initiating_principal_id'
          )
      ) THEN
        RAISE EXCEPTION
          'cannot downgrade Task 15: named system audit attribution has no exact initiating principal'
          USING ERRCODE = 'object_not_in_prerequisite_state';
      END IF;
    END
    $guard$
    """)

    execute("DROP POLICY outbox_definer_writes_audit ON audit.events")

    execute("""
    CREATE POLICY outbox_definer_writes_audit
    ON audit.events
    FOR INSERT
    TO singularity_outbox_definer
    WITH CHECK (
      actor_kind = 'system'
      AND principal_id IS NOT NULL
      AND vault_id IS NOT NULL
      AND anonymous_fingerprint IS NULL
    )
    """)

    execute("DROP TRIGGER events_normalize_legacy_insert ON audit.events")
    execute("DROP FUNCTION audit.normalize_legacy_event_insert()")

    execute("ALTER TABLE audit.events DISABLE TRIGGER events_immutable")

    execute("""
    ALTER TABLE audit.events
      DROP CONSTRAINT events_target_check,
      DROP CONSTRAINT events_actor_check,
      DROP CONSTRAINT events_actor_membership_fkey,
      ALTER COLUMN target_type DROP NOT NULL,
      ALTER COLUMN target_id DROP NOT NULL
    """)

    execute("""
    UPDATE audit.events AS event
    SET principal_id = (
      SELECT member.principal_id
      FROM core.vault_members AS member
      WHERE member.vault_id = event.vault_id
        AND member.principal_id::text =
          event.metadata ->> 'initiating_principal_id'
    )
    WHERE event.actor_kind = 'system'
    """)

    execute("""
    ALTER TABLE audit.events
      DROP COLUMN system_principal_name,
      ADD CONSTRAINT events_actor_membership_fkey
        FOREIGN KEY (principal_id, vault_id)
        REFERENCES core.vault_members(principal_id, vault_id)
        MATCH FULL,
      ADD CONSTRAINT events_actor_check
        CHECK (
          (
            actor_kind = 'anonymous'
            AND principal_id IS NULL
            AND vault_id IS NULL
            AND octet_length(anonymous_fingerprint) = 32
          )
          OR
          (
            actor_kind IN ('principal', 'system')
            AND principal_id IS NOT NULL
            AND vault_id IS NOT NULL
            AND anonymous_fingerprint IS NULL
          )
        )
    """)

    execute("ALTER TABLE audit.events ENABLE TRIGGER events_immutable")

    execute("SET LOCAL ROLE NONE")
  end
end
