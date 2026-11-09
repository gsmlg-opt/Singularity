defmodule Singularity.Storage.Schema.Core.DomainKeyVersion do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "core"

  schema "domain_key_versions" do
    field :vault_id, Ecto.UUID
    field :key_domain_id, Ecto.UUID
    field :vault_key_version_id, Ecto.UUID
    field :generation, :integer
    field :state, Ecto.Enum, values: [:pending, :active, :retired]
    field :algorithm, :string
    field :wrapped_key, :binary
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(domain_key_version, attrs) do
    domain_key_version
    |> cast(attrs, [
      :id,
      :vault_id,
      :key_domain_id,
      :vault_key_version_id,
      :generation,
      :state,
      :algorithm,
      :wrapped_key
    ])
    |> validate_required([
      :id,
      :vault_id,
      :key_domain_id,
      :vault_key_version_id,
      :generation,
      :state,
      :algorithm,
      :wrapped_key
    ])
    |> validate_number(:generation, greater_than: 0)
    |> add_constraints()
  end

  def lifecycle_changeset(domain_key_version, attrs) do
    domain_key_version
    |> cast(attrs, [:state])
    |> validate_required([:state])
    |> add_constraints()
  end

  defp add_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:key_domain_id,
      name: :domain_key_versions_domain_fkey
    )
    |> foreign_key_constraint(:vault_key_version_id,
      name: :domain_key_versions_vault_key_fkey
    )
    |> unique_constraint([:id, :vault_id],
      name: :domain_key_versions_id_vault_id_key
    )
    |> unique_constraint([:id, :vault_id, :key_domain_id],
      name: :domain_key_versions_id_vault_id_key_domain_id_key
    )
    |> unique_constraint([:key_domain_id, :generation],
      name: :domain_key_versions_key_domain_id_generation_key
    )
    |> check_constraint(:generation,
      name: :domain_key_versions_generation_check
    )
    |> check_constraint(:state, name: :domain_key_versions_state_check)
  end
end
