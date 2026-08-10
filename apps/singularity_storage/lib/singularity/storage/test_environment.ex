defmodule Singularity.Storage.TestEnvironment do
  @moduledoc false

  alias Singularity.Storage.SafeSQL

  @suffix_bytes 12
  @database_prefix "singularity_test_"
  @playwright_run_id_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @database_disconnect_attempts 500
  @database_disconnect_interval_ms 10
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

  @spec from_playwright_run_id!(String.t()) :: t()
  def from_playwright_run_id!(run_id) do
    assert_test_environment!()

    unless is_binary(run_id) and Regex.match?(@playwright_run_id_pattern, run_id) do
      raise ArgumentError, "Playwright run ID must be a canonical crypto.randomUUID value"
    end

    suffix =
      :sha256
      |> :crypto.hash(run_id)
      |> binary_part(0, @suffix_bytes)
      |> Base.encode16(case: :lower)

    %__MODULE__{
      database: @database_prefix <> suffix,
      storage_root: Path.join([System.tmp_dir!(), "singularity", "browser", suffix]),
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

  @spec force_drop!(t()) :: :ok
  def force_drop!(%__MODULE__{} = names) do
    assert_test_environment!()
    validate!(names)

    try do
      stop_repositories!()
      ensure_database_dependencies!()
      force_drop_database!(names.database)
      :ok
    after
      File.rm_rf!(names.storage_root)
    end
  end

  defp create_database!(database) do
    with_migration_repo("postgres", fn ->
      SafeSQL.query!(
        @migration_repo,
        "CREATE DATABASE #{quoted_identifier(database)}",
        [],
        log: false
      )
    end)

    with_migration_repo(database, fn ->
      SafeSQL.query!(
        @migration_repo,
        "GRANT CREATE ON DATABASE #{quoted_identifier(database)} TO singularity_table_owner",
        [],
        log: false
      )
    end)
  end

  defp drop_database!(database) do
    with_migration_repo("postgres", fn ->
      wait_for_database_disconnects!(
        database,
        @database_disconnect_attempts
      )

      SafeSQL.query!(
        @migration_repo,
        "DROP DATABASE IF EXISTS #{quoted_identifier(database)}",
        [],
        log: false
      )
    end)
  end

  defp force_drop_database!(database) do
    with_migration_repo("postgres", fn ->
      SafeSQL.query!(
        @migration_repo,
        "DROP DATABASE IF EXISTS #{quoted_identifier(database)} WITH (FORCE)",
        [],
        log: false
      )
    end)
  end

  defp wait_for_database_disconnects!(_database, 0) do
    raise "integration database connections did not drain"
  end

  defp wait_for_database_disconnects!(database, attempts) do
    %{rows: [[connection_count]]} =
      SafeSQL.query!(
        @migration_repo,
        """
        SELECT count(*)
        FROM pg_catalog.pg_stat_activity
        WHERE datname = $1
        """,
        [database],
        log: false
      )

    if connection_count == 0 do
      :ok
    else
      Process.sleep(@database_disconnect_interval_ms)
      wait_for_database_disconnects!(database, attempts - 1)
    end
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

    expected_roots =
      Enum.map(["integration", "browser"], fn environment ->
        Path.join([System.tmp_dir!(), "singularity", environment, names.suffix])
      end)

    unless names.database == expected_database and
             names.suffix =~ ~r/\A[0-9a-f]{24}\z/ and
             names.storage_root in expected_roots do
      raise ArgumentError,
            "browser/integration test environment must use its generated random suffix"
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
