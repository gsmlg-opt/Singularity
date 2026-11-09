defmodule Singularity.Release do
  @moduledoc "Release tasks: `bin/singularity eval Singularity.Release.migrate`."

  @app :singularity

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Singularity.Repo, fn _repo ->
        Singularity.Sources.ensure_default_source()
      end)

    :ok
  end
end
