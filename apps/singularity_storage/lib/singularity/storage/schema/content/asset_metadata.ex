defmodule Singularity.Storage.Schema.Content.AssetMetadata do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "content"

  schema "asset_metadata" do
    field :asset_id, Ecto.UUID
    field :resource_version_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :projection_version, :integer
    field :original_filename, :string
    field :declared_media_type, :string
    field :detected_media_type, :string
    field :plaintext_byte_size, :integer
    field :pdf_header_version, :string
    field :image_width, :integer
    field :image_height, :integer
    field :extraction_state, Ecto.Enum, values: [:pending, :completed, :failed]
    field :extractor_version, :string
    field :completed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def upsert_changeset(metadata, attrs) do
    metadata
    |> cast(attrs, [
      :id,
      :asset_id,
      :resource_version_id,
      :vault_id,
      :classification,
      :projection_version,
      :original_filename,
      :declared_media_type,
      :detected_media_type,
      :plaintext_byte_size,
      :pdf_header_version,
      :image_width,
      :image_height,
      :extraction_state,
      :extractor_version,
      :completed_at
    ])
    |> validate_required([
      :id,
      :asset_id,
      :resource_version_id,
      :vault_id,
      :classification,
      :projection_version,
      :original_filename,
      :declared_media_type,
      :plaintext_byte_size,
      :extraction_state
    ])
    |> validate_number(:projection_version, greater_than: 0)
    |> validate_number(:plaintext_byte_size, greater_than_or_equal_to: 0)
    |> validate_number(:image_width, greater_than: 0)
    |> validate_number(:image_height, greater_than: 0)
    |> foreign_key_constraint(:asset_id, name: :asset_metadata_asset_vault_fkey)
    |> foreign_key_constraint(:resource_version_id,
      name: :asset_metadata_resource_version_vault_fkey
    )
    |> unique_constraint(:asset_id, name: :asset_metadata_asset_id_key)
    |> check_constraint(:classification, name: :asset_metadata_classification_check)
    |> check_constraint(:projection_version, name: :asset_metadata_projection_version_check)
    |> check_constraint(:plaintext_byte_size, name: :asset_metadata_plaintext_size_check)
    |> check_constraint(:image_width, name: :asset_metadata_dimensions_check)
    |> check_constraint(:extraction_state, name: :asset_metadata_extraction_state_check)
  end
end
