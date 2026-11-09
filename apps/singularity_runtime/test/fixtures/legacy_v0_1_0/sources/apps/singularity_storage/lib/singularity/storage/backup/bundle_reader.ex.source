defmodule Singularity.Storage.Backup.BundleReader do
  @moduledoc "Authenticates a complete backup before exposing its records."

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.Manifest
  alias Singularity.Storage.Crypto.ChunkedAEAD

  @magic "SINGULARITY-BACKUP"
  @format_version 1
  @manifest_record_type 0xFFFF
  @max_public_header_bytes 65_536
  @max_public_prelude_bytes 65_560
  @max_encrypted_bundle_bytes 4_294_967_296
  @max_outer_bundle_bytes 4_295_032_856
  @max_frames 1_000_000
  @max_encrypted_records 1_024
  @max_manifest_bytes 67_108_864
  @reader_chunk_bytes 1_048_576
  @outer_header_bytes byte_size(@magic) + 6

  defmodule Replay do
    @moduledoc "Opaque authority for replaying the authenticated immutable source once."

    @enforce_keys [
      :crypto,
      :file_system,
      :public_header,
      :snapshot,
      :source_sha256,
      :source_size,
      :verifier
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  defimpl Inspect, for: Replay do
    import Inspect.Algebra

    def inspect(_replay, _options), do: concat(["#BundleReader.Replay<REDACTED>"])
  end

  defmodule Verified do
    @moduledoc "A fully authenticated and inventory-verified backup."

    @enforce_keys [:manifest, :records, :manifest_hash, :manifest_tag]
    defstruct @enforce_keys ++ [authentication: nil, cut: nil, replay: nil]

    @type t :: %__MODULE__{
            manifest: Manifest.t(),
            records: [map()],
            manifest_hash: <<_::256>>,
            manifest_tag: <<_::128>>,
            authentication: map() | nil,
            cut: map() | nil,
            replay: Replay.t() | nil
          }
  end

  @spec read_public_header(map()) :: {:ok, map()} | {:error, Error.t()}
  def read_public_header(source) do
    with {:ok, encoded_prefix} <- read_source_prefix(source),
         {:ok, public_header} <- parse_public_header_prefix(encoded_prefix) do
      {:ok, public_header}
    end
  end

  @spec authenticate_all(map(), keyword()) :: {:ok, Verified.t()} | {:error, Error.t()}
  def authenticate_all(source, options) do
    with {:ok, adapter, capability} <- crypto_option(options) do
      case bounded_option(source, options, adapter) do
        {:ok, verifier} -> authenticate_bounded(source, adapter, capability, verifier)
        :legacy -> authenticate_legacy(source, adapter, capability)
        {:error, %Error{}} = error -> error
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  end

  defp authenticate_legacy(source, adapter, capability) do
    with {:ok, encoded} <- read_source(source),
         {:ok, public_header, encrypted} <- parse_prelude(encoded),
         {:ok, manifest_tag} <- encrypted_manifest_tag(encrypted),
         {:ok, plaintext, evidence} <-
           decrypt_all(adapter, capability, public_header, encrypted),
         {:ok, records, manifest, encoded_manifest} <-
           verify_plaintext(plaintext, public_header),
         manifest_hash = :crypto.hash(:sha256, encoded_manifest),
         :ok <- verify_evidence(evidence, manifest_hash, manifest_tag) do
      {:ok,
       %Verified{
         manifest: manifest,
         records: records,
         manifest_hash: manifest_hash,
         manifest_tag: manifest_tag
       }}
    else
      {:error, %Error{code: :storage_unavailable} = error} -> {:error, error}
      {:error, %Error{code: :invalid} = error} -> {:error, error}
      _invalid -> backup_invalid()
    end
  end

  @doc """
  Replays an authenticated source through a bounded reducer.

  Reducer events are provisional until this function returns `{:ok, accumulator}`:
  the source is re-authenticated only at the end of the pass. Reducers must keep
  every effect reversible (for example, database writes in an uncommitted
  transaction and filesystem writes in unpublished stages). Irreversible
  publication from a reducer is forbidden.
  """
  @spec reduce_verified(Verified.t(), term(), (term(), term() -> {:ok, term()})) ::
          {:ok, term()} | {:error, Error.t()}
  def reduce_verified(
        %Verified{replay: %Replay{} = replay} = verified,
        accumulator,
        reducer
      )
      when is_function(reducer, 2) do
    result = replay_snapshot(verified, replay, accumulator, reducer)

    case close_snapshot(replay) do
      :ok -> result
      {:error, %Error{}} = error -> error
    end
  end

  def reduce_verified(%Verified{records: records}, accumulator, reducer)
      when is_list(records) and is_function(reducer, 2) do
    Enum.reduce_while(records, {:ok, accumulator}, fn record, {:ok, acc} ->
      case safe_reduce(reducer, record, acc) do
        {:ok, next_acc} -> {:cont, {:ok, next_acc}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  def reduce_verified(_verified, _accumulator, _reducer), do: invalid()

  @spec discard_verified(Verified.t()) :: :ok | {:error, Error.t()}
  def discard_verified(%Verified{replay: %Replay{} = replay}), do: close_snapshot(replay)
  def discard_verified(%Verified{}), do: :ok
  def discard_verified(_verified), do: invalid()

  @spec stream_verified(Verified.t(), (map() -> :ok)) :: :ok | {:error, Error.t()}
  def stream_verified(%Verified{replay: %Replay{}}, _consumer), do: invalid()

  def stream_verified(%Verified{records: records}, consumer)
      when is_list(records) and is_function(consumer, 1) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case consumer.(record) do
        :ok -> {:cont, :ok}
        _invalid -> {:halt, invalid()}
      end
    end)
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  def stream_verified(_verified, _consumer), do: invalid()

  defp crypto_option(options) when is_list(options) do
    if Keyword.keyword?(options) do
      case Keyword.fetch(options, :crypto) do
        {:ok, {adapter, capability}} when is_atom(adapter) ->
          if Code.ensure_loaded?(adapter) and
               (function_exported?(adapter, :decrypt_all, 3) or bounded_crypto?(adapter)) do
            {:ok, adapter, capability}
          else
            invalid()
          end

        _invalid ->
          invalid()
      end
    else
      invalid()
    end
  end

  defp crypto_option(_options), do: invalid()

  defp bounded_option(source, options, adapter) do
    case Keyword.fetch(options, :verifier) do
      {:ok, {verifier, argument}} ->
        if bounded_source?(source) and bounded_crypto?(adapter) and
             verifier_callbacks?(verifier) do
          {:ok, {verifier, argument}}
        else
          invalid()
        end

      :error ->
        :legacy

      _invalid ->
        invalid()
    end
  end

  defp bounded_crypto?(adapter) do
    Code.ensure_loaded?(adapter) and
      function_exported?(adapter, :header_size, 0) and
      function_exported?(adapter, :init_decrypt, 3) and
      function_exported?(adapter, :decrypt_record, 2) and
      function_exported?(adapter, :finalize_decrypt, 3)
  end

  defp verifier_callbacks?(verifier) when is_atom(verifier) and not is_nil(verifier) do
    Code.ensure_loaded?(verifier) and
      function_exported?(verifier, :init, 1) and
      function_exported?(verifier, :handle_event, 2) and
      function_exported?(verifier, :finish, 2)
  end

  defp verifier_callbacks?({verifier, _context})
       when is_atom(verifier) and not is_nil(verifier) do
    Code.ensure_loaded?(verifier) and
      function_exported?(verifier, :init, 2) and
      function_exported?(verifier, :handle_event, 3) and
      function_exported?(verifier, :finish, 3)
  end

  defp verifier_callbacks?(_verifier), do: false

  defp bounded_source?(%{file_system: file_system, path: path})
       when is_map(file_system) and is_binary(path) and path != "" do
    Enum.all?(
      [open_snapshot: 2, pread: 3, verify_snapshot: 2, close_snapshot: 1],
      fn {callback, arity} ->
        case Map.get(file_system, callback) do
          function when is_function(function, arity) -> true
          _missing -> false
        end
      end
    )
  end

  defp bounded_source?(_source), do: false

  defp authenticate_bounded(
         %{file_system: file_system, path: path},
         adapter,
         capability,
         verifier
       ) do
    case safe_file_system_call(file_system.open_snapshot, [path, @max_outer_bundle_bytes]) do
      {:ok, snapshot, %{size: source_size}} ->
        replay = %Replay{
          crypto: {adapter, capability},
          file_system: file_system,
          public_header: nil,
          snapshot: snapshot,
          source_sha256: nil,
          source_size: source_size,
          verifier: verifier
        }

        if is_integer(source_size) and source_size in 1..@max_outer_bundle_bytes do
          authenticate_opened_snapshot(replay, adapter)
        else
          close_after_authentication_failure(replay, backup_invalid())
        end

      {:error, :max_bytes_exceeded} ->
        backup_invalid()

      {:error, %Error{} = error} ->
        {:error, error}

      _invalid ->
        storage_unavailable()
    end
  end

  defp authenticate_opened_snapshot(replay, adapter) do
    case run_snapshot_pass(replay, nil, nil) do
      {:ok,
       %{
         accumulator: nil,
         authentication: authentication,
         cut: cut,
         manifest: manifest,
         manifest_hash: manifest_hash,
         manifest_tag: manifest_tag,
         public_header: public_header,
         replay_capability: replay_capability,
         source_sha256: source_sha256
       }}
      when replay_capability != :replayed ->
        replay = %{
          replay
          | crypto: {adapter, replay_capability},
            public_header: public_header,
            source_sha256: source_sha256
        }

        {:ok,
         %Verified{
           authentication: Map.drop(authentication, [:encoded_manifest]),
           cut: cut,
           manifest: manifest,
           manifest_hash: manifest_hash,
           manifest_tag: manifest_tag,
           records: [],
           replay: replay
         }}

      {:ok, _invalid} ->
        close_after_authentication_failure(replay, backup_invalid())

      {:error, %Error{}} = error ->
        close_after_authentication_failure(replay, error)
    end
  end

  defp replay_snapshot(verified, replay, accumulator, reducer) do
    with :ok <- verify_replay_source(replay),
         result <- run_snapshot_pass(replay, accumulator, reducer) do
      case result do
        {:ok,
         %{
           accumulator: accumulator,
           authentication: authentication,
           cut: cut,
           manifest: manifest,
           manifest_hash: manifest_hash,
           manifest_tag: manifest_tag,
           public_header: public_header,
           replay_capability: :replayed,
           source_sha256: source_sha256
         }} ->
          if manifest == verified.manifest and manifest_hash == verified.manifest_hash and
               manifest_tag == verified.manifest_tag and public_header == replay.public_header and
               source_sha256 == replay.source_sha256 and cut == verified.cut and
               fixed_authentication(authentication) ==
                 fixed_authentication(verified.authentication) do
            {:ok, accumulator}
          else
            backup_invalid()
          end

        {:ok, _invalid} ->
          backup_invalid()

        {:error, %Error{}} = error ->
          error
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp verify_replay_source(%Replay{} = replay) do
    with :ok <-
           safe_file_system_call(
             replay.file_system.verify_snapshot,
             [replay.snapshot, replay.source_size]
           ),
         {:ok, source_sha256} <- snapshot_sha256(replay),
         true <- source_sha256 == replay.source_sha256,
         :ok <-
           safe_file_system_call(
             replay.file_system.verify_snapshot,
             [replay.snapshot, replay.source_size]
           ) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp run_snapshot_pass(%Replay{} = replay, accumulator, reducer) do
    {adapter, capability} = replay.crypto

    with {:ok, public_header, encrypted_offset, source_hash} <- read_snapshot_prelude(replay),
         true <- is_nil(replay.public_header) or replay.public_header == public_header,
         encrypted_size = replay.source_size - encrypted_offset,
         true <- encrypted_size > 0 and encrypted_size <= @max_encrypted_bundle_bytes,
         {:ok, crypto_header_size} <- crypto_header_size(adapter),
         true <- encrypted_size >= crypto_header_size + 68,
         {:ok, crypto_header} <-
           read_exact(replay.file_system, replay.snapshot, encrypted_offset, crypto_header_size),
         {:ok, source_hash} <- update_hash(source_hash, crypto_header),
         {:ok, decrypt_state} <-
           safe_crypto_call(adapter, :init_decrypt, [capability, public_header, crypto_header]),
         {:ok, parser} <-
           init_frame_parser(replay.verifier, reducer, accumulator, public_header),
         {:ok, result} <-
           read_encrypted_records(
             replay,
             adapter,
             decrypt_state,
             parser,
             encrypted_offset + crypto_header_size,
             replay.source_size,
             0,
             source_hash,
             :crypto.hash_init(:sha256),
             :crypto.hash_init(:sha256)
           ) do
      {:ok, Map.put(result, :public_header, public_header)}
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp read_snapshot_prelude(replay) do
    with true <- replay.source_size >= @outer_header_bytes,
         {:ok, encoded_header} <-
           read_exact(replay.file_system, replay.snapshot, 0, @outer_header_bytes),
         <<@magic, @format_version::unsigned-big-16, header_size::unsigned-big-32>> <-
           encoded_header,
         true <- header_size in 1..@max_public_header_bytes,
         encrypted_offset = @outer_header_bytes + header_size,
         true <- encrypted_offset < replay.source_size,
         {:ok, public_header_bytes} <-
           read_exact(
             replay.file_system,
             replay.snapshot,
             @outer_header_bytes,
             header_size
           ),
         {:ok, public_header} <- decode_public_header(public_header_bytes),
         {:ok, source_hash} <-
           update_hash(:crypto.hash_init(:sha256), encoded_header <> public_header_bytes) do
      {:ok, public_header, encrypted_offset, source_hash}
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp crypto_header_size(adapter) do
    case safe_crypto_call(adapter, :header_size, []) do
      size when is_integer(size) and size > 0 and size <= @max_public_header_bytes -> {:ok, size}
      _invalid -> backup_invalid()
    end
  end

  defp read_encrypted_records(
         replay,
         adapter,
         decrypt_state,
         parser,
         offset,
         source_size,
         index,
         source_hash,
         encrypted_records_hash,
         encrypted_record_sizes_hash
       )
       when index <= @max_encrypted_records and offset + 8 <= source_size do
    with {:ok, record_header} <-
           read_exact(replay.file_system, replay.snapshot, offset, 8),
         <<counter::unsigned-big-32, payload_size::unsigned-big-32>> <- record_header do
      case counter do
        0xFFFFFFFF ->
          finalize_snapshot_pass(
            replay,
            adapter,
            decrypt_state,
            parser,
            offset,
            source_size,
            payload_size,
            source_hash,
            encrypted_records_hash,
            encrypted_record_sizes_hash
          )

        ^index when index < @max_encrypted_records and payload_size in 1..4_194_304 ->
          record_size = 8 + payload_size + 16
          next_offset = offset + record_size

          with true <- next_offset < source_size,
               :ok <-
                 validate_canonical_record_position(
                   replay,
                   payload_size,
                   next_offset,
                   source_size
                 ),
               {:ok, record} <-
                 read_exact(replay.file_system, replay.snapshot, offset, record_size),
               {:ok, source_hash} <- update_hash(source_hash, record),
               {:ok, encrypted_records_hash, encrypted_record_sizes_hash} <-
                 update_encrypted_record_hashes(
                   encrypted_records_hash,
                   encrypted_record_sizes_hash,
                   index,
                   payload_size,
                   record
                 ),
               {:ok, plaintext, next_decrypt_state} <-
                 safe_crypto_call(adapter, :decrypt_record, [decrypt_state, record]),
               true <- is_binary(plaintext) and byte_size(plaintext) == payload_size,
               {:ok, next_parser} <- feed_plaintext(parser, plaintext) do
            read_encrypted_records(
              replay,
              adapter,
              next_decrypt_state,
              next_parser,
              next_offset,
              source_size,
              index + 1,
              source_hash,
              encrypted_records_hash,
              encrypted_record_sizes_hash
            )
          else
            {:error, %Error{}} = error -> error
            _invalid -> backup_invalid()
          end

        _invalid ->
          backup_invalid()
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp read_encrypted_records(
         _replay,
         _adapter,
         _decrypt_state,
         _parser,
         _offset,
         _source_size,
         _index,
         _source_hash,
         _encrypted_records_hash,
         _encrypted_record_sizes_hash
       ),
       do: backup_invalid()

  defp finalize_snapshot_pass(
         replay,
         adapter,
         decrypt_state,
         parser,
         offset,
         source_size,
         44,
         source_hash,
         encrypted_records_hash,
         encrypted_record_sizes_hash
       )
       when offset + 68 == source_size do
    with {:ok, final_record} <-
           read_exact(replay.file_system, replay.snapshot, offset, 68),
         {:ok, source_hash} <- update_hash(source_hash, final_record),
         {:ok, encrypted_records_hash, encrypted_record_sizes_hash} <-
           update_encrypted_record_hashes(
             encrypted_records_hash,
             encrypted_record_sizes_hash,
             0xFFFFFFFF,
             44,
             final_record
           ),
         {:ok, source_sha256} <- finish_hash(source_hash),
         {:ok, encrypted_records_sha256} <- finish_hash(encrypted_records_hash),
         {:ok, encrypted_record_sizes_sha256} <- finish_hash(encrypted_record_sizes_hash),
         {:ok, manifest_tag} <- ChunkedAEAD.final_tag(final_record),
         {:ok, parsed} <- finish_frame_parser(parser, manifest_tag),
         :ok <-
           safe_file_system_call(
             replay.file_system.verify_snapshot,
             [replay.snapshot, replay.source_size]
           ),
         evidence = %{
           encoded_manifest: parsed.encoded_manifest,
           encrypted_record_sizes_sha256: encrypted_record_sizes_sha256,
           encrypted_records_sha256: encrypted_records_sha256,
           frame_count: parsed.frame_count,
           frame_digest: parsed.frame_digest,
           manifest_hash: parsed.manifest_hash,
           manifest_tag: manifest_tag,
           source_sha256: source_sha256
         },
         {:ok, authentication, replay_capability} <-
           safe_crypto_call(adapter, :finalize_decrypt, [decrypt_state, final_record, evidence]),
         true <- valid_bounded_authentication?(authentication, evidence) do
      {:ok,
       %{
         accumulator: parsed.accumulator,
         authentication: authentication,
         cut: parsed.cut,
         manifest: parsed.manifest,
         manifest_hash: parsed.manifest_hash,
         manifest_tag: manifest_tag,
         replay_capability: replay_capability,
         source_sha256: source_sha256
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp finalize_snapshot_pass(
         _replay,
         _adapter,
         _decrypt_state,
         _parser,
         _offset,
         _source_size,
         _payload_size,
         _source_hash,
         _encrypted_records_hash,
         _encrypted_record_sizes_hash
       ),
       do: backup_invalid()

  defp validate_canonical_record_position(replay, payload_size, next_offset, source_size) do
    with {:ok, next_header} <-
           read_exact(replay.file_system, replay.snapshot, next_offset, 8),
         <<next_counter::unsigned-big-32, next_payload_size::unsigned-big-32>> <- next_header,
         true <-
           payload_size == 4_194_304 or
             (next_counter == 0xFFFFFFFF and next_payload_size == 44 and
                next_offset + 68 == source_size) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp update_encrypted_record_hashes(
         encrypted_records_hash,
         encrypted_record_sizes_hash,
         counter,
         payload_size,
         record
       ) do
    record_sha256 = :crypto.hash(:sha256, record)

    with {:ok, encrypted_records_hash} <-
           update_hash(
             encrypted_records_hash,
             <<counter::unsigned-big-32, payload_size::unsigned-big-64,
               record_sha256::binary-size(32)>>
           ),
         {:ok, encrypted_record_sizes_hash} <-
           update_hash(
             encrypted_record_sizes_hash,
             <<counter::unsigned-big-32, payload_size::unsigned-big-64>>
           ) do
      {:ok, encrypted_records_hash, encrypted_record_sizes_hash}
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  rescue
    ArgumentError -> backup_invalid()
  end

  defp valid_bounded_authentication?(authentication, evidence) when is_map(authentication) do
    Map.get(authentication, :manifest_hash) == evidence.manifest_hash and
      Map.get(authentication, :manifest_tag) == evidence.manifest_tag and
      Map.get(authentication, :frame_count) == evidence.frame_count and
      Map.get(authentication, :frame_digest) == evidence.frame_digest and
      Map.get(authentication, :encrypted_record_sizes_sha256) ==
        evidence.encrypted_record_sizes_sha256 and
      Map.get(authentication, :encrypted_records_sha256) == evidence.encrypted_records_sha256 and
      Map.get(authentication, :source_sha256) == evidence.source_sha256 and
      match?(<<_::binary-size(32)>>, Map.get(authentication, :plaintext_sha256))
  end

  defp valid_bounded_authentication?(_authentication, _evidence), do: false

  defp fixed_authentication(authentication) when is_map(authentication),
    do:
      Map.take(authentication, [
        :chunk_count,
        :encrypted_record_sizes_sha256,
        :encrypted_records_sha256,
        :frame_count,
        :frame_digest,
        :manifest_hash,
        :manifest_tag,
        :plaintext_bytes,
        :plaintext_sha256,
        :proof,
        :source_sha256
      ])

  defp fixed_authentication(_authentication), do: nil

  defp close_after_authentication_failure(replay, error) do
    case close_snapshot(replay) do
      :ok -> error
      {:error, %Error{}} = close_error -> close_error
    end
  end

  defp close_snapshot(%Replay{} = replay) do
    case safe_file_system_call(replay.file_system.close_snapshot, [replay.snapshot]) do
      :ok -> :ok
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  end

  defp read_exact(file_system, snapshot, offset, count),
    do: read_exact(file_system, snapshot, offset, count, [])

  defp read_exact(_file_system, _snapshot, _offset, 0, chunks),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_exact(file_system, snapshot, offset, remaining, chunks) do
    case safe_file_system_call(file_system.pread, [snapshot, offset, remaining]) do
      {:ok, bytes} when is_binary(bytes) and bytes != "" and byte_size(bytes) <= remaining ->
        read_exact(
          file_system,
          snapshot,
          offset + byte_size(bytes),
          remaining - byte_size(bytes),
          [bytes | chunks]
        )

      {:error, %Error{}} = error ->
        error

      _invalid ->
        backup_invalid()
    end
  end

  defp snapshot_sha256(%Replay{} = replay) do
    snapshot_sha256(
      replay.file_system,
      replay.snapshot,
      0,
      replay.source_size,
      :crypto.hash_init(:sha256)
    )
  end

  defp snapshot_sha256(_file_system, _snapshot, offset, offset, hash), do: finish_hash(hash)

  defp snapshot_sha256(file_system, snapshot, offset, source_size, hash)
       when offset < source_size do
    count = min(@reader_chunk_bytes, source_size - offset)

    with {:ok, bytes} <- read_exact(file_system, snapshot, offset, count),
         {:ok, hash} <- update_hash(hash, bytes) do
      snapshot_sha256(file_system, snapshot, offset + count, source_size, hash)
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp init_frame_parser({verifier, argument}, reducer, accumulator, public_header) do
    with {:ok, verifier_state} <- safe_verifier_call(verifier, :init, [argument]) do
      {:ok,
       %{
         accumulator: accumulator,
         current: nil,
         frame_count: 0,
         frame_hash: :crypto.hash_init(:sha256),
         header: "",
         manifest: nil,
         manifest_complete?: false,
         public_header: public_header,
         reducer: reducer,
         verifier: verifier,
         verifier_state: verifier_state
       }}
    else
      _invalid -> backup_invalid()
    end
  end

  defp feed_plaintext(%{current: %{remaining: 0}} = parser, plaintext) do
    with {:ok, parser} <- finish_frame(parser) do
      feed_plaintext(parser, plaintext)
    end
  end

  defp feed_plaintext(parser, ""), do: {:ok, parser}

  defp feed_plaintext(%{manifest_complete?: true}, _plaintext), do: backup_invalid()

  defp feed_plaintext(%{current: nil, header: header} = parser, plaintext)
       when byte_size(header) < 10 do
    wanted = 10 - byte_size(header)
    taken = min(wanted, byte_size(plaintext))
    <<prefix::binary-size(taken), rest::binary>> = plaintext
    parser = %{parser | header: header <> prefix}

    if byte_size(parser.header) == 10 do
      with {:ok, parser} <- start_frame(parser) do
        feed_plaintext(parser, rest)
      end
    else
      {:ok, parser}
    end
  end

  defp feed_plaintext(%{current: current} = parser, plaintext) when is_map(current) do
    taken = min(current.remaining, min(byte_size(plaintext), @reader_chunk_bytes))
    <<chunk::binary-size(taken), rest::binary>> = plaintext

    with {:ok, parser} <- consume_frame_chunk(parser, chunk) do
      feed_plaintext(parser, rest)
    end
  end

  defp start_frame(%{header: <<type::unsigned-big-16, payload_length::unsigned-big-64>>} = parser) do
    cond do
      type == @manifest_record_type and is_nil(parser.manifest) and
          payload_length in 1..@max_manifest_bytes ->
        {:ok,
         %{
           parser
           | current: %{
               chunks: [],
               hash: :crypto.hash_init(:sha256),
               manifest?: true,
               payload_length: payload_length,
               remaining: payload_length,
               type: type
             },
             header: ""
         }}

      type != @manifest_record_type and parser.frame_count < @max_frames - 1 and
          payload_length <= @max_encrypted_bundle_bytes ->
        event = {:record_start, type, payload_length}

        with {:ok, parser} <- emit_parser_event(parser, event) do
          {:ok,
           %{
             parser
             | current: %{
                 chunks: [],
                 hash: :crypto.hash_init(:sha256),
                 manifest?: false,
                 payload_length: payload_length,
                 remaining: payload_length,
                 type: type
               },
               header: ""
           }}
        end

      true ->
        backup_invalid()
    end
  end

  defp consume_frame_chunk(parser, ""), do: {:ok, parser}

  defp consume_frame_chunk(%{current: current} = parser, chunk)
       when is_binary(chunk) and chunk != "" and byte_size(chunk) <= current.remaining do
    with {:ok, hash} <- update_hash(current.hash, chunk),
         {:ok, parser} <- maybe_emit_frame_chunk(parser, current.manifest?, chunk) do
      chunks = if current.manifest?, do: [chunk | current.chunks], else: current.chunks

      {:ok,
       %{
         parser
         | current: %{
             current
             | chunks: chunks,
               hash: hash,
               remaining: current.remaining - byte_size(chunk)
           }
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp maybe_emit_frame_chunk(parser, true, _chunk), do: {:ok, parser}

  defp maybe_emit_frame_chunk(parser, false, chunk),
    do: emit_parser_event(parser, {:record_chunk, chunk})

  defp finish_frame(%{current: %{manifest?: true, remaining: 0} = current} = parser) do
    encoded_manifest = current.chunks |> Enum.reverse() |> IO.iodata_to_binary()

    if byte_size(encoded_manifest) == current.payload_length do
      {:ok,
       %{
         parser
         | current: nil,
           manifest: encoded_manifest,
           manifest_complete?: true
       }}
    else
      backup_invalid()
    end
  end

  defp finish_frame(%{current: %{manifest?: false, remaining: 0} = current} = parser) do
    with {:ok, payload_hash} <- finish_hash(current.hash),
         {:ok, parser} <- emit_parser_event(parser, :record_end),
         {:ok, frame_hash} <-
           update_inventory_hash(
             parser.frame_hash,
             parser.frame_count,
             current.type,
             current.payload_length,
             payload_hash
           ) do
      {:ok,
       %{
         parser
         | current: nil,
           frame_count: parser.frame_count + 1,
           frame_hash: frame_hash
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp finish_frame(_parser), do: backup_invalid()

  defp emit_parser_event(parser, event) do
    with {:ok, verifier_state} <-
           safe_verifier_call(parser.verifier, :handle_event, [parser.verifier_state, event]),
         {:ok, accumulator} <- maybe_reduce(parser.reducer, event, parser.accumulator) do
      {:ok, %{parser | accumulator: accumulator, verifier_state: verifier_state}}
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp maybe_reduce(nil, _event, accumulator), do: {:ok, accumulator}
  defp maybe_reduce(reducer, event, accumulator), do: safe_reduce(reducer, event, accumulator)

  defp finish_frame_parser(
         %{
           current: nil,
           header: "",
           manifest: encoded_manifest,
           manifest_complete?: true
         } = parser,
         _manifest_tag
       )
       when is_binary(encoded_manifest) do
    with {:ok, manifest} <- Manifest.decode(encoded_manifest),
         {:ok, ^encoded_manifest} <- Manifest.encode(manifest),
         true <- Map.get(parser.public_header, :version) == manifest.version,
         true <- Map.get(parser.public_header, :manifest_id) == manifest.manifest_id,
         true <- parser.frame_count == length(manifest.inventory),
         {:ok, frame_digest} <- finish_hash(parser.frame_hash),
         {:ok, manifest_digest} <- manifest_inventory_digest(manifest.inventory),
         true <- frame_digest == manifest_digest,
         {:ok, cut} <-
           safe_verifier_call(parser.verifier, :finish, [parser.verifier_state, manifest]) do
      {:ok,
       %{
         accumulator: parser.accumulator,
         cut: cut,
         encoded_manifest: encoded_manifest,
         frame_count: parser.frame_count,
         frame_digest: frame_digest,
         manifest: manifest,
         manifest_hash: :crypto.hash(:sha256, encoded_manifest)
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> backup_invalid()
    end
  end

  defp finish_frame_parser(_parser, _manifest_tag), do: backup_invalid()

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

  defp update_inventory_hash(hash, position, type, payload_length, payload_hash) do
    update_hash(
      hash,
      <<position::unsigned-big-64, type::unsigned-big-16, payload_length::unsigned-big-64,
        payload_hash::binary-size(32)>>
    )
  rescue
    ArgumentError -> backup_invalid()
  end

  defp update_hash(hash, bytes) do
    {:ok, :crypto.hash_update(hash, bytes)}
  rescue
    ArgumentError -> backup_invalid()
  catch
    :error, _reason -> backup_invalid()
  end

  defp finish_hash(hash) do
    case :crypto.hash_final(hash) do
      <<_::binary-size(32)>> = digest -> {:ok, digest}
      _invalid -> backup_invalid()
    end
  rescue
    ArgumentError -> backup_invalid()
  catch
    :error, _reason -> backup_invalid()
  end

  defp safe_reduce(reducer, event, accumulator) do
    case reducer.(event, accumulator) do
      {:ok, _next} = ok -> ok
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  rescue
    _exception -> invalid()
  catch
    _kind, _reason -> invalid()
  end

  defp safe_crypto_call(adapter, function, arguments) do
    apply(adapter, function, arguments)
  rescue
    _exception -> backup_invalid()
  catch
    _kind, _reason -> backup_invalid()
  end

  defp safe_verifier_call(verifier, function, arguments) do
    call_adapter(verifier, function, arguments)
  rescue
    _exception -> backup_invalid()
  catch
    _kind, _reason -> backup_invalid()
  end

  defp safe_file_system_call(function, arguments) do
    apply(function, arguments)
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [context | arguments])

  defp read_source(%{file_system: file_system, path: path})
       when is_map(file_system) and is_binary(path) and path != "" do
    case Map.fetch(file_system, :read) do
      {:ok, read} when is_function(read, 2) ->
        case safe_file_read(read, path, @max_outer_bundle_bytes) do
          {:ok, binary}
          when is_binary(binary) and byte_size(binary) <= @max_outer_bundle_bytes ->
            {:ok, binary}

          {:error, :max_bytes_exceeded} ->
            backup_invalid()

          {:ok, binary} when is_binary(binary) ->
            backup_invalid()

          _error ->
            storage_unavailable()
        end

      _invalid ->
        invalid()
    end
  end

  defp read_source(_source), do: invalid()

  defp read_source_prefix(%{file_system: file_system, path: path})
       when is_map(file_system) and is_binary(path) and path != "" do
    case Map.fetch(file_system, :read_prefix) do
      {:ok, read_prefix} when is_function(read_prefix, 2) ->
        case safe_file_read(read_prefix, path, @max_public_prelude_bytes) do
          {:ok, binary}
          when is_binary(binary) and byte_size(binary) <= @max_public_prelude_bytes ->
            {:ok, binary}

          {:ok, binary} when is_binary(binary) ->
            backup_invalid()

          _error ->
            storage_unavailable()
        end

      _invalid ->
        invalid()
    end
  end

  defp read_source_prefix(_source), do: invalid()

  defp safe_file_read(read, path, max_bytes) do
    read.(path, max_bytes)
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp parse_prelude(
         <<@magic, @format_version::unsigned-big-16, header_size::unsigned-big-32, rest::binary>>
       )
       when header_size > 0 and header_size <= @max_public_header_bytes and
              header_size <= byte_size(rest) do
    <<encoded_header::binary-size(header_size), encrypted::binary>> = rest

    with true <- encrypted != "" and byte_size(encrypted) <= @max_encrypted_bundle_bytes,
         {:ok, public_header} <- decode_public_header(encoded_header) do
      {:ok, public_header, encrypted}
    else
      _invalid -> backup_invalid()
    end
  end

  defp parse_prelude(_encoded), do: backup_invalid()

  defp parse_public_header_prefix(
         <<@magic, @format_version::unsigned-big-16, header_size::unsigned-big-32, rest::binary>>
       )
       when header_size > 0 and header_size <= @max_public_header_bytes and
              header_size <= byte_size(rest) do
    <<encoded_header::binary-size(header_size), _remainder::binary>> = rest
    decode_public_header(encoded_header)
  end

  defp parse_public_header_prefix(_encoded), do: backup_invalid()

  defp decode_public_header(<<131, tag, _rest::binary>> = encoded) when tag != 80 do
    case :erlang.binary_to_term(encoded, [:safe, :used]) do
      {public_header, consumed}
      when is_map(public_header) and consumed == byte_size(encoded) ->
        canonical = :erlang.term_to_binary(public_header, [:deterministic])

        if canonical == encoded, do: {:ok, public_header}, else: backup_invalid()

      _invalid ->
        backup_invalid()
    end
  rescue
    ArgumentError -> backup_invalid()
  end

  defp decode_public_header(_encoded), do: backup_invalid()

  defp decrypt_all(adapter, capability, public_header, encrypted) do
    case safe_decrypt(adapter, capability, public_header, encrypted) do
      {:ok, plaintext, %{manifest_tag: <<_::binary-size(16)>>} = evidence}
      when is_binary(plaintext) and plaintext != "" and
             byte_size(plaintext) <= @max_encrypted_bundle_bytes ->
        {:ok, plaintext, evidence}

      _invalid ->
        backup_invalid()
    end
  end

  defp encrypted_manifest_tag(encrypted)
       when is_binary(encrypted) and byte_size(encrypted) >= 68 do
    final_record = binary_part(encrypted, byte_size(encrypted) - 68, 68)
    ChunkedAEAD.final_tag(final_record)
  end

  defp encrypted_manifest_tag(_encrypted), do: backup_invalid()

  defp safe_decrypt(adapter, capability, public_header, encrypted) do
    apply(adapter, :decrypt_all, [capability, public_header, encrypted])
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp verify_plaintext(plaintext, public_header) do
    with {:ok, frames} <- decode_frames(plaintext, [], 0),
         {:ok, records, encoded_manifest} <- split_manifest(frames),
         {:ok, manifest} <- Manifest.decode(encoded_manifest),
         {:ok, ^encoded_manifest} <- Manifest.encode(manifest),
         true <- Map.get(public_header, :version) == manifest.version,
         true <- Map.get(public_header, :manifest_id) == manifest.manifest_id,
         :ok <- Manifest.verify(manifest, records) do
      {:ok, records, manifest, encoded_manifest}
    else
      _invalid -> backup_invalid()
    end
  end

  defp decode_frames("", frames, _count), do: {:ok, Enum.reverse(frames)}

  defp decode_frames(
         <<type::unsigned-big-16, payload_length::unsigned-big-64, rest::binary>>,
         frames,
         count
       )
       when count < @max_frames and payload_length <= byte_size(rest) do
    <<payload::binary-size(payload_length), remaining::binary>> = rest
    decode_frames(remaining, [%{type: type, payload: payload} | frames], count + 1)
  end

  defp decode_frames(_invalid, _frames, _count), do: backup_invalid()

  defp verify_evidence(
         %{
           manifest_hash: <<_::binary-size(32)>> = manifest_hash,
           manifest_tag: <<_::binary-size(16)>> = manifest_tag
         },
         manifest_hash,
         manifest_tag
       ),
       do: :ok

  defp verify_evidence(_evidence, _manifest_hash, _manifest_tag), do: backup_invalid()

  defp split_manifest(frames) do
    case List.pop_at(frames, -1) do
      {%{type: @manifest_record_type, payload: encoded_manifest}, records} ->
        if Enum.all?(records, &(&1.type != @manifest_record_type)) do
          {:ok, records, encoded_manifest}
        else
          backup_invalid()
        end

      _invalid ->
        backup_invalid()
    end
  end

  defp invalid, do: {:error, Error.new(:invalid)}
  defp backup_invalid, do: {:error, Error.new(:backup_invalid)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable)}
end
