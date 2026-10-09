# Singularity v0.2 Recovery Qualification Design

Date: 2026-10-09
Status: Qualified locally; independent Astra SPEC and QUALITY reviews clear.
Baseline supplied by parent: `125653e9dbb6d979703360138abf55fb888f2711`,
branch `codex/v0.2-phase-2-import-extraction`, existing `.trees` worktree.
Source inspection below is not live PostgreSQL qualification evidence.

## Purpose and boundary

Close the recovery catalog and rollback coverage gaps in Phase 2 Task 15
Step 1. Characterize existing behavior through the real PostgreSQL functions,
`DocumentRepository`, and `Documents.ExtractionReconciler`. No production
behavior change is authorized by this supplement.

The existing seven-case `document_extraction_reconciler_test.exs` already
covers successful recovery, stale completion, exclusions, startup, concurrency,
revocation, and basic runtime-role EXECUTE privileges. Preserve every existing
assertion. The missing evidence is the live function hardening/UUID return
contract and rollback when successor-event insertion fails after the reset.

Only these files may change:

- `apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs`
- This design and `docs/superpowers/plans/2026-10-09-singularity-v0.2-recovery-qualification.md`.
- Parent-owned `docs/verification/2026-10-09-phase-2-task-15-matrix.md`.

Do not edit production modules, migrations, support helpers, configuration,
dependencies, frozen extraction/restart tests, or the original untracked full-C
plan. No Vault, custody, key, capability-policy, backup, search, or public-import
behavior changes. The existing private `grant_read!/1` fixture convention is
the only authorization setup needed. No service restart, E2E, full README gate,
version bump, merge, push, tag, release, deployment, or production activation.

## Options and decision

1. **Recommended: extend the owning integration file.** Reuse its existing
   schema-only source fixture, owner observation, worker repository, and expired
   attempt setup. This adds two bounded contracts without moving ownership.
2. A new recovery test file duplicates the same setup and splits seven existing
   contracts from their missing security/atomicity assertions.
3. Source-string checks or injected fake failures cannot establish effective
   PostgreSQL privileges or rollback through the actual SQL call.

Standing user approval selects the recommended bounded approach. The parent
must read both complete documents and obtain fresh independent Astra review
before test-only GO. Parent owns all Mix, database/service, Git, and evidence
operations. A real failing contract requires diagnosis and separately reviewed
repair authority; this document authorizes test changes only.

## Contract A: live narrow recovery authority

Inspect these exact function identities in the migrated integration database:

- `content.expired_document_extraction_ids(integer)`
- `content.recover_expired_document_with_event(uuid,uuid)`

For each, assert `pg_proc.prosecdef = true`, owner
`singularity_table_owner`, and exact function-local configuration
`["search_path=pg_catalog, content, core, identity"]`. Check effective EXECUTE
for `singularity_worker` and denial for `singularity_web`,
`singularity_dispatcher`, and `singularity_pre_auth`. Inspect expanded ACLs,
including default ACL fallback, to prove PUBLIC (grantee OID 0) has no EXECUTE;
PUBLIC is not an ordinary role argument to `has_function_privilege`.

The scanner's live catalog return definition must be exactly
`TABLE(version_id uuid, owner_id uuid)`. Execute it through WorkerRepo and
assert exactly the columns `version_id`, `owner_id`; locate the owned expired
fixture and validate both returned UUIDs. Also assert the real repository
returns its canonical text UUID pair. Do not claim a global one-row result
from a test database shared by multiple test cases.

No runtime role gains direct INSERT, UPDATE, or DELETE on
`content.document_versions` or `content.document_fragments`; worker direct
SELECT on both remains denied. Use effective table and any-column privilege
checks so column grants cannot evade the assertion. Established web reads are
not prohibited by this test. Do not redefine unrelated Asset/resource grants.

## Contract B: successor collision rolls back the entire recovery

The committed `20260922000200_document_extraction_recovery.exs` calls
`recover_document_extraction` and then performs an ordinary outbox INSERT.
There is no `ON CONFLICT` clause. The attempts migration resets lifecycle
fields and increments generation; PostgreSQL must roll that update back when
the INSERT violates `(vault_id, idempotency_key)` uniqueness.

Create a real schema-valid source/Document, grant fixture `asset.read`, and
use the existing `claim_expired!/2` to establish expired generation 1. Insert
a complete valid generation-2 `document.extraction_requested` event as table
owner. Use the real creator and owner, live authorization epochs, private
classification, the original job as causation, version as correlation,
`expected_entity_revision = 2`, `envelope_version = 1`, and exactly the two
resource UUID payload fields. Read back the exact fixture event. Do not
disable constraints/triggers, change functions, or invent a different error.

Before calling production recovery, snapshot complete rows, ordered by stable
IDs, for the fixture owner: Documents, resources, resource versions, Assets,
Asset objects, resource-Asset associations, outbox events, fragments, and
`content.asset_search_documents`. Include the source pin count observed by
owner SQL. Full Document rows include all immutable source references/digest/
size and every attempt/terminal field; complete resource rows include current
version and tombstone state. Explicitly assert generation 1, original job,
expired deadline, unset terminal fields, one collision event, no fragments,
and no Document search row before recovery.

Call `DocumentRepository.recover_expired_with_event/3` with real WorkerRepo,
then `ExtractionReconciler.run/1`. After each call require the complete
snapshot to equal the before snapshot: no reset, generation advance, pin
change, lost collision event, added row, fragment, or search projection.
Require the Document still appears in the worker scanner after both failures.
The reconciler must encounter this owned collision; assert scanner membership
before invoking it, and preserve existing eligible-fixture isolation.

The inspected `KnowledgeError.from/1` maps Postgrex `:unique_violation` to
`Error.new(:conflict)`. Therefore the expected adapter result is exactly
`{:error, %Singularity.Core.Error{code: :conflict, message: nil, details: %{},
retryable?: false}}`, not a raw SQL exception or invented storage error code.
Confirm it through the real call. If actual behavior differs, record the
characterization and diagnose before changing the expected contract.

Keep the collision event in place. Create a fresh second Document against the
same source, retain its existing read grant, assign a fresh job UUID, and call
`claim_expired!/2` before taking the control baseline. It must be an expired
generation-1 attempt, not a newly inserted pending generation-0 Document.
This provides the noncollision control through the real repository: first
recovery returns
`{:ok, true}`, repetition returns `{:ok, false}`, and exactly one successor
event has the exact IDs-only payload and correct generation/causation. The
control becomes pending generation 2 with cleared attempt/terminal fields,
while source pins, source rows, and projection state remain unchanged.

## Fixture lifetime and proof limits

The integration runner provides one disposable database per invocation, not
per test. Register `on_exit` immediately after creating each new expired
fixture, before any assertion can fail. Tombstone only that exact Document
resource by its resource and owner IDs after assertions, through established
table-owner fixture SQL. This makes it ineligible for later global scans
without deleting events or changing capabilities. Snapshot equality applies
before cleanup. No broad cleanup or unrelated fixture mutation is allowed.

No fake repository, fake scanner, production grant widening, new custody
fixture, supervised-runtime restart, timing sleep, or background dispatcher is
needed. The existing startup/concurrency tests remain intact. A collision
failure may consume an outbox identity sequence value: assert persisted rows,
not sequence continuity, since PostgreSQL sequences are not transactional.

Run scoped baseline, new characterization, a changed-order repeat, and the
existing Document lifecycle regression through the integration runner. Record
exact source hash, commands, counts/exclusions, exit results, observed database
cleanup, and remaining gaps in the existing matrix. New tests may pass on
first execution because this is evidence-gap qualification, not a required
production behavior change; never manufacture a RED.

Passing this supplement qualifies these bounded contracts only. E2E and the
complete README acceptance gate remain NOT RUN; Task 15 and Phase 2 remain
open. No claim of live source-byte authentication, extractor execution, or
full release acceptance follows from schema-only recovery fixtures.

## Qualification record

Final test SHA-256:
`f652a9e18fb90935799704251e13ff8d80530c772886c2280038eac227e9f39b`.
The final formatted combined/repeat gate executed 37 tests with zero failures.
Compilation, formatting, zero-cycle checks, exact database/root cleanup,
and independent reviews passed. Exact commands, the initial source-projection
harness correction, protected hashes, and proof limits are recorded in
`docs/verification/2026-10-09-phase-2-task-15-matrix.md`.
No production repair, Vault feature work, migration, or publication occurred.
