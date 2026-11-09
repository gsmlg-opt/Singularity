defmodule Singularity.Storage.Migrations.CreateAuditAndBackupTables do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DO $migration$
    BEGIN
    CREATE TABLE audit.events (
      id uuid PRIMARY KEY,
      vault_id uuid,
      actor_kind text NOT NULL,
      principal_id uuid,
      anonymous_fingerprint bytea,
      operation text NOT NULL,
      result text NOT NULL,
      classification text NOT NULL,
      correlation_id uuid NOT NULL,
      target_type text,
      target_id uuid,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      occurred_at timestamptz(6) NOT NULL,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT events_actor_membership_fkey
        FOREIGN KEY (principal_id, vault_id)
        REFERENCES core.vault_members(principal_id, vault_id)
        MATCH FULL,
      CONSTRAINT events_actor_check
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
        ),
      CONSTRAINT events_result_check
        CHECK (result IN ('allowed', 'denied', 'completed', 'failed')),
      CONSTRAINT events_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted'))
    );

    CREATE TABLE audit.backup_manifests (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL REFERENCES core.vaults(id),
      classification text NOT NULL,
      status text NOT NULL,
      destination_ref text NOT NULL,
      kdf_version integer NOT NULL,
      kdf_salt bytea NOT NULL,
      kdf_parameters jsonb NOT NULL,
      recovery_wrapper bytea NOT NULL,
      custody_ref text,
      snapshot_id uuid,
      outbox_high_water bigint,
      manifest_hash bytea,
      manifest_tag bytea,
      sealed_at timestamptz(6),
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (id, vault_id),
      CONSTRAINT backup_manifests_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT backup_manifests_status_check
        CHECK (status IN (
          'pending',
          'waiting_for_backup_key',
          'copying',
          'sealed',
          'failed'
        )),
      CONSTRAINT backup_manifests_kdf_version_check CHECK (kdf_version > 0),
      CONSTRAINT backup_manifests_outbox_high_water_check
        CHECK (outbox_high_water IS NULL OR outbox_high_water >= 0),
      CONSTRAINT backup_manifests_hash_check
        CHECK (manifest_hash IS NULL OR octet_length(manifest_hash) = 32)
    );

    CREATE TABLE audit.backup_manifest_objects (
      id uuid PRIMARY KEY,
      manifest_id uuid NOT NULL,
      asset_object_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      inventory_position bigint NOT NULL,
      storage_ref text NOT NULL,
      ciphertext_byte_size bigint NOT NULL,
      ciphertext_hash bytea NOT NULL,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (manifest_id, asset_object_id),
      CONSTRAINT backup_manifest_objects_manifest_vault_fkey
        FOREIGN KEY (manifest_id, vault_id)
        REFERENCES audit.backup_manifests(id, vault_id)
        MATCH FULL,
      CONSTRAINT backup_manifest_objects_object_vault_fkey
        FOREIGN KEY (asset_object_id, vault_id)
        REFERENCES content.asset_objects(id, vault_id)
        MATCH FULL,
      CONSTRAINT backup_manifest_objects_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT backup_manifest_objects_position_check CHECK (inventory_position >= 0),
      CONSTRAINT backup_manifest_objects_size_check CHECK (ciphertext_byte_size >= 0),
      CONSTRAINT backup_manifest_objects_hash_check
        CHECK (octet_length(ciphertext_hash) = 32)
    );

    CREATE OR REPLACE FUNCTION audit.reject_event_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, audit
    AS $$
    BEGIN
      RAISE EXCEPTION 'audit events are immutable';
    END;
    $$;

    CREATE TRIGGER events_immutable
    BEFORE UPDATE OR DELETE ON audit.events
    FOR EACH ROW
    EXECUTE FUNCTION audit.reject_event_mutation();
    END
    $migration$;
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DO $migration$
    BEGIN
    DROP TRIGGER IF EXISTS events_immutable ON audit.events;
    DROP FUNCTION IF EXISTS audit.reject_event_mutation();
    DROP TABLE IF EXISTS audit.backup_manifest_objects;
    DROP TABLE IF EXISTS audit.backup_manifests;
    DROP TABLE IF EXISTS audit.events;
    END
    $migration$;
    """)

    execute("SET LOCAL ROLE NONE")
  end
end
