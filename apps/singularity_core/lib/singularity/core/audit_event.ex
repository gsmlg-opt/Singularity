defmodule Singularity.Core.AuditEvent do
  @moduledoc "An append-only audit value with explicit authority and classification context."

  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [
    :audit_event_id,
    :actor_kind,
    :action,
    :result,
    :classification,
    :correlation_id,
    :target_type,
    :target_id,
    :occurred_at
  ]
  defstruct [
    :audit_event_id,
    :actor_kind,
    :principal_id,
    :vault_id,
    :anonymous_fingerprint,
    :system_principal_name,
    :action,
    :result,
    :classification,
    :correlation_id,
    :target_type,
    :target_id,
    :occurred_at,
    metadata: %{}
  ]

  @type actor_kind :: :anonymous | :principal | :system
  @type result :: :allowed | :denied | :completed | :failed

  @type t :: %__MODULE__{
          audit_event_id: Types.id(),
          actor_kind: actor_kind(),
          principal_id: Types.id() | nil,
          vault_id: Types.id() | nil,
          anonymous_fingerprint: binary() | nil,
          system_principal_name: String.t() | nil,
          action: String.t(),
          result: result(),
          classification: Classification.t(),
          correlation_id: Types.id(),
          target_type: String.t(),
          target_id: Types.id(),
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
         {:ok, anonymous_fingerprint} <- optional_fingerprint(attrs),
         {:ok, system_principal_name} <-
           Types.optional_opaque_string(attrs, :system_principal_name),
         :ok <-
           validate_actor(
             actor_kind,
             principal_id,
             vault_id,
             anonymous_fingerprint,
             system_principal_name
           ),
         {:ok, action} <- Types.normalized_string(attrs, :action),
         {:ok, result} <- result(attrs),
         {:ok, classification} <- Classification.new(Map.get(attrs, :classification)),
         {:ok, correlation_id} <- Types.opaque_string(attrs, :correlation_id),
         {:ok, target_type} <- Types.normalized_string(attrs, :target_type),
         {:ok, target_id} <- Types.opaque_string(attrs, :target_id),
         {:ok, occurred_at} <- Types.utc_datetime(attrs, :occurred_at),
         {:ok, metadata} <- Types.metadata(attrs) do
      {:ok,
       %__MODULE__{
         audit_event_id: audit_event_id,
         actor_kind: actor_kind,
         principal_id: principal_id,
         vault_id: vault_id,
         anonymous_fingerprint: anonymous_fingerprint,
         system_principal_name: system_principal_name,
         action: action,
         result: result,
         classification: classification,
         correlation_id: correlation_id,
         target_type: target_type,
         target_id: target_id,
         occurred_at: occurred_at,
         metadata: metadata
       }}
    end
  end

  defp optional_fingerprint(attrs) do
    case Map.get(attrs, :anonymous_fingerprint) do
      nil ->
        {:ok, nil}

      fingerprint when is_binary(fingerprint) and byte_size(fingerprint) == 32 ->
        {:ok, fingerprint}

      _other ->
        Types.invalid()
    end
  end

  defp validate_actor(:principal, principal_id, vault_id, nil, nil)
       when not is_nil(principal_id) and not is_nil(vault_id),
       do: :ok

  defp validate_actor(:system, nil, vault_id, nil, system_principal_name)
       when not is_nil(vault_id) and not is_nil(system_principal_name),
       do: :ok

  defp validate_actor(:anonymous, nil, nil, anonymous_fingerprint, nil)
       when not is_nil(anonymous_fingerprint),
       do: :ok

  defp validate_actor(
         _actor_kind,
         _principal_id,
         _vault_id,
         _anonymous_fingerprint,
         _system_principal_name
       ),
       do: Types.invalid()

  defp result(attrs) do
    case Map.get(attrs, :result) do
      result when result in [:allowed, :denied, :completed, :failed] -> {:ok, result}
      _other -> Types.invalid()
    end
  end
end
