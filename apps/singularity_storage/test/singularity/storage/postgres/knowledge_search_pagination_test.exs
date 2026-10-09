defmodule Singularity.Storage.Postgres.KnowledgeSearchPaginationTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Core.{DocumentFragment, Error, SourceLocator}
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, RequestRepo, ScopedRepo}

  @store Singularity.Storage.Postgres.KnowledgeSearchStore
  @timestamp ~U[2026-10-01 00:00:00.000000Z]

  test "tied mixed-kind pages preserve the complete ordering tuple across many fragments" do
    source = KnowledgeFixtures.source!()
    notes = Enum.map(1..3, fn _ -> KnowledgeFixtures.note!(source) end)
    {document, fragments} = document!(source, 63)
    project!(source, notes ++ [document])

    assert {:ok, %{items: first, next_cursor: token}} = search(source, query(source, 50))
    assert is_binary(token)

    assert {:ok, %{items: second, next_cursor: :done}} =
             search(source, %{query(source, 50) | cursor: token})

    expected = expected(source)
    assert Enum.map(first ++ second, &key/1) == expected
    assert length(expected) == 66
    assert length(Enum.uniq_by(first ++ second, & &1.entry_id)) == 66
    assert Enum.count(first ++ second, &(&1.kind == :document)) == length(fragments)

    assert collect(source, query(source, 1)) == expected
    assert collect(source, query(source, 7)) == expected
  end

  test "cursor filters are bound while the page limit may change" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    notes = Enum.map(1..4, fn _ -> KnowledgeFixtures.note!(source) end)
    project!(source, notes)
    base = query(source, 1)

    assert {:ok, %{items: [first], next_cursor: token}} = search(source, base)

    assert {:ok, %{items: remaining, next_cursor: :done}} =
             search(source, %{base | limit: 50, cursor: token})

    assert Enum.map([first | remaining], &key/1) == expected(source)

    for changed <- [
          %{base | q: "body"},
          %{base | kind: :note},
          %{base | tag_ids: [Ecto.UUID.generate()]},
          %{base | owner_scope_id: Ecto.UUID.load!(other.vault_id)},
          %{base | policy_version: 2}
        ] do
      assert {:error, %Error{code: :invalid}} = search(source, %{changed | cursor: token})
    end

    assert {:error, %Error{code: :invalid}} = search(source, %{base | cursor: token <> "a"})
  end

  test "rank and immutable recency descend before UUID ties on every page" do
    source = KnowledgeFixtures.source!()

    rows = [
      {"body body body", ~U[2026-09-01 00:00:00.000000Z]},
      {"body body", ~U[2026-09-02 00:00:00.000000Z]},
      {"body", ~U[2026-09-03 00:00:00.000000Z]},
      {"body", ~U[2026-09-04 00:00:00.000000Z]},
      {"body", ~U[2026-09-04 00:00:00.000000Z]}
    ]

    Fixtures.with_owner(fn ->
      for {body, timestamp} <- rows do
        resource = KnowledgeFixtures.uuid()
        version = KnowledgeFixtures.uuid()

        query!(
          MigrationRepo,
          "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,'Neutral heading')",
          [resource, source.vault_id, version]
        )

        query!(
          MigrationRepo,
          "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision,inserted_at) VALUES($1,$2,$3,'private',0,$4)",
          [version, resource, source.vault_id, timestamp]
        )

        query!(
          MigrationRepo,
          "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id) VALUES($1,$2,$3,'private','Neutral heading',$4,$5)",
          [version, resource, source.vault_id, body, source.principal_id]
        )

        query!(MigrationRepo, "SELECT content.reconcile_search_resource_internal($1,$2)", [
          source.vault_id,
          resource
        ])
      end
    end)

    expected =
      Fixtures.with_owner(fn ->
        %{rows: rows} =
          query!(
            MigrationRepo,
            """
            SELECT 4 * floor(1000000 * ts_rank_cd(search_vector,plainto_tsquery('simple','body'),32))::bigint + 1000000 AS rank,
                   source_inserted_at,resource_id::text,resource_version_id::text,ordinal,entry_id
            FROM content.search_entries WHERE vault_id=$1
            ORDER BY rank DESC,source_inserted_at DESC,resource_id,resource_version_id,ordinal,entry_id COLLATE "C"
            """,
            [source.vault_id]
          )

        Enum.map(rows, &List.to_tuple/1)
      end)

    assert length(Enum.uniq_by(expected, &elem(&1, 0))) == 3
    assert collect(source, %{query(source, 1) | q: "body"}) == expected
    assert collect(source, %{query(source, 2) | q: "body"}) == expected
  end

  test "every cursor page rechecks committed canonical tombstones" do
    source = KnowledgeFixtures.source!()
    notes = Enum.map(1..3, fn _ -> KnowledgeFixtures.note!(source) end)
    project!(source, notes)
    base = query(source, 1)
    assert {:ok, %{items: [first], next_cursor: token}} = search(source, base)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id<>$1 AND vault_id=$2 AND kind='note'",
        [Ecto.UUID.dump!(first.resource_id), source.vault_id]
      )
    end)

    assert {:ok, %{items: [], next_cursor: :done}} = search(source, %{base | cursor: token})
  end

  defp key(item),
    do:
      {item.rank, item.source_inserted_at, item.resource_id, item.resource_version_id,
       item.ordinal, item.entry_id}

  defp expected(source) do
    Fixtures.with_owner(fn ->
      %{rows: rows} =
        query!(
          MigrationRepo,
          """
          SELECT 0,source_inserted_at,resource_id::text,resource_version_id::text,ordinal,entry_id
          FROM content.search_entries WHERE vault_id=$1
          ORDER BY source_inserted_at DESC,resource_id,resource_version_id,ordinal,entry_id COLLATE "C"
          """,
          [source.vault_id]
        )

      Enum.map(rows, &List.to_tuple/1)
    end)
  end

  defp collect(source, query, accumulator \\ []) do
    assert {:ok, %{items: items, next_cursor: cursor}} = search(source, query)
    all = accumulator ++ Enum.map(items, &key/1)
    if cursor == :done, do: all, else: collect(source, %{query | cursor: cursor}, all)
  end

  defp document!(source, count) do
    document = KnowledgeFixtures.document!(source)

    fragments =
      Enum.map(0..(count - 1), fn ordinal ->
        {:ok, fragment} =
          DocumentFragment.new(%{
            resource_id: Ecto.UUID.load!(document.resource_id),
            resource_version_id: Ecto.UUID.load!(document.resource_version_id),
            owner_scope_id: Ecto.UUID.load!(source.vault_id),
            classification: :private,
            ordinal: ordinal,
            text: "body #{ordinal}",
            locator: %{"version" => 1, "kind" => "fragment", "ordinal" => ordinal}
          })

        fragment
      end)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [Ecto.UUID.load!(source.principal_id), Ecto.UUID.load!(source.vault_id)]
      )

      query!(MigrationRepo, "SELECT content.claim_document_extraction($1,0,$1,'plain',1)", [
        document.resource_version_id
      ])

      payload =
        Enum.map(fragments, fn fragment ->
          %{
            "id" => fragment.fragment_id,
            "ordinal" => fragment.ordinal,
            "text" => fragment.text,
            "digest" => Base.encode16(fragment.digest, case: :lower),
            "locator" => SourceLocator.to_map(fragment.locator)
          }
        end)

      digest = :crypto.hash(:sha256, Enum.map(fragments, & &1.text))

      query!(MigrationRepo, "SELECT content.complete_document_extraction($1,$1,1,$2,$3,'en')", [
        document.resource_version_id,
        payload,
        digest
      ])
    end)

    {document, fragments}
  end

  defp project!(source, resources) do
    Fixtures.with_owner(fn ->
      for resource <- resources do
        query!(MigrationRepo, "UPDATE content.resource_versions SET inserted_at=$2 WHERE id=$1", [
          resource.resource_version_id,
          @timestamp
        ])

        query!(MigrationRepo, "SELECT content.reconcile_search_resource_internal($1,$2)", [
          source.vault_id,
          resource.resource_id
        ])
      end
    end)
  end

  defp query(source, limit),
    do: %{
      owner_scope_id: Ecto.UUID.load!(source.vault_id),
      classification: :private,
      q: "",
      kind: :all,
      tag_ids: [],
      limit: limit,
      cursor: nil,
      policy_version: 1
    }

  defp search(source, query),
    do:
      ScopedRepo.transact(
        RequestRepo,
        Map.take(source, [:principal_id, :vault_id]),
        &apply(@store, :search, [&1, query])
      )
end
