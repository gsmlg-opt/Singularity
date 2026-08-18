defmodule Singularity.Storage.Postgres.NoteSearchStoreTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Core.NoteSaveResult
  alias Singularity.Core.NoteSnapshot
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.NoteRepository
  alias Singularity.Storage.Postgres.NoteSearchStore
  alias Singularity.Storage.RequestRepo
  alias Singularity.Storage.ScopedRepo

  @summary_keys [
    :classification,
    :deleted?,
    :open_conflict_count,
    :resource_id,
    :resource_version_id,
    :revision,
    :title,
    :updated_at,
    :vault_id
  ]

  defmodule Query do
    @enforce_keys [:vault_id, :q, :limit, :cursor, :classification]
    defstruct @enforce_keys
  end

  defmodule RejectingRepo do
    def all(_query), do: raise("invalid note search reached repository work")
  end

  setup do
    %{one: one, two: two} = Fixtures.two_vaults!()
    {:ok, fixture: load_ids(one), other_fixture: load_ids(two)}
  end

  test "search accepts the exact validated query shape and rejects malformed input before repo work",
       %{fixture: fixture} do
    query = %Query{
      vault_id: fixture.vault_id,
      q: "",
      limit: 20,
      cursor: nil,
      classification: :private
    }

    assert {:ok, %{items: [], next_cursor: :done}} = search(fixture, query)

    base = filters(fixture)

    invalid_queries = [
      Map.delete(base, :q),
      Map.put(base, :unexpected, true),
      Map.put(base, "q", "note"),
      %{base | vault_id: "not-a-vault"},
      %{base | vault_id: "00000000-0000-4000-8000-00000000000A"},
      %{base | classification: :sensitive},
      %{base | q: :binary.copy("q", 1_025)},
      %{base | q: <<0xFF>>},
      %{base | q: "note\0body"},
      %{base | limit: 0},
      %{base | limit: 51},
      %{base | limit: "20"},
      %{base | cursor: ""},
      %{base | cursor: " \t\n"},
      %{base | cursor: :binary.copy("c", 2_049)},
      %{base | cursor: <<0xFF>>},
      %{base | cursor: "next\0page"}
    ]

    for invalid <- invalid_queries do
      assert {:error, %Error{code: :invalid, retryable?: false}} =
               NoteSearchStore.search(RejectingRepo, invalid)
    end
  end

  test "empty query orders by canonical head time and ignores projection updated_at", %{
    fixture: fixture
  } do
    older = create_note!(fixture, "Older note", "# Older")
    newer = create_note!(fixture, "Newer note", "# Newer")
    older_head = ~U[2026-08-18 00:00:00.000000Z]
    newer_head = ~U[2026-08-19 00:00:00.000000Z]

    set_projection_times!(older.resource_id, older_head, ~U[2030-01-01 00:00:00.000000Z])
    set_projection_times!(newer.resource_id, newer_head, ~U[2020-01-01 00:00:00.000000Z])

    assert {:ok, %{items: [newer_item, older_item], next_cursor: :done}} =
             search(fixture, filters(fixture))

    assert newer_item.resource_id == newer.resource_id
    assert newer_item.updated_at == newer_head
    assert older_item.resource_id == older.resource_id
    assert older_item.updated_at == older_head
  end

  test "non-empty search ranks matches before canonical-head recency and excludes nonmatches", %{
    fixture: fixture
  } do
    dense = create_note!(fixture, "alpha alpha alpha", "alpha alpha alpha")
    sparse = create_note!(fixture, "alpha", "# sparse")
    nonmatch = create_note!(fixture, "beta", "# beta")

    set_projection_times!(dense.resource_id, ~U[2026-08-17 00:00:00.000000Z])
    set_projection_times!(sparse.resource_id, ~U[2026-08-18 00:00:00.000000Z])
    set_projection_times!(nonmatch.resource_id, ~U[2026-08-19 00:00:00.000000Z])

    assert {:ok, %{items: [dense_item, sparse_item], next_cursor: :done}} =
             search(fixture, %{filters(fixture) | q: "alpha"})

    assert dense_item.resource_id == dense.resource_id
    assert sparse_item.resource_id == sparse.resource_id
  end

  test "summaries expose exactly the canonical nine keys and count only open conflicts", %{
    fixture: fixture
  } do
    created = create_note!(fixture, "Original signal", "# Original signal")
    accepted = save_note!(fixture, created, "Canonical signal", "# Canonical signal")

    assert {:ok, %NoteSaveResult{outcome: :conflict} = competing} =
             save_note(
               fixture,
               created.resource_id,
               created.canonical_version_id,
               "Competing ghost",
               "# Competing ghost"
             )

    assert {:ok, %{items: [summary], next_cursor: :done}} =
             search(fixture, %{filters(fixture) | q: "canonical"})

    assert Enum.sort(Map.keys(summary)) == @summary_keys

    assert summary == %{
             resource_id: created.resource_id,
             resource_version_id: accepted.canonical_version_id,
             vault_id: fixture.vault_id,
             classification: :private,
             title: "Canonical signal",
             revision: 1,
             updated_at: projection_head_time(fixture, created.resource_id),
             deleted?: false,
             open_conflict_count: 1
           }

    refute Map.has_key?(summary, :markdown)
    refute Map.has_key?(summary, :snippet)

    assert {:ok, %{items: [], next_cursor: :done}} =
             search(fixture, %{filters(fixture) | q: "ghost"})

    assert competing.resource_id == created.resource_id
  end

  test "search applies live private current-head and vault predicates before returning summaries",
       %{
         fixture: fixture,
         other_fixture: other_fixture
       } do
    live = create_note!(fixture, "scope beacon", "# live scope beacon")
    deleted = create_note!(fixture, "scope beacon", "# deleted scope beacon")
    _other_vault = create_note!(other_fixture, "scope beacon", "# foreign scope beacon")

    tombstone_resource!(deleted.resource_id)

    assert {:ok, %{items: [summary], next_cursor: :done}} =
             search(fixture, %{filters(fixture) | q: "scope beacon"})

    assert %{
             resource_id: resource_id,
             resource_version_id: version_id,
             vault_id: vault_id,
             classification: :private,
             deleted?: false
           } = summary

    assert resource_id == live.resource_id
    assert version_id == live.canonical_version_id
    assert vault_id == fixture.vault_id
  end

  test "opaque keyset cursors preserve tied ordering and bind normalized filters", %{
    fixture: fixture,
    other_fixture: other_fixture
  } do
    tied_at = ~U[2026-08-18 12:00:00.000000Z]

    expected_ids =
      for _index <- 1..5 do
        note = create_note!(fixture, "pagination tie", "# pagination tie")
        set_projection_times!(note.resource_id, tied_at)
        note.resource_id
      end
      |> Enum.sort()

    first_filters = %{filters(fixture) | q: " pagination tie ", limit: 2}

    assert {:ok, %{items: first, next_cursor: cursor_one}} = search(fixture, first_filters)
    assert [%{}, %{}] = first
    assert is_binary(cursor_one)
    assert byte_size(cursor_one) <= 2_048

    <<first_byte, rest::binary>> = cursor_one
    replacement = if first_byte == ?A, do: ?B, else: ?A
    tampered = <<replacement, rest::binary>>

    for mismatch <- [
          %{first_filters | q: "different", cursor: cursor_one},
          %{first_filters | vault_id: other_fixture.vault_id, cursor: cursor_one},
          %{first_filters | classification: :sensitive, cursor: cursor_one},
          %{first_filters | cursor: tampered}
        ] do
      assert {:error, %Error{code: :invalid, retryable?: false}} = search(fixture, mismatch)
    end

    next_filters = %{first_filters | q: "pagination tie", cursor: cursor_one}
    assert {:ok, %{items: second, next_cursor: cursor_two}} = search(fixture, next_filters)
    assert [%{}, %{}] = second
    assert is_binary(cursor_two)

    assert {:ok, %{items: third, next_cursor: :done}} =
             search(fixture, %{next_filters | cursor: cursor_two})

    assert [%{}] = third

    items = first ++ second ++ third
    assert Enum.map(items, & &1.resource_id) == expected_ids
    assert length(Enum.uniq_by(items, & &1.resource_id)) == 5
    assert Enum.all?(items, &(Enum.sort(Map.keys(&1)) == @summary_keys))
  end

  defp filters(fixture) do
    %{
      vault_id: fixture.vault_id,
      q: "",
      limit: 20,
      cursor: nil,
      classification: :private
    }
  end

  defp create_note!(fixture, title, markdown) do
    {:ok, snapshot} =
      NoteSnapshot.initial(%{classification: :private, title: title, markdown: markdown})

    intent = %{
      mutation_id: Ecto.UUID.generate(),
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      snapshot: snapshot,
      request_fingerprint: :crypto.hash(:sha256, [title, 0, markdown, Ecto.UUID.generate()])
    }

    assert {:ok, %NoteSaveResult{} = result} =
             scoped(fixture, &NoteRepository.create(&1, intent))

    result
  end

  defp save_note!(fixture, created, title, markdown) do
    assert {:ok, %NoteSaveResult{} = result} =
             save_note(
               fixture,
               created.resource_id,
               created.canonical_version_id,
               title,
               markdown
             )

    result
  end

  defp save_note(fixture, resource_id, base_version_id, title, markdown) do
    {:ok, snapshot} =
      NoteSnapshot.normal(%{
        classification: :private,
        title: title,
        markdown: markdown,
        parent_version_id: base_version_id
      })

    intent = %{
      mutation_id: Ecto.UUID.generate(),
      principal_id: fixture.principal_id,
      vault_id: fixture.vault_id,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      resource_id: resource_id,
      base_version_id: base_version_id,
      snapshot: snapshot,
      request_fingerprint: :crypto.hash(:sha256, [resource_id, base_version_id, title, markdown])
    }

    scoped(fixture, &NoteRepository.save(&1, intent))
  end

  defp set_projection_times!(resource_id, head_inserted_at, updated_at \\ nil) do
    updated_at = updated_at || head_inserted_at

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE content.note_search_documents
        SET head_inserted_at = $2, updated_at = $3
        WHERE resource_id = $1
        """,
        [Ecto.UUID.dump!(resource_id), head_inserted_at, updated_at]
      )
    end)

    :ok
  end

  defp tombstone_resource!(resource_id) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1",
        [Ecto.UUID.dump!(resource_id)]
      )
    end)

    :ok
  end

  defp projection_head_time(fixture, resource_id) do
    scoped(fixture, fn repo ->
      assert %{rows: [[head_inserted_at]]} =
               query!(
                 repo,
                 "SELECT head_inserted_at FROM content.note_search_documents WHERE resource_id = $1",
                 [Ecto.UUID.dump!(resource_id)]
               )

      head_inserted_at
    end)
  end

  defp search(fixture, query) do
    scoped(fixture, &NoteSearchStore.search(&1, query))
  end

  defp scoped(fixture, callback) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      callback
    )
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value}
      when key in [
             :account_id,
             :asset_id,
             :credential_id,
             :principal_id,
             :resource_id,
             :resource_version_id,
             :session_id,
             :vault_id
           ] ->
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end
end
