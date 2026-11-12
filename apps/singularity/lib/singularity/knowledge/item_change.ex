defmodule Singularity.Knowledge.ItemChange do
  @moduledoc """
  What one collection run changed about one item: `added` (the source started
  keeping it), `updated` (authoritative fields or content changed) or `removed`
  (it left the source). `kind`, `external_id` and `title` are snapshots, so the
  record reads well after the item is deleted.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @changes ~w(added updated removed)

  schema "item_changes" do
    belongs_to :fetch_run, Singularity.Collection.FetchRun
    belongs_to :item, Singularity.Knowledge.Item
    field :kind, :string
    field :external_id, :string
    field :title, :string
    field :change, :string
    field :fields, :map, default: %{}
    field :content_diff, :string
    field :inserted_at, :utc_datetime
  end

  @spec changes() :: [String.t()]
  def changes, do: @changes
end
