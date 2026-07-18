defmodule Singularity.Storage.Schema.Content.Tombstone do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "content"

  schema "tombstones" do
    field :vault_id, Ecto.UUID
    field :asset_id, Ecto.UUID
    field :principal_id, Ecto.UUID
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :reason, :string
    field :retention_metadata, :map, default: %{}
    field :deleted_at, :utc_datetime_usec
  end

  def create_changeset(tombstone, attrs) do
    tombstone
    |> cast(attrs, [
      :id,
      :vault_id,
      :asset_id,
      :principal_id,
      :classification,
      :reason,
      :retention_metadata,
      :deleted_at
    ])
    |> validate_required([
      :id,
      :vault_id,
      :asset_id,
      :principal_id,
      :classification,
      :reason,
      :retention_metadata,
      :deleted_at
    ])
    |> validate_change(:retention_metadata, &string_keyed_json/2)
    |> foreign_key_constraint(:asset_id, name: :tombstones_asset_vault_fkey)
    |> foreign_key_constraint(:principal_id, name: :tombstones_membership_fkey)
    |> check_constraint(:classification, name: :tombstones_classification_check)
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
