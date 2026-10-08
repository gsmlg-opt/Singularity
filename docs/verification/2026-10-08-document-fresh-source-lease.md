# Fresh Document source lease verification

Date: 2026-10-08. Status: bounded lease implementation reviewed and verified
locally; not full Task 12, Phase 2 or release acceptance.

## Authority, source and boundary

Worktree: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`.
Branch: `codex/v0.2-phase-2-import-extraction`.
Baseline: `bde0101e8883636e9beac545b9038d3c56d01b1f`, clean before this slice.
Root main is independently clean at `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`.

The [selected source-replay amendment](../superpowers/specs/2026-10-08-singularity-v0.2-document-source-replay-design.md)
authorizes this bounded Task 8/12 extension under standing owner approval.
The previous turn completed and verified the worker adapter at `0cc65c0`; it was
progress toward the full release objective, not full Task 12 or phase acceptance.

This slice owns only Runtime `key_custodian.ex`, `download_lease.ex`, their
existing `document_custody_test.exs` and `download_lease_test.exs`, and a new
complete-code slice plan. The two shared Runtime files are an explicitly
approved **Document-only custody extension**, not Vault feature work or a Vault
compatibility repair. Ordinary Asset/request Document behavior and the old
checkpointed worker lease remain unchanged. No storage custody adapter, SQL,
migration, grants, keys, capability, unlock, GenericWorker or public API change
is authorized by this bounded slice.

Checkpoint-preserving progress and full Runtime extraction/death/restart
composition remain separate required work. Real custody fixtures, not only
test doubles, are required before this lease slice is accepted. Administrative
setup may construct valid rows; verified calls must use actual WorkerRepo and
real CustodyReader, encrypted objects and wrapped object keys without grants.
Existing immutable objects or wrappers must not be patched to manufacture that
fixture.

## Characterization and RED

The implementation worker ran the existing two focused files before adding tests:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
```

Worker-reported baseline: unit seed 47244, 0.3 seconds, 5 reported tests,
0 failures, 1 integration test excluded: **4 executed**; integration seed
184465, 0.4 seconds, 5 reported tests, 0 failures, 4 unit tests excluded:
**1 executed**. Both commands finished normally. UTC start timestamps were not
recorded. No broad test gate is implied by these focused counts.

The worker then added contracts without production edits. Initial RED, seed
236044: **21 reported tests, 16 failures, 1 excluded**, hence **20 executed**.
All four existing unit contracts passed. The new failures expose the absent
purpose, generic-fallback injection handling, absent worker chunk mode, incorrectly
available public full reads, and missing empty-source authentication operation.
This is agreed new-feature RED, not a failed Sol repair round. No production
edit is permitted until the coordinating agent personally reviews the complete
implementation plan against the spec, types and placeholder gate and gives GO.

The parent additionally identified a lifecycle requirement during plan preparation:
links do not kill a child when the parent exits normally. The new mode must
confirm its owned reader has stopped before dropping the pending ownership and
replying/normal termination. Ordinary-mode lifecycle remains unchanged.

Real-custody RED, seed 505319: **29 reported tests, 8 failures, 20 excluded**,
hence **9 executed**. All eight new contracts fail at the absent fresh purpose;
the existing permission contract passes. Before that failure, the legacy lease
authenticates the first chunk of a real source larger than 4 MiB and persists
its v4 index.
The fixture uses real encrypted bytes, wrapped object keys and WorkerRepo
authorization. Fixture-only setup corrections occurred before this RED; no
production edits or failed production repair rounds occurred.

Expanded unit RED, seed 640789, 3.2 seconds: **31 reported tests, 18 failures,
9 excluded**, hence **22 executed**. All four existing unit tests still pass.
The coordinating agent personally read the complete executable slice plan,
compared it with the amendment and baseline APIs, checked field/types and
absence of executable placeholders, and gave GO for the bounded production
patch. The empty-operation test additionally monitors a blocked reader before
release to assert it is dead when success is delivered.

## Initial implementation checks

The implementation worker applied the personally reviewed patch and formatted
only the four owned Elixir files. Initial unit GREEN started at
`2026-10-08T14:53:58Z`, seed 845083, 3.1 seconds: **31 reported, 9 excluded,
22 executed, 0 failures**. The parent inspected the actual production diff and
the blocked-reader/monitor-before-release empty authentication contract.
Independent review and parent-run regressions are still required; this is not
slice, phase or release acceptance.

Initial integration GREEN started `2026-10-08T14:54:11Z`, seed 852326,
9.6 seconds: **31 reported, 22 excluded, 9 executed, 0 failures**. Isolated
database `singularity_test_ff4c0e0d19aeee4e5ca97fd9` was automatically cleaned
by the completed alias. Scoped formatting and diff checks exited zero.

## Parent-run verification

Parent unit/regression command started `2026-10-08T14:55:53Z`:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs apps/singularity_runtime/test/singularity/runtime/custody_reader_test.exs apps/singularity_runtime/test/singularity/runtime/key_lease_test.exs
```

Seed 335975, 4.6 seconds: **81 reported, 9 excluded, 72 executed, 0 failures**,
exit zero. Existing Fake.Authorization/Clock/KeyReader module-redefinition
warnings occurred; these are test-support loading warnings, not a clean strict
compiler result. Asset metadata/download, ordinary custody and old KeyLease
regressions passed within this focused command.

Parent real-custody/regression command started `2026-10-08T14:56:07Z`:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_storage/test/singularity/storage/postgres/custody_repository_test.exs
```

Seed 557041: storage **14 executed, 0 failures**, 4.6 seconds; Runtime
**31 reported, 22 excluded, 9 executed, 0 failures**, 11.8 seconds. Total
**23 executed, 0 failures**, exit zero. Isolated database
`singularity_test_cf04f64c77e61c8c9efa8da4`; alias cleanup completed. Together
these parent commands execute **95 focused tests**, not a full umbrella,
Phase 2, browser or release gate.

Parent static checks exited zero:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex apps/singularity_runtime/lib/singularity/runtime/download_lease.ex apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix compile --warnings-as-errors
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
```

The compiler recompiled the two changed Runtime modules; this is an incremental
strict compile, not a forced fresh compilation of all seven applications.
Xref reported `No cycles found`. Existing borrowed services were neither stopped
nor restarted. No outside-scope failure occurred in these focused checks.

## Independent reviews

`document_fresh_lease_spec_review` independently inspected the actual source,
tests, complete-code plan and amendment and returned **SPEC_COMPLIANT**, with
zero actionable findings. This reviewer did not run Mix; the parent-run tests
above are the independent execution evidence. It confirmed the bounded lease
scope only and explicitly left full worker/progress/phase gates outstanding.

`document_fresh_lease_quality_review` independently inspected the code and found
zero Critical/Important issues. One Minor coverage gap: the empty-source error
sanitization test used an already-sanitized error. Production sanitization was
correct, but a regression could pass that assertion. The parent requested a
content-canary error and exact redaction assertion before commit. This is test
strengthening, not a failed production repair round.

The implementer strengthened that contract with a canary message/details and
exact expected sanitized Error, preserving code/retryability and the existing
unexpected-plaintext case. Worker unit seed 760495: **22 executed, 0 failures**.
The quality reviewer independently rechecked the source and closed the Minor
finding. No review findings remain for this bounded component. Parent targeted
run `mix test apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs:289`
(with the same devenv/dependency prefix above) exited zero, seed 854700,
17 reported / 15 excluded: **2 executed, 0 failures**, 0.8 seconds.

## Source identity and remaining work

Implementation and complete-code plan committed locally as
`03a1bc20ffc4bac36b92c6a1df6f9a1b4436b10d`
(`feat(runtime): add fresh document source leases`). The staged documentation
check found whitespace-only embedded diff context; it was represented as
equivalent empty-line delete/add pairs before commit. Its read-only reverse
application check passes with `git apply --reverse --check --unidiff-zero`.
The plan documents this reconstruction flag; no production behavior changed.

The parent reran both full focused commands above after the implementation
commit, with HEAD exactly `03a1bc20ffc4bac36b92c6a1df6f9a1b4436b10d`:

- Unit/regressions: seed 884636, 4.6 seconds, **81 reported, 9 excluded,
  72 executed, 0 failures**, exit zero. The same existing Fake module loading
  warnings occurred.
- Integration/custody regressions: seed 638960; storage **14 executed,
  0 failures**, 4.0 seconds; Runtime **31 reported, 22 excluded, 9 executed,
  0 failures**, 6.2 seconds. Total **23 executed, 0 failures**, exit zero.
  Isolated database `singularity_test_ec7cf17e3be93870688846c7`; alias cleanup
  completed normally.

Thus **95 focused tests pass on the exact committed implementation source**.
Subsequent edits are documentation only; production and test files remain
byte-identical to that source. All command sessions exited. Root main remained
clean and unchanged at `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`.
Sol failed production repair rounds: **0**. Astra attempts: **0**.

Required next slices remain checkpoint-preserving progress/wake transitions,
Runtime extraction wiring, actual worker death/restart and claim/deadline/outcome
fences, recovery/API work, the Phase 2 security matrix and complete acceptance
gate. Later release phases are still unimplemented/unaccepted and require their
own approved detailed plans. The complete release goal remains active. No E2E,
push, merge, tag, release, publication or deployment was performed.

Sol failed repair rounds in this slice: 0. Astra attempts: 0. No E2E, push,
merge, release, publication, deployment or Vault feature work occurred. The
full release goal remains active; Task 12 and Phase 2 remain incomplete.
