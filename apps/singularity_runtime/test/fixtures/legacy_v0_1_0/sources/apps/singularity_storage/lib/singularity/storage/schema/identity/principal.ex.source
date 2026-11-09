defmodule Singularity.Storage.Schema.Identity.Principal do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "identity"

  schema "principals" do
    field :account_id, Ecto.UUID
    field :kind, Ecto.Enum, values: [:owner, :system]
    field :authorization_epoch, :integer, default: 0
    field :revoked_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(principal, attrs) do
    principal
    |> cast(attrs, [:id, :account_id, :kind, :authorization_epoch, :metadata])
    |> validate_required([:id, :account_id, :kind, :authorization_epoch, :metadata])
    |> validate_number(:authorization_epoch, greater_than_or_equal_to: 0)
    |> validate_change(:metadata, &string_keyed_json/2)
    |> foreign_key_constraint(:account_id, name: :principals_account_id_fkey)
    |> check_constraint(:kind, name: :principals_kind_check)
    |> check_constraint(:authorization_epoch, name: :principals_authorization_epoch_check)
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
