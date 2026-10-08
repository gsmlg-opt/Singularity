defmodule Singularity.Web.Architecture.KnowledgePhase1ContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @design "2026-09-22-singularity-v0.2-phase-2-import-extraction-design.md"
  @plan "2026-09-22-singularity-v0.2-phase-2-import-extraction.md"
  @phase1 "a80957da41582de40bdf586a0cba1e14644acf0a"
  @baseline "6c3e8d5afb2cc9dbf264d276796070e16aa49e55"
  @api "apps/singularity_runtime/lib/singularity/runtime/api.ex"
  @application "apps/singularity_runtime/lib/singularity/runtime/application.ex"
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
    @application => [:Documents],
    "config/config.exs" => [:document_extract]
  }

  test "active guidance authorizes only the approved Phase 2 slice" do
    for {path, start, finish} <- [
          {"AGENTS.md", "## Active release", "## Vault freeze"},
          {"README.md", "## Active `0.2.0` scope", "## Development"},
          {"docs/guide.md", "# 21. Active implementation roadmap",
           "# 22. Cross-cutting invariants"}
        ] do
      section = active_section!(path, start, finish)

      for marker <- [
            "Phase 1 is accepted locally at `#{@phase1}`.",
            "active implementation slice is Phase 2",
            "superpowers/specs/#{@design}",
            "superpowers/plans/#{@plan}",
            "Later phases still require separate approved designs and detailed plans.",
            "New canonical writes remain unavailable to production runtime roles.",
            "Public import, extraction workers, search, Note Save integration, backup V3, and browser behavior remain in their designated later phases.",
            "Version bumps, tags, releases, pushes, and deployments remain separately gated."
          ] do
        assert section =~ marker, "#{path} is missing active Phase 2 governance: #{marker}"
      end
    end
  end

  test "guide governing links and final implementation gate agree with the active slice" do
    guide = read_source("docs/guide.md")
    [header, _] = String.split(guide, "\n---\n", parts: 2)
    assert header =~ "[approved Phase 2 design](superpowers/specs/#{@design})"
    assert header =~ "[Phase 2 implementation plan](superpowers/plans/#{@plan})"

    [_, gate] = String.split(guide, "# 24. Current implementation gate\n", parts: 2)
    gate = String.replace(gate, ~r/\s+/, " ")

    for marker <- [
          "Phase 2 is the current target.",
          "approved import/extraction design and detailed implementation plan",
          "Phase 2 must finish with recorded scoped evidence, a clean worktree, the complete supported verification gate passing, and independent review.",
          "Production canonical writes remain disabled.",
          "It must not begin later phases, modify Vault functionality, bump versions, tag, publish, push, or deploy without separate authorization."
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

  test "approved Phase 2 additions preserve every original legacy composition byte" do
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

    assert_digest!(path, legacy, expected)
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

  defp assert_document_registration!(path, source) do
    assert {:ok, ast} = Code.string_to_quoted(source)
    actual = ast |> document_terms() |> Enum.uniq() |> Enum.sort()
    expected = @document_terms |> Map.get(path, []) |> Enum.sort()
    assert actual == expected, "unapproved Document registration found in #{path}"
  end

  defp read_source(path), do: @repo_root |> Path.join(path) |> File.read!()

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
