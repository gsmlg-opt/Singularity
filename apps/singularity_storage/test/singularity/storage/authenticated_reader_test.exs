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
    def stat(%{fail_at: :stat, failure: error}, _object_ref), do: {:error, error}

    def stat(%{delegate_context: context}, object_ref),
      do: LocalFilesystemAdapter.stat(context, object_ref)

    def open(%{fail_at: :open, failure: error}, _object_ref), do: {:error, error}

    def open(%{delegate_context: context}, object_ref) do
      with {:ok, handle} <- LocalFilesystemAdapter.open(context, object_ref) do
        {:ok, handle}
      end
    end

    def read_range(%{fail_at: :read, failure: error}, _handle, _range),
      do: {:error, error}

    def read_range(
          %{delegate_context: context, owner: owner},
          handle,
          range
        ) do
      send(owner, {:ciphertext_range, range})
      LocalFilesystemAdapter.read_range(context, handle, range)
    end
  end

  test "digest authenticates empty content", %{tmp_dir: tmp_dir} do
    fixture = publish!(tmp_dir, "")
    expected = %{sha256: :crypto.hash(:sha256, ""), byte_size: 0}

    assert {:ok, ^expected} =
             AuthenticatedReader.digest(fixture.storage, fixture.binding, fixture.key)

    assert_received {:ciphertext_range, 66..133}
  end

  for corrupt_record <- [:middle, :final] do
    test "digest rejects corrupt #{corrupt_record} record", %{tmp_dir: tmp_dir} do
      fixture = publish!(tmp_dir, :binary.copy("C", Format.chunk_size() * 2) <> "tail")

      offset =
        case unquote(corrupt_record) do
          :middle -> @header_size + Format.chunk_size() + @record_overhead + 8
          :final -> fixture.binding.ciphertext_byte_size - 1
        end

      corrupt_byte!(fixture.path, offset)

      assert {:error, %Error{code: :integrity_failure}} =
               AuthenticatedReader.digest(fixture.storage, fixture.binding, fixture.key)
    end
  end

  for field <- [:plaintext_bytes, :chunk_count, :plaintext_sha256] do
    test "digest rejects authenticated false #{field}", %{tmp_dir: tmp_dir} do
      plaintext = :binary.copy("D", Format.chunk_size()) <> "tail"
      fixture = publish!(tmp_dir, plaintext)

      metadata = %{
        plaintext_bytes: byte_size(plaintext),
        chunk_count: 2,
        plaintext_sha256: :crypto.hash(:sha256, plaintext)
      }

      false_value = if unquote(field) == :plaintext_sha256, do: <<0::256>>, else: 1
      replace_final!(fixture, Map.put(metadata, unquote(field), false_value))

      assert {:error, %Error{code: :integrity_failure}} =
               AuthenticatedReader.digest(fixture.storage, fixture.binding, fixture.key)
    end
  end

  test "digest rejects truncation, wrong keys and wrong object binding", %{tmp_dir: tmp_dir} do
    fixture = publish!(tmp_dir, "private content")
    other_id = Ecto.UUID.generate()

    wrong_binding = %{
      fixture.binding
      | object_id: other_id,
        object_ref: %ObjectRef{object_id: other_id}
    }

    assert {:error, %Error{code: :integrity_failure}} =
             AuthenticatedReader.digest(fixture.storage, fixture.binding, <<0::256>>)

    assert {:error, %Error{code: :integrity_failure}} =
             AuthenticatedReader.digest(fixture.storage, wrong_binding, fixture.key)

    ciphertext = File.read!(fixture.path)
    File.chmod!(fixture.path, 0o600)
    File.write!(fixture.path, binary_part(ciphertext, 0, byte_size(ciphertext) - 1))

    assert {:error, %Error{code: :integrity_failure}} =
             AuthenticatedReader.digest(fixture.storage, fixture.binding, fixture.key)
  end

  for operation <- [:stat, :open, :read] do
    test "digest strips private #{operation} error details and preserves read errors", %{
      tmp_dir: tmp_dir
    } do
      fixture = publish!(tmp_dir, "private plaintext")

      failure =
        Error.new(:storage_unavailable,
          message: fixture.path,
          details: %{key: fixture.key, handle: fixture.path, plaintext: "private plaintext"},
          retryable?: true
        )

      storage = %{
        fixture.storage
        | context:
            Map.merge(fixture.storage.context, %{fail_at: unquote(operation), failure: failure})
      }

      assert {:error,
              %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}} =
                error} =
               AuthenticatedReader.digest(storage, fixture.binding, fixture.key)

      assert error.details == %{}

      assert {:error, ^failure} =
               AuthenticatedReader.read(storage, fixture.binding, fixture.key, :all)
    end
  end

  test "digest authenticates content and final metadata with bounded reads", %{tmp_dir: tmp_dir} do
    plaintext = :binary.copy("A", Format.chunk_size() * 2) <> "tail"
    fixture = publish!(tmp_dir, plaintext)
    expected = %{sha256: :crypto.hash(:sha256, plaintext), byte_size: byte_size(plaintext)}

    assert {:ok, ^expected} =
             AuthenticatedReader.digest(fixture.storage, fixture.binding, fixture.key)

    chunk_size = Format.chunk_size()
    second_offset = @header_size + chunk_size + @record_overhead
    third_offset = second_offset + chunk_size + @record_overhead
    final_offset = fixture.binding.ciphertext_byte_size - @final_record_size

    for expected_range <- [
          0..(@header_size - 1),
          @header_size..(second_offset - 1),
          second_offset..(third_offset - 1),
          third_offset..(final_offset - 1),
          final_offset..(fixture.binding.ciphertext_byte_size - 1)
        ] do
      assert_receive {:ciphertext_range, ^expected_range}
      assert Range.size(expected_range) <= chunk_size + @record_overhead
      assert Range.size(expected_range) < fixture.binding.ciphertext_byte_size
    end

    refute_receive {:ciphertext_range, _other}
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

  defp replace_final!(fixture, metadata) do
    ciphertext = File.read!(fixture.path)
    {:ok, header, _records, parsed} = Format.split_header(ciphertext)

    plaintext =
      <<metadata.plaintext_bytes::unsigned-big-64, metadata.chunk_count::unsigned-big-32,
        metadata.plaintext_sha256::binary>>

    {encrypted, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        fixture.key,
        Format.nonce(parsed.nonce_prefix, Format.final_counter()),
        plaintext,
        Format.final_aad(header),
        16,
        true
      )

    final =
      <<Format.final_counter()::unsigned-big-32, 44::unsigned-big-32, encrypted::binary,
        tag::binary>>

    offset = byte_size(ciphertext) - @final_record_size
    File.chmod!(fixture.path, 0o600)
    File.write!(fixture.path, binary_part(ciphertext, 0, offset) <> final)
  end
end
