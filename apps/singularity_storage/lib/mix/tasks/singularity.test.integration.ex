defmodule Mix.Tasks.Singularity.Test.Integration do
  use Mix.Task

  @shortdoc "Runs PostgreSQL integration tests in an isolated database"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    assert_test_environment!()
    Singularity.Storage.RoleVerifier.verify!()
    names = Singularity.Storage.TestEnvironment.allocate!()
    Mix.shell().info("database=#{names.database} storage_root=#{names.storage_root}")
    previous_start = Application.get_env(:singularity_runtime, :start_infrastructure, false)

    try do
      Singularity.Storage.TestEnvironment.create!(names)
      stop_runtime_repositories()
      Application.put_env(:singularity_runtime, :start_infrastructure, true)
      {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
      Mix.Task.run("test", ["--only", "integration" | args])
    after
      Application.stop(:singularity_runtime)
      Application.put_env(:singularity_runtime, :start_infrastructure, previous_start)
      Singularity.Storage.TestEnvironment.drop!(names)
    end
  end

  defp assert_test_environment! do
    if Mix.env() != :test do
      Mix.raise("singularity.test.integration requires MIX_ENV=test")
    end
  end

  defp stop_runtime_repositories do
    for repo <- [
          Singularity.Storage.RequestRepo,
          Singularity.Storage.PreAuthRepo,
          Singularity.Storage.DispatcherRepo,
          Singularity.Storage.WorkerRepo
        ] do
      case Process.whereis(repo) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end
    end
  end
end
