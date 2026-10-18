# Phase 5 Task11 bounded latency observation plan

Governing design:
docs/superpowers/specs/2026-10-16-singularity-v0.2-phase-5-task11-latency-observation-design.md
Existing nested lifecycle design/plan and saga plan remain governing. Continuous
authorization permits recommended design/review/implementation without routine
approval. This is a temporary observation, not a latency repair or acceptance.

## Later qualification amendment — 2026-10-16

The temporary observer was removed exactly after Native64. Its Native63/64
measurements kept the original60_000ms timer and their actual results remain
immutable. For FUTURE observer-free qualification, only the original sentinel
case's aggregate ExUnit watchdog has the separately reviewed
[sentinel budget amendment](../specs/2026-10-16-singularity-v0.2-phase-5-task11-sentinel-budget-design.md)
and [plan](2026-10-16-singularity-v0.2-phase-5-task11-sentinel-budget.md).
This is effective only after design SPEC -> NEW QUALITY and root source GO.
The no-timer-change clauses below remain historical requirements for this
completed diagnostic slice; they do not override that explicit future exception.
Every semantic assertion/native operation and all other restrictions stay.

## 1. Seal and independently review the measurement design

- Root preserves Native60 actual110/oneFAIL, complete safe raw/hash, separate
  post0EMPTY and closing guard, both read-only diagnosis results and old latency map.
- Archive the exact current Runtime owner4166/28e910d7 under ignored .devenv;
  require actual archive hash equality, emptyindex, diffcheck and frozen56 exact.
- Pin this design/plan and exact source/status in a fresh generation.
- Independent design SPEC then NEW distinct QUALITY, both read-only with
  before/after guards. Resolve findings before source author starts.

## 2. Source-only temporary observer, ONE owner file

A Sol author owns only the NEW Task11 block of:
apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs
No formatter/compiler/tests/VM/SQL/services/Git mutation by the author. Other
files and original baseline blocks remain exact. Root supplies a writer
manifest excluding only this literal owner path. Preserve others' work.

Add this complete private helper in that block, using the existing alias:

```elixir
defp task11_observe_lifetime(lifetime, fun)
     when lifetime in [:source, :sentinel, :failed, :restart] and is_function(fun, 0) do
  epoch = Process.get({__MODULE__, :task11_diagnostic_epoch})
  true = is_integer(epoch)

  ResourceOwner.with_checkpoint(
    fn native_stage, _resources ->
      case task11_checkpoint_stage(native_stage) do
        nil ->
          :ok

        stage ->
          elapsed = System.monotonic_time(:millisecond) - epoch

          IO.puts(
            :stderr,
            "task11_fixture=#{lifetime} stage=#{stage} status=observed elapsed_ms=#{elapsed}"
          )

          :ok
      end
    end,
    fun
  )
end

defp task11_checkpoint_stage(stage)
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

defp task11_checkpoint_stage({:repo_started, Singularity.Storage.MigrationRepo, :migration}),
  do: :migration_repo_started

defp task11_checkpoint_stage({:repo_started, Singularity.Storage.RequestRepo, :destination}),
  do: :request_repo_started

defp task11_checkpoint_stage({:repo_started, Singularity.Storage.PreAuthRepo, :destination}),
  do: :pre_auth_repo_started

defp task11_checkpoint_stage({:repo_started, Singularity.Storage.DispatcherRepo, :destination}),
  do: :dispatcher_repo_started

defp task11_checkpoint_stage({:repo_started, Singularity.Storage.WorkerRepo, :destination}),
  do: :worker_repo_started

defp task11_checkpoint_stage({:repo_started, Singularity.Storage.MigrationRepo, :destination}),
  do: :destination_migration_repo_started

defp task11_checkpoint_stage(_stage), do: nil
```

Make these exact insertions against the immutable4166-line archive; apply by
stable source anchors, not shifting live line numbers:

1. Replace source assignment3303 with:

```elixir
source =
  task11_observe_lifetime(:source, fn ->
    KnowledgeBackupRestoreFixture.backup_source!(portable_root, :uuid)
  end)
```

2. Immediately before the complete outer sentinel expression3198, insert
   `task11_observe_lifetime(:sentinel, fn ->`. Immediately after its matching
   `end)` at archived3282 insert `end)`. Indent that original expression by
   two spaces; retain every original callback and surrounding assertion.
3. Immediately before the complete failed-child expression3218 insert
   `task11_observe_lifetime(:failed, fn ->`; immediately after its matching
   closing parenthesis3228 insert `end)`. Indent only the enclosed expression.
4. Immediately before the complete fresh-child expression3246 insert
   `task11_observe_lifetime(:restart, fn ->`; immediately after its matching
   closing parenthesis3263 insert `end)`. Indent only the enclosed expression.

The two child insertions are nested inside the sentinel insertion. Preserve all
original arguments, callback lines, result bindings and surrounding assertions.
Do not move case3192 or any setup outside it. Do not change fixture/helper/MTE/
oracle, existing checkpoint contracts or errors.
Report exactdiff/hash/linecount, inverse proof, self-review and commandsCLOSED.

## 3. Root format and exact source reviews

- Verify writer manifest and scope, original-baseline inverse, and removal of
  only the four wrappers/helper reproduces archived owner4166/28e910d7.
- Root alone formats/checks ONLY this owner; fresh safe raw/post/closure for each.
  If formatting changes bytes, derive actual fresh seal before post guard.
- Independent ACTUAL SOURCE SPEC then NEW distinct QUALITY on exact bytes:
  review closure capture, literal projection, no resource rendering, single
  callback, nested hook restoration, errors/results/assertions/nativework/timer
  unchanged, reversible source diff. All commands CLOSED before execution.
- Do not count this observer as a Sol/Astra behavioral repair.

## 4. Initial focused Native measurement, not qualification

Exact direct argv (one invocation, no compound forwarding):

```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs:3192 --seed 215378 --warnings-as-errors
```

Use the existing root-only script/devenv/privatePG launcher and full guard.
Fresh absent/nonsymlink raw, umask077. WhileLIVE ONLY exact empty-sessionpoll
and commentary; no concurrent commands/actors, writes, reads, SQL, clock,
input/signals/kill or launcher deadline. Natural EOF. Never read
.devenv/phase5-task11-native-text-regression-static-native.log.

Read complete safe raw through EOF, actual exit and executed/excluded count,
hash, then separate ordinary residualSQL0EMPTY/fullclosingguard/owned0.
A failing test remains FAIL; missing stage is NOT a completed boundary.
Expected selection one actual case/50 exclusions: exclusions are NOT passes.
No master/Task11/phase performance acceptance from any focused outcome.

Record fixed lifetime+stage elapsed boundaries and database_drop_in_use count.
Separate admission, create, extension, migration, Repo start, child drain, native
shutdown/drain, DROP/rest and ACK buckets; do not infer unavailable after-DROP.
Close-return tail includes config equality/lifecycle assertions. Report
observer overhead and uncertainty, not an invented cause or optimization.
If failed-master context needs further measurement, root first records the
specific unanswered question and new guarded whole-owner/master measurement GO.

## 5. Restore baseline, then causal repair or honest external blocker

Remove only new observation wrappers/helper and verify exact archived28e910d7,
fixture312bf952/helperbdda89e1/MTEef2627fe/oracle4dd69f7d/frozen56 unchanged.
No behavioral repair may be overwritten by restoration: restore BEFORE assigning
a repair author. Preserve diagnostic raw/results and every historical FAIL.

Use actual measurement to form a separate bounded repair design/plan and
regression. >=2 failed actual Sol repair rounds or evidenced technical impasse
requires parent-managed Astra recovery. Prior SOL_IMPASSE/advisory remains
historical evidence; actual latency Sol0/Astra0 until real repairs occur.
Allow at least3 actual bounded Astra repair attempts if needed. Advice and
observation are not attempts. No repeated blind master or scope/coverage waiver.

All required whole affected vectors, saga Tasks12/13, complete permitted README,
source SPEC->NEWQUALITY and documentation reviews remain required before local
acceptance/commits. Task4fourthStoragevector is stillpending. Task16 is unwaived
BLOCKED_DESIGN; E2E NOTRUN is the only user-deferred test category.
No Vault/production/frozen changes, merge/push/version/tag/release/deployment.
