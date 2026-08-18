defmodule Singularity.Storage.Postgres.NoteMutationReceiptsTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.NoteFixtures
  alias Singularity.Storage.Postgres.NoteMutationReceipts, as: Receipts
  alias Singularity.Storage.ScopedRepo

  setup do
    {:ok, note: NoteFixtures.note!()}
  end

  test "the first claim completes and an exact replay returns only stored identifiers", %{
    note: note
  } do
    claim = claim(note)
    result = saved(note)

    assert {:ok, ^result} =
             NoteFixtures.scoped(note, RequestRepo, fn repo ->
               Receipts.with_claim(repo, claim, fn -> {:ok, result} end)
             end)

    assert {:ok, ^result} =
             NoteFixtures.scoped(note, RequestRepo, fn repo ->
               Receipts.with_claim(repo, claim, fn -> flunk("replay ran callback") end)
             end)

    NoteFixtures.scoped(note, RequestRepo, fn repo ->
      assert %{rows: [["save", fingerprint, "completed", "saved", resource_id, version_id, nil]]} =
               query!(
                 repo,
                 """
                 SELECT operation, request_fingerprint, state, outcome,
                        resource_id, version_id, conflict_id
                 FROM content.note_mutation_receipts
                 WHERE mutation_id = $1
                 """,
                 [Ecto.UUID.dump!(claim.mutation_id)]
               )

      assert fingerprint == claim.request_fingerprint
      assert Ecto.UUID.load!(resource_id) == note.resource_id
      assert Ecto.UUID.load!(version_id) == note.initial_version_id
      :ok
    end)
  end

  test "an existing key rejects operation, caller resource, and fingerprint mismatches", %{
    note: note
  } do
    claim = claim(note)
    result = saved(note)

    assert {:ok, ^result} =
             NoteFixtures.scoped(note, RequestRepo, fn repo ->
               Receipts.with_claim(repo, claim, fn -> {:ok, result} end)
             end)

    mismatches = [
      Map.put(claim, :operation, :merge),
      Map.put(claim, :resource_id, Ecto.UUID.generate()),
      Map.put(claim, :request_fingerprint, :crypto.hash(:sha256, "different"))
    ]

    for mismatch <- mismatches do
      assert {:error, %Error{code: :invalid, retryable?: false}} =
               NoteFixtures.scoped(note, RequestRepo, fn repo ->
                 Receipts.with_claim(repo, mismatch, fn -> flunk("mismatch ran callback") end)
               end)
    end
  end

  test "a failed callback rolls back pending state and a later claimant can win", %{note: note} do
    claim = claim(note)
    result = saved(note)

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             NoteFixtures.scoped(note, RequestRepo, fn repo ->
               Receipts.with_claim(repo, claim, fn ->
                 {:error, Error.new(:storage_unavailable, retryable?: true)}
               end)
             end)

    assert receipt_count(note, claim.mutation_id) == 0

    assert {:ok, ^result} =
             NoteFixtures.scoped(note, RequestRepo, fn repo ->
               Receipts.with_claim(repo, claim, fn -> {:ok, result} end)
             end)

    assert receipt_count(note, claim.mutation_id) == 1
  end

  test "a malformed callback outcome cannot commit a pending receipt", %{note: note} do
    claim = claim(note)

    assert {:error, %Error{code: :invalid}} =
             NoteFixtures.scoped(note, RequestRepo, fn repo ->
               Receipts.with_claim(repo, claim, fn ->
                 {:ok, %{outcome: "saved", resource_id: note.resource_id}}
               end)
             end)

    assert receipt_count(note, claim.mutation_id) == 0
  end

  test "a deferred result constraint is mapped before commit and rolls back pending state", %{
    note: note
  } do
    claim = claim(note)

    assert {:error, %Error{code: :invalid, retryable?: false}} =
             NoteFixtures.scoped(note, RequestRepo, fn repo ->
               Receipts.with_claim(repo, claim, fn ->
                 {:ok,
                  %{
                    outcome: "saved",
                    resource_id: note.resource_id,
                    version_id: Ecto.UUID.generate()
                  }}
               end)
             end)

    assert receipt_count(note, claim.mutation_id) == 0
  end

  test "simultaneous claims serialize and execute the winning callback once", %{note: note} do
    claim = claim(note)
    result = saved(note)
    counter = start_supervised!({Agent, fn -> 0 end})

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          NoteFixtures.scoped(note, RequestRepo, fn repo ->
            Receipts.with_claim(repo, claim, fn ->
              Agent.update(counter, &(&1 + 1))
              Process.sleep(50)
              {:ok, result}
            end)
          end)
        end)
      end

    assert Enum.map(tasks, &Task.await(&1, 5_000)) == [{:ok, result}, {:ok, result}]
    assert Agent.get(counter, & &1) == 1
    assert receipt_count(note, claim.mutation_id) == 1
  end

  test "the same vault mutation id is isolated by principal", %{note: note} do
    peer_principal_id = same_vault_principal!(note)
    mutation_id = Ecto.UUID.generate()
    fingerprint = :crypto.hash(:sha256, "principal-isolation")
    counter = start_supervised!({Agent, fn -> 0 end})

    for principal_id <- [note.principal_id, peer_principal_id] do
      principal_claim =
        claim(note)
        |> Map.merge(%{
          principal_id: principal_id,
          mutation_id: mutation_id,
          request_fingerprint: fingerprint
        })

      assert {:ok, saved(note)} ==
               ScopedRepo.transact(
                 RequestRepo,
                 %{principal_id: principal_id, vault_id: note.vault_id},
                 fn repo ->
                   Receipts.with_claim(repo, principal_claim, fn ->
                     Agent.update(counter, &(&1 + 1))
                     {:ok, saved(note)}
                   end)
                 end
               )
    end

    assert Agent.get(counter, & &1) == 2

    for principal_id <- [note.principal_id, peer_principal_id] do
      assert %{rows: [[1]]} =
               ScopedRepo.transact(
                 RequestRepo,
                 %{principal_id: principal_id, vault_id: note.vault_id},
                 fn repo ->
                   query!(
                     repo,
                     "SELECT count(*) FROM content.note_mutation_receipts WHERE mutation_id = $1",
                     [Ecto.UUID.dump!(mutation_id)]
                   )
                 end
               )
    end
  end

  test "malformed claim identifiers and fingerprints are stable invalid errors", %{note: note} do
    for malformed <- [
          Map.put(claim(note), :vault_id, "not-a-vault"),
          Map.put(claim(note), :principal_id, <<1, 2>>),
          Map.put(claim(note), :mutation_id, "not-a-mutation"),
          Map.put(claim(note), :resource_id, "not-a-resource"),
          Map.put(claim(note), :request_fingerprint, <<1>>)
        ] do
      assert {:error, %Error{code: :invalid, retryable?: false}} =
               NoteFixtures.scoped(note, RequestRepo, fn repo ->
                 Receipts.with_claim(repo, malformed, fn ->
                   flunk("invalid claim ran callback")
                 end)
               end)
    end
  end

  defp claim(note) do
    %{
      vault_id: note.vault_id,
      principal_id: note.principal_id,
      mutation_id: Ecto.UUID.generate(),
      operation: :save,
      request_fingerprint: :crypto.hash(:sha256, "receipt-#{Ecto.UUID.generate()}"),
      resource_id: note.resource_id
    }
  end

  defp saved(note) do
    %{
      outcome: "saved",
      resource_id: note.resource_id,
      version_id: note.initial_version_id
    }
  end

  defp receipt_count(note, mutation_id) do
    NoteFixtures.scoped(note, RequestRepo, fn repo ->
      %{rows: [[count]]} =
        query!(
          repo,
          "SELECT count(*) FROM content.note_mutation_receipts WHERE mutation_id = $1",
          [Ecto.UUID.dump!(mutation_id)]
        )

      count
    end)
  end

  defp same_vault_principal!(note) do
    person_id = Ecto.UUID.generate()
    account_id = Ecto.UUID.generate()
    principal_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "INSERT INTO identity.people (id, display_name) VALUES ($1, $2)", [
        Ecto.UUID.dump!(person_id),
        "Receipt peer"
      ])

      query!(MigrationRepo, "INSERT INTO identity.accounts (id, person_id) VALUES ($1, $2)", [
        Ecto.UUID.dump!(account_id),
        Ecto.UUID.dump!(person_id)
      ])

      query!(
        MigrationRepo,
        "INSERT INTO identity.principals (id, account_id, kind) VALUES ($1, $2, 'owner')",
        [Ecto.UUID.dump!(principal_id), Ecto.UUID.dump!(account_id)]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.vault_members (principal_id, vault_id) VALUES ($1, $2)",
        [Ecto.UUID.dump!(principal_id), Ecto.UUID.dump!(note.vault_id)]
      )
    end)

    principal_id
  end
end
