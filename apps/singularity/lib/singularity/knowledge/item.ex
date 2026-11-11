defmodule Singularity.Knowledge.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @required [:kind, :external_id, :title, :url, :first_seen_at, :last_seen_at]

  schema "items" do
    field :kind, :string
    field :external_id, :string
    field :title, :string
    field :url, :string
    field :summary, :string
    field :published_at, :utc_datetime
    field :attributes, :map, default: %{}
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :details_fetched_at, :utc_datetime
    field :details_error, :string
    field :custom_title, :boolean, default: false
    field :removal_due_at, :utc_datetime
    has_many :observations, Singularity.Knowledge.Observation
    has_many :labels, Singularity.Knowledge.Label
    has_many :item_sources, Singularity.Knowledge.ItemSource
    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, @required ++ [:summary, :published_at, :attributes, :custom_title])
    |> validate_required(@required)
    |> unique_constraint([:kind, :external_id])
  end
end
