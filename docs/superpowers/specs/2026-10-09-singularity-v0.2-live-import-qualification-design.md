# Singularity v0.2 Live Import Qualification Design

Date: 2026-10-09
Status: Independently reviewed; parent Test GO under standing approval.
This document authorizes no production
change. Baseline inspected: `52d9df11bd943ab7808896be3d0c49e9c7c7808a` in
`.trees/v0.2-phase-2-import-extraction`.

## Purpose and authority

This is a bounded characterization supplement to Phase 2 Task 15 Step 1 in
`2026-09-22-singularity-v0.2-phase-2-import-extraction.md`. Its purpose is to
qualify the existing public Document import composition with real PostgreSQL,
authorization, custody, and local encrypted bytes. It adds no import behavior.

The identified issue is a coverage gap, not a demonstrated production defect.
`document_import_test.exs` calls `Api.import_document/3` with substitutes for
scope, preparation, repository, Asset lookup, custody, reader, and audit. The
storage tests authenticate repository inputs through an injected digest
operation. The live empty-original fixture in `document_api_test.exs` supplies
real encrypted bytes and custody but precreates a Document and substitutes
`LiveReadScope`. Those tests do not establish that the complete public import
path works with the real `OperationScope` after-commit lifecycle.

Standing approval permits routine choices inside the approved test slice.
Parent read the complete design and plan. A separate Astra reviewer found no
Critical or Important issue and issued Test GO after tracing the real adapters,
temporary grants, deletion path, and denied SafeSQL telemetry control. A
valid new contract that fails against production code is handed back as RED
with diagnosis; this plan does not authorize a production repair.

## Options and decision

1. **Recommended: one new focused integration file.** Create
   `apps/singularity_runtime/test/singularity/runtime/document_import_live_test.exs`.
   It owns only public import composition and a small private encrypted-Asset
   fixture. Keep the existing 403-line fast import tests and 1,206-line API
   tests unchanged. This isolates the database lifecycle and preserves the
   existing owning contracts without a shared-fixture refactor.
2. Append a second integration module to `document_import_test.exs`. This is
   valid ownership but mixes independent test lifecycles and makes the file
   considerably larger. It offers no additional evidence.
3. Reuse `LiveReadScope` or call `DocumentRepository.create_pending/2` directly.
   This is insufficient: it repeats the existing seam coverage and bypasses
   the transaction/authorization composition under qualification.

Only the new test file and these two qualification documents may change in
the proposed implementation. Existing test support, production modules,
configuration, dependencies, migrations, and existing assertions remain
outside this supplement's edit scope. Reading their APIs is necessary.

## Real composition

The entrypoint is the existing explicit-config public facade:

```text
Api.import_document(config, DTO.Session, attrs)
  -> Documents.Import.run(runtime, SessionContext, attrs)
  -> OperationScope.with_shared_request
     -> VaultLock + AuthorizationLock + ScopedRepo + Authorize
     -> live IdentityRepository and real KeyCustodian
     -> receipt lookup, commit, after_commit_scoped callback
  -> PrepareSource -> DocumentSourceRepository
  -> Assets.Download -> OperationScope.with_read_request
     -> AssetRepository -> KeyCustodian -> DownloadLease
        -> CustodyReader/CustodyRepository -> ChunkedAEAD/local ciphertext
  -> Documents.create -> DocumentRepository.create_pending
     -> real preparation again, source revalidation, receipt, immutable pin,
        one document.extraction_requested outbox event
```

Use the same closure shape as the production config in `Api`; do not invoke
the global production-config facade or mutate application environment. Set
every relevant runtime adapter explicitly to its real implementation so the
composition is reviewable. The only test-specific values are the owned
custodian PID, its lease supervisor, temporary storage root, fixture IDs,
and a fixed test-only 32-byte fingerprint secret.

`OperationScope` must remain the real module. In particular, do not bypass
`with_shared_request/4`, `with_read_request/4`, `Authorize`, either advisory
lock, `ScopedRepo`, or the after-commit runner. Preparation refuses an active
transaction; successful import through this stack therefore exercises the
real transaction boundary. After each API result, verify a fresh request
checkout has no active transaction or owner/principal context.

The first import currently authenticates source bytes in both runtime
preparation and repository preparation. This is established behavior to
characterize, not permission to optimize it. Do not assert an invented
single-read or single-download-audit contract.

## Fixture and isolation

Use `Singularity.Storage.DataCase`, `async: false`, `@moduletag :integration`,
and ExUnit's `:tmp_dir`. The established integration Mix task allocates one
isolated database per invocation, not one per test. Each case creates unique
owner, session, Asset, and mutation identities; all observations are filtered
by those IDs. Do not reset shared tables or start a second global runtime.
The parent owns Mix commands, database/services, and Git writes.

Start with `KnowledgeFixtures.prepared_source!/0`, which creates an available
Asset, completed metadata, a source association, identity rows, key versions,
and an envelope. It returns canonical text UUIDs; dump UUID parameters only
at SQL boundaries. Do not call `KnowledgeFixtures.document!/2`,
`ready_document!/1`, `document_context/1`, or `document_command/2`: these either
precreate the subject or inject the digest evidence being qualified.

Adapt only the private encryption/custody setup from the existing
`DocumentApiIntegrationTest.empty_original_fixture!/2`:

- Encrypt a small nonempty text canary with `ChunkedAEAD.encode/1`, the actual
  `Format` parameters and exact owner/domain/object AAD. Stage, append, seal,
  and finalize with `LocalFilesystemAdapter` under `tmp_dir`.
- Wrap the actual object DEK with `KeyWrapper.wrap/3` and replace the fixture
  envelope. Set ciphertext hash/size and plaintext size on the object, and
  the matching plaintext size on Asset metadata. The fixture's placeholder
  digest must not be supplied to import; expected digest is independently
  `:crypto.hash(:sha256, plaintext)`.
- Grant the fixture principal existing `asset.read` capability and set its
  owner row unlocked, as established fixtures do. Only deletion cases need
  existing `asset.write`. This is setup of legacy owner-scope substrate, not
  a change to Vault behavior.
- Start unnamed, test-supervised `KeyLeaseSupervisor` and `KeyCustodian`.
  Configure real `CustodyReader` for authorization, clock, key reading, and
  object key loading, with `WorkerRepo`, `CustodyRepository`, `ScopedRepo`,
  `KeyWrapper`, and local storage context. Use the existing inert idle callback
  fixture convention; the bounded test does not wait for idle expiration.
- Use existing `prepare_unlock/2` and `activate_unlock/2` with matching live
  identity/key-version fields, then pass a matching `DTO.Session` to `Api`.
  Locked-custody cases omit activation while keeping the DTO's unlocked hint
  true, ensuring real custody is checked.

Wrap only the import scenario in
`KnowledgeTestGrants.with_grants(~w(document_versions document_import_receipts), fn -> ... end)`
and `KnowledgeTestGrants.with_receipt_grants/1`. This supports receipt update
as well as canonical insert without granting fragments or lifecycle writes.
These helpers require `singularity_test_<24 hex>` and unwind temporary grants.
Check denied canonical write privileges before and after the wrapper for
both runtime roles. Never add a migration or grant production access.

Use test-owned local ciphertext corruption to exercise real authentication
failure. Finalized objects are read-only: change permissions on the exact
fixture-owned object file before modifying it, never on its directory or a
broad storage path. Keep stored ciphertext metadata unchanged, so corruption cannot be
mistaken for a deliberately reauthorized new object. No ciphertext fixture
should contain plaintext as a shortcut.

## Required contracts

| Case | Required public and persisted observations |
| --- | --- |
| Successful import | Nonempty encrypted source imports through `Api`; returned pending version has exact authenticated plaintext SHA-256, byte size, source Asset/resource/version/object IDs and owner; new Document IDs differ from source IDs. Exactly one Document resource/version, one completed receipt and one extraction event exist. |
| Exact replay | Same mutation, same Asset, canonical-equivalent title returns the identical Document IDs/result; receipt, pin and extraction-event counts stay one. No new `asset.downloaded` audit is created by replay. |
| Changed replay | Same mutation with changed title or Asset ID returns exactly `{:error, :conflict}`; canonical rows/event counts and download audits do not change. |
| Cross-owner source | A fully valid, unlocked second owner's session imports the first owner's Asset ID and receives `{:error, :not_found}`. No Document/receipt/extraction event is written for either owner. Do not fake cross-owner coverage with a mismatched session struct. |
| Corrupt encrypted source | Modify the fixture object bytes without changing expected hash metadata, then call the same real import path. Require `{:error, :integrity_failure}` from the real authentication boundary. No Document, receipt, extraction event, fragments, or search rows survive. |
| Custody locked | Real identity and database authorization remain valid, but the owned custodian has no activated key. An unlocked DTO hint cannot permit import. Expect `{:error, :vault_locked}` and zero import writes. Also preserve existing fast coverage for `unlocked?: false`. |
| Revoked live authority | Activate custody, then revoke the fixture session in PostgreSQL. The stale DTO receives `{:error, :unauthenticated}`; zero import writes. This characterizes import's live check without changing any revocation implementation. |
| Replay after actual Asset deletion | Import, call real `Assets.Delete.run/4` using real locks/repository and current state revision, and verify the persisted tombstone and released association. Exact import replay still returns the original Document; changed replay conflicts; no extra extraction event or source-read audit appears. Original pin/object/ciphertext remain unchanged. |
| Privacy and footprint | Capture logs and applicable real telemetry around import, replay, and denial/corruption. Scan captured metadata, error terms, owner-filtered audit metadata, complete outbox rows, and job rows for distinct title/plaintext/key canaries. Extraction payload equals exactly the two Document UUID fields. Import does not start extraction, produce fragments/search projections, or submit new Oban jobs. |

The corrupt-source contract follows the existing local adapter's expected-hash
integrity failure. Do not broaden its accepted result list to obtain green.
An unexpected result is a diagnostic stop, not
permission to amend production or weaken the contract.

Privacy capture starts after fixture construction and ends before observation
SQL. Attach to the repos' actual `telemetry_prefix ++ [:query]` events and
existing relevant runtime telemetry; detach reliably. After temporary grants
unwind, perform one explicit denied `SafeSQL` read through WorkerRepo as a
capture control and require its real
`[:singularity, :authorization, :rls_denial]` event with bounded metadata.
Keep this control distinguishable from events produced by import itself.
RequestRepo's established `default_options/1` and SafeSQL disable query
telemetry; empty query capture is therefore expected and must be reported as
query metadata not produced, not positive capture of real query metadata.
Do not enable query telemetry for the test. Inspect entire terms
with unlimited printable/collection limits, including raw and inspected
representations of the binary canaries. Authorized successful Document
results intentionally contain title and digest; only errors and side-channel
surfaces are subjected to the no-content assertion.
Any query metadata captured must come from actual execution. Any captured SQL
parameter/content leak is a real RED result; do not hide it with fabricated
metadata, capture filtering, changed logger/telemetry settings, or adapter
substitution.

No worker or dispatcher is run for this test. Assert owner-filtered job counts
are unchanged and inspect any rows that exist, but do not represent an empty
job set as proof of produced Oban argument privacy. The established job codec,
dispatch and worker tests retain that Task 15 responsibility. Likewise this
slice does not replace cleanup collision, in-flight revocation, stale worker,
extraction-limit, PDF, tombstone-read, or backup-refusal coverage.

## Verification and stop rules

First run the single new integration file through the existing isolated-DB
task, then the existing fast import file and the existing API integration
file as focused regressions. Repeat the new file with a second fixed seed
after it passes to detect fixture ordering/global-state leakage. Do not add a
new concurrency harness; existing races remain in their owning tests.

Inspect errors before classifying RED. Incorrect fixture IDs, sizes, or grants
may be corrected only in the new test. A valid contract exposing a production
composition failure stops affected implementation and returns exact command,
assertion, sanitized result, database state, and a source-based diagnosis.
Never replace real scope/custody with fakes, suppress a failing assertion, or
add a production fix to obtain green.

Success means this bounded live import contract has passed with exact evidence
and temporary grants are restored. Full Task 15, E2E, and complete Phase 2
acceptance remain incomplete. E2E is explicitly NOT RUN under the standing
instruction. No version bump, release, tag, push, merge, deployment, canonical
production activation, Vault feature work, new grants/migrations, search,
Note Save, or backup V3 is included.
