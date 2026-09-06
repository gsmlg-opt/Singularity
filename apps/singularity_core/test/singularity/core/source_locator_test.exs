defmodule Singularity.Core.SourceLocatorTest do
  use ExUnit.Case, async: true
  alias Singularity.Core.{Error, KnowledgeEncoding, SourceLocator}

  @text %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
  @max 9_223_372_036_854_775_807

  test "text locator has stable v1 encoding and binary framing" do
    assert KnowledgeEncoding.frame("é") == <<2::unsigned-big-64, "é">>
    assert {:ok, locator} = SourceLocator.new(@text)
    assert SourceLocator.to_map(locator) == @text

    assert Base.encode16(SourceLocator.encode(locator), case: :lower) ==
             "000000000000000131000000000000000474657874000000000000000131000000000000000131"
  end

  test "all kinds serialize only their applicable fields" do
    for input <- [
          %{"version" => 1, "kind" => "pdf", "page" => 1},
          %{
            "version" => 1,
            "kind" => "pdf",
            "page" => @max,
            "start_char" => 0,
            "end_char" => @max
          },
          %{"version" => 1, "kind" => "markdown", "heading_path" => []},
          %{
            "version" => 1,
            "kind" => "markdown",
            "heading_path" => ["A"],
            "start_line" => 1,
            "end_line" => @max
          },
          @text,
          %{"version" => 1, "kind" => "fragment", "ordinal" => @max}
        ] do
      assert {:ok, locator} = SourceLocator.new(input)
      assert SourceLocator.to_map(locator) == input
      assert {:ok, ^locator} = SourceLocator.new(locator)
    end
  end

  test "optional fields encode empty frames and headings encode framed count and NFC strings" do
    assert {:ok, pdf} = SourceLocator.new(%{version: 1, kind: "pdf", page: 2})
    assert SourceLocator.encode(pdf) == framed(["1", "pdf", "2", "", ""])

    assert {:ok, markdown} =
             SourceLocator.new(%{version: 1, kind: "markdown", heading_path: ["e\u0301"]})

    assert SourceLocator.to_map(markdown)["heading_path"] == ["é"]
    assert SourceLocator.encode(markdown) == framed(["1", "markdown", framed(["1", "é"]), "", ""])
    assert {:ok, fallback} = SourceLocator.new(%{version: 1, kind: "fragment", ordinal: 0})
    assert SourceLocator.encode(fallback) == framed(["1", "fragment", "0"])
  end

  test "invalid shapes and values fail without accepting unknown or conflicting keys" do
    invalid = [
      nil,
      [],
      "text",
      %{},
      Map.delete(@text, "version"),
      Map.put(@text, "version", 2),
      Map.put(@text, "version", "1"),
      Map.put(@text, "kind", :text),
      Map.put(@text, "kind", "other"),
      Map.put(@text, "page", 1),
      Map.put(@text, "unexpected", 1),
      Map.put(@text, :version, 2)
    ]

    invalid =
      invalid ++
        for key <- ["start_line", "end_line"],
            value <- [nil, 0, -1, 1.0, "1", @max + 1],
            do: Map.put(@text, key, value)

    invalid = invalid ++ [Map.delete(@text, "end_line"), Map.put(@text, "start_line", 2)]
    for input <- invalid, do: assert({:error, %Error{code: :invalid}} = SourceLocator.new(input))

    pdf = %{"version" => 1, "kind" => "pdf", "page" => 1}

    for input <- [
          Map.put(pdf, "start_char", 0),
          Map.put(pdf, "end_char", 1),
          Map.merge(pdf, %{"start_char" => 1, "end_char" => 1}),
          Map.merge(pdf, %{"start_char" => -1, "end_char" => 1}),
          Map.merge(pdf, %{"start_char" => nil, "end_char" => nil}),
          Map.put(pdf, "page", 0),
          Map.put(pdf, "heading_path", [])
        ] do
      assert {:error, %Error{code: :invalid}} = SourceLocator.new(input)
    end

    markdown = %{"version" => 1, "kind" => "markdown", "heading_path" => []}

    for headings <- [
          nil,
          "A",
          [nil],
          [<<255>>],
          ["a\0"],
          [String.duplicate("a", 256)],
          List.duplicate("a", 65)
        ] do
      assert {:error, %Error{code: :invalid}} =
               SourceLocator.new(Map.put(markdown, "heading_path", headings))
    end

    for input <- [
          Map.put(markdown, "start_line", 1),
          Map.put(markdown, "end_line", 1),
          Map.merge(markdown, %{"start_line" => 2, "end_line" => 1}),
          Map.put(markdown, "ordinal", 0),
          %{"version" => 1, "kind" => "fragment", "ordinal" => -1},
          %{"version" => 1, "kind" => "fragment", "ordinal" => 0, "page" => 1}
        ] do
      assert {:error, %Error{code: :invalid}} = SourceLocator.new(input)
    end
  end

  test "handcrafted structs are revalidated on construction and serialization" do
    assert {:ok, locator} = SourceLocator.new(@text)
    invalid = Map.put(locator, :version, 2)
    assert {:error, %Error{code: :invalid}} = SourceLocator.new(invalid)
    assert {:error, %Error{code: :invalid}} = SourceLocator.to_map(invalid)
    assert {:error, %Error{code: :invalid}} = SourceLocator.encode(invalid)

    for fields <- [
          nil,
          [],
          %{start_line: 1},
          %{start_line: 1, end_line: 1, page: 1},
          %{start_line: 1, end_line: 1, version: 1},
          %{start_line: 2, end_line: 1}
        ] do
      invalid = Map.put(locator, :fields, fields)
      assert {:error, %Error{code: :invalid}} = SourceLocator.new(invalid)
      assert {:error, %Error{code: :invalid}} = SourceLocator.encode(invalid)
      assert {:error, %Error{code: :invalid}} = SourceLocator.to_map(invalid)
    end
  end

  test "all numeric fields enforce signed bigint bounds and valid encodings" do
    for {input, keys, minimum} <- [
          {%{version: 1, kind: "pdf", page: 1}, [:page], 1},
          {%{version: 1, kind: "pdf", page: 1, start_char: 0, end_char: 1},
           [:start_char, :end_char], 0},
          {%{version: 1, kind: "markdown", heading_path: [], start_line: 1, end_line: 1},
           [:start_line, :end_line], 1},
          {%{version: 1, kind: "fragment", ordinal: 0}, [:ordinal], 0}
        ],
        key <- keys,
        value <- [minimum - 1, @max + 1, nil, "1", 1.0] do
      assert {:error, %Error{code: :invalid}} = SourceLocator.new(Map.put(input, key, value))
    end

    for kind <- [<<255>>, "pdf\0"] do
      assert {:error, %Error{code: :invalid}} =
               SourceLocator.new(%{version: 1, kind: kind, page: 1})
    end
  end

  defp framed(values), do: IO.iodata_to_binary(Enum.map(values, &KnowledgeEncoding.frame/1))
end
