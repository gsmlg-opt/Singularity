# Phase 5 Nested Fixture Lifecycle Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Root exclusively owns Native execution; authors and reviewers must close all commands before a Native handoff.

**Goal:** Serialize parked parent/child test-resource cleanup without changing production behavior or relaxing any Task11 gate.

**Architecture:** Add explicit parent registration to the existing ResourceOwner process protocol. A child completes native MTE cleanup and configuration restoration before its parent can leave its ready callback; no MTE edit or coordinator is needed. Use an opt-in Task11 wrapper with no post-receipt application configuration writes.

**Tech Stack:** Existing seven-application Elixir/OTP umbrella, ExUnit, Ecto/PostgreSQL, actual disposable MTE databases/roots, existing pinned devenv toolchain.

---

## Governing boundary

Read matching design `docs/superpowers/specs/2026-10-16-singularity-v0.2-phase-5-nested-fixture-lifecycle-design.md`, current AGENTS.md, saga design section 4 and
saga plan Tasks11–13. Continuous authorization selects this recommended approach
without a human approval pause. Design SPEC then fresh independent QUALITY must
pass before Task1 source changes. All results below are planned, NOT RUN.

Source baseline: branch `codex/v0.2-phase-5-export-backup`, HEAD
`fed04c1259450a6be3e8ce5bf6a9a1e03c9758c8`, empty index. Preserve the 16 existing
status entries and all unrelated changes. New authorized paths expand inventory;
record them explicitly rather than deleting them to satisfy an old seal.

No frozen56, MTE, existing lifecycle owner, oracle, original Runtime baseline
block, production, migration, Vault, key, custody, lease, crypto, extraction,
search, default-V2, Task16, concurrency, seed or warning-policy change. Original
timeouts remain unchanged except the single reviewed sentinel aggregate ExUnit
watchdog in the [budget amendment](../specs/2026-10-16-singularity-v0.2-phase-5-task11-sentinel-budget-design.md)
and [plan](2026-10-16-singularity-v0.2-phase-5-task11-sentinel-budget.md), effective
only after design SPEC -> NEW QUALITY and root source GO. No other deadline,
semantic assertion or native operation changes; historical60s FAILs remain FAIL.
No E2E, merge, push, version/tag/release/deployment/activation/production work.

Native13 remains FAILED (110 actual / 1 failure / 6 excluded); post EMPTY does
not change that verdict. This repair addresses cleanup correctness only, not
elapsed-time acceptance. Do not declare Task11 complete after focused GREEN.

## File map

| File | Responsibility |
| --- | --- |
| MODIFY `apps/singularity_storage/test/support/knowledge_fixture_resource_owner.ex` | Explicit child interface, admission/drain/receipt state |
| CREATE `apps/singularity_storage/test/singularity/storage/backup/knowledge_fixture_nested_lifecycle_test.exs` | New complete deterministic lifecycle owner |
| MODIFY only Task11 block in `apps/singularity_runtime/test/support/knowledge_backup_restore_fixture.ex` | One parented destination wrapper |
| MODIFY only Task11 block in `apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs` | Two nested acquisitions pass sentinel owner |
| Matching design/plan and saga design/plan | Scope synchronization and actual evidence |

`knowledge_fixture_lifecycle_test.exs` remains byte exact; MTE remains byte exact.
Do not replace or edit historical prerequisite/frozen manifests. Before each
source-writing task root creates a writer-safe seal excluding only its assigned
writer files, and a fresh full source/status seal after it. Earlier qualification
remains historical; changed helper bytes require fresh affected qualification.

## Task 1: Reproduce real unordered cleanup deterministically

**Files:** New nested lifecycle owner; ResourceOwner additive RED-only entry.

- [ ] Read the unchanged old lifecycle owner's baseline/maintenance helpers,
  token checkpoint actor, registered callback and foreign-identity patterns.
  Copy only necessary private test patterns to the new owner; no old test edit.
- [ ] Add the following transitional entry without changing existing behavior:

```elixir
# RED-only unordered compatibility entry. Replace in Task2.
def open_child(_parent_owner, options \\ [])
    when options in [[], [migration_pool_size: 2]],
    do: open(options)
```

- [ ] Add observation-only boundaries in the existing acquisition callback and
  immediately after the complete MTE call. Do not change release behavior yet:

```elixir
send(caller, {acquire_ref, {:ok, destination}})
outcome = await_release(caller, caller_monitor)
checkpoint.(:owner_cleanup_begin, %{owner: self(), caller: caller})
outcome
```

```elixir
checkpoint.(:owner_cleanup_completed, %{owner: self(), caller: caller})
```

  These real boundaries allow behavioral RED without waiting until replacement
  detection has already misclassified live child Repos. Default no-op observers
  remain no-ops; this is instrumentation, not a cleanup repair.

- [ ] Start the new owner with the established tags and literal baseline queries:

```elixir
defmodule Singularity.Storage.Backup.KnowledgeFixtureNestedLifecycleTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Singularity.Storage.Backup.KnowledgeFixtureResourceOwner, as: ResourceOwner
  alias Singularity.Storage.MigrationRepo

  @repos [MigrationRepo, Singularity.Storage.RequestRepo, Singularity.Storage.PreAuthRepo,
          Singularity.Storage.DispatcherRepo, Singularity.Storage.WorkerRepo]
  @apps [:singularity_storage, :singularity_runtime]

  defp configuration do
    Map.new(@apps, &{&1, Map.new(Application.get_all_env(&1))})
  end

  defp current_database(repo) do
    %{rows: [[database]]} =
      Ecto.Adapters.SQL.query!(repo, "SELECT current_database()", [], log: false, timeout: 1_000)
    database
  end

  defp barrier(controller, token, stage, resources) do
    monitor = Process.monitor(controller)
    send(controller, {token, stage, resources})

    try do
      receive do
        {^token, :continue} -> :ok
        {:DOWN, ^monitor, :process, ^controller, _reason} -> :ok
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end
end
```

- [ ] Implement the decisive ordering case using a non-ExUnit actor owning both
  actual MTE lifetimes. Open parent, capture its actual destination/Repo PIDs,
  park only those exact named Repos, then open child with `open_child/2`.
  Capture both owner identities at `:before_arm`; capture actual names at
  `:ready`. Actor exits itself nonnormally after the controller's token message.
  Controller holds child at actual `:before_database_drop`.
- [ ] Parent checkpoint reports/holds either new
  `:waiting_for_child_cleanup` or the unordered `:owner_cleanup_begin`.
  Receive the positive event, record which occurred, prove child is still held
  and parent database/root remain present. Release child, await its actual
  `:owner_cleanup_completed`/terminal outcome (RED baseline may use its actual
  owner DOWN), then release parent's barrier. Await both actual owner outcomes.
  Assert the recorded first parent event was `:waiting_for_child_cleanup`
  and that parent cleanup-begin observation followed child native cleanup completion.
  A timeout/missing-function failure is NOT the accepted RED.
- [ ] Compare complete final app/compiler/Runtime baseline and baseline Repo
  databases, all acquired exact PIDs dead and both owned database/root absences.
  Keep the RED run clean by releasing child before the held parent proceeds.
  Monitor test-controller death in every barrier; no arbitrary sleep or kill scan.
- [ ] Root formats only this owner/helper, checks warnings, then runs the WHOLE
  new owner through the exclusive launcher:

```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_fixture_nested_lifecycle_test.exs --seed 215378 --warnings-as-errors
```

  Expected RED: actual ordering assertion fails after successful owned cleanup,
  nonzero natural exit, separate ordinary post check EMPTY. Retain complete log,
  source hashes and evidence; do not count excluded tests as passes.
- [ ] Root and independent SPEC then new QUALITY review the actual RED contract
  and evidence before Task2. The shim is not a repair or acceptance.

## Task 2: Implement explicit owner relationships and terminal acknowledgment

**Files:** ResourceOwner and new nested lifecycle owner only.

- [ ] Replace the unordered shim with the design's admitted-child path. Preserve
  old public/default behavior; add a fixed content-free exception:

```elixir
defmodule RelationshipError do
  defexception [:reason]
  def message(%{reason: reason}), do: "knowledge fixture relationship rejected: #{reason}"
end
```

- [ ] Use an explicit parent edge and one active child, no registry/process stack.
  Record exact peer PID, monitor and fresh edge reference inside owner state.
  On prepare, child asks parent to attach; parent ready loop validates original
  actual caller and empty/healthy child slot, records the edge, ACKs. Child must
  not call MTE before that ACK. Reject invalid/dead/foreign/not-ready/closing/
  closed/active/failed parent with exact design reason atoms.
- [ ] Implement these correlated protocol shapes inside existing owner loops:

```elixir
{:attach_child, child_pid, caller_pid, edge_ref, reply_ref}
{:child_attached, parent_pid, edge_ref, reply_ref}
{:child_rejected, parent_pid, edge_ref, reply_ref, reason}
{:close_child, parent_pid, edge_ref}
{:child_cleanup_completed, child_pid, edge_ref, failures}
{:child_cleanup_acknowledged, parent_pid, edge_ref}
```

  Each receive must match its exact peer/reference and monitor. Do not trust
  unmatched terminal messages, clear a different child, or consume a foreign
  callback's receipt. Parent ACK must precede child allocation; child completion
  ACK must precede its normal close reply and next-sibling admission.
- [ ] Cover ALL ready-loop terminal outcomes with the following transition map,
  using the existing MTE callback as the native cleanup boundary:

| Current event | Required next action |
| --- | --- |
| Parent close/finish from actual caller | Record release; send child close if active; service drain loop |
| Caller DOWN | Same child-first drain before returning `:caller_down` |
| Owned dependency EXIT | Same drain; preserve original dependency failure |
| Child terminal receipt in ready/draining | Add failures once; clear exact edge; demonitor; ACK; continue/finish drain |
| Child DOWN without receipt | Add `{:unconfirmed_child_cleanup, child_pid}`; reject later admission; never report success |
| Parent DOWN while child awaits terminal ACK | Add `{:unconfirmed_parent_acknowledgment, parent_pid}`; surface failure |
| Foreign live ancestor release with active child | Reply relationship `:not_owner`; continue servicing child |
| Parent infrastructure start with active child | Reply `{:error, :active_child}`; do not start native work |
| Attachment while not ready/closing/closed | Reply exact relationship reason; no MTE entry |

- [ ] Before returning from every terminal ready-loop path, emit
  `:owner_cleanup_begin` only after child settlement. After the WHOLE MTE call
  returns, emit `:owner_cleanup_completed`, send terminal receipt to own parent
  and service its ACK. Registered completion stays retained for original on_exit;
  parent draining requests close, never finish. No blocking generic child
  request inside a parent waiting for terminal completion.
- [ ] Add the exact fixed checkpoint stages from design section 5. Checkpoint
  observation exceptions become failures and cannot bypass child drain. Never
  print resource maps. Retain original acquisition kind/reason/stack and expose
  cleanup failures separately in retained child/parent receipts.
- [ ] Add real contract groups from design section 5: immediate sibling, actual
  caller ancestor-close, shared caller death, admission and partial-acquisition
  death, exact primary exception plus cleanup error, owned Repo failure,
  registered/unregistered completion, foreign/dead/not-ready/closed/active parent
  rejection, failed-parent rejection, repeated close/on_exit idempotence.
  Use actual registered cleanup functions captured at before_arm, not invented
  callbacks. Deliberate negative receipt tests consume/verify their own actual
  callbacks so expected failures cannot escape as unasserted ExUnit success.
- [ ] Root reruns the whole new owner unchanged and whole legacy owner:

```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_fixture_nested_lifecycle_test.exs --seed 215378 --warnings-as-errors
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_fixture_lifecycle_test.exs --seed 215378 --warnings-as-errors
```

  Expected GREEN: every executed assertion passes, natural exit0, normal owned
  cleanup and separate post EMPTY. Old lifecycle bytes/hash remain exact.
  Independent source SPEC then distinct QUALITY must pass before Task3.

## Task 3: Compose the two Task11 child destinations

**Files:** New Task11 block in Runtime fixture and owner only.

- [ ] Add the following complete wrapper inside the existing Task11 fixture
  block. Existing `require!`, `require_closed_source!`, `configure_runtime!`,
  `lifecycle` and aliases remain the established functions of that module.

```elixir
def task11_with_child_destination!(source, parent_owner, fun) when is_function(fun, 1) do
  require_closed_source!(source)
  apps = [:singularity_storage, :singularity_runtime]
  saved = Map.new(apps, &{&1, Map.new(Application.get_all_env(&1))})
  {owner, destination} = ResourceOwner.open_child(parent_owner, migration_pool_size: 2)

  outcome =
    try do
      require!(destination.database != source.database, "knowledge destination reused source database")
      require!(File.ls!(destination.object_root) == [], "knowledge destination object root is not empty")
      configure_runtime!(destination)
      Application.put_env(:singularity_runtime, :maintenance_mode, true)
      Application.put_env(:singularity_runtime, :start_infrastructure, false)
      repositories = NativeAssetFixture.repo_identities()

      require!(
        is_nil(Process.whereis(KeyCustodian)) and
          is_nil(Process.whereis(Singularity.Runtime.OutboxDispatcher)) and
          is_nil(Oban.whereis(Singularity.Oban)),
        "knowledge destination started ordinary runtime before restore"
      )

      {:return, fun.(%{
        owner: owner, destination: destination, infrastructure: nil,
        repositories: repositories,
        lifecycle: lifecycle(destination, nil, repositories, nil)
      })}
    catch
      kind, reason -> {:raised, kind, reason, __STACKTRACE__}
    end

  cleanup =
    try do
      :ok = ResourceOwner.close(owner)
      :ok
    catch
      kind, reason -> {:raised, kind, reason, __STACKTRACE__}
    end

  case {outcome, cleanup} do
    {{:raised, kind, reason, stack}, _} ->
      if cleanup != :ok, do: IO.puts(:stderr, "Task11 child destination cleanup failed")
      :erlang.raise(kind, reason, stack)

    {{:return, _}, {:raised, kind, reason, stack}} ->
      :erlang.raise(kind, reason, stack)

    {{:return, result}, :ok} ->
      restored = Map.new(apps, &{&1, Map.new(Application.get_all_env(&1))})
      require!(restored == saved, "Task11 child destination configuration differs")
      result
  end
end
```

  No caller-side application write after close. Checkpoint/resource owner
  lifecycle guards must still cover acquisition failures and caller death.
- [ ] Replace only the two nested acquisitions in the sentinel case with:

```elixir
KnowledgeBackupRestoreFixture.task11_with_child_destination!(
  source.lifecycle, sentinel.owner, fn failed ->
    task11_phase(:failed_attempt, :begin)
    task11_fault_attempt!(source, portable_root, failed, :plaintext_after)
    task11_phase(:failed_attempt, :returned)
    task11_phase(:failed_target_close, :begin)
    failed.lifecycle
  end
)
```

  The complete fresh acquisition is:

```elixir
KnowledgeBackupRestoreFixture.task11_with_child_destination!(
  source.lifecycle, sentinel.owner, fn fresh ->
    separate? =
      fresh.destination.database != sentinel.destination.database and
        fresh.destination.object_root != sentinel.destination.object_root and
        fresh.destination.database != failed_lifecycle.database and
        fresh.destination.object_root != failed_lifecycle.object_root

    assert separate?, "RESTART reused a failed or sentinel installation"
    task11_phase(:restart_publication, :begin)
    restarted = task11_full_success!(source, portable_root, fresh)
    task11_phase(:restart_publication, :returned)
    task11_phase(:restart_close, :begin)
    %{fresh.lifecycle | infrastructure: restarted.infrastructure}
  end
)
```

  Do not rewrite these separate identity checks, actual full success, snapshots
  or markers. Both acquisition
  calls remain inside the same original timed case. Do not alter source or
  sentinel acquisition, old with_destination/2 or original baseline blocks.
- [ ] Root verifies baseline inverses, whole-source seals, formatter/check,
  tests/WAE and independent source SPEC then NEW QUALITY on exact bytes.

## Task 4: Fresh affected qualification and preserve timeout evidence

**Files:** No new production implementation. Root-only logs/receipts and docs.

- [ ] Before Native: every author/reviewer command CLOSED, exact source/index/
  status/pins/privatePG/ownedBEAM0 verified. Each argv has a fresh absent and
  nonsymlink raw log under umask077 and existing direct launcher. No compound
  forwarded argv, inner bash-c, envdump, signals, launcher deadline or live
  parallel command. Read complete safe EOF and hash raw; separately run ordinary
  owned-residual SQL. Never read the known secret-containing historical log.
- [ ] Run separately and serialize the whole unchanged required vectors:

```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/native_text_ingestion_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_authorization_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_cut_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs --seed 215378 --warnings-as-errors
mix test apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs apps/singularity_runtime/test/singularity/runtime/restore_vault_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_reconciliation_test.exs apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs --seed 215378 --warnings-as-errors
```

  Historical NativeText GREEN4 seed0 is not this new seed215378 qualification.
- [ ] If the 60,000ms case still fails, preserve actual RED and enter a separate
  evidence-driven latency diagnosis/repair; do not claim this correctness repair
  solved performance. Keep Sol/Astra actual repair counters separate from
  design/advisory attempts, escalate per AGENTS. Do not repeat a master blindly
  or reduce any native work/assertion to obtain GREEN. The separately reviewed
  one-case aggregate ExUnit watchdog amendment is the only timer exception;
  it is not a performance fix or proof of the original60s acceptance condition.
- [ ] Complete every remaining saga Task12/13 and permitted README gate before
  its acceptance; this plan does not replace the independent oracle, full
  prerequisite seed0 vectors, Note-search store, frontend, seven-app/zero-xref,
  workflow lint, test/dev/prod WAE or final source/document independent reviews.
  E2E remains NOT RUN and required for eventual browser/release acceptance.
- [ ] Commit only after required combined saga qualification and source
  SPEC -> fresh QUALITY. Use explicit paths and small local commits, separately
  reviewed evidence documentation. No Task11/Phase5 acceptance while any required
  executed gate fails. Task16 remains unwaived BLOCKED_DESIGN.

## Self-review and handoff

- [ ] Root maps every design section to Tasks1–4 and confirms no missing terminal
  branch, stale interface, unbounded protocol cycle, unsupported PID guarantee,
  new product scope or hidden config write after receipt.
- [ ] Scan plan for placeholder instructions and compare literal call signatures,
  event names, reason atoms, owner file paths and exact test vectors.
- [ ] Obtain independent design SPEC then a fresh QUALITY on the exact reviewed
  generation. Automatically execute the recommended subagent-driven route after
  passing reviews, without requesting routine human approval.
