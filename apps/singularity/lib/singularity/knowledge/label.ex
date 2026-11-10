defmodule Singularity.Knowledge.Label do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @origins ~w(auto manual)

  schema "item_labels" do
    belongs_to :item, Singularity.Knowledge.Item
    field :name, :string
    field :origin, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [:item_id, :name, :origin])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:item_id, :name, :origin])
    |> validate_length(:name, max: 100)
    |> validate_inclusion(:origin, @origins)
    |> unique_constraint([:item_id, :name])
  end

  @doc "Labels are compared trimmed and lowercased."
  @spec normalize_name(String.t()) :: String.t()
  def normalize_name(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
end
