defmodule Singularity.Storage.Schema.Core.VaultMember do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @schema_prefix "core"

  schema "vault_members" do
    field :principal_id, Ecto.UUID, primary_key: true
    field :vault_id, Ecto.UUID, primary_key: true

    field :clearance, Ecto.Enum,
      values: [:private, :sensitive, :restricted],
      default: :private

    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(vault_member, attrs) do
    vault_member
    |> cast(attrs, [:principal_id, :vault_id, :clearance])
    |> validate_required([:principal_id, :vault_id, :clearance])
    |> foreign_key_constraint(:principal_id,
      name: :vault_members_principal_id_fkey
    )
    |> foreign_key_constraint(:vault_id, name: :vault_members_vault_id_fkey)
    |> unique_constraint([:principal_id, :vault_id], name: :vault_members_pkey)
    |> check_constraint(:clearance,
      name: :vault_members_classification_check
    )
  end

  def revoke_changeset(vault_member, attrs) do
    vault_member
    |> cast(attrs, [:revoked_at])
    |> validate_required([:revoked_at])
  end
end
