defmodule Singularity.Storage.Schema.Core.DataClassification do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @schema_prefix "core"

  schema "data_classifications" do
    field :name, Ecto.Enum,
      values: [:private, :sensitive, :restricted],
      primary_key: true

    field :rank, :integer
  end

  def create_changeset(data_classification, attrs) do
    data_classification
    |> cast(attrs, [:name, :rank])
    |> validate_required([:name, :rank])
    |> validate_number(:rank, greater_than_or_equal_to: 0)
    |> unique_constraint(:name, name: :data_classifications_pkey)
    |> unique_constraint(:rank, name: :data_classifications_rank_key)
    |> check_constraint(:name, name: :data_classifications_name_check)
    |> check_constraint(:rank, name: :data_classifications_rank_check)
  end
end
