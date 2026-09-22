defmodule Singularity.Ingest.Documents.Text do
  @moduledoc "Pure UTF-8 plain-text extraction with exact paragraph line ranges."

  @spec extract(binary()) :: {:ok, [map()]} | {:error, {:unsupported, String.t()}}
  def extract(bytes) when is_binary(bytes) do
    if String.valid?(bytes) do
      blocks =
        bytes
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")
        |> String.normalize(:nfc)
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.chunk_by(fn {line, _} -> String.trim(line) == "" end)
        |> Enum.reject(fn [{line, _} | _] -> String.trim(line) == "" end)
        |> Enum.map(fn lines ->
          {_, first} = hd(lines)
          {_, last} = List.last(lines)

          %{
            text: Enum.map_join(lines, "\n", &elem(&1, 0)),
            locator: %{version: 1, kind: "text", start_line: first, end_line: last}
          }
        end)

      if blocks == [], do: unsupported("no_extractable_text"), else: {:ok, blocks}
    else
      unsupported("invalid_utf8")
    end
  end

  def extract(_), do: unsupported("invalid_input")
  defp unsupported(code), do: {:error, {:unsupported, code}}
end
