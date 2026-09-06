defmodule Singularity.Core.KnowledgePropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Singularity.Core.{DocumentFragment, SourceLocator}
  @uuid "00000000-0000-4000-8000-000000000001"

  property "all locator kinds round-trip and ignore input map insertion order" do
    check all(
            kind <- member_of(["pdf", "markdown", "text", "fragment"]),
            start <- integer(1..1_000_000),
            extent <- integer(0..1000),
            heading <- string(:alphanumeric, max_length: 30)
          ) do
      fields =
        case kind do
          "pdf" ->
            %{"page" => start, "start_char" => start, "end_char" => start + extent + 1}

          "markdown" ->
            %{"heading_path" => [heading], "start_line" => start, "end_line" => start + extent}

          "text" ->
            %{"start_line" => start, "end_line" => start + extent}

          "fragment" ->
            %{"ordinal" => start}
        end

      input = Map.merge(fields, %{"version" => 1, "kind" => kind})
      assert {:ok, locator} = SourceLocator.new(input)
      assert SourceLocator.to_map(locator) == input
      assert {:ok, ^locator} = SourceLocator.new(SourceLocator.to_map(locator))
      assert {:ok, reordered} = SourceLocator.new(input |> Enum.reverse() |> Map.new())
      assert SourceLocator.encode(reordered) == SourceLocator.encode(locator)
    end
  end

  property "NFC equivalent headings yield identical locators and fragment identities" do
    check all(
            prefix <- string(:alphanumeric, max_length: 30),
            {composed, decomposed} <-
              member_of([{"é", "e\u0301"}, {"Å", "A\u030A"}, {"ñ", "n\u0303"}])
          ) do
      assert {:ok, first} =
               SourceLocator.new(%{
                 version: 1,
                 kind: "markdown",
                 heading_path: [prefix <> composed]
               })

      assert {:ok, second} =
               SourceLocator.new(%{
                 version: 1,
                 kind: "markdown",
                 heading_path: [prefix <> decomposed]
               })

      assert first == second
      digest = :crypto.hash(:sha256, "text")

      assert DocumentFragment.id(@uuid, first, 0, digest) ==
               DocumentFragment.id(@uuid, second, 0, digest)
    end
  end

  property "changing each identity input changes the fragment ID for concrete mutations" do
    check all(ordinal <- integer(0..1_000_000), text <- string(:alphanumeric, max_length: 100)) do
      locator = %{version: 1, kind: "text", start_line: 1, end_line: 1}
      digest = :crypto.hash(:sha256, text)
      baseline = DocumentFragment.id(@uuid, locator, ordinal, digest)

      refute baseline ==
               DocumentFragment.id(
                 "00000000-0000-4000-8000-000000000002",
                 locator,
                 ordinal,
                 digest
               )

      refute baseline == DocumentFragment.id(@uuid, %{locator | end_line: 2}, ordinal, digest)
      refute baseline == DocumentFragment.id(@uuid, locator, ordinal + 1, digest)

      refute baseline ==
               DocumentFragment.id(@uuid, locator, ordinal, :crypto.hash(:sha256, text <> "!"))

      attrs = %{
        resource_id: @uuid,
        resource_version_id: @uuid,
        owner_scope_id: @uuid,
        classification: :private,
        ordinal: ordinal,
        text: text,
        locator: locator
      }

      assert {:ok, fragment} = DocumentFragment.new(attrs)
      assert fragment.fragment_id == baseline
      assert {:ok, ^fragment} = DocumentFragment.new(fragment)
    end
  end
end
