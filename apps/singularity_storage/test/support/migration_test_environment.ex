defmodule Singularity.Storage.MigrationTestEnvironment do
  @moduledoc false

  alias Singularity.Storage.{MigrationRepo, TestEnvironment}

  @repos [
    MigrationRepo,
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]

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
