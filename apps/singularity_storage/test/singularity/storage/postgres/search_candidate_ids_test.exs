defmodule Singularity.Storage.Postgres.SearchCandidateIdsTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.{DocumentFragment, SourceLocator}
  alias Singularity.Storage.Postgres.KnowledgeSearchStore

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    MigrationRepo,
    MigrationTestEnvironment,
    SafeSQL,
    ScopedRepo
  }

  @owner_roles ~w(singularity_table_owner singularity_auth_definer singularity_authorization_definer singularity_outbox_definer)
  @runtime_roles ~w(singularity_pre_auth singularity_web singularity_dispatcher singularity_worker)
  @signature "content.search_candidate_ids(text,text,uuid[])"
  @invalid {:error, {:check_violation, "search candidates input is invalid", {false, false}}}
  @denied {:error,
           {:insufficient_privilege, "search candidates are not authorized", {false, false}}}

  test "real web reads only canonical Note and ready Document identities" do
    source = source!()
    note = KnowledgeFixtures.note!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    project!(source, [note, document])

    assert {:ok, %{rows: [["singularity_web", "singularity_web"]]}} =
             query(RequestRepo, "SELECT session_user,current_user")

    expected =
      Enum.sort([
        ["note:" <> Ecto.UUID.load!(note.resource_version_id)],
        ["document:" <> fragment.fragment_id]
      ])

    assert candidates(source, "o", "all") == {:ok, expected}
  end

  for {kind, capability} <- [{"note", "note.read"}, {"document", "asset.read"}] do
    @kind kind
    @capability capability

    test "real web #{@kind} candidates require only #{@capability}" do
      source = source!([@capability])
      note = KnowledgeFixtures.note!(source)
      {document, fragment} = KnowledgeFixtures.ready_document!(source)
      project!(source, [note, document])

      entry =
        Map.fetch!(
          %{
            "note" => "note:" <> Ecto.UUID.load!(note.resource_version_id),
            "document" => "document:" <> fragment.fragment_id
          },
          @kind
        )

      assert candidates(source, "o", @kind) == {:ok, [[entry]]}
    end
  end

  for capability <- ["note.read", "asset.read"] do
    @capability capability

    test "all-kind candidates reject #{@capability} without the other read capability" do
      source = source!([@capability])
      note = KnowledgeFixtures.note!(source)
      {document, _fragment} = KnowledgeFixtures.ready_document!(source)
      project!(source, [note, document])

      assert candidates(source, "o", "all") ==
               {:error,
                {:insufficient_privilege, "search candidates are not authorized", {false, false}}}
    end
  end

  test "kind reads require read assignments rather than write capabilities" do
    for {kind, capabilities} <- [
          {"note", []},
          {"document", []},
          {"all", []},
          {"note", ["note.write"]},
          {"document", ["asset.write"]},
          {"all", ["note.write", "asset.write"]}
        ] do
      source = source!(capabilities)
      note = KnowledgeFixtures.note!(source)
      {document, _fragment} = KnowledgeFixtures.ready_document!(source)
      project!(source, [note, document])

      assert candidates(source, "o", kind) ==
               {:error,
                {:insufficient_privilege, "search candidates are not authorized", {false, false}}}
    end
  end

  for {repo, role} <- [
        {WorkerRepo, "singularity_worker"},
        {DispatcherRepo, "singularity_dispatcher"},
        {PreAuthRepo, "singularity_pre_auth"}
      ] do
    @repo repo
    @role role

    test "actual #{@role} login cannot execute candidate selection" do
      source = source!()
      note = KnowledgeFixtures.note!(source)
      {document, _fragment} = KnowledgeFixtures.ready_document!(source)
      project!(source, [note, document])

      assert {:ok, %{rows: [[@role, @role]]}} =
               query(@repo, "SELECT session_user,current_user")

      assert candidates(@repo, source, "o", "all") == {:error, :candidate_execute_denied}
    end
  end

  test "candidate function has only the fixed IDs-only hardened catalog and exact ACL" do
    assert {:ok, %{rows: rows}} =
             query(
               RequestRepo,
               """
               SELECT owner.rolname,language.lanname,procedure.prosecdef,
                      procedure.provolatile::text,procedure.proparallel::text,
                      procedure.proisstrict,procedure.proretset,
                      pg_get_function_identity_arguments(procedure.oid),
                      pg_get_function_result(procedure.oid),
                      ARRAY(SELECT setting FROM unnest(procedure.proconfig) AS setting
                            ORDER BY setting COLLATE "C")
               FROM pg_proc AS procedure
               JOIN pg_roles AS owner ON owner.oid=procedure.proowner
               JOIN pg_language AS language ON language.oid=procedure.prolang
               WHERE procedure.oid=to_regprocedure($1)
               """,
               [@signature]
             )

    assert rows == [
             [
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
               ]
             ]
           ]

    assert {:ok, %{rows: [[@signature]]}} =
             query(RequestRepo, """
             SELECT procedure.oid::regprocedure::text
             FROM pg_proc AS procedure
             JOIN pg_namespace AS namespace ON namespace.oid=procedure.pronamespace
             WHERE namespace.nspname='content' AND procedure.proname LIKE 'search_candidate%'
             ORDER BY procedure.oid::regprocedure::text COLLATE "C"
             """)

    assert {:ok, %{rows: privileges}} =
             query(
               RequestRepo,
               """
               SELECT COALESCE(grantee.rolname,'PUBLIC'),grantor.rolname,
                      acl.privilege_type,acl.is_grantable
               FROM pg_proc AS procedure
               CROSS JOIN LATERAL aclexplode(COALESCE(procedure.proacl,
                 acldefault('f',procedure.proowner))) AS acl
               LEFT JOIN pg_roles AS grantee ON grantee.oid=acl.grantee
               JOIN pg_roles AS grantor ON grantor.oid=acl.grantor
               WHERE procedure.oid=to_regprocedure($1)
               ORDER BY COALESCE(grantee.rolname,'PUBLIC') COLLATE "C",acl.privilege_type
               """,
               [@signature]
             )

    assert privileges == [
             ["singularity_table_owner", "singularity_table_owner", "EXECUTE", false],
             ["singularity_web", "singularity_table_owner", "EXECUTE", false]
           ]
  end

  test "candidate reads preserve established role RLS grant and content-index baselines" do
    baseline = security_snapshot()
    assert_security_baseline(baseline)

    source = source!()
    note = KnowledgeFixtures.note!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    project!(source, [note, document])
    result = candidates(source, "o", "all")

    assert security_snapshot() == baseline

    assert result ==
             {:ok,
              Enum.sort([
                ["note:" <> Ecto.UUID.load!(note.resource_version_id)],
                ["document:" <> fragment.fragment_id]
              ])}
  end

  test "fresh migration preserves exact predecessor security and adds only one privileged function" do
    latest_configs =
      Enum.map([MigrationRepo, RequestRepo, PreAuthRepo, DispatcherRepo, WorkerRepo], fn repo ->
        {repo, Application.fetch_env(:singularity_storage, repo)}
      end)

    migration_head = fn ->
      {:ok, owned} = MigrationRepo.start_link()

      try do
        %{rows: [[head]]} =
          query!(MigrationRepo, "SELECT max(version) FROM public.schema_migrations")

        head
      after
        Supervisor.stop(owned)
      end
    end

    latest_head = migration_head.()
    assert latest_head > 20_261_010_000_000
    latest_security = security_snapshot()
    latest_functions = privileged_function_inventory()

    catalog_sql =
      "SELECT pg_get_functiondef(oid),pg_get_userbyid(proowner),proacl::text FROM pg_proc WHERE oid=$1::text::regprocedure"

    latest_catalog = query!(RequestRepo, catalog_sql, [@signature]).rows

    MigrationTestEnvironment.with_database(20_261_010_000_000, fn _environment ->
      assert migration_head.() == 20_261_010_000_000
      fresh_security = security_snapshot()
      fresh_functions = privileged_function_inventory()

      MigrationTestEnvironment.with_database(20_261_009_000_400, fn _environment ->
        assert {:ok, %{rows: [[nil]]}} =
                 query(RequestRepo, "SELECT to_regprocedure($1)::text", [@signature])

        predecessor_security = security_snapshot()
        predecessor_functions = privileged_function_inventory()

        assert_security_baseline(predecessor_security)
        assert fresh_security == predecessor_security

        assert fresh_functions ==
                 Enum.sort(predecessor_functions ++ [[@signature, "singularity_table_owner"]])
      end)

      assert security_snapshot() == fresh_security
      assert privileged_function_inventory() == fresh_functions
      assert migration_head.() == 20_261_010_000_000
    end)

    assert Enum.map(latest_configs, fn {repo, _config} ->
             {repo, Application.fetch_env(:singularity_storage, repo)}
           end) == latest_configs

    assert migration_head.() == latest_head
    assert security_snapshot() == latest_security
    assert privileged_function_inventory() == latest_functions
    assert query!(RequestRepo, catalog_sql, [@signature]).rows == latest_catalog
  end

  test "direct input rejects null oversized unknown and malformed array boundaries" do
    control = control!()
    tag = KnowledgeFixtures.uuid()
    snapshot = canonical_snapshot(control.source)
    assert_control(control)

    for {q, kind, tags} <- [
          {nil, "all", []},
          {"", "all", []},
          {:binary.copy("x", 1_025), "all", []},
          {String.duplicate("猫", 341) <> "xy", "all", []},
          {"o", nil, []},
          {"o", "asset", []},
          {"o", "all", nil},
          {"o", "all", [[tag], [tag]]},
          {"o", "all", [nil]},
          {"o", "all", List.duplicate(tag, 21)}
        ] do
      assert candidates(RequestRepo, control.source, q, kind, tags) == @invalid
      assert_control(control)
    end

    assert canonical_snapshot(control.source) == snapshot
  end

  test "direct UTF-8 q accepts exactly 1024 bytes and rejects 1025 without canonical mutation" do
    source = source!()
    q = String.duplicate("猫", 341) <> "x"
    assert byte_size(q) == 1_024
    note = literal_note!(source, "Neutral heading", q)
    project!(source, [note])
    snapshot = canonical_snapshot(source)
    expected = {:ok, [["note:" <> Ecto.UUID.load!(note.resource_version_id)]]}

    assert candidates(source, q, "note") == expected
    assert candidates(source, q <> "y", "note") == @invalid
    assert candidates(source, q, "note") == expected
    assert canonical_snapshot(source) == snapshot
  end

  test "empty tags and twenty repeated canonical tag IDs are valid before the raw cap" do
    control = control!()
    tag = tagged_note!(control.source, control.note)
    snapshot = canonical_snapshot(control.source)
    expected = {:ok, [["note:" <> Ecto.UUID.load!(control.note.resource_version_id)]]}

    assert_control(control)

    assert candidates(RequestRepo, control.source, "o", "all", List.duplicate(tag, 20)) ==
             expected

    assert candidates(RequestRepo, control.source, "o", "all", List.duplicate(tag, 21)) ==
             @invalid

    assert candidates(RequestRepo, control.source, "o", "all", [tag]) == expected
    assert_control(control)
    assert canonical_snapshot(control.source) == snapshot
  end

  test "direct substring matching treats backslash percent and underscore as literal bytes" do
    source = source!()
    needles = ["\\", "%", "_"]

    notes =
      Enum.map(needles, &literal_note!(source, "Neutral heading", "literal " <> &1 <> " mark"))

    project!(source, notes)
    snapshot = canonical_snapshot(source)

    for {q, note} <- Enum.zip(needles, notes) do
      assert candidates(source, q, "note") ==
               {:ok, [["note:" <> Ecto.UUID.load!(note.resource_version_id)]]}
    end

    assert canonical_snapshot(source) == snapshot
  end

  test "raw real-web GUC failures reach the function guard and leave a clean independent transaction" do
    control = control!()
    principal = Ecto.UUID.load!(control.source.principal_id)
    owner = Ecto.UUID.load!(control.source.vault_id)
    snapshot = canonical_snapshot(control.source)
    assert_control(control)

    for context <- [
          nil,
          {nil, owner},
          {principal, nil},
          {"", ""},
          {"", owner},
          {principal, ""},
          {"malformed-principal", owner},
          {principal, "malformed-owner"}
        ] do
      assert raw_candidates(context) == @denied
      assert_control(control)
    end

    assert canonical_snapshot(control.source) == snapshot
  end

  test "real scoped repeatable-read transaction is rejected rather than returning stale success" do
    control = control!()
    snapshot = canonical_snapshot(control.source)
    assert_control(control)

    assert ScopedRepo.transact(
             RequestRepo,
             Map.take(control.source, [:principal_id, :vault_id]),
             [isolation: :repeatable_read],
             fn repo -> candidate_query(repo, "o", "all", []) end
           ) == @denied

    assert_control(control)
    assert canonical_snapshot(control.source) == snapshot
  end

  test "raw serializable transaction sets isolation first and fails with the fixed guard error" do
    control = control!()

    context =
      {Ecto.UUID.load!(control.source.principal_id), Ecto.UUID.load!(control.source.vault_id)}

    snapshot = canonical_snapshot(control.source)
    assert_control(control)
    assert raw_candidates(context, :serializable) == @denied
    assert_control(control)
    assert canonical_snapshot(control.source) == snapshot
  end

  for authority <- [
        :wrong_owner,
        :non_owner,
        :inactive_account,
        :revoked_principal,
        :revoked_membership,
        :revoked_capability
      ] do
    @authority authority

    test "actual #{@authority} authority cannot read matching canonical candidates" do
      control = control!()
      snapshot = canonical_snapshot(control.source)
      assert_control(control)
      rejected_scope = reject_authority!(control.source, @authority)

      assert candidates(rejected_scope, "o", "all") == @denied
      assert canonical_snapshot(control.source) == snapshot
      assert_control(control!())
    end
  end

  test "immutable membership constraint rejects public clearance without changing private authority" do
    control = control!()
    snapshot = canonical_snapshot(control.source)
    membership = private_membership_snapshot(control.source)
    assert_control(control)

    result =
      Fixtures.with_owner(fn ->
        assert {:ok, _result} = query(MigrationRepo, "SAVEPOINT candidate_public_clearance")

        result =
          query(
            MigrationRepo,
            "UPDATE core.vault_members SET clearance='public' WHERE principal_id=$1 AND vault_id=$2",
            [control.source.principal_id, control.source.vault_id]
          )

        assert {:ok, _result} =
                 query(MigrationRepo, "ROLLBACK TO SAVEPOINT candidate_public_clearance")

        assert {:ok, _result} =
                 query(MigrationRepo, "RELEASE SAVEPOINT candidate_public_clearance")

        result
      end)

    assert result == {:error, {:check_violation, "23514", "vault_members_classification_check"}}
    assert private_membership_snapshot(control.source) == membership
    assert_control(control)
    assert canonical_snapshot(control.source) == snapshot
    assert_control(control!())
  end

  test "caller search path and empty temporary lookalike tables cannot shadow canonical selection" do
    control = control!()
    snapshot = canonical_snapshot(control.source)
    assert_control(control)

    result =
      ScopedRepo.transact(
        RequestRepo,
        Map.take(control.source, [:principal_id, :vault_id]),
        fn repo ->
          for table <-
                ~w(search_entries resources resource_versions note_versions document_versions document_fragments tags resource_tags) do
            assert {:ok, _result} =
                     query(repo, "CREATE TEMP TABLE " <> table <> "(shadow text) ON COMMIT DROP")
          end

          assert {:ok, _result} =
                   query(repo, """
                   SELECT set_config('search_path',
                     'pg_temp, public, search_extensions, content, core, identity, pg_catalog',true)
                   """)

          candidate_query(repo, "o", "all", [])
        end
      )

    assert result == {:ok, control.entries}
    assert_control(control)
    assert canonical_snapshot(control.source) == snapshot
  end

  for revocation <- [:capability, :membership, :principal] do
    @revocation revocation

    test "exact authorization wait rechecks committed #{@revocation} revocation before content access" do
      control = control!()
      snapshot = canonical_snapshot(control.source)
      assert_control(control)

      result =
        with_held_authorization(
          control.source,
          &revoke_in_transaction!(&1, control.source, @revocation),
          fn holder ->
            with_reader(
              control.source,
              holder,
              fn repo -> candidate_query(repo, "o", "all", []) end,
              fn reader, backend ->
                assert await_exact_authorization_wait(
                         backend,
                         holder,
                         System.monotonic_time(:millisecond) + 4_000
                       )

                assert_no_content_read_locks(backend)
                release_holder(holder)
                assert :ok = Task.await(holder.task, 5_000)
                Task.await(reader, 5_000)
              end
            )
          end
        )

      assert result == @denied
      assert canonical_snapshot(control.source) == snapshot
      assert_control(control!())
    end
  end

  test "a different actual authority key does not block or satisfy the exact wait barrier" do
    control = control!()
    foreign = control!()
    snapshot = canonical_snapshot(control.source)
    assert_control(control)
    assert_control(foreign)
    refute authorization_key(control.source) == authorization_key(foreign.source)

    result =
      with_held_authorization(foreign.source, fn _repo -> :ok end, fn holder ->
        with_reader(
          control.source,
          holder,
          fn repo -> candidate_query(repo, "o", "all", []) end,
          fn reader, backend ->
            result = Task.await(reader, 4_000)
            assert Process.alive?(holder.task.pid)
            refute exact_authorization_wait?(backend, holder)
            release_holder(holder)
            assert :ok = Task.await(holder.task, 5_000)
            result
          end
        )
      end)

    assert result == {:ok, control.entries}
    assert_control(control)
    assert canonical_snapshot(control.source) == snapshot
  end

  for mutation <- [:head, :tag_remove, :tag_add, :tombstone, :restore] do
    @mutation mutation

    test "Store keeps a conservative immutable-source intersection across committed #{@mutation}" do
      source = source!()
      note = literal_note!(source, "Coherence", "coherence")
      {document, _fragment} = KnowledgeFixtures.ready_document!(source)
      project!(source, [note, document])
      query = store_query(source)

      assert {:ok, %{items: [original], next_cursor: :done} = original_page} =
               store_search(source, query)

      tag =
        if Enum.member?([:tag_remove, :tag_add], @mutation),
          do: tagged_note!(source, note),
          else: nil

      replacement = if @mutation == :head, do: KnowledgeFixtures.uuid(), else: nil

      if @mutation == :tag_add do
        Fixtures.with_owner(fn ->
          assert {:ok, %{num_rows: 1}} =
                   query(
                     MigrationRepo,
                     "DELETE FROM content.resource_tags WHERE resource_id=$1 AND tag_id=$2",
                     [note.resource_id, tag]
                   )
        end)
      end

      if @mutation == :restore do
        Fixtures.with_owner(fn ->
          assert {:ok, %{num_rows: 1}} =
                   query(
                     MigrationRepo,
                     "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
                     [note.resource_id]
                   )
        end)
      end

      query = if tag, do: %{query | tag_ids: [Ecto.UUID.load!(tag)]}, else: query

      before_page =
        if Enum.member?([:tag_add, :restore], @mutation),
          do: %{items: [], next_cursor: :done},
          else: original_page

      assert store_search(source, query) == {:ok, before_page}
      before_snapshot = canonical_snapshot(source)

      {waiting_result, committed_snapshot} =
        with_held_authorization(
          source,
          &write_source_race!(&1, source, note, @mutation, tag, replacement),
          fn holder ->
            with_reader(source, holder, &KnowledgeSearchStore.search(&1, query), fn reader,
                                                                                    backend ->
              assert await_exact_authorization_wait(
                       backend,
                       holder,
                       System.monotonic_time(:millisecond) + 4_000
                     )

              # Store legitimately holds its outer content relation locks already.
              release_holder(holder)
              assert :ok = Task.await(holder.task, 5_000)
              snapshot = owner_transaction_snapshot(source)
              {Task.await(reader, 5_000), snapshot}
            end)
          end
        )

      assert waiting_result == {:ok, %{items: [], next_cursor: :done}}
      refute committed_snapshot == before_snapshot
      assert canonical_snapshot(source) == committed_snapshot

      current_page =
        case @mutation do
          mutation when mutation in [:tag_remove, :tombstone] ->
            %{items: [], next_cursor: :done}

          :head ->
            inserted_at = version_inserted_at(replacement)

            %{
              original_page
              | items: [
                  %{
                    original
                    | resource_version_id: Ecto.UUID.load!(replacement),
                      entry_id: "note:" <> Ecto.UUID.load!(replacement),
                      source_inserted_at: inserted_at
                  }
                ]
            }

          _mutation ->
            original_page
        end

      assert store_search(source, query) == {:ok, current_page}
      assert canonical_snapshot(source) == committed_snapshot
    end
  end

  test "candidate union is uncapped deduplicated and applies canonical AND tags beyond one Store page" do
    source = source!()

    notes =
      Enum.flat_map(Enum.chunk_every(Enum.to_list(1..66), 33), fn batch ->
        Fixtures.with_owner(fn ->
          Enum.map(batch, fn _index ->
            insert_literal_note!(MigrationRepo, source, "Coherence", "coherence")
          end)
        end)
      end)

    project!(source, notes)
    [first, second, third | _rest] = notes
    first_tag = tagged_note!(source, first)
    second_tag = tagged_note!(source, second, "second-boundary-tag")

    Fixtures.with_owner(fn ->
      attach_tag!(MigrationRepo, source, second, first_tag)
      attach_tag!(MigrationRepo, source, third, second_tag)
    end)

    foreign = source!()
    foreign_note = literal_note!(foreign, "Foreign", "coherence")
    foreign_tag = tagged_note!(foreign, foreign_note)
    snapshot = canonical_snapshot(source)
    expected = Enum.sort(Enum.map(notes, &["note:" <> Ecto.UUID.load!(&1.resource_version_id)]))
    assert candidates(source, "coherence", "note") == {:ok, expected}

    assert candidates(RequestRepo, source, "coherence", "note", [first_tag]) ==
             {:ok,
              Enum.sort(
                Enum.map([first, second], &["note:" <> Ecto.UUID.load!(&1.resource_version_id)])
              )}

    assert candidates(RequestRepo, source, "coherence", "note", [first_tag, second_tag]) ==
             {:ok, [["note:" <> Ecto.UUID.load!(second.resource_version_id)]]}

    assert candidates(RequestRepo, source, "coherence", "note", [KnowledgeFixtures.uuid()]) ==
             {:ok, []}

    assert candidates(RequestRepo, source, "coherence", "note", [foreign_tag]) == {:ok, []}

    query = %{store_query(source) | limit: 50}
    assert {:ok, %{items: first_page, next_cursor: cursor}} = store_search(source, query)
    assert length(first_page) == 50
    assert is_binary(cursor)

    assert {:ok, %{items: second_page, next_cursor: :done}} =
             store_search(source, %{query | cursor: cursor})

    assert length(second_page) == 16
    assert Enum.sort(Enum.map(first_page ++ second_page, &[&1.entry_id])) == expected
    assert candidates(source, "coherence", "all") == {:ok, expected}
    assert canonical_snapshot(source) == snapshot
  end

  test "admissible historical conflict and tombstoned projections exclude stale Note identities" do
    source = source!()
    live = literal_note!(source, "Signal", "signal")
    historical = literal_note!(source, "Signal", "signal")
    conflicted = literal_note!(source, "Base", "base")
    deleted = literal_note!(source, "Signal", "signal")
    project!(source, [live, historical, conflicted, deleted])
    foreign = control!()
    assert_typed_control(foreign)

    Fixtures.with_owner(fn ->
      replacement = KnowledgeFixtures.uuid()
      canonical = KnowledgeFixtures.uuid()
      competing = KnowledgeFixtures.uuid()

      insert_note_revision!(
        MigrationRepo,
        source,
        historical,
        replacement,
        1,
        "Replacement",
        "replacement"
      )

      insert_note_revision!(
        MigrationRepo,
        source,
        conflicted,
        canonical,
        1,
        "Canonical",
        "canonical"
      )

      insert_note_revision!(MigrationRepo, source, conflicted, competing, 2, "Signal", "signal")

      for {note, version} <- [{historical, replacement}, {conflicted, canonical}] do
        assert {:ok, %{num_rows: 1}} =
                 query(
                   MigrationRepo,
                   "UPDATE content.resources SET current_version_id=$2 WHERE id=$1",
                   [note.resource_id, version]
                 )
      end

      assert {:ok, %{num_rows: 1}} =
               query(
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

      assert {:ok, %{num_rows: 1}} =
               query(
                 MigrationRepo,
                 "UPDATE content.search_entries SET entry_id='note:'||$2::uuid::text,resource_version_id=$2,note_resource_version_id=$2,title='Signal',body='signal',source_inserted_at=(SELECT inserted_at FROM content.resource_versions WHERE id=$2) WHERE resource_id=$1",
                 [conflicted.resource_id, competing]
               )

      assert {:ok, %{num_rows: 1}} =
               query(
                 MigrationRepo,
                 "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
                 [deleted.resource_id]
               )
    end)

    canonical = canonical_snapshot(source)
    projection = projection_snapshot(source)
    assert projection.rows == 4
    expected = [["note:" <> Ecto.UUID.load!(live.resource_version_id)]]
    assert candidates(source, "signal", "note") == {:ok, expected}
    assert candidates(source, "signal", "all") == {:ok, expected}
    assert candidates(source, "signal", "document") == {:ok, []}
    assert candidates(source, "o", "all") == {:ok, []}
    assert_typed_control(foreign)
    assert canonical_snapshot(source) == canonical
    assert projection_snapshot(source) == projection
  end

  test "a real extracting Document staged fragment is not a ready search candidate" do
    control = control!()
    document = KnowledgeFixtures.document!(control.source)
    KnowledgeFixtures.retire_document_on_exit!(document)
    fragment = fragment!(document, 0, "staged signal")

    Fixtures.with_owner(fn ->
      extraction_context!(control.source)

      assert {:ok, %{rows: [["extracting"]]}} =
               query(
                 MigrationRepo,
                 "SELECT (content.claim_document_extraction($1,0,$1,'plain',1)).state",
                 [document.resource_version_id]
               )

      assert {:ok, %{num_rows: 1}} = insert_fragment(MigrationRepo, document, fragment)
      assert {:ok, %{num_rows: 1}} = insert_document_projection(MigrationRepo, document, fragment)
    end)

    canonical = canonical_snapshot(control.source)
    projection = projection_snapshot(control.source)
    assert projection.rows == 3
    assert_typed_control(control)
    assert candidates(control.source, "staged signal", "all") == {:ok, []}
    assert candidates(control.source, "staged signal", "document") == {:ok, []}
    assert canonical_snapshot(control.source) == canonical
    assert projection_snapshot(control.source) == projection
  end

  for {mutation, code, constraint} <- [
        {:foreign_owner, "23503", "search_entries_resource_version_fkey"},
        {:wrong_kind, "23503", "search_entries_note_version_fkey"},
        {:ordinal, "23514", "search_entries_source_shape_check"},
        {:fragment, "23503", "search_entries_document_fragment_fkey"}
      ] do
    @projection_mutation mutation
    @projection_code code
    @projection_constraint constraint

    test "impossible #{@projection_mutation} projection tuple fails its exact persistence constraint" do
      control = control!()
      foreign = control!()
      assert_typed_control(control)
      assert_typed_control(foreign)
      canonical = canonical_snapshot(control.source)
      projection = projection_snapshot(control.source)
      foreign_canonical = canonical_snapshot(foreign.source)
      foreign_projection = projection_snapshot(foreign.source)

      result =
        rejected_write(fn repo ->
          reject_projection_tuple(repo, control, foreign, @projection_mutation)
        end)

      assert result == {:error, {:constraint, @projection_code, @projection_constraint}}
      assert canonical_snapshot(control.source) == canonical
      assert projection_snapshot(control.source) == projection
      assert canonical_snapshot(foreign.source) == foreign_canonical
      assert projection_snapshot(foreign.source) == foreign_projection
      assert_typed_control(control)
      assert_typed_control(foreign)
    end
  end

  for state <- [:pending, :failed] do
    @document_state state

    test "#{@document_state} Document cannot persist a canonical or derived fragment" do
      control = control!()
      document = KnowledgeFixtures.document!(control.source)
      fragment = fragment!(document, 0, "staged signal")

      if Enum.member?([:failed], @document_state) do
        Fixtures.with_owner(fn ->
          extraction_context!(control.source)

          assert {:ok, %{rows: [["extracting"]]}} =
                   query(
                     MigrationRepo,
                     "SELECT (content.claim_document_extraction($1,0,$1,'plain',1)).state",
                     [document.resource_version_id]
                   )

          assert {:ok, %{rows: [["failed"]]}} =
                   query(
                     MigrationRepo,
                     "SELECT (content.fail_document_extraction($1,$1,1,'failed','extractor_failed')).state",
                     [document.resource_version_id]
                   )
        end)
      end

      assert {:ok, %{rows: [[state, 0]]}} =
               Fixtures.with_owner(fn ->
                 query(
                   MigrationRepo,
                   "SELECT document.state,(SELECT count(*) FROM content.document_fragments WHERE resource_version_id=document.resource_version_id) FROM content.document_versions AS document WHERE resource_version_id=$1",
                   [document.resource_version_id]
                 )
               end)

      assert state == Atom.to_string(@document_state)
      canonical = canonical_snapshot(control.source)
      projection = projection_snapshot(control.source)
      assert_typed_control(control)

      assert rejected_write(&insert_document_projection(&1, document, fragment)) ==
               {:error, {:constraint, "23503", "search_entries_document_fragment_fkey"}}

      assert rejected_write(fn repo ->
               assert {:ok, %{num_rows: 1}} = insert_fragment(repo, document, fragment)

               query(
                 repo,
                 "SET CONSTRAINTS content.document_fragments_completion_check IMMEDIATE"
               )
             end) == {:error, {:constraint, "23514", "document_versions_completion_check"}}

      assert canonical_snapshot(control.source) == canonical
      assert projection_snapshot(control.source) == projection
      assert_typed_control(control)
      assert candidates(control.source, "staged signal", "document") == {:ok, []}
    end
  end

  defp with_held_authorization(source, write, callback) do
    {:ok, owner_pid} = MigrationRepo.start_link(pool_size: 2)
    parent = self()
    reference = make_ref()
    key = authorization_key(source)

    holder =
      Task.async(fn ->
        assert {:ok, :ok} =
                 MigrationRepo.transaction(fn ->
                   assert {:ok, _result} =
                            query(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                   assert {:ok, %{rows: [[backend, hash]]}} =
                            query(
                              MigrationRepo,
                              """
                              SELECT pg_catalog.pg_backend_pid(),pg_catalog.hashtextextended($1,0)
                              """,
                              [key]
                            )

                   assert {:ok, %{num_rows: 1}} =
                            query(
                              MigrationRepo,
                              "SELECT pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended($1,0))",
                              [key]
                            )

                   write.(MigrationRepo)
                   send(parent, {reference, :authorization_held, backend, hash})

                   receive do
                     {^reference, :release} -> :ok
                   after
                     15_000 -> flunk("candidate authorization holder expired")
                   end
                 end)

        :ok
      end)

    try do
      assert_receive {^reference, :authorization_held, backend, hash}, 5_000
      callback.(%{task: holder, backend: backend, hash: hash, key: key, reference: reference})
    after
      send(holder.pid, {reference, :release})

      try do
        drain_candidate_task(holder)
      after
        Supervisor.stop(owner_pid)
      end
    end
  end

  defp with_reader(source, holder, read, callback) do
    parent = self()
    reference = make_ref()

    reader =
      Task.async(fn ->
        ScopedRepo.transact(RequestRepo, Map.take(source, [:principal_id, :vault_id]), fn repo ->
          assert {:ok, %{rows: [[backend]]}} = query(repo, "SELECT pg_catalog.pg_backend_pid()")
          send(parent, {reference, :candidate_reader, backend})
          read.(repo)
        end)
      end)

    try do
      assert_receive {^reference, :candidate_reader, backend}, 5_000
      callback.(reader, backend)
    after
      release_holder(holder)
      drain_candidate_task(reader)
    end
  end

  defp release_holder(holder), do: send(holder.task.pid, {holder.reference, :release})

  defp authorization_key(source),
    do:
      "singularity:authorization:" <>
        Ecto.UUID.load!(source.principal_id) <>
        ":" <>
        Ecto.UUID.load!(source.vault_id)

  defp revoke_in_transaction!(repo, source, revocation) do
    {statement, parameters, count} =
      case revocation do
        :capability ->
          {"UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
           [source.principal_id, source.vault_id], 2}

        :membership ->
          {"UPDATE core.vault_members SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
           [source.principal_id, source.vault_id], 1}

        :principal ->
          {"UPDATE identity.principals SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1",
           [source.principal_id], 1}
      end

    assert {:ok, %{num_rows: ^count}} = query(repo, statement, parameters)
    :ok
  end

  defp await_exact_authorization_wait(backend, holder, deadline) do
    cond do
      exact_authorization_wait?(backend, holder) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> await_exact_authorization_wait(backend, holder, deadline)
    end
  end

  defp exact_authorization_wait?(backend, holder) do
    assert {:ok, %{rows: [[waiting]]}} =
             query(
               MigrationRepo,
               """
               SELECT $4::bigint=pg_catalog.hashtextextended($3,0) AND EXISTS (
                 SELECT FROM pg_locks AS waiting JOIN pg_locks AS held
                   ON held.locktype=waiting.locktype AND held.database=waiting.database
                  AND held.classid=waiting.classid AND held.objid=waiting.objid
                  AND held.objsubid=waiting.objsubid
                 WHERE waiting.pid=$1 AND held.pid=$2 AND waiting.locktype='advisory'
                   AND waiting.mode='ShareLock' AND NOT waiting.granted
                   AND held.mode='ExclusiveLock' AND held.granted
                   AND waiting.classid=((pg_catalog.hashtextextended($3,0) >> 32) & 4294967295)::oid
                   AND waiting.objid=(pg_catalog.hashtextextended($3,0) & 4294967295)::oid
                   AND waiting.objsubid=1
               ) AND $2::integer=ANY(pg_catalog.pg_blocking_pids($1))
               """,
               [backend, holder.backend, holder.key, holder.hash]
             )

    waiting
  end

  defp assert_no_content_read_locks(backend) do
    assert {:ok, %{rows: [[false]]}} =
             query(
               MigrationRepo,
               """
               SELECT EXISTS (
                 SELECT FROM pg_locks AS lock JOIN pg_class AS relation ON relation.oid=lock.relation
                 JOIN pg_namespace AS namespace ON namespace.oid=relation.relnamespace
                 WHERE lock.pid=$1 AND lock.locktype='relation' AND lock.granted
                   AND lock.mode='AccessShareLock' AND namespace.nspname='content'
               )
               """,
               [backend]
             )
  end

  defp drain_candidate_task(task) do
    if Process.alive?(task.pid) do
      Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    else
      Task.shutdown(task, :brutal_kill)
    end

    refute Process.alive?(task.pid)
  end

  defp control! do
    source = source!()
    note = KnowledgeFixtures.note!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    project!(source, [note, document])

    %{
      source: source,
      note: note,
      document: document,
      fragment: fragment,
      entries:
        Enum.sort([
          ["note:" <> Ecto.UUID.load!(note.resource_version_id)],
          ["document:" <> fragment.fragment_id]
        ])
    }
  end

  defp assert_control(control),
    do: assert(candidates(control.source, "o", "all") == {:ok, control.entries})

  defp assert_typed_control(control) do
    assert_control(control)

    assert candidates(control.source, "o", "note") ==
             {:ok, [["note:" <> Ecto.UUID.load!(control.note.resource_version_id)]]}

    assert candidates(control.source, "o", "document") ==
             {:ok, [["document:" <> control.fragment.fragment_id]]}
  end

  defp fragment!(document, ordinal, text) do
    assert {:ok, fragment} =
             DocumentFragment.new(%{
               resource_id: Ecto.UUID.load!(document.resource_id),
               resource_version_id: Ecto.UUID.load!(document.resource_version_id),
               owner_scope_id: Ecto.UUID.load!(document.vault_id),
               classification: :private,
               ordinal: ordinal,
               text: text,
               locator: %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
             })

    fragment
  end

  defp extraction_context!(source) do
    assert {:ok, %{num_rows: 1}} =
             query(
               MigrationRepo,
               "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
               [Ecto.UUID.load!(source.principal_id), Ecto.UUID.load!(source.vault_id)]
             )

    :ok
  end

  defp insert_fragment(repo, document, fragment) do
    query(
      repo,
      "INSERT INTO content.document_fragments(id,resource_id,resource_version_id,vault_id,classification,ordinal,text,digest,locator,inserted_at) VALUES($1,$2,$3,$4,'private',$5,$6,$7,$8,CURRENT_TIMESTAMP)",
      [
        fragment.fragment_id,
        document.resource_id,
        document.resource_version_id,
        document.vault_id,
        fragment.ordinal,
        fragment.text,
        fragment.digest,
        SourceLocator.to_map(fragment.locator)
      ]
    )
  end

  defp insert_document_projection(repo, document, fragment) do
    query(
      repo,
      "INSERT INTO content.search_entries(entry_id,vault_id,classification,resource_id,resource_version_id,kind,fragment_id,ordinal,title,body,locator,source_inserted_at,projection_version) SELECT 'document:'||$1,$2,'private',$3,$4,'document',$1,$5,'Document',$6,$7,inserted_at,1 FROM content.resource_versions WHERE id=$4",
      [
        fragment.fragment_id,
        document.vault_id,
        document.resource_id,
        document.resource_version_id,
        fragment.ordinal,
        fragment.text,
        SourceLocator.to_map(fragment.locator)
      ]
    )
  end

  defp rejected_write(write) do
    Fixtures.with_owner(fn ->
      assert {:ok, _result} = query(MigrationRepo, "SAVEPOINT candidate_constraint_boundary")

      try do
        write.(MigrationRepo)
      after
        assert {:ok, _result} =
                 query(MigrationRepo, "ROLLBACK TO SAVEPOINT candidate_constraint_boundary")

        assert {:ok, _result} =
                 query(MigrationRepo, "RELEASE SAVEPOINT candidate_constraint_boundary")
      end
    end)
  end

  defp reject_projection_tuple(repo, control, foreign, :foreign_owner) do
    query(repo, "UPDATE content.search_entries SET vault_id=$2 WHERE entry_id=$1", [
      "document:" <> control.fragment.fragment_id,
      foreign.source.vault_id
    ])
  end

  defp reject_projection_tuple(repo, control, _foreign, :wrong_kind) do
    query(
      repo,
      """
      UPDATE content.search_entries
      SET kind='note',note_resource_version_id=resource_version_id,fragment_id=NULL,
          ordinal=0,entry_id='note:'||resource_version_id::text,locator=$2
      WHERE entry_id=$1
      """,
      [
        "document:" <> control.fragment.fragment_id,
        %{"version" => 1, "kind" => "markdown", "heading_path" => []}
      ]
    )
  end

  defp reject_projection_tuple(repo, control, _foreign, :ordinal) do
    query(repo, "UPDATE content.search_entries SET ordinal=1 WHERE entry_id=$1", [
      "document:" <> control.fragment.fragment_id
    ])
  end

  defp reject_projection_tuple(repo, control, _foreign, :fragment) do
    fragment = fragment!(control.document, 1, control.fragment.text)

    query(
      repo,
      "UPDATE content.search_entries SET fragment_id=$2,entry_id='document:'||$2,ordinal=1 WHERE entry_id=$1",
      ["document:" <> control.fragment.fragment_id, fragment.fragment_id]
    )
  end

  defp literal_note!(source, title, body) do
    Fixtures.with_owner(fn -> insert_literal_note!(MigrationRepo, source, title, body) end)
  end

  defp insert_literal_note!(repo, source, title, body) do
    row = %{resource_id: KnowledgeFixtures.uuid(), resource_version_id: KnowledgeFixtures.uuid()}

    assert {:ok, %{num_rows: 1}} =
             query(
               repo,
               "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,$4)",
               [row.resource_id, source.vault_id, row.resource_version_id, title]
             )

    assert {:ok, %{num_rows: 1}} =
             query(
               repo,
               "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',0)",
               [row.resource_version_id, row.resource_id, source.vault_id]
             )

    assert {:ok, %{num_rows: 1}} =
             query(
               repo,
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

    row
  end

  defp tagged_note!(source, note, key \\ "boundary-tag") do
    tag = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      assert {:ok, %{num_rows: 1}} =
               query(
                 MigrationRepo,
                 "INSERT INTO content.tags(id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at) VALUES($1,$2,'private',$4,$4,$3,CURRENT_TIMESTAMP)",
                 [tag, source.vault_id, source.principal_id, key]
               )

      attach_tag!(MigrationRepo, source, note, tag)
    end)

    tag
  end

  defp attach_tag!(repo, source, note, tag) do
    assert {:ok, %{num_rows: 1}} =
             query(
               repo,
               "INSERT INTO content.resource_tags(resource_id,tag_id,vault_id,classification,inserted_at) VALUES($1,$2,$3,'private',CURRENT_TIMESTAMP)",
               [note.resource_id, tag, source.vault_id]
             )

    :ok
  end

  defp store_query(source) do
    %{
      owner_scope_id: Ecto.UUID.load!(source.vault_id),
      classification: :private,
      q: "coherence",
      kind: :note,
      tag_ids: [],
      limit: 20,
      cursor: nil,
      policy_version: 1
    }
  end

  defp store_search(source, query) do
    ScopedRepo.transact(
      RequestRepo,
      Map.take(source, [:principal_id, :vault_id]),
      &KnowledgeSearchStore.search(&1, query)
    )
  end

  defp insert_note_revision!(repo, source, note, version, revision, title, body) do
    assert {:ok, %{num_rows: 1}} =
             query(
               repo,
               "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',$4)",
               [version, note.resource_id, source.vault_id, revision]
             )

    assert {:ok, %{num_rows: 1}} =
             query(
               repo,
               "INSERT INTO content.note_versions(resource_version_id,resource_id,vault_id,classification,title,markdown,created_by_principal_id,parent_version_id,inserted_at) VALUES($1,$2,$3,'private',$4,$5,$6,$7,CURRENT_TIMESTAMP)",
               [
                 version,
                 note.resource_id,
                 source.vault_id,
                 title,
                 body,
                 source.principal_id,
                 note.resource_version_id
               ]
             )

    :ok
  end

  defp write_source_race!(repo, source, note, mutation, tag, replacement) do
    case mutation do
      :head ->
        insert_note_revision!(repo, source, note, replacement, 1, "Coherence", "coherence")

        assert {:ok, %{num_rows: 1}} =
                 query(repo, "UPDATE content.resources SET current_version_id=$2 WHERE id=$1", [
                   note.resource_id,
                   replacement
                 ])

      :tag_remove ->
        assert {:ok, %{num_rows: 1}} =
                 query(
                   repo,
                   "DELETE FROM content.resource_tags WHERE resource_id=$1 AND tag_id=$2",
                   [note.resource_id, tag]
                 )

      :tag_add ->
        attach_tag!(repo, source, note, tag)

      :tombstone ->
        assert {:ok, %{num_rows: 1}} =
                 query(
                   repo,
                   "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
                   [note.resource_id]
                 )

      :restore ->
        assert {:ok, %{num_rows: 1}} =
                 query(repo, "UPDATE content.resources SET deleted_at=NULL WHERE id=$1", [
                   note.resource_id
                 ])
    end

    expected = if mutation == :tombstone, do: 0, else: 1

    assert {:ok, %{rows: [[^expected]]}} =
             query(repo, "SELECT content.reconcile_search_resource_internal($1,$2)", [
               source.vault_id,
               note.resource_id
             ])

    :ok
  end

  defp version_inserted_at(version) do
    Fixtures.with_owner(fn ->
      assert {:ok, %{rows: [[inserted_at]]}} =
               query(
                 MigrationRepo,
                 "SELECT inserted_at FROM content.resource_versions WHERE id=$1",
                 [version]
               )

      inserted_at
    end)
  end

  defp owner_transaction_snapshot(source) do
    assert {:ok, snapshot} =
             MigrationRepo.transaction(fn ->
               assert {:ok, _result} =
                        query(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

               canonical_snapshot_from(MigrationRepo, source)
             end)

    snapshot
  end

  defp reject_authority!(source, :wrong_owner) do
    foreign = control!()
    assert_control(foreign)
    %{source | vault_id: foreign.source.vault_id}
  end

  defp reject_authority!(source, authority) do
    {statement, parameters, count} =
      case authority do
        :non_owner ->
          {"UPDATE identity.principals SET kind='system' WHERE id=$1", [source.principal_id], 1}

        :inactive_account ->
          {"UPDATE identity.accounts SET status='disabled' WHERE id=$1", [source.account_id], 1}

        :revoked_principal ->
          {"UPDATE identity.principals SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1",
           [source.principal_id], 1}

        :revoked_membership ->
          {"UPDATE core.vault_members SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
           [source.principal_id, source.vault_id], 1}

        :revoked_capability ->
          {"UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
           [source.principal_id, source.vault_id], 2}
      end

    Fixtures.with_owner(fn ->
      assert {:ok, %{num_rows: ^count}} = query(MigrationRepo, statement, parameters)
    end)

    source
  end

  defp private_membership_snapshot(source) do
    Fixtures.with_owner(fn ->
      case query(
             MigrationRepo,
             """
             SELECT membership.clearance,membership.revoked_at,to_jsonb(membership)::text
             FROM core.vault_members AS membership
             WHERE principal_id=$1 AND vault_id=$2
             """,
             [source.principal_id, source.vault_id]
           ) do
        {:ok, %{rows: [["private", nil, row]], num_rows: 1}} -> :crypto.hash(:sha256, row)
        _other -> flunk("private candidate membership snapshot failed")
      end
    end)
  end

  defp canonical_snapshot(source) do
    Fixtures.with_owner(fn -> canonical_snapshot_from(MigrationRepo, source) end)
  end

  defp canonical_snapshot_from(repo, source) do
    Map.new(
      ~w(resources resource_versions note_versions note_conflicts document_versions document_fragments resource_assets asset_objects assets tags resource_tags),
      fn table ->
        case query(
               repo,
               "SELECT to_jsonb(canonical)::text FROM content." <>
                 table <>
                 " AS canonical WHERE vault_id=$1 ORDER BY to_jsonb(canonical)::text COLLATE \"C\"",
               [source.vault_id]
             ) do
          {:ok, %{rows: rows, num_rows: count}} ->
            {table, %{rows: count, digest: :crypto.hash(:sha256, :erlang.term_to_binary(rows))}}

          {:error, _reason} ->
            flunk("canonical candidate snapshot failed")
        end
      end
    )
  end

  defp projection_snapshot(source) do
    Fixtures.with_owner(fn ->
      case query(
             MigrationRepo,
             "SELECT to_jsonb(entry)::text FROM content.search_entries AS entry WHERE vault_id=$1 ORDER BY entry_id COLLATE \"C\"",
             [source.vault_id]
           ) do
        {:ok, %{rows: rows, num_rows: count}} ->
          %{rows: count, digest: :crypto.hash(:sha256, :erlang.term_to_binary(rows))}

        _other ->
          flunk("candidate projection snapshot failed")
      end
    end)
  end

  defp raw_candidates(context, isolation \\ :read_committed) do
    RequestRepo.checkout(fn ->
      result =
        case RequestRepo.transaction(fn ->
               if isolation == :serializable do
                 assert {:ok, _result} =
                          query(RequestRepo, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
               end

               if context != nil do
                 {principal, owner} = context

                 assert {:ok, _result} =
                          query(
                            RequestRepo,
                            "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
                            [principal, owner]
                          )
               end

               case candidate_query(RequestRepo, "o", "all", []) do
                 {:error, reason} -> RequestRepo.rollback(reason)
                 success -> success
               end
             end) do
          {:ok, success} -> success
          {:error, reason} -> {:error, reason}
        end

      assert {:ok, %{rows: [[nil, nil]]}} =
               query(RequestRepo, """
               SELECT NULLIF(current_setting('singularity.principal_id',true),''),
                      NULLIF(current_setting('singularity.vault_id',true),'')
               """)

      result
    end)
  end

  defp source!(names \\ ["note.read", "asset.read"]) do
    source = KnowledgeFixtures.source!()
    expected = length(names)

    Fixtures.with_owner(fn ->
      for name <- names do
        assert {:ok, _result} =
                 query(
                   MigrationRepo,
                   "INSERT INTO core.capabilities(id,name) VALUES($1,$2) ON CONFLICT(name) DO NOTHING",
                   [KnowledgeFixtures.uuid(), name]
                 )
      end

      assert {:ok, %{num_rows: ^expected}} =
               query(
                 MigrationRepo,
                 """
                 INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id)
                 SELECT $1,$2,capability.id FROM core.capabilities AS capability
                 WHERE capability.name=ANY($3::text[])
                 ON CONFLICT(principal_id,vault_id,capability_id) DO NOTHING
                 """,
                 [source.principal_id, source.vault_id, names]
               )
    end)

    source
  end

  defp project!(source, resources) do
    Fixtures.with_owner(fn ->
      for resource <- resources do
        assert {:ok, %{rows: [[1]]}} =
                 query(
                   MigrationRepo,
                   "SELECT content.reconcile_search_resource_internal($1,$2)",
                   [source.vault_id, resource.resource_id]
                 )
      end
    end)
  end

  defp candidates(source, q, kind) do
    candidates(RequestRepo, source, q, kind)
  end

  defp candidates(repo, source, q, kind) do
    candidates(repo, source, q, kind, [])
  end

  defp candidates(repo, source, q, kind, tags) do
    ScopedRepo.transact(repo, Map.take(source, [:principal_id, :vault_id]), fn repo ->
      candidate_query(repo, q, kind, tags)
    end)
  end

  defp candidate_query(repo, q, kind, tags) do
    case query(
           repo,
           """
           SELECT candidate.entry_id
           FROM content.search_candidate_ids($1::text,$2::text,$3::uuid[]) AS candidate
           ORDER BY candidate.entry_id COLLATE "C"
           """,
           [q, kind, tags]
         ) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, _reason} = error -> error
    end
  end

  defp security_snapshot do
    managed_roles = @owner_roles ++ @runtime_roles ++ ["singularity_migration"]

    assert {:ok, %{rows: roles}} =
             query(
               RequestRepo,
               """
               SELECT rolname,rolcanlogin,rolsuper,rolcreatedb,rolcreaterole,rolinherit,
                      rolbypassrls,rolreplication
               FROM pg_roles WHERE rolname=ANY($1::text[]) ORDER BY rolname COLLATE "C"
               """,
               [managed_roles]
             )

    assert {:ok, %{rows: memberships}} =
             query(
               RequestRepo,
               """
               SELECT granted.rolname,member.rolname,membership.admin_option,
                      membership.inherit_option,membership.set_option
               FROM pg_auth_members AS membership
               JOIN pg_roles AS granted ON granted.oid=membership.roleid
               JOIN pg_roles AS member ON member.oid=membership.member
               WHERE granted.rolname=ANY($1::text[]) OR member.rolname=ANY($1::text[])
               ORDER BY granted.rolname COLLATE "C",member.rolname COLLATE "C"
               """,
               [managed_roles]
             )

    assert {:ok, %{rows: relation}} =
             query(RequestRepo, """
             SELECT pg_get_userbyid(relowner),relrowsecurity,relforcerowsecurity
             FROM pg_class WHERE oid='content.search_entries'::regclass
             """)

    assert {:ok, %{rows: policies}} =
             query(RequestRepo, """
             SELECT policy.polname,policy.polcmd::text,policy.polpermissive,
                    ARRAY(SELECT role.rolname::text FROM unnest(policy.polroles) AS policy_role(oid)
                          JOIN pg_roles AS role ON role.oid=policy_role.oid
                          ORDER BY role.rolname COLLATE "C"),
                    pg_get_expr(policy.polqual,policy.polrelid),
                    pg_get_expr(policy.polwithcheck,policy.polrelid)
             FROM pg_policy AS policy WHERE policy.polrelid='content.search_entries'::regclass
             ORDER BY policy.polname COLLATE "C"
             """)

    assert {:ok, %{rows: grants}} =
             query(
               RequestRepo,
               """
               SELECT role,has_table_privilege(role,'content.search_entries','SELECT'),
                      has_table_privilege(role,'content.search_entries','INSERT'),
                      has_table_privilege(role,'content.search_entries','UPDATE'),
                      has_table_privilege(role,'content.search_entries','DELETE')
               FROM unnest($1::text[]) AS role ORDER BY role COLLATE "C"
               """,
               [@runtime_roles]
             )

    assert {:ok, %{rows: indexes}} =
             query(
               RequestRepo,
               """
               SELECT index_relation.relname,index.indisvalid,index.indisready,
                      pg_get_indexdef(index.indexrelid)
               FROM pg_index AS index JOIN pg_class AS index_relation ON index_relation.oid=index.indexrelid
               WHERE index.indrelid='content.search_entries'::regclass
                 AND index_relation.relname=ANY($1::text[])
               ORDER BY index_relation.relname COLLATE "C"
               """,
               [~w(search_entries_fts search_entries_title_trigram search_entries_body_trigram)]
             )

    %{
      roles: roles,
      memberships: memberships,
      relation: relation,
      policies: policies,
      grants: grants,
      indexes: indexes
    }
  end

  defp assert_security_baseline(baseline) do
    expected_roles =
      Enum.map(@owner_roles, &[&1, false, false, false, false, false, false, false]) ++
        Enum.map(@runtime_roles, &[&1, true, false, false, false, false, false, false]) ++
        [["singularity_migration", true, false, true, false, false, false, false]]

    assert baseline.roles == Enum.sort(expected_roles)

    assert baseline.memberships ==
             Enum.sort(Enum.map(@owner_roles, &[&1, "singularity_migration", false, false, true]))

    assert baseline.relation == [["singularity_table_owner", true, true]]

    assert [
             [
               "search_entries_table_owner",
               "*",
               true,
               ["singularity_table_owner"],
               "true",
               "true"
             ],
             ["search_entries_vault_isolation", "r", true, ["singularity_web"], _web_policy, nil]
           ] = baseline.policies

    assert baseline.grants ==
             Enum.sort(
               Enum.map(@runtime_roles, &[&1, &1 == "singularity_web", false, false, false])
             )

    assert baseline.indexes == [
             [
               "search_entries_body_trigram",
               true,
               true,
               "CREATE INDEX search_entries_body_trigram ON content.search_entries USING gin (body search_extensions.gin_trgm_ops)"
             ],
             [
               "search_entries_fts",
               true,
               true,
               "CREATE INDEX search_entries_fts ON content.search_entries USING gin (search_vector)"
             ],
             [
               "search_entries_title_trigram",
               true,
               true,
               "CREATE INDEX search_entries_title_trigram ON content.search_entries USING gin (title search_extensions.gin_trgm_ops)"
             ]
           ]
  end

  defp privileged_function_inventory do
    assert {:ok, %{rows: rows}} =
             query(RequestRepo, """
             SELECT format('%I.%I(%s)',namespace.nspname,procedure.proname,
                           replace(oidvectortypes(procedure.proargtypes),', ',',')) AS signature,
                    owner.rolname
             FROM pg_proc AS procedure
             JOIN pg_namespace AS namespace ON namespace.oid=procedure.pronamespace
             JOIN pg_roles AS owner ON owner.oid=procedure.proowner
             WHERE procedure.prosecdef AND namespace.nspname <> 'information_schema'
               AND namespace.nspname !~ '^pg_'
             ORDER BY format('%I.%I(%s)',namespace.nspname,procedure.proname,
                             replace(oidvectortypes(procedure.proargtypes),', ',',')) COLLATE "C",
                      owner.rolname COLLATE "C"
             """)

    rows
  end

  defp query(repo, statement, parameters \\ []) do
    case SafeSQL.query(repo, statement, parameters) do
      {:ok, %{rows: rows, num_rows: count}} -> {:ok, %{rows: rows, num_rows: count}}
      {:error, %Postgrex.Error{postgres: fields}} -> candidate_error(fields)
      _other -> {:error, :candidate_call_failed}
    end
  end

  defp candidate_error(%{code: :undefined_function}),
    do: {:error, :candidate_function_missing}

  defp candidate_error(%{
         code: :foreign_key_violation,
         pg_code: "23503",
         schema: "content",
         table: "search_entries",
         constraint: constraint
       })
       when constraint in [
              "search_entries_resource_version_fkey",
              "search_entries_note_version_fkey",
              "search_entries_document_fragment_fkey"
            ],
       do: {:error, {:constraint, "23503", constraint}}

  defp candidate_error(%{
         code: :check_violation,
         pg_code: "23514",
         schema: "content",
         table: "search_entries",
         constraint: "search_entries_source_shape_check"
       }),
       do: {:error, {:constraint, "23514", "search_entries_source_shape_check"}}

  defp candidate_error(%{
         code: :check_violation,
         pg_code: "23514",
         constraint: "document_versions_completion_check"
       }),
       do: {:error, {:constraint, "23514", "document_versions_completion_check"}}

  defp candidate_error(%{
         code: :check_violation,
         pg_code: "23514",
         schema: "core",
         table: "vault_members",
         constraint: "vault_members_classification_check"
       }),
       do: {:error, {:check_violation, "23514", "vault_members_classification_check"}}

  defp candidate_error(%{code: code, message: message} = fields)
       when (code == :check_violation and message == "search candidates input is invalid") or
              (code == :insufficient_privilege and
                 message == "search candidates are not authorized") do
    {:error, {code, message, {not is_nil(fields[:detail]), not is_nil(fields[:hint])}}}
  end

  defp candidate_error(%{code: :insufficient_privilege}),
    do: {:error, :candidate_execute_denied}

  defp candidate_error(_fields), do: {:error, :candidate_call_failed}
end
