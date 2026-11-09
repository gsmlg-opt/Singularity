defmodule Singularity.Sources.Source do
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "sources" do
    field :kind, :string
    field :name, :string
    field :config, :map, default: %{}
    field :enabled, :boolean, default: true
    field :interval_minutes, :integer
    field :next_run_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
