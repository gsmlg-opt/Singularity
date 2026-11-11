defmodule Singularity.Repo.Migrations.AddItemsReadmeInstructionDeprecation do
  use Ecto.Migration

  def change do
    alter table(:items) do
      add :readme, :text
      add :readme_fetched_at, :utc_datetime
      add :instruction, :text
      add :deprecated_at, :utc_datetime
      add :deprecation_reason, :text
    end

    create index(:items, [:readme_fetched_at])
  end
end
