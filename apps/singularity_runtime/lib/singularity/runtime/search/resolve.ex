defmodule Singularity.Runtime.Search.Resolve do
  @moduledoc "Resolves an immutable text selector through its existing kind-specific read authority."

  alias Singularity.Core.{Error, SearchSource, Types}
  alias Singularity.Runtime.DTO.KnowledgeSource
  alias Singularity.Runtime.{OperationScope, SessionContext}
  alias Singularity.Storage.Postgres.KnowledgeSearchStore

  @spec run(map(), SessionContext.t(), term()) :: {:ok, map()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, input) when is_map(runtime) do
    with {:ok, selector} <- SearchSource.new(input),
         true <- not is_struct(input) or input === selector,
         {:ok, _owner} <- Types.canonical_uuid(%{owner: session.vault_id}, :owner) do
      result =
        runtime
        |> Map.get(:operation_scope, OperationScope)
        |> call_adapter(:with_read_request, [
          runtime,
          session,
          requirement(session, selector.kind),
          fn repo ->
            call_adapter(
              Map.get(runtime, :knowledge_search_store, KnowledgeSearchStore),
              :resolve,
              [repo, selector]
            )
          end
        ])

      with {:ok, source} <- sanitize(result),
           {:ok, _public} <- KnowledgeSource.from_source(source, session.vault_id, selector) do
        {:ok, source}
      end
    else
      _ -> {:error, Error.new(:invalid)}
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def run(_, _, _), do: {:error, Error.new(:invalid)}

  defp requirement(session, kind) do
    %{
      vault_id: session.vault_id,
      classification: :private,
      required_capability: if(kind == :note, do: "note.read", else: "asset.read"),
      requires_unlocked?: kind == :note
    }
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
