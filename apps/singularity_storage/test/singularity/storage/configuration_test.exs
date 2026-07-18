defmodule Singularity.Storage.ConfigurationTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../..", __DIR__)

  @runtime_repos [
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo
  ]

  @production_database_env %{
    "SINGULARITY_MIGRATION_DATABASE_URL" =>
      "postgresql://singularity_migration:secret@localhost/singularity_prod",
    "SINGULARITY_DATABASE_URL" =>
      "postgresql://singularity_request:secret@localhost/singularity_prod",
    "SINGULARITY_PRE_AUTH_DATABASE_URL" =>
      "postgresql://singularity_pre_auth:secret@localhost/singularity_prod",
    "SINGULARITY_DISPATCHER_DATABASE_URL" =>
      "postgresql://singularity_dispatcher:secret@localhost/singularity_prod",
    "SINGULARITY_WORKER_DATABASE_URL" =>
      "postgresql://singularity_worker:secret@localhost/singularity_prod"
  }

  test "runtime pools and migration pool are distinct" do
    runtime_urls =
      for repo <- [
            Singularity.Storage.RequestRepo,
            Singularity.Storage.PreAuthRepo,
            Singularity.Storage.DispatcherRepo,
            Singularity.Storage.WorkerRepo
          ] do
        Application.fetch_env!(:singularity_storage, repo) |> Keyword.fetch!(:url)
      end

    migration_url =
      Application.fetch_env!(:singularity_storage, Singularity.Storage.MigrationRepo)
      |> Keyword.fetch!(:url)

    assert length(Enum.uniq(runtime_urls)) == 4
    refute migration_url in runtime_urls
    assert Application.fetch_env!(:singularity_runtime, :max_upload_bytes) == 536_870_912
    assert Application.fetch_env!(:singularity_runtime, :max_concurrent_uploads) == 2

    assert Application.fetch_env!(
             :singularity_storage,
             Singularity.Storage.RequestRepo
           )[:pool_size] >= 10

    assert Application.fetch_env!(:singularity_storage, Oban)[:prefix] == "jobs"
  end

  test "test storage root is scoped beneath the generated test directory" do
    storage_root = Application.fetch_env!(:singularity_storage, :storage_root)

    test_run_id =
      System.get_env("SINGULARITY_TEST_RUN_ID", "default")
      |> String.replace(~r/[^[:alnum:]_]/u, "_")

    relative_root = Path.relative_to(storage_root, System.tmp_dir!())

    refute Path.type(relative_root) == :absolute
    refute String.starts_with?(relative_root, "..")
    assert test_run_id in Path.split(relative_root)
  end

  test "JSON consumers use Elixir's built-in JSON module" do
    assert Application.fetch_env!(:phoenix, :json_library) == JSON
    assert Application.fetch_env!(:logger_json, :encoder) == JSON
  end

  test "production compile configuration does not require a missing environment file" do
    config =
      @repo_root
      |> Path.join("config/config.exs")
      |> Config.Reader.read!(env: :prod)

    assert config
           |> Keyword.fetch!(:singularity_runtime)
           |> Keyword.fetch!(:max_upload_bytes) == 536_870_912
  end

  test "runtime repositories never use migration or superuser credentials" do
    migration_url =
      Application.fetch_env!(:singularity_storage, Singularity.Storage.MigrationRepo)
      |> Keyword.fetch!(:url)

    for repo <- @runtime_repos do
      runtime_url =
        Application.fetch_env!(:singularity_storage, repo)
        |> Keyword.fetch!(:url)

      refute runtime_url == migration_url
      refute database_username(runtime_url) in ["postgres", "root", "singularity_migration"]
    end
  end

  test "production requires an explicit storage root" do
    runtime_config = Path.join(@repo_root, "config/runtime.exs")

    assert_raise System.EnvError, ~r/SINGULARITY_STORAGE_ROOT/, fn ->
      with_environment(
        Map.merge(@production_database_env, %{
          "SINGULARITY_STORAGE_ROOT" => nil,
          "SINGULARITY_MAX_CONCURRENT_UPLOADS" => nil
        }),
        fn -> Config.Reader.read!(runtime_config, env: :prod) end
      )
    end
  end

  test "production upload concurrency stays below the configured request pool size" do
    repo = Singularity.Storage.RequestRepo
    original_config = Application.fetch_env!(:singularity_storage, repo)

    on_exit(fn ->
      Application.put_env(:singularity_storage, repo, original_config)
    end)

    Application.put_env(
      :singularity_storage,
      repo,
      Keyword.put(original_config, :pool_size, 3)
    )

    environment =
      Map.merge(@production_database_env, %{
        "SINGULARITY_STORAGE_ROOT" => Path.join(System.tmp_dir!(), "singularity-production"),
        "SINGULARITY_MAX_CONCURRENT_UPLOADS" => "3"
      })

    assert_raise ArgumentError, ~r/below RequestRepo pool size 3/, fn ->
      with_environment(environment, fn ->
        @repo_root
        |> Path.join("config/runtime.exs")
        |> Config.Reader.read!(env: :prod)
      end)
    end
  end

  test "role provisioner configuration and repository are absent" do
    refute Keyword.has_key?(
             Application.get_all_env(:singularity_storage),
             Singularity.Storage.RoleProvisionerRepo
           )

    refute Code.ensure_loaded?(Singularity.Storage.RoleProvisionerRepo)

    config_source =
      @repo_root
      |> Path.join("config/*.exs")
      |> Path.wildcard()
      |> Enum.map_join(&File.read!/1)

    refute config_source =~ "SINGULARITY_ROLE_PROVISIONER_DATABASE_URL"
  end

  defp database_username(url) do
    url
    |> URI.parse()
    |> Map.fetch!(:userinfo)
    |> String.split(":", parts: 2)
    |> hd()
  end

  defp with_environment(environment, fun) do
    previous = Map.new(environment, fn {name, _value} -> {name, System.get_env(name)} end)

    Enum.each(environment, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
