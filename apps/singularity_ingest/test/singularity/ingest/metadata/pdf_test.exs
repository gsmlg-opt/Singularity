defmodule Singularity.Ingest.Metadata.PDFTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Ingest.MetadataExtractor

  @fixture_root Path.expand("../../../../../../test/fixtures/assets", __DIR__)

  test "extracts only deterministic PDF header metadata" do
    assert {:ok, metadata} =
             MetadataExtractor.extract(reader_for("sample.pdf", "application/pdf"))

    assert metadata == %{
             detected_media_type: "application/pdf",
             plaintext_bytes: 22,
             width: nil,
             height: nil,
             pdf_version: "1.7",
             extractor_version: 1
           }

    assert [{0, 22}] = reads()
  end

  test "rejects malformed and truncated PDF headers as integrity failures" do
    assert {:error, %Error{code: :integrity_failure}} =
             MetadataExtractor.extract(reader_for("malformed.pdf", "application/pdf"))

    assert {:error, %Error{code: :integrity_failure}} =
             MetadataExtractor.extract(reader_for_binary("%PDF-", "application/pdf"))
  end

  test "rejects unsupported content and a mismatched declaration" do
    assert {:error, %Error{code: :unsupported_media_type}} =
             MetadataExtractor.extract(
               reader_for_binary("not a supported asset", "application/pdf")
             )

    assert {:error, %Error{code: :unsupported_media_type}} =
             MetadataExtractor.extract(reader_for("sample.pdf", "image/png"))
  end

  test "requires the authenticated reader to return the exact requested prefix" do
    assert {:error, %Error{code: :integrity_failure}} =
             MetadataExtractor.extract(reader_returning(10, "application/pdf", "%PDF-1.7\n"))

    assert {:error, %Error{code: :integrity_failure}} =
             MetadataExtractor.extract(reader_returning(9, "application/pdf", "%PDF-1.7\nX"))

    assert [{0, 10}, {0, 9}] = reads()
  end

  test "rejects an empty object without issuing a zero-length range read" do
    assert {:error, %Error{code: :integrity_failure}} =
             MetadataExtractor.extract(reader_for_binary("", "application/pdf"))

    assert [] = reads()
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

  defp reader_returning(plaintext_byte_size, declared_media_type, response) do
    owner = self()

    %{
      declared_media_type: declared_media_type,
      plaintext_byte_size: plaintext_byte_size,
      read_range: fn offset, length ->
        send(owner, {:metadata_read_range, offset, length})
        {:ok, response}
      end
    }
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
