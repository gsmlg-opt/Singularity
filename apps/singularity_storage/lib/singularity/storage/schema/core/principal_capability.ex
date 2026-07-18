defmodule Singularity.Storage.Schema.Core.PrincipalCapability do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @schema_prefix "core"

  schema "principal_capabilities" do
    field :principal_id, Ecto.UUID, primary_key: true
    field :vault_id, Ecto.UUID, primary_key: true
    field :capability_id, Ecto.UUID, primary_key: true
    field :revoked_at, :utc_datetime_usec
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(principal_capability, attrs) do
    principal_capability
    |> cast(attrs, [:principal_id, :vault_id, :capability_id])
    |> validate_required([:principal_id, :vault_id, :capability_id])
    |> foreign_key_constraint(:capability_id,
      name: :principal_capabilities_capability_id_fkey
    )
    |> foreign_key_constraint(:principal_id,
      name: :principal_capabilities_membership_fkey
    )
    |> unique_constraint([:principal_id, :vault_id, :capability_id],
      name: :principal_capabilities_pkey
    )
  end

  def revoke_changeset(principal_capability, attrs) do
    principal_capability
    |> cast(attrs, [:revoked_at])
    |> validate_required([:revoked_at])
  end
end
