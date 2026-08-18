defmodule Singularity.Web.Architecture.NotesScopeContractTest do
  use ExUnit.Case, async: true

  @required_root_paths ~w[
    mix.exs mix.lock devenv.nix devenv.yaml devenv.lock
    config/config.exs config/dev.exs config/runtime.exs config/test.exs
    .github/workflows/ci.yml
  ]

  test "active dependencies, configuration, production code and deployment manifests exclude Qdrant" do
    root = Path.expand("../../../../..", __DIR__)
    files = tracked_files(root)
    active = Enum.filter(files, &active_path?/1)

    for required <- @required_root_paths do
      assert required in active, "Qdrant inventory omitted required active path #{required}"
    end

    app_roots =
      files
      |> Enum.filter(&Regex.match?(~r|^apps/[^/]+/mix\.exs$|, &1))
      |> Enum.map(&Path.dirname/1)

    assert length(app_roots) >= 7

    for app <- app_roots do
      assert "#{app}/mix.exs" in active

      assert Enum.any?(active, &String.starts_with?(&1, "#{app}/lib/")),
             "Qdrant inventory omitted production code for #{app}"
    end

    assert Enum.any?(active, &String.starts_with?(&1, "apps/singularity_web/assets/")),
           "Qdrant inventory omitted active browser source"

    for path <- active do
      refute active_qdrant?(path, File.read!(Path.join(root, path))),
             "active Qdrant scope found in #{path}"
    end
  end

  test "documentation and tests are intentionally outside the active-scope scan" do
    refute active_path?("docs/superpowers/plans/2026-08-18-milestone-2-private-markdown-notes.md")
    refute active_path?("apps/singularity_web/test/example_test.exs")
    refute active_path?("README.md")
  end

  defp tracked_files(root) do
    {output, 0} =
      System.cmd("git", ["ls-files", "--cached", "--others", "--exclude-standard"], cd: root)

    output
    |> String.split("\n", trim: true)
    |> Enum.sort()
  end

  defp active_path?("mix.exs"), do: true
  defp active_path?("mix.lock"), do: true

  defp active_path?(path) do
    cond do
      deployment_manifest?(path) ->
        true

      String.starts_with?(path, "apps/") ->
        not String.contains?(path, "/test/") and
          (String.ends_with?(path, "/mix.exs") or String.contains?(path, "/lib/") or
             String.contains?(path, "/priv/") or String.contains?(path, "/assets/"))

      String.starts_with?(path, "config/") ->
        true

      String.starts_with?(path, ".github/workflows/") ->
        true

      path in ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"] ->
        true

      path in ["devenv.nix", "devenv.yaml", "devenv.lock", "flake.nix", "flake.lock"] ->
        true

      true ->
        false
    end
  end

  defp deployment_manifest?(path) do
    basename = Path.basename(path)

    String.starts_with?(basename, "Dockerfile") or
      basename in ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"] or
      String.starts_with?(path, "deploy/") or String.starts_with?(path, "deployment/")
  end

  defp active_qdrant?(path, source) do
    if Path.extname(path) in [".ex", ".exs"] do
      case Code.string_to_quoted(source) do
        {:ok, ast} -> ast |> strip_docs() |> ast_mentions_qdrant?()
        {:error, _parse_error} -> true
      end
    else
      source =~ ~r/qdrant/i
    end
  end

  defp strip_docs(ast) do
    Macro.prewalk(ast, fn
      {:@, _metadata, [{attribute, _attribute_metadata, _arguments}]}
      when attribute in [:doc, :moduledoc, :typedoc] ->
        nil

      node ->
        node
    end)
  end

  defp ast_mentions_qdrant?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        {node, found? or qdrant_term?(node)}
      end)

    found?
  end

  defp qdrant_term?(value) when is_atom(value) or is_binary(value),
    do: Regex.match?(~r/qdrant/i, to_string(value))

  defp qdrant_term?(_value), do: false
end
