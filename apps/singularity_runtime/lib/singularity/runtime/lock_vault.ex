defmodule Singularity.Runtime.LockVault do
  @moduledoc "Revokes in-memory custody before durably locking a vault."

  alias Singularity.Core.Error
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext

  @default_idle_runtime %{
    request_repo: Singularity.Storage.RequestRepo,
    vault_lock: Singularity.Storage.VaultLock,
    authorization_lock: Singularity.Storage.AuthorizationLock,
    scoped_repo: Singularity.Storage.ScopedRepo,
    vaults: Singularity.Storage.Postgres.IdentityRepository
  }

  @requirement %{
    required_capability: "vault.lock",
    classification: :private,
    requires_unlocked?: false
  }

  @spec run(map(), SessionContext.t(), String.t()) ::
          {:ok, SessionContext.t()} | {:error, Error.t()}
  def run(
        runtime,
        %SessionContext{} = session,
        correlation_id
      )
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
                   call_adapter(adapters.vaults, :lock_and_audit, [
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
          locked_result(result, session)
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

  @doc false
  @spec idle_lock(map()) :: :ok | {:error, Error.t()}
  def idle_lock(session), do: idle_lock(@default_idle_runtime, session)

  @doc false
  @spec idle_lock(map(), map()) :: :ok | {:error, Error.t()}
  def idle_lock(
        runtime,
        %{
          session_id: session_id,
          principal_id: principal_id,
          vault_id: vault_id,
          reason: :idle_timeout
        }
      )
      when is_map(runtime) and is_binary(session_id) and
             byte_size(session_id) > 0 and is_binary(principal_id) and
             byte_size(principal_id) > 0 and is_binary(vault_id) and
             byte_size(vault_id) > 0 do
    with {:ok, adapters} <- idle_adapters(runtime) do
      adapters.vault_lock
      |> call_adapter(:with_exclusive, [
        adapter_module(adapters.request_repo),
        vault_id,
        fn repo ->
          call_adapter(adapters.authorization_lock, :with_exclusive, [
            repo,
            principal_id,
            vault_id,
            fn locked_repo ->
              call_adapter(adapters.scoped_repo, :transact, [
                locked_repo,
                %{principal_id: principal_id, vault_id: vault_id},
                fn scoped_repo ->
                  call_adapter(adapters.vaults, :lock_and_audit, [
                    scoped_repo,
                    %{
                      session_id: session_id,
                      principal_id: principal_id,
                      vault_id: vault_id,
                      correlation_id: Ecto.UUID.generate(),
                      reason: :idle_timeout
                    }
                  ])
                end
              ])
            end
          ])
        end
      ])
      |> idle_result()
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def idle_lock(_runtime, _session), do: {:error, Error.new(:invalid)}

  defp locked_result(:ok, session), do: {:ok, SessionContext.locked(session)}
  defp locked_result({:ok, _value}, session), do: {:ok, SessionContext.locked(session)}
  defp locked_result({:error, %Error{}} = error, _session), do: error
  defp locked_result(_invalid, _session), do: {:error, Error.new(:storage_unavailable)}

  defp adapters(runtime) do
    with custodian when custodian not in [nil, false] <- runtime[:custodian],
         operation_scope when operation_scope not in [nil, false] <-
           Map.get(runtime, :operation_scope, OperationScope),
         vaults when vaults not in [nil, false] <- runtime[:vaults] do
      {:ok,
       %{
         custodian: custodian,
         operation_scope: operation_scope,
         vaults: vaults
       }}
    else
      _missing -> {:error, Error.new(:invalid)}
    end
  end

  defp idle_adapters(runtime) do
    required = [
      :request_repo,
      :vault_lock,
      :authorization_lock,
      :scoped_repo,
      :vaults
    ]

    if Enum.all?(required, &(Map.get(runtime, &1) not in [nil, false])) do
      {:ok, Map.take(runtime, required)}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp idle_result(:ok), do: :ok
  defp idle_result({:ok, _value}), do: :ok
  defp idle_result({:error, %Error{}} = error), do: error
  defp idle_result(_invalid), do: {:error, Error.new(:storage_unavailable)}

  defp adapter_module(module) when is_atom(module), do: module
  defp adapter_module({module, _context}) when is_atom(module), do: module

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end
end
