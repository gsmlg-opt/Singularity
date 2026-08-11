# Singularity Architecture and Implementation Guide

**Status:** Draft v0.1
**Product type:** Personal Data and Knowledge Operating System
**Initial deployment:** Single owner, multiple devices, local-first
**Primary stack assumptions:** Elixir/Phoenix, PostgreSQL, embedded/S3-compatible ESS

---

## 1. Executive summary

Singularity is the canonical home for a person’s digital data:

* Notes and documents
* Photos and personal videos
* Movies, television series, music, books, and viewing history
* News, Wiki, YouTube, and other subscriptions
* Financial accounts, transactions, holdings, and market observations
* Medical documents, encounters, medications, and health observations
* Personal entities, relationships, annotations, and timelines

It is not merely a knowledge base. Its more precise role is:

> A local-first, searchable, auditable, and privacy-preserving personal data operating system.

The foundational storage decision is:

```text
PostgreSQL
  Canonical structured data, state, relationships, permissions, and metadata

ESS
  Canonical binary content: photos, videos, PDFs, source snapshots, and attachments

Derived projections
  Search indexes, embeddings, OCR, thumbnails, summaries, transcodes, and recommendations
```

PostgreSQL and ESS contain authoritative data. Every other representation must be rebuildable.

---

# 2. Architecture principles

## 2.1 Canonical data versus projections

Canonical data includes:

* Original imported files
* User-authored content
* Normalized domain records
* Resource versions
* Explicit user relationships
* Authentication and authorization state
* Source provenance

Derived projections include:

* BM25 indexes
* Embeddings
* OCR text
* Thumbnails and previews
* HLS segments
* Summaries
* Extracted entities
* Inferred graph relationships
* Recommendations

A projection must always point back to the exact source version from which it was generated.

```text
Resource Version
    ├── Search document
    ├── OCR output
    ├── Embedding
    ├── Thumbnail
    ├── Summary
    └── Inferred relationships
```

Deleting or superseding a source version must invalidate its projections.

---

## 2.2 Raw first, normalized second

External or imported data should normally pass through two layers:

```text
Original source
    ↓
Immutable raw representation
    ↓
Normalized domain model
```

For example, a bank statement produces:

```text
PDF statement in ESS
    ↓
Statement resource version
    ↓
Extracted financial transactions in PostgreSQL
```

A medical report produces:

```text
Original PDF in ESS
    ↓
Medical document resource
    ↓
Structured encounters and observations
```

This allows parsing logic to be improved and rerun without fetching or asking for the original data again.

---

## 2.3 Typed domains, not one universal JSON table

Do not model the entire system as:

```text
items(id, type, data_json)
```

That design is flexible during initial ingestion but weak for:

* Constraints
* Referential integrity
* Precise queries
* Migration safety
* Access control
* Financial correctness
* Medical units
* Time-series aggregation

Use typed domain tables for stable, query-critical fields. Use `jsonb` only for:

* Provider-specific metadata
* Rarely queried optional fields
* Raw normalized extension data
* Forward compatibility during connector development

---

## 2.4 Immutable source material

Original files and imported snapshots should be immutable.

An edit creates a new resource version:

```text
Resource
├── Version 1
├── Version 2
└── Version 3
```

This is especially important for:

* Medical records
* Financial statements
* Photos
* News snapshots
* Wiki revisions
* Legal documents
* Movie and media files

Mutable application state, such as tags or playback progress, can remain mutable.

---

## 2.5 Modular monolith before services

The initial system should be a modular monolith:

```text
One deployable application
├── Identity and vault
├── Content
├── Photos
├── Media
├── Finance
├── Health
├── Subscriptions
├── Ingestion
├── Search
└── Web/API
```

Modules should communicate through explicit context APIs and persisted events, not through arbitrary cross-table access.

Split a module into an independently deployed service only when it has a concrete reason:

* Independent scaling
* Different availability requirements
* Process isolation
* Hardware-specific deployment
* Operational ownership
* Incompatible runtime dependencies

FFmpeg media processing and a Rust Tantivy indexer may run as local worker processes without turning the complete application into microservices.

---

# 3. System context

```text
┌─────────────────────────────────────────────────────────────┐
│ Clients                                                     │
│ Web · Desktop · Mobile · CLI · TV                           │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│ Singularity Application                                     │
│                                                             │
│ Identity · Vault · Policy · Audit                           │
│ Notes · Documents · Photos · Media                          │
│ Finance · Health · Subscriptions · Library                  │
│ Ingestion · Search · Timeline · Agents                      │
└───────────────┬────────────────┬────────────────────────────┘
                │                │
                ▼                ▼
        ┌──────────────┐   ┌──────────────┐
        │ PostgreSQL   │   │ ESS          │
        │ Structured   │   │ Binary       │
        │ canonical    │   │ canonical    │
        └──────┬───────┘   └──────┬───────┘
               │                  │
               └────────┬─────────┘
                        ▼
           ┌──────────────────────────┐
           │ Projection workers       │
           │ Search · OCR · Media     │
           │ Embedding · Summaries    │
           └──────────────────────────┘
```

External sources include:

```text
Local filesystem
Photo libraries
RSS and news feeds
Wiki revisions
YouTube metadata
Book and movie catalogs
Music catalogs
Financial institutions
Market data providers
Medical exports
```

---

# 4. Core domain language

The system should use a small set of cross-domain concepts.

## 4.1 Person

A real-world person represented in the personal data model.

The owner is a `Person`, but other people may also exist:

* Family members
* Doctors
* Authors
* Actors
* Contacts
* People detected in photos

A person is not the same thing as a login account.

---

## 4.2 Account

An authentication identity.

An account is responsible for:

* Authentication
* Recovery
* Account state
* Credential management
* Linking the owner to the application

The initial installation may contain only one owner account.

---

## 4.3 Principal

An actor that can perform an operation.

Principal types include:

```text
owner
device
agent
background_job
connector
administrator
```

Examples:

* The owner opening a medical record
* A phone uploading photos
* A finance agent calculating monthly spending
* A worker creating a thumbnail
* An RSS connector importing an article

Authorization should be evaluated against principals, not only users.

---

## 4.4 Vault

A data ownership, policy, and encryption boundary.

Initial configuration:

```text
One owner
One personal vault
Multiple devices
Multiple internal principals
```

Future configurations may contain:

* Personal vault
* Family vault
* Work vault
* Archived vault

Most user-owned records should contain `vault_id`.

A vault is more stable and useful than adding `user_id` to every table.

---

## 4.5 Entity

A stable real-world or conceptual identity.

Examples:

* NVIDIA
* NASDAQ:NVDA
* Christopher Nolan
* Interstellar
* A hospital
* A medication
* A book
* A YouTube channel

Entities can have aliases and external identifiers.

---

## 4.6 Resource

An addressable content item.

Examples:

* A note
* A news article
* A PDF
* A Wiki page
* A YouTube video
* A medical report
* A bank statement
* A movie file
* A photograph

Resources can have multiple immutable versions.

---

## 4.7 Asset

A binary object stored by ESS.

Examples:

* Original photo
* PDF bytes
* MKV movie
* Subtitle file
* Poster image
* Thumbnail
* Audio track
* Raw provider response

A resource may reference multiple assets.

```text
Movie Resource
├── Original MKV asset
├── Poster asset
├── Subtitle asset
├── Preview asset
└── Transcoded asset
```

---

## 4.8 Event

Something that happened at a particular time.

Examples:

* Payment
* Purchase
* Medical encounter
* Medication taken
* Movie watched
* File imported
* Account opened
* Asset acquired

---

## 4.9 Observation

A value measured or observed at a particular time.

Examples:

* Stock price
* Account balance
* Blood pressure
* Weight
* Lab result
* Asset valuation
* YouTube view count

An observation is different from a document and should not be modeled as text.

---

## 4.10 Annotation

User-created context attached to another object.

Examples:

* Note
* Highlight
* Rating
* Review
* Comment
* Bookmark
* Tag
* Reading progress
* Viewing state

A standalone note is a resource. A note attached to a movie or document is also an annotation relationship.

---

## 4.11 Subscription

A persistent instruction to monitor a source or topic.

Examples:

* Follow an RSS feed
* Follow NVIDIA news
* Track NVDA prices
* Watch a YouTube channel
* Monitor a Wiki page
* Follow an author’s new books
* Follow a director’s new films

---

# 5. Application boundaries

A practical Elixir umbrella structure is:

```text
apps/
├── singularity_core
├── singularity_storage
├── singularity_domains
├── singularity_ingest
├── singularity_retrieval
└── singularity_web
```

## 5.1 `singularity_core`

Owns cross-domain concepts:

* Person
* Account
* Principal
* Device
* Vault
* Policy
* Entity
* Resource
* ResourceVersion
* Asset metadata
* Relationship
* Classification
* Audit event
* Domain event
* Shared ports and behaviours

It should not depend on individual domains such as Finance or Photos.

---

## 5.2 `singularity_storage`

Owns infrastructure adapters:

* PostgreSQL repository configuration
* ESS native adapter
* S3 adapter
* Encryption adapter
* Local cache manager
* Object lifecycle
* Backup manifests

Application logic should depend on storage behaviours, not ESS internals or a particular S3 SDK.

---

## 5.3 `singularity_domains`

Contains domain contexts:

```text
Notes
Documents
Photos
Media
Finance
Health
Library
Subscriptions
Timeline
```

Initially, these contexts can live in one OTP application. A domain should only become a separate application when it acquires substantial independent complexity.

---

## 5.4 `singularity_ingest`

Owns:

* Connector scheduling
* File imports
* Photo synchronization
* External source checkpoints
* Raw payload preservation
* Normalization
* Identity resolution
* Deduplication
* Import state machines
* Retry and dead-letter handling

---

## 5.5 `singularity_retrieval`

Owns rebuildable retrieval projections:

* PostgreSQL full-text retrieval
* Tantivy BM25 adapter
* Exact and prefix matching
* Facets
* OCR index
* Semantic retrieval
* Fusion
* Reranking
* Search authorization

---

## 5.6 `singularity_web`

Owns:

* Phoenix endpoints
* LiveView
* JSON API
* Authentication sessions
* Device-pairing endpoints
* Presigned upload endpoints
* Playback endpoints
* User interface composition

It must not contain domain rules.

---

# 6. PostgreSQL organization

Recommended logical schemas:

```text
identity
core
content
ingest
photos
media
finance
health
subscriptions
retrieval
audit
```

Database schemas help organization, but they are not sufficient security boundaries by themselves.

## 6.1 Identity tables

```text
identity.people
identity.accounts
identity.credentials
identity.principals
identity.devices
identity.device_keys
identity.sessions
```

Credentials should be separated from ordinary person profile data.

---

## 6.2 Vault and policy tables

```text
core.vaults
core.vault_members
core.capabilities
core.principal_capabilities
core.data_classifications
core.key_domains
```

Even in single-owner mode, this structure allows devices and agents to receive constrained access.

---

## 6.3 Content tables

```text
content.entities
content.entity_aliases
content.external_identifiers

content.resources
content.resource_versions
content.assets
content.resource_assets

content.relationships
content.annotations
content.tags
content.resource_tags
content.source_references
```

Suggested resource fields include:

```text
id
vault_id
kind
title
classification
current_version_id
created_at
updated_at
deleted_at
```

Suggested resource version fields include:

```text
id
resource_id
version_number
content_asset_id
structured_content
source_observed_at
ingested_at
created_by_principal_id
```

Suggested asset fields include:

```text
id
vault_id
ess_object_id
ess_object_version
content_hash
ciphertext_hash
size
media_type
classification
encryption_domain
state
created_at
verified_at
deleted_at
```

---

## 6.4 Provenance

Every imported record should retain provenance:

```text
source_id
external_id
external_revision
source_uri
fetched_at
observed_at
parser_version
normalizer_version
```

For extracted facts, retain the source version and extraction location:

```text
source_resource_version_id
page_number
text_range
confidence
extractor_version
```

This enables citations and safe reprocessing.

---

## 6.5 Time semantics

Do not use one ambiguous timestamp for every purpose.

Use distinct concepts:

* `occurred_at`: when an event happened
* `observed_at`: when a measurement was made
* `published_at`: when content was published
* `fetched_at`: when a connector retrieved it
* `ingested_at`: when Singularity stored it
* `created_at`: when the database record was created
* `updated_at`: when mutable state changed

Store timestamps in UTC while retaining original timezone information where meaningful.

---

## 6.6 Domain correctness rules

Financial values:

* Never use floating point.
* Store exact decimal values and currency.
* Keep original source amounts and normalized amounts separately.

Medical observations:

* Store value, unit, reference range, observation time, and provenance.
* Preserve source units even when normalized units are generated.
* Never rely solely on extracted text or embeddings for medical facts.

External identifiers:

* Store the source namespace explicitly.
* Do not assume IDs from different providers are globally unique.

---

# 7. ESS architecture

ESS is both:

1. An embeddable native storage engine
2. An S3-compatible remote interface

The application should support both through one storage port.

```text
StoragePort
├── EmbeddedESSAdapter
└── S3Adapter
```

## 7.1 Native ESS capabilities

The embedded adapter may expose capabilities beyond S3:

```text
put
put_if_absent
stat
open
read_at
verify
materialize_local
prefetch
pin
release
stage
commit_reference
abort_stage
```

These enable:

* Instant deduplication
* Content-addressed storage
* Local zero-copy access
* Fine-grained integrity checks
* Efficient FFmpeg materialization
* Reference accounting
* Storage compaction

---

## 7.2 S3 capabilities

The remote adapter should use standard operations:

```text
PutObject
GetObject
HeadObject
DeleteObject
Range requests
Multipart upload
Presigned uploads
Presigned downloads
Object versioning
Checksums
```

Do not wrap S3 in another network protocol unless a native ESS capability genuinely cannot be expressed through S3.

---

## 7.3 Object identity

The domain should use `asset_id`, not object keys, as its stable identity.

ESS object keys are storage details.

A possible object namespace is:

```text
vault/{vault_id}/objects/{algorithm}/{prefix}/{digest}
```

For privacy, cross-vault deduplication must not expose whether another vault already owns the same object.

A safer design is:

* Deduplicate within a vault or encryption domain.
* Derive the externally stored digest using a vault-scoped HMAC.
* Keep raw plaintext hashes protected.
* Never reveal cross-user deduplication hits through APIs.

---

## 7.4 Instant save semantics

“Instant save” can mean two different things.

### Existing object

When the content already exists in ESS:

```text
hash lookup
→ existing object found
→ create a new logical reference
→ no data copy
```

This can be effectively immediate.

### New object

For a completely new large video, ESS still has to read the bytes or receive a trusted content manifest.

The application can make the item appear immediately:

```text
create pending resource
→ stream and hash in background
→ finalize asset
→ mark resource ready
```

But the physical data is not fully durable until verification completes.

The UI should distinguish:

```text
pending
uploading
verifying
ready
failed
```

---

## 7.5 Object lifecycle

Use an explicit state machine:

```text
staging
→ uploaded
→ verified
→ available
→ processing
→ ready
→ pending_delete
→ deleted
```

Do not attempt a distributed transaction between PostgreSQL and ESS.

Recommended commit sequence:

```text
1. Stage object in ESS
2. Compute and verify checksums
3. Begin PostgreSQL transaction
4. Create resource version and asset metadata
5. Insert outbox events
6. Commit PostgreSQL transaction
7. Commit or pin the ESS reference
8. Clean abandoned staging objects asynchronously
```

Every step must be idempotent.

---

# 8. Asynchronous processing and consistency

Use a PostgreSQL-backed durable job system.

Important job classes include:

```text
ingest
metadata
thumbnail
ocr
search_index
embedding
media_probe
media_transcode
subscription_fetch
maintenance
garbage_collection
```

## 8.1 Transactional outbox

Domain changes and background work should be committed in one PostgreSQL transaction:

```text
Domain record update
+
Outbox event
```

A dispatcher later converts outbox events into jobs.

This avoids:

```text
Database committed
but job was never scheduled
```

---

## 8.2 Idempotency

Every external operation should have an idempotency key.

Examples:

```text
source + external_id + source_revision
asset + projection_type + projection_version
subscription + scheduled_window
resource_version + extractor_version
```

Retrying a job must not produce duplicate resources or assets.

---

## 8.3 Failure isolation

A projection failure must not corrupt canonical data.

Examples:

* OCR failure does not invalidate a PDF.
* Embedding failure does not invalidate a note.
* Transcoding failure does not invalidate the original movie.
* Search indexing failure leaves the source available for direct access.

---

# 9. Ingestion architecture

All connectors should follow a common lifecycle:

```text
discover
→ fetch
→ preserve raw source
→ normalize
→ resolve identity
→ deduplicate
→ persist canonical state
→ enrich
→ index
→ notify
```

## 9.1 Connector behaviours

Conceptual connector categories:

```text
DocumentSource
CatalogSource
ObservationSource
MediaSource
SubscriptionSource
```

Examples:

| Source              | Connector category                  |
| ------------------- | ----------------------------------- |
| RSS article         | DocumentSource                      |
| Wiki revision       | SubscriptionSource + DocumentSource |
| Stock quote         | ObservationSource                   |
| Movie metadata      | CatalogSource                       |
| Local photo library | MediaSource                         |
| YouTube channel     | SubscriptionSource + CatalogSource  |
| Bank statement      | DocumentSource + domain extractor   |

---

## 9.2 Connector checkpoints

Each connector should maintain:

* Last successful cursor
* Last attempted cursor
* Remote revision or ETag
* Rate-limit state
* Failure count
* Backoff state
* Last complete synchronization time

A failed item should not necessarily block later items.

---

## 9.3 Identity resolution

External records should first enter as source-specific identities.

For example:

```text
TMDB movie 157336
IMDb title tt0816692
Local filename Interstellar.mkv
```

Identity resolution may merge these references into one movie entity.

Automatic merges should be reversible and should store:

* Matching evidence
* Resolver version
* Confidence
* Merge author
* Timestamp

---

# 10. Search and retrieval

Search is a pipeline, not one database operation.

```text
Query
→ authorization scope
→ structured filters
→ exact lookup
→ lexical retrieval
→ optional semantic retrieval
→ fusion
→ reranking
→ final policy check
→ results with provenance
```

## 10.1 Initial implementation

Start with PostgreSQL:

* Exact identifiers
* Prefix matching
* Trigram matching
* PostgreSQL full-text search
* Structured filters
* Domain-specific queries

This minimizes infrastructure during the early data-model phase.

---

## 10.2 Tantivy projection

Introduce Tantivy when:

* Corpus size grows
* BM25 ranking needs better control
* Chinese tokenization needs dedicated configuration
* Facets become important
* Search latency becomes difficult to maintain in PostgreSQL

Tantivy should be accessed through a retrieval port:

```text
LexicalRetriever
├── PostgreSQLLexicalRetriever
└── TantivyLexicalRetriever
```

The Tantivy index remains disposable and rebuildable.

For titles and identifiers:

```text
exact match
> phrase match
> title BM25
> body BM25
> semantic similarity
```

Semantic retrieval should supplement lexical retrieval, not replace it.

---

## 10.3 Sensitive search domains

Sensitive data must not automatically enter a global index.

Recommended index separation:

```text
general
private
finance
health
restricted
```

Rules:

| Classification |            Global search |      Semantic index |        Agent access |
| -------------- | -----------------------: | ------------------: | ------------------: |
| Public         |                      Yes |             Allowed |   Policy-controlled |
| Private        |       After vault unlock |            Optional | Explicit capability |
| Sensitive      |       Domain search only | Disabled by default |   Narrow capability |
| Restricted     | Exact, dedicated UI only |                  No | Normally prohibited |

Policy filtering should happen before candidate retrieval whenever possible. Filtering only after retrieval can still leak counts, timing, or snippets.

---

# 11. Photo library

Photos are first-class domain objects, not merely generic attachments.

Recommended model:

```text
photos
photo_assets
albums
album_photos
photo_sources
photo_variants
photo_metadata
photo_locations
photo_people
photo_edits
```

## 11.1 Import pipeline

```text
discover source asset
→ read source identifier
→ quick fingerprint
→ EXIF extraction
→ strong hash
→ ESS deduplication/upload
→ create photo record
→ generate thumbnail and preview
→ optional OCR
→ optional image embedding
```

Original assets remain immutable.

Edited photos create:

* New edit instructions
* New derived preview
* Optionally a new exported asset

They do not overwrite the original.

---

## 11.2 Synchronization identity

Keep distinct identifiers:

```text
photo_id
source_library_id
source_asset_id
ess_object_id
content_hash
```

File paths are not identities because files can be renamed or moved.

---

## 11.3 Deletion

Use tombstones:

```text
active
→ missing_from_source
→ deleted_from_source
→ pending_purge
→ purged
```

A deleted photo must not reappear merely because another device has an old copy.

Tombstones should remain until all relevant devices have advanced beyond the deletion event or the retention period expires.

---

## 11.4 Sensitive photo metadata

The following should be treated as sensitive:

* GPS coordinates
* Face embeddings
* People clusters
* Home and workplace inference
* Screenshots containing account or medical data

Face recognition and location analysis should be local-only by default.

---

# 12. Video and Jellyfin-like media

Movies and television belong in a dedicated Media domain.

Recommended model:

```text
media_items
movies
series
seasons
episodes
media_editions
media_files
media_streams
subtitle_tracks
artwork
playback_states
watch_events
media_collections
```

## 12.1 Storage strategy

```text
ESS
  Authoritative original media and durable derivatives

Local NVMe cache
  Hot media, local materializations, and seek-heavy access

Transcode workspace
  Temporary FFmpeg input and output
```

S3-compatible storage is suitable as authoritative object storage. It is not ideal as a direct POSIX replacement for seek-heavy FFmpeg workloads.

The embedded ESS adapter should support:

```text
read_at
prefetch
materialize_local
open_local_handle
pin
release
```

---

## 12.2 Playback decision

```text
Playback request
    ↓
Client capability check
    ├── Compatible codecs/container → Direct Play
    ├── Compatible codecs, wrong container → Remux
    └── Incompatible codecs/bitrate → Transcode
```

### Direct Play

Serve byte ranges from:

1. Local cache when available
2. ESS range reads otherwise

### Remux

Change the container without re-encoding.

### Transcode

Decode and re-encode using FFmpeg, optionally with hardware acceleration later.

---

## 12.3 Recommended initial Jellyfin integration

Do not immediately rebuild the complete Jellyfin ecosystem.

Introduce a playback abstraction:

```text
MediaPlaybackPort
├── JellyfinAdapter
└── NativePlaybackAdapter
```

Initially:

* Singularity owns media identity, metadata, ESS assets, and user relationships.
* Jellyfin may provide playback, transcoding, and existing clients.
* ESS materializes or exposes a controlled media view for Jellyfin.
* Playback progress can be synchronized back into Singularity.

Later, Native Playback can replace parts of Jellyfin incrementally.

---

# 13. Finance domain

Finance is a structured domain, not a collection of searchable statements.

Recommended tables:

```text
financial_accounts
financial_institutions
financial_transactions
transaction_postings
merchants
categories
bills
assets
liabilities
securities
holdings
orders
market_observations
account_balance_observations
financial_documents
reconciliation_runs
```

A transaction should link to its source:

```text
Transaction
├── account
├── amount and currency
├── merchant
├── occurred_at
├── category
├── source statement
└── extraction provenance
```

Rules:

* Never use floating point for money.
* Keep source currency and normalized currency separate.
* Imported transactions require deterministic deduplication.
* Extracted transactions may remain `unverified` until reviewed.
* Full account identifiers should be encrypted.
* Global search should show masked identifiers only.

Market observations can initially remain in PostgreSQL and be partitioned when volume justifies it.

---

# 14. Health domain

Health records require typed structures and a stronger security boundary.

Recommended model:

```text
health_providers
health_encounters
health_conditions
health_medications
health_medication_events
health_observations
health_lab_results
health_vaccinations
health_documents
health_claims
```

A medical encounter might contain:

```text
Encounter
├── provider
├── occurred_at
├── source document
├── diagnoses
├── medications
└── observations
```

Rules:

* Original medical documents remain immutable.
* Extracted values require source citations.
* Units and reference ranges are mandatory where applicable.
* Automatic extraction must retain confidence and parser version.
* LLM access is disabled by default.
* Medical search runs in a separate policy and encryption domain.

The application must clearly distinguish:

```text
Source fact
User annotation
Machine inference
```

An inferred condition must never silently become an authoritative diagnosis.

---

# 15. Identity and security architecture

## 15.1 Separation of concerns

```text
Person
  Real-world identity and personal profile

Account
  Authentication and recovery

Principal
  Actor performing an operation

Vault
  Ownership and policy boundary
```

This separation avoids mixing medical profile data with password or device credentials.

---

## 15.2 Data classifications

Use four initial levels:

```text
public
private
sensitive
restricted
```

Examples:

| Level      | Examples                                          |
| ---------- | ------------------------------------------------- |
| Public     | Public Wiki and catalog metadata                  |
| Private    | Notes, photos, watch history                      |
| Sensitive  | Finance and health                                |
| Restricted | Credentials, identity documents, recovery secrets |

Every resource, asset, projection, and audit operation inherits or increases the classification of its source.

A summary of a medical document is still medical data. An embedding of a private note is still private.

---

## 15.3 Encryption hierarchy

Recommended conceptual hierarchy:

```text
Owner unlock secret or hardware-backed key
    ↓
Vault key
    ↓
Domain key
    ├── private
    ├── photos
    ├── finance
    ├── health
    └── identity
        ↓
Per-record or per-object data encryption key
```

Benefits:

* One compromised domain key does not expose every domain.
* A finance agent can receive access to finance-derived data without receiving the health key.
* Key rotation can happen by domain.
* Restricted data can require an additional unlock step.

---

## 15.4 Database access

Use:

* Non-superuser runtime database role
* PostgreSQL row-level security
* Vault-scoped queries
* Application-level capability checks
* Separate administrative migration role

Do not run the application using a role that bypasses row-level security.

Schema separation alone is not a sufficient security mechanism.

---

## 15.5 Capability model

Capabilities should be narrow and purpose-specific.

Examples:

```text
read:photos
write:photos
read:finance:transactions
read:finance:summary
read:health:documents
export:vault
manage:devices
media:transcode
```

An agent analyzing spending may receive:

```text
transaction date
merchant category
amount
currency
```

It does not need:

```text
full account number
medical data
identity documents
photo library
```

---

## 15.6 Audit

Sensitive actions should produce append-only audit records:

```text
principal
action
target
purpose
capability
timestamp
device
result
request correlation ID
```

Audit:

* Reads of sensitive and restricted data
* Decryption
* Export
* Agent access
* Device pairing
* Key changes
* Permission changes
* Destructive deletion

Supported final JSON records originating from
`Singularity.Runtime.Observability.LoggerMetadata.log/3` must not contain raw
medical text, account numbers, access tokens, or decrypted secrets.

---

# 16. Device synchronization

Even a single-owner system needs explicit device identity.

## 16.1 Device model

Each device should have:

* Device ID
* Public key
* Pairing state
* Last synchronization cursor
* Capabilities
* Revocation state
* Last-seen time

Device pairing should establish encrypted trust without sharing a reusable account password.

---

## 16.2 Change stream

Use a durable change log, not full event sourcing:

```text
vault_changes
- sequence
- vault_id
- aggregate_type
- aggregate_id
- operation
- version
- classification
- occurred_at
```

Devices pull changes after their last acknowledged sequence.

---

## 16.3 Conflict strategy

Different data types require different policies.

### Immutable assets

No conflict. Multiple versions may coexist.

### Notes

Use optimistic versioning. On incompatible concurrent edits:

```text
preserve both versions
→ create conflict state
→ allow merge
```

### Tags and collections

Use set-oriented merge rules where possible.

### Finance and health

Never silently merge conflicting structured records. Preserve both source records and require reconciliation.

### Deletion

Propagate tombstones. Do not physically delete until synchronization retention requirements are satisfied.

---

# 17. User-facing information architecture

The application should present one coherent shell without pretending every domain is identical.

Recommended top-level navigation:

```text
Home
Inbox
Search
Timeline
Notes
Documents
Photos
Media
Library
Subscriptions
Finance
Health
Vault
```

## 17.1 Home

Shows:

* Recent personal activity
* New subscription items
* Pending imports
* Upcoming bills
* Recent photos
* Continue watching
* Important health or finance notices

Sensitive cards may require an explicit vault unlock.

---

## 17.2 Inbox

All newly ingested items enter an inbox state:

```text
new
reviewed
archived
ignored
```

This prevents subscriptions and imports from flooding the permanent knowledge organization.

---

## 17.3 Global search

Global search should search safe domains by default.

Finance and health are explicitly enabled through domain filters or a separate unlocked search mode.

---

## 17.4 Timeline

The timeline unifies events without flattening their domain semantics:

```text
Photo captured
Article published
Transaction occurred
Movie watched
Medical encounter
Note edited
Asset valuation observed
```

Each entry links back to its typed domain object.

---

# 18. Deployment modes

## 18.1 Local development

```text
Phoenix
PostgreSQL
Embedded ESS
Local workers
PostgreSQL search
```

Everything may run on one machine.

---

## 18.2 Personal server

```text
Phoenix application
PostgreSQL
ESS embedded or local service
Worker processes
Local NVMe media cache
Optional Tantivy process
Optional Jellyfin
```

This is the recommended initial production topology.

---

## 18.3 Multiple application nodes

When multiple application nodes are introduced:

* Do not let several processes independently mutate the same embedded ESS store unless ESS explicitly supports it.
* Run ESS as a service through its S3 endpoint or native remote protocol.
* Coordinate jobs through PostgreSQL.
* Keep media caches node-local.
* Route or lease transcode jobs explicitly.

The embedded adapter is ideal for single-node deployments. S3 service mode is the safer multi-node boundary.

---

# 19. Observability

Only application-owned `[:singularity, ...]` events, final JSON records
originating from `Singularity.Runtime.Observability.LoggerMetadata.log/3`, and
immutable audit records are supported observability surfaces. The logging
boundary default-denies fields in both its structured message and metadata,
then uses the configured `LoggerJSON` formatter and
`Singularity.Runtime.Observability.Redactor` to format and redact the admitted
record.

Free-form Logger messages, OTP and crash reports, dependency or framework logs,
and the combined raw Logger output stream are unsupported and must be treated
as sensitive. Selected `capture_log` and request-log checks are defense in depth
only; they do not expand the supported logging surface. Reporters and exporters
consume Singularity metrics and events only. Supported reporters, exporters,
and persistence handlers do not subscribe to raw Thousand Island, Bandit, Plug,
Phoenix, Phoenix LiveView, Oban, Ecto, or other dependency events; those events
remain unsupported and must be treated as sensitive data.

Runtime telemetry uses numeric measurements and bounded redacted metadata. The
explicit Oban adapter may derive safe Singularity events from allow-listed job
events without promoting the raw source event to the supported contract.

Supported Singularity telemetry should include:

## Ingestion

* Items discovered
* Import latency
* Failed imports
* Connector lag
* Retry count
* Duplicate rate

## ESS

* Bytes stored
* Deduplication ratio
* Verification failures
* Orphan staging objects
* Cache hit rate
* Materialization latency

## Search

* Query latency
* Index lag
* Candidate count
* Zero-result rate
* Projection failures

## Media

* Direct-play percentage
* Remux percentage
* Transcode percentage
* Transcode queue length
* Cache misses
* Playback failures

## Security

* Failed authentication
* Device revocation
* Sensitive reads
* Denied capability checks
* Export events
* Key rotation failures

Operational logging and security auditing should be separate systems, even when both are stored in PostgreSQL.

---

# 20. Backup and recovery

Canonical data requiring backup:

```text
PostgreSQL
ESS objects
Encryption key metadata
Encrypted key backups
Source connector checkpoints
```

Rebuildable data that may be excluded:

```text
Tantivy indexes
Embeddings
Thumbnails
OCR text
Summaries
Temporary HLS
Local cache
Transcode workspace
```

A backup should produce a consistency manifest containing:

* Backup identifier
* PostgreSQL recovery point
* ESS object versions
* Encryption key generation
* Integrity hashes
* Included vaults
* Creation timestamp

Recovery order:

```text
1. Restore key material
2. Restore PostgreSQL
3. Restore or attach ESS objects
4. Verify referenced assets
5. Rebuild projections
6. Resume connectors
7. Run integrity audit
```

Backups are not considered valid until a test restore succeeds.

---

# 21. Implementation roadmap

## Milestone 0 — Foundation

Implement:

* Architecture decision records
* Umbrella application
* PostgreSQL repository
* Migrations
* Job system
* Outbox
* Structured application logging through `LoggerMetadata.log/3`
* Basic metrics
* Development environment

Required decisions:

```text
PostgreSQL is canonical structured storage
ESS is canonical binary storage
Vault is the ownership boundary
Modular monolith is the initial architecture
Projections are rebuildable
No distributed transaction with ESS
```

### Completion criteria

* Application starts reproducibly.
* Database migrations are automated.
* Jobs survive process restarts.
* Outbox delivery is idempotent.

---

## Milestone 1 — Identity, vault, and assets

Implement:

* Person
* Account
* Principal
* Device
* Vault
* Classification
* ESS embedded adapter
* S3 adapter
* Asset state machine
* Audit events

Complete one vertical workflow:

```text
unlock vault
→ upload file
→ ESS stage
→ verify
→ PostgreSQL commit
→ download
→ logical delete
→ physical cleanup
```

### Completion criteria

* Duplicate upload creates a reference without duplicating bytes.
* Interrupted upload can resume or cleanly fail.
* Orphan staging objects are collected.
* Sensitive operations are audited.
* Backup and restore of one vault succeeds.

---

## Milestone 2 — Notes and documents

Implement:

* Markdown notes
* Resource versions
* Attachments
* Tags
* Relationships
* PDF import
* Text extraction
* PostgreSQL lexical search
* Citations

### Completion criteria

* Every search result points to a resource version.
* Editing creates deterministic version history.
* Deleting a document invalidates its projections.
* Notes and documents export without proprietary lock-in.

---

## Milestone 3 — Photo library

Implement:

* Device photo source
* Incremental synchronization
* EXIF extraction
* Content-hash deduplication
* Thumbnail and preview jobs
* Albums
* Timeline
* Tombstones
* Optional OCR

### Completion criteria

* Rename or move does not duplicate a photo.
* Deletion does not resurrect on another device.
* Original photo remains unchanged.
* Thumbnail loss can be recovered by rebuilding.

---

## Milestone 4 — Personal video and media library

Implement:

* Video ingestion
* FFprobe metadata
* Movie and television model
* Tracks and subtitles
* Posters
* Playback progress
* HTTP range streaming
* Local cache
* ESS materialization
* Jellyfin adapter or basic native playback

### Completion criteria

* Compatible media direct-plays.
* Seek-heavy playback uses local cache where needed.
* Interrupted playback resumes correctly.
* Original media survives transcode failure.

---

## Milestone 5 — External subscriptions

Implement:

* RSS/news
* Wiki revision monitoring
* YouTube channel metadata
* Book, movie, and music catalog updates
* Subscription scheduling
* Inbox
* Deduplication
* Notifications or digest generation

### Completion criteria

* Connector restart does not duplicate items.
* Source checkpoints are recoverable.
* Raw source and normalized item retain provenance.
* One failing feed does not block other subscriptions.

---

## Milestone 6 — Finance

Implement:

* Accounts
* Transactions
* Statements
* Bills
* Assets and liabilities
* Holdings
* Market observations
* Reconciliation
* Finance encryption domain
* Finance-specific audit and search

### Completion criteria

* No floating-point monetary arithmetic.
* Duplicate statement imports do not duplicate transactions.
* Account identifiers are encrypted or masked.
* Agent access can be restricted to aggregate values.

---

## Milestone 7 — Health

Implement:

* Providers
* Encounters
* Documents
* Medications
* Observations
* Lab results
* Health encryption domain
* Provenance-aware extraction
* Health-specific search

### Completion criteria

* Every extracted value cites its source.
* Machine inference is visually distinct from source facts.
* Global search excludes health data by default.
* Health exports include original documents and structured records.

---

## Milestone 8 — Advanced retrieval and agents

Implement:

* Tantivy BM25
* Chinese tokenizer
* Semantic retrieval
* Result fusion
* Entity extraction
* Inferred relationships
* Summaries
* Scoped agent tools
* Cross-domain questions

### Completion criteria

* All projections can be rebuilt.
* Agent requests are capability-scoped.
* Finance and health never enter LLM context implicitly.
* Search results preserve classification and provenance.

---

# 22. Cross-cutting invariants

The following rules should be enforced throughout development:

1. **Every user-owned object belongs to a vault.**
2. **Every actor is a principal.**
3. **Every asset is immutable.**
4. **Every imported record retains provenance.**
5. **Every projection points to a source version.**
6. **Every background operation is idempotent.**
7. **Every destructive action creates a tombstone before physical deletion.**
8. **Every sensitive read is authorized and auditable.**
9. **No sensitive data is admitted to supported final JSON records originating
   from `LoggerMetadata.log/3`.**
10. **No agent receives unrestricted database access.**
11. **No domain uses floating point for monetary or clinical values.**
12. **No search index becomes the source of truth.**
13. **No PostgreSQL–ESS operation assumes distributed ACID.**
14. **No universal JSON object replaces typed domain models.**
15. **No derived data has a lower security classification than its source.**

---

# 23. Initial architecture decision records

Create these files under `docs/adr/`:

```text
ADR-001-postgresql-as-canonical-structured-store.md
ADR-002-ess-as-canonical-binary-store.md
ADR-003-vault-as-ownership-boundary.md
ADR-004-modular-monolith.md
ADR-005-rebuildable-projections.md
ADR-006-embedded-and-s3-ess-adapters.md
ADR-007-no-distributed-transactions.md
ADR-008-data-classification-and-key-domains.md
ADR-009-principal-and-capability-model.md
ADR-010-resource-versioning.md
ADR-011-ingestion-provenance.md
ADR-012-media-cache-and-materialization.md
ADR-013-sensitive-search-isolation.md
ADR-014-jellyfin-as-initial-playback-adapter.md
```

---

# 24. First implementation target

The first release should not attempt photos, movies, finance, health, subscriptions, and AI simultaneously.

Build this complete vertical slice first:

```text
Owner account
→ Vault unlock
→ Import one PDF or photo
→ ESS deduplicated storage
→ PostgreSQL resource and version
→ Background metadata extraction
→ Search
→ Authorized download
→ Logical deletion
→ Projection cleanup
→ Audit
→ Backup and restore
```

Once this workflow is reliable, every new domain becomes an extension of the same foundation rather than another storage system.

The core architecture can therefore be summarized as:

```text
Singularity
  Personal data semantics and user experience

PostgreSQL
  Structured canonical truth

ESS
  Immutable binary truth

Workers
  Idempotent processing

Indexes
  Rebuildable retrieval projections

Vault and capabilities
  Privacy and authorization boundary
```

