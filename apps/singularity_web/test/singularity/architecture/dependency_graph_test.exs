defmodule Singularity.Architecture.DependencyGraphTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../..", __DIR__)

  @expected %{
    singularity_core: [],
    singularity_domains: [:singularity_core],
    singularity_storage: [:singularity_core, :singularity_domains],
    singularity_ingest: [:singularity_core, :singularity_domains],
    singularity_retrieval: [:singularity_core, :singularity_domains],
    singularity_runtime: [
      :singularity_core,
      :singularity_domains,
      :singularity_ingest,
      :singularity_retrieval,
      :singularity_storage
    ],
    singularity_web: [:singularity_runtime]
  }

  @forbidden_web_modules ~w[
    Singularity.Core
    Singularity.Domains
    Singularity.Storage
    Singularity.Ingest
    Singularity.Retrieval
  ]

  test "child projects declare exactly the required internal dependency graph" do
    expected_apps = Map.keys(@expected)
    actual_apps = child_apps()

    assert MapSet.new(expected_apps) == MapSet.new(actual_apps)

    actual_dependencies =
      Map.new(actual_apps, fn app ->
        {app, declared_dependencies(app)}
      end)

    assert @expected == actual_dependencies
  end

  test "web source does not reference modules below the runtime boundary" do
    @repo_root
    |> Path.join("apps/singularity_web/lib/**/*.{ex,exs,heex}")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      source = File.read!(path)

      assert [] == forbidden_web_references(source),
             "#{Path.relative_to(path, @repo_root)} references a forbidden lower-layer module"
    end)
  end

  test "web production source references only Runtime.Api and Runtime DTOs" do
    runtime_references =
      @repo_root
      |> Path.join("apps/singularity_web/lib/**/*.{ex,exs,heex}")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(&Regex.scan(~r/\bSingularity\.Runtime(?:\.[A-Z][A-Za-z0-9_]*)+/, &1))
        |> List.flatten()
      end)
      |> Enum.uniq()

    assert Enum.all?(runtime_references, fn reference ->
             reference == "Singularity.Runtime.Api" or
               String.starts_with?(reference, "Singularity.Runtime.Api.") or
               String.starts_with?(reference, "Singularity.Runtime.DTO.")
           end)
  end

  test "web source rejects forbidden modules in grouped aliases" do
    source = "alias Singularity.{Core, Runtime}"

    assert ["Singularity.Core"] == forbidden_web_references(source)
  end

  test "web source rejects forbidden modules through a renamed Singularity alias" do
    source = """
    alias Singularity,
      as: Root

    Root.Core.call()
    Root.Runtime.call()
    """

    assert ["Singularity.Core"] == forbidden_web_references(source)
  end

  test "web source rejects direct modules with whitespace before the dot" do
    source = """
    Singularity . Core.call()
    Singularity . Runtime.call()
    """

    assert ["Singularity.Core"] == forbidden_web_references(source)
  end

  test "web source rejects direct modules with a dot on the next line" do
    source = """
    Singularity
    .Core.call()

    Singularity
    .Runtime.call()
    """

    assert ["Singularity.Core"] == forbidden_web_references(source)
  end

  test "web source rejects forbidden modules through a parenthesized renamed alias" do
    source = """
    alias(Singularity, as: Root)
    Root.Core.call()
    Root.Runtime.call()
    """

    assert ["Singularity.Core"] == forbidden_web_references(source)
  end

  test "valid Elixir source ignores forbidden module names in strings and comments" do
    source = ~S"""
    # Singularity.Core.call()
    "Singularity.Domains"
    Singularity.Runtime.call()
    """

    assert [] == forbidden_web_references(source)
  end

  test "valid Elixir source ignores unrelated dynamic alias paths" do
    assert [] == forbidden_web_references("__MODULE__.Core.call()")
  end

  test "parse-failing source conservatively rejects literal forbidden modules" do
    source = """
    <div>{Singularity.Core.call()}</div>
    <div>{Singularity.Runtime.call()}</div>
    """

    assert ["Singularity.Core"] == forbidden_web_references(source)
  end

  test "valid Elixir source scans static HEEx sigils for forbidden modules" do
    source = "~H\"<div>{Singularity.Core.call()}</div>\""

    assert ["Singularity.Core"] == forbidden_web_references(source)
  end

  test "valid Elixir source allows Runtime in static HEEx sigils" do
    source = "~H\"<div>{Singularity.Runtime.call()}</div>\""

    assert [] == forbidden_web_references(source)
  end

  test "all child projects use the centralized Elixir requirement" do
    expected = Singularity.Build.elixir_requirement()

    for app <- child_apps() do
      assert expected == project_config(app)[:elixir]
    end
  end

  test "storage declares and locks the supported Oban 2.24 line" do
    storage_dependencies =
      :singularity_storage
      |> project_config()
      |> Keyword.fetch!(:deps)

    assert {:oban, "~> 2.24"} in storage_dependencies

    assert {:hex, :oban, locked_version, _, _, _, "hexpm", _} =
             @repo_root
             |> Path.join("mix.lock")
             |> Mix.Dep.Lock.read()
             |> Map.fetch!(:oban)

    assert Version.match?(locked_version, "~> 2.24")
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
    |> Enum.flat_map(fn
      {dependency, options} when is_list(options) ->
        if Keyword.get(options, :in_umbrella, false), do: [dependency], else: []

      {dependency, _requirement, options} when is_list(options) ->
        if Keyword.get(options, :in_umbrella, false), do: [dependency], else: []

      _external_dependency ->
        []
    end)
    |> Enum.sort()
  end

  defp forbidden_web_references(source) do
    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} -> forbidden_ast_references(ast)
      {:error, _reason} -> forbidden_text_references(source)
    end
  end

  defp forbidden_ast_references(ast) do
    renamed_roots = renamed_singularity_roots(ast)

    referenced_modules =
      ast
      |> alias_paths()
      |> Enum.map(&resolve_renamed_root(&1, renamed_roots))
      |> Enum.flat_map(fn path ->
        if Enum.all?(path, &is_atom/1) do
          [Enum.map_join(path, ".", fn part -> Atom.to_string(part) end)]
        else
          []
        end
      end)

    static_heex_modules =
      ast
      |> static_heex_payloads()
      |> Enum.flat_map(&forbidden_text_references/1)
      |> MapSet.new()

    Enum.filter(@forbidden_web_modules, fn forbidden_module ->
      MapSet.member?(static_heex_modules, forbidden_module) or
        Enum.any?(referenced_modules, fn referenced_module ->
          referenced_module == forbidden_module or
            String.starts_with?(referenced_module, forbidden_module <> ".")
        end)
    end)
  end

  defp renamed_singularity_roots(ast) do
    {_ast, roots} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:alias, _meta, [{:__aliases__, _alias_meta, [:Singularity]}, options]} = node, roots
        when is_list(options) ->
          case Keyword.get(options, :as) do
            {:__aliases__, _as_meta, [root]} -> {node, MapSet.put(roots, root)}
            _other -> {node, roots}
          end

        node, roots ->
          {node, roots}
      end)

    roots
  end

  defp alias_paths(ast) do
    {_ast, paths} =
      Macro.prewalk(ast, [], fn
        {{:., _dot_meta, [{:__aliases__, _prefix_meta, prefix}, :{}]}, _call_meta, members} =
            node,
        paths ->
          grouped_paths =
            Enum.flat_map(members, fn
              {:__aliases__, _member_meta, suffix} -> [prefix ++ suffix]
              _other -> []
            end)

          {node, grouped_paths ++ paths}

        {:__aliases__, _meta, parts} = node, paths ->
          {node, [parts | paths]}

        node, paths ->
          {node, paths}
      end)

    paths
  end

  defp static_heex_payloads(ast) do
    {_ast, payloads} =
      Macro.prewalk(ast, [], fn
        {:sigil_H, _meta, [{:<<>>, _binary_meta, [payload]}, _modifiers]} = node, payloads
        when is_binary(payload) ->
          {node, [payload | payloads]}

        node, payloads ->
          {node, payloads}
      end)

    payloads
  end

  defp resolve_renamed_root([root | rest] = path, renamed_roots) do
    if MapSet.member?(renamed_roots, root), do: [:Singularity | rest], else: path
  end

  defp forbidden_text_references(source) do
    Enum.filter(@forbidden_web_modules, fn forbidden_module ->
      pattern =
        forbidden_module
        |> String.split(".")
        |> Enum.map_join("\\s*\\.\\s*", &Regex.escape/1)

      Regex.match?(Regex.compile!("\\b#{pattern}(?:\\s*\\.|\\b)"), source)
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
