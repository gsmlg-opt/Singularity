Code.require_file("build/project.exs", __DIR__)

defmodule Singularity.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      elixir: Singularity.Build.elixir_requirement(),
      start_permanent: Mix.env() == :prod,
      preferred_cli_env: [
        "singularity.test.integration": :test,
        "singularity.test.restore": :test,
        "singularity.test.browser": :test
      ],
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    []
  end

  defp aliases do
    [
      "assets.build": ["duskmoon_bundler.build singularity_web --tailwind"],
      "assets.deploy": [
        "duskmoon_bundler.build singularity_web --tailwind",
        "phx.digest"
      ]
    ]
  end
end
