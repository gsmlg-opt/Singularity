defmodule Singularity.Ingest.Documents.PDF do
  @moduledoc "Bounded extraction of text-bearing PDF bytes with page provenance."

  alias Singularity.Ingest.Documents.Poppler

  @source_limit 67_108_864
  @text_limit 16_777_216
  @page_limit 4_096
  @timeout_ms 120_000
  @minimum_timeout_ms 800
  @unsupported_codes ~w(
    encrypted_document
    malformed_document
    no_extractable_text
    source_too_large
    page_limit_exceeded
    output_too_large
    invalid_utf8
    invalid_input
  )
  @failed_codes ~w(extractor_timeout extractor_failed)

  @spec extract(binary(), keyword()) ::
          {:ok, [map()]} | {:error, {:unsupported | :failed, String.t()}}
  def extract(bytes, opts \\ [])

  def extract(bytes, opts) when is_binary(bytes) and is_list(opts) do
    runner = Keyword.get(opts, :runner, Poppler)

    with :ok <- runner_limits(opts),
         :ok <- source_limit(bytes),
         {:ok, info} <- information(runner, bytes, opts),
         {:ok, pages} <- page_count(info),
         :ok <- page_limit(pages),
         {:ok, text} <- text(runner, bytes, opts),
         :ok <- text_limit(text),
         {:ok, blocks} <- pages(text) do
      {:ok, blocks}
    else
      :timeout -> failed("extractor_timeout")
      {:error, :output_limit} -> unsupported("output_too_large")
      {:error, {:unsupported, code}} when code in @unsupported_codes -> unsupported(code)
      {:error, {:failed, code}} when code in @failed_codes -> failed(code)
      {:error, _reason} -> failed("extractor_failed")
    end
  end

  def extract(_, _), do: unsupported("invalid_input")

  defp information(runner, bytes, opts) do
    case runner.run(:info, bytes, opts) do
      {:exit, _status} -> unsupported("malformed_document")
      other -> other
    end
  end

  defp text(runner, bytes, opts) do
    case runner.run(:text, bytes, opts) do
      {:exit, _status} -> failed("extractor_failed")
      other -> other
    end
  end

  defp source_limit(bytes) when byte_size(bytes) <= @source_limit, do: :ok
  defp source_limit(_bytes), do: unsupported("source_too_large")

  defp runner_limits(opts) do
    with :ok <- runner_limit(opts, :timeout_ms, @timeout_ms),
         :ok <- runner_limit(opts, :output_limit, @text_limit) do
      :ok
    else
      :error -> {:error, :invalid_runner_limit}
    end
  end

  defp runner_limit(opts, key, maximum) do
    minimum = if key == :timeout_ms, do: @minimum_timeout_ms, else: 1

    case Keyword.fetch(opts, key) do
      :error ->
        :ok

      {:ok, value} when is_integer(value) and value >= minimum and value <= maximum ->
        :ok

      {:ok, _value} ->
        :error
    end
  end

  defp text_limit(text) when is_binary(text) and byte_size(text) <= @text_limit, do: :ok
  defp text_limit(_text), do: unsupported("output_too_large")

  defp page_count(info) when is_binary(info) do
    case Regex.run(~r/^Pages:\s+(\d+)$/m, info, capture: :all_but_first) do
      [count] ->
        case Integer.parse(count) do
          {pages, ""} when pages > 0 -> {:ok, pages}
          _ -> unsupported("malformed_document")
        end

      _ ->
        unsupported("malformed_document")
    end
  end

  defp page_count(_), do: unsupported("malformed_document")

  defp page_limit(pages) when pages <= @page_limit, do: :ok
  defp page_limit(_pages), do: unsupported("page_limit_exceeded")

  defp pages(text) do
    if String.valid?(text) do
      blocks =
        text
        |> String.replace("\r\n", "\n")
        |> String.replace("\r", "\n")
        |> String.split("\f")
        |> Enum.with_index(1)
        |> Enum.reduce([], fn {page, number}, acc ->
          normalized = page |> String.normalize(:nfc) |> String.trim()

          if normalized == "" do
            acc
          else
            [
              %{
                text: normalized,
                locator: %{
                  version: 1,
                  kind: "pdf",
                  page: number,
                  start_char: 0,
                  end_char: String.length(normalized)
                }
              }
              | acc
            ]
          end
        end)
        |> Enum.reverse()

      if blocks == [], do: unsupported("no_extractable_text"), else: {:ok, blocks}
    else
      unsupported("invalid_utf8")
    end
  end

  defp unsupported(code), do: {:error, {:unsupported, code}}
  defp failed(code), do: {:error, {:failed, code}}
end
