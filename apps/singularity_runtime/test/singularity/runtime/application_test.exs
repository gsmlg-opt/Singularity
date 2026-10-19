defmodule Singularity.Runtime.ApplicationTest do
  use ExUnit.Case, async: false

  alias Singularity.Runtime.Application, as: RuntimeApplication
  alias Singularity.Runtime.AssetEvents
  alias Singularity.Runtime.Assets.UploadReconciler
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.CustodyReader
  alias Singularity.Runtime.Documents.ExtractionReconciler
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
             ExtractionReconciler,
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
             object_storage:
               {Exporter,
                %{repo: WorkerRepo, storage: {LocalFilesystemAdapter, %{root: storage_root}}}},
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

defmodule Singularity.Runtime.ExportStartupTest do
  use ExUnit.Case, async: false

  alias Singularity.Runtime.Knowledge.ExportArtifact
  alias Singularity.Storage.KnowledgeExport.ArtifactDirectory

  @moduletag :tmp_dir
  @runtime __MODULE__.FixtureRuntime
  @contender __MODULE__.FixtureContender
  @upload_tasks Singularity.Runtime.UploadRecoveryTaskSupervisor
  @config Path.expand("../../../../../config", __DIR__)
  @required_env ~w(SECRET_KEY_BASE SINGULARITY_BACKUP_ROOT SINGULARITY_STORAGE_ROOT SINGULARITY_AUDIT_FINGERPRINT_SECRET SINGULARITY_MUTATION_FINGERPRINT_SECRET SINGULARITY_MIGRATION_DATABASE_URL SINGULARITY_DATABASE_URL SINGULARITY_PRE_AUTH_DATABASE_URL SINGULARITY_DISPATCHER_DATABASE_URL SINGULARITY_WORKER_DATABASE_URL)

  defmodule Child do
    use GenServer

    def start_link({:barrier, parent, reference, name}),
      do: GenServer.start_link(__MODULE__, {parent, reference, name})

    def start_link({:fail, parent, reference, root}) do
      {:ok, operation} = ArtifactDirectory.create(root)
      File.write!(Path.join(operation.path, "unfinished"), "fixture bytes")
      send(parent, {:failed_child_operation, reference, operation})
      {:error, :fixture_child_failure}
    end

    @impl true
    def init({parent, reference, name}) do
      send(parent, {:child_initializing, reference, self(), Process.whereis(name)})

      receive do
        {:release_child, ^reference} -> {:ok, nil}
      after
        5_000 -> {:stop, :fixture_barrier_not_released}
      end
    end
  end

  setup %{tmp_dir: tmp} do
    context =
      Map.new([:root, :storage_root, :backup_root], &{&1, Path.join(tmp, Atom.to_string(&1))})

    for key <- [:storage_root, :backup_root] do
      File.mkdir!(context[key])
      File.chmod!(context[key], 0o700)
      File.write!(Path.join(context[key], "sentinel"), Atom.to_string(key))
    end

    {:ok, root} = ArtifactDirectory.prepare(context)
    foreign = Path.join(context.root, "foreign-sentinel")
    File.write!(foreign, "foreign bytes")
    malformed = Path.join(context.root, "knowledge-export-00000000-0000-4000-8000-000000009990")
    File.mkdir!(malformed)
    File.chmod!(malformed, 0o700)
    File.write!(Path.join(malformed, ".ownership"), "not an ownership record")
    File.chmod!(Path.join(malformed, ".ownership"), 0o600)

    for {app, key, value} <- [
          {:singularity_runtime, :knowledge_export_root, context.root},
          {:singularity_storage, :storage_root, context.storage_root},
          {:singularity_storage, :backup_root, context.backup_root}
        ] do
      put_configuration(app, key, value)
    end

    assert Process.whereis(@runtime) == nil
    assert Process.whereis(@contender) == nil
    assert Process.whereis(@upload_tasks) == nil
    %{context: context, root: root, reference: make_ref(), foreign: foreign, malformed: malformed}
  end

  # Deliberately arranged OLD ordering, using real directory/supervisor calls.
  # Its deletion witness is not qualification of ExportArtifact.start_runtime.
  test "test-owned old absence-check cleanup start gap deletes a live envelope", c do
    parent = self()
    reference = c.reference

    {late, monitor} =
      spawn_monitor(fn ->
        assert Process.whereis(@runtime) == nil
        send(parent, {:old_checked_absent, reference})

        receive do
          {:continue_old_start, ^reference} ->
            {:ok, _counts} = ArtifactDirectory.scavenge(c.root)

            send(
              parent,
              {:old_start_returned, reference,
               Supervisor.start_link([], strategy: :one_for_one, name: @runtime)}
            )
        end
      end)

    on_exit(fn -> if Process.alive?(late), do: Process.exit(late, :kill) end)
    assert_receive {:old_checked_absent, ^reference}, 5_000
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one, name: @runtime)
    own_supervisor(supervisor)
    operation = operation!(c.root)
    send(late, {:continue_old_start, reference})

    assert_receive {:old_start_returned, ^reference, {:error, {:already_started, ^supervisor}}},
                   5_000

    assert_receive {:DOWN, ^monitor, :process, ^late, :normal}, 5_000
    assert File.lstat(operation.path) == {:error, :enoent}
    assert Process.alive?(supervisor)
    assert_sentinels(c)
    stop_supervisor(supervisor)
  end

  test "actual fixed local lock contention has no filesystem effects", c do
    require_startup!()
    operation = operation!(c.root)
    before = witness(c, operation)
    holder = hold_lock(c.reference)
    assert {:error, :storage_unavailable} = start_runtime([], @contender)
    assert witness(c, operation) == before
    release_lock(holder, c.reference)
    assert_guard_released()
  end

  test "actual guard spans native registration child initialization and start_link return", c do
    require_startup!()
    reference = c.reference
    {starter, monitor} = starter([barrier_child(c)], @runtime, reference)
    assert_receive {:child_initializing, ^reference, child, supervisor}, 5_000
    assert is_pid(supervisor) and Process.whereis(@runtime) == supervisor
    own_supervisor(supervisor)
    on_exit(fn -> send(child, {:release_child, reference}) end)
    refute_receive {:native_start_result, ^reference, _}, 0
    before = root_witness(c)
    assert {:error, :storage_unavailable} = start_runtime([], @contender)
    assert root_witness(c) == before
    send(child, {:release_child, reference})
    assert_receive {:native_start_result, ^reference, {:ok, ^supervisor}}, 5_000
    operation = operation!(c.root)
    before = witness(c, operation)
    assert {:error, {:already_started, ^supervisor}} = start_runtime([], @runtime)
    assert witness(c, operation) == before
    stop_supervisor(supervisor)
    finish_starter(starter, monitor)
  end

  for fault <- [:root, :cleanup] do
    @fault fault
    test "#{fault} failure refuses startup and releases guard for a real retry", c do
      require_startup!()
      operation = operation!(c.root)
      restore = inject_filesystem_fault(c, operation, @fault)
      assert {:error, :storage_unavailable} = start_runtime([], @runtime)
      assert Process.whereis(@runtime) == nil
      assert File.exists?(operation.path)
      assert_sentinels(c)
      assert_guard_released()
      restore.()
      {:ok, supervisor} = start_runtime([], @runtime)
      own_supervisor(supervisor)
      assert File.lstat(operation.path) == {:error, :enoent}
      assert_sentinels(c)
      stop_supervisor(supervisor)
    end
  end

  test "native child-start failure retains native result and next startup scavenges its orphan",
       c do
    require_startup!()
    reference = c.reference

    child = %{
      id: :fixture_child,
      start: {Child, :start_link, [{:fail, self(), reference, c.root}]}
    }

    {starter, monitor} = starter([child], @runtime, reference)
    assert_receive {:failed_child_operation, ^reference, operation}, 5_000

    assert_receive {:native_start_result, ^reference,
                    {:error,
                     {:shutdown, {:failed_to_start_child, :fixture_child, :fixture_child_failure}}}},
                   5_000

    assert Process.whereis(@runtime) == nil
    assert File.exists?(operation.path)
    assert_guard_released()
    finish_starter(starter, monitor)
    {:ok, supervisor} = start_runtime([], @runtime)
    own_supervisor(supervisor)
    assert File.lstat(operation.path) == {:error, :enoent}
    assert_sentinels(c)
    stop_supervisor(supervisor)
  end

  test "trusted preparation exception releases lock without starting a native tree", c do
    require_startup!()
    operation = operation!(c.root)
    before = witness(c, operation)
    Application.delete_env(:singularity_storage, :backup_root)
    assert_raise ArgumentError, fn -> start_runtime([], @runtime) end
    Application.put_env(:singularity_storage, :backup_root, c.context.backup_root)
    assert Process.whereis(@runtime) == nil
    assert witness(c, operation) == before
    assert_guard_released()
    {:ok, supervisor} = start_runtime([], @runtime)
    own_supervisor(supervisor)
    assert File.lstat(operation.path) == {:error, :enoent}
    assert_sentinels(c)
    stop_supervisor(supervisor)
  end

  test "starter hard death releases guard but surviving native supervisors forbid cleanup", c do
    require_startup!()
    reference = c.reference
    {starter, monitor} = starter([barrier_child(c)], @runtime, reference)
    assert_receive {:child_initializing, ^reference, child, supervisor}, 5_000
    own_supervisor(supervisor)
    on_exit(fn -> send(child, {:release_child, reference}) end)
    supervisor_monitor = Process.monitor(supervisor)
    operation = operation!(c.root)
    before = witness(c, operation)
    id = make_ref()
    upload = start_supervised!({Task.Supervisor, name: @upload_tasks}, id: id)
    upload_monitor = Process.monitor(upload)
    Process.exit(starter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^starter, :killed}, 5_000
    assert_guard_released()

    case Process.whereis(@runtime) do
      nil ->
        assert {:error, :storage_unavailable} = start_runtime([], @runtime)

      ^supervisor ->
        assert {:error, {:already_started, ^supervisor}} = start_runtime([], @runtime)
    end

    assert witness(c, operation) == before
    send(child, {:release_child, reference})
    assert_receive {:DOWN, ^supervisor_monitor, :process, ^supervisor, _}, 5_000
    assert Process.whereis(@runtime) == nil
    assert Process.whereis(@upload_tasks) == upload
    assert {:error, :storage_unavailable} = start_runtime([], @runtime)
    assert witness(c, operation) == before
    assert :ok = stop_supervised(id)
    assert_receive {:DOWN, ^upload_monitor, :process, ^upload, _}, 5_000
    {:ok, replacement} = start_runtime([], @runtime)
    own_supervisor(replacement)
    assert File.lstat(operation.path) == {:error, :enoent}
    assert_sentinels(c)
    stop_supervisor(replacement)
  end

  test "false preserves native options links and results despite lock and invalid roots", c do
    require_startup!()
    missing = Path.join(Path.dirname(c.context.root), "never-created")
    Application.put_env(:singularity_runtime, :knowledge_export_root, missing)
    Application.put_env(:singularity_storage, :storage_root, <<0>>)
    Application.delete_env(:singularity_storage, :backup_root)
    holder = hold_lock(c.reference)

    assert {:ok, supervisor} =
             apply(ExportArtifact, :start_runtime, [
               [],
               [strategy: :one_for_one, name: @runtime],
               false
             ])

    own_supervisor(supervisor)
    assert Process.whereis(@runtime) == supervisor
    assert {:links, links} = Process.info(self(), :links)
    assert supervisor in links
    assert Supervisor.which_children(supervisor) == []

    assert {:error, {:already_started, ^supervisor}} =
             apply(ExportArtifact, :start_runtime, [
               [],
               [strategy: :one_for_one, name: @runtime],
               false
             ])

    assert File.lstat(missing) == {:error, :enoent}
    assert_sentinels(c)
    release_lock(holder, c.reference)
    stop_supervisor(supervisor)
  end

  test "Config.Reader dev sibling defaults overrides and test run-id roots are exact", c do
    with_environment(
      %{
        "SINGULARITY_EXPORT_ROOT" => nil,
        "SINGULARITY_BACKUP_ROOT" => nil,
        "SINGULARITY_STORAGE_ROOT" => c.context.storage_root,
        "SINGULARITY_TEST_RUN_ID" => "startup-contract/a"
      },
      fn ->
        dev = Config.Reader.read!(Path.join(@config, "config.exs"), env: :dev)
        backup = Path.expand("../var/backups", @config)

        assert get_in(dev, [:singularity_runtime, :knowledge_export_root]) ==
                 backup <> "-knowledge-export"

        test_config = Config.Reader.read!(Path.join(@config, "config.exs"), env: :test)

        assert get_in(test_config, [:singularity_runtime, :knowledge_export_root]) ==
                 Path.join([
                   System.tmp_dir!(),
                   "singularity-knowledge-export",
                   "test",
                   "startup_contract_a"
                 ])

        System.put_env("SINGULARITY_BACKUP_ROOT", c.context.backup_root)
        dev = Config.Reader.read!(Path.join(@config, "config.exs"), env: :dev)

        assert get_in(dev, [:singularity_runtime, :knowledge_export_root]) ==
                 c.context.backup_root <> "-knowledge-export"

        System.put_env("SINGULARITY_EXPORT_ROOT", c.context.root)
        dev = Config.Reader.read!(Path.join(@config, "config.exs"), env: :dev)
        assert get_in(dev, [:singularity_runtime, :knowledge_export_root]) == c.context.root
      end
    )
  end

  test "production export root is optional and all pre-existing required variables remain required",
       c do
    put_configuration(:singularity_storage, :job_handler, Singularity.Runtime.JobDispatcher)
    put_configuration(:singularity_storage, Singularity.Storage.RequestRepo, pool_size: 10)
    fixture = production_environment(c)
    source = File.read!(Path.join(@config, "runtime.exs"))

    required =
      Regex.scan(~r/System.fetch_env!\("([^"]+)"\)/, source, capture: :all_but_first)
      |> List.flatten()

    assert MapSet.new(required) == MapSet.new(@required_env)

    with_environment(fixture, fn ->
      runtime = Config.Reader.read!(Path.join(@config, "runtime.exs"), env: :prod)

      assert get_in(runtime, [:singularity_runtime, :knowledge_export_root]) ==
               c.context.backup_root <> "-knowledge-export"

      System.put_env("SINGULARITY_EXPORT_ROOT", c.context.root)
      override = Config.Reader.read!(Path.join(@config, "runtime.exs"), env: :prod)
      assert get_in(override, [:singularity_runtime, :knowledge_export_root]) == c.context.root

      for key <- @required_env do
        System.delete_env(key)

        assert_raise System.EnvError, fn ->
          Config.Reader.read!(Path.join(@config, "runtime.exs"), env: :prod)
        end

        System.put_env(key, Map.fetch!(fixture, key))
      end
    end)
  end

  test "trusted configuration uses only fixed roots monotonic clock and existing task supervisor",
       c do
    assert Code.ensure_loaded?(ExportArtifact) and
             function_exported?(ExportArtifact, :configuration, 0),
           "missing ExportArtifact.configuration/0"

    before = System.monotonic_time(:millisecond)
    config = apply(ExportArtifact, :configuration, [])

    assert Enum.sort(Map.keys(config)) == [
             :backup_root,
             :clock,
             :root,
             :storage_root,
             :task_supervisor
           ]

    assert Map.take(config, [:root, :storage_root, :backup_root]) == c.context
    assert config.task_supervisor == @upload_tasks
    assert is_function(config.clock, 0)
    now = config.clock.()
    assert now >= before and now <= System.monotonic_time(:millisecond)

    dev = Config.Reader.read!(Path.join(@config, "config.exs"), env: :dev)
    custody = get_in(dev, [:singularity_runtime, :key_custodian])
    assert custody.authorization == Singularity.Runtime.CustodyReader
    assert custody.context.repository_adapter == Singularity.Storage.Postgres.CustodyRepository
    assert custody.context.storage == Singularity.Runtime.StorageAdapter
    assert custody.context.repo == Singularity.Storage.WorkerRepo
  end

  # BEGIN Task16 bootstrap-loss startup recovery witness
  # Real Artifact tasks/directories and guarded startup only. No authority,
  # Snapshot COMMIT, native custody or immediate bootstrap cleanup is claimed.
  test "pre-owner companion death leaves recognized residue for separate guarded startup recovery",
       c do
    require_startup!()
    parent = self()
    reference = c.reference
    task_id = :bootstrap_gap_tasks
    tasks = start_supervised!({Task.Supervisor, []}, id: task_id)
    tasks_monitor = Process.monitor(tasks)

    requester =
      spawn(fn ->
        receive do
          {:start_bootstrap_export, ^reference, runtime, session} ->
            result =
              ExportArtifact.generate(runtime, session, fn _runtime, _operation ->
                send(parent, {:unexpected_bootstrap_producer, reference, self()})
                flunk("bootstrap loss must precede the producer")
              end)

            send(parent, {:bootstrap_export_result, reference, result})
        after
          5_000 -> flunk("bootstrap fixture was not started")
        end
      end)

    requester_monitor = Process.monitor(requester)
    on_exit(fn -> if Process.alive?(requester), do: Process.exit(requester, :kill) end)

    clock = fn ->
      if self() == requester do
        send(parent, {:bootstrap_creation_clock, reference, self()})
      else
        # The existing first companion clock is after envelope creation and
        # before owner start; the paired source-order contract fixes this seam.
        send(parent, {:bootstrap_transition_clock, reference, self()})

        receive do
          {:release_bootstrap_clock, ^reference} -> :ok
        after
          5_000 -> flunk("bootstrap transition was not released")
        end
      end

      1_000
    end

    session = %Singularity.Runtime.SessionContext{
      session_id: "00000000-0000-4000-8000-000000009981",
      principal_id: "00000000-0000-4000-8000-000000009982",
      vault_id: "00000000-0000-4000-8000-000000009983",
      expires_at: ~U[2099-01-01 00:00:00Z],
      principal_authorization_epoch: 0,
      vault_authorization_epoch: 0,
      authorization_epoch: 0,
      unlocked?: true
    }

    runtime = %{knowledge_export: Map.merge(c.context, %{task_supervisor: tasks, clock: clock})}
    send(requester, {:start_bootstrap_export, reference, runtime, session})
    assert_receive {:bootstrap_creation_clock, ^reference, ^requester}, 5_000
    assert_receive {:bootstrap_transition_clock, ^reference, companion}, 5_000
    companion_monitor = Process.monitor(companion)
    on_exit(fn -> if Process.alive?(companion), do: Process.exit(companion, :kill) end)
    assert Task.Supervisor.children(tasks) == [companion]

    assert [operation_name] =
             File.ls!(c.context.root) -- [Path.basename(c.foreign), Path.basename(c.malformed)]

    assert "knowledge-export-" <> operation_id = operation_name
    assert Ecto.UUID.cast(operation_id) == {:ok, operation_id}
    operation_path = Path.join(c.context.root, operation_name)
    marker_path = Path.join(operation_path, ".ownership")
    marker_bytes = File.read!(marker_path)
    assert byte_size(marker_bytes) in 1..1_024
    assert Bitwise.band(File.lstat!(operation_path).mode, 0o7777) == 0o700
    assert Bitwise.band(File.lstat!(marker_path).mode, 0o7777) == 0o600

    marker_identity = fn path ->
      stat = File.lstat!(path)

      Map.new(~w(major_device minor_device inode uid gid)a, fn key ->
        {Atom.to_string(key), Map.fetch!(stat, key)}
      end)
    end

    assert Jason.decode!(marker_bytes) == %{
             "format" => "singularity.knowledge-export-owner",
             "version" => 1,
             "operation_id" => operation_id,
             "root" => marker_identity.(c.context.root),
             "operation" => marker_identity.(operation_path)
           }

    assert File.ls!(operation_path) == [".ownership"]

    assert Enum.filter(:ets.all(), fn table ->
             :ets.info(table, :owner) == companion and
               :ets.info(table, :name) == Singularity.Storage.KnowledgeExport.Writer
           end) == []

    refute_received {:unexpected_bootstrap_producer, ^reference, _}
    refute_received {:bootstrap_export_result, ^reference, _}
    residue = {identity(operation_path), identity(marker_path), marker_bytes}
    Process.exit(companion, :kill)
    assert_receive {:DOWN, ^companion_monitor, :process, ^companion, :killed}, 5_000

    assert_receive {:bootstrap_export_result, ^reference,
                    {:error,
                     %Singularity.Core.Error{
                       code: :storage_unavailable,
                       message: nil,
                       details: %{},
                       retryable?: true
                     }}},
                   5_000

    assert_receive {:DOWN, ^requester_monitor, :process, ^requester, :normal}, 5_000
    # Fence the already-dead child's supervisor bookkeeping, not its cleanup.
    assert Task.Supervisor.terminate_child(tasks, companion) in [:ok, {:error, :not_found}]
    assert Task.Supervisor.children(tasks) == []
    refute_received {:unexpected_bootstrap_producer, ^reference, _}
    assert {identity(operation_path), identity(marker_path), File.read!(marker_path)} == residue
    assert_sentinels(c)
    assert :ok = stop_supervised(task_id)
    assert_receive {:DOWN, ^tasks_monitor, :process, ^tasks, _}, 5_000
    refute Enum.any?([requester, companion, tasks], &Process.alive?/1)

    # STARTUP RECOVERY: only now may the original guarded startup scavenge the
    # recognized orphan. The foreign and malformed entries remain untouched.
    {:ok, supervisor} = start_runtime([], @runtime)
    own_supervisor(supervisor)
    assert Process.whereis(@runtime) == supervisor
    assert File.lstat(operation_path) == {:error, :enoent}

    assert Enum.sort(File.ls!(c.context.root)) ==
             Enum.sort([Path.basename(c.foreign), Path.basename(c.malformed)])

    assert_sentinels(c)
    stop_supervisor(supervisor)
  end

  # END Task16 bootstrap-loss startup recovery witness

  defp require_startup! do
    assert Code.ensure_loaded?(ExportArtifact) and
             function_exported?(ExportArtifact, :start_runtime, 3),
           "missing ExportArtifact.start_runtime/3"
  end

  defp start_runtime(children, name),
    do:
      apply(ExportArtifact, :start_runtime, [children, [strategy: :one_for_one, name: name], true])

  defp barrier_child(c),
    do: %{
      id: :fixture_child,
      start: {Child, :start_link, [{:barrier, self(), c.reference, @runtime}]}
    }

  defp starter(children, name, reference) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        send(parent, {:native_start_result, reference, start_runtime(children, name)})

        receive do
          :finish_fixture_starter -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {pid, monitor}
  end

  defp finish_starter(pid, monitor) do
    send(pid, :finish_fixture_starter)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
  end

  defp hold_lock(reference) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        :global.trans(
          {{ExportArtifact, :runtime_start}, self()},
          fn ->
            send(parent, {:fixed_lock_held, reference})

            receive do
              {:release_fixed_lock, ^reference} -> :ok
            end
          end,
          [node()],
          0
        )
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive {:fixed_lock_held, ^reference}, 5_000
    {pid, monitor}
  end

  defp release_lock({pid, monitor}, reference) do
    send(pid, {:release_fixed_lock, reference})
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
  end

  defp assert_guard_released do
    parent = self()
    reference = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          :global.trans(
            {{ExportArtifact, :runtime_start}, self()},
            fn -> :released end,
            [node()],
            0
          )

        send(parent, {:fresh_guard_result, reference, result})
      end)

    assert_receive {:fresh_guard_result, ^reference, :released}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
  end

  defp operation!(root) do
    {:ok, operation} = ArtifactDirectory.create(root)
    File.write!(Path.join(operation.path, "retained"), "retained bytes")
    operation
  end

  defp witness(c, operation),
    do:
      {identity(operation.path), identity(Path.join(operation.path, ".ownership")),
       File.read!(Path.join(operation.path, ".ownership")),
       File.read!(Path.join(operation.path, "retained")), root_witness(c)}

  defp identity(path) do
    stat = File.lstat!(path)

    {stat.type, stat.major_device, stat.minor_device, stat.inode, stat.uid, stat.gid, stat.mode,
     stat.size}
  end

  defp root_witness(c),
    do:
      {Enum.sort(File.ls!(c.context.root)), File.read!(c.foreign),
       File.read!(Path.join(c.malformed, ".ownership"))}

  defp assert_sentinels(c) do
    assert File.read!(c.foreign) == "foreign bytes"
    assert File.read!(Path.join(c.malformed, ".ownership")) == "not an ownership record"

    for key <- [:storage_root, :backup_root],
        do: assert(File.read!(Path.join(c.context[key], "sentinel")) == Atom.to_string(key))
  end

  defp inject_filesystem_fault(c, _operation, :root) do
    Application.put_env(:singularity_runtime, :knowledge_export_root, c.context.storage_root)
    fn -> Application.put_env(:singularity_runtime, :knowledge_export_root, c.context.root) end
  end

  defp inject_filesystem_fault(_c, operation, :cleanup) do
    blocked = Path.join(operation.path, "blocked")
    File.mkdir!(blocked)
    File.write!(Path.join(blocked, "retained"), "blocked bytes")
    File.chmod!(blocked, 0o000)
    on_exit(fn -> File.chmod(blocked, 0o700) end)
    assert {:error, :eacces} = File.ls(blocked)
    fn -> File.chmod!(blocked, 0o700) end
  end

  defp own_supervisor(pid), do: on_exit(fn -> stop_supervisor(pid) end)

  defp stop_supervisor(pid) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      Supervisor.stop(pid, :normal)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end
  end

  defp put_configuration(app, key, value) do
    previous = Application.fetch_env(app, key)

    on_exit(fn ->
      case previous do
        {:ok, original} -> Application.put_env(app, key, original)
        :error -> Application.delete_env(app, key)
      end
    end)

    Application.put_env(app, key, value)
  end

  defp with_environment(values, callback) do
    previous = Map.new(values, fn {key, _value} -> {key, System.get_env(key)} end)
    Enum.each(values, fn {key, value} -> put_environment(key, value) end)

    try do
      callback.()
    after
      Enum.each(previous, fn {key, value} -> put_environment(key, value) end)
    end
  end

  defp put_environment(key, nil), do: System.delete_env(key)
  defp put_environment(key, value), do: System.put_env(key, value)

  defp production_environment(c) do
    Map.new(@required_env, fn key -> {key, "postgresql://fixture@127.0.0.1:1/fixture"} end)
    |> Map.merge(%{
      "SECRET_KEY_BASE" => String.duplicate("fixture-only-", 8),
      "SINGULARITY_BACKUP_ROOT" => c.context.backup_root,
      "SINGULARITY_STORAGE_ROOT" => c.context.storage_root,
      "SINGULARITY_AUDIT_FINGERPRINT_SECRET" => Base.encode64(:binary.copy(<<1>>, 32)),
      "SINGULARITY_MUTATION_FINGERPRINT_SECRET" => Base.encode64(:binary.copy(<<2>>, 32)),
      "SINGULARITY_EXPORT_ROOT" => nil,
      "SINGULARITY_MAX_CONCURRENT_UPLOADS" => nil,
      "PHX_HOST" => "fixture.invalid",
      "PORT" => "4000"
    })
  end
end
