# Phase 5 Task 11: native knowledge V3 backup and restore saga design

## Current source/gate qualification — 2026-10-18

Task11 source/gate qualification is complete on local source
`4a2e007649ab2d7c62aa72ee84bf1d2de0a93802`: all26 required non-E2E campaign rows and their26 separate
ordinary posts PASS, including2215 unit tests+10properties,2086 integration tests,
197 JS tests and the sole independent V1/V2/V3 restore. Combined final21 actual
SOURCE SPEC then NEW distinct SOURCE QUALITY both CLOSED PASS; committed source
blobs21/21 match the tested/reviewed bytes. Exact commands, six source commits,
raw hashes, warnings, historical failures and documentation closure conditions
are in [Task11 handoff](../../verification/2026-10-18-phase-5-task11-handoff.md).
Documentation review/commit and literal clean handoff remain closure conditions;
this status records source/gates, not Phase5 acceptance or Task12 source GO.
DefaultV2/closed unsupported guard, Task16 BOTH strict ALL-leases
UNSATISFIED/UNWAIVED/BLOCKED_DESIGN, Task17NOTGO and Task18 dependencies remain.
E2E NOT RUN; no publication, production activation or Vault feature work.
Dated Task10 and earlier amendment/preparation paragraphs below are historical;
their old pending/source-NO-GO language does not replace this current record.

## Historical Native174 qualification result — 2026-10-18

The preparation narrative below is historical; Task11/Phase5 remain UNQUALIFIED.
The separately recorded ONE literal `mix singularity.test.integration`
qualification was Native174: natural2,2083actual/3FAIL,seed32026/max_cases96.
Storage1621actual/2FAIL; Runtime462actual/1FAIL. Exclusions are NOT passes.
Root read all1136 unfiltered safe raw lines through the actual03:08:19+08 exit2
footer and verified SHAfcf617f2f8b32eb5bebb4b5d3c359001f1b2e414892664049676fb3d6a6c3fdb.
Native175 fresh separate ordinary residual was natural0/EMPTY; complete4line raw,
actual03:12:19+08 footer/hash and ORIGINAL closing guard1574/status42/owned0 PASS.
No source or observer changes occurred during174; restored Runtime860295eb and
ingestionc52d71d7 remain exact. The final-qualification allowance is CONSUMED.

Actual failures: BackupConcurrency outbox claim received3events rather than1;
LogicalV3Exporter initial fixture seed checkout queue dropped4998ms before its
exporter/cut/oracle assertions; NativeTextAuthorization60000ms watchdog sampled
ResourceOwner.release, with cleanup incomplete. Causes are NOT yet established.
Separate read-only assessments identified omitted Document retirement in3
knowledge test owners; exact174UUID attribution remains unproved. Its bounded
2026-10-18 repair now has meaningful RED180(43actual/3teardownFAIL) and SAME
vector18843actualPASS, separate helper unit182/1901actualPASS each, all own
ordinary posts0EMPTY through191, and SOURCE SPEC->NEW distinct QUALITY191PASS.
Existing-helper retirement adds only33lines; no assertions or production change.
The final saga source map is previous18 plus all3 Document test owners listed in
the retirement design section2: all21 require combined final source review.
Checkout/release causes remain unresolved. The separately proposed2026-10-18
lifecycle-boundary-observation design/plan is a candidate, not execution permission
or a new qualification allowance. No automatic retry/successor from those results.

Native154 literalFAIL, Native166fullcontextFAIL2 and their unreachables remain.
Native17258actualPASS is scoped diagnostic-only, not repair/qualification.
QuestionA metrics remain WITHDRAWN/UNOBSERVED; no finite new budget is justified.
Document retirement actual round1 focusedGREEN/failedSol0/Astra0; checkout/release
actual repairs0/no technicalimpasse. All final vectors/timer locks/reviews remain.
DefaultV2, Task16UNSATISFIED/UNWAIVED/BLOCKED_DESIGN,Task17NOTGO and E2ENOTRUN stay.
No assertions, failed history, frozen boundary or publication scope changes.

Date: 2026-10-15. Status: DESIGN AMENDMENT — independent SPEC/QUALITY pending.
Companion plan:
`docs/superpowers/plans/2026-10-15-singularity-v0.2-phase-5-knowledge-v3-saga.md`.
No Task11 source implementation or runtime qualification is claimed.

## 1. Authority, prerequisites, and evidence boundary

The governing documents are the Phase 5 master design dated 2026-10-11, especially
§8 and §11, the corresponding master plan Task 11 and Task 12 dependency, and the
2026-10-12 storage-reference compatibility design. The inspected worktree is
`/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`. Source inspection began at HEAD
`94efb34ae128298ab62bfbd7b77d387b882bbb62`. During authoring the parent made its
planned local prerequisite code commits, reaching
`5f388ac88d5603b8c29df3a592d0843885a30912`, and reported the 26 qualified code
paths' content unchanged. Native-text prerequisite source/documents belong to
the parent and are untouched by this draft.

Task10 is qualified locally as recorded in its committed handoff. Native-text
prerequisite code and documentation each passed actual independent SPEC followed
by NEW distinct fresh QUALITY, then local documentation commit
`239c1c322b47c095004690154f691fcf85eeff81` (tree
`d502026915caaa8cc18b51e31c5c25d3ba387506`). Literal index/status were EMPTY;
all26 qualified code, all49 controls, all25 common native bytes and all87 reviewed
prerequisite source/control/document bytes matched unchanged. The immutable
ignored handoff is `.devenv/phase5-task11-native-text-handoff.md`, SHA256
`4f4b209b07c88c4c081ea81277fb120f32730e284bf7a944de40f2b427b8b32a`;
committed evidence is [native-text prerequisite](../../verification/2026-10-15-phase-5-native-text-prerequisite.md).
Those results qualify only that prerequisite, not Task11. Task11 implementation
remains gated until this complete
design, detailed plan, and synchronized governing amendments receive independent
SPEC followed by NEW, distinct QUALITY review. Design review is separate from
the later source SPEC/QUALITY reviews. Continuous development authority selects
the recommended in-scope approach without routine renewed human approval; it
does not remove these dependencies or reviews.

This design qualifies explicit logical V3 through existing runtime and storage
interfaces. Default logical version remains 2. Master Task 12 (default switch)
still requires master Tasks 8–11 GREEN and combined-boundary independent reviews.
No Phase 5, product, browser, release, or production acceptance follows from this
document. E2E is manual-only, deferred, and MUST remain NOT RUN.

Task 16's BOTH strict ALL-leases obligations remain independently
UNSATISFIED / UNWAIVED / BLOCKED_DESIGN. The selected Task 11 reads do not amend,
waive, satisfy, or authorize changes to those obligations.

## 2. Outcome and alternatives

The required outcome is a genuine public upload → public backup → authenticated
maintenance restore → genuine rewrap/integrity custody → knowledge verification
→ unified rebuild → completion proof, including all-state canonical history and
decrypted bytes from every retained original object. Existing shape-only bundles,
known hashes, fake leases, and direct raw-key test issuance remain useful scoped
contracts but cannot qualify that outcome.

Three approaches were considered:

1. **Recommended: compose real publication and custody with graph-only test
   seeding.** Publish originals through existing public upload and native workers;
   append the bounded canonical history using existing table-owner fixture
   patterns in a disposable source. Keep genuine bootstrap credentials,
   hierarchy, recovery wrapper, domain and object envelopes. This preserves the
   requested history coverage without expanding product APIs or custody. The
   cost is explicit test infrastructure ownership and independent snapshot
   observation.
2. **Reuse `KnowledgeBackupFixtures.seed!/1` and replace selected owner fields.**
   Its real encrypted objects help helper/import tests, but it always creates
   its own hierarchy and literal `fixture-recovery-wrapper`. Patching those
   fields is not proof of the normal wrapper chain and risks inconsistent
   identities. Do not use this as the native saga positive.
3. **Create the whole history through public knowledge APIs.** This maximizes
   public-path coverage but cannot create the exact historical/tombstoned,
   conflict, extracting, and imported states without extra runtime/recovery
   behavior. It expands this qualification task and makes a stable cut harder
   to establish. Existing public knowledge regressions remain; this task uses
   fixture-only historical graph construction with all ordinary guards active.

No production compatibility change, dependency, new public interface, role grant,
or migration is evidenced as necessary. A failed native contract is diagnosed
and repaired under a separately reviewed minimal amendment if required; this
draft does not pre-authorize a frozen-protocol or production-interface escape.

## 3. Invariants and actual composition

The existing call order remains:

```text
Api.request_backup
  → real OutboxDispatcher / Oban GenericWorker / WorkerScope
  → real JobDispatcher / BackupVault
  → explicit-V3 Exporter / real object inventory / BundleWriter / publication
  → maintenance RestoreVault empty-destination admission
  → RestoreAuthenticator / BundleReader / LogicalBundleVerifier
  → Restorer import: typed preflight → canonical insert/source seals
      → staged object publication → imported marker / commit resolution
  → recovered-key claim → native owner rewrap → native integrity capability
  → ciphertext verification → durable-work reconciliation
  → final ciphertext recheck → actual typed native PlaintextSummary
  → Document-source verification → unified knowledge rebuild
  → integrity completion → restore completion
  → ordinary login/unlock → public search and original-byte observation
```

`Runtime.RestoreVault` performs admission before authentication and revokes
authenticated and integrity authority on every appropriate exit. Its order is
not rearranged. `Runtime.IntegrityAudit.verify_final/4` already validates native
typed plaintext evidence before the Document callback and rebuild. Its final
verification rechecks ciphertext after the earlier saga-level ciphertext check;
fault tests distinguish these two boundaries.

Database rows and filesystem publication do not form a distributed transaction.
Pre/import failure proves canonical rollback and identity-bound owned cleanup.
Post-import failure proves an unpublished maintenance destination, barriers,
custody cleanup, and absence of restore completion; it does not claim rollback of
committed import, rewrap, or filesystem publication. Reconciliation is durable
work repair, not permission to dispatch or expose an unverified graph.

The existing active installation remains untouched. Replacement qualification is
restoration into a separate, empty, disposable staging destination while the
active-installation sentinel remains unchanged. Operational production cutover
is outside Task 11.

## Task11 case-local execution-budget amendment — 2026-10-16

The [sentinel budget design](2026-10-16-singularity-v0.2-phase-5-task11-sentinel-budget-design.md)
and [detailed plan](../plans/2026-10-16-singularity-v0.2-phase-5-task11-sentinel-budget.md)
govern an explicit independently reviewed exception: only the original continuous
sentinel/failed-target/fresh-RESTART case may use `@tag timeout: 120_000`.
This supersedes originaltimer wording only for its aggregate ExUnit watchdog,
not any product assertion, native work, other deadline or qualification vector.
It takes effect only after design SPEC -> NEW distinct QUALITY and root source GO.
Native60/64 remain FAIL; Native63 remains diagnostic. No latency speedup or
Task11/Phase5 acceptance is claimed. Frozen56/Vault/Task16 remain unchanged;
E2E NOT RUN and publication/production restrictions remain in force.

## 4. Ownership, resources, and test-only seams

Expected implementation responsibilities, subject to the detailed plan:

| Owner path | Responsibility |
| --- | --- |
| New `apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs` | Full native UUID/canonical/mixed saga, exact cut, bytes/search, runtime-stage faults, native size/digest/ciphertext negatives |
| New `apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs` | Independent malformed matrix, native import/insert/publication/commit-resolution faults and exact replay |
| New `apps/singularity_runtime/test/support/knowledge_backup_restore_fixture.ex` | Genuine source bootstrap/publication, separate controlled child assembly, V3 worker adapter and transparent observers |
| New `apps/singularity_runtime/test/support/knowledge_restore_oracle.ex` | Independent task entry and explicit canonical/search/original-byte/negative assertions, sharing construction but not production-derived expectations |
| New `apps/singularity_runtime/test/mix/tasks/singularity.test.restore_test.exs` | Focused executable oracle export/dynamic-entry/legacy-cleanup ordering contract; not native qualification |
| Existing Storage `test/support/knowledge_backup_fixtures.ex` | Add a graph-only entry sharing private graph writers, retaining existing `seed!/1` behavior and all existing callers |
| New `apps/singularity_storage/test/support/knowledge_canonical_oracle.ex` | Exact source snapshot and destination canonical queries with independently declared columns, PKs, owner filters and established identity transformations |
| Existing `apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex` | Additive invocation of knowledge oracle only; preserve every legacy operator/crypto/V1/V2 assertion and old path behavior |
| Eventual Task 11 design/plan and parent-owned master design/plan | Reviewed requirements, exact commands/results and retry wording synchronization |

Support names above are proposed new files/interfaces, not claims that those
APIs already exist. No app dependency direction changes. No changes to the
native-text prerequisite's `NativeAssetFixture` or qualifying production sources
are part of Task 11's planned fixture assembly. The necessary test-only
ResourceOwner exception is governed by
`2026-10-16-singularity-v0.2-phase-5-nested-fixture-lifecycle-design.md`
and its matching detailed plan. It permits only explicit parked-parent child
ordering, a new separate nested-lifecycle test owner and the two Task11 nested
destination callsites after independent design review and fresh qualification.
MTE, the existing lifecycle owner and the true frozen56 remain unchanged.
Historical helper seals remain historical, not regenerated acceptance.

Use the existing `KnowledgeFixtureResourceOwner.open/1`,
`start_infrastructure/2`, and `close/1` for each database lifetime. Source and
destination repositories with established global names run sequentially. Preserve
only an encrypted bundle and content-safe expected test data in a private,
operation-owned portable directory between lifetimes. Assert source supervisor
and owned repositories are stopped before destination acquisition. Never bootstrap
the destination before restore; start its ordinary runtime only after success.

The new knowledge assembly explicitly selects actual existing runtime child
specifications. It removes already-owned repository children exactly, as the
prerequisite pattern does, and withholds only periodic `Documents.ExtractionReconciler`
until the canonical import comparison. `ExtractionReconciler.init/1` immediately
sends itself work, so starting the full supervisor over an expired fixture would
change history before observation. Do not pause it by process signals, mutate its
implementation, or silently change `NativeAssetFixture.start_runtime!/2`. Once the
import cut is compared, enable lawful recovery explicitly and record its expected
changes. Upload verification/finalization and backup still run real services.

Snapshot and restore every application setting touched by fixture composition,
including `:job_handler`, maintenance/start flags, roots, repository configs,
authorization/custody/job adapters and Oban configuration. The independent oracle
also runs outside ExUnit; its entry needs explicit try/after cleanup, not reliance
on ExUnit on_exit alone. Every failure asserts owned roots/database cleanup;
sentinel/foreign artifacts remain untouched. No secret or body content enters
logs, assertions' failure metadata, telemetry, job arguments, or audit payloads.

## 5. Genuine originals and bounded canonical graph

Use a real `BootstrapOwner.run/2` with existing password hasher/KeyWrapper/KDF and
normal `Api.login`, `resolve_session`, and `unlock`. Keep the actual returned
owner/session identifiers and epochs. Do not replace credentials, wrappers,
capability results or key material with fixture strings. Required capabilities
are the existing ones used by the native source/search/download operations;
this is test-owner provisioning, not a policy or runtime grant change.

Publish six sources through `Api.create_upload_grant`, `begin_upload`,
`append_upload`, `finish_upload`, then real verification/finalization queues:
`:pdf`, `:pdf_duplicate`, `:empty`, `:plain`, `:unicode`, `:markdown`. Use equal
synthetic binary PDF inputs for the first two; assert distinct Asset/resource/
version IDs and genuine shared-object deduplication. The PDF publication witness
may be finalized `available/pending` metadata as established; do not falsely call
it completed text extraction. Native text originals use empty, CRLF plain text,
split UTF-8/BOM/combining characters, and Markdown bytes. Preserve exact original
bytes independently of any canonical text normalization. Assert real UUID
`storage_ref`, envelope generation, object availability, media type, finalized
receipt, and actual native pre-cut download where applicable.

Build each descriptor by querying actual finalized associations:

```elixir
%{resource_id: actual_resource_id,
  resource_version_id: actual_resource_version_id,
  asset_id: actual_asset_id,
  object_id: actual_object_id,
  digest: expected_sha256_of_input_bytes,
  byte_size: expected_original_byte_size}
```

The proposed graph-only entry accepts the actual owner, six descriptors, coherent
knowledge IDs, actual authorization epochs and fixture-owned work identities. It
shares `seed_documents`, `seed_notes`, `seed_organization`, and `seed_work` logic
without calling `seed_owner`, `seed_sources`, `FixtureCrypto`, or generating a
hierarchy. Construct fragments through actual `Core.DocumentFragment.new/1`
using final owner/resource/version IDs. Never rewrite fragment or citation IDs
after construction. Receipt fingerprints here are fixture construction, not
evidence that public Document import ran.

Coverage retains ready old/current/deleted Document versions, pending, extracting,
failed and unsupported; live/tombstoned Notes, six Note versions with parent/merge
ancestry and conflict resolution; attachments/citations including historical pins;
tags, normalized keys, assignments, pinned/unpinned relationships; completed
receipts and coherent durable recovery work. Independent explicit cardinalities
and identity relationships establish that none disappears in backup. Counts are
derived from the designed graph plus actual publication/backup events, not copied
unchanged from the synthetic fixture's 114-row graph.

Keep admission and retirement in separate committed phases. The new graph-only
entry commits Documents/fragments/Notes/source sets/organization/work while all
source targets are live, including every empty Note source set. It leaves the
genuine published Assets live; do not run old seed!'s direct PDF retirement SQL
before the following public operations. For each of the two real PDF Assets,
read its actual current state revision and call
`Api.delete_asset(session, asset_id, state_revision)`, then dispatch/drain its
actual `asset_cleanup` job. Native AssetDeletionRepository.apply_tombstone inserts
a real `content.tombstones` row, releases associations, and emits audit/cleanup
work. Native logical cleanup clears the Asset object pointer; existing
`document_source_pin_count` retains the object. Assert two actual tombstone rows
with exact Asset/principal/owner/revision binding, released source associations,
deleted Assets with null object pointers, available shared PDF object and
unchanged real ciphertext/envelopes. This is nonempty tombstone-table coverage;
setting resources.deleted_at alone is insufficient. Fixture-only retirement of
selected Note/Document/resource rows and source search reconciliation then commits
separately under ordinary guards. Retained PDF objects must now be required
solely by Documents. The original seed! behavior and its old tests remain
unchanged. Ordinary admission, completion, source-seal RLS, immutable guards, and
deferred constraints stay active.

Parameterize fixture work with actual epochs and a consistent extracting attempt
→ outbox event → submission chain. The historical event700/submission702 mismatch
cannot be left for restore to repair before the cut; adapt the existing lawful
child-delete/recreate submission pattern if required, preserving unrelated native
publication jobs/receipts. Dispatch accounting includes every actual event; do not
alter the legacy oracle's `submitted: 1` expectation to fit this separate graph.

## 6. Real explicit-V3 public backup and exact source snapshot

Production `Exporter.snapshot_cut/2` and `records/2` remain default V2. A nested
test-only V3 exporter delegates `/2` calls to actual Exporter `/3` with literal
version 3. A test-only JobHandler module delegates `dependencies/0` to actual
`JobDispatcher.dependencies/0`, adds only this exporter, and delegates `handle/2`
and `handle_failure/4` unchanged. GenericWorker still provides `repo_handle`,
`lock_mode`, and `transact`; its reserved-key checks are unchanged. Request-local
injection alone is insufficient because the real backup runs in a worker.

Call public `Api.request_backup(session, passphrase)`, native dispatch and backup
queue drain, and public `Api.backup_status`. Require sealed status and actual
operation/manifest identity. Read and retain only that operation's real published
bundle using `LocalDestination`; no fake manifest, completion, recovery wrapper,
object streamer, or bundle crypto is introduced.

The canonical expected cut MUST come from the exact worker repeatable-read
snapshot, not before request or after backup completion. The request creates work
and the worker changes durable state; those times are not equivalent.

Selected source-backed observer protocol:

1. Inside test V3 exporter's `snapshot_cut(repo, owner)`, delegate the actual
   `Exporter.snapshot_cut(repo, owner, 3)` and retain its exact successful result.
   ScopedRepo supplies the actual worker Repo in the checked-out RR transaction;
   WorkerScope retains its exclusive Vault lock and authorization lock.
2. On that SAME checked-out connection issue content-free
   `SELECT pg_export_snapshot()::text` through SafeSQL, using
   `repo.get_dynamic_repo()` when exported by the repo, matching Exporter's own
   SQL-repo convention. Do not change worker role, isolation, GUCs or privileges.
3. Synchronously, while the exporting transaction remains open, use the separately
   owned MigrationRepo connection to begin RR/read-only, import that database-
   returned snapshot BEFORE any table read, then assume the existing table-owner
   role for the test oracle. Snapshot text comes only from PostgreSQL and is
   validated/quoted as that token; no caller-controlled SQL identifier or snapshot.
   Require same database, different backend PID, worker CURRENT_USER unchanged
   before/after observation, and `txid_current_snapshot()::text` equal to
   `cut.database_snapshot`; fail if exporting/importing cannot be established.
4. Query independently fixed 367 wire columns and PK ordering for all 38 tables.
   Own this projection in test support, including the fixed old 30-table prefix;
   do not dynamically derive columns/PKs from either V2 or V3 registry, or build
   expected rows/digests from codec output, Restorer, or KnowledgeRestoreDigest.
   Apply the exporter contract's
   explicit owner/credential/principal filters, active Vault-key wrapper selection,
   and outbox `sequence <= cut.outbox_high_water_mark`. This includes real native
   upload and backup events/submissions/progress present at that snapshot. Snapshot
   equality, table count, expected fixture identity sets, and row cardinalities
   make accidental omission observable.
5. Commit the read-only observer, return the IDENTICAL actual cut, then let real
   `records(repo, logical_cut, 3)` and real object streaming run normally. The
   observer does not consume or re-encode the production record stream.

`KnowledgeBackupFixtures.canonical_rows/1` currently hard-binds MigrationRepo and
starts its own owner transaction. It is useful for ordinary fixture checks but
cannot simply be called before/after backup as the source oracle. The new fixed
projection observer explicitly owns its snapshot transaction. No nested lifetime
of named source/destination repos is introduced: this is two connections within
the same owned source database.

Current source inspection establishes no canonical DML in the RR export
transaction before snapshot capture: BackupVault.export authorizes, resolves
writer destination, captures cut, exports records/objects, writes bundle, and
only then acknowledges seal. ScopedRepo sets transaction isolation and context;
earlier worker progress commits are visible to this cut. Keep that causal source
contract and qualify it live. An imported MVCC snapshot would not include its
exporting transaction's own uncommitted writes; any future such write requires
revisiting the observer, never quietly accepting a stale expected cut.

## 7. Independent post-import canonical cut

Use a transparent contextual Restorer adapter implementing actual callbacks:
`import(context, migration_repo, %{verified:, cut:, binding:})`,
`rewrap_owner(context, imported, password, recovered_capability)`, and
`complete_restore(context, rewrapped)`. Delegate to native Restorer once.
Immediately after successful native `%Restorer.Imported{}` and before returning
that identical result to RestoreVault, observe destination rows in a fresh,
consistent MigrationRepo snapshot with the same independent fixed projections.
Native recovery-key claim/rewrap and reconciliation occur only after this return.

Compare every canonical wire column and sorted PK across all 38 tables, including
all historical/non-ready/tombstoned rows, IDs, source sets, fragment IDs/locators,
digests, receipts, conflicts and organization. Compare regenerated source seals
independently by exact Note-version membership/counts; seals and search projections
are derived and are not invented V3 tables. Credential verifier/version/updated_at
and pending wrapper fields are omitted by the wire and must be checked separately
with their established restore semantics. The ONLY wire-value transformation is
`core.vaults.locked = true`; no knowledge field is exempted. Do not compare new
password wrappers or lawful recovery mutations against a pre-rewrap source as
if they should remain byte-identical.

The observer preserves original Verified/cut/binding and all Imported/Rewrapped
fields, owner/manifest/tag/hash values and opaque capabilities. Errors/results are
returned unchanged; observation cannot import twice, claim recovery authority,
advance a saga, manufacture a typed handoff or normalize references.

## 8. UUID, historical canonical, and mixed native paths

Three separate complete native runs are required:

| Variant | Source composition | What the successful full saga proves |
| --- | --- | --- |
| Normal UUID | All public-published references remain untouched UUIDs | Real normal publication through genuine wrappers/lease and unified completion |
| Historical canonical | Explicit test-only historical alias composition of genuine published objects before backup | Accepted canonical reference compatibility through the same native chain |
| Mixed | A deterministic nonempty proper subset uses historical canonical aliases; remaining UUIDs unchanged | Simultaneous I/N(I) binding and real lease material across both spellings |

The compatibility variants first prove successful public UUID publication. Only
inside their OWN disposable source, a named test-only table-owner composition
changes selected `asset_objects.storage_ref` from exact own UUID to exactly
`Path.relative_to(path, root)`, where the actual successful
`{:ok, path} = PathGuard.object_path(root, owner, domain, lookup_hex)` fixes path.
Assert exact one-row updates and that all other persisted object fields, envelope
bytes/generations, real ciphertext bytes and physical identity are unchanged.
No trigger is disabled, no production reference normalization is added, and no
second object, file copy or fake wrapper is manufactured. Source precedent exists
for mutable `asset_objects.storage_ref` in the helper's persisted-reference
mutation test. The composition must itself pass current guards and actual backup;
its success is a historical compatibility witness, never a claim that normal
publication stores canonical paths. Keep the unchanged UUID case separate.

Object storage throughout the full native reference positive is the actual
LocalFilesystemAdapter with explicit root/owner/domain/lookup context. Its
`object_path/2` ignores the opaque ObjectRef spelling when lookup context is given;
PathGuard fixes the one path. Assert byte/stat equivalence through actual adapter
calls for both references before backup and after import. An arbitrary delegating
adapter is not silently treated as the actual local adapter for this proof.

For every variant preserve the exact ordered nine-field original inventory I:
`asset_object_id`, `vault_id`, `key_domain_id`, `classification`, `lookup_digest`,
`ciphertext_hash`, `ciphertext_byte_size`, `storage_ref`, `inventory_position`.
Authenticated wire/cut, persisted rows, Imported/Rewrapped and saga inventory
commitment stay I. N(I) replaces ONLY each storage_ref by the existing object
UUID; every position and other field remains identical. Require exact manifest,
owner, root, hash/tag, count and original-I commitment checks through existing
prepare/material loading. Capture actual native ciphertext and plaintext summary
results over N(I) without manufacturing/re-hashing a summary. Assert native
PlaintextSummary struct, owner/count/inventory digest, and exact ordered object/
hash pairs. Plaintext hashes come from actual unchanged authenticated reads.

## 9. Plaintext and public-search observations after completion

Select `{KnowledgeIntegrityAudit, MigrationRepo}` ONLY as V3 search rebuilder.
Preserve actual Storage IntegrityAudit ciphertext auditor/completion, native
RestoreIntegrityLease, recovered-key issuer, key deriver/wrapper and bundle crypto.
Transparent observer delegates may record content-free boundary events and actual
returned typed values; they cannot supply material, plaintext, summary, keys,
wrappers or capabilities. Keep native Base composition for V1/V2.

After successful completion, leave maintenance in this disposable test only,
start its ordinary owner infrastructure and login/unlock with the restored new
password. Compare public `Api.search_knowledge` results for Notes/Documents, preserve the
existing Asset list/search observations, and use lawful public source resolution:
only live heads, exact immutable resource/version/fragment pins and locator,
organization/tag behavior, no stale historical/non-ready/deleted search rows,
and no resurrected source Asset. Run lawful abandoned extraction recovery only
after the canonical cut and compare expected derived changes/idempotence
separately. Completed historical receipts and original pins remain immutable.

Every retained original object requires observed decrypted binary equality,
including the shared PDF object that is historical/deleted/nonhead and Doc-only.
Public `download_document_original` covers only live current Document heads;
it cannot serve as the all-history oracle. For each deduplicated inventory object
select its actual retained Asset identity, actual active envelope generation and
restored owner session, then use the PUBLIC lower-level existing native seam:

```elixir
request = %{
  purpose: :download,
  job_id: actual_retained_asset_id,
  session_id: restored_session.session_id,
  principal_id: restored_session.principal_id,
  vault_id: restored_session.vault_id,
  required_capability: "asset.read",
  principal_authorization_epoch: restored_session.principal_authorization_epoch,
  vault_authorization_epoch: restored_session.vault_authorization_epoch,
  object_id: actual_inventory_object_id,
  object_generation: actual_persisted_envelope_generation
}
{:ok, lease} = KeyCustodian.lease(actual_custodian, request)
{:ok, actual_binary} = DownloadLease.read(lease, :all)
```

This uses the actual restored retained tombstoned Asset ID where appropriate,
not a fake job/capability. CustodyRepository material loading requires available
object and active content domain/version/envelope, independently of Asset liveness;
CustodyReader revalidates real authorization and material. Assert those conditions
for every object and require every read succeeds. Close/revoke actual leases via
their established lifecycle and assert no leaked owned authority.

Compare the returned binaries with independent original inputs, including NUL/
non-UTF-8 PDF bytes and unnormalized text bytes. Three distinct required results
are recorded: ciphertext byte identity; native authenticated summary hash evidence;
actual native download binary equality. Source inputs and `source_bytes/1` are
expected data, never observations of decrypted bytes. This bounded fixture does
not qualify Task 16 strict ALL-leases.

## 10. Causal native integrity negatives

Each negative starts from a successful clean composition and then establishes
its own authentic/imported state. Preflight failure cannot substitute for a late
Document helper, reader, or rebuild denial.

**Size barrier.** Build an authenticated negative from the genuine-publication
source with equal wrong immutable Document and current Object plaintext sizes for
ALL Documents sharing a selected PDF object, while preserving actual encrypted
bytes and I's ciphertext length. This is named test-only metadata composition in
the disposable source BEFORE graph finalization/backup; do not mutate sealed
Document sizes afterward. Prove the normal genuine-publication baseline first,
and require the wrong-size native backup/import passes ordinary structural
checks. The released Document source-insert guard checks the live association
and Object/Doc size equality; it does not authenticate bytes or require source
digest equality with an independently read plaintext. Preflight likewise checks
size equality and common digest/size across sharing Documents. These source
contracts justify the negative fixture; actual stage reachability remains a
required native assertion. Equality does not establish the plaintext length.

After actual native import/rewrap, correct ONLY mutable Object plaintext size to
actual P before the native integrity lease's material read. Keep the immutable
wrong Doc size and original I unchanged. Run the genuine lease and unchanged
AuthenticatedReader; capture the actual returned typed PlaintextSummary. At the
test contextual Document callback boundary, AFTER Runtime validated that summary
but BEFORE delegating real `KnowledgeIntegrityAudit.verify_document_sources/4`,
commit Object size back to the wrong Doc size. Assert current Doc/Object equality
and original inventory equality, then require the real helper rejects and no
rebuild/integrity/restore completion occurs. The unchanged reader establishes P;
the helper must use `C(P)=66+P+24*ceil(P/4194304)+68` against original I, not merely
current equality. Preserve public Format constants, all nine independent literal
vectors, and existing actual empty/chunk-edge reader contracts. No hash-summary
replacement, raw-key issuance, or reader change qualifies this witness.

**Source digest.** Before negative graph finalization/backup, give every Document
sharing the chosen object the same structurally valid wrong 32-byte source digest.
Keep real encrypted bytes and wrapper chain. Require genuine import and native
lease success; the real Document callback then rejects authenticated plaintext
digest disagreement. No current-size-only or fixture-known hash shortcut.

**Ciphertext mutation.** After genuine import and an actual successful earlier
ciphertext check, change/truncate only the chosen owned encrypted object at a
deterministic later boundary. Separate witnesses prove final ciphertext recheck
denial and reader/authentication denial when mutation is placed after that final
check but before native read. A delegating ciphertext auditor can delegate first,
then perform the test fault and return the identical actual summary; it cannot
forge a summary or suppress native verification. Assert reached boundary and no
Document/rebuild/completion after the appropriate denial. Restore fixture-owned
bytes or discard the owned destination; never repair a production object.

**Evidence/metadata mutation.** Keep inherited independent missing/duplicate/
extra/reordered/malformed hash pair, foreign owner/manifest, original reference,
I-versus-N(I), wrong-format/material and historical extracted-digest checks. Shape
injection tests remain adapter-contract negatives and do not count as native
positive summary evidence. Do not generalize the earlier one-test historical
fragment-guard exception into Task 11. Its existing owning test remains in the
qualification set; new Task 11 causal corruption requiring that guard change
needs a separately reviewed narrow exception before authoring.

## 11. Independent malformed matrix

The new Storage failure owner constructs independently enumerated malformed
wire inputs from a valid bounded graph using the established codec/BundleReader/
Restorer contract harness. Genuine cryptographic authentication is required for
the native Runtime malformed/material witnesses; an isolated Storage fixture
adapter is labeled as protocol evidence, never as native cryptographic evidence.
Expected validity is not derived from the production validator, and every earlier
assertion remains. The full native positive and
wrong-size/digest/cipher cases above retain real bootstrap and recovery wrappers.
The established fixture-crypto harness may be reused only for isolated Storage
malformed/import contracts, explicitly not as whole native saga or cryptographic
authentication evidence. Record which adapter each case actually used.

| Malformation family | Required distinct counterexamples |
| --- | --- |
| Identity/closure | Duplicate PK; each relevant secondary-unique collision; extra/missing row; extra/missing object; inconsistent row/object counts; mixed cut/row/object logical versions |
| Provenance | Wrong owner/classification; dangling or wrong-kind source/head; missing parent/merge parent; malformed conflict canonical/competing/resolution ancestry; source associations with wrong owner/version or ambiguous binding |
| Source sets/text | Missing/extra source member; ordinal gaps/duplicates; wrong locator; noncanonical fragment ID; text/fragment digest tampering; historical ready aggregate mismatch; source-set membership tamper |
| Organization/receipts/work | Tag normalization/uniqueness and dangling assignment; invalid relationship target/version/kind; receipt identity/fingerprint/result disagreement; event/submission/job/attempt provenance mismatch |
| Original material | Unsupported format; foreign object; wrong UUID/canonical alias/physical identity; truncated or changed ciphertext; actual plaintext source digest/size mismatch |

Each case identifies the expected enforcement stage and exact Error code and
retryable flag from current source. Preserve known released error text only where
it is an established assertion; do not fabricate a code table before causal RED
execution. At preflight/import rejection, assert no canonical graph publication,
no foreign deletion, and appropriate marker/stage cleanup. Late native integrity
cases assert actual committed import first and remain unpublished on failure.
No malformed test gets counted as exercised when a preceding unrelated failure
prevented its intended stage.

## 12. Fault barriers, replay, and operational recovery

Use content-free, one-shot deterministic barriers with explicit reached-stage
assertions and actual callback results. No arbitrary sleep, hidden test skip,
invented fake material port, or production hook is needed.

| Fault boundary | Actual seam and required observation |
| --- | --- |
| Authentication/preflight | Real authenticator/BundleReader or delegated stage callback fails before canonical work; preserve exact result, no later-stage hit, revoke owned auth custody |
| Canonical insertion/source seals | New test-local SQL fault follows existing `logical_v3_import_test.with_sql_fault` pattern: unique owned sequence/function/trigger; assert native stage predicate and nontransactional hit; all existing guards stay enabled; rollback rows/seals and cleanup only owned artifacts |
| Before staged publication | Delegate real staging; fail selected finalize only after admitted canonical/source-seal state is observed inside transaction; no published object remains after rollback |
| After actual publication | Delegate finalize first, fail actual subsequent stat; assert genuine file/receipt and owned rollback; separately retain a chosen publication by faulting cleanup once, then exercise exact pending replay |
| Imported-marker transition | Test-local SQL trigger faults the real pending→imported update with validated graph/seals and actual object publication; rollback/cleanup and successful exact retry |
| Commit-result uncertainty branch | New real registered Ecto Repo with overridden `transact/2`, following existing CommitUncertaintyRepo: call `super`, inject error ONLY after actual `{:ok, :imported}`, assert outside transaction, retain one hit and original result; native Restorer sees error and resolves current imported marker/inventory; fresh exact-manifest Storage replay succeeds read-only |
| Rewrap | Transparent native delegate/issuer wrapper faults at an identified real boundary; prove original wrapper generation/pending transition state and revocation, no downstream stage; exact error unchanged |
| Ciphertext | Real early check and final recheck faults as separate boundaries; actual data mutation negatives use §10, not only synthetic returns |
| Durable-work reconciliation | Delegate/load actual committed work and fault at deterministic reconcile boundary; graph remains maintenance-only; no plaintext/rebuild/completion beyond failure |
| Typed plaintext / Document | Actual native lease result and Runtime validation before real helper; size/digest negatives above; preserve consumed/revoked capability semantics |
| Unified rebuild | V3 facade delegate reaches actual canonical rebuild or chosen fail-before/fail-after boundary; no restore completion on any failure; no graph exposure through runtime startup |
| Integrity / restore completion | Distinct exact completion boundary faults; assert reached actual earlier stages, no later completion, unchanged exact Error/retryable result, every-exit authority cleanup |

The registered Ecto Repo pattern is already present in
`logical_v3_import_test.exs:123–143,514–548`. SafeSQL uses real Ecto metadata, so an
unregistered proxy module is invalid. The committed-but-error injection models
the existing uncertainty resolution branch with actual committed rows. It is not
an actual network-loss experiment. Merely hiding a successful Imported result
in the outer Restorer observer proves lost reply after known commit, and does
NOT qualify the Storage commit-result branch. Test-only SQL fault objects are
uniquely named, contain no user content, preserve original trigger/function/RLS
definitions, and are dropped in unconditional owned cleanup.

Actual native in-place retries that existing interfaces support MUST succeed on
the identical authenticated manifest AND destination. Reauthenticate a fresh
one-shot Replay rather than reusing consumed input. For pending and imported
Storage replay compare complete canonical rows, exact physical files/ciphertext,
seals, jobs/progress/receipts, admissions and singleton marker before/after; no
duplicates or foreign cleanup. Imported replay is read-only for objects. Wrong
manifest/hash/tag/root, foreign artifacts or mutated imported graph fail closed.

Keep these evidence classes separate:

1. Same-destination pending/imported **Storage replay** through native Restorer.
2. Complete Runtime rerun on the SAME destination when actual empty admission
   still succeeds, for example an authentication failure with unchanged empty
   destination. Require actual success and no duplicate effects.
3. Post-import/committed-rewrap **whole Runtime continuation limitation**. Native
   Runtime admission is empty-only; import replay verifies original-generation
   state; rewrap requires pending-owner/original-wrapper predicates; one-use
   integrity authority is consumed/revoked. After committed rewrap plus custody
   loss/consumption, frozen interfaces provide no durable same-destination whole
   Runtime continuation. Preserve exact original error and retryable flag,
   custody cleanup, barriers and graph invisibility. Do not call a transient
   failure corruption or change it to nonretryable to fit the test.
4. A fresh disposable target successfully restoring the original authenticated
   backup is **RESTART**, never RESUME. Qualify clean and supported replacement
   staging this way while the active installation remains untouched.

No journal can manufacture the missing raw-key-to-integrity-custody bridge.
Do not add unwrap/key extraction, a new recovered-key bridge, a new capability,
pending-owner bypass, permissive empty check, resume protocol, or Vault redesign.
The actual Astra clarification withdrew an earlier unconditional requirement
interpretation that EVERY late fault must support durable resume. That withdrawal
is not a source test result or permission to remove any fault/assertion. No
required test is weakened or skipped by this design clarification.

## 13. Synchronized governing amendments

These three amendments are submitted together with this design and its detailed
plan for independent review. The master design §8 and §11 and master plan Task11
carry the exact wording below; the amendment is not accepted until its actual
SPEC then NEW distinct fresh QUALITY close. All other acceptance/native/legacy
assertions remain required.

**A. Master design §8:** synchronized final paragraph:

> If plaintext verification or a later saga stage fails, the restored graph remains
> unpublished: maintenance and dispatch barriers remain enforced and restore does
> not complete successfully. Pre/import failures must prove transaction rollback
> and owned-object cleanup; post-import failures must prove zero graph publication
> or visibility without claiming rollback of completed import, rewrap or filesystem
> publication. Every supported native in-place retry must succeed using the
> identical authenticated manifest and destination identity, without duplicate
> objects, graph rows, jobs or source seals. Qualify Storage pending/imported replay
> separately from complete Runtime saga recovery. After committed rewrap and loss
> or consumption of integrity custody, the existing interfaces provide no durable
> same-destination continuation of the complete Runtime saga. Preserve the original
> failure's exact error code and retryable flag, custody cleanup and maintenance
> isolation; do not reclassify a transient fault to satisfy qualification.
> Characterize this boundary and operational recovery through a new restore using
> the established disposable-destination procedure: RESTART, never successful
> RESUME. Malformed destinations cannot resume with another manifest. Existing
> active installation and data remain unchanged. This removes no required fault
> barrier or assertion and authorizes no Vault, custody, key or lease change.

**B. Master design §11:** synchronized required deterministic acceptance bullet:

> Fault barriers at authentication/preflight, canonical insert, staged object
> publish, commit uncertainty, rewrap, ciphertext verification, durable-work
> reconciliation, authenticated plaintext/Document verification, unified search
> rebuild and integrity/restore completion prove rollback or unpublished
> maintenance recovery as applicable, in the existing saga order. Supported native
> same-manifest/same-destination in-place retries must succeed without duplicate
> objects, graph rows, jobs or source seals. Qualify Storage pending/imported replay
> separately from complete Runtime continuation, and separately characterize the
> post-rewrap custody-loss boundary in §8. Disposable-destination RESTART does not
> count as RESUME. Preserve every required error, retryable, custody, isolation,
> invisibility and no-duplicate assertion.

**C. Master plan Task11:** synchronized unchecked fault-barrier checklist item:

> - [ ] Add deterministic fault barriers at authentication/preflight, canonical
>   insert, staged publish, commit uncertainty, rewrap, ciphertext verification,
>   durable-work reconciliation, authenticated plaintext/Document verification,
>   unified search rebuild and integrity/restore completion in the existing saga
>   order. Assert rollback and owned cleanup for pre/import failures and an
>   unpublished maintenance graph after import failures, preserving every exact
>   error/retryable, custody-cleanup, dispatch/isolation and invisibility assertion.
>   Every supported native in-place retry must actually succeed on the identical
>   authenticated manifest and destination without duplicate rows, objects, source
>   seals or jobs. Qualify Storage pending/imported replay separately from complete
>   Runtime continuation. Characterize the existing no-durable-continuation boundary
>   after committed rewrap plus lost/consumed integrity custody; do not reclassify
>   transient failures or bypass custody to satisfy qualification. Separately prove
>   successful clean restore and supported disposable replacement staging while
>   active installation/data remain unchanged. Fresh disposable-target success is
>   RESTART, never successful RESUME. Retain every required barrier/assertion and
>   never claim distributed transaction rollback or authorize a frozen protocol
>   change.

This synchronized clarification leaves master Task 12's dependency unchanged and does
not alter Task 16, the release scope, frozen custody semantics or any legacy test.

## 14. Additive independent restore oracle

This is internal saga Task 12, a constituent of master Task 11, not the later
master Task 12 default switch. Its focused export/AST wiring contract may prove
entry placement and hard failure only; the full sole native task must separately
prove that every real knowledge check executes. No production injection seam or
fake oracle substitutes for that execution.

`mix singularity.test.restore` remains the sole independent restore-scoped
integrity oracle. Preserve its existing run → backup_source! → restore_destination!
→ assert_restored! → restore_v1_fixture! flow, old operator descriptors/prompts,
secret handling, real crypto, V1 golden `.backup` bytes/hash, V2 fixtures and every
old assertion. Keep its legacy backup dispatch `submitted: 1` assumption on that
legacy graph. The knowledge addition runs after legacy resource cleanup with
fresh owned sequential databases and its own actual event accounting.

Runtime and Storage `test/support` compile only under MIX_ENV=test. A lib Mix task
must not gain static calls/struct expansion to absent test modules that fail
dev/prod warnings-as-errors. After existing `assert_test_environment!`, use an
additive guarded dynamic entry: require `Code.ensure_loaded?` for the test-only
knowledge oracle and `function_exported?` for its documented entry, then `apply`.
Absence is a hard test-task failure, not a skip. Keep support-module names as
module atoms and preserve normal non-test compile behavior. Nested task-local
helpers are an alternative only if needed to retain that boundary without a
new production dependency.

The knowledge oracle independently asserts the fixed canonical cut, all-state
source relationships, real wrapper/recovered-key/native summary path, public
search, every retained original's actual binary equality, and negative corruption
through an actual late native verification boundary. It must not merely call
ExUnit test files or print a marker. Shared fixture construction is permitted;
expected fixed projection/source-byte/search assertions remain explicit and
independent of production codecs/digests. Report old legacy and new knowledge
outcomes separately, and fail the sole task if either fails.

### Standalone transport ownership repair — 2026-10-17

Native76 failed after the unchanged legacy V1/V2 flow completed: legacy cleanup
correctly restored the deliberately unusable test repository defaults, so the
new standalone source inherited `127.0.0.1:1`. Integration fixture success did
not prove this entry boundary; its runner configures live connections first.
Preserve this actual failure and the original after-cleanup entry requirement.

Inside the new oracle block only, own a saved/restored configuration scope
around all four cases. Materialize the five established repository roles from
the required `PGHOST` Unix socket and strictly parsed `PGPORT` (1–65535), removing
stale URL/hostname and setting `url: nil`. Preserve database/pool/other options;
existing fixture ownership still selects each fresh database and owns startup.
Restore every incoming repository configuration exactly, including absence,
on normal return and callback failure. A test-only `with_postgres_transport!/1`
entry may expose this scope to focused tests without opening any connection.

Do not start ordinary runtime before isolation, create an extra baseline
database, change shared fixtures or TestEnvironment, or alter frozen/runtime
production behavior. Add focused success, callback-failure and invalid-port
contracts before implementation; all existing entry assertions stay intact.
Those no-connection contracts are not native proof: rerun the exact sole task
and require old V1/V2 plus all three V3 positives and late native denial, followed
by natural ordinary residual cleanup and final independent source reviews.

### Accepted prerequisite architecture attribution repair — 2026-10-17

Native97's ordinary `mix test` completed with seven failures in the existing
Web architecture owner: six original-byte checks did not attribute the accepted
native-text API changes, and one authority check still selected the pre-Task10
"Draft" heading. Preserve Native97 as FAIL. These are necessary test-contract
and documentation compatibility repairs, not permission to change production
behavior, reset a historical hash, or omit any required check.

The Runtime API is unchanged from accepted native-text commit
`6fd422a6987121d02e54a8cc6395061880ec903f`, SHA-256
`8557685c2415c5ee3b30e33be6dfaab6e4ee25b0772bb3123a92384a914c33b4`.
Extend only the Web architecture owner's Phase5 normalization with literal
inverse replacements for that commit's eleven original context-bearing hunks.
Fix old/new bytes and context digests independently from that accepted diff;
require each new context exactly once. Do not globally forbid short old
fragments that legitimately recur elsewhere. Inversion must recover the exact
pre-native-text API SHA-256
`6212a126be413c4b19bc0e24e8cc3c86f1e8ce776ebd2e8a7427ee2e2695fda1`.
Then the unchanged historical Phase4/3/2 stripping must still recover the original
`6c3e8d5afb2cc9dbf264d276796070e16aa49e55` baseline, SHA-256
`eded245a1bd95410b323192de836c9b1de8cec14de4b26cb8e41263d66ebf3c4`.
Retain all original baseline hashes, registrations and negative assertions.

Add actual-source, non-vacuous counterproofs for every hunk: changed bytes,
removal/reversion, duplication, relocation, and changed preceding/following
context must fail the actual normalizer or unchanged historical byte contract.
Also reject a distinct unrelated legacy modification. Prove each mutated source
differs, the intended mutation really occurred, and unrelated bytes remain.
The unchanged current source is the required positive control; diagnostic
in-memory probes alone are not ExUnit qualification.

Task10 commit `94efb34ae128298ab62bfbd7b77d387b882bbb62` accepted the current
`## Status, evidence and execution boundary` title. Synchronize that exact title
in the authority test and the master plan's Task0 instruction, without renaming
the current status back to Draft. For this Phase5 plan only, extract active
authority from exactly one complete-line start and end heading in correct order,
requiring them to be the first and second level-two headings. Reject missing,
altered, duplicated, reordered, relocated or inactive headings. Preserve every
existing authority marker and prohibition; moving one outside the interval or
replacing it with quoted/commented/fenced text must fail. Do not broaden this
structural rule to historical helpers with non-heading end markers.

The only additional source owner is
`apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs`;
the parent owns this amendment, its detailed plan and the one Task0 title sync.
Add focused failing counterproofs before changing normalization/section behavior,
then require the entire architecture owner, retained governance/dependency owners
and the complete permitted README gate on the final exact source. Independent
design review precedes implementation; final combined SOURCE SPEC then NEW
distinct QUALITY remains required before local commits or Task11 acceptance.
Production API, frozen56, default V2, Task16, native work, E2E and publication
restrictions are unchanged. E2E stays NOT RUN.

### Native107 prerequisite fixture and environment recovery amendment — 2026-10-17

The bounded governing amendment is
`docs/superpowers/specs/2026-10-17-singularity-v0.2-phase-5-prerequisite-fixture-compatibility-design.md`
with its matching detailed plan. It preserves Native107 as incomplete with five
observed failures, adds only the two named Storage test owners for coherent
strict-text and controlled queue-isolation fixture repairs, and permits ordinary
recovery of the exact original private PostgreSQL cluster with a two-PID-only
derived guard. Independent design reviews precede work; final combined source
reviews cover these two additional owners. No production/frozen/source-contract
relaxation, ordinary assertion reduction, early acceptance or E2E is authorized.

### Native134 upload-stage controller-exit observation amendment — 2026-10-17

The bounded diagnostic design is
`docs/superpowers/specs/2026-10-17-singularity-v0.2-phase-5-upload-stage-exit-observation-design.md`
with its matching detailed plan. Native134 ordinary full unit remains FAIL;
the unchanged standalone owner PASS does not repair it. Permit only the reviewed
reversible observer in the named real-file controller-exit and late-invalid-text
cases (the Native142 amendment), with exact restoration
and no deadline/work/assertion change. A narrow derived diagnostic source guard
may exclude only that original test row from two legacy registries while the full
current manifest pins its observed bytes. Frozen56 and every other pin remain.
No observer or guard exception may remain active for final qualification.

### Native154 admission acquisition observation amendment — 2026-10-17

The bounded diagnostic design is
`docs/superpowers/specs/2026-10-17-singularity-v0.2-phase-5-task11-admission-observation-design.md`
with its matching detailed plan. Native154 literal NOARGS full integration
remains FAIL at the admission case's original60000ms aggregate watchdog,
before destination callback entry. Native155 ordinary residual check is0/EMPTY.
Permit only the reviewed reversible observer inside the Runtime live owner's
NEW Task11 block, preserving every assertion, native operation and timer.
Only admission installs existing checkpoint observations; no fixture, helper,
production or guard exception changes. Exact original4167/860295eb restoration
is required before repair or qualification. The single existing sentinel120s
exception is not extended. Diagnostic PASS does not replace the failed full gate.

### Native160 admission full-context observation successor — 2026-10-17

The first single-owner observation completed51 actual tests/0 failures and the
admission case23165ms, without reproducing Native154's failed60s context.
Native161 ordinary residual check was0/EMPTY and source was restored exactly
to4167/860295eb. The first allowance is consumed; Native154 remains FAIL.
Both independent causal/contract assessments recommend missing full-workload
stage evidence, not a guessed repair or arbitrary watchdog increase.
The separate candidate design
`docs/superpowers/specs/2026-10-17-singularity-v0.2-phase-5-task11-admission-full-context-observation-design.md`
and matching detailed plan require NEW design/source reviews and root GO before
ONE `mix singularity.test.integration --seed 97250` diagnostic with the SAME
reversible observer. Keep original60s/one sentinel120s, all native work/assertions,
outer ExUnit on_exit/internal deadlines, exact removal and no guard exception.
Seeded diagnostic PASS is not the required literal NOARGS gate or acceptance.

## 15. Verification and acceptance

This author ran READ-ONLY source/document inspection and draft self-review only.
NO Mix, VM, formatter, SQL, database, service, E2E, Git mutation, commit, publication
or runtime verification was executed. All proposed Task 11 native checks are
NOT RUN. There is no fabricated RED/GREEN or design/source acceptance.

After prerequisite handoff and independent design/plan reviews, the implementation
plan must introduce focused failing contracts before behavior changes and retain
their complete owning files. Native/SQL tests are serialized under parent-owned
infrastructure, with owned cleanup verified after each complete invocation.
The three required Task11 Mix argument lists from the master plan remain
unchanged. In this inspected worktree the parent invokes each directly through
the already qualified private-PG wrapper (never inner bash -c or environment
dumping), with a fresh owned raw log and ordinary residual check afterward:

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix test apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs apps/singularity_runtime/test/singularity/runtime/restore_vault_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.restore
```

The detailed plan also includes the complete retained owners for native-text
prerequisite, V3 import/preflight/Document integrity/unified rebuild, V1 golden
and V2 compatibility, not merely matching test names. Run required static checks
including test and non-test warnings-as-errors where dynamic oracle composition
could affect compilation, format, dependency architecture, seven applications and
zero xref cycles, frozen registry verification and diff checks. Before Phase 5
local acceptance run the complete permitted README gate; omit ONLY the user's
explicitly forbidden E2E execution and report it NOT RUN. A failed executed
required gate blocks acceptance and advancement. Document any environment blocker
and what was not validated; preserve all failed evidence and cumulative repair
counters. Default V3 work remains separately gated.

The historical frozen registry remains
`.devenv/phase5-frozen-baseline.sha256`, expected registry SHA-256
`d0296d241c66e382baa09a0a092fe8add6df66364d5f2d5644f4f4ea1963a050`,
43 released migrations plus 13 frozen source files. Never regenerate it from
modified files. Parent checks it and additional accepted-source/native-text seals
at task boundaries. No Vault semantic/feature work, frozen lease/reader/digest/
bundle wire change, role/grant change, dependency, migration, merge, push, version
bump, tag, release, deploy, production activation/backfill or E2E is permitted by
this design.

Acceptance requires actual successful native UUID, historical canonical and mixed
full sagas; exact source/import cut comparisons; every retained object's observed
plaintext bytes; typed native summary and C(P) size barrier; causal digest/cipher
denial; the entire independent malformed/fault matrix; supported exact replay
success without duplication; explicit unsupported continuation characterization;
clean and supported replacement staging; complete legacy/independent oracle and
permitted gates; cleanup; actual source SPEC then distinct fresh QUALITY. No
acceptance item can be checked off by a source-only preparation report.

## 16. Source questions and self-review record

No missing production interface, new product decision, or frozen custody change
is asserted. Remaining feasibility checks are explicit causal test obligations
for the reviewed implementation plan: exported-snapshot observation must prove
equality with the real worker snapshot; test-only historical aliases must commit
lawfully and preserve real local physical identity; wrong-size/digest fixture
composition must reach authentic native import rather than fail earlier admission.
Each has a concrete current seam above. Source review resolved the specific
question of hidden worker-local canonical DML before export: none occurs in the
inspected path. The other causal obligations remain NOT RUN, as do all native
Task 11 checks. Failure to establish one is a design finding, not permission to
substitute a known hash, stale cut, fake wrapper/material loader, or weaker
assertion. No implementation is authorized before independent acceptance of this amendment.

Source references inspected for the exact interfaces include:

- Runtime `restore_vault.ex`, `integrity_audit.ex`, `job_dispatcher.ex`,
  `backup_vault.ex`, `application.ex`, `documents/extraction_reconciler.ex`,
  `key_custodian.ex`, `download_lease.ex`, `assets/delete.ex`, `assets/cleanup.ex`,
  and the independent restore Mix task.
- Storage `backup/exporter.ex`, `restorer.ex`, `knowledge_integrity_inventory.ex`,
  `knowledge_integrity_audit.ex`, `local_filesystem_adapter.ex`, `local/path_guard.ex`,
  `jobs/generic_worker.ex`, `jobs/worker_scope.ex`, `scoped_repo.ex`,
  `postgres/custody_repository.ex`, `postgres/asset_deletion_repository.ex`,
  `safe_sql.ex`, V2/V3 schema definitions and
  released object/admission migrations (read-only).
- Existing native-text restore/ingestion tests and `NativeAssetFixture`,
  `KnowledgeBackupFixtures`, `KnowledgeFixtureResourceOwner`,
  `logical_v3_import_test`, `document_restore_integrity_test`, and
  `restore_import_test`. Existing APIs are distinguished from proposed support.
- All six assigned source-only preparation reports were read fully. Historical
  unaccepted statuses there are not substituted for the parent's current handoff.

Self-review checked scope, identity/provenance, custody/wire freeze, real versus
synthetic evidence, exact snapshot timing, import-before-recovery observation,
canonical-versus-normal publication labels, original-versus-projected inventory,
byte-versus-hash observation, fault stage reachability, retry wording in all three
governing locations, test-support compilation, no assertion weakening, Task 12 and
Task 16 gates, E2E prohibition and explicit unrun status. This is author self-review
only. No independent SPEC/QUALITY verdict is claimed. The parent fully read the
original author draft and its parent-reviewed preparation, fixed exact support
ownership, unified-search API naming and explicit protocol-versus-native-crypto
evidence classification, and synchronized the prerequisite clean handoff and
three governing amendments. The separately authored detailed plan and actual
independent design/plan reviews remain required. All preparation commands
naturally CLOSED; no VM/test or source implementation occurred.

## Native166 failure-boundary observation successor — 2026-10-17

The admission full-context diagnostic is complete/natural2 (2083actual/2FAIL):
admission UNREPRODUCED24877ms; initial native-asset bootstrap checkout and genuine
foreign-header first password verify failed before their required assertions.
Native167 ordinarypost0/EMPTY; separate exact observer removal restored Runtime
owner860295eb, then original guard1526/status40/indexEMPTY/owned0 PASS.
Both admission measurement allowances are CONSUMED;154FAIL remains.

A NEW independent read-only causal/contract decision recommends no admission
retry or budget change. The initial two-failure observation proposal is now
amended to retain only foreign-case observation under:
`docs/superpowers/specs/2026-10-17-singularity-v0.2-phase-5-task11-native-failures-observation-design.md`
and `docs/superpowers/plans/2026-10-17-singularity-v0.2-phase-5-task11-native-failures-observation.md`.
Before any source GO these receive independent DESIGN SPEC -> NEW QUALITY.
Temporary ownership is NOW limited ONLY to foreign-header case/necessary reversible
observation wrappers in Runtime live Task9/shared password helper. Ingestion remains
EXACT264/11320/c52d71d7; no connection metrics/callback markers were executed.
The Runtime observer lies
outside NEWTask11, so its strict temporary inverse must first restore original
860295eb before wholeNEWTask11 inverse e897f3e6 is asserted.
This is the ONLY temporary old-test observational exception here; existing
NativeAssetFixture/MTE/RuntimeFixture/production/frozen56 remain exact.
No genuine operation, assertion, timeout, crypto cost or semantic contract changes.
The ONE later diagnostic selects BOTH complete files (expected58actual), seed97250,
without addedWAE; it is not fullsuite/master/retained qualification.
Exact restoration, ordinary closure and fresh independent continuation are mandatory.
All final required gates, defaultV2, Task16 unwaived/Task17NOTGO and E2E NOTRUN remain.

## Pre-Native source-pin discovery and narrower successor — 2026-10-17

The initial successor's two static observers were authored and root-verified,
but ORIGINALguard27566dfd correctly rejected ingestionA238e0e1c against TWO
immutable historical qualified-code/native-common originalc52d71d7 pins.
Current-generation repinning did not and cannot replace those assertions.
No formatter/VM/measurement was launched; no checksum or guard was bypassed.
A NEW independent contract decision recommended explicit diagnostic reduction.

A fresh bounded author withdrew ONLY A's3hunks; root complete-source equality and
inverse restored264/11320/c52d71d7, B stayed4280/164028/be501963,
other1538/status43->42/HEAD/indexEMPTY passed, then ORIGINALguard1542/owned0 PASS.
AuthoredA and original archives remain immutable0600. This is withdrawal, not
repair or measured success: initial-checkout QuestionA stays UNOBSERVED/unresolved.

The matching successor design/plan above now permit ONLY Runtime observerB.
NEW amended DESIGN SPEC -> NEW distinct QUALITY, formatter/check with ordinary
closure, then actual SOURCE SPEC -> NEW distinct QUALITY are mandatory.
The SAME ONE complete-two-file vector58actual/seed97250 remains, ingestion exact
and uninstrumented. B removal must restore860295eb before wholeNEWTask11 inverse
e897f3e6; exactstatus42/originalguard/historical/frozen manifests stay enforced.
All failed evidence, assertion/timer/final gates, Solrepair0/Astra0, defaultV2,
Task16 unwaived/Task17NOTGO and E2E NOTRUN remain unchanged.
