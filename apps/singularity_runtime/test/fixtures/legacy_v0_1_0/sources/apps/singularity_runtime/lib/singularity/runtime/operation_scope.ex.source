defmodule Singularity.Runtime.OperationScope do
  @moduledoc """
  Pins request work to the global vault/authorization lock order.

  A trusted `{:after_commit, callback}` result executes its zero-arity callback
  after the scoped transaction commits while the advisory locks are still held.

  `{:after_commit_scoped, callback}` also executes after that commit, but passes
  the callback a runner which can open a second scoped transaction on the same
  pinned connection under the same locks. This keeps non-database activation
  outside the transaction while allowing its resulting compare-and-swap to be
  committed and observed before the callback continues.
  """

  alias Singularity.Core.Error
  alias Singularity.Runtime.Audit
  alias Singularity.Runtime.Authorize
  alias Singularity.Storage.Postgres.AuditSink

  @spec with_read_request(map(), map(), map(), (term() -> term())) ::
          term() | {:error, Error.t()}
  def with_read_request(runtime, session, requirement, callback)
      when is_map(runtime) and is_map(session) and is_map(requirement) and
             is_function(callback, 1) do
    with {:ok, values} <- values(runtime, session) do
      case bind_requirement(session, requirement) do
        {:ok, bound_requirement} ->
          call_adapter(values.request_repo, :checkout, [
            fn ->
              repo = adapter_module(values.request_repo)

              with_authorization_lock(
                values,
                :shared,
                repo,
                session,
                bound_requirement,
                callback
              )
            end
          ])

        {:error, %Error{}} = error ->
          audit_cross_vault_denial(values, session, error)
      end
    end
  end

  def with_read_request(_runtime, _session, _requirement, _callback),
    do: {:error, Error.new(:invalid)}

  @spec with_shared_request(map(), map(), map(), (term() -> term())) ::
          term() | {:error, Error.t()}
  def with_shared_request(runtime, session, requirement, callback) do
    with_vault_request(:shared, runtime, session, requirement, callback)
  end

  @spec with_exclusive_request(map(), map(), map(), (term() -> term())) ::
          term() | {:error, Error.t()}
  def with_exclusive_request(runtime, session, requirement, callback) do
    with_vault_request(:exclusive, runtime, session, requirement, callback)
  end

  defp with_vault_request(mode, runtime, session, requirement, callback)
       when mode in [:shared, :exclusive] and is_map(runtime) and is_map(session) and
              is_map(requirement) and is_function(callback, 1) do
    with {:ok, values} <- values(runtime, session) do
      case bind_requirement(session, requirement) do
        {:ok, bound_requirement} ->
          call_adapter(values.vault_lock, lock_function(mode), [
            adapter_module(values.request_repo),
            bound_requirement.vault_id,
            fn pinned_repo ->
              with_authorization_lock(
                values,
                mode,
                pinned_repo,
                session,
                bound_requirement,
                callback
              )
            end
          ])

        {:error, %Error{}} = error ->
          audit_cross_vault_denial(values, session, error)
      end
    end
  end

  defp with_vault_request(_mode, _runtime, _session, _requirement, _callback),
    do: {:error, Error.new(:invalid)}

  defp with_authorization_lock(
         values,
         mode,
         repo,
         session,
         requirement,
         callback
       ) do
    call_adapter(values.authorization_lock, lock_function(mode), [
      repo,
      session.principal_id,
      requirement.vault_id,
      fn locked_repo ->
        scope = %{principal_id: session.principal_id, vault_id: session.vault_id}

        transaction_result =
          call_adapter(values.scoped_repo, :transact, [
            locked_repo,
            scope,
            fn scoped_repo ->
              authorize_then_run(
                values,
                scoped_repo,
                session,
                requirement,
                callback
              )
            end
          ])

        finish_transaction(
          transaction_result,
          values,
          locked_repo,
          scope,
          session,
          requirement
        )
      end
    ])
  end

  defp authorize_then_run(values, repo, session, requirement, callback) do
    case call_adapter(values.authorizer, :check, [
           values.authorization,
           repo,
           session,
           requirement
         ]) do
      :ok ->
        callback.(repo)

      {:error, %Error{code: code} = error}
      when code in [:unauthenticated, :forbidden] ->
        {:error, {:authorization_denial, error}}

      {:error, %Error{}} = error ->
        error

      _invalid ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp finish_transaction(
         {:error, {:authorization_denial, %Error{} = public_error}},
         values,
         locked_repo,
         scope,
         session,
         requirement
       ) do
    case append_denial(
           values,
           locked_repo,
           scope,
           session,
           requirement,
           "authorization.denied",
           "authorization"
         ) do
      :ok -> {:error, public_error}
      {:error, %Error{}} = audit_error -> audit_error
      _invalid -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp finish_transaction(
         result,
         values,
         locked_repo,
         scope,
         _session,
         _requirement
       ),
       do: run_after_commit(result, values, locked_repo, scope)

  defp audit_cross_vault_denial(values, session, public_error) do
    result =
      call_adapter(values.request_repo, :checkout, [
        fn ->
          repo = adapter_module(values.request_repo)
          scope = %{principal_id: session.principal_id, vault_id: session.vault_id}

          append_denial(
            values,
            repo,
            scope,
            session,
            %{},
            "authorization.cross_vault_denied",
            "vault"
          )
        end
      ])

    case result do
      :ok -> public_error
      {:error, %Error{}} = audit_error -> audit_error
      _invalid -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp append_denial(
         values,
         repo,
         scope,
         session,
         requirement,
         action,
         default_target_type
       ) do
    call_adapter(values.scoped_repo, :transact, [
      repo,
      scope,
      fn scoped_repo ->
        Audit.append_principal(values.audit, scoped_repo, session, %{
          action: action,
          result: :denied,
          classification: Map.get(requirement, :classification, :private),
          correlation_id: Map.get(requirement, :correlation_id, Ecto.UUID.generate()),
          target_type: Map.get(requirement, :audit_target_type, default_target_type),
          target_id: Map.get(requirement, :audit_target_id, session.vault_id),
          metadata: %{}
        })
      end
    ])
  end

  defp run_after_commit({:after_commit, callback}, _values, _locked_repo, _scope)
       when is_function(callback, 0),
       do: callback.()

  defp run_after_commit({:after_commit_scoped, callback}, values, locked_repo, scope)
       when is_function(callback, 1) do
    run_scoped = fn scoped_callback ->
      run_scoped_after_commit(scoped_callback, values, locked_repo, scope)
    end

    normalize_after_commit_result(callback.(run_scoped))
  end

  defp run_after_commit({tag, _invalid_callback}, _values, _locked_repo, _scope)
       when tag in [:after_commit, :after_commit_scoped],
       do: {:error, Error.new(:invalid)}

  defp run_after_commit(result, _values, _locked_repo, _scope), do: result

  defp run_scoped_after_commit(callback, values, locked_repo, scope)
       when is_function(callback, 1) do
    values.scoped_repo
    |> call_adapter(:transact, [
      locked_repo,
      scope,
      fn scoped_repo -> normalize_after_commit(callback.(scoped_repo)) end
    ])
    |> unwrap_after_commit()
  end

  defp run_scoped_after_commit(_invalid_callback, _values, _locked_repo, _scope),
    do: {:error, Error.new(:invalid)}

  defp normalize_after_commit({:commit, result}),
    do: {:operation_scope_committed_result, result}

  defp normalize_after_commit({:ok, _value} = result), do: result
  defp normalize_after_commit(:ok), do: :ok
  defp normalize_after_commit({:error, %Error{}} = error), do: error
  defp normalize_after_commit(_invalid), do: {:error, Error.new(:invalid)}

  defp unwrap_after_commit({:operation_scope_committed_result, result}), do: result
  defp unwrap_after_commit(result), do: result

  defp normalize_after_commit_result({:ok, _value} = result), do: result
  defp normalize_after_commit_result(:ok), do: :ok
  defp normalize_after_commit_result({:error, %Error{}} = error), do: error
  defp normalize_after_commit_result(_invalid), do: {:error, Error.new(:invalid)}

  defp values(runtime, %{principal_id: principal_id, vault_id: vault_id})
       when is_binary(principal_id) and byte_size(principal_id) > 0 and
              is_binary(vault_id) and byte_size(vault_id) > 0 do
    required = [
      :request_repo,
      :vault_lock,
      :authorization_lock,
      :scoped_repo,
      :authorization
    ]

    if Enum.all?(required, &concrete?(Map.get(runtime, &1))) do
      {:ok,
       %{
         request_repo: runtime.request_repo,
         vault_lock: runtime.vault_lock,
         authorization_lock: runtime.authorization_lock,
         scoped_repo: runtime.scoped_repo,
         authorizer: Map.get(runtime, :authorizer, Authorize),
         authorization: runtime.authorization,
         audit: Map.get(runtime, :audit, AuditSink)
       }}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp values(_runtime, _session), do: {:error, Error.new(:invalid)}

  defp lock_function(:shared), do: :with_shared
  defp lock_function(:exclusive), do: :with_exclusive

  defp bind_requirement(session, requirement) do
    bound =
      requirement
      |> Map.put_new(:vault_id, session.vault_id)
      |> Map.put_new(
        :principal_authorization_epoch,
        Map.get(session, :principal_authorization_epoch) ||
          Map.get(session, :authorization_epoch)
      )
      |> Map.put_new(
        :vault_authorization_epoch,
        Map.get(session, :vault_authorization_epoch)
      )

    if bound.vault_id == session.vault_id do
      {:ok, bound}
    else
      {:error, Error.new(:invalid)}
    end
  end

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

  defp concrete?(value), do: value not in [nil, false]
end
