defmodule Singularity.Storage.Postgres.NoteProjectionReconcilerTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.NoteFixtures
  alias Singularity.Storage.Postgres.NoteProjectionReconciler

  test "an exact projection event repairs from the current canonical head and ignores conflicts" do
    note = NoteFixtures.note_with_conflict!()

    scoped(note, fn repo ->
      corrupt_projection!(repo, note.resource_id)

      assert :ok =
               NoteProjectionReconciler.reconcile_event(
                 repo,
                 %{"resource_id" => note.resource_id},
                 note.vault_id
               )

      assert :ok =
               NoteProjectionReconciler.reconcile_event(
                 repo,
                 %{"resource_id" => note.resource_id, "conflict_id" => note.conflict_id},
                 note.vault_id
               )

      assert projection(repo, note.resource_id) == canonical_projection(repo, note.resource_id)

      assert %{rows: [[projected_version_id, "open"]]} =
               query!(
                 repo,
                 """
                 SELECT document.resource_version_id, conflict.state
                 FROM content.note_search_documents AS document
                 JOIN content.note_conflicts AS conflict
                   ON conflict.resource_id = document.resource_id
                  AND conflict.vault_id = document.vault_id
                 WHERE document.resource_id = $1
                   AND conflict.id = $2
                 """,
                 [dump(note.resource_id), dump(note.conflict_id)]
               )

      assert load(projected_version_id) == note.canonical_version_id
      refute load(projected_version_id) == note.competing_version_id
      :ok
    end)
  end

  test "projection events reject every non-exact or content-bearing payload without mutation" do
    note = NoteFixtures.note_with_conflict!()

    scoped(note, fn repo ->
      corrupt_projection!(repo, note.resource_id)
      stale = projection(repo, note.resource_id)

      for payload <- [
            %{},
            %{resource_id: note.resource_id},
            %{"resource_id" => "not-a-uuid"},
            %{"resource_id" => note.resource_id, "revision" => 2},
            %{
              "resource_id" => note.resource_id,
              "resource_version_id" => note.competing_version_id
            },
            %{"resource_id" => note.resource_id, "title" => "private title"},
            %{"resource_id" => note.resource_id, "markdown" => "# private body"},
            nil,
            ["resource_id", note.resource_id]
          ] do
        assert {:error, %Error{code: :invalid, retryable?: false}} =
                 NoteProjectionReconciler.reconcile_event(repo, payload, note.vault_id)
      end

      assert projection(repo, note.resource_id) == stale
      :ok
    end)
  end

  test "a tombstone event deletes an existing projection idempotently" do
    note = NoteFixtures.note!()

    scoped(note, fn repo ->
      assert %{num_rows: 1} =
               query!(
                 repo,
                 "UPDATE content.resources SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1",
                 [dump(note.resource_id)]
               )

      assert projection_count(repo, note.resource_id) == 1

      for _attempt <- 1..2 do
        assert :ok =
                 NoteProjectionReconciler.reconcile_event(
                   repo,
                   %{"resource_id" => note.resource_id},
                   note.vault_id
                 )

        assert projection_count(repo, note.resource_id) == 0
      end

      :ok
    end)
  end

  test "rebuild_vault repairs stale and missing live rows and removes tombstoned rows repeatedly" do
    live = NoteFixtures.note_with_conflict!()
    missing = NoteFixtures.note_with_conflict_in_context!(live)
    tombstoned = NoteFixtures.note_with_conflict_in_context!(live)

    scoped(live, fn repo ->
      corrupt_projection!(repo, live.resource_id)

      assert %{num_rows: 1} =
               query!(
                 repo,
                 "DELETE FROM content.note_search_documents WHERE resource_id = $1",
                 [dump(missing.resource_id)]
               )

      assert %{num_rows: 1} =
               query!(
                 repo,
                 "UPDATE content.resources SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1",
                 [dump(tombstoned.resource_id)]
               )

      assert projection_count(repo, tombstoned.resource_id) == 1
      assert :ok = NoteProjectionReconciler.rebuild_vault(repo, live.vault_id)

      expected = %{
        live.resource_id => canonical_projection(repo, live.resource_id),
        missing.resource_id => canonical_projection(repo, missing.resource_id)
      }

      assert projection(repo, live.resource_id) == Map.fetch!(expected, live.resource_id)
      assert projection(repo, missing.resource_id) == Map.fetch!(expected, missing.resource_id)
      assert projection_count(repo, tombstoned.resource_id) == 0

      assert projection(repo, live.resource_id).resource_version_id == live.canonical_version_id
      refute projection(repo, live.resource_id).resource_version_id == live.competing_version_id

      assert projection(repo, missing.resource_id).resource_version_id ==
               missing.canonical_version_id

      refute projection(repo, missing.resource_id).resource_version_id ==
               missing.competing_version_id

      first_rebuild = projection_rows(repo, Map.keys(expected))

      assert :ok = NoteProjectionReconciler.rebuild_vault(repo, live.vault_id)
      assert projection_rows(repo, Map.keys(expected)) == first_rebuild
      assert projection_count(repo, tombstoned.resource_id) == 0
      :ok
    end)
  end

  defp corrupt_projection!(repo, resource_id) do
    assert %{num_rows: 1} =
             query!(
               repo,
               """
               UPDATE content.note_search_documents
               SET title = 'STALE PROJECTION TITLE',
                   markdown = '# STALE PROJECTION BODY',
                   head_inserted_at = '2000-01-01 00:00:00+00',
                   updated_at = '2000-01-01 00:00:00+00'
               WHERE resource_id = $1
               """,
               [dump(resource_id)]
             )
  end

  defp canonical_projection(repo, resource_id) do
    assert %{rows: [[version_id, title, markdown, head_inserted_at]]} =
             query!(
               repo,
               """
               SELECT resource.current_version_id, note.title, note.markdown, version.inserted_at
               FROM content.resources AS resource
               JOIN content.resource_versions AS version
                 ON version.id = resource.current_version_id
                AND version.resource_id = resource.id
                AND version.vault_id = resource.vault_id
                AND version.classification = resource.classification
               JOIN content.note_versions AS note
                 ON note.resource_version_id = version.id
                AND note.resource_id = version.resource_id
                AND note.vault_id = version.vault_id
                AND note.classification = version.classification
               WHERE resource.id = $1
               """,
               [dump(resource_id)]
             )

    %{
      resource_version_id: load(version_id),
      title: title,
      markdown: markdown,
      head_inserted_at: head_inserted_at
    }
  end

  defp projection(repo, resource_id) do
    assert %{rows: [[version_id, title, markdown, head_inserted_at]]} =
             query!(
               repo,
               """
               SELECT resource_version_id, title, markdown, head_inserted_at
               FROM content.note_search_documents
               WHERE resource_id = $1
               """,
               [dump(resource_id)]
             )

    %{
      resource_version_id: load(version_id),
      title: title,
      markdown: markdown,
      head_inserted_at: head_inserted_at
    }
  end

  defp projection_rows(repo, resource_ids) do
    resource_ids
    |> Enum.sort()
    |> Enum.map(fn resource_id -> {resource_id, projection(repo, resource_id)} end)
  end

  defp projection_count(repo, resource_id) do
    assert %{rows: [[count]]} =
             query!(
               repo,
               "SELECT count(*) FROM content.note_search_documents WHERE resource_id = $1",
               [dump(resource_id)]
             )

    count
  end

  defp scoped(note, fun), do: NoteFixtures.scoped(note, RequestRepo, fun)
  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
  defp load(uuid), do: Ecto.UUID.load!(uuid)
end
