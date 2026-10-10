# Phase 3 Document fixture lifetime repair plan

> Use subagent-driven-development for disjoint registrations and independent
> review. Parent alone formats, executes tests, owns PostgreSQL and mutates Git.

**Goal:** Prevent finished tests' abandoned Document attempts from entering
later global recovery, without changing production behavior or weakening tests.

**Design:** [Explicit test-owned lifetime](../specs/2026-10-10-singularity-v0.2-phase-3-document-fixture-lifetime-design.md).
Shared constructors remain unchanged; retirement is exact-resource/owner,
idempotent, post-test and preserves canonical rows.

## Task 1: Design and RED contracts

- [x] Independently review the design and this plan, SPEC then QUALITY.
  Both reviews passed with nonauthor `search_observer_actual_review`.
- [x] Record full-run `37888` failures and the source-based producer inventory;
  do not claim exact identity matching for the old global expired-row list.
- [ ] Add only the three planned regressions in
  `apps/singularity_storage/test/singularity/storage/knowledge_fixtures_test.exs`.
  Run the pure registration case and both integration cases before implementing
  the helper. Record actual failures, including callback failures, accurately.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/knowledge_fixtures_test.exs --seed 918339
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/knowledge_fixtures_test.exs --seed 918339
```

## Task 2: Helper and explicit registrations

- [ ] Parent owns `apps/singularity_storage/test/support/knowledge_fixtures.ex`
  and the new owning test. Implement only the explicit registration helper;
  retain all three constructors byte-for-byte. Run all three new contracts GREEN.
- [ ] Storage implementer owns the four Storage registration files listed by
  the design. The previous five-file compatibility slice must finish before
  editing `document_lifecycle_test.exs` again. Register the two precise staged
  fixtures, common worker setup, and lifecycle-owned creations. Preserve tests.
- [ ] Runtime implementer owns the three Runtime registration files listed by
  the design. Use the helper for all reconciler-created Documents, the restart
  fixture and both extraction-job fixture helpers; remove only the now-unused
  local retirement helper. Preserve all callback ordering and existing behavior.

Workers are not alone. They must not revert other edits or format/run tests,
services or Git. Serialize any later event-contract work on the shared Runtime
job test. Do not touch historical/private database callers.

## Task 3: Parent verification

- [ ] Format only owned files. Run the new pure/integration contracts.
- [ ] Run both staged-fragment producers with real Runtime restart/recovery:

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs:456 apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs:771 apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs --seed 918339
```

- [ ] Run the full affected owning batch (the known ready-restore event failure
  may remain until its separate contract amendment; it is not a PASS):

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/knowledge_fixtures_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 918339
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix compile --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix xref graph --format cycles --fail-above 0
git diff --check
```

- [ ] Diagnose any residual failures without weakening constraints or changing
  real deadlines. Track this fixture-isolation repair separately from the
  observer's two failed Sol rounds and one successful Astra recovery.

## Task 4: Review, record and commit

- [ ] Independent nonauthors review SPEC then QUALITY. Resolve findings and
  re-run relevant checks. A failed owning batch is never labeled accepted.
- [ ] Verify owned database/root disposal, PostgreSQL stopped, unchanged
  protected worktrees/production/lockfiles and valid local Markdown links.
- [ ] Update the qualification record and checklist with exact commands,
  results, hashes, repair counts and zero Vault feature work.
- [ ] Make a narrowly staged local commit once relevant checks and review pass;
  continue the remaining full-gate work. No merge, push or publication.

## Self-review

Explicit opt-in avoids callbacks against already-disposed historical databases.
Ordinary callback ordering proves real cleanup rather than a substitute API;
the mismatched owner control independently tests the owner predicate. No global
deletion or production query filtering hides poisoned fixtures. New failures
remain diagnostic work, and E2E stays NOT RUN under the current restriction.
