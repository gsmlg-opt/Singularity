defmodule Singularity.Runtime.RestoreAuthenticator do
  @moduledoc "Authenticates a complete logical backup before issuing restore authority."

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Backup.Manifest
  alias Singularity.Storage.Crypto.RecoveredVaultKey

  @context_keys [
    :backup_cipher,
    :backup_key_deriver,
    :backup_key_lease,
    :bundle_reader,
    :destination,
    :logical_verifier,
    :recovered_vault_key,
    :restore_crypto_adapter,
    :restore_key_ttl_ms
  ]

  defmodule Authenticated do
    @moduledoc "Opaque authenticated handoff for maintenance restore."

    @enforce_keys [:binding, :cut, :lease, :verified]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            binding: map(),
            cut: map(),
            lease: pid(),
            verified: BundleReader.Verified.t()
          }
  end

  defimpl Inspect, for: Authenticated do
    import Inspect.Algebra

    def inspect(_authenticated, _options),
      do: concat(["#RestoreAuthenticator.Authenticated<REDACTED>"])
  end

  @spec authenticate_all(map(), binary(), binary()) ::
          {:ok, Authenticated.t()} | {:error, Error.t()}
  def authenticate_all(context, destination_ref, passphrase)
      when is_map(context) and is_binary(destination_ref) and destination_ref != "" and
             is_binary(passphrase) and passphrase != "" do
    with {:ok, adapters} <- adapters(context),
         {:ok, source} <- adapter_value(adapters.destination, :reader_source, [destination_ref]),
         {:ok, public_header} <-
           adapter_value(adapters.bundle_reader, :read_public_header, [source]),
         {:ok, binding, kdf} <- public_header(public_header),
         {:ok, <<_::binary-size(32)>> = backup_key} <-
           adapter_value(adapters.backup_key_deriver, :derive, [passphrase, kdf]) do
      authenticate_with_key(
        adapters,
        source,
        destination_ref,
        public_header,
        binding,
        backup_key
      )
    else
      {:error, %Error{code: :storage_unavailable} = error} -> public_error(error)
      {:error, %Error{code: :not_found} = error} -> public_error(error)
      {:error, %Error{}} -> backup_invalid()
      _invalid -> backup_invalid()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def authenticate_all(_context, _destination_ref, _passphrase), do: invalid()

  @spec claim_recovered_vault_key(map(), Authenticated.t()) ::
          {:ok, RecoveredVaultKey.t()} | {:error, Error.t()}
  def claim_recovered_vault_key(
        context,
        %Authenticated{lease: lease, verified: verified} = authenticated
      )
      when is_map(context) and is_pid(lease) do
    with {:ok, adapters} <- adapters(context),
         {:ok, manifest} <- authenticated_manifest(verified, authenticated.binding),
         expected_proof = proof(verified, manifest, authenticated.binding),
         ^expected_proof <- authentication_proof(verified),
         {:ok, %RecoveredVaultKey{} = capability} <-
           adapter_value(adapters.backup_key_lease, :claim_recovered_vault_key, [
             lease,
             expected_proof
           ]) do
      {:ok, capability}
    else
      {:error, %Error{}} -> backup_invalid()
      _invalid -> backup_invalid()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def claim_recovered_vault_key(_context, _authenticated), do: invalid()

  @spec revoke(map(), Authenticated.t()) :: :ok
  def revoke(context, %Authenticated{lease: lease, verified: verified}) when is_map(context) do
    case adapters(context) do
      {:ok, adapters} ->
        _discarded = safe_call(adapters.bundle_reader, :discard_verified, [verified])
        _revoked = safe_call(adapters.backup_key_lease, :revoke, [lease])
        :ok

      _invalid ->
        :ok
    end
  end

  def revoke(_context, _authenticated), do: :ok

  defp authenticate_with_key(
         adapters,
         source,
         destination_ref,
         public_header,
         binding,
         backup_key
       ) do
    try do
      start_restore_lease(adapters, public_header, binding, backup_key)
      |> case do
        {:ok, lease} ->
          authenticate_with_lease(
            adapters,
            lease,
            source,
            destination_ref,
            binding
          )

        {:error, %Error{}} = error ->
          error

        _invalid ->
          storage_unavailable()
      end
    after
      _cleared = overwrite(backup_key)
    end
  end

  defp start_restore_lease(adapters, public_header, binding, backup_key) do
    safe_call(adapters.backup_key_lease, :start_restore_link, [
      %{
        active_ttl_ms: adapters.restore_key_ttl_ms,
        binding: binding,
        cipher: adapters.backup_cipher,
        custodian: self(),
        key_material: backup_key,
        public_header: public_header
      }
    ])
  end

  defp authenticate_with_lease(adapters, lease, source, destination_ref, binding)
       when is_pid(lease) do
    result =
      with verifier_binding = %{
             destination_ref: destination_ref,
             manifest_id: binding.manifest_id,
             vault_id: binding.vault_id
           },
           {:ok, %BundleReader.Verified{} = verified} <-
             adapter_value(adapters.bundle_reader, :authenticate_all, [
               source,
               [
                 crypto: {adapters.restore_crypto_adapter, lease},
                 verifier: {adapters.logical_verifier, verifier_binding}
               ]
             ]) do
        authenticate_verified(adapters, lease, verified, destination_ref, binding)
      else
        {:error, %Error{code: :storage_unavailable} = error} -> public_error(error)
        {:error, %Error{}} -> backup_invalid()
        _invalid -> backup_invalid()
      end

    case result do
      {:ok, %Authenticated{}} = authenticated ->
        authenticated

      {:error, %Error{}} = error ->
        _revoked = safe_call(adapters.backup_key_lease, :revoke, [lease])
        error
    end
  rescue
    _exception ->
      _revoked = safe_call(adapters.backup_key_lease, :revoke, [lease])
      storage_unavailable()
  catch
    _kind, _reason ->
      _revoked = safe_call(adapters.backup_key_lease, :revoke, [lease])
      storage_unavailable()
  end

  defp authenticate_with_lease(_adapters, _lease, _source, _destination_ref, _binding),
    do: storage_unavailable()

  defp authenticate_verified(adapters, lease, verified, destination_ref, binding) do
    result =
      with {:ok, manifest} <- authenticated_manifest(verified, binding),
           logical_binding = %{
             destination_ref: destination_ref,
             manifest_id: binding.manifest_id,
             recovery: manifest.recovery,
             vault_id: binding.vault_id
           },
           cut when is_map(cut) <- verified.cut,
           :ok <- validate_cut(cut, manifest, binding),
           expected_proof = proof(verified, manifest, binding),
           ^expected_proof <- authentication_proof(verified) do
        {:ok,
         %Authenticated{
           binding: logical_binding,
           cut: cut,
           lease: lease,
           verified: verified
         }}
      else
        {:error, %Error{code: :storage_unavailable} = error} -> public_error(error)
        {:error, %Error{}} -> backup_invalid()
        _invalid -> backup_invalid()
      end

    case result do
      {:ok, %Authenticated{}} = authenticated ->
        authenticated

      {:error, %Error{}} = error ->
        _discarded = safe_call(adapters.bundle_reader, :discard_verified, [verified])
        error
    end
  rescue
    _exception ->
      _discarded = safe_call(adapters.bundle_reader, :discard_verified, [verified])
      storage_unavailable()
  catch
    _kind, _reason ->
      _discarded = safe_call(adapters.bundle_reader, :discard_verified, [verified])
      storage_unavailable()
  end

  defp authenticated_manifest(
         %BundleReader.Verified{
           manifest: manifest,
           manifest_hash: <<_::binary-size(32)>>,
           manifest_tag: <<_::binary-size(16)>>
         },
         binding
       ) do
    with {:ok, manifest} <- Manifest.new(manifest),
         true <- manifest.manifest_id == binding.manifest_id,
         true <- manifest.vault_ids == [binding.vault_id] do
      {:ok, manifest}
    else
      _invalid -> backup_invalid()
    end
  end

  defp authenticated_manifest(_verified, _binding), do: backup_invalid()

  defp validate_cut(cut, manifest, binding) when is_map(cut) do
    if Map.get(cut, :manifest_id) == binding.manifest_id and
         Map.get(cut, :vault_id) == binding.vault_id and
         Map.get(cut, :snapshot_id) == manifest.snapshot_id and
         Map.get(cut, :outbox_high_water_mark) == manifest.outbox_high_water_mark and
         is_list(Map.get(cut, :object_inventory)) do
      :ok
    else
      backup_invalid()
    end
  end

  defp validate_cut(_cut, _manifest, _binding), do: backup_invalid()

  defp proof(verified, manifest, binding) do
    recovery = manifest.recovery

    %{
      manifest_hash: verified.manifest_hash,
      manifest_id: binding.manifest_id,
      manifest_tag: verified.manifest_tag,
      recovery: %{
        binding: %{
          manifest_id: binding.manifest_id,
          vault_id: binding.vault_id
        },
        label: "backup_recovery",
        wrapper_sha256: :crypto.hash(:sha256, recovery["wrapper"])
      },
      vault_id: binding.vault_id
    }
  end

  defp authentication_proof(%BundleReader.Verified{authentication: %{proof: proof}}),
    do: proof

  defp authentication_proof(_verified), do: nil

  defp public_header(
         %{
           version: 1,
           manifest_id: manifest_id,
           vault_id: vault_id,
           kdf:
             %{
               "domain" => domain,
               "parameters" => parameters,
               "salt" => encoded_salt
             } = encoded_kdf
         } = public_header
       )
       when map_size(public_header) == 4 and map_size(encoded_kdf) == 3 and
              is_binary(domain) and domain != "" and is_map(parameters) and
              is_binary(encoded_salt) and encoded_salt != "" do
    with true <- canonical_uuid?(manifest_id),
         true <- canonical_uuid?(vault_id),
         {:ok, salt} <- Base.decode64(encoded_salt),
         true <- byte_size(salt) == 16,
         true <- Base.encode64(salt) == encoded_salt do
      {:ok, %{manifest_id: manifest_id, vault_id: vault_id},
       %{domain: domain, parameters: parameters, salt: salt}}
    else
      _invalid -> backup_invalid()
    end
  end

  defp public_header(_public_header), do: backup_invalid()

  defp adapters(context) do
    values = Map.take(context, @context_keys)

    if map_size(values) == length(@context_keys) and
         Enum.all?(@context_keys, &concrete?(Map.get(values, &1))) and
         is_integer(values.restore_key_ttl_ms) and values.restore_key_ttl_ms > 0 and
         is_atom(values.restore_crypto_adapter) do
      {:ok, values}
    else
      invalid()
    end
  end

  defp adapter_value(adapter, function, arguments) do
    case safe_call(adapter, function, arguments) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      {:error, %Error{} = error} -> public_error(error)
      _malformed -> storage_unavailable()
    end
  end

  defp safe_call(adapter, function, arguments) do
    call_adapter(adapter, function, arguments)
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, adapter_context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [adapter_context | arguments])

  defp public_error(%Error{code: code, retryable?: retryable?})
       when code in [:backup_invalid, :invalid, :not_found, :storage_unavailable] and
              is_boolean(retryable?),
       do: {:error, Error.new(code, retryable?: retryable?)}

  defp public_error(_error), do: storage_unavailable()

  defp canonical_uuid?(value) when is_binary(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp canonical_uuid?(_value), do: false

  defp concrete?(value), do: value not in [nil, false]

  defp overwrite(secret) when is_binary(secret),
    do: :binary.copy(<<0>>, byte_size(secret))

  defp overwrite(_secret), do: nil

  defp invalid, do: {:error, Error.new(:invalid)}
  defp backup_invalid, do: {:error, Error.new(:backup_invalid)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
