---
title: "PRD-001: Singularity Knowledge Core MVP"
status: Draft
version: 0.1
owner: Jonathan
date: 2026-07-15
product: Singularity
target_release: v0.1
---

# PRD-001: Singularity Knowledge Core MVP

## 1. Summary

Singularity is a personal, LLM-native knowledge base written in Elixir as an umbrella application. It stores heterogeneous knowledge, preserves immutable history, builds a semantic retrieval projection in Qdrant, and generates answers grounded in exact source revisions.

This PRD defines the first complete vertical slice:

```text
create or import knowledge
→ preserve an immutable revision
→ deterministically chunk it
→ embed and index it in Qdrant
→ retrieve relevant chunks
→ generate a cited answer through Backplane
```

The first release optimizes for **data safety, reproducibility, and architectural boundaries**, not breadth. It supports one user, one logical knowledge space, and a single active deployment node. Its storage and indexing design must remain compatible with a later two-server deployment.

## 2. Problem

Personal knowledge is spread across notes, Markdown files, source material, and model conversations. Existing tools commonly create one or more of these problems:

- Knowledge is trapped in one representation or application.
- Edits overwrite prior content without reliable provenance.
- Semantic indexes become an undocumented second source of truth.
- LLM answers cannot be traced to exact source material.
- Model-generated content is mixed with human-authored knowledge.
- Re-indexing after changing an embedding model is unsafe or expensive.
- Replicated document databases can make conflicting updates appear lost.

Singularity must provide a durable knowledge substrate that LLMs and agents can query without allowing model execution or vector indexing failures to corrupt canonical knowledge.

## 3. Product principles

1. **Canonical knowledge is durable and inspectable.** CouchDB stores knowledge items and immutable revisions.
2. **Content history is application-level history.** CouchDB `_rev` values are concurrency metadata, not user-visible version history.
3. **Qdrant is a disposable projection.** Deleting Qdrant must never delete knowledge.
4. **All transformations are deterministic where practical.** The same revision and pipeline versions produce the same chunks and point IDs.
5. **LLM output is derived content.** A model never silently mutates canonical knowledge.
6. **Every generated factual answer is evidence-grounded.** Citations resolve to exact revision and chunk identifiers.
7. **Concurrency conflicts are visible.** Singularity never resolves a content conflict by silently discarding a branch.
8. **Umbrella boundaries express failure domains.** Applications are coarse, acyclic, and independently testable.
9. **Singularity remembers and retrieves.** Backplane supplies model access; Synapsis owns long-running agents and autonomous execution.

## 4. Goals

### 4.1 Product goals

- Create and edit personal notes without losing earlier content.
- Import Markdown and plain-text files.
- Search by semantic meaning and metadata.
- Ask questions and receive streamed answers with exact citations.
- Inspect the source text behind every citation.
- Rebuild the entire vector index from canonical data.
- Record sufficient provenance to diagnose retrieval and generation failures.
- Establish stable APIs that Synapsis can later expose as agent tools.

### 4.2 Engineering goals

- Establish the Singularity umbrella and dependency graph.
- Define storage, vector, embedding, and generation behaviours.
- Implement a CouchDB adapter that prevents unsafe partial updates.
- Implement deterministic content normalization and chunking.
- Implement an idempotent Qdrant projection.
- Integrate Backplane through one narrow adapter.
- Provide contract tests and failure-path tests without requiring real LLM calls.

## 5. Non-goals

The following are explicitly outside PRD-001:

- Native two-node CouchDB clustering.
- Bidirectional CouchDB replication and automatic failover.
- Active-active writes across two servers.
- PDF, office document, image, audio, and video parsing.
- Web crawling or scheduled source synchronization.
- Multiple users, organizations, or complex authorization.
- Autonomous agents, heartbeat, dream/reflection, or scheduled agent work.
- Knowledge graph extraction and graph traversal.
- Automatic claim acceptance or model-authored canonical edits.
- Multiple embedding models active at the same time.
- Sparse-vector retrieval, rerankers, or advanced hybrid search.
- Mobile clients and offline-first editing.

These may be introduced by subsequent PRDs after the core invariants are proven.

## 6. User and primary scenarios

### 6.1 Primary user

The initial user is the owner and operator of the deployment. The user is technically proficient, understands revisions and source provenance, and prefers a local or privately hosted system.

### 6.2 Core scenarios

#### Scenario A: Create a note

1. The user creates a note with a title, body, tags, and optional metadata.
2. Singularity creates a stable item document.
3. Singularity creates an immutable content revision.
4. The item head points to that revision.
5. The revision is chunked, embedded, and indexed.
6. The UI shows `ready` when the Qdrant projection is current.

#### Scenario B: Revise a note

1. The user loads the current item and revision.
2. The user edits the body.
3. Singularity creates a new immutable revision with the prior revision as its parent.
4. Singularity updates the item head using the current CouchDB `_rev`.
5. A stale update returns a conflict and does not overwrite either content branch.
6. Previous revisions remain readable.

#### Scenario C: Import a Markdown file

1. The user uploads a `.md` or `.txt` file.
2. Singularity stores the original bytes or a content-addressed blob reference.
3. Singularity normalizes the content into canonical text and blocks.
4. The same revision and parser version always produce the same chunk IDs.
5. The imported item becomes searchable after indexing.

#### Scenario D: Search knowledge

1. The user submits a natural-language query with optional tag/type filters.
2. Singularity embeds the query through Backplane.
3. Qdrant returns candidate chunk IDs.
4. Singularity reloads canonical chunks and item state from CouchDB.
5. Stale, deleted, or non-head revisions are excluded by default.
6. Search results show title, heading path, snippet, type, tags, and revision.

#### Scenario E: Ask a question

1. The user asks a question.
2. Singularity records a retrieval snapshot.
3. Singularity selects evidence within a bounded context budget.
4. Backplane generates a streamed answer using numbered evidence chunks.
5. Every citation is validated against the supplied evidence.
6. Unsupported questions return an explicit insufficient-evidence result rather than fabricated certainty.

#### Scenario F: Rebuild the search index

1. The operator deletes or replaces the Qdrant collection.
2. Singularity scans current canonical revisions.
3. Singularity deterministically regenerates chunks and embeddings.
4. Singularity upserts points using stable IDs.
5. The rebuilt collection produces resolvable citations and no duplicate logical chunks.

## 7. Umbrella architecture

### 7.1 Applications

```text
singularity/
├── apps/
│   ├── singularity_core/
│   ├── singularity_store/
│   ├── singularity_retrieval/
│   ├── singularity_runtime/
│   └── singularity_web/
├── config/
├── rel/
└── mix.exs
```

#### `singularity_core`

Owns pure domain logic and contracts:

- Knowledge item, revision, block, chunk, citation, and retrieval types.
- Validation and schema-version rules.
- Content normalization.
- Deterministic chunking.
- Merge planning for conflicting item heads.
- Behaviours for `KnowledgeStore`, `VectorStore`, `BlobStore`, `Embedder`, and `Generator`.

It must not depend on Phoenix, CouchDB, Qdrant, Backplane, or another umbrella sibling.

#### `singularity_store`

Owns canonical persistence:

- CouchDB HTTP adapter.
- Complete-document update discipline.
- Immutable revision creation.
- Mutable item-head updates.
- Attachments or blob references.
- Conflict discovery.
- Soft deletion.
- Schema migration on read/write.
- Store contract tests.

No other application may issue raw CouchDB writes.

#### `singularity_retrieval`

Owns the Qdrant projection:

- Collection and alias lifecycle.
- Point upsert and deletion.
- Payload indexes.
- Semantic query.
- Index manifest and collection version.
- Projection reconciliation and rebuild.
- Vector-store contract tests.

It must treat all indexed content as reconstructible.

#### `singularity_runtime`

Owns use cases and orchestration:

- Note creation and revision workflows.
- File import pipeline.
- Chunk generation.
- Embedding through Backplane.
- Projection state transitions.
- Search candidate validation.
- Context selection.
- Cited answer generation.
- Retrieval and model-run provenance.

This is the only application that composes store, retrieval, and model capabilities.

#### `singularity_web`

Owns interfaces:

- Phoenix endpoint and router.
- LiveView UI.
- JSON API.
- Authentication for the single owner.
- Uploads.
- Search and answer streaming.
- Revision history and conflict presentation.
- Operational status and reindex controls.

It must call `singularity_runtime` public APIs rather than adapters directly.

### 7.2 Dependency direction

```text
                         singularity_core
                         ▲       ▲      ▲
                         │       │      │
              singularity_store │ singularity_retrieval
                         ▲       │      ▲
                         └───────┼──────┘
                                 │
                       singularity_runtime
                                 ▲
                                 │
                         singularity_web
```

Required rules:

- The graph is acyclic.
- Infrastructure modules do not leak through public domain APIs.
- `mix xref graph` is checked in CI.
- Sibling calls use documented public modules.

### 7.3 External boundaries

```text
Singularity → CouchDB   canonical knowledge
Singularity → Qdrant    semantic projection
Singularity → Backplane embeddings and answer generation
Synapsis    → Singularity knowledge tools in a later PRD
```

Singularity does not implement a competing general agent runtime.

## 8. Canonical data model

All documents include:

```text
_id
_rev                 # CouchDB concurrency only
kind
schema_version
created_at
updated_at
```

### 8.1 `knowledge_item`

A small mutable document representing stable identity and current heads.

```text
kind: "knowledge_item"
item_id
content_type: "note" | "markdown" | "text"
title
tags
metadata
head_revision_ids
status: "active" | "conflicted" | "deleted"
deleted_at
```

Rules:

- `head_revision_ids` is a list, even when it contains one revision.
- Updating an item requires the current `_rev`.
- Item updates send the complete document, never a partial replacement.
- A conflict must preserve all known heads.
- Deletion is soft in this release.

### 8.2 `knowledge_revision`

An immutable application-level content version.

```text
kind: "knowledge_revision"
revision_id
item_id
parent_revision_ids
content_type
canonical_text
structured_content
content_hash
source
parser_version
normalizer_version
created_by: "human" | "importer" | "model-proposal"
```

Rules:

- A successfully created revision is never updated.
- The revision ID is stable and application-controlled.
- CouchDB `_rev` is not exposed as content history.
- Canonical text is sufficient to rebuild chunks.
- Model proposals do not become an item head without an explicit user action.

### 8.3 `knowledge_chunk`

An immutable, deterministic retrieval and citation unit.

```text
kind: "knowledge_chunk"
chunk_id
item_id
revision_id
position
heading_path
text
start_offset
end_offset
token_count
content_hash
chunker_version
```

Rules:

- Chunk ID derives from revision, chunker version, position, and content hash.
- Chunks can be deleted and recreated only if generation is deterministic.
- A citation targets `revision_id` and `chunk_id`, not a Qdrant result rank.

### 8.4 `projection_state`

Tracks the derived state of one revision.

```text
kind: "projection_state"
revision_id
pipeline_version
embedding_model
embedding_dimensions
collection_version
status: "pending" | "processing" | "ready" | "failed" | "stale"
attempts
last_error
indexed_at
```

This state is operational and recoverable. It must not contain unique knowledge.

### 8.5 `answer_run`

An append-only provenance record for a generated answer.

```text
kind: "answer_run"
run_id
question
filters
retrieval_snapshot
selected_chunk_ids
prompt_program_version
model_route
status
answer
citations
usage
latency_ms
error
```

The product stores no hidden model chain-of-thought. It stores inputs, selected evidence, public answer content, tool/model metadata, and errors needed for reproducibility.

## 9. Data-integrity invariants

These invariants are release-blocking:

1. An acknowledged revision write returns CouchDB `201 Created`.
2. Singularity never uses CouchDB `batch=ok` for canonical data.
3. Singularity never treats HTTP `202 Accepted` as a completed canonical write.
4. A mutable document update always includes the complete current document and current `_rev`.
5. A `409 Conflict` is surfaced and handled; it is never bypassed with blind overwrite.
6. An item head references only existing immutable revisions.
7. A revision body is never mutated after creation.
8. Qdrant contains no knowledge that cannot be reconstructed from CouchDB.
9. A generated citation resolves to an existing chunk and revision.
10. LLM output cannot move an item head without explicit user confirmation.
11. Repeating an indexing operation converges to the same logical Qdrant points.
12. Soft-deleted items are excluded from default search and answer generation.

## 10. Functional requirements

### FR-001 — Create knowledge item

The system shall create a stable item and its first immutable revision as one recoverable workflow.

Acceptance conditions:

- Failure before revision creation leaves no visible item, or a reconciler marks and repairs the incomplete item.
- Failure after revision creation but before moving the head leaves the revision recoverable.
- The final item head references the created revision.

### FR-002 — Append revision

The system shall create a new immutable revision from an existing item.

Acceptance conditions:

- The prior revision remains readable.
- Parent revision IDs are recorded.
- Stale item `_rev` values return a domain conflict.
- No content branch is automatically discarded.

### FR-003 — Import Markdown and plain text

The system shall accept `.md` and `.txt` uploads.

Acceptance conditions:

- MIME type, original filename, byte size, and SHA-256 are recorded.
- Duplicate bytes for the same source do not create duplicate logical revisions unless explicitly requested.
- Parser errors are visible and retryable.
- Original bytes or a durable blob reference are retained.

### FR-004 — Normalize and chunk content

The system shall normalize supported content and create deterministic chunks.

Initial chunking policy:

- Respect Markdown heading boundaries.
- Preserve fenced code blocks as indivisible blocks when they fit the maximum size.
- Target 400–700 model tokens per chunk.
- Use 10–15% overlap only across compatible adjacent text blocks.
- Include title and heading path in embedding input, but keep citation text canonical.
- Record character offsets into canonical text.

### FR-005 — Project chunks into Qdrant

The system shall embed and index current chunks.

Acceptance conditions:

- Qdrant point ID equals a stable representation of `chunk_id`.
- Upserts are idempotent.
- Payload includes `item_id`, `revision_id`, `chunk_id`, type, tags, heading path, and active status.
- The projection becomes `ready` only after all expected points are verifiably present.
- Failed embedding or Qdrant calls retain retryable state.

### FR-006 — Semantic search

The system shall search current knowledge by natural-language query.

Acceptance conditions:

- Query embedding is obtained through the Backplane adapter.
- Type and tag filters are supported.
- Qdrant candidates are revalidated against CouchDB.
- Default results include only active item heads.
- The result includes canonical snippet, title, heading path, revision, and score/rank information.

### FR-007 — Cited answer generation

The system shall generate an answer using retrieved evidence.

Acceptance conditions:

- The model sees only selected, numbered evidence chunks.
- The prompt requires citation identifiers.
- Every returned citation is validated before display.
- Invalid citations are removed or cause the answer run to fail validation.
- When evidence is insufficient, the response explicitly says so.
- The answer streams to the client when Backplane supports streaming.

### FR-008 — Revision history and source inspection

The system shall display all revisions for an item and allow opening an exact cited chunk in context.

Acceptance conditions:

- The UI can navigate from answer citation to chunk, revision, and item.
- The user can inspect parent revision relationships.
- Conflicted items display all current heads.

### FR-009 — Reindex and reconcile

The operator shall be able to rebuild or repair the Qdrant projection.

Acceptance conditions:

- A full rebuild works from an empty collection.
- A reconciliation reports missing, stale, duplicate, and orphaned points.
- A rebuild does not mutate canonical revisions.
- Repeating the rebuild does not create duplicate logical points.

### FR-010 — Export

The operator shall be able to export all canonical knowledge independently of Qdrant and the LLM provider.

Acceptance conditions:

- Export includes items, immutable revisions, chunk manifests or deterministic generation metadata, attachments/blob references, and schema versions.
- Exported data is sufficient to reconstruct the application-visible knowledge history.

## 11. Interface requirements

### 11.1 Runtime public API

The first stable use-case surface should be conceptually equivalent to:

```text
Singularity.Runtime.create_note/1
Singularity.Runtime.import_file/2
Singularity.Runtime.append_revision/3
Singularity.Runtime.get_item/1
Singularity.Runtime.list_revisions/1
Singularity.Runtime.search/2
Singularity.Runtime.answer/2
Singularity.Runtime.reindex/1
Singularity.Runtime.reconcile/0
```

Return values must use explicit domain result types rather than leaking CouchDB or Qdrant response structures.

### 11.2 HTTP API

Initial JSON endpoints:

```text
POST   /api/v1/items
GET    /api/v1/items/:id
POST   /api/v1/items/:id/revisions
GET    /api/v1/items/:id/revisions
GET    /api/v1/revisions/:id
POST   /api/v1/imports
POST   /api/v1/search
POST   /api/v1/answers
POST   /api/v1/ops/reindex
GET    /api/v1/ops/status
```

Mutation endpoints require owner authentication and an idempotency key where retrying could duplicate work.

### 11.3 Future Synapsis tool surface

PRD-001 must not implement the agent integration, but the runtime API must be suitable for later exposure as:

```text
singularity.search
singularity.get
singularity.remember
singularity.revise
singularity.history
```

## 12. LLM and prompt requirements

### 12.1 Backplane adapter

All model access flows through one adapter owned by `singularity_runtime`:

```text
embed_documents
embed_query
generate_answer_stream
```

No domain, storage, retrieval, or web module may call a provider directly.

### 12.2 Prompt versioning

Each answer run records:

- Prompt program name and version.
- Model route and provider response identifier when available.
- Retrieval filters.
- Candidate and selected chunk IDs.
- Embedding model and collection version.
- Token usage and latency when available.

### 12.3 Safety and trust boundaries

- Retrieved documents are untrusted input.
- Document text cannot alter system-level instructions.
- The answer path has no filesystem, shell, network, or mutation tools.
- Generated answers cannot update canonical knowledge.
- A future `remember` flow creates a proposal or explicit user-authored revision, never a hidden side effect of answering.

## 13. Non-functional requirements

### NFR-001 — Durability

A successful canonical write must survive application-process restart. The application must distinguish local persistence from future cross-server replication status.

### NFR-002 — Recoverability

The operator must be able to:

- Restore CouchDB data and blobs from backup.
- Start with an empty Qdrant collection.
- Rebuild current search points.
- Verify that all item heads resolve to revisions.
- Verify that all current revisions have expected chunks.

### NFR-003 — Idempotency

Import, chunking, embedding, indexing, and answer-run persistence must tolerate retries without corrupting canonical state.

### NFR-004 — Performance targets

For a local corpus of up to 100,000 chunks on supported hardware:

- Item and revision reads: p95 under 250 ms excluding network setup.
- Semantic search after query embedding: p95 under 1 second.
- UI remains responsive while embedding or generation is in progress.
- Answer generation is streamed; no fixed completion-time guarantee is imposed on external model providers.

These are engineering targets, not external service guarantees.

### NFR-005 — Observability

Telemetry must cover:

- CouchDB request duration, status, and conflict count.
- Import and parsing duration and failures.
- Chunk counts and token distributions.
- Embedding batch duration, retries, and usage.
- Qdrant upsert/search duration and errors.
- Retrieval candidate counts and selected counts.
- Answer latency, usage, validation failures, and insufficient-evidence responses.

Logs must carry `request_id`, `item_id`, `revision_id`, `run_id`, and `pipeline_version` when applicable.

### NFR-006 — Security

- Owner authentication is required outside development.
- CouchDB, Qdrant, and Backplane endpoints are not exposed publicly.
- Secrets are provided at runtime and never stored in canonical documents.
- File uploads have configurable size limits.
- Imported filenames cannot control filesystem paths.
- Markdown rendering sanitizes unsafe HTML.

### NFR-007 — Portability

The release must run on NixOS and generic Linux through an Elixir release. Local development dependencies should be reproducible with a Nix flake or devenv configuration.

### NFR-008 — Testing

- Core algorithms use unit and property tests.
- Infrastructure adapters use contract tests.
- Runtime workflows use fake store, vector, and model adapters where practical.
- Integration tests run against real CouchDB and Qdrant in CI or a dedicated integration job.
- No test requires a billable external LLM call.

## 14. User interface scope

The MVP UI contains five primary views:

1. **Library** — list and filter items.
2. **Editor** — create and revise notes.
3. **Item history** — inspect immutable revisions and conflicts.
4. **Search/Ask** — semantic results and cited streamed answers.
5. **Operations** — projection status, failed jobs, reconcile, and reindex.

Required visual states:

```text
saved
indexing
ready
index_failed
conflicted
deleted
```

The UI must never display `saved` as equivalent to `indexed`.

## 15. Success metrics

The MVP is successful when:

- 100% of item heads reference existing immutable revisions.
- 100% of displayed answer citations resolve to exact chunks and revisions.
- A clean Qdrant rebuild recreates the expected logical point set.
- Repeated projection runs produce no duplicate logical chunks.
- Concurrent stale item updates produce visible conflicts rather than overwritten content.
- No canonical write path uses partial CouchDB document replacement.
- The user can create a note and receive a cited answer about it through one end-to-end workflow.
- The user can export all knowledge without requiring Qdrant or Backplane.

## 16. Release acceptance tests

PRD-001 is complete only when all of the following pass:

1. Create a note and verify the first immutable revision.
2. Revise the note and verify both revisions remain readable.
3. Attempt a stale concurrent update and verify a conflict with no lost branch.
4. Import a Markdown file twice and verify deterministic deduplication behavior.
5. Crash the runtime after revision creation but before indexing; restart and reach `ready` through reconciliation.
6. Execute the same indexing operation twice and verify one logical point per chunk.
7. Delete the Qdrant collection, rebuild it, and resolve all search results back to CouchDB.
8. Search for content using a semantic paraphrase.
9. Generate an answer whose citations all open exact canonical source chunks.
10. Force the model to return an invalid citation and verify validation catches it.
11. Ask a question absent from the corpus and verify an insufficient-evidence response.
12. Export and restore canonical data into an empty test environment.
13. Run the complete test suite with fake model adapters and no external model billing.

## 17. Delivery plan

### PR 1 — Umbrella skeleton and contracts

- Create the five umbrella applications.
- Define dependency rules.
- Add core domain structs and behaviours.
- Add fake adapters and contract-test harnesses.
- Add CI checks including `mix xref graph`.

### PR 2 — Loss-safe CouchDB knowledge store

- Implement CouchDB adapter.
- Implement item and immutable revision documents.
- Enforce complete-document updates and `_rev` checks.
- Add conflict and crash-recovery tests.
- Add export primitives.

### PR 3 — Normalization and deterministic chunking

- Implement Markdown/plain-text normalization.
- Implement chunk generation and stable IDs.
- Persist chunks and projection state.
- Add property tests for determinism and offsets.

### PR 4 — Qdrant projection and semantic search

- Implement collection bootstrap and payload indexes.
- Implement Backplane embedding adapter.
- Implement idempotent upsert, query, reconciliation, and rebuild.
- Revalidate all candidates against CouchDB.

### PR 5 — Cited RAG

- Add retrieval snapshots.
- Add context-budget selection.
- Add versioned answer prompt.
- Stream answers through Backplane.
- Validate citations and insufficient-evidence behavior.

### PR 6 — Phoenix MVP and operational controls

- Add library, editor, history, search/ask, and operations views.
- Add owner authentication.
- Add import flow and status updates.
- Add telemetry dashboards or structured operational endpoints.

## 18. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| CouchDB full-document updates omit fields | Apparent data loss | Centralize all writes; load/merge/save complete documents; contract tests |
| CouchDB conflict winner hides another branch | Apparent data loss | Immutable revisions; plural heads; explicit conflict UI |
| Qdrant becomes accidental source of truth | Irrecoverable knowledge/index drift | Canonical chunk text in CouchDB; mandatory rebuild test |
| LLM returns fabricated citations | Misleading answer | Identifier-based citations and post-generation validation |
| Embedding model changes | Mixed incompatible vectors | Versioned collection manifest and future alias migration |
| Pipeline retry duplicates data | Index bloat and inconsistent state | Deterministic IDs and idempotent upserts |
| Umbrella applications become tightly coupled | Slow development and refactoring | Coarse boundaries, behaviours, xref CI, no adapter leakage |
| MVP expands into agent platform | Unbounded scope | Keep autonomous execution in Synapsis; defer tool integration |
| External model outage blocks knowledge use | Reduced functionality | Canonical browsing remains available; clear degraded state |

## 19. Decisions captured by this PRD

- The product name and Elixir namespace are `Singularity`.
- The implementation is an Elixir umbrella with five initial applications.
- CouchDB is the canonical store for knowledge items and immutable revisions.
- Qdrant is a rebuildable vector projection.
- Backplane is the only model-access boundary.
- Synapsis remains the future long-running agent execution plane.
- The first release supports notes, Markdown, and plain text only.
- The first release is single-user and single-active-node.
- Two-server replication and failover require a separate PRD and failure model.
- Model output is never silently promoted to canonical knowledge.

## 20. Follow-on PRDs

Planned sequence:

```text
PRD-002  Two-server replication, backup, failover, and conflict operations
PRD-003  Source connectors and rich document ingestion
PRD-004  Synapsis knowledge tools and agent-memory integration
PRD-005  Claims, links, and knowledge graph projections
PRD-006  Multi-model indexing, hybrid retrieval, and reranking
```

## 21. Definition of done

Singularity v0.1 is done when the owner can:

```text
create or import knowledge
revise it without losing history
search it semantically
ask a question
inspect every citation
remove and rebuild Qdrant
export all canonical knowledge
```

and when every failure-path test demonstrates that canonical content survives indexing failures, process crashes, stale updates, and invalid model output.
