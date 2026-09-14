# Singularity v0.2.0 Phase 1 Acceptance Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the complete Phase 1 acceptance gate by making the legacy upload-grant migration test independent of later forward-only migrations.

**Architecture:** Use the existing `Singularity.Storage.MigrationTestEnvironment` to create a disposable database migrated only through the version immediately before `SecureUploadGrantCsrf`. Exercise the existing migration directly in that historical database while preserving every behavioral assertion and leaving production code, released migrations, Vault behavior, and workflow configuration unchanged.

**Tech Stack:** Elixir 1.18, Ecto SQL migrations, PostgreSQL, ExUnit, devenv

---

## File structure

- Modify `apps/singularity_storage/test/singularity/storage/upload_grant_csrf_migration_test.exs` only to isolate its migration state.
- Update `docs/superpowers/plans/2026-09-14-singularity-v0.2-phase-1-acceptance-repair.md` only to check completed steps and append exact verification evidence.
- Do not modify production modules, released migrations, Vault tests or behavior, dependencies, workflows, or any other test assertion.

Track completed steps outside the worktree until the complete README gate exits
successfully. Do not edit this plan or its checkboxes before that clean-worktree
gate. Afterward, update the checkboxes and verification record together.

### Task 1: Preserve the failing acceptance contract

**Files:**
- Test: `apps/singularity_storage/test/singularity/storage/upload_grant_csrf_migration_test.exs:1`

- [x] **Step 1: Confirm the worktree begins at the approved design commit**

Run:

```bash
git status --short --branch
git log -2 --oneline
```

Expected: branch `codex/v0.2-phase-1-acceptance-repair`, clean worktree, and design commit `2da8609` above Phase 1 commit `9e20fed`.

- [x] **Step 2: Run the focused integration test and preserve the red result**

Run:

```bash
(
set -euo pipefail
trap 'devenv processes down' EXIT
devenv up -d
devenv processes wait --timeout 120
devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/upload_grant_csrf_migration_test.exs
)
```

Expected: exit code 2; 1 test, 1 failure; `Ecto.MigrationError` reports `Knowledge links migration is forward-only` from `CreateKnowledgeLinksAndOrganization.down/0`.

### Task 2: Isolate the historical migration state

**Files:**
- Modify: `apps/singularity_storage/test/singularity/storage/upload_grant_csrf_migration_test.exs:6`
- Test: `apps/singularity_storage/test/singularity/storage/upload_grant_csrf_migration_test.exs:19`

- [x] **Step 1: Add the migration environment and explicit ceiling**

Replace the aliases and version attributes at the top of the test with:

```elixir
alias Singularity.Storage.{Fixtures, MigrationRepo, MigrationTestEnvironment}
alias Singularity.Storage.Migrations.SecureUploadGrantCsrf

@version 20_260_728_000_100
@previous_version 20_260_722_001_000
```

`@previous_version` is `20260722001000_guard_active_domain_key_envelopes.exs`, the latest migration before `SecureUploadGrantCsrf`.

- [x] **Step 2: Remove shared-database preparation**

Delete the module `setup` block. The disposable migration environment owns database creation and cleanup, so truncating the fully migrated integration database is no longer part of this test.

- [x] **Step 3: Wrap the established assertions in the isolated database**

Replace the beginning of the test body through the existing manual `try` setup with:

```elixir
test "legacy grants fail closed and the migration round-trips their prior consumption state" do
  MigrationTestEnvironment.with_database(@previous_version, fn _environment ->
    %{one: fixture} = Fixtures.two_vaults!()
    assert Code.ensure_loaded?(SecureUploadGrantCsrf)

    unconsumed_id = insert_legacy_grant!(fixture, nil)
    consumed_at = DateTime.add(DateTime.utc_now(:microsecond), -60, :second)
    consumed_id = insert_legacy_grant!(fixture, consumed_at)

    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               @version,
               SecureUploadGrantCsrf,
               log: false
             )
```

Keep the existing digest-length, invalid-digest, rollback-state, and final reapply assertions unchanged inside the callback.

- [x] **Step 4: Use the migration environment for cleanup**

Remove the old manual `after` block, including `Ecto.Migrator.run(..., :up, all: true)`, `Supervisor.stop/1`, and compiler-option restoration. Close the callback and test with:

```elixir
  end)
end
```

Delete the now-unused private `migrations_path/0` helper. Do not change `insert_legacy_grant!/2` or `with_owner/1`.

- [x] **Step 5: Format and inspect the surgical diff**

Run:

```bash
devenv shell -- mix format \
  apps/singularity_storage/test/singularity/storage/upload_grant_csrf_migration_test.exs
git diff --check
git diff -- \
  apps/singularity_storage/test/singularity/storage/upload_grant_csrf_migration_test.exs
```

Expected: the diff changes only migration-environment setup and cleanup; all behavioral assertions remain present.

- [x] **Step 6: Run the focused test and verify green**

Run:

```bash
(
set -euo pipefail
trap 'devenv processes down' EXIT
devenv up -d
devenv processes wait --timeout 120
devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/upload_grant_csrf_migration_test.exs
)
```

Expected: exit code 0; 1 test, 0 failures.

- [x] **Step 7: Commit the test-only repair**

Run:

```bash
git add \
  apps/singularity_storage/test/singularity/storage/upload_grant_csrf_migration_test.exs
git diff --cached --check
git diff --cached --name-only
git commit -m "test(storage): isolate upload grant migration state"
```

Expected: the staged file list contains only the upload-grant migration test.

### Task 3: Re-run the complete Phase 1 acceptance gate

**Files:**
- Update: `docs/superpowers/plans/2026-09-14-singularity-v0.2-phase-1-acceptance-repair.md`

- [x] **Step 1: Run the exact complete README verification sequence**

Run from one shell so cleanup remains active:

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

Expected: exit code 0; backend, integration, restore, frontend, browser, xref, and workflow checks all pass; cleanup stops local services; worktree remains clean.

If any command fails, stop without changing unrelated code and report the exact failing command and output.

- [x] **Step 2: Append the execution record**

Append a `## Verification record` section to this plan containing:

- repair commit SHA;
- changed file list;
- confirmation that no production, migration, or Vault behavior changed;
- focused test command and result;
- complete README gate command and result;
- remaining risks, including that Phase 2 has not started and release publication remains unauthorized.

- [x] **Step 3: Commit the verification record**

Run:

```bash
git add \
  docs/superpowers/plans/2026-09-14-singularity-v0.2-phase-1-acceptance-repair.md
git diff --cached --check
git diff --cached --name-only
git commit -m "docs(phase1): record acceptance repair verification"
```

Expected: the staged file list contains only this plan.

- [x] **Step 4: Audit final scope and history**

Run:

```bash
git status --short --branch
git diff --check main...HEAD
git diff --name-only main...HEAD
git log --oneline main..HEAD
```

Expected changed files:

```text
apps/singularity_storage/test/singularity/storage/upload_grant_csrf_migration_test.exs
docs/superpowers/plans/2026-09-14-singularity-v0.2-phase-1-acceptance-repair.md
docs/superpowers/specs/2026-09-14-singularity-v0.2-phase-1-acceptance-repair-design.md
```

Expected: clean worktree, no whitespace errors, and no production or released-migration changes.

## Verification record

- Test-only repair commit: `743309e3ee30e7d30b9ee98c57d5e9101dcfd2ad`
- Repair changed file: `apps/singularity_storage/test/singularity/storage/upload_grant_csrf_migration_test.exs`
- Scope confirmation: the repair changed no production file, released migration,
  dependency, workflow, or Vault behavior.
- Task 1 red contract: the focused `mix singularity.test.integration
  apps/singularity_storage/test/singularity/storage/upload_grant_csrf_migration_test.exs`
  command exited 2 with 1 test, 1 failure. `Ecto.MigrationError` reported
  `Knowledge links migration is forward-only` from
  `CreateKnowledgeLinksAndOrganization.down/0`.
- Task 2 focused green: the same focused integration command exited 0 with
  1 test, 0 failures. Independent verification also exited 0 with 1 test,
  0 failures, a clean worktree, and no leaked database or service.
- Approved narrow deviation: `MigrationTestEnvironment` stops `MigrationRepo`
  before invoking its callback, so the test retains a callback-scoped
  `MigrationRepo.start_link`; the environment owns repository stop, database
  drop, and configuration restoration. Specification and quality review
  approved this deviation.
- Complete README gate: the exact single-shell sequence in Task 3 Step 1 exited
  0. Role bootstrap, `mix deps.get`, `mix deps.unlock --check-unused`,
  `mix format --check-formatted`, and `mix compile --warnings-as-errors` passed.
  `mix test` reported: core 10 properties and 105 tests, domains 38 tests,
  storage 796 tests with 537 excluded, retrieval 26 tests, ingest 30 tests,
  runtime 544 tests with 78 excluded, and web 164 tests; every application
  reported 0 failures. `mix singularity.test.integration` reported storage
  796 tests, 0 failures, 259 excluded and runtime 544 tests, 0 failures,
  466 excluded; applications with no integration cases reported all tests
  excluded and 0 failures. `mix singularity.test.restore` exited 0; both
  restore scenarios reported `maintenance_mode ok=true`,
  `empty_destination ok=true`, and `restore complete`.
- Frontend and browser gate: frozen npm installation installed 166 packages;
  `mix npm.verify` reported that `node_modules` matches the 166-package lockfile;
  `mix duskmoon_bundler.js.check` reported 22 formatted files and no lint issues;
  `mix npm.run test:js` reported 9 files and 197 tests passed; the Tailwind and
  JavaScript build exited 0; `mix npm.run test:e2e` reported 10 tests passed.
- Architecture and workflow gate: xref reported `No cycles found`; actionlint
  exited 0 with no diagnostics. `git diff --check`, `git status --short`, and
  the porcelain-cleanliness assertion all exited 0 with no output.
- Cleanup proof: the single-shell EXIT trap invoked `devenv processes down`.
  A subsequent idempotent cleanup check reported
  `No process manager is running. Start processes first with devenv up -d`,
  and the worktree remained clean.
- Remaining risks and exclusions: Phase 2 has not started. Remote `main`, push,
  release publication, and deployment remain unverified and unauthorized.
