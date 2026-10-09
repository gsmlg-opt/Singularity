# Document Runtime outcome/recovery integration verification

Date: 2026-10-09. Status: original exact-size C2 regressions, corrected 76-test
storage gate, Asset/application, unit/architecture and zero-cycle gates passed.
The bounded WorkerScope patch is applied and unchanged. Corrected 14-contract
lifecycle verification passed. After user-resumed Astra spec/quality reviews
passed, the bounded repair was accepted and committed locally at `ecb1703`.
Task 12, Phase 2 and full release acceptance remain
open. Earlier preparation/GO checkpoints are historical.

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
