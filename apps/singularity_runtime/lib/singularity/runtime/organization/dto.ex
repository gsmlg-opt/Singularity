defmodule Singularity.Runtime.Organization.DTO do
  @moduledoc "Strict conversion of authenticated organization results into closed public DTOs."

  alias Singularity.Core.{Error, KnowledgeValidation, OrganizationPage, OrganizationPageQuery}
  alias Singularity.Core.{Relationship, Tag, Types}
  alias Singularity.Runtime.DTO.OrganizationPage, as: PageDTO
  alias Singularity.Runtime.DTO.OrganizationRelationship, as: RelationshipDTO
  alias Singularity.Runtime.DTO.OrganizationResource, as: ResourceDTO
  alias Singularity.Runtime.DTO.OrganizationTag, as: TagDTO

  @tag_keys [:tag_id, :display_value]
  @resource_keys [:resource_id, :kind]
  @edge_keys [
    :relationship_id,
    :source_resource_id,
    :target_resource_id,
    :target_resource_version_id,
    :type
  ]
  @pages %{
    list_resource_tags: :resource_tags,
    browse_resources_by_tag: :tag_resources,
    list_outgoing_relationships: :outgoing,
    list_backlinks: :incoming
  }

  @spec convert(atom(), term(), term(), term(), term()) ::
          :ok | {:ok, TagDTO.t() | RelationshipDTO.t() | PageDTO.t()} | {:error, Error.t()}
  def convert(operation, reply, owner_id, selector_id, params) do
    with {:ok, _} <- Types.canonical_uuid(%{owner_id: owner_id}, :owner_id),
         {:ok, _} <- Types.canonical_uuid(%{selector_id: selector_id}, :selector_id) do
      convert_reply(operation, reply, owner_id, selector_id, params)
    else
      _invalid -> integrity_failure()
    end
  rescue
    _exception -> integrity_failure()
  catch
    _, _ -> integrity_failure()
  end

  defp convert_reply(operation, :ok, _owner, _selector, _params)
       when operation in [:detach_tag, :unrelate_resource],
       do: :ok

  defp convert_reply(:attach_tag, {:ok, value}, owner, _selector, params) do
    with {:ok, attrs} <- tag_attrs(value, owner),
         {:ok, input} <- KnowledgeValidation.attrs(params, [:name]),
         {:ok, requested} <-
           Tag.new(%{
             tag_id: attrs.tag_id,
             owner_scope_id: owner,
             classification: :private,
             display_value: input[:name]
           }),
         {:ok, stored} <-
           Tag.new(%{
             tag_id: attrs.tag_id,
             owner_scope_id: owner,
             classification: :private,
             display_value: attrs.display_value
           }),
         true <- requested.normalized_key === stored.normalized_key,
         :ok <- validate_item(:resource_tags, attrs) do
      {:ok, struct!(TagDTO, attrs)}
    else
      _invalid -> integrity_failure()
    end
  end

  defp convert_reply(:relate_resource, {:ok, value}, owner, selector, params) do
    with {:ok, attrs} <- relationship_attrs(value, owner),
         {:ok, input} <-
           KnowledgeValidation.attrs(params, [
             :target_resource_id,
             :target_resource_version_id,
             :type
           ]),
         true <- attrs.source_resource_id === selector,
         true <- attrs.target_resource_id === input[:target_resource_id],
         true <- attrs.target_resource_version_id === input[:target_resource_version_id],
         true <- attrs.type === input[:type],
         :ok <- validate_item(:outgoing, attrs) do
      {:ok, struct!(RelationshipDTO, attrs)}
    else
      _invalid -> integrity_failure()
    end
  end

  defp convert_reply(operation, {:ok, value}, _owner, selector, params)
       when is_map_key(@pages, operation) do
    core_operation = Map.fetch!(@pages, operation)

    with {:ok, query} <- OrganizationPageQuery.new(params),
         {:ok, raw} <- page_attrs(value, core_operation),
         {:ok, page} <- OrganizationPage.new(core_operation, raw, query),
         true <- bound_items?(core_operation, page.items, selector) do
      {:ok,
       %PageDTO{
         items: Enum.map(page.items, &struct!(item_module(core_operation), &1)),
         next_cursor: if(page.next_cursor === :done, do: nil, else: page.next_cursor)
       }}
    else
      _invalid -> integrity_failure()
    end
  end

  defp convert_reply(_operation, _reply, _owner, _selector, _params), do: integrity_failure()

  defp tag_attrs(%Tag{} = value, owner) do
    with {:ok, canonical} <- Tag.new(value),
         true <- canonical === value,
         true <- value.owner_scope_id === owner,
         :private <- value.classification do
      {:ok, Map.take(Map.from_struct(value), @tag_keys)}
    else
      _invalid -> integrity_failure()
    end
  end

  defp tag_attrs(value, _owner), do: public_attrs(value, TagDTO, @tag_keys)

  defp relationship_attrs(%Relationship{} = value, owner) do
    with {:ok, canonical} <- Relationship.new(value),
         true <- canonical === value,
         true <- value.owner_scope_id === owner,
         :private <- value.classification do
      {:ok, Map.take(Map.from_struct(value), @edge_keys)}
    else
      _invalid -> integrity_failure()
    end
  end

  defp relationship_attrs(value, _owner),
    do: public_attrs(value, RelationshipDTO, @edge_keys)

  defp page_attrs(%PageDTO{} = value, operation) do
    with {:ok, attrs} <- public_attrs(value, PageDTO, [:items, :next_cursor]),
         true <- is_nil(attrs.next_cursor) or is_binary(attrs.next_cursor),
         {:ok, items} <- typed_items(attrs.items, operation, []) do
      {:ok,
       %{
         items: items,
         next_cursor: if(is_nil(attrs.next_cursor), do: :done, else: attrs.next_cursor)
       }}
    else
      _invalid -> integrity_failure()
    end
  end

  defp page_attrs(%OrganizationPage{} = value, _operation), do: {:ok, value}

  defp page_attrs(value, _operation) when is_map(value) and not is_struct(value),
    do: {:ok, value}

  defp page_attrs(_value, _operation), do: integrity_failure()

  defp typed_items([], _operation, acc), do: {:ok, Enum.reverse(acc)}

  defp typed_items([item | rest], operation, acc) do
    module = item_module(operation)

    with true <- is_struct(item, module),
         {:ok, attrs} <- public_attrs(item, module, item_keys(operation)) do
      typed_items(rest, operation, [attrs | acc])
    else
      _invalid -> integrity_failure()
    end
  end

  defp typed_items(_items, _operation, _acc), do: integrity_failure()

  defp bound_items?(:outgoing, items, selector),
    do: Enum.all?(items, &(&1.source_resource_id === selector))

  defp bound_items?(:incoming, items, selector),
    do: Enum.all?(items, &(&1.target_resource_id === selector))

  defp bound_items?(_operation, _items, _selector), do: true

  defp validate_item(operation, attrs) do
    with {:ok, query} <- OrganizationPageQuery.new(%{limit: 1}),
         {:ok, _} <- OrganizationPage.new(operation, %{items: [attrs], next_cursor: :done}, query) do
      :ok
    else
      _invalid -> integrity_failure()
    end
  end

  defp public_attrs(value, module, keys) when is_map(value) do
    cond do
      is_struct(value, module) -> exact_attrs(Map.from_struct(value), keys)
      is_struct(value) -> integrity_failure()
      true -> exact_attrs(value, keys)
    end
  end

  defp public_attrs(_value, _module, _keys), do: integrity_failure()

  defp exact_attrs(value, keys) do
    if Enum.sort(Map.keys(value)) === Enum.sort(keys),
      do: {:ok, value},
      else: integrity_failure()
  end

  defp item_module(:resource_tags), do: TagDTO
  defp item_module(:tag_resources), do: ResourceDTO
  defp item_module(operation) when operation in [:outgoing, :incoming], do: RelationshipDTO
  defp item_keys(:resource_tags), do: @tag_keys
  defp item_keys(:tag_resources), do: @resource_keys
  defp item_keys(operation) when operation in [:outgoing, :incoming], do: @edge_keys

  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
end
