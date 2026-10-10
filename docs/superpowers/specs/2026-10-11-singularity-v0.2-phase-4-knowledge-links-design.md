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

Exact Note-version DTOs include ordered owner-free source references; conflicts
include the competing version's sources. Add exact selectors
`resolve_note_attachment(session, note_id, version_id, attachment_id)` and
`resolve_note_citation(session, note_id, version_id, citation_id)`. Require
`note.read` on the containing Note and the target's existing read capability.
Response pins stay exact, with live/deleted status; deleted sources retain
historical evidence instead of silently becoming a newer version. Do not
return new binary bytes through this API: existing Asset download remains the
only original-byte delivery path.

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
Fetch `limit + 1`; return owner-free `items` and `next_cursor`, not a silently
truncated list. These are live pages, not a snapshot guarantee across mutations.
Retain the existing internal tag-list signature but do not reuse its `LIMIT 100`
as a complete public list. Test a resource with more than 100 tags across pages.
Filter source and target visibility/kind/read capability before admitting rows,
not by disclosing an unfiltered count. No generic graph traversal is added.

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
