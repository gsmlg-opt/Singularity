defmodule Singularity.Ingest.UploadRequestTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Ingest.UploadRequest

  @max_bytes 512 * 1024 * 1024
  @text_max_bytes 67_108_864

  test "normalizes a supported upload request and keeps its exact binding" do
    assert {:ok,
            %UploadRequest{
              filename: "report.pdf",
              size: 8,
              declared_media_type: "application/pdf",
              idempotency_key: "upload-1",
              max_bytes: @max_bytes
            }} =
             UploadRequest.new(%{
               filename: "report.pdf",
               size: 8,
               declared_media_type: " application/pdf ",
               idempotency_key: "upload-1"
             })
  end

  test "rejects every field outside the exact browser binding" do
    for {field, value} <- [
          {:resource_id, Ecto.UUID.generate()},
          {:resource_version_id, Ecto.UUID.generate()},
          {:asset_id, Ecto.UUID.generate()},
          {:source_reference_id, Ecto.UUID.generate()},
          {:classification, :private},
          {:checksum, :crypto.hash(:sha256, "payload")},
          {:size_bytes, 8},
          {:text_validation_version, "upload_text_v1"},
          {:extractor_version, "upload_text_v1"},
          {:metadata, %{declared_media_type: "text/plain"}}
        ] do
      for media_type <- ["application/pdf", "text/plain", "text/markdown"] do
        assert {:error, %Error{code: :invalid}} =
                 media_type
                 |> valid_attrs()
                 |> Map.put(field, value)
                 |> UploadRequest.new()
      end
    end
  end

  test "preserves PDF, JPEG, and PNG declaration admission" do
    for media_type <- ["application/pdf", "image/jpeg", "image/png"] do
      assert {:ok, %UploadRequest{declared_media_type: ^media_type}} =
               UploadRequest.new(valid_attrs(media_type))
    end

    assert {:error, %Error{code: :unsupported_media_type}} =
             UploadRequest.new(valid_attrs("application/octet-stream"))
  end

  test "admits an exact text/plain declaration before body streaming" do
    assert {:ok,
            %UploadRequest{
              filename: "asset.bin",
              size: 8,
              declared_media_type: "text/plain",
              idempotency_key: "upload-1",
              max_bytes: @text_max_bytes
            }} = UploadRequest.new(valid_attrs("text/plain"))
  end

  test "admits exactly the two text declarations without inferring from filenames" do
    for media_type <- ["text/plain", "text/markdown"], filename <- ["asset.pdf", "notes.md"] do
      assert {:ok,
              %UploadRequest{
                filename: ^filename,
                declared_media_type: ^media_type,
                max_bytes: @text_max_bytes
              }} =
               UploadRequest.new(%{valid_attrs(media_type) | filename: filename})
    end

    assert {:ok, %UploadRequest{declared_media_type: "text/markdown"}} =
             UploadRequest.new(valid_attrs(" text/markdown "))
  end

  test "rejects unsupported MIME declarations including Office and text lookalikes" do
    for media_type <- [
          "application/octet-stream",
          "application/msword",
          "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
          "application/vnd.ms-excel",
          "text/html",
          "text/csv",
          "text/x-markdown",
          "text/plain; charset=utf-8",
          "text/markdown; charset=utf-8",
          "application/json",
          "image/gif"
        ] do
      assert {:error, %Error{code: :unsupported_media_type}} =
               UploadRequest.new(valid_attrs(media_type))
    end
  end

  test "admits an honest empty text declaration even with a zero configured limit" do
    for media_type <- ["text/plain", "text/markdown"] do
      assert {:ok, %UploadRequest{size: 0, max_bytes: 0}} =
               UploadRequest.new(Map.merge(valid_attrs(media_type), %{size: 0, max_bytes: 0}))
    end
  end

  test "caps text at the Document bound without changing binary upload limits" do
    for media_type <- ["text/plain", "text/markdown"] do
      for configured_max <- [@text_max_bytes, @max_bytes, @max_bytes + 1] do
        assert {:ok, %UploadRequest{size: @text_max_bytes, max_bytes: @text_max_bytes}} =
                 UploadRequest.new(
                   Map.merge(valid_attrs(media_type), %{
                     size: @text_max_bytes,
                     max_bytes: configured_max
                   })
                 )

        assert {:error, %Error{code: :upload_too_large}} =
                 UploadRequest.new(
                   Map.merge(valid_attrs(media_type), %{
                     size: @text_max_bytes + 1,
                     max_bytes: configured_max
                   })
                 )
      end
    end

    for media_type <- ["application/pdf", "image/jpeg", "image/png"] do
      assert {:ok, %UploadRequest{size: @max_bytes, max_bytes: @max_bytes}} =
               UploadRequest.new(%{valid_attrs(media_type) | size: @max_bytes})
    end
  end

  test "preserves smaller configured limits for text and binary declarations" do
    for media_type <- [
          "text/plain",
          "text/markdown",
          "application/pdf",
          "image/jpeg",
          "image/png"
        ] do
      assert {:ok, %UploadRequest{size: 7, max_bytes: 7}} =
               UploadRequest.new(Map.merge(valid_attrs(media_type), %{size: 7, max_bytes: 7}))

      assert {:error, %Error{code: :upload_too_large}} =
               UploadRequest.new(Map.put(valid_attrs(media_type), :max_bytes, 7))
    end
  end

  test "keeps filename and idempotency validation for both text declarations" do
    for media_type <- ["text/plain", "text/markdown"],
        field <- [:filename, :idempotency_key],
        value <- ["", <<0>>, <<0xFF>>] do
      assert {:error, %Error{code: :invalid}} =
               media_type
               |> valid_attrs()
               |> Map.put(field, value)
               |> UploadRequest.new()
    end
  end

  test "rejects a declaration over the default limit before body streaming" do
    assert {:error, %Error{code: :upload_too_large}} =
             UploadRequest.new(%{valid_attrs("application/pdf") | size: @max_bytes + 1})
  end

  test "detects media from magic bytes instead of trusting the declaration" do
    assert {:ok, "application/pdf"} =
             UploadRequest.detect_media_type("%PDF-1.7\n")

    assert {:ok, "image/jpeg"} =
             UploadRequest.detect_media_type(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 16>>)

    assert {:ok, "image/png"} =
             UploadRequest.detect_media_type(<<137, 80, 78, 71, 13, 10, 26, 10, 0>>)

    assert {:error, %Error{code: :unsupported_media_type}} =
             UploadRequest.detect_media_type("declared-but-not-a-pdf")

    for bytes <- ["", "plain text", "# Markdown\n", <<0xEF, 0xBB, 0xBF, 65>>] do
      assert {:error, %Error{code: :unsupported_media_type}} =
               UploadRequest.detect_media_type(bytes)
    end
  end

  test "requires detected media to match the declaration" do
    assert :ok =
             UploadRequest.validate_magic(
               request!("application/pdf"),
               "%PDF-1.7\n"
             )

    assert {:error, %Error{code: :unsupported_media_type}} =
             UploadRequest.validate_magic(
               request!("image/png"),
               "%PDF-1.7\n"
             )
  end

  test "validates complete text bytes while preserving their declared identity" do
    for media_type <- ["text/plain", "text/markdown"],
        bytes <- ["", "# plain or Markdown\r\n", "\uFEFFe\u0301 中文 😀\r\n \t", "%PDF"] do
      request = request!(media_type)
      assert :ok = UploadRequest.validate_magic(request, bytes)
      assert request.declared_media_type == media_type
    end
  end

  test "rejects malformed complete text and conflicting leading binary signatures" do
    for media_type <- ["text/plain", "text/markdown"],
        bytes <- [
          "valid prefix" <> <<0>>,
          "valid prefix" <> <<0xFF>>,
          "valid prefix" <> <<0xE2, 0x82>>,
          "%PDF-1.7\n",
          <<0xFF, 0xD8, 0xFF, 0xE0>>,
          <<137, 80, 78, 71, 13, 10, 26, 10>>
        ] do
      assert {:error, %Error{code: :unsupported_media_type, details: %{}}} =
               UploadRequest.validate_magic(request!(media_type), bytes)
    end
  end

  defp valid_attrs(media_type) do
    %{
      filename: "asset.bin",
      size: 8,
      declared_media_type: media_type,
      idempotency_key: "upload-1"
    }
  end

  defp request!(media_type) do
    {:ok, request} = UploadRequest.new(valid_attrs(media_type))
    request
  end
end
