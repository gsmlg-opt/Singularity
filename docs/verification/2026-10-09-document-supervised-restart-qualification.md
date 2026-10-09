# Document supervised-restart qualification

Date: 2026-10-09. Status: bounded Task13 literal supervised-restart qualification
accepted locally after isolated1 and combined29 integration tests, exact cleanup,
new-file format/diff checks and fresh independent Astra source SPEC/QUALITY.
Task12 scoped qualification and C1–C6 evidence are committed locally at
`138b035e56c2bc7416e6840a0ad2ae2aff798093`. Phase2/release acceptance remains open.
Parent authorizes the exact four-file local qualification commit. No production
change, broader Phase2 acceptance, E2E or external publication is claimed.
Earlier preparation/GO checkpoints below are historical.

## Boundary and observed gap

Worktree `.trees/v0.2-phase-2-import-extraction`, branch
`codex/v0.2-phase-2-import-extraction`. Existing Task13 production implementation
is present. The current startup test starts a separately named reconciler,
which does not prove the original Task13 requirement to restart Runtime's
actual supervisor. Existing C3 suspend/resume/manual recovery also does not
prove replacement. No production defect has been established.

Recommended direction under standing auto-select approval: a test-only contract
replacing the actual Runtime application supervisor, observing old/new process
identities and recovery after a real attempt deadline. Astra is designing the
precise fixture, isolation, cleanup and assertions. No standalone/fake reconciler
may substitute for the actual application child. No custody/key/capability/Vault
semantics, production clock/deadline, released migration or trigger changes.
Frozen C source and the preserved untracked original C plan remain unchanged.
No E2E, merge, push, release, publication or deployment.

## Unchanged Task13 baseline

Parent serialized this command in its only Mix slot at source138b035:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_runtime/test/singularity/runtime/job_restart_test.exs --seed 1208
```

Session89069 terminated exit0. Storage19tests,zero failures,8.6seconds;
Runtime9tests,zero failures,3.2seconds. Total28integration executed, no
exclusions reported. Postgrex emitted two expected constraint-error disconnect
messages during storage negative contracts; actual ExUnit result is zero
failures. These existing tests are baseline evidence, not the missing literal
supervised-restart contract.

Independent exact cleanup:

```sh
psql -X -h /run/user/1000/devenv-afa1eb9/postgres -p 5432 -d postgres -Atqc "SELECT count(*) FROM pg_catalog.pg_database WHERE datname='singularity_test_f7cc6676d029d7fc63edcafd'"
test ! -e /tmp/singularity/integration/f7cc6676d029d7fc63edcafd
```

Catalog count0 and root absent, both exit0. The command finished, Mix slot is
free, borrowed services remain untouched. Root main remains clean at
`e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`. Failed production repair rounds0;
the latest restore permits at least three Astra repair rounds if needed.

## Bounded design and preparation ownership

Parent personally read Astra's full read-only architecture recommendation and
the actual existing reconciler/test, Runtime start/children, integration alias,
existing application restart tests and fixture boundaries. Parent recorded the
exact selected contract in
`docs/superpowers/specs/2026-10-09-singularity-v0.2-document-supervised-restart-design.md`.
It requires literal root/child/repository PID replacement, a real WorkerRepo
claim and180second deadline, unchanged expired state while Runtime is stopped,
automatic startup recovery observed within10seconds, exact successor provenance,
unchanged pins, stale original claim rejection and restoration armed before stop.

Dedicated ordinary Astra owns only the new complete-code executable plan;
no test source is authorized yet. Parent owns design/evidence, personal code
read, independent reviews, test GO, Mix/cleanup and commits. Concurrent reviewer
spawn was rejected by the agent thread limit; no review or agent is inferred
from that rejected call. Independent review will follow completed plan handoff.
This is preparation progress, not passing restart evidence or a production repair.

Complete-code plan handoff:479lines, SHA-256
`fd21538d83a17811e74ef3c5dfc0c6551f9d33973e6159048a8d2fbd61c16f8e`.
Parent personally read all479lines and the full selected design. Static standalone
Elixir parse/format validation found exactly one complete module and one test AST,
exit0, without compiling, starting apps, running tests or allocating a database.
Independent ordinary Astra plan/SPEC review is now running. No executable-source
GO or passing restart evidence is claimed; the new test file does not yet exist.
Frozen final C source remainsb8c6 and original preserved plan remains350a655.

Independent ordinary Astra plan/SPEC review cleared exactfd21538plan at138b035
with no Critical/Important findings. It checked actual context/claim shape,
full-row mutations and triggers, Ecto child tuples, Oban normalization, fixture
event/authorization, alias isolation, prearmed restoration and literal startup
recovery proof. A separate ordinary Astra QUALITY reviewer is now checking the
complete plan for race/timeout/cleanup and false-positive risks. No new test
file, Mix execution, database operation or source acceptance follows from these
read-only reviews alone.

Independent ordinary Astra plan/QUALITY also cleared exactfd21538 with no
Critical/Important findings, including cross-test lifecycle contamination,
prearmed restoration, atomic snapshots, no transaction across expiry waiting,
sub-periodic startup timing and fail-fast unexpected states. Parent grants
TESTONLYGO under standing approval: dedicated ordinary Astra creates only the
exact complete planned test file. Parent retains formatting, strict plan/AST
comparison, actual isolated/combined gates, exact cleanup, fresh source reviews
and acceptance. No production change or successful restart execution is claimed.

## Exact test creation and initial execution

Dedicated ordinary Astra created only the approved new test. Raw352line source
SHA-256 `e99fda8050ffc33dcdd16bc76f95d9b6ca9f7a07fe038ac4aecfb5b7cfb5c3c1`.
Parent's first byte-comparison probe failed because its regex excluded the
terminal file newline; this was a probe-boundary mistake, not a test/production
failure. Parent independently proved rawhash equals the exact complete planned
block plus that required newline. No behavioral source correction occurred.

Parent then ran only the authorized new-file formatter, session87196, exit0:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs
```

Final formatted source SHA-256
`3fe960f0afb64f5253626bafbd3acda5b6a04d14c9c884c2b3dc380401f9aed9`.
Standalone exact formatted-byte and normalized complete-AST comparison against
the approved code passed, exit0. Every original planned assertion remains.
No earlier source or original preserved plan changed. Diffcheck passes.

Parent started the isolated new contract using the planned integration command,
seed1208. Actual result and exact cleanup remain pending. The existing-production
characterization is not a fabricated RED/GREEN change; real failure, if any,
must be retained and diagnosed before a separately bounded repair.

### Isolated actual restart result

Session60073 terminated exit0:1integration test,zero failures,181.9seconds,
seed1208, no exclusions reported. Exact command and independent cleanup:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs --seed 1208
psql -X -h /run/user/1000/devenv-afa1eb9/postgres -p 5432 -d postgres -Atqc "SELECT count(*) FROM pg_catalog.pg_database WHERE datname='singularity_test_db134acb0ee136635d78a6e1'"
test ! -e /tmp/singularity/integration/db134acb0ee136635d78a6e1
```

Catalog count0 and exact root absent, both exit0. Every planned real claim,
180second deadline, Runtime-down expired unchanged negative control, old/new
actual root/child/repository PID, automatic sub-periodic recovery, exact
successor provenance, old-claim conflict and restoration assertion passed.
Parent personally read all356 final source lines after formatting and verified
exact approved AST; frozen final hash remains3fe960. This is initially green
characterization of existing production behavior, not a production repair or
fabricated RED. Failed production repair rounds remain0.

Parent started the unchanged three-file gate plus this new contract, seed1208.
Expected29integration, actual result and exact cleanup pending. Source is frozen
at3fe960; no acceptance or scoped commit is claimed before all remaining checks
and independent final source reviews.

Combined gate session57286 allocated exact
`singularity_test_55e879f30e29c7642a0f73bc` /
`/tmp/singularity/integration/55e879f30e29c7642a0f73bc`.
Storage19tests pass with zero failures,6.5seconds; Runtime new restart contract
remains running. Source hash3fe960, frozen C hashb8c6 and preserved original plan
hash350a655 independently rechecked unchanged.

Fresh independent ordinary Astra actual-source SPEC clear, no Critical/Important
finding: only two formatter line-wrap locations differ from the approved complete
code, all original assertions retained. It confirms exact scope and actual
claim/deadline/root/startup/snapshot/replay/restoration proof. Fresh independent
SOURCE QUALITY is running. Combined result/cleanup, format check and local
acceptance/commit remain pending; no production repair occurred.

Fresh independent ordinary Astra actual-source QUALITY clear, no Critical or
Important actionable findings after reading all356lines and relevant fixture,
supervision and neighboring test contracts. It confirms proof fidelity,
replacement/restoration lifecycle, atomic observations and scoped isolation;
review alone does not claim the still-pending combined result or acceptance.

## Final bounded Task13 qualification

Combined session57286 terminated exit0,seed1208: storage19tests,zero failures,
6.5seconds; Runtime10tests,zero failures,184.0seconds. Total29integration
executed, no exclusions reported. Complete command and exact cleanup:

```sh
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_runtime/test/singularity/runtime/job_restart_test.exs --seed 1208
psql -X -h /run/user/1000/devenv-afa1eb9/postgres -p 5432 -d postgres -Atqc "SELECT count(*) FROM pg_catalog.pg_database WHERE datname='singularity_test_55e879f30e29c7642a0f73bc'"
test ! -e /tmp/singularity/integration/55e879f30e29c7642a0f73bc
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs
git diff --check
```

Exact catalog count0 and root absent independently checked, both exit0.
Format-check session53582 and diffcheck exit0. Before/after final source SHA-256
`3fe960f0afb64f5253626bafbd3acda5b6a04d14c9c884c2b3dc380401f9aed9`.
Original28 contracts remain unchanged; the added one passed alone and together
with them, not inferred from an excluded unit run. Fresh independent actual
source SPEC then QUALITY are clear of Critical/Important findings; parent read
the complete final source and all findings. Complete approved AST is retained.

Parent accepts this missing Task13 restart qualification locally. Together with
existing accepted recovery implementation/concurrency/lifecycle evidence, the
original literal-supervisor-restart requirement is now established. No new
production repair or implementation was necessary. All owned commands finished;
the Mix slot is released, Runtime restoration assertions passed, each exact
alias environment is gone and borrowed services remain untouched.

One scoped local commit is authorized: the new test, companion design/complete
plan, and this evidence record (four files). Git records its resulting identity.
Frozen C source remains
`b8c6f602344926f4ec085edbd7b3a3b84173efb3d58654cc90ce20d31ba07e42`.
Original full C plan remains untracked, excluded, byte-identical
`350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.
No production/configuration/dependency/migration/grant or custody/key/capability/
Vault feature or compatibility patch occurred. Fixture authorization assignments
are the established test data, not runtime semantics or SQL privilege changes.
Failed production repair rounds0; the latest restore allows at least three Astra
rounds if needed, not a requirement to manufacture failures.

Next separately bounded gap remains Task14 empty request-original authentication,
already recorded by the prior readiness audit. This test does not prove original
source reading or custody. Complete README/Task15 acceptance: NOT RUN in this
bounded slice. E2E: NOT RUN under owner restriction. Phase2/release acceptance
remains open. No merge, push,
tag, release, registry publication or deployment occurred. Stop this accepted
qualification slice; any later source work requires its own bounded design/plan.
