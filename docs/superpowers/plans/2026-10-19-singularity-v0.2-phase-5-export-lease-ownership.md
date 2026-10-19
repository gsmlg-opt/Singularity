# Phase 5 Task16 native export-lease ownership implementation plan

> For workers: use subagent-driven-development after coordinator DESIGN SPEC
> then NEW distinct QUALITY closure. Root owns native gates, exact staging and
> commits. Workers are not alone; preserve all other edits and ignored evidence.

**Goal:** close the native acquisition-timeout and pre-recording companion-death
gaps without broadening any authority or ordinary lease semantics.

**Design:** [native export-request ownership](../specs/2026-10-19-singularity-v0.2-phase-5-export-lease-ownership-design.md).
**Baseline:** branch `codex/v0.2-phase-5-export-backup`, clean initial HEAD
`a5afb537e7d8f7455ec71e7c98bc120d5d397673`, existing `.trees` worktree.
**Stack:** existing OTP/Elixir, atomics, native monotonic clock, PostgreSQL and
genuine encrypted storage fixtures. No dependencies, migration or configuration.

Current source snapshot: Tasks A–E have actual scoped verification and independent
SOURCE SPEC then NEW distinct QUALITY at local source
`6c7f867309470e23e8f34c06a8f53af0b496d48d`. Task F's
[handoff](../../verification/2026-10-19-phase-5-export-lease-ownership-handoff.md)
is the documentation-review candidate; its review/commit/clean closure and the
resumption of original Task16 follow as subsequent actual facts. No wholeTask16/
Phase5 acceptance. The historical design-stage status below is retained.

Historical design-stage status: design self-reviewed; independent design gates PENDING; implementation
NOT STARTED; both strict Task16 guarantees UNSATISFIED/UNWAIVED. This plan records
expected checks, not executed results. E2E NOT RUN/manual-deferred. No publication,
deployment or production activation. The original Task16 startup, Task8 exact
attribution and artifact requirements remain in force after this prerequisite.

## Task A: close design and preserve baseline

- [x] Root captures branch, HEAD, index, literal status, original56 manifest and
  two original source hashes; preserve Task12 actual closure and prior assessment.
- [x] Root updates AGENTS, ADR0003, README, guide, release master, Phase5 design/
  plan and original Task16 design/plan with the dated sole exception. Preserve
  historical failures, strict assertions and fixed historical source literals.
- [x] Actual independent nonauthor DESIGN SPEC; resolve findings. Then NEW
  distinct QUALITY reviews the full current design/plan plus actual governance
  diffs. Source GO only after both close PASS. Architecture author is not reviewer.
- [x] Exact docs-only local commit after `git diff --check`, link and scope checks.
  Record commit and literal clean status. No source/test edits before source GO.

Governance paths: `AGENTS.md`, `README.md`, `docs/guide.md`,
`docs/adr/0003-vault-frozen-for-knowledge-base-development.md`,
`docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`,
`docs/superpowers/specs/2026-10-11-singularity-v0.2-phase-5-export-backup-design.md`,
`docs/superpowers/plans/2026-10-11-singularity-v0.2-phase-5-export-backup.md`,
`docs/superpowers/specs/2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership-design.md`,
`docs/superpowers/plans/2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership.md`,
and these two new dated documents.

## Task B: characterize, then prove RED

Root alone executes gates; close all author/reviewer command windows before VM.
All runs use a fresh private mode0600 raw PTY, established private-PG wrapper,
natural completion and a separate ordinary post query. No command deadline,
seed override, filtered output, forced database cleanup or secret raw log read.

Unchanged complete regression owners:

```text
apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs
apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs
apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs
apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs
```

- [x] Characterize these whole owners on unchanged production source; record
  actual selected/excluded counts separately. An integration-tagged file in a
  pure run is not native qualification.
- [x] Sol test author owns only NEW
  `apps/singularity_runtime/test/singularity/runtime/export_lease_ownership_test.exs`
  and additive cases/observers in the existing live custody owner. It may read
  source, not edit production, old assertions, fixtures, native tooling or Git.
- [x] New unit tests use real KeyCustodian/DownloadLease processes and private
  supervisors, existing unlock setup and deterministic delegating loader/clock/
  reader barriers. Doubled authorization/reader cases are explicitly unit scope.
- [x] New live cases reuse the actual fixture, retained encrypted Document and
  genuine CustodyReader/authority/storage. Add a fixed export custodian adapter
  at the existing runtime seam; keep AuthorizationDependencies on real custodian.
- [x] Parent executes genuine focused RED with full failure sections, source
  fingerprints and ordinary post0/EMPTY before native edits. Missing API RED
  is expected, not a failed implementation repair. Preserve all failed output.

Representative assertions, implemented with bounded handshake/monitors:

```elixir
# The acquisition process deliberately survives a native public-call timeout.
assert_receive {:loader_blocked, loader, token}, 5_000
assert_receive {:export_result, caller, {:error, %Error{code: :storage_unavailable}}}, 7_000
assert Process.alive?(caller)
send(loader, {:release_loader, token})
# Fence real custodian after release; no private wire/unknown-PID revoke.
assert KeyCustodian.unlocked?(f.custodian, f.session.session_id)
refute_receive {:export_plaintext, _}
```

For init barriers observe only PID/opaque token; monitor before
release and require DOWN autonomously. For post-return/pre-recording death,
the observer blocks after genuine `export_lease/2` returns, root kills its owner,
and native cleanup must work without production recording. For blocked reads,
monitor actual reader, kill/cancel owner, require reader DOWN and no successful
plaintext result before test teardown. Hard lease kill must kill linked reader.
Keep a same-session ordinary sentinel and independent second export live.

## Task C: minimal native implementation and GREEN

Production owner (one Sol worker, edit-only):

```text
apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex
apps/singularity_runtime/lib/singularity/runtime/download_lease.ex
```

- [x] Add internal `DownloadLease.ExportOwnership` helper in its existing source:
  immutable native deadline, atomics pending0/accepted1/cancelled2, terminal cancel,
  CAS expiry, pre/post acceptance time checks. No public request time overrides.
- [x] Add `KeyCustodian.export_lease/2`: allocate before enqueue, remaining native
  timeout, sanitize exits, cancel on all failure paths, accept only successful
  returned lease before deadline; known-PID failed acceptance synchronously
  revokes/awaits termination. Do not lose a cancelled lease if acquisition timer
  already observed accepted. Preserve ordinary `lease/2` byte-identically.
- [x] Add Asset and request-Document export handlers with actual caller from
  `from`, exact old auth/load pipelines, cancellation/liveness checks surrounding
  loader and private ownership option to unchanged lease-supervisor seam.
  Reject other purposes/access/extra fields. Keep registration and errors.
- [x] Install export owner monitor and acquisition timer before init clock/key
  state; validate before/after clock. Pending never performs reads. Timer, owner
  DOWN, revoke, expiry/custodian death perform real cleanup. Accepted keeps60s TTL.
- [x] Export-only guards run before I/O and after blocking work before delivery.
  Retain authority checks and existing key deletion/reader kill+await mechanics.
  Export readers link/monitor to lease under trap_exit so hard death cannot
  orphan them. No change to worker mode or ordinary handlers' behavior.
- [x] Worker closes author window. Parent runs focused GREEN; diagnose ordinary
  failures, preserve assertions and exact raw evidence. Track actual Sol repair
  rounds; escalate after2 failed rounds/evidenced impasse, allow3 Astra attempts
  if recovery is needed. Architecture advisory consumes no repair attempt.

Required matrix covers both source kinds where applicable: surviving-caller
actual timeout with delayed loader; delayed init across timeout; owner death
before usable init; post-return/pre-recording death; owner death/read cleanup;
hard lease death/read cleanup; accepted Document after5s acquisition boundary;
known-PID cancellation and acceptance deadline counterproof; authority/binding/
access rejections; cross-operation/same-session isolation. Await actual5s once
per applicable live case, do not manufacture a shorter production timeout.
Pure ticket boundary/source-structure tests are not live scheduling witnesses.

## Task D: exact inverse source contract

Create only:
`apps/singularity_web/test/singularity/architecture/export_lease_ownership_contract_test.exs`.
Root owns this source-attribution task separately from the native author.

- [x] Before patch, retain original raw source56 hashes, full sources and unchanged
  `Assets.Download`/`ExportRead` pins in ignored immutable baseline evidence.
- [x] On actual GREEN source, inventory every exact old/new hunk, unique two-sided
  contexts and hunk/context SHA256 in a literal reviewed test transition table.
  An insertion uses explicit unchanged surrounding anchors, never a module-wide
  regex. Inverse reconstructs exact old raw source and original pinned hashes.
- [x] Write mutation counterproofs first: missing/reverted/changed hunk, duplicate,
  relocated, either context edge changed, old/new coexistence, extra clauses or
  fields/registration and unrelated legacy mutation must reject. Execute RED
  of the checker/counterproof as appropriate, then implement exact checker and
  rerun whole owner. No replacement of existing architecture source contracts.
- [x] Execute original manifest literally and preserve expected exactly2 raw
  mismatches as such; assert remaining54 raw identical and both inverses exact.
  Verify manifest's own immutable original hash. Do not update/rebaseline it.

This prerequisite does not alter Api/Application, Task8/native-text attribution,
the fixture modules, `Assets.Download` or `ExportRead`. If those unexpectedly
need changes, diagnose first and amend this narrow scope; do not silently extend.

## Task E: complete scoped verification and independent source reviews

Every native command follows this actual argv pattern, with fresh ABS_RAW:

```sh
script --quiet --return --flush --log-out ABS_RAW -- devenv shell -- bash .devenv/phase5-pg-command.sh mix test apps/singularity_runtime/test/singularity/runtime/export_lease_ownership_test.exs apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs --seed 215378 --warnings-as-errors
script --quiet --return --flush --log-out ABS_RAW -- devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs --seed 215378 --warnings-as-errors
script --quiet --return --flush --log-out ABS_RAW -- devenv shell -- bash .devenv/phase5-pg-command.sh mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/export_lease_ownership_contract_test.exs --seed 215378 --warnings-as-errors
```

After EACH invocation, even RED/failure, root runs its own fresh raw:

```sh
script --quiet --return --flush --log-out ABS_POST -- devenv shell -- bash .devenv/phase5-pg-command.sh psql --dbname=postgres --no-psqlrc --tuples-only --no-align --file=.devenv/phase5-task11-residual.sql
```

Require actual natural exit0/bodyEMPTY for post; inspect complete safe raw output.
Do not read the explicitly excluded Task11 static-native raw. Baseline wrapper,
profile, privatePG and toolchain hashes remain attributable; never rewrite old
Task12 guard to accept current changes. Derive a separately named new guard with
explicit reviewed doc/source/test transitions and unchanged historical receipts.

- [x] Complete all five unchanged regression owners on appropriate whole-file
  pure/integration routes; new owner fully executed, not excluded.
- [x] Run both complete existing architecture owners above plus the new owner.
  No weakened old literals.
- [x] `mix format --check-formatted` on every actual changed Elixir file;
  development `mix compile --warnings-as-errors`; `mix xref graph --format cycles`
  must report zero cycles. Same wrapper/raw/post discipline, MIX_ENV=dev only
  for development checks via explicit `env MIX_ENV=dev` after wrapper.
- [x] `git diff --check`, original56 literal/inverse proof and exact source pins.
- [x] Root self-review full source/test owners against design. Actual independent
  SOURCE SPEC closes, then NEW distinct QUALITY reviews all changed owners and
  raw results. Resolve findings and rerun affected gates before commit.
- [x] Small conventional local source/test commits stage exact paths only.
  Verify committed blobs equal qualified/reviewed source. No publication.

## Task F: handoff and continue original Task16

- [x] Record actual commits, files, migrations(NONE), commands, exits, counts,
  complete raw hashes, reviews/findings, repair counters, limitations, frozen54
  and2 inverses, source SHA, no broader Vault work and E2E NOT RUN in a dated
  `docs/verification/2026-10-19-phase-5-export-lease-ownership-handoff.md`.
- [x] Update the two strict original Task16 conditions only to their actual
  qualified extent. Native prerequisite PASS is not artifact/orchestration PASS.
  Preserve all previous failed/BLOCKED_DESIGN snapshots as historical evidence.
- [ ] Fresh independent documentation SPEC then NEW distinct QUALITY, exact
  docs-only commit, separate actual clean closure. Retain original manifests.
- [ ] Resume original Task16 implementation with its companion adapter wired to
  this entry point and all original strict lifecycle tests intact. Then Task17
  real portable composition, Task18 historical upgrade and Task19 complete
  permitted README gates remain. E2E remains NOT RUN, not acceptance success.
