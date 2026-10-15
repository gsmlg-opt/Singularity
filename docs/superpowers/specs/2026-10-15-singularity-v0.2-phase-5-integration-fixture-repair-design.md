# Phase 5: integration fixture isolation and bounded canonical setup

Status: IMPLEMENTED; focused qualification, all15 final permitted README gates,
and final whole28 actual SPEC then NEW distinct fresh QUALITY are CLOSED PASS.
Local source is `d1a8d4f73c570daa7177468b246a25819a2cdd39`. Documentation review,
commit and clean handoff close under the [Task10 handoff](../../verification/2026-10-15-phase-5-task10-handoff.md).
Phase5 is not accepted; E2E NOT RUN. The remaining sections preserve the approved
design's historical inputs and implementation requirements, not a claim that the
original PDF or V3 timeout cause is known or causally repaired.

## Evidence and scope

The unchanged README integration gate ran once on the upload-stream source:
session4152 naturally CLOSED2, seed988075, default96. Its complete raw log is
`.devenv/phase5-task10-upload-stream-readme-07-integration-native.log`,
SHA256 `fff90b0f98bb4f424d4c879563ede664eb96e1f7afe6e338df299ae380ee0e8b`.
It selected1874 tests, invalidated4, executed1870, and failed14;2102 existing
exclusions remain exclusions. The recorded post-source/pin guard and ordinary
residual query passed. The failure is not reclassified by this design.

Two independent read-only Sol diagnoses establish these repair candidates:

- All13 Wake migration tests prepare in the invocation-wide database. Their
  released downgrade correctly refuses any pending wake generation, including
  unrelated state not covered by the test's event-scoped cleanup. The raw errors
  establish pending state existed; they do not identify its producer.
- Four search-plan tests were invalidated by setup_all: one transaction inserts
  8192 complete Notes and expires at COMMIT under the existing15s checkout.
  Deferred typed-head, aggregate and source-set finalizers accumulate in that
  transaction. Their additional work is a source-supported explanation, not a
  measurement distinguishing COMMIT cost from lock waiting. Projection batching,
  GIN maintenance and ANALYZE occur afterward and did not cause this failure.

A separate V3 large-record import test timed out at its unchanged60s deadline
during actual destination receipt publication, after staging, native insertion,
canonical digests and admission validation. This does not prove slow fsync or a
filesystem/dependency defect. Read-only diagnosis found one redundant full fixture
snapshot; candidate C below removes only that work. Its sufficiency is unproven.
No ordinary integration rerun substitutes for diagnosis or focused qualification.

## Recommended A: owner-managed Wake fixtures

Before repair, add a focused isolation assertion to the existing Wake setup:
capture the actual baseline database through RequestRepo, then require the
fixture MigrationRepo database to differ. Place the assertion after the old
cleanup registration but before stopping Runtime or downgrading. The existing
schema-default test is a deterministic RED: the old setup uses the same database.

After RED, acquire the established surviving KnowledgeFixtureResourceOwner
before seeding, using an explicit test-only MigrationRepo pool-size2 option.
Thread that one option through acquisition without changing default callers,
configuration snapshots, ownership checks, checkpoints, or acknowledged cleanup.
Both migration and destination MigrationRepo instances must use two connections.
The timezone helper's two simultaneous holders must still cover the entire pool.

Provide explicit expected-PID fixture borrowing for the two existing seed
entries used here: two_vaults! and outbox_event!. Original arities retain their
start/transaction/stop lifecycle. A borrowed path must verify the exact currently
registered MigrationRepo PID, use the same role-scoped transaction and seeding
bodies, and never stop the borrowed repository. No implicit auto-borrowing.

Retain all13 existing test bodies and downgrade assertions unchanged. The new
setup keeps the database-inequality assertion, checks pool2 and repository PID
continuity, then performs the same guarded downgrade in the owned database.
Remove only orphaned event-scoped SQL cleanup and manual Runtime/repo restoration;
the owner already handles normal return, setup exceptions and caller death.
Do not run late SQL cleanup after the owner restores baseline configuration.

Add a focused baseline-pending sentinel regression using exact test-owned rows:
prove the global downgrade guard rejects that state, owned preparation succeeds,
and baseline row/counters/schema and configuration remain unchanged after release.
Register sentinel cleanup BEFORE any insertion, binding it to exact allocated
submission/event IDs and the captured baseline connection/database. Pause only
the captured test Runtime if necessary before seeding; restore its original
running state after cleanup. The surviving ExUnit callback must run after the
destination owner's acknowledged cleanup, verify baseline identity, then delete
only those exact sentinel rows even if an assertion, setup exception or caller
death prevents normal cleanup. Never target whichever database global config
happens to name. Cleanup/identity failure is FAIL, not silent fallthrough. Prove
callback ordering and removal for normal and exceptional/killed-caller paths,
while unrelated pending rows remain untouched.
Retain existing normal/error/caller-death lifecycle regressions; exercise the
new pool option and rejected/stale PID borrowing without weakening their bounds.

## Recommended B: bounded complete-Note transactions

Before changing the loader, assert its resource insert is at most512 rows while
retaining the existing8192-row expectation. The old8192-row insert deterministically
fails this added setup contract before deferred COMMIT. Record four INVALID tests
honestly; a setup-contract RED is not four executed test failures.

Then partition ordinals1..8192 into512-row batches. In each owner transaction,
insert resources, resource_versions and note_versions for exactly that batch,
and assert all three insert counts equal its size. Both dependent SELECTs must
restrict the current batch's IDs; owner-wide predicates would duplicate prior
batches. Do not change Fixtures.with_owner, query/checkout limits, roles,
constraints, or production search.

After each commit, a fresh owner transaction verifies the complete typed-head,
resource/version/Note identities and the generated empty source-set seals.
Verify all8192 canonical/seal records, deterministic IDs/titles/bodies/timestamps,
and zero attachment/citation counts. Keep the existing projection batches,
uniform maintenance and every original production-role/plan/deadline assertion.

## Recommended C: original-ciphertext metadata lookup only

prepare_source captures a full38-table canonical oracle; verified_bundle captures
another full snapshot for its logical records. bundle then repeats all38 SELECTs
solely to obtain content.asset_objects for object_payloads. For the large test,
this unnecessarily transfers/decodes identity.people.metadata again.

Keep both independent full snapshots, both real staged restore oracles and every
digested/admission pass. Replace only bundle's third snapshot with select_rows
restricted to the existing canonical content.asset_objects projection. Preserve
owner filtering, columns, ordering, object_payloads and real filesystem sync.
Never reuse potentially malformed logical rows for canonical ciphertext lookup.

First add a deterministic query-count contract around each existing records/replay
verified_bundle call: one canonical SELECT per38 tables, plus one additional asset
metadata SELECT. Current code reads every table twice and must fail. The test-only
observer may transiently classify existing Ecto query events, retaining only fixed
table names/integer counts for the current caller. It must not retain or emit SQL,
parameters, results, source bytes, paths, arbitrary metadata or new telemetry.
Register an exact-handler ExUnit on_exit fallback BEFORE attaching the global
telemetry handler, in addition to normal after detachment/state restoration.
after alone does not run for a killed caller. Keep the fallback independent of
caller-owned process state and idempotent; never detach another handler. A small
test-local prepared counter descriptor may be registered by the containing test
before a monitored actor attaches it. Exercise normal/exception cleanup and a
killed actor, then invoke the exact registered fallback and verify handler absence;
the later ExUnit callback remains safe. A dead actor's local counters die with it.
Classify only the first FROM table, not nested owner-filter subqueries. An
unmatched/missing expected read cannot become PASS.

Add an authenticated malformed asset lookup_digest variant with exactly one
logical field change, unchanged original ciphertext records and canonical source.
This rules out substituting transformed asset metadata. Keep all existing fixture
assertions and defaultV2 checks. Then run the unchanged large-record import test
at its actual selected line and original60s limit. Removing37 redundant SELECTs
is not proof the timeout is fixed. If it still fails, retain the failure and enter
bounded elapsed-stage characterization; do not repeat, prewarm, move preparation
outside the original deadline, skip sync, reduce data or increase any deadline.

## Ownership and preserved boundaries

A worker owns Wake test, Fixtures, ResourceOwner, MigrationTestEnvironment and
narrow lifecycle regression changes. A separate worker owns KnowledgeBackupFixtures
and its existing fixture test for candidate C. The coordinator owns the search-plan
test, both design/plan documents, evidence, successor guards, Native commands and
progress synchronization. These source edits are decomposable; Native execution
is serialized with all other actors CLOSED. No agent edits another owner's files.

No production code, released migration, runtime role, Vault/custody/key/capability,
DownloadLease, defaultV2, immutable provenance, object durability, browser or
publication behavior changes. Opaque legacy fixture seeding is compatibility
plumbing, not Vault feature work. Preserve all prior dirty/untracked files.

## Verification and guard succession

Before source edits, retain immutable before-images/hashes of authorized files.
Historical277-entry/27-manifest guards remain immutable. Their source checks
cannot truthfully pass after authorized edits: create reviewed successor
manifests, replacing only documented changed source entries and adding the
previously unlisted Wake/search/Fixtures contracts. Check all unaffected entries,
historical manifest identities, before-images and explicit patch/inverse; never
overwrite historical seals or label old-source results current-source PASS.

Each RED and GREEN requires a fresh exact-source seal, reviewed exact argv/logger,
fresh nonsymlink raw path, unchanged pinned profile/private PostgreSQL identity,
empty index/exact HEAD, no owned BEAM/logger, and ordinary residual query EMPTY.
Any Native/maintenance LIVE interval permits only its exact-session polling and
commentary. No reads/edits/Git/SQL/other agents until natural closure; then read
the complete raw EOF and validate post-guards/residual cleanup.

Focused checks precede actual-source SPEC then distinct fresh QUALITY review.
After all remaining failures are genuinely resolved, execute the complete
permitted README gate on the new source, including ordinary no-args unit and
integration commands. Prior source PASS evidence remains historical. E2E is
NOT RUN/manual-only; no browser/release acceptance, merge, push, tag or deployment.
Sol repair counters for these new groups start at0 without resetting inherited
counters. Escalate only after two failed Sol repair rounds or evidenced impasse.
