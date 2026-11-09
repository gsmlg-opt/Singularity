defmodule Singularity.Runtime.Notes.Search do
  @moduledoc "Runs vault-bound private note search inside an authorized read scope."

  alias Singularity.Core.Error
  alias Singularity.Core.Types
  alias Singularity.Retrieval.NoteLexicalSearch
  alias Singularity.Retrieval.NoteSearchQuery
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.NoteSearchStore

  @spec run(map(), SessionContext.t(), map() | keyword()) ::
          {:ok, Singularity.Retrieval.NoteSearchPage.t()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, params) when is_map(runtime) do
    with {:ok, adapters} <- adapters(runtime),
         {:ok, params} <- bind_vault(params, session.vault_id),
         {:ok, query} <- NoteSearchQuery.new(params) do
      call_adapter(adapters.operation_scope, :with_read_request, [
        runtime,
        session,
        requirement(session),
        fn repo ->
          call_adapter(adapters.note_search, :search, [
            adapters.note_search_store,
            repo,
            query
          ])
        end
      ])
    end
  rescue
    _error -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def run(_runtime, _session, _params), do: invalid()

  defp bind_vault(params, vault_id) do
    with {:ok, params} <- Types.attrs(params),
         :ok <- validate_supplied_vault(params, vault_id) do
      {:ok,
       params
       |> Map.delete("vault_id")
       |> Map.put(:vault_id, vault_id)}
    end
  end

  defp validate_supplied_vault(params, vault_id) do
    supplied =
      [:vault_id, "vault_id"]
      |> Enum.flat_map(fn key ->
        case Map.fetch(params, key) do
          {:ok, value} -> [value]
          :error -> []
        end
      end)

    if Enum.all?(supplied, &(&1 == vault_id)), do: :ok, else: invalid()
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
      note_search: Map.get(runtime, :note_search, NoteLexicalSearch),
      note_search_store: Map.get(runtime, :note_search_store, NoteSearchStore),
      operation_scope: Map.get(runtime, :operation_scope, OperationScope)
    }

    if Enum.all?(Map.values(values), &concrete?/1), do: {:ok, values}, else: invalid()
  end

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
