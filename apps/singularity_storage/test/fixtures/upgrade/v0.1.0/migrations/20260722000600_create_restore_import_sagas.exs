defmodule Singularity.Storage.Migrations.CreateRestoreImportSagas do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    CREATE TABLE audit.restore_import_sagas (
      singleton boolean PRIMARY KEY DEFAULT TRUE,
      manifest_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      manifest_hash bytea NOT NULL,
      manifest_tag bytea NOT NULL,
      inventory_hash bytea NOT NULL,
      destination_root_hash bytea NOT NULL,
      object_count integer NOT NULL,
      state text NOT NULL,
      imported_at timestamptz,
      rewrapped_at timestamptz,
      reconciled_at timestamptz,
      verified_at timestamptz,
      completed_at timestamptz,
      integrity_principal_id uuid,
      wrapper_generation bigint,
      inserted_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT restore_import_sagas_singleton_check CHECK (singleton),
      CONSTRAINT restore_import_sagas_manifest_hash_check
        CHECK (octet_length(manifest_hash) = 32),
      CONSTRAINT restore_import_sagas_manifest_tag_check
        CHECK (octet_length(manifest_tag) = 16),
      CONSTRAINT restore_import_sagas_inventory_hash_check
        CHECK (octet_length(inventory_hash) = 32),
      CONSTRAINT restore_import_sagas_destination_root_hash_check
        CHECK (octet_length(destination_root_hash) = 32),
      CONSTRAINT restore_import_sagas_object_count_check CHECK (object_count >= 0),
      CONSTRAINT restore_import_sagas_wrapper_generation_check
        CHECK (wrapper_generation BETWEEN 1 AND 4294967295),
      CONSTRAINT restore_import_sagas_state_check CHECK (
        state IN (
          'pending',
          'imported',
          'rewrapped',
          'reconciled',
          'verified',
          'completed'
        )
      ),
      CONSTRAINT restore_import_sagas_state_shape_check CHECK (
        (
          state = 'pending'
          AND imported_at IS NULL
          AND rewrapped_at IS NULL
          AND reconciled_at IS NULL
          AND verified_at IS NULL
          AND completed_at IS NULL
          AND integrity_principal_id IS NULL
          AND wrapper_generation IS NULL
        )
        OR (
          state = 'imported'
          AND imported_at IS NOT NULL
          AND rewrapped_at IS NULL
          AND reconciled_at IS NULL
          AND verified_at IS NULL
          AND completed_at IS NULL
          AND integrity_principal_id IS NULL
          AND wrapper_generation IS NULL
        )
        OR (
          state = 'rewrapped'
          AND imported_at IS NOT NULL
          AND rewrapped_at IS NOT NULL
          AND reconciled_at IS NULL
          AND verified_at IS NULL
          AND completed_at IS NULL
          AND integrity_principal_id IS NOT NULL
          AND wrapper_generation IS NOT NULL
        )
        OR (
          state = 'reconciled'
          AND imported_at IS NOT NULL
          AND rewrapped_at IS NOT NULL
          AND reconciled_at IS NOT NULL
          AND verified_at IS NULL
          AND completed_at IS NULL
          AND integrity_principal_id IS NOT NULL
          AND wrapper_generation IS NOT NULL
        )
        OR (
          state = 'verified'
          AND imported_at IS NOT NULL
          AND rewrapped_at IS NOT NULL
          AND reconciled_at IS NOT NULL
          AND verified_at IS NOT NULL
          AND completed_at IS NULL
          AND integrity_principal_id IS NOT NULL
          AND wrapper_generation IS NOT NULL
        )
        OR (
          state = 'completed'
          AND imported_at IS NOT NULL
          AND rewrapped_at IS NOT NULL
          AND reconciled_at IS NOT NULL
          AND verified_at IS NOT NULL
          AND completed_at IS NOT NULL
          AND integrity_principal_id IS NOT NULL
          AND wrapper_generation IS NOT NULL
        )
      )
    )
    """)

    execute("ALTER TABLE audit.restore_import_sagas ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE audit.restore_import_sagas FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY restore_import_sagas_table_owner
    ON audit.restore_import_sagas
    FOR ALL
    TO singularity_table_owner
    USING (true)
    WITH CHECK (true)
    """)

    execute("REVOKE ALL ON audit.restore_import_sagas FROM PUBLIC")
    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("LOCK TABLE audit.restore_import_sagas IN ACCESS EXCLUSIVE MODE")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM audit.restore_import_sagas) THEN
        RAISE EXCEPTION
          'cannot downgrade while a restore import saga marker exists'
          USING ERRCODE = 'object_not_in_prerequisite_state';
      END IF;
    END
    $$
    """)

    execute("DROP TABLE IF EXISTS audit.restore_import_sagas")
    execute("SET LOCAL ROLE NONE")
  end
end
