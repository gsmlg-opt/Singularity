defmodule Singularity.Ingest.Metadata.PNG do
  @moduledoc "Bounded parser for PNG IHDR dimensions."

  alias Singularity.Core.Error

  @extractor_version 1
  @minimum_bytes 33
  @max_dimension 2_147_483_647

  @spec extract(map(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def extract(
        %{plaintext_byte_size: plaintext_byte_size},
        <<137, "PNG\r\n", 26, 10, 13::unsigned-big-32, "IHDR", ihdr::binary-size(13),
          expected_crc::unsigned-big-32, _rest::binary>>
      )
      when plaintext_byte_size >= @minimum_bytes do
    <<width::unsigned-big-32, height::unsigned-big-32, bit_depth, color_type, compression, filter,
      interlace>> = ihdr

    if valid_ihdr?(width, height, bit_depth, color_type, compression, filter, interlace) and
         expected_crc == :erlang.crc32("IHDR" <> ihdr) do
      {:ok,
       %{
         detected_media_type: "image/png",
         plaintext_bytes: plaintext_byte_size,
         width: width,
         height: height,
         pdf_version: nil,
         extractor_version: @extractor_version
       }}
    else
      integrity_failure()
    end
  end

  def extract(_reader, _prefix), do: integrity_failure()

  defp valid_ihdr?(width, height, bit_depth, color_type, 0, 0, interlace)
       when width > 0 and width <= @max_dimension and height > 0 and
              height <= @max_dimension and interlace in [0, 1],
       do: valid_bit_depth?(color_type, bit_depth)

  defp valid_ihdr?(
         _width,
         _height,
         _bit_depth,
         _color_type,
         _compression,
         _filter,
         _interlace
       ),
       do: false

  defp valid_bit_depth?(0, bit_depth), do: bit_depth in [1, 2, 4, 8, 16]
  defp valid_bit_depth?(2, bit_depth), do: bit_depth in [8, 16]
  defp valid_bit_depth?(3, bit_depth), do: bit_depth in [1, 2, 4, 8]
  defp valid_bit_depth?(4, bit_depth), do: bit_depth in [8, 16]
  defp valid_bit_depth?(6, bit_depth), do: bit_depth in [8, 16]
  defp valid_bit_depth?(_color_type, _bit_depth), do: false

  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
end
