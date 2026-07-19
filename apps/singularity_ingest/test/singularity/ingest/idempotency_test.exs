defmodule Singularity.Ingest.IdempotencyTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Ingest.Idempotency
  alias Singularity.Ingest.UploadRequest

  test "produces a stable digest for the exact grant binding" do
    request = request!()

    assert <<_::binary-size(32)>> = digest = Idempotency.digest(request)
    assert digest == Idempotency.digest(request)
    assert :ok = Idempotency.compare(request, request)
  end

  test "changed bound metadata is a conflict" do
    request = request!()

    for changed <- [
          %{request | filename: "other.pdf"},
          %{request | size: request.size + 1},
          %{request | declared_media_type: "image/png"},
          %{request | resource_version_id: "other-version"},
          %{request | classification: :restricted}
        ] do
      assert {:error, %Error{code: :conflict}} =
               Idempotency.compare(request, changed)
    end
  end

  defp request! do
    {:ok, request} =
      UploadRequest.new(%{
        filename: "report.pdf",
        size: 8,
        declared_media_type: "application/pdf",
        idempotency_key: "upload-1",
        resource_version_id: "resource-version-1",
        classification: :sensitive
      })

    request
  end
end
