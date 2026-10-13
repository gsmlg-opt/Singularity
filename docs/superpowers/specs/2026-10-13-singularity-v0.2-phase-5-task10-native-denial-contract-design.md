# Phase 5 Task10: native denial contract synchronization

Status: DESIGN REVIEWED. Actual independent DESIGN SPEC then NEW distinct fresh
DESIGN QUALITY CLOSED PASS/noP1P2 on reviewed designf628637e/planf03c4f0d.
These status-only lines follow the archived exact reviewed documents. Parent
permits bounded Sol test repair attempt2 only after the design-only local commit;
implementation/native GREEN and source acceptance remain pending.

## Evidence, authority and scope

Continuous AGENTS authorization permits necessary compatibility/test-contract
synchronization with design, plan, verification and independent review. It does
not permit weaker assertions, hidden failures, frozen semantics or publication.

First combined compatibility repair naturally CLOSED whole H3 session76572:
148 tests, 3 failures, 827.6s, exit2, zero warnings/invalid. 145 actual passing
cases are NOT whole GREEN. Full native archive SHA256
4e9c86a969f06db4c35ddf92e88fb99bb4cd13f23027ca5c94c849d1d1ca1306.
Normal maintenance EMPTY/exit0; exact root e0489820364e44056202cc88 absent/exit0;
full cleanup ec83d6a8c8d609b2cccfb56a25b9795ead97ce95da7cc5828700ffaac5586583.
Exact eight-source manifest3c68cadd/frozen56/protected3 remain unchanged.
All parent native commands are CLOSED. Combined failed Sol1/Astra0; historical
B/C preparation Sol2/Astra1 remains separate.

Actual independent SOURCE SPEC CLOSED FAIL/P2x2, with source-backed independent
read-only diagnosis agreeing. These are test-contract inconsistencies newly
reached after prior classification/OID repairs, not production defects:

- Doc661/677 expects zero saga rows after authenticated provenance denial.
  Restorer1635-1678 intentionally commits pending intent before the canonical
  transaction563-611, then cleanup710-722 retains that exact pending intent.
  Master Phase5 design796-802 and accepted Task7/native import owners require
  it. Both missing-event/submission cases now reach this inconsistent check.
- Doc2184 calls has_any_column_privilege with DELETE, which native PostgreSQL
  rejects22023. Table DELETE/TRUNCATE are supported and still must be denied.
  Existing actual DML helper2257 already asserts all four operations42501 and
  unchanged canonical snapshots under owned transaction rollback.

Only apps/singularity_storage/test/singularity/storage/backup/
document_restore_reconciliation_test.exs may change, plus these governing
documents and Task10/acceptance bookkeeping. Root owns documents/native/Git;
disjoint Sol owns only the test. Entry test SHA256
6799d0c43ec3af7abe00b23fa55f0f6297a696da2d071ea06ed38efe8e2f31d6.
Every production file, other test, shared fixture, released/new migration,
frozen/protected baseline, Vault/custody/lease/wire/defaultV2 stays unchanged.

## Recommended bounded repair and rejected alternatives

Synchronize the test with the established durable-pending contract and native
privilege vocabulary. Do not delete pending markers, move preflight ahead of
marker preparation, change Restorer/admission, grant permissions, suppress
errors, accept any marker, or remove real runtime DML denials. Those conflict
with preserved retry identity, durability or security.

This amendment supersedes ONLY the two post-denial zero-marker expectations
and invalid column-DELETE probe in earlier Task10/compatibility wording that
otherwise retained literal assertions. The initial zero-marker requirement
and every required no-canonical/no-publication/privilege denial remain and are
strengthened, not waived. A pending intent is not an imported COMMIT.

## Exact pending denial contract

Keep assert_empty_receiver!/0 and all initial calls byte-identical. In the two
generated absent-provenance tests only, replace the post-error use with a
dedicated strict post-denial helper and controlled retries:

1. Count every canonical V3 table using an independently declared fixed
   38-table literal (from accepted Task7 contract, never manifest/schema/helper
   selected), plus note_source_set_seals and knowledge_restore_admissions.
   Every unfiltered table count is0 under existing owner context.
2. Preserve accepted excluded-table emptiness: sessions/auth_attempts, asset
   stages/upload grants, legacy/unified search projections, note mutation
   receipts, backup metadata, Oban jobs/peers; the established optional knowledge
   mutation receipt relation is absent or, if present, empty.
3. SELECT the complete native saga row, requiring exactly ONE row. Independently
   verify singleton=true; manifest_id/vault_id from authenticated binding,
   manifest_hash/tag from genuine verified input, inventory_hash as SHA256 of
   deterministic ETF of ORIGINAL verified.cut.object_inventory,
   destination_root_hash as SHA256 of Path.expand(destination.object_root),
   object_count as original inventory length; state exactly pending.
4. Require imported_at, rewrapped_at, reconciled_at, verified_at, completed_at,
   integrity_principal_id and wrapper_generation all NULL. Require genuine
   inserted/updated timestamps and retain the complete row for exact equality.
   Do not derive expectations via Restorer/private production marker builders.
5. Actual LocalFilesystemAdapter.list_staged returns {:ok, []}, recursive regular
   published files are absent (including hidden paths), and MigrationRepo is
   outside a transaction. No cleanup/manual deletion to manufacture the result.
6. Fresh authentication of the SAME invalid variant repeats exact sanitized
   integrity_failure/details empty, and complete saga row including timestamps,
   every canonical/excluded table, stage and published-file state is unchanged.
   Fresh Replay is necessary because streaming import discards it; retain
   proper discard cleanup for each independently authenticated invocation.
7. Fresh authentication of the existing canonical bundle proves a DIFFERENT
   authenticated manifest_hash, then returns exact conflict/details empty and
   preserves the same full snapshot. Do not alter the bundle/binding or repair
   the deliberate missing provenance. No distributed rollback claim.

## Exact native privilege contract

Only change the invalid guard from operation!=TRUNCATE to operation in
INSERT/UPDATE. Keep the original table INSERT/UPDATE/DELETE/TRUNCATE false
assertions for both runtime repositories and both Document tables. Keep all
supported column INSERT/UPDATE false assertions, positive exact function OIDs,
full role/Public matrix, scanner limit/UUID-only shape and every actual runtime
DML42501/rollback/canonical snapshot assertion byte-identical. Accepted A1
bounded read assertions remain protected. No privilege/grant/production change.

## Qualification and handoff

Preserve whole148/3FAIL as causal evidence, both actual P2 findings and source
entry/diff hashes. Close the test author before parent format/compile/native/Git.
Parent formats only owned test, compiles warnings-as-errors, then reruns the
exact complete unfiltered H3. Focused checks may diagnose but cannot substitute.
Retain all TaskH Runtime/Base/Task9/Task8/static/remaining permitted README gates,
normal maintenance EMPTY/exact roots and unchanged seven production/other-test
hashes/frozen56/protected3. Prior complete Preflight GREEN44/0 is exact-source
retained evidence; Task9 SQL again runs its complete owner, not a filtered subset.
E2E NOT RUN/manual-only/deferred. Actual corrected SOURCE SPEC then NEW distinct
fresh SOURCE QUALITY remain required before bounded local Task10 commit.
Second failed Sol repair round or evidenced impasse triggers actual Astra,
allowing at least three bounded attempts if needed. Never redefine failures
as PASS or weaken a required assertion. Phase5 NOT ACCEPTED/Task16 unwaived;
no merge/push/version/tag/release/deploy/production activation/data.
