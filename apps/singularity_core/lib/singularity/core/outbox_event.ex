defmodule Singularity.Core.OutboxEvent do
  @moduledoc "A stable, versionable event awaiting durable job submission."

  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [
    :outbox_event_id,
    :event_type,
    :idempotency_key,
    :vault_id,
    :principal_id,
    :required_capability,
    :authorization_epoch,
    :classification,
    :correlation_id,
    :causation_id,
    :expected_entity_revision,
    :payload,
    :occurred_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          outbox_event_id: Types.id(),
          event_type: String.t(),
          idempotency_key: String.t(),
          vault_id: Types.id(),
          principal_id: Types.id(),
          required_capability: String.t(),
          authorization_epoch: non_neg_integer(),
          classification: Classification.t(),
          correlation_id: Types.id(),
          causation_id: Types.id(),
          expected_entity_revision: non_neg_integer(),
          payload: map(),
          occurred_at: Types.timestamp()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, outbox_event_id} <- Types.opaque_string(attrs, :outbox_event_id),
         {:ok, event_type} <- Types.normalized_string(attrs, :event_type),
         {:ok, idempotency_key} <- Types.normalized_string(attrs, :idempotency_key),
         {:ok, vault_id} <- Types.opaque_string(attrs, :vault_id),
         {:ok, principal_id} <- Types.opaque_string(attrs, :principal_id),
         {:ok, required_capability} <- Types.normalized_string(attrs, :required_capability),
         {:ok, authorization_epoch} <-
           Types.non_neg_integer(attrs, :authorization_epoch),
         {:ok, classification} <- Classification.new(Map.get(attrs, :classification)),
         {:ok, correlation_id} <- Types.opaque_string(attrs, :correlation_id),
         {:ok, causation_id} <- Types.opaque_string(attrs, :causation_id),
         {:ok, expected_entity_revision} <-
           Types.non_neg_integer(attrs, :expected_entity_revision),
         {:ok, payload} <- Types.string_map(Map.get(attrs, :payload)),
         {:ok, occurred_at} <- Types.utc_datetime(attrs, :occurred_at) do
      {:ok,
       struct!(__MODULE__,
         outbox_event_id: outbox_event_id,
         event_type: event_type,
         idempotency_key: idempotency_key,
         vault_id: vault_id,
         principal_id: principal_id,
         required_capability: required_capability,
         authorization_epoch: authorization_epoch,
         classification: classification,
         correlation_id: correlation_id,
         causation_id: causation_id,
         expected_entity_revision: expected_entity_revision,
         payload: payload,
         occurred_at: occurred_at
       )}
    end
  end
end
