# Document supervised Runtime restart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Qualify automatic recovery of a genuinely expired Document attempt after replacing the actual Runtime application supervisor.

**Architecture:** One integration test claims through the real WorkerScope and DocumentWorkerRepository, stops Runtime, waits for PostgreSQL's unchanged 180-second deadline, and restarts Runtime. One SQL statement observes the complete Document row, its extraction events and current authorization epochs consistently; only the exact original snapshot may be retried before the recovered snapshot is required.

**Tech Stack:** Elixir/ExUnit, existing canonical fixtures, Ecto/Postgrex, existing isolated integration alias.

**Status:** bounded Task13 restart qualification accepted locally on final test
source `3fe960f0afb64f5253626bafbd3acda5b6a04d14c9c884c2b3dc380401f9aed9`.
All planned checks passed: isolated1, combined29, exact cleanup, formatting,
diffcheck and independent final source SPEC/QUALITY. Parent authorizes the exact
four-file local commit; Git identifies its result. See
`docs/verification/2026-10-09-document-supervised-restart-qualification.md`.
Historical execution instructions follow; Phase2/release acceptance remains open.

---

## Scope and execution prerequisites

Work only in `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`, branch `codex/v0.2-phase-2-import-extraction`, characterized at `138b035e56c2bc7416e6840a0ad2ae2aff798093`.
Read the companion design `docs/superpowers/specs/2026-10-09-singularity-v0.2-document-supervised-restart-design.md` and applicable `AGENTS.md` before execution. Parent personal review and independent Astra review of this complete plan/code precede executable-source GO. This document is preparation, not implementation or acceptance evidence.

Only create `apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs`. All helpers are private in that file. Parent owns design, verification evidence, reviews and any separately authorized local commit. Preserve the original untracked `docs/superpowers/plans/2026-10-09-singularity-v0.2-document-extraction-runtime-outcomes-integration.md` byte-for-byte. No production/configuration/dependency/migration/grant/custody/key/capability/Vault implementation changes, service operations, public APIs, E2E, pushes, releases or deployments.

This adds a missing characterization for implemented behavior. An initially green result is expected. The real expired, unchanged row with no successor while Runtime is down supplies the negative control. Do not manufacture a red test by deleting production behavior, shortening deadlines, adjusting timestamps, disabling triggers or explicitly calling recovery. A real failure stops this qualification for diagnosis; repairs require their own bounded authority.

Verified source contracts:

- `KnowledgeFixtures.source!/0` returns binary UUID fields, digest and byte size; `document!/1` creates generation-zero pending rows. The real claim path needs no `prepared_source!/0`, key envelope, source-reader double, job submission or progress row.
- `Fixtures.with_owner/1` starts MigrationRepo, runs an owner-role transaction and stops the repo. Every observation below finishes before sleeping; no checkout or transaction spans expiry waiting.
- `DocumentWorkerRepository.claim/4` accepts `WorkerScope.run/2` context and returns canonical string IDs, atom state and DateTime timestamps. The production adapter is `plain_text`, format 1.
- `EnvelopeCodec` requires private classification, asset.read, canonical UUIDs, exact two-ID payload and the generation-zero key without a revision suffix. Recovery uses revision 2, version correlation and abandoned-job causation.
- Runtime directly supervises WorkerRepo and registered ExtractionReconciler. Its startup pass precedes an unchanged 30,000 ms periodic cadence. Oban's actual named configuration normalizes disabled queues/plugins to empty lists.
- OutboxDispatcher schedules its first dispatch after the configured interval; test configuration is 3,600,000 ms. Manual Oban alone does not disable dispatch. Event snapshots nevertheless select only immutable canonical provenance fields and IDs, excluding delivery/lease metadata, so the assertions do not depend on that unrelated timer.
- The integration alias maps the generated database suffix to `Path.join([System.tmp_dir!(), "singularity", "integration", suffix])` and configures all five repositories for that database.

## Task 1: Add the literal application-restart contract

**Files:**

- Create: `apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs`

- [x] **Step 1: Reconfirm the starting tree and obtain parent executable-source GO after plan review.**

```sh
git rev-parse HEAD
git status --short
git diff --check
```

Expected source is the characterized commit above unless the parent has explicitly recorded intervening accepted work. Preserve every existing unrelated or untracked file. The original three-file gate already passed 28 integration tests; its exact command and isolated cleanup evidence are in `docs/verification/2026-10-09-document-supervised-restart-qualification.md`.

- [x] **Step 2: Create exactly this complete file with apply_patch.**

```elixir
defmodule Singularity.Runtime.DocumentExtractionRuntimeRestartTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  alias Singularity.Core.{Error, JobEnvelope}
  alias Singularity.Runtime.Documents.ExtractionReconciler
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo}
  alias Singularity.Storage.Jobs.{EnvelopeCodec, WorkerScope}
  alias Singularity.Storage.Postgres.DocumentWorkerRepository

  @runtime_names [Singularity.Runtime.Supervisor, ExtractionReconciler, WorkerRepo]
  @event_fields ~w(event_type idempotency_key vault_id principal_id required_capability principal_authorization_epoch vault_authorization_epoch classification correlation_id causation_id expected_entity_revision envelope_version payload)

  test "replacing Runtime automatically recovers an attempt that expired while it was stopped" do
    assert_isolated_environment!()
    old_processes = runtime_processes!()

    on_exit(fn ->
      assert {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
      runtime_processes!()
    end)

    source = KnowledgeFixtures.source!()
    document = KnowledgeFixtures.document!(source)
    {event, envelope} = extraction_event!(source, document)
    {pending, _observed_at} = snapshot!(document)

    assert pending.row["state"] == "pending"
    assert pending.row["attempt_generation"] == 0
    assert pending.events == [event]

    for field <- ~w(source_asset_id source_resource_id source_resource_version_id source_object_id source_digest source_byte_size media_type created_by_principal_id)a do
      assert pending.row[Atom.to_string(field)] == Map.fetch!(document, field)
    end

    assert {:ok, attempt} = claim(envelope)

    assert attempt == %{
             resource_id: Ecto.UUID.load!(document.resource_id),
             resource_version_id: Ecto.UUID.load!(document.resource_version_id),
             job_id: event["id"],
             generation: 1,
             state: :extracting,
             adapter_name: "plain_text",
             format_version: 1,
             started_at: attempt.started_at,
             deadline_at: attempt.deadline_at
           }

    assert %DateTime{} = attempt.started_at
    assert %DateTime{} = attempt.deadline_at
    assert DateTime.diff(attempt.deadline_at, attempt.started_at, :microsecond) == 180_000_000

    expected_attempt = %{
      pending
      | row:
          Map.merge(pending.row, %{
            "state" => "extracting",
            "attempt_generation" => 1,
            "attempt_job_id" => Ecto.UUID.dump!(envelope.job_id),
            "attempt_started_at" => attempt.started_at,
            "attempt_deadline_at" => attempt.deadline_at,
            "extraction_adapter" => "plain_text",
            "extraction_format" => 1
          })
    }

    {original, _observed_at} = snapshot!(document)
    assert original == expected_attempt
    monitors = Enum.map(old_processes, fn {_name, pid} -> {pid, Process.monitor(pid)} end)

    assert :ok = Application.stop(:singularity_runtime)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
      refute Process.alive?(pid)
    end

    assert_runtime_stopped!()
    {stopped, stopped_at} = snapshot!(document)
    assert stopped == original
    assert DateTime.compare(stopped_at, attempt.deadline_at) == :lt

    await_expiry!(document, original, System.monotonic_time(:millisecond) + 210_000)

    restart_started_at = System.monotonic_time(:millisecond)
    assert {:ok, started} = Application.ensure_all_started(:singularity_runtime)
    assert :singularity_runtime in started
    new_processes = runtime_processes!()

    for name <- @runtime_names do
      refute Map.fetch!(new_processes, name) == Map.fetch!(old_processes, name)
    end

    recovered =
      await_recovery!(document, original, event, restart_started_at + 10_000)

    assert {:error, %Error{code: :conflict}} = claim(envelope)
    {after_replay, _observed_at} = snapshot!(document)
    assert after_replay == recovered
    assert runtime_processes!() == new_processes
  end

  defp assert_isolated_environment! do
    assert Application.fetch_env!(:singularity_runtime, :start_infrastructure) == true
    assert %{rows: [[database]]} = query!(WorkerRepo, "SELECT current_database()")
    assert database =~ ~r/\Asingularity_test_[0-9a-f]{24}\z/
    suffix = String.replace_prefix(database, "singularity_test_", "")

    assert Application.fetch_env!(:singularity_storage, :storage_root) ==
             Path.join([System.tmp_dir!(), "singularity", "integration", suffix])

    for repo <- [MigrationRepo, RequestRepo, PreAuthRepo, DispatcherRepo, WorkerRepo] do
      assert Keyword.fetch!(repo.config(), :database) == database
    end

    assert %{rows: [[^database]]} =
             Fixtures.with_owner(fn -> query!(MigrationRepo, "SELECT current_database()") end)
  end

  defp runtime_processes! do
    processes =
      Map.new(@runtime_names, fn name ->
        pid = Process.whereis(name)
        assert is_pid(pid)
        assert Process.alive?(pid)
        {name, pid}
      end)

    children = Supervisor.which_children(Map.fetch!(processes, Singularity.Runtime.Supervisor))

    for {name, type} <- [{ExtractionReconciler, :worker}, {WorkerRepo, :supervisor}] do
      pid = Map.fetch!(processes, name)
      assert {name, pid, type, [name]} in children
    end

    assert is_pid(Oban.whereis(Singularity.Oban))

    assert %Oban.Config{
             name: Singularity.Oban,
             repo: WorkerRepo,
             testing: :manual,
             queues: [],
             plugins: []
           } = Oban.config(Singularity.Oban)

    processes
  end

  defp assert_runtime_stopped! do
    for name <- @runtime_names, do: assert(is_nil(Process.whereis(name)))
  end

  defp extraction_event!(source, document) do
    event =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.read') ON CONFLICT (name) DO NOTHING",
          [KnowledgeFixtures.uuid()]
        )

        assert %{num_rows: 1} =
                 query!(
                   MigrationRepo,
                   "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
                   [source.principal_id, source.vault_id]
                 )

        %{rows: [[principal_epoch, owner_epoch]]} =
          query!(
            MigrationRepo,
            "SELECT p.authorization_epoch,v.authorization_epoch FROM identity.principals p CROSS JOIN core.vaults v WHERE p.id=$1 AND v.id=$2",
            [source.principal_id, source.vault_id]
          )

        %{rows: [[event]]} =
          query!(
            MigrationRepo,
            """
            INSERT INTO core.outbox_events AS event
              (id,event_type,idempotency_key,vault_id,principal_id,required_capability,
               principal_authorization_epoch,vault_authorization_epoch,classification,
               correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at)
            VALUES ($1,'document.extraction_requested',$2,$3,$4,'asset.read',$5,$6,'private',
                    $7,$1,0,1,$8::jsonb,clock_timestamp())
            RETURNING to_jsonb(event)
            """,
            [
              KnowledgeFixtures.uuid(),
              "document-extraction:#{Ecto.UUID.load!(document.resource_version_id)}",
              source.vault_id,
              source.principal_id,
              principal_epoch,
              owner_epoch,
              document.resource_version_id,
              %{
                "resource_id" => Ecto.UUID.load!(document.resource_id),
                "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
              }
            ]
          )

        Map.take(event, ["id" | @event_fields])
      end)

    assert {:ok, envelope} =
             JobEnvelope.new(%{
               version: event["envelope_version"],
               job_id: event["id"],
               job_type: "document_extract",
               idempotency_key: event["idempotency_key"],
               vault_id: event["vault_id"],
               principal_id: event["principal_id"],
               required_capability: event["required_capability"],
               principal_authorization_epoch: event["principal_authorization_epoch"],
               vault_authorization_epoch: event["vault_authorization_epoch"],
               classification: :private,
               correlation_id: event["correlation_id"],
               causation_id: event["causation_id"],
               expected_entity_revision: event["expected_entity_revision"],
               attempt: 0,
               payload: event["payload"]
             })

    assert event["classification"] == "private"
    assert {:ok, encoded} = EnvelopeCodec.encode(envelope)
    assert {:ok, ^envelope} = EnvelopeCodec.decode(encoded)
    {event, envelope}
  end

  defp claim(envelope) do
    WorkerScope.run(envelope, fn context ->
      assert context.repo_handle == WorkerRepo
      assert WorkerRepo.checked_out?()
      refute WorkerRepo.in_transaction?()
      DocumentWorkerRepository.claim(context, envelope, "plain_text", 1)
    end)
  end

  defp snapshot!(document) do
    Fixtures.with_owner(fn ->
      result =
        query!(
          MigrationRepo,
          """
          SELECT d.*, clock_timestamp() AS observed_at,
            p.authorization_epoch AS current_principal_epoch,
            v.authorization_epoch AS current_owner_epoch,
            COALESCE((SELECT jsonb_agg(to_jsonb(provenance) ORDER BY provenance.id)
              FROM (SELECT #{Enum.join(["id" | @event_fields], ",")}
                FROM core.outbox_events e
                WHERE e.event_type='document.extraction_requested'
                  AND (e.payload->>'resource_version_id'=$1::uuid::text
                       OR e.idempotency_key=$2 OR e.idempotency_key LIKE $2 || ':%')) provenance),
              '[]'::jsonb) AS extraction_events
          FROM content.document_versions d
          JOIN identity.principals p ON p.id=d.created_by_principal_id
          JOIN core.vaults v ON v.id=d.vault_id
          WHERE d.resource_version_id=$1
          """,
          [
            document.resource_version_id,
            "document-extraction:#{Ecto.UUID.load!(document.resource_version_id)}"
          ]
        )

      assert [values] = result.rows
      row = Map.new(Enum.zip(result.columns, values))

      {%{
         row:
           Map.drop(row, ~w(observed_at current_principal_epoch current_owner_epoch extraction_events)),
         events: row["extraction_events"],
         epochs: {row["current_principal_epoch"], row["current_owner_epoch"]}
       }, row["observed_at"]}
    end)
  end

  defp await_expiry!(document, original, deadline) do
    assert_runtime_stopped!()
    {snapshot, observed_at} = snapshot!(document)
    assert snapshot == original
    assert System.monotonic_time(:millisecond) < deadline

    if DateTime.compare(observed_at, original.row["attempt_deadline_at"]) == :gt do
      :ok
    else
      Process.sleep(1_000)
      await_expiry!(document, original, deadline)
    end
  end

  defp await_recovery!(document, original, original_event, deadline) do
    assert System.monotonic_time(:millisecond) < deadline
    {snapshot, _observed_at} = snapshot!(document)
    assert System.monotonic_time(:millisecond) < deadline

    if snapshot == original do
      Process.sleep(20)
      await_recovery!(document, original, original_event, deadline)
    else
      expected_row =
        Map.merge(original.row, %{
          "state" => "pending",
          "attempt_generation" => 2,
          "attempt_job_id" => nil,
          "attempt_started_at" => nil,
          "attempt_deadline_at" => nil,
          "extraction_adapter" => nil,
          "extraction_format" => nil,
          "extracted_text_digest" => nil,
          "detected_language" => nil,
          "failure_code" => nil,
          "attempt_finished_at" => nil
        })

      assert snapshot.row == expected_row
      assert snapshot.epochs == original.epochs
      assert length(snapshot.events) == 2
      assert original_event in snapshot.events
      assert [successor] = Enum.reject(snapshot.events, &(&1 == original_event))
      successor_id = successor["id"]
      assert {:ok, ^successor_id} = Ecto.UUID.cast(successor_id)
      refute successor_id == original_event["id"]
      {principal_epoch, owner_epoch} = snapshot.epochs

      assert Map.take(successor, @event_fields) == %{
               "event_type" => "document.extraction_requested",
               "idempotency_key" => original_event["idempotency_key"] <> ":2",
               "vault_id" => original_event["vault_id"],
               "principal_id" => original_event["principal_id"],
               "required_capability" => "asset.read",
               "principal_authorization_epoch" => principal_epoch,
               "vault_authorization_epoch" => owner_epoch,
               "classification" => "private",
               "correlation_id" => Ecto.UUID.load!(document.resource_version_id),
               "causation_id" => original_event["id"],
               "expected_entity_revision" => 2,
               "envelope_version" => 1,
               "payload" => %{
                 "resource_id" => Ecto.UUID.load!(document.resource_id),
                 "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
               }
             }

      snapshot
    end
  end
end
```

- [x] **Step 3: Format only the new test file.**

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs
```

Expected exit 0. Formatting is the only mechanical adjustment to the code above. Retain every assertion, strict deadline and real application stop/start. Parent owns the sole Mix slot; run commands serially.

## Task 2: Execute bounded qualification and hand off evidence

**Files:**

- Test: `apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs`
- Existing gates, unchanged: `apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs`, `apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs`, `apps/singularity_runtime/test/singularity/runtime/job_restart_test.exs`
- Parent-maintained evidence: `docs/verification/2026-10-09-document-supervised-restart-qualification.md`

- [x] **Step 1: Run the new integration contract alone.**

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs --seed 1208
```

Expected: 1 integration test, 0 failures, approximately 180 seconds plus fixture/application overhead, exit 0. Capture actual counts, duration and both alias-printed database and storage-root values. The test's 300,000 ms ExUnit timeout includes the unchanged deadline wait, and restoration is registered before stopping Runtime. Assertion, startup or timeout failure must propagate. Do not suppress cleanup failures or manually reconcile to rescue a failed test.

- [x] **Step 2: Verify exact isolated cleanup for that completed command.**

Use the following complete interactive shell block and paste the exact database/root pair printed by the alias at its prompts. Validation rejects a broader or unrelated target; no deletion is performed.

```sh
devenv shell -- bash -c '
read -r -p "Exact database printed by this run: " restart_database
read -r -p "Exact storage_root printed by this run: " restart_root
[[ "$restart_database" =~ ^singularity_test_[0-9a-f]{24}$ ]] || exit 1
restart_suffix="${restart_database#singularity_test_}"
[[ "$restart_root" == */singularity/integration/"$restart_suffix" ]] || exit 1
restart_count=$(psql -X -d postgres -Atqc "SELECT count(*) FROM pg_catalog.pg_database WHERE datname='\''$restart_database'\''") || exit 1
printf "database=%s catalog_count=%s storage_root=%s\n" "$restart_database" "$restart_count" "$restart_root"
[[ "$restart_count" == 0 ]] && [[ ! -e "$restart_root" ]]
'
```

Expected count 0, root absent, exit 0. Parent may instead issue literal read-only commands using the captured exact names as in the existing evidence record. Record exact values, not a wildcard count. Do not stop or alter borrowed PostgreSQL or external services. If cleanup fails, report it and stop this gate.

- [x] **Step 3: Run the complete four-file scoped gate.**

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_runtime/test/singularity/runtime/job_restart_test.exs --seed 1208
```

Expected total 29 integration tests (19 storage, 10 Runtime), 0 failures, exit 0; record actual reported counts and any exclusions. Re-run Step 2's exact cleanup verification with this run's newly printed pair. A green default suite or test count inferred from files does not substitute for the actual gate. No broad README/Phase 2 acceptance is claimed.

- [x] **Step 4: Verify formatting and source boundary.**

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs
git diff --check
git status --short
git diff --no-index -- /dev/null apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs
```

Expected format/diffcheck exit 0. The final `git diff --no-index` exits 1 because the new file differs from `/dev/null`; inspect the complete output. Only the one test is newly executable. The original C plan remains untracked and unchanged; the parent-owned design/verification documents are not agent implementation scope.

- [x] **Step 5: Parent records evidence and obtains independent spec then quality review.**

Record tested source and new-file hash, exact commands and actual counts, each generated database/root pair and cleanup results, actual supervisor/child replacement assertions, unchanged 180-second lifetime, recovery bound from before restart, replay conflict and unchanged successor identity. State no production, migration, grants, custody/key/capability/Vault feature work, no services altered, and no broader release acceptance. Parent personally reads the test and complete review findings. Fix only authorized test defects; preserve failures requiring separately bounded production work.

- [x] **Step 6: Parent performs the separately authorized scoped local commit after acceptance.**

Stage explicit paths only after inspecting their final diff; never use blanket staging. The parent owns selection of its design/plan/evidence documents alongside the single accepted test. Do not push, tag, publish, deploy, or merge. This preparation agent creates no commit.

## Self-review and readiness

The complete code covers isolation, actual named Oban safety, prearmed restoration, real generation-zero event/codec/claim, complete source/attempt retention, three original process deaths and absences, unexpired-at-stop proof, real database-clock expiry while Runtime is down, literal application restart and new direct-child PIDs, recovery within 10 seconds from before startup, exact event contract and singleton successor, and old-envelope conflict with unchanged snapshot. Only exact unchanged original snapshots are polled; partial, duplicate or unexpected states fail immediately.

Known cost: each successful execution waits the real 180 seconds; isolated and combined gates take roughly six minutes total plus overhead. Startup slower than 10 seconds deliberately fails rather than falling through to periodic recovery. The complete code has been checked against source contracts but is unexecuted until parent review and GO; preparation readiness does not imply passing tests.
