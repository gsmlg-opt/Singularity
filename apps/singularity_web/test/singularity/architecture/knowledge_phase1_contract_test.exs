defmodule Singularity.Web.Architecture.KnowledgePhase1ContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @design "2026-10-09-singularity-v0.2-phase-3-unified-lexical-search-design.md"
  @plan "2026-10-09-singularity-v0.2-phase-3-unified-lexical-search.md"
  @phase4_design "2026-10-11-singularity-v0.2-phase-4-knowledge-links-design.md"
  @phase4_plan "2026-10-11-singularity-v0.2-phase-4-knowledge-links.md"
  @phase5_design "2026-10-11-singularity-v0.2-phase-5-export-backup-design.md"
  @phase5_plan "2026-10-11-singularity-v0.2-phase-5-export-backup.md"
  @phase4 "42c01a5c99b1df3d1e4284d277c6ea48046875cb"
  @phase4_handoff "5f7e6363be534dbfb4dfa1475538fddcbd29cf32"
  @phase3 "35c1f8360dd22b129832a1618b3723032a1983bd"
  @phase3_handoff "617f0b986a3ecffba14c952988e39e3afe022cea"
  @phase2 "c34935a112a2b4b807ed741e8e67e44d4e63eafe"
  @handoff "ff703bd710074738b0391bb2f29d585dc6166d5c"
  @baseline "6c3e8d5afb2cc9dbf264d276796070e16aa49e55"
  @api "apps/singularity_runtime/lib/singularity/runtime/api.ex"
  @application "apps/singularity_runtime/lib/singularity/runtime/application.ex"
  @dispatcher "apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex"
  @runtime_baselines %{
    @api => "eded245a1bd95410b323192de836c9b1de8cec14de4b26cb8e41263d66ebf3c4",
    "apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex" =>
      "2f92227526e692931e4d8e501635eb94f79e59f90f54bab7f5f9891581f507c8",
    @application => "4bed50e5ab4f7ed351b0e7497a943f940466bce53101928ce4e906ae910abe35",
    "config/config.exs" => "ebbf6e0d51ce707a67d7e29115ad0e2af7fbc372ff68072a67279ec1fa5304f8",
    "config/runtime.exs" => "1847759a3e3461681f5e832cb4b9e35cfb1ae0217665afd7c60b375128fa55ca"
  }
  @document_operations [
    :import_document,
    :get_document,
    :list_documents,
    :document_status,
    :document_fragments,
    :download_document_original,
    :retry_document,
    :delete_document,
    :restore_document
  ]
  @document_terms %{
    @api =>
      @document_operations ++
        [
          :DocumentImport,
          :DocumentMutate,
          :DocumentRead,
          :DocumentVersion,
          :Documents,
          :document,
          :document_call,
          :document_in_scope?,
          :document_mutation_call
        ],
    @application => [
      :Documents,
      :DocumentWorkerRepository,
      :document_worker,
      :document_extractors
    ],
    @dispatcher => [:Documents, :document_source_lease, "document_extract"],
    "config/config.exs" => [:document_extract]
  }
  @phase3_document_terms %{
    @application => [:document_projection],
    @dispatcher => [:DocumentProjection, "document_projection"],
    "config/config.exs" => [:document_projection]
  }

  test "active guidance retains Phase 5 sequencing under continuous development authority" do
    for {path, start, finish} <- [
          {"AGENTS.md", "## Active release", "## Vault freeze"},
          {"README.md", "## Active `0.2.0` scope", "## Development"},
          {"docs/guide.md", "# 21. Active implementation roadmap",
           "# 22. Cross-cutting invariants"}
        ] do
      section = active_section!(path, start, finish)

      assert section =~ ~r/active implementation slice is Phase 5/,
             "#{path} does not identify Phase 5 as the active slice"

      for marker <- [
            "qualified local acceptance",
            @phase3,
            @phase4,
            @phase4_handoff,
            "superpowers/specs/#{@phase4_design}",
            "superpowers/plans/#{@phase4_plan}",
            "superpowers/specs/#{@phase5_design}",
            "superpowers/plans/#{@phase5_plan}",
            "Later phases require designs, detailed plans, required verification, and independent review, without renewed routine human approval.",
            "Advance automatically only after the preceding phase's required gates pass.",
            "New canonical writes remain unavailable to production runtime roles.",
            "New backups use logical V3 after combined writer and restore qualification. Explicit V2 retains its fail-closed unsupported-canonical guard.",
            "Public import, extraction workers, search, Note Save integration, backup V3, and browser behavior remain in their designated later phases.",
            "E2E",
            "NOT RUN",
            "final browser/release acceptance",
            "Version bumps, tags, releases, pushes, and deployments remain separately gated."
          ] do
        assert section =~ marker, "#{path} is missing active Phase 5 governance: #{marker}"
      end

      if path == "AGENTS.md", do: assert(section =~ @phase3_handoff)
    end
  end

  test "Phase 5 authority keeps production writes closed and selects qualified default V3" do
    plan_authority =
      phase5_plan_authority!(read_source("docs/superpowers/plans/#{@phase5_plan}"))

    design_authority =
      active_section!(
        "docs/superpowers/specs/#{@phase5_design}",
        "## 1. Baseline, scope, and fixed boundaries",
        "## 2. Evidence and selected approach"
      )

    for section <- [plan_authority, design_authority] do
      for marker <- [
            @phase4,
            @phase4_handoff,
            "New canonical writes remain unavailable to production runtime roles.",
            "E2E",
            "manual-only",
            "NOT RUN",
            "final browser/release acceptance"
          ] do
        assert section =~ marker
      end
    end

    assert plan_authority =~
             "New backups use logical V3 after combined writer and restore qualification. Explicit V2 retains its fail-closed unsupported-canonical guard."

    assert plan_authority =~
             "It does not permit Vault feature work, custody/key/capability/policy/crypto semantic changes, merge, push, version bump, tag, release, deployment, production activation or production backfill."

    assert design_authority =~
             "Vault, cryptography, key lifecycle, custody, capabilities, policy semantics, and their tests/UX remain frozen."

    assert design_authority =~
             "browser features, production activation/backfill, merge, push, version bump, tag, release, or deployment."

    wire_contract =
      active_section!(
        "docs/superpowers/specs/#{@phase5_design}",
        "## 6. Logical V3 wire schema and inventory",
        "## 7. Semantic preflight and historical admission"
      )

    for marker <- [
          "During implementation, introduce explicit V3 support behind explicit version selection while the default remains V2 and its unsupported-content guard continues to fail closed.",
          "Switch new-backup default to V3 only after its writer, full restore/validation/integrity boundary, compatibility fixtures and focused round trips qualify together.",
          "Documentation/selector preparation must not introduce a production guard exception."
        ] do
      assert wire_contract =~ marker
    end
  end

  test "Phase 4 retains its qualified Phase 3 base and explicit activation exclusions" do
    for {path, start, finish} <- [
          {"docs/superpowers/specs/#{@phase4_design}", "## Status and authority",
           "## Goal and boundaries"},
          {"docs/superpowers/plans/#{@phase4_plan}",
           "## Authority, base and execution discipline",
           "Run commands from this worktree with its own `_build`; reuse only locked"}
        ] do
      section = active_section!(path, start, finish)
      assert section =~ @phase3
      assert section =~ @phase3_handoff
      assert section =~ "E2E"
      assert section =~ "NOT RUN"
      assert section =~ "final browser/release acceptance"
    end

    boundaries =
      active_section!(
        "docs/superpowers/specs/#{@phase4_design}",
        "## Goal and boundaries",
        "## Architecture choice and inspected constraints"
      )

    for marker <- [
          "Production canonical writes remain disabled",
          "V1/V2 fail-closed unsupported-canonical-data guard",
          "The derived source seal alone does not make",
          "Web calls only `Singularity.Runtime.Api`; Phase 4 adds no browser workspace.",
          "Domain code stays free of Ecto, filesystem, Phoenix and React."
        ] do
      assert boundaries =~ marker
    end
  end

  test "Phase 3 authority retains its qualified Phase 2 base and release exclusions" do
    for {path, start, finish} <- [
          {"docs/superpowers/specs/#{@design}", "## Status and authority",
           "## Goal and boundaries"},
          {"docs/superpowers/plans/#{@plan}", "## Authority, baseline, and execution discipline",
           "All commands below run from the Phase 3 worktree root. Its local `_build`"}
        ] do
      section = active_section!(path, start, finish)
      assert section =~ @phase2
      assert section =~ @handoff
    end

    boundaries =
      active_section!(
        "docs/superpowers/specs/#{@design}",
        "## Goal and boundaries",
        "## Architecture choice"
      )

    for marker <- [
          "Excluded: Phase 4 attachment/citation/source-set writes, tag mutations",
          "V3 backup, new browser pages",
          "semantic search, Qdrant, embeddings, OCR, extraction changes",
          "No new capability, custody, key, or Vault policy is added.",
          "The seven-application dependency graph remains unchanged."
        ] do
      assert boundaries =~ marker
    end
  end

  test "guide governing links and final implementation gate agree with the active slice" do
    guide = read_source("docs/guide.md")
    [header, _] = String.split(guide, "\n---\n", parts: 2)
    assert header =~ "[approved Phase 3 design](superpowers/specs/#{@design})"
    assert header =~ "[Phase 3 implementation plan](superpowers/plans/#{@plan})"
    assert header =~ "[Phase 4 design](superpowers/specs/#{@phase4_design})"
    assert header =~ "[Phase 4 implementation plan](superpowers/plans/#{@phase4_plan})"
    assert header =~ "[Phase 5 design](superpowers/specs/#{@phase5_design})"
    assert header =~ "[Phase 5 implementation plan](superpowers/plans/#{@phase5_plan})"

    [_, gate] = String.split(guide, "# 24. Current implementation gate\n", parts: 2)
    gate = String.replace(gate, ~r/\s+/, " ")

    for marker <- [
          "Phase 5 is the current target.",
          "portable-export and logical-backup design and detailed implementation plan",
          "Phase 5 must finish with recorded scoped evidence, a clean worktree, the complete permitted verification gate passing, and independent review.",
          "Production canonical writes remain disabled.",
          "After the required gate and independent review pass, automatically prepare the next phase's design and plan under the continuous authorization.",
          "Vault changes, merge, version bumps, tags, publication, pushes, deployment, and production activation remain outside that authority.",
          "The user's 2026-10-10 E2E deferral permits local phase advancement after all other required checks and independent review pass.",
          "E2E stays NOT RUN; final browser/release acceptance remains required."
        ] do
      assert gate =~ marker
    end
  end

  test "activation prerequisites and the narrowed source proof remain explicit" do
    for {path, start, finish} <- [
          {"AGENTS.md", "## Active release", "## Vault freeze"},
          {"README.md", "## Active `0.2.0` scope", "## Development"},
          {"docs/guide.md", "# 21. Active implementation roadmap",
           "# 22. Cross-cutting invariants"}
        ] do
      section = active_section!(path, start, finish)

      for marker <- [
            "Phase 2 must provide original-byte retention and abandoned extraction recovery before public import.",
            "Phase 4 must seal Note source-set membership before enabling its writes.",
            "Production activation requires a fail-closed backup guard for unsupported canonical rows or complete V3 support.",
            "Phase 1 source acceptance covers only the bounded authenticated storage digest primitive, source-proof contract, source revalidation, and isolated contract tests.",
            "Live runtime custody composition requires a separately approved Phase 2 design.",
            "No custody, key, capability, or Vault change is authorized.",
            "Test doubles do not prove live source verification."
          ] do
        assert section =~ marker, "#{path} is missing an activation prerequisite: #{marker}"
      end
    end
  end

  test "public Document browser routes remain absent and runtime registration is bounded" do
    routes = Singularity.Web.Router.__routes__()
    assert Enum.any?(routes, &(&1.path == "/notes"))

    for route <- routes do
      refute inspect(route) =~ ~r/document|extract/i
      refute inspect(route) =~ ~r/knowledge|search/i
    end

    for path <- Map.keys(@runtime_baselines) do
      assert_document_registration!(path, read_source(path))
    end

    expected_functions =
      for operation <- @document_operations,
          arity <-
            if(operation in [:retry_document, :delete_document, :restore_document],
              do: [2, 3, 4],
              else: [2, 3]
            ),
          do: {operation, arity}

    actual_functions =
      Singularity.Runtime.Api.__info__(:functions)
      |> Enum.filter(fn {name, _} -> to_string(name) =~ ~r/document/i end)

    assert Enum.sort(actual_functions) == Enum.sort(expected_functions)
  end

  test "Document function names cannot evade the registration scan" do
    assert {:ok, ast} =
             Code.string_to_quoted(
               "defmodule Example do; def import_document(input), do: input; end"
             )

    assert :import_document in document_terms(ast)
  end

  test "logical V1 and V2 backup schemas remain unchanged from the accepted baseline" do
    assert_baseline_files!(%{
      "apps/singularity_storage/lib/singularity/storage/backup/logical_schema.ex" =>
        "ba0722ca85ce0a1259ce650927aa53ed728db0b28467adf308c3ada5a03036e8",
      "apps/singularity_storage/lib/singularity/storage/backup/logical_schema_v2.ex" =>
        "992ef89fb52a91ccaa0d7cf2b3ae6607a465e7b345cca5d6c55a86c3fac9f3e6"
    })
  end

  test "approved Phase 2 Phase 3 and Phase 4 additions preserve every original legacy composition byte" do
    for {path, expected} <- @runtime_baselines do
      assert_runtime_baseline!(path, read_source(path), expected)
    end
  end

  for {label, path, addition, destination} <- [
        {"Oban queue", "config/config.exs", "    document_extract: 2,\n", "  tailwind: [\n"},
        {"application alias", @application,
         "  alias Singularity.Runtime.Documents.ExtractionReconciler\n",
         "  alias Singularity.Runtime.BackupKeyLease\n"},
        {"supervisor child", @application, "      ExtractionReconciler,\n",
         "      key_custodian,\n"}
      ] do
    test "#{label} cannot be relocated outside its approved insertion context" do
      path = unquote(path)
      source = read_source(path)
      assert_runtime_baseline!(path, source, @runtime_baselines[path])
      source = normalize_phase5!(path, source)
      addition = unquote(addition)
      assert [before, rest] = String.split(source, addition)

      relocated =
        String.replace(
          before <> rest,
          unquote(destination),
          unquote(destination) <> addition,
          global: false
        )

      refute relocated == source
      assert_document_registration!(path, relocated)

      assert_raise ExUnit.AssertionError, fn ->
        assert_historical_runtime_baseline!(path, relocated, @runtime_baselines[path])
      end
    end
  end

  test "registration and byte guards reject unauthorized Document and legacy changes" do
    for {path, expected} <- @runtime_baselines do
      source = read_source(path)
      assert_runtime_baseline!(path, source, expected)
      source = normalize_phase5!(path, source)
      unauthorized = source <> "\ndefmodule ExtraDocumentRegistration do; end\n"

      assert_raise ExUnit.AssertionError, fn ->
        assert_document_registration!(path, unauthorized)
      end

      for changed <- [unauthorized, source <> "\n:unrelated_legacy_change\n"] do
        assert_raise ExUnit.AssertionError, fn ->
          assert_historical_runtime_baseline!(path, changed, expected)
        end
      end
    end
  end

  test "approved additions cannot change, disappear or be duplicated" do
    source = read_source(@api)
    assert_runtime_baseline!(@api, source, @runtime_baselines[@api])
    source = normalize_phase5!(@api, source)

    for {pattern, _} <- api_additions() do
      assert [[addition]] = Regex.scan(pattern, source)

      for changed <- [
            String.replace(source, addition, addition <> "  # unapproved change\n"),
            String.replace(source, addition, ""),
            String.replace(source, addition, addition <> addition)
          ] do
        assert_raise ExUnit.AssertionError, fn ->
          assert_historical_runtime_baseline!(@api, changed, @runtime_baselines[@api])
        end
      end
    end

    for {path, addition} <- [
          {@application, "  alias Singularity.Runtime.Documents.ExtractionReconciler\n"},
          {@application, "      ExtractionReconciler,\n"},
          {"config/config.exs", "    document_extract: 2,\n"}
        ] do
      source = read_source(path)
      assert_runtime_baseline!(path, source, @runtime_baselines[path])
      source = normalize_phase5!(path, source)

      for replacement <- ["", addition <> addition, String.replace(addition, "2", "3")] do
        if replacement != addition do
          assert_raise ExUnit.AssertionError, fn ->
            assert_historical_runtime_baseline!(
              path,
              String.replace(source, addition, replacement),
              @runtime_baselines[path]
            )
          end
        end
      end
    end
  end

  test "every approved worker block rejects mutation, removal, duplication and relocation" do
    for {path, preceding, addition, following, destination} <- worker_additions() do
      source = read_source(path)
      assert_runtime_baseline!(path, source, @runtime_baselines[path])
      source = normalize_phase5!(path, source)
      source = strip_phase3_additions!(path, strip_phase4_additions!(source, path))
      assert [before, rest] = String.split(source, addition)

      for replacement <- ["", addition <> addition, addition <> "  # unapproved worker change\n"] do
        changed = before <> replacement <> rest

        assert_raise ExUnit.AssertionError, fn ->
          assert_phase2_runtime_baseline!(path, changed, @runtime_baselines[path])
        end
      end

      assert [_, _] = String.split(source, preceding <> addition <> following)

      relocated =
        String.replace(before <> rest, destination, destination <> addition, global: false)

      refute relocated == source
      assert_document_registration!(path, relocated, :phase2)

      assert_raise ExUnit.AssertionError, fn ->
        assert_phase2_runtime_baseline!(path, relocated, @runtime_baselines[path])
      end
    end
  end

  test "every approved Phase 3 block rejects mutation, removal, duplication and relocation" do
    for {path, preceding, addition, following, destination} <- phase3_additions() do
      source = read_source(path)
      assert_runtime_baseline!(path, source, @runtime_baselines[path])
      source = normalize_phase5!(path, source)
      assert [before, rest] = String.split(source, addition)
      assert [_, _] = String.split(source, preceding <> addition <> following)

      relocated =
        String.replace(before <> rest, destination, destination <> addition, global: false)

      refute relocated == source
      assert_document_registration!(path, relocated)

      assert [token] =
               Regex.run(
                 ~r/SearchSource|KnowledgeSearchQuery|KnowledgeSearchPage|KnowledgeSearch|search_knowledge|SearchProjectionReconciler|DocumentProjection|document_projection|SearchRebuild|rebuild_search/,
                 addition
               )

      mutated = String.replace(addition, token, token <> "Unapproved", global: false)
      refute mutated == addition

      for changed <- [
            before <> rest,
            before <> addition <> addition <> rest,
            before <> mutated <> rest,
            relocated
          ] do
        assert_raise ExUnit.AssertionError, fn ->
          assert_historical_runtime_baseline!(path, changed, @runtime_baselines[path])
        end
      end
    end
  end

  test "exact Note source resolution public and leading-config registration is closed" do
    expected =
      for operation <- [:resolve_note_attachment, :resolve_note_citation],
          arity <- [4, 5],
          do: {operation, arity}

    actual =
      Singularity.Runtime.Api.__info__(:functions)
      |> Enum.filter(fn {name, _arity} ->
        String.starts_with?(to_string(name), "resolve_note_")
      end)

    assert Enum.sort(actual) == Enum.sort(expected)
  end

  test "every approved Phase 4 block rejects mutation removal duplication and relocation" do
    for {path, preceding, addition, following, destination} <- phase4_additions() do
      source = read_source(path)
      assert_runtime_baseline!(path, source, @runtime_baselines[path])
      source = normalize_phase5!(path, source)
      assert [before, rest] = String.split(source, addition)
      normalized = strip_phase4_organization_additions!(source, path)
      assert [_, _] = String.split(normalized, preceding <> addition <> following)

      relocated =
        String.replace(before <> rest, destination, destination <> addition, global: false)

      refute relocated == source

      for changed <- [
            before <> rest,
            before <> addition <> addition <> rest,
            before <> addition <> "  # unauthorized Phase 4 change\n" <> rest,
            relocated
          ] do
        assert_raise ExUnit.AssertionError, fn ->
          assert_historical_runtime_baseline!(path, changed, @runtime_baselines[path])
        end
      end
    end
  end

  test "Task 6 organization public registration is exact and closed" do
    expected =
      for {operation, arities} <- [
            attach_tag: [3, 4],
            detach_tag: [3, 4],
            list_resource_tags: [2, 3, 4],
            browse_resources_by_tag: [3, 4],
            relate_resource: [3, 4],
            unrelate_resource: [2, 3],
            list_outgoing_relationships: [3, 4],
            list_backlinks: [3, 4]
          ],
          arity <- arities,
          do: {operation, arity}

    actual =
      Singularity.Runtime.Api.__info__(:functions)
      |> Enum.filter(fn {name, _arity} ->
        Regex.match?(
          ~r/^(attach_tag|detach_tag|list_resource_tags|browse_resources_by_tag|relate_resource|unrelate_resource|list_outgoing_relationships|list_backlinks)/,
          to_string(name)
        )
      end)

    assert Enum.sort(actual) == Enum.sort(expected)
  end

  test "every Task 6 organization block rejects mutation removal duplication and relocation" do
    for {path, preceding, addition, following, destination} <- phase4_organization_additions() do
      source = read_source(path)
      assert_runtime_baseline!(path, source, @runtime_baselines[path])
      source = normalize_phase5!(path, source)
      assert [before, rest] = String.split(source, addition)
      assert [_, _] = String.split(source, preceding <> addition <> following)

      relocated =
        String.replace(before <> rest, destination, destination <> addition, global: false)

      refute relocated == source

      for changed <- [
            before <> rest,
            before <> addition <> addition <> rest,
            before <> addition <> "  # unauthorized organization change\n" <> rest,
            relocated
          ] do
        assert_raise ExUnit.AssertionError, fn ->
          assert_historical_runtime_baseline!(path, changed, @runtime_baselines[path])
        end
      end
    end
  end

  test "documentation attributes remain outside the registration scan" do
    assert {:ok, ast} =
             Code.string_to_quoted("""
             defmodule Example do
               @moduledoc "Document imports remain deferred"
               @doc "Document imports remain deferred"
               def identity(input), do: input
               @typedoc "Document imports remain deferred"
               @type input :: term()
             end
             """)

    assert document_terms(ast) == []
  end

  test "documentation attributes cannot hide an adjacent Document registration" do
    assert {:ok, ast} =
             Code.string_to_quoted("""
             defmodule Example do
               @moduledoc "Document imports remain deferred"
               @doc "Document imports remain deferred"
               def unauthorized_document(input), do: input
               @typedoc "Document imports remain deferred"
               @type input :: term()
             end
             """)

    assert document_terms(ast) == [:unauthorized_document]
  end

  # Backup formats and all composition outside the exact approved additions
  # retain their original Phase 0 byte-level contracts.
  defp assert_baseline_files!(files) do
    for {path, expected} <- files do
      assert_digest!(path, read_source(path), expected)
    end
  end

  defp normalize_phase5!(@api, source) do
    source = strip_phase5_additions!(@api, source)
    undo_phase5_native_text!(source)
  end

  defp normalize_phase5!(path, source) do
    source = strip_phase5_additions!(path, source)
    undo_phase5_task8!(path, source)
  end

  defp undo_phase5_native_text!(source) do
    Enum.reduce(native_text_hunks(), source, fn hunk, remaining ->
      {before, old, _new, after_bytes, prefix, suffix} = assert_native_text_hunk!(remaining, hunk)
      prefix <> before <> old <> after_bytes <> suffix
    end)
  end

  defp assert_runtime_baseline!(path, source, expected) do
    assert_historical_runtime_baseline!(path, normalize_phase5!(path, source), expected)
  end

  defp assert_historical_runtime_baseline!(path, source, expected) do
    source = strip_phase4_additions!(source, path)
    source = strip_phase3_additions!(path, source)
    assert_phase2_runtime_baseline!(path, source, expected)
  end

  defp assert_phase2_runtime_baseline!(path, source, expected) do
    legacy =
      case path do
        @api ->
          Enum.reduce(api_additions(), source, fn {pattern, digest}, remaining ->
            assert [[addition]] = Regex.scan(pattern, remaining)
            assert_digest!(path <> " approved addition", addition, digest)
            strip_unique!(remaining, addition)
          end)

        @application ->
          source
          |> strip_in_context!(
            "  alias Singularity.Runtime.Assets.UploadReconciler\n",
            "  alias Singularity.Runtime.Documents.ExtractionReconciler\n",
            "  alias Singularity.Runtime.Authorize\n"
          )
          |> strip_in_context!(
            "      UploadReconciler,\n",
            "      ExtractionReconciler,\n",
            "      upload_recovery_tasks,\n"
          )

        "config/config.exs" ->
          strip_in_context!(
            source,
            "    note_projection: 2,\n",
            "    document_extract: 2,\n",
            "    backup: 1,\n"
          )

        _ ->
          source
      end

    legacy =
      Enum.reduce(worker_additions(), legacy, fn
        {^path, preceding, addition, following, _destination}, remaining ->
          strip_in_context!(remaining, preceding, addition, following)

        _other, remaining ->
          remaining
      end)

    assert_digest!(path, legacy, expected)
  end

  defp strip_phase3_additions!(path, source) do
    Enum.reduce(phase3_additions(), source, fn
      {^path, preceding, addition, following, _destination}, remaining ->
        strip_in_context!(remaining, preceding, addition, following)

      _other, remaining ->
        remaining
    end)
  end

  defp strip_phase4_additions!(source, path) do
    source = strip_phase4_organization_additions!(source, path)

    Enum.reduce(phase4_additions(), source, fn
      {^path, preceding, addition, following, _destination}, remaining ->
        strip_in_context!(remaining, preceding, addition, following)

      _other, remaining ->
        remaining
    end)
  end

  defp strip_unique!(source, addition) do
    assert [before, rest] = String.split(source, addition)
    before <> rest
  end

  defp strip_in_context!(source, preceding, addition, following) do
    assert [_, _] = String.split(source, preceding <> addition <> following)
    strip_unique!(source, addition)
  end

  defp assert_digest!(path, bytes, expected) do
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    assert actual == expected, "#{path} changed from accepted baseline #{@baseline}"
  end

  defp assert_document_registration!(path, source, phase \\ :current) do
    assert {:ok, ast} = Code.string_to_quoted(source)
    actual = ast |> document_terms() |> Enum.uniq() |> Enum.sort()
    phase3 = if phase == :current, do: Map.get(@phase3_document_terms, path, []), else: []
    expected = Enum.sort(Map.get(@document_terms, path, []) ++ phase3)
    assert actual == expected, "unapproved Document registration found in #{path}"
  end

  defp read_source(path), do: @repo_root |> Path.join(path) |> File.read!()

  # Task 6 additions are stripped before Task 4, preserving all earlier byte guards.
  defp strip_phase4_organization_additions!(source, path) do
    Enum.reduce(phase4_organization_additions(), source, fn
      {^path, preceding, addition, following, _destination}, remaining ->
        strip_in_context!(remaining, preceding, addition, following)

      _other, remaining ->
        remaining
    end)
  end

  defp phase4_organization_additions do
    [
      {@api, "  alias Singularity.Runtime.Notes.Trash, as: NoteTrash\n",
       "  alias Singularity.Runtime.Organization.DTO, as: OrganizationDTO\n" <>
         "  alias Singularity.Runtime.Organization.Operations, as: OrganizationOperations\n",
       "  alias Singularity.Runtime.OperationScope\n",
       "  alias Singularity.Runtime.KeyCustodian\n"},
      {@api, "  alias Singularity.Storage.Postgres.NoteSearchStore\n",
       "  alias Singularity.Storage.Postgres.OrganizationRepository\n" <>
         "  alias Singularity.Storage.Postgres.RelationshipRepository\n" <>
         "  alias Singularity.Storage.Postgres.TagRepository\n",
       "  alias Singularity.Storage.Postgres.PreAuth\n",
       "  alias Singularity.Runtime.KeyCustodian\n"},
      {@api,
       "  defp canonical_note_source_uuid?(value), do: Ecto.UUID.cast(value) == {:ok, value}\n\n",
       ~S"""
         @doc "Attaches a canonical private tag after current resource-kind authorization."
         def attach_tag(session, resource_id, attrs),
           do: organization_production(:attach_tag, session, resource_id, attrs)

         @doc false
         def attach_tag(config, session, resource_id, attrs),
           do: organization_call(config, :attach_tag, session, resource_id, attrs)

         def detach_tag(session, resource_id, tag_id),
           do: organization_production(:detach_tag, session, resource_id, tag_id)

         @doc false
         def detach_tag(config, session, resource_id, tag_id),
           do: organization_call(config, :detach_tag, session, resource_id, tag_id)

         def list_resource_tags(session, resource_id),
           do: list_resource_tags(session, resource_id, %{})

         def list_resource_tags(%Session{} = session, resource_id, params),
           do: organization_production(:list_resource_tags, session, resource_id, params)

         def list_resource_tags(_session, _resource_id, _params), do: {:error, :invalid}

         @doc false
         def list_resource_tags(config, session, resource_id, params),
           do: organization_call(config, :list_resource_tags, session, resource_id, params)

         def browse_resources_by_tag(session, tag_id, params),
           do: organization_production(:browse_resources_by_tag, session, tag_id, params)

         @doc false
         def browse_resources_by_tag(config, session, tag_id, params),
           do: organization_call(config, :browse_resources_by_tag, session, tag_id, params)

         def relate_resource(session, source_resource_id, attrs),
           do: organization_production(:relate_resource, session, source_resource_id, attrs)

         @doc false
         def relate_resource(config, session, source_resource_id, attrs),
           do: organization_call(config, :relate_resource, session, source_resource_id, attrs)

         def unrelate_resource(session, relationship_id),
           do: organization_production(:unrelate_resource, session, relationship_id, nil)

         @doc false
         def unrelate_resource(config, session, relationship_id),
           do: organization_call(config, :unrelate_resource, session, relationship_id, nil)

         def list_outgoing_relationships(session, resource_id, params),
           do: organization_production(:list_outgoing_relationships, session, resource_id, params)

         @doc false
         def list_outgoing_relationships(config, session, resource_id, params),
           do: organization_call(config, :list_outgoing_relationships, session, resource_id, params)

         def list_backlinks(session, resource_id, params),
           do: organization_production(:list_backlinks, session, resource_id, params)

         @doc false
         def list_backlinks(config, session, resource_id, params),
           do: organization_call(config, :list_backlinks, session, resource_id, params)

         defp organization_production(operation, session, selector, params) do
           with {:ok, _validated} <- OrganizationOperations.validate(operation, selector, params) do
             with_production(&organization_call(&1, operation, session, selector, params))
           else
             error -> normalize_error(error)
           end
         end

         defp organization_call(config, operation, %Session{} = session, selector, params)
              when is_map(config) and not is_struct(config) do
           with {:ok, _validated} <- OrganizationOperations.validate(operation, selector, params),
                {:ok, context} <- note_source_session(session) do
             arguments =
               if operation == :unrelate_resource,
                 do: [context, selector],
                 else: [context, selector, params]

             case invoke(config, operation, arguments) do
               {:error, _} = error ->
                 normalize_error(error)

               reply ->
                 OrganizationDTO.convert(operation, reply, context.vault_id, selector, params)
                 |> normalize_organization_result()
             end
           else
             error -> normalize_error(error)
           end
         end

         defp organization_call(_config, _operation, _session, _selector, _params),
           do: {:error, :invalid}

         defp normalize_organization_result(:ok), do: :ok
         defp normalize_organization_result({:ok, _dto} = result), do: result
         defp normalize_organization_result(error), do: normalize_error(error)

       """, "  @spec get_note_conflict(Session.t(), String.t(), String.t()) ::\n",
       "  def get_note_conflict(_config, _session, _resource_id, _conflict_id),\n    do: {:error, :invalid}\n\n"},
      {@api,
       "        NoteSourceResolver.citation(runtime, session, note_id, version_id, citation_id)\n      end,\n",
       ~S"""
             attach_tag: &OrganizationOperations.attach_tag(runtime, &1, &2, &3),
             detach_tag: &OrganizationOperations.detach_tag(runtime, &1, &2, &3),
             list_resource_tags: &OrganizationOperations.list_resource_tags(runtime, &1, &2, &3),
             browse_resources_by_tag:
               &OrganizationOperations.browse_resources_by_tag(runtime, &1, &2, &3),
             relate_resource: &OrganizationOperations.relate_resource(runtime, &1, &2, &3),
             unrelate_resource: &OrganizationOperations.unrelate_resource(runtime, &1, &2),
             list_outgoing_relationships:
               &OrganizationOperations.list_outgoing_relationships(runtime, &1, &2, &3),
             list_backlinks: &OrganizationOperations.list_backlinks(runtime, &1, &2, &3),
       """, "      import_document: fn session, attrs ->\n",
       "      list_assets: fn session, params ->\n"},
      {@api, "      note_search_store: NoteSearchStore,\n",
       "      organization_repository: OrganizationRepository,\n" <>
         "      tag_repository: TagRepository,\n" <>
         "      relationship_repository: RelationshipRepository,\n", "      notes: Notes,\n",
       "      assets: AssetRepository,\n"}
    ]
  end

  # Each Phase 4 insertion is frozen in its original context before removing
  # it from the unchanged Phase 3, Phase 2 and legacy byte contracts.
  defp phase4_additions do
    [
      {@api, "  alias Singularity.Runtime.Notes.Restore, as: NoteRestore\n",
       "  alias Singularity.Runtime.Notes.ResolveSource, as: NoteSourceResolver\n",
       "  alias Singularity.Runtime.Notes.Save, as: NoteSave\n",
       "  alias Singularity.Runtime.KeyCustodian\n"},
      {@api, "  alias Singularity.Storage.Postgres.IdentityRepository\n",
       "  alias Singularity.Storage.Postgres.KnowledgeLinkRepository\n",
       "  alias Singularity.Storage.Postgres.NoteRepository\n",
       "  alias Singularity.Runtime.KeyCustodian\n"},
      {@api,
       "  def get_note_version(_config, _session, _resource_id, _version_id),\n    do: {:error, :invalid}\n\n",
       ~S"""
         @spec resolve_note_attachment(Session.t(), String.t(), String.t(), String.t()) ::
                 {:ok, map()} | {:error, atom()}
         def resolve_note_attachment(session, note_id, version_id, attachment_id) do
           if Enum.all?([note_id, version_id, attachment_id], &canonical_note_source_uuid?/1) do
             with_production(&resolve_note_attachment(&1, session, note_id, version_id, attachment_id))
           else
             {:error, :invalid}
           end
         end

         @doc false
         def resolve_note_attachment(config, %Session{} = session, note_id, version_id, attachment_id)
             when is_map(config),
             do: resolve_note_source(config, session, note_id, version_id, attachment_id, :attachment)

         def resolve_note_attachment(_config, _session, _note_id, _version_id, _attachment_id),
           do: {:error, :invalid}

         @spec resolve_note_citation(Session.t(), String.t(), String.t(), String.t()) ::
                 {:ok, map()} | {:error, atom()}
         def resolve_note_citation(session, note_id, version_id, citation_id) do
           if Enum.all?([note_id, version_id, citation_id], &canonical_note_source_uuid?/1) do
             with_production(&resolve_note_citation(&1, session, note_id, version_id, citation_id))
           else
             {:error, :invalid}
           end
         end

         @doc false
         def resolve_note_citation(config, %Session{} = session, note_id, version_id, citation_id)
             when is_map(config),
             do: resolve_note_source(config, session, note_id, version_id, citation_id, :citation)

         def resolve_note_citation(_config, _session, _note_id, _version_id, _citation_id),
           do: {:error, :invalid}

         defp resolve_note_source(config, session, note_id, version_id, member_id, operation) do
           callback =
             case operation do
               :attachment -> :resolve_note_attachment
               :citation -> :resolve_note_citation
             end

           with true <- Enum.all?([note_id, version_id, member_id], &canonical_note_source_uuid?/1),
                {:ok, context} <- note_source_session(session),
                {:ok, resolved} <- invoke(config, callback, [context, note_id, version_id, member_id]),
                {:ok, dto} <-
                  NotesDTO.source_resolution(operation, resolved, member_id, context.vault_id) do
             {:ok, dto}
           else
             false -> {:error, :invalid}
             result -> normalize_note_error(result)
           end
         end

         defp note_source_session(session) do
           with true <- Enum.sort(Map.keys(session)) == Enum.sort(Map.keys(Session.__struct__())),
                ids = [session.session_id, session.principal_id, session.vault_id],
                ids = if(is_nil(session.account_id), do: ids, else: [session.account_id | ids]),
                true <- Enum.all?(ids, &canonical_note_source_uuid?/1) do
             session_context(session)
           else
             _invalid -> {:error, :integrity_failure}
           end
         end

         defp canonical_note_source_uuid?(value), do: Ecto.UUID.cast(value) == {:ok, value}

       """, "  @spec get_note_conflict(Session.t(), String.t(), String.t()) ::\n",
       "  def get_note_conflict(_config, _session, _resource_id, _conflict_id),\n    do: {:error, :invalid}\n\n"},
      {@api,
       "      get_note_version: fn session, resource_id, version_id ->\n        NoteGet.version(runtime, session, resource_id, version_id)\n      end,\n",
       "      resolve_note_attachment: fn session, note_id, version_id, attachment_id ->\n" <>
         "        NoteSourceResolver.attachment(runtime, session, note_id, version_id, attachment_id)\n      end,\n" <>
         "      resolve_note_citation: fn session, note_id, version_id, citation_id ->\n" <>
         "        NoteSourceResolver.citation(runtime, session, note_id, version_id, citation_id)\n      end,\n",
       "      import_document: fn session, attrs ->\n",
       "      list_assets: fn session, params ->\n"},
      {@api, "      note_repository: NoteRepository,\n",
       "      knowledge_link_repository: KnowledgeLinkRepository,\n",
       "      note_search: NoteLexicalSearch,\n", "      assets: AssetRepository,\n"}
    ]
  end

  # Remove only the exact approved Phase 3 bytes in their original context,
  # then prove every Phase 2 addition and the unchanged legacy digests below.
  defp phase3_additions do
    [
      {@api, "  alias Singularity.Core.Error\n", "  alias Singularity.Core.SearchSource\n",
       "  alias Singularity.Domains.Notes\n", "  alias Singularity.Runtime.KeyCustodian\n"},
      {@api, "  alias Singularity.Retrieval.NoteLexicalSearch\n",
       "  alias Singularity.Retrieval.KnowledgeSearchQuery\n",
       "  alias Singularity.Runtime.Api.UploadHandle\n",
       "  alias Singularity.Runtime.KeyCustodian\n"},
      {@api, "  alias Singularity.Runtime.DTO.BackupStatus\n",
       "  alias Singularity.Runtime.DTO.KnowledgeSearchPage\n" <>
         "  alias Singularity.Runtime.DTO.KnowledgeSource\n",
       "  alias Singularity.Runtime.DTO.SearchPage\n",
       "  alias Singularity.Runtime.KeyCustodian\n"},
      {@api, "  alias Singularity.Runtime.ResolveSession\n",
       "  alias Singularity.Runtime.Search.Search, as: KnowledgeSearch\n" <>
         "  alias Singularity.Runtime.Search.Resolve, as: SearchSourceResolver\n",
       "  alias Singularity.Runtime.SessionContext\n",
       "  alias Singularity.Runtime.KeyCustodian\n"},
      {@api, "  def search_notes(_config, _session, _params), do: {:error, :invalid}\n\n",
       ~S"""
         @spec search_knowledge(Session.t(), map() | keyword()) ::
                 {:ok, KnowledgeSearchPage.t()} | {:error, atom()}
         def search_knowledge(session, params),
           do: with_production(&search_knowledge(&1, session, params))

         @doc false
         def search_knowledge(config, %Session{} = session, params) when is_map(config) do
           with {:ok, context} <- session_context(session),
                {:ok, query} <- KnowledgeSearchQuery.new(context.vault_id, params),
                {:ok, page} <- invoke(config, :search_knowledge, [context, knowledge_params(query)]),
                {:ok, dto} <- KnowledgeSearchPage.from_page(page, query) do
             {:ok, dto}
           else
             result -> normalize_error(result)
           end
         end

         def search_knowledge(_config, _session, _params), do: {:error, :invalid}

         @spec resolve_search_source(Session.t(), term()) ::
                 {:ok, KnowledgeSource.t()} | {:error, atom()}
         def resolve_search_source(session, selector),
           do: with_production(&resolve_search_source(&1, session, selector))

         @doc false
         def resolve_search_source(config, %Session{} = session, input) when is_map(config) do
           with {:ok, context} <- session_context(session),
                {:ok, selector} <- SearchSource.new(input),
                true <- not is_struct(input) or input === selector,
                {:ok, source} <- invoke(config, :resolve_search_source, [context, selector]),
                {:ok, dto} <- KnowledgeSource.from_source(source, context.vault_id, selector) do
             {:ok, dto}
           else
             false -> {:error, :invalid}
             result -> normalize_error(result)
           end
         end

         def resolve_search_source(_config, _session, _input), do: {:error, :invalid}

         defp knowledge_params(query), do: Map.take(query, [:q, :kind, :tag_ids, :limit, :cursor])

       """, "  @spec trash_notes(Session.t(), map() | keyword()) ::\n",
       "  def trash_notes(_config, _session, _params), do: {:error, :invalid}\n\n"},
      {@api,
       "      search_notes: fn session, params ->\n        NoteSearch.run(runtime, session, params)\n      end,\n",
       "      search_knowledge: fn session, params ->\n" <>
         "        KnowledgeSearch.run(runtime, session, params)\n      end,\n" <>
         "      resolve_search_source: fn session, selector ->\n" <>
         "        SearchSourceResolver.run(runtime, session, selector)\n      end,\n",
       "      subscribe_assets: &AssetEvents.subscribe/1,\n",
       "      subscribe_assets: &AssetEvents.subscribe/1,\n"},
      {@application, "  alias Singularity.Storage.Postgres.NoteRepository\n",
       "  alias Singularity.Storage.Postgres.SearchProjectionReconciler\n", "\n  @impl true\n",
       "  alias Singularity.Runtime.BackupKeyLease\n"},
      {@application, "      document_worker: DocumentWorkerRepository,\n",
       "      document_projection: SearchProjectionReconciler,\n",
       "      document_extractors: %{\n", "      assets: AssetRepository,\n"},
      {@dispatcher, "  alias Singularity.Runtime.Documents.Extract\n",
       "  alias Singularity.Runtime.Documents.Projection, as: DocumentProjection\n",
       "  alias Singularity.Runtime.DownloadLease\n",
       "  alias Singularity.Runtime.AssetEvents\n"},
      {@dispatcher,
       "  def handle(context, %{job_type: \"document_extract\"} = envelope),\n    do: Extract.run(context, envelope)\n\n",
       "  def handle(context, %{job_type: \"document_projection\"} = envelope),\n    do: DocumentProjection.run(context, envelope)\n\n",
       "  def handle(_context, _envelope), do: {:error, Error.new(:job_failed)}\n",
       "  @impl true\n  def handle(context, %{job_type: \"asset_verify\"} = envelope),\n    do: run_asset_job(context, envelope, Verify)\n\n"},
      {@dispatcher, "  def wake_waiting(_command), do: {:error, Error.new(:invalid)}\n\n",
       "  @impl true\n  def handle_failure(\n" <>
         "        _context,\n        %JobEnvelope{job_type: \"document_projection\"},\n" <>
         "        %Error{} = failure,\n        _attempt\n      ),\n" <>
         "      do: {:error, Error.new(failure.code, retryable?: failure.retryable?)}\n\n",
       "  @impl true\n  def handle_failure(\n        context,\n        %JobEnvelope{job_type: \"document_extract\"} = envelope,\n",
       "  @impl true\n  def handle(context, %{job_type: \"asset_verify\"} = envelope),\n    do: run_asset_job(context, envelope, Verify)\n\n"},
      {@api, "  alias Singularity.Runtime.SessionContext\n",
       "  alias Singularity.Runtime.Search.Rebuild, as: SearchRebuild\n",
       "  alias Singularity.Runtime.StorageAdapter\n",
       "  alias Singularity.Runtime.KeyCustodian\n"},
      {@api, "  def trash_notes(_config, _session, _params), do: {:error, :invalid}\n\n",
       ~S"""
         @spec rebuild_search(Session.t(), String.t() | :all) ::
                 {:ok, %{resources: non_neg_integer(), entries: non_neg_integer()}} | {:error, atom()}
         def rebuild_search(session, selector),
           do: with_production(&rebuild_search(&1, session, selector))

         @doc false
         def rebuild_search(config, %Session{} = session, input) when is_map(config) do
           with {:ok, context} <- session_context(session),
                {:ok, selector} <- SearchRebuild.validate_selector(input),
                {:ok, counts} <- invoke(config, :rebuild_search, [context, selector]),
                {:ok, counts} <- SearchRebuild.validate_counts(counts) do
             {:ok, counts}
           else
             result -> normalize_error(result)
           end
         end

         def rebuild_search(_config, _session, _input), do: {:error, :invalid}

       """, "  @spec get_note(Session.t(), String.t()) ::\n",
       "  def search_notes(_config, _session, _params), do: {:error, :invalid}\n\n"},
      {@api, "      subscribe_assets: &AssetEvents.subscribe/1,\n",
       "      rebuild_search: fn session, selector ->\n" <>
         "        SearchRebuild.run(runtime, session, selector)\n      end,\n",
       "      trash_notes: fn session, params ->\n",
       "      publish_asset: &AssetEvents.publish/2,\n"},
      {"config/config.exs", "    document_extract: 2,\n", "    document_projection: 2,\n",
       "    backup: 1,\n", "  tailwind: [\n"}
    ]
  end

  defp worker_additions do
    [
      {@application, "  use Application\n\n",
       "  alias Singularity.Ingest.Documents.{Markdown, PDF, Text}\n",
       "  alias Singularity.Runtime.AuthorizationDependencies\n",
       "  alias Singularity.Runtime.BackupKeyLease\n"},
      {@application, "  alias Singularity.Storage.Postgres.BackupRepository\n",
       "  alias Singularity.Storage.Postgres.DocumentWorkerRepository\n",
       "  alias Singularity.Storage.Postgres.NoteProjectionReconciler\n",
       "  alias Singularity.Runtime.BackupKeyLease\n"},
      {@application,
       "        {LocalDestination,\n         %{backup_root: Application.fetch_env!(:singularity_storage, :backup_root)}},\n",
       "      document_worker: DocumentWorkerRepository,\n" <>
         "      document_extractors: %{\n" <>
         "        \"text/plain\" => {Text, \"plain_text\", 1},\n" <>
         "        \"text/markdown\" => {Markdown, \"markdown\", 1},\n" <>
         "        \"application/pdf\" => {PDF, \"poppler_text\", 1}\n" <>
         "      },\n", "      exporter: Exporter,\n", "      assets: AssetRepository,\n"},
      {@dispatcher, "  alias Singularity.Runtime.BackupVault\n",
       "  alias Singularity.Runtime.Documents.Extract\n" <>
         "  alias Singularity.Runtime.DownloadLease\n",
       "  alias Singularity.Runtime.KeyCustodian\n", "  alias Singularity.Runtime.AssetEvents\n"},
      {@dispatcher, "      custodian: custody_adapter(dependencies.authorization.custodian),\n",
       "      document_source_lease: DownloadLease,\n", "      job_progress: Progress,\n",
       "      job_progress: Progress,\n"},
      {@dispatcher,
       "  def handle(context, %{job_type: \"note_projection\"} = envelope),\n    do: Projection.run(context, envelope)\n\n",
       "  def handle(context, %{job_type: \"document_extract\"} = envelope),\n    do: Extract.run(context, envelope)\n\n",
       "  def handle(_context, _envelope), do: {:error, Error.new(:job_failed)}\n",
       "  @impl true\n  def handle(context, %{job_type: \"asset_verify\"} = envelope),\n    do: run_asset_job(context, envelope, Verify)\n\n"},
      {@dispatcher, "  def wake_waiting(_command), do: {:error, Error.new(:invalid)}\n\n",
       "  @impl true\n  def handle_failure(\n" <>
         "        context,\n" <>
         "        %JobEnvelope{job_type: \"document_extract\"} = envelope,\n" <>
         "        %Error{} = failure,\n" <>
         "        attempt\n" <>
         "      )\n" <>
         "      when is_map(context),\n" <>
         "      do: Extract.record_exhaustion(context, envelope, failure, attempt)\n\n",
       "  @impl true\n  def handle_failure(\n        context,\n        %JobEnvelope{job_type: \"asset_metadata\"} = envelope,\n",
       "  @impl true\n  def handle(context, %{job_type: \"asset_verify\"} = envelope),\n    do: run_asset_job(context, envelope, Verify)\n\n"}
    ]
  end

  # Freeze each approved addition independently before removing it from the
  # original legacy-byte contract. A changed or duplicated addition must fail.
  defp api_additions do
    [
      {~r/  alias Singularity\.Runtime\.Documents\.Import, as: DocumentImport\n.*?(?=  alias Singularity\.Runtime\.KeyCustodian)/s,
       "6e5e573a197e10d21c0e18b69a91557cabdc4f1486aee721e2b2d11467543bfd"},
      {~r/  @spec import_document\(.*?(?=  @spec save_note\()/s,
       "76fbee10dd1ebef8530135e8f3d2d2c974483b68564a2ad0aedd716e380fc2cd"},
      {~r/      import_document: fn.*?(?=      list_assets: fn)/s,
       "5749342645e9d8cf57814e5627a52b825cc4498b3ce368c1e3ea7fa65e5b0090"},
      {~r/  defp document_call\(.*?(?=  defp invoke\()/s,
       "956425e9fb1fb06699d5df97b5585a8a74779a842d6f4fcc87e5db7c65f8c878"}
    ]
  end

  defp document_terms(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{attribute, _, _}]}, found
        when attribute in [:doc, :moduledoc, :typedoc] ->
          {nil, found}

        {name, _metadata, _arguments} = node, found when is_atom(name) ->
          {node, if(to_string(name) =~ ~r/document/i, do: [name | found], else: found)}

        value, found when is_atom(value) or is_binary(value) ->
          {value, if(to_string(value) =~ ~r/document/i, do: [value | found], else: found)}

        node, found ->
          {node, found}
      end)

    found
  end

  defp active_section!(path, start, finish) do
    source = @repo_root |> Path.join(path) |> File.read!()
    active_section_source!(source, start, finish)
  end

  defp active_section_source!(source, start, finish) do
    assert [_, rest] = String.split(source, start <> "\n", parts: 2)
    assert [section, _] = String.split(rest, finish <> "\n", parts: 2)
    refute section =~ ~r/```|~~~|<!--|-->|^(?: {4,}| {0,3}\t)\S/m
    section |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  # BEGIN Task8 exact test attribution.
  test "accepted Task8 inverse recovers independently fixed pre-Task8 Application bytes" do
    raw = read_source(@application)
    Enum.each(phase5_task8_replacements(), &assert_task8_tuple!(raw, &1))
    staged = strip_phase5_additions!(@application, raw)
    inverse = undo_phase5_task8!(@application, staged)

    assert_digest!(
      @application <> " Task8 inverse",
      inverse,
      "4deda19432de3174c2f737216c8185e3cdea8bb91d3960475308a27558bdfbca"
    )

    assert_historical_runtime_baseline!(
      @application,
      inverse,
      @runtime_baselines[@application]
    )
  end

  for {id, mutation} <- [
        {"P5-T8A", :missing},
        {"P5-T8A", :duplicate},
        {"P5-T8A", :altered},
        {"P5-T8A", :relocated},
        {"P5-T8A", :before},
        {"P5-T8A", :after},
        {"P5-T8B", :missing},
        {"P5-T8B", :duplicate},
        {"P5-T8B", :altered},
        {"P5-T8B", :relocated},
        {"P5-T8B", :before},
        {"P5-T8B", :after},
        {"P5-T8B", :coexisting}
      ] do
    test "Task8 #{id} inverse rejects #{mutation}" do
      source = read_source(@application)
      tuple = Enum.find(phase5_task8_replacements(), &(elem(&1, 0) == unquote(id)))
      mutated = task8_mutation!(source, tuple, unquote(mutation))

      assert_raise ExUnit.AssertionError, fn ->
        undo_phase5_task8!(@application, mutated)
      end
    end
  end

  for {label, insertion, addition} <- [
        {"extra WorkerRepo alias", "defmodule Singularity.Runtime.Application do\n",
         "  alias Singularity.Storage.WorkerRepo, as: ExtraWorkerRepo\n"},
        {"extra object-storage clause", "      authorize: Authorize,\n",
         "      object_storage: {Exporter, %{repo: WorkerRepo, storage: storage, unauthorized: true}},\n"},
        {"adjacent unauthorized registration", "      Singularity.Storage.PreAuthRepo,\n",
         "      Singularity.Runtime.UnauthorizedDocument,\n"}
      ] do
    test "Task8 current-source digest rejects #{label}" do
      source = read_source(@application)
      assert_runtime_baseline!(@application, source, @runtime_baselines[@application])
      insertion = unquote(insertion)
      assert [prefix, suffix] = String.split(source, insertion)
      addition = unquote(addition)
      mutated = prefix <> insertion <> addition <> suffix
      refute mutated == source
      assert [_, _] = String.split(mutated, addition)
      normalized = undo_phase5_task8!(@application, mutated)
      refute normalized == undo_phase5_task8!(@application, source)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_runtime_baseline!(@application, mutated, @runtime_baselines[@application])
        end

      assert String.starts_with?(error.message, @application <> " changed from accepted baseline")
    end
  end

  defp phase5_task8_replacements do
    [
      {"P5-T8A", "  alias Singularity.Storage.Postgres.SearchProjectionReconciler\n", "",
       "  alias Singularity.Storage.WorkerRepo\n", "\n  @impl true\n",
       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
       "39a200187ee4217b6af3360373f70fa99161596960c6d41bf1a5505b4593ef54",
       "1eb83e25ae05b4c71e16192cd860d41bcd2276680872dc14f309790e8a84bb1f",
       "3d711a1b22e36f343aedd6f100553d22a36aecc0d9a53fcca215a99ac6cb0b0b",
       "  alias Singularity.Runtime.BackupKeyLease\n"},
      {"P5-T8B", "      object_lock: ObjectLock,\n",
       "      object_storage: {Exporter, storage},\n",
       "      object_storage: {Exporter, %{repo: WorkerRepo, storage: storage}},\n",
       "      storage: storage\n",
       "765151e924b1527ee46e84b28c1f4767fb8a24f7e4a0002f4bfb3bc92d978f63",
       "c7135faaa946b7ee597e9671c314a92a1ece93aaf2b3a0da4d72ffc92e84adc2",
       "ab107ddaf89d242ac18e359d680c0f11b7b35199be202c119672c769fcfe8050",
       "bb3696cd1d51ab0af2f6cb7a04cb6f8d388b38830892703f4ead6f591baf2c63",
       "      assets: AssetRepository,\n"}
    ]
  end

  defp undo_phase5_task8!(@application = path, source) do
    Enum.reduce(phase5_task8_replacements(), source, fn
      {id, before, old, new, after_bytes, old_hash, new_hash, old_context_hash, new_context_hash,
       _destination},
      remaining ->
        assert_digest!(path <> id <> " old", old, old_hash)
        assert_digest!(path <> id <> " new", new, new_hash)

        assert_digest!(
          path <> id <> " old context",
          before <> old <> after_bytes,
          old_context_hash
        )

        context = before <> new <> after_bytes
        assert_digest!(path <> id <> " new context", context, new_context_hash)
        assert [_, _] = String.split(remaining, new)
        if old != "", do: refute(String.contains?(remaining, old))
        assert [prefix, suffix] = String.split(remaining, context)
        prefix <> before <> old <> after_bytes <> suffix
    end)
  end

  defp undo_phase5_task8!(_path, source), do: source

  defp assert_task8_tuple!(source, tuple) do
    {id, before, old, new, after_bytes, old_hash, new_hash, old_context_hash, new_context_hash,
     destination} = tuple

    assert_digest!(@application <> id <> " old", old, old_hash)
    assert_digest!(@application <> id <> " new", new, new_hash)

    assert_digest!(
      @application <> id <> " old context",
      before <> old <> after_bytes,
      old_context_hash
    )

    assert_digest!(
      @application <> id <> " new context",
      before <> new <> after_bytes,
      new_context_hash
    )

    assert [_, _] = String.split(source, new)
    assert [prefix, suffix] = String.split(source, before <> new <> after_bytes)
    assert [_, _] = String.split(source, destination)
    if old != "", do: refute(String.contains?(source, old))
    {before, old, new, after_bytes, destination, prefix, suffix}
  end

  defp task8_mutation!(source, tuple, mutation) do
    {before, old, new, after_bytes, destination, prefix, suffix} =
      assert_task8_tuple!(source, tuple)

    context = before <> new <> after_bytes
    old_site = before <> old <> after_bytes

    mutated =
      case mutation do
        :missing ->
          removed = prefix <> old_site <> suffix
          refute String.contains?(removed, new)
          assert [_, _] = String.split(removed, old_site)
          removed

        :duplicate ->
          duplicated = prefix <> before <> new <> new <> after_bytes <> suffix
          assert [_, _, _] = String.split(duplicated, new)
          duplicated

        :altered ->
          altered_new = String.replace(new, "WorkerRepo", "WorkerRepoUnapproved")
          refute altered_new == new
          altered = prefix <> before <> altered_new <> after_bytes <> suffix
          assert [_, _] = String.split(altered, before <> altered_new <> after_bytes)
          refute String.contains?(altered, new)
          altered

        :relocated ->
          removed = prefix <> old_site <> suffix
          assert [destination_prefix, destination_suffix] = String.split(removed, destination)
          relocated = destination_prefix <> destination <> new <> destination_suffix
          assert [_, _] = String.split(relocated, new)
          assert [_, _] = String.split(relocated, destination <> new)
          assert [_, _] = String.split(relocated, old_site)
          refute String.contains?(relocated, context)
          relocated

        :before ->
          changed_before = before <> "  # unauthorized Task8 before context\n"
          changed = prefix <> changed_before <> new <> after_bytes <> suffix
          assert [_, _] = String.split(changed, new)
          assert [_, _] = String.split(changed, changed_before <> new <> after_bytes)
          refute String.contains?(changed, context)
          changed

        :after ->
          changed_after = "  # unauthorized Task8 after context\n" <> after_bytes
          changed = prefix <> before <> new <> changed_after <> suffix
          assert [_, _] = String.split(changed, new)
          assert [_, _] = String.split(changed, before <> new <> changed_after)
          refute String.contains?(changed, context)
          changed

        :coexisting ->
          assert old != ""
          coexisting = prefix <> before <> new <> old <> after_bytes <> suffix
          assert [_, _] = String.split(coexisting, new)
          assert [_, _] = String.split(coexisting, old)
          coexisting
      end

    refute mutated == source
    mutated
  end

  # END Task8 exact test attribution.

  # Native-text fixtures come from all eleven original context-bearing hunks of
  # 6fd422a6987121d02e54a8cc6395061880ec903f, not from normalized current bytes.
  test "accepted native-text inverse recovers exact pre-native and original API bytes" do
    raw = read_source(@api)
    source = strip_phase5_additions!(@api, raw)

    assert_digest!(
      @api <> " accepted native-text source",
      source,
      "8557685c2415c5ee3b30e33be6dfaab6e4ee25b0772bb3123a92384a914c33b4"
    )

    Enum.each(native_text_hunks(), &assert_native_text_hunk!(source, &1))
    normalized = undo_phase5_native_text!(source)

    assert_digest!(
      @api <> " pre-native-text inverse",
      normalized,
      "6212a126be413c4b19bc0e24e8cc3c86f1e8ce776ebd2e8a7427ee2e2695fda1"
    )

    assert_historical_runtime_baseline!(@api, normalized, @runtime_baselines[@api])
  end

  for id <- 1..11 do
    test "native-text hunk #{id} rejects all actual-source byte and context mutations" do
      source = read_source(@api)
      hunk = Enum.at(native_text_hunks(), unquote(id) - 1)

      for mutation <- [:altered, :removed, :reverted, :duplicate, :relocated, :before, :after] do
        mutated = native_text_mutation!(source, hunk, mutation)

        assert_raise ExUnit.AssertionError, fn ->
          assert_runtime_baseline!(@api, mutated, @runtime_baselines[@api])
        end
      end
    end
  end

  test "native-text attribution retains an unrelated legacy-byte counterproof" do
    source = read_source(@api)
    original = "  The sole application-facing runtime facade.\n"
    replacement = "  The unauthorized application-facing runtime facade.\n"
    assert [prefix, suffix] = String.split(source, original)
    mutated = prefix <> replacement <> suffix
    refute mutated == source
    assert [^prefix, ^suffix] = String.split(mutated, replacement)
    refute String.contains?(mutated, original)
    Enum.each(native_text_hunks(), &assert_native_text_hunk!(mutated, &1))

    assert_raise ExUnit.AssertionError, fn ->
      assert_runtime_baseline!(@api, mutated, @runtime_baselines[@api])
    end
  end

  defp native_text_hunks do
    [
      {1,
       "  alias Singularity.Storage.VaultLock\n  alias Singularity.Storage.Jobs.ObanAdapter\n\n",
       "  @safe_media_types [\"application/pdf\", \"image/jpeg\", \"image/png\"]\n",
       "  @text_media_types [\"text/plain\", \"text/markdown\"]\n" <>
         "  @safe_media_types [\"application/pdf\", \"image/jpeg\", \"image/png\"] ++ @text_media_types\n" <>
         "  @text_max_bytes 67_108_864\n", "  @asset_states [\n    :staging,\n    :uploaded,\n",
       "3314ab6561a150a4604c7950ae544186b705dde3fadc698fa86d0d9b424d4aa4",
       "1e54ba3b7f84aa3ff69c381df58d84bc7594922c446db92e1e59347c3b507540",
       "066dbac52c38eb1b7c063440c722f39c7481eb0e82247b20fe78ea91a4f50126",
       "47056bf6be4efafc4561d21507b56ae36b913518077e45bb511a4390b39c3a25"},
      {2,
       "  @doc false\n  def create_upload_grant(config, %Session{} = session, attrs, csrf_token)\n" <>
         "      when is_map(config) and is_map(attrs) and is_binary(csrf_token) do\n",
       "    with {:ok, context} <- session_context(session),\n" <>
         "         {:ok, grant} <-\n" <>
         "           invoke(config, :create_upload_grant, [context, attrs, csrf_token]),\n" <>
         "         {:ok, token} <- grant_token(grant),\n" <>
         "         {:ok, dto} <- upload_grant_dto(grant) do\n",
       "    with :ok <- public_upload_fields(attrs),\n" <>
         "         {:ok, context} <- session_context(session),\n" <>
         "         {:ok, grant} <-\n" <>
         "           invoke(config, :create_upload_grant, [context, attrs, csrf_token]),\n" <>
         "         {:ok, token} <- grant_token(grant),\n" <>
         "         {:ok, dto} <- upload_grant_dto(grant, config) do\n",
       "      publish_asset(config, context.vault_id, dto.asset_id)\n      {:ok, token, dto}\n    else\n",
       "51e6926067fbdaeb5a7b0b9704744a878003683babd0212df0cd039eb85c190a",
       "c319bc2876676ebec170fa80e5a8590ceb1f9376ecf74987a7ddca03120b0b32",
       "f3e60f044a9a4216748d0788ce7ded9566bb973a0770a9fe6e97f2996eefc091",
       "3c0049bd5dc246b4986be8922c8cd8193985155c6738d4e3740d2fd1ff376f1a"},
      {3, "\n  defp valid_failure?(_failure), do: false\n\n",
       "  defp upload_grant_dto(grant) when is_map(grant) do\n",
       "  defp upload_grant_dto(grant, config) when is_map(grant) do\n",
       "    values = %{\n      grant_id: Map.get(grant, :grant_id, Map.get(grant, :id)),\n" <>
         "      asset_id: Map.get(grant, :asset_id),\n",
       "de1d54d1498ab99f8edbb4d54cd5f7987ca58082d071a4622ab9012bcc24eaff",
       "ce02a390064cd9d77657a5dd415d4172880591f742ff197f9f6dbcb3b22abed2",
       "3dcf5a28b1e94ea271d93d2a8c3e86633bf1d456aa94c32ccc9ac5ab3aeee28b",
       "367defd3751a88d47722935f2a675677195f6556b44bc987b8f7027845894260"},
      {4,
       "      valid_uuid?(values.grant_id) and valid_uuid?(values.asset_id) and\n" <>
         "        nonblank?(values.filename) and valid_epoch?(values.byte_size) and\n" <>
         "        values.declared_media_type in @safe_media_types and\n", "",
       "        (values.declared_media_type not in @text_media_types or\n" <>
         "           validate_content_length(config, values.byte_size, values.declared_media_type) == :ok) and\n",
       "        values.classification in [:private, :sensitive, :restricted] and\n" <>
         "        is_struct(values.expires_at, DateTime)\n\n",
       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
       "09830167134ac2541f13e54bf74ed7117c9645b0bd06430068a592218e35ee3d",
       "77287937e3240da69cc62b97b3ae0132d7def8e364902a4cce53ae5e58f91d16",
       "f304d0348c717cd1a3d845e6610937d6f8f53d6b3b7dfc418d2066e793525065"},
      {5, "      else: {:error, :integrity_failure}\n  end\n\n",
       "  defp upload_grant_dto(_grant), do: {:error, :integrity_failure}\n",
       "  defp upload_grant_dto(_grant, _config), do: {:error, :integrity_failure}\n",
       "\n  defp grant_token(grant) when is_map(grant) do\n    case Map.get(grant, :token) do\n",
       "fedbfd2fb76f88957106a8d8bffa138f008b29684a5f4054c83cf199b64c80a0",
       "97e4504b80d0027908899b67b51c793bd39fb501e9bfe6a32045d6c5579a917b",
       "c1913388f1a2b01a962420651ddfaa379fbc344413c2cc2b164c993c7b1e8f91",
       "b5ba5475de20e1abd8ddaa7408de14d0f2364682806cfca13a78ca80c25f1b91"},
      {6,
       "  defp grant_token(_grant), do: {:error, :integrity_failure}\n\n" <>
         "  defp upload_selector(config, context, grant_id, request) do\n",
       "    with true <- context.unlocked?,\n" <>
         "         true <- valid_uuid?(grant_id),\n" <>
         "         {:ok, upload_token} <-\n" <>
         "           decode_token(Map.get(request, :upload_token)),\n" <>
         "         {:ok, csrf_token} <- csrf_token(Map.get(request, :csrf_token)),\n" <>
         "         content_length when is_integer(content_length) and content_length >= 0 <-\n" <>
         "           Map.get(request, :content_length),\n" <>
         "         :ok <- validate_content_length(config, content_length),\n" <>
         "         {:ok, declared_media_type} <-\n" <>
         "           upload_media_type(Map.get(request, :declared_media_type)) do\n",
       "    with :ok <- public_upload_fields(request),\n" <>
         "         true <- context.unlocked?,\n" <>
         "         true <- valid_uuid?(grant_id),\n" <>
         "         {:ok, upload_token} <-\n" <>
         "           decode_token(Map.get(request, :upload_token)),\n" <>
         "         {:ok, csrf_token} <- csrf_token(Map.get(request, :csrf_token)),\n" <>
         "         content_length when is_integer(content_length) and content_length >= 0 <-\n" <>
         "           Map.get(request, :content_length),\n" <>
         "         {:ok, declared_media_type} <-\n" <>
         "           upload_media_type(Map.get(request, :declared_media_type)),\n" <>
         "         :ok <- validate_content_length(config, content_length, declared_media_type) do\n",
       "      {:ok,\n       %{\n         grant_id: grant_id,\n",
       "a603cd71b590d69b421a38cbf6c7dd2824272ae63d84a478141752f866548772",
       "e15350abeb0b4d466d026654c7339296a4ca3b2941bf75aab9d00cda732c0c83",
       "b6c1552b25cbca86efbbf889ae693c74306ac9d9cdccdb5132f9552c940c6e40",
       "3c54ab19fb0d4b248462735cb0e35b6242beea9610443a22c1dfd28a9fb2194d"},
      {7, "\n  defp upload_media_type(_media_type), do: {:error, :invalid}\n\n",
       "  defp validate_content_length(config, content_length) do\n",
       "  defp validate_content_length(config, content_length, media_type) do\n",
       "    max_upload_bytes =\n      Map.get(\n        config,\n",
       "5068dc9cff3ee648cacd0ccf6d324d7a32edc9fe26115a618d0d6e4b652b60f7",
       "e0d938c85db1aba96c0dbe10df05a131ba3fea93bc090fbb678ae2b55ea8ae7f",
       "e369b9d7df511cdb6ba06218559ba9ca1f539eb2390b9735efd2dafbe8f9f561",
       "c8fb7da28000d12b5906097321b7acae615a59985ba2f8782ca7e2917c68a526"},
      {8,
       "      not is_integer(max_upload_bytes) or max_upload_bytes < 0 ->\n" <>
         "        {:error, :invalid}\n\n", "      content_length > max_upload_bytes ->\n",
       "      content_length > max_upload_bytes or\n" <>
         "          (media_type in @text_media_types and content_length > @text_max_bytes) ->\n",
       "        {:error, :upload_too_large}\n\n      true ->\n",
       "f4ccbc1abf5f4b8286d6a4ba90cea87dad99e91c75318b6b5d22a581f173d4e5",
       "d2513a64e43ed82c413d61474b9e634ac958642958531b3a6f29741b081de638",
       "b0158803336248d525a6048240db623a8b4503e5ea6a60109490818cda472e6f",
       "cdf86a2f652014e52b0d96f4cce1e904df3e728039fe0883b375573d7a02c243"},
      {9,
       "  end\n\n  defp internal_upload_grant(descriptor, selector) when is_map(descriptor) do\n",
       "    if credential_fields_absent?(descriptor) do\n",
       "    if credential_fields_absent?(descriptor) and public_upload_fields(descriptor) == :ok do\n",
       "      grant =\n        Map.merge(\n          descriptor,\n",
       "d674bc525fcbae6eab150f27ba62933887e7eccbc139a726aa4a8cd200e8b038",
       "a5716f0134fb4731843c7458d2b0af49c1c2730f67e04bb5c6d02d072b4119ee",
       "640e19c17fbc20007f49c821546869a391f1616978039cc5df9b0a1dab75142d",
       "4c564f1db34dda0c0da69247214d9fd50a090396820d08b2973113aa05e3a73d"},
      {10,
       "          selector.grant_id and\n          grant.session_id == selector.session_id and\n" <>
         "          grant.principal_id == selector.principal_id and\n",
       "          grant.vault_id == selector.vault_id\n",
       "          grant.vault_id == selector.vault_id and\n" <>
         "          Map.get(grant, :byte_size) == selector.request_content_length and\n" <>
         "          Map.get(grant, :declared_media_type) == selector.request_declared_media_type\n",
       "\n      if exact?, do: {:ok, grant}, else: {:error, :integrity_failure}\n    else\n",
       "8be90fa1c62d8dd4fa3cc350c4d26ece720327a137579caddf01d179d2beeb4b",
       "cdb8eeff58cf2b76c2f0ca948262e5a814cc00139d4c29346dbb8ff829c63410",
       "7bd5f81f20003d0604911b0894f74b25a1044933a8b2ba7ac56e0f8895bedace",
       "a2c11a49c063696f50c071fb7859fff47a88966b57fb504d2dac430425eb4416"},
      {11,
       "  defp internal_upload_grant(_descriptor, _selector),\n" <>
         "    do: {:error, :integrity_failure}\n\n", "",
       "  defp public_upload_fields(value) do\n" <>
         "    if Enum.any?(\n" <>
         "         [:text_validation_version, \"text_validation_version\", :metadata, \"metadata\"],\n" <>
         "         &Map.has_key?(value, &1)\n" <>
         "       ),\n" <>
         "       do: {:error, :invalid},\n" <>
         "       else: :ok\n" <>
         "  end\n\n",
       "  defp upload_identity(%{vault_id: vault_id, asset_id: asset_id}) do\n" <>
         "    if valid_uuid?(vault_id) and valid_uuid?(asset_id),\n" <>
         "      do: {:ok, vault_id, asset_id},\n",
       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
       "f26aef2a5342cf4f1cff02515c5a3397f1c10ca159b916a1ee77ed8581dc9cff",
       "e4e1e48decac6d0243c371b66148fe8abb2732406a6aee6a0516e0f47599f856",
       "38528d15cb36960d6210e05947001b1f82679f101a2c4e7b4aebbda9897b1d5d"}
    ]
  end

  defp assert_native_text_hunk!(source, hunk) do
    {id, before, old, new, after_bytes, old_hash, new_hash, old_context_hash, new_context_hash} =
      hunk

    assert_digest!(@api <> " native-text #{id} old", old, old_hash)
    assert_digest!(@api <> " native-text #{id} new", new, new_hash)

    assert_digest!(
      @api <> " native-text #{id} old context",
      before <> old <> after_bytes,
      old_context_hash
    )

    assert_digest!(
      @api <> " native-text #{id} new context",
      before <> new <> after_bytes,
      new_context_hash
    )

    assert [prefix, suffix] = String.split(source, before <> new <> after_bytes)
    {before, old, new, after_bytes, prefix, suffix}
  end

  defp native_text_mutation!(source, hunk, mutation) do
    {before, old, new, after_bytes, prefix, suffix} = assert_native_text_hunk!(source, hunk)
    context = before <> new <> after_bytes

    replacement =
      case mutation do
        :altered ->
          altered =
            String.replace(new, "\n", " # unauthorized native-text bytes\n", global: false)

          refute altered == new
          before <> altered <> after_bytes

        :removed ->
          before <> after_bytes

        :reverted ->
          before <> old <> after_bytes

        :duplicate ->
          before <> new <> new <> after_bytes

        :relocated ->
          before <> old <> after_bytes

        :before ->
          before <> "  # changed preceding context\n" <> new <> after_bytes

        :after ->
          before <> new <> "  # changed following context\n" <> after_bytes
      end

    refute replacement == context
    changed = prefix <> replacement <> suffix
    assert String.replace(changed, replacement, context, global: false) == source
    assert String.starts_with?(changed, prefix)
    assert String.ends_with?(changed, suffix)

    mutated =
      if mutation == :relocated do
        destination = "  alias Singularity.Core.Error\n"
        assert [destination_prefix, destination_suffix] = String.split(changed, destination)
        relocated = destination_prefix <> destination <> new <> destination_suffix

        assert String.replace(relocated, destination <> new, destination, global: false) ==
                 changed

        assert [_, _] = String.split(relocated, destination <> new)
        refute String.contains?(relocated, context)
        relocated
      else
        changed
      end

    refute mutated == source
    mutated
  end

  test "current Phase 5 plan title selects its unchanged active authority" do
    source = read_source("docs/superpowers/plans/#{@phase5_plan}")
    section = phase5_plan_authority!(source)
    assert section =~ "Current Task10 qualification"
    refute section =~ "## Source map and parent-owned execution discipline"
  end

  for {label, heading} <- [
        {"start", "## Status, evidence and execution boundary"},
        {"end", "## Source map and parent-owned execution discipline"}
      ],
      mutation <- [
        :missing,
        :altered,
        :duplicate,
        :duplicate_outside,
        :relocated,
        :quoted,
        :commented,
        :fenced,
        :tilde_fenced,
        :indented
      ] do
    test "Phase 5 actual-plan #{label} heading rejects #{mutation}" do
      source = read_source("docs/superpowers/plans/#{@phase5_plan}")
      heading = unquote(heading)
      assert [prefix, suffix] = String.split(source, heading <> "\n")

      replacement =
        case unquote(mutation) do
          :missing -> ""
          :altered -> heading <> " altered\n"
          :duplicate -> heading <> "\n" <> heading <> "\n"
          :duplicate_outside -> heading <> "\n"
          :relocated -> ""
          :quoted -> "> " <> heading <> "\n"
          :commented -> "<!--\n" <> heading <> "\n"
          :fenced -> "```\n" <> heading <> "\n"
          :tilde_fenced -> "~~~\n" <> heading <> "\n"
          :indented -> "    " <> heading <> "\n"
        end

      replaced = prefix <> replacement <> suffix
      assert String.starts_with?(replaced, prefix)
      assert String.ends_with?(replaced, suffix)

      mutated =
        case unquote(mutation) do
          :duplicate_outside ->
            assert replaced == source
            outside = replaced <> "\n" <> heading <> "\n"
            assert [_, _, _] = String.split(outside, heading <> "\n")
            outside

          :relocated ->
            refute String.contains?(replaced, heading <> "\n")
            heading <> "\n" <> replaced

          :commented ->
            replaced <> "\n-->\n"

          :fenced ->
            replaced <> "\n```\n"

          :tilde_fenced ->
            replaced <> "\n~~~\n"

          _ ->
            replaced
        end

      refute mutated == source

      assert_raise ExUnit.AssertionError, fn ->
        phase5_plan_authority!(mutated)
      end
    end
  end

  test "Phase 5 actual-plan authority rejects reversed boundary order" do
    source = read_source("docs/superpowers/plans/#{@phase5_plan}")
    start = "## Status, evidence and execution boundary\n"
    finish = "## Source map and parent-owned execution discipline\n"
    assert [prefix, rest] = String.split(source, start)
    assert [body, suffix] = String.split(rest, finish)
    mutated = prefix <> finish <> body <> start <> suffix
    refute mutated == source
    assert [^prefix, ^suffix] = String.split(mutated, finish <> body <> start)

    assert_raise ExUnit.AssertionError, fn -> phase5_plan_authority!(mutated) end
  end

  for {label, anchor} <- [
        {"first", "## Status, evidence and execution boundary\n"},
        {"second", "## Source map and parent-owned execution discipline\n"}
      ] do
    test "Phase 5 actual-plan authority boundaries must be the #{label} level-two heading" do
      source = read_source("docs/superpowers/plans/#{@phase5_plan}")
      anchor = unquote(anchor)
      assert [prefix, suffix] = String.split(source, anchor)
      insertion = "## Unauthorized intervening authority\n\n"
      mutated = prefix <> insertion <> anchor <> suffix
      refute mutated == source
      assert [^prefix, ^suffix] = String.split(mutated, insertion <> anchor)

      assert_raise ExUnit.AssertionError, fn -> phase5_plan_authority!(mutated) end
    end
  end

  for {label, raw} <- [
        {"qualified source and handoff",
         "`5f7e6363be534dbfb4dfa1475538fddcbd29cf32`. Phase 4's tested implementation\n" <>
           "source is `42c01a5c99b1df3d1e4284d277c6ea48046875cb`; the handoff is not a\n" <>
           "new implementation qualification. Preserve main, other worktrees and unrelated\n" <>
           "untracked files. The design and acceptance report are coordinator-owned.\n"},
        {"frozen semantics and publication prohibition",
         "small local commits after review. It does not permit Vault feature work,\n" <>
           "custody/key/capability/policy/crypto semantic changes, merge, push, version\n" <>
           "bump, tag, release, deployment, production activation or production backfill.\n"},
        {"production writes prohibition",
         "New canonical writes remain unavailable to production runtime roles.\n"},
        {"qualified default V3 and explicit V2 closed guard",
         "New backups use logical V3 after combined writer and restore qualification.\n" <>
           "Explicit V2 retains its fail-closed unsupported-canonical guard.\n"},
        {"manual E2E and final acceptance",
         "No browser/archive UI is added. E2E is manual-only **NOT RUN**, explicitly\n" <>
           "deferred for local phase advancement; final browser/release acceptance remains\n" <>
           "required. All other required gates and actual independent review must pass.\n"}
      ],
      mutation <- [:outside, :quoted, :commented, :fenced, :indented] do
    test "Phase 5 actual-plan #{label} must remain active prose: #{mutation}" do
      source = read_source("docs/superpowers/plans/#{@phase5_plan}")
      raw = unquote(raw)
      assert [prefix, suffix] = String.split(source, raw)

      replacement =
        case unquote(mutation) do
          :outside -> ""
          :quoted -> "> " <> raw
          :commented -> "<!--\n" <> raw <> "-->\n"
          :fenced -> "```text\n" <> raw <> "```\n"
          :indented -> "    " <> String.replace(raw, "\n", "\n    ") <> "\n"
        end

      refute replacement == raw
      replaced = prefix <> replacement <> suffix
      assert String.starts_with?(replaced, prefix)
      assert String.ends_with?(replaced, suffix)

      mutated =
        if unquote(mutation) == :outside do
          refute String.contains?(replaced, raw)
          moved = replaced <> "\n" <> raw
          assert [_, _] = String.split(moved, raw)
          assert String.starts_with?(moved, replaced)
          moved
        else
          assert [^prefix, ^suffix] = String.split(replaced, replacement)
          replaced
        end

      refute mutated == source

      assert_raise ExUnit.AssertionError, fn -> phase5_plan_authority!(mutated) end
    end
  end

  # Only the current Phase 5 plan uses complete heading and active-prose boundaries.
  defp phase5_plan_authority!(source) do
    start = "## Status, evidence and execution boundary"
    finish = "## Source map and parent-owned execution discipline"
    headings = Regex.scan(~r/^## .+$/m, source) |> List.flatten()
    assert [^start, ^finish | _] = headings
    assert [prefix, rest] = String.split(source, start <> "\n")
    assert [section, _suffix] = String.split(rest, finish <> "\n")

    assert String.starts_with?(
             prefix,
             "# Singularity v0.2 Phase 5 Export and Backup Implementation Plan\n"
           )

    for marker <- ["**Goal:**", "**Architecture:**", "**Tech Stack:**"] do
      assert prefix =~ marker
    end

    refute prefix =~ ~r/```|~~~|<!--|-->/
    refute section =~ ~r/```|~~~|<!--|-->|^ {0,3}>|^(?: {4,}| {0,3}\t)\S/m
    section = section |> String.replace(~r/\s+/, " ") |> String.trim()

    for marker <- [
          @phase4,
          @phase4_handoff,
          "New canonical writes remain unavailable to production runtime roles.",
          "E2E",
          "manual-only",
          "NOT RUN",
          "final browser/release acceptance",
          "New backups use logical V3 after combined writer and restore qualification. Explicit V2 retains its fail-closed unsupported-canonical guard.",
          "It does not permit Vault feature work, custody/key/capability/policy/crypto semantic changes, merge, push, version bump, tag, release, deployment, production activation or production backfill."
        ] do
      assert section =~ marker
    end

    section
  end

  # BEGIN Task16 strict attribution contracts (test-first window).
  test "Task16 inventory pins exactly seven additions and one separate startup replacement" do
    assert ["P5-A1", "P5-A2", "P5-A3", "P5-A4", "P5-C1", "P5-C2", "P5-C3"] ==
             Enum.map(phase5_additions(), &elem(&1, 0))

    for tuple <- phase5_additions(),
        do: assert_phase5_addition!(read_source(elem(tuple, 1)), tuple)

    assert_phase5_startup!(read_source(@application))
  end

  for id <- ["P5-A1", "P5-A2", "P5-A3", "P5-A4", "P5-C1", "P5-C2", "P5-C3"],
      mutation <- [:missing, :duplicate, :altered, :relocated] do
    test "Task16 #{id} strict attribution rejects #{mutation}" do
      tuple = Enum.find(phase5_additions(), &(elem(&1, 0) == unquote(id)))
      path = elem(tuple, 1)
      mutated = phase5_addition_mutation!(read_source(path), tuple, unquote(mutation))

      assert_raise ExUnit.AssertionError, fn -> strip_phase5_additions!(path, mutated) end
    end
  end

  for mutation <- [
        :missing,
        :duplicate,
        :module,
        :function,
        :children,
        :options,
        :boolean,
        :old_only,
        :coexisting,
        :relocated,
        :before,
        :after
      ] do
    test "Task16 startup replacement rejects #{mutation}" do
      mutated = phase5_startup_mutation!(read_source(@application), unquote(mutation))
      assert_raise ExUnit.AssertionError, fn -> strip_phase5_additions!(@application, mutated) end
    end
  end

  test "Task16 staging recovers the same fixed pre-native API input" do
    staged = strip_phase5_additions!(@api, read_source(@api))
    assert_phase5_absent!(@api, staged)

    assert_digest!(
      @api <> " accepted native-text source",
      staged,
      "8557685c2415c5ee3b30e33be6dfaab6e4ee25b0772bb3123a92384a914c33b4"
    )

    Enum.each(native_text_hunks(), &assert_native_text_hunk!(staged, &1))
  end

  test "Task16 staging precedes one Task8 inverse with unchanged fixed output" do
    raw = read_source(@application)
    Enum.each(phase5_task8_replacements(), &assert_task8_tuple!(raw, &1))
    staged = strip_phase5_additions!(@application, raw)
    assert_phase5_absent!(@application, staged)

    assert_digest!(
      @application <> " Task8 inverse",
      undo_phase5_task8!(@application, staged),
      "4deda19432de3174c2f737216c8185e3cdea8bb91d3960475308a27558bdfbca"
    )
  end

  for {path, expected} <- [
        {"config/dev.exs", "b028676aba7578fad1e217fbecc94c0aad66610c671eeec1220d1808b3d6c8d0"},
        {"config/test.exs", "587ad6ff1dadd4cd3efe69a8dd485b26c9f28175e6a19edb565ae11c857e0ea2"},
        {"config/runtime.exs", "1847759a3e3461681f5e832cb4b9e35cfb1ae0217665afd7c60b375128fa55ca"}
      ] do
    test "Task16 config staging recovers the fixed #{path} parent" do
      path = unquote(path)
      staged = strip_phase5_additions!(path, read_source(path))
      assert_phase5_absent!(path, staged)
      assert_digest!(path, staged, unquote(expected))
    end
  end

  for boundary <- [:api_native, :application_task8],
      mutation <- [:missing, :duplicate, :altered, :relocated] do
    test "Task16 #{boundary} positive input boundary rejects #{mutation}" do
      {path, mutated} =
        case unquote(boundary) do
          :api_native ->
            tuple = Enum.find(phase5_additions(), &(elem(&1, 0) == "P5-A2"))
            {@api, phase5_addition_mutation!(read_source(@api), tuple, unquote(mutation))}

          :application_task8 ->
            {@application, phase5_startup_mutation!(read_source(@application), unquote(mutation))}
        end

      assert_raise ExUnit.AssertionError, fn -> strip_phase5_additions!(path, mutated) end
    end
  end

  for id <- 1..11 do
    test "native-text hunk #{id} retained mutations pass Task16 staging before native rejection" do
      source = read_source(@api)
      hunk = Enum.at(native_text_hunks(), unquote(id) - 1)

      for mutation <- [:altered, :removed, :reverted, :duplicate, :relocated, :before, :after] do
        mutated = native_text_mutation!(source, hunk, mutation)
        staged = strip_phase5_additions!(@api, mutated)
        assert_phase5_absent!(@api, staged)
        assert_raise ExUnit.AssertionError, fn -> assert_native_text_hunk!(staged, hunk) end

        assert_raise ExUnit.AssertionError, fn ->
          assert_runtime_baseline!(@api, mutated, @runtime_baselines[@api])
        end
      end
    end
  end

  test "unrelated native legacy-byte counterproof reaches its fixed historical digest" do
    source = read_source(@api)
    original = "  The sole application-facing runtime facade.\n"
    replacement = "  The unauthorized application-facing runtime facade.\n"
    assert [prefix, suffix] = String.split(source, original)
    mutated = prefix <> replacement <> suffix
    staged = strip_phase5_additions!(@api, mutated)
    assert_phase5_absent!(@api, staged)
    Enum.each(native_text_hunks(), &assert_native_text_hunk!(staged, &1))

    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_runtime_baseline!(@api, mutated, @runtime_baselines[@api])
      end

    assert String.starts_with?(error.message, @api <> " changed from accepted baseline")
  end

  test "portable export public registration has exactly the approved names and arities" do
    expected = [
      export_knowledge: 2,
      export_knowledge: 3,
      knowledge_export_entries: 3,
      knowledge_export_entries: 4,
      read_knowledge_export_chunk: 4,
      read_knowledge_export_chunk: 5,
      close_knowledge_export: 2,
      close_knowledge_export: 3
    ]

    actual =
      Singularity.Runtime.Api.__info__(:functions)
      |> Enum.filter(fn {name, _arity} -> phase5_export_name?(name) end)

    assert Enum.sort(actual) == Enum.sort(expected)
  end

  test "portable export AST registration matches only exact reviewed block references" do
    for path <- [@api, @application, "config/dev.exs", "config/test.exs", "config/runtime.exs"] do
      assert_phase5_registration!(path, read_source(path))
    end
  end

  for {label, addition} <- [
        {"unknown operation", "  def unknown_knowledge_export(value), do: value\n"},
        {"extra existing-name clause",
         "  def export_knowledge(:unapproved, _options), do: {:error, :invalid}\n"},
        {"foreign qualified callback",
         "  defp unapproved_callback(value), do: KnowledgeExport.unapproved(value)\n"},
        {"documentation-hidden operation",
         "  @doc \"portable export\"\n  def unknown_knowledge_export(value), do: value\n"}
      ] do
    test "portable export AST and historical bytes reject #{label}" do
      source = read_source(@api)
      assert_phase5_registration!(@api, source)
      mutated = phase5_append_module_code!(source, unquote(addition))
      assert_raise ExUnit.AssertionError, fn -> assert_phase5_registration!(@api, mutated) end
      staged = strip_phase5_additions!(@api, mutated)
      assert_phase5_absent!(@api, staged)
      Enum.each(native_text_hunks(), &assert_native_text_hunk!(staged, &1))

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_runtime_baseline!(@api, mutated, @runtime_baselines[@api])
        end

      assert String.starts_with?(error.message, @api <> " changed from accepted baseline")
    end
  end

  test "unknown export callbacks cannot hide beside an approved callback" do
    source = read_source(@api)
    anchor = "      finish_upload: &UploadSession.finish/1,\n"
    assert [prefix, suffix] = String.split(source, anchor)
    addition = "      unknown_knowledge_export: &KnowledgeExport.run(runtime, &1, &2),\n"
    mutated = prefix <> addition <> anchor <> suffix
    assert [_, _] = String.split(mutated, addition)
    assert_raise ExUnit.AssertionError, fn -> assert_phase5_registration!(@api, mutated) end

    # Inserting next to A3 changes its exact following context; the strict
    # stripper itself must reject rather than treating it as an absent block.
    assert_raise ExUnit.AssertionError, fn -> strip_phase5_additions!(@api, mutated) end
  end

  for {label, addition} <- [
        {"foreign native startup",
         "  defp foreign_start, do: Singularity.Runtime.Knowledge.ExportArtifact.start_runtime([], [], false)\n"},
        {"extra startup clause",
         "  @doc false\n  def application_children(:unapproved), do: []\n"}
      ] do
    test "unapproved #{label} retains its historical byte rejection" do
      mutated = phase5_append_module_code!(read_source(@application), unquote(addition))
      staged = strip_phase5_additions!(@application, mutated)
      assert_phase5_absent!(@application, staged)
      Enum.each(phase5_task8_replacements(), &assert_task8_tuple!(staged, &1))

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_runtime_baseline!(@application, mutated, @runtime_baselines[@application])
        end

      assert String.starts_with?(error.message, @application <> " changed from accepted baseline")
    end
  end

  test "export AST documentation filtering cannot hide adjacent executable code" do
    source = read_source(@api)

    documented =
      phase5_append_module_code!(
        source,
        "  @doc \"knowledge export\"\n  def identity(value), do: value\n"
      )

    assert_phase5_registration!(@api, documented)

    hidden =
      phase5_append_module_code!(
        source,
        "  @moduledoc \"knowledge export\"\n  @doc \"knowledge export\"\n" <>
          "  def unknown_knowledge_export(value), do: value\n"
      )

    assert_raise ExUnit.AssertionError, fn -> assert_phase5_registration!(@api, hidden) end
  end

  defp strip_phase5_additions!(path, source) do
    source = undo_phase5_startup!(path, source)

    Enum.reduce(phase5_additions(), source, fn
      {id, ^path, preceding, addition, following, block_hash, context_hash, _destination},
      remaining ->
        assert [_, _] = String.split(remaining, addition)
        assert_digest!(path <> id <> " addition", addition, block_hash)
        context = preceding <> addition <> following
        assert [_, _] = String.split(remaining, context)
        assert_digest!(path <> id <> " context", context, context_hash)
        strip_unique!(remaining, addition)

      _other, remaining ->
        remaining
    end)
  end

  defp undo_phase5_startup!(@application = path, source) do
    {before, old, new, after_bytes, old_hash, new_hash, old_context_hash, new_context_hash} =
      phase5_startup_replacement()

    assert_digest!(path <> " P5-A5 old", old, old_hash)
    assert_digest!(path <> " P5-A5 new", new, new_hash)
    assert_digest!(path <> " P5-A5 old context", before <> old <> after_bytes, old_context_hash)
    context = before <> new <> after_bytes
    assert_digest!(path <> " P5-A5 new context", context, new_context_hash)
    assert [_, _] = String.split(source, new)
    refute String.contains?(source, old)
    assert [prefix, suffix] = String.split(source, context)
    prefix <> before <> old <> after_bytes <> suffix
  end

  defp undo_phase5_startup!(_path, source), do: source

  defp assert_phase5_absent!(path, source) do
    for {_id, ^path, _before, addition, _after, _hash, _context_hash, _destination} <-
          phase5_additions() do
      refute String.contains?(source, addition)
    end

    if path == @application do
      {before, old, new, after_bytes, _, _, _, _} = phase5_startup_replacement()
      refute String.contains?(source, new)
      assert [_, _] = String.split(source, before <> old <> after_bytes)
    end
  end

  defp assert_phase5_addition!(source, tuple) do
    {id, path, before, addition, after_bytes, hash, context_hash, destination} = tuple
    assert_digest!(path <> id <> " addition", addition, hash)
    context = before <> addition <> after_bytes
    assert_digest!(path <> id <> " context", context, context_hash)
    assert [_, _] = String.split(source, addition)
    assert [prefix, suffix] = String.split(source, context)
    assert [_, _] = String.split(source, destination)
    {before, addition, after_bytes, destination, prefix, suffix}
  end

  defp phase5_addition_mutation!(source, tuple, mutation) do
    {before, addition, after_bytes, destination, prefix, suffix} =
      assert_phase5_addition!(source, tuple)

    context = before <> addition <> after_bytes

    changed =
      case mutation do
        :missing ->
          prefix <> before <> after_bytes <> suffix

        :duplicate ->
          prefix <> before <> addition <> addition <> after_bytes <> suffix

        :altered ->
          altered =
            String.replace(addition, "\n", " # unauthorized Task16 bytes\n", global: false)

          refute altered == addition
          prefix <> before <> altered <> after_bytes <> suffix

        :relocated ->
          removed = prefix <> before <> after_bytes <> suffix
          assert [destination_prefix, destination_suffix] = String.split(removed, destination)
          relocated = destination_prefix <> destination <> addition <> destination_suffix
          assert [_, _] = String.split(relocated, destination <> addition)
          assert [_, _] = String.split(relocated, before <> after_bytes)
          refute String.contains?(relocated, context)
          relocated
      end

    refute changed == source
    changed
  end

  defp assert_phase5_startup!(source) do
    {before, old, new, after_bytes, old_hash, new_hash, old_context_hash, new_context_hash} =
      phase5_startup_replacement()

    assert_digest!(@application <> " P5-A5 old", old, old_hash)
    assert_digest!(@application <> " P5-A5 new", new, new_hash)

    assert_digest!(
      @application <> " P5-A5 old context",
      before <> old <> after_bytes,
      old_context_hash
    )

    context = before <> new <> after_bytes
    assert_digest!(@application <> " P5-A5 new context", context, new_context_hash)
    assert [_, _] = String.split(source, new)
    refute String.contains?(source, old)
    assert [prefix, suffix] = String.split(source, context)
    {before, old, new, after_bytes, prefix, suffix}
  end

  defp phase5_startup_mutation!(source, mutation) do
    {before, old, new, after_bytes, prefix, suffix} = assert_phase5_startup!(source)
    context = before <> new <> after_bytes
    old_site = before <> old <> after_bytes

    changed =
      case mutation do
        :missing ->
          prefix <> before <> after_bytes <> suffix

        :duplicate ->
          prefix <> before <> new <> new <> after_bytes <> suffix

        :old_only ->
          prefix <> old_site <> suffix

        :coexisting ->
          prefix <> before <> new <> old <> after_bytes <> suffix

        :relocated ->
          destination = "  @doc false\n  @spec application_children(map())"
          removed = prefix <> old_site <> suffix
          assert [_, _] = String.split(removed, old_site)
          assert [destination_prefix, destination_suffix] = String.split(removed, destination)
          relocated = destination_prefix <> new <> destination <> destination_suffix
          assert String.replace(relocated, new, "", global: false) == removed
          assert [_, _] = String.split(relocated, new)
          refute String.contains?(relocated, context)
          relocated

        :before ->
          prefix <>
            before <> "    # unauthorized startup before\n" <> new <> after_bytes <> suffix

        :after ->
          prefix <> before <> new <> "    # unauthorized startup after\n" <> after_bytes <> suffix

        token_mutation
        when token_mutation in [:altered, :module, :function, :children, :options, :boolean] ->
          {token, replacement} =
            case token_mutation do
              :altered ->
                {"ExportArtifact", "UnauthorizedExportArtifact"}

              :module ->
                {"ExportArtifact", "UnauthorizedExportArtifact"}

              :function ->
                {"start_runtime", "start_runtime_unapproved"}

              :children ->
                {"      children,", "      [],"}

              :options ->
                {":one_for_one", ":one_for_all"}

              :boolean ->
                {"Application.fetch_env!(:singularity_runtime, :start_infrastructure)", "false"}
            end

          altered = String.replace(new, token, replacement, global: false)
          refute altered == new
          prefix <> before <> altered <> after_bytes <> suffix
      end

    refute changed == source
    changed
  end

  defp phase5_append_module_code!(source, addition) do
    ending = "\nend\n"
    assert String.ends_with?(source, ending)
    prefix = binary_part(source, 0, byte_size(source) - byte_size(ending))
    changed = prefix <> "\n" <> addition <> ending
    refute changed == source
    changed
  end

  defp phase5_export_name?(value),
    do:
      is_atom(value) and
        Regex.match?(~r/knowledge.*export|export.*knowledge/i, Atom.to_string(value))

  defp phase5_export_alias?(segments) do
    Enum.any?(segments, &phase5_export_name?/1) or
      (:Knowledge in segments and Enum.any?(segments, &(&1 in [:Export, :ExportArtifact])))
  end

  defp phase5_registration_terms!(source) do
    assert {:ok, ast} = Code.string_to_quoted(source)

    {_ast, terms} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{attribute, _, _}]}, found when attribute in [:doc, :moduledoc, :typedoc] ->
          {nil, found}

        {:__aliases__, _, segments} = node, found ->
          {node,
           if(phase5_export_alias?(segments), do: [{:alias, segments} | found], else: found)}

        {{:., _, [{:__aliases__, _, segments}, name]}, _, arguments} = node, found
        when is_list(arguments) ->
          term = {:qualified_call, segments, name, length(arguments)}
          {node, if(phase5_export_alias?(segments), do: [term | found], else: found)}

        {name, _, arguments} = node, found when is_atom(name) ->
          term = {:named, name, if(is_list(arguments), do: length(arguments), else: :variable)}
          {node, if(phase5_export_name?(name), do: [term | found], else: found)}

        {name, _value} = node, found when is_atom(name) ->
          {node, if(phase5_export_name?(name), do: [{:keyword, name} | found], else: found)}

        value, found when is_atom(value) ->
          {value, if(phase5_export_name?(value), do: [{:atom, value} | found], else: found)}

        node, found ->
          {node, found}
      end)

    Enum.sort(terms)
  end

  defp assert_phase5_registration!(path, source) do
    expected =
      phase5_additions()
      |> Enum.filter(&(elem(&1, 1) == path))
      |> Enum.flat_map(fn {id, _path, _before, addition, _after, _hash, _context_hash,
                           _destination} ->
        wrapped =
          if id in ["P5-A3", "P5-A4"],
            do:
              "defmodule Approved do\n defp approved(runtime) do\n %{\n" <>
                addition <> "\n }\n end\n end\n",
            else: "defmodule Approved do\n" <> addition <> "\nend\n"

        phase5_registration_terms!(wrapped)
      end)

    expected =
      if path == @application,
        do:
          phase5_registration_terms!(
            "defmodule Approved do\n" <> elem(phase5_startup_replacement(), 2) <> "\nend\n"
          ) ++ expected,
        else: expected

    assert phase5_registration_terms!(source) == Enum.sort(expected),
           "unapproved portable export registration found in #{path}"
  end

  defp phase5_additions do
    [
      {"P5-A1", "apps/singularity_runtime/lib/singularity/runtime/api.ex",
       "  alias Singularity.Runtime.StorageAdapter\n",
       "  alias Singularity.Runtime.Knowledge.Export, as: KnowledgeExport\n",
       "  alias Singularity.Runtime.UnlockVault\n",
       "bafbd33be306cb42c49cc94eb8ceb15e22c74cac3373d6fc0f0b982ccabee525",
       "d35cf69e969c288154f56a5cd178d98489a5d02e5af10583f835da2640bb30da",
       "  alias Singularity.Core.Error\n"},
      {"P5-A2", "apps/singularity_runtime/lib/singularity/runtime/api.ex",
       "  def export_note(_config, _session, _resource_id), do: {:error, :invalid}\n\n",
       "  def export_knowledge(session, options),\n    do: with_production(&export_knowledge(&1, session, options))\n\n  @doc false\n  def export_knowledge(config, session, options),\n    do: knowledge_export_call(config, :export_knowledge, session, [options])\n\n  def knowledge_export_entries(session, handle, cursor),\n    do: with_production(&knowledge_export_entries(&1, session, handle, cursor))\n\n  @doc false\n  def knowledge_export_entries(config, session, handle, cursor),\n    do: knowledge_export_call(config, :knowledge_export_entries, session, [handle, cursor])\n\n  def read_knowledge_export_chunk(session, handle, path, index),\n    do: with_production(&read_knowledge_export_chunk(&1, session, handle, path, index))\n\n  @doc false\n  def read_knowledge_export_chunk(config, session, handle, path, index),\n    do:\n      knowledge_export_call(config, :read_knowledge_export_chunk, session, [handle, path, index])\n\n  def close_knowledge_export(session, handle),\n    do: with_production(&close_knowledge_export(&1, session, handle))\n\n  @doc false\n  def close_knowledge_export(config, session, handle),\n    do: knowledge_export_call(config, :close_knowledge_export, session, [handle])\n\n  defp knowledge_export_call(config, operation, %Session{} = session, arguments)\n       when is_map(config) and not is_struct(config) and\n              operation in [\n                :export_knowledge,\n                :knowledge_export_entries,\n                :read_knowledge_export_chunk,\n                :close_knowledge_export\n              ] do\n    with :ok <- KnowledgeExport.validate(operation, arguments),\n         {:ok, context} <- note_source_session(session) do\n      config\n      |> invoke(operation, [context | arguments])\n      |> KnowledgeExport.public_result(operation)\n      |> normalize_knowledge_export_result()\n    else\n      result -> normalize_error(result)\n    end\n  end\n\n  defp knowledge_export_call(_config, _operation, _session, _arguments),\n    do: {:error, :invalid}\n\n  defp normalize_knowledge_export_result(:ok), do: :ok\n  defp normalize_knowledge_export_result({:ok, _} = result), do: result\n  defp normalize_knowledge_export_result(result), do: normalize_error(result)\n\n",
       "  @spec create_note(Session.t(), map() | keyword()) ::\n",
       "1cfcdcb92693b92b2409afabe85319f60966dfbf00adb7765eae4a4a014d2b7f",
       "cc309bdb2211654f4e571a914dd5e12f790d6a66b58b5fc8b6daf97c9ed5f11a",
       "  @spec login(map()) :: {:ok, String.t(), Session.t()} | {:error, atom()}\n"},
      {"P5-A3", "apps/singularity_runtime/lib/singularity/runtime/api.ex",
       "      export_note: fn session, resource_id ->\n        NoteExportReader.run(runtime, session, resource_id)\n      end,\n",
       "      export_knowledge: &KnowledgeExport.run(runtime, &1, &2),\n      knowledge_export_entries: &KnowledgeExport.entries(runtime, &1, &2, &3),\n      read_knowledge_export_chunk: &KnowledgeExport.read_chunk(runtime, &1, &2, &3, &4),\n      close_knowledge_export: &KnowledgeExport.close(runtime, &1, &2),\n",
       "      finish_upload: &UploadSession.finish/1,\n",
       "3bd6d3d4cf89fa5ca6f8f0f6d3a6b3ce9aefe20eae016d133f0ec9d470df7767",
       "84f7d773db76740d8cd33772f8ae2936ca01590e9ba5102808df0a9c9a211275",
       "      list_assets: fn session, params ->\n"},
      {"P5-A4", "apps/singularity_runtime/lib/singularity/runtime/api.ex",
       "      key_wrapper: KeyWrapper,\n",
       "      knowledge_export: KnowledgeExport.configuration(),\n",
       "      note_repository: NoteRepository,\n",
       "4a0c358b71f8262563abe79f3235339699348472e1179603c223a6add01acadd",
       "7a29bb7d9a9145cec7538b412ee8d082a76276066406c9e7a924f82d48b24813",
       "      assets: AssetRepository,\n"},
      {"P5-C1", "config/dev.exs", "      Path.expand(\"../var/storage\", __DIR__)\n    )\n\n",
       "export_backup_root =\n  System.get_env(\"SINGULARITY_BACKUP_ROOT\", Path.expand(\"../var/backups\", __DIR__))\n\nconfig :singularity_runtime,\n  knowledge_export_root:\n    System.get_env(\n      \"SINGULARITY_EXPORT_ROOT\",\n      Path.join(\n        Path.dirname(export_backup_root),\n        Path.basename(export_backup_root) <> \"-knowledge-export\"\n      )\n    )\n\n",
       "config :singularity_storage, Singularity.Storage.MigrationRepo,\n",
       "d00f70903d73f1238d0c7f7f062db307bbf778d0708ff5a29c9bf280ce45257a",
       "e04b97ef27cd4bee396b4667422b481a66ae86aa34eb4bf06594048a6eeec67c", "import Config\n"},
      {"P5-C2", "config/test.exs",
       "  storage_root: Path.join([System.tmp_dir!(), \"singularity\", \"test\", test_run_id])\n\n",
       "config :singularity_runtime,\n  knowledge_export_root:\n    Path.join([System.tmp_dir!(), \"singularity-knowledge-export\", \"test\", test_run_id])\n\n",
       "config :singularity_runtime,\n  start_infrastructure: false,\n",
       "bcfc6c807c63982522bd2294aacca2758f1531382bf4843f6f732af2d8d0f298",
       "f46a458f657f53d3dea0f8d42891eef4c6c78188f54ceabb6920506e0bb62a00", "import Config\n"},
      {"P5-C3", "config/runtime.exs",
       "  storage_root = System.fetch_env!(\"SINGULARITY_STORAGE_ROOT\")\n\n",
       "  config :singularity_runtime,\n    knowledge_export_root:\n      System.get_env(\n        \"SINGULARITY_EXPORT_ROOT\",\n        Path.join(Path.dirname(backup_root), Path.basename(backup_root) <> \"-knowledge-export\")\n      )\n\n",
       "  audit_fingerprint_secret =\n",
       "8e04ee2d4050d7f13b1725c5106e3c365f0c8416464a4b45b0208f075530e099",
       "4bd5f62e207938b44857bf2ba76e0368cfadb62acbf4b6868d5c638eb22db621", "import Config\n"}
    ]
  end

  defp phase5_startup_replacement do
    {"    children = application_children(composition())\n\n",
     "    Supervisor.start_link(children,\n      strategy: :one_for_one,\n      name: Singularity.Runtime.Supervisor\n    )\n",
     "    Singularity.Runtime.Knowledge.ExportArtifact.start_runtime(\n      children,\n      [strategy: :one_for_one, name: Singularity.Runtime.Supervisor],\n      Application.fetch_env!(:singularity_runtime, :start_infrastructure)\n    )\n",
     "  end\n\n  @doc false\n",
     "4d3a4b83c158a6934ec69ee8040001792f2aca027f0688ccc5924c5830541359",
     "6dbc92f768417e9ff94187ad848dcce494b3dd0aff7226f1173161c2be6ac275",
     "4efa62de7c4f815e083641f2e31f1d6d7cdca3a85e49c05305eb03cb22626529",
     "1ae1d3a76f2cfed98ce35885974d80a6a8188f0e5c55f9946d4ed5ad2e4e19e7"}
  end

  # END Task16 strict attribution contracts (test-first window).
end
