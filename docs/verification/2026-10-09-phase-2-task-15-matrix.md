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
