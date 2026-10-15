defmodule Singularity.Ingest.UploadTextTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Ingest.UploadText

  test "accepts honest empty EOF and empty appends without retaining bytes" do
    state = UploadText.new()
    assert_numeric_state(state)
    assert :ok = UploadText.finish(state)
    assert {:ok, ^state} = UploadText.append(state, "")
    assert :ok = UploadText.finish(state)
  end

  test "accepts every UTF8 boundary codepoint across every byte partition" do
    for codepoint <- [
          0x01,
          0x7F,
          0x80,
          0x7FF,
          0x800,
          0xD7FF,
          0xE000,
          0xFFFF,
          0x10000,
          0x10FFFF
        ],
        chunks <- partitions(<<codepoint::utf8>>) do
      assert :ok = validate(chunks)
      assert :ok = validate(["" | Enum.intersperse(chunks, "")] ++ [""])
    end
  end

  test "accepts mixed text across every pair of chunk boundaries" do
    bytes = "\uFEFF# Markdown\r\ne\u0301 中文 😀\t \n"
    size = byte_size(bytes)

    for first <- 0..size, second <- first..size do
      assert :ok =
               validate([
                 binary_part(bytes, 0, first),
                 binary_part(bytes, first, second - first),
                 binary_part(bytes, second, size - second)
               ])
    end
  end

  test "accepts BOM CRLF decomposition whitespace and Markdown literally" do
    for bytes <- [
          <<0xEF, 0xBB, 0xBF>>,
          "\r\n\r\n",
          "e\u0301",
          "é",
          " \t\r\n ",
          "# heading\r\n**strong** [link](relative.md)\n",
          "prefix %PDF- is ordinary text"
        ] do
      assert :ok = validate([bytes])
      assert :ok = validate(for <<byte <- bytes>>, do: <<byte>>)
    end
  end

  test "rejects NUL at the beginning middle or end of any chunk" do
    for chunks <- [[<<0>>], ["before", <<0>>, "after"], ["before" <> <<0>>], [<<0, 65>>]] do
      assert validate(chunks) == {:error, Error.new(:unsupported_media_type)}
    end
  end

  test "rejects malformed UTF8 at every partition without exposing content" do
    for bytes <- [
          <<0x80>>,
          <<0xBF>>,
          <<0xC0, 0x80>>,
          <<0xC1, 0xBF>>,
          <<0xC2, 0x7F>>,
          <<0xDF, 0xC0>>,
          <<0xE0, 0x80, 0x80>>,
          <<0xE0, 0x9F, 0xBF>>,
          <<0xED, 0xA0, 0x80>>,
          <<0xED, 0xBF, 0xBF>>,
          <<0xE1, 0x80, 0x41>>,
          <<0xF0, 0x80, 0x80, 0x80>>,
          <<0xF0, 0x8F, 0xBF, 0xBF>>,
          <<0xF4, 0x90, 0x80, 0x80>>,
          <<0xF4, 0xBF, 0xBF, 0xBF>>,
          <<0xF5, 0x80, 0x80, 0x80>>,
          <<0xF8, 0x88, 0x80, 0x80, 0x80>>,
          <<0xFE>>,
          <<0xFF>>
        ],
        chunks <- partitions(bytes) do
      assert validate(chunks) == {:error, Error.new(:unsupported_media_type)}
    end
  end

  test "rejects malformed late bytes after a long valid first chunk" do
    {:ok, state} = UploadText.append(UploadText.new(), String.duplicate("valid text\n", 1_024))

    for bytes <- [<<0>>, <<0x80>>, <<0xFF>>, <<0xE0, 0x80, 0x80>>, "%PDF-" <> <<0>>] do
      assert UploadText.append(state, bytes) == {:error, Error.new(:unsupported_media_type)}
    end
  end

  test "permits incomplete codepoints between appends but rejects incomplete EOF" do
    for bytes <- [
          <<0xC2>>,
          <<0xDF>>,
          <<0xE0>>,
          <<0xE0, 0xA0>>,
          <<0xED, 0x9F>>,
          <<0xEF, 0xBF>>,
          <<0xF0>>,
          <<0xF0, 0x90>>,
          <<0xF0, 0x90, 0x80>>,
          <<0xF4, 0x8F, 0xBF>>
        ] do
      assert {:ok, state} = UploadText.append(UploadText.new(), bytes)
      assert_numeric_state(state)
      assert {:ok, ^state} = UploadText.append(state, "")
      assert UploadText.finish(state) == {:error, Error.new(:unsupported_media_type)}
    end

    assert {:ok, state} = UploadText.append(UploadText.new(), <<0xF0, 0x9F>>)
    assert {:ok, state} = UploadText.append(state, <<0x98>>)
    assert {:ok, state} = UploadText.append(state, <<0x80>>)
    assert :ok = UploadText.finish(state)
  end

  test "rejects complete leading PDF JPEG and PNG signatures across every partition" do
    for signature <- ["%PDF-", <<0xFF, 0xD8, 0xFF>>, <<137, 80, 78, 71, 13, 10, 26, 10>>],
        chunks <- partitions(signature) do
      assert validate(chunks) == {:error, Error.new(:unsupported_media_type)}
    end

    {:ok, state} = UploadText.append(UploadText.new(), "%PDF")
    assert UploadText.append(state, "-") == {:error, Error.new(:unsupported_media_type)}
  end

  test "accepts every partial PDF prefix at honest EOF and nonleading PDF text" do
    for bytes <- ["%", "%P", "%PD", "%PDF", "%PDFx", " %PDF-", "\uFEFF%PDF-", "a%PDF-"] do
      assert :ok = validate([bytes])
      assert :ok = validate(for <<byte <- bytes>>, do: <<byte>>)
    end
  end

  test "retains only bounded numeric decoder and prefix state" do
    for chunks <- [
          ["private content A"],
          ["private content B"],
          ["%", "P", "D", "F"],
          [<<0xEF>>, <<0xBB>>, <<0xBF>>],
          [String.duplicate("private content never retained\n", 10_000)]
        ] do
      Enum.reduce(chunks, UploadText.new(), fn chunk, state ->
        assert {:ok, next} = UploadText.append(state, chunk)
        assert_numeric_state(next)
        assert byte_size(:erlang.term_to_binary(next)) <= 512
        next
      end)
    end

    assert {:ok, first} = UploadText.append(UploadText.new(), "private content A")
    assert {:ok, second} = UploadText.append(UploadText.new(), "private content B")
    assert first == second
  end

  test "returns content-free invalid errors for invalid API arguments and state" do
    for state <- [nil, :invalid, 42, [], %{}, %{remaining: -1}, {0}] do
      assert UploadText.append(state, "private content") == {:error, Error.new(:invalid)}
      assert UploadText.finish(state) == {:error, Error.new(:invalid)}
    end

    for bytes <- [nil, :invalid, 42, ~c"text", ["text"], <<1::size(1)>>] do
      assert UploadText.append(UploadText.new(), bytes) == {:error, Error.new(:invalid)}
    end
  end

  defp validate(chunks) do
    Enum.reduce_while(chunks, {:ok, UploadText.new()}, fn chunk, {:ok, state} ->
      case UploadText.append(state, chunk) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state} -> UploadText.finish(state)
      {:error, %Error{}} = error -> error
    end
  end

  defp partitions(<<>>), do: [[]]

  defp partitions(bytes) do
    for size <- 1..byte_size(bytes),
        rest <- partitions(binary_part(bytes, size, byte_size(bytes) - size)) do
      [binary_part(bytes, 0, size) | rest]
    end
  end

  defp assert_numeric_state(state) do
    assert numeric_state?(state)
  end

  defp numeric_state?(value) when is_integer(value), do: value >= 0

  defp numeric_state?(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.all?(&numeric_state?/1)
  end

  defp numeric_state?(value) when is_map(value) do
    value
    |> Map.delete(:__struct__)
    |> Enum.all?(fn {key, counter} -> is_atom(key) and numeric_state?(counter) end)
  end

  defp numeric_state?(_value), do: false
end
