defmodule Singularity.Core.DocumentFragmentation do
  @moduledoc "Builds bounded, deterministic fragments from extracted semantic blocks."

  alias Singularity.Core.{DocumentFragment, SourceLocator}

  @fragment_bytes 65_536
  @total_bytes 16_777_216
  @fragment_count 4_096

  @spec build(map(), String.t(), [map()]) ::
          {:ok, [DocumentFragment.t()]} | {:error, {:unsupported, String.t()}}
  def build(identity, media_type, blocks)
      when is_map(identity) and is_binary(media_type) and is_list(blocks) do
    with :ok <- valid_media_type(media_type),
         :ok <- total_limit(blocks),
         {:ok, fragments} <- build_blocks(blocks, identity, [], 0),
         true <- fragments != [] do
      {:ok, Enum.reverse(fragments)}
    else
      false -> unsupported("no_extractable_text")
      {:error, _} = error -> error
    end
  end

  def build(_, _, _), do: unsupported("invalid_input")

  defp valid_media_type(type) when type in ["text/plain", "text/markdown", "application/pdf"],
    do: :ok

  defp valid_media_type(_), do: unsupported("invalid_input")

  defp total_limit(blocks) do
    Enum.reduce_while(blocks, 0, fn
      %{text: text}, total when is_binary(text) ->
        size = total + byte_size(text)
        if size <= @total_bytes, do: {:cont, size}, else: {:halt, :over_limit}

      _, _ ->
        {:halt, :invalid}
    end)
    |> case do
      :over_limit -> unsupported("output_too_large")
      :invalid -> unsupported("invalid_input")
      _ -> :ok
    end
  end

  defp build_blocks([], _identity, acc, _ordinal), do: {:ok, acc}

  defp build_blocks([%{text: ""} | _], _identity, _acc, _ordinal),
    do: unsupported("no_extractable_text")

  defp build_blocks([%{text: text, locator: locator} | rest], identity, acc, ordinal)
       when is_binary(text) and is_map(locator) do
    if String.valid?(text) and text != "" do
      with {:ok, chunks} <- chunks(text),
           true <- ordinal + length(chunks) <= @fragment_count,
           {:ok, acc, next} <- build_chunks(chunks, locator, identity, acc, ordinal) do
        build_blocks(rest, identity, acc, next)
      else
        false -> unsupported("output_too_large")
        {:error, _} = error -> error
      end
    else
      unsupported("invalid_input")
    end
  end

  defp build_blocks(_, _, _, _), do: unsupported("invalid_input")

  defp chunks(text) do
    chunk_next(text, [], [], 0)
  end

  defp chunk_next("", previous, current, _bytes) do
    {:ok, Enum.reverse([IO.iodata_to_binary(Enum.reverse(current)) | previous])}
  end

  defp chunk_next(text, previous, current, bytes) do
    {grapheme, rest} = String.next_grapheme(text)
    size = byte_size(grapheme)

    cond do
      size > @fragment_bytes ->
        unsupported("output_too_large")

      bytes + size > @fragment_bytes ->
        chunk_next(
          rest,
          [IO.iodata_to_binary(Enum.reverse(current)) | previous],
          [grapheme],
          size
        )

      true ->
        chunk_next(rest, previous, [grapheme | current], bytes + size)
    end
  end

  defp build_chunks(chunks, locator, identity, acc, ordinal) do
    split? = length(chunks) > 1

    Enum.reduce_while(chunks, {:ok, acc, ordinal}, fn chunk, {:ok, built, index} ->
      with {:ok, effective_locator} <- effective_locator(locator, index, split?),
           attrs =
             Map.merge(identity, %{ordinal: index, text: chunk, locator: effective_locator}),
           {:ok, fragment} <- DocumentFragment.new(attrs) do
        {:cont, {:ok, [fragment | built], index + 1}}
      else
        _ -> {:halt, unsupported("invalid_input")}
      end
    end)
  end

  defp effective_locator(locator, index, split?) do
    case SourceLocator.new(locator) do
      {:ok, _} ->
        {:ok, if(split?, do: ordinal_locator(index), else: locator)}

      {:error, _} ->
        if oversized_markdown_heading?(locator) do
          {:ok, ordinal_locator(index)}
        else
          unsupported("invalid_input")
        end
    end
  end

  defp oversized_markdown_heading?(%{version: 1, kind: "markdown", heading_path: path} = locator)
       when is_list(path) do
    oversized = Enum.filter(path, &(is_binary(&1) and byte_size(&1) > 255))

    oversized != [] and
      Enum.all?(oversized, &(String.valid?(&1) and not String.contains?(&1, <<0>>))) and
      match?(
        {:ok, _},
        SourceLocator.new(%{
          locator
          | heading_path:
              Enum.map(path, fn heading ->
                if heading in oversized, do: "x", else: heading
              end)
        })
      )
  end

  defp oversized_markdown_heading?(_), do: false

  defp ordinal_locator(index), do: %{version: 1, kind: "fragment", ordinal: index}

  defp unsupported(code), do: {:error, {:unsupported, code}}
end
