# Phase 3 full-gate repair: test-owned Document lifetimes

Date: 2026-10-10. This test-only repair follows the
[continuous authorization](../../../AGENTS.md#continuous-development-authorization--2026-10-10).
Exact design/plan SPEC and separate QUALITY review passed with nonauthor
`search_observer_actual_review`. Implementation still requires verification and
independent review, not another routine human approval. Phase 3 remains unaccepted.

## Evidence

The clean full integration run `37888`, seed `918339`, failed one Runtime
restart recovery case and seven reconciler cases. The latter observed extra
expired attempts and recovery returning `:invalid` rather than success.
The integration harness shares one generated database across the umbrella;
`DataCase` does not roll every test back.

Source diagnosis found two concrete poison producers: the staged-fragment
tests in `knowledge_search_store_test.exs` and `search_candidate_ids_test.exs`
leave authorized, extracting Documents live after their tests. Once the real
180-second deadline expires, global recovery can select them. Recovery changes
state to pending while staged fragments remain, which violates the existing
completion constraint. Other lifecycle fixtures likewise leave recoverable
attempts beyond their owning tests. This proves a fixture-lifetime defect;
it does not identify every UUID from the failed full-run inventory or establish
that every Runtime failure has this single cause.

## Decision

Add an explicit test-support function
`KnowledgeFixtures.retire_document_on_exit!(document)`. It registers an ordinary
ExUnit `on_exit` callback from the owning test/setup process, captures only the
exact binary resource and owner IDs, and returns the registration result `:ok`.
The callback reuses the existing reconciler-test retirement SQL through
`Fixtures.with_owner` and the raising query helper:

```sql
UPDATE content.resources
SET deleted_at = clock_timestamp()
WHERE id = $1 AND vault_id = $2 AND deleted_at IS NULL
```

Zero rows is valid for an already-retired or mismatched selector. Do not assert
exactly one update. Keep canonical resources, versions, typed rows and fragments;
do not delete them or rewrite attempts. Do not catch registration, repository,
transaction, or SQL failures. No production recovery filter, error handling,
deadline, authorization, or lifecycle constraint changes are needed.

Keep `document!`, `insert_document!`, and `ready_document!` unchanged. An implicit
constructor hook is unsafe: historical tests can close/drop their private
database before the test's callbacks run, restoring the umbrella repository
configuration. Those historical/private-database fixtures remain governed by
their existing database disposal, not this helper.

Register immediately after successful creation, before claims or spawned work.
Later runner-stop callbacks then execute first in ExUnit's reverse registration
order. A module-local wrapper may consolidate registrations in the lifecycle
test, but there is no global fixture default change.

## Bounded registration sites

Storage tests, under `apps/singularity_storage/test/singularity/storage/`:

- `postgres/knowledge_search_store_test.exs`: only the staged-fragment fixture.
- `postgres/search_candidate_ids_test.exs`: only the staged-fragment fixture.
- `postgres/document_worker_repository_test.exs`: common Document setup.
- `document_lifecycle_test.exs`: each of its test-owned Document creations.

Runtime tests, under `apps/singularity_runtime/test/singularity/runtime/`:

- `document_extraction_reconciler_test.exs`: all test-owned Documents; replace
  its existing local retirement helper with the shared equivalent.
- `document_extraction_runtime_restart_test.exs`: the restart fixture.
- `document_extraction_job_test.exs`: the source-fixture and private-Document
  creation helpers, including the separately created private-title Document.

Do not register cleanup in `MigrationTestEnvironment.with_database` scopes or
the typed-head migration module's separately disposed database. Failed inserts
with asserted zero persisted rows require no hook. These sites follow an
independent caller/lifetime inventory, not a mandate to edit all Document tests.

## Deterministic new contracts

Add `knowledge_fixtures_test.exs` with two integration cases and one pure case.
Use ordinary verification callbacks registered before retirement so they run
after it; do not use ExUnit internals, polling or artificial sleeps.

1. Correct resource/owner selection retires only the target, while same-owner
   and foreign-owner controls remain live. A deliberately mismatched owner
   selector changes nothing. Compare complete version, typed-Document and
   fragment snapshots before/after, and prove registration itself changes no row.
2. A pre-tombstoned target registered twice retains its exact tombstone timestamp
   and canonical snapshots. This proves zero-row/idempotent cleanup.
3. Registration in a `Task` with synthetic IDs raises the existing unsupported
   process `ArgumentError`; the helper must not hide that failure. No database
   is needed for this case.

Controls may receive their own later cleanup after verification, without
weakening the assertion that target cleanup leaves them untouched.

## Verification and non-goals

Run the new contracts RED before adding the helper, then GREEN. Re-run the
two concrete poison-producing tests followed by the unchanged real three-minute
Runtime restart/reconciler tests. Run all seven affected owning files; keep all
existing assertions, capabilities, source checks, real deadlines and barriers.
The separately diagnosed ready-restore event contract is not repaired here;
if encountered, record it as the known separate failure, not a passing batch.

Independent SPEC then separate QUALITY review and a small local commit are
required. Full clean-SHA README qualification must be rerun after all repairs.
No production code, migration, Vault feature/semantics, source provenance,
backup format, E2E, publication, deployment or production data changes belong
to this slice. The two selective-plan failures and Runtime event contracts
remain separate workstreams.
