defmodule Singularity.Core.DocumentFragmentation do
  @moduledoc "Builds bounded, deterministic fragments from extracted semantic blocks."

  alias Singularity.Core.DocumentFragment

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
      :over_limit -> unsupported("output_limit")
      :invalid -> unsupported("invalid_input")
      _ -> :ok
    end
  end

  defp build_blocks([], _identity, acc, _ordinal), do: {:ok, acc}

  defp build_blocks([%{text: ""} | _], _identity, _acc, _ordinal),
    do: unsupported("no_extractable_text")

  defp build_blocks([%{text: text, locator: locator} | rest], identity, acc, ordinal)
       when is_binary(text) and is_map(locator) do
    with true <- String.valid?(text) and text != "",
         {:ok, chunks} <- chunks(text),
         true <- ordinal + length(chunks) <= @fragment_count,
         {:ok, acc, next} <- build_chunks(chunks, locator, identity, acc, ordinal) do
      build_blocks(rest, identity, acc, next)
    else
      false -> unsupported("fragment_limit")
      {:error, _} = error -> error
    end
  end

  defp build_blocks(_, _, _, _), do: unsupported("invalid_input")

  defp chunks(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], [], 0}, fn grapheme, {chunks, current, bytes} ->
      size = byte_size(grapheme)

      cond do
        size > @fragment_bytes ->
          {:halt, :invalid}

        bytes + size > @fragment_bytes ->
          {:cont, {[IO.iodata_to_binary(Enum.reverse(current)) | chunks], [grapheme], size}}

        true ->
          {:cont, {chunks, [grapheme | current], bytes + size}}
      end
    end)
    |> case do
      :invalid ->
        unsupported("output_limit")

      {previous, current, _} ->
        {:ok, Enum.reverse([IO.iodata_to_binary(Enum.reverse(current)) | previous])}
    end
  end

  defp build_chunks(chunks, locator, identity, acc, ordinal) do
    split? = length(chunks) > 1

    Enum.reduce_while(chunks, {:ok, acc, ordinal}, fn chunk, {:ok, built, index} ->
      effective_locator =
        if split?, do: %{version: 1, kind: "fragment", ordinal: index}, else: locator

      attrs = Map.merge(identity, %{ordinal: index, text: chunk, locator: effective_locator})

      case DocumentFragment.new(attrs) do
        {:ok, fragment} -> {:cont, {:ok, [fragment | built], index + 1}}
        {:error, _} -> {:halt, unsupported("invalid_input")}
      end
    end)
  end

  defp unsupported(code), do: {:error, {:unsupported, code}}
end
