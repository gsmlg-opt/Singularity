# Phase 5 prerequisite fixture compatibility and private environment recovery

## Status and authority

Design candidate; implementation and fresh qualification NOT RUN. This is a
necessary Phase 5 compatibility repair under AGENTS.md continuous development
authorization, not a new product slice or a request for routine approval.
Independent design SPEC followed by NEW distinct QUALITY must precede changes.
The matching plan is
`docs/superpowers/plans/2026-10-17-singularity-v0.2-phase-5-prerequisite-fixture-compatibility.md`.

Task11, Phase5 and the complete release remain unqualified. Default V2 stays
closed to unsupported canonical rows. Task16 BOTH-strict ALL-leases remains
UNSATISFIED/UNWAIVED/BLOCKED_DESIGN; Task17 is NOT GO. Master Task18 depends on
Tasks11,12,17. E2E is NOT RUN/manual-deferred. No merge, push, version, tag,
release, deployment, production activation or production backfill is authorized.

## 1. Observations and bounded conclusions

Native107 ran the ordinary no-argument `mix singularity.test.integration`, seed
186096, max_cases96. Its owned session22716 is now unknown and its former private
PostgreSQL PID3730509 is absent. Its retained raw has 604 lines/100467 bytes,
SHA256 `06e2c7e3e19ae049347afc8e83f01557a5bf4a2101e3cb47080ff9782b433df7`,
ends with NUL bytes, and has no complete suite footer or actual exit code.
Classify the invocation INCOMPLETE/INTERRUPTED with five observed failures,
never PASS or natural termination. A later recovery cannot supply its missing
termination or turn its failures into successes. Cause of interruption is not
established. Old raw, manifests, source pins and review receipts are immutable.

Four failures are the two orderings of each finalization race in
`knowledge_asset_lifecycle_guards_test.exs`: organization/finalization and retained
Note Save/finalization. The actual result is nonretryable `:conflict`, not a race
timeout. Accepted native-text commit `6fd422a6987121d02e54a8cc6395061880ec903f`
requires complete text evidence before reuse. The local helper creates a
`text/plain` grant without source_reference_id, and inherits completed metadata
named test.txt while its grant says lifecycle.txt. Strict rejection is correct.
Production checks and existing negative text-evidence contracts must not change.

The fifth failure is OutboxTest's fresh target missing from its claim of100.
Its setup commits fixtures without isolating the shared global queue. Claim
orders eligible events by sequence before applying its limit, so100 earlier
eligible events can exclude the target. This is a source-supported isolation
defect, not proof that Native107 actually had100 such events. Add a controlled
counterproof before repairing isolation. No evidence currently attributes this
to leakage from the new isolated backup fixture databases.

## 2. Test-only source ownership

Only these two additional source owners may change under this amendment:

- `apps/singularity_storage/test/singularity/storage/postgres/knowledge_asset_lifecycle_guards_test.exs`
- `apps/singularity_storage/test/singularity/storage/postgres/outbox_test.exs`

No shared KnowledgeFixtures, DataCase, TestEnvironment, schema, migration,
production repository, dispatcher, runtime, API or new production behavior is
part of this repair. Frozen56, Vault, keys, custody, capabilities and DownloadLease
remain unchanged. Parent owns these documents, the saga cross-references and
ignored recovery/source/evidence receipts. Required final combined reviews cover
both additional source owners as well as the existing complete saga source map.

### Asset fixture

First add a focused fixture-contract case which calls the existing local
finalization fixture and requires real `AssetRepository.reserve_finalization/2`
with the existing envelope and object_id command to return the expected existing
stage/object reuse, with identity assertions.
The unchanged helper must fail meaningfully with the observed conflict; a
missing-function or compilation error is not RED.

Then change only that helper's local persistence preparation: insert an immutable
browser_upload SourceReference for the same resource version, principal, owner,
classification, filename lifecycle.txt, text/plain, size12 and SHA256 of the exact
grant idempotency key. Bind its ID on the grant. Prepare that Asset's metadata
with the same filename/size/MIME, projection_version1, pending extraction,
extractor_version upload_text_v1, and nil detected/completed/PDF/image fields.
Check each insert/update affects exactly one row. Keep the existing stage,
object, envelope, sizes12/100, timestamps/order, actual epochs, both race orders,
barriers, deadlines, provenance and effects assertions. Do not replace text with
binary fallback or invoke native crypto merely to fabricate this storage fixture.
Describe this as synthetic storage-contract evidence, not genuine native
validation, runtime custody or original-byte verification proof.

### Outbox fixture

Behavior-preservingly extract the existing setup construction to a local
queue_fixture!/0 helper. Setup continues calling it. In a new regression, first
mark preexisting test events delivered with a regression-only owner preparation
helper so the controlled witness is not confused with suite leftovers. Append
exactly100 distinct earlier eligible events after setup through the real
ScopedRepo/Outbox API, assert their undelivered/unretired/unleased eligibility
and sequence-ordered IDs using owner-only test observation, then call queue_fixture!/0
again and append one fresh target. Require the normal claim limit100/lease60 to
return exactly that target; acknowledge it and require the next normal claim to
be empty. Assert identity sets/counts rather than relying on UPDATE RETURNING
row order. Before the repair the100 earlier events must be returned instead of
the target: preserve the actual controlled RED and its IDs/count evidence.

Repair only queue_fixture!/0: before constructing fresh fixtures, mark existing
undelivered test events delivered through Fixtures.with_owner/MigrationRepo,
following RunnerSubmissionRecoveryTest's established preparation. This operates
only on the owned disposable test database, never a production/global host
database. It preserves all original event-equality, empty-after-ack, malformed
input, conflict and authorization assertions. No claim-order/filter/limit,
dispatcher, lease or production policy change. No test-order/seed dependency.

## 3. Private PostgreSQL recovery

Before recovery prove no owned Native/script/BEAM remains; all agents and their
commands must be CLOSED. Validate the existing nonsymlink owner0700 PGDATA
`.devenv/phase5-pg.0LPElO` and socket directory
`/tmp/singularity-phase5-socket.hzWDT0`, PG_VERSION17, original postmaster.opts,
old PID absence and exact binary. Do not touch system PostgreSQL or another BEAM.

Recheck exact cluster liveness immediately before acting. If the original cluster
is already LIVE with its exact binary/PGDATA/socket/port, do not start or restart
it; only qualify its actual identity after owned-workload quiescence. Otherwise
start only this existing cluster with PostgreSQL17.10 at
`/nix/store/y83y08rgfv0zag50cvq55aqx9hyc2ldv-postgresql-17.10/bin/pg_ctl`,
the same PGDATA, socket, port5432 and listen_addresses empty. Use ordinary
pg_ctl -w start and fresh absent/nonsymlink private server/control logs under
umask077. Do not reinitialize, upgrade, change role/password/service/config,
delete pid/socket files manually, signal or force cleanup. Retain an ordinary
startup failure as failure and diagnose without bypassing these checks. Keep
server logs private; never dump connection URLs, environment or credentials.

After ordinary successful startup independently verify new PID/executable,
same PGDATA/socket/port and ready state. Derive a NEW ignored source guard from
the old44-line guard by replacing ONLY its two literal PID3730509 references.
Inverse replacement must recover old SHA256
`7e385ee962ca51d838df40f603817e181f2b56695e5b97aff95dce2160f71f31`.
Old guard/manifests remain immutable. All source, helper exception, frozen56,
branch, HEAD, index, status, toolchain, database identity and owned0 guards stay.
This is environment identity recovery, not a toolchain or source relaxation.

Capture a fresh ordinary residual query. Nonempty remains an observed failure,
not EMPTY. Inspect each exact owned database's provenance, owner and live
connections before considering ordinary non-FORCE cleanup. The only known
interrupted Native107 database is singularity_test_0383b6664bf81914b8bae0b5;
its known storage root is /tmp/singularity/integration/0383b6664bf81914b8bae0b5.
Do not automatically drop enumerated databases or recursively remove any root.
If precise ownership/no-active-connection conditions cannot be established,
preserve it and continue diagnosis rather than misreporting cleanup. A fresh
post-recovery EMPTY is new evidence, never Native107's natural postcondition.

## 4. Qualification and unchanged gates

Parent alone executes all Native work with fresh private unfiltered raw, exact
source/status seals, actual exit code/natural lifetime and ordinary postSQL.
While LIVE only exact empty owned-session polls and commentary; all other
commands/agents closed. No workload, fsync, crypto, inputs, seed, concurrency,
pool, assertion, timeout or runtime reduction; no prewarm/cache/fake boundary.
The previously reviewed single120s sentinel watchdog remains its sole exception.

Run both complete additional test owners at seed186096 with warnings-as-errors
for baseline, actual new-contract RED and fixed GREEN. Then retain all unchanged
master Task11 and prerequisite command vectors, full retained owners, sole
independent restore, static/frozen/architecture/dependency checks and the COMPLETE
permitted README gate on final source. Ordinary full integration remains the
no-argument command, not a selected substitute. E2E alone is NOT RUN.

Independent combined actual SOURCE SPEC then NEW distinct SOURCE QUALITY is
required after qualification and before small local source commits. Follow with
accurate tracked evidence/document synchronization, independent doc SPEC then
NEW distinct doc QUALITY, and a separate local documentation commit. No phase
advancement/default V3 switch based on focused tests or this design. Necessary
failure repairs use Sol; after two failed Sol rounds or evidenced impasse escalate
to Astra with at least three bounded actual attempts available. Design/diagnosis
advice does not count as a repair attempt.
