defmodule Singularity.Retrieval.KnowledgeSearchQuery do
  @moduledoc "Plain-text search filters bound to a separately authenticated owner."

  alias Singularity.Core.{Error, KnowledgeValidation, SearchPolicy, Types}

  @public_fields [:q, :kind, :tag_ids, :limit, :cursor]
  @enforce_keys @public_fields ++ [:owner_scope_id, :classification, :policy_version]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          owner_scope_id: Types.id(),
          classification: :private,
          q: String.t(),
          kind: :all | :note | :document,
          tag_ids: [Types.id()],
          limit: 1..50,
          cursor: String.t() | nil,
          policy_version: 1
        }

  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(owner_scope_id, params) do
    policy = SearchPolicy.current()

    with {:ok, owner} <- Types.canonical_uuid(%{owner: owner_scope_id}, :owner),
         {:ok, attrs} <- KnowledgeValidation.attrs(params, @public_fields),
         {:ok, q} <- KnowledgeValidation.string(Map.get(attrs, :q, ""), policy.query_bytes),
         {:ok, kind} <- kind(Map.get(attrs, :kind, :all)),
         {:ok, tags} <- tag_ids(Map.get(attrs, :tag_ids, []), policy.tag_count),
         {:ok, limit} <- KnowledgeValidation.integer(Map.get(attrs, :limit, 20), 1),
         true <- limit <= policy.page_limit,
         {:ok, cursor} <- cursor(Map.get(attrs, :cursor), policy.cursor_bytes) do
      {:ok,
       %__MODULE__{
         owner_scope_id: owner,
         classification: :private,
         q: String.trim(q),
         kind: kind,
         tag_ids: tags,
         limit: limit,
         cursor: cursor,
         policy_version: policy.version
       }}
    else
      _ -> Types.invalid()
    end
  end

  @doc "Revalidates an internal query without accepting public owner or policy overrides."
  @spec validate(term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{owner_scope_id: owner} = query) do
    with {:ok, normalized} <- new(owner, Map.take(query, @public_fields)),
         true <- normalized === query do
      {:ok, normalized}
    else
      _ -> Types.invalid()
    end
  end

  def validate(_), do: Types.invalid()

  defp kind(value) when value in [:all, "all"], do: {:ok, :all}
  defp kind(value) when value in [:note, "note"], do: {:ok, :note}
  defp kind(value) when value in [:document, "document"], do: {:ok, :document}
  defp kind(_), do: Types.invalid()

  defp tag_ids(values, maximum) when is_list(values) and length(values) <= maximum do
    if Enum.all?(values, &match?({:ok, _}, Types.canonical_uuid(%{id: &1}, :id))),
      do: {:ok, values |> Enum.uniq() |> Enum.sort()},
      else: Types.invalid()
  end

  defp tag_ids(_, _), do: Types.invalid()

  defp cursor(nil, _maximum), do: {:ok, nil}

  defp cursor(value, maximum) do
    with {:ok, value} <- KnowledgeValidation.string(value, maximum),
         true <- String.trim(value) != "" do
      {:ok, value}
    else
      _ -> Types.invalid()
    end
  end
end
