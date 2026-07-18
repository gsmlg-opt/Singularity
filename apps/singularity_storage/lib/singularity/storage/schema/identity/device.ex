defmodule Singularity.Storage.Schema.Identity.Device do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "identity"

  schema "devices" do
    field :principal_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :label, :string
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(device, attrs) do
    device
    |> cast(attrs, [:id, :principal_id, :vault_id, :label])
    |> validate_required([:id, :principal_id, :vault_id, :label])
    |> foreign_key_constraint(:principal_id, name: :devices_membership_fkey)
  end

  def revoke_changeset(device, attrs) do
    device
    |> cast(attrs, [:revoked_at])
    |> validate_required([:revoked_at])
  end
end
