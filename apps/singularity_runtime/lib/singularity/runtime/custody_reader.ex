defmodule Singularity.Runtime.CustodyReader do
  @moduledoc """
  Custody-only object-key loading and authenticated object reads.

  The object DEK is unwrapped only while `KeyCustodian` is issuing a lease.
  Callers receive the opaque lease and authenticated plaintext chunks, never
  any member of the vault, domain, or object key hierarchy.
  """

  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Storage.AuthenticatedReader
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.ScopedRepo

  @classifications [:private, :sensitive, :restricted]

  @spec utc_now(term()) :: DateTime.t()
  def utc_now(_context), do: DateTime.utc_now()

  @spec load_object_key(map(), map(), map()) ::
          {:ok, %{object_dek: <<_::256>>, reader_binding: map()}}
          | {:error, :waiting_for_unlock | Error.t()}
  def load_object_key(context, binding, hierarchy)
      when is_map(context) and is_map(binding) and is_map(hierarchy) do
    with {:ok, material} <-
           with_scope(context, binding, fn repository, repo ->
             repository.load_reader_material(repo, binding)
           end),
         :ok <- validate_material(material, binding, hierarchy),
         {:ok, <<_::binary-size(32)>> = object_dek} <-
           unwrap(context, hierarchy.domain_key, material) do
      {:ok,
       %{
         object_dek: object_dek,
         reader_binding: reader_binding(material)
       }}
    else
      {:error, :waiting_for_unlock} = waiting -> waiting
      {:error, %Error{}} = error -> error
      _invalid -> integrity_failure()
    end
  rescue
    _error -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def load_object_key(_context, _binding, _hierarchy),
    do: {:error, Error.new(:invalid)}

  @spec revalidate(map(), map()) ::
          :ok | {:error, :waiting_for_unlock | Error.t()}
  def revalidate(%{object_binding: reader_binding} = context, binding)
      when is_map(reader_binding) and is_map(binding) do
    with_scope(context, binding, fn repository, repo ->
      repository.revalidate_reader(repo, binding, reader_binding)
    end)
    |> normalize_status()
  rescue
    _error -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def revalidate(_context, _binding), do: {:error, Error.new(:invalid)}

  @spec load_checkpoint(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def load_checkpoint(%{object_binding: reader_binding} = context, binding)
      when is_map(reader_binding) and is_map(binding) do
    with_scope(context, binding, fn repository, repo ->
      repository.load_checkpoint(repo, binding, reader_binding.classification)
    end)
    |> normalize_value()
  rescue
    _error -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def load_checkpoint(_context, _binding), do: {:error, Error.new(:invalid)}

  @spec persist_checkpoint(map(), map(), map(), map()) ::
          :ok | {:error, Error.t()}
  def persist_checkpoint(
        %{object_binding: reader_binding} = context,
        binding,
        expected,
        next
      )
      when is_map(reader_binding) and is_map(binding) and is_map(expected) and
             is_map(next) do
    with_scope(context, binding, fn repository, repo ->
      repository.persist_checkpoint(
        repo,
        binding,
        reader_binding.classification,
        expected,
        next
      )
    end)
    |> normalize_status()
  rescue
    _error -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def persist_checkpoint(_context, _binding, _expected, _next),
    do: {:error, Error.new(:invalid)}

  @spec read_chunk(map(), map(), non_neg_integer()) ::
          {:ok, binary()} | {:error, Error.t()}
  def read_chunk(
        %{
          key_material: <<_::binary-size(32)>> = object_dek,
          object_binding: reader_binding
        } = context,
        binding,
        index
      )
      when is_map(reader_binding) and is_map(binding) and is_integer(index) and
             index >= 0 do
    with :ok <- exact_reader_binding(reader_binding, binding),
         {:ok, range} <- chunk_range(reader_binding.plaintext_byte_size, index),
         {:ok, storage} <- storage(context, reader_binding) do
      AuthenticatedReader.read(storage, authenticated_binding(reader_binding), object_dek, range)
    end
  rescue
    _error -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def read_chunk(_context, _binding, _index), do: {:error, Error.new(:invalid)}

  @spec read_range(map(), map(), :all | Range.t()) ::
          {:ok, binary()} | {:error, Error.t()}
  def read_range(
        %{
          key_material: <<_::binary-size(32)>> = object_dek,
          object_binding: reader_binding
        } = context,
        binding,
        range
      )
      when is_map(reader_binding) and is_map(binding) do
    with :ok <- exact_reader_binding(reader_binding, binding),
         {:ok, storage} <- storage(context, reader_binding) do
      AuthenticatedReader.read(
        storage,
        authenticated_binding(reader_binding),
        object_dek,
        range
      )
    end
  rescue
    _error -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def read_range(_context, _binding, _range),
    do: {:error, Error.new(:invalid)}

  defp validate_material(
         %{
           object_id: object_id,
           object_generation: object_generation,
           vault_id: vault_id,
           key_domain_id: key_domain_id,
           domain_key_version_id: domain_key_version_id,
           domain_key_generation: domain_key_generation,
           domain_classification: domain_classification,
           classification: classification,
           envelope_classification: envelope_classification,
           lifecycle: :available,
           wrapper_algorithm: "aes_256_gcm",
           wrapped_dek: wrapped_dek,
           lookup_digest: <<_::binary-size(32)>>,
           ciphertext_hash: <<_::binary-size(32)>>,
           plaintext_byte_size: plaintext_byte_size,
           ciphertext_byte_size: ciphertext_byte_size,
           format_version: format_version
         },
         %{
           object_id: object_id,
           object_generation: object_generation,
           vault_id: vault_id
         },
         %{
           domain_key: <<_::binary-size(32)>>,
           key_domain_id: key_domain_id,
           domain_key_version_id: domain_key_version_id,
           domain_key_generation: domain_key_generation,
           domain_classification: domain_classification
         }
       )
       when classification in @classifications and
              classification == envelope_classification and
              classification == domain_classification and
              is_binary(wrapped_dek) and byte_size(wrapped_dek) > 0 and
              is_integer(object_generation) and object_generation > 0 and
              is_integer(domain_key_generation) and domain_key_generation > 0 and
              is_integer(plaintext_byte_size) and plaintext_byte_size >= 0 and
              is_integer(ciphertext_byte_size) and ciphertext_byte_size >= 0 and
              is_integer(format_version) and format_version > 0,
       do: :ok

  defp validate_material(_material, _binding, _hierarchy),
    do: {:error, Error.new(:integrity_failure)}

  defp unwrap(context, domain_key, material) do
    call_adapter(context.key_wrapper, :unwrap, [
      domain_key,
      material.wrapped_dek,
      %{
        purpose: :object_dek,
        generation: material.object_generation,
        aad: "object:" <> material.object_id
      }
    ])
  end

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

  defp exact_reader_binding(
         %{
           object_id: object_id,
           object_generation: object_generation,
           vault_id: vault_id
         },
         %{
           object_id: object_id,
           object_generation: object_generation,
           vault_id: vault_id
         }
       ),
       do: :ok

  defp exact_reader_binding(_reader_binding, _binding),
    do: {:error, Error.new(:conflict)}

  defp chunk_range(plaintext_byte_size, index)
       when is_integer(plaintext_byte_size) and plaintext_byte_size > 0 do
    first = index * Format.chunk_size()

    if first < plaintext_byte_size do
      {:ok, first..min(first + Format.chunk_size() - 1, plaintext_byte_size - 1)}
    else
      {:error, Error.new(:conflict)}
    end
  end

  defp chunk_range(_plaintext_byte_size, _index),
    do: {:error, Error.new(:conflict)}

  defp authenticated_binding(reader_binding) do
    %{
      object_ref: %ObjectRef{object_id: reader_binding.object_id},
      object_id: reader_binding.object_id,
      vault_id: reader_binding.vault_id,
      encryption_domain_id: reader_binding.key_domain_id,
      plaintext_byte_size: reader_binding.plaintext_byte_size,
      ciphertext_byte_size: reader_binding.ciphertext_byte_size,
      format_version: reader_binding.format_version
    }
  end

  defp storage(%{storage: storage}, reader_binding) do
    with {:ok, %{adapter: adapter, context: base_context}} <-
           configured_storage(storage) do
      {:ok,
       %{
         adapter: adapter,
         context:
           base_context
           |> Map.put(:vault_namespace, reader_binding.vault_id)
           |> Map.put(:domain_namespace, reader_binding.key_domain_id)
           |> Map.put(
             :lookup_digest,
             Base.encode16(reader_binding.lookup_digest, case: :lower)
           )
           |> Map.put(:ciphertext_hash, reader_binding.ciphertext_hash)
       }}
    end
  end

  defp storage(_context, _reader_binding),
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp configured_storage(%{adapter: adapter, context: context})
       when is_atom(adapter) and is_map(context),
       do: {:ok, %{adapter: adapter, context: context}}

  defp configured_storage(module) when is_atom(module) and not is_nil(module) do
    case module.configured() do
      {adapter, context} when is_atom(adapter) and is_map(context) ->
        {:ok, %{adapter: adapter, context: context}}

      _invalid ->
        unavailable()
    end
  end

  defp configured_storage(_storage), do: unavailable()

  defp with_scope(context, binding, callback) do
    repository = Map.fetch!(context, :repository_adapter)
    repo = Map.fetch!(context, :repo)
    scope = Map.get(context, :scope, ScopedRepo)

    call_adapter(scope, :transact, [
      repo,
      binding,
      fn checked_out_repo -> callback.(repository, checked_out_repo) end
    ])
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, adapter_context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [adapter_context | arguments])
  end

  defp normalize_status(:ok), do: :ok
  defp normalize_status({:error, :waiting_for_unlock} = waiting), do: waiting
  defp normalize_status({:error, %Error{}} = error), do: error
  defp normalize_status(_invalid), do: integrity_failure()

  defp normalize_value({:ok, value}), do: {:ok, value}
  defp normalize_value({:error, %Error{}} = error), do: error
  defp normalize_value(_invalid), do: integrity_failure()

  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}

  defp unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
