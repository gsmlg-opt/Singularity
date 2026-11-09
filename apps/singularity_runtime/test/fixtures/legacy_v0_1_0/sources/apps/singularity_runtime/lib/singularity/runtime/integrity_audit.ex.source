defmodule Singularity.Runtime.IntegrityAudit do
  @moduledoc """
  Coordinates locked ciphertext, authenticated plaintext, and search integrity.

  The current milestone rebuilds the PostgreSQL metadata-search projection.
  The one completion audit is persisted only after that rebuild and every
  object verification succeed.
  """

  alias Singularity.Core.Error
  alias Singularity.Runtime.RestoreIntegrityLease.Capability
  alias Singularity.Runtime.RestoreIntegrityLease.PlaintextSummary
  alias Singularity.Storage.Backup.IntegrityAudit, as: StorageIntegrityAudit
  alias Singularity.Storage.Backup.IntegrityAudit.CiphertextSummary
  alias Singularity.Storage.Backup.IntegrityAudit.SearchSummary

  @ciphertext_context_keys [:ciphertext_auditor, :object_storage]
  @final_context_keys [
    :audit,
    :ciphertext_auditor,
    :object_storage,
    :restore_integrity_lease,
    :search_rebuilder
  ]

  @spec verify_ciphertext(map(), map()) :: :ok | {:error, Error.t()}
  def verify_ciphertext(context, rewrapped) when is_map(context) and is_map(rewrapped) do
    with {:ok, target} <- restore_target(rewrapped),
         {:ok, adapters} <- adapters(context, @ciphertext_context_keys),
         {:ok, _summary} <- verify_locked(adapters, target) do
      :ok
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def verify_ciphertext(_context, _rewrapped), do: invalid()

  @spec verify_plaintext_and_search(map(), map()) :: :ok | {:error, Error.t()}
  def verify_plaintext_and_search(context, rewrapped)
      when is_map(context) and is_map(rewrapped) do
    with {:ok, capability} <- integrity_capability(rewrapped),
         {:ok, lease_adapter} <- integrity_lease_adapter(context) do
      try do
        verify_final(context, rewrapped, capability, lease_adapter)
      after
        revoke_capability(lease_adapter, capability)
      end
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def verify_plaintext_and_search(_context, _rewrapped), do: invalid()

  @doc """
  Synchronously revokes only the opaque restore-integrity capability.

  Cleanup is intentionally idempotent and best-effort at this coordinator
  boundary so it never replaces the restore phase's primary result.
  """
  @spec revoke(map(), map()) :: :ok
  def revoke(context, rewrapped) when is_map(context) and is_map(rewrapped) do
    with {:ok, capability} <- integrity_capability(rewrapped),
         {:ok, lease_adapter} <- adapter(context, :restore_integrity_lease, :revoke, 1) do
      revoke_capability(lease_adapter, capability)
    else
      _failure -> :ok
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  def revoke(_context, _rewrapped), do: :ok

  @doc """
  Runs a durable integrity job only through an injected subject loader.

  A job envelope is authority metadata, never a serialized key capability.
  The loader must obtain a fresh runtime-only subject and opaque lease.
  """
  @spec run(map(), map()) :: :ok | {:error, Error.t()}
  def run(context, %{job_type: "integrity_audit"} = envelope) when is_map(context) do
    with {:ok, subject_loader} <- adapter(context, :integrity_subject, :load, 1),
         {:ok, rewrapped} <- adapter_value(call(subject_loader, :load, [envelope])),
         true <- is_map(rewrapped) || invalid(),
         :ok <- verify_plaintext_and_search(context, rewrapped) do
      :ok
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  def run(_context, _envelope), do: {:error, Error.new(:job_failed)}

  defp verify_final(context, rewrapped, capability, lease_adapter) do
    with {:ok, target} <- restore_target(rewrapped),
         {:ok, adapters} <- adapters(context, @final_context_keys),
         true <- adapters.restore_integrity_lease == lease_adapter || invalid(),
         {:ok, ciphertext} <- verify_locked(adapters, target),
         {:ok, plaintext} <-
           adapter_value(call(lease_adapter, :verify_all, [capability])),
         {:ok, plaintext_inventory_sha256} <-
           validate_plaintext_summary(plaintext, ciphertext, target),
         {:ok, lexical} <- rebuild_lexical(adapters.search_rebuilder, target),
         :ok <-
           adapter_ok(
             call(adapters.audit, :complete, [
               completion_command(
                 target,
                 ciphertext,
                 plaintext_inventory_sha256,
                 lexical
               )
             ])
           ) do
      :ok
    end
  end

  defp verify_locked(adapters, target) do
    with {:ok, summary} <-
           adapter_value(
             call(adapters.ciphertext_auditor, :verify_ciphertext, [
               adapters.object_storage,
               target.vault_id,
               target.inventory
             ])
           ),
         :ok <- validate_ciphertext_summary(summary, target) do
      {:ok, summary}
    end
  end

  defp validate_ciphertext_summary(
         %CiphertextSummary{
           vault_id: vault_id,
           object_count: object_count,
           inventory_sha256: <<_::binary-size(32)>> = inventory_sha256,
           ciphertext_hashes: ciphertext_hashes
         },
         target
       )
       when vault_id == target.vault_id and object_count == length(target.inventory) and
              is_list(ciphertext_hashes) do
    expected_hashes =
      Enum.map(target.inventory, fn entry ->
        %{asset_object_id: entry.asset_object_id, sha256: entry.ciphertext_hash}
      end)

    with {:ok, expected_inventory_sha256} <-
           StorageIntegrityAudit.inventory_sha256(target.vault_id, target.inventory),
         true <- secure_compare(inventory_sha256, expected_inventory_sha256),
         true <- ciphertext_hashes == expected_hashes do
      :ok
    else
      _mismatch -> integrity_failure()
    end
  end

  defp validate_ciphertext_summary(_summary, _target), do: unavailable()

  defp validate_plaintext_summary(
         %PlaintextSummary{
           vault_id: vault_id,
           object_count: object_count,
           inventory_sha256: <<_::binary-size(32)>> = inventory_sha256,
           plaintext_hashes: plaintext_hashes
         },
         %CiphertextSummary{inventory_sha256: expected_inventory_sha256},
         target
       )
       when vault_id == target.vault_id and object_count == length(target.inventory) and
              is_list(plaintext_hashes) do
    expected_ids = Enum.map(target.inventory, & &1.asset_object_id)

    with true <- secure_compare(inventory_sha256, expected_inventory_sha256),
         {:ok, encoded_hashes} <- encode_plaintext_hashes(plaintext_hashes, expected_ids) do
      {:ok,
       :crypto.hash(:sha256, [
         "SINGULARITY-PLAINTEXT-INTEGRITY-V1\0",
         encoded_hashes
       ])}
    else
      _mismatch -> integrity_failure()
    end
  end

  defp validate_plaintext_summary(_summary, _ciphertext, _target), do: unavailable()

  defp encode_plaintext_hashes(hashes, expected_ids)
       when length(hashes) == length(expected_ids) do
    hashes
    |> Enum.zip(expected_ids)
    |> Enum.reduce_while({:ok, []}, fn
      {%{asset_object_id: id, sha256: <<_::binary-size(32)>> = hash}, id}, {:ok, encoded} ->
        case Ecto.UUID.dump(id) do
          {:ok, <<_::binary-size(16)>> = uuid} -> {:cont, {:ok, [[uuid, hash] | encoded]}}
          _invalid -> {:halt, integrity_failure()}
        end

      _mismatch, _encoded ->
        {:halt, integrity_failure()}
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      {:error, %Error{}} = error -> error
    end
  end

  defp encode_plaintext_hashes(_hashes, _expected_ids), do: integrity_failure()

  defp rebuild_lexical(adapter, target) do
    with {:ok, result} <- adapter_value(call(adapter, :rebuild, [search_binding(target)])),
         %SearchSummary{
           projection: "postgres_metadata_v1",
           document_count: document_count,
           result_sha256: <<_::binary-size(32)>>
         } = summary <- result,
         true <- is_integer(document_count) and document_count >= 0 do
      {:ok, summary}
    else
      {:error, %Error{}} = error -> error
      _malformed -> unavailable()
    end
  end

  defp completion_command(target, ciphertext, plaintext_sha256, lexical) do
    %{
      ciphertext_inventory_sha256: ciphertext.inventory_sha256,
      correlation_id: restore_identity(target, "integrity.audit_completed:correlation"),
      integrity_principal_id: target.integrity_principal_id,
      manifest_id: target.manifest_id,
      object_count: ciphertext.object_count,
      operation: "integrity.audit_completed",
      plaintext_inventory_sha256: plaintext_sha256,
      search_rebuild_sha256: lexical.result_sha256,
      vault_id: target.vault_id
    }
  end

  defp restore_identity(target, label) do
    digest =
      :crypto.hash(:sha256, [
        "singularity:restore:audit:v1\0",
        label,
        0,
        Ecto.UUID.dump!(target.manifest_id),
        Ecto.UUID.dump!(target.vault_id)
      ])

    <<prefix::binary-size(6), version_byte, middle_byte, variant_byte, suffix::binary-size(7),
      _rest::binary>> = digest

    version_byte = Bitwise.bor(Bitwise.band(version_byte, 0x0F), 0x50)
    variant_byte = Bitwise.bor(Bitwise.band(variant_byte, 0x3F), 0x80)

    Ecto.UUID.load!(<<prefix::binary, version_byte, middle_byte, variant_byte, suffix::binary>>)
  end

  defp search_binding(target),
    do: %{manifest_id: target.manifest_id, vault_id: target.vault_id}

  defp restore_target(%{
         cut: %{vault_id: vault_id, object_inventory: cut_inventory},
         integrity_principal_id: integrity_principal_id,
         manifest: %{manifest_id: manifest_id},
         object_inventory: inventory
       })
       when is_list(inventory) and cut_inventory == inventory do
    with {:ok, ^manifest_id} <- canonical_uuid(manifest_id),
         {:ok, ^vault_id} <- canonical_uuid(vault_id),
         {:ok, ^integrity_principal_id} <- canonical_uuid(integrity_principal_id),
         {:ok, _inventory_sha256} <- StorageIntegrityAudit.inventory_sha256(vault_id, inventory) do
      {:ok,
       %{
         integrity_principal_id: integrity_principal_id,
         inventory: inventory,
         manifest_id: manifest_id,
         vault_id: vault_id
       }}
    else
      {:error, %Error{} = error} -> error
      _invalid -> backup_invalid()
    end
  end

  defp restore_target(_rewrapped), do: backup_invalid()

  defp integrity_capability(%{integrity_capability: %Capability{} = capability}),
    do: {:ok, capability}

  defp integrity_capability(_rewrapped), do: backup_invalid()

  defp adapters(context, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, configured} ->
      case configured_adapter(context, key) do
        {:ok, value} -> {:cont, {:ok, Map.put(configured, key, value)}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp configured_adapter(context, :object_storage) do
    case Map.fetch(context, :object_storage) do
      {:ok, value} when value not in [nil, false] -> {:ok, value}
      _missing -> invalid()
    end
  end

  defp configured_adapter(context, :ciphertext_auditor),
    do: adapter(context, :ciphertext_auditor, :verify_ciphertext, 3)

  defp configured_adapter(context, :restore_integrity_lease),
    do: integrity_lease_adapter(context)

  defp configured_adapter(context, :search_rebuilder),
    do: adapter(context, :search_rebuilder, :rebuild, 1)

  defp configured_adapter(context, :audit), do: adapter(context, :audit, :complete, 1)

  defp integrity_lease_adapter(context) do
    with {:ok, verify_adapter} <-
           adapter(context, :restore_integrity_lease, :verify_all, 1),
         {:ok, ^verify_adapter} <-
           adapter(context, :restore_integrity_lease, :revoke, 1) do
      {:ok, verify_adapter}
    end
  end

  defp adapter(context, key, function, arity) do
    case Map.fetch(context, key) do
      {:ok, module} when is_atom(module) and not is_nil(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, function, arity),
          do: {:ok, module},
          else: invalid()

      {:ok, {module, adapter_context}} when is_atom(module) and not is_nil(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, function, arity + 1),
          do: {:ok, {module, adapter_context}},
          else: invalid()

      _missing ->
        invalid()
    end
  end

  defp call(module, function, arguments) when is_atom(module) do
    apply(module, function, arguments)
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  defp call({module, adapter_context}, function, arguments) do
    apply(module, function, [adapter_context | arguments])
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  defp adapter_value({:ok, value}) when not is_nil(value), do: {:ok, value}
  defp adapter_value({:error, %Error{} = error}), do: {:error, public_error(error)}
  defp adapter_value(_malformed), do: unavailable()

  defp adapter_ok(:ok), do: :ok
  defp adapter_ok({:error, %Error{} = error}), do: {:error, public_error(error)}
  defp adapter_ok(_malformed), do: unavailable()

  defp revoke_capability(adapter, capability) do
    _result = call(adapter, :revoke, [capability])
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> {:ok, value}
      _invalid -> backup_invalid()
    end
  end

  defp canonical_uuid(_value), do: backup_invalid()

  defp secure_compare(<<_::binary-size(32)>> = left, <<_::binary-size(32)>> = right),
    do: :crypto.hash_equals(left, right)

  defp public_error(%Error{code: code, retryable?: retryable?}),
    do: Error.new(code, retryable?: retryable?)

  defp invalid, do: {:error, Error.new(:invalid)}
  defp backup_invalid, do: {:error, Error.new(:backup_invalid)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
