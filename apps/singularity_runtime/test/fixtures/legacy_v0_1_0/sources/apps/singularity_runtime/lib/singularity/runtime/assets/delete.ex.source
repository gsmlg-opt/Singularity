defmodule Singularity.Runtime.Assets.Delete do
  @moduledoc "Commits an authorized logical asset tombstone."

  alias Singularity.Core.Error
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.ObjectLock

  @max_lock_redirects 4

  @spec run(map(), SessionContext.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(
        runtime,
        %SessionContext{} = session,
        asset_id,
        expected_state_revision
      )
      when is_map(runtime) and is_binary(asset_id) and
             is_integer(expected_state_revision) and expected_state_revision >= 0 do
    with {:ok, adapters} <- adapters(runtime),
         {:ok, _asset_id} <- Ecto.UUID.cast(asset_id),
         {:ok, target} <- load_target(adapters, runtime, session, asset_id),
         :ok <- validate_target(target, session, asset_id) do
      call_adapter(adapters.operation_scope, :with_shared_request, [
        runtime,
        session,
        requirement(target.classification),
        fn repo ->
          delete_under_lock(
            adapters,
            repo,
            %{
              asset_id: asset_id,
              vault_id: session.vault_id,
              principal_id: session.principal_id,
              classification: target.classification,
              expected_state_revision: expected_state_revision
            },
            @max_lock_redirects
          )
        end
      ])
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_runtime, _session, _asset_id, _expected_state_revision),
    do: {:error, Error.new(:invalid)}

  defp load_target(adapters, runtime, session, asset_id) do
    call_adapter(adapters.operation_scope, :with_read_request, [
      runtime,
      session,
      requirement(:private),
      fn repo ->
        call_adapter(adapters.deletions, :load_delete_target, [
          repo,
          %{asset_id: asset_id, vault_id: session.vault_id}
        ])
      end
    ])
  end

  defp validate_target(
         %{id: asset_id, vault_id: vault_id, classification: classification},
         session,
         asset_id
       )
       when vault_id == session.vault_id and
              classification in [:private, :sensitive, :restricted],
       do: :ok

  defp validate_target(_target, _session, _asset_id),
    do: {:error, Error.new(:conflict)}

  defp requirement(classification) do
    %{
      required_capability: "asset.write",
      classification: classification,
      requires_unlocked?: false
    }
  end

  defp delete_under_lock(_adapters, _repo, _command, redirects_left)
       when redirects_left <= 0,
       do: {:error, Error.new(:conflict)}

  defp delete_under_lock(adapters, repo, command, redirects_left) do
    with {:ok, target} <- resolve_lock_target(adapters, repo, command) do
      delete_resolved(
        adapters,
        repo,
        command,
        target.object_id,
        redirects_left
      )
    end
  end

  defp delete_resolved(adapters, repo, command, nil, _redirects_left) do
    call_adapter(adapters.deletions, :tombstone_and_release, [
      repo,
      Map.put(command, :locked_object_id, nil)
    ])
  end

  defp delete_resolved(
         adapters,
         repo,
         command,
         object_id,
         redirects_left
       )
       when is_binary(object_id) do
    with {:ok, ^object_id} <- Ecto.UUID.cast(object_id) do
      result =
        call_adapter(adapters.object_lock, :with_exclusive, [
          repo,
          object_id,
          fn ->
            case resolve_lock_target(adapters, repo, command) do
              {:ok, %{object_id: ^object_id}} ->
                call_adapter(adapters.deletions, :tombstone_and_release, [
                  repo,
                  Map.put(command, :locked_object_id, object_id)
                ])

              {:ok, %{object_id: redirected_object_id}} ->
                {:retry_lock, redirected_object_id}

              {:error, %Error{}} = error ->
                error
            end
          end
        ])

      case result do
        {:retry_lock, redirected_object_id} ->
          delete_resolved(
            adapters,
            repo,
            command,
            redirected_object_id,
            redirects_left - 1
          )

        other ->
          other
      end
    else
      :error -> {:error, Error.new(:conflict)}
    end
  end

  defp delete_resolved(_adapters, _repo, _command, _object_id, _redirects_left),
    do: {:error, Error.new(:conflict)}

  defp resolve_lock_target(adapters, repo, command) do
    case call_adapter(
           adapters.deletions,
           :resolve_delete_lock_target,
           [repo, Map.take(command, [:asset_id, :vault_id])]
         ) do
      {:ok, %{object_id: object_id}} when is_binary(object_id) or is_nil(object_id) ->
        {:ok, %{object_id: object_id}}

      {:error, %Error{}} = error ->
        error

      _invalid ->
        {:error, Error.new(:conflict)}
    end
  end

  defp adapters(runtime) do
    deletions =
      Map.get(runtime, :asset_deletions) ||
        Map.get(runtime, :assets)

    if deletions not in [nil, false] do
      {:ok,
       %{
         deletions: deletions,
         object_lock: Map.get(runtime, :object_lock, ObjectLock),
         operation_scope: Map.get(runtime, :operation_scope, OperationScope)
       }}
    else
      {:error, Error.new(:invalid)}
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
