defmodule Singularity.Ingest.Documents.MarkdownTest do
  use ExUnit.Case, async: true

  alias Singularity.Ingest.Documents.Markdown

  test "headings form stable paths and fenced content stays one block" do
    source =
      "# Root\r\n\r\nalpha\r\n\r\n## Child\r\n\r\n```elixir\r\nhello\r\n\r\nworld\r\n```\r\n\r\n### Leaf\r\nend"

    assert {:ok, [root, alpha, child, fence, leaf, ending]} = Markdown.extract(source)

    assert root == %{
             text: "# Root",
             locator: %{
               version: 1,
               kind: "markdown",
               heading_path: ["Root"],
               start_line: 1,
               end_line: 1
             }
           }

    assert alpha.locator.heading_path == ["Root"]
    assert child.locator.heading_path == ["Root", "Child"]
    assert fence.text == "```elixir\nhello\n\nworld\n```"

    assert fence.locator == %{
             version: 1,
             kind: "markdown",
             heading_path: ["Root", "Child"],
             start_line: 7,
             end_line: 11
           }

    assert leaf.locator.heading_path == ["Root", "Child", "Leaf"]
    assert ending.locator.heading_path == ["Root", "Child", "Leaf"]
    assert Markdown.extract(source) == Markdown.extract(source)
  end

  test "normalizes NFC and rejects invalid UTF-8" do
    assert {:ok, [%{text: "é"}]} = Markdown.extract("e\u0301")
    assert {:error, {:unsupported, "invalid_utf8"}} = Markdown.extract(<<255>>)
  end

  test "a shallower heading replaces a skipped-level ancestor" do
    assert {:ok, [deep, up, body]} = Markdown.extract("### Deep\n## Up\ntext")
    assert deep.locator.heading_path == ["Deep"]
    assert up.locator.heading_path == ["Up"]
    assert body.locator.heading_path == ["Up"]
  end
end
