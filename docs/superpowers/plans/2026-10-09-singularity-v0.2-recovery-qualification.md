# Singularity v0.2 Recovery Qualification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Qualify existing recovery catalog restrictions and atomic successor-event collision rollback in real PostgreSQL.

**Architecture:** Extend the existing owning integration test with real WorkerRepo calls and table-owner fixture observations. Preserve production SQL and every existing assertion. Parent owns execution, evidence, and Git; the implementation worker owns only the existing test file.

**Tech Stack:** Elixir/ExUnit, Ecto/Postgrex, PostgreSQL catalogs, existing integration runner.

---

Design: `docs/superpowers/specs/2026-10-09-singularity-v0.2-recovery-qualification-design.md`.
Supplied baseline: `125653e9dbb6d979703360138abf55fb888f2711`.
This is a test-only Task 15 supplement; E2E/full acceptance remain excluded.
No production repair, migration, support/configuration change, service restart,
or publication is authorized. Preserve frozen C/restart tests and the original
untracked full-C plan. Do not stage them.

## Task 1: Review and unchanged characterization

**Read:** the design, worktree `AGENTS.md`, existing reconciler test,
`apps/singularity_runtime/lib/singularity/runtime/documents/extraction_reconciler.ex`,
`apps/singularity_storage/lib/singularity/storage/postgres/document_repository.ex`,
`knowledge_error.ex` in that same directory, and migrations
`20260922000100_document_extraction_attempts.exs` and
`20260922000200_document_extraction_recovery.exs` under storage `priv/repo/migrations`.

- [x] Parent reads both complete documents and obtains fresh independent Astra
  review. Resolve actionable design findings before test-only GO.
- [x] Parent records unchanged owning-file baseline with the command below;
  reuse an already completed exact baseline rather than rerunning it.

```sh
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs \
  --seed 1208 --trace
```

Expected: seven existing tests execute; inspect actual output and exclusions.
Borrow ready PostgreSQL without restarting it. Run one Mix process at a time.
Stop on a valid required scoped failure; do not repair production under this plan.

## Task 2: Live catalog and scanner contract

**Modify/Test:** `apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs` only.

- [ ] Extend the existing narrow-worker-execution test with live catalog
  assertions for its two existing signatures. Use this exact query per signature:

```sql
SELECT pg_get_userbyid(p.proowner), p.prosecdef, p.proconfig,
       pg_get_function_result(p.oid),
       EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl,
         acldefault('f', p.proowner))) AS a
         WHERE a.grantee=0 AND a.privilege_type='EXECUTE')
FROM pg_proc AS p WHERE p.oid=to_regprocedure($1)
```

Expect owner `singularity_table_owner`, `true`, exact search_path list from
the design, and final `false`. Scanner result is
`TABLE(version_id uuid, owner_id uuid)`; recovery result is `boolean`.
Keep the existing effective EXECUTE role assertions unchanged.

- [ ] Assert denied direct mutation for every runtime role on both
  `content.document_versions` and `content.document_fragments` with the query
  below. Check INSERT/UPDATE/DELETE separately; for INSERT/UPDATE also check
  `has_any_column_privilege($1,$2,$3) = false`. Assert worker SELECT denial
  using both table and any-column checks. Do not prohibit established web reads.

```sql
SELECT has_table_privilege($1,$2,$3)
```

- [ ] Add a live scanner contract using `source!/0`, `document!/1`, existing
  `grant_read!/1`, and `claim_expired!/2`. Register exact-resource cleanup
  immediately after document creation, using the helper contract in Task 3.
  Execute and assert the exact two columns, both UUIDs, and repository pair:

```elixir
result = query!(WorkerRepo, "SELECT * FROM content.expired_document_extraction_ids(100)")
assert result.columns == ["version_id", "owner_id"]
assert [document.resource_version_id, document.vault_id] in result.rows
for [version, owner] <- result.rows do
  assert {:ok, _} = Ecto.UUID.load(version)
  assert {:ok, _} = Ecto.UUID.load(owner)
end
assert {:ok, pairs} = DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 100)
assert {Ecto.UUID.load!(document.resource_version_id), Ecto.UUID.load!(document.vault_id)} in pairs
```

Do not assert a global single result or substitute the scanner.

## Task 3: Legal collision, exact rollback, and successful control

**Modify/Test:** the same existing reconciler test only; private helpers stay here.

- [ ] Add one collision test using existing source/Document/expired-attempt
  fixtures. Register an `on_exit` callback immediately after creation of each
  new Document. Its sole mutation is this exact-ID fixture retirement inside
  `Fixtures.with_owner/1`; call `query!(MigrationRepo, sql, [resource_id, owner_id])`:

```sql
UPDATE content.resources SET deleted_at=clock_timestamp()
WHERE id=$1 AND vault_id=$2 AND deleted_at IS NULL
```

This occurs after assertions and prevents the intentionally unrecoverable
fixture from contaminating later global scans. Never delete the collision event.

- [ ] Insert the collision through table-owner fixture SQL. Set local
  principal/owner context to the fixture before reading live epochs. Parameters
  are `[event_id, version_id, resource_id, owner_id, principal_id, old_job_id]`,
  all binary UUIDs. Require exactly one inserted row and read its complete row:

```sql
INSERT INTO core.outbox_events
  (id,event_type,idempotency_key,vault_id,principal_id,required_capability,
   principal_authorization_epoch,vault_authorization_epoch,classification,
   correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at)
SELECT $1,'document.extraction_requested','document-extraction:' || $2::uuid::text || ':2',
  $4,$5,'asset.read',a.principal_authorization_epoch,a.vault_authorization_epoch,
  'private',$2,$6,2,1,
  jsonb_build_object('resource_id',$3::uuid,'resource_version_id',$2::uuid),clock_timestamp()
FROM core.live_principal_authorization() AS a
WHERE a.principal_id=$5 AND a.vault_id=$4
```

- [ ] Add a private snapshot helper returning complete `to_jsonb(row)` rows
  with `WHERE vault_id=$1`, ordered by each table's stable primary key:

| Table | Order |
| --- | --- |
| `content.document_versions` | `resource_version_id` |
| `content.resources` | `id` |
| `content.resource_versions` | `id` |
| `content.assets` | `id` |
| `content.asset_objects` | `id` |
| `content.resource_assets` | `resource_version_id, asset_id` |
| `core.outbox_events` | `id` |
| `content.document_fragments` | `id` |
| `content.asset_search_documents` | `asset_id` |

Use only this fixed allowlist for interpolated SQL identifiers; UUID values
remain parameters. Read as table owner. Also snapshot the exact source-object
pin count with `SELECT count(*) FROM content.document_versions WHERE
vault_id=$1 AND source_object_id=$2`. Assert initial generation 1, original
job, expired deadline, nil digest/language/failure/finished time, one exact
collision event, empty fragments, and no Document search projection.

- [ ] Assert production calls and compare the complete snapshot after each:

```elixir
expected = {:error, Singularity.Core.Error.new(:conflict)}
version = Ecto.UUID.load!(document.resource_version_id)
owner = Ecto.UUID.load!(document.vault_id)
before = recovery_snapshot(source)
assert expected == DocumentRepository.recover_expired_with_event(%{repo: WorkerRepo}, version, owner)
assert before == recovery_snapshot(source)
assert {:ok, ids} = DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 100)
assert {version, owner} in ids
assert expected == ExtractionReconciler.run(%{repo: WorkerRepo})
assert before == recovery_snapshot(source)
assert {:ok, ids} = DocumentRepository.list_expired_recovery_ids(%{repo: WorkerRepo}, 100)
assert {version, owner} in ids
```

Implement `recovery_snapshot/1` exactly as the row/pin contract above. Exact
Error equality enforces nil message, empty details, and nonretryable conflict.
The unique violation is currently mapped by `KnowledgeError`; do not change
the adapter to manufacture a different result. Sequence gaps are not row loss.

- [ ] Create a fresh second Document against the same source for a noncollision
  control, register exact-resource cleanup immediately, retain the source's
  existing `asset.read` grant, generate its own old job UUID, and call
  `claim_expired!/2`. Assert extracting generation 1 with that job and an
  expired deadline, then capture the control baseline. Call the
  real repository directly for this version so the still-expired collision
  cannot halt the control. Assert `{:ok, true}` then `{:ok, false}`, pending
  generation 2, and nil job/start/deadline/adapter/format/digest/language/failure/
  finished fields. Assert exactly one new event with payload exactly
  `%{"resource_id" => control_resource_uuid, "resource_version_id" => control_version_uuid}`,
  generation/revision 2, and causation equal to its old job. Compare complete
  source rows, pins, resources, versions, fragments, and search rows before/
  after this call, and verify the collision Document/event remain unchanged.

## Task 4: Parent verification, independent review, and evidence

- [ ] Parent reads the complete changed test and records its hash. Run the
  Task 1 command against the new assertions as characterization, then format
  only that file and run scoped checks below. A first-pass green result is valid.

```sh
devenv shell -- mix format --check-formatted \
  apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs \
  apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs \
  --seed 1208 --trace
MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps \
  devenv shell -- mix singularity.test.integration \
  apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs \
  --seed 90731 --trace
git diff --check
```

- [ ] Parent verifies each runner's actual database cleanup and no service
  restart; record executed counts separately from exclusions. Stop affected
  work on an out-of-scope failure and report it without broadening repairs.
- [ ] Obtain independent Astra SPEC and QUALITY/security review of the exact
  tested diff. Reviewers run no Mix/database/Git mutations. Correct only
  authorized harness defects; a production finding needs bounded review first.
- [ ] Parent updates only the existing Task 15 matrix with source hash, exact
  commands/results, changed files, cleanup, review findings, and limits. Mark
  bounded recovery evidence only; E2E/full gate NOT RUN and Phase 2 unaccepted.
  Any local commit follows the parent's existing authorization; no publication.
