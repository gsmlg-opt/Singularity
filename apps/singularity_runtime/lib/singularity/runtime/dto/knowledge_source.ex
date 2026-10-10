defmodule Singularity.Runtime.DTO.KnowledgeSource do
  @moduledoc "An owner-free exact immutable text source with canonical provenance."

  alias Singularity.Core.{
    DocumentFragment,
    Error,
    KnowledgeValidation,
    SearchSource,
    SourceLocator,
    Types
  }

  alias Singularity.Retrieval.{KnowledgeSearchQuery, KnowledgeSearchResult}

  @selector_fields [:kind, :resource_id, :resource_version_id, :fragment_id]
  @fields @selector_fields ++ [:ordinal, :title, :body, :locator, :source_inserted_at]
  @internal_fields @fields ++ [:owner_scope_id, :classification]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          kind: :note | :document,
          resource_id: Types.id(),
          resource_version_id: Types.id(),
          fragment_id: String.t() | nil,
          ordinal: non_neg_integer(),
          title: String.t(),
          body: String.t(),
          locator: SourceLocator.t(),
          source_inserted_at: DateTime.t()
        }

  @spec from_source(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_source(input, owner, selector) do
    with {:ok, source} <- SearchSource.new(selector),
         true <- not is_struct(selector) or source === selector,
         {:ok, query} <- KnowledgeSearchQuery.new(owner, %{kind: source.kind}) do
      convert(input, source, query)
    else
      _ -> {:error, Error.new(:invalid)}
    end
  end

  defp convert(input, source, query) when is_map(input) and not is_struct(input) do
    with true <- map_size(input) == length(@internal_fields),
         true <- Enum.all?(@internal_fields, &Map.has_key?(input, &1)),
         true <- Map.take(input, @selector_fields) === Map.from_struct(source),
         {:ok, body} <- KnowledgeValidation.string(input.body, body_limit(source.kind)),
         {:ok, entry} <- SearchSource.entry_id(source),
         # Reuse the closed summary validator for owner, identity, title, ordinal,
         # locator and lossless UTC timestamp, without inventing a second policy.
         {:ok, summary} <- KnowledgeSearchResult.new(summary(input, entry), query),
         true <- canonical_locator?(input.locator, summary.locator),
         :ok <- fragment_identity(input, summary.locator) do
      {:ok,
       struct!(
         __MODULE__,
         input
         |> Map.take(@fields)
         |> Map.put(:body, body)
         |> Map.put(:locator, summary.locator)
       )}
    else
      _ -> unavailable()
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp convert(_, _, _), do: unavailable()

  defp summary(input, entry),
    do:
      input
      |> Map.delete(:body)
      |> Map.merge(%{entry_id: entry, snippet: "", rank: 0})

  defp canonical_locator?(%SourceLocator{} = original, validated), do: original === validated
  defp canonical_locator?(original, validated), do: original === SourceLocator.to_map(validated)

  defp fragment_identity(%{kind: :note}, _), do: :ok

  defp fragment_identity(input, locator) do
    attrs =
      input
      |> Map.take([
        :owner_scope_id,
        :classification,
        :resource_id,
        :resource_version_id,
        :fragment_id,
        :ordinal
      ])
      |> Map.merge(%{text: input.body, locator: locator})

    with {:ok, fragment} <- DocumentFragment.new(attrs),
         true <- fragment.text === input.body and fragment.locator === locator do
      :ok
    else
      _ -> unavailable()
    end
  end

  defp body_limit(:note), do: 1_048_576
  defp body_limit(:document), do: 65_536
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
