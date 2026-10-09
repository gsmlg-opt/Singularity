defmodule Singularity.Storage.Postgres.DocumentProjectionEventsTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.{DocumentCompletion, DocumentFragment, Error, JobEnvelope, SourceLocator}
  alias Singularity.Storage.Jobs.WorkerScope
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, SafeSQL, ScopedRepo}
  alias Singularity.Storage.Postgres.DocumentWorkerRepository

  @projection_types ~w(document.ready document.deleted document.restored)

  setup do
    source = KnowledgeFixtures.prepared_source!()

    binary_source =
      Map.new(source, fn {key, value} ->
        {key,
         if(String.ends_with?(Atom.to_string(key), "_id"),
           do: Ecto.UUID.dump!(value),
           else: value
         )}
      end)

    document = KnowledgeFixtures.document!(binary_source)
    job = KnowledgeFixtures.uuid()
    grant_read!(binary_source)

    envelope =
      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [
          binary_source.vault_id
        ])

        {principal_epoch, owner_epoch} = epochs(binary_source)
        payload = payload(document)
        key = "document-extraction:" <> Ecto.UUID.load!(document.resource_version_id)

        query!(
          MigrationRepo,
          """
          INSERT INTO core.outbox_events
            (id,event_type,idempotency_key,vault_id,principal_id,required_capability,
             principal_authorization_epoch,vault_authorization_epoch,classification,
             correlation_id,expected_entity_revision,envelope_version,payload,occurred_at)
          VALUES ($1,'document.extraction_requested',$2,$3,$4,'asset.read',$5,$6,
            'private',$1,0,1,$7::jsonb,CURRENT_TIMESTAMP)
          """,
          [
            job,
            key,
            binary_source.vault_id,
            binary_source.principal_id,
            principal_epoch,
            owner_epoch,
            payload
          ]
        )

        {:ok, envelope} =
          JobEnvelope.new(%{
            version: 1,
            job_id: Ecto.UUID.load!(job),
            job_type: "document_extract",
            idempotency_key: key,
            vault_id: source.vault_id,
            principal_id: source.principal_id,
            required_capability: "asset.read",
            principal_authorization_epoch: principal_epoch,
            vault_authorization_epoch: owner_epoch,
            classification: :private,
            correlation_id: Ecto.UUID.load!(job),
            causation_id: Ecto.UUID.load!(job),
            expected_entity_revision: 0,
            attempt: 37,
            payload: payload
          })

        envelope
      end)

    %{
      source: binary_source,
      document: document,
      envelope: envelope,
      scope: %{principal_id: source.principal_id, vault_id: source.vault_id}
    }
  end

  test "real worker completion emits one exact ready envelope and terminal replay emits none",
       c do
    claimed = claim!(c)
    retained = source_retention(c)
    assert {:ok, %{state: :ready, generation: 1}} = complete(c, claimed)
    assert [event] = projection_events(c)
    assert_projection_event(event, c, "document.ready")
    assert event["expected_entity_revision"] == 0
    refute event["expected_entity_revision"] == claimed.attempt.generation
    assert canonical_state(c) == ["ready", 1, Ecto.UUID.dump!(c.envelope.job_id), false, 1]
    assert source_retention(c) == retained
    assert projection_rows(c) == []

    for _replay <- 1..2 do
      assert {:ok, %{state: :ready, generation: 1}} = complete(c, claimed)
      assert projection_events(c) == [event]
    end
  end

  test "two delete restore cycles retain distinct UUID keys without changing version or generation",
       c do
    assert {:ok, %{state: :ready}} = complete(c, claim!(c))
    assert_reconciled(c, 1)
    assert [_entry] = visible_projection_rows(c)

    for cycle <- 1..2 do
      assert_lifecycle(c, :delete)
      assert projection_rows(c) == []
      assert visible_projection_rows(c) == []
      deleted_events = projection_events(c)
      assert_lifecycle(c, :delete)
      assert projection_events(c) == deleted_events

      assert_lifecycle(c, :restore)
      assert projection_rows(c) == []
      assert visible_projection_rows(c) == []
      restored_events = projection_events(c)
      assert_lifecycle(c, :restore)
      assert projection_events(c) == restored_events
      assert canonical_state(c) == ["ready", 1, Ecto.UUID.dump!(c.envelope.job_id), false, 1]
      assert_reconciled(c, 1)
      assert [_entry] = visible_projection_rows(c)
      assert Enum.count(restored_events) == 1 + cycle * 2
    end

    events = projection_events(c)

    assert Enum.frequencies_by(events, & &1["event_type"]) ==
             %{"document.ready" => 1, "document.deleted" => 2, "document.restored" => 2}

    for event <- events, do: assert_projection_event(event, c, event["event_type"])
    assert Enum.uniq_by(events, & &1["id"]) == events
    assert Enum.uniq_by(events, & &1["idempotency_key"]) == events
  end

  test "completion after a real tombstone retains canonical extraction with no visible projection",
       c do
    claimed = claim!(c)
    retained = source_retention(c)
    assert_lifecycle(c, :delete)
    assert {:ok, %{state: :ready, generation: 1}} = complete(c, claimed)
    assert canonical_state(c) == ["ready", 1, Ecto.UUID.dump!(c.envelope.job_id), true, 1]
    assert source_retention(c) == retained
    assert projection_rows(c) == []

    Fixtures.with_owner(fn ->
      assert %{rows: [[0]]} =
               query!(MigrationRepo, "SELECT content.reconcile_search_resource_internal($1,$2)", [
                 c.source.vault_id,
                 c.document.resource_id
               ])
    end)

    assert visible_projection_rows(c) == []
    assert [deleted, ready] = projection_events(c)
    assert_projection_event(deleted, c, "document.deleted")
    assert_projection_event(ready, c, "document.ready")
    assert {:ok, %{state: :ready}} = complete(c, claimed)
    assert projection_events(c) == [deleted, ready]
  end

  test "ready event insert failure rolls back fragments and terminal state while retaining the source",
       c do
    claimed = claim!(c)
    before = snapshot(c)

    with_event_failure(c, "document.ready", fn _constraint ->
      assert {:error, %Error{}} = complete(c, claimed)
      assert snapshot(c) == before
    end)

    assert {:ok, %{state: :ready}} = complete(c, claimed)
    assert [event] = projection_events(c)
    assert_projection_event(event, c, "document.ready")
  end

  test "delete event insert failure rolls back the tombstone and synchronous projection removal",
       c do
    assert {:ok, %{state: :ready}} = complete(c, claim!(c))
    assert_reconciled(c, 1)
    before = snapshot(c)

    with_event_failure(c, "document.deleted", fn constraint ->
      assert {:error, %Postgrex.Error{postgres: %{constraint: ^constraint}}} =
               lifecycle(c, :delete)

      assert snapshot(c) == before
      assert [_entry] = visible_projection_rows(c)
    end)

    assert_lifecycle(c, :delete)
    assert projection_rows(c) == []
  end

  test "restore event insert failure rolls back the ready tombstone transition and retained projection state",
       c do
    assert {:ok, %{state: :ready}} = complete(c, claim!(c))
    assert_reconciled(c, 1)
    assert_lifecycle(c, :delete)
    before = snapshot(c)

    with_event_failure(c, "document.restored", fn constraint ->
      assert {:error, %Postgrex.Error{postgres: %{constraint: ^constraint}}} =
               lifecycle(c, :restore)

      assert snapshot(c) == before
      assert visible_projection_rows(c) == []
    end)

    assert_lifecycle(c, :restore)
    assert projection_rows(c) == []
    assert_reconciled(c, 1)
  end

  test "pending restore event failure also rolls back generation and extraction scheduling", c do
    assert_lifecycle(c, :delete)
    before = snapshot(c)

    with_event_failure(c, "document.restored", fn constraint ->
      assert {:error, %Postgrex.Error{postgres: %{constraint: ^constraint}}} =
               lifecycle(c, :restore)

      assert snapshot(c) == before
    end)

    assert_lifecycle(c, :restore)
    assert canonical_state(c) == ["pending", 1, nil, false, 0]
    assert [initial, successor] = extraction_events(c)
    assert initial["id"] == Ecto.UUID.dump!(c.envelope.job_id)
    assert_extraction_event(successor, c, 1)
    events = snapshot(c)
    assert_lifecycle(c, :restore)
    assert snapshot(c) == events
  end

  test "retry preserves the generation bound extraction envelope and emits no ready lifecycle event",
       c do
    claimed = claim!(c)
    assert {:ok, %{state: :failed}} = fail(c, claimed)
    assert_lifecycle(c, :retry)
    assert canonical_state(c) == ["pending", 2, nil, false, 0]
    assert [initial, successor] = extraction_events(c)
    assert initial["id"] == Ecto.UUID.dump!(c.envelope.job_id)
    assert_extraction_event(successor, c, 2)
    assert projection_events(c) == []
    assert_lifecycle(c, :retry)
    assert extraction_events(c) == [initial, successor]
  end

  test "expired attempt recovery preserves its existing successor envelope through the worker role",
       c do
    claim!(c)
    expire!(c)

    assert %{rows: [[true]]} =
             query!(WorkerRepo, "SELECT content.recover_expired_document_with_event($1,$2)", [
               c.document.resource_version_id,
               c.source.vault_id
             ])

    assert canonical_state(c) == ["pending", 2, nil, false, 0]
    assert [initial, successor] = extraction_events(c)
    assert initial["id"] == Ecto.UUID.dump!(c.envelope.job_id)
    assert_extraction_event(successor, c, 2)
    assert successor["correlation_id"] == c.document.resource_version_id
    assert successor["causation_id"] == Ecto.UUID.dump!(c.envelope.job_id)
    assert projection_events(c) == []

    assert %{rows: [[false]]} =
             query!(WorkerRepo, "SELECT content.recover_expired_document_with_event($1,$2)", [
               c.document.resource_version_id,
               c.source.vault_id
             ])

    assert extraction_events(c) == [initial, successor]
  end

  test "trusted private completion records its actual scoped actor rather than the stored creator",
       c do
    claimed = claim!(c)
    actor = alternate_actor!(c)
    refute actor.principal_id == c.source.principal_id
    completion = claimed.completion

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [Ecto.UUID.load!(actor.principal_id), c.scope.vault_id]
      )

      assert %{rows: [["ready"]]} =
               query!(
                 MigrationRepo,
                 "SELECT state FROM content.complete_document_extraction($1,$2,$3,$4,$5,$6)",
                 [
                   c.document.resource_version_id,
                   Ecto.UUID.dump!(c.envelope.job_id),
                   claimed.attempt.generation,
                   fragment_maps(completion),
                   completion.extracted_text_digest,
                   completion.detected_language
                 ]
               )
    end)

    assert [event] = projection_events(c)
    actor_context = %{c | source: Map.merge(c.source, actor)}
    assert_projection_event(event, actor_context, "document.ready")
  end

  test "web lifecycle preserves creator and asset.read authority without emitting unauthorized events",
       c do
    actor = alternate_actor!(c)
    grant_read!(actor)

    alternate = %{
      c
      | scope: %{principal_id: Ecto.UUID.load!(actor.principal_id), vault_id: c.scope.vault_id}
    }

    assert {:ok, %{rows: [[nil]]}} = lifecycle(alternate, :delete)
    assert projection_events(c) == []

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
        [c.source.principal_id, c.source.vault_id]
      )
    end)

    assert {:error,
            %Postgrex.Error{postgres: %{constraint: "document_extraction_authority_check"}}} =
             lifecycle(c, :delete)

    assert canonical_state(c) == ["pending", 0, nil, false, 0]
    assert projection_events(c) == []
  end

  test "worker completion preserves read committed isolation and private helper ACLs", c do
    claimed = claim!(c)

    args = [
      c.document.resource_id,
      c.document.resource_version_id,
      Ecto.UUID.dump!(c.envelope.job_id),
      c.envelope.expected_entity_revision,
      c.envelope.principal_authorization_epoch,
      c.envelope.vault_authorization_epoch,
      claimed.attempt.generation,
      "plain",
      1,
      "text/plain",
      fragment_maps(claimed.completion),
      claimed.completion.extracted_text_digest,
      "en"
    ]

    WorkerRepo.checkout(fn ->
      assert {:error, %Postgrex.Error{postgres: %{constraint: "document_extraction_input_check"}}} =
               ScopedRepo.transact(WorkerRepo, c.scope, [isolation: :repeatable_read], fn repo ->
                 SafeSQL.query(
                   repo,
                   "SELECT * FROM content.complete_document_worker($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)",
                   args
                 )
               end)
    end)

    for repo <- [RequestRepo, WorkerRepo, DispatcherRepo, PreAuthRepo] do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               SafeSQL.query(repo, "SELECT content.document_runtime_target($1,true)", [
                 c.document.resource_id
               ])

      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               SafeSQL.query(
                 repo,
                 "SELECT content.complete_document_extraction($1,$2,1,$3,$4,'en')",
                 [
                   c.document.resource_version_id,
                   Ecto.UUID.dump!(c.envelope.job_id),
                   fragment_maps(claimed.completion),
                   claimed.completion.extracted_text_digest
                 ]
               )
    end

    assert canonical_state(c) == ["extracting", 1, Ecto.UUID.dump!(c.envelope.job_id), false, 0]
    assert projection_events(c) == []
  end

  test "runtime target locks Resource before waiting for Document without writing projections",
       c do
    start_supervised!({MigrationRepo, pool_size: 3})
    parent = self()
    reference = make_ref()

    blocker =
      Task.async(fn ->
        {:ok, :ok} =
          MigrationRepo.transaction(fn ->
            query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

            query!(
              MigrationRepo,
              "SELECT resource_version_id FROM content.document_versions WHERE resource_version_id=$1 FOR UPDATE",
              [c.document.resource_version_id]
            )

            send(parent, {reference, :document_locked})

            receive do
              {^reference, :release} -> :ok
            after
              5_000 -> raise "Document runtime lock barrier timed out"
            end
          end)

        :ok
      end)

    try do
      assert_receive {^reference, :document_locked}, 5_000

      mutation =
        Task.async(fn ->
          RequestRepo.checkout(fn ->
            ScopedRepo.transact(RequestRepo, c.scope, fn repo ->
              %{rows: [[backend]]} = SafeSQL.query!(repo, "SELECT pg_backend_pid()")
              send(parent, {reference, :mutation_backend, backend})

              SafeSQL.query(repo, "SELECT content.delete_document_runtime($1)", [
                c.document.resource_id
              ])
            end)
          end)
        end)

      try do
        assert_receive {^reference, :mutation_backend, backend}, 5_000
        assert await_row_wait(backend, System.monotonic_time(:millisecond) + 4_000)

        assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
                 MigrationRepo.transaction(fn ->
                   query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                   case SafeSQL.query(
                          MigrationRepo,
                          "SELECT id FROM content.resources WHERE id=$1 FOR UPDATE NOWAIT",
                          [c.document.resource_id]
                        ) do
                     {:error, error} -> MigrationRepo.rollback(error)
                     success -> success
                   end
                 end)

        assert %{rows: [[false]]} =
                 query!(
                   MigrationRepo,
                   """
                   SELECT EXISTS(SELECT FROM pg_locks AS lock
                     JOIN pg_class AS relation ON relation.oid=lock.relation
                     JOIN pg_namespace AS namespace ON namespace.oid=relation.relnamespace
                     WHERE lock.pid=$1 AND lock.mode='RowExclusiveLock' AND lock.granted
                       AND namespace.nspname='content' AND relation.relname='search_entries')
                   """,
                   [backend]
                 )

        send(blocker.pid, {reference, :release})
        assert :ok = Task.await(blocker, 5_000)
        resource_id = c.document.resource_id
        assert {:ok, %{rows: [[^resource_id]]}} = Task.await(mutation, 5_000)
      after
        send(blocker.pid, {reference, :release})
        drain_task(blocker)
        drain_task(mutation)
      end
    after
      send(blocker.pid, {reference, :release})
      drain_task(blocker)
    end
  end

  defp claim!(c) do
    WorkerScope.run(c.envelope, fn context ->
      assert context.repo_handle == WorkerRepo
      assert {:ok, {:source, source}} = DocumentWorkerRepository.describe(context, c.envelope)
      assert {:ok, attempt} = DocumentWorkerRepository.claim(context, c.envelope, "plain", 1)
      %{source: source, attempt: attempt, completion: completion(c, attempt, :ready)}
    end)
  end

  defp complete(c, claimed) do
    WorkerScope.run(c.envelope, fn context ->
      DocumentWorkerRepository.complete(
        context,
        c.envelope,
        claimed.source,
        claimed.attempt,
        claimed.completion
      )
    end)
  end

  defp fail(c, claimed) do
    WorkerScope.run(c.envelope, fn context ->
      DocumentWorkerRepository.complete(
        context,
        c.envelope,
        claimed.source,
        claimed.attempt,
        completion(c, claimed.attempt, :failed)
      )
    end)
  end

  defp completion(c, attempt, outcome) do
    {:ok, fragment} =
      DocumentFragment.new(%{
        resource_id: Ecto.UUID.load!(c.document.resource_id),
        resource_version_id: Ecto.UUID.load!(c.document.resource_version_id),
        owner_scope_id: c.scope.vault_id,
        classification: :private,
        ordinal: 0,
        text: "projection event private canary",
        locator: %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
      })

    {:ok, completion} =
      DocumentCompletion.new(%{
        resource_id: fragment.resource_id,
        resource_version_id: fragment.resource_version_id,
        owner_scope_id: c.scope.vault_id,
        classification: :private,
        generation: attempt.generation,
        outcome: outcome,
        adapter_name: attempt.adapter_name,
        format_version: attempt.format_version,
        finished_at: DateTime.utc_now(),
        media_type: "text/plain",
        fragments: if(outcome == :ready, do: [fragment]),
        extracted_text_digest: if(outcome == :ready, do: fragment.digest),
        detected_language: if(outcome == :ready, do: "en"),
        failure_code: if(outcome != :ready, do: "extractor_failed")
      })

    completion
  end

  defp fragment_maps(completion) do
    Enum.map(completion.fragments, fn fragment ->
      %{
        "id" => fragment.fragment_id,
        "ordinal" => fragment.ordinal,
        "text" => fragment.text,
        "digest" => Base.encode16(fragment.digest, case: :lower),
        "locator" => SourceLocator.to_map(fragment.locator)
      }
    end)
  end

  defp lifecycle(c, operation) do
    sql =
      case operation do
        :delete -> "SELECT content.delete_document_runtime($1)"
        :restore -> "SELECT content.restore_document_runtime($1,'plain',1)"
        :retry -> "SELECT content.retry_document_runtime($1,'plain',1)"
      end

    RequestRepo.checkout(fn ->
      ScopedRepo.transact(RequestRepo, c.scope, fn repo ->
        SafeSQL.query(repo, sql, [c.document.resource_id])
      end)
    end)
  end

  defp assert_lifecycle(c, operation) do
    resource_id = c.document.resource_id
    assert {:ok, %{rows: [[^resource_id]]}} = lifecycle(c, operation)
  end

  defp assert_reconciled(c, count) do
    RequestRepo.checkout(fn ->
      assert {:ok, %{rows: [[^count]]}} =
               ScopedRepo.transact(RequestRepo, c.scope, fn repo ->
                 SafeSQL.query(repo, "SELECT content.reconcile_search_resource($1)", [
                   c.document.resource_id
                 ])
               end)
    end)
  end

  defp projection_rows(c) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "SELECT entry_id,resource_version_id,fragment_id,title,body,locator FROM content.search_entries WHERE resource_id=$1 ORDER BY entry_id",
        [c.document.resource_id]
      ).rows
    end)
  end

  defp visible_projection_rows(c) do
    RequestRepo.checkout(fn ->
      ScopedRepo.transact(RequestRepo, c.scope, fn repo ->
        query!(
          repo,
          """
          SELECT entry.entry_id FROM content.search_entries AS entry
          JOIN content.resources AS resource ON resource.id=entry.resource_id
            AND resource.vault_id=entry.vault_id AND resource.classification=entry.classification
            AND resource.current_version_id=entry.resource_version_id
          JOIN content.document_versions AS document ON document.resource_version_id=entry.resource_version_id
            AND document.resource_id=entry.resource_id AND document.vault_id=entry.vault_id
          WHERE entry.resource_id=$1 AND resource.deleted_at IS NULL AND document.state='ready'
          ORDER BY entry.entry_id
          """,
          [c.document.resource_id]
        ).rows
      end)
    end)
  end

  defp canonical_state(c) do
    Fixtures.with_owner(fn ->
      %{rows: [row]} =
        query!(
          MigrationRepo,
          """
          SELECT document.state,document.attempt_generation,document.attempt_job_id,
            resource.deleted_at IS NOT NULL,
            (SELECT count(*) FROM content.document_fragments WHERE resource_version_id=document.resource_version_id)
          FROM content.document_versions AS document JOIN content.resources AS resource ON resource.id=document.resource_id
          WHERE document.resource_version_id=$1
          """,
          [c.document.resource_version_id]
        )

      row
    end)
  end

  # This proves retained SQL object identity and byte metadata, not live decryption.
  defp source_retention(c) do
    Fixtures.with_owner(fn ->
      rows =
        query!(
          MigrationRepo,
          """
          SELECT object.id,object.lookup_digest,object.ciphertext_hash,object.plaintext_byte_size,
            object.ciphertext_byte_size,object.storage_ref,object.lifecycle,
            (SELECT count(*) FROM content.document_versions WHERE source_object_id=object.id AND vault_id=object.vault_id),
            (SELECT count(*) FROM content.assets WHERE asset_object_id=object.id AND vault_id=object.vault_id AND state='available')
          FROM content.asset_objects AS object WHERE object.id=$1
          """,
          [c.source.object_id]
        ).rows

      object_id = c.source.object_id

      assert [
               [
                 ^object_id,
                 _lookup_digest,
                 _ciphertext_hash,
                 12,
                 100,
                 _storage_ref,
                 "available",
                 1,
                 1
               ]
             ] = rows

      rows
    end)
  end

  defp snapshot(c),
    do: %{
      state: canonical_state(c),
      source: source_retention(c),
      projection: projection_rows(c),
      events: events(c, @projection_types ++ ["document.extraction_requested"])
    }

  defp projection_events(c), do: events(c, @projection_types)
  defp extraction_events(c), do: events(c, ["document.extraction_requested"])

  defp events(c, types) do
    Fixtures.with_owner(fn ->
      result =
        query!(
          MigrationRepo,
          """
          SELECT id,event_type,idempotency_key,vault_id,principal_id,required_capability,
            principal_authorization_epoch,vault_authorization_epoch,classification,
            correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at
          FROM core.outbox_events WHERE vault_id=$1 AND payload->>'resource_id'=$2
            AND event_type=ANY($3::text[]) ORDER BY occurred_at,id
          """,
          [c.source.vault_id, Ecto.UUID.load!(c.document.resource_id), types]
        )

      Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
    end)
  end

  defp assert_projection_event(event, c, type) do
    assert_common_event(event, c, type)
    assert event["idempotency_key"] == "document-projection:" <> Ecto.UUID.load!(event["id"])
    assert event["expected_entity_revision"] == 0
  end

  defp assert_extraction_event(event, c, generation) do
    assert_common_event(event, c, "document.extraction_requested")

    assert event["idempotency_key"] ==
             "document-extraction:#{Ecto.UUID.load!(c.document.resource_version_id)}:#{generation}"

    assert event["expected_entity_revision"] == generation
  end

  defp assert_common_event(event, c, type) do
    expected_epochs = Fixtures.with_owner(fn -> epochs(c.source) end)
    assert event["event_type"] == type
    assert event["vault_id"] == c.source.vault_id
    assert event["principal_id"] == c.source.principal_id

    assert {event["principal_authorization_epoch"], event["vault_authorization_epoch"]} ==
             expected_epochs

    assert event["required_capability"] == "asset.read"
    assert event["classification"] == "private"
    assert event["envelope_version"] == 1
    assert event["payload"] == payload(c.document)
    assert {:ok, _} = Ecto.UUID.load(event["id"])
    assert {:ok, _} = Ecto.UUID.load(event["correlation_id"])
    refute is_nil(event["occurred_at"])
  end

  defp payload(document),
    do: %{
      "resource_id" => Ecto.UUID.load!(document.resource_id),
      "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
    }

  defp epochs(source) do
    %{rows: [[principal_epoch, owner_epoch]]} =
      query!(
        MigrationRepo,
        "SELECT principal.authorization_epoch,owner.authorization_epoch FROM identity.principals AS principal CROSS JOIN core.vaults AS owner WHERE principal.id=$1 AND owner.id=$2",
        [source.principal_id, source.vault_id]
      )

    {principal_epoch, owner_epoch}
  end

  defp grant_read!(source) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.read') ON CONFLICT(name) DO NOTHING",
        [KnowledgeFixtures.uuid()]
      )

      query!(
        MigrationRepo,
        "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
        [source.principal_id, source.vault_id]
      )
    end)
  end

  defp alternate_actor!(c) do
    %{one: other} = Fixtures.two_vaults!()
    actor = %{principal_id: other.principal_id, vault_id: c.source.vault_id}

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO core.vault_members(principal_id,vault_id) VALUES($1,$2)",
        [actor.principal_id, actor.vault_id]
      )
    end)

    actor
  end

  defp with_event_failure(c, type, fun) do
    constraint = "document_projection_event_failure_#{System.unique_integer([:positive])}"
    resource = Ecto.UUID.load!(c.document.resource_id)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "ALTER TABLE core.outbox_events ADD CONSTRAINT #{constraint} CHECK(event_type <> '#{type}' OR payload->>'resource_id' <> '#{resource}') NOT VALID"
      )
    end)

    try do
      fun.(constraint)
    after
      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "ALTER TABLE core.outbox_events DROP CONSTRAINT #{constraint}")
      end)
    end
  end

  defp expire!(c) do
    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "SET CONSTRAINTS ALL IMMEDIATE")

      query!(
        MigrationRepo,
        "ALTER TABLE content.document_versions DISABLE TRIGGER document_versions_lifecycle_guard"
      )

      query!(
        MigrationRepo,
        "WITH expired AS (SELECT clock_timestamp()-interval '181 seconds' AS started) UPDATE content.document_versions SET attempt_started_at=expired.started,attempt_deadline_at=expired.started+interval '180 seconds' FROM expired WHERE resource_version_id=$1",
        [c.document.resource_version_id]
      )

      query!(
        MigrationRepo,
        "ALTER TABLE content.document_versions ENABLE TRIGGER document_versions_lifecycle_guard"
      )
    end)
  end

  defp await_row_wait(backend, deadline) do
    %{rows: [[waiting]]} =
      query!(
        MigrationRepo,
        "SELECT EXISTS(SELECT FROM pg_locks WHERE pid=$1 AND NOT granted AND locktype IN ('tuple','transactionid'))",
        [backend]
      )

    cond do
      waiting -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> await_row_wait(backend, deadline)
    end
  end

  defp drain_task(task) do
    if Process.alive?(task.pid) do
      Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    else
      Task.shutdown(task, :brutal_kill)
    end
  end
end
