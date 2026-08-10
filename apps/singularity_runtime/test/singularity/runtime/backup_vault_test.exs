defmodule Singularity.Runtime.BackupVaultTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope

  @backup_vault Singularity.Runtime.BackupVault
  @backup_task Mix.Tasks.Singularity.Backup
  @restore_task Mix.Tasks.Singularity.Restore
  @manifest_id "00000000-0000-4000-8000-000000000711"
  @vault_id "00000000-0000-4000-8000-000000000712"
  @passphrase "CANARY_BACKUP_PASSPHRASE_711"
  @wrong_passphrase "CANARY_WRONG_BACKUP_PASSPHRASE_711"
  @derived_key :binary.copy(<<0xD1>>, 32)
  @salt :binary.copy(<<0x71>>, 16)
  @encoded_salt Base.encode64(@salt)
  @kdf %{
    "domain" => "singularity.backup.bundle.v1",
    "parameters" => %{
      "m_cost" => 65_536,
      "parallelism" => 2,
      "t_cost" => 5,
      "version" => 4
    },
    "salt" => @encoded_salt
  }

  defmodule State do
    use Agent

    def start_link(options) do
      Agent.start_link(fn ->
        %{
          active: MapSet.new(),
          derived_key_canary: :binary.copy(<<0xD1>>, 32),
          destination_state: :absent,
          events: [],
          failure: Keyword.get(options, :failure),
          manifests: %{},
          next_ref: 0,
          outbox: [],
          partials: MapSet.new(),
          pending: MapSet.new(),
          scoped_transactions: 0,
          worker_transactions: 0,
          wakes: []
        }
      end)
    end

    def get(state), do: Agent.get(state, & &1)
    def failure(state), do: Agent.get(state, & &1.failure)
    def derived_key(state), do: Agent.get(state, & &1.derived_key_canary)
    def destination_state(state), do: Agent.get(state, & &1.destination_state)

    def set_destination_state(state, destination_state),
      do: Agent.update(state, &%{&1 | destination_state: destination_state})

    def set_failure(state, failure), do: Agent.update(state, &%{&1 | failure: failure})

    def durable(state) do
      Agent.get(state, &Map.take(&1, [:active, :manifests, :outbox, :partials, :pending, :wakes]))
    end

    def record(state, event),
      do: Agent.update(state, &update_in(&1.events, fn events -> events ++ [event] end))

    def pending(state) do
      Agent.get_and_update(state, fn data ->
        sequence = data.next_ref + 1
        opaque_ref = "backup-key-ref-#{sequence}"

        {opaque_ref,
         %{
           data
           | next_ref: sequence,
             pending: MapSet.put(data.pending, opaque_ref)
         }}
      end)
    end

    def discard(state, opaque_ref),
      do: Agent.update(state, &%{&1 | pending: MapSet.delete(&1.pending, opaque_ref)})

    def activate(state, opaque_ref) do
      Agent.update(state, fn data ->
        %{
          data
          | active: MapSet.put(data.active, opaque_ref),
            pending: MapSet.delete(data.pending, opaque_ref)
        }
      end)
    end

    def revoke(state, opaque_ref) do
      Agent.update(state, fn data ->
        %{
          data
          | active: MapSet.delete(data.active, opaque_ref),
            pending: MapSet.delete(data.pending, opaque_ref)
        }
      end)
    end

    def insert(state, manifest, outbox_args) do
      Agent.update(state, fn data ->
        %{
          data
          | manifests: Map.put(data.manifests, manifest.id, manifest),
            outbox: [outbox_args]
        }
      end)
    end

    def put_manifest(state, manifest),
      do: Agent.update(state, &%{&1 | manifests: Map.put(&1.manifests, manifest.id, manifest)})

    def seed_manifest(state, manifest) do
      Agent.update(state, fn data ->
        %{
          data
          | manifests: %{manifest.id => manifest},
            outbox: [%{"pending_manifest_id" => manifest.id}],
            partials: MapSet.put(data.partials, manifest.id)
        }
      end)
    end

    def rollback(state, snapshot) do
      Agent.update(state, fn data ->
        %{data | manifests: snapshot.manifests, outbox: snapshot.outbox}
      end)
    end

    def next_scoped_transaction(state) do
      Agent.get_and_update(state, fn data ->
        count = data.scoped_transactions + 1
        {count, %{data | scoped_transactions: count}}
      end)
    end

    def next_worker_transaction(state) do
      Agent.get_and_update(state, fn data ->
        count = data.worker_transactions + 1
        {count, %{data | worker_transactions: count}}
      end)
    end

    def remove_partial(state, manifest_id),
      do: Agent.update(state, &%{&1 | partials: MapSet.delete(&1.partials, manifest_id)})

    def wake(state, manifest_id),
      do: Agent.update(state, &%{&1 | wakes: &1.wakes ++ [manifest_id]})
  end

  defmodule Ids do
    def generate(_state), do: "00000000-0000-4000-8000-000000000711"
  end

  defmodule BackupKeys do
    alias Singularity.Runtime.BackupVaultTest.Custodian

    @correct_passphrase "CANARY_BACKUP_PASSPHRASE_711"
    @domain "singularity.backup.bundle.v1"

    def prepare(state, runtime, session, manifest_id, passphrase)
        when is_map(runtime) and is_map(session) do
      true = runtime.backup_key_lease == {__MODULE__, state}
      true = runtime.custodian == {Custodian, state}
      kdf = kdf_metadata()
      State.record(state, {:derive_new_backup_key, manifest_id, kdf})
      derived_key = derive(state, passphrase, kdf)
      binding = %{"manifest_id" => manifest_id, "vault_id" => session.vault_id}
      State.record(state, {:wrap_recovery, manifest_id, :backup_recovery, binding})
      prepared(state, manifest_id, session.vault_id, derived_key, binding, kdf)
    end

    def reenter(
          state,
          runtime,
          %{
            "backup_key_lease_id" => previous_ref,
            "manifest" => manifest,
            "public_metadata" => public_metadata,
            "vault_id" => vault_id
          } = persisted,
          passphrase
        )
        when is_map(runtime) and is_binary(previous_ref) and is_map(manifest) and
               is_map(public_metadata) and is_binary(vault_id) do
      true = runtime.backup_key_lease == {__MODULE__, state}

      true =
        Map.keys(persisted) |> Enum.sort() ==
          ~w[backup_key_lease_id manifest public_metadata vault_id]

      manifest_id = manifest["manifest_id"]
      kdf = public_metadata["kdf"]
      recovery = public_metadata["recovery"]

      State.record(state, {:reenter, manifest_id})
      State.record(state, {:derive_reentered_backup_key, manifest_id, kdf})
      derived_key = derive(state, passphrase, kdf)
      binding = recovery["binding"]
      State.record(state, {:verify_recovery_wrapper, manifest_id, binding})

      expected_binding = %{
        "manifest_id" => manifest_id,
        "vault_id" => vault_id
      }

      with true <- binding == expected_binding,
           [^vault_id] <- manifest["vault_ids"],
           ^recovery <- manifest["recovery"],
           "backup_recovery" <- recovery["label"],
           expected <- recovery_wrapper(derived_key, binding),
           true <- recovery["wrapper"] == expected do
        opaque_ref = State.pending(state)
        State.record(state, {:prepare_reentered_custody, manifest_id, opaque_ref})

        {:ok,
         %{
           binding: binding,
           opaque_ref: opaque_ref,
           public_metadata: public_metadata
         }}
      else
        _invalid -> {:error, Error.new(:backup_invalid)}
      end
    end

    defp prepared(state, manifest_id, vault_id, derived_key, binding, kdf) do
      opaque_ref = State.pending(state)

      {:ok,
       %{
         binding: %{manifest_id: manifest_id, vault_id: vault_id},
         opaque_ref: opaque_ref,
         public_metadata: %{
           "kdf" => kdf,
           "recovery" => %{
             "binding" => binding,
             "label" => "backup_recovery",
             "wrapper" => recovery_wrapper(derived_key, binding)
           }
         }
       }}
    end

    defp derive(state, passphrase, kdf) do
      if passphrase == @correct_passphrase and kdf == kdf_metadata() do
        State.derived_key(state)
      else
        salt = Base.decode64!(Map.get(kdf, "salt", ""))
        domain = Map.get(kdf, "domain", "")
        parameters = Map.get(kdf, "parameters", %{})

        :crypto.hash(
          :sha256,
          passphrase <> salt <> domain <> :erlang.term_to_binary(parameters)
        )
      end
    rescue
      _invalid_kdf -> :binary.copy(<<0xE1>>, 32)
    end

    defp recovery_wrapper(derived_key, binding) do
      :crypto.mac(
        :hmac,
        :sha256,
        derived_key,
        :erlang.term_to_binary({:backup_recovery, binding})
      )
      |> Base.encode16()
    end

    defp kdf_metadata do
      %{
        "domain" => @domain,
        "parameters" => %{
          "m_cost" => 65_536,
          "parallelism" => 2,
          "t_cost" => 5,
          "version" => 4
        },
        "salt" => Base.encode64(:binary.copy(<<0x71>>, 16))
      }
    end
  end

  defmodule RecordContract do
    def record(type, payload, attrs \\ %{}) when is_binary(payload) do
      Map.merge(attrs, %{
        payload: [payload],
        payload_length: byte_size(payload),
        type: type
      })
    end

    def descriptor(record) do
      payload = IO.iodata_to_binary(record.payload)

      %{
        record_type: record.type,
        payload_length: record.payload_length,
        sha256: :crypto.hash(:sha256, payload)
      }
    end

    def inventory(records) do
      records
      |> Enum.map(&descriptor/1)
      |> Enum.with_index()
      |> Enum.map(fn {descriptor, position} -> Map.put(descriptor, :position, position) end)
    end
  end

  defmodule Scope do
    def with_shared_request(state, _runtime, _session, requirement, callback) do
      State.record(state, {:shared_scope, requirement})

      case State.failure(state) do
        :transaction ->
          {:error, Error.new(:storage_unavailable)}

        failure ->
          snapshot = State.get(state)

          case callback.(:request_repo) do
            {:after_commit_scoped, _callback} when failure == :commit ->
              State.rollback(state, snapshot)
              {:error, Error.new(:storage_unavailable)}

            {:after_commit_scoped, after_commit} ->
              State.record(state, :committed)

              run_scoped = fn scoped_callback ->
                scoped_snapshot = State.get(state)
                scoped_transaction = State.next_scoped_transaction(state)
                State.record(state, {:scoped_transaction, scoped_transaction})

                result = scoped_callback.(:request_repo)

                cond do
                  failure == :second_commit and scoped_transaction == 1 ->
                    State.rollback(state, scoped_snapshot)
                    State.record(state, :second_commit_failed)
                    {:error, Error.new(:storage_unavailable, retryable?: true)}

                  match?({:error, %Error{}}, result) ->
                    State.rollback(state, scoped_snapshot)
                    result

                  match?({:commit, _result}, result) ->
                    {:commit, committed_result} = result
                    State.record(state, {:scoped_committed, scoped_transaction})
                    committed_result

                  true ->
                    State.record(state, {:scoped_committed, scoped_transaction})
                    result
                end
              end

              after_commit.(run_scoped)

            {:after_commit, after_commit} when is_function(after_commit, 0) ->
              State.record(state, :committed)
              after_commit.()

            result ->
              result
          end
      end
    end
  end

  defmodule Backups do
    @request_keys ~w[
      audit_event_id causation_id classification correlation_id custody_ref
      destination_ref manifest_id occurred_at outbox_event_id
      principal_authorization_epoch principal_id public_metadata
      vault_authorization_epoch vault_id
    ]a

    def insert_pending_and_enqueue(state, :request_repo, command) do
      true = Map.keys(command) |> Enum.sort() == Enum.sort(@request_keys)
      true = distinct_uuid_command_ids?(command)
      State.record(state, {:insert_pending, command})

      if State.failure(state) == :audit do
        {:error, Error.new(:storage_unavailable)}
      else
        manifest = %{
          backup_key_lease_id: command.custody_ref,
          classification: command.classification,
          destination_ref: command.destination_ref,
          id: command.manifest_id,
          kdf: Map.fetch!(command.public_metadata, "kdf"),
          recovery: Map.fetch!(command.public_metadata, "recovery"),
          status: :waiting_for_backup_key,
          vault_id: command.vault_id
        }

        outbox_args = %{"pending_manifest_id" => command.manifest_id}
        State.insert(state, manifest, outbox_args)
        {:ok, manifest}
      end
    end

    def load_waiting(
          state,
          :request_repo,
          %{manifest_id: manifest_id, vault_id: vault_id} = command
        )
        when map_size(command) == 2 do
      State.record(state, {:load_waiting, command})

      case State.get(state).manifests do
        %{^manifest_id => %{status: :waiting_for_backup_key, vault_id: ^vault_id} = manifest} ->
          {:ok, manifest}

        _missing ->
          {:error, Error.new(:not_found)}
      end
    end

    def replace_key_and_audit(state, :request_repo, command) do
      State.record(state, {:replace_key_and_audit, command})
      manifest_id = command.manifest_id

      case State.get(state).manifests do
        %{
          ^manifest_id =>
            %{
              backup_key_lease_id: expected_ref,
              status: :waiting_for_backup_key,
              vault_id: vault_id
            } = manifest
        }
        when expected_ref == command.expected_custody_ref and vault_id == command.vault_id ->
          replacement = %{manifest | backup_key_lease_id: command.replacement_custody_ref}
          State.put_manifest(state, replacement)
          {:ok, replacement}

        _stale ->
          {:error, Error.new(:conflict)}
      end
    end

    def mark_pending(
          state,
          :request_repo,
          %{manifest_id: manifest_id, vault_id: vault_id, custody_ref: opaque_ref} = command
        )
        when map_size(command) == 3 do
      State.record(state, {:mark_pending, command})

      case State.failure(state) do
        :mark_pending_error ->
          {:error, Error.new(:storage_unavailable)}

        :mark_pending_raise ->
          raise "simulated mark-pending failure"

        :mark_pending_exit ->
          exit(:simulated_mark_pending_failure)

        _other ->
          case State.get(state).manifests do
            %{
              ^manifest_id =>
                %{
                  backup_key_lease_id: ^opaque_ref,
                  status: :waiting_for_backup_key,
                  vault_id: ^vault_id
                } = manifest
            } ->
              pending = %{manifest | status: :pending}
              State.put_manifest(state, pending)
              {:ok, pending}

            _stale ->
              {:error, Error.new(:conflict)}
          end
      end
    end

    def mark_waiting_for_backup_key(
          state,
          repo,
          %{manifest_id: manifest_id, vault_id: vault_id, custody_ref: opaque_ref} = command
        )
        when repo in [:request_repo, :worker_repo] and map_size(command) == 3 do
      State.record(state, {:restore_waiting, command})

      case State.failure(state) do
        :wait_transition_raise ->
          raise "simulated wait transition failure"

        :wait_transition_throw ->
          throw(:simulated_wait_transition_failure)

        _other ->
          case State.get(state).manifests do
            %{
              ^manifest_id =>
                %{
                  backup_key_lease_id: ^opaque_ref,
                  status: status,
                  vault_id: ^vault_id
                } = manifest
            }
            when status in [:waiting_for_backup_key, :pending, :copying] ->
              waiting = %{manifest | status: :waiting_for_backup_key}
              State.put_manifest(state, waiting)
              {:ok, waiting}

            _stale ->
              {:error, Error.new(:conflict)}
          end
      end
    end

    def load_pending(
          state,
          :worker_repo,
          %{manifest_id: manifest_id, vault_id: vault_id} = command
        )
        when map_size(command) == 2 do
      State.record(state, {:load_pending, command})

      case State.get(state).manifests do
        %{^manifest_id => %{vault_id: ^vault_id, status: :pending} = manifest} ->
          copying = %{manifest | status: :copying}
          State.put_manifest(state, copying)
          State.record(state, {:claimed_copying, manifest_id})
          {:ok, copying}

        %{^manifest_id => %{vault_id: ^vault_id, status: :copying} = manifest} ->
          waiting = %{manifest | status: :waiting_for_backup_key}
          State.put_manifest(state, waiting)
          {:ok, waiting}

        %{
          ^manifest_id => %{vault_id: ^vault_id, status: status} = manifest
        }
        when status in [:waiting_for_backup_key, :sealed] ->
          {:ok, manifest}

        _missing ->
          {:error, Error.new(:not_found)}
      end
    end

    def acknowledge_sealed(state, :worker_repo, command) do
      case State.failure(state) do
        :seal_error ->
          State.record(state, {:acknowledge_sealed_failed, command})
          {:error, Error.new(:storage_unavailable, retryable?: true)}

        :seal_raise ->
          raise "simulated seal failure"

        _other ->
          acknowledge_sealed_success(state, command)
      end
    end

    defp acknowledge_sealed_success(state, command) do
      pending = Map.fetch!(State.get(state).manifests, command.manifest_id)
      true = pending.status == :copying
      true = pending.vault_id == command.vault_id
      true = pending.backup_key_lease_id == command.expected_custody_ref
      true = pending.destination_ref == command.sealed.destination_ref

      manifest =
        Map.merge(pending, %{
          inventory: command.cut.object_inventory,
          manifest_hash: command.sealed.manifest_hash,
          manifest_tag: command.sealed.manifest_tag,
          outbox_high_water_mark: command.cut.outbox_high_water_mark,
          snapshot_id: command.cut.snapshot_id,
          status: :sealed
        })

      State.record(state, {:acknowledge_sealed, command})
      State.put_manifest(state, manifest)
      {:ok, manifest}
    end

    defp distinct_uuid_command_ids?(command) do
      ids = [
        command.audit_event_id,
        command.correlation_id,
        command.manifest_id,
        command.outbox_event_id
      ]

      Enum.all?(ids, &match?({:ok, _uuid}, Ecto.UUID.cast(&1))) and
        Enum.uniq(ids) == ids and command.causation_id == command.manifest_id
    end
  end

  defmodule Custodian do
    def activate_backup_key(state, opaque_ref) do
      State.record(state, {:activate, opaque_ref})

      if State.failure(state) == :activation do
        State.discard(state, opaque_ref)
        {:error, Error.new(:storage_unavailable)}
      else
        State.activate(state, opaque_ref)
        :ok
      end
    end

    def discard_pending(state, opaque_ref) do
      State.record(state, {:discard, opaque_ref})
      State.discard(state, opaque_ref)
      :ok
    end

    def revoke_backup_key(state, opaque_ref) do
      State.record(state, {:revoke, opaque_ref})
      State.revoke(state, opaque_ref)
      :ok
    end

    def backup_crypto(state, manifest_id, opaque_ref) do
      State.record(state, {:backup_crypto, manifest_id, opaque_ref})

      cond do
        State.failure(state) == :backup_crypto_malformed ->
          :malformed

        MapSet.member?(State.get(state).active, opaque_ref) ->
          manifest = Map.fetch!(State.get(state).manifests, manifest_id)

          {:ok,
           %{
             adapter: Singularity.Runtime.BackupKeyLease,
             capability: :opaque_crypto_lease,
             public_header: %{
               version: 1,
               manifest_id: manifest.id,
               kdf: manifest.kdf
             }
           }}

        true ->
          {:error, :lease_missing}
      end
    end
  end

  defmodule Exporter do
    def snapshot_cut(state, :worker_repo, vault_id) do
      State.record(state, {:snapshot_cut, vault_id})

      {:ok,
       %{
         database_snapshot: "100:100:",
         object_inventory: [
           %{
             asset_object_id: "00000000-0000-4000-8000-000000000718",
             ciphertext_byte_size: 30,
             ciphertext_hash: :binary.copy(<<0x72>>, 32),
             classification: :private,
             inventory_position: 0,
             key_domain_id: "00000000-0000-4000-8000-000000000719",
             lookup_digest: :binary.copy(<<0x73>>, 32),
             storage_ref: "objects/object-718",
             vault_id: vault_id
           }
         ],
         outbox_high_water_mark: 41,
         snapshot_id: "00000000-0000-4000-8000-000000000717",
         vault_id: vault_id
       }}
    end

    def records(state, :worker_repo, cut) do
      manifest_id = Map.fetch!(cut, :manifest_id)

      records = [
        RecordContract.record(0x0001, "database-logical-export-v1")
      ]

      State.record(state, {:export_records, cut.snapshot_id, manifest_id})
      {:ok, %{records: records, inventory: Enum.map(records, &RecordContract.descriptor/1)}}
    end
  end

  defmodule ObjectStorage do
    def stream_inventory(state, cut) do
      [object] = cut.object_inventory

      record =
        RecordContract.record(
          0xBEEF,
          :erlang.term_to_binary(object, [:deterministic]),
          object
        )

      State.record(state, {:stream_inventory, cut.snapshot_id})

      {:ok,
       %{
         records: [record],
         inventory: [RecordContract.descriptor(record)]
       }}
    end
  end

  defmodule PartialBundles do
    def cleanup(state, destination_ref, manifest_id) do
      State.record(state, {:cleanup_partial, destination_ref, manifest_id})

      case State.failure(state) do
        :cleanup_error ->
          {:error, Error.new(:storage_unavailable)}

        :cleanup_raise ->
          raise "simulated partial cleanup failure"

        :cleanup_exit ->
          exit(:simulated_partial_cleanup_failure)

        _other ->
          State.remove_partial(state, manifest_id)
          :ok
      end
    end
  end

  defmodule Destination do
    def probe(state, destination_ref, manifest_id) do
      State.record(state, {:destination_probe, destination_ref, manifest_id})

      case State.destination_state(state) do
        :absent ->
          {:ok, :absent}

        :partial ->
          {:ok, :partial}

        :final ->
          {:ok,
           {:final,
            %{
              destination_ref: destination_ref,
              manifest_id: manifest_id,
              path: "/var/lib/singularity/backups/#{destination_ref}"
            }}}
      end
    end

    def writer_destination(state, destination_ref) do
      State.record(state, {:writer_destination, destination_ref})

      {:ok,
       %{
         destination_ref: destination_ref,
         path: "/var/lib/singularity/backups/#{destination_ref}"
       }}
    end
  end

  defmodule Jobs do
    def wake_vault(state, vault_id) do
      State.record(state, {:wake, vault_id})

      case State.failure(state) do
        :wake_error ->
          {:error, Error.new(:storage_unavailable)}

        :wake_raise ->
          raise "simulated wake failure"

        :wake_exit ->
          exit(:simulated_wake_failure)

        _other ->
          State.wake(state, vault_id)
          :ok
      end
    end
  end

  defmodule JobProgress do
    def wait_for_backup_key(state, :worker_repo, envelope) do
      manifest_id = Map.get(envelope.payload, "pending_manifest_id")
      State.record(state, {:wait_for_backup_key, manifest_id})
      :ok
    end
  end

  defmodule Authorize do
    def check_job(state, :worker_repo, envelope) do
      State.record(state, {:authorize_job, envelope.vault_id})
      :ok
    end
  end

  defmodule BundleWriter do
    import ExUnit.Assertions

    def stream(
          state,
          %{destination_ref: destination},
          records,
          inventory,
          manifest,
          crypto
        ) do
      assert manifest.inventory == RecordContract.inventory(records ++ inventory)

      State.record(
        state,
        {:bundle_stream, destination, records, inventory, manifest, crypto}
      )

      if State.failure(state) == :writer_error do
        {:error, Error.new(:backup_invalid)}
      else
        State.record(state, {:bundle_published, destination})
        State.set_destination_state(state, :final)

        {:ok,
         %{
           destination_ref: destination,
           inventory: manifest.inventory,
           manifest_hash: :binary.copy(<<0x77>>, 32),
           manifest_id: manifest.manifest_id,
           manifest_tag: :binary.copy(<<0x78>>, 16),
           path: "/var/lib/singularity/backups/#{destination}"
         }}
      end
    end
  end

  defmodule BundleReader do
    def authenticate_all(state, source, options) do
      State.record(state, {:bundle_authenticate, source, options})

      case State.failure(state) do
        :reader_error ->
          {:error, Error.new(:backup_invalid)}

        :reader_raise ->
          raise "simulated reader failure"

        :reader_secret_error ->
          {:error,
           Error.new(:backup_invalid,
             message: "CANARY_READER_AUTHENTICATED_PLAINTEXT_711",
             details: %{authenticated_plaintext: "CANARY_READER_AUTHENTICATED_PLAINTEXT_711"}
           )}

        _other ->
          manifest = Map.fetch!(State.get(state).manifests, source.manifest_id)

          {:ok,
           %{
             manifest: %{
               inventory: [%{payload_length: 12, record_type: 0x0001, sha256: <<0::256>>}],
               manifest_id: manifest.id,
               outbox_high_water_mark: 41,
               recovery: manifest.recovery,
               snapshot_id: "00000000-0000-4000-8000-000000000717",
               vault_ids: [manifest.vault_id],
               version: 1
             },
             manifest_hash: :binary.copy(<<0x79>>, 32),
             manifest_tag: :binary.copy(<<0x7A>>, 16),
             records: []
           }}
      end
    end
  end

  defmodule BundleVerifier do
    def verify(state, verified, binding) do
      State.record(state, {:bundle_verify, verified, binding})

      case State.failure(state) do
        :verifier_error ->
          {:error, Error.new(:backup_invalid)}

        :verifier_throw ->
          throw(:simulated_verifier_failure)

        _other ->
          {:ok,
           %{
             database_snapshot: "100:100:",
             manifest_id: binding.manifest_id,
             object_inventory: [
               %{
                 asset_object_id: "00000000-0000-4000-8000-000000000718",
                 ciphertext_byte_size: 30,
                 ciphertext_hash: :binary.copy(<<0x72>>, 32),
                 classification: :private,
                 inventory_position: 0,
                 key_domain_id: "00000000-0000-4000-8000-000000000719",
                 lookup_digest: :binary.copy(<<0x73>>, 32),
                 storage_ref: "objects/object-718",
                 vault_id: binding.vault_id
               }
             ],
             outbox_high_water_mark: verified.manifest.outbox_high_water_mark,
             snapshot_id: verified.manifest.snapshot_id,
             vault_id: binding.vault_id
           }}
      end
    end
  end

  defmodule SingleUseExporter do
    def snapshot_cut(state, repo, vault_id), do: Exporter.snapshot_cut(state, repo, vault_id)

    def records(state, :worker_repo, cut) do
      manifest_id = Map.fetch!(cut, :manifest_id)
      record = RecordContract.record(0x0001, "single-use-logical-export")

      records =
        Stream.map([record], fn entry ->
          State.record(state, :logical_stream_consumed)
          entry
        end)

      State.record(state, {:export_records, cut.snapshot_id, manifest_id})
      {:ok, %{records: records, inventory: [RecordContract.descriptor(record)]}}
    end
  end

  defmodule SingleUseObjectStorage do
    def stream_inventory(state, cut) do
      record = RecordContract.record(0xBEEF, "single-use-object-ciphertext")

      records =
        Stream.map([record], fn entry ->
          State.record(state, :object_stream_consumed)
          entry
        end)

      State.record(state, {:stream_inventory, cut.snapshot_id})
      {:ok, %{records: records, inventory: [RecordContract.descriptor(record)]}}
    end
  end

  defmodule ConsumingBundleWriter do
    def stream(state, destination, records, objects, manifest, crypto) do
      State.record(state, :writer_entered)

      BundleWriter.stream(
        state,
        destination,
        Enum.to_list(records),
        Enum.to_list(objects),
        manifest,
        crypto
      )
    end
  end

  defmodule TaskOperationRecorder do
    use Agent

    def start_link(_options) do
      Agent.start_link(fn -> %{backup_calls: [], restore_calls: []} end)
    end

    def record_backup(recorder, destination_ref, passphrase) do
      Agent.update(recorder, fn state ->
        call = %{
          destination_ref: destination_ref,
          passphrase_hash: :crypto.hash(:sha256, passphrase)
        }

        update_in(state.backup_calls, &(&1 ++ [call]))
      end)
    end

    def record_restore(recorder, source, passphrase, new_password) do
      Agent.update(recorder, fn state ->
        call = %{
          new_password_hash: :crypto.hash(:sha256, new_password),
          passphrase_hash: :crypto.hash(:sha256, passphrase),
          source: source
        }

        update_in(state.restore_calls, &(&1 ++ [call]))
      end)
    end

    def get(recorder), do: Agent.get(recorder, & &1)
  end

  defmodule BackupTaskOperation do
    def request(recorder, _runtime, _session, passphrase, destination_ref) do
      TaskOperationRecorder.record_backup(recorder, destination_ref, passphrase)
      {:ok, %{id: "task-backup-manifest", status: :pending}}
    end
  end

  defmodule FunctionClauseBackupTaskOperation do
    def request(_runtime, _session, "only-this-impossible-passphrase", _destination_ref),
      do: {:ok, %{id: "unreachable"}}
  end

  defmodule RaisingBackupTaskOperation do
    def request(_runtime, _session, passphrase, _destination_ref) do
      raise ArgumentError, "adapter must not leak #{passphrase}"
    end
  end

  defmodule MalformedBackupTaskOperation do
    def request(_runtime, _session, _passphrase, _destination_ref), do: :malformed
  end

  defmodule ThrowingBackupTaskOperation do
    def request(_runtime, _session, passphrase, _destination_ref),
      do: throw({:adapter_throw, passphrase})
  end

  defmodule ExitingBackupTaskOperation do
    def request(_runtime, _session, passphrase, _destination_ref),
      do: exit({:adapter_exit, passphrase})
  end

  defmodule RestoreTaskOperation do
    def run(recorder, _context, request) do
      TaskOperationRecorder.record_restore(
        recorder,
        request.source,
        request.passphrase,
        request.new_password
      )

      {:ok, %{manifest_id: "task-restore-manifest"}}
    end
  end

  defmodule NoEchoIO do
    use GenServer

    def start_link(secrets) do
      GenServer.start_link(__MODULE__, secrets)
    end

    def output(device), do: GenServer.call(device, :output)
    def reads(device), do: GenServer.call(device, :reads)

    @impl GenServer
    def init(secrets) do
      {:ok, %{output: [], reads: [], secrets: secrets}}
    end

    @impl GenServer
    def handle_call(:output, _from, state) do
      {:reply, state.output |> Enum.reverse() |> IO.iodata_to_binary(), state}
    end

    def handle_call(:reads, _from, state) do
      {:reply, Enum.reverse(state.reads), state}
    end

    @impl GenServer
    def handle_info({:io_request, from, reply_as, request}, state) do
      {reply, state} = io_request(request, state)
      send(from, {:io_reply, reply_as, reply})
      {:noreply, state}
    end

    defp io_request({:requests, requests}, state) do
      Enum.reduce(requests, {:ok, state}, fn request, {_reply, state} ->
        io_request(request, state)
      end)
    end

    defp io_request({:put_chars, _encoding, characters}, state) do
      {:ok, put_output(state, characters)}
    end

    defp io_request({:put_chars, characters}, state) do
      {:ok, put_output(state, characters)}
    end

    defp io_request({:put_chars, _encoding, module, function, arguments}, state) do
      {:ok, put_output(state, apply(module, function, arguments))}
    end

    defp io_request({:put_chars, module, function, arguments}, state) do
      {:ok, put_output(state, apply(module, function, arguments))}
    end

    defp io_request({:get_password, _encoding}, state) do
      password_reply(state, :get_password, false)
    end

    defp io_request({:get_line, _encoding, _prompt}, state) do
      password_reply(state, :get_line, true)
    end

    defp io_request({:get_chars, _encoding, _prompt, _count}, state) do
      password_reply(state, :get_chars, false)
    end

    defp io_request({:setopts, _options}, state), do: {:ok, state}
    defp io_request(:getopts, state), do: {{:ok, []}, state}
    defp io_request({:get_geometry, _geometry}, state), do: {{:error, :enotsup}, state}
    defp io_request(_request, state), do: {{:error, :request}, state}

    defp password_reply(%{secrets: [secret | rest]} = state, kind, newline?) do
      reply = if newline?, do: secret <> "\n", else: secret
      {String.to_charlist(reply), %{state | reads: [kind | state.reads], secrets: rest}}
    end

    defp password_reply(state, kind, _newline?) do
      {{:error, :enotsup}, %{state | reads: [kind | state.reads]}}
    end

    defp put_output(state, characters) do
      %{state | output: [IO.chardata_to_string(characters) | state.output]}
    end
  end

  setup do
    state = start_supervised!({State, []})
    {:ok, runtime: runtime(state), session: session(), state: state}
  end

  test "success CASes the durable manifest to pending before waking the worker", context do
    assert {:ok, %{id: @manifest_id, status: :pending}} = request(context)
    snapshot = State.get(context.state)
    manifest_id = @manifest_id

    assert %{^manifest_id => manifest} = snapshot.manifests
    assert snapshot.outbox == [%{"pending_manifest_id" => @manifest_id}]
    assert is_binary(manifest.backup_key_lease_id)
    assert manifest.status == :pending
    assert manifest.kdf == @kdf
    assert json_safe_map?(manifest.kdf)
    assert json_safe_map?(manifest.recovery)
    assert manifest.recovery["label"] == "backup_recovery"
    assert MapSet.size(snapshot.active) == 1
    assert snapshot.pending == MapSet.new()
    assert snapshot.wakes == [@vault_id]

    assert [{:insert_pending, command}] =
             Enum.filter(snapshot.events, &match?({:insert_pending, _command}, &1))

    assert command == %{
             audit_event_id: command.audit_event_id,
             causation_id: @manifest_id,
             classification: :private,
             correlation_id: command.correlation_id,
             custody_ref: manifest.backup_key_lease_id,
             destination_ref: "backup://vault-7",
             manifest_id: @manifest_id,
             occurred_at: command.occurred_at,
             outbox_event_id: command.outbox_event_id,
             principal_authorization_epoch: 7,
             principal_id: "principal-7",
             public_metadata: %{"kdf" => manifest.kdf, "recovery" => manifest.recovery},
             vault_authorization_epoch: 11,
             vault_id: @vault_id
           }

    assert event_index!(snapshot.events, :committed) < event_index!(snapshot.events, :activate)
    assert event_index!(snapshot.events, :activate) < event_index!(snapshot.events, :mark_pending)
    assert event_index!(snapshot.events, :mark_pending) < event_index!(snapshot.events, :wake)
  end

  test "a fresh request does not require the resume-only partial bundle adapter", context do
    runtime = Map.delete(context.runtime, :partial_bundles)

    assert {:ok, %{id: @manifest_id, status: :pending}} =
             api(:request, [runtime, context.session, @passphrase, "backup://vault-7"])

    assert State.get(context.state).wakes == [@vault_id]
  end

  test "reentry still requires the partial bundle adapter", context do
    State.seed_manifest(context.state, waiting_manifest())
    runtime = Map.delete(context.runtime, :partial_bundles)

    assert {:error, %Error{code: :invalid}} =
             api(:reenter, [runtime, context.session, @manifest_id, @passphrase])

    snapshot = State.get(context.state)
    assert snapshot.pending == MapSet.new()
    assert snapshot.active == MapSet.new()
    assert snapshot.wakes == []
  end

  test "transaction, audit, and commit failures leave no manifest, outbox, or custody" do
    for failure <- [:transaction, :audit, :commit] do
      state = start_supervised!({State, failure: failure}, id: make_ref())
      result_ref = make_ref()

      log =
        capture_log(fn ->
          send(
            self(),
            {result_ref,
             api(:request, [runtime(state), session(), @passphrase, "backup://vault-7"])}
          )
        end)

      assert_receive {^result_ref, {:error, %Error{code: :storage_unavailable} = error}}

      snapshot = State.get(state)
      assert snapshot.manifests == %{}
      assert snapshot.outbox == []
      assert snapshot.pending == MapSet.new()
      assert snapshot.active == MapSet.new()
      assert snapshot.wakes == []
      assert Enum.any?(snapshot.events, &match?({:discard, _opaque_ref}, &1))
      refute Enum.any?(snapshot.events, &match?({:activate, _opaque_ref}, &1))

      refute secret_leaked?(
               [error, log, State.durable(state), snapshot.events],
               [@passphrase, @derived_key]
             )
    end
  end

  test "post-commit activation failure leaves only one waiting manifest", _context do
    state = start_supervised!({State, failure: :activation}, id: make_ref())
    result_ref = make_ref()

    log =
      capture_log(fn ->
        send(
          self(),
          {result_ref,
           api(:request, [runtime(state), session(), @passphrase, "backup://vault-7"])}
        )
      end)

    assert_receive {^result_ref,
                    {:ok, %{id: @manifest_id, status: :waiting_for_backup_key} = result}}

    snapshot = State.get(state)
    manifest_id = @manifest_id
    assert %{^manifest_id => %{status: :waiting_for_backup_key}} = snapshot.manifests
    assert snapshot.outbox == [%{"pending_manifest_id" => @manifest_id}]
    assert snapshot.pending == MapSet.new()
    assert snapshot.active == MapSet.new()
    assert snapshot.wakes == []
    refute Enum.any?(snapshot.events, &match?({:mark_pending, _}, &1))

    refute secret_leaked?(
             [result, log, State.durable(state), snapshot.events],
             [@passphrase, @derived_key]
           )
  end

  test "request compensation restores waiting state and revokes activated custody" do
    for failure <- [:mark_pending_error, :wake_exit] do
      state = start_supervised!({State, failure: failure}, id: {failure, make_ref()})

      assert {:error, %Error{code: :storage_unavailable}} =
               api(:request, [runtime(state), session(), @passphrase, "backup://vault-7"])

      snapshot = State.get(state)
      assert snapshot.manifests[@manifest_id].status == :waiting_for_backup_key
      assert snapshot.active == MapSet.new()
      assert snapshot.pending == MapSet.new()
      assert snapshot.wakes == []
      assert Enum.any?(snapshot.events, &match?({:restore_waiting, _}, &1))
      assert Enum.any?(snapshot.events, &match?({:revoke, _}, &1))
    end
  end

  test "a second scoped-transaction commit failure is observed after activation and compensated" do
    state = start_supervised!({State, failure: :second_commit}, id: make_ref())

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             api(:request, [runtime(state), session(), @passphrase, "backup://vault-7"])

    snapshot = State.get(state)
    manifest = snapshot.manifests[@manifest_id]

    assert manifest.status == :waiting_for_backup_key
    assert snapshot.active == MapSet.new()
    assert snapshot.pending == MapSet.new()
    assert snapshot.wakes == []

    assert event_index!(snapshot.events, :activate) <
             event_index!(snapshot.events, :second_commit_failed)

    assert event_index!(snapshot.events, :second_commit_failed) <
             event_index!(snapshot.events, :restore_waiting)

    assert event_index!(snapshot.events, :restore_waiting) <
             event_index!(snapshot.events, :revoke)

    assert Enum.count(snapshot.events, &match?({:scoped_transaction, _}, &1)) == 2

    assert [{:activate, activated_ref}] =
             Enum.filter(snapshot.events, &match?({:activate, _opaque_ref}, &1))

    assert [{:restore_waiting, %{custody_ref: ^activated_ref}}] =
             Enum.filter(snapshot.events, &match?({:restore_waiting, _command}, &1))
  end

  test "a restarted worker with a lost lease waits without writing a bundle", context do
    State.seed_manifest(context.state, %{waiting_manifest() | status: :pending})
    before = State.get(context.state)

    envelope = backup_envelope()

    assert {:snooze, 60} = api(:run, [worker_context(context.state), envelope])

    after_wait = State.get(context.state)
    assert after_wait.manifests[@manifest_id].status == :waiting_for_backup_key
    assert after_wait.outbox == before.outbox
    assert after_wait.partials == before.partials
    assert after_wait.active == MapSet.new()
    assert after_wait.wakes == []
    assert Enum.any?(after_wait.events, &match?({:wait_for_backup_key, @manifest_id}, &1))
    refute Enum.any?(after_wait.events, &match?({:bundle_stream, _, _, _, _, _}, &1))

    second_transaction =
      after_wait.events
      |> Enum.with_index()
      |> Enum.filter(fn {event, _index} -> match?({:worker_transaction_begin, 2, []}, event) end)
      |> then(fn [{_event, index}] -> index end)

    second_commit =
      after_wait.events
      |> Enum.with_index()
      |> Enum.find_value(fn
        {{:worker_transaction_commit, 2}, index} -> index
        _other -> nil
      end)

    assert second_transaction < event_index!(after_wait.events, :restore_waiting)

    assert event_index!(after_wait.events, :restore_waiting) <
             event_index!(after_wait.events, :wait_for_backup_key)

    assert event_index!(after_wait.events, :wait_for_backup_key) < second_commit
  end

  test "waiting and sealed worker states never acquire custody or touch the filesystem" do
    for status <- [:waiting_for_backup_key, :sealed] do
      state = start_supervised!({State, []}, id: {status, make_ref()})
      manifest = %{waiting_manifest() | status: status}
      State.seed_manifest(state, manifest)
      State.activate(state, manifest.backup_key_lease_id)

      expected = if status == :sealed, do: {:ok, :sealed}, else: {:snooze, 60}
      result = api(:run, [worker_context(state), backup_envelope()])

      case expected do
        {:ok, :sealed} -> assert {:ok, %{status: :sealed}} = result
        {:snooze, 60} -> assert {:snooze, 60} = result
      end

      events = State.get(state).events
      assert State.get(state).active == MapSet.new()
      assert {:revoke, manifest.backup_key_lease_id} in events
      refute Enum.any?(events, &match?({:backup_crypto, _, _}, &1))
      refute Enum.any?(events, &match?({:bundle_stream, _, _, _, _, _}, &1))
      refute Enum.any?(events, &match?({:snapshot_cut, _}, &1))
    end
  end

  test "copying crash recovery returns to waiting without acquiring custody", context do
    copying = %{waiting_manifest() | status: :copying}
    State.seed_manifest(context.state, copying)
    State.activate(context.state, copying.backup_key_lease_id)

    assert {:snooze, 60} =
             api(:run, [worker_context(context.state), backup_envelope()])

    snapshot = State.get(context.state)
    assert snapshot.manifests[@manifest_id].status == :waiting_for_backup_key
    assert snapshot.active == MapSet.new()
    assert {:revoke, copying.backup_key_lease_id} in snapshot.events
    assert {:wait_for_backup_key, @manifest_id} in snapshot.events
    refute Enum.any?(snapshot.events, &match?({:backup_crypto, _, _}, &1))
    refute Enum.any?(snapshot.events, &match?({:bundle_stream, _, _, _, _, _}, &1))
  end

  test "writer and seal failures compensate copying, revoke custody, and preserve bundle files" do
    for {failure, expected_code, published?} <- [
          {:writer_error, :backup_invalid, false},
          {:seal_error, :storage_unavailable, true}
        ] do
      state = start_supervised!({State, failure: failure}, id: {failure, make_ref()})
      pending = %{waiting_manifest() | status: :pending}
      State.seed_manifest(state, pending)
      State.activate(state, pending.backup_key_lease_id)
      files_before = State.get(state).partials

      assert {:error, %Error{code: ^expected_code}} =
               api(:run, [worker_context(state), backup_envelope()])

      snapshot = State.get(state)
      assert snapshot.manifests[@manifest_id].status == :waiting_for_backup_key
      assert snapshot.active == MapSet.new()
      assert snapshot.partials == files_before
      assert {:revoke, pending.backup_key_lease_id} in snapshot.events

      assert Enum.any?(snapshot.events, fn
               {:restore_waiting, %{custody_ref: ref, manifest_id: @manifest_id}} ->
                 ref == pending.backup_key_lease_id

               _other ->
                 false
             end)

      assert Enum.any?(snapshot.events, &match?({:wait_for_backup_key, @manifest_id}, &1))
      refute Enum.any?(snapshot.events, &match?({:cleanup_partial, _, _}, &1))

      assert Enum.any?(snapshot.events, &match?({:bundle_published, _}, &1)) == published?
    end
  end

  test "a live worker composes the storage writer contract without exposing its key", context do
    pending = %{waiting_manifest() | status: :pending}
    State.seed_manifest(context.state, pending)
    State.activate(context.state, pending.backup_key_lease_id)

    assert {:ok, %{id: @manifest_id, status: :sealed} = sealed} =
             api(:run, [worker_context(context.state), backup_envelope()])

    snapshot = State.get(context.state)

    assert [
             {:bundle_stream, destination, records, inventory, manifest, crypto}
           ] =
             Enum.filter(
               snapshot.events,
               &match?({:bundle_stream, _, _, _, _, _}, &1)
             )

    assert destination == pending.destination_ref
    assert sealed.status == :sealed
    refute MapSet.member?(snapshot.active, pending.backup_key_lease_id)

    assert event_index!(snapshot.events, :claimed_copying) <
             event_index!(snapshot.events, :backup_crypto)

    assert {:export_records, "00000000-0000-4000-8000-000000000717", @manifest_id} in snapshot.events

    assert records == [
             %{
               payload: ["database-logical-export-v1"],
               payload_length: 26,
               type: 0x0001
             }
           ]

    assert manifest.inventory == RecordContract.inventory(records ++ inventory)
    refute manifest.inventory == []

    assert [{:acknowledge_sealed, seal_command}] =
             Enum.filter(snapshot.events, &match?({:acknowledge_sealed, _command}, &1))

    assert seal_command.sealed.inventory == manifest.inventory
    assert sealed.inventory == seal_command.cut.object_inventory
    refute sealed.inventory == seal_command.sealed.inventory

    assert Map.take(manifest, [
             :version,
             :manifest_id,
             :vault_ids,
             :snapshot_id,
             :outbox_high_water_mark,
             :recovery
           ]) == %{
             version: 1,
             manifest_id: @manifest_id,
             vault_ids: [@vault_id],
             snapshot_id: "00000000-0000-4000-8000-000000000717",
             outbox_high_water_mark: 41,
             recovery: pending.recovery
           }

    assert crypto == %{
             adapter: Singularity.Runtime.BackupKeyLease,
             capability: :opaque_crypto_lease,
             public_header: %{
               version: 1,
               manifest_id: @manifest_id,
               kdf: @kdf
             }
           }

    refute secret_leaked?(
             [sealed, snapshot.events],
             [@passphrase, @derived_key]
           )
  end

  test "a published final is authenticated and CAS-sealed after operator re-entry without rewriting" do
    state = start_supervised!({State, failure: :seal_error}, id: make_ref())
    pending = %{waiting_manifest() | status: :pending}
    State.seed_manifest(state, pending)
    State.activate(state, pending.backup_key_lease_id)

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             api(:run, [worker_context(state), backup_envelope()])

    assert State.destination_state(state) == :final
    assert State.get(state).manifests[@manifest_id].status == :waiting_for_backup_key

    State.set_failure(state, nil)

    assert {:ok, %{status: :pending}} =
             api(:reenter, [runtime(state), session(), @manifest_id, @passphrase])

    assert {:ok, %{id: @manifest_id, status: :sealed}} =
             api(:run, [worker_context(state), backup_envelope()])

    snapshot = State.get(state)
    assert snapshot.destination_state == :final
    assert Enum.count(snapshot.events, &match?({:bundle_stream, _, _, _, _, _}, &1)) == 1
    assert Enum.count(snapshot.events, &match?({:bundle_published, _}, &1)) == 1
    assert Enum.count(snapshot.events, &match?({:bundle_authenticate, _, _}, &1)) == 1
    assert Enum.count(snapshot.events, &match?({:bundle_verify, _, _}, &1)) == 1
    assert Enum.count(snapshot.events, &match?({:snapshot_cut, _}, &1)) == 1
    assert Enum.count(snapshot.events, &match?({:export_records, _, _}, &1)) == 1
  end

  test "an owned partial waits without acquiring or consuming backup crypto", context do
    pending = %{waiting_manifest() | status: :pending}
    State.seed_manifest(context.state, pending)
    State.activate(context.state, pending.backup_key_lease_id)
    State.set_destination_state(context.state, :partial)

    assert {:snooze, 60} = api(:run, [worker_context(context.state), backup_envelope()])

    snapshot = State.get(context.state)
    assert snapshot.destination_state == :partial
    assert snapshot.manifests[@manifest_id].status == :waiting_for_backup_key
    assert snapshot.active == MapSet.new()
    refute Enum.any?(snapshot.events, &match?({:backup_crypto, _, _}, &1))
    refute Enum.any?(snapshot.events, &match?({:snapshot_cut, _}, &1))
    refute Enum.any?(snapshot.events, &match?({:bundle_stream, _, _, _, _, _}, &1))
    refute Enum.any?(snapshot.events, &match?({:bundle_authenticate, _, _}, &1))
  end

  test "an invalid published final is preserved and returns to waiting", context do
    pending = %{waiting_manifest() | status: :pending}
    State.seed_manifest(context.state, pending)
    State.activate(context.state, pending.backup_key_lease_id)
    State.set_destination_state(context.state, :final)
    State.set_failure(context.state, :reader_error)

    assert {:error, %Error{code: :backup_invalid}} =
             api(:run, [worker_context(context.state), backup_envelope()])

    snapshot = State.get(context.state)
    assert snapshot.destination_state == :final
    assert snapshot.manifests[@manifest_id].status == :waiting_for_backup_key
    assert snapshot.active == MapSet.new()
    assert Enum.any?(snapshot.events, &match?({:bundle_authenticate, _, _}, &1))
    refute Enum.any?(snapshot.events, &match?({:bundle_verify, _, _}, &1))
    refute Enum.any?(snapshot.events, &match?({:snapshot_cut, _}, &1))
    refute Enum.any?(snapshot.events, &match?({:bundle_stream, _, _, _, _, _}, &1))
  end

  test "a recovery CAS failure preserves the authenticated final for another re-entry" do
    state = start_supervised!({State, failure: :seal_error}, id: make_ref())
    pending = %{waiting_manifest() | status: :pending}
    State.seed_manifest(state, pending)
    State.activate(state, pending.backup_key_lease_id)
    State.set_destination_state(state, :final)

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             api(:run, [worker_context(state), backup_envelope()])

    snapshot = State.get(state)
    assert snapshot.destination_state == :final
    assert snapshot.manifests[@manifest_id].status == :waiting_for_backup_key
    assert snapshot.active == MapSet.new()
    assert Enum.any?(snapshot.events, &match?({:bundle_authenticate, _, _}, &1))
    assert Enum.any?(snapshot.events, &match?({:bundle_verify, _, _}, &1))
    assert Enum.any?(snapshot.events, &match?({:acknowledge_sealed_failed, _}, &1))
    refute Enum.any?(snapshot.events, &match?({:snapshot_cut, _}, &1))
    refute Enum.any?(snapshot.events, &match?({:bundle_stream, _, _, _, _, _}, &1))
  end

  test "published-final adapter failures synchronously compensate and revoke custody" do
    for failure <- [
          :reader_raise,
          :verifier_throw,
          :seal_raise,
          :second_worker_transaction_raise
        ] do
      state = start_supervised!({State, failure: failure}, id: {failure, make_ref()})
      pending = %{waiting_manifest() | status: :pending}
      State.seed_manifest(state, pending)
      State.activate(state, pending.backup_key_lease_id)
      State.set_destination_state(state, :final)

      assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
               api(:run, [worker_context(state), backup_envelope()])

      snapshot = State.get(state)
      assert snapshot.destination_state == :final
      assert snapshot.manifests[@manifest_id].status == :waiting_for_backup_key
      assert snapshot.active == MapSet.new()
      assert {:revoke, pending.backup_key_lease_id} in snapshot.events
      refute Enum.any?(snapshot.events, &match?({:snapshot_cut, _}, &1))
      refute Enum.any?(snapshot.events, &match?({:bundle_stream, _, _, _, _, _}, &1))
    end
  end

  test "malformed backup-crypto replies compensate both new and published-final paths" do
    for destination_state <- [:absent, :final] do
      state =
        start_supervised!(
          {State, failure: :backup_crypto_malformed},
          id: {destination_state, make_ref()}
        )

      pending = %{waiting_manifest() | status: :pending}
      State.seed_manifest(state, pending)
      State.activate(state, pending.backup_key_lease_id)
      State.set_destination_state(state, destination_state)

      assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
               api(:run, [worker_context(state), backup_envelope()])

      snapshot = State.get(state)
      assert snapshot.destination_state == destination_state
      assert snapshot.manifests[@manifest_id].status == :waiting_for_backup_key
      assert snapshot.active == MapSet.new()
      assert {:revoke, pending.backup_key_lease_id} in snapshot.events
      refute Enum.any?(snapshot.events, &match?({:snapshot_cut, _}, &1))
      refute Enum.any?(snapshot.events, &match?({:bundle_authenticate, _, _}, &1))
      refute Enum.any?(snapshot.events, &match?({:bundle_stream, _, _, _, _, _}, &1))
    end
  end

  test "transition failures cannot bypass synchronous custody revocation" do
    for failure <- [:wait_transition_raise, :wait_transition_throw] do
      state = start_supervised!({State, failure: failure}, id: {failure, make_ref()})
      pending = %{waiting_manifest() | status: :pending}
      State.seed_manifest(state, pending)
      State.activate(state, pending.backup_key_lease_id)
      State.set_destination_state(state, :partial)

      assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
               api(:run, [worker_context(state), backup_envelope()])

      snapshot = State.get(state)
      assert snapshot.destination_state == :partial
      assert snapshot.manifests[@manifest_id].status == :copying
      assert snapshot.active == MapSet.new()
      assert {:revoke, pending.backup_key_lease_id} in snapshot.events
      refute Enum.any?(snapshot.events, &match?({:backup_crypto, _, _}, &1))
    end
  end

  test "published-final adapter errors are reduced to public code and retryability only" do
    secret = "CANARY_READER_AUTHENTICATED_PLAINTEXT_711"
    state = start_supervised!({State, failure: :reader_secret_error}, id: make_ref())
    pending = %{waiting_manifest() | status: :pending}
    State.seed_manifest(state, pending)
    State.activate(state, pending.backup_key_lease_id)
    State.set_destination_state(state, :final)
    result_ref = make_ref()

    log =
      capture_log(fn ->
        send(self(), {result_ref, api(:run, [worker_context(state), backup_envelope()])})
      end)

    assert_receive {^result_ref,
                    {:error,
                     %Error{
                       code: :backup_invalid,
                       details: %{},
                       message: nil,
                       retryable?: false
                     } = error}}

    snapshot = State.get(state)
    assert snapshot.manifests[@manifest_id].status == :waiting_for_backup_key
    assert snapshot.active == MapSet.new()
    refute secret_leaked?([error, log, snapshot.events], [secret])
  end

  test "authoritative inventories do not consume single-use streams before the writer", context do
    pending = %{waiting_manifest() | status: :pending}
    State.seed_manifest(context.state, pending)
    State.activate(context.state, pending.backup_key_lease_id)

    worker_context =
      context.state
      |> worker_context()
      |> Map.merge(%{
        bundle_writer: {ConsumingBundleWriter, context.state},
        exporter: {SingleUseExporter, context.state},
        object_storage: {SingleUseObjectStorage, context.state}
      })

    assert {:ok, %{status: :sealed}} = api(:run, [worker_context, backup_envelope()])

    events = State.get(context.state).events
    writer_index = event_index!(events, :writer_entered)
    assert writer_index < event_index!(events, :logical_stream_consumed)
    assert writer_index < event_index!(events, :object_stream_consumed)
  end

  test "wrong passphrase or tampered recovery wrapper and binding are mutation-free" do
    cases = [
      {:wrong_passphrase, & &1, @wrong_passphrase},
      {:tampered_wrapper, &put_in(&1, [:recovery, "wrapper"], "tampered"), @passphrase},
      {:tampered_binding, &put_in(&1, [:recovery, "binding", "vault_id"], "other-vault"),
       @passphrase},
      {:tampered_kdf, &put_in(&1, [:kdf, "parameters", "m_cost"], 8), @passphrase}
    ]

    for {name, tamper, passphrase} <- cases do
      state = start_supervised!({State, []}, id: {name, make_ref()})
      State.seed_manifest(state, tamper.(waiting_manifest()))
      durable_before = State.durable(state)
      result_ref = make_ref()

      log =
        capture_log(fn ->
          send(
            self(),
            {result_ref, api(:reenter, [runtime(state), session(), @manifest_id, passphrase])}
          )
        end)

      assert_receive {^result_ref, {:error, %Error{code: :backup_invalid} = error}}

      assert State.durable(state) == durable_before
      events = State.get(state).events

      assert event_index!(events, :derive_reentered_backup_key) <
               event_index!(events, :verify_recovery_wrapper)

      refute Enum.any?(events, &match?({:prepare_reentered_custody, _, _}, &1))
      refute Enum.any?(events, &match?({:replace_key_and_audit, _}, &1))
      refute Enum.any?(events, &match?({:activate, _}, &1))
      refute Enum.any?(events, &match?({:wake, _}, &1))

      refute secret_leaked?(
               [error, log, State.durable(state), events],
               [@passphrase, @wrong_passphrase, @derived_key]
             )
    end
  end

  test "correct re-entry replaces custody on the same manifest, cleans partial data, and wakes",
       context do
    State.seed_manifest(context.state, waiting_manifest())
    result_ref = make_ref()

    log =
      capture_log(fn ->
        send(
          self(),
          {result_ref,
           api(:reenter, [context.runtime, context.session, @manifest_id, @passphrase])}
        )
      end)

    assert_receive {^result_ref, {:ok, %{id: @manifest_id, status: :pending} = result}}

    resumed = State.get(context.state)
    assert Map.keys(resumed.manifests) == [@manifest_id]
    assert resumed.manifests[@manifest_id].status == :pending
    assert is_binary(resumed.manifests[@manifest_id].backup_key_lease_id)
    assert resumed.partials == MapSet.new()
    assert MapSet.size(resumed.active) == 1
    assert resumed.wakes == [@vault_id]
    assert resumed.outbox == [%{"pending_manifest_id" => @manifest_id}]

    assert Enum.any?(resumed.events, fn
             {:revoke, "lost-after-restart-ref"} -> true
             _other -> false
           end)

    assert event_index!(resumed.events, :derive_reentered_backup_key) <
             event_index!(resumed.events, :verify_recovery_wrapper)

    assert event_index!(resumed.events, :verify_recovery_wrapper) <
             event_index!(resumed.events, :prepare_reentered_custody)

    assert event_index!(resumed.events, :committed) < event_index!(resumed.events, :activate)
    assert event_index!(resumed.events, :activate) < event_index!(resumed.events, :mark_pending)

    assert event_index!(resumed.events, :mark_pending) <
             event_index!(resumed.events, :cleanup_partial)

    assert event_index!(resumed.events, :cleanup_partial) < event_index!(resumed.events, :wake)

    refute secret_leaked?(
             [result, log, State.durable(context.state), resumed.events],
             [@passphrase, @derived_key]
           )
  end

  test "post-activation failures restore waiting state and synchronously revoke custody" do
    for failure <- [
          :mark_pending_error,
          :mark_pending_raise,
          :mark_pending_exit,
          :cleanup_error,
          :cleanup_raise,
          :cleanup_exit,
          :wake_error,
          :wake_raise,
          :wake_exit
        ] do
      state = start_supervised!({State, failure: failure}, id: {failure, make_ref()})
      State.seed_manifest(state, waiting_manifest())

      assert {:error, %Error{code: :storage_unavailable}} =
               api(:reenter, [runtime(state), session(), @manifest_id, @passphrase])

      snapshot = State.get(state)
      assert snapshot.manifests[@manifest_id].status == :waiting_for_backup_key
      assert snapshot.outbox == [%{"pending_manifest_id" => @manifest_id}]
      assert snapshot.active == MapSet.new()
      assert snapshot.pending == MapSet.new()
      assert snapshot.wakes == []
      assert Enum.any?(snapshot.events, &match?({:restore_waiting, _}, &1))
      assert Enum.any?(snapshot.events, &match?({:revoke, _}, &1))

      refute secret_leaked?(
               [State.durable(state), snapshot.events],
               [@passphrase, @derived_key]
             )
    end
  end

  test "commands, persistence, logs, errors, and public results contain no secret form",
       context do
    log = capture_log(fn -> send(self(), {:request_result, request(context)}) end)
    assert_receive {:request_result, {:ok, result}}
    snapshot = State.get(context.state)

    assert secret_leaked?(snapshot.derived_key_canary, [@derived_key])

    public_state = Map.drop(snapshot, [:derived_key_canary])

    for value <- [result, public_state, snapshot.manifests, snapshot.outbox, snapshot.events, log] do
      refute secret_leaked?(value, [@passphrase, @wrong_passphrase, @derived_key])
    end

    state = start_supervised!({State, []}, id: make_ref())
    State.seed_manifest(state, waiting_manifest())

    assert {:error, error} =
             api(:reenter, [runtime(state), session(), @manifest_id, @wrong_passphrase])

    refute secret_leaked?(error, [@passphrase, @wrong_passphrase, @derived_key])
  end

  test "task run/1 uses real no-echo prompts before invoking injected operations" do
    recorder = start_supervised!({TaskOperationRecorder, []})
    backup_passphrase = "CANARY_PROMPT_BACKUP_PASSPHRASE_711"
    restore_passphrase = "CANARY_PROMPT_RESTORE_PASSPHRASE_711"
    new_password = "CANARY_PROMPT_RESTORE_PASSWORD_711"

    with_task_operations(recorder, fn _backup_root ->
      {backup_result, backup_stdout, backup_stderr, backup_reads} =
        capture_task_run(
          @backup_task,
          ["--destination", "prompt-vault-7.bundle"],
          [backup_passphrase]
        )

      {restore_result, restore_stdout, restore_stderr, restore_reads} =
        capture_task_run(
          @restore_task,
          ["prompt-bundle-1.bundle"],
          [restore_passphrase, new_password]
        )

      assert backup_result == %{id: "task-backup-manifest", status: :pending}
      assert restore_result == %{manifest_id: "task-restore-manifest"}

      assert backup_reads == [:get_password]
      assert restore_reads == [:get_password, :get_password]

      backup_output = String.downcase(backup_stdout <> backup_stderr)
      restore_output = String.downcase(restore_stdout <> restore_stderr)
      assert String.contains?(backup_output, "passphrase")
      assert String.contains?(restore_output, "passphrase")
      assert String.contains?(restore_output, "password")

      assert TaskOperationRecorder.get(recorder) == %{
               backup_calls: [
                 %{
                   destination_ref: "prompt-vault-7.bundle",
                   passphrase_hash: secret_hash(backup_passphrase)
                 }
               ],
               restore_calls: [
                 %{
                   new_password_hash: secret_hash(new_password),
                   passphrase_hash: secret_hash(restore_passphrase),
                   source: "prompt-bundle-1.bundle"
                 }
               ]
             }

      refute secret_leaked?(
               [
                 backup_result,
                 backup_stdout,
                 backup_stderr,
                 restore_result,
                 restore_stdout,
                 restore_stderr,
                 TaskOperationRecorder.get(recorder)
               ],
               [backup_passphrase, restore_passphrase, new_password]
             )
    end)
  end

  test "task run/1 normalizes operator paths to persisted local references" do
    recorder = start_supervised!({TaskOperationRecorder, []})

    with_task_operations(recorder, fn backup_root ->
      operator_path = Path.join([backup_root, "nested", "vault-7.bundle"])

      capture_task_run(@backup_task, ["--destination", operator_path], ["backup-secret"])

      capture_task_run(
        @restore_task,
        ["--source", operator_path],
        ["restore-secret", "new-password"]
      )

      assert TaskOperationRecorder.get(recorder) == %{
               backup_calls: [
                 %{
                   destination_ref: "nested/vault-7.bundle",
                   passphrase_hash: secret_hash("backup-secret")
                 }
               ],
               restore_calls: [
                 %{
                   new_password_hash: secret_hash("new-password"),
                   passphrase_hash: secret_hash("restore-secret"),
                   source: "nested/vault-7.bundle"
                 }
               ]
             }
    end)
  end

  @tag :tmp_dir
  test "task run/1 reads real inherited numeric descriptors while they remain open", %{
    tmp_dir: tmp_dir
  } do
    recorder = start_supervised!({TaskOperationRecorder, []})
    backup_passphrase = "CANARY_FD_BACKUP_PASSPHRASE_711"
    restore_passphrase = "CANARY_FD_RESTORE_PASSPHRASE_711"
    new_password = "CANARY_FD_RESTORE_PASSWORD_711"

    descriptor_specs = [
      {:backup, Path.join(tmp_dir, "backup-passphrase"), backup_passphrase},
      {:restore, Path.join(tmp_dir, "restore-passphrase"), restore_passphrase},
      {:password, Path.join(tmp_dir, "new-password"), new_password}
    ]

    descriptors = open_secret_descriptors(descriptor_specs)

    try do
      backup_fd = descriptors.backup.fd
      restore_fd = descriptors.restore.fd
      password_fd = descriptors.password.fd

      with_task_operations(recorder, fn _backup_root ->
        {backup_result, backup_stdout, backup_stderr, backup_reads} =
          capture_task_run(
            @backup_task,
            [
              "--passphrase-fd",
              Integer.to_string(backup_fd),
              "--destination",
              "fd-vault-7.bundle"
            ],
            []
          )

        {restore_result, restore_stdout, restore_stderr, restore_reads} =
          capture_task_run(
            @restore_task,
            [
              "--passphrase-fd",
              Integer.to_string(restore_fd),
              "--password-fd",
              Integer.to_string(password_fd),
              "fd-bundle-1.bundle"
            ],
            []
          )

        assert backup_reads == []
        assert restore_reads == []

        assert TaskOperationRecorder.get(recorder) == %{
                 backup_calls: [
                   %{
                     destination_ref: "fd-vault-7.bundle",
                     passphrase_hash: secret_hash(backup_passphrase)
                   }
                 ],
                 restore_calls: [
                   %{
                     new_password_hash: secret_hash(new_password),
                     passphrase_hash: secret_hash(restore_passphrase),
                     source: "fd-bundle-1.bundle"
                   }
                 ]
               }

        for {_purpose, descriptor} <- descriptors do
          assert File.exists?("/proc/self/fd/#{descriptor.fd}")
          assert {:ok, _position} = :file.position(descriptor.device, :cur)
        end

        refute secret_leaked?(
                 [
                   backup_result,
                   backup_stdout,
                   backup_stderr,
                   restore_result,
                   restore_stdout,
                   restore_stderr,
                   TaskOperationRecorder.get(recorder)
                 ],
                 [backup_passphrase, restore_passphrase, new_password]
               )
      end)
    after
      Enum.each(descriptors, fn {_purpose, descriptor} -> File.close(descriptor.device) end)
    end
  end

  test "task run/1 rejects positional and named secrets without any echo" do
    secret = "CANARY_CLI_SECRET_711"
    recorder = start_supervised!({TaskOperationRecorder, []})

    with_task_operations(recorder, fn _backup_root ->
      for {task, arguments} <- [
            {@backup_task, [secret]},
            {@backup_task, ["--password", secret]},
            {@backup_task, ["--passphrase", secret]},
            {@restore_task, ["bundle-1.bundle", secret]},
            {@restore_task, ["--password", secret]},
            {@restore_task, ["--passphrase", secret]}
          ] do
        {exception, stdout, stderr, reads} = capture_rejection(task, arguments)

        assert %Mix.Error{} = exception
        assert Exception.message(exception) =~ ~r/(password|passphrase) arguments are forbidden/
        assert reads == []

        refute secret_leaked?(
                 [exception, Exception.message(exception), inspect(exception), stdout, stderr],
                 [secret]
               )
      end

      assert TaskOperationRecorder.get(recorder) == %{backup_calls: [], restore_calls: []}
    end)
  end

  test "backup task rejects positional path-shaped canaries before reading secrets" do
    recorder = start_supervised!({TaskOperationRecorder, []})

    with_task_operations(recorder, fn _backup_root ->
      for canary <- ["CANARY.destination", "CANARY/path/destination"] do
        {exception, stdout, stderr, reads} = capture_rejection(@backup_task, [canary])

        assert %Mix.Error{} = exception
        assert reads == []
        refute secret_leaked?([exception, stdout, stderr], [canary])
      end

      assert TaskOperationRecorder.get(recorder).backup_calls == []
    end)
  end

  test "backup task redacts adapter exceptions, throws, and malformed results" do
    passphrase = "CANARY_ADAPTER_BOUNDARY_PASSPHRASE_711"

    for operation <- [
          FunctionClauseBackupTaskOperation,
          RaisingBackupTaskOperation,
          MalformedBackupTaskOperation,
          ThrowingBackupTaskOperation,
          ExitingBackupTaskOperation
        ] do
      with_backup_task_operation(operation, fn _backup_root ->
        result_ref = make_ref()

        logs =
          capture_log(fn ->
            send(
              self(),
              {result_ref,
               capture_task_call(
                 @backup_task,
                 ["--destination", "adapter-failure.bundle"],
                 [passphrase]
               )}
            )
          end)

        assert_receive {^result_ref, {{:mix_error, exception}, stdout, stderr, [:get_password]}}
        assert Exception.message(exception) == "backup failed: storage_unavailable"

        refute secret_leaked?(
                 [
                   exception,
                   Exception.message(exception),
                   inspect(exception),
                   stdout,
                   stderr,
                   logs
                 ],
                 [passphrase]
               )
      end)
    end
  end

  test "CLI secret seam uses no-echo prompts for backup and both restore secrets" do
    parent = self()

    readers = %{
      prompt_no_echo: fn purpose ->
        send(parent, {:prompt_no_echo, purpose})

        case purpose do
          :backup_passphrase -> {:ok, "prompt-backup-passphrase"}
          :restore_passphrase -> {:ok, "prompt-restore-passphrase"}
          :new_owner_password -> {:ok, "prompt-new-owner-password"}
        end
      end,
      read_descriptor_once: fn fd, purpose ->
        send(parent, {:unexpected_descriptor, fd, purpose})
        {:error, :unexpected_descriptor}
      end
    }

    assert {:ok, backup_options} =
             task_api(@backup_task, :parse_options, [
               ["--destination", "backup://vault-7"]
             ])

    assert {:ok, %{passphrase: "prompt-backup-passphrase"}} =
             task_api(@backup_task, :read_secrets, [backup_options, readers])

    assert_receive {:prompt_no_echo, :backup_passphrase}

    assert {:ok, restore_options} =
             task_api(@restore_task, :parse_options, [["backup://bundle-1"]])

    assert {:ok,
            %{
              new_password: "prompt-new-owner-password",
              passphrase: "prompt-restore-passphrase"
            }} = task_api(@restore_task, :read_secrets, [restore_options, readers])

    assert_receive {:prompt_no_echo, :restore_passphrase}
    assert_receive {:prompt_no_echo, :new_owner_password}
    refute_receive {:unexpected_descriptor, _, _}
  end

  test "CLI parsers accept the test restore oracle and require exactly one local reference" do
    assert {:ok,
            %{
              destination_ref: "vault-7.bundle",
              restore_oracle: true
            }} =
             task_api(@backup_task, :parse_options, [
               ["--restore-oracle", "--destination", "vault-7.bundle"]
             ])

    assert {:ok, %{restore_oracle: true, source: "vault-7.bundle"}} =
             task_api(@restore_task, :parse_options, [
               ["--restore-oracle", "--source", "vault-7.bundle"]
             ])

    assert {:ok, %{restore_oracle: false, source: "vault-7.bundle"}} =
             task_api(@restore_task, :parse_options, [["vault-7.bundle"]])

    for arguments <- [
          [],
          ["--source", "one.bundle", "two.bundle"],
          ["--source", "one.bundle", "--source", "two.bundle"]
        ] do
      assert {:error, %Error{code: :invalid}} =
               task_api(@restore_task, :parse_options, [arguments])
    end

    for arguments <- [
          [],
          ["--destination", "one.bundle", "--destination", "two.bundle"]
        ] do
      assert {:error, %Error{code: :invalid}} =
               task_api(@backup_task, :parse_options, [arguments])
    end
  end

  test "CLI parsers reject the internal restore oracle outside MIX_ENV=test" do
    previous_env = Mix.env()

    try do
      Mix.env(:prod)

      for {task, arguments} <- [
            {@backup_task, ["--restore-oracle", "--destination", "vault-7.bundle"]},
            {@restore_task, ["--restore-oracle", "--source", "vault-7.bundle"]}
          ] do
        assert {:error, %Error{code: :invalid}} =
                 task_api(task, :parse_options, [arguments])
      end
    after
      Mix.env(previous_env)
    end
  end

  test "backup CLI accepts stable local references and rejects unsafe path syntax" do
    for reference <- [
          "backup",
          "backup.bundle",
          "nested/backup.bundle",
          "/srv/singularity/backups/backup.bundle",
          "backup://vault-7"
        ] do
      assert {:ok, %{destination_ref: ^reference}} =
               task_api(@backup_task, :parse_options, [["--destination", reference]])
    end

    for reference <- [
          "",
          <<0>>,
          ".",
          "..",
          "../backup.bundle",
          "nested/../backup.bundle",
          "nested/./backup.bundle",
          "nested\\..\\backup.bundle"
        ] do
      assert {:error, %Error{code: :invalid}} =
               task_api(@backup_task, :parse_options, [["--destination", reference]])
    end

    assert {:error, %Error{code: :invalid}} =
             task_api(@backup_task, :parse_options, [
               [
                 "--destination",
                 "backup://one",
                 "--destination",
                 "backup://two"
               ]
             ])
  end

  test "CLI secret seam reads inherited backup and restore descriptors exactly once" do
    parent = self()

    readers = %{
      prompt_no_echo: fn purpose ->
        send(parent, {:unexpected_prompt, purpose})
        {:error, :unexpected_prompt}
      end,
      read_descriptor_once: fn fd, purpose ->
        send(parent, {:descriptor_read, fd, purpose})

        case {fd, purpose} do
          {9, :backup_passphrase} -> {:ok, "fd-backup-passphrase"}
          {10, :restore_passphrase} -> {:ok, "fd-restore-passphrase"}
          {11, :new_owner_password} -> {:ok, "fd-new-owner-password"}
        end
      end
    }

    assert {:ok, backup_options} =
             task_api(@backup_task, :parse_options, [
               ["--passphrase-fd", "9", "--destination", "backup://vault-7"]
             ])

    assert {:ok, %{passphrase: "fd-backup-passphrase"}} =
             task_api(@backup_task, :read_secrets, [backup_options, readers])

    assert_receive {:descriptor_read, 9, :backup_passphrase}

    assert {:ok, restore_options} =
             task_api(@restore_task, :parse_options, [
               [
                 "--passphrase-fd",
                 "10",
                 "--password-fd",
                 "11",
                 "backup://bundle-1"
               ]
             ])

    assert {:ok,
            %{
              new_password: "fd-new-owner-password",
              passphrase: "fd-restore-passphrase"
            }} = task_api(@restore_task, :read_secrets, [restore_options, readers])

    assert_receive {:descriptor_read, 10, :restore_passphrase}
    assert_receive {:descriptor_read, 11, :new_owner_password}
    refute_receive {:descriptor_read, _, _}
    refute_receive {:unexpected_prompt, _}
  end

  defp request(context) do
    api(:request, [context.runtime, context.session, @passphrase, "backup://vault-7"])
  end

  defp api(function, arguments), do: apply(@backup_vault, function, arguments)
  defp task_api(task, function, arguments), do: apply(task, function, arguments)

  defp runtime(state) do
    %{
      backup_key_lease: {BackupKeys, state},
      backups: {Backups, state},
      custodian: {Custodian, state},
      ids: {Ids, state},
      jobs: {Jobs, state},
      operation_scope: {Scope, state},
      partial_bundles: {PartialBundles, state}
    }
  end

  defp worker_context(state) do
    Map.merge(runtime(state), %{
      authorization: state,
      authorize: Authorize,
      bundle_reader: {BundleReader, state},
      bundle_verifier: {BundleVerifier, state},
      bundle_writer: {BundleWriter, state},
      destination: {Destination, state},
      exporter: {Exporter, state},
      job_progress: {JobProgress, state},
      object_storage: {ObjectStorage, state},
      transact: fn options, callback ->
        transaction = State.next_worker_transaction(state)
        State.record(state, {:worker_transaction_begin, transaction, options})

        if State.failure(state) == :second_worker_transaction_raise and transaction == 2 do
          raise "simulated second worker transaction failure"
        else
          result = callback.(:worker_repo)
          State.record(state, {:worker_transaction_commit, transaction})
          result
        end
      end
    })
  end

  defp session do
    %{
      principal_authorization_epoch: 7,
      principal_id: "principal-7",
      session_id: "session-7",
      vault_authorization_epoch: 11,
      vault_id: @vault_id
    }
  end

  defp waiting_manifest do
    binding = %{"manifest_id" => @manifest_id, "vault_id" => @vault_id}

    %{
      backup_key_lease_id: "lost-after-restart-ref",
      classification: :private,
      destination_ref: "backup://vault-7",
      id: @manifest_id,
      kdf: @kdf,
      recovery: %{
        "binding" => binding,
        "label" => "backup_recovery",
        "wrapper" => recovery_wrapper(@derived_key, binding)
      },
      status: :waiting_for_backup_key,
      vault_id: @vault_id
    }
  end

  defp backup_envelope do
    {:ok, envelope} =
      JobEnvelope.new(%{
        version: 1,
        job_id: "00000000-0000-4000-8000-000000000713",
        job_type: "backup",
        idempotency_key: "backup:#{@manifest_id}",
        vault_id: @vault_id,
        principal_id: "00000000-0000-4000-8000-000000000714",
        required_capability: "backup.create",
        principal_authorization_epoch: 7,
        vault_authorization_epoch: 11,
        classification: :private,
        correlation_id: "00000000-0000-4000-8000-000000000715",
        causation_id: "00000000-0000-4000-8000-000000000716",
        expected_entity_revision: 0,
        attempt: 0,
        payload: %{"pending_manifest_id" => @manifest_id}
      })

    envelope
  end

  defp recovery_wrapper(derived_key, binding) do
    :crypto.mac(
      :hmac,
      :sha256,
      derived_key,
      :erlang.term_to_binary({:backup_recovery, binding})
    )
    |> Base.encode16()
  end

  defp with_task_operations(recorder, callback) do
    with_task_backup_root(fn backup_root ->
      keys = [:backup_task, :restore_task]

      previous =
        Map.new(keys, fn key ->
          {key, Application.fetch_env(:singularity_runtime, key)}
        end)

      Application.put_env(:singularity_runtime, :backup_task, %{
        operation: {BackupTaskOperation, recorder},
        runtime: %{},
        session: session()
      })

      Application.put_env(:singularity_runtime, :restore_task, %{
        context: %{},
        operation: {RestoreTaskOperation, recorder}
      })

      try do
        callback.(backup_root)
      after
        Enum.each(previous, fn
          {key, {:ok, value}} -> Application.put_env(:singularity_runtime, key, value)
          {key, :error} -> Application.delete_env(:singularity_runtime, key)
        end)
      end
    end)
  end

  defp with_backup_task_operation(operation, callback) do
    with_task_backup_root(fn backup_root ->
      previous = Application.fetch_env(:singularity_runtime, :backup_task)

      Application.put_env(:singularity_runtime, :backup_task, %{
        operation: operation,
        runtime: %{},
        session: session()
      })

      try do
        callback.(backup_root)
      after
        case previous do
          {:ok, value} -> Application.put_env(:singularity_runtime, :backup_task, value)
          :error -> Application.delete_env(:singularity_runtime, :backup_task)
        end
      end
    end)
  end

  defp with_task_backup_root(callback) do
    backup_root =
      Path.join(
        System.tmp_dir!(),
        "singularity-cli-#{System.unique_integer([:positive, :monotonic])}"
      )

    previous = Application.fetch_env(:singularity_storage, :backup_root)
    File.mkdir_p!(backup_root)
    Application.put_env(:singularity_storage, :backup_root, backup_root)

    try do
      callback.(backup_root)
    after
      case previous do
        {:ok, value} -> Application.put_env(:singularity_storage, :backup_root, value)
        :error -> Application.delete_env(:singularity_storage, :backup_root)
      end

      File.rm_rf!(backup_root)
    end
  end

  defp capture_task_run(task, arguments, secrets) do
    {{:return, result}, stdout, stderr, reads} =
      capture_task_call(task, arguments, secrets)

    {result, stdout, stderr, reads}
  end

  defp capture_rejection(task, arguments) do
    {{:mix_error, exception}, stdout, stderr, reads} =
      capture_task_call(task, arguments, [])

    {exception, stdout, stderr, reads}
  end

  defp capture_task_call(task, arguments, secrets) do
    {:ok, io_device} = NoEchoIO.start_link(secrets)
    original_group_leader = Process.group_leader()
    result_ref = make_ref()

    try do
      assert Process.group_leader(self(), io_device)

      stderr =
        capture_io(:stderr, fn ->
          outcome =
            try do
              {:return, task_api(task, :run, [arguments])}
            rescue
              exception in Mix.Error -> {:mix_error, exception}
            end

          send(self(), {result_ref, outcome})
        end)

      outcome =
        receive do
          {^result_ref, outcome} -> outcome
        after
          1_000 -> flunk("Mix task did not return")
        end

      {outcome, NoEchoIO.output(io_device), stderr, NoEchoIO.reads(io_device)}
    after
      Process.group_leader(self(), original_group_leader)

      if Process.alive?(io_device) do
        GenServer.stop(io_device)
      end
    end
  end

  defp open_secret_descriptors(specs) do
    Map.new(specs, fn {purpose, path, secret} ->
      File.write!(path, secret <> "\n")
      File.chmod!(path, 0o600)
      device = File.open!(path, [:read, :binary])

      {purpose, %{device: device, fd: numeric_descriptor_for!(path)}}
    end)
  end

  defp numeric_descriptor_for!(path) do
    expanded_path = Path.expand(path)

    Path.wildcard("/proc/self/fd/*")
    |> Enum.find_value(fn descriptor_path ->
      case File.read_link(descriptor_path) do
        {:ok, ^expanded_path} -> descriptor_path |> Path.basename() |> String.to_integer()
        _other -> nil
      end
    end)
    |> case do
      nil -> flunk("open file did not have a numeric /proc/self/fd descriptor")
      descriptor -> descriptor
    end
  end

  defp secret_hash(secret), do: :crypto.hash(:sha256, secret)

  defp json_safe_map?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} ->
      is_binary(key) and json_safe_value?(value)
    end)
  end

  defp json_safe_value?(value) when is_map(value), do: json_safe_map?(value)
  defp json_safe_value?(value) when is_list(value), do: Enum.all?(value, &json_safe_value?/1)

  defp json_safe_value?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp event_index!(events, tag) do
    case Enum.find_index(events, &tagged?(&1, tag)) do
      nil -> flunk("expected event #{inspect(tag)} was not recorded")
      index -> index
    end
  end

  defp tagged?(tag, tag), do: true

  defp tagged?(event, tag) when is_tuple(event) and tuple_size(event) > 0,
    do: elem(event, 0) == tag

  defp tagged?(_event, _tag), do: false

  defp secret_leaked?(value, secrets) do
    binaries = collect_binaries(value) ++ rendered_forms(value)

    Enum.any?(secrets, fn secret ->
      Enum.any?(secret_forms(secret), fn form ->
        Enum.any?(binaries, &binary_contains?(&1, form))
      end)
    end)
  end

  defp collect_binaries(value) when is_binary(value), do: [value]

  defp collect_binaries(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.flat_map(fn {key, nested} ->
      collect_binaries(key) ++ collect_binaries(nested)
    end)
  end

  defp collect_binaries(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.flat_map(&collect_binaries/1)

  defp collect_binaries(value) when is_list(value),
    do: Enum.flat_map(value, &collect_binaries/1)

  defp collect_binaries(_value), do: []

  defp rendered_forms(value) do
    [
      inspect(value, limit: :infinity, printable_limit: :infinity),
      inspect(value,
        base: :hex,
        binaries: :as_binaries,
        charlists: :as_lists,
        limit: :infinity,
        printable_limit: :infinity
      )
    ]
  end

  defp secret_forms(secret) when is_binary(secret) do
    [
      secret,
      Base.encode16(secret, case: :lower),
      Base.encode16(secret, case: :upper),
      inspect(secret, limit: :infinity, printable_limit: :infinity),
      inspect(secret,
        base: :hex,
        binaries: :as_binaries,
        limit: :infinity,
        printable_limit: :infinity
      ),
      inspect(:binary.bin_to_list(secret), limit: :infinity)
    ]
    |> Enum.uniq()
  end

  defp binary_contains?(binary, form) when is_binary(binary) and is_binary(form),
    do: :binary.match(binary, form) != :nomatch
end
