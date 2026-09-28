Code.require_file("../../build/project.exs", __DIR__)

defmodule Singularity.Ingest.MixProject do
  use Mix.Project

  def project do
    [
      app: :singularity_ingest,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: Singularity.Build.elixir_requirement(),
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: internal_deps()
    ]
  end

  defp internal_deps do
    [
      {:singularity_core, in_umbrella: true},
      {:singularity_domains, in_umbrella: true},
      {:ex_cmd, "~> 0.18.0"},
      {:elixir_make, "~> 0.10", runtime: false}
    ]
  end
end
