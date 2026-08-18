defmodule Singularity.Runtime.Notes.Get do
  @moduledoc "Reads canonical notes, exact versions, and conflict sources."

  alias Singularity.Core.Error
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.NoteRepository

  @spec run(map(), SessionContext.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, resource_id) when is_map(runtime) do
    with :ok <- validate_ids(resource_id),
         {:ok, adapters} <- adapters(runtime) do
      read(adapters, runtime, session, fn repo ->
        call_adapter(adapters.note_repository, :get, [repo, session.vault_id, resource_id])
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
        call_adapter(adapters.note_repository, :get_version, [
          repo,
          session.vault_id,
          resource_id,
          version_id
        ])
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
        call_adapter(adapters.note_repository, :get_conflict, [
          repo,
          session.vault_id,
          resource_id,
          conflict_id
        ])
      end)
    end
  rescue
    _error -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def conflict(_runtime, _session, _resource_id, _conflict_id), do: invalid()

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
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
