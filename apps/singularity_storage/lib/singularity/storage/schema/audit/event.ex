defmodule Singularity.Storage.Schema.Audit.Event do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "audit"
  @redacted_value "[REDACTED]"
  @sensitive_metadata_keys MapSet.new(~w[
    password
    passphrase
    backup_passphrase
    token
    upload_token
    csrf
    csrf_token
    audit_fingerprint_secret
    vault_key
    domain_key
    domain_dedup_key
    dek
    plaintext
    authorization
    cookie
    path
  ])

  schema "events" do
    field :vault_id, Ecto.UUID
    field :actor_kind, Ecto.Enum, values: [:anonymous, :principal, :system]
    field :principal_id, Ecto.UUID
    field :anonymous_fingerprint, :binary
    field :system_principal_name, :string
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
    attrs = sanitize_metadata(attrs)

    event
    |> cast(attrs, [
      :id,
      :vault_id,
      :actor_kind,
      :principal_id,
      :anonymous_fingerprint,
      :system_principal_name,
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
      :target_type,
      :target_id,
      :occurred_at
    ])
    |> validate_actor()
    |> validate_length(:anonymous_fingerprint, is: 32, count: :bytes)
    |> validate_length(:system_principal_name, min: 1)
    |> validate_change(:metadata, &string_keyed_json/2)
    |> foreign_key_constraint(:principal_id, name: :events_actor_membership_fkey)
    |> check_constraint(:actor_kind, name: :events_actor_check)
    |> check_constraint(:target_type, name: :events_target_check)
    |> check_constraint(:result, name: :events_result_check)
    |> check_constraint(:classification, name: :events_classification_check)
  end

  defp validate_actor(changeset) do
    case get_field(changeset, :actor_kind) do
      :anonymous ->
        changeset
        |> validate_required([:anonymous_fingerprint])
        |> validate_absent([:principal_id, :vault_id, :system_principal_name])

      :principal ->
        changeset
        |> validate_required([:principal_id, :vault_id])
        |> validate_absent([:anonymous_fingerprint, :system_principal_name])

      :system ->
        changeset
        |> validate_required([:system_principal_name, :vault_id])
        |> validate_absent([:principal_id, :anonymous_fingerprint])

      _other ->
        changeset
    end
  end

  defp validate_absent(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, checked_changeset ->
      if is_nil(get_field(checked_changeset, field)) do
        checked_changeset
      else
        add_error(checked_changeset, field, "must be absent for this actor kind")
      end
    end)
  end

  defp sanitize_metadata(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :metadata) ->
        Map.update!(attrs, :metadata, &redact_metadata/1)

      Map.has_key?(attrs, "metadata") ->
        Map.update!(attrs, "metadata", &redact_metadata/1)

      true ->
        attrs
    end
  end

  defp sanitize_metadata(attrs), do: attrs

  defp redact_metadata(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_metadata_key?(key),
        do: {key, @redacted_value},
        else: {key, redact_metadata(nested)}
    end)
  end

  defp redact_metadata(value) when is_list(value),
    do: Enum.map(value, &redact_metadata/1)

  defp redact_metadata(value), do: value

  defp sensitive_metadata_key?(key) when is_atom(key) or is_binary(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")

    MapSet.member?(@sensitive_metadata_keys, normalized)
  end

  defp sensitive_metadata_key?(_key), do: false

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
