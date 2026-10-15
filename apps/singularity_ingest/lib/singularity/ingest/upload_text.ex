defmodule Singularity.Ingest.UploadText do
  @moduledoc "Incremental original-text validation without retaining content."

  alias Singularity.Core.Error

  # Decoder 0 accepts a new codepoint; 1..3 count ordinary continuations.
  # States 4..7 constrain the first continuation of E0, ED, F0 and F4.
  # Prefix 0..4 counts a leading PDF signature; 5 means it no longer matches.
  defstruct decoder: 0, pdf_prefix: 0

  @opaque t :: %__MODULE__{decoder: 0..7, pdf_prefix: 0..5}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec append(t(), binary()) :: {:ok, t()} | {:error, Error.t()}
  def append(%__MODULE__{decoder: decoder, pdf_prefix: prefix} = state, bytes)
      when map_size(state) == 3 and decoder in 0..7 and prefix in 0..5 and is_binary(bytes) do
    consume(bytes, decoder, prefix)
  end

  def append(_state, _bytes), do: {:error, Error.new(:invalid)}

  @spec finish(t()) :: :ok | {:error, Error.t()}
  def finish(%__MODULE__{decoder: decoder, pdf_prefix: prefix} = state)
      when map_size(state) == 3 and decoder in 0..7 and prefix in 0..5 do
    if decoder == 0, do: :ok, else: {:error, Error.new(:unsupported_media_type)}
  end

  def finish(_state), do: {:error, Error.new(:invalid)}

  defp consume(<<>>, decoder, prefix),
    do: {:ok, %__MODULE__{decoder: decoder, pdf_prefix: prefix}}

  defp consume(<<byte, rest::binary>>, decoder, prefix) do
    case {next_decoder(decoder, byte), next_prefix(prefix, byte)} do
      {next_decoder, next_prefix} when next_decoder >= 0 and next_prefix >= 0 ->
        consume(rest, next_decoder, next_prefix)

      _unsupported ->
        {:error, Error.new(:unsupported_media_type)}
    end
  end

  defp next_decoder(0, byte) when byte in 1..0x7F, do: 0
  defp next_decoder(0, byte) when byte in 0xC2..0xDF, do: 1
  defp next_decoder(0, 0xE0), do: 4
  defp next_decoder(0, byte) when byte in 0xE1..0xEC, do: 2
  defp next_decoder(0, 0xED), do: 5
  defp next_decoder(0, byte) when byte in 0xEE..0xEF, do: 2
  defp next_decoder(0, 0xF0), do: 6
  defp next_decoder(0, byte) when byte in 0xF1..0xF3, do: 3
  defp next_decoder(0, 0xF4), do: 7

  defp next_decoder(remaining, byte) when remaining in 1..3 and byte in 0x80..0xBF,
    do: remaining - 1

  defp next_decoder(4, byte) when byte in 0xA0..0xBF, do: 1
  defp next_decoder(5, byte) when byte in 0x80..0x9F, do: 1
  defp next_decoder(6, byte) when byte in 0x90..0xBF, do: 2
  defp next_decoder(7, byte) when byte in 0x80..0x8F, do: 2
  defp next_decoder(_decoder, _byte), do: -1

  defp next_prefix(0, ?%), do: 1
  defp next_prefix(1, ?P), do: 2
  defp next_prefix(2, ?D), do: 3
  defp next_prefix(3, ?F), do: 4
  defp next_prefix(4, ?-), do: -1
  defp next_prefix(_prefix, _byte), do: 5
end
