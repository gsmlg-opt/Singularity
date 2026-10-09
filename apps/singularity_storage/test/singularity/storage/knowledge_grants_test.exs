defmodule Singularity.Storage.KnowledgeGrantsTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  @tables ~w(document_versions document_import_receipts document_fragments note_attachments note_citations tags resource_tags relationships)
  @web_read_tables ~w(document_versions document_fragments)
  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    ScopedRepo
  }

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

  test "baseline web Document reads require owner scope and an active authorized principal" do
    source = KnowledgeFixtures.source!()
    other = KnowledgeFixtures.source!()
    {document, _fragment} = KnowledgeFixtures.ready_document!(source)
    {other_document, _other_fragment} = KnowledgeFixtures.ready_document!(other)

    for table <- @web_read_tables do
      assert %{rows: []} = query!(RequestRepo, "SELECT resource_version_id FROM content.#{table}")

      assert %{rows: [[version]]} =
               ScopedRepo.transact(RequestRepo, source, fn repo ->
                 query!(repo, "SELECT resource_version_id FROM content.#{table}")
               end)

      assert version == document.resource_version_id

      assert %{rows: []} =
               ScopedRepo.transact(RequestRepo, source, fn repo ->
                 query!(
                   repo,
                   "SELECT resource_version_id FROM content.#{table} WHERE resource_version_id=$1",
                   [
                     other_document.resource_version_id
                   ]
                 )
               end)

      assert %{rows: []} =
               ScopedRepo.transact(RequestRepo, %{source | vault_id: other.vault_id}, fn repo ->
                 query!(repo, "SELECT resource_version_id FROM content.#{table}")
               end)
    end

    Fixtures.revoke_membership!(source)

    for table <- @web_read_tables do
      assert %{rows: []} =
               ScopedRepo.transact(RequestRepo, source, fn repo ->
                 query!(repo, "SELECT resource_version_id FROM content.#{table}")
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
      expected = role == "singularity_web" and privilege == "SELECT"

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
      expected = role == "singularity_web" and table in @web_read_tables and privilege == "SELECT"

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

  test "canonical tables enforce RLS and exactly the two web-only Document read grants" do
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
        expected =
          role == "singularity_web" and table in @web_read_tables and privilege == "SELECT"

        assert %{rows: [[^expected]]} =
                 query!(RequestRepo, "SELECT has_table_privilege($1, $2, $3)", [
                   role,
                   "content.#{table}",
                   privilege
                 ])
      end

      expected_acl =
        if table in @web_read_tables, do: [["singularity_web", "SELECT", false]], else: []

      assert %{rows: ^expected_acl} =
               query!(
                 RequestRepo,
                 """
                 SELECT pg_get_userbyid(acl.grantee), acl.privilege_type, acl.is_grantable
                 FROM pg_class AS relation
                 CROSS JOIN LATERAL aclexplode(coalesce(relation.relacl, acldefault('r', relation.relowner))) AS acl
                 WHERE relation.oid = to_regclass($1) AND acl.grantee <> relation.relowner
                 ORDER BY acl.grantee, acl.privilege_type
                 """,
                 ["content.#{table}"]
               )

      for repo <- [RequestRepo, WorkerRepo, DispatcherRepo, PreAuthRepo] do
        if repo == RequestRepo and table in @web_read_tables do
          assert %{rows: []} = query!(repo, "SELECT * FROM content.#{table}")
        else
          error =
            assert_raise Postgrex.Error, fn -> query!(repo, "SELECT * FROM content.#{table}") end

          assert error.postgres.code == :insufficient_privilege
        end

        for statement <- [
              "DELETE FROM content.#{table}",
              "INSERT INTO content.#{table} DEFAULT VALUES",
              "UPDATE content.#{table} SET vault_id = vault_id"
            ] do
          error = assert_raise Postgrex.Error, fn -> query!(repo, statement) end
          assert error.postgres.code == :insufficient_privilege
        end
      end
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
      expected = role == "singularity_web" and privilege == "SELECT"

      assert %{rows: [[^expected]]} =
               query!(RequestRepo, "SELECT has_table_privilege($1,$2,$3)", [
                 role,
                 "content.#{table}",
                 privilege
               ])
    end

    for repo <- [WorkerRepo, DispatcherRepo, PreAuthRepo],
        table <- ~w(document_versions document_fragments) do
      error =
        assert_raise Postgrex.Error, fn -> query!(repo, "SELECT * FROM content.#{table}") end

      assert error.postgres.code == :insufficient_privilege
    end
  end
end
