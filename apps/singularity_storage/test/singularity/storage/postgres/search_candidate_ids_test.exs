defmodule Singularity.Storage.Postgres.SearchCandidateIdsTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

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

  defp control! do
    source = source!()
    note = KnowledgeFixtures.note!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)
    project!(source, [note, document])

    %{
      source: source,
      note: note,
      entries:
        Enum.sort([
          ["note:" <> Ecto.UUID.load!(note.resource_version_id)],
          ["document:" <> fragment.fragment_id]
        ])
    }
  end

  defp assert_control(control),
    do: assert(candidates(control.source, "o", "all") == {:ok, control.entries})

  defp literal_note!(source, title, body) do
    row = %{resource_id: KnowledgeFixtures.uuid(), resource_version_id: KnowledgeFixtures.uuid()}

    Fixtures.with_owner(fn ->
      assert {:ok, %{num_rows: 1}} =
               query(
                 MigrationRepo,
                 "INSERT INTO content.resources(id,vault_id,classification,kind,current_version_id,title) VALUES($1,$2,'private','note',$3,$4)",
                 [row.resource_id, source.vault_id, row.resource_version_id, title]
               )

      assert {:ok, %{num_rows: 1}} =
               query(
                 MigrationRepo,
                 "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',0)",
                 [row.resource_version_id, row.resource_id, source.vault_id]
               )

      assert {:ok, %{num_rows: 1}} =
               query(
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

  defp tagged_note!(source, note) do
    tag = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      assert {:ok, %{num_rows: 1}} =
               query(
                 MigrationRepo,
                 "INSERT INTO content.tags(id,vault_id,classification,display_value,normalized_key,created_by_principal_id,inserted_at) VALUES($1,$2,'private','boundary-tag','boundary-tag',$3,CURRENT_TIMESTAMP)",
                 [tag, source.vault_id, source.principal_id]
               )

      assert {:ok, %{num_rows: 1}} =
               query(
                 MigrationRepo,
                 "INSERT INTO content.resource_tags(resource_id,tag_id,vault_id,classification,inserted_at) VALUES($1,$2,$3,'private',CURRENT_TIMESTAMP)",
                 [note.resource_id, tag, source.vault_id]
               )
    end)

    tag
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
    Fixtures.with_owner(fn ->
      Map.new(
        ~w(resources resource_versions note_versions document_versions document_fragments resource_assets asset_objects assets tags resource_tags),
        fn table ->
          case query(
                 MigrationRepo,
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
