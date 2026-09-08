# Singularity v0.2 Phase 1 Canonical Knowledge Model Implementation Plan

> **For agentic workers:** Use subagent-driven-development or executing-plans to execute this plan task by task. Steps use checkbox syntax. Parallel work is limited to tasks with satisfied dependencies and disjoint files.

**Goal:** Establish the canonical Document and knowledge-link model with scoped, idempotent internal persistence and database integrity, while production writes remain disabled.

**Architecture:** Extend existing resource/version identity through typed Document rows, guarded lifecycle functions, immutable fragments and Note-version source sets, and current organization metadata. Keep validation in core, intent/port contracts in domains, and authenticated reads, Ecto, SQL, and transaction composition in storage. Exercise new writes only in disposable test databases with temporary grants.

**Tech Stack:** Existing seven-app Elixir umbrella, Ecto/PostgreSQL, existing authenticated object reader, ExUnit/StreamData, and the pinned devenv environment. No new dependency is planned.

**Status:** Source-preparation scope resolution approved by the user on
2026-09-07. Detailed plan finalized for execution handoff; no implementation or
phase acceptance is claimed by this document.

**Execution amendment (2026-09-08):** The user approved the test-only historical
migration harness repair described below and requested that end-to-end tests
remain deferred. Continue scoped unit and database checks, but do not execute
the complete README gate or claim Phase 1 acceptance until its deferred
end-to-end checks are authorized and pass. Phase 2 has not started.

**Typed-head verification amendment (2026-09-08):** The user approved retaining
the Task 4 Document deletion/reparenting race assertions against a disposable
database capped at migration `20260906000100`. Task 5's immediate immutable
identity guard intentionally prevents those statements from reaching the older
deferred head guard. Preserve the original deferred assertions at that earlier
schema boundary, including the direct typed-deletion assertion when superseded
by the immutable guard. Keep final-state head updates, the Note race, and all
other current-schema checks on the latest schema; add latest-schema checks for
immediate immutable identity rejection and runtime deletion denial. This narrow
test-boundary exception does not authorize weakening assertions or production
guards. Reuse the isolated migration helper within `document_schema_test.exs`.

---

## Authority, baseline, and execution boundary

Approved specification:
`docs/superpowers/specs/2026-09-06-singularity-v0.2-phase-1-canonical-model-design.md`.
The user approved its content at `ba45d11` on 2026-09-06.
The release directive remains
`docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`, Phase 1.

Product baseline: `6c3e8d5afb2cc9dbf264d276796070e16aa49e55`.
Planning worktree: `.trees/v0.2-phase-1-canonical-model`.
Branch: `codex/v0.2-phase-1-canonical-model`.
Use this existing worktree, not another nested worktree. Read the approved spec,
root AGENTS.md, ADR 0003, Notes design, and relevant current modules before editing.

This plan authorizes no public Document API, registered job, extractor, new
projection, browser UI, backup-format change, production migration, version bump,
merge, push, tag, publication, or deployment. Phase 2 must solve original-byte
retention and abandoned extraction recovery before public import; Phase 4 must
seal Note source-set membership before enabling its writes; activation before
backup V3 requires a guard that fails backups containing unsupported canonical data.

All new canonical tables and write functions deny production runtime writes.
Existing generic-table grants cannot be used to leave an untyped Document behind:
deferred aggregate constraints reject it at commit. Test privileges are temporary,
database-local grants with guaranteed revocation; never ALTER ROLE or relax RLS.

### Source-preparation scope decision

Inspection found that `AuthenticatedReader` requires a raw object DEK, which
must remain in runtime custody. The existing runtime download path returns the
whole plaintext; chunk reads do not authenticate the final digest record. Neither
is a bounded authenticated digest capability usable by the proposed storage
preparer. Existing generic/metadata custody leases require processing/job state;
reusing them would introduce deferred work and change frozen key/capability paths.

Evidence: `apps/singularity_runtime/lib/singularity/runtime/assets/download.ex`,
`apps/singularity_runtime/lib/singularity/runtime/custody_reader.ex`,
`apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex`, and
`apps/singularity_storage/lib/singularity/storage/authenticated_reader.ex`.

Approved resolution (2026-09-07): Phase 1 implements the bounded storage digest primitive,
source-proof contract, source revalidation, and isolated contract tests only.
Defer live custody composition to a separately approved Phase 2 design. Keep all
production Document writes disabled and explicitly do not claim end-to-end live
source preparation. The user approved this narrower acceptance promise. It is
not permission to modify custody, keys, capabilities, or Vault. Task 7 and its
dependent tests proceed against the internal contract and encrypted fixtures;
live custody composition is not a Phase 1 acceptance criterion.

## Execution order and ownership

| Task | Result | Depends on |
|---|---|---|
| 1 | Governance and shared-behavior characterization | approved plan execution |
| 2 | Locators, framing, fragments | 1 |
| 3 | Document/link/tag/relationship values and ports | 2 |
| 4 | Document aggregate migration and typed heads | 3 |
| 5 | Fragment/lifecycle migration | 4 |
| 6 | Source-link/organization migration | 5 |
| 7 | Digest primitive and source-preparation contract tests | 3 |
| 8 | Document receipts and persistence adapters | 5, 7 |
| 9 | Link/tag/relationship adapters | 6, 8 test support |
| 10 | Isolation, rollback, concurrency, compatibility | 8, 9 |
| 11 | Complete gate and independent review | 10 |

Task 7 can run alongside Tasks 4–6. Core tests can be reviewed while migration
work proceeds after Task 3. Only one worker edits shared schema/test support at
a time. Each task ends with a local conventional commit after its checks pass.

## Exact implementation file map

Paths below are relative to the worktree. No wildcard is permission to modify
an unlisted existing file. New modules have the standard `Singularity` namespace.

**Existing files allowed to change:**

- `AGENTS.md`, `README.md`, `docs/guide.md`: active Phase 1 authorization only.
- `apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`: active-phase assertions, retaining freeze and exclusion coverage.
- `apps/singularity_storage/lib/singularity/storage/schema/content/resource.ex`: Document kind and replacement head constraint names.
- `apps/singularity_storage/lib/singularity/storage/schema/content/resource_version.ex`: new Document identity constraint mapping.
- `apps/singularity_storage/lib/singularity/storage/authenticated_reader.ex`: additive bounded digest operation, preserving `read/4`.
- `apps/singularity_storage/test/singularity/storage/authenticated_reader_test.exs`: digest and existing-read characterization.
- `apps/singularity_storage/test/singularity/storage/note_schema_test.exs`: replace exact old-head-FK assertion with equivalent stronger typed-head assertions if required.
- `apps/singularity_storage/test/singularity/storage/migrations_test.exs`: retain every historical and Phase 0 assertion; isolate the historical harness in a disposable database capped at Phase 0, including every full-path migration restoration. This test-only harness change was separately approved because the released Notes downgrade cannot run beneath the new forward-only Document schema.

**New core files under `apps/singularity_core/lib/singularity/core/`:**

`knowledge_encoding.ex`, `knowledge_validation.ex`, `source_locator.ex`,
`document_source.ex`, `document_version.ex`, `document_fragment.ex`,
`document_completion.ex`, `note_attachment.ex`, `note_citation.ex`,
`note_source_set.ex`, `tag.ex`, `resource_tag.ex`, `relationship.ex`.

**New domain files under `apps/singularity_domains/lib/singularity/domains/`:**

`documents/command.ex`, `documents/repository.ex`, `documents.ex`,
`knowledge_links/repository.ex`, `tags/repository.ex`, `relationships/repository.ex`.

**New storage files under `apps/singularity_storage/lib/singularity/storage/`:**

`documents/prepare_source.ex`, `documents/prepared_source.ex`,
`postgres/document_repository.ex`, `postgres/document_mutation_receipts.ex`,
`postgres/document_source_repository.ex`, `postgres/knowledge_link_repository.ex`,
`postgres/tag_repository.ex`, `postgres/relationship_repository.ex`,
`postgres/knowledge_error.ex`,
`schema/content/document_version.ex`, `schema/content/document_fragment.ex`,
`schema/content/document_import_receipt.ex`, `schema/content/note_attachment.ex`,
`schema/content/note_citation.ex`, `schema/content/tag.ex`,
`schema/content/resource_tag.ex`, `schema/content/relationship.ex`.

**New migrations under `apps/singularity_storage/priv/repo/migrations/`:**

`20260906000100_create_document_aggregate.exs`,
`20260906000200_create_document_fragments_and_lifecycle.exs`,
`20260906000300_create_knowledge_links_and_organization.exs`.

**New tests:**

- Core `test/singularity/core/`: `source_locator_test.exs`, `document_values_test.exs`, `knowledge_link_values_test.exs`, `knowledge_properties_test.exs`.
- Domains `test/singularity/domains/`: `documents_test.exs`, `knowledge_ports_test.exs`; `test/support/fake/document_repository.ex`.
- Storage `test/support/knowledge_fixtures.ex`, `test/support/knowledge_test_grants.ex`.
- Storage `test/support/migration_test_environment.ex`: separately approved test-only helper for isolated historical/preflight databases, with guaranteed generated-database cleanup and repository/runtime configuration restoration. Current-schema checks remain in the outer isolated integration database.
- Storage `test/singularity/storage/`: `document_schema_test.exs`, `document_lifecycle_test.exs`, `knowledge_schema_test.exs`, `knowledge_rls_test.exs`, `knowledge_grants_test.exs`, `knowledge_migration_test.exs`, `knowledge_concurrency_test.exs`, `knowledge_privacy_test.exs`.
- Storage `test/singularity/storage/documents/prepare_source_test.exs`.
- Storage `test/singularity/storage/postgres/`: `document_repository_test.exs`, `document_mutation_receipts_test.exs`, `knowledge_link_repository_test.exs`, `tag_repository_test.exs`, `relationship_repository_test.exs`.
- Web `test/singularity/architecture/knowledge_phase1_contract_test.exs`.

Do not modify released migrations, crypto formats, Vault modules, job metadata,
Runtime.Api, NoteSnapshot, Notes commands/fingerprints, backup codecs, dependency
files, workflow files, assets, or application versions. If a required correction
falls outside the map, report the specific evidence before expanding scope.

## Focused verification commands

Run from the worktree root. The integration task forwards test paths to Mix and
allocates its own database; never invoke migrations against a normal dev database.

```bash
devenv shell -- mix test apps/singularity_core/test/singularity/core/source_locator_test.exs
devenv shell -- mix test apps/singularity_domains/test/singularity/domains/documents_test.exs
(
set -euo pipefail
trap 'devenv processes down' EXIT
devenv up -d
devenv processes wait --timeout 120
devenv shell -- bash apps/singularity_storage/priv/repo/bootstrap_roles.sh
devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/document_schema_test.exs
)
```

Substitute only the exact task test paths listed below. New integration modules
use `@moduletag :integration` and `async: false` when granting privileges or
altering schema. Production-role grant tests run with normal migration privileges
before any temporary grant and after revocation. An assertion failure is not
reclassified as timing noise; diagnose it and retain the assertion.

## Fixed contracts used by every task

All new core values have validated constructors returning `{:ok, struct}` or
`{:error, %Singularity.Core.Error{code: :invalid}}`. Validate canonical UUIDs with
the existing helper. Unknown keys and conflicting atom/string aliases fail.
Never convert user strings into atoms. New shared validation helpers are private
to the knowledge model; do not tighten existing generic constructors.

`owner_scope_id` is the name in new pure values. Internal storage context is
`%{principal_id: uuid, owner_scope_id: uuid}` and is mapped to legacy `vault_id`
only by storage. These IDs are trusted orchestration inputs independently checked
against scoped transaction GUCs; a core constructor does not authenticate anyone.

Planning bounds are 255 UTF-8 bytes for titles/labels/tag display, 1,024 bytes for
normalized tag keys, 64 heading components of at most 255 bytes each, 65,536 UTF-8
bytes per fragment, 4,096 fragments per completion, and 16 MiB of total normalized
text per completion. Source preparation accepts up to 64 MiB of authenticated
plaintext. All are explicit v1 constants, not public settings. Zero-length source
bytes may be pinned, but an empty extraction cannot become ready. Strings reject
NUL; tags additionally reject Unicode control characters. All ordinals/generations
fit nonnegative PostgreSQL bigint, and increment at its ceiling returns conflict.

Supported media types are `application/pdf`, `text/markdown`, and `text/plain`.
Canonical text normalizes CRLF and CR to LF in Phase 2; Phase 1 rejects unnormalized
fragment input instead of changing its digest. Do not normalize body Unicode.
PDF fragments require PDF locators, Markdown fragments Markdown locators, text
fragments text locators; any may use the generic ordinal fallback.

Framing is `<<byte_size(field)::unsigned-big-64, field::binary>>`. Locator JSON
uses string keys `version`, `kind`, and only the fields for that kind:

| Kind | Required fields | Optional paired fields |
|---|---|---|
| pdf | `page` | `start_char`, `end_char` |
| markdown | `heading_path` | `start_line`, `end_line` |
| text | `start_line`, `end_line` | none |
| fragment | `ordinal` | none |

Absent optional fields are omitted from JSON and encoded as empty framed fields
for hashing. Heading-path encoding is a framed decimal count followed by each
framed NFC heading. That whole binary is framed as the locator heading-path field.
Require character end > start; require line end >= start. Page/line values start
at 1 and ordinals at 0. Version is integer 1 in JSON and text `1` in the framing.

Fixed independent vector, calculated with Node's SHA-256 and framing:

```text
resource_version_id = 00000000-0000-4000-8000-000000000001
locator = {"version":1,"kind":"text","start_line":1,"end_line":1}
locator_encoding_hex = 000000000000000131000000000000000474657874000000000000000131000000000000000131
ordinal = 0
text = hello followed by LF
text_digest_hex = 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
fragment_id = a5e06997d69433d9a127780ef4d01c4e7147691745f5fcac15b230d3c3e48a48
```

### Task 1: Authorize execution and characterize shared behavior

- [ ] Confirm branch, clean state, design approval, baseline ancestry, and current
  remote main. If main advanced, inspect its delta before changing the recorded
  baseline. Record `git rev-parse HEAD` in the execution report.
- [ ] Run existing `resource_values_test.exs`, `note_values_test.exs`, domain
  `notes_test.exs`, and storage `authenticated_reader_test.exs` as focused unit
  characterization. Run `note_schema_test.exs`, `note_mutation_receipts_test.exs`,
  and `provenance_test.exs` through the isolated integration command.
- [ ] Add `knowledge_phase1_contract_test.exs` to assert the approved design/plan
  references, closed production writes, deferred activation prerequisites, and
  absence of public Document routes/jobs. Run it and observe the missing active
  Phase 1 governance failure before editing active guidance.
- [ ] Update AGENTS.md, README scope paragraph, and guide active roadmap with:

```text
Phase 0 is accepted at 6c3e8d5afb2cc9dbf264d276796070e16aa49e55.
The active implementation slice is Phase 1 under the approved 2026-09-06
canonical-model design and implementation plan. New canonical writes remain
unavailable to production runtime roles. Public import, extraction workers,
search, Note Save integration, backup V3, and browser behavior remain in their
designated later phases. Version bumps, tags, releases, pushes, and deployments
require separate authorization.
```

- [ ] Add both new document paths to governing references. Preserve ADR 0003,
  all freeze/exclusion text, the complete README command block, and historical
  Phase 0 repair text. Mark that repair section historical; scope tests must
  verify it as historical evidence and validate the new active restriction.
  Do not delete the Phase 0 assertions or loosen their security checks.
- [ ] Run both architecture scope tests. Confirm existing Notes/Assets
  characterization passed before changing their shared constraints.
- [ ] Commit `docs(scope): authorize canonical model phase 1`.

### Task 2: Implement locators, encoding, and immutable fragments

Files: new core encoding/validation/locator/fragment files and
`source_locator_test.exs`, `document_values_test.exs`, `knowledge_properties_test.exs`.

- [ ] Add the fixed vector test before implementation:

```elixir
alias Singularity.Core.{SourceLocator, DocumentFragment}

test "text locator has stable v1 encoding" do
  input = %{"version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1}
  assert {:ok, locator} = SourceLocator.new(input)
  assert SourceLocator.to_map(locator) == input
  assert Base.encode16(SourceLocator.encode(locator), case: :lower) ==
           "000000000000000131000000000000000474657874000000000000000131000000000000000131"
end

test "fragment identity matches the independent vector" do
  assert {:ok, locator} = SourceLocator.new(%{
    "version" => 1, "kind" => "text", "start_line" => 1, "end_line" => 1
  })
  assert DocumentFragment.id(
           "00000000-0000-4000-8000-000000000001", locator, 0,
           :crypto.hash(:sha256, "hello\n")
         ) == "a5e06997d69433d9a127780ef4d01c4e7147691745f5fcac15b230d3c3e48a48"
end
```

- [ ] Add failures for every kind/field mismatch, missing range endpoint,
  reversed/negative range, invalid encoding, NUL, oversized heading, unexpected
  key, and unsupported locator version. Run the new core files; expect missing
  modules/functions, not an unrelated setup failure.
- [ ] Implement `KnowledgeEncoding.frame/1`, `SourceLocator.new/1`, `to_map/1`,
  `encode/1`, and `DocumentFragment.id/4`, `new/1` using the fixed contract.
  Fragment constructor recomputes digest/ID, verifies supplied ones if present,
  and rejects inconsistencies. Return a typed fragment with no filesystem concerns.
- [ ] Add property checks for constructor/serialization round-trip, map-order
  independence, heading NFC equivalence, and ID changes on any version, locator,
  ordinal, or text change. Do not assert probabilistic hash uniqueness generally.
- [ ] Run all new core files plus existing `resource_values_test.exs` and
  `note_values_test.exs`. Commit `feat(core): add canonical locators and fragments`.

### Task 3: Add knowledge values, commands, and repository contracts

Files: remaining new core/domain files and their mapped tests/fake.

- [ ] Add failing tests for `DocumentSource.new/1`, `DocumentVersion.new/1`,
  `DocumentCompletion.new/1`, `NoteAttachment.new/1`, `NoteCitation.new/1`,
  `NoteSourceSet.new/1`, `Tag.new/1`, `ResourceTag.new/1`, and `Relationship.new/1`.
  Verify the expected undefined-module failures with the task's test files.
- [ ] Implement the following typed data contract. Every identity tuple is
  checked for internal consistency; authorization remains storage/runtime work.

| Value | Mandatory payload beyond owner scope and private classification |
|---|---|
| DocumentSource | Asset ID, source resource/version IDs, object ID, 32-byte plaintext digest, byte size, media type |
| DocumentVersion | resource/version IDs, revision, source, title, actor ID, inserted_at, state, generation |
| DocumentCompletion | resource/version IDs, generation, outcome, adapter name, format version, and outcome-specific fields |
| NoteAttachment | Note resource/version IDs, attachment UUID, target kind/resource/version, ordinal, role `source`; optional label |
| NoteCitation | Note resource/version IDs, citation UUID, source Document resource/version, fragment ID, locator, ordinal |
| NoteSourceSet | Note identity tuple plus lists of attachments/citations and validated target/fragment values |
| Tag | tag UUID, display value, derived normalized key |
| ResourceTag | resource ID, tag ID |
| Relationship | relationship UUID, source/target IDs, type, optional target-version ID |

- [ ] `NoteSourceSet` rejects duplicate identities/ordinals and noncontiguous
  order; takes validated source values to prove resource/version/fragment/locator
  equality in pure tests. Constructors that have only IDs validate shape only;
  never claim they have looked up foreign rows. Reject self-attachments/relations.
- [ ] Implement tag key as `input |> String.trim() |> String.normalize(:nfc)
  |> :string.casefold() |> IO.chardata_to_string() |> String.normalize(:nfc)`.
  Test `Straße` and `STRASSE`, decomposed accents, invalid UTF-8, embedded controls,
  key bounds, and a forged struct's normalized key. Preserve first display spelling
  in the repository, not by mutating the incoming value.
- [ ] Use lifecycle states and fixed field rules: pending has no outcome fields;
  extracting has positive generation and adapter/format; ready has nonempty
  validated fragments, 32-byte extracted-text digest, finished time, no failure;
  failed/unsupported have a bounded code and no fragments/digest. New v1 codes are
  `invalid_utf8`, `malformed_document`, `encrypted_document`, `no_extractable_text`,
  `input_too_large`, `output_too_large`, `page_limit`, `timeout`, `extractor_failed`.
  Do not expose arbitrary extractor strings as codes.
- [ ] Define the internal domain port signatures:

```elixir
# Singularity.Domains.Documents.Repository
@callback create_pending(term(), Singularity.Domains.Documents.Command.t()) ::
  {:ok, Singularity.Core.DocumentVersion.t()} | {:error, Singularity.Core.Error.t()}
@callback get_version(term(), String.t(), String.t()) ::
  {:ok, Singularity.Core.DocumentVersion.t()} | {:error, Singularity.Core.Error.t()}
@callback claim(term(), String.t(), non_neg_integer(), String.t(), pos_integer()) ::
  {:ok, Singularity.Core.DocumentVersion.t()} | {:error, Singularity.Core.Error.t()}
@callback complete(term(), Singularity.Core.DocumentCompletion.t()) ::
  {:ok, Singularity.Core.DocumentVersion.t()} | {:error, Singularity.Core.Error.t()}
@callback reset_failed(term(), String.t(), non_neg_integer()) ::
  {:ok, Singularity.Core.DocumentVersion.t()} | {:error, Singularity.Core.Error.t()}
```

`term()` context is a documented internal map containing scoped repo, principal,
owner scope, and trusted source preparation dependencies; no public scope parameter.
`get_version` takes resource then version ID. `claim` takes version ID, expected
generation, adapter name, format version. `reset_failed` is an internal CAS only;
Phase 2 owns retry eligibility and user authorization.

- [ ] Define `Documents.Command.new/1` for create with mutation/resource/version
  UUIDs, title, source, actor, owner scope, correlation ID and timestamp. Candidate
  resource/version IDs and execution timestamps are not fingerprint inputs.
  `fingerprint_term/1` is the versioned tuple `{:document_import_v1, mutation_id,
  source_asset_id, source_resource_id, source_version_id, object_id, source_digest,
  byte_size, media_type, title, :private}`. Storage computes HMAC-SHA256 with an
  injected 32-byte secret over `:erlang.term_to_binary(term, [:deterministic])`.
  Never accept a caller-supplied fingerprint or reuse Notes receipts.
- [ ] Define `Documents.create/2` to revalidate its command, call the repository,
  and validate its returned result. The fake records exact calls and can return
  invalid results; tests prove no I/O on invalid commands.
- [ ] Define other internal ports: `KnowledgeLinks.Repository.insert_set/2`,
  `list_set/3`; `Tags.Repository.resolve/2`, `attach/3`, `detach/3`, `list/2`;
  `Relationships.Repository.relate/2`, `unrelate/2`, `outgoing/2`, `incoming/2`.
  Read results use typed lists sorted by ordinal or UUID and capped at 100 per
  internal call; public pagination/browsing is deferred. Tests assert exact
  callbacks and result types rather than adding unused public operations.
- [ ] Run new core/domain files and existing Notes domain tests. Commit
  `feat(domains): define canonical knowledge contracts`.

### Task 4: Add Document tables and preserve typed heads

Files: first migration, Document/receipt schemas, Resource/ResourceVersion mapping,
new schema/migration/grant tests, and temporary-grant support.

- [ ] Add integration tests that an ordinary runtime role cannot write any new
  canonical table/function, and that Document insertion currently fails. Add
  typed-head matrix tests before writing the migration. Run the task files and
  record missing-table/unsupported-kind failures.
- [ ] Create the first migration with `up/0`; `down/0` raises a fixed
  `Ecto.MigrationError` because this is forward-only schema evolution. Disposable
  tests restore state by dropping their isolated database, not rolling this down.
  Start by taking necessary table locks in resource, version, typed-table order;
  preflight Asset null heads and all current Note typed heads. Fail atomically on
  an invalid preexisting row, including before any constraint replacement.
- [ ] Add `content.document_versions` with these columns:

```text
resource_version_id uuid PRIMARY KEY
resource_id uuid NOT NULL
vault_id uuid NOT NULL
classification text NOT NULL CHECK (classification = 'private')
source_asset_id uuid NOT NULL
source_resource_id uuid NOT NULL
source_resource_version_id uuid NOT NULL
source_object_id uuid NOT NULL
source_digest bytea NOT NULL CHECK (octet_length(source_digest) = 32)
source_byte_size bigint NOT NULL CHECK (source_byte_size BETWEEN 0 AND 67108864)
media_type text NOT NULL
title text NOT NULL
created_by_principal_id uuid NOT NULL
state text NOT NULL DEFAULT 'pending'
attempt_generation bigint NOT NULL DEFAULT 0 CHECK (attempt_generation >= 0)
extraction_adapter text
extraction_format integer
extracted_text_digest bytea
detected_language text
failure_code text
attempt_finished_at timestamptz(6)
inserted_at timestamptz(6) NOT NULL
```

- [ ] Add a unique aggregate tuple `(resource_version_id, resource_id, vault_id,
  classification)` and deferred FK to the existing generic identity tuple. Add
  source FKs to Assets, source generic version tuple, resource_assets association,
  and object `(id,vault_id)`. The source link guard also proves that the Asset's
  own version equals the accepted source version, the source resource kind is
  Asset, its classification is private, and association/Asset/object are live at
  acceptance. Actor membership uses the existing principal/owner membership key.
  Persistent FKs must not bind to the mutable `asset_object_id` field of Assets;
  later Asset deletion must not be blocked by a newly introduced equality FK.
- [ ] Create `document_import_receipts` with primary key `(vault_id,principal_id,
  mutation_id)`, 32-byte `request_fingerprint`, pending/completed state, nullable
  result resource/version UUIDs, inserted_at, and deferred typed result FKs.
  Require null results when pending and both results when completed. A deferred
  constraint trigger rejects any pending receipt at commit.
- [ ] Replace the existing Note-only head FK with:

```sql
ALTER TABLE content.resources
  DROP CONSTRAINT resources_note_version_head_fkey,
  ADD CONSTRAINT resources_version_head_fkey
    FOREIGN KEY (current_version_id, id, vault_id, classification)
    REFERENCES content.resource_versions(id, resource_id, vault_id, classification)
    DEFERRABLE INITIALLY DEFERRED;
```

Broaden `resources_kind_check` to Asset/Note/Document and add a check requiring
Asset heads null and Note/Document heads non-null. Preserve existing head unique
keys used by Note search. Add deferred typed-head guards on resources, Note typed
  rows, and Document typed rows; guards re-query the final committed candidate state,
not obsolete NEW data from earlier queued events. Generic-only heads fail.

- [ ] Follow the existing `singularity.note.aggregate:` advisory-lock convention
  for shared resource identity guards so old Notes operations and new checks
  serialize on the same key. Before validating child kind/head existence, lock
  the parent resource consistently. For reparenting attempts, inspect both old
  and new identities and lock affected aggregate IDs in deterministic sorted
  order. Prove head changes racing typed-row deletion/retyping with two real
  database connections. Enforce Document version identity immutability
  through a new trigger; preserve the existing Note trigger and the Phase 0
  deferrable classification FK. Never create a second competing identity system.
- [ ] For each new table enable/force RLS, table-owner policy, existing owner
  predicate for web/worker, and principal predicate for receipts. Revoke PUBLIC
  and runtime DML. Do not grant production SELECT merely to simplify tests.
  The complete grant tests inspect inherited/effective privileges as well as ACLs.
- [ ] Add schemas with named constraint mappings and no general update changeset.
  Update Resource Ecto.Enum and the replaced FK mapping. Preserve existing error
  mappings for old Notes fields. Update any exact current-schema tests while
  retaining cases that reject wrong-note and wrong-owner heads.
- [ ] Run `document_schema_test.exs`, `knowledge_migration_test.exs`,
  `knowledge_grants_test.exs`, existing `note_schema_test.exs`, and the Phase 0
  cases in `migrations_test.exs`. Commit `feat(storage): add typed document identity`.

### Task 5: Add immutable fragments and guarded lifecycle

Files: second migration, fragment schema, lifecycle tests.

- [ ] Write failing SQL tests for claim, completion, failure, reset, exact replay,
  wrong generation, and direct UPDATE/DELETE denial before adding functions.
- [ ] Create `document_fragments` with fragment ID text primary key constrained
  to lowercase 64-character hex, aggregate tuple, ordinal bigint, text, 32-byte
  digest, locator JSONB, and inserted_at. Add unique `(resource_version_id,ordinal)`
  and `(id,resource_id,resource_version_id,vault_id,classification)` keys, plus
  deferred Document aggregate FK. Heading metadata comes from the canonical
  locator; do not store an independently mutable duplicate heading value.
- [ ] Add database locator validation matching core's exact fields, integer types,
  paired ranges, and bounds. Add canonical frame/locator/fragment-ID SQL helpers;
  use PostgreSQL built-in `sha256(bytea)` and `int8send(bigint)` with UTF-8 bytes,
  not session text collation. SQL tests compare the same independent vector.
  SQL NULL semantics must not turn unknown/invalid fields into passing CHECKs.
- [ ] Add state-shape constraints and functions with exact argument contracts:

```text
content.claim_document_extraction(version uuid, expected_generation bigint,
                                  adapter text, format integer) -> document_versions
content.complete_document_extraction(version uuid, generation bigint,
  fragments jsonb, extracted_digest bytea, language text) -> document_versions
content.fail_document_extraction(version uuid, generation bigint,
  outcome text, failure_code text) -> document_versions
content.reset_document_extraction(version uuid, expected_generation bigint)
  -> document_versions
```

Every function is SECURITY DEFINER with qualified names and fixed search_path,
revoked PUBLIC execution and no runtime EXECUTE grant. Derive owner/principal
from the current scope, validate active authority, then lock resource and typed
version in that order. For Phase 1 the authority check is existing active private
owner membership; public Document capability selection remains Phase 2.

- [ ] Claim requires pending and exact generation, increments once, sets adapter
  and format, and rejects bigint exhaustion. Repeating claim with the old
  generation conflicts, avoiding two callers owning the same attempt. Completion
  revalidates every fragment in SQL, locks the version, inserts the whole set,
  and moves to ready in one transaction. Compute extracted digest over text
  concatenated in ordinal order without injected separators. Compare the supplied
  digest. Ready replay compares canonical metadata and full stored fragments;
  it never inserts more fragments. Failure allows only failed/unsupported and
  clears all completion data. Reset requires one of those outcomes and exact
  generation, retains generation, clears outcome/adapter fields, and sets pending.
- [ ] Add immutable-field and state-transition triggers. Guard direct runtime
  UPDATE even if accidentally granted: lifecycle changes require the effective
  table-owner role of the guarded function, not a caller-set GUC. Superuser/table
  owner remain trusted administrative principals; do not claim tamper resistance
  against them. The role-checking trigger must be SECURITY INVOKER; a definer
  trigger would itself elevate every direct caller and defeat this check.
  Fragments reject UPDATE/DELETE and INSERT into a ready version.
  Deferred completion guard verifies no partial fragments on failed/pending
  versions and a complete nonempty set on ready versions.
- [ ] Tests grant only EXECUTE to the scoped test role, then call functions with
  correct/missing/wrong scope; this proves function authorization independently
  of normal privilege denial. Raw table constraint tests use a trusted migration
  connection in an isolated database and still verify trigger rejection.
- [ ] Separately grant direct UPDATE/DELETE to the runtime test role and prove
  it cannot bypass lifecycle guards, mutate immutable fields/fragments, or alter
  generation. Revoke all grants afterward. Verify function ownership, fixed
  search_path, live-principal authorization, and PUBLIC execution denial.
- [ ] Run lifecycle, schema, and grant files. Commit
  `feat(storage): guard document extraction lifecycle`.

### Task 6: Add source-link and organization schema

Files: third migration, six knowledge schemas, knowledge schema/RLS tests.

- [ ] Add rejection tests first: wrong Note version, wrong source tuple, wrong
  fragment or locator, self-reference, duplicate order, and cross-owner target.
- [ ] Create `note_attachments` with primary key `(note_resource_version_id,id)`,
  Note aggregate tuple, target aggregate tuple, target_kind, ordinal, role, label,
  and inserted_at. Both sides carry private classification and owner scope.
  Add typed Note FK, generic target FK, unique Note ordinal, unique Note/target
  version/role, target-kind/readiness guard, and self-attachment check.
- [ ] Create `note_citations` with primary key `(note_resource_version_id,id)`,
  Note tuple, Document source tuple, fragment ID, exact locator, ordinal, timestamp.
  Add typed Note and full fragment-tuple FKs, unique Note ordinal, and deferred
  equality check against the immutable fragment locator. Duplicate citation IDs
  across different Note versions are permitted; the same Note version cannot
  reuse one. Different citation IDs may cite the same fragment.
- [ ] Both source tables deny all production writes and write-function execution.
  UPDATE/DELETE triggers protect inserted rows; INSERT guards require a valid
  complete source set in test transactions. Do not describe row immutability as
  sealed membership: that separate Phase 4 prerequisite remains explicit.
- [ ] Create `tags(id,vault_id,classification,display_value,normalized_key,
  created_by_principal_id,inserted_at)` with private check, bounds, actor FK,
  `(id,vault_id)` uniqueness and bytewise `(vault_id,normalized_key COLLATE "C")`
  unique index. No SQL claim of full Unicode normalization equivalence.
- [ ] Create `resource_tags(resource_id,tag_id,vault_id,classification,inserted_at)`
  with owner/resource/tag PK and composite resource/tag FKs. Create
  `relationships(id,vault_id,classification,source_resource_id,target_resource_id,
  target_resource_version_id,type,created_by_principal_id,inserted_at)` with source/
  target tuples, optional target-version composite FK using MATCH SIMPLE, private
  checks, exact type allowlist, non-self check, unique owner/source/target/type,
  and owner/target/type/source incoming index. An absent target pin is allowed;
  a non-null pin must match the target resource.
- [ ] Resource/target guards verify initial private supported kinds and same scope;
  tombstoning retains rows. Add RLS to every table and deny production writes as
  in Task 4. No cascading deletion from tombstone or physical Asset cleanup.
- [ ] Run `knowledge_schema_test.exs`, `knowledge_rls_test.exs`, and grant tests.
  Commit `feat(storage): add versioned sources and organization tables`.

### Task 7: Implement the digest primitive and source-preparation contract

**Approved boundary:** implement and test the internal preparation contract with
injected test dependencies. Test the real digest primitive independently using
encrypted fixtures. Do not implement live runtime composition, a new custody
operation, or pass raw keys into storage orchestration.

Files: additive AuthenticatedReader operation, new preparation modules/source
repository, reader tests and prepare_source tests. This task can run alongside
schema tasks after Task 3.

- [ ] Add a failing `AuthenticatedReader.digest/3` test inside the existing reader
  test module so it can use its private encrypted fixture builder:

```elixir
test "digest authenticates content and final metadata", %{tmp_dir: tmp_dir} do
  bytes = :binary.copy("A", Format.chunk_size()) <> "tail"
  fixture = publish!(tmp_dir, bytes)
  assert {:ok, %{sha256: digest, byte_size: size}} =
           AuthenticatedReader.digest(fixture.storage, fixture.binding, fixture.key)
  assert digest == :crypto.hash(:sha256, bytes)
  assert size == byte_size(bytes)
end
```

- [ ] Implement digest with existing input/header/layout/stat checks, incremental
  `:crypto.hash_init/update/final`, one authenticated record at a time, and
  final-record digest/byte/chunk validation. Do not call `read(:all)` or repeatedly
  range-read without final authentication. Empty input hashes correctly. Keep
  existing `read/4` semantics untouched; add only private helpers actually shared.
- [ ] Prove corrupt middle/final record, false byte count, truncation, wrong key,
  wrong object binding, and storage failure never return a digest. A recording
  adapter proves no read requests the full ciphertext and reads are bounded by
  one chunk plus format overhead. Return only digest/size; no plaintext buffer,
  ciphertext handle, path, key, or exception detail escapes in the result.
- [ ] Implement internal `DocumentSourceRepository.load(repo, context, asset_id)` to read the private live
  Asset and exact source tuple in a scoped short transaction. Construct object
  binding using the established authorized object read/key-envelope contract.
  `PrepareSource.prepare/2` accepts a trusted digest-operation dependency, source IDs,
  and caller context; validates source size before reading; authenticates/digests
  outside the DB transaction; returns `PreparedSource` containing identity,
  digest/size/media and no key/plaintext. It returns no prepared value on failure.
  Its binding includes object generation and the live `resource_assets`
  association (`released_at IS NULL`), not just Asset/object IDs. The future live
  dependency must perform reads within runtime custody; storage must never load or unwrap
  keys, depend on runtime, or reuse a download response as a digest proof.
- [ ] The prepared value is an internal result, not an unforgeable BEAM capability.
  `DocumentRepository` receives a preparation dependency and invokes it itself;
  its public adapter entry never accepts externally manufactured digest evidence.
  Production composition is deferred to Phase 2. A fake proves only the internal
  contract; it is never evidence of live custody verification. No production
  initializer or application configuration wires this adapter. Missing digest
  dependencies return `Error.new(:storage_unavailable)` without I/O or writes;
  add a focused test for this fail-closed path.
- [ ] Recheck Asset state, source association, object identity and immutable
  binding in the later create transaction; source-change/tombstone races fail
  without receipt/data. Phase 1 does not acquire long-lived object retention or
  redesign keys. Missing authorization for the in-scope source query is a blocker;
  the deferred live digest capability is not a Phase 1 blocker.
- [ ] Run reader and prepare-source tests plus existing
  `asset_authorized_object_test.exs` in integration. Commit
  `feat(storage): define authenticated source preparation contract`.

### Task 8: Persist idempotent pending Documents and lifecycle results

Files: DocumentRepository, DocumentMutationReceipts, KnowledgeError, mapped tests
and KnowledgeFixtures. Reuse existing isolated account/Asset/Note fixture builders.

- [ ] Write pending creation, sequential/concurrent replay, changed-input conflict,
  source-race rollback, and dangling-result tests first. Expected first failure is
  missing adapter behavior. Use the same mutation with different generated
  candidate resource IDs to prove replay returns original identifiers.
- [ ] DocumentRepository separates preparation and commit: validate input and
  invoke the injected preparation contract outside any DB transaction, then use
  ScopedRepo.transact with authenticated internal context to validate source and
  claim receipt. Internal
  repository callbacks operating within the transaction must not nest ScopedRepo.
  A supplied already-open transaction at the preparation entry is invalid.
  Phase 1 exercises this composition with test-only preparation dependencies;
  no live runtime import entry point or raw-key dependency is introduced.
- [ ] Claim receipt with `INSERT ... ON CONFLICT DO NOTHING`; on existing row,
  `SELECT ... FOR UPDATE`, compare fingerprint/principal/scope, and return stored
  result. New owner locks source Asset and object using established lock order,
  rechecks association, inserts generic resource/version/typed row, sets head,
  completes receipt, and forces named deferred aggregate/result constraints before
  success. Do not mutate a completed receipt or accept a partially written result.
  Include head, source, and typed identity constraints in that explicit list;
  do not copy only the four Notes receipt constraints or force unrelated work
  with `SET CONSTRAINTS ALL`.
- [ ] Receipt result is stable accepted identity. `create_pending` replay returns
  a typed current view of that same accepted version even after its lifecycle
  advances; it never resets state. If original source is unavailable, no new import
  is accepted. Phase 1 does not promise public replay without source access.
- [ ] HMAC input uses canonical accepted fields from Task 3 and server-injected
  secret. Do not store title/text/raw secret in receipt fields or diagnostics.
  Different mutation IDs with identical source are two accepted logical Documents.
- [ ] Adapter lifecycle operations invoke only the guarded SQL functions. Map
  their stable conflict/invalid/forbidden/not-found outcomes through KnowledgeError;
  map connection failures to retryable storage_unavailable. Never include raw
  changeset, query, parameter, or database detail in Core.Error.
- [ ] Grant helper accepts explicit new table/function allowlists; it checks
  generated isolated database identity, grants only within that database, and
  uses try/after revocation. It never grants BYPASSRLS/superuser/role membership.
  All test modules using it are synchronous and call grant-denial verification
  afterward. Test-only grants may not be copied into migrations or bootstrap.
- [ ] Run repository, receipt, lifecycle, source-preparation and grants tests.
  Commit `feat(storage): persist idempotent document imports`.

### Task 9: Implement internal knowledge-link and organization adapters

Files: three knowledge adapters and their mapped tests.

- [ ] Add failing tests for atomically inserting/reading a complete source set,
  typed target validation, normalized tag replay, assignment replay, relationship
  pin conflict, and deterministic outgoing/incoming lists.
- [ ] `KnowledgeLinkRepository.insert_set/2` requires the existing outer scoped
  transaction, revalidates NoteSourceSet and database source values, then inserts
  all attachments/citations. It forces its deferred constraints before success;
  any failure returns through the outer rollback. No overwrite/update/upsert of
  an old source row is allowed. Entire equal-set replay returns existing values;
  partial or mismatched stored sets conflict. Read by exact Note resource/version.
  This adapter remains disabled by runtime grants until Phase 4 adds membership sealing.
- [ ] Tag resolve computes display/key in trusted code, inserts on owner/key
  conflict do-nothing, then fetches the established row; first accepted spelling
  and UUID win. Attach inserts on owner/resource/tag conflict do-nothing; detach
  deletes that exact assignment. Only a real mutation emits an ID-only audit.
- [ ] Relationship relate inserts on natural edge key conflict do-nothing; replay
  fetches the row and compares the optional pin. A changed pin conflicts. Unrelate
  of a missing owned edge is successful without duplicate audit. No automatic
  inferred/reverse edge is created. Incoming is a reverse query on stored directed
  edges; live lists join live source and target resources. Limit 100 and sort by
  stable UUID tuple; public cursors and browser API remain deferred.
- [ ] Use existing audit transaction pattern with operation names
  `knowledge.tag_created`, `knowledge.tag_attached`, `knowledge.tag_detached`,
  `knowledge.related`, `knowledge.unrelated`; metadata contains only UUIDs/type
  allowlist. Audit failure rolls back the canonical mutation. Validate existing
  audit shape accepts these operation names before adapter writes; do not expand
  global audit/Vault semantics to force them through.
- [ ] Run the three adapter test files, knowledge schema/RLS tests, and privacy
  tests. Commit `feat(storage): persist internal knowledge links`.

### Task 10: Prove isolation, concurrency, privacy, and compatibility

Files: new knowledge concurrency/privacy/RLS/migration/grant tests and existing
current-schema tests only when exact inventory changed.

- [ ] Concurrency fixtures use separate scoped connections, process handshakes,
  bounded lock waits and monitored process completion. No fixed sleep proves a
  race. Prove equivalent import winner/replay, mismatched request conflict,
  claim collision, ready/failure collision, reset/stale completion, and source
  deletion between authentication and create. Repeat scoped tests only when a
  code change or unresolved race concern warrants it.
- [ ] Execute the FK rejection matrix using SQL bypassing Ecto: wrong owner,
  resource, version, classification, typed kind, Note parent, source Asset version,
  Document fragment, and locator. Assert exact constraint/error code and no leaked
  committed rows. Corrupt stored prerequisites only within disposable database
  migration tests; keep ordinary tests' production constraints enabled.
- [ ] Test direct grants do not permit immutable UPDATE/DELETE or raw lifecycle
  transitions; temporary EXECUTE still enforces live scope. Test missing context,
  other owner, another principal's receipt, revoked membership, and context cleanup
  after rollback. Recheck production effective privileges after temporary revocation.
- [ ] Add privacy canaries for title, body, source filename, tag, label, and locator
  through successful and failing paths. Capture supported logger/telemetry/audit
  surfaces using existing helpers. New errors contain only code/retryability;
  no arbitrary exception inspection. Architecture tests forbid public API/job
  activation and changes to logical V1/V2 backup schemas.
- [ ] Re-run existing Notes schema/repository/receipt/concurrency/rollback and
  Asset provenance/authorized-object tests to show the generic head change and
  digest helper preserve supported behavior. Report any outside-scope failure
  and stop acceptance; do not repair it under this plan.
- [ ] Commit `test(knowledge): prove canonical model boundaries`.

### Task 11: Complete verification and independent review

- [ ] Check the full diff from `6c3e8d5` against the exact file map. Confirm three
  new migrations only, every released migration unchanged, all versions unchanged,
  and no Vault/crypto-format/job/workflow/browser/backup-format edits.
- [ ] Run format and compilation checks and commit any scoped formatting changes.
  Run the complete README development block verbatim on the clean phase HEAD:

```bash
test -z "$(git status --porcelain)"
set -o pipefail
awk '
/^## Development$/ { section = 1; next }
section && /^```bash$/ { fence = 1; next }
section && fence && /^```$/ { exit }
section && fence { print }
' README.md | bash
```

- [ ] Record final exit status and exact SHA. The full gate is explicitly required
  by the approved design: unit, isolated database, restore, JS, assets, browser,
  xref, workflow lint, diff and clean state. Focused tests do not replace it.
  Verify the service lifecycle trap completed. Stop on any failure and preserve
  the assertion; no automatic release or unrelated repair follows.
- [ ] Request independent specification and quality reviews. Supply the approved
  design, this plan, baseline/final SHAs, exact file list, gate result, and database
  privilege evidence. Review source retention/activation gates, typed-head
  concurrency, lifecycle immutability, fixture-backed source authentication,
  deferred live custody composition, and backup denial
  explicitly. Address Critical/Important findings and repeat affected checks;
  repeat the final full gate if implementation changes after its evidence.
- [ ] Produce the phase report in the task: commits, files, migrations, tests,
  commands/results, exact SHA, remaining limits, and zero Vault feature changes.
  Phase 1 is a canonical foundation with disabled production writes; report that
  limitation plainly, along with the absence of live custody integration.
  Stop for the user's integration decision.

## Specification coverage checklist

- [ ] Reused generic identity, private source model, typed head constraints: 3–4.
- [ ] Digest primitive and idempotent pending creation with test-only source
  preparation; live custody composition deferred to Phase 2: 7–8.
- [ ] Guarded lifecycle, retries, generations, atomic completion: 3, 5, 8, 10.
- [ ] Locators, stable IDs, canonical fragments: 2, 5.
- [ ] Immutable Note source links and explicit membership-sealing gate: 3, 6, 9.
- [ ] Tags, directed relations, pinned targets and backlink queries: 3, 6, 9.
- [ ] Scope isolation, grants, no production new-data writes: 4–6, 8, 10.
- [ ] Privacy, unchanged existing Notes/Assets/V1/V2 behavior: 1, 7, 10–11.
- [ ] Forward migrations, complete gate, independent review and report: 4–6, 11.
- [ ] Phase 2 retention/recovery, Phase 4 sealing, and backup activation
  prerequisites remain explicit and no later-phase public behavior was added.
