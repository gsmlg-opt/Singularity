# Singularity v0.2.0 Phase 0 Blocker Repairs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair the two verified Phase 0 storage blockers without weakening classification integrity, losing durable wakes, changing backup formats, or expanding the approved release scope.

**Architecture:** A forward migration changes only the validation timing of the existing resource/version classification foreign key. A second forward migration transfers application-owned wake generations from legacy Oban metadata into locked `jobs.job_submissions` rows; `WakeHandshake` continues to lock and inspect Oban state but no longer writes Oban metadata. Governance alignment precedes production edits, each repair follows a focused red-green cycle, and the canonical complete Phase 0 gate remains the acceptance boundary.

**Tech Stack:** Elixir 1.18.4, Erlang/OTP 28, Ecto SQL 3.14, PostgreSQL 17, Oban 2.24, ExUnit, devenv/Nix, npm_ex, Vitest, Playwright, actionlint, Git.

---

## Authority and execution boundary

This plan implements only the approved amendment:

- `docs/superpowers/specs/2026-09-01-singularity-v0.2-phase-0-blocker-repair-design.md`

It supplements, but does not otherwise expand:

- `docs/superpowers/specs/2026-08-31-singularity-v0.2-release-design.md`
- `docs/superpowers/plans/2026-08-31-singularity-v0.2-phase-0-scope-baseline.md`
- `docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`

Execution remains on:

- Branch: `codex/v0.2-phase-0-scope-baseline`
- Worktree: `.trees/v0.2-phase-0-scope-baseline`
- Approved amendment commit: `78b929a`

The committed version of this plan must be the newest checkpoint before Task
1 starts. The worktree must be clean.

### Original implementation allowlist (18 paths)

Create:

- `apps/singularity_storage/priv/repo/migrations/20260901000100_defer_resource_version_classification_fkey.exs`
- `apps/singularity_storage/priv/repo/migrations/20260901000200_move_wake_generations_to_job_submissions.exs`
- `apps/singularity_storage/test/singularity/storage/wake_generation_migration_test.exs`

Modify:

- `AGENTS.md`
- `apps/singularity_storage/mix.exs`
- `apps/singularity_storage/lib/singularity/storage/jobs/progress.ex`
- `apps/singularity_storage/lib/singularity/storage/schema/jobs/job_submission.ex`
- `apps/singularity_storage/test/singularity/storage/asset_search_projection_test.exs`
- `apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs`
- `apps/singularity_storage/test/singularity/storage/classification_inheritance_test.exs`
- `apps/singularity_storage/test/singularity/storage/effect_receipt_test.exs`
- `apps/singularity_storage/test/singularity/storage/migrations_test.exs`
- `apps/singularity_storage/test/singularity/storage/note_schema_test.exs`
- `apps/singularity_storage/test/singularity/storage/postgres/asset_repository_test.exs`
- `apps/singularity_storage/test/singularity/storage/runner_submission_recovery_test.exs`
- `apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs`
- `apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`

Planning artifact:

- `docs/superpowers/plans/2026-09-01-singularity-v0.2-phase-0-blocker-repairs.md`

Expected unchanged:

- `mix.lock` (already locks Oban 2.24.0)
- every migration dated before 2026-09-01
- `apps/singularity_storage/lib/singularity/storage/jobs/oban_adapter.ex`
- `apps/singularity_storage/lib/singularity/storage/jobs/generic_worker.ex`
- `apps/singularity_storage/lib/singularity/storage/backup/logical_schema.ex`
- `apps/singularity_storage/lib/singularity/storage/backup/logical_schema_v2.ex`
- all Vault production files, public APIs, versions, and release workflows

At initial plan approval, any path outside this 18-path set required explicit
approval before editing. The following section records the only subsequent
approvals.

### Separately approved canonical-gate corrections

Later canonical-gate failures separately received explicit approval for these
verification-harness and documentation corrections only:

- `apps/singularity_runtime/test/singularity/runtime/asset_deletion_test.exs`
- `apps/singularity_runtime/lib/mix/tasks/singularity.test.browser.ex`
- `apps/singularity_runtime/test/mix/tasks/singularity.test.browser_test.exs`
- `apps/singularity_web/test/singularity/web/asset_toolchain_contract_test.exs`
- `playwright.config.ts`
- this alignment of the approved blocker design in
  `docs/superpowers/specs/2026-09-01-singularity-v0.2-phase-0-blocker-repair-design.md`
- `apps/singularity_storage/test/singularity/storage/roles_test.exs` for
  test-only isolation of the dispatcher `LIMIT 1` claim from older undelivered
  outbox events left by another integration test

These corrections do not alter the original two production repair slices and
authorize no further production, Vault, backup-format, version, workflow,
release, deployment, or Phase 1 change.

The original 18 paths plus these seven corrections form the
complete approved 25-path set.
Any path outside that combined set requires new approval before editing.

## File responsibility map

- `AGENTS.md` and `notes_scope_contract_test.exs`: make the approved two-slice
  exception active without relaxing any other Phase 0 rule.
- `20260901000100_defer_resource_version_classification_fkey.exs`: change the
  existing composite FK's validation timing in place while preserving its
  identity, shape, referenced key, and committed equality invariant.
- Classification integration files: prove statement-order independence,
  commit-time rejection of partial state, strictest-contributor behavior, and
  repair the three incomplete fixture chains in each affected search/repository
  suite.
- `migrations_test.exs`: preserve the existing historical migration harness
  now that two new migrations follow the Notes migration, and prove exact
  round trips.
- `20260901000200_move_wake_generations_to_job_submissions.exs`: add/check the
  counters, validate and transfer legacy values, recover generations from
  active reconcilers, and guard local downgrade.
- `wake_generation_migration_test.exs`: exercise the one-time transfer and
  downgrade independently of runtime behavior.
- `job_submission.ex`: expose the two application-owned counters and their
  narrow internal update changeset.
- `progress.ex`: keep the current public `WakeHandshake` interface while
  moving all generation reads/writes to the locked submission.
- `effect_receipt_test.exs`: prove the actual snooze race, Oban 2.24 attempt
  semantics, reconciler uniqueness, and crash recovery.
- `runner_submission_recovery_test.exs` and `restore_import_test.exs`: prove
  idempotent submission defaults and immutable logical-backup compatibility.
- `roles_test.exs`: isolate the dispatcher-role `LIMIT 1` claim and
  acknowledgement test from older undelivered integration state without
  changing production claim SQL or its behavioral assertions.
- `dependency_graph_test.exs` and `mix.exs`: enforce the supported Oban 2.24
  floor without lock churn.

### Task 1: Confirm the plan checkpoint and immutable boundaries

**Files:**

- Verify: `docs/superpowers/specs/2026-09-01-singularity-v0.2-phase-0-blocker-repair-design.md`
- Verify: `apps/singularity_storage/priv/repo/migrations/20260818000100_create_private_markdown_notes.exs`
- Verify: `mix.lock`

- [ ] **Step 1: Confirm branch, checkpoint, and cleanliness**

Run:

```bash
git branch --show-current
git status --short --branch
git log -3 --oneline
git merge-base HEAD main
```

Expected:

- branch is `codex/v0.2-phase-0-scope-baseline`;
- the tree is clean;
- this committed plan is the newest commit;
- `78b929a` is an ancestor of `HEAD`; and
- the merge base remains the Phase 0 starting `main` revision.

- [ ] **Step 2: Record the protected-file baseline**

Run:

```bash
git show 78b929a:apps/singularity_storage/priv/repo/migrations/20260818000100_create_private_markdown_notes.exs | sha256sum
git show 78b929a:mix.lock | sha256sum
git status --porcelain
```

Expected: two hashes are recorded in the execution report and status is empty.
Do not copy the files or create an evidence directory.

- [ ] **Step 3: Start the local PostgreSQL test prerequisite**

Run:

```bash
devenv up -d
devenv processes wait --timeout 120

devenv shell -- bash \
  apps/singularity_storage/priv/repo/bootstrap_roles.sh
```

Expected: the process manager reports ready and role bootstrap succeeds. Keep
the local services available for focused RED/GREEN cycles; the canonical gate
owns final teardown with its trap.

### Task 2: Activate only the approved governance exceptions

**Files:**

- Modify: `apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`
- Modify: `AGENTS.md`

- [ ] **Step 1: Add the failing governance contract**

Add these module attributes next to the existing Phase 0 markers in
`notes_scope_contract_test.exs`:

```elixir
@blocker_repair_design_path "docs/superpowers/specs/2026-09-01-singularity-v0.2-phase-0-blocker-repair-design.md"

@classification_repair_scope "The only classification repair makes `resource_versions_resource_classification_fkey` deferrable and initially deferred through a new forward migration."

@wake_repair_scope "The only wake repair moves application-owned wake generation counters from Oban metadata to `jobs.job_submissions` and raises the supported Oban floor to 2.24."

@no_other_repair_scope "No other Phase 0 production-code, production-behavior, or schema change is authorized."
```

Add this test after the existing governance-document contract:

```elixir
test "Phase 0 governance names only the approved blocker repair exceptions" do
  agents =
    @repo_root
    |> Path.join("AGENTS.md")
    |> read_required!()
    |> assert_active_prose!()
    |> normalize_markdown()

  design_path = Path.join(@repo_root, @blocker_repair_design_path)
  design = read_required!(design_path)

  assert design =~ "**Status:** Approved"
  assert agents =~ @blocker_repair_design_path

  for marker <- [
        @classification_repair_scope,
        @wake_repair_scope,
        @no_other_repair_scope
      ] do
    assert agents =~ marker
  end
end
```

- [ ] **Step 2: Run the contract and verify RED**

Run:

```bash
devenv shell -- mix format \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs

devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs
```

Expected: only the new test fails because `AGENTS.md` does not yet name the
amendment or the bounded exceptions. Fix test syntax if it errors for another
reason; do not edit `AGENTS.md` until this expected failure is observed.

- [ ] **Step 3: Align active repository instructions**

Add the blocker-repair design path to the governing-document list in
`AGENTS.md`. Replace the blanket Phase 0 production prohibition with exactly:

```markdown
The approved Phase 0 blocker repair amendment is:

- `docs/superpowers/specs/2026-09-01-singularity-v0.2-phase-0-blocker-repair-design.md`

The only classification repair makes
`resource_versions_resource_classification_fkey` deferrable and initially
deferred through a new forward migration.

The only wake repair moves application-owned wake generation counters from
Oban metadata to `jobs.job_submissions` and raises the supported Oban floor to
2.24.

No other Phase 0 production-code, production-behavior, or schema change is
authorized. Version bumps, tags, releases, pushes, deployments, and Phase 1
work remain prohibited.
```

Retain every Vault freeze, backup compatibility, verification, dependency,
release, and Phase 1 rule already present.

- [ ] **Step 4: Run GREEN governance verification**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs

git diff --check
git diff --name-only 78b929a..HEAD
git status --short
```

Expected: the architecture file passes. Before the commit, the only unstaged
implementation paths are `AGENTS.md` and the scope contract.

- [ ] **Step 5: Commit the governance checkpoint**

```bash
git add -- \
  AGENTS.md \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs

git commit -m "docs(scope): authorize approved phase 0 blocker repairs"
```

Run:

```bash
git status --short
git diff --name-only 78b929a..HEAD -- 'apps/*/lib/**' 'apps/*/priv/**'
```

Expected: clean tree and no production or migration path changed yet.

### Task 3: Establish the classification RED contracts

**Files:**

- Modify: `apps/singularity_storage/test/singularity/storage/note_schema_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/classification_inheritance_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/asset_search_projection_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/postgres/asset_repository_test.exs`

- [ ] **Step 1: Require the exact deferred catalog contract**

In the Note schema constraint test, add:

```elixir
assert constraint_definition!("resource_versions_resource_classification_fkey") =~
         "DEFERRABLE INITIALLY DEFERRED"
```

Do not remove the constraint from `@constraints` or alter any other expected
constraint.

- [ ] **Step 2: Add atomic and partial-transition integration tests**

In `classification_inheritance_test.exs`, import capture support and alias the
migration repository:

```elixir
import ExUnit.CaptureLog

alias Singularity.Storage.MigrationRepo
```

Add these tests:

```elixir
test "resource/version classification strengthening commits in either statement order" do
  for order <- [[:resource, :resource_version], [:resource_version, :resource]] do
    %{one: fixture} = Fixtures.two_vaults!()
    updates = classification_updates(fixture)

    assert :ok =
             Fixtures.with_owner(fn ->
               Enum.each(order, fn target ->
                 {statement, parameters} = Map.fetch!(updates, target)
                 query!(MigrationRepo, statement, parameters)
               end)

               :ok
             end)

    assert %{rows: [["restricted", "restricted"]]} =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 """
                 SELECT resource.classification, version.classification
                 FROM content.resources AS resource
                 JOIN content.resource_versions AS version
                   ON version.resource_id = resource.id
                  AND version.vault_id = resource.vault_id
                 WHERE resource.id = $1 AND version.id = $2
                 """,
                 [fixture.resource_id, fixture.resource_version_id]
               )
             end)
  end
end

test "partial resource/version classification strengthening fails at commit and rolls back" do
  parent = self()

  for target <- [:resource, :resource_version] do
    %{one: fixture} = Fixtures.two_vaults!()
    {statement, parameters} = Map.fetch!(classification_updates(fixture), target)

    capture_log(fn ->
      assert_raise Postgrex.Error,
                   ~r/resource_versions_resource_classification_fkey/,
                   fn ->
                     Fixtures.with_owner(fn ->
                       query!(MigrationRepo, statement, parameters)
                       send(parent, {:partial_statement_completed, target})
                     end)
                   end
    end)

    assert_receive {:partial_statement_completed, ^target}

    assert %{rows: [["private", "private"]]} =
             Fixtures.with_owner(fn ->
               query!(
                 MigrationRepo,
                 """
                 SELECT resource.classification, version.classification
                 FROM content.resources AS resource
                 JOIN content.resource_versions AS version
                   ON version.resource_id = resource.id
                  AND version.vault_id = resource.vault_id
                 WHERE resource.id = $1 AND version.id = $2
                 """,
                 [fixture.resource_id, fixture.resource_version_id]
               )
             end)
  end
end
```

Add the complete local helper:

```elixir
defp classification_updates(fixture) do
  %{
    resource:
      {
        "UPDATE content.resources SET classification = 'restricted' WHERE id = $1 AND vault_id = $2",
        [fixture.resource_id, fixture.vault_id]
      },
    resource_version:
      {
        "UPDATE content.resource_versions SET classification = 'restricted' WHERE id = $1 AND vault_id = $2",
        [fixture.resource_version_id, fixture.vault_id]
      }
  }
end
```

The message assertion is essential: before the migration, the first statement
fails and no message is delivered; after the migration, the statement succeeds
temporarily and PostgreSQL rejects the mismatch only at commit.

- [ ] **Step 3: Make every stricter-chain fixture aggregate-complete**

In `install_stricter_classification_chain!/1` in
`asset_search_projection_test.exs`, retain the existing version-first order and
add immediately after the version update:

```elixir
query!(
  MigrationRepo,
  """
  UPDATE content.resources
  SET classification = 'sensitive'
  WHERE id = $1 AND vault_id = $2
  """,
  [raw_fixture.resource_id, raw_fixture.vault_id]
)
```

In each of these `asset_repository_test.exs` cases, retain the existing
version-first order and add a matching resource update in the same scoped
transaction:

- `upload intent rejects a downgrade from the persisted resource version without effects`
- `first search projection cannot downgrade the canonical asset classification`
- `canonical classification cannot change between validation and first projection insert`

Use this exact statement with the existing fixture:

```elixir
query!(
  repo,
  """
  UPDATE content.resources
  SET classification = 'restricted'
  WHERE id = $1 AND vault_id = $2
  """,
  [
    Ecto.UUID.dump!(fixture.resource_id),
    Ecto.UUID.dump!(fixture.vault_id)
  ]
)
```

Do not make asset, metadata, source, and resource classifications identical;
they remain independent strictest-contributor inputs.

- [ ] **Step 4: Run the classification suite and verify RED**

Run:

```bash
devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/note_schema_test.exs \
  apps/singularity_storage/test/singularity/storage/classification_inheritance_test.exs \
  apps/singularity_storage/test/singularity/storage/asset_search_projection_test.exs \
  apps/singularity_storage/test/singularity/storage/postgres/asset_repository_test.exs
```

Expected:

- the catalog assertion reports the FK is not deferrable;
- the complete transitions raise the existing FK on their first statement;
- the partial test does not receive its statement-completed message; and
- the six original strict-classification tests still fail with
  `resource_versions_resource_classification_fkey`.

Do not commit the RED state.

### Task 4: Implement and prove transactional classification strengthening

**Files:**

- Create: `apps/singularity_storage/priv/repo/migrations/20260901000100_defer_resource_version_classification_fkey.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/migrations_test.exs`
- Test: all Task 3 files

- [ ] **Step 1: Add the forward migration**

Create the migration with exactly:

```elixir
defmodule Singularity.Storage.Migrations.DeferResourceVersionClassificationForeignKey do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    ALTER TABLE content.resource_versions
      ALTER CONSTRAINT resource_versions_resource_classification_fkey
      DEFERRABLE INITIALLY DEFERRED
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    ALTER TABLE content.resource_versions
      ALTER CONSTRAINT resource_versions_resource_classification_fkey
      NOT DEFERRABLE INITIALLY IMMEDIATE
    """)

    execute("SET LOCAL ROLE NONE")
  end
end
```

Each direction changes only validation timing in place. This preserves the
constraint identity and name, child and parent columns, referenced key, and
committed equality invariant while avoiding FK drop, recreation, revalidation,
and the referenced-table lock involved in adding a foreign key. Specifically,
it avoids the add-FK `SHARE ROW EXCLUSIVE` lock on referenced
`content.resources`. The bounded guarantee is that migration-up requests
no referenced-table lock mode that conflicts with an already held
`ROW EXCLUSIVE` lock; compatible weaker locks are not excluded. Down restores
immediate validation safely because every committed row remains valid. Do not
change the released Notes migration.

- [ ] **Step 2: Teach the historical migration harness about the new head**

Add:

```elixir
@classification_migration_version 20_260_901_000_100
@classification_migration Singularity.Storage.Migrations.DeferResourceVersionClassificationForeignKey
```

Replace the setup call to `prepare_private_notes_migration!/1` with:

```elixir
prepare_migration_state!(
  private_notes?: context[:with_private_notes] == true,
  classification_repair?: context[:with_classification_repair] == true
)
```

Replace the old private-Notes preparation helpers and `notes_migration_up?/0`
with:

```elixir
defp prepare_migration_state!(options) do
  include_classification? = Keyword.fetch!(options, :classification_repair?)
  include_notes? = Keyword.fetch!(options, :private_notes?) or include_classification?
  {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)

  try do
    if migration_up?(@classification_migration_version) and not include_classification? do
      :ok =
        Ecto.Migrator.down(
          MigrationRepo,
          @classification_migration_version,
          @classification_migration,
          log: false
        )

      purge_migration(@classification_migration)
    end

    cond do
      include_notes? and not migration_up?(@notes_migration_version) ->
        :ok =
          Ecto.Migrator.up(
            MigrationRepo,
            @notes_migration_version,
            @notes_migration,
            log: false
          )

      not include_notes? and migration_up?(@notes_migration_version) ->
        cleanup_notes_with_started_repo!()

        :ok =
          Ecto.Migrator.down(
            MigrationRepo,
            @notes_migration_version,
            @notes_migration,
            log: false
          )

        purge_migration(@notes_migration)

      true ->
        :ok
    end

    if include_classification? and not migration_up?(@classification_migration_version) do
      :ok =
        Ecto.Migrator.up(
          MigrationRepo,
          @classification_migration_version,
          @classification_migration,
          log: false
        )
    end
  after
    Supervisor.stop(migration_repo)
  end
end

defp migration_up?(version) do
  %{rows: rows} =
    query!(
      MigrationRepo,
      "SELECT 1 FROM public.schema_migrations WHERE version = $1",
      [version]
    )

  rows == [[1]]
end

defp purge_migration(migration) do
  :code.purge(migration)
  :code.delete(migration)
end
```

Existing `@tag :with_private_notes` tests intentionally leave the new
classification migration down so their direct Notes downgrade remains valid.
Only the new round-trip test below uses `@tag :with_classification_repair`.

Append `@classification_migration_version` to every exact result list from
`Ecto.Migrator.run(..., :up, all: true)` that currently ends with
`@notes_migration_version`. Do not loosen exact list assertions.

- [ ] **Step 3: Add the exact migration round-trip test**

Add to `migrations_test.exs`:

```elixir
@tag :with_classification_repair
test "classification deferral migration round-trips the exact foreign-key contract" do
  {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)

  try do
    assert {true, true, deferred_definition} = classification_foreign_key_contract()
    assert deferred_definition =~ "FOREIGN KEY (resource_id, vault_id, classification)"
    assert deferred_definition =~ "REFERENCES content.resources(id, vault_id, classification)"
    assert deferred_definition =~ "DEFERRABLE INITIALLY DEFERRED"

    assert :ok =
             Ecto.Migrator.down(
               MigrationRepo,
               @classification_migration_version,
               @classification_migration,
               log: false
             )

    assert {false, false, immediate_definition} = classification_foreign_key_contract()
    assert immediate_definition =~ "FOREIGN KEY (resource_id, vault_id, classification)"
    assert immediate_definition =~
             "REFERENCES content.resources(id, vault_id, classification)"

    refute immediate_definition =~ "DEFERRABLE"

    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               @classification_migration_version,
               @classification_migration,
               log: false
             )

    assert {true, true, _definition} = classification_foreign_key_contract()
  after
    unless migration_up?(@classification_migration_version) do
      Ecto.Migrator.up(
        MigrationRepo,
        @classification_migration_version,
        @classification_migration,
        log: false
      )
    end

    Supervisor.stop(migration_repo)
  end
end

defp classification_foreign_key_contract do
  %{rows: [[deferrable?, deferred?, definition]]} =
    query!(
      RequestRepo,
      """
      SELECT condeferrable, condeferred, pg_get_constraintdef(oid)
      FROM pg_catalog.pg_constraint
      WHERE conrelid = 'content.resource_versions'::regclass
        AND conname = 'resource_versions_resource_classification_fkey'
      """
    )

  {deferrable?, deferred?, definition}
end
```

The existing regression
`classification migration changes deferrability without locking referenced resources`
is also required evidence. Despite its historical name, its bounded guarantee
is only that migration-up succeeds with a `500ms` lock timeout and requests
no referenced-table lock mode that conflicts with the `ROW EXCLUSIVE` lock
held by a separate transaction on `content.resources`; compatible weaker locks
are not excluded.

- [ ] **Step 4: Run GREEN classification verification**

Run:

```bash
devenv shell -- mix format \
  apps/singularity_storage/priv/repo/migrations/20260901000100_defer_resource_version_classification_fkey.exs \
  apps/singularity_storage/test/singularity/storage/migrations_test.exs \
  apps/singularity_storage/test/singularity/storage/note_schema_test.exs \
  apps/singularity_storage/test/singularity/storage/classification_inheritance_test.exs \
  apps/singularity_storage/test/singularity/storage/asset_search_projection_test.exs \
  apps/singularity_storage/test/singularity/storage/postgres/asset_repository_test.exs

devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/migrations_test.exs \
  apps/singularity_storage/test/singularity/storage/note_schema_test.exs \
  apps/singularity_storage/test/singularity/storage/classification_inheritance_test.exs \
  apps/singularity_storage/test/singularity/storage/asset_search_projection_test.exs \
  apps/singularity_storage/test/singularity/storage/postgres/asset_repository_test.exs

git diff --check
git diff --exit-code 78b929a -- \
  apps/singularity_storage/priv/repo/migrations/20260818000100_create_private_markdown_notes.exs
```

Expected: all scoped tests pass, including all six original FK failures and the
bounded referenced-table lock-mode regression. The released Notes migration
is byte-unchanged.

- [ ] **Step 5: Commit Slice A only**

```bash
git add -- \
  apps/singularity_storage/priv/repo/migrations/20260901000100_defer_resource_version_classification_fkey.exs \
  apps/singularity_storage/test/singularity/storage/migrations_test.exs \
  apps/singularity_storage/test/singularity/storage/note_schema_test.exs \
  apps/singularity_storage/test/singularity/storage/classification_inheritance_test.exs \
  apps/singularity_storage/test/singularity/storage/asset_search_projection_test.exs \
  apps/singularity_storage/test/singularity/storage/postgres/asset_repository_test.exs

git commit -m "fix(storage): make classification strengthening atomic"
```

Run `git status --short`. Expected: clean. Do not include wake, dependency,
backup, Vault, or release files in this commit.

### Task 5: Establish the wake-migration RED contracts

**Files:**

- Create: `apps/singularity_storage/test/singularity/storage/wake_generation_migration_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/migrations_test.exs`

- [ ] **Step 1: Create the isolated migration test harness**

Create the new test module with these constants and lifecycle helpers:

```elixir
defmodule Singularity.Storage.WakeGenerationMigrationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

alias Singularity.Storage.Fixtures
alias Singularity.Storage.MigrationRepo
alias Singularity.Storage.Schema.Jobs.JobSubmission

  @version 20_260_901_000_200
  @migration Singularity.Storage.Migrations.MoveWakeGenerationsToJobSubmissions
  @generic_worker "Singularity.Storage.Jobs.GenericWorker"
  @reconciler "Singularity.Storage.Jobs.WakeReconciler"

  setup do
    %{one: fixture} = Fixtures.two_vaults!()
    event = Fixtures.outbox_event!(fixture)
    runtime_started? = runtime_started?()

    if runtime_started?, do: assert(:ok == Application.stop(:singularity_runtime))

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)

    if migration_up?() do
      assert :ok = Ecto.Migrator.down(MigrationRepo, @version, @migration, log: false)
    end

    on_exit(fn ->
      cleanup_test_state!(event.id)

      if Code.ensure_loaded?(@migration) and not migration_up?() do
        Ecto.Migrator.up(MigrationRepo, @version, @migration, log: false)
      end

      if Process.alive?(migration_repo), do: Supervisor.stop(migration_repo)

      if runtime_started? do
        assert {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
      end
    end)

    %{event: event, fixture: fixture}
  end

  defp runtime_started? do
    Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
      app == :singularity_runtime
    end)
  end

  defp migration_up? do
    %{rows: rows} =
      query!(
        MigrationRepo,
        "SELECT 1 FROM public.schema_migrations WHERE version = $1",
        [@version]
      )

    rows == [[1]]
  end

  defp migrate_up! do
    assert :ok = Ecto.Migrator.up(MigrationRepo, @version, @migration, log: false)
  end

  defp migrate_down! do
    assert :ok = Ecto.Migrator.down(MigrationRepo, @version, @migration, log: false)
  end

  defp cleanup_test_state!(event_id) do
    test_id = Ecto.UUID.load!(event_id)

    owner_transaction(fn ->
      query!(
        MigrationRepo,
        "DELETE FROM jobs.oban_jobs WHERE meta->>'wake_migration_test_id' = $1",
        [test_id]
      )

      query!(
        MigrationRepo,
        "DELETE FROM jobs.job_submissions WHERE outbox_event_id = $1",
        [event_id]
      )

      query!(
        MigrationRepo,
        "DELETE FROM core.outbox_events WHERE id = $1",
        [event_id]
      )

      query!(
        MigrationRepo,
        "DELETE FROM jobs.oban_peers WHERE name = 'wake-migration-test'"
      )
    end)
  end
end
```

The fixture and outbox event are created before stopping Runtime because their
helpers use the running application repositories. Every migration operation
then runs through `MigrationRepo` with Oban stopped. Cleanup deletes test jobs
and submissions whether the migration is up or down before restoring the
latest schema, so pending counters or active reconcilers cannot leak into the
next test's guarded setup downgrade.

- [ ] **Step 2: Add complete legacy-row helpers**

Add these helpers inside the module:

```elixir
defp insert_legacy_submission!(fixture, event, meta, reconcilers \\ []) do
  owner_transaction(fn ->
    test_id = Ecto.UUID.load!(event.id)

    target_id =
      insert_oban_job!(
        "scheduled",
        @generic_worker,
        %{"job_id" => Ecto.UUID.load!(event.id)},
        meta,
        test_id
      )

    query!(
      MigrationRepo,
      """
      INSERT INTO jobs.job_submissions (
        id,
        vault_id,
        outbox_event_id,
        classification,
        idempotency_key,
        job_type,
        runner_job_id
      ) VALUES ($1, $2, $1, 'private', $3, 'asset_verify', $4)
      """,
      [
        event.id,
        fixture.vault_id,
        "legacy-wake-#{Ecto.UUID.load!(event.id)}",
        Integer.to_string(target_id)
      ]
    )

    reconciler_ids =
      Enum.map(reconcilers, fn {state, generation} ->
        insert_oban_job!(
          state,
          @reconciler,
          %{
            "target_job_id" => target_id,
            "wake_generation" => generation
          },
          %{},
          test_id
        )
      end)

    %{reconciler_ids: reconciler_ids, submission_id: event.id, target_id: target_id}
  end)
end

defp insert_oban_job!(state, worker, args, meta, test_id) do
  meta = Map.put(meta, "wake_migration_test_id", test_id)

  %{rows: [[job_id]]} =
    query!(
      MigrationRepo,
      """
      INSERT INTO jobs.oban_jobs (
        state,
        queue,
        worker,
        args,
        meta,
        scheduled_at
      ) VALUES (
        $1,
        'maintenance',
        $2,
        $3::text::jsonb,
        $4::text::jsonb,
        CURRENT_TIMESTAMP + interval '1 day'
      )
      RETURNING id
      """,
      [state, worker, JSON.encode!(args), JSON.encode!(meta)]
    )

  job_id
end

defp owner_transaction(fun) do
  assert {:ok, result} =
           MigrationRepo.transaction(fn ->
             query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
             fun.()
           end)

  result
end

defp wake_generations!(submission_id) do
  %{rows: [[requested, consumed]]} =
    query!(
      MigrationRepo,
      """
      SELECT wake_requested_generation, wake_consumed_generation
      FROM jobs.job_submissions
      WHERE id = $1
      """,
      [submission_id]
    )

  {requested, consumed}
end

defp wake_columns_exist? do
  %{rows: [[count]]} =
    query!(
      MigrationRepo,
      """
      SELECT count(*)
      FROM information_schema.columns
      WHERE table_schema = 'jobs'
        AND table_name = 'job_submissions'
        AND column_name IN (
          'wake_requested_generation',
          'wake_consumed_generation'
        )
      """
    )

  count == 2
end
```

Keep every inserted job scheduled one day in the future. Never start Oban in
this test module while a migration is down.

- [ ] **Step 3: Specify schema, backfill, and metadata preservation**

First add the Ecto ownership contract:

```elixir
test "JobSubmission exposes zero application-owned wake defaults" do
  submission = struct(JobSubmission)

  assert Map.fetch(submission, :wake_requested_generation) == {:ok, 0}
  assert Map.fetch(submission, :wake_consumed_generation) == {:ok, 0}

  changeset =
    JobSubmission.wake_generation_changeset(submission, %{
      wake_requested_generation: 1,
      wake_consumed_generation: 1
    })

  assert Enum.any?(changeset.constraints, fn constraint ->
           constraint.constraint == "job_submissions_wake_generations_check" and
             constraint.field == :wake_consumed_generation
         end)
end
```

Then add:

```elixir
test "transfers valid legacy target generations exactly",
     %{event: event, fixture: fixture} do
  %{submission_id: submission_id} =
    insert_legacy_submission!(fixture, event, %{
      "singularity_wake_requested_generation" => 5,
      "singularity_wake_consumed_generation" => 3
    })

  migrate_up!()

  assert wake_generations!(submission_id) == {5, 3}
end

test "submission without a matching GenericWorker target keeps zero defaults",
     %{event: event, fixture: fixture} do
  owner_transaction(fn ->
    query!(
      MigrationRepo,
      """
      INSERT INTO jobs.job_submissions (
        id,
        vault_id,
        outbox_event_id,
        classification,
        idempotency_key,
        job_type,
        runner_job_id
      ) VALUES ($1, $2, $1, 'private', $3, 'asset_verify', '999999999')
      """,
      [event.id, fixture.vault_id, "unmatched-wake-#{Ecto.UUID.load!(event.id)}"]
    )
  end)

  migrate_up!()

  assert wake_generations!(event.id) == {0, 0}
end

test "adds bounded wake counters and transfers legacy and reconciler generations",
     %{event: event, fixture: fixture} do
  legacy_meta = %{
    "singularity_wake_requested_generation" => 5,
    "singularity_wake_consumed_generation" => 3,
    "unrelated" => "preserved"
  }

  %{submission_id: submission_id, target_id: target_id} =
    insert_legacy_submission!(fixture, event, legacy_meta, [
      {"available", 4},
      {"scheduled", 7},
      {"executing", 6},
      {"retryable", 2},
      {"completed", 99},
      {"discarded", 100},
      {"cancelled", 101}
    ])

  migrate_up!()

  assert wake_columns_exist?()
  assert wake_generations!(submission_id) == {7, 3}

  expected_meta =
    Map.put(legacy_meta, "wake_migration_test_id", Ecto.UUID.load!(event.id))

  assert %{rows: [[^expected_meta]]} =
           query!(MigrationRepo, "SELECT meta FROM jobs.oban_jobs WHERE id = $1", [target_id])

  assert %{rows: column_rows} =
           query!(
             MigrationRepo,
             """
             SELECT
               column_name,
               data_type,
               is_nullable,
               column_default
             FROM information_schema.columns
             WHERE table_schema = 'jobs'
               AND table_name = 'job_submissions'
               AND column_name IN (
                 'wake_requested_generation',
                 'wake_consumed_generation'
               )
             ORDER BY column_name
             """
           )

  assert [
           ["wake_consumed_generation", "bigint", "NO", consumed_default],
           ["wake_requested_generation", "bigint", "NO", requested_default]
         ] = column_rows

  assert consumed_default =~ "0"
  assert requested_default =~ "0"

  assert %{rows: [[constraint_definition]]} =
           query!(
             MigrationRepo,
             """
             SELECT pg_get_constraintdef(oid)
             FROM pg_catalog.pg_constraint
             WHERE conrelid = 'jobs.job_submissions'::regclass
               AND conname = 'job_submissions_wake_generations_check'
             """
           )

  assert constraint_definition =~ "wake_requested_generation >= 0"
  assert constraint_definition =~ "wake_consumed_generation >= 0"
  assert constraint_definition =~
           "wake_consumed_generation <= wake_requested_generation"
end
```

Add a second backfill case with stale target metadata and one active durable
reconciler:

```elixir
test "active reconciler recovers a generation erased from target metadata",
     %{event: event, fixture: fixture} do
  %{submission_id: submission_id} =
    insert_legacy_submission!(
      fixture,
      event,
      %{
        "singularity_wake_requested_generation" => 1,
        "singularity_wake_consumed_generation" => 1
      },
      [{"scheduled", 4}]
    )

  migrate_up!()

  assert wake_generations!(submission_id) == {4, 1}
end
```

- [ ] **Step 4: Specify fail-closed legacy validation**

Add a table-driven test with these exact invalid JSON values for both legacy
metadata keys:

```elixir
test "rejects malformed legacy target generations before casting",
     %{event: event, fixture: fixture} do
  invalid_values = ["1", -1, 1.5, nil, 9_223_372_036_854_775_808]

  for key <- [
        "singularity_wake_requested_generation",
        "singularity_wake_consumed_generation"
      ],
      value <- invalid_values do
    %{submission_id: submission_id} =
      insert_legacy_submission!(fixture, event, %{key => value})

    assert_raise Postgrex.Error,
                 ~r/invalid legacy Singularity wake generation/i,
                 fn ->
                   Ecto.Migrator.up(MigrationRepo, @version, @migration, log: false)
                 end

    refute migration_up?()
    refute wake_columns_exist?()
    delete_legacy_submission!(submission_id)
  end
end

test "rejects malformed active reconciler generations before casting",
     %{event: event, fixture: fixture} do
  for value <- ["1", -1, 0, 1.5, nil, 9_223_372_036_854_775_808] do
    %{submission_id: submission_id} =
      insert_legacy_submission!(fixture, event, %{}, [{"scheduled", value}])

    assert_raise Postgrex.Error,
                 ~r/invalid active wake reconciler generation/i,
                 fn ->
                   Ecto.Migrator.up(MigrationRepo, @version, @migration, log: false)
                 end

    refute migration_up?()
    refute wake_columns_exist?()
    delete_legacy_submission!(submission_id)
  end
end
```

Add `delete_legacy_submission!/1`:

```elixir
defp delete_legacy_submission!(submission_id) do
  owner_transaction(fn ->
    %{rows: [[runner_job_id]]} =
      query!(
        MigrationRepo,
        "SELECT runner_job_id FROM jobs.job_submissions WHERE id = $1",
        [submission_id]
      )

    query!(
      MigrationRepo,
      "DELETE FROM jobs.oban_jobs WHERE worker = $1 AND args->>'target_job_id' = $2",
      [@reconciler, runner_job_id]
    )

    query!(MigrationRepo, "DELETE FROM jobs.oban_jobs WHERE id::text = $1", [runner_job_id])
    query!(MigrationRepo, "DELETE FROM jobs.job_submissions WHERE id = $1", [submission_id])
  end)
end
```

Terminal and unmatched reconciler rows must not poison migration. Add one
`{"completed", "malformed"}` reconciler to a valid legacy fixture, add another
malformed reconciler whose target ID does not match, run `migrate_up!()`, and
assert the target metadata counters transfer normally.

- [ ] **Step 5: Specify defaults, constraint rejection, and downgrade guards**

After migrating up, use this exact loop:

```elixir
for {requested, consumed} <- [{-1, 0}, {0, -1}, {1, 2}] do
  assert_raise Postgrex.Error,
               ~r/job_submissions_wake_generations_check/,
               fn ->
                 owner_transaction(fn ->
                   query!(
                     MigrationRepo,
                     """
                     UPDATE jobs.job_submissions
                     SET wake_requested_generation = $2,
                         wake_consumed_generation = $3
                     WHERE id = $1
                     """,
                     [submission_id, requested, consumed]
                   )
                 end)
               end
end

assert wake_generations!(submission_id) == {0, 0}
```

Add a downgrade test that performs these phases in order:

```elixir
owner_transaction(fn ->
  query!(
    MigrationRepo,
    """
    UPDATE jobs.job_submissions
    SET wake_requested_generation = 2,
        wake_consumed_generation = 1
    WHERE id = $1
    """,
    [submission_id]
  )
end)

assert_raise Postgrex.Error, ~r/pending wake generations/i, fn -> migrate_down!() end

owner_transaction(fn ->
  query!(
    MigrationRepo,
    """
    UPDATE jobs.job_submissions
    SET wake_consumed_generation = wake_requested_generation
    WHERE id = $1
    """,
    [submission_id]
  )
end)
```

Retain the active reconciler inserted by the fixture and assert down raises
`active wake reconcilers`; then mark it `completed`. Insert the peer with:

```elixir
owner_transaction(fn ->
  query!(
    MigrationRepo,
    """
    INSERT INTO jobs.oban_peers (name, node, started_at, expires_at)
    VALUES (
      'wake-migration-test',
      'test@localhost',
      CURRENT_TIMESTAMP,
      CURRENT_TIMESTAMP + interval '1 minute'
    )
    """
  )
end)

assert_raise Postgrex.Error, ~r/Oban peers are active/i, fn -> migrate_down!() end

owner_transaction(fn ->
  query!(MigrationRepo, "DELETE FROM jobs.oban_peers WHERE name = 'wake-migration-test'")
end)

migrate_down!()
refute wake_columns_exist?()
```

Let `on_exit` restore the migration.

- [ ] **Step 6: Extend the historical harness constants before the migration exists**

Add to `migrations_test.exs`:

```elixir
@wake_migration_version 20_260_901_000_200
@wake_migration Singularity.Storage.Migrations.MoveWakeGenerationsToJobSubmissions
```

Extend `prepare_migration_state!/1` with the option:

```elixir
wake_repair?: context[:with_wake_repair] == true
```

The final state implications are:

```text
wake_repair?          -> classification_repair? -> private_notes?
classification_repair?                         -> private_notes?
```

At the start of `prepare_migration_state!/1`, derive the final booleans:

```elixir
include_wake? = Keyword.fetch!(options, :wake_repair?)

include_classification? =
  Keyword.fetch!(options, :classification_repair?) or include_wake?

include_notes? = Keyword.fetch!(options, :private_notes?) or include_classification?
```

Add this repository inventory:

```elixir
@runtime_repositories [
  Singularity.Storage.RequestRepo,
  Singularity.Storage.PreAuthRepo,
  Singularity.Storage.DispatcherRepo,
  Singularity.Storage.WorkerRepo
]
```

Replace the setup's migration preamble and simple
`on_exit(&restore_all_migrations!/0)` with:

```elixir
runtime_started? = runtime_started?()

if runtime_started? do
  :ok = Application.stop(:singularity_runtime)
end

on_exit(fn ->
  stop_runtime_repositories!()
  restore_all_migrations!()

  if runtime_started? do
    assert {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
  end
end)

prepare_migration_state!(
  private_notes?: context[:with_private_notes] == true,
  classification_repair?: context[:with_classification_repair] == true,
  wake_repair?: context[:with_wake_repair] == true
)

start_runtime_repositories!()
```

Keeping Runtime stopped is required: new code must never run while the wake
columns are deliberately absent, and the wake migration must never run while
Oban is active. The role-specific repositories provide the exact database
interfaces used by this test module without starting Oban, dispatchers, or
other Runtime services.

Add these helpers:

```elixir
defp runtime_started? do
  Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
    app == :singularity_runtime
  end)
end

defp start_runtime_repositories! do
  Enum.each(@runtime_repositories, fn repo ->
    assert {:ok, _pid} = repo.start_link()
  end)
end

defp stop_runtime_repositories! do
  Enum.each(Enum.reverse(@runtime_repositories), fn repo ->
    case Process.whereis(repo) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end)
end
```

Inside `prepare_migration_state!/1`, before the existing classification-down
block, add:

```elixir
if migration_up?(@wake_migration_version) and not include_wake? do
  :ok =
    Ecto.Migrator.down(
      MigrationRepo,
      @wake_migration_version,
      @wake_migration,
      log: false
    )

  purge_migration(@wake_migration)
end
```

After the Notes-up and classification-up blocks, add:

```elixir
if include_wake? and not migration_up?(@wake_migration_version) do
  :ok =
    Ecto.Migrator.up(
      MigrationRepo,
      @wake_migration_version,
      @wake_migration,
      log: false
    )
end
```

Only after wake is down may the helper down classification and Notes. When
wake is requested, apply Notes, classification, and wake in that order. The
`on_exit` callback stops manual repositories before applying all migrations
and only then restarts the complete Runtime application.

Append `@wake_migration_version` after `@classification_migration_version` in
the exact `Ecto.Migrator.run(..., :up, all: true)` result lists. Do not convert
those assertions to subset checks.

- [ ] **Step 7: Run the wake migration test and verify RED**

Run:

```bash
devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/wake_generation_migration_test.exs \
  --seed 0
```

Expected: the migration module/columns are absent and the new assertions fail.
The `on_exit` loader guard prevents cleanup from masking that RED result. Do
not create the migration before observing the failure.

### Task 6: Implement the canonical wake-generation schema and transfer

**Files:**

- Create: `apps/singularity_storage/priv/repo/migrations/20260901000200_move_wake_generations_to_job_submissions.exs`
- Modify: `apps/singularity_storage/lib/singularity/storage/schema/jobs/job_submission.ex`
- Modify: `apps/singularity_storage/test/singularity/storage/migrations_test.exs`
- Test: `apps/singularity_storage/test/singularity/storage/wake_generation_migration_test.exs`

- [ ] **Step 1: Create the wake-generation migration**

Create:

```elixir
defmodule Singularity.Storage.Migrations.MoveWakeGenerationsToJobSubmissions do
  use Ecto.Migration

  @generic_worker "Singularity.Storage.Jobs.GenericWorker"
  @reconciler "Singularity.Storage.Jobs.WakeReconciler"

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")
    lock_runtime_tables()

    execute("""
    ALTER TABLE jobs.job_submissions
      ADD COLUMN wake_requested_generation bigint NOT NULL DEFAULT 0,
      ADD COLUMN wake_consumed_generation bigint NOT NULL DEFAULT 0
    """)

    validate_legacy_generations()
    backfill_legacy_generations()

    execute("""
    ALTER TABLE jobs.job_submissions
      ADD CONSTRAINT job_submissions_wake_generations_check
        CHECK (
          wake_requested_generation >= 0
          AND wake_consumed_generation >= 0
          AND wake_consumed_generation <= wake_requested_generation
        )
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")
    lock_runtime_tables()

    execute("""
    DO $guard$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM jobs.oban_peers
        WHERE expires_at > CURRENT_TIMESTAMP
      ) THEN
        RAISE EXCEPTION 'cannot remove wake generations while Oban peers are active'
          USING ERRCODE = '55000';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM jobs.job_submissions
        WHERE wake_requested_generation <> wake_consumed_generation
      ) THEN
        RAISE EXCEPTION 'cannot remove wake generations while pending wake generations exist'
          USING ERRCODE = '55000';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM jobs.job_submissions AS submission
        JOIN jobs.oban_jobs AS target
          ON target.id::text = submission.runner_job_id
         AND target.worker = '#{@generic_worker}'
        JOIN jobs.oban_jobs AS reconciler
          ON reconciler.worker = '#{@reconciler}'
         AND reconciler.state IN ('available', 'scheduled', 'executing', 'retryable')
         AND reconciler.args->>'target_job_id' = target.id::text
      ) THEN
        RAISE EXCEPTION 'cannot remove wake generations while active wake reconcilers exist'
          USING ERRCODE = '55000';
      END IF;
    END
    $guard$
    """)

    execute("""
    ALTER TABLE jobs.job_submissions
      DROP CONSTRAINT job_submissions_wake_generations_check,
      DROP COLUMN wake_consumed_generation,
      DROP COLUMN wake_requested_generation
    """)

    execute("SET LOCAL ROLE NONE")
  end

  defp lock_runtime_tables do
    execute("LOCK TABLE jobs.oban_jobs IN SHARE ROW EXCLUSIVE MODE")
    execute("LOCK TABLE jobs.oban_peers IN SHARE ROW EXCLUSIVE MODE")
    execute("LOCK TABLE jobs.job_submissions IN ACCESS EXCLUSIVE MODE")
  end

  defp validate_legacy_generations do
    execute("""
    DO $validation$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM jobs.job_submissions AS submission
        JOIN jobs.oban_jobs AS target
          ON target.id::text = submission.runner_job_id
         AND target.worker = '#{@generic_worker}'
        CROSS JOIN LATERAL (
          VALUES
            (
              target.meta ? 'singularity_wake_requested_generation',
              target.meta->'singularity_wake_requested_generation'
            ),
            (
              target.meta ? 'singularity_wake_consumed_generation',
              target.meta->'singularity_wake_consumed_generation'
            )
        ) AS legacy(present, value)
        WHERE legacy.present
          AND (
            jsonb_typeof(legacy.value) = 'number'
            AND legacy.value #>> '{}' ~ '^(0|[1-9][0-9]*)$'
            AND (
              octet_length(legacy.value #>> '{}') < 19
              OR (
                octet_length(legacy.value #>> '{}') = 19
                AND (legacy.value #>> '{}') COLLATE "C" <= '9223372036854775807'
              )
            )
          ) IS NOT TRUE
      ) THEN
        RAISE EXCEPTION 'invalid legacy Singularity wake generation'
          USING ERRCODE = '22023';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM jobs.job_submissions AS submission
        JOIN jobs.oban_jobs AS target
          ON target.id::text = submission.runner_job_id
         AND target.worker = '#{@generic_worker}'
        JOIN jobs.oban_jobs AS reconciler
          ON reconciler.worker = '#{@reconciler}'
         AND reconciler.state IN ('available', 'scheduled', 'executing', 'retryable')
         AND reconciler.args->>'target_job_id' = target.id::text
        WHERE (
          jsonb_typeof(reconciler.args->'target_job_id') = 'number'
          AND reconciler.args->>'target_job_id' ~ '^[1-9][0-9]*$'
          AND jsonb_typeof(reconciler.args->'wake_generation') = 'number'
          AND reconciler.args->>'wake_generation' ~ '^[1-9][0-9]*$'
          AND (
              octet_length(reconciler.args->>'wake_generation') < 19
              OR (
                octet_length(reconciler.args->>'wake_generation') = 19
                AND (reconciler.args->>'wake_generation') COLLATE "C" <=
                      '9223372036854775807'
              )
            )
          ) IS NOT TRUE
      ) THEN
        RAISE EXCEPTION 'invalid active wake reconciler generation'
          USING ERRCODE = '22023';
      END IF;
    END
    $validation$
    """)
  end

  defp backfill_legacy_generations do
    execute("""
    WITH legacy AS (
      SELECT
        submission.id AS submission_id,
        target.id AS target_id,
        COALESCE(
          (target.meta->>'singularity_wake_requested_generation')::bigint,
          0
        ) AS requested,
        COALESCE(
          (target.meta->>'singularity_wake_consumed_generation')::bigint,
          0
        ) AS consumed
      FROM jobs.job_submissions AS submission
      JOIN jobs.oban_jobs AS target
        ON target.id::text = submission.runner_job_id
       AND target.worker = '#{@generic_worker}'
    ),
    transferred AS (
      SELECT
        legacy.submission_id,
        legacy.requested,
        legacy.consumed,
        COALESCE(
          max((reconciler.args->>'wake_generation')::bigint)
            FILTER (WHERE reconciler.id IS NOT NULL),
          0
        ) AS reconciler_generation
      FROM legacy
      LEFT JOIN jobs.oban_jobs AS reconciler
        ON reconciler.worker = '#{@reconciler}'
       AND reconciler.state IN ('available', 'scheduled', 'executing', 'retryable')
       AND reconciler.args->>'target_job_id' = legacy.target_id::text
      GROUP BY
        legacy.submission_id,
        legacy.requested,
        legacy.consumed
    )
    UPDATE jobs.job_submissions AS submission
    SET
      wake_requested_generation = greatest(
        transferred.requested,
        transferred.consumed,
        transferred.reconciler_generation
      ),
      wake_consumed_generation = transferred.consumed
    FROM transferred
    WHERE submission.id = transferred.submission_id
    """)
  end
end
```

The up migration intentionally locks `oban_peers` but does not treat a peer
lease as proof of an old-code process; the approved release procedure must
still stop workers. The down migration is destructive and therefore also
fails when an unexpired peer exists. Do not add a new runtime lease protocol.

- [ ] **Step 2: Add the Ecto ownership surface**

Add to the `JobSubmission` schema after `runner_job_id`:

```elixir
field :wake_requested_generation, :integer, default: 0
field :wake_consumed_generation, :integer, default: 0
```

Add this internal changeset:

```elixir
def wake_generation_changeset(submission, attrs) do
  submission
  |> cast(attrs, [:wake_requested_generation, :wake_consumed_generation])
  |> validate_number(:wake_requested_generation, greater_than_or_equal_to: 0)
  |> validate_number(:wake_consumed_generation, greater_than_or_equal_to: 0)
  |> check_constraint(:wake_consumed_generation,
    name: :job_submissions_wake_generations_check
  )
end
```

Do not add the counters to `reserve_changeset/2`; callers cannot choose
generation state at submission creation.

- [ ] **Step 3: Finish the migration-harness ordering**

Implement the implications described in Task 5 so setup always steps down in
this order:

```text
wake generation migration
classification deferral migration
private Notes migration
```

and steps up in the reverse dependency order:

```text
private Notes migration
classification deferral migration
wake generation migration
```

Runtime remains stopped for the whole `MigrationsTest` case. Only the four
role-specific repositories run while migrations are intentionally below head;
the `on_exit` callback stops them, restores all migrations, and then restarts
Runtime. The existing direct Notes downgrade tests stay tagged only
`:with_private_notes`; therefore both repair migrations are down for those
tests and their semantics remain unchanged.

- [ ] **Step 4: Run migration GREEN verification**

Run:

```bash
devenv shell -- mix format \
  apps/singularity_storage/priv/repo/migrations/20260901000200_move_wake_generations_to_job_submissions.exs \
  apps/singularity_storage/lib/singularity/storage/schema/jobs/job_submission.ex \
  apps/singularity_storage/test/singularity/storage/migrations_test.exs \
  apps/singularity_storage/test/singularity/storage/wake_generation_migration_test.exs

devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/wake_generation_migration_test.exs \
  apps/singularity_storage/test/singularity/storage/migrations_test.exs \
  --seed 0
```

Expected: schema, backfill, invalid-value, down-guard, and historical migration
tests all pass. Keep the Slice B work uncommitted until runtime behavior is
green in Task 7.

### Task 7: Move runtime wake ownership and adopt Oban 2.24 semantics

**Files:**

- Modify: `apps/singularity_storage/test/singularity/storage/effect_receipt_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/runner_submission_recovery_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs`
- Modify: `apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs`
- Modify: `apps/singularity_storage/lib/singularity/storage/jobs/progress.ex`
- Modify: `apps/singularity_storage/mix.exs`
- Test: Task 5 and 6 files

- [ ] **Step 1: Add the failing supported-Oban contract**

Add to `dependency_graph_test.exs` near the centralized Elixir requirement
test:

```elixir
test "storage declares and locks the supported Oban 2.24 line" do
  storage_dependencies =
    :singularity_storage
    |> project_config()
    |> Keyword.fetch!(:deps)

  assert {:oban, "~> 2.24"} in storage_dependencies

  assert {:hex, :oban, locked_version, _, _, _, "hexpm", _} =
           @repo_root
           |> Path.join("mix.lock")
           |> Mix.Dep.Lock.read()
           |> Map.fetch!(:oban)

  assert Version.match?(locked_version, "~> 2.24")
end
```

The lock assertion already passes. The declaration assertion must fail against
the current `~> 2.23` floor.

- [ ] **Step 2: Replace runtime metadata assertions with submission state**

Add to `effect_receipt_test.exs`:

```elixir
defp wake_generations(envelope) do
  assert %{rows: [[requested, consumed]]} =
           scoped_query(
             envelope,
             """
             SELECT wake_requested_generation, wake_consumed_generation
             FROM jobs.job_submissions
             WHERE id = $1 AND vault_id = $2
             """,
             [
               Ecto.UUID.dump!(envelope.job_id),
               Ecto.UUID.dump!(envelope.vault_id)
             ]
           )

  {requested, consumed}
end
```

Make these exact assertion changes:

- In `wake while the worker is executing prevents a full-interval lost
  snooze`, the first acknowledged snooze stores attempt `0` and
  `meta["snoozed"] == 1`; the second stores attempt `0` and snoozed `2`.
- In `wake before waiting progress is committed remains durable while the
  worker executes`, assert `{1, 0}` immediately after wake and `{1, 1}` after
  the worker commits waiting progress. The acknowledged snooze stores attempt
  `0` and snoozed `1`.
- In `durable reconciler closes a wake after the worker's final generation
  check`, assert `{1, 0}` before and after the stale snooze acknowledgement,
  attempt `0`, and snoozed `1`; after the reconciler, assert `{1, 1}` and the
  target is `available`.
- In `reconciler waits for Lifeline when an executor dies before snooze
  acknowledgement`, replace the metadata generation query with
  `wake_generations(envelope) == {1, 1}`. The executing attempt remains `1`
  because acknowledgement never completed.

For acknowledged snoozes, use queries shaped exactly like:

```elixir
assert %{rows: [["scheduled", scheduled_at, 0, 1]]} =
         query!(
           WorkerRepo,
           """
           SELECT
             state,
             scheduled_at,
             attempt,
             (meta->>'snoozed')::integer
           FROM jobs.oban_jobs
           WHERE id = $1
           """,
           [runner_id]
         )
```

Also assert on a normal target job after acknowledgement:

```elixir
assert %{rows: [[false, false]]} =
         query!(
           WorkerRepo,
           """
           SELECT
             meta ? 'singularity_wake_requested_generation',
             meta ? 'singularity_wake_consumed_generation'
           FROM jobs.oban_jobs
           WHERE id = $1
           """,
           [runner_id]
         )
```

Do not alter ordinary failure/retry attempt assertions; only snoozes preserve
the attempt budget in Oban 2.24.

- [ ] **Step 3: Prove runtime ignores legacy target metadata**

Add the missing alias near the other job aliases:

```elixir
alias Singularity.Storage.Jobs.WakeHandshake
```

Add this focused test to `effect_receipt_test.exs`:

```elixir
test "wake generations ignore historical target metadata", %{fixture: fixture} do
  envelope =
    submitted_envelope(fixture, 0, %{
      "wait_for_unlock" => true,
      "checkpoint" => %{"next_chunk_index" => 17}
    })

  assert {:ok, encoded} = EnvelopeCodec.encode(envelope)
  assert {:snooze, 60} = GenericWorker.perform(%Oban.Job{args: encoded})

  runner_id = runner_id(envelope)
  put_oban_state(runner_id, "scheduled")

  assert %{num_rows: 1} =
           query!(
             WorkerRepo,
             """
             UPDATE jobs.oban_jobs
             SET meta = meta || $2::text::jsonb
             WHERE id = $1
             """,
             [
               runner_id,
               JSON.encode!(%{
                 "singularity_wake_requested_generation" => 99,
                 "singularity_wake_consumed_generation" => 99
               })
             ]
           )

  assert :ok = ObanAdapter.wake_vault(%{}, envelope.vault_id)
  assert wake_generations(envelope) == {1, 1}

  assert %{rows: [[99, 99]]} =
           query!(
             WorkerRepo,
             """
             SELECT
               (meta->>'singularity_wake_requested_generation')::integer,
               (meta->>'singularity_wake_consumed_generation')::integer
             FROM jobs.oban_jobs
             WHERE id = $1
             """,
             [runner_id]
           )

  assert_no_active_wake_reconcilers()
  assert_context_absent()
end
```

The historical values remain untouched but cannot affect canonical counters.

Add the stale-reconciler monotonicity regression:

```elixir
test "a stale reconciler cannot lower the consumed generation", %{fixture: fixture} do
  envelope = submitted_envelope(fixture, 0)
  runner_id = runner_id(envelope)
  put_oban_state(runner_id, "scheduled")

  assert %{num_rows: 1} =
           scoped_query(
             envelope,
             """
             UPDATE jobs.job_submissions
             SET wake_requested_generation = 2,
                 wake_consumed_generation = 2
             WHERE id = $1
             """,
             [Ecto.UUID.dump!(envelope.job_id)]
           )

  assert %{num_rows: 1} =
           query!(
             WorkerRepo,
             """
             UPDATE jobs.oban_jobs
             SET meta = meta || $2::text::jsonb
             WHERE id = $1
             """,
             [
               runner_id,
               JSON.encode!(%{
                 "singularity_wake_requested_generation" => 2,
                 "singularity_wake_consumed_generation" => 0
               })
             ]
           )

  assert :done =
           ScopedRepo.transact(WorkerRepo, envelope, fn repo ->
             WakeHandshake.reconcile(repo, "jobs", envelope, runner_id, 1)
           end)

  assert wake_generations(envelope) == {2, 2}

  assert %{rows: [[0]]} =
           query!(
             WorkerRepo,
             """
             SELECT (meta->>'singularity_wake_consumed_generation')::integer
             FROM jobs.oban_jobs
             WHERE id = $1
             """,
             [runner_id]
           )

  assert_no_active_wake_reconcilers()
  assert_context_absent()
end
```

Before the repair, the legacy implementation changes target metadata from
consumed `0` to `1`; the test is RED. A submission-based implementation that
checks `not waiting?` before stale-generation closure lowers submission
consumed from `2` to `1`; the same test remains RED until consumption is
monotonic.

- [ ] **Step 4: Add recovery and restore-default assertions**

In `runner_submission_recovery_test.exs`, extend the permanent identity query
to select the counters:

```sql
SELECT
  count(*),
  max(runner_job_id),
  max(wake_requested_generation),
  max(wake_consumed_generation)
FROM jobs.job_submissions
WHERE outbox_event_id = $1
```

Assert the row is:

```elixir
[[1, ^runner_id_before, 0, 0]]
```

In the full V1 import case in `backup/restore_import_test.exs`, immediately
after `assert_all_logical_groups_imported/1`, add:

```elixir
assert %{rows: [[0, 0]]} =
         owner_transaction(fn ->
           query(
             """
             SELECT wake_requested_generation, wake_consumed_generation
             FROM jobs.job_submissions
             WHERE id = $1
             """,
             [Ecto.UUID.dump!(fixture.ids.job_submission_id)]
           )
         end)
```

Use the file's existing owner-query helper. Do not add the counters to either
logical schema or to the serialized fixture row.

- [ ] **Step 5: Run runtime and dependency tests and verify RED**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs

devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/effect_receipt_test.exs \
  apps/singularity_storage/test/singularity/storage/runner_submission_recovery_test.exs \
  apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs:264 \
  --seed 0
```

Expected:

- the dependency declaration remains `~> 2.23`;
- submission counters remain zero where the tests require generations;
- legacy metadata still drives generation 100 rather than generation 1; and
- Oban 2.24 attempt assertions already reflect the installed dependency.

Do not edit `WakeHandshake` or `mix.exs` before this RED result.

- [ ] **Step 6: Replace `WakeHandshake` with submission-owned state**

Keep the module's public signatures and replace its internals with this
structure:

```elixir
defmodule Singularity.Storage.Jobs.WakeHandshake do
  @moduledoc false

  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Storage.Schema.Jobs.JobProgress
  alias Singularity.Storage.Schema.Jobs.JobSubmission

  @generic_worker "Singularity.Storage.Jobs.GenericWorker"
  @wakeable_states ["executing", "scheduled", "retryable"]

  @spec request(module(), String.t(), JobEnvelope.t(), pos_integer()) ::
          {:ok, %{generation: pos_integer(), state: String.t()}}
          | :skipped
          | {:error, Error.t()}
  def request(repo, prefix, %JobEnvelope{} = envelope, runner_job_id)
      when is_binary(prefix) and is_integer(runner_job_id) and runner_job_id > 0 do
    with %Oban.Job{} = job <-
           lock_job(repo, prefix, envelope, runner_job_id, @wakeable_states),
         %JobSubmission{} = submission <-
           lock_submission(repo, envelope, runner_job_id) do
      cond do
        job.state == "executing" ->
          request_generation(repo, submission, job.state)

        waiting?(repo, envelope) ->
          request_generation(repo, submission, job.state)

        true ->
          :skipped
      end
    else
      nil -> :skipped
    end
  end

  def request(_repo, _prefix, _envelope, _runner_job_id),
    do: {:error, Error.new(:invalid)}

  @spec consume(module(), String.t(), JobEnvelope.t(), pos_integer()) ::
          :pending | :none | :skipped | {:error, Error.t()}
  def consume(repo, prefix, %JobEnvelope{} = envelope, runner_job_id)
      when is_binary(prefix) and is_integer(runner_job_id) and runner_job_id > 0 do
    with %Oban.Job{} <-
           lock_job(repo, prefix, envelope, runner_job_id, @wakeable_states),
         %JobSubmission{} = submission <-
           lock_submission(repo, envelope, runner_job_id),
         true <- waiting?(repo, envelope) do
      if submission.wake_requested_generation > submission.wake_consumed_generation do
        case put_generations(repo, submission, %{
               wake_consumed_generation: submission.wake_requested_generation
             }) do
          {:ok, _submission} -> :pending
          {:error, %Ecto.Changeset{}} -> storage_unavailable()
        end
      else
        :none
      end
    else
      nil -> :skipped
      false -> :skipped
    end
  end

  def consume(_repo, _prefix, _envelope, _runner_job_id),
    do: {:error, Error.new(:invalid)}

  @spec reconcile(module(), String.t(), JobEnvelope.t(), pos_integer(), pos_integer()) ::
          {:retry, Oban.Job.t()} | :wait | :done | {:error, Error.t()}
  def reconcile(repo, prefix, %JobEnvelope{} = envelope, runner_job_id, wake_generation)
      when is_binary(prefix) and is_integer(runner_job_id) and runner_job_id > 0 and
             is_integer(wake_generation) and wake_generation > 0 do
    with %Oban.Job{} = job <- lock_job(repo, prefix, envelope, runner_job_id, :all),
         %JobSubmission{} = submission <- lock_submission(repo, envelope, runner_job_id) do
      cond do
        submission.wake_requested_generation < wake_generation ->
          :done

        job.state == "executing" ->
          :wait

        submission.wake_consumed_generation >= wake_generation ->
          :done

        not waiting?(repo, envelope) ->
          consume_generation(repo, submission, wake_generation, :done)

        job.state in ["scheduled", "retryable"] ->
          consume_generation(repo, submission, wake_generation, {:retry, job})

        true ->
          consume_generation(repo, submission, wake_generation, :done)
      end
    else
      nil -> :done
    end
  end

  def reconcile(_repo, _prefix, _envelope, _runner_job_id, _wake_generation),
    do: {:error, Error.new(:invalid)}

  defp lock_job(repo, prefix, envelope, runner_job_id, states) do
    query =
      from(job in Oban.Job,
        where:
          job.id == ^runner_job_id and
            job.worker == ^@generic_worker and
            fragment("?->>'job_id' = ?", job.args, ^envelope.job_id) and
            fragment("?->>'vault_id' = ?", job.args, ^envelope.vault_id) and
            fragment("?->>'principal_id' = ?", job.args, ^envelope.principal_id),
        lock: "FOR UPDATE"
      )

    query =
      if states == :all do
        query
      else
        where(query, [job], job.state in ^states)
      end

    repo.one(query, prefix: prefix)
  end

  defp lock_submission(repo, envelope, runner_job_id) do
    repo.one(
      from(submission in JobSubmission,
        where:
          submission.id == ^envelope.job_id and
            submission.outbox_event_id == ^envelope.job_id and
            submission.vault_id == ^envelope.vault_id and
            submission.runner_job_id == ^Integer.to_string(runner_job_id) and
            submission.job_type == ^envelope.job_type and
            submission.classification == ^envelope.classification,
        lock: "FOR UPDATE"
      )
    )
  end

  defp waiting?(repo, envelope) do
    query =
      from(progress in JobProgress,
        where:
          progress.submission_id == ^envelope.job_id and
            progress.vault_id == ^envelope.vault_id,
        select: progress.state,
        limit: 1,
        lock: "FOR UPDATE"
      )

    case {envelope.job_type, repo.one(query)} do
      {"backup", :waiting_for_backup_key} -> true
      {_job_type, :waiting_for_unlock} -> true
      _not_waiting -> false
    end
  end

  defp consume_generation(repo, submission, wake_generation, result) do
    next_consumed = max(submission.wake_consumed_generation, wake_generation)

    case put_generations(repo, submission, %{
           wake_consumed_generation: next_consumed
         }) do
      {:ok, _submission} -> result
      {:error, %Ecto.Changeset{}} -> storage_unavailable()
    end
  end

  defp request_generation(repo, submission, state) do
    next_generation =
      max(
        submission.wake_requested_generation,
        submission.wake_consumed_generation
      ) + 1

    case put_generations(repo, submission, %{
           wake_requested_generation: next_generation
         }) do
      {:ok, _submission} -> {:ok, %{generation: next_generation, state: state}}
      {:error, %Ecto.Changeset{}} -> storage_unavailable()
    end
  end

  defp put_generations(repo, submission, attrs) do
    submission
    |> JobSubmission.wake_generation_changeset(attrs)
    |> repo.update()
  end

  defp storage_unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
```

This preserves the required lock order: target Oban job, submission, then
progress. Do not change `ObanAdapter`, `GenericWorker`, or reconciler args.

- [ ] **Step 7: Raise only the declared Oban floor**

In `apps/singularity_storage/mix.exs`, change only:

```elixir
{:oban, "~> 2.24"}
```

Run:

```bash
devenv shell -- mix deps.get
git diff --exit-code -- mix.lock
```

Expected: dependency resolution succeeds and `mix.lock` is unchanged. If the
lock changes, stop and diagnose; do not accept unrelated churn.

- [ ] **Step 8: Run Slice B GREEN verification**

Run:

```bash
devenv shell -- mix format \
  apps/singularity_storage/mix.exs \
  apps/singularity_storage/lib/singularity/storage/jobs/progress.ex \
  apps/singularity_storage/lib/singularity/storage/schema/jobs/job_submission.ex \
  apps/singularity_storage/priv/repo/migrations/20260901000200_move_wake_generations_to_job_submissions.exs \
  apps/singularity_storage/test/singularity/storage/effect_receipt_test.exs \
  apps/singularity_storage/test/singularity/storage/migrations_test.exs \
  apps/singularity_storage/test/singularity/storage/runner_submission_recovery_test.exs \
  apps/singularity_storage/test/singularity/storage/wake_generation_migration_test.exs \
  apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs \
  apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs

devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs

devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/wake_generation_migration_test.exs \
  apps/singularity_storage/test/singularity/storage/migrations_test.exs \
  apps/singularity_storage/test/singularity/storage/effect_receipt_test.exs \
  apps/singularity_storage/test/singularity/storage/runner_submission_recovery_test.exs \
  --seed 0

devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs:264 \
  --seed 0

if rg -n 'singularity_wake_(requested|consumed)_generation' \
  apps/singularity_storage/lib; then
  echo "legacy wake metadata keys remain in runtime code" >&2
  exit 1
fi

git diff --check
git diff --exit-code -- mix.lock
```

Expected:

- all focused tests pass;
- `rg` has no runtime-library matches;
- only the new migration and tests retain legacy metadata key strings;
- the stale snooze acknowledgement leaves submission `{1, 0}` until the
  reconciler consumes it;
- acknowledged snoozes preserve attempt `0` and increment `"snoozed"`; and
- logical restore initializes both counters to zero without format changes.

- [ ] **Step 9: Commit Slice B only**

```bash
git add -- \
  apps/singularity_storage/mix.exs \
  apps/singularity_storage/lib/singularity/storage/jobs/progress.ex \
  apps/singularity_storage/lib/singularity/storage/schema/jobs/job_submission.ex \
  apps/singularity_storage/priv/repo/migrations/20260901000200_move_wake_generations_to_job_submissions.exs \
  apps/singularity_storage/test/singularity/storage/effect_receipt_test.exs \
  apps/singularity_storage/test/singularity/storage/migrations_test.exs \
  apps/singularity_storage/test/singularity/storage/runner_submission_recovery_test.exs \
  apps/singularity_storage/test/singularity/storage/wake_generation_migration_test.exs \
  apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs \
  apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs

git commit -m "fix(jobs): preserve wakes across Oban snoozes"
```

Run `git status --short`. Expected: clean. Do not include `mix.lock`, Slice A
files already committed, backup schema modules, release files, or unrelated
changes.

### Task 8: Prove the complete Phase 0 gate and stop

**Files:**

- Verify: every allowlisted file
- Verify unchanged: every protected path in this plan

- [ ] **Step 1: Re-run both original reproductions**

Run:

```bash
devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/asset_search_projection_test.exs:553

devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/effect_receipt_test.exs:309
```

Expected: both pass. These commands are retained as the direct before/after
evidence for the two root causes.

- [ ] **Step 2: Run the complete affected matrix**

Run:

```bash
devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/migrations_test.exs \
  apps/singularity_storage/test/singularity/storage/note_schema_test.exs \
  apps/singularity_storage/test/singularity/storage/classification_inheritance_test.exs \
  apps/singularity_storage/test/singularity/storage/asset_search_projection_test.exs \
  apps/singularity_storage/test/singularity/storage/postgres/asset_repository_test.exs \
  apps/singularity_storage/test/singularity/storage/wake_generation_migration_test.exs \
  apps/singularity_storage/test/singularity/storage/effect_receipt_test.exs \
  apps/singularity_storage/test/singularity/storage/runner_submission_recovery_test.exs \
  --seed 0

devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs:264 \
  --seed 0

devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs \
  apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs \
  apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
```

Expected: all pass with no warnings or leaked database context.

- [ ] **Step 3: Verify formatting and compilation**

Run:

```bash
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
git status --short
```

Expected: both commands pass and the tree is clean. If the format check fails,
run `mix format` only on the reported allowlisted files, inspect the diff,
rerun the affected red-green tests, and amend only the owning behavioral
commit before proceeding.

- [ ] **Step 4: Run the canonical complete gate verbatim**

Run from a clean committed worktree:

```bash
(
set -euo pipefail
trap 'devenv processes down' EXIT

devenv up -d
devenv processes wait --timeout 120

devenv shell -- bash \
  apps/singularity_storage/priv/repo/bootstrap_roles.sh

devenv shell -- mix deps.get
devenv shell -- mix deps.unlock --check-unused
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test
devenv shell -- mix singularity.test.integration
devenv shell -- mix singularity.test.restore

devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
devenv shell -- mix npm.verify
devenv shell -- mix duskmoon_bundler.js.check
devenv shell -- mix npm.run test:js
devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind
devenv shell -- mix npm.run test:e2e

devenv shell -- mix xref graph --format cycles --fail-above 0
nix run nixpkgs#actionlint -- \
  .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/release.yml

git diff --check
git status --short
test -z "$(git status --porcelain)"
)
```

Expected: every stage passes, including the previously unrun restore,
frontend, browser, xref, and actionlint stages. A failure outside the allowlist
is reported and stops work; it is not repaired under this plan.

- [ ] **Step 5: Obtain independent specification and quality reviews**

Dispatch two fresh reviewers in parallel.

Specification review must check every acceptance item in the approved design,
including:

- exact FK identity and shape, equality, commit timing, avoidance of the
  add-FK `SHARE ROW EXCLUSIVE` mode, and bounded evidence that no requested
  referenced-table lock mode conflicts with `ROW EXCLUSIVE` while compatible
  weaker locks remain possible;
- complete versus partial classification transitions;
- one-time legacy wake transfer and malformed-value refusal;
- runtime lock order and canonical submission ownership;
- Oban attempt/snooze semantics;
- restore defaults and immutable backup formats;
- Vault/privacy boundaries; and
- all stop conditions.

Quality review must inspect:

- migration SQL type/range validation before casts;
- table and row lock order;
- down guards and reversibility;
- the real stale-snapshot snooze barrier;
- no remaining runtime metadata writes;
- changeset/error mapping;
- dependency-floor enforcement and unchanged lock; and
- absence of unrelated refactors.

Every Critical or Important finding must be fixed with a new focused RED/GREEN
cycle, committed, re-reviewed, and followed by another complete gate on the
new HEAD. Suggestions outside scope are reported but not implemented.

- [ ] **Step 6: Run the final mechanical scope audit**

Run:

```bash
(
set -euo pipefail

expected_paths="$(
  printf '%s\n' \
    AGENTS.md \
    apps/singularity_runtime/lib/mix/tasks/singularity.test.browser.ex \
    apps/singularity_runtime/test/mix/tasks/singularity.test.browser_test.exs \
    apps/singularity_runtime/test/singularity/runtime/asset_deletion_test.exs \
    apps/singularity_storage/lib/singularity/storage/jobs/progress.ex \
    apps/singularity_storage/lib/singularity/storage/schema/jobs/job_submission.ex \
    apps/singularity_storage/mix.exs \
    apps/singularity_storage/priv/repo/migrations/20260901000100_defer_resource_version_classification_fkey.exs \
    apps/singularity_storage/priv/repo/migrations/20260901000200_move_wake_generations_to_job_submissions.exs \
    apps/singularity_storage/test/singularity/storage/asset_search_projection_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs \
    apps/singularity_storage/test/singularity/storage/classification_inheritance_test.exs \
    apps/singularity_storage/test/singularity/storage/effect_receipt_test.exs \
    apps/singularity_storage/test/singularity/storage/migrations_test.exs \
    apps/singularity_storage/test/singularity/storage/note_schema_test.exs \
    apps/singularity_storage/test/singularity/storage/postgres/asset_repository_test.exs \
    apps/singularity_storage/test/singularity/storage/roles_test.exs \
    apps/singularity_storage/test/singularity/storage/runner_submission_recovery_test.exs \
    apps/singularity_storage/test/singularity/storage/wake_generation_migration_test.exs \
    apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs \
    apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs \
    apps/singularity_web/test/singularity/web/asset_toolchain_contract_test.exs \
    docs/superpowers/plans/2026-09-01-singularity-v0.2-phase-0-blocker-repairs.md \
    docs/superpowers/specs/2026-09-01-singularity-v0.2-phase-0-blocker-repair-design.md \
    playwright.config.ts |
    sort
)"

actual_paths="$(git diff --name-only 78b929a..HEAD | sort)"
test "$actual_paths" = "$expected_paths"

git diff --exit-code 78b929a -- \
  apps/singularity_storage/priv/repo/migrations/20260818000100_create_private_markdown_notes.exs \
  apps/singularity_storage/lib/singularity/storage/backup/logical_schema.ex \
  apps/singularity_storage/lib/singularity/storage/backup/logical_schema_v2.ex \
  mix.lock \
  .github/workflows/release.yml

test "$(find apps/singularity_storage/priv/repo/migrations -maxdepth 1 -type f -name '20260901*.exs' | wc -l | tr -d ' ')" = "2"

for mix_file in mix.exs apps/*/mix.exs; do
  rg -q 'version: "0\.1\.0"' "$mix_file"
done

test -z "$(git diff --name-only 78b929a..HEAD -- apps | rg -i 'vault' || true)"

commit_subjects="$(git log --format='%s' --reverse 78b929a..HEAD)"
governance_position="$(printf '%s\n' "$commit_subjects" | rg -n '^docs\(scope\): authorize approved phase 0 blocker repairs$' | cut -d: -f1)"
classification_position="$(printf '%s\n' "$commit_subjects" | rg -n '^fix\(storage\): make classification strengthening atomic$' | cut -d: -f1)"
wake_position="$(printf '%s\n' "$commit_subjects" | rg -n '^fix\(jobs\): preserve wakes across Oban snoozes$' | cut -d: -f1)"
roles_governance_position="$(printf '%s\n' "$commit_subjects" | rg -n '^docs\(scope\): authorize roles test isolation repair$' | cut -d: -f1)"
roles_isolation_position="$(printf '%s\n' "$commit_subjects" | rg -n '^test\(storage\): isolate dispatcher role claim$' | cut -d: -f1)"

test "$governance_position" -lt "$classification_position"
test "$classification_position" -lt "$wake_position"
test "$wake_position" -lt "$roles_governance_position"
test "$roles_governance_position" -lt "$roles_isolation_position"

git log --format='%h %s' --reverse 78b929a..HEAD
git diff --check
test -z "$(git status --porcelain)"
)
```

Expected:

- changed files exactly match the original allowlist plus the separately
  approved correction list (25 paths total);
- exactly two new 2026-09-01 migrations exist;
- released migrations, backup schemas, lockfile, and release workflow are
  unchanged;
- all eight Mix project versions remain `0.1.0`;
- no Vault production path changed;
- the original governance commit precedes both production commits, and the
  roles-isolation governance commit follows them and precedes the roles test
  commit; and
- the worktree is clean.

- [ ] **Step 7: Report and stop at the Phase 0 acceptance boundary**

The execution report must include:

- final branch and SHA;
- commits in order;
- exact changed files and the two new migrations;
- RED and GREEN evidence for each slice;
- complete-gate command results and test totals;
- independent review results and any resolved findings;
- protected-file hashes/diff evidence;
- confirmation that no Vault, backup-format, version, release, or Phase 1 work
  occurred; and
- remaining rollout note: a future deployment must stop Oban, migrate before
  starting new code, and must not run old/new wake implementations together.

Stop. Do not merge, push, dispatch remote workflows, bump versions, tag,
release, deploy, create a Phase 1 branch, or start Phase 1.
