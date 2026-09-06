defmodule Singularity.Domains.KnowledgePortsTest do
  use ExUnit.Case, async: true

  test "canonical repository boundaries expose only approved typed operations" do
    for {module, expected} <- [
          {Singularity.Domains.Documents.Repository,
           [create_pending: 2, get_version: 3, claim: 5, complete: 2, reset_failed: 3]},
          {Singularity.Domains.KnowledgeLinks.Repository, [insert_set: 2, list_set: 3]},
          {Singularity.Domains.Tags.Repository, [resolve: 2, attach: 3, detach: 3, list: 2]},
          {Singularity.Domains.Relationships.Repository,
           [relate: 2, unrelate: 2, outgoing: 2, incoming: 2]}
        ] do
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
          {Singularity.Domains.Documents.Repository, _} ->
            assert rendered =~ "Singularity.Core.DocumentVersion.t()"

          {Singularity.Domains.KnowledgeLinks.Repository, _} ->
            assert rendered =~ "Singularity.Core.NoteSourceSet.t()"

          {Singularity.Domains.Tags.Repository, operation} when operation in [:resolve, :list] ->
            assert rendered =~ "Singularity.Core.Tag.t()"

          {Singularity.Domains.Relationships.Repository, operation} when operation != :unrelate ->
            assert rendered =~ "Singularity.Core.Relationship.t()"

          _ ->
            assert rendered =~ ":ok"
        end
      end
    end
  end
end
