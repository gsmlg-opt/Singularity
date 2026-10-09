# Phase 2 Task 15 Backup Qualification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Qualify existing backup refusal and snapshot consistency without changing production behavior.

**Architecture:** Extend the owning logical exporter integration test using its private legacy-export setup. Repair its stale Document fixture first, then test the deployed guard catalog, legal unsupported inventory, both entrypoints, and a synchronized two-connection snapshot.

**Tech Stack:** Elixir/ExUnit, Ecto scoped transactions, PostgreSQL catalogs, existing isolated integration runner.

**Status:** Complete for this bounded test-only slice. Final formatted source
passed 21 tests in each of two orders; independent Astra SPEC and QUALITY reviews
are clear. Task 15 and full Phase 2 acceptance remain open; E2E was not run.

---

## Preconditions and file ownership

Design: `docs/superpowers/specs/2026-10-09-singularity-v0.2-backup-qualification-design.md`.
Inspected HEAD: `dfe60aa11ac471da243e0523a33a23b0bf426276`.
Worktree: `.trees/v0.2-phase-2-import-extraction`.

Only code file to modify:
`apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs`.
The parent owns evidence updates, Git, Mix, services, and database lifecycle.
Keep production, support, migrations, config, dependencies, V2 wire schema,
frozen extraction/restart tests, and original untracked C plan unchanged.

- [x] Parent reads both documents completely; fresh Astra review resolves all findings.
- [x] Parent records fixture-repair GO, then new qualification GO after rebaseline/reviews.
- [x] Record unchanged baseline: 11 tests / one Document fixture `:forbidden` failure.
  This is not a backup guard failure: execution never reached its assertions.
- [x] Preserve every existing assertion; do not force characterization red by
  changing production code. New coverage is expected to pass existing behavior.

## Task 1: repair only the stale Document test setup, then rebaseline

- [x] Immediately after `source = KnowledgeFixtures.prepared_source!()` in the
  existing Document-refusal test, add its established repository-test prerequisites:

```elixir
Fixtures.with_owner(fn ->
  owner_query!("UPDATE core.vaults SET locked=false WHERE id=$1", [
    Ecto.UUID.dump!(source.vault_id)
  ])
  owner_query!(
    "INSERT INTO core.capabilities (id,name) VALUES ($1,'asset.read') ON CONFLICT (name) DO NOTHING",
    [uuid_dump()]
  )
  owner_query!(
    "INSERT INTO core.principal_capabilities (principal_id,vault_id,capability_id) SELECT $1,$2,id FROM core.capabilities WHERE name='asset.read'",
    [Ecto.UUID.dump!(source.principal_id), Ecto.UUID.dump!(source.vault_id)]
  )
end)
```

- [x] Keep `DocumentRepository.create_pending/2`, temporary grants, and all backup
  assertions. This copies existing fixture setup; no policy or Vault behavior changes.
- [x] Parent runs the owning file using the command below. Expected: all 11
  existing tests pass. If anything fails, STOP qualification and report exact
  failure; no production/support fix or assertion weakening is authorized.

```sh
devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs
```

## Task 2: live guard catalog and entrypoint authorization

- [x] Add one integration test, `backup guard retains its bounded worker privileges`.
  In an authenticated WorkerRepo scoped transaction, assert worker current_user
  and query the exact deployed function:

```sql
SELECT p.prosecdef, p.provolatile::text, r.rolname,
       p.prorettype = 'boolean'::regtype, p.proconfig, p.prosrc,
       EXISTS (SELECT 1
               FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
               WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
WHERE p.oid = 'content.backup_has_unsupported_canonical_rows(uuid)'::regprocedure
```

- [x] Expect true, `s`, `singularity_table_owner`, true,
  `['search_path=pg_catalog, content, core']`, body, false. Check the body has
  all eight `FROM content.<table> WHERE vault_id = requested_vault_id` clauses,
  `core.live_principal_authorization()`, scope match, live principal/membership,
  and `backup.create`. Label this structural inventory evidence.
- [x] Use `has_function_privilege($1, $2, 'EXECUTE')` for worker=true and
  web/dispatcher/pre-auth=false. Use `has_table_privilege(current_user,$1,'SELECT')`
  for all `@unsupported_tables`, expecting false. Run after any fixture grants close.
- [x] Extend unauthorized characterization to BOTH exporter entrypoints. Use
  source principal without backup.create and valid fixture principal requesting
  a foreign owner. For records, create a well-shaped cut with requested vault_id,
  empty object_inventory, and `current_snapshot_cut/2`; keep UUIDs valid.
  Each call gets its own transaction so a failed SQL statement cannot taint
  the next assertion. Preserve existing raw guard/savepoint assertions.

```elixir
expected = {:error, Error.new(:storage_unavailable, retryable?: true)}
assert result == expected
assert {:error, %Error{message: nil, details: %{}}} = result
```

## Task 3: legal inventory at cut and records with owner isolation

- [x] Add parameterized cases for the eight tables in the design's inventory.
  Start each from `raw = KnowledgeFixtures.source!()`; `load_ids(raw)` supplies
  text UUIDs. `seed_export_rows!(raw)` supplies its export closure and capability;
  use existing `cut/2`. Never seed a second active key version on prepared_source!.
  The setup fixture remains the clean control. Prove both export before insertion.
- [x] Add only private helpers local to this test file. Fixture insertion uses
  `Fixtures.with_owner/1` and `owner_query!/2`, binary UUID parameters, `log: false`,
  and committed constraints. Existing `KnowledgeFixtures.document!/1`,
  `ready_document!/1`, and `note!/1` create valid parents. Do not copy or edit support.
- [x] Construct the following exact shapes (timestamps use CURRENT_TIMESTAMP,
  classification is private; all parent identities use the same raw owner):

| Case | Required insertion and omitted inventory |
| --- | --- |
| Document | `document!(raw)`; only document_versions |
| Fragment | `ready_document!(raw)`; document_versions + document_fragments |
| Receipt | `document!(raw)`, then completed receipt with principal_id, mutation_id, 32-byte request_fingerprint, resource_id, version_id; Document + receipt |
| Attachment | two `note!(raw)` parents; source note IDs, target note IDs, target_kind=note, ordinal=0, role=source, label canary; only note_attachments |
| Citation | `note!(raw)` and `ready_document!(raw)`; source document IDs, fragment.fragment_id and exact fragment.locator, ordinal=0; Document + fragment + citation |
| Tag | id, raw vault_id, display_value/normalized_key canaries, raw principal_id; only tags |
| Resource tag | supported Note, valid tag, resource_id/tag_id/vault_id; tags + resource_tags |
| Relationship | two supported Notes, source_resource_id, target_resource_id, type=related_to, creator principal; only relationships |

- [x] Owner-query counts for every omitted table before worker checks; assert the
  nonzero table set equals the table above. Never create pending receipt orphans
  or bypass immutable/foreign-key/source-set constraints to isolate a branch.
- [x] For each case, use separate repeatable-read ScopedRepo transactions for
  cut and records. The latter binds the existing valid test cut directly with
  `current_snapshot_cut/2`, allowing the record guard to execute after cut refusal.

```elixir
assert result == {:error, Error.new(:backup_unsupported)}
assert {:error, %Error{message: nil, details: %{}, retryable?: false}} = result
Enum.each(canaries, fn canary -> refute inspect(result) =~ canary end)
```

- [x] After insertion, the clean owner must still obtain a successful cut and
  materialized records inside its own transaction. Decode records with
  LogicalRecordCodec and reuse `assert_vault_scoped_rows/2`; reject case canaries.
  The ready-Document helper's fixed fragment text `"text"` is also a wire type
  tag: reject it as a decoded user row value, not in raw bytes. Preserve the
  helper and use its exact fragment ID/locator as additional canaries.
- [x] Preserve existing exact counts/order/descriptors/privacy test unchanged.
  Record four independent cases and four dependent composite cases honestly.

## Task 4: a committed concurrent tag does not change the old export snapshot

- [x] Add `backup cut and records share the snapshot across a committed canonical insert`.
  The test process is reader; use `start_supervised!(Task.Supervisor)` and
  `Task.Supervisor.async_nolink/2` for a monitored writer waiting for a unique
  `{reference, :write}` message. Its receive timeout is 10 seconds. It calls
  `Fixtures.with_owner/1` only after the barrier, inserts one canary tag into
  the setup owner, and returns its pg_backend_pid after commit.
- [x] Wrap task lifetime in `try/after`; call bounded `Task.shutdown/2` before
  leaving the test. Capture the task-owned MigrationRepo supervisor PID after
  startup via a reference-tagged message. On cancellation, stop that exact PID
  if still alive; never kill a shared repo. Ensure final cleanup has completed.
- [x] Reader uses ScopedRepo WorkerRepo repeatable_read. Set local statement_timeout
  and lock_timeout to 5 seconds on both connections. Explicitly establish the
  snapshot before releasing the writer:

```elixir
%{rows: [[snapshot, reader_pid]]} =
  SafeSQL.query!(repo, "SELECT txid_current_snapshot()::text, pg_backend_pid()", [])
assert {:ok, first_cut} = Exporter.snapshot_cut(repo, fixture.vault_id)
first_cut = Map.put(first_cut, :manifest_id, Ecto.UUID.generate())
assert first_cut.database_snapshot == snapshot
assert {:ok, before_export} = Exporter.records(repo, first_cut)
before_records = Enum.to_list(before_export.records)
send(writer.pid, {reference, :write})
writer_pid = Task.await(writer, 10_000)
refute writer_pid == reader_pid
assert {:ok, second_cut} = Exporter.snapshot_cut(repo, fixture.vault_id)
assert Map.drop(second_cut, [:snapshot_id]) ==
         Map.drop(first_cut, [:snapshot_id, :manifest_id])
assert {:ok, after_export} = Exporter.records(repo, first_cut)
assert Enum.to_list(after_export.records) == before_records
assert after_export.inventory == before_export.inventory
```

- [x] Confirm unchanged snapshot text explicitly and reject the tag canary from
  materialized bytes. Return `{:ok, :checked}` and assert transaction completion.
  Task completion must occur after its owner transaction commits, not merely
  after its INSERT returns. No sleep, polling, retries, or shared connection.
- [x] After reader transaction ends, owner-query the exact committed tag ID.
  In a new worker repeatable_read transaction assert both cut and records return
  exact Error.new(:backup_unsupported). Records uses a newly bound valid cut,
  not the old snapshot. New snapshot string need not be compared lexicographically.

## Task 5: bounded verification and evidence handoff

- [x] Parent runs new focused cases while implementing, then one complete owning
  file run with the Task 1 command. Stop on any failure; preserve full diagnostics.
- [x] Parent runs formatter check for the one changed .exs file and `git diff --check`.
  Confirm `logical_schema_v2.ex` is byte-identical and changed paths are allowlisted.
- [x] Parent reviews new test fixtures, exact error equality, both entrypoints,
  legal parent sets, effective worker privileges, reference-tagged barriers,
  post-commit acknowledgment, and task/supervisor cleanup on failures.
- [x] Update Task 15 evidence matrix with exact source, changed files, commands,
  baseline failure and repair, final test counts, and independent/composite
  inventory distinction. Record zero migration/production/support changes.
- [x] Fresh review of resulting test diff must pass before claiming this slice
  complete. Full README gate, full Phase 2 acceptance, E2E, bundle restore,
  deployment and production acceptance remain NOT RUN. No push/merge/tag/release.
- [x] Stop after this bounded slice. Parent handles any separately authorized
  local commit; this plan does not authorize publication or acceptance expansion.
