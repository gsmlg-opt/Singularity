defmodule Singularity.Storage.Backup.LegacyUpgradeLifecycleTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Storage.Backup.KnowledgeFixtureResourceOwner, as: ResourceOwner
  alias Singularity.Storage.{LegacyUpgradeFixtures, MigrationRepo}

  @repos [
    MigrationRepo,
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]
  @apps [:singularity_storage, :singularity_runtime]

  test "fixed legacy preparation closes in its owner before ready and preserves exact resources" do
    baseline = baseline()
    maintenance = maintenance()
    caller = self()
    token = make_ref()

    expected_versions =
      LegacyUpgradeFixtures.identity!().files
      |> Enum.map(&(&1.filename |> binary_part(0, 14) |> String.to_integer()))

    checkpoint = fn
      :before_arm, resources -> send(caller, {token, {:armed, resources.owner}})
      :ready, resources -> send(caller, {token, {:ready, resources}})
      _stage, _resources -> :ok
    end

    prepare = fn destination, context ->
      assert self() != caller
      assert context.caller == caller
      assert Enum.sort(Map.keys(context)) == [:caller, :report_cleanup]
      assert is_function(context.report_cleanup, 1)
      assert destination.repo == MigrationRepo

      repos = Map.new(@repos, &{&1, Process.whereis(&1)})

      assert Enum.all?(repos, fn {repo, pid} ->
               is_pid(pid) and Process.alive?(pid) and
                 current_database(repo) == destination.database
             end),
             "preparation requires the five actual live same-A repositories"

      assert Keyword.fetch!(Ecto.Repo.Registry.lookup(repos[MigrationRepo]).opts, :pool_size) == 2

      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          MigrationRepo,
          "SELECT version FROM public.schema_migrations ORDER BY version",
          [],
          log: false
        )

      assert Enum.map(rows, fn [version] -> version end) == expected_versions
      assert :ok = context.report_cleanup.(:running)
      send(caller, {token, {:running, self()}})

      observation = %{
        repos: repos,
        database: database_identity(MigrationRepo),
        root: directory_identity(Path.dirname(destination.object_root))
      }

      assert :ok = context.report_cleanup.(:closed)
      send(caller, {token, {:closed, self(), observation}})
      %{prepared: true, database: destination.database}
    end

    {owner, destination, receipt} =
      ResourceOwner.with_checkpoint(checkpoint, fn ->
        apply(ResourceOwner, :open_legacy_v0_1_0, [prepare])
      end)

    {resources, observation, infrastructure} =
      try do
        assert receipt == %{prepared: true, database: destination.database}
        assert Process.alive?(owner)
        assert {:armed, ^owner} = next_event(token)
        assert {:running, ^owner} = next_event(token)
        assert {:closed, ^owner, observation} = next_event(token)
        assert {:ready, resources} = next_event(token)

        assert resources.owner == owner
        assert resources.caller == caller
        assert resources.names.database == destination.database
        assert resources.repos == observation.repos
        assert database_identity(MigrationRepo) == observation.database
        assert elem(observation.database, 0) == destination.database
        assert directory_identity(resources.names.storage_root) == observation.root
        assert destination.object_root == Path.join(resources.names.storage_root, "objects")
        assert Map.new(@repos, &{&1, Process.whereis(&1)}) == observation.repos
        refute runtime_started?()

        assert {:ok, infrastructure} = ResourceOwner.start_infrastructure(owner, [])
        assert Process.alive?(infrastructure)
        assert {:error, :already_started} = ResourceOwner.start_infrastructure(owner, [])
        assert Map.new(@repos, &{&1, Process.whereis(&1)}) == observation.repos
        {resources, observation, infrastructure}
      after
        assert :ok = ResourceOwner.close(owner)
      end

    refute Process.alive?(infrastructure)
    assert Enum.all?(resources.owned_repos, fn {_repo, pid} -> not Process.alive?(pid) end)
    assert Enum.all?(observation.repos, fn {_repo, pid} -> not Process.alive?(pid) end)
    refute Process.alive?(resources.maintenance)
    refute database_exists?(maintenance, destination.database)
    refute File.exists?(resources.names.storage_root)
    assert_baseline(baseline)
  end

  test "invalid preparation and path or option selectors reject before allocation" do
    baseline = baseline()
    caller = self()
    token = make_ref()
    prepare = fn _destination, _context -> :not_executed end

    invalid = [
      nil,
      :legacy_v0_1_0,
      fn -> :not_executed end,
      fn _destination -> :not_executed end,
      fn _destination, _context, _extra -> :not_executed end,
      [],
      [prepare: prepare],
      [prepare: prepare, migration_path: "/arbitrary/migrations"],
      [prepare: prepare, migration_pool_size: 2],
      [prepare: prepare, prepare: prepare],
      [prepare: prepare, migration_pool_size: 2, migration_pool_size: 2],
      {prepare, "/arbitrary/migrations"}
    ]

    ResourceOwner.with_checkpoint(
      fn stage, _resources -> send(caller, {token, :unexpected_checkpoint, stage}) end,
      fn ->
        for rejected <- invalid do
          assert_raise ArgumentError, "legacy_preparation", fn ->
            apply(ResourceOwner, :open_legacy_v0_1_0, [rejected])
          end
        end
      end
    )

    refute_receive {^token, :unexpected_checkpoint, _stage}, 0
    assert_baseline(baseline)
  end

  for failure <- [:raise, :throw, :caller_loss, :running, :unconfirmed] do
    test "#{failure} preparation preserves its primary and the exact cleanup boundary" do
      baseline = baseline()
      maintenance = maintenance()
      scenario = preparation_scenario(unquote(failure))
      quarantined? = unquote(failure) in [:running, :unconfirmed]

      try do
        assert Enum.all?(scenario.resources.repos, fn {_repo, pid} -> not Process.alive?(pid) end)
        refute Process.alive?(scenario.resources.owner)
        await_connection_absence(maintenance, scenario.resources.destination.database)
        assert connection_count(maintenance, scenario.resources.destination.database) == 0
        assert_baseline(baseline)
        refute :ready in scenario.stages

        if quarantined? do
          assert database_exists?(maintenance, scenario.resources.destination.database)
          assert directory_identity(scenario.resources.root) == scenario.resources.root_identity
          refute :before_database_drop in scenario.stages
          refute :owner_cleanup_completed in scenario.stages
          assert :owner_cleanup_failed in scenario.stages
          assert {:raised, :error, exception, _stack} = scenario.outcome
          assert exception.__struct__ == ResourceOwner.PreparationError
          assert exception.primary == :legacy_preparation_not_closed
          assert {:legacy_preparation_quarantined, unquote(failure)} in exception.cleanup
        else
          refute database_exists?(maintenance, scenario.resources.destination.database)
          refute File.exists?(scenario.resources.root)
          assert :owner_cleanup_completed in scenario.stages

          case unquote(failure) do
            :raise ->
              assert {:raised, :error, %RuntimeError{message: "legacy preparation probe"}, stack} =
                       scenario.outcome

              assert stack != []

            :throw ->
              assert {:raised, :throw, :legacy_preparation_probe, stack} = scenario.outcome
              assert stack != []

            :caller_loss ->
              assert scenario.outcome == :caller_lost
          end
        end
      after
        if quarantined? do
          # Separate test recovery, NOT automatic helper cleanup credit. The
          # complete owner/Repo and native PostgreSQL absence checks come first.
          recover_quarantined_fixture!(maintenance, scenario.resources)
        end
      end

      refute database_exists?(maintenance, scenario.resources.destination.database)
      refute File.exists?(scenario.resources.root)
      assert_baseline(baseline)
    end
  end

  for {status, category} <- [
        {:closed, :legacy_protocol},
        {:unconfirmed, :legacy_pipe},
        {:closed, {:private, "legacy-private-category-probe"}},
        {:unconfirmed, {:private, "legacy-private-category-probe"}}
      ] do
    test "trusted preparation signal #{status}/#{inspect(category)} keeps only fixed categories" do
      assert_preparation_signal(unquote(status), unquote(Macro.escape(category)))
    end
  end

  test "preparation reporting rejects foreign callers and unknown states without mutating ownership" do
    baseline = baseline()

    prepare = fn _destination, context ->
      assert :ok = context.report_cleanup.(:running)
      owner = self()
      token = make_ref()

      {foreign, monitor} =
        spawn_monitor(fn ->
          outcome = capture(fn -> context.report_cleanup.(:unconfirmed) end)
          send(owner, {token, outcome})
        end)

      assert_receive {^token,
                      {:raised, :error, %ArgumentError{message: "legacy_preparation_owner"}, _}},
                     1_000

      assert_receive {:DOWN, ^monitor, :process, ^foreign, :normal}, 1_000

      assert_raise ArgumentError, "legacy_preparation_state", fn ->
        context.report_cleanup.(:arbitrary_state)
      end

      assert :ok = context.report_cleanup.(:closed)
      :owner_local
    end

    {owner, _destination, :owner_local} =
      apply(ResourceOwner, :open_legacy_v0_1_0, [prepare])

    assert :ok = ResourceOwner.close(owner)
    assert_baseline(baseline)
  end

  defp assert_preparation_signal(status, category) do
    baseline = baseline()
    maintenance = maintenance()
    scenario = preparation_scenario({:signal, status, category})

    try do
      refute Process.alive?(scenario.resources.owner)
      assert Enum.all?(scenario.resources.repos, fn {_repo, pid} -> not Process.alive?(pid) end)
      await_connection_absence(maintenance, scenario.resources.destination.database)
      assert connection_count(maintenance, scenario.resources.destination.database) == 0
      refute :ready in scenario.stages
      assert {:raised, :error, exception, stack} = scenario.outcome
      assert exception.__struct__ == ResourceOwner.PreparationError
      assert Exception.message(exception) == "legacy_preparation"
      assert exception.primary == if(is_atom(category), do: category, else: :legacy_preparation)
      refute inspect(exception) =~ "legacy-private-category-probe"
      refute inspect(stack) =~ "legacy-private-category-probe"

      if status == :closed do
        assert exception.cleanup == []
        refute database_exists?(maintenance, scenario.resources.destination.database)
        refute File.exists?(scenario.resources.root)
        assert :owner_cleanup_completed in scenario.stages
      else
        assert {:legacy_preparation_quarantined, :unconfirmed} in exception.cleanup
        assert database_exists?(maintenance, scenario.resources.destination.database)
        assert directory_identity(scenario.resources.root) == scenario.resources.root_identity
        refute :before_database_drop in scenario.stages
        refute :owner_cleanup_completed in scenario.stages
        assert :owner_cleanup_failed in scenario.stages
      end

      assert_baseline(baseline)
    after
      if status == :unconfirmed do
        # Explicit test recovery after actual process/connection absence;
        # this is not automatic helper cleanup or a successful receipt.
        recover_quarantined_fixture!(maintenance, scenario.resources)
      end
    end

    refute database_exists?(maintenance, scenario.resources.destination.database)
    refute File.exists?(scenario.resources.root)
    assert_baseline(baseline)
  end

  defp preparation_scenario(failure) do
    controller = self()
    token = make_ref()

    {actor, actor_monitor} =
      spawn_monitor(fn ->
        checkpoint = fn stage, _resources -> send(controller, {token, :stage, stage}) end

        prepare = fn destination, context ->
          caller_monitor = Process.monitor(context.caller)
          assert :ok = context.report_cleanup.(:running)
          root = Path.dirname(destination.object_root)

          send(
            controller,
            {token, :preparing,
             %{
               owner: self(),
               destination: destination,
               root: root,
               root_identity: directory_identity(root),
               repos: Map.new(@repos, &{&1, Process.whereis(&1)})
             }}
          )

          try do
            case failure do
              :raise ->
                assert :ok = context.report_cleanup.(:closed)
                raise "legacy preparation probe"

              :throw ->
                assert :ok = context.report_cleanup.(:closed)
                throw(:legacy_preparation_probe)

              :caller_loss ->
                receive do
                  {:DOWN, ^caller_monitor, :process, caller, _reason}
                  when caller == context.caller ->
                    :ok
                end

                assert :ok = context.report_cleanup.(:closed)
                :must_not_become_ready

              :running ->
                :must_not_become_ready

              :unconfirmed ->
                assert :ok = context.report_cleanup.(:unconfirmed)
                :must_not_become_ready

              {:signal, status, category} ->
                assert :ok = context.report_cleanup.(status)
                throw({:legacy_preparation_failed, category})
            end
          after
            Process.demonitor(caller_monitor, [:flush])
          end
        end

        outcome =
          capture(fn ->
            ResourceOwner.with_checkpoint(checkpoint, fn ->
              {owner, _destination, receipt} =
                apply(ResourceOwner, :open_legacy_v0_1_0, [prepare])

              try do
                receipt
              after
                ResourceOwner.close(owner)
              end
            end)
          end)

        send(controller, {token, :outcome, outcome})
      end)

    resources =
      receive do
        {^token, :preparing, resources} -> resources
      after
        30_000 -> flunk("the exact legacy preparation did not reach its owned boundary")
      end

    owner_monitor = Process.monitor(resources.owner)
    owner = resources.owner
    if failure == :caller_loss, do: Process.exit(actor, :kill)
    assert_receive {:DOWN, ^actor_monitor, :process, ^actor, actor_reason}, 15_000
    assert actor_reason == if(failure == :caller_loss, do: :killed, else: :normal)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _reason}, 15_000

    outcome =
      if failure == :caller_loss do
        :caller_lost
      else
        receive do
          {^token, :outcome, outcome} -> outcome
        after
          0 -> flunk("the legacy failure must return only after its cleanup receipt")
        end
      end

    %{resources: resources, outcome: outcome, stages: collect_stages(token, [])}
  end

  defp collect_stages(token, stages) do
    receive do
      {^token, :stage, stage} -> collect_stages(token, [stage | stages])
    after
      0 -> Enum.reverse(stages)
    end
  end

  defp recover_quarantined_fixture!(maintenance, resources) do
    refute Process.alive?(resources.owner)
    assert Enum.all?(resources.repos, fn {_repo, pid} -> not Process.alive?(pid) end)
    database = resources.destination.database
    assert database =~ ~r/\Asingularity_test_[0-9a-f]{24}\z/
    suffix = String.replace_prefix(database, "singularity_test_", "")
    assert resources.root == Path.join([System.tmp_dir!(), "singularity", "integration", suffix])
    await_connection_absence(maintenance, database)
    assert connection_count(maintenance, database) == 0

    if database_exists?(maintenance, database) do
      assert directory_identity(resources.root) == resources.root_identity
      Postgrex.query!(maintenance, "DROP DATABASE \"#{database}\"", [])
    end

    if File.exists?(resources.root) do
      assert directory_identity(resources.root) == resources.root_identity
      File.rm_rf!(resources.root)
    end
  end

  defp await_connection_absence(connection, database) do
    await_connection_absence(connection, database, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_connection_absence(connection, database, deadline) do
    count = connection_count(connection, database)
    remaining = deadline - System.monotonic_time(:millisecond)

    # BEAM DOWN is not a PostgreSQL backend-exit receipt. Observe actual native
    # absence within the ordinary cleanup's 500 x 10ms envelope; never terminate
    # sessions, and leave the caller's exact final zero assertion authoritative.
    if count != 0 and remaining > 0 do
      receive do
      after
        min(10, remaining) -> :ok
      end

      await_connection_absence(connection, database, deadline)
    end
  end

  defp connection_count(connection, database) do
    %{rows: [[count]]} =
      Postgrex.query!(
        connection,
        "SELECT count(*) FROM pg_catalog.pg_stat_activity WHERE datname=$1",
        [database]
      )

    count
  end

  defp capture(fun) do
    try do
      {:returned, fun.()}
    catch
      kind, reason -> {:raised, kind, reason, __STACKTRACE__}
    end
  end

  defp maintenance do
    options =
      MigrationRepo.config()
      |> Keyword.drop([:url, :name])
      |> Keyword.put(:database, "postgres")

    start_supervised!({Postgrex, options})
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

  defp assert_baseline(baseline) do
    configs_restored? = application_configs() == baseline.configs

    assert configs_restored?,
           "legacy cleanup must restore the complete application configuration"

    assert Code.compiler_options() == baseline.compiler_options
    assert runtime_started?() == baseline.runtime_started?

    for {repo, previous} <- baseline.repos do
      restored? =
        case {previous, Process.whereis(repo)} do
          {nil, nil} ->
            true

          {old, current} when is_pid(old) and is_pid(current) ->
            Process.alive?(current) and current_database(repo) == baseline.repo_databases[repo]

          _other ->
            false
        end

      assert restored?, "legacy cleanup must restore each original repository binding"
    end
  end

  defp current_database(repo) do
    %{rows: [[database]]} =
      Ecto.Adapters.SQL.query!(repo, "SELECT current_database()", [], log: false)

    database
  end

  defp database_identity(repo) do
    %{rows: [[database, oid]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT current_database(), oid::bigint FROM pg_catalog.pg_database WHERE datname=current_database()",
        [],
        log: false
      )

    {database, oid}
  end

  defp directory_identity(path) do
    %File.Stat{type: :directory, major_device: major, minor_device: minor, inode: inode} =
      File.lstat!(path)

    {major, minor, inode}
  end

  defp database_exists?(connection, database) do
    %{rows: [[exists?]]} =
      Postgrex.query!(
        connection,
        "SELECT EXISTS(SELECT 1 FROM pg_catalog.pg_database WHERE datname=$1)",
        [database]
      )

    exists?
  end

  defp application_configs, do: Map.new(@apps, &{&1, Map.new(Application.get_all_env(&1))})

  defp next_event(token) do
    receive do
      {^token, event} -> event
    after
      0 -> flunk("the legacy preparation event must precede its successful reply")
    end
  end

  defp runtime_started? do
    Enum.any?(Application.started_applications(), &(elem(&1, 0) == :singularity_runtime))
  end
end
