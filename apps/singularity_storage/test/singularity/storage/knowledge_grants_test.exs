defmodule Singularity.Storage.KnowledgeGrantsTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @tables ~w(document_versions document_import_receipts document_fragments note_attachments note_citations note_source_set_seals tags resource_tags relationships)
  @web_read_tables ~w(document_versions document_fragments)
  @worker_read_tables ~w(document_versions document_fragments note_attachments note_citations tags resource_tags relationships)
  @canonical_web_grants %{
    "document_versions" => ~w(SELECT),
    "document_fragments" => ~w(SELECT),
    "note_attachments" => ~w(INSERT SELECT),
    "note_citations" => ~w(INSERT SELECT),
    "note_source_set_seals" => ~w(SELECT),
    "tags" => ~w(INSERT SELECT),
    "resource_tags" => ~w(DELETE INSERT SELECT),
    "relationships" => ~w(DELETE INSERT SELECT)
  }
  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    ScopedRepo
  }

  test "temporary organization DELETE grants preserve preexisting ACLs after success" do
    assert_organization_delete_grants_preserved(:completed)
  end

  test "temporary organization DELETE grants preserve preexisting ACLs after an exception" do
    assert_organization_delete_grants_preserved(:raise)
  end

  test "temporary organization DELETE grants preserve preexisting ACLs after a throw" do
    assert_organization_delete_grants_preserved(:throw)
  end

  test "direct mutation grant cleanup preserves baseline Document reads after success" do
    assert_document_baseline_grants()

    assert :completed ==
             KnowledgeTestGrants.with_direct_mutation_grants(fn ->
               assert_temporary_document_mutation_grants()
               :completed
             end)

    assert_document_baseline_grants()
  end

  test "direct mutation grant cleanup preserves baseline Document reads after an exception" do
    assert_document_baseline_grants()

    assert_raise RuntimeError, "intentional mutation grant-scope failure", fn ->
      KnowledgeTestGrants.with_direct_mutation_grants(fn ->
        assert_temporary_document_mutation_grants()
        raise "intentional mutation grant-scope failure"
      end)
    end

    assert_document_baseline_grants()
  end

  test "baseline web and worker Document reads require owner scope and an active authorized principal" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    {document, _fragment} = KnowledgeFixtures.ready_document!(source)
    {other_document, _other_fragment} = KnowledgeFixtures.ready_document!(other)

    for repo <- [RequestRepo, WorkerRepo], table <- @web_read_tables do
      assert %{rows: []} = query!(repo, "SELECT resource_version_id FROM content.#{table}")

      assert %{rows: [[version]]} =
               ScopedRepo.transact(repo, source, fn scoped ->
                 query!(scoped, "SELECT resource_version_id FROM content.#{table}")
               end)

      assert version == document.resource_version_id

      assert %{rows: []} =
               ScopedRepo.transact(repo, source, fn scoped ->
                 query!(
                   scoped,
                   "SELECT resource_version_id FROM content.#{table} WHERE resource_version_id=$1",
                   [
                     other_document.resource_version_id
                   ]
                 )
               end)

      assert %{rows: []} =
               ScopedRepo.transact(repo, %{source | vault_id: other.vault_id}, fn scoped ->
                 query!(scoped, "SELECT resource_version_id FROM content.#{table}")
               end)
    end

    Fixtures.revoke_membership!(source)

    for repo <- [RequestRepo, WorkerRepo], table <- @web_read_tables do
      assert %{rows: []} =
               ScopedRepo.transact(repo, source, fn scoped ->
                 query!(scoped, "SELECT resource_version_id FROM content.#{table}")
               end)
    end
  end

  test "temporary isolated grants preserve missing-scope, cross-owner and revoked-principal isolation" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    KnowledgeFixtures.document!(other)

    KnowledgeTestGrants.with_grants(["document_versions"], fn ->
      for repo <- [RequestRepo, WorkerRepo] do
        assert %{rows: []} =
                 query!(repo, "SELECT resource_version_id FROM content.document_versions")

        assert %{rows: [[version]]} =
                 ScopedRepo.transact(repo, source, fn scoped ->
                   query!(scoped, "SELECT resource_version_id FROM content.document_versions")
                 end)

        assert version == document.resource_version_id

        assert %{rows: []} =
                 ScopedRepo.transact(repo, %{source | vault_id: other.vault_id}, fn scoped ->
                   query!(scoped, "SELECT resource_version_id FROM content.document_versions")
                 end)
      end

      Fixtures.revoke_membership!(source)

      assert %{rows: []} =
               ScopedRepo.transact(RequestRepo, source, fn repo ->
                 query!(repo, "SELECT resource_version_id FROM content.document_versions")
               end)
    end)
  end

  test "receipt policies require both matching owner and principal with temporary grants" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    second_principal = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO identity.principals (id, account_id, kind) VALUES ($1,$2,'owner')",
        [second_principal, source.account_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.vault_members (principal_id,vault_id) VALUES ($1,$2)",
        [second_principal, source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.document_import_receipts (vault_id,principal_id,mutation_id,request_fingerprint,state,resource_id,version_id,inserted_at) VALUES ($1,$2,$3,$4,'completed',$5,$6,CURRENT_TIMESTAMP)",
        [
          source.vault_id,
          source.principal_id,
          KnowledgeFixtures.uuid(),
          source.digest,
          document.resource_id,
          document.resource_version_id
        ]
      )
    end)

    KnowledgeTestGrants.with_grants(["document_import_receipts"], fn ->
      for repo <- [RequestRepo, WorkerRepo] do
        assert %{rows: [[1]]} =
                 ScopedRepo.transact(repo, source, fn scoped ->
                   query!(scoped, "SELECT count(*) FROM content.document_import_receipts")
                 end)

        assert %{rows: [[0]]} =
                 ScopedRepo.transact(
                   repo,
                   %{source | principal_id: second_principal},
                   fn scoped ->
                     query!(scoped, "SELECT count(*) FROM content.document_import_receipts")
                   end
                 )
      end
    end)
  end

  test "temporary grant cleanup runs after failure and rejects non-allowlisted targets" do
    assert_raise RuntimeError, "intentional grant-scope failure", fn ->
      KnowledgeTestGrants.with_grants(["document_versions"], fn ->
        raise "intentional grant-scope failure"
      end)
    end

    for role <- ~w(singularity_web singularity_worker), privilege <- ~w(SELECT INSERT) do
      expected = privilege in canonical_privileges(role, "document_versions")

      assert %{rows: [[^expected]]} =
               query!(
                 RequestRepo,
                 "SELECT has_table_privilege($1, 'content.document_versions', $2)",
                 [role, privilege]
               )
    end

    assert_raise ArgumentError, fn ->
      KnowledgeTestGrants.with_grants(["note_versions"], fn -> :ok end)
    end

    for role <- ~w(singularity_web singularity_worker) do
      assert %{rows: [[false]]} =
               query!(
                 RequestRepo,
                 "SELECT has_function_privilege($1,'content.document_trim_name(text)','EXECUTE')",
                 [role]
               )
    end
  end

  test "aggregate trigger functions grant no PUBLIC or effective runtime execution" do
    for function <-
          ~w(enforce_knowledge_typed_head enforce_document_source enforce_document_resource_version_update enforce_document_import_receipt enforce_note_source_immutable enforce_note_source_set enforce_knowledge_organization_resource) do
      signature = "content.#{function}()"

      assert %{rows: [[oid]]} =
               query!(RequestRepo, "SELECT to_regprocedure($1)::oid", [signature])

      assert is_integer(oid)

      for role <-
            ~w(singularity_web singularity_worker singularity_dispatcher singularity_pre_auth) do
        assert %{rows: [[false]]} =
                 query!(RequestRepo, "SELECT has_function_privilege($1, $2, 'EXECUTE')", [
                   role,
                   signature
                 ])
      end

      assert %{rows: []} =
               query!(
                 RequestRepo,
                 """
                 SELECT acl.grantee FROM pg_proc AS function
                 CROSS JOIN LATERAL aclexplode(coalesce(function.proacl, acldefault('f', function.proowner))) AS acl
                 WHERE function.oid = to_regprocedure($1) AND acl.grantee <> function.proowner
                 """,
                 [signature]
               )
    end
  end

  test "lifecycle functions are owner-defined with fixed search path and no public or runtime execution" do
    for signature <- [
          "claim_document_extraction(uuid,bigint,text,integer)",
          "complete_document_extraction(uuid,bigint,jsonb,bytea,text)",
          "fail_document_extraction(uuid,bigint,text,text)",
          "reset_document_extraction(uuid,bigint)"
        ] do
      assert %{rows: [[nil]]} =
               query!(RequestRepo, "SELECT to_regprocedure($1)", ["content." <> signature])
    end

    for signature <- [
          "content.claim_document_extraction(uuid,bigint,uuid,text,integer)",
          "content.complete_document_extraction(uuid,uuid,bigint,jsonb,bytea,text)",
          "content.fail_document_extraction(uuid,uuid,bigint,text,text)",
          "content.reset_document_extraction(uuid,bigint,text,integer)",
          "content.recover_document_extraction(uuid,bigint)"
        ] do
      assert %{rows: [[true, "singularity_table_owner", config]]} =
               query!(
                 RequestRepo,
                 """
                 SELECT p.prosecdef, pg_get_userbyid(p.proowner), p.proconfig
                 FROM pg_proc AS p WHERE p.oid = to_regprocedure($1)
                 """,
                 [signature]
               )

      assert "search_path=pg_catalog, content, core, identity" in config

      for role <-
            ~w(singularity_web singularity_worker singularity_dispatcher singularity_pre_auth) do
        assert %{rows: [[false]]} =
                 query!(RequestRepo, "SELECT has_function_privilege($1,$2,'EXECUTE')", [
                   role,
                   signature
                 ])
      end

      assert %{rows: []} =
               query!(
                 RequestRepo,
                 """
                 SELECT acl.grantee FROM pg_proc AS p
                 CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f',p.proowner))) AS acl
                 WHERE p.oid = to_regprocedure($1) AND acl.grantee <> p.proowner
                 """,
                 [signature]
               )
    end
  end

  test "temporary lifecycle and mutation grants restore the baseline after failures" do
    for helper <- [
          :with_lifecycle_grants,
          :with_direct_mutation_grants,
          :with_receipt_grants,
          :with_fragment_read_grants
        ] do
      assert_raise RuntimeError, "intentional grant-scope failure", fn ->
        apply(KnowledgeTestGrants, helper, [fn -> raise "intentional grant-scope failure" end])
      end
    end

    for role <- ~w(singularity_web singularity_worker),
        table <- ~w(document_versions document_fragments document_import_receipts),
        privilege <- ~w(SELECT INSERT UPDATE DELETE) do
      expected = privilege in canonical_privileges(role, table)

      assert %{rows: [[^expected]]} =
               query!(RequestRepo, "SELECT has_table_privilege($1,$2,$3)", [
                 role,
                 "content.#{table}",
                 privilege
               ])
    end

    for role <- ~w(singularity_web singularity_worker) do
      assert %{rows: [[false]]} =
               query!(
                 RequestRepo,
                 "SELECT has_function_privilege($1,'content.claim_document_extraction(uuid,bigint,uuid,text,integer)','EXECUTE')",
                 [role]
               )
    end
  end

  test "canonical tables enforce RLS and exactly the web organization and worker backup read grants" do
    for table <- @tables do
      assert %{rows: [[true, true]]} =
               query!(
                 RequestRepo,
                 "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = to_regclass($1)",
                 ["content.#{table}"]
               )

      for role <-
            ~w(singularity_web singularity_worker singularity_dispatcher singularity_pre_auth),
          privilege <- ~w(SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER) do
        expected = privilege in canonical_privileges(role, table)

        assert %{rows: [[^expected]]} =
                 query!(RequestRepo, "SELECT has_table_privilege($1, $2, $3)", [
                   role,
                   "content.#{table}",
                   privilege
                 ])
      end

      expected_acl =
        for role <- ~w(singularity_web singularity_worker),
            privilege <- canonical_privileges(role, table),
            do: [role, privilege, false]

      assert %{rows: ^expected_acl} =
               query!(
                 RequestRepo,
                 """
                 SELECT pg_get_userbyid(acl.grantee), acl.privilege_type, acl.is_grantable
                 FROM pg_class AS relation
                 CROSS JOIN LATERAL aclexplode(coalesce(relation.relacl, acldefault('r', relation.relowner))) AS acl
                 WHERE relation.oid = to_regclass($1) AND acl.grantee <> relation.relowner
                 ORDER BY pg_get_userbyid(acl.grantee), acl.privilege_type
                 """,
                 ["content.#{table}"]
               )

      for {repo, role} <- [
            {RequestRepo, "singularity_web"},
            {WorkerRepo, "singularity_worker"},
            {DispatcherRepo, "singularity_dispatcher"},
            {PreAuthRepo, "singularity_pre_auth"}
          ] do
        if "SELECT" in canonical_privileges(role, table) do
          assert %{rows: []} = query!(repo, "SELECT * FROM content.#{table}")
        else
          error =
            assert_raise Postgrex.Error, fn -> query!(repo, "SELECT * FROM content.#{table}") end

          assert error.postgres.code == :insufficient_privilege
        end

        if repo == RequestRepo and "DELETE" in Map.get(@canonical_web_grants, table, []) do
          assert %{num_rows: 0} = query!(repo, "DELETE FROM content.#{table}")
        else
          error =
            assert_raise Postgrex.Error, fn -> query!(repo, "DELETE FROM content.#{table}") end

          assert error.postgres.code == :insufficient_privilege
        end

        insert_error =
          assert_raise Postgrex.Error, fn ->
            query!(repo, "INSERT INTO content.#{table} DEFAULT VALUES")
          end

        if repo == RequestRepo and table in ~w(resource_tags relationships) do
          # Their BEFORE INSERT provenance guard rejects invalid default rows
          # before native RLS. Valid missing-scope rows are checked separately.
          assert insert_error.postgres.code == :check_violation
          assert insert_error.postgres.constraint == table <> "_resource_check"
        else
          assert insert_error.postgres.code == :insufficient_privilege
        end

        update_error =
          assert_raise Postgrex.Error, fn ->
            query!(repo, "UPDATE content.#{table} SET vault_id = vault_id")
          end

        assert update_error.postgres.code == :insufficient_privilege
      end
    end
  end

  defp assert_organization_delete_grants_preserved(outcome) do
    original_acl = organization_acls()

    original_permissions =
      for table <- ~w(resource_tags relationships),
          role <- ~w(singularity_web singularity_worker) do
        %{rows: [[allowed?]]} =
          query!(RequestRepo, "SELECT has_table_privilege($1,$2,'DELETE')", [
            role,
            "content.#{table}"
          ])

        {table, role, allowed?}
      end

    # Exercise both durable and temporary permissions in an allocated isolated
    # database. The outer finally restores every original permission and ACL.
    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "GRANT DELETE ON content.resource_tags TO singularity_web")
      query!(MigrationRepo, "GRANT DELETE ON content.relationships TO singularity_worker")
      query!(MigrationRepo, "REVOKE DELETE ON content.resource_tags FROM singularity_worker")
      query!(MigrationRepo, "REVOKE DELETE ON content.relationships FROM singularity_web")
    end)

    try do
      expected_acl = organization_acls()

      callback = fn ->
        for table <- ~w(resource_tags relationships),
            role <- ~w(singularity_web singularity_worker) do
          assert %{rows: [[true]]} =
                   query!(RequestRepo, "SELECT has_table_privilege($1,$2,'DELETE')", [
                     role,
                     "content.#{table}"
                   ])
        end

        organization_grant_outcome(outcome)
      end

      case outcome do
        :completed ->
          assert :completed == KnowledgeTestGrants.with_organization_delete_grants(callback)

        :raise ->
          assert_raise RuntimeError, "intentional organization grant failure", fn ->
            KnowledgeTestGrants.with_organization_delete_grants(callback)
          end

        :throw ->
          assert catch_throw(KnowledgeTestGrants.with_organization_delete_grants(callback)) ==
                   :intentional_organization_grant_failure
      end

      assert organization_acls() == expected_acl
    after
      Fixtures.with_owner(fn ->
        for {table, role, allowed?} <- original_permissions do
          statement =
            if allowed?,
              do: "GRANT DELETE ON content.#{table} TO #{role}",
              else: "REVOKE DELETE ON content.#{table} FROM #{role}"

          query!(MigrationRepo, statement)
        end
      end)

      assert organization_acls() == original_acl
    end
  end

  defp organization_grant_outcome(:completed), do: :completed
  defp organization_grant_outcome(:raise), do: raise("intentional organization grant failure")
  defp organization_grant_outcome(:throw), do: throw(:intentional_organization_grant_failure)

  defp organization_acls do
    for table <- ~w(resource_tags relationships) do
      %{rows: rows} =
        query!(
          RequestRepo,
          """
          SELECT pg_get_userbyid(acl.grantee), acl.privilege_type, acl.is_grantable
          FROM pg_class AS relation
          CROSS JOIN LATERAL aclexplode(coalesce(relation.relacl, acldefault('r', relation.relowner))) AS acl
          WHERE relation.oid=to_regclass($1) AND acl.grantee<>relation.relowner
          ORDER BY acl.grantee, acl.privilege_type
          """,
          ["content.#{table}"]
        )

      {table, rows}
    end
  end

  defp assert_temporary_document_mutation_grants do
    for role <- ~w(singularity_web singularity_worker),
        table <- ~w(document_versions document_fragments),
        privilege <- ~w(SELECT INSERT UPDATE DELETE) do
      assert %{rows: [[true]]} =
               query!(RequestRepo, "SELECT has_table_privilege($1,$2,$3)", [
                 role,
                 "content.#{table}",
                 privilege
               ])
    end
  end

  defp assert_document_baseline_grants do
    for role <-
          ~w(singularity_web singularity_worker singularity_dispatcher singularity_pre_auth),
        table <- ~w(document_versions document_fragments),
        privilege <- ~w(SELECT INSERT UPDATE DELETE) do
      expected = privilege in canonical_privileges(role, table)

      assert %{rows: [[^expected]]} =
               query!(RequestRepo, "SELECT has_table_privilege($1,$2,$3)", [
                 role,
                 "content.#{table}",
                 privilege
               ])
    end

    for repo <- [WorkerRepo, DispatcherRepo, PreAuthRepo],
        table <- ~w(document_versions document_fragments) do
      if repo == WorkerRepo do
        assert %{rows: []} = query!(repo, "SELECT * FROM content.#{table}")
      else
        error =
          assert_raise Postgrex.Error, fn -> query!(repo, "SELECT * FROM content.#{table}") end

        assert error.postgres.code == :insufficient_privilege
      end
    end
  end

  defp canonical_privileges("singularity_web", table),
    do: Map.get(@canonical_web_grants, table, [])

  defp canonical_privileges("singularity_worker", table),
    do: if(table in @worker_read_tables, do: ["SELECT"], else: [])

  defp canonical_privileges(_role, _table), do: []
end
