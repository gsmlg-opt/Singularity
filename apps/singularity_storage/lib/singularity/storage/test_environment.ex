defmodule Singularity.Storage.TestEnvironment do
  @moduledoc false

  @suffix_bytes 12
  @database_prefix "singularity_test_"
  @migration_repo Singularity.Storage.MigrationRepo
  @runtime_repos [
    {Singularity.Storage.RequestRepo, "singularity_web"},
    {Singularity.Storage.PreAuthRepo, "singularity_pre_auth"},
    {Singularity.Storage.DispatcherRepo, "singularity_dispatcher"},
    {Singularity.Storage.WorkerRepo, "singularity_worker"}
  ]

  defstruct [:database, :storage_root, :suffix]

  @type t :: %__MODULE__{
          database: String.t(),
          storage_root: Path.t(),
          suffix: String.t()
        }

  @spec allocate!() :: t()
  def allocate! do
    assert_test_environment!()

    suffix =
      @suffix_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    %__MODULE__{
      database: @database_prefix <> suffix,
      storage_root: Path.join([System.tmp_dir!(), "singularity", "integration", suffix]),
      suffix: suffix
    }
  end

  @spec create!(t()) :: :ok
  def create!(%__MODULE__{} = names) do
    assert_test_environment!()
    validate!(names)
    ensure_database_dependencies!()
    File.mkdir_p!(names.storage_root)

    create_database!(names.database)
    configure_repositories!(names)
    migrate!()
    start_runtime_repositories!()
    :ok
  end

  @spec drop!(t()) :: :ok
  def drop!(%__MODULE__{} = names) do
    assert_test_environment!()
    validate!(names)

    try do
      stop_repositories!()
      ensure_database_dependencies!()
      drop_database!(names.database)
      :ok
    after
      File.rm_rf!(names.storage_root)
    end
  end

  defp create_database!(database) do
    with_migration_repo("postgres", fn ->
      Ecto.Adapters.SQL.query!(
        @migration_repo,
        "CREATE DATABASE #{quoted_identifier(database)}",
        [],
        log: false
      )
    end)

    with_migration_repo(database, fn ->
      Ecto.Adapters.SQL.query!(
        @migration_repo,
        "GRANT CREATE ON DATABASE #{quoted_identifier(database)} TO singularity_table_owner",
        [],
        log: false
      )
    end)
  end

  defp drop_database!(database) do
    with_migration_repo("postgres", fn ->
      Ecto.Adapters.SQL.query!(
        @migration_repo,
        "DROP DATABASE IF EXISTS #{quoted_identifier(database)} WITH (FORCE)",
        [],
        log: false
      )
    end)
  end

  defp configure_repositories!(names) do
    put_repo_connection!(@migration_repo, "singularity_migration", names.database)

    Enum.each(@runtime_repos, fn {repo, role} ->
      put_repo_connection!(repo, role, names.database)
    end)

    Application.put_env(:singularity_storage, :storage_root, names.storage_root)
  end

  defp migrate! do
    {:ok, _pid} = @migration_repo.start_link(pool_size: 2)

    try do
      Ecto.Migrator.run(
        @migration_repo,
        migrations_path(),
        :up,
        all: true,
        log: false
      )
    after
      stop_repo(@migration_repo)
    end
  end

  defp start_runtime_repositories! do
    Enum.each(@runtime_repos, fn {repo, _role} ->
      {:ok, _pid} = repo.start_link()
    end)
  end

  defp stop_repositories! do
    Enum.each([@migration_repo | Enum.map(@runtime_repos, &elem(&1, 0))], &stop_repo/1)
  end

  defp stop_repo(repo) do
    case Process.whereis(repo) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end

  defp with_migration_repo(database, fun) do
    {:ok, _pid} =
      @migration_repo.start_link(
        connection_options("singularity_migration", database) ++ [pool_size: 1]
      )

    try do
      fun.()
    after
      stop_repo(@migration_repo)
    end
  end

  defp put_repo_connection!(repo, username, database) do
    config =
      :singularity_storage
      |> Application.get_env(repo, [])
      |> Keyword.drop([:url, :hostname])
      |> Keyword.merge(connection_options(username, database))

    Application.put_env(:singularity_storage, repo, config)
  end

  defp connection_options(username, database) do
    [
      url: nil,
      username: username,
      database: database,
      socket_dir: System.fetch_env!("PGHOST"),
      port: pg_port!()
    ]
  end

  defp migrations_path do
    :singularity_storage
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("repo/migrations")
  end

  defp quoted_identifier(identifier) do
    ~s("#{String.replace(identifier, "\"", "\"\"")}")
  end

  defp ensure_database_dependencies! do
    {:ok, _started} = Application.ensure_all_started(:ecto_sql)
    {:ok, _started} = Application.ensure_all_started(:postgrex)
  end

  defp validate!(%__MODULE__{} = names) do
    expected_database = @database_prefix <> names.suffix
    expected_root = Path.join([System.tmp_dir!(), "singularity", "integration", names.suffix])

    unless names.database == expected_database and
             names.suffix =~ ~r/\A[0-9a-f]{24}\z/ and
             Path.expand(names.storage_root) == Path.expand(expected_root) do
      raise ArgumentError, "integration database must contain its generated random suffix"
    end

    :ok
  end

  defp assert_test_environment! do
    unless Mix.env() == :test do
      raise ArgumentError, "integration environment requires MIX_ENV=test"
    end
  end

  defp pg_port! do
    case Integer.parse(System.fetch_env!("PGPORT")) do
      {port, ""} when port in 1..65_535 -> port
      _other -> raise ArgumentError, "PGPORT must be a valid PostgreSQL port"
    end
  end
end
