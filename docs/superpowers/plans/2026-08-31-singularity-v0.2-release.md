# Singularity v0.2.0 — First Complete Knowledge Base Release

> **Audience:** OpenAI Codex and reviewing engineers<br>
> **Repository:** `gsmlg-opt/Singularity`<br>
> **Plan date:** 2026-08-31<br>
> **Reviewed baseline:** `main` at `c49dc0aeda1d0115b20ff291f0da658f7e558b43`<br>
> **Phase 0 starting baseline:** local `main` and the locally recorded `origin/main` at `5151febde7d94c92877f7a49525e0e2add5b2faf`; the delta from the reviewed baseline is documentation-only, while live remote state remains unverified after network timeouts<br>
> **Current package version:** `0.1.0`<br>
> **Target:** `0.2.0`, the first complete knowledge-base release<br>
> **Execution model:** Test-first, one reviewable vertical slice per branch or pull request

---

## 1. Executive directive

Continue the existing Singularity implementation and complete the previously approved **Notes and Documents** milestone.

The current `0.1.0` release is the foundation/bootstrap release. The next release must turn that foundation into a usable personal knowledge base by completing:

- document import;
- text extraction;
- immutable document versions;
- attachments;
- tags;
- typed relationships and backlinks;
- unified PostgreSQL lexical search;
- version-pinned citations;
- portable export;
- complete backup and restore support;
- a coherent Notes/Documents/Search user workflow;
- release-quality automated verification.

Do not start semantic retrieval, Qdrant indexing, RAG, Agent tools, photo management, media management, finance, health, email, contacts, calendars, or external connectors.

---

## 2. Non-negotiable product correction: Vault is frozen

Singularity is currently being developed as a **single-user, local-first personal knowledge base**. Vault is not an active product module for this milestone.

### 2.1 Required handling

Treat the existing Vault implementation as **frozen compatibility substrate**:

- Do not add Vault features.
- Do not redesign Vault.
- Do not remove Vault.
- Do not make Vault optional in this milestone.
- Do not modify Vault unlock, locking, key rotation, password, recovery, capability, or administration UX.
- Do not add Vault-specific tests, migrations, policies, commands, telemetry, documentation, or acceptance criteria.
- Do not refactor existing code merely to rename or abstract Vault.
- Do not investigate or repair unrelated Vault issues.
- Do not describe Vault as a deliverable of `0.2.0`.

Existing `vault_id` fields and storage-scope plumbing may remain where the current schema and adapters require them. Treat those values as opaque compatibility scope:

- pass them through unchanged only where existing infrastructure requires it;
- derive them from the existing authenticated runtime context;
- do not expose a caller-supplied `vault_id` in new knowledge-base APIs;
- do not introduce new knowledge-domain rules that depend on Vault behavior;
- isolate unavoidable compatibility handling inside runtime/storage adapters;
- do not alter existing Vault tables, cryptographic formats, or semantics.

A Vault-related file may be touched only when a new knowledge-base change would otherwise fail to compile or preserve established behavior. Any such change must be the smallest compatibility patch possible and must be explicitly listed in the implementation report.

### 2.2 Project guardrails to add first

Create a root `AGENTS.md` that records this scope lock for all future agents.

Add `docs/adr/0003-vault-frozen-for-knowledge-base-development.md` with these decisions:

1. Vault is no longer part of the active knowledge-base roadmap.
2. Existing implementation remains untouched for compatibility.
3. New knowledge-domain APIs use authenticated owner/session context and never introduce new Vault-facing product behavior.
4. Removal or replacement of legacy Vault infrastructure requires a separate, explicitly approved migration project.
5. Historical specifications remain historical records; the new ADR governs active development.

Update the active sections of `README.md` and `docs/guide.md` so that they no longer direct agents to develop Vault. Do not rewrite old implementation-history documents merely to erase their historical context. Mark any conflicting active guidance as superseded by ADR 0003.

Replace the active architectural invariant:

> Every user-owned object belongs to a vault.

with:

> Every user-owned object belongs to an authenticated owner scope, and every projection points to an immutable source version.

Document that current persistence may still encode the owner scope using legacy columns until a separately approved migration is performed.

---

## 3. Existing implementation to preserve

Do not rewrite completed behavior.

The following are established foundations:

- seven-application Elixir umbrella;
- PostgreSQL as the canonical structured store;
- encrypted object/asset storage;
- Assets upload, verification, download, deletion, and backup behavior;
- Markdown Notes create/open/list/save/history/conflict/merge/delete/restore/export;
- immutable note versions;
- current-version Notes lexical search;
- Outbox and Oban background execution;
- Runtime API as the only application-facing boundary;
- Phoenix LiveView hosting React App Clips;
- unit, PostgreSQL integration, restore, JavaScript, and Playwright test layers;
- Docker and multi-architecture release tooling.

Characterize existing behavior before modifying it. Prefer additive changes over replacement.

---

## 4. Release outcome

The release is complete only when this end-to-end scenario works:

1. A user uploads a text-bearing PDF, Markdown file, or UTF-8 plain-text file.
2. The existing Asset pipeline stores the original bytes.
3. The user imports the Asset as a Document.
4. Singularity creates an immutable Document resource version.
5. A background job extracts canonical text with source provenance.
6. Deterministic fragments are persisted and projected into PostgreSQL lexical search.
7. Unified search returns Notes and Documents.
8. Every result identifies its exact `resource_id`, `resource_version_id`, and source locator.
9. The user opens the exact document source location from a search result.
10. The user attaches the source to a Note and inserts a version-pinned citation.
11. The Note shows tags, outgoing relationships, incoming backlinks, attachments, and citations.
12. Deleting the Document removes it from live search without destroying immutable history or existing citation records.
13. Restoring the Document deterministically rebuilds its search projection.
14. A portable export contains Markdown, original documents, and non-proprietary metadata.
15. A backup created after this workflow restores into a clean database and reproduces the same Notes, Documents, versions, tags, relationships, attachments, citations, and live search results.
16. The complete automated verification sequence passes on the exact release source revision.
17. No new Vault functionality is introduced.

---

## 5. Scope

### 5.1 Required for `0.2.0`

- Existing Markdown Notes behavior remains stable.
- Document resources and immutable Document versions.
- Import from existing Assets.
- Required import formats:
  - text-bearing PDF;
  - UTF-8 Markdown;
  - UTF-8 plain text.
- Asynchronous, idempotent text extraction.
- Provenance-preserving document fragments.
- Attachments pinned to immutable source versions.
- Tags.
- Typed resource relationships.
- Backlinks.
- PostgreSQL lexical search across current live Notes and Documents.
- Search filters for resource kind and tags.
- CJK/short-query fallback using PostgreSQL facilities rather than Qdrant.
- Exact source locators.
- Structured citations tied to immutable Note and source versions.
- Tombstone, restore, projection invalidation, and projection rebuild.
- Portable knowledge export.
- Logical backup format extension with backward-compatible restore.
- Documents UI, unified Search UI, and Notes knowledge panels.
- Full test and release gates.
- Upgrade verification from `0.1.0`.

### 5.2 Explicitly out of scope

- Any Vault feature, redesign, cleanup, removal, or migration.
- Qdrant.
- Embeddings.
- Vector search.
- Hybrid lexical/vector search.
- Reranking.
- RAG.
- LLM or Agent execution.
- OCR.
- Scanned-image PDF recognition.
- Office document formats.
- Rich-text/WYSIWYG editing.
- Autosave.
- CRDTs.
- Real-time collaboration.
- Multi-device synchronization.
- Public sharing.
- Photos, albums, video, movies, music, or Jellyfin behavior.
- Email, contacts, calendars, finance, health, or subscriptions.
- External source connectors.
- General ESS or S3 redesign.
- Activity and Settings product expansion.
- PDF.js or a full embedded PDF renderer.

---

## 6. Architectural invariants

### 6.1 Canonical data and projections

- PostgreSQL is canonical for structured knowledge data.
- Original file bytes remain in the existing Asset/object-storage path.
- Notes, Documents, versions, extracted fragments, citations, tags, and relationships are canonical records.
- Search rows are rebuildable projections.
- No search result may exist without an immutable source version.
- Qdrant must not be required by any `0.2.0` path.

### 6.2 Functional boundaries

- `singularity_core` owns validated immutable values and behaviours.
- `singularity_domains` owns pure state-transition and intent construction.
- `singularity_ingest` owns extraction normalization and deterministic fragmentation logic.
- `singularity_retrieval` owns search query validation, ranking, filtering, pagination, and result values.
- `singularity_storage` owns Ecto schemas, migrations, PostgreSQL queries, projection persistence, and backup/restore adapters.
- `singularity_runtime` owns authenticated use-case orchestration and adapter composition.
- `singularity_web` calls only `Singularity.Runtime.Api`.
- Domain code must not contain Ecto, Phoenix, filesystem, shell-command, PostgreSQL, or React concerns.
- Web code must not call storage or retrieval adapters directly.

### 6.3 Immutability

- A Document version is immutable after completion.
- Canonical extracted fragments are immutable children of one Document version.
- A Note version's attachments and citations are immutable members of that Note version.
- Editing a Note creates a new version; it must never mutate the previous version's attachment or citation set.
- Mutable organization metadata such as current tags and resource-level relationships must be audited and backed up.

### 6.4 Idempotency and asynchronous work

- Import requests have stable idempotency keys.
- Retrying an import cannot create duplicate Document versions for the same accepted request.
- External extraction must not occur inside a long PostgreSQL transaction.
- Outbox payloads carry identifiers and bounded metadata, never full document or note text.
- Background jobs are safe to retry after process, node, or database interruption.
- Projection rebuilds are deterministic and idempotent.

### 6.5 Privacy and observability

Never place any of these in logs, telemetry metadata, exception text, outbox payloads, job arguments, or audit metadata:

- Note titles or Markdown;
- extracted document text;
- filenames when they may contain private data;
- citation excerpts;
- tag display values;
- relationship labels;
- original file bytes.

Record stable IDs, operation names, MIME classes, byte counts, result states, durations, and sanitized error codes instead.

---

## 7. Canonical knowledge model

Use the repository's existing `content.resources` and `content.resource_versions` model. Do not create a second competing identity/version system.

Exact table and module names may be adjusted to match established repository conventions, but the following invariants are mandatory.

### 7.1 Resource kinds

Extend the current resource kind constraint to include:

- `asset`
- `note`
- `document`

Do not repurpose an Asset row as the Document itself. The Asset is the immutable original binary; the Document is the knowledge representation derived from it.

### 7.2 Document versions

Add a typed Document-version record linked one-to-one to a generic resource version.

Required concepts:

- document resource ID;
- resource version ID;
- source Asset ID and accepted source Asset version/reference;
- original media type;
- source content digest;
- title projection;
- import state;
- extraction adapter name;
- extraction format version;
- extracted-text digest;
- detected language when available;
- creation actor and timestamps;
- sanitized failure code when extraction fails.

Recommended states:

- `pending`
- `extracting`
- `ready`
- `unsupported`
- `failed`

A failed extraction must not delete or corrupt the original Asset.

### 7.3 Document fragments

Persist immutable, ordered fragments for each ready Document version.

A fragment must contain:

- stable fragment ID;
- resource ID;
- resource version ID;
- ordinal;
- canonical UTF-8 text;
- text digest;
- source locator;
- optional normalized heading path;
- optional page number;
- optional line range;
- optional character offsets.

Fragment identity must be deterministic from the Document version, locator, ordinal, and normalized-content digest. Replaying the same extraction format against the same accepted source must produce the same fragment sequence.

Do not call search-projection rows canonical fragments. Canonical fragments survive projection deletion and are sufficient to rebuild search.

### 7.4 Source locators

Define a validated pure `SourceLocator` value supporting:

- PDF page and optional character range;
- Markdown heading path and optional line range;
- plain-text line range;
- generic fragment ordinal fallback.

Reject contradictory or negative locators. Serialization must be deterministic and versioned.

### 7.5 Note-version attachments

Attach knowledge sources to an immutable Note version, not merely to a mutable UI state.

Each attachment reference must pin:

- Note resource version;
- attached resource;
- attached resource version;
- attachment role;
- stable ordering;
- optional safe display label.

Saving a Note with changed attachments creates a new Note version.

### 7.6 Note-version citations

A citation must pin both sides:

- the exact Note resource version containing the citation;
- the exact source resource version;
- the exact source fragment;
- a validated source locator;
- a stable citation identifier;
- deterministic display order.

A citation must never silently move to a newer Document version.

Existing citations remain historical records when a source is tombstoned. Live resolution should report the source as deleted rather than silently discarding or retargeting the citation. Restore makes the source live again.

Portable export must render citations as standard Markdown footnotes or links plus human-readable source metadata. Do not require proprietary URI schemes to understand an export.

### 7.7 Tags

Add normalized Tags and resource assignments.

Required behavior:

- Unicode normalization;
- case-insensitive uniqueness within the authenticated owner scope;
- preserved display value;
- attach/detach operations are idempotent;
- deleted resources do not appear in live tag browsing;
- assignments survive tombstone for deterministic restore;
- tag mutation is audited without logging the tag value.

Tags are current organizational metadata and do not need to create a new resource version.

### 7.8 Typed relationships and backlinks

Add directed, typed relationships between resources.

Initial allowed relationship types:

- `related_to`
- `references`
- `derived_from`

Do not build a general ontology or inferred knowledge graph.

Required behavior:

- no self-relations;
- uniqueness for the same source, target, and type;
- optional pinned target version;
- outgoing and incoming queries;
- incoming relations are displayed as backlinks;
- tombstoned resources are hidden from live graph queries but relationships remain recoverable;
- relationship mutation is audited.

### 7.9 Unified lexical search projection

Create one logical search surface for live current Notes and Documents.

Every search entry and result must include:

- resource kind;
- resource ID;
- exact resource version ID;
- optional fragment ID;
- title;
- bounded snippet;
- source locator;
- rank;
- live/deleted state enforcement.

Use PostgreSQL only for this release.

Recommended query strategy:

- `simple` full-text configuration for normalized lexical matching;
- GIN indexes for `tsvector`;
- `pg_trgm` fallback for CJK text, short queries, and title matching;
- deterministic rank fusion between full-text and trigram matches;
- stable cursor ordering with a deterministic ID tie-breaker.

Do not return historical Note or Document versions in normal search. Historical versions remain directly retrievable through version/history use cases.

---

## 8. Document ingestion design

### 8.1 Public workflow

The Runtime boundary should expose use cases equivalent to:

- import an existing Asset as a Document;
- get a Document;
- list Documents;
- retry a failed/unsupported extraction when appropriate;
- delete a Document;
- restore a Document;
- inspect import status.

Follow existing Runtime API naming and DTO conventions. New application-facing calls accept authenticated session/context plus resource IDs and validated attributes. They must not accept a new public Vault selector.

### 8.2 Transaction boundaries

Use this sequence:

```text
validate authenticated request
→ validate source Asset and supported MIME
→ idempotently create pending Document version
→ write outbox event with IDs only
→ commit
→ background worker reads source bytes
→ extractor produces normalized fragments outside DB transaction
→ short transaction stores immutable fragments and marks version ready
→ emit projection event
→ projection worker upserts search rows
```

On failure:

```text
classify sanitized failure
→ mark import failed or unsupported idempotently
→ retain original Asset
→ retain retry metadata
→ do not emit partial live search projection
```

### 8.3 Extractor port

Define an extractor behaviour with typed input and output. The domain and runtime must depend on the behaviour, not Poppler or filesystem details.

Required adapters:

#### Markdown

- validate UTF-8;
- normalize line endings;
- retain heading hierarchy;
- produce deterministic section/paragraph fragments;
- preserve line ranges.

#### Plain text

- validate UTF-8;
- normalize line endings;
- produce deterministic bounded fragments;
- preserve line ranges.

#### PDF

Use a local Poppler-based adapter for the first release:

- add Poppler tools to `devenv.nix`;
- add the required runtime package to the pinned Docker snapshot;
- invoke executables directly, never through a shell;
- use a private temporary directory and restrictive file modes;
- enforce configurable input-size, page-count, output-size, and execution-time limits;
- guarantee cleanup on success, failure, timeout, and task exit;
- classify password-protected/encrypted, malformed, unsupported, and no-extractable-text documents;
- preserve page boundaries;
- never execute embedded scripts or access the network.

OCR remains explicitly deferred. A scanned PDF with no extractable text should produce a stable `no_extractable_text`/unsupported outcome, not fake empty success.

### 8.4 Fragmentation

Fragmentation must be a pure function.

Properties to test:

- same input and format version produce identical fragments;
- concatenating fragment text in source order preserves the normalized extracted content;
- fragments never exceed configured bounds except an explicitly documented indivisible source block;
- locators are monotonic and non-overlapping where the source format permits it;
- fragment IDs are stable;
- empty fragments are eliminated;
- malformed UTF-8 is rejected before persistence.

Version the fragmentation format. Changing it later must create a deliberate re-extraction/reprojection path rather than silently changing existing citation targets.

---

## 9. Runtime and domain use cases

Implement thin public use-case modules following the existing one-module-per-operation pattern.

Required groups:

### Documents

- Import
- Get
- List
- RetryExtraction
- Delete
- Restore
- Source/Fragments

### Knowledge search

- Search
- RebuildProjection for one resource/version
- ResolveResultSource

### Tags

- CreateOrResolve
- Attach
- Detach
- ListForResource
- BrowseResourcesByTag

### Relationships

- Relate
- Unrelate
- ListOutgoing
- ListBacklinks

### Note knowledge metadata

- Save Note with attachment and citation sets
- Resolve attachment
- Resolve citation
- List attachments/citations for a Note version

Use typed request and result values. Do not pass loosely shaped maps across application boundaries when a stable value type is warranted.

Extend `Singularity.Runtime.Api` without moving domain decisions into that facade.

---

## 10. Portable export and logical backup

### 10.1 Portable knowledge export

Add an export that remains understandable without Singularity.

The export must include:

```text
notes/
  <safe-name>.md

documents/
  originals/
    <safe-name>.<ext>
  extracted/
    <safe-name>.txt

manifest.json
```

`manifest.json` must use a documented, versioned, non-secret format containing:

- resources and immutable versions;
- original-document references and digests;
- fragment/source locator metadata;
- tags;
- relationships;
- attachment references;
- citation references;
- tombstone state where explicitly requested.

Markdown files must remain ordinary UTF-8 Markdown. Citations should be rendered as standard footnotes/links with readable source information. Original document bytes must remain byte-identical.

Avoid loading the complete export into BEAM memory. Stream file/object content where practical.

### 10.2 Backup format

Extend the existing logical backup format to version 3.

Version 3 must include:

- Document resources and versions;
- canonical document fragments;
- import state and extractor format;
- tags and assignments;
- relationships;
- Note-version attachments;
- Note-version citations;
- all data needed to rebuild the unified search projection.

Restore requirements:

- continue accepting existing version 1 and version 2 backups;
- write version 3 for new backups;
- validate referential closure before mutation;
- restore canonical records before projections;
- rebuild projections rather than trusting serialized search rows;
- restore into a clean database and into the supported replacement workflow;
- reject malformed, duplicate, dangling, or cross-owner references atomically;
- preserve immutable IDs and digests;
- never partially expose a restored knowledge graph.

Do not redesign backup cryptography or Vault-key behavior in this milestone. Extend only the logical knowledge payload and restore ordering.

---

## 11. Web experience

Reuse the existing Phoenix LiveView + React App Clip architecture.

### 11.1 Documents workspace

Provide:

- upload/import entry using the existing Asset pipeline;
- document list;
- import/extraction state;
- retry action for eligible failures;
- extracted-text source view grouped by page/section;
- original file download;
- delete and restore;
- tags and relationships;
- backlinks;
- action to attach or cite the source in a Note.

Do not add an embedded full PDF renderer. Source resolution may open the extracted page section and offer original-file download.

### 11.2 Unified search

Provide:

- one query field;
- Note/Document/all filter;
- tag filter;
- result kind;
- bounded highlighted snippet;
- exact source locator;
- open-source action;
- attach-to-note action;
- cite-in-note action;
- pagination without unbounded result loading.

### 11.3 Notes workspace extension

Preserve the current Markdown editor, explicit Save, history, conflicts, merge, and preview.

Add compact panels for:

- tags;
- attachments;
- citations;
- outgoing relationships;
- backlinks.

A changed attachment or citation set participates in the explicit Save operation and creates a new immutable Note version.

Do not add autosave, WYSIWYG, collaboration, or a new client-side state architecture.

### 11.4 Accessibility and failure states

Cover:

- keyboard navigation;
- labels and focus order;
- loading;
- pending extraction;
- unsupported format;
- failed extraction;
- empty search;
- deleted citation source;
- stale Note Save conflict;
- restore in progress;
- network/retry errors.

Retain axe/Playwright acceptance coverage.

---

## 12. Implementation phases

Do not implement the entire release in one branch. Complete, review, and verify each phase before starting the next.

## Phase 0 — Scope lock and green baseline

### Deliverables

- [ ] Record the starting commit SHA and confirm whether `main` has advanced.
- [ ] Create root `AGENTS.md` with the Vault freeze and active `0.2.0` scope.
- [ ] Add ADR 0003.
- [ ] Add an approved `0.2.0` design specification.
- [ ] Add this implementation plan under `docs/superpowers/plans/`.
- [ ] Update active `README.md` and `docs/guide.md` roadmap/invariants.
- [ ] Do not rewrite historical specifications.
- [ ] Run the complete repository verification sequence.
- [ ] Repair baseline failures that block knowledge-base development, without initiating Vault work.
- [ ] Add or update workflow contract tests if the documented verification sequence differs from CI.

### Acceptance

- Working tree is clean.
- Existing behavior is characterized.
- All currently supported checks pass.
- Future agents cannot reasonably interpret Vault as active scope.
- No production Vault behavior changed.

Suggested commit:

```text
docs(scope): freeze vault work and approve knowledge v0.2
```

---

## Phase 1 — Canonical Document and knowledge-link model

### Deliverables

- [ ] Add pure core values and behaviours for Document versions, fragments, locators, attachments, citations, tags, and relationships.
- [ ] Extend resource kind support with `document`.
- [ ] Add new forward-only migrations; never edit released migrations.
- [ ] Add Ecto schemas and repository behaviours/adapters.
- [ ] Apply the existing storage-scope isolation pattern mechanically without changing its semantics.
- [ ] Add immutable constraints and cross-resource/version foreign keys.
- [ ] Add mutation idempotency receipts where current conventions require them.
- [ ] Add unit, migration, PostgreSQL integration, and isolation tests.
- [ ] Add backup-format placeholders only if needed to keep compilation coherent; full backup behavior belongs to Phase 5.

### Acceptance

- A pending Document version can be created idempotently from an existing Asset.
- Invalid cross-resource or cross-version references are rejected by both pure validation and PostgreSQL constraints.
- Document versions and fragments cannot be updated through runtime grants.
- Note-version attachments and citations cannot point to the wrong Note or source version.
- Existing Notes and Assets tests remain green.
- No Vault tables or behavior changed.

Suggested commit:

```text
feat(knowledge): add canonical document and source-link model
```

---

## Phase 2 — Import, extraction, and source viewing vertical slice

### Deliverables

- [ ] Add typed Runtime/Domain import use cases.
- [ ] Add outbox event and Oban handler using IDs only.
- [ ] Add Markdown and plain-text extractors.
- [ ] Add bounded Poppler PDF extractor.
- [ ] Update Nix and Docker runtime dependencies.
- [ ] Add deterministic pure fragmentation.
- [ ] Persist canonical fragments.
- [ ] Add import status, retry, failure classification, delete, and restore behavior.
- [ ] Add a minimal source/fragments read use case.
- [ ] Add fixtures for multipage PDF, Markdown headings, plain text, encrypted PDF, malformed PDF, empty/scanned PDF, oversized input, and duplicate import.
- [ ] Add interruption/retry and idempotency tests.

### Acceptance

- Importing each supported format reaches `ready` with deterministic fragments.
- Repeating the same accepted import request returns the established result.
- Worker retry does not duplicate versions or fragments.
- Failed extraction preserves the original Asset.
- Extracted content never appears in logs, telemetry, audit metadata, outbox payloads, or job arguments.
- Docker and devenv both contain the same required extractor capability.
- No partial live search rows are created on extraction failure.

Suggested commit:

```text
feat(ingest): import and extract versioned documents
```

---

## Phase 3 — Unified lexical retrieval and source provenance

### Deliverables

- [ ] Add the unified search-entry projection.
- [ ] Add projection handlers for Note current heads and ready Document fragments.
- [ ] Add PostgreSQL FTS and trigram indexes.
- [ ] Update database bootstrap/extension manifests for `pg_trgm` if required.
- [ ] Add typed unified Search query/page/result values.
- [ ] Add kind and tag filters.
- [ ] Add exact source-resolution use case.
- [ ] Invalidate projections on tombstone.
- [ ] Rebuild projections on restore.
- [ ] Add deterministic rebuild command for one resource and for full maintenance.
- [ ] Add query-plan and pagination tests.
- [ ] Preserve existing Notes-search API behavior or provide a compatibility wrapper while the UI migrates.

### Acceptance

- One query returns Notes and Documents.
- Every result is pinned to an exact immutable source version.
- Document results carry fragment and locator provenance.
- CJK and short queries have a tested PostgreSQL fallback.
- Tombstoned resources disappear from live search.
- Restore recreates byte/logically equivalent projection rows from canonical data.
- Deleting all projection rows and rebuilding produces the same visible results.
- No Qdrant service, configuration, dependency, collection, worker, or test is introduced.

Suggested commit:

```text
feat(retrieval): unify version-pinned lexical search
```

---

## Phase 4 — Attachments, citations, tags, relationships, and backlinks

### Deliverables

- [ ] Extend Note snapshots/save commands with immutable attachment and citation sets.
- [ ] Keep old call sites compatible through explicit defaults.
- [ ] Include attachments and citations in mutation fingerprints.
- [ ] Persist the sets atomically with the new Note version.
- [ ] Add tag attach/detach/browse use cases.
- [ ] Add typed relate/unrelate/outgoing/backlink use cases.
- [ ] Add citation resolution and deleted-source behavior.
- [ ] Add standard Markdown citation rendering for export.
- [ ] Add tests for stale saves, merge behavior, citation pinning, attachment pinning, duplicate tags, duplicate relationships, backlinks, tombstoned sources, and restored sources.
- [ ] Ensure conflicts preserve the submitted attachment/citation set just as they preserve submitted Markdown.

### Acceptance

- Saving changed knowledge metadata creates a new Note version.
- Old Note versions retain their original attachment/citation sets.
- A citation never follows a newer source version automatically.
- Backlinks are deterministic and exclude tombstoned resources from live results.
- Existing Note conflict and merge semantics remain correct.
- Tag and relationship mutations are idempotent and audited without private values.

Suggested commit:

```text
feat(notes): add versioned sources and knowledge links
```

---

## Phase 5 — Portable export, backup v3, restore, and upgrade

### Deliverables

- [ ] Add portable knowledge export.
- [ ] Extend logical backup writer to version 3.
- [ ] Extend restore validation and import ordering.
- [ ] Retain version 1 and version 2 restore compatibility.
- [ ] Rebuild search projections after restore.
- [ ] Add full backup/restore fixtures containing Notes, Documents, fragments, tags, relationships, attachments, citations, tombstones, and conflicts.
- [ ] Add `0.1.0` database-to-`0.2.0` migration acceptance.
- [ ] Verify original document bytes and all canonical digests after restore.
- [ ] Add rollback/failure tests proving atomic rejection of malformed backups.
- [ ] Do not modify backup cryptography or Vault-key lifecycle.

### Acceptance

- A clean restore reproduces canonical data and visible search results.
- Existing v1/v2 backups still restore.
- Portable export is understandable without Singularity.
- Original binary documents are byte-identical.
- Markdown is ordinary UTF-8 Markdown.
- Citations and relationships remain human-readable.
- No proprietary database or application state is required to understand exported Notes and sources.

Suggested commit:

```text
feat(export): preserve complete knowledge provenance
```

---

## Phase 6 — Complete the Web knowledge workflow

### Deliverables

- [ ] Add Documents workspace.
- [ ] Add unified Search workspace.
- [ ] Extend Notes workspace with knowledge panels.
- [ ] Connect UI only through `Singularity.Runtime.Api`.
- [ ] Add source-location navigation.
- [ ] Add attach/cite actions.
- [ ] Add all required empty, loading, pending, failed, deleted, and restore states.
- [ ] Add focused React/Vitest tests.
- [ ] Add LiveView/controller boundary tests.
- [ ] Add Playwright end-to-end scenario covering the complete release outcome.
- [ ] Add axe accessibility assertions.
- [ ] Keep Activity and Settings outside the scope.

### Acceptance

A browser test proves:

```text
upload PDF
→ import Document
→ wait for extraction
→ search extracted text
→ open exact source page
→ create/open Note
→ attach source
→ insert citation
→ tag and relate resources
→ save Note
→ view backlink
→ delete Document
→ verify search invalidation and deleted citation state
→ restore Document
→ verify source/search recovery
→ export
→ create backup
```

Existing Assets and Notes browser flows remain green.

Suggested commit:

```text
feat(web): complete the first knowledge-base workflow
```

---

## Phase 7 — Release hardening and `0.2.0`

### Deliverables

- [ ] Run the complete verification sequence from a clean checkout.
- [ ] Make the full Tests workflow a release prerequisite for the exact source revision.
- [ ] Prevent Release from publishing a revision that has not passed all required checks.
- [ ] Prefer a reviewed version-bump commit before release; do not let the release job silently create untested product code.
- [ ] Add workflow contract tests for exact-SHA test gating.
- [ ] Configure or document required branch protection for `main`.
- [ ] Verify clean `0.1.0` upgrade and fresh installation.
- [ ] Build and inspect amd64 and arm64 images.
- [ ] Verify Poppler availability in both runtime images.
- [ ] Verify OCI/SBOM/provenance behavior remains intact.
- [ ] Update release notes and operator documentation.
- [ ] Bump all canonical umbrella application versions consistently to `0.2.0`.
- [ ] Tag and publish only after all gates pass.

### Acceptance

- The exact release source SHA passed all backend, database, restore, frontend, browser, architecture, and container checks.
- Fresh install succeeds.
- Upgrade from `0.1.0` succeeds without data loss.
- Backup from the upgraded installation restores cleanly.
- Both target architectures import and extract a PDF.
- Release artifacts match the tagged source revision.
- `0.2.0` release notes describe knowledge-base features and do not present Vault as a release feature.
- No new Vault functionality exists in the diff.

Suggested commits:

```text
ci(release): require full tests for published revisions
chore(release): prepare singularity v0.2.0
```

---

## 13. Verification gates

Use the repository's complete verification sequence, not only focused tests.

```bash
(
set -euo pipefail
trap 'devenv processes down' EXIT

devenv up -d
devenv processes wait --timeout 120

devenv shell -- bash \
  apps/singularity_storage/priv/repo/bootstrap_roles.sh

devenv shell -- mix deps.get
devenv shell -- mix deps.unlock --check-unused
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test
devenv shell -- mix singularity.test.integration
devenv shell -- mix singularity.test.restore

devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
devenv shell -- mix npm.verify
devenv shell -- mix duskmoon_bundler.js.check
devenv shell -- mix npm.run test:js
devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind
devenv shell -- mix npm.run test:e2e

devenv shell -- mix xref graph --format cycles --fail-above 0
nix run nixpkgs#actionlint -- \
  .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/release.yml

git diff --check
git status --short
)
```

Add focused test commands during each phase, but never substitute them for the final complete gate.

---

## 14. Required test matrix

### Pure/domain

- value validation;
- deterministic IDs;
- locator validation;
- fragment determinism;
- version immutability;
- mutation fingerprint stability;
- idempotent commands;
- invalid cross-resource references;
- stale Note saves and conflicts;
- merge parent correctness;
- tag normalization;
- relationship validation.

### PostgreSQL integration

- forward migration from `0.1.0`;
- constraints;
- current owner-scope isolation;
- immutable grants;
- import idempotency;
- fragment persistence;
- projection upsert;
- projection invalidation/rebuild;
- deletion/restore;
- tag and backlink queries;
- citation resolution;
- transaction rollback;
- outbox retry.

### Extraction

- Markdown;
- UTF-8 text;
- multipage PDF;
- malformed PDF;
- password-protected PDF;
- scanned/no-text PDF;
- oversized source;
- timeout;
- process crash;
- duplicate import;
- temporary-file cleanup;
- Docker runtime executable availability.

### Retrieval

- Notes and Documents in one query;
- exact version IDs;
- locator correctness;
- CJK;
- short query;
- tag/kind filters;
- stable pagination;
- deterministic tie-breaking;
- tombstone exclusion;
- rebuild equivalence.

### Backup/export

- v1 restore;
- v2 restore;
- v3 round trip;
- malformed v3 rejection;
- dangling reference rejection;
- original-byte equality;
- projection rebuild;
- portable Markdown and citations;
- full upgraded-installation restore.

### Web/browser

- complete vertical scenario;
- errors and retries;
- stale edit conflict;
- deleted citation source;
- keyboard navigation;
- axe checks;
- existing Assets and Notes regression.

---

## 15. Codex execution protocol

1. Read this plan, root `AGENTS.md`, ADR 0003, `README.md`, `docs/guide.md`, the existing Milestone 2 Notes specification, current Notes/Assets contexts, current Runtime API, storage migrations, search adapters, and test workflows.
2. Do not begin by reviewing Vault files.
3. Verify the actual starting SHA. If `main` moved, inspect the delta and update the plan's baseline note without weakening scope.
4. Create an isolated worktree and branch for each phase.
5. Add characterization tests before changing established Notes, Assets, backup, or release behavior.
6. For each behavior:
   - write the focused failing test;
   - prove the expected failure;
   - implement the smallest coherent change;
   - run the focused test;
   - run the phase gate;
   - request independent review;
   - address Critical and Important findings;
   - commit a single reviewable concept.
7. Never edit released migrations. Add new forward migrations.
8. Never bypass a failing test, weaken an assertion, delete an acceptance case, or mark a failure flaky without evidence and review.
9. Do not perform broad cleanup while implementing a feature.
10. Preserve the umbrella dependency graph and require zero xref cycles.
11. Keep external extraction outside database transactions.
12. Keep user content out of observability surfaces.
13. Do not bump the release version until implementation and upgrade verification are complete.
14. Do not publish a release from a dirty, unreviewed, or untested source revision.
15. At the end of each phase, report:
    - commits;
    - files changed;
    - migrations added;
    - tests added;
    - exact commands run;
    - results;
    - remaining risks;
    - confirmation that no Vault feature work was performed.

---

## 16. Stop conditions

Stop the affected phase and report evidence when:

- the required behavior would require changing Vault semantics;
- an existing schema constraint makes an additive implementation impossible without a separately approved migration;
- source data cannot be linked to an immutable version;
- an extractor cannot be bounded or sandboxed sufficiently;
- a proposed search path cannot preserve exact source provenance;
- backup compatibility would be broken;
- a release workflow cannot prove the exact source SHA passed all tests.

Continue any independent phase work that remains valid. Do not turn a blocker into an unapproved architectural rewrite.

---

## 17. Final definition of done

`0.2.0` is done only when all statements are true:

- [ ] Vault is frozen and absent from the active feature roadmap.
- [ ] Existing Vault implementation was neither expanded nor redesigned.
- [ ] Existing Notes and Assets behavior remains stable.
- [ ] PDF, Markdown, and plain-text Documents import through the Asset pipeline.
- [ ] Document versions and fragments are immutable and provenance-preserving.
- [ ] Unified PostgreSQL search returns exact Note and Document versions.
- [ ] Tags, relationships, and backlinks work.
- [ ] Note-version attachments and citations are immutable and source-pinned.
- [ ] Tombstone and restore correctly invalidate and rebuild projections.
- [ ] Portable export is understandable without Singularity.
- [ ] Backup v3 round-trips the complete knowledge state.
- [ ] v1 and v2 backups remain restorable.
- [ ] A `0.1.0` installation upgrades successfully.
- [ ] The complete browser workflow passes.
- [ ] All repository verification gates pass on the release source SHA.
- [ ] amd64 and arm64 release images pass runtime extraction smoke tests.
- [ ] Release artifacts, tag, image digests, SBOM, and provenance refer to the same source.
- [ ] No Qdrant, embedding, RAG, Agent, OCR, or unrelated domain work entered the release.
