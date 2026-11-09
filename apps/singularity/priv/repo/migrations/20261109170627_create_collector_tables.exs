defmodule Singularity.Repo.Migrations.CreateCollectorTables do
  use Ecto.Migration

  def change do
    create table(:sources) do
      add :kind, :string, null: false
      add :name, :string, null: false
      add :config, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :interval_minutes, :integer, null: false
      add :next_run_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:sources, [:enabled, :next_run_at])

    create table(:items) do
      add :kind, :string, null: false
      add :external_id, :string, null: false
      add :title, :text, null: false
      add :url, :text, null: false
      add :summary, :text
      add :published_at, :utc_datetime
      add :attributes, :map, null: false, default: %{}
      add :first_seen_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:items, [:kind, :external_id])
    create index(:items, [:last_seen_at])

    create table(:item_observations) do
      add :item_id, references(:items, on_delete: :delete_all), null: false
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :period, :string, null: false
      add :observed_at, :utc_datetime, null: false
      add :rank, :integer
      add :attributes, :map, null: false, default: %{}
      add :raw, :map, null: false, default: %{}
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:item_observations, [:source_id, :item_id, :period])
    create index(:item_observations, [:item_id])
    create index(:item_observations, [:observed_at])

    create table(:fetch_runs) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :item_count, :integer, null: false, default: 0
      add :skipped_count, :integer, null: false, default: 0
      add :error, :text
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
    end

    create index(:fetch_runs, [:source_id, :started_at])
  end
end
