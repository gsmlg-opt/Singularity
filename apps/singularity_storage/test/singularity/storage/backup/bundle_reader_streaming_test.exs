defmodule Singularity.Storage.Backup.BundleReaderStreamingTest do
  use ExUnit.Case, async: false

  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Backup.LocalDestination
  alias Singularity.Storage.Backup.Manifest

  @manifest_id "91000000-0000-4000-8000-000000000001"
  @vault_id "92000000-0000-4000-8000-000000000002"
  @snapshot_id "93000000-0000-4000-8000-000000000003"
  @raw_type 0x8000

  @moduletag :tmp_dir

  defmodule StreamingCrypto do
    @header "TEST"
    @final_counter 0xFFFFFFFF

    def header_size, do: byte_size(@header)

    def init_decrypt(capability, _public_header, @header) do
      {:ok, %{capability: capability, count: 0, hash: :crypto.hash_init(:sha256), bytes: 0}}
    end

    def decrypt_record(state, record) do
      with <<counter::unsigned-big-32, size::unsigned-big-32, plaintext::binary-size(size),
             _tag::binary-size(16)>> <- record,
           true <- counter == state.count do
        {:ok, plaintext,
         %{
           state
           | bytes: state.bytes + size,
             count: counter + 1,
             hash: :crypto.hash_update(state.hash, plaintext)
         }}
      else
        _invalid -> {:error, :integrity_failure}
      end
    end

    def finalize_decrypt(state, final_record, evidence) do
      with <<@final_counter::unsigned-big-32, 44::unsigned-big-32, _metadata::binary-size(44),
             _tag::binary-size(16)>> <- final_record do
        authenticated =
          Map.merge(evidence, %{
            chunk_count: state.count,
            plaintext_bytes: state.bytes,
            plaintext_sha256: :crypto.hash_final(state.hash),
            proof: %{manifest_hash: evidence.manifest_hash}
          })

        case state.capability do
          {:authenticate, recorder} ->
            Agent.update(recorder, &Map.put(&1, :authenticated, authenticated))
            {:ok, authenticated, {:replay, recorder}}

          {:replay, recorder} ->
            if Agent.get(recorder, &(&1.authenticated == authenticated)) do
              {:ok, authenticated, :replayed}
            else
              {:error, :integrity_failure}
            end
        end
      else
        _invalid -> {:error, :integrity_failure}
      end
    end
  end

  defmodule StreamingVerifier do
    def init({recorder, cut}) do
      Agent.update(recorder, &Map.update!(&1, :passes, fn count -> count + 1 end))
      {:ok, %{cut: cut, recorder: recorder}}
    end

    def handle_event(state, {:record_chunk, chunk}) do
      Agent.update(state.recorder, fn recorder ->
        %{recorder | max_chunk: max(recorder.max_chunk, byte_size(chunk))}
      end)

      {:ok, state}
    end

    def handle_event(state, {:record_start, _type, _size}) do
      Agent.update(state.recorder, &Map.update!(&1, :starts, fn count -> count + 1 end))
      {:ok, state}
    end

    def handle_event(state, :record_end) do
      Agent.update(state.recorder, &Map.update!(&1, :ends, fn count -> count + 1 end))
      {:ok, state}
    end

    def finish(state, _manifest) do
      Agent.update(state.recorder, &Map.update!(&1, :finishes, fn count -> count + 1 end))
      {:ok, state.cut}
    end
  end

  test "authenticates and replays one immutable snapshot without retaining raw payloads", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "backups")
    File.mkdir_p!(root)
    path = Path.join(root, "vault.bundle")
    moved = path <> ".authenticated"
    raw = :binary.copy(<<0xA5>>, 5 * 1024 * 1024 + 17)
    records = [%{type: 0x1234, payload: "metadata"}, %{type: @raw_type, payload: raw}]
    manifest = manifest!(records)
    public_header = %{manifest_id: @manifest_id, version: 1}
    encoded = encode_bundle(public_header, records, manifest)
    File.write!(path, encoded)

    {:ok, recorder} =
      Agent.start_link(fn ->
        %{
          authenticated: nil,
          ends: 0,
          finishes: 0,
          max_chunk: 0,
          passes: 0,
          starts: 0
        }
      end)

    cut = %{manifest_id: @manifest_id, object_inventory: [], vault_id: @vault_id}

    assert {:ok, source} =
             LocalDestination.reader_source(%{backup_root: root}, "vault.bundle")

    authentication_result =
      BundleReader.authenticate_all(source,
        crypto: {StreamingCrypto, {:authenticate, recorder}},
        verifier: {StreamingVerifier, {recorder, cut}}
      )

    assert {:ok, verified} = authentication_result

    assert verified.records == []
    assert verified.cut == cut
    assert inspect(verified.replay) =~ "REDACTED"
    refute inspect(verified) =~ raw

    File.rename!(path, moved)
    File.write!(path, "untrusted replacement")

    reducer = fn
      {:record_start, @raw_type, payload_length}, state ->
        {:ok, %{state | expected: payload_length, raw?: true}}

      {:record_chunk, chunk}, %{raw?: true} = state ->
        {:ok, %{state | bytes: state.bytes + byte_size(chunk)}}

      :record_end, %{raw?: true} = state ->
        {:ok, %{state | raw?: false}}

      _event, state ->
        {:ok, state}
    end

    expected_size = byte_size(raw)

    assert {:ok, %{bytes: ^expected_size, expected: ^expected_size, raw?: false}} =
             BundleReader.reduce_verified(
               verified,
               %{bytes: 0, expected: nil, raw?: false},
               reducer
             )

    assert Agent.get(recorder, & &1.passes) == 2
    assert Agent.get(recorder, & &1.max_chunk) <= 1_048_576
  end

  test "closes an opened snapshot when its reported size is invalid" do
    owner = self()

    file_system = %{
      close_snapshot: fn :snapshot ->
        send(owner, :snapshot_closed)
        :ok
      end,
      open_snapshot: fn "invalid.bundle", _max_bytes ->
        {:ok, :snapshot, %{size: 0}}
      end,
      pread: fn _snapshot, _offset, _count -> flunk("invalid snapshot must not be read") end,
      verify_snapshot: fn _snapshot, _size -> flunk("invalid snapshot must not be verified") end
    }

    assert {:error, _reason} =
             BundleReader.authenticate_all(
               %{file_system: file_system, path: "invalid.bundle"},
               crypto: {StreamingCrypto, {:authenticate, self()}},
               verifier: {StreamingVerifier, {self(), %{}}}
             )

    assert_receive :snapshot_closed
  end

  test "rejects an in-place rewrite before replay reducer effects", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "backups")
    File.mkdir_p!(root)
    path = Path.join(root, "vault.bundle")
    records = [%{type: 0x1234, payload: "metadata"}]
    manifest = manifest!(records)
    public_header = %{manifest_id: @manifest_id, version: 1}
    encoded = encode_bundle(public_header, records, manifest)
    File.write!(path, encoded)

    {:ok, recorder} =
      Agent.start_link(fn ->
        %{authenticated: nil, ends: 0, finishes: 0, max_chunk: 0, passes: 0, starts: 0}
      end)

    cut = %{manifest_id: @manifest_id, object_inventory: [], vault_id: @vault_id}
    assert {:ok, source} = LocalDestination.reader_source(%{backup_root: root}, "vault.bundle")

    assert {:ok, verified} =
             BundleReader.authenticate_all(source,
               crypto: {StreamingCrypto, {:authenticate, recorder}},
               verifier: {StreamingVerifier, {recorder, cut}}
             )

    <<first, rest::binary>> = encoded
    File.write!(path, <<Bitwise.bxor(first, 1), rest::binary>>)
    owner = self()

    assert {:error, _reason} =
             BundleReader.reduce_verified(verified, :initial, fn event, accumulator ->
               send(owner, {:reducer_effect, event})
               {:ok, accumulator}
             end)

    refute_received {:reducer_effect, _event}
  end

  test "rejects a short encrypted record followed by another data record", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "backups")
    File.mkdir_p!(root)
    path = Path.join(root, "vault.bundle")
    raw = :binary.copy(<<0xA5>>, 2 * 1024 * 1024)
    records = [%{type: @raw_type, payload: raw}]
    manifest = manifest!(records)
    public_header = %{manifest_id: @manifest_id, version: 1}

    File.write!(path, encode_bundle(public_header, records, manifest, 1_048_576))

    {:ok, recorder} =
      Agent.start_link(fn ->
        %{authenticated: nil, ends: 0, finishes: 0, max_chunk: 0, passes: 0, starts: 0}
      end)

    cut = %{manifest_id: @manifest_id, object_inventory: [], vault_id: @vault_id}
    assert {:ok, source} = LocalDestination.reader_source(%{backup_root: root}, "vault.bundle")

    assert {:error, _reason} =
             BundleReader.authenticate_all(source,
               crypto: {StreamingCrypto, {:authenticate, recorder}},
               verifier: {StreamingVerifier, {recorder, cut}}
             )
  end

  defp manifest!(records) do
    inventory =
      records
      |> Enum.with_index()
      |> Enum.map(fn {%{type: type, payload: payload}, position} ->
        %{
          payload_length: byte_size(payload),
          position: position,
          record_type: type,
          sha256: :crypto.hash(:sha256, payload)
        }
      end)

    assert {:ok, manifest} =
             Manifest.new(%{
               inventory: inventory,
               manifest_id: @manifest_id,
               outbox_high_water_mark: 0,
               recovery: %{
                 "binding" => %{"manifest_id" => @manifest_id, "vault_id" => @vault_id},
                 "label" => "backup_recovery",
                 "wrapper" => "test-wrapper"
               },
               snapshot_id: @snapshot_id,
               vault_ids: [@vault_id],
               version: 1
             })

    manifest
  end

  defp encode_bundle(public_header, records, manifest, encrypted_chunk_size \\ 4_194_304) do
    {:ok, encoded_manifest} = Manifest.encode(manifest)

    plaintext =
      (records ++ [%{type: 0xFFFF, payload: encoded_manifest}])
      |> Enum.map(fn record ->
        <<record.type::unsigned-big-16, byte_size(record.payload)::unsigned-big-64,
          record.payload::binary>>
      end)
      |> IO.iodata_to_binary()

    encrypted =
      plaintext
      |> chunk_binary(encrypted_chunk_size)
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        <<index::unsigned-big-32, byte_size(chunk)::unsigned-big-32, chunk::binary, 0::128>>
      end)
      |> Kernel.++([
        <<0xFFFFFFFF::unsigned-big-32, 44::unsigned-big-32, 0::352, 0xAB::128>>
      ])
      |> then(&IO.iodata_to_binary(["TEST" | &1]))

    encoded_header = :erlang.term_to_binary(public_header, [:deterministic])

    <<"SINGULARITY-BACKUP", 1::unsigned-big-16, byte_size(encoded_header)::unsigned-big-32,
      encoded_header::binary, encrypted::binary>>
  end

  defp chunk_binary(binary, size), do: chunk_binary(binary, size, [])
  defp chunk_binary("", _size, chunks), do: Enum.reverse(chunks)

  defp chunk_binary(binary, size, chunks) do
    count = min(size, byte_size(binary))
    <<chunk::binary-size(count), rest::binary>> = binary
    chunk_binary(rest, size, [chunk | chunks])
  end
end
