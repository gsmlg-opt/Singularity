defmodule Singularity.Runtime.OperationScope do
  @moduledoc """
  Pins request work to the global vault/authorization lock order.

  A trusted `{:after_commit, callback}` result is executed after the scoped
  transaction commits while the advisory locks are still held.
  """

  alias Singularity.Core.Error
  alias Singularity.Runtime.Authorize

  @spec with_read_request(map(), map(), map(), (term() -> term())) ::
          term() | {:error, Error.t()}
  def with_read_request(runtime, session, requirement, callback)
      when is_map(runtime) and is_map(session) and is_map(requirement) and
             is_function(callback, 1) do
    with {:ok, values} <- values(runtime, session),
         {:ok, requirement} <- bind_requirement(session, requirement) do
      call_adapter(values.request_repo, :checkout, [
        fn ->
          repo = adapter_module(values.request_repo)

          with_authorization_lock(
            values,
            :shared,
            repo,
            session,
            requirement,
            callback
          )
        end
      ])
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
    with {:ok, values} <- values(runtime, session),
         {:ok, requirement} <- bind_requirement(session, requirement) do
      call_adapter(values.vault_lock, lock_function(mode), [
        adapter_module(values.request_repo),
        requirement.vault_id,
        fn pinned_repo ->
          with_authorization_lock(
            values,
            mode,
            pinned_repo,
            session,
            requirement,
            callback
          )
        end
      ])
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
        values.scoped_repo
        |> call_adapter(:transact, [
          locked_repo,
          %{principal_id: session.principal_id, vault_id: session.vault_id},
          fn scoped_repo ->
            with :ok <-
                   call_adapter(values.authorizer, :check, [
                     values.authorization,
                     scoped_repo,
                     session,
                     requirement
                   ]) do
              callback.(scoped_repo)
            end
          end
        ])
        |> run_after_commit()
      end
    ])
  end

  defp run_after_commit({:after_commit, callback}) when is_function(callback, 0),
    do: callback.()

  defp run_after_commit(result), do: result

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
         authorization: runtime.authorization
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
