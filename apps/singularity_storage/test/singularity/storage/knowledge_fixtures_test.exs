defmodule Singularity.Storage.KnowledgeFixturesTest do
  use Singularity.Storage.DataCase, async: false

  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo}

  @tag :integration
  test "retirement selects the exact resource and owner while retaining canonical rows" do
    source = KnowledgeFixtures.source!()
    foreign_source = KnowledgeFixtures.source!()
    {target, _} = KnowledgeFixtures.ready_document!(source)
    {same_owner, _} = KnowledgeFixtures.ready_document!(source)
    {foreign_owner, _} = KnowledgeFixtures.ready_document!(foreign_source)
    documents = [target, same_owner, foreign_owner]
    before = Enum.map(documents, &snapshot!/1)
    assert Enum.all?(before, &is_nil(&1.deleted_at))

    # These run after the verification callback, keeping controls live while
    # verifying that the target's retirement did not affect either of them.
    assert :ok = KnowledgeFixtures.retire_document_on_exit!(same_owner)
    assert :ok = KnowledgeFixtures.retire_document_on_exit!(foreign_owner)

    on_exit(fn ->
      [retired, same, foreign] = after_cleanup = Enum.map(documents, &snapshot!/1)
      assert %DateTime{} = retired.deleted_at
      assert same.deleted_at == nil
      assert foreign.deleted_at == nil
      assert Enum.map(after_cleanup, & &1.canonical) == Enum.map(before, & &1.canonical)
    end)

    assert :ok = KnowledgeFixtures.retire_document_on_exit!(target)

    assert :ok =
             KnowledgeFixtures.retire_document_on_exit!(%{
               same_owner
               | vault_id: foreign_source.vault_id
             })

    assert Enum.map(documents, &snapshot!/1) == before
  end

  @tag :integration
  test "repeated retirement preserves an existing tombstone and canonical rows" do
    source = KnowledgeFixtures.source!()
    {document, _} = KnowledgeFixtures.ready_document!(source)

    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "UPDATE content.resources SET deleted_at=clock_timestamp() WHERE id=$1 AND vault_id=$2",
                 [document.resource_id, document.vault_id]
               )
    end)

    before = snapshot!(document)
    assert %DateTime{} = before.deleted_at

    on_exit(fn -> assert snapshot!(document) == before end)

    assert :ok = KnowledgeFixtures.retire_document_on_exit!(document)
    assert :ok = KnowledgeFixtures.retire_document_on_exit!(document)
    assert snapshot!(document) == before
  end

  test "registration from an unsupported process remains a visible error" do
    document = %{
      resource_id: KnowledgeFixtures.uuid(),
      vault_id: KnowledgeFixtures.uuid()
    }

    task =
      Task.async(fn ->
        assert_raise ArgumentError, ~r/only be invoked from the test process/, fn ->
          KnowledgeFixtures.retire_document_on_exit!(document)
        end
      end)

    assert %ArgumentError{} = Task.await(task)
  end

  defp snapshot!(document) do
    Fixtures.with_owner(fn ->
      assert %{rows: [[deleted_at, resource, version, typed, fragments]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT resource.deleted_at, to_jsonb(resource) - 'deleted_at',
                        to_jsonb(version), to_jsonb(document),
                        COALESCE((SELECT jsonb_agg(to_jsonb(fragment) ORDER BY fragment.ordinal)
                                  FROM content.document_fragments AS fragment
                                  WHERE fragment.resource_version_id = document.resource_version_id
                                    AND fragment.vault_id = document.vault_id), '[]'::jsonb)
                 FROM content.document_versions AS document
                 JOIN content.resource_versions AS version
                   ON version.id = document.resource_version_id AND version.vault_id = document.vault_id
                 JOIN content.resources AS resource
                   ON resource.id = document.resource_id AND resource.vault_id = document.vault_id
                 WHERE document.resource_version_id = $1 AND document.vault_id = $2
                 """,
                 [document.resource_version_id, document.vault_id]
               )

      %{
        deleted_at: deleted_at,
        canonical: %{resource: resource, version: version, document: typed, fragments: fragments}
      }
    end)
  end
end
