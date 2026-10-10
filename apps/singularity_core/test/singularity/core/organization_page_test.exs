defmodule Singularity.Core.OrganizationPageTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{Error, Relationship, Tag}

  @page Singularity.Core.OrganizationPage
  @query Singularity.Core.OrganizationPageQuery
  @operations [:resource_tags, :tag_resources, :outgoing, :incoming]
  @source "00000000-0000-4000-8000-000000000a01"
  @target "00000000-0000-4000-8000-000000000a02"
  @version "00000000-0000-4000-8000-000000000a03"
  @owner "00000000-0000-4000-8000-000000000a04"

  test "every operation accepts an empty terminal owner-free page" do
    for operation <- @operations do
      assert {:ok, page} = new(operation, %{items: [], next_cursor: :done})
      assert page.__struct__ == @page
      assert Map.from_struct(page) == %{items: [], next_cursor: :done}
      assert {:ok, ^page} = new(operation, page)
    end
  end

  test "tag items contain only canonical tag identity and first display spelling" do
    items = [tag(1), tag(2, "École")]
    assert {:ok, %{items: ^items, next_cursor: :done}} = new(:resource_tags, terminal(items))
  end

  test "browse items contain only resource identity and an established kind" do
    items =
      for {kind, index} <- Enum.with_index([:asset, :document, :note], 1),
          do: resource(index, kind)

    assert {:ok, %{items: ^items}} = new(:tag_resources, terminal(items))
  end

  test "edge items preserve direction exact nullable pin and established relationship types" do
    for operation <- [:outgoing, :incoming],
        type <- [:related_to, :references, :derived_from],
        pin <- [nil, @version] do
      item = edge(1) |> Map.put(:type, type) |> Map.put(:target_resource_version_id, pin)
      assert {:ok, %{items: [^item]}} = new(operation, terminal([item]))
    end
  end

  test "UUID ordering is strict and independent of endpoint tuple order" do
    for operation <- @operations do
      items = [item(operation, 1), item(operation, 2)]
      assert {:ok, %{items: ^items}} = new(operation, terminal(items))
      assert_invalid(new(operation, terminal(Enum.reverse(items))))
      assert_invalid(new(operation, terminal([hd(items), hd(items)])))
    end

    items = [edge(1), %{edge(2) | source_resource_id: @target, target_resource_id: @source}]
    assert {:ok, %{items: ^items}} = new(:outgoing, terminal(items))
  end

  test "page size is bounded by the validated query limit" do
    for operation <- @operations do
      items = for index <- 1..50, do: item(operation, index)
      assert {:ok, %{items: ^items}} = new(operation, terminal(items), query(50))
      assert_invalid(new(operation, terminal(items), query(49)))
      assert_invalid(new(operation, terminal(items ++ [item(operation, 51)]), query(50)))
    end
  end

  test "continuation requires a full nonempty page and a bounded nonblank cursor" do
    for operation <- @operations do
      items = [item(operation, 1), item(operation, 2)]
      cursor = String.duplicate("a", 2048)

      assert {:ok, %{items: ^items, next_cursor: ^cursor}} =
               new(operation, %{items: items, next_cursor: cursor}, query(2))

      assert_invalid(new(operation, %{items: [], next_cursor: cursor}, query(2)))
      assert_invalid(new(operation, %{items: [hd(items)], next_cursor: cursor}, query(2)))

      for bad <- [nil, "", " \t", String.duplicate("a", 2049), <<255>>, "token" <> <<0>>, 7] do
        assert_invalid(new(operation, %{items: items, next_cursor: bad}, query(2)))
      end
    end
  end

  test "page envelope rejects extra missing and malformed fields" do
    valid = terminal([tag(1)])

    for input <- [
          Map.delete(valid, :items),
          Map.delete(valid, :next_cursor),
          Map.put(valid, :owner_scope_id, @owner),
          Map.put(valid, :count, 1),
          Map.put(valid, :allowed_kinds, [:note]),
          Map.put(valid, :title, "CANARY_PAGE_PRIVATE"),
          Map.put(valid, "items", []),
          %{items: :invalid, next_cursor: :done},
          %{items: [tag(1) | :tail], next_cursor: :done},
          nil,
          [],
          Error.new(:invalid)
        ] do
      assert_invalid(new(:resource_tags, input))
    end
  end

  test "items reject owner capability content and every extra field" do
    for operation <- @operations,
        field <- [
          :owner_scope_id,
          :vault_id,
          :classification,
          :capabilities,
          :title,
          :metadata,
          :body
        ] do
      candidate = Map.put(item(operation, 1), field, "CANARY_ITEM_PRIVATE")
      assert_invalid(new(operation, terminal([candidate])))
    end

    for operation <- @operations,
        field <- Map.keys(item(operation, 1)) do
      assert_invalid(new(operation, terminal([Map.delete(item(operation, 1), field)])))
    end

    for operation <- @operations do
      string_keys =
        Map.new(item(operation, 1), fn {key, value} -> {Atom.to_string(key), value} end)

      assert_invalid(new(operation, terminal([string_keys])))
    end
  end

  test "each required UUID and optional pin must be canonical" do
    for operation <- @operations,
        field <- uuid_fields(operation),
        value <- [String.upcase(@source), "not-a-uuid", nil, 7] do
      assert_invalid(new(operation, terminal([Map.put(item(operation, 1), field, value)])))
    end

    for operation <- [:outgoing, :incoming],
        value <- [String.upcase(@version), "not-a-uuid", 7] do
      assert_invalid(
        new(operation, terminal([Map.put(edge(1), :target_resource_version_id, value)]))
      )
    end
  end

  test "display values kinds types and endpoint identity are revalidated" do
    for display <- [
          "",
          " ",
          " Straße ",
          "E\u0301cole",
          String.duplicate("a", 256),
          <<255>>,
          "x\n",
          7
        ] do
      assert_invalid(new(:resource_tags, terminal([tag(1, display)])))
    end

    for kind <- [:unknown, :all, "note", nil, 7] do
      assert_invalid(new(:tag_resources, terminal([resource(1, kind)])))
    end

    for operation <- [:outgoing, :incoming] do
      for type <- [:unknown, "references", nil, 7] do
        assert_invalid(new(operation, terminal([Map.put(edge(1), :type, type)])))
      end

      assert_invalid(new(operation, terminal([%{edge(1) | target_resource_id: @source}])))
    end
  end

  test "item shape is selected only by the server operation" do
    for operation <- @operations,
        other <- @operations,
        operation != other,
        not (operation in [:outgoing, :incoming] and other in [:outgoing, :incoming]) do
      assert_invalid(new(operation, terminal([item(other, 1)])))
    end

    for operation <- [:unknown, :all, "resource_tags", %{operation: :resource_tags}, nil] do
      assert_invalid(new(operation, terminal([tag(1)])))
    end
  end

  test "ownerful stored tag and relationship values are not accepted as page items" do
    assert {:ok, stored_tag} =
             Tag.new(%{
               tag_id: id(1),
               owner_scope_id: @owner,
               classification: :private,
               display_value: "Straße"
             })

    assert {:ok, stored_edge} =
             Relationship.new(
               Map.merge(edge(1), %{owner_scope_id: @owner, classification: :private})
             )

    assert_invalid(new(:resource_tags, terminal([stored_tag])))
    assert_invalid(new(:outgoing, terminal([stored_edge])))
  end

  test "forged page structs and query values cannot bypass reconstruction" do
    assert {:ok, page} = new(:resource_tags, terminal([tag(1)]))

    for forged <- [
          Map.put(page, :owner_scope_id, @owner),
          Map.delete(page, :next_cursor),
          Map.put(page, :items, [Map.put(tag(1), :body, "CANARY_PAGE_PRIVATE")]),
          Map.put(page, :__struct__, Error)
        ] do
      assert_invalid(new(:resource_tags, forged))
    end

    for forged <- [
          query(20) |> Map.put(:limit, 51),
          query(20) |> Map.put(:allowed_kinds, [:note]),
          %{limit: 20, cursor: nil}
        ] do
      assert_invalid(new(:resource_tags, terminal([tag(1)]), forged))
    end
  end

  defp query(limit) do
    assert {:ok, query} = apply(@query, :new, [%{limit: limit}])
    query
  end

  defp new(operation, page), do: new(operation, page, query(20))
  defp new(operation, page, query), do: apply(@page, :new, [operation, page, query])
  defp terminal(items), do: %{items: items, next_cursor: :done}
  defp tag(index, display \\ "Straße"), do: %{tag_id: id(index), display_value: display}
  defp resource(index, kind), do: %{resource_id: id(index), kind: kind}
  defp item(:resource_tags, index), do: tag(index)
  defp item(:tag_resources, index), do: resource(index, :note)
  defp item(operation, index) when operation in [:outgoing, :incoming], do: edge(index)

  defp edge(index) do
    %{
      relationship_id: id(index),
      source_resource_id: @source,
      target_resource_id: @target,
      target_resource_version_id: nil,
      type: :references
    }
  end

  defp uuid_fields(:resource_tags), do: [:tag_id]
  defp uuid_fields(:tag_resources), do: [:resource_id]

  defp uuid_fields(operation) when operation in [:outgoing, :incoming],
    do: [:relationship_id, :source_resource_id, :target_resource_id]

  defp id(index) do
    suffix = index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
    "00000000-0000-4000-8000-" <> suffix
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid, message: nil, details: %{}, retryable?: false} = error} =
             result

    assert error.details == %{}
  end
end
