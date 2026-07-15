defmodule Singularity.Architecture.DependencyGraphTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../..", __DIR__)

  @expected_dependencies %{
    singularity_core: [],
    singularity_store: [:singularity_core],
    singularity_retrieval: [:singularity_core],
    singularity_runtime: [
      :singularity_core,
      :singularity_store,
      :singularity_retrieval
    ],
    singularity_web: [:singularity_runtime]
  }

  test "child projects declare exactly the required internal dependency graph" do
    expected_apps = Map.keys(@expected_dependencies)
    actual_apps = child_apps()

    assert MapSet.new(expected_apps) == MapSet.new(actual_apps)

    actual_dependencies =
      Map.new(actual_apps, fn app ->
        {app, declared_dependencies(app)}
      end)

    assert @expected_dependencies == actual_dependencies
  end

  test "all child projects use the centralized Elixir requirement" do
    expected = Singularity.Build.elixir_requirement()

    for app <- child_apps() do
      assert expected == project_config(app)[:elixir]
    end
  end

  defp child_apps do
    @repo_root
    |> Path.join("apps/*/mix.exs")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename() |> String.to_existing_atom()))
  end

  defp declared_dependencies(app) do
    app
    |> project_config()
    |> Keyword.fetch!(:deps)
    |> Enum.map(fn
      {dependency, [in_umbrella: true]} -> dependency
      unexpected -> flunk("unexpected dependency declaration: #{inspect(unexpected)}")
    end)
  end

  defp project_config(app) do
    if app == Mix.Project.config()[:app] do
      Mix.Project.config()
    else
      path = Path.join(@repo_root, "apps/#{app}")

      Mix.Project.in_project(app, path, fn _module ->
        Mix.Project.config()
      end)
    end
  end
end
