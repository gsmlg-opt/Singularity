# Phase 5 Retained Backup-Reader Grant Contract Implementation Plan

> Use parent-managed execution and disjoint Sol ownership. Checkboxes record
> actual evidence only; all sources are frozen while a gate runs.

Goal: restore precise retained security contracts for already accepted worker
backup reads without removing any mutation/owner-isolation/cleanup assertion.

Design: [retained backup-reader grant contract](../specs/2026-10-12-singularity-v0.2-phase-5-backup-reader-grant-contract-design.md).
Status: bounded implemented test contracts locally qualified. Historical design
d19067aa/plan d68e4320 received actual independent SOURCE SPEC/distinct fresh
QUALITY before authoring. Current Rls e24dcace/Grants efd5c7c8 pass focused15/0,
complete retained16 (344actual/0,3 non-SQL exclusions), whole legacy pure5/0,
normal cleanup/static/frozen checks and final actual SOURCE SPEC then distinct
fresh QUALITY. Historical failing output remains FAIL. Task9C may proceed;
Phase5 and complete compatibility restoration remain unaccepted.

## A. Evidence and review before authoring

- [x] Close live complete retained16 SQL50680 normally; retain available failed output
  (explicit truncated chunk),
  actual count/exclusions/exit, selected-file receipt and bounded recovery
  cleanup (the timed-out case interrupted normal cleanup).
- [x] Verify original two test, actual grant-helper, accepted00500/00600 and
  frozen56 hashes. Do not revoke correct durable grants or change helpers.
- [x] Actual independent nonauthor SOURCE SPEC reviews complete design/plan,
  full owning cases, literal approved matrix, cleanup timing and baseline RLS.
- [x] Distinct fresh actual-source QUALITY follows; resolve blockers and record
  both exact reviewed documents/source hashes. Sync masterTask9/report.
- [x] Only after BOTH reviews AND closed gate: parent test-author GO; disjoint
  Sol Task13 Repository-test author may proceed independently. All authors stop
  before formatter/Mix/tests/SQL. No test mutation overlaps a running gate.

## B. Parent-only two retained test edits

Ownership ONLY knowledge_rls_test.exs and knowledge_grants_test.exs.
Other workers are present; preserve their Task9B/Task13 changes and unrelated
files. No production/support/helper/config/migration/permission edits.

- [x] Keep both Rls/thirteen Grants cases and all required assertions/timeouts.
  Encode the design's exact web and seven-table worker SELECT baseline.
- [x] Separate tags SELECT/INSERT expectations before/after temporary grants;
  post-rollback worker scoped read is exactly empty. Keep DML/GUC/backend checks.
- [x] Align every cleanup/baseline expected privilege, preserving receipt denial,
  lifecycle/private-function denials, exceptions/throw and helper allowlist.
- [x] Canonical four-role/seven-privilege/RLS/FORCE-RLS matrix plus exact
  nongrantable ACLs include only authorized worker SELECT. Stable role-name
  ordering, no observed-privilege-derived expected values.
- [x] Missing-scope worker reads return empty on seven tables; receipts/seals,
  dispatcher/pre_auth native42501 and every mutation denial remain.
- [x] Extend genuine baseline Document reads to web and worker; prove exact
  matching/foreign-version/mismatched-owner/revoked rows without temporary grants.
  Add real worker organization baseline missing/matching/foreign contexts before
  existing grant block and revoked empty rows after cleanup.
- [x] Parent reads full narrow diff, confirms no assertion/case removal or helper
  change, closes all authors, formats only changed files, records immutable receipt.

## C. Complete gates and actual final review

- [x] Parent complete focused retained security owners, with actual counts,
  warnings-as-errors, default timeout, full output archive and cleanup:

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs --seed 215378 --warnings-as-errors
```

- [x] Parent repeats EXACT unchanged complete retained16 owning selection.
  All source/test/support remain frozen; focused success alone is insufficient:

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_digest_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_schema_ddl_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_historical_admission_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_asset_lifecycle_guards_test.exs apps/singularity_storage/test/singularity/storage/note_source_set_sealing_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs apps/singularity_storage/test/singularity/storage/knowledge_schema_test.exs --seed 215378 --warnings-as-errors
```

- [x] Verify exact privileges/ACLs, real baseline owner filtering, no mutation
  leakage/new failures, normal exits, allocated DB/root cleanup, zero warnings.
  Match new selected-source receipt, unchanged helper/accepted grants/frozen56.
- [x] Required formatting, compile warnings-as-errors, unchanged seven-app graph /
  zero xref cycles and git diff --check. Preserve all earlier failed evidence.
- [x] Actual final nonauthor SOURCE SPEC of two full test edits, then distinct
  fresh QUALITY, exact receipt/verdict/remaining risks recorded.
- [ ] Parent includes the qualified test-contract edits in the bounded combined
  compatibility TaskF local commit. Admission contains pending Task9B cases and
  must not be committed without their required00700 implementation. Complete16
  GREEN plus final reviews unlock Task9C, not Phase5 acceptance. Task13 qualified
  independently with114pure/48SQL/static/final reviews and localcommit09f8ee0;
  Task14's own test-first implementation and qualification remain required.

E2E NOT RUN/manual-only. No skipped/weak assertion, production/helper/grant/
Vault semantics changes, merge/push/version/tag/release/deploy/activation/data.
