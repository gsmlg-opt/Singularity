defmodule Singularity.Repo.Migrations.AddItemContentAndChanges do
  use Ecto.Migration

  def change do
    alter table(:items) do
      add :content, :text
      add :content_updated_at, :utc_datetime
    end

    create table(:item_changes) do
      add :fetch_run_id, references(:fetch_runs, on_delete: :delete_all), null: false
      add :item_id, references(:items, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :external_id, :string, null: false
      add :title, :text, null: false
      add :change, :string, null: false
      add :fields, :map, null: false, default: %{}
      add :content_diff, :text
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:item_changes, [:fetch_run_id])
    create index(:item_changes, [:item_id, :inserted_at])

    alter table(:fetch_runs) do
      add :added_count, :integer, null: false, default: 0
      add :updated_count, :integer, null: false, default: 0
      add :removed_count, :integer, null: false, default: 0
    end
  end
end
