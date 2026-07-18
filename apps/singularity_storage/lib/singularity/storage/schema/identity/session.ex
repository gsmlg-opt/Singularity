defmodule Singularity.Storage.Schema.Identity.Session do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "identity"

  schema "sessions" do
    field :account_id, Ecto.UUID
    field :credential_id, Ecto.UUID
    field :principal_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :token_digest, :binary
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :id,
      :account_id,
      :credential_id,
      :principal_id,
      :vault_id,
      :token_digest,
      :expires_at
    ])
    |> validate_required([
      :id,
      :account_id,
      :credential_id,
      :principal_id,
      :vault_id,
      :token_digest,
      :expires_at
    ])
    |> validate_change(:token_digest, &validate_digest/2)
    |> foreign_key_constraint(:account_id, name: :sessions_account_id_fkey)
    |> foreign_key_constraint(:credential_id, name: :sessions_credential_id_fkey)
    |> foreign_key_constraint(:principal_id, name: :sessions_membership_fkey)
    |> unique_constraint(:token_digest, name: :sessions_token_digest_key)
    |> unique_constraint([:id, :vault_id], name: :sessions_id_vault_id_key)
    |> check_constraint(:token_digest, name: :sessions_token_digest_check)
  end

  def revoke_changeset(session, attrs) do
    session
    |> cast(attrs, [:revoked_at])
    |> validate_required([:revoked_at])
  end

  defp validate_digest(field, digest) do
    if is_binary(digest) and byte_size(digest) == 32,
      do: [],
      else: [{field, "must be exactly 32 bytes"}]
  end
end
