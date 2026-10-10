# Singularity v0.2 Phase 3 — Unified lexical retrieval and source provenance

## Status and authority

Approved by the user on 2026-10-09 after review of proposal commit
`7a9a32a0607b80c11c4aea0a156169325d543b94`. Approval authorizes this bounded
Phase 3 design and its [detailed implementation plan](../plans/2026-10-09-singularity-v0.2-phase-3-unified-lexical-search.md).
It is not implementation acceptance or production activation. The user's
2026-10-10 [continuous development authorization](../../../AGENTS.md#continuous-development-authorization--2026-10-10)
now permits necessary in-scope design amendments, plans, repairs, verification,
independent review, local commits, and later phase development without routine
approval waits. Phase dependencies and required acceptance gates remain;
publication, deployment, E2E, production data, and Vault restrictions are unchanged.

The [2026-10-10 guarded search-index amendment](2026-10-10-singularity-v0.2-phase-3-search-index-repair-design.md)
addresses the executed selective-index failures. Its candidate-ID authority and
test-only nested-plan observation require their own implementation evidence;
independent design review is not a passing search gate.

The governing scope is [Phase 3 of the release plan](../plans/2026-08-31-singularity-v0.2-release.md#phase-3--unified-lexical-retrieval-and-source-provenance).
The base is the [qualified Phase 2 acceptance](../../verification/2026-10-09-phase-2-acceptance.md):
tested source `c34935a112a2b4b807ed741e8e67e44d4e63eafe`, followed by the
documentation-only handoff `ff703bd710074738b0391bb2f29d585dc6166d5c`.
The proposal lives on `codex/v0.2-phase-3-search-design`, in the project-local
`.trees/v0.2-phase-3-search-design` worktree based on that handoff, not on an
assumption that Phase 2 has already been merged into `main`.

Phase 2's unresolved initial-login-mount race and host/image Poppler version
difference remain qualified risks. They are not repaired, waived, or expanded
into this search phase. No Vault feature work, production activation, merge,
push, version bump, tag, release, image publication, or deployment is included.

## Goal and boundaries

Provide one authenticated PostgreSQL search surface over live current Notes
and ready Document fragments. Every result must resolve to its exact immutable
source, even if the current head changes after the search. Deleting projections
must lose no canonical knowledge and rebuilding must reproduce the same
visible results once canonical activity is quiescent.

Included:

- An additive unified search projection, FTS and trigram indexes, and the
  database extension prerequisite.
- Typed search query, result, page, and exact-source selector contracts.
- Kind and canonical tag-membership filters, without tag mutations.
- Note and Document lifecycle reconciliation, narrow worker authorization,
  and deterministic one-resource/full-owner maintenance.
- The minimum V1/V2 derived-projection restore compatibility hooks.
- Scoped regressions and the complete existing README gate before accepting
  implemented Phase 3.

Excluded: Phase 4 attachment/citation/source-set writes, tag mutations,
relationships/backlinks, V3 backup, new browser pages, rich snippet rendering,
semantic search, Qdrant, embeddings, OCR, extraction changes, and every other
release exclusion. No new capability, custody, key, or Vault policy is added.
The seven-application dependency graph remains unchanged.

## Architecture choice

Use a new `content.search_entries` projection. Keep the existing Notes and
Asset search APIs, tables, DTOs, cursor formats, and query behavior intact.

| Approach | Benefit | Cost and decision |
| --- | --- | --- |
| Additive unified projection | One ranking, provenance, pagination, and rebuild contract; legacy consumers remain unchanged | Duplicates derived Note text while both surfaces exist; recommended |
| Query a union of old Notes and new Document projections | Less duplicated Note text | Couples two projection/grant/query contracts and complicates consistent ranking and maintenance |
| Replace the existing Notes projection | Avoids transitional duplication | Unnecessary migration and compatibility risk for existing Notes callers; rejected for this phase |

Core owns pure source-selector values, persistence ports, and the versioned
shared ranking-policy value. Retrieval owns query/result/page validation.
Storage owns SQL, indexes, RLS, canonical reconciliation, and cursor encoding.
Runtime owns
authenticated composition, durable event dispatch, maintenance, and public
DTO conversion. Web continues to call only `Singularity.Runtime.Api`; no
Phase 3 page or direct storage access is added.

## Existing contracts that constrain the design

Source inspection at the base established these seams; these are not fresh
runtime-test claims:

- `NoteRepository` maintains `note_search_documents` synchronously with
  canonical mutations. Its current-head FK requires removal before changing
  the head. Competing conflict versions never become normal search content.
- Existing Note repair jobs contain only a resource ID, require `note.write`,
  and reconcile current canonical state rather than event-era content.
- Documents currently emit only `document.extraction_requested`. Ready
  completion, deletion, and ready restoration have no projection events.
- A ready Document can finish after tombstoning. Ready delete/restore cycles
  do not increment its extraction generation or immutable version revision.
- Worker roles cannot SELECT Document versions/fragments. The accepted
  extraction bridge is a retained-event-bound definer returning a closed
  source/receipt descriptor, not searchable text.
- Web can SELECT Document versions/fragments under forced owner RLS. Tags
  and resource-tag memberships currently deny all runtime table privileges.
- Existing Note/Asset search uses `simple` FTS only. No repository extension
  bootstrap currently installs `pg_trgm`.
- Existing restore reconciliation rebuilds Asset and legacy Note projections,
  not a unified projection. V1/V2 cannot represent Documents or tags; the
  accepted backup guard refuses such canonical inventories.

Primary implementation seams are the Storage `note_repository.ex`,
`note_projection_reconciler.ex`, `document_repository.ex`, and
`document_worker_repository.ex`; Runtime `operation_scope.ex`,
`outbox_dispatcher.ex`, and `job_dispatcher.ex`; and the forward migrations
`20260922000100_document_extraction_attempts.exs`,
`20260922000300_document_runtime_mutations.exs`, and
`20261008000000_document_worker_bridge.exs`. Those migrations are evidence,
not files to edit: all Phase 3 database changes use new forward migrations.

## Projection identity and visibility

One live current Note contributes one entry containing its immutable title
and Markdown snapshot. A live current ready Document contributes one entry
per immutable canonical fragment, with the Document title and fragment text.
Several results may therefore belong to the same Document. Grouping them into
one UI card is not part of this retrieval contract.

Each entry contains:

- Authenticated owner-scope encoding and private classification.
- Resource kind, resource ID, exact resource version ID, and deterministic
  entry ID: `note:<version UUID>` or `document:<fragment SHA-256 hex>`.
- A nullable fragment ID: absent for Notes, mandatory for Documents.
- Source ordinal: zero for the whole Note, canonical ordinal for a fragment.
- Title and body search material copied from that exact canonical source.
- Immutable generic-version `inserted_at` as `source_inserted_at`.
- Validated source locator and projection format version `1`.
- Generated weighted `simple` FTS vector; title has weight A and body D.

The Note locator is the existing Markdown whole-source locator with an empty
`heading_path` and no line range. It identifies the immutable Note body, not
an invented canonical Document fragment. Document locators are copied exactly
from the canonical fragment and revalidated on source resolution.

The table has a composite immutable-version FK binding resource, version,
owner, and classification. Conditional typed references additionally bind
Notes to their typed Note snapshot and Documents to their exact canonical
fragment. Kind/nullability/entry-ID checks prevent cross-kind shapes.
A nullable Note-only version reference must equal the common version ID for
Note rows and be NULL for Document rows; its composite FK targets
`note_versions`. The nullable fragment reference is NULL for Notes and required
for Documents; its composite FK includes the common version/resource/owner
identity. Do not place an unconditional FK from the common version column to
`note_versions`, which would reject Document entries.
Uniqueness permits only one projected Note entry per resource and one entry
per Document fragment. No rebuild-generated random ID or wall-clock timestamp
participates in ranking or equivalence evidence.

Do not add a universal current-head FK to this asynchronously repairable
table. Preserve the legacy Note projection's stronger FK unchanged. Every
unified search statement independently joins canonical rows and requires:

1. Matching authenticated owner, private classification, kind, and exact
   immutable source binding.
2. A non-tombstoned resource whose current version equals the entry version.
3. For Documents, a ready typed version and the matching canonical fragment.

These conditions also apply to counts, candidate selection, and pagination.
A stale projection may cause a temporary omission, never visibility of a
deleted, historical, cross-owner, non-ready, or competing-conflict source.

## Query, ranking, pagination, and result contract

Add `Api.search_knowledge(session, params)` and its injected-runtime test seam.
Accepted public fields are exactly `q`, `kind`, `tag_ids`, `limit`, and
`cursor`, with existing atom/string duplicate-key validation conventions.
No owner, Vault, classification, raw SQL, ranking, or timeout input is accepted.

- `q`: valid UTF-8 without NUL, at most 1,024 bytes before trimming; default empty.
  No accent folding or Unicode normalization guarantee is introduced.
- `kind`: `:all`, `:note`, or `:document`, or their exact lowercase strings;
  normalize through a fixed allowlist. Default `:all`; never intern user atoms.
- `tag_ids`: a list of at most 20 canonical UUIDs before deduplication/sorting; default
  empty. All requested tags must be assigned to the resource (AND semantics).
- `limit`: integer 1–50, default 20.
- `cursor`: absent or a nonempty bounded token, at most 2,048 bytes.

Unknown fields and malformed or conflicting values fail before repository
work. Unknown/cross-owner tag IDs yield no matches without revealing whether
the tag exists. Filtering uses owner-bound canonical `EXISTS` joins to
`tags`/`resource_tags`, not copied tag sets. It does not expose tag labels or
enable tag creation/assignment. Future Phase 4 tag writes consequently need
no search-projection event to make filtering reflect committed membership.

### Search policy version 1

The new API accepts plain text, not a query language. Use
`plainto_tsquery('simple', q)` for FTS. Quotes, minus signs, and `OR` do not
introduce operators in this new contract. Existing `search_notes` retains
its established `websearch_to_tsquery` behavior.

For nonempty `q`, the candidate set is the union of:

- Matching weighted FTS entries.
- Case-insensitive literal substring matches in title or body. Escape
  backslash, percent, and underscore before binding the LIKE pattern.
- Title trigram similarity matches at fixed threshold `0.3`, only when the
  query has at least three Unicode code points.

The literal branch ensures CJK and one-/two-character matching does not
depend on FTS tokenization. GIN `gin_trgm_ops` indexes on title and body
support eligible substring and title-similarity searches. The threshold is
set transaction-locally, not inherited from a mutable connection default.
All branches use the same canonical visibility and tag predicates before
the final ordered `limit + 1`; no arbitrary candidate cap may discard matches.
An entry matching several branches appears once, with one combined rank;
deduplicate by entry identity before pagination, not after applying the limit.

Use an integer ranking score, calculated once in SQL and reused unchanged
for ordering, the returned rank, and cursor comparison:

```text
F = floor(1_000_000 * ts_rank_cd(weighted_vector, plain_query, 32))
    for an FTS match, otherwise 0
T = floor(1_000_000 * similarity(title, q))
    for an eligible title-similarity match, otherwise 0
L = 1_000_000 for a literal title/body substring match, otherwise 0
rank = 4 * F + 2 * T + L
```

The SQL conversion produces a finite integer in `0..7_000_000`; no floating
point value crosses the cursor boundary. This is a fixed lexical relevance
policy, not a probability or relevance percentage. For empty `q`, skip all
text predicates, return all eligible entries, and use rank zero.

Order by rank descending, `source_inserted_at` descending, resource UUID
ascending, version UUID ascending, ordinal ascending, then entry ID ascending
with deterministic bytewise text ordering. Indexes also cover owner/kind and
canonical recency. Rebuilding or restoring an unchanged source does not alter
its recency, score, identity, snippet, or locator.

Trigram indexing is not a guarantee of selective one-/two-character queries:
patterns without extractable trigrams can scan the index. Query-plan tests
must distinguish selective FTS/trigram cases from that explicit short-query
limit. Search statements have a fixed five-second database deadline; timeout
returns a sanitized retryable storage error, never a falsely complete empty
page. This is a resource bound, not a performance SLA. See the PostgreSQL 17
[trigram index documentation](https://www.postgresql.org/docs/17/pgtrgm.html#PGTRGM-INDEX)
and [text-search ranking documentation](https://www.postgresql.org/docs/17/textsearch-controls.html#TEXTSEARCH-RANKING).

### Results and cursor

`SearchPage` contains only bounded `items` and nullable `next_cursor`.
Each result contains kind, resource/version IDs, nullable fragment ID,
title, snippet, locator, immutable source timestamp, and integer rank.
Internal validation additionally checks owner, classification, entry identity,
and ordinal before stripping internal fields from the public DTO.

The snippet is the first at most 160 Unicode code points of that source body,
at most 640 UTF-8 bytes. It is plain text, not HTML or highlighted markup.
It need not contain the matching term; search eligibility still uses the full
body. No full body, digest, storage path, key, query text, or tag label is
added to a summary. Exact-source reads supply content separately.

Use a new versioned HMAC cursor domain, distinct from legacy Note and Asset
cursors, with the existing minimum-32-byte audit fingerprint secret. A keyed
filter fingerprint binds derived owner, private classification, normalized
query fields, sorted tag IDs, and search-policy version. The signed envelope
contains only that fingerprint and the complete ordering tuple. It contains
no plaintext query/title/body/locator; `limit` may change between pages.
Validate exact keys, MAC, bounds, timestamps, UUIDs, entry identity, and filter
binding before SQL. Old, forged, cross-owner, or filter-mismatched cursors
return `invalid`, not an unfiltered first page.

Pagination is deterministic over an unchanged eligible set, not a frozen
cross-request snapshot. Concurrent head or tag changes may alter membership
between pages. Every page reauthorizes and rechecks canonical visibility.

## Exact immutable source resolution

Add `Api.resolve_search_source(session, selector)`. The selector contains
exactly kind, resource ID, resource version ID, and nullable fragment ID with
the same branch rules as a result. It accepts neither owner nor caller-supplied
locator, text, filename, digest, or storage coordinates.

Authorize for the selected kind before reading content, then verify the kind
and entire identity against canonical storage in one scoped read. A mismatched
kind/version/fragment, another owner, tombstone, or absent source returns
`not_found`; malformed selectors return `invalid`. Live authorization failures
retain existing sanitized authorization errors. The projection need not exist.

For Notes, reuse exact immutable Note-version retrieval; return that title and
Markdown plus the whole-source locator, never the newer current head. For
Documents, add an exact version/fragment canonical read returning its title,
fragment text, ordinal, and original locator, requiring ready state and a
live parent resource. Do not implement it through the current-only Document
listing or by following the current head. Historical exact resolution remains
separate from normal current-only search.

This use case resolves text provenance. It does not replace the Phase 2
original-download protocol, expose storage bindings, acquire new custody, or
add a new historical binary-download API. A future UI must not label a
current-only download as the historical source of an older result.

## Transactional projection maintenance

Use one private canonical reconciliation implementation with separate,
narrow authorization entrypoints. Callers provide identifiers, never title,
body, locators, fragments, or arbitrary SQL. Reconciliation locks and rereads
canonical state, atomically replaces only that resource's entries, and deletes
all its entries if it is tombstoned or otherwise ineligible.

### Notes

Create, canonical save, merge, tombstone, and restore reconcile both Note
projections inside the existing mutation transaction. Preserve the legacy
delete-before-head-change sequence. Conflict-only saves retain their current
semantics and do not project the competing version. A projection failure
rolls back the owning mutation; the existing idempotency receipt contract
must not report success for a partially projected transaction.

The owning path acquires the resource row `FOR UPDATE` before invoking either
projector. Apply that order to the existing Note repair job too; do not let two
reconcilers first hold the legacy `FOR SHARE` lock and then contend to upgrade
it when maintaining the unified table.

Existing `note_projection` jobs repair both projections from current canonical
state, retaining their `note.write` authorization and existing event identity.
Adding projection maintenance must not newly require `note.read` for a writer.

### Documents

New forward migrations add transactionally emitted, identifier-only
`document.ready`, `document.deleted`, and `document.restored` events.
Payloads contain resource and exact version IDs only. The owning functions
retain every Phase 2 state, receipt, digest, lease, and authority check.

- First transition to ready persists fragments, ready state, and ready event
  atomically. Exact terminal replay emits no second event.
- Actual deletion marks the tombstone, removes unified rows synchronously,
  and inserts its event in the same transaction. Repeated deletion is a no-op.
- Actual restoration emits a new event. A ready version becomes searchable
  after reconciliation; pending outcomes continue the existing extraction
  scheduling. Repeated restoration is a no-op.

Generate a fresh event UUID for each actual locked transition and use
`document-projection:<event UUID>` as the unique idempotency key. Repeated
delivery reuses that retained row. Never deduplicate lifecycle transitions
solely by resource version, revision, or extraction generation: repeated
delete/restore cycles reuse those values.

The handler always reconciles present canonical state. A ready event arriving
after deletion cannot resurrect content; a delete event arriving after
restoration rebuilds the currently eligible version. A terminal ready receipt
alone does not prove current search visibility. Event revision is an exact
retained-envelope check, not a demand that the present head still equal the
event-era revision.

Preserve any established outer compatibility lock. Within it, use explicit
lock order: existing shared authorization lock, resource row, Document-version
row where needed, then projection writes. The forward migration must express
this same order in the existing Document runtime
target helper without changing its authorization semantics. No external
extraction, filesystem operation, or whole-owner sweep occurs while holding
one resource transaction open.

## Permissions, jobs, and privacy

Use existing `OperationScope` authorization, deriving the owner from
authenticated runtime context. No new capability or owner selector is added.
Preserve the existing read boundaries: Note reads require an unlocked session;
Document canonical-text reads use the accepted `requires_unlocked?: false`
boundary. Mixed reads/maintenance include the Note unlock requirement. None
of these operations performs a login, unlock, or custody transition itself.

| Boundary | Required authority |
| --- | --- |
| Note-only search/exact read/manual rebuild | Existing `note.read` |
| Document-only search/exact read/manual rebuild | Existing `asset.read` |
| Mixed search or full mixed maintenance | Both, conjunctively; no silent partial result |
| Synchronous Note mutation/existing repair job | Existing `note.write`, unchanged |
| Document projection worker | Existing `asset.read` plus exact retained-event binding and live authority |

Grant web SELECT on `search_entries`, `tags`, and `resource_tags` under forced
owner RLS. Keep tag mutations and all direct runtime writes to the new
`search_entries` table denied. Existing web/worker DML grants on the legacy
Note projection remain unchanged.
Workers retain direct SELECT/DML denial on Document versions/fragments and
receive no new projection or tag SELECT grant. Preauthentication and dispatcher
roles receive no content read or projection-write access.

The worker-only projection definer has a fixed trusted search path, table-owner
ownership, explicit EXECUTE ACL, and no PUBLIC grant. Its ungranted helper
accepts neither content nor an arbitrary owner. Following the accepted worker
bridge, validate scoped context, isolation, shared authorization lock, live
principal/owner authority and capability, matching epochs and creator binding,
and the exact retained outbox identity/type/key/payload/revision/envelope.
Acknowledged dispatch is not retirement; retired, forged, substituted, or
unauthorized events fail closed. The public function returns only bounded
status/count metadata, not the canonical text it internally projects.

Ready-event principal/epochs come from the authenticated completing job;
delete/restore-event principal/epochs come from the checked lifecycle caller.
Never substitute the stored Document creator for the actual event actor.
The current lifecycle and extraction contracts already require that actor to
be the creator, so the worker comparison preserves their boundary. Do not
add that creator restriction to read-authorized manual maintenance.

Authenticated read-maintenance and existing Note-write reconciliation use
separate entrypoints into that private helper so their existing capabilities
are not accidentally widened or conjoined. ACL integration tests use actual
production roles; temporary test grants are not permission evidence.

Extend the closed event/job codec and dispatcher mappings for
`document_projection`, using the existing durable outbox/Oban reservation
mechanism. Do not place content or query fields in envelopes, job arguments,
audit records, log messages, telemetry, exceptions, or dead-letter diagnostics.
Use existing safe SQL execution and sanitized stable errors. Tests include
canaries for query, title, body, snippet, tag labels, and locator headings.

## Deterministic maintenance and recovery

One-resource and full-owner maintenance use the same canonical reconciler;
neither requires a surviving projection row or lifecycle event. Authority is
freshly checked through the authenticated Runtime boundary, not bypassed by a
caller-supplied owner UUID or an unrestricted worker scan.

Expose `Api.rebuild_search(session, resource_id)` and
`Api.rebuild_search(session, :all)` with their injected-runtime test seams.
For one resource, inspect only bounded owner-scoped identity to determine its
canonical kind, then authorize that kind before reading content or reconciling.
An unknown or foreign resource is hidden; full maintenance requires both
existing read capabilities before enumeration.

The maintenance command boundary is in-process in the already-running
authenticated Runtime, using its existing resolved session:

```elixir
Singularity.Runtime.Api.rebuild_search(existing_session, resource_id)
Singularity.Runtime.Api.rebuild_search(existing_session, :all)
```

This explicitly interprets the phase's rebuild-command requirement as a Runtime
command, not a new standalone administration CLI. A separate Mix runtime cannot
reuse the live instance's process-local unlock state merely by resolving a
session token. Do not copy custody state, bypass unlock, or claim a standalone
Mix command is usable. A remote command transport or credential-acquisition
workflow would need a separately approved scope.

Reject owner, principal, database-role, and connection overrides. Missing,
expired, revoked, locked-when-required, or underprivileged sessions fail closed.
The command returns only bounded counts and stable codes, never content or
session credentials. It does not mint credentials, log in, unlock, or use
migration credentials. It is exercised within the existing live Runtime
authorization path; automated login and all-owner administration are excluded.

Full maintenance enumerates canonical Note/Document IDs in ascending UUID
keyset batches of at most 100, including tombstones, and reconciles each in
its own transaction. Enumeration is IDs-only and must not hydrate Document
fragment sets. Each item is reauthorized before reconciliation. Failure stops
the command with sanitized status; it does not skip failures and report success.
An interrupted command can restart safely from the beginning.

Per-resource replacement removes stale-version and tombstoned rows. Composite
FKs prohibit true source orphans; maintenance verifies those constraints rather
than depending on stale projection rows as the enumeration source. No destructive
global truncate or long whole-owner transaction is the rebuild algorithm.

The sweep is not a globally frozen snapshot. Concurrent mutations maintain or
queue their own projection work. Once activity quiesces and accepted jobs drain,
its visible result set must equal a fresh canonical rebuild. Equivalence covers
entry identity, text, locators, rank, timestamps, and stable paging; bookkeeping
timestamps are excluded. Backup-provided projection rows are never authoritative.

## Migrations, extensions, and legacy restore

Install `pg_trgm` in a `search_extensions` schema controlled by the established
table owner, before creating indexes. Revoke PUBLIC schema access and function
execution; final migrations grant only schema usage/function execution required
by search. Runtime roles cannot CREATE there or install extensions.
Schema-qualify trigram functions, operators, and opclasses. An existing
extension in an unexpected namespace fails preflight; do not silently relocate
an operator's extension.

Use the actual migration/database bootstrap lifecycle for every fresh test and
deployment application database, not the provisioner's `postgres` maintenance
database. The test database lifecycle grants CREATE on each fresh database to
the table owner before provisioning. Verify the required extension package and
namespace on PostgreSQL 17 fixtures. Missing installation prerequisites fail
before search activation and are documented for operators, not bypassed at
runtime.

### Approved installation-authority amendment, 2026-10-10

The user approved the narrow administrator-provisioning amendment after an
isolated PostgreSQL 17.10 probe showed that trusted installation gives the
table owner the extension but leaves its functions owned by the bootstrap
administrator. Table-owner REVOKE/GRANT statements can warn without applying
the required function ACLs. The administrator step below is the sole exception
to migration-only schema/grant changes; it does not authorize new runtime
privileges or a general bootstrap redesign.

1. Use the existing external administrator connection and an explicit
   application database target; refuse maintenance/template databases. Share
   one privileged SQL implementation between an operator wrapper and the fresh
   and historical test database lifecycles. Do not add an administrator Repo,
   runtime configuration, or credential-bearing process arguments/logs.
2. In one transaction, install `pg_trgm` 1.6 in the table-owner-controlled
   schema under `SET LOCAL ROLE singularity_table_owner`, then return to the
   administrator to revoke PUBLIC function execution. Keep extension functions
   administrator-owned. Delegate EXECUTE WITH GRANT OPTION to the table owner
   only for `similarity(text,text)` and `similarity_op(text,text)`, the functions
   required by the approved scoring and `%` operator. Do not grant broad
   extension execution or change managed-role attributes/memberships.
3. Verify namespace, extension/schema ownership, supported version, and exact
   ACLs. Compatible reruns are idempotent, including after final web grants.
   Reject incompatible pre-existing namespace/ownership/grants rather than
   relocating, adopting, or silently rewriting operator-managed state.
4. A new forward migration fails closed unless provisioning is correct, then
   applies final web USAGE/EXECUTE grants and projection DDL. Prove GIN creation,
   maintenance, and querying with the constrained ACLs using actual roles;
   do not treat successful warning-only SQL as privilege evidence.
5. Provision each fresh/historical application database after the table-owner
   CREATE grant and before migrations, inside cleanup-protected lifecycle
   code. A real provisioning failure must remove only its allocated database
   and storage root and restore the outer historical fixture configuration.

Apart from this explicit initial provisioning exception, schema, function
replacement, and grant amendments remain new forward migrations. Preserve
immutable source rows, all released migrations, the existing Note projection,
and the accepted source-retention/backup guard.
Initial backfill uses canonical reconciliation and is verified before the
new search API is considered ready; existing APIs remain available.

V1/V2 compatibility requires a narrowly listed derived-projection amendment:

1. Exclude `search_entries` from canonical backup payloads.
2. Include it in restore destination locking and empty-destination checks.
3. During the existing pre-completion restore reconciliation, rebuild unified
   Note entries from canonical restored Notes and verify exact identity.
4. Preserve every existing Asset/Note restore assertion, proof, payload shape,
   and completion protocol. V1 has no unified entries; V2 reconstructs Notes.

Restore uses its existing trusted owner transaction and authenticated restore
binding, not a live user session. That existing internal path may call the
private canonical helper under its established table-owner authority. It does
not call `Api.rebuild_search`, acquire new read capabilities, or newly require
an unlock. Do not expose that helper through PUBLIC/runtime EXECUTE or turn it
into an owner-ID override for ordinary maintenance. Existing restore locks and
verification remain the authority for this compatibility-only invocation.
The online command's one-transaction-per-resource rule does not replace the
existing exclusive restore transaction or its locks.

This is the smallest required legacy restore compatibility hook, not a Vault
or V3 feature. The unsupported-canonical-row guard remains unchanged and
continues refusing V1/V2 backups containing Documents, fragments, tags, or other
unsupported knowledge data, including retained tombstoned data. Phase 3 must
not claim Document backup support. Any required Vault-related file touch must
be reported explicitly and remain within this compatibility boundary.

## Implementation acceptance contract

Before changing behavior, characterize the old Notes/Asset APIs and add focused
failing contracts. The subsequent detailed plan must map each item below to
exact files, commands, production-role fixtures, and independent review.

- Pure malformed-query/selector/result tests; unknown keys, duplicate aliases,
  UTF-8/NUL/size bounds, tag normalization, and branch-specific provenance.
- Mixed Note/Document results, exact source versions, only current ready/live
  content, conflict exclusion, deleted sources, and owner isolation.
- Note create/save/merge/delete/restore atomicity and rollback with both
  projections; unchanged legacy search DTOs, ranking, filters, and cursors.
- Document ready/delete/restore, duplicate delivery, repeated lifecycle cycles,
  terminal replay, completion after tombstone, and out-of-order event races
  using deterministic barriers, not longer sleeps or weaker assertions.
- Real worker definer ACLs and direct-table denials; wrong creator/scope/epoch,
  revoked capability, missing/forged/retired retained events, missing scope,
  and sanitized errors. No temporary-grant substitute for live-role evidence.
- Tag AND semantics and immediate canonical membership filtering, including
  unknown/cross-owner IDs and preserved web mutation denials.
- PostgreSQL FTS, title similarity, literal wildcard escaping, CJK, one-/two-
  character queries, punctuation-only input, empty query, and Unicode snippets.
- Fixed rank fixtures and tied mixed-kind keyset pagination; cursor tampering,
  wrong filter/owner/policy, old cursor domains, bounded tokens, and no plaintext
  query exposure. Document concurrent-page membership limits explicitly.
- Query plans on deterministic, analyzed fixtures with selective FTS/trigram
  cases and honest nonselective short-query evidence. Do not require the
  planner to use an index for a tiny table or force it to hide a bad query plan.
- Exact Note and Document fragment resolution after head advance, absent
  projection, wrong resource/version/fragment, tombstone, and another owner.
- Complete projection deletion followed by one-resource/full rebuild;
  identical results/ordering/locators, interrupted restart, and concurrent
  lifecycle changes. Canonical versions/fragments/digests remain unchanged.
- Command selector validation, existing live-session authorization,
  expiry/revocation between batches, privilege/unlock boundaries, and absence
  of credentials/content from results and diagnostics. A new runtime without
  the required existing unlock state must fail closed, not regain it from IDs.
- Fresh-database extension setup and forward migration; bootstrap privilege
  limits; unchanged seven-application graph and zero xref cycles.
- V1/V2 clean restore and destination checks; reconstructed unified Notes;
  unchanged unsupported-canonical guard with retained Documents/tags.
- Query/content/locator/tag canaries across supported diagnostics, rollback,
  cancellation, job retry, and source-unavailable paths.

Finally run the complete ordered README verification gate from the exact
committed candidate, with owned service identity and cleanup evidence. Browser
acceptance remains a manual run; this phase does not broaden workflow triggers
or silently run E2E during focused development. Preserve and report unrelated
baseline failures according to the repository diagnosis/repair policy. The
current prohibition on running E2E remains in force; record NOT RUN without
claiming a complete gate or accepting the phase.

Record exact source SHA, changed files, forward migrations and grants, all
commands/results, review findings, residual risks, and explicit confirmation
that no Vault feature work occurred. A green scoped suite alone is not Phase 3
or whole-release acceptance. Phases 4–7 retain their separate designs and plans;
after required acceptance and independent review, advance automatically under
the continuous authorization rather than requesting routine approval.
