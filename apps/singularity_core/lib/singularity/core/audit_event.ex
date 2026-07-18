defmodule Singularity.Core.AuditEvent do
  @moduledoc "An append-only audit value with explicit authority and classification context."

  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [
    :audit_event_id,
    :actor_kind,
    :action,
    :classification,
    :correlation_id,
    :occurred_at
  ]
  defstruct [
    :audit_event_id,
    :actor_kind,
    :principal_id,
    :vault_id,
    :action,
    :classification,
    :correlation_id,
    :occurred_at,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          audit_event_id: Types.id(),
          actor_kind: atom(),
          principal_id: Types.id() | nil,
          vault_id: Types.id() | nil,
          action: String.t(),
          classification: Classification.t(),
          correlation_id: Types.id(),
          occurred_at: Types.timestamp(),
          metadata: Types.metadata()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, audit_event_id} <- Types.opaque_string(attrs, :audit_event_id),
         {:ok, actor_kind} <- Types.atom_value(attrs, :actor_kind),
         {:ok, principal_id} <- Types.optional_opaque_string(attrs, :principal_id),
         {:ok, vault_id} <- Types.optional_opaque_string(attrs, :vault_id),
         {:ok, action} <- Types.normalized_string(attrs, :action),
         {:ok, classification} <- Classification.new(Map.get(attrs, :classification)),
         {:ok, correlation_id} <- Types.opaque_string(attrs, :correlation_id),
         {:ok, occurred_at} <- Types.utc_datetime(attrs, :occurred_at),
         {:ok, metadata} <- Types.metadata(attrs) do
      {:ok,
       %__MODULE__{
         audit_event_id: audit_event_id,
         actor_kind: actor_kind,
         principal_id: principal_id,
         vault_id: vault_id,
         action: action,
         classification: classification,
         correlation_id: correlation_id,
         occurred_at: occurred_at,
         metadata: metadata
       }}
    end
  end
end
