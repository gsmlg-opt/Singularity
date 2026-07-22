defmodule Singularity.Storage.Postgres.CustodyRepository do
  @moduledoc """
  Least-privilege PostgreSQL reads and checkpoint CAS for plaintext custody.

  Every call is expected to run inside `ScopedRepo` with the requesting
  principal and vault already installed as transaction-local RLS context.
  """

  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Content.AssetKeyEnvelope
  alias Singularity.Storage.Schema.Content.AssetObject
  alias Singularity.Storage.Schema.Core.DomainKeyVersion
  alias Singularity.Storage.Schema.Core.KeyDomain
  alias Singularity.Storage.Schema.Jobs.JobProgress

  @classifications [:private, :sensitive, :restricted]
  @classification_rank %{private: 0, sensitive: 1, restricted: 2}
  @v2_checkpoint_keys ~w[
    version next_chunk_index job_id vault_id principal_id required_capability
    principal_authorization_epoch vault_authorization_epoch object_id
    object_generation
  ]
  @metadata_checkpoint_keys ~w[
    version protocol next_chunk_index processing_revision extractor_state
    job_id vault_id principal_id required_capability
    principal_authorization_epoch vault_authorization_epoch object_id
    object_generation
  ]
  @metadata_protocol "asset_metadata_v1"
  @max_bigint 9_223_372_036_854_775_807
  @binding_keys [
    :job_id,
    :vault_id,
    :principal_id,
    :required_capability,
    :principal_authorization_epoch,
    :vault_authorization_epoch,
    :object_id,
    :object_generation
  ]
  @metadata_target_keys [:declared_media_type, :plaintext_byte_size]

  @spec load_reader_material(module(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def load_reader_material(repo, binding) when is_map(binding) do
    with :ok <- validate_binding(binding) do
      repo.all(reader_material_query(binding))
      |> one_reader_material()
    end
  rescue
    _error in [Ecto.Query.CastError, DBConnection.ConnectionError, Postgrex.Error] ->
      unavailable()
  end

  def load_reader_material(_repo, _binding), do: {:error, Error.new(:invalid)}

  @spec revalidate_reader(module(), map(), map()) ::
          :ok | {:error, Error.t()}
  def revalidate_reader(repo, binding, reader_binding)
      when is_map(binding) and is_map(reader_binding) do
    with :ok <- validate_binding(binding),
         {:ok, material} <- load_reader_material(repo, binding),
         true <- reader_binding(material) == reader_binding,
         {:ok, live} <-
           IdentityRepository.load_live_principal(
             repo,
             binding.principal_id,
             binding.vault_id
           ),
         :ok <- validate_live_principal(live, binding, material.classification) do
      :ok
    else
      false -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
      _denied -> {:error, Error.new(:forbidden)}
    end
  rescue
    _error in [Ecto.Query.CastError, DBConnection.ConnectionError, Postgrex.Error] ->
      unavailable()
  end

  def revalidate_reader(_repo, _binding, _reader_binding),
    do: {:error, Error.new(:invalid)}

  @spec load_checkpoint(module(), map(), atom()) ::
          {:ok, map()} | {:error, Error.t()}
  def load_checkpoint(repo, binding, classification)
      when is_map(binding) and classification in @classifications do
    with :ok <- validate_binding(binding),
         {:ok, version} <- checkpoint_version(binding) do
      load_checkpoint_version(repo, binding, classification, version)
    end
  rescue
    _error in [Ecto.Query.CastError, DBConnection.ConnectionError, Postgrex.Error] ->
      unavailable()
  end

  def load_checkpoint(_repo, _binding, _classification),
    do: {:error, Error.new(:invalid)}

  defp load_checkpoint_version(repo, binding, classification, 2) do
    case repo.all(v2_checkpoint_query(binding, classification)) do
      [%{checkpoint: checkpoint}] when is_map(checkpoint) ->
        {:ok, checkpoint}

      [] ->
        {:error, Error.new(:conflict)}

      [_first, _second] ->
        {:error, Error.new(:integrity_failure)}
    end
  end

  defp load_checkpoint_version(repo, binding, classification, 3) do
    case repo.all(v3_checkpoint_query(binding, classification)) do
      [
        %{
          checkpoint_version: checkpoint_version,
          processing_revision: processing_revision,
          state: state,
          checkpoint: checkpoint
        }
      ]
      when is_map(checkpoint) ->
        with :ok <-
               validate_stored_metadata_checkpoint(
                 checkpoint,
                 checkpoint_version,
                 processing_revision,
                 state
               ),
             :ok <-
               validate_checkpoint_columns(
                 checkpoint_version,
                 processing_revision,
                 state,
                 binding,
                 3
               ),
             :ok <- validate_checkpoint(checkpoint, binding, 3) do
          {:ok, checkpoint}
        end

      [%{checkpoint: _malformed_checkpoint}] ->
        {:error, Error.new(:integrity_failure)}

      [] ->
        {:error, Error.new(:conflict)}

      [_first, _second] ->
        {:error, Error.new(:integrity_failure)}
    end
  rescue
    _error in [ArgumentError] ->
      {:error, Error.new(:integrity_failure)}
  end

  @spec persist_checkpoint(module(), map(), atom(), map(), map()) ::
          :ok | {:error, Error.t()}
  def persist_checkpoint(repo, binding, classification, expected, next)
      when is_map(binding) and classification in @classifications and
             is_map(expected) and is_map(next) do
    with :ok <- validate_binding(binding),
         {:ok, version} <- checkpoint_version(binding),
         :ok <- validate_checkpoint(expected, binding, version),
         :ok <- validate_checkpoint(next, binding, version),
         true <-
           next["next_chunk_index"] ==
             expected["next_chunk_index"] + 1 do
      case repo.update_all(
             checkpoint_cas_query(
               binding,
               classification,
               version,
               expected
             ),
             set: [checkpoint: next, updated_at: DateTime.utc_now()]
           ) do
        {1, _rows} ->
          :ok

        {0, _rows} ->
          classify_checkpoint_cas_miss(repo, binding, classification, version, expected)
      end
    else
      false -> {:error, Error.new(:invalid)}
      {:error, %Error{}} = error -> error
    end
  rescue
    _error in [ArgumentError] ->
      {:error, Error.new(:integrity_failure)}

    _error in [Ecto.Query.CastError, DBConnection.ConnectionError, Postgrex.Error] ->
      unavailable()
  end

  def persist_checkpoint(_repo, _binding, _classification, _expected, _next),
    do: {:error, Error.new(:invalid)}

  @doc false
  @spec validate_metadata_checkpoint(map(), map()) :: :ok | {:error, Error.t()}
  def validate_metadata_checkpoint(checkpoint, binding)
      when is_map(checkpoint) and is_map(binding) do
    with :ok <- validate_binding(binding),
         {:ok, 3} <- checkpoint_version(binding) do
      validate_checkpoint(checkpoint, binding, 3)
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  def validate_metadata_checkpoint(_checkpoint, _binding),
    do: {:error, Error.new(:invalid)}

  defp classify_checkpoint_cas_miss(repo, binding, classification, 3, expected) do
    case repo.all(checkpoint_cas_miss_query(binding, classification)) do
      [
        %{
          checkpoint_version: checkpoint_version,
          processing_revision: processing_revision,
          state: state,
          checkpoint: checkpoint
        }
      ]
      when is_map(checkpoint) ->
        with :ok <-
               validate_stored_metadata_checkpoint(
                 checkpoint,
                 checkpoint_version,
                 processing_revision,
                 state
               ),
             :ok <-
               validate_checkpoint_cas_miss_columns(
                 checkpoint_version,
                 processing_revision,
                 state,
                 binding
               ),
             :ok <- validate_checkpoint(checkpoint, binding, 3),
             :ok <- classify_checkpoint_cas_miss_state(state, checkpoint, expected) do
          {:error, :checkpoint_advanced}
        else
          {:error, %Error{}} = error -> error
        end

      [%{checkpoint: _malformed_checkpoint}] ->
        {:error, Error.new(:integrity_failure)}

      [] ->
        {:error, Error.new(:conflict)}

      [_first, _second] ->
        {:error, Error.new(:integrity_failure)}
    end
  end

  defp classify_checkpoint_cas_miss(_repo, _binding, _classification, _version, _expected),
    do: {:error, Error.new(:conflict)}

  defp validate_checkpoint_cas_miss_columns(
         3,
         processing_revision,
         state,
         %{processing_revision: processing_revision}
       )
       when state in [:running, :waiting_for_unlock, :completed, :failed],
       do: :ok

  defp validate_checkpoint_cas_miss_columns(
         3,
         _processing_revision,
         state,
         %{processing_revision: _binding_processing_revision}
       )
       when state in [:running, :waiting_for_unlock, :completed, :failed],
       do: {:error, Error.new(:conflict)}

  defp validate_checkpoint_cas_miss_columns(
         _checkpoint_version,
         _processing_revision,
         _state,
         _binding
       ),
       do: {:error, Error.new(:integrity_failure)}

  defp classify_checkpoint_cas_miss_state(:running, checkpoint, expected) do
    if checkpoint["next_chunk_index"] > expected["next_chunk_index"],
      do: :ok,
      else: {:error, Error.new(:conflict)}
  end

  defp classify_checkpoint_cas_miss_state(state, _checkpoint, _expected)
       when state in [:waiting_for_unlock, :completed, :failed],
       do: :ok

  defp reader_material_query(binding) do
    from(envelope in AssetKeyEnvelope,
      join: object in AssetObject,
      on:
        object.id == envelope.asset_object_id and
          object.vault_id == envelope.vault_id and
          object.key_domain_id == envelope.key_domain_id,
      join: domain_version in DomainKeyVersion,
      on:
        domain_version.id == envelope.domain_key_version_id and
          domain_version.vault_id == envelope.vault_id and
          domain_version.key_domain_id == envelope.key_domain_id,
      join: domain in KeyDomain,
      on:
        domain.id == envelope.key_domain_id and
          domain.vault_id == envelope.vault_id,
      where: envelope.asset_object_id == ^binding.object_id,
      where: envelope.vault_id == ^binding.vault_id,
      where: envelope.key_generation == ^binding.object_generation,
      where: object.lifecycle == :available,
      where: domain_version.state == :active,
      where: domain.state == :active,
      where: domain.kind == "content",
      order_by: [asc: envelope.id],
      limit: 2,
      select: %{
        object_id: object.id,
        object_generation: envelope.key_generation,
        vault_id: object.vault_id,
        key_domain_id: object.key_domain_id,
        domain_key_version_id: envelope.domain_key_version_id,
        domain_key_generation: domain_version.generation,
        domain_classification: domain.classification,
        classification: object.classification,
        envelope_classification: envelope.classification,
        lifecycle: object.lifecycle,
        wrapper_algorithm: envelope.algorithm,
        wrapped_dek: envelope.wrapped_dek,
        lookup_digest: object.lookup_digest,
        ciphertext_hash: object.ciphertext_hash,
        plaintext_byte_size: object.plaintext_byte_size,
        ciphertext_byte_size: object.ciphertext_byte_size,
        format_version: object.format_version
      }
    )
  end

  defp one_reader_material([]), do: {:error, Error.new(:forbidden)}

  defp one_reader_material([material]) do
    if valid_material?(material),
      do: {:ok, material},
      else: {:error, Error.new(:integrity_failure)}
  end

  defp one_reader_material([_first, _second]),
    do: {:error, Error.new(:integrity_failure)}

  defp valid_material?(material) do
    material.classification in @classifications and
      material.classification == material.envelope_classification and
      material.classification == material.domain_classification and
      material.lifecycle == :available and
      material.wrapper_algorithm == "aes_256_gcm" and
      valid_uuid?(material.object_id) and
      valid_uuid?(material.vault_id) and
      valid_uuid?(material.key_domain_id) and
      valid_uuid?(material.domain_key_version_id) and
      is_integer(material.object_generation) and
      material.object_generation > 0 and
      is_integer(material.domain_key_generation) and
      material.domain_key_generation > 0 and
      is_binary(material.wrapped_dek) and
      byte_size(material.wrapped_dek) > 0 and
      digest?(material.lookup_digest) and
      digest?(material.ciphertext_hash) and
      is_integer(material.plaintext_byte_size) and
      material.plaintext_byte_size >= 0 and
      is_integer(material.ciphertext_byte_size) and
      material.ciphertext_byte_size >= 0 and
      is_integer(material.format_version) and material.format_version > 0
  end

  defp validate_live_principal(
         %{
           principal_id: principal_id,
           principal_authorization_epoch: principal_authorization_epoch,
           principal_revoked_at: nil,
           vault_id: vault_id,
           vault_authorization_epoch: vault_authorization_epoch,
           vault_locked: false,
           membership_revoked_at: nil,
           clearance: clearance,
           capabilities: capabilities
         },
         %{
           principal_id: principal_id,
           principal_authorization_epoch: principal_authorization_epoch,
           vault_id: vault_id,
           vault_authorization_epoch: vault_authorization_epoch,
           required_capability: required_capability
         },
         classification
       )
       when clearance in @classifications and classification in @classifications and
              is_list(capabilities) do
    if required_capability in capabilities and
         @classification_rank[clearance] >=
           @classification_rank[classification] do
      :ok
    else
      {:error, Error.new(:forbidden)}
    end
  end

  defp validate_live_principal(_live, _binding, _classification),
    do: {:error, Error.new(:forbidden)}

  defp reader_binding(material) do
    Map.take(material, [
      :object_id,
      :object_generation,
      :vault_id,
      :key_domain_id,
      :classification,
      :lookup_digest,
      :ciphertext_hash,
      :plaintext_byte_size,
      :ciphertext_byte_size,
      :format_version
    ])
  end

  defp validate_binding(%{
         job_id: job_id,
         vault_id: vault_id,
         principal_id: principal_id,
         required_capability: required_capability,
         principal_authorization_epoch: principal_authorization_epoch,
         vault_authorization_epoch: vault_authorization_epoch,
         object_id: object_id,
         object_generation: object_generation,
         session_id: session_id
       })
       when is_binary(required_capability) and byte_size(required_capability) > 0 and
              is_integer(principal_authorization_epoch) and
              principal_authorization_epoch >= 0 and
              is_integer(vault_authorization_epoch) and
              vault_authorization_epoch >= 0 and
              is_integer(object_generation) and object_generation > 0,
       do: UUID.validate([job_id, vault_id, principal_id, object_id, session_id])

  defp validate_binding(%{processing_revision: _processing_revision} = binding),
    do: validate_metadata_binding(binding)

  defp validate_binding(_binding), do: {:error, Error.new(:invalid)}

  defp validate_metadata_binding(
         %{
           job_id: job_id,
           vault_id: vault_id,
           principal_id: principal_id,
           required_capability: required_capability,
           principal_authorization_epoch: principal_authorization_epoch,
           vault_authorization_epoch: vault_authorization_epoch,
           object_id: object_id,
           object_generation: object_generation,
           processing_revision: processing_revision,
           declared_media_type: declared_media_type,
           plaintext_byte_size: plaintext_byte_size
         } = binding
       )
       when is_binary(required_capability) and byte_size(required_capability) in 1..128 and
              is_integer(principal_authorization_epoch) and
              principal_authorization_epoch in 0..@max_bigint and
              is_integer(vault_authorization_epoch) and
              vault_authorization_epoch in 0..@max_bigint and
              is_integer(object_generation) and object_generation in 1..@max_bigint and
              is_integer(processing_revision) and processing_revision in 1..@max_bigint and
              is_integer(plaintext_byte_size) and plaintext_byte_size in 0..@max_bigint do
    with :ok <- UUID.validate([job_id, vault_id, principal_id, object_id]),
         true <- valid_text?(declared_media_type, 255),
         true <-
           Enum.sort(Map.keys(binding)) ==
             Enum.sort([:processing_revision | @metadata_target_keys ++ @binding_keys]) do
      :ok
    else
      false -> {:error, Error.new(:invalid)}
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_metadata_binding(_binding), do: {:error, Error.new(:invalid)}

  defp valid_checkpoint?(
         %{
           "version" => 2,
           "next_chunk_index" => next_chunk_index
         } = checkpoint,
         binding
       )
       when is_integer(next_chunk_index) and next_chunk_index >= 0 do
    Enum.sort(Map.keys(checkpoint)) == Enum.sort(@v2_checkpoint_keys) and
      checkpoint == checkpoint(binding, next_chunk_index)
  end

  defp valid_checkpoint?(_checkpoint, _binding), do: false

  defp checkpoint(binding, next_chunk_index) do
    %{
      "version" => 2,
      "next_chunk_index" => next_chunk_index,
      "job_id" => binding.job_id,
      "vault_id" => binding.vault_id,
      "principal_id" => binding.principal_id,
      "required_capability" => binding.required_capability,
      "principal_authorization_epoch" => binding.principal_authorization_epoch,
      "vault_authorization_epoch" => binding.vault_authorization_epoch,
      "object_id" => binding.object_id,
      "object_generation" => binding.object_generation
    }
  end

  defp v2_checkpoint_query(binding, classification) do
    from(progress in JobProgress,
      where: progress.submission_id == ^binding.job_id,
      where: progress.vault_id == ^binding.vault_id,
      where: progress.classification == ^classification,
      where: progress.checkpoint_version == 2,
      select: %{checkpoint: progress.checkpoint},
      limit: 2
    )
  end

  defp v3_checkpoint_query(binding, classification) do
    binding
    |> checkpoint_row_query(classification)
    |> where([progress], progress.state == :running)
  end

  defp checkpoint_cas_miss_query(binding, classification),
    do: checkpoint_row_query(binding, classification)

  defp checkpoint_row_query(binding, classification) do
    from(progress in JobProgress,
      where: progress.submission_id == ^binding.job_id,
      where: progress.vault_id == ^binding.vault_id,
      where: progress.classification == ^classification,
      select: %{
        checkpoint_version: progress.checkpoint_version,
        processing_revision: progress.processing_revision,
        state: progress.state,
        checkpoint: progress.checkpoint
      },
      limit: 2
    )
  end

  defp validate_checkpoint_columns(2, _processing_revision, _state, _binding, 2), do: :ok

  defp validate_checkpoint_columns(
         3,
         processing_revision,
         :running,
         %{processing_revision: processing_revision},
         3
       ),
       do: :ok

  defp validate_checkpoint_columns(3, _processing_revision, _state, _binding, 3),
    do: {:error, Error.new(:conflict)}

  defp validate_checkpoint_columns(
         _stored_version,
         _processing_revision,
         _state,
         _binding,
         _version
       ),
       do: {:error, Error.new(:integrity_failure)}

  defp validate_stored_metadata_checkpoint(
         %{
           "extractor_state" => extractor_state,
           "job_id" => job_id,
           "vault_id" => vault_id,
           "principal_id" => principal_id,
           "required_capability" => required_capability,
           "principal_authorization_epoch" => principal_authorization_epoch,
           "vault_authorization_epoch" => vault_authorization_epoch,
           "object_id" => object_id,
           "object_generation" => object_generation
         } = checkpoint,
         3,
         processing_revision,
         state
       )
       when is_integer(processing_revision) and processing_revision in 1..@max_bigint and
              state in [:running, :waiting_for_unlock, :completed, :failed] do
    with {declared_media_type, plaintext_byte_size} <- metadata_state_target(extractor_state),
         :ok <-
           validate_checkpoint(
             checkpoint,
             %{
               job_id: job_id,
               vault_id: vault_id,
               principal_id: principal_id,
               required_capability: required_capability,
               principal_authorization_epoch: principal_authorization_epoch,
               vault_authorization_epoch: vault_authorization_epoch,
               object_id: object_id,
               object_generation: object_generation,
               processing_revision: processing_revision,
               declared_media_type: declared_media_type,
               plaintext_byte_size: plaintext_byte_size
             },
             3
           ) do
      :ok
    else
      _malformed -> {:error, Error.new(:integrity_failure)}
    end
  end

  defp validate_stored_metadata_checkpoint(
         _checkpoint,
         _checkpoint_version,
         _processing_revision,
         _state
       ),
       do: {:error, Error.new(:integrity_failure)}

  defp checkpoint_cas_query(binding, classification, version, expected) do
    query =
      from(progress in JobProgress,
        where: progress.submission_id == ^binding.job_id,
        where: progress.vault_id == ^binding.vault_id,
        where: progress.classification == ^classification,
        where: progress.checkpoint_version == ^version,
        where: progress.checkpoint == ^expected
      )

    if version == 3 do
      where(
        query,
        [progress],
        progress.processing_revision == ^binding.processing_revision and
          progress.state == :running
      )
    else
      query
    end
  end

  defp checkpoint_version(%{session_id: _session_id}), do: {:ok, 2}

  defp checkpoint_version(%{processing_revision: processing_revision})
       when is_integer(processing_revision) and processing_revision > 0,
       do: {:ok, 3}

  defp checkpoint_version(binding) do
    if Map.has_key?(binding, :processing_revision),
      do: {:error, Error.new(:invalid)},
      else: {:ok, 2}
  end

  defp validate_checkpoint(checkpoint, binding, 2) do
    if valid_checkpoint?(checkpoint, binding),
      do: :ok,
      else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_checkpoint(
         %{
           "version" => 3,
           "protocol" => @metadata_protocol,
           "next_chunk_index" => next_chunk_index,
           "processing_revision" => processing_revision,
           "extractor_state" => extractor_state,
           "job_id" => job_id,
           "vault_id" => vault_id,
           "principal_id" => principal_id,
           "required_capability" => required_capability,
           "principal_authorization_epoch" => principal_authorization_epoch,
           "vault_authorization_epoch" => vault_authorization_epoch,
           "object_id" => object_id,
           "object_generation" => object_generation
         } = persisted,
         binding,
         3
       ) do
    with true <- Enum.sort(Map.keys(persisted)) == Enum.sort(@metadata_checkpoint_keys),
         true <- is_integer(next_chunk_index) and next_chunk_index in 0..@max_bigint,
         true <- is_integer(processing_revision) and processing_revision in 1..@max_bigint,
         true <- valid_uuid?(job_id),
         true <- valid_uuid?(vault_id),
         true <- valid_uuid?(principal_id),
         true <- valid_text?(required_capability, 128),
         true <-
           is_integer(principal_authorization_epoch) and
             principal_authorization_epoch in 0..@max_bigint,
         true <-
           is_integer(vault_authorization_epoch) and
             vault_authorization_epoch in 0..@max_bigint,
         true <- valid_uuid?(object_id),
         true <- is_integer(object_generation) and object_generation in 1..@max_bigint,
         true <- is_map(extractor_state),
         :ok <- validate_extractor_state(extractor_state),
         :ok <- validate_metadata_position(next_chunk_index, extractor_state),
         :ok <- validate_metadata_target(extractor_state, binding) do
      expected = metadata_checkpoint(binding, next_chunk_index, extractor_state)

      if persisted == expected,
        do: :ok,
        else: {:error, Error.new(:conflict)}
    else
      false -> {:error, Error.new(:integrity_failure)}
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_checkpoint(%{"version" => 3}, _binding, 3),
    do: {:error, Error.new(:integrity_failure)}

  defp validate_checkpoint(_checkpoint, _binding, _version),
    do: {:error, Error.new(:integrity_failure)}

  defp metadata_checkpoint(binding, next_chunk_index, extractor_state) do
    %{
      "version" => 3,
      "protocol" => @metadata_protocol,
      "next_chunk_index" => next_chunk_index,
      "processing_revision" => binding.processing_revision,
      "extractor_state" => extractor_state,
      "job_id" => binding.job_id,
      "vault_id" => binding.vault_id,
      "principal_id" => binding.principal_id,
      "required_capability" => binding.required_capability,
      "principal_authorization_epoch" => binding.principal_authorization_epoch,
      "vault_authorization_epoch" => binding.vault_authorization_epoch,
      "object_id" => binding.object_id,
      "object_generation" => binding.object_generation
    }
  end

  defp validate_metadata_position(0, %{"phase" => "start"}), do: :ok

  defp validate_metadata_position(_next_chunk_index, %{"phase" => "start"}),
    do: {:error, Error.new(:integrity_failure)}

  defp validate_metadata_position(
         next_chunk_index,
         %{
           "phase" => "jpeg_scan",
           "plaintext_bytes" => plaintext_bytes,
           "cursor" => cursor
         }
       ) do
    max_chunks = metadata_chunk_count(plaintext_bytes)

    if is_integer(next_chunk_index) and next_chunk_index >= 1 and
         next_chunk_index < max_chunks and
         cursor >= next_chunk_index * Format.chunk_size(),
       do: :ok,
       else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_metadata_position(next_chunk_index, %{"phase" => phase} = state)
       when phase in ["done", "failed"] do
    plaintext_bytes =
      case state do
        %{"phase" => "done", "result" => %{"plaintext_bytes" => value}} -> value
        %{"phase" => "failed", "plaintext_bytes" => value} -> value
      end

    if is_integer(next_chunk_index) and
         next_chunk_index in 1..metadata_chunk_count(plaintext_bytes),
       do: :ok,
       else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_metadata_position(_next_chunk_index, _extractor_state),
    do: {:error, Error.new(:integrity_failure)}

  defp metadata_chunk_count(plaintext_bytes),
    do: max(1, div(plaintext_bytes + Format.chunk_size() - 1, Format.chunk_size()))

  defp validate_extractor_state(
         %{
           "phase" => "start",
           "declared_media_type" => declared_media_type,
           "plaintext_bytes" => plaintext_bytes
         } = state
       ) do
    if exact_keys?(state, ~w[phase declared_media_type plaintext_bytes]) and
         valid_text?(declared_media_type, 255) and valid_plaintext_size?(plaintext_bytes),
       do: :ok,
       else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_extractor_state(%{"phase" => "jpeg_scan"} = state) do
    if valid_jpeg_state?(state),
      do: :ok,
      else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_extractor_state(%{"phase" => "done", "result" => result} = state) do
    if exact_keys?(state, ~w[phase result]) and valid_metadata_result?(result),
      do: :ok,
      else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_extractor_state(
         %{
           "phase" => "failed",
           "error_code" => error_code,
           "declared_media_type" => declared_media_type,
           "plaintext_bytes" => plaintext_bytes
         } = state
       ) do
    if exact_keys?(state, ~w[phase error_code declared_media_type plaintext_bytes]) and
         error_code in ["integrity_failure", "unsupported_media_type"] and
         valid_text?(declared_media_type, 255) and valid_plaintext_size?(plaintext_bytes),
       do: :ok,
       else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_extractor_state(_state),
    do: {:error, Error.new(:integrity_failure)}

  defp validate_metadata_target(extractor_state, binding) do
    case metadata_state_target(extractor_state) do
      {media_type, plaintext_bytes}
      when media_type == binding.declared_media_type and
             plaintext_bytes == binding.plaintext_byte_size ->
        :ok

      {_media_type, _plaintext_bytes} ->
        {:error, Error.new(:conflict)}

      :error ->
        {:error, Error.new(:integrity_failure)}
    end
  end

  defp metadata_state_target(%{
         "phase" => phase,
         "declared_media_type" => media_type,
         "plaintext_bytes" => plaintext_bytes
       })
       when phase in ["start", "jpeg_scan", "failed"],
       do: {media_type, plaintext_bytes}

  defp metadata_state_target(%{
         "phase" => "done",
         "result" => %{
           "detected_media_type" => media_type,
           "plaintext_bytes" => plaintext_bytes
         }
       }),
       do: {media_type, plaintext_bytes}

  defp metadata_state_target(_extractor_state), do: :error

  defp valid_metadata_result?(
         %{
           "detected_media_type" => detected_media_type,
           "plaintext_bytes" => plaintext_bytes,
           "width" => width,
           "height" => height,
           "pdf_version" => pdf_version,
           "extractor_version" => extractor_version
         } = result
       ) do
    exact_keys?(
      result,
      ~w[detected_media_type plaintext_bytes width height pdf_version extractor_version]
    ) and valid_plaintext_size?(plaintext_bytes) and
      extractor_version == 1 and
      valid_typed_metadata?(detected_media_type, width, height, pdf_version)
  end

  defp valid_metadata_result?(_result), do: false

  defp valid_typed_metadata?("application/pdf", nil, nil, pdf_version),
    do: valid_pdf_version?(pdf_version)

  defp valid_typed_metadata?("image/jpeg", width, height, nil),
    do: dimension?(width, 65_535) and dimension?(height, 65_535)

  defp valid_typed_metadata?("image/png", width, height, nil),
    do: dimension?(width, 2_147_483_647) and dimension?(height, 2_147_483_647)

  defp valid_typed_metadata?(_media_type, _width, _height, _pdf_version), do: false

  defp valid_jpeg_state?(
         %{
           "phase" => "jpeg_scan",
           "declared_media_type" => "image/jpeg",
           "plaintext_bytes" => plaintext_bytes,
           "cursor" => cursor,
           "segments_seen" => segments_seen,
           "mode" => mode
         } = state
       ) do
    valid_plaintext_size?(plaintext_bytes) and plaintext_bytes >= 2 and
      is_integer(cursor) and cursor >= 0 and cursor < plaintext_bytes and
      is_integer(segments_seen) and segments_seen in 0..255 and
      valid_jpeg_mode?(state, mode)
  end

  defp valid_jpeg_state?(_state), do: false

  defp valid_jpeg_mode?(state, mode)
       when mode == "soi_first",
       do: exact_keys?(state, jpeg_base_keys()) and state["cursor"] == 0

  defp valid_jpeg_mode?(state, "soi_second"),
    do: exact_keys?(state, jpeg_base_keys()) and state["cursor"] == 1

  defp valid_jpeg_mode?(state, "marker_prefix"),
    do: exact_keys?(state, jpeg_base_keys()) and state["cursor"] >= 2

  defp valid_jpeg_mode?(state, "marker_code"),
    do: exact_keys?(state, jpeg_base_keys()) and state["cursor"] >= 3

  defp valid_jpeg_mode?(state, "length_high"),
    do:
      exact_keys?(state, jpeg_base_keys() ++ ["segment_kind"]) and
        valid_segment_kind?(state["segment_kind"]) and
        state["cursor"] + 2 <= state["plaintext_bytes"]

  defp valid_jpeg_mode?(state, "length_low") do
    exact_keys?(state, jpeg_base_keys() ++ ["segment_kind", "segment_length_acc"]) and
      valid_segment_kind?(state["segment_kind"]) and
      shifted_accumulator?(state["segment_length_acc"]) and
      state["cursor"] + 1 <= state["plaintext_bytes"]
  end

  defp valid_jpeg_mode?(state, mode) when mode in ["sof_precision", "sof_height_high"] do
    exact_keys?(state, jpeg_base_keys() ++ ["segment_kind", "segment_length"]) and
      state["segment_kind"] == "sof" and valid_segment_length?(state["segment_length"]) and
      valid_sof_bounds?(state, mode)
  end

  defp valid_jpeg_mode?(state, "sof_height_low") do
    exact_keys?(
      state,
      jpeg_base_keys() ++ ["segment_kind", "segment_length", "height_acc"]
    ) and state["segment_kind"] == "sof" and
      valid_segment_length?(state["segment_length"]) and
      shifted_accumulator?(state["height_acc"]) and
      valid_sof_bounds?(state, "sof_height_low")
  end

  defp valid_jpeg_mode?(state, "sof_width_high") do
    exact_keys?(state, jpeg_base_keys() ++ ["segment_kind", "segment_length", "height"]) and
      state["segment_kind"] == "sof" and valid_segment_length?(state["segment_length"]) and
      dimension?(state["height"], 65_535) and valid_sof_bounds?(state, "sof_width_high")
  end

  defp valid_jpeg_mode?(state, "sof_width_low") do
    exact_keys?(
      state,
      jpeg_base_keys() ++ ["segment_kind", "segment_length", "height", "width_acc"]
    ) and state["segment_kind"] == "sof" and
      valid_segment_length?(state["segment_length"]) and
      dimension?(state["height"], 65_535) and
      shifted_accumulator?(state["width_acc"]) and
      valid_sof_bounds?(state, "sof_width_low")
  end

  defp valid_jpeg_mode?(state, "sof_components") do
    exact_keys?(
      state,
      jpeg_base_keys() ++ ["segment_kind", "segment_length", "height", "width"]
    ) and state["segment_kind"] == "sof" and
      valid_segment_length?(state["segment_length"]) and
      dimension?(state["height"], 65_535) and dimension?(state["width"], 65_535) and
      valid_sof_bounds?(state, "sof_components")
  end

  defp valid_jpeg_mode?(_state, _mode), do: false

  defp jpeg_base_keys,
    do: ~w[phase declared_media_type plaintext_bytes cursor segments_seen mode]

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp valid_segment_kind?(segment_kind), do: segment_kind in ["sof", "skip"]
  defp valid_segment_length?(value), do: is_integer(value) and value in 8..65_535

  defp shifted_accumulator?(value),
    do: is_integer(value) and value in 0..65_280 and rem(value, 256) == 0

  defp valid_sof_bounds?(state, mode) do
    consumed_after_length = %{
      "sof_precision" => 0,
      "sof_height_high" => 1,
      "sof_height_low" => 2,
      "sof_width_high" => 3,
      "sof_width_low" => 4,
      "sof_components" => 5
    }

    remaining = state["segment_length"] - 2 - Map.fetch!(consumed_after_length, mode)
    remaining >= 1 and state["cursor"] + remaining <= state["plaintext_bytes"]
  end

  defp valid_pdf_version?(<<major, ?., minor>>),
    do: major in ?0..?9 and minor in ?0..?9

  defp valid_pdf_version?(_version), do: false

  defp dimension?(value, maximum),
    do: is_integer(value) and value in 1..maximum

  defp valid_plaintext_size?(value),
    do: is_integer(value) and value >= 0 and value <= @max_bigint

  defp valid_text?(value, max_bytes),
    do: is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes

  defp digest?(value), do: is_binary(value) and byte_size(value) == 32
  defp valid_uuid?(value), do: UUID.validate(value) == :ok

  defp unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
