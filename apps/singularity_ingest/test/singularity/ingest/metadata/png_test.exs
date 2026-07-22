defmodule Singularity.Ingest.Metadata.PNGTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Ingest.MetadataExtractor

  @fixture_root Path.expand("../../../../../../test/fixtures/assets", __DIR__)

  test "extracts the pinned PNG metadata shape without enrichment fields" do
    assert {:ok,
            %{
              detected_media_type: "image/png",
              plaintext_bytes: 67,
              width: 1,
              height: 1,
              pdf_version: nil,
              extractor_version: 1
            } = metadata} = MetadataExtractor.extract(reader_for("sample.png", "image/png"))

    assert map_size(metadata) == 6
    assert [{0, 64}] = reads()
  end

  test "rejects malformed and truncated PNG IHDR data as integrity failures" do
    assert {:error, %Error{code: :integrity_failure}} =
             MetadataExtractor.extract(reader_for("malformed.png", "image/png"))

    truncated = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 0, 0>>

    assert {:error, %Error{code: :integrity_failure}} =
             MetadataExtractor.extract(reader_for_binary(truncated, "image/png"))
  end

  test "rejects a PNG whose authenticated declaration names another type" do
    assert {:error, %Error{code: :unsupported_media_type}} =
             MetadataExtractor.extract(reader_for("sample.png", "image/jpeg"))
  end

  test "accepts the maximum PNG dimension supported by PostgreSQL integer fields" do
    png = png_header(2_147_483_647, 1)

    assert {:ok, %{width: 2_147_483_647, height: 1, plaintext_bytes: 33}} =
             MetadataExtractor.extract(reader_for_binary(png, "image/png"))

    assert [{0, 33}] = reads()
  end

  test "rejects CRC-valid PNG dimensions above the specification limit" do
    for {width, height} <- [{2_147_483_648, 1}, {1, 2_147_483_648}] do
      assert {:error, %Error{code: :integrity_failure}} =
               MetadataExtractor.extract(
                 reader_for_binary(png_header(width, height), "image/png")
               )
    end
  end

  defp reader_for(filename, declared_media_type) do
    filename
    |> then(&Path.join(@fixture_root, &1))
    |> File.read!()
    |> reader_for_binary(declared_media_type)
  end

  defp reader_for_binary(binary, declared_media_type) do
    owner = self()

    %{
      declared_media_type: declared_media_type,
      plaintext_byte_size: byte_size(binary),
      read_range: fn offset, length ->
        send(owner, {:metadata_read_range, offset, length})
        read_range(binary, offset, length)
      end
    }
  end

  defp png_header(width, height) do
    ihdr = <<width::unsigned-big-32, height::unsigned-big-32, 8, 6, 0, 0, 0>>

    <<137, "PNG\r\n", 26, 10, 13::unsigned-big-32, "IHDR", ihdr::binary,
      :erlang.crc32("IHDR" <> ihdr)::unsigned-big-32>>
  end

  defp read_range(binary, offset, length)
       when is_integer(offset) and offset >= 0 and is_integer(length) and length > 0 do
    available = max(byte_size(binary) - offset, 0)

    if available == 0 do
      {:ok, ""}
    else
      {:ok, binary_part(binary, offset, min(length, available))}
    end
  end

  defp read_range(_binary, _offset, _length), do: {:error, Error.new(:invalid)}

  defp reads(acc \\ []) do
    receive do
      {:metadata_read_range, offset, length} -> reads([{offset, length} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
