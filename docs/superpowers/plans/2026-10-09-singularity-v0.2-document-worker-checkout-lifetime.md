# Document worker checkout lifetime repair implementation plan

> **For agentic workers:** Use executing-plans with main-owned checkpoints. No nested agents. Steps use checkbox syntax; existing failing Runtime assertions remain frozen.

**Goal:** Repair the reproduced Document checkout lifetime without widening unrelated worker or server SQL execution limits.

**Architecture:** A closed Document-only WorkerScope path owns a finite checkout and temporary session statement limit. Actual-worker-role tests select exact named-pool backends and monitor borrowers. Existing locking, authority and canonical deadlines remain unchanged.

**Tech Stack:** Elixir, Ecto SQL, Postgrex, DBConnection, PostgreSQL, isolated integration alias.

Status: **bounded repair accepted locally at `ecb170349ae3ca021e8fe0ca194d4a9b73dfa738`; all scoped gates and independent Astra spec/quality reviews green; committed source blobs match tested hashes**. Main owns this plan.
The accepted architecture is
`docs/superpowers/specs/2026-10-09-singularity-v0.2-document-worker-checkout-lifetime-design.md`
at `273322d`. Main personally reviewed all focused test code, production additions,
commands, counts and cleanup contracts. All four Elixir blocks parse and the test
block compiles warning-free in memory with 14 registered contracts (no execution).

Use writing-plans, systematic-debugging, test-driven-development,
using-elixir-skills, ecto-thinking, otp-thinking and verification-before-completion.
No nested agents. Current agent capacity prevented fresh Sol delegation after the
successful Astra architecture handoff, so main continues the preparation directly;
this is not a technical blocker or permission request.

## Frozen evidence and scope

Worktree:
`/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`.
Branch: `codex/v0.2-phase-2-import-extraction`.

The existing Runtime test file, including the two actual C2 failures, is frozen
for this repair at SHA-256
`20598c663e6ecc57c655d48d32e5e32add3e9032c1827d8124361f4b9b838515`.
Its original 2,191-line A/B prefix remains byte-identical. The C plan is preserved
at SHA-256 `350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.
Main owns C verification evidence. C3/C4/C5 remain held.

Original failing integration result: 55 executed, 43 exclusions, 2 failures; 31 B
and 22 C2 passed. Exact 64 MiB source and exact 16 MiB output fail the real 15-second
checkout. Both failed-run isolated environments were independently confirmed
absent. Failed Sol production
repairs 0, Astra production repair attempts 0, successful Astra architecture 1,
C harness correction 1. Maximum Astra repair attempts 3.

Only proposed production file: `apps/singularity_storage/lib/singularity/storage/jobs/worker_scope.ex`.
Only proposed additional test file: `apps/singularity_storage/test/singularity/storage/document_worker_scope_test.exs`.
Accepted test-only compatibility amendment also permits the existing
`apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs`
progress helper and authority observation changes in the accepted design. All
assertions remain enforced; no shared fixture change or production scope growth.
No migrations, dependencies, privileges, Vault files/semantics, custody, keys,
capabilities, Runtime extractors, GenericWorker, generic retry/wake, global config,
timeout overrides/hooks, repository injection or frozen assertion changes.
No E2E, service interruption, merge, push, release or deployment GO. A bounded
local repair commit is permitted only after Task 4's required gates and reviews.

## Preparation checkpoints

- [x] Trace reproduced failures and obtain fresh Astra architecture assessment.
- [x] Record and locally commit the accepted bounded design under standing approval.
- [x] Read the installed SafeSQL/Ecto/Postgrex simple-query dispatch source.
- [x] Complete actual-worker-role test code and finite contract ledger.
- [x] Complete and parse the minimal production patch and all test code.
- [x] Review every callback/result shape, session-setting and owned-process cleanup.
- [x] Issue separate test GO, retain focused RED, then scoped production GO.

## Actual-role test isolation (corrected after baseline)

Tests use the named WorkerRepo and actual worker PostgreSQL role, never a fake
or RequestRepo substitute. Seed exactly one backend and capture its original
setting in that checkout. Bounded identity-aware selection reborrows that exact
backend for callbacks and readback; misses execute no target assertions/mutations.
Matched errors/throws are never retried. Cleanup restores only the captured
backend or establishes its disappearance. Separate monitored observers avoid
reentrant session-lock false positives. Runners are monitored and cleanup kills
and waits for owned processes. No pool saturation, restart, config/timeout
override, dynamic repo, production injection or borrowed-service interruption.
The selection admission deadline is five seconds/256 attempts, not a guarantee
that an already-started checkout finishes in five seconds. Selection contention
fails explicitly. This component proof does not replace C2's encrypted-source
contracts. Three short-test orchestration tags become 60 seconds; actual 16-second
hold, 14–20-second SQL assertion and real 300-second expiry remain unchanged.

Required contracts remain exactly the accepted design: >15-second same-backend
callback with both locks; real SQL cap and stricter prior cap; exact restoration
on success/error/raise/throw/rollback; borrower and owned-backend death cleanup;
nested rejection before changes; unchanged non-Document behavior; one actual
300-second outer expiry with no late mutation; unchanged C2 exact-size reruns and
all required scoped regressions. Timing must use bounded, deadline-derived
receive timers and process monitors, with no arbitrary race sleeps.

## Stop checkpoint

Main issues bounded GO to create the exact focused test block and run Task 1 RED.
Production remains held until expected RED is retained. No successful repair,
C2 completion, Task 12, Phase 2 or release acceptance is claimed. Execute the
explicit RED/repair sequence without asking the user again.

Subsequent actual baseline: 14 tests, 14 failures, exit 2 in 42.3 seconds. The
private dynamic pool is not valid isolation for unchanged SafeSQL: raw
Ecto.Adapters.SQL.query!(WorkerRepo) resolves the named repo directly, while
WorkerRepo.checkout selects the dynamic repo. Setting/session/lock assertions
therefore run on different backends; this is not accepted RED for production GO.
The separate bounded Astra SOL_IMPASSE assessment supplied the named-pool
amendment. Main read its complete helper/callsite recipe, applied only that test
correction, personally reviewed the resulting code and compiled 14 contracts
without warnings. The executable block below now contains the corrected tests.
Main issues corrected focused test GO. No production patch has been applied.

Subsequent valid baseline completed 14 tests / 12 expected failures in 57.2 seconds;
stricter cap and non-Document characterization passed including cleanup. Main
retained RED, verified exact environment cleanup and issued scoped production GO.
Only Task 2 WorkerScope additions were applied (+73 lines), and only that file
and the new Storage test were formatted. Focused verification is in progress.
Test block below mirrors formatted source; no existing Runtime assertion changed.

## Task 1: Complete actual-role focused contracts

- [x] After preparation review and explicit test GO, create only
  `apps/singularity_storage/test/singularity/storage/document_worker_scope_test.exs`
  with the entire following block. The existing KnowledgeFixtures create complete
  canonical rows; no source read or live custody proof is claimed by these scope
  component tests. C2 retains that separate end-to-end source responsibility.

```elixir
defmodule Singularity.Storage.DocumentWorkerScopeTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration

  alias Singularity.Core.{Error, JobEnvelope}
  alias Singularity.Storage.{Fixtures, KnowledgeFixtures, MigrationRepo, SafeSQL}
  alias Singularity.Storage.Jobs.{EnvelopeCodec, WorkerScope}

  @settings_options [query_type: :text, timeout: 15_000]

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
    job = Ecto.UUID.generate()
    key = "document-extraction:#{Ecto.UUID.load!(document.resource_version_id)}"

    payload = %{
      "resource_id" => Ecto.UUID.load!(document.resource_id),
      "resource_version_id" => Ecto.UUID.load!(document.resource_version_id)
    }

    {principal_epoch, owner_epoch} =
      Fixtures.with_owner(fn ->
        query!(
          MigrationRepo,
          "INSERT INTO core.capabilities(id,name) VALUES($1,'asset.read') ON CONFLICT(name) DO NOTHING",
          [KnowledgeFixtures.uuid()]
        )

        query!(
          MigrationRepo,
          "INSERT INTO core.principal_capabilities(principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
          [binary_source.principal_id, binary_source.vault_id]
        )

        %{rows: [[pe, oe]]} =
          query!(
            MigrationRepo,
            "SELECT p.authorization_epoch,v.authorization_epoch FROM identity.principals p CROSS JOIN core.vaults v WHERE p.id=$1 AND v.id=$2",
            [binary_source.principal_id, binary_source.vault_id]
          )

        query!(
          MigrationRepo,
          """
          INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,required_capability,
            principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,causation_id,
            expected_entity_revision,envelope_version,payload,occurred_at)
          VALUES($1,'document.extraction_requested',$2,$3,$4,'asset.read',$5,$6,'private',$1,$1,0,1,$7,CURRENT_TIMESTAMP)
          """,
          [
            Ecto.UUID.dump!(job),
            key,
            binary_source.vault_id,
            binary_source.principal_id,
            pe,
            oe,
            payload
          ]
        )

        query!(
          MigrationRepo,
          """
          INSERT INTO jobs.job_submissions(id,vault_id,outbox_event_id,classification,idempotency_key,job_type)
          VALUES($1,$2,$1,'private',$3,'document_extract')
          """,
          [Ecto.UUID.dump!(job), binary_source.vault_id, key]
        )

        {pe, oe}
      end)

    {:ok, envelope} =
      JobEnvelope.new(%{
        version: 1,
        job_id: job,
        job_type: "document_extract",
        idempotency_key: key,
        vault_id: source.vault_id,
        principal_id: source.principal_id,
        required_capability: "asset.read",
        principal_authorization_epoch: principal_epoch,
        vault_authorization_epoch: owner_epoch,
        classification: :private,
        correlation_id: job,
        causation_id: job,
        expected_entity_revision: 0,
        attempt: 0,
        payload: payload
      })

    {:ok, encoded} = EnvelopeCodec.encode(envelope)
    {:ok, ^envelope} = EnvelopeCodec.decode(encoded)
    assert WorkerRepo.get_dynamic_repo() == WorkerRepo
    named = Process.whereis(WorkerRepo)
    config = Application.fetch_env!(:singularity_storage, WorkerRepo)
    original = fresh_snapshot()

    f = %{
      backend: original.backend,
      envelope: envelope,
      source: binary_source,
      document: document
    }

    # Registered before runner cleanup callbacks, which execute first.
    on_exit(fn ->
      restore_backend!(original)
      assert Process.whereis(WorkerRepo) == named
      assert Process.alive?(named)
      assert Application.fetch_env!(:singularity_storage, WorkerRepo) == config
    end)

    assert %{role: "singularity_worker", timeout: 0} = original
    {:ok, fixture: f}
  end

  test "fresh Document checkout caps server statements outside transactions and restores its session",
       %{fixture: f} do
    before = snapshot(f)

    assert :done =
             run(f, fn context ->
               assert context.repo_handle === WorkerRepo
               assert context.lock_mode == :shared
               assert WorkerRepo.checked_out?()
               refute WorkerRepo.in_transaction?()
               assert timeout_ms() == 15_000
               assert backend() == before.backend
               locks!(f, false)

               assert :done =
                        context.transact.([], fn repo ->
                          assert repo === WorkerRepo
                          assert WorkerRepo.in_transaction?()

                          assert [[principal, owner]] =
                                   SafeSQL.query!(
                                     repo,
                                     "SELECT current_setting('singularity.principal_id'),current_setting('singularity.vault_id')"
                                   ).rows

                          assert {principal, owner} ==
                                   {f.envelope.principal_id, f.envelope.vault_id}

                          :done
                        end)

               :done
             end)

    assert snapshot(f) == before
    locks!(f, true)
  end

  @tag timeout: 60_000
  test "real Document borrower survives 15 seconds with same backend and both shared locks", %{
    fixture: f
  } do
    parent = self()
    token = make_ref()

    runner =
      spawn_owned(f, fn ->
        run(f, fn _context ->
          initial = backend()
          assert timeout_ms() == 15_000
          started = System.monotonic_time(:millisecond)
          send(parent, {token, :entered, initial})
          wait_until(started + 16_000)
          assert backend() == initial
          assert WorkerRepo.checked_out?()
          refute WorkerRepo.in_transaction?()
          :done
        end)
      end)

    assert_receive {^token, :entered, pid}, 5_000
    locks!(f, false)
    assert :done = result!(runner, 22_000)
    assert snapshot(f).backend == pid
    assert snapshot(f).timeout == 0
    locks!(f, true)
  end

  @tag timeout: 60_000
  test "actual statement above 15 seconds is cancelled without losing the Document backend", %{
    fixture: f
  } do
    before = snapshot(f)

    assert :cancelled =
             run(f, fn _context ->
               started = System.monotonic_time(:millisecond)

               assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
                        SafeSQL.query(WorkerRepo, "SELECT pg_sleep(20)")

               elapsed = System.monotonic_time(:millisecond) - started
               assert elapsed >= 14_000 and elapsed < 20_000
               assert backend() == before.backend
               :cancelled
             end)

    assert snapshot(f) == before
    locks!(f, true)
  end

  test "stricter existing 75 ms statement cap stays effective and is restored exactly", %{
    fixture: f
  } do
    set_prior!(f, 75)
    before = snapshot(f)

    assert :cancelled =
             run(f, fn _context ->
               assert timeout_ms() == 75

               assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} =
                        SafeSQL.query(WorkerRepo, "SELECT pg_sleep(1)")

               :cancelled
             end)

    assert snapshot(f) == before
    locks!(f, true)
  end

  for mode <- [:success, :returned_failure, :raise, :throw, :rollback] do
    test "exact prior setting and request GUCs restore after #{mode}", %{fixture: f} do
      set_prior!(f, 30_000)
      before = snapshot(f)
      mode = unquote(mode)

      result =
        try do
          {:returned,
           run(f, fn context ->
             assert timeout_ms() == 15_000
             assert backend() == before.backend
             callback_outcome(mode, context, f)
           end)}
        rescue
          error in RuntimeError -> {:raised, error.message}
        catch
          :throw, reason -> {:thrown, reason}
        end

      assert_outcome(mode, result)
      assert snapshot(f) == before
      assert WorkerRepo.get_dynamic_repo() == WorkerRepo
      locks!(f, true)
    end
  end

  test "borrower death disconnects only its backend and releases locks and temporary settings", %{
    fixture: f
  } do
    parent = self()
    token = make_ref()

    runner =
      spawn_owned(f, fn ->
        run(f, fn _context ->
          assert timeout_ms() == 15_000
          send(parent, {token, :entered, backend()})

          receive do
            {^token, :continue} -> :unexpected_success
          after
            5_000 -> flunk("borrower kill barrier exceeded bound")
          end
        end)
      end)

    assert_receive {^token, :entered, pid}, 5_000
    locks!(f, false)
    Process.exit(runner.pid, :kill)
    down!(runner, :killed)
    backend_gone!(pid)
    next = fresh_snapshot()
    assert %{role: "singularity_worker", timeout: 0} = next
    refute next.backend == pid
    locks!(f, true)
  end

  test "loss of exactly the owned backend makes restoration kill its borrower rather than return success",
       %{fixture: f} do
    parent = self()
    token = make_ref()

    runner =
      spawn_owned(f, fn ->
        run(f, fn _context ->
          assert timeout_ms() == 15_000
          send(parent, {token, :entered, backend()})

          result =
            try do
              SafeSQL.query(WorkerRepo, "SELECT pg_terminate_backend(pg_backend_pid())")
            rescue
              error in DBConnection.ConnectionError -> {:error, error}
            end

          assert match?({:error, %Postgrex.Error{postgres: %{code: :admin_shutdown}}}, result) or
                   match?({:error, %DBConnection.ConnectionError{}}, result)

          send(parent, {token, :owned_connection_lost})
          :unexpected_success
        end)
      end)

    assert_receive {^token, :entered, pid}, 5_000
    assert_receive {^token, :owned_connection_lost}, 5_000
    down!(runner, :killed)
    backend_gone!(pid)
    next = fresh_snapshot()
    assert %{role: "singularity_worker", timeout: 0} = next
    refute next.backend == pid
    locks!(f, true)
  end

  test "nested Document entry is rejected before session settings locks or callback change", %{
    fixture: f
  } do
    at_backend!(f.backend, fn ->
      before = {backend(), timeout_ms()}

      assert {:error, %Error{code: :invalid, message: nil, details: %{}}} =
               WorkerScope.run(f.envelope, fn _context ->
                 flunk("nested callback must not execute")
               end)

      assert {backend(), timeout_ms()} == before
      locks!(f, true)
    end)

    assert snapshot(f).timeout == 0
  end

  @tag timeout: 60_000
  test "non-Document worker retains its existing statement setting and 15-second checkout", %{
    fixture: f
  } do
    asset = asset_envelope!(f)
    parent = self()
    token = make_ref()

    runner =
      spawn_owned(f, fn ->
        try do
          WorkerScope.run(asset, fn _context ->
            assert timeout_ms() == 0
            send(parent, {token, :entered, backend()})
            wait_until(System.monotonic_time(:millisecond) + 16_000)
            SafeSQL.query!(WorkerRepo, "SELECT 1")
            :unexpected_success
          end)
        rescue
          _error in DBConnection.ConnectionError -> :legacy_checkout_expired
        end
      end)

    assert_receive {^token, :entered, pid}, 5_000
    assert :legacy_checkout_expired = result!(runner, 22_000)
    backend_gone!(pid)
    next = fresh_snapshot()
    assert %{role: "singularity_worker", timeout: 0} = next
    refute next.backend == pid
    locks!(f, true)
  end

  @tag timeout: 360_000
  test "real fixed five-minute checkout expiry prevents late scoped mutation and releases owned backend",
       %{fixture: f} do
    parent = self()
    token = make_ref()

    runner =
      spawn_owned(f, fn ->
        run(f, fn context ->
          assert timeout_ms() == 15_000
          assert :written = bump_wake(context, f)
          started = System.monotonic_time(:millisecond)
          send(parent, {token, :entered, backend()})
          wait_until(started + 300_750)
          send(parent, {token, :late_attempt})
          bump_wake(context, f)
          :unexpected_success
        end)
      end)

    assert_receive {^token, :entered, pid}, 5_000
    assert wake_count(f) == 1
    locks!(f, false)
    assert_receive {^token, :late_attempt}, 310_000
    down!(runner, :killed)
    backend_gone!(pid)
    assert wake_count(f) == 1

    assert [["pending", 0, nil, nil]] ==
             owner_query(
               "SELECT state,attempt_generation,attempt_started_at,attempt_deadline_at FROM content.document_versions WHERE resource_version_id=$1",
               [f.document.resource_version_id]
             ).rows

    next = fresh_snapshot()
    assert %{role: "singularity_worker", timeout: 0} = next
    refute next.backend == pid
    locks!(f, true)
  end

  defp run(f, callback) do
    assert WorkerRepo.get_dynamic_repo() == WorkerRepo
    refute WorkerRepo.checked_out?()

    select_backend!(fn ->
      WorkerScope.run(f.envelope, fn context ->
        if backend() == f.backend, do: {:selected, callback.(context)}, else: :not_selected
      end)
    end)
  end

  defp asset_envelope!(f) do
    id = Ecto.UUID.generate()

    asset = %{
      f.envelope
      | job_id: id,
        job_type: "asset_metadata",
        correlation_id: id,
        causation_id: id,
        idempotency_key: "asset-metadata:#{Ecto.UUID.load!(f.source.asset_id)}:0",
        payload: %{"asset_id" => Ecto.UUID.load!(f.source.asset_id)}
    }

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.outbox_events(id,event_type,idempotency_key,vault_id,principal_id,required_capability,
          principal_authorization_epoch,vault_authorization_epoch,classification,correlation_id,causation_id,
          expected_entity_revision,envelope_version,payload,occurred_at)
        VALUES($1,'asset.metadata_requested',$2,$3,$4,'asset.read',$5,$6,'private',$1,$1,0,1,$7,CURRENT_TIMESTAMP)
        """,
        [
          Ecto.UUID.dump!(id),
          asset.idempotency_key,
          f.source.vault_id,
          f.source.principal_id,
          asset.principal_authorization_epoch,
          asset.vault_authorization_epoch,
          asset.payload
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO jobs.job_submissions(id,vault_id,outbox_event_id,classification,idempotency_key,job_type)
        VALUES($1,$2,$1,'private',$3,'asset_metadata')
        """,
        [Ecto.UUID.dump!(id), f.source.vault_id, asset.idempotency_key]
      )
    end)

    {:ok, encoded} = EnvelopeCodec.encode(asset)
    {:ok, ^asset} = EnvelopeCodec.decode(encoded)
    asset
  end

  defp callback_outcome(:success, _context, _f), do: :done

  defp callback_outcome(:returned_failure, _context, _f),
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp callback_outcome(:raise, _context, _f), do: raise("bounded checkout callback")
  defp callback_outcome(:throw, _context, _f), do: throw(:bounded_checkout_callback)

  defp callback_outcome(:rollback, context, f) do
    context.transact.([], fn repo ->
      assert WorkerRepo.in_transaction?()

      assert [[f.envelope.principal_id, f.envelope.vault_id]] ==
               SafeSQL.query!(
                 repo,
                 "SELECT current_setting('singularity.principal_id'),current_setting('singularity.vault_id')"
               ).rows

      repo.rollback(:bounded_checkout_rollback)
    end)
  end

  defp assert_outcome(:success, result), do: assert(result == {:returned, :done})

  defp assert_outcome(:returned_failure, result),
    do: assert({:returned, {:error, %Error{code: :storage_unavailable}}} = result)

  defp assert_outcome(:raise, result),
    do: assert(result == {:raised, "bounded checkout callback"})

  defp assert_outcome(:throw, result), do: assert(result == {:thrown, :bounded_checkout_callback})

  defp assert_outcome(:rollback, result),
    do: assert(result == {:returned, {:error, :bounded_checkout_rollback}})

  @selection_attempts 256
  @selection_window_ms 5_000

  defp select_backend!(attempt) do
    deadline = System.monotonic_time(:millisecond) + @selection_window_ms
    select_backend!(attempt, deadline, @selection_attempts)
  end

  defp select_backend!(_attempt, _deadline, 0),
    do: flunk("exact backend was not selected within the bounded checkout count")

  defp select_backend!(attempt, deadline, remaining) do
    assert System.monotonic_time(:millisecond) < deadline,
           "exact backend selection exceeded its admission deadline"

    case attempt.() do
      {:selected, result} -> result
      :not_selected -> select_backend!(attempt, deadline, remaining - 1)
      _unexpected -> flunk("backend selection returned an unexpected scope result")
    end
  end

  defp at_backend!(target, callback) do
    assert WorkerRepo.get_dynamic_repo() == WorkerRepo
    refute WorkerRepo.checked_out?()

    select_backend!(fn ->
      WorkerRepo.checkout(fn ->
        if backend() == target, do: {:selected, callback.()}, else: :not_selected
      end)
    end)
  end

  defp snapshot(f), do: at_backend!(f.backend, &snapshot_checked_out/0)

  defp fresh_snapshot do
    assert WorkerRepo.get_dynamic_repo() == WorkerRepo
    refute WorkerRepo.checked_out?()
    WorkerRepo.checkout(&snapshot_checked_out/0)
  end

  defp snapshot_checked_out do
    assert WorkerRepo.checked_out?()
    refute WorkerRepo.in_transaction?()

    assert [[pid, "singularity_worker", principal, owner]] =
             SafeSQL.query!(
               WorkerRepo,
               "SELECT pg_backend_pid(),current_user,current_setting('singularity.principal_id',true),current_setting('singularity.vault_id',true)"
             ).rows

    assert principal in [nil, ""] and owner in [nil, ""]
    %{backend: pid, role: "singularity_worker", timeout: timeout_ms()}
  end

  defp backend, do: SafeSQL.query!(WorkerRepo, "SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp timeout_ms do
    assert [[value]] =
             SafeSQL.query!(
               WorkerRepo,
               "SELECT setting FROM pg_catalog.pg_settings WHERE name='statement_timeout'",
               [],
               @settings_options
             ).rows

    {integer, ""} = Integer.parse(value)
    assert integer >= 0
    integer
  end

  defp set_timeout!(milliseconds) do
    assert is_integer(milliseconds) and milliseconds >= 0

    SafeSQL.query!(
      WorkerRepo,
      "SELECT set_config('statement_timeout','#{milliseconds}ms',false)",
      [],
      @settings_options
    )

    assert timeout_ms() == milliseconds
    :ok
  end

  defp set_prior!(f, milliseconds),
    do: at_backend!(f.backend, fn -> set_timeout!(milliseconds) end)

  defp restore_backend!(original) do
    assert WorkerRepo.get_dynamic_repo() == WorkerRepo
    refute WorkerRepo.checked_out?()

    if backend_present?(original.backend) do
      at_backend!(original.backend, fn ->
        set_timeout!(original.timeout)
        assert snapshot_checked_out() == original
        :restored
      end)
    else
      # Cleanup only: disappearance cannot satisfy same-backend restoration tests.
      :backend_gone
    end
  end

  defp locks!(f, expected) do
    borrower_backend = if WorkerRepo.checked_out?(), do: backend(), else: nil
    excluded_backends = [f.backend, borrower_backend]

    observe!(fn ->
      select_backend!(fn ->
        WorkerRepo.checkout(fn ->
          observer_backend = backend()

          if observer_backend in excluded_backends do
            :not_selected
          else
            assert [["singularity_worker"]] =
                     SafeSQL.query!(WorkerRepo, "SELECT current_user").rows

            for key <- [
                  "singularity:vault:" <> f.envelope.vault_id,
                  "singularity:authorization:" <>
                    f.envelope.principal_id <> ":" <> f.envelope.vault_id
                ] do
              assert [[available]] =
                       SafeSQL.query!(
                         WorkerRepo,
                         "SELECT pg_try_advisory_lock(hashtextextended($1::text,0))",
                         [key]
                       ).rows

              if available do
                assert [[true]] =
                         SafeSQL.query!(
                           WorkerRepo,
                           "SELECT pg_advisory_unlock(hashtextextended($1::text,0))",
                           [key]
                         ).rows
              end

              assert available == expected
            end

            {:selected, :ok}
          end
        end)
      end)
    end)
  end

  defp observe!(callback) do
    parent = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        assert WorkerRepo.get_dynamic_repo() == WorkerRepo
        refute WorkerRepo.checked_out?()
        result = callback.()
        send(parent, {token, :observed, result})
      end)

    try do
      receive do
        {^token, :observed, result} ->
          assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
          result

        {:DOWN, ^monitor, :process, ^pid, _reason} ->
          flunk("independent backend observer failed")
      after
        5_000 -> flunk("independent backend observer exceeded its bound")
      end
    after
      if Process.alive?(pid) do
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
      end

      Process.demonitor(monitor, [:flush])
    end
  end

  defp spawn_owned(_f, callback) do
    parent = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        assert WorkerRepo.get_dynamic_repo() == WorkerRepo
        refute WorkerRepo.checked_out?()
        result = callback.()
        send(parent, {token, :result, result})
      end)

    on_exit(fn ->
      monitor = Process.monitor(pid)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end)

    %{pid: pid, monitor: monitor, token: token}
  end

  defp result!(%{pid: pid, monitor: monitor, token: token}, timeout) do
    assert_receive {^token, :result, result}, timeout
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    result
  end

  defp down!(%{pid: pid, monitor: monitor, token: token}, reason) do
    assert_receive {:DOWN, ^monitor, :process, ^pid, ^reason}, 5_000
    refute_receive {^token, :result, _}, 0
  end

  defp backend_present?(pid) do
    observe!(fn ->
      assert [[count]] =
               SafeSQL.query!(
                 WorkerRepo,
                 "SELECT count(*) FROM pg_catalog.pg_stat_activity WHERE pid=$1",
                 [pid]
               ).rows

      assert count in [0, 1]
      count == 1
    end)
  end

  defp backend_gone!(pid), do: backend_gone(pid, System.monotonic_time(:millisecond) + 5_000)

  defp backend_gone(pid, bound) do
    if backend_present?(pid) do
      assert System.monotonic_time(:millisecond) < bound
      wait_until(min(bound, System.monotonic_time(:millisecond) + 10))
      backend_gone(pid, bound)
    end
  end

  defp wait_until(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      token = make_ref()
      interval = min(remaining, 30_000)
      timer = Process.send_after(self(), {:scope_tick, token}, interval)

      receive do
        {:scope_tick, ^token} -> :ok
      after
        interval + 1_000 ->
          Process.cancel_timer(timer)
          flunk("owned scope timer exceeded bound")
      end

      wait_until(deadline)
    end
  end

  defp bump_wake(context, f) do
    context.transact.([], fn repo ->
      assert %{num_rows: 1} =
               SafeSQL.query!(
                 repo,
                 "UPDATE jobs.job_submissions SET wake_requested_generation=wake_requested_generation+1 WHERE id=$1",
                 [Ecto.UUID.dump!(f.envelope.job_id)]
               )

      :written
    end)
  end

  defp wake_count(f) do
    [[count]] =
      owner_query(
        "SELECT wake_requested_generation FROM jobs.job_submissions WHERE id=$1",
        [Ecto.UUID.dump!(f.envelope.job_id)]
      ).rows

    count
  end

  defp owner_query(sql, params),
    do: Fixtures.with_owner(fn -> query!(MigrationRepo, sql, params) end)
end
```

- [x] Run focused RED before changing production. Expected enforced-contract
  failures are the missing Document statement cap, nested rejection and longer
  checkout. Record actual counts rather than predicting each failure. Existing
  stricter-cap/non-Document characterization may already pass.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/document_worker_scope_test.exs --seed 1208
```

## Task 2: Minimal Document-only production repair

- [x] After expected focused RED, issue scoped production GO and apply only the
  following additions to WorkerScope; its existing run body, backup clause,
  generic shared fallback and lock_mode clauses remain byte-identical.

Add aliases `Singularity.Core.Error` and `Singularity.Storage.SafeSQL` and constants:

```elixir
  @document_checkout_timeout 300_000
  @statement_timeout 15_000
  @settings_options [query_type: :text, timeout: @statement_timeout]
```

Insert before the existing generic shared fallback:

```elixir
  defp with_vault_lock(%{job_type: "document_extract"} = envelope, fun) do
    if WorkerRepo.checked_out?() do
      {:error, Error.new(:invalid)}
    else
      WorkerRepo.checkout(
        fn ->
          saved = statement_timeout!()
          limit = if saved == 0, do: @statement_timeout, else: min(saved, @statement_timeout)

          # Arm restoration before a setting change with uncertain acknowledgement.
          try do
            set_statement_timeout!(limit)
            VaultLock.with_shared_checked_out(WorkerRepo, envelope.vault_id, fun)
          after
            restore_statement_timeout!(saved)
          end
        end,
        timeout: @document_checkout_timeout
      )
    end
  end
```

Insert before the existing lock_mode clauses:

```elixir
  defp statement_timeout! do
    %{rows: [[value]], num_rows: 1} =
      SafeSQL.query!(
        WorkerRepo,
        "SELECT setting FROM pg_catalog.pg_settings WHERE name='statement_timeout'",
        [],
        @settings_options
      )

    case Integer.parse(value) do
      {milliseconds, ""} when milliseconds >= 0 and milliseconds <= 2_147_483_647 ->
        milliseconds

      _ ->
        raise ArgumentError, "invalid Document worker statement timeout"
    end
  end

  defp set_statement_timeout!(milliseconds) do
    %{rows: [[value]], num_rows: 1} =
      SafeSQL.query!(
        WorkerRepo,
        "SELECT set_config('statement_timeout','#{milliseconds}ms',false)",
        [],
        @settings_options
      )

    true = is_binary(value)
    ^milliseconds = statement_timeout!()
    :ok
  end

  defp restore_statement_timeout!(saved) do
    set_statement_timeout!(saved)
  rescue
    _ -> discard_owned_connection()
  catch
    _, _ -> discard_owned_connection()
  end

  defp discard_owned_connection do
    # Borrower death disconnects its holder; never check in uncertain session state.
    Process.exit(self(), :kill)
  end
```

- [x] Format only the new Storage test and WorkerScope. Do not format the frozen
  Runtime test file or unrelated files.
- [x] Rerun Task 1's exact command: require 14 executed, zero failures. The actual
  five-minute expiry must run once; no shortening, timeout override or skip.
  Keep the shared Mix slot exclusively owned and send updates during the wait.
  Corrected run: exit 0, 14 tests / zero failures in 353.0 seconds, seed 1208.
  Exact database/root independently absent; see verification evidence.

## Test-only regression compatibility patch

Main read the complete Astra recipe before explicit amendment GO. The following
exact patch records the existing-test adjustment, preserving all race assertions
and tying the authority waiter to the owned blocker and eventual callback.
No production or shared-fixture change. The focused observer correction is
already included in Task 1's complete code above.

```diff
diff --git i/apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs w/apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
index c1e288b..abc6721 100644
--- i/apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
+++ w/apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
@@ -1812,13 +1812,20 @@ defmodule Singularity.Storage.Postgres.DocumentWorkerRepositoryTest do

     try do
       assert_receive {^reference, :locked}, 5_000
+      assert_receive {^reference, :authority_blocker, blocker_backend}, 5_000
       task = progress_task(envelope, :waiting_for_unlock, parent, reference)

       try do
-        assert_receive {^reference, :backend, backend}, 5_000
+        assert {:ok, backend} =
+                 await_progress_blocked_backend(
+                   blocker_backend,
+                   System.monotonic_time(:millisecond) + 4_000
+                 )
+
         assert await_progress_lock_wait(backend, System.monotonic_time(:millisecond) + 4_000)
         send(blocker.pid, {reference, :commit})
         assert :ok = Task.await(blocker, 5_000)
+        assert_receive {^reference, :backend, ^backend}, 5_000
         assert {:error, %Error{code: :forbidden}} = Task.await(task, 5_000)
       after
         Task.shutdown(task, :brutal_kill)
@@ -1967,13 +1974,10 @@ defmodule Singularity.Storage.Postgres.DocumentWorkerRepositoryTest do

   defp progress_task(envelope, state, parent, reference) do
     Task.async(fn ->
-      WorkerRepo.checkout(fn ->
+      WorkerScope.run(envelope, fn context ->
         %{rows: [[backend]]} = SafeSQL.query!(WorkerRepo, "SELECT pg_backend_pid()")
         send(parent, {reference, :backend, backend})
-
-        WorkerScope.run(envelope, fn context ->
-          put_progress_state(context, envelope, state)
-        end)
+        put_progress_state(context, envelope, state)
       end)
     end)
   end
@@ -2006,6 +2010,9 @@ defmodule Singularity.Storage.Postgres.DocumentWorkerRepositoryTest do
               "UPDATE core.principal_capabilities SET revoked_at=CURRENT_TIMESTAMP WHERE principal_id=$1 AND vault_id=$2",
               [c.source.principal_id, c.source.vault_id]
             )
+
+            %{rows: [[backend]]} = query!(MigrationRepo, "SELECT pg_backend_pid()")
+            send(parent, {reference, :authority_blocker, backend})
         end

         send(parent, {reference, :locked})
@@ -2019,6 +2026,39 @@ defmodule Singularity.Storage.Postgres.DocumentWorkerRepositoryTest do
     end)
   end

+  defp await_progress_blocked_backend(blocker_backend, deadline) do
+    %{rows: rows} =
+      SafeSQL.query!(
+        MigrationRepo,
+        """
+        SELECT a.pid
+        FROM pg_catalog.pg_stat_activity AS a
+        WHERE a.usename = 'singularity_worker'
+          AND a.datname = current_database()
+          AND $1::integer = ANY(pg_catalog.pg_blocking_pids(a.pid))
+        """,
+        [blocker_backend]
+      )
+
+    case rows do
+      [[backend]] ->
+        {:ok, backend}
+
+      [] ->
+        remaining = deadline - System.monotonic_time(:millisecond)
+
+        if remaining > 0 do
+          Process.sleep(min(10, remaining))
+          await_progress_blocked_backend(blocker_backend, deadline)
+        else
+          :timeout
+        end
+
+      _ ->
+        flunk("authority blocker has more than one matching worker waiter")
+    end
+  end
+
   defp await_progress_lock_wait(backend, deadline) do
     %{rows: [[waiting]]} =
       SafeSQL.query!(
```

## Task 3: Unchanged source-size regressions and scoped gates

- [x] Rerun the unchanged Runtime file (55 integration executions, 43 exclusions):

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

- [x] Run actual-role storage/authority regressions; record actual counts:

The 14 focused contracts above already cover the new file on the same unchanged
source. Run remaining storage regressions separately, preserving every assertion
without duplicating the real five-minute expiry. This is command partitioning,
not a tag/exclusion or reduced acceptance requirement.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs apps/singularity_storage/test/singularity/storage/authorization_lock_test.exs --seed 1208
```

- [x] Run existing Asset/application regressions (17 additional integration
  executions; with the separate frozen Runtime file, 72 total). Do not duplicate
  C2's exact-size cases already executed on this same source:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs --seed 1208
```

- [x] Run the scoped unit/architecture gate (80 executions, record exclusions):

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
sha256sum apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
```

Each integration invocation prints its exact isolated database and root. After
completion independently query that literal database's absence and inspect that
literal root's absence. Never infer cleanup merely from exit status. Keep borrowed
PostgreSQL/devenv services running. Do not print fixture/key/plaintext dumps.
Require the seven-application graph unchanged and zero xref cycles. A required
unexpected gate failure stops affected work; preserve evidence before diagnosis.

## Task 4: Review and bounded acceptance

First spec review found no deviations. First quality review identified observer
session reentrancy after checkin; the corrected observer excludes the original
and active borrower backends. Fresh 14-contract execution remains required.
The existing progress_task helper's nested checkout caused the initial storage
gate failure. Accepted Astra test-only amendments removed that outer checkout
and preserved the authority race using the exact owned blocker and observed
waiter. The corrected 76-test storage gate passed. No assertion weakening,
shared-fixture change or production nested allowance occurred. Frozen Runtime
tests and the production patch remain unchanged. Independent re-review of these
amendments is still required. Earlier Sol spawn/follow-up returned agent thread
limit reached. Under the user's explicit restore/continue/use-Astra instruction,
a fresh independent Astra-model spec reviewer successfully started. Main's
inspection is not independent review. Reviewer model changes, not acceptance
requirements, are authorized by that instruction.

- [x] Obtain independent spec then quality review using the user's requested
  Astra model. Use fresh independent review contexts, not the architecture-only
  recovery thread; do not claim main's review is independent.
- [x] Main personally inspects every diff, actual counts, backend cleanup and
  frozen prefix/hash. Record exact commands, outcomes, remaining risks and that
  no Vault feature work occurred.
- [x] Only after reviews/gates, make a scoped local repair commit and verify its
  exact source. Publication, Task 12, Phase 2 and release acceptance remain held.
  Code commit `ecb170349ae3ca021e8fe0ca194d4a9b73dfa738` contains only WorkerScope
  and its two scoped Storage test files. `git show` SHA-256 values match all
  recorded tested source hashes; no code changed during commit. Runtime C2 and
  the full C plan remain separately preserved unfinished working-tree work.
- [ ] Resume C3–C5 only after this prerequisite is accepted. Resolve C3's global
  reconciler isolation in a separately reviewed test-only plan before execution.

## Finite contract ledger and attempt accounting

Exactly 14 focused contracts: fresh context/session (1), >15-second callback (1),
15-second SQL cancellation (1), stricter prior cap (1), five callback outcomes
(5), borrower death (1), owned backend loss/restoration failure (1), nested entry
(1), unchanged non-Document expiry (1), actual five-minute outer expiry (1).
In-memory registration/compilation is preparation only, not executed test proof.

Server SQL cancellation and client broken-network timing are distinct: the
15-second server bound does not replace the fixed 300-second lifetime backstop.
Any unexpected production repair failure is retained and counted separately
from a setup-only correction or expected RED. Escalate under the user's Astra
instruction when a repair fails, with at most three Astra production attempts.
Current counters remain Sol production failures 0, Astra production attempts 0.

Historical conservative overall limit: Astra's first named-pool cleanup recommendation
failed its harness gate and counts as 1/3 overall failed repair recommendations,
even though production attempts remain zero. Only two further failed Astra
repairs remain within the user's cap; no three additional production failures.

Latest user instruction supersedes that old cap: restore/continue using Astra,
with at least three failed Astra repair rounds allowed. Retain the historical
unsuccessful recommendation count (1) and track resumed failed repair rounds
separately (currently 0). Agent-capacity errors and read-only review findings are
not failed implementation rounds. No existing failure evidence is reset or erased.
