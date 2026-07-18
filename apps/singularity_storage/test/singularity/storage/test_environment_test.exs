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

  test "refuses a database name without the generated random suffix" do
    names = %{TestEnvironment.allocate!() | database: "singularity_test"}

    assert_raise ArgumentError, ~r/generated random suffix/, fn ->
      TestEnvironment.create!(names)
    end
  end

  test "create and drop independently refuse a non-test Mix environment" do
    names = %TestEnvironment{
      database: "must_not_connect",
      storage_root: "/must_not_touch",
      suffix: "invalid"
    }

    previous_mix_env = Mix.env()
    Mix.env(:dev)

    try do
      for operation <- [&TestEnvironment.create!/1, &TestEnvironment.drop!/1] do
        assert_raise ArgumentError, ~r/integration environment requires MIX_ENV=test/, fn ->
          operation.(names)
        end
      end
    after
      Mix.env(previous_mix_env)
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
end
