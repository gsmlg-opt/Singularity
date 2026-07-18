defmodule Singularity.Storage.Schema.Content.Resource do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "content"

  schema "resources" do
    field :vault_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :title, :string
    field :deleted_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(resource, attrs) do
    resource
    |> cast(attrs, [:id, :vault_id, :classification, :title, :metadata])
    |> validate_required([:id, :vault_id, :classification, :title, :metadata])
    |> validate_change(:metadata, &string_keyed_json/2)
    |> foreign_key_constraint(:vault_id, name: :resources_vault_id_fkey)
    |> unique_constraint([:id, :vault_id], name: :resources_id_vault_id_key)
    |> check_constraint(:classification, name: :resources_classification_check)
    |> check_constraint(:title, name: :resources_title_check)
  end

  def tombstone_changeset(resource, attrs) do
    resource
    |> cast(attrs, [:deleted_at])
    |> validate_required([:deleted_at])
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
