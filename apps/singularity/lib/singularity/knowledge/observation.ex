defmodule Singularity.Knowledge.Observation do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @required [:item_id, :period, :observed_at]

  schema "item_observations" do
    belongs_to :item, Singularity.Knowledge.Item
    belongs_to :source, Singularity.Sources.Source
    field :period, :string
    field :observed_at, :utc_datetime
    field :rank, :integer
    field :attributes, :map, default: %{}
    field :raw, :map, default: %{}
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(observation, attrs) do
    observation
    |> cast(attrs, @required ++ [:source_id, :rank, :attributes, :raw])
    |> validate_required(@required)
    |> unique_constraint([:source_id, :item_id, :period])
  end
end
