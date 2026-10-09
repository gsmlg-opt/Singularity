# Document Runtime outcome/recovery integration verification

Date: 2026-10-09. Status: original exact-size C2 regressions, corrected 76-test
storage gate, Asset/application, unit/architecture and zero-cycle gates passed.
The bounded WorkerScope patch is applied and unchanged. Corrected 14-contract
lifecycle verification passed. After user-resumed Astra spec/quality reviews
passed, the bounded repair was accepted and committed locally at `ecb1703`.
Task 12 scoped source qualification is now accepted locally as recorded in the
final C6 closure below; Phase 2 and full release acceptance remain open.
C3 is accepted locally at working-tree test source `6263105…a3c9`:
all 64 integration contracts pass; independent Astra spec/quality review and
exact alias cleanup pass. C4 is now accepted locally at source `7322557…33bd4`:
all 75 cumulative integration contracts, independent Astra reviews and exact
cleanup pass. The four C5 missing-event failures were repaired through the
separately reviewed canonical-worker telemetry compatibility patch, accepted and
committed locally at `027b28b` after focused27 RED/GREEN and actual84 GREEN.
The PDF detector and outside-rescue subprocess-evidence assertions are applied;
focused20 and amended full84 pass with cleanup. Final full-C Astra spec/quality
reviews are clear; final formatted source is `b8c6f60…07e42`. Exact-final-byte
full84 passes with exact cleanup; C5 is accepted locally. All mandatory C6
regressions, unit/architecture, compile and zero-cycle checks now pass.
Parent accepts C1–C6 and authorizes the exact eight-file dependent local commit.
The original full plan remains byte-identical, untracked and excluded.
No Phase2 or release acceptance is claimed.
Earlier preparation/GO checkpoints are historical.

## Current state and previous-turn audit

The previous goal turn made concrete progress, not merely a wait: source
integration was committed at `5be1e515ef9315933aed4bd7c65dc2b6abc4ed23`,
independently spec/quality reviewed and tested on that exact commit (113 scoped
integration and 80 unit/architecture contracts, zero failures, 48 exclusions in
each mode, zero xref cycles). Evidence was committed at
`33e9bdae575f531f8f907a3a4157bf314feb99a8`.

Main rechecked current authoritative state: the Phase 2 worktree was clean at
`33e9bdae575f531f8f907a3a4157bf314feb99a8`, branch
`codex/v0.2-phase-2-import-extraction`, in the existing project-local linked
worktree. Root main was clean and unchanged at
`e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`. The C preparation worker was confirmed
live by the agent-status tool; it must not be restarted on an observation timeout.

The full release definition of done is not established: later search,
organization, attachments/citations, backup V3/backward restore/upgrade, browser
workflow and exact-source multi-architecture artifacts remain open. The goal
remains active; no completion or repeated-blocker claim is made.

## Ownership and preparation boundary

`document_runtime_c_plan` owns only the new complete-code C plan under
`docs/superpowers/plans/2026-10-09-singularity-v0.2-document-extraction-runtime-outcomes-integration.md`.
Main owns this evidence and any status corrections. The existing complete
2,191-line A/B test source remains frozen. C must cover all mandatory outcome,
recovery/retry/restore, post-claim deletion, exhaustion/retry/snooze, atomicity and
privacy contracts, not replace them with successful fakes. Main must personally
read the complete executable plan before explicit test GO. Production changes
would separately require a focused failing contract and bounded approval.

## Characterized source-cap and expiry boundaries

The released canonical source-size constraint permits only 0..67,108,864 bytes.
The initial source guard requires object/pin size equality; worker describe
independently rejects later object-size drift. Therefore a claimed canonical
Document over 64 MiB is not a valid fixture. Main independently inspected these
guards. The proposed plan must distinguish real maximum-size worker success,
canonical insertion rejection, actual adapter oversize rejection and descriptor
drift denial from mappings that cannot be reached by a valid canonical worker.
Existing assertions are not weakened to force an impossible persisted outcome.

Existing storage expiry fixtures disable a lifecycle trigger, which is prohibited
for C. The worker is preparing a real claim/deadline-derived bounded wait and
actual recovery race, with no trigger bypass, clock hook or arbitrary race sleep.
The complete code and timing assertions remain subject to main review; no C test
has yet run.

No E2E, schema/migration, Vault feature/compatibility patch, key/capability
semantics, generic retry/wake, public repository, merge, push, tag, release,
publication or deployment is authorized here. Borrowed services stay running.
Failed Sol production repair rounds: 0; Astra attempts: 0 (maximum 3 if required).
Successful harness corrections remain recorded separately: A accessor 1 and
B source-size fixture 1. The shared Mix slot is free; preparation needs no
duplicate B baseline.

## Required Asset/application integration baseline

While the C worker prepared the plan without code edits, main took the free
shared Mix slot and ran the mandatory scoped Asset/application regression command
from the A plan against source `5be1e51` (HEAD `33e9bda`, documentation-only above
that tested source):

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs --seed 1208
```

Exit 0, seed 1208: 113 reported, 65 unit exclusions, 48 integration executed,
0 failures. This explicitly executes the 17 historical Asset/application
integration contracts previously excluded from ordinary unit checks, together
with the 31 B contracts. It does not establish C behavior or Phase 2 acceptance.

Exact database `singularity_test_23caaf53ea4fea9b4368c6b1` and root
`/tmp/singularity/integration/23caaf53ea4fea9b4368c6b1` were independently checked
afterward: database count 0 and root absent, checks exit 0. All main-owned commands
finished and the Mix slot is released; borrowed services remain running. No
production/test edits, repairs or E2E occurred. This new scoped execution evidence
is current-turn progress toward the required regression gate, not a status-only
restatement of B.

## Privacy-path preparation evidence

Main inspected actual SafeSQL, repository defaults/configuration, observability
handlers and the installed Oban executor. SafeSQL forces `log: false` and
`telemetry_event: nil`; repository defaults suppress query telemetry and current
configuration suppresses SQL logs. These source observations are not privacy test
execution. C must capture actual Oban executor start/stop/exception events with
positive event controls, repository query events, bounded application events,
public errors, logs and persisted job/outbox/progress/audit surfaces. Unique owned
handlers must be detached. Direct calls to a telemetry handler cannot substitute
for real runner evidence; no observability expansion is authorized.

## Complete plan review and bounded test GO

The worker completed the 1,287-line five-block plan, SHA-256
`2ef915b3660bb3d7653eebe3cb732e046f1b6de418e9729dec2ab0d7f73bc817`.
Main personally read every executable block and the complete instructions/ledger,
then reviewed all final corrections. These include positive ordinary source and
fragment reads, retained successor causation, actual raw and bounded runner
telemetry, and full owner-scoped outbox/submission/progress/runner/audit metadata
canary inspection. No mandatory C contract was removed.

Worker preparation parsed/compiled all blocks in memory with ExUnit autorun
disabled, no compiler warnings: 24 outcome, 9 fence, 11 runner and 9 privacy tests,
53 registered in total. This is not test execution. Main independently confirmed
the final plan hash, unchanged frozen A/B test hash and clean tracked diff before
GO. No production failure or new repair attempt occurred.

Under standing approval, main issues **C TEST GO for C1/C2 only**: append the
reviewed support and 24 outcome contracts with `apply_patch`, preserving the
entire frozen 2,191-line prefix, then execute the focused integration file in the
worker's exclusive shared Mix slot. Expected integration count is 31 B + 24 C2;
actual results and exact isolated environment cleanup must be reported. Already
implemented behavior may pass immediately and must be called characterization,
not fabricated RED. Stop and retain any unexpected failure before a repair.

C3/C4/C5 execution remains held for the C2 handoff. No production repair,
acceptance, E2E, schema, Vault change, service interruption or external publication
is authorized. Main owns this evidence; the worker owns only the plan and approved
test append. The inherited escalation counters remain 0 failed Sol production
repairs and 0 Astra attempts, maximum 3 Astra attempts if required.

## First C1/C2 execution and narrow harness correction

The worker appended exactly the reviewed first two blocks: +599/-0, entire A/B
prefix unchanged. Test SHA-256 before correction:
`104b113f4875b98f1b7798b9c7aa32c786c8e8e932bd0444beaceff88f30623c`.
The focused integration command, seed 1208, finished exit 2: 98 reported,
43 unit exclusions, 55 integration attempted; 31 B passed and all 24 C2 cases
failed in setup before their behavioral assertions executed.

Main independently traced the sole reported setup mismatch: new `C.setup/1`
matched `{:ok, %{fixture: f}}`, whereas frozen `S.setup/1` returns
`{:ok, fixture: fixture}` (keyword list). Main approved only changing the new
pattern to `{:ok, fixture: f}` in the test append and owned plan, followed by the
same focused rerun. No assertion or production behavior changes. Full fixture
values in ExUnit's mismatch diagnostic are deliberately not reproduced here.

Worker verified exact database
`singularity_test_3105b229c7f523d45a85a2d5` count 0 and exact root
`/tmp/singularity/integration/3105b229c7f523d45a85a2d5` absent, then finished every
owned command and released the Mix slot. Main reassigned that slot for the narrow
correction/rerun. C3/C4/C5 remain held. This is C harness correction 1, separate
from 0 failed Sol production repair rounds and 0 Astra attempts. An earlier
relative `apply_patch` target was rejected without changing a file; using the
absolute assigned worktree path was a tooling correction, not a runtime repair.

Main independently repeated the failed-run checks: exact database count 0 and
exact storage root absent, both exit 0.

## C2 real checkout-lifetime failure after setup correction

The approved one-line setup correction was applied to the append and plan only.
Main independently proved that the entire frozen A/B file remains an exact
prefix and the append equals the corrected plan's first two blocks byte-for-byte.
Corrected test SHA-256:
`20598c663e6ecc57c655d48d32e5e32add3e9032c1827d8124361f4b9b838515`;
corrected plan SHA-256:
`350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.

The same focused integration command finished exit 2, seed 1208, in 148.6 seconds:
98 reported, 43 unit exclusions, 55 integration executed. All 31 B and 22 C2
contracts passed. The exact 64 MiB authenticated source and exact 16 MiB
normalized output cases failed during real processing, not fixture setup.
DBConnection's disconnect diagnostic reports checkout longer than 15,000 ms;
sampled stacks were actual Text NFC normalization and DocumentCompletion fragment
validation. Cleanup then raised DBConnection.ConnectionError in the existing
shared advisory-lock release path. No assertion, timeout or production code was
changed after this failure.

Main traced WorkerScope's shared path to VaultLock's default `repo.checkout/1`;
the installed Ecto/DBConnection source supplies a 15,000 ms default and current
WorkerRepo configuration does not override it. This source trace is diagnosis,
not a verified repair. A fresh Astra worker has a read-only **project architecture**
assignment for a finite Document-only checkout lifetime preserving short SQL
timeouts, immutable canonical deadlines, existing authorization and unchanged
non-Document behavior. No VaultLock/Vault semantics change, global timeout,
generic retry/wake change or test-only timeout workaround is authorized.
Production repair GO remains held for the concrete design.

Worker verified exact database
`singularity_test_67e63763079ec63a0ffc8920` count 0 and exact root
`/tmp/singularity/integration/67e63763079ec63a0ffc8920` absent, then released the
Mix slot with all owned commands finished. Main independently repeated both
checks: database count 0 and root absent, exit 0. C3/C4/C5 remain held; C2's
required failing assertions remain intact.
Counters: C harness corrections 1, failed Sol production repairs 0, Astra
production repair attempts 0; fresh Astra architecture assessment 1 in progress.

The Astra assessment identified that a larger outer checkout alone would also
loosen effective SQL timing: installed DBConnection reuses the checked-out
connection without a new inner timer and Postgrex's extended-query receive is
unbounded within it. No production server statement timeout is configured.
Therefore bare timeout widening is not approved; the design must independently
preserve bounded SQL execution. This is an architecture finding, not a repair.

Separately, before later C3 GO, main identified a test-isolation risk: the
integration alias explicitly enables runtime infrastructure, including the
automatic ExtractionReconciler, regardless of ordinary test configuration.
C3's real deadline/manual concurrent recovery must not depend on the global
scanner's phase. No C3 test or service state has changed; any isolation amendment
requires explicit bounded review and cannot interrupt borrowed services.

## Accepted repair architecture and next executable-plan boundary

The fresh Astra read-only architecture assessment completed successfully without
edits or execution. Main read the full handoff and adopted the finite Document-only
300,000 ms checkout, independent local SQL cap, strict prior-setting preservation,
nested-checkout rejection and exceptional borrower self-termination if restoration
cannot be verified. The client/network versus server SQL timing distinction is
explicitly accepted. The design was self-reviewed and committed locally at
`273322d` in
`docs/superpowers/specs/2026-10-09-singularity-v0.2-document-worker-checkout-lifetime-design.md`.
Only that new design was staged; all existing dirty files were preserved.

Fresh Sol delegation and reuse of the prior Sol thread both returned agent-thread
capacity errors after the completed Astra assessment. No worker was restarted or
misused for routine work. Main therefore owns repair-plan preparation directly in
`docs/superpowers/plans/2026-10-09-singularity-v0.2-document-worker-checkout-lifetime.md`.
That document is explicitly an incomplete preparation draft, not test/production
GO. The scope remains one proposed production file and one new focused test file;
the actual failing Runtime tests are unchanged. No user clarification is needed
and no blocked-goal claim is made because main can continue meaningful work.

The architecture adds mandatory actual-role lifetime/setting/backend/lock cleanup
contracts, including one real 300-second expiry. Those and the complete executable
patch must be personally reviewed before GO. Failed production repair counters
remain Sol 0, Astra 0; successful Astra architecture assessment 1. No E2E or Vault
feature/compatibility patch occurred. Main independently rechecked root main clean
at `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`; no commands remain running.

## Checkout repair focused test GO

Main completed and personally read the entire executable repair plan, including
the 14 actual-role contracts, minimal WorkerScope additions, finite commands,
cleanup and review gates. All four Elixir blocks parse; in-memory compilation
registered 14 tests without warnings. This preparation did not execute tests or
start a database. Main issues bounded GO to create only the new Storage test file
and run focused RED. Production remains unchanged/held for expected RED; C2's
frozen Runtime assertions and all A/B code remain unchanged. Agent capacity still
prevents fresh Sol delegation; main continues direct work, not a blocked claim.
Counters remain failed Sol production repairs 0 and Astra production attempts 0.

## Focused baseline invalidated private dynamic-pool isolation

The focused Storage command (seed 1208) finished exit 2 in 42.3 seconds: 14 tests,
14 failures. No production change had been made. Unlike Repo.checkout, raw
Ecto.Adapters.SQL.query!(WorkerRepo) resolves Ecto.Adapter.lookup_meta(WorkerRepo)
directly rather than WorkerRepo.get_dynamic_repo(). Installed lookup_meta docs
explicitly require the caller to supply the dynamic repo. Consequently the
new harness's settings/locks were not on its owned checkout, and later fixtures
observed altered settings on named-pool backends. This is not accepted production
RED and not a dependency defect. No assertion was weakened or SafeSQL changed.

Main requested a separate read-only Astra recovery assessment with explicit
astra_gate=SOL_IMPASSE, retaining the one-file production boundary and frozen
Runtime assertions. Production attempts remain Sol 0 / Astra 0; failed harness
isolation designs 1. The failed baseline's exact database is
`singularity_test_6ec14ecc5b909bfa37f7ff5a`, root
`/tmp/singularity/integration/6ec14ecc5b909bfa37f7ff5a`.
The original C2 checkout defect remains the required production repair target.

Main independently confirmed this failed run's exact database count 0 and exact
root absent after completion (both exit 0). Borrowed services remain running.
A fresh independent Sol review spawn again failed with agent thread limit; no
review is claimed and the architecture/recovery Astra thread is not repurposed
for routine review. No owned command remains running.

## Astra recovery amendment and corrected baseline GO

The separate SOL_IMPASSE read-only assessment completed. Main read its full
replacement recipe and corrected only the new test and owned plan/design docs:
named WorkerRepo, exact-PID bounded selection, original-setting cleanup and
separate monitored observer processes. No dynamic support, pool restart,
saturation or production edit. Three orchestration tags changed to 60 seconds;
all enforced SQL, callback and five-minute deadlines/assertions are unchanged.
Main personally inspected the helper/callsite delta and warning-free in-memory
compilation registered all 14 contracts. This is preparation, not test success.
Corrected focused baseline GO is issued; production remains held for valid RED.
Successful Astra architecture assessments 1 and recovery assessments 1;
production attempts remain Sol 0 / Astra 0, harness isolation corrections 1.

Corrected named-pool baseline completed exit 2 in 58.4 seconds: 14/14 failures.
Most failures now reach the expected absent cap or nested rejection, and stricter
75 ms / non-Document bodies characterize correctly. Their cleanup exhausted
selection because the observer consumed a checkout on every selection iteration,
allowing FIFO phase-lock; one later fixture observed the un-restored 75 ms value.
This is retained as a separate harness cleanup failure, not accepted full RED.
The same Astra recovery task traced installed oldest-holder selection and supplied
the surgical correction: probe existence once before exact-backend selection,
then retain every same-backend restoration assertion. Main reviewed/applied only
that helper in the test and mirrored plan. No fallback on mid-selection death,
arbitrary session reset or production edit. Exact failed environment:
`singularity_test_31c11e6203a0d0c5366469d9` and
`/tmp/singularity/integration/31c11e6203a0d0c5366469d9`.
Production counters remain 0/0; harness cleanup corrections 1. Corrected baseline
GO remains in effect.

## Valid focused RED and scoped production GO

The third focused baseline (same exact command/seed 1208) completed exit 2 in
57.2 seconds: 14 tests, 12 failures. Stricter 75 ms SQL cancellation and unchanged
non-Document 15-second expiry passed, including cleanup. Remaining failures reach
missing Document statement cap, nested callback rejection, or original checkout
expiry; there were no fixture/selection/cleanup failures. Main accepts this as
focused RED. The two original C2 size failures remain frozen independently.
Main verified the second failed baseline database/root absent, and verified this
third baseline database `singularity_test_d931407b245f2126fa1d06be` count 0 and root
`/tmp/singularity/integration/d931407b245f2126fa1d06be` absent. All owned commands
finished; borrowed services remain running.

Main issues scoped production GO for exactly the reviewed Task 2 WorkerScope
additions: Document-only fresh 300-second checkout, saved/minimum 15-second SQL
cap, nested rejection and fail-closed restoration. No other production file,
assertion, canonical deadline, Vault behavior or configuration change is allowed.
Production verification is next; no successful repair/phase acceptance is claimed.

Verification command partition amendment: execute the focused 14 contracts once
(including actual five-minute expiry), frozen Runtime 55 once, remaining storage
repository/authority separately, and additional Asset/application 17 separately.
Every previously required assertion still runs on unchanged source; no tag,
exclusion, timeout override or test assertion is removed. This avoids duplicate
long-duration executions while preserving all scoped gates. Unit/architecture
and zero-cycle commands remain unchanged. Independent reviews remain required.

Conservative user-limit accounting: although no Astra production patch has been
attempted, count Astra's first named-pool cleanup recipe (which exhausted
selection) as one unsuccessful repair recommendation toward the user's overall
three-failure maximum. Thus Astra failures overall 1/3, production failures 0;
do not treat the earlier production-only counter as three additional failures
of authority. The subsequent surgical cleanup correction established valid RED.

## Focused production verification passed

The first production repair's exact focused command (seed 1208) completed exit 0
in 354.6 seconds: **14 tests, zero failures**. This includes actual >15-second
same-backend/lock holding, 15-second SQL cancellation, stricter 75 ms cap, all five
restoration outcomes, borrower death, self-owned backend loss/restoration kill,
nested rejection, unchanged non-Document 15-second expiry and actual 300-second
outer expiry with committed positive-control write and no late mutation. Expected
connection-death diagnostics belong to those explicit lifecycle tests, not test
failures. No timeout hook, production backend signalling, fake cleanup or skip.

Main independently confirmed database
`singularity_test_72bf69f29ed9dfa6d08e75b4` count 0 and root
`/tmp/singularity/integration/72bf69f29ed9dfa6d08e75b4` absent. Borrowed services
remain running. Tested SHA-256: WorkerScope
`d772ca0aa33603233bf40ff521d0a17a5b931114d517c1103f0bd49426168a88`;
new Storage test `45372d239e327c4f6b5500a97af6960faab8203a1c77dae34cd74ebd2aebb028`.
Frozen Runtime SHA and A/B prefix remain unchanged. Production failures Sol 0,
Astra 0; Astra unsuccessful recommendations overall 1/3. Next: unchanged C2
exact-size/full-file regressions, remaining scoped gates and independent reviews.

## Original C2 failures repaired on unchanged assertions

The exact frozen Runtime integration command completed exit 0 in 173.1 seconds,
seed 1208: **98 reported, 43 excluded, 55 integration executed, zero failures**.
All 31 B and 24 C2 contracts passed, including the previously failing exact
64 MiB authenticated source and exact 16 MiB normalized output. No Runtime test
line or production extraction/custody/canonical deadline changed for this repair.
Main independently confirmed database `singularity_test_d79bd82c171d83fc7d3cd169`
count 0 and root `/tmp/singularity/integration/d79bd82c171d83fc7d3cd169` absent.

A fresh independent Sol spec reviewer read the complete production diff, test
file and accepted design/plan and found no concrete spec/safety deviations.
It verified the WorkerScope hash and unchanged common paths, auth/ScopedRepo,
canonical deadlines and Vault boundaries without running tests or editing files.
A separate fresh Sol quality reviewer is now running read-only. Earlier agent
capacity errors are resolved, not a continuing blocker. Remaining storage,
Asset/application, unit/architecture and zero-cycle gates remain pending.

## Required storage regression failure: acceptance stopped

The remaining storage repository/authorization command completed exit 2 in
17.0 seconds, seed 1208: **76 tests, 46 failures**. First failure: existing
`Document progress concurrent creation serializes and retains the first generic
checkpoint`, line 1727, failed `await_progress_lock_wait` at line 1746. Subsequent
failures largely cascade through existing Fixtures.with_owner/1 reporting the
MigrationRepo already started. No frozen assertion or fixture has been changed.
This required gate prevents repair acceptance/commit despite the 14 lifecycle
and 55 Runtime contracts passing. No unrelated repair or gate reclassification.

Exact failed environment: `singularity_test_003d5076496d785a89332566`, root
`/tmp/singularity/integration/003d5076496d785a89332566`. Main independently checked
database count 0 and root absent. Borrowed services remain running; no owned Mix
command remains. Main is escalating the concrete failure to Astra under the
user's instruction, with at most two further unsuccessful Astra repairs within
the conservative 1/3 overall count. Determine relation to the one-file patch
before any proposed correction; scope cannot silently expand.

Main source trace: existing progress_task/4 opens WorkerRepo.checkout, captures a
backend, then calls Document WorkerScope. The accepted fresh-only contract now
rejects that nested entry before progress SQL, explaining absence of a lock wait.
Astra received a bounded SOL_IMPASSE recovery assignment to validate and supply
the minimal test-helper correction. Production nested rejection must not relax.

Independent quality review found one Important test-proof gap: after callback
return the lock observer may reborrow f.backend; session-reentrant advisory locks
could then mask a shared-lock leak. The observer must explicitly exclude that
backend as well as any active borrower. The earlier 14-green run is retained,
but its post-return lock-release proof is not accepted until this gap is fixed
and the complete 14-contract file is rerun, including actual five-minute expiry.
No production defect was found by either independent reviewer. No test edits
have yet been made for either finding; Astra advice and scoped amendment pending.

Independent unaffected Asset/application checks continued without evading the
held storage/quality gate: the partitioned four-file command completed exit 0
in 4.7 seconds, seed 1208, **39 reported / 22 excluded / 17 integration executed,
zero failures**. Main independently confirmed database
`singularity_test_e0643a92bf1e0b1c0fb2a05b` count 0 and root
`/tmp/singularity/integration/e0643a92bf1e0b1c0fb2a05b` absent. Together with the
separate frozen Runtime run this is 72 integration executions, not repair/phase
acceptance. The production hash and frozen Runtime test remain unchanged.

Main personally read Astra's complete test-only correction recipe. Production
remains unchanged. Scope amendment GO is limited to new-test locks!/2 and existing
repository test progress_task/4, authority-blocker PID notification, one bounded
pg_blocking_pids observer and authority-test orchestration. Preserve all prior
assertions; tie the observed worker waiter to the exact owned blocker and pin
that PID to the eventual callback. No shared-fixture repair, production nested
allowance, grants, migration, timeout override or assertion weakening. Apply the
recipe then rerun required 76 and complete 14 contracts; quality/spec re-review
must cover the corrected test proof. Conservative Astra failures remain 1/3.

Main applied and inspected the full bounded Astra recipe and formatted only the
two Storage test files. Production remains hash-identical. Repository diff is
limited to the accepted helper/authority observation amendment; no assertion or
shared fixture was weakened. New focused test hash is
`ccefe6d62a09a5eeada0a0d281a3d72e67690813ccf404e663b71412ba10dbcb`;
repository test hash `4e568166382c492f14e95c7b6c4ad6a5b8ff218fc661c2732440dce856d2fc13`.
Fresh re-review was requested but temporarily hit agent capacity again; no
approval is claimed until reviewers actually resume and read the deltas.

The scoped unit/architecture command completed exit 0: Runtime 137 reported,
72 integration exclusions, 65 executed; Web architecture 15 executed; **80 total,
zero failures**. These test-only corrections do not change that gate's selected
sources. `mix xref graph --format cycles --fail-above 0` completed exit 0 with
**No cycles found**. Seven-application graph and frozen Runtime source remain
unchanged. Required corrected storage/focused execution still pending.

## Corrected storage regression gate passed

The exact same 76-test storage command/seed 1208 completed exit 0 in 24.5 seconds:
**76 tests, zero failures**. Submission serialization, terminal-row reload and
authority refresh all retain actual lock-wait proofs; the authority callback PID
matches the uniquely observed worker blocked by the test-owned blocker. The
earlier fixture cascade did not recur. No production/shared-fixture change.
Main independently confirmed database `singularity_test_950a0ebc8cfb3315a527c73e`
count 0 and root `/tmp/singularity/integration/950a0ebc8cfb3315a527c73e` absent.
Corrected focused 14-contract execution is next; independent re-review remains
required. No commit/acceptance until both pass. Astra overall failures remain 1/3.

## Final lifecycle rerun and review-capacity checkpoint

The unchanged focused command/seed 1208 allocated database
`singularity_test_652503b87f99f3ce5c07727f` and root
`/tmp/singularity/integration/652503b87f99f3ce5c07727f`. It executes the corrected
observer, including actual 300,000 ms expiry without a timeout override. At
18:20:28 UTC the real checkout expired; the late-mutation/backend-cleanup contract
then passed. Full command completion and independent environment cleanup are
still required; individual dots are not full-file acceptance.

Main inspected the complete production/test changes, confirmed the first Elixir
plan block exactly matches the actual new Storage test, and reconfirmed the frozen
Runtime SHA and byte-identical 2,191-line prefix. Root main remains clean at
`e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`; worktree HEAD remains `273322d`.
Production diff since `d5ea128` is solely WorkerScope (+73/-0); existing repository
test compatibility diff is +46/-6. No Vault file, migration, dependency, grants,
custody, generic worker or global configuration changes occurred in this repair.

Fresh eligible Sol spec/quality re-review requests remain rejected by agent
thread capacity. Completed Astra architecture/recovery threads are not eligible
routine reviewers and were not repurposed. Main's inspection does not substitute
for the accepted independent review gate. Hold local commit and C3–C5 until that
gate clears; no merge, push, release, deployment or Phase 2 acceptance. This is
not another repair failure; conservative Astra unsuccessful recommendations
remain 1/3, with at most two further failures permitted.

### Final corrected lifecycle result

The complete corrected 14-contract command exited 0: **14 tests, zero failures,
353.0 seconds**, seed 1208. Actual 300-second Document expiry, unchanged
15-second non-Document expiry, real server cancellation, restoration and
non-reentrant lock-release observations all executed. No assertion was skipped,
weakened or reclassified. Expected connection-expiry/backend-loss diagnostics
were followed by passing cleanup assertions, not treated as unexpected failures.

Independent exact cleanup commands:

```sh
psql -X -h /run/user/1000/devenv-afa1eb9/postgres -p 5432 -d postgres -Atqc "SELECT count(*) FROM pg_catalog.pg_database WHERE datname='singularity_test_652503b87f99f3ce5c07727f'"
test ! -e /tmp/singularity/integration/652503b87f99f3ce5c07727f
git diff --check
```

Actual results: database count `0`, root absence exit 0, diff check exit 0.
An initial read-only cleanup query used root main's inactive socket and failed
to connect; main then resolved this worktree's configured borrowed socket above
and verified absence there. No database cleanup or service mutation was needed.

Final tested SHA-256 values remain WorkerScope `d772ca0aa33603233bf40ff521d0a17a5b931114d517c1103f0bd49426168a88`,
focused Storage test `ccefe6d62a09a5eeada0a0d281a3d72e67690813ccf404e663b71412ba10dbcb`,
existing repository test `4e568166382c492f14e95c7b6c4ad6a5b8ff218fc661c2732440dce856d2fc13`,
frozen Runtime test `20598c663e6ecc57c655d48d32e5e32add3e9032c1827d8124361f4b9b838515`.
No owned command remains. All scoped execution gates are green; the final fresh
Sol re-review request again failed with agent thread limit reached. Consequently
no local commit or repair acceptance is claimed. Preserve the reviewed source,
all evidence and frozen C2/C-plan edits for the next eligible independent review.
Task 12, C3–C5, Phase 2 and the full release remain open. No E2E or Vault feature
work occurred. Astra unsuccessful recommendations remain 1/3; no further retry
was needed after the successful test-only correction.

### Goal continuation: review blocker revalidated

Previous turn classification: progress, because the corrected 14-contract run
completed and its exact isolated database/root cleanup was independently proved.
This continuation revalidated HEAD `273322d`, all four tested source hashes,
the linked worktree and a clean diff check; no tested source changed. A fresh
eligible Sol spec reviewer spawn again returned `agent thread limit reached`.
The authoritative live-agent list contains only root and two completed
architecture-only Astra threads; no eligible review process is running or being
waited on. Do not substitute either architecture thread or main for the required
independent Sol re-review.

The complete master release plan was reread. Its phase ordering and this repair's
accepted Task 4 gate prohibit C3–C5 before repair acceptance, and later product
phases require separate accepted designs/plans. No independent authorized
implementation task bypasses the current gate. Full release completion remains
unproven; the goal stays active. This is the second consecutive goal turn with
the same reviewer-capacity blocker, not a new code failure or verified process
wait. Acceptance/commit remain held pending eligible reviewer capacity.

### Third consecutive review-capacity blocker audit

Previous continuation classification: no progress, not a verified wait. Current
HEAD and all four tested source hashes are unchanged, and `git diff --check`
passes. A fresh eligible Sol spec spawn and a follow-up to the original Sol
quality reviewer both again returned `agent thread limit reached`; neither
created/resumed a review process. No new code defect or Astra repair failure.

The same independent-review capacity condition has now prevented acceptance for
three consecutive goal turns. No authorized independent implementation remains
that avoids this accepted prerequisite. Mark the full release goal blocked,
not complete or voluntarily paused, pending restored eligible reviewer capacity.
Resume with independent spec/quality amendment review, then bounded repair commit
and exact-source verification before C3–C5. All tested edits/evidence remain
preserved and uncommitted. No E2E, publication, service mutation or Vault feature
work occurred. Astra unsuccessful recommendations remain 1/3.

### User-resumed Astra review

User explicitly requested restore/continue using Astra and allowed at least
three failed Astra repair rounds. The goal tool confirms status active. The
worktree remains at `273322d`, all four tested source hashes match the final
green evidence above, root main is clean, and `git diff --check` passes.

A fresh independent Astra-model spec reviewer successfully started as
`checkout_astra_spec_review`, in a new read-only context. It is not the prior
architecture/recovery thread and has no edit/Mix/service authority. The accepted
gate remains independent spec followed by quality review; only the reviewer
model is amended under the explicit user instruction. Review success is not
claimed until actual findings return and main verifies them. The former capacity
blocker is resolved for this reviewer. Keep historical unsuccessful Astra
recommendations (1) and resumed failed implementation rounds (0) distinct;
at least three resumed failures are allowed, not counted from capacity errors.
No tested source changed, and no E2E/publication/Vault work is authorized here.

The fresh Astra spec reviewer completed its full read-only review with no spec,
scope or proof violations. It checked the complete design/plan, production branch,
all 14 contracts and repository amendment, including exact blocker/waiter identity
and the non-reentrant observer. Source hashes matched. A separate fresh
`checkout_astra_quality_review` context then started; quality acceptance remains
pending its actual report.

Fresh main-owned verification on resumed source, seed 1208:

- The same storage/authorization integration command above: exit 0, 76 tests,
  zero failures, 30.6 seconds. Database `singularity_test_18e45617dfd3b27a78bae981`
  count 0 and root `/tmp/singularity/integration/18e45617dfd3b27a78bae981` absent,
  independently checked with this worktree's configured PostgreSQL socket.
- `mix format --check-formatted` for WorkerScope and the two Storage test files:
  exit 0; no rewrite occurred.
- The same six-file scoped unit/architecture command above: exit 0. Runtime
  137 reported / 72 excluded / 65 executed in 34.1 seconds; Web 15 executed
  in 0.6 seconds; 80 total executions, zero failures.
- Complete plan test block matches the actual focused Storage test exactly.
  Frozen Runtime's 2,191-line prefix SHA remains
  `373ad3d5fcfdd07ae522f00a037caa6efabbfba5f060c6c9685fb7d71da14178`.

The earlier corrected 14-contract/55-Runtime/17-Asset runs remain exact-source
evidence because none of their production/test source hashes changed. The
five-minute cutoff is not shortened or excluded; no duplicate execution is
claimed. Local commit remains held until independent quality review clears.

Fresh xref completed exit 0 with `No cycles found`; the seven-application graph
is unchanged. The independent Astra quality reviewer then completed: no Critical
or Important findings, original observer-reentrancy finding resolved, ready for
a bounded local repair commit after successful parent verification. It checked
the actual production/helper/observer source, installed borrower-death path and
all four hashes; it made no edits or Mix/service operations. The connection-loss
test's bounded proof and separately accepted source reasoning for still-live
reset failure remain explicitly distinguished. Both reviews grant only repair
acceptance, not Task 12/Phase 2/release acceptance.

Main's final diff/source inspection and resumed verification are complete.
Issue bounded local commit GO for WorkerScope, its new focused contract file and
the smallest existing repository-test compatibility amendment only. Preserve
the unfinished Runtime C2 append and untracked full C plan. Follow with a separate
documentation/evidence commit identifying the exact tested source blobs. No
merge, push, release, E2E, deployment or Vault feature work.

### Bounded repair accepted and committed locally

Source commit: `ecb170349ae3ca021e8fe0ca194d4a9b73dfa738`
(`fix(storage): bound document checkout and preserve short SQL limits`).
Exactly three files: WorkerScope (+73/-0), new focused Storage contract file
(802 lines), existing repository test compatibility amendment (+46/-6). No
migrations, dependencies, grants, Vault files or other production files changed.

After commit, main ran `git show HEAD:<path> | sha256sum` for each of these three
files. All match the recorded green WorkerScope/focused-test/repository-test
hashes exactly. `git diff --exit-code HEAD -- <three paths>` and
`git diff --check` both pass. This is exact committed-blob identity verification
against executed gates, not a claim that the tests were re-executed after commit.
All main-owned commands are terminal. Root main remains untouched; borrowed
services remain running. No E2E or external publication occurred.

The original Runtime C2 append and full C plan remain unfinished, separately
preserved working-tree work at their frozen hashes; they were not staged into
this repair commit. Their successful 55-contract integration execution is working-
tree evidence on the identical production blob, not clean full-phase acceptance.
The bounded checkout prerequisite is now accepted. Next authorized work is C3's
separately reviewed test-only reconciler-isolation plan, then C3–C5 contracts.
Task 12, Phase 2 and all later release requirements remain open. Historical Astra
unsuccessful recommendations remain 1; resumed failed implementation rounds 0.

## C3 full-suite isolation preparation

Previous goal turn made concrete progress: independent Astra spec/quality reviews
cleared the checkout prerequisite, fresh scoped gates passed and source/evidence
were committed at `ecb1703` / `caf80fd`. Current HEAD is
`caf80fd4a1e71bc8b4253fbd058980c0be4a8275`; root main remains clean at `e866990`.
The Runtime file remains frozen at SHA-256
`20598c663e6ecc57c655d48d32e5e32add3e9032c1827d8124361f4b9b838515` and full C
plan at `350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.
Main reread the complete 1,287-line C plan and relevant actual composition and
fixture source. No C3 test or production edit has been made; no Mix/DB command
is running.

Fresh Astra test-harness architecture assessment is active under explicit
`PROJECT_ARCHITECTURE` / architecture mode. Evidence changes the next action:
the integration alias starts the real application reconciler, whose 30-second
timer races C3's real 180-second expiry; serial fixtures do not delete canonical
rows between tests. C2's final SQL-fault pair intentionally leaves extracting
attempts. Complete storage tests also leave tombstoned extracting attempts,
which real recovery intentionally excludes. Suspension alone therefore does not
establish C3's exact global recovery count, and requiring no extracting rows
globally would incorrectly reject valid ineligible history.

Parent rejects a filtered-only expiry invocation as the final solution: the
complete unfiltered README integration gate must also execute this contract.
Recommended bounded test-only direction: verify alias/child ownership, arm exact
PID resume before acknowledged suspension, settle pre-existing attempts using
actual database deadlines and unchanged real recovery, prove the eligible list
empty, retain an exact unchanged residual ledger for ineligible attempts, then
create the C3 target fixture. Preserve every original target assertion, including
the two actual concurrent scanner results `[{ :ok, 0 }, { :ok, 1 }]`, one successor,
generation fences and actual deadline. Added orchestration headroom is not a
shortened deadline. The complete exact helper/cleanup plan still requires main's
personal read and independent review before C3 TEST GO.

No global config, production timer/API, clock/trigger/timestamp, Vault/custody,
grant, shared fixture or borrowed devenv/PostgreSQL service changes are allowed.
No fake successful worker/recovery result, exclusion, assertion weakening or
new production repair is authorized. Historical Astra unsuccessful advice 1;
resumed failed implementation rounds 0; current architecture findings are not
failed implementation attempts. C4/C5, Task 12 and Phase 2 remain held.

### C3 architecture reviewed; append-only TEST GO

Astra completed the test-harness architecture without edits or execution. Parent
wrote and personally read the complete C3 isolation design/executable amendment
and original nine-contract C3 module. Independent Astra spec review identified
one Important plan defect: proposed SQL used worker-result alias column names.
Parent corrected them to physical `extraction_adapter` / `extraction_format` and
reviewer verified the correction against schema and `S.attempt_rows/1`. Final
review reports no unresolved Critical/Important findings. No implementation or
test attempt had occurred, so resumed failed implementation rounds remain zero.

Parent grants append-only C3 TEST GO: new module only, frozen 2,790-line prefix,
all original assertions, actual 180-second database deadline, captured-PID
cleanup, and unfiltered cumulative integration. Failure-path harness and actual
execution remain required for acceptance. Astra is preparing exact disposable
lifecycle probes while a separately owned Astra implementation may append the
reviewed code. Parent alone owns Mix/database execution and this evidence.
Production remains frozen; C4/C5, Task 12 and Phase 2 acceptance remain pending.

### C3 append and disposable probe preflight

Astra appended the complete nine-contract C3 module and exact reviewed isolation
amendment. Parent personally read every appended line, mechanically formatted
only that new segment, then verified syntax/format and the unchanged frozen
2,790-line prefix hash. Pre-execution full-file SHA-256:
`1ba971836c19a1ce60fdd5fa5fdec5fcdcb4e1d996f390d4c691b4bd18bb3fb2`.
No earlier source or production file changed.

The complete disposable failure driver is recorded in the C3 amendment plan.
Independent Astra preflight found quoted alias hygiene and a task-scheduling
elapsed-baseline race; parent corrected both before execution and re-review
cleared all findings. The driver executes the actual helper AST and callback,
separately records callback/observer success, and requires exactly four intended
failures. This avoids ExUnit masking a cleanup failure behind a failed test.

The first launch exited 1 before allocating any database: `mix run` preserved a
literal `--` in script arguments. Parent removed only that CLI separator and
corrected the recorded command. The second invocation allocated
`singularity_test_ec516b438b2e7f8a567f8153` and began the real 200-second timeout
branch. It also found an unexpected C3 helper failure before fixture creation:
`Oban.config/0` looks up default `Oban`, but this application uses
`Singularity.Oban`. Astra independently traced config, application composition,
adapter merge and installed API, recommending only the named lookup in new C3
code. Source stays frozen until this invocation terminates; its actual results
and cleanup remain pending. The governing plan is corrected, not production.

Intentional injected failures are not repair failures. This is the first C3
unexpected diagnostic failure, with test-only repair round 1 pending execution;
resumed unsuccessful Astra production repair rounds remain 0. The user's
allowance for at least three failed Astra repair rounds remains available.
The source commit is deferred until complete C1–C5 acceptance: C3 depends on
preserved uncommitted C1/C2 support and must not form a broken standalone commit.

The second invocation finished outer exit 1 after exercising the real settling
timeout: fixture/death scenarios failed admission on the wrong Oban lookup,
which the strict driver rejected instead of reporting PASS. Exact allocated
database count is independently 0; exact storage root is absent, both checks
exit 0. Test source SHA remained `1ba9718…3fb2` through the whole invocation.
Main grants Astra only the diagnosed one-line new-helper correction and a full
four-scenario rerun. No production repair or assertion change is authorized.

### C3 cleanup verified; unfiltered gate running

Astra applied exactly `Oban.config(Singularity.Oban)` in the new helper. Full
source SHA is now
`9a043a7979d22e173bb8fbe82b5218c4d5976076cde7dedb2bb900835ecbfe4e`;
frozen-prefix SHA remains unchanged. Parent independently inspected the line,
hash, formatting boundary and diff. No source changed during verification.

Corrected disposable probe command (worktree root):

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix run --no-start /tmp/singularity-c3-cleanup.SpfMQL/driver.exs apps/singularity_runtime/test/c3_cleanup_probe_spfmql_test.exs
```

Outer exit 0. Exactly four expected inner failures, no exclusions/skips; all four
actual captured-PID resume callbacks and all four independent restoration
observers succeeded. The real 200,000-ms settling timeout executed and its
supervised task was proved dead. Source identity remained unchanged. Exact
helper-AST SHA-256:
`f5a0289705da7faa2ba20a89ada0e86e5bdedb961dfccf3dc5cbc0bb62d8aba7`.
Driver SHA:
`2ba231b3f61cbc8c7dd9b18ac5ee3fba10facc23cb84942ef8fa6a52d9f6e5c0`.
The killed-process diagnostic and unused aliases/helper warnings belong to the
disposable probe, which compiles all actual helper AST but not normal test bodies;
they are not production logs or normal C3 compiler warnings.

Exact database `singularity_test_36584b34e298ff7be9a56e5e` count 0 and root
`/tmp/singularity/integration/36584b34e298ff7be9a56e5e` absent independently
confirmed, both exit 0. Parent removed only its owned probe and temporary driver
with apply_patch; the complete driver remains recoverable in the amendment plan.
No borrowed service was stopped or changed.

Independent Astra implementation SPEC then QUALITY reviews both cleared the
exact `9a043a7…cfe4e` source with no Critical/Important findings. Spec review
verified original C3 test-body AST equivalence, all nine generated contracts,
accepted helper/setup equivalence, and unchanged prefix/production sources.
Quality review verified captured-PID ownership, unconditional resume, bounded
settling, residual ledger, real deadlines, exact successor attribution and
content-free added SQL. These source verdicts do not substitute for execution.

Parent took the exclusive Mix slot for the complete unfiltered Runtime file:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

Expected 107 reported, 43 unit exclusions, 64 integration executed. Actual
results, target real deadline and exact alias cleanup remain pending. No tag,
line or module exclusion was added. C4/C5, Task 12 and Phase 2 remain unaccepted.
One C3 diagnostic defect was repaired in the first bounded test-only repair;
failed production repair rounds remain zero. Two optional additional reviewer
capacity requests failed, but existing eligible Astra spec/quality threads were
successfully reused; no review gate was skipped and no current blocker exists.

### First unfiltered C3 result and evidenced repair boundary

The unfiltered command finished exit 2 after 535.5 seconds (36.3 async, 499.1
sync): 107 reported, 43 unit excluded, 64 integration attempted, three failures.
All 55 existing B/C2 integration contracts and six new C3 contracts passed,
including actual 180-second expiry, queued automatic timer, exact concurrent
`[{ :ok, 0 }, { :ok, 1 }]`, successor generation and residual isolation checks.
This is not C3 acceptance: pending restore, paused retry and paused restore failed
at the same test helper's envelope encode, before successor processing.

Source stayed `9a043a7…cfe4e`; cleanup-helper text SHA is
`c74a7a36190a849304b774991c923f4a24a4957078a4e6caea4b763e813b5b46`.
Exact database `singularity_test_a49beacc399e736f0b39c124` count 0 and root
`/tmp/singularity/integration/a49beacc399e736f0b39c124` absent independently
confirmed, both exit 0. All invocation-owned commands have terminated.

Astra read-only diagnosis and parent independent source tracing establish the
cause: retry/restore SQL emits NULL causation; production Outbox normalizes it
to that actual event ID before envelope construction. C1's test helper instead
passes nil into the correctly strict codec. Failure is at `EnvelopeCodec.encode`
(line 2519), whose internal decode rejects it—not at the subsequent explicit
round-trip decode (line 2520). No production or persisted-event repair is needed.

Parent accepted and personally read an explicit narrow C1 freeze amendment in
the C3 design/plan: only `Ecto.UUID.load!(causation || id)` in the existing
helper, with two additional C3 controls proving actual event-ID normalization
and unchanged stored NULL. All other 2,790 prefix bytes and all original
assertions stay protected; old/new hashes and reverse-line identity proof are
required. This avoids a duplicate test-support implementation and never weakens
codec validation. C3 cleanup helpers remain unchanged. First bounded test-only
repair (Oban lookup) is verified; this second test-only repair remains pending.
Three affected assertions are one common defect, not three repair attempts.
Production repair failures remain zero; at least three failed Astra repair
rounds remain authorized. C4/C5 and acceptance remain held.

Independent Astra next-slice preflight found shared-queue fetch interference and
stale C6 whole-file formatting instructions. Parent wrote and personally read a
separate C4/C5 design/plan amendment; independent Astra review found no
Critical/Important findings. It isolates only each new runner ID after proving
its original queue and preserves all existing jobs/contract assertions. This is
preparation only; no C4/C5 source or TEST GO yet.

### Successor correction applied; fresh verification pending

Astra applied only the approved C1 mapping and two new C3 positive assertions.
Parent personally read the exact code and final amendment, then formatted only
the C3 append (the initial format check correctly rejected unformatted separation
around the new multiline assertion). No other C1/C2 byte was formatted.
Final 3,285-line source SHA:
`62631052619632b747892be4636474f4b824ebd3eaaad63501cc589c7bfba3c9`.
New 2,790-line prefix SHA:
`2fdc2bbe3aa6ce3a4ee8a717d790eb67c28a0c243a2495dfe189a6fa4713e108`.
Parent independently proved reversing only that unique mapping restores original
`20598c6…8515`, A/B stays `373ad3d…14178`, and cleanup-helper text stays
`c74a7a3…5b46`. These checks completed exit 0. Whole-source hash before append-only
format was `8c446d7…0a82`; it was not executed as final-source evidence.

Fast diagnostic command:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs:2885 --seed 1208
```

Exit 0, 45.7 seconds: 107 reported, 92 excluded, 15 executed, zero failures.
This is a line-scoped diagnostic result, not the required 64-contract gate or a
claim that only one test executed. Exact database
`singularity_test_f106599207e8469ccd950d42` count 0 and root
`/tmp/singularity/integration/f106599207e8469ccd950d42` absent independently
confirmed, both exit 0.

Independent Astra SPEC re-review cleared final `6263105…a3c9`: exact sole C1
line exception, production normalization, unchanged A/B/helper hashes, retained
original nine C3 contracts/assertions and added provenance controls, no
production/config/dependency change. Independent quality re-review is pending.

Parent started the required full file again with only diagnostic per-test timing
added (no line/module/tag exclusion):

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208 --trace
```

All 64 integration contracts remain required, with the established 43 unit
exclusions. No source change is authorized during this invocation. Actual final
result and exact allocated cleanup remain pending. C4/C5 remain preparation only.

Independent Astra QUALITY re-review also cleared `6263105…a3c9` with no
Critical/Important findings. It independently reversed only the approved C1
line and removed only the two new provenance controls, reproducing the entire
previous `9a043a7…cfe4e` source hash. Thus no other source/assertion changed.
The new helper matches actual production normalization for both non-null and
NULL causation; strict round-trip checks, stored source event and cleanup
ownership remain intact. This is source-quality approval, not runtime acceptance.
The traced unfiltered invocation allocated exact database
`singularity_test_e9ab09bff14529c8c2c191ca` and root
`/tmp/singularity/integration/e9ab09bff14529c8c2c191ca`; it is still running.

Read-only parent observations during the traced expiry test used only lifecycle
metadata in that exact isolated database:

```sh
psql -X -h /run/user/1000/devenv-afa1eb9/postgres -p 5432 -d singularity_test_e9ab09bff14529c8c2c191ca -Atqc "SELECT clock_timestamp(),count(*),min(attempt_started_at),max(attempt_deadline_at),bool_and(attempt_deadline_at=attempt_started_at+interval '180 seconds') FROM content.document_versions WHERE state='extracting'"
```

At `02:21:11.004935 UTC`, two pre-existing attempts remained; earliest start
`02:19:01.363259`, latest original deadline `02:23:03.989141`, exact-duration
predicate true. At `02:23:28.841682 UTC`, those attempts were recovered and only
the new target remained: start `02:23:04.453596`, deadline `02:26:04.453596`, exact
180-second predicate true. Both observations exit 0; no row, timer, trigger,
clock or configuration was changed. The normal unfiltered test remains the
authority for residual identity, exact two-scanner results and final completion;
these observations independently document real settling and target timing.

### Final C3 acceptance checkpoint

The traced, unfiltered command above terminated exit 0 in 516.2 seconds
(36.7 async, 479.4 sync): **107 reported, 43 unit excluded, 64 integration
executed, zero failures**. This includes all 31 B, 24 C2 and nine C3 contracts.
The real expiry/concurrent-recovery contract passed in 357.4264 seconds,
including prior-attempt settling and the target's original 180-second deadline.
The maximum 64 MiB source and 16 MiB output cases also passed. No filter,
deadline/clock/trigger override or required assertion weakening was introduced.

After process exit, independent exact cleanup checks passed:

```sh
psql -X -h /run/user/1000/devenv-afa1eb9/postgres -p 5432 -d postgres -Atqc "SELECT count(*) FROM pg_catalog.pg_database WHERE datname='singularity_test_e9ab09bff14529c8c2c191ca'"
test ! -e /tmp/singularity/integration/e9ab09bff14529c8c2c191ca
```

Database count 0, both commands exit 0. All owned commands have terminated;
borrowed devenv/PostgreSQL services remain untouched. Fresh source checks prove:

- Final 3,285-line test source unchanged:
  `62631052619632b747892be4636474f4b824ebd3eaaad63501cc589c7bfba3c9`.
- Amended 2,790-line prefix:
  `2fdc2bbe3aa6ce3a4ee8a717d790eb67c28a0c243a2495dfe189a6fa4713e108`.
  Reversing only the approved causation mapping restores original prefix hash
  `20598c663e6ecc57c655d48d32e5e32add3e9032c1827d8124361f4b9b838515`.
- Original A/B prefix remains
  `373ad3d5fcfdd07ae522f00a037caa6efabbfba5f060c6c9685fb7d71da14178`.
- Actual cleanup-helper bytes remain
  `c74a7a36190a849304b774991c923f4a24a4957078a4e6caea4b763e813b5b46`;
  the successful four-scenario failure-path execution remains applicable.
- Preserved complete C plan remains
  `350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.

Append-only `Code.format_string!/1` check and `git diff --check` pass, exit 0.
No `apps/*/lib/**` or `apps/*/priv/**` diff exists. Root main remains clean at
`e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`; Phase 2 HEAD remains
`caf80fd4a1e71bc8b4253fbd058980c0be4a8275`. No commit was made this turn.

Independent Astra spec then quality re-reviews cleared the final exact source,
with no Critical/Important findings. Parent accepts C3 locally at this tested
working-tree checkpoint. The dependent C1–C5 source commit remains deferred
until complete C-block acceptance; do not stage C3 alone without C1/C2 support.

Two bounded test-only corrections were made (named Oban lookup and successor
causation normalization); the three first-run failures had one shared helper
cause, not three failed repair rounds. Production repair failures this turn are
zero. User authorization allows at least three failed Astra repair rounds.
No production/config/dependency/migration/grant/Vault work, E2E, merge, push,
release or deployment occurred. Task 12, Phase 2 and full release remain open.

The separately reviewed C4/C5 amendment is accepted. Parent grants only
append-only C4 TEST GO (11 runner contracts and the exact queue-isolation
amendment), preserving all 3,285 accepted C3 lines. C4 implementation has not
started. C5 GO remains held until C4 passes cumulative verification and separate
spec/quality review. This is a continuation boundary, not full phase acceptance.

### C4 continuation started

The previous goal turn made progress: final C3 acceptance and the executable C4
GO changed the authoritative checkpoint. Fresh inspection confirms root main
clean at `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`, the linked Phase 2 worktree
on `codex/v0.2-phase-2-import-extraction` at `caf80fd4…8275`, and the full
3,285-line accepted C3 source still hashes to `6263105…a3c9`. No production or
migration diff exists. Existing dirty/untracked work is preserved.

Parent re-read the complete C4 executable module and queue-isolation amendment,
then dispatched a fresh ordinary Astra implementer (`c4_runner_implement`) with
ownership only of the 11-contract C4 append. No earlier bytes, C5, production,
configuration, services, database execution or commits are delegated. Parent
retains the single shared Mix slot, append-only formatting, independent spec
then quality review, exact environment cleanup and acceptance authority.
`unbuffer` is unavailable; use the plan's established exact `devenv shell -- mix`
command without installing or modifying the borrowed environment. No new test
execution or C4 pass is claimed at this checkpoint.

Astra handed off the complete C4 append, with no running commands. Parent
personally read its complete implementation and mechanically formatted only the
append. Accepted C3 prefix SHA `6263105…a3c9` is unchanged. The final 3,540-line
source SHA-256 is
`73225571a14d707c1631dc544fb48bcfb568b4a22108f47eb7c8c9f8f6033bd4`;
the pre-format append source `47b27ef…05881` is not runtime acceptance evidence.
`git diff --check` passes. Parent started this exact unfiltered command:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208 --trace
```

Session 85750 is confirmed live; exact allocated database
`singularity_test_b632af9e11add8e33a65a1fc` and storage root
`/tmp/singularity/integration/b632af9e11add8e33a65a1fc`. No source changes are
authorized during execution. Expected 118 reported, 43 unit excluded, 75
integration executed; actual outcome and cleanup are pending. Independent Astra
spec review (`c4_runner_spec_review`) is running read-only against this exact
source. C5 GO remains held; no production repair or acceptance is implied.

Fresh independent Astra SPEC review passed: normalized AST of the complete
original C4 executable block plus only its reviewed queue amendment equals the
actual append; registration-only harness confirmed 11 distinct integration
contracts without setup/body execution. Its first disposable harness command
had a syntax error; the corrected in-memory harness passed (expected warnings
from deliberately removed bodies are not application compiler warnings).
Independent Astra QUALITY review then passed, no Critical/Important findings:
real terminal delegation/transaction fault, callback/canonical positive checks,
exact newly submitted runner isolation, wake identity, attempt/max/v4 invariants,
registered handler restoration and bounded owned-runner cleanup. Both reviews
verified final `7322557…33bd4` and frozen `6263105…a3c9`; neither edited files or
ran Mix/database/services. Runtime acceptance remains pending the live full gate.

Read-only lifecycle observations in this exact C4 alias database (same SELECT
shape as the C3 observation above, database
`singularity_test_b632af9e11add8e33a65a1fc`) independently confirm real settling:
at `02:38:17.850251 UTC`, two earlier attempts remained, earliest start
`02:35:00.454346`, latest deadline `02:39:04.589620`, exact 180-second predicate
true. At `02:39:23.364830 UTC`, only the new target remained, start
`02:39:05.460233`, deadline `02:42:05.460233`, exact-duration predicate true.
Both read-only commands exit 0; no source/row/clock/trigger/config change.
Fresh production SHA-256 identities, distinct from test source:

- `documents/extract.ex`: `a1bfb59b107902bca820fc406266571048b3cef4ae354f77a72b3d7da843179b`.
- `jobs/worker_scope.ex`: `d772ca0aa33603233bf40ff521d0a17a5b931114d517c1103f0bd49426168a88`.
- `postgres/document_worker_repository.ex`: `213128313e7b20d9ca3314624ca99b917e84354f21d910ec5c0301656c58229c`.

### C4 accepted; C5 TEST GO

Session 85750 terminated exit 0: **532.2 seconds (37.4 async, 494.8 sync),
118 reported, 43 unit excluded, 75 integration executed, zero failures**.
All 11 new C4 contracts pass; the real wake/Basic snooze/resume contract passed
in 1.5122 seconds, and retained real expiry/recovery passed in 356.1135 seconds.
Both fresh Astra source reviews cleared the exact tested `7322557…33bd4`.

Independent cleanup after exit:

```sh
psql -X -h /run/user/1000/devenv-afa1eb9/postgres -p 5432 -d postgres -Atqc "SELECT count(*) FROM pg_catalog.pg_database WHERE datname='singularity_test_b632af9e11add8e33a65a1fc'"
test ! -e /tmp/singularity/integration/b632af9e11add8e33a65a1fc
```

Database count 0; both checks exit 0. Fresh whole-source hash remains
`73225571a14d707c1631dc544fb48bcfb568b4a22108f47eb7c8c9f8f6033bd4`.
Append-only format check, frozen 3,285-line C3 hash, preserved complete C-plan
hash and `git diff --check` pass. No source change occurred during the run.
All parent/worker/reviewer commands finished and the Mix slot is free.

Parent accepts C4 locally and grants only append-only C5 TEST GO: the complete
nine-contract privacy module plus the already reviewed exact newly submitted
runner queue amendment. All 3,540 current source lines are frozen. Main personally
read the full original C5 code, executable amendment, observability skill and
its complete examples reference. No C4 repair round was needed; production repair
failures remain zero. No Vault/production/config/dependency/migration/grant/E2E
work or external publication occurred. C6, Task 12, Phase 2 and release acceptance
remain mandatory/open; dependent C1–C5 source commit stays deferred.

### C5 focused diagnostic — fixture defect, not production failure

Astra appended all nine original privacy contracts plus the approved queue
amendment. Parent personally read the complete append and formatted only it.
Pre-format SHA `545e39e…919dd`; formatted source SHA
`206408753dcc2b74e28dd767917b51fee8631fbce45752e35ef2c302431b9ec8`.
Accepted C4 prefix `7322557…33bd4` remained exact. Before the long gate, parent
noticed the previously unused private-title helper's NULL envelope causation and
ran this focused diagnostic, without any correction first:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs:3560 --seed 1208 --trace
```

Exit 2, 50.8 seconds (35.3 async, 15.5 sync): 127 reported, 110 excluded,
17 executed, one failure. Actual ready C5 case fails at `ObanAdapter.submit`
with sanitized `job_failed`, before Executor/privacy assertions. This is not
an unfiltered 84-contract gate or a one-test execution claim. Exact database
`singularity_test_030de88c7bbf487b31adfa1f` independently has count 0, and exact
root `/tmp/singularity/integration/030de88c7bbf487b31adfa1f` is absent; both exit 0.

Parent systematic-debugging/source tracing and independent Astra review locate
the cause in existing C1 `private_document!/1`: synthetic envelope causation nil
is rejected by correctly strict encode/decode. Production Outbox normalizes
stored NULL to the actual event ID. Stored event/codec/production stay unchanged.
Parent personally read and accepted a surgical design/plan amendment: one helper
line changes nil to actual `id`, with two new C5 provenance controls (normalized
envelope and still-NULL stored event). All other accepted bytes/assertions remain
frozen, protected by reverse-line hash identity. C5 acceptance and C6 remain held
until corrected source is freshly tested/reviewed. No production repair attempted.

### C5 correction applied and focused diagnostic green

Astra applied only the explicitly approved private fixture line and five C5
assertions (two provenance checks plus strict encode/decode/equality). Parent
personally read the repair and mechanically formatted only C5. Before formatting
source SHA `cde9919…99e02`; final 3,857-line source SHA-256
`20e92bfa0b5d0c1bbeb2b918677658959d208beb434c1edfaa1f529a1130369c`.
New 3,540-line prefix SHA
`6fcc670f335451040e705bb350b3559f2d7b752979ceff3fc908264692a91302`;
reversing only `private_document!` causation id to nil in memory recovers accepted
`7322557…33bd4` exactly. Original A/B hash `373ad3d…14178` and actual C3
cleanup-helper hash `c74a7a3…5b46` independently rechecked unchanged, exit 0.
No earlier prefix was formatted; every original assertion is retained.

Same focused diagnostic without optional `--trace` terminated exit 0 in 54.6
seconds (36.4 async, 18.1 sync): 127 reported, 110 excluded, 17 executed, zero
failures. Exact database `singularity_test_2f51de12bf493452cd8c30eb` independently
has count 0; root `/tmp/singularity/integration/2f51de12bf493452cd8c30eb` absent,
both exit 0. This proves the ready privacy path and fixture correction only,
not all nine privacy contracts or the complete C gate.

Parent started the required full unfiltered Runtime file command, seed 1208,
diagnostic `--trace` only, at exact source `20e92bf…0369c`; session 41148 is live.
Expected 127 reported, 43 unit excluded, 84 integration executed. All source
edits are held during execution. Fresh independent Astra SPEC re-review is
running; quality follows only after spec clears. Actual full result, alias cleanup
and C5/C6 acceptance remain pending. One bounded test-only C5 fixture repair was
needed; no production repair was attempted or failed.

### C5 independent quality finding — inspected-source detector

Fresh independent Astra SPEC re-review cleared exact `20e92bf…0369c`, all nine
registered contracts, precise amended AST, sole helper freeze exception, reverse
prefix identity and unchanged original A/B/C3 cleanup bytes. Subsequent Astra
QUALITY review found one Important test-proof gap: `f.plaintext` is searched raw
inside inspected public/telemetry/persisted terms. The PDF fixture has no title
canary, and inspection escapes/formats source bytes. Thus the current assertions
can miss an entire source leaked into those terms. No actual production leak is
observed; acceptance remains held even if the live run passes.

Parent independently reproduced with the actual `two_pages.pdf` in a standalone
Elixir diagnostic (no Mix/DB/services): an inspected `%{leaked_source: bytes}`
contains neither raw PDF bytes nor the title canary, but contains the full
inspected source representation. All three predicates asserted; exit 0. This
is negative detector evidence and a positive proposed-detection control, not
runtime privacy acceptance.

Parent personally read and accepted the additive design/plan section 6 amendment:
after current frozen-source run and exact cleanup, add complete inspected source
to the existing secret list plus a deterministic fabricated-term detector
positive control. Keep all original assertions and real observed surfaces. No
earlier prefix/production/config/event/codec change. Fresh full gate and separate
spec then quality re-review are mandatory after the change.
Live session 41148 has exact database `singularity_test_bf2992ebe523ecd90bf1bb1c`
and root `/tmp/singularity/integration/bf2992ebe523ecd90bf1bb1c`; do not edit source
or restart it while its real expiry contract is running. C5/C6 remain open.

### Full C5 gate failed; no production workaround authorized

Session 41148 terminated exit 2 at unchanged `20e92bf…0369c`: **554.2 seconds
(38.7 async, 515.4 sync), 127 reported, 43 unit excluded, 84 integration executed,
four failures**. Actual C3 deadline/recovery passed in 355.2990 seconds; every
C4 runner contract passed. C5 fails expected bounded retry/failure event checks
at helper line 3736, while real Oban start/exception/stop and RLS denial events
are observed. Tool output truncated some repeated failure metadata; do not claim
an independent complete read of those omitted values. Aggregate result and the
observed identical failure boundary are established; fresh focused reproduction
and full gate remain required for any production repair.

After exit, exact database `singularity_test_bf2992ebe523ecd90bf1bb1c` independently
has count 0, and `/tmp/singularity/integration/bf2992ebe523ecd90bf1bb1c` is absent,
both exit 0. Source stayed `20e92bf…0369c` throughout the run.

Parent traced the actual captured worker name and production matcher. Independent
Astra diagnosis confirms the application defect, not an upstream dependency bug:
installed Oban 2.24 `Worker.to_string/1` strips `Elixir.`, Job.new uses that value,
and Executor emits it unchanged. Runtime `Telemetry.generic_worker?/1` accepts
only the module atom or prefixed string. Existing unit contracts inject only the
prefixed string, so they miss the actual boundary. Retry and terminal handlers
silently return without deriving events. Unchanged Telemetry source SHA-256 is
`ce4d557f7d03dfb770af689a2e3fd782fbea91adb4fc95c9395b54cba0a21458`.

This production file is outside the approved C5 test-only scope. Affected C5
acceptance stops; no fake event/worker name, relaxed assertion, broad normalization,
production patch, upstream workaround or unrelated Vault investigation is allowed.
Astra recommends a separate surgical compatibility design/plan: accept exactly
the canonical unprefixed GenericWorker string in addition to both existing forms,
with a new focused test file using actual `Oban.Worker.to_string/1`, top-level and
nested metadata, retry/final/cancel/discard, exact sanitized events, and rejection
of unrelated/lookalike names. Preserve all schemas, metadata precedence, queue
mapping, privacy and existing Vault semantics. This diagnosis is not implementation
GO; no production edit has occurred. Required C5 real-executor assertions remain.

Independent detector work remains valid: after full-run termination and cleanup,
parent applied only the approved inspected-source value, fabricated-term detector
positive control, and added secret-list entry, then formatted only C5. The agent
thread limit prevented both reuse of its completed implementer and a fresh Astra
spawn; parent used the documented skill fallback for this mechanical approved
test-only edit, without skipping later independent reviews. Source is now 3,865
lines, SHA-256
`68537ed710bff9559c70ac498f482b56e7aab2d59c01811e56b8ec27e3bfeb3f`;
the entire amended 3,540-line prefix remains `6fcc670…91302`. `git diff --check`
passes; no production/migration diff exists. Focused actual PDF/tool diagnostic
is running under the parent-owned Mix slot:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs:3617 --seed 1208
```

Session 87200 confirmed live; actual result and exact cleanup remain pending.
This focused work cannot establish full C5/C6 acceptance or waive the production
telemetry defect. No production repair has been attempted or failed; at least
three failed Astra repair rounds remain authorized. No E2E, Vault feature work,
commit, merge, push, release or deployment occurred. Goal remains active.

### End-of-turn exact checkpoint

Session 87200 terminated exit 0 in **50.4 seconds (36.9 async, 13.5 sync),
127 reported, 109 excluded, 18 executed, zero failures**. This diagnostic includes
both actual PDF timeout/tool-exit privacy paths and the new detector positive
control. It does not cover the four failed derived-event paths or replace the
required 84-contract full gate. Exact allocated database
`singularity_test_b158783632b4f3ca05aba515` independently has count 0; exact root
`/tmp/singularity/integration/b158783632b4f3ca05aba515` absent, both exit 0.

Fresh final checks retain test source `68537ed…feb3f`, preserved original complete
C plan `350a655…34281`, and unchanged production Telemetry `ce4d557…21458`.
`git diff --check` passes. Root main remains clean at `e866990…ae2b`; active
worktree HEAD remains `caf80fd4…8275`. All owned commands and Astra tasks are
terminal, single Mix slot free, borrowed services untouched. No source commit
was made. Existing unrelated/untracked plan work remains preserved.

Concrete progress this turn: C4 implemented/reviewed/accepted with 75 cumulative
integration contracts; C5 implemented with fixture causation corrected and
focused red/green evidence; independent quality gap strengthened with actual PDF
diagnostic green; full gate exposed and independently traced an existing
application worker-name telemetry compatibility defect. Neither C5, C6, Task 12,
Phase 2 nor full release is accepted. Next safe action is the separately bounded
GenericWorker telemetry compatibility design/plan, focused red/green and exact
unchanged C5 gate, under standing recommended-choice approval. No repeated-blocker
or goal-completion claim is justified.

## GenericWorker canonical-name compatibility prerequisite

Restored exact worktree HEAD `caf80fd4…8275`, clean root main `e866990…ae2b`,
frozen C5 source `68537ed…feb3f` and unchanged production Telemetry
`ce4d557…21458`. Main personally read the new companion compatibility design and
complete executable plan. Independent ordinary Astra review cleared the exact
closed-list patch, all 27 registered focused contracts and source-derived nine
expected canonical RED failures, without blockers/Important findings. Parent
selects recommended exact-alias option under standing user approval and grants
only Task 1 new-test-file GO first. Dedicated ordinary Astra implementer owns the
new file; parent retains single Mix slot and commits. No production GO until
observed correct RED. Actual C5/Executor assertions remain unchanged; no broader
telemetry/Vault/config/migration work, E2E or publication is authorized.

### Compatibility focused RED / GREEN

Dedicated ordinary Astra implemented only the new focused telemetry test file,
SHA-256 `be8c8149eb14d332797ba082e42a670ad607bc9440fbc6f6f7b53118ad1fb14c`.
Parent read it completely and ran:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/generic_worker_telemetry_test.exs --seed 1208
```

RED session56324 terminated exit2, 2.0 seconds, 27 tests / nine failures, all at
missing derived-event assertions for canonical-worker positive cases (eight
matrix cases plus precedence case). All 18 existing-representation/negative
controls passed. Production was unchanged `ce4d557…21458`; parent then granted
Task 2 exact-list-only production GO. This intentional RED is not a failed
repair round.

Astra applied only the planned identity-list expansion, production SHA-256
`4756f8af1f32474bfeff896cf4d175676a1df0bad007bef8a608c2996453de4d`.
Parent inspected its entire production diff and reran the identical command:
GREEN session50554 terminated exit0, 1.0 seconds, 27 tests / zero failures.
Test hash and C5 source `68537ed…feb3f` remain unchanged. Independent spec review
is in progress; quality follows spec. Parent started the unchanged unfiltered
84-integration-contract Runtime gate, seed1208. Actual result/cleanup pending.
No compatibility acceptance, dependent C commit, Phase 2 acceptance or external
publication is claimed. Repair round1 has focused GREEN; failed repair rounds0.

Independent ordinary Astra specification review verified exact production bytes
against HEAD plus only the approved list addition, and exact new-test normalized
AST against the approved plan. A separate ordinary Astra quality reviewer cleared
the compatibility repair with no Critical/Important/Minor findings. Both verified
source hashes; neither ran Mix/database operations or edited files.

Final C5 specification review independently normalized actual AST against the
original complete C5 block, reversing only approved queue, provenance/codec and
inspected-source detector additions: clear, no findings. Subsequent independent
Astra quality review cleared final C5 at `68537ed…feb3f`, including a standalone
actual-PDF diagnostic reproducing the old detector gap and additive fix. Every
old secret/assertion and actual Executor/log/event/persisted surface remains.
Main independently verified original A/B prefix, amended 3,540-line prefix,
accepted C3 restoration-helper hash, and new-test formatting. Full84 result and
exact cleanup are still pending. Final entire-C source specification review has
started separately for C6; prior scoped reviews do not waive any required gate.

### Real Executor compatibility gate result and final review finding

Unchanged Runtime integration command (seed1208), session32562, terminated exit0:
**527.7 seconds (36.3 async, 491.4 sync), 127 reported, 43 excluded,
84 integration executed, zero failures**. Runtime test SHA `68537ed…feb3f` and
Telemetry SHA `4756f8af…de4d` remained unchanged. All four previously missing
derived-event paths now pass with original assertions intact. Independently:

```sh
psql -X -h /run/user/1000/devenv-afa1eb9/postgres -p 5432 -d postgres -Atqc "SELECT count(*) FROM pg_catalog.pg_database WHERE datname='singularity_test_a406838f586e746f93ad4970'"
test ! -e /tmp/singularity/integration/a406838f586e746f93ad4970
```

Count0, root absent, both exit0. Parent accepts the narrow canonical-name
compatibility repair locally: focused RED/GREEN, independent spec/quality and
unchanged actual Executor gate all passed. Production repair round1 successful,
failed production repair rounds0. No source commit yet.

Full-C independent Astra SPEC subsequently cleared all53 contracts and freezes.
Final whole-block QUALITY identified one Important test-proof gap outside the
compatibility patch: ToolFailure's PID-file read and child-death assertion run
inside Extract.extract/2 rescue-all; their failure becomes the expected
extractor_failed outcome, potentially making tool-exit tests falsely green.
C5 timeout also asserts only failed state, not exact failure code. This is not an
observed child leak or production defect. C-block acceptance remains withheld
despite the green84 gate. Main verified the rescue path and requested the smallest
additive test-only amendment: retain all C1 assertions/bytes, add independent
PID presence/positive integer/death checks in C2/C5 test bodies outside rescue,
plus exact C5 tool failure codes. Finish precise scope/negative-control review
before edits; prior green does not clear this finding. Mix slot now free.

### Bounded subprocess-evidence amendment and oracle controls

Main read the final independent quality finding and actual rescue path, recorded
the exact additive companion design/plan, personally read both completely, and
granted only the reviewer-specified test-body additions under standing approval.
Dedicated ordinary Astra added16 lines/791bytes, preserving every old statement
and C1 helper byte. Current full source3881lines, SHA-256
`f40569f8ebfa2b332c29a313264378b60a9c117725f1f54ed35fe29a65885f78`.
New2795/3290/3545line prefix hashes respectively `1cdd335…8f26`,
`6349a41…0b7e`, `bf2c359…bfe8`. Original A/B and C3 restoration helpers unchanged.
Main independently reversed only the two five-line PID blocks plus exact C5
failure-code block in memory: full old `68537ed…feb3f` recovered exactly.

Standalone disposable probe extracted both actual five-statement ASTs, proved
equality to each other and the complete planned block, then executed them without
apps/Mix/database. Four negative controls failed at exact ExUnit expressions:
missing file at File.regular?, live current BEAM at refuted /proc existence,
zero at pid>0, malformed at strict Integer.parse match. Synchronously reaped real
owned child passed. Probe exited0 and proved source unchanged; only its two
owned temp files were removed via apply_patch, exact empty root removed.
This establishes assertion-oracle sensitivity, not production subprocess proof.

Parent started actual C2/C5 tool pairs (same integration alias, source selectors
2743 and3622, seed1208, trace); session28433 running. Actual results/cleanup
pending. Fresh amended-source independent SPEC started; QUALITY follows. No
production change beyond accepted telemetry alias, no failed production repair
round, E2E, Vault feature work or publication. C6 remains unaccepted.

Focused session28433 terminated exit0: **59.2 seconds (35.3 async,23.9 sync),
127 reported,107 excluded,20 executed,zero failures**. Trace explicitly confirms
both C2 and both C5 actual tool cases; location filtering also executes existing
macro-generated regression contracts, so this is not described as a four-test
run. Exact database `singularity_test_84f9348bd6470c62fb11ff18` count0 and exact
root `/tmp/singularity/integration/84f9348bd6470c62fb11ff18` absent, exit0.

Committed only the independently verified telemetry production matcher, its new
focused tests and companion design/plan as
`027b28bc1ca8a635a43fe37b3cceb76d811233cf`,
`fix(runtime): recognize canonical Oban worker telemetry`. Pending dependent C
tests/docs and original untracked plan remain preserved, unstaged. No push.

Full amended-source integration gate is running as session23048, sourcef40569f…5f78,
exact allocated database/root suffix `82b9c5315408641c42c355f0`. Fresh entire-C
Astra SPEC clear, all53 contracts retained and strict old-source reversal proved.
Final Astra QUALITY re-review underway. Read-only formatting check found only
two empty-line insertions required around the new C5 SQL assertion; parent
recorded the precise formatting clarification, will not edit live frozen source,
and will prove AST equality/reversal and reverify finalhash before acceptance.
Mandatory C6 gates remain pending; all future final-source integration commands
will include the entire Runtime file without filtering.

### Amended full gate, final formatting and quality clearance

Session23048 terminated exit0, **557.3seconds (37.0async,520.2sync),
127reported,43excluded,84integration executed,zero failures** at unchanged
sourcef40569f…5f78. Exact `singularity_test_82b9c5315408641c42c355f0` catalog
count0; exact `/tmp/singularity/integration/82b9c5315408641c42c355f0` absent,
both exit0. Parent only then inserted the two agreed formatter-required blank
lines around the new C5 SQL assertion. Final3883line source SHA-256
`b8c6f602344926f4ec085edbd7b3a3b84173efb3d58654cc90ce20d31ba07e42`.
Removing only those two empty lines recovers f405 exacthash; complete normalized
ASTs equal; whole C5 segment equals Code.format_string! output; diffcheck passes.

Fresh full-C Astra SPEC clear at f405 retained all53 contracts and every original
assertion. Independent final Astra QUALITY reviewer compared saved complete
f405 source to actual finalb8c6 source, verified exactly two blankline changes,
strict whole repair reversal to685, original A/B and C3 helper hashes unchanged,
and cleared complete C1-C5 with zero Critical/Important/Minor findings. No reviews
ran Mix/database operations or edited sources. Parent started fresh final-byte
full84 integration command; result/cleanup and every remaining mandatory C6 gate
still pending. No C-block/Task12/Phase2 acceptance or dependent source commit yet.

Independent read-only Astra readiness audit found no further approved Task12
production requirement beyond completing/evidencing its mandatory gates and
dependent commit. Main fully read the194line governing worker-bridge plan and
confirmed two additional verification requirements: seven existing reconciler
integration contracts and explicit compile --warnings-as-errors. Main recorded
the verification-only union command in the tool-evidence amendment; independent
Astra audit cleared coverage consolidation:173expected = original166 plus7,
retaining all assertions of C6 and bridge groups. Original standalone84,
Asset/application101,unitarchitecture80,xref and cleanup remain mandatory.

Checkout-specific Task13/14 source already exists at `77a81a3`/`41e8eff`; unchecked
historical plan boxes do not imply absence. Audit identified separate later
qualification gaps: Task13 tests standalone startup rather than literal Runtime
supervised restart; Task14 empty request-original preflight hashes an in-memory
empty value without reading/authenticating ciphertext. Neither is a new Task12
source requirement or fixed by current tests. Preserve these for separately
bounded characterization/design/repair after Task12 closure; no Phase2 acceptance.

### Exact final-byte84 acceptance and union gate started

Session48250 terminated exit0: **558.9seconds (36.8async,522.1sync),
127reported,43excluded,84integration executed,zero failures**. Before/after source
SHA `b8c6f602344926f4ec085edbd7b3a3b84173efb3d58654cc90ce20d31ba07e42`.
Exact database `singularity_test_1fe404098123d8a6d13b51e7` independently count0;
exact root `/tmp/singularity/integration/1fe404098123d8a6d13b51e7` absent, exit0.
Parent accepts C5 locally after final-source full84, independent full-C spec and
quality clearance, exact freeze/format/oracle controls and cleanup. C6 still
requires every remaining regression, compile and xref check; no dependent commit
or Task12/Phase2/release acceptance yet.

Parent started the verification-only union command documented in the tool-evidence
amendment, seed1208, session31514. Expected173integration (all original166 plus7
reconciler); actual counts/results/cleanup pending. Source remains frozenb8c6.

### C6 combined custody/storage/reconciler result

Session31514 terminated exit0 on unchanged final sourceb8c6. Storage:
73tests,zero failures,30.1seconds. Runtime:148reported,48excluded,
100integration executed,zero failures,566.0seconds (36.2async,529.7sync).
Combined173 integration contracts executed: all original166 plus7reconciler.
The complete Runtime file was unfiltered. Command:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs --seed 1208
psql -X -h /run/user/1000/devenv-afa1eb9/postgres -p 5432 -d postgres -Atqc "SELECT count(*) FROM pg_catalog.pg_database WHERE datname='singularity_test_205a29c6ab16ac8ff70f9841'"
test ! -e /tmp/singularity/integration/205a29c6ab16ac8ff70f9841
```

Exact catalog count0 and root absence independently verified, both exit0.
Before/after source SHA-256 remains
`b8c6f602344926f4ec085edbd7b3a3b84173efb3d58654cc90ce20d31ba07e42`.
Parent completed personal read of the entire final C append,2192–3883, no new
finding; fresh exact A/B and C3 helper hashes and C3/C4/C5 append formatting
checks pass. Independent ordinary Astra read-only closure audit confirms the
remaining required gates, eight-file dependent commit scope, and preservation
of the original full plan byte-identical and untracked. No acceptance gap or
additional Task12 production requirement identified. This does not establish
Task13 supervised restart or Task14 empty-original authentication.

Parent started unchanged Asset/application integration regression, session46857,
seed1208. Actual result and exact allocated environment cleanup remain pending;
unit/architecture, compile warnings and xref also remain pending. No C6/Task12
acceptance, dependent commit, E2E or external publication yet. Failed production
repair rounds remain0; the telemetry repair succeeded on its first round.

Latest restore instruction explicitly selects Astra and permits at least three
failed repair rounds if needed; this supersedes earlier historical maximum-three
wording, not any source/phase/Vault/E2E boundary. Parent restored the existing
active goal, exact clean root main and active worktree source/commit, and resumed
the known live union process without starting a duplicate. No failed production
round has occurred since restoration.

### C6 Asset/application regression result

Session46857 terminated exit0:563.5seconds (35.7async,527.8sync),
166reported,65excluded,101integration executed,zero failures,seed1208.
The entire Runtime file and unchanged Asset/application files were unfiltered:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs --seed 1208
psql -X -h /run/user/1000/devenv-afa1eb9/postgres -p 5432 -d postgres -Atqc "SELECT count(*) FROM pg_catalog.pg_database WHERE datname='singularity_test_fe5688ac48f4ff14c7e97923'"
test ! -e /tmp/singularity/integration/fe5688ac48f4ff14c7e97923
```

Exact database count0 and exact root absent, independently checked, both exit0.
Unit/architecture now running as session82743. Explicit compile warnings and
xref checks remain pending. No additional repair or source edit occurred.

### Final C6 closure and Task12 scoped qualification

All commands below terminated exit0, serialized in the parent-owned Mix slot:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix compile --warnings-as-errors
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
```

Unit/architecture session82743: Runtime166reported,101integrationexcluded,
65executed,zero failures,35.7seconds (35.6async,0.08sync); Web15executed,
zero failures,0.6seconds. Total80unit/architecture executed; integration is not
claimed from this command. Compile session35978 compiled the changed Runtime
module with warnings-as-errors and passed. Xref session24758 reported
`No cycles found`, preserving the seven-application graph. The devenv2.2.2 versus
locked2.1.2 update notice is informational, not an Elixir compiler warning; no
lockfile update was made.

Final mandatory integration ledger: standalone84 (session48250), strengthened
custody/storage/reconciler173 (session31514), and unchanged Asset/application101
(session46857), all zero failures on final source. Every allocated exact database
count0/root absence was independently checked after termination. These overlap;
they are not358distinct contracts. The focused27 telemetry RED/GREEN and focused20
tool diagnostic remain separate evidence, not substitutes for full gates.

Final test SHA-256:
`b8c6f602344926f4ec085edbd7b3a3b84173efb3d58654cc90ce20d31ba07e42`.
Committed production telemetry SHA-256 separately:
`4756f8af1f32474bfeff896cf4d175676a1df0bad007bef8a608c2996453de4d`.
Original2191line A/B prefix remains
`373ad3d5fcfdd07ae522f00a037caa6efabbfba5f060c6c9685fb7d71da14178`;
C3 restoration-helper bytes remain
`c74a7a36190a849304b774991c923f4a24a4957078a4e6caea4b763e813b5b46`.
Parent independently rechecked these exact hashes, final source identity,
C3/C4/C5 append formatting, and personally read all final C bytes. Approved
amendment reversal/oracle evidence and fresh full-C independent Astra SPEC and
QUALITY clearance are recorded above; no Critical/Important/Minor finding
remains. All original53 C contracts and existing A43/B31 contracts remain.

Parent accepts the bounded C1–C6 test block locally. Separately, Task12 scoped
source qualification is accepted: the worker bridge, source replay, actual
runtime composition, terminal/recovery fences, privacy and mandatory regression
requirements are evidenced across their accepted commits and this final gate.
This is not whole Phase2 acceptance. Task13's literal supervised-restart
qualification and Task14's empty-request-original authentication gap remain the
next separately bounded work, not covered or waived by this checkpoint.

Parent authorizes one dependent local commit containing exactly the Runtime test,
this verification record, and the C3/C4-C5/tool-evidence companion designs/plans
(eight files). Git records the resulting commit identity; no production file
belongs in that commit. The preserved original full executable plan remains
untracked, byte-identical SHA-256
`350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`,
excluded from staging. Root main remains unchanged. All owned commands are
finished, the Mix slot is released, owned process/handler cleanup assertions
passed, and borrowed services remain untouched. Production repair round1
succeeded; failed production rounds0. No migration, dependency change, Vault
feature or compatibility patch occurred in this closure. E2E/complete README
acceptance: NOT RUN under owner restriction. No merge, push, tag, release,
registry publication or deployment occurred.

Independent final ordinary Astra evidence/scope review cleared the closure and
six companion status updates with no Critical/Important findings. It confirmed
the distinct C6/Task12 versus Phase2/release boundaries and exact eight-file
commit scope. Parent staged only those eight files, independently inspected
the staged names/stat/diffcheck, and confirmed no production file or preserved
original full plan was included. No source changed after the green gates.
