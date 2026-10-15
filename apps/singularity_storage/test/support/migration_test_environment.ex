defmodule Singularity.Storage.MigrationTestEnvironment do
  @moduledoc false

  alias Singularity.Storage.{MigrationRepo, SearchExtensionBootstrap, TestEnvironment}

  @repos [
    MigrationRepo,
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]

  @owned_state {__MODULE__, :owned_destination}
  @fixture_apps [:singularity_storage, :singularity_runtime]

  # This entry runs only in the surviving fixture owner. The ordinary migration
  # fixture API below retains its established behavior and consumers.
  def with_owned_database(caller, checkpoint, fun, options \\ [])
      when options in [[], [migration_pool_size: 2]] do
    state = %{
      caller: caller,
      checkpoint: checkpoint,
      migration_repo_options: if(options == [], do: [], else: [pool_size: 2]),
      configs: Map.new(@fixture_apps, &{&1, Map.new(Application.get_all_env(&1))}),
      compiler_options: Code.compiler_options(),
      baseline_repos: Map.new(@repos, &{&1, Process.whereis(&1)}),
      runtime_started?: runtime_started?(),
      runtime_pid: Process.whereis(Singularity.Runtime.Supervisor),
      runtime_stopped?: false,
      maintenance_config:
        MigrationRepo.config()
        |> Keyword.drop([:url, :name])
        |> Keyword.put(:database, "postgres"),
      maintenance: nil,
      connections: [],
      names: nil,
      database_status: :not_attempted,
      root_identity: nil,
      root_claimed?: false,
      infrastructure: nil,
      owned_repos: [],
      active_repos: %{}
    }

    Process.put(@owned_state, state)

    try do
      outcome =
        try do
          destination = acquire_owned_destination()
          {:ok, fun.(destination)}
        catch
          :throw, :fixture_caller_down -> :caller_down
          kind, reason -> {:raised, kind, reason, __STACKTRACE__}
        end

      {outcome, cleanup_owned_destination()}
    after
      Process.delete(@owned_state)
    end
  end

  # Test-only ownership extension: record an empty supervisor before starting
  # children so even a later partial start failure has one exact cleanup owner.
  def start_owned_infrastructure(children) when is_list(children) do
    case owned_state() do
      %{infrastructure: nil} ->
        with {:ok, supervisor} <- Supervisor.start_link([], strategy: :one_for_one) do
          update_owned(&%{&1 | infrastructure: supervisor})

          Enum.reduce_while(children, {:ok, supervisor}, fn child, success ->
            case Supervisor.start_child(supervisor, child) do
              {:ok, _pid} -> {:cont, success}
              {:ok, _pid, _info} -> {:cont, success}
              {:error, _reason} = error -> {:halt, error}
            end
          end)
        end

      %{infrastructure: supervisor} when is_pid(supervisor) ->
        {:error, :already_started}

      _not_acquired ->
        {:error, :not_acquired}
    end
  end

  defp acquire_owned_destination do
    owned_checkpoint(:before_allocation)
    names = TestEnvironment.allocate!()
    validate_owned_names!(names)
    update_owned(&%{&1 | names: names})
    owned_checkpoint(:allocated)
    pause_owned_baseline()
    owned_checkpoint(:baseline_paused)

    connection = start_owned_maintenance()
    owned_checkpoint(:maintenance_started)
    update_owned(&%{&1 | database_status: :uncertain})

    case Postgrex.query(connection, "CREATE DATABASE \"#{names.database}\"", []) do
      {:ok, _result} ->
        update_owned(&%{&1 | database_status: :created})

      {:error, %Postgrex.Error{postgres: postgres} = error} when is_map(postgres) ->
        update_owned(&%{&1 | database_status: :rejected})
        raise error

      {:error, error} ->
        raise error
    end

    owned_checkpoint(:database_created)
    File.mkdir_p!(Path.dirname(names.storage_root))
    :ok = File.mkdir(names.storage_root)
    update_owned(&%{&1 | root_claimed?: true})
    identity = directory_identity!(names.storage_root)
    update_owned(&%{&1 | root_identity: identity})
    File.chmod!(names.storage_root, 0o700)
    root = Path.join(names.storage_root, "objects")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    owned_checkpoint(:root_created)

    for repo <- @repos do
      config = Application.get_env(:singularity_storage, repo, [])

      Application.put_env(
        :singularity_storage,
        repo,
        config |> Keyword.delete(:url) |> Keyword.put(:database, names.database)
      )
    end

    Application.put_env(:singularity_storage, :storage_root, root)

    migration_pid =
      start_owned_repo(MigrationRepo, :migration, owned_state().migration_repo_options)

    Ecto.Adapters.SQL.query!(
      MigrationRepo,
      "GRANT CREATE ON DATABASE \"#{names.database}\" TO singularity_table_owner",
      [],
      log: false
    )

    SearchExtensionBootstrap.run!(names.database)
    owned_checkpoint(:extensions_ready)
    Code.compiler_options(ignore_module_conflict: true)

    try do
      owned_checkpoint(:before_migration)
      Ecto.Migrator.run(MigrationRepo, migrations_path(), :up, to: 99_999_999_999_999, log: false)
    after
      Code.compiler_options(owned_state().compiler_options)
    end

    owned_checkpoint(:migrated)
    stop_owned_repo(MigrationRepo, migration_pid)
    for repo <- @repos -- [MigrationRepo], do: start_owned_repo(repo, :destination)
    start_owned_repo(MigrationRepo, :destination, owned_state().migration_repo_options)
    owned_checkpoint(:ready)
    %{repo: MigrationRepo, database: names.database, object_root: root}
  end

  defp pause_owned_baseline do
    state = owned_state()

    if state.runtime_started? do
      unless Process.whereis(Singularity.Runtime.Supervisor) == state.runtime_pid,
        do: raise("fixture Runtime identity changed before acquisition")

      :ok = Application.stop(:singularity_runtime)
      update_owned(&%{&1 | runtime_stopped?: true})
    end

    for repo <- Enum.reverse(@repos) do
      case {state.baseline_repos[repo], Process.whereis(repo)} do
        {_previous, nil} -> :ok
        {pid, pid} when is_pid(pid) -> Supervisor.stop(pid)
        _replacement -> raise "fixture baseline repository identity changed: #{inspect(repo)}"
      end
    end
  end

  defp start_owned_maintenance do
    {:ok, pid} = Postgrex.start_link(owned_state().maintenance_config)
    update_owned(&%{&1 | maintenance: pid, connections: [pid | &1.connections]})
    pid
  end

  defp start_owned_repo(repo, purpose, options \\ []) do
    {:ok, pid} = repo.start_link(options)

    update_owned(fn state ->
      %{
        state
        | owned_repos: [{repo, pid} | state.owned_repos],
          active_repos: Map.put(state.active_repos, repo, pid)
      }
    end)

    owned_checkpoint({:repo_started, repo, purpose})
    pid
  end

  defp stop_owned_repo(repo, pid) do
    case Process.whereis(repo) do
      current when current == pid or is_nil(current) -> :ok
      _replacement -> raise "fixture repository replaced: #{inspect(repo)}"
    end

    if Process.alive?(pid), do: Supervisor.stop(pid)
    update_owned(&%{&1 | active_repos: Map.delete(&1.active_repos, repo)})
  end

  defp owned_checkpoint(stage) do
    state = owned_state()

    state.checkpoint.(stage, %{
      owner: self(),
      caller: state.caller,
      names: state.names,
      maintenance: state.maintenance,
      repos: state.active_repos,
      owned_repos: state.owned_repos
    })

    unless Process.alive?(state.caller), do: throw(:fixture_caller_down)

    for {_repo, pid} <- state.active_repos do
      unless Process.alive?(pid), do: raise("fixture repository exited during acquisition")
    end

    if state.maintenance && not Process.alive?(state.maintenance),
      do: raise("fixture maintenance connection exited during acquisition")
  end

  defp cleanup_owned_destination do
    state = owned_state()

    # Oban's notifier can hold a separate PostgreSQL connection. Stop the exact
    # owned infrastructure before repositories or database-drain checking.
    failures =
      cleanup_step([], {:stop_infrastructure, state.infrastructure}, fn ->
        if state.infrastructure && Process.alive?(state.infrastructure),
          do: Supervisor.stop(state.infrastructure)
      end)

    replacements =
      for repo <- @repos,
          pid = Process.whereis(repo),
          is_pid(pid),
          pid != state.baseline_repos[repo],
          {repo, pid} not in state.owned_repos,
          do: {repo, pid}

    failures =
      failures ++
        Enum.map(replacements, fn {repo, pid} -> {:unexpected_repository, repo, pid} end)

    failures =
      Enum.reduce(state.owned_repos, failures, fn {repo, pid}, failures ->
        cleanup_step(failures, {:stop_repository, repo, pid}, fn ->
          if Process.alive?(pid), do: Supervisor.stop(pid)
        end)
      end)

    database = if state.names, do: state.names.database
    root = if state.names, do: state.names.storage_root
    failures = cleanup_step(failures, {:drop_database, database}, &drop_owned_database/0)

    failures =
      Enum.reduce(owned_state().connections, failures, fn pid, failures ->
        cleanup_step(failures, {:stop_maintenance, pid}, fn ->
          if Process.alive?(pid), do: GenServer.stop(pid)
        end)
      end)

    failures = cleanup_step(failures, {:remove_root, root}, &remove_owned_root/0)

    failures =
      cleanup_step(failures, :restore_configs, fn -> restore_owned_configs(state.configs) end)

    failures =
      cleanup_step(failures, :restore_compiler, fn ->
        Code.compiler_options(state.compiler_options)
      end)

    failures =
      cleanup_step(failures, :restore_runtime, fn ->
        if state.runtime_stopped? do
          if Enum.any?(replacements, fn {repo, _pid} -> repo != MigrationRepo end),
            do: raise("fixture Runtime restart blocked by a foreign repository")

          if Process.whereis(Singularity.Runtime.Supervisor),
            do: raise("fixture Runtime was replaced before restoration")

          {:ok, _apps} = Application.ensure_all_started(:singularity_runtime)
        end
      end)

    Enum.reduce(@repos, failures, fn repo, failures ->
      cleanup_step(failures, {:restore_repository, repo}, fn ->
        if state.baseline_repos[repo] && Process.whereis(repo) == nil do
          {:ok, pid} = repo.start_link()
          Process.unlink(pid)
          unless Process.alive?(pid), do: raise("restored fixture baseline repository exited")
        end
      end)
    end)
  end

  defp drop_owned_database do
    state = owned_state()

    case state.database_status do
      :created ->
        validate_owned_names!(state.names)

        connection =
          if state.maintenance && Process.alive?(state.maintenance),
            do: state.maintenance,
            else: start_owned_maintenance()

        wait_owned_disconnects(connection, state.names.database, 500)

      :uncertain ->
        raise "fixture database creation outcome is unconfirmed"

      _not_created ->
        :ok
    end
  end

  defp wait_owned_disconnects(_connection, _database, 0),
    do: raise("fixture database connections did not drain")

  defp wait_owned_disconnects(connection, database, remaining) do
    %{rows: [[count]]} =
      Postgrex.query!(
        connection,
        "SELECT count(*) FROM pg_catalog.pg_stat_activity WHERE datname=$1",
        [database]
      )

    retry? =
      if count == 0 do
        state = owned_state()

        resources = %{
          owner: self(),
          caller: state.caller,
          names: state.names,
          maintenance: connection,
          repos: state.active_repos,
          owned_repos: state.owned_repos
        }

        # Cleanup observers must not run acquisition's caller/Repo liveness checks.
        state.checkpoint.(:before_database_drop, resources)

        case Postgrex.query(connection, "DROP DATABASE \"#{database}\"", [],
               timeout: :timer.minutes(1)
             ) do
          {:ok, _result} ->
            false

          {:error, %Postgrex.Error{postgres: %{code: :object_in_use, pg_code: "55006"}} = error} ->
            # Classify the native result before invoking the observer; observer
            # exceptions remain cleanup failures, never retryable SQL results.
            state.checkpoint.(:database_drop_in_use, Map.put(resources, :error, error))
            true

          {:error, error} ->
            raise error
        end
      else
        true
      end

    if retry? do
      receive do
      after
        10 -> :ok
      end

      wait_owned_disconnects(connection, database, remaining - 1)
    end
  end

  defp remove_owned_root do
    state = owned_state()

    if state.root_claimed? do
      validate_owned_names!(state.names)

      unless state.root_identity != nil and
               directory_identity!(state.names.storage_root) == state.root_identity,
             do: raise("fixture root identity changed before cleanup")

      File.rm_rf!(state.names.storage_root)
    end
  end

  defp directory_identity!(path) do
    %File.Stat{type: :directory, major_device: major, minor_device: minor, inode: inode} =
      File.lstat!(path)

    {major, minor, inode}
  end

  defp validate_owned_names!(%TestEnvironment{} = names) do
    unless names.suffix =~ ~r/\A[0-9a-f]{24}\z/ and
             names.database == "singularity_test_" <> names.suffix and
             names.storage_root ==
               Path.join([System.tmp_dir!(), "singularity", "integration", names.suffix]),
           do: raise(ArgumentError, "fixture requires its exact allocated database and root")
  end

  defp restore_owned_configs(configs) do
    for {app, saved} <- configs do
      for {key, _value} <- Application.get_all_env(app),
          not Map.has_key?(saved, key),
          do: Application.delete_env(app, key)

      for {key, value} <- saved, do: Application.put_env(app, key, value)
    end
  end

  defp cleanup_step(failures, step, fun) do
    fun.()
    failures
  catch
    kind, reason ->
      category = if is_map(reason), do: Map.get(reason, :__struct__, :failure), else: :failure
      failures ++ [{step, kind, category}]
  end

  defp owned_state, do: Process.get(@owned_state)
  defp update_owned(fun), do: Process.put(@owned_state, fun.(owned_state()))

  def with_database(ceiling, fun) do
    environment = open!(ceiling)

    try do
      fun.(environment)
    after
      close!(environment)
    end
  end

  def open!(ceiling) when is_integer(ceiling) and ceiling >= 0 do
    names = TestEnvironment.allocate!()

    environment = %{
      names: names,
      database: names.database,
      configs: Enum.map(@repos, &{&1, Application.fetch_env(:singularity_storage, &1)}),
      running_repos: Enum.filter(@repos, &(Process.whereis(&1) != nil)),
      runtime_started?: runtime_started?()
    }

    try do
      if environment.runtime_started?, do: Application.stop(:singularity_runtime)
      stop_repos!()
      create_database!(names)
    catch
      kind, reason ->
        restore!(environment)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end

    try do
      Enum.each(@repos, fn repo ->
        config = Application.get_env(:singularity_storage, repo, [])

        Application.put_env(
          :singularity_storage,
          repo,
          config |> Keyword.delete(:url) |> Keyword.put(:database, names.database)
        )
      end)

      with_repo(MigrationRepo, fn ->
        Ecto.Adapters.SQL.query!(
          MigrationRepo,
          "GRANT CREATE ON DATABASE \"#{names.database}\" TO singularity_table_owner",
          [],
          log: false
        )

        SearchExtensionBootstrap.run!(names.database)

        compiler_options = Code.compiler_options()
        Code.compiler_options(ignore_module_conflict: true)

        try do
          Ecto.Migrator.run(MigrationRepo, migrations_path(), :up, to: ceiling, log: false)
        after
          Code.compiler_options(compiler_options)
        end
      end)

      Enum.each(@repos -- [MigrationRepo], &start_repo!/1)
      environment
    catch
      kind, reason ->
        close!(environment)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def close!(environment) do
    try do
      TestEnvironment.drop!(environment.names)
    after
      restore!(environment)
    end
  end

  defp create_database!(%TestEnvironment{database: database} = names) do
    unless database =~ ~r/\Asingularity_test_[0-9a-f]{24}\z/ do
      raise ArgumentError, "migration tests require an allocated database name"
    end

    config = MigrationRepo.config() |> Keyword.delete(:url) |> Keyword.put(:database, "postgres")
    {:ok, connection} = Postgrex.start_link(config)
    Process.unlink(connection)

    try do
      Postgrex.query!(connection, "CREATE DATABASE \"#{database}\"", [])
    catch
      kind, reason ->
        if Process.alive?(connection), do: GenServer.stop(connection)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end

    try do
      GenServer.stop(connection)
    catch
      kind, reason ->
        TestEnvironment.drop!(names)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp restore!(environment) do
    stop_repos!()

    Enum.each(environment.configs, fn
      {repo, {:ok, config}} -> Application.put_env(:singularity_storage, repo, config)
      {repo, :error} -> Application.delete_env(:singularity_storage, repo)
    end)

    if environment.runtime_started? do
      {:ok, _} = Application.ensure_all_started(:singularity_runtime)
    end

    Enum.each(environment.running_repos, fn repo ->
      if Process.whereis(repo) == nil, do: start_repo!(repo)
    end)
  end

  defp with_repo(repo, fun) do
    start_repo!(repo)

    try do
      fun.()
    after
      Supervisor.stop(Process.whereis(repo))
    end
  end

  defp start_repo!(repo) do
    {:ok, pid} = repo.start_link()
    Process.unlink(pid)
  end

  defp stop_repos! do
    Enum.each(Enum.reverse(@repos), fn repo ->
      if pid = Process.whereis(repo), do: Supervisor.stop(pid)
    end)
  end

  defp runtime_started? do
    Enum.any?(Application.started_applications(), &(elem(&1, 0) == :singularity_runtime))
  end

  defp migrations_path do
    :singularity_storage |> :code.priv_dir() |> to_string() |> Path.join("repo/migrations")
  end
end
