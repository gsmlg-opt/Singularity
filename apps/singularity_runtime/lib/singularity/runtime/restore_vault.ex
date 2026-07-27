defmodule Singularity.Runtime.RestoreVault do
  @moduledoc "Coordinates authenticated maintenance-mode restore phases."

  alias Singularity.Core.Error
  alias Singularity.Storage.Crypto.RecoveredVaultKey

  @request_keys [:new_password, :passphrase, :source]
  @context_keys [
    :authenticator,
    :destination,
    :integrity,
    :maintenance_mode,
    :migration_repo,
    :reconciler,
    :restorer
  ]

  @spec run(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def run(context, request) when is_map(context) and is_map(request) do
    with {:ok, adapters} <- adapters(context),
         {:ok, values} <- request_values(request),
         :ok <-
           adapter_ok(call_adapter(adapters.maintenance_mode, :require_maintenance, [])),
         :ok <-
           adapter_ok(
             call_adapter(adapters.destination, :require_empty, [adapters.migration_repo])
           ),
         {:ok, authenticated} <-
           adapter_value(
             call_adapter(adapters.authenticator, :authenticate_all, [
               values.source,
               values.passphrase
             ])
           ) do
      restore_authenticated(adapters, values, authenticated)
    else
      {:error, %Error{} = error} -> public_error(error)
      _invalid -> storage_unavailable()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def run(_context, _request), do: invalid()

  defp restore_authenticated(adapters, values, authenticated) do
    try do
      with {:ok, import_package} <- authenticated_values(authenticated),
           verified = import_package.verified,
           {:ok, authenticated_manifest_id} <- authenticated_manifest_id(verified),
           {:ok, imported} <-
             adapter_value(
               call_adapter(adapters.restorer, :import, [
                 adapters.migration_repo,
                 import_package
               ])
             ),
           :ok <- preserve_manifest_id(imported, authenticated_manifest_id),
           {:ok, %RecoveredVaultKey{} = recovered_vault_key} <-
             adapter_value(
               call_adapter(adapters.authenticator, :claim_recovered_vault_key, [
                 authenticated
               ])
             ),
           {:ok, rewrapped} <-
             adapter_value(
               call_adapter(adapters.restorer, :rewrap_owner, [
                 imported,
                 values.new_password,
                 recovered_vault_key
               ])
             ) do
        restore_rewrapped(adapters, rewrapped, authenticated_manifest_id)
      else
        {:error, %Error{} = error} -> public_error(error)
        _invalid -> backup_invalid()
      end
    after
      revoke_authenticated(adapters.authenticator, authenticated)
    end
  end

  defp restore_rewrapped(adapters, rewrapped, authenticated_manifest_id) do
    try do
      with :ok <- preserve_manifest_id(rewrapped, authenticated_manifest_id),
           {:ok, reconciliation_cut} <-
             reconciliation_cut(rewrapped, authenticated_manifest_id),
           :ok <-
             adapter_ok(call_adapter(adapters.integrity, :verify_ciphertext, [rewrapped])),
           :ok <-
             adapter_ok(call_adapter(adapters.reconciler, :reconcile, [reconciliation_cut])),
           :ok <-
             adapter_ok(
               call_adapter(adapters.integrity, :verify_plaintext_and_search, [rewrapped])
             ),
           :ok <-
             adapter_ok(call_adapter(adapters.restorer, :complete_restore, [rewrapped])) do
        {:ok, %{manifest_id: authenticated_manifest_id}}
      else
        {:error, %Error{} = error} -> public_error(error)
        _invalid -> storage_unavailable()
      end
    after
      revoke_integrity(adapters.integrity, rewrapped)
    end
  end

  defp authenticated_values(%{
         binding: binding,
         cut: cut,
         lease: lease,
         verified: verified
       })
       when is_map(binding) and is_map(cut) and not is_nil(lease) and not is_nil(verified),
       do: {:ok, %{binding: binding, cut: cut, verified: verified}}

  defp authenticated_values(_authenticated), do: backup_invalid()

  defp revoke_authenticated(authenticator, authenticated) do
    _result = call_adapter(authenticator, :revoke, [authenticated])
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp revoke_integrity(integrity, rewrapped) do
    _result = call_adapter(integrity, :revoke, [rewrapped])
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp adapters(context) do
    if Enum.all?(@context_keys, &concrete?(Map.get(context, &1))) do
      {:ok, Map.take(context, @context_keys)}
    else
      invalid()
    end
  end

  defp request_values(request) do
    with true <- Map.keys(request) |> Enum.sort() == Enum.sort(@request_keys),
         true <- nonempty?(request.source),
         true <- nonempty?(request.passphrase),
         true <- nonempty?(request.new_password) do
      {:ok, request}
    else
      _invalid -> invalid()
    end
  end

  defp authenticated_manifest_id(verified) do
    case manifest_id(verified) do
      {:ok, manifest_id} -> {:ok, manifest_id}
      :error -> backup_invalid()
    end
  end

  defp preserve_manifest_id(value, expected) do
    case manifest_id(value) do
      {:ok, ^expected} -> :ok
      _mismatch -> backup_invalid()
    end
  end

  defp reconciliation_cut(
         %{
           cut: %{
             manifest_id: manifest_id,
             outbox_high_water_mark: outbox_high_water_mark,
             vault_id: vault_id
           }
         },
         expected_manifest_id
       )
       when is_integer(outbox_high_water_mark) and outbox_high_water_mark >= 0 do
    with {:ok, ^expected_manifest_id} <- canonical_uuid(manifest_id),
         {:ok, ^vault_id} <- canonical_uuid(vault_id) do
      {:ok,
       %{
         manifest_id: manifest_id,
         outbox_high_water_mark: outbox_high_water_mark,
         vault_id: vault_id
       }}
    else
      _invalid -> backup_invalid()
    end
  end

  defp reconciliation_cut(_rewrapped, _expected_manifest_id), do: backup_invalid()

  defp manifest_id(%{manifest: %{manifest_id: manifest_id}}), do: canonical_uuid(manifest_id)
  defp manifest_id(%{manifest_id: manifest_id}), do: canonical_uuid(manifest_id)
  defp manifest_id(_restored), do: :error

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> {:ok, value}
      _invalid -> :error
    end
  end

  defp canonical_uuid(_value), do: :error

  defp adapter_ok(:ok), do: :ok
  defp adapter_ok({:error, %Error{} = error}), do: public_error(error)
  defp adapter_ok(_malformed), do: storage_unavailable()

  defp adapter_value({:ok, value}) when not is_nil(value), do: {:ok, value}
  defp adapter_value({:error, %Error{} = error}), do: public_error(error)
  defp adapter_value(_malformed), do: storage_unavailable()

  defp public_error(%Error{code: code, retryable?: retryable?})
       when code in [
              :unauthenticated,
              :vault_locked,
              :forbidden,
              :not_found,
              :conflict,
              :invalid,
              :upload_expired,
              :upload_too_large,
              :unsupported_media_type,
              :integrity_failure,
              :storage_unavailable,
              :job_failed,
              :backup_invalid
            ] and is_boolean(retryable?),
       do: {:error, Error.new(code, retryable?: retryable?)}

  defp public_error(_malformed), do: storage_unavailable()

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, adapter_context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [adapter_context | arguments])

  defp nonempty?(value), do: is_binary(value) and value != ""
  defp concrete?(value), do: value not in [nil, false]
  defp invalid, do: {:error, Error.new(:invalid)}
  defp backup_invalid, do: {:error, Error.new(:backup_invalid)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
