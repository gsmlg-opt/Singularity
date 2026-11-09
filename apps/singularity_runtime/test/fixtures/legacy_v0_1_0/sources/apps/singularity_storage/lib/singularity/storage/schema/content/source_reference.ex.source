defmodule Singularity.Storage.Schema.Content.SourceReference do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "content"

  schema "source_references" do
    field :vault_id, Ecto.UUID
    field :resource_version_id, Ecto.UUID
    field :principal_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :kind, Ecto.Enum, values: [:browser_upload]
    field :observed_at, :utc_datetime_usec
    field :original_filename, :string
    field :declared_media_type, :string
    field :byte_size, :integer
    field :idempotency_key_digest, :binary
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(reference, attrs) do
    reference
    |> cast(attrs, [
      :id,
      :vault_id,
      :resource_version_id,
      :principal_id,
      :classification,
      :kind,
      :observed_at,
      :original_filename,
      :declared_media_type,
      :byte_size,
      :idempotency_key_digest
    ])
    |> validate_required([
      :id,
      :vault_id,
      :resource_version_id,
      :principal_id,
      :classification,
      :kind,
      :observed_at,
      :original_filename,
      :declared_media_type,
      :byte_size,
      :idempotency_key_digest
    ])
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:resource_version_id,
      name: :source_references_resource_version_vault_fkey
    )
    |> foreign_key_constraint(:principal_id, name: :source_references_membership_fkey)
    |> check_constraint(:classification, name: :source_references_classification_check)
    |> check_constraint(:kind, name: :source_references_kind_check)
    |> check_constraint(:byte_size, name: :source_references_byte_size_check)
    |> check_constraint(:idempotency_key_digest,
      name: :source_references_idempotency_digest_check
    )
  end
end
