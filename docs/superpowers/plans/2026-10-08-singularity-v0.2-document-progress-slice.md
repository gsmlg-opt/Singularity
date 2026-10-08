# Document Checkpoint-Preserving Progress Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist Document waiting/running state under actual WorkerRepo privileges while preserving all existing checkpoint fields and using the unchanged unlock wake handshake.

**Architecture:** Add only `DocumentWorkerRepository.put_progress_state/3`. Validate the closed Document envelope and the trusted short WorkerScope transaction, require the transaction scope to match the envelope, lock and validate the exact submission, and reuse the existing describe SQL to verify retained-event identity, current authority and lifecycle. Insert the generic v1 shape only when absent; lock/reload the progress row and update only state and updated_at. Return a bounded saved receipt, never checkpoint data.

**Tech Stack:** Elixir, Postgrex/Ecto, PostgreSQL 17, ExUnit and devenv.

---

## Scope and decisions

Worktree: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`.
Branch: `codex/v0.2-phase-2-import-extraction`.
Clean starting HEAD: `5f2b4cfba610069ffaaec3aaddb068cf2a650340`.

Owned files:

- Modify `apps/singularity_storage/lib/singularity/storage/postgres/document_worker_repository.ex`: the one new method and its private helpers, after parent review and GO.
- Modify `apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs`: additive real WorkerScope/WorkerRepo contracts and fixture helpers. Preserve all 47 original tests and assertions.
- Create this plan at `docs/superpowers/plans/2026-10-08-singularity-v0.2-document-progress-slice.md`.

The parent owns existing documentation and `docs/verification/2026-10-08-document-progress.md`; preserve those changes. Governing specification: `docs/superpowers/specs/2026-10-08-singularity-v0.2-document-source-replay-design.md`, Progress and unlock wake, plus its required contract 6.

Success is `{:ok, :saved}`; failure is `{:error, %Singularity.Core.Error{}}` with sanitized message/details. Completed/failed progress returns typed `:conflict`, not unchanged, because the caller must not mistake rejection for saved waiting/running state. The parent approved these result shapes.

Accept requested state only as `:running | :waiting_for_unlock`. Existing progress may be pending, running or waiting_for_unlock; other states conflict. Canonical terminal Document descriptions also conflict rather than recording a misleading running/waiting state. No checkpoint validity interpretation or v4 reset is needed: SQL never assigns checkpoint_version, processing_revision or checkpoint on an existing row.

Lock order is submission then progress, compatible with existing WakeHandshake's Oban job, submission, progress order. The existing WorkerScope session authorization lock spans the short transaction. The reused describe SQL also checks current authorization under its established shared transaction lock. It does not require an unlocked owner, allowing waiting state to be recorded before future Runtime snoozes.

The absence path inserts version 1, revision 0 and empty JSON with ON CONFLICT DO NOTHING. Both paths then reload FOR UPDATE and validate exact submission, owner and private classification before the state-only update. A concurrent old-lease checkpoint CAS therefore retains its own JSON update; a terminal update committed during lock wait is reloaded and rejected.

No new SQL function, migration, grants, public repository behaviour, generic Progress/GenericWorker/WakeHandshake changes, Runtime composition, custody/key/lease/Vault/Asset changes, E2E, commits, pushes or release actions. Later Runtime composition records waiting before `{:snooze, 60}` and running on resume; this storage slice does not implement those calls.

## Task 1: Characterization and additive RED contracts

- [x] Inspect the worktree, branch, baseline and existing diff; starting assigned scope was clean.
- [x] Read repository instructions, approved source-replay design, Elixir/Ecto/Oban skills, TDD and its testing anti-patterns reference, and writing-plans instructions.
- [x] Run the 47-test baseline using the exact focused command below. Seed `52380`, exit 0, 47 tests / 0 failures; isolated database `singularity_test_d87ca1aa7bd303985121ea36`.
- [x] Add the exact test patch in Appendix A. It covers two absent-state insertions, all six pending/running/waiting v4 transitions, four terminal reopening rejections, malformed state/envelope/context checks, seven submission/progress binding failures, retained-event and live-authority forgery/revocation, locked-owner WakeHandshake integration, concurrent creation, terminal-row lock reload, concurrent authorization revocation, and privacy plus rollback after a persistence exception.
- [x] Confirm a realistic complete `document_source_v1` checkpoint with consumed index 1 for the 12-byte source, processing revision 37, and full binding is retained. Compare the complete database row except state/updated_at, including JSON's PostgreSQL text representation, id and inserted_at.
- [x] Correct only the new RED harness after its initial linked Task failure; preserve all original assertions.
- [x] Record final 73-test RED evidence after the added concurrent-authority test: seed 219266, exit 2, 73 tests / 26 expected feature-absence failures, with all original 47 passing. Of the 26 new failures, 23 raise UndefinedFunctionError for put_progress_state/3 and three fail the missing-export preflight before owned race tasks start. No already_started cascade or missing-method compiler warning occurs. Isolated database: `singularity_test_80aaa3024c632dd170ef06ad`; storage root: `/tmp/singularity/integration/80aaa3024c632dd170ef06ad`.

Focused integration command:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs --seed 219266
```

Historical preparation evidence, retained transparently:

1. Initial expanded run: seed 219266, exit 2, 72 tests / 72 failures, isolated database `singularity_test_efbb48c1aed23a6d02ec00ab`. A linked race task raised the missing-method exception before cleanup, leaving the fixture-owned repo registered; later original tests cascaded with `{:error, {:already_started, pid}}`. This is invalid feature RED evidence, not an accepted baseline regression or a production repair.
2. Preflight guard diagnostic: same seed plus `--max-failures 1`, exit 2, 1 test / 1 expected missing-export failure, isolated database `singularity_test_6c68853470829e24a64070c9`.
3. Corrected full expanded run: seed 219266, exit 2, 72 tests / 25 expected new-method absence failures; all original 47 pass, isolated database `singularity_test_d8eb54ef6e2a9db2b5a424e1`.
4. The final 26-new-contract suite adds explicit concurrent authority revocation and uses a private test helper calling `apply/3` to avoid expected missing-function compiler warnings. Race tests check the method exists before spawning owned barrier tasks. Their substantive race assertions remain in place and each task has bounded barriers and cleanup.

All Mix commands run serially against the shared build with the shared deps path. The services are borrowed and remain running; no installation or service restart is permitted. `unbuffer` is unavailable, so the parent-directed devenv invocation is used. The integration runner allocates and drops its own database/storage root. Verify both are absent with read-only checks after final RED/GREEN.

Read-only psql and exact-path filesystem checks confirmed all five preparation databases and storage roots are absent after their commands exited. Production module diff remains empty at this review checkpoint. All owned commands have finished; the shared Mix slot is released to the parent.

## Task 2: Parent review checkpoint

- [x] Parent reads this entire plan, Appendices A and B, and the approved specification before production edits.
- [x] Parent issues GO after personal full plan/code review and database timestamp default verification. GO received before the production patch was applied.

No production code has been changed when this plan is first handed off. The full implementation patch below is executable after GO and contains no omitted helpers.

## Task 3: Apply bounded production patch

- [x] Confirm baseline/ownership again and preserve parent-owned documents. HEAD and branch still match the recorded baseline; the production module had no existing diff.
- [x] Apply Appendix B exactly with apply_patch. Production diff adds 161 lines within the assigned adapter only.
- [x] Format only the two assigned Elixir files; command exited 0:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format apps/singularity_storage/lib/singularity/storage/postgres/document_worker_repository.ex apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
```

The patch deliberately uses SafeSQL for all progress queries; no checkpoint JSON is selected into the public response, logged, copied into query parameters or rewritten. Persistence errors and raised exceptions map through KnowledgeError, and a failed callback rolls back through the existing ScopedRepo closure. A transaction result other than the exact bounded saved shape cannot claim success.

## Task 4: Focused GREEN and handoff

- [x] Run the same 73-test focused integration command with seed 219266. Actual result: exit 0, 73 tests / 0 failures, 29.5 seconds. This includes every original assertion and the unchanged actual WakeHandshake request/consume calls. Isolated database: `singularity_test_9fd4434fc03c1b76afe82daf`; storage root: `/tmp/singularity/integration/9fd4434fc03c1b76afe82daf`. The adapter compiled without warnings. No production repair was needed.
- [x] Check only assigned formatting and diff whitespace; formatting and git diff --check exited 0:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_storage/lib/singularity/storage/postgres/document_worker_repository.ex apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
git diff --check
git diff --stat
git status --short
```

- [x] Verify isolated database and root cleanup by their exact printed names. A read-only psql NOT EXISTS query returned true for the GREEN database, and the exact-path filesystem check reported storage_root absent. All owned commands finished; shared infrastructure remained running.
- [x] Report exact commands, actual seeds/counts, changed files, cleanup/shutdown evidence and remaining boundaries to the parent. Shared Mix slot released. No phase acceptance, live Runtime composition, E2E, Vault feature work or compatibility patch is claimed. Parent-owned verification document was not edited.

Initial feature RED and the corrected test-harness preparation do not count as a Sol production repair. Current cumulative Sol repair rounds: 0; received Astra repair counter: none. After two unsuccessful production repair/validation rounds stop and hand back evidence to the parent for its escalation gate. Do not expand tests or scope after this bounded suite.

## Appendix A: Complete additive test patch

Apply against the clean baseline only; the patch is already applied in the assigned test file during RED preparation. Do not apply it twice.

```diff
diff --git i/apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs w/apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
index 9b80062..c1e288b 100644
--- i/apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
+++ w/apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
@@ -4,7 +4,7 @@ defmodule Singularity.Storage.Postgres.DocumentWorkerRepositoryTest do
   import ExUnit.CaptureLog
-
+
   alias Singularity.Core.{DocumentCompletion, Error, JobEnvelope, SourceLocator}
-  alias Singularity.Storage.Jobs.WorkerScope
+  alias Singularity.Storage.Jobs.{EnvelopeCodec, WakeHandshake, WorkerScope}
   alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, SafeSQL, ScopedRepo}
   alias Singularity.Storage.Postgres.{DocumentWorkerRepository, KnowledgeError}
-
+
@@ -1415,10 +1415,634 @@ defmodule Singularity.Storage.Postgres.DocumentWorkerRepositoryTest do
     assert no_fragments(c)
   end
-
+
+  for initial <- [:running, :waiting_for_unlock] do
+    test "Document progress creates generic v1 #{initial} without changing wake generations", c do
+      envelope = progress_envelope(c)
+
+      WorkerScope.run(envelope, fn context ->
+        assert {:ok, :saved} =
+                 put_progress_state(context, envelope, unquote(initial))
+
+        assert_scope_absent()
+      end)
+
+      assert [row] = progress_rows(c)
+      assert row["state"] == Atom.to_string(unquote(initial))
+      assert row["checkpoint_version"] == 1
+      assert row["processing_revision"] == 0
+      assert row["checkpoint"] == "{}"
+      assert row["classification"] == "private"
+      assert row["vault_id"] == c.source.vault_id
+      assert row["submission_id"] == c.job
+      assert wake_generations(c) == [0, 0]
+      assert state(c) == ["pending", 0, nil]
+    end
+  end
+
+  for initial <- [:pending, :running, :waiting_for_unlock],
+      next <- [:running, :waiting_for_unlock] do
+    test "Document progress preserves every v4 field from #{initial} to #{next}", c do
+      envelope = progress_envelope(c)
+      seed_progress(c, unquote(initial))
+      assert [before] = progress_rows(c)
+
+      assert {:ok, :saved} =
+               WorkerScope.run(envelope, fn context ->
+                 put_progress_state(context, envelope, unquote(next))
+               end)
+
+      assert [after_row] = progress_rows(c)
+      assert Map.drop(after_row, ~w(state updated_at)) == Map.drop(before, ~w(state updated_at))
+      assert after_row["state"] == Atom.to_string(unquote(next))
+      assert DateTime.compare(after_row["updated_at"], before["updated_at"]) == :gt
+      assert wake_generations(c) == [0, 0]
+    end
+  end
+
+  for terminal <- [:completed, :failed], next <- [:running, :waiting_for_unlock] do
+    test "Document progress rejects reopening #{terminal} as #{next}", c do
+      envelope = progress_envelope(c)
+      seed_progress(c, unquote(terminal))
+      before = progress_rows(c)
+
+      assert {:error, %Error{code: :conflict, message: nil, details: %{}}} =
+               WorkerScope.run(envelope, fn context ->
+                 put_progress_state(context, envelope, unquote(next))
+               end)
+
+      assert progress_rows(c) == before
+      assert wake_generations(c) == [0, 0]
+    end
+  end
+
+  test "Document progress rejects malformed states, envelopes and transaction boundaries", c do
+    envelope = progress_envelope(c)
+
+    assert {:error, %Error{code: :invalid}} =
+             put_progress_state(%{}, envelope, :running)
+
+    WorkerScope.run(envelope, fn context ->
+      for state <- [:pending, :completed, :failed, :waiting_for_backup_key, "running", nil, %{}] do
+        assert {:error, %Error{code: :invalid}} =
+                 put_progress_state(context, envelope, state)
+      end
+
+      for invalid <- [
+            nil,
+            Map.from_struct(envelope),
+            %{envelope | job_type: "asset_metadata"},
+            %{envelope | classification: :sensitive},
+            %{
+              envelope
+              | payload: Map.put(envelope.payload, "checkpoint", "private-progress-canary")
+            },
+            %{envelope | job_id: "bad-uuid"},
+            %{envelope | expected_entity_revision: -1}
+          ] do
+        assert {:error, %Error{code: :invalid}} =
+                 put_progress_state(context, invalid, :running)
+      end
+
+      for invalid <- [
+            Map.delete(context, :transact),
+            %{context | repo_handle: RequestRepo},
+            %{context | transact: nil},
+            %{context | transact: fn _, phase -> phase.(WorkerRepo) end},
+            %{context | transact: fn _, phase -> phase.(RequestRepo) end},
+            %{
+              context
+              | transact: fn _, phase -> WorkerRepo.transaction(fn -> phase.(WorkerRepo) end) end
+            }
+          ] do
+        assert {:error, %Error{}} =
+                 put_progress_state(invalid, envelope, :running)
+      end
+
+      assert {:error, %Error{code: :invalid}} =
+               context.transact.([], fn _repo ->
+                 put_progress_state(context, envelope, :running)
+               end)
+
+      assert_scope_absent()
+    end)
+
+    assert progress_rows(c) == []
+  end
+
+  for binding <- [
+        :missing_submission,
+        :submission_type,
+        :submission_classification,
+        :submission_outbox,
+        :submission_idempotency,
+        :progress_classification,
+        :progress_owner
+      ] do
+    test "Document progress rejects #{binding} binding before changing existing data", c do
+      envelope = progress_envelope(c)
+      seed_progress(c, :running)
+
+      Fixtures.with_owner(fn ->
+        case unquote(binding) do
+          :missing_submission ->
+            query!(MigrationRepo, "DELETE FROM jobs.job_progress WHERE submission_id=$1", [c.job])
+            query!(MigrationRepo, "DELETE FROM jobs.job_submissions WHERE id=$1", [c.job])
+
+          :submission_type ->
+            query!(
+              MigrationRepo,
+              "UPDATE jobs.job_submissions SET job_type='asset_metadata' WHERE id=$1",
+              [c.job]
+            )
+
+          :submission_classification ->
+            query!(
+              MigrationRepo,
+              "UPDATE jobs.job_submissions SET classification='sensitive' WHERE id=$1",
+              [c.job]
+            )
+
+          :submission_idempotency ->
+            query!(
+              MigrationRepo,
+              "UPDATE jobs.job_submissions SET idempotency_key='wrong-key' WHERE id=$1",
+              [c.job]
+            )
+
+          :submission_outbox ->
+            other = KnowledgeFixtures.uuid()
+
+            query!(
+              MigrationRepo,
+              "INSERT INTO core.outbox_events (id,event_type,idempotency_key,vault_id,principal_id,required_capability,principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at) SELECT $2,event_type,idempotency_key||':other',vault_id,principal_id,required_capability,principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at FROM core.outbox_events WHERE id=$1",
+              [c.job, other]
+            )
+
+            query!(
+              MigrationRepo,
+              "UPDATE jobs.job_submissions SET outbox_event_id=$2 WHERE id=$1",
+              [c.job, other]
+            )
+
+          :progress_classification ->
+            query!(
+              MigrationRepo,
+              "UPDATE jobs.job_progress SET classification='sensitive' WHERE submission_id=$1",
+              [c.job]
+            )
+
+          :progress_owner ->
+            # RLS must hide the row under a different authenticated owner.
+            :ok
+        end
+      end)
+
+      before = progress_rows(c)
+
+      supplied =
+        if unquote(binding) == :progress_owner,
+          do: %{envelope | vault_id: Ecto.UUID.generate()},
+          else: envelope
+
+      assert {:error, %Error{}} =
+               WorkerScope.run(supplied, fn context ->
+                 put_progress_state(
+                   context,
+                   supplied,
+                   :waiting_for_unlock
+                 )
+               end)
+
+      assert progress_rows(c) == before
+    end
+  end
+
+  test "Document progress revalidates retained event identity and current authority", c do
+    envelope = progress_envelope(c)
+    seed_progress(c, :running)
+    before = progress_rows(c)
+
+    WorkerScope.run(envelope, fn context ->
+      for invalid <- [
+            %{envelope | job_id: Ecto.UUID.generate()},
+            %{envelope | principal_id: Ecto.UUID.generate()},
+            %{envelope | expected_entity_revision: 1},
+            %{
+              envelope
+              | principal_authorization_epoch: envelope.principal_authorization_epoch + 1
+            },
+            %{envelope | vault_authorization_epoch: envelope.vault_authorization_epoch + 1},
+            %{
+              envelope
+              | payload: Map.put(envelope.payload, "resource_version_id", Ecto.UUID.generate())
+            }
+          ] do
+        assert {:error, %Error{}} =
+                 put_progress_state(
+                   context,
+                   invalid,
+                   :waiting_for_unlock
+                 )
+      end
+    end)
+
+    Fixtures.with_owner(fn ->
+      query!(
+        MigrationRepo,
+        "UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
+        [c.source.principal_id, c.source.vault_id]
+      )
+    end)
+
+    assert {:error, %Error{code: :forbidden}} =
+             WorkerScope.run(envelope, fn context ->
+               put_progress_state(context, envelope, :waiting_for_unlock)
+             end)
+
+    assert progress_rows(c) == before
+  end
+
+  test "Document progress waiting state integrates with the unchanged WakeHandshake while locked",
+       c do
+    envelope = progress_envelope(c)
+    seed_progress(c, :running)
+    assert [before] = progress_rows(c)
+    assert {:ok, encoded} = EnvelopeCodec.encode(envelope)
+
+    runner =
+      Fixtures.with_owner(fn ->
+        %{rows: [[runner]]} =
+          query!(
+            MigrationRepo,
+            "INSERT INTO jobs.oban_jobs (state,queue,worker,args,meta,scheduled_at) VALUES ('scheduled','document_extract','Singularity.Storage.Jobs.GenericWorker',$1::jsonb,$2::jsonb,CURRENT_TIMESTAMP) RETURNING id",
+            [encoded, %{"legacy_wake_canary" => 99}]
+          )
+
+        query!(MigrationRepo, "UPDATE jobs.job_submissions SET runner_job_id=$2 WHERE id=$1", [
+          c.job,
+          Integer.to_string(runner)
+        ])
+
+        query!(MigrationRepo, "UPDATE core.vaults SET locked=true WHERE id=$1", [
+          c.source.vault_id
+        ])
+
+        runner
+      end)
+
+    WorkerScope.run(envelope, fn context ->
+      assert {:ok, :saved} =
+               put_progress_state(context, envelope, :waiting_for_unlock)
+
+      assert wake_generations(c) == [0, 0]
+
+      assert {:ok, %{generation: 1, state: "scheduled"}} =
+               context.transact.([], &WakeHandshake.request(&1, "jobs", envelope, runner))
+
+      assert wake_generations(c) == [1, 0]
+
+      assert :pending =
+               context.transact.([], &WakeHandshake.consume(&1, "jobs", envelope, runner))
+
+      assert wake_generations(c) == [1, 1]
+
+      assert {:ok, :saved} =
+               put_progress_state(context, envelope, :running)
+
+      assert :skipped =
+               context.transact.([], &WakeHandshake.request(&1, "jobs", envelope, runner))
+
+      assert_scope_absent()
+    end)
+
+    assert wake_generations(c) == [1, 1]
+    assert [after_row] = progress_rows(c)
+    assert Map.drop(after_row, ~w(state updated_at)) == Map.drop(before, ~w(state updated_at))
+
+    assert Fixtures.with_owner(fn ->
+             query!(MigrationRepo, "SELECT meta FROM jobs.oban_jobs WHERE id=$1", [runner]).rows
+           end) == [[%{"legacy_wake_canary" => 99}]]
+  end
+
+  test "Document progress concurrent creation serializes and retains the first generic checkpoint",
+       c do
+    assert Code.ensure_loaded?(DocumentWorkerRepository)
+    assert function_exported?(DocumentWorkerRepository, :put_progress_state, 3)
+    envelope = progress_envelope(c)
+    parent = self()
+    reference = make_ref()
+    blocker = progress_blocker(c, reference, :submission)
+
+    try do
+      assert_receive {^reference, :locked}, 5_000
+
+      tasks =
+        for state <- [:running, :waiting_for_unlock],
+            do: progress_task(envelope, state, parent, reference)
+
+      try do
+        for _ <- tasks do
+          assert_receive {^reference, :backend, backend}, 5_000
+          assert await_progress_lock_wait(backend, System.monotonic_time(:millisecond) + 4_000)
+        end
+
+        send(blocker.pid, {reference, :commit})
+        assert :ok = Task.await(blocker, 5_000)
+        for task <- tasks, do: assert({:ok, :saved} = Task.await(task, 5_000))
+      after
+        for task <- tasks, do: Task.shutdown(task, :brutal_kill)
+      end
+    after
+      send(blocker.pid, {reference, :commit})
+      Task.shutdown(blocker, :brutal_kill)
+    end
+
+    assert [row] = progress_rows(c)
+    assert row["state"] in ["running", "waiting_for_unlock"]
+
+    assert {row["checkpoint_version"], row["processing_revision"], row["checkpoint"]} ==
+             {1, 0, "{}"}
+
+    assert wake_generations(c) == [0, 0]
+  end
+
+  test "Document progress reloads a terminal checkpoint committed while waiting for its row lock",
+       c do
+    assert Code.ensure_loaded?(DocumentWorkerRepository)
+    assert function_exported?(DocumentWorkerRepository, :put_progress_state, 3)
+    envelope = progress_envelope(c)
+    seed_progress(c, :running)
+    parent = self()
+    reference = make_ref()
+    blocker = progress_blocker(c, reference, :terminal)
+
+    try do
+      assert_receive {^reference, :locked}, 5_000
+      task = progress_task(envelope, :waiting_for_unlock, parent, reference)
+
+      try do
+        assert_receive {^reference, :backend, backend}, 5_000
+        assert await_progress_lock_wait(backend, System.monotonic_time(:millisecond) + 4_000)
+        send(blocker.pid, {reference, :commit})
+        assert :ok = Task.await(blocker, 5_000)
+        assert {:error, %Error{code: :conflict}} = Task.await(task, 5_000)
+      after
+        Task.shutdown(task, :brutal_kill)
+      end
+    after
+      send(blocker.pid, {reference, :commit})
+      Task.shutdown(blocker, :brutal_kill)
+    end
+
+    assert [row] = progress_rows(c)
+    assert row["state"] == "completed"
+    assert {row["checkpoint_version"], row["processing_revision"]} == {4, 37}
+    assert wake_generations(c) == [0, 0]
+  end
+
+  test "Document progress refreshes authority after concurrent revocation commits", c do
+    assert Code.ensure_loaded?(DocumentWorkerRepository)
+    assert function_exported?(DocumentWorkerRepository, :put_progress_state, 3)
+    envelope = progress_envelope(c)
+    seed_progress(c, :running)
+    before = progress_rows(c)
+    parent = self()
+    reference = make_ref()
+    blocker = progress_blocker(c, reference, :authority)
+
+    try do
+      assert_receive {^reference, :locked}, 5_000
+      task = progress_task(envelope, :waiting_for_unlock, parent, reference)
+
+      try do
+        assert_receive {^reference, :backend, backend}, 5_000
+        assert await_progress_lock_wait(backend, System.monotonic_time(:millisecond) + 4_000)
+        send(blocker.pid, {reference, :commit})
+        assert :ok = Task.await(blocker, 5_000)
+        assert {:error, %Error{code: :forbidden}} = Task.await(task, 5_000)
+      after
+        Task.shutdown(task, :brutal_kill)
+      end
+    after
+      send(blocker.pid, {reference, :commit})
+      Task.shutdown(blocker, :brutal_kill)
+    end
+
+    assert progress_rows(c) == before
+    assert wake_generations(c) == [0, 0]
+  end
+
+  test "Document progress sanitizes failed persistence and emits no private SQL events", c do
+    envelope = progress_envelope(c)
+    seed_progress(c, :running)
+    before = progress_rows(c)
+    reference = make_ref()
+    handler = {__MODULE__, reference}
+    query_event = WorkerRepo.config()[:telemetry_prefix] ++ [:query]
+
+    :ok =
+      :telemetry.attach(
+        handler,
+        query_event,
+        &__MODULE__.handle_private_event/4,
+        {self(), reference}
+      )
+
+    on_exit(fn -> :telemetry.detach(handler) end)
+
+    logs =
+      capture_log(fn ->
+        WorkerScope.run(envelope, fn context ->
+          assert {:ok, :saved} =
+                   put_progress_state(
+                     context,
+                     envelope,
+                     :waiting_for_unlock
+                   )
+
+          assert {:ok, :saved} =
+                   put_progress_state(context, envelope, :running)
+
+          failed = %{
+            context
+            | transact: fn options, phase ->
+                context.transact.(options, fn repo ->
+                  assert {:ok, :saved} = phase.(repo)
+                  raise "private-progress-canary"
+                end)
+              end
+          }
+
+          assert {:error,
+                  %Error{code: :storage_unavailable, retryable?: true, message: nil, details: %{}}} =
+                   put_progress_state(
+                     failed,
+                     envelope,
+                     :waiting_for_unlock
+                   )
+
+          assert_scope_absent()
+        end)
+      end)
+
+    assert [after_row] = progress_rows(c)
+    assert [before_row] = before
+    assert Map.delete(after_row, "updated_at") == Map.delete(before_row, "updated_at")
+    refute logs =~ "private-progress-canary"
+    refute logs =~ "document_source_v1"
+    refute_receive {^reference, ^query_event, _, _}
+    assert wake_generations(c) == [0, 0]
+  end
+
   def handle_private_event(event, measurements, metadata, {pid, reference}) do
     if self() == pid, do: send(pid, {reference, event, measurements, metadata})
   end
-
+
+  defp progress_envelope(c) do
+    envelope = worker_envelope(c)
+
+    Fixtures.with_owner(fn ->
+      query!(
+        MigrationRepo,
+        "INSERT INTO jobs.job_submissions (id,vault_id,outbox_event_id,classification,idempotency_key,job_type) VALUES ($1,$2,$1,'private',$3,'document_extract')",
+        [c.job, c.source.vault_id, envelope.idempotency_key]
+      )
+    end)
+
+    envelope
+  end
+
+  defp seed_progress(c, state) do
+    envelope = worker_envelope(c)
+
+    checkpoint = %{
+      "version" => 4,
+      "protocol" => "document_source_v1",
+      "next_chunk_index" => 1,
+      "job_id" => envelope.job_id,
+      "resource_version_id" => envelope.payload["resource_version_id"],
+      "vault_id" => envelope.vault_id,
+      "principal_id" => envelope.principal_id,
+      "required_capability" => envelope.required_capability,
+      "principal_authorization_epoch" => envelope.principal_authorization_epoch,
+      "vault_authorization_epoch" => envelope.vault_authorization_epoch,
+      "object_id" => Ecto.UUID.load!(c.source.object_id),
+      "object_generation" => 1
+    }
+
+    Fixtures.with_owner(fn ->
+      query!(
+        MigrationRepo,
+        "INSERT INTO jobs.job_progress (id,vault_id,submission_id,classification,state,processing_revision,checkpoint_version,checkpoint,inserted_at,updated_at) VALUES ($1,$2,$3,'private',$4,37,4,$5::jsonb,CURRENT_TIMESTAMP-INTERVAL '1 day',CURRENT_TIMESTAMP-INTERVAL '1 day')",
+        [KnowledgeFixtures.uuid(), c.source.vault_id, c.job, Atom.to_string(state), checkpoint]
+      )
+    end)
+  end
+
+  defp progress_rows(c) do
+    Fixtures.with_owner(fn ->
+      result =
+        query!(
+          MigrationRepo,
+          "SELECT id,vault_id,submission_id,classification,state,processing_revision,checkpoint_version,checkpoint::text AS checkpoint,inserted_at,updated_at FROM jobs.job_progress WHERE submission_id=$1",
+          [c.job]
+        )
+
+      Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
+    end)
+  end
+
+  defp wake_generations(c) do
+    Fixtures.with_owner(fn ->
+      %{rows: [row]} =
+        query!(
+          MigrationRepo,
+          "SELECT wake_requested_generation,wake_consumed_generation FROM jobs.job_submissions WHERE id=$1",
+          [c.job]
+        )
+
+      row
+    end)
+  end
+
+  defp progress_task(envelope, state, parent, reference) do
+    Task.async(fn ->
+      WorkerRepo.checkout(fn ->
+        %{rows: [[backend]]} = SafeSQL.query!(WorkerRepo, "SELECT pg_backend_pid()")
+        send(parent, {reference, :backend, backend})
+
+        WorkerScope.run(envelope, fn context ->
+          put_progress_state(context, envelope, state)
+        end)
+      end)
+    end)
+  end
+
+  defp progress_blocker(c, reference, mode) do
+    parent = self()
+
+    Task.async(fn ->
+      Fixtures.with_owner(fn ->
+        case mode do
+          :submission ->
+            query!(MigrationRepo, "SELECT id FROM jobs.job_submissions WHERE id=$1 FOR UPDATE", [
+              c.job
+            ])
+
+          :terminal ->
+            query!(
+              MigrationRepo,
+              "UPDATE jobs.job_progress SET state='completed' WHERE submission_id=$1",
+              [c.job]
+            )
+
+          :authority ->
+            query!(MigrationRepo, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
+              "singularity:authorization:#{c.scope.principal_id}:#{c.scope.vault_id}"
+            ])
+
+            query!(
+              MigrationRepo,
+              "UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
+              [c.source.principal_id, c.source.vault_id]
+            )
+        end
+
+        send(parent, {reference, :locked})
+
+        receive do
+          {^reference, :commit} -> :ok
+        after
+          5_000 -> raise "progress test barrier timed out"
+        end
+      end)
+    end)
+  end
+
+  defp await_progress_lock_wait(backend, deadline) do
+    %{rows: [[waiting]]} =
+      SafeSQL.query!(
+        MigrationRepo,
+        "SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND NOT granted)",
+        [backend]
+      )
+
+    cond do
+      waiting ->
+        true
+
+      System.monotonic_time(:millisecond) >= deadline ->
+        false
+
+      true ->
+        Process.sleep(10)
+        await_progress_lock_wait(backend, deadline)
+    end
+  end
+
+  defp put_progress_state(context, envelope, state),
+    do: apply(DocumentWorkerRepository, :put_progress_state, [context, envelope, state])
+
   defp worker_envelope(c) do
     Fixtures.with_owner(fn ->
       %{
```

## Appendix B: Complete production patch for review and GO

```diff
*** Begin Patch
*** Update File: /home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction/apps/singularity_storage/lib/singularity/storage/postgres/document_worker_repository.ex
@@
   def describe(context, envelope), do: describe(context, envelope, :error)
-
+
+  @spec put_progress_state(map(), JobEnvelope.t(), :running | :waiting_for_unlock) ::
+          {:ok, :saved} | {:error, Error.t()}
+  def put_progress_state(context, envelope, state)
+      when state in [:running, :waiting_for_unlock] do
+    with :ok <- valid_envelope(envelope),
+         %{repo_handle: WorkerRepo, transact: transact} when is_function(transact, 2) <- context,
+         true <- WorkerRepo.checked_out?(),
+         false <- WorkerRepo.in_transaction?() do
+      case transact.([], fn repo ->
+             if repo === WorkerRepo and WorkerRepo.checked_out?() and
+                  WorkerRepo.in_transaction?() do
+               save_progress_state(repo, envelope, state)
+             else
+               invalid()
+             end
+           end) do
+        {:ok, :saved} = saved -> saved
+        {:error, error} -> {:error, KnowledgeError.from(error)}
+        _ -> invalid()
+      end
+    else
+      _ -> invalid()
+    end
+  rescue
+    error -> {:error, KnowledgeError.from(error)}
+  end
+
+  def put_progress_state(_context, _envelope, _state), do: invalid()
+
@@
-  defp parameters(envelope) do
+  defp save_progress_state(repo, envelope, state) do
+    with :ok <- validate_progress_scope(repo, envelope),
+         :ok <- lock_progress_submission(repo, envelope),
+         {:ok, described} <-
+           SafeSQL.query(
+             repo,
+             "SELECT * FROM content.describe_document_worker($1,$2,$3,$4,$5,$6)",
+             parameters(envelope),
+             log: false
+           ),
+         {:ok, {:source, _source}} <- decode_source(described, envelope),
+         {:ok, _inserted} <-
+           SafeSQL.query(
+             repo,
+             """
+             INSERT INTO jobs.job_progress
+               (id,vault_id,submission_id,classification,state,
+                processing_revision,checkpoint_version,checkpoint)
+             VALUES ($1,$2,$3,'private',$4,0,1,'{}'::jsonb)
+             ON CONFLICT (submission_id) DO NOTHING
+             """,
+             [
+               Ecto.UUID.dump!(Ecto.UUID.generate()),
+               Ecto.UUID.dump!(envelope.vault_id),
+               Ecto.UUID.dump!(envelope.job_id),
+               Atom.to_string(state)
+             ],
+             log: false
+           ),
+         :ok <- lock_progress_row(repo, envelope),
+         {:ok, %Postgrex.Result{num_rows: 1}} <-
+           SafeSQL.query(
+             repo,
+             """
+             UPDATE jobs.job_progress SET state=$4,updated_at=clock_timestamp()
+             WHERE submission_id=$1 AND vault_id=$2 AND classification=$3
+             """,
+             [
+               Ecto.UUID.dump!(envelope.job_id),
+               Ecto.UUID.dump!(envelope.vault_id),
+               "private",
+               Atom.to_string(state)
+             ],
+             log: false
+           ) do
+      {:ok, :saved}
+    else
+      {:error, error} -> {:error, KnowledgeError.from(error)}
+      _ -> {:error, Error.new(:conflict)}
+    end
+  end
+
+  defp validate_progress_scope(repo, envelope) do
+    case SafeSQL.query(
+           repo,
+           """
+           SELECT current_setting('singularity.principal_id',true),
+                  current_setting('singularity.vault_id',true)
+           """,
+           [],
+           log: false
+         ) do
+      {:ok, %Postgrex.Result{rows: [[principal, owner]]}}
+      when principal == envelope.principal_id and owner == envelope.vault_id ->
+        :ok
+
+      {:error, error} ->
+        {:error, KnowledgeError.from(error)}
+
+      _ ->
+        {:error, Error.new(:forbidden)}
+    end
+  end
+
+  defp lock_progress_submission(repo, envelope) do
+    owner = Ecto.UUID.dump!(envelope.vault_id)
+    job = Ecto.UUID.dump!(envelope.job_id)
+
+    case SafeSQL.query(
+           repo,
+           """
+           SELECT id,vault_id,outbox_event_id,classification,idempotency_key,job_type
+           FROM jobs.job_submissions WHERE id=$1 FOR UPDATE
+           """,
+           [job],
+           log: false
+         ) do
+      {:ok,
+       %Postgrex.Result{
+         num_rows: 1,
+         rows: [[^job, ^owner, ^job, "private", key, "document_extract"]]
+       }}
+      when key == envelope.idempotency_key ->
+        :ok
+
+      {:error, error} ->
+        {:error, KnowledgeError.from(error)}
+
+      _ ->
+        {:error, Error.new(:conflict)}
+    end
+  end
+
+  defp lock_progress_row(repo, envelope) do
+    owner = Ecto.UUID.dump!(envelope.vault_id)
+    job = Ecto.UUID.dump!(envelope.job_id)
+
+    case SafeSQL.query(
+           repo,
+           """
+           SELECT submission_id,vault_id,classification,state
+           FROM jobs.job_progress WHERE submission_id=$1 FOR UPDATE
+           """,
+           [job],
+           log: false
+         ) do
+      {:ok,
+       %Postgrex.Result{
+         num_rows: 1,
+         rows: [[^job, ^owner, "private", current_state]]
+       }}
+      when current_state in ["pending", "running", "waiting_for_unlock"] ->
+        :ok
+
+      {:error, error} ->
+        {:error, KnowledgeError.from(error)}
+
+      _ ->
+        {:error, Error.new(:conflict)}
+    end
+  end
+
+  defp parameters(envelope) do
*** End Patch
```
