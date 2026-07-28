defmodule Singularity.Storage.Schema.Content.UploadGrant do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "content"

  schema "upload_grants" do
    field :vault_id, Ecto.UUID
    field :session_id, Ecto.UUID
    field :principal_id, Ecto.UUID
    field :asset_id, Ecto.UUID
    field :source_reference_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :token_digest, :binary
    field :csrf_token_digest, :binary
    field :filename, :string
    field :byte_size, :integer
    field :declared_media_type, :string
    field :idempotency_key, :string
    field :principal_authorization_epoch, :integer
    field :vault_authorization_epoch, :integer
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :id,
      :vault_id,
      :session_id,
      :principal_id,
      :asset_id,
      :source_reference_id,
      :classification,
      :token_digest,
      :csrf_token_digest,
      :filename,
      :byte_size,
      :declared_media_type,
      :idempotency_key,
      :principal_authorization_epoch,
      :vault_authorization_epoch,
      :expires_at
    ])
    |> validate_required([
      :id,
      :vault_id,
      :session_id,
      :principal_id,
      :asset_id,
      :classification,
      :token_digest,
      :csrf_token_digest,
      :filename,
      :byte_size,
      :declared_media_type,
      :idempotency_key,
      :principal_authorization_epoch,
      :vault_authorization_epoch,
      :expires_at
    ])
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> validate_number(:principal_authorization_epoch, greater_than_or_equal_to: 0)
    |> validate_number(:vault_authorization_epoch, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:session_id, name: :upload_grants_session_vault_fkey)
    |> foreign_key_constraint(:principal_id, name: :upload_grants_membership_fkey)
    |> foreign_key_constraint(:asset_id, name: :upload_grants_asset_vault_fkey)
    |> foreign_key_constraint(:source_reference_id,
      name: :upload_grants_source_reference_vault_fkey
    )
    |> unique_constraint(:token_digest, name: :upload_grants_token_digest_key)
    |> unique_constraint([:vault_id, :idempotency_key],
      name: :upload_grants_active_idempotency_key
    )
    |> check_constraint(:classification, name: :upload_grants_classification_check)
    |> check_constraint(:token_digest, name: :upload_grants_token_digest_check)
    |> check_constraint(:csrf_token_digest, name: :upload_grants_csrf_token_digest_check)
    |> check_constraint(:byte_size, name: :upload_grants_byte_size_check)
    |> check_constraint(:principal_authorization_epoch,
      name: :upload_grants_principal_authorization_epoch_check
    )
    |> check_constraint(:vault_authorization_epoch,
      name: :upload_grants_vault_authorization_epoch_check
    )
  end

  def consume_changeset(grant, attrs) do
    grant
    |> cast(attrs, [:consumed_at])
    |> validate_required([:consumed_at])
  end
end
