defmodule Singularity.Storage.KnowledgeMigrationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, MigrationTestEnvironment}
  @previous 20_260_901_000_200
  @version 20_260_906_000_100

  test "historical schema rejects Document and forward migration preserves existing Assets and Notes" do
    MigrationTestEnvironment.with_database(@previous, fn _ ->
      source = KnowledgeFixtures.source!()
      note = Singularity.Storage.NoteFixtures.note!()
      error = assert_raise Postgrex.Error, fn -> KnowledgeFixtures.document!(source) end
      assert error.postgres.constraint == "resources_kind_check"
      migrate!()
      assert %{resource_version_id: _} = KnowledgeFixtures.document!(source)

      Fixtures.with_owner(fn ->
        assert %{rows: [[version]]} =
                 query!(
                   MigrationRepo,
                   "SELECT current_version_id FROM content.resources WHERE id = $1",
                   [Ecto.UUID.dump!(note.resource_id)]
                 )

        assert version == Ecto.UUID.dump!(note.initial_version_id)
      end)

      assert %{rows: [[true, true]]} =
               query!(
                 RequestRepo,
                 "SELECT condeferrable, condeferred FROM pg_constraint WHERE conname = 'resource_versions_resource_classification_fkey'"
               )
    end)
  end

  test "preflight rejects incompatible historical Asset heads before changing constraints" do
    MigrationTestEnvironment.with_database(@previous, fn _ ->
      source = KnowledgeFixtures.source!()

      Fixtures.with_owner(fn ->
        # Deliberately corrupt only this disposable historical fixture. The released
        # migration itself and its required assertions are never modified.
        query!(
          MigrationRepo,
          "ALTER TABLE content.resources DROP CONSTRAINT resources_note_version_head_fkey"
        )

        query!(
          MigrationRepo,
          "UPDATE content.resources SET current_version_id = $1 WHERE id = $2",
          [source.resource_version_id, source.resource_id]
        )
      end)

      error = assert_raise Postgrex.Error, &migrate!/0
      assert error.postgres.constraint == "resources_document_preflight_check"

      assert %{rows: [[nil]]} =
               query!(RequestRepo, "SELECT to_regclass('content.document_versions')")

      assert %{rows: [[definition]]} =
               query!(
                 RequestRepo,
                 "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'resources_kind_check'"
               )

      refute definition =~ "document"

      assert %{rows: []} =
               query!(
                 RequestRepo,
                 "SELECT 1 FROM pg_constraint WHERE conname = 'resources_version_head_fkey'"
               )
    end)
  end

  test "Document migration refuses downgrade with a fixed forward-only error" do
    assert Code.ensure_loaded?(Singularity.Storage.Migrations.CreateDocumentAggregate)

    assert_raise Ecto.MigrationError, "Document aggregate migration is forward-only", fn ->
      apply(Singularity.Storage.Migrations.CreateDocumentAggregate, :down, [])
    end
  end

  test "preflight rejects a historical Note with a generic-only head atomically" do
    MigrationTestEnvironment.with_database(@previous, fn _ ->
      note = Singularity.Storage.NoteFixtures.note!()
      resource = Ecto.UUID.dump!(note.resource_id)

      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "ALTER TABLE content.resources DROP CONSTRAINT resources_note_version_head_fkey"
        )

        query!(
          MigrationRepo,
          "DELETE FROM content.note_search_documents WHERE resource_id = $1",
          [resource]
        )

        query!(
          MigrationRepo,
          "DELETE FROM content.note_mutation_receipts WHERE resource_id = $1",
          [resource]
        )

        query!(MigrationRepo, "DELETE FROM content.note_versions WHERE resource_id = $1", [
          resource
        ])
      end)

      error = assert_raise Postgrex.Error, &migrate!/0
      assert error.postgres.constraint == "resources_document_preflight_check"

      assert %{rows: [[nil]]} =
               query!(RequestRepo, "SELECT to_regclass('content.document_versions')")

      assert %{rows: [[definition]]} =
               query!(
                 RequestRepo,
                 "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'resources_kind_check'"
               )

      refute definition =~ "document"
    end)
  end

  defp migrate! do
    {:ok, pid} = MigrationRepo.start_link()
    options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      path =
        :singularity_storage |> :code.priv_dir() |> to_string() |> Path.join("repo/migrations")

      Ecto.Migrator.run(MigrationRepo, path, :up, to: @version, log: false)
    after
      Code.compiler_options(options)
      Supervisor.stop(pid)
    end
  end
end
