defmodule Singularity.Core.JobEnvelope do
  @moduledoc "A versioned durable-job value carrying explicit authority and concurrency context."

  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @required_fields ~w[
    version job_id job_type idempotency_key vault_id principal_id
    required_capability principal_authorization_epoch vault_authorization_epoch
    classification correlation_id causation_id expected_entity_revision attempt payload
  ]a

  @enforce_keys @required_fields
  defstruct @required_fields

  @type t :: %__MODULE__{
          version: pos_integer(),
          job_id: Types.id(),
          job_type: String.t(),
          idempotency_key: String.t(),
          vault_id: Types.id(),
          principal_id: Types.id(),
          required_capability: String.t(),
          principal_authorization_epoch: non_neg_integer(),
          vault_authorization_epoch: non_neg_integer(),
          classification: Classification.t(),
          correlation_id: Types.id(),
          causation_id: Types.id(),
          expected_entity_revision: non_neg_integer(),
          attempt: non_neg_integer(),
          payload: map()
        }

  @spec required_fields() :: [atom()]
  def required_fields, do: @required_fields

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, version} <- Types.pos_integer(attrs, :version),
         {:ok, job_id} <- Types.opaque_string(attrs, :job_id),
         {:ok, job_type} <- Types.normalized_string(attrs, :job_type),
         {:ok, idempotency_key} <- Types.normalized_string(attrs, :idempotency_key),
         {:ok, vault_id} <- Types.opaque_string(attrs, :vault_id),
         {:ok, principal_id} <- Types.opaque_string(attrs, :principal_id),
         {:ok, required_capability} <- Types.normalized_string(attrs, :required_capability),
         {:ok, principal_authorization_epoch} <-
           Types.non_neg_integer(attrs, :principal_authorization_epoch),
         {:ok, vault_authorization_epoch} <-
           Types.non_neg_integer(attrs, :vault_authorization_epoch),
         {:ok, classification} <- Classification.new(Map.get(attrs, :classification)),
         {:ok, correlation_id} <- Types.opaque_string(attrs, :correlation_id),
         {:ok, causation_id} <- Types.opaque_string(attrs, :causation_id),
         {:ok, expected_entity_revision} <-
           Types.non_neg_integer(attrs, :expected_entity_revision),
         {:ok, attempt} <- Types.non_neg_integer(attrs, :attempt),
         {:ok, payload} <- Types.string_map(Map.get(attrs, :payload)) do
      {:ok,
       struct!(__MODULE__,
         version: version,
         job_id: job_id,
         job_type: job_type,
         idempotency_key: idempotency_key,
         vault_id: vault_id,
         principal_id: principal_id,
         required_capability: required_capability,
         principal_authorization_epoch: principal_authorization_epoch,
         vault_authorization_epoch: vault_authorization_epoch,
         classification: classification,
         correlation_id: correlation_id,
         causation_id: causation_id,
         expected_entity_revision: expected_entity_revision,
         attempt: attempt,
         payload: payload
       )}
    end
  end
end
