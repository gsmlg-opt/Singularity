# Singularity Foundation and Asset Vertical Design

**Status:** Approved design

**Date:** 2026-07-18

**Governing architecture:** [`docs/guide.md`](../../guide.md)

**Delivery scope:** Milestone 0, a local-storage Milestone 1a, and the first complete asset vertical
**Upstream ESS dependency:** [`gsmlg-opt/ex_storage_service#5`](https://github.com/gsmlg-opt/ex_storage_service/issues/5)

## 1. Purpose

This design turns the architecture guide into the first implementable Singularity
release slice.

The branch will establish:

- The replacement seven-application umbrella.
- PostgreSQL as canonical structured storage.
- A content-addressed local directory as temporary canonical binary storage.
- A stable object-storage port that can later use embedded ExStorageService.
- Vault- and domain-scoped envelope encryption for canonical binary storage.
- A transactional outbox and interchangeable durable job-runner port.
- Oban as the initial job-runner adapter.
- Owner authentication, vault unlock, capabilities, RLS, and audit.
- A complete upload, verification, technical-metadata extraction, metadata
  search, download, logical deletion, cleanup, backup, and restore workflow.
- A Phoenix shell with a React asset workbench mounted through the App-Clip
  integration seam.

The implementation must preserve the guide's central invariant: PostgreSQL and
the configured object store are canonical; every index and enrichment is
rebuildable.

## 2. Authority and replacement

`docs/guide.md` supersedes the removed knowledge-core PRD and its CouchDB-first
delivery sequence.

The existing PR 1 source code is historical scaffolding, not an API
compatibility constraint. The implementation may remove or replace the old
knowledge-specific structs, behaviours, fakes, tests, and exact five-app
architecture guard when they do not fit this design.

The following ideas remain useful and should be preserved:

- Explicit behaviours at infrastructure boundaries.
- Immutable source versions.
- Exact provenance.
- Idempotent reconciliation.
- Rebuildable projections.
- Architecture tests and contract-test harnesses.
- A web application that depends on the composition root rather than concrete
  adapters.

## 3. Delivery boundary

### 3.1 In scope

- Milestone 0 foundation:
  - Seven-application umbrella and dependency guard.
  - PostgreSQL repository and migrations.
  - Durable outbox.
  - Job-runner port and Oban adapter.
  - Structured logging, audit telemetry, and basic metrics.
  - Reproducible `devenv` services.
  - Initial ADR set for decisions exercised by this branch.
- Local-storage Milestone 1a identity, vault, and assets:
  - Person, account, credential, principal, device skeleton, vault,
    classification, capability, and session records.
  - Password authentication and vault-key wrapping.
  - Local content-addressed storage adapter.
  - Per-object envelope encryption and protected deduplication identities.
  - Asset state machine and lifecycle jobs.
  - Background technical-metadata extraction for PDF, JPEG, and PNG.
  - Vault-scoped PostgreSQL search over asset metadata.
  - RLS and capability enforcement.
  - Append-only audit events.
  - Backup manifest, backup, restore, and integrity audit.
- Complete first vertical:
  - Bootstrap owner.
  - Login.
  - Unlock vault.
  - Upload a PDF or photo.
  - Encrypt, deduplicate, and verify bytes.
  - Persist resource, version, and asset metadata.
  - Extract supported technical metadata in a background job.
  - Search the imported asset by title, original filename, media type, and
    lifecycle state.
  - Display lifecycle progress.
  - Download with authorization.
  - Logically delete.
  - Clean derived state and unreferenced bytes.
  - Back up and restore one vault.

### 3.2 Explicitly out of scope

- Notes, document editing, PDF body text extraction, and citations.
- Photo-library synchronization, albums, EXIF extraction, and thumbnails.
- Video playback, FFmpeg, Jellyfin, and media caches.
- Subscriptions and external connectors.
- Finance and health.
- Tantivy.
- Qdrant and semantic vector search.
- Backplane and model calls.
- Agents.
- Multi-node runtime or device synchronization.
- The embedded ExStorageService Hex package.
- The Milestone 1 S3 adapter.

Qdrant remains a required Milestone 8 adapter and rebuildable vector projection.
It is not configured or exercised by this branch.

This branch does not claim the guide's complete Milestone 1 storage-adapter
matrix. Embedded ESS is waiting on upstream issue #5 and S3 follows after that
port is proven. The branch does complete the user-approved local-storage
vertical, including the guide's background metadata and search steps.

## 4. Application architecture

The umbrella contains exactly seven applications:

```text
apps/
├── singularity_core
├── singularity_storage
├── singularity_domains
├── singularity_ingest
├── singularity_retrieval
├── singularity_runtime
└── singularity_web
```

### 4.1 Dependency graph

```text
singularity_core
  └── no internal dependencies

singularity_domains
  └── singularity_core

singularity_storage
  ├── singularity_core
  └── singularity_domains

singularity_ingest
  ├── singularity_core
  └── singularity_domains

singularity_retrieval
  ├── singularity_core
  └── singularity_domains

singularity_runtime
  ├── singularity_core
  ├── singularity_storage
  ├── singularity_domains
  ├── singularity_ingest
  └── singularity_retrieval

singularity_web
  └── singularity_runtime
```

The architecture test must enumerate `apps/*/mix.exs`, require this exact set,
and enforce this allow-list. It must also reject direct web references to
storage, domain, ingest, or retrieval modules.

### 4.2 Ownership

`singularity_core` owns:

- Pure cross-domain types and invariants.
- Person, account, principal, device, vault, resource, version, asset,
  classification, capability, audit, and domain-event concepts.
- Object-storage, repository, outbox, job-runner, clock, ID, encryption, and
  audit behaviours.
- Stable domain errors and result types.
- No infrastructure and no production process.

`singularity_domains` owns:

- Typed domain contexts and domain-facing persistence contracts.
- The initial Identity, Vault, and Assets contexts.
- Future Notes, Documents, Photos, Media, Finance, Health, Library,
  Subscriptions, and Timeline contexts.
- No adapter selection.

`singularity_storage` owns:

- Ecto repository and migrations.
- PostgreSQL adapters for domain persistence and audit.
- RLS session setup.
- Local filesystem object-storage adapter.
- Chunked authenticated-encryption codec and key-envelope persistence.
- Future embedded ESS and S3 adapters.
- Outbox persistence and dispatch adapter.
- Oban job-runner adapter.
- Backup manifests and storage-integrity operations.

`singularity_ingest` owns:

- Import workflow primitives, staged upload metadata, idempotency, and retry
  state.
- Future connectors, checkpoints, and normalization.

`singularity_retrieval` owns:

- Rebuildable retrieval ports and projection state.
- Vault-scoped PostgreSQL asset-metadata search in this branch.
- PostgreSQL lexical retrieval in Milestone 2.
- Qdrant semantic vectors in Milestone 8.

`singularity_runtime` owns:

- The application supervision tree and adapter wiring.
- Public use cases for bootstrap, login, vault unlock/lock, upload, asset status,
  download authorization, deletion, cleanup, backup, restore, and integrity
  audit.
- Job dispatch from stable job envelopes to domain handlers.
- Session-scoped unlocked-key custody.
- Key rotation and password-change rewrapping use cases.
- CLI and non-web composition.

`singularity_web` owns:

- Phoenix endpoint, router, sessions, controllers, LiveViews, and JSON
  serialization.
- The DuskmoonBundler asset profile.
- The React App-Clip hook and asset workspace.
- No domain rules and no concrete storage calls.

## 5. PostgreSQL model

Migrations are owned by `singularity_storage`. Use logical PostgreSQL schemas:

```text
identity
core
content
jobs
audit
```

The first branch creates at least:

```text
identity.people
identity.accounts
identity.credentials
identity.principals
identity.sessions
identity.devices

core.vaults
core.vault_members
core.capabilities
core.principal_capabilities
core.data_classifications
core.key_domains
core.vault_key_versions
core.vault_key_wrappers
core.domain_key_versions
core.domain_dedup_key_wrappers
core.outbox_events

content.resources
content.resource_versions
content.assets
content.asset_objects
content.asset_key_envelopes
content.asset_metadata
content.asset_search_documents
content.resource_assets
content.source_references
content.tombstones
content.upload_grants

jobs.oban_jobs
jobs.oban_peers

audit.events
audit.backup_manifests
```

All user-owned rows carry `vault_id` directly or through an enforced parent.
Stable query-critical fields use typed columns. `jsonb` is limited to extension
metadata and versioned job/event payloads.

`content.asset_objects` is the canonical encrypted-object record. It stores the
vault and encryption domain, protected lookup digest, ciphertext digest, byte
counts, storage reference, format version, and object lifecycle. Logical
`content.assets` rows may share one object row. `content.asset_key_envelopes`
stores only wrapped per-object data-encryption keys and their key generations.

`content.asset_metadata` is a typed, versioned technical-metadata projection.
For this branch it stores original filename, declared and detected media type,
plaintext byte size, PDF header version, image width and height, extraction
state, extractor version, and timestamps. Fields that do not apply are `NULL`;
arbitrary extracted JSON is not introduced.

`content.asset_search_documents` is a rebuildable projection containing asset
ID, resource-version ID, vault ID, classification, lifecycle state, detected
media type, and a generated `tsvector` from the current resource title and
original filename.

Database roles are explicit:

- A no-login table owner owns tables and RLS policies.
- A migration administrator applies migrations and is never used by the
  running application. An external PostgreSQL superuser provisioner creates
  it as a no-`BYPASSRLS`, `NOCREATEROLE`, task-only `CREATEDB` login. It has
  `SET TRUE, INHERIT FALSE, ADMIN FALSE` membership in the owner roles solely
  so migrations can execute database-local DDL as the correct owner.
- A no-login authorization-definer owns only the fixed
  `core.principal_is_authorized/2` function and can read only the active
  membership columns required by that function.
- `singularity_pre_auth` has no table privileges and can execute only the
  authentication/session functions described below.
- `singularity_web` handles request transactions and has no `BYPASSRLS`.
- `singularity_dispatcher` can execute narrowly scoped, audited
  `SECURITY DEFINER` outbox claim/acknowledgement functions but cannot read
  domain tables directly.
- `singularity_worker` owns no tables, can operate the `jobs` schema, has no
  `BYPASSRLS`, and accesses domain rows only after establishing the job's
  principal and vault context.

Every user-data table uses `FORCE ROW LEVEL SECURITY`. Ordinary request and
worker policies are explicitly limited to those runtime roles and fail closed
when either `singularity.principal_id` or `singularity.vault_id` is absent.
Both SQL predicates and checkout checks treat `NULL` and PostgreSQL's empty
custom-GUC reset sentinel as absent, so a reused connection fails closed
without attempting to cast an empty string to UUID. Context is set only with
`SET LOCAL` inside an Ecto transaction.
Security-definer functions have a fixed `search_path`, validate their inputs,
and expose only their minimum result.

The request/worker policy predicate calls
`core.principal_is_authorized(principal_id, vault_id)`. That function runs as
a dedicated no-login, no-`BYPASSRLS` authorization-definer and reads only the
active principal/vault row in `core.vault_members`. The forced-RLS membership
table has one separate policy targeted only at that definer role with a
non-recursive `USING (true)` expression. Ordinary request/worker policies are
never `TO PUBLIC` and do not include the definer role, so the helper lookup
cannot invoke itself recursively. The helper also requires both arguments to
equal the current transaction GUCs, preventing direct calls from becoming a
cross-vault membership oracle. Runtime roles cannot `SET ROLE` to any definer.
Function execution is revoked from `PUBLIC` and granted only to the request
and worker roles. Integration tests prove active, missing, revoked, cross-GUC,
and missing-GUC results and reject policy recursion.

Function migrations temporarily grant the target no-login definer `CREATE` on
the schema, `SET LOCAL ROLE` to that definer, and create or replace the
function as its final owner. The table owner then revokes schema `CREATE`;
the definer retains only schema `USAGE` and its exact table/column privileges.

Cluster-role creation and membership normalization never run through
`MigrationRepo`. In development/CI, the database gate waits for the managed
PostgreSQL service, then explicitly runs the checked role-provisioning SQL
with a local superuser URL that is not loaded into application configuration.
In production, the database platform provisioner or IaC applies the same role
contract out of band. A read-only Mix task verifies final role flags and
memberships before any migration or integration database is created.

Other security-definer functions expose only the minimum columns required to
claim work and emit their required audit record. Connection checkout asserts
no context leaked from a prior borrower.

Login and opaque-session resolution are the only pre-context exceptions.
`singularity_pre_auth` may execute three narrowly scoped functions owned by a
no-login definer role:

```text
identity.authentication_candidate(normalized_login)
identity.resolve_session(session_token_digest)
identity.record_auth_attempt(login_fingerprint, source_fingerprint, result)
```

They return only the credential verifier or session context required for one
attempt, never lists or counts, and the candidate function returns a fixed dummy
verifier for an unknown login. Direct reads of identity tables remain denied.
The identity policies permit only the exact no-login function-owner role for
these calls; neither the function owner nor `singularity_pre_auth` receives
`BYPASSRLS`.
External responses are uniform for unknown and invalid credentials. Tests prove
the pre-auth role cannot enumerate identities, the functions do not leak
account existence, and the resolved context cannot survive connection reuse.

## 6. Temporary object storage and future ESS

### 6.1 Port

`singularity_core` defines a storage port with operations equivalent to:

```text
stage
append_encrypted_chunk
seal_stage
stat_stage
finalize
abort_stage
stat
open
read_range
verify
delete
list_staged
```

Domain code uses `asset_id` and storage references. It never constructs storage
paths or ESS object keys.

### 6.2 Local filesystem adapter

`Singularity.Storage.LocalFilesystemAdapter` is the initial implementation.

Configuration:

```text
SINGULARITY_STORAGE_ROOT
```

The development default is a project-local ignored data directory. Production
must require an explicit durable path.

Layout:

```text
<root>/
├── staging/<stage_id>
└── objects/<vault_namespace>/<domain_namespace>/hmac-sha256/<prefix>/<lookup_digest>
```

Rules:

- Stage IDs and all path segments are server-generated and validated; original
  filenames never become paths.
- Reject symlinks and path traversal at every filesystem boundary.
- Stream uploads through the encryption codec without buffering the full file.
- Compute the plaintext SHA-256, vault-scoped lookup HMAC, and ciphertext
  SHA-256 while streaming.
- Flush and sync staged bytes before acknowledging the stage.
- Treat finalized objects as immutable.
- Use an atomic same-filesystem rename for finalization.
- Sync the final file and its parent directory before marking the object
  available.
- Deduplicate by verified digest within the vault/encryption domain.
- Never expose a cross-vault deduplication oracle.
- Verify ciphertext size and digest before reads are considered healthy.
- Garbage-collect abandoned stages and unreferenced finalized objects through
  idempotent jobs.

### 6.3 Envelope encryption and object identity

Each vault has a random vault key. Each initial `private` domain has a random
domain key wrapped by the active vault-key generation. Each canonical object has
a random 256-bit data-encryption key (DEK) wrapped by the active domain-key
generation.

Uploads use a versioned chunked AEAD format:

- AES-256-GCM from Erlang/OTP `:crypto`.
- A random 64-bit nonce prefix plus an unsigned 32-bit chunk counter forms each
  96-bit nonce using network byte order; counters cannot repeat for a DEK.
- Four MiB plaintext chunks, with a final shorter chunk allowed.
- Authenticated data binds the format version, vault ID, encryption-domain ID,
  object ID, chunk index, and plaintext chunk length.
- A small authenticated header records the format version, chunk size, nonce
  prefix, vault ID, encryption-domain ID, object ID, and algorithm. A final
  encrypted and authenticated record binds total plaintext size, chunk count,
  and plaintext SHA-256.

Domain-key generation belongs to the independently authenticated DEK wrapper,
not the immutable ciphertext header or chunk AAD. Rewrapping a DEK under a new
domain-key generation therefore changes only
`content.asset_key_envelopes`; it cannot require rewriting canonical object
bytes. A wrapper-generation mismatch fails before the DEK is released to the
chunk codec.

The clear header does not consume an AEAD nonce; its canonical byte encoding is
included in every record's associated data. Data chunks use counters
`0x00000000` through `0xFFFFFFFE`. Counter `0xFFFFFFFF` is reserved exclusively
for the final encrypted record. Sealing rejects a file whose chunk count would
enter the reserved counter, and the configured upload-size limit is enforced
before streaming. Format vectors assert that no header, data, or final record
can cause nonce reuse.

The plaintext SHA-256 is never stored in a queryable plaintext column. The
database stores:

```text
lookup_digest = HMAC-SHA-256(domain_dedup_key, plaintext_sha256)
ciphertext_hash = SHA-256(exact staged ciphertext bytes)
```

`domain_dedup_key` is a dedicated random 256-bit secret created once per
encryption domain and wrapped by the active domain-key generation. It is not
derived from or replaced with the rotating domain key. The raw plaintext hash
is retained only inside the authenticated encrypted object metadata.
Deduplication looks up
`(vault_id, encryption_domain_id, lookup_digest)` after the stream is sealed.
On a hit, the new stage and DEK envelope are destroyed and the logical asset
references the existing object. On a miss, the encrypted stage and its wrapped
DEK become the canonical object.

Reads require an unlocked vault. Runtime unwraps vault key → domain key → DEK,
verifies the header and each chunk tag, and never returns unauthenticated
plaintext. Range reads align to encrypted chunks internally and trim the
decrypted response to the authorized byte range.

Password change derives a new key-encryption key and rewraps only the active
vault key. Vault-key rotation rewraps domain keys. Domain-key rotation rewraps
object DEKs and the stable domain dedup key; lookup digests and canonical object
ciphertext do not change. Every wrapper records algorithm and key generation. A
failed rewrap leaves the previous generation active until all new wrappers
verify. Plaintext keys have bounded in-memory lifetimes and are overwritten on
a best-effort basis, but the design makes no false guarantee that BEAM binaries
can be deterministically zeroized.

Finalization and ciphertext integrity checks can run while a vault is locked.
Jobs that need plaintext, including metadata extraction, enter
`waiting_for_unlock` in their job progress and resume when the vault is next
unlocked; this is job progress, not an asset lifecycle state.

The metadata transition is resumable by job/effect identity. The first claim
persists the post-transition `processing_revision` and extractor checkpoint.
A retry by that same job while the asset is already `processing` receives the
persisted revision and checkpoint instead of attempting the stale
`available -> processing` transition again. Completion uses that persisted
processing revision. The begin/resume phase commits before extraction.
Extraction advances in bounded steps that commit each new checkpoint before
the next plaintext read, so a crash or unlock wait resumes from the last
durable checkpoint. A different or revoked job remains stale.

Plaintext jobs never receive a vault key, domain key, or DEK in their envelope.
They request a `KeyLease` from the runtime custodian using job ID, vault,
initiating principal, required capability, authorization epoch, and object key
generation. A lease is bound to one unlocked session, expires after 60 seconds,
and is revoked immediately on lock, logout, timeout, session revocation,
principal revocation, or authorization-epoch change.

The custodian keeps the key hierarchy internal and exposes only authenticated
chunk reads under the opaque lease reference. It revalidates the lease before
every chunk and never returns a wrapping key or DEK. Revocation cannot erase
plaintext already delivered to the extractor, but it prevents every subsequent
read and causes the job to return to `waiting_for_unlock`. Unlock wakes waiting
jobs for that vault; each job must acquire a new lease and resume from a
persisted, idempotent extractor checkpoint.

Revocation is custody-first. Lock, logout, timeout, session/principal
revocation, and membership/capability/epoch changes synchronously mark the
affected custody `revoking` and terminate matching leases before waiting for
the database advisory locks used to persist revocation and audit. A lease
therefore refuses the next chunk even when an already-running protected
operation still holds the shared authorization lock. If database persistence
fails, custody remains conservatively locked; key material is never
resurrected automatically. Self-revocation requires a resolved opaque session,
timeouts originate inside the custodian, and principal/vault-wide changes use
a scoped authorization preflight before touching custody plus an authoritative
recheck under the exclusive database lock.

### 6.4 ESS migration

`gsmlg-opt/ex_storage_service#5` tracks the embeddable Hex package.
Its recorded severity is `needed`, not `blocker`: the approved local adapter
allows this branch to complete without hiding the upstream gap.

The implementation callsite selecting the local adapter must include:

```elixir
# WORKAROUND(upstream): gsmlg-opt/ex_storage_service#5
```

When the package is available, add `EmbeddedESSAdapter` behind the existing port.
The domain schema, runtime workflows, and web API must not change. S3 remains the
remote/multi-node adapter.

## 7. Asset saga and state machine

The authoritative asset states and transitions are:

| From | To | Required evidence |
| --- | --- | --- |
| `staging` | `uploaded` | Grant consumed, encrypted stage sealed and synced, byte counts and ciphertext digest recorded |
| `uploaded` | `verified` | Stage format envelope is present and ciphertext size and digest match the sealed-stage record |
| `verified` | `available` | Canonical object finalized or an existing same-vault/domain object safely reused |
| `available` | `processing` | Technical-metadata job claimed with the expected asset revision |
| `processing` | `ready` | Supported metadata persisted and searchable projection updated |
| `ready` | `pending_delete` | Logical delete authorized, tombstone committed, live reference released |
| `staging` | `pending_delete` | Cancel or terminal failure authorized; stage release scheduled |
| `uploaded` | `pending_delete` | Logical delete authorized; sealed stage release scheduled |
| `verified` | `pending_delete` | Logical delete authorized; stage/object reference release scheduled |
| `available` | `pending_delete` | Same as above when the user deletes before metadata completes |
| `processing` | `pending_delete` | Same as above; extraction job becomes stale |
| `pending_delete` | `deleted` | Logical asset/resource deletion committed; projection cleanup acknowledged |

`state_revision` increments on every transition. Jobs carry their expected
revision and become a no-op when it is stale. Failure is orthogonal state stored
as `failure_code`, `retryable`, `failed_operation`, and `attempt`; it never
rewrites original bytes or invents a durable `failed` state. A retryable failure
leaves the asset in its last durable state and allows an idempotent retry. A
terminal failure remains inspectable until the owner deletes it.

Logical asset deletion and physical object cleanup are separate. A shared
`content.asset_objects` row is eligible for `orphan_pending` only after a
transaction proves that it has no live logical references. Its ciphertext moves
to `deleted` only after retention permits removal and a missing-object check is
recorded. The logical asset reaches `deleted` as soon as its tombstone,
projection cleanup, and reference release are committed; it does not wait for
physical cleanup. If another logical asset still references the object, the
canonical bytes remain available to that asset. If the object becomes orphaned,
retention and physical deletion continue as independently retryable cleanup
work in a separate `object_cleanup` job emitted by the logical-cleanup
transaction. Finalization and object cleanup serialize on the same per-object
session advisory lock, so a new reference cannot appear between the orphan
recheck and byte removal. Stale delete jobs cannot remove an object that gained
a new reference.

New-object workflow:

1. Runtime authorizes the unlocked principal, validates upload metadata, creates
   `staging` records, and issues a single-use grant.
2. Storage generates an object ID and DEK, streams encrypted chunks into a
   durable stage, computes protected digests, syncs the stage, and seals it.
3. A PostgreSQL transaction verifies that the already-consumed grant still
   matches its bound metadata, records the sealed stage and wrapped DEK,
   creates the local-upload source reference, advances the asset to `uploaded`,
   appends audit context, and inserts a verification outbox event.
4. The dispatcher submits a stable job envelope through `JobRunner`.
5. Verification advances `uploaded` to `verified`.
6. Finalization atomically moves the encrypted object or reuses a verified
   same-vault/domain object, then advances `verified` to `available`.
7. Metadata extraction decrypts only while the vault is unlocked, validates the
   supported file signature, persists typed technical metadata, updates the
   PostgreSQL metadata-search projection, and advances `processing` to `ready`.
8. Every transition transaction appends its audit and follow-up outbox records.

There is no PostgreSQL-filesystem distributed transaction. Recovery resumes
from persisted stage IDs and idempotency keys. Orphan collection handles stages
or objects that lose their database reference.

Duplicate bytes may create another logical resource/asset reference without
copying bytes. The API must not reveal whether a digest existed in another
vault.

Every imported resource version has provenance. The local-upload source
reference records source kind `browser_upload`, server-observed time, original
filename, declared media type, exact byte size, initiating principal, and a
digest of the client idempotency key. It never records a client filesystem path.

The initial resource classification is `private`. Asset, object, metadata,
search document, outbox/job envelope, audit target, backup entry, and any future
projection inherit that classification or a stricter one. Database constraints
and constructors reject a classification downgrade.

### 7.1 Technical metadata and search

The background extractor is intentionally narrow and deterministic:

- PDF: verify the `%PDF-` header and store the header version.
- JPEG: verify SOI plus a valid start-of-frame segment and store pixel width and
  height.
- PNG: verify the signature and IHDR chunk and store pixel width and height.
- All types: store detected media type, exact plaintext byte size, extractor
  version, and completion timestamp.

It does not extract PDF body text, page count, EXIF, thumbnails, OCR, captions,
or embeddings. Unsupported or malformed content records a stable terminal
metadata failure while preserving the authenticated canonical bytes for owner
inspection or deletion.

`singularity_retrieval` exposes a vault-scoped `AssetMetadataSearch` port backed
by the rebuildable `content.asset_search_documents` projection. A generated
`tsvector` using the `simple` configuration covers resource title and original
filename. `websearch_to_tsquery('simple', ...)` provides text search; detected
media type and lifecycle state are typed filters.
Results are ordered by text rank, then `updated_at DESC`, then stable asset ID,
and each result identifies its resource version. Empty queries return the same
authorized list ordered by update time. Search requires an unlocked vault,
applies capability checks before retrieval, and is protected by the same RLS
context as asset reads.

## 8. Outbox and durable jobs

`singularity_core` defines a `JobRunner` behaviour. The initial adapter is Oban,
but runtime workflows do not call Oban directly.

Domain changes and outbox events are written in the same Ecto transaction.

The dispatcher:

- Claims undelivered events with database locking.
- Converts each event into a versioned job envelope.
- Submits the envelope through `JobRunner`.
- Records the runner job ID.
- Marks delivery idempotently.
- Retries safely after crashes between submission and acknowledgement.

Job uniqueness is derived from the operation's idempotency key. Handlers must
remain idempotent even when runner-level uniqueness expires or fails.

Initial queues:

```text
asset_finalize
asset_verify
asset_metadata
asset_cleanup
object_cleanup
backup
maintenance
```

The core `JobEnvelope` is versioned and carries `job_id`, `job_type`,
`idempotency_key`, `vault_id`, initiating `principal_id`, required capability,
authorization epoch, classification, correlation ID, causation ID, expected
entity revision, attempt, and typed payload. The handler rechecks current
membership, capability, and revocation before any sensitive or destructive
effect.

`singularity_storage` owns a generic Oban worker and adapter, but it does not
depend on runtime. `singularity_core` defines a `JobHandler` callback. Runtime
injects `Singularity.Runtime.JobDispatcher` as that callback during composition.
The callback exposes an explicit, in-memory dependency bundle assembled by the
supervised runtime composition root; it includes the authoritative
authorization store and custodian. Storage treats the bundle as opaque, and it
is never serialized into an envelope. Authorization code has no hidden
application-environment or process-dictionary dependency accessors.
The generic worker validates and decodes the envelope, pins its locks and
worker connection, and passes the callback an explicit short scoped-transaction
capability. Runtime handlers define and commit phase boundaries around
external effects. Missing callback configuration or missing principal/vault
context fails closed.

The dispatcher discovers cross-vault outbox rows only through its audited claim
function. Each handler transaction uses the no-bypass worker role with
`SET LOCAL` context from the envelope. Maintenance work uses a named,
least-privilege system principal scoped to the specific vault and operation; it
does not impersonate the owner.

The generic worker pins one checked-out worker connection while it holds the
vault advisory lock and a shared principal/vault authorization lock. Each
handler phase establishes RLS context, reloads live authority, and commits its
database effect/acknowledgement. External work may occur between explicitly
committed phases while the locks and connection remain pinned. Session-bound
plaintext work additionally revalidates its session through KeyLease custody.
Handlers receive the scoped repository only inside the transaction capability
and must not switch to a request or dispatcher pool. Request mutations use the
same pattern through a request-operation scope. Cached session context and the
epoch copied into an envelope are identity hints and stale-work guards, never
authorization authority.

## 9. Authentication, vault keys, and authorization

### 9.1 Owner bootstrap

Bootstrap creates the owner person, account, principal, personal vault,
membership, initial capabilities, and key metadata atomically. Re-running
bootstrap is idempotent and cannot replace an existing owner credential.

Bootstrap accepts the password only through an interactive no-echo prompt or a
one-shot secret file descriptor. It never accepts a password in a command-line
argument. Authentication responses and timing-visible error categories do not
distinguish a missing account from an invalid credential. Per-account and
per-source rate limits apply before Argon2id work, and successful
authentication does not bypass the separate vault-unlock step.

Session issuance and its successful-authentication audit event are one scoped
database transaction: neither may commit without the other. Invalid and
unknown credentials take the same public path and record an anonymous failure
through the restricted pre-auth function. The HMAC fingerprint secret is a
dedicated production configuration value of at least 256 bits; startup fails
when it is missing or too short. The secret is used only to MAC a
normalized login and normalized source under separate domain labels, producing
independent rate-limit/audit fingerprints. It is never passed to persistence,
persisted, or logged. Password-bearing request values remain in runtime;
pre-auth and scoped persistence adapters receive only the normalized-login
lookup input and sanitized fingerprint/session-digest/audit commands.

### 9.2 Password and vault key

- Argon2id hashes the account password for authentication.
- An independent Argon2id derivation uses a distinct salt and domain separation
  to derive a key-encryption key from the same password.
- A cryptographically random vault key is wrapped with an authenticated
  encryption construction.
- Passwords, derived keys, and plaintext vault keys are never persisted or
  logged.

Use maintained cryptographic libraries and version the KDF and wrapping
parameters so they can be upgraded. Authentication and wrapping use independent
salts and domain labels. Changing the account password rehashes the credential,
derives a new wrapping KEK, verifies the old wrapper, and atomically replaces
the vault-key wrapper; it does not re-encrypt canonical objects.

There is no password-recovery back door in this branch. Losing both the account
password and the separately held encrypted-backup passphrase loses access to
the vault. The bootstrap and backup interfaces state this explicitly.

### 9.3 Unlocked sessions

- The signed cookie contains only an opaque session identifier.
- Unlocked vault keys live only in a runtime-owned, session-scoped in-memory
  key store.
- Unlock first creates a monitored, short-lived pending custody reference
  that cannot issue leases or wake jobs. The live authorization transaction
  and its unlock audit must commit before an after-commit callback atomically
  activates that reference while the same advisory locks are held.
- Transaction, audit, commit, or activation failure leaves no usable custody.
  Pending references expire and are discarded idempotently.
- The default inactivity timeout is 15 minutes and is configurable.
- Logout, timeout, revocation, or application restart locks the vault.
- Browser props never contain owner secrets, vault keys, or reusable API tokens.
- Plaintext-dependent jobs pause at `waiting_for_unlock`; unlocking publishes a
  bounded wake-up signal for that vault rather than placing keys in a job
  payload.

### 9.4 Authorization

Every operation evaluates:

- Principal.
- Vault membership.
- Required capability.
- Resource classification.
- Current vault-unlock state when the operation requires plaintext or key
  custody.

RLS is the final database guard, not a replacement for application capability
checks.

Authorization is re-evaluated at use time. An upload grant, outbox event, or job
created under an old authorization epoch cannot perform a sensitive effect
after the initiating principal is revoked.

Protected operations hold a session-level shared authorization lock keyed by
principal and vault through their last external effect and database
acknowledgement. Session revocation, membership/capability mutation, and epoch
changes close the custody gate first, then take the corresponding database
locks in the same order: vault first, authorization second. Therefore an
already-linearized non-plaintext operation may finish before revocation
commits, while plaintext work stops at its next lease read as soon as custody
enters `revoking`. No protected effect can overlap a committed revocation.
Unlock and key re-entry still perform live authorization with
`requires_unlocked = false`; only the operation that establishes custody may
waive the prior-unlock check. Object-specific finalization/cleanup locks, when
needed, are always acquired last.

## 10. Delete, backup, and restore

### 10.1 Logical deletion

Deletion:

1. Authorizes a destructive capability.
2. Creates a tombstone and audit event.
3. Marks the resource and asset references deleted.
4. Emits projection-cleanup and object-release events.
5. Physically removes bytes only after no live reference remains and retention
   permits cleanup.

Retrying deletion is idempotent.

### 10.2 Backup

A backup contains:

- A vault-scoped PostgreSQL logical export taken from a repeatable-read snapshot.
- Object-store inventory and immutable object bytes.
- Wrapped key metadata and key-generation identifiers.
- Integrity hashes.
- Included vault IDs.
- An authenticated consistency manifest with the snapshot ID, outbox high-water
  mark, and exact object inventory.

Every vault-mutating request and worker operation holds a session-level shared
vault advisory lock on a dedicated checked-out database connection for the
entire operation, including external filesystem effects and their following
database acknowledgement. The lock is released in an `after` path on every
result. Backup takes the corresponding exclusive lock, which waits for
in-flight handlers and cleanup to finish. New mutations block, and outbox claim
functions skip that vault while the exclusive lock is held. Backup then records
the snapshot and outbox cut, copies exactly the immutable objects referenced by
that snapshot, and releases the lock only after the manifest is sealed. Reads
may continue.

The entire backup bundle is encrypted and authenticated with a dedicated backup
key derived from an operator-supplied backup passphrase using independently
versioned Argon2id parameters. While the vault is unlocked, backup also creates
a recovery wrapper of the active vault key under a distinct key derived from
that backup key. That passphrase is never the account password, never persisted
by Singularity, and must be supplied out of band for restore. The manifest
authentication tag, verified with that external passphrase-derived key, is the
trust anchor. The backup path must not record plaintext passwords, vault keys,
domain keys, DEKs, or unencrypted database/object content.

Backup remains durable without persisting its passphrase or derived key.
Request-time setup stores only a pending-manifest identifier, KDF salt and
parameters, authenticated recovery-wrapper ciphertext, and an opaque
operation-bound key-lease reference. The derived backup key first enters
monitored pending custody that cannot encrypt or wake work. The
pending-manifest, audit, and outbox transaction must commit before an
after-commit callback activates the reference while the same locks remain
held. Transaction/audit/commit failure discards the pending key; activation
failure leaves the durable manifest waiting for re-entry but no usable key
capability. The activated key stays inside the runtime custodian, which exposes
streaming encryption operations but not the key. If a restart destroys that
lease, the job waits for the operator to re-enter the passphrase; runtime
derives the same key from the persisted salt, verifies the recovery wrapper,
prepares another inert reference, commits its replacement/audit, then activates
and wakes the job. Partial bundles are never accepted and are cleaned or
restarted idempotently.

### 10.3 Restore

Restore into an empty environment runs in maintenance mode with web mutations,
the outbox dispatcher, and workers disabled:

1. Derives the backup key from the supplied passphrase and authenticates the
   complete manifest before importing data.
2. Restores PostgreSQL, including wrapped key metadata, at the recorded snapshot
   and outbox cut.
3. Restores or attaches the exact encrypted object inventory.
4. Unwraps the recovery copy of the vault key, accepts a new owner password
   through a no-echo secret input, and atomically replaces the restored
   credential hash and vault-key wrapper without exposing the key in arguments
   or logs.
5. Verifies every ciphertext digest while still locked.
6. Reconciles pending outbox rows and jobs against restored asset/object states,
   discarding stale work and preserving only effects not reflected at the cut.
7. Unlocks the test vault, verifies authenticated plaintext for every referenced
   asset, rebuilds metadata search, and runs an integrity audit.
8. Enables dispatch and workers only after reconciliation succeeds.

A backup is not accepted until the automated restore test passes.

## 11. Phoenix, React App-Clip, and DuskmoonBundler

### 11.1 Routes

Initial routes:

```text
/login
/vault/unlock
/assets
/api/v1/uploads/:grant_id
/activity
/audit
/backups
/settings
```

The selected layout is the Vault Workbench:

- Persistent shell navigation.
- Vault-lock status and remaining inactivity time.
- Center asset workspace.
- Selection/inspection panel.
- Search by title or original filename, plus media-type and lifecycle filters.
- Explicit upload, verification, availability, processing, ready, failure, and
  deletion states.

The UI derives its presentation from the authoritative domain state:

| Domain state | Default UI label | Progress |
| --- | --- | --- |
| `staging` | Uploading | XHR bytes sent / expected bytes |
| `uploaded` | Verifying | Indeterminate until verification event |
| `verified` | Finalizing | Indeterminate until canonical object event |
| `available` | Available | Complete bytes; metadata not yet indexed |
| `processing` | Processing | Extractor step, or `Waiting for vault unlock` |
| `ready` | Ready | Complete and searchable |
| `pending_delete` | Deleting | Projection/object-release acknowledgements |
| `deleted` | Deleted | Hidden by default, visible in activity/audit |

When `failure_code` is present, the visible label becomes `Failed: <stable
message>` without changing the domain state. The retry action is enabled only
when `retryable` is true and submits the current `state_revision`.

### 11.2 Ownership seam

Phoenix LiveView owns:

- Authentication and session lifecycle.
- Vault unlock and lock.
- Navigation and page chrome.
- Authorization.
- Audit and backup pages.

React `AssetWorkspace` owns only the center workspace at `/assets`.

The placeholder uses:

```text
phx-hook="MountAssetWorkspace"
phx-update="ignore"
```

The hook:

- Creates one React root.
- Reads initial non-sensitive JSON props.
- Receives `asset:update` events and re-renders the existing root.
- Provides `pushEvent`, server-driven navigation, and upload functions through
  a bridge.
- Unmounts the React root in `destroyed()`.

`assets/js/hooks.js` exports and registers `MountAssetWorkspace`, and the
Phoenix `LiveSocket` receives that hooks object. The hook creates its root
before any asynchronous import and always calls `root.unmount()` from
`destroyed()`.

The seam is versioned and contains no reusable API credential:

| Channel | Name | Versioned payload/reply |
| --- | --- | --- |
| Initial Phoenix → React | `data-props` | `{version: 1, vault: {ref, locked, expiresAt}, assets: {items: AssetSummary[], nextCursor}, filters: {q, state, mediaType}, upload: {maxBytes, acceptedTypes}}` |
| Phoenix → React | `asset:snapshot` | `{version: 1, sequence, assets: {items: AssetSummary[], nextCursor}}` |
| Phoenix → React | `asset:update` | `{version: 1, sequence, asset: AssetSummary}` |
| React → Phoenix | `asset:search` | `{version: 1, q, state, mediaType}` → `{ok, sequence, filters, assets: {items, nextCursor}}` |
| React → Phoenix | `asset:page` | `{version: 1, cursor, q, state, mediaType}` → `{ok, sequence, assets: {items, nextCursor}}` |
| React → Phoenix | `upload:grant` | `{version: 1, filename, size, mediaType, idempotencyKey}` → `{ok, grantId, uploadToken, uploadUrl, expiresAt}` |
| React → Phoenix | `upload:cancel` | `{version: 1, grantId}` → `{ok: true, accepted: boolean}` |
| React → Phoenix | `asset:retry` | `{version: 1, assetId, stateRevision}` → `{ok, accepted}` |
| React → Phoenix | `asset:delete` | `{version: 1, assetId, stateRevision}` → `{ok, accepted}` |
| React → Phoenix | `navigate` | `{version: 1, to}` → `{ok}` |

`AssetSummary` is
`{id, resourceVersionId, title, originalFilename, detectedMediaType, state,
stateRevision, label, progress, failure, updatedAt}`. `failure` is `null` or
`{code, retryable, operation, attempt}`. Sequence and state revision are
monotonic integers; the client ignores stale events.

Search uses 50-result keyset pages. The opaque cursor encodes the last result's
rank, update timestamp, and asset ID and is signed by Phoenix. A search reply
replaces the list; an `asset:page` reply appends only results newer than the
client's current sequence and rejects a cursor whose filters do not match.

The LiveView subscribes to the vault asset topic only after the connected mount.
After LiveView reconnect it queries canonical PostgreSQL state and sends a full
`asset:snapshot`; React replaces its local list before applying later updates.
Navigation accepts only `/assets`, `/activity`, `/audit`, `/backups`, and
`/settings`, and LiveView performs `push_navigate/2`. Arbitrary client paths are
rejected.

### 11.3 Upload seam

React cannot send file bytes through `pushEvent`.

The upload flow is:

1. React requests a grant with `upload:grant`.
2. LiveView authorizes the unlocked session and persists a random, single-use
   grant bound to the session, principal, vault, object ID, filename, exact byte
   size, declared media type, idempotency key, authorization epoch, and a
   five-minute expiry. Only SHA-256 of the random 256-bit upload token is stored.
3. React uses `XMLHttpRequest` to `PUT /api/v1/uploads/:grant_id`, sends the
   token in `x-upload-token`, and sends the Phoenix CSRF token from the document
   meta tag in `x-csrf-token`. The same-origin session cookie remains
   `HttpOnly`, `Secure` in production, and `SameSite=Lax`.
4. The controller atomically marks the unused grant consumed before accepting
   bytes, rechecks the session, unlock state, authorization epoch, size, media
   type, expiry, CSRF token, `Content-Length`, and final streamed byte count, and
   streams the body into encrypted staging. The plaintext prefix is validated
   against the supported magic signature before the stage can be sealed.
5. `xhr.upload.onprogress` reports byte-transfer progress to React. PubSub and
   versioned `asset:update` events report server verification, finalization, and
   metadata progress.
6. After a valid grant, every terminal client result except HTTP `201` awaits
   one best-effort `upload:cancel` reply before the attempt completes or retry
   can request another grant. The version-1 cancellation payload contains only
   `grantId`; it never carries the upload token, session, principal, or vault.
7. AssetsLive accepts cancellation only for its one currently tracked pending
   grant and binds session, principal, and vault from `current_session`.
   Before replacing that grant it cancels the old one. It also schedules
   bounded best-effort cancellation just before the validated expiry and
   repeats the attempt during graceful `terminate/2` when a grant remains.
8. Storage row-locks the exact grant bound to that server-owned identity. In
   one transaction it cancels only an unconsumed grant, records
   `cancelled_at == retired_at`, tombstones and releases its staging asset,
   removes the search projection, and writes the audit/outbox effects. If PUT
   consumption won the race, the active upload-session abandonment path
   remains authoritative. Expired, cancelled, interrupted, or consumed grants
   are never resumed or reused; retry uses the same idempotency key and either
   returns the existing logical asset or creates one replacement stage.

Runtime represents the active PUT with an opaque, short-lived upload-session
handle. That process owns the checked-out request connection, live
authorization scope, shared vault and authorization advisory locks, encrypted
stage writer, and final database acknowledgement for the lifetime of the
stream. It first commits grant consumption and stage creation in a short scoped
transaction, streams outside a database transaction, then commits the sealed
stage acknowledgement in another scoped transaction. Grant consumption
therefore survives process/VM failure and the token cannot become reusable.
Phoenix retains the `Plug.Conn` and sends only chunks and the opaque handle to
runtime. The upload session monitors the controller, expires no later than the
grant, and abandons its stage idempotently on disconnect, timeout, or
cancellation. Its `after` path releases the writer, connection, and advisory
locks. Concurrency is bounded below RequestRepo capacity; excess uploads fail
before body reads so normal requests cannot be starved.

Accepted types are exactly `application/pdf`, `image/jpeg`, and `image/png`.
Magic-byte validation is authoritative; the declared type is only a hint. The
default maximum is 512 MiB through `SINGULARITY_MAX_UPLOAD_BYTES`.
Reusing an idempotency key with different filename, size, media type, principal,
or vault returns `conflict`.

The upload response contract is:

| Status | Stable result |
| --- | --- |
| `201` | `{ok: true, assetId, state: "uploaded", stateRevision}` |
| `400` | `invalid` |
| `401` | `unauthenticated` |
| `403` | `forbidden` or `vault_locked` |
| `409` | `conflict` for a consumed/revoked grant |
| `410` | `upload_expired` |
| `413` | `upload_too_large` |
| `415` | `unsupported_media_type` |
| `422` | `integrity_failure` |
| `503` | `storage_unavailable` |

The upload token and CSRF token are redacted from request logs, telemetry, error
reports, and audit metadata.

### 11.4 Asset toolchain

Use a named DuskmoonBundler profile, `:singularity_web`, consistently in config,
watchers, the development server, build tasks, and static-path helpers.

DuskmoonBundler owns:

- JavaScript and TypeScript bundling.
- React JSX.
- Tailwind.
- HMR.
- Production manifests and preload metadata.
- JS/TS formatting and linting.

The fixed web dependency declarations are:

```elixir
{:duskmoon_bundler_runtime, "~> 9.9.7"}
{:duskmoon_bundler, "~> 9.9.7", runtime: Mix.env() in [:dev, :test]}
{:floki, ">= 0.36.0", only: :test}
{:lazy_html, ">= 0.1.0"}
```

The runtime package starts in every environment. The bundler package remains
available in every environment, but its OTP application starts only in `:dev`
and `:test`. Floki remains test-only. LazyHTML deliberately has no `only`
restriction because DuskmoonBundler 9.9.7 declares it for every environment,
and Mix requires the direct dependency to use the same environment scope.

Use `mix npm.install` and commit `package.json` plus `package-lock.json`. Do not
add npm, yarn, or Bun workflows.

DuskmoonBundler is the asset toolchain, not a component library. This branch
uses project-owned semantic CSS variables for background, surface, text,
muted-text, border, accent, success, warning, danger, and focus colors. Light
and dark themes are selected at the shell's `data-theme` root; component code
uses semantic tokens rather than literal color classes.

The workbench must:

- Operate entirely by keyboard with visible focus.
- Use semantic landmarks and accessible names.
- Preserve logical focus when the inspection panel opens or closes.
- Collapse navigation and the inspection panel without horizontal overflow
  below 768 CSS pixels.
- Honor `prefers-reduced-motion` and never require animation to understand
  lifecycle progress.
- Meet WCAG AA contrast for text, controls, and focus indicators in both themes.

No additional DuskMoon UI component dependency is assumed by this design.

## 12. Errors, audit, and observability

Public boundaries return stable domain errors rather than Ecto, filesystem,
Oban, or Phoenix internals.

Initial error categories include:

```text
unauthenticated
vault_locked
forbidden
not_found
conflict
invalid
upload_expired
upload_too_large
unsupported_media_type
integrity_failure
storage_unavailable
job_failed
backup_invalid
```

Database constraints are the final race guard. Error responses must not reveal
cross-vault object existence, credential validity detail, filesystem paths, or
secret metadata.

Append-only audit records cover:

- Authentication and failed authentication.
- Denied authorization and cross-vault access.
- Vault unlock and lock.
- Upload and download.
- Integrity verification.
- Sensitive reads.
- Deletion and physical cleanup.
- Backup, restore, and integrity audit.
- Credential, key wrap/rewrap/rotation, capability, and policy changes.

Pre-authentication failures use `actor_kind = anonymous`, a keyed
non-reversible HMAC fingerprint of normalized login plus source under the
runtime audit-fingerprint secret, and `vault_id = NULL`; they never create a
principal. Known successful actors use principal and vault IDs, while
maintenance effects use the named system principal. The audit viewer renders
anonymous failures identically regardless of whether the login matched an
account.

Operational logs and audit records are separate. Logs contain correlation,
principal, vault, resource, asset, outbox, and job IDs where allowed, but never
raw sensitive content, credentials, tokens, keys, or full identifiers.

Telemetry covers upload bytes and latency, deduplication, stage age, integrity
failures, outbox lag, job retry/failure, authentication-audit write failures,
RLS denials, vault unlocks, backup duration, restore duration, and orphan
cleanup.

## 13. Testing strategy

### 13.1 Core

- Unit and property tests for identifiers, states, classifications,
  capabilities, versioning, and idempotency keys.
- Invalid transitions and privilege escalation attempts must fail.
- Encryption-format vectors cover header authentication, chunk ordering, nonce
  uniqueness, truncation, altered tags, wrong vault/domain/object associated
  data, wrapper-generation validation before codec invocation, reserved
  final-record counter, and chunk-count overflow.
- Password change, vault-key rotation, and domain-key rotation prove that the
  correct wrappers change while canonical ciphertext remains byte-for-byte
  unchanged.
- Uploading the same plaintext after domain-key rotation produces the same
  protected lookup digest and reuses the existing canonical object.

### 13.2 Storage contracts

Run the reusable object-storage contract against isolated temporary
directories:

- Streaming SHA-256.
- Chunked encryption and authenticated range reads.
- Same-vault/domain deduplication through protected lookup digests.
- Atomic finalization.
- Corruption detection.
- Abort and orphan cleanup.
- No cross-vault existence leak.
- No original-filename path use, symlink escape, or traversal.
- Final-file and parent-directory sync before availability acknowledgement.

The same contract will later apply to embedded ESS and S3 adapters.

### 13.3 PostgreSQL integration

Use the real `devenv` PostgreSQL service for:

- Migrations and constraints.
- RLS and vault scoping.
- Fail-closed missing context and pooled-connection context leakage.
- Pre-auth functions return fixed-shape candidate/session results, prevent table
  enumeration, and give unknown and invalid credentials indistinguishable
  external behavior.
- A two-vault fixture proving that request and worker roles cannot read,
  mutate, search, or infer the other vault's rows.
- Transactional domain plus outbox writes.
- Concurrent claims.
- Runner-submission crash recovery.
- Audit immutability.
- Bootstrap idempotency.
- Metadata search ranking, typed filters, stable pagination, and rebuild.
- End-to-end provenance and classification inheritance across resource version,
  asset, object, metadata, search document, job, audit, and backup entry.

### 13.4 Failure injection

Crash or fail at each saga boundary:

- During upload staging.
- After stage sync.
- Before PostgreSQL commit.
- After PostgreSQL commit.
- Before object finalization.
- After object finalization.
- Before asset-state acknowledgement.
- While metadata extraction waits for unlock.
- During an authenticated chunk read immediately before session lock or
  principal revocation.
- During deletion.
- During backup and restore.
- While a concurrent upload, metadata worker, or physical cleanup operation
  competes with the backup's exclusive vault lock.

Restart must converge without duplicate logical resources, lost references, or
untracked canonical bytes.

Key-lease tests prove that a waiting job wakes after unlock, receives only
authenticated plaintext chunks, resumes from its persisted checkpoint, and
returns to `waiting_for_unlock` without another chunk after lock, timeout,
session revocation, or authorization-epoch change. A paused-read race proves
the next chunk fails after custody enters `revoking` while database revocation
is still blocked on the exclusive authorization lock. Unlock failure injection
at transaction, audit, commit, and activation boundaries proves that no usable
custody, lease, or wake-up survives.

Backup concurrency tests prove the exclusive lock waits for an already-running
worker/cleanup effect, prevents new claims and mutations from entering the
manifest cut, and releases blocked work only after the manifest is sealed.
Backup-key setup failure injection proves transaction/audit/commit failures
leave no manifest or key capability, while activation failure leaves only the
durable `waiting_for_backup_key` manifest and no usable or orphaned custody.

The durable-job restart test records the Oban job ID, job state, outbox ID, and
domain effect count before terminating the application. After restart, the same
logical job reaches completion and the effect count is exactly one. A separate
injected crash immediately after runner submission but before outbox
acknowledgement must still produce one logical handler effect and one recorded
runner job identity.

### 13.5 Runtime and web

Runtime acceptance tests exercise:

```text
bootstrap
→ login
→ unlock
→ upload
→ verify
→ extract metadata
→ search
→ download
→ logical delete
→ cleanup
→ backup
→ restore
→ integrity audit
```

Phoenix tests cover sessions, CSRF, upload grants, authorization, locked-vault
redirects, and LiveView events.

App-Clip tests cover mount, initial props, live updates, bridge replies,
reconnect snapshot, stale-event rejection, allow-listed navigation, XHR upload
progress, cancellation, grant expiry/reuse, domain-to-UI lifecycle mapping, and
mandatory unmount.

A headless Chromium smoke test verifies the complete Vault Workbench workflow,
keyboard operation, visible focus, responsive layout at 767 and 1280 CSS
pixels, reduced-motion behavior, and both light and dark themes.

Security tests seed distinct canary values for password, audit-fingerprint
secret, upload token, CSRF token, vault key, domain key, DEK, and backup
passphrase. Password/key/passphrase/server-secret canaries must be absent from
structured logs, audit metadata, persistence-adapter arguments, rendered HTML,
`data-props`, LiveView payloads, controller JSON, and browser console output.
The upload token may appear only in its one grant callback and corresponding XHR
header. The CSRF token may appear only in the dedicated meta tag, Phoenix
LiveSocket connection parameter, Phoenix-generated `_csrf_token` hidden fields
on the same-origin login/unlock/logout controller forms, and the same-origin
upload request header. The LiveSocket and hidden-field occurrences are
framework transport, not application events or server-pushed payloads. Both
ephemeral-token canaries must be absent from every log, audit record,
server-pushed event, `data-props`, controller JSON/application payload, and
console message.

Audit acceptance asserts one immutable event for each enumerated sensitive
operation in section 12, including denied authentication/authorization,
download, delete, physical cleanup, backup, restore, capability change, and key
rewrap. Each event must have operation, result, correlation ID, timestamp, and
redacted target reference. It must also have either principal plus vault, named
system principal plus vault, or anonymous fingerprint with a null vault under
the exact pre-authentication rule above.

### 13.6 Verification gates

`mix singularity.test.integration` is a project task that creates a unique
temporary PostgreSQL database, applies every migration, allocates a temporary
storage root, runs the tagged PostgreSQL/storage/job suite, and drops both on
success. `mix singularity.test.restore` creates a source database/root and a
separate empty destination database/root, performs the encrypted one-vault
backup and maintenance-mode restore, then asserts exact equality of live
resource, version, asset, object, metadata, and tombstone counts; the restored
source audit count plus exactly `backup.restore_completed`,
`credential.rewrapped_after_restore`, and `integrity.audit_completed`; exact
manifest inventory count; every ciphertext hash; every decrypted asset hash;
zero unreconciled stale jobs; and equivalent search results.

Both tasks refuse to use a non-test database and print the randomly generated
database names and storage roots. They run against the real PostgreSQL service
inside `devenv`, never an in-memory substitute.

Every milestone commit runs:

```text
mix deps.get
mix deps.unlock --check-unused
mix format --check-formatted
mix compile --warnings-as-errors
scoped tests
architecture dependency tests
mix xref graph --format cycles --fail-above 0
git diff --check
```

PostgreSQL, storage, outbox, and restore milestones additionally run:

```text
devenv shell -- mix singularity.test.integration
devenv shell -- mix singularity.test.restore
```

The web/toolchain milestone additionally runs:

```text
mix npm.install --frozen
mix npm.verify
mix duskmoon_bundler.js.check
mix npm.run test:js
mix duskmoon_bundler.build singularity_web --tailwind
devenv shell -- mix npm.run test:e2e
```

`test:js` runs Vitest in deterministic single-run mode. `test:e2e` runs
Playwright against the Chromium binary supplied by `devenv`; package lifecycle
scripts and `npx playwright install` are not used. The final branch gate runs
the entire `mix test` suite after every scoped suite passes. If an out-of-scope
test fails, implementation stops and reports it rather than changing unrelated
behavior.

## 14. Implementation sequence on one branch

The implementation uses one feature branch and one `.trees` worktree. Each gate
produces a conventional commit.

1. Documentation and ADR baseline.
2. Seven-app umbrella restructuring and architecture tests.
3. PostgreSQL, Ecto, least-privilege roles, RLS, migrations, and `devenv`.
4. Core identity, vault, resource, asset, state-machine, and port contracts.
5. Key hierarchy, chunked AEAD codec, protected object identity, and rotation.
6. Local filesystem storage contract and adapter.
7. Transactional outbox, job-runner/handler ports, injected Oban adapter, and
   scoped worker context.
8. Owner bootstrap, authentication, vault unlock, capabilities, and audit.
9. Upload, verify, finalize, download, delete, and cleanup workflows.
10. Background technical-metadata extraction and PostgreSQL metadata search.
11. Encrypted backup, maintenance-mode restore, reconciliation, and integrity
    audit.
12. Phoenix shell, DuskmoonBundler profile, and Vault Workbench App-Clip.
13. Browser acceptance workflow and final full verification.

No later step begins until the scoped tests and checklist for its current step
pass.

## 15. Completion criteria

The branch is complete only when:

1. The exact seven-app graph is mechanically enforced.
2. A clean environment starts reproducibly with PostgreSQL and local encrypted
   object storage.
3. A persisted job retains its recorded ID across restart and produces exactly
   one logical domain effect.
4. A crash after runner submission but before outbox acknowledgement produces
   exactly one logical handler effect.
5. The owner can log in and unlock the personal vault.
6. A PDF, JPEG, or PNG can be streamed, encrypted, hashed, deduplicated,
   persisted, authenticated, and downloaded only while unlocked; plaintext
   workers cannot read another chunk after their key lease is revoked.
7. Interrupted uploads and finalization converge or fail with a stable,
   inspectable error; stages are later collected.
8. Duplicate uploads within one vault/domain do not duplicate canonical
   ciphertext, while a second vault receives no existence signal.
9. Logical deletion creates a tombstone before physical cleanup.
10. PDF/JPEG/PNG technical metadata is extracted by a durable background job,
    and the resulting resource version is found through authorized PostgreSQL
    metadata search; provenance exists and no derived record lowers the source
    classification.
11. Every operation enumerated in section 12 is authorized and has the required
    immutable audit event, including denied operations.
12. Two-vault and pooled-connection tests prove RLS blocks cross-vault request,
    worker, and search access and fails closed without context.
13. Seeded secret canaries satisfy the exact absence and ephemeral-token
    allow-list assertions in section 13.5.
14. A separately encrypted one-vault backup restores into an empty destination
    with exact row/object/manifest counts and no stale destructive job replay;
    concurrent mutation/cleanup tests prove the manifest cut is stable.
15. Restored ciphertext and unlocked plaintext pass integrity audit, and rebuilt
    metadata search returns equivalent results.
16. The Vault Workbench implements the exact lifecycle mapping, ignores stale
    revisions, and enables retry only for retryable failures.
17. JS unit tests and the headless Chromium complete-workflow test pass in
    addition to scoped Elixir/integration/restore tests.
18. All scoped and full verification gates pass without ESS, S3, Qdrant,
    Backplane, or external model calls.
