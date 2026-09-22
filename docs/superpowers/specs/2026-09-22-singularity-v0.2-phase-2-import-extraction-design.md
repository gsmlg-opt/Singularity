# Singularity v0.2 Phase 2 Document Import and Extraction

Date: 2026-09-22
Status: Design approved in conversation; written specification awaiting user review.

## Authority and delivery boundary

This design covers Phase 2 of
`docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`. It builds on
the accepted Phase 1 canonical model at
`a80957da41582de40bdf586a0cba1e14644acf0a`. The worktree is
`.trees/v0.2-phase-2-import-extraction` on branch
`codex/v0.2-phase-2-import-extraction`.

Phase 2 supplies the first complete Document vertical slice: an authenticated
import of an existing Asset, durable original-byte retention, asynchronous
extraction, deterministic canonical fragments, status and retry, logical
delete/restore, and source/fragment reads. It extends the guarded Phase 1
Document aggregate. PostgreSQL remains canonical for structured data; original
bytes remain in the established encrypted Asset storage path. Search rows are
not written here. No new Note Save, backup V3, or browser workflow is included.

Core owns pure extraction results, locators, fragmentation, and retry
eligibility. Domains own use-case inputs and repository contracts. Ingest owns
format normalization and bounded extractor interfaces. Storage owns source
retention, guarded lifecycle transitions, source reads, and a fail-closed
backup guard. Runtime composes authenticated custody, outbox/Oban, and the
bounded Poppler process. Web remains unchanged in this phase. Domain code does
not depend on Ecto, Phoenix, filesystem, shell, PostgreSQL, or React.

Vault remains frozen compatibility substrate. New knowledge APIs derive
principal and owner scope from authenticated runtime context, never accept a
caller-selected scope, and reuse existing key-lease machinery without changing
keys, capabilities, custody semantics, Vault files, or Vault UX. No version
bump, push, release, or deployment is authorized by this design.

## Import and original-byte retention

Runtime import accepts an existing Asset ID, a title, and a mutation UUID.
Only a live, completed, available, private Asset with supported media type and
at most 64 MiB of authenticated plaintext is eligible. Phase 1's source
preparation computes a SHA-256 digest from authenticated plaintext outside the
mutation transaction. Runtime supplies the live digest operation through its
existing key lease; a caller cannot supply trusted digest evidence or source
identity fields.

The import transaction revalidates the exact Asset, resource version,
association, object, owner, classification, size, media type, and digest proof
against current source binding. It creates one pending Document and one
IDs-only extraction outbox event, or returns the established result of the
same mutation UUID and canonical inputs. A changed-input replay conflicts.
Concurrent identical requests cannot create duplicate versions or events.
Source preparation failure leaves no receipt, Document, or event.

The immutable `document_versions.source_object_id` is the durable retention
pin. Asset deletion remains allowed and retains its existing visible behavior.
Object cleanup treats an object as referenced when either a live Asset
association or **any** canonical Document version pins it, including a
tombstoned Document. The import transaction and cleanup decision serialize on
the source binding/object state: an import that wins leaves a retention pin;
cleanup that wins makes the source unavailable and import fails atomically.
An FK alone is not sufficient retention evidence. Phase 2 performs no
permanent Document purge, so tombstone does not release the pin. No plaintext
copy or second binary storage system is introduced.

A live Document's original-byte read resolves its pinned object directly
through the Document, with authenticated owner authorization and existing
decryption/authentication. It does not require its source Asset to remain
live. A tombstoned Document cannot be read through ordinary status, fragment,
or original-download APIs, although canonical data and original bytes remain
for later history, backup, export, and restore behavior. Deleting the source
Asset never changes Document identity, version, status, or fragments.

## Extraction attempt and recovery

Phase 1's guarded lifecycle is extended with database-owned attempt start,
deadline, and logical job identity. The logical job ID is the extraction
outbox-event UUID carried by the existing job envelope, not an untrusted
caller-provided or Oban-internal numeric ID. A claim binds the immutable
Document version, incremented generation, logical job ID, adapter and format
version, start time, and deadline in one guarded PostgreSQL transition.
The external extractor runs outside any long database transaction.

The extractor has a hard 120-second process timeout; an active attempt has a
fixed 180-second database deadline. The deadline is measured in the database,
not extended by worker restarts. A retry of the same logical job may resume
its unexpired generation. A different job cannot take over or complete it.
Once expired, a recovery transition atomically advances the generation and
permits a fresh attempt; the old worker's later completion or failure is
rejected. A restart or process crash therefore cannot strand a Document in
`extracting` indefinitely. Generation, job ID, state, and deadline all fence
terminal writes. No independent attempt ledger or Oban-state canonical source
of truth is added. A bounded periodic recovery pass scans expired attempts,
atomically returns each to `pending` while advancing its generation, and
emits one new IDs-only extraction event in the same transaction. Recovery
needs no plaintext access and is idempotent under concurrent scanners.

Before claiming, a worker resolves the pinned Document source, obtains an
existing key lease, authenticates its bytes, and rechecks the immutable
plaintext digest. If authenticated plaintext access is unavailable because
custody is locked, the Document remains `pending` and work is deferred until
access returns. Custody deferral consumes no extraction generation and must
not turn into a terminal failure through Oban exhaustion. If source access or
processing fails after claim, only a sanitized, allowlisted outcome is stored.
A digest mismatch before claim is an integrity incident: the worker does not
extract or claim, leaves the version pending, and surfaces only a sanitized
operator-visible failure for investigation. It must not retry the mismatched
bytes into a different canonical outcome.
The worker's successful terminal transaction validates and inserts the entire
fragment set before marking `ready`; no partial canonical fragments survive
failure. Exact replay of a completed identical result remains idempotent.

An already-claimed worker may safely finish after a logical delete because
its immutable source and version still exist. A worker that observes deletion
before claim stops without processing. Restore re-emits extraction only for a
version still pending or with an eligible terminal outcome; it does not reopen
a ready version.

## Format handling, fragmentation, and failures

Supported inputs are UTF-8 plain text, UTF-8 Markdown, and PDF with
extractable text. Text and Markdown are normalized to NFC and LF. A pure,
deterministic fragmentation function forms semantic blocks and splits large
blocks on stable boundaries without changing their order. Plain-text locators
use source line ranges; Markdown locators preserve heading path and available
line ranges; PDF locators preserve page and available character ranges.
Where a precise range cannot be justified after normalization or splitting,
use the versioned ordinal fallback locator rather than inventing provenance.
For the same Document version, equal immutable source bytes and
extractor/format versions produce equal ordered fragments, locators, IDs, and
extracted-text digest. Different Document versions have different fragment
IDs even when they import identical bytes.

PDF extraction uses a bounded, non-shell Poppler adapter that preserves page
boundaries. No OCR, Office parsing, persistent plaintext file, or renderer is
added. The runtime dependency is supplied consistently by devenv/Nix and
Docker. Extraction is limited to 64 MiB of source bytes, 16 MiB of normalized
text, 4096 PDF pages, and 4096 fragments, each at most 65,536 UTF-8 bytes.
The process has the 120-second hard timeout above. Limits are checked before
the final database transaction; storage independently enforces Phase 1's
fragment and digest constraints.

Malformed PDF, encrypted/password-protected PDF, invalid UTF-8, no
extractable text, and deterministic source/output/page limits become
`unsupported` with an allowlisted reason. Timeout and transient extractor,
storage, or post-claim custody failure become `failed`. Worker/process errors
are converted to sanitized codes; no source text, title, locator, excerpts,
SQL parameters, or external-tool stderr enters an exception returned to
users, logging, telemetry metadata, outbox payload, job arguments, or audit
metadata. A failed extraction preserves the original source and pin.

Manual retry is atomic: validate the version's terminal outcome and retry
eligibility, reset it to `pending`, and emit one new IDs-only event. A
transient `failed` outcome may retry with the same extractor. An
`unsupported` outcome may retry only after the relevant adapter or format
version changes; repeating the same deterministic failure is rejected.
The current adapter/format choice is checked at retry time, not trusted from
the caller. Oban exhaustion may record `failed` only if the exhausting
logical job and generation still own the active attempt. It cannot overwrite
a ready result, a recovery generation, or an unclaimed custody deferral.

## Runtime API and read semantics

Authenticated Runtime operations import an Asset; get or list live Documents
with bounded pagination; inspect extraction status; retry an eligible
outcome; logically delete or restore a Document; read ready fragments; and
stream the retained original of a live Document. Runtime generates canonical
resource/version IDs internally and derives owner scope from the session.
Application-facing input cannot select a different owner, source version,
object, digest, or attempt generation.

Status is canonical PostgreSQL state, not Oban state. Fragment reads return a
complete ordered set only for a live, ready version. Original reads are
authorized by the live Document rather than by current visibility of the
source Asset. Logical deletion immediately hides status details, fragments,
and original download from ordinary live reads while retaining version rows,
fragments, receipt, and bytes. Restore re-exposes a ready version or resumes
eligible pending/failed work without creating a new Document identity.
No Phase 3 search projection rows are produced by these operations.

## Backup compatibility and activation

The current V2 logical backup exporter cannot represent Phase 1's new
canonical knowledge rows. Before granting production Document writes, Phase 2
adds a fail-closed, snapshot-consistent check at backup creation. It refuses a
V1/V2 backup whenever that owner scope contains a Document or any other new
canonical row not represented by that format. The refusal is an explicit,
sanitized unsupported-backup result; it cannot create an apparently successful
bundle that silently omits data. Existing supported V1/V2 Notes and Assets
fixtures remain valid. Full V3 backup and restore remain Phase 5.

The guard is an activation prerequisite, not a claim that V2 can back up
Documents. No Phase 2 production deployment is approved here. If production
Document writes are separately enabled before V3 exists, operators must
expect V1/V2 backups to refuse that owner scope until Phase 5 supplies V3.
No Vault behavior or existing backup wire format changes.

## Verification and acceptance

Characterize existing Asset deletion/cleanup, download, source preparation,
Document lifecycle, outbox/Oban, and V2 backup behavior before changing them.
Add a failing focused contract before each change to enforced behavior. Use
only new forward migrations; do not edit a released migration. Keep RLS,
minimum grants, immutable-field guards, and the seven-application dependency
graph intact.

Focused pure and integration tests cover:

- successful import of text, Markdown, and multipage PDF with deterministic
  fragments and provenance; malformed, encrypted, scanned/empty, invalid
  UTF-8, oversized, timed-out, and no-text cases;
- replay, changed-input conflict, concurrent import, atomic receipt/outbox
  creation, cross-owner denial, and custody-unavailable deferral;
- Asset deletion racing with import, object cleanup pinning, source read after
  Asset deletion, tombstone retention, and live-only read authorization;
- duplicate dispatch, worker interruption, same-job resume, deadline
  reclamation, stale completion/failure rejection, Oban exhaustion, manual
  retry eligibility, and restore scheduling;
- all-or-nothing fragment persistence, deterministic limits, source-digest
  mismatch, absence of partial search rows, and absence of content in
  diagnostics or event/job metadata;
- V1/V2 backup refusal with unsupported canonical rows and unchanged
  successful backup behavior for supported legacy data; and
- identical extractor capability in Docker and devenv.

The complete README verification gate is required before Phase 2 acceptance:
format, warnings-as-errors compilation, tests, integration, restore, JS,
browser E2E, build, zero xref cycles, workflow lint, and diff checks. This
phase does not inherit the earlier E2E deferral. Record the exact commit,
migrations, changed files, commands and results, remaining risks, and explicit
confirmation that no Vault feature work occurred. A focused green result or
design approval is not implementation acceptance. The separate detailed
implementation plan is the next gate after user review of this written spec.
