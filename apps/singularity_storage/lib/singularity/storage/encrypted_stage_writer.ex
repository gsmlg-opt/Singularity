defmodule Singularity.Storage.EncryptedStageWriter do
  @moduledoc """
  Streams one upload through the authenticated object codec into durable storage.

  The returned metadata contains only the protected lookup digest and the
  ciphertext digest. The transient plaintext digest is never returned.
  """

  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Core.StageRef
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Crypto.ObjectIdentity

  @chunk_size 4_194_304

  defmodule RecoveryRef do
    @moduledoc """
    Durable metadata needed to retry a finalization whose publication state is
    ambiguous. It contains no plaintext digest or unwrapped key.
    """

    alias Singularity.Core.ObjectRef
    alias Singularity.Core.StageRef

    @enforce_keys [
      :stage_ref,
      :object_ref,
      :vault_id,
      :encryption_domain_id,
      :lookup_digest,
      :ciphertext_hash,
      :plaintext_byte_size,
      :ciphertext_byte_size,
      :format_version,
      :dek_wrapper
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            stage_ref: StageRef.t(),
            object_ref: ObjectRef.t(),
            vault_id: String.t(),
            encryption_domain_id: String.t(),
            lookup_digest: binary(),
            ciphertext_hash: binary(),
            plaintext_byte_size: non_neg_integer(),
            ciphertext_byte_size: non_neg_integer(),
            format_version: pos_integer(),
            dek_wrapper: term()
          }
  end

  @type result :: %{
          required(:object_ref) => ObjectRef.t(),
          required(:plaintext_byte_size) => non_neg_integer(),
          required(:ciphertext_byte_size) => non_neg_integer(),
          required(:lookup_digest) => binary(),
          required(:ciphertext_hash) => binary(),
          required(:format_version) => pos_integer(),
          required(:dek_wrapper) => term()
        }

  @spec stream_and_seal(map(), map(), Enumerable.t()) ::
          {:ok, result()} | {:error, Error.t(), StageRef.t() | RecoveryRef.t() | nil}
  def stream_and_seal(storage, upload, stream)
      when is_map(storage) and is_map(upload) do
    case validate(storage, upload) do
      {:ok, config} ->
        start_stage(config, stream)

      {:error, %Error{} = error} ->
        _ = destroy_unvalidated_wrapper(storage, upload)
        {:error, error, nil}
    end
  end

  def stream_and_seal(_storage, _upload, _stream),
    do: {:error, Error.new(:invalid), nil}

  @spec retry_finalize(map(), RecoveryRef.t()) ::
          {:ok, result()} | {:error, Error.t(), RecoveryRef.t()}
  def retry_finalize(
        %{adapter: adapter, context: context},
        %RecoveryRef{} = recovery
      )
      when is_atom(adapter) and is_map(context) do
    final_context = final_context(context, recovery)

    result =
      try do
        normalize_adapter(
          adapter.finalize(
            final_context,
            recovery.stage_ref,
            recovery.object_ref
          )
        )
      rescue
        _exception -> {:error, unavailable()}
      catch
        _kind, _reason -> {:error, unavailable()}
      end

    case result do
      {:ok, object_ref} when object_ref == recovery.object_ref ->
        {:ok,
         result(
           recovery.object_ref,
           %{plaintext_bytes: recovery.plaintext_byte_size},
           recovery.lookup_digest,
           recovery.ciphertext_hash,
           recovery.ciphertext_byte_size,
           recovery.dek_wrapper
         )}

      {:error, %Error{} = error} ->
        {:error, error, recovery}

      _invalid ->
        {:error, unavailable(), recovery}
    end
  end

  def retry_finalize(_storage, %RecoveryRef{} = recovery),
    do: {:error, Error.new(:invalid), recovery}

  defp start_stage(config, stream) do
    with :ok <- enforce_declared_limit(config),
         {:ok, %StageRef{} = stage_ref} <- call_stage(config) do
      run_stage(config, stage_ref, stream)
    else
      {:error, %Error{} = error} ->
        _ = destroy_wrapper(config)
        {:error, error, nil}

      _invalid ->
        _ = destroy_wrapper(config)
        {:error, unavailable(), nil}
    end
  end

  defp run_stage(config, stage_ref, stream) do
    result =
      try do
        write_stage(config, stage_ref, stream)
      rescue
        _exception -> {:error, unavailable()}
      catch
        _kind, _reason -> {:error, unavailable()}
      end

    case result do
      {:ok, result} ->
        {:ok, result}

      {:error, %Error{} = error} ->
        _ = discard(config, stage_ref)
        {:error, error, stage_ref}

      {:retain, %Error{} = error, %RecoveryRef{} = recovery} ->
        {:error, error, recovery}

      _invalid ->
        _ = discard(config, stage_ref)
        {:error, unavailable(), stage_ref}
    end
  end

  defp write_stage(config, stage_ref, stream) do
    with {:ok, header, cipher} <- init_cipher(config),
         :ok <- append_nonempty(config, stage_ref, header),
         {:ok, state} <- reduce_stream(config, stage_ref, stream, initial_state(cipher, header)),
         {:ok, state, summary} <- finalize_cipher(config, stage_ref, state),
         {:ok, lookup_digest} <-
           ObjectIdentity.lookup_digest(
             config.domain_dedup_key,
             summary.plaintext_sha256
           ),
         ciphertext_hash <- :crypto.hash_final(state.ciphertext_hash),
         {:ok, sealed} <-
           seal_stage(
             config,
             stage_ref,
             summary,
             lookup_digest,
             ciphertext_hash,
             state.ciphertext_bytes
           ),
         :ok <-
           verify_sealed(
             sealed,
             state.ciphertext_bytes,
             ciphertext_hash
           ) do
      resolve_object(
        config,
        stage_ref,
        summary,
        lookup_digest,
        ciphertext_hash,
        state.ciphertext_bytes
      )
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, codec_error(reason)}
      _invalid -> {:error, Error.new(:integrity_failure)}
    end
  end

  defp init_cipher(config) do
    config.codec.init_encrypt(%{
      key: config.object_dek,
      format_version: Format.format_version(),
      algorithm: Format.algorithm(),
      chunk_size: Format.chunk_size(),
      vault_id: config.vault_id,
      encryption_domain_id: config.encryption_domain_id,
      object_id: config.object_id,
      chunk_index: 0
    })
  end

  defp initial_state(cipher, header) do
    %{
      cipher: cipher,
      plaintext_hash: :crypto.hash_init(:sha256),
      ciphertext_hash:
        :sha256
        |> :crypto.hash_init()
        |> :crypto.hash_update(header),
      plaintext_bytes: 0,
      ciphertext_bytes: byte_size(header)
    }
  end

  defp reduce_stream(config, stage_ref, stream, state) do
    Enum.reduce_while(stream, {:ok, state}, fn
      "", {:ok, current} ->
        {:cont, {:ok, current}}

      plaintext, {:ok, current} when is_binary(plaintext) ->
        case encrypt_fragment(config, stage_ref, plaintext, current) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      _invalid, {:ok, _current} ->
        {:halt, {:error, Error.new(:invalid)}}
    end)
  end

  defp encrypt_fragment(config, stage_ref, plaintext, state) do
    with :ok <- enforce_limit(state.plaintext_bytes, byte_size(plaintext), config.max_bytes),
         {:ok, emitted, cipher} <-
           normalize_codec(config.codec.encrypt_chunk(state.cipher, plaintext)),
         :ok <- append_nonempty(config, stage_ref, emitted) do
      {:ok,
       %{
         state
         | cipher: cipher,
           plaintext_hash: :crypto.hash_update(state.plaintext_hash, plaintext),
           ciphertext_hash: :crypto.hash_update(state.ciphertext_hash, emitted),
           plaintext_bytes: state.plaintext_bytes + byte_size(plaintext),
           ciphertext_bytes: state.ciphertext_bytes + byte_size(emitted)
       }}
    end
  end

  defp finalize_cipher(config, stage_ref, state) do
    with {:ok, final_tail, summary, _finalized_state} <-
           normalize_finalize(config.codec.finalize(state.cipher)),
         :ok <- verify_summary(config, state, summary),
         :ok <- append_nonempty(config, stage_ref, final_tail) do
      {:ok,
       %{
         state
         | ciphertext_hash: :crypto.hash_update(state.ciphertext_hash, final_tail),
           ciphertext_bytes: state.ciphertext_bytes + byte_size(final_tail)
       }, summary}
    end
  end

  defp verify_summary(config, state, %{
         plaintext_bytes: plaintext_bytes,
         chunk_count: chunk_count,
         plaintext_sha256: <<_::binary-size(32)>> = summary_hash
       })
       when plaintext_bytes == state.plaintext_bytes and
              chunk_count == div(plaintext_bytes + @chunk_size - 1, @chunk_size) do
    plaintext_hash = :crypto.hash_final(state.plaintext_hash)

    if :crypto.hash_equals(plaintext_hash, summary_hash) do
      if plaintext_bytes == config.expected_bytes do
        :ok
      else
        {:error, Error.new(:invalid)}
      end
    else
      {:error, Error.new(:integrity_failure)}
    end
  end

  defp verify_summary(_config, _state, _summary),
    do: {:error, Error.new(:integrity_failure)}

  defp seal_stage(
         config,
         stage_ref,
         summary,
         lookup_digest,
         ciphertext_hash,
         ciphertext_bytes
       ) do
    metadata = %{
      format_version: Format.format_version(),
      plaintext_byte_size: summary.plaintext_bytes,
      ciphertext_byte_size: ciphertext_bytes,
      lookup_digest: lookup_digest,
      ciphertext_hash: ciphertext_hash
    }

    config.adapter.seal_stage(config.context, stage_ref, metadata)
    |> normalize_adapter()
  end

  defp verify_sealed(
         %{
           sealed?: true,
           byte_size: actual_byte_size,
           ciphertext_hash: actual_ciphertext_hash
         },
         expected_byte_size,
         expected_ciphertext_hash
       )
       when actual_byte_size == expected_byte_size do
    if secure_digest_equal?(actual_ciphertext_hash, expected_ciphertext_hash) do
      :ok
    else
      {:error, Error.new(:integrity_failure)}
    end
  end

  defp verify_sealed(_sealed, _byte_size, _ciphertext_hash),
    do: {:error, Error.new(:integrity_failure)}

  defp resolve_object(
         config,
         stage_ref,
         summary,
         lookup_digest,
         ciphertext_hash,
         ciphertext_bytes
       ) do
    case config.dedup_lookup.(
           config.vault_id,
           config.encryption_domain_id,
           lookup_digest
         ) do
      :miss ->
        finalize_new_object(
          config,
          stage_ref,
          summary,
          lookup_digest,
          ciphertext_hash,
          ciphertext_bytes
        )

      {:ok,
       %{
         vault_id: vault_id,
         encryption_domain_id: encryption_domain_id,
         object_ref: %ObjectRef{} = object_ref,
         dek_wrapper: canonical_wrapper,
         plaintext_byte_size: plaintext_byte_size,
         ciphertext_byte_size: canonical_ciphertext_bytes,
         ciphertext_hash: <<_::binary-size(32)>> = canonical_ciphertext_hash,
         format_version: format_version,
         lookup_digest: <<_::binary-size(32)>> = candidate_lookup_digest,
         lifecycle: :available
       }}
      when vault_id == config.vault_id and
             encryption_domain_id == config.encryption_domain_id and
             plaintext_byte_size == summary.plaintext_bytes and
             is_integer(canonical_ciphertext_bytes) and
             canonical_ciphertext_bytes >= 0 and
             format_version == 1 ->
        if secure_digest_equal?(candidate_lookup_digest, lookup_digest) do
          with :ok <- discard(config, stage_ref) do
            {:ok,
             result(
               object_ref,
               summary,
               lookup_digest,
               canonical_ciphertext_hash,
               canonical_ciphertext_bytes,
               canonical_wrapper
             )}
          end
        else
          {:error, Error.new(:invalid)}
        end

      {:error, %Error{} = error} ->
        {:error, error}

      _invalid ->
        {:error, Error.new(:invalid)}
    end
  end

  defp finalize_new_object(
         config,
         stage_ref,
         summary,
         lookup_digest,
         ciphertext_hash,
         ciphertext_bytes
       ) do
    object_ref = %ObjectRef{object_id: config.object_id}

    recovery =
      recovery_ref(
        config,
        stage_ref,
        object_ref,
        summary,
        lookup_digest,
        ciphertext_hash,
        ciphertext_bytes
      )

    final_context = final_context(config.context, recovery)

    case call_finalize(config, final_context, stage_ref, object_ref) do
      {:ok, ^object_ref} ->
        {:ok,
         result(
           object_ref,
           summary,
           lookup_digest,
           ciphertext_hash,
           ciphertext_bytes,
           config.dek_wrapper
         )}

      {:error, %Error{} = error} ->
        classify_finalize_failure(config, stage_ref, error, recovery)

      {:ambiguous, %Error{} = error} ->
        {:retain, error, recovery}

      _invalid ->
        classify_finalize_failure(config, stage_ref, unavailable(), recovery)
    end
  end

  defp result(
         object_ref,
         summary,
         lookup_digest,
         ciphertext_hash,
         ciphertext_bytes,
         dek_wrapper
       ) do
    %{
      object_ref: object_ref,
      plaintext_byte_size: summary.plaintext_bytes,
      ciphertext_byte_size: ciphertext_bytes,
      lookup_digest: lookup_digest,
      ciphertext_hash: ciphertext_hash,
      format_version: Format.format_version(),
      dek_wrapper: dek_wrapper
    }
  end

  defp append_nonempty(_config, _stage_ref, ""), do: :ok

  defp append_nonempty(config, stage_ref, bytes) when is_binary(bytes) do
    config.adapter.append_encrypted_chunk(config.context, stage_ref, bytes)
    |> normalize_adapter()
  end

  defp append_nonempty(_config, _stage_ref, _invalid),
    do: {:error, Error.new(:integrity_failure)}

  defp discard(config, stage_ref) do
    abort_result =
      config.adapter.abort_stage(config.context, stage_ref)
      |> normalize_adapter()

    wrapper_result = destroy_wrapper(config)

    case {abort_result, wrapper_result} do
      {:ok, :ok} -> :ok
      {{:error, %Error{} = error}, _wrapper_result} -> {:error, error}
      {_abort_result, {:error, %Error{} = error}} -> {:error, error}
    end
  end

  defp destroy_wrapper(config) do
    config.destroy_dek_wrapper.(config.dek_wrapper)
    |> normalize_cleanup()
  end

  defp destroy_unvalidated_wrapper(storage, upload) do
    with destroy when is_function(destroy, 1) <-
           Map.get(storage, :destroy_dek_wrapper),
         {:ok, wrapper} <- Map.fetch(upload, :dek_wrapper) do
      try do
        destroy.(wrapper)
        |> normalize_cleanup()
      rescue
        _exception -> {:error, unavailable()}
      catch
        _kind, _reason -> {:error, unavailable()}
      end
    else
      _missing -> :ok
    end
  end

  defp recovery_ref(
         config,
         stage_ref,
         object_ref,
         summary,
         lookup_digest,
         ciphertext_hash,
         ciphertext_bytes
       ) do
    %RecoveryRef{
      stage_ref: stage_ref,
      object_ref: object_ref,
      vault_id: config.vault_id,
      encryption_domain_id: config.encryption_domain_id,
      lookup_digest: lookup_digest,
      ciphertext_hash: ciphertext_hash,
      plaintext_byte_size: summary.plaintext_bytes,
      ciphertext_byte_size: ciphertext_bytes,
      format_version: Format.format_version(),
      dek_wrapper: config.dek_wrapper
    }
  end

  defp classify_finalize_failure(
         _config,
         _stage_ref,
         %Error{details: %{publication_state: state}} = error,
         recovery
       )
       when state in [:published, :ambiguous] do
    {:retain, error, recovery}
  end

  defp classify_finalize_failure(
         _config,
         _stage_ref,
         %Error{details: %{publication_state: :not_published}} = error,
         _recovery
       ) do
    {:error, error}
  end

  defp classify_finalize_failure(config, stage_ref, error, recovery) do
    case object_status(config, recovery) do
      {:ok, %{ciphertext_hash: ciphertext_hash}} ->
        if secure_digest_equal?(ciphertext_hash, recovery.ciphertext_hash) do
          {:retain, error, recovery}
        else
          {:retain, Error.new(:integrity_failure), recovery}
        end

      {:error, %Error{code: :not_found}} ->
        case stage_status(config, stage_ref) do
          {:ok, %{sealed?: true}} -> {:error, error}
          _missing_or_unknown -> {:retain, error, recovery}
        end

      _present_or_unknown ->
        {:retain, error, recovery}
    end
  end

  defp object_status(config, recovery) do
    context = final_context(config.context, recovery)

    try do
      config.adapter.stat(context, recovery.object_ref)
      |> normalize_adapter()
    rescue
      _exception -> :unknown
    catch
      _kind, _reason -> :unknown
    end
  end

  defp stage_status(config, stage_ref) do
    try do
      config.adapter.stat_stage(config.context, stage_ref)
      |> normalize_adapter()
    rescue
      _exception -> :unknown
    catch
      _kind, _reason -> :unknown
    end
  end

  defp final_context(context, recovery) do
    context
    |> Map.put(:vault_namespace, recovery.vault_id)
    |> Map.put(:domain_namespace, recovery.encryption_domain_id)
    |> Map.put(
      :lookup_digest,
      Base.encode16(recovery.lookup_digest, case: :lower)
    )
    |> Map.put(:ciphertext_hash, recovery.ciphertext_hash)
  end

  defp validate(storage, upload) do
    with adapter when is_atom(adapter) <- Map.get(storage, :adapter),
         context when is_map(context) <- Map.get(storage, :context),
         codec when is_atom(codec) <- Map.get(storage, :codec, ChunkedAEAD),
         dedup_lookup when is_function(dedup_lookup, 3) <-
           Map.get(storage, :dedup_lookup),
         destroy_dek_wrapper when is_function(destroy_dek_wrapper, 1) <-
           Map.get(storage, :destroy_dek_wrapper),
         vault_id when is_binary(vault_id) <- Map.get(upload, :vault_id),
         {:ok, _vault_uuid} <- Ecto.UUID.dump(vault_id),
         encryption_domain_id when is_binary(encryption_domain_id) <-
           Map.get(upload, :encryption_domain_id),
         {:ok, _domain_uuid} <- Ecto.UUID.dump(encryption_domain_id),
         object_id when is_binary(object_id) <- Map.get(upload, :object_id),
         {:ok, _object_uuid} <- Ecto.UUID.dump(object_id),
         <<_::binary-size(32)>> = object_dek <- Map.get(upload, :object_dek),
         <<_::binary-size(32)>> = domain_dedup_key <-
           Map.get(upload, :domain_dedup_key),
         {:ok, dek_wrapper} <- Map.fetch(upload, :dek_wrapper),
         expected_bytes when is_integer(expected_bytes) and expected_bytes >= 0 <-
           Map.get(upload, :expected_bytes),
         max_bytes when is_integer(max_bytes) and max_bytes >= 0 <-
           Map.get(upload, :max_bytes) do
      {:ok,
       %{
         adapter: adapter,
         context: context,
         codec: codec,
         dedup_lookup: dedup_lookup,
         destroy_dek_wrapper: destroy_dek_wrapper,
         vault_id: vault_id,
         encryption_domain_id: encryption_domain_id,
         object_id: object_id,
         object_dek: object_dek,
         domain_dedup_key: domain_dedup_key,
         dek_wrapper: dek_wrapper,
         expected_bytes: expected_bytes,
         max_bytes: max_bytes
       }}
    else
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp enforce_declared_limit(%{expected_bytes: expected, max_bytes: max})
       when expected <= max,
       do: :ok

  defp enforce_declared_limit(_config),
    do: {:error, Error.new(:upload_too_large)}

  defp enforce_limit(current, incoming, maximum)
       when current + incoming <= maximum,
       do: :ok

  defp enforce_limit(_current, _incoming, _maximum),
    do: {:error, Error.new(:upload_too_large)}

  defp call_stage(config) do
    try do
      config.adapter.stage(config.context, %{})
      |> normalize_adapter()
    rescue
      _exception -> {:error, unavailable()}
    catch
      _kind, _reason -> {:error, unavailable()}
    end
  end

  defp call_finalize(config, context, stage_ref, object_ref) do
    try do
      config.adapter.finalize(context, stage_ref, object_ref)
      |> normalize_adapter()
    rescue
      _exception -> {:ambiguous, unavailable()}
    catch
      _kind, _reason -> {:ambiguous, unavailable()}
    end
  end

  defp secure_digest_equal?(
         <<_::binary-size(32)>> = left,
         <<_::binary-size(32)>> = right
       ) do
    :crypto.hash_equals(left, right)
  end

  defp secure_digest_equal?(_left, _right), do: false

  defp normalize_codec({:ok, emitted, cipher}) when is_binary(emitted),
    do: {:ok, emitted, cipher}

  defp normalize_codec({:error, reason}), do: {:error, codec_error(reason)}
  defp normalize_codec(_invalid), do: {:error, Error.new(:integrity_failure)}

  defp normalize_finalize({:ok, tail, summary, finalized_state})
       when is_binary(tail) and is_map(summary),
       do: {:ok, tail, summary, finalized_state}

  defp normalize_finalize({:error, reason}), do: {:error, codec_error(reason)}
  defp normalize_finalize(_invalid), do: {:error, Error.new(:integrity_failure)}

  defp normalize_adapter(:ok), do: :ok
  defp normalize_adapter({:ok, value}), do: {:ok, value}
  defp normalize_adapter({:error, %Error{} = error}), do: {:error, error}
  defp normalize_adapter(_invalid), do: {:error, unavailable()}

  defp normalize_cleanup(:ok), do: :ok
  defp normalize_cleanup({:error, %Error{} = error}), do: {:error, error}
  defp normalize_cleanup(_invalid), do: {:error, unavailable()}

  defp codec_error(reason)
       when reason in [:plaintext_size_overflow, :chunk_count_overflow],
       do: Error.new(:upload_too_large)

  defp codec_error(reason) when reason in [:invalid_chunk, :invalid_format],
    do: Error.new(:invalid)

  defp codec_error(_reason), do: Error.new(:integrity_failure)

  defp unavailable, do: Error.new(:storage_unavailable, retryable?: true)
end
