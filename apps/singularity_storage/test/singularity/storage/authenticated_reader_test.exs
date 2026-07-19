defmodule Singularity.Storage.AuthenticatedReaderTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Storage.AuthenticatedReader
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.LocalFilesystemAdapter

  @moduletag :tmp_dir

  @vault_id "00000000-0000-0000-0000-000000000001"
  @domain_id "00000000-0000-0000-0000-000000000002"
  @header_size 66
  @record_overhead 24
  @final_record_size 68

  defmodule RecordingStorage do
    def stat(%{delegate_context: context}, object_ref),
      do: LocalFilesystemAdapter.stat(context, object_ref)

    def open(%{delegate_context: context}, object_ref) do
      with {:ok, handle} <- LocalFilesystemAdapter.open(context, object_ref) do
        {:ok, handle}
      end
    end

    def read_range(
          %{delegate_context: context, owner: owner},
          handle,
          range
        ) do
      send(owner, {:ciphertext_range, range})
      LocalFilesystemAdapter.read_range(context, handle, range)
    end
  end

  test "authenticates aligned records and trims a range crossing chunk boundaries", %{
    tmp_dir: tmp_dir
  } do
    chunk_size = Format.chunk_size()
    plaintext = :binary.copy("A", chunk_size) <> "tail-B"
    fixture = publish!(tmp_dir, plaintext)
    range = (chunk_size - 3)..(chunk_size + 4)

    assert {:ok, "AAA" <> "tail-"} =
             AuthenticatedReader.read(
               fixture.storage,
               fixture.binding,
               fixture.key,
               range
             )

    first_record = @header_size..(@header_size + chunk_size + @record_overhead - 1)

    second_offset = @header_size + chunk_size + @record_overhead

    second_record =
      second_offset..(second_offset + byte_size("tail-B") + @record_overhead - 1)

    header_range = 0..(@header_size - 1)
    assert_receive {:ciphertext_range, ^header_range}
    assert_receive {:ciphertext_range, ^first_record}
    assert_receive {:ciphertext_range, ^second_record}
    refute_receive {:ciphertext_range, _other}
  end

  test "a full read authenticates every data record and final metadata", %{
    tmp_dir: tmp_dir
  } do
    plaintext = :binary.copy("B", Format.chunk_size()) <> "final"
    fixture = publish!(tmp_dir, plaintext)

    assert {:ok, ^plaintext} =
             AuthenticatedReader.read(
               fixture.storage,
               fixture.binding,
               fixture.key,
               :all
             )

    final_start = fixture.binding.ciphertext_byte_size - @final_record_size
    assert_received {:ciphertext_range, %Range{first: ^final_start, last: final_end, step: 1}}
    assert final_end == fixture.binding.ciphertext_byte_size - 1
  end

  test "corruption in a selected data record fails closed", %{tmp_dir: tmp_dir} do
    chunk_size = Format.chunk_size()
    plaintext = :binary.copy("C", chunk_size) <> "selected"
    fixture = publish!(tmp_dir, plaintext)
    second_record_offset = @header_size + chunk_size + @record_overhead
    second_tag_offset = second_record_offset + 8 + byte_size("selected")

    corrupt_byte!(fixture.path, second_tag_offset)

    assert {:error, %Error{code: :integrity_failure}} =
             AuthenticatedReader.read(
               fixture.storage,
               fixture.binding,
               fixture.key,
               chunk_size..(chunk_size + 2)
             )
  end

  test "a full read rejects corrupted final metadata", %{tmp_dir: tmp_dir} do
    fixture = publish!(tmp_dir, "authenticated final metadata")
    corrupt_byte!(fixture.path, fixture.binding.ciphertext_byte_size - 1)

    assert {:error, %Error{code: :integrity_failure}} =
             AuthenticatedReader.read(
               fixture.storage,
               fixture.binding,
               fixture.key,
               :all
             )
  end

  test "truncated ciphertext is rejected instead of accepting a short range read", %{
    tmp_dir: tmp_dir
  } do
    fixture = publish!(tmp_dir, "never accept partial ciphertext")

    File.chmod!(fixture.path, 0o600)

    :ok =
      fixture.path
      |> File.open!([:read, :write, :binary])
      |> then(fn io ->
        try do
          :file.position(io, fixture.binding.ciphertext_byte_size - 1)
          :file.truncate(io)
        after
          File.close(io)
        end
      end)

    assert {:error, %Error{code: :integrity_failure}} =
             AuthenticatedReader.read(
               fixture.storage,
               fixture.binding,
               fixture.key,
               0..3
             )
  end

  defp publish!(tmp_dir, plaintext) do
    key = :crypto.strong_rand_bytes(32)
    object_id = Ecto.UUID.generate()
    lookup_digest = :crypto.strong_rand_bytes(32)
    lookup_digest_hex = Base.encode16(lookup_digest, case: :lower)
    object_ref = %ObjectRef{object_id: object_id}

    codec_context = %{
      key: key,
      plaintext: plaintext,
      format_version: Format.format_version(),
      algorithm: Format.algorithm(),
      chunk_size: Format.chunk_size(),
      vault_id: @vault_id,
      encryption_domain_id: @domain_id,
      object_id: object_id,
      chunk_index: 0
    }

    assert {:ok, ciphertext} = ChunkedAEAD.encode(codec_context)

    delegate_context = %{
      root: tmp_dir,
      vault_namespace: @vault_id,
      domain_namespace: @domain_id,
      lookup_digest: lookup_digest_hex
    }

    assert {:ok, stage_ref} =
             LocalFilesystemAdapter.stage(delegate_context, %{})

    assert :ok =
             LocalFilesystemAdapter.append_encrypted_chunk(
               delegate_context,
               stage_ref,
               ciphertext
             )

    assert {:ok, %{sealed?: true}} =
             LocalFilesystemAdapter.seal_stage(
               delegate_context,
               stage_ref,
               %{}
             )

    assert {:ok, ^object_ref} =
             LocalFilesystemAdapter.finalize(
               delegate_context,
               stage_ref,
               object_ref
             )

    assert {:ok, path} =
             PathGuard.object_path(
               tmp_dir,
               @vault_id,
               @domain_id,
               lookup_digest_hex
             )

    %{
      key: key,
      path: path,
      storage: %{
        adapter: RecordingStorage,
        context: %{delegate_context: delegate_context, owner: self()}
      },
      binding: %{
        object_ref: object_ref,
        object_id: object_id,
        vault_id: @vault_id,
        encryption_domain_id: @domain_id,
        plaintext_byte_size: byte_size(plaintext),
        ciphertext_byte_size: byte_size(ciphertext),
        format_version: Format.format_version()
      }
    }
  end

  defp corrupt_byte!(path, offset) do
    File.chmod!(path, 0o600)
    {:ok, io} = :file.open(path, [:read, :write, :binary])

    try do
      {:ok, <<byte>>} = :file.pread(io, offset, 1)
      :ok = :file.pwrite(io, offset, <<Bitwise.bxor(byte, 1)>>)
      :ok = :file.sync(io)
    after
      :ok = :file.close(io)
    end
  end
end
