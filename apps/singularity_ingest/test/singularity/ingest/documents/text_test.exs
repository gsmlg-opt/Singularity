defmodule Singularity.Ingest.Documents.TextTest do
  use ExUnit.Case, async: true

  alias Singularity.Ingest.Documents.Text

  test "normalizes line endings and NFC while retaining exact paragraph lines" do
    assert {:ok,
            [
              %{text: "é\none", locator: %{version: 1, kind: "text", start_line: 1, end_line: 2}},
              %{text: "two", locator: %{version: 1, kind: "text", start_line: 4, end_line: 4}}
            ]} = Text.extract("e\u0301\r\none\r\n\r\ntwo")
  end

  test "rejects invalid UTF-8 and empty text without exposing input" do
    assert {:error, {:unsupported, "invalid_utf8"}} = Text.extract(<<255>>)
    assert {:error, {:unsupported, "no_extractable_text"}} = Text.extract(" \n\t")
  end

  test "is deterministic" do
    assert Text.extract("one\n\ntwo") == Text.extract("one\n\ntwo")
  end
end
