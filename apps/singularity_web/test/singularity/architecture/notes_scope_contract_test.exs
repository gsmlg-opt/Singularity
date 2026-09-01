defmodule Singularity.Web.Architecture.NotesScopeContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @vault_adr Path.join(
               @repo_root,
               "docs/adr/0003-vault-frozen-for-knowledge-base-development.md"
             )
  @vault_adr_name Path.basename(@vault_adr)
  @master_plan Path.join(
                 @repo_root,
                 "docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md"
               )

  @scope_lock "Vault is frozen compatibility substrate for `0.2.0`, not an active product module or release deliverable."
  @qdrant_lock "Qdrant is out of scope for `0.2.0`."
  @owner_scope_invariant "Every user-owned object belongs to an authenticated owner scope, and every projection points to an immutable source version."
  @production_repair_gate "Any production-code or production-behavior repair requires an approved design amendment and explicit user approval."
  @release_design_path "docs/superpowers/specs/2026-08-31-singularity-v0.2-release-design.md"
  @blocker_repair_design_path "docs/superpowers/specs/2026-09-01-singularity-v0.2-phase-0-blocker-repair-design.md"
  @release_plan_path "docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md"
  @classification_repair_scope "The only classification repair makes `resource_versions_resource_classification_fkey` deferrable and initially deferred through a new forward migration."
  @wake_repair_scope "The only wake repair moves application-owned wake generation counters from Oban metadata to `jobs.job_submissions` and raises the supported Oban floor to 2.24."
  @no_other_repair_scope "No other Phase 0 production-code, production-behavior, or schema change is authorized."
  @release_prohibition_scope "Version bumps, tags, releases, pushes, deployments, and Phase 1 work remain prohibited."
  @blocker_repair_design_heading "# Singularity v0.2.0 Phase 0 Blocker Repair Design"
  @blocker_repair_heading "### Approved Phase 0 blocker repairs"
  @stop_conditions_heading "## Stop conditions"
  @governing_document_bullets [
    "- `#{@release_design_path}`",
    "- `#{@blocker_repair_design_path}`",
    "- `#{@release_plan_path}`"
  ]
  @approved_blocker_repair_scope Enum.join(
                                   [
                                     "- `#{@blocker_repair_design_path}`",
                                     @classification_repair_scope,
                                     @wake_repair_scope,
                                     @no_other_repair_scope,
                                     @release_prohibition_scope
                                   ],
                                   " "
                                 )
  @approved_phase_protocol_scope Enum.join(
                                   [
                                     "- Characterize established behavior before changing it.",
                                     "- Add a failing focused contract before changing enforced behavior.",
                                     "- Never edit a released migration.",
                                     "- Never weaken, skip, delete, or reclassify a required assertion.",
                                     "- Run focused checks during a phase and the complete README verification gate before accepting the phase.",
                                     "- Preserve the seven-application dependency graph and require zero xref cycles.",
                                     "- Record commits, changed files, migrations, tests, exact commands and results, remaining risks, and confirmation that no Vault feature work occurred.",
                                     @blocker_repair_heading,
                                     @approved_blocker_repair_scope
                                   ],
                                   " "
                                 )

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
    agents = Path.join(@repo_root, "AGENTS.md") |> read_required!() |> assert_active_prose!()
    vault_adr_source = @vault_adr |> read_required!() |> assert_active_prose!()
    master_plan_source = read_required!(@master_plan)

    phase0_deliverables =
      master_plan_source
      |> markdown_section!(
        "## Phase 0 — Scope lock and green baseline",
        "## Phase 1 — Canonical Document and knowledge-link model"
      )
      |> markdown_section!("### Deliverables", "### Acceptance")
      |> assert_active_prose!()

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

    assert normalize_markdown(phase0_deliverables) =~ @production_repair_gate,
           "canonical release plan does not reserve production repairs for explicit approval"
  end

  test "Phase 0 governance names only the approved blocker repair exceptions" do
    agents =
      @repo_root
      |> Path.join("AGENTS.md")
      |> read_required!()
      |> assert_active_prose!()

    design_path = Path.join(@repo_root, @blocker_repair_design_path)
    design = read_required!(design_path)

    assert_phase0_governance_contract!(agents, design)
  end

  test "Phase 0 governance rejects an extra repair authorization" do
    agents = @repo_root |> Path.join("AGENTS.md") |> read_required!()
    design = @repo_root |> Path.join(@blocker_repair_design_path) |> read_required!()

    extra_authorization =
      String.replace(
        agents,
        "\n## Stop conditions",
        "\nAn additional production repair is authorized.\n\n## Stop conditions",
        global: false
      )

    assert_raise ExUnit.AssertionError, fn ->
      assert_phase0_governance_contract!(extra_authorization, design)
    end
  end

  test "Phase 0 governance requires the amendment in the governing-document list" do
    agents = @repo_root |> Path.join("AGENTS.md") |> read_required!()
    design = @repo_root |> Path.join(@blocker_repair_design_path) |> read_required!()
    amendment_bullet = "- `#{@blocker_repair_design_path}`\n"
    missing_governing_bullet = String.replace(agents, amendment_bullet, "", global: false)

    assert missing_governing_bullet =~ @blocker_repair_design_path

    assert_raise ExUnit.AssertionError, fn ->
      assert_phase0_governance_contract!(missing_governing_bullet, design)
    end
  end

  test "Phase 0 governance rejects an extra non-backtick governing-document bullet" do
    agents = @repo_root |> Path.join("AGENTS.md") |> read_required!()
    design = @repo_root |> Path.join(@blocker_repair_design_path) |> read_required!()

    extra_governing_bullet =
      String.replace(
        agents,
        "- `#{@release_plan_path}`\n",
        "- `#{@release_plan_path}`\n- docs/extra-governance.md\n",
        global: false
      )

    assert_raise ExUnit.AssertionError, fn ->
      assert_phase0_governance_contract!(extra_governing_bullet, design)
    end
  end

  test "Phase 0 governance rejects an authorization before the repair subsection" do
    agents = @repo_root |> Path.join("AGENTS.md") |> read_required!()
    design = @repo_root |> Path.join(@blocker_repair_design_path) |> read_required!()

    extra_authorization =
      String.replace(
        agents,
        "\n#{@blocker_repair_heading}",
        "\nAn earlier production repair is authorized.\n\n#{@blocker_repair_heading}",
        global: false
      )

    assert_raise ExUnit.AssertionError, fn ->
      assert_phase0_governance_contract!(extra_authorization, design)
    end
  end

  test "Phase 0 blocker design requires an active approved status in its header" do
    agents = @repo_root |> Path.join("AGENTS.md") |> read_required!()
    design = @repo_root |> Path.join(@blocker_repair_design_path) |> read_required!()

    approved_only_in_comment =
      String.replace(
        design,
        "**Status:** Approved",
        "<!-- **Status:** Approved -->",
        global: false
      )

    approved_only_in_fence =
      String.replace(
        design,
        "**Status:** Approved",
        "```markdown\n**Status:** Approved\n```",
        global: false
      )

    approved_only_outside_header =
      design
      |> String.replace("**Status:** Approved\n\n", "", global: false)
      |> String.replace(
        "## 1. Purpose",
        "## 1. Purpose\n\n**Status:** Approved",
        global: false
      )

    for invalid_design <- [
          approved_only_in_comment,
          approved_only_in_fence,
          approved_only_outside_header
        ] do
      assert_raise ExUnit.AssertionError, fn ->
        assert_phase0_governance_contract!(agents, invalid_design)
      end
    end
  end

  test "Phase 0 blocker design rejects an indented approved status" do
    agents = @repo_root |> Path.join("AGENTS.md") |> read_required!()
    design = @repo_root |> Path.join(@blocker_repair_design_path) |> read_required!()

    approved_only_in_indented_code =
      String.replace(
        design,
        "**Status:** Approved",
        "    **Status:** Approved",
        global: false
      )

    assert_raise ExUnit.AssertionError, fn ->
      assert_phase0_governance_contract!(agents, approved_only_in_indented_code)
    end
  end

  test "active README and guide state the v0.2 scope lock" do
    readme_source = @repo_root |> Path.join("README.md") |> read_required!()
    guide_source = @repo_root |> Path.join("docs/guide.md") |> read_required!()

    readme_scope =
      active_section!(readme_source, "## Active `0.2.0` scope", "## Development")

    guide_header =
      case String.split(guide_source, "\n---\n", parts: 2) do
        [header, _rest] -> assert_active_prose!(header)
        [_source] -> flunk("guide active header separator is missing")
      end

    roadmap =
      active_section!(
        guide_source,
        "# 21. Active implementation roadmap",
        "# 22. Cross-cutting invariants"
      )

    invariants =
      active_section!(
        guide_source,
        "# 22. Cross-cutting invariants",
        "# 23. Architecture decision records"
      )

    guide_active = Enum.join([guide_header, roadmap, invariants], "\n")

    for {name, source} <- [
          {"README.md", normalize_markdown(readme_scope)},
          {"docs/guide.md", normalize_markdown(guide_active)}
        ] do
      for marker <- [@scope_lock, @qdrant_lock, @owner_scope_invariant] do
        assert source =~ marker, "#{name} is missing required Phase 0 marker #{inspect(marker)}"
      end
    end

    assert readme_scope =~
             "[ADR 0003](docs/adr/0003-vault-frozen-for-knowledge-base-development.md)",
           "README does not contain the rendered ADR 0003 link"

    assert guide_header =~
             "[ADR 0003](adr/0003-vault-frozen-for-knowledge-base-development.md)",
           "guide does not contain the rendered ADR 0003 link"

    assert File.regular?(@vault_adr), "ADR 0003 link target does not resolve"

    assert normalize_markdown(readme_scope) =~
             "Phase 1 must not begin until Phase 0 is accepted and Phase 1 has its own approved design and detailed implementation plan."

    refute normalize_markdown(readme_scope) =~ "Qdrant is required"

    assert normalize_markdown(roadmap) =~ @scope_lock
    assert roadmap =~ "Conflicting roadmap guidance is superseded by ADR 0003."

    assert normalize_markdown(invariants) =~ @owner_scope_invariant
    refute invariants =~ "Every user-owned object belongs to a vault."
  end

  test "active scope sections reject inactive Markdown constructs" do
    fixtures = [
      {"headings inside a top-level fence",
       """
       ```markdown
       # 21. Active implementation roadmap
       #{@scope_lock}
       # 22. Cross-cutting invariants
       ```
       """},
      {"headings inside an HTML comment",
       """
       <!--
       # 21. Active implementation roadmap
       #{@scope_lock}
       # 22. Cross-cutting invariants
       -->
       """},
      {"blockquote fenced code",
       """
       # 21. Active implementation roadmap
       > ```markdown
       > #{@scope_lock}
       > ```
       # 22. Cross-cutting invariants
       """},
      {"list-nested fenced code",
       """
       # 21. Active implementation roadmap
       - ```markdown
         #{@scope_lock}
         ```
       # 22. Cross-cutting invariants
       """},
      {"four-space indented code",
       """
       # 21. Active implementation roadmap
           #{@scope_lock}
       # 22. Cross-cutting invariants
       """},
      {"mixed tab indented code",
       "# 21. Active implementation roadmap\n \t#{@scope_lock}\n# 22. Cross-cutting invariants\n"},
      {"inline HTML comment with rendered stale guidance",
       """
       # 21. Active implementation roadmap
       <!-- compatibility note --> Every user-owned object belongs to a vault.
       # 22. Cross-cutting invariants
       """}
    ]

    for {_name, markdown} <- fixtures do
      assert_raise ExUnit.AssertionError,
                   ~r/(?:inactive Markdown constructs|required Markdown heading is missing|unclosed Markdown fence)/,
                   fn ->
                     active_section!(
                       markdown,
                       "# 21. Active implementation roadmap",
                       "# 22. Cross-cutting invariants"
                     )
                   end
    end
  end

  test "documentation and tests are intentionally outside the active-scope scan" do
    refute active_path?("docs/superpowers/plans/2026-08-18-milestone-2-private-markdown-notes.md")
    refute active_path?("apps/singularity_web/test/example_test.exs")
    refute active_path?("README.md")
  end

  defp assert_phase0_governance_contract!(agents, design) do
    assert_governing_documents!(agents)
    assert_phase_protocol!(agents)
    assert_approved_design_status!(design)
  end

  defp assert_governing_documents!(agents) do
    governing_document_bullets =
      agents
      |> active_section!("## Active release", "## Vault freeze")
      |> String.split(~r/\r?\n/)
      |> Enum.filter(&markdown_bullet_line?/1)
      |> Enum.map(&String.trim_trailing/1)

    assert governing_document_bullets == @governing_document_bullets,
           "active release governing-document bullets must match the approved ordered list"
  end

  defp assert_phase_protocol!(agents) do
    phase_protocol =
      agents
      |> active_section!("## Phase and verification protocol", @stop_conditions_heading)
      |> normalize_markdown()

    assert phase_protocol == @approved_phase_protocol_scope,
           "Phase 0 protocol must match the exact verification and blocker repair contract"
  end

  defp assert_approved_design_status!(design) do
    header =
      design
      |> markdown_section!(@blocker_repair_design_heading, "## 1. Purpose")
      |> assert_active_prose!()

    status_lines =
      header
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&status_line?/1)

    assert status_lines == ["**Status:** Approved"],
           "blocker repair design header must contain only the active status **Status:** Approved"
  end

  defp markdown_bullet_line?(line) do
    Regex.match?(~r/^ {0,3}(?:> ?)* {0,3}(?:[-+*]|\d+[.)])\s+\S/, line)
  end

  defp status_line?(line) do
    Regex.match?(~r/^(?:[-#]+\s*)?\*{0,2}Status(?:\*{0,2})?:\*{0,2}(?:\s|$)/i, line)
  end

  defp read_required!(path) do
    assert File.regular?(path), "required Phase 0 document is missing: #{path}"
    File.read!(path)
  end

  defp markdown_section!(source, start_heading, end_heading) do
    lines = String.split(source, ~r/\r?\n/, trim: false)
    active_lines = active_top_level_lines!(lines)
    start_index = heading_index!(active_lines, start_heading, 0)
    end_index = heading_index!(active_lines, end_heading, start_index + 1)

    lines
    |> Enum.slice(start_index + 1, max(end_index - start_index - 1, 0))
    |> Enum.join("\n")
  end

  defp heading_index!(active_lines, heading, offset) do
    indexes =
      active_lines
      |> Enum.filter(fn {line, index} ->
        index >= offset and String.trim_trailing(line) == heading
      end)
      |> Enum.map(&elem(&1, 1))

    case indexes do
      [index] -> index
      [] -> flunk("required Markdown heading is missing: #{heading}")
      matches -> flunk("required Markdown heading appears #{length(matches)} times: #{heading}")
    end
  end

  defp active_top_level_lines!(lines) do
    scan_top_level_lines(lines, 0, {:outside, false}, [])
  end

  defp scan_top_level_lines([], _index, {:outside, false}, active),
    do: Enum.reverse(active)

  defp scan_top_level_lines([], _index, {:outside, true}, _active),
    do: flunk("unclosed Markdown HTML comment")

  defp scan_top_level_lines(
         [],
         _index,
         {:inside_fence, _character, _length, opening_index},
         _active
       ),
       do: flunk("unclosed Markdown fence starting on line #{opening_index + 1}")

  defp scan_top_level_lines([line | lines], index, {:outside, inside_comment?}, active) do
    started_inside_comment? = inside_comment?

    {inside_comment?, comment_line?} =
      advance_top_level_comment_state(line, inside_comment?)

    cond do
      started_inside_comment? or comment_line? or inside_comment? ->
        scan_top_level_lines(lines, index + 1, {:outside, inside_comment?}, active)

      true ->
        case top_level_opening_fence(line) do
          {:ok, character, length} ->
            scan_top_level_lines(
              lines,
              index + 1,
              {:inside_fence, character, length, index},
              active
            )

          :none ->
            scan_top_level_lines(lines, index + 1, {:outside, false}, [
              {line, index} | active
            ])
        end
    end
  end

  defp scan_top_level_lines(
         [line | lines],
         index,
         {:inside_fence, character, length, opening_index},
         active
       ) do
    if top_level_closing_fence?(line, character, length) do
      scan_top_level_lines(lines, index + 1, {:outside, false}, active)
    else
      scan_top_level_lines(
        lines,
        index + 1,
        {:inside_fence, character, length, opening_index},
        active
      )
    end
  end

  defp advance_top_level_comment_state(line, inside_comment?) do
    advance_top_level_comment_state(line, inside_comment?, inside_comment?)
  end

  defp advance_top_level_comment_state(line, false, comment_line?) do
    case :binary.match(line, "<!--") do
      {start, 4} ->
        remainder = binary_part(line, start + 4, byte_size(line) - start - 4)
        advance_top_level_comment_state(remainder, true, true)

      :nomatch ->
        {false, comment_line?}
    end
  end

  defp advance_top_level_comment_state(line, true, _comment_line?) do
    case :binary.match(line, "-->") do
      {finish, 3} ->
        remainder = binary_part(line, finish + 3, byte_size(line) - finish - 3)
        advance_top_level_comment_state(remainder, false, true)

      :nomatch ->
        {true, true}
    end
  end

  defp top_level_opening_fence(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,}).*$/, line, capture: :all_but_first) do
      [fence] -> {:ok, String.first(fence), String.length(fence)}
      nil -> :none
    end
  end

  defp top_level_closing_fence?(line, opening_character, opening_length) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})[ \t]*$/, line, capture: :all_but_first) do
      [fence] ->
        String.first(fence) == opening_character and String.length(fence) >= opening_length

      nil ->
        false
    end
  end

  defp normalize_markdown(source) do
    source
    |> String.replace(~r/(?:^|\n)\s*>\s?/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp active_section!(source, start_heading, end_heading) do
    source
    |> markdown_section!(start_heading, end_heading)
    |> assert_active_prose!()
  end

  defp assert_active_prose!(source) do
    problems =
      [
        if(Regex.match?(~r/(?:`{3,}|~{3,})/, source), do: "fenced code"),
        if(String.contains?(source, "<!--") or String.contains?(source, "-->"),
          do: "HTML comments"
        ),
        if(Regex.match?(~r/^(?: {4,}| {0,3}\t)[ \t]*\S/m, source), do: "indented code")
      ]
      |> Enum.reject(&is_nil/1)

    if problems != [] do
      flunk(
        "active documentation contains inactive Markdown constructs: #{Enum.join(problems, ", ")}"
      )
    end

    source
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
