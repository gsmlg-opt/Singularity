# Singularity v0.2 Phase 4 — Versioned sources and knowledge organization

## Status and authority

Design under the user's 2026-10-10
[continuous development authorization](../../../AGENTS.md#continuous-development-authorization--2026-10-10).
Routine approval waits are superseded; this document still requires independent
review before implementation. The user's later explicit E2E deferral permits
local development and phase advancement after every other required check and
independent review passes. E2E stays manual-only and NOT RUN; final
browser/release acceptance remains required.

The base is [qualified Phase 3](../../verification/2026-10-09-phase-3-acceptance.md):
tested source `35c1f8360dd22b129832a1618b3723032a1983bd`, followed by
documentation handoff `617f0b986a3ecffba14c952988e39e3afe022cea`.
Work belongs to `.trees/v0.2-phase-4-knowledge-links`, branch
`codex/v0.2-phase-4-knowledge-links`. It is not merged into `main`.
The [detailed plan](../plans/2026-10-11-singularity-v0.2-phase-4-knowledge-links.md)
implements only [release Phase 4](../plans/2026-08-31-singularity-v0.2-release.md#phase-4--attachments-citations-tags-relationships-and-backlinks).

No merge, push, version bump, tag, release, deployment, production activation,
production backfill, V3 backup format, new browser feature, or Vault feature is
authorized. Preserve the seven-application graph and zero xref cycles. Earlier
Phase 2 qualifications remain recorded, not silently repaired or waived.

## Goal and boundaries

Make attachments and citations immutable parts of each Note version, including
competing conflict versions, with exact source pins and retention of historical
evidence. Expose authenticated tag organization, directed relationships and
backlinks through Runtime, and render citations as ordinary readable Markdown.

PostgreSQL remains canonical. Original bytes, extraction and search ranking
are unchanged. Domain code stays free of Ecto, filesystem, Phoenix and React.
Web calls only `Singularity.Runtime.Api`; Phase 4 adds no browser workspace.
Tags and relationships are independent resource organization commands, not
extra mutable fields embedded in a Note snapshot or a graph framework.

Production canonical writes remain disabled pending the complete release
activation gate. The existing V1/V2 fail-closed unsupported-canonical-data guard
must continue rejecting nonempty knowledge metadata. The derived source seal
alone does not make an otherwise supported legacy backup unsupported.

## Architecture choice and inspected constraints

| Approach | Decision |
| --- | --- |
| Immutable per-version source seal, typed request references, existing Note transaction | Chosen: includes empty sets, preserves receipts and raw-SQL integrity, and permits bounded historical retention |
| Adapter-only finalization | Rejected: a later SQL INSERT can still extend a committed empty or nonempty version |
| Caller flags, transaction `xmin`, or an owner-wide lock | Rejected: unnecessary trust/transaction identity or serialization of unrelated Notes |

The source-set and lock protocol received Astra architecture advice under
`PROJECT_ARCHITECTURE`, not a repair attempt. Sol remains the implementation
and review default; diagnosis escalates under the recorded two-round/impasse
rule. No bounded repair attempt has been consumed by this design advice.

Existing `NoteAttachment` and `NoteCitation` are stored shapes: they require
containing Note/version and owner identity. They are not caller input values.
`NoteSourceSet` already validates immutable provenance and historical witnesses,
but `KnowledgeLinkRepository` currently treats empty sets as uninitialized and
always requires live targets on insertion. Its historical reader takes a
resource lock, so it cannot be reused unchanged for early lock preparation.
Released SQL prevents child UPDATE/DELETE but not later append. All SQL changes
therefore use new forward migrations; old migrations remain untouched.

Every fresh successful Save already creates a version, even with equal text.
Stale Save keeps the submitted competing version without changing the head;
Merge has two parents and resolves the selected open conflict. Those semantics,
deadlines, source projections, ID-only events and receipt behavior remain.

## Pure request references and defaults

Add `Core.NoteAttachmentReference` and `Core.NoteCitationReference`:

- Attachment: stable `attachment_id`, `target_resource_id`, exact
  `target_resource_version_id`, `target_kind` (`asset`, `note`, `document`),
  `role` (only `source`, default), optional NFC `label` (at most 255 bytes).
- Citation: stable `citation_id`, `source_resource_id`, exact
  `source_resource_version_id`, lowercase 64-hex `fragment_id`, and an existing
  validated v1 `SourceLocator`.
- Only these fields are accepted. No caller owner, Vault, classification,
  containing Note/version, ordinal, live/retained flag, text excerpt or witness.
  Normalize atom/string aliases through fixed keys, reject conflicting aliases,
  unknown keys and malformed/forged structs, and never intern input atoms.
- Preserve caller list order; Storage derives zero-based ordinals. Each
  collection has at most 100 members; attachment IDs and citation IDs are
  unique within their collection, as are attachment target/version/role tuples.
  The union of referenced target identities and fragments is bounded at 100.
  Errors are the existing content-free `Core.Error` values.

Extend `NoteSnapshot` with `attachments` and `citations`, each independently
either a validated list or the internal `:inherit` sentinel. Client omission is
the only way to request inheritance; an explicit client `:inherit`/string is
invalid. Internal canonical reconstruction may preserve the sentinel without
reinterpreting it as a client field.

| Operation | Omitted collection | Explicit `[]` |
| --- | --- | --- |
| Create | Empty | Empty |
| Save, including stale Save | Copy exact `base_version_id` | Clear |
| Merge | Copy exact `expected_current_version_id` | Clear |

Mixed modes are valid. Explicit Merge references can retain unchanged members
from either direct parent. Existing callers retain their text and parent
semantics; an omitted field must never erase a source set. Metadata-only saves
create a version. Old versions and conflicts retain their original source sets.

## Fingerprints, receipts and orchestration

Preserve the exact literal `:note_mutation_v1` tuple for legacy default modes:
empty Create collections; Save/Merge with both collections omitted. Explicit
empty Create is equivalent to its default. Tombstone/restore fingerprints stay
unchanged. Use domain `:note_mutation_v2` for other Create/Save/Merge requests.
V2 covers normalized request intent: inherit versus replace, ordered stable
member IDs, every target pin/kind/role/label, and fragment/locator encoding.
Do not include a generated containing Note/version, fetched evidence, resolved
parent members, current head, private runtime context or wall-clock time.
The exact v2 tuple replaces the corresponding v1 marker, retaining its remaining
operation fields, and appends attachment mode then citation mode. Each mode is
`:inherit` or `{:replace, ordered_member_tuples}`. Attachment members contain
`{attachment_id, target_resource_id, target_resource_version_id, target_kind,
role, label}`; citation members contain `{citation_id, source_resource_id,
source_resource_version_id, fragment_id, encoded_locator}`. This literal
encoding is independently asserted by Runtime HMAC tests.

Domains' reconstruction and Runtime's fingerprint reconstruction must carry
the source modes without accepting hand-crafted noncanonical commands.
Keep the established HMAC secret and deterministic term encoding; no custody,
key, capability or Vault machinery changes.

Source preparation, live checks and persistence occur inside the winning
`NoteMutationReceipts.with_claim` callback. Completed replay returns recorded
identities without creating a version or validating now-deleted sources.
Runtime retains its current canonical-head response hydration semantics.
The same mutation ID with changed source intent conflicts with the receipt.
For the same authenticated receipt identity, operation and caller resource,
a changed canonical request fingerprint returns a nonretryable conflict.
Structural operation/resource mismatches remain invalid, even when the
fingerprint also differs; malformed/pending stored receipts retain their
existing integrity handling. Receipt keys, HMAC encoding and completed replay
results do not change. Nonlocking aggregate-input preflight may preserve
established lineage error classification inside the winning callback before
source resolution; all existing post-ordered-lock checks remain required.

## Per-member historical retention

Storage and SQL independently derive retention from the new stored Note's
direct parent row(s), never a caller-provided retained bit. Match the stable
member UUID and all semantic fields against a parent's exact stored member;
exclude new containing Note/version IDs, ordinal and insertion time.
Before granting retention, independently require same-Note/owner/private direct
parents whose canonical resource revisions are strictly lower than the new
containing version. A self-parent, cycle or non-lower parent cannot establish
historical evidence. This predicate must be SQL-enforced, not inferred from
caller fields or the existing same-resource parent FK. Valid legacy restore
retains its original well-founded Note ancestry.

- An unchanged retained member can reorder and survive source tombstones.
- A new UUID, target/version/kind/role/label change, fragment change or locator
  change is new evidence and requires a current live typed source; a Document
  must be ready and its fragment/locator must exactly match canonical data.
- One target may have both retained and new references: validation is per
  member, not an exemption for the entire target.
- Historical reads retain exact pins and report deletion; they do not follow
  the source's newest head or drop evidence after tombstones.
- Owner, private classification, typed target, version binding, no self-link,
  readiness for new references and exact fragment provenance remain enforced.
  SQL compares parents and fields even if a raw caller bypasses the adapter.

## Transaction lock protocol

Introduce narrow Storage preparation/lock/persistence seams. Preparation reads
immutable parent membership and canonical target identities without row locks.
Complete the source identity set before the existing edited-resource lock:

1. Existing OperationScope authorization locks and matching scoped transaction.
2. Claim the mutation receipt; replay does not enter preparation.
3. Resolve request modes and immutable parents without resource row locks.
4. Lock all target Assets sorted by Asset UUID `FOR SHARE`, then their objects
   sorted by object UUID `FOR SHARE`.
5. Lock the edited Note and all target resources sorted by resource UUID
   `FOR UPDATE`, then existing aggregate advisory locks in that same order.
6. Lock referenced immutable resource versions sorted by UUID, followed by
   Asset associations in their established order.
7. Revalidate each live/retained witness and the existing Note/base/CAS/conflict
   conditions; insert the new version, both collections and its seal, then
   existing head, projection, receipt, audit and outbox effects.

Do not discover new targets or acquire Asset locks after resource locks. Keep
the existing CAS/conflict serialization and deadlines. Mutual Note attachments
use the same resource order; Asset deletion keeps Asset→object→resource;
Document lifecycle keeps resource→typed Document. Barrier-controlled real
transactions must prove supported application writers converge without raising
timeouts. Arbitrary raw SQL can still deadlock-abort; do not promise universal
deadlock freedom.

Canonical mutation composition remains metadata-only for retained copying.
The existing public `NoteSourceSet.new/1` requires full `DocumentFragment`
text, so it and the standalone content-hydrating link adapter keep their
contracts unchanged. The narrow mutation seam instead reconstructs strict
canonical reference lists, derives `NoteAttachment`/`NoteCitation` rows with
authenticated owner and new containing IDs/ordinals, and checks actual typed
source/fragment identity and exact locator metadata under the ordered locks.
Resolved collection/union bounds and independent SQL provenance, parent,
retention and final-seal constraints all remain mandatory. It neither forges
Core structs nor claims content-witness validation without reading content.

## Database sealing, migration and grants

Add derived `content.note_source_set_seals`, with the exact containing
Note/version/owner/private tuple, attachment count and citation count. It has
a composite FK to the typed Note tuple, forced owner RLS and established table
ownership. Seal UPDATE/DELETE and runtime direct INSERT/TRUNCATE are forbidden.

Source-child BEFORE INSERT rejects a visible existing seal. Deferred constraint
triggers on both typed Note-version INSERT and child INSERT finalize the full
set. Child-side deferred verification closes the concurrent-append race where
the early guard cannot see another transaction's uncommitted seal.

Finalization validates exact identity, complete counts, contiguous ordinals,
existing uniqueness, and the 100-member/target/fragment bounds. An existing seal
must match the exact tuple/counts; it is never updated or silently ignored.
An absent seal is inserted once and rechecked. A conflicting concurrent insert
without a visible matching row fails. Child immutability prevents same-count
replacement after finalization.

The adapter flushes only named provenance and finalizer constraints after both
collections have been inserted, including the Note-version event so an empty
set seals immediately. It owns these named modes (initially deferred, flush
immediate then re-defer only those); all unrelated constraint modes remain
untouched. Do not claim restoration of an arbitrary caller's earlier mode for
the owned names. Never `SET CONSTRAINTS ALL`. Reverse ordinal/parent
construction remains valid until deferred finalization; an early named
`SET CONSTRAINTS ... IMMEDIATE` seals the set then present. Re-deferring never
reopens it.

The forward migration locks affected tables against concurrent writes,
structurally validates and backfills seals for all historical Note versions,
including empty versions. It neither rewrites child rows nor requires
historical target liveness. Malformed existing membership aborts migration.
The complete-set fixture change must preserve identity/FK/ordinal/locator
negative tests and reverse-insertion coverage, replacing only the old
second-transaction append expectation with sealed rejection.

Enable only the explicit source/organization operations required by authenticated
web Runtime under existing forced RLS. Worker/download roles gain no new source
or organization write privilege. Preserve existing capabilities and role
attributes/membership. Runtime has no caller-selected owner scope.

## Runtime reads and authorization

Keep `Api.create_note`, `save_note` and `merge_note` signatures, adding only
optional `attachments`/`citations` client fields. Existing Note write plus
unlock requirements remain. A newly introduced Note target requires existing
`note.read`; an Asset/Document target requires existing `asset.read`.
Retained exact members may copy IDs without fetching/disclosing source content.
Every source resolution, title or excerpt hydration requires current source
read authority. Authorization and persistence share the OperationScope boundary;
no one-time preflight replaces revocation checks.

Runtime passes the existing opaque repository context as a server-only map
containing the scoped `repo` and an `authorize_new_sources` callback. Domains
forwards it unchanged; the callback is never a client field, Note intent,
Command or receipt/HMAC input. NoteRepository preserves raw-repo internal
callers, but a mapped context must contain a valid callback or fail closed.
Thread that callback separately into the winning mutation callback. After
metadata-only source preparation determines exact new members, and before
ordered locks/revalidation/insertion, authorize only those new references on
the same scoped repo. Retained-only mutations and receipt replay must not call
it. Runtime derives sorted unique existing read capabilities from validated
new target kinds and uses the existing authorizer, explicitly binding both
session authorization epochs because this direct check bypasses OperationScope's
initial requirement binding. Preserve the authorization lock and transaction;
no nested scope, new capability, custody or Vault change. A source denial returns
the ordinary sanitized Error and rolls back canonical/receipt/effect writes;
do not manufacture OperationScope's private initial-denial marker or mislabel a
source-read denial as the outer Note-write denial audit.

Exact Note-version DTOs include ordered owner-free source references; conflicts
include the competing version's sources. Add exact selectors
`resolve_note_attachment(session, note_id, version_id, attachment_id)` and
`resolve_note_citation(session, note_id, version_id, citation_id)`. Require
`note.read` on the containing Note and the target's existing read capability.
Response pins stay exact, with live/deleted status; deleted sources retain
historical evidence instead of silently becoming a newer version. Do not
return new binary bytes through this API: existing Asset download remains the
only original-byte delivery path.

Source resolution first selects only the requested stored canonical reference
using the authenticated containing Note/version/member identity. Determine and
check its target's current read authority before hydrating any source title,
excerpt or citation fragment text, on the same scoped connection and existing
authorization lock. A narrow historical metadata reader joins the exact owner,
private resource/version/typed identity and selected fragment/locator; ordinary
live-only resource/search readers retain their behavior. Asset filenames come
from pinned source metadata, not mutable resource-head titles. Missing or
cross-owner members return nondisclosing not-found outcomes. Whole-set citation
hydration is not a valid pre-authorization selector.

The narrow adapter seam has four existing-scope operations, added to the
KnowledgeLinks repository port without changing its legacy `insert_set` or
`list_set` contracts:

- `select_attachment_in_scope(context, note_id, version_id, attachment_id)`
  returns the existing owner-free `Core.NoteAttachmentReference`.
- `select_citation_in_scope(context, note_id, version_id, citation_id)` returns
  the existing owner-free `Core.NoteCitationReference`.
- `resolve_attachment_in_scope(context, selected_reference)` returns exactly
  `%{reference: selected_reference, source: source_metadata}`.
- `resolve_citation_in_scope(context, selected_reference)` returns exactly
  `%{reference: selected_reference, source: source_metadata, fragment: selected_fragment}`.

All four require the same already-open scoped transaction and both matching
principal/owner GUCs. Selectors require a live private containing Note, the exact
typed containing version and its seal, retaining the containing resource's share
lock; a historical containing version need not be the current head. They select
only the requested stored member and do not read target titles, Asset metadata,
fragment text or another member's evidence. Missing, foreign and mismatched
containing/member tuples return nondisclosing not-found. Runtime revalidates the
selected reference and binds its member ID before determining target authority.

`source_metadata` has exactly `kind`, `resource_id`, `resource_version_id`,
`title` and `deleted?`; `kind` is one of the three supported kinds, identifiers
are canonical exact pins, `deleted?` is boolean, and the title is nonblank valid
UTF-8 without NUL, preserved rather than replaced by a resource-head title.
For Asset the exact AssetMetadata asset/version/owner/private binding supplies
the filename; missing or mismatched metadata returns nondisclosing not-found,
not a head-title fallback. For Note/Document the pinned typed version supplies
the title. Historical resolution permits deleted targets but enforces the exact
resource/version/typed owner/private identity. A selected citation fragment has
exactly `fragment_id`, `ordinal`, `text` and canonical `Core.SourceLocator`;
validate its canonical fragment digest/identity and equality to the stored
locator. No whole fragment set, Note body, original bytes or custody fields are
added to attachment resolution. Domain port types explicitly describe these
owner-free maps; Runtime reconstructs their nested values and rejects unknown
or noncanonical output fields. These internal metadata operations are not new
client-supplied selectors or an alternative to current target authorization.

Compose complete ordered reference collections in Runtime, not by narrowing
legacy raw `NoteRepository.get/get_version/get_conflict` contracts. A small
shared `Notes.SourceCollections` helper calls the existing metadata-only
`read_membership/3` using authenticated session principal/owner and the returned
row's exact resource/version IDs on the same scoped repo. It binds the returned
revision to that row and reconstructs both reference arrays; no source title or
fragment text is loaded. Use it for current/exact Get, each conflict branch,
mutation latest-head reload (including winning replay), and ordinary Export
before strict Note conversion. An internal injectable `knowledge_link_repository`
defaults to the real adapter; fake unit readers are explicit and do not prove
canonical membership. Do not silently substitute empty arrays for an absent or
failed production membership read.

`DTO.Note` and `DTO.NoteVersion` require both arrays explicitly. Nested
`DTO.NoteAttachment` and `DTO.NoteCitation` expose only their existing reference
fields, without owner, containing version, evidence, ordinal or hydrated titles;
revalidate exact keys, canonical values, per-collection bounds and uniqueness.
Array order preserves the canonical ordinal order. Summary/history/search DTOs
remain unchanged. Existing test DTO constructors gain explicit empty arrays
where the fixture has no references. Export source-collection composition is a
strict-DTO compatibility requirement, not early source rendering; the ordinary
Markdown rendering work remains Task 7. No browser behavior or E2E is changed by
these constructor-fixture updates.

## Independent tags, relationships and backlinks

Expose resource-scoped Runtime APIs, using existing Note or Asset/Document
read/write capabilities according to the resource kind:

- `attach_tag(session, resource_id, %{name: name})`,
  `detach_tag(session, resource_id, tag_id)`,
  `list_resource_tags(session, resource_id, params \\ %{})`.
- `browse_resources_by_tag(session, tag_id, params)`.
- `relate_resource(session, source_id, %{target_resource_id: id, type: type,
  target_resource_version_id: pin_or_nil})`, `unrelate_resource(session, edge_id)`.
- `list_outgoing_relationships(session, resource_id, params)` and
  `list_backlinks(session, resource_id, params)`.

Tags retain trim→NFC→Unicode-casefold→NFC identity and first spelling/UUID.
Attach/detach and natural-edge replay are idempotent; audit only actual changes
with IDs, never labels/content. Edges remain directed `related_to`, `references`
or `derived_from`; self-links are invalid. A duplicate natural edge with a
different exact target pin conflicts. Unknown/cross-owner selectors must not
reveal existence. Runtime establishes selector visibility before listing;
outgoing/backlink lists omit tombstoned endpoints and are deterministic.

Tag-list/browse/outgoing/backlink `params` accept only `limit` (1–50, default 20) and
optional bounded cursor (at most 2048 bytes). Use owner/selector/direction-bound,
domain-separated authenticated keyset tokens, existing runtime secret, and
UUID order (tag UUID for resource tags, resource UUID for tag browse,
relationship UUID for edges).
The internal cursor binding is exactly `owner_scope_id`, `selector_id`,
`operation` (one of the four fixed server operations) and integer
`ordering_version: 1`; it is not a client DTO. Encode the last returned
canonical UUID with `OrganizationCursor.encode(last_uuid, binding, secret)`;
`decode(token_or_nil, binding, secret)` returns that UUID or nil. Following
the existing search cursor framing, the binding MAC uses
`knowledge-organization-binding:v1` plus NUL and 64-bit big-endian byte-length
frames for owner, selector, operation string and `"1"`. The cursor MAC uses
`knowledge-organization-cursor:v1` plus NUL and frames for `"1"`, binding MAC
and last UUID. Both use HMAC-SHA256 and unpadded base64url. The canonical JSON
envelope has exactly `v`, `f`, `i`, `h` (integer 1, binding MAC, last UUID,
cursor MAC), wrapped in unpadded base64url. Reject noncanonical/duplicate-key
JSON, malformed or extra fields, invalid IDs/version and MAC/context mismatch
with sanitized errors and constant-time MAC comparison. The binary secret
has the existing cursor's minimum 32-byte bound; no new secret or key lifecycle.
Query limit is deliberately independent; current trusted allowed kinds and
authority are reapplied on each page and never taken from the token.
Fetch `limit + 1`; return owner-free `items` and `next_cursor`, not a silently
truncated list. These are live pages, not a snapshot guarantee across mutations.
Retain the existing internal tag-list signature but do not reuse its `LIMIT 100`
as a complete public list. Test a resource with more than 100 tags across pages.
Filter source and target visibility/kind/read capability before admitting rows,
not by disclosing an unfiltered count. No generic graph traversal is added.

The pure `OrganizationPageQuery` contains only `limit` and `cursor`, with
defaults 20 and nil. The server-side page constructor receives one of
`resource_tags`, `tag_resources`, `outgoing` or `incoming` separately; the
`OrganizationPage` itself contains only `items` and `next_cursor`. Preserve
the established internal `:done` terminal, converted by the Runtime DTO if
needed. Fixed owner-free items contain `tag_id`/`display_value` for resource
tags, `resource_id`/`kind` for tag browse, and `relationship_id`,
`source_resource_id`, `target_resource_id`, nullable
`target_resource_version_id` and `type` for edges. Validate exact keys,
canonical IDs/kinds/types, distinct edge endpoints, strictly ascending unique
UUID keys and bounded proper lists. A continuation requires a full nonempty
page. Preserve existing ownerful Core Tag/Relationship mutation values.
Pure Domains dispatch revalidates selector, query and returned page through
literal query-port operations; trusted allowed kinds are a separate internal
argument, never a client query field or a replacement for current Runtime
authorization. SQL filters both edge endpoint kinds before paging.

### Task 6 facade result detail

Use four small owner-free Runtime DTOs with the existing Core page field names:
`OrganizationTag` has exactly `tag_id` and `display_value`;
`OrganizationResource` has exactly `resource_id` and `kind`;
`OrganizationRelationship` has exactly `relationship_id`, `source_resource_id`,
`target_resource_id`, explicit nullable `target_resource_version_id` and `type`;
`OrganizationPage` has exactly `items` and `next_cursor`. Resource-tag pages
contain Tag DTOs, tag-browse pages Resource DTOs, and outgoing/backlink pages
Relationship DTOs. Operations remain server-selected, not an extra page field.
Convert the established Core `:done` terminal to public nil. Every continuation
still requires a full nonempty page under the exact validated query.

`attach_tag` returns one OrganizationTag; `relate_resource` returns one
OrganizationRelationship. `detach_tag` and `unrelate_resource` return `:ok`.
Keep the existing ownerful Core Tag/Relationship port results unchanged.
Runtime converts them only after exact constructor revalidation and binding to
the authenticated owner/private context; forged values, private extras,
rewriting/default filling or mismatched result identities fail closed. Public
Api revalidates canonical owner-free item DTOs/maps and typed Page DTOs, and may
convert exact authenticated Core results through its deterministic configured
test seam. Raw page maps follow the unchanged Core contract, including `:done`;
public nil terminals are accepted only through the typed Page DTO boundary.
It never strips unvalidated fields or accepts caller-provided owner scope.

Shared pure conversion lives in `Runtime.Organization.DTO`; operations compose
the existing scoped ports and current authorization in
`Runtime.Organization.Operations`. Core page validation remains the authority
for exact item shapes, order, uniqueness, limits and continuation. This detail
fixes the previously unspecified mutation-result DTO identity; it adds no
capability, organization feature, browser behavior or canonical record.

### Task 6 per-kind scope entry and selector metadata

An organization-only `Runtime.Organization.Authorizer` composes existing
authorization rather than changing `Authorize`, `OperationScope` or their
dependencies. For each invocation, Operations makes a local runtime copy with
the wrapper as its injected authorizer, preserving the original authorizer in
a trusted adapter context. Never mutate global configuration or recurse through
the wrapper. Mutations use existing `with_shared_request`; pages use existing
`with_read_request`. Both establish the ordinary authorization lock and scoped
transaction before the entry check.

The fixed server entry mode is read or write. It delegates nonempty single
capability alternatives: `note.read` or `asset.read` for pages, `note.write` or
`asset.write` for mutations. This is OR composition, never a new capability,
empty requirement or demand for both kinds. Every delegated requirement has
private classification, authenticated owner and both current session epochs.
Note requirements retain unlock; Asset/Document metadata requirements retain
the established non-unlock behavior. At the returned-result boundary, only a
canonical nonretryable forbidden or Note-lock error permits the alternative;
exposed unauthenticated, retryable, other error and malformed replies terminate.
An exception/throw/exit escaping the delegate becomes sanitized unavailable,
not fallback. Existing Authorize internally converts some malformed store
replies and rescued exceptions to forbidden; the wrapper cannot distinguish
those from capability denial and must not claim it can. Such an opaque denial
may permit an independently successful alternative, which must perform the
complete existing live-authority check. Successful entry permits bounded
selector metadata only, never authority on the denied kind. Exact kind checks
still precede labels/mutation and page admission excludes every denied kind.

Inside that same callback and repo, perform the exact actual-kind check before
labels, pages or mutation. Attach/detach require the resource's write; resource
tag/outgoing/backlink pages require the selector's read; relate requires source
write plus both visible endpoints' read. Tag browse has no resource kind and
requires at least one read authority, then the existing owner-scoped tag
selector. Derive allowed page kinds through fresh checks on the same repo:
Note read contributes Note, Asset read contributes Asset and Document. Fixed
observable nonretryable denials omit that kind; exposed operational/
unauthenticated failures abort, with the same inherited forbidden opacity.
Apply these trusted kinds before SQL page admission on every continuation,
never from a session snapshot, client or cursor. Inner direct denials remain
ordinary errors; do not claim the outer scope's denial-audit marker.

Add only `Domains.Organization.Repository` and its Storage implementation for
two existing-scope, metadata-only callbacks. `resources_in_scope(context, ids)`
accepts one or two canonical sorted unique UUIDs and returns the complete exact
requested set, sorted by UUID, as closed `resource_id`/`kind` maps. It filters
live supported kinds, private classification and authenticated owner, locking
Resources in UUID order. Missing or foreign membership returns the same
not-found result. `relationship_in_scope(context, id)` returns nil for absent
or foreign, or one closed five-field relationship map matching the requested
UUID, with exact endpoints, type and explicit nullable pin. Neither callback
returns title, tag label, body, bytes, timestamps or creator. Both require an
already-open transaction and matching principal/owner GUCs. Runtime strictly
revalidates keys, values, selector identity and complete membership. No new
pre-authority tag-label callback is needed.

Unrelate of an absent/foreign edge is the same idempotent `:ok` after write
entry, without mutation/audit. For a selected edge, read its live source
metadata and require that actual kind's write. A tombstoned source remains
nondisclosing not-found until restored. Add only
`Relationships.Repository.unrelate_selected_in_scope(context, selected)` to
delete with authenticated owner and every selected identity field, including
null-safe target-pin equality. A vanished or replaced edge produces no
deletion/audit. Preserve existing `unrelate_in_scope/2` callers. Do not row-lock
the relationship: its approved SELECT/INSERT/DELETE grants intentionally lack
UPDATE. Resource locks keep the authorized source kind stable; the conditional
DELETE binds the write to the selected edge without broader grants.

No metadata preflight outside the scoped lock, mutable checked-state side
channel, duplicated live-authority policy or change to custody/capabilities,
role attributes/membership, general policies, Core/page contracts or migrations
is introduced by this composition.

Storage's existing tag/relationship transactions cannot be nested inside
OperationScope. Add narrowly scoped internal methods while retaining existing
standalone adapter calls; don't compose organization writes into Note Save.

## Markdown export and legacy backup compatibility

Add a pure standard-Markdown source renderer composed by the existing Note
export operation after authorized exact-source resolution. An empty source set
returns the original Markdown byte-for-byte. Nonempty sets append a separated
source section with readable titles, stable IDs/version pins and validated
human-readable locators; citations use standard footnote definitions/links,
attachments use ordinary Markdown links. Escape Markdown/URL-sensitive data
and reject unsafe URI schemes; never invent an application-only URI needed to
understand the exported text. Use portable relative source names assigned by
the exporter, not filesystem input from clients. The renderer creates no
cross-resource byte download or V3 package; that remains Phase 5.
Private source hydration obeys current read capabilities and export authority.

Seals are regenerated derived records, not V1/V2 wire tables. Add them only to
restore destination locking and pre-restore emptiness inventory, not the
post-restore excluded-table list: valid restoration creates empty seals.
Existing generic Note import can regenerate them from finalizer triggers.
Run the full original V1/V2 restore oracle with unchanged wire columns,
crypto, keys, custody and assertions. Report the minimal frozen-substrate
`backup/restorer.ex` inventory patch explicitly. Nonempty attachments,
citations, tags and edges continue failing the unsupported-backup guard.

### Task 7 bounded renderer and authorized export detail

The recommended implementation reuses the existing exact selected-reference
and historical resolution ports; no new persistence port, grant, migration,
byte download, custody path or public Api signature is needed. Existing containing
Note loading remains authorized by the conjunctive `note.export`/`note.read`
unlocked shared scope. It already hydrates that Note's body/title before sealed
membership; the new pre-hydration guarantee concerns **referenced-source**
titles/fragments, not the already authorized containing Note.

Add pure `Singularity.Core.NoteMarkdownSources.render(markdown, descriptors)`
returning `{:ok, markdown}` or a content-free Core Error. The exact plain
descriptor map has only `attachments` and `citations`. Each proper collection
has at most 100 items with unique member UUIDs and preserves the canonical
caller/ordinal order, including descending UUIDs and retained-member reordering;
attachment `(target_resource_id, target_resource_version_id, role)` tuples are
also unique, regardless of differing member IDs or labels. Different version
pins remain distinct and attachment/citation overlap is allowed. The union of
target resource/version identities is at most 100. Each item
has exactly `reference`, `source`, `href`: an exact canonical Core
NoteAttachmentReference or NoteCitationReference respectively, the exact plain
source map `kind/resource_id/resource_version_id/title/deleted?`, and an assigned
relative href. Reconstruct references with exact equality, including nested
locator, role and label; never normalize server values or fill missing fields.
Bind all source kind/resource/version fields to the exact reference. Titles are
nonblank, UTF-8 and NUL-free; deletion is a boolean. No body, fragment text,
owner, authorization flag, caller filesystem path or Runtime struct reaches Core.

Runtime converts already canonical membership DTOs into Core reference structs
with exact field equality. Before any referenced-source hydration, it checks
each distinct required existing capability on the original scoped repo/session
with both bound epochs: `note.read` for Note attachments and `asset.read` for
Asset/Document attachments and citations. All must pass. Preserve the existing
private/unlocked source-resolution requirement. No OR fallback, silent omission
or public per-member ResolveSource call is used. After all
checks, one existing selected callback on the first nonempty membership item
locks the live containing Resource and must equal the canonical reference.
Then existing in-scope resolvers hydrate every exact historical member on that
same scope. Strict Notes.DTO.source_resolution validation binds each result;
citations still verify the selected fragment text/locator internally, but the
renderer receives no fragment text. Existing target tombstones remain readable
as historical metadata. Missing, unauthorized, malformed or over-budget members
abort the whole export, with no success audit or partial result. Empty collections
add no selector, target authorization or hydration calls.

Render nonempty sources after the unchanged original body, separated by two
newlines and a `## Sources` heading, after any provable fence closure described
below. Emit attachments first, then citations,
preserving canonical collection order. Ordinary Markdown links show escaped
titles and optional attachment labels, IDs, kind and exact resource/version
pins; citations add standard footnote markers and definitions with citation
UUID, resource/version, fragment ID and readable validated locator. Display PDF
page/optional character range, Markdown heading path/optional line range, text
line range or fragment ordinal. Mark deleted sources explicitly as historical.
Escape Markdown/HTML-sensitive punctuation and render control/newline characters
visibly in source labels; never interpolate source text as raw Markdown/HTML.
Footnote labels use ASCII `singularity-source-<citation UUID>` and an integer
suffix when needed. Scan existing body footnote labels conservatively with
trim/casefold before choosing deterministic unoccupied labels; do not rewrite
the user's original body, including existing footnotes.

The appendix must not be swallowed by the containing body's Markdown parsing
context. Adopt the bounded, dependency-free conservative formatter admission
recommended by the architecture-only Astra review; this is not a new canonical
Markdown syntax validator. Empty sources bypass this policy and return the
original bytes. For nonempty sources, scan physical LF, CRLF and bare-CR lines
incrementally with only `outside` or `fence(marker, opening_length)` state:

- Outside, recognize an opening maximal run of at least three backticks or
  tildes only at literal document column zero. Backtick info may contain no
  backtick; tilde info may contain arbitrary remaining text. Invalid openers
  fail closed. A recognized opener's entire line belongs to that literal fence.
- Every other outside line must contain neither `<` nor a contiguous run of
  three or more backticks or tildes anywhere. Otherwise fail closed. This
  deliberately rejects raw HTML (even closed), angle-bracket autolinks, `<`
  inside inline code/prose, and ambiguous indented/container/inline/escaped
  triple-marker runs. These can be valid Markdown; only nonempty-source export
  admission is restricted. Ordinary prose, headings, lists, quotes, regular
  Markdown links and single/double-backtick code remain supported when they
  avoid those guards. No initial BOM is stripped for fence recognition: a
  BOM-prefixed fence fails conservatively, not an ordinary BOM-containing body.
- Inside, recognize a closer with zero to three ASCII leading spaces, the same
  marker repeated at least the opening length, and only ASCII spaces/tabs
  afterward. All other lines are literal content, including HTML or apparently
  nested fences. A closing line cannot simultaneously open another fence.
- At EOF outside, append the normal separator/section. At EOF inside a proven
  column-zero fence, append one LF only if the body ends in neither CR nor LF,
  then exactly the opening number of markers, then the normal separator/section.
  Never append speculative generic HTML or fence closers. The original body is
  always the output's exact byte prefix, never escaped, normalized or replaced.

Closed column-zero fences, including literal HTML inside them, stay supported.
An unfinished proven fence gains exactly one matching appended closer; opaque
or ambiguous contexts fail before success audit rather than producing hidden
sources. Add Core/Runtime regressions for these admissions, closures, all raw
HTML classes, containers, BOM and line-ending variants. Independently
characterize generated accepted examples with the established local Markdown
parser: Sources must be a top-level heading and appended links/definitions
outside code/HTML. This is a pure non-browser diagnostic, not E2E acceptance.

Runtime assigns only `sources/<kind>-<resource UUID>-<version UUID>.<extension>`
with `asset/bin`, `note/md`, `document/txt`. Core requires exact equality to
that grammar and pin: schemes, absolute paths, traversal, backslashes, encoded
separators, query and fragment are all rejected. These identify logical pinned
destinations, not materialized files: label the appended section as a text-only
source inventory with no included source files. Phase 5 alone supplies portable
files/packages. No original filename is used as a destination path.

Canonical input Markdown remains UTF-8/NUL-free and at most **1,048,576 bytes**;
empty sources return its exact original bytes. Introduce a separate rendered
export ceiling of **16,777,216 bytes**, checked by pure
`NoteMarkdownSources.valid_rendered?/1` and reused only by Runtime
DTO.NoteExport.new/1. Canonical NoteSnapshot, NoteValidation and all canonical
Markdown write/summary validators remain unchanged. The distinct ceiling avoids
rejecting a legal 1 MiB Note merely because source metadata is appended. It
accommodates bounded citation heading metadata (100 × 64 × 255 bytes plus
conservative escape expansion), body and fixed pins; Asset filenames remain
unbounded SQL text and therefore require fail-closed title/escaped-output and
aggregate-budget checks before expansion/return. Never truncate metadata.
Count each generated byte, including any fence closer and every escape, using
the same token rules as emission; stop at overflow before constructing escaped
titles or the complete output. Then emit bounded iodata and flatten once.
Runtime rejects a resolved title whose bytes exceed the remaining aggregate
raw-title budget before retaining that result; raw-title bytes cannot exceed
the rendered ceiling. This bounds accumulated title payloads, not the size of
a single existing SQL read or total BEAM heap to 16 MiB. No source read port is
changed. Never claim that the output ceiling is a total allocation ceiling.
Validate the final NoteExport before appending the existing ID-only success
audit. A renderer-invalid authenticated descriptor becomes integrity_failure;
known adapter/authorization faults remain sanitized and abort the scope.

This necessary export-size/route-contract amendment is authorized under the
continuous product authorization, not a weakening of canonical input or an
expansion to V3, browser behavior or E2E. Independently review this detail before
implementation. Preserve empty-export identity and existing exact-version,
audit and privacy assertions when updating the old nonempty raw-body oracle.

## Task 9 qualification compatibility amendment

The complete gate at `1f760855e8a861406ad467b98ffecc21be89dcd7`
failed Storage integration, and separate whole-candidate QUALITY found two
Asset lifecycle gaps. These necessary compatibility and diagnostic contracts
replace conflicting earlier lock details only for organization/lifecycle reads
and writes; Note source readiness, canonical membership and other locks stay
unchanged. They received independent SPEC then fresh separate QUALITY review
before implementation, as recorded in the Phase 4 report. This is reviewed
design, not a fixed gate or phase acceptance.

### Historical contracts

Four failures compare a historical contract with the latest Phase4 schema.
Preserve every original assertion and raw inventory query, without filters,
weaker expectations, deleted assertions, longer waits or production changes.

1. In `postgres/search_candidate_migration_test.exs`, run the entire populated
   predecessor-upgrade test inside an outer `MigrationTestEnvironment.with_database`
   at candidate migration 20261010000000. Its nested predecessor remains
   20261009000400. Fresh and upgraded security/catalog/data/ranks now compare the
   same historical schema. Preserve the separate latest candidate catalog test.
2. In `postgres/search_candidate_ids_test.exs`, run the complete exact predecessor
   security/privileged-function inventory test at 20261010000000, retaining the
   nested predecessor and its exact one-function delta. Other latest tests remain.
3. In `search_projection_schema_test.exs`, run the complete Phase3 final-grants
   test at 20261010000000. Preserve all worker, projection-write, tag-write and
   extension denials. The separate current `KnowledgeGrantsTest` continues proving
   the exact approved Phase4 grants, forced RLS and excluded roles.
4. In `document_schema_test.exs`, run the complete established typed-head deletion
   race at pre-seal 20261010000000. Its original lock barrier, five-second lock
   deadline and exact `resources_typed_head_check` error remain. Add a separate
   latest-schema test proving a sealed typed Note deletion is rejected atomically
   by `note_source_set_seals_note_fkey`, without altering the current head,
   immutable generic/typed version identities or seals.

Each historical outer test asserts the exact target migration head and unchanged
enclosing latest repository configuration, migration head and relevant
catalog/security inventory after restoration. Do not modify the shared lifecycle
helper, fixtures, released migrations, security snapshot SQL or live production.
Owning full four-file SQL plus current Phase4 grants/sealing counterproofs and
independent SPEC then separate QUALITY must pass before a narrow local commit.

### Unknown short-literal plan failure: diagnosis only

The generic observer error does not establish its cause. Preserve all query,
unforced-plan, row-count, node-envelope, cleanup and fixed five-second production
deadline assertions. No retry, plan forcing, timeout increase, node filtering,
observer bypass or flaky-test classification is permitted.

First run the unchanged focused plan case. If it still fails or complete-run
reproduction needs finer evidence, add test-only opt-in bounded process-local
diagnostics to `test/support/knowledge_search_plan_observer.ex` and its owning
tests. Public error tuples remain identical. Preserve the first inner failure
rather than overwriting it with callback-wrapper failure. Keep only fixed stage
and error atoms, allowlisted exception class, allowlisted source-file identifier
and bounded line number; existing bounded backend and fixed case ordinal may be
included. Never retain exception messages/operands, stack arguments, queries,
parameters, NOTICEs, plans or result content. Restore diagnostic state in `after`.
Observer itself emits no Logger/telemetry/stdout event. The plan test may report
only the strictly closed content-free failure record after cleanup.

Stages distinguish setup/callback, original search/drain, trace delivery/pair
collection/cleanup, plan validation, local settings and final observer cleanup.
Owning regressions prove unchanged errors, first-error preservation, closed
bounded fields, content-canary exclusion, no process residue, zero log/query
telemetry and all trace/repo/default cleanup. A production repair may be designed
only after evidence identifies the actual cause. Run the complete observer and
plan suites, including the unchanged deadline barrier.

### Exact lifecycle contracts

Established Asset deletion changes Asset state, inserts `content.tombstones`
and releases matching `content.resource_assets`; it does not tombstone Resource.

- Historical attachment resolution retains the exact private Resource/version/
  Asset/AssetMetadata/ResourceAsset identity. Missing or ambiguous exact binding
  fails closed, never substitutes another surviving Asset. `deleted?` means
  Resource tombstone OR pending_delete/deleted Asset state OR matching Asset
  tombstone OR released exact association. Original metadata and pins remain
  readable after cleanup clears `asset_object_id`; do not require an object,
  original bytes or available state for this metadata-only reader.
  Before choosing metadata, require exactly one distinct candidate Asset ID
  across existing `assets`, `asset_metadata` and `resource_assets` evidence for
  the pinned version and authenticated owner. This identity population ignores
  classification, lifecycle state, object pointers and association release;
  the selected binding still requires every exact private join above. A count
  restricted to current private Asset rows could silently choose later B after
  original A is reclassified or reassigned to another version while its original
  metadata/association remains. Missing or diverged evidence must not rescue B.
  Execute this UNION-distinct admission and all exact private joins in one SQL
  statement/snapshot; separate count and selection statements are forbidden.
  Keep the candidate population entirely in SQL and return only the bounded
  scalar/metadata result, never an unbounded BEAM candidate list. The check
  relies on retained evidence, which supported lifecycle writers preserve; it
  cannot reconstruct identity after every original evidence row is irrecoverably
  removed or rewritten and does not prove custody or tamper-proof Asset identity.
  This is a reader-only fail-closed check, not new Asset identity immutability,
  fields, permissions, RLS, lifecycle writes or a historical backfill.
- Organization liveness requires an undeleted private supported Resource. Asset
  requires at least one exact unreleased, untombstoned private binding whose
  Asset is staging/uploaded/verified/available/processing/ready. Do not use an
  Asset Resource's null `current_version_id` as a head. A second live binding
  may keep the Resource live without changing a deleted historical attachment.
- New Note-source readiness and retained-member Save remain unchanged. Do not
  rewrite Asset deletion/cleanup, Resource tombstones, canonical history or the
  existing Note lock sequence.

Use SQL liveness before ordering/LIMIT/cursor admission, including both edge
endpoints. Keep kind/capability filtering, source-only selected-unrelate authority,
closed contexts/DTOs, source ordering, no-op audits and all privacy boundaries.

### One forward migration and shared SQL guard

Add one new forward migration; never edit released DDL or rewrite/backfill rows.
Create shared hardened SECURITY INVOKER functions using existing RLS:

1. `content.knowledge_asset_binding_is_live(owner, version, asset)` — exact
   live Asset binding predicate, read-only and lock-free.
2. `content.knowledge_resource_is_live(owner, resource)` — read-only/lock-free
   supported private Resource predicate with live Asset-binding existence.
3. A narrow `content.lock_knowledge_organization_resources(owner, resource_ids)`
   guard — VOLATILE, returning boolean, owning the complete witnessed lock
   sequence below. Accept one or two canonical distinct sorted Resource IDs;
   invalid/missing/nonlive input fails closed. No caller flag, previous-lock
   claim, transaction GUC, selected authority or arbitrary SQL input is accepted.

Revoke PUBLIC execution and grant only the required existing web/table-owner
callers. Existing web SELECT/UPDATE privileges already cover Asset/Resource row
locks and lifecycle tables; add no table privilege, role membership/attributes,
capability, custody/key change or new definer read surface. Existing organization
INSERT trigger remains its established definer authority; replace only its body
to invoke the shared guard and preserve `resource_tags_resource_check` /
`relationships_resource_check` names and sanitized errors. Existing canonical
organization rows remain historical, not invalidated or deleted by migration.

Guard implementation must retain exact operation-local binding witnesses
`{resource_id, resource_version_id, asset_id, owner_scope_id, classification}`.
It must not materialize an unbounded binding collection in BEAM: keep discovery
and witnessing inside SQL, retaining at most one live locked witness per Asset
Resource. Multiple legacy bindings remain supported without an invented cap.
Discover candidates in a single pre-Resource snapshot, traverse by Asset UUID,
lock needed Asset rows FOR SHARE in that global order, and record only exact
identities actually locked. If a waited-on candidate is no longer live, another
candidate from the original discovery may establish the witness before Resource
acquisition. Newly committed candidates outside that discovery cannot rescue it.
Stop witnessing after all Asset Resources have a witness; no Resource lock has
yet been acquired. Lock requested Resources sorted by UUID FOR SHARE. In a
subsequent SQL statement, revalidate Resource identity/private scope/liveness and
require each Asset Resource's live binding to be one of its recorded exact
witnesses. Hold through mutation and audit. If a binding disappears or no known
live witness remains, return false; never lock an unseen Asset after Resource
acquisition or retry away the race. Additional new bindings do not invalidate a
still-live held witness. Unrestricted liveness alone is not post-wait proof.

### Single lock ownership and actual-kind authority

Do not repeat discovery at metadata, repository and trigger layers:

- Attach/relate: the BEFORE INSERT trigger is the sole guard invocation and
  Asset→Resource lock owner, including `ON CONFLICT DO NOTHING`. Earlier Runtime
  resource metadata and repository liveness prechecks are lock-free snapshots;
  the trigger revalidates live scope before admitting canonical insertion.
- Detach and Runtime selected-unrelate: one explicit repository guard invokes
  the same shared SQL function before DELETE. Selected-unrelate locks/revalidates
  its source only, not a new live/readable target requirement. Preserve standalone
  unrelate's established behavior and absent/foreign no-op semantics.
- Read selectors/pages/history/export: lock-free lifecycle snapshots, without
  Asset locks. The historical source selector's containing-Note lock remains;
  this repair does not remove that source-membership protection.

Actual kind cannot change between lock-free metadata and Runtime capability
checks: `20260818000100` installs the global Resource BEFORE UPDATE OF kind guard
`enforce_note_resource_kind_update()`, raising
`resources_note_kind_immutable_check` on every kind change, not just Notes.
Preserve this guard and add actual-role Asset/Document/Note counterproofs. No
duplicate capability policy, mutable checked-state channel, extra port field or
new public signature is needed. Owner/private identity and current capabilities
remain revalidated in the same existing scoped authorization transaction; a
deletion after precheck makes the guard reject and rolls back all tag/audit
effects. No cross-page or historical-read snapshot permanence is promised.

Existing Note preparation locks Assets before Resources. Asset deletion retains
its object-advisory→Asset-lock→association-release path; finalization retains its
Asset lock. Organization takes no object advisory/object-row lock and no late
Asset lock. This preserves the supported writer ordering without a Vault change.

### Required RED and deterministic qualification

Use real `Api.delete_asset` composed with real Runtime Delete, Authorize,
OperationScope and SQL under permanent grants. Do not substitute direct Resource
tombstoning or a deletion double. Existing lease fixture limitations remain
explicit; this is not live byte/custody, browser or release acceptance.

- Delete an Asset with Note attachment, tag and both relationship directions.
  Prove Asset state/tombstone/association release while Resource deleted_at is nil;
  exact historical IDs/title/deleted marker, browse/backlink exclusion, selector/
  new attach/relate rejection with zero success audit and unchanged membership.
- Run normal logical cleanup clearing the object pointer; metadata still resolves.
  Preserve retained Save and reject new source references. Cover every six live
  states, different versions/multiple bindings, missing/ambiguous/foreign metadata.
  Native-web counterproofs must permit and establish original A's reclassification
  or version reassignment, preserve its old metadata/association, add valid B on
  the pinned version, then require historical resolution to fail closed rather
  than substitute B. Prove the role, owner context and identities before the
  reader assertion; do not change Asset update policy to make the test pass.
- Actual-role direct INSERT rejects deleted/missing/foreign/mismatched-context
  endpoints. Exact function ACL/invoker/path, unchanged table grants and global
  immutable-kind checks remain independently proved.
- Deterministic unheld-binding race: hold Asset A in a real deleting transaction;
  start organization until its Asset SHARE wait is observed; commit new live B
  on the same version from the supported upload path; finish deletion; organization
  must reject with no mutation/audit, not admit B. No arbitrary sleeps or retries.
- Control: add B while A stays live; the locked A witness still permits mutation.
  With organization holding A, real deletion waits until commit; later pages omit
  the deleted endpoint. Prove only one Asset-lock acquisition phase on INSERT.
- Note Save/finalization interleavings finish within unchanged deadlines without
  deadlock or masking retries. Preserve source-only selected-unrelate, capability
  epochs, paging, pin conflicts/idempotency and content-canary privacy assertions.

Ownership: new migration/shared SQL guard, Storage knowledge-link/organization/
Tag/Relationship repositories and owning SQL tests; Runtime organization,
Markdown-export and source-collection integration tests; actual Phase4 design/
plan/report. Runtime Operations/ports/DTOs need no new fields/signatures. No
AssetRepository/Delete/Note source readiness, extraction/search, backup wire,
Vault/custody, E2E or publication work.

### Owning-suite fixture and payload-privacy refinement

The broader Storage owning run reports eight Tag fixture failures and one
Organization permission-contract failure. Preserve those failures as FAIL.
These are necessary test-contract refinements, not new production permissions
or a claim that the original zero-Asset-column-access precondition is unchanged.
Independently review this detail before its test repair.

In `postgres/tag_repository_test.exs`, retain `Fixtures.two_vaults!()`, its IDs,
private staging Assets and every existing assertion. Locally compose the missing
exact private unreleased `resource_assets` association for each of its two
owners, using the established four-column fixture INSERT under the existing
test owner helper. Do not edit shared fixtures, create available objects or
change the resource kind. Prove the exact associations and unchanged staging
state/object absence; existing native-owner and audit counterproofs remain.

Organization selector metadata may inspect authenticated, RLS-visible Asset
identity and lifecycle columns solely to reject nonlive Resources. It must not
hydrate typed payloads or expose additional DTO fields. Refine the isolated
privacy test to deny table-level SELECT on all five typed tables while allowing
only `assets.id`, `resource_version_id`, `vault_id`, `classification` and `state`
to the existing web role, without grant option. Preserve all original five
table-denial assertions, exact resource metadata results and selected-edge
results. Rename the test/helper or explicitly explain the lifecycle allowance;
do not advertise metadata success without any Asset read authority.

Enumerate actual columns from the catalog and prove effective SELECT is true
only for those five Asset columns and false for every other Asset column and
every column of AssetMetadata, NoteVersion, DocumentVersion and DocumentFragment.
Under actual `singularity_web`, execute `assets.*`, each excluded Asset-column
and typed-table read probes, each in an isolated scoped transaction so expected
permission errors cannot poison later assertions. Prove live Asset metadata
succeeds, nonlive metadata rejects, foreign-owner and missing/revoked-membership
rows remain RLS-invisible, and removing the five lifecycle grants makes the
lifecycle-dependent selector fail closed. Preserve the closed two-key resource
and five-key selected-edge output shapes.

Keep the isolated-database guard and unconditional `after` cleanup. Snapshot
complete table and column privilege-entry inventories for all grantees on the
five affected tables, including grantor, privilege and grantability, before and
after. Mutate only web SELECT entries: temporarily remove existing web column
SELECT grants, then allow exactly the five lifecycle columns. Restore every
changed original table/column SELECT grant and grant option and prove exact
inventory equality, including unchanged worker and unrelated privileges.
Unsupported grantors must fail before any mutation; never approximate restoration
with broad grants. Preflight the complete inventories and reject any table or
column SELECT grant issued by `singularity_web`, including downstream grants to
PUBLIC, worker or other grantees, before the first mutation. Never use CASCADE.
Add a native-web downstream-grant counterproof proving preflight rejection and
unchanged complete inventories; do not rely on an eventual REVOKE failure after
earlier permissions were already changed. Preserve the original web table-SELECT
ACL assertions too.
This equality concerns privilege entries, not raw catalog NULL-versus-empty ACL
representation, which PostgreSQL may normalize after GRANT/REVOKE. Add explicit
cleanup-on-callback-failure coverage. No production grants, policies, roles,
capabilities, definer authority, ports or Vault changes are permitted.

## Verification and acceptance

Follow red/green focused contracts, independent SPEC then QUALITY review, and
small local commits. Required vectors include:

- Literal legacy fingerprints; ordered v2 references and mixed modes; invalid
  aliases/structs/bounds/privacy; unchanged legacy callers.
- Empty/nonempty seals, append/update/delete/reseal rejection, concurrent append,
  reverse insertion, gaps/bounds, early-immediate irreversibility, migration
  backfill and full V1/V2 reconstruction.
- Normal/stale/metadata-only saves and two-parent merge; independent omitted,
  clear and explicit modes; exact conflict sets and immutable old membership.
- Retained deleted sources/reordering versus changed/new live validation;
  forged/self/cyclic/non-lower parent, owner, UUID, kind, pins, fragment and
  locator rejection.
- Receipt replay after deletion with zero new effects, changed-intent conflicts,
  supported mutual-attachment/lifecycle races and unchanged deadlines.
- Current capability/RLS/revocation boundaries; content-canary checks for logs,
  exceptions, telemetry, audits, events and jobs.
- Tag normalization/idempotency/browse pages, directed duplicate/pin conflicts,
  deterministic live backlinks and restored endpoint behavior.
- Ordinary Markdown rendering, escaping, exact pins and empty byte compatibility.

Before local phase acceptance run the complete permitted README sequence,
including all unit/property/integration, complete restore, frontend, static
workflow, compile/format and zero-cycle checks. Keep E2E explicitly NOT RUN.
Record exact source, changed files, new migrations, commands/seeds/results,
review verdicts, remaining risks, owned-process/database cleanup and protected
worktree state in the Phase 4 acceptance report. Only then advance locally;
final browser/release acceptance and publication remain separately gated.
