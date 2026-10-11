# Singularity v0.2 Phase 5: portable export, logical V3, restore, and upgrade

Status: REVIEWED FOR IMPLEMENTATION — coordinator self-review and independent
SPEC followed by separate fresh QUALITY review have closed. Phase 5 remains
IN PROGRESS; this document is not implementation acceptance. The reviewed
snapshots and bounded corrections are recorded in the Phase 5 report.

Date: 2026-10-11. Governing requirements: release plan §10 and Phase 5,
`2026-08-31-singularity-v0.2-release-design.md`, and current root `AGENTS.md`.
Continuous development authority permits choosing the recommended in-scope
design and preparing its plan without another routine approval request.

## 1. Baseline, scope, and fixed boundaries

The assigned worktree is `.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`, initially clean at
`5f7e6363be534dbfb4dfa1475538fddcbd29cf32`. The coordinator identifies
`42c01a5c99b1df3d1e4284d277c6ea48046875cb` as the accepted Phase 4 tested
implementation source; the later handoff is documentation only. This design
does not reproduce or extend that verification evidence.

Deliver portable Markdown, retained originals, extracted text, and documented
non-secret JSON; write logical backup V3; restore V1/V2/V3; reconstruct unified
search; prove a historical 0.1 database upgrades and produces restorable V3.
Include all canonical history, conflicts, tombstones, organization, and exact
source pins in V3. Portable export has the explicitly narrower selection in §4.

Preserve seven applications, zero xref cycles, immutable IDs and provenance,
the PostgreSQL canonical/Asset object storage split, and Runtime.Api as the
only web boundary. No dependencies, new applications, external services,
browser features, production activation/backfill, merge, push, version bump,
tag, release, or deployment. E2E remains manual-only and NOT RUN under the
user's deferral; final browser/release acceptance remains outstanding.
New canonical writes remain unavailable to production runtime roles.

Vault, cryptography, key lifecycle, custody, capabilities, policy semantics,
and their tests/UX remain frozen. Prefer implementation entirely through
existing Storage backup adapter seams plus new knowledge-export modules.
Keep `Runtime.BackupVault`, `Runtime.RestoreVault`, `DownloadLease`,
`KeyCustodian`, `RestoreIntegrityLease`, and cryptographic formats unchanged.
If source characterization proves a frozen-substrate file unavoidable, first
document the individual compatibility requirement and obtain independent
review; this design does not authorize new frozen semantics.

## 2. Evidence and selected approach

These are inspected source facts at the baseline, not claims of V3 behavior:

| Source | Consequence |
| --- | --- |
| `storage/backup/logical_schema_v2.ex` | V2 has 30 tables/280 columns; V1 has its separate immutable schema. |
| `storage/backup/exporter.ex: snapshot_cut/2, records/2, object_inventory/2`; `runtime/backup_vault.ex: export transaction` | One repeatable-read cut owns lazy logical/object consumption; current inventory only includes available objects referenced by nondeleted/nonpending-delete Assets. |
| `20260922000050_document_source_pin_count.exs` | Every Document version retains its object, including historical/deleted Documents. |
| `storage/backup/restorer.ex: stream_pending_import/7, verify_migration_authority/1, destination_tables/0` | Import uses a serializable transaction, exact migration-session authority, destination locks, pending/imported saga, and object cleanup; destination table list currently uses V2 plus exclusions/seals. |
| `runtime/restore_vault.ex: run/2, restore_rewrapped/3` | Import, existing rewrap, ciphertext/plaintext verification, reconciliation, and completion are successive saga stages, not one transaction. |
| `20260906000100_create_document_aggregate.exs: enforce_document_source`; `20260906000200_create_document_fragments_and_lifecycle.exs: enforce_document_fragment` | Live Asset admission and the ready-fragment seal prevent naive historical row insertion. |
| `20261011000000_seal_note_source_sets.exs: enforce_note_source_set`; `20261011000200_knowledge_asset_lifecycle_guards.exs` | Live/retained-parent source and organization admission need a distinct historical restore contract; source-set seals are derived. |
| `storage/backup/integrity_audit.ex: rebuild_locked`; `storage/backup/reconciler.ex: event_job_type/1` | Existing audit rebuild covers Assets/Notes; Document projections and durable-work reconciliation must be added. |
| `runtime/documents/read.ex: download_original/3`; `20260922000250_document_custody_binding.exs` | Existing request custody can bind an exact Document version but denies a tombstoned Document; public read currently selects its head. |
| `runtime/notes/export.ex`; `core/note_markdown_sources.ex` | Existing ordinary Markdown rendering is reusable, but its logical source paths do not mean source files have been exported. |

Paths in this table abbreviate `apps/singularity_storage/lib/singularity/`,
`apps/singularity_runtime/lib/singularity/`, `apps/singularity_core/lib/singularity/`,
or the Storage migration directory as appropriate.

Considered alternatives:

1. **Recommended: two output contracts, one canonical source model.** A readable
   portable directory and an additive logical V3 use exact version pins. V3
   has maintenance-only historical admission plus complete structural
   validation. This preserves established backup encryption and runtime source
   authorization, at the cost of explicit restore validation and staging.
2. Replay runtime create/save/import commands. This reuses live admission, but
   changes IDs, revisions, historical tombstone behavior and extraction state;
   it cannot reproduce immutable history. Reject.
3. Database dump or disabled triggers with an all-history portable copy. A dump
   is schema-coupled and not the established logical contract. Disabled
   triggers weaken integrity; all-history deleted-byte access crosses frozen
   custody boundaries. Reject.

## 3. Ownership and interfaces

Core owns pure portable descriptor validation, safe path construction,
canonical ordering, closure rules, and Markdown source rendering. It receives
values and yields values/iodata, never SQL, filesystem paths, keys, or leases.

Storage owns `Backup.LogicalSchemaV3`, codec/version dispatch, repeatable-read
queries, graph preflight, historical import, original-object inventory,
maintenance admission SQL, reconciliation and projection rebuild. New
`KnowledgeExport.Repository` reads authenticated canonical metadata. New
`KnowledgeExport.Writer` creates private files and incrementally writes JSON
and byte streams. It receives authenticated plaintext chunks, never key
material or encrypted-envelope state.

Runtime owns `Knowledge.Export`: authenticate current session, derive owner,
build the selected version closure, acquire existing exact-binding read
adapters, materialize and verify files, reauthorize before delivery, cancel and
clean up. The public contract is:

- `Runtime.Api.export_knowledge(session, %{include_tombstones: boolean})`:
  returns an opaque export handle only after complete artifact verification.
  Omitted option defaults to false; reject unknown keys, caller owner scope,
  requested filesystem destinations, arbitrary paths, and caller adapters.
- `Runtime.Api.knowledge_export_entries(session, handle, cursor)` returns a
  bounded page of relative path/media type/size/SHA-256 descriptors.
- `Runtime.Api.read_knowledge_export_chunk(session, handle, path, index)` reads
  only a manifest-listed file by validated ordinal chunk; authorize handle
  ownership and the current session before each call.
- `Runtime.Api.close_knowledge_export(session, handle)` is idempotent for its
  owning session and releases the temporary artifact.

The handle is an opaque runtime artifact identifier bound to the original
session, principal, owner, and authorization epochs. It is not a new key or
custody capability. Entries expose no host path. Browser download/archive UI
belongs to Phase 6; Phase 5 tests materialize the returned entries as the
documented directory. Existing single-Note export remains compatible.

Selection and each delivery require the existing read authorizations needed
by the selected kinds, including current Note read and original Asset read
authority. The owning session must remain unlocked and unrevoked; possession
of a handle is insufficient. No new export capability or Vault grant is added.

Use existing supervision for bounded temporary tasks; add no domain GenServer
or durable export queue. A process owns each private staging directory and
monitors its requester only during generation. Before replying with a verified
handle, transfer ownership to a supervised artifact owner under the existing
supervision and drop the generation-request monitor. A short-lived request
ending after completion must not invalidate its session-bound handle.
Requester death before completion
aborts generation; afterward session close/revocation, expiry or owner restart
controls cleanup. Maximum handle lifetime is 15 minutes from creation;
expiry/cancel/session revocation closes delivery and removes owned staging.
Restart cleanup only removes recognizable export-owned directories below the
dedicated export staging root; it never walks arbitrary user paths.

## 4. Portable selection and exact source closure

One export selects all live Note and Document heads in the authenticated owner
scope, plus live Asset resources needed by source references. Standalone Asset
library export is not added. Include all tags assigned to selected resources,
their assignments, and relationships with at least one selected endpoint.
Other endpoints receive owner-authorized metadata descriptors; those
descriptors do not themselves expand relationship traversal or body/history
selection. A pinned relationship includes its exact target-version descriptor;
other metadata endpoints include their head descriptor when they have one.

Starting from each selected Note version, traverse its sealed attachments and
citations. Add exact live Note target versions and recursively their source
sets; exact live Document versions with their fragments/originals; and exact
live Asset version bindings. Deduplicate by `(kind, resource_id, version_id)`;
mark a key visited before traversing it so cycles terminate. Process the
frontier in lexicographic `(kind, resource_id, version_id)` order. Never follow
an updated head in place of a pin. Two versions of one Document produce two
version-addressed entries even if their original bytes deduplicate internally.

The manifest includes every selected version and every referenced endpoint;
no dangling implicit reference or successful truncation is allowed. Note
parent/merge IDs are historical provenance, not source-file links: include
their recursively deduplicated metadata-only version descriptors without
selecting ancestor bodies or their source sets. Apply the same total bounds.
An exact
deleted/unavailable source already referenced by a live Note receives the
existing authorized resolver's metadata and, for a citation, its permitted
selected-fragment description. Its `availability` explains why no file is
present. Metadata access never authorizes an original/body download.

`include_tombstones: true` additionally includes owner-scoped deleted-resource
metadata, immutable version descriptors, and relevant edge/source metadata.
It does not export tombstoned Note bodies or Document originals. This is the
release plan's optional tombstone state, not an undelete or deleted-binary
recovery feature. No new all-history selector is introduced. Unselected
conflict branches and otherwise unreferenced history belong to complete V3.

Missing bytes for a selected live Document or otherwise admitted live source,
bad digests, ambiguous Asset/version bindings, authorization denial/expiry,
or a resource becoming unavailable during execution fail the whole operation.
Only sources already classified as metadata-only by the authorized selection
contract may have unavailable descriptors. An I/O or authorization error must
never be converted into a successful metadata-only export.

Capture metadata and head choices in one authenticated repeatable-read
transaction, streaming a private spool. Consume the snapshot before returning
the connection; binary transfer then uses immutable captured pins and current
authorization. Selected live bytes must still be authorized at transfer and
completion. Changes after the cut cannot alter the selected version, tags, or
source sets; deletion/revocation that prevents access aborts the artifact.
Do not hold a metadata transaction open through client delivery.

For exact Document originals, add a knowledge read adapter that selects the
specified version and reuses the existing request `document_source` custody
binding and DownloadLease protocol unchanged. Require a live Document, exact
owner/version/object/size/digest and supported storage format. A source Asset
may have been deleted while the live Document retains the original. Do not
use worker/extraction identity or RestoreIntegrityLease for export. For Asset
pins, prove the unique exact resource-version/Asset/object association before
calling established live Asset download; reject ambiguous or changed binding.
Use its bounded chunk-delivery path, never the eager `:all` bytes variant.
Revalidate the captured version/Asset/object/size/digest binding before lease
creation and completion; authenticate each chunk through the existing delivery
contract. No DownloadLease or custody implementation change is authorized.

## 5. Portable files and manifest version 1

The output tree contains:

```text
notes/<resource-uuid>--<version-uuid>.md
documents/originals/<resource-uuid>--<version-uuid>.<ext>
documents/extracted/<resource-uuid>--<version-uuid>.txt
assets/<resource-uuid>--<version-uuid>.bin
manifest.json
```

Document extensions are the fixed media-type mapping PDF→`pdf`,
Markdown→`md`, plain text→`txt`. UUID-only basename components avoid title
collisions, path traversal, Unicode normalization and platform-reserved names.
Use `/` in manifest paths; reject absolute paths, `..`, separators inside IDs,
NUL, symlinks, duplicate paths, and case-fold collisions. Never overwrite an
existing destination or follow caller-supplied paths.

Markdown is UTF-8 canonical Note text plus ordinary source links/footnotes
generated by `NoteMarkdownSources` with actual relative file paths. Preserve
body content; escape source labels and Markdown destinations correctly.
Add `NoteMarkdownSources.render_portable/3` for the validated exact-version
file map and unavailable-source descriptions. Preserve existing `render/2`
bytes, fixed logical `sources/...` path validation and text-only wording;
portable output must not change the established single-Note export contract.
Footnotes contain title, resource/version identity, locator, and unavailable
reason where applicable. A deleted source has readable metadata, not a link
that falsely suggests an exported original exists. Canonical Note body digest
and rendered-file digest are distinct fields. Exported `.txt` concatenates
canonical fragment text in ordinal order with **no added delimiter**, matching
the existing extracted-text digest. Manifest fragment offsets are UTF-8 byte
offsets into this file. Non-ready Documents have an original and explicit
state, with no fabricated extracted text.

The exact top-level manifest keys are `format`, `version`, `selection`,
`resources`, `versions`, `fragments`, `tags`, `tag_assignments`, `relationships`,
`attachments`, `citations`, and `files`. `format` is
`singularity.portable-knowledge`; `version` is integer `1`; `selection` has
`mode: "live_heads_with_source_closure"` and `include_tombstones`. Arrays use
stable identity ordering, except source/fragment arrays also order by parent
version and ordinal. JSON is UTF-8 with integer ordinals, lowercase canonical
UUIDs, lowercase 64-character SHA-256 hex and UTC microsecond timestamps;
nullable fields use JSON null. No wall-clock export timestamp is required,
allowing byte-stable output for an identical snapshot.

| Array | Required record fields |
| --- | --- |
| resources | `id`, `kind`, `title`, `current_version_id`, `deleted_at`, `selection_reason` (`head`, `source`, `relationship_endpoint`, `tombstone`) |
| versions | `resource_id`, `version_id`, `revision`, `kind`, `inserted_at`, `availability` (`included`, `metadata_only_deleted`, `metadata_only_unavailable`, `metadata_only_unselected`), `body_path`, `original_path`, `extracted_path`, `body_digest`, `original_digest`, `original_byte_size`, `extracted_digest`, `media_type`, `state`, `extraction_adapter`, `extraction_format`, `parent_version_id`, `merge_parent_version_id` |
| fragments | `id`, `resource_id`, `version_id`, `ordinal`, `digest`, `locator`, `extracted_path`, `start_byte`, `byte_size`; metadata-only citations use null offsets/path and the already-authorized readable locator |
| tags | `id`, `display_value`, `normalized_key` |
| tag_assignments | `resource_id`, `tag_id` |
| relationships | `id`, `source_resource_id`, `target_resource_id`, nullable `target_version_id`, `type` |
| attachments | `note_resource_id`, `note_version_id`, `id`, `ordinal`, `target_resource_id`, `target_version_id`, `target_kind`, `role`, nullable `label` |
| citations | `note_resource_id`, `note_version_id`, `id`, `ordinal`, `source_resource_id`, `source_version_id`, `fragment_id`, `locator` |
| files | `path`, `media_type`, `byte_size`, `sha256` |

All version keys are present; inapplicable fields are null. Live relationship
endpoints outside the body selection use `metadata_only_unselected`, not an
unavailable/deleted claim. Descriptors with
insufficient authorized metadata use null optional values, not another
version's values. Source IDs/locators are necessary provenance, not secrets.
No owner/Vault identifiers, logins, sessions, principal identifiers, storage
references, wrapped keys, key domains, capabilities, receipts, job payloads,
or arbitrary database metadata appear. This plaintext user-requested artifact
contains user content and is private, despite the schema being non-secret.
`files` excludes `manifest.json` to avoid recursive digesting; the returned
handle supplies the final manifest's size/digest separately.

Fixed initial limits: 100,000 selected version/endpoint keys, 1,000,000 total
metadata records, 1 GiB manifest/spool metadata, 64 GiB total file bytes and
15 minutes execution. Exceeding any limit fails with a bounded content-free
error. Honor stricter existing per-item limits: 64 MiB Document originals,
4,096 fragments, 64 KiB fragment text, 16 MiB extracted text, and existing
Note/source-set limits. Page metadata at at most 500 rows; stream content in
at most 64 KiB chunks and JSON one record at a time. Do not collect all bodies,
fragments, encoded manifest or object bytes in BEAM memory. Closure indexes
are bounded by the explicit version/record ceilings.

Directories are mode 0700; files are exclusive-created mode 0600. Write under
a random, application-owned staging directory, finalize the manifest last,
verify every listed size/digest and reference, and atomically rename within
that root to completed state. Return no handle on error. On cancel, disk-full,
timeout, process death, denied chunk or checksum mismatch, revoke outstanding
leases and remove only this operation's owned staging; startup scavenging
handles leftovers. No partial file is advertised as a completed artifact.

## 6. Logical V3 wire schema and inventory

Logical V3 is distinct from outer encrypted bundle/Manifest version 1. Preserve
outer framing, cipher suite, authenticated manifest, wrappers, KDF, keys,
object encoding, and existing recovered-key handoff. Freeze V1/V2 schema
modules and golden bytes; select `LogicalSchemaV3` explicitly for new writes.
Codec/verifier/restorer dispatch accepts exactly logical versions 1, 2 and 3,
and rejects mixed-version records. Do not infer version from table count.

During implementation, introduce explicit V3 support behind explicit version
selection while the default remains V2 and its unsupported-content guard
continues to fail closed. Switch new-backup default to V3 only after its writer,
full restore/validation/integrity boundary, compatibility fixtures and focused
round trips qualify together. Documentation/selector preparation must not
introduce a production guard exception. The final Phase 5 product writes V3.

V3 preserves all V2 table ordinals/columns/types/nullability at ordinals 0–29
and appends these eight tables at 30–37. There is no separate Documents table:
Document resource identity is `content.resources` plus `resource_versions`.
The V3 total is 38 tables and 367 columns. Listed column order is wire order;
SQL scalar type tags/nullability match the defining migrations exactly.

| Ordinal/table | Ordered columns (primary key in following paragraph) |
| --- | --- |
| 30 `content.document_versions` | `resource_version_id, resource_id, vault_id, classification, source_asset_id, source_resource_id, source_resource_version_id, source_object_id, source_digest, source_byte_size, media_type, title, created_by_principal_id, state, attempt_generation, extraction_adapter, extraction_format, extracted_text_digest, detected_language, failure_code, attempt_finished_at, inserted_at, attempt_job_id, attempt_started_at, attempt_deadline_at` |
| 31 `content.document_fragments` | `id, resource_id, resource_version_id, vault_id, classification, ordinal, text, digest, locator, inserted_at` |
| 32 `content.document_import_receipts` | `vault_id, principal_id, mutation_id, request_fingerprint, state, resource_id, version_id, inserted_at` |
| 33 `content.note_attachments` | `note_resource_version_id, id, note_resource_id, vault_id, classification, target_resource_id, target_resource_version_id, target_kind, ordinal, role, label, inserted_at` |
| 34 `content.note_citations` | `note_resource_version_id, id, note_resource_id, vault_id, classification, source_resource_id, source_resource_version_id, fragment_id, locator, ordinal, inserted_at` |
| 35 `content.tags` | `id, vault_id, classification, display_value, normalized_key, created_by_principal_id, inserted_at` |
| 36 `content.resource_tags` | `resource_id, tag_id, vault_id, classification, inserted_at` |
| 37 `content.relationships` | `id, vault_id, classification, source_resource_id, target_resource_id, target_resource_version_id, type, created_by_principal_id, inserted_at` |

Primary keys respectively: version UUID; fragment text ID; owner/principal/
mutation UUID triple; Note-version/reference UUID pair for each source table;
tag UUID; resource/tag/owner UUID triple; relationship UUID. Existing wire
tags and primary-key ordering remain unchanged. Golden schema tests freeze
all definitions; a schema-to-current-DDL contract catches an omitted column.

Retain completed Document import receipts and fingerprints because retry
identity is part of import state. Pending receipts cannot exist at a valid
committed cut. Note/knowledge mutation receipts remain excluded, as in existing
backup, because they are session-operation replay bookkeeping; restore ends
their retry namespace and clients must create fresh mutation IDs. Preserve
Note versions/conflicts and source sets themselves. Never describe excluded
receipts as reconstructed canonical evidence.

Do not serialize search projections, source-set seals, sessions, Oban rows,
restore staging/admission records or new export artifacts. Preserve existing
V2 durable outbox/job records and their exact provenance fields. Regenerate
source-set seals only after all source members for every Note version exist,
including empty historical V1/V2 sets. Source object pin counts are queried
from versions, not a new serialized counter.

V3 object closure is the union of existing required live-Asset objects and
**every** `document_versions.source_object_id`, regardless of Document state,
head status, tombstone or source Asset release/deletion. Deduplicate by object
ID, sort by ID, retain the established object-evidence/raw-record mapping.
Each Document pin must have its exact historical owner, Asset/version and
association identities plus the independently pinned object and available
retained original. `document_versions.source_object_id`, `source_digest` and
`source_byte_size` are authoritative immutable original evidence. Source Asset
cleanup may clear `assets.asset_object_id`, mark the Asset deleted and release
the association; those changes do not invalidate the Document pin. Never
require a nonnull/current/live Asset object binding or an unreleased
association to restore that history. Validate the retained object directly
against the Document's owner/classification/size and authenticated plaintext
digest. Missing retained bytes is corruption,
not permission to omit the Document. Do not demand bytes for already physically
deleted Asset-only historical references whose established state permits their
absence. Inventory must match this rule exactly, with no extra foreign objects.

Extend the fail-closed unsupported-canonical guard only when V3 covers these
rows; never replace it with unconditional false. Check unsupported kinds,
format versions, shapes and missing closure. Retain legacy writer rejection
of V3-only rows. Add only narrow knowledge-table read grants required by the
existing backup worker and existing owner RLS; do not grant new mutation,
custody, identity, key or capability authority. The cut, row counts, lazy row
streams, object streams and acknowledgement stay inside the established
scoped repeatable-read backup transaction.

## 7. Semantic preflight and historical admission

Wire order is not insertion order. First authenticate the immutable bundle
using the established reader, then stream rows into connection-local typed
temporary staging tables, with bounded rows/chunks and fixed schema mapping.
Use SQL indexes/joins for full closure instead of collecting all canonical
text in an Elixir map. Preflight staging is not canonical mutation. Never run
SQL identifiers or functions supplied by the bundle. Retain the existing
64 KiB header, 16 MiB record and 999,999 non-manifest-frame limits.

Before canonical writes validate:

- Exact row counts, schema/type/nullability, PK and secondary uniqueness;
  one authenticated owner graph and every owner/classification join; valid
  creator/membership identities and existing V2 identity/wrapper rules.
- Typed resource heads; Note body digests, revisions, parent/merge DAGs and
  conflict states; exact historical Document source identities and independent
  original object pin as specified in §6, size bounds, all extraction
  state/attempt-field shapes and supported extractor format values.
- Ready Document fragments: canonical locators, IDs, text digests, contiguous
  ordinals, count/size bounds and aggregate digest over text concatenation.
  Reject fragments on non-ready states, including extracting snapshots: actual
  extraction completion inserts fragments and transitions atomically.
- Note source owners/types/exact versions; no self links; unique targets and
  contiguous source ordinals; source membership bounds; citation's exact
  fragment and locator equality. Historical deleted/released endpoints are
  allowed only as structurally complete immutable history, never retargeted.
- Tags normalize to their keys using the same Core rule; unique owner/key;
  assignments and relationships have same-owner typed endpoints and unique
  keys; pinned relationship versions belong to their specified target.
- Completed import receipts point to the exact Document result; durable work
  refers to allowed owner/entity/version/generation and legal payload shapes.
- Exact object closure, ciphertext lengths/hashes and one-to-one authenticated
  evidence/raw object mapping; each source digest is a valid canonical SHA-256.
  Original plaintext digest equality is checked through existing integrity
  custody after rewrap, as explicitly scoped in §8.

Historical admission is a narrowly added SQL path, not disabled triggers or
an ordinary API bypass. A forward migration creates
`audit.knowledge_restore_admissions`, owned by `singularity_table_owner`, with
no runtime/PUBLIC grants. Its row stores manifest ID, owner ID, authenticated
manifest hash, current full transaction ID, backend PID, expected canonical
row-count vector, per-table canonical row digests, and state (`loading` or
`validated`). It is restore
bookkeeping, excluded from all payloads. Its insert/update entry functions
require exactly `session_user = 'singularity_migration'` and existing SET
authority for the table-owner role; SECURITY DEFINER `current_user` alone is
not proof. Pin search paths, qualify every relation, and do not trust a GUC,
temporary relation name, caller Boolean, caller principal or runtime role.

Admission additionally requires the existing advisory restore lock, locked
pending saga with equal manifest/hash/owner, an empty validated destination,
and current transaction/backend binding. Only the existing maintenance restore
adapter creates it after staged preflight. An admission expires with its
transaction and cannot authorize a later write or another connection. A
deferred constraint trigger on admission creation/update independently requires
`validated` state plus final graph/count verification at transaction end;
omitting the explicit finalizer cannot commit a partial graph. Runtime roles
cannot read, insert, update or execute admission helpers, even after setting
arbitrary session GUCs. No role membership/attribute or Vault policy changes.

Per-table comparison uses the same explicit typed canonical column projection
for staged and destination rows, stable primary-key order, length-framed
row encodings and SHA-256; knowledge rows must be identical. Established V2
compatibility transformations retain their existing separate verification.
Expected digests derive from authenticated staged rows before admission, not
from destination rows after mutation. The transaction-end validator compares
these digests as well as counts, detecting equal-count changes after explicit
validation. Admission helpers cannot be invoked by runtime roles via another
SECURITY DEFINER function; exact migration `session_user` is mandatory.

New forward definitions amend only knowledge admission guards:

1. `enforce_document_source`: authenticated restore uses complete historical
   identity/owner/type/size agreement instead of creation-time live Asset
   status. A released association and nulled current Asset object pointer are
   legal; the immutable Document original pin is verified independently.
2. `enforce_document_fragment`: admit INSERT into its exact ready restored
   version while retaining canonical fragment checks; UPDATE/DELETE remain
   forbidden. Ordinary completion's ready seal is unchanged.
3. `enforce_note_source_set`: under bound restore, replace creation-time live
   or parent-retention admission with exact structural history validation;
   retain identity, type, source-set/ordinal and locator constraints.
4. `enforce_knowledge_organization_resource`: permit historical tombstoned
   endpoints with exact same-owner typed bindings; retain uniqueness, target
   version and unambiguous Asset association checks.

No broad early `RETURN NEW` is acceptable. Each historical branch runs its
explicit validator; normal branches remain byte-equivalent in behavior.
Sealed-set insertion, immutable identity, lifecycle, FK, CHECK and completion
constraints stay enabled. In particular no rewriting deleted rows as live,
inventing extraction attempts, or temporary replacement of canonical digests.

Task6 necessary work-validator correction: an actual authenticated complete
history restore reached the private extraction payload validator and raised
SQLSTATE42702 because its local `resource_id` conflicts with table columns.
Add only forward migration `20261011000410_knowledge_restore_work_validation.exs`
to replace `audit.knowledge_restore_payload_is_valid(core.outbox_events)` with
an unambiguous local name. Preserve its complete existing value predicates,
signature, private owner/ACL, SECURITY INVOKER and pinned search path. Do not
change accepted00300, generic outbox behavior, runtime grants, admission
authority or any Vault/custody substrate. The genuine complete-history
payload, graph, all38 digests/seals, explicit validation and actual COMMIT
remain required; independent review includes this additive compatibility fix.

Import stages inside one canonical transaction are:

1. Lock/check the union of V1/V2/V3 canonical tables plus excluded/derived
   destination tables, establish the admission, and defer only already
   deferrable constraints.
2. Insert established V2 identity/opaque owner/key compatibility records,
   generic resources/versions, Asset objects/envelopes/Assets/associations and
   existing durable work in dependency order; preserve legacy compatibility
   transforms exactly. Note versions/conflicts retain their established order.
3. Insert Document versions with their actual final state, then fragments,
   completed import receipts, tags, assignments and relationships. Insert Note
   attachments/citations only after all typed versions/fragments are present.
4. Finalize each Note source set after all its members; do not let the generic
   V1/V2 per-Note insertion shortcut seal an empty V3 set prematurely.
5. Force the fixed ordinary/source/completion deferred constraints while the
   bound admission is still loading. In particular, deferred AFTER INSERT Note
   source checks require historical loading-state authority when they execute.
   Keep the admission final-check queue deferred; do not use `SET CONSTRAINTS
   ALL IMMEDIATE`. Then run final staged-versus-canonical equality/counts and
   structural/digest verification, mark admission validated, publish objects
   and `mark_imported`. The transaction-end check still verifies the final
   state. A mismatch rolls back all canonical rows.

V1/V2 keep their decoder definitions and import semantics, generating empty
source seals. All restore versions check the expanded destination-table union
so a legacy restore cannot ignore existing V3 content. Excluded runtime tables
remain empty where the established restore contract requires it.

For an already imported V3 marker, freshly authenticate and privately type-stage
the identical bundle without staging or publishing object files. Preserve the
existing `KnowledgePreflight.stage/4` object-staging behavior; add only internal
`stage_for_verification/4`, using fixed private object-stage/verify modes. Verify
raw inventory lengths and incremental ciphertext hashes in the latter mode,
with the same caller/repository/backend/full-transaction/destination binding.
The returned staged purpose is explicit: verification-only input cannot begin
historical write admission. Native replay stays a bounded fixed-registry
iterator, never caller SQL or wire re-encoding. Compare every canonical table,
exact source memberships/seals and existing published inventory; no canonical
insert, source finalization, admission write or filesystem mutation on retry.
V1/V2 imported retries also reject any V3-only canonical rows, not merely lock
the expanded union. This is internal restore correctness, not a runtime API,
new capability, observer, crypto change or activation.

Retained preflight characterization still rejects malformed binding/cut without
any canonical, temporary, staged or published side effects. Its valid ordinary
V3 import into a populated destination now rejects with `conflict` instead of
the earlier closed-dispatch `backup_invalid`. Only that obsolete phase-code
expectation and descriptive test name change; all18 complete owner cases and
their no-write assertions are retained. Native-row replay is PK ordered for
all38 fixed tables, including outbox UUID IDs. This internal native order is
distinct from the unchanged protected wire's required outbox sequence order.

An actual complete retained gate exhausted the default60-second ExUnit budget
of the Document-state group, which bundled22 independently authenticated
mutations plus fixture setup/cleanup. Private checkpoint evidence and a
content-free monotonic probe characterize cumulative work, not an independent
60-second DROP hang. Split only that group into22 fresh independent cases,
retaining all original mutation inputs, genuine authentication, assertions,
helpers and default timeout; remove the temporary diagnostic output. The
original18 semantic groups now have39 executable cases. The whole owning and
complete retained gates must pass on a new exact source receipt; the failed
repair1 gate and isolated diagnostic PASS do not qualify acceptance. No
production or fixture cleanup behavior changes are part of this repair.

## 8. Staging, failure atomicity, and integrity

Use the existing disposable empty destination and maintenance-mode workflow.
For replacement, the active installation remains untouched until the separate
supported operational replacement step after successful verification. This
phase does not add an in-place overwrite or automatic production cutover.

The existing sequence stays: authenticated immutable bundle → preflight →
canonical import transaction/object publication into the maintenance
destination → existing owner rewrap → ciphertext verification → durable-work
reconciliation → plaintext verification and projection rebuild → complete
restore. Document-source verification runs after authenticated plaintext-summary
validation and before projection rebuild. Maintenance and dispatch barriers
remain enforced throughout; `Runtime.RestoreVault` keeps its existing ordering.
Database and object storage do not form one distributed transaction.

Malformed wire data, duplicates, dangling/cross-owner references, canonical
text/fragment digest mismatch and bad ciphertext fail before canonical import.
Late constraint/import failure rolls back canonical rows and invokes existing
owned-object cleanup, preserving its identity-bound pending saga. Publication
failure or uncertain commit is recovered through the existing pending/imported
marker and exact inventory checks; never delete objects belonging to another
manifest or treat an uncertain commit as success.

Plaintext source digest checking necessarily follows the frozen rewrap/custody
handoff. `Runtime.IntegrityAudit.verify_final` already receives authenticated
`RestoreIntegrityLease.PlaintextSummary.plaintext_hashes`; the existing Storage
search-rebuilder input does not contain those hashes. Add one narrow knowledge
validation call there, after validating that summary and before rebuild or
completion, passing owner/manifest binding and the authenticated object/hash
pairs to `Storage.Backup.IntegrityAudit.verify_document_sources`. This is a
knowledge-completeness check, not a custody/key change. It compares every
Document source digest and canonical size to its inventory/material and
verified object hash, including objects retained only by Documents. The helper
must reject missing, duplicate or extra evidence relative to the full object
inventory and owner/manifest mismatch; legitimate Asset-only inventory entries
remain valid even when no Document refers to them.
Keep the lease and its material/crypto protocol unchanged. Do not hash
ciphertext as if it were the plaintext digest. Retain existing Note digest and
Asset evidence checks; validate all ready historical Document extracted digests
again before completion.

If plaintext verification or a later saga stage fails, no graph is exposed:
maintenance remains mandatory and `complete_restore` is not reached. A
malformed staged destination is discarded/recreated through the established
disposable-destination procedure; it cannot be resumed with another manifest.
Retryable interruptions resume only the identical authenticated manifest and
destination identity. Existing active installation/data remains unchanged.
This is atomic rejection at the published graph boundary; it does not falsely
promise rollback of the completed import transaction, rewrap, or filesystem
publication after a later failure. Tests assert both transaction rollback for
pre/import failures and zero publication/visibility for post-import failures.

## 9. Search and durable-work recovery

After canonical verification and before dispatch resumes, rebuild projections
from canonical records using established reconciliation functions. Enumerate
all restored resource IDs in stable order, clear stale derived rows, and use
`content.reconcile_search_resource_internal` for current Note/Document heads.
Retain existing Asset projection rebuild. Never trust serialized search rows.
Ready live Document heads yield their exact canonical fragment results;
non-ready, deleted and old-version Documents yield none. Old fragments remain
canonical for citations. Repeat rebuild and compare stable ID/version/fragment
tuples, matched text and locators, not incidental physical row order.

Extend Storage `Backup.Reconciler` with exact Document event/job payload
allowlists derived from Phase 2 (`document.extraction_requested`,
`document.ready`, `document.deleted`, `document.restored`). Preserve the
established periodic `Documents.ExtractionReconciler` recovery mechanism; it is
not a serialized recovery job. Validate provenance epochs and owner just as
existing work; unknown event types or malformed payloads fail closed. Never
infer an event's authority from content text or issue new capabilities.

For completed ready/failed/unsupported versions retire redundant extraction
work as already reflected. Retire stale generation/head/destructive work;
reconcile projection events against actual final resource state. Live pending
versions retain one valid current-generation extraction request and wake;
deleted pending versions remain undispatched until ordinary restore behavior.
An `extracting` snapshot has no running process in the new installation:
preserve its deadline and let the existing periodic guarded Phase 2 recovery
invalidate the abandoned attempt and issue the next generation after normal
service resumes.
Do not force an illegal state change, extend its deadline, synthesize a live
session or bypass custody. If historical authorization is no longer valid,
retire work under the established provenance rules; authenticated ordinary
retry remains necessary. Reconciliation is idempotent across saga retries.

The acceptance comparison distinguishes the restored cut from later legitimate
recovery transitions: canonical snapshot equality is checked before recovery;
subsequent generation/state changes must exactly match existing recovery rules.
Dispatch must remain stopped until graph validation, complete projection rebuild
and restore completion succeed. No partially rebuilt search may be served.

## 10. Migration and compatibility strategy

All schema/guard/grant changes use new forward migrations after the Phase 4
baseline; never edit a released migration. Separate V3 admission/validation
DDL from the narrow export/backup read grants and supported-payload guard so
review can prove their effects. Existing runtime role membership, Vault tables
and key/custody functions remain unchanged. New tables are maintenance
bookkeeping, not another canonical knowledge model.

The 0.1 upgrade fixture starts with the migration set and schema at historical
release `c49dc0aeda1d0115b20ff291f0da658f7e558b43`, whose repository identity
must be checked by the coordinator. Populate representative canonical Notes,
history/conflicts, Asset bytes/associations, deleted rows and durable work using
that schema; record exact immutable IDs/digests and source bytes. Apply every
forward migration through Phase 5 without a schema reset. Assert preserved
legacy data, derived seals, current constraints/grants, empty new knowledge
tables where expected, then add knowledge through qualified current contracts.
Create V3 and restore it into a second fresh migrated destination; compare
canonical history, original bytes and public search results. Run this only in
isolated disposable test databases/object roots, never production.

Maintain independently fixed V1/V2 fixture/golden records in addition to V3
round trips. Writer defaults to V3 even when no Documents exist. V1/V2 restore
into latest schema must not invent Document rows or source memberships. Old
readers rejecting V3 is expected; old backups being unreadable is not.

## 11. Implementation sequence and proof obligations

The coordinator owns the detailed plan, execution, test commands and final
acceptance. Dependency order:

1. Characterize V1/V2 golden wire/restore, current inventory, frozen file hashes,
   role denials, source-set finalization and historical admission failures.
   Establish the current clean baseline before behavioral changes.
2. Define Core portable contracts and V3 schema/codec/closure contracts in
   parallel where files do not overlap. Add failing focused tests first.
3. Implement preflight staging and the forward historical-admission migration;
   prove negative role/constraint counterexamples before enabling V3 writes.
4. Implement import dependency order, V3 inventory and unchanged cryptographic
   composition; add all-state historical fixtures and malformed rejection.
5. Implement Document integrity, durable-work reconciliation and unified search
   rebuild; prove repeatable restore/recovery before accepting round trips.
6. Implement exact-binding portable reads and private writer/handle lifecycle,
   using the already defined Core contracts; prove byte identity and denial
   cleanup using real request custody composition as well as isolated tests.
7. Add historical upgrade acceptance, complete permitted README verification,
   independent specification/quality review, evidence documentation and small
   local commits. Only then consider Phase 5 locally accepted.

Required deterministic acceptance cases:

- V3 contains live and tombstoned Notes/Documents, old heads, Note conflicts
  and merges, every Document state, retained originals after Asset deletion,
  shared objects, fragments, tags, assignments, relationships, attachments,
  citations, completed receipts and durable recovery work. Compare canonical
  data at the cut, exact IDs/locators, source-set membership, all digests and
  original binary bytes after clean and supported replacement staging restore.
- Independent malformed fixtures cover duplicate PK/unique keys, extra/missing
  rows/objects, mixed logical versions, wrong owner/classification, dangling
  heads/parents/conflicts, wrong kind, ordinal gaps, locator/fragment/digest
  tampering, unsupported formats, receipt disagreement, ambiguous bindings,
  extra foreign objects, truncated/changed ciphertext and source-byte mismatch.
- Counterproof SQL as web/worker/dispatcher/pre-auth and spoofed GUC sessions
  cannot establish admission, append to ready fragments/sealed Note sets,
  accept deleted sources as new runtime links or bypass organization guards.
  Wrong manifest/backend/transaction, missing finalizer, post-validation row
  mutation, and stale admission records all fail at or before commit.
- Fault barriers at preflight, canonical insert, staged object publish, commit
  uncertainty, rewrap, plaintext verification, reconcile/rebuild and completion
  prove rollback or unpublished maintenance recovery as applicable; retry the
  exact manifest without duplicate objects, graph rows, jobs or source seals.
- Portable output handles duplicate titles, hostile labels/paths, version
  cycles, two pins to different historical versions, source Asset deletion,
  metadata-only tombstones, unresolved deleted sources, limits, expiry/cancel,
  revocation between chunks, disk exhaustion and process death. A standard
  Markdown reader plus JSON parser resolves every declared present file and
  citation without a Singularity database or proprietary URI scheme.
- A barrier moves a head or changes tags after snapshot capture: files/metadata
  remain from the cut, immutable pins never retarget. A separate barrier
  revokes access/deletes a selected live source: completion fails and cleans up.
- Memory/bounds tests instrument chunk/page sizes and reject eager full-export
  accumulation; identical captured selections produce identical files/manifest.
- V1/V2 fixture restore and upgrade fixture pass; ordinary runtime regressions
  retain prior assertions. Verify seven applications and zero xref cycles,
  full permitted README gate, no frozen-substrate semantic changes and no
  publication/production activity. E2E remains explicitly NOT RUN.

## 12. Review focus and completion record

Highest risks are historical admission becoming runtime authority, incomplete
object closure, premature source sealing, overclaimed saga atomicity, and
portable metadata being mistaken for deleted-byte authority. Each has explicit
negative acceptance coverage above. No new user-only product decision is
required by the recommended design. A proven need to change frozen custody or
key behavior is a design blocker, not permission to bypass it.

This architecture task ran no Mix/tests/database/services/network operations
and changes only this design file. Its source inspection and document checks
do not establish current V3 implementation or test success. Implementation,
all verification results, exact migration/file lists, source hashes, independent
reviews and remaining risks belong to the coordinator's Phase 5 plan and
acceptance report. Architecture work consumes no recovery repair round.
