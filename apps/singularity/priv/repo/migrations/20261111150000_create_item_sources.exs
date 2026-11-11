defmodule Singularity.Repo.Migrations.CreateItemSources do
  use Ecto.Migration

  def up do
    create table(:item_sources) do
      add :item_id, references(:items, on_delete: :delete_all), null: false
      add :source_id, references(:sources, on_delete: :delete_all)
      add :added_at, :utc_datetime, null: false
      add :removed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    # Manual additions have no source; NULLS NOT DISTINCT keeps one row per item.
    create unique_index(:item_sources, [:item_id, :source_id], nulls_distinct: false)
    create index(:item_sources, [:source_id])

    alter table(:items) do
      add :removal_due_at, :utc_datetime
    end

    create index(:items, [:removal_due_at])

    # Every existing source record means that source added the item.
    execute """
    INSERT INTO item_sources (item_id, source_id, added_at, inserted_at, updated_at)
    SELECT item_id, source_id, min(observed_at), now(), now()
    FROM item_observations
    GROUP BY item_id, source_id
    """
  end

  def down do
    alter table(:items) do
      remove :removal_due_at
    end

    drop table(:item_sources)
  end
end
