defmodule Singularity.Storage.Schema.Content.AssetSearchDocument do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:asset_id, Ecto.UUID, autogenerate: false}
  @schema_prefix "content"
  @states [
    :staging,
    :uploaded,
    :verified,
    :available,
    :processing,
    :ready,
    :pending_delete,
    :deleted
  ]

  schema "asset_search_documents" do
    field :resource_version_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :state, Ecto.Enum, values: @states
    field :detected_media_type, :string
    field :resource_title, :string
    field :original_filename, :string
    timestamps(inserted_at: false, type: :utc_datetime_usec)
  end

  def upsert_changeset(document, attrs) do
    document
    |> cast(attrs, [
      :asset_id,
      :resource_version_id,
      :vault_id,
      :classification,
      :state,
      :detected_media_type,
      :resource_title,
      :original_filename
    ])
    |> validate_required([
      :asset_id,
      :resource_version_id,
      :vault_id,
      :classification,
      :state,
      :resource_title,
      :original_filename
    ])
    |> foreign_key_constraint(:asset_id,
      name: :asset_search_documents_asset_vault_fkey
    )
    |> foreign_key_constraint(:resource_version_id,
      name: :asset_search_documents_resource_version_vault_fkey
    )
    |> check_constraint(:classification,
      name: :asset_search_documents_classification_check
    )
    |> check_constraint(:state, name: :asset_search_documents_state_check)
  end
end
