# C3 full-suite recovery isolation

Status: accepted locally, including implementation and verification, at working-tree
source SHA-256 `62631052619632b747892be4636474f4b824ebd3eaaad63501cc589c7bfba3c9`.
Complete C-block acceptance and its dependent local commit are now authorized;
see `docs/verification/2026-10-09-document-runtime-outcomes-integration.md`
for final-source C6 closure and separate Task12 scoped qualification.
The final unfiltered gate executed all 64 integration contracts with zero failures;
independent Astra spec then quality reviews and exact alias cleanup passed.
Phase 2 and release acceptance remain open.

Parent personally read the complete architecture, executable amendment, and
original C3 module. Independent Astra spec review found one Important proposed
SQL-column mismatch, corrected before implementation to the physical
`extraction_adapter` / `extraction_format` columns. Re-review reports no unresolved
Critical/Important findings. Parent grants append-only C3 TEST GO under standing
auto-select approval. Failure-path and unfiltered integration verification remain
required before acceptance; no production repair GO is granted.

## Scope and authority

This is a test-only amendment to Task C3 in
`docs/superpowers/plans/2026-10-09-singularity-v0.2-document-extraction-runtime-outcomes-integration.md`.
The user restored the active Phase 2 goal, requested Astra, and authorized
auto-selection of the recommended work. Astra supplied this bounded test-harness
architecture under `PROJECT_ARCHITECTURE`; the parent owns review and execution.
The checkout prerequisite is accepted at `caf80fd4a1e71bc8b4253fbd058980c0be4a8275`.

Only the new C3 module may change executable source. The existing 2,790-line
Runtime test prefix, all C1/C2 support and assertions, and all production files
remain byte-identical. No E2E, Vault work, dependency change, migration, grant,
clock/deadline mutation, trigger bypass, publication, or deployment is authorized.

## Observed interference

The application-owned `ExtractionReconciler` immediately scans at startup and
then every 30 seconds. Its global scan can win the target recovery before the
two C3 scanner processes. Earlier serial tests also retain extracting attempts;
those can inflate the exact global recovery count. Some retained attempts are
tombstoned or have revoked owners and are intentionally ineligible for recovery.
Requiring zero extracting rows globally would incorrectly reject those fixtures.

## Chosen isolation

For the one expiry test only, capture the current VM's original reconciler and
supervisor PIDs, verify running status and exact state, and arm ExUnit cleanup
before requesting acknowledged `:sys.suspend/2`. Never act on a replacement PID.
Keep the child suspended through the original test. Verify its timer message is
queued after the real target deadline. Cleanup unconditionally attempts resume
of the captured PID and verifies its identity, running status, and original state.

Before creating the target fixture, prove both repositories use the integration
alias's same allocated `singularity_test_<24 hex>` database, the matching storage
root, and manual Oban without queues/plugins. Admit at most 10,000 existing
extracting attempts. Their exact fields remain fixed while waiting for their
latest original database deadline (each duration is exactly 180 seconds).
Use unchanged production list/run recovery APIs in bounded 100-row batches.
Reject unadmitted IDs, no progress, field changes, or new attempts. Prove the
recoverable list is empty, retaining an exact ledger of ineligible expired rows.
Check that ledger remains unchanged throughout the original target test.

Settling runs in an ExUnit-supervised temporary task, bounded to 200 seconds.
The target fixture is created only afterward so its authenticated session does
not age during settling. The expiry test's orchestration timeout becomes 420
seconds; the real 180-second extraction deadline remains unchanged. Database
time governs waits; bounded timers only schedule the next observation.

## Preserved contracts and failure behavior

All nine original C3 tests execute in the unfiltered cumulative integration file.
The original exact concurrent results `[{ :ok, 0 }, { :ok, 1 }]`, pending
generation, one successor event, stale completion/claim/exhaustion fences,
successor claim/completion, and final zero scan remain unchanged. The setup may
recover earlier disposable fixtures but cannot alter ineligible rows.

A pre-existing suspension fails before registering cleanup. Failed setup,
assertions, settling, and test-process timeout still run the registered resume
callback. ExUnit terminates its supervised processes before that callback.
Dead/replaced children fail exact-identity restoration; a replacement is never
resumed. The integration alias then owns application/database cleanup. Killing
the entire BEAM cannot execute ExUnit callbacks and requires parent verification
of alias-owned database/root cleanup. Borrowed devenv/PostgreSQL services are
never stopped or reconfigured.

## Alternatives and acceptance

Terminating/restarting the child loses original PID/state and schedules a fresh
immediate scan. Filtering out the expiry test evades the complete integration
gate. Neither is accepted. Ledger-only recovery counts without settling allow
prior deadlines to cross between scans and complicate attribution.

Acceptance requires independent design/spec review, exact-source inspection,
failure-path harness verification, all nine C3 tests in the unfiltered cumulative
file, unchanged frozen prefix/production sources, format/diff checks, subsequent
spec then quality review, and independently confirmed alias database/root cleanup.
The expected cumulative count is 64 executed integration contracts, with 43 unit
contracts excluded by the established integration alias. Actual results govern.
This does not accept C4/C5, Task 12, Phase 2, or the release.

## Accepted bounded successor-mapping amendment

The first unfiltered C3 execution on `9a043a7…cfe4e` attempted all 64 integration
contracts: 61 passed, three retry/restore successor cases failed in test support
before their successor assertions. The actual expiry/concurrent-recovery case
passed. Astra and parent independently traced the failure to
`DocumentOutcomeIntegrationSupport.successor!/2`: it preserves nullable stored
causation, unlike production `Postgres.Outbox.claimed_event/1`, which uses
`load_uuid(causation_id || event_id)`. `EnvelopeCodec.encode/1` correctly rejects
the test's NULL envelope causation. No production defect or codec relaxation is
indicated.

Under standing recommended-work approval, parent accepts exactly one exception
to the 2,790-line freeze: replace the C1 test helper's causation mapping with
`causation_id: Ecto.UUID.load!(causation || id),`. Preserve every other prefix
byte, all existing assertions, stored events and production files. Add two C3
positive controls proving the pending-restore envelope uses its actual event ID
and that the exact stored event still has NULL causation. Record old/new prefix
and whole-source hashes, and prove reversing only this line recovers the original
frozen hash. The original 2,191-line A/B prefix remains byte-identical.

This is a test-only repair GO, not acceptance. Run the entire unfiltered file
again and independently verify exact database/root cleanup. The already-verified
cleanup helpers themselves must remain byte-identical; their original successful
four-scenario evidence is retained only with that explicit identity proof.
