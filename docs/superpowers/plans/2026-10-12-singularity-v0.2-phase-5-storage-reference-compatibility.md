# Phase 5 Storage-Reference Compatibility Implementation Plan

> **For agentic workers:** Use the applicable subagent-driven-development or executing-plans skill under parent-managed ownership. Steps use checkboxes. Actual design SPEC and fresh QUALITY passed; preceding Task8 acceptance and causal RED still gate dependent implementation.

**Goal:** Preserve ordinary UUID and accepted canonical-path references through V3 restore without changing frozen custody or original evidence.

**Architecture:** Keep authenticated/persisted inventory `I` unchanged. A Storage-owned, V3-only adapter validates its saga/persisted binding and derives UUID inventory `N(I)` for the existing lease and ciphertext summaries. Document integrity consumes original `I` and verified plaintext hashes.

**Tech stack:** Existing Elixir/OTP, PostgreSQL/Ecto, LocalFilesystemAdapter and authenticated restore adapters; no new dependency.

Status: DESIGN REVIEWED — implementation gated by Task8, 2026-10-12. Governing
[design](../specs/2026-10-12-singularity-v0.2-phase-5-storage-reference-compatibility-design.md)
and [master Phase 5 plan](2026-10-11-singularity-v0.2-phase-5-export-backup.md).
HEAD at preparation: `38b16f5d4a1f5d870a74d3e3093b3e2a2a0c5041`.
No tests run for this document. Architecture counters: Sol 0/Astra 0, no repair consumed.
Actual distinct independent design SPEC and fresh QUALITY passed draft SHA256
`448b2b83a1e301223eebbd2e610feeb8e27b3024f495084dab9cc5b8c217dfb1`.
Parent factual records are named in the governing compatibility design.
Only review status/citation metadata changed afterward; implementation/runtime
acceptance and every unchecked causal gate below remain pending.

## Ownership and execution rules

The parent owns formatter, Mix, SQL, services, test serialization, review and Git.
Workers are not alone: preserve Task 8/13 and unrelated edits; freeze source
during parent verification. Use complete owning files/default timeouts for
acceptance. Record actual RED/GREEN commands, exits, counts, excluded coverage,
source hashes and cleanup. Never delete, weaken, skip or relabel assertions.
Necessary goal-serving compatibility amendments are allowed after design/review;
the file map below is responsibility, not a reason to bypass a real scope conflict.

Storage implementation owner:

- Create `apps/singularity_storage/lib/singularity/storage/backup/knowledge_integrity_inventory.ex`.
- Modify `apps/singularity_storage/lib/singularity/storage/backup/knowledge_preflight.ex`, `restorer.ex`, and `integrity_audit.ex` (last two in the same `backup/` directory).
- Create `apps/singularity_storage/priv/repo/migrations/20261011000700_knowledge_restore_storage_references.exs`.
- Create `apps/singularity_storage/test/singularity/storage/backup/knowledge_integrity_inventory_test.exs` and `document_restore_integrity_test.exs`.
- Extend existing `backup/knowledge_preflight_test.exs`, `knowledge_restore_admission_test.exs`, `logical_v3_import_test.exs`, `restore_rewrap_test.exs` and `test/singularity/storage/integrity_audit_test.exs` under the Storage application.

Runtime owner modifies `apps/singularity_runtime/lib/singularity/runtime/integrity_audit.ex`
and its complete `test/singularity/runtime/integrity_audit_test.exs`. Parent owns
governing documentation synchronization and later Task 11 live/oracle tests.
No change to any of the 56 frozen files, existing migration, lease, reader,
physical adapter, key material, grants, policy, default V2 or production data.

## Task A: Close preceding Task 8 writer repair and design reviews

- [ ] Parent finishes the separate exact two-form `00600` writer correction's
  causal full-owner RED, source implementation, full gates, SOURCE SPEC and fresh
  QUALITY. Its current UUID tests are SQL shape evidence only; preserve that label.
- [ ] Parent reads both new documents completely, obtains independent design SPEC
  then fresh QUALITY, records exact reviewed hashes, and links them from the
  governing Phase 5 documents. Resolve findings before dependent implementation.
- [ ] Verify actual baseline/dirty ownership and the unchanged frozen registry:

```sh
git rev-parse HEAD
git status --short
sha256sum .devenv/phase5-frozen-baseline.sha256
sha256sum -c .devenv/phase5-frozen-baseline.sha256
```

Expected registry hash is `d0296d241c66e382baa09a0a092fe8add6df66364d5f2d5644f4f4ea1963a050`;
all 56 entries must match. Never regenerate the registry to accept drift.

## Task B: Characterize and correct V3 preflight/deferred admission

Depends on A. Storage owner; parent runs commands.

- [ ] Add independent UUID-positive and wrong-UUID/path-negative cases preserving
  existing canonical-path fixtures. Prove both preflight and actual deferred
  commit: complete canonical digests, loading/validated admission, finalizer and
  rollback assertions remain active. New tests must expose each old predicate,
  not stop at an earlier rejection and claim both boundaries characterized.
- [ ] Run the complete preflight/admission owners below; record the causal failures.
- [ ] Implement only two-form reference agreement in preflight and additive
  `00700`. Use an exactly-once expected-clause transformation or reviewed complete
  function replacement. Compare before/after `pg_get_functiondef`, owner/ACL and
  settings; assert all other body text and security attributes remain equivalent.
- [ ] Run the same owners GREEN, then Task F's complete retained gate. Preserve
  accepted `00300` and its destination digests/deferred validation unchanged.

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs --seed 215378 --warnings-as-errors
```

## Task C: Implement the two-view adapter and original-evidence binding

Depends on B; no Restorer/Runtime routing change until the adapter's own RED exists.

- [ ] Add complete-file tests for `project(storage, cut)`, `prepare(repo, storage,
  imported)` and `load_plaintext_material(context, binding, projected_entry)`.
  Cover UUID identity, canonical/mixed conversion, exact non-reference equality,
  order/count, canonical IDs, duplicate physical identities, wrong paths/UUIDs,
  unknown logical version and path conversion through a nonlocal adapter.
- [ ] Add SQL counterproofs for wrong manifest ID/hash/tag, original inventory
  hash, owner/count/status/root, unequal original cut/handoff, missing/extra
  objects, changed persisted reference/metadata and wrong projected position.
  Compare existing Restorer saga hashing against the new helper byte-for-byte.
- [ ] Run both commands below RED; absence of the new module alone is initial RED,
  not proof that the binding counterexamples are meaningful.
- [ ] Implement explicit authenticated-version dispatch and design interfaces.
  `prepare` checks existing imported saga and original rows in a consistent
  migration transaction. Loader checks the original entry then delegates the
  EXACT projected single entry to the existing four-key-binding loader in that
  same transaction; return its wrappers/material without alteration. Do not
  return raw keys, widen legacy inventory validation or create authority flags.
- [ ] Run both owners GREEN; assert invalid bindings do not call the base loader,
  and real SQL cases prove connection/snapshot consistency and persisted refs.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/knowledge_integrity_inventory_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_integrity_inventory_test.exs --seed 215378 --warnings-as-errors
```

## Task D: Compose unchanged lease and honest integrity summaries

Depends on C. Storage owns Restorer; Runtime owner coordinates its separate file.

- [ ] Add RED in `restore_rewrap_test.exs` for genuine V3 prepare errors occurring
  before issuer/commit, original Imported/Rewrapped equality, exact UUID lease
  inventory, wrapper context and unchanged legacy option behavior. Retain issuer
  failure, commit failure/revocation and all old credential/rewrap assertions.
- [ ] Add Runtime RED proving both ciphertext entrypoints derive the same `N(I)`
  while retaining original `I`; reject cut mismatch and actual-summary mismatch.
  Fakes record exact arguments/order and prove denial, not real custody success.
- [ ] Parent runs Task E's complete pure command and the integration command
  below. Record expected failures before implementation.
- [ ] Make Restorer options preparation return `{:ok, options}` or Error and
  propagate before `issue`. Select V3 from authenticated `cut.logical_version`.
  Keep legacy options, original handoffs, key values and issuer lifecycle intact.
- [ ] Runtime keeps original-cut equality, uses projected inventory for ciphertext
  and actual lease-summary comparison, and retains original inventory separately.
  Leave `StorageIntegrityAudit.inventory_sha256/2`, V1 encoding and structs intact.
  Never replace summary digests or present converted inventory as original cut.
- [ ] Rerun owning commands GREEN; independently inspect the dataflow and unchanged
  lease/reader hashes. This still does not qualify Task 11 live restoration.

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
```

## Task E: Complete Task 9 Document plaintext verification

Depends on D. Storage/Runtime owners coordinate; retain the master Task 9 requirements.

- [ ] Add RED covering retained historical/deleted Document originals, Asset-only
  entries, wrong plaintext with matching ciphertext evidence, wrong size/digest,
  absent/duplicate/extra/unordered hashes, foreign owner/manifest, mutated original
  refs and ready historical extracted-text mismatch.
- [ ] Implement `verify_document_sources(repo, binding, original_inventory,
  plaintext_hashes)` with exact saga/original inventory identity and full closure.
  Runtime calls it after plaintext-summary validation and before rebuild/audit
  completion, passing ORIGINAL `I`. Require callback availability; update existing
  recording fake while preserving rebuild assertions. Errors deny completion and
  leave committed destination unpublished; do not claim rewrap rollback.
- [ ] Run complete integrity owners RED before the change and GREEN afterward:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/integrity_audit_test.exs apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
```

## Task F: Retained gates, independent review and bounded local handoff

Depends on B–E. Parent only. Existing counts are historical evidence, not expected
new totals: preflight 39, import owners 32, historical admission 24, complete
retained selection 334 actual SQL, separate legacy pure 5 and downstream 186.
Run every whole file below; report actual new totals and separately cover exclusions.

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_digest_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_schema_ddl_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_historical_admission_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_asset_lifecycle_guards_test.exs apps/singularity_storage/test/singularity/storage/note_source_set_sealing_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs apps/singularity_storage/test/singularity/storage/knowledge_schema_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_bundle_verifier_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_core/test/singularity/core/knowledge_export_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
sha256sum -c .devenv/phase5-frozen-baseline.sha256
git diff --check
```

- [ ] Rerun the separate Task 8 complete exporter/security and pure owning gates
  from the master plan because writer/restore predicate agreement is required.
- [ ] Record exact source/migration lists, unchanged accepted migrations/frozen56,
  test results, SQL function equivalence/ACL evidence and residual risks. Obtain
  actual nonauthor SOURCE SPEC then separate fresh QUALITY on that exact diff.
- [ ] Parent makes a small local reviewed commit, preserving unrelated files:
  `fix(restore): preserve v3 storage references across integrity verification`.
  Record commit SHA and exact verification scope; no publication or phase acceptance.

## Task G: Required Task 11 live qualification before Task 12

Depends on F and master Task 10. Parent owns the existing Task 11 live fixture,
`apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs`,
`apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs`
and the narrow knowledge-oracle additions in
`apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex`.

- [ ] Add mandatory actual normal Asset finalization → UUID persisted reference →
  explicit V3 export/authentication/preflight → real deferred admission commit →
  unchanged lease/real wrappers/ciphertext/AEAD → Document digest/search/completion.
- [ ] Also qualify preserved canonical-path and mixed inventories with real local
  encrypted bytes and unchanged lease, plus wrong headers/wrappers/plaintext,
  mutation and saga failures. Compare exact original refs, canonical pins, bytes
  and both inventory views. Keep all existing frozen fixtures and legacy assertions.
- [ ] Run the master Task 11 complete live/legacy commands and independent
  `mix singularity.test.restore` oracle; record actual results and independent
  SPEC/fresh QUALITY. Fakes and Task 8 SQL-shape tests cannot substitute for this.

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs apps/singularity_runtime/test/singularity/runtime/restore_vault_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.restore
```

- [ ] Only qualified Tasks 8–11 permit the separate Task 12 default change.
  Complete permitted README acceptance remains master Task 19; E2E is NOT RUN.
  Architecture completion, these documents and earlier green gates grant no
  production activation, release or browser acceptance.
