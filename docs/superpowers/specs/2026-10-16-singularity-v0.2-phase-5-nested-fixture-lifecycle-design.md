# Phase 5 Task11 nested fixture cleanup compatibility design

## Status and authority

Proposed narrow test-helper compatibility amendment, 2026-10-16. No implementation,
behavioral RED, GREEN, or acceptance is claimed by this document. Required design
SPEC then a fresh independent QUALITY review precede implementation. Continuous
development authorization in AGENTS.md permits necessary test compatibility
repairs; the older Task11 file allowlist is not a user-frozen product boundary.

This amends only the ResourceOwner exclusion in saga design section 4 and the
corresponding locked file map / Task11 / Task13 clauses in
`2026-10-15-singularity-v0.2-phase-5-knowledge-v3-saga.md`.
All saga requirements and failed evidence remain in force. No production change,
MTE change, new migration, Vault/key/custody/lease change, E2E, merge, push, version,
tag, release, deployment, activation, or production-data work is authorized.

Astra supplied the explicit parent-child architecture under
`astra_gate=PROJECT_ARCHITECTURE`; prior `SOL_IMPASSE` diagnosis remains evidence,
not a claim of two failed Sol timeout repairs. Actual timeout repair rounds
remain Sol 0 / Astra 0 at this design boundary.

## 1. Observed failure and bounded claim

Native13's unchanged complete four-owner master naturally exited 2: Storage
59 actual / 0 failures, Runtime 51 actual / 1 failure, six excluded tests not
passes. The sole failure was the existing sentinel/failed-target/fresh-RESTART
case at its unchanged 60,000 ms deadline. Native12's same-source standalone
Runtime run passed 51 actual cases; that does not erase Native13.

After Native13's caller death, 3,440 Postgrex reconnect errors referenced an
already deleted synthetic database. The separate ordinary post check exited
0 / EMPTY. Source inspection proves a reachable cleanup race, not the precise
database/PID association or elapsed-time cause in that run:

1. Outer sentinel owner and inner target owner independently monitor the same
   actual caller. Both can enter MTE cleanup concurrently after caller death.
2. Inner MTE captured the parked sentinel's application configuration. Outer MTE
   captured the ordinary baseline.
3. Inner restoration can overwrite outer restoration; outer argless baseline
   Repo startup can then read the already deleted sentinel database.
4. ExUnit's reverse-order callbacks join cleanup that may already be running;
   callback order cannot serialize these autonomous owner monitors.

The selected repair establishes resource-lifetime ordering. It does not fix or
waive accumulated timeout latency. Task11 stays unaccepted until every required
gate passes unchanged. Native13's raw/RED/post/source archives remain immutable.

## 2. File ownership and preserved evidence

| Path | Authorized responsibility |
| --- | --- |
| `apps/singularity_storage/test/support/knowledge_fixture_resource_owner.ex` | Add explicit child admission, child-first cleanup and completion receipts |
| NEW `apps/singularity_storage/test/singularity/storage/backup/knowledge_fixture_nested_lifecycle_test.exs` | Deterministic native nested-lifecycle contracts |
| Task11 block in `apps/singularity_runtime/test/support/knowledge_backup_restore_fixture.ex` | Explicit parented destination wrapper only |
| Task11 block in `apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs` | Replace only failed/fresh nested acquisition callsites |
| This design, matching plan, saga design/plan | Scope, protocol, validation and actual evidence synchronization |

Leave the complete 1,793-line existing lifecycle test unchanged, SHA-256
`cc897ec5c81ea8250f261a795db340c50f8c0462b758288696f30d46acb44948`.
Leave MigrationTestEnvironment unchanged, SHA-256
`ef2627fe6d3330d7f9b74c71d87d188255d116270344021a7d736612192bf319`.
Leave the Runtime oracle and original 3104/2007/745-line baseline blocks exact.

ResourceOwner's old SHA-256
`1ae47ae0590523d35d0f470e4b7534777b7dd19ee780c902c8b43cdb7e04bb49`
is an accepted-helper prerequisite pin, not an entry in the true frozen56
registry. Preserve old source manifests and qualification receipts as historical
evidence. A new explicitly scoped writer-safe generation excludes only authorized
writer paths; a fresh full seal pins actual changed bytes before Native.
Never regenerate the frozen56 registry from modified files. Registry SHA-256 stays
`d0296d241c66e382baa09a0a092fe8add6df66364d5f2d5644f4f4ea1963a050`.

## 3. Public interface and admission

Add `open_child(parent_owner, options \\ [])`, returning the existing
`{owner_pid, destination}`. Options remain exactly `[]` or
`[migration_pool_size: 2]`. Preserve every default `open/0,1`, `close/1`,
`start_infrastructure/2`, registration and unnested failure behavior.

The parent is a genuine live helper owner returned to the SAME actual calling
process, in its ready loop. Task11 uses only an already parked sentinel whose
exact owned runtime and named Repos have stopped. This API does not permit
nesting over a live installation, caller overrides, ownership transfer, implicit
caller stacks, registry lookup, or new timeout options.

An arbitrary live non-helper PID is outside the admissible-input contract:
without a new registry or timer, bounded rejection of a peer that never answers
cannot be guaranteed. Test real helper parents with different callers, dead
parents, non-PIDs and the caller PID, not that unsupported guarantee.

Add `RelationshipError` with fixed `reason` atom and content-free message.
Reasons are `:invalid_parent`, `:parent_down`, `:different_caller`,
`:parent_not_ready`, `:parent_closing`, `:parent_closed`, `:active_child`,
`:parent_cleanup_failed`, `:not_owner`. Reject admission before MTE entry,
configuration capture/mutation, Repo pausing, or allocation.

A newly spawned unarmed child prepares using the actual caller and existing
actual ExUnit registration. During prepare it requests attachment to the parent.
The edge has a fresh reference, exact child PID and monitor. Only the parent's
ready loop admits a matching original caller with no active child or earlier
descendant failure. Parent records the edge and ACKs before child acquisition.
Parent ACK and later drain commands have the same sender and ordered delivery.
No new process category or coordinator is added.

Each owner retains only its original caller, registration flag, optional parent
edge, at most one active child edge, descendant failure list and lifecycle phase.
Before ready and after leaving ready, reject new attachment explicitly. A fresh
child has one immutable parent and no descendants at admission; cycles cannot be
introduced through the supported API.

## 4. Child-first completion protocol

The enforced order is:

```text
child complete native MTE cleanup + complete configuration restoration
  -> parent records terminal receipt, clears active edge and ACKs child
  -> parent may leave its ready callback
  -> parent enters its own native MTE cleanup
```

Every ready-loop terminal branch drains children: accepted close, finish,
original caller DOWN, and owned dependency failure. The barrier occurs BEFORE
infrastructure shutdown, replacement detection, own Repo shutdown, database DROP,
root removal, application/compiler restoration, and baseline Repo restart.

The parent sends a correlated close request and services a drain receive loop.
It MUST NOT block in generic `request(child, :close)`: that would prevent it
from acknowledging child completion. The drain loop services terminal receipts,
peer DOWN, invalid admission/release replies and ignored normal EXITs.

After its complete `with_owned_database` call returns, the child sends its
terminal cleanup outcome to its parent and waits for ACK before replying to a
normal close. Parent ready and draining loops both service that receipt.
An immediately opened next sibling therefore cannot race asynchronous detach.
Parent never waits for child ExUnit finish or retained-receipt process exit.
Registered children keep their original completion-only receipts for their own
callbacks. Unregistered children exit only after parent acknowledgment.

MTE needs no new hook: parents cannot admit a child before ready, and every
terminal ready-loop path drains before returning into MTE cleanup. An acquiring
owner therefore has no descendants; a partially acquired child can run existing
MTE cleanup and publish its terminal receipt afterwards. Exceptions in new
diagnostic checkpoints must be captured as failures and must not bypass drain.

Original live caller may close an ancestor synchronously, invalidating nested
fixture use; drain children first. A different live process cannot close/finish
an ancestor while its caller is alive and a child is active: return
`RelationshipError(reason: :not_owner)`. After caller DOWN, ExUnit cleanup may
join normally. Reject parent infrastructure startup with `:active_child`
while it must service child completion. Unnested behavior stays unchanged.

Aggregate descendant failures exactly once before own cleanup failures. A child
DOWN without terminal receipt is `unconfirmed_child_cleanup`, never success;
forbid subsequent admission and preserve foreign resources through existing
ownership checks. Parent loss during child ACK waiting is observable as
`unconfirmed_parent_acknowledgment`, not successful ordered cleanup.
These fixed failure markers may include exact private PID/reference correlation
in test receipts, not user content or public diagnostics.

Preserve an original child acquisition/callback kind, reason and stack when
cleanup also fails. Cleanup failure remains independently observable through
the child's retained callback and/or parent's accumulated completion receipt.
Do not replace a native RestoreVault error or retry flag. Repeated close/finish
reads the same terminal result without repeating destructive cleanup.

Monitor all peers and remove consumed monitors. No new timers, polling delays,
force cleanup, process scans, signals, or deadline extensions. This protocol has
no parent/child request cycle; it does not promise termination of permanently
hung native cleanup or of an unsupported arbitrary live non-helper parent.

## 5. Deterministic test checkpoints

Add these fixed test-only stages to the existing checkpoint mechanism:

```elixir
[:child_attach_requested, :child_attached, :release_requested,
 :waiting_for_child_cleanup, :owner_cleanup_begin, :owner_cleanup_completed,
 :child_cleanup_acknowledged]
```

Use exact private owner/parent/child PID and edge reference correlation in
checkpoint resource maps. Never print those maps. Existing public timing output
remains fixed stage/status atoms plus elapsed milliseconds only.
`:owner_cleanup_begin` is emitted only after descendant settlement and before
returning from the ready callback into MTE. A throwing observation is recorded
without bypassing that invariant.

New contracts use `async: false`, `@moduletag :integration`, actual MTE resources,
actual registered callbacks, exact monitors and token-held barriers released if
the controlling test dies. No sleep establishes ordering; a negative receive
window alone is not proof that a parent reached its wait.

Required groups:

- Normal child close, terminal ACK, immediate sibling admission, ancestor close.
- Shared nonnormal original caller death while a real child is held before DROP.
- Caller death during admission and two partial-acquisition stages
  (before allocation and after root creation/first Repo startup).
- Exact primary acquisition error, separately visible cleanup failure and child
  owned-Repo failure; failed descendant admission remains closed.
- Real registered completion receipts versus non-ExUnit child completion.
- Foreign actual caller, dead/closed/not-ready parent and second active child
  rejected before configuration mutation/allocation.
- Repeated close/on_exit does not repeat DROP, restore configuration again,
  consume a different callback's receipt, or lose the original failure.

Before parent cleanup begins, prove parked parent database/root/configuration
are intact. After both lifetimes settle, assert complete app/compiler/Runtime
baseline, own process termination, both database/root absences, and query
`current_database()` on every restored baseline Repo. Repo presence alone would
miss the reported stale configuration defect. Foreign identities stay alive.

For behavioral RED, a temporary additive `open_child` shim may delegate to the
unchanged unordered `open`. Add observation-only owner-cleanup begin/completed
checkpoints at the existing MTE callback return and complete MTE return boundaries.
The new ordering test must observe parent cleanup beginning before child terminal
completion, not merely missing API or compilation failure. Hold parent at that
before-cleanup observation, then release child to real native completion before
releasing parent. Intentional RED must not leave the fixture corrupt. Remove the
unordered shim during implementation; retain correctly placed observation stages.

## 6. Task11 composition

Add `task11_with_child_destination!(source, parent_owner, fun)` inside the new
Task11 fixture block. Keep old `with_destination/2` exact. The new wrapper uses
`open_child(parent_owner, migration_pool_size: 2)`, preserves closed-source,
distinct database, empty root, maintenance-only, exact Repo and closed-lifecycle
checks, and invokes the original callback once.

MTE owns all configuration restoration. Do not call caller-side
`restore_settings(saved)` after the child's terminal receipt; that would escape
the ordering guarantee. On ordinary return, compare exact captured configuration.
Preserve primary callback exceptions separately from cleanup failures.

In the sentinel test replace ONLY the failed and fresh nested destination
acquisitions, passing `sentinel.owner`. Source creation, sentinel acquisition,
real native faults, denial/retry, full successful RESTART, all snapshots,
original-byte/search checks, parking/reader behavior, timing markers, native
crypto/filesystem calls remain unchanged. The original case deadline stays
unchanged except the one case-local aggregate ExUnit watchdog in the reviewed
[sentinel budget amendment](2026-10-16-singularity-v0.2-phase-5-task11-sentinel-budget-design.md)
and [plan](../plans/2026-10-16-singularity-v0.2-phase-5-task11-sentinel-budget.md),
effective only after design SPEC -> NEW QUALITY and root source GO. This does not
amend any semantic assertion, native operation or other deadline; old60s FAILs
remain FAIL and no native latency repair is claimed.

## 7. Requalification and verdict

Run the new complete nested owner and unchanged complete legacy lifecycle owner.
Requalify affected NativeText owners and current Task11 complete four-owner
master, five-owner units and retained five-owner integration. Preserve exact seed
215378 / warnings-as-errors, concurrency, all other original timers and pinned
toolchain. Only the single reviewed aggregate watchdog exception above applies.
Also retain all other saga-plan prerequisite and independent restore gates.

All Native is root-owned, serialized and naturally terminated, with fresh safe
raw logs, complete EOF review, exact source seals and separate ordinary residual
checks. No agents run commands while Native is LIVE. Failure enters diagnosis;
do not weaken assertions, split the sentinel case, move its work into setup_all,
share cached sources, reduce native crypto/fsync, or fake a positive result.

Design review, behavioral RED, lifecycle GREEN, timeout qualification and whole
Phase5 acceptance are distinct. Internal saga Task12 independent oracle and all saga Task13
source SPEC -> new QUALITY / small local commits remain required. Task16 BOTH
strict ALL-leases remains UNSATISFIED / UNWAIVED / BLOCKED_DESIGN.
E2E remains NOT RUN under the user's restriction.
