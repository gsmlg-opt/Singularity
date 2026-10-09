# C3 isolation implementation plan

> For agentic workers: use subagent-driven-development and verification-before-completion.

Status: C3 accepted locally at working-tree source SHA-256
`62631052619632b747892be4636474f4b824ebd3eaaad63501cc589c7bfba3c9`;
Complete C-block acceptance and the dependent eight-file local commit are now
authorized; see `docs/verification/2026-10-09-document-runtime-outcomes-integration.md`
for final-source gates and the separate Task12 scoped qualification. Governing design:
`docs/superpowers/specs/2026-10-09-singularity-v0.2-document-c3-isolation-design.md`.

## Boundary and exact baseline

Worktree: `.trees/v0.2-phase-2-import-extraction`.
Branch: `codex/v0.2-phase-2-import-extraction`.
HEAD: `caf80fd4a1e71bc8b4253fbd058980c0be4a8275`.
Only append to `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`.
Its existing 2,790-line prefix SHA-256 must remain
`20598c663e6ecc57c655d48d32e5e32add3e9032c1827d8124361f4b9b838515`.
Parent owns these documents and the evidence record. Do not stage or edit the
preserved untracked full C plan. No production changes or E2E are authorized.

## Task 1: review and GO

- [x] Parent reads this complete plan and original full C3 module (lines 677–849
  of the full C plan). Independently review exact setup, database admission,
  recovery bounds, original assertions, cleanup, and complete-suite execution.
- [x] Resolve Critical/Important findings before recording TEST GO. An observation
  timeout or review finding is not an unsuccessful Astra implementation attempt.

## Task 2: append the exact C3 module with this isolation amendment

Append the complete `Singularity.Runtime.DocumentOutcomeFencesIntegrationTest`
module from Task C3 of the full C plan, retaining every original assertion and
all nine registered tests. Replace only its one-line setup with the setup below;
add the aliases/attributes/helpers below inside that same new module.

```elixir
alias Singularity.Storage.{MigrationRepo, SafeSQL}
alias Singularity.Storage.Postgres.DocumentRepository

@c3_system_timeout 5_000
@c3_settle_timeout 200_000
@c3_admission_limit 10_000

setup context do
  isolation =
    if Map.get(context, :c3_expiry_isolation, false) do
      guard = suspend_automatic_reconciler!()

      residual =
        bounded_settle!(fn ->
          admit_alias_database!()
          settle_prior_attempts!()
        end)

      %{guard: guard, residual: residual}
    end

  {:ok, fixture: fixture} = C.setup(context)
  {:ok, fixture: fixture, c3_isolation: isolation}
end

defp suspend_automatic_reconciler! do
  supervisor = Process.whereis(Singularity.Runtime.Supervisor)
  pid = Process.whereis(ExtractionReconciler)
  assert is_pid(supervisor) and is_pid(pid)
  assert node(supervisor) == node() and node(pid) == node()
  assert_reconciler_status!(pid, supervisor, :running)
  state = :sys.get_state(pid, @c3_system_timeout)
  assert state == %{repo: WorkerRepo}
  guard = %{pid: pid, supervisor: supervisor, state: state}

  # Arm cleanup before suspend; a timeout does not prove non-delivery.
  on_exit(fn ->
    try do
      assert Process.whereis(ExtractionReconciler) == pid
      assert :sys.get_state(pid, @c3_system_timeout) == state
    after
      # Never address a replacement registered child.
      assert :ok = :sys.resume(pid, @c3_system_timeout)
      assert_reconciler_status!(pid, supervisor, :running)
      assert :sys.get_state(pid, @c3_system_timeout) == state
    end
  end)

  assert :ok = :sys.suspend(pid, @c3_system_timeout)
  assert_reconciler_suspended!(guard)
  guard
end

defp assert_reconciler_status!(pid, supervisor, expected) do
  assert Process.whereis(Singularity.Runtime.Supervisor) == supervisor
  assert Process.whereis(ExtractionReconciler) == pid

  assert {:status, ^pid, {:module, :gen_server},
          [_dictionary, ^expected, ^supervisor, _debug, _status]} =
           :sys.get_status(pid, @c3_system_timeout)

  assert {:links, links} = Process.info(pid, :links)
  assert supervisor in links
end

defp assert_reconciler_suspended!(guard) do
  assert_reconciler_status!(guard.pid, guard.supervisor, :suspended)
  assert :sys.get_state(guard.pid, @c3_system_timeout) == guard.state
end

defp admit_alias_database! do
  assert [[database]] = S.owner_query("SELECT current_database()", []).rows
  assert [^database, suffix] =
           Regex.run(~r/\Asingularity_test_([0-9a-f]{24})\z/, database)
  assert MigrationRepo.config()[:database] == database
  assert WorkerRepo.config()[:database] == database
  assert %{rows: [[^database]]} =
           SafeSQL.query!(WorkerRepo, "SELECT current_database()", [])
  assert Application.fetch_env!(:singularity_storage, :storage_root) ==
           Path.join([System.tmp_dir!(), "singularity", "integration", suffix])

  config = Oban.config(Singularity.Oban)
  assert config.testing == :manual
  assert config.queues == []
  assert config.plugins == []
end

defp extracting_attempts!(excluded_version \\ nil) do
  rows =
    S.owner_query(
      """
      SELECT resource_version_id,vault_id,attempt_generation,attempt_job_id,
             extraction_adapter,extraction_format,attempt_started_at,attempt_deadline_at
      FROM content.document_versions
      WHERE state='extracting'
        AND ($1::uuid IS NULL OR resource_version_id <> $1)
      ORDER BY resource_version_id
      LIMIT 10001
      """,
      [excluded_version]
    ).rows

  assert length(rows) <= @c3_admission_limit
  rows
end

defp settle_prior_attempts! do
  admitted = extracting_attempts!()
  assert [[now]] = S.owner_query("SELECT clock_timestamp()", []).rows

  deadlines =
    Enum.map(admitted, fn
      [_version, _owner, _generation, _job, _adapter, _format, started, deadline] ->
        assert DateTime.diff(deadline, started, :microsecond) == 180_000_000
        assert DateTime.diff(deadline, now, :microsecond) <= 180_000_000
        deadline
    end)

  case deadlines do
    [] ->
      :ok

    [first | rest] ->
      maximum =
        Enum.reduce(rest, first, fn deadline, latest ->
          if DateTime.compare(deadline, latest) == :gt, do: deadline, else: latest
        end)

      wait_past_database_deadline!(maximum, System.monotonic_time(:millisecond) + 190_000)
  end

  assert extracting_attempts!() == admitted
  admitted_ids =
    MapSet.new(admitted, fn [version, owner | _] ->
      {Ecto.UUID.load!(version), Ecto.UUID.load!(owner)}
    end)
  maximum_scans = div(length(admitted) + 99, 100)

  result =
    Enum.reduce_while(0..maximum_scans, nil, fn _, _ ->
      assert {:ok, ids} =
               DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 100)

      case ids do
        [] ->
          {:halt, :settled}

        [_ | _] ->
          assert Enum.all?(ids, &MapSet.member?(admitted_ids, &1))
          before = extracting_attempts!()
          assert {:ok, recovered} = ExtractionReconciler.run(%{repo: WorkerRepo})
          assert recovered == length(ids)
          remaining = extracting_attempts!()
          assert length(before) - length(remaining) == recovered
          assert MapSet.subset?(MapSet.new(remaining), MapSet.new(before))
          {:cont, nil}
      end
    end)

  assert result == :settled
  assert {:ok, []} =
           DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 100)
  residual = extracting_attempts!()
  assert MapSet.subset?(MapSet.new(residual), MapSet.new(admitted))
  residual
end

defp wait_past_database_deadline!(deadline, bound) do
  remaining_bound = bound - System.monotonic_time(:millisecond)
  assert remaining_bound > 0
  assert [[now]] = S.owner_query("SELECT clock_timestamp()", []).rows
  remaining = DateTime.diff(deadline, now, :millisecond)

  if remaining >= 0 do
    token = make_ref()
    delay = min(min(remaining + 2, 30_000), remaining_bound)
    timer = Process.send_after(self(), {:c3_settle_tick, token}, delay)

    try do
      receive do
        {:c3_settle_tick, ^token} -> :ok
      after
        delay + 1_000 -> flunk("C3 settling timer exceeded its bound")
      end
    after
      Process.cancel_timer(timer)
    end

    wait_past_database_deadline!(deadline, bound)
  end
end

defp bounded_settle!(fun) do
  owner = self()
  token = make_ref()
  pid =
    start_supervised!(%{
      id: token,
      restart: :temporary,
      shutdown: :brutal_kill,
      start:
        {Task, :start_link,
         [fn ->
           receive do
             {^token, :start} -> send(owner, {token, self(), fun.()})
           after
             5_000 -> exit(:c3_settle_start_timeout)
           end
         end]}
    })

  monitor = Process.monitor(pid)
  send(pid, {token, :start})

  receive do
    {^token, ^pid, residual} ->
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
      residual

    {:DOWN, ^monitor, :process, ^pid, _reason} ->
      flunk("C3 prior-attempt settling failed")
  after
    @c3_settle_timeout ->
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
      flunk("C3 prior-attempt settling exceeded its bound")
  end
end

defp assert_c3_isolation!(isolation, fixture) do
  assert_reconciler_suspended!(isolation.guard)
  assert extracting_attempts!(fixture.document.resource_version_id) == isolation.residual
end
```

Change the existing expiry test's tag and header to exactly:

```elixir
@tag timeout: 420_000
@tag c3_expiry_isolation: true
test "actual DB deadline expiry and concurrent recovery fence every old outcome and terminal callback",
     %{fixture: f, c3_isolation: isolation} do
```

Retain its full original body. Add `assert_c3_isolation!(isolation, f)` at five
points: before its first claim; immediately after `C.wait_for_deadline!/2`;
immediately before starting its two scanners; immediately after their monitored
completion; and at the end. Immediately after the deadline wait also add:

```elixir
assert {:messages, queued} = Process.info(isolation.guard.pid, :messages)
assert :reconcile in queued
```

## Task 3: verification and failure paths

- [x] Verify frozen-prefix SHA, original C3 assertions, no production changes,
  scoped formatting, and `git diff --check`.
- [x] Validate cleanup for failure immediately after suspend, fixture setup
  failure, settling timeout, and test-process termination with a disposable
  test-only harness under the parent-owned Mix slot. It must exercise the actual
  registered callback and ExUnit process lifecycle, not a substitute resume.
  Record exact commands/results; no permanent extra C3 tests or production hooks.
- [x] Run the **unfiltered** cumulative integration file:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

Expected: 107 reported, 43 unit excluded, 64 integration executed, zero failures.
No line/module/tag exclusion is allowed as acceptance. Record real deadline and
settling observations, original exact successor result, process restoration,
exit code, allocated database/storage root, and independent cleanup checks.
Only one shared Mix process may run. Parent communicates progress at most 60
seconds apart. No borrowed host service may be changed/stopped.

## Task 4: review, evidence, and commit

- [x] Independent spec review, then quality review. Resolve findings; do not
  weaken assertions. Unexpected failures stop this bounded slice before any
  production edit. Astra is authorized for bounded repairs; resumed failed
  implementation rounds start at zero and the user allows at least three.
- [x] Record exact files, source hashes, commands/counts/elapsed/cleanup/reviews,
  exclusions, and no Vault work in the verification evidence. Record a tested
  working-tree checkpoint; defer the dependent Runtime source commit until the
  complete C1–C5 block is accepted. C3 requires the preserved uncommitted C1/C2
  support, so staging C3 alone would produce a broken intermediate commit.
  Preserve all other dirty work, including the untracked full C plan.
- [x] Stop C3 acceptance. C4/C5 and full release acceptance remain separate gates.

## Disposable failure-path driver (complete executable source)

Independent Astra review resolved quoted alias hygiene and elapsed-baseline
races before execution. Helpers remain the exact actual C3 AST. The wrapper
records actual callback success because ExUnit can mask on_exit failures behind
an already-failed test. Main personally read this complete driver.

Create a parent-owned temporary runtime probe containing only
`C3CleanupHarness.compile!()`. Place the following driver in a `mktemp -d`
directory; run it from the worktree root under the exclusive Mix slot:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix run --no-start /tmp/singularity-c3-cleanup.SpfMQL/driver.exs apps/singularity_runtime/test/c3_cleanup_probe_spfmql_test.exs
```

Require outer exit zero, exactly four expected inner failures, four actual
callback successes, four restoration observer successes, no skips/exclusions,
unchanged source SHA, and independent alias database/root cleanup. Remove only
the owned probe/driver after recording evidence, before the unfiltered suite.
Intentional probe failures are not failed repair attempts. Never shorten the
actual 200-second settle timeout.

```elixir
defmodule C3CleanupHarness do
  import ExUnit.Assertions

  @table __MODULE__
  @scenarios [:after_suspend, :fixture_setup, :settle_timeout, :test_death]
  def table, do: @table

  def put(key, value) do
    true = :ets.insert(@table, {key, value})
    :ok
  end

  def get(key) do
    assert [{^key, value}] = :ets.lookup(@table, key)
    value
  end

  def compile! do
    source = get(:source)
    ast = source |> File.read!() |> Code.string_to_quoted!(file: source)
    {:__block__, _, forms} = ast

    module_body = fn name ->
      matches =
        for {:defmodule, _, [{:__aliases__, _, parts}, [do: body]]} <- forms,
            Module.concat(parts) == name,
            do: body

      assert [body] = matches
      body
    end

    for name <- [
          Singularity.Runtime.DocumentSourceIntegrationSupport,
          Singularity.Runtime.DocumentOutcomeIntegrationSupport
        ] do
      body = module_body.(name)
      Code.compile_quoted(quote(do: defmodule(unquote(name), do: unquote(body))), source)
    end

    {:__block__, _, statements} =
      module_body.(Singularity.Runtime.DocumentOutcomeFencesIntegrationTest)

    prefix =
      Enum.filter(statements, fn
        {:alias, _, _} -> true
        {:@, _, [{name, _, [_]}]} -> String.starts_with?(Atom.to_string(name), "c3_")
        _ -> false
      end)

    helpers = Enum.filter(statements, &match?({:defp, _, _}, &1))
    assert helpers != []
    assert [setup] = Enum.filter(statements, &match?({:setup, _, _}, &1))
    context = Macro.var(:context, nil)

    {setup, counts} =
      Macro.postwalk(setup, {0, 0, 0}, fn
        {:suspend_automatic_reconciler!, _, []} = call, {a, b, c} ->
          replacement =
            quote do
              guard = unquote(call)
              if unquote(context).c3_failure_scenario == :after_suspend,
                do: raise("C3_HARNESS_AFTER_SUSPEND")
              guard
            end
          {replacement, {a + 1, b, c}}

        {:bounded_settle!, metadata, [fun]}, {a, b, c} ->
          injected_fun =
            quote do
              fn ->
                if unquote(context).c3_failure_scenario == :settle_timeout do
                  C3CleanupHarness.put(
                    {:settle_timeout, :task},
                    {self(), System.monotonic_time(:millisecond)}
                  )

                  receive do
                    :c3_harness_unblock -> raise "C3_HARNESS_UNEXPECTED_UNBLOCK"
                  after
                    210_000 -> raise "C3_HARNESS_TIMEOUT_BRANCH_NOT_REACHED"
                  end
                else
                  apply(unquote(fun), [])
                end
              end
            end
          replacement =
            quote do
              if unquote(context).c3_failure_scenario == :settle_timeout do
                C3CleanupHarness.put(
                  {:settle_timeout, :entered},
                  System.monotonic_time(:millisecond)
                )
              end
              unquote({:bounded_settle!, metadata, [injected_fun]})
            end
          {replacement, {a, b + 1, c}}

        {{:., dot_metadata, [{:__aliases__, _, [:C]} = alias_ast, :setup]},
         call_metadata, [arg]}, {a, b, c} ->
          injected_arg =
            quote do
              if unquote(context).c3_failure_scenario == :fixture_setup,
                do: Map.delete(unquote(arg), :tmp_dir),
                else: unquote(arg)
            end
          replacement = {{:., dot_metadata, [alias_ast, :setup]}, call_metadata, [injected_arg]}
          {replacement, {a, b, c + 1}}

        node, counts -> {node, counts}
      end)

    assert counts == {1, 1, 1}
    put(:helper_ast_sha256, :crypto.hash(:sha256, :erlang.term_to_binary(helpers)))

    probe =
      quote do
        defmodule C3CleanupProbe do
          use Singularity.Storage.DataCase, async: false
          import ExUnit.Callbacks, except: [on_exit: 1, on_exit: 2]
          @moduletag :integration
          @moduletag :tmp_dir
          @moduletag c3_expiry_isolation: true
          @moduletag timeout: 230_000
          unquote_splicing(prefix)

          setup context do
            scenario = context.c3_failure_scenario
            Process.put(:c3_cleanup_scenario, scenario)
            pid = Process.whereis(Singularity.Runtime.Documents.ExtractionReconciler)
            supervisor = Process.whereis(Singularity.Runtime.Supervisor)
            assert_reconciler_status!(pid, supervisor, :running)
            state = :sys.get_state(pid, @c3_system_timeout)

            C3CleanupHarness.put(
              {scenario, :baseline},
              %{pid: pid, supervisor: supervisor, state: state, test_pid: self()}
            )

            ExUnit.Callbacks.on_exit(fn ->
              assert_reconciler_status!(pid, supervisor, :running)
              assert :sys.get_state(pid, @c3_system_timeout) == state
              assert C3CleanupHarness.get({scenario, :callback}) == :ok

              if scenario == :settle_timeout do
                {task, _task_started} = C3CleanupHarness.get({scenario, :task})
                started = C3CleanupHarness.get({scenario, :entered})
                assert System.monotonic_time(:millisecond) - started >= @c3_settle_timeout
                refute Process.alive?(task)
                monitor = Process.monitor(task)
                assert_receive {:DOWN, ^monitor, :process, ^task, :noproc}, 5_000
              end

              C3CleanupHarness.put({scenario, :observer}, :ok)
            end)
            :ok
          end

          unquote(setup)

          setup context do
            C3CleanupHarness.put({context.c3_failure_scenario, :setup_complete}, true)
            :ok
          end

          for scenario <- [:after_suspend, :fixture_setup, :settle_timeout, :test_death] do
            @tag c3_failure_scenario: scenario
            test "cleanup #{scenario}", context do
              if context.c3_failure_scenario == :test_death,
                do: Process.exit(self(), :kill),
                else: flunk("C3_HARNESS_SETUP_UNEXPECTEDLY_SUCCEEDED")
            end
          end

          defp on_exit(callback) do
            scenario = Process.get(:c3_cleanup_scenario)
            ExUnit.Callbacks.on_exit(fn ->
              try do
                result = callback.()
                C3CleanupHarness.put({scenario, :callback}, :ok)
                result
              catch
                kind, reason ->
                  C3CleanupHarness.put({scenario, :callback}, {:failed, kind, reason})
                  :erlang.raise(kind, reason, __STACKTRACE__)
              end
            end)
          end

          unquote_splicing(helpers)
        end
      end
    Code.compile_quoted(probe, source)
  end

  def verify! do
    results = for {{:suite_result, _}, result} <- :ets.tab2list(@table), do: result
    assert [%{total: 4, failures: 4, excluded: 0, skipped: 0}] = results
    tests = for {{:test_finished, _}, test} <- :ets.tab2list(@table), do: test
    assert length(tests) == 4
    assert Enum.sort(Enum.map(tests, & &1.tags.c3_failure_scenario)) == Enum.sort(@scenarios)

    for test <- tests do
      scenario = test.tags.c3_failure_scenario
      baseline = get({scenario, :baseline})
      case {scenario, test.state} do
        {:after_suspend,
         {:failed, [{:error, %RuntimeError{message: "C3_HARNESS_AFTER_SUSPEND"}, _}]}} ->
          :ok

        {:fixture_setup, {:failed, [{:error, %KeyError{key: :tmp_dir}, stack}]}} ->
          assert Enum.any?(stack, fn
                   {Singularity.Runtime.DocumentSourceIntegrationSupport, :setup, _, _} -> true
                   _ -> false
                 end)

        {:settle_timeout, {:failed, [{:error, %ExUnit.AssertionError{message: message}, _}]}} ->
          assert message == "C3 prior-attempt settling exceeded its bound"

        {:test_death, {:failed, [{{:EXIT, pid}, :killed, _}]}} ->
          assert pid == baseline.test_pid

        unexpected -> flunk("unexpected harness outcome: #{inspect(unexpected)}")
      end

      assert get({scenario, :callback}) == :ok
      assert get({scenario, :observer}) == :ok
      if scenario == :test_death do
        assert get({scenario, :setup_complete}) == true
      else
        assert :ets.lookup(@table, {scenario, :setup_complete}) == []
      end
    end

    assert :crypto.hash(:sha256, File.read!(get(:source))) == get(:source_sha256)
    IO.puts("C3 cleanup harness PASS: four exact expected failures; four actual callbacks succeeded; four restoration observers succeeded")
    IO.puts("helper_ast_sha256=#{Base.encode16(get(:helper_ast_sha256), case: :lower)}")
  end
end

defmodule C3CleanupFormatter do
  use GenServer
  def init(_options), do: {:ok, nil}
  def handle_cast({:test_finished, test}, state) do
    C3CleanupHarness.put({:test_finished, make_ref()}, test)
    {:noreply, state}
  end
  def handle_cast(_event, state), do: {:noreply, state}
end

import ExUnit.Assertions
assert [probe] = System.argv()
probe = Path.expand(probe)
assert File.regular?(probe)
assert String.starts_with?(probe, Path.expand("apps/singularity_runtime/test") <> "/")
source = Path.expand("apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs")
prefix = source |> File.stream!() |> Enum.take(2790) |> Enum.join()
assert Base.encode16(:crypto.hash(:sha256, prefix), case: :lower) ==
         "20598c663e6ecc57c655d48d32e5e32add3e9032c1827d8124361f4b9b838515"
:ets.new(C3CleanupHarness.table(), [:named_table, :public, :set])
C3CleanupHarness.put(:source, source)
C3CleanupHarness.put(:source_sha256, :crypto.hash(:sha256, File.read!(source)))
ExUnit.start(autorun: false)
ExUnit.after_suite(fn result -> C3CleanupHarness.put({:suite_result, make_ref()}, result) end)

outcome =
  try do
    Mix.Task.run("singularity.test.integration", [probe, "--raise", "--seed", "0", "--formatter", "C3CleanupFormatter"])
    :unexpected_success
  rescue
    error in Mix.Error ->
      assert error.message == "\"mix test\" failed"
      :expected_inner_failure
  end

assert outcome == :expected_inner_failure
C3CleanupHarness.verify!()
```

## Accepted repair iteration 2: actual successor causation normalization

First unfiltered execution: exit 2, 535.5 seconds, 107 reported, 43 excluded,
64 integration attempted, three failures in the same C1 successor mapping.
The other 61 contracts, including actual expiry/recovery, passed. Exact alias
database/root cleanup passed independently. Source `9a043a7…cfe4e` stayed fixed.

Astra traced actual retry/restore SQL's NULL causation through production
`Postgres.Outbox.claimed_event/1` line 156 to the normalized event passed to
OutboxDispatcher. Parent personally verified that complete boundary and codec
validation. Parent grants only this explicit C1 freeze exception, using
apply_patch after the failed invocation has terminated:

```diff
-      causation_id: if(is_nil(causation), do: nil, else: Ecto.UUID.load!(causation)),
+      causation_id: Ecto.UUID.load!(causation || id),
```

No other line in the first 2,790 lines may change. Do not format that old segment.
Immediately after the pending-restore test's `successor = C.successor!(f, 1)`,
add exactly these positive controls, retaining its original body:

```elixir
assert successor.envelope.causation_id == successor.envelope.job_id
assert [[nil]] ==
         S.owner_query(
           "SELECT causation_id FROM core.outbox_events WHERE id=$1 AND vault_id=$2",
           [Ecto.UUID.dump!(successor.envelope.job_id), f.source.vault_id]
         ).rows
```

- [x] Apply only the one-line helper mapping and two new assertions.
- [x] Record new 2,790-line prefix and whole-source hashes; reverse only the
  authorized mapping in memory and prove the original prefix hash
  `20598c663e6ecc57c655d48d32e5e32add3e9032c1827d8124361f4b9b838515`.
  Prove original A/B prefix `373ad3d5…14178` unchanged and original assertions
  retained. Format/check only C3 append.
- [x] Prove unchanged cleanup-helper text SHA
  `c74a7a36190a849304b774991c923f4a24a4957078a4e6caea4b763e813b5b46`
  from `defp suspend_automatic_reconciler!` through module end. Existing successful
  four-scenario execution remains scoped to these exact unchanged helpers;
  successor mapping is exercised by the fresh full integration gate instead.
- [x] Re-run the same unfiltered Runtime integration command, seed 1208, all 64
  contracts, with no skip/filter/clock/deadline/config/codec/event changes.
- [x] Exact alias cleanup, independent spec then quality re-review, parent
  acceptance. Corrected C3 source is accepted; C4/C5 freeze metadata now records
  its exact hash. At that historical checkpoint, separate C4 GO was recorded
  in its amendment and C5 remained held. Current C5 acceptance and pending C6
  gates are recorded in `docs/verification/2026-10-09-document-runtime-outcomes-integration.md`.

Final command adds only diagnostic `--trace` to the unfiltered command above:
exit 0, 516.2 seconds, 107 reported, 43 unit excluded, 64 integration executed,
zero failures. The real expiry/recovery contract took 357.4264 seconds. Exact
database `singularity_test_e9ab09bff14529c8c2c191ca` and storage root
`/tmp/singularity/integration/e9ab09bff14529c8c2c191ca` independently confirmed
absent after exit. See the verification evidence for full source/freeze/cleanup
proofs. No production/Vault/E2E work or external publication occurred.
