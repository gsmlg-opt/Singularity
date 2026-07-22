defmodule Singularity.Runtime.AssetFailureRecoveryTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.ObjectRef
  alias Singularity.Core.StageRef
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.Assets.AcceptUpload
  alias Singularity.Runtime.Assets.Delete
  alias Singularity.Runtime.Assets.CreateUploadGrant
  alias Singularity.Runtime.Assets.UploadReconciler
  alias Singularity.Runtime.Assets.UploadSession
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.CustodyReader
  alias Singularity.Runtime.JobDispatcher
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLeaseSupervisor
  alias Singularity.Runtime.SessionContext
  alias Singularity.Runtime.UploadSessionSupervisor
  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Jobs.EnvelopeCodec
  alias Singularity.Storage.Jobs.GenericWorker
  alias Singularity.Storage.Jobs.ObanAdapter
  alias Singularity.Storage.Jobs.WorkerScope
  alias Singularity.Storage.LocalFilesystemAdapter
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.ObjectLock
  alias Singularity.Storage.Postgres.AssetDeletionRepository
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Postgres.AssetUploadRecoveryRepository
  alias Singularity.Storage.Postgres.CustodyRepository
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock

  @boundaries [
    :during_stage,
    :after_stage_sync,
    :before_database_commit,
    :after_database_commit,
    :before_finalize,
    :after_finalize,
    :before_state_ack,
    :during_delete,
    :during_cleanup
  ]

  defmodule OneShotCrashGate do
    @moduledoc false

    def child_spec([test_pid, boundary, trigger_on]) do
      %{
        id: {__MODULE__, boundary},
        start: {__MODULE__, :start_link, [test_pid, boundary, trigger_on]},
        restart: :temporary
      }
    end

    def start_link(test_pid, boundary, trigger_on \\ 1)
        when is_pid(test_pid) and
               boundary in [
                 :during_stage,
                 :after_stage_sync,
                 :before_database_commit,
                 :after_database_commit,
                 :before_finalize,
                 :after_finalize,
                 :before_state_ack,
                 :during_delete,
                 :during_cleanup
               ] and is_integer(trigger_on) and trigger_on > 0 do
      Agent.start_link(fn ->
        %{
          boundary: boundary,
          calls: 0,
          test_pid: test_pid,
          trigger_on: trigger_on,
          tripped?: false
        }
      end)
    end

    def trip(gate, evidence \\ %{}) when is_pid(gate) and is_map(evidence) do
      action =
        Agent.get_and_update(gate, fn state ->
          calls = state.calls + 1

          if not state.tripped? and calls == state.trigger_on do
            {{:trip, state.test_pid, state.boundary}, %{state | calls: calls, tripped?: true}}
          else
            {:continue, %{state | calls: calls}}
          end
        end)

      case action do
        {:trip, test_pid, boundary} ->
          send(test_pid, {:failure_boundary, boundary, self(), evidence})

          receive do
            {:continue_boundary, ^boundary} -> :ok
          end

        :continue ->
          :ok
      end
    end
  end

  defmodule AfterStageSyncWriter do
    @moduledoc false

    def stream_and_seal_stage(gate, storage, upload, stream) do
      result =
        Singularity.Storage.EncryptedStageWriter.stream_and_seal_stage(
          storage,
          upload,
          stream
        )

      if match?({:ok, _sealed}, result) do
        Singularity.Runtime.AssetFailureRecoveryTest.OneShotCrashGate.trip(
          gate,
          %{stage_ref: upload.stage_ref}
        )
      end

      result
    end
  end

  defmodule UploadCommitGate do
    @moduledoc false

    alias Singularity.Runtime.AssetFailureRecoveryTest.OneShotCrashGate
    alias Singularity.Storage.ScopedRepo

    def transact(%{boundary: :before_database_commit, gate: gate}, repo, context, callback) do
      ScopedRepo.transact(repo, context, fn scoped_repo ->
        result = callback.(scoped_repo)
        trip_after_uploaded(gate, result)
        result
      end)
    end

    def transact(%{boundary: :after_database_commit, gate: gate}, repo, context, callback) do
      result = ScopedRepo.transact(repo, context, callback)
      trip_after_uploaded(gate, result)
      result
    end

    defp trip_after_uploaded(gate, {:ok, %{asset: %{state: :uploaded}}}) do
      OneShotCrashGate.trip(gate)
    end

    defp trip_after_uploaded(_gate, _result), do: :ok
  end

  defmodule AfterFinalizeStorage do
    @moduledoc false

    alias Singularity.Runtime.AssetFailureRecoveryTest.OneShotCrashGate
    alias Singularity.Storage.LocalFilesystemAdapter

    def finalize(%{gate: gate} = context, stage_ref, object_ref) do
      result =
        LocalFilesystemAdapter.finalize(
          Map.delete(context, :gate),
          stage_ref,
          object_ref
        )

      if match?({:ok, ^object_ref}, result) do
        OneShotCrashGate.trip(gate, %{
          object_ref: object_ref,
          stage_ref: stage_ref
        })
      end

      result
    end

    def stat(context, object_ref),
      do: LocalFilesystemAdapter.stat(Map.delete(context, :gate), object_ref)

    def verify(context, object_ref),
      do: LocalFilesystemAdapter.verify(Map.delete(context, :gate), object_ref)

    def abort_stage(context, stage_ref),
      do: LocalFilesystemAdapter.abort_stage(Map.delete(context, :gate), stage_ref)
  end

  defmodule BeforeStateAckRepository do
    @moduledoc false

    alias Singularity.Runtime.AssetFailureRecoveryTest.OneShotCrashGate
    alias Singularity.Storage.Postgres.AssetRepository

    def resolve_finalization(_gate, repo, envelope),
      do: AssetRepository.resolve_finalization(repo, envelope)

    def reserve_finalization(_gate, repo, command),
      do: AssetRepository.reserve_finalization(repo, command)

    def acknowledge_finalization(gate, repo, command) do
      OneShotCrashGate.trip(gate, %{
        object_id: command.object_id,
        stage_id: command.stage_id
      })

      AssetRepository.acknowledge_finalization(repo, command)
    end
  end

  defmodule DuringDeleteRepository do
    @moduledoc false

    alias Singularity.Runtime.AssetFailureRecoveryTest.OneShotCrashGate
    alias Singularity.Storage.Postgres.AssetDeletionRepository

    def load_delete_target(_gate, repo, command),
      do: AssetDeletionRepository.load_delete_target(repo, command)

    def resolve_delete_lock_target(_gate, repo, command),
      do: AssetDeletionRepository.resolve_delete_lock_target(repo, command)

    def tombstone_and_release(gate, repo, command) do
      result = AssetDeletionRepository.tombstone_and_release(repo, command)

      if match?({:ok, %{state: :pending_delete}}, result) do
        OneShotCrashGate.trip(gate, %{asset_id: command.asset_id})
      end

      result
    end
  end

  defmodule AfterPhysicalDeleteStorage do
    @moduledoc false

    alias Singularity.Runtime.AssetFailureRecoveryTest.OneShotCrashGate
    alias Singularity.Storage.LocalFilesystemAdapter

    def delete(%{gate: gate} = context, object_ref) do
      result =
        LocalFilesystemAdapter.delete(
          Map.delete(context, :gate),
          object_ref
        )

      if result == :ok do
        OneShotCrashGate.trip(gate, %{object_ref: object_ref})
      end

      result
    end
  end

  defmodule MetadataReadGateStorage do
    @moduledoc false

    use Agent

    alias Singularity.Storage.LocalFilesystemAdapter

    def start_link(options) do
      Agent.start_link(fn ->
        %{
          completed: %{},
          owner: Keyword.fetch!(options, :owner),
          targets: Keyword.fetch!(options, :targets)
        }
      end)
    end

    def stat(context, object_ref),
      do: LocalFilesystemAdapter.stat(delegate_context(context), object_ref)

    def open(context, object_ref),
      do: LocalFilesystemAdapter.open(delegate_context(context), object_ref)

    def read_range(%{read_gate: gate} = context, handle, %Range{} = range) do
      case before_read(gate, range.first) do
        {:block, owner, token} ->
          send(owner, {:metadata_ciphertext_read_blocked, self(), token, range})

          receive do
            {:continue_metadata_ciphertext_read, ^token} -> :ok
          end

        :continue ->
          :ok
      end

      result = LocalFilesystemAdapter.read_range(delegate_context(context), handle, range)

      if match?({:ok, _bytes}, result) do
        Agent.update(gate, fn state ->
          update_in(
            state,
            [:completed],
            &Map.update(&1, range.first, 1, fn count -> count + 1 end)
          )
        end)
      end

      result
    end

    def completed(gate), do: Agent.get(gate, & &1.completed)

    defp before_read(gate, offset) do
      Agent.get_and_update(gate, fn
        %{targets: [^offset | rest]} = state ->
          token = make_ref()
          {{:block, state.owner, token}, %{state | targets: rest}}

        state ->
          {:continue, state}
      end)
    end

    defp delegate_context(context), do: Map.delete(context, :read_gate)
  end

  setup do
    %{one: raw_fixture} = Fixtures.two_vaults!()
    fixture = load_ids(raw_fixture)
    keys = install_vertical_security!(fixture)

    storage_root =
      Path.join(
        Application.fetch_env!(:singularity_storage, :storage_root),
        "asset-failure-recovery-#{Ecto.UUID.generate()}"
      )

    File.mkdir_p!(storage_root)
    on_exit(fn -> File.rm_rf!(storage_root) end)

    lease_supervisor =
      start_supervised!(
        {KeyLeaseSupervisor, name: nil},
        id: make_ref()
      )

    custody_context = %{
      key_wrapper: KeyWrapper,
      repo: WorkerRepo,
      repository_adapter: CustodyRepository,
      scope: ScopedRepo,
      storage: %{
        adapter: LocalFilesystemAdapter,
        context: %{root: storage_root}
      }
    }

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: CustodyReader,
           clock: CustodyReader,
           context: custody_context,
           idle_lock: fn _session -> :ok end,
           idle_timeout_ms: :timer.minutes(10),
           key_reader: CustodyReader,
           key_wrapper: KeyWrapper,
           lease_supervisor: lease_supervisor,
           object_key_loader: CustodyReader,
           upload_recovery: %{
             repository: {AssetUploadRecoveryRepository, WorkerRepo},
             storage: {LocalFilesystemAdapter, %{root: storage_root}},
             clock: fn -> DateTime.utc_now(:microsecond) end
           }
         }},
        id: make_ref()
      )

    upload_supervisor =
      start_supervised!(
        {UploadSessionSupervisor, name: nil, max_children: 4},
        id: make_ref()
      )

    session = session(fixture)

    assert {:ok, pending} =
             KeyCustodian.prepare_unlock(
               custodian,
               custody_session(session, keys)
             )

    assert :ok = KeyCustodian.activate_unlock(custodian, pending)

    assert {:ok, authorization} =
             AuthorizationDependencies.new(%{
               store: IdentityRepository,
               custodian: {KeyCustodian, custodian}
             })

    asset_storage = %{
      adapter: LocalFilesystemAdapter,
      context: %{root: storage_root},
      dedup_lookup: fn _vault_id, _key_domain_id, _lookup_digest ->
        :miss
      end,
      destroy_dek_wrapper: fn _wrapped_dek -> :ok end
    }

    runtime = %{
      asset_deletions: AssetDeletionRepository,
      assets: AssetRepository,
      asset_storage: asset_storage,
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      authorizer: Authorize,
      custodian: {KeyCustodian, custodian},
      object_lock: ObjectLock,
      operation_scope: Singularity.Runtime.OperationScope,
      request_repo: RequestRepo,
      scoped_repo: ScopedRepo,
      upload_session_supervisor: upload_supervisor,
      upload_supervisor: UploadSessionSupervisor,
      vault_lock: VaultLock
    }

    {:ok,
     custodian: custodian,
     fixture: fixture,
     keys: keys,
     runtime: runtime,
     session: session,
     storage_root: storage_root}
  end

  test "declares the exact Task 12 restart boundary matrix" do
    assert @boundaries == [
             :during_stage,
             :after_stage_sync,
             :before_database_commit,
             :after_database_commit,
             :before_finalize,
             :after_finalize,
             :before_state_ack,
             :during_delete,
             :during_cleanup
           ]
  end

  test "one-shot crash gate blocks exactly once at :during_stage" do
    gate = start_supervised!({OneShotCrashGate, [self(), :during_stage, 2]})

    assert :ok = OneShotCrashGate.trip(gate, %{call: 1})

    worker =
      spawn(fn ->
        OneShotCrashGate.trip(gate, %{call: 2})
      end)

    monitor = Process.monitor(worker)

    assert_receive {:failure_boundary, :during_stage, ^worker, %{call: 2}}
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    assert :ok = OneShotCrashGate.trip(gate, %{call: 3})
  end

  test "real metadata worker resumes after claim and checkpoint crashes with once-only effects",
       %{
         fixture: fixture,
         keys: keys,
         runtime: runtime,
         session: session,
         storage_root: storage_root
       } do
    jpeg = jpeg_with_sof_after_first_chunk()

    available =
      prepare_available_asset!(
        fixture,
        runtime,
        session,
        storage_root,
        :metadata_two_crash,
        jpeg,
        "image/jpeg"
      )

    envelope =
      submitted_envelope!(
        fixture,
        available.asset_id,
        "asset.metadata_requested",
        "asset_metadata"
      )

    assert {:ok, encoded} = EnvelopeCodec.encode(envelope)

    first_data_offset = Format.header_size()
    second_data_offset = Format.header_size() + Format.chunk_size() + 24

    read_gate =
      start_supervised!(
        {MetadataReadGateStorage,
         owner: self(), targets: [first_data_offset, second_data_offset]},
        id: make_ref()
      )

    crash_custodian = start_metadata_gate_custodian!(storage_root, read_gate)

    activate_custody!(crash_custodian, session, keys)

    with_generic_worker_runtime(crash_custodian, storage_root, fn ->
      job = %Oban.Job{args: encoded, attempt: 1, max_attempts: 20}
      first = Task.async(fn -> GenericWorker.perform(job) end)

      assert_receive {
                       :metadata_ciphertext_read_blocked,
                       _reader,
                       _token,
                       %Range{first: ^first_data_offset}
                     },
                     5_000

      assert %{rows: [["processing", 4, "running", "0"]]} =
               owner_query(
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   progress.state,
                   progress.checkpoint ->> 'next_chunk_index'
                 FROM content.assets AS asset
                 JOIN jobs.job_progress AS progress
                   ON progress.submission_id = $2
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(available.asset_id), Ecto.UUID.dump!(envelope.job_id)]
               )

      assert Task.shutdown(first, :brutal_kill) == nil
      revoke_and_reactivate_custody!(crash_custodian, session, keys)

      second = Task.async(fn -> GenericWorker.perform(job) end)

      assert_receive {
                       :metadata_ciphertext_read_blocked,
                       _reader,
                       _token,
                       %Range{first: ^second_data_offset}
                     },
                     5_000

      assert %{rows: [["processing", 4, "running", "1"]]} =
               owner_query(
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   progress.state,
                   progress.checkpoint ->> 'next_chunk_index'
                 FROM content.assets AS asset
                 JOIN jobs.job_progress AS progress
                   ON progress.submission_id = $2
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(available.asset_id), Ecto.UUID.dump!(envelope.job_id)]
               )

      assert Task.shutdown(second, :brutal_kill) == nil
      revoke_and_reactivate_custody!(crash_custodian, session, keys)

      assert {:ok, %{state: :ready, state_revision: 5}} = GenericWorker.perform(job)
      completed_reads = MetadataReadGateStorage.completed(read_gate)
      assert completed_reads[first_data_offset] == 1
      assert completed_reads[second_data_offset] == 1

      assert {:ok, %{state: :ready, state_revision: 5}} = GenericWorker.perform(job)
      assert MetadataReadGateStorage.completed(read_gate) == completed_reads
    end)

    assert %{rows: [["ready", 5, "completed", "2", 1, 1, 0, 0]]} =
             owner_query(
               """
               SELECT
                 asset.state,
                 asset.state_revision,
                 progress.state,
                 progress.checkpoint ->> 'next_chunk_index',
                 (SELECT count(*) FROM audit.events
                    WHERE target_id = asset.id
                      AND operation = 'asset.metadata_completed'),
                 (SELECT count(*) FROM jobs.effect_receipts
                    WHERE submission_id = $2 AND result = 'applied'),
                 (SELECT count(*) FROM jobs.effect_receipts
                    WHERE submission_id = $2 AND result = 'failed'),
                 (SELECT count(*) FROM audit.events
                    WHERE target_id = asset.id
                      AND operation = 'asset.metadata_failed')
               FROM content.assets AS asset
               JOIN jobs.job_progress AS progress
                 ON progress.submission_id = $2
               WHERE asset.id = $1
               """,
               [Ecto.UUID.dump!(available.asset_id), Ecto.UUID.dump!(envelope.job_id)]
             )
  end

  test "live authorization revocation after a metadata read prevents checkpoint CAS", %{
    fixture: fixture,
    keys: keys,
    runtime: runtime,
    session: session,
    storage_root: storage_root
  } do
    available =
      prepare_available_asset!(
        fixture,
        runtime,
        session,
        storage_root,
        :metadata_checkpoint_authorization,
        "%PDF-1.7\ncheckpoint authorization",
        "application/pdf"
      )

    envelope =
      submitted_envelope!(
        fixture,
        available.asset_id,
        "asset.metadata_requested",
        "asset_metadata"
      )

    assert {:ok, encoded} = EnvelopeCodec.encode(envelope)
    first_data_offset = Format.header_size()

    read_gate =
      start_supervised!(
        {MetadataReadGateStorage, owner: self(), targets: [first_data_offset]},
        id: make_ref()
      )

    custodian = start_metadata_gate_custodian!(storage_root, read_gate)
    activate_custody!(custodian, session, keys)

    with_generic_worker_runtime(custodian, storage_root, fn ->
      job = %Oban.Job{args: encoded, attempt: 1, max_attempts: 20}
      worker = Task.async(fn -> GenericWorker.perform(job) end)

      assert_receive {
                       :metadata_ciphertext_read_blocked,
                       reader,
                       token,
                       %Range{first: ^first_data_offset}
                     },
                     5_000

      assert %{rows: [["processing", 4, "running", "0"]]} =
               owner_query(
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   progress.state,
                   progress.checkpoint ->> 'next_chunk_index'
                 FROM content.assets AS asset
                 JOIN jobs.job_progress AS progress
                   ON progress.submission_id = $2
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(available.asset_id), Ecto.UUID.dump!(envelope.job_id)]
               )

      assert %{num_rows: 1} =
               owner_query(
                 """
                 UPDATE identity.principals
                 SET authorization_epoch = authorization_epoch + 1
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(fixture.principal_id)]
               )

      send(reader, {:continue_metadata_ciphertext_read, token})
      assert {:cancel, %{code: :job_failed}} = Task.await(worker, 5_000)

      assert MetadataReadGateStorage.completed(read_gate)[first_data_offset] == 1
    end)

    assert %{rows: [["processing", 4, "running", "0", 0, 0]]} =
             owner_query(
               """
               SELECT
                 asset.state,
                 asset.state_revision,
                 progress.state,
                 progress.checkpoint ->> 'next_chunk_index',
                 (SELECT count(*) FROM jobs.effect_receipts WHERE submission_id = $2),
                 (SELECT count(*) FROM audit.events
                    WHERE target_id = asset.id
                      AND operation IN ('asset.metadata_completed', 'asset.metadata_failed'))
               FROM content.assets AS asset
               JOIN jobs.job_progress AS progress
                 ON progress.submission_id = $2
               WHERE asset.id = $1
               """,
               [Ecto.UUID.dump!(available.asset_id), Ecto.UUID.dump!(envelope.job_id)]
             )
  end

  test ":during_stage kills a real append after the stage file is opened" do
    storage_root =
      Path.join(
        Application.fetch_env!(:singularity_storage, :storage_root),
        "failure-during-stage-#{Ecto.UUID.generate()}"
      )

    File.mkdir_p!(storage_root)
    on_exit(fn -> File.rm_rf!(storage_root) end)

    gate = start_supervised!({OneShotCrashGate, [self(), :during_stage, 2]})

    context = %{
      root: storage_root,
      filesystem_options: [
        operation_hook: fn :append_opened, paths ->
          OneShotCrashGate.trip(gate, paths)
        end
      ]
    }

    stage_ref = %StageRef{stage_id: Ecto.UUID.generate()}

    assert {:ok, ^stage_ref} =
             LocalFilesystemAdapter.stage(context, %{stage_id: stage_ref.stage_id})

    assert :ok = LocalFilesystemAdapter.append_encrypted_chunk(context, stage_ref, "header")

    writer =
      spawn(fn ->
        LocalFilesystemAdapter.append_encrypted_chunk(
          context,
          stage_ref,
          "ciphertext-fragment"
        )
      end)

    monitor = Process.monitor(writer)

    assert_receive {:failure_boundary, :during_stage, ^writer, %{path: path}}
    assert File.regular?(path)

    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}

    assert {:ok, %{byte_size: 6, sealed?: false}} =
             LocalFilesystemAdapter.stat_stage(context, stage_ref)
  end

  test ":during_stage restart abandons partial bytes and converges through a fresh grant",
       %{
         fixture: fixture,
         runtime: runtime,
         session: session,
         storage_root: storage_root
       } do
    plaintext =
      "%PDF-1.7\n" <>
        :binary.copy("A", 4_194_304) <>
        "\n%%EOF\n"

    request = upload_request(fixture, :during_stage, plaintext)
    gate = start_supervised!({OneShotCrashGate, [self(), :during_stage, 2]})

    faulting_runtime =
      put_in(
        runtime,
        [:asset_storage, :context, :filesystem_options],
        operation_hook: fn operation, paths ->
          if operation == :append_opened,
            do: OneShotCrashGate.trip(gate, paths),
            else: :ok
        end
      )

    assert {:ok, first_grant} =
             CreateUploadGrant.run(runtime, session, request)

    assert {:ok, upload} =
             AcceptUpload.begin(
               faulting_runtime,
               session,
               first_grant,
               self()
             )

    upload_monitor = Process.monitor(upload)

    append =
      Task.async(fn ->
        UploadSession.append(upload, plaintext)
      end)

    assert_receive {:failure_boundary, :during_stage, writer, %{path: partial_path}},
                   2_000

    assert writer != upload
    assert File.regular?(partial_path)

    assert {:ok, [%StageRef{} = partial_stage_ref]} =
             LocalFilesystemAdapter.list_staged(%{root: storage_root})

    Process.exit(upload, :kill)
    assert_receive {:DOWN, ^upload_monitor, :process, ^upload, :killed}
    Task.shutdown(append, :brutal_kill)

    assert_eventually(fn -> not File.exists?(partial_path) end)

    assert {:error, %Singularity.Core.Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(
               %{root: storage_root},
               partial_stage_ref
             )

    assert_eventually(fn ->
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          """
          SELECT
            stage.state,
            stage.state_revision,
            stage.failure_code,
            (
              SELECT count(*)
              FROM audit.events
              WHERE operation = 'asset.upload_abandoned'
                AND target_id = stage.asset_id
                AND metadata ->> 'stage_id' = stage.id::text
                AND metadata ->> 'failure_code' = 'runtime_restarted'
            )
          FROM content.asset_stages AS stage
          WHERE stage.id = $1
          """,
          [Ecto.UUID.dump!(partial_stage_ref.stage_id)]
        ).rows == [["abandoned", 1, "runtime_restarted", 1]]
      end)
    end)

    assert {:ok, replacement_grant} =
             CreateUploadGrant.run(runtime, session, request)

    refute replacement_grant.id == first_grant.id
    assert replacement_grant.asset_id == first_grant.asset_id
    assert replacement_grant.source_reference_id == first_grant.source_reference_id

    uploaded = complete_upload!(runtime, session, replacement_grant, plaintext)
    assert uploaded.asset.id == first_grant.asset_id

    available =
      verify_and_finalize!(
        fixture,
        runtime,
        storage_root,
        uploaded.asset.id
      )

    assert_available_convergence!(
      fixture,
      storage_root,
      request.idempotency_key,
      available.id,
      first_grant.source_reference_id,
      request.resource_version_id,
      available.asset_object_id
    )
  end

  test "custody revocation physically abandons its exact partial upload before returning",
       %{
         custodian: custodian,
         fixture: fixture,
         runtime: runtime,
         session: session,
         storage_root: storage_root
       } do
    plaintext = "%PDF-1.7\ncustody revocation partial upload\n%%EOF\n"
    request = upload_request(fixture, :custody_revoked, plaintext)

    assert {:ok, grant} =
             CreateUploadGrant.run(runtime, session, request)

    assert {:ok, upload} =
             AcceptUpload.begin(
               runtime,
               session,
               grant,
               self()
             )

    assert :ok = UploadSession.append(upload, plaintext)

    assert {:ok, [%StageRef{} = stage_ref]} =
             LocalFilesystemAdapter.list_staged(%{root: storage_root})

    assert %{worker: writer} =
             custodian
             |> :sys.get_state()
             |> get_in([:uploads, upload])

    assert is_pid(writer)

    upload_monitor = Process.monitor(upload)
    writer_monitor = Process.monitor(writer)

    assert {:ok, token} =
             KeyCustodian.begin_revoke(
               custodian,
               %{session_id: session.session_id}
             )

    assert_receive {:DOWN, ^upload_monitor, :process, ^upload, _reason}
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, _reason}

    assert {:error, %Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(
               %{root: storage_root},
               stage_ref
             )

    Fixtures.with_owner(fn ->
      assert %{rows: [["abandoned", 1, "custody_revoked", 1]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   stage.state,
                   stage.state_revision,
                   stage.failure_code,
                   (
                     SELECT count(*)
                     FROM audit.events
                     WHERE operation = 'asset.upload_abandoned'
                       AND target_id = stage.asset_id
                       AND metadata ->> 'failure_code' = 'custody_revoked'
                   )
                 FROM content.asset_stages AS stage
                 WHERE stage.id = $1
                 """,
                 [Ecto.UUID.dump!(stage_ref.stage_id)]
               )
    end)

    assert :ok = KeyCustodian.finish_revoke(custodian, token)
  end

  test ":after_stage_sync restart removes a sealed uncommitted stage and converges",
       %{
         fixture: fixture,
         runtime: runtime,
         session: session,
         storage_root: storage_root
       } do
    plaintext = "%PDF-1.7\nafter stage sync recovery\n%%EOF\n"
    request = upload_request(fixture, :after_stage_sync, plaintext)
    gate = start_supervised!({OneShotCrashGate, [self(), :after_stage_sync, 1]})
    faulting_runtime = Map.put(runtime, :stage_writer, {AfterStageSyncWriter, gate})

    assert {:ok, first_grant} =
             CreateUploadGrant.run(runtime, session, request)

    assert {:ok, upload} =
             AcceptUpload.begin(
               faulting_runtime,
               session,
               first_grant,
               self()
             )

    upload_monitor = Process.monitor(upload)
    assert :ok = UploadSession.append(upload, plaintext)
    finish = Task.async(fn -> UploadSession.finish(upload) end)

    assert_receive {:failure_boundary, :after_stage_sync, writer,
                    %{stage_ref: %StageRef{} = stage_ref}},
                   2_000

    assert writer != upload

    assert {:ok, %{sealed?: true}} =
             LocalFilesystemAdapter.stat_stage(%{root: storage_root}, stage_ref)

    assert_upload_state!(first_grant.asset_id, "staging", 0, "open", 0)

    Process.exit(upload, :kill)
    assert_receive {:DOWN, ^upload_monitor, :process, ^upload, :killed}
    Task.shutdown(finish, :brutal_kill)

    recover_abandoned_upload!(
      fixture,
      runtime,
      session,
      storage_root,
      request,
      plaintext,
      first_grant,
      stage_ref
    )
  end

  test ":before_database_commit restart rolls back the sealed checkpoint and converges",
       %{
         fixture: fixture,
         runtime: runtime,
         session: session,
         storage_root: storage_root
       } do
    plaintext = "%PDF-1.7\nbefore database commit recovery\n%%EOF\n"
    request = upload_request(fixture, :before_database_commit, plaintext)
    gate = start_supervised!({OneShotCrashGate, [self(), :before_database_commit, 1]})

    faulting_runtime =
      Map.put(
        runtime,
        :scoped_repo,
        {UploadCommitGate, %{boundary: :before_database_commit, gate: gate}}
      )

    assert {:ok, first_grant} =
             CreateUploadGrant.run(runtime, session, request)

    assert {:ok, upload} =
             AcceptUpload.begin(
               faulting_runtime,
               session,
               first_grant,
               self()
             )

    upload_monitor = Process.monitor(upload)
    assert :ok = UploadSession.append(upload, plaintext)
    finish = Task.async(fn -> UploadSession.finish(upload) end)

    assert_receive {:failure_boundary, :before_database_commit, ^upload, %{}},
                   2_000

    assert {:ok, [%StageRef{} = stage_ref]} =
             LocalFilesystemAdapter.list_staged(%{root: storage_root})

    assert {:ok, %{sealed?: true}} =
             LocalFilesystemAdapter.stat_stage(%{root: storage_root}, stage_ref)

    assert_upload_state!(first_grant.asset_id, "staging", 0, "open", 0)

    Process.exit(upload, :kill)
    assert_receive {:DOWN, ^upload_monitor, :process, ^upload, :killed}
    Task.shutdown(finish, :brutal_kill)

    recover_abandoned_upload!(
      fixture,
      runtime,
      session,
      storage_root,
      request,
      plaintext,
      first_grant,
      stage_ref
    )
  end

  test ":after_database_commit restart preserves the sealed checkpoint and converges",
       %{
         fixture: fixture,
         runtime: runtime,
         session: session,
         storage_root: storage_root
       } do
    plaintext = "%PDF-1.7\nafter database commit recovery\n%%EOF\n"
    request = upload_request(fixture, :after_database_commit, plaintext)
    gate = start_supervised!({OneShotCrashGate, [self(), :after_database_commit, 1]})

    faulting_runtime =
      Map.put(
        runtime,
        :scoped_repo,
        {UploadCommitGate, %{boundary: :after_database_commit, gate: gate}}
      )

    assert {:ok, grant} =
             CreateUploadGrant.run(runtime, session, request)

    assert {:ok, upload} =
             AcceptUpload.begin(
               faulting_runtime,
               session,
               grant,
               self()
             )

    upload_monitor = Process.monitor(upload)
    assert :ok = UploadSession.append(upload, plaintext)
    finish = Task.async(fn -> UploadSession.finish(upload) end)

    assert_receive {:failure_boundary, :after_database_commit, ^upload, %{}},
                   2_000

    assert {:ok, [%StageRef{}]} =
             LocalFilesystemAdapter.list_staged(%{root: storage_root})

    assert_upload_state!(grant.asset_id, "uploaded", 1, "sealed", 1)

    Process.exit(upload, :kill)
    assert_receive {:DOWN, ^upload_monitor, :process, ^upload, :killed}
    Task.shutdown(finish, :brutal_kill)

    assert {:ok, 0} =
             UploadReconciler.run(%{
               repository: {AssetUploadRecoveryRepository, WorkerRepo},
               storage: {LocalFilesystemAdapter, %{root: storage_root}},
               clock: fn -> DateTime.utc_now(:microsecond) end
             })

    assert {:error, %Singularity.Core.Error{code: :conflict}} =
             CreateUploadGrant.run(runtime, session, request)

    available =
      verify_and_finalize!(
        fixture,
        runtime,
        storage_root,
        grant.asset_id
      )

    assert_available_convergence!(
      fixture,
      storage_root,
      request.idempotency_key,
      available.id,
      grant.source_reference_id,
      request.resource_version_id,
      available.asset_object_id
    )
  end

  test ":before_finalize restart replays the durable reservation before publication",
       %{
         fixture: fixture,
         runtime: runtime,
         session: session,
         storage_root: storage_root
       } do
    plaintext = "%PDF-1.7\nbefore finalize recovery\n%%EOF\n"
    request = upload_request(fixture, :before_finalize, plaintext)

    {grant, uploaded, finalize} =
      prepare_verified_asset!(
        fixture,
        runtime,
        session,
        storage_root,
        request,
        plaintext
      )

    gate = start_supervised!({OneShotCrashGate, [self(), :before_finalize, 1]})

    storage = {
      LocalFilesystemAdapter,
      %{
        root: storage_root,
        filesystem_options: [
          operation_hook: fn operation, paths ->
            if operation == :before_publish,
              do: OneShotCrashGate.trip(gate, paths),
              else: :ok
          end
        ]
      }
    }

    worker =
      spawn(fn ->
        run_job(finalize, runtime, storage_root, %{storage: storage})
      end)

    monitor = Process.monitor(worker)

    assert_receive {:failure_boundary, :before_finalize, ^worker,
                    %{destination: destination, source: source}},
                   2_000

    assert File.regular?(source)
    refute File.exists?(destination)

    assert_finalization_reservation!(
      grant.asset_id,
      uploaded.stage.id,
      "verified",
      "sealed",
      "staged"
    )

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    assert {:ok, available} =
             run_job(finalize, runtime, storage_root)

    assert_available_convergence!(
      fixture,
      storage_root,
      request.idempotency_key,
      available.id,
      grant.source_reference_id,
      request.resource_version_id,
      available.asset_object_id
    )
  end

  test ":after_finalize restart replays publication from the durable receipt",
       %{
         fixture: fixture,
         runtime: runtime,
         session: session,
         storage_root: storage_root
       } do
    plaintext = "%PDF-1.7\nafter finalize recovery\n%%EOF\n"
    request = upload_request(fixture, :after_finalize, plaintext)

    {grant, uploaded, finalize} =
      prepare_verified_asset!(
        fixture,
        runtime,
        session,
        storage_root,
        request,
        plaintext
      )

    gate = start_supervised!({OneShotCrashGate, [self(), :after_finalize, 1]})

    worker =
      spawn(fn ->
        run_job(finalize, runtime, storage_root, %{
          storage: {AfterFinalizeStorage, %{root: storage_root, gate: gate}}
        })
      end)

    monitor = Process.monitor(worker)

    assert_receive {:failure_boundary, :after_finalize, ^worker,
                    %{
                      object_ref: %ObjectRef{} = object_ref,
                      stage_ref: %StageRef{} = stage_ref
                    }},
                   2_000

    assert {:error, %Singularity.Core.Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(
               %{root: storage_root},
               stage_ref
             )

    assert {:ok, %{byte_size: byte_size}} =
             LocalFilesystemAdapter.stat(
               object_storage_context!(object_ref.object_id, storage_root),
               object_ref
             )

    assert byte_size > 0

    assert_finalization_reservation!(
      grant.asset_id,
      uploaded.stage.id,
      "verified",
      "sealed",
      "staged"
    )

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    assert {:ok, available} =
             run_job(finalize, runtime, storage_root)

    assert available.asset_object_id == object_ref.object_id

    assert_available_convergence!(
      fixture,
      storage_root,
      request.idempotency_key,
      available.id,
      grant.source_reference_id,
      request.resource_version_id,
      available.asset_object_id
    )
  end

  test ":before_state_ack restart acknowledges an already published canonical object once",
       %{
         fixture: fixture,
         runtime: runtime,
         session: session,
         storage_root: storage_root
       } do
    plaintext = "%PDF-1.7\nbefore state ack recovery\n%%EOF\n"
    request = upload_request(fixture, :before_state_ack, plaintext)

    {grant, uploaded, finalize} =
      prepare_verified_asset!(
        fixture,
        runtime,
        session,
        storage_root,
        request,
        plaintext
      )

    gate = start_supervised!({OneShotCrashGate, [self(), :before_state_ack, 1]})

    worker =
      spawn(fn ->
        run_job(finalize, runtime, storage_root, %{
          assets: {BeforeStateAckRepository, gate}
        })
      end)

    monitor = Process.monitor(worker)

    assert_receive {:failure_boundary, :before_state_ack, ^worker,
                    %{object_id: object_id, stage_id: stage_id}},
                   2_000

    assert stage_id == uploaded.stage.id

    assert {:ok, %{byte_size: byte_size}} =
             LocalFilesystemAdapter.stat(
               object_storage_context!(object_id, storage_root),
               %ObjectRef{object_id: object_id}
             )

    assert byte_size > 0

    assert_finalization_reservation!(
      grant.asset_id,
      uploaded.stage.id,
      "verified",
      "sealed",
      "staged"
    )

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    assert {:ok, available} =
             run_job(finalize, runtime, storage_root)

    assert available.asset_object_id == object_id

    assert_available_convergence!(
      fixture,
      storage_root,
      request.idempotency_key,
      available.id,
      grant.source_reference_id,
      request.resource_version_id,
      available.asset_object_id
    )
  end

  test "Delete waits for :after_finalize acknowledgement before taking the asset row",
       %{
         fixture: fixture,
         runtime: runtime,
         session: session,
         storage_root: storage_root
       } do
    plaintext = "%PDF-1.7\nserialized finalize delete\n%%EOF\n"
    request = upload_request(fixture, :after_finalize, plaintext)

    {grant, uploaded, finalize} =
      prepare_verified_asset!(
        fixture,
        runtime,
        session,
        storage_root,
        request,
        plaintext
      )

    gate = start_supervised!({OneShotCrashGate, [self(), :after_finalize, 1]})

    finalization =
      Task.async(fn ->
        run_job(finalize, runtime, storage_root, %{
          storage: {AfterFinalizeStorage, %{root: storage_root, gate: gate}}
        })
      end)

    assert_receive {:failure_boundary, :after_finalize, finalizer,
                    %{object_ref: %ObjectRef{object_id: object_id}}},
                   2_000

    deletion =
      Task.async(fn ->
        Delete.run(runtime, session, grant.asset_id, 3)
      end)

    assert Task.yield(deletion, 100) == nil

    assert_finalization_reservation!(
      grant.asset_id,
      uploaded.stage.id,
      "verified",
      "sealed",
      "staged"
    )

    send(finalizer, {:continue_boundary, :after_finalize})

    assert {:ok, %{state: :available, state_revision: 3}} =
             Task.await(finalization, 5_000)

    assert {:ok, %{state: :pending_delete, state_revision: 4}} =
             Task.await(deletion, 5_000)

    Fixtures.with_owner(fn ->
      assert %{rows: [["pending_delete", 4, "finalized", "available", 0, 1]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   stage.state,
                   object.lifecycle,
                   (
                     SELECT count(*)
                     FROM content.asset_objects
                     WHERE vault_id = asset.vault_id
                       AND lifecycle = 'staged'
                   ),
                   (
                     SELECT count(*)
                     FROM content.assets
                     WHERE asset_object_id = object.id
                       AND vault_id = object.vault_id
                   )
                 FROM content.assets AS asset
                 JOIN content.asset_stages AS stage
                   ON stage.id = $2
                  AND stage.vault_id = asset.vault_id
                 JOIN content.asset_objects AS object
                   ON object.id = $3
                  AND object.vault_id = asset.vault_id
                 WHERE asset.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(grant.asset_id),
                   Ecto.UUID.dump!(uploaded.stage.id),
                   Ecto.UUID.dump!(object_id)
                 ]
               )
    end)

    assert length(physical_object_files(storage_root)) == 1
  end

  test ":during_delete restart rolls back the outer request and converges with one live sentinel",
       %{
         fixture: fixture,
         runtime: runtime,
         session: session,
         storage_root: storage_root
       } do
    sentinel =
      prepare_available_asset!(
        fixture,
        runtime,
        session,
        storage_root,
        :during_delete_sentinel,
        "%PDF-1.7\ndelete sentinel\n%%EOF\n"
      )

    disposable =
      prepare_available_asset!(
        fixture,
        runtime,
        session,
        storage_root,
        :during_delete,
        "%PDF-1.7\nduring delete target\n%%EOF\n"
      )

    gate = start_supervised!({OneShotCrashGate, [self(), :during_delete, 1]})
    faulting_runtime = Map.put(runtime, :asset_deletions, {DuringDeleteRepository, gate})

    worker =
      spawn(fn ->
        Delete.run(
          faulting_runtime,
          session,
          disposable.asset_id,
          3
        )
      end)

    monitor = Process.monitor(worker)

    assert_receive {:failure_boundary, :during_delete, ^worker, %{asset_id: disposable_asset_id}},
                   2_000

    assert disposable_asset_id == disposable.asset_id

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    assert_asset_delete_state!(disposable.asset_id, "available", 3, nil)

    complete_delete!(
      fixture,
      runtime,
      session,
      storage_root,
      disposable
    )

    assert_delete_convergence!(
      fixture,
      storage_root,
      sentinel,
      disposable
    )
  end

  test ":during_cleanup restart replays a durable claim after physical bytes are gone",
       %{
         fixture: fixture,
         runtime: runtime,
         session: session,
         storage_root: storage_root
       } do
    sentinel =
      prepare_available_asset!(
        fixture,
        runtime,
        session,
        storage_root,
        :during_cleanup_sentinel,
        "%PDF-1.7\ncleanup sentinel\n%%EOF\n"
      )

    disposable =
      prepare_available_asset!(
        fixture,
        runtime,
        session,
        storage_root,
        :during_cleanup,
        "%PDF-1.7\nduring cleanup target\n%%EOF\n"
      )

    object_cleanup =
      prepare_logically_deleted_asset!(
        fixture,
        runtime,
        session,
        storage_root,
        disposable
      )

    gate = start_supervised!({OneShotCrashGate, [self(), :during_cleanup, 1]})

    worker =
      spawn(fn ->
        run_job(object_cleanup, runtime, storage_root, %{
          storage: {AfterPhysicalDeleteStorage, %{root: storage_root, gate: gate}}
        })
      end)

    monitor = Process.monitor(worker)

    assert_receive {:failure_boundary, :during_cleanup, ^worker,
                    %{object_ref: %ObjectRef{object_id: object_id}}},
                   2_000

    assert object_id == disposable.object_id

    assert_object_cleanup_state!(
      disposable,
      storage_root,
      "deleting",
      false
    )

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    assert {:ok, %{lifecycle: :deleted}} =
             run_job(object_cleanup, runtime, storage_root)

    assert_delete_convergence!(
      fixture,
      storage_root,
      sentinel,
      disposable
    )
  end

  defp upload_request(
         fixture,
         boundary,
         plaintext,
         declared_media_type \\ "application/pdf"
       ) do
    extension = if declared_media_type == "image/jpeg", do: "jpg", else: "pdf"

    %{
      classification: :private,
      declared_media_type: declared_media_type,
      filename: "#{boundary}-recovery.#{extension}",
      idempotency_key: "asset-recovery:#{boundary}:#{Ecto.UUID.generate()}",
      resource_version_id: fixture.resource_version_id,
      size: byte_size(plaintext)
    }
  end

  defp recover_abandoned_upload!(
         fixture,
         runtime,
         session,
         storage_root,
         request,
         plaintext,
         first_grant,
         stage_ref
       ) do
    assert_eventually(fn ->
      match?(
        {:error, %Error{code: :not_found}},
        LocalFilesystemAdapter.stat_stage(
          %{root: storage_root},
          stage_ref
        )
      )
    end)

    assert_eventually(fn ->
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          """
          SELECT
            stage.state,
            stage.state_revision,
            stage.failure_code,
            (
              SELECT count(*)
              FROM audit.events
              WHERE operation = 'asset.upload_abandoned'
                AND target_id = stage.asset_id
                AND metadata ->> 'stage_id' = stage.id::text
                AND metadata ->> 'failure_code' = 'runtime_restarted'
            )
          FROM content.asset_stages AS stage
          WHERE stage.id = $1
          """,
          [Ecto.UUID.dump!(stage_ref.stage_id)]
        ).rows == [["abandoned", 1, "runtime_restarted", 1]]
      end)
    end)

    assert {:ok, 0} =
             UploadReconciler.run(%{
               repository: {AssetUploadRecoveryRepository, WorkerRepo},
               storage: {LocalFilesystemAdapter, %{root: storage_root}},
               clock: fn -> DateTime.utc_now(:microsecond) end
             })

    assert {:error, %Singularity.Core.Error{code: :not_found}} =
             LocalFilesystemAdapter.stat_stage(
               %{root: storage_root},
               stage_ref
             )

    assert_upload_state!(
      first_grant.asset_id,
      "staging",
      0,
      "abandoned",
      1
    )

    assert {:ok, replacement_grant} =
             CreateUploadGrant.run(runtime, session, request)

    refute replacement_grant.id == first_grant.id
    assert replacement_grant.asset_id == first_grant.asset_id
    assert replacement_grant.source_reference_id == first_grant.source_reference_id

    uploaded = complete_upload!(runtime, session, replacement_grant, plaintext)
    assert uploaded.asset.id == first_grant.asset_id

    available =
      verify_and_finalize!(
        fixture,
        runtime,
        storage_root,
        uploaded.asset.id
      )

    assert_available_convergence!(
      fixture,
      storage_root,
      request.idempotency_key,
      available.id,
      first_grant.source_reference_id,
      request.resource_version_id,
      available.asset_object_id
    )

    available
  end

  defp prepare_verified_asset!(
         fixture,
         runtime,
         session,
         storage_root,
         request,
         plaintext
       ) do
    assert {:ok, grant} =
             CreateUploadGrant.run(runtime, session, request)

    uploaded = complete_upload!(runtime, session, grant, plaintext)

    verify =
      submitted_envelope!(
        fixture,
        grant.asset_id,
        "asset.verify_requested",
        "asset_verify"
      )

    assert {:ok, %{state: :verified, state_revision: 2}} =
             run_job(verify, runtime, storage_root)

    finalize =
      submitted_envelope!(
        fixture,
        grant.asset_id,
        "asset.finalize_requested",
        "asset_finalize"
      )

    {grant, uploaded, finalize}
  end

  defp prepare_available_asset!(
         fixture,
         runtime,
         session,
         storage_root,
         boundary,
         plaintext,
         declared_media_type \\ "application/pdf"
       ) do
    request = upload_request(fixture, boundary, plaintext, declared_media_type)

    {grant, uploaded, finalize} =
      prepare_verified_asset!(
        fixture,
        runtime,
        session,
        storage_root,
        request,
        plaintext
      )

    assert {:ok,
            %{
              id: asset_id,
              asset_object_id: object_id,
              state: :available,
              state_revision: 3
            }} =
             run_job(finalize, runtime, storage_root)

    assert asset_id == grant.asset_id

    %{
      asset_id: asset_id,
      finalize: finalize,
      grant: grant,
      object_id: object_id,
      request: request,
      stage_id: uploaded.stage.id
    }
  end

  defp prepare_logically_deleted_asset!(
         fixture,
         runtime,
         session,
         storage_root,
         disposable
       ) do
    assert {:ok, %{state: :pending_delete, state_revision: 4}} =
             Delete.run(
               runtime,
               session,
               disposable.asset_id,
               3
             )

    cleanup =
      submitted_envelope!(
        fixture,
        disposable.asset_id,
        "asset.cleanup_requested",
        "asset_cleanup"
      )

    assert {:ok,
            %{
              asset_object_id: nil,
              state: :deleted,
              state_revision: 5
            }} =
             run_job(cleanup, runtime, storage_root)

    submitted_envelope!(
      fixture,
      disposable.asset_id,
      "object.cleanup_requested",
      "object_cleanup"
    )
  end

  defp complete_delete!(
         fixture,
         runtime,
         session,
         storage_root,
         disposable
       ) do
    object_cleanup =
      prepare_logically_deleted_asset!(
        fixture,
        runtime,
        session,
        storage_root,
        disposable
      )

    assert {:ok, %{lifecycle: :deleted}} =
             run_job(object_cleanup, runtime, storage_root)

    object_cleanup
  end

  defp assert_asset_delete_state!(
         asset_id,
         state,
         revision,
         released_at
       ) do
    Fixtures.with_owner(fn ->
      assert %{rows: [[^state, ^revision, observed_released_at]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   resource_asset.released_at
                 FROM content.assets AS asset
                 JOIN content.resource_assets AS resource_asset
                   ON resource_asset.asset_id = asset.id
                  AND resource_asset.vault_id = asset.vault_id
                 WHERE asset.id = $1
                 """,
                 [Ecto.UUID.dump!(asset_id)]
               )

      assert observed_released_at == released_at
    end)
  end

  defp assert_object_cleanup_state!(
         disposable,
         storage_root,
         lifecycle,
         file_exists?
       ) do
    Fixtures.with_owner(fn ->
      assert %{rows: [["deleted", nil, ^lifecycle, claim_token]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   asset.state,
                   asset.asset_object_id,
                   object.lifecycle,
                   object.delete_claim_token
                 FROM content.assets AS asset
                 JOIN content.asset_objects AS object
                   ON object.id = $2
                  AND object.vault_id = asset.vault_id
                 WHERE asset.id = $1
                 """,
                 [
                   Ecto.UUID.dump!(disposable.asset_id),
                   Ecto.UUID.dump!(disposable.object_id)
                 ]
               )

      assert is_binary(claim_token)
    end)

    context =
      object_storage_context!(
        disposable.object_id,
        storage_root
      )

    exists? =
      match?(
        {:ok, _stat},
        LocalFilesystemAdapter.stat(
          context,
          %ObjectRef{object_id: disposable.object_id}
        )
      )

    assert exists? == file_exists?
  end

  defp assert_delete_convergence!(
         fixture,
         storage_root,
         sentinel,
         disposable
       ) do
    Fixtures.with_owner(fn ->
      assert %{
               rows: [
                 [
                   2,
                   true,
                   2,
                   1,
                   true,
                   1,
                   "available",
                   "deleted",
                   nil,
                   "available",
                   "deleted",
                   0
                 ]
               ]
             } =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   count(DISTINCT asset.id),
                   bool_and(asset.resource_version_id = $6),
                   count(resource_asset.asset_id),
                   count(*) FILTER (
                     WHERE resource_asset.released_at IS NULL
                   ),
                   bool_and(
                     CASE
                       WHEN asset.id = $1 THEN asset.asset_object_id = $3
                       WHEN asset.id = $2 THEN asset.asset_object_id IS NULL
                       ELSE false
                     END
                   ),
                   (
                     SELECT count(*)
                     FROM content.assets AS live_asset
                     WHERE live_asset.asset_object_id = $3
                       AND live_asset.vault_id = $5
                   ),
                   max(asset.state) FILTER (
                     WHERE asset.id = $1
                   ),
                   max(asset.state) FILTER (
                     WHERE asset.id = $2
                   ),
                   (
                     SELECT asset_object_id
                     FROM content.assets
                     WHERE id = $2
                   ),
                   (
                     SELECT lifecycle
                     FROM content.asset_objects
                     WHERE id = $3
                   ),
                   (
                     SELECT lifecycle
                     FROM content.asset_objects
                     WHERE id = $4
                   ),
                   (
                     SELECT count(*)
                     FROM content.asset_objects
                     WHERE vault_id = $5
                       AND lifecycle = 'staged'
                   )
                 FROM content.assets AS asset
                 LEFT JOIN content.resource_assets AS resource_asset
                   ON resource_asset.asset_id = asset.id
                  AND resource_asset.vault_id = asset.vault_id
                  AND resource_asset.resource_version_id = $6
                 WHERE asset.id IN ($1, $2)
                 """,
                 [
                   Ecto.UUID.dump!(sentinel.asset_id),
                   Ecto.UUID.dump!(disposable.asset_id),
                   Ecto.UUID.dump!(sentinel.object_id),
                   Ecto.UUID.dump!(disposable.object_id),
                   Ecto.UUID.dump!(fixture.vault_id),
                   Ecto.UUID.dump!(fixture.resource_version_id)
                 ]
               )
    end)

    assert {:ok, %{byte_size: sentinel_size}} =
             LocalFilesystemAdapter.stat(
               object_storage_context!(
                 sentinel.object_id,
                 storage_root
               ),
               %ObjectRef{object_id: sentinel.object_id}
             )

    assert sentinel_size > 0

    assert {:error, %Singularity.Core.Error{code: :not_found}} =
             LocalFilesystemAdapter.stat(
               object_storage_context!(
                 disposable.object_id,
                 storage_root
               ),
               %ObjectRef{object_id: disposable.object_id}
             )

    assert {:ok, []} =
             LocalFilesystemAdapter.list_staged(%{root: storage_root})

    assert length(physical_object_files(storage_root)) == 1
  end

  defp physical_object_files(storage_root) do
    storage_root
    |> Path.join("objects/**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end

  defp assert_finalization_reservation!(
         asset_id,
         stage_id,
         asset_state,
         stage_state,
         object_lifecycle
       ) do
    Fixtures.with_owner(fn ->
      assert %{
               rows: [
                 [
                   ^asset_state,
                   2,
                   nil,
                   ^stage_state,
                   1,
                   ^object_lifecycle,
                   0,
                   1
                 ]
               ]
             } =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   asset.asset_object_id,
                   stage.state,
                   stage.state_revision,
                   object.lifecycle,
                   object.lifecycle_revision,
                   (
                     SELECT count(*)
                     FROM content.asset_key_envelopes
                     WHERE asset_object_id = object.id
                       AND vault_id = object.vault_id
                   )
                 FROM content.assets AS asset
                 JOIN content.asset_stages AS stage
                   ON stage.asset_id = asset.id
                  AND stage.vault_id = asset.vault_id
                 JOIN content.asset_objects AS object
                   ON object.id = stage.candidate_object_id
                  AND object.vault_id = stage.vault_id
                 WHERE asset.id = $1
                   AND stage.id = $2
                 """,
                 [
                   Ecto.UUID.dump!(asset_id),
                   Ecto.UUID.dump!(stage_id)
                 ]
               )
    end)
  end

  defp assert_upload_state!(
         asset_id,
         asset_state,
         asset_revision,
         stage_state,
         stage_revision
       ) do
    Fixtures.with_owner(fn ->
      assert %{rows: [[^asset_state, ^asset_revision, ^stage_state, ^stage_revision]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   stage.state,
                   stage.state_revision
                 FROM content.assets AS asset
                 JOIN content.asset_stages AS stage
                   ON stage.asset_id = asset.id
                  AND stage.vault_id = asset.vault_id
                 WHERE asset.id = $1
                 ORDER BY stage.inserted_at DESC, stage.id DESC
                 LIMIT 1
                 """,
                 [Ecto.UUID.dump!(asset_id)]
               )
    end)
  end

  defp assert_eventually(callback, attempts \\ 500)

  defp assert_eventually(callback, attempts) when attempts > 0 do
    if callback.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(callback, attempts - 1)
    end
  end

  defp assert_eventually(_callback, 0),
    do: flunk("condition did not become true")

  defp complete_upload!(runtime, session, grant, plaintext) do
    assert {:ok, upload} =
             AcceptUpload.begin(runtime, session, grant, self())

    assert :ok = UploadSession.append(upload, plaintext)

    assert {:ok,
            %{
              asset: %{state: :uploaded, state_revision: 1},
              stage: %{state: :sealed, state_revision: 1}
            } = uploaded} = UploadSession.finish(upload)

    uploaded
  end

  defp activate_custody!(custodian, session, keys) do
    assert {:ok, pending} =
             KeyCustodian.prepare_unlock(
               custodian,
               custody_session(session, keys)
             )

    assert :ok = KeyCustodian.activate_unlock(custodian, pending)
  end

  defp revoke_and_reactivate_custody!(custodian, session, keys) do
    assert {:ok, token} =
             KeyCustodian.begin_revoke(custodian, %{session_id: session.session_id})

    assert :ok = KeyCustodian.finish_revoke(custodian, token)
    activate_custody!(custodian, session, keys)
  end

  defp start_metadata_gate_custodian!(storage_root, read_gate) do
    lease_supervisor =
      start_supervised!(
        {KeyLeaseSupervisor, name: nil},
        id: make_ref()
      )

    start_supervised!(
      {KeyCustodian,
       %{
         authorization: CustodyReader,
         clock: CustodyReader,
         context: %{
           key_wrapper: KeyWrapper,
           repo: WorkerRepo,
           repository_adapter: CustodyRepository,
           scope: ScopedRepo,
           storage: %{
             adapter: MetadataReadGateStorage,
             context: %{root: storage_root, read_gate: read_gate}
           }
         },
         idle_lock: fn _session -> :ok end,
         idle_timeout_ms: :timer.minutes(10),
         key_reader: CustodyReader,
         key_wrapper: KeyWrapper,
         lease_supervisor: lease_supervisor,
         object_key_loader: CustodyReader
       }},
      id: make_ref()
    )
  end

  defp with_generic_worker_runtime(custodian, storage_root, callback) do
    previous_handler = Application.get_env(:singularity_storage, :job_handler)
    previous_root = Application.fetch_env!(:singularity_storage, :storage_root)

    previous_authorization =
      Application.fetch_env!(:singularity_runtime, :authorization_dependencies)

    Application.put_env(:singularity_storage, :job_handler, JobDispatcher)
    Application.put_env(:singularity_storage, :storage_root, storage_root)

    Application.put_env(:singularity_runtime, :authorization_dependencies, %{
      store: IdentityRepository,
      custodian: {KeyCustodian, custodian}
    })

    try do
      callback.()
    after
      Application.put_env(:singularity_storage, :storage_root, previous_root)

      Application.put_env(
        :singularity_runtime,
        :authorization_dependencies,
        previous_authorization
      )

      if previous_handler do
        Application.put_env(:singularity_storage, :job_handler, previous_handler)
      else
        Application.delete_env(:singularity_storage, :job_handler)
      end
    end
  end

  defp jpeg_with_sof_after_first_chunk do
    segment =
      <<0xFF, 0xE0, 65_535::unsigned-big-16>> <>
        :binary.copy(<<0>>, 65_533)

    sof =
      <<0xFF, 0xC0, 11::unsigned-big-16, 8, 2::unsigned-big-16, 3::unsigned-big-16, 1, 1, 0x11,
        0>>

    <<0xFF, 0xD8>> <> :binary.copy(segment, 64) <> sof
  end

  defp verify_and_finalize!(
         fixture,
         runtime,
         storage_root,
         asset_id
       ) do
    verify =
      submitted_envelope!(
        fixture,
        asset_id,
        "asset.verify_requested",
        "asset_verify"
      )

    assert {:ok, %{state: :verified, state_revision: 2}} =
             run_job(verify, runtime, storage_root)

    finalize =
      submitted_envelope!(
        fixture,
        asset_id,
        "asset.finalize_requested",
        "asset_finalize"
      )

    assert {:ok,
            %{
              id: ^asset_id,
              asset_object_id: object_id,
              state: :available,
              state_revision: 3
            } = available} =
             run_job(finalize, runtime, storage_root)

    assert is_binary(object_id)
    available
  end

  defp run_job(envelope, runtime, storage_root, overrides \\ %{}) do
    WorkerScope.run(envelope, fn worker_context ->
      context =
        Map.merge(worker_context, %{
          asset_deletions: AssetDeletionRepository,
          assets: AssetRepository,
          authorization: runtime.authorization,
          authorize: Authorize,
          object_lock: ObjectLock,
          storage: {LocalFilesystemAdapter, %{root: storage_root}}
        })

      context
      |> Map.merge(overrides)
      |> JobDispatcher.handle(envelope)
    end)
  end

  defp submitted_envelope!(
         fixture,
         asset_id,
         event_type,
         job_type
       ) do
    envelope =
      scoped(fixture, fn repo ->
        assert %{
                 rows: [
                   [
                     id,
                     idempotency_key,
                     vault_id,
                     principal_id,
                     required_capability,
                     principal_epoch,
                     vault_epoch,
                     classification,
                     correlation_id,
                     causation_id,
                     expected_revision,
                     payload
                   ]
                 ]
               } =
                 query!(
                   repo,
                   """
                   SELECT
                     id,
                     idempotency_key,
                     vault_id,
                     principal_id,
                     required_capability,
                     principal_authorization_epoch,
                     vault_authorization_epoch,
                     classification,
                     correlation_id,
                     causation_id,
                     expected_entity_revision,
                     payload
                   FROM core.outbox_events
                   WHERE event_type = $1
                     AND payload ->> 'asset_id' = $2
                   """,
                   [event_type, asset_id]
                 )

        assert {:ok, envelope} =
                 JobEnvelope.new(%{
                   attempt: 0,
                   causation_id: load_uuid(causation_id),
                   classification: String.to_existing_atom(classification),
                   correlation_id: load_uuid(correlation_id),
                   expected_entity_revision: expected_revision,
                   idempotency_key: idempotency_key,
                   job_id: load_uuid(id),
                   job_type: job_type,
                   payload: payload,
                   principal_authorization_epoch: principal_epoch,
                   principal_id: load_uuid(principal_id),
                   required_capability: required_capability,
                   vault_authorization_epoch: vault_epoch,
                   vault_id: load_uuid(vault_id),
                   version: 1
                 })

        envelope
      end)

    assert {:ok, _runner_job_id} = ObanAdapter.submit(%{}, envelope)
    envelope
  end

  defp assert_available_convergence!(
         fixture,
         storage_root,
         idempotency_key,
         asset_id,
         source_reference_id,
         resource_version_id,
         object_id
       ) do
    scoped(fixture, fn repo ->
      assert %{
               rows: [
                 [
                   "available",
                   3,
                   "available",
                   true,
                   true,
                   true,
                   1,
                   1,
                   1,
                   0,
                   0
                 ]
               ]
             } =
               query!(
                 repo,
                 """
                 SELECT
                   asset.state,
                   asset.state_revision,
                   object.lifecycle,
                   (
                     SELECT count(*) > 0
                     FROM content.upload_grants AS upload_grant
                     WHERE upload_grant.vault_id = asset.vault_id
                       AND upload_grant.idempotency_key = $3
                   ),
                   (
                     SELECT count(*) = 0
                     FROM content.upload_grants AS upload_grant
                     WHERE upload_grant.vault_id = asset.vault_id
                       AND upload_grant.idempotency_key = $3
                       AND upload_grant.asset_id IS DISTINCT FROM asset.id
                   ),
                   (
                     SELECT count(*) = 0
                     FROM content.upload_grants AS upload_grant
                     WHERE upload_grant.vault_id = asset.vault_id
                       AND upload_grant.idempotency_key = $3
                       AND upload_grant.source_reference_id
                         IS DISTINCT FROM $4::uuid
                   ),
                   (
                     SELECT count(*)
                     FROM content.source_references AS source_reference
                     JOIN content.resource_versions AS resource_version
                       ON resource_version.id = source_reference.resource_version_id
                      AND resource_version.vault_id = source_reference.vault_id
                     JOIN content.resource_assets AS resource_asset
                       ON resource_asset.resource_version_id = resource_version.id
                      AND resource_asset.asset_id = asset.id
                      AND resource_asset.vault_id = resource_version.vault_id
                     WHERE source_reference.id = $4
                       AND source_reference.vault_id = asset.vault_id
                       AND source_reference.resource_version_id = $5
                       AND source_reference.idempotency_key_digest = $6
                       AND resource_asset.released_at IS NULL
                   ),
                   (
                     SELECT count(*)
                     FROM content.resource_assets AS resource_asset
                     WHERE resource_asset.asset_id = asset.id
                       AND resource_asset.vault_id = asset.vault_id
                       AND resource_asset.resource_version_id = $5
                       AND resource_asset.released_at IS NULL
                   ),
                   (
                     SELECT count(*)
                     FROM content.assets AS live_asset
                     WHERE live_asset.asset_object_id = object.id
                       AND live_asset.vault_id = object.vault_id
                   ),
                   (
                     SELECT count(*)
                     FROM content.asset_stages AS stage
                     WHERE stage.asset_id = asset.id
                       AND stage.vault_id = asset.vault_id
                       AND stage.state = 'open'
                   ),
                   (
                     SELECT count(*)
                     FROM content.asset_objects AS staged_object
                     WHERE staged_object.vault_id = asset.vault_id
                       AND staged_object.lifecycle = 'staged'
                   )
                 FROM content.assets AS asset
                 JOIN content.asset_objects AS object
                   ON object.id = asset.asset_object_id
                  AND object.vault_id = asset.vault_id
                 WHERE asset.id = $1
                   AND object.id = $2
                   AND asset.resource_version_id = $5
                 """,
                 [
                   Ecto.UUID.dump!(asset_id),
                   Ecto.UUID.dump!(object_id),
                   idempotency_key,
                   Ecto.UUID.dump!(source_reference_id),
                   Ecto.UUID.dump!(resource_version_id),
                   :crypto.hash(:sha256, idempotency_key)
                 ]
               )

      :ok
    end)

    object_context = object_storage_context!(object_id, storage_root)

    assert {:ok, %{byte_size: byte_size, ciphertext_hash: ciphertext_hash}} =
             LocalFilesystemAdapter.stat(
               object_context,
               %ObjectRef{object_id: object_id}
             )

    assert byte_size > 0
    assert ciphertext_hash == object_context.ciphertext_hash

    assert {:ok, []} =
             LocalFilesystemAdapter.list_staged(%{root: storage_root})

    physical_objects =
      storage_root
      |> Path.join("objects/**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)

    assert length(physical_objects) == 1
  end

  defp object_storage_context!(object_id, storage_root) do
    Fixtures.with_owner(fn ->
      assert %{rows: [[vault_id, key_domain_id, lookup_digest, ciphertext_hash]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   vault_id,
                   key_domain_id,
                   lookup_digest,
                   ciphertext_hash
                 FROM content.asset_objects
                 WHERE id = $1
                 """,
                 [Ecto.UUID.dump!(object_id)]
               )

      %{
        ciphertext_hash: ciphertext_hash,
        domain_namespace: load_uuid(key_domain_id),
        lookup_digest: Base.encode16(lookup_digest, case: :lower),
        root: storage_root,
        vault_namespace: load_uuid(vault_id)
      }
    end)
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      RequestRepo,
      %{
        principal_id: fixture.principal_id,
        vault_id: fixture.vault_id
      },
      callback
    )
  end

  defp owner_query(statement, parameters) do
    Fixtures.with_owner(fn -> query!(MigrationRepo, statement, parameters) end)
  end

  defp install_vertical_security!(fixture) do
    ids = %{
      cleanup_principal_id: Ecto.UUID.generate(),
      domain_key_version_id: Ecto.UUID.generate(),
      key_domain_id: Ecto.UUID.generate(),
      vault_key_version_id: Ecto.UUID.generate()
    }

    domain_key = :crypto.strong_rand_bytes(32)
    domain_dedup_key = :crypto.strong_rand_bytes(32)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE core.vaults
        SET locked = false
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(fixture.vault_id)]
      )

      for capability <- ["asset.write", "asset.read", "object.cleanup"] do
        query!(
          MigrationRepo,
          """
          INSERT INTO core.capabilities (id, name)
          VALUES ($1, $2)
          ON CONFLICT (name) DO NOTHING
          """,
          [Ecto.UUID.dump!(Ecto.UUID.generate()), capability]
        )
      end

      for capability <- ["asset.write", "asset.read"] do
        query!(
          MigrationRepo,
          """
          INSERT INTO core.principal_capabilities (
            principal_id, vault_id, capability_id
          )
          SELECT $1, $2, id
          FROM core.capabilities
          WHERE name = $3
          """,
          [
            Ecto.UUID.dump!(fixture.principal_id),
            Ecto.UUID.dump!(fixture.vault_id),
            capability
          ]
        )
      end

      query!(
        MigrationRepo,
        """
        INSERT INTO identity.principals (
          id, account_id, kind, metadata
        ) VALUES (
          $1, $2, 'system', '{"name":"object_cleanup"}'::jsonb
        )
        """,
        [
          Ecto.UUID.dump!(ids.cleanup_principal_id),
          Ecto.UUID.dump!(fixture.account_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_members (
          principal_id, vault_id, clearance
        ) VALUES ($1, $2, 'private')
        """,
        [
          Ecto.UUID.dump!(ids.cleanup_principal_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.principal_capabilities (
          principal_id, vault_id, capability_id
        )
        SELECT $1, $2, id
        FROM core.capabilities
        WHERE name = 'object.cleanup'
        """,
        [
          Ecto.UUID.dump!(ids.cleanup_principal_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        UPDATE core.vaults
        SET object_cleanup_principal_id = $2
        WHERE id = $1
        """,
        [
          Ecto.UUID.dump!(fixture.vault_id),
          Ecto.UUID.dump!(ids.cleanup_principal_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES (
          $1, $2, 1, 'active', 'aes_256_gcm', CURRENT_TIMESTAMP
        )
        """,
        [
          Ecto.UUID.dump!(ids.vault_key_version_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.key_domains (
          id, vault_id, classification, kind, state
        ) VALUES ($1, $2, 'private', 'content', 'active')
        """,
        [
          Ecto.UUID.dump!(ids.key_domain_id),
          Ecto.UUID.dump!(fixture.vault_id)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.domain_key_versions (
          id,
          vault_id,
          key_domain_id,
          vault_key_version_id,
          generation,
          state,
          algorithm,
          wrapped_key
        ) VALUES (
          $1, $2, $3, $4, 1, 'active', 'aes_256_gcm', $5
        )
        """,
        [
          Ecto.UUID.dump!(ids.domain_key_version_id),
          Ecto.UUID.dump!(fixture.vault_id),
          Ecto.UUID.dump!(ids.key_domain_id),
          Ecto.UUID.dump!(ids.vault_key_version_id),
          :crypto.strong_rand_bytes(60)
        ]
      )
    end)

    Map.merge(ids, %{
      domain_dedup_key: domain_dedup_key,
      domain_key: domain_key
    })
  end

  defp session(fixture) do
    %SessionContext{
      account_id: fixture.account_id,
      authorization_epoch: 0,
      expires_at: DateTime.add(DateTime.utc_now(), 1_800, :second),
      principal_authorization_epoch: 0,
      principal_id: fixture.principal_id,
      session_id: fixture.session_id,
      unlocked?: true,
      vault_authorization_epoch: 0,
      vault_id: fixture.vault_id
    }
  end

  defp custody_session(session, keys) do
    %{
      account_id: session.account_id,
      domain_classification: :private,
      domain_dedup_key: keys.domain_dedup_key,
      domain_key: keys.domain_key,
      domain_key_generation: 1,
      domain_key_version_id: keys.domain_key_version_id,
      expires_at: session.expires_at,
      key_domain_id: keys.key_domain_id,
      principal_authorization_epoch: session.principal_authorization_epoch,
      principal_id: session.principal_id,
      session_id: session.session_id,
      vault_authorization_epoch: session.vault_authorization_epoch,
      vault_id: session.vault_id,
      vault_key: :crypto.strong_rand_bytes(32)
    }
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
