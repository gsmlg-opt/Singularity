defmodule Singularity.Storage.TestEnvironmentTest do
  use ExUnit.Case, async: false

  alias Singularity.Storage.TestEnvironment

  test "defines one migration repo and four distinct runtime repos" do
    repos = [
      Singularity.Storage.MigrationRepo,
      Singularity.Storage.RequestRepo,
      Singularity.Storage.PreAuthRepo,
      Singularity.Storage.DispatcherRepo,
      Singularity.Storage.WorkerRepo
    ]

    assert Enum.uniq(repos) == repos

    for repo <- repos do
      assert repo.__adapter__() == Ecto.Adapters.Postgres
    end
  end

  test "allocates a random database and storage root with the same suffix" do
    names = TestEnvironment.allocate!()

    assert <<"singularity_test_", suffix::binary-size(24)>> = names.database
    assert suffix =~ ~r/\A[0-9a-f]{24}\z/
    assert Path.basename(names.storage_root) == suffix
    refute File.exists?(names.storage_root)
  end

  test "derives a deterministic browser environment from a canonical Playwright run ID" do
    run_id = "123e4567-e89b-42d3-a456-426614174000"
    other_run_id = "123e4567-e89b-42d3-a456-426614174001"

    assert %TestEnvironment{
             database: "singularity_test_320159ebe3219112484baaa0",
             storage_root: storage_root,
             suffix: "320159ebe3219112484baaa0"
           } = TestEnvironment.from_playwright_run_id!(run_id)

    assert storage_root ==
             Path.join([
               System.tmp_dir!(),
               "singularity",
               "browser",
               "320159ebe3219112484baaa0"
             ])

    assert TestEnvironment.from_playwright_run_id!(run_id) ==
             TestEnvironment.from_playwright_run_id!(run_id)

    refute TestEnvironment.from_playwright_run_id!(run_id) ==
             TestEnvironment.from_playwright_run_id!(other_run_id)
  end

  test "refuses malformed or noncanonical Playwright run IDs" do
    invalid_run_ids = [
      nil,
      "not-a-uuid",
      "123E4567-E89B-42D3-A456-426614174000",
      "123e4567-e89b-12d3-a456-426614174000",
      "123e4567-e89b-42d3-7456-426614174000"
    ]

    for run_id <- invalid_run_ids do
      assert_raise ArgumentError, ~r/canonical crypto.randomUUID/, fn ->
        TestEnvironment.from_playwright_run_id!(run_id)
      end
    end
  end

  test "create accepts the exact generated browser root before database configuration" do
    names =
      TestEnvironment.from_playwright_run_id!("123e4567-e89b-42d3-a456-426614174002")

    previous_pg_port = System.get_env("PGPORT")
    System.put_env("PGPORT", "invalid")

    try do
      assert_raise ArgumentError, ~r/PGPORT must be a valid PostgreSQL port/, fn ->
        TestEnvironment.create!(names)
      end
    after
      restore_env("PGPORT", previous_pg_port)
      File.rm_rf!(names.storage_root)
      File.rm_rf!(names.storage_root <> "-backups")
      File.rm_rf!(names.storage_root <> "-knowledge-export")
    end
  end

  test "create rejects path traversal and arbitrary storage roots" do
    names =
      TestEnvironment.from_playwright_run_id!("123e4567-e89b-42d3-a456-426614174003")

    tampered_roots = [
      Path.join([names.storage_root, "..", names.suffix]),
      Path.join([System.tmp_dir!(), "singularity", "browser", "arbitrary"])
    ]

    previous_pg_port = System.get_env("PGPORT")
    System.put_env("PGPORT", "invalid")

    try do
      for storage_root <- tampered_roots do
        tampered_names = %{names | storage_root: storage_root}

        assert_raise ArgumentError, ~r/test environment.*generated random suffix/, fn ->
          TestEnvironment.create!(tampered_names)
        end
      end
    after
      restore_env("PGPORT", previous_pg_port)
      File.rm_rf!(names.storage_root)
    end
  end

  test "refuses a database name without the generated random suffix" do
    names = %{TestEnvironment.allocate!() | database: "singularity_test"}

    assert_raise ArgumentError, ~r/test environment.*generated random suffix/, fn ->
      TestEnvironment.create!(names)
    end
  end

  test "create, drop, and force drop independently refuse a non-test Mix environment" do
    names = %TestEnvironment{
      database: "must_not_connect",
      storage_root: "/must_not_touch",
      suffix: "invalid"
    }

    previous_mix_env = Mix.env()
    Mix.env(:dev)

    try do
      for operation <- [
            &TestEnvironment.create!/1,
            &TestEnvironment.drop!/1,
            &TestEnvironment.force_drop!/1
          ] do
        assert_raise ArgumentError, ~r/integration environment requires MIX_ENV=test/, fn ->
          operation.(names)
        end
      end
    after
      Mix.env(previous_mix_env)
    end
  end

  test "force drop rejects tampered database, suffix, and root before cleanup" do
    names =
      TestEnvironment.from_playwright_run_id!("123e4567-e89b-42d3-a456-426614174004")

    sentinel = Path.join(names.storage_root, "must-survive")
    File.mkdir_p!(names.storage_root)
    File.write!(sentinel, "safe")

    tampered_names = [
      %{names | database: names.database <> "_tampered"},
      %{names | suffix: String.duplicate("0", 24)},
      %{names | storage_root: names.storage_root <> "-tampered"}
    ]

    try do
      for tampered <- tampered_names do
        assert_raise ArgumentError, ~r/test environment.*generated random suffix/, fn ->
          TestEnvironment.force_drop!(tampered)
        end

        assert File.read!(sentinel) == "safe"
      end
    after
      File.rm_rf!(names.storage_root)
    end
  end

  @tag :integration
  test "force drop terminates runtime and migration connections and removes only its browser environment" do
    names =
      TestEnvironment.from_playwright_run_id!("123e4567-e89b-42d3-a456-426614174006")

    runtime_repositories = [
      Singularity.Storage.RequestRepo,
      Singularity.Storage.PreAuthRepo,
      Singularity.Storage.DispatcherRepo,
      Singularity.Storage.WorkerRepo
    ]

    storage_configuration =
      Enum.map(
        [
          :storage_root,
          :backup_root,
          Singularity.Storage.MigrationRepo
          | runtime_repositories
        ],
        fn key -> {key, Application.fetch_env(:singularity_storage, key)} end
      )

    previous_export_root = Application.fetch_env(:singularity_runtime, :knowledge_export_root)

    outer_database =
      :singularity_storage
      |> Application.fetch_env!(Singularity.Storage.RequestRepo)
      |> Keyword.fetch!(:database)

    sibling_root = names.storage_root <> "-sibling"
    sibling_sentinel = Path.join(sibling_root, "must-survive")

    try do
      assert :ok = Application.stop(:singularity_runtime)

      try do
        TestEnvironment.create!(names)
        File.mkdir_p!(sibling_root)
        File.write!(sibling_sentinel, "safe")

        {:ok, connection} =
          Postgrex.start_link(postgrex_options(names.database, "singularity_worker"))

        Process.unlink(connection)

        try do
          {:ok, migration_connection} = Postgrex.start_link(postgrex_options(names.database))
          Process.unlink(migration_connection)

          try do
            assert :ok = TestEnvironment.force_drop!(names)
            assert Process.alive?(connection)

            {:ok, postgres_connection} = Postgrex.start_link(postgrex_options("postgres"))
            Process.unlink(postgres_connection)

            try do
              assert %{rows: [[false]]} =
                       Postgrex.query!(
                         postgres_connection,
                         "SELECT EXISTS(SELECT 1 FROM pg_catalog.pg_database WHERE datname = $1)",
                         [names.database]
                       )
            after
              GenServer.stop(postgres_connection)
            end

            refute File.exists?(names.storage_root)
            assert File.read!(sibling_sentinel) == "safe"
          after
            if Process.alive?(migration_connection), do: GenServer.stop(migration_connection)
          end
        after
          if Process.alive?(connection), do: GenServer.stop(connection)
        end
      after
        TestEnvironment.force_drop!(names)
        File.rm_rf!(names.storage_root)
        File.rm_rf!(sibling_root)
      end
    after
      Enum.each(storage_configuration, fn
        {key, {:ok, value}} -> Application.put_env(:singularity_storage, key, value)
        {key, :error} -> Application.delete_env(:singularity_storage, key)
      end)

      case previous_export_root do
        {:ok, value} -> Application.put_env(:singularity_runtime, :knowledge_export_root, value)
        :error -> Application.delete_env(:singularity_runtime, :knowledge_export_root)
      end

      assert {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
    end

    for repository <- runtime_repositories do
      assert is_pid(Process.whereis(repository))

      assert %{rows: [[^outer_database]]} =
               Ecto.Adapters.SQL.query!(
                 repository,
                 "SELECT current_database()",
                 [],
                 log: false
               )
    end
  end

  test "force drop removes only the exact browser root when database configuration fails" do
    names =
      TestEnvironment.from_playwright_run_id!("123e4567-e89b-42d3-a456-426614174005")

    sibling_root = names.storage_root <> "-sibling"
    sibling_artifact = Path.join(sibling_root, "must-survive")
    File.mkdir_p!(names.storage_root)
    File.write!(Path.join(names.storage_root, "sensitive-test-artifact"), "test")
    File.mkdir_p!(sibling_root)
    File.write!(sibling_artifact, "safe")

    previous_pg_port = System.get_env("PGPORT")
    System.put_env("PGPORT", "invalid")

    try do
      assert_raise ArgumentError, ~r/PGPORT must be a valid PostgreSQL port/, fn ->
        TestEnvironment.force_drop!(names)
      end

      refute File.exists?(names.storage_root)
      assert File.read!(sibling_artifact) == "safe"
    after
      restore_env("PGPORT", previous_pg_port)
      File.rm_rf!(names.storage_root)
      File.rm_rf!(sibling_root)
    end
  end

  test "removes the exact storage root when database teardown raises" do
    names = TestEnvironment.allocate!()
    File.mkdir_p!(names.storage_root)
    File.write!(Path.join(names.storage_root, "sensitive-test-artifact"), "test")

    previous_pg_port = System.get_env("PGPORT")
    System.put_env("PGPORT", "invalid")

    try do
      assert_raise ArgumentError, ~r/PGPORT must be a valid PostgreSQL port/, fn ->
        TestEnvironment.drop!(names)
      end
    after
      if previous_pg_port do
        System.put_env("PGPORT", previous_pg_port)
      else
        System.delete_env("PGPORT")
      end
    end

    refute File.exists?(names.storage_root)
  end

  @tag :integration
  @tag timeout: 75_000
  test "database drop has a bounded maintenance budget independent of ordinary query timeouts" do
    names = TestEnvironment.allocate!()
    repo = Singularity.Storage.MigrationRepo
    previous_config = Application.fetch_env!(:singularity_storage, repo)

    outer_database =
      Application.fetch_env!(:singularity_storage, Singularity.Storage.RequestRepo)
      |> Keyword.fetch!(:database)

    supervisor = start_supervised!(Task.Supervisor)
    ordinary_timeout_ms = 1_000
    assert :ok = Application.stop(:singularity_runtime)

    try do
      {:ok, connection} = Postgrex.start_link(postgrex_options("postgres"))
      Process.unlink(connection)

      try do
        Postgrex.query!(connection, ~s(CREATE DATABASE "#{names.database}"), [])
        File.mkdir_p!(names.storage_root)

        try do
          # The same database is renamed back before commit. Its object lock
          # remains held, providing an observed, deterministic DROP barrier.
          Postgrex.query!(connection, "BEGIN", [])

          Postgrex.query!(
            connection,
            ~s(ALTER DATABASE "#{names.database}" RENAME TO "#{names.database}_barrier"),
            []
          )

          Postgrex.query!(
            connection,
            ~s(ALTER DATABASE "#{names.database}_barrier" RENAME TO "#{names.database}"),
            []
          )

          Application.put_env(
            :singularity_storage,
            repo,
            Keyword.put(previous_config, :timeout, ordinary_timeout_ms)
          )

          # Prime the transaction's statistics snapshot before DROP starts so
          # the observer must refresh it, regardless of task scheduling.
          Postgrex.query!(connection, "SELECT count(*) FROM pg_stat_activity", [])

          dropping =
            Task.Supervisor.async_nolink(supervisor, fn ->
              try do
                TestEnvironment.drop!(names)
              rescue
                error -> {:failed, error.__struct__}
              end
            end)

          try do
            assert await_database_drop_lock(
                     connection,
                     names.database,
                     System.monotonic_time(:millisecond) + 4_000
                   )

            # This wait deliberately crosses the configured ordinary-query
            # budget after SQL proves DROP is blocked, not a guessed startup delay.
            assert Task.yield(dropping, ordinary_timeout_ms + 100) == nil
            assert Keyword.fetch!(repo.config(), :timeout) == ordinary_timeout_ms
            Postgrex.query!(connection, "ROLLBACK", [])
            assert :ok = Task.await(dropping, 65_000)

            assert %{rows: [[false, true]]} =
                     Postgrex.query!(
                       connection,
                       "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = $1), EXISTS(SELECT 1 FROM pg_database WHERE datname = $2)",
                       [names.database, outer_database]
                     )

            refute File.exists?(names.storage_root)
          after
            Postgrex.query!(connection, "ROLLBACK", [])
            Task.shutdown(dropping, :brutal_kill)
          end
        after
          Postgrex.query!(connection, "ROLLBACK", [])

          try do
            Postgrex.query!(connection, ~s(DROP DATABASE IF EXISTS "#{names.database}"), [],
              timeout: 60_000
            )
          after
            File.rm_rf!(names.storage_root)
          end
        end
      after
        if Process.alive?(connection), do: GenServer.stop(connection)
      end
    after
      Application.put_env(:singularity_storage, repo, previous_config)
      assert {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
    end
  end

  # BEGIN Task16 isolated export-root compatibility contracts
  test "create provisions an isolated backup sibling before database configuration" do
    names = TestEnvironment.allocate!()
    roots = isolated_export_roots(names)
    previous_pg_port = System.get_env("PGPORT")
    System.put_env("PGPORT", "invalid")

    try do
      assert Map.keys(Map.from_struct(names)) |> Enum.sort() ==
               [:database, :storage_root, :suffix]

      assert_raise ArgumentError, ~r/PGPORT must be a valid PostgreSQL port/, fn ->
        TestEnvironment.create!(names)
      end

      assert File.dir?(roots.storage_root)
      assert File.dir?(roots.backup_root)
      assert File.dir?(Path.dirname(roots.root))
      assert {:error, :enoent} = File.lstat(roots.root)

      for left <- Map.values(roots), right <- Map.values(roots), left != right do
        refute String.starts_with?(left, right <> "/")
      end
    after
      restore_env("PGPORT", previous_pg_port)
      Enum.each(Map.values(roots), &File.rm_rf!/1)
    end
  end

  for operation <- [:drop!, :force_drop!] do
    test "#{operation} removes all exact isolated roots when database configuration fails" do
      names = TestEnvironment.allocate!()
      roots = isolated_export_roots(names)
      sibling = names.storage_root <> "-unrelated"
      sentinel = Path.join(sibling, "must-survive")

      for root <- Map.values(roots) do
        File.mkdir_p!(root)
        File.write!(Path.join(root, "owned-test-artifact"), "owned")
      end

      File.mkdir_p!(sibling)
      File.write!(sentinel, "unrelated")
      previous_pg_port = System.get_env("PGPORT")
      System.put_env("PGPORT", "invalid")

      try do
        assert_raise ArgumentError, ~r/PGPORT must be a valid PostgreSQL port/, fn ->
          apply(TestEnvironment, unquote(operation), [names])
        end

        for root <- Map.values(roots), do: assert({:error, :enoent} = File.lstat(root))
        assert File.read!(sentinel) == "unrelated"
      after
        restore_env("PGPORT", previous_pg_port)
        Enum.each(Map.values(roots), &File.rm_rf!/1)
        File.rm_rf!(sibling)
      end
    end

    @tag :tmp_dir
    test "#{operation} never follows isolated backup or export symlinks", %{tmp_dir: tmp} do
      names = TestEnvironment.allocate!()
      roots = isolated_export_roots(names)
      target = Path.join(tmp, "external-target")
      sentinel = Path.join(target, "must-survive")
      File.mkdir_p!(target)
      File.write!(sentinel, "external")
      File.mkdir_p!(roots.storage_root)
      File.ln_s!(target, roots.backup_root)
      File.ln_s!(target, roots.root)
      previous_pg_port = System.get_env("PGPORT")
      System.put_env("PGPORT", "invalid")

      try do
        assert_raise ArgumentError, ~r/PGPORT must be a valid PostgreSQL port/, fn ->
          apply(TestEnvironment, unquote(operation), [names])
        end

        for root <- Map.values(roots), do: assert({:error, :enoent} = File.lstat(root))
        assert File.read!(sentinel) == "external"
        assert {:ok, %{type: :directory}} = File.lstat(target)
      after
        restore_env("PGPORT", previous_pg_port)
        Enum.each(Map.values(roots), &File.rm_rf!/1)
      end
    end
  end

  @tag :tmp_dir
  test "create refuses symlink root leaves before database configuration", %{tmp_dir: tmp} do
    previous_pg_port = System.get_env("PGPORT")
    System.put_env("PGPORT", "invalid")

    try do
      for key <- [:storage_root, :backup_root, :root] do
        names = TestEnvironment.allocate!()
        roots = isolated_export_roots(names)
        target = Path.join(tmp, Atom.to_string(key))
        sentinel = Path.join(target, "must-survive")
        File.mkdir_p!(target)
        File.write!(sentinel, "external")
        File.mkdir_p!(Path.dirname(names.storage_root))
        File.ln_s!(target, Map.fetch!(roots, key))

        try do
          assert_raise ArgumentError, ~r/symlink/, fn ->
            TestEnvironment.create!(names)
          end

          assert File.read!(sentinel) == "external"
          assert {:ok, %{type: :symlink}} = File.lstat(Map.fetch!(roots, key))
          assert File.ls!(target) == ["must-survive"]
        after
          Enum.each(Map.values(roots), &File.rm_rf!/1)
        end
      end
    after
      restore_env("PGPORT", previous_pg_port)
    end
  end

  @tag :integration
  test "create configures disjoint run-owned roots accepted by the unchanged export directory guard" do
    names = TestEnvironment.allocate!()
    roots = isolated_export_roots(names)

    storage_configuration =
      Enum.map(
        [
          :storage_root,
          :backup_root,
          Singularity.Storage.MigrationRepo,
          Singularity.Storage.RequestRepo,
          Singularity.Storage.PreAuthRepo,
          Singularity.Storage.DispatcherRepo,
          Singularity.Storage.WorkerRepo
        ],
        fn key -> {key, Application.fetch_env(:singularity_storage, key)} end
      )

    previous_export_root = Application.fetch_env(:singularity_runtime, :knowledge_export_root)
    assert :ok = Application.stop(:singularity_runtime)

    try do
      assert :ok = TestEnvironment.create!(names)

      assert Application.fetch_env!(:singularity_storage, :storage_root) == roots.storage_root
      assert Application.fetch_env!(:singularity_storage, :backup_root) == roots.backup_root
      assert Application.fetch_env!(:singularity_runtime, :knowledge_export_root) == roots.root
      assert {:error, :enoent} = File.lstat(roots.root)

      assert {:ok, %{root: export_root}} =
               Singularity.Storage.KnowledgeExport.ArtifactDirectory.prepare(roots)

      assert export_root == roots.root
      assert {:ok, %{mode: mode}} = File.lstat(export_root)
      assert Bitwise.band(mode, 0o777) == 0o700

      for root <- Map.values(roots) do
        File.write!(Path.join(root, "owned-test-artifact"), "owned")
      end

      assert :ok = TestEnvironment.drop!(names)
      for root <- Map.values(roots), do: assert({:error, :enoent} = File.lstat(root))
    after
      try do
        TestEnvironment.force_drop!(names)
      after
        Enum.each(Map.values(roots), &File.rm_rf!/1)

        Enum.each(storage_configuration, fn
          {key, {:ok, value}} -> Application.put_env(:singularity_storage, key, value)
          {key, :error} -> Application.delete_env(:singularity_storage, key)
        end)

        case previous_export_root do
          {:ok, value} -> Application.put_env(:singularity_runtime, :knowledge_export_root, value)
          :error -> Application.delete_env(:singularity_runtime, :knowledge_export_root)
        end

        assert {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
      end
    end
  end

  defp isolated_export_roots(names) do
    %{
      storage_root: names.storage_root,
      backup_root: names.storage_root <> "-backups",
      root: names.storage_root <> "-knowledge-export"
    }
  end

  # END Task16 isolated export-root compatibility contracts

  defp await_database_drop_lock(connection, database, deadline) do
    Postgrex.query!(connection, "SELECT pg_stat_clear_snapshot()", [])

    %{rows: [[waiting?]]} =
      Postgrex.query!(
        connection,
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_stat_activity
          WHERE query = $1 AND wait_event_type = 'Lock'
            AND pg_backend_pid() = ANY(pg_blocking_pids(pid))
        )
        """,
        [~s(DROP DATABASE IF EXISTS "#{database}")]
      )

    cond do
      waiting? ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        await_database_drop_lock(connection, database, deadline)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp postgrex_options(database, username \\ "singularity_migration") do
    [
      username: username,
      database: database,
      socket_dir: System.fetch_env!("PGHOST"),
      port: String.to_integer(System.fetch_env!("PGPORT")),
      log: false
    ]
  end
end
