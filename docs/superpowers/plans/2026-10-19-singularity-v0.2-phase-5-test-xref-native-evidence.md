# Fixed native-evidence test leaf implementation plan — draft1

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or
> executing-plans task-by-task, as assigned by the parent. Parent alone delegates
> independent reviewers and runs the single VM/SQL lane. This private draft is
> not implementation GO.

**Goal:** Repair the real test-support xref cycle without changing native restore
evidence behavior, original assertions, custody or product code.

**Architecture:** Extract four exact Oracle primitives and copy four helper
clauses into a fixed test-only NativeEvidence leaf. Keep explicit Oracle wrappers
and route all nine Fixture calls directly to that leaf. Attribute both old whole
sources strictly, retaining unchanged33 source pins and historical evidence.

**Tech Stack:** Elixir/ExUnit, existing local storage adapter/PathGuard, existing
private PostgreSQL qualification lane, Node strict source attribution.

Governing private design:
`docs/superpowers/specs/2026-10-19-singularity-v0.2-phase-5-test-xref-native-evidence-design.md`.
Diagnosis: `.devenv/phase5-task16-test-xref-diagnosis1.md`.
No runtime commands below have been executed by this plan author.

## Task 1: Review, freeze and establish exact ownership

- [ ] Obtain independent DESIGN SPEC and distinct DESIGN QUALITY on both private
  drafts. Parent may repair/promote only after actual review closure, not inferred
  approval. Canonical targets are the two exact design/plan paths in the design.
- [ ] Parent confirms no conflicting writer or owned VM/SQL. Record actual
  worktree/HEAD, AGENTS, source pins, dirty status and existing33 manifest.
  Stop on unexplained drift; never revert another writer's work.
- [ ] Verify raw Oracle SHA
  `5a2785715058945ab43b544feb108e9d91f92ff56bde4f0aec606382052ab3e5`
  and Fixture SHA
  `60485cecc8c4897cb5926b8af72a6a6a5e44a62f5392e939f1b409776f2481a4`.
  Preserve exact189 FAIL1 and190 EMPTY0. Production Sol/Astra repair counts stay0.
- [ ] Assign one Sol source worker the two existing support files and two new
  source/test files named in the design. Tell it others share the worktree and
  not to revert their work. Parent owns private guard/receipts/canonical docs.

## Task 2: Add the focused functional RED

Create only
`apps/singularity_runtime/test/singularity/runtime/knowledge_restore_native_evidence_test.exs`.
Use async ExUnit `@moduletag :tmp_dir`, no database/global configuration. Fixed
adapter bytes `"owned-ciphertext-A"` and `"owned-ciphertext-B"` are synthetic,
not native publication/AEAD or custody evidence. A fixture creates a0700 child
root, canonical PathGuard path, parent directories and one0400 file. Use valid
UUIDs ending9001(vault),9002(domain),9003(object), lookup `<<1::256>>`, actual
SHA256/size, and storage_ref equal to object UUID. Capture physical state as
`{major_device, minor_device, inode, mode, size, File.read!(path)}`.

- [ ] Add these nine deterministic tests, exercising leaf and Oracle paths:

| Test | Required oracle |
| --- | --- |
| Literal inventory | Rows b,a → a,b; all nine mapped fields and positions0/1, classification `:private`; Oracle parity. |
| Invalid classification | String `task16_nonexisting_classification_93af` raises ArgumentError in both; input unchanged. |
| Handoff | Exact six-key result; owner only key-version/generation, canaries excluded; Oracle parity; missing `:cut` raises KeyError in both. |
| Native aliases | Exact actual bytes/hash/size, canonical relative reference and physical identity; Oracle parity; original physical state unchanged. |
| Wrong expected size | Size+1 raises ArgumentError `actual alias ciphertext differs from persisted native evidence` in both; physical state unchanged. |
| Wrong expected hash | Foreign SHA raises ArgumentError `alias ciphertext open failed` in both; physical state unchanged. |
| Replacement positive | Separate owned fixture for each path; equal-length foreign bytes; exact returned before/after evidence, inode/mode/size preserved and mode0400. |
| Replacement negatives | Same bytes, foreign bytes plus `!`, and mode0600 each raise existing ArgumentError `foreign composition requires one genuine read-only equal-length owned ciphertext`; both paths; file state unchanged. |
| Public guard | Nonbinary replacement raises FunctionClauseError in both; file unchanged. |

Do not invent stronger malformed-row validation or new error behavior. Parameter
cases are not separate ExUnit test counts. Keep fixtures readable for ordinary
ExUnit cleanup; do not credit teardown as production/ResourceOwner cleanup.

- [ ] Parent runs the whole new file before extraction, followed by its own EMPTY
  post. Preserve actual absent-module RED separately from causal189. Do not
  claim old wrappers are expected to fail.

```sh
devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh mix test apps/singularity_runtime/test/singularity/runtime/knowledge_restore_native_evidence_test.exs --seed 215378 --warnings-as-errors
```

## Task 3: Perform the exact static extraction

- [ ] Copy each of the five exact definition slices from the whole-pinned old
  Oracle, using the line ranges/byte counts/SHA256 table in the design. Build the
  new leaf with the fixed module envelope, `@moduledoc false`, four old functions
  in table order and four copied helper clauses, blank lines, final `end` and LF.
  Keep original function bodies byte-identical; no hand-written substitutes.
- [ ] Replace only the four old Oracle definitions with the explicit wrappers
  shown in the design. Add only the single fixed leaf alias. Leave Oracle's four
  private helper clauses and all five Fixture orchestrator calls untouched.
- [ ] Replace only the two Fixture alias entries and nine direct receivers with
  `KnowledgeRestoreNativeEvidence`. Keep arguments, expressions and every native
  observation/assertion/callback unmodified. No dynamic apply or edge suppression.
- [ ] Capture pre-format whole source plus literal transitions. Parent formats
  only these four owned sources, captures post-format bytes and checks all other
  current33 pins unchanged. Verify each copied function/helper byte hash exactly.
- [ ] Parent replays the whole new leaf file twice, each followed by own EMPTY
  post. Expected GREEN with all nine tests and zero failures; record actual
  compiler behavior/counts. Repair genuine failures without weakening assertions.

## Task 4: Strict successor attribution and fail-closed counterproofs

Parent owns new private artifacts named
`.devenv/phase5-task16-test-xref-source-stage.json`,
`.devenv/phase5-task16-test-xref-source-guard.js`, and
`.devenv/phase5-task16-test-xref-thirtynine.sha256`. These are new forward files;
do not edit old guards/manifests or fake their success status.

- [ ] Raw-pin both current support sources before any virtual attribution. Record
  each unique full before/after literal, byte offset, left/right context, literal
  hash and whole hash. Inverse four Oracle wrappers and one alias insertion to
  whole5a278571…; inverse two Fixture aliases and nine receivers to whole60485cec….
- [ ] Verify raw new leaf contains exactly all four old function bodies and four
  helper clauses plus only its fixed envelope. Original Oracle helper clauses
  remain. Verify static graph edges and zero leaf→Oracle/Fixture references.
- [ ] Preserve immutable33 manifest62aca109… and every raw entry. Append exactly
  the two support sources, new leaf/new test and canonical design/plan as six
  new entries. Reject duplicates and unexpected status, require actual Git
  status39 / tracked21 exactly and staged diff empty. No Git interception.
- [ ] Retain current IO-Q1/C13 stages and all earlier whole inverses, profile and
  owned0 checks, frozen54 raw checks and two accepted native source inverses.
  Attribute the two support sources before checking their immutable Task12 pins.
  Check actual historical source/manifest files rather than rewritten baselines.
- [ ] Execute direct Node pure counterproofs: each missing, altered, duplicated,
  relocated literal; altered left context; altered right context; unrelated old
  byte; unauthorized outside byte; unauthorized new leaf expression; unexpected
  scope/status. Each must fail for the corresponding intended check. No SQL/VM
  is required for the counterproof transformation itself; parent owns guard runs.
- [ ] Independently review the actual guard/stage and all source bytes before
  using the guard as final readiness evidence. Do not load old preload modules
  prematurely or broaden historical attribution into an ordinary source bypass.

## Task 5: Replay affected original gates, not a blind full19 rerun

Parent must serialize all commands with its actual own EMPTY post and0600 full
raw receipt. Wrapper stays the qualified IO-Q1 wrapper; no timeout/PG/permission/
source changes. Run all commands in W. Test env is the wrapper default; explicit
dev overrides appear only in the two dev commands.

- [ ] New whole leaf command from Task2, full9 tests, repeated GREEN.
- [ ] Whole standalone task unit gate:

```sh
devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh mix test apps/singularity_runtime/test/mix/tasks/singularity.test.restore_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Original whole native backup/restore cohort, no path/test filtering:

```sh
devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Original standalone real restore gate, no arguments:

```sh
devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh mix singularity.test.restore
```

  Its real Oracle.run! still covers UUID, canonical compatibility, mixed
  compatibility and late native corruption, with actual custody, source/search,
  ResourceOwner and cleanup assertions. Do not substitute unit stubs for it.

- [ ] Replay original full architecture cohort167 exactly:

```sh
devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh mix test apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/export_lease_ownership_contract_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Replay original full pure cohort185 exactly:

```sh
devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs apps/singularity_storage/test/singularity/storage/test_environment_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Global formatting and both environments' compiler and graph gates:

```sh
devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh mix format --check-formatted
devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh env MIX_ENV=dev mix compile --warnings-as-errors
devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh env MIX_ENV=dev mix xref graph --format cycles --fail-above 0
devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh mix compile --warnings-as-errors
devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh mix xref graph --format cycles --fail-above 0
```

  The final test xref is the exact189 inner argv on the new manifest. It must
  genuinely report no cycles and exit0; never filter output or change threshold.

- [ ] Parent runs source guard only with all owned VM/SQL closed, records actual
  Git/diff/source/frozen/profile/environment checks and final
  `git diff --check`. No process cleanup/guard success can be inferred from tests.

## Task 6: Independent source review and honest incremental handoff

- [ ] Fresh non-author SOURCE SPEC reviews actual four-source diff, whole inverse,
  new tests, actual full native/standalone gate evidence and strict guard. Then a
  distinct fresh QUALITY reviewer checks implementation quality. Neither is
  credited with full unrelated source review. Close writers before review.
- [ ] Record a gate mapping: retain each old passing record only for its exact
  unchanged inputs; mark this amendment's affected replays fresh on the39 scope.
  The eighteen old passing Task16 gates are retained evidence, not eighteen
  newly executed successor gates. Any affected old gate is superseded for current
  readiness only by its actual corresponding replay, not a blanket assertion.
- [ ] Preserve historical117 FAIL,133 FAIL, lifecycle001 FAIL and189 FAIL; keep
  migration redefinition warnings/intentional SQL negative-path errors correctly
  classified. Record reported/excluded/actual test counts, exact natural exits,
  physical post delays, tmpfs volatility and E2E NOT RUN. No durable-power-loss,
  Phase5 or release acceptance claim is permitted.
- [ ] Parent closes final required packet, guard and orderly private-lane teardown
  under its existing reviewed ownership protocol before a Task16 local-component
  readiness decision. This amendment alone cannot accept Task16 or its native
  composition. It changes none of its unwaived ALL-issued/startup/error tests.
- [ ] Once all required affected gates and independent reviews pass, parent may
  make a small local commit with explicit owned paths and evidence under current
  authority. Do not stage unrelated work or push/release/deploy. Worker returns
  bounded handoff; parent continuous authority is not stopped by this worker end.

## Author self-review / remaining status

All design obligations map to Tasks1–6: exact body extraction and wrappers3,
functional positive/negative evidence2–3, strict whole inverses/frozen scope4,
native/standalone and graph evidence5, independent review and incremental credit6.
No code has been implemented or executed by this plan author. Private draft
review is the next dependency; no product decision or external permission is
requested. Production repair counters remain Sol0/Astra0.
