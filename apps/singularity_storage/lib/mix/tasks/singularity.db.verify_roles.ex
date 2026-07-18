defmodule Mix.Tasks.Singularity.Db.VerifyRoles do
  use Mix.Task

  @shortdoc "Verifies externally provisioned PostgreSQL roles"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    Singularity.Storage.RoleVerifier.verify!()
    Mix.shell().info("PostgreSQL role contract verified")
  end
end
