defmodule Singularity.Storage.Crypto.ChunkedAEAD do
  @moduledoc """
  Versioned, all-or-nothing chunked AES-256-GCM object codec.

  The encryption API emits a canonical header, one authenticated record per
  canonical four MiB plaintext chunk, and a reserved final metadata record.
  Its opaque state retains at most one pending transport fragment smaller than
  the canonical chunk size.

  `decode/2` authenticates the canonical header, every ordered data record,
  and the final encrypted metadata record before returning any plaintext.
  """

  alias Singularity.Storage.Crypto.Format

  defmodule EncryptState do
    @moduledoc false

    @enforce_keys [
      :version,
      :phase,
      :header,
      :context,
      :key,
      :nonce_prefix,
      :counter,
      :chunk_count,
      :plaintext_bytes,
      :plaintext_hash,
      :pending_plaintext,
      :generation_token
    ]
    defstruct @enforce_keys

    @opaque t :: %__MODULE__{
              version: 1,
              phase: :open | :finalized,
              header: binary(),
              context: map(),
              key: binary() | nil,
              nonce_prefix: binary(),
              counter: non_neg_integer(),
              chunk_count: non_neg_integer(),
              plaintext_bytes: non_neg_integer(),
              plaintext_hash: reference() | nil,
              pending_plaintext: binary(),
              generation_token: reference() | nil
            }
  end

  defimpl Inspect, for: EncryptState do
    import Inspect.Algebra

    def inspect(state, opts) do
      progress = [
        phase: state |> Map.get(:phase, :invalid) |> safe_phase(),
        counter: state |> Map.get(:counter, :invalid) |> safe_integer(),
        chunk_count: state |> Map.get(:chunk_count, :invalid) |> safe_integer(),
        plaintext_bytes: state |> Map.get(:plaintext_bytes, :invalid) |> safe_integer(),
        pending_bytes:
          state
          |> Map.get(:pending_plaintext, :invalid)
          |> safe_pending_bytes()
      ]

      concat(["#ChunkedAEAD.EncryptState<", to_doc(progress, opts), ">"])
    end

    defp safe_phase(phase) when phase in [:open, :finalized], do: phase
    defp safe_phase(_phase), do: :invalid

    defp safe_integer(value) when is_integer(value) and value >= 0, do: value
    defp safe_integer(_value), do: :invalid

    defp safe_pending_bytes(pending) when is_binary(pending), do: byte_size(pending)
    defp safe_pending_bytes(_pending), do: :invalid
  end

  @chunk_size 4_194_304
  @tag_size 16
  @final_plaintext_size 44
  @final_counter 0xFFFFFFFF
  @max_plaintext_bytes 0xFFFFFFFFFFFFFFFF
  @header_context_keys [
    :format_version,
    :algorithm,
    :chunk_size,
    :nonce_prefix,
    :vault_id,
    :encryption_domain_id,
    :object_id,
    :chunk_index
  ]

  @type encrypt_error ::
          :already_finalized
          | :chunk_count_overflow
          | :invalid_chunk
          | :invalid_format
          | :plaintext_size_overflow
          | :state_consumed

  @type encryption_summary :: %{
          plaintext_bytes: non_neg_integer(),
          chunk_count: non_neg_integer(),
          plaintext_sha256: <<_::256>>
        }

  @spec encode(map()) :: {:ok, binary()} | {:error, atom()}
  def encode(%{key: <<_::binary-size(32)>>, plaintext: plaintext, chunk_index: 0} = context)
      when is_binary(plaintext) do
    with {:ok, header, state} <- init_encrypt(context),
         {:ok, records, state} <- encrypt_plaintext(plaintext, state),
         {:ok, final, _summary, _finalized_state} <- finalize(state) do
      {:ok, IO.iodata_to_binary([header, records, final])}
    end
  end

  def encode(_context), do: {:error, :invalid_format}

  @doc false
  @spec encode_vector(map(), binary()) :: {:ok, binary()} | {:error, atom()}
  def encode_vector(
        %{key: <<_::binary-size(32)>>, plaintext: plaintext, chunk_index: 0} = context,
        <<_::binary-size(8)>> = nonce_prefix
      )
      when is_binary(plaintext) do
    with {:ok, header, state} <- init_encrypt_vector(context, nonce_prefix),
         {:ok, records, state} <- encrypt_plaintext(plaintext, state),
         {:ok, final, _summary, _finalized_state} <- finalize(state) do
      {:ok, IO.iodata_to_binary([header, records, final])}
    end
  end

  def encode_vector(_context, _nonce_prefix), do: {:error, :invalid_format}

  @doc """
  Starts a bounded streaming encryption and owns a fresh nonce prefix.

  The returned header must be written before records emitted by
  `encrypt_chunk/2`.
  """
  @spec init_encrypt(map()) ::
          {:ok, binary(), EncryptState.t()} | {:error, :invalid_format}
  def init_encrypt(%{key: <<_::binary-size(32)>> = key, chunk_index: 0} = context) do
    init_encrypt(context, key, :crypto.strong_rand_bytes(8))
  end

  def init_encrypt(_context), do: {:error, :invalid_format}

  @doc false
  @spec init_encrypt_vector(map(), binary()) ::
          {:ok, binary(), EncryptState.t()} | {:error, :invalid_format}
  def init_encrypt_vector(
        %{key: <<_::binary-size(32)>> = key, chunk_index: 0} = context,
        <<_::binary-size(8)>> = nonce_prefix
      ) do
    init_encrypt(context, key, nonce_prefix)
  end

  def init_encrypt_vector(_context, _nonce_prefix), do: {:error, :invalid_format}

  @doc """
  Accepts one non-empty binary transport fragment.

  The state buffers fewer than four MiB of pending plaintext and emits zero or
  more complete canonical four MiB authenticated records. The emitted value is
  always a binary; `""` is a successful result and callers should append only
  non-empty output before continuing with the returned one-shot state.
  """
  @spec encrypt_chunk(EncryptState.t(), binary()) ::
          {:ok, binary(), EncryptState.t()} | {:error, encrypt_error()}
  def encrypt_chunk(%EncryptState{phase: :finalized}, _plaintext),
    do: {:error, :already_finalized}

  def encrypt_chunk(state, fragment) do
    with :ok <- validate_open_state(state),
         :ok <- validate_plaintext_fragment(fragment),
         :ok <- ensure_fragment_capacity(state, byte_size(fragment)),
         {:ok, plaintext_bytes} <-
           checked_plaintext_bytes(state.plaintext_bytes, byte_size(fragment)),
         :ok <- consume_generation(state.generation_token),
         {:ok, plaintext_hash} <- update_hash(state.plaintext_hash, fragment),
         {:ok, records, next_state} <- rechunk_fragment(state, fragment) do
      {:ok, IO.iodata_to_binary(records),
       %{
         next_state
         | plaintext_bytes: plaintext_bytes,
           plaintext_hash: plaintext_hash,
           generation_token: new_generation_token()
       }}
    end
  end

  @doc """
  Emits the pending short data record, if present, followed by the reserved
  encrypted final record and returns an in-memory plaintext summary.

  The returned finalized state contains neither the DEK nor the incremental
  hash context or pending plaintext and exists only to make repeated
  finalization fail closed.
  """
  @spec finalize(EncryptState.t()) ::
          {:ok, binary(), encryption_summary(), EncryptState.t()}
          | {:error, encrypt_error()}
  def finalize(%EncryptState{phase: :finalized}), do: {:error, :already_finalized}

  def finalize(state) do
    with :ok <- validate_open_state(state),
         :ok <- ensure_finalize_capacity(state),
         :ok <- consume_generation(state.generation_token),
         {:ok, pending_record, state} <- flush_pending(state),
         {:ok, plaintext_sha256} <- finish_hash(state.plaintext_hash),
         {:ok, final} <- encrypt_final(state, plaintext_sha256) do
      summary = %{
        plaintext_bytes: state.plaintext_bytes,
        chunk_count: state.chunk_count,
        plaintext_sha256: plaintext_sha256
      }

      finalized_state = %{
        state
        | phase: :finalized,
          key: nil,
          plaintext_hash: nil,
          pending_plaintext: "",
          generation_token: nil
      }

      {:ok, IO.iodata_to_binary([pending_record, final]), summary, finalized_state}
    end
  end

  @doc """
  Authenticates and decrypts one complete canonical data record.

  The expected counter and plaintext size are part of the authenticated
  context. Truncated records and records with trailing bytes fail closed.
  """
  @spec decrypt_data_record(binary(), map()) ::
          {:ok, binary()} | {:error, :integrity_failure}
  def decrypt_data_record(
        <<counter::unsigned-big-32, size::unsigned-big-32, ciphertext::binary-size(size),
          tag::binary-size(@tag_size)>>,
        %{
          key: <<_::binary-size(32)>> = key,
          header: <<_::binary-size(66)>> = header,
          nonce_prefix: <<_::binary-size(8)>> = nonce_prefix,
          counter: expected_counter,
          plaintext_size: expected_size
        }
      )
      when counter == expected_counter and counter >= 0 and
             counter <= @final_counter - 1 and size == expected_size and size > 0 and
             size <= @chunk_size do
    decrypt_record(
      ciphertext,
      tag,
      key,
      Format.nonce(nonce_prefix, counter),
      Format.data_aad(header, counter, size)
    )
  end

  def decrypt_data_record(_record, _context), do: {:error, :integrity_failure}

  @doc """
  Authenticates and decrypts the complete reserved final metadata record.
  """
  @spec decrypt_final_record(binary(), map()) ::
          {:ok, encryption_summary()} | {:error, :integrity_failure}
  def decrypt_final_record(
        <<@final_counter::unsigned-big-32, @final_plaintext_size::unsigned-big-32,
          ciphertext::binary-size(@final_plaintext_size), tag::binary-size(@tag_size)>>,
        %{
          key: <<_::binary-size(32)>> = key,
          header: <<_::binary-size(66)>> = header,
          nonce_prefix: <<_::binary-size(8)>> = nonce_prefix
        }
      ) do
    with {:ok,
          <<plaintext_bytes::unsigned-big-64, chunk_count::unsigned-big-32,
            plaintext_sha256::binary-size(32)>>} <-
           decrypt_record(
             ciphertext,
             tag,
             key,
             Format.nonce(nonce_prefix, @final_counter),
             Format.final_aad(header)
           ) do
      {:ok,
       %{
         plaintext_bytes: plaintext_bytes,
         chunk_count: chunk_count,
         plaintext_sha256: plaintext_sha256
       }}
    end
  end

  def decrypt_final_record(_record, _context), do: {:error, :integrity_failure}

  @doc """
  Extracts the authentication tag from one exact reserved final record.

  This is a structural operation only; it does not authenticate the record.
  """
  @spec final_tag(binary()) :: {:ok, <<_::128>>} | {:error, :integrity_failure}
  def final_tag(
        <<@final_counter::unsigned-big-32, @final_plaintext_size::unsigned-big-32,
          _ciphertext::binary-size(@final_plaintext_size), tag::binary-size(@tag_size)>>
      ),
      do: {:ok, tag}

  def final_tag(_record), do: {:error, :integrity_failure}

  @spec decode(binary(), map()) :: {:ok, binary()} | {:error, :integrity_failure}
  def decode(
        encoded,
        %{key: <<_::binary-size(32)>> = key, chunk_index: 0} = expected
      )
      when is_binary(encoded) do
    with {:ok, header, records, parsed} <- Format.split_header(encoded),
         true <-
           Format.context_matches?(
             parsed,
             Map.put(expected, :nonce_prefix, parsed.nonce_prefix)
           ),
         {:ok, plaintext, final_metadata} <-
           decrypt_records(records, key, header, parsed.nonce_prefix),
         :ok <- verify_final(plaintext, final_metadata) do
      {:ok, plaintext}
    else
      _invalid -> {:error, :integrity_failure}
    end
  end

  def decode(_encoded, _expected), do: {:error, :integrity_failure}

  @spec validate_chunk_count(non_neg_integer()) ::
          :ok | {:error, :chunk_count_overflow}
  def validate_chunk_count(count)
      when is_integer(count) and count >= 0 and count <= 0xFFFFFFFF,
      do: :ok

  def validate_chunk_count(_count), do: {:error, :chunk_count_overflow}

  defp init_encrypt(context, key, nonce_prefix) do
    header_context =
      context
      |> Map.put(:nonce_prefix, nonce_prefix)
      |> Map.take(@header_context_keys)

    with {:ok, header} <- Format.canonical_header(header_context) do
      {:ok, header,
       %EncryptState{
         version: 1,
         phase: :open,
         header: header,
         context: header_context,
         key: key,
         nonce_prefix: nonce_prefix,
         counter: 0,
         chunk_count: 0,
         plaintext_bytes: 0,
         plaintext_hash: :crypto.hash_init(:sha256),
         pending_plaintext: "",
         generation_token: new_generation_token()
       }}
    end
  end

  defp encrypt_plaintext("", state), do: {:ok, "", state}

  defp encrypt_plaintext(plaintext, state) do
    encrypt_chunk(state, plaintext)
  end

  defp encrypt_data_record(state, plaintext) do
    size = byte_size(plaintext)
    nonce = Format.nonce(state.nonce_prefix, state.counter)
    aad = Format.data_aad(state.header, state.counter, size)

    with {:ok, ciphertext, tag} <-
           encrypt_record(state.key, nonce, plaintext, aad) do
      {:ok,
       <<state.counter::unsigned-big-32, size::unsigned-big-32, ciphertext::binary, tag::binary>>}
    end
  end

  defp encrypt_final(state, plaintext_sha256) do
    metadata =
      <<state.plaintext_bytes::unsigned-big-64, state.chunk_count::unsigned-big-32,
        plaintext_sha256::binary>>

    nonce = Format.nonce(state.nonce_prefix, Format.final_counter())
    aad = Format.final_aad(state.header)

    with {:ok, ciphertext, tag} <-
           encrypt_record(state.key, nonce, metadata, aad) do
      {:ok,
       <<Format.final_counter()::unsigned-big-32, @final_plaintext_size::unsigned-big-32,
         ciphertext::binary, tag::binary>>}
    end
  end

  defp validate_open_state(%EncryptState{} = state) do
    valid_shape? =
      state.version == 1 and
        state.phase == :open and
        is_binary(state.header) and
        is_map(state.context) and
        match?(<<_::binary-size(32)>>, state.key) and
        match?(<<_::binary-size(8)>>, state.nonce_prefix) and
        is_integer(state.counter) and
        state.counter >= 0 and
        state.counter <= @final_counter and
        state.chunk_count == state.counter and
        is_integer(state.plaintext_bytes) and
        state.plaintext_bytes >= 0 and
        state.plaintext_bytes <= @max_plaintext_bytes and
        is_reference(state.plaintext_hash) and
        is_binary(state.pending_plaintext) and
        byte_size(state.pending_plaintext) < @chunk_size and
        (state.counter < @final_counter or state.pending_plaintext == "") and
        valid_generation_token?(state.generation_token) and
        Map.get(state.context, :chunk_index) == 0 and
        Map.get(state.context, :nonce_prefix) == state.nonce_prefix

    if valid_shape? and canonical_state_header?(state) do
      :ok
    else
      {:error, :invalid_format}
    end
  end

  defp validate_open_state(_state), do: {:error, :invalid_format}

  defp canonical_state_header?(state) do
    case Format.canonical_header(state.context) do
      {:ok, header} -> header == state.header
      {:error, :invalid_format} -> false
    end
  end

  defp new_generation_token, do: :atomics.new(1, [])

  defp valid_generation_token?(token) when is_reference(token) do
    try do
      match?(%{size: 1}, :atomics.info(token)) and
        :atomics.get(token, 1) in [0, 1]
    rescue
      ArgumentError -> false
    end
  end

  defp valid_generation_token?(_token), do: false

  defp consume_generation(token) do
    try do
      case :atomics.compare_exchange(token, 1, 0, 1) do
        :ok -> :ok
        1 -> {:error, :state_consumed}
        _invalid -> {:error, :invalid_format}
      end
    rescue
      ArgumentError -> {:error, :invalid_format}
    end
  end

  defp validate_plaintext_fragment(plaintext) when not is_binary(plaintext),
    do: {:error, :invalid_chunk}

  defp validate_plaintext_fragment(""), do: {:error, :invalid_chunk}

  defp validate_plaintext_fragment(_plaintext), do: :ok

  defp ensure_fragment_capacity(state, fragment_size) do
    future_plaintext_bytes = byte_size(state.pending_plaintext) + fragment_size

    future_records =
      div(future_plaintext_bytes + @chunk_size - 1, @chunk_size)

    if state.counter + future_records <= @final_counter do
      :ok
    else
      {:error, :chunk_count_overflow}
    end
  end

  defp ensure_finalize_capacity(%EncryptState{pending_plaintext: ""}), do: :ok

  defp ensure_finalize_capacity(%EncryptState{counter: counter})
       when counter <= 0xFFFFFFFE,
       do: :ok

  defp ensure_finalize_capacity(%EncryptState{}),
    do: {:error, :chunk_count_overflow}

  defp rechunk_fragment(
         %EncryptState{pending_plaintext: ""} = state,
         fragment
       ) do
    encrypt_complete_fragments(state, fragment, [])
  end

  defp rechunk_fragment(state, fragment) do
    pending_size = byte_size(state.pending_plaintext)
    needed = @chunk_size - pending_size

    if byte_size(fragment) < needed do
      {:ok, [], %{state | pending_plaintext: state.pending_plaintext <> fragment}}
    else
      <<prefix::binary-size(needed), rest::binary>> = fragment
      plaintext = state.pending_plaintext <> prefix

      with {:ok, record, state} <- encrypt_data_chunk(state, plaintext) do
        state = %{state | pending_plaintext: ""}
        encrypt_complete_fragments(state, rest, [record])
      end
    end
  end

  defp encrypt_complete_fragments(state, fragment, records)
       when byte_size(fragment) >= @chunk_size do
    <<plaintext::binary-size(@chunk_size), rest::binary>> = fragment

    with {:ok, record, state} <- encrypt_data_chunk(state, plaintext) do
      encrypt_complete_fragments(state, rest, [record | records])
    end
  end

  defp encrypt_complete_fragments(state, pending, records) do
    pending = :binary.copy(pending)
    {:ok, Enum.reverse(records), %{state | pending_plaintext: pending}}
  end

  defp flush_pending(%EncryptState{pending_plaintext: ""} = state),
    do: {:ok, "", state}

  defp flush_pending(state) do
    with {:ok, record, state} <-
           encrypt_data_chunk(state, state.pending_plaintext) do
      {:ok, record, %{state | pending_plaintext: ""}}
    end
  end

  defp encrypt_data_chunk(state, plaintext) do
    with :ok <- ensure_data_counter_available(state.counter),
         {:ok, record} <- encrypt_data_record(state, plaintext) do
      {:ok, record,
       %{
         state
         | counter: state.counter + 1,
           chunk_count: state.chunk_count + 1
       }}
    end
  end

  defp ensure_data_counter_available(counter)
       when counter >= 0 and counter <= 0xFFFFFFFE,
       do: :ok

  defp ensure_data_counter_available(@final_counter),
    do: {:error, :chunk_count_overflow}

  defp ensure_data_counter_available(_counter),
    do: {:error, :invalid_format}

  defp checked_plaintext_bytes(current, added)
       when current <= @max_plaintext_bytes - added,
       do: {:ok, current + added}

  defp checked_plaintext_bytes(_current, _added),
    do: {:error, :plaintext_size_overflow}

  defp update_hash(hash, plaintext) do
    try do
      {:ok, :crypto.hash_update(hash, plaintext)}
    rescue
      ArgumentError -> {:error, :invalid_format}
    catch
      :error, _reason -> {:error, :invalid_format}
    end
  end

  defp finish_hash(hash) do
    try do
      case :crypto.hash_final(hash) do
        <<_::binary-size(32)>> = digest -> {:ok, digest}
        _invalid -> {:error, :invalid_format}
      end
    rescue
      ArgumentError -> {:error, :invalid_format}
    catch
      :error, _reason -> {:error, :invalid_format}
    end
  end

  defp encrypt_record(key, nonce, plaintext, aad) do
    try do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             plaintext,
             aad,
             @tag_size,
             true
           ) do
        {ciphertext, <<_::binary-size(@tag_size)>> = tag}
        when is_binary(ciphertext) ->
          {:ok, ciphertext, tag}

        _invalid ->
          {:error, :invalid_format}
      end
    rescue
      ArgumentError -> {:error, :invalid_format}
    catch
      :error, _reason -> {:error, :invalid_format}
    end
  end

  defp decrypt_records(records, key, header, nonce_prefix) do
    decrypt_records(records, key, header, nonce_prefix, 0, [])
  end

  defp decrypt_records(
         <<counter::unsigned-big-32, @final_plaintext_size::unsigned-big-32,
           ciphertext::binary-size(@final_plaintext_size), tag::binary-size(@tag_size)>>,
         key,
         header,
         nonce_prefix,
         expected_counter,
         plaintext
       )
       when counter == @final_counter do
    with {:ok, metadata} <-
           decrypt_record(
             ciphertext,
             tag,
             key,
             Format.nonce(nonce_prefix, counter),
             Format.final_aad(header)
           ) do
      {:ok, IO.iodata_to_binary(Enum.reverse(plaintext)), {metadata, expected_counter}}
    end
  end

  defp decrypt_records(
         <<counter::unsigned-big-32, size::unsigned-big-32, rest::binary>>,
         key,
         header,
         nonce_prefix,
         expected_counter,
         plaintext
       )
       when counter == expected_counter and counter <= 0xFFFFFFFE and size > 0 and
              size <= 4_194_304 do
    case rest do
      <<ciphertext::binary-size(size), tag::binary-size(@tag_size), remaining::binary>> ->
        with :ok <- validate_chunk_position(size, remaining),
             {:ok, chunk} <-
               decrypt_record(
                 ciphertext,
                 tag,
                 key,
                 Format.nonce(nonce_prefix, counter),
                 Format.data_aad(header, counter, size)
               ) do
          decrypt_records(
            remaining,
            key,
            header,
            nonce_prefix,
            expected_counter + 1,
            [chunk | plaintext]
          )
        end

      _truncated ->
        {:error, :integrity_failure}
    end
  end

  defp decrypt_records(
         _records,
         _key,
         _header,
         _nonce_prefix,
         _expected_counter,
         _plaintext
       ),
       do: {:error, :integrity_failure}

  defp decrypt_record(ciphertext, tag, key, nonce, aad) do
    try do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             aad,
             tag,
             false
           ) do
        :error -> {:error, :integrity_failure}
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
      end
    rescue
      ArgumentError -> {:error, :integrity_failure}
    catch
      :error, _reason -> {:error, :integrity_failure}
    end
  end

  defp verify_final(
         plaintext,
         {<<total_size::unsigned-big-64, chunk_count::unsigned-big-32,
            plaintext_sha256::binary-size(32)>>, decoded_chunk_count}
       ) do
    if total_size == byte_size(plaintext) and
         chunk_count == decoded_chunk_count and
         plaintext_sha256 == :crypto.hash(:sha256, plaintext) do
      :ok
    else
      {:error, :integrity_failure}
    end
  end

  defp verify_final(_plaintext, _final_metadata),
    do: {:error, :integrity_failure}

  defp validate_chunk_position(4_194_304, _remaining), do: :ok

  defp validate_chunk_position(
         size,
         <<@final_counter::unsigned-big-32, _final_record::binary>>
       )
       when size > 0 and size < 4_194_304,
       do: :ok

  defp validate_chunk_position(_size, _remaining),
    do: {:error, :integrity_failure}
end
