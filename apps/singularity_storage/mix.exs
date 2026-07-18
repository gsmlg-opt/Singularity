Code.require_file("../../build/project.exs", __DIR__)

defmodule Singularity.Storage.MixProject do
  use Mix.Project

  def project do
    [
      app: :singularity_storage,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: Singularity.Build.elixir_requirement(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp deps do
    [
      {:singularity_core, in_umbrella: true},
      {:singularity_domains, in_umbrella: true},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22.3"},
      {:oban, "~> 2.23"},
      {:argon2_elixir, "~> 4.1"},
      {:telemetry, "~> 1.4"}
    ]
  end
end
