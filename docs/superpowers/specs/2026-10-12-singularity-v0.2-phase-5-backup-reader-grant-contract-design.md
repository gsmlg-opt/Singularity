# Phase 5 Retained Backup-Reader Grant Contract Amendment

Status: actual independent nonauthor SOURCE SPEC and distinct fresh QUALITY
PASS on complete candidate design d19067aa/plan d68e4320. Complete retained
SQL50680 is still running with all source/test/support frozen; emitted failures
are not a final gate verdict. Implementation still waits for normal closure.
The ACL amendment does not explain newly emitted timeout/lifecycle failures.

## Goal and bounded ownership

Synchronize two retained security-test contracts with already accepted Task8
worker backup SELECT authority. Strengthen genuine baseline RLS read witnesses;
preserve every mutation denial, private-function denial and cleanup assertion.
Do not change production permissions to satisfy obsolete denial expectations.

Implementation scope ONLY:

- `apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs`;
- `apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs`.

Parent owns design/plan/master/report and the two test edits, formatter, gates
and local Git. Task13's separate Sol author owns only its NEW Repository test.
No production/support/helper/config/credential/policy/role/grant or migration
change. No Vault/custody/key/capability/lease/crypto semantics change.
E2E NOT RUN/manual-only; no publication or production activation/data.

## Characterized source and causal RED

Accepted00500 SHA
`f2abeb240665c727725d0ca055bb829a182dfb0e3bf64d87ed77cef7d65a4154`
grants worker SELECT on exactly seven knowledge tables. Receipt direct SELECT
is still absent; its fixed authorized SECURITY DEFINER backup helper is a
separate accepted contract. Source-set seals remain web-only.
Accepted00600 SHA
`1d5522fe1a505b53a99c48d0c246a5cc59ab381a6be6ce1d3041f1163fe796ea`
adds only fixed guard execution, not table grants or policies.

Unchanged KnowledgeTestGrants SHA
`f29d304e1b7e1b1c66364c880a1207af2954456212b97abd8abe5d0a4f8c55da`
snapshots effective permissions and revokes only initially-false entries
(lines120–146). It correctly preserves durable worker SELECT. Rls79 and
Grants36/48 fail their INITIAL baseline checks before temporary helpers run;
these three cannot establish a cleanup leak. The other three emitted failures
also expect obsolete worker SELECT denial after correct preservation.

Original Rls test SHA
`07d87d69f639d66a5a89c34353b313e4964c881231659a2faa0c92a8cef78f80`;
original Grants test SHA
`efd6cfb9022739fa8a4157315c77f5052a03cea38d48e970fa632fed58df09d6`.
Read-only Sol diagnosis covered both files through EOF, real grant/owner helpers,
accepted00500/00600, governing Task8 clauses and earlier grant/RLS migrations.
No diagnostic SQL, test edits or gate qualification was claimed.

## Exact literal expected matrix

| Tables | Web | Worker |
| --- | --- | --- |
| document_versions, document_fragments | SELECT | SELECT |
| note_attachments, note_citations, tags | INSERT, SELECT | SELECT |
| resource_tags, relationships | DELETE, INSERT, SELECT | SELECT |
| note_source_set_seals | SELECT | None |
| document_import_receipts | None | None |

Dispatcher/pre_auth have NONE on every listed table. All unlisted privileges
remain false, including UPDATE/TRUNCATE/REFERENCES/TRIGGER everywhere and all
worker mutation privileges. Every nonowner ACL entry is exact/non-grantable;
no PUBLIC or unexpected role entry. Expectations are literal approved constants,
not inferred from observed database privileges.

## Selected test-only correction

Preserve all original two Rls and thirteen Grants cases, fixtures, assertions,
exceptions/throw cleanup, complete selections and default timeouts. Rename only
misleading web-only/baseline titles where the accepted contract now includes
worker reads. Do not skip/delete/reclassify a required behavior.

In Rls rollback case, distinguish tags SELECT=true for both runtime repos from
INSERT=true only for web. UPDATE/DELETE/TRUNCATE remain false. Both before and
after temporary helper checks remain. Post-rollback worker scoped SELECT must
return empty, not a permission exception; preserve actual same-connection
backend/GUC/rollback and every DML denial.

In Grants cleanup cases and baseline helper, expected Document/fragment SELECT
is true for web and worker, false for dispatcher/pre_auth; all tested DML remains
false. Receipt privileges stay false. Worker missing-scope baseline reads must
return empty; dispatcher/pre_auth still raise native42501.

Canonical matrix checks retain FORCE RLS, all four roles and all seven native
table privileges. Exact ACL adds ONLY one nongrantable worker SELECT row on
each of the seven approved tables, none on receipts/seals. Order expected and
queried ACL rows deterministically by role name/privilege, not role-creation OID.
Missing-scope SELECT returns empty for each legitimately readable repo/table;
all unreadable combinations still require native42501. Existing DELETE/INSERT/
UPDATE behavior checks stay exact, including provenance-guard23514 exceptions.

Strengthen genuine baseline reads WITHOUT temporary grants: extend existing
Document/fragment baseline RLS case to both web and worker, retaining exact
matching rows, foreign-version exclusion, mismatched owner, and revoked membership.
Add worker organization-table missing-scope/matching/foreign-principal/foreign-
owner checks BEFORE the existing temporary-grant block, and revoked-membership
empty reads AFTER its normal cleanup. Existing organization insert/isolation
checks inside that block remain unchanged. This proves all seven durable worker
read grants still filter by authenticated active matching owner.

Do not broaden worker source-set-seal or receipt direct reads, grant private
lifecycle/trigger/native helper execution, or modify any helper cleanup behavior.

## Verification and advancement

Keep live50680 source frozen through normal closure, archive full output/actual
count/exclusions/exit and all six or additional failures, match original selected
sixteen-file/Task13/frozen56 receipts and verify normal DB/root cleanup.
This complete failed gate remains FAIL even after later repairs.

After design SOURCE SPEC and distinct fresh QUALITY PASS AND gate closure,
parent may author only these two tests while disjoint Sol authors reviewed
Task13 Repository test. Close ALL source authoring before any formatter/Mix/SQL.
Run complete two retained security files with warnings-as-errors/default timeout,
then the UNCHANGED complete sixteen-file retained SQL selection. Require exact
matrix, native row filtering, no mutations, no new failures, normal cleanup and
zero warnings. No focused PASS substitutes for the complete retained gate.

Record new exact source receipt, full output archives, protected helper and
accepted00500/00600 hashes, frozen56, format/compile/xref/diff checks. Obtain
actual final nonauthor SOURCE SPEC followed by distinct fresh QUALITY on these
test edits before bounded local commit. Task9C remains NO GO until complete16
GREEN; Task13 has separate full114pure/43SQL/static/final-review requirements.
A source-author or permission probe cannot accept either task.

Ordinary failures enter bounded Sol diagnosis/repair with preserved full failed
evidence; escalate only under established Astra conditions. Routine human
approve is superseded by continuing authority, not security/product boundaries.
