# Phase 5 portable export and logical V3 qualification

## Current status

**IN PROGRESS — Tasks 1/2 pure contracts, NOT accepted.** Phase5 has its own
worktree `.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`, based on Phase4 documentation handoff
`5f7e6363be534dbfb4dfa1475538fddcbd29cf32`. Phase4's exact tested implementation
source is `42c01a5c99b1df3d1e4284d277c6ea48046875cb`; its complete permitted
non-E2E gate and independent reviews are recorded in the
[Phase4 acceptance report](2026-10-11-phase-4-acceptance.md).

Phase4 application, test, schema, workflow and dependency bytes are unchanged in
this starting checkout. The clean Phase5 baseline below is focused
characterization, not V3/portable-export implementation acceptance or a rerun of
the entire Phase4 gate. The detailed Phase5 design used bounded Astra
architecture advice, not an implementation repair attempt. Parent self-review,
independent design SPEC followed by fresh QUALITY, and independent detailed-plan
SPEC followed by fresh QUALITY have closed with the bounded corrections below.
This permits starting Task 0; it does not qualify V3 or portable export.

E2E remains **manual-only, NOT RUN**, explicitly deferred by the user for local
development and phase advancement. All other required verification and actual
independent review remain mandatory. No final browser/release acceptance is
claimed. No merge, push, version bump, tag, release, deployment, production
activation or production backfill is authorized or performed here.
Vault/custody/key/capability/policy/cryptography semantics remain frozen.

## Isolated checkout and protected state

Parent verified the main checkout was clean at
`e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`, the Phase4 checkout was clean after
its six-document local handoff commit, the new path/branch did not exist, and
the project-local `.trees` path is ignored. No native worktree creation tool
was available, so the Git fallback was used from the main checkout:

```sh
git worktree add /home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup -b codex/v0.2-phase-5-export-backup 5f7e6363be534dbfb4dfa1475538fddcbd29cf32
```

The command exited 0. The new checkout was clean on the named branch at the exact
handoff SHA; main and the earlier phase worktrees were not merged or modified.
The unrelated untracked Phase2 runtime-outcomes plan remained present with
SHA-256 `350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.
It was not staged, deleted or edited.

## Clean baseline execution

All commands below were executed by the parent in the new Phase5 worktree
before any Phase5 application/test/schema edit, with no parallel Mix, formatter,
database or service run.

### Dependency resolution and fresh compilation

`16147` completed normally, exit 0:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do deps.get, compile --warnings-as-errors
```

Dependency resolution reported the existing versions unchanged. The new
worktree's isolated `_build/test` compiled dependencies and all seven umbrella
applications. No lockfile or application/configuration source change resulted.
The devenv version-update notice remained visible; no dependency or Nix update
was performed to silence it.

### Full focused owning files

`31790` completed normally, exit 0, seed `215378`, warnings-as-errors:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_bundle_verifier_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --seed 215378 --warnings-as-errors
```

The complete seven owning files reported **136 tests, zero failures**:

| Application | Tests | Failures | Reported time |
|---|---:|---:|---:|
| Core | 40 | 0 | 13.2 seconds |
| Storage | 34 | 0 | 1.9 seconds |
| Runtime | 26 | 0 | 4.7 seconds |
| Web | 36 | 0 | 1.9 seconds |

These characterize existing Markdown sources, logical record encoding,
authenticated logical verification, the immutable V1 fixture/V2 compatibility,
Runtime Markdown export and the full existing architecture/scope contracts.
SQL integration and E2E were not part of this focused baseline.

### Static baseline

`4551` completed normally, exit 0:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted, xref graph --format cycles --fail-above 0
```

Full format checking passed and xref reported **No cycles found**. The starting
tracked checkout remained clean; no application, migration, workflow, lockfile
or dependency changes occurred. The report itself is the first parent-owned
Phase5 documentation record, not an implementation qualification.

## Remaining qualification

The authoritative master [Phase5 deliverables](../superpowers/plans/2026-08-31-singularity-v0.2-release.md#phase-5--portable-export-backup-v3-restore-and-upgrade)
remain unchecked. V3 payloads, complete portable artifacts, historical-graph
restore, original-source digest verification, Document search/work rebuilding,
malformed rejection and upgrade fixtures are not implemented or accepted.
Each bounded TDD implementation slice, owning tests, full permitted gate,
final SOURCE SPEC then fresh QUALITY,
environment cleanup and local handoff remain required.

## Design and detailed-plan review closure

These are actual native-agent reviews, not test executions. The ignored
`.devenv/*-native.md` files are parent transcriptions of those reviews; original
FAIL verdicts remain FAIL and are not replaced with passing evidence.

The parent read the original 666-line design completely at
`8956200fb12784700b9148d6e94079eae08b3a1c282b41d09d0e95e27f5cf9d2`.
Independent Sol SPEC found one P2: the stated restore saga order disagreed with
the actual frozen implementation. Only §8 was corrected; SPEC closed at the
669-line snapshot `3bf8957b42fd9136b23b4172ae17c7515d4e6c1486a735d996f088df0e7e7d3a`.
Separate fresh Sol QUALITY read all 669 lines and found no P0–P2, with two P3
clarifications: completed handles survive their request process, and the new
portable Markdown renderer preserves existing `render/2` bytes. Those bounded
changes closed through SPEC then separate QUALITY carry at 679 lines,
`45ec328473ff1b92627ec27b6bbe21b4e18fdb02452b1d5affd8d09b2e150c6f`.
The final carry is not a fresh complete 679-line reread.

The parent read the original 1,269-line detailed plan completely at
`9071106f500f59e58225169886a9763b6155da8374c37923f05b9fc75959bac8`.
Independent Sol PLAN SPEC found two P2s: incomplete owning-file test modes and
an explicit V3 writer/guard dependency cycle. Bounded corrections added the
missing pure/SQL owners and moved the version-aware guard into Task 8 while
preserving default V2 and the legacy guard. SPEC closed at 1,289 lines,
`4857e117c42d6e5b15dfc6d6539ff21d231647b5dcb200d8019c51deac60ec2b`.
Separate fresh Sol PLAN QUALITY read all 1,289 lines and found one P2: a new
V1 writer could omit Note-only history because the legacy guard checks only
eight V3 tables. The minimum-scope correction rejects all new V1/unknown writer
requests before queries/streams, requires independent live/history/conflict/
tombstone Note-only negatives with no V3 rows, and preserves V1 codec, golden,
decoder and restore compatibility and the unchanged V2 guard. Independent
SPEC then separate QUALITY carry closed at 1,328 lines,
`9ac947a920af6c95f8d9a20de2bbdac9c7038fccbea28618ea0968f812f7598b`.
Coverage is the complete original reviews plus their complete bounded deltas,
not a fresh full 1,328-line reread. Both final verdicts have zero outstanding
P0–P2 in the reviewed boundaries. Frozen baseline entries were checked by the
reviewers. No reviewer ran tests, Mix, formatter, databases, services or network.

Selected ignored native receipts, with SHA-256:

| Receipt | SHA-256 |
|---|---|
| `phase5-design-review-closure-v2-native.md` | `930b3f0fd72f3b9193a1b77b688d441a7e6f0877c36d6d5e6ce3dd7e19f1f21c` |
| `phase5-plan-spec-v1-native.md` (original FAIL) | `4d35b2c7c3b36e57c6759576f7ffe63fffa1f7968f162cad652b57ddea4bdace` |
| `phase5-plan-spec-closure-v1-native.md` | `865704dc16ef672c153dc303b0e2ae0145a6c4e6c5752d05b6600048204efad2` |
| `phase5-plan-quality-v1-native.md` (original FAIL) | `6bdcd053dcce79a691c8ca252f1000ba3cbdbcb6dc70e300e94e3a4683545e30` |
| `phase5-plan-spec-closure-v2-native.md` | `a9915e673886ae7e9cea6e1dcc625471f471009ffbcbf9f303fe1c9a03dfb63f` |
| `phase5-plan-quality-closure-v2-native.md` | `6a1fe586fd0fe9590388d88ac1d7c928bdf3a32f34861a674970a14446c46d0f` |

Task 0's status updates and explicit production-write prohibition are bounded
governance synchronization, not additional product or Vault authority. They
will receive actual SOURCE SPEC then separate fresh QUALITY after GREEN.
Implementation Sol/Astra repair rounds remain **0**; plan/design corrections
and expected RED do not count as failed implementation repairs.

## Task 0 — active Phase 5 governance

The source author changed only the two full governance files for the RED stage:
current-phase selectors/links and one additive Phase5 authority test. Historical
Phase3/4 assertions, all removal/duplication/relocation/registration/Markdown
counterexamples, exact five governing bullets, full continuous authorization/
protocol equality, runtime legacy hashes and V1/V2 schema hashes remain intact.

Parent-executed RED `20552` completed normally with exit **2**:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --seed 215378 --warnings-as-errors
```

Result: **37 tests, 4 expected failures**, 2.0 seconds. Failures were the old
Phase4 active selector in AGENTS, old Phase4 README/guide scope selector,
missing Phase5 guide header links, and the missing explicit production-write
prohibition in design §1. Remaining historical/negative assertions passed.
Ignored captured output `.devenv/phase5-task0-red.log` has SHA-256
`0d609aff64ace33c268ffc3d11ba0b7bdb704dabaca0c8d60ccbb6aaa1666fb4`.
This is expected RED, not a passing gate. Documentation synchronization, GREEN
and static checks completed below. SOURCE SPEC, fresh QUALITY and the local
commit were pending at the original review snapshot; their actual closure is
recorded in the following subsection.
No application, migration, workflow, dependency, runtime grant or Vault behavior
has changed. No SQL database/service was started and E2E remains NOT RUN.

### Task 0 GREEN and static verification

The author changed only AGENTS/README/guide current-phase narrative, preserving
Phase3/4 links and tested provenance. The coordinator updated design/plan review
status and added the explicit existing production-write prohibition to design
§1. No production adapter, guard, schema, runtime-baseline stripping or frozen
semantics changed.

Parent repeated the same full two-file test command in `31229`; normal exit
**0**, **37 tests, zero failures**, 1.9 seconds, seed `215378` and
warnings-as-errors. Parent static `91180` completed normally, exit **0**:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
```

Full format and warnings-as-errors compilation passed; xref reported **No cycles
found**. Parent `git diff --check` exited 0. Parent also verified all **56** entries
in `.devenv/phase5-frozen-baseline.sha256` with `sha256sum -c`; every entry was OK.
These qualify the Task0 governance checks only, not Phase5 functionality or the
complete phase gate. SOURCE SPEC then separate fresh QUALITY was pending at
the original report snapshot and subsequently closed below.

### Task 0 independent source review and local commit

Actual independent Sol SOURCE SPEC followed by a separate fresh Sol SOURCE
QUALITY both returned **PASS, no findings**. Each read the complete five-file
tracked diff, full current governance tests (1,181/850 lines), AGENTS (218),
README (164), report (213), and affected guide sections. Prior full design/plan
reviews carried through all verified status/production-prohibition metadata
deltas; neither claimed a fresh full design/plan reread. Both checked the actual
parent RED/GREEN/static logs and all 56 frozen files; reviewer test execution
was NOT RUN. All read-only commands finished and all eight reviewed hashes
remained unchanged throughout both reviews.

The exact eight-file review manifest `.devenv/phase5-task0-source-reviewed.sha256`
has SHA-256 `1c76ded8c1d45c22a062bef17e1849ff457b47855edcc062eca50e2d16b65bf8`.
Its report snapshot was
`add3178334f73eccfde8de2a95abe5bb514cbe16f49eb0d8b4571505e6d3e636`;
pending-review language was correct before the verdict, not a false PASS.
Ignored native receipt transcriptions:

| Receipt | SHA-256 |
|---|---|
| `phase5-task0-source-spec-native.md` | `9cd2948a9cdb7f4133034b4a3a6e2d1b85592b496cd9432b52a76642b11de499` |
| `phase5-task0-source-quality-native.md` | `117d19efcb5ae3dca45a4619fd1d6275f08b9579a4b6e0cad179e435b544ef26` |
| `phase5-task0-green.log` | `971c015e00cf8d9e13095a3d23173f1814fc4821258a7e8a299003afc7fa54fe` |
| `phase5-task0-static.log` | `9a3dc75733d125ec6bcaf065db2d08ac31e68d2bdad931fe05703e4bd4ba9e02` |

Parent verified the exact reviewed hashes and clean index, checked that no
active Git hook would run an unrequested gate, staged exactly the eight scoped
paths, checked the staged diff, and created the local commit:
`95f4df1c9e8577f4d611d60c0dda4d3385cbd517`,
`docs: start phase five export and backup qualification`.
Commit exited 0: eight files, 2,388 additions and 21 removals. The worktree was
clean immediately afterward; no ignored tooling or unrelated files were staged.
No merge/push/publication occurred. This closes Task 0, not Phase5 acceptance.
The plan checklist and this post-verdict record are updated only after the
successful commit and will receive the next bounded task's documentation review.

Tasks 1 and 2 now have disjoint Storage/Core source ownership and start with
RED-only tests. Parent keeps all Mix, formatter, database, service and Git
operations serialized. Both production default V2 and the current guard remain
closed; no V3 restore or production activation is enabled. E2E stays NOT RUN;
implementation Sol/Astra repair rounds remain 0.

## Tasks 1/2 — observed RED before parallel implementation

### Task 1 explicit V3 wire contract

Storage test-only changes added a literal independent 87-column/PK/tag/nullability
contract, immutable V2 prefix, default V2 and frozen V1/V2 hashes, three fixed-hex
cut/row/object vectors, malformed types/count vectors/keys, and authenticated
bidirectional mixed V3↔V1/V2 row/object rejection through both verifier paths.
Three existing unknown-version fixture values advanced from 3 to 4 (two codec,
one verifier); their exact rejection assertions remain. No released migration,
V1 compatibility fixture, Restorer, Exporter, default or guard was changed.
The parent read the entire new 281-line schema test and complete codec/verifier
test delta before entering implementation. Synthetic V3 rows establish wire
shape only, not legal historical-graph admission or live source custody.

Parent RED `51873` completed normally, exit **2**, seed `215378`,
warnings-as-errors:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_bundle_verifier_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
```

Result: **51 tests, 12 expected failures**, 1.9 seconds. Failures were the missing
V3 registry and explicit logical version 3 being unsupported; the 34 existing
contracts and five newly closed negative/default/hash cases passed. The latter
are not sufficient alone—positive V3 cases and all negatives must pass together
after implementation. Ignored captured output `.devenv/phase5-task1-red.log`
has SHA-256 `9fb1a58dd2275bdbce5895ef509c6521fc2070b4370f24791e785784a3b8588a`.
GREEN, static checks, full owning regressions, independent reviews and local
commit remain pending. Exhaustive actual-DDL agreement is still Task 3.

### Task 2 pure portable contracts

Core added six options/path tests, eleven exact-manifest tests and nine portable
Markdown tests; all 40 existing Markdown assertions remained unchanged. The
parent read all 126 options/path and 291 manifest lines and the entire 209-line
additive Markdown delta. These test pure values, exact pin/path identity,
privacy/key/type rejection, canonical encodings, fixed limits, readable metadata
and escaping; they do not prove filesystem containment or live authorization.

Parent RED `2362` completed normally, exit **2**, seed `215378`,
warnings-as-errors:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_core/test/singularity/core/knowledge_export_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs --seed 215378 --warnings-as-errors
```

Result: **66 tests, 26 expected failures**, 13.9 seconds. Every new failure was a
missing pure constructor or `render_portable/3`; all 40 established tests passed.
Ignored captured output `.devenv/phase5-task2-red.log` has SHA-256
`6f78aa7d43c21df204a238f3226425c691e0acbdee89a6492ac6b8e85e3a6025`.
GREEN, static/owning regressions, independent reviews and local commit remain
pending. Runtime authorization, streamed artifacts and filesystem faults remain
in their designated later tasks.

Both writers began only after their actual parent RED executions finished.
Storage/Core implementation may run in parallel with disjoint ownership; the
parent will run no Mix/formatter validation until both writers stop. No SQL
database/service or E2E run occurred. These expected RED results are not failed
implementation repair rounds; cumulative Sol/Astra implementation repair
counts remain 0. Phase5 is NOT accepted.

## Tasks 1/2 — actual GREEN, pending independent source reviews

Both source authors stopped before the parent ran Mix or the formatter.
The parent read the complete new Storage/Core implementations and additive
Markdown source delta; all established render/2 implementation and assertions
were retained. These are pure wire/value contracts, not SQL admission, live
custody, filesystem containment, aggregate streaming, or Phase5 acceptance.

### Compile diagnosis and bounded repair

The first owning GREEN attempt (`58323`) exited **1** before any tests ran:
KnowledgeExport used Elixir's reserved module attribute `@file` for a Regex.
This is a Task2 compile defect, not a V3 test failure or a passing gate.
The Core author completed Sol repair round **1** by renaming only that
attribute and its reference to `@portable_file_path`. No assertion or test
shape was changed. That defect is resolved by the subsequent actual builds
and owning GREENs below; no Astra implementation recovery was required.

### Owning behavior and formatted downstream regression

- Task1 retry `19998`, exact RED command above: normal exit **0**,
  **51 tests, 0 failures**, 2.0 seconds.
- Task2 `2127`, exact RED command above: normal exit **0**,
  **66 tests, 0 failures**, 14.2 seconds.
- Parent formatted only the twelve changed/new application and test files
  (`74519`, exit **0**), then re-ran every owning file plus the unchanged
  Runtime single-Note Markdown consumer and both complete governance files:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_bundle_verifier_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_core/test/singularity/core/knowledge_export_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --seed 215378 --warnings-as-errors
```

Execution `91446` completed normally, exit **0**, seed `215378`,
warnings-as-errors. Core **66/0**, Storage **51/0**, Runtime **26/0**,
Web governance **37/0**: **180 tests, 0 failures**. SQL/E2E were not run.

### Static and immutable-source checks

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
sha256sum -c .devenv/phase5-frozen-baseline.sha256
git diff --check
```

Static `91245` exited **0**: format and warnings-as-errors compilation passed,
xref reported **No cycles found**. The parent checked all **56** frozen
baseline entries successfully and `git diff --check` exited **0**.
Default logical V2, its unsupported-canonical guard, V1/V2 registries, outer
Manifest/framing/crypto, released migrations and frozen Vault/runtime source
remain unchanged. Restorer version3 and any new export activation stay closed.

The parent captured the normal owning GREEN, full regression and static
outputs under ignored `.devenv/phase5-task1-green.log`,
`.devenv/phase5-task2-green.log`, `.devenv/phase5-tasks12-regressions.log`,
and `.devenv/phase5-tasks12-static.log`. Exact twelve-file reviewed-source
hashes are recorded in `.devenv/phase5-tasks12-source-review.sha256`.
Actual independent SOURCE SPEC followed by separate fresh QUALITY and
small scoped local commits remain pending. Task3 must still compare all
87 appended columns against actual PostgreSQL DDL and prove fixture legality.

Cumulative implementation repair counts: **Sol 1** (reserved attribute,
resolved), **Astra 0**. Expected RED and formatting are not failed repairs.
E2E remains manual-only **NOT RUN**; no Vault feature work, migration,
database/service startup, merge, push or publication occurred. Phase5 is
**NOT accepted**.
