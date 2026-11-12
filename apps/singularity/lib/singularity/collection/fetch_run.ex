defmodule Singularity.Collection.FetchRun do
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "fetch_runs" do
    belongs_to :source, Singularity.Sources.Source
    field :status, :string
    field :item_count, :integer, default: 0
    field :skipped_count, :integer, default: 0
    field :added_count, :integer, default: 0
    field :updated_count, :integer, default: 0
    field :removed_count, :integer, default: 0
    field :error, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
  end
end
