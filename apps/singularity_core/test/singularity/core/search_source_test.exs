defmodule Singularity.Core.SearchSourceTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{Error, SearchSource}

  @resource "00000000-0000-4000-8000-000000000a01"
  @version "00000000-0000-4000-8000-000000000a02"
  @fragment String.duplicate("ab01", 16)
  @note %{kind: :note, resource_id: @resource, resource_version_id: @version, fragment_id: nil}
  @document %{@note | kind: :document, fragment_id: @fragment}

  test "a Note selector retains its exact immutable identity" do
    assert Code.ensure_loaded?(Singularity.Core.SearchSource)

    input = %{
      kind: :note,
      resource_id: "00000000-0000-4000-8000-000000000a01",
      resource_version_id: "00000000-0000-4000-8000-000000000a02",
      fragment_id: nil
    }

    assert {:ok, source} = apply(Singularity.Core.SearchSource, :new, [input])
    assert Map.from_struct(source) == input

    assert {:ok, "note:00000000-0000-4000-8000-000000000a02"} =
             apply(Singularity.Core.SearchSource, :entry_id, [source])
  end

  test "a Document selector requires its exact fragment and uses its deterministic entry ID" do
    assert {:ok, source} = SearchSource.new(@document)
    assert Map.from_struct(source) == @document
    assert SearchSource.entry_id(source) == {:ok, "document:" <> @fragment}
    assert SearchSource.new(source) == {:ok, source}
  end

  test "fixed string kind and field aliases normalize without creating new atoms" do
    for input <- [@note, @document] do
      string_input =
        input
        |> Map.put(:kind, Atom.to_string(input.kind))
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

      assert {:ok, source} = SearchSource.new(string_input)
      assert Map.from_struct(source) == input
      assert SearchSource.new(Map.to_list(input)) == {:ok, source}
    end
  end

  test "identical aliases coalesce but conflicting aliases and keyword duplicates fail" do
    assert {:ok, expected} = SearchSource.new(@note)

    for {key, value} <- @note do
      assert SearchSource.new(Map.put(@note, Atom.to_string(key), value)) == {:ok, expected}
      assert SearchSource.new([{key, value} | Map.to_list(@note)]) == {:ok, expected}
      assert_invalid(Map.put(@note, Atom.to_string(key), "different"))
      assert_invalid([{key, "different"} | Map.to_list(@note)])
    end

    assert_invalid(Map.put(@note, "kind", "note"))
  end

  test "all four selector keys are required even the nullable Note fragment" do
    for input <- [@note, @document], key <- Map.keys(input) do
      assert_invalid(Map.delete(input, key))
    end
  end

  test "selectors reject caller scope, content, locator, digest and unknown fields" do
    for input <- [@note, @document],
        key <- [
          :owner_scope_id,
          :vault_id,
          :classification,
          :title,
          :text,
          :locator,
          :digest,
          :filename,
          :storage_path,
          :unknown
        ],
        alias_key <- [key, Atom.to_string(key)] do
      assert_invalid(Map.put(input, alias_key, "private-content-canary"))
    end
  end

  test "only fixed Note and Document kinds are supported" do
    for kind <- [nil, :all, :asset, "Note", "DOCUMENT", "", "unknown", <<255>>, "note\0", 1] do
      assert_invalid(Map.put(@note, :kind, kind))
    end
  end

  test "source UUIDs must be canonical lowercase strings" do
    for key <- [:resource_id, :resource_version_id],
        value <- [
          nil,
          "",
          "uuid",
          String.upcase(@resource),
          " " <> @resource,
          @resource <> "\n",
          @resource <> "\0",
          <<0::128>>,
          <<255>>,
          1,
          :id
        ] do
      assert_invalid(Map.put(@note, key, value))
    end
  end

  test "Note identities cannot acquire fragments and Document identities cannot omit them" do
    for fragment <- [@fragment, "", 0, false],
        do: assert_invalid(Map.put(@note, :fragment_id, fragment))

    for fragment <- [
          nil,
          "",
          String.duplicate("a", 63),
          String.duplicate("a", 65),
          String.upcase(@fragment),
          String.duplicate("g", 64),
          @fragment <> "\n",
          String.duplicate("a", 63) <> "\0",
          :binary.copy(<<255>>, 64),
          String.duplicate("é", 32),
          0
        ] do
      assert_invalid(Map.put(@document, :fragment_id, fragment))
    end
  end

  test "non-attribute inputs and unrelated structs fail closed" do
    for input <- [
          nil,
          false,
          "content",
          7,
          [],
          [:kind],
          [{"kind", "note"}],
          [{:kind, :note} | :improper],
          Error.new(:invalid)
        ] do
      assert_invalid(input)
    end
  end

  test "handcrafted selectors cannot bypass validation through either entrypoint" do
    assert {:ok, source} = SearchSource.new(@note)

    for input <- [
          Map.put(source, :resource_version_id, "invalid"),
          Map.put(source, :fragment_id, @fragment),
          Map.put(source, :owner_scope_id, @resource),
          Map.put(source, "resource_id", @resource),
          Map.delete(source, :fragment_id),
          %{__struct__: SearchSource}
        ] do
      assert_invalid(input)
    end
  end

  defp assert_invalid(input) do
    expected = {:error, Error.new(:invalid)}
    assert SearchSource.new(input) == expected
    assert SearchSource.entry_id(input) == expected
  end
end
