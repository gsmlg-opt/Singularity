defmodule Singularity.Storage.Schema.Core.OutboxEvent do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "core"

  schema "outbox_events" do
    field :sequence, :integer, read_after_writes: true
    field :event_type, :string
    field :idempotency_key, :string
    field :vault_id, Ecto.UUID
    field :principal_id, Ecto.UUID
    field :required_capability, :string
    field :principal_authorization_epoch, :integer
    field :vault_authorization_epoch, :integer

    field :classification, Ecto.Enum, values: [:private, :sensitive, :restricted]

    field :correlation_id, Ecto.UUID
    field :causation_id, Ecto.UUID
    field :expected_entity_revision, :integer
    field :envelope_version, :integer
    field :payload, :map
    field :occurred_at, :utc_datetime_usec
    field :claim_token, Ecto.UUID
    field :claimed_until, :utc_datetime_usec
    field :runner_job_id, :string
    field :delivered_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(outbox_event, attrs) do
    outbox_event
    |> cast(attrs, [
      :id,
      :event_type,
      :idempotency_key,
      :vault_id,
      :principal_id,
      :required_capability,
      :principal_authorization_epoch,
      :vault_authorization_epoch,
      :classification,
      :correlation_id,
      :causation_id,
      :expected_entity_revision,
      :envelope_version,
      :payload,
      :occurred_at
    ])
    |> validate_required([
      :id,
      :event_type,
      :idempotency_key,
      :vault_id,
      :principal_id,
      :required_capability,
      :principal_authorization_epoch,
      :vault_authorization_epoch,
      :classification,
      :correlation_id,
      :expected_entity_revision,
      :envelope_version,
      :payload,
      :occurred_at
    ])
    |> validate_number(:principal_authorization_epoch, greater_than_or_equal_to: 0)
    |> validate_number(:vault_authorization_epoch, greater_than_or_equal_to: 0)
    |> validate_number(:expected_entity_revision, greater_than_or_equal_to: 0)
    |> validate_number(:envelope_version, greater_than: 0)
    |> validate_change(:payload, &string_keyed_json/2)
    |> foreign_key_constraint(:principal_id,
      name: :outbox_events_membership_fkey
    )
    |> unique_constraint([:id, :vault_id],
      name: :outbox_events_id_vault_id_key
    )
    |> unique_constraint([:vault_id, :idempotency_key],
      name: :outbox_events_vault_id_idempotency_key_key
    )
    |> check_constraint(:classification,
      name: :outbox_events_classification_check
    )
    |> check_constraint(:principal_authorization_epoch,
      name: :outbox_events_principal_authorization_epoch_check
    )
    |> check_constraint(:vault_authorization_epoch,
      name: :outbox_events_vault_authorization_epoch_check
    )
    |> check_constraint(:expected_entity_revision,
      name: :outbox_events_expected_revision_check
    )
    |> check_constraint(:envelope_version,
      name: :outbox_events_envelope_version_check
    )
    |> check_constraint(:claim_token,
      name: :outbox_events_claim_shape_check
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
