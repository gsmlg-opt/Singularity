# Document worker SQL bridge execution record

This records local acceptance of the bounded SQL component only, not full
bridge, Task 12, Phase 2, or release acceptance.
The governing contract is the approved
[worker bridge amendment](../superpowers/specs/2026-10-08-singularity-v0.2-phase-2-worker-bridge-proposal.md).
The existing E2E prohibition remains in force.

## Starting point and ownership

Execution starts at `80bbcd538586bca6f1c38569e357e77f8ac361c3` on
`codex/v0.2-phase-2-import-extraction` in the project-local Phase 2 worktree.
The initial worktree was clean. The preceding lifecycle repair is recorded
[separately](2026-10-08-document-lifecycle-generation-repair.md).

The SQL implementer owns only the new forward migration
`apps/singularity_storage/priv/repo/migrations/20261008000000_document_worker_bridge.exs`
and the actual-role contract file
`apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs`.
The coordinator owns documentation. Initial work is restricted to test-first
contracts; production migration implementation waits for the executable SQL
slice and coordinator self-review. Existing canonical ACLs, raw lifecycle
functions, historical migrations, Runtime wiring, and Vault semantics are not
implementation targets.

## Fresh prerequisite verification

From the Phase 2 worktree, with its existing ready services:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
```

Result: exit 0, seed `349833`; storage 19 tests, 0 failures; Runtime 3 tests,
0 failures, 2 excluded. This proves only the selected lifecycle and existing
custody baseline. It does not exercise the new bridge. Postgrex emitted the
same fixed-text deferred fragment-constraint disconnect messages recorded in
the lifecycle repair; those are not new bridge evidence or content-bearing
diagnostics. No E2E tests ran.

## Initial actual-role red contract

The implementer created the focused SQL contract file, without an adapter or
migration, and ran:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
```

Implementer result: exit 2, seed `461915`, 13 tests, 13 failures. Failures were
missing bridge functions or their absent catalog entries; fixture creation and
actual WorkerRepo scope composition succeeded. The coordinator read all tests
and requested `SourceLocator.to_map/1` serialization and SafeSQL for verified
calls before green verification. This agreed feature-absence red is not a
failed Sol repair round. No production migration had been written at this gate.

## SQL execution gate and ACL clarification

The coordinator's complete-code
[SQL slice plan](../superpowers/plans/2026-10-08-singularity-v0.2-worker-sql-slice.md)
authorized implementation of the four wrappers after self-review. The
describe source query was corrected during design review to read current
attempt state and source bindings in one statement.

The initial new ACL test incorrectly assumed all legacy resource tables were
denied. Historical migration `20260718000600` already grants worker CRUD on
`content.resources` and `content.resource_versions` under existing RLS. The
approved unchanged-ACL invariant takes precedence over that erroneous new
test assumption. Document-table denials remain required; legacy resource ACLs
are separately characterized and remain unchanged. The implementer ran:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs:188
```

Result reported by implementer: exit 0, seed `985932`, 15 tests, 0 failures,
14 excluded. A preceding stale line filter `:185` selected the still-missing
catalog contract and failed (seed `683779`, one executed test, 14 excluded);
it is not passing evidence. No production migration existed during either run.

The gate required the missing-function red run, exact SQL implementation and
ACL diff, actual-role green runs, authority/race/privacy coverage, independent
spec and quality reviews, and coordinator verification recorded below.
Adapter, exhaustion, fresh source replay, and Runtime extraction remain separate
unchecked obligations of Task 12.

## First migration-code validation and bounded repairs

The implementer applied the complete forward migration to the integration
alias's disposable database and reran the focused file: seed `301207`, 15 tests,
8 failures, exit 2. Valid cases failed closed at
live authority; negative and catalog/ACL cases passed. Source inspection found
the administrative fixture's capability assignment selected no rows because
`prepared_source!/0` does not create `asset.read`. The existing repository test
helper explicitly creates that capability before assigning it. No authority
guard was relaxed.

Sol repair round 1 corrected fixture creation and reran the file: seed
`784248`, 15 tests, 4 failures, exit 2. The remaining source descriptor failures
were PostgreSQL `42804`: canonical key generation is integer, but the approved
output column is bigint. Sol repair round 2 adds only the required explicit
`min(e.key_generation)::bigint` cast in the new migration projection. The
coordinator updated the executable plan to match. Its verification result must
be recorded before any success claim. After two failed Sol repair rounds,
escalation is to parent-managed Astra with at most three attempts; agreed new
feature red tests do not consume repair attempts.

Round 2 verification succeeded: implementer result seed `304303`, 15 tests,
0 failures, exit 0, using the same exact focused integration command. Cumulative
initial-slice repair accounting: two Sol repair rounds, one unsuccessful and
one successful; zero Astra attempts. This is initial-contract green only,
not adversarial matrix coverage, independent review, or component acceptance.

## Incremental adversarial verification

Using the same focused integration command, the implementer reports:

- Seed `208278`: 23 tests, 0 failures, exit 0. Includes all four wrappers under
  both rejected isolation levels, direct raw/helper denial, live identity and
  event fields, source availability/active binding, expiry, and the observed
  advisory-lock wait followed by committed revocation and worker denial.
- Seed `411308`: 29 tests, 0 failures, exit 0. Adds ambiguous active key
  generation, recovery/retry/restore successor fencing, malformed and oversized
  fragments, and captured logs/telemetry/mapped-storage-error privacy. This run exposed
  an Elixir warning in the generated transition test; the implementer is
  extracting its fixture helper before final verification. No production SQL
  changes were required by these incremental cases.

These are intermediate implementer results. Final warning-free verification,
coordinator rerun, and independent reviews remain required. The initial forecast
of 24 authority tests was incorrect; the actual executed count was 23.

The final implementer run passed with seed `426022`: 32 tests, 0 failures,
exit 0, 14.1 seconds, no compiler warnings. The test fixture explicitly proves
capability assignment and legitimately delivered-event metadata. Added final
cases include a live authorized alternate owner/creator, object/source size
mismatch, and 257 individually valid 65,536-byte fragments with correct
canonical identities and aggregate digest: the >16-MiB completion is rejected
atomically, then a valid single-fragment subset completes. Failure/stale paths
assert no target-version fragments or existing Asset/Note projections, while
preserving the distinct source Asset projection. No Document search projection
table exists in this phase. Invalid canonical source bounds/digest/media are
already schema-enforced; no impossible fixtures bypass those constraints.

All implementer commands and test-owned tasks finished; telemetry handlers
were detached. The coordinator independently compared the normalized AST of
the actual migration with the complete-code plan: equal, exit 0. Independent
spec review, quality review and coordinator integration rerun follow this gate.

## Coordinator verification before review completion

The coordinator ran:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_storage/priv/repo/migrations/20261008000000_document_worker_bridge.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
git diff --check
```

All exited 0. Integration seed `422062`: storage 51 tests, 0 failures;
Runtime 3 tests, 0 failures, 2 excluded (52 executed integration tests in total).
The lifecycle file again emitted its existing fixed-text deferred-fragment
constraint disconnect logs; the bridge privacy contracts passed. No compiler
warnings or E2E tests. This is direct SQL/mapped-storage-error evidence, not
Runtime extraction or public endpoint acceptance. Spec review is in progress;
quality review had not started at that verification point.

## Independent review and architecture checks

`worker_sql_spec_review` independently reviewed the actual SQL, complete tests,
approved amendment, complete-code plan, and existing authority/lifecycle
implementations: `SPEC_COMPLIANT`, no findings. It confirmed that every feasible
membership clearance is covered; the schema permits exactly private, sensitive
and restricted, so invalid-clearance fixtures must not bypass that constraint.

After spec approval, `worker_sql_quality_review` independently reviewed the same
component and relevant delegated helpers: no Critical, Important or Minor
findings; ready to commit this bounded SQL component. Reviewers made no edits,
ran no integration tests, and finished their commands. Their approval does not
extend to adapter, Runtime or phase acceptance.

The coordinator also ran:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix compile --warnings-as-errors
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --name-only HEAD -- 'apps/*/mix.exs' mix.exs
```

All exited 0: all seven applications compiled without warnings, xref reported
`No cycles found`, and no application dependency manifests changed. The worktree
contains only the six explicitly owned source/test/plan/evidence files. The
main checkout remains clean and unchanged. No Vault file, semantics, historical
migration, production table grant/RLS, or existing raw lifecycle function changed.

## Exact committed-source verification and remaining scope

Code, tests, complete-code plan, and unchanged-ACL clarification are committed
at `b8db6d562d072c2de5dc77635d29159080d1401a`
(`feat(storage): add fenced document worker SQL bridge`). The coordinator reran
the exact combined integration command above at that commit: seed `477022`,
exit 0; storage 51 tests, 0 failures; Runtime 3 tests, 0 failures, 2 excluded.
The two-file format check also exited 0 at that source. The only outstanding
worktree change during this run was this documentation-only execution record.
Subsequent acceptance-status edits are documentation only.

The SQL component is accepted locally with both independent reviews and fresh
committed-source verification. Cumulative repair count remains two Sol rounds,
one unsuccessful and one successful; zero Astra attempts. No required Document
denial, provenance, lifecycle or authority assertion was weakened to obtain
green; the erroneous new legacy-ACL baseline assumption was explicitly
corrected and characterized as recorded above.

The next component is the bounded worker adapter: exact decoders, trusted short
transaction composition, validated completion serialization, and active-attempt
exhaustion. The fresh sequential source lease, restart/death custody evidence,
Runtime extraction/wiring and full Task 12/Phase 2 gates remain unfinished.
No E2E, merge, push, tag, release, container publication, production migration
or deployment occurred. The existing E2E restriction remains in force and does
not waive the later full-phase acceptance gate. Existing ready development
services remain running; no services were restarted by this component work.
