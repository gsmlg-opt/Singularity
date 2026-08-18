defmodule Singularity.Runtime.ApplicationTest do
  use ExUnit.Case, async: false

  alias Singularity.Runtime.Application, as: RuntimeApplication
  alias Singularity.Runtime.AssetEvents
  alias Singularity.Runtime.Assets.UploadReconciler
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.CustodyReader
  alias Singularity.Runtime.JobDispatcher
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLeaseSupervisor
  alias Singularity.Runtime.LockVault
  alias Singularity.Runtime.Observability.Telemetry
  alias Singularity.Runtime.StorageAdapter
  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Backup.BundleWriter
  alias Singularity.Storage.Backup.Exporter
  alias Singularity.Storage.Backup.LocalDestination
  alias Singularity.Storage.Backup.LogicalBundleVerifier
  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Jobs.GenericWorker
  alias Singularity.Storage.LocalFilesystemAdapter
  alias Singularity.Storage.ObjectLock
  alias Singularity.Storage.Postgres.AssetDeletionRepository
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.Postgres.BackupRepository
  alias Singularity.Storage.Postgres.CustodyRepository
  alias Singularity.Storage.Postgres.NoteProjectionReconciler
  alias Singularity.Storage.Postgres.NoteRepository
  alias Singularity.Storage.WorkerRepo

  test "pure tests opt out of every infrastructure child" do
    children =
      RuntimeApplication.infrastructure_children(%{
        start_infrastructure: false
      })

    assert children == []
    refute AssetEvents.Registry in Enum.map(children, &child_id/1)
  end

  test "the observability handler is supervised even when infrastructure is disabled" do
    assert RuntimeApplication.application_children(%{
             start_infrastructure: false
           }) == [Telemetry]
  end

  test "infrastructure children preserve the literal dependency order" do
    composition = valid_composition()

    assert RuntimeApplication.infrastructure_children(composition)
           |> Enum.map(&child_id/1) == [
             Singularity.Storage.RequestRepo,
             Singularity.Storage.PreAuthRepo,
             Singularity.Storage.DispatcherRepo,
             Singularity.Storage.WorkerRepo,
             Singularity.Runtime.AssetEvents.Registry,
             UploadReconciler,
             Singularity.Runtime.UploadRecoveryTaskSupervisor,
             Singularity.Runtime.KeyLeaseSupervisor,
             Singularity.Runtime.KeyCustodian,
             Singularity.Runtime.UploadSessionSupervisor,
             Singularity.Storage.Jobs.ObanAdapter,
             Singularity.Runtime.OutboxDispatcher
           ]

    refute Singularity.Storage.MigrationRepo in Enum.map(
             RuntimeApplication.infrastructure_children(composition),
             &child_id/1
           )
  end

  test "dev and prod configuration provide startable fail-closed custody" do
    config_path = Path.expand("../../../../../config/config.exs", __DIR__)

    for environment <- [:dev, :prod] do
      runtime_config =
        config_path
        |> Config.Reader.read!(env: environment)
        |> Keyword.fetch!(:singularity_runtime)

      assert %{
               authorization: CustodyReader,
               backup_cipher: ChunkedAEAD,
               clock: CustodyReader,
               context: %{
                 repo: WorkerRepo,
                 repository_adapter: CustodyRepository,
                 key_wrapper: KeyWrapper,
                 storage: StorageAdapter
               },
               idle_lock: LockVault,
               key_reader: CustodyReader,
               object_key_loader: CustodyReader
             } = options = Keyword.fetch!(runtime_config, :key_custodian)

      lease_supervisor =
        start_supervised!(
          {KeyLeaseSupervisor, name: nil},
          id: make_ref()
        )

      custodian =
        start_supervised!(
          {KeyCustodian, Map.put(options, :lease_supervisor, lease_supervisor)},
          id: make_ref()
        )

      assert Process.alive?(custodian)

      assert {:error, :waiting_for_unlock} =
               KeyCustodian.lease(custodian, lease_binding())
    end
  end

  test "startup validation fails closed for a missing handler or authorization member" do
    for invalid <- [
          put_in(valid_composition(), [:job_handler], nil),
          put_in(valid_composition(), [:authorization, :store], nil),
          put_in(valid_composition(), [:authorization, :custodian], nil),
          update_in(
            valid_composition(),
            [:key_custodian],
            &Map.delete(&1, :object_key_loader)
          ),
          update_in(
            valid_composition(),
            [:key_custodian],
            &Map.delete(&1, :backup_cipher)
          ),
          put_in(
            valid_composition(),
            [:key_custodian, :backup_cipher],
            :not_a_cipher_adapter
          )
        ] do
      assert_raise ArgumentError, ~r/runtime job composition is invalid/, fn ->
        RuntimeApplication.infrastructure_children(invalid)
      end
    end
  end

  test "authorization bundle has a concrete store and custodian" do
    assert {:ok,
            %{
              __struct__: AuthorizationDependencies,
              store: Fake.Authorization,
              custodian: Singularity.Runtime.KeyCustodian
            }} =
             AuthorizationDependencies.new(%{
               store: Fake.Authorization,
               custodian: Singularity.Runtime.KeyCustodian
             })

    for invalid <- [%{}, %{store: Fake.Authorization}, %{custodian: self()}] do
      assert {:error, %{code: :job_failed}} =
               AuthorizationDependencies.new(invalid)
    end
  end

  test "runtime has no direct Oban dependency and storage has no runtime dependency" do
    runtime_mix = File.read!(Path.expand("../../../mix.exs", __DIR__))
    storage_mix = File.read!(Path.expand("../../../../singularity_storage/mix.exs", __DIR__))

    refute runtime_mix =~ "{:oban,"
    refute storage_mix =~ ":singularity_runtime"
  end

  test "runtime handler and generic worker fail closed for an invalid authorization bundle" do
    previous_handler = Application.get_env(:singularity_storage, :job_handler)

    previous_authorization =
      Application.get_env(:singularity_runtime, :authorization_dependencies)

    on_exit(fn ->
      Application.put_env(:singularity_storage, :job_handler, previous_handler)

      Application.put_env(
        :singularity_runtime,
        :authorization_dependencies,
        previous_authorization
      )
    end)

    Application.put_env(:singularity_storage, :job_handler, JobDispatcher)

    for invalid <- [
          nil,
          %{store: nil, custodian: Singularity.Runtime.KeyCustodian},
          %{store: Fake.Authorization, custodian: nil}
        ] do
      if invalid do
        Application.put_env(
          :singularity_runtime,
          :authorization_dependencies,
          invalid
        )
      else
        Application.delete_env(
          :singularity_runtime,
          :authorization_dependencies
        )
      end

      assert {:cancel, %{code: :job_failed}} =
               GenericWorker.perform(%Oban.Job{args: encoded_envelope()})
    end
  end

  test "runtime handler exposes the explicit asset and backup job bundle" do
    assert %{
             asset_deletions: AssetDeletionRepository,
             asset_events: AssetEvents,
             assets: AssetRepository,
             authorize: Authorize,
             authorization: %AuthorizationDependencies{
               store: Fake.Authorization,
               custodian: Singularity.Runtime.KeyCustodian
             },
             backups: BackupRepository,
             bundle_reader: BundleReader,
             bundle_verifier: LogicalBundleVerifier,
             bundle_writer: BundleWriter,
             destination: {LocalDestination, %{backup_root: backup_root}},
             exporter: Exporter,
             note_projection: NoteProjectionReconciler,
             note_repository: NoteRepository,
             object_lock: ObjectLock,
             object_storage: {Exporter, {LocalFilesystemAdapter, %{root: storage_root}}},
             storage: {LocalFilesystemAdapter, %{root: storage_root}}
           } = JobDispatcher.dependencies()

    assert is_binary(storage_root)
    assert is_binary(backup_root)
    refute Path.expand(backup_root) == Path.expand(storage_root)

    assert {:error, %{code: :job_failed}} =
             JobDispatcher.handle(JobDispatcher.dependencies(), :unregistered)
  end

  test "runtime handler dispatches only the exact seven implemented durable job types" do
    for job_type <- [
          "asset_verify",
          "asset_finalize",
          "asset_metadata",
          "asset_cleanup",
          "object_cleanup",
          "backup"
        ] do
      assert {:error, %{code: :invalid}} =
               JobDispatcher.handle(%{}, %{job_type: job_type})
    end

    assert {:ok, note_projection} =
             Singularity.Core.JobEnvelope.new(%{
               version: 1,
               job_id: "00000000-0000-4000-8000-000000001911",
               job_type: "note_projection",
               idempotency_key: "note-current-changed:00000000-0000-4000-8000-000000001912:1",
               vault_id: "00000000-0000-4000-8000-000000001913",
               principal_id: "00000000-0000-4000-8000-000000001914",
               required_capability: "note.write",
               principal_authorization_epoch: 0,
               vault_authorization_epoch: 0,
               classification: :private,
               correlation_id: "00000000-0000-4000-8000-000000001915",
               causation_id: "00000000-0000-4000-8000-000000001916",
               expected_entity_revision: 1,
               attempt: 0,
               payload: %{"resource_id" => "00000000-0000-4000-8000-000000001912"}
             })

    assert {:error, %{code: :invalid}} = JobDispatcher.handle(%{}, note_projection)

    for unregistered_job_type <- [
          "integrity_audit",
          "metadata_extract",
          "asset_metadata_v1",
          "technical_metadata"
        ] do
      assert {:error, %{code: :job_failed}} =
               JobDispatcher.handle(%{}, %{job_type: unregistered_job_type})
    end
  end

  test "Oban composition gives the closed note projection queue two workers" do
    oban = Application.fetch_env!(:singularity_storage, Oban)
    assert Keyword.fetch!(oban, :queues)[:note_projection] == 2
  end

  defp valid_composition do
    %{
      start_infrastructure: true,
      job_handler: Singularity.Runtime.JobDispatcher,
      authorization: %{
        store: Fake.Authorization,
        custodian: Singularity.Runtime.KeyCustodian
      },
      key_custodian: %{
        authorization: Fake.Authorization,
        backup_cipher: ChunkedAEAD,
        clock: Fake.Clock,
        context: %{},
        idle_lock: fn _session -> :ok end,
        key_reader: Fake.KeyReader,
        object_key_loader: Fake.KeyReader
      },
      oban: [],
      outbox_dispatcher: []
    }
  end

  defp child_id(module) when is_atom(module), do: module
  defp child_id({module, _options}) when is_atom(module), do: module
  defp child_id(%{id: id}), do: id

  defp lease_binding do
    %{
      job_id: "job-1",
      vault_id: "vault-1",
      principal_id: "principal-1",
      required_capability: "asset.read",
      principal_authorization_epoch: 0,
      vault_authorization_epoch: 0,
      object_id: "object-1",
      object_generation: 1,
      session_id: "session-1"
    }
  end

  defp encoded_envelope do
    %{
      "version" => 1,
      "job_id" => "00000000-0000-0000-0000-000000000001",
      "job_type" => "asset_verify",
      "idempotency_key" => "asset:verify:7",
      "vault_id" => "00000000-0000-0000-0000-000000000002",
      "principal_id" => "00000000-0000-0000-0000-000000000003",
      "required_capability" => "asset:verify",
      "principal_authorization_epoch" => 4,
      "vault_authorization_epoch" => 9,
      "classification" => "private",
      "correlation_id" => "00000000-0000-0000-0000-000000000005",
      "causation_id" => "00000000-0000-0000-0000-000000000006",
      "expected_entity_revision" => 7,
      "attempt" => 0,
      "payload" => %{"asset_id" => "00000000-0000-0000-0000-000000000007"}
    }
  end
end
