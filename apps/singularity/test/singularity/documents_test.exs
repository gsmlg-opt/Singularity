defmodule Singularity.DocumentsTest do
  use ExUnit.Case, async: true

  alias Singularity.Documents

  @fixtures Path.expand("../fixtures/documents", __DIR__)
  @sample Path.join(@fixtures, "sample.md")

  test "passes an existing file to the extractor and returns its result" do
    assert {:ok, %{content: "# Fake", mime_type: "text/markdown", title: "Fake", metadata: %{}}} =
             Documents.extract(@sample)

    assert_received {:fake_extractor_called, @sample, []}
  end

  test "passes :mime_type through and nothing else" do
    assert {:ok, _} = Documents.extract(@sample, mime_type: "text/plain", max_bytes: 1_000)
    assert_received {:fake_extractor_called, @sample, [mime_type: "text/plain"]}
  end

  test "rejects URLs, directories and missing paths without calling the extractor" do
    for path <- [
          "https://example.com/doc.pdf",
          "file://#{@sample}",
          @fixtures,
          Path.join(@fixtures, "missing.pdf")
        ] do
      assert {:error, :not_a_file} = Documents.extract(path)
    end

    refute_received {:fake_extractor_called, _, _}
  end

  test "rejects files over :max_bytes without calling the extractor" do
    size = File.stat!(@sample).size

    assert {:error, :too_large} = Documents.extract(@sample, max_bytes: size - 1)
    refute_received {:fake_extractor_called, _, _}

    assert {:ok, _} = Documents.extract(@sample, max_bytes: size)
  end
end
