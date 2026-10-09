# Document literal Runtime-restart qualification

Status: bounded Task13 literal supervised-restart qualification accepted locally.
Isolated1 and combined29 integration tests, exact cleanup, formatting and fresh
independent ordinary Astra source SPEC then QUALITY all passed. Parent read the
complete design/plan/final source; the exact four-file local commit is authorized.
See `docs/verification/2026-10-09-document-supervised-restart-qualification.md`.
No production defect is established. Task12 is
qualified locally at `138b035e56c2bc7416e6840a0ad2ae2aff798093`.

## Requirement and decision

Original Phase2 Task13 explicitly requires restarting Runtime's supervisor and
observing one recovery event plus a pending row at advanced generation. Existing
production implements startup recovery and a30second periodic cadence, but the
current startup test starts a separately named reconciler. C3's suspend/resume
and explicit run also do not establish supervisor replacement.

Add exactly one integration test in
`apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs`.
Use the established `Application.stop(:singularity_runtime)` /
`Application.ensure_all_started(:singularity_runtime)` pattern from
`job_restart_test.exs`. Assert actual old/new Runtime supervisor, registered
ExtractionReconciler and WorkerRepo identities and direct child relationships.
Reject standalone-child or child-only restart as substitutes. Directly killing
the root adds application-termination hazards without useful extra coverage.

## Exact behavioral contract

Use DataCase async:false, integration tag and300000ms test timeout. Fail closed
unless current database matches `singularity_test_[0-9a-f]{24}`, Runtime
infrastructure is enabled, the actual supervisor/children are running, and the
existing named Oban configuration is manual with no queues/plugins. Confirm
the alias's exact database/root mapping; do not change application settings.

Register on_exit restoration before any stop: ensure Runtime started and assert
its root/reconciler/WorkerRepo running as the correct supervisor children.
Restoration failures propagate; test timeout is not an excuse to leave Runtime
stopped for subsequent tests. This restores only the test BEAM's owned Runtime
application, not a borrowed PostgreSQL or external service.

Create ordinary source/Document fixtures and fixture-only asset.read assignment
through existing owner helpers. Insert a real generation0 extraction outbox
event with original owner/principal, actual epochs, private classification,
asset.read, envelope1, exact two-ID payload and canonical idempotency key.
Build JobEnvelope from the stored event and prove strict codec round-trip.
No jobs submission, progress, custody fixture or SQL grant is needed for claim.

Claim via actual WorkerScope and DocumentWorkerRepository.claim with plain_text1.
Assert extracting/generation1/job/adapter/format identity, exactly180000000us
between returned timestamps, matching canonical row and unchanged source pins.
Capture the complete relevant attempt/source snapshot and no successor event.

Monitor the root, reconciler and WorkerRepo. Stop Runtime; assert all original
processes terminated and registered names absent. Assert the original attempt
is still unexpired, failing if stop happened too late to exclude prior recovery.

While Runtime remains stopped, poll PostgreSQL's actual clock through short
Fixtures.with_owner/MigrationRepo queries. Assert the full original row and no
successor at each observation. Wait until stored deadline < clock_timestamp(),
with approximately1second observations and210000ms monotonic overall bound.
No transaction/checkout spans a wait; no clock hook, timestamp mutation, trigger
bypass or shortened production lifetime. Fixtures.with_owner starts/stops its
own MigrationRepo; do not assume a continuously live administrative repo.

Before restart, record monotonic time. Ensure actual Runtime application
started, require three new PIDs unequal to their predecessors, and require new
reconciler/WorkerRepo directly supervised by the new actual root. No explicit
reconcile call/message, suspension or separately named reconciler is allowed.

Observe one consistent recovered snapshot within10000ms measured from before
the restart call. This is below the unchanged30000ms periodic cadence. Require
pending/generation2; all attempt job/timestamps/adapter/format cleared; source
pins unchanged. Require exactly one canonical successor ID with revision2,
exact two-ID payload, original owner/principal/current epochs, private,
asset.read/envelope1, correlation equal to version and causation equal to the
abandoned job. Duplicate/partial/unexpected states must fail, not be retried
into a passing assertion. Retry only the known original extracting snapshot
until the bounded automatic transition appears.

Replay the original actual WorkerScope claim: conflict. Re-read the complete
recovered snapshot/event identity and count, all unchanged. Existing unchanged
reconciler/lifecycle tests continue to prove completion/failure/concurrent fences;
do not duplicate the entire Task12 suite or fabricate a completion source map.

## Scope, characterization and gates

Only the new test and its private helpers may change executable source. Parent
owns this design and verification; a dedicated Astra plan author owns only the
new complete-code companion plan. Existing C qualification source, original
untracked C plan, production, configuration, dependencies, released migrations,
grants and custody/key/capability/Vault semantics remain unchanged. Assigning
asset.read fixture rows is not a SQL privilege or capability implementation
change. No public API, E2E, publication, deployment or borrowed service changes.

This fills a missing characterization contract for already implemented behavior;
initially green is expected, not fabricated missing-production-code RED. The
expired unchanged row/no successor while Runtime is stopped is the negative
control; actual root restart is the only introduced causal change. If the test
fails, retain that real evidence and diagnose before any separately bounded
production repair. Never remove an implemented child or weaken an assertion to
manufacture RED/GREEN. At least three Astra repair rounds are permitted if needed.

Baseline three-file Task13 gate:28integration tests passed, exact cleanup
recorded in `docs/verification/2026-10-09-document-supervised-restart-qualification.md`.
After plan review/test GO, run the new test alone and then all four files through
the isolated integration alias. Expected final29, actual counts govern. Exact
database catalog count0 and root absence after each, new-file format check,
diffcheck, fresh independent spec then quality review, parent acceptance and
scoped local commit. No broader Phase2/README/release acceptance is implied.
