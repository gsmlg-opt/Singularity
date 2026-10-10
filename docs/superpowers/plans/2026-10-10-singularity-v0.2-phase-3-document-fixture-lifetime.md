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
- [x] Add only the three planned regressions in
  `apps/singularity_storage/test/singularity/storage/knowledge_fixtures_test.exs`.
  Run the pure registration case and both integration cases before implementing
  the helper. Record actual failures, including callback failures, accurately.
  Pure RED `2012`, exit 2: one executed/failed, two excluded, 0.2 seconds.
  Integration RED `90820`, exit 2: two executed/failed, one excluded, 1.2 seconds.
  Both fail because the helper does not yet exist, after the integration
  fixtures/snapshots were established. Seed `918339`; allocation
  `068c5bd5cae2a82cc3290136` disposed, PostgreSQL stopped.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/knowledge_fixtures_test.exs --seed 918339
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/knowledge_fixtures_test.exs --seed 918339
```

## Task 2: Helper and explicit registrations

- [x] Parent owns `apps/singularity_storage/test/support/knowledge_fixtures.ex`
  and the new owning test. Implement only the explicit registration helper;
  retain all three constructors byte-for-byte. Run all three new contracts GREEN.
  GREEN `42398`, exit 0: one pure case passed (two excluded, 0.1 seconds),
  then two integration cases passed (one excluded, 1.5 seconds), seed `918339`.
  Allocation `242dc96c54b925f74ca0e059` disposed, PostgreSQL stopped.
  Nonauthor `search_observer_actual_review` passed helper/test SPEC and separate
  QUALITY at helper hash `e6b3b6d7...` / test hash `e9d78bd4...`.
- [x] Storage implementer owns the four Storage registration files listed by
  the design. The previous five-file compatibility slice must finish before
  editing `document_lifecycle_test.exs` again. Register the two precise staged
  fixtures, common worker setup, and lifecycle-owned creations. Preserve tests.
- [x] Runtime implementer owns the three Runtime registration files listed by
  the design. Use the helper for all reconciler-created Documents, the restart
  fixture and both extraction-job fixture helpers; remove only the now-unused
  local retirement helper. Preserve all callback ordering and existing behavior.
  Worker handoff covered all ten direct reconciler creations, restart creation
  and both job helpers. Independent SPEC found one missing hook for the
  reconciler's terminal `ready_document!` control; parent added it after
  targeted gate `7608` ended. QUALITY found no other issue. This is a review
  correction, not evidence that the terminal control caused an expired scan.

Workers are not alone. They must not revert other edits or format/run tests,
services or Git. Serialize any later event-contract work on the shared Runtime
job test. Do not touch historical/private database callers.

## Task 3: Parent verification

- [x] Format only owned files. Run the new pure/integration contracts.
  Final expanded run `96668` also reran the pure registration case (one passed,
  two excluded, 0.2 seconds) and all 161 selected Storage integration cases,
  including both cleanup contracts (zero failures, one excluded, 95.1 seconds).
  Runtime and the later static/cleanup gates subsequently passed as recorded below.
- [x] Run both staged-fragment producers with real Runtime restart/recovery:

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs:456 apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs:771 apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs --seed 918339
```

`7608`, exit 0, seed `918339`: Storage two executed cases passed (65 excluded,
4.2 seconds); Runtime ten executed cases passed (199.2 seconds). The real
180-second expiration remained unchanged. Allocation
`3f793129fa99fa0cc846e141` was disposed and PostgreSQL stopped. This run preceded
the one ready-control hook requested by review; the full batch below reruns
that corrected reconciler. No full-gate acceptance follows from these 12 passes.

- [x] Run the full affected owning batch, preserving the failed baseline and
  verifying the separately reviewed event-contract correction:

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/knowledge_fixtures_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/search_candidate_ids_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs --seed 918339
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix compile --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix xref graph --format cycles --fail-above 0
git diff --check
```

The expanded command includes the dispatcher to cover both complete Runtime
event-test files. This adds coverage and omits no lifetime case.

Combined characterization `23006` used that additional dispatcher file, seed
`918339`, at `e08113b` plus the reviewed nine-file lifetime diff. It exited 2:
Storage 161 executed, zero failures, one excluded (98.1 seconds); Runtime 110
executed, one failure, 43 excluded (752.4 seconds). Only the unchanged
ready-restoration event count failed, expecting 2 and observing 3. The corrected
ready-control retirement registration was included. Allocation
`8ffdd8426d28bdc46d69b77b` completed and PostgreSQL stopped; final cleanup
`19748` later confirmed its disposal. This batch remains FAIL, not qualification.

Final expanded run `96668`, exit 0, seed `918339`, passed 161 Storage cases
(one excluded, 95.1 seconds) and 110 Runtime cases (43 excluded, 768.1 seconds).
Allocation `213302780d62541c9596b14b` was disposed and PostgreSQL stopped.
The same command chain passed 32 event/lifecycle regressions (21.2 seconds,
allocation `be4b15306e7fa683f92e367c`), full formatting, warnings-as-errors
compilation, zero xref cycles and `git diff --check`.

- [x] Diagnose any residual failures without weakening constraints or changing
  real deadlines. Track this fixture-isolation repair separately from the
  observer's two failed Sol rounds and one successful Astra recovery.

## Task 4: Review, record and commit

- [x] Independent nonauthors review SPEC then QUALITY. Resolve findings and
  re-run relevant checks. A failed owning batch is never labeled accepted.
  `search_observer_actual_review` passed the final nine-file source after the
  ready-control correction, and then separately reviewed the additional
  event-contract changes in the shared job file. The final batch passed above.
- [x] Verify owned database/root disposal, PostgreSQL stopped, unchanged
  protected worktrees/production/lockfiles and valid local Markdown links.
  Cleanup `19748` found zero generated databases and absent recorded roots;
  direct checks covered all new roots. Protected worktrees and lock/source
  hashes remained unchanged; relative document targets passed validation.
- [x] Update the qualification record and checklist with exact commands,
  results, hashes, repair counts and zero Vault feature work.
- [x] Make a narrowly staged local commit once relevant checks and review pass;
  continue the remaining full-gate work. No merge, push or publication.
  Because both reviewed slices edit the same Runtime job test, the lifetime and
  event-contract fixes may share one narrow local test-only commit after their
  complete combined batch and separate required regressions pass. Record each
  slice's evidence independently; do not mix the search-plan maintenance into it.
  Both test slices are committed at `c423a88d792a06e29cb84a3a501678e245182255`;
  the search-plan maintenance is a separate commit. Subsequent clean-source
  `35c1f8360dd22b129832a1618b3723032a1983bd` passed every allowed ordered
  non-E2E README check in `91785`, exit 0, including all 1,109 integration cases.
  Independent complete-candidate SPEC and separate QUALITY source reviews and
  fresh cleanup `8761` passed. Full phase acceptance remains unmet because
  E2E is still prohibited/NOT RUN; no Phase 4 advancement is implied.

## Self-review

Explicit opt-in avoids callbacks against already-disposed historical databases.
Ordinary callback ordering proves real cleanup rather than a substitute API;
the mismatched owner control independently tests the owner predicate. No global
deletion or production query filtering hides poisoned fixtures. New failures
remain diagnostic work, and E2E stays NOT RUN under the current restriction.
