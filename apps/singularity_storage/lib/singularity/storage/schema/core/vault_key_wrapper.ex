defmodule Singularity.Storage.Schema.Core.VaultKeyWrapper do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "core"

  schema "vault_key_wrappers" do
    field :vault_id, Ecto.UUID
    field :vault_key_version_id, Ecto.UUID
    field :account_id, Ecto.UUID
    field :kdf_version, :integer
    field :kdf_salt, :binary
    field :kdf_parameters, :map
    field :wrapper_algorithm, :string
    field :wrapped_key, :binary
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(vault_key_wrapper, attrs) do
    vault_key_wrapper
    |> cast(attrs, [
      :id,
      :vault_id,
      :vault_key_version_id,
      :account_id,
      :kdf_version,
      :kdf_salt,
      :kdf_parameters,
      :wrapper_algorithm,
      :wrapped_key
    ])
    |> validate_required([
      :id,
      :vault_id,
      :vault_key_version_id,
      :account_id,
      :kdf_version,
      :kdf_salt,
      :kdf_parameters,
      :wrapper_algorithm,
      :wrapped_key
    ])
    |> validate_number(:kdf_version, greater_than: 0)
    |> validate_change(:kdf_parameters, &string_keyed_json/2)
    |> foreign_key_constraint(:vault_key_version_id,
      name: :vault_key_wrappers_version_fkey
    )
    |> foreign_key_constraint(:account_id,
      name: :vault_key_wrappers_account_id_fkey
    )
    |> check_constraint(:kdf_version,
      name: :vault_key_wrappers_kdf_version_check
    )
  end

  defp string_keyed_json(field, value) do
    if json_value?(value),
      do: [],
      else: [{field, "must use string keys and JSON values"}]
  end

  defp json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and json_value?(nested)
    end)
  end

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  defp json_value?(value) when is_binary(value) or is_number(value), do: true
  defp json_value?(value) when is_boolean(value) or is_nil(value), do: true
  defp json_value?(_value), do: false
end
