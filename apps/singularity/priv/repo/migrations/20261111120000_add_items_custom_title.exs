defmodule Singularity.Repo.Migrations.AddItemsCustomTitle do
  use Ecto.Migration

  def change do
    alter table(:items) do
      # A title the user typed when adding the project; details fetches keep it.
      add :custom_title, :boolean, null: false, default: false
    end
  end
end
