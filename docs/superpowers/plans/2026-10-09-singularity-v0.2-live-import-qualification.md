# Singularity v0.2 Live Import Qualification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development`
> or `executing-plans` to implement this plan task-by-task. The parent owns all
> Mix commands, database/services, and Git writes. Parent issued test-only GO
> after complete draft review and independent Astra review. No production
> repair is authorized by this document.

**Goal:** Qualify the existing public import path with real PostgreSQL,
OperationScope, authorization, custody, and encrypted local Asset bytes.

**Architecture:** Add one Runtime integration test file. Reuse existing public
configuration seams and real adapters, with a private fixture based on the
established encrypted-original fixture but without any precreated Document.
Production behavior, support libraries, and migrations are unchanged.

**Tech Stack:** Elixir/ExUnit, Ecto/PostgreSQL isolated test database, real
KeyCustodian/DownloadLease, ChunkedAEAD, local Asset storage.

**Design:**
`docs/superpowers/specs/2026-10-09-singularity-v0.2-live-import-qualification-design.md`.

**Status:** Test-only GO at `52d9df11bd943ab7808896be3d0c49e9c7c7808a` after
parent and independent Astra review; no new qualification tests run yet.
This is a Task 15 Step 1 supplement. Full Task 15, E2E,
and complete Phase 2 acceptance remain incomplete; E2E is NOT RUN.

---

## Ownership and execution limits

Create only:

- `apps/singularity_runtime/test/singularity/runtime/document_import_live_test.exs`

Maintain only the two qualification documents for evidence. Existing
`document_import_test.exs`, `document_api_test.exs`, shared fixtures and all
production files are read-only references. The new file belongs to the same
Runtime import contract as Task 10 and Task 15 Step 1; separating its database
lifecycle avoids expanding either existing mixed test file.

Only the parent runs commands below, serially with other service/database
work. Keep all code edits inside the test file. A production failure must
remain RED pending a separately bounded repair decision. Do not add fakes,
fallbacks, broader grants, or migrations to make the test pass.

### Task 1: Establish the live fixture and one public success contract

**Create:** `apps/singularity_runtime/test/singularity/runtime/document_import_live_test.exs`.

**Read-only references:**

- `apps/singularity_runtime/test/singularity/runtime/document_api_test.exs`:
  `empty_original_fixture!/2`, `install_live_object!/5`, `live_session/1`, and
  `grant_runtime!/1` (the fixture helpers near line 940 at the baseline).
- `apps/singularity_storage/test/support/knowledge_fixtures.ex`:
  `prepared_source!/0`; do not use the injected digest in `document_context/1`.
- `apps/singularity_storage/test/support/knowledge_test_grants.ex`.
- `apps/singularity_runtime/lib/singularity/runtime/api.ex`:
  `import_document/3` and the production closure near line 1001.
- `apps/singularity_runtime/lib/singularity/runtime/documents/import.ex` and
  `operation_scope.ex`.

- [ ] **Step 1: Add the owning module and exact real runtime map.**

Use `Singularity.Runtime.DocumentImportLiveTest`,
`use Singularity.Storage.DataCase, async: false`, `@moduletag :integration`,
and `@moduletag :tmp_dir`. Alias the modules shown here to their existing
Runtime/Storage namespaces. Build this runtime inside the private fixture:

```elixir
{:ok, authorization} =
  AuthorizationDependencies.new(%{
    store: IdentityRepository,
    custodian: {KeyCustodian, custodian}
  })

runtime = %{
  operation_scope: OperationScope,
  request_repo: RequestRepo,
  vault_lock: VaultLock,
  authorization_lock: AuthorizationLock,
  scoped_repo: ScopedRepo,
  authorizer: Authorize,
  authorization: authorization,
  audit: AuditSink,
  assets: AssetRepository,
  asset_deletions: AssetDeletionRepository,
  object_lock: ObjectLock,
  prepare_source: PrepareSource,
  document_repository: DocumentRepository,
  custodian: {KeyCustodian, custodian},
  authenticated_reader: DownloadLease,
  fingerprint_secret: :binary.copy(<<0x6D>>, 32)
}

config = %{
  import_document: fn context, attrs ->
    Singularity.Runtime.Documents.Import.run(runtime, context, attrs)
  end
}
```

- [ ] **Step 2: Build the private nonempty encrypted-Asset fixture.**

Copy only `install_live_object!/5`'s existing implementation into this new
module. Adapt `empty_original_fixture!/2` into `live_fixture!/2` taking the
test `tmp_dir` and keyword option `activate?: true`. Use
`KnowledgeFixtures.prepared_source!/0` and plaintext
`"LIVE_IMPORT_PRIVATE_BYTES_7a42\n"`; title canary is
`"LIVE_IMPORT_PRIVATE_TITLE_839c"`. Update Asset metadata size to the actual
plaintext byte size. Do not create a Document or provide a prepared digest.
Retain the real custody context and unlock fields from the reference fixture.

Return `%{source: source, plaintext: plaintext, title: title, config: config,
runtime: runtime, session: dto, context: session_context, custodian: custodian,
object_path: object_path, key_canaries: [domain_key, object_dek]}`. Here `dto` is
`struct(Singularity.Runtime.DTO.Session, Map.from_struct(session_context))`.
All fixture SQL uses `Fixtures.with_owner/1` and `query!` with correctly
dumped UUIDs. Source owner/principal/account/session/object IDs are text UUIDs.
Set up `asset.read` only, unless a deletion case explicitly requests
`asset.write`; read session epochs/expiration from fixture-consistent values.
Keep ExUnit's temporary directory and owned supervision cleanup local.

The fixture must assert its initial owner has zero Document resources,
Document versions, receipts, and extraction events before invoking import.
This catches accidental reuse of the precreated-Document reference fixture.

- [ ] **Step 3: Add SQL observation helpers with owner-filtered results.**

Implement private `import_rows/1` using `Fixtures.with_owner/1`, returning
the actual rows from `content.resources` with `kind='document'`,
`content.resource_versions` joined to those resources,
`content.document_versions`, `content.document_import_receipts`, and
`core.outbox_events` filtered by owner and
`event_type='document.extraction_requested'`. Include fragment, search,
job-submission and Oban rows for that owner in a separate effects snapshot.
Use exact row lists/counts, not unfiltered database totals. Read the existing
schemas for foreign-key/filter columns rather than inventing them.

Wrap scenario execution as follows; assert canonical write privileges are
false before and after, and do not manually nest a SQL transaction around it:

```elixir
KnowledgeTestGrants.with_grants(
  ~w(document_versions document_import_receipts),
  fn ->
    KnowledgeTestGrants.with_receipt_grants(fn ->
      assert {:ok, document} = Api.import_document(f.config, f.session, attrs)
      assert document.source.digest == :crypto.hash(:sha256, f.plaintext)
      assert document.source.byte_size == byte_size(f.plaintext)
      assert document.source.object_id == f.source.object_id
      assert document.source.asset_id == f.source.asset_id
      assert document.source.resource_id == f.source.resource_id
      assert document.source.resource_version_id == f.source.resource_version_id
      assert document.owner_scope_id == f.source.vault_id
      assert document.state == :pending
      assert document.generation == 0
      assert document.resource_id != f.source.resource_id
      assert document.resource_version_id != f.source.resource_version_id
    end)
  end
)
```

`attrs` is `%{asset_id: f.source.asset_id, title: f.title,
mutation_id: Ecto.UUID.generate()}`. Persisted assertions must match one
completed receipt pointing to the returned IDs and one extraction payload:

```elixir
assert payload == %{
  "resource_id" => document.resource_id,
  "resource_version_id" => document.resource_version_id
}
```

Assert immutable pin, digest and size match returned data; fragments/search
and new jobs remain absent. In a fresh `RequestRepo.checkout/1`, assert
`refute RequestRepo.in_transaction?()` and that current owner/principal
settings are nil or empty, as required by `ScopedRepo`.

- [ ] **Step 4: Run the first characterization contract.**

Parent runs from the Phase 2 worktree:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_import_live_test.exs --seed 41123 --trace
```

Expected: the new test executes, not excluded, and passes if the existing
composition satisfies the approved contract. This is characterization: do
not manufacture RED by deliberately breaking production. If the valid test
fails, retain its assertion and stop for diagnosis. Correct fixture-only
mistakes inside this file; do not change production behavior.

### Task 2: Add replay and authorization/authentication refusal contracts

**Modify:** only the new live import test file.

- [ ] **Step 1: Add exact and changed replay assertions.**

Within the grant wrapper, import with `title: "  " <> f.title <> "  "`, then
replay using canonical `f.title` and string request keys. Assert identical
Document result and unchanged canonical/extraction-event snapshot. Capture
`audit.events` for the owner's `operation='asset.downloaded'`; assert replay
does not add downloads. Do not hard-code the first import's download count.

```elixir
assert {:ok, ^document} = Api.import_document(f.config, f.session, %{
  "asset_id" => f.source.asset_id,
  "title" => f.title,
  "mutation_id" => attrs.mutation_id
})
assert {:error, :conflict} =
  Api.import_document(f.config, f.session, %{attrs | title: f.title <> " changed"})
assert {:error, :conflict} =
  Api.import_document(f.config, f.session, %{attrs | asset_id: Ecto.UUID.generate()})
```

- [ ] **Step 2: Add real cross-owner refusal.**

Build a second independently valid live fixture under another child of the
test directory, with its own session/custodian and owner. Call its real API
config using the first fixture's Asset ID and a fresh mutation. Require
`{:error, :not_found}`; both owners' import effects remain zero. Do not merely
replace the owner ID inside the first session.

- [ ] **Step 3: Add locked custody and revoked session refusal.**

For locked custody, build `live_fixture!(tmp_dir, activate?: false)` but keep
the DTO `unlocked?: true`, then require `{:error, :vault_locked}`. For a
separate revoked-session case, activate normally and execute fixture SQL:

```elixir
Fixtures.with_owner(fn ->
  query!(MigrationRepo,
    "UPDATE identity.sessions SET revoked_at=CURRENT_TIMESTAMP WHERE id=$1",
    [Ecto.UUID.dump!(f.source.session_id)])
end)
assert {:error, :unauthenticated} =
  Api.import_document(f.config, f.session, attrs)
```

Both cases require zero canonical/receipt/extraction-event writes and no
fragments/search/job effects. Audit denial rows may be added and are subject
to privacy assertions; do not incorrectly require zero audit activity.

- [ ] **Step 4: Add real ciphertext authentication refusal.**

After the fixture is ready, flip one ciphertext byte in its exact
`object_path` using the following test-only action. Finalization makes this
file read-only; the permission change is confined to the test-owned file.

```elixir
<<first, rest::binary>> = File.read!(f.object_path)
File.chmod!(f.object_path, 0o600)
File.write!(f.object_path, <<Bitwise.bxor(first, 1), rest::binary>>)
assert {:error, :integrity_failure} =
  Api.import_document(f.config, f.session, attrs)
```

Keep expected ciphertext hash and size metadata unchanged. Require zero
import effects. An unexpected code, success, exception, or partial write is
RED; do not broaden the accepted error list to obtain green.

- [ ] **Step 5: Run only the new file again with seed 41123.**

Use Task 1 Step 4's command. Expected: every added case executes and passes.
Stop on a valid behavioral failure; keep ordinary fixture repair separate
from any proposed production repair.

### Task 3: Prove replay after the real logical deletion transition

**Modify:** only the new live import test file.

- [ ] **Step 1: Add a real deletion case with its existing capability.**

Grant `asset.write` only to this fixture principal using the established
capability-assignment SQL pattern. After successful import, read the Asset's
current state revision and call the real use case:

```elixir
assert {:ok, _deleted} =
  Singularity.Runtime.Assets.Delete.run(
    f.runtime, f.context, f.source.asset_id, current_state_revision)
assert {:ok, ^document} = Api.import_document(f.config, f.session, attrs)
assert {:error, :conflict} =
  Api.import_document(f.config, f.session, %{attrs | title: f.title <> " changed"})
```

Verify actual `content.tombstones` and released `content.resource_assets`
state. Require the same completed receipt, Document IDs, source digest and
pin, one extraction event, unchanged ciphertext/object availability, and no
new download audit after deletion. Filter import effects separately from
legitimate Asset deletion audit/outbox effects. Do not run cleanup workers;
cleanup collision and retained-original read tests remain separate owners.

- [ ] **Step 2: Run the new file with seed 41123.**

Expected: replay succeeds despite the persisted Asset deletion, with no new
import effects. A valid failure is handed back as RED without altering the
deletion, receipt, or custody implementations.

### Task 4: Capture real privacy surfaces and close bounded evidence

**Modify:** only the new test file and these qualification documents.

- [ ] **Step 1: Capture side channels around actual import calls.**

Use `ExUnit.CaptureLog.capture_log/1`. Attach a uniquely named telemetry
handler to actual query event names from RequestRepo, WorkerRepo,
MigrationRepo, and DispatcherRepo plus existing authorization-denial runtime
events. Record complete metadata with a test-owned token; detach with
`on_exit/1` and after normal completion. Attach after fixture SQL. Once the
grant wrappers unwind, run this explicit real denial as a capture control:

```elixir
assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
  Singularity.Storage.SafeSQL.query(
    WorkerRepo,
    "SELECT title FROM content.document_versions WHERE title=$1",
    [f.title]
  )
```

Require the actual `[:singularity, :authorization, :rls_denial]` event with
`%{count: 1}` and `%{repo: :worker}` from this control. Drain before observation
SQL. Do not attribute the control event to import. RequestRepo's existing
`default_options/1` and SafeSQL set `telemetry_event: nil`; query capture can
legitimately be empty. Report that as query metadata not produced, while
the real denial proves the listener was active. Do not enable query telemetry
or claim positive query-metadata coverage from an empty capture.
Follow the established capture pattern in
`document_extraction_job_test.exs` without editing that file.

For first import, replay, and failure scenarios inspect captured logs,
metadata, public error terms, actual owner-filtered audit metadata, complete
outbox rows, and any owner job rows. Test distinct plaintext, title, and key
canaries in both raw and inspected/encoded representations; use
`inspect(value, limit: :infinity, printable_limit: :infinity)`. Do not scan
authorized success results for their intentionally returned title/digest.
Inspect actual query metadata if emitted, including real SQL parameters.
A content leak is a genuine RED result; do not silence
the event, alter logging/telemetry settings, filter out the metadata, or
replace it with a fabricated safe example.

Require exact extraction payload keys and unchanged job counts. Report that
this test does not execute a dispatcher or prove newly produced Oban args;
those remain owning dispatch/worker matrix assertions. Do not fabricate a
job row or synthetic metadata value to claim live privacy evidence.

- [ ] **Step 2: Run focused verification and one deterministic repeat.**

Parent runs these commands serially from the worktree:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_runtime/test/singularity/runtime/document_import_live_test.exs
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_import_test.exs --seed 41123
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_import_live_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs --seed 41123 --trace
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_import_live_test.exs --seed 90731 --trace
git diff --check
```

Expected: all selected cases execute and pass, temporary canonical writes
are revoked, and the diff is confined to the allowlist. No unbuffer command
is used because the approved local environment does not provide it. Record
actual test/exclusion counts rather than predicting them. A failure in an
existing regression is reported and stops this slice; do not repair it here.

- [ ] **Step 3: Record and hand back the exact result.**

Record baseline/final SHA, changed files, commands, seeds, executed counts,
sanitized failures if any, and grant restoration evidence. Mark only the
bounded live import qualification PASS/FAIL/BLOCKED as justified. Preserve
Task 15, E2E and Phase 2 as incomplete. No production changes, migrations,
Vault feature work, production grants, release, push, merge or deployment
are permitted. The parent handles any separately authorized local commit
after review; this plan does not issue Git writes.
