defmodule Singularity.Web.Architecture.KnowledgePhase1ContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @design "2026-09-06-singularity-v0.2-phase-1-canonical-model-design.md"
  @plan "2026-09-06-singularity-v0.2-phase-1-canonical-model.md"
  @baseline "6c3e8d5afb2cc9dbf264d276796070e16aa49e55"

  test "active guidance authorizes only the approved Phase 1 slice" do
    for {path, start, finish} <- [
          {"AGENTS.md", "## Active release", "## Vault freeze"},
          {"README.md", "## Active `0.2.0` scope", "## Development"},
          {"docs/guide.md", "# 21. Active implementation roadmap",
           "# 22. Cross-cutting invariants"}
        ] do
      section = active_section!(path, start, finish)

      for marker <- [
            "Phase 0 is accepted at `#{@baseline}`.",
            "The active implementation slice is Phase 1",
            "superpowers/specs/#{@design}",
            "superpowers/plans/#{@plan}",
            "New canonical writes remain unavailable to production runtime roles.",
            "Public import, extraction workers, search, Note Save integration, backup V3, and browser behavior remain in their designated later phases.",
            "Version bumps, tags, releases, pushes, and deployments require separate authorization."
          ] do
        assert section =~ marker, "#{path} is missing active Phase 1 governance: #{marker}"
      end
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

  test "public Document routes and job registration remain absent" do
    routes = Singularity.Web.Router.__routes__()
    assert Enum.any?(routes, &(&1.path == "/notes"))

    for route <- routes do
      refute inspect(route) =~ ~r/document|extract/i
    end

    for path <- [
          "apps/singularity_runtime/lib/singularity/runtime/api.ex",
          "apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex",
          "apps/singularity_runtime/lib/singularity/runtime/application.ex",
          "config/config.exs",
          "config/runtime.exs"
        ] do
      source = @repo_root |> Path.join(path) |> File.read!()
      assert {:ok, ast} = Code.string_to_quoted(source)

      assert document_terms(ast) == [], "public Document registration found in #{path}"
    end
  end

  test "Document function names cannot evade the registration scan" do
    assert {:ok, ast} =
             Code.string_to_quoted(
               "defmodule Example do; def import_document(input), do: input; end"
             )

    assert :import_document in document_terms(ast)
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
