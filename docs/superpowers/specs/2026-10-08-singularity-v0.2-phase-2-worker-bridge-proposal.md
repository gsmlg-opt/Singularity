# Phase 2 Document worker bridge proposal

**Status: proposed, not approved.** This document grants no implementation,
migration, production activation, merge, push, tag, release, or deployment authority.

Date: 2026-10-08. Source inspected at
`e866990fc0ee8682d139d70da9cbf5aff9b2ae2b` on
`codex/v0.2-phase-2-import-extraction`. The reviewed contract repair is now on
main and origin/main at that same revision; this unapproved proposal is separate.

This is a proposed narrow amendment to Task 12 of the
[approved Phase 2 plan](../plans/2026-09-22-singularity-v0.2-phase-2-import-extraction.md)
and its [design](2026-09-22-singularity-v0.2-phase-2-import-extraction-design.md).
The [contract-repair record](../../verification/2026-10-08-phase-2-contract-alignment.md)
records the prerequisite repair, not worker or phase acceptance.

## 1. Problem and decision

The planned worker cannot compose the current repositories under its production
database role. `WorkerScope` uses `WorkerRepo`, which is deliberately denied
canonical Document table reads and raw lifecycle execution. The current pinned
source and Document repositories directly read those rows and hydrate complete
`DocumentVersion` values. Fixture-only grants do not establish live composition.

Choose a separate `DocumentWorkerRepository` adapter backed by four worker-only
security-definer entrypoints. Return bounded descriptors and receipts, not full
canonical records. The existing Document lease remains the only source-plaintext
acquisition path; extraction and completion subsequently handle that bounded text.

| Approach | Trade-off |
| --- | --- |
| Separate worker adapter and bounded receipts — recommended | Preserves public repository types and limits database output; adds one adapter. |
| Wrappers returning complete DocumentVersion values | Keeps Task 12's original success type but exposes unnecessary title/fragment content on replay. |
| Role-dependent results from the existing repository | Avoids a separate adapter but changes the meaning of existing public callbacks and callers. |

Broad SELECT grants, RequestRepo substitution, fabricated DocumentVersion fields,
and direct grants on existing lifecycle functions are not acceptable alternatives.

## 2. Scope and unchanged boundaries

The amendment would authorize only a forward migration, the worker adapter and
its focused storage tests, and Task 12's already-planned Runtime worker/wiring/tests.
It would change Task 12's success type to a typed worker receipt and move its
planned `record_exhaustion/4` method to the worker adapter.

Public `Documents.Repository` callbacks, public DocumentVersion reads,
`DocumentPinnedSource.load_live`, browser routes, GenericWorker normalization,
existing Asset leases, and canonical table grants stay unchanged. Existing
migrations are not edited. No Vault file, key/capability policy, unlock behavior,
source retention, backup format, search projection, or later phase changes.

Legacy `vault_id` fields and GUCs remain opaque authenticated owner-scope encoding.
No new API accepts a caller-selected owner or principal identity.

## 3. Four SQL entrypoints

All signatures share six leading parameters, abbreviated `B`:

```text
requested_resource uuid,
requested_version uuid,
requested_job uuid,
expected_revision bigint,
requested_principal_epoch bigint,
requested_owner_epoch bigint
```

Their exact existing envelope mapping is:

| Parameter | Envelope field |
| --- | --- |
| requested_resource | payload["resource_id"] |
| requested_version | payload["resource_version_id"] |
| requested_job | job_id, which is core.outbox_events.id, not the Oban runner ID |
| expected_revision | expected_entity_revision, the generation before claim |
| requested_principal_epoch | principal_authorization_epoch |
| requested_owner_epoch | vault_authorization_epoch |

Oban delivery `attempt` is a runner counter and `max_attempts` its retry budget,
not Document generation or `expected_entity_revision`. Neither is a SQL fence.

```text
content.describe_document_worker(B)
content.claim_document_worker(B, adapter text, format integer)
content.complete_document_worker(
  B, claimed_generation bigint, adapter text, format integer, media_type text,
  fragments jsonb, extracted_digest bytea, language text)
content.fail_document_worker(
  B, claimed_generation bigint, adapter text, format integer, media_type text,
  outcome text, failure_code text)
```

Use explicit RETURNS TABLE columns, never a canonical composite row or
`to_jsonb(document)`. Required parameters cannot use nullable bypass values.

Return allowlists:

- Describe: kind (`source` or `terminal`), Document resource/version/job UUIDs,
  state, and attempt generation. A source result additionally contains object
  UUID, object key generation, source SHA-256, source byte size, media type, and
  nullable attempt adapter/format/start/deadline. All these additional columns
  are NULL for a terminal result.
- Claim: resource/version/job UUIDs, generation, extracting state,
  adapter/format, start, and deadline.
- Complete/fail: resource/version/job UUIDs, generation, and terminal state.

No title, source Asset identity, bytes, wrapped keys, locators, fragment text, or
arbitrary error details are returned. The adapter decodes closed state/kind
allowlists and declares exact descriptor/attempt/outcome types. It never creates
a partial DocumentVersion or widens public repository return types.

## 4. Authority, events, and privileges

Each entrypoint independently validates scoped identity from
`singularity.principal_id` and `singularity.vault_id`; there are no principal or
owner override parameters. Reject absent/malformed scope. Require a live owner
principal, active account and membership, nonrevocation, private-or-higher
clearance, `asset.read`, and exact nonnegative current authorization epochs.
Use `core.live_principal_authorization()` as the scoped authority snapshot.

Keep the existing trusted application boundary: GenericWorker decodes the durable
envelope and establishes WorkerScope before the handler runs. WorkerScope supplies
the checked-out WorkerRepo handle and a ScopedRepo transaction closure bound to
that envelope. ScopedRepo checks for absent prior context and sets normalized
UUIDs with transaction-local `set_config(..., true)`. It checks context absence
after normally returned commit or rollback; exceptional exits rely on
transaction-local cleanup and do not run that post-return assertion.
The adapter uses this trusted handler context; request inputs
and job payloads cannot supply scope, repository handles, or transaction callbacks.
Preserve GenericWorker's reserved dependency-key rejection and
prove context cleanup on both commit and rollback. Custom GUCs are not credentials:
this does not protect against an actor already able to execute arbitrary SQL as
the worker role or replace trusted application code. The SQL predicates instead
check the scoped identity against live authority and the retained event binding.

Follow `Authorize.check_job/3` authority semantics: **do not require a session,
custody, or `vault_locked=false` for metadata or outcome operations**. That
function does not check unlock. Do not reuse `document_runtime_target` or
`document_custody_binding` as metadata authority predicates: their request/byte
access checks are different. Byte access continues to require the unchanged
Document lease and its session, unlock, expiry, and per-chunk checks.

Bind a real retained outbox event to all six parameters and the scoped identity:

- Event ID equals requested_job; owner and principal equal scope.
- Event type is `document.extraction_requested`, capability `asset.read`,
  classification private, and envelope_version exactly 1.
- Both event epochs equal the supplied and current epochs.
- Event revision equals expected_revision; payload equals exactly the two
  requested UUIDs, without additional keys.
- Revision zero uses `document-extraction:<version>`; positive revision n uses
  `document-extraction:<version>:<n>`.
- Document/resource/version/owner/private classification match, including the
  Document creator binding already required by custody.

Delivery timestamps are not proof of authority and do not invalidate a
legitimately delivered job. Runtime still performs the complete existing
envelope/codec validation; SQL independently enforces its durable binding.

Each exposed function is owned by `singularity_table_owner`, uses the fixed trusted
search path `pg_catalog, content, core, identity` and qualified relations/functions,
revokes EXECUTE from PUBLIC, web, dispatcher, and pre-auth roles, and grants it
only to singularity_worker.
Private helpers are ungranted. Existing table ACLs, RLS, raw lifecycle ACLs, and
function definitions remain unchanged.

## 5. Locks, snapshots, and transaction boundaries

All four wrappers are explicit VOLATILE PL/pgSQL functions. Before any authority
query or lifecycle helper, acquire `pg_advisory_xact_lock_shared` with the existing
exact identity:

```text
hashtextextended(
  'singularity:authorization:' || scoped_principal::text || ':' || scoped_owner::text,
  0)
```

Use separate lock and authorization statements under READ COMMITTED. The adapter
owns a short scoped READ COMMITTED transaction per call on the checked-out
WorkerRepo handle, rejects nesting in an existing transaction, and keeps existing
WorkerScope locks. SQL entrypoints reject other transaction isolation levels.
Do not load authority or invoke a row-locking helper in a DECLARE initializer.
For mutations, lock resource before version, then recheck binding and fences.

A lock acquired after a repeatable-read snapshot does not refresh that snapshot.
READ COMMITTED plus a volatile wrapper permits a fresh authority query after a
lock wait; this rule must be tested, not inferred from advisory-lock presence.
See PostgreSQL 17's [snapshot rules](https://www.postgresql.org/docs/17/transaction-iso.html)
and [function volatility](https://www.postgresql.org/docs/17/xfunc-volatility.html).

Do not hold a PostgreSQL transaction during ciphertext reads, digest computation,
or external extraction. The new SQL surface does not alter authorization
invalidation or existing owner-lock behavior.

## 6. Describe, claim, and resume

Describe returns source metadata only for:

- A live pending Document at generation n = expected_revision.
- An extracting Document owned by this job at generation n+1 with a future DB
  deadline. It may be tombstoned because this is already-claimed work.

Require an available same-owner pinned object, matching source/object size in
0..64 MiB, a 32-byte digest, one of the three approved media types, and exactly
one active matching key-generation binding. Read this source tuple consistently;
the existing lease independently revalidates it before and during delivery.
No Asset-liveness requirement is added. For a terminal result, require the same
job and generation n+1, where n is the event's expected_revision, and return only
its terminal receipt; do not obtain a lease or reread source bytes.
Stale/expired/unrelated jobs and deleted-before-claim Documents yield no source.

Guard bigint arithmetic before computing n+1. For a new pending claim, delegate
to the existing claim function only after event/authority checks. For resume,
use the existing terminal lock, recheck job/generation/adapter/format/deadline,
and return the existing attempt unchanged. Do not extend its deadline.

Resume cannot simply delegate to existing claim: that function calls its
live-only lock before reaching its resume branch, so it rejects a tombstone.
The new wrapper handles matching resume without replacing the old function.
Deletion between reading source and first claim must prevent that claim.

## 7. Completion, failure, and exhaustion

Under the existing tombstone-safe terminal lock, require exact durable event,
claimed generation n+1, adapter, format, and media type. Delegate terminal
validation/persistence to existing complete/fail internals, then project only
the receipt. Preserve canonical fragment validation, all-or-nothing persistence,
job/generation/deadline fences, and exact-ready completion replay. A conflicting
replay fails; a different or recovered attempt cannot write either outcome.
Before serialization, the adapter validates DocumentCompletion and compares its
resource/version/owner/classification/generation and extraction metadata with
the authenticated envelope, scope, and attempt. It rejects mismatches rather
than silently replacing completion identity with the SQL target's identity.

The worker adapter's `record_exhaustion/4` describes the bound job without a lease
or plaintext read. Only a matching unexpired extracting attempt at n+1 proceeds
to the same fail wrapper with fixed `failed` / `extractor_failed`. The fail
wrapper repeats the fence under lock. Pending, terminal, expired, recovered,
and other-job attempts remain unchanged; there is no fifth SQL entrypoint.
Only a recognized state conflict becomes unchanged. Do not swallow authority
or storage failures.

Preserve GenericWorker's existing terminal dispatch: it calls `handle_failure/4`
for a typed nonretryable error immediately, or for a typed retryable error when
integer `attempt >= max_attempts` with positive max_attempts. Earlier retryable
errors do not invoke the recorder. A snooze is not an error and never enters that
path; the existing wake handshake may shorten 60 seconds to 1 second without
claiming or failing a Document. Oban 2.24's Basic engine restores the consumed
attempt on acknowledged snooze and leaves max_attempts unchanged. The Document
clause delegates to the adapter only
from this terminal callback; it does not equate runner counters with generation
or introduce another exhaustion trigger. Tests must cover both terminal cases,
nonterminal retry, and snooze, while leaving GenericWorker unchanged.
This hook covers typed returned errors, not arbitrary process death or a raised
or thrown handler error caught by GenericWorker's outer fallback. Those can leave
a claimed attempt for the already-planned deadline reconciler to recover. A
recorder error does not extend Oban's attempt budget; do not promise otherwise.

## 8. Runtime composition and sanitized outcomes

Preserve the approved five-stage worker, adding only its missing storage bridge:

1. Strict envelope validation and `Authorize.check_job/3`; describe the job.
   Return a terminal receipt immediately for duplicate terminal delivery.
2. Acquire the existing Document lease; read/authenticate at most 64 MiB and
   compare the pinned digest before claim. Locked custody snoozes 60 seconds
   without generation change. Digest mismatch leaves pending, with a sanitized
   integrity failure and no extractor invocation.
3. Claim or resume the exact attempt through the worker adapter.
4. Extract using the approved PDF, Markdown, and text adapters outside a DB
   transaction, preserving their limits and cleanup behavior.
5. Build DocumentCompletion, persist complete/fail atomically, and return the
   typed receipt. Post-claim failure uses only approved outcome/reason codes.

No content enters errors, logs, telemetry, audit metadata, outbox, or Oban args.
Database errors use existing sanitized mappings, never raw diagnostic/parameter
text. No failed attempt leaves fragments or search rows. GenericWorker remains
unchanged; its existing success normalization accepts `{:ok, receipt}`.

## 9. Proposed file boundary

After approval and a detailed implementation plan, the narrow additions are:

- New forward migration `20261008000000_document_worker_bridge.exs`; recheck
  timestamp uniqueness before creation. No migration with this timestamp was
  present during this proposal's source inspection.
- New storage adapter `postgres/document_worker_repository.ex` and focused
  `postgres/document_worker_repository_test.exs` under their existing application
  source/test roots.
- Task 12's existing planned Runtime `documents/extract.ex`,
  `document_extraction_job_test.exs`, `job_dispatcher.ex`, and `application.ex`.
- Approved Phase 2 design/plan amendments and only the architecture-contract
  additions needed to permit this exact approved worker wiring.

Do not add `record_exhaustion/4` to public DocumentRepository. Do not change
GenericWorker, custody adapters, existing migrations, or public API types.

## 10. Required evidence after implementation

Use actual WorkerRepo privileges with no temporary canonical/lifecycle grants:
fixture creation may use a separate administrative connection, but never grant
the worker temporary access or use that connection for the verified calls.

- Verify owner, fixed search path, VOLATILE category, exact ACLs, denied raw
  lifecycle execution, and denied canonical SELECT/INSERT/UPDATE/DELETE.
- Reject malformed scope, cross-owner/resource/version, revoked or inactive
  identity, insufficient clearance/capability, stale epochs, forged event fields,
  extra payload keys, wrong version/key/revision, and bigint overflow.
- Prove the adapter uses the envelope-bound worker transaction closure, rejects
  request/job-payload scope/handle/callback overrides, and leaves no scoped GUCs after
  commit or rollback on the reused connection.
- Prove exact return-column allowlists and NULL source columns for terminal
  receipts; no title, fragments, keys, or bytes escape the bridge.
- Prove fresh post-wait authority after concurrent revocation under the shared
  advisory lock; reject repeatable-read/serializable calls without mutation.
- Run describe → lease → digest → claim → complete after source Asset deletion;
  include a legitimately delivered outbox event.
- Prove locked custody snoozes without claim, preclaim digest rejection,
  same-job resume without deadline reset, source-read/first-claim deletion race,
  and completion/failure after deletion of an already-claimed Document.
- Race recovery/retry/restore against stale claim/completion/failure/exhaustion.
  Prove active-current-attempt-only exhaustion and unchanged terminal/pending/
  expired/recovered attempts.
- Prove ready replay, conflicting replay rejection, bounded fragment validation,
  atomic rollback, and no partial fragments or search rows on failure.
- Capture application logs, telemetry, and public errors across failures to
  prove no content/tool output/SQL parameters leak. Keep Asset worker regressions.

Use the scoped integration alias for integration-tagged bridge tests and the
approved Task 12 Runtime regressions. A new detailed plan must give exact commands
and file ownership. Full Phase 2 acceptance still requires the complete README
gate. E2E remains unrun under the user's restriction; that restriction does not
waive the acceptance requirement. No release readiness is implied.

## 11. Approval requested

Approve together: the four worker-only SQL entrypoints and forward migration,
the separate bounded adapter, and Task 12's receipt-return/exhaustion-placement
amendments. This proposal is not approval of a migration or implementation.
Until explicit approval, retain the current permissions and stop affected
production implementation; independent already-approved work may continue.
