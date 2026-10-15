# Phase5 Task10 local qualification and handoff — 2026-10-15

Status: source/gates and final actual-code reviews QUALIFIED. Local Task10
acceptance closes only when the documentation review/commit/clean conditions
below have actually completed; this document does not predeclare those results.
Task10's complete permitted README gate passed on one unchanged implementation.
Phase5 remains IN PROGRESS. E2E NOT RUN; Task11/12 are not accepted and default
backup remains V2. Task16 BOTH strict ALL-leases obligations remain
UNSATISFIED/UNWAIVED/BLOCKED_DESIGN independently.

## Source, scope and local commits

- Worktree: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup`.
- Branch: `codex/v0.2-phase-5-export-backup`.
- Qualification baseline HEAD: `1c1ca7f68035e255247e0c2efb86d16000bb34c5`.
- Exact qualified28-file manifest:
  `.devenv/phase5-task10-integration-repaired-current28.sha256`,
  SHA256 `f17cbeb85579e6e93d566097f0a47a49bd75bdac9f2d3244c67ef28e4fef14d4`.
- Immutable qualified source327 SHA256:
  `fc44bf592f5a6e0dcbd3023e6a52ecefe1403133ae7ec4645c6cf53cba8d53c4`.
- Final local source commit: `d1a8d4f73c570daa7177468b246a25819a2cdd39`.
  Content-equivalence to all28 tested identities passed before/after each commit;
  the baseline-to-final-source changed-path set is exactly those28 paths.
  A commit's metadata does not constitute a new test run.

The five bounded local code commits, in order:

- `ebaea06a696ad4268de055ab9f1fee85eac89eeb` — test(storage): isolate canonical backup fixture lifecycles
- `b39402425b1ff51dbc39591852a8c0fda1cfc564` — test(knowledge): align document worker read contracts
- `2212dc79297eaf5421c523ae4bfb15ac1d174407` — fix(backup): preserve historical v3 admission contracts
- `32144a94afdea07cff67fb139a4eb2e052834a28` — fix(runtime): preserve upload stream protocol dispatch
- `d1a8d4f73c570daa7177468b246a25819a2cdd39` — feat(restore): reconstruct unified search and document work

Task10 implements unified current-head Note/Document/Asset search reconstruction
and provenance-checked Document work reconciliation/recovery. Its only new
migration is forward `20261011000800_document_restore_recovery_provenance.exs`
(authorized constraint delta plus three existing functions). Necessary preflight,
read-contract, upload-message-enumeration and test-fixture compatibility fixes
are included; all28 exact paths are the baseline-to-final-source Git diff.

No Vault feature work occurred. A custody repository TEST only characterizes
established reads under opaque legacy owner encoding; custody production code,
keys, capabilities, DownloadLease, runtime pins, defaultV2 and released migrations
are unchanged. Seven applications remain, no new dependency.

## Native verification

All fifteen exact reviewed commands below ran ONCE for this final generation,
naturally exited0, and had complete raw EOF, exact-source/pin checks and ordinary
EMPTY private-database residual queries before/after. No overlap, hidden filters,
prewarm, forced cleanup, seed/concurrency/deadline override or durability change.
The unit/integration/restore commands are ordinary NO-ARGS invocations.

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.db.verify_roles
devenv shell -- env MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix deps.get
devenv shell -- env MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix deps.unlock --check-unused
devenv shell -- env MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted
devenv shell -- env MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix compile --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix test
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.restore
devenv shell -- env MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
devenv shell -- env MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix npm.verify
devenv shell -- env MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix duskmoon_bundler.js.check
devenv shell -- env MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix npm.run test:js
devenv shell -- env MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix duskmoon_bundler.build singularity_web --tailwind
devenv shell -- env MIX_ENV=dev MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix xref graph --format cycles --fail-above 0
nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/e2e.yml .github/workflows/release.yml .github/workflows/docker-image.yml
```

| Executed gate | Actual result |
| --- | --- |
| Unit | 2092tests +10properties executed,0FAIL;1882 integration tests excluded |
| Integration | 1882tests executed (Storage1509/Runtime373),0FAIL/0INVALID;2102 tests/properties excluded |
| Independent restore | Existing V1/V2 oracle: two completed manifests, maintenance/empty stages, Note search3/3 |
| JS tests | 9files/197tests PASS |
| Static/build | roles/deps/unused/format/warnings-as-errors compile; frozen166-package install+verify;22-file frontend format/lint;Tailwind/JS build PASS |
| Architecture/workflows | xref0cycles with fail-above0; actionlint5workflow files,0findings |

Excluded-only apps are not execution passes. The existing independent restore
oracle is not ExUnit and does not qualify Task11's native knowledge-V3 saga.
Installing Playwright and linting e2e.yml are not E2E execution.

Every exact argv/logger, complete raw size/hash and natural-cleanup result is
retained in the15 per-gate closures under
`.devenv/phase5-task10-integration-repaired-readme-01-roles-closure.md`
through `15-actionlint-closure.md`. Complete aggregate:
`.devenv/phase5-task10-integration-repaired-readme-all15-closure.md`,
SHA256 `d27b4db9c3df827e4950ec24b92280be5414fde2cb22281ef7cb49fe583e571d`.
Its39-entry raw/closure/input evidence seal has SHA256
`b774f398b6adcefe3a34be4f5cc2166f9ec3bbbbde39253cf0f11149a07068eb`.
Original raw files, old manifests and old FAIL records remain immutable.

## Independent review and residual risk

Whole28 actual SPEC: `/root/task10_current28_final_actual_spec_v1`,
DONE/CLOSED PASS, no actionable P1/P2; root-retained receipt
`.devenv/phase5-task10-current28-final-actual-spec-v1.md`,
SHA256 `891d598a1d6f614d2d78e14c8de8ea4e71d2208dfffdd43bf1afe822bb562f48`.
NEW distinct fresh whole28 actual QUALITY:
`/root/task10_current28_final_actual_quality_v1`, DONE/CLOSED PASS, no actionable
P1/P2; root-retained receipt
`.devenv/phase5-task10-current28-final-actual-quality-v1.md`,
SHA256 `77d15cc6bc090d228cd39c05e1578fe89a034e994976b2501ab175303c4e1504`.
Both reviewers read all28 complete files and actual diffs, not latest8 amendment
receipts alone. Documentation acceptance is governed separately below.

Focused fixture qualification: A45/0, B4/0, selected C large-import1/0 with38
excluded, supplemental whole fixture D16/0. The C selector did not execute
the owning fixture file. Bounded A RED reached the new setup inequality
failure (13registered/1failure/12excluded); the original migration body/down
guard did not run. C RED proves count-contract failure but prints no numeric
map. Original assertions,8192row fixture,60s large-import deadline and sync remain.

Earlier old-source integration14FAIL/4INVALID and original PDF unit FAIL remain
historical FAIL. Original PDF and V3 large-record timeout causes remain UNKNOWN.
Current full-source nonrecurrence proves this gate passage, not the old cause or
a durability repair. No assertion or required gate is waived. A/B/C each had
one bounded Sol implementation qualification PASS and zero failed repair rounds;
inherited Source/utility counts remain preserved, not reset. The complete final
fifteen-gate generation added zero failed repair rounds.

## Documentation delta and next dependency

Progress status/checklists are synchronized after final actual code reviews.
Two qualified repair-design/plan before-images are retained in
`.devenv/phase5-task10-status-before/`: design SHA256
`540c0b77e3f9e11f557039411faa291b4b9e79af9d4f525b240abba84d2bd3c1`,
plan SHA256 `632e48e0223091825200fa54903d827d64ad79138035e6616e14485943ee2d83`.
All325 unaffected source327 entries and all28 code identities must remain exact.
The old327/seals are not overwritten or represented as current live-path checks
of those two edited docs. No product/test behavior changes occur in this delta.

Task10 local handoff closes only after sequential independent documentation SPEC
then NEW distinct fresh QUALITY both PASS, an explicit docs-only local commit,
verification of unchanged qualified code/evidence and a literal clean Git status.
The root-retained `.devenv/phase5-task10-local-handoff-closure.md` records actual
review receipts, documentation commit SHA and clean check; absence or failure of
that closure leaves local acceptance open. It is local evidence, not publication.

After documentation review and a local clean handoff, Task11's bounded formal
native-original text-ingestion prerequisite and V3 saga design/plan may proceed.
Existing ignored preparation is not author GO. Task12's defaultV3 switch still
requires Tasks8–11 GREEN and independent combined review. Task16 remains unwaived;
its lease freeze cannot be bypassed by this Task10 acceptance.

No merge,push,version bump,tag,release,deployment,production activation or
production-data access. E2E NOT RUN/manual-only/deferred and final
browser/release acceptance remains outstanding.
