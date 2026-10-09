defmodule Singularity.Runtime.DTO.KnowledgeSearchResult do
  @moduledoc "A public version-pinned search summary stripped of validated internal scope."

  alias Singularity.Core.{Error, SourceLocator, Types}
  alias Singularity.Retrieval.KnowledgeSearchQuery
  alias Singularity.Retrieval.KnowledgeSearchResult, as: InternalResult

  @fields [
    :kind,
    :resource_id,
    :resource_version_id,
    :fragment_id,
    :title,
    :snippet,
    :locator,
    :source_inserted_at,
    :rank
  ]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          kind: :note | :document,
          resource_id: Types.id(),
          resource_version_id: Types.id(),
          fragment_id: String.t() | nil,
          title: String.t(),
          snippet: String.t(),
          locator: SourceLocator.t(),
          source_inserted_at: DateTime.t(),
          rank: 0..7_000_000
        }

  @spec from_result(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_result(result, query) do
    with {:ok, query} <- KnowledgeSearchQuery.validate(query) do
      convert(result, query)
    end
  end

  defp convert(%InternalResult{} = result, query) do
    with {:ok, ^result} <- InternalResult.new(result, query) do
      {:ok, struct!(__MODULE__, Map.take(result, @fields))}
    else
      _ -> unavailable()
    end
  rescue
    _ -> unavailable()
  end

  defp convert(_, _), do: unavailable()

  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
