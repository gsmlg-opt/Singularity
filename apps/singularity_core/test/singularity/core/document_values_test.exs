defmodule Singularity.Core.DocumentValuesTest do
  use ExUnit.Case, async: true
  alias Singularity.Core.{DocumentFragment, Error, SourceLocator}
  @uuid "00000000-0000-4000-8000-000000000001"
  @id "a5e06997d69433d9a127780ef4d01c4e7147691745f5fcac15b230d3c3e48a48"

  test "fragment identity matches the independent vector" do
    assert {:ok, locator} = SourceLocator.new(attrs().locator)
    digest = :crypto.hash(:sha256, "hello\n")

    assert Base.encode16(digest, case: :lower) ==
             "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"

    assert DocumentFragment.id(@uuid, locator, 0, digest) == @id
    assert {:ok, fragment} = DocumentFragment.new(attrs())
    assert fragment.digest == digest
    assert fragment.fragment_id == @id
    assert {:ok, ^fragment} = DocumentFragment.new(fragment)
    assert {:ok, ^fragment} = DocumentFragment.new(Map.from_struct(fragment))
  end

  test "constructor verifies supplied digest and identity and rejects unnormalized body" do
    for {key, values} <- [
          resource_id: [nil, "uuid", String.upcase("abcdef00-0000-4000-8000-000000000001")],
          resource_version_id: [nil, "uuid"],
          owner_scope_id: [nil, "uuid"],
          classification: [:public, nil],
          ordinal: [-1, 9_223_372_036_854_775_808, 1.0],
          text: [nil, <<255>>, "a\0", "a\rb", "a\r\nb", String.duplicate("a", 65_537)],
          digest: [nil, "digest", :crypto.hash(:sha256, "different")],
          fragment_id: [nil, "wrong"],
          locator: [nil, %{}],
          heading_path: [[]],
          vault_id: [@uuid],
          unexpected: [true]
        ],
        value <- values do
      assert {:error, %Error{code: :invalid}} = DocumentFragment.new(Map.put(attrs(), key, value))
    end

    assert {:error, %Error{code: :invalid}} = DocumentFragment.new(Map.put(attrs(), "ordinal", 1))

    assert {:ok, fragment} =
             DocumentFragment.new(Map.put(attrs(), :text, String.duplicate("a", 65_536)))

    assert byte_size(fragment.text) == 65_536
    assert {:ok, empty} = DocumentFragment.new(Map.put(attrs(), :text, ""))
    assert empty.digest == :crypto.hash(:sha256, "")
    assert {:ok, fragment} = DocumentFragment.new(attrs())
    assert {:error, %Error{code: :invalid}} = DocumentFragment.new(%{fragment | text: "changed"})
  end

  test "body Unicode remains byte-exact and identity inputs are validated" do
    assert {:ok, decomposed} = DocumentFragment.new(Map.put(attrs(), :text, "e\u0301"))
    assert {:ok, composed} = DocumentFragment.new(Map.put(attrs(), :text, "é"))
    refute decomposed.fragment_id == composed.fragment_id
    assert decomposed.text == "e\u0301"

    for {version, locator, ordinal, digest} <- [
          {"bad", attrs().locator, 0, composed.digest},
          {@uuid, %{}, 0, composed.digest},
          {@uuid, attrs().locator, -1, composed.digest},
          {@uuid, attrs().locator, 0, "not a digest"}
        ] do
      assert {:error, %Error{code: :invalid}} =
               DocumentFragment.id(version, locator, ordinal, digest)
    end
  end

  test "fallback locator ordinal agrees with its fragment ordinal" do
    fallback = %{version: 1, kind: "fragment", ordinal: 0}
    assert {:ok, _} = DocumentFragment.new(Map.put(attrs(), :locator, fallback))

    assert {:error, %Error{code: :invalid}} =
             DocumentFragment.new(Map.put(attrs(), :locator, %{fallback | ordinal: 1}))
  end

  test "unrelated structs are invalid constructor input" do
    assert {:error, %Error{code: :invalid}} = DocumentFragment.new(%URI{})
    assert {:error, %Error{code: :invalid}} = SourceLocator.new(%URI{})
  end

  defp attrs do
    %{
      resource_id: @uuid,
      resource_version_id: @uuid,
      owner_scope_id: @uuid,
      classification: :private,
      ordinal: 0,
      text: "hello\n",
      locator: %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
    }
  end
end
