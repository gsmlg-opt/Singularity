defmodule Singularity.Web.Architecture.KnowledgePhase1ContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @design "2026-10-09-singularity-v0.2-phase-3-unified-lexical-search-design.md"
  @plan "2026-10-09-singularity-v0.2-phase-3-unified-lexical-search.md"
  @phase4_design "2026-10-11-singularity-v0.2-phase-4-knowledge-links-design.md"
  @phase4_plan "2026-10-11-singularity-v0.2-phase-4-knowledge-links.md"
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

  test "active guidance retains Phase 4 sequencing under continuous development authority" do
    for {path, start, finish} <- [
          {"AGENTS.md", "## Active release", "## Vault freeze"},
          {"README.md", "## Active `0.2.0` scope", "## Development"},
          {"docs/guide.md", "# 21. Active implementation roadmap",
           "# 22. Cross-cutting invariants"}
        ] do
      section = active_section!(path, start, finish)

      assert section =~ ~r/active implementation slice is Phase 4/,
             "#{path} does not identify Phase 4 as the active slice"

      for marker <- [
            "qualified local acceptance",
            @phase3,
            "superpowers/specs/#{@phase4_design}",
            "superpowers/plans/#{@phase4_plan}",
            "Later phases require designs, detailed plans, required verification, and independent review, without renewed routine human approval.",
            "Advance automatically only after the preceding phase's required gates pass.",
            "New canonical writes remain unavailable to production runtime roles.",
            "Public import, extraction workers, search, Note Save integration, backup V3, and browser behavior remain in their designated later phases.",
            "Version bumps, tags, releases, pushes, and deployments remain separately gated."
          ] do
        assert section =~ marker, "#{path} is missing active Phase 4 governance: #{marker}"
      end

      if path == "AGENTS.md", do: assert(section =~ @phase3_handoff)
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

    [_, gate] = String.split(guide, "# 24. Current implementation gate\n", parts: 2)
    gate = String.replace(gate, ~r/\s+/, " ")

    for marker <- [
          "Phase 4 is the current target.",
          "versioned-source design and detailed implementation plan",
          "Phase 4 must finish with recorded scoped evidence, a clean worktree, the complete permitted verification gate passing, and independent review.",
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
        assert_runtime_baseline!(path, relocated, @runtime_baselines[path])
      end
    end
  end

  test "registration and byte guards reject unauthorized Document and legacy changes" do
    for {path, expected} <- @runtime_baselines do
      source = read_source(path)
      unauthorized = source <> "\ndefmodule ExtraDocumentRegistration do; end\n"

      assert_raise ExUnit.AssertionError, fn ->
        assert_document_registration!(path, unauthorized)
      end

      for changed <- [unauthorized, source <> "\n:unrelated_legacy_change\n"] do
        assert_raise ExUnit.AssertionError, fn ->
          assert_runtime_baseline!(path, changed, expected)
        end
      end
    end
  end

  test "approved additions cannot change, disappear or be duplicated" do
    source = read_source(@api)

    for {pattern, _} <- api_additions() do
      assert [[addition]] = Regex.scan(pattern, source)

      for changed <- [
            String.replace(source, addition, addition <> "  # unapproved change\n"),
            String.replace(source, addition, ""),
            String.replace(source, addition, addition <> addition)
          ] do
        assert_raise ExUnit.AssertionError, fn ->
          assert_runtime_baseline!(@api, changed, @runtime_baselines[@api])
        end
      end
    end

    for {path, addition} <- [
          {@application, "  alias Singularity.Runtime.Documents.ExtractionReconciler\n"},
          {@application, "      ExtractionReconciler,\n"},
          {"config/config.exs", "    document_extract: 2,\n"}
        ] do
      source = read_source(path)

      for replacement <- ["", addition <> addition, String.replace(addition, "2", "3")] do
        if replacement != addition do
          assert_raise ExUnit.AssertionError, fn ->
            assert_runtime_baseline!(
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
          assert_runtime_baseline!(path, changed, @runtime_baselines[path])
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
      assert [before, rest] = String.split(source, addition)
      assert [_, _] = String.split(source, preceding <> addition <> following)

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
          assert_runtime_baseline!(path, changed, @runtime_baselines[path])
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

  defp assert_runtime_baseline!(path, source, expected) do
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
    assert [_, rest] = String.split(source, start <> "\n", parts: 2)
    assert [section, _] = String.split(rest, finish <> "\n", parts: 2)
    refute section =~ ~r/```|~~~|<!--|-->|^(?: {4,}| {0,3}\t)\S/m
    section |> String.replace(~r/\s+/, " ") |> String.trim()
  end
end
