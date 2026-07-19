defmodule Singularity.Storage.Postgres.CustodyRepository do
  @moduledoc """
  Least-privilege PostgreSQL reads and checkpoint CAS for plaintext custody.

  Every call is expected to run inside `ScopedRepo` with the requesting
  principal and vault already installed as transaction-local RLS context.
  """

  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Content.AssetKeyEnvelope
  alias Singularity.Storage.Schema.Content.AssetObject
  alias Singularity.Storage.Schema.Core.DomainKeyVersion
  alias Singularity.Storage.Schema.Core.KeyDomain
  alias Singularity.Storage.Schema.Jobs.JobProgress

  @classifications [:private, :sensitive, :restricted]
  @classification_rank %{private: 0, sensitive: 1, restricted: 2}
  @checkpoint_keys ~w[
    version next_chunk_index job_id vault_id principal_id required_capability
    principal_authorization_epoch vault_authorization_epoch object_id
    object_generation
  ]

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
    with :ok <- validate_binding(binding) do
      case repo.all(
             from(progress in JobProgress,
               where: progress.submission_id == ^binding.job_id,
               where: progress.vault_id == ^binding.vault_id,
               where: progress.classification == ^classification,
               where: progress.checkpoint_version == 2,
               select: progress.checkpoint,
               limit: 2
             )
           ) do
        [checkpoint] when is_map(checkpoint) -> {:ok, checkpoint}
        [] -> {:error, Error.new(:conflict)}
        [_first, _second] -> {:error, Error.new(:integrity_failure)}
      end
    end
  rescue
    _error in [Ecto.Query.CastError, DBConnection.ConnectionError, Postgrex.Error] ->
      unavailable()
  end

  def load_checkpoint(_repo, _binding, _classification),
    do: {:error, Error.new(:invalid)}

  @spec persist_checkpoint(module(), map(), atom(), map(), map()) ::
          :ok | {:error, Error.t()}
  def persist_checkpoint(repo, binding, classification, expected, next)
      when is_map(binding) and classification in @classifications and
             is_map(expected) and is_map(next) do
    with :ok <- validate_binding(binding),
         true <- valid_checkpoint?(expected, binding),
         true <- valid_checkpoint?(next, binding),
         true <-
           next["next_chunk_index"] ==
             expected["next_chunk_index"] + 1 do
      case repo.update_all(
             from(progress in JobProgress,
               where: progress.submission_id == ^binding.job_id,
               where: progress.vault_id == ^binding.vault_id,
               where: progress.classification == ^classification,
               where: progress.checkpoint_version == 2,
               where: progress.checkpoint == ^expected
             ),
             set: [checkpoint: next, updated_at: DateTime.utc_now()]
           ) do
        {1, _rows} -> :ok
        {0, _rows} -> {:error, Error.new(:conflict)}
      end
    else
      false -> {:error, Error.new(:invalid)}
      {:error, %Error{}} = error -> error
    end
  rescue
    _error in [Ecto.Query.CastError, DBConnection.ConnectionError, Postgrex.Error] ->
      unavailable()
  end

  def persist_checkpoint(_repo, _binding, _classification, _expected, _next),
    do: {:error, Error.new(:invalid)}

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
              is_integer(object_generation) and object_generation > 0 do
    UUID.validate([
      job_id,
      vault_id,
      principal_id,
      object_id,
      session_id
    ])
  end

  defp validate_binding(_binding), do: {:error, Error.new(:invalid)}

  defp valid_checkpoint?(
         %{
           "version" => 2,
           "next_chunk_index" => next_chunk_index
         } = checkpoint,
         binding
       )
       when is_integer(next_chunk_index) and next_chunk_index >= 0 do
    Enum.sort(Map.keys(checkpoint)) == Enum.sort(@checkpoint_keys) and
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

  defp digest?(value), do: is_binary(value) and byte_size(value) == 32
  defp valid_uuid?(value), do: UUID.validate(value) == :ok

  defp unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
