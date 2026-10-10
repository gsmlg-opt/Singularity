# Phase 3 guarded search-index repair

Date: 2026-10-10. Status: architecture handoff for independent review and a
detailed implementation plan under the user's continuous-development authority.
This document is not implementation, test success, or Phase 3 acceptance.

## Scope and evidence

This amendment repairs the selective-index qualification failure of the
[Phase 3 design](2026-10-09-singularity-v0.2-phase-3-unified-lexical-search-design.md)
at source `191e58691eac2413fec3b0b302397775fe527aff`. The
[qualification record](../../verification/2026-10-09-phase-3-acceptance.md)
retains the actual commands, failed assertions, and causal probes.

Session `69774` executed four contracts: selective FTS and trigram plans failed;
short-literal nonselectivity and the five-second cancellation/retry passed.
Probes `93912` and `11736` established that forced web RLS prevents the text
predicates from becoming index conditions. With unchanged RLS and planner
settings, the existing table-owner policy permits the FTS index; `11736` also
demonstrated the title-trigram index. The earlier owner-trigram sequential scan
remains unexplained cost/physical variation: explicit pending-list cleanup in
`11736` returned zero and did not cause its already-indexed plan.

The indexes exist and are valid/ready. PostgreSQL rejects a non-leakproof
restriction as an index condition when a lower-security restriction must precede
it. The actual `@@`, `ILIKE`, and trigram `%` implementations are not leakproof.
This is expected PostgreSQL security behavior, not an upstream dependency bug.
See PostgreSQL 17's [index qualification](https://raw.githubusercontent.com/postgres/postgres/REL_17_STABLE/src/backend/optimizer/path/indxpath.c)
and [security promotion check](https://raw.githubusercontent.com/postgres/postgres/REL_17_STABLE/src/backend/optimizer/util/restrictinfo.c).

No change to Vault behavior, role attributes/memberships, RLS policies or flags,
operator/function leakproof flags, existing migrations, canonical writes, search
policy version, API shape, cursor domain, or production data is authorized by
this amendment. E2E remains prohibited. No publication or deployment occurs.

## Decision and alternatives

Add one guarded, read-only, table-owner-owned candidate-ID function. Keep the
existing outer web-role query responsible for final canonical visibility,
content, rank, and pagination. This contains privileged execution in a fixed
candidate-selection operation and preserves the existing public read boundary.

Alternatives rejected:

1. More indexes, planner forcing, or OR-to-UNION alone: none removes the web
   security-level restriction. Disabling RLS or marking operators leakproof is
   not an acceptable repair.
2. Materialize all RLS-authorized entries before text matching: safe isolation,
   but it still scans the owner's candidates and cannot provide the required
   base-table selective content-index evidence.
3. Move the complete ranked search into a definer: potentially workable, but
   unnecessarily moves content-returning SQL, cursor comparisons, and final
   visibility behind elevated execution. It is not the selected boundary.

## Database interface and authority

The sole new callable interface is:

```sql
content.search_candidate_ids(
  requested_q text,
  requested_kind text,
  requested_tag_ids uuid[]
) RETURNS TABLE (entry_id text)
```

Use `LANGUAGE plpgsql VOLATILE SECURITY DEFINER PARALLEL UNSAFE`, owned by
`singularity_table_owner`. Do not use `STRICT`: null arguments must fail, not
silently return an empty set. Fix `search_path` to
`pg_catalog, content, core, identity, pg_temp`, qualify application objects and
extension operators/functions, and set the function-local
`pg_trgm.similarity_threshold` to `0.3`. Do not set or disable `row_security`,
alter planner settings, introduce a cost/row-count tuning override, or reset the
active statement timer inside the function.

Revoke all function privileges from PUBLIC and every runtime role, then grant
EXECUTE only to `singularity_web`. Preserve the table's existing ENABLE/FORCE
RLS, owner policy, web SELECT grants, and all runtime DML denials. No new role,
extension, administrative repository, or runtime administrator credential is
introduced. Explicit schema qualification and trusted-path ordering must make
temporary or caller-path object shadowing ineffective.

The function accepts no owner, principal, session, classification, connection,
role, limit, cursor, ranking option, pattern, SQL, or diagnostic selector.

Before any projection/canonical content scan:

1. Reject null/empty `requested_q`, text exceeding 1,024 UTF-8 bytes, a null kind
   or a kind outside `note`/`document`/`all`, null tag arrays, multidimensional arrays,
   more than 20 elements before deduplication, or null tag elements. PostgreSQL
   text/UUID input types enforce their own encoding/type constraints. Public
   normalization, Unicode trimming, UUID canonicalization, and unknown-field
   rejection remain in the existing query validator; the function consumes
   that normalized query rather than introducing a second normalization policy.
2. Require READ COMMITTED. Parse principal and owner only from existing
   transaction-scoped `singularity.principal_id` and `singularity.vault_id`.
   Missing, empty, or malformed context fails closed.
3. Acquire the existing shared transaction authorization lock, using exactly
   `hashtextextended('singularity:authorization:' || principal::text || ':' ||
   owner::text, 0)`. Do not acquire a new Vault lock or reverse the established
   runtime lock order. `OperationScope.with_read_request/4` remains unchanged;
   its existing authorization lock is compatible with this shared lock.
4. In a subsequent SQL command, read unchanged
   `core.live_principal_authorization()`. Require matching principal/owner,
   owner principal kind, active account (already enforced by that function),
   non-revoked principal/membership, and private-or-higher clearance. Require
   `note.read` for Note, `asset.read` for Document, both conjunctively for all.
   No partial-kind fallback is allowed. Follow the established guard in
   migration `20261009000200_unified_search_reconciliation.exs`, without editing
   it or the existing authorization functions.
5. Only then read candidate content. Do not treat these database IDs or checks
   as session authentication. Existing runtime session validity/epochs and
   Note/mixed unlock requirements remain mandatory; Document-only reads retain
   their existing no-unlock requirement. No login, unlock, or custody action is
   added to the function.

Use fixed, content-free errors: input failures raise SQLSTATE `23514` with
`search candidates input is invalid`; context/isolation/authority failures
raise `42501` with `search candidates are not authorized`. Do not interpolate
arguments or add DETAIL/HINT content. Existing `KnowledgeError.from/1` maps
these to sanitized invalid/forbidden errors. Unexpected database errors and
cancellation retain the existing sanitized retryable storage error path.

## Candidate and outer-query invariants

The function returns a distinct, uncapped set of eligible `entry_id` values,
never content text, locators, tags, scores, owner IDs, counts, or plans. Entry identities
are existing immutable-source identities; no new persisted record is created.

Within fixed SQL, form the union of four matching branches: simple weighted
FTS, escaped case-insensitive title substring, escaped body substring, and
title similarity when `char_length(requested_q) >= 3`. Build the escaped literal
pattern internally from the query, escaping backslash, percent, and underscore
exactly as the existing store does. Use the existing three GIN indexes. A
`UNION` of entry identities followed by canonical validation is recommended to
keep each branch independently indexable; no per-branch LIMIT or top-k cutoff
is permitted. There is no dynamic SQL or user-selected identifier.

Before emitting an identity, enforce the complete existing canonical joins:
matching derived owner/private classification/kind, non-tombstoned resource,
entry version equal to current head, matching immutable resource version,
typed Note existence or ready typed Document plus exact fragment identity and
ordinal. Apply every requested tag using the same owner-bound canonical
membership/tag AND predicates; unknown or foreign tags yield no identities.
Preliminary text matches inside the function are not an externally visible
candidate set. Stale, historical, conflict, non-ready, deleted, foreign, and
wrong-kind identities must never be returned by this interface.

For nonempty queries, `KnowledgeSearchStore.statement/1` adds one materialized
candidate-ID relation, invoking the function once with the existing q/kind/tags
bindings, then joins it by `entry_id`. Retain the outer query's original
owner/classification predicates, canonical joins, tag predicates, text
predicate, combined rank expression, scored materialization, ordering, cursor
comparison, and final `limit + 1`. This deliberate second validation keeps the
web-role RLS path authoritative for returned content. Do not duplicate ranking
inside the function or change the existing 13 parameter bindings.

**Empty q stays on the existing direct web-RLS path**, with no candidate
function call and rank zero. It needs no content-index repair. A direct empty-q
function invocation is invalid rather than an alternative privileged listing.

The store still sets the transaction-local five-second timeout before the actual
search statement. That timer covers candidate authorization waits, selection,
and the outer query together; the function must not restart or extend it. Keep
the existing cancellation, rollback, connection-setting cleanup, and retry
contract unchanged.

### Snapshot position

VOLATILE is intentional: after waiting for the shared authorization lock, the
subsequent authority query must see a revocation committed by the preceding
exclusive holder. Do not label this lock-taking operation STABLE. PostgreSQL
uses fresh command snapshots inside VOLATILE functions, while the outer query
retains its own statement snapshot. See [function volatility](https://www.postgresql.org/docs/17/xfunc-volatility.html).

Therefore candidate emission and outer content validation can observe different
committed head/tag states during concurrent changes. Their identity intersection
is conservative: it can omit a concurrently changed resource, but cannot
substitute another version, expose a source rejected by either validation, or
create duplicate identities. Unchanged eligible sets retain complete membership,
rank, order, and pagination. This amendment explicitly records that conservative
READ COMMITTED behavior; it does not promise a new frozen per-page or cross-page
snapshot. Controlled concurrency tests must verify immutable source coherence
and fail-closed visibility, not bless a mismatched source. If a stronger atomic
single-snapshot completeness guarantee becomes a requirement, stop and redesign
the boundary rather than misclassifying volatility or silently accepting drift.

## Authoritative executed-plan observation

Use PostgreSQL 17's bundled `auto_explain` only in a newly allocated synthetic
integration database and only on a dedicated real-web-login connection. Its
executor hook can observe nested statements and emit analyzed JSON at NOTICE
level. The locked Postgrex implementation retains these notices in
`Postgrex.Result.messages` (`result.ex`; `protocol.ex:handle_msg/3` and `done`).
This allows actual inner execution to be inspected in memory without a
production plan-returning function or a copied SQL reconstruction.

Sources: [auto_explain settings](https://www.postgresql.org/docs/17/auto-explain.html)
and its [executor hook](https://raw.githubusercontent.com/postgres/postgres/REL_17_STABLE/contrib/auto_explain/auto_explain.c).

### Test-only setup and isolation

Add a helper under `apps/singularity_storage/test/support/`, with any external
administrator wrapper also under that test directory. Reuse the established
administrator credential transport pattern, not its production bootstrap SQL.
No administrator Repo or credential enters application configuration.

The helper must require MIX_ENV=test, the exact currently allocated
`singularity_test_[0-9a-f]{24}` database, verified connection identity, and the
parent-owned isolated test lifecycle. Reject application/production databases,
arbitrary roles/settings, missing identity, and pre-existing conflicting
database-role defaults. Never set cluster-wide defaults or modify production
bootstrap, runtime configuration, or migration logging.

Install the allowlisted defaults atomically in one administrator transaction;
remove those same owned defaults atomically after connecting. Partial setup or
cleanup failure must be reported and recovered before another test is started,
not concealed by dropping the connection alone.

Through the external administrator only, temporarily install these
`ALTER ROLE singularity_web IN DATABASE <exact test database> SET ...` defaults:

| Setting | Value |
| --- | --- |
| session_preload_libraries | auto_explain |
| auto_explain.log_min_duration | 0 |
| auto_explain.log_analyze | on |
| auto_explain.log_nested_statements | on |
| auto_explain.log_format | json |
| auto_explain.log_level | notice |
| auto_explain.log_parameter_max_length | 0 |
| auto_explain.log_timing | off |
| auto_explain.log_buffers | on |
| auto_explain.log_verbose | off |
| auto_explain.sample_rate | 1 |
| client_min_messages | notice |
| log_min_messages | warning |

Verify existing inherited preload/logging configuration before setting defaults;
do not silently replace other preloads or logging policy. PostgreSQL 17 marks
`session_preload_libraries` and `shared_preload_libraries` as
`GUC_SUPERUSER_ONLY`: the real Web login cannot read them. The observed `42501`
requires split evidence, not a new grant or treating denied inspection as success.

The external administrator verifies the empty global preload baseline through
`pg_settings.setting`, `source`, `reset_val`, and `pending_restart`. Reject
administrator-specific role/database/client/session overrides that could mask
the baseline; that administrator session does not expose another backend's
settings. Inspect all applicable global, database, Web-role and Web-role/database
catalog defaults. Reject every pre-existing `auto_explain.*` key and conflicting
preloads, not just keys being installed. Preserve compatible inherited logging
defaults. Snapshot the exact catalog footprint and require exact restoration;
reset only keys owned by this helper.

Close startup override paths in the actual effective RequestRepo configuration
and URL parameters: reject caller options, observation/preload parameters,
`after_connect`, and `configure` hooks. A pure test predicate may validate
synthetic configurations, but cannot supply options to the observer. A fixed
regression fixture may set compatible logging defaults on the allocated test
database only, then restore its own exact footprint; no cluster-wide setting
is authorized.

There is no SET privilege grant, `pg_read_all_settings` membership, privileged
inspection function, role-attribute change, or SET ROLE impersonation. Connect
as the actual `singularity_web` login and verify both users, database/backend,
empty readable `local_preload_libraries`, every expected readable auto_explain
setting, logging thresholds, RLS, and the normal sequential-scan setting. Remove
the owned defaults before the callback. The dedicated session retains its
startup settings; future sessions must not inherit them. Actual analyzed nested
NOTICE evidence remains mandatory; configuration checks cannot replace it.

After reset, a fresh ordinary Web connection must show no registered
`auto_explain.*` rows in `pg_settings` and no plan NOTICE from a fixed read-only
probe, alongside its normal identity/settings. Custom settings appear in that
view after the defining module loads; this proves ordinary-session isolation
without pretending to read its hidden preload GUCs.

This 2026-10-10 correction was provided by Astra under `PROJECT_ARCHITECTURE`
after the observed failed prerequisite. Primary references:
[PostgreSQL 17 GUC visibility](https://raw.githubusercontent.com/postgres/postgres/REL_17_STABLE/src/backend/utils/misc/guc_tables.c),
[pg_settings provenance](https://www.postgresql.org/docs/17/view-pg-settings.html),
[login-time role settings](https://www.postgresql.org/docs/17/sql-alterrole.html),
and [auto_explain](https://www.postgresql.org/docs/17/auto-explain.html).

Use a test-only **real Ecto.Repo** with one fixed private module/name and pool
size one, started from the validated real RequestRepo connection configuration.
Pass this module explicitly to the observer callback and unchanged production
`ScopedRepo.transact/3`, SafeSQL, and later `KnowledgeSearchStore.search/2`.
These production functions already accept the Repo module; no SQL copy, fake
authorizer, adapter replacement, privileged login, or production SafeSQL change
is involved. A name collision fails closed and never stops an existing process.
Stop only the newly returned owned Repo PID and confirm termination.

This replaces the initially proposed dynamic RequestRepo binding: the locked
Ecto SQL raw-query API resolves an atom through the Repo registry directly,
whereas generated Repo transaction methods honor dynamic selection. Probe
`87856` confirmed the initial mismatch by reporting the ordinary backend's
missing/unregistered observation settings. Combining those APIs through a
dynamic module binding therefore did not prove one observed scoped connection.

Leave the shared RequestRepo PID and its process-local dynamic selection
unchanged throughout. For fresh ordinary-session controls, start an unnamed
RequestRepo and pass its **PID explicitly** to SafeSQL for fixed read-only
checks; it performs no scoped transaction. This permits `clean?/1` during the
named observer callback without a name collision. Never change application
environment or inherit an observed connection into unrelated tests. Both real
Repo paths retain log/telemetry suppression and explicit identity checks.

NOTICE is below the configured server logging threshold. Parameter logging is
disabled, but **plan expressions can still contain literals**: these are not
redacted plans. Only synthetic fixtures may ever use this observer. Raw notices
stay in process memory; never emit them through Logger, telemetry, artifacts,
failure inspection, or persisted reports. Export only closed numeric counters,
known index/node names, and bounded pass/fail identifiers. Existing production
and privacy tests remain uninstrumented, with their no-content assertions intact.

Cleanup must preserve shared/dynamic RequestRepo state, stop the owned observer connection,
remove only owned temporary settings, remove owned trace patterns/flags, drain
the collector, and let the parent dispose of its database/root. Verify no
database-role observation settings remain and a fresh ordinary web connection
has observation disabled. Handle setup failure halfway through just as strictly
as successful completion; never RESET ALL or stop another owner's process.

### Evidence captured from the actual call

Extend the existing process-specific SafeSQL trace with return tracing and
call/return correlation. Observe the raw result of the **actual**
`KnowledgeSearchStore.search/2` search statement, including its Postgrex backend
connection ID and notices, before the unchanged store maps rows into a page.
Use the delivery barrier and unconditional cleanup already established by the
plan test. No production callback, telemetry event, or debug flag is added.

Select analyzed inner plans belonging to the candidate function's fixed
candidate SELECT, identified by its static source marker and PL/pgSQL context;
tie them to that actual outer call/connection. Validate the deployed function
identity/definition against the tested migration. Other nested authorization
queries and catalog/fixture/setup plans are not candidate evidence.

Require the named content index in an executed candidate plan node with
`Actual Loops > 0`, plus the original positive result identity, rank, and row
count checks. The FTS fixture requires `search_entries_fts`; the typo fixture
requires `search_entries_title_trigram`. Neither a Function Scan, an unused
index node, aggregate index counters, owner-only diagnostic query, nor EXPLAIN
of copied function SQL satisfies this requirement. The existing outer analyzed
plan remains useful for final row count and whole-query shape, not inner proof.

The instrumentation must first be proven on an existing read-only definer
(`core.live_principal_authorization()`) through the real scoped observer
connection. This feasibility check precedes production implementation. Absence
of the bundled module, insufficient external administrator authority, missing
notices/analysis fields, or uncontrollable observation leakage is a failed
environment/evidence prerequisite, not permission to weaken the check.

Keep the deterministic 8,192-source fixture, bounded fixture-building
transactions, ANALYZE, and unforced planner settings. If normal GIN maintenance
is needed for deterministic post-load qualification, explicitly maintain all
three fixture indexes uniformly before measurement and record it; never claim
the prior zero-page cleanup repaired anything. Exercise repeated calls on the
same backend past the usual PL/pgSQL plan-cache warmup; do not force custom or
generic plans. Instrumentation overhead must not justify increasing the product
deadline. Missing executed plans or timeout remains a failed qualification.

## Forward migration and compatibility

Use a new forward-only migration
`20261010000000_create_guarded_search_candidates.exs` (verify the version remains
unused before implementation). It creates only the function and its explicit
ownership/ACL/configuration. Existing index, projection, canonical, role, and
extension migrations remain byte-identical. No backfill, data rewrite, backup
format, or projection schema change is needed. Existing V1/V2 restore guards
remain authoritative; the new function is recreated by migrations, not exported
as canonical backup content.

Storage-only direct-search fixtures previously tested owner RLS without read
capability rows. Seed the existing required capability assignments explicitly
in those owning fixtures before successful nonempty searches. This is real
authorization data, not a temporary database grant. Do not change the shared
`Fixtures.two_vaults!/0` or `KnowledgeFixtures.source!/0` defaults, auto-grant on
every search invocation, or regrant revoked authority inside negative tests.

Expected implementation scope is the new migration, `KnowledgeSearchStore`,
new candidate-authority integration contracts, the plan test and its test-only
observer helper/wrapper, narrowly affected direct-search fixtures, and Phase 3
plan/evidence. Existing runtime/API modules, SafeSQL, authorization functions,
Vault modules, and general bootstrap are not implementation targets. The Sol
plan must enumerate the exact affected fixture files before edits.

## Acceptance and implementation order

1. Prove the real-role NOTICE/nested-plan capture prerequisite without changing
   production code; validate observer teardown and lack of configuration leakage.
2. Add failing real-role function contracts, then implement the forward migration
   and narrow store join. Fresh and historical migration paths must yield exact
   signature, owner, VOLATILE/definer/parallel flags, trusted path, threshold,
   ACLs, and unchanged RLS/role/index state.
3. Test web success by each required capability, mixed conjunction, and direct
   EXECUTE denial for PUBLIC/unrelated roles, worker, dispatcher, and preauth.
   Assert helper absence (there is no additional callable privileged helper).
4. Test null/oversized/invalid q/kind/tags, malformed/missing context, wrong owner,
   revoked principal/membership/capability, inactive account, insufficient
   clearance, non-owner principal, and unsupported transaction isolation. Errors
   stay content-free, and no invalid call returns a falsely complete empty set.
   The unchanged `vault_members_classification_check` permits only private,
   sensitive, or restricted membership clearance. A public-only membership is
   therefore an impossible persisted state: prove its UPDATE is rejected by
   that exact existing constraint, the membership remains private, and the
   legitimate candidate control and canonical snapshot remain unchanged.
   Do not disable the constraint, invent authorization doubles, or claim the
   candidate function executed with public clearance. This qualification
   correction follows the actual fixture failure in parent run `93996`; the
   production private-or-higher guard and frozen schema remain unchanged.
5. Reproduce revocation while the function waits behind the existing exclusive
   authorization lock; observe the wait, commit revocation, release, and require
   denial from the post-lock authority read. Verify wrong-key locks do not
   satisfy the test barrier. Preserve runtime expired/locked/underprivileged
   session denials and Document-only no-unlock behavior.
6. Directly test candidate canonical/tag constraints, including deliberately
   stale projections, tombstones, historical/conflict versions, non-ready
   Documents, wrong fragments, foreign tags, and multiple matching branches.
   Verify identity deduplication and no candidate cutoff. Controlled head/tag
   changes must never yield incoherent or unauthorized content; unchanged data
   must exactly match the original ordered result/rank/cursor contracts.
7. Pass both selective actual-call nested index contracts, honest short-literal
   evidence, and the unchanged observed five-second timeout/clean retry. For
   short literals, account for scan work inside candidate execution as well as
   the outer query; counting only the outer narrowed relation is insufficient.
   Keep empty-q behavior and original outer-query results as positive controls.
8. Run owning search/pagination, runtime authorization/privacy, rebuild/restore,
   role/migration, and architecture gates. Obtain independent specification and
   quality review. Then return to the remaining Phase 3 qualification plan;
   no scoped green subset establishes phase acceptance or overrides the E2E
   prohibition.

## Self-review and remaining proof obligations

Self-review checked scope, concrete signature, privilege ownership, null/error
behavior, canonical/tag validation on both sides, volatility/snapshot semantics,
empty-query compatibility, deadline ownership, and observation cleanup. No
implementation, dependency, or Vault redesign is hidden in the observer.

No user choice is outstanding. Technical proof is still required for real-role
auto_explain delivery, bounded overhead within five seconds, actual inner plans
on cold/warm calls, the new guard's revocation race, concurrency coherence, and
all regression gates. The design does not predict those checks passed. Failure
must return concrete evidence to the coordinator; it must not cause an index
assertion waiver, policy weakening, broader credential use, or production plan
logging.
