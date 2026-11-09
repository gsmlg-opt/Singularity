defmodule Singularity.Runtime.AccessPolicy do
  @moduledoc """
  Performs owner-authorized capability and clearance changes through atomic
  persistence-and-audit repository operations.
  """

  alias Singularity.Core.Error
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.IdentityRepository

  @preflight_requirement %{
    required_capability: "vault.password_change",
    classification: :restricted,
    requires_unlocked?: true
  }
  @persist_requirement %{@preflight_requirement | requires_unlocked?: false}

  @spec change_capability(
          map(),
          SessionContext.t(),
          String.t(),
          String.t(),
          :grant | :revoke,
          String.t()
        ) :: :ok | {:error, Error.t()}
  def change_capability(
        runtime,
        %SessionContext{} = session,
        target_principal_id,
        capability,
        change,
        correlation_id
      )
      when is_map(runtime) and change in [:grant, :revoke] do
    with :ok <- validate_common(session, target_principal_id, correlation_id),
         {:ok, capability} <- normalized_capability(capability),
         {:ok, adapters} <- adapters(runtime) do
      mutate(
        adapters,
        runtime,
        session,
        :change_capability_and_audit,
        %{
          session_id: session.session_id,
          actor_principal_id: session.principal_id,
          target_principal_id: target_principal_id,
          vault_id: session.vault_id,
          capability: capability,
          change: change,
          correlation_id: correlation_id
        }
      )
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def change_capability(
        _runtime,
        _session,
        _target_principal_id,
        _capability,
        _change,
        _correlation_id
      ),
      do: {:error, Error.new(:invalid)}

  @spec change_clearance(
          map(),
          SessionContext.t(),
          String.t(),
          :private | :sensitive | :restricted,
          String.t()
        ) :: :ok | {:error, Error.t()}
  def change_clearance(
        runtime,
        %SessionContext{} = session,
        target_principal_id,
        clearance,
        correlation_id
      )
      when is_map(runtime) and clearance in [:private, :sensitive, :restricted] do
    with :ok <- validate_common(session, target_principal_id, correlation_id),
         {:ok, adapters} <- adapters(runtime) do
      mutate(
        adapters,
        runtime,
        session,
        :change_clearance_and_audit,
        %{
          session_id: session.session_id,
          actor_principal_id: session.principal_id,
          target_principal_id: target_principal_id,
          vault_id: session.vault_id,
          clearance: clearance,
          correlation_id: correlation_id
        }
      )
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def change_clearance(
        _runtime,
        _session,
        _target_principal_id,
        _clearance,
        _correlation_id
      ),
      do: {:error, Error.new(:invalid)}

  defp mutate(adapters, runtime, session, function, command) do
    selector = %{vault_id: session.vault_id}

    with :ok <- preflight(adapters, runtime, session, command),
         {:ok, revoke_token} <-
           call_adapter(adapters.custodian, :begin_revoke, [selector]) do
      persist_while_revoking(
        adapters,
        runtime,
        session,
        selector,
        revoke_token,
        function,
        command
      )
    end
    |> normalize_result()
  end

  defp preflight(adapters, runtime, session, command) do
    call_adapter(adapters.operation_scope, :with_read_request, [
      runtime,
      session,
      audit_requirement(@preflight_requirement, command),
      fn _repo -> :ok end
    ])
  end

  defp persist_while_revoking(
         adapters,
         runtime,
         session,
         selector,
         revoke_token,
         function,
         command
       ) do
    try do
      with :ok <- call_adapter(adapters.custodian, :await_revoking, [selector]) do
        call_adapter(adapters.operation_scope, :with_exclusive_request, [
          runtime,
          session,
          audit_requirement(@persist_requirement, command),
          fn repo ->
            call_adapter(adapters.policies, function, [repo, command])
          end
        ])
      end
    after
      _finish_result =
        call_adapter(adapters.custodian, :finish_revoke, [revoke_token])
    end
  end

  defp audit_requirement(requirement, command) do
    Map.merge(requirement, %{
      correlation_id: command.correlation_id,
      audit_target_type: "principal",
      audit_target_id: command.target_principal_id
    })
  end

  defp validate_common(
         %{unlocked?: true, principal_id: principal_id, vault_id: vault_id},
         target_principal_id,
         correlation_id
       ) do
    validate_uuids([
      principal_id,
      vault_id,
      target_principal_id,
      correlation_id
    ])
  end

  defp validate_common(_session, _target_principal_id, _correlation_id),
    do: {:error, Error.new(:invalid)}

  defp validate_uuids(values) do
    if Enum.all?(values, &match?({:ok, _uuid}, Ecto.UUID.cast(&1))),
      do: :ok,
      else: {:error, Error.new(:invalid)}
  end

  defp normalized_capability(capability) when is_binary(capability) do
    normalized = String.trim(capability)

    if normalized != "" and normalized == capability,
      do: {:ok, normalized},
      else: {:error, Error.new(:invalid)}
  end

  defp normalized_capability(_capability), do: {:error, Error.new(:invalid)}

  defp adapters(runtime) do
    values = %{
      custodian: Map.get(runtime, :custodian, KeyCustodian),
      operation_scope: Map.get(runtime, :operation_scope, OperationScope),
      policies: Map.get(runtime, :policies, IdentityRepository)
    }

    if Enum.all?(Map.values(values), &(&1 not in [nil, false])),
      do: {:ok, values},
      else: {:error, Error.new(:invalid)}
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _value}), do: :ok
  defp normalize_result({:error, %Error{}} = error), do: error
  defp normalize_result(_invalid), do: {:error, Error.new(:storage_unavailable)}

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end
end
