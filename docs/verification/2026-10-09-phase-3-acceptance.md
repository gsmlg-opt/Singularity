# Phase 3 unified lexical search qualification

## Current status

**IN PROGRESS — Phase 3 is not accepted.**

Qualification baseline: `191e58691eac2413fec3b0b302397775fe527aff` on
`codex/v0.2-phase-3-search-design`, in the project-local Phase 3 worktree.
The approved implementation is locally complete through Task 10. Task 11's
privacy contracts pass locally; its selective query-plan gate fails. Query-plan
recovery, complete affected-suite checks, independent final reviews, and
exact-clean-SHA README acceptance remain outstanding.

The bounded Astra diagnosis is complete. The user's 2026-10-10
[continuous development authorization](../../AGENTS.md#continuous-development-authorization--2026-10-10)
removes the former routine approval blocker. Its proposed repair now proceeds
through a documented architecture amendment, detailed plan, new forward
migration, verification, and independent review. The failed index gate remains
failed until actual executed-plan evidence proves the repair.

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
| Selective real-role FTS/trigram query plans on analyzed fixtures | FAIL: two selective content-index assertions, `69774` |
| Honest short-query limitation and fixed-timeout error | PASS: two owning contracts, `69774` |
| Runtime content-canary/privacy/cancellation/retry contracts | PASS: eight owning contracts, `75124`; prior failures retained above |
| All new and directly affected PostgreSQL suites | NOT RUN for final candidate |
| Complete V1/V2 restore on final candidate | NOT RUN; Task 10 scoped oracle passed |
| Exact clean-SHA ordered README gate | NOT RUN |
| Manual E2E | NOT RUN under user restriction |
| Final independent complete-candidate specification/quality review | NOT RUN |

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
