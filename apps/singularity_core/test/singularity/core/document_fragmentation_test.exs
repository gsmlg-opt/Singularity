defmodule Singularity.Core.DocumentFragmentationTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.DocumentFragmentation

  @id "00000000-0000-4000-8000-000000000001"

  test "builds ordered stable fragments from exact source ranges" do
    blocks = [
      %{text: "one\n", locator: %{version: 1, kind: "text", start_line: 1, end_line: 1}},
      %{text: "two\n", locator: %{version: 1, kind: "text", start_line: 3, end_line: 3}}
    ]

    assert {:ok, [first, second]} = DocumentFragmentation.build(identity(), "text/plain", blocks)
    assert {first.ordinal, second.ordinal} == {0, 1}
    assert first.fragment_id != second.fragment_id

    assert {:ok, [^first, ^second]} =
             DocumentFragmentation.build(identity(), "text/plain", blocks)
  end

  test "splits on graphemes with ordinal provenance fallback" do
    text = String.duplicate("é", 32_769)
    block = %{text: text, locator: %{version: 1, kind: "text", start_line: 1, end_line: 1}}
    assert {:ok, [first, second]} = DocumentFragmentation.build(identity(), "text/plain", [block])
    assert byte_size(first.text) <= 65_536
    assert byte_size(second.text) <= 65_536
    assert first.text <> second.text == text
    assert first.locator.kind == "fragment"
    assert first.locator.fields.ordinal == 0
    assert second.locator.fields.ordinal == 1
  end

  test "rejects empty and over-limit outputs" do
    assert {:error, {:unsupported, "no_extractable_text"}} =
             DocumentFragmentation.build(identity(), "text/plain", [])

    large = %{
      text: String.duplicate("a", 16_777_217),
      locator: %{version: 1, kind: "text", start_line: 1, end_line: 1}
    }

    assert {:error, {:unsupported, "output_limit"}} =
             DocumentFragmentation.build(identity(), "text/plain", [large])

    block = %{text: "x", locator: %{version: 1, kind: "text", start_line: 1, end_line: 1}}

    assert {:error, {:unsupported, "fragment_limit"}} =
             DocumentFragmentation.build(identity(), "text/plain", List.duplicate(block, 4097))
  end

  defp identity,
    do: %{
      resource_id: @id,
      resource_version_id: @id,
      owner_scope_id: @id,
      classification: :private
    }
end
