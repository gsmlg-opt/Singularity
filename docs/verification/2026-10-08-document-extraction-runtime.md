# Document extraction Runtime composition verification

Date: 2026-10-08. Status: bounded Runtime A implemented, focused unit verification
and independent reviews passed; mandatory B/C remain open.

## Goal-turn audit and authoritative source

The previous goal turn was **progress**, not a wait or no-progress turn:
checkpoint-preserving storage progress was committed at
`ebb1f7c6e67686d78c79f9125a44814dda69c06e`, independently reviewed and tested on
that exact source (93 integration and 16 unit tests, no failures). Its evidence
and bounded amendment status were recorded at
`5cf98c61172fba497bde1df2b4f81fa31c492011`.

Current worktree:
`/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`;
branch `codex/v0.2-phase-2-import-extraction`. It was clean at this turn's
start, at `5cf98c61172fba497bde1df2b4f81fa31c492011`. Read-only Git checks
confirmed linked-worktree isolation, no superproject, and unchanged root main
at `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`.

The release goal remains full implementation of
`2026-08-31-singularity-v0.2-release.md`; it is not redefined as this Task 12
component. Its final definition of done still requires later search/knowledge
phases, complete backup V3 and backward restore/upgrade evidence, the browser
workflow, complete release-source gates and exact-source multi-architecture
image/artifact qualification. At this turn's start, files had no
`documents/extract.ex` handler, Document JobDispatcher route or dedicated worker
dependency bundle. A now supplies those components, but actual source/claim and
outcome/recovery integration remains unverified. This and the later release
requirements disprove release completion. No goal completion or phase/release
acceptance is claimed.

## Approved contract and execution order

This continues the approved Phase 2 import/extraction design, Task 12 of its
implementation plan, the worker-bridge amendment and the source-replay amendment.
SQL bridge, typed worker repository, fresh sequential lease and preserving
progress are prerequisites already present in the current source.

The implementation worker proposed three dependency-ordered review steps.
The parent selected that recommendation under standing approval, without
dropping any Task 12 requirement:

1. **A: Complete production worker and unit contracts.** Closed envelope and
   live authorization, bounded descriptor/terminal replay, fresh sequential
   source read including authenticated empty originals, exact length/digest
   before claim, preserving waiting/running state, guaranteed lease cleanup,
   claim/resume, real format adapter composition, canonical completion,
   route/dependencies and existing terminal callback delegation. The production
   path must be complete; no stub, TODO or reduced fake-only implementation.
2. **B: Real source/claim and interruption integration.** Actual WorkerRepo,
   retained events and crypto custody; source Asset deletion, valid/corrupt
   empty originals, digest rejection, actual preclaim partial/full-read death
   and restart, postclaim death with unchanged deadline, locked wake/resume and
   checkpoint preservation, deletion before/after claim and authority fences.
3. **C: Real outcome/recovery/exhaustion/privacy integration.** Actual canonical
   outcomes and no partial fragments/search projections; recovery/retry/restore
   races, stale outcome rejection, active-attempt-only exhaustion, nonterminal
   retry and snooze behavior, bounded codes and content/tool/SQL leakage checks.

Steps B/C remain mandatory separately planned acceptance work, not waived tests.
Task 12 is not accepted after A alone. Every step requires its complete-code
plan, RED/GREEN evidence, independent spec then quality review, and scoped
regressions. The parent must personally read the complete executable plan and
give production GO before any implementation edits.

## Ownership and boundaries

Worker ownership: new Runtime `documents/extract.ex`, new
`document_extraction_job_test.exs`, additive `job_dispatcher.ex` and
`application.ex`, and the complete-code Runtime slice plan. Parent ownership:
this evidence, approved status documents and only the architecture-contract
additions explicitly allowed by worker-bridge section 9.

The existing architecture contract byte-freezes legacy Application/JobDispatcher
composition. Its extension must recognize only exact approved additions while
preserving baseline hashes, original bytes and negative assertions; it cannot
simply replace those hashes with the modified files. Existing dependency map
assertions are partial maps and need no weakening for additive dependencies.
Worker default extractor identities must match existing retry defaults:
`plain_text`/1, `markdown`/1 and `poppler_text`/1.

No generic job/wake, public repository, custody/key/lease, Vault, ACL, schema,
migration, search, backup or browser behavior change is authorized here.
No RequestRepo substitution, temporary grants, v4 reset/deletion, partial
canonical objects or production test hooks are permitted. Tests use actual
worker privileges; fixture administration remains separate.

## Verification state

Unchanged baseline commands:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 1208
```

Both exited zero. Runtime reported **39 tests, 0 failures, 17 excluded**
(22 unit tests executed). Architecture reported/executed **14 tests, 0 failures**.
No integration alias was used, so neither command allocated a temporary
integration database/storage root. These do not establish the excluded Asset
integration regressions.

The initial 32 new unit contracts then failed on the absent Document dispatcher
behavior/dependencies, seed 1208, with no exclusions. Expanded RED reached 40
contracts, then 43 after the cleanup correction below. The final command was:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs --seed 1208
```

It exited 2: **43 executed, 43 expected assertion failures**, no exclusions,
because the Document dispatcher route/callback/dependencies were absent.
Production was untouched throughout these RED checkpoints. The worker verified
the embedded test code was byte-identical to the 730-line test file, syntax and
format of the proposed complete worker, and all seven unique additive wiring
anchors. Main personally read the entire 1321-line executable plan, including
the final corrections, before production GO.

The parent-owned composition-guard plan preserves all original frozen hashes,
legacy bytes and historical assertions. Its seven literal insertion allowances
are unique and context-bound; new negatives reject mutation/removal/duplication/
relocation of each. The focused architecture command above exited 2:
**15 executed, 5 expected missing-addition assertion failures**, no exclusions,
before production wiring existed. Main then issued bounded Runtime A GO.

### Empty-source cleanup review correction

Pre-GO review identified that authenticated empty-source completion stops its
DownloadLease normally; a following synchronous revoke can race that stop.
An owned OTP probe confirmed both exact `:normal` and `:noproc` GenServer.call
exit shapes and was stopped under a monitor. Proposed cleanup accepts only
those closed-call exits with the same local lease PID, `:revoke`, and
`:infinity`. Bare exits, wrong PID/operation/timeout and shutdown remain failures
and prevent claim/extraction. Two positive contracts and one negative matrix
cover this narrow behavior. This was a plan review correction, not an observed
production repair failure. Actual crypto/empty-source qualification remains B.

### Already-claimed restart distinction

The worker surfaced whether custody/read failure during restart should snooze
or immediately persist a failed outcome. The parent checked the approved Phase 2
design's explicit rule: timeout and transient extractor/storage/post-claim
custody failures become `failed`. Therefore a pending descriptor may record
waiting and snooze without claiming, but an extracting descriptor already
proves this job owns an attempt. For its custody/storage failure, use that
descriptor's closed attempt fields to persist fixed `failed`/`extractor_failed`
through the independently fenced worker completion path. Do not call claim just
to fail or extend the deadline. Add focused tests for custody/read failure and
failure persistence error. Integrity mismatch still returns a sanitized
integrity incident without a new claim or extraction. Existing GenericWorker
terminal callback behavior remains unchanged.

Commands use the shared Mix slot serially. Borrowed services remain running and
must not be restarted. Integration uses the isolated
`mix singularity.test.integration` alias with the shared deps path. No E2E,
push, merge, tag, release, publication or deployment is being performed.

Sol failed production repair rounds: 0. Astra attempts: 0. Two failed Sol
production repair rounds or an evidenced technical impasse require parent-managed
Astra escalation, with at most three Astra attempts. Expected feature RED is
not a production repair round.

## Runtime A implementation and fresh verification

The complete new handler is 346 lines. Application adds eight lines and
JobDispatcher adds sixteen, with no original line removed or changed. Dedicated
Document DownloadLease wiring leaves Asset KeyLease unchanged. No Vault file or
compatibility patch, schema/migration, custody/key/capability semantics, generic
job/wake, public repository, backup, search or browser code changed.

The initial GREEN run reported 82 tests,17 excluded,65 executed and three new-test
failures: provenance values were accessed directly on SourceLocator rather than
under its established `fields` map. Exactly five accessor expressions were
corrected; expected line, heading and page values were unchanged. Production
needed no repair. One successful test-harness repair-and-validation round is
recorded; failed production repair rounds remain zero, Astra attempts zero.

Worker rerun seed1208 passed 65 Runtime unit tests and15 architecture tests;
xref found no cycles. Main then independently ran:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 1208
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_runtime/lib/singularity/runtime/documents/extract.ex apps/singularity_runtime/lib/singularity/runtime/application.ex apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs
```

Both exited zero: Runtime82 reported,17 excluded,65 executed,0 failures;
architecture15 reported/executed,0 failures; total80 executed. Formatting passed.
The same17 integration exclusions are not acceptance evidence. Main's independent
embedded-code comparisons found source/test byte-identical to the complete plan.
The final test file is735 lines. No integration database/root was allocated by
these ordinary unit commands. Main also independently ran:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
```

Both exited zero; xref reported `No cycles found`. Independent read-only
`document_runtime_a_spec` inspected actual source, dependencies, tests and
governing specifications and returned **SPEC_COMPLIANT**, no findings. Its own
whitespace check passed; it ran no Mix commands and changed no files. Independent
`document_runtime_a_quality` then independently inspected the complete diff/new
files and production dependencies and returned **QUALITY_APPROVED**, with no
critical, important or minor findings and no separate plan flaw. Its whitespace
check passed; it ran no Mix commands, edited no files and touched no services.
B/C remain mandatory and unstarted.

## Local source commit and exact-source recheck

After both independent reviews passed, main committed exactly the five code/test
paths and two complete-code plans as
`d5ea128f3423e54df2381d78b941cafff291a62a`
(`feat(runtime): compose fenced document extraction jobs`). The commit contains
no migration or Vault compatibility patch. This verification file was the only
remaining untracked path immediately after that commit.

Main reran the combined test command above on that exact committed source,
seed1208: Runtime82 reported,17 excluded,65 executed,0 failures; architecture15
executed,0 failures; total80 executed, exit0. Main also reran the same focused
format check and xref command on the committed source: both exit0, no cycles.
All commands finished. These are bounded unit/composition results only.

Full Task12 source/claim and outcome/recovery qualification (B/C), full Phase2
README gate/checklist, and later release definition-of-done work are still open.
Main inspected the release plan's final checklist again; unified search, complete
knowledge/backup/upgrade/browser and exact-source artifact/image qualification
are not established. The goal remains active, not complete or blocked. Current
work made concrete progress with reviewed/tested source, not a wait/no-progress
turn. No E2E, merge, push, tag, release, image publication or deployment occurred;
root main remained unchanged at `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`.
