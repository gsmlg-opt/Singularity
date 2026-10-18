# Phase 5 Task11 Final-Source Qualification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Qualify the restored final21-owner Task11 source through every required non-E2E gate without inferring repair from an unreproduced diagnostic.
**Architecture:** Independent design reviews precede one bounded parent-only verification campaign on pinned source. Each direct command has its own complete natural raw, separate ordinary post and original guard; actual source reviews precede source commits and accurate documentation reviews precede a separate docs commit.
**Tech Stack:** Elixir1.18.4/OTP28.5.0.3, seven-application Mix umbrella, private PostgreSQL17.10, pinned devenv, existing npm/Duskmoon tooling and actionlint.

---

## Status and file responsibilities

SOURCE/GATES QUALIFIED: independent DESIGN SPEC then NEW distinct QUALITY
preceded the26-row campaign; all26 gates and26 own posts PASS. Combined final21
actual SOURCE SPEC then NEW distinct SOURCE QUALITY CLOSED PASS before six
explicit local source commits, ending at `4a2e007649ab2d7c62aa72ee84bf1d2de0a93802`.
See [Task11 handoff](../../verification/2026-10-18-phase-5-task11-handoff.md)
for exact evidence and remaining documentation-review/commit/clean conditions.
Phase5 remains UNQUALIFIED; defaultV2 and all preserved restrictions remain.
The candidate/zero-start facts below describe the original preparation boundary.
Design: `docs/superpowers/specs/2026-10-18-singularity-v0.2-phase-5-task11-final-source-qualification-design.md`.

Create only this plan and its matching design. Modify only status/decision text
and Task5 completion in the existing lifecycle observation design/plan:
`docs/superpowers/specs/2026-10-18-singularity-v0.2-phase-5-task11-lifecycle-boundary-observation-design.md`
and
`docs/superpowers/plans/2026-10-18-singularity-v0.2-phase-5-task11-lifecycle-boundary-observation.md`.
All21 source paths/hashes are the complete locked map in design section2 and are
READONLY during this campaign. Parent additionally owns fresh ignored execution
GO/raw/manifests/ledger; historical manifests and original guard stay unchanged.
No production/test-code implementation is planned, so no new TDD seam or source
formatter is needed. Existing focused RED/GREEN evidence is retained.

## Task 1: Seal decision and review executable design

- [x] Read actual AGENTS, design and this complete plan, original guard, previous
  causal/contract decisions, consumed174/220 results and exact removal proof.
- [x] Root archive/cmp complete pre-edit lifecycle docs as regular0600 files;
  read ALL actual four-document changes and strict existing-document inverses.
- [x] Prove all non-owned pins/source21/HEAD/index/status/frozen56 unchanged.
  New status is exactly prior49 plus ONLY the two new candidate paths.
  Explicitly repin only reviewed document rows and new private artifacts.
- [x] Independent DESIGN SPEC checks rationale, exact vectors/coverage/order,
  one-shot allowances, environment adaptation, failure/restore/review boundaries.
- [x] NEW distinct DESIGN QUALITY checks the exact SPEC-passed candidate.
  Resolve findings before executable root GO; no routine human approval needed.
- [x] Root closes all actors/commands, original fullguard PASS and freezes source.
  Reviews grant only bounded verification, not final SOURCE approval/acceptance.

## Task 2: Execute exact26-row campaign

Shared protocol applies to EACH row separately, never paste this matrix as one
compound command. Start fresh Native numbering at222; each gate and own post
get distinct increasing numbers and explicit private filenames. Persist the
exact ID -> Native/argv/source-generation/raw/hash/exit/count/post/guard map in
a fresh ignored parent-owned ledger. Earlier raws are never overwritten.

For each row in the order below:

- [x] Write its concrete ignored GO including the exact argv, evidence purpose,
  reviewed design generation and still-unconsumed allowance. Require all prior
  rows and posts PASS; parent original fullguard, absent/nonsymlink raw and owned0.
- [x] Use umask077 and one direct launcher:
  `script --quiet --return --flush --log-out <fresh absolute private raw> -- devenv shell -- bash .devenv/phase5-pg-command.sh <exact argv>`.
  Angle-bracket fields are concrete per-run GO values, not shell input.
  Existing wrapper SHA256
  `66a4ace46937b352ca16e3099ce8d0c0b7d65338aba5e2cdacc5cccf788d19b5`
  selects only privatePG21905 and MIX_ENV=test; explicit dev overrides below
  remain. Do not start/stop shared devenv services, provision new role behavior,
  wrap argv in inner bash-c, add deadlines or change native deadlines/concurrency.
- [x] While LIVE parent ONLY empty-polls the exact owned session and reports
  concise progress; no other agent/repo/SQL/hash/process inspection command.
- [x] At natural closure read full safe0600 raw through actual footer, all
  per-application results and SHA256, recording actual executed/excluded/failed
  counts separately. ANSI escaping is presentation-only; no output filtering.
- [x] Launch its OWN fresh ordinary post via the same direct launcher:
```sh
psql --dbname=postgres --no-psqlrc --tuples-only --no-align --file=.devenv/phase5-task11-residual.sql
```
- [x] Fully read that post's actual raw/footer/hash; require natural0/EMPTY,
  original closingguard, exact unchanged source/status/HEAD/index/owned0.
  Only reviewed new private GO/raw/ledger paths may be explicitly added to the
  current manifest. Historical/frozen/source pins are never bypassed.
- [x] Any gate/post FAIL or discrepancy consumes this campaign and stops further
  rows for actual diagnosis. Preserve remaining rows NOT RUN. No automatic retry,
  plan-as-success, unreviewed rebaseline or successful-selected-test substitution.

Exact rows, in execution order (each code block is ONE direct argv):

### R01: Existing private test role provisioning verification; adapted README bootstrap prerequisite.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix singularity.db.verify_roles
```

### R02: README dependency resolution, no tracked lock/source changes.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
env MIX_ENV=dev mix deps.get
```

### R03: README unused-dependency check.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
env MIX_ENV=dev mix deps.unlock --check-unused
```

### R04: Complete README format check, not a formatter.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
env MIX_ENV=dev mix format --check-formatted
```

### R05: Complete README dev compile, warnings are errors.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
env MIX_ENV=dev mix compile --warnings-as-errors
```

### R06: Literal no-arguments README unit route; exclusions are not passes.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix test
```

### R07: Exactly ONE literal no-arguments full integration qualification attempt.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix singularity.test.integration
```

### M01: MasterTask11 complete live V3/fault/restore owners.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
```

### M02: MasterTask11 retained legacy unit owners, no new Vault test behavior.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix test apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs apps/singularity_runtime/test/singularity/runtime/restore_vault_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
```

### T01: Complete retained Storage integration owners.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_reconciliation_test.exs apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs --seed 215378 --warnings-as-errors
```

### T02: Complete retained native text integration owners; distinct seed from prerequisite.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/native_text_ingestion_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_authorization_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_cut_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs --seed 215378 --warnings-as-errors
```

### T03: Complete retained codec/schema/exporter unit selection; integration exclusions are not passes.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix test apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_schema_ddl_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs --seed 215378 --warnings-as-errors
```

### P01: Complete native prerequisite vector, exact seed0.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/native_text_ingestion_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_authorization_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_cut_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs --seed 0
```

### P02: Complete 12-owner Ingest/Runtime unit prerequisite vector, exact seed0.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix test apps/singularity_ingest/test/singularity/ingest/upload_request_test.exs apps/singularity_ingest/test/singularity/ingest/upload_text_test.exs apps/singularity_runtime/test/singularity/runtime/api_test.exs apps/singularity_runtime/test/singularity/runtime/accept_upload_test.exs apps/singularity_runtime/test/singularity/runtime/upload_session_lock_test.exs apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs apps/singularity_runtime/test/singularity/runtime/upload_message_stream_test.exs apps/singularity_runtime/test/singularity/runtime/authorization_test.exs apps/singularity_runtime/test/singularity/runtime/create_upload_grant_test.exs apps/singularity_runtime/test/singularity/runtime/cancel_upload_grant_test.exs apps/singularity_runtime/test/singularity/runtime/upload_session_supervisor_test.exs apps/singularity_runtime/test/singularity/runtime/upload_reconciler_test.exs --seed 0
```

### P03: Complete 17-owner integration prerequisite vector, exact seed0.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/asset_saga_test.exs apps/singularity_storage/test/singularity/storage/asset_grant_creation_test.exs apps/singularity_storage/test/singularity/storage/server_owned_upload_grant_test.exs apps/singularity_storage/test/singularity/storage/asset_stage_abandonment_test.exs apps/singularity_storage/test/singularity/storage/asset_sealed_checkpoint_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_fixture_lifecycle_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup_restore_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs apps/singularity_runtime/test/singularity/runtime/asset_vertical_test.exs apps/singularity_runtime/test/singularity/runtime/asset_verification_finalization_test.exs apps/singularity_runtime/test/singularity/runtime/upload_reconciliation_integration_test.exs apps/singularity_runtime/test/singularity/runtime/upload_session_lock_test.exs --seed 0
```

### P04: Complete four-owner legacy Storage unit prerequisite vector, exact seed0.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix test apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_storage/test/singularity/storage/backup_restore_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 0
```

### A01: Complete independent architecture owners; retain seven-application graph.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs --seed 215378 --warnings-as-errors
```

### S01: Independent complete NoteSearchStore owner. Existing task inserts --only integration; unchanged @moduletag :integration is actually executed.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs --seed 215378 --warnings-as-errors
```

### R08: README restore and MasterTask11 M03: ONE shared sole-independent restore invocation after all focused vectors, not two replacement tests.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
mix singularity.test.restore
```

### R09: README frozen frontend installation.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
env MIX_ENV=dev NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
```

### R10: README frontend dependency verification.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
env MIX_ENV=dev mix npm.verify
```

### R11: README JS check.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
env MIX_ENV=dev mix duskmoon_bundler.js.check
```

### R12: README JS tests, not E2E.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
env MIX_ENV=dev mix npm.run test:js
```

### R13: README production asset build.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
env MIX_ENV=dev mix duskmoon_bundler.build singularity_web --tailwind
```

### R14: README zero xref cycles; seven applications remain.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
env MIX_ENV=dev mix xref graph --format cycles --fail-above 0
```

### R15: README workflow syntax only. Does NOT dispatch any workflow or run E2E.

- [x] Natural gate0, full raw and its OWN ordinary post0/EMPTY/closingguard.
```sh
nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/e2e.yml .github/workflows/release.yml .github/workflows/docker-image.yml
```

R01 adapts the already-provisioned private-role verification prerequisite rather
than re-running README's `devenv up/down` and role-bootstrap lifecycle against
shared services. R02–R05 and R09–R14 explicitly use dev environment as the README
expects; the unit/integration/restore routes stay test. R06 and R07 remain
literal NOARGS with no flag/filter/seed/max_cases alteration. R07 authorizes
exactly ONE final-source attempt;174 qualification and220 diagnostic allowances
remain CONSUMED. S01 uses the existing integration task's real tag selector,
not ordinary unit exclusion. P01–P04 are verbatim prerequisite-document vectors;
do not consolidate them into seed215378 or a shorter subset.

R08 is also MasterM03 with the identical argv and unchanged source. Execute it
ONCE after all focused vectors; map its one raw/post to both obligations. It
remains the sole independent restore-scoped integrity task, with actual legacy
and new oracles. No substitute standalone test or selected helper suffices.
No overlapping runs are summed as distinct test coverage. R15 syntax checking
e2e.yml does not execute E2E or dispatch any workflow.

## Task 3: Final combined actual source review and local source commits

- [x] Require all26 rows and their26 separate posts PASS on the same frozen
  source21; record every raw/footer/hash/actual selection and original guards.
  Earlier174FAIL and220diagnostic-only remain recorded, not overwritten.
- [x] Obtain combined independent actual final21 SOURCE SPEC, reading complete
  governing master/saga/compatibility/retirement/current design/plan and actual
  complete sources/diffs/raw evidence, including unknown/unreached limitations.
- [x] Obtain NEW distinct actual final21 SOURCE QUALITY on exactly SPEC-passed
  bytes; resolve issues through evidence-backed diagnosis/scoped repairs and
  affected gate requalification under an amended reviewed plan, not a retry loop.
- [x] Root verifies all reviewed bytes, explicit file ownership and empty index,
  then makes small conventional local source commits by responsibility. No
  blanket staging, unrelated work, early commits, merge or publication.

## Task 4: Accurate documentation review and separate handoff

This immutable review candidate records Tasks1–3 complete. Final documentation
review/commit/clean results are recorded after actual closure in
`.devenv/phase5-task11-v3-task11-documentation-handoff-closure.json` rather than
predicting their PASS or changing the exact reviewed bytes to record themselves.


- [x] Synchronize tracked verification/design/plan docs with actual source
  commits, exact matrix results, raw hashes, migrations, changed paths and risks.
  Preserve PASS/FAIL/BLOCKED/NOT RUN/UNSUPPORTED and excluded counts honestly.
- [ ] Obtain documentation SPEC then NEW distinct QUALITY on accurate final docs;
  do not reuse design readiness or observer reviews as final documentation review.
- [ ] After reviews and all required gates, make a separate local docs commit.
  Run `git diff --check`, `git status --short` and the literal
  `test -z "$(git status --porcelain)"` clean-handoff check; do not stage/delete
  unrelated work merely to obtain a clean status. Record any genuine mismatch.
- [ ] Keep E2E NOT RUN/manual-deferred. No Task11/Phase5 acceptance before every
  required result/review; defaultV2/unsupported-canonical guard remain closed.
  Task12 needs its own reviewed design execution after dependencies, not this GO.
- [ ] Preserve Task16 BOTH strict ALL-leases UNSATISFIED/UNWAIVED/BLOCKED_DESIGN,
  Task17NOTGO and Task18 dependencies. No Vault/key/custody/capability/
  DownloadLease, product-scope, production-data, merge/push/version/tag/release/
  deployment/activation/backfill change.
