defmodule Singularity.Storage.Postgres.DocumentWorkerRepositoryTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  import ExUnit.CaptureLog

  alias Singularity.Core.{DocumentCompletion, Error, JobEnvelope, SourceLocator}
  alias Singularity.Storage.Jobs.{EnvelopeCodec, WakeHandshake, WorkerScope}
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, SafeSQL, ScopedRepo}
  alias Singularity.Storage.Postgres.{DocumentWorkerRepository, KnowledgeError}

  @base "uuid,uuid,uuid,bigint,bigint,bigint"
  @signatures [
    "describe_document_worker(#{@base})",
    "claim_document_worker(#{@base},text,integer)",
    "complete_document_worker(#{@base},bigint,text,integer,text,jsonb,bytea,text)",
    "fail_document_worker(#{@base},bigint,text,integer,text,text,text)"
  ]
  @describe_columns ~w(kind resource_id resource_version_id job_id state generation object_id object_generation source_digest source_byte_size media_type adapter_name format_version started_at deadline_at)
  @claim_columns ~w(resource_id resource_version_id job_id generation state adapter_name format_version started_at deadline_at)
  @receipt_columns ~w(resource_id resource_version_id job_id generation state)

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

    {principal_epoch, owner_epoch} =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities (id,name) VALUES ($1,'asset.read') ON CONFLICT (name) DO NOTHING",
          [KnowledgeFixtures.uuid()]
        )

        assert %{num_rows: 1} =
                 query!(
                   MigrationRepo,
                   "INSERT INTO core.principal_capabilities (principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
                   [binary_source.principal_id, binary_source.vault_id]
                 )

        %{rows: [[principal_epoch, owner_epoch]]} =
          query!(
            MigrationRepo,
            "SELECT p.authorization_epoch,v.authorization_epoch FROM identity.principals p CROSS JOIN core.vaults v WHERE p.id=$1 AND v.id=$2",
            [binary_source.principal_id, binary_source.vault_id]
          )

        query!(
          MigrationRepo,
          """
          INSERT INTO core.outbox_events
            (id,event_type,idempotency_key,vault_id,principal_id,required_capability,
             principal_authorization_epoch,vault_authorization_epoch,classification,
             correlation_id,expected_entity_revision,envelope_version,payload,occurred_at)
          VALUES ($1,'document.extraction_requested',$2,$3,$4,'asset.read',$5,$6,'private',$1,0,1,$7::jsonb,CURRENT_TIMESTAMP)
          """,
          [
            job,
            "document-extraction:#{Ecto.UUID.load!(document.resource_version_id)}",
            document.vault_id,
            binary_source.principal_id,
            principal_epoch,
            owner_epoch,
            %{
              "resource_id" => Ecto.UUID.load!(document.resource_id),
              "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
            }
          ]
        )

        {principal_epoch, owner_epoch}
      end)

    %{
      source: binary_source,
      document: document,
      job: job,
      scope: %{principal_id: source.principal_id, vault_id: source.vault_id},
      args: [
        document.resource_id,
        document.resource_version_id,
        job,
        0,
        principal_epoch,
        owner_epoch
      ]
    }
  end

  test "adapter describes the durable job through actual WorkerScope with a closed source map",
       c do
    envelope = worker_envelope(c)

    WorkerScope.run(envelope, fn context ->
      assert context.repo_handle === WorkerRepo
      assert WorkerRepo.checked_out?()
      refute WorkerRepo.in_transaction?()

      assert {:ok, {:source, source}} = DocumentWorkerRepository.describe(context, envelope)

      assert source == %{
               resource_id: envelope.payload["resource_id"],
               resource_version_id: envelope.payload["resource_version_id"],
               job_id: envelope.job_id,
               generation: 0,
               state: :pending,
               object_id: Ecto.UUID.load!(c.source.object_id),
               object_generation: 1,
               source_digest: c.source.digest,
               source_byte_size: 12,
               media_type: "text/plain",
               adapter_name: nil,
               format_version: nil,
               started_at: nil,
               deadline_at: nil
             }

      assert_scope_absent()
    end)
  end

  test "adapter claims once and returns only a typed ready receipt on completion and replay", c do
    envelope = worker_envelope(c)

    WorkerScope.run(envelope, fn context ->
      assert {:ok, {:source, source}} = DocumentWorkerRepository.describe(context, envelope)
      assert {:ok, attempt} = DocumentWorkerRepository.claim(context, envelope, "plain", 1)

      assert Map.keys(attempt) |> Enum.sort() ==
               Enum.sort(
                 ~w(resource_id resource_version_id job_id generation state adapter_name format_version started_at deadline_at)a
               )

      assert %{
               generation: 1,
               state: :extracting,
               adapter_name: "plain",
               format_version: 1,
               started_at: %DateTime{},
               deadline_at: %DateTime{}
             } = attempt

      assert {:ok, ^attempt} = DocumentWorkerRepository.claim(context, envelope, "plain", 1)
      completion = worker_completion(c, attempt, :ready)

      receipt = %{
        resource_id: source.resource_id,
        resource_version_id: source.resource_version_id,
        job_id: envelope.job_id,
        generation: 1,
        state: :ready
      }

      assert {:ok, ^receipt} =
               DocumentWorkerRepository.complete(context, envelope, source, attempt, completion)

      assert {:ok, ^receipt} =
               DocumentWorkerRepository.complete(context, envelope, source, attempt, completion)

      assert {:ok, {:terminal, ^receipt}} = DocumentWorkerRepository.describe(context, envelope)

      assert {:ok, :unchanged} =
               DocumentWorkerRepository.record_exhaustion(
                 context,
                 envelope,
                 Error.new(:job_failed),
                 %{attempt: 37, max_attempts: 1}
               )

      assert_scope_absent()
    end)
  end

  test "adapter rejects absent or substituted context and nested transactions before mutation",
       c do
    envelope = worker_envelope(c)
    assert {:error, %Error{code: :invalid}} = DocumentWorkerRepository.describe(%{}, envelope)

    WorkerScope.run(envelope, fn context ->
      for invalid <- [
            Map.delete(context, :transact),
            %{context | repo_handle: RequestRepo},
            %{context | transact: nil},
            %{context | transact: fn _, phase -> phase.(WorkerRepo) end},
            %{context | transact: fn _, phase -> phase.(RequestRepo) end}
          ] do
        assert {:error, %Error{code: :invalid}} =
                 DocumentWorkerRepository.describe(invalid, envelope)
      end

      assert {:error, %Error{code: :invalid}} =
               context.transact.([], fn _repo ->
                 DocumentWorkerRepository.claim(context, envelope, "plain", 1)
               end)

      for invalid <- [
            %{envelope | payload: Map.put(envelope.payload, "repo_handle", "injected")},
            %{envelope | classification: :sensitive},
            %{envelope | expected_entity_revision: 9_223_372_036_854_775_807},
            %{envelope | principal_authorization_epoch: 9_223_372_036_854_775_808}
          ] do
        assert {:error, %Error{}} = DocumentWorkerRepository.describe(context, invalid)
      end

      assert_scope_absent()
    end)

    assert state(c) == ["pending", 0, nil]
  end

  test "adapter rejects completion identity and metadata mismatches without partial writes", c do
    envelope = worker_envelope(c)

    WorkerScope.run(envelope, fn context ->
      assert {:ok, {:source, source}} = DocumentWorkerRepository.describe(context, envelope)
      assert {:ok, attempt} = DocumentWorkerRepository.claim(context, envelope, "plain", 1)
      completion = worker_completion(c, attempt, :failed)

      for {key, value} <- [
            resource_id: Ecto.UUID.generate(),
            resource_version_id: Ecto.UUID.generate(),
            owner_scope_id: Ecto.UUID.generate(),
            classification: :sensitive,
            generation: 2,
            adapter_name: "other",
            format_version: 2,
            media_type: "application/pdf",
            failure_code: "private-tool-output-canary"
          ] do
        assert {:error, %Error{code: :invalid, message: nil, details: %{}}} =
                 DocumentWorkerRepository.complete(
                   context,
                   envelope,
                   source,
                   attempt,
                   Map.put(completion, key, value)
                 )
      end

      assert_scope_absent()
    end)

    assert state(c) == ["extracting", 1, c.job]
    assert no_fragments(c)
  end

  test "adapter rejects nonclosed or malformed source and attempt values", c do
    envelope = worker_envelope(c)

    WorkerScope.run(envelope, fn context ->
      assert {:ok, {:source, source}} = DocumentWorkerRepository.describe(context, envelope)
      assert {:ok, attempt} = DocumentWorkerRepository.claim(context, envelope, "plain", 1)
      completion = worker_completion(c, attempt, :failed)

      for invalid <- [
            Map.put(source, :title, "private-title-canary"),
            %{source | object_id: "invalid"},
            %{source | object_generation: 0},
            %{source | source_digest: <<0>>},
            %{source | source_byte_size: 67_108_865},
            %{source | state: :ready},
            %{source | media_type: "image/png"},
            %{source | resource_id: Ecto.UUID.generate()}
          ] do
        assert {:error, %Error{code: :invalid}} =
                 DocumentWorkerRepository.complete(
                   context,
                   envelope,
                   invalid,
                   attempt,
                   completion
                 )
      end

      for invalid <- [
            Map.put(attempt, :title, "private-title-canary"),
            %{attempt | job_id: Ecto.UUID.generate()},
            %{attempt | generation: 37},
            %{attempt | state: :pending},
            %{attempt | adapter_name: " plain "},
            %{attempt | format_version: 2_147_483_648},
            %{attempt | started_at: nil},
            %{attempt | deadline_at: attempt.started_at}
          ] do
        assert {:error, %Error{code: :invalid}} =
                 DocumentWorkerRepository.complete(context, envelope, source, invalid, completion)
      end
    end)

    assert state(c) == ["extracting", 1, c.job]
    assert no_fragments(c)
  end

  test "adapter rollback cleans the reused WorkerRepo connection", c do
    envelope = worker_envelope(c)

    WorkerScope.run(envelope, fn context ->
      assert {:ok, _} = DocumentWorkerRepository.claim(context, envelope, "plain", 1)

      assert {:error, %Error{code: :conflict, message: nil, details: %{}}} =
               DocumentWorkerRepository.claim(context, envelope, "other", 1)

      assert_scope_absent()

      assert {:ok, {:source, %{state: :extracting, generation: 1}}} =
               DocumentWorkerRepository.describe(context, envelope)

      assert_scope_absent()
    end)
  end

  test "adapter failed and unsupported outcomes return closed receipts", c do
    envelope = worker_envelope(c)

    WorkerScope.run(envelope, fn context ->
      assert {:ok, {:source, source}} = DocumentWorkerRepository.describe(context, envelope)
      assert {:ok, attempt} = DocumentWorkerRepository.claim(context, envelope, "plain", 1)

      receipt = %{
        resource_id: source.resource_id,
        resource_version_id: source.resource_version_id,
        job_id: envelope.job_id,
        generation: 1,
        state: :unsupported
      }

      assert {:ok, ^receipt} =
               DocumentWorkerRepository.complete(
                 context,
                 envelope,
                 source,
                 attempt,
                 worker_completion(c, attempt, :unsupported)
               )

      assert {:ok, {:terminal, ^receipt}} = DocumentWorkerRepository.describe(context, envelope)
    end)

    assert no_fragments(c)
  end

  test "exhaustion leaves an unclaimed pending document unchanged", c do
    envelope = worker_envelope(c)

    assert {:ok, :unchanged} =
             WorkerScope.run(envelope, fn context ->
               DocumentWorkerRepository.record_exhaustion(
                 context,
                 envelope,
                 Error.new(:job_failed, message: "private-tool-output-canary"),
                 %{attempt: 37, max_attempts: 1}
               )
             end)

    assert state(c) == ["pending", 0, nil]
    assert no_fragments(c)
  end

  test "exhaustion fails only the active same-job attempt with fixed sanitized outcome", c do
    envelope = worker_envelope(c)
    reference = make_ref()
    handler = {__MODULE__, reference}
    query_event = WorkerRepo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler,
        query_event,
        &__MODULE__.handle_private_event/4,
        {self(), reference}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    logs =
      capture_log(fn ->
        WorkerScope.run(envelope, fn context ->
          assert {:ok, attempt} = DocumentWorkerRepository.claim(context, envelope, "plain", 1)

          receipt = %{
            resource_id: attempt.resource_id,
            resource_version_id: attempt.resource_version_id,
            job_id: envelope.job_id,
            generation: 1,
            state: :failed
          }

          assert {:ok, ^receipt} =
                   DocumentWorkerRepository.record_exhaustion(
                     context,
                     envelope,
                     Error.new(:job_failed,
                       message: "private-tool-output-canary",
                       details: %{text: "private-title-canary"}
                     ),
                     %{attempt: 0, max_attempts: 0, job_id: "forged-runner-id"}
                   )

          assert {:ok, {:terminal, ^receipt}} =
                   DocumentWorkerRepository.describe(context, envelope)

          assert {:ok, :unchanged} =
                   DocumentWorkerRepository.record_exhaustion(
                     context,
                     envelope,
                     Error.new(:job_failed),
                     %{attempt: 100, max_attempts: 1}
                   )

          assert_scope_absent()
          send(self(), {reference, attempt})
        end)
      end)

    assert_receive {^reference, attempt}

    assert Fixtures.with_owner(fn ->
             query!(
               MigrationRepo,
               "SELECT state,failure_code,attempt_generation,attempt_started_at,attempt_deadline_at FROM content.document_versions WHERE resource_version_id=$1",
               [c.document.resource_version_id]
             ).rows
           end) == [["failed", "extractor_failed", 1, attempt.started_at, attempt.deadline_at]]

    refute logs =~ "private-tool-output-canary"
    refute logs =~ "private-title-canary"
    refute_receive {^reference, ^query_event, _, _}
    assert no_fragments(c)
  end

  test "exhaustion leaves an expired attempt unchanged", c do
    assert {:ok, _} = call(c, :claim, ["plain", 1])
    expire(c)
    envelope = worker_envelope(c)

    assert {:ok, :unchanged} =
             WorkerScope.run(envelope, fn context ->
               DocumentWorkerRepository.record_exhaustion(
                 context,
                 envelope,
                 Error.new(:job_failed),
                 %{}
               )
             end)

    assert state(c) == ["extracting", 1, c.job]
    assert no_fragments(c)
  end

  for transition <- [:recovery, :retry, :restore] do
    test "exhaustion cannot change pending or newly claimed successor after #{transition}", c do
      assert {:ok, _} = call(c, :claim, ["plain", 1])
      envelope = worker_envelope(c)
      transition(c, unquote(transition))

      assert {:ok, :unchanged} =
               WorkerScope.run(envelope, fn context ->
                 DocumentWorkerRepository.record_exhaustion(
                   context,
                   envelope,
                   Error.new(:job_failed),
                   %{}
                 )
               end)

      assert state(c) == ["pending", 2, nil]

      successor =
        Fixtures.with_owner(fn ->
          %{rows: [[job]]} =
            query!(
              MigrationRepo,
              "SELECT id FROM core.outbox_events WHERE vault_id=$1 AND payload->>'resource_version_id'=$2 AND expected_entity_revision=2",
              [c.source.vault_id, Ecto.UUID.load!(c.document.resource_version_id)]
            )

          %{c | job: job, args: c.args |> List.replace_at(2, job) |> List.replace_at(3, 2)}
        end)

      assert {:ok, _} = call(successor, :claim, ["plain", 1])

      assert {:ok, :unchanged} =
               WorkerScope.run(envelope, fn context ->
                 DocumentWorkerRepository.record_exhaustion(
                   context,
                   envelope,
                   Error.new(:job_failed),
                   %{}
                 )
               end)

      assert state(c) == ["extracting", 3, successor.job]
      assert no_fragments(c)
    end
  end

  test "exhaustion propagates live authorization failures", c do
    assert {:ok, _} = call(c, :claim, ["plain", 1])
    envelope = worker_envelope(c)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
        [c.source.principal_id, c.source.vault_id]
      )
    end)

    assert {:error, %Error{code: :forbidden, message: nil, details: %{}}} =
             WorkerScope.run(envelope, fn context ->
               DocumentWorkerRepository.record_exhaustion(
                 context,
                 envelope,
                 Error.new(:job_failed),
                 %{}
               )
             end)

    assert state(c) == ["extracting", 1, c.job]
    assert no_fragments(c)
  end

  test "adapter and exhaustion sanitize storage exceptions and propagate storage errors", c do
    envelope = worker_envelope(c)

    logs =
      capture_log(fn ->
        WorkerScope.run(envelope, fn context ->
          for transact <- [
                fn _, _ -> raise DBConnection.ConnectionError, "private-storage-canary" end,
                fn _, _ -> raise RuntimeError, "private-storage-canary" end,
                fn _, _ ->
                  {:error, %DBConnection.ConnectionError{message: "private-storage-canary"}}
                end
              ] do
            invalid = %{context | transact: transact}

            assert {:error,
                    %Error{
                      code: :storage_unavailable,
                      retryable?: true,
                      message: nil,
                      details: %{}
                    }} =
                     DocumentWorkerRepository.describe(invalid, envelope)

            assert {:error,
                    %Error{
                      code: :storage_unavailable,
                      retryable?: true,
                      message: nil,
                      details: %{}
                    }} =
                     DocumentWorkerRepository.record_exhaustion(
                       invalid,
                       envelope,
                       Error.new(:job_failed),
                       %{}
                     )
          end

          assert_scope_absent()
        end)
      end)

    refute logs =~ "private-storage-canary"
    assert state(c) == ["pending", 0, nil]
    assert no_fragments(c)
  end

  test "worker reads only the explicit pending source descriptor without canonical grants", c do
    assert {:ok, %{rows: [["singularity_worker"]]}} =
             SafeSQL.query(WorkerRepo, "SELECT current_user")

    assert {:ok,
            %{
              columns: @describe_columns,
              rows: [
                [
                  "source",
                  resource,
                  version,
                  job,
                  "pending",
                  0,
                  object,
                  1,
                  digest,
                  12,
                  "text/plain",
                  nil,
                  nil,
                  nil,
                  nil
                ]
              ]
            }} = call(c, :describe)

    assert {resource, version, job, object, digest} ==
             {c.document.resource_id, c.document.resource_version_id, c.job, c.source.object_id,
              c.source.digest}

    assert_denied(
      SafeSQL.query(
        WorkerRepo,
        "SELECT resource_version_id FROM content.document_versions LIMIT 0",
        [],
        log: false
      )
    )
  end

  test "four functions have exact security properties and only worker execution", _c do
    for signature <- @signatures do
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
                 ["content." <> signature]
               )

      assert %{rows: [[true, false, false, false, false]]} =
               SafeSQL.query!(
                 WorkerRepo,
                 "SELECT has_function_privilege('singularity_worker', $1, 'EXECUTE'), has_function_privilege('singularity_web',$1,'EXECUTE'),has_function_privilege('singularity_dispatcher',$1,'EXECUTE'),has_function_privilege('singularity_pre_auth',$1,'EXECUTE'),EXISTS(SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a WHERE p.oid=to_regprocedure($1) AND a.grantee=0 AND a.privilege_type='EXECUTE')",
                 ["content." <> signature]
               )
    end

    for table <- ~w(document_versions document_fragments),
        privilege <- ~w(SELECT INSERT UPDATE DELETE) do
      assert %{rows: [[false]]} =
               SafeSQL.query!(
                 WorkerRepo,
                 "SELECT has_table_privilege('singularity_worker',$1,$2)",
                 [
                   "content." <> table,
                   privilege
                 ]
               )
    end

    for signature <- [
          "claim_document_extraction(uuid,bigint,uuid,text,integer)",
          "complete_document_extraction(uuid,uuid,bigint,jsonb,bytea,text)",
          "fail_document_extraction(uuid,uuid,bigint,text,text)",
          "lock_document_terminal_extraction(uuid,uuid,bigint)",
          "document_worker_target(#{@base},boolean)"
        ] do
      assert %{rows: [[false]]} =
               SafeSQL.query!(
                 WorkerRepo,
                 "SELECT has_function_privilege('singularity_worker',$1,'EXECUTE')",
                 ["content." <> signature]
               )
    end
  end

  test "legacy Asset resource table privileges remain unchanged", _c do
    # These legacy Asset resource tables already have runtime grants. The bridge
    # must preserve, not revoke or widen, those established ACLs.
    for table <- ~w(resources resource_versions), privilege <- ~w(SELECT INSERT UPDATE DELETE) do
      assert %{rows: [[true]]} =
               SafeSQL.query!(
                 WorkerRepo,
                 "SELECT has_table_privilege('singularity_worker',$1,$2)",
                 ["content." <> table, privilege]
               )
    end
  end

  test "claim and same-job resume preserve the original attempt deadline after tombstone", c do
    assert {:ok,
            %{
              columns: @claim_columns,
              rows: [[resource, version, job, 1, "extracting", "plain", 1, started, deadline]]
            }} = call(c, :claim, ["plain", 1])

    assert {resource, version, job} ==
             {c.document.resource_id, c.document.resource_version_id, c.job}

    tombstone(c)

    assert {:ok,
            %{
              columns: @claim_columns,
              rows: [
                [^resource, ^version, ^job, 1, "extracting", "plain", 1, ^started, ^deadline]
              ]
            }} = call(c, :claim, ["plain", 1])

    assert {:ok,
            %{
              rows: [
                [
                  "source",
                  ^resource,
                  ^version,
                  ^job,
                  "extracting",
                  1,
                  _,
                  _,
                  _,
                  _,
                  _,
                  "plain",
                  1,
                  ^started,
                  ^deadline
                ]
              ]
            }} = call(c, :describe)

    assert_conflict(call(c, :claim, ["different", 1]))
  end

  test "deletion between source read and initial claim prevents mutation", c do
    assert {:ok, _} = call(c, :describe)
    tombstone(c)
    assert_conflict(call(c, :claim, ["plain", 1]))
    assert_conflict(call(c, :describe))
    assert state(c) == ["pending", 0, nil]
  end

  test "claimed tombstone failure returns a bounded terminal receipt with no source columns", c do
    assert {:ok, _} = call(c, :claim, ["plain", 1])
    tombstone(c)

    assert {:ok, %{columns: @receipt_columns, rows: [[resource, version, job, 1, "failed"]]}} =
             call(c, :fail, [1, "plain", 1, "text/plain", "failed", "extractor_failed"])

    assert {:ok,
            %{
              columns: @describe_columns,
              rows: [
                [
                  "terminal",
                  ^resource,
                  ^version,
                  ^job,
                  "failed",
                  1,
                  nil,
                  nil,
                  nil,
                  nil,
                  nil,
                  nil,
                  nil,
                  nil,
                  nil
                ]
              ]
            }} = call(c, :describe)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.domain_key_versions SET state='retired' WHERE vault_id=$1",
        [c.source.vault_id]
      )
    end)

    assert {:ok,
            %{
              rows: [
                [
                  "terminal",
                  ^resource,
                  ^version,
                  ^job,
                  "failed",
                  1,
                  nil,
                  nil,
                  nil,
                  nil,
                  nil,
                  nil,
                  nil,
                  nil,
                  nil
                ]
              ]
            }} = call(c, :describe)

    assert no_fragments(c)
  end

  test "ready completion and exact replay survive deletion while conflicting replay is atomic",
       c do
    assert {:ok, _} = call(c, :claim, ["plain", 1])
    tombstone(c)
    completion = completion(c)

    assert {:ok, %{columns: @receipt_columns, rows: [[_, _, _, 1, "ready"]]}} =
             call(c, :complete, completion)

    assert {:ok, %{rows: [[_, _, _, 1, "ready"]]}} = call(c, :complete, completion)
    assert_conflict(call(c, :complete, List.replace_at(completion, 6, "fr")))
    assert state(c) == ["ready", 1, c.job]

    assert Fixtures.with_owner(fn ->
             query!(
               MigrationRepo,
               "SELECT count(*) FROM content.document_fragments WHERE resource_version_id=$1",
               [c.document.resource_version_id]
             ).rows
           end) == [[1]]
  end

  test "malformed fragments and mismatched outcome metadata cannot persist partial output", c do
    assert {:ok, _} = call(c, :claim, ["plain", 1])
    assert_invalid(call(c, :complete, List.replace_at(completion(c), 4, [])))
    assert_conflict(call(c, :complete, List.replace_at(completion(c), 1, "different")))

    assert_conflict(
      call(c, :fail, [1, "plain", 1, "application/pdf", "failed", "extractor_failed"])
    )

    assert state(c) == ["extracting", 1, c.job]
    assert no_fragments(c)
  end

  test "source Asset deletion and locked custody do not remove metadata authority", c do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.resource_assets SET released_at=CURRENT_TIMESTAMP WHERE asset_id=$1",
        [c.source.asset_id]
      )

      query!(
        MigrationRepo,
        "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
        [c.source.resource_id]
      )

      query!(MigrationRepo, "UPDATE core.vaults SET locked=true WHERE id=$1", [c.source.vault_id])

      query!(
        MigrationRepo,
        "UPDATE core.outbox_events SET delivered_at=CURRENT_TIMESTAMP,runner_job_id='12345' WHERE id=$1",
        [c.job]
      )
    end)

    assert {:ok, _} = call(c, :describe)
    assert {:ok, _} = call(c, :claim, ["plain", 1])
  end

  test "worker cannot call raw lifecycle or private target helper", c do
    for {statement, arguments} <- [
          {"SELECT content.claim_document_extraction($1,0,$2,'plain',1)",
           [c.document.resource_version_id, c.job]},
          {"SELECT content.complete_document_extraction($1,$2,1,'[]'::jsonb,$3,NULL)",
           [c.document.resource_version_id, c.job, c.source.digest]},
          {"SELECT content.fail_document_extraction($1,$2,1,'failed','extractor_failed')",
           [c.document.resource_version_id, c.job]},
          {"SELECT content.document_worker_target($1,$2,$3,$4,$5,$6,false)", c.args}
        ] do
      assert_denied(SafeSQL.query(WorkerRepo, statement, arguments))
    end

    assert state(c) == ["pending", 0, nil]
  end

  test "missing and malformed scope cannot disclose a source", c do
    for {principal, owner} <- [
          {"", ""},
          {"malformed", c.scope.vault_id},
          {c.scope.principal_id, "malformed"}
        ] do
      assert_denied(manual_call(c, principal, owner, "READ COMMITTED"))
    end
  end

  test "stronger transaction isolation is rejected before any claim", c do
    for isolation <- ["REPEATABLE READ", "SERIALIZABLE"],
        {operation, extra} <- [
          describe: [],
          claim: ["plain", 1],
          complete: completion(c),
          fail: [1, "plain", 1, "text/plain", "failed", "extractor_failed"]
        ] do
      assert_invalid(
        manual_call(c, c.scope.principal_id, c.scope.vault_id, isolation, operation, extra)
      )
    end

    assert state(c) == ["pending", 0, nil]
  end

  test "cross-target, stale revision and epochs, missing event, and overflow are rejected", c do
    for {index, value} <- [
          {0, KnowledgeFixtures.uuid()},
          {1, KnowledgeFixtures.uuid()},
          {2, KnowledgeFixtures.uuid()},
          {3, 1},
          {3, 9_223_372_036_854_775_807},
          {4, -1},
          {5, -1},
          {4, Enum.at(c.args, 4) + 1},
          {5, Enum.at(c.args, 5) + 1}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: code}}} =
               call(%{c | args: List.replace_at(c.args, index, value)}, :describe)

      assert code in [:insufficient_privilege, :check_violation]
    end

    assert state(c) == ["pending", 0, nil]
  end

  test "extra retained-event payload keys and noncanonical idempotency key are denied", c do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.outbox_events SET payload=payload || '{\"extra\":true}'::jsonb WHERE id=$1",
        [c.job]
      )
    end)

    assert_denied(call(c, :describe))

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.outbox_events SET payload=payload-'extra',idempotency_key='forged-worker-event' WHERE id=$1",
        [c.job]
      )
    end)

    assert_denied(call(c, :describe))
  end

  test "revoked capability immediately denies metadata and outcomes", c do
    assert {:ok, _} = call(c, :claim, ["plain", 1])

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
        [c.source.principal_id, c.source.vault_id]
      )
    end)

    assert_denied(call(c, :describe))
    assert_denied(call(c, :fail, [1, "plain", 1, "text/plain", "failed", "extractor_failed"]))
    assert state(c) == ["extracting", 1, c.job]
  end

  for {label, statement, source_key} <- [
        {"revoked principal",
         "UPDATE identity.principals SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1",
         :principal_id},
        {"revoked membership",
         "UPDATE core.vault_members SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1",
         :principal_id},
        {"inactive account", "UPDATE identity.accounts SET status='disabled' WHERE id=$1",
         :account_id}
      ] do
    test "#{label} cannot describe or mutate an extracting attempt", c do
      assert {:ok, _} = call(c, :claim, ["plain", 1])

      Fixtures.with_owner(fn ->
        query!(MigrationRepo, unquote(statement), [Map.fetch!(c.source, unquote(source_key))])
      end)

      assert_denied(call(c, :describe))
      assert_denied(call(c, :claim, ["plain", 1]))
      assert_denied(call(c, :complete, completion(c)))
      assert_denied(call(c, :fail, [1, "plain", 1, "text/plain", "failed", "extractor_failed"]))
      assert state(c) == ["extracting", 1, c.job]
      assert no_fragments(c)
    end
  end

  test "each retained event field is independently bound", c do
    for {field, forged, original} <- [
          {"event_type", "asset.verify_requested", "document.extraction_requested"},
          {"required_capability", "asset.write", "asset.read"},
          {"classification", "sensitive", "private"},
          {"envelope_version", 2, 1},
          {"expected_entity_revision", 1, 0},
          {"principal_authorization_epoch", Enum.at(c.args, 4) + 1, Enum.at(c.args, 4)},
          {"vault_authorization_epoch", Enum.at(c.args, 5) + 1, Enum.at(c.args, 5)}
        ] do
      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "UPDATE core.outbox_events SET #{field}=$2 WHERE id=$1", [
          c.job,
          forged
        ])
      end)

      assert_denied(call(c, :describe))
      assert_denied(call(c, :claim, ["plain", 1]))

      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "UPDATE core.outbox_events SET #{field}=$2 WHERE id=$1", [
          c.job,
          original
        ])
      end)
    end

    assert {:ok, _} = call(c, :describe)
    assert state(c) == ["pending", 0, nil]
  end

  test "every valid clearance authorizes private metadata", c do
    for clearance <- ["private", "sensitive", "restricted"] do
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE core.vault_members SET clearance=$3 WHERE principal_id=$1 AND vault_id=$2",
          [c.source.principal_id, c.source.vault_id, clearance]
        )
      end)

      assert {:ok, _} = call(c, :describe)
    end
  end

  test "live cross-owner and event-matching alternate creator identities are denied", c do
    %{one: outsider} = Fixtures.two_vaults!()

    principal_epoch =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO core.vault_members (principal_id,vault_id) VALUES ($1,$2)",
          [outsider.principal_id, c.source.vault_id]
        )

        for owner <- [c.source.vault_id, outsider.vault_id] do
          assert %{num_rows: 1} =
                   query!(
                     MigrationRepo,
                     "INSERT INTO core.principal_capabilities (principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
                     [outsider.principal_id, owner]
                   )
        end

        %{rows: [[epoch]]} =
          query!(
            MigrationRepo,
            "SELECT authorization_epoch FROM identity.principals WHERE id=$1",
            [outsider.principal_id]
          )

        epoch
      end)

    outsider_scope = %{
      principal_id: Ecto.UUID.load!(outsider.principal_id),
      vault_id: Ecto.UUID.load!(outsider.vault_id)
    }

    outsider_call = %{
      c
      | scope: outsider_scope,
        args: List.replace_at(c.args, 4, principal_epoch)
    }

    assert {:ok, %{rows: [["owner", true]]}} =
             WorkerRepo.checkout(fn ->
               ScopedRepo.transact(WorkerRepo, outsider_scope, fn repo ->
                 SafeSQL.query(
                   repo,
                   "SELECT principal_kind,'asset.read'=ANY(capabilities) FROM core.live_principal_authorization()"
                 )
               end)
             end)

    assert_denied(call(outsider_call, :describe))

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.outbox_events SET principal_id=$2,principal_authorization_epoch=$3 WHERE id=$1",
        [c.job, outsider.principal_id, principal_epoch]
      )
    end)

    alternate = %{outsider_call | scope: %{outsider_scope | vault_id: c.scope.vault_id}}

    assert {:ok, %{rows: [["owner", true]]}} =
             WorkerRepo.checkout(fn ->
               ScopedRepo.transact(WorkerRepo, alternate.scope, fn repo ->
                 SafeSQL.query(
                   repo,
                   "SELECT principal_kind,'asset.read'=ANY(capabilities) FROM core.live_principal_authorization()"
                 )
               end)
             end)

    assert_denied(call(alternate, :describe))
    assert_denied(call(alternate, :claim, ["plain", 1]))
    assert state(c) == ["pending", 0, nil]
  end

  test "object/source size mismatch cannot return a descriptor", c do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.asset_objects SET plaintext_byte_size=13 WHERE id=$1",
        [c.source.object_id]
      )
    end)

    assert_conflict(call(c, :describe))
    assert state(c) == ["pending", 0, nil]
  end

  test "source descriptor rejects unavailable object and inactive binding without reading Asset liveness",
       c do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.domain_key_versions SET state='retired' WHERE vault_id=$1",
        [c.source.vault_id]
      )
    end)

    assert_conflict(call(c, :describe))

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.domain_key_versions SET state='active' WHERE vault_id=$1",
        [c.source.vault_id]
      )
    end)

    assert {:ok, _} = call(c, :describe)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE content.asset_objects SET lifecycle='pending_delete' WHERE id=$1",
        [c.source.object_id]
      )
    end)

    assert_conflict(call(c, :describe))
    assert state(c) == ["pending", 0, nil]
  end

  test "expired attempt cannot describe, resume, complete or fail", c do
    assert {:ok, _} = call(c, :claim, ["plain", 1])
    expire(c)
    assert_conflict(call(c, :describe))
    assert_conflict(call(c, :claim, ["plain", 1]))
    assert_conflict(call(c, :complete, completion(c)))
    assert_conflict(call(c, :fail, [1, "plain", 1, "text/plain", "failed", "extractor_failed"]))
    assert state(c) == ["extracting", 1, c.job]
    assert no_fragments(c)
  end

  test "authorization is refreshed after waiting for concurrent revocation", c do
    parent = self()
    reference = make_ref()

    revoker =
      Task.async(fn ->
        Fixtures.with_owner(fn ->
          query!(MigrationRepo, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
            "singularity:authorization:#{c.scope.principal_id}:#{c.scope.vault_id}"
          ])

          query!(
            MigrationRepo,
            "UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
            [c.source.principal_id, c.source.vault_id]
          )

          send(parent, {reference, :revocation_locked})

          receive do
            {^reference, :commit} -> :ok
          after
            5_000 -> raise "revocation test barrier timed out"
          end
        end)
      end)

    try do
      assert_receive {^reference, :revocation_locked}, 5_000

      reader =
        Task.async(fn ->
          WorkerRepo.checkout(fn ->
            ScopedRepo.transact(WorkerRepo, c.scope, fn repo ->
              %{rows: [[backend]]} = SafeSQL.query!(repo, "SELECT pg_backend_pid()")
              send(parent, {reference, :reader, backend})
              sql_call(repo, c.args, :describe, [])
            end)
          end)
        end)

      try do
        assert_receive {^reference, :reader, backend}, 5_000
        assert await_lock_wait(backend, System.monotonic_time(:millisecond) + 4_000)
        send(revoker.pid, {reference, :commit})
        assert :ok = Task.await(revoker, 5_000)
        assert_denied(Task.await(reader, 5_000))
      after
        Task.shutdown(reader, :brutal_kill)
      end
    after
      send(revoker.pid, {reference, :commit})
      Task.shutdown(revoker, :brutal_kill)
    end

    assert state(c) == ["pending", 0, nil]
  end

  test "ambiguous active key generations cannot return source metadata", c do
    Fixtures.with_owner(fn ->
      second_version = KnowledgeFixtures.uuid()

      query!(
        MigrationRepo,
        "INSERT INTO core.domain_key_versions (id,vault_id,key_domain_id,vault_key_version_id,generation,state,algorithm,wrapped_key) SELECT $1,vault_id,key_domain_id,vault_key_version_id,2,'active',algorithm,wrapped_key FROM core.domain_key_versions WHERE vault_id=$2",
        [second_version, c.source.vault_id]
      )

      query!(
        MigrationRepo,
        "INSERT INTO content.asset_key_envelopes (id,vault_id,asset_object_id,domain_key_version_id,key_domain_id,classification,algorithm,key_generation,wrapped_dek) SELECT $1,vault_id,asset_object_id,$2,key_domain_id,classification,algorithm,2,wrapped_dek FROM content.asset_key_envelopes WHERE asset_object_id=$3",
        [KnowledgeFixtures.uuid(), second_version, c.source.object_id]
      )
    end)

    assert_conflict(call(c, :describe))
    assert state(c) == ["pending", 0, nil]
  end

  for transition <- [:recovery, :retry, :restore] do
    test "stale deliveries cannot affect the successor after #{transition}", c do
      assert {:ok, _} = call(c, :claim, ["plain", 1])

      transition(c, unquote(transition))

      successor =
        Fixtures.with_owner(fn ->
          %{rows: [[job]]} =
            query!(
              MigrationRepo,
              "SELECT id FROM core.outbox_events WHERE vault_id=$1 AND payload->>'resource_version_id'=$2 AND expected_entity_revision=2",
              [c.source.vault_id, Ecto.UUID.load!(c.document.resource_version_id)]
            )

          %{c | job: job, args: c.args |> List.replace_at(2, job) |> List.replace_at(3, 2)}
        end)

      assert state(c) == ["pending", 2, nil]
      assert_conflict(call(c, :describe))
      assert_conflict(call(c, :claim, ["plain", 1]))

      assert {:ok, %{rows: [[_, _, _, 3, "extracting", _, _, _, _]]}} =
               call(successor, :claim, ["plain", 1])

      assert_conflict(call(c, :complete, completion(c)))
      assert_conflict(call(c, :fail, [1, "plain", 1, "text/plain", "failed", "extractor_failed"]))
      assert state(c) == ["extracting", 3, successor.job]
      assert no_fragments(c)
    end
  end

  test "SQL fragment validation rejects malformed or unbounded output atomically", c do
    assert {:ok, _} = call(c, :claim, ["plain", 1])
    valid = completion(c)
    [fragment] = Enum.at(valid, 4)

    for fragments <- [
          [],
          [Map.put(fragment, "id", "forged")],
          [Map.put(fragment, "ordinal", 1)],
          [Map.put(fragment, "digest", String.duplicate("00", 32))],
          [Map.put(fragment, "locator", %{"version" => 1, "kind" => "pdf", "page" => 1})],
          [Map.put(fragment, "text", "")],
          [Map.put(fragment, "text", String.duplicate("x", 65_537))],
          [fragment, fragment],
          List.duplicate(fragment, 4_097)
        ] do
      assert_invalid(call(c, :complete, List.replace_at(valid, 4, fragments)))
      assert state(c) == ["extracting", 1, c.job]
      assert no_fragments(c)
    end
  end

  test "aggregate output larger than 16 MiB is rejected even with individually valid fragments",
       c do
    assert {:ok, _} = call(c, :claim, ["plain", 1])
    text = String.duplicate("x", 65_536)

    fragments =
      Enum.map(0..256, fn ordinal ->
        {:ok, fragment} =
          Singularity.Core.DocumentFragment.new(%{
            resource_id: Ecto.UUID.load!(c.document.resource_id),
            resource_version_id: Ecto.UUID.load!(c.document.resource_version_id),
            owner_scope_id: c.scope.vault_id,
            classification: :private,
            ordinal: ordinal,
            text: text,
            locator: %{
              "version" => 1,
              "kind" => "text",
              "start_line" => ordinal + 1,
              "end_line" => ordinal + 1
            }
          })

        fragment_map(fragment)
      end)

    completion = [
      1,
      "plain",
      1,
      "text/plain",
      fragments,
      :crypto.hash(:sha256, List.duplicate(text, 257)),
      "en"
    ]

    assert_invalid(call(c, :complete, completion))
    assert state(c) == ["extracting", 1, c.job]
    assert no_fragments(c)
    [first | _] = fragments

    assert {:ok, %{rows: [[_, _, _, 1, "ready"]]}} =
             call(c, :complete, [
               1,
               "plain",
               1,
               "text/plain",
               [first],
               :crypto.hash(:sha256, text),
               "en"
             ])
  end

  test "worker SQL errors expose no content or parameters through logs, telemetry, or mapped errors",
       c do
    reference = make_ref()
    handler = {__MODULE__, reference}
    query_event = WorkerRepo.config()[:telemetry_prefix] ++ [:query]
    denial_event = [:singularity, :authorization, :rls_denial]

    :ok =
      :telemetry.attach_many(
        handler,
        [query_event, denial_event],
        &__MODULE__.handle_private_event/4,
        {self(), reference}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    logs =
      capture_log(fn ->
        assert {:ok, _} = call(c, :claim, ["plain", 1])

        {:error, invalid} =
          call(c, :fail, [1, "plain", 1, "text/plain", "failed", "private-tool-output-canary"])

        assert %Singularity.Core.Error{code: :invalid} = KnowledgeError.from(invalid)

        {:error, denied} =
          call(
            %{c | args: List.replace_at(c.args, 2, KnowledgeFixtures.uuid())},
            :complete,
            completion(c)
          )

        assert %Singularity.Core.Error{code: :forbidden} = KnowledgeError.from(denied)

        for error <- [KnowledgeError.from(invalid), KnowledgeError.from(denied)] do
          refute inspect(error) =~ "worker bridge canary"
          refute inspect(error) =~ "private-tool-output-canary"
          refute inspect(error) =~ "parameters"
        end
      end)

    refute logs =~ "worker bridge canary"
    refute logs =~ "private-tool-output-canary"
    assert_receive {^reference, ^denial_event, %{count: 1}, %{repo: :worker}}
    refute_receive {^reference, ^query_event, _, _}
    assert state(c) == ["extracting", 1, c.job]
    assert no_fragments(c)
  end

  for initial <- [:running, :waiting_for_unlock] do
    test "Document progress creates generic v1 #{initial} without changing wake generations", c do
      envelope = progress_envelope(c)

      WorkerScope.run(envelope, fn context ->
        assert {:ok, :saved} =
                 put_progress_state(context, envelope, unquote(initial))

        assert_scope_absent()
      end)

      assert [row] = progress_rows(c)
      assert row["state"] == Atom.to_string(unquote(initial))
      assert row["checkpoint_version"] == 1
      assert row["processing_revision"] == 0
      assert row["checkpoint"] == "{}"
      assert row["classification"] == "private"
      assert row["vault_id"] == c.source.vault_id
      assert row["submission_id"] == c.job
      assert wake_generations(c) == [0, 0]
      assert state(c) == ["pending", 0, nil]
    end
  end

  for initial <- [:pending, :running, :waiting_for_unlock],
      next <- [:running, :waiting_for_unlock] do
    test "Document progress preserves every v4 field from #{initial} to #{next}", c do
      envelope = progress_envelope(c)
      seed_progress(c, unquote(initial))
      assert [before] = progress_rows(c)

      assert {:ok, :saved} =
               WorkerScope.run(envelope, fn context ->
                 put_progress_state(context, envelope, unquote(next))
               end)

      assert [after_row] = progress_rows(c)
      assert Map.drop(after_row, ~w(state updated_at)) == Map.drop(before, ~w(state updated_at))
      assert after_row["state"] == Atom.to_string(unquote(next))
      assert DateTime.compare(after_row["updated_at"], before["updated_at"]) == :gt
      assert wake_generations(c) == [0, 0]
    end
  end

  for terminal <- [:completed, :failed], next <- [:running, :waiting_for_unlock] do
    test "Document progress rejects reopening #{terminal} as #{next}", c do
      envelope = progress_envelope(c)
      seed_progress(c, unquote(terminal))
      before = progress_rows(c)

      assert {:error, %Error{code: :conflict, message: nil, details: %{}}} =
               WorkerScope.run(envelope, fn context ->
                 put_progress_state(context, envelope, unquote(next))
               end)

      assert progress_rows(c) == before
      assert wake_generations(c) == [0, 0]
    end
  end

  test "Document progress rejects malformed states, envelopes and transaction boundaries", c do
    envelope = progress_envelope(c)

    assert {:error, %Error{code: :invalid}} =
             put_progress_state(%{}, envelope, :running)

    WorkerScope.run(envelope, fn context ->
      for state <- [:pending, :completed, :failed, :waiting_for_backup_key, "running", nil, %{}] do
        assert {:error, %Error{code: :invalid}} =
                 put_progress_state(context, envelope, state)
      end

      for invalid <- [
            nil,
            Map.from_struct(envelope),
            %{envelope | job_type: "asset_metadata"},
            %{envelope | classification: :sensitive},
            %{
              envelope
              | payload: Map.put(envelope.payload, "checkpoint", "private-progress-canary")
            },
            %{envelope | job_id: "bad-uuid"},
            %{envelope | expected_entity_revision: -1}
          ] do
        assert {:error, %Error{code: :invalid}} =
                 put_progress_state(context, invalid, :running)
      end

      for invalid <- [
            Map.delete(context, :transact),
            %{context | repo_handle: RequestRepo},
            %{context | transact: nil},
            %{context | transact: fn _, phase -> phase.(WorkerRepo) end},
            %{context | transact: fn _, phase -> phase.(RequestRepo) end},
            %{
              context
              | transact: fn _, phase -> WorkerRepo.transaction(fn -> phase.(WorkerRepo) end) end
            }
          ] do
        assert {:error, %Error{}} =
                 put_progress_state(invalid, envelope, :running)
      end

      assert {:error, %Error{code: :invalid}} =
               context.transact.([], fn _repo ->
                 put_progress_state(context, envelope, :running)
               end)

      assert_scope_absent()
    end)

    assert progress_rows(c) == []
  end

  for binding <- [
        :missing_submission,
        :submission_type,
        :submission_classification,
        :submission_outbox,
        :submission_idempotency,
        :progress_classification,
        :progress_owner
      ] do
    test "Document progress rejects #{binding} binding before changing existing data", c do
      envelope = progress_envelope(c)
      seed_progress(c, :running)

      Fixtures.with_owner(fn ->
        case unquote(binding) do
          :missing_submission ->
            query!(MigrationRepo, "DELETE FROM jobs.job_progress WHERE submission_id=$1", [c.job])
            query!(MigrationRepo, "DELETE FROM jobs.job_submissions WHERE id=$1", [c.job])

          :submission_type ->
            query!(
              MigrationRepo,
              "UPDATE jobs.job_submissions SET job_type='asset_metadata' WHERE id=$1",
              [c.job]
            )

          :submission_classification ->
            query!(
              MigrationRepo,
              "UPDATE jobs.job_submissions SET classification='sensitive' WHERE id=$1",
              [c.job]
            )

          :submission_idempotency ->
            query!(
              MigrationRepo,
              "UPDATE jobs.job_submissions SET idempotency_key='wrong-key' WHERE id=$1",
              [c.job]
            )

          :submission_outbox ->
            other = KnowledgeFixtures.uuid()

            query!(
              MigrationRepo,
              "INSERT INTO core.outbox_events (id,event_type,idempotency_key,vault_id,principal_id,required_capability,principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at) SELECT $2,event_type,idempotency_key||':other',vault_id,principal_id,required_capability,principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at FROM core.outbox_events WHERE id=$1",
              [c.job, other]
            )

            query!(
              MigrationRepo,
              "UPDATE jobs.job_submissions SET outbox_event_id=$2 WHERE id=$1",
              [c.job, other]
            )

          :progress_classification ->
            query!(
              MigrationRepo,
              "UPDATE jobs.job_progress SET classification='sensitive' WHERE submission_id=$1",
              [c.job]
            )

          :progress_owner ->
            # RLS must hide the row under a different authenticated owner.
            :ok
        end
      end)

      before = progress_rows(c)

      supplied =
        if unquote(binding) == :progress_owner,
          do: %{envelope | vault_id: Ecto.UUID.generate()},
          else: envelope

      assert {:error, %Error{}} =
               WorkerScope.run(supplied, fn context ->
                 put_progress_state(
                   context,
                   supplied,
                   :waiting_for_unlock
                 )
               end)

      assert progress_rows(c) == before
    end
  end

  test "Document progress revalidates retained event identity and current authority", c do
    envelope = progress_envelope(c)
    seed_progress(c, :running)
    before = progress_rows(c)

    WorkerScope.run(envelope, fn context ->
      for invalid <- [
            %{envelope | job_id: Ecto.UUID.generate()},
            %{envelope | principal_id: Ecto.UUID.generate()},
            %{envelope | expected_entity_revision: 1},
            %{
              envelope
              | principal_authorization_epoch: envelope.principal_authorization_epoch + 1
            },
            %{envelope | vault_authorization_epoch: envelope.vault_authorization_epoch + 1},
            %{
              envelope
              | payload: Map.put(envelope.payload, "resource_version_id", Ecto.UUID.generate())
            }
          ] do
        assert {:error, %Error{}} =
                 put_progress_state(
                   context,
                   invalid,
                   :waiting_for_unlock
                 )
      end
    end)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
        [c.source.principal_id, c.source.vault_id]
      )
    end)

    assert {:error, %Error{code: :forbidden}} =
             WorkerScope.run(envelope, fn context ->
               put_progress_state(context, envelope, :waiting_for_unlock)
             end)

    assert progress_rows(c) == before
  end

  test "Document progress waiting state integrates with the unchanged WakeHandshake while locked",
       c do
    envelope = progress_envelope(c)
    seed_progress(c, :running)
    assert [before] = progress_rows(c)
    assert {:ok, encoded} = EnvelopeCodec.encode(envelope)

    runner =
      Fixtures.with_owner(fn ->
        %{rows: [[runner]]} =
          query!(
            MigrationRepo,
            "INSERT INTO jobs.oban_jobs (state,queue,worker,args,meta,scheduled_at) VALUES ('scheduled','document_extract','Singularity.Storage.Jobs.GenericWorker',$1::jsonb,$2::jsonb,CURRENT_TIMESTAMP) RETURNING id",
            [encoded, %{"legacy_wake_canary" => 99}]
          )

        query!(MigrationRepo, "UPDATE jobs.job_submissions SET runner_job_id=$2 WHERE id=$1", [
          c.job,
          Integer.to_string(runner)
        ])

        query!(MigrationRepo, "UPDATE core.vaults SET locked=true WHERE id=$1", [
          c.source.vault_id
        ])

        runner
      end)

    WorkerScope.run(envelope, fn context ->
      assert {:ok, :saved} =
               put_progress_state(context, envelope, :waiting_for_unlock)

      assert wake_generations(c) == [0, 0]

      assert {:ok, %{generation: 1, state: "scheduled"}} =
               context.transact.([], &WakeHandshake.request(&1, "jobs", envelope, runner))

      assert wake_generations(c) == [1, 0]

      assert :pending =
               context.transact.([], &WakeHandshake.consume(&1, "jobs", envelope, runner))

      assert wake_generations(c) == [1, 1]

      assert {:ok, :saved} =
               put_progress_state(context, envelope, :running)

      assert :skipped =
               context.transact.([], &WakeHandshake.request(&1, "jobs", envelope, runner))

      assert_scope_absent()
    end)

    assert wake_generations(c) == [1, 1]
    assert [after_row] = progress_rows(c)
    assert Map.drop(after_row, ~w(state updated_at)) == Map.drop(before, ~w(state updated_at))

    assert Fixtures.with_owner(fn ->
             query!(MigrationRepo, "SELECT meta FROM jobs.oban_jobs WHERE id=$1", [runner]).rows
           end) == [[%{"legacy_wake_canary" => 99}]]
  end

  test "Document progress concurrent creation serializes and retains the first generic checkpoint",
       c do
    assert Code.ensure_loaded?(DocumentWorkerRepository)
    assert function_exported?(DocumentWorkerRepository, :put_progress_state, 3)
    envelope = progress_envelope(c)
    parent = self()
    reference = make_ref()
    blocker = progress_blocker(c, reference, :submission)

    try do
      assert_receive {^reference, :locked}, 5_000

      tasks =
        for state <- [:running, :waiting_for_unlock],
            do: progress_task(envelope, state, parent, reference)

      try do
        for _ <- tasks do
          assert_receive {^reference, :backend, backend}, 5_000
          assert await_progress_lock_wait(backend, System.monotonic_time(:millisecond) + 4_000)
        end

        send(blocker.pid, {reference, :commit})
        assert :ok = Task.await(blocker, 5_000)
        for task <- tasks, do: assert({:ok, :saved} = Task.await(task, 5_000))
      after
        for task <- tasks, do: Task.shutdown(task, :brutal_kill)
      end
    after
      send(blocker.pid, {reference, :commit})
      Task.shutdown(blocker, :brutal_kill)
    end

    assert [row] = progress_rows(c)
    assert row["state"] in ["running", "waiting_for_unlock"]

    assert {row["checkpoint_version"], row["processing_revision"], row["checkpoint"]} ==
             {1, 0, "{}"}

    assert wake_generations(c) == [0, 0]
  end

  test "Document progress reloads a terminal checkpoint committed while waiting for its row lock",
       c do
    assert Code.ensure_loaded?(DocumentWorkerRepository)
    assert function_exported?(DocumentWorkerRepository, :put_progress_state, 3)
    envelope = progress_envelope(c)
    seed_progress(c, :running)
    parent = self()
    reference = make_ref()
    blocker = progress_blocker(c, reference, :terminal)

    try do
      assert_receive {^reference, :locked}, 5_000
      task = progress_task(envelope, :waiting_for_unlock, parent, reference)

      try do
        assert_receive {^reference, :backend, backend}, 5_000
        assert await_progress_lock_wait(backend, System.monotonic_time(:millisecond) + 4_000)
        send(blocker.pid, {reference, :commit})
        assert :ok = Task.await(blocker, 5_000)
        assert {:error, %Error{code: :conflict}} = Task.await(task, 5_000)
      after
        Task.shutdown(task, :brutal_kill)
      end
    after
      send(blocker.pid, {reference, :commit})
      Task.shutdown(blocker, :brutal_kill)
    end

    assert [row] = progress_rows(c)
    assert row["state"] == "completed"
    assert {row["checkpoint_version"], row["processing_revision"]} == {4, 37}
    assert wake_generations(c) == [0, 0]
  end

  test "Document progress refreshes authority after concurrent revocation commits", c do
    assert Code.ensure_loaded?(DocumentWorkerRepository)
    assert function_exported?(DocumentWorkerRepository, :put_progress_state, 3)
    envelope = progress_envelope(c)
    seed_progress(c, :running)
    before = progress_rows(c)
    parent = self()
    reference = make_ref()
    blocker = progress_blocker(c, reference, :authority)

    try do
      assert_receive {^reference, :locked}, 5_000
      assert_receive {^reference, :authority_blocker, blocker_backend}, 5_000
      task = progress_task(envelope, :waiting_for_unlock, parent, reference)

      try do
        assert {:ok, backend} =
                 await_progress_blocked_backend(
                   blocker_backend,
                   System.monotonic_time(:millisecond) + 4_000
                 )

        assert await_progress_lock_wait(backend, System.monotonic_time(:millisecond) + 4_000)
        send(blocker.pid, {reference, :commit})
        assert :ok = Task.await(blocker, 5_000)
        assert_receive {^reference, :backend, ^backend}, 5_000
        assert {:error, %Error{code: :forbidden}} = Task.await(task, 5_000)
      after
        Task.shutdown(task, :brutal_kill)
      end
    after
      send(blocker.pid, {reference, :commit})
      Task.shutdown(blocker, :brutal_kill)
    end

    assert progress_rows(c) == before
    assert wake_generations(c) == [0, 0]
  end

  test "Document progress sanitizes failed persistence and emits no private SQL events", c do
    envelope = progress_envelope(c)
    seed_progress(c, :running)
    before = progress_rows(c)
    reference = make_ref()
    handler = {__MODULE__, reference}
    query_event = WorkerRepo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler,
        query_event,
        &__MODULE__.handle_private_event/4,
        {self(), reference}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    logs =
      capture_log(fn ->
        WorkerScope.run(envelope, fn context ->
          assert {:ok, :saved} =
                   put_progress_state(
                     context,
                     envelope,
                     :waiting_for_unlock
                   )

          assert {:ok, :saved} =
                   put_progress_state(context, envelope, :running)

          failed = %{
            context
            | transact: fn options, phase ->
                context.transact.(options, fn repo ->
                  assert {:ok, :saved} = phase.(repo)
                  raise "private-progress-canary"
                end)
              end
          }

          assert {:error,
                  %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} =
                   put_progress_state(
                     failed,
                     envelope,
                     :waiting_for_unlock
                   )

          assert_scope_absent()
        end)
      end)

    assert [after_row] = progress_rows(c)
    assert [before_row] = before
    assert Map.delete(after_row, "updated_at") == Map.delete(before_row, "updated_at")
    refute logs =~ "private-progress-canary"
    refute logs =~ "document_source_v1"
    refute_receive {^reference, ^query_event, _, _}
    assert wake_generations(c) == [0, 0]
  end

  def handle_private_event(event, measurements, metadata, {pid, reference}) do
    if self() == pid, do: send(pid, {reference, event, measurements, metadata})
  end

  defp progress_envelope(c) do
    envelope = worker_envelope(c)

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO jobs.job_submissions (id,vault_id,outbox_event_id,classification,idempotency_key,job_type) VALUES ($1,$2,$1,'private',$3,'document_extract')",
        [c.job, c.source.vault_id, envelope.idempotency_key]
      )
    end)

    envelope
  end

  defp seed_progress(c, state) do
    envelope = worker_envelope(c)

    checkpoint = %{
      "version" => 4,
      "protocol" => "document_source_v1",
      "next_chunk_index" => 1,
      "job_id" => envelope.job_id,
      "resource_version_id" => envelope.payload["resource_version_id"],
      "vault_id" => envelope.vault_id,
      "principal_id" => envelope.principal_id,
      "required_capability" => envelope.required_capability,
      "principal_authorization_epoch" => envelope.principal_authorization_epoch,
      "vault_authorization_epoch" => envelope.vault_authorization_epoch,
      "object_id" => Ecto.UUID.load!(c.source.object_id),
      "object_generation" => 1
    }

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO jobs.job_progress (id,vault_id,submission_id,classification,state,processing_revision,checkpoint_version,checkpoint,inserted_at,updated_at) VALUES ($1,$2,$3,'private',$4,37,4,$5::jsonb,CURRENT_TIMESTAMP-INTERVAL '1 day',CURRENT_TIMESTAMP-INTERVAL '1 day')",
        [KnowledgeFixtures.uuid(), c.source.vault_id, c.job, Atom.to_string(state), checkpoint]
      )
    end)
  end

  defp progress_rows(c) do
    Fixtures.with_owner(fn ->
      result =
        query!(
          MigrationRepo,
          "SELECT id,vault_id,submission_id,classification,state,processing_revision,checkpoint_version,checkpoint::text AS checkpoint,inserted_at,updated_at FROM jobs.job_progress WHERE submission_id=$1",
          [c.job]
        )

      Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
    end)
  end

  defp wake_generations(c) do
    Fixtures.with_owner(fn ->
      %{rows: [row]} =
        query!(
          MigrationRepo,
          "SELECT wake_requested_generation,wake_consumed_generation FROM jobs.job_submissions WHERE id=$1",
          [c.job]
        )

      row
    end)
  end

  defp progress_task(envelope, state, parent, reference) do
    Task.async(fn ->
      WorkerScope.run(envelope, fn context ->
        %{rows: [[backend]]} = SafeSQL.query!(WorkerRepo, "SELECT pg_backend_pid()")
        send(parent, {reference, :backend, backend})
        put_progress_state(context, envelope, state)
      end)
    end)
  end

  defp progress_blocker(c, reference, mode) do
    parent = self()

    Task.async(fn ->
      Fixtures.with_owner(fn ->
        case mode do
          :submission ->
            query!(MigrationRepo, "SELECT id FROM jobs.job_submissions WHERE id=$1 FOR UPDATE", [
              c.job
            ])

          :terminal ->
            query!(
              MigrationRepo,
              "UPDATE jobs.job_progress SET state='completed' WHERE submission_id=$1",
              [c.job]
            )

          :authority ->
            query!(MigrationRepo, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
              "singularity:authorization:#{c.scope.principal_id}:#{c.scope.vault_id}"
            ])

            query!(
              MigrationRepo,
              "UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
              [c.source.principal_id, c.source.vault_id]
            )

            %{rows: [[backend]]} = query!(MigrationRepo, "SELECT pg_backend_pid()")
            send(parent, {reference, :authority_blocker, backend})
        end

        send(parent, {reference, :locked})

        receive do
          {^reference, :commit} -> :ok
        after
          5_000 -> raise "progress test barrier timed out"
        end
      end)
    end)
  end

  defp await_progress_blocked_backend(blocker_backend, deadline) do
    %{rows: rows} =
      SafeSQL.query!(
        MigrationRepo,
        """
        SELECT a.pid
        FROM pg_catalog.pg_stat_activity AS a
        WHERE a.usename = 'singularity_worker'
          AND a.datname = current_database()
          AND $1::integer = ANY(pg_catalog.pg_blocking_pids(a.pid))
        """,
        [blocker_backend]
      )

    case rows do
      [[backend]] ->
        {:ok, backend}

      [] ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(10, remaining))
          await_progress_blocked_backend(blocker_backend, deadline)
        else
          :timeout
        end

      _ ->
        flunk("authority blocker has more than one matching worker waiter")
    end
  end

  defp await_progress_lock_wait(backend, deadline) do
    %{rows: [[waiting]]} =
      SafeSQL.query!(
        MigrationRepo,
        "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND NOT granted)",
        [backend]
      )

    cond do
      waiting ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        await_progress_lock_wait(backend, deadline)
    end
  end

  defp put_progress_state(context, envelope, state),
    do: apply(DocumentWorkerRepository, :put_progress_state, [context, envelope, state])

  defp worker_envelope(c) do
    Fixtures.with_owner(fn ->
      %{
        rows: [
          [
            job,
            key,
            owner,
            principal,
            principal_epoch,
            owner_epoch,
            correlation,
            revision,
            version,
            payload
          ]
        ]
      } =
        query!(
          MigrationRepo,
          "SELECT id,idempotency_key,vault_id,principal_id,principal_authorization_epoch,vault_authorization_epoch,correlation_id,expected_entity_revision,envelope_version,payload FROM core.outbox_events WHERE id=$1",
          [c.job]
        )

      {:ok, envelope} =
        JobEnvelope.new(%{
          version: version,
          job_id: Ecto.UUID.load!(job),
          job_type: "document_extract",
          idempotency_key: key,
          vault_id: Ecto.UUID.load!(owner),
          principal_id: Ecto.UUID.load!(principal),
          required_capability: "asset.read",
          principal_authorization_epoch: principal_epoch,
          vault_authorization_epoch: owner_epoch,
          classification: :private,
          correlation_id: Ecto.UUID.load!(correlation),
          causation_id: Ecto.UUID.load!(job),
          expected_entity_revision: revision,
          attempt: 37,
          payload: payload
        })

      envelope
    end)
  end

  defp worker_completion(c, attempt, outcome) do
    [_, _, _, _, [fragment], digest, language] = completion(c)

    {:ok, value} =
      DocumentCompletion.new(%{
        resource_id: Ecto.UUID.load!(c.document.resource_id),
        resource_version_id: Ecto.UUID.load!(c.document.resource_version_id),
        owner_scope_id: c.scope.vault_id,
        classification: :private,
        generation: attempt.generation,
        outcome: outcome,
        adapter_name: attempt.adapter_name,
        format_version: attempt.format_version,
        finished_at: DateTime.utc_now(),
        media_type: "text/plain",
        fragments:
          if(outcome == :ready,
            do: [
              %{
                resource_id: Ecto.UUID.load!(c.document.resource_id),
                resource_version_id: Ecto.UUID.load!(c.document.resource_version_id),
                owner_scope_id: c.scope.vault_id,
                classification: :private,
                ordinal: fragment["ordinal"],
                text: fragment["text"],
                locator: fragment["locator"]
              }
            ]
          ),
        extracted_text_digest: if(outcome == :ready, do: digest),
        detected_language: if(outcome == :ready, do: language),
        failure_code: if(outcome != :ready, do: "extractor_failed")
      })

    value
  end

  defp assert_scope_absent do
    assert %{rows: [[principal, owner]]} =
             SafeSQL.query!(
               WorkerRepo,
               "SELECT current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)"
             )

    assert principal in [nil, ""]
    assert owner in [nil, ""]
  end

  defp transition(c, :recovery) do
    expire(c)

    assert %{rows: [[true]]} =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 "SELECT content.recover_expired_document_with_event($1,$2)",
                 [c.document.resource_version_id, c.source.vault_id]
               )
             end)
  end

  defp transition(c, operation) when operation in [:retry, :restore] do
    assert {:ok, _} = call(c, :fail, [1, "plain", 1, "text/plain", "failed", "extractor_failed"])
    if operation == :restore, do: tombstone(c)

    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "UPDATE core.vaults SET locked=false WHERE id=$1", [c.source.vault_id])

      query!(
        MigrationRepo,
        "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
        [c.scope.principal_id, c.scope.vault_id]
      )

      query!(MigrationRepo, "SELECT content.#{operation}_document_runtime($1,'plain',1)", [
        c.document.resource_id
      ])
    end)
  end

  defp call(c, operation, extra \\ []) do
    WorkerRepo.checkout(fn ->
      ScopedRepo.transact(WorkerRepo, c.scope, fn repo ->
        sql_call(repo, c.args, operation, extra)
      end)
    end)
  end

  defp sql_call(repo, args, operation, extra) do
    parameters = args ++ extra
    placeholders = Enum.map_join(1..length(parameters), ",", &"$#{&1}")

    SafeSQL.query(
      repo,
      "SELECT * FROM content.#{operation}_document_worker(#{placeholders})",
      parameters,
      log: false
    )
  end

  defp manual_call(c, principal, owner, isolation, operation \\ :describe, extra \\ []) do
    WorkerRepo.checkout(fn ->
      case WorkerRepo.transaction(fn ->
             SafeSQL.query!(WorkerRepo, "SET TRANSACTION ISOLATION LEVEL " <> isolation)

             SafeSQL.query!(
               WorkerRepo,
               "SELECT set_config('singularity.principal_id',$1,true),set_config('singularity.vault_id',$2,true)",
               [principal, owner]
             )

             case sql_call(WorkerRepo, c.args, operation, extra) do
               {:error, error} -> WorkerRepo.rollback(error)
               success -> success
             end
           end) do
        {:ok, result} -> result
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp expire(c) do
    Fixtures.with_owner(fn ->
      query!(MigrationRepo, "SET CONSTRAINTS ALL IMMEDIATE", [])

      query!(
        MigrationRepo,
        "ALTER TABLE content.document_versions DISABLE TRIGGER document_versions_lifecycle_guard",
        []
      )

      query!(
        MigrationRepo,
        "WITH expired AS (SELECT clock_timestamp()-interval '181 seconds' AS started) UPDATE content.document_versions SET attempt_started_at=expired.started,attempt_deadline_at=expired.started+interval '180 seconds' FROM expired WHERE resource_version_id=$1",
        [c.document.resource_version_id]
      )

      query!(
        MigrationRepo,
        "ALTER TABLE content.document_versions ENABLE TRIGGER document_versions_lifecycle_guard",
        []
      )
    end)
  end

  defp await_lock_wait(backend, deadline) do
    %{rows: [[waiting]]} =
      SafeSQL.query!(
        MigrationRepo,
        "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND locktype='advisory' AND NOT granted)",
        [backend]
      )

    cond do
      waiting ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        await_lock_wait(backend, deadline)
    end
  end

  defp completion(c) do
    {:ok, fragment} =
      Singularity.Core.DocumentFragment.new(%{
        resource_id: Ecto.UUID.load!(c.document.resource_id),
        resource_version_id: Ecto.UUID.load!(c.document.resource_version_id),
        owner_scope_id: c.scope.vault_id,
        classification: :private,
        ordinal: 0,
        text: "worker bridge canary",
        locator: %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
      })

    [
      1,
      "plain",
      1,
      "text/plain",
      [fragment_map(fragment)],
      fragment.digest,
      "en"
    ]
  end

  defp fragment_map(fragment),
    do: %{
      "id" => fragment.fragment_id,
      "ordinal" => fragment.ordinal,
      "text" => fragment.text,
      "digest" => Base.encode16(fragment.digest, case: :lower),
      "locator" => SourceLocator.to_map(fragment.locator)
    }

  defp tombstone(c),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "UPDATE content.resources SET deleted_at=CURRENT_TIMESTAMP WHERE id=$1",
          [c.document.resource_id]
        )
      end)

  defp state(c),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "SELECT state,attempt_generation,attempt_job_id FROM content.document_versions WHERE resource_version_id=$1",
          [c.document.resource_version_id]
        ).rows
        |> hd()
      end)

  defp no_fragments(c),
    do:
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          """
          SELECT NOT EXISTS(SELECT 1 FROM content.document_fragments WHERE resource_version_id=$1),
            NOT EXISTS(SELECT 1 FROM content.asset_search_documents WHERE resource_version_id=$1),
            NOT EXISTS(SELECT 1 FROM content.note_search_documents WHERE resource_version_id=$1),
            EXISTS(SELECT 1 FROM content.asset_search_documents WHERE resource_version_id=$2)
          """,
          [c.document.resource_version_id, c.source.resource_version_id]
        ).rows == [[true, true, true, true]]
      end)

  defp assert_denied(result),
    do: assert({:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} = result)

  defp assert_conflict(result),
    do:
      assert(
        {:error, %Postgrex.Error{postgres: %{constraint: "document_extraction_conflict_check"}}} =
          result
      )

  defp assert_invalid(result),
    do: assert({:error, %Postgrex.Error{postgres: %{code: :check_violation}}} = result)
end
