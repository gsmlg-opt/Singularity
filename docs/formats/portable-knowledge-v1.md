# Portable knowledge format 1

This is a private, plaintext, readable selection of knowledge. It is **not a
logical backup**, a complete history export, an undelete mechanism, or a restore
input. It contains user content; protect its directory and dispose of it when
finished. The format does not require a Singularity database or proprietary URI
scheme to read the included files.

## Selection and files

Selection mode is `live_heads_with_source_closure`: live Note and Document heads,
their recursively selected exact-version sources, and live Asset versions needed
by those sources. An updated head never substitutes for an immutable source pin.
Two selected versions of one resource have different version-addressed files.
Standalone Asset-library export is not part of this format.

Assigned tags and relevant relationships are included. An otherwise unselected
relationship endpoint, pinned endpoint version, or Note parent/merge ancestor
gets an authorized metadata descriptor, not its body or an expanded source set.
`include_tombstones` additionally selects authorized tombstone metadata. It does
not grant access to deleted bodies or originals. Unreferenced history and conflict
branches belong to logical backup V3, not this selection.

Paths use canonical lowercase UUIDs, never titles or original filenames:

```text
notes/<resource>--<version>.md
documents/originals/<resource>--<version>.<pdf|md|txt>
documents/extracted/<resource>--<version>.txt
assets/<resource>--<version>.bin
manifest.json
```

Document media mappings are `application/pdf` → `pdf`, `text/markdown` → `md`,
and `text/plain` → `txt`. Original files preserve the actual binary bytes,
including empty originals. Asset files use `application/octet-stream` or the
captured declared media type; Document originals use their captured media type.
Note files use `text/markdown`; extracted text uses `text/plain`.

Note Markdown starts with the captured canonical body and uses ordinary readable
source links/footnotes from the established Markdown renderer. Source descriptions
identify exact resource/version pins, titles, reference IDs, and citation
fragments/locators. Included Note links are relative basenames; other included
links are relative `../assets/...` or `../documents/...` paths. A ready Document
source links to its extracted text; another admitted Document source links to
its original. Deleted metadata has a readable reason, not a fictitious file link.

Extracted text concatenates canonical fragments in ordinal order with **no added
delimiter**. `start_byte` and `byte_size` are UTF-8 byte offsets/lengths, not
character counts. Non-ready Documents retain their original and explicit state
without fabricated extracted text.

## Manifest

`manifest.json` is UTF-8 JSON. Its fixed top-level key order is:

```text
format, version, selection, resources, versions, fragments, tags,
tag_assignments, relationships, attachments, citations, files
```

`format` is `singularity.portable-knowledge`; `version` is integer `1`.
`selection` has exactly `mode` and boolean `include_tombstones`, preserving the
original normalized selection option. Arrays are present even when empty.
There is no export-clock timestamp: identical captured selections yield identical
file and manifest bytes. UUIDs are canonical lowercase text; SHA-256 values are
lowercase 64-character hex. Timestamps are UTC with six fractional digits and
terminal `Z`; counts, revisions, and ordinals are integers. JSON null denotes an
absent or inapplicable value; every listed field is present.

Record key order and identity ordering are fixed:

| Array | Fields, in serialization order | Array ordering |
| --- | --- | --- |
| `resources` | `id`, `kind`, `title`, `current_version_id`, `deleted_at`, `selection_reason` | `id` |
| `versions` | `resource_id`, `version_id`, `revision`, `kind`, `inserted_at`, `availability`, `body_path`, `original_path`, `extracted_path`, `body_digest`, `original_digest`, `original_byte_size`, `extracted_digest`, `media_type`, `state`, `extraction_adapter`, `extraction_format`, `parent_version_id`, `merge_parent_version_id` | resource/version |
| `fragments` | `id`, `resource_id`, `version_id`, `ordinal`, `digest`, `locator`, `extracted_path`, `start_byte`, `byte_size` | resource/version/ordinal/ID |
| `tags` | `id`, `display_value`, `normalized_key` | `id` |
| `tag_assignments` | `resource_id`, `tag_id` | resource/tag |
| `relationships` | `id`, `source_resource_id`, `target_resource_id`, `target_version_id`, `type` | `id` |
| `attachments` | `note_resource_id`, `note_version_id`, `id`, `ordinal`, `target_resource_id`, `target_version_id`, `target_kind`, `role`, `label` | Note resource/version/ordinal/ID |
| `citations` | `note_resource_id`, `note_version_id`, `id`, `ordinal`, `source_resource_id`, `source_version_id`, `fragment_id`, `locator` | Note resource/version/ordinal/ID |
| `files` | `path`, `media_type`, `byte_size`, `sha256` | `path` |

Resource `kind` and attachment `target_kind` are `note`, `document`, or `asset`.
`selection_reason` is `head`, `source`, `relationship_endpoint`, or `tombstone`.
Resource `current_version_id` may be null when no head is available; `deleted_at`
is null for a live resource. Version provenance uses exact immutable UUIDs.
Note `parent_version_id` and `merge_parent_version_id` may be null; inapplicable
parent fields are null for Assets/Documents. They are historical metadata links,
not promises that ancestor bodies were selected.

Availability is explicit:

- `included`: the kind-appropriate declared files are present and verified.
- `metadata_only_deleted`: positively authorized historical/deleted metadata;
  no body/original/extracted file is present.
- `metadata_only_unselected`: authorized ancestry or relationship-endpoint
  metadata outside body selection; no files are present.
- `metadata_only_unavailable`: reserved by the pure schema, **not emitted by the
  current export**. Missing bytes, corruption, I/O failure, expiry or authorization
  denial fail the operation, not a successful unavailable downgrade.

Included Notes have `body_path` and canonical `body_digest`. Original/extraction
fields are null. The canonical body digest is independent of the rendered `.md`
file digest in `files`; source rendering can change the latter.

Included Assets have `original_path`, `original_digest`, `original_byte_size`, and
`media_type`; body/extraction/state/parent fields are null. Asset plaintext SHA-256
is calculated from actual authenticated fold bytes and size before public schema
validation. Private pending null-digest drafts and binary bindings are never
published; keyed lookup digests and ciphertext hashes are not plaintext hashes.

Included Documents have an original path/digest/size/media type and state:
`pending`, `extracting`, `ready`, `failed`, or `unsupported`. Pending extraction
has null adapter/format; other states carry the captured supported adapter/format.
Only `ready` declares `extracted_path` and `extracted_digest`. Document original
SHA and size still must match its exact immutable retained pin. A released or
deleted source Asset does not retarget that Document pin.

Metadata-only versions have null `body_path`, `original_path`, and
`extracted_path`. Other optional metadata is preserved only when positively
available and applicable; another version's values are never substituted.
Metadata-only citation fragments retain their permitted ID, digest, ordinal and
canonical locator, with null extracted path/byte offset/length. No hidden text is
invented or exported.

Fragment `digest` hashes its canonical text bytes. Its `id` is the canonical
Document fragment identity binding version, locator, ordinal, and digest—not
merely the text SHA. Ready-fragment ordinals are contiguous from zero; each
fragment and the complete no-delimiter aggregate are independently checked.
Locators use the established canonical version-1 `pdf`, `markdown`, `text`, or
`fragment` representation.

Tags preserve display value and its established normalized key. Assignments bind
resource/tag IDs. Relationship `target_version_id` may be null; when present it
belongs to the exact target resource. Relationship types are `related_to`,
`references`, or `derived_from`. Attachments use role `source` and a nullable
label. Citation IDs/fragment IDs/locators bind the exact captured source version.
Every referenced resource/version/tag/fragment must have a matching descriptor;
there is no dangling implicit reference or silent truncation.

`files` lists every included data file with actual byte size and SHA-256. It
**excludes `manifest.json`**, avoiding recursive hashing. The internal completed
artifact's separately verified manifest descriptor is included in entry delivery.
Consumers can verify every data file against the manifest, and the manifest
against that separately supplied descriptor.

## Bounds, integrity and lifecycle

Fixed limits have no public or test-selectable overrides:

| Bound | Limit |
| --- | --- |
| Selected version/endpoint keys | 100,000 |
| Total capture/writer metadata and index records | 1,000,000 |
| Capture, temporary plaintext, journals, framing and indexes combined | 1 GiB |
| Final manifest | 1 GiB |
| All final files, including manifest | 64 GiB |
| Execution/delivery lifetime from the original capture clock | 15 minutes |
| Writer/delivery chunk | 64 KiB |
| Entry page | 500 descriptors |
| Canonical Note / rendered Note | 1 MiB / 16 MiB |
| Distinct typed source targets per Note | 100 |
| Document original | 64 MiB |
| Ready fragments / one fragment / extracted aggregate | 4,096 / 64 KiB / 16 MiB |

Ready Documents require at least one fragment and one extracted byte. Empty Note
bodies and authenticated empty originals remain valid. A legal escaped metadata
record may exceed 64 KiB; it is serialized one record at a time in smaller chunks.
The writer never collects corpus bodies, original streams, or the whole manifest.
Only one bounded Note and its bounded source descriptions are reassembled for
the unchanged renderer. Temporary duplicate plaintext has no quota exemption.

Materialization consumes only exact real sealed capture members/refs. The trusted
original adapter emits bounded authenticated bytes and closes/revalidates its
exact selector before returning success. Writer derives hashes from bytes, checks
captured sizes/digests, and rereads real final files to verify intended output.
It writes the manifest last and verifies every declared reference, file and hash
before publication. Errors are bounded/content-free and yield no completed
artifact. Pure filesystem callback doubles qualify this Writer boundary only;
they do not prove live custody or request authorization.

The dedicated application-configured export root is mode0700, non-symlink,
separate from ciphertext and backup roots. Each operation uses a random owned
directory, exclusive mode0600 files and mode0700 subdirectories. Absolute paths,
traversal, duplicate/case-fold-colliding paths and symlink traversal are rejected.
Completion reserves a new empty directory exclusively, binds its inode/ownership,
and renames only over that operation's reservation under a shared finish/cancel
gate. Existing empty/nonempty destinations or symlinks are not overwritten.
This trusted-root contract does not claim OS `RENAME_NOREPLACE` protection against
hostile same-UID mutation between native checks and rename.

The internal artifact contains descriptors and bounded identity/hash indexes,
not corpus text. Entry cursors are operation-bound; chunk delivery accepts only
listed paths and valid ordinals and checks actual bytes. The original deadline
is never restarted. Abort/cancel removes only the witnessed owned operation,
without following symlinks or deleting neighboring operations/foreign completion
destinations. An operation-local identity ledger must move with ownership when
Runtime transfers the artifact to its supervised owner; generator death before
handoff is not a successful artifact. Runtime remains responsible for current
session authorization, lease revocation and process-death/startup scavenging.

No owner/Vault IDs, principals, sessions, logins, storage references, object/key
domains, wrapped keys, capabilities, receipts, job payloads or arbitrary database
metadata appear in the public manifest. Necessary resource/version/fragment IDs
and locators are provenance, not cryptographic secrets. The files still contain
private user content. Format-source documentation and local Writer unit evidence
do not imply browser, live custody, release or production qualification.
