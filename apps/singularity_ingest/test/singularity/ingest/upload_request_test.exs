defmodule Singularity.Ingest.UploadRequestTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Ingest.UploadRequest

  @max_bytes 512 * 1024 * 1024

  test "normalizes a supported upload request and keeps its exact binding" do
    assert {:ok,
            %UploadRequest{
              filename: "report.pdf",
              size: 8,
              declared_media_type: "application/pdf",
              idempotency_key: "upload-1",
              resource_version_id: "resource-version-1",
              classification: :sensitive,
              max_bytes: @max_bytes
            }} =
             UploadRequest.new(%{
               filename: "report.pdf",
               size: 8,
               declared_media_type: " application/pdf ",
               idempotency_key: "upload-1",
               resource_version_id: "resource-version-1",
               classification: :sensitive
             })
  end

  test "accepts exactly PDF, JPEG, and PNG declarations" do
    for media_type <- ["application/pdf", "image/jpeg", "image/png"] do
      assert {:ok, %UploadRequest{declared_media_type: ^media_type}} =
               UploadRequest.new(valid_attrs(media_type))
    end

    assert {:error, %Error{code: :unsupported_media_type}} =
             UploadRequest.new(valid_attrs("text/plain"))
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

  defp valid_attrs(media_type) do
    %{
      filename: "asset.bin",
      size: 8,
      declared_media_type: media_type,
      idempotency_key: "upload-1",
      resource_version_id: "resource-version-1",
      classification: :sensitive
    }
  end

  defp request!(media_type) do
    {:ok, request} = UploadRequest.new(valid_attrs(media_type))
    request
  end
end
