defmodule Singularity.Storage.Schema.Identity.Account do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "identity"

  schema "accounts" do
    field :person_id, Ecto.UUID
    field :status, Ecto.Enum, values: [:active, :disabled], default: :active
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(account, attrs) do
    account
    |> cast(attrs, [:id, :person_id, :status, :metadata])
    |> validate_required([:id, :person_id, :status, :metadata])
    |> validate_change(:metadata, &string_keyed_json/2)
    |> foreign_key_constraint(:person_id, name: :accounts_person_id_fkey)
    |> check_constraint(:status, name: :accounts_status_check)
  end

  defp string_keyed_json(field, value) do
    if json_value?(value), do: [], else: [{field, "must use string keys and JSON values"}]
  end

  defp json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  defp json_value?(value) when is_binary(value) or is_number(value), do: true
  defp json_value?(value) when is_boolean(value) or is_nil(value), do: true
  defp json_value?(_value), do: false
end
