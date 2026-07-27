defmodule Singularity.Storage.BackupConcurrencyTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.ObjectRef
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.OutboxDispatcher
  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.Backup.Exporter
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Jobs.WorkerScope
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.Outbox
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock

  @backup_vault Singularity.Runtime.BackupVault
  @barrier_timeout 5_000

  defmodule Harness do
    use Agent

    def start_link(options) do
      Agent.start_link(fn ->
        %{
          bundle: %{
            accepted?: false,
            final?: false,
            inventory: [],
            status: :absent
          },
          events: [],
          failure: Keyword.get(options, :failure),
          gate: Keyword.fetch!(options, :gate),
          manifest: Keyword.fetch!(options, :manifest),
          observer: Keyword.fetch!(options, :observer),
          snapshot_id: Keyword.fetch!(options, :snapshot_id)
        }
      end)
    end

    def snapshot(state), do: Agent.get(state, & &1)

    def value(state, key), do: Agent.get(state, &Map.fetch!(&1, key))

    def record(state, event) do
      Agent.update(state, fn current ->
        %{current | events: current.events ++ [event]}
      end)
    end

    def record_partial(state, inventory) do
      Agent.update(state, fn current ->
        %{
          current
          | bundle: %{
              accepted?: false,
              final?: false,
              inventory: inventory,
              status: :partial
            },
            events: current.events ++ [:bundle_partial]
        }
      end)
    end

    def acknowledge(state, manifest) do
      Agent.update(state, fn current ->
        %{
          current
          | bundle: %{
              accepted?: true,
              final?: true,
              inventory: manifest.inventory,
              status: :sealed
            },
            events: current.events ++ [:acknowledge_sealed],
            manifest: manifest
        }
      end)
    end

    def put_manifest(state, manifest) do
      Agent.update(state, &%{&1 | manifest: manifest})
    end
  end

  defmodule SnapshotExporter do
    import ExUnit.Assertions
    import Singularity.Storage.DataCase, only: [query!: 3]

    alias Singularity.Storage.BackupConcurrencyTest.Harness

    def snapshot_cut(state, repo, vault_id) do
      assert %{rows: [["repeatable read"]]} =
               query!(repo, "SHOW transaction_isolation", [])

      assert %{rows: [[database_snapshot]]} =
               query!(repo, "SELECT txid_current_snapshot()::text", [])

      assert %{rows: [[outbox_high_water_mark]]} =
               query!(
                 repo,
                 """
                 SELECT COALESCE(max(sequence), 0)
                 FROM core.outbox_events
                 WHERE vault_id = $1
                 """,
                 [Ecto.UUID.dump!(vault_id)]
               )

      cut = %{
        database_snapshot: database_snapshot,
        object_inventory: inventory(repo, vault_id),
        outbox_high_water_mark: outbox_high_water_mark,
        snapshot_id: Harness.value(state, :snapshot_id),
        transaction_isolation: :repeatable_read,
        vault_id: vault_id
      }

      observer = Harness.value(state, :observer)
      gate = Harness.value(state, :gate)
      send(observer, {:backup_cut, gate, cut})

      receive do
        {^gate, :continue_cut} -> {:ok, cut}
      after
        5_000 -> raise "backup snapshot-cut barrier timed out"
      end
    end

    def records(_state, repo, %{vault_id: vault_id}) do
      assert %{rows: rows} =
               query!(
                 repo,
                 """
                 SELECT id, state, state_revision
                 FROM content.assets
                 WHERE vault_id = $1
                 ORDER BY id
                 """,
                 [Ecto.UUID.dump!(vault_id)]
               )

      records =
        Enum.map(rows, fn [asset_id, state, state_revision] ->
          attrs = %{
            asset_id: Ecto.UUID.load!(asset_id),
            state: state,
            state_revision: state_revision
          }

          record(0x0001, attrs, attrs)
        end)

      {:ok, %{records: records, inventory: Enum.map(records, &descriptor/1)}}
    end

    def stream_inventory(_state, %{object_inventory: inventory}) do
      {:ok, %{records: inventory, inventory: Enum.map(inventory, &descriptor/1)}}
    end

    def object_record(entry), do: record(0xBEEF, entry, entry)

    defp inventory(repo, vault_id) do
      assert %{rows: rows} =
               query!(
                 repo,
                 """
                 SELECT
                   object.id,
                   object.vault_id,
                   object.classification,
                   object.storage_ref,
                   object.ciphertext_byte_size,
                   object.ciphertext_hash
                 FROM content.asset_objects AS object
                 WHERE object.vault_id = $1
                   AND object.lifecycle = 'available'
                   AND EXISTS (
                     SELECT 1
                     FROM content.assets AS asset
                     WHERE asset.asset_object_id = object.id
                       AND asset.vault_id = object.vault_id
                       AND asset.state NOT IN ('pending_delete', 'deleted')
                   )
                 ORDER BY object.id
                 """,
                 [Ecto.UUID.dump!(vault_id)]
               )

      rows
      |> Enum.with_index()
      |> Enum.map(fn {
                       [
                         object_id,
                         vault_id,
                         classification,
                         storage_ref,
                         byte_size,
                         ciphertext_hash
                       ],
                       position
                     } ->
        object_record(%{
          asset_object_id: Ecto.UUID.load!(object_id),
          classification: String.to_existing_atom(classification),
          ciphertext_byte_size: byte_size,
          ciphertext_hash: ciphertext_hash,
          inventory_position: position,
          storage_ref: storage_ref,
          vault_id: Ecto.UUID.load!(vault_id)
        })
      end)
    end

    defp record(type, payload_term, attrs) do
      payload = :erlang.term_to_binary(payload_term, [:deterministic])

      Map.merge(attrs, %{
        payload: payload,
        payload_length: byte_size(payload),
        type: type
      })
    end

    defp descriptor(record) do
      %{
        record_type: record.type,
        payload_length: record.payload_length,
        sha256: :crypto.hash(:sha256, record.payload)
      }
    end
  end

  defmodule BarrierBundleWriter do
    import ExUnit.Assertions

    alias Singularity.Core.Error
    alias Singularity.Storage.BackupConcurrencyTest.Harness
    alias Singularity.Storage.BackupConcurrencyTest.OpaqueBackupCrypto

    def probe(state, destination_ref, manifest_id) do
      case Harness.snapshot(state) do
        %{bundle: %{status: :absent}} ->
          {:ok, :absent}

        %{bundle: %{status: :partial}} ->
          {:ok, :partial}

        %{
          bundle: %{accepted?: true, final?: true, status: :sealed},
          manifest: %{destination_ref: ^destination_ref, id: ^manifest_id}
        } ->
          {:ok,
           {:final,
            %{
              destination_ref: destination_ref,
              manifest_id: manifest_id,
              path: destination_ref
            }}}

        _invalid ->
          {:error, Error.new(:backup_invalid)}
      end
    end

    def writer_destination(_state, destination_ref), do: {:ok, destination_ref}

    def stream(
          state,
          destination_ref,
          records,
          inventory,
          manifest,
          %{
            adapter: OpaqueBackupCrypto,
            capability: {:opaque_backup_crypto, manifest_id},
            public_header: %{kdf: kdf, manifest_id: manifest_id, version: 1}
          } = crypto
        )
        when is_map(kdf) do
      expected_manifest_inventory =
        (records ++ inventory)
        |> Enum.with_index()
        |> Enum.map(fn {record, position} ->
          %{
            position: position,
            record_type: record.type,
            payload_length: record.payload_length,
            sha256: :crypto.hash(:sha256, IO.iodata_to_binary(record.payload))
          }
        end)

      assert manifest.inventory == expected_manifest_inventory

      gate = Harness.value(state, :gate)
      observer = Harness.value(state, :observer)
      failure = Harness.value(state, :failure)
      Harness.record_partial(state, inventory)

      send(
        observer,
        {:bundle_copy_started, gate, destination_ref, records, inventory, manifest, crypto}
      )

      receive do
        {^gate, :continue_copy} -> :ok
      after
        5_000 -> raise "backup copy barrier timed out"
      end

      if failure == :copy do
        {:error, Error.new(:storage_unavailable, retryable?: true)}
      else
        send(observer, {:bundle_seal_started, gate})

        receive do
          {^gate, :continue_seal} -> :ok
        after
          5_000 -> raise "backup seal barrier timed out"
        end

        if failure == :seal do
          {:error, Error.new(:storage_unavailable, retryable?: true)}
        else
          {:ok,
           %{
             destination_ref: destination_ref,
             inventory: inventory,
             manifest_hash: :crypto.hash(:sha256, :erlang.term_to_binary(manifest)),
             manifest_id: manifest_id,
             manifest_tag: :binary.copy(<<0x7A>>, 16),
             path: destination_ref,
             records: records
           }}
        end
      end
    end

    def authenticate_destination(state, destination_ref) do
      case Harness.snapshot(state) do
        %{
          bundle: %{accepted?: true, final?: true, status: :sealed} = bundle,
          manifest: %{destination_ref: ^destination_ref, status: :sealed}
        } ->
          {:ok, bundle}

        _incomplete ->
          {:error, Error.new(:backup_invalid)}
      end
    end
  end

  defmodule RecordingObjectStorage do
    alias Singularity.Core.Error
    alias Singularity.Core.ObjectRef

    def open(%{observer: observer, objects: objects} = context, %ObjectRef{object_id: object_id}) do
      send(observer, {:object_opened, object_id, context})

      if Map.has_key?(objects, object_id) do
        {:ok, object_id}
      else
        {:error, Error.new(:not_found)}
      end
    end

    def read_range(
          %{observer: observer, objects: objects},
          object_id,
          %Range{first: first, last: last, step: 1} = range
        ) do
      send(observer, {:object_range_read, object_id, range})
      bytes = Map.fetch!(objects, object_id)

      if first >= byte_size(bytes) do
        {:ok, ""}
      else
        length = min(last - first + 1, byte_size(bytes) - first)
        {:ok, binary_part(bytes, first, length)}
      end
    end
  end

  defmodule Backups do
    alias Singularity.Core.Error
    alias Singularity.Storage.BackupConcurrencyTest.Harness

    def load_pending(
          state,
          _repo,
          %{manifest_id: manifest_id, vault_id: vault_id} = command
        )
        when map_size(command) == 2 do
      case Harness.value(state, :manifest) do
        %{id: ^manifest_id, status: :pending, vault_id: ^vault_id} = manifest ->
          copying = %{manifest | status: :copying}
          Harness.put_manifest(state, copying)
          {:ok, copying}

        %{id: ^manifest_id, status: :copying, vault_id: ^vault_id} = manifest ->
          waiting = %{manifest | status: :waiting_for_backup_key}
          Harness.put_manifest(state, waiting)
          {:ok, waiting}

        %{id: ^manifest_id, status: status, vault_id: ^vault_id} = manifest
        when status in [:waiting_for_backup_key, :sealed] ->
          {:ok, manifest}

        _missing ->
          {:error, Error.new(:not_found)}
      end
    end

    def mark_waiting_for_backup_key(
          state,
          _repo,
          %{manifest_id: manifest_id, vault_id: vault_id, custody_ref: custody_ref} = command
        )
        when map_size(command) == 3 do
      case Harness.value(state, :manifest) do
        %{
          id: ^manifest_id,
          backup_key_lease_id: ^custody_ref,
          status: status,
          vault_id: ^vault_id
        } = manifest
        when status in [:pending, :copying, :waiting_for_backup_key] ->
          waiting = %{manifest | status: :waiting_for_backup_key}
          Harness.put_manifest(state, waiting)
          {:ok, waiting}

        _stale ->
          {:error, Error.new(:conflict)}
      end
    end

    def acknowledge_sealed(
          state,
          _repo,
          %{
            cut: cut,
            expected_custody_ref: custody_ref,
            manifest_id: manifest_id,
            sealed: sealed,
            vault_id: vault_id
          } = command
        )
        when map_size(command) == 5 do
      pending = Harness.value(state, :manifest)
      true = pending.id == manifest_id
      true = pending.vault_id == vault_id
      true = pending.backup_key_lease_id == custody_ref
      true = pending.status == :copying
      true = sealed.destination_ref == pending.destination_ref
      true = sealed.manifest_id == manifest_id

      manifest =
        Map.merge(pending, %{
          inventory: cut.object_inventory,
          manifest_hash: sealed.manifest_hash,
          manifest_tag: sealed.manifest_tag,
          outbox_high_water_mark: cut.outbox_high_water_mark,
          sealed_at: DateTime.utc_now(),
          snapshot_id: cut.snapshot_id,
          status: :sealed
        })

      Harness.acknowledge(state, manifest)

      send(
        Harness.value(state, :observer),
        {:manifest_sealed, Harness.value(state, :gate), manifest}
      )

      {:ok, manifest}
    end
  end

  defmodule AllowJobAuthorization do
    def check(_authorization, _repo, _session, _requirement), do: :ok
    def check_job(_authorization, _repo, _envelope), do: :ok
  end

  defmodule OpaqueBackupCrypto do
    alias Singularity.Storage.BackupConcurrencyTest.Harness

    def backup_crypto(state, manifest_id, _lease_id) do
      manifest = Harness.value(state, :manifest)

      {:ok,
       %{
         adapter: __MODULE__,
         capability: {:opaque_backup_crypto, manifest_id},
         public_header: %{kdf: manifest.kdf, manifest_id: manifest_id, version: 1}
       }}
    end

    def revoke_backup_key(state, lease_id) do
      Harness.record(state, {:revoke_backup_key, lease_id})
      :ok
    end
  end

  defmodule JobProgress do
    alias Singularity.Storage.BackupConcurrencyTest.Harness

    def wait_for_backup_key(state, _repo, envelope) do
      Harness.record(state, {:wait_for_backup_key, envelope.payload["pending_manifest_id"]})
      :ok
    end
  end

  defmodule RecordingRunner do
    @behaviour Singularity.Core.JobRunner

    @impl true
    def submit(observer, envelope) do
      send(observer, {:runner_submit, envelope})
      {:ok, "backup-concurrency-runner:" <> envelope.job_id}
    end

    @impl true
    def wake_vault(_observer, _vault_id), do: :ok
  end

  setup do
    mark_existing_events_delivered!()
    %{one: raw_fixture, two: raw_other} = Fixtures.two_vaults!()

    {:ok,
     fixture: load_ids(raw_fixture),
     other: load_ids(raw_other),
     raw_fixture: raw_fixture,
     raw_other: raw_other}
  end

  test "production cut captures the repeatable-read snapshot, vault outbox mark, and ordered reachable objects",
       %{
         fixture: fixture,
         other: other,
         raw_fixture: raw_fixture,
         raw_other: raw_other
       } do
    expected_inventory = seed_inventory_fixture!(fixture, other)
    same_vault_event = Fixtures.outbox_event!(raw_fixture)
    _other_vault_event = Fixtures.outbox_event!(raw_other)
    expected_high_water = outbox_sequence!(same_vault_event.id)

    assert {:ok, cut} =
             ScopedRepo.transact(
               WorkerRepo,
               %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
               [isolation: :repeatable_read],
               fn repo -> Exporter.snapshot_cut(repo, fixture.vault_id) end
             )

    assert cut.vault_id == fixture.vault_id
    snapshot_id = cut.snapshot_id
    assert {:ok, ^snapshot_id} = Ecto.UUID.cast(snapshot_id)
    assert is_binary(cut.database_snapshot)
    assert cut.database_snapshot != ""
    assert cut.outbox_high_water_mark == expected_high_water

    expected_ids = Enum.map(expected_inventory, & &1.asset_object_id)
    assert Enum.map(cut.object_inventory, & &1.asset_object_id) == expected_ids
    assert expected_ids == Enum.sort(expected_ids)

    assert Enum.with_index(cut.object_inventory)
           |> Enum.all?(fn {entry, position} ->
             entry.inventory_position == position and
               entry.vault_id == fixture.vault_id and
               is_binary(entry.key_domain_id) and
               byte_size(entry.lookup_digest) == 32 and
               byte_size(entry.ciphertext_hash) == 32 and
               entry.ciphertext_byte_size >= 0
           end)
  end

  test "production cut rejects a read-committed caller", %{fixture: fixture} do
    assert {:error, %Error{code: :invalid}} =
             Exporter.snapshot_cut(WorkerRepo, fixture.vault_id)
  end

  test "object inventory is lazy and reads exact 64 KiB ranges with object-bound context" do
    object_id = Ecto.UUID.generate()
    vault_id = Ecto.UUID.generate()
    key_domain_id = Ecto.UUID.generate()
    lookup_digest = :crypto.strong_rand_bytes(32)
    bytes = :binary.copy(<<0xA5>>, 2 * 65_536) <> "last-seventeen!!!"
    ciphertext_hash = :crypto.hash(:sha256, bytes)
    storage_ref = "objects/#{object_id}"

    cut = %{
      object_inventory: [
        %{
          asset_object_id: object_id,
          vault_id: vault_id,
          key_domain_id: key_domain_id,
          classification: :private,
          lookup_digest: lookup_digest,
          storage_ref: storage_ref,
          ciphertext_byte_size: byte_size(bytes),
          ciphertext_hash: ciphertext_hash,
          inventory_position: 0
        }
      ],
      vault_id: vault_id
    }

    storage_context = %{observer: self(), objects: %{storage_ref => bytes}}

    assert {:ok, %{records: records, inventory: inventory}} =
             Exporter.stream_inventory({RecordingObjectStorage, storage_context}, cut)

    assert inventory == [
             %{
               record_type: 0x8000,
               payload_length: byte_size(bytes),
               sha256: ciphertext_hash
             }
           ]

    refute_receive {:object_opened, _, _}
    assert [record] = Enum.to_list(records)
    assert record.type == 0x8000
    assert record.payload_length == byte_size(bytes)
    assert record.asset_object_id == object_id
    refute_receive {:object_opened, _, _}

    assert bytes == record.payload |> Enum.to_list() |> IO.iodata_to_binary()

    assert_receive {:object_opened, ^storage_ref, enriched_context}

    assert Map.take(enriched_context, [
             :vault_namespace,
             :domain_namespace,
             :lookup_digest,
             :ciphertext_hash
           ]) == %{
             vault_namespace: vault_id,
             domain_namespace: key_domain_id,
             lookup_digest: Base.encode16(lookup_digest, case: :lower),
             ciphertext_hash: ciphertext_hash
           }

    assert_receive {:object_range_read, ^storage_ref, 0..65_535//1}
    assert_receive {:object_range_read, ^storage_ref, 65_536..131_071//1}
    assert_receive {:object_range_read, ^storage_ref, 131_072..131_088//1}
    refute_receive {:object_range_read, ^storage_ref, _range}
  end

  test "object inventory opens the opaque storage ref rather than the asset object id" do
    object_id = Ecto.UUID.generate()
    storage_ref = "opaque-storage-ref/#{Ecto.UUID.generate()}"
    vault_id = Ecto.UUID.generate()
    bytes = "opaque object ciphertext"

    cut = %{
      object_inventory: [
        %{
          asset_object_id: object_id,
          vault_id: vault_id,
          key_domain_id: Ecto.UUID.generate(),
          classification: :private,
          lookup_digest: :crypto.strong_rand_bytes(32),
          storage_ref: storage_ref,
          ciphertext_byte_size: byte_size(bytes),
          ciphertext_hash: :crypto.hash(:sha256, bytes),
          inventory_position: 0
        }
      ],
      vault_id: vault_id
    }

    storage_context = %{observer: self(), objects: %{storage_ref => bytes}}

    assert {:ok, %{records: records}} =
             Exporter.stream_inventory({RecordingObjectStorage, storage_context}, cut)

    assert [%{asset_object_id: ^object_id, payload: payload}] = Enum.to_list(records)
    assert bytes == payload |> Enum.to_list() |> IO.iodata_to_binary()
    assert_receive {:object_opened, ^storage_ref, _context}
    refute_receive {:object_opened, ^object_id, _context}
  end

  test "short object bytes fail before the authoritative descriptor is accepted" do
    object_id = Ecto.UUID.generate()
    vault_id = Ecto.UUID.generate()
    expected_bytes = :binary.copy(<<0x5A>>, 70_000)
    short_bytes = binary_part(expected_bytes, 0, 65_539)
    expected_hash = :crypto.hash(:sha256, expected_bytes)
    storage_ref = "objects/#{object_id}"

    cut = %{
      object_inventory: [
        %{
          asset_object_id: object_id,
          vault_id: vault_id,
          key_domain_id: Ecto.UUID.generate(),
          classification: :private,
          lookup_digest: :crypto.strong_rand_bytes(32),
          storage_ref: storage_ref,
          ciphertext_byte_size: byte_size(expected_bytes),
          ciphertext_hash: expected_hash,
          inventory_position: 0
        }
      ],
      vault_id: vault_id
    }

    storage_context = %{observer: self(), objects: %{storage_ref => short_bytes}}

    assert {:ok, %{records: records, inventory: [descriptor]}} =
             Exporter.stream_inventory({RecordingObjectStorage, storage_context}, cut)

    assert [record] = Enum.to_list(records)

    assert {Exporter, :object_stream_error, %Error{code: :integrity_failure}} =
             catch_throw(Enum.to_list(record.payload))

    assert descriptor.payload_length == byte_size(expected_bytes)
    assert descriptor.sha256 == expected_hash
  end

  test "outbox claims skip vaults held by an exclusive vault lock", %{
    fixture: fixture,
    raw_fixture: raw_fixture,
    raw_other: raw_other
  } do
    same_vault_event = Fixtures.outbox_event!(raw_fixture)
    other_vault_event = Fixtures.outbox_event!(raw_other)
    gate = make_ref()
    parent = self()

    lock_holder =
      tracked_task(fn ->
        VaultLock.with_exclusive(WorkerRepo, fixture.vault_id, fn _repo ->
          send(parent, {:exclusive_vault_lock_acquired, gate})
          await_release(gate)
        end)
      end)

    assert_receive {:exclusive_vault_lock_acquired, ^gate}, @barrier_timeout

    assert {:ok, [claimed_other]} =
             Outbox.claim(DispatcherRepo, %{
               limit: 100,
               lease_seconds: 60,
               claim_token: Ecto.UUID.generate()
             })

    assert claimed_other.outbox_event_id == load_uuid(other_vault_event.id)
    assert_outbox_unclaimed!(same_vault_event.id)

    send(lock_holder.pid, {gate, :release})
    assert :ok = Task.await(lock_holder, @barrier_timeout)

    assert {:ok, [claimed_same]} =
             Outbox.claim(DispatcherRepo, %{
               limit: 100,
               lease_seconds: 60,
               claim_token: Ecto.UUID.generate()
             })

    assert claimed_same.outbox_event_id == load_uuid(same_vault_event.id)
  end

  test "backup waits for existing shared operations and holds the cut through seal", %{
    fixture: fixture,
    raw_fixture: raw_fixture,
    raw_other: raw_other
  } do
    [_object] = seed_reachable_objects!(fixture, 1)
    same_vault_event = Fixtures.outbox_event!(raw_fixture)
    _other_vault_event = Fixtures.outbox_event!(raw_other)
    {state, gate, envelope} = start_harness(fixture)

    upload = start_request_holder(fixture, :upload)
    metadata = start_worker_holder(fixture, "asset_metadata", "asset.metadata", :metadata)
    cleanup = start_worker_holder(fixture, "object_cleanup", "object.cleanup", :cleanup)

    for {_task, holder_gate, label} <- [upload, metadata, cleanup] do
      assert_receive {:shared_operation_acquired, ^holder_gate, ^label}
    end

    backup = tracked_task(fn -> run_backup(state, envelope) end)
    assert_receive {:backup_attempting, ^gate}
    refute_receive {:backup_cut, ^gate, _cut}, 200

    for {task, holder_gate, _label} <- [upload, metadata] do
      send(task.pid, {holder_gate, :release})
      assert :ok = Task.await(task, @barrier_timeout)
      refute_receive {:backup_cut, ^gate, _cut}, 100
    end

    {cleanup_task, cleanup_gate, :cleanup} = cleanup
    send(cleanup_task.pid, {cleanup_gate, :release})
    assert :ok = Task.await(cleanup_task, @barrier_timeout)

    assert_receive {:backup_cut, ^gate, cut}, @barrier_timeout
    assert cut.transaction_isolation == :repeatable_read
    assert is_binary(cut.database_snapshot)

    waiting_mutation = start_request_holder(fixture, :waiting_mutation)
    {waiting_task, waiting_gate, :waiting_mutation} = waiting_mutation
    assert_receive {:shared_operation_attempting, ^waiting_gate, :waiting_mutation}
    refute_receive {:shared_operation_acquired, ^waiting_gate, :waiting_mutation}, 200

    assert {:ok, %{submitted: 1, skipped: 0, failed: 0}} =
             OutboxDispatcher.dispatch_once(dispatcher_options())

    assert_receive {:runner_submit, %{vault_id: submitted_vault_id}}
    assert submitted_vault_id == load_uuid(raw_other.vault_id)
    same_vault_id = fixture.vault_id
    refute_receive {:runner_submit, %{vault_id: ^same_vault_id}}
    assert_outbox_unclaimed!(same_vault_event.id)

    send(backup.pid, {gate, :continue_cut})

    assert_receive {:bundle_copy_started, ^gate, _destination, _records, inventory, _manifest,
                    %{adapter: OpaqueBackupCrypto, capability: {:opaque_backup_crypto, _}}},
                   @barrier_timeout

    assert inventory == cut.object_inventory
    refute_receive {:shared_operation_acquired, ^waiting_gate, :waiting_mutation}, 200

    send(backup.pid, {gate, :continue_copy})
    assert_receive {:bundle_seal_started, ^gate}, @barrier_timeout
    refute_receive {:shared_operation_acquired, ^waiting_gate, :waiting_mutation}, 200

    send(backup.pid, {gate, :continue_seal})
    assert_receive {:manifest_sealed, ^gate, sealed_manifest}, @barrier_timeout

    assert {:ok, ^sealed_manifest} = Task.await(backup, @barrier_timeout)
    assert sealed_manifest.status == :sealed
    assert sealed_manifest.snapshot_id == cut.snapshot_id
    assert %DateTime{} = sealed_manifest.sealed_at

    assert sealed_manifest.outbox_high_water_mark ==
             cut.outbox_high_water_mark

    assert_receive {:shared_operation_acquired, ^waiting_gate, :waiting_mutation},
                   @barrier_timeout

    send(waiting_task.pid, {waiting_gate, :release})
    assert :ok = Task.await(waiting_task, @barrier_timeout)

    assert %{bundle: %{accepted?: true, final?: true, status: :sealed}} =
             Harness.snapshot(state)

    destination_ref = sealed_manifest.destination_ref

    assert {:ok, %{accepted?: true, final?: true, status: :sealed}} =
             BarrierBundleWriter.authenticate_destination(state, destination_ref)

    assert {:ok, %{submitted: 1, skipped: 0, failed: 0}} =
             OutboxDispatcher.dispatch_once(dispatcher_options())

    assert_receive {:runner_submit, %{vault_id: ^same_vault_id}}
  end

  test "repeatable-read cut freezes rows, outbox high-water, and immutable inventory", %{
    fixture: fixture,
    other: other,
    raw_fixture: raw_fixture
  } do
    expected_inventory = seed_inventory_fixture!(fixture, other)
    initial_event = Fixtures.outbox_event!(raw_fixture)
    {state, gate, envelope} = start_harness(fixture)
    backup = tracked_task(fn -> run_backup(state, envelope) end)

    assert_receive {:backup_attempting, ^gate}
    assert_receive {:backup_cut, ^gate, cut}, @barrier_timeout

    initial_high_water = outbox_sequence!(initial_event.id)
    assert cut.transaction_isolation == :repeatable_read
    assert cut.outbox_high_water_mark == initial_high_water
    assert cut.object_inventory == expected_inventory

    late_object = insert_reachable_object!(fixture, Ecto.UUID.generate(), "late-object")
    late_event = Fixtures.outbox_event!(raw_fixture)
    assert outbox_sequence!(late_event.id) > cut.outbox_high_water_mark

    send(backup.pid, {gate, :continue_cut})

    assert_receive {:bundle_copy_started, ^gate, _destination, records, copied_inventory,
                    _manifest,
                    %{adapter: OpaqueBackupCrypto, capability: {:opaque_backup_crypto, _}}},
                   @barrier_timeout

    assert copied_inventory == expected_inventory

    refute Enum.any?(copied_inventory, fn entry ->
             entry.asset_object_id == late_object.asset_object_id
           end)

    refute Enum.any?(records, fn record ->
             record.asset_id == late_object.asset_id
           end)

    send(backup.pid, {gate, :continue_copy})
    assert_receive {:bundle_seal_started, ^gate}, @barrier_timeout
    send(backup.pid, {gate, :continue_seal})

    assert {:ok, manifest} = Task.await(backup, @barrier_timeout)
    assert manifest.status == :sealed
    assert manifest.snapshot_id == cut.snapshot_id
    assert manifest.outbox_high_water_mark == initial_high_water
    assert manifest.inventory == expected_inventory

    assert %{manifest: ^manifest, bundle: %{inventory: ^expected_inventory}} =
             Harness.snapshot(state)
  end

  test "copy and seal failures release the exclusive lock and never accept a partial bundle", %{
    fixture: fixture
  } do
    [_object] = seed_reachable_objects!(fixture, 1)

    for failure <- [:copy, :seal] do
      {state, gate, envelope} = start_harness(fixture, failure: failure)
      backup = tracked_task(fn -> run_backup(state, envelope) end)

      assert_receive {:backup_attempting, ^gate}
      assert_receive {:backup_cut, ^gate, _cut}, @barrier_timeout
      send(backup.pid, {gate, :continue_cut})

      assert_receive {:bundle_copy_started, ^gate, _destination, _records, _inventory, _manifest,
                      %{adapter: OpaqueBackupCrypto, capability: {:opaque_backup_crypto, _}}},
                     @barrier_timeout

      send(backup.pid, {gate, :continue_copy})

      if failure == :seal do
        assert_receive {:bundle_seal_started, ^gate}, @barrier_timeout
        send(backup.pid, {gate, :continue_seal})
      end

      assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
               Task.await(backup, @barrier_timeout)

      shared_after_failure =
        tracked_task(fn ->
          VaultLock.with_shared(WorkerRepo, fixture.vault_id, fn _repo ->
            send(Harness.value(state, :observer), {:shared_after_failure, failure})
            :ok
          end)
        end)

      assert_receive {:shared_after_failure, ^failure}, @barrier_timeout
      assert :ok = Task.await(shared_after_failure, @barrier_timeout)

      snapshot = Harness.snapshot(state)
      assert snapshot.manifest.status == :waiting_for_backup_key
      refute Map.has_key?(snapshot.manifest, :manifest_hash)
      refute Map.has_key?(snapshot.manifest, :manifest_tag)
      refute Map.has_key?(snapshot.manifest, :sealed_at)

      assert {:wait_for_backup_key, snapshot.manifest.id} in snapshot.events

      assert {:revoke_backup_key, snapshot.manifest.backup_key_lease_id} in snapshot.events

      assert snapshot.bundle == %{
               accepted?: false,
               final?: false,
               inventory: snapshot.bundle.inventory,
               status: :partial
             }

      assert {:error, %Error{code: :backup_invalid}} =
               BarrierBundleWriter.authenticate_destination(
                 state,
                 snapshot.manifest.destination_ref
               )

      refute :acknowledge_sealed in snapshot.events
    end
  end

  defp start_harness(fixture, options \\ []) do
    gate = make_ref()
    manifest_id = Ecto.UUID.generate()

    manifest = %{
      backup_key_lease_id: "opaque-backup-key-lease-#{manifest_id}",
      destination_ref: "backup://#{fixture.vault_id}/#{manifest_id}",
      id: manifest_id,
      kdf: %{"domain" => "singularity.backup.bundle.test.v1"},
      recovery: %{"label" => "backup_recovery", "wrapper" => :binary.copy(<<0x6B>>, 48)},
      recovery_wrapper: :binary.copy(<<0x6B>>, 48),
      status: :pending,
      vault_id: fixture.vault_id
    }

    state =
      start_supervised!(
        {Harness,
         [
           failure: Keyword.get(options, :failure),
           gate: gate,
           manifest: manifest,
           observer: self(),
           snapshot_id: Ecto.UUID.generate()
         ]},
        id: make_ref()
      )

    {state, gate, backup_envelope(fixture, manifest_id, gate)}
  end

  defp run_backup(state, envelope) do
    send(Harness.value(state, :observer), {:backup_attempting, Harness.value(state, :gate)})

    WorkerScope.run(envelope, fn worker_context ->
      context =
        Map.merge(worker_context, %{
          authorization: :test_authorization,
          authorize: AllowJobAuthorization,
          backups: {Backups, state},
          bundle_reader: Singularity.Storage.Backup.BundleReader,
          bundle_verifier: Singularity.Storage.Backup.LogicalBundleVerifier,
          bundle_writer: {BarrierBundleWriter, state},
          custodian: {OpaqueBackupCrypto, state},
          destination: {BarrierBundleWriter, state},
          exporter: {SnapshotExporter, state},
          job_progress: {JobProgress, state},
          object_storage: {SnapshotExporter, state}
        })

      apply(@backup_vault, :run, [context, envelope])
    end)
  end

  defp start_request_holder(fixture, label) do
    gate = make_ref()
    parent = self()

    task =
      tracked_task(fn ->
        send(parent, {:shared_operation_attempting, gate, label})

        OperationScope.with_shared_request(
          request_runtime(),
          session(fixture),
          %{
            classification: :private,
            required_capability: "assets.upload",
            vault_id: fixture.vault_id
          },
          fn repo ->
            assert_real_transaction!(repo)
            send(parent, {:shared_operation_acquired, gate, label})
            await_release(gate)
          end
        )
      end)

    {task, gate, label}
  end

  defp start_worker_holder(fixture, job_type, capability, label) do
    gate = make_ref()
    parent = self()
    envelope = worker_envelope(fixture, job_type, capability)

    task =
      tracked_task(fn ->
        send(parent, {:shared_operation_attempting, gate, label})

        WorkerScope.run(envelope, fn worker_context ->
          worker_context.transact.([], fn repo ->
            assert_real_transaction!(repo)
            send(parent, {:shared_operation_acquired, gate, label})
            await_release(gate)
          end)
        end)
      end)

    {task, gate, label}
  end

  defp assert_real_transaction!(repo) do
    assert %{rows: [[transaction_id]]} = query!(repo, "SELECT txid_current()", [])
    assert is_integer(transaction_id)
    :ok
  end

  defp await_release(gate) do
    receive do
      {^gate, :release} -> :ok
    after
      @barrier_timeout -> raise "shared-operation barrier timed out"
    end
  end

  defp tracked_task(callback) do
    task = Task.async(callback)

    on_exit(fn ->
      if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
    end)

    task
  end

  defp request_runtime do
    %{
      authorization: :test_authorization,
      authorization_lock: AuthorizationLock,
      authorizer: AllowJobAuthorization,
      request_repo: RequestRepo,
      scoped_repo: ScopedRepo,
      vault_lock: VaultLock
    }
  end

  defp session(fixture) do
    %{
      principal_authorization_epoch: 0,
      principal_id: fixture.principal_id,
      session_id: fixture.session_id,
      vault_authorization_epoch: 0,
      vault_id: fixture.vault_id
    }
  end

  defp backup_envelope(fixture, manifest_id, gate) do
    envelope!(fixture, %{
      job_type: "backup",
      payload: %{"pending_manifest_id" => manifest_id},
      required_capability: "backup.create",
      suffix: "backup-#{inspect(gate)}"
    })
  end

  defp worker_envelope(fixture, job_type, capability) do
    envelope!(fixture, %{
      job_type: job_type,
      payload: %{"barrier" => job_type},
      required_capability: capability,
      suffix: job_type
    })
  end

  defp envelope!(fixture, attrs) do
    {:ok, envelope} =
      JobEnvelope.new(%{
        attempt: 0,
        causation_id: Ecto.UUID.generate(),
        classification: :private,
        correlation_id: Ecto.UUID.generate(),
        expected_entity_revision: 0,
        idempotency_key: "#{attrs.suffix}:#{Ecto.UUID.generate()}",
        job_id: Ecto.UUID.generate(),
        job_type: attrs.job_type,
        payload: attrs.payload,
        principal_authorization_epoch: 0,
        principal_id: fixture.principal_id,
        required_capability: attrs.required_capability,
        vault_authorization_epoch: 0,
        vault_id: fixture.vault_id,
        version: 1
      })

    envelope
  end

  defp dispatcher_options do
    %{
      after_submit: fn _envelope, _runner_id -> :ok end,
      batch_size: 100,
      job_runner: RecordingRunner,
      job_runner_context: self(),
      lease_seconds: 60,
      outbox: Singularity.Storage.Postgres.Outbox,
      outbox_context: DispatcherRepo
    }
  end

  defp seed_inventory_fixture!(fixture, other) do
    live_objects = reachable_objects(fixture, 2)

    shared_object =
      insert_reachable_object!(fixture, Ecto.UUID.generate(), "shared-live-reference")

    _released_reference =
      insert_asset_reference!(fixture, shared_object.asset_object_id, :pending_delete)

    expected = inventory_entries(live_objects ++ [shared_object])

    _pending_delete = insert_pending_delete_object!(fixture)
    _unreferenced = insert_object!(fixture, Ecto.UUID.generate(), "unreferenced", :available)
    _deleted = insert_object!(fixture, Ecto.UUID.generate(), "deleted", :deleted)
    [_other_vault] = seed_reachable_objects!(other, 1)
    expected
  end

  defp seed_reachable_objects!(fixture, count) do
    fixture
    |> reachable_objects(count)
    |> inventory_entries()
  end

  defp reachable_objects(fixture, count) do
    Enum.map(1..count, fn index ->
      insert_reachable_object!(fixture, Ecto.UUID.generate(), "reachable-#{index}")
    end)
  end

  defp inventory_entries(objects) do
    objects
    |> Enum.sort_by(& &1.asset_object_id)
    |> Enum.with_index()
    |> Enum.map(fn {object, position} ->
      Map.put(object, :inventory_position, position)
      |> Map.drop([:asset_id])
      |> SnapshotExporter.object_record()
    end)
  end

  defp insert_reachable_object!(fixture, object_id, label) do
    object = insert_object!(fixture, object_id, label, :available)
    Map.put(object, :asset_id, insert_asset_reference!(fixture, object_id, :available))
  end

  defp insert_pending_delete_object!(fixture) do
    object_id = Ecto.UUID.generate()
    object = insert_object!(fixture, object_id, "pending-delete", :pending_delete)

    Map.put(
      object,
      :asset_id,
      insert_asset_reference!(fixture, object_id, :pending_delete)
    )
  end

  defp insert_asset_reference!(fixture, object_id, state) do
    asset_id = Ecto.UUID.generate()

    owner_query!(
      """
      INSERT INTO content.assets (
        id,
        vault_id,
        resource_version_id,
        asset_object_id,
        classification,
        state,
        state_revision
      ) VALUES ($1, $2, $3, $4, 'private', $5, 1)
      """,
      [
        Ecto.UUID.dump!(asset_id),
        Ecto.UUID.dump!(fixture.vault_id),
        Ecto.UUID.dump!(fixture.resource_version_id),
        Ecto.UUID.dump!(object_id),
        Atom.to_string(state)
      ]
    )

    asset_id
  end

  defp insert_object!(fixture, object_id, label, lifecycle) do
    key_domain_id = Ecto.UUID.generate()
    storage_ref = "backup-concurrency/#{fixture.vault_id}/#{object_id}"
    ciphertext = "ciphertext:#{label}:#{object_id}"
    ciphertext_hash = :crypto.hash(:sha256, ciphertext)
    lookup_digest = :crypto.hash(:sha256, "lookup:#{label}:#{object_id}")

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.key_domains (
          id, vault_id, classification, kind, state
        ) VALUES ($1, $2, 'private', 'content', 'active')
        """,
        [Ecto.UUID.dump!(key_domain_id), Ecto.UUID.dump!(fixture.vault_id)]
      )

      {deleted_at, deletion_evidence} =
        if lifecycle == :deleted,
          do: {DateTime.utc_now(), JSON.encode!(%{"reason" => "test_deleted"})},
          else: {nil, nil}

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_objects (
          id,
          vault_id,
          key_domain_id,
          classification,
          lookup_digest,
          ciphertext_hash,
          plaintext_byte_size,
          ciphertext_byte_size,
          storage_ref,
          format_version,
          lifecycle,
          lifecycle_revision,
          deleted_at,
          deletion_evidence
        ) VALUES (
          $1, $2, $3, 'private', $4, $5, $6, $7, $8, 1, $9, 1, $10,
          $11::text::jsonb
        )
        """,
        [
          Ecto.UUID.dump!(object_id),
          Ecto.UUID.dump!(fixture.vault_id),
          Ecto.UUID.dump!(key_domain_id),
          lookup_digest,
          ciphertext_hash,
          byte_size(ciphertext),
          byte_size(ciphertext),
          storage_ref,
          Atom.to_string(lifecycle),
          deleted_at,
          deletion_evidence
        ]
      )
    end)

    %{
      asset_object_id: object_id,
      classification: :private,
      ciphertext_byte_size: byte_size(ciphertext),
      ciphertext_hash: ciphertext_hash,
      storage_ref: storage_ref,
      vault_id: fixture.vault_id
    }
  end

  defp outbox_sequence!(event_id) do
    assert %{rows: [[sequence]]} =
             owner_query!(
               "SELECT sequence FROM core.outbox_events WHERE id = $1",
               [event_id]
             )

    sequence
  end

  defp assert_outbox_unclaimed!(event_id) do
    assert %{rows: [[nil, nil, nil]]} =
             owner_query!(
               """
               SELECT claim_token, claimed_until, delivered_at
               FROM core.outbox_events
               WHERE id = $1
               """,
               [event_id]
             )
  end

  defp mark_existing_events_delivered! do
    owner_query!(
      """
      UPDATE core.outbox_events
      SET delivered_at = CURRENT_TIMESTAMP
      WHERE delivered_at IS NULL
      """,
      []
    )
  end

  defp owner_query!(statement, parameters) do
    Fixtures.with_owner(fn -> query!(MigrationRepo, statement, parameters) end)
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value}
      when key in [
             :account_id,
             :asset_id,
             :credential_id,
             :principal_id,
             :resource_id,
             :resource_version_id,
             :session_id,
             :vault_id
           ] ->
        {key, load_uuid(value)}

      pair ->
        pair
    end)
  end

  defp load_uuid(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end
end

defmodule Singularity.Storage.BackupProgressTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Storage.Jobs.Progress

  defmodule Repo do
    def insert(%Ecto.Changeset{} = changeset, _options) do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    end
  end

  test "backup jobs persist the dedicated waiting-for-key state" do
    envelope = envelope("backup")

    assert {:ok, progress} = Progress.wait_for_backup_key(Repo, envelope)
    assert progress.submission_id == envelope.job_id
    assert progress.vault_id == envelope.vault_id
    assert progress.state == :waiting_for_backup_key

    assert {:error, %Error{code: :invalid}} =
             Progress.wait_for_backup_key(Repo, envelope("asset_verify"))
  end

  defp envelope(job_type) do
    {:ok, envelope} =
      JobEnvelope.new(%{
        version: 1,
        job_id: "00000000-0000-4000-8000-000000000831",
        job_type: job_type,
        idempotency_key: "#{job_type}:progress-test",
        vault_id: "00000000-0000-4000-8000-000000000832",
        principal_id: "00000000-0000-4000-8000-000000000833",
        required_capability: "backup.create",
        principal_authorization_epoch: 1,
        vault_authorization_epoch: 2,
        classification: :private,
        correlation_id: "00000000-0000-4000-8000-000000000834",
        causation_id: "00000000-0000-4000-8000-000000000835",
        expected_entity_revision: 0,
        attempt: 0,
        payload: %{"pending_manifest_id" => "00000000-0000-4000-8000-000000000836"}
      })

    envelope
  end
end
