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
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Singularity.Runtime.Application, []}
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
