defmodule Singularity.Runtime.Notes.Get do
  @moduledoc "Reads canonical notes, exact versions, and conflict sources."

  alias Singularity.Core.Error
  alias Singularity.Runtime.Notes.SourceCollections
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.NoteRepository
  alias Singularity.Storage.Postgres.KnowledgeLinkRepository

  @spec run(map(), SessionContext.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, resource_id) when is_map(runtime) do
    with :ok <- validate_ids(resource_id),
         {:ok, adapters} <- adapters(runtime) do
      read(adapters, runtime, session, fn repo ->
        call_adapter(adapters.note_repository, :get, [repo, session.vault_id, resource_id])
        |> compose_result(adapters, repo, session, resource_id)
      end)
    end
  rescue
    _error -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def run(_runtime, _session, _resource_id), do: invalid()

  @spec version(map(), SessionContext.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def version(runtime, %SessionContext{} = session, resource_id, version_id)
      when is_map(runtime) do
    with :ok <- validate_ids([resource_id, version_id]),
         {:ok, adapters} <- adapters(runtime) do
      read(adapters, runtime, session, fn repo ->
        case call_adapter(adapters.note_repository, :get_version, [
               repo,
               session.vault_id,
               resource_id,
               version_id
             ]) do
          {:ok, %{resource_version_id: ^version_id}} = result ->
            compose_result(result, adapters, repo, session, resource_id)

          {:ok, _invalid} ->
            integrity_failure()

          result ->
            result
        end
      end)
    end
  rescue
    _error -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def version(_runtime, _session, _resource_id, _version_id), do: invalid()

  @spec conflict(map(), SessionContext.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def conflict(runtime, %SessionContext{} = session, resource_id, conflict_id)
      when is_map(runtime) do
    with :ok <- validate_ids([resource_id, conflict_id]),
         {:ok, adapters} <- adapters(runtime) do
      read(adapters, runtime, session, fn repo ->
        case call_adapter(adapters.note_repository, :get_conflict, [
               repo,
               session.vault_id,
               resource_id,
               conflict_id
             ]) do
          {:ok, %{conflict: conflict, current: current, competing: competing} = detail}
          when map_size(detail) == 3 ->
            with {:ok, current} <-
                   compose_result({:ok, current}, adapters, repo, session, resource_id),
                 {:ok, competing} <-
                   compose_result({:ok, competing}, adapters, repo, session, resource_id) do
              {:ok, %{conflict: conflict, current: current, competing: competing}}
            end

          {:ok, _invalid} ->
            integrity_failure()

          result ->
            result
        end
      end)
    end
  rescue
    _error -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def conflict(_runtime, _session, _resource_id, _conflict_id), do: invalid()

  defp compose_result(
         {:ok, %{resource_id: resource_id} = row},
         adapters,
         repo,
         session,
         resource_id
       ),
       do: SourceCollections.compose(adapters.knowledge_link_repository, repo, session, row)

  defp compose_result({:error, %Error{}} = result, _adapters, _repo, _session, _resource_id),
    do: result

  defp compose_result(_result, _adapters, _repo, _session, _resource_id), do: integrity_failure()

  defp read(adapters, runtime, session, callback) do
    call_adapter(adapters.operation_scope, :with_read_request, [
      runtime,
      session,
      requirement(session),
      callback
    ])
  end

  defp requirement(session) do
    %{
      vault_id: session.vault_id,
      required_capability: "note.read",
      classification: :private,
      requires_unlocked?: true
    }
  end

  defp adapters(runtime) do
    values = %{
      note_repository: Map.get(runtime, :note_repository, NoteRepository),
      knowledge_link_repository:
        Map.get(runtime, :knowledge_link_repository, KnowledgeLinkRepository),
      operation_scope: Map.get(runtime, :operation_scope, OperationScope)
    }

    if Enum.all?(Map.values(values), &concrete?/1), do: {:ok, values}, else: invalid()
  end

  defp validate_ids(ids) when is_list(ids) do
    if Enum.all?(ids, &valid_uuid?/1), do: :ok, else: invalid()
  end

  defp validate_ids(id), do: validate_ids([id])

  defp valid_uuid?(value), do: Ecto.UUID.cast(value) == {:ok, value}

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [context | arguments])

  defp concrete?(value), do: value not in [nil, false]
  defp invalid, do: {:error, Error.new(:invalid)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
