defmodule Singularity.Runtime.Search.Search do
  @moduledoc "Composes unified knowledge search inside the existing authenticated read scope."

  alias Singularity.Core.Error
  alias Singularity.Retrieval.{KnowledgeSearch, KnowledgeSearchQuery}
  alias Singularity.Runtime.DTO.KnowledgeSearchPage
  alias Singularity.Runtime.{OperationScope, SessionContext}
  alias Singularity.Storage.Postgres.KnowledgeSearchStore

  @spec run(map(), SessionContext.t(), term()) ::
          {:ok, Singularity.Retrieval.KnowledgeSearchPage.t()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, params) when is_map(runtime) do
    with {:ok, query} <- KnowledgeSearchQuery.new(session.vault_id, params) do
      result =
        runtime
        |> Map.get(:operation_scope, OperationScope)
        |> call_adapter(:with_read_request, [
          runtime,
          session,
          requirement(session, query.kind),
          fn repo ->
            call_adapter(Map.get(runtime, :knowledge_search, KnowledgeSearch), :search, [
              Map.get(runtime, :knowledge_search_store, KnowledgeSearchStore),
              repo,
              query
            ])
          end
        ])

      with {:ok, page} <- sanitize(result),
           {:ok, _public} <- KnowledgeSearchPage.from_page(page, query) do
        {:ok, page}
      end
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def run(_, _, _), do: {:error, Error.new(:invalid)}

  defp requirement(session, kind) do
    base = %{
      vault_id: session.vault_id,
      classification: :private,
      requires_unlocked?: kind != :document
    }

    case kind do
      :note -> Map.put(base, :required_capability, "note.read")
      :document -> Map.put(base, :required_capability, "asset.read")
      :all -> Map.put(base, :required_capabilities, ["asset.read", "note.read"])
    end
  end

  defp call_adapter(module, function, arguments) when is_atom(module) and not is_nil(module),
    do: apply(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [context | arguments])

  defp sanitize({:ok, _} = result), do: result

  defp sanitize({:error, %Error{code: code, retryable?: retryable?}})
       when is_boolean(retryable?) do
    if code in Error.codes(),
      do: {:error, Error.new(code, retryable?: retryable?)},
      else: unavailable()
  end

  defp sanitize(_), do: unavailable()
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
