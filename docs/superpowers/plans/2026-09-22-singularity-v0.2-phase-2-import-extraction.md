# Singularity v0.2 Phase 2 Document Import and Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import an authenticated Asset as a durable Document, extract bounded PDF/Markdown/text into immutable fragments, and expose safe lifecycle and source reads.

**Architecture:** Extend the guarded Phase 1 Document aggregate and its source pin. Storage owns atomic retention, attempts, receipts, and backup refusal; Ingest/Core own deterministic extraction; Runtime composes the existing authorization and key machinery with one narrowly Document-scoped lease path and IDs-only jobs.

**Tech Stack:** Elixir umbrella, Ecto/PostgreSQL/RLS, Oban/outbox, encrypted Asset storage, Poppler `pdfinfo`/`pdftotext` through `ex_cmd` 0.18, Nix/Docker, ExUnit.

---

## Authority, order, and worktree

The approved spec is `docs/superpowers/specs/2026-09-22-singularity-v0.2-phase-2-import-extraction-design.md`, including its approved Document-pinned custody amendment at `eeb8c3b`, the three narrow implementation-boundary amendments approved on 2026-09-23 (Poppler process bridge, Document binding resolver, Document envelope codec case), the native Poppler process-group guardian approved on 2026-09-23, and the explicit guardian control protocol approved on 2026-09-28. Execute only on `codex/v0.2-phase-2-import-extraction` in `.trees/v0.2-phase-2-import-extraction`. Do not edit released migrations. Do not alter Vault files, unlock/key derivation/capability policy, or existing Asset lease semantics. `asset.read` remains the sole read capability. No push, tag, release, or deployment.

Phase 2 is one dependent vertical slice, not independent products: retention, backup refusal, and abandoned-attempt recovery must exist before exposing import. Do not deploy or activate production Document writes until Tasks 2–14 and the Task 15 gate pass; earlier task tests use only temporary disposable-database grants. Existing Phase 1 repository tests and V1/V2 backup fixtures remain required assertions; add tests rather than deleting or weakening them.

Run each command from the Phase 2 worktree. Use `devenv shell --` for Mix and Poppler checks. A focused test is evidence for its task only; complete acceptance is Task 15.

## File and responsibility map

| Unit | Files | Responsibility |
| --- | --- | --- |
| Canonical attempt | New `apps/singularity_storage/priv/repo/migrations/20260922000100_document_extraction_attempts.exs` and `20260922000200_document_extraction_recovery.exs`; existing `apps/singularity_storage/lib/singularity/storage/schema/content/document_version.ex`, `apps/singularity_core/lib/singularity/core/document_version.ex`, `apps/singularity_storage/lib/singularity/storage/postgres/document_repository.ex` | Fixed deadline, logical-job fence, recovery, immutable completion. |
| Retention and source | `apps/singularity_storage/lib/singularity/storage/postgres/asset_deletion_repository.ex`; new `apps/singularity_storage/lib/singularity/storage/postgres/document_pinned_source.ex` | Count all Document pins and authorize retained object by Document, not live Asset. |
| Custody | `apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex`, `key_lease.ex`, `download_lease.ex`, `apps/singularity_storage/lib/singularity/storage/postgres/custody_repository.ex`, new forward migration `20260922000250_document_custody_binding.exs`, `config/config.exs` | Document-specific binding through existing 60-second lease, worker-only binding proof, chunk revalidation and revocation. |
| Extraction | New `apps/singularity_core/lib/singularity/core/document_fragmentation.ex`, `apps/singularity_ingest/lib/singularity/ingest/documents/text.ex`, `markdown.ex`, `pdf.ex`, `poppler.ex`; `apps/singularity_ingest/mix.exs`, `mix.lock`, `devenv.nix`, `Dockerfile` | Normalization, semantic blocks, bounded non-shell Poppler and deterministic locators. |
| Import and lifecycle | `apps/singularity_domains/lib/singularity/domains/documents.ex` and `documents/repository.ex`; `apps/singularity_storage/lib/singularity/storage/postgres/document_repository.ex`; new `apps/singularity_storage/priv/repo/migrations/20260922000300_document_runtime_mutations.exs`, `apps/singularity_runtime/lib/singularity/runtime/documents/import.ex`, `read.ex`, `mutate.ex`; `apps/singularity_runtime/lib/singularity/runtime/api.ex` | Authenticated APIs, receipt/outbox atomicity, bounded reads, retry/delete/restore. |
| Jobs/recovery | New `apps/singularity_runtime/lib/singularity/runtime/documents/extract.ex` and `extraction_reconciler.ex`; `job_dispatcher.ex`, `outbox_dispatcher.ex`, `application.ex`; `apps/singularity_storage/lib/singularity/storage/jobs/oban_adapter.ex`, `envelope_codec.ex`; `config/config.exs` | IDs-only dispatch and strict codec, custody defer, fenced completion/exhaustion, periodic expiry. |
| Backup | `apps/singularity_storage/lib/singularity/storage/backup/exporter.ex` and `apps/singularity_core/lib/singularity/core/error.ex` | Fail closed with a distinct `backup_unsupported` code on owner-scoped canonical rows absent from V2. Do not change `logical_schema_v2.ex`. |

The table is a change map, not permission for a broad refactor. Keep new files single-purpose and use existing patterns. The plan below names the focused test home for each change.

### Task 1: Record the Phase 1 characterization baseline

**Files:** Read `README.md`, `apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs`, `apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs`, `apps/singularity_storage/test/singularity/storage/object_cleanup_concurrency_test.exs`, `apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs`, and `apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs`. Modify only the active-slice paragraph of `AGENTS.md` after the user approves execution.

- [ ] **Step 1: Verify isolation and baseline commit.** Run:

```sh
git status --short --branch
git rev-parse HEAD
```

Expected: clean `codex/v0.2-phase-2-import-extraction` at or after `eeb8c3b`.

- [ ] **Step 2: Run focused established contracts.** Run:

```sh
devenv shell -- mix test apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs apps/singularity_storage/test/singularity/storage/object_cleanup_concurrency_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs
devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs
```

Expected: pass. If baseline fails, diagnose that failure before edits; do not change unrelated code or claim Phase 2 evidence.

- [ ] **Step 3: Record the execution boundary.** After the user approves this plan's execution, change `AGENTS.md` so its active slice names Phase 2 and cites the approved spec and this plan. Keep its historical Phase 0/1 notes and all other constraints. The replacement active-slice text is:

```markdown
Phase 1 is accepted locally at
`a80957da41582de40bdf586a0cba1e14644acf0a`. The active implementation
slice is Phase 2 under
`docs/superpowers/specs/2026-09-22-singularity-v0.2-phase-2-import-extraction-design.md`
and
`docs/superpowers/plans/2026-09-22-singularity-v0.2-phase-2-import-extraction.md`.
Later phases still require separate approved designs and detailed plans.
Version bumps, tags, releases, pushes, and deployments remain separately gated.
```

Run `git diff --check` and commit this documentation-only change as `docs(knowledge): activate phase 2 implementation guidance`. Do not make this edit while the plan itself is awaiting execution choice.

### Task 2: Refuse unsupported V1/V2 backups before Document writes

**Files:** Modify `apps/singularity_storage/lib/singularity/storage/backup/exporter.ex`, `apps/singularity_core/lib/singularity/core/error.ex`, and only the public error allowlist in `apps/singularity_runtime/lib/singularity/runtime/backup_vault.ex`; add forward migration `apps/singularity_storage/priv/repo/migrations/20260922000000_backup_unsupported_guard.exs`. Test `apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs`, `apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs`, and `apps/singularity_core/test/singularity/core/error_test.exs`. Preserve `apps/singularity_storage/lib/singularity/storage/backup/logical_schema_v2.ex` byte-for-byte.

**Approved privilege amendment:** The migration adds a backup-only, owner-scoped `SECURITY DEFINER` boolean predicate, owned by `singularity_table_owner`, with a fixed search path. It verifies `core.live_principal_authorization()` for the requested scope, live principal and membership, and `backup.create`; unauthorized callers fail closed. It executes the eight owner-scoped `EXISTS` checks below in the caller's repeatable-read snapshot. Revoke EXECUTE from PUBLIC, web, and other runtime roles; grant only `singularity_worker` EXECUTE. Do not grant worker broad SELECT on new canonical tables. Test with temporary grants only for fixture writes, then remove them before real worker-role checks; prove legacy-only success and unsupported-row refusal without those grants.

- [ ] **Step 1: Add the failing integration test.** In a scoped repeatable-read cut fixture, create one Phase 1 Document with `KnowledgeFixtures.prepared_source!/0` and `DocumentRepository.create_pending/2` under temporary test grants. Assert `Exporter.snapshot_cut/2` returns a sanitized unsupported error for that owner, while an unrelated owner and the existing Notes/Assets fixture still export. Add one test for a non-Document Phase 1 canonical row absent from V2. Add a `BackupVault` test proving the public operation reports the same code and does not publish a bundle. Use the same transaction and grants pattern already in `logical_exporter_test.exs`.

```elixir
assert {:error, %Singularity.Core.Error{code: :backup_unsupported}} =
         Exporter.snapshot_cut(repo, owner_scope_id)
refute inspect(Exporter.snapshot_cut(repo, owner_scope_id)) =~ document.title
```

- [ ] **Step 2: Prove red.** Run `devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs`; plain `mix test` excludes this module's `:integration` tag. Expected: the new unsupported-row assertion fails because V2 currently returns a cut.

- [ ] **Step 3: Implement the guard at both cut and record entrypoints.** Add `:backup_unsupported` to the closed `Core.Error` code/type list and assert its constructor returns empty message/details. In `Exporter.snapshot_cut/2`, call a private `reject_unsupported_canonical_rows/2` before object inventory. Repeat the check in `records/2` under the same exported database snapshot. The predicate is vault-scoped and checks every Phase 1 table omitted by `LogicalSchemaV2`; use `EXISTS` rather than streaming content. Do not include legacy V2-represented Note/Asset rows. Return only `Error.new(:backup_unsupported)`, with no row text or SQL detail. Use this complete table inventory from the Phase 1 migrations:

```sql
SELECT EXISTS (
  SELECT 1 FROM content.document_versions WHERE vault_id = $1
) OR EXISTS (
  SELECT 1 FROM content.document_fragments WHERE vault_id = $1
) OR EXISTS (
  SELECT 1 FROM content.document_import_receipts WHERE vault_id = $1
) OR EXISTS (
  SELECT 1 FROM content.note_attachments WHERE vault_id = $1
) OR EXISTS (
  SELECT 1 FROM content.note_citations WHERE vault_id = $1
) OR EXISTS (
  SELECT 1 FROM content.tags WHERE vault_id = $1
) OR EXISTS (
  SELECT 1 FROM content.resource_tags WHERE vault_id = $1
) OR EXISTS (
  SELECT 1 FROM content.relationships WHERE vault_id = $1
);
```

Do not alter the V2 wire schema. The guard must run under the backup's repeatable-read snapshot and before any bundle is published.

- [ ] **Step 4: Prove green and commit.** Run `devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs` and `devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs apps/singularity_core/test/singularity/core/error_test.exs`; expected: new refusal and old successful exports pass. Then:

```sh
git add apps/singularity_core/lib/singularity/core/error.ex apps/singularity_core/test/singularity/core/error_test.exs apps/singularity_runtime/lib/singularity/runtime/backup_vault.ex apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs apps/singularity_storage/lib/singularity/storage/backup/exporter.ex apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/priv/repo/migrations/20260922000000_backup_unsupported_guard.exs docs/superpowers/specs/2026-09-22-singularity-v0.2-phase-2-import-extraction-design.md docs/superpowers/plans/2026-09-22-singularity-v0.2-phase-2-import-extraction.md
git commit -m "fix(backup): refuse unsupported canonical document rows"
```

### Task 3: Pin original objects across Asset deletion and cleanup

**Files:** Modify `apps/singularity_storage/lib/singularity/storage/postgres/asset_deletion_repository.ex`; add forward migration `apps/singularity_storage/priv/repo/migrations/20260922000050_document_source_pin_count.exs`. Test `apps/singularity_storage/test/singularity/storage/orphan_cleanup_test.exs`, `apps/singularity_storage/test/singularity/storage/object_cleanup_concurrency_test.exs`, and `apps/singularity_storage/test/singularity/storage/roles_test.exs`.

- [ ] **Step 1: Add failing pin and race tests.** Create a Document from an available Asset, delete that Asset, run its cleanup job, and assert the object remains `available` with ciphertext intact. Repeat with the Document tombstoned. Race import against cleanup with two tasks and a barrier around their source/object locks; assert either a committed Document pin and retained object or an atomic import rejection with no receipt. Never accept a committed Document pointing at deleted bytes.

```elixir
assert {:ok, document} = DocumentRepository.create_pending(context, command)
assert {:ok, _asset} = delete_asset_and_finish_cleanup(asset_id)
assert object_lifecycle(document.source.object_id) == :available
assert original_ciphertext_exists?(document.source.object_id)
```

The helper names above belong only in the test module and must be implemented there using its existing deletion fixtures; do not add production shortcuts.

- [ ] **Step 2: Prove red.** Run `devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/orphan_cleanup_test.exs apps/singularity_storage/test/singularity/storage/object_cleanup_concurrency_test.exs`. Plain `mix test` excludes these `:integration` modules. Expected: the new pin/race assertions fail before the retention predicate is changed.

- [ ] **Step 3: Change one shared retention decision.** Make `live_object_references/2` and the final cleanup recheck count `content.document_versions.source_object_id` for the same object and owner, irrespective of `resources.deleted_at`. Preserve the existing Asset → object lock order and the final object-locked reference check before physical delete. Use the same predicate in retain/schedule, claim, and acknowledgement paths; no fast path may inspect only Assets.

```sql
SELECT count(*) FROM content.document_versions
WHERE source_object_id = $1 AND vault_id = $2;
```

The total reference count is existing live Asset references plus this count. No permanent Document purge or new object store is added.

The count uses a forward-only `content.document_source_pin_count(uuid,uuid)`
security-definer function owned by `singularity_table_owner`, with a fixed
search path and `EXECUTE` granted only to `singularity_worker`. It grants no
direct Document table read. The function binds the current owner-scope GUC,
requires a live principal and membership, and accepts only the two existing
worker cleanup identities: the deleting user's `asset.write` path or the named
`object_cleanup` principal returned by `core.object_cleanup_authorization`.
Unauthorized calls raise rather than returning zero. A roles catalog contract
checks owner, definer settings, and exact worker-only privilege.

- [ ] **Step 4: Prove green and commit.** Run the two focused files above plus `apps/singularity_storage/test/singularity/storage/roles_test.exs` and `apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs` with `devenv shell -- mix singularity.test.integration`; expected: pass. Commit only the Task 3 repository, migration, docs, and focused tests as `fix(storage): retain document-pinned source objects`.

### Task 4: Add database-owned attempt identity, deadline, and expiry

**Files:** Create `apps/singularity_storage/priv/repo/migrations/20260922000100_document_extraction_attempts.exs`. Modify `apps/singularity_storage/lib/singularity/storage/schema/content/document_version.ex`, `apps/singularity_core/lib/singularity/core/document_version.ex`, `apps/singularity_storage/lib/singularity/storage/postgres/document_repository.ex`, `apps/singularity_domains/lib/singularity/domains/documents/repository.ex`. Test `apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs` and `apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs`.

- [ ] **Step 1: Write the failing lifecycle cases.** Claim with `job_id` A, assert start/deadline are database timestamps exactly 180 seconds apart, resume A without generation change, reject B, reject stale A after expiry, recover the row to `pending` with generation incremented, and reject every old completion/failure. Also assert ready replay requires the same job and exact content, terminal rows preserve the source pin, and a newly claimed job can finish. Use a transaction-scoped clock control or a test-only deadline update under table-owner privileges; never sleep 180 seconds.

```elixir
assert {:ok, %{generation: 1, attempt_job_id: ^job_a}} =
         DocumentRepository.claim(context, version_id, 0, job_a, "plain-text", 1)
assert {:error, %Error{code: :conflict}} =
         DocumentRepository.claim(context, version_id, 0, job_b, "plain-text", 1)
assert {:ok, %{state: :pending, generation: 2}} =
         DocumentRepository.recover_expired(context, version_id, 1)
```

- [ ] **Step 2: Prove red.** Run the two focused files. Expected: compile failure for the new method/arity, then failing deadline and ownership assertions as each layer is added.

- [ ] **Step 3: Add a forward-only migration and guarded SQL.** Add `attempt_job_id uuid`, `attempt_started_at timestamptz(6)`, and `attempt_deadline_at timestamptz(6)`. Create new guarded claim, complete, fail, and reset signatures in this migration and drop the old signatures after updating tests/callers; leaving an old definer function would bypass job ownership. Never edit `20260906000200_create_document_fragments_and_lifecycle.exs`. Revoke PUBLIC on the new functions and grant only the narrow worker/runtime roles after backup guard/retention are proven. The claim's required update is:

```sql
UPDATE content.document_versions
SET state = 'extracting',
    attempt_generation = attempt_generation + 1,
    attempt_job_id = claim_job_id,
    attempt_started_at = claim_time,
    attempt_deadline_at = claim_time + interval '180 seconds',
    extraction_adapter = adapter,
    extraction_format = format
WHERE resource_version_id = version
  AND state = 'pending'
  AND attempt_generation = expected_generation;
```

Declare `claim_time timestamptz := clock_timestamp()` once in the actual function. Same-job resume returns only an unexpired extracting row and does not extend its deadline. A new completion/failure compares state, generation, job ID, and unexpired deadline under the row lock. An exact replay of an already-ready result compares job/generation/content but does not reject merely because wall time passed after sealing. A terminal ready/failed/unsupported row retains its attempt job ID/start/deadline for replay and exhaustion fencing; `pending` requires all three to be null. Expiry atomically sets `pending`, increments generation, clears attempt fields, and rejects stale completion. New `reset_document_extraction(version, expected_generation, new_adapter, new_format)` SQL allows `failed` with the same pair but `unsupported` only if the pair differs, and clears all attempt/result fields. Update the lifecycle trigger/state-shape constraints and Core/Schema fields accordingly. Keep immutable source fields unchanged. Preserve the intent of existing Phase 1 reset tests by asserting the stricter Phase 2 eligibility, not by deleting them.

- [ ] **Step 4: Wire repository contracts.** Use these exact public storage signatures and update the domain behaviour:

```elixir
claim(context, version_id, expected_generation, job_id, adapter, format)
complete(context, job_id, %DocumentCompletion{})
recover_expired(context, version_id, expected_generation)
reset_failed(context, version_id, expected_generation, new_adapter, new_format)
```

Replace the old `reset_failed/3` callback and update its focused tests to pass the selected adapter/format; never keep a callable old SQL or Elixir path that bypasses unsupported eligibility. Validate canonical UUID job IDs and strip database exception messages through `KnowledgeError`.
When `DocumentVersion.new/1` validates terminal content, pass only the original completion fields to `DocumentCompletion.new/1`; attempt job/timestamps are lifecycle metadata and must not be mistaken for completion input.

- [ ] **Step 5: Prove green and commit.** Run the two focused files plus `devenv shell -- mix test apps/singularity_core/test/singularity/core/document_values_test.exs`; expected: pass, including old immutability contracts. Commit migration, four modules, and tests as `feat(storage): fence document extraction attempts`.

### Task 5: Deterministic plain text and Markdown fragmentation

**Files:** Create `apps/singularity_core/lib/singularity/core/document_fragmentation.ex`, `apps/singularity_core/test/singularity/core/document_fragmentation_test.exs`, `apps/singularity_ingest/lib/singularity/ingest/documents/text.ex`, `apps/singularity_ingest/lib/singularity/ingest/documents/markdown.ex`, `apps/singularity_ingest/test/singularity/ingest/documents/text_test.exs`, `markdown_test.exs`.

- [ ] **Step 1: Add pure red tests.** Test LF/NFC normalization, UTF-8 rejection, paragraph and heading blocks, stable heading paths, exact text line ranges, 65,536-byte Unicode-safe splitting, ordinal fallback when splitting destroys an exact range, 16 MiB/4096-fragment limits, and identical reruns. Use literal vectors:

```elixir
assert {:ok, [first, second]} =
         DocumentFragmentation.build(identity(), "text/plain", [
           %{text: "one\n", locator: %{version: 1, kind: "text", start_line: 1, end_line: 1}},
           %{text: "two\n", locator: %{version: 1, kind: "text", start_line: 3, end_line: 3}}
         ])
assert {first.ordinal, second.ordinal} == {0, 1}
assert first.fragment_id != second.fragment_id
assert {:error, {:unsupported, "invalid_utf8"}} = Text.extract(<<255>>)
```

`identity/0` is a test helper returning the exact `resource_id`, `resource_version_id`, `owner_scope_id`, and `classification: :private` fields required by `DocumentFragment.new/1`.

- [ ] **Step 2: Prove red.** Run `devenv shell -- mix test apps/singularity_core/test/singularity/core/document_fragmentation_test.exs apps/singularity_ingest/test/singularity/ingest/documents/text_test.exs apps/singularity_ingest/test/singularity/ingest/documents/markdown_test.exs`. Expected: new modules missing.

- [ ] **Step 3: Implement exact pure contracts.** `Text.extract/1` and `Markdown.extract/1` return `{:ok, [%{text: binary, locator: map}]}` or `{:error, {:unsupported, allowlisted_code}}`. Validate `String.valid?/1` before normalization. Normalize CRLF/CR to LF, then NFC. Split on blank lines while retaining source line accounting; Markdown ATX headings push/pop a heading path, and fenced code remains one semantic block. `DocumentFragmentation.build/3` returns `{:ok, [DocumentFragment.t()]}`, splits blocks on grapheme boundaries without crossing the byte limit, uses a `fragment` ordinal locator if a split has no defensible source range, assigns contiguous ordinals, checks count/total bytes, and rejects empty output. The worker computes `:crypto.hash(:sha256, Enum.map(fragments, & &1.text))` for `DocumentCompletion`. The internal extraction tuple is not a public `Core.Error`; the worker translates its code to a `DocumentCompletion.failure_code`.

```elixir
defp normalize_utf8(bytes) when is_binary(bytes) do
  if String.valid?(bytes) do
    {:ok,
     bytes
     |> String.replace("\r\n", "\n")
     |> String.replace("\r", "\n")
     |> String.normalize(:nfc)}
  else
    {:error, {:unsupported, "invalid_utf8"}}
  end
end
```

Never place text or heading paths in an exception or log. Keep these modules free of Ecto/Runtime dependencies.

- [ ] **Step 4: Prove green and commit.** Run the three new files plus `devenv shell -- mix test apps/singularity_core/test/singularity/core/document_values_test.exs`. Expected: pass. Commit the six new files as `feat(ingest): fragment text and markdown documents`.

### Task 6: Bounded Poppler PDF extraction and runtime dependency parity

**Files:** Create `apps/singularity_ingest/lib/singularity/ingest/documents/poppler.ex`, `apps/singularity_ingest/lib/singularity/ingest/documents/pdf.ex`, `apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs`, and bounded PDF fixtures under `apps/singularity_ingest/test/fixtures/documents/`. Modify `apps/singularity_ingest/mix.exs`, `mix.lock`, `devenv.nix`, and `Dockerfile`. No OCR or persistent plaintext file.

- [ ] **Step 1: Add failing fixture tests.** Cover two-page text, encrypted/password-protected, malformed, empty/scanned, 4097-page, output over 16 MiB, process timeout, unexpected exit, invalid UTF-8, and safe stderr handling. Inject a process runner for timeout/error tests; run real `pdfinfo` and `pdftotext` for multipage fixture acceptance. Assert page numbers and monotone character ranges or ordinal fallback. Keep encrypted/malformed fixtures small and committed as binary fixtures; never embed their contents in logs.

```elixir
assert {:ok, [%{locator: %{page: 1}}, %{locator: %{page: 2}}]} =
         PDF.extract(
           File.read!("apps/singularity_ingest/test/fixtures/documents/two_pages.pdf"),
           runner: Poppler
         )
assert {:error, {:unsupported, "encrypted_document"}} =
         PDF.extract(
           File.read!("apps/singularity_ingest/test/fixtures/documents/encrypted.pdf"),
           runner: Poppler
         )
```

The extraction error above is an internal Ingest classification, not a new `Core.Error` code: use `{:error, {:unsupported | :failed, allowlisted_code}}` and map it to Phase 1's allowlisted `failure_code` at the worker boundary.

- [ ] **Step 2: Prove red.** Run `devenv shell -- mix test apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs`. Expected: missing module or executable before implementation.

- [ ] **Step 3: Implement a non-shell, bounded runner.** Add `{:ex_cmd, "~> 0.18.0"}` only to Ingest and update `mix.lock`. Resolve executable names once via `System.find_executable/1` and require absolute resolved paths. Use `ExCmd.Process` without a shell to run `pdfinfo -` for encryption/page count and `pdftotext -enc UTF-8 -eol unix -q - -` for text. Feed at most 64 MiB through stdin, close stdin independently, demand-read at most 16 MiB of stdout, and disable stderr. Enforce a hard 120-second wall-clock budget while writing/reading, not only while awaiting exit; terminate and reap the direct child and any descendants on timeout, excess output, or caller cancellation. `ExCmd.Process` is owner-linked: run it under an isolated monitored owner so abnormal process exit cannot kill the calling worker. Never persist plaintext or pass title, file path, or password as process arguments. Preserve Poppler page form-feed separators, normalize each page to NFC/LF, and reject a document with no text. Check actual page count before extraction and enforce at most 4096. Classify exit/timeout without copying process output to errors. The stdin/stdout `-` interface and page-break behavior are documented by [Debian's pdftotext manual](https://manpages.debian.org/testing/poppler-utils/pdftotext.1.en.html); `pdfinfo -` is documented by [Debian's pdfinfo manual](https://manpages.debian.org/testing/poppler-utils/pdfinfo.1.en.html). [ExCmd.Process](https://hexdocs.pm/ex_cmd/ExCmd.Process.html) documents independent stdin closure, demand reads, ownership, and teardown. Real-process tests must prove the installed package and bounded teardown behave accordingly.

  Build a small bundled native guardian during normal Mix/release/container compilation; do not commit its binary under source `priv`. `ExCmd.Process` owns the guardian directly, but ExCmd 0.18 may force-stop that child with `SIGKILL`, so cleanup must not depend on ExCmd delivering `SIGTERM`. Use one versioned, magic, fixed-width big-endian length frame for a payload of at most 64 MiB; reject malformed, short, and oversized frames. The guardian starts the resolved Poppler executable directly, without a shell, in a dedicated target process group, proxies exactly the declared payload through its own pipe, closes Poppler stdin, and keeps its outer ExCmd stdin open as a cancellation channel. Transfer the outer stdin to a persistent writer process that sends the frame and stays alive until asked to close it. Premature outer-stdin EOF makes the guardian TERM/KILL the entire owned target group, wait for and reap all descendants, and exit before the controller calls bounded ExCmd teardown. Normal target exit makes the guardian reap and exit while the control channel remains open. Demand-read stdout from a separate process in chunks no larger than 65,531 bytes. The controller monitors the caller and hard wall clock across write, read, and await; timeout, output overflow, pipe error, or caller death closes the control channel, permits bounded guardian cleanup and reader EOF, and only then awaits the guardian. Treat failed cleanup as process failure. Add native-boundary malformed-frame tests and real subprocess tests in which the target spawns a grandchild; prove repeatedly that both child and grandchild are gone after timeout and caller cancellation. Package only the minimal compiler/build input needed by Nix and Docker.

```elixir
@source_limit 67_108_864
@text_limit 16_777_216
@page_limit 4_096
@timeout_ms 120_000
@pdfinfo_args ["-"]
@pdftotext_args ["-enc", "UTF-8", "-eol", "unix", "-q", "-", "-"]
```

- [ ] **Step 4: Package and verify executable parity.** Add `poppler_utils` to the stable Nix package list and `poppler-utils` to the runtime Docker apt list. Check `devenv shell -- command -v pdfinfo` and `devenv shell -- command -v pdftotext`; both must resolve. Build the Docker image at the current SHA and run `pdfinfo -v`/`pdftotext -v` inside it; do not publish it.

- [ ] **Step 5: Prove green and commit.** Run the PDF test file and `devenv shell -- mix test apps/singularity_ingest/test/singularity/ingest/documents/`. Expected: pass. Commit only PDF modules/tests/fixtures, Ingest dependency/lockfile, and Nix/Docker changes as `feat(ingest): add bounded poppler document extraction`.

### Task 7: Read a pinned source without requiring the Asset to remain live

**Files:** Create `apps/singularity_storage/lib/singularity/storage/postgres/document_pinned_source.ex` and `apps/singularity_storage/test/singularity/storage/postgres/document_pinned_source_test.exs`. Do not loosen `apps/singularity_storage/lib/singularity/storage/postgres/document_source_repository.ex`, which remains the live-Asset import proof.

- [ ] **Step 1: Write failing storage tests.** Create a Document, logically delete its source Asset, and assert the new lookup returns only its immutable `source_object_id`, object generation, byte size, digest, media type, and owner-scoped reader binding. Cross-owner/missing scope and tombstoned-Document public lookup return `not_found`. Internal worker lookup accepts a live pending version for its authorized extraction event or a tombstoned version only when the same job owns an active claim. A source-object mismatch returns `integrity_failure`.

```elixir
assert {:ok, %{object_id: pinned_id, source_digest: digest}} =
         DocumentPinnedSource.load_live(repo, context, document.resource_id)
assert pinned_id == document.source.object_id
assert digest == document.source.digest
```

- [ ] **Step 2: Prove red.** Run `devenv shell -- mix test apps/singularity_storage/test/singularity/storage/postgres/document_pinned_source_test.exs`. Expected: missing module.

- [ ] **Step 3: Implement narrow lookups.** Expose `load_live/3` for a live Document and `load_for_job/4` for a version/event-job pair. Join `content.document_versions` to its own `content.resources` and the pinned `content.asset_objects` tuple under RLS. `load_live/3` requires `resources.deleted_at IS NULL`; `load_for_job/4` accepts a live pending Document only for an authorized extraction event, or a tombstone only when the same job owns an active claim. Neither query filters on `content.resource_assets.released_at` nor source Asset state. Validate UUIDs, classification, and object lifecycle; return only an internal descriptor, not key material.

```sql
SELECT d.source_object_id, d.source_digest, d.source_byte_size, d.media_type,
       o.object_generation
FROM content.document_versions AS d
JOIN content.resources AS r ON r.id = d.resource_id AND r.vault_id = d.vault_id
JOIN content.asset_objects AS o ON o.id = d.source_object_id AND o.vault_id = d.vault_id
WHERE d.resource_id = $1 AND d.vault_id = $2
  AND r.kind = 'document' AND r.deleted_at IS NULL
  AND o.lifecycle = 'available';
```

Use the corresponding version/job/event predicate for `load_for_job/4`; do not reuse the live-only SQL verbatim.

- [ ] **Step 4: Prove green and commit.** Run the new test, `document_repository_test.exs`, and the two object-cleanup tests. Expected: source survives deleted Asset, scope remains enforced, old import proof tests still pass. Commit as `feat(storage): read document-pinned source objects`.

### Task 8: Narrow Document lease with unchanged key and capability semantics

**Files:** Modify `apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex`, `apps/singularity_runtime/lib/singularity/runtime/key_lease.ex`, `apps/singularity_runtime/lib/singularity/runtime/download_lease.ex`, `apps/singularity_storage/lib/singularity/storage/postgres/custody_repository.ex`, and `config/config.exs`. Add forward migration `apps/singularity_storage/priv/repo/migrations/20260922000250_document_custody_binding.exs`. Test new `apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs` plus existing `apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs` and an isolated worker-role privilege test.

- [ ] **Step 1: Add failing custody contracts.** A request with `purpose: :document_source`, exact Document version/object/generation, job ID, owner/principal epochs, and `required_capability: "asset.read"` gets a 60-second lease only while an authorized session is unlocked. Missing key, mismatched object/version, revoked principal/session, changed authorization epoch, or deleted original object refuses or revokes. A deleted Asset with a live pinned Document still reads; a deleted Document is unavailable for a new public lease. Read 64 MiB at most and assert a digest mismatch is surfaced as sanitized integrity failure before claim. A public Document download uses a session-bound `DownloadLease` and stops between chunks when that session locks. Existing Asset metadata/download tests must remain unchanged.

```elixir
assert {:error, :waiting_for_unlock} = KeyCustodian.lease(custodian, document_request)
unlock_existing_session()
assert {:ok, lease} = KeyCustodian.lease(custodian, document_request)
assert {:ok, first_chunk} = KeyLease.read_chunk(lease, 0)
refute first_chunk == ""
```

- [ ] **Step 2: Prove red.** Run `devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs`. Expected: the new purpose is rejected.

- [ ] **Step 3: Add only the Document binding path.** `KeyCustodian.lease/2` accepts `purpose: :document_source` with exact-key validation and selects an existing unlocked session using the same revocation checks as `:metadata`. Because `singularity_worker` has no direct Document-version `SELECT`, the new forward migration provides a fixed-search-path, `singularity_table_owner`-owned `SECURITY DEFINER` predicate callable only by `singularity_worker`. It returns only whether the exact scoped owner/principal, version, pinned object/generation and either live request or current job/event/claim authorize this binding; it must not return wrapped keys, plaintext, or broad canonical rows. Revoke PUBLIC and other runtime-role EXECUTE, prove direct worker SELECT still fails, and use the predicate inside `CustodyRepository` to resolve the existing DEK and revalidate the binding plus principal epochs before each chunk. Do not grant worker broad canonical-table SELECT. Add a versioned `document_source_v1` checkpoint in existing `jobs.job_progress`, binding `job_id`, `resource_version_id`, owner/principal and authorization epochs, object ID/generation, and next chunk index. Its CAS rejects a changed Document version or object even if a process resumes. `KeyLease.read_chunk/2` retains its existing 60-second expiry, chunk CAS, and best-effort revocation behavior; do not relax its generic authorization. The Document request has this shape:

```elixir
%{
  purpose: :document_source,
  access: :worker,
  job_id: envelope.job_id,
  resource_version_id: version_id,
  vault_id: envelope.vault_id,
  principal_id: envelope.principal_id,
  required_capability: "asset.read",
  principal_authorization_epoch: envelope.principal_authorization_epoch,
  vault_authorization_epoch: envelope.vault_authorization_epoch,
  object_id: descriptor.object_id,
  object_generation: descriptor.object_generation
}
```

For public original download, the same `:document_source` purpose has an exact-key `access: :request` variant: replace `access: :worker` and `job_id` with `access: :request` and `session_id: session.session_id`, retaining the Document version/object/owner/epochs and `asset.read` fields. Validate the two shapes separately. Use the existing one-use `DownloadLease` shape with a Document-pinned reader binding; add a Document-only chunk method that keeps authorization/revocation checks between chunks while leaving Asset `read/2` unchanged. No worker job ID or checkpoint is accepted from a caller. Do not introduce a new capability, change the meaning of `asset.read`, or edit Vault modules. Keep plaintext in a bounded in-memory buffer only until the worker has authenticated SHA-256; release/revoke the worker lease before Poppler runs.

- [ ] **Step 4: Prove green and commit.** Run `devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs apps/singularity_runtime/test/singularity/runtime/key_lease_test.exs apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs`, the isolated worker-role privilege test, and `devenv shell -- mix xref graph --format cycles --fail-above 0`. Expected: pass, zero cycles, unchanged Asset lease behavior. Commit only custody, the new migration, and tests as `feat(runtime): lease document-pinned source reads`.

### Task 9: Emit exactly one extraction event with the import receipt

**Files:** Modify `apps/singularity_storage/lib/singularity/storage/postgres/document_repository.ex`, `apps/singularity_storage/test/singularity/storage/postgres/document_mutation_receipts_test.exs`, `apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs`, and test grants in `apps/singularity_storage/test/support/knowledge_test_grants.ex` only as required. Use existing `apps/singularity_storage/lib/singularity/storage/schema/core/outbox_event.ex`.

- [ ] **Step 1: Add failing receipt/event tests.** New import produces one `document.extraction_requested` event with payload exactly `%{"resource_id" => id, "resource_version_id" => version_id}`. Same mutation replay, including candidate UUID changes, produces no second event. Changed title conflicts. Force event insertion failure and assert no Document/receipt remains. The event's owner/principal authorization epochs come from `core.live_principal_authorization()` inside the transaction; job arguments contain only identifiers.

```elixir
assert {:ok, document} = DocumentRepository.create_pending(context, command)
assert [%{"resource_id" => id, "resource_version_id" => version_id}] =
         extraction_event_payloads(context.owner_scope_id)
assert {id, version_id} == {document.resource_id, document.resource_version_id}
assert {:ok, ^document} = DocumentRepository.create_pending(context, command)
assert length(extraction_event_payloads(context.owner_scope_id)) == 1
```

- [ ] **Step 2: Prove red.** Run `devenv shell -- mix test apps/singularity_storage/test/singularity/storage/postgres/document_mutation_receipts_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs`. Expected: the new event count assertion fails.

- [ ] **Step 3: Insert within the receipt's creation callback.** In `DocumentRepository.create_pending/2`, after `persist/2` and before receipt completion, insert one `OutboxEvent.create_changeset/2` with `event_type: "document.extraction_requested"`, `required_capability: "asset.read"`, `classification: :private`, `causation_id: command.mutation_id`, `expected_entity_revision: 0`, and a stable owner-scoped idempotency key derived from the immutable version ID. Fetch epochs as NoteRepository does; do not copy title, digest, source locator, or plaintext into payload. On replay, do not execute this callback.

```elixir
payload = %{
  "resource_id" => command.resource_id,
  "resource_version_id" => command.resource_version_id
}
```

Preserve Phase 1 source revalidation and the existing internal test asserting replay fails when the original Asset binding has been released; the public replay-after-deletion behavior is implemented separately in Task 10.

- [ ] **Step 4: Prove green and commit.** Run the two files above and `devenv shell -- mix test apps/singularity_storage/test/singularity/storage/documents/prepare_source_test.exs`. Expected: pass. Commit as `feat(storage): schedule document extraction atomically`.

### Task 10: Public authenticated import and replay after Asset deletion

**Files:** Create `apps/singularity_runtime/lib/singularity/runtime/documents/import.ex` and `apps/singularity_runtime/test/singularity/runtime/document_import_test.exs`. Modify `apps/singularity_runtime/lib/singularity/runtime/api.ex` and `apps/singularity_domains/lib/singularity/domains/documents.ex`. Extend `apps/singularity_storage/lib/singularity/storage/postgres/document_repository.ex` with `find_import_receipt_scoped/3`; do not change the Phase 1 internal `create_pending/2` replay rule.

- [ ] **Step 1: Add failing Runtime tests.** An authenticated unlocked session imports only `asset_id`, `title`, and `mutation_id`; Runtime creates resource/version/correlation IDs, obtains the existing key lease and real digest operation, and calls the Phase 1 repository. Same mutation, Asset ID, and canonical title returns the original Document even after source Asset deletion; changed title or Asset ID conflicts without reading deleted bytes. Cross-owner, locked, unsupported media, and forged owner/source fields fail with sanitized errors. No event is created by a replay.

```elixir
assert {:ok, first} =
         Api.import_document(runtime, session, %{
           asset_id: asset_id, title: "  Notes  ", mutation_id: mutation_id
         })
delete_source_asset(asset_id)
assert {:ok, ^first} =
         Api.import_document(runtime, session, %{
           asset_id: asset_id, title: "Notes", mutation_id: mutation_id
         })
```

- [ ] **Step 2: Prove red.** Run `devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_import_test.exs`. Expected: missing API.

- [ ] **Step 3: Implement the request and receipt path.** Add `Api.import_document/2` and config-seam `/3`. Use `OperationScope.with_shared_request/4` with `asset.read` and authenticated `SessionContext`. Before source preparation, do a scoped receipt lookup keyed by principal/owner/mutation; if it exists, compare the canonical title and requested Asset ID to its retained immutable Document source and return its established identity, including after Asset deletion. If absent, return `{:after_commit, fn -> ... end}` from the authorized callback so all source preparation runs outside its transaction while the authorization lock remains held. In that callback use the existing session-bound live-Asset `:download` lease to compute the actual digest, construct `Documents.Command` from trusted values, then call `DocumentRepository.create_pending/2`, which performs its own preparation and revalidates inside its own transaction. Do not use the new Document-pinned lease before a Document exists. Reject unknown/duplicate atom/string input keys. Do not accept caller-provided owner, source version, digest, object ID, or attempt generation.

```elixir
OperationScope.with_shared_request(runtime, session, requirement, fn repo ->
  case DocumentRepository.find_import_receipt_scoped(repo, session, mutation_id) do
    {:ok, document} -> compare_replay(document, asset_id, title)
    {:error, %Error{code: :not_found}} ->
      {:after_commit,
       fn -> create_from_live_source(runtime, session, asset_id, title, mutation_id) end}
    {:error, %Error{}} = error -> error
  end
end)
```

`compare_replay/3` and `create_from_live_source/5` are private functions in the new import module. `find_import_receipt_scoped/3` accepts only the already-scoped repository handle from `OperationScope`; it does not open a nested transaction. `create_from_live_source/5` makes an independent, scoped source-preparation call before constructing the command; `create_pending/2` deliberately rechecks it rather than trusting public input. The real digest operation uses the existing Asset `:download` custody path for the still-live Asset. It must not be a test-only injected digest in production.

- [ ] **Step 4: Prove green and commit.** Run the new Runtime test, storage receipt test, and `devenv shell -- mix test apps/singularity_domains/test/singularity/domains/documents_test.exs`. Expected: pass. Commit the Runtime/domain/storage changes and tests as `feat(runtime): import authenticated documents`.

### Task 11: Route the IDs-only event through Oban

**Files:** Modify `apps/singularity_runtime/lib/singularity/runtime/outbox_dispatcher.ex`, `apps/singularity_storage/lib/singularity/storage/jobs/oban_adapter.ex`, `apps/singularity_storage/lib/singularity/storage/jobs/envelope_codec.ex`, and `config/config.exs`. Test `apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs` and `apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs`.

- [ ] **Step 1: Add failing dispatch tests.** Dispatch `document.extraction_requested` and assert one `document_extract` job with `JobEnvelope.job_id == outbox_event.id` and payload exactly the two UUIDs. Re-dispatch the same event and assert the same runner submission. Reject unknown/extra payload keys and ensure no title, digest, text, or locator reaches job args. Test the durable codec with both `document-extraction:<version>` at revision zero and `document-extraction:<version>:<generation>` at positive matching revision; reject mismatched keys, capability, classification, and noncanonical UUIDs.

```elixir
assert %JobEnvelope{
         job_type: "document_extract",
         payload: %{"resource_id" => ^resource_id, "resource_version_id" => ^version_id}
       } = submitted_envelope()
```

- [ ] **Step 2: Prove red.** Run the two focused files. Expected: event/job type has no route.

- [ ] **Step 3: Add only this route.** Add `"document.extraction_requested" => "document_extract"` to the outbox mapping, strict payload validation for exactly two canonical UUIDs, `"document_extract" => :document_extract` to `ObanAdapter.@queues`, and `document_extract: 2` to configured Oban queues. Extend only `EnvelopeCodec`'s closed allowlist and per-job contract for the exact IDs-only payload, private classification, `asset.read`, and the initial/recovered idempotency-key forms above. Preserve every existing job contract and the generic worker. Never put bytes or titles in `payload`.

```elixir
defp envelope_payload("document_extract", %{
       "resource_id" => resource_id,
       "resource_version_id" => version_id
     } = payload)
     when map_size(payload) == 2 and is_binary(resource_id) and is_binary(version_id) do
  {:ok, payload}
end
```

Also validate each UUID with `Ecto.UUID.cast/1` in this Runtime boundary; the guard above alone is insufficient.

- [ ] **Step 4: Prove green and commit.** Run the focused dispatch/adapter tests and `devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/job_restart_test.exs`. Expected: pass. Commit as `feat(jobs): route document extraction events`.

### Task 12: Worker extraction, custody deferral, and terminal failure fencing

**Files:** Create `apps/singularity_runtime/lib/singularity/runtime/documents/extract.ex` and `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`. Modify `apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex` and `application.ex`, and `apps/singularity_storage/lib/singularity/storage/postgres/document_repository.ex` for `record_exhaustion/4`.

- [ ] **Step 1: Add failing worker tests with fakes and real storage.** Cover text/Markdown/PDF ready result, duplicate logical job resume, custody unavailable before claim → `{:snooze, 60}` and `pending`, digest mismatch before claim → sanitized incident with no attempt, transient post-claim failure → `failed`/`timeout` or `extractor_failed`, deterministic unsupported outcomes, worker kill after claim, and an already-claimed worker finishing after deletion. A stale logical job/generation cannot write ready or failure. On final Oban exhaustion, only the current claimed job/generation records `failed`; an unclaimed locked job, recovered generation, or ready result is unchanged. Assert no search rows appear on a failed attempt.

```elixir
assert {:snooze, 60} = Extract.run(context, envelope)
assert {:ok, %{state: :pending, generation: 0}} =
         DocumentRepository.get_version(repository_context, resource_id, version_id)
assert {:ok, %{state: :ready, fragments: [_ | _]}} =
         run_after_unlock(context, envelope)
```

`run_after_unlock/2` is a local test helper that unlocks the existing session then calls `Extract.run/2`; it must not bypass custody in production.

- [ ] **Step 2: Prove red.** Run `devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`. Expected: missing handler/route.

- [ ] **Step 3: Implement the five-stage worker.** (1) Validate the IDs-only envelope and authorization via `Authorize.check_job/3`; (2) read and authenticate at most 64 MiB through the Document lease, checking SHA-256 against the pin before claim; (3) claim/resume via Task 4's job/generation fence; (4) extract outside the transaction with Task 5/6 adapters; (5) build `DocumentCompletion` and complete/fail in one scoped transaction. Never hold a PostgreSQL transaction while reading ciphertext or invoking Poppler. `{:error, :waiting_for_unlock}` returns `{:snooze, 60}` without a claim; use existing wake plumbing so a later unlock resumes. Digest mismatch returns sanitized `integrity_failure` and leaves `pending`, without attempting untrusted bytes. The post-claim completion path must load canonical rows by job/generation even if `resources.deleted_at` became non-null; public `get_version/3` stays live-only.

```elixir
case custodian.lease(custodian_context, request) do
  {:error, :waiting_for_unlock} -> {:snooze, 60}
  {:ok, lease} -> read_verify_claim_extract_complete(context, envelope, lease)
  {:error, %Error{}} = error -> error
end
```

`read_verify_claim_extract_complete/3` is private in the new worker. It returns `{:ok, DocumentVersion.t()}`, `{:snooze, 1 | 60}`, or a sanitized `{:error, %Error{}}`. Map internal extraction reasons only to Phase 1's allowlisted `failure_code` and `failed`/`unsupported`; never pass Poppler output or stderr through `Error.message`/`details`.

- [ ] **Step 4: Wire terminal handling.** Add `document_extract` to `JobDispatcher.handle/2` and the job dependency map. Add a `handle_failure/4` clause that calls `DocumentRepository.record_exhaustion/4` only for a terminal Oban failure and only if `attempt_job_id == envelope.job_id`, state is `extracting`, and generation matches. `GenericWorker` already invokes the terminal handler; do not modify its normalization. A custody snooze is not an error and cannot mark `failed`.

- [ ] **Step 5: Prove green and commit.** Run `devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs`. Expected: pass, unchanged Asset behavior. Commit as `feat(runtime): extract document jobs with fenced outcomes`.

### Task 13: Periodic recovery of expired attempts

**Files:** Create `apps/singularity_runtime/lib/singularity/runtime/documents/extraction_reconciler.ex`, `apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs`, and `apps/singularity_storage/priv/repo/migrations/20260922000200_document_extraction_recovery.exs`. Modify `apps/singularity_runtime/lib/singularity/runtime/application.ex` and `apps/singularity_storage/lib/singularity/storage/postgres/document_repository.ex`. Task 4's migration remains untouched after commit.

- [ ] **Step 1: Add failing restart/race tests.** Seed an `extracting` row whose DB deadline is past, restart the Runtime supervisor, and assert one new IDs-only event plus a `pending` row with advanced generation. Run two reconcilers concurrently and assert one transition/event. Unexpired, ready, deleted-before-claim, and key-locked pending rows produce no duplicate work. A stale worker cannot complete or fail after the recovery commit.

```elixir
assert {:ok, 1} = ExtractionReconciler.run(context)
assert {:ok, 0} = ExtractionReconciler.run(context)
assert {:ok, %{state: :pending, generation: 2}} =
         DocumentRepository.get_version(repo_context, resource_id, version_id)
assert length(recovery_events(version_id)) == 1
```

- [ ] **Step 2: Prove red.** Run `devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs`. Expected: missing reconciler/repository method.

- [ ] **Step 3: Implement bounded periodic recovery.** A supervised GenServer runs once at startup and at a bounded cadence (for example, 30 seconds), claiming at most 100 expired rows per pass. A narrowly granted database function enumerates only expired version/owner IDs; it never exposes text. Each owner-scoped transaction locks a row, verifies `attempt_deadline_at < clock_timestamp()`, advances generation, resets to `pending`, and inserts one new outbox event tied to the new generation. Do not depend on Oban job status. Repeated/concurrent passes are idempotent through row lock + generation and outbox idempotency key. Schedule recovery even if key custody is locked; the new worker can snooze safely.

```sql
UPDATE content.document_versions
SET state = 'pending', attempt_generation = attempt_generation + 1,
    attempt_job_id = NULL, attempt_started_at = NULL, attempt_deadline_at = NULL,
    extraction_adapter = NULL, extraction_format = NULL
WHERE resource_version_id = $1
  AND state = 'extracting'
  AND attempt_generation = $2
  AND attempt_deadline_at < clock_timestamp();
```

Ensure SQL recovery and successor outbox insertion commit together. If the original principal is no longer authorized, leave the expired row fenced by its deadline and retry the recovery pass when current authorization is restored; do not advance state without a successor event, manufacture an epoch, or broaden capability. This special case must have a focused test.

- [ ] **Step 4: Prove green and commit.** Run the new reconciler test plus `document_lifecycle_test.exs` and `job_restart_test.exs`. Expected: pass. Commit as `feat(runtime): recover abandoned document extraction`.

### Task 14: Bounded reads, manual retry, logical delete, and restore

**Files:** Create `apps/singularity_runtime/lib/singularity/runtime/documents/read.ex`, `mutate.ex`, `apps/singularity_runtime/test/singularity/runtime/document_api_test.exs`, and `apps/singularity_storage/priv/repo/migrations/20260922000300_document_runtime_mutations.exs`. Modify `apps/singularity_runtime/lib/singularity/runtime/api.ex`, `apps/singularity_domains/lib/singularity/domains/documents.ex` and `documents/repository.ex`, `apps/singularity_storage/lib/singularity/storage/postgres/document_repository.ex`. Do not edit Phase 1 migrations.

- [ ] **Step 1: Add failing API tests.** Test get/list with a hard page-size cap and stable cursor; pending/ready/failed/unsupported status; ordered fragments only for live ready version; original download from pinned object after Asset deletion; cross-owner and tombstoned ordinary reads denied. Test deletion hides all reads immediately but preserves version/fragments/bytes. Restore keeps the same identity, re-exposes ready data, and emits exactly one event only for pending or eligible failed/unsupported. Same-adapter retry accepts transient failed and refuses unsupported; changed adapter/format allows unsupported retry. Duplicate retry/delete/restore is idempotent, with no duplicate outbox event. Assert request maps cannot choose owner, digest, object, or generation.

```elixir
assert {:ok, %{items: [_], next_cursor: _}} = Api.list_documents(runtime, session, %{limit: 1})
assert {:ok, [first | _]} = Api.document_fragments(runtime, session, document.resource_id)
assert first.ordinal == 0
assert :ok = Api.delete_document(runtime, session, document.resource_id)
assert {:error, %Error{code: :not_found}} =
         Api.document_fragments(runtime, session, document.resource_id)
```

- [ ] **Step 2: Prove red.** Run `devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_api_test.exs`. Expected: missing API functions.

- [ ] **Step 3: Implement read operations.** Add paired public/config seam functions to `Api`: `get_document`, `list_documents`, `document_status`, `document_fragments`, and `download_document_original`. Use `OperationScope.with_read_request/4` and `SessionContext`-derived scope. Storage queries order list by a stable tuple and cap `limit` to 1..100; never expose tombstoned rows through live APIs. Fragments are ordered by ordinal, only when the complete version is `ready`. Original read authenticates the pinned object under Task 8's Document lease and checks its immutable digest before success; no Asset-liveness query. Return a bounded stream/reader: first preflight the at-most-64-MiB pin/digest under an authorized one-use Document download lease without returning bytes, then acquire a fresh session-bound Document lease for chunk delivery. The immutable object binding and per-chunk authorization are rechecked throughout, so expiry/revocation stops the stream; a preflight digest mismatch returns a sanitized error and yields zero chunks.

- [ ] **Step 4: Implement mutations atomically.** Add `retry_document`, `delete_document`, and `restore_document` through `OperationScope.with_shared_request/4` with current authorization. Repository row-locks the Document, checks state/generation and adapter/format eligibility, applies the transition, and inserts one IDs-only event in the same transaction when required. Do not reopen `ready`. For unsupported retry, compare current adapter/format version to the stored pair; for failed retry, permit same pair. Logical delete sets `resources.deleted_at` without deleting version, fragment, receipt, or source pin. Restore clears that marker and schedules only eligible non-ready work. Add narrowly scoped definer functions/grants in the new forward migration for resource tombstone/restore and retry reset; do not grant direct UPDATE/DELETE on versions/fragments. Repeated delete/restore/retry observes the already-applied state and emits no second event, using a deterministic transition-specific outbox idempotency key; no new mutation-receipt table is needed. Caller-supplied state or source identity is rejected.

```elixir
eligible? =
  case document.state do
    :failed -> true
    :unsupported ->
      {document.adapter_name, document.format_version} != {current_adapter, current_format}
    _ -> false
  end
```

- [ ] **Step 5: Prove green and commit.** Run `devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs`. Expected: pass. Commit as `feat(runtime): expose document lifecycle and source reads`.

### Task 15: Security matrix and complete Phase 2 acceptance gate

**Files:** Extend focused tests from Tasks 2–14 where a coverage gap remains. Record results in the implementation handoff; do not mark the plan complete on a focused green subset.

- [ ] **Step 1: Execute the adversarial matrix.** Cover all approved fixtures and races, including cross-owner authorization, RLS/definer grants, forged source proof, object cleanup collision, stale completion, timeout, 4096/4097 pages, 16 MiB output boundary, 4096/4097 fragments, malformed/encrypted/scanned PDF, invalid UTF-8, locked custody, revocation, deleted Asset, tombstoned Document, and V2 backup refusal. Assert no user content in logs, telemetry metadata, audit metadata, outbox payload, Oban args, or public error details. No failed attempt leaves fragments or search rows. Add each missing assertion to its owning test file before running the gate.

```elixir
refute inspect(job.args) =~ secret_text
refute inspect(outbox.payload) =~ secret_text
assert [] == search_rows_for(document.resource_id)
```

- [ ] **Step 2: Run the complete README gate in its documented order.** Run:

```sh
devenv up -d
devenv processes wait --timeout 120
devenv shell -- bash apps/singularity_storage/priv/repo/bootstrap_roles.sh
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
nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/release.yml
git diff --check
git status --short
```

Expected: every command passes, including E2E and zero cycles. If any required check fails, stop acceptance, diagnose within Phase 2 scope, and rerun the affected focused check and entire failed gate. Do not waive E2E or call a partial run accepted.

- [ ] **Step 3: Record an exact-SHA handoff.** Run `git rev-parse HEAD`, `git status --short`, and `git log --oneline` for Phase 2 commits. Report changed files, new migrations, every gate command/result, remaining risks, and explicit confirmation that no Vault feature work, V3 backup, search projection, Note Save, release, push, or deployment occurred. Implementation acceptance and merge are separate decisions.
