# Phase 3 unified lexical search qualification

## Current status

**IN PROGRESS — Phase 3 is not accepted.**

Current source: `996fdbea5284fdbd6cd12c7fd3df9ba60d861596` on
`codex/v0.2-phase-3-search-design`, in the project-local Phase 3 worktree.
The approved implementation is locally complete through Task 10. Task 11's
privacy and actual-call cold/warm selective query-plan contracts pass locally.
The guarded-index repair's scoped gates and independent complete-candidate
SPEC and separate QUALITY source reviews pass. Complete affected-suite checks
and exact-clean-SHA README acceptance remain outstanding; these scoped results
do not accept Phase 3.

The bounded Astra diagnosis is complete. The user's 2026-10-10
[continuous development authorization](../../AGENTS.md#continuous-development-authorization--2026-10-10)
removes the former routine approval blocker. The repair proceeded through a
documented architecture amendment, detailed plan, new forward migration,
verification, and independent review. Original failed index qualification
`69774` remains historical evidence; actual executed-plan owning gate `54358`
and combined search regression `14560` subsequently passed without weakening
the required assertions.

The user restriction on E2E remains in force: browser tests are **NOT RUN** in
this qualification. This cannot be represented as a complete README gate or
full phase acceptance. No Phase 4, production activation, production backfill,
merge, push, tag, release, or deployment is authorized by this report.

Governing [design](../superpowers/specs/2026-10-09-singularity-v0.2-phase-3-unified-lexical-search-design.md)
and [execution plan](../superpowers/plans/2026-10-09-singularity-v0.2-phase-3-unified-lexical-search.md)
retain the source-level RED/GREEN evidence, approvals, and scope boundaries.

## Continuous-authorization governance qualification, 2026-10-10

The user explicitly authorized recommended in-scope design, planning,
implementation, necessary compatibility/test-contract repairs, documentation,
tests, independent review, local commits, and next-phase progression after the
required gates. `AGENTS.md`, README, guide, master release design/plan, and the
active Phase 3 design/plan now distinguish that authority from preserved Vault,
E2E, publication/deployment, and production-data restrictions. This does not
authorize Phase 4 before Phase 3 acceptance or waive the failed index gate.

The two existing architecture suites initially failed five of 29 cases against
the new policy (`55692`, exit 2, seed `215378`, 2.7 seconds): their stale routine
approval clauses and old governing-list section boundary contradicted the new
authorization. The test update changes those governance expectations only,
retains historical exact-list/protocol checks and negative cases, and adds a
complete authorization contract with permission-removal and permission-expansion
negative controls. Runtime byte hashes, registration guards, Vault locks, and
production activation prerequisites are unchanged.

The updated suites passed **31 tests, zero failures** (`39447`, exit 0, seed
`215378`, 2.1 seconds). Formatting, warnings-as-errors compilation, and zero-cycle
xref passed (`77374`, exit 0). All 42 local Markdown link targets across the
eight governing/evidence documents resolved (`0d7a33`, exit 0). Exact commands:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 215378
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs, test apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 215378
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
git diff --check
```

Independent specification review passed for the policy and test changes.
Independent quality review and final evidence closure passed before the local
governance commit, with no Critical or Important findings.
No production source, migration, Vault semantics, or release state changed in
this governance slice; E2E was NOT RUN. Existing Task 11 privacy and query-plan
files remain separate from the governance commit and retain their frozen hashes.

## Accepted local prerequisites

- Task 8 authenticated search and exact-source API: `c6bd440000916f444b1ae78ae1be621e0e0c5502`.
- Bounded owned-database cleanup checkpoint repair: `294958c35a481baf0b670803e9bfe9e3f157c573`.
- Task 9 deterministic canonical rebuild: `ab212109cf876b29e017f595c3bc5b6160d83550`.
- Task 10 minimal V1/V2 restore compatibility: `c9a7b7937fb55378f8d655fc0bb638b952e6a99f`.
- Recorded scoped evidence and mandatory operator backfill instruction: `191e58691eac2413fec3b0b302397775fe527aff`.

The two frozen-substrate compatibility files are `backup/restorer.ex` (derived
search inventory only) and `backup/integrity_audit.ex` (restore-owned canonical
Note projection rebuild and exact identity verification only). Existing
Asset/Note evidence, V1/V2 wire schemas, keys, custody, and Vault semantics are
unchanged. No released migration was edited.

## Task 11 baseline, 2026-10-10

Session `92363`, exit 0, seed `215378`: **337 executed unit/property cases**,
zero failures, across the 49 changed or directly affected owning test files.
Integration exclusions are not counted as executed. Core: 39 tests plus two
properties (0.9 s); Storage: 64 executed, 343 excluded (17.2 s); Retrieval:
39 executed (0.7 s); Runtime: 149 executed, 145 excluded (40.8 s); Web:
44 executed (2.2 s). This baseline does not include the new Task 11 contracts.

Exact command:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_core/test/singularity/core/job_envelope_test.exs apps/singularity_core/test/singularity/core/knowledge_link_values_test.exs apps/singularity_core/test/singularity/core/search_policy_test.exs apps/singularity_core/test/singularity/core/search_source_test.exs apps/singularity_core/test/singularity/core/source_locator_test.exs apps/singularity_retrieval/test/singularity/retrieval/knowledge_search_test.exs apps/singularity_retrieval/test/singularity/retrieval/note_lexical_search_test.exs apps/singularity_runtime/test/singularity/runtime/api_test.exs apps/singularity_runtime/test/singularity/runtime/asset_search_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_document_projection_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_note_projection_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs apps/singularity_runtime/test/singularity/runtime/search_rebuild_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/configuration_test.exs apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/migrations_test.exs apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_projection_events_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_projection_worker_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_cursor_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/outbox_test.exs apps/singularity_storage/test/singularity/storage/postgres/search_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/roles_test.exs apps/singularity_storage/test/singularity/storage/search_extension_bootstrap_test.exs apps/singularity_storage/test/singularity/storage/search_projection_schema_test.exs apps/singularity_storage/test/singularity/storage/test_environment_test.exs apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --seed 215378
```

The parent serializes all Mix, database, formatter, and Git execution.
Implementation workers own only their separately assigned Task 11 test files.
Database checks use the existing private Unix socket and verified owned PGDATA;
no borrowed service or TCP-listening PostgreSQL instance is used.

## Outstanding qualification

The first plan-test attempt (`29095`, exit 2, seed `215378`) invalidated all
four tests during setup: rebuilding 8,192 fixture projections exceeded the
existing 15-second outer owner-transaction checkout, despite a longer inner
query timeout. No query-plan assertion executed, so this is not evidence of a
search/index failure. Fixture repair round 1 preserves every row and assertion
and partitions construction into 16 existing owner transactions of 512 IDs,
with a separate final ANALYZE/count check; shared/runtime timeouts are unchanged.
Revalidation `19792` (exit 2, seed `215378`, 28.5 seconds) completed that setup,
but all four tests failed at the next test-harness step: the current connection
had no matching retained row in `pg_prepared_statements` after a successful
store search. Thus no EXPLAIN/index assertion ran. Fixture repair 2 captures the
actual `SafeSQL.query/4` call and its exact parameters using a process-specific
trace, a delivery barrier, and unconditional trace/collector cleanup. The
locked Postgrex path uses an unnamed statement unless `cache_statement` is
supplied; no production prepare configuration was changed.

Revalidation `69774` (exit 2, seed `215378`, 39.6 seconds) executed all four
contracts: **two passed and two failed**. Actual result identity/rank and
EXPLAIN row-count controls passed for both selective searches, but neither
plan used its required content index (`search_entries_fts` or
`search_entries_title_trigram`). Both plans used only identity/join indexes:
`resource_versions_pkey`, `search_entries_note_resource`, `resource_tags_pkey`,
`tags_id_vault_key`, `note_versions_identity_aggregate_key`,
`document_versions_receipt_identity_key`, and `document_fragments_pkey`.
The one-/two-character cases each inspected all 8,192 entries through an index
scan. The observed relation-lock barrier, fixed five-second cancellation,
sanitized retryable error, restored connection settings/scope, and successful
retry passed. This initially established an unmet query-plan qualification
requirement, not its root cause. All planner, role, RLS, and index assertions remain
unchanged; production code was frozen at that diagnostic boundary. The later
continuous authorization permits the documented repair process, not an assertion
waiver.

An independent read-only specification review found the query-plan contracts
aligned with the approved design, but correctly withheld qualification PASS
because of the two executed index failures. The requested Astra recovery
spawn failed with `agent thread limit reached`. After both retained Sol workers
finished, one dispatch retry succeeded: Astra completed bounded read-only
diagnosis under `SOL_IMPASSE`. This is advisory attempt 1; cumulative Astra
repair attempts at that handoff were zero. Production implementation was not
authorized by that diagnostic handoff alone; the later continuous authorization
supersedes its routine approval wait. No Sol production repair or assertion waiver
substitutes for the failed gate.

Initial privacy validation `74303` (exit 2, seed `215378`, 11.7 seconds)
executed eight contracts: **five passed and three failed**. Two failures were
at the blanket no-query-telemetry assertion after the content-canary checks
passed: existing fixture `SET LOCAL ROLE` and Oban queue-only `pg_notify`
events were captured. The durable job's rollback, sanitized persisted error,
retry, and real projection completion assertions had passed before that
diagnostic assertion. The third failure expected `:forbidden` after membership
revocation but received sanitized retryable `:storage_unavailable`; its cause
is under diagnosis, not waived. The actual SQL-timeout/privacy/retry contract
passed. These results do not establish a complete privacy PASS.

Exact owning commands:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_search_privacy_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs --seed 215378
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_runtime/test/singularity/runtime/knowledge_search_privacy_test.exs --seed 215378
```

Formatting exited 0 (`359b1b`). Both integration harnesses stopped their owned
PostgreSQL instance after terminal results. The subsequent read-only cleanup
inventory (`11934`, exit 0) verified zero generated test databases, absence of
all recorded temporary storage roots, and owned PostgreSQL shutdown.

Independent privacy specification review classified the three failures as
two test-contract issues, with no evidenced new production privacy defect:
the all-query-events prohibition exceeded the content-privacy contract, and
membership-revocation audit failure precedence was already characterized by
the accepted Task 8 API suite. A bounded test-only repair retains all six
canary checks, permits only the two observed exact content-free control-event
shapes, and separates capability-revoked `:forbidden` with successful audit
from membership-revoked retryable `:storage_unavailable` with failed audit.
The independent quality review additionally identified consumed telemetry
events that bypassed the later canary scan. Repair 1 binds and scans each full
consumed RLS/retry/Oban event, retaining the bounded supported-event assertions.
Repair validation (`29035`) ran on formatted privacy-file SHA-256
`a9df43e4182e18d74ef4afcaf7800e762b75a0d170611e62b4fd25a3a816e100`;
no production authorization or audit path is changed to satisfy the new test.
It exited 2 (seed `215378`, 13.8 seconds): seven passed, one failed. All new
capability/membership denial, exact audit-row, and callback-exclusion assertions
passed; the remaining failure was the shared test fixture's raw membership
UPDATE telemetry, not a canary leak. Independent specification and quality
closure reviews passed on those exact bytes, without claiming an executed PASS.

The original author could not be resumed after the successful Astra dispatch
(`agent thread limit reached`), so the parent applied fixture repair 2: perform
the identical live membership UPDATE through the test's existing `owner_query`
and `SafeSQL` helper, asserting exactly one affected row. Shared fixtures,
production code, and the two-shape telemetry allowlist are unchanged. No
required assertion was removed or weakened.

Final owning privacy validation `75124` exited 0 (seed `215378`, 14.2 seconds):
**eight integration contracts passed, zero failures**. This includes actual
authorization, content-bearing DTOs only, malformed input, synthetic adapter
errors/exceptions, real SQL cancellation and retry, exact-source denial,
rebuild rollback, and acknowledged durable worker retry/completion. Independent
specification and quality closure reviews passed on the exact formatted file
SHA-256 `17e6eeebdef3314b328b600e02110c840a64ebffc3727162e928dcd957d01056`.
The command is the same privacy owning command above. The owned PostgreSQL
instance stopped normally. This resolves the privacy test gate only; the
selective-index gate remains failed.

## Astra query-plan diagnosis and design boundary

The parent ran two causal diagnostics on fresh copies of the same 8,192-row
canonical fixture. Both retained the original failing selective assertions.
Session `93912` exited 2 (seed `215378`, 29.7 seconds): two selective tests
executed and failed, two unrelated cases excluded by the line filter. Session
`11736` exited 2 (same seed, 32.5 seconds) with the same executed/excluded counts.
The role-control observations are diagnostic evidence, not successful
production-role qualification.

| Isolated selective predicate | Actual web role | Existing table-owner control |
| --- | --- | --- |
| FTS, both sessions | Sequential scan: one match, 8,191 rows rejected | `search_entries_fts` bitmap index scan, one match |
| Title trigram, `93912` | Sequential scan: one match, 8,191 rows rejected | Sequential scan: one match, 8,191 rows rejected |
| Title trigram, `11736` | Sequential scan: one match, 8,191 rows rejected | `search_entries_title_trigram` bitmap index scan, one match |

Both roles had `row_security=on`, `enable_seqscan=on`, `statement_timeout=5s`,
and similarity threshold `0.3`. Catalog reads confirmed enabled/forced RLS,
all seven indexes valid and ready, and `proleakproof=false` for
`ts_match_vq(tsvector,tsquery)`, `texticlike(text,text)`, and
`search_extensions.similarity_op(text,text)`. Removing joins, OR branches,
ranking, and cursors therefore did not remove the web-role index restriction.
The complete Store query still performed 8,192 identity-index probes and failed
both required content-index assertions.

In `11736`, the owner trigram index was already selected **before** an explicit
test-owned `gin_clean_pending_list` call, which returned zero. The subsequent
role comparison was unchanged. The earlier owner-trigram plan variation remains
unexplained; no pending-list cause or maintenance fix is claimed. This was
maintenance of only the disposable fixture's existing index, using its existing
owner permission, with no logical content, schema, grant, policy, or planner
change. PostgreSQL documents this function as moving pending entries into the
main GIN index structure: [index maintenance](https://www.postgresql.org/docs/17/functions-admin.html#FUNCTIONS-ADMIN-INDEX).

The diagnosis combines the executed role contrasts with PostgreSQL's documented
security ordering and optimizer source: the nontrivial web RLS restriction
precedes non-leakproof content predicates, which are rejected as index
conditions before operator-family matching. This is expected PostgreSQL
behavior, not an absent or invalid index. See
[row-security ordering](https://www.postgresql.org/docs/17/ddl-rowsecurity.html),
[index-condition qualification](https://raw.githubusercontent.com/postgres/postgres/REL_17_STABLE/src/backend/optimizer/path/indxpath.c),
and [security promotion rules](https://raw.githubusercontent.com/postgres/postgres/REL_17_STABLE/src/backend/optimizer/util/restrictinfo.c).

Exact parent diagnostic invocation, run twice with temporary diagnostic-only
instrumentation attached to the two existing selective cases:

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs:27 --seed 215378
```

The instrumentation used each role's existing fixture transaction, verified
the settings/catalog facts above, and explained these exact statements with
the fixture owner and synthetic query bound as parameters:

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT entry_id FROM content.search_entries
WHERE vault_id=$1 AND classification='private' AND kind='note'
  AND search_vector @@ plainto_tsquery('simple',$2);
-- $2 = 'needle bridge'

EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT entry_id FROM content.search_entries
WHERE vault_id=$1 AND classification='private' AND kind='note'
  AND title OPERATOR(search_extensions.%) $2;
-- $2 = 'postgreql'

-- Second diagnostic only, existing fixture table owner; result: 0.
SELECT pg_catalog.gin_clean_pending_list(
  'content.search_entries_title_trigram'::regclass
);
```

All temporary instrumentation was removed. The original plan-test SHA-256 was
restored exactly:
`01b20aca6afb66f65e0e62f17cbc083e5753603b446e62412dae0fb0595da570`.
All four original contracts and the fixture population remain unchanged.

### Diagnosis recommendation — repair now authorized for design and verification

Astra recommends a narrow read-only candidate-identity function with explicitly
reviewed definer authority. It would derive owner/principal only from existing
scoped context, validate existing authority and bounded inputs, execute fixed
schema-qualified SQL, and return identities only. Existing web-RLS canonical
joins, current-head/readiness/tombstone checks, tags, ranking, complete candidate
membership, cursors, final content reads, and Runtime authorization must remain
intact. No caller-selected owner/role/classification, arbitrary candidate cap,
content-bearing diagnostics, or new custody behavior is acceptable.

This changes a database privilege boundary: it requires a documented and
independently reviewed design and **new forward migration**, with explicit intended-web-role EXECUTE
and PUBLIC/other-runtime-role denial. Do not alter released migrations, RLS
policies, leakproof flags, role memberships, Vault semantics, or backup
compatibility. Adding more indexes or splitting predicates is not a repair for
the demonstrated security ordering.

The amendment must first specify how the actual web-originating call will prove
executed **inner** content-index use. An outer `Function Scan` is not such proof.
It must also preserve strict authorization/ACL negative cases, complete ranking
and pagination, fixed sanitized timeout behavior, privacy, canonical source
visibility, restore compatibility, and the original failed-gate history.
At diagnosis completion no proposed function, migration, privilege change, or
production repair had been implemented. Astra repair attempts: **0**; completed
advisory attempts: **1**. The later continuous authorization permits the bounded
repair process; it does not turn this proposal or the failed gate into acceptance.

### Reviewed repair architecture, 2026-10-10

Astra completed the bounded [guarded search-index design](../superpowers/specs/2026-10-10-singularity-v0.2-phase-3-search-index-repair-design.md)
under `PROJECT_ARCHITECTURE`, after governance commit
`799e36308660f9b6b9fc8ade7d4261b264d995a7`. Its self-reviewed document hash is
`9ddbe4f8effd1ad20a216dcb3e3528d9115a39cdbbe48a37d623638c28f7486a`.
Independent Sol specification review passed that exact document against the
existing Store, authorization guards, and failed-plan evidence.

The design keeps candidate authority read-only and ID-only, preserves outer
web-RLS content/rank/cursor/timeout checks, and leaves empty queries unchanged.
It explicitly records VOLATILE authorization freshness and conservative
concurrent snapshot visibility. Actual nested execution must be captured only
on an owned synthetic database's dedicated web-login connection, using
`auto_explain` NOTICE messages without server plan logging. Feasibility, cleanup,
five-second overhead, selective cold/warm plans, and regressions remain unproven.
The locked PostgreSQL 17.10 installation contains `lib/auto_explain.so`; an
initial environment probe could not use `pg_config` because that utility was
not in PATH, and did not establish a missing-module failure.

No production code, migration, role grant, or database observation setting has
changed at this architecture handoff. Astra repair attempts remain **0**;
completed diagnosis attempts **1**, completed architecture-design handoffs **1**.
The parent will execute the observer prerequisite before the production repair.

After linking the amendment, the same two architecture suites passed again
(`43703`, exit 0, seed `215378`, **31 tests, zero failures**, 2.4 seconds), using
the focused command recorded in the governance section. All 16 local links in
the four changed architecture/evidence documents resolved (`00b79f`, exit 0),
and `git diff --check` passed. This verifies documentation consistency, not the
proposed observer or candidate function.

### Observer prerequisite: initial execution and diagnosis, 2026-10-10

The [observer prerequisite plan](../superpowers/plans/2026-10-10-singularity-v0.2-phase-3-search-plan-observer.md)
was authored by Sol and independently reviewed by the parent. Revision
`dc7e982cbf7c7416ef5209cc191383032359c17d95f07775cc2ce42d0847197d`
removes a machine-specific cluster path and makes pre-reset versus callback
cleanup ownership explicit. The ignored parent harness supplies the verified
private cluster identity through `SINGULARITY_TEST_OBSERVER_PGDATA`; committed
tests do not start or stop PostgreSQL.

TDD and first implementation evidence, seed `215378`:

- `20136`, exit 2: one pure test, one intended missing-helper failure.
- `38001`, exit 0: one pure target-validation test passes.
- `10511`, exit 2: five integration cases fail as expected for missing
  lifecycle, cleanup, and proof implementation; one pure case excluded.
- `8635`, exit 2: first full helper implementation still fails all five
  integration cases; one pure case excluded. This is not qualification.
- `91063` and `19744`, exit 2: one focused lifecycle case fails, five excluded.
  Closed diagnostic counters locate PostgreSQL `insufficient_privilege` while
  the real Web connection reads preload settings, before installing defaults.
- `41266`, exit 0: one pure case passes, five integration cases excluded.

Exact owning commands (the diagnostic commands used the same integration
command with the owning file suffixed `:27`):

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs --seed 215378
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs --seed 215378
```

PostgreSQL 17 marks `session_preload_libraries` and
`shared_preload_libraries` as `GUC_SUPERUSER_ONLY`; a real least-privilege Web
login cannot perform the plan's proposed direct reads. This is expected
PostgreSQL behavior, not an internal dependency defect. Astra received the
evidenced architecture correction under `PROJECT_ARCHITECTURE`, without new
grants or production changes. At this checkpoint no repair round had run.

Independent SPEC review also requires rejecting unlisted `auto_explain.*`
catalog settings and permitting unchanged compatible inherited logging defaults
in the cleanup predicate. The reviewed helper hash was
`513cf6ecb75eda5d6312bee8972d447cc1ea08d944a70e55e55ae2672e14c383`,
test hash `2512c06381f69c84e1cc31e3e4a11b190eadf5250f25f51b7270b0ae026e6836`.
Temporary diagnostic output contained only closed error categories, exception
classes, and helper line numbers; it was removed, restoring the exact helper
hash. No raw plans, SQL, connection options, or credentials were emitted.

The parent cleanup inventory `53683`, exit 0, verified zero generated test
databases, absent recorded storage roots for all four new allocations, and
stopped its owned server. Original Task 11 privacy/plan test hashes and the
legacy Note concurrency-test hash remain unchanged. Observer delivery and
actual nested analysis are still **NOT PROVEN**; the original two selective
index failures remain **FAIL**. No E2E, publication, or deployment occurred.

The subsequent no-grant architecture correction is now recorded in the design.
It moves only hidden preload inspection to administrator configuration-provenance
checks, preserves every readable real-role check and actual nested-plan proof,
and adds startup-override rejection plus fresh ordinary-backend negative controls.
The amended observer plan adds the two independent fixed conflict fixtures and
allocated-database-only compatible logging fixture without a settings injection
API. Startup rejection first failed as intended in `13430` (one pure failure,
five excluded), then passed in `32327` (one pure pass, five excluded).

Repair run `96674`, exit 2, still failed three of five integration cases (one
pure case excluded). Early-fault cleanup and the two conflict branches passed.
The run also exposed a separate helper defect: raw Postgrex `log: false` is
treated as a callback by locked DBConnection 2.10.2, whose callback failure
logged synthetic administrator SQL/results. No authorization plan, user content,
or credentials were present, but diagnostic confinement did fail. Raw Postgrex
logging was corrected to `nil`/omission; production Ecto SafeSQL is unchanged.
The test now checks an empty captured log through a closed boolean, so an
assertion failure cannot itself print captured diagnostics.

The second repair/probe `41720`, exit 2, ran the actual-proof case at `:73` and
still failed (five other cases excluded). Content-free instrumentation identifies
the `auto_explain.log_min_duration` readiness comparison, not a successful
nested-plan observation. After these two distinct repair-and-validation rounds,
the parent handed the same two test files to Astra under `SOL_REPEATED_FAILURE`,
mode `implementation`. Astra starts implementation repair round 1; its prior
diagnosis/design handoffs do not count as repairs. At least three bounded Astra
attempts remain permitted if needed. No production function, grant, migration,
or original index assertion has changed.

Astra's first content-free diagnostic `87856`, exit 2 (one owning case failed,
five excluded), reported `log_min_duration` missing and no registered
auto_explain settings. Inspection of the locked Ecto SQL/Repo registry showed
the routing mismatch: raw SQL with a module atom used its registered shared pool,
while generated Repo transaction methods honored dynamic selection. The original
dynamic observer therefore did not route those calls to the same connection.
This is expected adapter API behavior, not a dependency bug.

The revised design uses a fixed private **real** Ecto.Repo initialized from
validated RequestRepo options. Its module is passed explicitly through unchanged
production ScopedRepo/SafeSQL/Store functions; ordinary negative controls pass
their freshly allocated connection PID explicitly. Shared RequestRepo and its
dynamic state remain untouched. Independent Sol SPEC review passed exact design
hash `abf390ced68bd2d3a5604a139da8c58d1ef05d6aaec5b22abd5ecb067cfb9d06`.
Additional startup-negative assertions first failed as intended in `97981`
(exit 2, one pure failure, five excluded). These probes do not consume an Astra
implementation repair round; the first bounded implementation is in progress.

### Observer prerequisite: Astra repair qualification

Astra implementation round 1 used the fixed named real Repo and explicit
Repo/PID routing. Session `64238`, exit 0, formatted both files and passed
one pure case (five integration cases excluded). Full integration `95857`,
exit 2, passed four cases but failed the actual-proof case with closed
`:observer_evidence_missing`; one pure case was excluded. Lifecycle, inherited
logging, collision ownership, fault cleanup, and diagnostic confinement passed.
This was a failed repair round, not successful nested-plan qualification.

Focused diagnostic `30291`, exit 2 (one failed case, five excluded), reached
no successful function-identity marker. The immutable authorization migration
sets `singularity_authorization_definer` before creating
`core.live_principal_authorization()`. The observer had incorrectly expected
`singularity_table_owner`. Astra round 2 corrected only that exact owner check;
the check was not removed and the migration/function was not changed. All
temporary diagnostic instrumentation was removed before qualification.

Round 2 integration `17116`, exit 0, seed `215378`, took 1.7 seconds: **five
executed integration cases pass, one pure case excluded**. Its closed summary
from the actual real-Web scoped function call was:

```text
backend=455900 nested_statements=1 executed_nodes=12
actual_rows=1 actual_loops=1 buffer_nodes=12 indexes=[]
```

This proves delivery of an analyzed nested deployed function plan, including
its strict source/context/backend identity and buffer counters. The empty
index list is deliberate: this prerequisite makes no search-index claim.
No copied SQL, SET ROLE, broad grants, planner forcing, RLS bypass, raw plan
output, or shared RequestRepo/dynamic-state mutation was used.

Qualified file hashes:

- Helper: `87213eef3a4a8017004951781a04160b06e01a3e3ed199c73e5ccc5505c3e8f3`.
- Owning test: `d36687ebe9b079ee6f87da51bbec358c385b5466216858a24b81364fe6963b16`.

Static/pure session `62549`, exit 0, passed changed-file format checking,
one pure test (five integration cases excluded), compilation with warnings
as errors, and compile-connected xref with zero cycles. Exact command:

```sh
devenv shell -- bash -c 'export MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps; mix format --check-formatted apps/singularity_storage/test/support/knowledge_search_plan_observer.ex apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs && mix test apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs --seed 215378 && mix compile --warnings-as-errors && mix xref graph --format cycles --label compile-connected --fail-above 0'
```

The owning integration command remains the complete-file command above.
Full-xref/cleanup session `30119`, exit 0, reported zero cycles, zero **all**
generated test databases, zero recorded databases, and every recorded storage
root absent, including rounds 1/2 and the focused owner diagnostic. The owned
PostgreSQL instance stopped normally. Exact command:

```sh
devenv shell -- bash -c 'export MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps; mix xref graph --format cycles --fail-above 0 && bash .devenv/phase3-cleanup-inventory.sh'
git diff --check
```

Independent Sol SPEC then QUALITY reviews both **PASS**, with no outstanding
important findings, on the exact helper/test hashes above. SPEC also reviewed
observer-plan behavior at `a14b17361032cf9d79bf618cbfc0976cd2c6d8e5d30d67e062dac0f152efb1b3`;
later documentation changes record qualification and checklist completion.
Both review passes used read-only inspection only; parent-owned execution is the
evidence for the test results. Link check `a4e72d` passed three documents and
nine local links. Root/main and the two protected Phase 2 worktrees remain at
their recorded commits, and the protected untracked integration plan and all
three frozen original test hashes remain unchanged.

Cumulative implementation repair accounting is
two failed parent/Sol rounds followed by two Astra rounds (first failed,
second passed its owning tests); diagnostic probes are not repair rounds.
Original selective-index contracts remain FAIL pending the separate product
repair; E2E remains NOT RUN. No production or Vault file has changed.

The qualified prerequisite, synchronized observation design/plan, and evidence
were committed locally as `cdfa29ab46913d65a7611a2f2e9f820f120c9cc7`
(`test(storage): prove isolated nested search-plan observation`). Only five
owned files were staged; the original privacy and failed plan contracts remain
untracked and unchanged. No merge or push occurred.

Post-commit governance/architecture recheck `47262`, exit 0, seed `215378`,
passed all **31 tests** in 2.6 seconds against the committed implementation
(only documentation status edits were pending):

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 215378
```

## Guarded candidate repair: unchanged direct-search characterization

Before any candidate function or Store change, parent session `70425`, exit 0,
seed `215378`, passed **21 integration tests** in 19.5 seconds at production
source `cdfa29ab46913d65a7611a2f2e9f820f120c9cc7` (only documentation status
updates were pending). The existing Store and pagination suites were unchanged:

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs --seed 215378
```

The harness allocated `singularity_test_96ca97c71c2cd646a17c973a`, disposed of
its database/storage root, and stopped its owned PostgreSQL server. This is
pre-repair behavior characterization, not evidence that the two selective-index
failures or a final-candidate gate have passed.

Read-only cleanup inventory `30218`, exit 0, independently verified zero
generated/recorded test databases and absent recorded storage roots, including
this allocation, then stopped the owned server. It used the unchanged command
`devenv shell -- bash .devenv/phase3-cleanup-inventory.sh`.

The concrete [candidate repair plan](../superpowers/plans/2026-10-10-singularity-v0.2-phase-3-search-index-repair.md)
was authored/self-reviewed by Sol and independently reviewed by the parent.
Review corrected fixture-local seeding of existing product capability
definitions, private reduction of raw errors, actual-call candidate invocation
evidence, exact compiled migration-literal identity, and the historical ceiling
`20261009000400`. Final reviewed plan hash:
`63d68d6dada194e215a40976684adac0312758e59ba7af5cb9058114e8206496`.
Local-link check `ba81d4` passed four documents and 18 links; `git diff --check`
passed. Candidate implementation qualification remains NOT RUN at this plan
handoff. There is no outstanding user choice or routine approval gate.

## Guarded candidate implementation: first expected RED

The reviewed implementation plan was committed locally as
`13e52189742270b727957281d2d978a5a421a587`
(`docs(storage): plan guarded search candidate implementation`). No merge,
push, release, deployment, E2E, or Vault work occurred.

Sol authored the first direct-function contract; the parent added private,
once-per-source existing-capability assignment wrappers in the three owning
Store/pagination/plan test files. Shared fixture defaults and all original
assertions are unchanged. Formatting session `36729` exited 0. A mechanical
fixture patch initially failed to apply due to hunk order; no partial edit
occurred, and correcting the order applied the intended fixture-only changes.

Parent session `31744`, exit 2, seed `215378`, ran one integration case in
2.4 seconds:

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs --seed 215378
```

The real `singularity_web` login, real canonical Note/ready Document, projection,
and explicit existing read assignments passed their preconditions. The exact
remaining failure was closed `:candidate_function_missing`, as intended before
creating `content.search_candidate_ids(text,text,uuid[])`. The migration version
`20261010000000` was checked unused. The harness allocated
`singularity_test_9e2a8023906026eb5f40f339`, disposed of the database/storage root,
and stopped its PostgreSQL server. No production code existed at this RED.
Product repair rounds remain zero; this expected regression failure is not a
failed repair attempt and does not change the recorded observer counters.

The parent reran the original Store/pagination contracts after their fixture-only
permission setup changes, still before any production edit. Session `87477`,
exit 0, seed `215378`, passed **21 integration tests** in 30.6 seconds with the
same command as baseline session `70425`. Allocation
`singularity_test_a2892aab29f52d4500ef137f` was disposed and the owned server
stopped. This validates the explicit fixture authority setup, not the pending
candidate function or selective-index repair.

Read-only cleanup inventory `54242`, exit 0, independently confirmed zero
generated and recorded test databases and absent recorded storage roots,
including both new allocations, then stopped the owned PostgreSQL server.
The frozen runtime privacy and legacy Note concurrency test hashes remained
unchanged (`6da120`).

## Guarded candidate implementation: authority and catalog RED

Independent Sol reviewer `/root/search_fixture_authority_review` returned
separate SPEC and QUALITY PASS verdicts for the three parent-authored fixture
changes, with no findings. Reversing the local wrappers/call replacements and
necessary alias formatting reproduced both tracked HEAD files byte-for-byte
and the original plan-test hash
`01b20aca6afb66f65e0e62f17cbc083e5753603b446e62412dae0fb0595da570`.
The reviewer did not run tests or claim implementation qualification.

Sol expanded the owning candidate module to 11 contracts. Parent formatting
`98666` exited 0; formatted test hash was
`fe46b5ea6a5b3e4eff1f5524b7c850d05c569a04e9f00ea82007b4ecebd0a9ff`.
Parent integration `46619`, exit 2, seed `215378`, took 10.5 seconds using the
same owning command as `31744`: **11 tests, 9 expected failures**. Eight failed
with closed `:candidate_function_missing`; the catalog contract found no
function row. Actual dispatcher and pre-authentication logins already denied
schema access, so those two negative controls passed. Worker execution was one
of the missing-function failures. Existing role attributes/memberships, forced
RLS and policy/grant/index baselines passed their assertions before and after
the attempted candidate call. No fixture/authentication defect was masked by
this expected RED, and no production code had yet been added.

Allocation `singularity_test_aa09894178fc697796e1d4c9` was disposed by the
harness and its owned PostgreSQL server stopped. Sol then received only the
new forward migration for implementation; the test remained frozen for
independent review. These expected RED checks do not increment repair counters.

Independent candidate-test review initially required two coverage repairs:
the partial web-policy substring assertion was not an exact pre-migration
baseline, and a candidate-name-prefix function inventory could miss another
privileged helper. Sol added one historical predecessor comparison. It compares
the complete fresh security snapshot (including full policy expressions) with
`20261009000400`, and requires the full non-system-schema SECURITY DEFINER
signature/owner inventory to differ by exactly the new candidate function.
Parent review also corrected the system-schema filter from SQL wildcard
`LIKE 'pg_%'` to the literal reserved prefix regex `'^pg_'`. No assertion was
weakened; the old substring loop was replaced by exact historical equality.
Final formatting `34606` exited 0 without changing the final candidate-test
hash `904cb794fe5514ae6c9d7c5ee0651ee0febe504ac3af6e710e014a2145012811`.
Independent SPEC then QUALITY re-review passed with both findings closed.
This early predecessor check is not the later populated historical migration
upgrade/canonical-byte gate from Task 7.

The new migration's literal function SQL matches the reviewed plan. Parent
formatting `56580` exited 0; final migration hash:
`5ce4fd3e4408963718acfb60d0d8a570d5bb40396f5020c993a011beba67dca4`.
Independent SPEC and QUALITY source review both passed with no findings.
Only this new function/owner/ACL/fixed settings are added; all released
migrations, role attributes, RLS, Store code, and Vault remain unchanged.

Parent session `99086`, exit 0, seed `215378`, passed **45 integration tests**
in 147.4 seconds against the migration candidate:

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/roles_test.exs apps/singularity_storage/test/singularity/storage/search_projection_schema_test.exs --seed 215378
```

Allocation `singularity_test_9cc42b2e202c60a4ce6dbdba` was disposed and the owned
server stopped. These unchanged role/projection-schema gates passed; candidate
direct-call GREEN remains a separate required command. Production repair
counters remain zero; source-review corrections are not failed repair rounds.

## Guarded candidate Tasks 1–2: scoped GREEN checkpoint

Parent `58453`, exit 0, seed `215378`, passed all **12 candidate integration
tests** in 17.5 seconds with the unchanged owning integration command. Exact
real-web Note/Document/all identity sets, capability conjunction/denials,
non-web runtime denial, hardened function catalog/ACL, unchanged complete
predecessor security state, and the sole-added-privileged-function inventory
all passed. Allocation `singularity_test_cbb4b99a32a713a1b25b8961` was disposed
and the owned PostgreSQL stopped. Candidate test and migration hashes remained
the independently reviewed `904cb794...` and `5ce4fd3e...` above.

Static verification `63024`, exit 0, passed changed-file formatting and
warnings-as-errors compilation, with **zero xref cycles**:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted apps/singularity_storage/priv/repo/migrations/20261010000000_create_guarded_search_candidates.exs apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
```

Cleanup inventory `53484`, exit 0, verified zero generated/recorded test
databases, absent recorded storage roots, and stopped its owned server.
Root/main, both protected Phase 2 worktrees, their protected integration plan,
and the frozen runtime privacy test remained unchanged. `git diff --check`
passed; only owned paths are eligible for the local commit.

This is the guarded function and explicit fixture-authority checkpoint only.
The Store has not yet been changed to use it. Input/context/revocation/concurrency,
actual nested index evidence, populated historical upgrade, full regression,
and complete-candidate reviews remain outstanding. The original selective
index qualification remains FAIL, and E2E remains NOT RUN. The original
untracked plan test is included with this batch's approved fixture-only change;
its known selective failures are preserved, not claimed fixed. No phase or
release acceptance, Vault change, merge, push, or deployment is implied.

This seven-file checkpoint was committed locally as
`8fa8aa1d1a55485713dc200c4758d13e7b9994b3`
(`feat(storage): add guarded canonical search candidates`). Only the protected
runtime privacy test remains untracked. The parent assigned Task 3 direct
authority/input qualification and Task 4 Store RED contracts to different Sol
workers on disjoint files; all database, test, formatting, and Git work remains
parent-serialized. Neither task requires renewed human approval.

## Guarded candidate Tasks 3–4: parallel qualification and Store RED

Task 3 adds 15 input/context/live-authority/isolation/shadowing contracts to the
12 existing candidate cases. Canonical row count/digest snapshots remain private
and every failed query has its own transaction. Task 4 adds five Store contracts
without changing existing assertions. Before execution, parent review renamed
the empty-query capture's counter to `candidate_references` (it is SQL absence
evidence, not actual-call invocation proof) and required a distinct fixed
collector-cleanup error so an expected setup fault cannot hide abnormal
collector termination. Formatting `77362` exited 0; Store-test hash:
`78543d3e95bb40b6d3ce468979de61f425ff30bdeae6764fb1ca5a172bac2ef7`.

Parent Store/pagination RED `92037`, exit 2, seed `215378`, took 17.3 seconds:
**26 integration tests, one expected failure**, before changing the production
Store. The no-read matching nonempty query still returned a canonical page
instead of the new required sanitized forbidden result. The other 25 contracts
passed, including empty-query rank-zero identity/13-bindings/no-candidate SQL,
trace ownership/cleanup, existing ranking/pagination, and the fixed deadline.
The production Store was still byte-identical at SHA256
`ad2832e8b8e048c1c480e91d8f0d182637f315b1d60a02a1f8a36c9fa01293a4`.
This expected RED is not a failed repair round.

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs --seed 215378
```

The harness disposed `singularity_test_44e160ab4fa4e793c0bf7ee9` and stopped its
owned server. Only then did Sol add the two planned Store fragments and SQL
interpolation anchors. Reverse reconstruction reproduces the original Store
byte-for-byte; parameters, rank, text predicates, resolve, page/cursor mapping,
and fixed settings remain unchanged. Candidate source guards and Store
integration are reviewed independently by the other, nonauthor Sol worker.
Parent formatting `29017` exited 0. Final frozen candidate-test hash:
`1621edacc5596e59596341ccee55dec1200ebda500af3e1006f44c64fb7f1073`;
Store implementation hash:
`53e4b3bae1eee8397ae0e6587a2fedacca2f16e95518e6428567a97795c8c3b4`.
GREEN results remain separate execution obligations, not inferred from review.

Parent Task 3 qualification `93996`, exit 2, seed `215378`, executed **27 tests
with one failure** in 28.0 seconds. The public-clearance fixture UPDATE failed
before calling the candidate function: the unchanged initial migration's
`vault_members_classification_check` permits only private/sensitive/restricted.
The other 26 contracts passed. Allocation
`singularity_test_05b0d9db4322f6a220dc650b` was disposed and PostgreSQL stopped.
Both earlier source-only SPEC/QUALITY reviews passed but missed this invalid
fixture; they do not override the execution failure.

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs --seed 215378
```

The reviewed design/plan correction qualifies this impossible persisted state
through its exact existing constraint/SQLSTATE rejection, unchanged membership,
legitimate candidate control, and unchanged canonical snapshot. The first Sol
fixture repair is in progress; no completed failed repair round is recorded.
No production function, Vault schema, guard, or constraint change is required.
This is not a claim of live candidate denial with public clearance.

Parent Task 4 GREEN `33792`, exit 0, seed `215378`, ran the exact Store/pagination
command above: **26 tests, zero failures**, 17.8 seconds. Allocation
`singularity_test_45512132b45c7eed5576011c` was disposed and PostgreSQL stopped.
Store and Store-test hashes remained `53e4b3ba...` and `78543d3e...` respectively.
Independent SPEC and separate QUALITY source reviews by the nonauthor
`phase3_task9_rebuild` Sol both passed without findings. This qualifies the
narrow join and retained Store contracts only; actual nested selective-index
proof, concurrency, migration upgrade, final regression, and E2E remain separate.

Parent static gate `33585`, exit 0, passed formatting of the two changed Store
files, warnings-as-errors compilation, and zero xref cycles:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted apps/singularity_storage/lib/singularity/storage/postgres/knowledge_search_store.ex apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
```

Only those two files were committed locally as
`9793289851022c15ea6aa31305daeecacb2c9d85`
(`fix(storage): join guarded candidates for nonempty search`). Uncommitted
candidate qualification and evidence updates remain separate; the protected
privacy test, original plan fixture, and legacy concurrency test are unchanged.

Task 3 repair 1 passed independent amended SPEC and separate QUALITY review by
the nonauthor `search_fixture_authority_review` Sol. Formatting `75487` exited
0; final candidate-test hash is
`6296a850d50e12d862bbc8d31ed0752f061a35b5618a360de8f16ae670256453`.
Parent owning rerun `5183`, exit 0, seed `215378`, passed **27 integration tests
in 30.4 seconds**, using the exact candidate command recorded above. The public
membership UPDATE produces the exact expected `23514` constraint error within
an owner-fixture savepoint, then rollback/release allows the unchanged private
membership and canonical snapshots to be verified. All six representable
authority denials, invalid inputs/GUC/isolation, literal boundaries, and
shadowing controls remain intact. This is one successful Sol fixture repair,
zero failed Sol repair rounds and zero Astra repair rounds for this guarded
candidate batch; historical observer recovery counts above remain unchanged.

Allocation `singularity_test_ad8c9880aeb24b172d3935e7` was disposed and PostgreSQL
stopped. Earlier cleanup `80252`, exit 0, confirmed zero generated/recorded
databases and absent roots through the Task 4 allocation; the repair allocation
has been added to the next read-only inventory. Protected root/main and both
Phase 2 worktrees, their untracked plan digest, runtime privacy test, and legacy
Note concurrency test remain unchanged. No production/Vault change was part of
this fixture repair. Concurrency and actual nested index qualification are next.

The Task 3 qualification and its independently reviewed contract correction
were committed locally as `8c94c0e23475601fd665077e5c57d33670f31c11`
(`test(storage): qualify search candidate authority boundaries`). A local-link
check subsequently resolved all 14 referenced local targets without a missing
file. Tasks 5 and 6 proceed on disjoint candidate/observer files; parent-only
execution remains serialized.

## Guarded candidate Tasks 5–6: concurrency and actual-call evidence

Task 5's first increment preserves the 27 qualified cases and adds three exact
authorization-lock revocation barriers plus one wrong-key control. Parent
formatting `91497` exited 0; frozen candidate-test hash:
`e3966a20e7e5062105a7795da46e9301ac2b8498b7f6845c50b33e4934a4a8ee`.
The separate Task 6 worker is writing missing-export RED contracts only; the
observer helper remains `87213eef...` and the original plan fixture remains
`bc063726...` until parent execution. No nested-plan success is claimed yet.

Parent candidate increment `48442`, exit 0, seed `215378`, passed **31 tests
in 35.1 seconds** with the same owning candidate command. All three exact-key
readers were observed waiting before acquiring any content relation read lock;
after the writer committed capability/membership/principal revocation, each
returned the fixed forbidden error. The wrong-key reader completed successfully
while its unrelated holder remained alive. Allocation
`singularity_test_2009b98d975d981b26c56567` was disposed and the owned PostgreSQL
stopped. No production repair or failed repair round was needed. Controlled
canonical races, uncapped/dedup/stale-derived controls, and independent complete
Task 5 reviews still remain; this subset is not full Task 5 acceptance.

Task 6 missing-export RED `36640`, exit 2, seed `215378`, completed in 2.2
seconds: **11 total tests, one pure test excluded, five expected failures**;
all five existing integration controls passed. Each new contract stopped at
the absent `search_summary/3` export, including the actual empty-query control.
No expected-error branch could mask that absence. Parent formatting `68383`
passed; owning-test hash:
`cc1b231b5c6342d58e153cf29473bdfb7fc208fa6f405f3901de8dd1e7a5351f`.
Independent SPEC and separate QUALITY reviews by the nonauthor
`phase3_task9_rebuild` Sol passed before formatting. This expected RED is not a
failed repair round. Allocation `singularity_test_a44d9b9a1427246a5400a1e4` was
disposed and the owned PostgreSQL stopped.

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs --seed 215378
```

Task 7 uses the new independent `search_candidate_migration_test.exs` module,
with unchanged proof obligations, to avoid concurrent edits to Task 5's owning
file. Parent pure run `15511`, exit 0, passed the fixed forward-only contract
(three total tests, two integration cases excluded) in 0.5 seconds; formatting
`1589` and `21085` passed. Source review strengthened same-database physical
relation/index identity before historical upgrade, avoiding a claim that equal
logical definitions alone prove no index rewrite. Final historical qualification
and its independent review remain outstanding.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_storage/test/singularity/storage/postgres/search_candidate_migration_test.exs, test apps/singularity_storage/test/singularity/storage/postgres/search_candidate_migration_test.exs --seed 215378
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/search_candidate_migration_test.exs --seed 215378
```

Task 7 first integration `99538`, exit 2, seed `215378`, executed two tests
(three total, one pure test excluded): **one failure**, 14.8 seconds. Fresh
catalog validation passed, but the populated historical upgrade failed with
`42501` when CREATE FUNCTION validated `pg_trgm.similarity_threshold` on its
new migration connection. This is a migration compatibility defect, not a
waived test or authorization request. Allocation
`singularity_test_92578871d655a231b5e8d5fb` was disposed and PostgreSQL stopped.

Sol confirmed the PostgreSQL 17 initialization/GUC-validation mechanism cited
in the amended design. Calling the already-granted pure
`search_extensions.similarity('','')` before CREATE registers its USERSET GUC.
The four-line new-migration addition retained all prior function/body/ACL
bytes; hash `a949fc59102a4ab939a878a51fe5c378ce37833954fa8ff7405e0066ed8c2715`.
No role grant, preload/default, released migration, or Store change was made.
In particular, the existing Store's fixed-settings function was not changed;
an earlier parent hypothesis that it already calls similarity was incorrect
(only the existing timeout fixture explicitly primes it).

Independent Task 7 review found and closed two coverage gaps before the rerun:
inventory every non-system privileged function rather than only three schemas,
and execute real web/worker/dispatcher/preauth INSERT/UPDATE/DELETE denials
at fresh/pre/post-upgrade checkpoints instead of relying only on catalog
privilege predicates. Every unexpected write outcome also rolls back.
Both amended SPEC and separate QUALITY reviews passed at owning-test hash
`2ecfdf2dd5727503ce06af469bb144e809a3f61491163eb733c5992654fd15bf`.

Parent repair-1 command `95652`, exit 0, passed changed-file formatting and
**both migration integration tests** in 16.3 seconds (three total, one pure
excluded), seed `215378`. Allocation
`singularity_test_c0a57ebb6a37b9f53db8cc92` was disposed and PostgreSQL stopped.
This is one successful Sol production-migration repair, zero failed Sol repair
rounds and zero Astra rounds in this batch; the earlier successful fixture
repair and historical observer counters remain distinct.

PostgreSQL grammar source review also found that a comment before the first
SQL token would not survive into nested Query Text. The same single static
marker was moved after WITH, with no guard/predicate/ACL/settings change;
new migration hash `5254c58509393090dfdf67e9e3e1570c7eea8ba72fad0b4c63c70b60f615de26`.
This is a nonsemantic observation preflight correction, not actual NOTICE
qualification. The parent is rerunning the Task 7 oracle on these final bytes
alongside the Task 5 second increment (37 candidate tests); formatting `56738`
passed, candidate-test hash
`9f4d850d8485292fb84b244f65a4989d92d528825ecd6838664383db50d13f88`.

Parent combined rerun `13321`, exit 0, seed `215378`, passed **39 integration
tests in 45.9 seconds** (40 total, one pure excluded): all 37 Task 5 candidate
contracts and both Task 7 migration contracts. Allocation
`singularity_test_fd52bde51c45f9e1ec1f4576` was disposed and PostgreSQL stopped.
The five canonical races and full 66-row, two-page candidate set passed.
Generated constant-atom membership checks in the new race tests emitted
compiler warnings; this is not a warning-free gate. Their surgical correction
and remaining representable/stale source controls are in progress.
The final migration bytes `5254c585...` passed independent SPEC and separate
QUALITY source review by the nonauthor `phase3_task9_rebuild` Sol. Task 7's
existing migration/role/schema regression gate still remains.

Task 6 helper formatting `60800` passed at hash
`1a78dad15bd0e5b933d502bd197c52713e3dec3078c691bf347d0732ae437c41`;
the owning test remains `cc1b231b...`. Independent SPEC and separate QUALITY
source reviews by the nonauthor `search_observer_actual_review` Sol passed.
Removing only the added search-observation block reproduces the previously
qualified helper hash `87213eef...`, preserving the original lifecycle and
authorization implementation byte-for-byte.

Actual owning execution `85135`, exit 2, seed `215378`, then produced **three
failures in 4.2 seconds** (11 total, one pure excluded). The positive Store
and empty-query callbacks returned the sanitized callback-failed outcome;
the explicit post-capture callback-fault control did not reach its proof
signal. The five old integration cases and no-read/conflicting-pattern
controls passed. Source-review PASS does not override these failures.
Sol diagnosis is in progress with all assertions and original lifecycle
unchanged; no completed failed repair round is recorded yet. Allocation
`singularity_test_949a636bf3de3a8df4ad0e47` was disposed and PostgreSQL stopped.

Final-byte Task 7 pure rerun `43640`, exit 0, seed `215378`, passed **one
forward-only test in 0.7 seconds** (three total, two integration excluded),
together with changed migration/test formatting checks. The parent has started
the complete prescribed existing migration/role/schema/RLS batch on the same
migration bytes; its outcome will be recorded separately rather than inferred
from the new owning tests.

That complete prescribed migration/role/schema/RLS batch `84484`, exit 0,
seed `215378`, passed **109 integration tests in 434.5 seconds** (117 total,
eight excluded). Allocation `singularity_test_b9e9ad8b29c7ab87bd5c5ed3` was
disposed and PostgreSQL stopped. It covers all nine files in Task 8's second
integration command, including the new migration module; no assertion or
required case was removed. Final migration/test digests remain `5254c585...`
and `2ecfdf2d...`. The migration repair was committed locally as
`2acbfa07055c59e95882730f7d0be97aedd1b32b`; its separate owning qualification
was committed as `193f1c38579944278b60cb7c9bf26e549ce9b220`.

Task 5's final additions passed independent SPEC and separate QUALITY source
reviews by the nonauthor `search_observer_actual_review` Sol before execution.
Parent formatting `13312` exited 0; formatted owning-test digest is
`225beea1a7b19226e065cb6e029364e93f9648c3738e7a09ebf208ab80e42b99`.
All 45 candidate contracts, including the eight new stale/schema cases and
warning corrections, still require the parent runtime gate.

Task 6 privacy-safe diagnostic `1701`, exit 2, repeated the same three
failures (11 total, one pure excluded) in 8.7 seconds. Temporary helper
instrumentation used only fixed stage/error-class atoms and no captured
values, SQL, parameters, source, notices, or exception text. All three
positive/empty failures reached `original_plans` then a guard failure; source,
trace pairing, backend identity, and 13-parameter checks had completed.
The other two emitted failures belong to their expected conflicting-trace
and no-read negative controls. This localizes diagnosis but is not a fix or
a completed repair round. Temporary formatted helper hash was
`ae653f96b928bb848ce3a09f8d28659a938a3799000e67eb9b7b8b96718c6a6a`;
all instrumentation must be removed before qualification/commit. Allocation
`singularity_test_7a1efdd0c9a1c1fc08f6c02b` was disposed and PostgreSQL stopped.

Task 5 final runtime gate `27406`, exit 0, seed `215378`, passed **71
integration tests in 178.4 seconds**: all 45 candidate contracts and all 26
Store/pagination contracts. No compiler warnings occurred. The eight new
stale/schema boundary cases passed without changing production or disabling
constraints. Independent SPEC and separate QUALITY reviews were reaffirmed
for the exact formatted test hash `225beea1...`. Allocation
`singularity_test_cd04ceb3507c4e014ac4d934` was disposed and PostgreSQL stopped.
The sole candidate-test file was committed locally as
`e85b3035826ed00226d182b0141f37b3f39aed77`
(`test(storage): cover search candidate revocation and source races`).

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs --seed 215378
```

Task 6's second temporary diagnostic narrows only the original-plan parsing
boundary using fixed numeric counters and private equality checks. The strict
parser and all owning assertions remain unchanged. No repair or performance
success is claimed from diagnostic instrumentation.

Second bounded diagnostic `88899`, exit 2, seed `215378`, repeated **three
failures in 9.1 seconds** (11 total, one pure excluded); temporary formatted
helper hash `5a67bd1215b0035b5046153d767cc667ab68de91e1634e37621e4f64e0277ccc`.
Both nonempty positive attempts had nine duration notices, four candidate
signature contexts, zero exact full-context matches, one exact candidate SQL
match, and zero outer query anchors. The empty query had six duration notices
and no candidate/outer matches. Captured row counts had the expected numeric
type. No captured values were emitted. Allocation
`singularity_test_521146149fb5726b9514af64` was disposed and PostgreSQL stopped.

Primary PostgreSQL 17 source inspection establishes that `auto_explain` emits
at ExecutorEnd, whereas completed extended-protocol SELECT portals remain
PORTAL_READY until later cleanup. The original Store return therefore need
not contain its outer plan; replacing it with replay proof is prohibited.
The driver lifecycle and bounded original-notice collection design are being
diagnosed before any repair. These two diagnostic runs are not failed repair
attempts; no actual repair has yet been validated.

Sources: [auto_explain ExecutorEnd](https://raw.githubusercontent.com/postgres/postgres/REL_17_STABLE/contrib/auto_explain/auto_explain.c),
[SELECT portal lifecycle](https://raw.githubusercontent.com/postgres/postgres/REL_17_STABLE/src/backend/tcop/pquery.c),
[portal cleanup](https://raw.githubusercontent.com/postgres/postgres/REL_17_STABLE/src/backend/commands/portalcmds.c),
and [extended Execute completion](https://raw.githubusercontent.com/postgres/postgres/REL_17_STABLE/src/backend/tcop/postgres.c).

Sol verified the complementary checked-out Postgrex `0.22.4` behavior in
`deps/postgrex/lib/postgrex/protocol.ex`: `done/5` snapshots and clears the
connection's messages when CommandComplete arrives; later close/ready notices
update connection state rather than the already-created result. The bound
execute/close path closes the statement, not the SELECT portal. This is an
evidenced observation-channel design mismatch, not a production search defect
or an internal dependency workaround. A bounded Astra architecture consultation
(`search_notice_lifecycle_architecture`, `PROJECT_ARCHITECTURE`) is correcting
the evidence collection model; it is not counted as a failed repair attempt.
No replay may be substituted for original-call evidence.

An early independent production-only SPEC review by the nonauthor
`search_observer_actual_review` Sol found no concrete defects against accepted
Phase 2 source `c34935a...` through production `193f1c3...` (unchanged through
`e85b303...`). It covered provenance, authorization, workers, rebuild, restore,
bootstrap/ACLs, layering, and Vault freeze. This is explicitly not final
complete-candidate review or acceptance of the failing Task 6 helper.

The uninstrumented runtime/projection/privacy batch `92723`, exit 2,
seed `215378`, passed **38 storage integration tests in 42.3 seconds**, then
executed **28 runtime integration tests with one failure in 147.9 seconds**
(58 runtime total, 30 pure excluded). The failure was the cross-page rebuild
revocation contract at `search_rebuild_test.exs:521`: it did not receive the
between-pages signal within 5,000 ms while 82 callback/resource progress
messages were already present. This is a new failed checkpoint, distinct from
the preserved historical Note concurrency timeout; no cause or fix is claimed.
Sol diagnosis is in progress without reducing the 100-row page boundary,
weakening revocation assertions, or blindly increasing the timeout.

The frozen runtime privacy and legacy Note concurrency hashes remain
`17e6eeeb...` and `d49e2288...`; their cases passed in this batch. Allocation
`singularity_test_eca7c6e8442e202e1d94c8ba` was disposed and PostgreSQL stopped.
This partial pass is not a green combined runtime gate or Task 8 acceptance.

Read-only Sol diagnosis traced the rebuild hook to the return of the hundredth
serial resource scope. The existing per-resource markers are emitted after
actual authorization and transaction acquisition but before reconciliation;
the next marker proves the preceding scope completed. The failing receive
therefore budgets five seconds for enumeration plus all 100 real scopes, not
one barrier transition. No production defect was established.

The first test-only repair adds ten lines to consume those 100 markers in
exact canonical order, each with the existing five-second bounded progress
wait, and assert positive, distinct transaction IDs and no extra resource
marker. It leaves all original 101 post-revocation content-callback checks,
barrier, next-page denial, projection/canonical equality, fixture size, test
deadline, and cleanup unchanged. Pre-repair test hash is `f9210602...`;
formatted repair hash is
`06c9a98ea72cc72cc36579e71ce29d865de25c2ed126b6dc4af999eebe35c740`.
Parent owning rerun `74705` and independent nonauthor review are in progress;
no repair success is claimed before their results.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format apps/singularity_runtime/test/singularity/runtime/search_rebuild_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_runtime/test/singularity/runtime/search_rebuild_test.exs --seed 215378
```

Owning repair rerun `74705`, exit 0, seed `215378`, passed **13 integration
tests in 36.0 seconds** (17 total, four pure excluded). Independent SPEC and
separate QUALITY review by the nonauthor `search_fixture_authority_review` Sol
passed on exact formatted hash `06c9a98e...`; the diff adds only ten lines.
Allocation `singularity_test_75c3176e53476e6c0fe5db67` was disposed and
PostgreSQL stopped.

The complete previously failing seven-file batch rerun `51110`, exit 0,
seed `215378`, passed **38 storage integration tests in 13.5 seconds** and
**28 runtime integration tests in 64.1 seconds** (58 runtime total, 30 pure
excluded). Allocation `singularity_test_cbe10225ab46d25ac4ebfb8b` was disposed
and PostgreSQL stopped. This is one successful Sol test-contract repair,
zero failed repair rounds for this rebuild issue, with no production change.
The original `92723` failure remains recorded, as does the unrelated historical
Note timeout. Full Task 8 and Phase 3 acceptance remain incomplete.

The independently reviewed, owning- and combined-green ten-line runtime test
repair was committed locally as `67775356a4c10cb6fca499a0aaa284dd15069e6d`
(`test(runtime): await exact rebuild progress before revocation`). No
production files or other tests were included in that commit.

The Astra observation architecture recommendation was written into the design
and Task 6. Independent doc-only SPEC and separate QUALITY review by
`search_observer_actual_review` passed. Its one minor audit finding was fixed:
the initial design digest is explicitly historical, distinguished from amended
reviewed design `4d32dd0f...`. No runtime proof is inferred from that review;
the temporary helper remains unqualified until the new RED/GREEN and actual
cold/warm gates execute.

The amended design, implementation plan, and accumulated evidence were committed
locally as `f2c2fb5feaa78d1dee288cbbd39a60038874f377`
(`docs: correct search observation and rebuild wait contracts`).

The independent restore compatibility batch `71569`, exit 0, seed `215378`,
passed **36 integration tests in 29.9 seconds** (44 total, eight pure excluded).
It covered unified search restore, integrity audit, restore import, and logical
exporter. Allocation `singularity_test_63336e00afdff95be8a5c839` was disposed
and PostgreSQL stopped. The complete V1/V2 restore oracle remains a separate
required check; this subset does not qualify Task 6 or full phase acceptance.

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs --seed 215378
```

Amended Task 6 RED `58298`, exit 2, seed `215378`, executed six pure tests in
1.2 seconds: the original pure test passed and **all five new contracts failed
at the missing `validate_search_envelope/1` export**, outside callbacks/error
catching (17 total, 11 integration excluded). Formatted owning-test hash is
`1f894e915bb964e58b2f389c7e67a13e4307c29906f1b7995728c465f244e880`.
The temporary helper remained `5a67bd12...` and original 8,192-row plan test
`bc063726...` during RED. Sol may now implement the first two-result repair;
no helper success or index qualification is inferred from expected RED.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs, test apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs --seed 215378
```

The complete V1/V2 restore command `90085` exited 0. It allocated source
`singularity_test_6e516fefc837d601548174a2`, V2 destination
`singularity_test_c0c41fe8af5ed94982f6435c`, and V1 destination
`singularity_test_66be652f47751606eedaa835`, with matching integration storage
roots. The established oracle completed and the owned PostgreSQL instance
stopped. Postgrex type-cache reload debug messages and migration-module
redefinition warnings were present; this is not a warning-free command or
a diagnostic-privacy proof. No legacy migration or Vault file was changed.
The runtime privacy test and legacy Note concurrency test retain their frozen
hashes `17e6eeeb...` and `d49e2288...`.

```sh
devenv shell -- bash .devenv/phase3-restore.sh
```

Post-restore read-only cleanup inventory `12129` exited 0: no generated test
databases remain, every recorded integration/storage root is absent, and the
owned PostgreSQL instance stopped. Root/main and the Phase 2 verification
worktree are clean; the Phase 2 implementation worktree retains only its
protected untracked integration plan with unchanged SHA `350a6557...`.
The current `git diff --check` is clean. This checkpoint precedes the new
Task 6 helper implementation and is not final candidate cleanup.

Independent interim QUALITY source review by `search_observer_actual_review`
passed for frozen Phase 3 source `c34935a...` through `f2c2fb5...`, with no
concrete security/privacy/authorization/snapshot/race/restore or maintainability
findings. Production remains unchanged since its earlier SPEC review at
`193f1c3...`. This review explicitly excludes the three still-changing Task 6
files and the untracked privacy test; it does not replace the final
complete-candidate SPEC and separate QUALITY reviews.

Task 6 Sol repair 1 removed every temporary probe and EXPLAIN replay and added
the immediate drain plus strict two-channel validator. Parent formatting and
pure validation `72713`, exit 2, seed `215378`, executed six pure tests in
1.2 seconds: **five passed, one failed** (17 total, 11 integration excluded).
The backend/PID rejection suite caught a floating-point returned PID accepted
by numerically loose `==`; no assertion was weakened. Formatted helper hash is
`fc7c31b7b99ec9dff1d391adcdf2bcbb5d248856eebcc46c0c70661674a9be08`.
Removing only the added search-observation block reproduces the exact qualified
lifecycle/authorization helper SHA `87213eef...`, independently checked by
the parent. Owning tests remain `1f894e91...`; original plan test remains
`bc063726...`. This is **one failed Sol repair round** for this Task 6 issue;
the same frozen bytes are undergoing owning integration diagnosis before
the next repair. Astra architecture consultation is not a repair round.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_storage/test/support/knowledge_search_plan_observer.ex, test apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs --seed 215378
```

The same first-repair bytes passed owning integration `90913`, exit 0,
seed `215378`: **11 integration tests in 5.6 seconds** (17 total, six pure
excluded), including original-call positive/empty proof, three successive
same-backend calls, cleanup and diagnostic confinement. Allocation
`singularity_test_ead805296e33a6d922b6bc70` was disposed and PostgreSQL stopped.
This does not override the pure float-PID failure. Read-only diagnosis
confirmed a four-comparison strict-identity repair; the second Sol repair
changes only both connection IDs, drain row count, and drain PID rows from
`==` to `===`, preserving all assertions and lifecycle/source proof.

Independent NEW-test-only SPEC and separate QUALITY reviews by
`search_observer_actual_review` passed on owning hash `1f894e91...`. Removing
only its six new contracts/helpers reproduces previous owning-test bytes
`cc1b231b...`. Synthetic proof does not replace actual Store/cold/warm evidence;
final implementation and complete-candidate reviews remain outstanding.

Task 6 repair 2 helper hash
`3a079c213115eb0329c2fd816ebe0ea42872cc5a67af3a58bfa430dce685db20`
passed pure rerun `15446`, exit 0, seed `215378`: **six pure tests in
1.5 seconds** (17 total, 11 integration excluded). Owning integration `36117`,
exit 0, same seed, passed **11 tests in 6.3 seconds** (17 total, six pure
excluded). Allocation `singularity_test_1c732137f9608f57104d50c4` was disposed
and PostgreSQL stopped. These results close the float-PID regression, not
the entire helper review.

Independent implementation SPEC review found a P2 evidence gap: the buffer
guard aggregates outer and nested candidate nodes, so candidate buffers alone
can satisfy it when every original outer node lacks buffer instrumentation.
The design requires original outer buffer proof independently. A new named
pure rejection contract is being added without changing the existing 17 tests.
This is the **second failed Sol repair round**: repair 1 failed pure validation;
repair 2 passed its existing tests but failed independent SPEC review. Bounded
Astra recovery is therefore authorized under the established escalation rule,
after the new RED is verified. No third Sol implementation repair or assertion
waiver is substituted for that escalation. Astra repair attempts remain zero
at this checkpoint; its earlier architecture consultation is counted separately.

The additional outer-buffer contract produced parent RED `80654`, exit 2,
seed `215378`: **only that new contract failed**, while the prior six pure
contracts passed in 1.5 seconds (18 total, 11 integration excluded). Current
formatted owning-test hash is
`495e08538802de389216c2bf59b57b1bc5b286370f118ed2343793252d74eeba`;
helper remained `3a079c21...`. The test first proves the valid closed baseline,
then removes all ten buffer fields recursively from only the original outer
plan and requires the fixed missing-evidence error. The existing 17 test
bodies were preserved. Independent pre-repair SPEC and separate QUALITY both
failed on that same P2, with no additional concrete findings.

`search_outer_buffer_astra_recovery` is now the sole helper writer for bounded
recovery, gate `SOL_REPEATED_FAILURE`, Astra attempt 1. Its ownership excludes
tests, production, SQL/settings/roles, documentation, and the original plan
test. The parent remains sole formatting, execution, and Git owner. A repair
is not qualified until the new pure contract, real owning tests, and independent
review all pass. E2E and publication remain prohibited.

Astra recovery attempt 1 helper
`cd5bc59deae22b3ba55e0676d5b252541ae14d14aa7c69b27cdaa9a175fc60e7`
passed parent pure `5167`, exit 0, seed `215378`: **seven tests in 1.2 seconds**
(18 total, 11 integration excluded), and owning integration `13257`, exit 0,
same seed: **11 tests in 5.4 seconds** (18 total, seven pure excluded).
Allocation `singularity_test_0218a3b9c64f00a90bfd55f6` was disposed and PostgreSQL
stopped. Independent SPEC closure and separate QUALITY closure by the nonauthor
`search_observer_actual_review` passed on those exact helper/test bytes.
The P2 is closed: only an executed original outer node can satisfy its buffer
requirement. Existing aggregate counters, test assertions, and lifecycle
baseline remain unchanged. Cumulative counters for this issue: two failed Sol
rounds, one successful Astra recovery attempt, zero failed Astra attempts.
This qualifies only the small helper, not the 8,192-row cold/warm plan gate.

Read-only preparation for the original plan test identified its existing
transaction-local settings assertion. The design and Task 6 explicitly retain
that exact assertion inside the helper, after completed capture/validation and
before the scoped transaction exits. It may not be dropped during the planned
observer-interface rewrite. This is remaining planned contract preservation,
not a reopening or broadening of the resolved Astra buffer repair.

That narrow preservation amendment passed independent doc-only SPEC and separate
QUALITY review by `search_observer_actual_review` at design SHA
`d5c26a3f614b89654ec3ccc5e64c6073324cfd7da897aa053d2daad4e56a084d`
and plan review checkpoint `be5ad1b8...`; the plan subsequently records this
reviewed design digest explicitly. Sol resumed only the remaining planned
helper assertion relocation and original four-contract plan rewrite. The
existing observer owning tests remain frozen, and no performance gate is
claimed passed before the rewritten real tests execute.

The remaining settings-assertion relocation and original plan rewrite are now
formatted at helper SHA
`780dede425cc42fad6988ce32f9d06e954616839439a20e944792de5386fc2e8`
and plan-test SHA
`298d78db00db2095bce11146a9ea7405f763f361ebf42eb6fa83d5ec3baeff2b`.
The owning test remains `495e0853...`; removing the helper's new search block
still reproduces original lifecycle SHA `87213eef...`. The four original test
names, 60-second test timeout, canonical fixture/builders/ANALYZE, query
strings, and ordinary five-second timeout test body are preserved. The
selective contracts now make seven actual searches per fresh observer backend
and additionally check exact immutable version/entry identity.

Parent pure rerun `89223`, exit 0, seed `215378`, passed **seven tests in
1.2 seconds** (18 total, 11 integration excluded). Owning real rerun `13888`,
exit 0, same seed, passed **11 tests in 5.4 seconds** (18 total, seven pure
excluded). Allocation `singularity_test_9ecb4fe2ff80bcd8c577d63a` was disposed
and PostgreSQL stopped. The original four-contract performance gate is now
running on these exact bytes; no result is yet claimed.

Independent source SPEC and separate QUALITY review of the protected untracked
runtime privacy test `17e6eeeb...` by `search_observer_actual_review` passed,
with no concrete findings. It covers all eight contracts and six content
canaries, supported/raw telemetry confinement, metadata stores, real
cancellation/retry/source denial, and bounded owned cleanup. Parent execution
evidence remains `75124` and combined `51110`; this source review did not rerun
tests or modify files and does not establish production or phase acceptance.

Original four-contract plan qualification `54358`, exit 0, seed `215378`,
passed **all four tests in 34.0 seconds** at helper `780dede4...` and plan
`298d78db...`. Each selective contract made exactly seven actual searches on
one fresh real-web observer backend: title-trigram backend `1653382` reported
one candidate call, one outer row/loop, and 50 buffer nodes on every sample;
FTS backend `1658973` reported the same counts with 49 buffer nodes. Both cold
sample 1 and warm samples 6/7 (and every intermediate sample) reported executed
`search_entries_fts`, `search_entries_title_trigram`, and
`search_entries_body_trigram`; the required index and exact immutable result
identity assertions passed. No replay or forced planner setting was used.

The unchanged one-/two-character cases returned 20 ranked rows plus a cursor
with 21 outer rows and measured **32,768 / 32,766 search-entry row visits**
across original inner and outer access nodes. These are accumulated visits,
not distinct canonical rows, and exceed the unchanged 90%-of-8,192 threshold.
Their access names were only Index Scan, Bitmap Heap Scan, and Seq Scan.
The unchanged ordinary uninstrumented five-second relation-lock timeout,
sanitized retryable error, settings/context rollback, and successful retry
also passed. Allocation `singularity_test_3ca65814357fad96e9b3f8a1` was disposed
and PostgreSQL stopped. Historical selective failure `69774` remains recorded;
this is its qualified owning repair, not full Phase 3 acceptance. Task 6
independent review and Task 8 combined/static gates remain in progress.

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs --seed 215378
```

Final bounded Task 6 independent SPEC and separate QUALITY review by
`search_observer_actual_review` passed on helper `780dede4...`, original plan
`298d78db...`, and owning test `495e0853...`, with no concrete findings. Its
read-only comparison confirmed byte-identical timeout-body and fixture-builder
sections and exact relocation of the original settings query. All 13 Task 6
checklist items are now complete. Those three files alone were committed
locally as `becc2eff733254dc1c8c13f6ca7db3ac8484753f`
(`test(storage): qualify actual nested cold and warm search plans`).

Parent Task 8 static/focused gate `24357`, exit 0, seed `215378`, passed full
format checking, compilation with warnings as errors, and xref with zero cycles.
It passed **118 executed pure/property/architecture tests**: storage 19 in
2.6 seconds (77 total, 58 integration excluded), retrieval 26 in 0.6 seconds,
runtime 27 in 1.4 seconds (47 total, 20 integration excluded), and web
architecture 46 in 1.8 seconds. No assertions or architectural baseline hashes
were relaxed. The combined five-file search integration batch is now running
on the committed candidate; final Task 8 review/cleanup/handoff remains pending.

That combined search batch `14560`, exit 0, seed `215378`, passed **86
integration tests in 94.1 seconds** (93 total, seven pure excluded) on
`becc2eff...`. In the combined fixture population, the short cases measured
33,002 / 33,000 row visits. Both selective seven-call sequences again retained
one candidate invocation and one outer row/loop, with every required executed
index present: title backend `3598792` had 49 buffer nodes cold and 52 in
samples 6/7; FTS backend `3604185` had 49 cold and 51 in samples 6/7. No assertion
or planner setting changed. Allocation `singularity_test_e0b908577667c6f4472ca08c`
was disposed and PostgreSQL stopped.

All Task 8 owning batches have now passed: search `14560` (86), migration/
role/schema/RLS `84484` (109), runtime/projection/privacy `51110` (66), restore
compatibility `71569` (36), and complete V1/V2 restore `90085` (exit 0). These
are scoped counts, not distinct-test totals; earlier runs before `becc2eff...`
used byte-identical production and owning regression files, with only the
subsequently qualified test-only observer/plan changes added. The exact clean-SHA
ordered README gate remains separate and incomplete.

The nonauthor `search_observer_actual_review` completed independent
**complete-candidate SPEC and separate QUALITY source reviews**, both PASS,
with no concrete findings. Scope: all 83 tracked changes from accepted Phase 2
`c34935a...` through `becc2eff...`, plus protected untracked privacy test
`17e6eeeb...` and reviewed design `d5c26a3...`. It audited the full inventory
and cross-boundary contracts, reusing unchanged scoped reviews. This does not
convert prohibited E2E or unrun full README checks into success, nor accept
Phase 3. Final evidence-document synchronization and cleanup remain pending.

Fresh privacy owning rerun `19825`, exit 0, seed `215378`, passed **all eight
integration contracts in 13.3 seconds** on final guarded-search code. Its
frozen SHA remains `17e6eeeb...`. Allocation
`singularity_test_1be7772cad85b707ed15a37b` was disposed and PostgreSQL stopped.
Only that independently reviewed file was committed locally as
`996fdbea5284fdbd6cd12c7fd3df9ba60d861596`
(`test(runtime): guard unified search diagnostic privacy`). The complete
source-review scope is unchanged in bytes; the extra file is now tracked.

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs --seed 215378
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_runtime/test/singularity/runtime/knowledge_search_privacy_test.exs --seed 215378
```

Final repair cleanup inventory `40529`, exit 0, verified **zero generated test
databases and zero recorded storage roots**, including the entire V1/V2 restore
allocation and every diagnostic/repair attempt; owned PostgreSQL stopped.
All parent commands and worker execution commands are terminal. Existing helper
owning tests verify collector/Repo/monitor/trace teardown and removal of only
owned observation defaults on success and failure. Current Markdown-link
validation found all 22 local links valid across the repair design/plan,
Phase 3 plan, and this evidence report; `git diff --check` is clean.

Root/main remains clean at `e866990f...`; Phase 2 verification remains clean at
`c34935a...`; Phase 2 implementation remains at `ff703bd7...` with only its
protected untracked integration plan, SHA `350a6557...`, unchanged. The legacy
Note concurrency test is still `d49e2288...`; production candidate migration
and Store retain exact qualified hashes `5254c585...` and `53e4b3ba...`.
No Vault feature work, production data/backfill/activation, merge, push, version
bump, tag, release, deployment, or E2E occurred. Scoped repair evidence is ready
for final document review and local handoff commit; broader Phase 3 verification
and the explicitly prohibited E2E gate remain outstanding.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted, compile --warnings-as-errors, xref graph --format cycles --fail-above 0, test apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_cursor_test.exs apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_observer_test.exs apps/singularity_retrieval/test/singularity/retrieval/knowledge_search_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/search_rebuild_test.exs apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_storage/test/singularity/storage/postgres/search_candidate_migration_test.exs --seed 215378
```

## Earlier local hygiene for the failed-plan qualification slice

Session `43627` exited 0: both new tests format correctly, compilation with
warnings as errors passes, and xref reports zero cycles. Exact command:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_search_privacy_test.exs, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
devenv shell -- bash .devenv/phase3-cleanup-inventory.sh
```

The final read-only cleanup inventory (`01ef6a`, exit 0) verified zero generated
test databases and absence of all recorded storage roots, including every
privacy and diagnostic attempt. The owned PostgreSQL instance was stopped.
No additional Task 11 commit was made while its required gate remains failed.
The independent scoped evidence review passed: counts, failed-gate history,
frozen hashes, local links, and design/publication boundaries are consistent.
This is not the outstanding complete-candidate specification/quality review.
At that diagnostic checkpoint, final Git/hash checks verified unchanged root/main and the two protected
Phase 2 worktrees, the preserved untracked Phase 2 integration plan, and the
byte-identical original Note concurrency test. Task 11's two tests and this
report were then untracked, with only the plan/evidence subsection modified;
the subsequent governance changes are recorded separately above.

| Gate | Status |
| --- | --- |
| Selective real-role FTS/trigram query plans on analyzed fixtures | PASS: cold/warm actual-call owning gate `54358`; historical failure `69774` retained |
| Honest short-query limitation and fixed-timeout error | PASS: owning gate `54358`; earlier `69774` retained |
| Runtime content-canary/privacy/cancellation/retry contracts | PASS: fresh eight-contract owning run `19825` and combined `51110`; prior failures retained above |
| All new and directly affected PostgreSQL suites | NOT RUN for final candidate |
| Complete V1/V2 restore | PASS: `90085` on guarded-function production source; exact clean-SHA ordered gate remains NOT RUN |
| Exact clean-SHA ordered README gate | NOT RUN |
| Manual E2E | NOT RUN under user restriction |
| Final independent complete-candidate specification/quality source review | PASS: `search_observer_actual_review`, all tracked Phase 3 changes plus the exact privacy test now committed at `996fdbea...`; phase acceptance remains separate |

## Preserved risks and boundaries

- The earlier five-second Note-reconciliation concurrency timeout remains
  **NONREPRODUCED**, with unchanged passing reruns; its cause is not established
  and it was neither repaired nor waived. Task 11 must preserve that history.
- The Phase 2 login-readiness race and Poppler qualification limitations remain
  as recorded in the [Phase 2 handoff](2026-10-09-phase-2-acceptance.md).
- No live deployment or production initial backfill has occurred. Before any
  separately authorized activation, the already-running authenticated Runtime
  must perform the guarded `Api.rebuild_search(existing_session, :all)` step
  described in Task 9 and verify canonical search results.
- Root/main, other worktrees, and the protected untracked Phase 2 integration
  plan are outside this task and remain preserved.

No green subset above is full Phase 3 or `0.2.0` release acceptance.
