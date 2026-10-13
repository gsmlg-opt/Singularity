# Phase 5 Task10: complete-README compatibility and fixture lifetime

Status: DESIGN REVIEWED — actual independent SPEC then NEW distinct fresh
QUALITY CLOSED PASS/noP0-P2. Reviewed pre-bookkeeping designc7aa51fd/plan14524ea3;
these status lines are parent bookkeeping, not retroactive review coverage.
Parent GO remains separately staged by the plan; this is not source acceptance.
Parent integration36198
naturally CLOSED FAIL/exit2 at2026-10-13 05:02:59UTC. Task10/Phase5 NOT ACCEPTED.
Continuous AGENTS authorization permits these necessary knowledge-test repairs,
not publication or relaxed assertions. Combined compatibility failedSol2 /
AstraRepair0; next implementation is bounded Astra recovery1. Read-only Sol/Astra
preparation adds0repairrounds; historical B/C Sol2/Astra1 stays separate.

Worktree: /home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup
Branch: codex/v0.2-phase-5-export-backup
HEAD: c98b4a6aad7516489b0615163340b225ea58a954
Governing Task10 unified-restore design/plan and Phase5 master remain authoritative.
This amendment supersedes their shared-fixture exclusion ONLY for the exact
test-support lifecycle changes below. All other scope/security/gates remain.

## 1. Actual evidence and goals

Full unfiltered command:
`devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration`
Seed681112; full archive .devenv/phase5-task10-compat-attempt2-readme-integration-native.log
SHA e526ad1ebae1b698b43b19fb22900a48d7eea6c6242d058aa5c7515a59346ff7.

Storage1904listed/370FAIL/446excluded/1458executed/3967.5s.
Runtime1396listed/369FAIL/1023excluded/373executed/675.6s.
Total1831executed/739FAIL. Other applications' cases all excluded, not SQL PASS.
Four reached stale Document SELECT assertions; one historical60s timeout;
seven Observer observer_invalid_target assertions; 725 already_started setup
failures; Runtime restart root mismatch and outcome-fence missing-process failure.
Do NOT change the latter Observer/Runtime assertions or declare their failures
mere noise. Their creator/causal chain remains unproven and requires full rerun.

Current8, frozen56, protectedA1current3, lockedREADME13 and four-entry permission
sources all unchanged; index empty. Main DB/root cleaned normally, but maintenance
inventory NOT EMPTY: singularity_test_a4770d1925efb9f4d84ab9ee, owner
singularity_migration; matching root and objects directories mode700 remain.
PostEOF exact DB activity has no backends. This cannot disprove an earlier stall.
Cleanup FAIL, not EMPTY. Full README stopped; remaining gates NOT RUN.

Required outcomes: synchronize obsolete read-denial contracts with accepted
00500 read grants while strengthening actual isolation/write-denial evidence;
preserve all seven historical rejection witnesses without raising timeouts;
close caller-kill fixture resource/configuration lifetime; whole gates/reviews.
Production behavior, frozen Vault/custody, defaultV2 and original assertions stay.

## 2. Exact source scope and ownership

Permission chunk, five files:
- test/singularity/storage/roles_test.exs: named Document pin-count/read case only.
- test/singularity/storage/postgres/document_projection_worker_test.exs:
  named worker-definer ACL case only.
- test/singularity/storage/postgres/search_projection_reconciler_test.exs:
  named worker read-maintenance/Document Note-write case only.
- test/singularity/storage/postgres/custody_repository_test.exs:
  named Document-pin case, knowledge permission metadata only.
- NEW test/support/worker_document_read_assertions.ex.

Lifetime chunk, five files:
- test/support/knowledge_backup_fixtures.ex: with_destination lifetime/Replay bracket.
- test/support/migration_test_environment.ex: narrowly owned lifecycle entry;
  existing ordinary open!/close!/with_database consumers unchanged.
- NEW test/support/knowledge_fixture_resource_owner.ex.
- NEW test/singularity/storage/backup/knowledge_fixture_lifecycle_test.exs.
- test/singularity/storage/backup/knowledge_historical_admission_test.exs:
  split only original409-468 seven-scenario case.

All paths under apps/singularity_storage. Parent owns this design/plan and
Task10/master/acceptance bookkeeping. Two disjoint Astra chunks may author
in parallel after both actual design reviews PASS; no author runs native/Mix/
formatter/SQL/service/Git mutation. All authors close before parent commands.

Keep unchanged: pending Task10source8; protected3; released43migrations/frozen13;
Fixtures.with_owner, KnowledgeFixtures, DataCase, production TestEnvironment,
Preflight, Replay, custody/Vault/lease/key/capability code; Observer/Runtime tests;
all other permission/historical cases/helpers except new helper integration.
No role/grant/schema/dependency/workflow change. No new production process/API.

## 3. Fixed four-consumer worker read contract

Use one test-only WorkerDocumentReadAssertions.assert_read_only_rls!/0.
Zero arguments/fixed expectations prevent weakening by consumers; four consumers
justify one shared helper, not four260-line duplicates or a generic framework.
Create separate own/foreign KnowledgeFixtures metadata and ready Documents/
fragments; retire both on_exit. Never reuse or revoke custody/projection fixtures.

Independent expected16Document/9Fragment fields: exact immutable version/Resource/
owner/creator/source Asset/Resource/version/object pins; private; source
SHA256("source bytes"), size12, text/plain, Document, ready, en; fragmentordinal0,
literal text "text", digest982d9e3eb996f559e633f4d194def3761d909f5a3b647d1a851fead67c32c9d1,
literal native locator version1/kindtext/start_line1/end_line1. Do not derive
expected semantic rows from owner SELECT. Query both known version IDs, ordered.
Separately SELECT* complete own+foreign Document/fragment snapshots include
all lifecycle and timestamp fields and remain identical after every probe.

One WorkerRepo.checkout captures backend and current_user singularity_worker;
native operations retain that backend. Require:
- no scope: both known rows invisible;
- own principal+owner: exact own rows; foreign principal+owner: exact foreign rows;
- both mismatched principal/owner directions: both invisible;
- independently missing principal and owner GUC: both invisible;
- revoked own membership: own hidden, foreign positive witness retained.
Missing GUC probes clear each transaction-local setting inside real ScopedRepo
transaction; nil UUID would be rejected before native SQL and is not RLS proof.

Both tables: effective read web+worker/notpreauth+dispatcher/noPUBLIC; tableSELECT
and supported columnSELECT for every explicitly projected field; no table
INSERT/UPDATE/DELETE/TRUNCATE or any-column INSERT/UPDATE; ENABLE and FORCE RLS.
Column DELETE/TRUNCATE vocabulary is invalid and must not be used.

In eight independent scoped transactions, execute real INSERT INTO table SELECT*
WHERE resource_version_id=$1, UPDATE classification='private', DELETE by known
version, and TRUNCATE. Require Postgrex insufficient_privilege plus SQLSTATE42501.
Unexpected success rolls back BEFORE failure assertion. After each statement:
full own+foreign snapshots unchanged, same backend/role, no transaction, both
GUC absent(nil/empty), direct unscoped known rows invisible. Same cleanup after
normal reads, explicit rollback and membership denial. Catalog flags alone
cannot replace actual native denial or positive/negative rows.

Consumers preserve function signature/owner/security/searchpath/volatility/
EXECUTE/PUBLIC/private-builder/search-entry contracts. Only two Document SELECT
expectations become allowed. Search reconciler retains read-maintenance42501,
Note-write Document[-1], search-entry42501, final empty projection and
unchanged assert_denied. Custody changes only title, old92-98 direct-read denial,
one workerDocSELECT Boolean(entry110), and call to isolated helper. Its catalog
SQL remains exact. Preserve entry setup23-90 SHA
388d0f8ab3c2cdefadb41c3ea6bc136fec7d85e12df4efb77a0fe745de5d758a and entire
binding/material/checkpoint/lifecycle/substitution/epoch/revocation137-276 SHA
2110a5b4d9c004fda694270dda91002052f74481654a595ab7e29d0bdb891e83,
all existing custody helpers/other cases. Inverse permitted consumer edits must
reproduce entry copies. This is knowledge permission compatibility only;
membership/GUC isolation does NOT prove or replace session/capability/epoch/
generation/object availability/custody material authorization.

## 4. Surviving fixture owner, fixed lifecycle

Actual Astra PROJECT_ARCHITECTURE .devenv/phase5-task10-fixture-lifetime-astra-architecture-actual.md
SHA57258bd94dc615d6f7c8f35ce24b88faee5483a028ba8fd592259995f0fad275
supports one unlinked unnamed fixture-specific owner plus before-acquisition
ExUnit cleanup fence. No generic registry/ETS/resource-manager/concurrency API.

Start owner monitoring original caller, initially unarmed. In registered
test/setup_all context (public ExUnit.fetch_test_supervisor), register unique
on_exit callback BEFORE arming/allocation. Registration failure closes unarmed
owner. Caller death before arm leaves no allocations/owner leak. Non-ExUnit
uses monitor/bracket without mandatory ExUnit; existing seven-state oracle stays.

Owner serially captures full storage/runtime/Repo configs including absent keys,
compiler options, exact baseline Repo PIDs and Runtime initial identity/running
state. Preserve intentional baseline pause addressing captured PIDs; never adopt
unexpected replacements. Capture unnamed maintenance connection config before
global changes. Fixed staged acquisition uses exception-safe brackets and
explicit successful resource outcomes, not a pluggable ledger framework.

TestEnvironment.allocate is pure names. Validate exact generated name/root;
successful CREATE establishes DB ownership; duplicate failure forbids DROP.
Ambiguous connection-loss CREATE remains cleanup FAIL unless ownership proven.
Refuse preexisting generated root; only successfully claimed root is removable.
Record every acquired maintenance/migration/runtime/final Repo PID immediately.
Owner must survive known linked child failures during acquisition (trap and
handle known exits or equivalent). Caller DOWN cannot race an in-flight
migration/bootstrap command: settle current stage, then unwind; check caller
liveness between stages. Do not kill unrelated command/session/process.

Return unchanged %{repo: MigrationRepo,database: database,object_root: root}.
Callback, native transactions/authentication, Replay/raw descriptors and caller
process dictionary STAY ORIGINAL CALLER. Preflight self/backend/transaction
binding preserved. Caller owns Replay discard/consumption/previous-dictionary
restoration; descriptor transfer or copying authority to owner forbidden.

Normal return/raise/throw/exit synchronously releases; Replay discard failure
cannot bypass owner release. Caller DOWN triggers same cleanup. ExUnit on_exit
waits exact owner and raises on failure. Registered mode retains minimal closed
result until callback acknowledgment; repeated release performs no repeated
restoration. setup_all ordinary release occurs immediately, not module end.
Non-ExUnit normal/error release stops owner after cleanup; caller-death owner
exits after cleanup and failures remain observable.

Stop/await ONLY acquired PIDs. Unknown replacement named PID survives and yields
cleanup FAIL; no global-name fallback. Ordinary drain/DROP ONLY owned DB through
unnamed maintenance connection, no FORCE/broad session kill. Remove only claimed
validated root. Attempt independent remaining cleanup/config restoration after
failure and aggregate failures. Restore complete config/compiler snapshots
BEFORE baseline services restart; manually restarted baseline Repos detach from
temporary owner and must survive its exit. Preserve initial absent/stopped states.

Do not increase ExUnit60s/on_exit/query timeouts. No forecast that an external
stall always cleans within60s: timeout remains FAIL and still-live owner accounted
for before next native. Existing serial fixture assumption remains; no concurrent
destination fixtures promised. Production/Vault/custody/Replay code unchanged.

## 5. TDD, seven rejection witnesses and exact recovery

Existing four reached assertions provide permission RED. Add a causal native
lifecycle regression FIRST against unchanged with_destination: isolated test-owned
actor reaches real callback, reports exact destination/PIDs, then parent kills
ONLY that acknowledged actor. Bound observation of owned PID/DB/root cleanup;
legacy surviving Repo/root/DB must produce actual causal FAIL, not missing
future module/API or compile failure. Report allocated identities in assertion
evidence so parent can recover EXACT run-owned resources after native closure.
No intentionally timed-out containing ExUnit test; no weaker/assertion-only mock.
Close author, parent compile/whole initial lifecycle owner RED, archive all output
and exact run-owned leftovers; parent reviewed normal recovery before next native.

Then implement fixed owner and remaining deterministic real-stage regressions:
before arm/effect, actual DB/root creation, real in-flight acquisition versus
pre-call barrier, partial Repo start, callback kill/acquire exception, normal/
raise/throw/exit, repeatedrelease/on_exit, non-ExUnit. Preserve callbackself and
native backend/xact staging+validation; caller Replay discard and raw-descriptor
owner-death evidence. Require exact PIDs DOWN/DB+root absent/fullconfigs/compiler/
baseline restored and surviving owner exit. Keep independent DB/unnamedconnection/
root sentinel/unrelated process unchanged. Unknown named replacement preserved
with explicit cleanup FAIL. Hooks only around actual test-support stages.

Split original historical case into six separately generated scalar tests:
source_object_id999, source_asset_id998, source_resource_id997,
source_resource_version_id996, vault_id995, source_byte_size PDF+1;
one separate ambiguous Asset994/duplicate association test. Keep every exact
source, open_admission, insertion, document_versions_source_check/check_violation,
phase/callback-not-returned/no-import/auth/cleanup assertion. Default60s unchanged.
Splitting addresses cumulative setup/digest cost, not claimed query-stall proof.
Do not cache/omit required38table digests or change production admission.

Before next native, parent may recover the one exact run-owned orphan after
verifying task-owned PostgreSQL data_directory against current wrapper, no
active backends, prior-empty inventory and matching recorded test root. Keep
original FAIL/cleanupFAIL records; use ordinary exact DROP, no FORCE; move exact
orphan root into ignored forensic directory rather than delete original bytes.
No broad roots/databases or existing user data. Recovery does not relabel cleanup.

## 6. Qualification and preserved gates

After all authors/commands close, root alone formats owned files, compiles WAE,
seals exact source diffs/hashes and checks current8/frozen56/protected3/locked13.
Whole new lifecycle and four permission owners, whole historical owner and every
KnowledgeBackupFixtures consumer required; existing seven-state characterization
and retained TaskH/Runtime2/Base/Task9/Task8 pure+SQL/static gates unchanged.
Run full unfiltered README integration on clean isolated environment, preserving
739 original failures. All Observer/Runtime cases/assertions must actually pass,
not excluded, skipped, weakened or declared cascade-only. Any remaining genuine
failure enters bounded diagnosis/amended review/Astra attempts (at least3 if
needed), not another silent Sol repair or routine approve request.

After all native gates and complete permitted README checks, actual SOURCE SPEC
then NEW distinct fresh SOURCE QUALITY on combined actual source/docs. Small
exact-path local commits only after reviews; full README end Git status literally
clean required, not waived by dirty documentation. Tested sources must match
commit exactly; preserve unrelated work. Task10/Phase5 acceptance remains withheld
until every required gate/review/cleanup closes.

E2E manual-only/NOT RUN/deferred, no final browser/release acceptance. DefaultV2,
unsupported-canonical activation guard and Task16 strict lease promises unwaived.
No merge/push/version/tag/release/deploy/production activation/backfill.
