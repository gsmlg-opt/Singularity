# Phase 5 Task16 Terminal Close Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development`
> or `executing-plans` task-by-task. Parent assigns exclusive writers and owns
> all validation windows; architecture author does not implement this plan.

**Goal:** Preserve idempotent authenticated close while terminating the actual
Writer owner before envelope deletion and acknowledging real cleanup.

**Architecture:** An admitted close transfers its reply to the existing
companion. The caller waits for exact owner/companion DOWN and the companion's
successful cleanup result. A later dead-owner close freshly authenticates a
no-op. Admitted entries/chunk errors use the same fixed terminal reply protocol.

**Tech Stack:** Existing Elixir/OTP tasks and monitors, OperationScope,
ArtifactDirectory, Writer and qualified native export-request leases.

---

## Preconditions and ownership

Read the complete [terminal-close design](../specs/2026-10-19-singularity-v0.2-phase-5-export-terminal-close-design.md),
original [Task16 plan](2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership.md),
[acyclic plan](2026-10-19-singularity-v0.2-phase-5-export-acyclic-composition.md)
and [companion recovery plan](2026-10-19-singularity-v0.2-phase-5-export-companion-recovery.md).
This is a narrow delta to original Step4; it does not replace their required
native, startup, attribution, source authority or acceptance checks.

Worktree `.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`, inspected HEAD
`8fb1142ee593641544769658d03a96cb83ebaa56`. Existing source/tests/config edits
belong to parent/Sol. No overlapping write ownership. Native prerequisite is
separately qualified at `6c7f867309470e23e8f34c06a8f53af0b496d48d`.

| Owner | Exact file and scope |
| --- | --- |
| Parent/test author before affected production author | `apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs`: additive close/authority/failure tests; preserve every original assertion. |
| Parent architecture-test author in separate window | `apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs`: additive close ordering/protocol counterproofs. |
| Existing Sol Artifact author after explicit parent GO | `apps/singularity_runtime/lib/singularity/runtime/knowledge/export_artifact.ex`: terminal close and bounded reply ownership only. |
| Parent | Full reads, exact candidate pins, DESIGN SPEC then NEW distinct QUALITY, all execution, source reviews, small AGENTS pointer and later scoped local commit. |

This architecture author writes only these two new documents. Do not change
Handle/public arities, Export work composition, native source, Writer,
ArtifactDirectory, startup/config, historical manifests or old docs for this
delta. Parent may continue unrelated already-authorized work in other files.
All affected normal-close source edits wait for reviewed design and additive
test-first evidence; unblocked initial implementation may continue separately.

## Task A: establish the terminal-close contract before source changes

- [ ] Parent fully reads both documents, obtains independent DESIGN SPEC then
  NEW distinct DESIGN QUALITY, and records their exact hashes. Add the small
  AGENTS pointer only under parent ownership. No automatic skill commit or
  renewed routine human approval is required.
- [ ] In the existing lifecycle owner, strengthen the idempotence case using
  its current helpers. Keep its original no-readable-data and sentinel checks.
  The concrete core below uses existing `generate_from_requester/1`, `export/3`,
  `authority_count/1`, `assert_cleaned/1` and `note_path/0` helpers:

```elixir
{handle, _requester} = generate_from_requester(c)
owner = handle.owner
owner_monitor = Process.monitor(owner)
[companion] = Task.Supervisor.children(c.supervisor) -- [owner]
companion_monitor = Process.monitor(companion)
[ledger] = owner_ledgers(owner)
assert Process.alive?(owner)
assert :ok = export(c, :close, [handle])
# No waiting or fixture cleanup may make these post-return assertions pass.
assert_received {:DOWN, ^owner_monitor, :process, ^owner, _}
assert_received {:DOWN, ^companion_monitor, :process, ^companion, :normal}
refute Process.alive?(owner)
assert :undefined = :ets.info(ledger)
assert_cleaned(c)
first = authority_count(c)
assert :ok = export(c, :close, [handle])
assert authority_count(c) > first
assert_cleaned(c)
assert {:error, %Error{}} = export(c, :entries, [handle, nil])
assert {:error, %Error{}} = export(c, :read_chunk, [handle, note_path(), 0])
```

  Because this caller itself owns the monitor before close, exact DOWN must
  already be queued when the successful call returns; no eventual polling is
  a substitute. Retain the independent actual filesystem assertion.
- [ ] Add a separate repeated-close case per existing authority mutation
  (session/principal/membership revocation, either epoch, capabilities, unlock).
  First close successfully, then mutate the existing synthetic authority state,
  require the same original denial code on another close and a fresh authority
  event. Preserve exact five-field foreign-session/Handle mismatch denial;
  test each field individually, wrong live operation ref and wrong deadline.
  Invalid live handles leave the original operation usable and cannot cancel it.
- [ ] For dead-owner close, place a test-owned sentinel under the isolated export
  root after successful cleanup, repeat close and denied/mismatched variants,
  and require unchanged inventory/bytes. A source contract must also prohibit
  filesystem/descriptor/restart calls in the dead-owner branch: sentinel survival
  alone cannot prove no filesystem access. Never pass a path through Handle.
- [ ] Add identity-conflict close using the existing isolated marker replacement
  pattern: require sanitized failure, exact owner termination, preserved foreign
  replacement and no `:ok` receipt. Add in-flight owner/companion-loss cases using
  existing trusted callback barriers or fixed control-message observation;
  preserve separate successful recovery evidence. An interrupted close must
  fail, even if later cleanup succeeds, and must not fall into dead-owner no-op.
  Parent's concrete minimum addition is three cases preserving all prior 22:
  actual owner/companion/ledger/root completion and repeated authentication;
  seven current-authority variants plus five-hint foreign denial; and genuine
  cleanup refusal using a mode-000 owned child. The last must first observe real
  `File.ls` EACCES (no skip), require `storage_unavailable` from the in-flight
  close, restore fixture permissions and inspect retained residue/sentinels,
  then require a later authorized no-op to leave that residue unchanged. Keep
  broader existing identity/failure tests intact. No fixture deletion may
  supply the asserted production cleanup result.
- [ ] In the composition contract owner, parse actual executable AST and require
  registered caller monitor, exact operation/call/owner/companion matches,
  original deadline, owner-DOWN-before-cleanup and cleanup-before-success. Add
  causal mutations for early `:ok`, DOWN-as-success, in-flight dead-no-op fallback,
  omitted native-error check, wrong monitor/reference/PID, retained live owner
  receipt, cleanup from Handle, refreshed deadline and third operation task.
  Each mutation must find its intended source node and fail the intended check;
  absent implementation is RED, never a skipped mutation.
- [ ] Parent runs both whole test owners with fresh candidate pins before the
  affected source changes. Preserve native41 and other original RED logs;
  distinguish missing implementation/compiler failure from causal contract RED.
  These synthetic lifecycle tests prove real files/ETS, not native custody or
  actual SQL COMMIT. Do not rename them as native proof.

## Task B: implement the reviewed reply handoff and qualify it

- [ ] Existing Sol Artifact author adds the exact protocol from the design in
  the current private owner/companion loops. The following transition table is
  the implementation contract; state field layout follows the actual current
  source and is not a new public struct or callable callback:

| Actor/input | Required transition |
| --- | --- |
| Caller before request | Monitor exact live owner; fresh reply ref; fix live-request branch. Initially confirmed dead owner uses only fresh native authentication plus five-hint equality. |
| Owner/authenticated close after COMMIT | Seal delivery; register one waiter with known companion; wait matching registration acknowledgement. |
| Companion/registration | Verify owner/ref; monitor caller; store only caller/ref/monitor plus original operation identity/deadline. |
| Owner/registration acknowledgement | Send exact `export_close_route` to caller, then request terminal cancellation; never enter a persistent closed-receipt loop. |
| Caller/route | Match request/owner/ref; monitor exact companion; send fixed `export_close_waiting`; wait for cleanup result, its own exact owner DOWN and normal companion DOWN in either order. |
| Companion/cancel or exact owner DOWN | Seal; signal known Writer cancellation; genuinely revoke known leases; stop/observe exact owner DOWN; identity-clean original envelope. Readiness is not a prerequisite for cleanup. |
| Companion/cleanup success and caller ready | Send exact `export_closed` success and exit. A pending content-free result may wait only until caller readiness/loss or original deadline. |
| Any native/error/unknown/identity failure | No successful receipt; sanitize; continue safe existing cleanup and retain residue honestly. |
| Admitted entries/chunk error | Register the original sanitized error code through the same fixed terminal protocol; return it only after completed cleanup and both DOWNs. Cleanup failure returns `storage_unavailable`. No plaintext reply. |
| Companion loss | Existing one-shot cleanup-only replacement, unchanged four-key context; no close success inferred from replacement or owner death. |

  Fixed message forms, identically in both documents:

```elixir
{:export_close_route, operation_ref, reply_ref, owner, companion}
{:export_close_waiting, operation_ref, reply_ref, caller}
{:export_closed, operation_ref, reply_ref, companion, :ok}
```

  Registration/cancellation use existing private messages extended with the
  bounded waiter where needed, with matching stored owner/ref. No new public
  operation, configured callback or arbitrary executable message is accepted.
  For admitted terminal errors, `export_closed` carries the fixed sanitized
  error result instead of `:ok`. The companion sends the result then exits
  normally; no subsequent caller acknowledgement or persistent receipt loop
  is needed. Unadmitted malformed/foreign requests never enter this path.
- [ ] Remove only the planned same-owner receipt behavior. Repeat close does
  not restart tasks, recover ETS, invoke filesystem code or renew TTL. Do not
  catch in-flight call exits as no-op success. Caller death/timeout removes reply
  ownership while cleanup proceeds; deadline cannot substitute for DOWN/native
  acknowledgement. Drop any content/work/runtime-authority references from
  post-cleanup acknowledgement state. Keep at most two live operation tasks.
- [ ] Close the source author. Parent reads complete changed source and diff,
  adds no unreviewed callback hooks, and runs the following whole owners inside
  its already-qualified private environment. These are payload commands, not
  authority to start another VM/service lane. Record exact argv, exit, counts,
  raw log hashes and each native invocation's immediate own residual check:

```sh
mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs --seed 215378 --warnings-as-errors
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs --seed 215378 --warnings-as-errors
mix test apps/singularity_storage/test/singularity/storage/knowledge_export/artifact_directory_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/writer_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/spool_test.exs --seed 215378 --warnings-as-errors
mix format --check-formatted
mix compile --warnings-as-errors
mix xref graph --format cycles --fail-above 0
git diff --check
```

- [ ] Retain and run all original Task16 Step8/acyclic/recovery/attribution gates
  required by the entire candidate. Genuine native ALL-leases assertions remain
  separately mandatory: late issuance after timeout, companion hard death before
  recording, pre-forward and known-forwarded cases, actual native read denial,
  ordinary/independent sentinels. Closed owner, absent root and primitive lease
  acceptance cannot substitute for these. Preserve original node-local startup
  serialization through actual supervisor registration/return.
- [ ] Record every required check PASS/FAIL/NOT RUN and exclusions; require zero
  failures for component acceptance. Native41 remains historical RED; newly
  passing checks do not rewrite it. Retain exact native56 inverses, original
  manifests, Task8/native-text layers, seven applications and unfiltered zero
  cycles. No baseline rebasing or unrelated frozen-source repair.
- [ ] Obtain independent source SPEC then NEW distinct source QUALITY on exact
  source/tests/log pins. Review the route-registration race, caller/owner DOWN
  ordering, real native errors, identity refusal, no in-flight no-op fallback,
  fixed deadlines, recovery separation and absence of a third watcher.
- [ ] Parent records reviewed changed paths and actual validation before any
  separately owned local commit. Complete Task16 only when all original
  applicable obligations pass; Phase5 still requires the full permitted README
  gate. E2E stays NOT RUN/manual-deferred. No publication, release, deployment
  or production-data action is included.

## EOF self-review and author evidence

Task A covers prospective normal/repeated/denied/failed close and ordering
counterproofs; Task B implements the bounded handoff and preserves every wider
gate. Public operations, Handle shape, five binding values and private message
forms agree with the design. The single superseded same-PID receipt requirement
is named; no cleanup or authentication obligation is silently removed.

Documentation inspection/self-review only. Implementation/Mix/SQL/native checks
above NOT RUN by this author. Parent's earlier failures remain failures and
pending independent design reviews remain pending. Received Sol production
counter 0; cumulative Astra implementation repair rounds 0, unchanged. No
implementation budget consumed or reset. No Vault feature work or old-file
edit by this author. Parent owns implementation GO and acceptance.
