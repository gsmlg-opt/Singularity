defmodule Singularity.Runtime.MetadataLockResumeTest do
  use ExUnit.Case, async: true

  alias Singularity.Ingest.MetadataExtractor
  alias Singularity.Runtime.KeyLease

  @chunk_size 4_194_304

  test "incremental JPEG extraction resumes from a JSON-safe parser checkpoint" do
    jpeg = jpeg_with_sof_after_first_chunk()

    assert {:ok, initial} =
             MetadataExtractor.initial_state("image/jpeg", byte_size(jpeg))

    first_chunk = binary_part(jpeg, 0, @chunk_size)

    assert {:continue, checkpoint} =
             MetadataExtractor.step(initial, first_chunk, 0)

    assert byte_size(JSON.encode!(checkpoint)) < 1_024
    refute checkpoint |> inspect() |> String.contains?(Base.encode64(first_chunk))

    restored = checkpoint |> JSON.encode!() |> JSON.decode!()
    second_chunk = binary_part(jpeg, @chunk_size, byte_size(jpeg) - @chunk_size)

    assert {:done, metadata, final_state} =
             MetadataExtractor.step(restored, second_chunk, @chunk_size)

    assert metadata == %{
             detected_media_type: "image/jpeg",
             plaintext_bytes: byte_size(jpeg),
             width: 3,
             height: 2,
             pdf_version: nil,
             extractor_version: 1
           }

    assert final_state == %{
             "phase" => "done",
             "result" => %{
               "detected_media_type" => "image/jpeg",
               "plaintext_bytes" => byte_size(jpeg),
               "width" => 3,
               "height" => 2,
               "pdf_version" => nil,
               "extractor_version" => 1
             }
           }
  end

  test "final JPEG byte without a start-of-frame is a terminal integrity failure" do
    jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0>>

    assert {:ok, initial} = MetadataExtractor.initial_state("image/jpeg", byte_size(jpeg))

    assert {:error, error, final_state} = MetadataExtractor.step(initial, jpeg, 0)
    assert error.code == :integrity_failure

    assert final_state == %{
             "phase" => "failed",
             "error_code" => "integrity_failure",
             "declared_media_type" => "image/jpeg",
             "plaintext_bytes" => byte_size(jpeg)
           }
  end

  test "runtime checkpoint validation rejects storage-invalid terminal shapes" do
    valid = %{
      "phase" => "done",
      "result" => %{
        "detected_media_type" => "application/pdf",
        "plaintext_bytes" => 10,
        "width" => nil,
        "height" => nil,
        "pdf_version" => "1.7",
        "extractor_version" => 1
      }
    }

    assert :ok = MetadataExtractor.validate_state(valid)

    assert {:error, %{code: :integrity_failure}} =
             MetadataExtractor.validate_state(put_in(valid, ["result", "extra"], true))

    assert {:error, %{code: :integrity_failure}} =
             MetadataExtractor.validate_state(put_in(valid, ["result", "width"], 1))

    assert {:error, %{code: :integrity_failure}} =
             MetadataExtractor.validate_state(put_in(valid, ["result", "extractor_version"], 2))

    for invalid_pdf_version <- ["10.0", "1.x", "1.7 "] do
      assert {:error, %{code: :integrity_failure}} =
               MetadataExtractor.validate_state(
                 put_in(valid, ["result", "pdf_version"], invalid_pdf_version)
               )
    end

    jpeg =
      valid
      |> put_in(["result", "detected_media_type"], "image/jpeg")
      |> put_in(["result", "width"], 65_535)
      |> put_in(["result", "height"], 65_535)
      |> put_in(["result", "pdf_version"], nil)

    assert :ok = MetadataExtractor.validate_state(jpeg)

    assert {:error, %{code: :integrity_failure}} =
             MetadataExtractor.validate_state(put_in(jpeg, ["result", "width"], 65_536))

    png =
      jpeg
      |> put_in(["result", "detected_media_type"], "image/png")
      |> put_in(["result", "width"], 2_147_483_647)

    assert :ok = MetadataExtractor.validate_state(png)

    assert {:error, %{code: :integrity_failure}} =
             MetadataExtractor.validate_state(put_in(png, ["result", "width"], 2_147_483_648))
  end

  test "a start checkpoint is valid only at chunk index zero" do
    binding = metadata_binding("application/pdf", @chunk_size + 1)

    {:ok, start_state} =
      MetadataExtractor.initial_state("application/pdf", @chunk_size + 1)

    assert {:ok, 0, ^start_state} =
             binding
             |> KeyLease.metadata_checkpoint(0, start_state)
             |> KeyLease.validate_metadata_checkpoint(binding)

    assert {:error, %{code: :integrity_failure}} =
             binding
             |> KeyLease.metadata_checkpoint(1, start_state)
             |> KeyLease.validate_metadata_checkpoint(binding)
  end

  test "a well-shaped checkpoint for a stale processing revision is a conflict" do
    binding = metadata_binding()
    {:ok, start_state} = MetadataExtractor.initial_state("application/pdf", 10)
    checkpoint = KeyLease.metadata_checkpoint(binding, 0, start_state)

    assert {:error, %{code: :conflict}} =
             KeyLease.validate_metadata_checkpoint(
               checkpoint,
               %{binding | processing_revision: binding.processing_revision + 1}
             )
  end

  test "malformed outer metadata checkpoint fields are integrity failures" do
    binding = metadata_binding()
    {:ok, start_state} = MetadataExtractor.initial_state("application/pdf", 10)
    checkpoint = KeyLease.metadata_checkpoint(binding, 0, start_state)

    for malformed <- [
          Map.put(checkpoint, "job_id", ""),
          Map.put(checkpoint, "job_id", <<0xFF>>),
          Map.put(checkpoint, "required_capability", 123),
          Map.put(checkpoint, "principal_authorization_epoch", -1),
          Map.put(checkpoint, "vault_authorization_epoch", 9_223_372_036_854_775_808),
          Map.put(checkpoint, "object_generation", 0),
          Map.put(checkpoint, "processing_revision", 0),
          Map.put(checkpoint, "next_chunk_index", -1)
        ] do
      assert {:error, %{code: :integrity_failure}} =
               KeyLease.validate_metadata_checkpoint(malformed, binding)
    end

    assert {:error, %{code: :conflict}} =
             KeyLease.validate_metadata_checkpoint(
               Map.put(checkpoint, "object_id", "object-other"),
               binding
             )
  end

  test "in-progress and terminal checkpoint indexes stay within object chunk bounds" do
    jpeg = jpeg_with_sof_after_first_chunk()
    binding = metadata_binding("image/jpeg", byte_size(jpeg))
    {:ok, initial} = MetadataExtractor.initial_state("image/jpeg", byte_size(jpeg))

    assert {:continue, jpeg_scan} =
             MetadataExtractor.step(initial, binary_part(jpeg, 0, @chunk_size), 0)

    assert {:ok, 1, ^jpeg_scan} =
             binding
             |> KeyLease.metadata_checkpoint(1, jpeg_scan)
             |> KeyLease.validate_metadata_checkpoint(binding)

    for invalid_index <- [0, 2] do
      assert {:error, %{code: :integrity_failure}} =
               binding
               |> KeyLease.metadata_checkpoint(invalid_index, jpeg_scan)
               |> KeyLease.validate_metadata_checkpoint(binding)
    end

    done = %{
      "phase" => "done",
      "result" => %{
        "detected_media_type" => "image/jpeg",
        "plaintext_bytes" => byte_size(jpeg),
        "width" => 3,
        "height" => 2,
        "pdf_version" => nil,
        "extractor_version" => 1
      }
    }

    failed = %{
      "phase" => "failed",
      "error_code" => "integrity_failure",
      "declared_media_type" => "image/jpeg",
      "plaintext_bytes" => byte_size(jpeg)
    }

    for terminal <- [done, failed], valid_index <- [1, 2] do
      assert {:ok, ^valid_index, ^terminal} =
               binding
               |> KeyLease.metadata_checkpoint(valid_index, terminal)
               |> KeyLease.validate_metadata_checkpoint(binding)
    end

    for terminal <- [done, failed], invalid_index <- [0, 3] do
      assert {:error, %{code: :integrity_failure}} =
               binding
               |> KeyLease.metadata_checkpoint(invalid_index, terminal)
               |> KeyLease.validate_metadata_checkpoint(binding)
    end
  end

  defp jpeg_with_sof_after_first_chunk do
    large_application_segment =
      <<0xFF, 0xE0, 65_535::unsigned-big-16>> <>
        :binary.copy(<<0>>, 65_533)

    sof =
      <<0xFF, 0xC0, 11::unsigned-big-16, 8, 2::unsigned-big-16, 3::unsigned-big-16, 1, 1, 0x11,
        0>>

    <<0xFF, 0xD8>> <> :binary.copy(large_application_segment, 64) <> sof
  end

  defp metadata_binding(
         declared_media_type \\ "application/pdf",
         plaintext_byte_size \\ 10
       ) do
    %{
      job_id: "job-1",
      vault_id: "vault-1",
      principal_id: "principal-1",
      required_capability: "asset.read",
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      object_id: "object-1",
      object_generation: 3,
      processing_revision: 5,
      declared_media_type: declared_media_type,
      plaintext_byte_size: plaintext_byte_size
    }
  end
end
