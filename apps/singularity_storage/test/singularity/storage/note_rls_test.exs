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

  test "receipt rows are isolated to the exact principal within one vault" do
    note = NoteFixtures.note_with_conflict!()
    other_principal_id = same_vault_principal!(note)

    other_mutation_id =
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: other_principal_id, vault_id: note.vault_id},
        fn repo -> insert_pending_receipt!(repo, note, other_principal_id) end
      )

    assert %{rows: [[owner_principal_id]]} =
             NoteFixtures.scoped(note, RequestRepo, fn repo ->
               query!(repo, "SELECT principal_id FROM content.note_mutation_receipts")
             end)

    assert Ecto.UUID.load!(owner_principal_id) == note.principal_id

    assert %{rows: [[other_principal_id_dump]]} =
             ScopedRepo.transact(
               RequestRepo,
               %{principal_id: other_principal_id, vault_id: note.vault_id},
               fn repo ->
                 query!(repo, "SELECT principal_id FROM content.note_mutation_receipts")
               end
             )

    assert Ecto.UUID.load!(other_principal_id_dump) == other_principal_id

    assert %{num_rows: 0} =
             ScopedRepo.transact(
               RequestRepo,
               %{principal_id: other_principal_id, vault_id: note.vault_id},
               fn repo ->
                 query!(
                   repo,
                   "UPDATE content.note_mutation_receipts SET request_fingerprint = $1 WHERE mutation_id = $2",
                   [
                     :crypto.hash(:sha256, "other-principal-update"),
                     Ecto.UUID.dump!(note.mutation_id)
                   ]
                 )
               end
             )

    assert_raise Postgrex.Error, fn ->
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: other_principal_id, vault_id: note.vault_id},
        fn repo -> insert_pending_receipt!(repo, note, note.principal_id) end
      )
    end

    assert Ecto.UUID.cast!(other_mutation_id)
  end

  test "missing context cannot insert or update receipts" do
    note = NoteFixtures.note_with_conflict!()

    assert_raise Postgrex.Error, fn ->
      insert_pending_receipt!(RequestRepo, note, note.principal_id)
    end

    assert %{num_rows: 0} =
             query!(
               RequestRepo,
               "UPDATE content.note_mutation_receipts SET request_fingerprint = $1 WHERE mutation_id = $2",
               [
                 :crypto.hash(:sha256, "missing-context-update"),
                 Ecto.UUID.dump!(note.mutation_id)
               ]
             )
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

  defp same_vault_principal!(note) do
    person_id = Ecto.UUID.generate()
    account_id = Ecto.UUID.generate()
    principal_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO identity.people (id, display_name) VALUES ($1, 'Receipt peer')",
        [Ecto.UUID.dump!(person_id)]
      )

      query!(MigrationRepo, "INSERT INTO identity.accounts (id, person_id) VALUES ($1, $2)", [
        Ecto.UUID.dump!(account_id),
        Ecto.UUID.dump!(person_id)
      ])

      query!(
        MigrationRepo,
        "INSERT INTO identity.principals (id, account_id, kind) VALUES ($1, $2, 'owner')",
        [
          Ecto.UUID.dump!(principal_id),
          Ecto.UUID.dump!(account_id)
        ]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.vault_members (principal_id, vault_id) VALUES ($1, $2)",
        [
          Ecto.UUID.dump!(principal_id),
          Ecto.UUID.dump!(note.vault_id)
        ]
      )
    end)

    principal_id
  end

  defp insert_pending_receipt!(repo, note, principal_id) do
    mutation_id = Ecto.UUID.generate()

    query!(
      repo,
      """
      INSERT INTO content.note_mutation_receipts (
        vault_id, principal_id, mutation_id, operation,
        request_fingerprint, state, resource_id
      ) VALUES ($1, $2, $3, 'save', $4, 'pending', $5)
      """,
      [
        Ecto.UUID.dump!(note.vault_id),
        Ecto.UUID.dump!(principal_id),
        Ecto.UUID.dump!(mutation_id),
        :crypto.hash(:sha256, "pending-receipt-#{mutation_id}"),
        Ecto.UUID.dump!(note.resource_id)
      ]
    )

    mutation_id
  end
end
