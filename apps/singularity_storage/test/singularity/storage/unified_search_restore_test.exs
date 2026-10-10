defmodule Singularity.Storage.UnifiedSearchRestoreTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.{Exporter, IntegrityAudit}
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, NoteFixtures, ScopedRepo}

  test "restore-owned rebuild reconstructs exact current Note entries without live session authority" do
    %{one: owner, two: other_owner} = Fixtures.two_vaults!()
    live = NoteFixtures.note_with_conflict_in_context!(owner)
    tombstoned = NoteFixtures.note_with_conflict_in_context!(owner)
    foreign = NoteFixtures.note_with_conflict_in_context!(other_owner)

    {canonical_before, foreign_before} =
      Fixtures.with_owner(fn ->
        for note <- [tombstoned, foreign] do
          assert %{rows: [[1]]} =
                   query!(
                     MigrationRepo,
                     "SELECT content.reconcile_search_resource_internal($1,$2)",
                     [uuid(note.vault_id), uuid(note.resource_id)]
                   )
        end

        query!(MigrationRepo, "UPDATE content.resources SET deleted_at=now() WHERE id=$1", [
          uuid(tombstoned.resource_id)
        ])

        {canonical_rows(live.vault_id), search_rows(foreign.vault_id)}
      end)

    binding = %{manifest_id: Ecto.UUID.generate(), vault_id: live.vault_id}

    assert {:ok, first} =
             Fixtures.with_owner(fn ->
               assert_no_session_context!()
               IntegrityAudit.rebuild(MigrationRepo, binding)
             end)

    assert first.projection == "postgres_metadata_v1"
    assert first.document_count == 1
    assert <<_::binary-size(32)>> = first.result_sha256

    rebuilt =
      Fixtures.with_owner(fn ->
        assert canonical_rows(live.vault_id) == canonical_before
        assert search_rows(foreign.vault_id) == foreign_before

        assert [
                 [
                   entry_id,
                   "note",
                   resource_id,
                   version_id,
                   nil,
                   0,
                   "Accepted fixture note",
                   "# Accepted fixture note",
                   %{"kind" => "markdown", "version" => 1, "heading_path" => []},
                   inserted_at
                 ]
               ] = rows = search_rows(live.vault_id)

        assert entry_id == "note:" <> live.canonical_version_id
        assert resource_id == live.resource_id
        assert version_id == live.canonical_version_id

        assert %{rows: [[^inserted_at]]} =
                 query!(
                   MigrationRepo,
                   "SELECT inserted_at FROM content.resource_versions WHERE id=$1",
                   [
                     uuid(live.canonical_version_id)
                   ]
                 )

        rows
      end)

    assert {:ok, ^first} =
             Fixtures.with_owner(fn ->
               assert_no_session_context!()
               IntegrityAudit.rebuild(MigrationRepo, binding)
             end)

    Fixtures.with_owner(fn ->
      assert search_rows(live.vault_id) == rebuilt
      assert canonical_rows(live.vault_id) == canonical_before
      assert search_rows(foreign.vault_id) == foreign_before
    end)
  end

  for kind <- [:document, :tagged_note] do
    @kind kind

    test "legacy backup rejects live and tombstoned #{@kind} canonical rows" do
      source = KnowledgeFixtures.source!()

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities (id,name) VALUES ($1,'backup.create') ON CONFLICT (name) DO NOTHING",
          [KnowledgeFixtures.uuid()]
        )

        query!(
          MigrationRepo,
          "INSERT INTO core.principal_capabilities (principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='backup.create'",
          [source.principal_id, source.vault_id]
        )
      end)

      assert {:ok, _supported_cut} = backup_cut(source)
      resource = unsupported_resource!(@kind, source)

      assert {:error, %Error{code: :backup_unsupported, message: nil, details: %{}}} =
               backup_cut(source)

      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "UPDATE content.resources SET deleted_at=now() WHERE id=$1", [
          resource.resource_id
        ])
      end)

      assert {:error, %Error{code: :backup_unsupported, message: nil, details: %{}}} =
               backup_cut(source)
    end
  end

  defp backup_cut(source) do
    owner = Ecto.UUID.load!(source.vault_id)

    ScopedRepo.transact(
      WorkerRepo,
      %{principal_id: Ecto.UUID.load!(source.principal_id), vault_id: owner},
      [isolation: :repeatable_read],
      fn repo -> Exporter.snapshot_cut(repo, owner) end
    )
  end

  defp unsupported_resource!(:document, source), do: KnowledgeFixtures.document!(source)

  defp unsupported_resource!(:tagged_note, source) do
    note = KnowledgeFixtures.note!(source)
    tag_id = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.tags (id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at) VALUES ($1,$2,'private','restore guard tag','restore guard tag',$3,CURRENT_TIMESTAMP)",
        [tag_id, source.vault_id, source.principal_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_tags (resource_id,tag_id,vault_id,classification,inserted_at) VALUES ($1,$2,$3,'private',CURRENT_TIMESTAMP)",
        [note.resource_id, tag_id, source.vault_id]
      )
    end)

    note
  end

  defp assert_no_session_context! do
    assert %{rows: [[nil, nil]]} =
             query!(
               MigrationRepo,
               "SELECT NULLIF(current_setting('singularity.principal_id',true),''), NULLIF(current_setting('singularity.vault_id',true),'')",
               []
             )
  end

  defp search_rows(owner) do
    %{rows: rows} =
      query!(
        MigrationRepo,
        """
        SELECT entry_id,kind,resource_id::text,resource_version_id::text,
               fragment_id,ordinal,title,body,locator,source_inserted_at
        FROM content.search_entries WHERE vault_id=$1 ORDER BY entry_id
        """,
        [uuid(owner)]
      )

    rows
  end

  defp canonical_rows(owner) do
    for {table, order} <- [
          {"resources", "id"},
          {"resource_versions", "id"},
          {"note_versions", "resource_version_id"},
          {"note_conflicts", "id"}
        ] do
      %{rows: rows} =
        query!(
          MigrationRepo,
          "SELECT row_to_json(canonical)::text FROM content.#{table} AS canonical WHERE vault_id=$1 ORDER BY #{order}",
          [uuid(owner)]
        )

      {table, rows}
    end
  end

  defp uuid(value), do: Ecto.UUID.dump!(value)
end
