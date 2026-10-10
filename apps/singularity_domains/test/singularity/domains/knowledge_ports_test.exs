defmodule Singularity.Domains.KnowledgePortsTest do
  use ExUnit.Case, async: true

  for {module, expected} <- [
        {Singularity.Domains.Documents.Repository,
         [
           create_pending: 2,
           get_version: 3,
           claim: 6,
           complete: 3,
           reset_failed: 5,
           recover_expired: 3,
           get_live_scoped: 3,
           list_live_scoped: 3,
           fragments_live_scoped: 3,
           source_live_scoped: 3
         ]},
        {Singularity.Domains.KnowledgeLinks.Repository,
         [
           insert_set: 2,
           list_set: 3,
           select_attachment_in_scope: 4,
           select_citation_in_scope: 4,
           resolve_attachment_in_scope: 2,
           resolve_citation_in_scope: 2
         ]},
        {Singularity.Domains.Tags.Repository,
         [
           resolve: 2,
           attach: 3,
           detach: 3,
           list: 2,
           resolve_in_scope: 2,
           attach_in_scope: 3,
           detach_in_scope: 3,
           list_page_in_scope: 4,
           browse_in_scope: 4
         ]},
        {Singularity.Domains.Relationships.Repository,
         [
           relate: 2,
           unrelate: 2,
           outgoing: 2,
           incoming: 2,
           relate_in_scope: 2,
           unrelate_in_scope: 2,
           outgoing_page_in_scope: 4,
           incoming_page_in_scope: 4
         ]}
      ] do
    @repository module
    @operations expected

    test "#{inspect(module)} exposes only approved typed operations" do
      assert_boundary(@repository, @operations)
    end
  end

  test "selected source port types describe only exact owner-free reference and metadata maps" do
    module = Singularity.Domains.KnowledgeLinks.Repository
    assert Code.ensure_loaded?(module)
    assert {:ok, types} = Code.Typespec.fetch_types(module)

    expected = %{
      source_metadata:
        "source_metadata() :: %{kind: :asset | :note | :document, resource_id: Singularity.Core.Types.id(), resource_version_id: Singularity.Core.Types.id(), title: String.t(), deleted?: boolean()}",
      selected_fragment:
        "selected_fragment() :: %{fragment_id: String.t(), ordinal: non_neg_integer(), text: String.t(), locator: Singularity.Core.SourceLocator.t()}",
      resolved_attachment:
        "resolved_attachment() :: %{reference: Singularity.Core.NoteAttachmentReference.t(), source: source_metadata()}",
      resolved_citation:
        "resolved_citation() :: %{reference: Singularity.Core.NoteCitationReference.t(), source: source_metadata(), fragment: selected_fragment()}"
    }

    for {name, declaration} <- expected do
      assert {:type, definition} =
               Enum.find(types, fn {_kind, {type_name, _, _}} -> type_name == name end)

      expected_declaration = declaration |> Code.string_to_quoted!() |> Macro.to_string()

      assert definition |> Code.Typespec.type_to_quoted() |> Macro.to_string() ==
               expected_declaration
    end
  end

  defp assert_boundary(module, expected) do
    assert Code.ensure_loaded?(module)
    assert Enum.sort(module.behaviour_info(:callbacks)) == Enum.sort(expected)
    assert {:ok, callbacks} = Code.Typespec.fetch_callbacks(module)
    assert Enum.sort(Enum.map(callbacks, &elem(&1, 0))) == Enum.sort(expected)

    for {{name, _arity}, specifications} <- callbacks do
      rendered =
        Enum.map_join(
          specifications,
          "\n",
          &(Code.Typespec.spec_to_quoted(name, &1) |> Macro.to_string())
        )

      assert rendered =~ "Singularity.Core.Error.t()"

      case {module, name} do
        {Singularity.Domains.Documents.Repository, operation} ->
          success =
            case operation do
              :fragments_live_scoped ->
                "{:ok, [Singularity.Core.DocumentFragment.t()]}"

              :source_live_scoped ->
                "{:ok, map()}"

              :list_live_scoped ->
                "{:ok, %{items: [Singularity.Core.DocumentVersion.t()], next_cursor: String.t() | nil}}"

              _ ->
                "{:ok, Singularity.Core.DocumentVersion.t()}"
            end

          expected_return =
            Code.string_to_quoted!(success <> " | {:error, Singularity.Core.Error.t()}")
            |> Macro.to_string()

          for specification <- specifications do
            assert {:"::", _, [_, return]} = Code.Typespec.spec_to_quoted(name, specification)
            assert Macro.to_string(return) == expected_return
          end

        {Singularity.Domains.KnowledgeLinks.Repository, operation}
        when operation in [:insert_set, :list_set] ->
          assert rendered =~ "Singularity.Core.NoteSourceSet.t()"

        {Singularity.Domains.KnowledgeLinks.Repository, operation} ->
          success =
            case operation do
              :select_attachment_in_scope -> "Singularity.Core.NoteAttachmentReference.t()"
              :select_citation_in_scope -> "Singularity.Core.NoteCitationReference.t()"
              :resolve_attachment_in_scope -> "resolved_attachment()"
              :resolve_citation_in_scope -> "resolved_citation()"
            end

          case operation do
            :resolve_attachment_in_scope ->
              assert rendered =~ "Singularity.Core.NoteAttachmentReference.t()"

            :resolve_citation_in_scope ->
              assert rendered =~ "Singularity.Core.NoteCitationReference.t()"

            _selector ->
              assert rendered =~ "Singularity.Core.Types.id()"
          end

          expected_return =
            Code.string_to_quoted!("{:ok, #{success}} | {:error, Singularity.Core.Error.t()}")
            |> Macro.to_string()

          for specification <- specifications do
            assert {:"::", _, [_, return]} = Code.Typespec.spec_to_quoted(name, specification)
            assert Macro.to_string(return) == expected_return
          end

        {module, operation}
        when module in [
               Singularity.Domains.Tags.Repository,
               Singularity.Domains.Relationships.Repository
             ] and
               operation in [
                 :list_page_in_scope,
                 :browse_in_scope,
                 :outgoing_page_in_scope,
                 :incoming_page_in_scope
               ] ->
          assert rendered =~ "Singularity.Core.OrganizationPageQuery.t()"

          expected_return =
            Code.string_to_quoted!(
              "{:ok, Singularity.Core.OrganizationPage.t()} | {:error, Singularity.Core.Error.t()}"
            )
            |> Macro.to_string()

          for specification <- specifications do
            assert {:"::", _, [_, return]} = Code.Typespec.spec_to_quoted(name, specification)
            assert Macro.to_string(return) == expected_return
          end

        {Singularity.Domains.Tags.Repository, operation}
        when operation in [:resolve, :resolve_in_scope, :list] ->
          assert rendered =~ "Singularity.Core.Tag.t()"

        {Singularity.Domains.Relationships.Repository, operation}
        when operation not in [:unrelate, :unrelate_in_scope] ->
          assert rendered =~ "Singularity.Core.Relationship.t()"

        _ ->
          assert rendered =~ ":ok"
      end
    end
  end
end
