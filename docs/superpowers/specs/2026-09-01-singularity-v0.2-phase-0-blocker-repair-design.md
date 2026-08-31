# Singularity v0.2.0 Phase 0 Blocker Repair Design

**Status:** Approved

**Date:** 2026-09-01

**Amends:**
`docs/superpowers/specs/2026-08-31-singularity-v0.2-release-design.md`

**Phase plan:**
`docs/superpowers/plans/2026-08-31-singularity-v0.2-phase-0-scope-baseline.md`

## 1. Purpose

The Phase 0 complete verification gate exposed two production-behavior defects
that cannot be repaired under the original documentation-and-contract-only
scope:

1. the classification aggregate cannot be strengthened atomically because an
   immediate composite foreign key rejects every safe update order; and
2. application-owned wake generations are stored in Oban-owned metadata that
   Oban 2.24 legitimately rewrites from the executor's stale snapshot while
   acknowledging a snooze.

This design amendment authorizes the smallest production and schema changes
needed to repair those defects and return Phase 0 to its complete gate. It does
not authorize Phase 1, a public API change, Vault work, a version bump, a push,
a remote workflow rerun, a release, or a deployment.

The original Phase 0 design remains authoritative everywhere this amendment is
silent. In particular, the knowledge-base scope lock, Vault freeze,
application boundaries, privacy rules, fail-closed verification policy, and
release stop conditions remain unchanged.

## 2. Verified failure baseline

The complete local gate reached all unit suites successfully: 1,488 tests
passed with 469 exclusions. Storage integration then ran 639 tests with nine
failures and 248 exclusions. Runtime integration ran 543 tests with no
failures and 465 exclusions. The nine storage failures split into two
independent groups:

- six classification-chain failures caused by
  `resource_versions_resource_classification_fkey`; and
- three wake/snooze failures in `effect_receipt_test.exs` after the resolved
  Oban dependency moved to 2.24.

The minimal reproductions are:

```bash
mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/asset_search_projection_test.exs:553

mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/effect_receipt_test.exs:309
```

These failures are required-gate failures. They may not be skipped, relabeled,
weakened, or replaced with narrower passing checks.

Later complete-gate stages, including restore acceptance, frontend checks,
browser acceptance, dependency-cycle verification, and workflow linting,
remain unproven on this branch until both blocker groups are repaired and the
gate is restarted from the beginning.

## 3. Root-cause decisions

### 3.1 Classification aggregate

The released Notes migration
`20260818000100_create_private_markdown_notes.exs` added the composite foreign
key:

```sql
FOREIGN KEY (resource_id, vault_id, classification)
REFERENCES content.resources(id, vault_id, classification)
```

The constraint correctly requires every resource version to carry the same
classification as its parent resource. However, it is immediate. Updating the
resource first fails while versions still reference the old composite key;
updating a version first fails because the parent still exposes the old key.
The database therefore rejects a legitimate classification strengthening even
when the transaction would finish in a valid state.

Some existing test helpers compound the issue by changing only part of the
aggregate. Those fixtures are not valid evidence for a stronger-classification
chain: an update that leaves the resource and version classifications
different must continue to fail.

The defect is the timing of the equality check, not the equality invariant.

### 3.2 Wake handshake across Oban snoozes

`apps/singularity_storage/mix.exs` declares Oban `~> 2.23`, while the lock
currently resolves Oban 2.24. Oban 2.24 intentionally changes snooze behavior:

- snoozing rolls the current attempt back so a snooze does not consume an
  attempt; and
- the dependency increments a `"snoozed"` counter in the job's `meta` map.

Oban's basic engine computes that metadata from the executor's job snapshot
and writes the full map while acknowledging the snooze. Singularity currently
stores `singularity_wake_requested_generation` and
`singularity_wake_consumed_generation` in the same map. A wake committed after
the executor loaded its job but before Oban acknowledges the snooze can
therefore be overwritten by Oban's valid stale-snapshot write.

The resulting lost-wake race is an application compatibility defect.
Singularity put authoritative application state in dependency-owned storage;
Oban did not violate its contract. No upstream issue or dependency workaround
is warranted.

The old assertions that every snooze increments `attempt` are also no longer a
valid supported-version contract. They must be replaced with assertions for
attempt preservation and the separate Oban-owned `"snoozed"` count.

## 4. Scope authorization

This amendment overrides the original Phase 0 prohibition on production and
schema changes only for the following two repair slices:

- make the existing resource/version classification foreign key deferrable at
  transaction commit, and correct focused fixtures to represent complete,
  valid aggregate transitions;
- move wake requested/consumed generations from Oban metadata to
  `jobs.job_submissions`, adopt Oban 2.24 attempt semantics, and preserve the
  established wake/reconciler behavior.

For Phase 0 acceptance, the original requirement that no production code or
behavior change is replaced only by the requirement that no production code
or behavior change outside these two slices. The forthcoming detailed blocker
repair plan supplements the original Phase 0 file map only for the authorized
surfaces below.

Authorized implementation surfaces are limited to:

- `AGENTS.md`, only to list this approved amendment and express the narrow
  production/schema exception for these two slices;
- new forward migrations under
  `apps/singularity_storage/priv/repo/migrations/`;
- the `JobSubmission` Ecto schema;
- the existing `WakeHandshake` implementation and the smallest necessary
  adjacent job-adapter code;
- the Oban dependency floor in `apps/singularity_storage/mix.exs` and a lock
  change only if dependency resolution actually produces one;
- focused storage migration, classification, wake-handshake, recovery,
  backup/restore, and dependency-contract tests directly affected by these
  changes; and
- the detailed implementation plan and Phase 0 evidence report.

The `AGENTS.md` alignment is the first implementation task and must be
committed before any production or migration file changes. It does not relax
any other Phase 0 restriction.

No released migration may be edited. No unrelated production module, cleanup,
refactor, dependency upgrade, schema redesign, or documentation expansion is
authorized. Every changed line must trace to one of the two verified blockers.

## 5. Slice A: transactional classification strengthening

### 5.1 Schema decision

Add a new migration after the released Notes migration. It will drop and
recreate `resource_versions_resource_classification_fkey` with the same child
columns, parent columns, and constraint name, adding only:

```sql
DEFERRABLE INITIALLY DEFERRED
```

The referenced unique key
`resources_id_vault_classification_key` and the version aggregate unique key
remain unchanged. The constraint remains enforced by PostgreSQL and remains
enabled by default; its validation point moves from each statement to the
transaction commit.

The migration must be reversible. Its down direction may restore the original
immediate form only after PostgreSQL has confirmed that all committed rows are
valid. Because every successful transaction still ends with a valid composite
reference, no invalid committed data is introduced by the up migration.

### 5.2 Aggregate invariant

At every successful commit:

```text
resource_version.resource_id       = resource.id
resource_version.vault_id          = resource.vault_id
resource_version.classification    = resource.classification
```

Temporary mismatch is permitted only inside the transaction that strengthens
the aggregate. A partial transition, divergent resource/version
classifications, or a transaction that exits before completing the pair must
fail at commit and leave the prior state intact.

Assets and asset metadata remain separate classification contributors. They
may be equal to or stricter than the canonical resource/version pair according
to the existing strictest-contributor rules. This amendment does not flatten
all contributors to one value and does not weaken downgrade prevention.

### 5.3 Application behavior

No new classification API is added. Existing focused tests that construct a
stronger chain through SQL must perform the intended resource, version, asset,
and metadata changes inside one transaction and leave a valid aggregate at
commit.

The repair must preserve:

- exact fetch authorization at the strictest contributor classification;
- canonical search rebuild classification;
- rejection of a projection that downgrades a stricter contributor;
- owner-scope and vault isolation; and
- all existing immutable-version and source-binding behavior.

## 6. Slice B: application-owned wake generations

### 6.1 Canonical storage

Add a separate new migration that extends `jobs.job_submissions` with:

```text
wake_requested_generation bigint NOT NULL DEFAULT 0
wake_consumed_generation  bigint NOT NULL DEFAULT 0
```

Add a named check constraint equivalent to:

```sql
wake_requested_generation >= 0
AND wake_consumed_generation >= 0
AND wake_consumed_generation <= wake_requested_generation
```

The defaults keep existing insert paths compatible and initialize submissions
that have no legacy handshake state. The Ecto schema exposes both fields as
integers with matching zero defaults. They are application-owned coordination
data; Oban's `meta`, `attempt`, `state`, and scheduling timestamps remain
dependency-owned.

The same forward migration performs a one-time, fail-closed transfer of legacy
handshake state while Oban workers are stopped. For each submission whose
`runner_job_id` matches an existing GenericWorker job, it derives:

```text
requested = max(
  legacy requested metadata,
  legacy consumed metadata,
  active matching WakeReconciler generations,
  0
)

consumed = max(legacy consumed metadata, 0)
```

Only absent values or base-10 non-negative integers represent valid legacy
state. Values outside the PostgreSQL `bigint` range, malformed Singularity
wake keys, or malformed active matching reconciler generations fail the
migration instead of being coerced. Active reconcilers are those in
`available`, `scheduled`, `executing`, or `retryable`; terminal reconciler rows
do not create pending state. Submissions without a matching target job or any
legacy wake evidence remain at zero.

Including active reconciler generations closes the known stale-metadata case:
if Oban 2.24 already overwrote the target job's generation keys, the durable
reconciler argument still carries the committed requested generation. The
backfill never updates or deletes Oban metadata.

The migration must be reversible for local development. Its down direction
must fail closed unless workers are stopped, every submission has
`requested == consumed`, and no matching reconciler remains in an active Oban
state. Only then may it drop the counters for a disposable/local rollback.
This amendment does not authorize or define a live runtime downgrade.

### 6.2 Locking and ownership boundary

`WakeHandshake.request/4`, `consume/4`, and `reconcile/5` continue to validate
and lock the target Oban job to inspect dependency-owned state. They also lock
the matching `jobs.job_submissions` row and read or write generations only
there.

The established lock order is preserved:

1. lock and validate the target `jobs.oban_jobs` row;
2. lock the matching submission/progress aggregate;
3. read or update the application-owned generation counters; and
4. commit before an external retry or future worker execution observes the
   new state.

No path may update an Oban job's full `meta` map to maintain wake state.
After the one-time migration transfer, historical Singularity wake keys in
`meta` are ignored at runtime; they are neither authoritative nor copied back
after snooze acknowledgement.

### 6.3 Generation protocol

The protocol remains monotonic and bounded by the database constraint:

- `request` computes `max(requested, consumed) + 1` while the submission is
  locked, persists it as requested, and returns that generation with the
  current Oban state;
- `consume` observes one locked snapshot and, when `requested > consumed`,
  advances consumed to requested;
- `reconcile` compares its durable generation argument with the locked
  submission counters and target Oban state, then waits, retries, or closes
  exactly that generation; and
- a generation is never consumed beyond the latest requested generation.

Wake reconciler uniqueness remains keyed by target job and generation. An
executor crash, application restart, Lifeline rescue, repeated wake request,
or concurrent snooze acknowledgement must not create duplicate effective
work or erase a committed request.

### 6.4 Oban compatibility contract

Raise the supported dependency floor from Oban `~> 2.23` to `~> 2.24` without
requesting any unrelated dependency upgrade. The current lock already resolves
2.24, so the change documents and enforces the behavior the test suite and
application support.

After a job begins its first execution, its stored attempt is `1`. After Oban
2.24 acknowledges a snooze, the stored attempt returns to `0`; later snoozes
continue to preserve the attempt budget. Oban records the number of snoozes in
`meta["snoozed"]`. Tests must assert those two contracts independently.

Singularity must not depend on the preservation of unrelated custom metadata
across a snooze. The only supported application state used by the wake
protocol is the state in `jobs.job_submissions`.

## 7. Backup, restore, and upgrade boundary

Wake generations are transient coordination state, not user knowledge data.
The immutable logical backup v1 and v2 schemas retain their current field
lists and do not gain these columns. Restoring a submission through those
formats uses the database defaults of zero for both counters; existing restore
reconciliation remains responsible for rebuilding runnable job state.

This choice must be verified by the existing restore acceptance gate. If a
focused regression reveals that zeroed handshake state violates restore
reconciliation, implementation stops for a new design decision rather than
changing a released backup format silently.

The one-time migration backfill preserves persisted in-flight wake evidence
for a stopped, non-rolling upgrade. It is intentionally distinct from logical
backup restore: an in-place upgrade retains `oban_jobs`, while a logical
restore rebuilds runnable state through restore reconciliation.

The Phase 0 work is local and CI-only. It does not authorize applying either
migration to a live installation. A later release/deployment procedure must
stop Oban workers, run the migrations before starting code that requires the
new columns, and must not run old and new wake-handshake implementations
concurrently. A zero-downtime rolling transfer remains outside this repair and
requires an explicit rollout decision if it is needed.

## 8. Error, privacy, and observability behavior

Both repairs preserve the existing safe error boundary:

- invalid inputs remain `:invalid`;
- conflicting identities or aggregates remain conflicts/integrity failures;
- database write failures remain retryable `:storage_unavailable`; and
- no raw PostgreSQL, Oban, or dependency exception becomes a public error.

The new wake fields contain only non-negative counters. They contain no user
content, secret, key material, identifier beyond the existing submission row,
or caller-controlled metadata. No new log, telemetry, audit, outbox, or job-arg
field is introduced. Existing content-redaction and supported-observability
contracts remain unchanged.

## 9. Test-first implementation requirements

Each slice follows a failing-test, minimal-implementation, passing-test cycle.
The pre-repair focused reproductions above are retained as evidence.

### 9.1 Classification tests

Before implementing the migration, add focused assertions that prove:

- the composite foreign key is deferrable and initially deferred after all
  migrations run;
- a complete resource/version strengthening in either statement order commits
  successfully;
- a partial or divergent strengthening raises at constraint validation/commit
  and rolls back;
- strictest-contributor fetch and rebuild behavior still succeeds; and
- downgrade protection still rejects a weaker projection.

The tests must not disable constraints, defer an unrelated constraint, rescue
away the failed commit, or weaken the expected classification.

### 9.2 Wake tests

Before moving the counters, update/add focused assertions that prove:

- both submission columns default to zero and reject negative or
  consumed-greater-than-requested states;
- a legacy target with stale or absent generation metadata but an active
  durable reconciler backfills the requested generation and remains wakeable;
- valid legacy requested/consumed generations transfer exactly, while
  malformed or out-of-range legacy state fails migration;
- migration rollback refuses pending generations or active reconcilers and
  succeeds only for a quiescent local state;
- request, consume, and reconcile persist/read generations from the locked
  submission rather than Oban metadata;
- a wake committed after the executor snapshot but before snooze
  acknowledgement survives Oban's full metadata write;
- an acknowledged snooze preserves attempt budget and increments Oban's
  `"snoozed"` metadata separately;
- the durable reconciler remains unique per target/generation and closes or
  retries the correct generation;
- executor death before snooze acknowledgement remains recoverable through
  Lifeline/reconciliation; and
- unrelated waiting jobs and the caller's bounded wake limit remain
  unchanged.

### 9.3 Verification sequence

After both focused red-green cycles, run in this order:

1. the two minimal reproductions;
2. the full affected storage test files;
3. focused migration, schema, restore, recovery, and architecture contracts
   touched by the implementation;
4. the complete Phase 0 verification sequence from the canonical release
   directive, restarted from its first command; and
5. independent specification and code-quality review of the exact diff.

The target is zero integration failures, including elimination of all nine
baseline failures. A green focused subset is not Phase 0 completion.

## 10. Commit and review boundaries

The repair should remain reviewable as two behavioral commits after the
approved plan checkpoint:

1. `fix(storage): make classification strengthening atomic`
2. `fix(jobs): preserve wakes across Oban snoozes`

Test-first commits may be retained separately when that makes the red/green
evidence clearer, but classification and wake changes must not be mixed into
one broad refactor. The detailed plan is committed before implementation.

Independent review must verify the database invariants, lock ordering, Oban
ownership boundary, migration reversibility, restore compatibility, privacy
constraints, exact failure coverage, and absence of unrelated changes. Every
Critical or Important finding is resolved and reverified before Phase 0 can be
accepted.

## 11. Alternatives rejected

### 11.1 Pin Oban to 2.23

Rejected because it hides the ownership defect, preserves reliance on
dependency internals, and avoids rather than supports the resolved dependency
behavior.

### 11.2 Reapply custom metadata after Oban snoozes

Rejected because it retains split ownership of one row, still admits races,
and couples application correctness to dependency write timing.

### 11.3 Weaken or remove classification equality

Rejected because resource/version classification equality is a security and
integrity invariant. Only validation timing changes.

### 11.4 Disable constraints in fixtures

Rejected because it would make tests construct states production must reject
and would convert a required security assertion into false evidence.

### 11.5 Change released migrations or backup schemas

Rejected because released history and backup format contracts are immutable.
All database evolution is additive through new migrations, and transient wake
counters are restored through defaults.

## 12. Non-goals and stop conditions

This amendment does not authorize:

- a new classification endpoint or general reclassification workflow;
- a classification hierarchy redesign;
- changes to Notes, Documents, extraction, retrieval, or browser UX;
- Vault feature, schema, policy, command, telemetry, cleanup, or removal work;
- a custom Oban engine, fork, monkey patch, or upstream issue;
- a new logical backup version;
- unrelated dependency updates;
- a version bump, tag, artifact, image, publication, deployment, or remote
  workflow dispatch; or
- any Phase 1 implementation.

Implementation stops and returns for approval if the minimal repairs require a
public API change, a released-backup format change, a different lock order, a
zero-downtime rolling migration, an internal upstream workaround, or
production changes outside the authorized surfaces.

## 13. Acceptance criteria

This amendment is satisfied only when:

- `AGENTS.md` names this amendment and grants only its two bounded exceptions
  before production implementation begins;
- both new migrations exist and no released migration changed;
- committed resource/version rows still have equal owner scope and
  classification, while complete atomic strengthening succeeds;
- partial strengthening fails at commit and downgrade protection is intact;
- wake generations are canonical only in locked `job_submissions` rows;
- valid persisted legacy wake state, including a generation recoverable only
  from an active reconciler, is transferred without normalizing corruption;
- Oban 2.24 snooze attempt and `"snoozed"` behavior is asserted explicitly;
- the snooze-acknowledgement race cannot erase a committed wake;
- crash recovery, reconciler uniqueness, idempotence, and no-lost-wake
  behavior remain green;
- all nine baseline integration failures are eliminated;
- the complete Phase 0 gate, including restore, frontend, browser, xref, and
  actionlint stages, passes from a clean worktree;
- independent review has no unresolved Critical or Important findings;
- no Vault feature work, release action, deployment, or Phase 1 work occurred;
  and
- Phase 0 stops for user acceptance before any merge, push, remote rerun,
  version bump, tag, release, deployment, or next-phase branch.
