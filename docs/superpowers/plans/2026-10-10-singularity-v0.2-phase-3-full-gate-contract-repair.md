# Phase 3 legacy storage contract repair plan

> Use subagent-driven-development for disjoint implementation and independent
> review. The parent alone runs formatting, builds, tests, PostgreSQL, and Git.

**Goal:** Repair the 14 source-diagnosed legacy Storage contract failures without
changing production behavior or weakening the original assertions.

**Architecture:** Explicit generated-fixture capability assignments; an exact
Phase 3 read-permission matrix separate from Document-only queries; semantic
timestamp comparison. Follow the
[design](../specs/2026-10-10-singularity-v0.2-phase-3-full-gate-contract-repair-design.md)
and the existing continuous authority. No human approval pause is required.

**Environment:** Current project-local Phase 3 worktree, Elixir/ExUnit, owned
PostgreSQL 17, established `.devenv/phase3-integration.sh`. Shared dependencies
are selected through `MIX_DEPS_PATH`; no production service is involved.

## Task 1: Freeze and characterize the failure

- [x] Record clean baseline `999b2fc7ce5308156203944eb0f474a5cdb2a44f`, complete
  gate `37888` exit 2, exact counts/seeds, cleanup, and unchanged source/locks.
- [x] Parent runs all five unchanged owning files and records each actual
  result. This is diagnosis; an isolated PASS does not erase the full-run FAIL.

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/note_mutation_rollback_test.exs apps/singularity_storage/test/singularity/storage/note_mutation_concurrency_test.exs apps/singularity_storage/test/singularity/storage/restore_reconciliation_test.exs apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs --seed 918339
```

Pre-edit characterization `98049`, exit 2, seed `918339`: **59 executed tests,
14 failures**, 16.1 seconds. All 14 diagnosed failures reproduced, including
the offset-sensitive deadline comparison. Allocation
`singularity_test_6410f6657ce52aa22bd3f579` was disposed and PostgreSQL stopped.

- [x] Close independent exact-document SPEC and QUALITY review. Preserve the
  unresolved selective-plan and Runtime failures as separate workstreams.
  Nonauthor `search_observer_actual_review` passed both reviews after the old
  plan's earlier scoped PASS was clearly labeled historical. All 21 local
  Markdown targets in the four changed documents resolved (`ed2537`).

## Task 2: Implement the bounded test corrections

Parallel ownership is disjoint; workers are not alone and must preserve other
edits. No worker executes tests or mutates services/Git.

- [x] Note-fixture implementer owns only
  `apps/singularity_storage/test/singularity/storage/note_mutation_rollback_test.exs`,
  `note_mutation_concurrency_test.exs`, and `restore_reconciliation_test.exs`
  in that same directory. Add the existing `note.write` catalog/assignment
  pattern for the exact generated principal/owner. Preserve every original
  assertion and test deadline. In the Note restore helper, additionally prove
  no Note capability remains after the original deletion, before recovery.
- [x] Parent owns only `knowledge_grants_test.exs` and
  `document_lifecycle_test.exs` in the same directory. Add the distinct
  canonical-read allowlist and use it only for the final matrix's three
  branches; retain all denials and RLS/ACL checks. Parse the deadline before
  strict instant comparison, retaining the existing lifecycle assertions.

No shared fixture, production, migration, Vault-facing helper, or unrelated
test edits are expected. If a new required repair is evidenced, diagnose it
and update the bounded design instead of guessing or broadening silently.

## Task 3: Verify the exact diff

- [x] Parent formats only the five owned files, then runs their complete batch
  above with seed `918339`. Keep explicit executed/excluded counts.
  `28694`, exit 0: **59 tests, zero failures**, 20.6 seconds, no exclusions.
- [x] Parent runs existing authorization and Note compatibility regressions:

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/search_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs --seed 918339
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix compile --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix xref graph --format cycles --fail-above 0
git diff --check
```

- [x] Diagnose any remaining failures. The first compatibility repair round
  passed its owning and regression checks; no failed compatibility repair or
  Astra attempt. Keep this distinct from the earlier observer's two failed Sol rounds
  and one successful Astra recovery. Escalation follows AGENTS.md; no timeout
  increase, skipped assertion, global data clearing, or misleading PASS is allowed.

## Task 4: Independent review and local handoff

- [x] Nonauthors review SPEC first, then QUALITY, against the complete bounded
  diff and design. Resolve findings and repeat relevant parent checks.
  `search_observer_actual_review` passed both reviews on the exact five files.
- [x] Verify owned database/storage-root cleanup, stopped PostgreSQL, unchanged
  protected worktrees/lockfiles/production hashes, and valid local links.
- [x] Record exact commands/results/hashes/reviews and explicit zero Vault work
  in the Phase 3 qualification record; preserve all historical failures.
- [x] Explicitly stage only this reviewed slice and make a small local
  conventional commit. Return to the other full-gate failures and remaining
  README checks. A green compatibility subset is not Phase 3 acceptance.
  Local commit: `d80d7270679f11e2a71ea36ad9afbe2bbd859307`.

Regression/static command `59417` exited 0: **43 integration tests, zero
failures**, 14.9 seconds, seed `918339`; formatting, warnings-as-errors compile
and zero-cycle xref passed. Cleanup `84902` exited 0, with zero generated
databases, all recorded/recent roots absent and owned PostgreSQL stopped.
Root/main and both protected Phase 2 worktrees, the protected untracked plan,
production/config/migrations and all three lockfiles remain unchanged.

## Self-review

Every change maps to one observed failure and retains the original behavioral
assertions. The timestamp fix validates input as well as strict expiration;
the permission fix keeps negative cells; the Note restore fix strengthens the
pre-recovery absence contract. The separate index observation, Document fixture
lifetime, and Runtime event workstreams remain open. E2E remains **NOT RUN**;
no next-phase advancement, publication, or deployment is authorized here.
