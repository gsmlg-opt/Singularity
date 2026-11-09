defmodule Singularity.Storage.Schema.Core.KeyDomain do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "core"

  schema "key_domains" do
    field :vault_id, Ecto.UUID

    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]

    field :kind, :string, default: "content"
    field :state, Ecto.Enum, values: [:active, :retired], default: :active
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(key_domain, attrs) do
    key_domain
    |> cast(attrs, [:id, :vault_id, :classification, :kind, :state])
    |> validate_required([:id, :vault_id, :classification, :kind, :state])
    |> foreign_key_constraint(:vault_id, name: :key_domains_vault_id_fkey)
    |> unique_constraint([:id, :vault_id], name: :key_domains_id_vault_id_key)
    |> check_constraint(:classification,
      name: :key_domains_classification_check
    )
    |> check_constraint(:state, name: :key_domains_state_check)
  end

  def state_changeset(key_domain, attrs) do
    key_domain
    |> cast(attrs, [:state])
    |> validate_required([:state])
    |> check_constraint(:state, name: :key_domains_state_check)
  end
end
