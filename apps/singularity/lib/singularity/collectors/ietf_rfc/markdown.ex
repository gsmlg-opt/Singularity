defmodule Singularity.Collectors.IetfRfc.Markdown do
  @moduledoc """
  Turns RFC files into the Markdown stored as item content.

  v3 RFCs (8650 on) are converted from HTML by xberg and cleaned with
  `clean_html/1`. Older RFCs are fixed-width text whose meaning depends on
  layout (packet diagrams, tables), so `from_text/1` keeps it byte for byte
  in a code fence.
  """

  @rfc_editor "https://www.rfc-editor.org/rfc/rfc"

  # An in-page link, optionally with a title that may contain escaped quotes.
  @in_page_link ~S{\[([^\]]*)\]\(#[^)\s]*(?:\s+"(?:[^"\\]|\\.)*")?\)}

  @doc "Cleans xberg's Markdown for a v3 RFC HTML page."
  @spec clean_html(String.t()) :: String.t()
  def clean_html(markdown) do
    markdown
    |> drop_preamble()
    |> String.replace(~r/[ \t]*\[¶\]\(#[^)]*\)/u, "")
    # "[1.](#section-1)[Introduction](#name-introduction)" reads "1. Introduction".
    |> String.replace(Regex.compile!(@in_page_link <> ~S{(?=\[)}), "\\1 ")
    |> String.replace(Regex.compile!(@in_page_link), "\\1")
    |> String.replace(~r{\]\(\./rfc(\d+)([^)]*)\)}, "](#{@rfc_editor}\\1\\2)")
  end

  # Front matter and the header table duplicate the metadata; the document
  # starts at its "# RFC <number>" heading.
  defp drop_preamble(markdown) do
    case :binary.match(markdown, "\n# RFC ") do
      {at, _length} -> binary_part(markdown, at + 1, byte_size(markdown) - at - 1)
      :nomatch -> markdown
    end
  end

  @doc "Wraps plain RFC text in a `text` code fence longer than any backtick run inside."
  @spec from_text(String.t()) :: String.t()
  def from_text(text) do
    longest =
      ~r/`+/
      |> Regex.scan(text)
      |> Enum.map(fn [run] -> byte_size(run) end)
      |> Enum.max(fn -> 0 end)

    fence = String.duplicate("`", max(3, longest + 1))
    body = if String.ends_with?(text, "\n"), do: text, else: text <> "\n"

    fence <> "text\n" <> body <> fence <> "\n"
  end
end
