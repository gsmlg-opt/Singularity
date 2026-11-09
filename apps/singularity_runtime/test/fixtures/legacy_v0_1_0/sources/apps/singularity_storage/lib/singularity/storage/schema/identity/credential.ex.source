defmodule Singularity.Storage.Schema.Identity.Credential do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "identity"

  schema "credentials" do
    field :account_id, Ecto.UUID
    field :normalized_login, :string
    field :verifier, :string
    field :verifier_version, :integer, default: 1
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :id,
      :account_id,
      :normalized_login,
      :verifier,
      :verifier_version
    ])
    |> validate_required([
      :id,
      :account_id,
      :normalized_login,
      :verifier,
      :verifier_version
    ])
    |> validate_number(:verifier_version, greater_than: 0)
    |> validate_change(:normalized_login, fn :normalized_login, login ->
      if login == login |> String.trim() |> String.downcase(),
        do: [],
        else: [normalized_login: "must be normalized"]
    end)
    |> unique_constraint(:id, name: :credentials_pkey)
    |> foreign_key_constraint(:account_id, name: :credentials_account_id_fkey)
    |> unique_constraint(:normalized_login, name: :credentials_normalized_login_key)
    |> check_constraint(:normalized_login, name: :credentials_login_check)
    |> check_constraint(:verifier_version, name: :credentials_verifier_version_check)
  end
end
