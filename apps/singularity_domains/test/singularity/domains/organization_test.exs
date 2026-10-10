defmodule Singularity.Domains.OrganizationTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error

  @organization Singularity.Domains.Organization
  @query Singularity.Core.OrganizationPageQuery
  @page Singularity.Core.OrganizationPage
  @selector "00000000-0000-4000-8000-000000000a01"
  @target "00000000-0000-4000-8000-000000000a02"
  @allowed [:asset, :document, :note]

  # These observers establish pure dispatch only, not SQL, RLS or authorization evidence.
  defmodule TagPort do
    def list_page_in_scope(context, selector, query, allowed_kinds),
      do: observe(context, :list_page_in_scope, selector, query, allowed_kinds)

    def browse_in_scope(context, selector, query, allowed_kinds),
      do: observe(context, :browse_in_scope, selector, query, allowed_kinds)

    defp observe(context, operation, selector, query, allowed_kinds) do
      send(
        context.observer,
        {:organization_port, operation, context, selector, query, allowed_kinds}
      )

      context.reply
    end
  end

  defmodule RelationshipPort do
    def outgoing_page_in_scope(context, selector, query, allowed_kinds),
      do: observe(context, :outgoing_page_in_scope, selector, query, allowed_kinds)

    def incoming_page_in_scope(context, selector, query, allowed_kinds),
      do: observe(context, :incoming_page_in_scope, selector, query, allowed_kinds)

    defp observe(context, operation, selector, query, allowed_kinds) do
      send(
        context.observer,
        {:organization_port, operation, context, selector, query, allowed_kinds}
      )

      context.reply
    end
  end

  test "resource tags dispatch exactly to their scoped tag page port" do
    assert_dispatch(:resource_tags, :list_page_in_scope)
  end

  test "tag browse dispatches exactly to its scoped resource page port" do
    assert_dispatch(:tag_resources, :browse_in_scope)
  end

  test "outgoing dispatches exactly to its scoped outgoing edge page port" do
    assert_dispatch(:outgoing, :outgoing_page_in_scope)
  end

  test "backlinks dispatch exactly to their scoped incoming edge page port" do
    assert_dispatch(:incoming, :incoming_page_in_scope)
  end

  test "a validated full page preserves its opaque continuation" do
    query = query()
    items = [%{tag() | tag_id: @selector}, tag()]
    raw = %{items: items, next_cursor: "next-token"}

    assert {:ok, result} = page(adapters({:ok, raw}), :resource_tags, @selector, query, @allowed)
    assert Map.from_struct(result) == raw
    assert_received {:organization_port, :list_page_in_scope, _, @selector, ^query, @allowed}
    refute_received {:organization_port, _, _, _, _, _}
  end

  test "trusted allowed kinds are forwarded separately from the fixed client query" do
    query = query()
    raw = %{items: [], next_cursor: :done}
    adapters = adapters({:ok, raw})

    for allowed <- [[], [:note], [:asset, :document], @allowed] do
      assert {:ok, %{items: [], next_cursor: :done}} =
               page(adapters, :tag_resources, @selector, query, allowed)

      assert_received {:organization_port, :browse_in_scope, _context, @selector, ^query,
                       ^allowed}

      assert Map.from_struct(query) == %{limit: 2, cursor: "request-token"}
    end
  end

  test "invalid operation selector query and allowed kinds fail before any port call" do
    adapters = adapters({:ok, %{items: [], next_cursor: :done}})
    query = query()

    for operation <- [:unknown, :relate, :save, "resource_tags", nil, %{operation: :outgoing}] do
      assert_invalid(page(adapters, operation, @selector, query, @allowed))
    end

    for selector <- [String.upcase(@selector), "not-a-uuid", nil, %{owner_scope_id: @selector}] do
      assert_invalid(page(adapters, :resource_tags, selector, query, @allowed))
    end

    for forged <- [
          Map.from_struct(query),
          Map.put(query, :limit, 51),
          Map.put(query, :owner_scope_id, @selector),
          Map.put(query, :allowed_kinds, [:note]),
          Map.put(query, :capabilities, ["note.read"])
        ] do
      assert_invalid(page(adapters, :resource_tags, @selector, forged, @allowed))
    end

    for allowed <- [nil, :all, "note", [:unknown], ["note"], [:note, :note], [:note | :tail]] do
      assert_invalid(page(adapters, :resource_tags, @selector, query, allowed))
    end

    refute_received {:organization_port, _, _, _, _, _}
  end

  test "missing malformed or nonport adapters fail without dispatch" do
    valid = adapters({:ok, %{items: [], next_cursor: :done}})

    for malformed <- [
          %{},
          Map.delete(valid, :tags),
          Map.put(valid, :tags, nil),
          Map.put(valid, :tags, {__MODULE__, %{}}),
          Map.put(valid, :tags, {"not-a-module", %{}}),
          nil
        ] do
      assert_invalid(page(malformed, :resource_tags, @selector, query(), @allowed))
    end

    refute_received {:organization_port, _, _, _, _, _}
  end

  test "malformed adapter pages and owner or content injection never escape the boundary" do
    for raw <- [
          %{items: [], next_cursor: "continuation"},
          %{items: [tag(), tag()], next_cursor: :done},
          %{items: [Map.put(tag(), :owner_scope_id, @selector)], next_cursor: :done},
          %{items: [Map.put(tag(), :body, "CANARY_DOMAIN_PRIVATE")], next_cursor: :done},
          %{items: [tag()], next_cursor: :done, count: 1},
          %{items: [tag()], next_cursor: :done, capabilities: ["note.read"]},
          %{items: [tag() | :tail], next_cursor: :done},
          %{items: [resource()], next_cursor: :done},
          :ok,
          nil
        ] do
      assert_sanitized_error(
        page(adapters({:ok, raw}), :resource_tags, @selector, query(), @allowed)
      )

      assert_received {:organization_port, :list_page_in_scope, _, _, _, _}
    end
  end

  test "canonical page structs are revalidated rather than trusted on return" do
    query = query()
    raw = %{items: [tag()], next_cursor: :done}
    assert {:ok, canonical} = apply(@page, :new, [:resource_tags, raw, query])

    assert {:ok, ^canonical} =
             page(adapters({:ok, canonical}), :resource_tags, @selector, query, @allowed)

    assert_received {:organization_port, :list_page_in_scope, _, _, _, _}

    forged = Map.put(canonical, :owner_scope_id, "CANARY_DOMAIN_PRIVATE")

    assert_sanitized_error(
      page(adapters({:ok, forged}), :resource_tags, @selector, query, @allowed)
    )

    assert_received {:organization_port, :list_page_in_scope, _, _, _, _}
  end

  test "adapter errors are sanitized without returning content or arbitrary terms" do
    for reply <- [
          {:error,
           Error.new(:forbidden,
             message: "CANARY_DOMAIN_PRIVATE",
             details: %{body: "CANARY_DOMAIN_PRIVATE"}
           )},
          {:error, %{code: :unknown, message: "CANARY_DOMAIN_PRIVATE"}},
          {:error, "CANARY_DOMAIN_PRIVATE"},
          {:unexpected, "CANARY_DOMAIN_PRIVATE"}
        ] do
      assert_sanitized_error(page(adapters(reply), :resource_tags, @selector, query(), @allowed))
      assert_received {:organization_port, :list_page_in_scope, _, _, _, _}
    end
  end

  defp assert_dispatch(operation, callback) do
    query = query()
    item = item(operation)
    raw = %{items: [item], next_cursor: :done}
    adapters = adapters({:ok, raw})
    context = elem(Map.fetch!(adapters, port_key(operation)), 1)

    assert {:ok, result} = page(adapters, operation, @selector, query, @allowed)
    assert result.__struct__ == @page
    assert Map.from_struct(result) == raw
    assert_received {:organization_port, ^callback, ^context, @selector, ^query, @allowed}
    refute_received {:organization_port, _, _, _, _, _}
  end

  defp adapters(reply) do
    %{
      tags: {TagPort, %{observer: self(), reply: reply, identity: :tags}},
      relationships:
        {RelationshipPort, %{observer: self(), reply: reply, identity: :relationships}}
    }
  end

  defp page(adapters, operation, selector, query, allowed),
    do: apply(@organization, :page, [adapters, operation, selector, query, allowed])

  defp query do
    assert {:ok, query} = apply(@query, :new, [%{limit: 2, cursor: "request-token"}])
    query
  end

  defp port_key(operation) when operation in [:resource_tags, :tag_resources], do: :tags
  defp port_key(operation) when operation in [:outgoing, :incoming], do: :relationships
  defp item(:resource_tags), do: tag()
  defp item(:tag_resources), do: resource()
  defp item(operation) when operation in [:outgoing, :incoming], do: edge()
  defp tag, do: %{tag_id: @target, display_value: "Straße"}
  defp resource, do: %{resource_id: @target, kind: :note}

  defp edge do
    %{
      relationship_id: @target,
      source_resource_id: @selector,
      target_resource_id: @target,
      target_resource_version_id: nil,
      type: :references
    }
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid}} = result
    assert_sanitized_error(result)
  end

  defp assert_sanitized_error(result) do
    assert {:error,
            %Error{code: code, message: nil, details: %{}, retryable?: retryable?} = error} =
             result

    assert code in Error.codes()
    assert error.details == %{}
    assert is_boolean(retryable?)
    refute inspect(error) =~ "CANARY"
  end
end
