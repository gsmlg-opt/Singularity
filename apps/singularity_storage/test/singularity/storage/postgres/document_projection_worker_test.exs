defmodule Singularity.Storage.Postgres.DocumentProjectionWorkerTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Core.{Error, JobEnvelope}
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, SafeSQL, ScopedRepo}
  alias Singularity.Storage.Jobs.{EnvelopeCodec, WorkerScope}
  alias Singularity.Storage.Postgres.SearchProjectionReconciler

  @signature "content.reconcile_document_search_worker(uuid,uuid,uuid,bigint,bigint,bigint)"

  setup do
    source = KnowledgeFixtures.source!()
    grant_read!(source)
    {document, fragment} = KnowledgeFixtures.ready_document!(source)

    scope = %{
      principal_id: Ecto.UUID.load!(source.principal_id),
      vault_id: Ecto.UUID.load!(source.vault_id)
    }

    c = %{source: source, document: document, fragment: fragment, scope: scope}

    %{rows: [[job, revision, principal_epoch, owner_epoch, correlation]]} =
      owner_query(
        """
        SELECT id,expected_entity_revision,principal_authorization_epoch,vault_authorization_epoch,correlation_id
        FROM core.outbox_events WHERE event_type='document.ready' AND vault_id=$1
          AND payload->>'resource_id'=$2
        """,
        [source.vault_id, Ecto.UUID.load!(document.resource_id)]
      )

    {:ok, envelope} =
      JobEnvelope.new(%{
        version: 1,
        job_id: Ecto.UUID.load!(job),
        job_type: "document_projection",
        idempotency_key: "document-projection:#{Ecto.UUID.load!(job)}",
        vault_id: scope.vault_id,
        principal_id: scope.principal_id,
        required_capability: "asset.read",
        principal_authorization_epoch: principal_epoch,
        vault_authorization_epoch: owner_epoch,
        classification: :private,
        correlation_id: Ecto.UUID.load!(correlation),
        causation_id: Ecto.UUID.load!(job),
        expected_entity_revision: revision,
        attempt: 0,
        payload: %{
          "resource_id" => Ecto.UUID.load!(document.resource_id),
          "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
        }
      })

    Map.merge(c, %{
      envelope: envelope,
      job: job,
      args: [
        document.resource_id,
        document.resource_version_id,
        job,
        revision,
        principal_epoch,
        owner_epoch
      ]
    })
  end

  test "real worker reconstructs immutable fragments repeatedly with only count metadata", c do
    pinned = source_pin(c)
    assert projection_rows(c) == []
    assert {:ok, %{columns: ["reconcile_document_search_worker"], rows: [[1]]}} = call(c)
    expected = projection_rows(c)
    assert [[_, _, _, _, _, "Document", "text", _, _]] = expected

    for _ <- 1..2 do
      assert {:ok, %{rows: [[1]]}} = call(c)
      assert projection_rows(c) == expected
    end

    assert source_pin(c) == pinned
  end

  test "dispatch acknowledgment remains executable but retired events fail closed", c do
    owner_query(
      "UPDATE core.outbox_events SET delivered_at=clock_timestamp(),runner_job_id='123' WHERE id=$1",
      [c.job]
    )

    assert {:ok, %{rows: [[1]]}} = call(c)
    expected = projection_rows(c)

    owner_query(
      "UPDATE core.outbox_events SET retired_at=clock_timestamp(),retirement_reason='restore_effect_already_reflected' WHERE id=$1",
      [c.job]
    )

    assert_denied(call(c))
    assert projection_rows(c) == expected
  end

  test "ready arriving after actual deletion cannot resurrect search content", c do
    lifecycle!(c, :delete)
    assert {:ok, %{rows: [[0]]}} = call(c)
    assert projection_rows(c) == []
  end

  test "delete arriving after restore rebuilds current state across duplicate out of order cycles",
       c do
    for _ <- 1..2 do
      lifecycle!(c, :delete)
      deleted = latest_event(c, "document.deleted")
      assert {:ok, %{rows: [[0]]}} = call(c, deleted)
      lifecycle!(c, :restore)
      restored = latest_event(c, "document.restored")
      assert {:ok, %{rows: [[1]]}} = call(c, deleted)
      expected = projection_rows(c)

      for event <- [restored, c.args, deleted, restored] do
        assert {:ok, %{rows: [[1]]}} = call(c, event)
        assert projection_rows(c) == expected
      end
    end
  end

  test "retained event revision does not require current head or extraction generation equality",
       c do
    owner_query(
      "UPDATE core.outbox_events SET expected_entity_revision=9223372036854775807 WHERE id=$1",
      [c.job]
    )

    args = List.replace_at(c.args, 3, 9_223_372_036_854_775_807)
    assert {:ok, %{rows: [[1]]}} = call(c, args)
    assert_denied(call(c))
  end

  test "old retained ready event reconciles a newer non ready canonical head", c do
    assert {:ok, %{rows: [[1]]}} = call(c)
    next_version = KnowledgeFixtures.uuid()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.resource_versions(id,resource_id,vault_id,classification,revision) VALUES($1,$2,$3,'private',1)",
        [next_version, c.document.resource_id, c.source.vault_id]
      )

      KnowledgeFixtures.insert_typed!(%{c.document | resource_version_id: next_version})

      query!(MigrationRepo, "UPDATE content.resources SET current_version_id=$1 WHERE id=$2", [
        next_version,
        c.document.resource_id
      ])
    end)

    for _ <- 1..2 do
      assert {:ok, %{rows: [[0]]}} = call(c)
      assert projection_rows(c) == []
    end
  end

  test "missing scoped context and stronger isolation fail before projection writes", c do
    for {principal, owner} <- [
          {"", ""},
          {"malformed", c.scope.vault_id},
          {c.scope.principal_id, "malformed"}
        ] do
      assert_denied(manual_call(c, principal, owner, "READ COMMITTED"))
    end

    for isolation <- ["REPEATABLE READ", "SERIALIZABLE"] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               manual_call(c, c.scope.principal_id, c.scope.vault_id, isolation)
    end

    assert projection_rows(c) == []
  end

  test "substituted resource version job revision and epochs are denied", c do
    for {index, value} <- [
          {0, KnowledgeFixtures.uuid()},
          {1, KnowledgeFixtures.uuid()},
          {2, KnowledgeFixtures.uuid()},
          {3, 1},
          {4, Enum.at(c.args, 4) + 1},
          {5, Enum.at(c.args, 5) + 1}
        ] do
      assert_denied(call(c, List.replace_at(c.args, index, value)))
    end

    for index <- 3..5 do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               call(c, List.replace_at(c.args, index, -1))
    end

    assert projection_rows(c) == []
  end

  test "every retained event authority field and exact payload are independently checked", c do
    for {field, forged, original} <- [
          {"event_type", "document.extraction_requested", "document.ready"},
          {"required_capability", "asset.write", "asset.read"},
          {"classification", "sensitive", "private"},
          {"envelope_version", 2, 1},
          {"principal_authorization_epoch", Enum.at(c.args, 4) + 1, Enum.at(c.args, 4)},
          {"vault_authorization_epoch", Enum.at(c.args, 5) + 1, Enum.at(c.args, 5)},
          {"idempotency_key", "document-projection:#{Ecto.UUID.generate()}",
           c.envelope.idempotency_key}
        ] do
      owner_query("UPDATE core.outbox_events SET #{field}=$2 WHERE id=$1", [c.job, forged])
      assert_denied(call(c))
      owner_query("UPDATE core.outbox_events SET #{field}=$2 WHERE id=$1", [c.job, original])
    end

    for payload <- [
          Map.put(c.envelope.payload, "body", "CONTENT_CANARY"),
          Map.put(c.envelope.payload, "resource_id", Ecto.UUID.generate()),
          Map.put(c.envelope.payload, "resource_version_id", Ecto.UUID.generate())
        ] do
      owner_query("UPDATE core.outbox_events SET payload=$2::jsonb WHERE id=$1", [c.job, payload])
      assert_denied(call(c))
    end

    assert projection_rows(c) == []
  end

  for {label, sql, key} <- [
        {"non owner principal kind", "UPDATE identity.principals SET kind='system' WHERE id=$1",
         :principal_id},
        {"revoked capability",
         "UPDATE core.principal_capabilities SET revoked_at=clock_timestamp() WHERE principal_id=$1",
         :principal_id},
        {"revoked principal",
         "UPDATE identity.principals SET revoked_at=clock_timestamp() WHERE id=$1",
         :principal_id},
        {"revoked membership",
         "UPDATE core.vault_members SET revoked_at=clock_timestamp() WHERE principal_id=$1",
         :principal_id},
        {"disabled owner account", "UPDATE identity.accounts SET status='disabled' WHERE id=$1",
         :account_id},
        {"stale principal authority",
         "UPDATE identity.principals SET authorization_epoch=authorization_epoch+1 WHERE id=$1",
         :principal_id},
        {"stale owner authority",
         "UPDATE core.vaults SET authorization_epoch=authorization_epoch+1 WHERE id=$1",
         :vault_id}
      ] do
    test "#{label} denies reconciliation without removing valid existing rows", c do
      assert {:ok, %{rows: [[1]]}} = call(c)
      expected = projection_rows(c)
      owner_query(unquote(sql), [Map.fetch!(c.source, unquote(key))])
      assert_denied(call(c))
      assert projection_rows(c) == expected
    end
  end

  test "live alternate actor matching the retained event cannot substitute the creator", c do
    %{one: outsider} = Fixtures.two_vaults!()
    grant_read!(outsider)

    owner_query(
      "INSERT INTO core.vault_members(principal_id,vault_id,clearance) VALUES($1,$2,'private')",
      [outsider.principal_id, c.source.vault_id]
    )

    owner_query(
      "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
      [outsider.principal_id, c.source.vault_id]
    )

    %{rows: [[epoch]]} =
      owner_query("SELECT authorization_epoch FROM identity.principals WHERE id=$1", [
        outsider.principal_id
      ])

    owner_query(
      "UPDATE core.outbox_events SET principal_id=$2,principal_authorization_epoch=$3 WHERE id=$1",
      [c.job, outsider.principal_id, epoch]
    )

    alternate = %{c | scope: %{c.scope | principal_id: Ecto.UUID.load!(outsider.principal_id)}}
    assert_denied(call(alternate, List.replace_at(c.args, 4, epoch)))

    assert_denied(
      call(%{
        c
        | scope: %{
            principal_id: Ecto.UUID.load!(outsider.principal_id),
            vault_id: Ecto.UUID.load!(outsider.vault_id)
          }
      })
    )

    assert projection_rows(c) == []
  end

  test "locked owner scope still permits the established no custody canonical projection", c do
    owner_query("UPDATE core.vaults SET locked=true WHERE id=$1", [c.source.vault_id])
    assert {:ok, %{rows: [[1]]}} = call(c)
  end

  test "SQL entrypoint retains the scoped shared authorization lock until commit", c do
    assert :ok =
             ScopedRepo.transact(WorkerRepo, c.scope, fn repo ->
               assert {:ok, %{rows: [[1]]}} = sql_call(repo, c.args)
               key = "singularity:authorization:#{c.scope.principal_id}:#{c.scope.vault_id}"

               assert %{rows: [[true]]} =
                        query!(
                          repo,
                          """
                          SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=pg_backend_pid()
                            AND locktype='advisory' AND mode='ShareLock' AND granted
                            AND classid=((hashtextextended($1,0)>>32)&4294967295)::oid
                            AND objid=(hashtextextended($1,0)&4294967295)::oid)
                          """,
                          [key]
                        )

               :ok
             end)
  end

  test "storage adapter validates direct callers and runs only inside scoped worker transactions",
       c do
    assert {:error, %Error{code: :invalid}} =
             apply(SearchProjectionReconciler, :reconcile_document, [WorkerRepo, c.envelope])

    for invalid <- [
          %{c.envelope | payload: Map.put(c.envelope.payload, "body", "CONTENT_CANARY")},
          %{c.envelope | principal_authorization_epoch: 9_223_372_036_854_775_808},
          %{c.envelope | idempotency_key: "document-projection:#{Ecto.UUID.generate()}"}
        ] do
      assert {:error, %Error{message: nil, details: %{}}} =
               apply(SearchProjectionReconciler, :reconcile_document, [WorkerRepo, invalid])
    end

    assert {:ok, _} = EnvelopeCodec.encode(c.envelope)

    WorkerScope.run(c.envelope, fn context ->
      for invalid <- [
            %{c.envelope | vault_id: Ecto.UUID.generate()},
            %{c.envelope | principal_id: Ecto.UUID.generate()}
          ] do
        assert {:error, %Error{code: :forbidden, message: nil, details: %{}}} =
                 context.transact.([], fn repo ->
                   apply(SearchProjectionReconciler, :reconcile_document, [repo, invalid])
                 end)

        assert projection_rows(c) == []
      end

      assert {:ok, 1} =
               context.transact.([], fn repo ->
                 apply(SearchProjectionReconciler, :reconcile_document, [repo, c.envelope])
               end)
    end)
  end

  test "worker definer ACL retains scoped Document reads and denies canonical writes and projection access",
       _c do
    assert %{
             rows: [
               [
                 "singularity_table_owner",
                 true,
                 "v",
                 ["search_path=pg_catalog, content, core, identity"]
               ]
             ]
           } =
             SafeSQL.query!(
               WorkerRepo,
               "SELECT pg_get_userbyid(proowner),prosecdef,provolatile::text,proconfig FROM pg_proc WHERE oid=to_regprocedure($1)",
               [@signature]
             )

    assert %{rows: [[true, false, false, false, false]]} =
             SafeSQL.query!(
               WorkerRepo,
               """
               SELECT has_function_privilege('singularity_worker',$1,'EXECUTE'),
                 has_function_privilege('singularity_web',$1,'EXECUTE'),
                 has_function_privilege('singularity_dispatcher',$1,'EXECUTE'),
                 has_function_privilege('singularity_pre_auth',$1,'EXECUTE'),
                 EXISTS(SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a
                   WHERE p.oid=to_regprocedure($1) AND a.grantee=0 AND a.privilege_type='EXECUTE')
               """,
               [@signature]
             )

    for table <- ~w(document_versions document_fragments search_entries),
        privilege <- ~w(SELECT INSERT UPDATE DELETE) do
      assert %{rows: [[allowed?]]} =
               SafeSQL.query!(
                 WorkerRepo,
                 "SELECT has_table_privilege('singularity_worker',$1,$2)",
                 ["content." <> table, privilege]
               )

      assert allowed? ==
               (privilege == "SELECT" and table in ~w(document_versions document_fragments))
    end

    assert %{rows: [[false]]} =
             SafeSQL.query!(
               WorkerRepo,
               "SELECT has_function_privilege('singularity_worker','content.reconcile_search_resource_internal(uuid,uuid)','EXECUTE')",
               []
             )

    Singularity.Storage.WorkerDocumentReadAssertions.assert_read_only_rls!()
  end

  defp grant_read!(source) do
    owner_query(
      "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.read') ON CONFLICT(name) DO NOTHING",
      [KnowledgeFixtures.uuid()]
    )

    owner_query(
      "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read' ON CONFLICT DO NOTHING",
      [source.principal_id, source.vault_id]
    )
  end

  defp call(c, args \\ nil) do
    WorkerRepo.checkout(fn ->
      ScopedRepo.transact(WorkerRepo, c.scope, fn repo -> sql_call(repo, args || c.args) end)
    end)
  end

  defp sql_call(repo, args),
    do:
      SafeSQL.query(
        repo,
        "SELECT content.reconcile_document_search_worker($1,$2,$3,$4,$5,$6)",
        args,
        log: false
      )

  defp manual_call(c, principal, owner, isolation) do
    WorkerRepo.checkout(fn ->
      case WorkerRepo.transaction(fn ->
             query!(WorkerRepo, "SET TRANSACTION ISOLATION LEVEL " <> isolation)

             query!(
               WorkerRepo,
               "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
               [principal, owner]
             )

             case sql_call(WorkerRepo, c.args) do
               {:error, error} -> WorkerRepo.rollback(error)
               result -> result
             end
           end) do
        {:ok, result} -> result
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp lifecycle!(c, operation) do
    owner_query("UPDATE core.vaults SET locked=false WHERE id=$1", [c.source.vault_id])

    assert {:ok, _} =
             ScopedRepo.transact(RequestRepo, c.scope, fn repo ->
               statement =
                 case operation do
                   :delete -> "SELECT content.delete_document_runtime($1)"
                   :restore -> "SELECT content.restore_document_runtime($1,'plain',1)"
                 end

               SafeSQL.query(repo, statement, [c.document.resource_id])
             end)
  end

  defp latest_event(c, type) do
    %{rows: [[id, revision, principal_epoch, owner_epoch]]} =
      owner_query(
        """
        SELECT id,expected_entity_revision,principal_authorization_epoch,vault_authorization_epoch
        FROM core.outbox_events WHERE vault_id=$1 AND event_type=$2 AND payload->>'resource_id'=$3
        ORDER BY occurred_at DESC LIMIT 1
        """,
        [c.source.vault_id, type, c.envelope.payload["resource_id"]]
      )

    [
      c.document.resource_id,
      c.document.resource_version_id,
      id,
      revision,
      principal_epoch,
      owner_epoch
    ]
  end

  defp projection_rows(c) do
    owner_query(
      "SELECT entry_id,resource_id,resource_version_id,fragment_id,ordinal,title,body,locator,source_inserted_at FROM content.search_entries WHERE resource_id=$1 ORDER BY ordinal",
      [c.document.resource_id]
    ).rows
  end

  # Metadata retention evidence only; this does not prove live source byte custody.
  defp source_pin(c),
    do:
      owner_query(
        "SELECT source_asset_id,source_resource_id,source_resource_version_id,source_object_id,source_digest,source_byte_size FROM content.document_versions WHERE resource_version_id=$1",
        [c.document.resource_version_id]
      ).rows

  defp owner_query(sql, args), do: Fixtures.with_owner(fn -> query!(MigrationRepo, sql, args) end)

  defp assert_denied(result),
    do: assert({:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} = result)
end
