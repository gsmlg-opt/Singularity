defmodule Singularity.Storage.Schema.Core.Capability do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "core"

  schema "capabilities" do
    field :name, :string
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(capability, attrs) do
    capability
    |> cast(attrs, [:id, :name])
    |> validate_required([:id, :name])
    |> unique_constraint(:name, name: :capabilities_name_key)
    |> check_constraint(:name, name: :capabilities_name_check)
  end
end
