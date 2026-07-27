defmodule Singularity.Storage.Backup.BundleWriter do
  @moduledoc """
  Streams an authenticated backup bundle to an injected filesystem.

  Ownership-aware filesystems return `{:ok, device, token}` from `open/2` and
  provide `publish/3` plus `remove_owned/2`. Legacy injected filesystems may
  continue to return `{:ok, device}` and provide `rename/2` plus `remove/1`.
  """

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.Manifest

  @magic "SINGULARITY-BACKUP"
  @format_version 1
  @manifest_record_type 0xFFFF
  @max_public_header_bytes 65_536
  @max_payload_length 0xFFFFFFFFFFFFFFFF
  @max_frames 1_000_000

  @common_file_system_callbacks [
    open: 2,
    write: 2,
    sync: 1,
    close: 1,
    exists?: 1
  ]
  @legacy_file_system_callbacks [rename: 2, remove: 1]
  @owned_file_system_callbacks [publish: 3, remove_owned: 2]

  @spec stream(map(), Enumerable.t(), Enumerable.t(), map(), map()) ::
          {:ok,
           %{
             destination_ref: binary(),
             path: binary(),
             manifest_id: Ecto.UUID.t(),
             inventory: [map()],
             manifest_hash: <<_::256>>,
             manifest_tag: <<_::128>>
           }}
          | {:error, Error.t()}
  def stream(destination, records, inventory_records, manifest, crypto) do
    with {:ok, context} <-
           validate_context(destination, records, inventory_records, manifest, crypto),
         :ok <- ensure_destination_absent(context),
         :ok <- remove_stale_partial(context),
         {:ok, opened} <- open_partial(context) do
      write_and_publish(opened, context)
    end
  end

  defp validate_context(
         %{file_system: file_system, path: path} = destination,
         records,
         inventory_records,
         manifest,
         %{adapter: adapter, capability: capability, public_header: public_header}
       )
       when is_binary(path) and path != "" and is_map(file_system) and is_atom(adapter) do
    destination_ref = Map.get(destination, :destination_ref, path)

    with true <- is_binary(destination_ref) and destination_ref != "",
         {:ok, file_system_mode} <- validate_file_system(file_system),
         :ok <- validate_enumerable(records),
         :ok <- validate_enumerable(inventory_records),
         {:ok, manifest} <- Manifest.new(manifest),
         true <- valid_frame_count?(length(manifest.inventory)),
         {:ok, partial_path} <- partial_path(destination, path, manifest.manifest_id),
         {:ok, prelude} <- encode_prelude(public_header, manifest),
         true <- crypto_adapter?(adapter) do
      {:ok,
       %{
         adapter: adapter,
         capability: capability,
         destination_ref: destination_ref,
         file_system: file_system,
         file_system_mode: file_system_mode,
         inventory: manifest.inventory,
         inventory_records: inventory_records,
         manifest: manifest,
         partial_path: partial_path,
         path: path,
         prelude: prelude,
         public_header: public_header,
         records: records
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> invalid()
    end
  end

  defp validate_context(
         _destination,
         _records,
         _inventory_records,
         _manifest,
         _crypto
       ),
       do: invalid()

  @doc false
  @spec valid_frame_count?(non_neg_integer()) :: boolean()
  def valid_frame_count?(data_frame_count)
      when is_integer(data_frame_count) and data_frame_count >= 0,
      do: data_frame_count < @max_frames

  def valid_frame_count?(_data_frame_count), do: false

  defp validate_file_system(file_system) do
    with true <- callbacks?(file_system, @common_file_system_callbacks) do
      cond do
        callbacks?(file_system, @owned_file_system_callbacks) -> {:ok, :owned}
        callbacks?(file_system, @legacy_file_system_callbacks) -> {:ok, :legacy}
        true -> invalid()
      end
    else
      false -> invalid()
    end
  end

  defp callbacks?(file_system, callbacks) do
    Enum.all?(callbacks, fn {name, arity} ->
      case Map.fetch(file_system, name) do
        {:ok, callback} -> is_function(callback, arity)
        :error -> false
      end
    end)
  end

  defp validate_enumerable(value) do
    if Enumerable.impl_for(value), do: :ok, else: invalid()
  end

  defp partial_path(%{partial_path: resolver}, path, manifest_id)
       when is_function(resolver, 1) do
    case resolver.(manifest_id) do
      partial_path when is_binary(partial_path) and partial_path != "" and partial_path != path ->
        {:ok, partial_path}

      _invalid ->
        invalid()
    end
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  defp partial_path(destination, path, _manifest_id) do
    if Map.has_key?(destination, :partial_path),
      do: invalid(),
      else: {:ok, path <> ".partial"}
  end

  defp crypto_adapter?(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :init_encrypt, 2) and
      function_exported?(adapter, :encrypt_chunk, 2) and
      function_exported?(adapter, :finalize, 2)
  end

  defp encode_prelude(public_header, manifest) when is_map(public_header) do
    with true <- Map.get(public_header, :version) == @format_version,
         true <- Map.get(public_header, :manifest_id) == manifest.manifest_id,
         encoded when is_binary(encoded) <-
           :erlang.term_to_binary(public_header, [:deterministic]),
         true <- byte_size(encoded) in 1..@max_public_header_bytes,
         true <- safely_decodes_to?(encoded, public_header) do
      {:ok,
       <<@magic, @format_version::unsigned-big-16, byte_size(encoded)::unsigned-big-32,
         encoded::binary>>}
    else
      _invalid -> invalid()
    end
  rescue
    ArgumentError -> invalid()
  end

  defp encode_prelude(_public_header, _manifest), do: invalid()

  defp safely_decodes_to?(<<131, tag, _rest::binary>> = encoded, expected) when tag != 80 do
    case :erlang.binary_to_term(encoded, [:safe, :used]) do
      {^expected, consumed} when consumed == byte_size(encoded) -> true
      _invalid -> false
    end
  rescue
    ArgumentError -> false
  end

  defp safely_decodes_to?(_encoded, _expected), do: false

  defp ensure_destination_absent(context) do
    case file_system_call(context.file_system, :exists?, [context.path]) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, Error.new(:conflict)}
      {:ok, {:error, %Error{} = error}} -> {:error, error}
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> storage_unavailable()
    end
  end

  defp remove_stale_partial(context) do
    case file_system_call(context.file_system, :exists?, [context.partial_path]) do
      {:ok, false} -> :ok
      {:ok, true} when context.file_system_mode == :legacy -> remove_partial(context, :legacy)
      {:ok, true} -> {:error, Error.new(:conflict)}
      {:ok, {:error, %Error{} = error}} -> {:error, error}
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> storage_unavailable()
    end
  end

  defp open_partial(context) do
    case file_system_call(context.file_system, :open, [
           context.partial_path,
           [:write, :binary, :exclusive]
         ]) do
      {:ok, {:ok, device, ownership}} when context.file_system_mode == :owned ->
        {:ok, %{device: device, ownership: {:owned, ownership}}}

      {:ok, {:ok, device}} when context.file_system_mode == :legacy ->
        {:ok, %{device: device, ownership: :legacy}}

      {:ok, {:error, %Error{} = error}} ->
        {:error, error}

      _error ->
        storage_unavailable()
    end
  end

  defp write_and_publish(%{device: device, ownership: ownership}, context) do
    result = write_open_bundle(device, context)
    close_result = file_system_call(context.file_system, :close, [device])

    case {result, close_result} do
      {{:ok, bundle}, {:ok, :ok}} ->
        publish_partial(context, bundle, ownership)

      {{:error, %Error{} = error}, {:ok, :ok}} ->
        cleanup(context, error, ownership)

      {_result, _close_result} ->
        cleanup(context, Error.new(:storage_unavailable), ownership)
    end
  end

  defp write_open_bundle(device, context) do
    with {:ok, crypto_header, crypto_state} <-
           crypto_init(context.adapter, context.capability, context.public_header),
         :ok <- write_bytes(context.file_system, device, context.prelude),
         :ok <- write_bytes(context.file_system, device, crypto_header),
         {:ok, crypto_state} <- write_records(device, context, crypto_state),
         {:ok, encoded_manifest} <- Manifest.encode(context.manifest),
         {:ok, crypto_state} <-
           encrypt_and_write(
             device,
             context,
             crypto_state,
             <<@manifest_record_type::unsigned-big-16,
               byte_size(encoded_manifest)::unsigned-big-64>>
           ),
         {:ok, crypto_state} <-
           encrypt_and_write(device, context, crypto_state, encoded_manifest),
         {:ok, final_output, summary, :finalized} <-
           crypto_finalize(context.adapter, crypto_state, context.manifest),
         <<_::binary-size(32)>> = manifest_hash <- Map.get(summary, :manifest_hash),
         <<_::binary-size(16)>> = manifest_tag <- Map.get(summary, :manifest_tag),
         true <- manifest_hash == :crypto.hash(:sha256, encoded_manifest),
         true <- byte_size(final_output) >= byte_size(manifest_tag),
         true <-
           binary_part(
             final_output,
             byte_size(final_output) - byte_size(manifest_tag),
             byte_size(manifest_tag)
           ) == manifest_tag,
         :ok <- write_if_nonempty(context.file_system, device, final_output),
         :ok <- sync(context.file_system, device) do
      {:ok,
       %{
         destination_ref: context.destination_ref,
         path: context.path,
         manifest_id: context.manifest.manifest_id,
         inventory: context.inventory,
         manifest_hash: manifest_hash,
         manifest_tag: manifest_tag
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> backup_invalid()
    end
  rescue
    _exception -> backup_invalid()
  catch
    :throw, {Singularity.Storage.Backup.Exporter, :object_stream_error, %Error{} = error} ->
      {:error, error}

    _kind, _reason ->
      backup_invalid()
  end

  defp write_records(device, context, crypto_state) do
    all_records = Stream.concat(context.records, context.inventory_records)

    result =
      Enum.reduce_while(
        all_records,
        {:ok, crypto_state, context.inventory},
        fn record, {:ok, state, inventory} ->
          case write_record(device, context, state, record, inventory) do
            {:ok, next_state, remaining_inventory} ->
              {:cont, {:ok, next_state, remaining_inventory}}

            {:error, %Error{} = error} ->
              {:halt, {:error, error}}
          end
        end
      )

    case result do
      {:ok, state, []} -> {:ok, state}
      {:ok, _state, _remaining_inventory} -> backup_invalid()
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp write_record(
         device,
         context,
         crypto_state,
         %{type: type, payload_length: payload_length, payload: payload},
         [
           %{
             record_type: type,
             payload_length: payload_length,
             sha256: expected_hash
           }
           | inventory
         ]
       )
       when is_integer(type) and type >= 0 and type < @manifest_record_type and
              is_integer(payload_length) and payload_length >= 0 and
              payload_length <= @max_payload_length and is_binary(expected_hash) do
    with {:ok, fragments} <- payload_fragments(payload),
         {:ok, crypto_state} <-
           encrypt_and_write(
             device,
             context,
             crypto_state,
             <<type::unsigned-big-16, payload_length::unsigned-big-64>>
           ),
         {:ok, crypto_state, actual_length, actual_hash} <-
           write_payload(device, context, crypto_state, fragments, payload_length),
         true <- actual_length == payload_length and actual_hash == expected_hash do
      {:ok, crypto_state, inventory}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> backup_invalid()
    end
  end

  defp write_record(_device, _context, _crypto_state, _record, _inventory),
    do: backup_invalid()

  defp payload_fragments(payload) when is_binary(payload) do
    if payload == "", do: {:ok, []}, else: {:ok, [payload]}
  end

  defp payload_fragments(payload) do
    if Enumerable.impl_for(payload), do: {:ok, payload}, else: invalid()
  end

  defp write_payload(device, context, crypto_state, fragments, expected_length) do
    initial = {:ok, crypto_state, 0, :crypto.hash_init(:sha256)}

    result =
      Enum.reduce_while(fragments, initial, fn
        fragment, {:ok, state, length, hash_state}
        when is_binary(fragment) and fragment != "" ->
          fragment_size = byte_size(fragment)

          if length <= expected_length and fragment_size <= expected_length - length do
            case encrypt_and_write(device, context, state, fragment) do
              {:ok, next_state} ->
                {:cont,
                 {:ok, next_state, length + fragment_size,
                  :crypto.hash_update(hash_state, fragment)}}

              {:error, %Error{} = error} ->
                {:halt, {:error, error}}
            end
          else
            {:halt, backup_invalid()}
          end

        _fragment, _state ->
          {:halt, backup_invalid()}
      end)

    case result do
      {:ok, state, length, hash_state} ->
        {:ok, state, length, :crypto.hash_final(hash_state)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp encrypt_and_write(device, context, crypto_state, fragment) do
    with {:ok, output, next_state} <-
           crypto_encrypt(context.adapter, crypto_state, fragment),
         :ok <- write_if_nonempty(context.file_system, device, output) do
      {:ok, next_state}
    end
  end

  defp crypto_init(adapter, capability, public_header) do
    case safe_apply(adapter, :init_encrypt, [capability, public_header]) do
      {:ok, {:ok, header, state}} when is_binary(header) and header != "" ->
        {:ok, header, state}

      _invalid ->
        backup_invalid()
    end
  end

  defp crypto_encrypt(adapter, state, fragment) do
    case safe_apply(adapter, :encrypt_chunk, [state, fragment]) do
      {:ok, {:ok, output, next_state}} when is_binary(output) ->
        {:ok, output, next_state}

      _invalid ->
        backup_invalid()
    end
  end

  defp crypto_finalize(adapter, state, manifest) do
    case safe_apply(adapter, :finalize, [state, manifest]) do
      {:ok, {:ok, output, summary, :finalized}} when is_binary(output) and is_map(summary) ->
        {:ok, output, summary, :finalized}

      _invalid ->
        backup_invalid()
    end
  end

  defp safe_apply(module, function, arguments) do
    {:ok, apply(module, function, arguments)}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp write_if_nonempty(_file_system, _device, ""), do: :ok

  defp write_if_nonempty(file_system, device, bytes) when is_binary(bytes) do
    write_bytes(file_system, device, bytes)
  end

  defp write_bytes(file_system, device, bytes) do
    case file_system_call(file_system, :write, [device, bytes]) do
      {:ok, :ok} -> :ok
      {:ok, {:error, %Error{} = error}} -> {:error, error}
      _error -> storage_unavailable()
    end
  end

  defp sync(file_system, device) do
    case file_system_call(file_system, :sync, [device]) do
      {:ok, :ok} -> :ok
      {:ok, {:error, %Error{} = error}} -> {:error, error}
      _error -> storage_unavailable()
    end
  end

  defp publish_partial(context, bundle, ownership) do
    {callback, arguments} = publication_callback(context, ownership)

    case file_system_call(context.file_system, callback, arguments) do
      {:ok, :ok} -> {:ok, bundle}
      {:ok, {:error, %Error{} = error}} -> publication_failure(context, error, ownership)
      _unknown -> ambiguous_publication()
    end
  end

  defp publication_callback(context, {:owned, ownership}),
    do: {:publish, [context.partial_path, context.path, ownership]}

  defp publication_callback(context, :legacy),
    do: {:rename, [context.partial_path, context.path]}

  defp publication_failure(context, %Error{details: details} = error, ownership) do
    case Map.get(details, :publication_state) do
      state when state in [:published, :ambiguous] -> {:error, error}
      :not_published -> cleanup(context, error, ownership)
      _unknown -> ambiguous_publication()
    end
  end

  defp cleanup(context, error, ownership) do
    case remove_partial(context, ownership) do
      :ok -> {:error, error}
      {:error, %Error{} = cleanup_error} -> cleanup_failure(error, cleanup_error)
    end
  end

  defp cleanup_failure(%Error{} = primary, %Error{} = cleanup_error) do
    {:error,
     Error.new(:storage_unavailable,
       details: %{
         cleanup_error: cleanup_error.code,
         operation: :cleanup_partial,
         primary_error: primary.code
       },
       retryable?: true
     )}
  end

  defp ambiguous_publication do
    {:error,
     Error.new(:storage_unavailable,
       details: %{operation: :publish, publication_state: :ambiguous},
       retryable?: true
     )}
  end

  defp remove_partial(context, ownership) do
    {callback, arguments} = removal_callback(context, ownership)

    case file_system_call(context.file_system, callback, arguments) do
      {:ok, :ok} -> :ok
      {:ok, {:error, :enoent}} -> :ok
      {:ok, {:error, %Error{} = error}} -> {:error, error}
      _error -> storage_unavailable()
    end
  end

  defp removal_callback(context, {:owned, ownership}),
    do: {:remove_owned, [context.partial_path, ownership]}

  defp removal_callback(context, :legacy), do: {:remove, [context.partial_path]}

  defp file_system_call(file_system, callback, arguments) do
    function = Map.fetch!(file_system, callback)
    {:ok, apply(function, arguments)}
  rescue
    _exception -> {:error, Error.new(:storage_unavailable)}
  catch
    _kind, _reason -> {:error, Error.new(:storage_unavailable)}
  end

  defp invalid, do: {:error, Error.new(:invalid)}
  defp backup_invalid, do: {:error, Error.new(:backup_invalid)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable)}
end
