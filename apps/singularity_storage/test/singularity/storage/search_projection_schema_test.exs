defmodule Singularity.Storage.SearchProjectionSchemaTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.SourceLocator

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    MigrationRepo,
    MigrationTestEnvironment,
    ScopedRepo
  }

  @migration_version 20_261_009_000_100
  @migration Singularity.Storage.Migrations.CreateUnifiedSearchProjection
  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261009000100_create_unified_search_projection.exs",
                    __DIR__
                  )
  @fields ~w(entry_id vault_id classification resource_id resource_version_id kind note_resource_version_id fragment_id ordinal title body locator source_inserted_at projection_version)a
  @runtime_roles ~w(singularity_web singularity_pre_auth singularity_dispatcher singularity_worker)

  test "table owner builds maintains and queries trigram GIN with only the approved function delegation" do
    Fixtures.with_owner(fn ->
      assert %{rows: [["singularity_table_owner"]]} = query!(MigrationRepo, "SELECT current_user")

      query!(
        MigrationRepo,
        "CREATE TEMP TABLE search_trgm_authority_probe (body text) ON COMMIT DROP"
      )

      query!(
        MigrationRepo,
        "CREATE INDEX search_trgm_authority_probe_gin ON search_trgm_authority_probe USING gin(body search_extensions.gin_trgm_ops)"
      )

      query!(MigrationRepo, "INSERT INTO search_trgm_authority_probe VALUES ('knowledge')")
      query!(MigrationRepo, "UPDATE search_trgm_authority_probe SET body = 'updated knowledge'")
      query!(MigrationRepo, "SET LOCAL enable_seqscan = off")

      assert %{rows: plan} =
               query!(
                 MigrationRepo,
                 "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT body FROM search_trgm_authority_probe WHERE body LIKE '%knowledge%'"
               )

      assert Enum.any?(plan, fn [line] ->
               String.contains?(line, "Bitmap Index Scan on search_trgm_authority_probe_gin") and
                 String.contains?(line, "loops=1")
             end)

      assert %{rows: [["updated knowledge", true, true]]} =
               query!(MigrationRepo, """
               SELECT body, search_extensions.similarity(body, 'knowledge') > 0,
                      body OPERATOR(search_extensions.%) 'knowledge'
               FROM search_trgm_authority_probe WHERE body LIKE '%knowledge%'
               """)

      assert %{rows: [[true, true, "gin"]]} =
               query!(MigrationRepo, """
               SELECT index.indisvalid, index.indisready, method.amname
               FROM pg_index AS index JOIN pg_class AS relation ON relation.oid = index.indexrelid
               JOIN pg_am AS method ON method.oid = relation.relam
               WHERE relation.relname = 'search_trgm_authority_probe_gin'
                 AND relation.relnamespace = pg_my_temp_schema()
               """)

      assert %{rows: [[2]]} =
               query!(MigrationRepo, """
               SELECT count(*) FROM pg_proc WHERE pronamespace = 'search_extensions'::regnamespace
                 AND has_function_privilege('singularity_table_owner', oid, 'EXECUTE')
               """)
    end)
  end

  test "fresh application databases contain the controlled extension and forced-RLS projection" do
    Fixtures.with_owner(fn ->
      assert %{rows: [["search_extensions"]]} =
               query!(MigrationRepo, """
               SELECT n.nspname
               FROM pg_extension AS e
               JOIN pg_namespace AS n ON n.oid = e.extnamespace
               WHERE e.extname = 'pg_trgm'
               """)

      assert %{rows: [[true, true, "singularity_table_owner"]]} =
               query!(MigrationRepo, """
               SELECT c.relrowsecurity, c.relforcerowsecurity, pg_get_userbyid(c.relowner)
               FROM pg_class AS c
               JOIN pg_namespace AS n ON n.oid = c.relnamespace
               WHERE n.nspname = 'content' AND c.relname = 'search_entries'
               """)
    end)
  end

  test "projection columns generated weighted vector indexes and three immutable source FKs are exact" do
    assert %{rows: columns} =
             query!(RequestRepo, """
             SELECT attname, format_type(atttypid, atttypmod), attnotnull, attgenerated::text
             FROM pg_attribute WHERE attrelid = 'content.search_entries'::regclass
               AND attnum > 0 AND NOT attisdropped ORDER BY attnum
             """)

    assert columns == [
             ["entry_id", "text", true, ""],
             ["vault_id", "uuid", true, ""],
             ["classification", "text", true, ""],
             ["resource_id", "uuid", true, ""],
             ["resource_version_id", "uuid", true, ""],
             ["kind", "text", true, ""],
             ["note_resource_version_id", "uuid", false, ""],
             ["fragment_id", "text", false, ""],
             ["ordinal", "bigint", true, ""],
             ["title", "text", true, ""],
             ["body", "text", true, ""],
             ["locator", "jsonb", true, ""],
             ["source_inserted_at", "timestamp(6) with time zone", true, ""],
             ["projection_version", "integer", true, ""],
             ["search_vector", "tsvector", true, "s"]
           ]

    assert %{rows: foreign_keys} =
             query!(RequestRepo, """
             SELECT target.relname, source_fk.confmatchtype, pg_get_constraintdef(source_fk.oid)
             FROM pg_constraint AS source_fk JOIN pg_class AS target ON target.oid = source_fk.confrelid
             WHERE source_fk.conrelid = 'content.search_entries'::regclass AND source_fk.contype = 'f'
             ORDER BY target.relname
             """)

    assert [
             ["document_fragments", "s", fragment_fk],
             ["note_versions", "s", note_fk],
             ["resource_versions", "s", version_fk]
           ] = foreign_keys

    assert fragment_fk =~
             "FOREIGN KEY (fragment_id, resource_id, resource_version_id, vault_id, classification)"

    assert note_fk =~
             "FOREIGN KEY (note_resource_version_id, resource_id, vault_id, classification)"

    assert version_fk =~
             "FOREIGN KEY (resource_version_id, resource_id, vault_id, classification)"

    refute Enum.any?(foreign_keys, fn [_, _, definition] ->
             String.contains?(definition, "current_version_id")
           end)

    assert %{rows: indexes} =
             query!(
               RequestRepo,
               "SELECT indexdef FROM pg_indexes WHERE schemaname = 'content' AND tablename = 'search_entries'"
             )

    definitions = Enum.map(indexes, fn [definition] -> definition end)

    for column <- ["search_vector", "title", "body"] do
      assert Enum.any?(
               definitions,
               &(String.contains?(&1, "USING gin") and String.contains?(&1, "(" <> column))
             )
    end

    for column <- ["title", "body"] do
      assert Enum.any?(
               definitions,
               &String.contains?(&1, "#{column} search_extensions.gin_trgm_ops")
             )
    end

    assert Enum.any?(
             definitions,
             &(String.contains?(&1, "vault_id, kind, source_inserted_at DESC") and
                 String.contains?(&1, "entry_id"))
           )

    assert Enum.any?(
             definitions,
             &(String.contains?(&1, "UNIQUE") and String.contains?(&1, "resource_id") and
                 String.contains?(&1, "'note'"))
           )

    assert Enum.any?(
             definitions,
             &(String.contains?(&1, "UNIQUE") and String.contains?(&1, "fragment_id") and
                 String.contains?(&1, "'document'"))
           )
  end

  test "real canonical Note and ready Document entries retain identities source times and generated A D weights" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    note_entry = note_attrs!(note)
    document_entry = document_attrs!(document, fragment)
    seed!(note_entry)
    seed!(document_entry)

    assert %{rows: rows} =
             ScopedRepo.transact(RequestRepo, context(source), fn repo ->
               query!(
                 repo,
                 "SELECT entry_id, kind, resource_version_id, fragment_id, locator, source_inserted_at, search_vector::text FROM content.search_entries WHERE vault_id=$1 ORDER BY kind",
                 [source.vault_id]
               )
             end)

    assert [
             [document_id, "document", document_version, fragment_id, locator, document_time, _],
             [note_id, "note", note_version, nil, note_locator, note_time, note_vector]
           ] = rows

    assert document_id == document_entry.entry_id
    assert document_version == document.resource_version_id
    assert fragment_id == fragment.fragment_id
    assert locator == SourceLocator.to_map(fragment.locator)
    assert document_time === document_entry.source_inserted_at
    assert note_id == note_entry.entry_id
    assert note_version == note.resource_version_id
    assert note_locator == %{"version" => 1, "kind" => "markdown", "heading_path" => []}
    assert note_time === note_entry.source_inserted_at
    assert note_vector =~ "'note':1A"
    assert note_vector =~ "'body':2"
  end

  test "branch nullability deterministic identities and whole Note provenance cannot bypass typed FKs" do
    source = KnowledgeFixtures.source!()
    note = note_attrs!(KnowledgeFixtures.note!(source))
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    document = document_attrs!(document, fragment)

    for malformed <- [
          %{note | classification: "public"},
          %{note | kind: "asset"},
          %{note | note_resource_version_id: nil},
          %{note | fragment_id: fragment.fragment_id},
          %{note | note_resource_version_id: KnowledgeFixtures.uuid()},
          %{note | ordinal: 1},
          %{note | entry_id: "note:" <> Ecto.UUID.load!(source.resource_version_id)},
          %{note | locator: %{"version" => 1.0, "kind" => "markdown", "heading_path" => []}},
          %{
            note
            | locator: %{"version" => 1, "kind" => "markdown", "heading_path" => ["Heading"]}
          },
          %{
            note
            | locator: %{
                "version" => 1,
                "kind" => "markdown",
                "heading_path" => [],
                "start_line" => 1,
                "end_line" => 1
              }
          },
          %{document | fragment_id: nil},
          %{document | note_resource_version_id: note.resource_version_id},
          %{document | fragment_id: String.upcase(fragment.fragment_id)},
          %{document | ordinal: -1},
          %{document | ordinal: 1},
          %{document | entry_id: "document:" <> String.duplicate("f", 64)},
          %{document | locator: %{"version" => 1, "kind" => "fragment", "ordinal" => 1}},
          %{
            document
            | locator: %{"version" => 2, "kind" => "text", "start_line" => 1, "end_line" => 1}
          }
        ] do
      assert_sql_error(:check_violation, fn -> seed!(malformed) end)
    end
  end

  test "canonical title body projection version and finite source time bounds are enforced" do
    source = KnowledgeFixtures.source!()
    note = note_attrs!(KnowledgeFixtures.note!(source))
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    document = document_attrs!(document, fragment)

    for attrs <- [note, document],
        {field, value} <- [
          title: "",
          title: "   ",
          title: String.duplicate("é", 128),
          projection_version: 0,
          projection_version: 2
        ] do
      assert_sql_error(:check_violation, fn -> seed!(Map.put(attrs, field, value)) end)
    end

    assert_sql_error(:check_violation, fn ->
      seed!(%{note | body: String.duplicate("x ", 524_289)})
    end)

    for body <- [String.duplicate("x ", 32_769), "text\r"] do
      malformed = rebind_document(%{document | body: body})
      assert_sql_error(:check_violation, fn -> seed!(malformed) end)
    end

    assert_sql_error(:check_violation, fn ->
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO content.search_entries (#{Enum.join(@fields, ",")}) VALUES (#{placeholders()})",
          Enum.map(@fields, &Map.fetch!(note, &1))
        )

        query!(
          MigrationRepo,
          "UPDATE content.search_entries SET source_inserted_at = 'infinity' WHERE entry_id=$1",
          [note.entry_id]
        )
      end)
    end)
  end

  test "common version owner resource and typed source references reject forged sources" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    note = note_attrs!(KnowledgeFixtures.note!(source))

    for malformed <- [
          %{note | vault_id: other.vault_id},
          %{note | resource_id: other.resource_id}
        ] do
      assert_sql_error(:foreign_key_violation, fn -> seed!(malformed) end)
    end

    asset_as_note = %{
      note
      | resource_id: source.resource_id,
        resource_version_id: source.resource_version_id,
        note_resource_version_id: source.resource_version_id,
        entry_id: "note:" <> Ecto.UUID.load!(source.resource_version_id)
    }

    assert_sql_error(:foreign_key_violation, fn -> seed!(asset_as_note) end)

    {document, fragment} = KnowledgeFixtures.ready_document!(source)

    absent_fragment =
      document_attrs!(document, fragment)
      |> Map.put(:body, "not retained in canonical fragments")
      |> rebind_document()

    assert_sql_error(:foreign_key_violation, fn -> seed!(absent_fragment) end)
  end

  test "exact canonical content maxima and empty bodies remain accepted" do
    source = KnowledgeFixtures.source!()
    title = String.duplicate("x", 255)

    for body <- ["", String.duplicate("x ", 524_288)] do
      original = KnowledgeFixtures.note!(source)
      note = new_note_version!(original, source.principal_id, title, body)
      entry = note_attrs!(note) |> Map.merge(%{title: title, body: body})
      seed!(entry)

      assert %{rows: [[255, size]]} =
               ScopedRepo.transact(RequestRepo, context(source), fn repo ->
                 query!(
                   repo,
                   "SELECT octet_length(title),octet_length(body) FROM content.search_entries WHERE entry_id=$1",
                   [entry.entry_id]
                 )
               end)

      assert size == byte_size(body)
    end

    for bodies <- [[String.duplicate("x ", 32_768)], ["", "nonempty completion"]] do
      {document, fragment} = ready_document_with_bodies!(source, title, bodies)
      entry = document_attrs!(document, fragment) |> Map.put(:title, title)
      seed!(entry)

      assert %{rows: [[255, size]]} =
               ScopedRepo.transact(RequestRepo, context(source), fn repo ->
                 query!(
                   repo,
                   "SELECT octet_length(title),octet_length(body) FROM content.search_entries WHERE entry_id=$1",
                   [entry.entry_id]
                 )
               end)

      assert size == byte_size(hd(bodies))
    end
  end

  test "each Note resource and each immutable Document fragment has at most one projection" do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    first = note_attrs!(note)
    seed!(first)
    newer = new_note_version!(note, source.principal_id)
    assert_sql_error(:unique_violation, fn -> seed!(note_attrs!(newer)) end)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    entry = document_attrs!(document, fragment)
    seed!(entry)
    assert_sql_error(:unique_violation, fn -> seed!(entry) end)
  end

  test "advancing a Document head preserves an existing immutable version projection" do
    source = KnowledgeFixtures.source!()
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    entry = document_attrs!(document, fragment)
    seed!(entry)
    new_version = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
        [new_version, document.resource_id, source.vault_id]
      )

      KnowledgeFixtures.insert_typed!(%{document | resource_version_id: new_version})

      query!(MigrationRepo, "UPDATE content.resources SET current_version_id=$1 WHERE id=$2", [
        new_version,
        document.resource_id
      ])

      assert %{rows: [[version]]} =
               query!(
                 MigrationRepo,
                 "SELECT resource_version_id FROM content.search_entries WHERE entry_id=$1",
                 [entry.entry_id]
               )

      assert version == document.resource_version_id
    end)
  end

  test "web projection reads require live matching principal and owner context" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    entry = note_attrs!(KnowledgeFixtures.note!(source))
    seed!(entry)

    assert %{rows: []} =
             query!(
               RequestRepo,
               "SELECT entry_id FROM content.search_entries WHERE entry_id=$1",
               [entry.entry_id]
             )

    for scope <- [
          context(other),
          %{principal_id: other.principal_id, vault_id: source.vault_id},
          %{principal_id: source.principal_id, vault_id: other.vault_id}
        ] do
      assert %{rows: []} =
               ScopedRepo.transact(RequestRepo, scope, fn repo ->
                 query!(repo, "SELECT entry_id FROM content.search_entries WHERE entry_id=$1", [
                   entry.entry_id
                 ])
               end)
    end

    assert %{rows: [[id]]} =
             ScopedRepo.transact(RequestRepo, context(source), fn repo ->
               query!(repo, "SELECT entry_id FROM content.search_entries WHERE entry_id=$1", [
                 entry.entry_id
               ])
             end)

    assert id == entry.entry_id
    Fixtures.revoke_membership!(source)

    assert %{rows: []} =
             ScopedRepo.transact(RequestRepo, context(source), fn repo ->
               query!(repo, "SELECT entry_id FROM content.search_entries WHERE entry_id=$1", [
                 entry.entry_id
               ])
             end)
  end

  test "final grants allow web reads only and preserve worker Document and tag mutation denials" do
    for role <- @runtime_roles, table <- ~w(search_entries tags resource_tags) do
      assert %{rows: [[select?, false, false, false]]} =
               query!(
                 RequestRepo,
                 "SELECT has_table_privilege($1,$2,'SELECT'),has_table_privilege($1,$2,'INSERT'),has_table_privilege($1,$2,'UPDATE'),has_table_privilege($1,$2,'DELETE')",
                 [role, "content." <> table]
               )

      assert select? == (role == "singularity_web")
    end

    for role <- @runtime_roles do
      assert %{rows: [[usage?, false]]} =
               query!(
                 RequestRepo,
                 "SELECT has_schema_privilege($1,'search_extensions','USAGE'),has_schema_privilege($1,'search_extensions','CREATE')",
                 [role]
               )

      assert usage? == (role == "singularity_web")

      assert %{rows: [[count]]} =
               query!(
                 RequestRepo,
                 "SELECT count(*) FROM pg_proc WHERE pronamespace='search_extensions'::regnamespace AND has_function_privilege($1,oid,'EXECUTE')",
                 [role]
               )

      assert count == if(role == "singularity_web", do: 2, else: 0)
    end

    source = KnowledgeFixtures.source!()
    entry = note_attrs!(KnowledgeFixtures.note!(source))
    seed!(entry)

    for statement <- [
          "INSERT INTO content.search_entries(entry_id) VALUES($1)",
          "UPDATE content.search_entries SET body='changed' WHERE entry_id=$1",
          "DELETE FROM content.search_entries WHERE entry_id=$1",
          "UPDATE content.tags SET display_value='changed' WHERE vault_id=$1",
          "DELETE FROM content.resource_tags WHERE vault_id=$1"
        ] do
      params =
        if String.contains?(statement, "entry_id"), do: [entry.entry_id], else: [source.vault_id]

      assert_sql_error(:insufficient_privilege, fn ->
        ScopedRepo.transact(RequestRepo, context(source), fn repo ->
          query!(repo, statement, params)
        end)
      end)
    end

    for table <- ~w(search_entries document_versions document_fragments tags resource_tags) do
      assert_sql_error(:insufficient_privilege, fn ->
        ScopedRepo.transact(WorkerRepo, context(source), fn repo ->
          query!(repo, "SELECT 1 FROM content.#{table} LIMIT 1")
        end)
      end)
    end
  end

  test "real web tag and resource tag reads hide missing foreign mismatched and revoked scopes" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    tag_id = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.tags(id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at) VALUES($1,$2,'private','Search tag','search tag',$3,CURRENT_TIMESTAMP)",
        [tag_id, source.vault_id, source.principal_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.resource_tags(resource_id,tag_id,vault_id,classification,inserted_at) VALUES($1,$2,$3,'private',CURRENT_TIMESTAMP)",
        [note.resource_id, tag_id, source.vault_id]
      )
    end)

    for table <- ~w(tags resource_tags) do
      statement = "SELECT vault_id FROM content.#{table} WHERE vault_id=$1"
      assert %{rows: []} = query!(RequestRepo, statement, [source.vault_id])

      assert %{rows: [[owner]]} =
               ScopedRepo.transact(RequestRepo, context(source), fn repo ->
                 query!(repo, statement, [source.vault_id])
               end)

      assert owner == source.vault_id

      for scope <- [
            context(other),
            %{principal_id: other.principal_id, vault_id: source.vault_id},
            %{principal_id: source.principal_id, vault_id: other.vault_id}
          ] do
        assert %{rows: []} =
                 ScopedRepo.transact(RequestRepo, scope, fn repo ->
                   query!(repo, statement, [source.vault_id])
                 end)
      end
    end

    Fixtures.revoke_membership!(source)

    for table <- ~w(tags resource_tags) do
      assert %{rows: []} =
               ScopedRepo.transact(RequestRepo, context(source), fn repo ->
                 query!(repo, "SELECT vault_id FROM content.#{table} WHERE vault_id=$1", [
                   source.vault_id
                 ])
               end)
    end
  end

  test "actual web queries use approved FTS literal similarity and operator functions without support grants" do
    source = KnowledgeFixtures.source!()

    note =
      note_attrs!(KnowledgeFixtures.note!(source))
      |> Map.merge(%{title: "knowledge", body: "plain knowledge body"})

    seed!(note)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.search_entries SET body='updated knowledge body' WHERE entry_id=$1",
        [note.entry_id]
      )
    end)

    assert %{rows: [[id, true]]} =
             ScopedRepo.transact(RequestRepo, context(source), fn repo ->
               query!(
                 repo,
                 """
                 SELECT entry_id, search_extensions.similarity(title,'knowledge') = 1
                 FROM content.search_entries WHERE entry_id=$1
                   AND search_vector @@ plainto_tsquery('simple','knowledge')
                   AND body LIKE '%knowledge%'
                   AND title OPERATOR(search_extensions.%) 'knowledge'
                 """,
                 [note.entry_id]
               )
             end)

    assert id == note.entry_id
  end

  test "forward upgrade preserves canonical sources and legacy grants while adding the projection" do
    assert File.regular?(@migration_path)

    MigrationTestEnvironment.with_database(20_261_008_000_000, fn _environment ->
      source = KnowledgeFixtures.source!()
      note = KnowledgeFixtures.note!(source)
      {document, fragment} = KnowledgeFixtures.ready_document!(source)
      before = canonical_snapshot(note, document)
      grants = legacy_acl_snapshot()

      assert %{rows: [[nil]]} =
               query!(RequestRepo, "SELECT to_regclass('content.search_entries')")

      assert [@migration_version] = run_migration!()
      assert canonical_snapshot(note, document) == before
      assert legacy_acl_snapshot() == grants
      seed!(note_attrs!(note))
      seed!(document_attrs!(document, fragment))

      assert %{rows: [[2]]} =
               ScopedRepo.transact(RequestRepo, context(source), fn repo ->
                 query!(repo, "SELECT count(*) FROM content.search_entries WHERE vault_id=$1", [
                   source.vault_id
                 ])
               end)

      assert [] = run_migration!()
    end)
  end

  for {name, alteration} <- [
        {"missing extension", "DROP EXTENSION pg_trgm"},
        {"wrong extension namespace", "ALTER EXTENSION pg_trgm SET SCHEMA public"},
        {"unsupported extension version",
         "UPDATE pg_catalog.pg_extension SET extversion='1.5' WHERE extname='pg_trgm'"},
        {"wrong extension owner",
         "UPDATE pg_catalog.pg_extension SET extowner=10 WHERE extname='pg_trgm'"},
        {"wrong extension schema owner",
         "ALTER SCHEMA search_extensions OWNER TO singularity_auth_definer"},
        {"wrong extension function owner",
         "ALTER FUNCTION search_extensions.similarity(text,text) OWNER TO singularity_table_owner"},
        {"PUBLIC schema usage", "GRANT USAGE ON SCHEMA search_extensions TO PUBLIC"},
        {"missing function grant option",
         "REVOKE GRANT OPTION FOR EXECUTE ON FUNCTION search_extensions.similarity(text,text) FROM singularity_table_owner"},
        {"PUBLIC function execution",
         "GRANT EXECUTE ON FUNCTION search_extensions.similarity(text,text) TO PUBLIC"},
        {"extra table owner support function execution",
         "GRANT EXECUTE ON FUNCTION search_extensions.show_trgm(text) TO singularity_table_owner"},
        {"worker delegated function execution",
         "GRANT EXECUTE ON FUNCTION search_extensions.similarity(text,text) TO singularity_worker"},
        {"substituted similarity operator",
         "UPDATE pg_catalog.pg_operator SET oprcode='search_extensions.word_similarity_op(text,text)'::regprocedure WHERE oid='search_extensions.%(text,text)'::regoperator"}
      ] do
    @bootstrap_alteration alteration
    test "migration rejects #{name} transactionally without changing the prior catalog" do
      assert File.regular?(@migration_path)

      MigrationTestEnvironment.with_database(20_261_008_000_000, fn environment ->
        admin_sql!(environment.database, @bootstrap_alteration)
        before = bootstrap_snapshot()
        assert_raise Postgrex.Error, fn -> run_migration!() end
        assert bootstrap_snapshot() == before

        assert %{rows: [[nil]]} =
                 query!(RequestRepo, "SELECT to_regclass('content.search_entries')")

        assert %{rows: [[0]]} =
                 migration_query!(
                   "SELECT count(*) FROM public.schema_migrations WHERE version=$1",
                   [@migration_version]
                 )
      end)
    end
  end

  for {name, alteration} <- [
        {"detached gtrgm type", "ALTER EXTENSION pg_trgm DROP TYPE search_extensions.gtrgm"},
        {"detached GIN family",
         "ALTER EXTENSION pg_trgm DROP OPERATOR FAMILY search_extensions.gin_trgm_ops USING gin"},
        {"renamed support function",
         "ALTER FUNCTION search_extensions.show_trgm(text) RENAME TO unexpected_show_trgm"},
        {"extension member outside the controlled namespace",
         "CREATE FUNCTION public.unexpected_extension_member() RETURNS integer LANGUAGE SQL AS 'SELECT 1'; ALTER EXTENSION pg_trgm ADD FUNCTION public.unexpected_extension_member()"}
      ] do
    @bootstrap_alteration alteration
    @tag guard_parity: true
    test "migration rejects #{name} transactionally without changing the prior catalog" do
      MigrationTestEnvironment.with_database(20_261_008_000_000, fn environment ->
        admin_sql!(environment.database, @bootstrap_alteration)
        before = bootstrap_snapshot()
        assert_raise Postgrex.Error, fn -> run_migration!() end
        assert bootstrap_snapshot() == before

        assert %{rows: [[nil]]} =
                 query!(RequestRepo, "SELECT to_regclass('content.search_entries')")

        assert %{rows: [[0]]} =
                 migration_query!(
                   "SELECT count(*) FROM public.schema_migrations WHERE version=$1",
                   [@migration_version]
                 )
      end)
    end
  end

  defp context(source), do: Map.take(source, [:principal_id, :vault_id])
  defp placeholders, do: Enum.map_join(1..length(@fields), ",", &"$#{&1}")

  defp seed!(attrs),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO content.search_entries (#{Enum.join(@fields, ",")}) VALUES (#{placeholders()})",
          Enum.map(@fields, &Map.fetch!(attrs, &1))
        )
      end)

  defp note_attrs!(note) do
    Fixtures.with_owner(fn -> attrs(note, :note, nil) end)
  end

  defp document_attrs!(document, fragment) do
    Fixtures.with_owner(fn -> attrs(document, :document, fragment) end)
  end

  defp attrs(source, kind, fragment) do
    %{rows: [[time]]} =
      query!(MigrationRepo, "SELECT inserted_at FROM content.resource_versions WHERE id=$1", [
        source.resource_version_id
      ])

    %{
      entry_id:
        if(kind == :note,
          do: "note:" <> Ecto.UUID.load!(source.resource_version_id),
          else: "document:" <> fragment.fragment_id
        ),
      vault_id: source.vault_id,
      classification: "private",
      resource_id: source.resource_id,
      resource_version_id: source.resource_version_id,
      kind: Atom.to_string(kind),
      note_resource_version_id: if(kind == :note, do: source.resource_version_id),
      fragment_id: if(fragment, do: fragment.fragment_id),
      ordinal: if(fragment, do: fragment.ordinal, else: 0),
      title: if(kind == :note, do: "Note", else: "Document"),
      body: if(fragment, do: fragment.text, else: "body"),
      locator:
        if(fragment,
          do: SourceLocator.to_map(fragment.locator),
          else: %{"version" => 1, "kind" => "markdown", "heading_path" => []}
        ),
      source_inserted_at: time,
      projection_version: 1
    }
  end

  defp rebind_document(attrs) do
    Fixtures.with_owner(fn ->
      %{rows: [[fragment_id]]} =
        query!(
          MigrationRepo,
          "SELECT content.document_fragment_id($1,$2,$3,sha256(convert_to($4,'UTF8')))",
          [attrs.resource_version_id, attrs.locator, attrs.ordinal, attrs.body]
        )

      %{attrs | fragment_id: fragment_id, entry_id: "document:" <> fragment_id}
    end)
  end

  defp new_note_version!(note, principal_id, title \\ "Note", body \\ "body") do
    version = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
        [version, note.resource_id, note.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id) VALUES($1,$2,$3,'private',$4,$5,$6,$7)",
        [
          version,
          note.resource_id,
          note.vault_id,
          title,
          body,
          principal_id,
          note.resource_version_id
        ]
      )
    end)

    %{note | resource_version_id: version}
  end

  defp ready_document_with_bodies!(source, title, bodies) do
    document = KnowledgeFixtures.document!(source, %{title: title})

    fragments =
      bodies
      |> Enum.with_index()
      |> Enum.map(fn {body, ordinal} ->
        {:ok, fragment} =
          Singularity.Core.DocumentFragment.new(%{
            resource_id: Ecto.UUID.load!(document.resource_id),
            resource_version_id: Ecto.UUID.load!(document.resource_version_id),
            owner_scope_id: Ecto.UUID.load!(document.vault_id),
            classification: :private,
            ordinal: ordinal,
            text: body,
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

      digest = :crypto.hash(:sha256, Enum.join(bodies))

      query!(MigrationRepo, "SELECT content.complete_document_extraction($1,$1,1,$2,$3,'en')", [
        document.resource_version_id,
        payload,
        digest
      ])
    end)

    {document, hd(fragments)}
  end

  defp assert_sql_error(code, fun) do
    error = assert_raise Postgrex.Error, fun
    assert error.postgres.code == code
  end

  defp run_migration! do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@migration_path)
    {:ok, pid} = MigrationRepo.start_link()

    try do
      Ecto.Migrator.run(MigrationRepo, [{@migration_version, @migration}], :up,
        all: true,
        log: false
      )
    after
      Supervisor.stop(pid)
    end
  end

  defp migration_query!(statement, params) do
    {:ok, pid} = MigrationRepo.start_link()

    try do
      query!(MigrationRepo, statement, params)
    after
      Supervisor.stop(pid)
    end
  end

  defp canonical_snapshot(note, document) do
    Fixtures.with_owner(fn ->
      Enum.map(
        [
          "SELECT id,resource_id,vault_id,classification,revision,inserted_at FROM content.resource_versions WHERE id=ANY($1) ORDER BY id",
          "SELECT resource_version_id,title,markdown,inserted_at FROM content.note_versions WHERE resource_version_id=ANY($1) ORDER BY resource_version_id",
          "SELECT resource_version_id,title,state,source_digest,source_object_id,inserted_at FROM content.document_versions WHERE resource_version_id=ANY($1) ORDER BY resource_version_id",
          "SELECT id,resource_version_id,ordinal,text,digest,locator,inserted_at FROM content.document_fragments WHERE resource_version_id=ANY($1) ORDER BY id"
        ],
        &query!(MigrationRepo, &1, [[note.resource_version_id, document.resource_version_id]]).rows
      )
    end)
  end

  defp legacy_acl_snapshot do
    query!(
      RequestRepo,
      "SELECT relname,relacl::text FROM pg_class WHERE relnamespace='content'::regnamespace AND relname=ANY($1) ORDER BY relname",
      [
        ~w(note_versions note_conflicts note_search_documents note_mutation_receipts document_versions document_fragments)
      ]
    ).rows
  end

  defp bootstrap_snapshot do
    Enum.map(
      [
        "SELECT extowner,extnamespace,extversion FROM pg_extension WHERE extname='pg_trgm'",
        "SELECT nspowner,nspacl::text FROM pg_namespace WHERE nspname='search_extensions'",
        "SELECT oid,proname,pronamespace,proowner,proacl::text FROM pg_proc WHERE pronamespace=(SELECT oid FROM pg_namespace WHERE nspname='search_extensions') OR oid IN (SELECT objid FROM pg_depend WHERE classid='pg_proc'::regclass AND refclassid='pg_extension'::regclass AND refobjid=(SELECT oid FROM pg_extension WHERE extname='pg_trgm') AND deptype='e') ORDER BY oid",
        "SELECT oid,oprcode FROM pg_operator WHERE oprnamespace=(SELECT oid FROM pg_namespace WHERE nspname='search_extensions') ORDER BY oid",
        "SELECT classid,objid,objsubid,deptype FROM pg_depend WHERE refclassid='pg_extension'::regclass AND refobjid=(SELECT oid FROM pg_extension WHERE extname='pg_trgm') ORDER BY classid,objid,objsubid,deptype",
        "SELECT oid,typname,typowner,typarray,typelem FROM pg_type WHERE typnamespace=(SELECT oid FROM pg_namespace WHERE nspname='search_extensions') ORDER BY oid",
        "SELECT oid,opcname,opcowner,opcfamily,opcmethod,opcintype FROM pg_opclass WHERE opcnamespace=(SELECT oid FROM pg_namespace WHERE nspname='search_extensions') ORDER BY oid",
        "SELECT oid,opfname,opfowner,opfmethod FROM pg_opfamily WHERE opfnamespace=(SELECT oid FROM pg_namespace WHERE nspname='search_extensions') ORDER BY oid",
        "SELECT relname,relacl::text FROM pg_class WHERE relnamespace='content'::regnamespace AND relname IN ('tags','resource_tags') ORDER BY relname"
      ],
      &query!(RequestRepo, &1).rows
    )
  end

  defp admin_sql!(database, statement) do
    helper =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/bootstrap_roles.exs")

    shell = """
    set -euo pipefail
    service="$(elixir "$1" 2>/dev/null)"
    exec 9< <(printf '%s\\n' "$service")
    unset service SINGULARITY_ROLE_PROVISIONER_DATABASE_URL
    PGSERVICEFILE=/dev/fd/9 PGSERVICE=singularity_role_provisioner \
      exec psql --no-psqlrc --set=ON_ERROR_STOP=1 --dbname="$2" --command="$3"
    """

    assert {_output, 0} =
             System.cmd(
               "bash",
               ["-c", shell, "search-projection-fixture", helper, database, statement],
               stderr_to_stdout: true
             )
  end
end
