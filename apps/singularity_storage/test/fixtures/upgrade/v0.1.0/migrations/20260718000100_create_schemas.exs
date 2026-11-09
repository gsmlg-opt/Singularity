defmodule Singularity.Storage.Migrations.CreateSchemas do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    for schema <- ~w(identity core content jobs audit) do
      execute("CREATE SCHEMA #{schema} AUTHORIZATION singularity_table_owner")
      execute("REVOKE ALL ON SCHEMA #{schema} FROM PUBLIC")
    end

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    for schema <- ~w(audit jobs content core identity) do
      execute("DROP SCHEMA IF EXISTS #{schema} CASCADE")
    end

    execute("SET LOCAL ROLE NONE")
  end
end
