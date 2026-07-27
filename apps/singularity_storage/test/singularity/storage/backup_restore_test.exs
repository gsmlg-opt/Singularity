defmodule Singularity.Storage.BackupRestoreTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Backup.BundleWriter
  alias Singularity.Storage.Backup.Exporter
  alias Singularity.Storage.Backup.Manifest

  @database_record_type 0x0001
  @object_record_type 0xBEEF
  @manifest_record_type 0xFFFF
  @max_outer_bundle_bytes 4_295_032_856
  @max_public_prelude_bytes 65_560

  @vault_ids [
    "00000000-0000-0000-0000-000000000101",
    "00000000-0000-0000-0000-000000000102"
  ]
  @snapshot_id "00000000-0000-0000-0000-000000000201"
  @backup_id "00000000-0000-0000-0000-000000000301"
  @moduletag :tmp_dir

  defmodule RecordingCrypto do
    @moduledoc false

    @magic "TEST-BACKUP-AEAD-V2"
    @nonce_prefix_size 8
    @tag_size 16
    @final_counter 0xFFFFFFFF
    @final_metadata_size 44
    @manifest_record_type 0xFFFF

    def magic, do: @magic

    def start_link(owner, tmp_dir, key_source) do
      Agent.start_link(fn ->
        %{
          owner: owner,
          tmp_dir: tmp_dir,
          key: derive_key(key_source),
          streams: %{}
        }
      end)
    end

    def init_encrypt(capability, public_header) when is_pid(capability) do
      Agent.get_and_update(capability, fn state ->
        stream_ref = make_ref()
        nonce_prefix = :crypto.strong_rand_bytes(@nonce_prefix_size)
        header = <<@magic, nonce_prefix::binary>>

        stream = %{
          public_header: public_header,
          nonce_prefix: nonce_prefix,
          counter: 0,
          plaintext_bytes: 0,
          chunk_count: 0,
          plaintext_hash: :crypto.hash_init(:sha256),
          pending_plaintext: ""
        }

        notify(state, {:crypto, :init_encrypt, public_header, header})

        {{:ok, header, {capability, stream_ref}}, put_in(state, [:streams, stream_ref], stream)}
      end)
    end

    def encrypt_chunk({capability, stream_ref} = opaque_state, fragment)
        when is_pid(capability) and is_reference(stream_ref) and is_binary(fragment) and
               fragment != "" do
      Agent.get_and_update(capability, fn state ->
        stream = Map.fetch!(state.streams, stream_ref)

        updated_stream = %{
          stream
          | plaintext_bytes: stream.plaintext_bytes + byte_size(fragment),
            plaintext_hash: :crypto.hash_update(stream.plaintext_hash, fragment)
        }

        {encoded, next_stream} =
          case stream.pending_plaintext do
            "" ->
              {"", %{updated_stream | pending_plaintext: fragment}}

            pending ->
              encrypt_record(
                state.key,
                %{updated_stream | pending_plaintext: ""},
                pending <> fragment
              )
          end

        notify(state, {:crypto, :encrypt_chunk, fragment, encoded})

        {{:ok, encoded, opaque_state}, put_in(state, [:streams, stream_ref], next_stream)}
      end)
    end

    def finalize({capability, stream_ref}, manifest)
        when is_pid(capability) and is_reference(stream_ref) and is_map(manifest) do
      Agent.get_and_update(capability, fn state ->
        stream = Map.fetch!(state.streams, stream_ref)

        {pending_record, stream} =
          case stream.pending_plaintext do
            "" -> {"", stream}
            pending -> encrypt_record(state.key, %{stream | pending_plaintext: ""}, pending)
          end

        plaintext_sha256 = :crypto.hash_final(stream.plaintext_hash)

        metadata =
          <<stream.chunk_count::unsigned-big-32, stream.plaintext_bytes::unsigned-big-64,
            plaintext_sha256::binary>>

        {ciphertext, tag} =
          :crypto.crypto_one_time_aead(
            :aes_256_gcm,
            state.key,
            nonce(stream.nonce_prefix, @final_counter),
            metadata,
            final_aad(stream.public_header, manifest),
            @tag_size,
            true
          )

        final_record =
          <<@final_counter::unsigned-big-32, @final_metadata_size::unsigned-big-32,
            ciphertext::binary, tag::binary>>

        output = pending_record <> final_record

        summary = %{
          plaintext_bytes: stream.plaintext_bytes,
          chunk_count: stream.chunk_count,
          plaintext_sha256: plaintext_sha256,
          manifest_hash: manifest_hash!(manifest),
          manifest_tag: tag
        }

        notify(
          state,
          {:crypto, :finalize, manifest, output, summary, byte_size(pending_record)}
        )

        {{:ok, output, summary, :finalized},
         update_in(state.streams, &Map.delete(&1, stream_ref))}
      end)
    end

    def decrypt_all(capability, public_header, encoded)
        when is_pid(capability) and is_binary(encoded) do
      Agent.get(capability, fn state ->
        notify(state, {:crypto, :decrypt_all, byte_size(encoded)})

        with {:ok, plaintext} <- decrypt_stream(state.key, public_header, encoded),
             {:ok, manifest} <- manifest_from_plaintext(plaintext),
             true <- byte_size(encoded) >= @tag_size do
          tag = binary_part(encoded, byte_size(encoded) - @tag_size, @tag_size)

          {:ok, plaintext, %{manifest_hash: manifest_hash!(manifest), manifest_tag: tag}}
        else
          _invalid -> {:error, :integrity_failure}
        end
      end)
    end

    def seal_fixture(capability, public_header, manifest, plaintext)
        when is_pid(capability) and is_map(manifest) and is_binary(plaintext) and
               plaintext != "" do
      with {:ok, header, stream} <- init_encrypt(capability, public_header),
           {:ok, record, stream} <- encrypt_chunk(stream, plaintext),
           {:ok, tail, _summary, :finalized} <- finalize(stream, manifest) do
        {:ok, header <> record <> tail}
      end
    end

    defp decrypt_stream(
           key,
           public_header,
           <<@magic, nonce_prefix::binary-size(@nonce_prefix_size), records::binary>>
         ) do
      decrypt_records(records, key, public_header, nonce_prefix, 0, [], 0)
    rescue
      ArgumentError -> {:error, :integrity_failure}
    end

    defp decrypt_stream(_key, _public_header, _encoded),
      do: {:error, :integrity_failure}

    defp decrypt_records(
           <<@final_counter::unsigned-big-32, @final_metadata_size::unsigned-big-32,
             ciphertext::binary-size(@final_metadata_size), tag::binary-size(@tag_size)>>,
           key,
           public_header,
           nonce_prefix,
           expected_counter,
           plaintext,
           plaintext_bytes
         ) do
      decoded = plaintext |> Enum.reverse() |> IO.iodata_to_binary()

      with {:ok, manifest} <- manifest_from_plaintext(decoded),
           metadata when is_binary(metadata) <-
             :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               key,
               nonce(nonce_prefix, @final_counter),
               ciphertext,
               final_aad(public_header, manifest),
               tag,
               false
             ),
           <<^expected_counter::unsigned-big-32, ^plaintext_bytes::unsigned-big-64,
             expected_hash::binary-size(32)>> <- metadata,
           true <- :crypto.hash(:sha256, decoded) == expected_hash do
        {:ok, decoded}
      else
        _invalid -> {:error, :integrity_failure}
      end
    end

    defp decrypt_records(
           <<counter::unsigned-big-32, payload_length::unsigned-big-32,
             ciphertext::binary-size(payload_length), tag::binary-size(@tag_size), rest::binary>>,
           key,
           public_header,
           nonce_prefix,
           expected_counter,
           plaintext,
           plaintext_bytes
         )
         when counter == expected_counter and counter < @final_counter do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce(nonce_prefix, counter),
             ciphertext,
             data_aad(public_header, counter, payload_length),
             tag,
             false
           ) do
        decoded when is_binary(decoded) ->
          decrypt_records(
            rest,
            key,
            public_header,
            nonce_prefix,
            expected_counter + 1,
            [decoded | plaintext],
            plaintext_bytes + byte_size(decoded)
          )

        :error ->
          {:error, :integrity_failure}
      end
    end

    defp decrypt_records(
           _records,
           _key,
           _public_header,
           _nonce_prefix,
           _expected_counter,
           _plaintext,
           _plaintext_bytes
         ),
         do: {:error, :integrity_failure}

    defp derive_key({:passphrase, passphrase}) when is_binary(passphrase) do
      :crypto.hash(:sha256, "singularity:test:backup-kdf-v2:" <> passphrase)
    end

    defp derive_key({:fixed_byte, byte}) when byte in 0..255 do
      :binary.copy(<<byte>>, 32)
    end

    defp encrypt_record(key, stream, plaintext) do
      counter = stream.counter

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          nonce(stream.nonce_prefix, counter),
          plaintext,
          data_aad(stream.public_header, counter, byte_size(plaintext)),
          @tag_size,
          true
        )

      encoded =
        <<counter::unsigned-big-32, byte_size(plaintext)::unsigned-big-32, ciphertext::binary,
          tag::binary>>

      {encoded,
       %{
         stream
         | counter: counter + 1,
           chunk_count: stream.chunk_count + 1
       }}
    end

    defp nonce(prefix, counter), do: <<prefix::binary, counter::unsigned-big-32>>

    defp data_aad(public_header, counter, payload_length) do
      <<"TEST-BACKUP-DATA-V2", canonical_header(public_header)::binary, counter::unsigned-big-32,
        payload_length::unsigned-big-64>>
    end

    defp final_aad(public_header, manifest) do
      <<"TEST-BACKUP-FINAL-V2", canonical_term(public_header)::binary,
        canonical_term(manifest)::binary>>
    end

    defp canonical_header(public_header), do: canonical_term(public_header)

    defp canonical_term(term) do
      :erlang.term_to_binary(term, [:deterministic])
    end

    defp manifest_hash!(manifest) do
      {:ok, encoded} = Singularity.Storage.Backup.Manifest.encode(manifest)
      :crypto.hash(:sha256, encoded)
    end

    defp manifest_from_plaintext(plaintext) do
      with {:ok, frames} <- decode_frames(plaintext, []),
           [%{payload: encoded_manifest}] <-
             Enum.filter(frames, &(&1.type == @manifest_record_type)),
           {:ok, manifest} <-
             apply(Singularity.Storage.Backup.Manifest, :decode, [encoded_manifest]) do
        {:ok, manifest}
      else
        _invalid -> {:error, :integrity_failure}
      end
    end

    defp decode_frames("", frames), do: {:ok, Enum.reverse(frames)}

    defp decode_frames(
           <<type::unsigned-big-16, payload_length::unsigned-big-64,
             payload::binary-size(payload_length), rest::binary>>,
           frames
         ) do
      decode_frames(rest, [%{type: type, payload: payload} | frames])
    end

    defp decode_frames(_invalid, _frames), do: {:error, :integrity_failure}

    defp notify(state, event) do
      files = state.tmp_dir |> File.ls!() |> Enum.sort()
      send(state.owner, {:contract_event, event, files})
    end
  end

  defmodule RecordingFileSystem do
    @moduledoc false

    def new(owner, tmp_dir) do
      %{
        root: tmp_dir,
        open: fn path, modes ->
          with :ok <- allowed_path(path, tmp_dir) do
            result = File.open(path, modes)
            notify(owner, tmp_dir, {:file_system, :open, path, modes})
            result
          end
        end,
        write: fn device, bytes ->
          binary = IO.iodata_to_binary(bytes)
          result = IO.binwrite(device, binary)
          notify(owner, tmp_dir, {:file_system, :write, binary})
          result
        end,
        sync: fn device ->
          result = :file.sync(device)
          notify(owner, tmp_dir, {:file_system, :sync})
          result
        end,
        close: fn device ->
          result = File.close(device)
          notify(owner, tmp_dir, {:file_system, :close})
          result
        end,
        rename: fn source, destination ->
          with :ok <- allowed_path(source, tmp_dir),
               :ok <- allowed_path(destination, tmp_dir) do
            result = File.rename(source, destination)
            notify(owner, tmp_dir, {:file_system, :rename, source, destination})
            result
          end
        end,
        remove: fn path ->
          with :ok <- allowed_path(path, tmp_dir) do
            result = File.rm(path)
            notify(owner, tmp_dir, {:file_system, :remove, path})
            result
          end
        end,
        exists?: fn path ->
          with :ok <- allowed_path(path, tmp_dir) do
            File.exists?(path)
          end
        end,
        read: fn path, max_bytes ->
          with :ok <- allowed_path(path, tmp_dir) do
            result = File.read(path)
            notify(owner, tmp_dir, {:file_system, :read, path, max_bytes})
            result
          end
        end,
        read_prefix: fn path, max_bytes ->
          with :ok <- allowed_path(path, tmp_dir),
               {:ok, binary} <- File.read(path) do
            prefix = binary_part(binary, 0, min(byte_size(binary), max_bytes))
            notify(owner, tmp_dir, {:file_system, :read_prefix, path, max_bytes})
            {:ok, prefix}
          end
        end
      }
    end

    def source(file_system, path), do: %{file_system: file_system, path: path}

    defp allowed_path(path, tmp_dir) do
      expanded = Path.expand(path)
      root = Path.expand(tmp_dir) <> "/"

      if String.starts_with?(expanded, root), do: :ok, else: {:error, :outside_test_root}
    end

    defp notify(owner, tmp_dir, event) do
      files = tmp_dir |> File.ls!() |> Enum.sort()
      send(owner, {:contract_event, event, files})
    end
  end

  defmodule EvidenceCrypto do
    @moduledoc false

    def decrypt_all({capability, mutation}, public_header, encrypted) do
      with {:ok, plaintext, evidence} <-
             Singularity.Storage.BackupRestoreTest.RecordingCrypto.decrypt_all(
               capability,
               public_header,
               encrypted
             ) do
        {:ok, plaintext, mutate(evidence, mutation)}
      end
    end

    defp mutate(evidence, :missing_hash), do: Map.delete(evidence, :manifest_hash)
    defp mutate(evidence, :nil_hash), do: Map.put(evidence, :manifest_hash, nil)
    defp mutate(evidence, :wrong_hash), do: Map.put(evidence, :manifest_hash, <<0::256>>)
    defp mutate(evidence, :wrong_tag), do: Map.put(evidence, :manifest_tag, <<0::128>>)
  end

  defmodule FailingObjectStorage do
    @moduledoc false

    alias Singularity.Core.ObjectRef

    def open(
          %{failure: :open_error, error: error, observer: observer},
          %ObjectRef{} = object_ref
        ) do
      send(observer, {:object_storage, :open, object_ref})
      {:error, error}
    end

    def open(%{failure: :open_unexpected, observer: observer}, %ObjectRef{} = object_ref) do
      send(observer, {:object_storage, :open, object_ref})
      :unexpected
    end

    def open(%{observer: observer}, %ObjectRef{object_id: object_id} = object_ref) do
      send(observer, {:object_storage, :open, object_ref})
      {:ok, object_id}
    end

    def read_range(
          %{failure: :read_error, error: error, observer: observer},
          object_id,
          range
        ) do
      send(observer, {:object_storage, :read_range, object_id, range})
      {:error, error}
    end

    def read_range(%{failure: :read_raise, observer: observer}, object_id, range) do
      send(observer, {:object_storage, :read_range, object_id, range})
      raise "object storage read failed"
    end

    def read_range(%{failure: :premature_eof, observer: observer}, object_id, range) do
      send(observer, {:object_storage, :read_range, object_id, range})
      {:ok, ""}
    end

    def read_range(%{bytes: bytes, observer: observer}, object_id, %Range{} = range) do
      send(observer, {:object_storage, :read_range, object_id, range})
      first = range.first

      if first >= byte_size(bytes) do
        {:ok, ""}
      else
        length = min(range.last - first + 1, byte_size(bytes) - first)
        {:ok, binary_part(bytes, first, length)}
      end
    end
  end

  test "manifest is versioned and preserves the exact ordered inventory and hashes" do
    records = records_fixture()
    attrs = manifest_attrs(records)

    assert {:ok, manifest} = call(Manifest, :new, [attrs])

    assert Map.take(manifest, [
             :version,
             :manifest_id,
             :vault_ids,
             :snapshot_id,
             :outbox_high_water_mark,
             :recovery,
             :inventory
           ]) == attrs

    assert {:ok, encoded} = call(Manifest, :encode, [manifest])
    assert {:ok, decoded} = call(Manifest, :decode, [encoded])
    assert decoded == manifest
    assert :ok = call(Manifest, :verify, [decoded, materialized_records(records)])
  end

  test "manifest decode rejects trailing bytes" do
    manifest = new_manifest!(records_fixture())
    assert {:ok, encoded} = call(Manifest, :encode, [manifest])

    encoded
    |> Kernel.<>("trailing")
    |> then(&call(Manifest, :decode, [&1]))
    |> assert_safe_backup_invalid("trailing manifest bytes")
  end

  test "manifest decode rejects compressed ETF before canonical verification" do
    manifest = new_manifest!(records_fixture())
    assert {:ok, canonical} = call(Manifest, :encode, [manifest])
    wire = :erlang.binary_to_term(canonical, [:safe])
    compressed = :erlang.term_to_binary(wire, compressed: 9)

    assert <<131, 80, _rest::binary>> = compressed
    assert_safe_backup_invalid(Manifest.decode(compressed), "compressed manifest ETF")
  end

  test "manifest rejects every missing or malformed consistency field" do
    attrs = manifest_attrs(records_fixture())
    [first, second] = attrs.inventory

    invalid_manifests = [
      {"missing version", &Map.delete(&1, :version)},
      {"zero version", &Map.put(&1, :version, 0)},
      {"unknown version", &Map.put(&1, :version, 2)},
      {"noninteger version", &Map.put(&1, :version, "1")},
      {"missing manifest ID", &Map.delete(&1, :manifest_id)},
      {"malformed manifest ID", &Map.put(&1, :manifest_id, "not-a-uuid")},
      {"missing vault IDs", &Map.delete(&1, :vault_ids)},
      {"empty vault IDs", &Map.put(&1, :vault_ids, [])},
      {"malformed vault ID", &Map.put(&1, :vault_ids, ["not-a-uuid"])},
      {"duplicate vault IDs", &Map.put(&1, :vault_ids, [hd(@vault_ids), hd(@vault_ids)])},
      {"missing snapshot ID", &Map.delete(&1, :snapshot_id)},
      {"malformed snapshot ID", &Map.put(&1, :snapshot_id, "not-a-uuid")},
      {"missing outbox cut", &Map.delete(&1, :outbox_high_water_mark)},
      {"negative outbox cut", &Map.put(&1, :outbox_high_water_mark, -1)},
      {"noninteger outbox cut", &Map.put(&1, :outbox_high_water_mark, "42")},
      {"missing recovery metadata", &Map.delete(&1, :recovery)},
      {"wrong recovery label", &put_in(&1, [:recovery, "label"], "vault_key")},
      {"mismatched recovery manifest",
       &put_in(&1, [:recovery, "binding", "manifest_id"], Ecto.UUID.generate())},
      {"recovery vault outside manifest",
       &put_in(&1, [:recovery, "binding", "vault_id"], Ecto.UUID.generate())},
      {"missing inventory", &Map.delete(&1, :inventory)},
      {"missing inventory position",
       &Map.put(&1, :inventory, [Map.delete(first, :position), second])},
      {"negative inventory position",
       &Map.put(&1, :inventory, [%{first | position: -1}, second])},
      {"noninteger inventory position",
       &Map.put(&1, :inventory, [%{first | position: "0"}, second])},
      {"nonzero-start inventory positions",
       &Map.put(&1, :inventory, [%{first | position: 1}, %{second | position: 2}])},
      {"gapped inventory positions", &Map.put(&1, :inventory, [first, %{second | position: 2}])},
      {"nonordered inventory positions",
       &Map.put(&1, :inventory, [%{first | position: 1}, %{second | position: 0}])},
      {"duplicate inventory positions",
       &Map.put(&1, :inventory, [first, %{second | position: 0}])},
      {"missing record type",
       &Map.put(&1, :inventory, [Map.delete(first, :record_type), second])},
      {"negative record type", &Map.put(&1, :inventory, [%{first | record_type: -1}, second])},
      {"noninteger record type", &Map.put(&1, :inventory, [%{first | record_type: "1"}, second])},
      {"record type above u16",
       &Map.put(&1, :inventory, [%{first | record_type: 0x10000}, second])},
      {"reserved manifest record type",
       &Map.put(&1, :inventory, [%{first | record_type: @manifest_record_type}, second])},
      {"missing payload length",
       &Map.put(&1, :inventory, [Map.delete(first, :payload_length), second])},
      {"negative payload length",
       &Map.put(&1, :inventory, [%{first | payload_length: -1}, second])},
      {"noninteger payload length",
       &Map.put(&1, :inventory, [%{first | payload_length: "26"}, second])},
      {"missing hash", &Map.put(&1, :inventory, [Map.delete(first, :sha256), second])},
      {"31-byte hash",
       &Map.put(&1, :inventory, [%{first | sha256: :binary.copy(<<0>>, 31)}, second])},
      {"33-byte hash",
       &Map.put(&1, :inventory, [%{first | sha256: :binary.copy(<<0>>, 33)}, second])}
    ]

    for {label, mutate} <- invalid_manifests do
      attrs
      |> mutate.()
      |> then(&call(Manifest, :new, [&1]))
      |> assert_safe_backup_invalid(label)
    end
  end

  test "writer uses unsigned big-endian 16-bit types and 64-bit payload lengths and puts the manifest last",
       context do
    records = records_fixture()
    manifest = new_manifest!(records)

    write_bundle!(context, records, manifest)
    events = recorded_contract_events()
    plaintext = recorded_plaintext(events)

    expected =
      records
      |> materialized_records()
      |> Kernel.++([manifest_record!(manifest)])
      |> encode_frames()

    assert plaintext == expected

    assert <<@database_record_type::unsigned-big-16, 26::unsigned-big-64,
             "database-logical-export-v1", @object_record_type::unsigned-big-16,
             30::unsigned-big-64, "immutable-object-ciphertext-v1",
             @manifest_record_type::unsigned-big-16, _manifest_size::unsigned-big-64,
             _manifest_payload::binary>> = plaintext

    assert {:ok, frames} = split_frames(plaintext)
    assert Enum.map(frames, & &1.type) == record_types(records) ++ [@manifest_record_type]

    assert %{type: @manifest_record_type, payload: encoded_manifest} = List.last(frames)
    assert {:ok, decoded_manifest} = call(Manifest, :decode, [encoded_manifest])
    assert decoded_manifest == manifest
    assert Map.fetch!(decoded_manifest, :version) == 1
  end

  test "writer tolerates empty crypto output and writes emitted records before pulling again",
       context do
    chunks = ["first-stream-chunk", "second-stream-chunk", "third-stream-chunk"]
    payload = IO.iodata_to_binary(chunks)

    records = [
      %{
        type: @database_record_type,
        payload_length: byte_size(payload),
        payload:
          Stream.map(chunks, fn chunk ->
            snapshot_event(context, {:source, chunk})
            chunk
          end)
      }
    ]

    manifest = new_manifest_from_binaries!([{@database_record_type, payload}])
    write_bundle!(context, records, manifest)

    events = recorded_contract_events() |> Enum.map(&elem(&1, 0))

    assert {:crypto, :init_encrypt, _public_header, header} =
             Enum.find(events, &match?({:crypto, :init_encrypt, _, _}, &1))

    assert header != ""

    source_results =
      for chunk <- chunks do
        source_index = event_index!(events, &(&1 == {:source, chunk}))

        crypto_index =
          event_index!(events, &crypto_plaintext_equals?(&1, chunk))

        {:crypto, :encrypt_chunk, ^chunk, ciphertext} = Enum.at(events, crypto_index)

        assert source_index < crypto_index

        write_index =
          if ciphertext == "" do
            nil
          else
            refute :binary.match(ciphertext, chunk) != :nomatch
            index = event_index!(events, &(&1 == {:file_system, :write, ciphertext}))
            assert crypto_index < index
            index
          end

        {chunk, ciphertext, write_index}
      end

    assert Enum.any?(source_results, fn {_chunk, output, _write_index} -> output == "" end)
    assert Enum.any?(source_results, fn {_chunk, output, _write_index} -> output != "" end)
    refute Enum.any?(events, &(&1 == {:file_system, :write, ""}))

    for {{_chunk, _output, write_index}, next_chunk} <- Enum.zip(source_results, tl(chunks)),
        is_integer(write_index) do
      assert write_index < event_index!(events, &(&1 == {:source, next_chunk}))
    end

    assert {:crypto, :finalize, ^manifest, final_output, _summary, pending_record_bytes} =
             Enum.find(events, &match?({:crypto, :finalize, _, _, _, _}, &1))

    assert final_output != ""
    assert byte_size(final_output) == pending_record_bytes + 4 + 4 + 44 + 16
    assert Enum.any?(events, &(&1 == {:file_system, :write, final_output}))
  end

  test "writer rejects a declared payload overrun before encrypting the extra fragment",
       context do
    declared = "declared"
    overflow = "must-not-be-encrypted"

    records = [
      %{
        type: @database_record_type,
        payload_length: byte_size(declared),
        payload:
          Stream.map([declared, overflow], fn fragment ->
            snapshot_event(context, {:source, fragment})
            fragment
          end)
      }
    ]

    manifest = new_manifest_from_binaries!([{@database_record_type, declared}])

    assert {:error, %Error{code: :backup_invalid}} =
             call(BundleWriter, :stream, [
               bundle_source(context),
               records,
               [],
               manifest,
               %{
                 adapter: RecordingCrypto,
                 capability: context.crypto_capability,
                 public_header: context.public_header
               }
             ])

    events = recorded_contract_events() |> Enum.map(&elem(&1, 0))
    assert {:source, overflow} in events
    refute Enum.any?(events, &crypto_plaintext_equals?(&1, overflow))
    assert_failed_bundle_cleaned(context)
  end

  test "the injected filesystem observes every event and only an encrypted partial and final bundle",
       context do
    record_binaries = record_binaries_fixture()
    records = tracked_records(context, record_binaries)
    manifest = new_manifest_from_binaries!(record_binaries)

    sealed = write_bundle!(context, records, manifest)
    events = recorded_contract_events()

    destination = context.destination
    partial_name = Path.basename(destination <> ".partial")
    final_name = Path.basename(destination)
    allowed_names = [partial_name, final_name]

    assert Enum.any?(events, &match?({{:source, _chunk}, _files}, &1))
    assert Enum.any?(events, &match?({{:crypto, :encrypt_chunk, _, _}, _files}, &1))
    assert Enum.any?(events, &match?({{:file_system, :write, _}, _files}, &1))

    for {_event, files} <- events do
      assert Enum.all?(files, &(&1 in allowed_names)),
             "transient untracked sidecar observed: #{inspect(files)}"

      refute Enum.any?(files, fn name ->
               name =~ ~r/\.(?:tar|sql|json|key|object)(?:\.|$)/i
             end)
    end

    touched_paths = recorded_file_paths(events)
    allowed_paths = [destination <> ".partial", destination]
    assert Enum.sort(Enum.uniq(touched_paths)) == Enum.sort(allowed_paths)

    assert File.ls!(context.tmp_dir) == [final_name]
    assert File.regular?(destination)
    refute File.exists?(destination <> ".partial")

    encrypted_bundle = File.read!(destination)
    assert encrypted_bundle != ""

    assert {:ok, encoded_manifest} = Manifest.encode(manifest)

    assert sealed == %{
             destination_ref: destination,
             path: destination,
             manifest_id: manifest.manifest_id,
             inventory: manifest.inventory,
             manifest_hash: :crypto.hash(:sha256, encoded_manifest),
             manifest_tag: binary_part(encrypted_bundle, byte_size(encrypted_bundle) - 16, 16)
           }

    writes = recorded_file_writes(events)
    assert writes != []
    assert Enum.all?(writes, &(&1 != ""))

    transcript = IO.iodata_to_binary(writes)
    crypto_transcript = events |> recorded_crypto_outputs() |> IO.iodata_to_binary()
    prelude_size = byte_size(transcript) - byte_size(crypto_transcript)

    assert prelude_size > 0

    assert <<encoded_public_prelude::binary-size(prelude_size), encrypted::binary>> =
             transcript

    assert encoded_public_prelude != ""
    assert encrypted == crypto_transcript
    assert encrypted_bundle == encoded_public_prelude <> crypto_transcript

    expected_public_header = context.public_header

    assert {:ok, ^expected_public_header} =
             call(BundleReader, :read_public_header, [bundle_source(context)])

    plaintext_fragments =
      Enum.flat_map(record_binaries, fn {_type, payload} -> split_payload(payload) end)

    secrets =
      plaintext_fragments ++
        [context.passphrase, elem(call(Manifest, :encode, [manifest]), 1)]

    for secret <- secrets do
      refute :binary.match(transcript, secret) != :nomatch
      Enum.each(writes, &refute_secret(&1, secret))
    end
  end

  test "writer preserves a typed object open error and removes the partial bundle", context do
    expected =
      Error.new(:not_found,
        message: "object missing from storage",
        details: %{storage_ref: "opaque/missing"}
      )

    assert {:error, ^expected} = write_exported_bundle(context, :open_error, expected)
    assert_failed_bundle_cleaned(context)
  end

  test "writer preserves a typed object read error and removes the partial bundle", context do
    expected =
      Error.new(:storage_unavailable,
        message: "range read unavailable",
        details: %{attempt: 2},
        retryable?: true
      )

    assert {:error, ^expected} = write_exported_bundle(context, :read_error, expected)
    assert_failed_bundle_cleaned(context)
  end

  test "writer reports premature object EOF as an integrity failure and removes the partial bundle",
       context do
    assert {:error, %Error{code: :integrity_failure, retryable?: false}} =
             write_exported_bundle(context, :premature_eof)

    assert_failed_bundle_cleaned(context)
  end

  test "writer maps unexpected object storage results and exceptions to retryable unavailability",
       context do
    for failure <- [:open_unexpected, :read_raise] do
      assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
               write_exported_bundle(context, failure)

      assert_failed_bundle_cleaned(context)
    end
  end

  test "reader uses the injected filesystem, authenticates all, then streams verified records",
       context do
    records = records_fixture()
    manifest = new_manifest!(records)
    write_bundle!(context, records, manifest)
    _writer_events = recorded_contract_events()

    source = bundle_source(context)

    assert {:ok, public_header} = call(BundleReader, :read_public_header, [source])
    assert public_header == context.public_header

    header_events = recorded_contract_events()
    assert_reader_used_file_system(header_events)
    assert_prefix_reader(header_events)

    assert {:ok, verified} =
             call(BundleReader, :authenticate_all, [
               source,
               [crypto: {RecordingCrypto, context.crypto_capability}]
             ])

    reader_events = recorded_contract_events()

    assert_reader_used_file_system(reader_events)
    assert_bounded_reader(reader_events)

    assert Enum.any?(reader_events, &match?({{:crypto, :decrypt_all, _bytes}, _files}, &1))
    assert Map.fetch!(verified, :manifest) == manifest
    assert {:ok, encoded_manifest} = Manifest.encode(manifest)
    assert verified.manifest_hash == :crypto.hash(:sha256, encoded_manifest)

    encrypted_bundle = File.read!(context.destination)

    assert verified.manifest_tag ==
             binary_part(encrypted_bundle, byte_size(encrypted_bundle) - 16, 16)

    refute_received {:consumer, _record}

    assert :ok = call(BundleReader, :stream_verified, [verified, consumer(self())])

    assert_receive {:consumer,
                    %{type: @database_record_type, payload: "database-logical-export-v1"}}

    assert_receive {:consumer,
                    %{
                      type: @object_record_type,
                      payload: "immutable-object-ciphertext-v1"
                    }}

    refute_received {:consumer, %{type: @manifest_record_type}}
  end

  test "writer reserves one logical frame for the authenticated manifest" do
    assert BundleWriter.valid_frame_count?(999_999)
    refute BundleWriter.valid_frame_count?(1_000_000)
    refute BundleWriter.valid_frame_count?(-1)
  end

  test "wrong key and wrong passphrase fail authenticate_all before any consumer", context do
    records = records_fixture()
    manifest = new_manifest!(records)
    write_bundle!(context, records, manifest)

    wrong_key_capability = crypto_capability!(context, {:fixed_byte, 99})
    wrong_passphrase = "definitely not the operator passphrase"

    wrong_passphrase_capability =
      crypto_capability!(context, {:passphrase, wrong_passphrase})

    assert_authentication_rejected(
      bundle_source(context),
      wrong_key_capability,
      []
    )

    assert_authentication_rejected(
      bundle_source(context),
      wrong_passphrase_capability,
      [wrong_passphrase]
    )
  end

  test "missing or mismatched authenticated manifest evidence fails before any consumer",
       context do
    records = records_fixture()
    manifest = new_manifest!(records)
    write_bundle!(context, records, manifest)

    for mutation <- [:missing_hash, :nil_hash, :wrong_hash, :wrong_tag] do
      assert_safe_backup_invalid(
        call(BundleReader, :authenticate_all, [
          bundle_source(context),
          [crypto: {EvidenceCrypto, {context.crypto_capability, mutation}}]
        ]),
        "manifest evidence rejection"
      )

      refute_received {:consumer, _record}
    end
  end

  test "noncanonical public-header bytes are rejected before authentication", context do
    records = records_fixture()
    manifest = new_manifest!(records)
    write_bundle!(context, records, manifest)

    encoded = File.read!(context.destination)

    <<"SINGULARITY-BACKUP", 1::unsigned-big-16, header_size::unsigned-big-32, rest::binary>> =
      encoded

    <<_canonical_header::binary-size(header_size), encrypted::binary>> = rest
    noncanonical_header = :erlang.term_to_binary(context.public_header)
    canonical_header = :erlang.term_to_binary(context.public_header, [:deterministic])
    refute noncanonical_header == canonical_header

    File.write!(
      context.destination,
      <<"SINGULARITY-BACKUP", 1::unsigned-big-16, byte_size(noncanonical_header)::unsigned-big-32,
        noncanonical_header::binary, encrypted::binary>>
    )

    assert_safe_backup_invalid(
      call(BundleReader, :read_public_header, [bundle_source(context)]),
      "noncanonical public header"
    )

    assert_authentication_rejected(
      bundle_source(context),
      context.crypto_capability,
      []
    )
  end

  test "truncation fails authenticate_all before any consumer", context do
    records = records_fixture()
    manifest = new_manifest!(records)
    write_bundle!(context, records, manifest)

    encoded = File.read!(context.destination)
    File.write!(context.destination, binary_part(encoded, 0, byte_size(encoded) - 7))

    assert_authentication_rejected(
      bundle_source(context),
      context.crypto_capability,
      [encoded]
    )
  end

  test "record reordering and a non-final manifest fail authenticate_all before any consumer",
       context do
    mutations = [
      fn [first, second | rest] -> [second, first | rest] end,
      fn frames ->
        {manifest_frame, data_frames} = List.pop_at(frames, -1)
        [manifest_frame | data_frames]
      end
    ]

    for {mutation, index} <- Enum.with_index(mutations) do
      destination = Path.join(context.tmp_dir, "reordered-#{index}.bundle")
      records = records_fixture()
      manifest = new_manifest!(records)

      write_bundle!(%{context | destination: destination}, records, manifest)

      rewrite_authenticated_frames!(
        destination,
        context.public_header,
        context.crypto_capability,
        mutation
      )

      assert_authentication_rejected(
        bundle_source(context, destination),
        context.crypto_capability,
        []
      )
    end
  end

  test "every authenticated inventory-field alteration fails authenticate_all", context do
    mutations = [
      fn [first, second] -> [%{second | position: 0}, %{first | position: 1}] end,
      fn [first | rest] -> [%{first | record_type: @database_record_type + 1} | rest] end,
      fn [first | rest] -> [%{first | payload_length: first.payload_length + 1} | rest] end,
      fn [first | rest] -> [Map.update!(first, :sha256, &flip_first_byte/1) | rest] end
    ]

    for {mutate_inventory, index} <- Enum.with_index(mutations) do
      destination = Path.join(context.tmp_dir, "altered-inventory-#{index}.bundle")
      records = records_fixture()
      manifest = new_manifest!(records)
      write_bundle!(%{context | destination: destination}, records, manifest)

      rewrite_authenticated_frames!(
        destination,
        context.public_header,
        context.crypto_capability,
        fn frames ->
          {manifest_frame, data_frames} = List.pop_at(frames, -1)
          assert manifest_frame.type == @manifest_record_type

          assert {:ok, decoded} = call(Manifest, :decode, [manifest_frame.payload])
          altered = Map.update!(decoded, :inventory, mutate_inventory)
          assert {:ok, encoded} = call(Manifest, :encode, [altered])

          data_frames ++ [%{manifest_frame | payload: encoded}]
        end
      )

      assert_authentication_rejected(
        bundle_source(context, destination),
        context.crypto_capability,
        []
      )
    end
  end

  test "an authenticated but noncanonical manifest fails before records are exposed", context do
    records = records_fixture()
    manifest = new_manifest!(records)
    write_bundle!(context, records, manifest)

    rewrite_authenticated_frames!(
      context.destination,
      context.public_header,
      context.crypto_capability,
      fn frames ->
        {manifest_frame, data_frames} = List.pop_at(frames, -1)
        noncanonical = noncanonical_manifest!(manifest_frame.payload)
        assert {:ok, ^manifest} = Manifest.decode(noncanonical)
        refute noncanonical == manifest_frame.payload
        data_frames ++ [%{manifest_frame | payload: noncanonical}]
      end
    )

    assert_authentication_rejected(
      bundle_source(context),
      context.crypto_capability,
      []
    )
  end

  setup %{tmp_dir: tmp_dir} do
    passphrase = "correct operator backup passphrase"
    owner = self()
    file_system = RecordingFileSystem.new(owner, tmp_dir)

    context = %{
      owner: owner,
      tmp_dir: tmp_dir,
      destination: Path.join(tmp_dir, "vault.bundle"),
      passphrase: passphrase,
      public_header: %{
        version: 1,
        manifest_id: @backup_id,
        kdf: %{
          "domain" => "singularity.backup.bundle.v1",
          "parameters" => %{
            "m_cost" => 65_536,
            "parallelism" => 1,
            "t_cost" => 3,
            "version" => 1
          },
          "salt" => Base.encode64(<<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>)
        }
      },
      file_system: file_system
    }

    {:ok,
     Map.put(
       context,
       :crypto_capability,
       crypto_capability!(context, {:passphrase, passphrase})
     )}
  end

  defp crypto_capability!(context, key_source) do
    assert {:ok, capability} =
             RecordingCrypto.start_link(context.owner, context.tmp_dir, key_source)

    assert is_pid(capability)

    on_exit(fn ->
      if Process.alive?(capability), do: Agent.stop(capability)
    end)

    capability
  end

  defp write_bundle!(context, records, manifest) do
    assert is_pid(context.crypto_capability)

    assert {:ok, bundle} =
             call(BundleWriter, :stream, [
               bundle_source(context),
               records,
               [],
               manifest,
               %{
                 adapter: RecordingCrypto,
                 capability: context.crypto_capability,
                 public_header: context.public_header
               }
             ])

    bundle
  end

  defp write_exported_bundle(context, failure, error \\ nil) do
    bytes = "immutable object ciphertext"
    vault_id = hd(@vault_ids)
    storage_ref = "opaque/storage/#{Ecto.UUID.generate()}"

    cut = %{
      object_inventory: [
        %{
          asset_object_id: Ecto.UUID.generate(),
          vault_id: vault_id,
          key_domain_id: Ecto.UUID.generate(),
          classification: :private,
          lookup_digest: :crypto.strong_rand_bytes(32),
          storage_ref: storage_ref,
          ciphertext_byte_size: byte_size(bytes),
          ciphertext_hash: :crypto.hash(:sha256, bytes),
          inventory_position: 0
        }
      ],
      vault_id: vault_id
    }

    storage_context = %{
      bytes: bytes,
      error: error,
      failure: failure,
      observer: context.owner
    }

    assert {:ok, %{records: records, inventory: inventory}} =
             Exporter.stream_inventory({FailingObjectStorage, storage_context}, cut)

    manifest = manifest_from_inventory!(inventory)

    BundleWriter.stream(
      bundle_source(context),
      [],
      records,
      manifest,
      %{
        adapter: RecordingCrypto,
        capability: context.crypto_capability,
        public_header: context.public_header
      }
    )
  end

  defp manifest_from_inventory!(inventory) do
    inventory =
      inventory
      |> Enum.with_index()
      |> Enum.map(fn {entry, position} -> Map.put(entry, :position, position) end)

    attrs = Map.put(manifest_attrs([]), :inventory, inventory)
    assert {:ok, manifest} = Manifest.new(attrs)
    manifest
  end

  defp assert_failed_bundle_cleaned(context) do
    refute File.exists?(context.destination)
    refute File.exists?(context.destination <> ".partial")
    assert File.ls!(context.tmp_dir) == []
  end

  defp assert_authentication_rejected(source, capability, secrets) do
    result =
      call(BundleReader, :authenticate_all, [
        source,
        [crypto: {RecordingCrypto, capability}]
      ])

    error = assert_safe_backup_invalid(result, "authenticate_all corruption rejection")
    rendered = inspect(error)
    Enum.each(secrets, &refute_secret(rendered, &1))

    refute_received {:consumer, _record}
    refute_received {:importer, _record}
  end

  defp assert_safe_backup_invalid(result, label) do
    assert match?(
             {:error,
              %Error{
                code: :backup_invalid,
                message: nil,
                details: %{},
                retryable?: false
              }},
             result
           ),
           "#{label}: expected safe backup_invalid, got #{inspect(result)}"

    {:error, error} = result
    error
  end

  defp consumer(owner) do
    fn record ->
      normalized = %{
        type: Map.fetch!(record, :type),
        payload: record |> Map.fetch!(:payload) |> payload_binary()
      }

      send(owner, {:consumer, normalized})
      :ok
    end
  end

  defp record_binaries_fixture do
    [
      {@database_record_type, "database-logical-export-v1"},
      {@object_record_type, "immutable-object-ciphertext-v1"}
    ]
  end

  defp records_fixture, do: records_from_binaries(record_binaries_fixture())

  defp tracked_records(context, records) do
    Enum.map(records, fn {type, payload} ->
      %{
        type: type,
        payload_length: byte_size(payload),
        payload:
          payload
          |> split_payload()
          |> Stream.map(fn chunk ->
            snapshot_event(context, {:source, chunk})
            chunk
          end)
      }
    end)
  end

  defp records_from_binaries(records) do
    Enum.map(records, fn {type, payload} ->
      %{
        type: type,
        payload_length: byte_size(payload),
        payload: split_payload(payload)
      }
    end)
  end

  defp split_payload(payload) do
    midpoint = max(div(byte_size(payload), 2), 1)
    <<first::binary-size(midpoint), second::binary>> = payload
    [first, second]
  end

  defp new_manifest!(records) do
    assert {:ok, manifest} = call(Manifest, :new, [manifest_attrs(records)])
    manifest
  end

  defp new_manifest_from_binaries!(records) do
    records
    |> records_from_binaries()
    |> new_manifest!()
  end

  defp manifest_attrs(records) do
    %{
      version: 1,
      manifest_id: @backup_id,
      vault_ids: @vault_ids,
      snapshot_id: @snapshot_id,
      outbox_high_water_mark: 42,
      recovery: %{
        "binding" => %{
          "manifest_id" => @backup_id,
          "vault_id" => hd(@vault_ids)
        },
        "label" => "backup_recovery",
        "wrapper" => "authenticated-recovery-wrapper"
      },
      inventory:
        records
        |> materialized_records()
        |> Enum.with_index()
        |> Enum.map(fn {%{type: type, payload: payload}, position} ->
          %{
            position: position,
            record_type: type,
            payload_length: byte_size(payload),
            sha256: :crypto.hash(:sha256, payload)
          }
        end)
    }
  end

  defp materialized_records(records) do
    Enum.map(records, fn record ->
      %{
        type: Map.fetch!(record, :type),
        payload: record |> Map.fetch!(:payload) |> payload_binary()
      }
    end)
  end

  defp manifest_record!(manifest) do
    assert {:ok, payload} = call(Manifest, :encode, [manifest])
    %{type: @manifest_record_type, payload: payload}
  end

  defp encode_frames(frames) do
    frames
    |> Enum.map(fn %{type: type, payload: payload} ->
      <<type::unsigned-big-16, byte_size(payload)::unsigned-big-64, payload::binary>>
    end)
    |> IO.iodata_to_binary()
  end

  defp split_frames(binary), do: split_frames(binary, [])

  defp split_frames("", frames), do: {:ok, Enum.reverse(frames)}

  defp split_frames(
         <<type::unsigned-big-16, payload_length::unsigned-big-64,
           payload::binary-size(payload_length), rest::binary>>,
         frames
       ) do
    split_frames(rest, [%{type: type, payload: payload} | frames])
  end

  defp split_frames(_invalid, _frames), do: {:error, :invalid_frame}

  defp rewrite_authenticated_frames!(path, public_header, capability, rewrite) do
    encoded = File.read!(path)
    {offset, _magic_size} = :binary.match(encoded, RecordingCrypto.magic())
    prefix = binary_part(encoded, 0, offset)
    encrypted = binary_part(encoded, offset, byte_size(encoded) - offset)

    assert {:ok, plaintext, _evidence} =
             RecordingCrypto.decrypt_all(capability, public_header, encrypted)

    assert {:ok, frames} = split_frames(plaintext)

    rewritten_frames = rewrite.(frames)

    assert [%{payload: encoded_manifest}] =
             Enum.filter(rewritten_frames, &(&1.type == @manifest_record_type))

    assert {:ok, manifest} = call(Manifest, :decode, [encoded_manifest])
    rewritten = encode_frames(rewritten_frames)

    assert {:ok, sealed} =
             RecordingCrypto.seal_fixture(capability, public_header, manifest, rewritten)

    File.write!(path, prefix <> sealed)
  end

  defp bundle_source(context, path \\ nil) do
    RecordingFileSystem.source(context.file_system, path || context.destination)
  end

  defp snapshot_event(context, event) do
    files = context.tmp_dir |> File.ls!() |> Enum.sort()
    send(context.owner, {:contract_event, event, files})
  end

  defp recorded_contract_events, do: receive_contract_events([]) |> Enum.reverse()

  defp receive_contract_events(events) do
    receive do
      {:contract_event, event, files} ->
        receive_contract_events([{event, files} | events])
    after
      0 -> events
    end
  end

  defp recorded_plaintext(events) do
    events
    |> Enum.flat_map(fn
      {{:crypto, :encrypt_chunk, plaintext, _ciphertext}, _files} -> [plaintext]
      _event -> []
    end)
    |> IO.iodata_to_binary()
  end

  defp recorded_file_paths(events) do
    events
    |> Enum.flat_map(fn
      {{:file_system, :open, path, _modes}, _files} -> [path]
      {{:file_system, :rename, source, destination}, _files} -> [source, destination]
      {{:file_system, :remove, path}, _files} -> [path]
      {{:file_system, :read, path, _max_bytes}, _files} -> [path]
      {{:file_system, :read_prefix, path, _max_bytes}, _files} -> [path]
      _event -> []
    end)
  end

  defp recorded_file_writes(events) do
    Enum.flat_map(events, fn
      {{:file_system, :write, bytes}, _files} -> [bytes]
      _event -> []
    end)
  end

  defp recorded_crypto_outputs(events) do
    Enum.flat_map(events, fn
      {{:crypto, :init_encrypt, _public_header, header}, _files} -> [header]
      {{:crypto, :encrypt_chunk, _plaintext, ""}, _files} -> []
      {{:crypto, :encrypt_chunk, _plaintext, output}, _files} -> [output]
      {{:crypto, :finalize, _manifest, output, _summary, _pending_bytes}, _files} -> [output]
      _event -> []
    end)
  end

  defp assert_reader_used_file_system(events) do
    assert Enum.any?(events, fn
             {{:file_system, :read, _path, _max_bytes}, _files} -> true
             {{:file_system, :read_prefix, _path, _max_bytes}, _files} -> true
             {{:file_system, :open, _path, _modes}, _files} -> true
             _other -> false
           end)
  end

  defp assert_bounded_reader(events) do
    assert Enum.any?(events, fn
             {{:file_system, :read, _path, @max_outer_bundle_bytes}, _files} -> true
             _other -> false
           end)
  end

  defp assert_prefix_reader(events) do
    assert Enum.any?(events, fn
             {{:file_system, :read_prefix, _path, @max_public_prelude_bytes}, _files} -> true
             _other -> false
           end)

    refute Enum.any?(events, fn
             {{:file_system, :read, _path, _max_bytes}, _files} -> true
             _other -> false
           end)
  end

  defp event_index!(events, predicate) do
    case Enum.find_index(events, predicate) do
      nil -> flunk("expected event was not recorded: #{inspect(events)}")
      index -> index
    end
  end

  defp crypto_plaintext_equals?(
         {:crypto, :encrypt_chunk, plaintext, _ciphertext},
         expected
       ),
       do: plaintext == expected

  defp crypto_plaintext_equals?(_event, _expected), do: false

  defp payload_binary(payload) when is_binary(payload), do: payload

  defp payload_binary(payload) do
    payload
    |> Enum.to_list()
    |> IO.iodata_to_binary()
  end

  defp record_types(records), do: Enum.map(records, &Map.fetch!(&1, :type))

  defp flip_first_byte(<<byte, rest::binary>>),
    do: <<Bitwise.bxor(byte, 1), rest::binary>>

  defp noncanonical_manifest!(canonical) do
    {offset, 2} = :binary.match(canonical, <<97, 1>>)
    prefix = binary_part(canonical, 0, offset)
    suffix_offset = offset + 2
    suffix = binary_part(canonical, suffix_offset, byte_size(canonical) - suffix_offset)
    prefix <> <<98, 0, 0, 0, 1>> <> suffix
  end

  defp refute_secret(rendered, secret) when is_binary(secret) do
    refute :binary.match(rendered, secret) != :nomatch
    refute :binary.match(rendered, Base.encode16(secret)) != :nomatch
  end

  defp call(module, function, arguments), do: apply(module, function, arguments)
end
