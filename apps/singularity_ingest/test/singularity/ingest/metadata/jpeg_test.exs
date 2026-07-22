defmodule Singularity.Ingest.Metadata.JPEGTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Ingest.Metadata.JPEG
  alias Singularity.Ingest.MetadataExtractor

  @chunk_size 4_194_304
  @fixture_root Path.expand("../../../../../../test/fixtures/assets", __DIR__)

  test "finds a valid SOF segment through bounded range reads" do
    assert {:ok, metadata} =
             MetadataExtractor.extract(reader_for("sample.jpg", "image/jpeg"))

    assert metadata == %{
             detected_media_type: "image/jpeg",
             plaintext_bytes: 83,
             width: 3,
             height: 2,
             pdf_version: nil,
             extractor_version: 1
           }

    assert [{0, 64}, {68, 2}, {70, 2}, {68, 10}] = reads()
  end

  test "rejects malformed and truncated JPEG segment data as integrity failures" do
    assert {:error, %Error{code: :integrity_failure}} =
             MetadataExtractor.extract(reader_for("malformed.jpg", "image/jpeg"))

    truncated = <<0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8, 0>>

    assert {:error, %Error{code: :integrity_failure}} =
             MetadataExtractor.extract(reader_for_binary(truncated, "image/jpeg"))
  end

  test "rejects a JPEG whose authenticated declaration names another type" do
    assert {:error, %Error{code: :unsupported_media_type}} =
             MetadataExtractor.extract(reader_for("sample.jpg", "application/pdf"))
  end

  test "caps malformed JPEG marker scanning at a deterministic bound" do
    padding = <<0xFF, 0xD8>> <> :binary.copy(<<0xFF>>, 400)

    assert {:error, %Error{code: :integrity_failure}} =
             MetadataExtractor.extract(reader_for_binary(padding, "image/jpeg"))

    assert length(reads()) <= 198
  end

  test "accepts a legal standalone TEM marker before SOF" do
    jpeg =
      <<0xFF, 0xD8, 0xFF, 0x01, 0xFF, 0xC0, 0, 11, 8, 0, 2, 0, 3, 1, 1, 0x11, 0, 0xFF, 0xD9>>

    assert {:ok,
            %{
              detected_media_type: "image/jpeg",
              plaintext_bytes: 19,
              width: 3,
              height: 2,
              pdf_version: nil,
              extractor_version: 1
            }} = MetadataExtractor.extract(reader_for_binary(jpeg, "image/jpeg"))

    assert [{0, 19}] = reads()
  end

  test "incremental extraction resumes across every JPEG byte boundary" do
    jpeg = minimal_jpeg(258, 515)

    for split <- 1..(byte_size(jpeg) - 1) do
      initial =
        JPEG.incremental_state(%{
          "phase" => "start",
          "declared_media_type" => "image/jpeg",
          "plaintext_bytes" => byte_size(jpeg)
        })

      first = JPEG.step(initial, binary_part(jpeg, 0, split), 0)

      {:done, metadata, _final_state} =
        case first do
          {:continue, checkpoint} ->
            assert JPEG.valid_incremental_state?(checkpoint)
            refute raw_partial_field?(checkpoint)

            JPEG.step(
              checkpoint,
              binary_part(jpeg, split, byte_size(jpeg) - split),
              split
            )

          {:done, metadata, final_state} ->
            {:done, metadata, final_state}
        end

      assert metadata.width == 515
      assert metadata.height == 258
    end
  end

  test "a short SOF length at the chunk boundary fails instead of emitting invalid state" do
    maximum_segment =
      <<0xFF, 0xE0, 65_535::unsigned-big-16>> <> :binary.copy(<<0>>, 65_533)

    boundary_segment =
      <<0xFF, 0xE0, 65_465::unsigned-big-16>> <> :binary.copy(<<0>>, 65_463)

    jpeg =
      <<0xFF, 0xD8>> <>
        :binary.copy(maximum_segment, 63) <>
        boundary_segment <>
        <<0xFF, 0xC0, 0, 7, 8, 0, 2, 0, 3>>

    assert <<_first_chunk::binary-size(@chunk_size), 8, 0, 2, 0, 3>> = jpeg
    assert {:ok, initial} = MetadataExtractor.initial_state("image/jpeg", byte_size(jpeg))

    result = MetadataExtractor.step(initial, binary_part(jpeg, 0, @chunk_size), 0)

    assert {:error, %Error{code: :integrity_failure}, failed_state} = result
    assert :ok = MetadataExtractor.validate_state(failed_state)
  end

  test "incremental checkpoints store shifted semantic accumulators without raw header bytes" do
    jpeg = minimal_jpeg(258, 515)
    initial = jpeg_incremental_state(jpeg)

    assert {:continue, segment} = JPEG.step(initial, binary_part(jpeg, 0, 5), 0)
    assert segment["mode"] == "length_low"
    assert segment["segment_kind"] == "sof"
    assert segment["segment_length_acc"] == 0
    refute raw_partial_field?(segment)
    assert JPEG.valid_incremental_state?(segment)

    assert {:continue, height} = JPEG.step(initial, binary_part(jpeg, 0, 8), 0)
    assert height["mode"] == "sof_height_low"
    assert height["height_acc"] == 256
    refute raw_partial_field?(height)
    assert JPEG.valid_incremental_state?(height)

    assert {:continue, width} = JPEG.step(initial, binary_part(jpeg, 0, 10), 0)
    assert width["mode"] == "sof_width_low"
    assert width["height"] == 258
    assert width["width_acc"] == 512
    refute raw_partial_field?(width)
    assert JPEG.valid_incremental_state?(width)
  end

  test "incremental state validation rejects raw, impossible, and out-of-bounds parser state" do
    jpeg = minimal_jpeg(258, 515)
    initial = jpeg_incremental_state(jpeg)
    assert {:continue, segment} = JPEG.step(initial, binary_part(jpeg, 0, 5), 0)
    assert {:continue, height} = JPEG.step(initial, binary_part(jpeg, 0, 8), 0)
    assert {:continue, width} = JPEG.step(initial, binary_part(jpeg, 0, 10), 0)

    refute JPEG.valid_incremental_state?(Map.put(segment, "length_high", 0))
    refute JPEG.valid_incremental_state?(Map.put(height, "height_high", 1))
    refute JPEG.valid_incremental_state?(Map.put(width, "width_high", 2))

    refute JPEG.valid_incremental_state?(Map.put(segment, "marker", 0xC0))
    refute JPEG.valid_incremental_state?(%{segment | "segment_kind" => "unknown"})
    refute JPEG.valid_incremental_state?(%{segment | "segment_length_acc" => 1})
    refute JPEG.valid_incremental_state?(%{segment | "segment_length_acc" => 65_536})
    refute JPEG.valid_incremental_state?(%{height | "height_acc" => 257})
    refute JPEG.valid_incremental_state?(%{height | "height_acc" => 65_536})
    refute JPEG.valid_incremental_state?(%{width | "width_acc" => 513})
    refute JPEG.valid_incremental_state?(%{width | "width_acc" => 65_536})
    refute JPEG.valid_incremental_state?(%{height | "segment_length" => 7})
    refute JPEG.valid_incremental_state?(%{height | "segment_length" => 65_536})
    refute JPEG.valid_incremental_state?(%{height | "cursor" => byte_size(jpeg) - 1})
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

  defp minimal_jpeg(height, width) do
    <<0xFF, 0xD8, 0xFF, 0xC0, 11::unsigned-big-16, 8, height::unsigned-big-16,
      width::unsigned-big-16, 1, 1, 0x11, 0, 0xFF, 0xD9>>
  end

  defp jpeg_incremental_state(jpeg) do
    JPEG.incremental_state(%{
      "phase" => "start",
      "declared_media_type" => "image/jpeg",
      "plaintext_bytes" => byte_size(jpeg)
    })
  end

  defp raw_partial_field?(state) do
    Enum.any?(["length_high", "height_high", "width_high"], &Map.has_key?(state, &1)) or
      Map.has_key?(state, "marker")
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
