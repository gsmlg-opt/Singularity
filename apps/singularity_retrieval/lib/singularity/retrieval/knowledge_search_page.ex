defmodule Singularity.Retrieval.KnowledgeSearchPage do
  @moduledoc "One bounded, validated page of version-pinned internal search summaries."

  alias Singularity.Core.{Error, KnowledgeValidation, SearchPolicy}
  alias Singularity.Retrieval.{KnowledgeSearchQuery, KnowledgeSearchResult}

  @enforce_keys [:items, :next_cursor]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          items: [KnowledgeSearchResult.t()],
          next_cursor: String.t() | nil
        }

  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%{items: items, next_cursor: cursor} = page, query)
      when is_map(page) and not is_struct(page) and map_size(page) == 2 and is_list(items) do
    with {:ok, query} <- KnowledgeSearchQuery.validate(query),
         true <- bounded_items?(items, query.limit),
         {:ok, items} <- results(items, query),
         true <- length(Enum.uniq_by(items, & &1.entry_id)) == length(items),
         {:ok, cursor} <- cursor(cursor) do
      {:ok, %__MODULE__{items: items, next_cursor: cursor}}
    else
      _ -> unavailable()
    end
  end

  def new(_, _), do: unavailable()

  defp bounded_items?(items, limit) when is_list(items) and length(items) <= limit, do: true
  defp bounded_items?(_, _), do: false

  defp results(items, query) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case KnowledgeSearchResult.new(item, query) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        _ -> {:halt, unavailable()}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp cursor(:done), do: {:ok, nil}

  defp cursor(value) do
    with {:ok, value} <- KnowledgeValidation.string(value, SearchPolicy.current().cursor_bytes),
         true <- String.trim(value) != "" do
      {:ok, value}
    else
      _ -> unavailable()
    end
  end

  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
