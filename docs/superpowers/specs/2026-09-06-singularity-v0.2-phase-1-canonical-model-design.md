# Singularity v0.2 Phase 1 Canonical Knowledge Model

Date: 2026-09-06
Status: Approved by the user on 2026-09-06 following review of commit ba45d11.

## Authority and baseline

This design implements Phase 1 of
`docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`, under the
release design and ADR 0003. Phase 0 was accepted, merged, and pushed at
`6c3e8d5afb2cc9dbf264d276796070e16aa49e55`. On 2026-09-06 the remote main
reference still matched that revision; CI 33898634154 and Tests 33898633957
both reported success for it.

Planning branch: `codex/v0.2-phase-1-canonical-model`.
Worktree: `.trees/v0.2-phase-1-canonical-model`.
This document approves the Phase 1 design. Production implementation follows
the separate detailed implementation plan and its execution handoff.

## Scope and delivery boundary

Phase 1 establishes validated knowledge values, repository contracts, additive
schemas, and database integrity. Its executable acceptance operation is an
internal, scoped repository transaction creating a pending Document from an
accepted Asset reference idempotently. No public Runtime import operation,
worker registration, extractor, search projection, UI, or Note Save integration
is introduced here. Those remain Phases 2, 3, 4, and 6 respectively.

All seven existing application boundaries remain. New pure values live in
core; pure command preparation and repository behaviours live in domains;
Ecto, SQL, grants, and transaction composition live in storage. Existing generic
Core.Resource constructors remain compatible; typed Document values establish
their kind without adding mandatory fields to existing callers.

Vault behavior stays frozen. New values and commands do not expose a selectable
Vault concept. Storage adapters receive the already authenticated/scoped repo
and explicit internal owner/principal IDs derived from authenticated context.
The repo handle itself does not supply that context; RLS independently checks
the internal IDs against transaction scope. Production
activation, release, version changes, and deployment are outside this slice.

## Document identity and lifecycle

Reuse `content.resources` and `content.resource_versions`. A Document has kind
`document`, one explicit current version, and a one-to-one typed
`content.document_versions` row. Each accepted import initially creates a new
Document at revision zero. A repeated mutation returns the same identifiers;
a distinct mutation may import the same source as a distinct Document. Content
deduplication does not silently merge logical identities.

The typed row fixes resource/version identity, source Asset ID, source resource
and version IDs, source byte digest, media type, title, creator, classification,
and creation time at insertion. These fields never change. State, attempt
generation, adapter/format identifiers, completion digest/language, failure
code, and completion time are controlled lifecycle fields.

The approved storage approach is a guarded row. Runtime roles have no direct
UPDATE or DELETE privilege on Document versions or fragments. Narrow database
functions perform compare-and-set lifecycle transitions, and triggers reject
changes to immutable fields or ready rows even if a future grant is mistaken.

Legal transitions are:

- `pending -> extracting`: claim an attempt and increment its generation.
- `extracting -> ready`: atomically insert the complete fragment set and seal
  the version, recording adapter, format, digest, and completion time.
- `extracting -> failed|unsupported`: record only an allowlisted failure code
  and attempt-finished time; no fragments remain.
- `failed|unsupported -> pending`: explicit eligible retry clears outcome
  fields and retains immutable source identity. Eligibility and the public
  retry workflow belong to Phase 2.

A ready version never reopens. Failed/unsupported outcomes are not completed
canonical content: they may retry against the same immutable accepted bytes.
Every completion requires the active attempt generation. Stale attempts fail
without mutation. Exact replay of an already accepted completion succeeds only
when its canonical result matches; mismatched replay returns conflict. Phase 2
must define abandoned-attempt recovery before registering extraction workers.

Completion validates UTF-8, bounds, contiguous ordinals, deterministic IDs,
locator/media compatibility, and all digests before writing. Empty extraction
cannot become ready. Any invalid fragment rolls back the entire completion.
External extraction is never performed inside this transaction.

## Head constraints and source pins

The existing `resources_note_version_head_fkey` points every non-null head
directly at `note_versions`. Adding a kind alone cannot support Documents.
A forward migration replaces this with a generic composite head FK plus
deferred typed-head constraint triggers. At commit, every Note head must still
resolve to its own typed Note row, and every Document head to its own typed
Document row. The guards cover changes to resources and removal or retyping
of typed rows; a generic version alone cannot satisfy the typed-head rule.
Asset heads remain null. Note and Document heads are non-null and resolve to
their matching typed row. Migration preflight rejects any incompatible existing
Asset head instead of silently rewriting it.

All identity links carry the resource ID, version ID, owner encoding, and
classification as appropriate. Composite FKs enforce tuple membership rather
than merely proving that independent IDs exist. Typed kind guards prevent a
resource from masquerading as another kind. Deferred constraints permit atomic
resource/version/typed-row/head creation without exposing invalid committed data.

An accepted source pins an existing live, available Asset through its exact
resource-version-to-Asset association and object ID. The source byte digest is
SHA-256 over authenticated plaintext, not the existing ciphertext hash or keyed
lookup digest. A trusted preparation adapter streams and authenticates the
accepted object's bytes outside the mutation transaction and computes this
digest. Inside the transaction, storage locks and rechecks that the same live
Asset still references the accepted object and association. A changed reference
fails without creating a Document. Public callers cannot supply trusted digest
evidence. Changing the source association or digest of an accepted Document is
forbidden. The preparation contract and tests belong to Phase 1; public import
orchestration remains Phase 2.

The user approved a narrower Phase 1 acceptance boundary on 2026-09-07:
implement the bounded authenticated digest primitive, source-proof contract,
source revalidation, and isolated contract tests. Verify the real digest primitive
with encrypted fixtures and repository composition with injected test-only
preparation dependencies. Live runtime key-custody integration belongs to a
separately approved Phase 2 design; it is not a Phase 1 acceptance criterion.
No custody, key, capability, or Vault change is authorized. Production Document
writes remain disabled, and no test double is evidence of live source verification.

The initial Document model supports private sources, matching established
Notes classification. Sensitive/restricted Assets cannot be imported into a
private Document. This restriction applies to Document import and does not
change Asset classification behavior.

An existing Asset delete releases resource-Asset associations and may schedule
original-byte cleanup. A Document FK alone does not retain those bytes. Phase 1
therefore keeps Document creation internal and test-only from the application's
perspective. Before public import in Phase 2, its design must explicitly provide
source retention and deletion behavior that preserves original bytes for
Document download, history, export, and backup. No silent Asset deletion repair
or storage redesign is authorized by this design.

## Locators and fragments

`SourceLocator` is distinct from existing upload `SourceReference` provenance.
Its version-one encoding is an exact-key JSON object with a format version and
one kind: `pdf`, `markdown`, `text`, or `fragment`. Deterministic hashing uses
an explicitly ordered canonical tuple, never map iteration or JSON key order.

Pages and lines are one-based inclusive ranges; fragment ordinals are zero-based.
Character ranges are zero-based half-open Unicode codepoint offsets within the
identified page. Both endpoints must appear together. Negative/reversed ranges,
unknown keys, contradictory kind fields, invalid UTF-8, and NUL are rejected.
PDF requires a page; Markdown requires a heading path (possibly empty) and may
include a line range; text requires a line range; fallback requires an ordinal.
Heading paths preserve source spelling after NFC normalization. Locators and
text are private content and must not appear in diagnostics.

`DocumentFragment` contains its aggregate identity, ordinal, normalized text,
SHA-256 digest, locator, and optional heading metadata. A fragment ID is a
lowercase 64-character SHA-256 hex string over a domain-separated, length-framed
encoding of version ID, locator encoding, ordinal, and text digest. The prefix is
the UTF-8 bytes `singularity:document-fragment:v1` followed by NUL. Each subsequent
field has an unsigned 64-bit big-endian byte length followed by its bytes:
canonical UUID text, locator encoding, decimal ordinal text, and raw 32-byte
digest. Locator encoding uses that same framing over version `1`, kind, and its
kind-specific fields in page/start/end, heading-path/start-line/end-line,
start-line/end-line, or ordinal order respectively. Optional values use an empty
field; heading paths encode their decimal count followed by framed UTF-8 entries.
Integer fields use canonical decimal text without leading zeros. Other new
entity/version/mutation identifiers use canonical lowercase UUIDs. The detailed
plan includes literal encoding vectors to verify the encoder independently.

Each version has unique ordinals and fragment IDs; fragment rows are immutable.
The extraction algorithm remains Phase 2. Phase 1 validates supplied normalized
fragments and their identity without implementing parsing or segmentation.

## Attachments, citations, tags, and relationships

Attachments and citations are immutable children of an exact typed Note version.
Their FK includes that Note's identity tuple. Ordered sets use unique zero-based
ordinals and reject duplicates; storage validates a complete set atomically.
Changing a set later requires another Note version, implemented with explicit
Save in Phase 4. Phase 1 does not modify NoteSnapshot or existing fingerprints.
Phase 1 grants no runtime INSERT, UPDATE, DELETE, or write-function EXECUTE for
these source-set tables. Tests exercise complete-set persistence with disposable
test privileges. Phase 4 must add database-enforced sealing of set membership
before enabling writes, so even adding a child to an old version is forbidden.

Attachments pin a source resource and version. Initial targets are Assets,
Notes, and ready Documents in the same private owner scope; self-attachment is
rejected. Initial role is `source`. An optional NFC display label is bounded to
255 UTF-8 bytes. Attachment IDs are UUIDs unique within the owning Note version.

Citations initially target ready Document fragments because Notes currently
have no canonical fragment table. They pin the exact Note version, Document
resource/version, fragment ID, and locator. The locator must equal the referenced
fragment's locator, enforced by a database constraint trigger as well as pure
validation. Stable citation UUIDs may carry across Note versions; uniqueness is
per Note version. A citation cannot retarget within an existing Note version.
Tombstoning a source retains links; live resolution semantics belong to Phase 4.

Tags consist of a UUID, preserved NFC display spelling, and a normalized identity
key computed as NFC(casefold(NFC(trim(input)))). Use Erlang's Unicode
`:string.casefold/1` on the validated UTF-8 value and normalize its result to NFC.
Trim outer whitespace;
reject empty values, NUL/control characters, and display values over 255 UTF-8
bytes. The first accepted spelling wins on normalized collisions. Required vectors
include composed/decomposed accented letters and `Straße`/`STRASSE` mapping to
the same key. The database enforces owner/key uniqueness using bytewise key
comparison; the trusted adapter computes the key itself and never accepts a key
from an application-facing request. SQL uniqueness does not independently prove
the Unicode transformation. Adapter tests must prove that handcrafted inputs
cannot bypass normalization through the repository boundary.

Resource-tag assignments are unique by owner/resource/tag. Attach and detach
are idempotent; tombstone does not remove assignments. Tags and assignments are
mutable organization records, not resource versions.

Relationships have UUID identity, source/target resource IDs, optional exact
target version, and one of `related_to`, `references`, `derived_from`. They are
directed, reject self-links, and are unique by owner/source/target/type. Different
target pins for an existing edge conflict rather than silently replacing it.
Outgoing and incoming indexes support later backlink use cases. Initial endpoints
are private Assets, Notes, or Documents in the same owner scope. Mutable edge
operations retain audit records containing identifiers only.

## Persistence, isolation, and errors

Repository behaviours follow the existing domain-local convention, with focused
storage adapters for Document operations, immutable Note source sets, tags, and
relationships. No generic graph framework or shared receipt refactor is needed.
New commands reject unknown fields and conflicting atom/string aliases; adapters
revalidate handcrafted values at the trust boundary.

Document import receipts follow the existing Note receipt pattern: principal-
and owner-scoped mutation UUID, versioned 32-byte request fingerprint, claimed
transaction, and stored result identifiers. Replay compares canonical inputs and
returns the original result; mismatched inputs conflict. Receipt completion and
aggregate constraints must be validated before returning success. Concurrent
equivalent requests create one aggregate; any failure rolls back receipt and data.

Every new user table enables and forces RLS, uses the existing table owner and
authenticated scope predicates, and receives minimum role grants. Definer
functions revoke PUBLIC execution, fix search_path, use qualified identifiers,
validate live caller authority, and verify owner/principal against session scope.
They never accept a caller-selected scope as authority. New-table policies reuse
existing isolation semantics without modifying Vault tables or functions.

Database errors map to existing bounded Core.Error codes. SQL logging is disabled
for private values; returned errors do not include SQL, parameters, titles, text,
labels, locators, or excerpts. Outbox/job integration stays deferred. Internal
organization mutations record IDs and operation names in the existing audit
format; no user-visible label is audit metadata.

## Migration and backup boundary

Only new forward migrations are permitted. Order work as aggregate keys/head
constraints, Document rows and lifecycle functions, fragments, immutable Note
source links, then organizational metadata and receipts. Preserve the Phase 0
classification deferrability repair and all existing constraints' intent.
Migration tests must prove Notes remain typed correctly after the head change.

No backup format is extended in Phase 1. Existing V1/V2 fixtures and supported
Notes/Assets backup paths must stay green. To prevent successful backups from
silently omitting new data, all new canonical write tables and write functions
remain unavailable to production runtime roles in Phase 1, including Document
creation, lifecycle, tags, and relationships. Scoped integration acceptance uses
temporary grants in disposable databases, never production grants. There is no
public API or registered worker capable of creating these rows. Privilege tests
prove this boundary. Before any later phase enables production writes, it must
provide a fail-closed backup guard for unsupported canonical rows or complete
V3 support. This activation prerequisite cannot be waived by passing old fixtures.

## Verification and acceptance

Pure tests cover invalid inputs, source tuple mismatches, locator serialization,
deterministic fragment IDs, normalized tag collisions, and relationship rules.
Storage tests cover forward migration, all composite FKs, typed heads, missing
scope, cross-owner access, minimum grants, immutable rows, atomic source sets,
receipt replay/conflict/concurrency/rollback, lifecycle generations, stale
completion, and all-or-nothing fragment finalization.

Characterize existing Notes head, conflict, receipt, and Asset source-reference
behavior before changing shared constraints. Use focused tests while developing;
the complete README gate and independent specification/quality reviews remain
the phase acceptance requirement. Production migrations and live data are not
used for tests.

Acceptance requires idempotent internal pending creation from a validated Asset,
invalid references rejected in pure validation and PostgreSQL, no direct runtime
mutation of immutable content, unchanged supported Notes/Assets behavior, and
no Vault functionality changes. Report exact commits, files, migrations, commands,
results, and remaining limitations. Implementation, merge, push, and release
remain separate handoff decisions.
