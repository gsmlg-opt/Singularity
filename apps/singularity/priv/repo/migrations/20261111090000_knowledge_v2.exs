defmodule Singularity.Repo.Migrations.KnowledgeV2 do
  use Ecto.Migration

  def up do
    # v1 data is disposable (spec §3): the knowledge base starts empty.
    execute "DELETE FROM item_observations"
    execute "DELETE FROM fetch_runs"
    execute "DELETE FROM items"

    alter table(:items) do
      add :details_fetched_at, :utc_datetime
      add :details_error, :text
    end

    create table(:item_labels) do
      add :item_id, references(:items, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :origin, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:item_labels, [:item_id, :name])
    create index(:item_labels, [:name])

    # Manual additions have no source. NULLS NOT DISTINCT keeps them unique per
    # item and period, so ON CONFLICT on these columns stays idempotent.
    drop unique_index(:item_observations, [:source_id, :item_id, :period])
    execute "ALTER TABLE item_observations ALTER COLUMN source_id DROP NOT NULL"

    create unique_index(:item_observations, [:source_id, :item_id, :period],
             nulls_distinct: false
           )

    create table(:settings) do
      add :key, :string, null: false
      add :value, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:settings, [:key])
  end

  def down do
    drop table(:settings)

    execute "DELETE FROM item_observations WHERE source_id IS NULL"
    drop unique_index(:item_observations, [:source_id, :item_id, :period])
    execute "ALTER TABLE item_observations ALTER COLUMN source_id SET NOT NULL"
    create unique_index(:item_observations, [:source_id, :item_id, :period])

    drop table(:item_labels)

    alter table(:items) do
      remove :details_fetched_at
      remove :details_error
    end
  end
end
