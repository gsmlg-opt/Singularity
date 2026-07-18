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

    try do
      Singularity.Storage.TestEnvironment.create!(names)
      Mix.Task.run("test", ["--only", "integration" | args])
    after
      Singularity.Storage.TestEnvironment.drop!(names)
    end
  end

  defp assert_test_environment! do
    if Mix.env() != :test do
      Mix.raise("singularity.test.integration requires MIX_ENV=test")
    end
  end
end
