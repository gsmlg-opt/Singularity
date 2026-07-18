defmodule Singularity.Storage.Schema.Audit.Event do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "audit"

  schema "events" do
    field :vault_id, Ecto.UUID
    field :actor_kind, Ecto.Enum, values: [:anonymous, :principal, :system]
    field :principal_id, Ecto.UUID
    field :anonymous_fingerprint, :binary
    field :operation, :string
    field :result, Ecto.Enum, values: [:allowed, :denied, :completed, :failed]
    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]
    field :correlation_id, Ecto.UUID
    field :target_type, :string
    field :target_id, Ecto.UUID
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def append_changeset(event, attrs) do
    event
    |> cast(attrs, [
      :id,
      :vault_id,
      :actor_kind,
      :principal_id,
      :anonymous_fingerprint,
      :operation,
      :result,
      :classification,
      :correlation_id,
      :target_type,
      :target_id,
      :metadata,
      :occurred_at
    ])
    |> validate_required([
      :id,
      :actor_kind,
      :operation,
      :result,
      :classification,
      :correlation_id,
      :metadata,
      :occurred_at
    ])
    |> validate_actor()
    |> validate_change(:metadata, &string_keyed_json/2)
    |> foreign_key_constraint(:principal_id, name: :events_actor_membership_fkey)
    |> check_constraint(:actor_kind, name: :events_actor_check)
    |> check_constraint(:result, name: :events_result_check)
    |> check_constraint(:classification, name: :events_classification_check)
  end

  defp validate_actor(changeset) do
    case get_field(changeset, :actor_kind) do
      :anonymous ->
        validate_required(changeset, [:anonymous_fingerprint])

      actor_kind when actor_kind in [:principal, :system] ->
        validate_required(changeset, [:principal_id, :vault_id])

      _other ->
        changeset
    end
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
