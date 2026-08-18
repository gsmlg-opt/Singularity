defmodule Singularity.Storage.NoteRlsTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.NoteFixtures
  alias Singularity.Storage.ScopedRepo

  @tables ~w(note_versions note_conflicts note_search_documents note_mutation_receipts)

  test "missing context and another vault cannot see note rows" do
    note = NoteFixtures.note_with_conflict!()
    other = NoteFixtures.note!()

    for {repo, table} <- readable_tables() do
      assert %{rows: []} = query!(repo, "SELECT vault_id FROM content.#{table}")

      assert %{rows: []} =
               ScopedRepo.transact(repo, context(other), fn scoped ->
                 query!(scoped, "SELECT vault_id FROM content.#{table} WHERE vault_id = $1", [
                   Ecto.UUID.dump!(note.vault_id)
                 ])
               end)
    end
  end

  test "nonmember and revoked member cannot see note rows" do
    note = NoteFixtures.note_with_conflict!()
    other = NoteFixtures.note!()

    for {repo, table} <- readable_tables() do
      assert %{rows: []} =
               ScopedRepo.transact(
                 repo,
                 %{principal_id: other.principal_id, vault_id: note.vault_id},
                 fn scoped ->
                   query!(scoped, "SELECT vault_id FROM content.#{table}")
                 end
               )
    end

    Fixtures.revoke_membership!(%{
      principal_id: Ecto.UUID.dump!(note.principal_id),
      vault_id: Ecto.UUID.dump!(note.vault_id)
    })

    for {repo, table} <- readable_tables() do
      assert %{rows: []} =
               ScopedRepo.transact(repo, context(note), fn scoped ->
                 query!(scoped, "SELECT vault_id FROM content.#{table}")
               end)
    end
  end

  test "active owner and table owner see exactly their vault rows" do
    note = NoteFixtures.note_with_conflict!()
    _other = NoteFixtures.note_with_conflict!()

    for {repo, table} <- readable_tables() do
      assert %{rows: [[vault_id]]} =
               ScopedRepo.transact(repo, context(note), fn scoped ->
                 query!(scoped, "SELECT DISTINCT vault_id FROM content.#{table}")
               end)

      assert Ecto.UUID.load!(vault_id) == note.vault_id
    end

    Fixtures.with_owner(fn ->
      for table <- @tables do
        assert %{rows: [[true]]} =
                 query!(
                   MigrationRepo,
                   "SELECT EXISTS (SELECT 1 FROM content.#{table} WHERE vault_id = $1)",
                   [Ecto.UUID.dump!(note.vault_id)]
                 )
      end
    end)
  end

  test "worker cannot access conflicts or receipts and cannot mutate snapshots" do
    note = NoteFixtures.note_with_conflict!()

    for table <- ~w(note_conflicts note_mutation_receipts) do
      assert_raise Postgrex.Error, fn ->
        ScopedRepo.transact(WorkerRepo, context(note), fn repo ->
          query!(repo, "SELECT 1 FROM content.#{table}")
        end)
      end
    end

    for statement <- [
          "UPDATE content.note_versions SET title = 'changed' WHERE resource_version_id = $1",
          "DELETE FROM content.note_versions WHERE resource_version_id = $1"
        ] do
      assert_raise Postgrex.Error, fn ->
        ScopedRepo.transact(WorkerRepo, context(note), fn repo ->
          query!(repo, statement, [Ecto.UUID.dump!(note.initial_version_id)])
        end)
      end
    end
  end

  defp readable_tables do
    [
      {RequestRepo, "note_versions"},
      {RequestRepo, "note_conflicts"},
      {RequestRepo, "note_search_documents"},
      {RequestRepo, "note_mutation_receipts"},
      {WorkerRepo, "note_versions"},
      {WorkerRepo, "note_search_documents"}
    ]
  end

  defp context(note), do: %{principal_id: note.principal_id, vault_id: note.vault_id}
end
