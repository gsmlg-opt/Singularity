defmodule Singularity.Storage.Schema.Identity.Person do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "identity"

  schema "people" do
    field :display_name, :string
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(person, attrs) do
    person
    |> cast(attrs, [:id, :display_name, :metadata])
    |> validate_required([:id, :display_name, :metadata])
    |> validate_change(:metadata, &string_keyed_json/2)
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
