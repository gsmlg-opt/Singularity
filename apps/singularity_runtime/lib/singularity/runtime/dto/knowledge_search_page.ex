defmodule Singularity.Runtime.DTO.KnowledgeSearchPage do
  @moduledoc "A bounded public page converted from a fully revalidated internal search page."

  alias Singularity.Core.Error
  alias Singularity.Retrieval.KnowledgeSearchPage, as: InternalPage
  alias Singularity.Retrieval.KnowledgeSearchQuery
  alias Singularity.Runtime.DTO.KnowledgeSearchResult

  @enforce_keys [:items, :next_cursor]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          items: [KnowledgeSearchResult.t()],
          next_cursor: String.t() | nil
        }

  @spec from_page(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_page(page, query) do
    with {:ok, query} <- KnowledgeSearchQuery.validate(query) do
      convert(page, query)
    end
  end

  defp convert(%InternalPage{next_cursor: cursor} = page, query)
       when is_nil(cursor) or is_binary(cursor) do
    raw_page =
      page
      |> Map.from_struct()
      |> Map.put(:next_cursor, if(is_nil(cursor), do: :done, else: cursor))

    with {:ok, ^page} <- InternalPage.new(raw_page, query),
         {:ok, items} <- public_items(page.items, query) do
      {:ok, %__MODULE__{items: items, next_cursor: cursor}}
    else
      _ -> unavailable()
    end
  rescue
    _ -> unavailable()
  end

  defp convert(_, _), do: unavailable()

  defp public_items(items, query) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case KnowledgeSearchResult.from_result(item, query) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        _ -> {:halt, unavailable()}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
