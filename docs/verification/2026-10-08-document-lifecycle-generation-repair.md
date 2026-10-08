# Document reset generation contract repair — 2026-10-08

The owner explicitly requested fixing the previously blocked lifecycle failure.
This extends the repair scope to
`apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs`,
not unrelated production behavior. Base: `568ff38d2a423e1e040d099486df817c13f5ae47`.
Repair commit: `cf87c7ed79c2cc52c2727a1cfcfc3fe0d9a1e9e8`, on
`codex/v0.2-phase-2-import-extraction` in the existing Phase 2 worktree.

## Cause and repair

The later forward migration `20260922000300_document_runtime_mutations.exs`
advances generation when resetting a terminal attempt. The lifecycle test still
expected the earlier reset behavior. The current SQL, existing repository
regression, and Runtime retry tests agree: pending 0 → claim 1 → reset 2 →
claim 3. Claiming after reset requires expected revision 2, not 1.

The repair corrects those expectations and adds stale-claim rejection after
reset and stale-completion/failure rejection before and after the next claim,
including unchanged-row assertions.
All existing eligibility, immutable identity/source, metadata-clearing and
failure-detail assertions remain. No assertion was skipped, deleted, weakened
or reclassified. Production code and released migrations were not changed.

## Focused evidence

Commands ran from `.trees/v0.2-phase-2-import-extraction`, using shared dependencies
and the worktree-local build. The existing local PostgreSQL service was ready;
integration aliases allocated and dropped disposable databases.

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_mutation_receipts_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_api_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs
git diff --check
```

- Worker red before edits: seed `70452`, 19 tests, one expected failure, exit 2.
- Worker green: seed `510549`, 19 tests, zero failures, exit 0.
- Parent lifecycle/custody repetition: seed `272890`, storage 19 tests with zero
  failures; Runtime three tests with zero failures and two excluded; exit 0.
- Repeated that same lifecycle/custody command after committing the exact repair
  at `cf87c7ed79c2cc52c2727a1cfcfc3fe0d9a1e9e8`: seed `57472`, the same counts
  and exclusions, zero failures, exit 0.
- Related integration checks: seed `943876`, storage 20 tests with zero failures;
  Runtime 11 tests with zero failures and five excluded; exit 0.
- Runtime API unit checks: seed `244621`, 11 tests with zero failures and six
  integration tests excluded; exit 0.
- Worker and parent exact-file formatting checks passed. Whitespace checks passed.

Existing adversarial lifecycle tests still emit fixed-text Postgrex deferred
fragment constraint diagnostics. They appeared in the failing baseline as well
as passing runs; no source content appeared in these diagnostics. This repair
does not claim to qualify the future worker bridge's privacy behavior.

## Review, escalation and limits

Independent specification/quality review approved with no findings after checking
the diff, actual reset/claim SQL, governing design and existing regression.
Documentation review identified one wording overstatement about stale-claim
coverage; it was corrected to distinguish it from terminal-write coverage.
Sol repair rounds: one successful, zero unsuccessful. Astra attempts: zero; no
escalation was necessary. The owner's escalation ceiling is three Astra repair
attempts if escalation becomes necessary; it does not waive verification gates.

This resolves only the historical lifecycle baseline failure. The worker bridge
plan remains a draft, its production implementation and real restart evidence
remain outstanding, and complete Phase 2 acceptance still requires its full gate.
No full unit suite, E2E, restore, frontend, container, push, merge, release or
deployment ran in this repair. No Vault feature work or compatibility patch,
new migration, production change, dependency change or privilege change occurred.
