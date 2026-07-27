defmodule Singularity.Runtime.BackupVault do
  @moduledoc "Coordinates encrypted backup setup, resumption, and export."

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope

  @backup_requirement %{
    classification: :private,
    required_capability: "backup.create",
    requires_unlocked?: true
  }

  @reentry_requirement %{
    classification: :private,
    required_capability: "backup.create",
    requires_unlocked?: false
  }

  @spec request(map(), map(), binary(), term()) :: {:ok, map()} | {:error, Error.t()}
  def request(runtime, session, passphrase, destination_ref)
      when is_map(runtime) and is_map(session) and is_binary(passphrase) and
             byte_size(passphrase) > 0 do
    with {:ok, adapters} <- request_adapters(runtime),
         manifest_id <- call_adapter(adapters.ids, :generate, []),
         true <- is_binary(manifest_id) and manifest_id != "",
         {:ok, prepared} <-
           call_adapter(adapters.backup_key_lease, :prepare, [
             runtime,
             session,
             manifest_id,
             passphrase
           ]),
         {:ok, opaque_ref, public_metadata} <- prepared_values(prepared) do
      try do
        call_adapter(adapters.operation_scope, :with_shared_request, [
          runtime,
          session,
          @backup_requirement,
          fn repo ->
            command =
              request_command(session, manifest_id, destination_ref, public_metadata, opaque_ref)

            with {:ok, manifest} <-
                   call_adapter(adapters.backups, :insert_pending_and_enqueue, [
                     repo,
                     command
                   ]) do
              {:after_commit_scoped,
               fn run_scoped ->
                 activate_and_wake(adapters, run_scoped, manifest, opaque_ref)
               end}
            end
          end
        ])
        |> normalize_result()
      after
        _discarded = call_adapter(adapters.custodian, :discard_pending, [opaque_ref])
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def request(_runtime, _session, _passphrase, _destination_ref), do: invalid()

  @spec reenter(map(), map(), binary(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def reenter(runtime, session, manifest_id, passphrase)
      when is_map(runtime) and is_map(session) and is_binary(manifest_id) and
             manifest_id != "" and is_binary(passphrase) and byte_size(passphrase) > 0 do
    cleanup_key = {__MODULE__, make_ref()}

    with {:ok, adapters} <- request_adapters(runtime) do
      try do
        call_adapter(adapters.operation_scope, :with_shared_request, [
          runtime,
          session,
          @reentry_requirement,
          fn repo ->
            with {:ok, manifest} <-
                   call_adapter(adapters.backups, :load_waiting, [
                     repo,
                     %{manifest_id: manifest_id, vault_id: session.vault_id}
                   ]),
                 {:ok, previous_ref} <-
                   manifest_field(manifest, [:backup_key_lease_id, :custody_ref]),
                 {:ok, persisted} <- persisted_backup(runtime, manifest),
                 {:ok, prepared} <-
                   call_adapter(adapters.backup_key_lease, :reenter, [
                     runtime,
                     persisted,
                     passphrase
                   ]),
                 {:ok, opaque_ref, _public_metadata} <- prepared_values(prepared),
                 :ok <- remember_pending(cleanup_key, adapters.custodian, opaque_ref),
                 {:ok, replacement} <-
                   call_adapter(adapters.backups, :replace_key_and_audit, [
                     repo,
                     reentry_command(session, manifest_id, previous_ref, opaque_ref)
                   ]) do
              {:after_commit_scoped,
               fn run_scoped ->
                 resume_after_commit(
                   adapters,
                   run_scoped,
                   replacement,
                   opaque_ref,
                   previous_ref
                 )
               end}
            end
          end
        ])
        |> normalize_result()
      after
        discard_remembered_pending(cleanup_key)
      end
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def reenter(_runtime, _session, _manifest_id, _passphrase), do: invalid()

  @spec run(map(), JobEnvelope.t()) ::
          {:ok, map()} | {:error, Error.t()} | {:snooze, pos_integer()}
  def run(
        context,
        %JobEnvelope{
          job_type: "backup",
          payload: %{"pending_manifest_id" => manifest_id}
        } = envelope
      )
      when is_map(context) and is_binary(manifest_id) and manifest_id != "" do
    with {:ok, adapters} <- worker_adapters(context),
         {:ok, manifest} <- load_pending(adapters, envelope, manifest_id) do
      case manifest.status do
        :waiting_for_backup_key ->
          snooze_waiting(adapters, envelope, manifest)

        :sealed ->
          sealed_success(adapters, manifest)

        :copying ->
          run_copying(adapters, envelope, manifest)

        _invalid ->
          {:error, Error.new(:conflict)}
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def run(_context, _envelope), do: invalid()

  defp run_copying(adapters, envelope, manifest) do
    case safe_adapter_call(adapters.destination, :probe, [
           manifest.destination_ref,
           manifest.id
         ]) do
      {:ok, :absent} ->
        run_new_export(adapters, envelope, manifest)

      {:ok, :partial} ->
        wait_for_backup_key(adapters, envelope, manifest)

      {:ok, {:final, source}} when is_map(source) ->
        run_published_final_recovery(adapters, envelope, manifest, source)

      {:error, %Error{}} = error ->
        compensate_copy_failure(adapters, envelope, manifest, error)

      _invalid ->
        compensate_copy_failure(adapters, envelope, manifest, storage_unavailable())
    end
  end

  defp run_new_export(adapters, envelope, manifest) do
    case safe_adapter_call(adapters.custodian, :backup_crypto, [
           manifest.id,
           manifest.backup_key_lease_id
         ]) do
      {:ok, crypto} ->
        case safe_export(adapters, envelope, manifest, crypto) do
          {:ok, _sealed} = success ->
            success

          {:error, %Error{}} = error ->
            compensate_copy_failure(adapters, envelope, manifest, error)

          _invalid ->
            compensate_copy_failure(adapters, envelope, manifest, storage_unavailable())
        end

      {:error, :lease_missing} ->
        wait_for_backup_key(adapters, envelope, manifest)

      {:error, %Error{}} = error ->
        compensate_copy_failure(adapters, envelope, manifest, error)

      _invalid ->
        compensate_copy_failure(adapters, envelope, manifest, storage_unavailable())
    end
  end

  defp run_published_final_recovery(adapters, envelope, manifest, source) do
    case safe_adapter_call(adapters.custodian, :backup_crypto, [
           manifest.id,
           manifest.backup_key_lease_id
         ]) do
      {:ok, crypto} ->
        case safe_recover_published_final(adapters, envelope, manifest, source, crypto) do
          {:ok, _sealed} = success ->
            success

          {:error, %Error{}} = error ->
            compensate_copy_failure(adapters, envelope, manifest, error)

          _invalid ->
            compensate_copy_failure(adapters, envelope, manifest, storage_unavailable())
        end

      {:error, :lease_missing} ->
        wait_for_backup_key(adapters, envelope, manifest)

      {:error, %Error{}} = error ->
        compensate_copy_failure(adapters, envelope, manifest, error)

      _invalid ->
        compensate_copy_failure(adapters, envelope, manifest, storage_unavailable())
    end
  end

  defp activate_and_wake(adapters, run_scoped, manifest, opaque_ref) do
    case call_adapter(adapters.custodian, :activate_backup_key, [opaque_ref]) do
      :ok ->
        after_activation(adapters, run_scoped, manifest, opaque_ref, fn pending ->
          call_adapter(adapters.jobs, :wake_backup, [pending.id])
        end)

      {:error, _reason} ->
        {:ok, manifest}

      _invalid ->
        {:ok, manifest}
    end
  end

  defp resume_after_commit(adapters, run_scoped, manifest, opaque_ref, previous_ref) do
    with :ok <- revoke_previous_custody(adapters, previous_ref, opaque_ref) do
      case call_adapter(adapters.custodian, :activate_backup_key, [opaque_ref]) do
        :ok ->
          after_activation(adapters, run_scoped, manifest, opaque_ref, fn pending ->
            with :ok <-
                   call_adapter(adapters.partial_bundles, :cleanup, [
                     pending.destination_ref,
                     pending.id
                   ]),
                 :ok <- call_adapter(adapters.jobs, :wake_backup, [pending.id]) do
              :ok
            end
          end)

        {:error, _reason} ->
          {:ok, manifest}

        _invalid ->
          {:ok, manifest}
      end
    else
      _failure -> storage_unavailable()
    end
  end

  defp after_activation(adapters, run_scoped, manifest, opaque_ref, operation) do
    result =
      run_scoped.(fn repo ->
        call_adapter(adapters.backups, :mark_pending, [
          repo,
          cas_command(manifest, opaque_ref)
        ])
      end)

    case result do
      {:ok, pending} ->
        case operation.(pending) do
          :ok ->
            {:ok, pending}

          {:ok, _value} ->
            {:ok, pending}

          {:error, %Error{}} = error ->
            compensate_activation(adapters, run_scoped, manifest, opaque_ref, error)

          _invalid ->
            compensate_activation(
              adapters,
              run_scoped,
              manifest,
              opaque_ref,
              storage_unavailable()
            )
        end

      {:error, %Error{}} = error ->
        compensate_activation(adapters, run_scoped, manifest, opaque_ref, error)

      _invalid ->
        compensate_activation(adapters, run_scoped, manifest, opaque_ref, storage_unavailable())
    end
  rescue
    _exception ->
      compensate_activation(adapters, run_scoped, manifest, opaque_ref, storage_unavailable())
  catch
    _kind, _reason ->
      compensate_activation(adapters, run_scoped, manifest, opaque_ref, storage_unavailable())
  end

  defp compensate_activation(adapters, run_scoped, manifest, opaque_ref, public_error) do
    marker = make_ref()

    compensation =
      safe_scoped_call(run_scoped, fn repo ->
        case safe_adapter_call(adapters.backups, :mark_waiting_for_backup_key, [
               repo,
               cas_command(manifest, opaque_ref)
             ]) do
          {:ok, _waiting} -> {:commit, {:ok, marker}}
          :ok -> {:commit, {:ok, marker}}
          {:error, %Error{}} = error -> error
          _invalid -> storage_unavailable()
        end
      end)

    _revoked = safe_adapter_call(adapters.custodian, :revoke_backup_key, [opaque_ref])

    case compensation do
      {:ok, ^marker} -> normalize_public_error(public_error)
      _failure -> storage_unavailable()
    end
  end

  defp load_pending(adapters, envelope, manifest_id) do
    adapters.transact.([], fn repo ->
      with :ok <- authorize_job(adapters, repo, envelope) do
        call_adapter(adapters.backups, :load_pending, [
          repo,
          %{manifest_id: manifest_id, vault_id: envelope.vault_id}
        ])
      end
    end)
  end

  defp recover_published_final(adapters, envelope, pending, source, crypto) do
    with {:ok, adapter, capability} <- crypto_values(crypto),
         {:ok, verified} <-
           call_adapter(adapters.bundle_reader, :authenticate_all, [
             source,
             [crypto: {adapter, capability}]
           ]),
         {:ok, cut} <-
           call_adapter(adapters.bundle_verifier, :verify, [
             verified,
             verification_binding(pending)
           ]),
         {:ok, sealed} <- authenticated_seal(pending, source, verified) do
      adapters.transact.([], fn repo ->
        with :ok <- authorize_job(adapters, repo, envelope) do
          call_adapter(adapters.backups, :acknowledge_sealed, [
            repo,
            seal_command(pending, cut, sealed)
          ])
        end
      end)
      |> normalize_result()
      |> revoke_sealed_custody(adapters, pending.backup_key_lease_id)
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:backup_invalid)}
    end
  end

  defp safe_recover_published_final(adapters, envelope, pending, source, crypto) do
    recover_published_final(adapters, envelope, pending, source, crypto)
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp export(adapters, envelope, pending, crypto) do
    adapters.transact.([isolation: :repeatable_read], fn repo ->
      with :ok <- authorize_job(adapters, repo, envelope),
           {:ok, destination} <-
             call_adapter(adapters.destination, :writer_destination, [
               pending.destination_ref
             ]),
           {:ok, cut} <-
             call_adapter(adapters.exporter, :snapshot_cut, [repo, envelope.vault_id]),
           logical_cut = Map.put(cut, :manifest_id, pending.id),
           {:ok, logical_export} <-
             call_adapter(adapters.exporter, :records, [repo, logical_cut]),
           {:ok, object_export} <-
             call_adapter(adapters.object_storage, :stream_inventory, [cut]),
           {:ok, records, logical_inventory} <- record_batch(logical_export),
           {:ok, inventory_records, object_inventory} <- record_batch(object_export),
           {:ok, manifest_inventory} <-
             authoritative_inventory(logical_inventory, object_inventory),
           manifest <- manifest(cut, pending, manifest_inventory),
           {:ok, sealed} <-
             call_adapter(adapters.bundle_writer, :stream, [
               destination,
               records,
               inventory_records,
               manifest,
               crypto
             ]) do
        call_adapter(adapters.backups, :acknowledge_sealed, [
          repo,
          seal_command(pending, cut, sealed)
        ])
      end
    end)
    |> normalize_result()
    |> revoke_sealed_custody(adapters, pending.backup_key_lease_id)
  end

  defp safe_export(adapters, envelope, pending, crypto) do
    export(adapters, envelope, pending, crypto)
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp crypto_values(%{adapter: adapter, capability: capability})
       when is_atom(adapter) and not is_nil(adapter) and capability not in [nil, false],
       do: {:ok, adapter, capability}

  defp crypto_values(_crypto), do: {:error, Error.new(:backup_invalid)}

  defp verification_binding(pending) do
    %{
      destination_ref: pending.destination_ref,
      manifest_id: pending.id,
      recovery: pending.recovery,
      vault_id: pending.vault_id
    }
  end

  defp authenticated_seal(
         pending,
         %{path: path},
         %{
           manifest: %{inventory: inventory},
           manifest_hash: <<_::binary-size(32)>> = manifest_hash,
           manifest_tag: <<_::binary-size(16)>> = manifest_tag
         }
       )
       when is_binary(path) and path != "" and is_list(inventory) do
    {:ok,
     %{
       destination_ref: pending.destination_ref,
       inventory: inventory,
       manifest_hash: manifest_hash,
       manifest_id: pending.id,
       manifest_tag: manifest_tag,
       path: path
     }}
  end

  defp authenticated_seal(_pending, _source, _verified),
    do: {:error, Error.new(:backup_invalid)}

  defp wait_for_backup_key(adapters, envelope, manifest) do
    transition = safe_transition_to_waiting(adapters, envelope, manifest)
    revoked = revoke_custody(adapters, manifest.backup_key_lease_id)

    case {transition, revoked} do
      {:ok, :ok} -> {:snooze, 60}
      {{:error, %Error{}} = error, :ok} -> normalize_public_error(error)
      _failure -> storage_unavailable()
    end
  end

  defp compensate_copy_failure(adapters, envelope, manifest, public_error) do
    transition = safe_transition_to_waiting(adapters, envelope, manifest)
    revoked = revoke_custody(adapters, manifest.backup_key_lease_id)

    case {transition, revoked, public_error} do
      {:ok, :ok, {:error, %Error{}} = error} -> normalize_public_error(error)
      _failure -> storage_unavailable()
    end
  end

  defp transition_to_waiting(adapters, envelope, manifest) do
    case adapters.transact.([], fn repo ->
           with :ok <- authorize_job(adapters, repo, envelope),
                {:ok, _waiting} <-
                  call_adapter(adapters.backups, :mark_waiting_for_backup_key, [
                    repo,
                    cas_command(manifest, manifest.backup_key_lease_id)
                  ]),
                :ok <- call_adapter(adapters.job_progress, :wait_for_backup_key, [repo, envelope]) do
             :ok
           end
         end) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, %Error{}} = error -> error
      _invalid -> storage_unavailable()
    end
  end

  defp safe_transition_to_waiting(adapters, envelope, manifest) do
    transition_to_waiting(adapters, envelope, manifest)
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp snooze_waiting(adapters, envelope, manifest) do
    transition = safe_transition_to_waiting(adapters, envelope, manifest)
    revoked = revoke_custody(adapters, manifest.backup_key_lease_id)

    case {transition, revoked} do
      {:ok, :ok} -> {:snooze, 60}
      _failure -> storage_unavailable()
    end
  end

  defp sealed_success(adapters, manifest) do
    case revoke_custody(adapters, manifest.backup_key_lease_id) do
      :ok -> {:ok, manifest}
      _failure -> storage_unavailable()
    end
  end

  defp revoke_custody(adapters, opaque_ref) do
    case safe_adapter_call(adapters.custodian, :revoke_backup_key, [opaque_ref]) do
      :ok -> :ok
      _failure -> storage_unavailable()
    end
  end

  defp manifest(cut, pending, inventory) do
    %{
      version: 1,
      manifest_id: pending.id,
      vault_ids: [pending.vault_id],
      snapshot_id: cut.snapshot_id,
      outbox_high_water_mark: cut.outbox_high_water_mark,
      recovery: pending.recovery,
      inventory: inventory
    }
  end

  defp request_command(session, manifest_id, destination_ref, public_metadata, opaque_ref) do
    %{
      audit_event_id: Ecto.UUID.generate(),
      causation_id: manifest_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      custody_ref: opaque_ref,
      destination_ref: destination_ref,
      manifest_id: manifest_id,
      occurred_at: DateTime.utc_now(:microsecond),
      outbox_event_id: Ecto.UUID.generate(),
      principal_authorization_epoch: session.principal_authorization_epoch,
      principal_id: session.principal_id,
      public_metadata: public_metadata,
      vault_authorization_epoch: session.vault_authorization_epoch,
      vault_id: session.vault_id
    }
  end

  defp reentry_command(session, manifest_id, previous_ref, replacement_ref) do
    %{
      audit_event_id: Ecto.UUID.generate(),
      correlation_id: Ecto.UUID.generate(),
      expected_custody_ref: previous_ref,
      manifest_id: manifest_id,
      occurred_at: DateTime.utc_now(:microsecond),
      principal_id: session.principal_id,
      replacement_custody_ref: replacement_ref,
      vault_id: session.vault_id
    }
  end

  defp cas_command(manifest, opaque_ref) do
    %{
      custody_ref: opaque_ref,
      manifest_id: manifest.id,
      vault_id: manifest.vault_id
    }
  end

  defp seal_command(pending, cut, sealed) do
    %{
      cut:
        Map.take(cut, [
          :object_inventory,
          :outbox_high_water_mark,
          :snapshot_id,
          :vault_id
        ]),
      expected_custody_ref: pending.backup_key_lease_id,
      manifest_id: pending.id,
      sealed: sealed,
      vault_id: pending.vault_id
    }
  end

  defp revoke_sealed_custody({:ok, sealed}, adapters, opaque_ref) do
    case safe_adapter_call(adapters.custodian, :revoke_backup_key, [opaque_ref]) do
      :ok -> {:ok, sealed}
      _failure -> storage_unavailable()
    end
  end

  defp revoke_sealed_custody(result, _adapters, _opaque_ref), do: result

  defp revoke_previous_custody(_adapters, previous_ref, previous_ref), do: :ok

  defp revoke_previous_custody(adapters, previous_ref, _replacement_ref) do
    case safe_adapter_call(adapters.custodian, :revoke_backup_key, [previous_ref]) do
      :ok -> :ok
      _failure -> storage_unavailable()
    end
  end

  defp normalize_public_error({:error, %Error{code: code, retryable?: retryable?}})
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

  defp normalize_public_error(_invalid), do: storage_unavailable()

  defp safe_scoped_call(run_scoped, callback) do
    run_scoped.(callback)
  rescue
    _exception -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  defp record_batch(%{records: records, inventory: inventory}) when is_list(inventory) do
    if Enumerable.impl_for(records) do
      {:ok, records, inventory}
    else
      invalid()
    end
  end

  defp record_batch(_batch), do: invalid()

  defp authoritative_inventory(logical, objects) do
    inventory = logical ++ objects

    inventory
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {descriptor, position}, {:ok, entries} ->
      case descriptor do
        %{
          record_type: record_type,
          payload_length: payload_length,
          sha256: <<_::binary-size(32)>> = sha256
        }
        when map_size(descriptor) == 3 and is_integer(record_type) and record_type >= 0 and
               record_type <= 0xFFFE and is_integer(payload_length) and payload_length >= 0 ->
          {:cont,
           {:ok,
            [
              %{
                position: position,
                record_type: record_type,
                payload_length: payload_length,
                sha256: sha256
              }
              | entries
            ]}}

        _invalid ->
          {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, %Error{}} = error -> error
    end
  end

  defp persisted_backup(runtime, manifest) do
    with {:ok, manifest_id} <- manifest_field(manifest, [:id, :manifest_id]),
         {:ok, vault_id} <- manifest_field(manifest, [:vault_id]),
         {:ok, opaque_ref} <-
           manifest_field(manifest, [:backup_key_lease_id, :custody_ref]),
         {:ok, public_metadata} <-
           persisted_public_metadata(runtime, manifest, manifest_id, vault_id),
         recovery = Map.fetch!(public_metadata, "recovery") do
      {:ok,
       %{
         "backup_key_lease_id" => opaque_ref,
         "manifest" => %{
           "manifest_id" => manifest_id,
           "recovery" => recovery,
           "vault_ids" => [vault_id]
         },
         "public_metadata" => public_metadata,
         "vault_id" => vault_id
       }}
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:backup_invalid)}
    end
  end

  defp persisted_public_metadata(_runtime, %{kdf: kdf, recovery: recovery}, _id, _vault_id)
       when is_map(kdf) and is_map(recovery),
       do: {:ok, %{"kdf" => kdf, "recovery" => recovery}}

  defp persisted_public_metadata(
         runtime,
         %{
           kdf_parameters: parameters,
           kdf_salt: salt,
           recovery_wrapper: recovery_wrapper
         },
         manifest_id,
         vault_id
       )
       when is_map(parameters) and is_binary(salt) and byte_size(salt) == 16 and
              is_binary(recovery_wrapper) and recovery_wrapper != "" do
    case Map.get(runtime, :backup_kdf_domain) do
      domain when is_binary(domain) and domain != "" ->
        {:ok,
         %{
           "kdf" => %{
             "domain" => domain,
             "parameters" => parameters,
             "salt" => Base.encode64(salt)
           },
           "recovery" => %{
             "binding" => %{
               "manifest_id" => manifest_id,
               "vault_id" => vault_id
             },
             "label" => "backup_recovery",
             "wrapper" => recovery_wrapper
           }
         }}

      _invalid ->
        {:error, Error.new(:backup_invalid)}
    end
  end

  defp persisted_public_metadata(_runtime, _manifest, _manifest_id, _vault_id),
    do: {:error, Error.new(:backup_invalid)}

  defp manifest_field(manifest, keys) when is_map(manifest) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(manifest, key) do
        {:ok, value} -> value
        :error -> Map.get(manifest, Atom.to_string(key))
      end
    end)
    |> case do
      value when is_binary(value) and value != "" -> {:ok, value}
      _invalid -> {:error, Error.new(:backup_invalid)}
    end
  end

  defp authorize_job(adapters, repo, envelope) do
    call_adapter(adapters.authorize, :check_job, [
      adapters.authorization,
      repo,
      envelope
    ])
  end

  defp request_adapters(runtime) do
    required = [
      :backup_key_lease,
      :backups,
      :custodian,
      :ids,
      :jobs,
      :operation_scope,
      :partial_bundles
    ]

    if Enum.all?(required, &concrete?(Map.get(runtime, &1))) do
      {:ok, Map.take(runtime, required)}
    else
      invalid()
    end
  end

  defp worker_adapters(context) do
    required = [
      :authorization,
      :authorize,
      :backups,
      :bundle_reader,
      :bundle_verifier,
      :bundle_writer,
      :custodian,
      :destination,
      :exporter,
      :job_progress,
      :object_storage
    ]

    transact = Map.get(context, :transact)

    if Enum.all?(required, &concrete?(Map.get(context, &1))) and
         is_function(transact, 2) do
      {:ok,
       context
       |> Map.take(required)
       |> Map.put(:transact, transact)}
    else
      invalid()
    end
  end

  defp prepared_values(%{opaque_ref: opaque_ref, public_metadata: public_metadata})
       when not is_nil(opaque_ref) and is_map(public_metadata),
       do: {:ok, opaque_ref, public_metadata}

  defp prepared_values(_prepared), do: invalid()

  defp remember_pending(key, custodian, opaque_ref) do
    Process.put(key, {custodian, opaque_ref})
    :ok
  end

  defp discard_remembered_pending(key) do
    case Process.delete(key) do
      {custodian, opaque_ref} ->
        _discarded = call_adapter(custodian, :discard_pending, [opaque_ref])
        :ok

      nil ->
        :ok
    end
  end

  defp normalize_result({:ok, _value} = result), do: result
  defp normalize_result({:error, %Error{}} = error), do: error
  defp normalize_result({:snooze, seconds} = result) when is_integer(seconds), do: result
  defp normalize_result(_invalid), do: storage_unavailable()

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, adapter_context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [adapter_context | arguments])

  defp safe_adapter_call(adapter, function, arguments) do
    call_adapter(adapter, function, arguments)
  rescue
    _exception -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp concrete?(value), do: value not in [nil, false]
  defp invalid, do: {:error, Error.new(:invalid)}
  defp storage_unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
