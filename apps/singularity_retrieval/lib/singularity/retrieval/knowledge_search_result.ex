defmodule Singularity.Retrieval.KnowledgeSearchResult do
  @moduledoc "A validated, version-pinned internal search summary with no full source body."

  alias Singularity.Core.{
    Error,
    KnowledgeValidation,
    SearchPolicy,
    SearchSource,
    SourceLocator,
    Types
  }

  alias Singularity.Retrieval.KnowledgeSearchQuery

  @datetime_fields DateTime.__struct__() |> Map.keys() |> Enum.sort()
  @selector_fields [:kind, :resource_id, :resource_version_id, :fragment_id]
  @enforce_keys @selector_fields ++
                  [
                    :owner_scope_id,
                    :classification,
                    :entry_id,
                    :ordinal,
                    :title,
                    :snippet,
                    :locator,
                    :source_inserted_at,
                    :rank
                  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          owner_scope_id: Types.id(),
          classification: :private,
          kind: :note | :document,
          resource_id: Types.id(),
          resource_version_id: Types.id(),
          fragment_id: String.t() | nil,
          entry_id: String.t(),
          ordinal: non_neg_integer(),
          title: String.t(),
          snippet: String.t(),
          locator: SourceLocator.t(),
          source_inserted_at: DateTime.t(),
          rank: 0..7_000_000
        }

  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = input, query), do: new(Map.from_struct(input), query)

  def new(input, query) when is_map(input) and not is_struct(input) do
    policy = SearchPolicy.current()

    with {:ok, query} <- KnowledgeSearchQuery.validate(query),
         true <- map_size(input) == length(@enforce_keys),
         true <- Enum.all?(@enforce_keys, &Map.has_key?(input, &1)),
         true <- input.owner_scope_id == query.owner_scope_id,
         :private <- input.classification,
         {:ok, source} <- SearchSource.new(Map.take(input, @selector_fields)),
         true <- source.kind == input.kind and query.kind in [:all, source.kind],
         {:ok, entry_id} <- SearchSource.entry_id(source),
         true <- input.entry_id == entry_id,
         {:ok, ordinal} <- KnowledgeValidation.integer(input.ordinal),
         {:ok, title} <- KnowledgeValidation.string(input.title, 255),
         true <- title != "" and String.trim(title) == title,
         {:ok, snippet} <- KnowledgeValidation.string(input.snippet, policy.snippet_bytes),
         true <- length(String.codepoints(snippet)) <= policy.snippet_codepoints,
         {:ok, locator} <- SourceLocator.new(input.locator),
         true <- valid_provenance?(source.kind, ordinal, locator),
         {:ok, timestamp} <- KnowledgeValidation.utc_datetime(input, :source_inserted_at),
         true <- Enum.sort(Map.keys(timestamp)) == @datetime_fields,
         "UTC" <- timestamp.zone_abbr,
         {:ok, rank} <- KnowledgeValidation.integer(input.rank),
         true <- rank <= policy.max_rank and (query.q != "" or rank == 0) do
      {:ok, struct!(__MODULE__, Map.put(input, :locator, locator))}
    else
      _ -> Types.invalid()
    end
  end

  def new(_, _), do: Types.invalid()

  defp valid_provenance?(:note, 0, %SourceLocator{kind: "markdown", fields: fields}),
    do: fields == %{heading_path: []}

  defp valid_provenance?(:note, _, _), do: false

  defp valid_provenance?(:document, ordinal, %SourceLocator{kind: "fragment", fields: fields}),
    do: fields.ordinal == ordinal

  defp valid_provenance?(:document, _, _), do: true
end
