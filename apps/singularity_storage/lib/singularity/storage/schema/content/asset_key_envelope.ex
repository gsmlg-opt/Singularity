defmodule Singularity.Storage.Schema.Content.AssetKeyEnvelope do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "content"

  schema "asset_key_envelopes" do
    field :vault_id, Ecto.UUID
    field :asset_object_id, Ecto.UUID
    field :domain_key_version_id, Ecto.UUID
    field :key_domain_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :algorithm, :string
    field :key_generation, :integer
    field :wrapped_dek, :binary
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(envelope, attrs) do
    envelope
    |> cast(attrs, [
      :id,
      :vault_id,
      :asset_object_id,
      :domain_key_version_id,
      :key_domain_id,
      :classification,
      :algorithm,
      :key_generation,
      :wrapped_dek
    ])
    |> validate_required([
      :id,
      :vault_id,
      :asset_object_id,
      :domain_key_version_id,
      :key_domain_id,
      :classification,
      :algorithm,
      :key_generation,
      :wrapped_dek
    ])
    |> validate_number(:key_generation, greater_than: 0)
    |> foreign_key_constraint(:asset_object_id,
      name: :asset_key_envelopes_object_vault_fkey
    )
    |> foreign_key_constraint(:domain_key_version_id,
      name: :asset_key_envelopes_domain_version_vault_fkey
    )
    |> unique_constraint([:asset_object_id, :domain_key_version_id],
      name: :asset_key_envelopes_asset_object_id_domain_key_version_id_key
    )
    |> check_constraint(:classification, name: :asset_key_envelopes_classification_check)
    |> check_constraint(:key_generation, name: :asset_key_envelopes_generation_check)
  end
end
