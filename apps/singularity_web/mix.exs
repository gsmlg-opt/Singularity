Code.require_file("../../build/project.exs", __DIR__)

defmodule Singularity.Web.MixProject do
  use Mix.Project

  def project do
    [
      app: :singularity_web,
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
      mod: {Singularity.Web.Application, []}
    ]
  end

  defp deps do
    [
      {:singularity_runtime, in_umbrella: true},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.2"},
      {:bandit, "~> 1.12"},
      {:duskmoon_bundler_runtime, "~> 9.9.7"},
      {:duskmoon_bundler, "~> 9.9.7", runtime: Mix.env() in [:dev, :test]},
      {:floki, ">= 0.36.0", only: :test},
      {:lazy_html, ">= 0.1.0"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
