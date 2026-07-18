defmodule Singularity.Storage.Schema.Content.ResourceAsset do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @schema_prefix "content"

  schema "resource_assets" do
    field :resource_version_id, Ecto.UUID, primary_key: true
    field :asset_id, Ecto.UUID, primary_key: true
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :released_at, :utc_datetime_usec
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(reference, attrs) do
    reference
    |> cast(attrs, [:resource_version_id, :asset_id, :vault_id, :classification])
    |> validate_required([:resource_version_id, :asset_id, :vault_id, :classification])
    |> foreign_key_constraint(:resource_version_id,
      name: :resource_assets_resource_version_vault_fkey
    )
    |> foreign_key_constraint(:asset_id, name: :resource_assets_asset_vault_fkey)
    |> unique_constraint([:resource_version_id, :asset_id],
      name: :resource_assets_pkey
    )
    |> check_constraint(:classification, name: :resource_assets_classification_check)
  end

  def release_changeset(reference, attrs) do
    reference
    |> cast(attrs, [:released_at])
    |> validate_required([:released_at])
  end
end
