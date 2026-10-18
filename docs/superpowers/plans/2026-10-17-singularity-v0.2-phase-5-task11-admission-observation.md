# Phase 5 Task11 admission acquisition observation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development for this plan task-by-task, with parent-only Native. Routine approval is covered by continuous authorization; reviews and preserved restrictions are not waived.

**Goal:** Measure the unchanged admission case's source and destination lifetimes
without repairing behavior or changing its execution budget.

**Architecture:** One temporary wrapper and literal checkpoint projection inside
the Runtime live owner's NEW Task11 block. Reuse ResourceOwner.with_checkpoint/2;
all fixtures, production, deadlines, assertions and native work remain exact.

**Tech Stack:** Elixir1.18.4/OTP28.5.0.3, ExUnit, PostgreSQL17.10, existing private
devenv/PG launcher and immutable source/verification seals.

**Status:** ONE OBSERVATION COMPLETE / EXACTLY REMOVED. Native16051actual/0FAIL/
1328.7s; admission completed23165ms, timeout UNREPRODUCED. Native161post0/EMPTY;
exact4167/860295eb restored.
Design/source reviews and formatting/closure passed. No repair/qualification.
Final required gates remain pending; this measurement allowance is consumed.
Governing design: docs/superpowers/specs/2026-10-17-singularity-v0.2-phase-5-task11-admission-observation-design.md.
Read actual AGENTS.md and the complete matching design. E2E NOT RUN; Task16
unwaived BLOCKED_DESIGN; no publication/production or early commit.

---

## Task 1: Seal evidence and independently review design

**Files:** Root-owned matching design/plan, bounded saga cross-references, ignored
archives/manifests only. No source author until design SPEC -> NEW distinct
QUALITY PASS and root explicit source GO.

- [ ] Preserve Native154 natural2/2083 actual/one timeout and the fully read
  original raw70c00603; Native155 ordinary post0/EMPTY/rawb4c865e2 and closing
  1481-pin/status36/indexEMPTY original guard PASS. Do not change their results.
- [ ] Verify original owner4167/860295eb equals the literal archive in the design;
  retain its0600/nonsymlink state. Keep the full NEW Task11 inversee897f3e6.
- [ ] Root adds only a dated observation reference in saga design and plan:
  one temporary owner, original timers, no repair/acceptance, exact removal.
  Do not amend active timer locks, sentinel authority, requirements or raw history.
- [ ] Root self-reviews the complete documents for scope/privacy/call counts/
  reversibility and all commands. Independent design SPEC then NEW distinct
  QUALITY checks actual pinned bytes and all preserved obligations.

## Task 2: Implement the reversible observer in ONE owner

**Modify only:** apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs, inside its NEW Task11 block.
The author is not alone; preserve others' work. Root supplies a writer-safe
manifest excluding only this path; verify it before and after. Static reads,
diffs, hashes and apply_patch only; no formatter/VM/compiler/tests/SQL/services,
Git mutation, subagents, signals or credential-log access.

- [ ] Replace only the generated fault test body, preserving the fault list,
  test name, tmp_dir tag and every original callback/expression/assertion:

```elixir
    @tag :tmp_dir
    test "Task11 actual Runtime #{fault} preserves native order, custody and maintenance barriers",
         %{tmp_dir: tmp_dir} do
      task11_observe_admission(unquote(fault), fn epoch ->
        task11_with_source!(tmp_dir, fn source, portable_root ->
          task11_admission_observation(epoch, :source_ready, :observed)
          task11_admission_observation(epoch, :destination, :begin)

          lifecycle =
            KnowledgeBackupRestoreFixture.with_destination(source.lifecycle, fn fixture ->
              task11_admission_observation(epoch, :destination_callback, :entered)
              task11_fault_attempt!(source, portable_root, fixture, unquote(fault))
              task11_admission_observation(epoch, :fault_attempt, :returned)
              fixture.lifecycle
            end)

          task11_admission_observation(epoch, :destination, :returned)
          assert_closed_lifecycle(lifecycle)
        end)
      end)
    end
```

- [ ] Insert these complete private helpers immediately before the existing
  `defp task11_close_portable_source(root) do`. Do not change the
  existing task11_phase helper or any fixture/source implementation:

```elixir
  defp task11_observe_admission(:admission, fun) when is_function(fun, 1) do
    epoch = System.monotonic_time(:millisecond)

    ResourceOwner.with_checkpoint(
      fn native_stage, _resources ->
        case task11_admission_checkpoint_stage(native_stage) do
          nil -> :ok
          stage -> task11_admission_observation(epoch, stage, :observed)
        end
      end,
      fn ->
        task11_admission_observation(epoch, :case, :begin)
        result = fun.(epoch)
        task11_admission_observation(epoch, :case, :returned)
        result
      end
    )
  end

  defp task11_observe_admission(_fault, fun) when is_function(fun, 1), do: fun.(nil)

  defp task11_admission_observation(nil, _stage, _status), do: :ok

  defp task11_admission_observation(epoch, stage, status)
       when is_integer(epoch) and
              stage in [
                :case,
                :source_ready,
                :destination,
                :destination_callback,
                :fault_attempt,
                :child_attach_requested,
                :child_attached,
                :before_arm,
                :before_allocation,
                :allocated,
                :baseline_paused,
                :maintenance_started,
                :database_created,
                :root_created,
                :extensions_ready,
                :before_migration,
                :migrated,
                :ready,
                :release_requested,
                :waiting_for_child_cleanup,
                :owner_cleanup_begin,
                :before_database_drop,
                :database_drop_in_use,
                :owner_cleanup_completed,
                :child_cleanup_acknowledged,
                :migration_repo_started,
                :request_repo_started,
                :pre_auth_repo_started,
                :dispatcher_repo_started,
                :worker_repo_started,
                :destination_migration_repo_started
              ] and status in [:begin, :entered, :observed, :returned] do
    elapsed = System.monotonic_time(:millisecond) - epoch

    IO.puts(
      :stderr,
      "task11_admission stage=#{stage} status=#{status} elapsed_ms=#{elapsed}"
    )

    :ok
  end

  defp task11_admission_checkpoint_stage(stage)
       when stage in [
              :child_attach_requested,
              :child_attached,
              :before_arm,
              :before_allocation,
              :allocated,
              :baseline_paused,
              :maintenance_started,
              :database_created,
              :root_created,
              :extensions_ready,
              :before_migration,
              :migrated,
              :ready,
              :release_requested,
              :waiting_for_child_cleanup,
              :owner_cleanup_begin,
              :before_database_drop,
              :database_drop_in_use,
              :owner_cleanup_completed,
              :child_cleanup_acknowledged
            ],
       do: stage

  defp task11_admission_checkpoint_stage(
         {:repo_started, Singularity.Storage.MigrationRepo, :migration}
       ),
       do: :migration_repo_started

  defp task11_admission_checkpoint_stage(
         {:repo_started, Singularity.Storage.RequestRepo, :destination}
       ),
       do: :request_repo_started

  defp task11_admission_checkpoint_stage(
         {:repo_started, Singularity.Storage.PreAuthRepo, :destination}
       ),
       do: :pre_auth_repo_started

  defp task11_admission_checkpoint_stage(
         {:repo_started, Singularity.Storage.DispatcherRepo, :destination}
       ),
       do: :dispatcher_repo_started

  defp task11_admission_checkpoint_stage(
         {:repo_started, Singularity.Storage.WorkerRepo, :destination}
       ),
       do: :worker_repo_started

  defp task11_admission_checkpoint_stage(
         {:repo_started, Singularity.Storage.MigrationRepo, :destination}
       ),
       do: :destination_migration_repo_started

  defp task11_admission_checkpoint_stage(_stage), do: nil
```

- [ ] Report full exact diff, owner hash/line count, all commands CLOSED and
  self-review. Ordinary faults invoke fun(nil) once with no installed hook/IO;
  admission calls fun(epoch) once through the restoring checkpoint wrapper.
  Unknown native-stage shapes are ignored only by the projection; native errors
  are not caught or translated. Resource maps are never rendered.
- [ ] Root proves removing exactly this wrapper/markers/helpers recovers the
  literal archived4167/860295eb source; the unchanged whole NEW-block inverse
  still yieldse897f3e6. No other owner/pin/frozen byte may change. This is
  observation, not a Sol/Astra repair attempt.

## Task 3: Root formatting and actual-source reviews

- [ ] Root issues an explicit current source/status seal (no guard exception),
  then uses each exact argv as its OWN guarded Native:

```sh
env MIX_ENV=dev mix format apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs
env MIX_ENV=dev mix format --check-formatted apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs
```

- [ ] Each command must naturally finish; root fully reads its safe raw/footer/
  hash before a separate ordinary residual SQL invocation, full post raw/hash
  and closing guard. If formatting changes bytes, pin the actual formatter
  result before the postguard and re-prove the inverse, not old preformat bytes.
- [ ] Actual SOURCE SPEC reviews exact postformat delta, inverse, privacy,
  one-time callbacks/returns, all old assertions/operations/timers and fixed-only
  output. Then a NEW distinct actual SOURCE QUALITY reviews the same bytes.
  Both are read-only and finish all commands before root Native GO.

## Task 4: Exactly one diagnostic whole-owner measurement

**Run only after:** actors/commands CLOSED, root full source/status/HEAD/index/
frozen56/toolchain/privatePG21905/owned0 guard PASS and fresh raw absent/nonsymlink.

- [ ] Root predeclares one invocation and its only question: full source vs
  destination-stage elapsed boundaries for the unchanged admission case.
  The exact direct argv is:

```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs --seed 97250 --warnings-as-errors
```

- [ ] Use original script/devenv/privatePG wrapper with umask077 and fresh raw.
  No full-gate reproduction claim: this file-selected seeded/WAE diagnostic is
  distinct from Native154 NOARGS integration and mandatory seed215378 master.
  Expected owning scope51 actual; do not count exclusions as passed tests.
- [ ] While LIVE only exact empty owned-session polling and concise commentary.
  No concurrent commands/agents/writes/reads/hashes/SQL/clock, input/signals or
  launcher deadline. Keep60s and the ONE existing120s sentinel tag unchanged.
- [ ] On natural EOF root reads the complete safe unmodified raw through actual
  footer/hash and actual per-owner counts; record each new marker, source-ready
  boundary, owner acquisition/cleanup buckets and reached/missing assertions.
  Broad wall-time buckets do not establish CPU/DDL/fsync/scheduling causation.
  Observer IO overhead is disclosed. No output from a missing stage is success.
- [ ] Only after full raw read run a fresh separate ordinary residual command:

```sh
psql --dbname=postgres --no-psqlrc --tuples-only --no-align --file=.devenv/phase5-task11-residual.sql
```

  Require natural0/EMPTY, complete post safe raw/footer/hash and original full
  closing guard. Preserve every failure; do not rerun unchanged until green.

## Task 5: Exact removal and evidence-based continuation

- [ ] A separate bounded author removes ONLY this observation delta. Parent
  verifies byte-exact archived4167/860295eb owner, full other pins, emptyindex/
  exact status and original guard. Do not overwrite any repair: restoration
  precedes assignment of behavioral work. Keep immutable observation archives.
- [ ] Record actual observations, PASS/FAIL and missing assertions separately
  from Native154 FAIL and all historical failures. An observed PASS is NOT
  admission repair, NOARGS integration PASS, Task11 or Phase5 acceptance.
- [ ] Root and an independent read-only causal/contract assessment choose the
  next measured-evidence step: a causal repair with regression, or a separately
  justified finite admission-only watchdog amendment with synchronized active
  governing clauses. There is no automatic increase or full-context repeat.
  If further context is necessary, first state the concrete unanswered question
  and obtain its own bounded measurement design/review/GO.
- [ ] Keep actual new failure repair counts Sol0/Astra0 until a real repair.
  Two failed actual Sol repair rounds or evidenced technical impasse triggers
  parent-managed Astra; allow at least three bounded actual attempts if needed,
  preserving freeze. Advice/design/observation are not attempts.
- [ ] After a genuine repair/amendment, run whole affected owners, unchanged
  exact saga/retained/prerequisite vectors, sole independent restore, complete
  permitted README (including literal NOARGS integration), and combined actual
  SOURCE SPEC -> NEW distinct QUALITY before small local source commits.
  Then accurate documentation and independent doc reviews precede a separate
  documentation commit. E2E is NOT RUN and never called PASS.

## Separately bounded full-context successor — 2026-10-17

The ONE whole-owner allowance above is CONSUMED by Native160; its unchanged
60s case completed23165ms, not a reproduced slow-context failure or repair.
Both independent causal/contract assessments require the missing full-workload
stage evidence before choosing a repair or finite new admission budget.
The separate candidate design
`docs/superpowers/specs/2026-10-17-singularity-v0.2-phase-5-task11-admission-full-context-observation-design.md`
and matching plan govern any future ONE seeded full-scope diagnostic, only after
NEW design/source reviews and parent GO. This does not renew this plan's original
allowance, change any timer/work/assertion, or replace later NOARGS qualification.
