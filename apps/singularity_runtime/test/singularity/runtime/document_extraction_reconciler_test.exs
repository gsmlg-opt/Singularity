defmodule Singularity.Runtime.DocumentExtractionReconcilerTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Runtime.Documents.ExtractionReconciler
  alias Singularity.Storage.Postgres.DocumentRepository

  alias Singularity.Storage.{
    Fixtures,
    KnowledgeFixtures,
    KnowledgeTestGrants,
    MigrationRepo,
    ScopedRepo
  }

  test "expired attempt recovers once with a successor event and fences the old job" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    old_job = KnowledgeFixtures.uuid()
    grant_read!(source)
    claim_expired!(document, old_job)

    assert %{rows: [["extracting", 1, true]]} =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 "SELECT state,attempt_generation,attempt_deadline_at < clock_timestamp() FROM content.document_versions WHERE resource_version_id=$1",
                 [document.resource_version_id]
               )
             end)

    assert {:ok, [{version, owner}]} =
             DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 100)

    assert version == Ecto.UUID.load!(document.resource_version_id)
    assert owner == Ecto.UUID.load!(document.vault_id)

    assert %{rows: [[_, _, caps]]} =
             ScopedRepo.transact(
               WorkerRepo,
               %{principal_id: source.principal_id, vault_id: source.vault_id},
               fn repo ->
                 query!(
                   repo,
                   "SELECT principal_id,vault_id,capabilities FROM core.live_principal_authorization()",
                   []
                 )
               end
             )

    assert "asset.read" in caps
    assert {:ok, 1} = ExtractionReconciler.run(%{repo: WorkerRepo})
    assert {:ok, 0} = ExtractionReconciler.run(%{repo: WorkerRepo})

    assert %{rows: [["pending", 2, nil]]} =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 "SELECT state, attempt_generation, attempt_job_id FROM content.document_versions WHERE resource_version_id=$1",
                 [document.resource_version_id]
               )
             end)

    assert %{rows: [[1, payload]]} =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 "SELECT count(*), max(payload::text) FROM core.outbox_events WHERE idempotency_key=$1",
                 ["document-extraction:#{Ecto.UUID.load!(document.resource_version_id)}:2"]
               )
             end)

    assert payload =~ Ecto.UUID.load!(document.resource_version_id)
    refute payload =~ "source bytes"

    assert %{rows: [[2]]} =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 "SELECT expected_entity_revision FROM core.outbox_events WHERE idempotency_key=$1",
                 ["document-extraction:#{Ecto.UUID.load!(document.resource_version_id)}:2"]
               )
             end)

    KnowledgeTestGrants.with_lifecycle_grants(fn ->
      for sql <- [
            "SELECT content.fail_document_extraction($1,$2,1,'failed','timeout')",
            "SELECT content.complete_document_extraction($1,$2,1,'[]'::jsonb,decode(repeat('00',32),'hex'),NULL)"
          ] do
        assert_raise Postgrex.Error, fn ->
          ScopedRepo.transact(
            RequestRepo,
            %{principal_id: source.principal_id, vault_id: source.vault_id},
            fn repo -> query!(repo, sql, [document.resource_version_id, old_job]) end
          )
        end
      end
    end)
  end

  test "unexpired and terminal attempts are not recovered" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    {ready, _fragment} = KnowledgeFixtures.ready_document!(source)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.document_versions SET state='extracting', attempt_generation=1, attempt_job_id=$2, attempt_started_at=transaction_timestamp(), attempt_deadline_at=transaction_timestamp()+interval '180 seconds', extraction_adapter='plain', extraction_format=1 WHERE resource_version_id=$1",
        [document.resource_version_id, KnowledgeFixtures.uuid()]
      )
    end)

    assert {:ok, 0} = ExtractionReconciler.run(%{repo: WorkerRepo})

    assert %{rows: [["ready"]]} =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 "SELECT state FROM content.document_versions WHERE resource_version_id=$1",
                 [ready.resource_version_id]
               )
             end)
  end

  test "a newly started reconciler runs a recovery pass" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    grant_read!(source)
    claim_expired!(document, KnowledgeFixtures.uuid())

    {:ok, pid} = ExtractionReconciler.start_link(name: :document_recovery_test)

    try do
      assert Enum.any?(1..30, fn _ ->
               if state_generation(document).rows == [[2]] do
                 true
               else
                 Process.sleep(20)
                 false
               end
             end)

      assert %{rows: [[1]]} = recovery_event_count(document)
    after
      GenServer.stop(pid)
    end
  end

  test "concurrent passes create exactly one successor" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    grant_read!(source)
    claim_expired!(document, KnowledgeFixtures.uuid())

    results =
      1..2
      |> Task.async_stream(fn _ -> ExtractionReconciler.run(%{repo: WorkerRepo}) end,
        max_concurrency: 2,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.sort(results) == [{:ok, 0}, {:ok, 1}]
    assert %{rows: [[2]]} = state_generation(document)
    assert %{rows: [[1]]} = recovery_event_count(document)
  end

  test "revoked original principal leaves expired attempt fenced without an event" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    grant_read!(source)
    claim_expired!(document, KnowledgeFixtures.uuid())
    Fixtures.revoke_membership!(source)

    assert {:ok, 0} = ExtractionReconciler.run(%{repo: WorkerRepo})
    assert %{rows: [[1]]} = state_generation(document)
    assert %{rows: [[0]]} = recovery_event_count(document)
  end

  test "locked custody does not prevent recovery; deleted Documents are not redispatched" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    grant_read!(source)
    claim_expired!(document, KnowledgeFixtures.uuid())

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=true WHERE id=$1", [source.vault_id])
    end)

    assert {:ok, 1} = ExtractionReconciler.run(%{repo: WorkerRepo})
    assert %{rows: [[1]]} = recovery_event_count(document)

    deleted = KnowledgeFixtures.document!(source)
    claim_expired!(deleted, KnowledgeFixtures.uuid())

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=clock_timestamp() WHERE id=$1",
        [deleted.resource_id]
      )
    end)

    assert {:ok, 0} = ExtractionReconciler.run(%{repo: WorkerRepo})
    assert %{rows: [[1]]} = state_generation(deleted)
    assert %{rows: [[0]]} = recovery_event_count(deleted)
  end

  test "recovery functions expose only narrow worker execution" do
    for signature <- [
          "content.expired_document_extraction_ids(integer)",
          "content.recover_expired_document_with_event(uuid,uuid)"
        ] do
      assert %{rows: [["singularity_table_owner", true, config, result, false]]} =
               query!(
                 RequestRepo,
                 """
                 SELECT pg_get_userbyid(p.proowner), p.prosecdef, p.proconfig,
                        pg_get_function_result(p.oid),
                        EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl,
                          acldefault('f', p.proowner))) AS a
                          WHERE a.grantee=0 AND a.privilege_type='EXECUTE')
                 FROM pg_proc AS p WHERE p.oid=to_regprocedure($1)
                 """,
                 [signature]
               )

      assert config == ["search_path=pg_catalog, content, core, identity"]

      assert result ==
               if(signature == "content.expired_document_extraction_ids(integer)",
                 do: "TABLE(version_id uuid, owner_id uuid)",
                 else: "boolean"
               )

      for role <- ~w(singularity_web singularity_dispatcher singularity_pre_auth) do
        assert %{rows: [[false]]} =
                 query!(RequestRepo, "SELECT has_function_privilege($1,$2,'EXECUTE')", [
                   role,
                   signature
                 ])
      end

      assert %{rows: [[true]]} =
               query!(RequestRepo, "SELECT has_function_privilege($1,$2,'EXECUTE')", [
                 "singularity_worker",
                 signature
               ])
    end

    for role <-
          ~w(singularity_web singularity_worker singularity_dispatcher singularity_pre_auth),
        table <- ~w(content.document_versions content.document_fragments) do
      for privilege <- ~w(INSERT UPDATE DELETE) do
        assert %{rows: [[false]]} =
                 query!(RequestRepo, "SELECT has_table_privilege($1,$2,$3)", [
                   role,
                   table,
                   privilege
                 ])
      end

      for privilege <- ~w(INSERT UPDATE) do
        assert %{rows: [[false]]} =
                 query!(RequestRepo, "SELECT has_any_column_privilege($1,$2,$3)", [
                   role,
                   table,
                   privilege
                 ])
      end
    end

    for table <- ~w(content.document_versions content.document_fragments) do
      assert %{rows: [[false, false]]} =
               query!(
                 RequestRepo,
                 "SELECT has_table_privilege($1,$2,'SELECT'), has_any_column_privilege($1,$2,'SELECT')",
                 ["singularity_worker", table]
               )
    end
  end

  test "worker scanner returns only version and owner UUIDs for an expired Document" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    retire_document_on_exit(document)
    grant_read!(source)
    claim_expired!(document, KnowledgeFixtures.uuid())

    result = query!(WorkerRepo, "SELECT * FROM content.expired_document_extraction_ids(100)")
    assert result.columns == ["version_id", "owner_id"]
    assert [document.resource_version_id, document.vault_id] in result.rows

    for [version, owner] <- result.rows do
      assert {:ok, _} = Ecto.UUID.load(version)
      assert {:ok, _} = Ecto.UUID.load(owner)
    end

    assert {:ok, pairs} =
             DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 100)

    assert {Ecto.UUID.load!(document.resource_version_id), Ecto.UUID.load!(document.vault_id)} in pairs
  end

  test "successor collision rolls back recovery while a same-source control recovers once" do
    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    retire_document_on_exit(document)
    old_job = KnowledgeFixtures.uuid()
    grant_read!(source)
    claim_expired!(document, old_job)
    assert_expired_attempt!(document, old_job)

    collision_id = KnowledgeFixtures.uuid()
    collision = insert_collision!(source, document, old_job, collision_id)
    version = Ecto.UUID.load!(document.resource_version_id)
    owner = Ecto.UUID.load!(document.vault_id)

    assert collision["id"] == Ecto.UUID.load!(collision_id)
    assert collision["event_type"] == "document.extraction_requested"
    assert collision["idempotency_key"] == "document-extraction:#{version}:2"
    assert collision["vault_id"] == owner
    assert collision["principal_id"] == Ecto.UUID.load!(source.principal_id)
    assert collision["required_capability"] == "asset.read"
    assert is_integer(collision["principal_authorization_epoch"])
    assert is_integer(collision["vault_authorization_epoch"])
    assert collision["classification"] == "private"
    assert collision["correlation_id"] == version
    assert collision["causation_id"] == Ecto.UUID.load!(old_job)
    assert collision["expected_entity_revision"] == 2
    assert collision["envelope_version"] == 1

    assert collision["payload"] == %{
             "resource_id" => Ecto.UUID.load!(document.resource_id),
             "resource_version_id" => version
           }

    before = recovery_snapshot(source)
    assert before.outbox_events == [collision]
    assert before.document_fragments == []
    assert [source_projection] = before.asset_search_documents
    assert source_projection["asset_id"] == Ecto.UUID.load!(source.asset_id)
    assert source_projection["resource_version_id"] == Ecto.UUID.load!(source.resource_version_id)
    assert source_projection["vault_id"] == owner
    refute Enum.any?(before.asset_search_documents, &(&1["resource_version_id"] == version))
    assert before.source_pins == 1
    expected = {:error, Singularity.Core.Error.new(:conflict)}

    assert expected ==
             DocumentRepository.recover_expired_with_event(%{repo: WorkerRepo}, version, owner)

    assert before == recovery_snapshot(source)

    assert {:ok, ids} =
             DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 100)

    assert {version, owner} in ids
    assert expected == ExtractionReconciler.run(%{repo: WorkerRepo})
    assert before == recovery_snapshot(source)

    assert {:ok, ids} =
             DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 100)

    assert {version, owner} in ids

    control = KnowledgeFixtures.document!(source)
    retire_document_on_exit(control)
    control_job = KnowledgeFixtures.uuid()
    claim_expired!(control, control_job)
    assert_expired_attempt!(control, control_job)
    control_before = recovery_snapshot(source)
    assert control_before.source_pins == 2
    control_version = Ecto.UUID.load!(control.resource_version_id)
    assert control_before.asset_search_documents == before.asset_search_documents

    refute Enum.any?(
             control_before.asset_search_documents,
             &(&1["resource_version_id"] == control_version)
           )

    assert {:ok, true} =
             DocumentRepository.recover_expired_with_event(
               %{repo: WorkerRepo},
               control_version,
               owner
             )

    recovered = recovery_snapshot(source)

    assert Map.drop(recovered, [:document_versions, :outbox_events]) ==
             Map.drop(control_before, [:document_versions, :outbox_events])

    cleared_fields =
      Map.new(
        ~w(attempt_job_id attempt_started_at attempt_deadline_at extraction_adapter extraction_format extracted_text_digest detected_language failure_code attempt_finished_at),
        &{&1, nil}
      )

    expected_documents =
      Enum.map(control_before.document_versions, fn row ->
        if row["resource_version_id"] == control_version do
          row
          |> Map.merge(cleared_fields)
          |> Map.merge(%{"state" => "pending", "attempt_generation" => 2})
        else
          row
        end
      end)

    assert recovered.document_versions == expected_documents
    assert [successor] = recovered.outbox_events -- control_before.outbox_events

    assert recovered.outbox_events ==
             Enum.sort_by(control_before.outbox_events ++ [successor], & &1["id"])

    assert successor["event_type"] == "document.extraction_requested"
    assert successor["idempotency_key"] == "document-extraction:#{control_version}:2"
    assert successor["vault_id"] == owner
    assert successor["principal_id"] == Ecto.UUID.load!(source.principal_id)
    assert successor["required_capability"] == "asset.read"

    assert successor["principal_authorization_epoch"] ==
             collision["principal_authorization_epoch"]

    assert successor["vault_authorization_epoch"] == collision["vault_authorization_epoch"]
    assert successor["classification"] == "private"
    assert successor["correlation_id"] == control_version
    assert successor["causation_id"] == Ecto.UUID.load!(control_job)
    assert successor["expected_entity_revision"] == 2
    assert successor["envelope_version"] == 1

    assert successor["payload"] == %{
             "resource_id" => Ecto.UUID.load!(control.resource_id),
             "resource_version_id" => control_version
           }

    assert {:ok, false} =
             DocumentRepository.recover_expired_with_event(
               %{repo: WorkerRepo},
               control_version,
               owner
             )

    assert recovered == recovery_snapshot(source)
  end

  defp retire_document_on_exit(document) do
    on_exit(fn ->
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=clock_timestamp() WHERE id=$1 AND vault_id=$2 AND deleted_at IS NULL",
          [document.resource_id, document.vault_id]
        )
      end)
    end)
  end

  defp assert_expired_attempt!(document, job_id) do
    assert %{rows: [["extracting", 1, ^job_id, true, nil, nil, nil, nil]]} =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 """
                 SELECT state, attempt_generation, attempt_job_id,
                        attempt_deadline_at < clock_timestamp(), extracted_text_digest,
                        detected_language, failure_code, attempt_finished_at
                 FROM content.document_versions WHERE resource_version_id=$1 AND vault_id=$2
                 """,
                 [document.resource_version_id, document.vault_id]
               )
             end)
  end

  defp insert_collision!(source, document, old_job, event_id) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [Ecto.UUID.load!(source.principal_id), Ecto.UUID.load!(source.vault_id)]
      )

      assert %{num_rows: 1} =
               query!(
                 MigrationRepo,
                 """
                 INSERT INTO core.outbox_events
                   (id,event_type,idempotency_key,vault_id,principal_id,required_capability,
                    principal_authorization_epoch,vault_authorization_epoch,classification,
                    correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at)
                 SELECT $1,'document.extraction_requested','document-extraction:' || $2::uuid::text || ':2',
                   $4,$5,'asset.read',a.principal_authorization_epoch,a.vault_authorization_epoch,
                   'private',$2,$6,2,1,
                   jsonb_build_object('resource_id',$3::uuid,'resource_version_id',$2::uuid),clock_timestamp()
                 FROM core.live_principal_authorization() AS a
                 WHERE a.principal_id=$5 AND a.vault_id=$4
                 """,
                 [
                   event_id,
                   document.resource_version_id,
                   document.resource_id,
                   document.vault_id,
                   source.principal_id,
                   old_job
                 ]
               )

      assert %{rows: [[event]]} =
               query!(
                 MigrationRepo,
                 "SELECT to_jsonb(e) FROM core.outbox_events AS e WHERE id=$1 AND vault_id=$2",
                 [event_id, document.vault_id]
               )

      event
    end)
  end

  defp recovery_snapshot(source) do
    Fixtures.with_owner(fn ->
      tables = [
        {:document_versions, "content.document_versions", "resource_version_id"},
        {:resources, "content.resources", "id"},
        {:resource_versions, "content.resource_versions", "id"},
        {:assets, "content.assets", "id"},
        {:asset_objects, "content.asset_objects", "id"},
        {:resource_assets, "content.resource_assets", "resource_version_id, asset_id"},
        {:outbox_events, "core.outbox_events", "id"},
        {:document_fragments, "content.document_fragments", "id"},
        {:asset_search_documents, "content.asset_search_documents", "asset_id"}
      ]

      rows =
        Map.new(tables, fn {key, table, order} ->
          result =
            query!(
              MigrationRepo,
              "SELECT to_jsonb(r) FROM #{table} AS r WHERE vault_id=$1 ORDER BY #{order}",
              [source.vault_id]
            )

          {key, Enum.map(result.rows, fn [row] -> row end)}
        end)

      %{rows: [[pins]]} =
        query!(
          MigrationRepo,
          "SELECT count(*) FROM content.document_versions WHERE vault_id=$1 AND source_object_id=$2",
          [source.vault_id, source.object_id]
        )

      Map.put(rows, :source_pins, pins)
    end)
  end

  defp claim_expired!(document, job_id) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.document_versions SET state='extracting', attempt_generation=1, attempt_job_id=$2, attempt_started_at=transaction_timestamp()-interval '181 seconds', attempt_deadline_at=transaction_timestamp()-interval '1 second', extraction_adapter='plain', extraction_format=1 WHERE resource_version_id=$1",
        [document.resource_version_id, job_id]
      )
    end)
  end

  defp grant_read!(source) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.read') ON CONFLICT (name) DO NOTHING",
        [KnowledgeFixtures.uuid()]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.principal_capabilities (principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
        [source.principal_id, source.vault_id]
      )
    end)
  end

  defp state_generation(document) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT attempt_generation FROM content.document_versions WHERE resource_version_id=$1",
        [document.resource_version_id]
      )
    end)
  end

  defp recovery_event_count(document) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT count(*) FROM core.outbox_events WHERE idempotency_key=$1",
        ["document-extraction:#{Ecto.UUID.load!(document.resource_version_id)}:2"]
      )
    end)
  end
end
