defmodule Singularity.Storage.Postgres.KnowledgeSearchStoreTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.{DocumentFragment, Error, SourceLocator}

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    MigrationRepo,
    RequestRepo,
    SafeSQL,
    ScopedRepo
  }

  @store Singularity.Storage.Postgres.KnowledgeSearchStore
  @result_keys ~w(owner_scope_id classification kind resource_id resource_version_id fragment_id entry_id ordinal title snippet locator source_inserted_at rank)a

  defmodule RejectingRepo do
    def in_transaction?, do: raise("invalid knowledge search reached repository work")
  end

  test "empty query returns the owner's current canonical Note and ready Document entries" do
    source = authorized_source!()
    note = KnowledgeFixtures.note!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)

    Fixtures.with_owner(fn ->
      for resource <- [note, document] do
        assert %{rows: [[1]]} =
                 query!(
                   MigrationRepo,
                   "SELECT content.reconcile_search_resource_internal($1,$2)",
                   [
                     source.vault_id,
                     resource.resource_id
                   ]
                 )
      end
    end)

    assert {:ok, %{items: items, next_cursor: :done}} = search(source, filters(source))
    assert [document_item, note_item] = Enum.sort_by(items, & &1.kind)

    for item <- items do
      assert Enum.sort(Map.keys(item)) == Enum.sort(@result_keys)
      assert item.owner_scope_id == Ecto.UUID.load!(source.vault_id)
      assert item.classification == :private
      assert item.rank == 0
      assert %DateTime{} = item.source_inserted_at
    end

    assert note_item.kind == :note
    assert note_item.resource_id == Ecto.UUID.load!(note.resource_id)
    assert note_item.resource_version_id == Ecto.UUID.load!(note.resource_version_id)
    assert note_item.entry_id == "note:" <> Ecto.UUID.load!(note.resource_version_id)
    assert note_item.fragment_id == nil
    assert note_item.ordinal == 0
    assert note_item.title == "Note"
    assert note_item.snippet == "body"
    assert note_item.locator == %{"version" => 1, "kind" => "markdown", "heading_path" => []}

    assert document_item.kind == :document
    assert document_item.resource_id == Ecto.UUID.load!(document.resource_id)
    assert document_item.resource_version_id == Ecto.UUID.load!(document.resource_version_id)
    assert document_item.entry_id == "document:" <> fragment.fragment_id
    assert document_item.fragment_id == fragment.fragment_id
    assert document_item.ordinal == 0
    assert document_item.title == "Document"
    assert document_item.snippet == "text"
    assert document_item.locator == Singularity.Core.SourceLocator.to_map(fragment.locator)
  end

  test "nonempty canonical search without read assignments returns a sanitized forbidden error" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    project!(source, [note])
    assert_no_read_assignments!(source)

    assert search(source, %{filters(source) | q: "body", kind: :note}) ==
             {:error, %Error{code: :forbidden, message: nil, details: %{}, retryable?: false}}
  end

  test "empty query without read assignments preserves the direct canonical source and 13 bindings" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    project!(source, [note])
    assert_no_read_assignments!(source)
    query = %{filters(source) | kind: :note}

    original = search(source, query)
    assert {:ok, %{items: [item], next_cursor: :done}} = original
    assert Enum.sort(Map.keys(item)) == Enum.sort(@result_keys)
    assert item.owner_scope_id == Ecto.UUID.load!(source.vault_id)
    assert item.resource_id == Ecto.UUID.load!(note.resource_id)
    assert item.resource_version_id == Ecto.UUID.load!(note.resource_version_id)
    assert item.entry_id == "note:" <> Ecto.UUID.load!(note.resource_version_id)
    assert item.classification == :private
    assert item.kind == :note
    assert item.fragment_id == nil
    assert item.ordinal == 0
    assert item.title == "Note"
    assert item.snippet == "body"
    assert item.locator == %{"version" => 1, "kind" => "markdown", "heading_path" => []}
    assert %DateTime{} = item.source_inserted_at
    assert item.rank == 0

    assert {:ok, captured, summary} = capture_search_summary(source, query)
    assert captured == original
    assert summary == %{statements: 1, parameter_count: 13, candidate_references: 0}
    assert {:flags, []} = :erlang.trace_info(self(), :flags)
    assert {:traced, false} = :erlang.trace_info({SafeSQL, :query, 4}, :traced)
  end

  test "invalid public search maps return only the sanitized invalid error" do
    source = KnowledgeFixtures.source!()
    query = %{filters(source) | q: " untrimmed "}

    assert apply(@store, :search, [RejectingRepo, query]) ==
             {:error, %Error{code: :invalid, message: nil, details: %{}, retryable?: false}}
  end

  test "private search capture refuses another observer's trace pattern" do
    source = KnowledgeFixtures.source!()
    function = {SafeSQL, :query, 4}
    Code.ensure_loaded!(SafeSQL)
    assert {:flags, []} = :erlang.trace_info(self(), :flags)
    assert {:traced, false} = :erlang.trace_info(function, :traced)

    try do
      assert :erlang.trace_pattern(function, true, [:local]) == 1
      assert capture_search_summary(source, filters(source)) == {:error, :search_trace_owned}
      assert {:traced, :local} = :erlang.trace_info(function, :traced)
    after
      :erlang.trace_pattern(function, false, [:local])
    end

    assert {:flags, []} = :erlang.trace_info(self(), :flags)
    assert {:traced, false} = :erlang.trace_info(function, :traced)
  end

  test "private search capture cleans its traces when scoped setup raises" do
    source = KnowledgeFixtures.source!()

    assert capture_search_summary(%{}, filters(source)) == {:error, :search_trace_failed}
    assert {:flags, []} = :erlang.trace_info(self(), :flags)
    assert {:traced, false} = :erlang.trace_info({SafeSQL, :query, 4}, :traced)
  end

  test "closed validated maps and cursor envelopes fail before repository work" do
    source = authorized_source!()
    base = filters(source)

    invalid = [
      nil,
      Map.delete(base, :q),
      Map.put(base, :timeout, 1),
      Map.put(base, "q", "text"),
      %{base | owner_scope_id: "not-an-owner"},
      %{base | owner_scope_id: String.upcase(base.owner_scope_id)},
      %{base | classification: :sensitive},
      %{base | policy_version: 2},
      %{base | q: " untrimmed "},
      %{base | q: <<255>>},
      %{base | q: "text\0body"},
      %{base | q: :binary.copy("x", 1_025)},
      %{base | kind: "note"},
      %{base | tag_ids: ["bad-tag"]},
      %{base | tag_ids: List.duplicate(Ecto.UUID.generate(), 21)},
      %{base | limit: 0},
      %{base | limit: 51},
      %{base | limit: "20"},
      %{base | cursor: ""},
      %{base | cursor: :binary.copy("x", 2_049)},
      %{base | cursor: "forged-cursor"}
    ]

    for query <- invalid do
      assert {:error, %Error{code: :invalid, retryable?: false}} =
               apply(@store, :search, [RejectingRepo, query])
    end
  end

  test "search requires a scoped transaction and the query owner must match its GUC" do
    source = authorized_source!()
    other = authorized_source!()

    assert {:error, %Error{code: :invalid}} =
             apply(@store, :search, [RequestRepo, filters(source)])

    assert {:error, %Error{code: :invalid}} = search(source, filters(other))
  end

  test "FTS-only candidates use the weighted simple vector and exact integer score" do
    source = authorized_source!()
    note = note!(source, "Neutral heading", "alpha bridge beta")
    project!(source, [note])
    q = "alpha beta"

    assert {:ok, %{items: [item], next_cursor: :done}} = search(source, %{filters(source) | q: q})
    assert item.resource_id == Ecto.UUID.load!(note.resource_id)

    Fixtures.with_owner(fn ->
      assert %{rows: [[false, false, expected]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT title ILIKE '%' || $2 || '%' OR body ILIKE '%' || $2 || '%',
                        search_extensions.similarity(title,$2) >= 0.3,
                        4 * floor(1000000 * ts_rank_cd(search_vector,plainto_tsquery('simple',$2),32))::bigint
                 FROM content.search_entries WHERE entry_id=$1
                 """,
                 [item.entry_id, q]
               )

      assert item.rank == expected
      assert item.rank > 0
    end)
  end

  test "eligible title typos match trigram similarity with the fixed integer score" do
    source = authorized_source!()
    note = note!(source, "postgresql", "neutral body")
    project!(source, [note])
    q = "postgreql"

    assert {:ok, %{items: [item], next_cursor: :done}} = search(source, %{filters(source) | q: q})
    assert item.resource_id == Ecto.UUID.load!(note.resource_id)

    Fixtures.with_owner(fn ->
      assert %{rows: [[false, false, expected]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT search_vector @@ plainto_tsquery('simple',$2),
                        title ILIKE '%' || $2 || '%' OR body ILIKE '%' || $2 || '%',
                        2 * floor(1000000 * search_extensions.similarity(title,$2))::bigint
                 FROM content.search_entries WHERE entry_id=$1
                 """,
                 [item.entry_id, q]
               )

      assert item.rank == expected
      assert item.rank > 0
    end)
  end

  test "trigram eligibility counts Unicode code points rather than graphemes" do
    source = authorized_source!()
    note = note!(source, "a b", "neutral body")
    project!(source, [note])
    q = "a\u0301b"
    assert String.length(q) == 2
    assert length(String.codepoints(q)) == 3

    Fixtures.with_owner(fn ->
      assert %{rows: [[true, expected]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT search_extensions.similarity(title,$2) >= 0.3,
                        CASE WHEN search_vector @@ plainto_tsquery('simple',$2)
                          THEN 4 * floor(1000000 * ts_rank_cd(search_vector,plainto_tsquery('simple',$2),32))::bigint
                          ELSE 0 END
                        + 2 * floor(1000000 * search_extensions.similarity(title,$2))::bigint
                 FROM content.search_entries WHERE resource_id=$1
                 """,
                 [note.resource_id, q]
               )

      assert {:ok, %{items: [item], next_cursor: :done}} =
               search(source, %{filters(source) | q: q})

      assert item.rank == expected
    end)
  end

  test "a candidate matching FTS literal and trigram branches occurs once with the combined score" do
    source = authorized_source!()
    note = note!(source, "alpha", "alpha")
    project!(source, [note])

    assert {:ok, %{items: [item], next_cursor: :done}} =
             search(source, %{filters(source) | q: "alpha", limit: 1})

    Fixtures.with_owner(fn ->
      assert %{rows: [[expected]]} =
               query!(
                 MigrationRepo,
                 """
                 SELECT 4 * floor(1000000 * ts_rank_cd(search_vector,plainto_tsquery('simple','alpha'),32))::bigint
                          + 3000000
                 FROM content.search_entries WHERE entry_id=$1
                 """,
                 [item.entry_id]
               )

      assert item.rank == expected
      assert item.rank in 0..7_000_000
    end)
  end

  test "short Unicode and CJK substrings match independently of tokenization" do
    source = authorized_source!()
    note = note!(source, "Neutral heading", "prefixXYsuffix 前中文后")
    project!(source, [note])

    for q <- ["x", "xy", "中", "中文"] do
      assert {:ok, %{items: [item], next_cursor: :done}} =
               search(source, %{filters(source) | q: q})

      assert item.resource_id == Ecto.UUID.load!(note.resource_id)
      assert item.rank == 1_000_000
    end
  end

  test "literal percent underscore backslash and punctuation do not become LIKE wildcards" do
    source = authorized_source!()
    literal = note!(source, "Neutral heading", "x%z x_z x\\z !!!")
    other = note!(source, "Different heading", "xyz unrelated")
    project!(source, [literal, other])

    for q <- ["%", "_", "\\", "!!!"] do
      assert {:ok, %{items: [item], next_cursor: :done}} =
               search(source, %{filters(source) | q: q})

      assert item.resource_id == Ecto.UUID.load!(literal.resource_id)
      assert item.rank == 1_000_000
    end

    assert {:ok, %{items: [_, _], next_cursor: :done}} = search(source, filters(source))
  end

  test "OR quotes and minus signs remain plain text rather than websearch operators" do
    source = authorized_source!()
    plain = note!(source, "Neutral heading", "alpha bridge beta")
    literal = note!(source, "Different heading", "alpha OR beta")
    project!(source, [plain, literal])

    assert {:ok, %{items: [item], next_cursor: :done}} =
             search(source, %{filters(source) | q: "alpha OR beta"})

    assert item.resource_id == Ecto.UUID.load!(literal.resource_id)

    assert {:ok, %{items: items, next_cursor: :done}} =
             search(source, %{filters(source) | q: "\"alpha\" -beta"})

    assert Enum.sort(Enum.map(items, & &1.resource_id)) ==
             Enum.sort([Ecto.UUID.load!(plain.resource_id), Ecto.UUID.load!(literal.resource_id)])
  end

  test "full-body eligibility returns only a bounded plain Unicode snippet" do
    source = authorized_source!()
    prefix = :binary.copy("😀", 160)
    note = note!(source, "Neutral heading", prefix <> " distantneedle <strong>raw</strong>")
    project!(source, [note])

    assert {:ok, %{items: [item], next_cursor: :done}} =
             search(source, %{filters(source) | q: "distantneedle"})

    assert item.snippet == prefix
    assert length(String.codepoints(item.snippet)) == 160
    assert byte_size(item.snippet) == 640
    assert Enum.sort(Map.keys(item)) == Enum.sort(@result_keys)
  end

  test "kind filters and canonical AND tags include all Document fragments without exposing labels" do
    source = authorized_source!()
    foreign = authorized_source!()
    note = note!(source, "Note", "body")
    {document, _} = document!(source, ["one", "two"])
    project!(source, [note, document])
    [first, second] = tags!(source, ["secret-label-one", "secret-label-two"])
    [foreign_tag] = tags!(foreign, ["secret-label-one"])
    assign_tags!(source, note, [first])
    assign_tags!(source, document, [first, second])

    assert {:ok, %{items: [%{kind: :note}], next_cursor: :done}} =
             search(source, %{filters(source) | kind: :note})

    assert {:ok, %{items: [%{kind: :document}, %{kind: :document}], next_cursor: :done}} =
             search(source, %{filters(source) | tag_ids: Enum.sort([first, second])})

    for tag <- [foreign_tag, Ecto.UUID.generate()] do
      assert {:ok, %{items: [], next_cursor: :done}} =
               search(source, %{filters(source) | tag_ids: [tag]})
    end

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "DELETE FROM content.resource_tags WHERE resource_id=$1 AND tag_id=$2",
        [
          document.resource_id,
          Ecto.UUID.dump!(second)
        ]
      )
    end)

    assert {:ok, %{items: [], next_cursor: :done}} =
             search(source, %{filters(source) | tag_ids: Enum.sort([first, second])})
  end

  test "stale projections never expose historical deleted or foreign sources" do
    source = authorized_source!()
    foreign = authorized_source!()
    live = note!(source, "Live", "signal")
    historical = note!(source, "Historical conflict", "signal")
    deleted = note!(source, "Deleted", "signal")
    foreign_note = note!(foreign, "Foreign", "signal")
    project!(source, [live, historical, deleted])
    project!(foreign, [foreign_note])

    Fixtures.with_owner(fn ->
      replacement = KnowledgeFixtures.uuid()

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
        [replacement, historical.resource_id, source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id) VALUES($1,$2,$3,'private','Replacement','replacement',$4,$5)",
        [
          replacement,
          historical.resource_id,
          source.vault_id,
          source.principal_id,
          historical.resource_version_id
        ]
      )

      query!(MigrationRepo, "UPDATE content.resources SET current_version_id=$2 WHERE id=$1", [
        historical.resource_id,
        replacement
      ])

      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
        [deleted.resource_id]
      )
    end)

    for q <- ["", "signal"] do
      assert {:ok, %{items: [item], next_cursor: :done}} =
               search(source, %{filters(source) | q: q})

      assert item.resource_id == Ecto.UUID.load!(live.resource_id)
    end
  end

  test "an extracting Document with staged canonical fragments and stale entries is not visible" do
    source = authorized_source!()
    document = KnowledgeFixtures.document!(source)
    fragment = fragment!(source, document, "signal", 0)

    Fixtures.with_owner(fn ->
      set_owner_context!(source)

      query!(MigrationRepo, "SELECT content.claim_document_extraction($1,0,$1,'plain',1)", [
        document.resource_version_id
      ])

      query!(
        MigrationRepo,
        """
        INSERT INTO content.document_fragments(id,resource_id,resource_version_id,vault_id,classification,ordinal,text,digest,locator,inserted_at)
        VALUES($1,$2,$3,$4,'private',0,$5,$6,$7,CURRENT_TIMESTAMP)
        """,
        [
          fragment.fragment_id,
          document.resource_id,
          document.resource_version_id,
          source.vault_id,
          fragment.text,
          fragment.digest,
          SourceLocator.to_map(fragment.locator)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.search_entries(entry_id,vault_id,classification,resource_id,resource_version_id,kind,fragment_id,ordinal,title,body,locator,source_inserted_at,projection_version)
        SELECT $1,$2,'private',$3,$4,'document',$5,0,'Document',$6,$7,inserted_at,1
        FROM content.resource_versions WHERE id=$4
        """,
        [
          "document:" <> fragment.fragment_id,
          source.vault_id,
          document.resource_id,
          document.resource_version_id,
          fragment.fragment_id,
          fragment.text,
          SourceLocator.to_map(fragment.locator)
        ]
      )
    end)

    for q <- ["", "signal"] do
      assert {:ok, %{items: [], next_cursor: :done}} = search(source, %{filters(source) | q: q})
    end
  end

  test "open conflicts preserve the canonical head while a stale competing projection is omitted" do
    source = authorized_source!()
    conflicted = note!(source, "Base", "base")
    control = note!(source, "Control", "canonicalneedle")
    canonical = KnowledgeFixtures.uuid()
    competing = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      for {version, revision, title, body} <- [
            {canonical, 1, "Canonical", "canonicalneedle"},
            {competing, 2, "Competing", "ghostneedle"}
          ] do
        query!(
          MigrationRepo,
          "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',$4)",
          [version, conflicted.resource_id, source.vault_id, revision]
        )

        query!(
          MigrationRepo,
          "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id) VALUES($1,$2,$3,'private',$4,$5,$6,$7)",
          [
            version,
            conflicted.resource_id,
            source.vault_id,
            title,
            body,
            source.principal_id,
            conflicted.resource_version_id
          ]
        )
      end

      query!(MigrationRepo, "UPDATE content.resources SET current_version_id=$2 WHERE id=$1", [
        conflicted.resource_id,
        canonical
      ])

      query!(
        MigrationRepo,
        "INSERT INTO content.note_conflicts(id,resource_id,vault_id,classification,base_version_id,canonical_version_id,competing_version_id,state) VALUES($1,$2,$3,'private',$4,$5,$6,'open')",
        [
          KnowledgeFixtures.uuid(),
          conflicted.resource_id,
          source.vault_id,
          conflicted.resource_version_id,
          canonical,
          competing
        ]
      )
    end)

    project!(source, [conflicted, control])

    assert {:ok, %{items: items, next_cursor: :done}} =
             search(source, %{filters(source) | q: "canonicalneedle"})

    assert [_, _] = items

    canonical_item =
      Enum.find(items, &(&1.resource_id == Ecto.UUID.load!(conflicted.resource_id)))

    assert canonical_item.resource_version_id == Ecto.UUID.load!(canonical)

    Fixtures.with_owner(fn ->
      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 UPDATE content.search_entries
                 SET entry_id=$2,resource_version_id=$3,note_resource_version_id=$3,title='Competing',body='ghostneedle',
                     source_inserted_at=(SELECT inserted_at FROM content.resource_versions WHERE id=$3)
                 WHERE resource_id=$1
                 """,
                 [conflicted.resource_id, "note:" <> Ecto.UUID.load!(competing), competing]
               )
    end)

    assert {:ok, %{items: [], next_cursor: :done}} =
             search(source, %{filters(source) | q: "ghostneedle"})

    for q <- ["", "canonicalneedle"] do
      assert {:ok, %{items: [item], next_cursor: :done}} =
               search(source, %{filters(source) | q: q})

      assert item.resource_id == Ecto.UUID.load!(control.resource_id)
    end
  end

  test "fixed settings override caller transaction settings and remain transaction local" do
    source = authorized_source!()

    RequestRepo.checkout(fn ->
      query!(RequestRepo, "SELECT search_extensions.similarity('','')")
      before_settings = settings(RequestRepo)

      assert :ok =
               ScopedRepo.transact(
                 RequestRepo,
                 Map.take(source, [:principal_id, :vault_id]),
                 fn repo ->
                   query!(repo, "SET LOCAL statement_timeout='30s'")
                   query!(repo, "SET LOCAL pg_trgm.similarity_threshold=0.9")

                   assert {:ok, %{items: [], next_cursor: :done}} =
                            apply(@store, :search, [repo, filters(source)])

                   assert ["5s", "0.3"] = settings(repo)
                   :ok
                 end
               )

      assert settings(RequestRepo) == before_settings
    end)
  end

  @tag timeout: 20_000
  test "a real statement deadline returns a sanitized retryable error and cleans the transaction" do
    source = authorized_source!()
    note = note!(source, "timeout-title-canary", "timeout-body-canary")
    project!(source, [note])
    start_supervised!({MigrationRepo, pool_size: 2})
    parent = self()
    reference = make_ref()

    blocker =
      Task.async(fn ->
        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
          query!(MigrationRepo, "LOCK TABLE content.search_entries IN ACCESS EXCLUSIVE MODE")

          %{rows: [[relation_oid]]} =
            query!(MigrationRepo, "SELECT 'content.search_entries'::regclass::oid")

          send(parent, {reference, :locked, relation_oid})

          receive do
            {^reference, :release} -> :ok
          after
            15_000 -> raise "knowledge search deadline barrier expired"
          end
        end)
      end)

    try do
      assert_receive {^reference, :locked, relation_oid}, 5_000

      reader =
        Task.async(fn ->
          ScopedRepo.transact(
            RequestRepo,
            Map.take(source, [:principal_id, :vault_id]),
            fn repo ->
              %{rows: [[backend]]} = query!(repo, "SELECT pg_backend_pid()")
              send(parent, {reference, :reader, backend})
              apply(@store, :search, [repo, %{filters(source) | q: "timeout-query-canary"}])
            end
          )
        end)

      try do
        assert_receive {^reference, :reader, backend}, 5_000

        assert await_relation_wait(
                 backend,
                 relation_oid,
                 System.monotonic_time(:millisecond) + 4_000
               )

        assert {:error,
                %Error{code: :storage_unavailable, retryable?: true, details: %{}, message: nil}} =
                 Task.await(reader, 7_000)
      after
        send(blocker.pid, {reference, :release})
        drain_task(blocker)
        drain_task(reader)
      end
    after
      send(blocker.pid, {reference, :release})
      drain_task(blocker)
    end

    assert {:ok, %{items: [_], next_cursor: :done}} = search(source, filters(source))
  end

  defp note!(source, title, body) do
    row = %{resource_id: KnowledgeFixtures.uuid(), resource_version_id: KnowledgeFixtures.uuid()}

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,$4)",
        [row.resource_id, source.vault_id, row.resource_version_id, title]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',0)",
        [row.resource_version_id, row.resource_id, source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,inserted_at) VALUES($1,$2,$3,'private',$4,$5,$6,CURRENT_TIMESTAMP)",
        [
          row.resource_version_id,
          row.resource_id,
          source.vault_id,
          title,
          body,
          source.principal_id
        ]
      )
    end)

    row
  end

  defp document!(source, bodies) do
    document = KnowledgeFixtures.document!(source)
    fragments = Enum.with_index(bodies, &fragment!(source, document, &1, &2))

    Fixtures.with_owner(fn ->
      set_owner_context!(source)

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

      digest = :crypto.hash(:sha256, bodies)

      query!(MigrationRepo, "SELECT content.complete_document_extraction($1,$1,1,$2,$3,'en')", [
        document.resource_version_id,
        payload,
        digest
      ])
    end)

    {document, fragments}
  end

  defp fragment!(source, document, text, ordinal) do
    {:ok, fragment} =
      DocumentFragment.new(%{
        resource_id: Ecto.UUID.load!(document.resource_id),
        resource_version_id: Ecto.UUID.load!(document.resource_version_id),
        owner_scope_id: Ecto.UUID.load!(source.vault_id),
        classification: :private,
        ordinal: ordinal,
        text: text,
        locator: %{"version" => 1, "kind" => "fragment", "ordinal" => ordinal}
      })

    fragment
  end

  defp set_owner_context!(source),
    do:
      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [Ecto.UUID.load!(source.principal_id), Ecto.UUID.load!(source.vault_id)]
      )

  defp project!(source, resources) do
    Fixtures.with_owner(fn ->
      for resource <- resources do
        query!(MigrationRepo, "SELECT content.reconcile_search_resource_internal($1,$2)", [
          source.vault_id,
          resource.resource_id
        ])
      end
    end)
  end

  defp tags!(source, labels) do
    Fixtures.with_owner(fn ->
      Enum.map(labels, fn label ->
        id = KnowledgeFixtures.uuid()

        query!(
          MigrationRepo,
          "INSERT INTO content.tags(id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at) VALUES($1,$2,'private',$3,$3,$4,CURRENT_TIMESTAMP)",
          [id, source.vault_id, label, source.principal_id]
        )

        Ecto.UUID.load!(id)
      end)
    end)
  end

  defp assign_tags!(source, resource, tags) do
    Fixtures.with_owner(fn ->
      for tag <- tags do
        query!(
          MigrationRepo,
          "INSERT INTO content.resource_tags(resource_id,tag_id,vault_id,classification,inserted_at) VALUES($1,$2,$3,'private',CURRENT_TIMESTAMP)",
          [resource.resource_id, Ecto.UUID.dump!(tag), source.vault_id]
        )
      end
    end)
  end

  defp settings(repo) do
    %{rows: [settings]} =
      query!(
        repo,
        "SELECT current_setting('statement_timeout'),current_setting('pg_trgm.similarity_threshold')"
      )

    settings
  end

  defp await_relation_wait(backend, relation_oid, deadline) do
    %{rows: [[waiting]]} =
      query!(
        MigrationRepo,
        "SELECT EXISTS(SELECT FROM pg_locks WHERE pid=$1 AND relation=$2::oid AND NOT granted)",
        [backend, relation_oid]
      )

    cond do
      waiting -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> await_relation_wait(backend, relation_oid, deadline)
    end
  end

  defp drain_task(task) do
    if Process.alive?(task.pid),
      do: Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill),
      else: Task.shutdown(task, :brutal_kill)
  end

  defp filters(source) do
    %{
      owner_scope_id: Ecto.UUID.load!(source.vault_id),
      classification: :private,
      q: "",
      kind: :all,
      tag_ids: [],
      limit: 20,
      cursor: nil,
      policy_version: 1
    }
  end

  defp assert_no_read_assignments!(source) do
    Fixtures.with_owner(fn ->
      assert %{rows: [[0]]} =
               SafeSQL.query!(
                 MigrationRepo,
                 """
                 SELECT count(*)
                 FROM core.principal_capabilities AS assignment
                 JOIN core.capabilities AS capability ON capability.id=assignment.capability_id
                 WHERE assignment.principal_id=$1 AND assignment.vault_id=$2
                   AND assignment.revoked_at IS NULL AND capability.name=ANY($3::text[])
                 """,
                 [source.principal_id, source.vault_id, ["note.read", "asset.read"]]
               )
    end)
  end

  defp capture_search_summary(source, query) do
    Code.ensure_loaded!(SafeSQL)
    caller = self()
    function = {SafeSQL, :query, 4}

    if :erlang.trace_info(caller, :flags) == {:flags, []} and
         :erlang.trace_info(function, :traced) == {:traced, false} do
      reference = make_ref()
      initial = %{statements: 0, parameter_count: nil, candidate_references: 0}

      {collector, monitor} =
        spawn_monitor(fn -> collect_search_summary(caller, reference, initial) end)

      try do
        try do
          1 = :erlang.trace_pattern(function, true, [:local])

          try do
            1 = :erlang.trace(caller, true, [:call, {:tracer, collector}])
            result = search(source, query)
            delivered = :erlang.trace_delivered(caller)

            receive do
              {:trace_delivered, ^caller, ^delivered} -> :ok
            after
              5_000 -> throw(:search_trace_delivery_timeout)
            end

            send(collector, {reference, :collect})

            receive do
              {^reference, :summary, summary} -> {:ok, result, summary}
            after
              5_000 -> throw(:search_trace_collection_timeout)
            end
          after
            :erlang.trace(caller, false, [:call])
          end
        after
          :erlang.trace_pattern(function, false, [:local])
          stop_search_collector!(collector, monitor, reference)
        end
      rescue
        _error -> {:error, :search_trace_failed}
      catch
        :throw, :search_trace_cleanup_failed -> {:error, :search_trace_cleanup_failed}
        _kind, _reason -> {:error, :search_trace_failed}
      end
    else
      {:error, :search_trace_owned}
    end
  end

  defp collect_search_summary(caller, reference, summary) do
    receive do
      {:trace, ^caller, :call, {SafeSQL, :query, [RequestRepo, statement, parameters, _options]}}
      when is_binary(statement) and is_list(parameters) ->
        # Reduce arguments immediately. Only closed counts leave this collector.
        candidate_references =
          summary.candidate_references +
            if(String.contains?(statement, "content.search_candidate_ids"), do: 1, else: 0)

        updated = %{summary | candidate_references: candidate_references}

        updated =
          if String.starts_with?(statement, "WITH input AS (") and
               String.contains?(statement, "scored AS MATERIALIZED") do
            %{updated | statements: updated.statements + 1, parameter_count: length(parameters)}
          else
            updated
          end

        collect_search_summary(caller, reference, updated)

      {^reference, :collect} ->
        send(caller, {reference, :summary, summary})
        collect_search_summary(caller, reference, summary)

      {^reference, :stop} ->
        :ok
    end
  end

  defp stop_search_collector!(collector, monitor, reference) do
    send(collector, {reference, :stop})

    receive do
      {:DOWN, ^monitor, :process, ^collector, :normal} -> :ok
      {:DOWN, ^monitor, :process, ^collector, _reason} -> throw(:search_trace_cleanup_failed)
    after
      5_000 ->
        Process.exit(collector, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^collector, _reason} ->
            throw(:search_trace_cleanup_failed)
        after
          1_000 -> throw(:search_trace_cleanup_failed)
        end
    end
  end

  defp authorized_source! do
    source = KnowledgeFixtures.source!()
    capabilities = ["note.read", "asset.read"]

    Fixtures.with_owner(fn ->
      for name <- capabilities do
        SafeSQL.query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid(), name]
        )
      end

      result =
        SafeSQL.query!(
          MigrationRepo,
          """
          INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id)
          SELECT $1,$2,capability.id FROM core.capabilities AS capability
          WHERE capability.name=ANY($3::text[])
          ON CONFLICT(principal_id,vault_id,capability_id) DO NOTHING
          """,
          [source.principal_id, source.vault_id, capabilities]
        )

      assert result.num_rows == length(capabilities)
    end)

    source
  end

  defp search(source, query) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: source.principal_id, vault_id: source.vault_id},
      &apply(@store, :search, [&1, query])
    )
  end
end
