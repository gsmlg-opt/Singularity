defmodule Singularity.Storage.Schema.Core.VaultKeyVersion do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "core"

  schema "vault_key_versions" do
    field :vault_id, Ecto.UUID
    field :generation, :integer
    field :state, Ecto.Enum, values: [:pending, :active, :retired]
    field :algorithm, :string
    field :activated_at, :utc_datetime_usec
    field :retired_at, :utc_datetime_usec
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(vault_key_version, attrs) do
    vault_key_version
    |> cast(attrs, [
      :id,
      :vault_id,
      :generation,
      :state,
      :algorithm,
      :activated_at,
      :retired_at
    ])
    |> validate_required([:id, :vault_id, :generation, :state, :algorithm])
    |> validate_number(:generation, greater_than: 0)
    |> add_constraints()
  end

  def lifecycle_changeset(vault_key_version, attrs) do
    vault_key_version
    |> cast(attrs, [:state, :activated_at, :retired_at])
    |> validate_required([:state])
    |> add_constraints()
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:vault_id,
      name: :vault_key_versions_vault_id_fkey
    )
    |> unique_constraint([:id, :vault_id],
      name: :vault_key_versions_id_vault_id_key
    )
    |> unique_constraint([:vault_id, :generation],
      name: :vault_key_versions_vault_id_generation_key
    )
    |> unique_constraint(:vault_id, name: :vault_key_versions_one_active)
    |> check_constraint(:generation,
      name: :vault_key_versions_generation_check
    )
    |> check_constraint(:state, name: :vault_key_versions_state_check)
  end
end
