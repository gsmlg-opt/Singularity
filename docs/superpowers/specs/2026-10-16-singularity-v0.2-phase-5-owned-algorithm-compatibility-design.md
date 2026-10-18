# Phase 5 Owned-SQL Algorithm-Metadata Compatibility Design

Date: 2026-10-16. This additive amendment completes the algorithm compatibility
boundary exposed by Task 6 of the native V3 saga. Continuous development
authorization selects the recommended repair without renewed routine approval.
Document review, causal RED, required GREEN and actual source reviews remain gates.
No phase, browser, release or production acceptance is claimed.

## Evidence and bounded outcome

Worktree .trees/v0.2-phase-5-export-backup; branch
codex/v0.2-phase-5-export-backup; HEAD
fed04c1259450a6be3e8ce5bf6a9a1e03c9758c8. Existing ten dirty paths are preserved.

The preceding preflight amendment accepts exactly aes_256_gcm and aes-256-gcm
in core.vault_key_versions. Its complete Preflight and LogicalV3Import gate
passed 78 tests with zero failures. Actual bootstrap still writes aes-256-gcm;
source persistence and export preserve it unchanged.

The subsequent full Runtime/search/restore gate failed two new native UUID
sagas, with 46 executed, 44 PASS and 2 FAIL. A fresh independently safety-reviewed
reuse of the fixed25-MFA caller-only argument-free diagnostic then ran the entire
Runtime owner: 14 executed, 12 PASS and 2 FAIL, natural exit2, 251.8 seconds.
Both cases passed all three preflight semantic traversals, native row import,
source finalization, ordinary constraints and exact digest comparison, then
entered KnowledgePreflight.validate_destination/2 and returned nonretryable
backup_invalid before publish_objects/2. No later successful hook was reached.
The exact inner SQL predicate was not observed by call-only tracing.

Actual receipt .devenv/phase5-task11-v3-task6-post-repair1-probe1-failure.md
SHA256 4bfc2f54be550e75b4dd2fa1d9971947a4c0a48590cca4d0bc1cf04eefb3d7b1
records safe raws, source291 seal, exact commands, final guards and EMPTY PG post.
All six failed Task6 Runtime runs remain failures.

Independent read-only source audits establish the remaining contract mismatch:

- Released 20261011000300_knowledge_restore_admission.exs embeds the
  underscore-only core.vault_key_versions predicate into
  audit.assert_knowledge_restore_graph(uuid).
- KnowledgePreflight.validate_destination calls audit.validate_knowledge_restore,
  which calls audit.assert_knowledge_restore_destination and that graph function.
  SQL rejection rolls back the admission savepoint and returns backup_invalid.
- Forward migration 20261011000700 changes only its storage_ref predicate.
  Current final migration 20261011000800 handles recovery provenance and does not
  alter this graph algorithm predicate.

A controlled structural import contract varying only the algorithm must fail on
the old SQL before production edits. This is not native custody proof.

## Alternatives and decision

1. Recommended: a new forward migration replaces exactly one table-specific
   predicate inside the existing owned function. Keep the previous storage_ref
   repair, all other function bytes and attributes, all source values and all
   cryptographic behavior.
2. Editing a released migration is rejected: it does not repair existing
   databases and violates migration immutability.
3. Rewriting bootstrap/source values, bypassing destination admission, broad
   algorithm acceptance, a caller-installed validator or new grants is rejected:
   each hides the real native contract or expands frozen behavior.

The exact old SQL substring is:

~~~sql
EXISTS(SELECT 1 FROM core.vault_key_versions WHERE (generation>0 AND state IN ('pending','active','retired') AND algorithm='aes_256_gcm') IS NOT TRUE)
~~~

Only that complete substring becomes:

~~~sql
EXISTS(SELECT 1 FROM core.vault_key_versions WHERE (generation>0 AND state IN ('pending','active','retired') AND algorithm IN ('aes_256_gcm','aes-256-gcm')) IS NOT TRUE)
~~~

The migration obtains pg_get_functiondef for the exact regprocedure, requires
exactly one old occurrence and zero new occurrences, then executes its single
replacement. Absent, duplicated or already-altered input fails closed and rolls
back. CREATE OR REPLACE preserves OID, owner and ACL. The copied definition
retains invoker security, pinned search_path, volatility and every unrelated
guard. No DROP, data UPDATE, new function, new grant or schema/wire change.
The migration is forward-only; down raises Ecto.MigrationError.

## Bounded file scope and ownership

Add three source/test paths to the prior additive SourceGO only after this
design and plan receive actual SPEC then NEW distinct fresh QUALITY:

- Create apps/singularity_storage/priv/repo/migrations/20261016000100_knowledge_restore_algorithm_metadata.exs.
- Modify apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs
  additively, preserving all 23 old tests and their assertions. Baseline1693 lines,
  SHA256 ac7bfa0fd9e310225517bb85e19efcab18cf255c78718a4d2d96778b7cf1fa70.
- Create apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_algorithm_migration_test.exs.

Existing Task6 fixture/owner regions may remove the temporary probe exactly back
to the archived diag2 files, preserving both Task5 inverse comparisons. The new
oracle, synthetic fixture, existing preflight repair/tests, old formal documents,
all released migrations, frozen56, prerequisite26, controls49 and common25 remain
unchanged. New documents are uncommitted until the Task13 combined local-commit
boundary; old seals and historical receipts are never rewritten.

This is a necessary knowledge-restore compatibility repair for opaque legacy
owner metadata, not Vault feature work. Vault/bootstrap, crypto, custody, keys,
passwords, capabilities/policies, DownloadLease, runtime roles, defaults, V1/V2
wire behavior, immutable provenance and production data remain frozen. No merge,
push, version, tag, release, deployment, activation or backfill. E2E NOT RUN.

## Verification and progression

First add two independently named structural full-import positives, one per
established literal, using the existing disposable fixture's actual source row,
authenticated V3 import, 38 exact destination digests, five ciphertext objects,
all six seals and a read-only imported retry. Only the test-owned source metadata
varies; do not normalize the actual native bootstrap.

Add one direct owned-graph negative contract covering all six malformed owner
spellings and the three adjacent-table hyphen denials. Import a valid baseline,
mutate only disposable algorithm metadata inside an independently rolled-back
transaction for each vector, call the actual owned function and require23514.
Verify the complete destination snapshot and original bytes remain unchanged.
Existing independently named preflight denials remain mandatory.

Run the COMPLETE LogicalV3Import owner before production changes. Expected:
26 executed, only the new hyphen positive fails, all25 others pass. Any other
failure enters diagnosis; compilation, missing-module or migration-absence
failures are not causal RED.

Then a default Sol implementer creates the exact migration and its dedicated
upgrade contracts, and removes tracing. Tests use MigrationTestEnvironment at
the real preceding ceiling20261011000800, not a fake catalog or edited released
migration. Verify exact before/after function catalog, OID/ACL/owner/security
attributes, the single body replacement, prior storage_ref acceptance,
runtime-role denials, already-migrated no-op and forward-only down. Independently
test absent/duplicated predicates: the migration must fail without changing the
catalog or recording its version. Fresh-current migration is also exercised by
every full import/native fixture.

Require full migration/admission/preflight/import GREEN and the complete
four-file Runtime/search/restore gate GREEN without tracing. Then obtain actual
combined-source SPEC followed by NEW distinct fresh QUALITY before Task6
acceptance and Task7. Further downstream failures remain failures and are
diagnosed under continuing authority.

Root exclusively owns Native, formatting, maintenance SQL, receipts and Git.
All other actors/commands are CLOSED before every LIVE interval. Root only
polls that exact session with empty input and sends commentary until natural
closure; then ordinary private-PG residual must be EMPTY and source guards pass.
No inspection, signals, timeout, concurrency relaxation or unsafe historical raw.

Sol code-repair rounds for this new owned-SQL defect start at0. The earlier Astra
candidate has focused78/0 PASS but full Task6 FAIL, not complete success.
Escalate after two failed Sol code-repair rounds or evidenced technical impasse;
permit at least three bounded evidence-driven Astra attempts if needed.
Diagnostic/design attempts are not code-repair rounds.
Task16 strict BOTH/ALL leases remains UNSATISFIED/UNWAIVED/BLOCKED_DESIGN.
