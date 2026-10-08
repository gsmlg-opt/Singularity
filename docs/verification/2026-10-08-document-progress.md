# Document checkpoint-preserving progress verification

Date: 2026-10-08. Status: bounded storage implementation locally accepted on exact
source `ebb1f7c6e67686d78c79f9125a44814dda69c06e`. No phase/release acceptance.

## Source, authority and scope

Worktree: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`.
Branch: `codex/v0.2-phase-2-import-extraction`.
Initial clean baseline: `5f2b4cfba610069ffaaec3aaddb068cf2a650340`.
The previous goal turn was concrete progress: fresh lease implementation
`03a1bc2` passed 95 exact-source focused tests and independent reviews.

This storage-only slice follows the Progress and unlock wake section of the
[approved source-replay amendment](../superpowers/specs/2026-10-08-singularity-v0.2-document-source-replay-design.md).
Only `postgres/document_worker_repository.ex`, its existing focused test file,
and a complete-code slice plan are implementation-owned. Parent documentation
is separate. No new migration, grant, SQL entrypoint, schema, GenericWorker,
WakeHandshake, generic Progress, custody, key/capability, unlock/locking, Asset
or Vault feature change is authorized.

The new method accepts only Document envelopes and `:running` or
`:waiting_for_unlock`, returns a bounded `{:ok, :saved}` receipt and must reject
terminal-progress reopening with a sanitized conflict. Actual WorkerScope and
WorkerRepo calls must validate current authority and exact submission/owner/
private-classification binding in a short transaction. The submission lock
precedes the progress lock, matching existing wake machinery.

An absent row uses existing v1/revision-zero/empty-checkpoint defaults. Existing
rows may change only `state` and `updated_at`; checkpoint version, processing
revision and checkpoint JSON must remain verbatim, including v4. No generic
Progress reset or replacement is permitted. Runtime snooze/resume wiring and
full extraction death/restart acceptance remain later work.

## Characterization

The implementation worker reported this unchanged adapter baseline:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
```

Seed 52380: **47 tests, 0 failures**, exit zero. Isolated database
`singularity_test_d87ca1aa7bd303985121ea36`; command and alias cleanup completed.
The expected new-method RED and personally reviewed complete-code plan are
required before production edits. No production edits occurred at this point.

The first expanded test run was **not valid feature RED**: seed 219266,
72 tests / 72 failures. A linked race-test child raised on the missing method
and interrupted fixture cleanup, leaving the fixture-owned repository registered
and causing cascading `already_started` failures. The worker is adding a
method-availability setup guard before spawning barrier tasks, retaining all
substantive race assertions. A fresh run must recover all 47 original passes
and isolate the expected new-method failures before production GO. The worker
reported that the baseline and failed-run isolated databases and storage roots
were absent after cleanup. No production edits or production repair rounds
occurred in this harness-preparation run.

Corrected RED reran seed 219266: **72 tests, 25 expected new-feature failures**;
all **47 original tests passed**. Race/setup preflight guards fail before
spawning linked tasks when the method is absent; substantive race assertions
remain unchanged. An additional concurrent-revocation contract brings the final
planned inventory to 73 tests. The fixture's complete v4 binding now uses index
one, consistent with its one-chunk source.

Final RED, seed 219266: **73 tests, 26 expected new-feature failures**, all
47 original tests passing. Of the new failures, 23 are missing-method failures
and three are method-availability preflight assertions. Isolated database
`singularity_test_80aaa3024c632dd170ef06ad` and storage root
`/tmp/singularity/integration/80aaa3024c632dd170ef06ad` were removed by the alias.
The worker confirmed all five preparation databases/storage roots absent and
released the Mix slot. Focused formatting and `git diff --check` passed.

The parent personally read the complete 928-line executable slice plan,
including every additive test and the exact production patch, before GO.
A placeholder scan found none. Existing migration
`20260718000400_create_outbox_and_jobs.exs` lines 96–97 supplies the timestamp
defaults needed by the proposed insert; no schema change is required.
Production GO was then issued for the reviewed adapter patch and focused GREEN
only. Independent spec and quality review remain required before acceptance.

## Implementation GREEN

The worker applied only the reviewed adapter patch. The same focused command
with seed 219266 passed: **73 tests, 0 failures**, exit zero, no compilation
warnings. Isolated database `singularity_test_9fd4434fc03c1b76afe82daf` and its
storage root were confirmed absent after alias cleanup. Scoped formatting and
`git diff --check` passed; the worker released the shared Mix slot.

Production changes are limited to `put_progress_state/3` and its private scope,
submission and progress helpers. An absent generic row is inserted with conflict
handling; the reloaded row is locked/validated before state-only mutation. SQL
never selects checkpoint JSON into the response or updates existing checkpoint
fields. The existing describe function supplies live authorization and retained
event/generation validation without requiring an unlocked owner.

## Parent verification and independent review

Fresh parent scoped integration command:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs apps/singularity_storage/test/singularity/storage/scoped_repo_test.exs apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs apps/singularity_storage/test/singularity/storage/postgres/custody_repository_test.exs --seed 219266
```

Exit zero, seed 219266: **109 reported tests, 0 failures, 16 excluded**;
**93 integration tests executed**. The excluded OutboxOban tests were then run
separately:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs --seed 219266
```

Exit zero: **16 unit tests, 0 failures**. The integration database was
`singularity_test_d44b28f33e8da82d9b7996f8`. Read-only `psql` confirmed both
worker GREEN and parent integration databases absent; exact-path filesystem
checks confirmed the parent storage root absent. Shared services were untouched.

Static commands:

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format --check-formatted apps/singularity_storage/lib/singularity/storage/postgres/document_worker_repository.ex apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix compile --warnings-as-errors
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
```

Focused `mix format --check-formatted` passed on the adapter and test file.
`mix compile --warnings-as-errors` exited zero, recompiling one storage module;
this is an incremental strict compile, not a clean seven-application build.
`git diff --check` passed. The additive test patch reverse-check passed, and the
production additions match the reviewed plan (the plan's replacement of the
unchanged `defp parameters` anchor is not a production delta).
`mix xref graph --format cycles --fail-above 0` exited zero: **No cycles found**.

Independent read-only Sol spec review returned **SPEC_COMPLIANT**, with no
missing/extra requirements. It inspected actual source, supporting bridge SQL,
scope/rollback behavior, WakeHandshake lock order and additive tests; it did not
rerun tests. The subsequent independent read-only Sol quality review reported
**no Critical, Important or Minor actionable findings**. It additionally checked
the old v4 checkpoint CAS and found the state-only update cannot overwrite its
JSON, and confirmed submission-to-progress lock order is compatible with the
unchanged wake machinery. It ran only a read-only diff check, not Mix/services.

## Source commit and exact-source audit

Source commit: `ebb1f7c6e67686d78c79f9125a44814dda69c06e`,
`feat(storage): preserve document checkpoints in progress updates`.
It contains only the adapter, focused additive tests and complete-code slice
plan. Staging exposed five whitespace-only blank context markers in the embedded
plan patches, which untracked-file diff checks had not covered. The parent
normalized those documentation markers to equivalent removed/added empty lines;
the test patch still passes a read-only reverse check with `--unidiff-zero`.
No source/test behavior changed, and staged `git diff --check` then passed.

Exact committed-source commands (seed 219266):

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs apps/singularity_storage/test/singularity/storage/scoped_repo_test.exs apps/singularity_storage/test/singularity/storage/postgres/custody_repository_test.exs --seed 219266
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix test apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs --seed 219266
```

Both exited zero: **93 integration tests and 16 unit tests, no failures**.
The source/test diff against the committed SHA was empty before the reruns.
Exact-source database `singularity_test_6758b0e40327e910b11b3a5e` and storage root
`/tmp/singularity/integration/6758b0e40327e910b11b3a5e` were confirmed absent with
read-only `psql` and exact-path filesystem checks after cleanup. All commands
finished; no services were restarted or stopped. Subsequent edits only record
verification and update the amendment's bounded-component status; production
and tests remain byte-identical to this source SHA. No broader acceptance is
inferred from the local source commit.

## Remaining release work

This is storage-level checkpoint/wake evidence, not a working Runtime extraction
job. `documents/extract.ex`, JobDispatcher/dependency composition, real preclaim
and postclaim death/restart, full digest-before-claim and fenced extraction
outcomes remain mandatory Task 12 work. Existing recovery/API implementations
still require their designated acceptance checks. Later release phases, backup
v3, browser workflow, full source-SHA verification and release image/artifact
gates remain open. No complete phase/release gate was run or waived.

No Vault feature work or compile compatibility patch occurred. No migrations,
keys, capabilities, grants, custody protocols or generic job/wake behavior were
changed. Root main remains unchanged at
`e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`.

Sol failed production repair rounds: 0. Astra attempts: 0. No E2E, push, merge,
release, publication or deployment occurred. Full Task 12, Phase 2 and release
acceptance remain unproven; the full release goal remains active.
