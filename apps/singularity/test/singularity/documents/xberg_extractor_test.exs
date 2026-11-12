defmodule Singularity.Documents.XbergExtractorTest do
  # Runs the real xberg NIF against small fixture files.
  use ExUnit.Case, async: true

  alias Singularity.Documents.XbergExtractor

  @fixtures Path.expand("../../fixtures/documents", __DIR__)

  defp extract(name, opts \\ []), do: XbergExtractor.extract(Path.join(@fixtures, name), opts)

  test "extracts Markdown" do
    assert {:ok, result} = extract("sample.md")
    assert result.mime_type == "text/markdown"
    assert result.title == "Singularity Notes"
    assert result.content =~ "# Singularity Notes"
    assert result.content =~ "**knowledge items**"
  end

  test "extracts HTML to Markdown" do
    assert {:ok, result} = extract("sample.html")
    assert result.mime_type == "text/html"
    assert result.content =~ "# Knowledge Items"
    assert result.content =~ "Sources feed the knowledge base."
    assert result.metadata["format_type"] == "html"
  end

  test "extracts PDF text and metadata" do
    assert {:ok, result} = extract("sample.pdf")
    assert result.mime_type == "application/pdf"
    assert result.title == "Sample PDF"
    assert result.content =~ "Singularity sample document"
    assert result.metadata["format_type"] == "pdf"
  end

  test "honours an explicit :mime_type" do
    assert {:ok, result} = extract("sample.md", mime_type: "text/plain")
    assert result.mime_type == "text/plain"
  end

  test "a corrupt PDF is an error, not a crash" do
    assert {:error, {:extract_failed, message}} = extract("corrupt.pdf")
    assert is_binary(message)
  end
end
