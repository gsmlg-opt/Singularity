defmodule Singularity.Runtime.Logout do
  @moduledoc "Revokes session custody before durably revoking the session."

  alias Singularity.Core.Error
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext

  @requirement %{
    required_capability: "vault.lock",
    classification: :private,
    requires_unlocked?: false
  }

  @spec run(map(), SessionContext.t(), String.t()) :: :ok | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, correlation_id)
      when is_map(runtime) and is_binary(correlation_id) and
             byte_size(correlation_id) > 0 do
    selector = %{vault_id: session.vault_id}

    with {:ok, adapters} <- adapters(runtime),
         {:ok, token} <-
           call_adapter(adapters.custodian, :begin_revoke, [selector]) do
      try do
        with :ok <-
               call_adapter(
                 adapters.custodian,
                 :await_revoking,
                 [selector]
               ),
             result <-
               call_adapter(adapters.operation_scope, :with_exclusive_request, [
                 runtime,
                 session,
                 @requirement,
                 fn repo ->
                   call_adapter(adapters.identity, :revoke_session_and_audit, [
                     repo,
                     %{
                       session_id: session.session_id,
                       principal_id: session.principal_id,
                       vault_id: session.vault_id,
                       correlation_id: correlation_id
                     }
                   ])
                 end
               ]) do
          logout_result(result)
        end
      after
        _finish_result =
          call_adapter(adapters.custodian, :finish_revoke, [token])
      end
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_runtime, _session, _correlation_id),
    do: {:error, Error.new(:invalid)}

  defp logout_result(:ok), do: :ok
  defp logout_result({:ok, _value}), do: :ok
  defp logout_result({:error, %Error{}} = error), do: error
  defp logout_result(_invalid), do: {:error, Error.new(:storage_unavailable)}

  defp adapters(runtime) do
    with custodian when custodian not in [nil, false] <- runtime[:custodian],
         identity when identity not in [nil, false] <- runtime[:identity],
         operation_scope when operation_scope not in [nil, false] <-
           Map.get(runtime, :operation_scope, OperationScope) do
      {:ok,
       %{
         custodian: custodian,
         identity: identity,
         operation_scope: operation_scope
       }}
    else
      _missing -> {:error, Error.new(:invalid)}
    end
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end
end
