defmodule Singularity.Storage.Schema.Core.DomainDedupKeyWrapper do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "core"

  schema "domain_dedup_key_wrappers" do
    field :vault_id, Ecto.UUID
    field :key_domain_id, Ecto.UUID
    field :domain_key_version_id, Ecto.UUID
    field :algorithm, :string
    field :wrapped_key, :binary
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(domain_dedup_key_wrapper, attrs) do
    domain_dedup_key_wrapper
    |> cast(attrs, [
      :id,
      :vault_id,
      :key_domain_id,
      :domain_key_version_id,
      :algorithm,
      :wrapped_key
    ])
    |> validate_required([
      :id,
      :vault_id,
      :key_domain_id,
      :domain_key_version_id,
      :algorithm,
      :wrapped_key
    ])
    |> foreign_key_constraint(:key_domain_id,
      name: :domain_dedup_key_wrappers_domain_fkey
    )
    |> foreign_key_constraint(:domain_key_version_id,
      name: :domain_dedup_key_wrappers_version_fkey
    )
  end
end
