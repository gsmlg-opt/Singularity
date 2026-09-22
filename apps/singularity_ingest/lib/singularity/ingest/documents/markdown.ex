defmodule Singularity.Ingest.Documents.Markdown do
  @moduledoc "Pure UTF-8 Markdown extraction with heading and line provenance."

  @spec extract(binary()) :: {:ok, [map()]} | {:error, {:unsupported, String.t()}}
  def extract(bytes) when is_binary(bytes) do
    if String.valid?(bytes) do
      lines =
        bytes
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")
        |> String.normalize(:nfc)
        |> String.split("\n")
        |> Enum.with_index(1)

      blocks = collect(lines, [], [], [], nil)
      if blocks == [], do: unsupported("no_extractable_text"), else: {:ok, blocks}
    else
      unsupported("invalid_utf8")
    end
  end

  def extract(_), do: unsupported("invalid_input")

  defp collect([], path, pending, blocks, _fence) do
    {blocks, _} = flush(pending, path, blocks)
    Enum.reverse(blocks)
  end

  defp collect([{line, number} = item | rest], path, pending, blocks, fence) do
    cond do
      fence != nil ->
        pending = [item | pending]

        if closes_fence?(line, fence) do
          {blocks, _} = flush(pending, path, blocks)
          collect(rest, path, [], blocks, nil)
        else
          collect(rest, path, pending, blocks, fence)
        end

      marker = opens_fence(line) ->
        {blocks, _} = flush(pending, path, blocks)
        collect(rest, path, [item], blocks, marker)

      heading = heading(line) ->
        {blocks, _} = flush(pending, path, blocks)
        {level, title} = heading

        path =
          Enum.take_while(path, fn {ancestor_level, _} -> ancestor_level < level end) ++
            [{level, title}]

        block = make_block([{line, number}], path)
        collect(rest, path, [], [block | blocks], nil)

      String.trim(line) == "" ->
        {blocks, _} = flush(pending, path, blocks)
        collect(rest, path, [], blocks, nil)

      true ->
        collect(rest, path, [item | pending], blocks, nil)
    end
  end

  defp flush([], _path, blocks), do: {blocks, []}
  defp flush(pending, path, blocks), do: {[make_block(Enum.reverse(pending), path) | blocks], []}

  defp make_block(lines, path) do
    {_, first} = hd(lines)
    {_, last} = List.last(lines)

    %{
      text: Enum.map_join(lines, "\n", &elem(&1, 0)),
      locator: %{
        version: 1,
        kind: "markdown",
        heading_path: Enum.map(path, &elem(&1, 1)),
        start_line: first,
        end_line: last
      }
    }
  end

  defp heading(line) do
    case Regex.run(~r/^([#]{1,6})[ \t]+(.+?)$/, line) do
      [_, hashes, raw_title] ->
        title =
          raw_title |> then(&Regex.replace(~r/[ \t]+#+[ \t]*$/, &1, "")) |> String.trim_trailing()

        {byte_size(hashes), title}

      _ ->
        nil
    end
  end

  defp opens_fence(line) do
    case Regex.run(~r/^[ ]{0,3}(`{3,}|~{3,})/, line) do
      [_, marker] -> {binary_part(marker, 0, 1), byte_size(marker)}
      _ -> nil
    end
  end

  defp closes_fence?(line, {symbol, length}) do
    Regex.match?(~r/^[ ]{0,3}(?:`{3,}|~{3,})[ \t]*$/, line) and
      String.starts_with?(String.trim_leading(line), String.duplicate(symbol, length))
  end

  defp unsupported(code), do: {:error, {:unsupported, code}}
end
