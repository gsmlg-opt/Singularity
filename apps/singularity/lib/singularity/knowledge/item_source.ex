defmodule Singularity.Knowledge.ItemSource do
  @moduledoc """
  How an item entered the knowledge base: one row per source that added it
  (`source_id` nil = added by hand). `removed_at` is set when a complete-list
  source stops listing the item.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "item_sources" do
    belongs_to :item, Singularity.Knowledge.Item
    belongs_to :source, Singularity.Sources.Source
    field :added_at, :utc_datetime
    field :removed_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
