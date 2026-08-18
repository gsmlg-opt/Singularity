# Milestone 2 Private Markdown Notes Design

**Status:** Approved design

**Date:** 2026-08-18

**Governing architecture:** [`docs/guide.md`](../../guide.md)

**Extends:**
[`2026-07-18-foundation-asset-vertical-design.md`](2026-07-18-foundation-asset-vertical-design.md)

**Observability boundary:**
[`2026-08-11-supported-observability-boundary-design.md`](2026-08-11-supported-observability-boundary-design.md)

**Delivery scope:** The first Milestone 2 vertical: private Markdown notes

## 1. Purpose

This design adds the first editable knowledge type to the completed Singularity
foundation. It delivers private Markdown notes with immutable version history,
deterministic conflict preservation, current-version PostgreSQL lexical search,
portable Markdown export, tombstone and restore behavior, logical backup and
restore, and a focused Notes workspace.

The slice must preserve the foundation invariants:

- PostgreSQL is canonical for structured note data.
- Every note snapshot is immutable.
- Search and future vector indexes are rebuildable projections.
- Authorization is enforced before retrieval and again by forced RLS.
- Web code calls only `Singularity.Runtime.Api`.
- Supported application logs, telemetry, audit, outbox, and errors never carry
  note titles or Markdown.
- Qdrant remains required for later semantic vector search, but this slice does
  not depend on Qdrant availability.

## 2. Approved decisions

The approved direction is:

- A focused split editor with a compact note rail, large Markdown canvas, and
  an on-demand Preview, History, and Conflict drawer.
- Explicit Save only. There is no autosave.
- Typed immutable note snapshots linked one-to-one with generic resource
  versions.
- One canonical head per note.
- A stale Save preserves the submitted snapshot, opens a conflict, and leaves
  the canonical head unchanged.
- A merge creates a new two-parent snapshot and resolves the selected conflict.
- Internal revisions are zero-based; the UI displays `revision + 1`.
- Title is part of every immutable snapshot. `content.resources.title` remains
  the canonical-head projection.
- PostgreSQL stores canonical Markdown text and the current-version lexical
  projection.
- Search returns only live canonical versions and pins every result to its exact
  `resource_version_id`.
- Export returns the canonical UTF-8 Markdown bytes as a safely named
  `<title>.md` file without frontmatter or a proprietary wrapper.
- Deletion tombstones the resource and removes retrieval projections while
  retaining history. Restore rebuilds projections from the same canonical head.
- The first slice supports only `private` classification.
- Preview supports a safe Markdown subset. It does not execute raw HTML, load
  remote images or embeds, or accept unsafe URL schemes.

## 3. Delivery boundary

### 3.1 In scope

- Pure note snapshot and conflict values.
- A `Singularity.Domains.Notes` context and persistence behaviour.
- PostgreSQL schemas, forced-RLS policies, grants, and adapters for notes,
  conflicts, lexical search, and mutation receipts.
- Private-note read, write, and export capabilities.
- Create, open, list, search, Save, history, merge, tombstone, restore, and
  export use cases.
- Idempotent note mutations.
- Current-only PostgreSQL full-text search.
- Logical-backup format version two with backward-compatible version-one
  restore.
- A `/notes` LiveView hosting a React Notes App Clip.
- A controller-backed Markdown export route.
- Scoped unit, integration, LiveView, frontend, browser, backup, RLS, and
  secret-canary acceptance.

### 3.2 Explicitly deferred

- Attachments and ESS integration.
- Tags, collections, and relationships.
- PDF import and body-text extraction.
- Citations and RAG.
- Qdrant vector indexing and semantic-search UI.
- Agents and model calls.
- Device synchronization.
- Autosave and offline drafts.
- CRDTs, real-time collaboration, and live cross-device merge.
- Public, sensitive, or restricted notes.
- Rich-text or WYSIWYG editing.

The schema and events must leave a clean Qdrant projection seam, but no Qdrant
dependency, collection, worker, configuration, or acceptance claim belongs to
this slice.

## 4. Application architecture

The Notes vertical follows the existing seven-application dependency graph:

```text
NotesWorkspace (React App Clip)
  -> Singularity.Web.NotesLive
  -> Singularity.Runtime.Api
  -> Singularity.Runtime.Notes.*
  -> Singularity.Domains.Notes
  -> Singularity.Domains.Notes.Repository
  -> Singularity.Storage.Postgres.NoteRepository
  -> PostgreSQL
```

Lexical reads follow the existing retrieval boundary:

```text
Singularity.Runtime.Notes.Search
  -> Singularity.Retrieval.NoteLexicalSearch
  -> Singularity.Storage.Postgres.NoteSearchStore
```

### 4.1 Ownership

`singularity_core` owns:

- Pure note snapshot and conflict values.
- Validation of IDs, classification, revision, parents, title, and Markdown.
- Stable result shapes and existing stable errors.
- No Ecto, Phoenix, React, PostgreSQL, or Qdrant references.

`singularity_domains` owns:

- Note commands and state-transition decisions.
- Create, Save, merge, delete, restore, and export intent construction.
- The repository behaviour for atomic note operations.
- No concrete adapter selection.

`singularity_storage` owns:

- Migrations, Ecto schemas, forced RLS, grants, and scoped SQL.
- Atomic note persistence and revision allocation.
- Current-version lexical projection persistence.
- Mutation receipts.
- Logical-backup version-two export and restore.

`singularity_retrieval` owns:

- Note search query validation, ranking, and cursor semantics.
- Search page value types.
- No canonical note mutation.

`singularity_runtime` owns:

- Session, vault-lock, capability, and classification enforcement.
- One use-case module per public note operation.
- Adapter composition and DTO conversion.
- The sole application-facing `Singularity.Runtime.Api` functions.

`singularity_web` owns:

- Routes, LiveView event validation, controller headers, and serialization.
- The App-Clip bridge and React workspace.
- Safe Markdown presentation.
- Local unsaved draft state.
- No domain rules and no direct storage or retrieval calls.

## 5. Canonical PostgreSQL model

All new canonical and projection tables live under `content`. Every table that
contains vault data has `vault_id`, forced RLS, a table-owner policy, a
vault-isolation policy for its approved runtime roles, and the minimum grants
required by its adapter.

### 5.1 `content.resources`

Extend the existing resource table with:

```text
kind                 text, required, `asset | note`
current_version_id   uuid, nullable for legacy/in-flight asset resources
```

Existing rows are backfilled as `asset`. A note resource must have a canonical
`current_version_id`. The note-creation transaction pre-generates the resource
and version IDs and uses a deferred composite foreign key so the mutually
referencing resource and first version become valid together at commit.

Database integrity requires:

```text
CHECK (kind <> 'note' OR current_version_id IS NOT NULL)
UNIQUE (id, vault_id, classification)
UNIQUE (id, current_version_id, vault_id, classification)
FOREIGN KEY (current_version_id, id, vault_id, classification)
  -> note_versions(resource_version_id, resource_id, vault_id, classification)
  DEFERRABLE INITIALLY DEFERRED
```

The deferred target is the typed note table, not merely the generic version
table. A note therefore cannot point at an asset or another resource's version.

The existing columns retain these meanings:

- `title` is the canonical-head title projection.
- `classification` is `private` for this slice.
- `deleted_at` is the tombstone marker.
- `metadata` is not used for note body, lineage, or conflict data.

The canonical head is always the explicit pointer. It is not inferred from the
greatest revision because a competing conflict version may have a greater
revision than the accepted head.

### 5.2 `content.resource_versions`

The existing table remains the generic immutable version identity:

```text
id
resource_id
vault_id
classification
revision
inserted_at
updated_at
```

Add the composite uniqueness and foreign key needed to bind identity, vault,
and classification across the aggregate:

```text
UNIQUE (id, resource_id, vault_id, classification)
FOREIGN KEY (resource_id, vault_id, classification)
  -> resources(id, vault_id, classification)
```

`revision` is a monotonically allocated snapshot-creation sequence scoped to a
resource. Revision zero displays as Version 1. Canonical, competing, and merge
snapshots all consume revisions.

### 5.3 `content.note_versions`

Each note snapshot has exactly one generic resource version:

```text
resource_version_id       uuid, primary key
resource_id               uuid, required
vault_id                  uuid, required
classification            text, required and `private`
title                     text, required
markdown                  text, required
created_by_principal_id   uuid, required
parent_version_id         uuid, nullable only for the initial snapshot
merge_parent_version_id   uuid, nullable for normal saves
inserted_at               timestamptz, required
```

The table provides:

```text
UNIQUE (resource_version_id, resource_id, vault_id, classification)
FOREIGN KEY (resource_version_id, resource_id, vault_id, classification)
  -> resource_versions(id, resource_id, vault_id, classification)
FOREIGN KEY (parent_version_id, resource_id, vault_id, classification)
  -> note_versions(resource_version_id, resource_id, vault_id, classification)
FOREIGN KEY (merge_parent_version_id, resource_id, vault_id, classification)
  -> note_versions(resource_version_id, resource_id, vault_id, classification)
```

Parent foreign keys are deferrable for version-two restore. These constraints
ensure the snapshot and both parents belong to the same note, vault, and
classification. A merge parent must differ from the normal parent.
`note_versions` rows are immutable after insert. Database grants do not permit
application UPDATE or DELETE.

The initial snapshot has no parents. A normal or competing Save has one parent:
the submitted base version. A successful merge has two parents: the canonical
head used for the merge and the competing version being resolved.

### 5.4 `content.note_conflicts`

Conflicts are explicit records rather than a derived boolean:

```text
id                       uuid, primary key
resource_id              uuid, required
vault_id                 uuid, required
classification           text, required and `private`
base_version_id          uuid, required
canonical_version_id     uuid, required
competing_version_id     uuid, required
state                    text, `open | resolved`
resolution_version_id    uuid, nullable until resolved
created_at               timestamptz, required
resolved_at              timestamptz, nullable until resolved
```

The stored canonical version is the head observed when the stale Save was
accepted. A later merge uses the then-current canonical head as its normal
parent. Resolving one conflict does not implicitly resolve any other open
conflict.

State and timestamp checks require an open conflict to have no resolution and
a resolved conflict to have both a resolution version and `resolved_at`.
Composite foreign keys target the typed `note_versions` uniqueness above for
the base, observed canonical, competing, and resolution versions, always with
the conflict's resource, vault, and classification.

### 5.5 `content.note_search_documents`

The current-version lexical projection contains one row per live note:

```text
resource_id          uuid, primary key
resource_version_id  uuid, required
vault_id             uuid, required
classification       text, required and `private`
title                text, required
markdown             text, required
head_inserted_at      timestamptz, required
search_vector        generated tsvector over title and Markdown
updated_at           timestamptz, required
```

The generated vector uses PostgreSQL's `simple` configuration for predictable
language-neutral behavior in this first slice. A GIN index supports matching;
vault, canonical `head_inserted_at`, and resource ID support deterministic
pagination. Projection `updated_at` is operational metadata only and never
participates in result ordering because reconciliation and restore may rewrite
it.

The repository upserts this row only when the canonical head changes, deletes
it synchronously when the resource is tombstoned, and recreates it on restore.
Competing versions never enter this table.

A composite foreign key from
`(resource_id, resource_version_id, vault_id, classification)` to
`resources(id, current_version_id, vault_id, classification)` proves that each
row names the resource's canonical head. A second composite foreign key targets
the same typed `note_versions` snapshot.

### 5.6 `content.note_mutation_receipts`

Every mutation carries a client-generated UUID `mutation_id`. A receipt is
written in the same transaction:

```text
vault_id            uuid, required
principal_id        uuid, required
mutation_id         uuid, required
operation           text, required
request_fingerprint bytea, required, 32 bytes
state               text, `pending | completed`
outcome             text, nullable until completed
resource_id         uuid, required
version_id          uuid, nullable
conflict_id         uuid, nullable
inserted_at         timestamptz, required
PRIMARY KEY (vault_id, principal_id, mutation_id)
```

Before entering the repository, Runtime computes `request_fingerprint` as
HMAC-SHA-256 over every caller-supplied field of the validated canonical command
using a dedicated runtime mutation-fingerprint secret. Server-generated result
IDs are not part of the fingerprint. The secret is distinct from signing,
session, audit-fingerprint, vault, and encryption keys and is never persisted,
logged, backed up, or returned.

The repository first inserts a `pending` receipt. The same transaction must
complete it before commit; rollback removes it. PostgreSQL uniqueness serializes
simultaneous claims. After a winning transaction commits, a waiter reloads the
completed receipt. A repeated key must match vault, principal, operation,
caller-supplied resource identity when present, and request fingerprint or it is
`invalid`. Create has no caller-supplied resource identity; the winning receipt
owns its pre-generated resource ID and every replay returns that same ID.

A check constraint requires `pending` receipts to have no outcome/result IDs and
`completed` receipts to have an outcome plus the identifiers required by that
operation. Application code never commits a pending receipt.

Receipts contain no title or Markdown. Replaying the same mutation returns the
recorded result references without creating another version or conflict.
Receipts are operational state, excluded from logical backup, and start empty
after restore. Restored systems invalidate pre-restore sessions, so an old
browser request cannot cross the restore boundary.

## 6. Domain and runtime contracts

### 6.1 Core values

The pure note values represent:

- An immutable note snapshot.
- A normal one-parent version.
- A two-parent merge version.
- An open or resolved conflict.
- A Save outcome of `saved` or `conflict`.

They enforce private classification and exact parent shapes before a repository
intent exists.

### 6.2 Domain context

`Singularity.Domains.Notes` provides pure orchestration for:

- `create`
- `save`
- `merge`
- `tombstone`
- `restore`

It validates a command, builds one atomic intent, and invokes
`Singularity.Domains.Notes.Repository`. Read and search behavior remains in
runtime/retrieval modules rather than turning the domain context into a query
facade.

The repository behaviour accepts an already-scoped repository context and
intent-oriented callbacks. It never accepts a global Ecto Repo.

### 6.3 Runtime use cases

Use one focused module per operation under `Singularity.Runtime.Notes`:

```text
Create
Get
Search
Trash
History
Save
Merge
Delete
Restore
Export
```

Each use case:

1. Converts a runtime session to `SessionContext`.
2. Requires an unlocked vault.
3. Authorizes the exact capability and private classification.
4. Enters a vault-scoped read or shared-request operation.
5. Invokes the domain, retrieval, or repository boundary.
6. Returns a stable internal result for `Runtime.Api` conversion.

### 6.4 Capabilities

Add and grant the owner these exact capabilities:

```text
note.read
note.write
note.export
```

Authorization requirements are:

- `note.read`: list, search, Trash, open, exact-version read, and history.
- `note.write`: create, Save, merge, tombstone, and restore.
- `note.read` plus `note.export`: Markdown export.

Classification is fixed by server composition. No client request includes a
classification selector.

The request-authorization requirement accepts exactly one of:

```text
required_capability: "one.name"
required_capabilities: ["first.name", "second.name"]
```

The plural form is a non-empty, sorted, duplicate-free conjunction; every named
capability must be active. Existing asset, vault, backup, and job requirements
retain the singular field unchanged. Note export uses
`required_capabilities: ["note.export", "note.read"]`. Supplying both fields or
a malformed list is `invalid`.

### 6.5 Runtime API and DTOs

`Singularity.Runtime.Api` remains the only application-facing facade. It adds
functions corresponding to the runtime use cases and returns only these DTO
families:

`NoteSummary`:

```text
resource_id
resource_version_id
title
revision
display_version
updated_at
deleted?
open_conflict_count
```

`Note` extends the summary with canonical `markdown`.

`NoteVersionSummary` contains:

```text
resource_version_id
revision
display_version
created_by_principal_id
inserted_at
parent_version_id
merge_parent_version_id
canonical?
conflict_state
```

`NoteVersion` extends `NoteVersionSummary` with `resource_id`, immutable title,
and immutable Markdown. It is used only for authorized exact-version, history,
and conflict reads; it is never returned by list or search.

`NoteConflict` contains the conflict ID and exact canonical, competing, and
base version references. Full source snapshots are fetched only when the user
opens merge mode.

`NoteSearchPage` contains `items` and an opaque `next_cursor`. Every item pins
the exact canonical `resource_version_id`. The first slice does not return body
snippets.

`NoteTrashPage` contains tombstoned `NoteSummary` items, `deleted_at`, and an
opaque cursor. It is ordered by canonical deletion time and never queries the
lexical projection.

`NoteHistoryPage` contains `NoteVersionSummary` items and an opaque
`next_cursor`.

`NoteConflictDetail` contains the conflict ID, base and observed-canonical
references, the current canonical `NoteVersion`, and the competing
`NoteVersion`. Merge always names the returned current canonical version rather
than assuming the observed canonical reference is still current.

`NoteSaveResult` contains:

```text
outcome                  `saved | conflict`
canonical                Note
submitted_version_id     uuid
conflict_id              uuid, present only for `conflict`
```

For `saved`, `submitted_version_id` equals the canonical version and
`conflict_id` is absent. For `conflict`, canonical remains the accepted head and
the submitted version is the preserved competitor.

`NoteExport` contains:

```text
resource_id
resource_version_id
filename
media_type
markdown
```

A Save returns `{:ok, NoteSaveResult}` with outcome `saved` or `conflict`. A
stale Save is therefore a successful persistence result, not
`Core.Error(:conflict)`.

## 7. Mutation semantics

All mutations run inside one authorized, scoped PostgreSQL transaction. The
resource row is locked before revision allocation or state comparison.

The locked resource-state matrix is exact:

```text
create     no existing resource
save       live only
merge      live only
tombstone  live only
restore    tombstoned only
```

An operation attempted in the opposite lifecycle state returns `not_found`
without writing a version, conflict, projection, audit, outbox, or receipt,
unless the same completed mutation receipt is being replayed.

### 7.1 Create

Create performs the following atomically:

1. Claim or replay the mutation receipt.
2. Insert a `note` resource with a pre-generated first-version pointer.
3. Insert resource revision zero.
4. Insert the immutable note snapshot with no parents.
5. Insert the current lexical projection.
6. Insert identifier-only audit and outbox records.
7. Complete the mutation receipt with the resource and version IDs.

### 7.2 Save from the canonical head

Save first requires `deleted_at IS NULL` under the resource lock. A tombstoned
note returns `not_found` and creates no version. When
`base_version_id == current_version_id`:

1. Allocate the next resource revision.
2. Insert the generic version and immutable one-parent note snapshot.
3. Update the resource head and title projection.
4. Upsert the lexical projection to the same version.
5. Insert identifier-only audit and outbox records.
6. Complete the receipt as `saved`.

The repository never updates an existing snapshot.

### 7.3 Save from a stale version

When the live resource's submitted base belongs to the note but is not its
current head:

1. Allocate the next resource revision.
2. Insert the generic version and immutable one-parent competing snapshot.
3. Insert an open conflict referencing the submitted base, observed canonical
   head, and competing version.
4. Leave resource head, title, and lexical projection unchanged.
5. Insert identifier-only audit and outbox records.
6. Complete the receipt as `conflict`.

If two requests race from the same head, the resource lock deterministically
allows one to advance the head and causes the other to become a preserved
conflict. No accepted Markdown is discarded.

### 7.4 Merge

A merge command includes:

```text
mutation_id
resource_id
conflict_id
expected_current_version_id
competing_version_id
title
markdown
```

The repository requires `deleted_at IS NULL`, the conflict to be open, and its
competing version to match. A tombstoned note returns `not_found`. If the
expected head is still current, it creates a two-parent snapshot, advances
head/title/search, marks only that conflict resolved, and records the resolution
version.

If the head changed, the command creates nothing and returns the stable
`:conflict` error. The browser keeps the local merge draft while the vault
remains unlocked and asks the user to reload the new head before retrying.

### 7.5 Tombstone

Delete includes the expected canonical version. If it is stale, the repository
returns `:conflict` without mutation. Otherwise it:

- sets `deleted_at`;
- deletes the lexical projection;
- retains the head, immutable snapshots, conflicts, and title projection;
- writes audit/outbox/receipt records atomically.

Normal list, search, open, and export operations treat a tombstoned resource as
`not_found`. The Trash view uses a dedicated authorized query.

### 7.6 Restore

Restore requires a tombstoned note and reuses its existing canonical head. It
clears `deleted_at`, recreates the lexical projection from that exact snapshot,
and writes audit/outbox/receipt records in one transaction. It does not create
a content version.

### 7.7 Mutation replay

The receipt key is scoped to vault and principal. A repeated mutation ID with
the same operation, caller-supplied resource identity when applicable, and
request fingerprint returns the recorded result references. Any mismatch is
`invalid`. The adapter reloads current DTO state before returning, so a replay
never returns stale plaintext captured in the receipt.

## 8. Projection and outbox behavior

PostgreSQL lexical projection changes are synchronous with the canonical
mutation. There is no window in which PostgreSQL search can return a deleted or
non-canonical version after the transaction commits.

Lifecycle events use stable, identifier-only payloads such as:

```text
note.current_changed
note.conflict_created
note.conflict_resolved
note.deleted
note.restored
```

Payloads contain opaque IDs, private classification, correlation ID, and the
required capability; they contain no title or Markdown.

The first-slice note projection handler idempotently reconciles PostgreSQL's
current projection with the canonical resource state and acknowledges these
events. This provides a repair path without making search eventual. A later
Qdrant rollout will first rebuild all current vectors, then add its adapter to
the same canonical-state reconciler. It must not reinterpret historical event
payloads as canonical content.

Stale outbox delivery always reads the current resource state. It therefore
converges to the latest canonical head or deletion state instead of resurrecting
an older version.

## 9. Lexical search and reads

### 9.1 Search

Search requires an unlocked vault and `note.read`. The query applies vault,
classification, and live-resource predicates before ranking candidates.

The first-slice ordering is deterministic:

1. PostgreSQL text-search rank descending when a query is present.
2. Canonical head `inserted_at` descending.
3. `resource_id` ascending as the final tie-breaker.

The opaque cursor encodes only bounded ordering values and filter identity. It
does not contain Markdown or titles. An empty query lists live notes by recency.

### 9.2 Exact-version reads

Opening a search result carries both resource and version IDs. Runtime verifies
that the version belongs to the resource and vault. The response identifies
whether the pinned version remains canonical. This prevents a search result
from silently changing content between result selection and display.

If the pinned version is no longer canonical, the workspace shows that exact
snapshot read-only in the History drawer and offers an explicit Open current
action. It does not place stale content into the writable canonical editor.

The normal editor opens the canonical version. History and conflict drawers
may request exact retained versions.

### 9.3 History

History is cursor-paginated by revision descending. It marks the explicit
canonical head, open competing versions, resolved conflicts, and merge parents.
The maximum revision is not labeled canonical unless it matches the resource
pointer.

### 9.4 Trash

Trash is a separate cursor-paginated authorized query over tombstoned note
resources and their canonical typed snapshots. It uses `deleted_at` descending
and `resource_id` ascending, does not consult `note_search_documents`, and does
not search Markdown. It supplies the only list path used by Restore.

## 10. Portable Markdown export

The authenticated, unlocked browser route is:

```text
GET /api/v1/notes/:resource_id/export
```

The controller calls only `Singularity.Runtime.Api`. Runtime reads one live
canonical snapshot under `note.read` and `note.export`, records an export audit
event, and returns `NoteExport`.

The response uses:

```text
Content-Type: text/markdown; charset=utf-8
Content-Disposition: attachment; filename=...; filename*=UTF-8''...
Cache-Control: no-store
X-Content-Type-Options: nosniff
```

The body is the stored Markdown bytes exactly. Export adds no title, frontmatter,
metadata, version marker, or proprietary wrapper.

Filename handling affects only `Content-Disposition`. The current title gains
`.md`; CR, LF, NUL, path separators, and unsafe controls are replaced. If no
safe filename remains, use `note.md`.

## 11. Notes web workspace

### 11.1 Route and mount

Add `/notes` to the existing authenticated, vault-unlocked LiveView session and
top-level navigation. `Singularity.Web.NotesLive` hosts one App-Clip mount:

```heex
<div
  id="notes-workspace"
  phx-hook="MountNotesWorkspace"
  phx-update="ignore"
  data-props={...}
></div>
```

Disconnected initial props contain the versioned bridge contract, vault state,
filters, and note summaries. They do not contain Markdown. The connected App
Clip explicitly opens the selected note before populating the editor.

`NotesLive` validates exact request keys and calls only `Runtime.Api`. The
bridge validates exact reply shapes before changing React state.

### 11.2 Bridge operations

The version-one bridge supports:

```text
note:search
note:trash
note:open
note:create
note:save
note:history
note:conflict
note:merge
note:delete
note:restore
navigate
```

Export uses the controller route rather than carrying file bytes through the
LiveView bridge.

There is no first-slice PubSub or live-collaboration channel. Concurrency is
detected authoritatively at Save or merge time.

### 11.3 Focused split layout

The approved workspace contains:

- A compact left rail for current search, active notes, and a Trash filter.
- A large center canvas with title, Markdown source, explicit Save, version,
  dirty state, and merge mode.
- A collapsed-by-default right drawer with mutually exclusive Preview,
  History, and Conflict views.

On narrow screens, the rail and drawer become explicit panels while the editor
remains the primary surface. The controls retain their identities and do not
collapse into indistinguishable layouts.

### 11.4 Draft and conflict behavior

React owns only the unsaved draft and presentation state. It records the exact
base version loaded into the editor.

- Save is enabled only for a valid dirty draft.
- Selecting another note or navigating away with a dirty draft requires an
  explicit Stay or Discard choice.
- A retryable storage failure keeps the draft while the vault remains unlocked.
- A preserved stale Save enters conflict mode using the persisted competing
  version.
- Merge mode loads the current canonical and competing snapshots, places the
  user-authored result in the main canvas, and submits only on Save merge.
- Reply generations prevent an older open, search, history, or mutation reply
  from overwriting newer state.
- Vault lock or session expiry synchronously clears summaries, Markdown,
  history, conflict sources, and drafts before navigating to Unlock.

## 12. Validation and safe Markdown

### 12.1 Request limits

- All bridge payloads are exact versioned objects. Unknown keys are invalid.
- IDs and mutation IDs are canonical UUIDs.
- Title is trimmed, non-empty UTF-8 and at most 255 bytes after trimming.
- Markdown may be empty, must be valid UTF-8, contain no NUL, and is at most
  1 MiB.
- Search query is at most 1,024 bytes.
- Cursor is opaque and at most 2,048 bytes.
- Page size is an integer from 1 through 50, with a server default of 20.

Production composition requires a dedicated 32-byte
`mutation_fingerprint_secret`; startup fails closed when it is absent or the
wrong size. The value is supplied only to the HMAC boundary, is named in the
runtime redactor's deny-list, and never enters adapter options, telemetry,
Logger metadata, audit, or backup.

The stored title is the trimmed title. The stored Markdown is otherwise the
exact submitted UTF-8 text; the server does not rewrite line endings, headings,
links, or raw HTML.

### 12.2 Preview boundary

Preview parses Markdown into a restricted syntax tree and constructs React
nodes. It never injects user HTML with `dangerouslySetInnerHTML`.

Supported presentation includes paragraphs, headings, emphasis, strong text,
lists, blockquotes, inline code, fenced code, thematic breaks, and safe links.

Raw HTML is displayed as inert text. Remote images and embeds do not load.
`javascript:`, `data:`, `file:`, and other non-approved schemes are inert.
Explicit `http`, `https`, and `mailto` links receive safe external-link
attributes. Preview behavior never changes canonical Markdown or export bytes.

## 13. Authorization, privacy, and observability

Every note operation requires:

1. A valid authenticated session.
2. An unlocked vault.
3. Exact principal and vault binding.
4. The required note capability.
5. Private classification clearance.
6. A scoped runtime database role subject to forced RLS.

Cross-vault IDs, unauthorized exact-version IDs, and tombstoned notes on normal
routes return `not_found` without exposing existence. A locked search returns
`vault_locked`, not an empty result.

Supported application logs, `[:singularity, ...]` telemetry, audit records,
outbox payloads, mutation receipts, and error details must not contain titles,
Markdown, search snippets, export bytes, or rendered HTML. Approved metadata is
limited to opaque IDs, counts, byte sizes, operation/result labels, correlation
references, and private classification.

Private plaintext is intentionally allowed only where the feature requires it:
authorized application DTO/bridge payloads, canonical NoteRepository writes and
reads, NoteSearchStore query/projection arguments, and NoteExport output. The raw
search query may itself contain private note text and receives the same
side-channel protections as Markdown. Secret-canary tests use this exact
allow-list rather than claiming canonical content adapters are plaintext-free.

The supported observability guarantee remains exactly the boundary in the
observability amendment. Raw Phoenix, LiveView, Bandit, Thousand Island, Ecto,
Oban, OTP, and dependency telemetry/logging remain unsupported and sensitive.
This slice does not subscribe Singularity reporters to those raw events and
does not claim they are plaintext-free.

The `/notes` and export responses use no-store behavior. Browser error messages
are stable and never echo submitted title or Markdown.

## 14. Errors and recovery

The existing stable errors are sufficient:

```text
unauthenticated
vault_locked
forbidden
not_found
conflict
invalid
storage_unavailable
```

Their Notes meanings are:

- `unauthenticated`: no valid session.
- `vault_locked`: authorization cannot proceed without unlock.
- `forbidden`: valid scoped identity lacks a required capability.
- `not_found`: absent, cross-vault, unauthorized exact version, or tombstoned
  normal read.
- `conflict`: stale merge or destructive command; no mutation committed.
- `invalid`: malformed/oversized input, invalid lineage, closed conflict,
  mismatched receipt identity/fingerprint, or invalid cursor.
- `storage_unavailable`: retryable repository failure after secret-safe mapping.

A stale Save that was preserved is an `{:ok, SaveResult{outcome: :conflict}}`,
not a stable error.

Any mutation failure rolls back resource version, note snapshot, head/title,
conflict, lexical projection, audit, outbox, and receipt together. The browser
keeps a local draft only while the vault is still unlocked.

The projection reconciler is idempotent. It reads canonical state on every
attempt, so retries repair PostgreSQL projection drift and future vector drift
without replaying an obsolete snapshot.

## 15. Logical backup and restore

Versioning is explicit at each existing layer:

- The outer `SINGULARITY-BACKUP` bundle format remains version 1.
- The authenticated manifest structure and manifest wire version remain version
  1 because inventory and recovery binding do not change.
- Logical cut/row/object record wire version 1 and `LogicalSchema` version 1 remain
  immutable, including every table ordinal, column ordinal, type, and nullable
  flag.
- This slice introduces logical cut/row/object record wire version 2 and
  `LogicalSchema` version 2.

`LogicalRecordCodec` dispatches cut and row decoding from the embedded logical
wire version. Version-one records use a frozen V1 schema definition; version-two
records use a separate V2 definition and table-count vector. The restorer selects
one schema from the authenticated cut before accepting any rows and rejects
mixed logical versions.

Within V2, every existing V1 table keeps its ordinal and every existing column
keeps its ordinal. New `content.resources` fields append after the V1 columns;
new Notes tables append after the complete V1 table list in dependency order.
The version-two object-record shape is unchanged even though its embedded
logical wire version is two.

The exporter writes logical version two after this migration. Version two
includes:

- Extended resources and generic resource versions.
- Note versions.
- Note conflicts and resolution references.
- Existing canonical identity, vault, asset, key, audit, and backup data.

It excludes:

- `note_search_documents`.
- `note_mutation_receipts`.
- Existing excluded sessions, upload grants, stages, jobs, and search
  projections.
- Future Qdrant vectors.

The restorer accepts both formats:

- Version-one resource rows restore as `asset` with no note head.
- Version-two rows restore complete note heads, lineage, tombstones, and
  conflicts.
- Deferred constraints validate mutually referencing heads and versions before
  commit.
- After import, the normal reconciliation phase rebuilds current lexical
  projections and excludes tombstoned notes.
- Restored session state is empty.

After either version imports, an idempotent capability reconciliation ensures
the catalog contains `note.read`, `note.write`, and `note.export`. It grants them
to each active restored vault principal that already holds
`vault.password_change`, the existing owner authority. It does not grant them to
ordinary members or system principals. Because sessions are excluded, the
restored owner must authenticate again and receives current authorization state.

Backward-compatibility acceptance uses a checked-in authenticated version-one
fixture produced by the pre-version-two code and pinned by a known hash. It must
not regenerate the purported V1 fixture with the new codec.

Backup acceptance verifies exact note IDs, titles, Markdown, revisions, parents,
head pointers, open/resolved conflicts, tombstones, and export bytes. It also
proves a restored V1 owner can create, read, and export a new private note.

## 16. Test strategy

Implementation follows test-first, scoped slices. Do not repair unrelated test
failures.

### 16.1 Core and domain

- Title, Markdown, classification, revision, and parent validation.
- Initial, normal, competing, and merge snapshot shapes.
- Open/resolved conflict invariants.
- Create, Save, merge, tombstone, and restore intents using fakes.
- Mutation replay, simultaneous duplicate claims, and mismatched operation,
  resource, or request-fingerprint rejection.

### 16.2 PostgreSQL and retrieval

- Migration constraints, immutable grants, forced RLS, and least-privilege
  role access.
- Two-vault, missing-context, non-member, and revoked-member RLS isolation for
  every Notes table and query.
- Database rejection of classification mismatches between resource, generic
  version, typed snapshot, conflict, and lexical projection.
- Concurrent Save tests that produce one canonical and one competing version.
- Save-versus-delete, merge-versus-delete, and restore-versus-delete races that
  enforce the live/tombstoned operation matrix.
- Monotonic revision allocation across canonical and competing versions.
- Fault injection proving transaction rollback across every written surface.
- Current-only FTS, deterministic rank/cursor behavior, and exact version IDs.
- Tombstone removal and restore rebuild.
- Idempotent projection reconciliation and stale-event convergence.

### 16.3 Runtime

- Authenticated, locked/unlocked, capability, clearance, and cross-vault
  matrices for every public operation.
- Conjunctive `required_capabilities` validation and authorization while every
  existing singular-capability flow remains unchanged.
- Stable error mapping and stale Save success semantics.
- Stale merge/delete no-mutation behavior.
- Exact export authorization and bytes.
- Same-vault principal capability differences at the runtime boundary.
- Secret-canary scans of final supported JSON logs, supported telemetry, audit,
  outbox, receipts, returned errors, and non-content adapter metadata.
- Allow-list tests proving title, Markdown, and raw search query occur only in
  the authorized UI/API payloads and canonical note persistence, lexical-query,
  and export arguments that require them.

### 16.4 Backup

- Version-two export/import round trip for live, conflicted, merged, deleted,
  and restored notes.
- Version-one asset backup compatibility using the checked-in pre-change bundle
  and known hash.
- Immutable V1 logical ordinals/columns and explicit V1/V2 codec dispatch.
- Post-import owner capability reconciliation for both versions.
- Projection and session exclusion.
- Projection rebuild from restored canonical heads.

### 16.5 Web and frontend

- Route and authentication contract.
- Exact initial-props and reply decoders.
- Exact Search, Trash, History, Save-result, conflict-detail, and export DTO
  shapes.
- Explicit Save and dirty-navigation confirmation.
- Stale async reply rejection.
- Conflict and merge mode.
- Trash and restore.
- Safe Markdown AST rendering and unsafe-input fixtures.
- Exact export headers and body.
- Vault-lock state purge.
- Keyboard, focus, accessible names/status, mobile layout, reduced motion, and
  theme behavior.

### 16.6 Architecture and exclusion guards

- Web retains a compile-time dependency only on Runtime and calls only
  `Runtime.Api`.
- Core and Domains remain free of Ecto, Phoenix, React, PostgreSQL, and Qdrant.
- A scoped Qdrant exclusion check rejects dependencies and lock entries,
  application code, runtime configuration, collection definitions, workers,
  adapters, and supervision children. It allows only established future-scope
  documentation references.
- Supported reporters remain barred from dependency-owned telemetry.

### 16.7 Browser acceptance

The scoped browser proof performs:

1. Create a private note at revision zero, displayed as Version 1.
2. Save a normal edit and observe the canonical head/search advance.
3. Save concurrently from the old head and observe both snapshots plus an open
   conflict while search remains on the accepted head.
4. Merge and observe a new two-parent canonical version.
5. Export and compare the response body byte-for-byte with canonical Markdown.
6. Tombstone and prove normal reads and search stop exposing the note.
7. Restore and prove the same canonical version is projected again.
8. Back up and restore the vault and prove history, conflict resolution, IDs,
   and export bytes survive.
9. Prove another vault and a locked session cannot observe the target vault's
   note IDs, counts, titles, versions, or content.

## 17. Completion criteria

The slice is complete only when:

- Every listed scoped test passes.
- Existing affected architecture guards pass.
- Create, Save, conflict, merge, search, export, delete, restore, and backup
  browser acceptance passes.
- Search results always identify the exact canonical resource version.
- Concurrent editing produces deterministic immutable history without data
  loss.
- Deletion invalidates PostgreSQL projection synchronously.
- Export is exact portable Markdown.
- Version-one asset backups and version-two note backups both restore.
- No supported application observability or non-content persistence surface
  carries note title, Markdown, or a raw private search query.
- Qdrant remains explicitly deferred and no dependency or active configuration
  is introduced.
- The implementation plan stays within this design and stops when this
  checklist is satisfied.
