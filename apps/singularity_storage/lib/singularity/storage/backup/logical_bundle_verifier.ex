defmodule Singularity.Storage.Backup.LogicalBundleVerifier do
  @moduledoc "Verifies authenticated logical backup semantics and reconstructs the sealed cut."

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Backup.LogicalRecordCodec
  alias Singularity.Storage.Backup.LogicalSchema
  alias Singularity.Storage.Backup.Manifest

  @cut_record_type 0x0001
  @row_record_type 0x0002
  @object_evidence_record_type 0x0003
  @object_record_type 0x8000
  @binding_keys ~w[destination_ref manifest_id recovery vault_id]a
  @stream_binding_keys ~w[destination_ref manifest_id vault_id]a
  @cut_payload_limit 64 * 1024
  @metadata_payload_limit 16 * 1024 * 1024
  @max_non_manifest_frames 999_999

  defmodule StreamState do
    @moduledoc false

    @enforce_keys [
      :binding,
      :current,
      :cut,
      :frame_count,
      :inventory,
      :inventory_hash,
      :phase
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  defimpl Inspect, for: StreamState do
    import Inspect.Algebra

    def inspect(state, options) do
      concat([
        "#LogicalBundleVerifier.StreamState<",
        to_doc([frame_count: state.frame_count, phase: safe_phase(state.phase)], options),
        ">"
      ])
    end

    defp safe_phase(:cut), do: :cut
    defp safe_phase(:done), do: :done
    defp safe_phase({phase, _rest}), do: phase
    defp safe_phase({phase, _one, _two, _three, _four}), do: phase
    defp safe_phase(_phase), do: :invalid
  end

  @spec init(map()) :: {:ok, StreamState.t()} | {:error, Error.t()}
  def init(binding) when is_map(binding) do
    with {:ok, binding} <- validate_stream_binding(binding) do
      {:ok,
       %StreamState{
         binding: binding,
         current: nil,
         cut: nil,
         frame_count: 0,
         inventory: [],
         inventory_hash: :crypto.hash_init(:sha256),
         phase: :cut
       }}
    end
  end

  def init(_binding), do: invalid()

  @spec handle_event(StreamState.t(), term()) ::
          {:ok, StreamState.t()} | {:error, Error.t()}
  def handle_event(
        %StreamState{current: nil, frame_count: count} = state,
        {:record_start, type, payload_length}
      )
      when count < @max_non_manifest_frames and is_integer(type) and type >= 0 and
             type <= 0xFFFE and is_integer(payload_length) and payload_length >= 0 and
             payload_length <= 0xFFFFFFFFFFFFFFFF do
    with {:ok, buffering?} <- validate_stream_record_start(state, type, payload_length) do
      {:ok,
       %{
         state
         | current: %{
             buffering?: buffering?,
             chunks: [],
             hash: :crypto.hash_init(:sha256),
             payload_length: payload_length,
             remaining: payload_length,
             type: type
           }
       }}
    end
  end

  def handle_event(
        %StreamState{current: %{remaining: remaining} = current} = state,
        {:record_chunk, chunk}
      )
      when is_binary(chunk) and chunk != "" and byte_size(chunk) <= remaining do
    chunks = if current.buffering?, do: [chunk | current.chunks], else: current.chunks

    {:ok,
     %{
       state
       | current: %{
           current
           | chunks: chunks,
             hash: :crypto.hash_update(current.hash, chunk),
             remaining: remaining - byte_size(chunk)
         }
     }}
  rescue
    ArgumentError -> invalid()
  catch
    :error, _reason -> invalid()
  end

  def handle_event(%StreamState{current: %{remaining: 0} = current} = state, :record_end) do
    with {:ok, payload_hash} <- finish_hash(current.hash),
         {:ok, state} <- finish_stream_record(state, current, payload_hash),
         {:ok, inventory_hash} <-
           update_inventory_hash(
             state.inventory_hash,
             state.frame_count,
             current.type,
             current.payload_length,
             payload_hash
           ) do
      {:ok,
       %{
         state
         | current: nil,
           frame_count: state.frame_count + 1,
           inventory_hash: inventory_hash
       }}
    else
      _invalid -> invalid()
    end
  end

  def handle_event(_state, _event), do: invalid()

  @spec finish(StreamState.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def finish(
        %StreamState{
          current: nil,
          cut: cut,
          frame_count: frame_count,
          inventory: inventory,
          inventory_hash: inventory_hash,
          phase: :done
        } = state,
        manifest
      )
      when is_map(cut) and is_list(inventory) do
    with {:ok, manifest} <- Manifest.new(manifest),
         :ok <- validate_manifest_binding(manifest, state.binding),
         :ok <- validate_cut_binding(cut, manifest, state.binding),
         true <- frame_count == length(manifest.inventory),
         {:ok, observed_digest} <- finish_hash(inventory_hash),
         {:ok, manifest_digest} <- manifest_inventory_digest(manifest.inventory),
         true <- observed_digest == manifest_digest do
      {:ok, cut_result(cut, inventory)}
    else
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def finish(_state, _manifest), do: invalid()

  @spec verify(BundleReader.Verified.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def verify(
        %BundleReader.Verified{
          manifest: manifest,
          records: records,
          manifest_hash: <<_::binary-size(32)>> = manifest_hash,
          manifest_tag: <<_::binary-size(16)>>
        },
        binding
      )
      when is_list(records) and is_map(binding) do
    with {:ok, manifest} <- validate_verified(manifest, records, manifest_hash),
         {:ok, binding} <- validate_binding(binding),
         :ok <- validate_manifest_binding(manifest, binding),
         {:ok, cut, remaining} <- decode_cut(records),
         :ok <- validate_cut_binding(cut, manifest, binding),
         :ok <- validate_frame_count(records, cut),
         {:ok, remaining} <-
           verify_rows(
             remaining,
             cut.table_count_vector,
             binding.vault_id,
             cut.outbox_high_water_mark
           ),
         {:ok, inventory, remaining} <-
           verify_object_evidence(remaining, cut.object_count, binding.vault_id),
         :ok <- verify_raw_objects(remaining, inventory) do
      {:ok,
       %{
         database_snapshot: cut.database_snapshot,
         manifest_id: cut.manifest_id,
         object_inventory: inventory,
         outbox_high_water_mark: cut.outbox_high_water_mark,
         snapshot_id: cut.snapshot_id,
         vault_id: cut.vault_id
       }}
    else
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def verify(_verified, _binding), do: invalid()

  defp validate_stream_record_start(%StreamState{phase: :cut}, @cut_record_type, payload_length)
       when payload_length <= @cut_payload_limit,
       do: {:ok, true}

  defp validate_stream_record_start(
         %StreamState{phase: {:rows, _schema, _remaining, _rest, _previous}},
         @row_record_type,
         payload_length
       )
       when payload_length <= @metadata_payload_limit,
       do: {:ok, true}

  defp validate_stream_record_start(
         %StreamState{phase: {:object_evidence, _remaining, _next_index, _previous}},
         @object_evidence_record_type,
         payload_length
       )
       when payload_length <= @metadata_payload_limit,
       do: {:ok, true}

  defp validate_stream_record_start(
         %StreamState{phase: {:raw_objects, [%{ciphertext_byte_size: payload_length} | _rest]}},
         @object_record_type,
         payload_length
       ),
       do: {:ok, false}

  defp validate_stream_record_start(_state, _type, _payload_length), do: invalid()

  defp finish_stream_record(%StreamState{phase: :cut} = state, current, _payload_hash) do
    with {:ok, payload} <- buffered_payload(current),
         {:ok, %{kind: :cut} = cut} <-
           LogicalRecordCodec.decode(@cut_record_type, payload),
         true <- cut.manifest_id == state.binding.manifest_id,
         true <- cut.vault_id == state.binding.vault_id,
         :ok <- validate_table_count(Enum.at(LogicalSchema.all(), 0), hd(cut.table_count_vector)) do
      phase =
        cut.table_count_vector
        |> then(&Enum.zip(LogicalSchema.all(), &1))
        |> rows_phase(cut.object_count)

      {:ok, %{state | cut: cut, phase: phase}}
    else
      _invalid -> invalid()
    end
  end

  defp finish_stream_record(
         %StreamState{
           cut: cut,
           phase: {:rows, schema, remaining, rest, previous_key}
         } = state,
         current,
         _payload_hash
       ) do
    with {:ok, payload} <- buffered_payload(current),
         {:ok, row} <- decode_row(%{type: current.type, payload: payload}, schema),
         :ok <- validate_row_vault(row, schema, state.binding.vault_id),
         {:ok, key} <- row_sort_key(row, schema, cut.outbox_high_water_mark),
         true <- is_nil(previous_key) or previous_key < key do
      {:ok, %{state | phase: advance_rows_phase(schema, remaining, rest, key, cut.object_count)}}
    else
      _invalid -> invalid()
    end
  end

  defp finish_stream_record(
         %StreamState{
           cut: cut,
           inventory: inventory,
           phase: {:object_evidence, remaining, next_index, previous_id}
         } = state,
         current,
         _payload_hash
       ) do
    with {:ok, payload} <- buffered_payload(current),
         {:ok, object} <- decode_object(%{type: current.type, payload: payload}),
         true <- object.object_index == next_index,
         true <- object.vault_id == state.binding.vault_id,
         true <- is_nil(previous_id) or previous_id < object.asset_object_id,
         {:ok, classification} <- classification(object.classification) do
      entry = %{
        asset_object_id: object.asset_object_id,
        ciphertext_byte_size: object.ciphertext_byte_size,
        ciphertext_hash: object.ciphertext_hash,
        classification: classification,
        inventory_position: object.object_index,
        key_domain_id: object.key_domain_id,
        lookup_digest: object.lookup_digest,
        storage_ref: object.storage_ref,
        vault_id: object.vault_id
      }

      inventory = [entry | inventory]

      phase =
        if remaining == 1 do
          inventory
          |> Enum.reverse()
          |> raw_objects_phase()
        else
          {:object_evidence, remaining - 1, next_index + 1, object.asset_object_id}
        end

      {:ok, %{state | inventory: inventory, phase: phase, cut: cut}}
    else
      _invalid -> invalid()
    end
  end

  defp finish_stream_record(
         %StreamState{inventory: reversed_inventory, phase: {:raw_objects, [entry | rest]}} =
           state,
         current,
         payload_hash
       ) do
    if current.payload_length == entry.ciphertext_byte_size and
         payload_hash == entry.ciphertext_hash do
      inventory =
        case rest do
          [] -> Enum.reverse(reversed_inventory)
          _remaining -> reversed_inventory
        end

      {:ok, %{state | inventory: inventory, phase: raw_objects_phase(rest)}}
    else
      invalid()
    end
  end

  defp finish_stream_record(_state, _current, _payload_hash), do: invalid()

  defp rows_phase(schema_counts, object_count) do
    case Enum.drop_while(schema_counts, fn {_schema, count} -> count == 0 end) do
      [{schema, count} | rest] -> {:rows, schema, count, rest, nil}
      [] -> object_evidence_phase(object_count)
    end
  end

  defp advance_rows_phase(schema, remaining, rest, key, _object_count) when remaining > 1,
    do: {:rows, schema, remaining - 1, rest, key}

  defp advance_rows_phase(_schema, 1, rest, _key, object_count),
    do: rows_phase(rest, object_count)

  defp object_evidence_phase(0), do: :done
  defp object_evidence_phase(count), do: {:object_evidence, count, 0, nil}

  defp raw_objects_phase([]), do: :done
  defp raw_objects_phase(inventory), do: {:raw_objects, inventory}

  defp buffered_payload(%{buffering?: true, chunks: chunks, payload_length: payload_length}) do
    payload = chunks |> Enum.reverse() |> IO.iodata_to_binary()
    if byte_size(payload) == payload_length, do: {:ok, payload}, else: invalid()
  end

  defp buffered_payload(_current), do: invalid()

  defp update_inventory_hash(hash, position, type, payload_length, payload_hash) do
    {:ok,
     :crypto.hash_update(
       hash,
       <<position::unsigned-big-64, type::unsigned-big-16, payload_length::unsigned-big-64,
         payload_hash::binary-size(32)>>
     )}
  rescue
    ArgumentError -> invalid()
  catch
    :error, _reason -> invalid()
  end

  defp manifest_inventory_digest(inventory) do
    inventory
    |> Enum.reduce_while({:ok, :crypto.hash_init(:sha256)}, fn entry, {:ok, hash} ->
      case update_inventory_hash(
             hash,
             entry.position,
             entry.record_type,
             entry.payload_length,
             entry.sha256
           ) do
        {:ok, next_hash} -> {:cont, {:ok, next_hash}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, hash} -> finish_hash(hash)
      {:error, %Error{}} = error -> error
    end
  end

  defp finish_hash(hash) do
    case :crypto.hash_final(hash) do
      <<_::binary-size(32)>> = digest -> {:ok, digest}
      _invalid -> invalid()
    end
  rescue
    ArgumentError -> invalid()
  catch
    :error, _reason -> invalid()
  end

  defp cut_result(cut, inventory) do
    %{
      database_snapshot: cut.database_snapshot,
      manifest_id: cut.manifest_id,
      object_inventory: inventory,
      outbox_high_water_mark: cut.outbox_high_water_mark,
      snapshot_id: cut.snapshot_id,
      vault_id: cut.vault_id
    }
  end

  defp validate_verified(manifest, records, manifest_hash) do
    with {:ok, manifest} <- Manifest.new(manifest),
         {:ok, encoded_manifest} <- Manifest.encode(manifest),
         true <- :crypto.hash(:sha256, encoded_manifest) == manifest_hash,
         :ok <- Manifest.verify(manifest, records) do
      {:ok, manifest}
    else
      _invalid -> invalid()
    end
  end

  defp validate_binding(binding) do
    with true <- exact_keys?(binding, @binding_keys),
         true <- canonical_uuid?(binding.manifest_id),
         true <- canonical_uuid?(binding.vault_id),
         true <- is_map(binding.recovery),
         true <- is_binary(binding.destination_ref) and binding.destination_ref != "" do
      {:ok, binding}
    else
      _invalid -> invalid()
    end
  end

  defp validate_stream_binding(binding) do
    if exact_keys?(binding, @binding_keys) do
      validate_binding(binding)
    else
      with true <- exact_keys?(binding, @stream_binding_keys),
           true <- canonical_uuid?(binding.manifest_id),
           true <- canonical_uuid?(binding.vault_id),
           true <- is_binary(binding.destination_ref) and binding.destination_ref != "" do
        {:ok, binding}
      else
        _invalid -> invalid()
      end
    end
  end

  defp validate_manifest_binding(manifest, binding) do
    recovery_matches? =
      not Map.has_key?(binding, :recovery) or manifest.recovery == binding.recovery

    if manifest.manifest_id == binding.manifest_id and
         manifest.vault_ids == [binding.vault_id] and recovery_matches? do
      :ok
    else
      invalid()
    end
  end

  defp decode_cut([
         %{type: @cut_record_type, payload: payload} | remaining
       ])
       when is_binary(payload) do
    with {:ok, %{kind: :cut} = cut} <-
           LogicalRecordCodec.decode(@cut_record_type, payload) do
      {:ok, cut, remaining}
    end
  end

  defp decode_cut(_records), do: invalid()

  defp validate_cut_binding(cut, manifest, binding) do
    if cut.manifest_id == binding.manifest_id and
         cut.vault_id == binding.vault_id and
         cut.snapshot_id == manifest.snapshot_id and
         cut.outbox_high_water_mark == manifest.outbox_high_water_mark do
      :ok
    else
      invalid()
    end
  end

  defp validate_frame_count(records, cut) do
    expected_count =
      1 + Enum.sum(cut.table_count_vector) + 2 * cut.object_count

    if length(records) == expected_count, do: :ok, else: invalid()
  end

  defp verify_rows(records, counts, vault_id, outbox_high_water_mark) do
    LogicalSchema.all()
    |> Enum.zip(counts)
    |> Enum.reduce_while({:ok, records}, fn {schema, count}, {:ok, remaining} ->
      result =
        with :ok <- validate_table_count(schema, count),
             {:ok, table_records, tail} <- take_exact(remaining, count),
             :ok <-
               verify_table_rows(
                 table_records,
                 schema,
                 vault_id,
                 outbox_high_water_mark
               ) do
          {:ok, tail}
        end

      case result do
        {:ok, tail} ->
          {:cont, {:ok, tail}}

        {:error, %Error{}} = error ->
          {:halt, error}
      end
    end)
  end

  defp validate_table_count(%{table: "core.vaults"}, 1), do: :ok
  defp validate_table_count(%{table: "core.vaults"}, _count), do: invalid()
  defp validate_table_count(_schema, _count), do: :ok

  defp verify_table_rows(records, schema, vault_id, outbox_high_water_mark) do
    records
    |> Enum.reduce_while({:ok, nil}, fn record, {:ok, previous_key} ->
      with {:ok, row} <- decode_row(record, schema),
           :ok <- validate_row_vault(row, schema, vault_id),
           {:ok, key} <- row_sort_key(row, schema, outbox_high_water_mark),
           true <- is_nil(previous_key) or previous_key < key do
        {:cont, {:ok, key}}
      else
        _invalid -> {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, _last_key} -> :ok
      {:error, %Error{}} = error -> error
    end
  end

  defp decode_row(%{type: @row_record_type, payload: payload}, schema)
       when is_binary(payload) do
    with {:ok,
          %{
            kind: :row,
            table: table,
            table_ordinal: ordinal
          } = row} <- LogicalRecordCodec.decode(@row_record_type, payload),
         true <- table == schema.table and ordinal == schema.ordinal do
      {:ok, row}
    else
      _invalid -> invalid()
    end
  end

  defp decode_row(_record, _schema), do: invalid()

  defp validate_row_vault(row, %{table: "core.vaults"}, vault_id) do
    case row.ordered_column_values do
      [{"uuid", ^vault_id} | _rest] -> :ok
      _invalid -> invalid()
    end
  end

  defp validate_row_vault(row, schema, vault_id) do
    case Enum.find_index(schema.columns, &(&1.name == "vault_id")) do
      nil ->
        :ok

      position ->
        if Enum.at(row.ordered_column_values, position) == {"uuid", vault_id},
          do: :ok,
          else: invalid()
    end
  end

  defp row_sort_key(row, %{table: "core.outbox_events"}, outbox_high_water_mark) do
    case row.ordered_column_values do
      [{"uuid", _id}, {"integer", sequence} | _rest]
      when sequence >= 0 and sequence <= outbox_high_water_mark ->
        {:ok, sequence}

      _invalid ->
        invalid()
    end
  end

  defp row_sort_key(row, _schema, _outbox_high_water_mark),
    do: {:ok, row.primary_key_values}

  defp verify_object_evidence(records, count, vault_id) do
    with {:ok, object_records, remaining} <- take_exact(records, count) do
      object_records
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, [], nil}, fn {record, expected_index},
                                              {:ok, inventory, previous_id} ->
        with {:ok, object} <- decode_object(record),
             true <- object.object_index == expected_index,
             true <- object.vault_id == vault_id,
             true <- is_nil(previous_id) or previous_id < object.asset_object_id,
             {:ok, classification} <- classification(object.classification) do
          entry = %{
            asset_object_id: object.asset_object_id,
            ciphertext_byte_size: object.ciphertext_byte_size,
            ciphertext_hash: object.ciphertext_hash,
            classification: classification,
            inventory_position: object.object_index,
            key_domain_id: object.key_domain_id,
            lookup_digest: object.lookup_digest,
            storage_ref: object.storage_ref,
            vault_id: object.vault_id
          }

          {:cont, {:ok, [entry | inventory], object.asset_object_id}}
        else
          _invalid -> {:halt, invalid()}
        end
      end)
      |> case do
        {:ok, inventory, _last_id} -> {:ok, Enum.reverse(inventory), remaining}
        {:error, %Error{}} = error -> error
      end
    end
  end

  defp decode_object(%{type: @object_evidence_record_type, payload: payload})
       when is_binary(payload) do
    with {:ok, %{kind: :object} = object} <-
           LogicalRecordCodec.decode(@object_evidence_record_type, payload) do
      {:ok, object}
    end
  end

  defp decode_object(_record), do: invalid()

  defp verify_raw_objects(records, inventory) do
    Enum.zip_reduce(records, inventory, :ok, fn
      %{type: @object_record_type, payload: payload}, entry, :ok when is_binary(payload) ->
        if byte_size(payload) == entry.ciphertext_byte_size and
             :crypto.hash(:sha256, payload) == entry.ciphertext_hash do
          :ok
        else
          invalid()
        end

      _record, _entry, :ok ->
        invalid()

      _record, _entry, {:error, %Error{}} = error ->
        error
    end)
    |> case do
      :ok when length(records) == length(inventory) -> :ok
      _invalid -> invalid()
    end
  end

  defp classification("private"), do: {:ok, :private}
  defp classification("sensitive"), do: {:ok, :sensitive}
  defp classification("restricted"), do: {:ok, :restricted}
  defp classification(_classification), do: invalid()

  defp take_exact(records, count) when is_integer(count) and count >= 0 do
    {taken, remaining} = Enum.split(records, count)

    if length(taken) == count,
      do: {:ok, taken, remaining},
      else: invalid()
  end

  defp take_exact(_records, _count), do: invalid()

  defp exact_keys?(map, keys),
    do: Map.keys(map) |> Enum.sort() == Enum.sort(keys)

  defp canonical_uuid?(value) when is_binary(value),
    do: Ecto.UUID.cast(value) == {:ok, value}

  defp canonical_uuid?(_value), do: false

  defp invalid, do: {:error, Error.new(:backup_invalid)}
end
