defmodule Singularity.Storage.Postgres.NoteProjectionReconcilerTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.{Fixtures, MigrationRepo, NoteFixtures, SafeSQL}
  alias Singularity.Storage.Postgres.NoteProjectionReconciler

  test "an exact projection event repairs from the current canonical head and ignores conflicts" do
    note = NoteFixtures.note_with_conflict!()
    grant_note_write!(note)
    seed_unified!(note)

    scoped(note, fn repo ->
      corrupt_projection!(repo, note.resource_id)
      original_unified = unified_projection(repo, note.resource_id)

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.search_entries SET title='STALE UNIFIED TITLE' WHERE resource_id=$1",
          [dump(note.resource_id)]
        )
      end)

      assert :ok =
               NoteProjectionReconciler.reconcile_event(
                 repo,
                 %{"resource_id" => note.resource_id},
                 note.vault_id
               )

      assert unified_projection(repo, note.resource_id) == original_unified

      assert :ok =
               NoteProjectionReconciler.reconcile_event(
                 repo,
                 %{"resource_id" => note.resource_id, "conflict_id" => note.conflict_id},
                 note.vault_id
               )

      assert projection(repo, note.resource_id) == canonical_projection(repo, note.resource_id)

      assert unified_projection(repo, note.resource_id) ==
               canonical_projection(repo, note.resource_id)

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
    grant_note_write!(note)
    seed_unified!(note)

    scoped(note, fn repo ->
      assert %{num_rows: 1} =
               query!(
                 repo,
                 "UPDATE content.resources SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1",
                 [dump(note.resource_id)]
               )

      assert projection_count(repo, note.resource_id) == 1
      assert unified_count(repo, note.resource_id) == 1

      for _attempt <- 1..2 do
        assert :ok =
                 NoteProjectionReconciler.reconcile_event(
                   repo,
                   %{"resource_id" => note.resource_id},
                   note.vault_id
                 )

        assert projection_count(repo, note.resource_id) == 0
        assert unified_count(repo, note.resource_id) == 0
      end

      :ok
    end)
  end

  test "rebuild_vault repairs stale and missing live rows and removes tombstoned rows repeatedly" do
    live = NoteFixtures.note_with_conflict!()
    missing = NoteFixtures.note_with_conflict_in_context!(live)
    tombstoned = NoteFixtures.note_with_conflict_in_context!(live)
    seed_unified!(live)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.search_entries SET title='LEGACY REBUILD MUST NOT REPAIR THIS' WHERE resource_id=$1",
        [dump(live.resource_id)]
      )
    end)

    scoped(live, fn repo ->
      original_unified = unified_projection(repo, live.resource_id)
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
      assert unified_projection(repo, live.resource_id) == original_unified
      assert unified_count(repo, missing.resource_id) == 0
      assert unified_count(repo, tombstoned.resource_id) == 0
      :ok
    end)
  end

  test "existing worker repair reconciles both current projections with only note.write" do
    note = NoteFixtures.note_with_conflict!()
    grant_note_write!(note)

    assert :ok =
             NoteFixtures.scoped(note, WorkerRepo, fn repo ->
               corrupt_projection!(repo, note.resource_id)

               NoteProjectionReconciler.reconcile_event(
                 repo,
                 %{"resource_id" => note.resource_id},
                 note.vault_id
               )
             end)

    scoped(note, fn repo ->
      canonical = canonical_projection(repo, note.resource_id)
      assert projection(repo, note.resource_id) == canonical
      assert unified_projection(repo, note.resource_id) == canonical
      :ok
    end)
  end

  test "a unified projection failure rolls back both reconciliations" do
    note = NoteFixtures.note!()
    grant_note_write!(note)
    seed_unified!(note)
    constraint = "note_reconciler_failure_#{System.unique_integer([:positive])}"

    scoped(note, fn repo ->
      corrupt_projection!(repo, note.resource_id)
      :ok
    end)

    before =
      scoped(note, fn repo ->
        {projection(repo, note.resource_id), unified_projection(repo, note.resource_id)}
      end)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "ALTER TABLE content.search_entries ADD CONSTRAINT #{constraint} CHECK(resource_id <> '#{note.resource_id}'::uuid) NOT VALID"
      )
    end)

    try do
      assert {:error, %Error{code: :invalid, retryable?: false}} =
               scoped(note, fn repo ->
                 NoteProjectionReconciler.reconcile(repo, %{
                   vault_id: note.vault_id,
                   resource_id: note.resource_id
                 })
               end)

      assert scoped(note, fn repo ->
               {projection(repo, note.resource_id), unified_projection(repo, note.resource_id)}
             end) == before
    after
      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "ALTER TABLE content.search_entries DROP CONSTRAINT #{constraint}")
      end)
    end
  end

  test "normal reconciliation requires its owning scoped transaction" do
    note = NoteFixtures.note!()
    grant_note_write!(note)

    assert {:error, %Error{code: :invalid, retryable?: false}} =
             NoteProjectionReconciler.reconcile(RequestRepo, %{
               vault_id: note.vault_id,
               resource_id: note.resource_id
             })
  end

  test "a selector cannot override the transaction owner before either projection changes" do
    note = NoteFixtures.note!()
    grant_note_write!(note)
    %{one: foreign} = Fixtures.two_vaults!()

    scoped(note, fn repo ->
      corrupt_projection!(repo, note.resource_id)
      original = projection(repo, note.resource_id)

      assert {:error, %Error{code: :forbidden, retryable?: false}} =
               NoteProjectionReconciler.reconcile(repo, %{
                 vault_id: load(foreign.vault_id),
                 resource_id: note.resource_id
               })

      assert projection(repo, note.resource_id) == original
      assert unified_count(repo, note.resource_id) == 0
      :ok
    end)
  end

  test "competing repairs lock Resource FOR UPDATE before writing either projection" do
    note = NoteFixtures.note!()
    grant_note_write!(note)
    start_supervised!({MigrationRepo, pool_size: 2})
    parent = self()
    reference = make_ref()

    blocker =
      Task.async(fn ->
        {:ok, :ok} =
          MigrationRepo.transaction(fn ->
            query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

            query!(MigrationRepo, "SELECT id FROM content.resources WHERE id=$1 FOR UPDATE", [
              dump(note.resource_id)
            ])

            send(parent, {reference, :resource_locked})

            receive do
              {^reference, :release} -> :ok
            after
              5_000 -> raise "Note reconciler resource barrier timed out"
            end
          end)

        :ok
      end)

    try do
      assert_receive {^reference, :resource_locked}, 5_000

      repairs =
        for index <- 1..2 do
          Task.async(fn ->
            scoped(note, fn repo ->
              %{rows: [[backend]]} = SafeSQL.query!(repo, "SELECT pg_backend_pid()")
              send(parent, {reference, :repair, index, backend})

              NoteProjectionReconciler.reconcile(repo, %{
                vault_id: note.vault_id,
                resource_id: note.resource_id
              })
            end)
          end)
        end

      try do
        for index <- 1..2 do
          assert_receive {^reference, :repair, ^index, backend}, 5_000
          assert await_row_wait(backend, System.monotonic_time(:millisecond) + 4_000)

          assert %{rows: [[true, false]]} =
                   query!(
                     MigrationRepo,
                     """
                     SELECT EXISTS(SELECT FROM pg_locks AS lock
                       JOIN pg_class AS relation ON relation.oid=lock.relation
                       JOIN pg_namespace AS namespace ON namespace.oid=relation.relnamespace
                       WHERE lock.pid=$1 AND lock.locktype='tuple' AND lock.mode='AccessExclusiveLock'
                         AND namespace.nspname='content' AND relation.relname='resources'),
                       EXISTS(SELECT FROM pg_locks AS lock
                         JOIN pg_class AS relation ON relation.oid=lock.relation
                         JOIN pg_namespace AS namespace ON namespace.oid=relation.relnamespace
                         WHERE lock.pid=$1 AND lock.mode='RowExclusiveLock' AND lock.granted
                           AND namespace.nspname='content'
                           AND relation.relname IN ('note_search_documents','search_entries'))
                     """,
                     [backend]
                   )
        end

        send(blocker.pid, {reference, :release})
        assert :ok = Task.await(blocker, 5_000)
        for repair <- repairs, do: assert(:ok = Task.await(repair, 5_000))
      after
        send(blocker.pid, {reference, :release})
        drain_task(blocker)
        for repair <- repairs, do: drain_task(repair)
      end
    after
      send(blocker.pid, {reference, :release})
      drain_task(blocker)
    end

    scoped(note, fn repo ->
      canonical = canonical_projection(repo, note.resource_id)
      assert projection(repo, note.resource_id) == canonical
      assert unified_projection(repo, note.resource_id) == canonical
      :ok
    end)
  end

  defp drain_task(task) do
    if Process.alive?(task.pid) do
      Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    else
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp grant_note_write!(note) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.capabilities(id,name) VALUES($1,'note.write') ON CONFLICT(name) DO NOTHING",
        [dump(Ecto.UUID.generate())]
      )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='note.write'",
                 [dump(note.principal_id), dump(note.vault_id)]
               )
    end)
  end

  defp seed_unified!(note) do
    Fixtures.with_owner(fn ->
      assert %{rows: [[1]]} =
               query!(MigrationRepo, "SELECT content.reconcile_search_resource_internal($1,$2)", [
                 dump(note.vault_id),
                 dump(note.resource_id)
               ])
    end)
  end

  defp unified_projection(repo, resource_id) do
    assert %{rows: [[entry_id, version_id, title, markdown, inserted_at, locator]]} =
             query!(
               repo,
               "SELECT entry_id,resource_version_id,title,body,source_inserted_at,locator FROM content.search_entries WHERE resource_id=$1",
               [dump(resource_id)]
             )

    assert entry_id == "note:" <> load(version_id)
    assert locator == %{"version" => 1, "kind" => "markdown", "heading_path" => []}

    %{
      resource_version_id: load(version_id),
      title: title,
      markdown: markdown,
      head_inserted_at: inserted_at
    }
  end

  defp unified_count(repo, resource_id) do
    %{rows: [[count]]} =
      query!(repo, "SELECT count(*) FROM content.search_entries WHERE resource_id=$1", [
        dump(resource_id)
      ])

    count
  end

  defp await_row_wait(backend, deadline) do
    %{rows: [[waiting]]} =
      query!(
        MigrationRepo,
        "SELECT EXISTS(SELECT FROM pg_locks WHERE pid=$1 AND NOT granted AND locktype IN ('tuple','transactionid'))",
        [backend]
      )

    cond do
      waiting -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> await_row_wait(backend, deadline)
    end
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
