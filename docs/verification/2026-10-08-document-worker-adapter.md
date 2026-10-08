# Document worker adapter verification

Date: 2026-10-08. Status: bounded adapter slice verified and reviewed locally;
not Task 12 or Phase 2 acceptance.

## Scope and source

Worktree: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`.
Branch: `codex/v0.2-phase-2-import-extraction`.
Baseline: `78a8634527059b79014247b7bcf11567006cf4a7`.

This bounded slice implements adapter and exhaustion portions of Tasks 4–6 of
the [worker bridge plan](../superpowers/plans/2026-10-08-singularity-v0.2-phase-2-worker-bridge.md),
under the [approved amendment](../superpowers/specs/2026-10-08-singularity-v0.2-phase-2-worker-bridge-proposal.md).
The four SQL wrappers were separately verified and accepted at `b8db6d5`.
Their migration, grants, and existing lifecycle functions are unchanged here.

The new adapter is internal: exact typed descriptors, attempts and terminal
receipts; strict envelope and completion binding; short real WorkerRepo
transactions; active-current-attempt-only exhaustion. It does not change public
Document repository types, GenericWorker, WorkerScope, ScopedRepo, custody,
Vault, or production registration. Trusted transaction callbacks are application
code, not credentials whose provenance this adapter can authenticate.

## Characterization and initial RED

The implementation worker added three focused integration contracts before any
production adapter existed, retaining all 32 existing SQL tests. The contracts
use actual `WorkerScope.run/2`, WorkerRepo and a real retained outbox event; no
temporary worker grants or administrative connection is used for verified calls.
The envelope runner attempt is deliberately 37 while pending generation is 0.

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
```

Worker-reported initial RED: exit 2, seed 853983, 35 tests, 3 failures, 11.9 s.
All three failures were missing-module `UndefinedFunctionError` for
`DocumentWorkerRepository.describe/2`; the original 32 SQL contracts passed.
This agreed missing-feature RED is not a failed repair round.

Expanded worker-reported RED: exit 2, seed 132380, 46 tests, 14 failures,
21.6 s; all new failures were missing-module failures and the original 32 SQL
tests passed. After adding the storage-exception/privacy contract and ready
terminal exhaustion assertion, final RED: exit 2, seed 89315, **47 tests,
15 failures**, 20.9 s, with the same missing-module-only failure classification
and all 32 original SQL contracts passing. No production module existed in
these runs.

## Plan self-review and execution gate

The coordinating agent read the entire
[complete-code adapter slice plan](../superpowers/plans/2026-10-08-singularity-v0.2-worker-adapter-slice.md)
and governing amendment before authorizing production creation. Spec sections
3–7 and 10 map to exact envelope parameters, closed typed decoders, real scoped
transactions, completion validation/serialization, exhaustion, and privacy
contracts. Input and output names/types match the accepted SQL signatures. A
placeholder scan found no matches.

Main-agent review corrected the planned `execute` exception boundary before
production: all raised repository exceptions now pass through KnowledgeError,
matching the established DocumentRepository pattern, rather than handling only
DBConnection/Postgrex exceptions. RuntimeError and connection-error canaries
were added to the RED contract. Exits/process death are not caught. Recognized
lifecycle SQL conflicts return a private error sentinel for transaction rollback
before exhaustion converts that sentinel to unchanged outside the transaction;
authorization and storage failures are not converted to unchanged.

GO was given under the owner's standing approval after this self-review and
conditional on the final expected RED, which the worker reported as above.
Sol failed repair rounds: 0; Astra attempts: 0. This gate authorizes only the
bounded adapter slice, not Runtime wiring or phase acceptance.

## Existing boundary regressions

The coordinating agent independently ran the existing transaction and durable
job-envelope regression files without modifying them:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/scoped_repo_test.exs apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs
```

- Integration: exit 0, seed 865955, 22 reported tests, 0 failures, 16 excluded:
  **6 executed**. Verifies existing scoped connection cleanup and safe SQL
  telemetry, not the excluded GenericWorker unit contracts.
- Unit: exit 0, seed 551610, **16 tests, 0 failures**. Includes unchanged
  GenericWorker rejection of all six reserved atom/string dependency keys and
  strict durable-envelope handling.

## Implementation and fresh verification

The worker created only the internal adapter and additive contracts after GO.
First implementation GREEN: exit 0, seed 653159, **47 tests, 0 failures**,
20.7 s. No repair was needed. The adapter module is 503 lines; existing SQL
test bodies remain intact, with only aliases replaced and new tests/helpers
added. No test-only decoder exports or query-injection framework was introduced.

The coordinating agent inspected the actual module and diff, then independently
ran:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_storage/test/singularity/storage/scoped_repo_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_storage/lib/singularity/storage/postgres/document_worker_repository.ex apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix compile --warnings-as-errors
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
```

- Combined integration: exit 0, seed 637050. Storage **72 tests, 0 failures**
  (47 bridge + 19 lifecycle + 6 ScopedRepo), 27.1 s. Runtime 3 reported,
  0 failures, 2 excluded, 0.3 s: **1 executed**. Total **73 executed,
  0 failures**, not 75. Existing fixed-text deferred-fragment constraint
  disconnect logs occurred in the lifecycle negative tests, as in the separately
  recorded lifecycle baseline/repair; no content or new failure was reported.
- Fresh durable-job unit regression: exit 0, seed 650669, **16 tests,
  0 failures**, 0.7 s.
- Exact changed-file format check: exit 0.
- Strict umbrella compile: exit 0, no compiler warnings. This was incremental;
  it does not claim all seven applications were freshly recompiled.
- Umbrella xref: exit 0, `No cycles found`; no application/dependency manifest
  or graph boundary changed.
- Parent plan/module comparison: `diff -u` of the sole Elixir plan code block
  and production module returned exit 0, exact match. Placeholder scan returned
  exit 1 with no matches. `git diff --check` passed.

Independent Sol review `worker_adapter_spec_review` reports `SPEC_COMPLIANT`,
with no missing or extra requirements in the bounded slice. It inspected the
actual code, tests, plan and transaction/serializer dependencies; independently
verified exact plan/module comparison and diff-check; made no edits and ran no
tests or services. Independent Sol review `worker_adapter_quality_review`
reports no Critical, Important or Minor findings and readiness for local commit.
It inspected actual source/spec/tests/diff, freshly ran diff-check, and made no
edits or test/service calls. No repair rounds were needed; Astra attempts: 0.
All recorded commands finished; borrowed services were not restarted or stopped.

## Committed-source verification and handoff

Implementation commit: `0cc65c0cfa6c98144c0842ac01c8326248fa6674`
(`feat(storage): add typed document worker adapter`). Exact changed files:

- `apps/singularity_storage/lib/singularity/storage/postgres/document_worker_repository.ex`
- `apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs`
- `docs/superpowers/plans/2026-10-08-singularity-v0.2-worker-adapter-slice.md`
- `docs/superpowers/plans/2026-10-08-singularity-v0.2-phase-2-worker-bridge.md`

At that exact HEAD, the parent repeated the full combined integration command
above: exit 0, seed **890155**, storage **72 tests, 0 failures**, 26.8 s;
Runtime 3 reported, 0 failures, 2 excluded, 0.3 s, hence **73 executed,
0 failures** overall. The existing fixed-text lifecycle negative-test disconnect
logs appeared again without a failing assertion. The alias finished normally.
The adapter and test files had no diff against the tested commit afterward.
Only this separately owned verification document remained untracked before
the documentation handoff. Root main remained clean and unchanged at
`e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`.

The adapter slice is accepted locally after focused verification and both
independent reviews. This adds no migration and no grant change. Sol failed
repair rounds in this slice: **0**; Astra attempts: **0**. The user's bounded
Astra escalation authority remains available if a later repair reaches its
agreed threshold, with no more than three Astra attempts.

Next bounded work is the separately approved fresh Document source lease,
checkpoint-preserving progress updates, and then Runtime extraction composition
with actual custody/restart evidence. No fake resume, checkpoint reset,
RequestRepo substitution or temporary grants can satisfy that acceptance.

No E2E, push, merge, tag, release, publication, deployment, or Vault feature work
has occurred. Task 12 and Phase 2 remain incomplete. Source-replay, Runtime
composition, real restart evidence and the full required phase gate are separate
remaining work; the owner's E2E restriction does not waive that gate.
