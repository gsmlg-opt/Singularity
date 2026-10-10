defmodule Singularity.Core.OrganizationPage do
  @moduledoc "One bounded UUID-ordered page of owner-free organization items."

  alias Singularity.Core.{Error, KnowledgeValidation, OrganizationPageQuery, Types}

  @operations [:resource_tags, :tag_resources, :outgoing, :incoming]
  @edge_keys [
    :relationship_id,
    :source_resource_id,
    :target_resource_id,
    :target_resource_version_id,
    :type
  ]
  @enforce_keys [:items, :next_cursor]
  defstruct @enforce_keys

  @type operation :: :resource_tags | :tag_resources | :outgoing | :incoming
  @type tag_item :: %{tag_id: Types.id(), display_value: String.t()}
  @type resource_item :: %{resource_id: Types.id(), kind: :asset | :document | :note}
  @type relationship_item :: %{
          relationship_id: Types.id(),
          source_resource_id: Types.id(),
          target_resource_id: Types.id(),
          target_resource_version_id: Types.id() | nil,
          type: :related_to | :references | :derived_from
        }
  @type item :: tag_item() | resource_item() | relationship_item()
  @type t :: %__MODULE__{items: [item()], next_cursor: String.t() | :done}

  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(operation, %__MODULE__{} = page, query) do
    with {:ok, ^page} <- new(operation, Map.from_struct(page), query) do
      {:ok, page}
    else
      _invalid -> Types.invalid()
    end
  end

  def new(operation, page, query) when operation in @operations do
    with {:ok, query} <- OrganizationPageQuery.validate(query),
         true <- exact_fields?(page, [:items, :next_cursor]),
         {:ok, count} <- items(page.items, operation, query.limit, nil, 0),
         :ok <- cursor(page.next_cursor, count, query.limit) do
      {:ok, %__MODULE__{items: page.items, next_cursor: page.next_cursor}}
    else
      _invalid -> Types.invalid()
    end
  end

  def new(_operation, _page, _query), do: Types.invalid()

  defp items([], _operation, _limit, _previous, count), do: {:ok, count}

  defp items([item | rest], operation, limit, previous, count) when count < limit do
    with {:ok, key} <- item(operation, item),
         true <- is_nil(previous) or previous < key do
      items(rest, operation, limit, key, count + 1)
    else
      _invalid -> Types.invalid()
    end
  end

  defp items(_items, _operation, _limit, _previous, _count), do: Types.invalid()

  defp item(:resource_tags, item) do
    with true <- exact_fields?(item, [:tag_id, :display_value]),
         {:ok, id} <- Types.canonical_uuid(item, :tag_id),
         {:ok, display} <- KnowledgeValidation.string(item.display_value, 255),
         true <- display != "",
         true <- String.trim(display) == display,
         true <- String.normalize(display, :nfc) == display,
         false <- Regex.match?(~r/\p{Cc}/u, display) do
      {:ok, id}
    else
      _invalid -> Types.invalid()
    end
  end

  defp item(:tag_resources, item) do
    with true <- exact_fields?(item, [:resource_id, :kind]),
         {:ok, id} <- Types.canonical_uuid(item, :resource_id),
         true <- item.kind in [:asset, :document, :note] do
      {:ok, id}
    else
      _invalid -> Types.invalid()
    end
  end

  defp item(operation, item) when operation in [:outgoing, :incoming] do
    with true <- exact_fields?(item, @edge_keys),
         {:ok, id} <- Types.canonical_uuid(item, :relationship_id),
         {:ok, source} <- Types.canonical_uuid(item, :source_resource_id),
         {:ok, target} <- Types.canonical_uuid(item, :target_resource_id),
         true <- source != target,
         true <- item.type in [:related_to, :references, :derived_from],
         true <-
           is_nil(item.target_resource_version_id) or
             match?({:ok, _}, Types.canonical_uuid(item, :target_resource_version_id)) do
      {:ok, id}
    else
      _invalid -> Types.invalid()
    end
  end

  defp cursor(:done, _count, _limit), do: :ok

  defp cursor(cursor, count, limit) when count == limit and count > 0 do
    with {:ok, cursor} <- KnowledgeValidation.string(cursor, 2048),
         true <- String.trim(cursor) != "" do
      :ok
    else
      _invalid -> Types.invalid()
    end
  end

  defp cursor(_cursor, _count, _limit), do: Types.invalid()

  defp exact_fields?(value, keys) when is_map(value) and not is_struct(value),
    do: map_size(value) == length(keys) and Enum.all?(keys, &Map.has_key?(value, &1))

  defp exact_fields?(_value, _keys), do: false
end
