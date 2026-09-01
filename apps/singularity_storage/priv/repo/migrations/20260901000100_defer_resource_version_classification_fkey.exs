defmodule Singularity.Storage.Migrations.DeferResourceVersionClassificationForeignKey do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    ALTER TABLE content.resource_versions
      ALTER CONSTRAINT resource_versions_resource_classification_fkey
      DEFERRABLE INITIALLY DEFERRED
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    ALTER TABLE content.resource_versions
      ALTER CONSTRAINT resource_versions_resource_classification_fkey
      NOT DEFERRABLE INITIALLY IMMEDIATE
    """)

    execute("SET LOCAL ROLE NONE")
  end
end
