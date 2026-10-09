defmodule Singularity.Retrieval.KnowledgeSearch do
  @moduledoc "Validates queries and untrusted persistence results at the knowledge search port."

  alias Singularity.Core.{Error, Types}
  alias Singularity.Retrieval.{KnowledgeSearchPage, KnowledgeSearchQuery}

  @spec search(module(), term(), KnowledgeSearchQuery.t()) ::
          {:ok, KnowledgeSearchPage.t()} | {:error, Error.t()}
  def search(store, context, query) when is_atom(store) and store not in [nil, true, false] do
    with {:ok, query} <- KnowledgeSearchQuery.validate(query) do
      case store.search(context, Map.from_struct(query)) do
        {:ok, page} -> KnowledgeSearchPage.new(page, query)
        {:error, %Error{} = error} -> sanitize_error(error)
        _ -> unavailable()
      end
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def search(_, _, _), do: Types.invalid()

  defp sanitize_error(%Error{code: code, retryable?: retryable?}) do
    if code in Error.codes() and is_boolean(retryable?),
      do: {:error, Error.new(code, retryable?: retryable?)},
      else: unavailable()
  end

  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
