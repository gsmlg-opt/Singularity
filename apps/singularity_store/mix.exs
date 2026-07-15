Code.require_file("../../build/project.exs", __DIR__)

defmodule Singularity.Store.MixProject do
  use Mix.Project

  def project do
    [
      app: :singularity_store,
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

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:singularity_core, in_umbrella: true}
    ]
  end
end
