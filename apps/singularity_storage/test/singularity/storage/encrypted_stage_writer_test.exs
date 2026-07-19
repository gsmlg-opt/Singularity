defmodule Singularity.Storage.EncryptedStageWriterTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.ObjectRef
  alias Singularity.Core.Error
  alias Singularity.Core.StageRef
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.ObjectIdentity
  alias Singularity.Storage.EncryptedStageWriter
  alias Singularity.Storage.Local.PathGuard
  alias Singularity.Storage.LocalFilesystemAdapter

  @vault_id "00000000-0000-0000-0000-000000000001"
  @domain_id "00000000-0000-0000-0000-000000000002"
  @object_id "00000000-0000-0000-0000-000000000003"

  @moduletag :tmp_dir

  test "stage-only streaming durably seals without dedup lookup or physical publication", %{
    tmp_dir: tmp_dir
  } do
    owner = self()
    plaintext = "%PDF-1.7\nstaged"

    storage =
      storage(tmp_dir,
        dedup_lookup: fn _vault_id, _domain_id, _lookup_digest ->
          send(owner, :dedup_looked_up)
          :miss
        end
      )

    assert {:ok,
            %{
              stage_ref: stage_ref,
              object_ref: %ObjectRef{object_id: @object_id},
              plaintext_byte_size: plaintext_size,
              ciphertext_byte_size: ciphertext_size,
              lookup_digest: <<_::binary-size(32)>>,
              ciphertext_hash: <<_::binary-size(32)>>,
              format_version: 1,
              dek_wrapper: "wrapped-dek"
            }} =
             EncryptedStageWriter.stream_and_seal_stage(
               storage,
               upload(byte_size(plaintext)),
               [plaintext]
             )

    assert plaintext_size == byte_size(plaintext)
    assert ciphertext_size > plaintext_size

    assert {:ok, %{sealed?: true, byte_size: ^ciphertext_size}} =
             LocalFilesystemAdapter.stat_stage(storage.context, stage_ref)

    assert {:ok, [^stage_ref]} =
             LocalFilesystemAdapter.list_staged(storage.context)

    refute_received :dedup_looked_up
  end

  test "stage-only streaming uses a caller-created durable stage", %{tmp_dir: tmp_dir} do
    plaintext = "%PDF-1.7\ncaller-stage"
    storage = storage(tmp_dir)
    stage_ref = %StageRef{stage_id: Ecto.UUID.generate()}

    upload =
      byte_size(plaintext)
      |> upload()
      |> Map.put(:stage_ref, stage_ref)

    assert {:ok, %{stage_ref: ^stage_ref}} =
             EncryptedStageWriter.stream_and_seal_stage(storage, upload, [plaintext])

    assert {:ok, [^stage_ref]} =
             LocalFilesystemAdapter.list_staged(storage.context)
  end

  defmodule RecordingAdapter do
    @moduledoc false

    alias Singularity.Core.Error
    alias Singularity.Storage.LocalFilesystemAdapter

    def stage(%{raise_stage?: true} = context, _options) do
      send(context.test_pid, {:adapter, :stage})
      raise "injected stage failure"
    end

    def stage(context, options) do
      send(context.test_pid, {:adapter, :stage})
      LocalFilesystemAdapter.stage(context, options)
    end

    def append_encrypted_chunk(context, stage_ref, bytes) do
      send(context.test_pid, {:adapter, :append, IO.iodata_to_binary(bytes)})
      LocalFilesystemAdapter.append_encrypted_chunk(context, stage_ref, bytes)
    end

    def seal_stage(context, stage_ref, metadata) do
      send(context.test_pid, {:adapter, :seal, metadata})
      LocalFilesystemAdapter.seal_stage(context, stage_ref, metadata)
    end

    def finalize(%{fail_finalize?: true} = context, _stage_ref, _object_ref) do
      send(context.test_pid, {:adapter, :finalize})
      {:error, Error.new(:storage_unavailable, retryable?: true)}
    end

    def finalize(%{raise_after_finalize?: true} = context, stage_ref, object_ref) do
      send(context.test_pid, {:adapter, :finalize})

      assert_published!(
        LocalFilesystemAdapter.finalize(context, stage_ref, object_ref),
        object_ref
      )

      raise "injected post-publication failure"
    end

    def finalize(context, stage_ref, object_ref) do
      send(context.test_pid, {:adapter, :finalize})
      LocalFilesystemAdapter.finalize(context, stage_ref, object_ref)
    end

    def abort_stage(context, stage_ref) do
      send(context.test_pid, {:adapter, :abort})
      LocalFilesystemAdapter.abort_stage(context, stage_ref)
    end

    def stat_stage(context, stage_ref) do
      LocalFilesystemAdapter.stat_stage(context, stage_ref)
    end

    def stat(context, object_ref) do
      LocalFilesystemAdapter.stat(context, object_ref)
    end

    defp assert_published!({:ok, object_ref}, object_ref), do: :ok
  end

  defmodule SilentCodec do
    @moduledoc false

    def init_encrypt(_context) do
      {:ok, "header", %{hash: :crypto.hash_init(:sha256), bytes: 0, chunks: 0}}
    end

    def encrypt_chunk(state, plaintext) do
      {:ok, "",
       %{
         state
         | hash: :crypto.hash_update(state.hash, plaintext),
           bytes: state.bytes + byte_size(plaintext),
           chunks: state.chunks + 1
       }}
    end

    def finalize(state) do
      {:ok, "final-tail",
       %{
         plaintext_bytes: state.bytes,
         chunk_count: div(state.bytes + 4_194_303, 4_194_304),
         plaintext_sha256: :crypto.hash_final(state.hash)
       }, :finalized}
    end
  end

  defmodule FailingCodec do
    @moduledoc false

    def init_encrypt(_context), do: {:ok, "header", :open}
    def encrypt_chunk(:open, _plaintext), do: {:error, :invalid_format}
  end

  defmodule InvalidSummaryCodec do
    @moduledoc false

    defdelegate init_encrypt(context), to: SilentCodec
    defdelegate encrypt_chunk(state, plaintext), to: SilentCodec

    def finalize(state) do
      {:ok, tail, summary, finalized} = SilentCodec.finalize(state)
      {:ok, tail, %{summary | chunk_count: summary.chunk_count + 1}, finalized}
    end
  end

  test "streams canonical encrypted bytes, protected identity, and hashes into durable storage",
       %{
         tmp_dir: tmp_dir
       } do
    plaintext_fragments = ["short", "-", :binary.copy("transport-fragment", 20)]
    plaintext = IO.iodata_to_binary(plaintext_fragments)
    upload = upload(byte_size(plaintext))
    storage = storage(tmp_dir)

    assert {:ok,
            %{
              object_ref: %ObjectRef{object_id: @object_id},
              plaintext_byte_size: plaintext_size,
              ciphertext_byte_size: ciphertext_size,
              lookup_digest: lookup_digest,
              ciphertext_hash: ciphertext_hash,
              format_version: 1,
              dek_wrapper: "wrapped-dek"
            } = result} =
             EncryptedStageWriter.stream_and_seal(storage, upload, plaintext_fragments)

    assert plaintext_size == byte_size(plaintext)
    refute Map.has_key?(result, :plaintext_sha256)
    refute Map.has_key?(result, :stage_ref)

    assert {:ok, ^lookup_digest} =
             ObjectIdentity.lookup_digest(
               upload.domain_dedup_key,
               :crypto.hash(:sha256, plaintext)
             )

    lookup_hex = Base.encode16(lookup_digest, case: :lower)

    assert {:ok, object_path} =
             PathGuard.object_path(tmp_dir, @vault_id, @domain_id, lookup_hex)

    ciphertext = File.read!(object_path)
    assert byte_size(ciphertext) == ciphertext_size
    assert :crypto.hash(:sha256, ciphertext) == ciphertext_hash

    assert {:ok, ^plaintext} =
             ChunkedAEAD.decode(ciphertext, %{
               key: upload.object_dek,
               format_version: 1,
               algorithm: :aes_256_gcm,
               chunk_size: 4_194_304,
               vault_id: @vault_id,
               encryption_domain_id: @domain_id,
               object_id: @object_id,
               chunk_index: 0
             })

    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "does not append when the codec emits an empty transport result", %{
    tmp_dir: tmp_dir
  } do
    storage =
      tmp_dir
      |> storage()
      |> Map.put(:adapter, RecordingAdapter)
      |> Map.put(:codec, SilentCodec)
      |> put_in([:context, :test_pid], self())

    assert {:ok, _result} =
             EncryptedStageWriter.stream_and_seal(
               storage,
               upload(6),
               ["one", "two"]
             )

    assert_received {:adapter, :append, "header"}
    assert_received {:adapter, :append, "final-tail"}
    assert_received {:adapter, :seal, metadata}
    refute Map.has_key?(metadata, :plaintext_sha256)
    refute_received {:adapter, :append, ""}
  end

  test "streams canonical records as transport fragments cross the codec boundary", %{
    tmp_dir: tmp_dir
  } do
    chunk_size = 4_194_304
    fragments = ["prefix", :binary.copy(<<17>>, chunk_size), "tail"]
    expected_bytes = Enum.reduce(fragments, 0, &(byte_size(&1) + &2))

    storage =
      tmp_dir
      |> storage()
      |> Map.put(:adapter, RecordingAdapter)
      |> put_in([:context, :test_pid], self())

    assert {:ok, %{plaintext_byte_size: ^expected_bytes}} =
             EncryptedStageWriter.stream_and_seal(
               storage,
               upload(expected_bytes),
               fragments
             )

    assert_received {:adapter, :append, <<_header::binary-size(66)>>}
    assert_received {:adapter, :append, emitted_record}
    assert byte_size(emitted_record) > chunk_size
    assert_received {:adapter, :append, final_tail}
    assert byte_size(final_tail) > 0
    refute_received {:adapter, :append, ""}
  end

  test "rejects an oversized declaration before staging or enumerating", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    storage =
      storage(tmp_dir,
        destroy_dek_wrapper: fn _wrapper ->
          send(parent, :wrapper_destroyed)
          :ok
        end
      )

    stream =
      Stream.map(["must-not-be-read"], fn chunk ->
        send(parent, :stream_enumerated)
        chunk
      end)

    assert {:error, %Error{code: :upload_too_large}, nil} =
             EncryptedStageWriter.stream_and_seal(
               storage,
               %{upload(11) | max_bytes: 10},
               stream
             )

    refute_received :stream_enumerated
    assert_received :wrapper_destroyed
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "a raised stage call destroys the wrapper and returns a normalized error", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    storage =
      tmp_dir
      |> storage(
        destroy_dek_wrapper: fn wrapper ->
          send(parent, {:wrapper_destroyed, wrapper})
          :ok
        end
      )
      |> Map.put(:adapter, RecordingAdapter)
      |> put_in([:context], %{
        root: tmp_dir,
        test_pid: self(),
        raise_stage?: true
      })

    assert {:error, %Error{code: :storage_unavailable}, nil} =
             EncryptedStageWriter.stream_and_seal(storage, upload(4), ["four"])

    assert_received {:adapter, :stage}
    assert_received {:wrapper_destroyed, "wrapped-dek"}
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "an invalid upload still destroys the wrapper transferred to the writer", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    storage =
      storage(tmp_dir,
        destroy_dek_wrapper: fn wrapper ->
          send(parent, {:wrapper_destroyed, wrapper})
          :ok
        end
      )

    assert {:error, %Error{code: :invalid}, nil} =
             EncryptedStageWriter.stream_and_seal(
               storage,
               %{upload(4) | vault_id: "not-a-uuid"},
               ["four"]
             )

    assert_received {:wrapper_destroyed, "wrapped-dek"}
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "aborts the stage and destroys its wrapper when streamed bytes exceed the limit", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    storage =
      storage(tmp_dir,
        destroy_dek_wrapper: fn wrapper ->
          send(parent, {:wrapper_destroyed, wrapper})
          :ok
        end
      )

    assert {:error, %Error{code: :upload_too_large}, %_{}} =
             EncryptedStageWriter.stream_and_seal(
               storage,
               %{upload(5) | max_bytes: 5},
               ["123", "456"]
             )

    assert_received {:wrapper_destroyed, "wrapped-dek"}
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "rejects a final observed-size mismatch and cleans up", %{tmp_dir: tmp_dir} do
    parent = self()

    storage =
      storage(tmp_dir,
        destroy_dek_wrapper: fn _wrapper ->
          send(parent, :wrapper_destroyed)
          :ok
        end
      )

    assert {:error, %Error{code: :invalid}, %_{}} =
             EncryptedStageWriter.stream_and_seal(
               storage,
               upload(5),
               ["four"]
             )

    assert_received :wrapper_destroyed
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "aborts and destroys the wrapper after a codec failure", %{tmp_dir: tmp_dir} do
    parent = self()

    storage =
      tmp_dir
      |> storage(
        destroy_dek_wrapper: fn _wrapper ->
          send(parent, :wrapper_destroyed)
          :ok
        end
      )
      |> Map.put(:codec, FailingCodec)
      |> Map.put(:adapter, RecordingAdapter)
      |> put_in([:context, :test_pid], self())

    assert {:error, %Error{code: :invalid}, %_{}} =
             EncryptedStageWriter.stream_and_seal(storage, upload(3), ["bad"])

    assert_received {:adapter, :abort}
    assert_received :wrapper_destroyed
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "an interrupted enumerable aborts the partial stage and destroys its wrapper", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    storage =
      storage(tmp_dir,
        destroy_dek_wrapper: fn _wrapper ->
          send(parent, :wrapper_destroyed)
          :ok
        end
      )

    stream =
      Stream.concat([
        ["first"],
        Stream.map(["interrupt"], fn _chunk -> raise "connection closed" end)
      ])

    assert {:error, %Error{code: :storage_unavailable}, %_{}} =
             EncryptedStageWriter.stream_and_seal(
               storage,
               %{upload(10) | max_bytes: 20},
               stream
             )

    assert_received :wrapper_destroyed
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "rejects inconsistent authenticated final summary metadata", %{tmp_dir: tmp_dir} do
    parent = self()

    storage =
      tmp_dir
      |> storage(
        destroy_dek_wrapper: fn _wrapper ->
          send(parent, :wrapper_destroyed)
          :ok
        end
      )
      |> Map.put(:codec, InvalidSummaryCodec)

    assert {:error, %Error{code: :integrity_failure}, %_{}} =
             EncryptedStageWriter.stream_and_seal(storage, upload(4), ["four"])

    assert_received :wrapper_destroyed
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "a seal sync failure is cleaned up and never acknowledged", %{tmp_dir: tmp_dir} do
    parent = self()
    sync_state_key = {__MODULE__, make_ref()}

    storage =
      storage(tmp_dir,
        destroy_dek_wrapper: fn _wrapper ->
          send(parent, :wrapper_destroyed)
          :ok
        end
      )
      |> put_in(
        [:context, :sync_options],
        sync_fun: fn
          :file, path ->
            if String.contains?(path, "/staging/") do
              Process.put(sync_state_key, :stage_file_synced)
            end

            :ok

          :directory, _path ->
            if Process.get(sync_state_key) == :stage_file_synced do
              {:error, :injected_sync_failure}
            else
              :ok
            end
        end
      )

    assert {:error, %Error{code: :storage_unavailable}, %_{}} =
             EncryptedStageWriter.stream_and_seal(storage, upload(4), ["four"])

    assert_received :wrapper_destroyed
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "a finalization failure aborts the stage and destroys the wrapper", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    storage =
      tmp_dir
      |> storage(
        destroy_dek_wrapper: fn _wrapper ->
          send(parent, :wrapper_destroyed)
          :ok
        end
      )
      |> Map.put(:adapter, RecordingAdapter)
      |> Map.merge(%{context: %{root: tmp_dir, test_pid: self(), fail_finalize?: true}})

    assert {:error, %Error{code: :storage_unavailable}, %_{}} =
             EncryptedStageWriter.stream_and_seal(storage, upload(4), ["four"])

    assert_received {:adapter, :finalize}
    assert_received {:adapter, :abort}
    assert_received :wrapper_destroyed
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "a post-publication sync failure preserves an actionable recovery handle and wrapper", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    sync_state_key = {__MODULE__, make_ref()}

    failing_sync = fn
      :file, path ->
        if String.contains?(path, "/objects/") do
          Process.put(sync_state_key, :object_file_synced)
        end

        :ok

      :directory, _path ->
        if Process.get(sync_state_key) == :object_file_synced do
          {:error, :injected_post_publication_failure}
        else
          :ok
        end
    end

    storage =
      storage(tmp_dir,
        destroy_dek_wrapper: fn wrapper ->
          send(parent, {:wrapper_destroyed, wrapper})
          :ok
        end
      )

    failing_storage =
      put_in(storage, [:context, :sync_options], sync_fun: failing_sync)

    assert {:error,
            %Error{
              code: :storage_unavailable,
              details: %{publication_state: :published}
            },
            %{
              __struct__: Singularity.Storage.EncryptedStageWriter.RecoveryRef,
              stage_ref: stage_ref,
              object_ref: %ObjectRef{object_id: @object_id},
              dek_wrapper: "wrapped-dek"
            } = recovery} =
             EncryptedStageWriter.stream_and_seal(
               failing_storage,
               upload(4),
               ["four"]
             )

    refute_received {:wrapper_destroyed, "wrapped-dek"}
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)

    assert {:ok, %{object_ref: %ObjectRef{object_id: @object_id}} = recovered} =
             EncryptedStageWriter.retry_finalize(storage, recovery)

    refute Map.has_key?(recovered, :stage_ref)
    refute Map.has_key?(recovered, :plaintext_sha256)
    assert stage_ref == recovery.stage_ref
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
    refute_received {:wrapper_destroyed, "wrapped-dek"}
  end

  test "a raised finalize call after publication preserves recovery state and wrapper", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    storage =
      tmp_dir
      |> storage(
        destroy_dek_wrapper: fn wrapper ->
          send(parent, {:wrapper_destroyed, wrapper})
          :ok
        end
      )
      |> Map.put(:adapter, RecordingAdapter)
      |> put_in([:context], %{
        root: tmp_dir,
        test_pid: self(),
        raise_after_finalize?: true
      })

    assert {:error, %Error{code: :storage_unavailable},
            %{
              __struct__: Singularity.Storage.EncryptedStageWriter.RecoveryRef,
              object_ref: %ObjectRef{object_id: @object_id},
              dek_wrapper: "wrapped-dek"
            } = recovery} =
             EncryptedStageWriter.stream_and_seal(storage, upload(4), ["four"])

    assert_received {:adapter, :finalize}
    refute_received {:adapter, :abort}
    refute_received {:wrapper_destroyed, "wrapped-dek"}
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)

    retry_storage =
      storage(tmp_dir,
        destroy_dek_wrapper: fn wrapper ->
          send(parent, {:wrapper_destroyed, wrapper})
          :ok
        end
      )

    assert {:ok, %{object_ref: %ObjectRef{object_id: @object_id}}} =
             EncryptedStageWriter.retry_finalize(retry_storage, recovery)

    refute_received {:wrapper_destroyed, "wrapped-dek"}
  end

  test "deduplicates only against a canonical object in the same vault and domain", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    existing_ref = %ObjectRef{object_id: "00000000-0000-0000-0000-000000000009"}
    canonical_ciphertext_hash = :binary.copy(<<42>>, 32)

    storage =
      storage(tmp_dir,
        dedup_lookup: fn vault_id, domain_id, lookup_digest ->
          send(parent, {:dedup_scope, vault_id, domain_id, lookup_digest})

          {:ok,
           %{
             vault_id: vault_id,
             encryption_domain_id: domain_id,
             object_ref: existing_ref,
             dek_wrapper: "canonical-wrapper",
             plaintext_byte_size: 4,
             ciphertext_byte_size: 999,
             ciphertext_hash: canonical_ciphertext_hash,
             format_version: 1,
             lookup_digest: lookup_digest,
             lifecycle: :available
           }}
        end,
        destroy_dek_wrapper: fn wrapper ->
          send(parent, {:wrapper_destroyed, wrapper})
          :ok
        end
      )

    assert {:ok,
            %{
              object_ref: ^existing_ref,
              dek_wrapper: "canonical-wrapper",
              plaintext_byte_size: 4,
              ciphertext_byte_size: 999,
              ciphertext_hash: ^canonical_ciphertext_hash,
              format_version: 1
            } = result} =
             EncryptedStageWriter.stream_and_seal(storage, upload(4), ["four"])

    assert_received {:dedup_scope, @vault_id, @domain_id, lookup_digest}
    assert lookup_digest == result.lookup_digest
    assert_received {:wrapper_destroyed, "wrapped-dek"}
    refute Map.has_key?(result, :deduplicated?)
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "rejects a dedup candidate from a different vault and cleans up", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    storage =
      storage(tmp_dir,
        dedup_lookup: fn _vault_id, domain_id, lookup_digest ->
          {:ok,
           %{
             vault_id: "00000000-0000-0000-0000-000000000099",
             encryption_domain_id: domain_id,
             object_ref: %ObjectRef{
               object_id: "00000000-0000-0000-0000-000000000009"
             },
             dek_wrapper: "foreign-wrapper",
             plaintext_byte_size: 4,
             ciphertext_byte_size: 999,
             ciphertext_hash: :binary.copy(<<42>>, 32),
             format_version: 1,
             lookup_digest: lookup_digest,
             lifecycle: :available
           }}
        end,
        destroy_dek_wrapper: fn wrapper ->
          send(parent, {:wrapper_destroyed, wrapper})
          :ok
        end
      )

    assert {:error, %Error{code: :invalid}, %_{}} =
             EncryptedStageWriter.stream_and_seal(storage, upload(4), ["four"])

    assert_received {:wrapper_destroyed, "wrapped-dek"}
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  test "rejects a same-scope dedup candidate with the wrong protected identity", %{
    tmp_dir: tmp_dir
  } do
    parent = self()

    storage =
      storage(tmp_dir,
        dedup_lookup: fn vault_id, domain_id, _lookup_digest ->
          {:ok,
           %{
             vault_id: vault_id,
             encryption_domain_id: domain_id,
             object_ref: %ObjectRef{
               object_id: "00000000-0000-0000-0000-000000000009"
             },
             dek_wrapper: "wrong-wrapper",
             plaintext_byte_size: 4,
             ciphertext_byte_size: 999,
             ciphertext_hash: :binary.copy(<<42>>, 32),
             format_version: 1,
             lookup_digest: :binary.copy(<<43>>, 32),
             lifecycle: :available
           }}
        end,
        destroy_dek_wrapper: fn wrapper ->
          send(parent, {:wrapper_destroyed, wrapper})
          :ok
        end
      )

    assert {:error, %Error{code: :invalid}, %_{}} =
             EncryptedStageWriter.stream_and_seal(storage, upload(4), ["four"])

    assert_received {:wrapper_destroyed, "wrapped-dek"}
    assert {:ok, []} = LocalFilesystemAdapter.list_staged(storage.context)
  end

  defp storage(root, overrides \\ []) do
    %{
      adapter: LocalFilesystemAdapter,
      context: %{root: root},
      dedup_lookup:
        Keyword.get(
          overrides,
          :dedup_lookup,
          fn _vault_id, _domain_id, _lookup_digest -> :miss end
        ),
      destroy_dek_wrapper: Keyword.get(overrides, :destroy_dek_wrapper, fn _wrapper -> :ok end)
    }
  end

  defp upload(expected_bytes) do
    %{
      vault_id: @vault_id,
      encryption_domain_id: @domain_id,
      object_id: @object_id,
      object_dek: :binary.copy(<<7>>, 32),
      domain_dedup_key: :binary.copy(<<8>>, 32),
      dek_wrapper: "wrapped-dek",
      expected_bytes: expected_bytes,
      max_bytes: expected_bytes + 1
    }
  end
end
