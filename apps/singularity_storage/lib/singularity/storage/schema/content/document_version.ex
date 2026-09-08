defmodule Singularity.Storage.Schema.Content.DocumentVersion do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:resource_version_id, Ecto.UUID, autogenerate: false}
  @schema_prefix "content"
  @source_fields [
    :resource_version_id,
    :resource_id,
    :vault_id,
    :classification,
    :source_asset_id,
    :source_resource_id,
    :source_resource_version_id,
    :source_object_id,
    :source_digest,
    :source_byte_size,
    :media_type,
    :title,
    :created_by_principal_id,
    :inserted_at
  ]

  schema "document_versions" do
    field :resource_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private]
    field :source_asset_id, Ecto.UUID
    field :source_resource_id, Ecto.UUID
    field :source_resource_version_id, Ecto.UUID
    field :source_object_id, Ecto.UUID
    field :source_digest, :binary
    field :source_byte_size, :integer
    field :media_type, :string
    field :title, :string
    field :created_by_principal_id, Ecto.UUID
    field :state, Ecto.Enum, values: [:pending, :extracting, :ready, :failed, :unsupported]
    field :attempt_generation, :integer
    field :extraction_adapter, :string
    field :extraction_format, :integer
    field :extracted_text_digest, :binary
    field :detected_language, :string
    field :failure_code, :string
    field :attempt_finished_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  def create_changeset(document_version, attrs) do
    document_version
    |> cast(attrs, @source_fields)
    |> put_change(:state, :pending)
    |> put_change(:attempt_generation, 0)
    |> validate_required(@source_fields ++ [:state, :attempt_generation])
    |> validate_inclusion(:classification, [:private])
    |> validate_length(:source_digest, is: 32, count: :bytes)
    |> validate_number(:source_byte_size,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 67_108_864
    )
    |> validate_inclusion(:media_type, ["application/pdf", "text/markdown", "text/plain"])
    |> validate_length(:title, max: 255, count: :bytes)
    |> unique_constraint(:resource_version_id, name: :document_versions_pkey)
    |> unique_constraint([:resource_version_id, :resource_id, :vault_id, :classification],
      name: :document_versions_identity_aggregate_key
    )
    |> unique_constraint([:resource_version_id, :resource_id, :vault_id],
      name: :document_versions_receipt_identity_key
    )
    |> foreign_key_constraint(:resource_version_id,
      name: :document_versions_resource_version_fkey
    )
    |> foreign_key_constraint(:source_asset_id, name: :document_versions_source_asset_fkey)
    |> foreign_key_constraint(:source_resource_version_id,
      name: :document_versions_source_version_fkey
    )
    |> foreign_key_constraint(:source_asset_id, name: :document_versions_source_association_fkey)
    |> foreign_key_constraint(:source_object_id, name: :document_versions_source_object_fkey)
    |> foreign_key_constraint(:created_by_principal_id,
      name: :document_versions_created_by_membership_fkey
    )
    |> check_constraint(:classification, name: :document_versions_private_check)
    |> check_constraint(:source_digest, name: :document_versions_source_digest_check)
    |> check_constraint(:source_byte_size, name: :document_versions_source_byte_size_check)
    |> check_constraint(:media_type, name: :document_versions_media_type_check)
    |> check_constraint(:title, name: :document_versions_title_check)
    |> check_constraint(:state, name: :document_versions_state_check)
    |> check_constraint(:attempt_generation, name: :document_versions_attempt_generation_check)
    |> check_constraint(:source_asset_id, name: :document_versions_source_check)
    |> check_constraint(:resource_id, name: :resources_typed_head_check)
    |> check_constraint(:resource_id, name: :knowledge_versions_resource_kind_check)
  end
end
