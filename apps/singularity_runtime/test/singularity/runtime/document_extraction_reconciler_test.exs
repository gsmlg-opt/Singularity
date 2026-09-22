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
