Code.require_file("../../build/project.exs", __DIR__)

defmodule Singularity.Runtime.MixProject do
  use Mix.Project

  def project do
    [
      app: :singularity_runtime,
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
      {:singularity_storage, in_umbrella: true},
      {:singularity_domains, in_umbrella: true},
      {:singularity_ingest, in_umbrella: true},
      {:singularity_retrieval, in_umbrella: true},
      {:logger_json, "~> 7.0"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"}
    ]
  end
end
