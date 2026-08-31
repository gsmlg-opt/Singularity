defmodule Singularity.Web.Architecture.NotesScopeContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @vault_adr Path.join(
               @repo_root,
               "docs/adr/0003-vault-frozen-for-knowledge-base-development.md"
             )
  @vault_adr_name Path.basename(@vault_adr)

  @scope_lock "Vault is frozen compatibility substrate for `0.2.0`, not an active product module or release deliverable."
  @qdrant_lock "Qdrant is out of scope for `0.2.0`."
  @owner_scope_invariant "Every user-owned object belongs to an authenticated owner scope, and every projection points to an immutable source version."

  @required_root_paths ~w[
    mix.exs mix.lock devenv.nix devenv.yaml devenv.lock
    config/config.exs config/dev.exs config/runtime.exs config/test.exs
    .github/workflows/ci.yml
  ]

  test "active dependencies, configuration, production code and deployment manifests exclude Qdrant" do
    root = @repo_root
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

  test "Phase 0 governance documents record the approved scope lock" do
    agents = read_required!(Path.join(@repo_root, "AGENTS.md"))
    vault_adr_source = read_required!(@vault_adr)

    for {name, source} <- [
          {"AGENTS.md", normalize_markdown(agents)},
          {@vault_adr_name, normalize_markdown(vault_adr_source)}
        ] do
      assert source =~ @scope_lock, "#{name} is missing the approved Vault scope lock"

      assert source =~ @owner_scope_invariant,
             "#{name} is missing the authenticated owner-scope invariant"

      assert source =~ "requires a separately approved migration project",
             "#{name} does not reserve Vault migration for a separately approved project"
    end

    assert normalize_markdown(agents) =~ @qdrant_lock
    assert vault_adr_source =~ "Status: Accepted"
  end

  test "active README and guide state the v0.2 scope lock" do
    readme_source = read_required!(Path.join(@repo_root, "README.md"))
    guide_source = read_required!(Path.join(@repo_root, "docs/guide.md"))

    for {name, source} <- [
          {"README.md", normalize_markdown(readme_source)},
          {"docs/guide.md", normalize_markdown(guide_source)}
        ] do
      for marker <- [@scope_lock, @qdrant_lock, @owner_scope_invariant] do
        assert source =~ marker, "#{name} is missing required Phase 0 marker #{inspect(marker)}"
      end

      assert source =~ @vault_adr_name,
             "#{name} does not link to the accepted Vault scope ADR"
    end

    assert normalize_markdown(readme_source) =~
             "Phase 1 must not begin until Phase 0 is accepted and Phase 1 has its own approved design and detailed implementation plan."

    refute normalize_markdown(readme_source) =~ "Qdrant is required"

    roadmap =
      guide_source
      |> markdown_section!(
        "# 21. Active implementation roadmap",
        "# 22. Cross-cutting invariants"
      )
      |> normalize_markdown()

    assert roadmap =~ @scope_lock
    assert roadmap =~ "Conflicting roadmap guidance is superseded by ADR 0003."

    invariants =
      guide_source
      |> markdown_section!(
        "# 22. Cross-cutting invariants",
        "# 23. Architecture decision records"
      )
      |> normalize_markdown()

    assert invariants =~ @owner_scope_invariant
    refute invariants =~ "Every user-owned object belongs to a vault."
  end

  test "documentation and tests are intentionally outside the active-scope scan" do
    refute active_path?("docs/superpowers/plans/2026-08-18-milestone-2-private-markdown-notes.md")
    refute active_path?("apps/singularity_web/test/example_test.exs")
    refute active_path?("README.md")
  end

  defp read_required!(path) do
    assert File.regular?(path), "required Phase 0 document is missing: #{path}"
    File.read!(path)
  end

  defp markdown_section!(source, start_heading, end_heading) do
    after_start =
      case String.split(source, start_heading, parts: 2) do
        [_before, after_start] -> after_start
        [_source] -> flunk("required Markdown heading is missing: #{start_heading}")
      end

    case String.split(after_start, end_heading, parts: 2) do
      [section, _after] -> section
      [_after_start] -> flunk("required Markdown heading is missing: #{end_heading}")
    end
  end

  defp normalize_markdown(source) do
    source
    |> String.replace(~r/(?:^|\n)\s*>\s?/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
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
