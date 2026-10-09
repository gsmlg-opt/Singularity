# Phase 2 Task 15 qualification matrix

## Status and scope

Task 15 is open. This record is not Phase 2 acceptance, a complete README
verification gate, or publication evidence. Source baseline is
`52d9df11bd943ab7808896be3d0c49e9c7c7808a` on
`codex/v0.2-phase-2-import-extraction` in the existing project-local worktree.
E2E remains NOT RUN under the user's explicit exclusion; the required full
Phase 2 gate cannot be marked accepted without it.

No production activation, Vault feature change, new migration, backup V3,
search projection, Note Save, merge, push, release, or deployment is included.

## Read-only Astra audit

Two independent Astra source audits reviewed the extractor/Core and
Runtime/storage security matrices. Their findings identify source assertions,
not new passing test evidence. Existing tests cover cross-owner/RLS rejection,
forged source proofs, receipt replay and SQL races, cleanup collisions,
stale completion, native timeout/cancellation, custody lock/revocation,
retained-source reads, and content-free diagnostic/persistence channels.

Audited qualification slices, in recommended order:

1. **Locally qualified below:** real public import through `Api`,
   `Documents.Import`, `OperationScope`,
   authorization, custody, authenticated encrypted storage, and PostgreSQL.
   Existing public API import tests replace those boundaries with doubles;
   existing live original-download fixtures precreate the Document.
2. Extraction recovery catalog/UUID-only scanner and atomic rollback on a
   legally constructed successor-event collision; inspect actual SQL semantics
   before selecting the failure assertion.
3. Backup unsupported-inventory owner scoping and two-connection repeatable-read
   snapshot behavior. Do not bypass constraints to manufacture invalid rows.
4. Positive inclusive extraction limits: 4096 pages, 4096 fragments, and exact
   output boundary alongside existing over-limit refusals. Distinguish native
   raw-output bounds from normalized-text bounds before choosing the contract.
5. Real image-only scanned PDF, blocked stdin/native output-overflow descendant
   cleanup, repeated real PDF-to-fragment digest, and adapter log privacy.

These are evidence gaps, not established production defects. Any real failing
contract requires diagnosis and a bounded reviewed repair before production
edits. Never weaken an existing refusal, alter custody semantics, or enable
production canonical writes to make a qualification test pass.

## Live import design review

Parent read the complete live-import design and plan, then a separate Astra
reviewer traced the real adapters, after-commit runner, two authenticated
preparations, isolated grant helpers, deletion path, and denied SafeSQL
telemetry listener control. No Critical or Important finding remained.
Parent issued test-only GO under standing approval, confined to the new
`document_import_live_test.exs`. A valid behavioral failure remains RED pending
bounded diagnosis/repair; no production repair is preauthorized by this plan.
The design, plan, and initial matrix record were locally committed as
`7de5636928efee90948bbd7371f4938e10b388e7`; production source remains unchanged
from `52d9df11bd943ab7808896be3d0c49e9c7c7808a`.

## Unchanged scoped baselines

Commands below ran with
`MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps` in the Phase 2
worktree. Only one Mix process ran at a time. Existing ready PostgreSQL was
borrowed; no service restart or shutdown was performed.

```sh
devenv shell -- mix test \
  apps/singularity_core/test/singularity/core/document_fragmentation_test.exs \
  apps/singularity_core/test/singularity/core/document_values_test.exs \
  apps/singularity_core/test/singularity/core/knowledge_properties_test.exs \
  apps/singularity_ingest/test/singularity/ingest/documents/text_test.exs \
  apps/singularity_ingest/test/singularity/ingest/documents/markdown_test.exs \
  apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs \
  --seed 1208
```

PASS, session `41123`, exit 0. Core: 3 properties and 20 tests, 0 failures
(6.2 seconds). Ingest: 24 tests, 0 failures (10.2 seconds). Total 47 executions,
including 3 properties; no integration database was allocated.

```sh
devenv shell -- mix test \
  apps/singularity_runtime/test/singularity/runtime/document_import_test.exs \
  apps/singularity_domains/test/singularity/domains/documents_test.exs \
  --seed 1208
```

PASS, session `5523`, exit 0. Domain: 5 tests, 0 failures (1.0 second).
Runtime: 7 tests, 0 failures (0.6 seconds). These are unchanged unit contracts,
not proof of the live import composition.

```sh
devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs \
  apps/singularity_storage/test/singularity/storage/documents/prepare_source_test.exs \
  --seed 1208
```

PASS, session `85402`, exit 0. Storage: 29 tests, 0 failures (8.1 seconds).
Observed database `singularity_test_13a7b071740c23f89160d1c1` was independently
absent after exit (`pg_database` count 0), and the exact storage directory
`/tmp/singularity/integration/13a7b071740c23f89160d1c1` was absent.

```sh
devenv shell -- mix compile --warnings-as-errors
```

PASS, session `89952`, exit 0 against unchanged production source. This is a
compile baseline, not verification of the new qualification tests.

## First live public import characterization

Parent read the entire new 548-line test file before execution. Initial test
SHA-256: `ec3877efa8813f58f8add78711375d65445c4b4eb9682c3ad980b63717492278`.
No existing source or test file changed.

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_import_live_test.exs \
  --seed 41123 --trace
```

PASS, session `89787`, exit 0: 1 test, 0 failures (2.4 seconds). The real
API/OperationScope/authorization/custody/PrepareSource/reader/repository path
authenticated nonempty encrypted bytes, persisted the exact immutable source
digest and IDs, produced one pending Document/receipt/IDs-only extraction
event, preserved preexisting Asset search state, created no fragment or job,
restored temporary grants, and left a fresh request checkout unscoped.
This is characterization of existing behavior, not a manufactured TDD RED.

Observed database `singularity_test_d3b56571ae31789797038278` was independently
absent after exit (`pg_database` count 0); exact integration storage directory
`/tmp/singularity/integration/d3b56571ae31789797038278` was absent.
ExUnit's separate fixture directory retained the owned ciphertext after this
initial run. The next test-only edit must register explicit exact-root cleanup,
as the established original-download fixture does. Existing unrelated ignored
temporary artifacts must not be removed.

Parent issued test-only GO for replay/refusal and real-deletion contracts;
privacy capture and final review remain pending. Production repair rounds: 0.

## Replay, refusal, and actual deletion characterization

Parent read the complete 823-line revision, SHA-256
`053b58125d1ebb7534e5996d9c5222018f2f9309f85a46d9606ed40455bef931`.
The same new-file integration command with seed `41123` ran as session
`44875`, exit 0: 7 tests, 0 failures (47.3 seconds). Exact and changed replay,
independently valid cross-owner authority, locked real custody, revoked live
session, corrupt ciphertext, and replay after real Asset deletion all passed.
The deletion test verifies persisted tombstone/released association, unchanged
Document pin/object/ciphertext, and no additional download audit or import event.

This run was not environmentally pristine: before ExUnit started, two
Postgrex connection checkout timeouts (15,000 ms) occurred during database
creation. Read-only observation showed an active `postgres` database backend
waiting on `IO/VersionFileSync`, without test-database connections yet.
Read-only Astra diagnosis traced that stage to `TestEnvironment.create!/1`
before migrations/application startup/ExUnit. The same process progressed and
completed without intervention. Filesystem capacity was available; the
underlying storage-latency cause remains unproven. No timeout change, retry
run, database restart, or production repair was applied. Final repeat remains
required; this delay is not a failing behavioral assertion.

Observed database `singularity_test_19a5ce2abbeb9ef34b59e627` was independently
absent after exit (`pg_database` count 0); exact integration directory
`/tmp/singularity/integration/19a5ce2abbeb9ef34b59e627` was absent. Explicit
exact-root `on_exit` cleanup removed the owned live-test ciphertext files;
the prior known success fixture directory was independently absent.
Borrowed PostgreSQL remained ready with zero restarts.

Parent issued test-only GO for Task 4 actual-call privacy capture. Final
repeat, focused regressions, and independent implementation review remain
pending. Production repair rounds: 0.

## Initial privacy harness diagnostic failure

Parent read the complete privacy revision and formatted only the new file
(session `95391`, exit 0). Formatted SHA-256 was
`8b231969eb3eb992676c94e34a470522d0cbce24785929a6595d290a89e83e82`.
The new-file integration command, seed `41123`, session `69679`, exited 2:
7 tests, 7 failures (6.4 seconds). The listener attached before temporary
grant setup. The pre-import drain captured test-only MigrationRepo raw SQL
and failed a blanket query-event absence assertion before calling the API.
This is not a demonstrated production privacy failure or valid production RED.

Independent Astra SPEC review identified two Important harness findings:
capture lifetime included setup/observation/restoration SQL, and unconditional
query-event rejection exceeded the requirement to scan actual metadata.
`DataCase.query!` invokes raw Ecto SQL without the Repo operation default
options; MigrationRepo fixture traffic therefore emits query events despite
its `default_options/1`. The correction uses exact API-call windows and a
separate post-restoration denial-control window, retaining complete metadata
and all required canary checks. No event/metadata filtering, telemetry config
change, or production patch is authorized.

The reviewer found no missing applicable runtime telemetry subscription:
the live import/download/custody stack does not invoke Observability spans;
Asset verification spans are not on this path. SafeSQL's actual RLS-denial
event remains the real positive listener control.

Observed database `singularity_test_2d9178f8ef2d884c51dcf8d5` was independently
absent after exit (count 0), and exact integration directory
`/tmp/singularity/integration/2d9178f8ef2d884c51dcf8d5` was absent.
Parent issued Astra test-only harness repair GO. Harness diagnostic repair
rounds attempted: 1; production repair rounds: 0. Final qualification and
review remain pending.

## Corrected actual-call privacy qualification

Astra corrected only the new test file; formatting session `74405` exited 0
without changing its SHA-256:
`9f361db0524d89856ea1b9dbbef8610e33253a4b1193c58d816bff89bebcb31c`.
Parent read the corrected capture implementation before running the same
new-file integration command with seed `41123`.

PASS, session `75983`, exit 0: 7 tests, 0 failures (10.2 seconds).
Every actual API-call window reported `query_events=0`; every separate real
denial control also reported zero query events and passed the exact bounded
RLS event/count assertion. No captured log, metadata, error, or complete
owner-filtered audit/outbox/job row contained the plaintext/title or installed
domain/object/dedup/Vault/fingerprint-key canaries in the tested raw, inspected,
hex, or base64 forms. Intentional authorized Document result content is not a
side-channel privacy surface. No worker/dispatcher ran; empty job sets do not
prove the privacy of produced Oban arguments.

Observed database `singularity_test_688b8ecc56c59249a0d4c43c` was independently
absent after exit (count 0), and exact integration directory
`/tmp/singularity/integration/688b8ecc56c59249a0d4c43c` was absent.

Independent Astra SPEC re-review cleared the exact corrected source hash:
both Important harness findings resolved; no Critical, Important, or Minor
finding remains. Fresh independent QUALITY review and final scoped checks
remain pending. One harness diagnostic correction passed; production repair
rounds remain 0.

## Final scoped gate and independent reviews

All following commands ran serially in the Phase 2 worktree with
`MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps`.
Test commands used `MIX_ENV=test`. The tested file retained SHA-256
`9f361db0524d89856ea1b9dbbef8610e33253a4b1193c58d816bff89bebcb31c`
through formatting, verification, and both independent reviews.

```sh
devenv shell -- mix format --check-formatted \
  apps/singularity_runtime/test/singularity/runtime/document_import_live_test.exs
devenv shell -- mix test \
  apps/singularity_runtime/test/singularity/runtime/document_import_test.exs \
  --seed 41123
devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_import_live_test.exs \
  apps/singularity_runtime/test/singularity/runtime/document_api_test.exs \
  --seed 41123 --trace
devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_import_live_test.exs \
  --seed 90731 --trace
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
git status --short
```

Results:

- Format: session `11091`, exit 0.
- Existing fast import: session `56465`, exit 0; 7 tests, 0 failures
  (0.6 seconds).
- Combined integration: session `25337`, exit 0; 29 reported, 8 excluded,
  **21 executed**, 0 failures (16.4 seconds). The 8 fast API unit cases are
  excluded by this integration command; their execution is not claimed here.
- New live import repeat: session `11960`, exit 0; 7 tests, 0 failures
  (11.4 seconds), with changed test order under seed `90731`.
- Final production compile: session `29355`, exit 0.
- Xref: session `77161`, exit 0, `No cycles found`.
- Diff whitespace check: exit 0; status is confined to the four allowlisted
  files and the preserved original untracked C integration plan.

The three final test commands executed **35 tests**, 0 failures. All live
privacy windows in both final integration runs reported zero query events;
each separate real denial control satisfied its bounded RLS-event assertion.
No environmental Postgrex timeout appeared in these final runs.

Both final integration databases were independently absent after exit:
`singularity_test_8c4bbf8c609cbba03bd7a34f` and
`singularity_test_03633069d29b71eaa2b39b0a` (`pg_database` count 0 each).
Their exact integration storage roots were absent. Owned live fixture files
were cleaned; preexisting unrelated ignored fixtures were not removed.

Independent Astra SPEC and fresh QUALITY/security reviews cleared the exact
tested source hash with no Critical, Important, or Minor actionable finding.
No reviewer ran Mix, altered services, wrote source, or performed Git writes.

## Bounded acceptance and handoff

PASS: the live public-import qualification supplement is accepted locally,
subject to the exact source hash and scoped gate above. The baseline source
is `52d9df11bd943ab7808896be3d0c49e9c7c7808a`; reviewed plan commit is
`7de5636928efee90948bbd7371f4938e10b388e7`. Parent records the resulting
qualification commit SHA in the final Git handoff; it is not publication.

Changed files are exactly the new Runtime live-import test, its design, its
implementation plan, and this qualification matrix. No production file,
dependency, configuration, support helper, or migration changed. No Vault
feature/semantics, production grant/activation, backup V3, search projection,
Note Save, version bump, tag, merge, push, release, or deployment occurred.

NOT RUN: E2E, the complete README gate, and broader release/deployment gates.
Task 15 and Phase 2 are **not accepted** on this focused green subset.
Remaining source-audit slices are recovery catalog/rollback, backup snapshot
and inventory, inclusive extraction limits, and real scanned/process/privacy
extractor cases. The full required acceptance gate still includes E2E and
cannot be waived under the standing exclusion.

One test-harness diagnostic correction passed; no production repair was
attempted. The transient database-creation I/O delay remains an unproven
environmental latency cause, not a resolved infrastructure issue.

## Protected artifacts

The original untracked full-C integration plan remains excluded from staging
and byte-identical: SHA-256
`350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.
The frozen Runtime extraction test remains SHA-256
`b8c6f602344926f4ec085edbd7b3a3b84173efb3d58654cc90ce20d31ba07e42`;
the accepted supervised-restart test remains SHA-256
`3fe960f0afb64f5253626bafbd3acda5b6a04d14c9c884c2b3dc380401f9aed9`.
These hashes and `git diff --check` were verified before new qualification
source changes.

## Recovery qualification: unchanged baseline

Source baseline: `125653e9dbb6d979703360138abf55fb888f2711`, on the existing
`codex/v0.2-phase-2-import-extraction` worktree. The next bounded supplement
characterizes live recovery function hardening, UUID-only scanning, and atomic
rollback on a valid successor-event collision. Production behavior and
migrations remain unchanged; E2E/full acceptance remain NOT RUN.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs \
  --seed 1208
```

Unchanged baseline: session `21466`, exit 0; 7 tests, 0 failures (2.4 seconds).
No exclusions were reported. After exit, the exact database
`singularity_test_bd834312205b4009eb2047ea` had `pg_database` count 0 and its
storage root `/tmp/singularity/integration/bd834312205b4009eb2047ea` was absent.
Borrowed PostgreSQL was ready with zero restarts; no service restart occurred.
The three protected artifact hashes above were rechecked and unchanged.

Independent Astra design review found one setup omission: the fresh positive
control must be claimed as expired generation 1 before recording its baseline.
The parent verified the pending generation-0 fixture behavior and corrected
both documents. Independent re-review cleared the correction and all remaining
design/plan contracts. Standing approval permits test-only GO; new tests and
their qualification remain pending. This baseline does not close Task 15,
Phase 2, or the release acceptance gate.

## Recovery first characterization and harness diagnosis

The reviewed recovery documents were committed locally as
`326a7868538c584889182af54ad8ced5fe5ce8df`. Astra modified only the owning
reconciler test; all seven existing contracts/assertions were preserved.
Parent read the complete 602-line test before execution. Initial SHA-256:
`7e935725982a75dfde13ccf2f19c8fc8867810dcf4dde233d56227d1e4580a02`.

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs \
  --seed 1208 --trace
```

Session `86821`, exit 2: 9 tests, 1 failure (3.0 seconds). The catalog/grant
and real UUID scanner contracts passed. The collision contract stopped before
its production recovery call: it incorrectly expected the entire owner-scoped
Asset search projection to be empty. `KnowledgeFixtures.source!/0` calls
`Fixtures.two_vaults!/0`, which inserts an established source Asset projection;
the observed row identified that source Asset/version, not the Document.

This is a test-harness assumption defect, not a reproduced recovery defect.
The design requires no Document search row and preservation of source rows.
Astra was assigned a surgical assertion correction retaining full snapshot
equality, with no deletion/mutation of the source projection. One harness
diagnostic correction is in progress; production repair attempts remain 0.

After the failed run, exact database
`singularity_test_01c31da0525dc520c94bb6e9` had `pg_database` count 0 and exact
storage root `/tmp/singularity/integration/01c31da0525dc520c94bb6e9` was absent.
No service, production source, migration, or grant policy changed.

## Corrected recovery characterization

The parent verified the fixture's source projection insertion. Astra changed
only the invalid empty-owner-search assertion: the test now identifies the
existing source Asset/version/owner projection, explicitly excludes each new
Document version, and preserves every complete snapshot comparison. No
projection was deleted or changed. Corrected test SHA-256:
`98e26e5e0b5e6353c4e935276d4cd6ef23b9342217bc841f311d1a45b1d374bc`.

The exact first-characterization command above was rerun: session `79425`,
exit 0, 9 tests, 0 failures (3.0 seconds), no exclusions. Real adapter and
reconciler calls both returned the exact sanitized conflict while all nine
owner-filtered table snapshots and the source pin count remained equal.
The collision stayed scan-eligible; a fresh expired same-source control
recovered exactly once, cleared only the allowed attempt fields, and inserted
one correct IDs-only successor without changing source rows or projections.

Exact database `singularity_test_27e763c21e357cd216f0d9e2` had `pg_database`
count 0 after exit; root
`/tmp/singularity/integration/27e763c21e357cd216f0d9e2` was absent. One harness
diagnostic correction passed; production repair attempts remain 0. Independent
SPEC/QUALITY review and the final scoped repeat/regression remain pending.

## Recovery formatting and scoped regression

Initial format check (session `64817`, exit 1) identified only four formatting
areas in new code. Before formatting, the combined owning-file/lifecycle
regression ran in session `70133`, exit 0: Storage 19 tests (6.4 seconds),
Runtime 9 tests (2.9 seconds), total 28 executed, 0 failures, no exclusions.
The existing deferred-constraint test emitted its expected Postgrex
`document_versions_completion_check` disconnect diagnostics; it passed.
Database `singularity_test_1e98c528fb4d14af995dd8cf` and its exact storage root
were independently absent afterward.

Parent formatted only the owning test in session `67862`, exit 0; format check
session `12193` then exited 0. Final test SHA-256:
`f652a9e18fb90935799704251e13ff8d80530c772886c2280038eac227e9f39b`.
Independent Astra SPEC review re-read the formatted diff, confirmed the four
formatting-only changes and no semantic changes, and cleared that exact hash.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix format --check-formatted \
  apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs \
  apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs \
  --seed 1208 --trace
```

Final formatted combined run: session `55117`, exit 0; Storage 19 tests,
0 failures (6.3 seconds), Runtime 9 tests, 0 failures (3.0 seconds). Total
28 executed, no exclusions. The same expected deferred-constraint diagnostics
appeared in its passing preexisting test. Exact database
`singularity_test_61b2d96f67b9df0a51b53f5c` had `pg_database` count 0 and exact
root `/tmp/singularity/integration/61b2d96f67b9df0a51b53f5c` was absent.

Changed-order repeat and fresh independent QUALITY/security review remain
pending. No production repair or service restart was needed.

## Recovery final scoped gate

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs \
  --seed 90731 --trace
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix compile --warnings-as-errors
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
git status --short
devenv processes list
```

Changed-order repeat: session `39543`, exit 0; 9 tests, 0 failures
(3.4 seconds), no exclusions. The collision test preceded later global scan
and reconciler cases, all of which passed with the exact-resource fixture
retirement in place. Exact database
`singularity_test_ad0358091cd83cecf5f81114` had `pg_database` count 0; exact
root `/tmp/singularity/integration/ad0358091cd83cecf5f81114` was absent.
Compile: session `4651`, exit 0. Xref: session `86274`, exit 0,
`No cycles found`. Diff whitespace check: exit 0. Borrowed PostgreSQL remains
ready with zero restarts; no parent-owned service was started or stopped.

The final formatted combined/repeat commands executed **37 tests**, 0 failures.
Test SHA-256 remains `f652a9e18fb90935799704251e13ff8d80530c772886c2280038eac227e9f39b`.
All three protected artifact hashes remain identical to the recorded values.
No production module, migration, support helper, dependency, or configuration
changed. Final fresh independent QUALITY/security review remains pending;
these scoped results do not imply Task 15 or Phase 2 acceptance.

## Recovery bounded acceptance and handoff

PASS: the bounded recovery qualification supplement is accepted locally.
Independent Astra SPEC and fresh QUALITY/security reviews cleared final test
SHA-256 `f652a9e18fb90935799704251e13ff8d80530c772886c2280038eac227e9f39b`
with no Critical, Important, or Minor actionable findings. Reviewers performed
no Mix, database, service, source, or Git mutations. Parent verified source
scope, formatting, all 37 final scoped executions, compilation, zero xref
cycles, each exact database/root cleanup, and protected artifact hashes.

Source baseline is `125653e9dbb6d979703360138abf55fb888f2711`; reviewed
design/plan commit is `326a7868538c584889182af54ad8ced5fe5ce8df`. Parent records
the resulting qualification commit in the Git handoff, not as publication.
Changed files are exactly the existing Runtime reconciler test, its new design
and implementation plan, and this existing qualification matrix. All seven
existing tests/assertions remain preserved. No released migration changed.

One test-harness diagnostic correction passed. No production repair was
attempted; no behavioral RED/production-fix claim is made. Existing expected
deferred-constraint diagnostics are not new recovery failures. No Vault
feature/semantics, custody/key/capability policy, production activation,
backup V3, search projection behavior, Note Save, version bump, merge, push,
tag, release, or deployment changed. The original untracked C plan was not
staged, and the existing worktree/branch remain in place.

NOT RUN: E2E, complete README acceptance, and broader release/deployment gates.
Task 15 and Phase 2 remain **open and unaccepted**. The next recommended
source-audited qualification slice is backup unsupported-inventory owner
scoping and repeatable-read snapshot behavior, followed by inclusive extraction
limits and real scanned/process/privacy extractor cases. These require their
own bounded design/review before implementation. No focused subset waives
the standing E2E exclusion or the complete acceptance requirement.

## Backup qualification: unchanged baseline and diagnostic prerequisite

Baseline source: `dfe60aa11ac471da243e0523a33a23b0bf426276`, existing Phase 2
worktree/branch. The next audited evidence gaps are live omitted-inventory
owner scoping and repeatable-read snapshot consistency. No new backup test
or production change preceded this characterization.

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs \
  --seed 1208 --trace
```

Session `97869`, exit 2: 11 tests, 1 failure (5.6 seconds), no exclusions.
The existing Document-owner refusal test stopped at fixture creation:
`DocumentRepository.create_pending/2` returned the exact sanitized
`:forbidden` error instead of a Document. Its backup guard assertion was
therefore NOT REACHED. All ten other existing exporter cases passed.

Parent and Astra traced the setup mismatch: `prepared_source!/0` inherits
the legacy locked default and assigns no `asset.read`. The current repository's
extraction request requires a live unlocked owner with `asset.read`.
Existing `DocumentRepositoryTest.grant_asset_read!/1` supplies both fixture
operations before creation; the backup fixture supplies neither. The proposed
repair is confined to that owning test's fixture setup, preserving the real
repository call and every refusal/other-owner/privacy assertion. No repository
authorization weakening, production grant, support helper, or Vault feature
repair is authorized. New qualification awaits reviewed design and rebaseline.

After exit, exact database `singularity_test_3335b212a5cde4a6b376f543` had
`pg_database` count 0 and root
`/tmp/singularity/integration/3335b212a5cde4a6b376f543` was absent. PostgreSQL
remains ready with zero restarts. `unbuffer` is unavailable; no environment
installation/change was made, and the established `devenv shell` runner is
used. No E2E/full acceptance or publication occurred.

Protected V2 wire-schema SHA-256:
`992ef89fb52a91ccaa0d7cf2b3ae6607a465e7b345cca5d6c55a86c3fac9f3e6`.
Unchanged owning-test SHA-256:
`fdd24d5d4ac1ea98f9bcc8ccf51b9ee4e000c8ef5ff4dda62d739cc529a192dd`.
The existing frozen extraction/restart tests and original untracked C plan
retain their previously recorded hashes. Repair attempts in this slice: 0.

The parent reproduced the same failure in isolation before any repair:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs:51 \
  --seed 90731 --trace
```

Session `1451`, exit 2: 11 reported, 10 excluded, **1 executed**, 1 failure
(2.5 seconds). The same existing `create_pending/2` assertion received
`:forbidden`; this is independent of ordering among the other ten cases.
Exact database `singularity_test_276889fd5d53cb20954d8d85` had `pg_database`
count 0 and its exact storage root was absent. Source inspection confirmed
the locked default in `20260718000200_create_identity_and_vault_tables.exs`.

Parent read both backup qualification documents completely. Fresh independent
Astra design review cleared their fixture repair, legal independent/composite
inventory classification, live guard restrictions, independently bound records
cuts, and post-commit two-connection snapshot/cleanup protocol. Standing approval
permits **fixture-repair-only GO** first. The documented successful 11-test
rebaseline remains a prerequisite to new qualification implementation.

## Backup fixture repair and rebaseline

Astra added only the existing repository test's fixture prerequisites to the
Document-refusal case: unlock that exact disposable owner fixture and assign
`asset.read` to its existing principal. All assertions, real repository call,
temporary grants, title/privacy checks, and other-owner success remain intact.
Parent read the exact 17-line added block before running the whole owning file.
Repaired test SHA-256:
`f27e9ec18cf26c7fabdc3610e0c6e0302a6cff06a26189bf20662f33b7c5dd6e`.

The exact full-file baseline command above was rerun, session `48803`, exit 0:
11 tests, 0 failures (8.3 seconds), no exclusions. The existing Document fixture
now creates through the real repository, and its unchanged backup refusal and
other-owner checks execute and pass. This resolves the demonstrated fixture
setup defect on the first repair attempt; production repair attempts remain 0.

Exact database `singularity_test_30e0e43d8107925c3ba9dbfd` had `pg_database`
count 0 after exit and root
`/tmp/singularity/integration/30e0e43d8107925c3ba9dbfd` was absent. No production
file, support helper, migration, V2 schema, service, or policy changed. The only
legacy-owner fixture mutation required for knowledge compatibility is reported
explicitly; no Vault feature work occurred. Independent Task 1 reviews and
new qualification implementation remain pending.

Task 1 closure: formatter session `84277`, exit 0. Independent Astra SPEC and
fresh QUALITY/security reviews cleared exact repaired test hash
`f27e9ec18cf26c7fabdc3610e0c6e0302a6cff06a26189bf20662f33b7c5dd6e`
with no actionable findings. Parent verified the parameterized exact owner/
principal fixture scope, preserved assertions, all 11 passing cases, cleanup,
and unchanged V2 schema. Standing approval now permits Tasks 2–4 test-only
qualification GO. Those new assertions and the final qualification gate remain
unimplemented/unverified; Task 15 and Phase 2 remain open.

## Backup qualification: first new-contract characterization

Tasks 2–4 added live guard catalog/privilege checks, both-entrypoint authorization,
eight legal omitted-inventory fixtures with clean-owner controls, and a synchronized
post-commit repeatable-read test. Parent read the complete added diff before running.
Initial owning-test SHA-256:
`877e512fcd4c5430158de5eaf7d6fae849e4420c7e590781b0af6b478cde0a50`.

The full-file command above, seed 1208 with trace, session `49858`, exited 2:
21 tests, 2 failures (18.3 seconds), no test exclusions. Both failures occurred
in new test helpers before the affected refusal assertions: the ready-Document
helper returns a Core `SourceLocator` struct, not a JSON-encodable map. The
fragment case encoded it as a canary; the citation case passed it to the JSONB
parameter. The other 19 cases, including the committed-writer snapshot test,
passed. This is fixture characterization evidence, not a production guard defect.

Parent verified the established `SourceLocator.to_map/1` representation and
requested a surgical Astra correction confined to the owning test. Citation
UUID parameter types also require verification against raw-SQL binary UUIDs.
No protocol derivation, shared-helper edit, production repair, or weaker assertion
is authorized. This is the first observed new-qualification harness failure;
the user permits at least three failed repair attempts if needed.

After terminal exit, exact database
`singularity_test_710b5f58a155ef65475903c3` had `pg_database` count 0 and root
`/tmp/singularity/integration/710b5f58a155ef65475903c3` was absent.
E2E, full README acceptance, bundle restore, and publication remain NOT RUN.

### Astra fixture conversion repair and final-source characterization

Astra repair attempt 1 converted the citation JSONB parameter and locator
canaries through the established `SourceLocator.to_map/1`. Source verification
also established that fragment IDs are SHA-256 text identities, not UUIDs;
the citation column is `text`, so the existing fragment parameter was retained.
No production or shared-support defect was demonstrated or repaired.

Parent formatted only the owning test (session `6924`, exit 0), read the full
diff, and checked whitespace. Final formatted owning-test SHA-256:
`8fcea4a0e55ae3dae6b6d768782c5e66989a0157d190f3b23239c4b75bb28297`.
The full-file seed-1208 command, session `87859`, exited 0: 21 tests,
0 failures (17.9 seconds), no test exclusions. The previously failing fragment
and citation cases now reach their inventory, both-entrypoint refusal, and
clean-owner assertions and pass. The snapshot test passes unchanged.

Exact database `singularity_test_bcea928f033bd7dd25c5b810` had `pg_database`
count 0 after exit and its exact storage root was absent. This repair succeeded
on its first attempt; the user's three-failure allowance did not require retries.
Independent final reviews and changed-order verification remain pending.

Changed-order run, session `5522`, exit 0:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs \
  --seed 90731 --trace
```

21 tests, 0 failures (18.9 seconds), no test exclusions. Exact database
`singularity_test_00214a4fadb48494d40e2ca2` had `pg_database` count 0 and its
exact storage root was absent. Final-source evidence totals **42 executions,
0 failures**; the earlier failing characterization is not included as a pass.

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix format --check-formatted \
  apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
```

Formatter session `72141`, exit 0. Xref session `35195`, exit 0:
`No cycles found`. Whitespace check exit 0. V2 schema and protected extraction,
restart, and original untracked C-plan hashes remain identical. Main remains
clean at `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`.

Fresh independent Astra SPEC review cleared exact final test hash with no
actionable Tasks 2–4 gaps. Fresh QUALITY/security review is pending; no final
slice acceptance or commit is claimed yet.

### Backup qualification closure

Fresh independent Astra QUALITY/security review also cleared the exact final
test hash without actionable findings. Both reviews were read-only source
reviews; the parent-owned executions above are the test evidence. Parent verified
the complete checklist and allowlisted four changed files: owning test, backup
design, backup plan, and this existing matrix.

PASS: deployed function security/catalog and owner-scoped structural inventory;
both unauthorized exporter entrypoints; eight legal inventory fixtures at both
entrypoints with successful clean-owner controls; exact sanitized refusal;
unchanged old export snapshot after acknowledged writer commit; refusal in the
fresh snapshot; existing legacy export assertions; 42 final-source executions;
formatting, zero xref cycles, whitespace, isolated-run cleanup, protected hashes,
and independent SPEC/QUALITY reviews.

Coverage distinction: Document, Note attachment, tag, and relationship fixtures
are four independent unsupported cases. Fragment, receipt, citation, and resource
tag fixtures require legal unsupported parents. All eight targets are covered,
but dependent fixtures do not prove independent reachability of their OR branches.

Production/support/migration/config changes: 0. V2 schema remains byte-identical.
New qualification harness repairs: 1 successful attempt; production repairs: 0.
The earlier prerequisite commit's disposable legacy-owner unlock/asset.read setup
is unchanged and explicitly reported above; no Vault feature work occurred.
Main, shared services, and user-owned untracked C plan remain untouched. The local
test commit is authorized; no push, merge, tag, release, or deployment is included.

NOT RUN: E2E, complete README gate, real bundle restore, deployment, and production
acceptance. **Task 15 and Phase 2 remain open and unaccepted.** This bounded backup
qualification plan stops here. Recommended next separately designed slice:
inclusive extraction limits and real scanned/process/privacy extractor cases.

## Inclusive extraction limits: source audit and unchanged baseline

Source: `c7efaec657c1f3d18fad16bed39ea6ae0e85a083` in the existing Phase 2
worktree. Parent and a read-only Astra audit found that Core already has exact
16,777,216-byte success with 256 exact-size fragments; preserve that evidence.
The missing inclusive positives are 4096 fragments, 4096 PDF pages, and PDF raw
output exactly at its limit. A multi-codepoint grapheme boundary and an independent
native raw-cap pair complement those gaps without production changes.

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix test \
  apps/singularity_core/test/singularity/core/document_fragmentation_test.exs \
  apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs \
  --seed 1208 --trace
```

Unchanged baseline session `15903`, exit 0: Core 6 tests/0 failures (5.3 seconds),
Ingest PDF 16/0 (10.0 seconds), **22 total**. ExUnit excludes integration tags,
but neither module has integration cases and no tests were excluded. No database
was allocated and no service operation occurred. Existing native timeout and
cancellation tests, encrypted/malformed/empty real PDF fixtures, all adjacent
over-limit refusals, and exact Core 16 MiB success passed unchanged.

Baseline owning-test SHA-256 values:

- Core: `24e264464d3f4a8ee82d4bf8f3837d7103922beb13231b89c2d19f9f3bd68f8d`
- PDF: `47d5ad7e1943f2c1e43d2d88439aeedfea3becea8509358e73155ba55f40f773`

Protected production SHA-256 values:

- Core fragmentation: `811ad7db20d6670ea6e5bb00c418bb03466e7d77d5d4dccc5668c17e70ae65ba`
- PDF adapter: `3ec8e2d2e89f9bb428303836794e111ad44bab1754f48fb10756506290516370`
- Poppler controller: `ec1e2939185898a393a537e459d9817de9c546fe6d2fa7047488e1f11bc925e5`

Parent wrote and read the complete bounded design and detailed plan. Fresh
independent Astra design review is pending before test-only GO. Only the two
owning tests and these three records may change. Source/fixture binary/support/
dependency/config/migration changes and production repair are not authorized.
The original untracked C plan remains protected. E2E/full acceptance NOT RUN;
Task 15 and Phase 2 remain open.

Inclusive-limits design closure: fresh independent Astra review read both full
documents and traced Core/PDF/Poppler contracts. No Critical/Important finding
remained. Parent confirmed five vectors, exact types, 27 expected test executions,
evidence boundaries, old assertion preservation, and the two-test file scope.
Standing approval now permits test-only GO; production repair remains prohibited
without a separate bounded review. No qualification test has run yet.

### Inclusive-limits implementation and first final-source run

Reviewed design/plan and baseline records were committed locally as
`f0735345e379f3dc1ec7f3ac16dd0e70f0d944e0`. Astra added exactly two Core and three
PDF tests; parent read the complete diff, 102 insertions and one alias-line
replacement. No old test assertion, runner, helper, production file, or limit
changed. Formatting session `72873`, exit 0, did not change the supplied hashes.

Final formatted owning-test SHA-256 values:

- Core: `2df35098a64b2ff792dc3c741af4533ac1e03f4bb1ddd0af8810dec1ec4927ea`
- PDF: `38302505e1266731e081141eef2d6565199349be08f446ed7efc2de49f843d0d`

The full two-file seed-1208 command above, session `52066`, exited 0:
Core 8 tests/0 failures (6.1 seconds), PDF 19/0 (18.4 seconds), **27 total**.
No cases were excluded and no integration database was allocated. The new
4096-fragment, intact multi-codepoint grapheme, 4096-page runner-double, raw PDF
16 MiB including form feed, and native exact-cap/one-extra-byte assertions all
execute and pass against unchanged production. The native cap pair completed
in 1013.3 ms; the adapter's large output parsing completed in 7196.7 ms. These
are observations, not new timing thresholds or performance guarantees.

Protected Core/PDF/Poppler production hashes remain equal to the baseline.
Repair attempts: 0; no failure was hidden by retry. Changed-order repeat and
independent final reviews remain pending. Task 15 and Phase 2 are not accepted.

### Inclusive-limits final verification and closure

Changed-order command:

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix test \
  apps/singularity_core/test/singularity/core/document_fragmentation_test.exs \
  apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs \
  --seed 90731 --trace
```

Session `92252`, exit 0: Core 8 tests/0 failures (6.2 seconds), PDF 19/0
(19.4 seconds), **27 total**. No test exclusions. Final formatted source totals
**54 executions, zero failures**, excluding the separate 22-test baseline.
No database allocation or shared-service change occurred in either final run.

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix format --check-formatted \
  apps/singularity_core/test/singularity/core/document_fragmentation_test.exs \
  apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
```

Formatter session `27770`, exit 0; xref session `2656`, exit 0, `No cycles found`;
standalone whitespace check exit 0. Final tests retain the hashes above. Production
Core/PDF/Poppler hashes remain identical. Protected Runtime extraction/restart,
V2 schema, and original untracked C plan retain their previously recorded hashes.
Main remains clean at `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`.

Fresh independent Astra SPEC and distinct QUALITY reviews inspected actual diffs
against `f073534` and the exact final hashes. Both cleared without actionable
findings, independently verifying old assertion preservation and the five vectors.
These reviews did not execute tests; the parent runs above supply test evidence.

PASS: inclusive 4096 Core fragments with stable source provenance and content IDs;
multi-codepoint grapheme splitting without content change; 4096 PDF page maps;
exact 16 MiB PDF raw output including separator; native exact raw cap and one-byte
overflow refusal; existing exact semantic 16 MiB and adjacent negative assertions;
formatting, zero cycles, protected hashes, and independent reviews.

Evidence limits: PDF page/raw-output positives use FaultRunner, not a physical
4096-page PDF or a real 16 MiB Poppler PDF output. The native pair uses real guardian
and `cat`, not PDF interpretation or descendant-overflow cleanup. PDF's boundary
body is 16,777,215 semantic bytes because the raw form feed consumes one byte;
the existing Core test separately proves 16,777,216 semantic bytes. These tests
do not establish end-to-end worker or production acceptance.

Repair attempts: 0. Production, support, migration, fixture binary, dependency,
configuration, Vault feature, and custody changes: 0. Parent permits only a local
five-file commit (two tests, design, plan, and this existing matrix). The original
untracked C plan is not staged; Phase 2 worktree/branch remain in place. No merge,
push, tag, release, activation, or deployment occurred.

NOT RUN: E2E, complete README gate, complete Task 15/Phase 2 acceptance, deployment,
and production acceptance. **Task 15 and Phase 2 remain open and unaccepted.**
This bounded plan stops here. Recommended next separately designed slice: real
image-only scanned PDF, blocked-stdin/output-overflow descendant cleanup, repeated
real PDF-to-fragment digest, and adapter log privacy.

## Real extractor qualification: source audits and unchanged baseline

Source: `d39ad93f257df3a6e01a87a420c7a034c888192b` in the existing Phase 2
worktree. Two parallel read-only Astra audits examined PDF/fragment/completion
and Logger/IO contracts, and the full native guardian/controller lifetime.
Parent read the complete guardian source and relevant pure/adapter contracts.
The existing empty PDF is not an image-only scanned fixture; native timeout
and cancellation cases use empty payloads, and the new exact-cap native case
has no descendant tree. These gaps are not established production defects.

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix test \
  apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs \
  --seed 1208 --trace
```

Session `73785`, exit 0: 19 tests, zero failures (18.9 seconds), no test exclusions,
no integration database or service operation. Existing real encrypted/malformed/
empty/multipage, inclusive/over-limit, and native cleanup assertions passed.
Owning-test hash remains
`38302505e1266731e081141eef2d6565199349be08f446ed7efc2de49f843d0d`.
Guardian C source hash:
`c9232d53efa3280fb1d53fe7badcd317138e4ffe10425d4637d4d0f6af66d607`.

Recommended architecture: add three real PDF/determinism/privacy cases and one
image-only fixture; put the two additional native lifecycle cases in a dedicated
companion test, preserving all established native helpers and assertions.
The parent awaits complete written design/plan plus fresh independent review
before implementation GO. No production repair, new dependency, support edit,
migration, activation, or Vault feature is authorized.

Audit boundaries: the guardian buffers the entire frame before target fork;
large-input readiness therefore establishes guardian-to-target backpressure,
not a blocked BEAM frame writer. Exact timeout/overflow results alone do not
prove cleanup; record and verify the live target, ordinary descendant, TERM-
ignoring session escapee, and guardian, then establish their disappearance.
Native test control uses a separately owned FIFO, not target stdin.

Logger capture alone cannot lower its globally configured warning threshold;
the test must restore any temporary debug-level change in try/after and capture
metadata. BEAM stdout/stderr and Logger capture do not prove direct native OS
fd2, runtime telemetry, audit, job arguments, or outbox privacy. Those evidence
boundaries remain explicit. E2E/full acceptance NOT RUN; Task 15 and Phase 2 open.

Parent restored the existing isolated worktree at `d39ad93` and verified protected
hashes and main's unchanged clean `e866990` state. Complete design and plan were
read and self-reviewed; a fresh independent Astra architecture review cleared
the test-only scope after requiring exact normalized page texts. Parent verified
installed `pdftotext -layout` output as `First page\n\fSecond page\n\f`, exit 0.
Test-only GO issued under standing approval; two Astra workers own disjoint PDF
and native-test paths. Parent retains exclusive execution and evidence ownership.

Fixture authoring repair round 1: apply_patch normalized six intended CRLF classic
xref records to LF (997 instead of 1,003 bytes). Qualification stopped before
executing that fixture. Astra proposed and independent Astra review verified a
strict PDF 1.5 ASCIIHexDecode xref stream, preserving the image-only content,
object offsets, and ordinary whitespace checks. Parent approved this same-file
encoding repair and restored omitted image-structure assertions. Final fixture
is 1,070 ASCII/LF bytes; three stream lengths 33/324/100, object offsets
9/58/115/245/327/820, seven decoded xref entries, startxref 820. No production
behavioral failure or repair occurred; no assertion was weakened.

Native first execution: parent format session `20683`, exit 0, followed by
`MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_ingest/test/singularity/ingest/documents/poppler_lifecycle_test.exs --seed 1208 --trace`.
Session `74502`, exit 0: 2 tests, zero failures (6.7 seconds), integration-tag
exclusion only; both native cases executed. No integration database/service
operation. Native candidate SHA-256:
`b322474226508d338a4af62925a87675221356aaba8e5a473528ba2be1cf24e3`.

## Real extractor qualification: final source verification

Six-file scope: existing PDF test, new native lifecycle companion, image-only
fixture, bounded design/plan, and this existing matrix. Exactly three PDF tests
and two lifecycle tests added; the original 19 tests/helpers remain unchanged.
Parent read complete patches and fixture before execution. Both owning modules
are `async: false`; no test assertion, exclusion, deadline, or process limit was
weakened. Ordinary integration exclusion applies; all 24 selected cases ran.

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix test \
  apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs \
  apps/singularity_ingest/test/singularity/ingest/documents/poppler_lifecycle_test.exs \
  --seed 1208 --trace
# Same complete owning files, changed-order seed:
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix test \
  apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs \
  apps/singularity_ingest/test/singularity/ingest/documents/poppler_lifecycle_test.exs \
  --seed 90731 --trace
```

Session `89873`, exit 0: 24 tests, zero failures, 25.2 seconds. Changed-order
session `15393`, exit 0: 24 tests, zero failures, 25.3 seconds. Both use identical
final source hashes below. Together these provide 48 test-case executions across
two complete owning-file runs; the earlier two native cases use the same final
native hash, for 50 test-case executions, zero failures. New behavioral assertions passed on their first
execution; fixture-authoring repair round 1 was resolved before execution.

Final SHA-256:

| Path | SHA-256 |
| --- | --- |
| `pdf_test.exs` | `c6c83e6c0f3e7c0d0bf2235c6e0b8d41f65668b2a0ff1872effa969da1df3eb6` |
| `poppler_lifecycle_test.exs` | `b322474226508d338a4af62925a87675221356aaba8e5a473528ba2be1cf24e3` |
| `scanned_image_only.pdf` | `b4032a9dc96aae0f63499620ab96176265e8bfd576a6dbaaa89a47b1417310a7` |

Fixture checks: actual-byte JavaScript validation confirmed size, ASCII/LF,
all stream lengths/offsets/xref entries/startxref. `devenv shell -- pdfinfo` exit 0
reported one unencrypted PDF 1.5 page, no metadata/JavaScript, 1,070 bytes.
`devenv shell -- pdfimages -list` exit 0 found the painted 23x7 gray image object
5. The real adapter tests returned exact `no_extractable_text`, independently
of the preserved empty-PDF assertion.

Formatting sessions `20683` (native) and `53879` (PDF), exit 0. Final
`mix format --check-formatted` for both modules: session `6201`, exit 0. Final
`mix xref graph --format cycles --fail-above 0`: session `93254`, exit 0,
`No cycles found`. Every Mix command used `MIX_ENV=test`, the shared dependency
path, and `devenv shell`; the known devenv-version advisory is not a test error.
Whitespace checks pass without exemptions or Git-attribute/configuration changes.

PASS: real painted image-only scan rejection without OCR; exact two-page source
locators, fragment identities/digests/ordinals and repeated real Core completion;
sanitized real fixture/fault outcomes with empty Logger/debug-metadata and BEAM
IO captures, restoring the primary threshold; guardian-to-target stdin
backpressure timeout; output-overflow cleanup; observed live target, normal
grandchild, TERM-ignoring setsid escapee, and guardian identities, all absent
before fallback cleanup; formatting, zero cycles, and protected hashes.

Evidence limits: repeatability applies to installed Poppler, not upgrades. BEAM
captures do not inspect arbitrary OS fd2 or prove telemetry/audit/job/outbox
privacy. Large-input readiness proves target-pipe backpressure, not a blocked
BEAM frame writer. Failure artifacts preserve observed identities but incomplete
readiness cannot prove absence of unobserved descendants. No failures occurred.

Protected Runtime extraction/restart tests, V2 backup schema, original untracked
C plan, and production Core/PDF/Poppler/guardian retain their earlier exact
hashes. No production, support, dependency, configuration, migration, Vault
feature, custody, or activation change; no database/service operation, push,
merge, tag, release, or deployment. Optional separate Core-file execution was
not selected; real Core values are directly exercised in the composition test.

Fresh independent Astra SPEC review cleared exact final source, mechanically
confirmed byte-for-byte preservation of all old PDF tests/helpers, and decoded
the image/xref independently. It did not execute tests; parent sessions above
supply execution evidence. Distinct fresh Astra QUALITY review also cleared the
exact three final source hashes without actionable findings, independently
inspecting lifecycle cleanup, privacy, fixture and existing production contracts.
Both reviews are source inspection, not independent test runs. Final independent
documentation closure also cleared after correcting execution-count units to
test cases; no actionable findings remain. Only a six-file local commit is
authorized. The next useful move is the existing non-E2E README/Task 15 gates on
this exact source, not another qualification design. A clean verification worktree
must preserve the original untracked C plan; required E2E remains NOT RUN and
cannot be replaced by partial acceptance.

## Existing non-E2E README gate: attempt 1 and formatter diagnosis

Source: local commit `3f7ab99b863b7e7345a68c024a9dbf8fa3b8813e`. Parent created
the clean project-local verification worktree `.trees/v0.2-phase-2-verification`
on `codex/v0.2-phase-2-verification`, preserving the original untracked C plan.
No acceptance-source edits were made in the verification checkout. Two read-only
Astra preflights verified service ownership and frontend commands. Source-defined
manual E2E triggering does not prove hosted checks; no remote writes occurred.

Environment probe session `61618`, exit 0, verified dedicated paths:
`DEVENV_STATE=<verification-worktree>/.devenv/state`,
`PGDATA=<verification-worktree>/.devenv/state/postgres`,
`DEVENV_RUNTIME=/run/user/1000/devenv-50f49bc`,
`PGHOST=/run/user/1000/devenv-50f49bc/postgres`, `PGPORT=5432`.
All manager PID/socket, postmaster PID, and PostgreSQL socket identities were
absent before startup. Parent ran one strict shell with an EXIT trap that stops
only this verified owned runtime; the borrowed `devenv-afa1eb9` was never adopted.

Runner session `5898`, exit 1, executed README order up to the formatter gate:

| Command | Result |
| --- | --- |
| `devenv up -d` | PASS |
| `devenv processes wait --timeout 120` | PASS |
| PostgreSQL identity query | PASS: owned data/socket directories, empty TCP listen address, port 5432 |
| `devenv shell -- bash apps/singularity_storage/priv/repo/bootstrap_roles.sh` | PASS, owned cluster only |
| `devenv shell -- mix deps.get` | PASS, all locked dependencies unchanged |
| `devenv shell -- mix deps.unlock --check-unused` | PASS |
| `devenv shell -- mix format --check-formatted` | FAIL: one Runtime extraction test file |

Mix commands used the shared source dependency path but verification-worktree
build outputs. Role bootstrap was deliberately isolated: its cluster-wide role
alterations/revocations must never run on the borrowed cluster. Cleanup completed;
new manager/socket/postmaster/socket artifacts are absent and readiness reports
no response there. The borrowed cluster still reports accepting connections.
No test database was allocated because execution stopped before integration.

NOT RUN after this failure: warnings-as-errors application compile, full unit,
full integration, independent bundle restore, frontend install/verify/check/unit/
build, final xref/actionlint/clean gate. E2E remains separately NOT RUN by user
exclusion. No partial acceptance was declared or later gate silently skipped.

Focused reproduction session `22978`, exit 1, reports the same sole unformatted
file: `apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`,
SHA-256 `b8c6f602344926f4ec085edbd7b3a3b84173efb3d58654cc90ce20d31ba07e42`.
Astra traced this to C1/C2 appended in `138b035`; later C3/C4/C5 formatting was
recorded separately while those earlier bytes were deliberately preserved.
Original A/B first 2,191 lines remain SHA-256
`373ad3d5fcfdd07ae522f00a037caa6efabbfba5f060c6c9685fb7d71da14178`.
The historical “final formatted source” description did not establish this
repository-wide formatting gate; this live failure supersedes that broad reading.

Task 15 explicitly requires stopping acceptance, diagnosing within Phase 2, and
rerunning the affected focused check plus the entire failed gate. The owning
Task 12 file is in that approved Phase 2 scope. Its historical tool-evidence
amendment explicitly prohibited whole-file formatting within that additive slice;
the parent read that design and plan completely and does not waive it silently.
Proposed new acceptance-repair exception is formatter-only for this one file,
with original A/B and C3/C4/C5 bytes unchanged, complete normalized AST and comment
text equality, and no assertion/tag/deadline/literal or production/Vault change.
Fresh independent Astra scope review cleared this exact exception after verifying
the actual source and complete historical freeze design/plan. Parent issues
formatter-only acceptance-repair GO under standing approval, preserving every
semantic freeze and the original byte-protected A/B/C3-onward regions. Only this
existing matrix and the owning Runtime test are authorized repair files.

NOT RUN: E2E, complete README gate, complete Task 15/Phase 2 acceptance,
deployment and production acceptance. **Task 15 and Phase 2 remain open.**

### Formatter repair: structural proof and focused verification

Parent applied `devenv shell -- mix format
apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs`
(session `41585`, exit 0). The complete diff changes only C1/C2 layout; original
A/B and C3-onward are byte-identical. No assertions or enforced behavior changed.
Parent read the entire actual diff without truncation before further verification.

Elixir structural proof session `59841`, exit 0, compared the complete file against
`3f7ab99` using `Code.string_to_quoted_with_comments!` and metadata-normalized ASTs:

| Proof | Result |
| --- | --- |
| Complete normalized AST and ordered comment texts | Equal |
| Syntactic registrations/assertions/tags | Unchanged: 24 modules, 91 `test` AST nodes, 554 assertions, 63 tags |
| Original A/B first 2,191 lines | Byte-identical, SHA-256 `373ad3d5fcfdd07ae522f00a037caa6efabbfba5f060c6c9685fb7d71da14178` |
| C3-onward through EOF | Byte-identical, SHA-256 `53e2a67134a4190a3e77c3ad7765dee08e55bb261945a812fa19629de9ad095f` |
| Complete formatted Runtime file | SHA-256 `32b04d1913f976a9b74f2a08a97c375b605836e5af17448940cc05433655e979` |

These are structural counts, not executed test-case counts. Formatting changes
source lines, but no line-sensitive macro dependency was found in the affected
code. The preserved source regions retain their original content.

An initial whole-formatter invocation (`1500`, exit 1) omitted the existing
shared dependency-path environment and stopped on unavailable dependencies,
before checking formatting. Corrected command `devenv shell -- env
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format
--check-formatted` passed (`9363`, exit 0). No dependency or lockfile edit occurred.

Fresh independent Astra SPEC review passed the actual two-file repair, separately
confirming the complete-file and protected-region hashes and reviewing the entire
diff. It is a source-only review; parent sessions provide execution evidence.
The original untracked C plan retains SHA-256
`350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.

Focused runner `69590`, exit 0, started and verified only the owned verification
cluster, provisioned roles there, and ran the entire Runtime file from the
implementation checkout with explicit owned PostgreSQL environment:

```sh
devenv shell -- env \
  MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  PGHOST=/run/user/1000/devenv-50f49bc/postgres PGPORT=5432 \
  mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs \
  --seed 1208
```

PASS: 127 reported tests, 43 excluded, **84 executed test cases, zero failures**,
554.1 seconds. Generated database `singularity_test_a7b05c78b9aa47b80b60226a`
and storage root `/tmp/singularity/integration/a7b05c78b9aa47b80b60226a` were
isolated to this run. The post-run owned-cluster database query returned no
`singularity_test_%` database; the cleanup trap stopped only the owned runtime.
Read-only inspection during a quiet interval showed idle PostgreSQL connections.
Astra source investigation explained the existing expiry contract: settling prior
attempts can wait almost 180 seconds, followed by another 180-second fresh-attempt
deadline, under the existing 420-second test timeout. No timeout, assertion,
deadline, or synchronization behavior was weakened or changed.

Distinct fresh Astra QUALITY review passed, independently repeating complete
AST/comment equality, protected-byte checks and exact file hash. It confirmed
the 554 counted assertion operators and four separately unchanged `flunk` calls.
SPEC and QUALITY are source-only reviews; parent sessions supply all test and
formatter execution evidence. Production Core/PDF/Poppler/guardian, restart test,
and V2 backup schema retain their previously recorded exact hashes; root `main`
remains clean at `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`.

This repairs the failed formatter and proves the affected focused contract only.
The entire selected non-E2E README gate must restart from its first command on
the clean committed repair source. E2E remains NOT RUN, full acceptance remains
open, and no merge, push, release, deployment, or Vault feature work occurred.

## Existing non-E2E README gate: attempt 2 and reader-observation repair

Formatter-only repair is committed locally at
`5a41faa6bf1d410bbfe72b5e585f39704674b2fc`. Only the authorized Runtime extraction
test and this matrix were committed. The original untracked C plan was preserved.
Parent fast-forwarded only the clean verification branch to this exact commit;
root `main` was not merged or changed. The entire selected README wrapper restarted
from service startup, with the same dedicated PostgreSQL identity and shared
source dependency path. This is not a continuation past the earlier failed gate.

Wrapper `24036`, exit 2: service startup/readiness, owned-cluster identity and role
bootstrap, locked dependency fetch, unused-dependency check, repository formatter,
and all seven applications' warnings-as-errors compile passed. Unit execution
seed was `247993`, maximum concurrent cases 96:

| Application | Reported result |
| --- | --- |
| Core | 10 properties, 113 tests, zero failures |
| Domains | 38 tests, zero failures |
| Storage | 928 tests, 667 excluded, zero failures |
| Retrieval | 26 tests, zero failures |
| Ingest | 62 tests, zero failures |
| Runtime | 793 tests, 205 excluded, **one failure** |
| Web | 183 tests, zero failures |

FAIL: Runtime `DocumentFreshDownloadLeaseTest`, generated case
`expire terminates the owned reader without late plaintext`, original line 322;
exact `:killed` monitor assertion at line 340 instead received `:noproc` for that
reader. The mailbox also contained the failed consumer result
`{:error, :waiting_for_unlock}` and normal lease termination. Runtime suite took
55.2 seconds. Test compilation emitted existing duplicate-definition warnings for
three Fake support modules; the application warnings-as-errors compile passed.
No unrelated support/legacy/Vault repair was attempted.

Acceptance stopped at this unit gate. Full integration, independent restore,
frontend gates, final xref/actionlint/clean gate were NOT RUN. E2E remains NOT RUN
separately by user exclusion. No integration database was allocated. After the
wrapper terminated, teardown was initially still visible. An additional
ownership-checked cleanup command returned exit 1 during this interval; its
output did not identify the failing precheck, so no precise failing precondition
is claimed. Subsequent read-only checks confirmed the owned manager, postmaster
and PostgreSQL socket were absent; the verification tree remained clean. The
borrowed cluster still accepted connections and was never a cleanup target.

Two read-only Astra investigations established the allowed Document-only scope
and observation-race mechanism. The approved source replay amendment explicitly
includes this test and requires reader kill/await and no late plaintext; the
legacy first module and production lifecycle remain frozen. Issuing the test's
monitor precedes explicit expiry in source, but does not acknowledge target-side
installation. A kill from the lease is a different-sender signal and can overtake
that monitor. The production spawn-time monitor still observes reader termination
and replies only after its own kill/await path completes. This failure is not
evidence that the reader remained alive or that plaintext was released.

Primary references: [OTP 28 monitor semantics](https://www.erlang.org/docs/28/apps/erts/erlang.html#monitor/2),
[ordered process information](https://www.erlang.org/docs/28/apps/erts/erlang.html#process_info/2),
and [OTP monitor signal implementation](https://github.com/erlang/otp/blob/OTP-28.0/erts/emulator/beam/erl_proc_sig_queue.c#L1027).
Monitor requests are asynchronous; the subsequent same-sender process-info request
acknowledges the reader's registered monitor before any termination trigger.

Pre-repair characterization `61299`, exit 0, ran the entire owning file with seed
247993: 33 tests, zero failures, 1.5 seconds. This does not erase the full-suite
RED result or establish a deterministic pre-fix scheduling reproducer; none is
claimed. Independent Astra scope review issued GO for only the new Document-mode
test's monitor-registration prerequisite, preserving every existing assertion,
timeout, termination case, ordinary Asset/request behavior, and production file.

Parent added only a comment and two assertions after `Process.monitor(reader)`:
`Process.info(reader, :monitored_by)` must return its observer list and that list
must contain the test process. All six termination cases retain exact `:killed`,
lease termination, dead-reader, attempted late release, and no successful plaintext
assertions. No sleep, retry, timeout change, weaker exit reason, module serialization,
fixture protocol, production code, migration, dependency or Vault behavior changed.

Focused verification on the guard candidate:

| Parent command/session | Result |
| --- | --- |
| Owning-file `mix test`, seed 247993, session `6367` | PASS: 33 tests, zero failures, 1.6 seconds |
| Owning-file `mix test`, seed 90731, session `62646` | PASS: 33 tests, zero failures, 1.6 seconds |
| Whole `mix format --check-formatted`, same wrapper `62646` | PASS, wrapper exit 0 |

Both Mix commands used `devenv shell -- env
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps`; no services were
started for these focused unit runs. Together they execute 66 test cases, not
66 file executions. The causal target-side monitor prerequisite supplies the
deterministic observation guarantee; repeated green runs alone are not that proof.

Parent Elixir byte proof, exit 0, removed the exact single added guard block in
memory and compared the result to `5a41faa`: **the complete original test file is
byte-identical**. Thus all old tests/assertions/comments, legacy module and later
Document original tests remain untouched. Hashes:

- Original whole test: `81096c858e57401943f583a4db239e439bffe488b6352cae1c92e9c55be3619c`.
- Guard candidate: `a9589b0e4f9054d4ebbecb2c3711c82a4f6807ce3dd2ee80761cca9969e354d0`.
- Legacy module prefix: `1091184685dd47ab99e54da5c0b7f2d0605f9b45c907ed4aa58b3f234595578c`.
- Later Document original tests: `f7df06f3f17dbe1d35cacb85993b4efa90632dcb424b9bd2e97a3072d4dbefaa`.
- Production DownloadLease, independently byte-compared to HEAD:
  `3ecce1470e11d506435d8213faa1b2c0c012ffb360cb3e4b82f67bdd5277636e`.

This is the first reader-observation repair attempt, with zero failed repaired
focused runs; no artificial failure or blind retry was introduced. The user's
allowance for at least three failed Astra repair attempts is retained if needed,
not a requirement to manufacture failures or waive an invariant. The full selected
README gate still requires a fresh restart on the clean committed candidate.

Fresh independent Astra SPEC and distinct QUALITY reviews passed the exact
four-line guard and matrix append, with no actionable findings. Both verified
the candidate/production hashes and preservation of the original assertions;
QUALITY also reviewed the narrowed cleanup-evidence wording. Reviews are read-only
source assessments, not independently executed tests or full-gate acceptance.
Parent read the complete final diff and `git diff --check` passed. Only the owning
Document lease test and this existing matrix are authorized for the local commit.
Task 15/Phase 2 remain open; no E2E, Vault feature work, product merge, push, tag,
release, deployment, or production activation occurred.
