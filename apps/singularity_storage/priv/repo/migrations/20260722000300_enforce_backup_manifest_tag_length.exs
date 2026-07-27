defmodule Singularity.Storage.Migrations.EnforceBackupManifestTagLength do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    ALTER TABLE audit.backup_manifests
    ADD CONSTRAINT backup_manifests_tag_check
    CHECK (manifest_tag IS NULL OR octet_length(manifest_tag) = 16)
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    ALTER TABLE audit.backup_manifests
    DROP CONSTRAINT IF EXISTS backup_manifests_tag_check
    """)

    execute("SET LOCAL ROLE NONE")
  end
end
