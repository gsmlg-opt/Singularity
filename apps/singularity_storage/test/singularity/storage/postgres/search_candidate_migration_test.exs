defmodule Singularity.Storage.Postgres.SearchCandidateMigrationTest do
  use Singularity.Storage.DataCase, async: false

  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, MigrationTestEnvironment}
  alias Singularity.Storage.{SafeSQL, ScopedRepo}
  alias Singularity.Storage.Postgres.KnowledgeSearchStore

  @migration Singularity.Storage.Migrations.CreateGuardedSearchCandidates
  @migration_version 20_261_010_000_000
  @predecessor 20_261_009_000_400
  @signature "content.search_candidate_ids(text,text,uuid[])"
  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20261010000000_create_guarded_search_candidates.exs",
                    __DIR__
                  )
  @roles ~w(singularity_table_owner singularity_auth_definer singularity_authorization_definer singularity_outbox_definer singularity_migration singularity_web singularity_worker singularity_dispatcher singularity_pre_auth)

  test "guarded candidate downgrade refuses before performing any database operation" do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@migration_path)

    assert_raise Ecto.MigrationError, "Guarded search candidates migration is forward-only", fn ->
      apply(@migration, :down, [])
    end
  end

  @tag :integration
  test "fresh candidate catalog matches the exact compiled literal and fixed authority" do
    assert_catalog!()
  end

  @tag :integration
  test "populated predecessor upgrade adds only the function and preserves immutable search sources" do
    latest_configs =
      Enum.map([MigrationRepo, RequestRepo, PreAuthRepo, DispatcherRepo, WorkerRepo], fn repo ->
        {repo, Application.fetch_env(:singularity_storage, repo)}
      end)

    latest_head = migration_head()
    assert latest_head > @migration_version
    latest_catalog = assert_catalog!()
    latest_security = security_snapshot()
    latest_relations = relation_storage_snapshot()

    MigrationTestEnvironment.with_database(@migration_version, fn _environment ->
      assert migration_head() == @migration_version
      fresh_catalog = assert_catalog!()
      fresh_security = security_snapshot()
      fresh = fixture!()
      fresh_rows = data_snapshot(fresh.source)
      assert_write_denials(fresh.source)
      fresh_page = search!(fresh, "o")
      assert_exact_sources(fresh_page, fresh)
      assert Enum.all?(fresh_page.items, &(&1.rank > 0))
      fresh_ranks = ranks_by_kind(fresh_page)
      assert data_snapshot(fresh.source) == fresh_rows

      MigrationTestEnvironment.with_database(@predecessor, fn _environment ->
        fixture = fixture!()
        before_rows = data_snapshot(fixture.source)
        before_security = security_snapshot()
        before_relations = relation_storage_snapshot()
        assert_write_denials(fixture.source)
        assert before_security == fresh_security

        assert migration_head() == @predecessor

        assert %{rows: [[nil]]} =
                 private_query!(RequestRepo, "SELECT to_regprocedure($1)::text", [@signature])

        assert missing_candidate?(fixture)
        before_page = search!(fixture, "")
        assert_exact_sources(before_page, fixture)
        assert Enum.all?(before_page.items, &(&1.rank == 0))
        assert data_snapshot(fixture.source) == before_rows

        assert [@migration_version] = upgrade!()
        assert assert_catalog!() == fresh_catalog
        assert security_snapshot() == before_security
        assert relation_storage_snapshot() == before_relations
        assert data_snapshot(fixture.source) == before_rows

        assert candidate_ids(fixture) == Enum.sort(Enum.map(before_page.items, & &1.entry_id))
        assert_write_denials(fixture.source)
        after_page = search!(fixture, "o")
        assert_exact_sources(after_page, fixture)
        assert Enum.all?(after_page.items, &(&1.rank > 0))
        assert ranks_by_kind(after_page) == fresh_ranks
        assert without_ranks(after_page) == without_ranks(before_page)
        assert data_snapshot(fixture.source) == before_rows

        assert [] = upgrade!()
        assert assert_catalog!() == fresh_catalog
        assert security_snapshot() == before_security
        assert relation_storage_snapshot() == before_relations
        assert data_snapshot(fixture.source) == before_rows
      end)

      assert assert_catalog!() == fresh_catalog
      assert security_snapshot() == fresh_security
      assert data_snapshot(fresh.source) == fresh_rows
      assert search!(fresh, "o") == fresh_page
      assert migration_head() == @migration_version
    end)

    assert Enum.map(latest_configs, fn {repo, _config} ->
             {repo, Application.fetch_env(:singularity_storage, repo)}
           end) == latest_configs

    assert migration_head() == latest_head
    assert assert_catalog!() == latest_catalog
    assert security_snapshot() == latest_security
    assert relation_storage_snapshot() == latest_relations
  end

  defp fixture! do
    source = KnowledgeFixtures.source!()
    note = KnowledgeFixtures.note!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)

    Fixtures.with_owner(fn ->
      names = ["note.read", "asset.read"]

      for name <- names do
        private_query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid(), name]
        )
      end

      assert %{num_rows: 2} =
               private_query!(
                 MigrationRepo,
                 """
                 INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id)
                 SELECT $1,$2,id FROM core.capabilities WHERE name=ANY($3::text[])
                 ON CONFLICT(principal_id,vault_id,capability_id) DO NOTHING
                 """,
                 [source.principal_id, source.vault_id, names]
               )

      for resource <- [note, document] do
        assert %{rows: [[1]]} =
                 private_query!(
                   MigrationRepo,
                   "SELECT content.reconcile_search_resource_internal($1,$2)",
                   [source.vault_id, resource.resource_id]
                 )
      end
    end)

    %{source: source, note: note, document: document, fragment: fragment}
  end

  defp search!(fixture, q) do
    source = fixture.source

    query = %{
      owner_scope_id: Ecto.UUID.load!(source.vault_id),
      classification: :private,
      q: q,
      kind: :all,
      tag_ids: [],
      limit: 20,
      cursor: nil,
      policy_version: 1
    }

    case ScopedRepo.transact(RequestRepo, Map.take(source, [:principal_id, :vault_id]), fn repo ->
           KnowledgeSearchStore.search(repo, query)
         end) do
      {:ok, page} -> page
      _other -> flunk("candidate migration Store control failed (contents withheld)")
    end
  end

  defp candidate_ids(fixture) do
    ScopedRepo.transact(
      RequestRepo,
      Map.take(fixture.source, [:principal_id, :vault_id]),
      fn repo ->
        private_query!(
          repo,
          "SELECT entry_id FROM content.search_candidate_ids('o','all',ARRAY[]::uuid[]) ORDER BY entry_id COLLATE \"C\""
        ).rows
        |> Enum.map(&hd/1)
      end
    )
  end

  defp missing_candidate?(fixture) do
    result =
      ScopedRepo.transact(
        RequestRepo,
        Map.take(fixture.source, [:principal_id, :vault_id]),
        fn repo ->
          case SafeSQL.query(
                 repo,
                 "SELECT entry_id FROM content.search_candidate_ids('o','all',ARRAY[]::uuid[])"
               ) do
            {:error, %Postgrex.Error{postgres: %{code: :undefined_function, pg_code: "42883"}}} ->
              {:error, :candidate_missing}

            _other ->
              {:error, :unexpected_candidate_result}
          end
        end
      )

    result == {:error, :candidate_missing}
  end

  defp assert_exact_sources(page, fixture) do
    assert page.next_cursor == :done
    assert length(page.items) == 2
    items = Map.new(page.items, &{&1.kind, &1})
    note = Map.fetch!(items, :note)
    document = Map.fetch!(items, :document)
    assert note.entry_id == "note:" <> Ecto.UUID.load!(fixture.note.resource_version_id)
    assert note.resource_id == Ecto.UUID.load!(fixture.note.resource_id)
    assert note.resource_version_id == Ecto.UUID.load!(fixture.note.resource_version_id)
    assert note.fragment_id == nil
    assert note.ordinal == 0
    assert note.title == "Note" and note.snippet == "body"
    assert note.locator == %{"version" => 1, "kind" => "markdown", "heading_path" => []}
    assert document.entry_id == "document:" <> fixture.fragment.fragment_id
    assert document.resource_id == Ecto.UUID.load!(fixture.document.resource_id)
    assert document.resource_version_id == Ecto.UUID.load!(fixture.document.resource_version_id)
    assert document.fragment_id == fixture.fragment.fragment_id
    assert document.ordinal == fixture.fragment.ordinal
    assert document.title == "Document" and document.snippet == fixture.fragment.text
    assert document.locator == Singularity.Core.SourceLocator.to_map(fixture.fragment.locator)

    for item <- page.items do
      assert item.owner_scope_id == Ecto.UUID.load!(fixture.source.vault_id)
      assert item.classification == :private
      assert %DateTime{} = item.source_inserted_at
      assert is_integer(item.rank) and item.rank >= 0
    end
  end

  defp ranks_by_kind(page), do: Map.new(page.items, &{&1.kind, &1.rank})

  defp without_ranks(page),
    do: page.items |> Enum.map(&Map.delete(&1, :rank)) |> Enum.sort_by(& &1.entry_id)

  defp assert_write_denials(source) do
    for {repo, role} <- [
          {RequestRepo, "singularity_web"},
          {WorkerRepo, "singularity_worker"},
          {DispatcherRepo, "singularity_dispatcher"},
          {PreAuthRepo, "singularity_pre_auth"}
        ] do
      assert %{rows: [[^role, ^role]]} = private_query!(repo, "SELECT session_user,current_user")

      for {sql, params} <- [
            {"INSERT INTO content.search_entries DEFAULT VALUES", []},
            {"UPDATE content.search_entries SET title=title WHERE vault_id=$1",
             [source.vault_id]},
            {"DELETE FROM content.search_entries WHERE vault_id=$1", [source.vault_id]}
          ] do
        result =
          ScopedRepo.transact(repo, Map.take(source, [:principal_id, :vault_id]), fn scoped ->
            # Both outcomes roll back. A regressed grant must not mutate the fixture.
            case SafeSQL.query(scoped, sql, params) do
              {:error,
               %Postgrex.Error{postgres: %{code: :insufficient_privilege, pg_code: "42501"}}} ->
                {:error, :write_denied}

              _other ->
                {:error, :unexpected_write_result}
            end
          end)

        assert result == {:error, :write_denied}
      end
    end
  end

  defp assert_catalog! do
    %{rows: rows} =
      private_query!(
        RequestRepo,
        """
        SELECT owner.rolname,language.lanname,p.prosecdef,p.provolatile::text,p.proparallel::text,
               p.proisstrict,p.proretset,pg_get_function_identity_arguments(p.oid),
               pg_get_function_result(p.oid),
               ARRAY(SELECT setting FROM unnest(p.proconfig) AS setting ORDER BY setting COLLATE "C"),
               ARRAY(SELECT COALESCE(grantee.rolname,'PUBLIC') || ':' || grantor.rolname || ':' ||
                            acl.privilege_type || ':' || acl.is_grantable::text
                     FROM aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) AS acl
                     LEFT JOIN pg_roles AS grantee ON grantee.oid=acl.grantee
                     JOIN pg_roles AS grantor ON grantor.oid=acl.grantor
                     ORDER BY COALESCE(grantee.rolname,'PUBLIC') COLLATE "C",acl.privilege_type),p.prosrc
        FROM pg_proc AS p JOIN pg_roles AS owner ON owner.oid=p.proowner
        JOIN pg_language AS language ON language.oid=p.prolang
        WHERE p.oid=to_regprocedure($1)
        """,
        [@signature]
      )

    {header, source_digest} =
      case rows do
        [row] when length(row) == 12 ->
          {Enum.take(row, 11), digest(String.trim(List.last(row)))}

        _other ->
          flunk("candidate migration catalog missing (contents withheld)")
      end

    assert header == [
             "singularity_table_owner",
             "plpgsql",
             true,
             "v",
             "u",
             false,
             true,
             "requested_q text, requested_kind text, requested_tag_ids uuid[]",
             "TABLE(entry_id text)",
             [
               "pg_trgm.similarity_threshold=0.3",
               "search_path=pg_catalog, content, core, identity, pg_temp"
             ],
             [
               "singularity_table_owner:singularity_table_owner:EXECUTE:false",
               "singularity_web:singularity_table_owner:EXECUTE:false"
             ]
           ]

    assert source_digest == literal_body_digest()

    assert %{rows: [[@signature]]} =
             private_query!(RequestRepo, """
             SELECT p.oid::regprocedure::text FROM pg_proc AS p
             JOIN pg_namespace AS n ON n.oid=p.pronamespace
             WHERE n.nspname='content' AND p.proname LIKE 'search_candidate%'
             ORDER BY p.oid::regprocedure::text COLLATE "C"
             """)

    %{header: header, source: source_digest}
  end

  defp literal_body_digest do
    {:ok, ast} = @migration_path |> File.read!() |> Code.string_to_quoted()

    {_ast, creates} =
      Macro.prewalk(ast, [], fn
        {:execute, _, [sql]} = node, found when is_binary(sql) ->
          if String.starts_with?(
               String.trim(sql),
               "CREATE FUNCTION content.search_candidate_ids("
             ),
             do: {node, [sql | found]},
             else: {node, found}

        node, found ->
          {node, found}
      end)

    case creates do
      [sql] ->
        case String.split(sql, "$function$") do
          [_header, body, _end] -> digest(String.trim(body))
          _other -> flunk("candidate migration literal delimiter contract changed")
        end

      _other ->
        flunk("candidate migration must contain one literal CREATE statement")
    end
  end

  defp security_snapshot do
    queries = [
      {"roles",
       "SELECT rolname,rolcanlogin,rolsuper,rolcreatedb,rolcreaterole,rolinherit,rolbypassrls,rolreplication FROM pg_roles WHERE rolname=ANY($1::text[]) ORDER BY rolname COLLATE \"C\"",
       [@roles]},
      {"memberships",
       "SELECT granted.rolname,member.rolname,m.admin_option,m.inherit_option,m.set_option FROM pg_auth_members AS m JOIN pg_roles AS granted ON granted.oid=m.roleid JOIN pg_roles AS member ON member.oid=m.member WHERE granted.rolname=ANY($1::text[]) OR member.rolname=ANY($1::text[]) ORDER BY granted.rolname COLLATE \"C\",member.rolname COLLATE \"C\"",
       [@roles]},
      {"relation",
       "SELECT pg_get_userbyid(relowner),relrowsecurity,relforcerowsecurity FROM pg_class WHERE oid='content.search_entries'::regclass",
       []},
      {"policies",
       "SELECT policyname,permissive,roles,cmd,qual,with_check FROM pg_policies WHERE schemaname='content' AND tablename='search_entries' ORDER BY policyname COLLATE \"C\"",
       []},
      {"grants",
       "SELECT role,has_table_privilege(role,'content.search_entries','SELECT'),has_table_privilege(role,'content.search_entries','INSERT'),has_table_privilege(role,'content.search_entries','UPDATE'),has_table_privilege(role,'content.search_entries','DELETE') FROM unnest($1::text[]) AS role ORDER BY role COLLATE \"C\"",
       [@roles]},
      {"indexes",
       "SELECT c.relname,i.indisvalid,i.indisready,pg_get_indexdef(i.indexrelid) FROM pg_index AS i JOIN pg_class AS c ON c.oid=i.indexrelid WHERE i.indrelid='content.search_entries'::regclass ORDER BY c.relname COLLATE \"C\"",
       []},
      {"functions",
       "SELECT p.oid::regprocedure::text,pg_get_userbyid(p.proowner),pg_get_functiondef(p.oid),p.proacl::text FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid=p.pronamespace WHERE n.nspname <> 'information_schema' AND n.nspname !~ '^pg_' AND p.prosecdef AND p.oid IS DISTINCT FROM to_regprocedure($1) ORDER BY p.oid::regprocedure::text COLLATE \"C\"",
       [@signature]}
    ]

    Map.new(queries, fn {name, sql, params} ->
      rows = private_query!(RequestRepo, sql, params).rows
      {name, %{count: length(rows), digest: digest(:erlang.term_to_binary(rows))}}
    end)
  end

  defp relation_storage_snapshot do
    rows =
      private_query!(RequestRepo, """
      SELECT relation.relname,relation.relkind::text,relation.relfilenode::bigint
      FROM pg_class AS relation JOIN pg_namespace AS namespace ON namespace.oid=relation.relnamespace
      WHERE namespace.nspname='content' AND relation.relkind IN ('r','i','m')
      ORDER BY relation.relname COLLATE "C",relation.relkind
      """).rows

    %{count: length(rows), digest: digest(:erlang.term_to_binary(rows))}
  end

  defp data_snapshot(source) do
    Fixtures.with_owner(fn ->
      tables =
        ~w(content.resources content.resource_versions content.note_versions content.document_versions content.document_fragments content.resource_assets content.asset_objects content.assets content.tags content.resource_tags content.search_entries core.outbox_events jobs.job_submissions)

      Map.new(tables, fn table ->
        rows =
          private_query!(
            MigrationRepo,
            "SELECT to_jsonb(canonical)::text FROM " <>
              table <>
              " AS canonical WHERE vault_id=$1 ORDER BY to_jsonb(canonical)::text COLLATE \"C\"",
            [source.vault_id]
          ).rows

        {table, %{count: length(rows), digest: digest(:erlang.term_to_binary(rows))}}
      end)
    end)
  end

  defp migration_head do
    {:ok, owned} = MigrationRepo.start_link()

    try do
      case private_query!(MigrationRepo, "SELECT max(version) FROM public.schema_migrations") do
        %{rows: [[version]]} when is_integer(version) -> version
        _other -> flunk("candidate migration predecessor is missing")
      end
    after
      Supervisor.stop(owned)
    end
  end

  defp upgrade! do
    {:ok, owned} = MigrationRepo.start_link()
    previous = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      Ecto.Migrator.run(MigrationRepo, Path.dirname(@migration_path), :up,
        to: @migration_version,
        log: false
      )
    after
      try do
        Code.compiler_options(previous)
      after
        Supervisor.stop(owned)
      end
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value)

  defp private_query!(repo, sql, params \\ []) do
    case SafeSQL.query(repo, sql, params) do
      {:ok, %{rows: rows, num_rows: count}} -> %{rows: rows, num_rows: count}
      _other -> flunk("candidate migration query failed (contents withheld)")
    end
  end
end
