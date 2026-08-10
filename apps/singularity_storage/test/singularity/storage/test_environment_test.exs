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
  test "force drop terminates an independent connection and removes only its browser environment" do
    names =
      TestEnvironment.from_playwright_run_id!("123e4567-e89b-42d3-a456-426614174006")

    sibling_root = names.storage_root <> "-sibling"
    sibling_sentinel = Path.join(sibling_root, "must-survive")
    connection = nil

    try do
      TestEnvironment.create!(names)
      File.mkdir_p!(sibling_root)
      File.write!(sibling_sentinel, "safe")

      {:ok, connection} =
        Postgrex.start_link(postgrex_options(names.database) ++ [backoff_type: :stop])

      Process.unlink(connection)
      monitor_ref = Process.monitor(connection)

      assert :ok = TestEnvironment.force_drop!(names)
      assert catch_exit(Postgrex.query(connection, "SELECT 1", []))
      assert_receive {:DOWN, ^monitor_ref, :process, ^connection, _reason}, 1_000

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
      if connection && Process.alive?(connection), do: GenServer.stop(connection)

      TestEnvironment.force_drop!(names)
      File.rm_rf!(names.storage_root)
      File.rm_rf!(sibling_root)
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

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp postgrex_options(database) do
    [
      username: "singularity_migration",
      database: database,
      socket_dir: System.fetch_env!("PGHOST"),
      port: String.to_integer(System.fetch_env!("PGPORT")),
      log: false
    ]
  end
end
