defmodule Singularity.Storage.Backup.KnowledgeFixtureLifecycleTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Storage.Backup.KnowledgeBackupFixtures
  alias Singularity.Storage.Backup.KnowledgeFixtureResourceOwner, as: ResourceOwner
  alias Singularity.Storage.Backup.{BundleReader, KnowledgePreflight}
  alias Singularity.Storage.{Fixtures, LocalFilesystemAdapter, TestEnvironment}
  alias Singularity.Storage.MigrationRepo

  @wake_version 20_260_901_000_200
  @wake_migration Singularity.Storage.Migrations.MoveWakeGenerationsToJobSubmissions

  @repos [
    MigrationRepo,
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]
  @apps [:singularity_storage, :singularity_runtime]
  @replays {KnowledgeBackupFixtures, :replays}
  @originals %{
    pdf: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    pdf_duplicate: "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n",
    empty: "",
    plain: "plain original\r\nsecond line\n",
    unicode: "界🙂 café\n",
    markdown: "# Original Markdown\n\n[source](https://example.test/)\n"
  }
  @ids ~w(
    account_id principal_id vault_id session_id live_note_id deleted_note_id
    initial_note_version_id canonical_note_version_id competing_note_version_id
    merge_note_version_id open_competing_note_version_id deleted_note_version_id
    resolved_conflict_id open_conflict_id ready_document_id ready_old_version_id
    ready_current_version_id deleted_document_id deleted_document_version_id
    pending_document_id pending_version_id extracting_document_id extracting_version_id
    failed_document_id failed_version_id unsupported_document_id unsupported_version_id
    attachment_id citation_id deleted_attachment_id deleted_citation_id tag_id
    relationship_id pdf_object_id empty_object_id plain_object_id unicode_object_id
    markdown_object_id
  )a
       |> Enum.with_index(1)
       |> Map.new(fn {name, index} ->
         {name,
          "50000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0")}
       end)

  defmodule InfrastructureProbe do
    use GenServer

    def start_link(options), do: GenServer.start_link(__MODULE__, options)

    @impl true
    def init(options) do
      Process.flag(:trap_exit, true)
      {:ok, options}
    end

    @impl true
    def terminate(_reason, %{test: test, token: token, repos: repos}) do
      live =
        Map.new(repos, fn {repo, pid} ->
          {repo, Process.whereis(repo) == pid and Process.alive?(pid)}
        end)

      send(test, {token, :infrastructure_stopped, self(), live})
      :ok
    end
  end

  defmodule FailingInfrastructureChild do
    def child_spec(_options),
      do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}

    def start_link(_options), do: {:error, :native_fixture_startup_probe}
  end

  test "owned infrastructure startup preserves Repo PIDs and stops children before Repo cleanup" do
    Code.ensure_loaded!(ResourceOwner)
    assert function_exported?(ResourceOwner, :start_infrastructure, 2)
    baseline = baseline()
    maintenance = maintenance()
    {owner, destination} = ResourceOwner.open(migration_pool_size: 2)
    repos = Map.new(@repos, &{&1, Process.whereis(&1)})
    token = make_ref()

    try do
      assert {:ok, supervisor} =
               apply(ResourceOwner, :start_infrastructure, [
                 owner,
                 [{InfrastructureProbe, %{test: self(), token: token, repos: repos}}]
               ])

      assert is_pid(supervisor) and Process.alive?(supervisor)
      assert Map.new(@repos, &{&1, Process.whereis(&1)}) == repos
      for repo <- @repos, do: assert(current_database(repo) == destination.database)
      assert {:error, :already_started} = apply(ResourceOwner, :start_infrastructure, [owner, []])

      assert {:error, :not_owner} =
               Task.async(fn -> apply(ResourceOwner, :start_infrastructure, [owner, []]) end)
               |> Task.await()

      Application.put_env(:singularity_runtime, :native_fixture_absent_probe, token)
      Application.delete_env(:singularity_runtime, :key_custodian)
      :ok = ResourceOwner.close(owner)
      refute Process.alive?(supervisor)
      assert_receive {^token, :infrastructure_stopped, _child, live}, 1_000
      assert live == Map.new(@repos, &{&1, true})

      assert_cleanup(
        maintenance,
        %{
          database: destination.database,
          storage_root: Path.dirname(destination.object_root),
          repos: repos
        },
        baseline,
        System.monotonic_time(:millisecond) + 10_000,
        "owned infrastructure normal cleanup"
      )
    after
      ResourceOwner.close(owner)
    end
  end

  test "a partial infrastructure startup failure replies on its own request and remains cleanable" do
    baseline = baseline()
    maintenance = maintenance()
    {owner, destination} = ResourceOwner.open(migration_pool_size: 2)
    repos = Map.new(@repos, &{&1, Process.whereis(&1)})
    token = make_ref()

    try do
      assert {:error, {:native_fixture_startup_probe, _child}} =
               apply(ResourceOwner, :start_infrastructure, [
                 owner,
                 [
                   {InfrastructureProbe, %{test: self(), token: token, repos: repos}},
                   FailingInfrastructureChild
                 ]
               ])

      assert Map.new(@repos, &{&1, Process.whereis(&1)}) == repos
      :ok = ResourceOwner.close(owner)
      assert_receive {^token, :infrastructure_stopped, _child, live}, 1_000
      assert live == Map.new(@repos, &{&1, true})

      assert_cleanup(
        maintenance,
        %{
          database: destination.database,
          storage_root: Path.dirname(destination.object_root),
          repos: repos
        },
        baseline,
        System.monotonic_time(:millisecond) + 10_000,
        "partial infrastructure startup cleanup"
      )
    after
      ResourceOwner.close(owner)
    end
  end

  for outcome <- [:raise, :kill] do
    test "owned infrastructure cleans after its original caller #{outcome}" do
      baseline = baseline()
      maintenance = maintenance()
      parent = self()
      token = make_ref()

      {actor, actor_monitor} =
        spawn_monitor(fn ->
          parent_monitor = Process.monitor(parent)

          checkpoint = fn
            :before_arm, %{owner: owner} -> send(parent, {token, :infrastructure_owner, owner})
            _stage, _resources -> :ok
          end

          ResourceOwner.with_checkpoint(checkpoint, fn ->
            {owner, destination} = ResourceOwner.open(migration_pool_size: 2)
            repos = Map.new(@repos, &{&1, Process.whereis(&1)})

            try do
              assert {:ok, supervisor} =
                       apply(ResourceOwner, :start_infrastructure, [
                         owner,
                         [{InfrastructureProbe, %{test: parent, token: token, repos: repos}}]
                       ])

              send(parent, {token, :infrastructure_ready, supervisor, destination, repos})

              receive do
                {^token, :raise} -> raise "native fixture caller probe"
                {^token, :release} -> :ok
                {:DOWN, ^parent_monitor, :process, ^parent, _reason} -> :ok
              end
            after
              ResourceOwner.close(owner)
            end
          end)
        end)

      ready_deadline = System.monotonic_time(:millisecond) + 30_000

      try do
        assert_receive {^token, :infrastructure_owner, owner}, 30_000
        owner_monitor = Process.monitor(owner)

        try do
          ready_timeout = max(ready_deadline - System.monotonic_time(:millisecond), 0)

          assert_receive {^token, :infrastructure_ready, supervisor, destination, repos},
                         ready_timeout

          case unquote(outcome) do
            :raise -> send(actor, {token, :raise})
            :kill -> Process.exit(actor, :kill)
          end

          assert_receive {:DOWN, ^actor_monitor, :process, ^actor, reason}, 15_000

          if unquote(outcome) == :kill,
            do: assert(reason == :killed),
            else:
              assert(
                match?({%RuntimeError{message: "native fixture caller probe"}, _stack}, reason)
              )

          deadline = System.monotonic_time(:millisecond) + 10_000
          assert_receive {^token, :infrastructure_stopped, _child, live}, 1_000
          assert live == Map.new(@repos, &{&1, true})

          # The probe sends from inside terminate/2. Only the owner's exit
          # acknowledges supervisor shutdown and the rest of resource cleanup.
          timeout = max(deadline - System.monotonic_time(:millisecond), 0)
          assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, timeout
          refute Process.alive?(supervisor)

          assert_cleanup(
            maintenance,
            %{
              database: destination.database,
              storage_root: Path.dirname(destination.object_root),
              repos: repos
            },
            baseline,
            deadline,
            "owned infrastructure caller cleanup"
          )
        after
          send(actor, {token, :release})

          assert_process_stopped(
            owner,
            System.monotonic_time(:millisecond) + 10_000,
            "owned infrastructure parent bracket did not finish owner cleanup"
          )

          Process.demonitor(owner_monitor, [:flush])
        end
      after
        send(actor, {token, :release})

        assert_process_stopped(
          actor,
          System.monotonic_time(:millisecond) + 15_000,
          "owned infrastructure parent bracket did not release its actor"
        )

        Process.demonitor(actor_monitor, [:flush])
      end
    end
  end

  test "killing the destination callback caller cleans its resources and restores the baseline" do
    baseline = %{
      configs: application_configs(),
      compiler_options: Code.compiler_options(),
      repos: Map.new(@repos, &{&1, Process.whereis(&1)}),
      repo_databases:
        Map.new(
          for repo <- @repos, is_pid(Process.whereis(repo)), do: {repo, current_database(repo)}
        ),
      runtime_started?: runtime_started?()
    }

    maintenance_options =
      MigrationRepo.config()
      |> Keyword.drop([:url, :name])
      |> Keyword.put(:database, "postgres")

    maintenance = start_supervised!({Postgrex, maintenance_options})
    test_pid = self()
    token = make_ref()

    {actor, actor_monitor} =
      spawn_monitor(fn ->
        test_monitor = Process.monitor(test_pid)

        KnowledgeBackupFixtures.with_destination(:current, fn destination ->
          repos = Map.new(@repos, &{&1, Process.whereis(&1)})
          send(test_pid, {token, :callback_ready, self(), destination, repos})

          # If an assertion fails before the deliberate kill, let the existing
          # normal-return bracket clean up after the containing test exits.
          receive do
            {:DOWN, ^test_monitor, :process, ^test_pid, _reason} -> :ok
          end
        end)
      end)

    {destination, repos} =
      receive do
        {^token, :callback_ready, ^actor, destination, repos} ->
          {destination, repos}

        {:DOWN, ^actor_monitor, :process, ^actor, reason} ->
          flunk("fixture actor exited before reaching its callback: #{inspect(reason)}")
      after
        30_000 -> flunk("fixture actor #{inspect(actor)} did not reach its callback")
      end

    resources = %{
      actor: actor,
      database: destination.database,
      storage_root: Path.dirname(destination.object_root),
      object_root: destination.object_root,
      repos: repos
    }

    evidence = "exact callback fixture resources: #{inspect(resources, limit: :infinity)}"
    assert destination.repo == MigrationRepo, evidence
    assert resources.database =~ ~r/\Asingularity_test_[0-9a-f]{24}\z/, evidence
    assert File.dir?(resources.object_root), evidence
    assert database_exists?(maintenance, resources.database) == true, evidence

    repo_monitors =
      for {repo, pid} <- repos do
        assert is_pid(pid) and Process.alive?(pid), evidence
        refute pid == baseline.repos[repo], evidence

        assert current_database(repo) == resources.database, evidence
        {pid, Process.monitor(pid)}
      end

    Process.exit(actor, :kill)
    assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :killed}, 1_000, evidence

    deadline = System.monotonic_time(:millisecond) + 10_000
    assert_cleanup(maintenance, resources, baseline, deadline, evidence)

    for {pid, monitor} <- repo_monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000, evidence
    end

    for {repo, database} <- baseline.repo_databases do
      assert current_database(repo) == database, evidence
    end
  end

  for stage <- [
        :before_arm,
        :before_allocation,
        :allocated,
        :database_created,
        :root_created,
        {:repo_started, Singularity.Storage.RequestRepo, :destination}
      ] do
    database_created? = stage in [:database_created, :root_created]
    root_created? = stage == :root_created

    test "caller death at #{inspect(stage)} unwinds only completed acquisition stages" do
      baseline = baseline()
      maintenance = maintenance()
      {actor, actor_monitor, token, resources} = stage_actor(unquote(Macro.escape(stage)))
      owner = resources.owner
      owner_monitor = Process.monitor(owner)
      evidence = evidence(resources)

      if names = Map.get(resources, :names) do
        if unquote(database_created?) do
          assert database_exists?(maintenance, names.database) == true, evidence
        end

        if unquote(root_created?) do
          assert File.dir?(Path.join(names.storage_root, "objects")), evidence
        end
      end

      Process.exit(actor, :kill)
      assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :killed}, 1_000, evidence
      send(owner, {token, :continue})
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 15_000, evidence
      assert_stage_cleanup(maintenance, resources, baseline)
    end
  end

  test "a real blocked migration settles before caller-death cleanup starts" do
    baseline = baseline()
    maintenance = maintenance()
    connection_options = MigrationRepo.config() |> Keyword.drop([:url, :name])
    {actor, actor_monitor, token, resources} = stage_actor(:before_migration)
    owner = resources.owner
    owner_monitor = Process.monitor(owner)
    database = resources.names.database
    evidence = evidence(resources)
    {:ok, locker} = Postgrex.start_link(Keyword.put(connection_options, :database, database))

    try do
      Postgrex.query!(
        locker,
        "CREATE TABLE IF NOT EXISTS schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp(0))",
        []
      )

      assert {:error, :lock_released} =
               Postgrex.transaction(locker, fn connection ->
                 Postgrex.query!(
                   connection,
                   "LOCK TABLE schema_migrations IN ACCESS EXCLUSIVE MODE",
                   []
                 )

                 send(owner, {token, :continue})

                 await(
                   fn ->
                     %{rows: [[waiting]]} =
                       Postgrex.query!(
                         maintenance,
                         "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND wait_event_type='Lock' AND query LIKE '%schema_migrations%')",
                         [database]
                       )

                     waiting
                   end,
                   evidence <> " migration never reached the actual PostgreSQL lock"
                 )

                 Process.exit(actor, :kill)

                 assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :killed},
                                1_000,
                                evidence

                 assert Process.alive?(owner), evidence
                 assert Process.alive?(resources.repos[MigrationRepo]), evidence
                 assert database_exists?(maintenance, database) == true, evidence
                 assert File.dir?(resources.names.storage_root), evidence
                 Postgrex.rollback(connection, :lock_released)
               end)
    after
      if Process.alive?(locker), do: GenServer.stop(locker)
    end

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 20_000, evidence
    assert_stage_cleanup(maintenance, resources, baseline)
  end

  test "an acquisition exception is preserved after exact cleanup outside ExUnit" do
    baseline = baseline()
    maintenance = maintenance()
    {actor, actor_monitor, token, resources} = stage_actor(:root_created)
    owner = resources.owner
    owner_monitor = Process.monitor(owner)
    send(owner, {token, :raise})

    assert_receive {^token, :outcome,
                    {:error, %RuntimeError{message: "lifecycle acquisition probe"}}},
                   15_000,
                   evidence(resources)

    assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :normal}, 1_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000
    assert_stage_cleanup(maintenance, resources, baseline)
  end

  test "the owner survives a known linked Repo failure during acquisition" do
    baseline = baseline()
    maintenance = maintenance()

    {actor, actor_monitor, token, resources} =
      stage_actor({:repo_started, MigrationRepo, :migration})

    owner = resources.owner
    owner_monitor = Process.monitor(owner)
    repo = resources.repos[MigrationRepo]
    repo_monitor = Process.monitor(repo)
    Process.exit(repo, :kill)
    assert_receive {:DOWN, ^repo_monitor, :process, ^repo, :killed}, 1_000
    assert Process.alive?(owner)
    send(owner, {token, :continue})

    assert_receive {^token, :outcome,
                    {:error,
                     %RuntimeError{message: "fixture repository exited during acquisition"}}},
                   15_000,
                   evidence(resources)

    assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :normal}, 1_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000
    assert_stage_cleanup(maintenance, resources, baseline)
  end

  for outcome <- [:normal, :raise, :throw, :exit] do
    test "#{outcome} callback releases synchronously for a non-ExUnit caller" do
      baseline = baseline()
      maintenance = maintenance()

      callback = fn _destination ->
        case unquote(outcome) do
          :normal -> :fixture_return
          :raise -> raise "lifecycle callback probe"
          :throw -> throw(:fixture_throw)
          :exit -> exit(:fixture_exit)
        end
      end

      {actor, actor_monitor, token, resources} = stage_actor(:ready, callback)
      owner = resources.owner
      owner_monitor = Process.monitor(owner)
      send(owner, {token, :continue})

      expected =
        case unquote(outcome) do
          :normal -> {:return, :fixture_return}
          :raise -> {:error, %RuntimeError{message: "lifecycle callback probe"}}
          :throw -> {:throw, :fixture_throw}
          :exit -> {:exit, :fixture_exit}
        end

      assert_receive {^token, :outcome, ^expected}, 15_000, evidence(resources)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000
      assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :normal}, 1_000
      assert_stage_cleanup(maintenance, resources, baseline)

      # Manually restarted baseline Repos must not die with their temporary owner.
      for {repo, database} <- baseline.repo_databases do
        assert current_database(repo) == database
      end
    end
  end

  test "registered release retains only its receipt until on_exit and is idempotent" do
    baseline = baseline()
    caller = self()
    observer = make_ref()
    on_exit(observer, fn -> :ok end)

    checkpoint = fn
      :before_arm, %{owner: owner} ->
        assert self() == caller
        send(caller, {:registered_owner, owner})
        # Replacing this earlier callback preserves its position: it runs after
        # the fixture's later-registered completion callback.
        on_exit(observer, fn -> refute Process.alive?(owner) end)

      _stage, _resources ->
        :ok
    end

    assert :fixture_return ==
             ResourceOwner.with_checkpoint(checkpoint, fn ->
               KnowledgeBackupFixtures.with_destination(:current, fn _destination ->
                 assert self() == caller
                 Application.put_env(:singularity_storage, :fixture_lifecycle_new_key, :temporary)
                 Application.put_env(:singularity_runtime, :fixture_lifecycle_new_key, :temporary)
                 :fixture_return
               end)
             end)

    assert_receive {:registered_owner, owner}
    assert Process.alive?(owner)
    assert application_configs() == baseline.configs
    assert Code.compiler_options() == baseline.compiler_options
    saved = Application.fetch_env(:singularity_storage, :fixture_lifecycle_after_close)

    try do
      Application.put_env(:singularity_storage, :fixture_lifecycle_after_close, :later_state)
      :ok = ResourceOwner.close(owner)
      assert Process.alive?(owner)

      assert Application.fetch_env(:singularity_storage, :fixture_lifecycle_after_close) ==
               {:ok, :later_state}
    after
      case saved do
        {:ok, value} ->
          Application.put_env(:singularity_storage, :fixture_lifecycle_after_close, value)

        :error ->
          Application.delete_env(:singularity_storage, :fixture_lifecycle_after_close)
      end
    end

    assert application_configs() == baseline.configs
  end

  test "an unknown named replacement is preserved and cleanup failure is observable" do
    assert Process.whereis(MigrationRepo) == nil
    baseline = baseline()
    maintenance = maintenance()
    parent = self()

    callback = fn _destination ->
      parent_monitor = Process.monitor(parent)
      send(parent, {:replacement_callback, self()})

      receive do
        :release_fixture -> :ok
        {:DOWN, ^parent_monitor, :process, ^parent, _reason} -> :ok
      end
    end

    {actor, actor_monitor, token, resources} = stage_actor(:ready, callback)
    owner = resources.owner
    owner_monitor = Process.monitor(owner)
    send(owner, {token, :continue})
    assert_receive {:replacement_callback, ^actor}, 1_000
    Supervisor.stop(resources.repos[MigrationRepo])

    foreign =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    foreign_monitor = Process.monitor(foreign)
    true = Process.register(foreign, MigrationRepo)

    try do
      send(actor, :release_fixture)

      assert_receive {^token, :outcome,
                      {:error, %ResourceOwner.CleanupError{failures: failures}}},
                     15_000,
                     evidence(resources)

      assert {:unexpected_repository, MigrationRepo, foreign} in failures

      assert_receive {:DOWN, ^owner_monitor, :process, ^owner,
                      {:fixture_cleanup_failed, ^failures}},
                     1_000

      assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :normal}, 1_000
      assert Process.whereis(MigrationRepo) == foreign
      assert Process.alive?(foreign)
      assert database_exists?(maintenance, resources.names.database) == false
      refute File.exists?(resources.names.storage_root)
      assert application_configs() == baseline.configs
      assert Code.compiler_options() == baseline.compiler_options
      assert runtime_started?() == baseline.runtime_started?
      assert Enum.all?(resources.owned_repos, fn {_repo, pid} -> not Process.alive?(pid) end)
    after
      send(foreign, :stop)
      assert_receive {:DOWN, ^foreign_monitor, :process, ^foreign, :normal}, 1_000
    end
  end

  test "negative on_exit acknowledges the exact retained failure and stops the owner" do
    assert Process.whereis(MigrationRepo) == nil
    baseline = baseline()
    caller = self()

    options =
      MigrationRepo.config() |> Keyword.drop([:url, :name]) |> Keyword.put(:database, "postgres")

    {:ok, observer_connection} = Postgrex.start_link(options)
    Process.unlink(observer_connection)
    observer_cleanup = make_ref()

    on_exit(observer_cleanup, fn ->
      if Process.alive?(observer_connection), do: GenServer.stop(observer_connection)
    end)

    checkpoint = fn
      :before_arm, %{owner: owner, on_exit: {id, cleanup}} ->
        assert self() == caller
        Process.put({__MODULE__, :negative_cleanup}, {owner, id, cleanup})

      :ready, resources ->
        send(caller, {:negative_resources, resources})

      _, _ ->
        :ok
    end

    error =
      assert_raise ResourceOwner.CleanupError, fn ->
        ResourceOwner.with_checkpoint(checkpoint, fn ->
          KnowledgeBackupFixtures.with_destination(:current, fn _destination ->
            owned = Process.whereis(MigrationRepo)
            Supervisor.stop(owned)

            foreign =
              spawn(fn ->
                receive do
                  :stop -> :ok
                end
              end)

            true = Process.register(foreign, MigrationRepo)
            Process.put({__MODULE__, :negative_foreign}, foreign)
          end)
        end)
      end

    {owner, id, cleanup} = Process.delete({__MODULE__, :negative_cleanup})
    foreign = Process.delete({__MODULE__, :negative_foreign})
    assert_receive {:negative_resources, resources}
    assert error.failures == [{:unexpected_repository, MigrationRepo, foreign}]
    assert Process.alive?(owner)
    repeated = assert_raise ResourceOwner.CleanupError, fn -> ResourceOwner.close(owner) end
    assert repeated.failures == error.failures
    assert application_configs() == baseline.configs
    assert database_exists?(observer_connection, resources.names.database) == false
    refute File.exists?(resources.names.storage_root)

    on_exit(id, fn ->
      owner_monitor = Process.monitor(owner)
      foreign_monitor = Process.monitor(foreign)

      try do
        observed = assert_raise ResourceOwner.CleanupError, cleanup
        assert observed.failures == error.failures
        assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000
        assert Process.whereis(MigrationRepo) == foreign
        assert Process.alive?(foreign)
        assert Process.alive?(observer_connection)
        assert database_exists?(observer_connection, resources.names.database) == false
        refute File.exists?(resources.names.storage_root)
        assert Enum.all?(resources.owned_repos, fn {_repo, pid} -> not Process.alive?(pid) end)
        assert application_configs() == baseline.configs
        assert Code.compiler_options() == baseline.compiler_options
        assert runtime_started?() == baseline.runtime_started?
      after
        send(foreign, :stop)
        assert_receive {:DOWN, ^foreign_monitor, :process, ^foreign, :normal}, 1_000
      end
    end)
  end

  test "independent database, unnamed connection, root and process survive callback death" do
    baseline = baseline()
    maintenance = maintenance()
    sentinel = TestEnvironment.allocate!()
    Postgrex.query!(maintenance, "CREATE DATABASE \"#{sentinel.database}\"", [])
    File.mkdir_p!(sentinel.storage_root)
    sentinel_path = Path.join(sentinel.storage_root, "independent")
    File.write!(sentinel_path, "independent fixture sentinel", [:exclusive])

    unrelated =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    unrelated_monitor = Process.monitor(unrelated)

    try do
      parent = self()

      callback = fn _destination ->
        parent_monitor = Process.monitor(parent)
        send(parent, {:sentinel_callback, self()})

        receive do
          {:DOWN, ^parent_monitor, :process, ^parent, _} -> :ok
        end
      end

      {actor, actor_monitor, token, resources} = stage_actor(:ready, callback)
      owner = resources.owner
      owner_monitor = Process.monitor(owner)
      send(owner, {token, :continue})
      assert_receive {:sentinel_callback, ^actor}, 1_000
      Process.exit(actor, :kill)
      assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :killed}, 1_000

      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal},
                     15_000,
                     evidence(resources)

      assert_stage_cleanup(maintenance, resources, baseline)
      assert database_exists?(maintenance, sentinel.database) == true
      assert Process.alive?(maintenance)
      assert File.read!(sentinel_path) == "independent fixture sentinel"
      assert Process.alive?(unrelated)
    after
      send(unrelated, :stop)
      assert_receive {:DOWN, ^unrelated_monitor, :process, ^unrelated, :normal}, 1_000
      Postgrex.query!(maintenance, "DROP DATABASE \"#{sentinel.database}\"", [])
      File.rm_rf!(sentinel.storage_root)
    end
  end

  for collision <- [:database, :root] do
    test "a generated #{collision} collision is not adopted or removed" do
      baseline = baseline()
      maintenance = maintenance()
      {actor, actor_monitor, token, resources} = stage_actor(:allocated)
      owner = resources.owner
      owner_monitor = Process.monitor(owner)
      names = resources.names
      sentinel = Path.join(names.storage_root, "collision-sentinel")

      case unquote(collision) do
        :database ->
          Postgrex.query!(maintenance, "CREATE DATABASE \"#{names.database}\"", [])

        :root ->
          File.mkdir_p!(names.storage_root)
          File.write!(sentinel, "not claimed by fixture", [:exclusive])
      end

      try do
        send(owner, {token, :continue})
        assert_receive {^token, :outcome, {:error, error}}, 15_000, evidence(resources)

        case unquote(collision) do
          :database ->
            assert %Postgrex.Error{postgres: %{code: :duplicate_database}} = error
            assert database_exists?(maintenance, names.database) == true
            refute File.exists?(names.storage_root)

          :root ->
            assert %MatchError{term: {:error, :eexist}} = error
            assert database_exists?(maintenance, names.database) == false
            assert File.read!(sentinel) == "not claimed by fixture"
        end

        assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000
        assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :normal}, 1_000
        assert application_configs() == baseline.configs
        assert Code.compiler_options() == baseline.compiler_options
        assert runtime_started?() == baseline.runtime_started?
      after
        case unquote(collision) do
          :database -> Postgrex.query!(maintenance, "DROP DATABASE \"#{names.database}\"", [])
          :root -> File.rm_rf!(names.storage_root)
        end
      end
    end
  end

  test "manually running baseline Repo is restarted detached from the temporary owner" do
    assert Process.whereis(MigrationRepo) == nil
    {:ok, original} = MigrationRepo.start_link()
    Process.unlink(original)
    baseline = baseline()
    maintenance = maintenance()

    try do
      {actor, actor_monitor, token, resources} = stage_actor(:ready)
      owner = resources.owner
      owner_monitor = Process.monitor(owner)
      send(owner, {token, :continue})
      assert_receive {^token, :outcome, {:return, :fixture_return}}, 15_000, evidence(resources)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000
      assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :normal}, 1_000
      assert_stage_cleanup(maintenance, resources, baseline)
      restored = Process.whereis(MigrationRepo)
      refute restored == original
      assert Process.alive?(restored)
      assert current_database(MigrationRepo) == baseline.repo_databases[MigrationRepo]
      {:links, links} = Process.info(restored, :links)
      refute owner in links
    after
      if pid = Process.whereis(MigrationRepo), do: Supervisor.stop(pid)
    end
  end

  test "an initially stopped Runtime and absent Repos remain stopped and absent" do
    original = baseline()
    if original.runtime_started?, do: Application.stop(:singularity_runtime)

    for {repo, previous} <- original.repos do
      if is_pid(previous) and Process.whereis(repo) == previous, do: Supervisor.stop(previous)
    end

    baseline = baseline()
    maintenance = maintenance()

    try do
      refute baseline.runtime_started?
      assert Enum.all?(baseline.repos, fn {_repo, pid} -> is_nil(pid) end)
      {actor, actor_monitor, token, resources} = stage_actor(:ready)
      owner = resources.owner
      owner_monitor = Process.monitor(owner)
      send(owner, {token, :continue})
      assert_receive {^token, :outcome, {:return, :fixture_return}}, 15_000, evidence(resources)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000
      assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :normal}, 1_000
      assert_stage_cleanup(maintenance, resources, baseline)
      refute runtime_started?()
      assert Enum.all?(@repos, &(Process.whereis(&1) == nil))
    after
      if original.runtime_started?, do: Application.ensure_all_started(:singularity_runtime)

      for {repo, previous} <- original.repos, is_pid(previous), Process.whereis(repo) == nil do
        {:ok, pid} = repo.start_link()
        Process.unlink(pid)
      end
    end
  end

  test "authenticated Replay staging and validation keep the original caller and native transaction" do
    caller = self()
    Process.put(@replays, :outer_replay_sentinel)

    try do
      KnowledgeBackupFixtures.with_destination(:current, fn destination ->
        assert self() == caller
        assert Process.get(@replays) == []
        fixture = seed(destination)
        assert {:ok, bundle} = KnowledgeBackupFixtures.transformed_bundle(fixture, [])

        assert %BundleReader.Verified{
                 replay: %BundleReader.Replay{},
                 authentication: authentication
               } = bundle.verified

        assert is_map(authentication)
        assert Process.get(@replays) == [bundle.verified]
        root = Path.join(destination.object_root, "native-preflight")
        File.mkdir!(root)
        File.chmod!(root, 0o700)
        storage = %{module: LocalFilesystemAdapter, context: %{root: root}}

        assert {:error, :inspected} ==
                 MigrationRepo.transaction(fn ->
                   Ecto.Adapters.SQL.query!(
                     MigrationRepo,
                     "SET LOCAL ROLE singularity_table_owner",
                     [],
                     log: false
                   )

                   before = native_binding()

                   assert {:ok, staged} =
                            KnowledgePreflight.stage(
                              MigrationRepo,
                              bundle.verified,
                              bundle.cut,
                              storage
                            )

                   assert staged.caller == caller
                   assert staged.connection == before

                   assert {:ok, summary} =
                            KnowledgePreflight.validate(MigrationRepo, staged, bundle.cut)

                   assert map_size(summary.digests) == 38
                   assert native_binding() == before
                   assert self() == caller

                   assert {:error, _closed} =
                            :file.pread(bundle.verified.replay.snapshot.device, 0, 1)

                   MigrationRepo.rollback(:inspected)
                 end)
      end)

      assert Process.get(@replays) == :outer_replay_sentinel
    after
      Process.delete(@replays)
    end
  end

  test "unused Replay is discarded in its caller before infrastructure release" do
    caller = self()

    device =
      KnowledgeBackupFixtures.with_destination(:current, fn destination ->
        assert self() == caller
        assert {:ok, bundle} = KnowledgeBackupFixtures.transformed_bundle(seed(destination), [])
        device = bundle.verified.replay.snapshot.device
        assert {:ok, <<"S">>} = :file.pread(device, 0, 1)
        device
      end)

    assert {:error, _closed} = :file.pread(device, 0, 1)
    assert Process.get(@replays) == nil
  end

  test "a killed Replay caller loses its actual raw descriptor without transferring authority" do
    baseline = baseline()
    maintenance = maintenance()
    parent = self()

    callback = fn destination ->
      assert {:ok, bundle} = KnowledgeBackupFixtures.transformed_bundle(seed(destination), [])
      assert {:ok, <<"S">>} = :file.pread(bundle.verified.replay.snapshot.device, 0, 1)
      path = Path.join(destination.object_root, bundle.binding.destination_ref)
      parent_monitor = Process.monitor(parent)
      # Send only the filename: neither Replay authority nor its raw descriptor
      # is copied to the surviving fixture owner or the observation process.
      send(parent, {:raw_snapshot_open, self(), path})

      receive do
        {:DOWN, ^parent_monitor, :process, ^parent, _} -> :ok
      end
    end

    {actor, actor_monitor, token, resources} = stage_actor(:ready, callback)
    owner = resources.owner
    owner_monitor = Process.monitor(owner)
    send(owner, {token, :continue})
    assert_receive {:raw_snapshot_open, ^actor, path}, 20_000, evidence(resources)
    assert raw_descriptor_open?(path), evidence(resources)
    Process.exit(actor, :kill)
    assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :killed}, 1_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 15_000, evidence(resources)

    await(
      fn -> not raw_descriptor_open?(path) end,
      evidence(resources) <> " raw descriptor survived caller death"
    )

    assert_stage_cleanup(maintenance, resources, baseline)
  end

  test "Replay discard exceptions cannot skip infrastructure release or dictionary restoration" do
    baseline = baseline()
    maintenance = maintenance()
    caller = self()

    checkpoint = fn
      :ready, resources -> send(caller, {:discard_resources, resources})
      _, _ -> :ok
    end

    Process.put(@replays, :outer_replay_sentinel)

    try do
      assert_raise Protocol.UndefinedError, fn ->
        ResourceOwner.with_checkpoint(checkpoint, fn ->
          KnowledgeBackupFixtures.with_destination(:current, fn _ ->
            Process.put(@replays, :not_enumerable)
          end)
        end)
      end

      assert_receive {:discard_resources, resources}
      assert_stage_cleanup(maintenance, resources, baseline)
      assert Process.get(@replays) == :outer_replay_sentinel
    after
      Process.delete(@replays)
    end
  end

  test "ordinary DROP retries a real connection arriving after the zero-session snapshot" do
    baseline = baseline()
    maintenance = maintenance()
    connection_options = MigrationRepo.config() |> Keyword.drop([:url, :name, :pool_size])
    parent = self()
    token = make_ref()

    {actor, actor_monitor} =
      spawn_monitor(fn ->
        checkpoint = fn
          stage, resources when stage in [:before_database_drop, :database_drop_in_use] ->
            parent_monitor = Process.monitor(parent)
            send(parent, {token, stage, resources})

            try do
              receive do
                {^token, :continue} -> :ok
                {:DOWN, ^parent_monitor, :process, ^parent, _reason} -> :ok
              end
            after
              Process.demonitor(parent_monitor, [:flush])
            end

          _, _ ->
            :ok
        end

        outcome =
          try do
            {:return,
             ResourceOwner.with_checkpoint(checkpoint, fn ->
               KnowledgeBackupFixtures.with_destination(:current, fn destination ->
                 send(parent, {token, :callback, self(), destination})
                 :fixture_return
               end)
             end)}
          catch
            :error, reason -> {:error, Exception.normalize(:error, reason, __STACKTRACE__)}
            kind, reason -> {kind, reason}
          end

        send(parent, {token, :outcome, outcome})
      end)

    assert_receive {^token, :before_database_drop, resources}, 30_000
    owner = resources.owner
    owner_monitor = Process.monitor(owner)
    names = resources.names
    database = names.database
    evidence = evidence(resources)
    assert resources.caller == actor, evidence

    assert_receive {^token, :callback, ^actor,
                    %{repo: MigrationRepo, database: ^database, object_root: object_root}},
                   1_000,
                   evidence

    assert object_root == Path.join(names.storage_root, "objects"), evidence

    %{rows: [[0]]} =
      Postgrex.query!(
        maintenance,
        "SELECT count(*) FROM pg_catalog.pg_stat_activity WHERE datname=$1",
        [database]
      )

    # Keep the native connection linked to this test so its death also releases
    # the connection while every observer barrier independently monitors us.
    {:ok, probe} = Postgrex.start_link(Keyword.put(connection_options, :database, database))
    probe_monitor = Process.monitor(probe)

    try do
      %{rows: [[backend, ^database]]} =
        Postgrex.query!(probe, "SELECT pg_backend_pid(), current_database()", [])

      assert is_integer(backend), evidence

      assert %{rows: [[^backend]]} =
               Postgrex.query!(
                 maintenance,
                 "SELECT pid FROM pg_catalog.pg_stat_activity WHERE datname=$1",
                 [database]
               )

      send(owner, {token, :continue})

      assert_receive {^token, :database_drop_in_use,
                      %{
                        owner: ^owner,
                        names: ^names,
                        error: %Postgrex.Error{
                          postgres: %{code: :object_in_use, pg_code: "55006"}
                        }
                      }},
                     15_000,
                     evidence

      assert Process.alive?(owner), evidence
      assert database_exists?(maintenance, database) == true, evidence
      assert File.dir?(names.storage_root), evidence

      assert %{rows: [[^backend, ^database]]} =
               Postgrex.query!(probe, "SELECT pg_backend_pid(), current_database()", [])

      GenServer.stop(probe)
      assert_receive {:DOWN, ^probe_monitor, :process, ^probe, :normal}, 1_000, evidence
      send(owner, {token, :continue})

      assert_receive {^token, :before_database_drop, %{owner: ^owner, names: ^names}},
                     15_000,
                     evidence

      send(owner, {token, :continue})
      assert_receive {^token, :outcome, {:return, :fixture_return}}, 15_000, evidence
      assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :normal}, 1_000, evidence
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000, evidence
      assert_stage_cleanup(maintenance, resources, baseline)

      for {repo, original_database} <- baseline.repo_databases do
        assert current_database(repo) == original_database, evidence
      end
    after
      if Process.alive?(probe), do: GenServer.stop(probe)
      send(owner, {token, :continue})
    end
  end

  test "migration pool options reject unsupported settings before acquisition" do
    baseline = baseline()

    for options <- [[migration_pool_size: 1], [migration_pool_size: 3], [pool_size: 2]] do
      assert_raise FunctionClauseError, fn -> ResourceOwner.open(options) end
    end

    assert application_configs() == baseline.configs
    assert Map.new(@repos, &{&1, Process.whereis(&1)}) == baseline.repos
    assert runtime_started?() == baseline.runtime_started?
  end

  test "pool2 acquisition exception preserves its cause and restores the baseline" do
    baseline = baseline()
    maintenance = maintenance()
    caller = self()

    checkpoint = fn
      {:repo_started, MigrationRepo, :migration}, resources ->
        assert Keyword.fetch!(
                 Ecto.Repo.Registry.lookup(resources.repos[MigrationRepo]).opts,
                 :pool_size
               ) == 2

        send(caller, {:pool2_acquisition_resources, resources})
        raise "pool2 acquisition probe"

      _, _ ->
        :ok
    end

    assert_raise RuntimeError, "pool2 acquisition probe", fn ->
      ResourceOwner.with_checkpoint(checkpoint, fn ->
        ResourceOwner.open(migration_pool_size: 2)
      end)
    end

    assert_receive {:pool2_acquisition_resources, resources}
    assert_stage_cleanup(maintenance, resources, baseline)
  end

  for outcome <- [:normal, :raise, :kill] do
    test "pool2 Wake fixture preserves pending baseline and cleans sentinels after #{outcome}" do
      sentinel = prepare_wake_sentinels()
      baseline = baseline()
      parent = self()
      token = make_ref()

      {actor, actor_monitor} =
        spawn_monitor(fn ->
          parent_monitor = Process.monitor(parent)

          checkpoint = fn
            :before_arm, %{owner: owner} ->
              send(parent, {token, :unarmed, owner})

              receive do
                {^token, :continue} ->
                  :ok

                :release_fixture ->
                  raise "Wake sentinel containing test exited"

                {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
                  raise "Wake sentinel containing test exited"
              end

            {:repo_started, MigrationRepo, purpose}, resources ->
              pid = resources.repos[MigrationRepo]
              assert Keyword.fetch!(Ecto.Repo.Registry.lookup(pid).opts, :pool_size) == 2
              send(parent, {token, :pool2, purpose, pid})

            :ready, resources ->
              send(parent, {token, :resources, resources})

            _, _ ->
              :ok
          end

          result =
            try do
              ResourceOwner.with_checkpoint(checkpoint, fn ->
                {owner, destination} = ResourceOwner.open(migration_pool_size: 2)

                try do
                  refute destination.database == sentinel.database
                  assert current_database(MigrationRepo) == destination.database
                  repo = Process.whereis(MigrationRepo)
                  previous_dynamic = MigrationRepo.get_dynamic_repo()
                  %{one: fixture} = Fixtures.two_vaults!(repo)
                  assert MigrationRepo.get_dynamic_repo() == previous_dynamic
                  event = Fixtures.outbox_event!(fixture, repo)
                  assert MigrationRepo.get_dynamic_repo() == previous_dynamic
                  assert Process.whereis(MigrationRepo) == repo
                  assert Process.alive?(repo)
                  assert_borrowed_wake_rejections(fixture, repo)

                  assert :ok =
                           Ecto.Migrator.down(MigrationRepo, @wake_version, @wake_migration,
                             log: false
                           )

                  send(parent, {token, :prepared, destination, event.id})

                  receive do
                    :release_fixture ->
                      if unquote(outcome) == :raise, do: raise("Wake sentinel callback probe")
                      :fixture_return

                    {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
                      :fixture_return
                  end
                after
                  ResourceOwner.close(owner)
                end
              end)
            catch
              :error, error -> {:error, Exception.normalize(:error, error, __STACKTRACE__)}
            end

          send(parent, {token, :outcome, result})
        end)

      assert_receive {^token, :unarmed, owner}, 30_000
      owner_monitor = Process.monitor(owner)

      # Replace the pre-insertion callback without moving its earlier position.
      # The actor cannot acquire resources until this surviving fallback is armed.
      on_exit(sentinel.cleanup_id, fn ->
        monitor = Process.monitor(owner)
        send(actor, :release_fixture)

        assert_receive {:DOWN, ^monitor, :process, ^owner, reason}, 15_000
        assert reason in [:normal, :noproc]
        assert application_configs() == baseline.configs
        assert runtime_started?() == baseline.runtime_started?
        assert Process.whereis(MigrationRepo) == nil
        finish_wake_sentinels(sentinel)
      end)

      send(actor, {token, :continue})
      assert_receive {^token, :pool2, :migration, migration_pid}, 30_000
      assert_receive {^token, :pool2, :destination, destination_pid}, 30_000
      refute migration_pid == destination_pid
      refute Process.alive?(migration_pid)
      assert_receive {^token, :resources, resources}, 30_000
      assert_receive {^token, :prepared, destination, _event_id}, 30_000
      assert destination.database == resources.names.database
      assert pending_wake_rows(sentinel) == sentinel.rows

      if unquote(outcome) == :kill do
        Process.exit(actor, :kill)
        assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :killed}, 1_000
      else
        send(actor, :release_fixture)

        expected =
          if unquote(outcome) == :normal,
            do: :fixture_return,
            else: {:error, %RuntimeError{message: "Wake sentinel callback probe"}}

        assert_receive {^token, :outcome, ^expected}, 15_000
        assert_receive {:DOWN, ^actor_monitor, :process, ^actor, :normal}, 1_000
      end

      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 15_000
      assert_stage_cleanup(sentinel.connection, resources, baseline)
      assert pending_wake_rows(sentinel) == sentinel.rows
      assert wake_schema_rows(sentinel.connection) == sentinel.schema_rows
      # The registered fallback now proves exact sentinel removal, preservation
      # of the unrelated row until its separate teardown, and Runtime restoration.
    end
  end

  defp prepare_wake_sentinels do
    initial = baseline()
    database = current_database(Singularity.Storage.RequestRepo)
    assert database =~ ~r/\Asingularity_test_[0-9a-f]{24}\z/

    options =
      MigrationRepo.config()
      |> Keyword.drop([:url, :name])
      |> Keyword.put(:database, database)

    {:ok, connection} = Postgrex.start_link(options)
    Process.unlink(connection)

    on_exit(fn ->
      if Process.alive?(connection), do: GenServer.stop(connection)
      assert application_configs() == initial.configs

      if initial.runtime_started? do
        assert {:ok, _apps} = Application.ensure_all_started(:singularity_runtime)
      else
        refute runtime_started?()
      end
    end)

    own_id = Ecto.UUID.bingenerate()
    unrelated_id = Ecto.UUID.bingenerate()

    sentinel = %{
      connection: connection,
      database: database,
      own_id: own_id,
      unrelated_id: unrelated_id,
      initial: initial,
      runtime_pid: Process.whereis(Singularity.Runtime.Supervisor),
      cleanup_id: make_ref(),
      schema_rows: wake_schema_rows(connection)
    }

    on_exit(sentinel.cleanup_id, fn -> finish_wake_sentinels(sentinel) end)
    assert %{rows: [[^database]]} = Postgrex.query!(connection, "SELECT current_database()", [])
    assert [[@wake_version, _constraint]] = sentinel.schema_rows

    if initial.runtime_started? do
      assert Process.whereis(Singularity.Runtime.Supervisor) == sentinel.runtime_pid
      assert :ok == Application.stop(:singularity_runtime)
    end

    %{one: fixture} = Fixtures.two_vaults!()

    for id <- [own_id, unrelated_id] do
      baseline_owner_query(
        connection,
        """
        INSERT INTO core.outbox_events (
          id, event_type, idempotency_key, vault_id, principal_id,
          required_capability, principal_authorization_epoch, vault_authorization_epoch,
          classification, correlation_id, expected_entity_revision, envelope_version,
          payload, occurred_at, delivered_at
        ) VALUES ($1, 'asset.verify_requested', $2, $3, $4, 'asset.write', 7, 23,
          'private', $1, 0, 1, '{}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """,
        [id, "wake-isolation-#{Ecto.UUID.load!(id)}", fixture.vault_id, fixture.principal_id]
      )

      baseline_owner_query(
        connection,
        """
        INSERT INTO jobs.job_submissions (
          id, vault_id, outbox_event_id, classification, idempotency_key, job_type,
          wake_requested_generation, wake_consumed_generation
        ) VALUES ($1, $2, $1, 'private', $3, 'asset_verify', 2, 1)
        """,
        [id, fixture.vault_id, "wake-isolation-#{Ecto.UUID.load!(id)}"]
      )
    end

    {:ok, repo} = MigrationRepo.start_link(pool_size: 2)

    try do
      assert current_database(MigrationRepo) == database

      error =
        assert_raise Postgrex.Error, ~r/pending wake generations/i, fn ->
          Ecto.Migrator.down(MigrationRepo, @wake_version, @wake_migration, log: false)
        end

      assert error.postgres.code == :object_not_in_prerequisite_state
    after
      Supervisor.stop(repo)
    end

    Map.put(sentinel, :rows, pending_wake_rows(sentinel))
  end

  defp assert_borrowed_wake_rejections(fixture, repo) do
    {stale, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^stale, :normal}, 1_000

    counts = wake_fixture_counts()

    for rejected <- [self(), stale] do
      assert_raise ArgumentError, ~r/exact live MigrationRepo PID/, fn ->
        Fixtures.two_vaults!(rejected)
      end

      assert_raise ArgumentError, ~r/exact live MigrationRepo PID/, fn ->
        Fixtures.outbox_event!(fixture, rejected)
      end
    end

    assert Process.whereis(MigrationRepo) == repo
    assert Process.alive?(repo)

    assert wake_fixture_counts() == counts
  end

  defp wake_fixture_counts do
    assert {:ok, %{rows: rows}} =
             MigrationRepo.transaction(fn ->
               Ecto.Adapters.SQL.query!(
                 MigrationRepo,
                 "SET LOCAL ROLE singularity_table_owner",
                 [],
                 log: false
               )

               Ecto.Adapters.SQL.query!(
                 MigrationRepo,
                 "SELECT (SELECT count(*) FROM identity.people), (SELECT count(*) FROM core.outbox_events)",
                 [],
                 log: false
               )
             end)

    rows
  end

  defp pending_wake_rows(sentinel) do
    %{rows: rows} =
      baseline_owner_query(
        sentinel.connection,
        """
        SELECT id, wake_requested_generation, wake_consumed_generation
        FROM jobs.job_submissions WHERE id = ANY($1::uuid[]) ORDER BY id
        """,
        [[sentinel.own_id, sentinel.unrelated_id]]
      )

    rows
  end

  defp wake_schema_rows(connection) do
    %{rows: rows} =
      Postgrex.query!(
        connection,
        """
        SELECT migration.version, pg_get_constraintdef(guard.oid)
        FROM public.schema_migrations AS migration
        JOIN pg_catalog.pg_constraint AS guard
          ON guard.conname = 'job_submissions_wake_generations_check'
        JOIN pg_catalog.pg_class AS relation
          ON relation.oid = guard.conrelid AND relation.relname = 'job_submissions'
        JOIN pg_catalog.pg_namespace AS namespace
          ON namespace.oid = relation.relnamespace AND namespace.nspname = 'jobs'
        WHERE migration.version=$1
        """,
        [@wake_version]
      )

    rows
  end

  defp baseline_owner_query(connection, statement, parameters) do
    assert {:ok, result} =
             Postgrex.transaction(connection, fn transaction ->
               Postgrex.query!(transaction, "SET LOCAL ROLE singularity_table_owner", [])
               Postgrex.query!(transaction, statement, parameters)
             end)

    result
  end

  defp finish_wake_sentinels(sentinel) do
    assert application_configs() == sentinel.initial.configs

    assert %{rows: [[database]]} =
             Postgrex.query!(sentinel.connection, "SELECT current_database()", [])

    assert database == sentinel.database
    assert wake_schema_rows(sentinel.connection) == sentinel.schema_rows

    before = pending_wake_rows(sentinel)
    if Map.has_key?(sentinel, :rows), do: assert(before == sentinel.rows)
    delete_wake_sentinel(sentinel.connection, sentinel.own_id)

    assert pending_wake_rows(sentinel) ==
             Enum.reject(before, fn [id, _, _] -> id == sentinel.own_id end)

    delete_wake_sentinel(sentinel.connection, sentinel.unrelated_id)
    assert pending_wake_rows(sentinel) == []
  end

  defp delete_wake_sentinel(connection, id) do
    baseline_owner_query(
      connection,
      "DELETE FROM jobs.job_submissions WHERE id=$1 AND outbox_event_id=$1",
      [id]
    )

    baseline_owner_query(connection, "DELETE FROM core.outbox_events WHERE id=$1", [id])
  end

  defp seed(destination),
    do: KnowledgeBackupFixtures.seed!(Map.merge(destination, %{ids: @ids, originals: @originals}))

  defp native_binding do
    %{rows: [["singularity_migration", "singularity_table_owner", backend, transaction]]} =
      Ecto.Adapters.SQL.query!(
        MigrationRepo,
        "SELECT session_user::text,current_user::text,pg_backend_pid(),pg_current_xact_id()::text",
        [],
        log: false
      )

    {backend, transaction}
  end

  defp raw_descriptor_open?(path) do
    directory = "/proc/#{System.pid()}/fd"

    Enum.any?(File.ls!(directory), fn entry ->
      case File.read_link(Path.join(directory, entry)) do
        {:ok, target} -> target in [path, path <> " (deleted)"]
        {:error, :enoent} -> false
      end
    end)
  end

  defp stage_actor(stage, callback \\ fn _destination -> :fixture_return end) do
    parent = self()
    token = make_ref()

    {actor, monitor} =
      spawn_monitor(fn ->
        checkpoint = fn reached, resources ->
          if reached == stage do
            parent_monitor = Process.monitor(parent)
            send(parent, {token, :checkpoint, resources})

            try do
              receive do
                {^token, :continue} -> :ok
                {^token, :raise} -> raise "lifecycle acquisition probe"
                {:DOWN, ^parent_monitor, :process, ^parent, _reason} -> :ok
              end
            after
              Process.demonitor(parent_monitor, [:flush])
            end
          end
        end

        outcome =
          try do
            {:return,
             ResourceOwner.with_checkpoint(checkpoint, fn ->
               KnowledgeBackupFixtures.with_destination(:current, callback)
             end)}
          catch
            :error, reason -> {:error, Exception.normalize(:error, reason, __STACKTRACE__)}
            kind, reason -> {kind, reason}
          end

        send(parent, {token, :outcome, outcome})
      end)

    receive do
      {^token, :checkpoint, resources} ->
        {actor, monitor, token, resources}

      {:DOWN, ^monitor, :process, ^actor, reason} ->
        flunk("stage actor exited: #{inspect(reason)}")
    after
      30_000 -> flunk("stage #{inspect(stage)} not reached by #{inspect(actor)}")
    end
  end

  defp assert_process_stopped(pid, deadline, evidence) do
    monitor = Process.monitor(pid)

    try do
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, timeout, evidence
      refute Process.alive?(pid), evidence
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp baseline do
    %{
      configs: application_configs(),
      compiler_options: Code.compiler_options(),
      repos: Map.new(@repos, &{&1, Process.whereis(&1)}),
      repo_databases:
        Map.new(
          for repo <- @repos, is_pid(Process.whereis(repo)), do: {repo, current_database(repo)}
        ),
      runtime_started?: runtime_started?()
    }
  end

  defp maintenance do
    options =
      MigrationRepo.config() |> Keyword.drop([:url, :name]) |> Keyword.put(:database, "postgres")

    start_supervised!({Postgrex, options})
  end

  defp evidence(resources), do: "exact fixture resources: #{inspect(resources, limit: :infinity)}"

  defp assert_stage_cleanup(maintenance, resources, baseline) do
    if names = Map.get(resources, :names) do
      target = %{
        database: names.database,
        storage_root: names.storage_root,
        repos: resources.repos
      }

      assert_cleanup(
        maintenance,
        target,
        baseline,
        System.monotonic_time(:millisecond) + 10_000,
        evidence(resources)
      )
    else
      assert application_configs() == baseline.configs
      assert Code.compiler_options() == baseline.compiler_options
      assert Map.new(@repos, &{&1, Process.whereis(&1)}) == baseline.repos
      assert runtime_started?() == baseline.runtime_started?
    end

    for {_repo, pid} <- Map.get(resources, :owned_repos, []) do
      refute Process.alive?(pid), evidence(resources)
    end
  end

  defp await(fun, evidence, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    unless fun.() do
      assert System.monotonic_time(:millisecond) < deadline, evidence

      receive do
      after
        10 -> :ok
      end

      await(fun, evidence, deadline)
    end
  end

  defp assert_cleanup(maintenance, resources, baseline, deadline, evidence) do
    observed = %{
      live_owned_repos: Map.filter(resources.repos, fn {_repo, pid} -> Process.alive?(pid) end),
      database_exists?: database_exists?(maintenance, resources.database),
      root_exists?: File.exists?(resources.storage_root),
      configs_restored?: application_configs() == baseline.configs,
      compiler_options_restored?: Code.compiler_options() == baseline.compiler_options,
      baseline_repos_restored?:
        Enum.all?(baseline.repos, fn {repo, previous_pid} ->
          case {previous_pid, Process.whereis(repo)} do
            {nil, nil} ->
              true

            {previous, current} when is_pid(previous) and is_pid(current) ->
              Process.alive?(current)

            _ ->
              false
          end
        end),
      runtime_restored?: runtime_started?() == baseline.runtime_started?
    }

    expected = %{
      live_owned_repos: %{},
      database_exists?: false,
      root_exists?: false,
      configs_restored?: true,
      compiler_options_restored?: true,
      baseline_repos_restored?: true,
      runtime_restored?: true
    }

    if observed != expected do
      assert System.monotonic_time(:millisecond) < deadline,
             "#{evidence}\ncleanup did not complete: #{inspect(observed, limit: :infinity)}"

      receive do
      after
        10 -> :ok
      end

      assert_cleanup(maintenance, resources, baseline, deadline, evidence)
    end
  end

  defp current_database(repo) do
    %{rows: [[database]]} =
      Ecto.Adapters.SQL.query!(repo, "SELECT current_database()", [], log: false, timeout: 1_000)

    database
  end

  defp database_exists?(connection, database) do
    case Postgrex.query(
           connection,
           "SELECT EXISTS(SELECT 1 FROM pg_catalog.pg_database WHERE datname=$1)",
           [database],
           timeout: 1_000
         ) do
      {:ok, %{rows: [[exists?]]}} -> exists?
      {:error, _reason} -> :observation_failed
    end
  end

  defp application_configs do
    Map.new(@apps, &{&1, Map.new(Application.get_all_env(&1))})
  end

  defp runtime_started? do
    Enum.any?(Application.started_applications(), &(elem(&1, 0) == :singularity_runtime))
  end
end
