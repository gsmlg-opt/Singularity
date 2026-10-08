# Document Runtime source/claim integration verification

Started: 2026-10-08; continued on 2026-10-09. Status: bounded Runtime B implemented,
113 integration and 80 unit/architecture contracts passed; independent spec and
quality reviews passed. Source committed at `5be1e51` and exact-commit gates passed.
Mandatory C, Task 12, Phase 2 and full release acceptance remain open.

## Authority and source

This is mandatory B under Task 12 of the approved Phase 2 design/plan, worker
bridge amendment and fresh-source replay amendment. It does not replace C or
accept Task 12, Phase 2 or the release.

Worktree:
`/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`;
branch `codex/v0.2-phase-2-import-extraction`. Preparation started clean at
`e39bba9f93d183e76a1eee56d5734d5dbdebce71`, the evidence commit for Runtime A.
Its production source is `d5ea128f3423e54df2381d78b941cafff291a62a`.
A passed independent spec/quality review and 80 scoped unit/architecture tests
on that exact source, plus formatting and zero xref cycles. Seventeen excluded
Asset/application integration tests were not claimed as passing. The full
release goal remains active; the current goal turn made reviewed, committed,
exact-source-tested progress rather than merely waiting.

## Preparation ownership and boundary

`document_runtime_b_plan` owns only the new complete-code plan
`docs/superpowers/plans/2026-10-08-singularity-v0.2-document-extraction-runtime-source-integration.md`
at this checkpoint. Parent owns this verification document. No B test or
production edit is authorized before main reads the complete executable plan
and gives GO. Future B tests belong in the same Document extraction test file,
preserving the existing A unit module and assertions.

B must compose real WorkerRepo authority, retained events/submissions,
KeyCustodian/DownloadLease, encrypted storage, Core and actual extractors. It
must prove source pin authentication, empty originals, pending deferral and v4
checkpoint preservation, actual worker death before/after claim, restart from
zero, unchanged same-attempt DB deadline, Asset deletion retention, Document
deletion before claim, and actual authority fences. Wrappers may observe/barrier
actual calls but may not replace authorization, source authentication or typed
repository results with successful fakes. No RequestRepo substitution,
temporary grants, partial canonical models or production test hooks.

C remains separately required for real outcomes, post-claim deletion,
recovery/retry/restore staleness, exhaustion/retry/snooze, atomicity and privacy.
Existing source behavior already implemented by A may be characterized by new
passing integration tests; do not manufacture RED by weakening/removing
production. Any actual missing behavior requires a focused failing regression
and parent approval before a surgical production repair.

## Established integration baseline

Worker executed this scoped baseline before B test changes:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs --seed 1208
```

Reported exit 0: storage 73 executed, 0 failures; Runtime 14 reported,
5 non-integration exclusions, 9 executed, 0 failures. Total 82 integration
tests executed. This is established prerequisite evidence, not the new full
worker source/claim contract.

The alias allocated:

- database `singularity_test_b428cc96a1bf603ede076c12`
- storage root `/tmp/singularity/integration/b428cc96a1bf603ede076c12`

Worker independently checked `pg_database` count 0 and root absence afterward.
Main then independently ran:

```bash
devenv shell -- psql -U singularity_migration -d postgres -At -c "SELECT count(*) FROM pg_database WHERE datname = 'singularity_test_b428cc96a1bf603ede076c12'"
test ! -e /tmp/singularity/integration/b428cc96a1bf603ede076c12
```

Both exited 0; the database query returned 0. All baseline/cleanup commands
finished and the shared Mix slot was released. Borrowed PostgreSQL/devenv
services remain running and must never be restarted/stopped by this task.

## Verification and stop conditions

### First implemented checkpoint: B1/B2

Worker appended the approved support and ready/replay blocks: 594 lines added,
zero removed. The original A prefix remains byte-identical. Scoped integration
seed 1208 exited 0: 50 reported, 43 A unit exclusions, 7 integration executed,
0 failures. Syntax and whitespace checks passed; production remains unchanged.

Exact allocated database `singularity_test_1138b27770371676db4fe112` and root
`/tmp/singularity/integration/1138b27770371676db4fe112` were independently checked
absent by the worker. Main independently confirmed database count 0 and root
absence afterward, both checks exit 0. No broader B/C acceptance is implied.

### B3 unexpected fixture failure: retained, diagnosis in progress

The first B3 invocation reported a setup failure for the proposed short-length
pin. PostgreSQL raised SQLSTATE 23514, constraint
`document_versions_source_check`, in `KnowledgeFixtures.insert_document!/2`,
before `Extract.run/2`. Released migration
`20260906000100_create_document_aggregate.exs` installs an INSERT guard requiring
the source object's `plaintext_byte_size` to equal the new Document pin.
Therefore that proposed fixture cannot reach the worker's descriptor guard.

The worker stopped changes and is finishing the owned command/cleanup before
handoff. Main independently traced the constraint; production and required
assertions remain unchanged. A constraint-valid replacement arrangement needs
explicit parent review before fixture edits. No trigger/grant bypass or released
migration change is authorized. This is a new test-harness setup defect, not a
production repair attempt.

The invocation finished exit 2: 65 reported, 43 excluded, 22 selected, 21
passed and one setup failure. Exact database
`singularity_test_327491e87549efc405366784` and root
`/tmp/singularity/integration/327491e87549efc405366784` were independently
confirmed absent by both worker and main; database count 0, checks exit 0.

Main then read the existing storage repository test at lines 1124–1139, which
creates a valid Document before an administrator changes object size and
asserts a descriptor conflict. Main reviewed and authorized the complete-code
test-only correction following that precedent: normal matching fixture, then
object `plaintext_byte_size+1` with affected-row count 1. No Document pin,
trigger, migration or grant is changed. The original conflict/no lease/no claim/
no extractor/pending-generation-zero assertions remain unchanged. Physical
ciphertext truncation remains a separate retained contract. Rerun is pending;
no success is yet claimed for this correction. The Mix slot is reassigned to
the worker for that rerun and remaining B stages if green.

The authorized B3 correction passed: same scoped command and seed 1208, exit 0,
65 reported, 43 excluded, 22 executed, 0 failures. One successful B fixture
harness correction is recorded separately from the prior successful A accessor
correction. Production repair failures remain 0; Astra attempts remain 0.
Exact database `singularity_test_e3042464b5568eedec04d45a` and root
`/tmp/singularity/integration/e3042464b5568eedec04d45a` were independently
confirmed absent by worker and main; database count 0, checks exit 0. B4 is now
running; no result for that stage was claimed at that checkpoint.

B4 subsequently passed the cumulative scoped command, seed 1208, exit 0:
68 reported, 43 excluded, 25 executed, 0 failures. Actual owned Oban unlock/wake,
v4 preservation and both real progress SQL rollback cases passed. Database
`singularity_test_ecf8750e954407d188a7be41` and root
`/tmp/singularity/integration/ecf8750e954407d188a7be41` were independently
confirmed absent by worker and main; database count 0, checks exit 0. B5 is
running; production remains unchanged.

B5 passed the cumulative scoped command, seed 1208, exit 0: 72 reported,
43 excluded, 29 executed, 0 failures. Monitored partial-read, complete-read and
claimed worker death/restart passed, including reader/lease cleanup, full-source
digest, preserved v4 and exact original database attempt timestamps/identity.
Database `singularity_test_aa8ba5b50835ffdde64f9834` and root
`/tmp/singularity/integration/aa8ba5b50835ffdde64f9834` were independently
confirmed absent by worker and main; database count 0, checks exit 0. B6 is
running; no production changes occurred.

B6 passed the cumulative scoped command, seed 1208, exit 0: 74 reported,
43 excluded, 31 executed, 0 failures. Source Asset tombstone retained identical
ciphertext and completed ready; Document deletion at the actual first-claim
barrier denied claim with no extractor/fragments. Database
`singularity_test_7ee5c4305e692d96995725d3` and root
`/tmp/singularity/integration/7ee5c4305e692d96995725d3` were independently
confirmed absent by worker and main; database count 0, checks exit 0. B7 combined
gates/reviews remain outstanding; these stage results do not accept B/Task 12.

B7 repeated the full B file successfully: 31 executed, 43 exclusions, 0 failures,
seed 1208. Database `singularity_test_1f8a6062a760fb6d469e44e1` and root
`/tmp/singularity/integration/1f8a6062a760fb6d469e44e1` were independently
confirmed absent by worker and main (database count 0, checks exit 0).

The first combined B/custody/worker-repository run also passed, seed 1208:
storage 73 executed, Runtime 88 reported/48 excluded/40 executed; total 113
executed, 0 failures, exit 0. Exact database
`singularity_test_b3af91411ad79cc11ce8d8b2` and root
`/tmp/singularity/integration/b3af91411ad79cc11ce8d8b2` were independently
confirmed absent by worker and main (database count 0, checks exit 0).

The final block-concatenation diagnostic found Progress placed after Restart
and Tombstone rather than before them. Each complete block remained individually
byte-identical; the A prefix remained unchanged. Main inspected module order and
authorized an intact mechanical reorder to match the plan, followed by format
and a fresh combined run on final source. No test assertion or production repair
is involved. Final gates and independent reviews remain open.

The reordered/formatted final source passed the combined integration command,
seed 1208, exit 0: storage 73 executed; Runtime 88 reported/48 excluded/40
executed; total 113 executed, 0 failures. Exact database
`singularity_test_d99048bb21d9d9fb724dc284` and root
`/tmp/singularity/integration/d99048bb21d9d9fb724dc284` were independently
confirmed absent by worker and main (database count 0, checks exit 0).

Worker's final unit/architecture command passed, seed 1208, exit 0: Runtime
113 reported/48 excluded/65 executed and architecture 15 executed; total 80
executed, 0 failures. Formatting/check passed, xref exit 0 (`No cycles found`).
The formatted append is 1,456 lines, zero deletions. Main independently proved
the file equals the exact baseline bytes plus all six ordered plan blocks.
Test SHA-256: `373ad3d5fcfdd07ae522f00a037caa6efabbfba5f060c6c9685fb7d71da14178`.
Parent fresh gates and independent spec/quality reviews remain outstanding.

## Parent final-source verification

After the worker explicitly released the Mix slot, main independently ran:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs --seed 1208
```

Exit 0: storage 73 executed, 0 failures; Runtime 88 reported/48 excluded/40
executed, 0 failures; total 113 executed. Exact allocated database
`singularity_test_519dc975beaed23f080133ec` and root
`/tmp/singularity/integration/519dc975beaed23f080133ec` were independently
checked afterward: database count 0 and root absent, both checks exit 0.
Main also independently proved exact A-prefix/ordered-six-plan-block byte
equality and the test SHA-256 recorded above. Root main remains clean at
`e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`.

Main also independently ran:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
```

Both exited 0: Runtime 113 reported/48 excluded/65 executed, architecture
15 executed; total 80 executed, 0 failures. The 31 new B tests execute through
the integration alias, not this ordinary unit command. No database/root was
allocated by the ordinary unit or formatting commands. Main independently ran
`MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0`:
exit 0, `No cycles found`. Main whitespace/scope/hash checks also passed.
All main-owned commands finished and the Mix slot is free. Fresh independent
`document_runtime_b_spec` returned **SPEC_COMPLIANT**, with no missing, extra or
incorrect B requirements and no plan flaw. It independently checked actual
production/dependency APIs, byte identity, source hash and scope; its whitespace
check passed. It ran no Mix commands and changed no files, services, databases
or external state. All reviewer commands finished. Fresh read-only independent
quality review followed that result. `document_runtime_b_quality` returned
**QUALITY_APPROVED**, no critical, important or minor findings and no B plan
flaws. It independently checked actual code/dependencies, assertions, owned
process cleanup, source/plan identity, scope and whitespace. No files, services,
databases or external state changed; no Mix commands ran. All reviewer commands
finished. It approved only a bounded local B commit, not Task 12/Phase 2/merge.

## Local source commit and exact-commit recheck

After both independent reviews passed, main committed exactly the test append
and its complete-code plan as `5be1e515ef9315933aed4bd7c65dc2b6abc4ed23`
(`test(runtime): qualify document source acquisition and restart`). The commit
has two paths, 3,247 additions and no deletions: 1,456 test lines plus 1,791 plan
lines. This verification document was the only untracked path afterward.
Production source remains `d5ea128f3423e54df2381d78b941cafff291a62a`.

Main reran the same combined integration command on that exact committed source,
seed 1208: storage 73 executed, Runtime 88 reported/48 excluded/40 executed;
total 113 executed, 0 failures, exit 0. Exact database
`singularity_test_dda6b9ffca0c3d4a20f4b5c9` and root
`/tmp/singularity/integration/dda6b9ffca0c3d4a20f4b5c9` were checked afterward:
database count 0 and root absent, both checks exit 0.

Main also reran the same unit/architecture command on that exact commit:
Runtime 113 reported/48 excluded/65 executed, architecture 15 executed;
total 80 executed, 0 failures, exit 0. Scoped format check and xref both exited
0; xref reported `No cycles found`. All main-owned commands finished; the shared
Mix slot is explicitly released. Test source hash and historical prefix remain
unchanged. No E2E, Vault compatibility patch, production repair, merge, push,
tag, release, image publication or deployment occurred. Root main is unchanged.

## Remaining work and goal audit

This goal turn made concrete progress: Runtime A was implemented, independently
reviewed, committed and tested on its exact source; bounded B now has 31 real
integration contracts, independent spec/quality approval and exact-commit
verification. This is not a wait-only or repeated-blocker turn. The full release
goal remains active, not complete or blocked.

Mandatory C remains open for actual outcomes/caps, post-claim source loss,
tombstones, recovery/retry/restore staleness, atomicity, terminal exhaustion,
retry/snooze and privacy. A fresh Sol worker has begun a separate complete-code
C plan under the standing approval, with plan-only ownership and no test or
production GO. Its preparation can rely on the freshly verified B baseline.

Only A+B+C and required Asset regressions can establish Task 12. Full Phase 2
still requires its complete README/checklist gate. The full release definition
of done additionally requires later search, tags/relationships, Note attachments
and citations, projection restore, portable export, backup V3 and V1/V2 restore,
0.1 upgrade, browser workflow and exact-source multi-architecture artifacts.
Those are unproven; no phase or release completion is claimed. E2E remains
prohibited and unrun; it is not silently waived as an acceptance requirement.

Final cumulative counters: failed Sol production repair rounds 0; Astra attempts
0 (maximum 3 if escalation is required). Successful test-harness corrections:
A accessor 1, B source-size fixture 1. No failed production repair is hidden or
counter reset by moving to C.

Main personally read all 1,209 lines of the final complete-code B plan, including
all six code blocks and mandatory B/C ledgers. The plan proposes 31 contracts
(7 ready/replay, 15 authentication/authority, 3 progress, 4 restart, 2 tombstone).
Its in-memory compile is preparation evidence only, not executed tests.

Plan corrections included the actual Core fragment identity, constraint-valid
cross-owner/alternate-member fixtures, SQL rejection of an object/pin length
mismatch, truncation inside an expected data record rather than final-only
truncation, and a delete race paused after progress immediately before claim.
Complete-read death observes actual lease termination; it does not kill the
lease to manufacture cleanup success. Existing A test bytes stay frozen.

Main gives B TEST GO for the plan's scoped test-only append and serial focused
verification. The shared Mix slot is assigned to the B worker until released.
No production GO is given. An unexpected contract failure must be retained and
reported before a production edit. No B tests, source edits, independent review
approval or integration acceptance are yet claimed.

No E2E, external publication, push, merge,
tag, release, deployment, schema/migration, Vault feature/compatibility patch,
key/capability semantics, generic retry/wake, public repository, backup, search
or browser change is authorized here.

One prior successful A test-harness accessor correction remains recorded.
Failed Sol production repair rounds: 0. Astra attempts: 0. Two failed Sol
production repair rounds or a clear technical impasse require parent-managed
Astra escalation, with no more than three Astra attempts. No failure is hidden
or counter reset by moving from A to B.
