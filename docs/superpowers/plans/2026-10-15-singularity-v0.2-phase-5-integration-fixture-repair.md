# Phase 5 integration fixture repair implementation plan

> Use subagent-driven-development, TDD and verification-before-completion.
> Designs and actual artifacts require independent SPEC then distinct fresh
> QUALITY review. Checked source/verification items below are backed by the
> [Task10 handoff](../../verification/2026-10-15-phase-5-task10-handoff.md); documentation
> handoff closes only after its independent review, local commit and clean check.

Design: `docs/superpowers/specs/2026-10-15-singularity-v0.2-phase-5-integration-fixture-repair-design.md`.
Goal: repair two demonstrated test-fixture contracts and remove one independently
identified redundant fixture snapshot without weakening assertions, database
guards or deadlines. Focused qualification and all15 final permitted README gates
passed. The original V3 timeout cause remains UNKNOWN; nonrecurrence is not a
causal repair. Phase5 remains IN PROGRESS; E2E NOT RUN.

## Recorded execution result

A RED reached the added setup inequality assertion (13registered/1failure/
12excluded); the original migration body/down guard did not run. B RED retained
four setup INVALID cases. C RED proves count-contract failure, not an observed
numeric map. Focused GREEN totals: A45/0, B4/0, C1/0 with38excluded, D16/0.
Final actual8 and final whole28 SPEC→NEWfreshQUALITY are CLOSED PASS. All15 final
permitted README gates passed on the unchanged implementation; five local code
commits end at `d1a8d4f73c570daa7177468b246a25819a2cdd39`. Old FAIL records and
before-images remain immutable. The handoff records exact commands and hashes.

## 1. Qualify the plan and immutable starting evidence

- [x] Read the current worktree instructions and full failing integration raw;
  retain its CLOSED2/14FAIL/4INVALID classification and failure closure.
- [x] Finish independent design SPEC, then a distinct fresh design QUALITY review.
  Correct findings before implementation; continuous authorization replaces
  routine approval, not these reviews.
- [x] Retain all authorized files as immutable before-images. Verify original
  source277/27, exact HEAD/index, pinned profile/privatePG and no owned VM/logger.
- [x] Review successor-guard construction: historical manifest files are immutable;
  unchanged entries remain exact, changed entries use reviewed before/after
  mapping. New file entries must not mask older source inputs or released DDL.
- [x] Write exact focused argv/logger descriptors with fresh raw paths and fixed
  seed988075. Keep default concurrency and default test/checkout limits. Validate
  expected arities, no appended filters/prewarm/runtime options and raw absence.

## 2. Establish deterministic RED on the old behavior

A ownership:
`apps/singularity_storage/test/singularity/storage/wake_generation_migration_test.exs`.

- [x] Add baseline database capture and inequality assertion only, after registered
  old cleanup and before Runtime stop/down. Preserve original fixture behavior.
- [x] Parent runs the existing schema-default test by its exact selected line:
  `devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/wake_generation_migration_test.exs:LINE --seed 988075`.
  Substitute and seal the actual line before Native. Expect the new equality
  failure, not a timeout, compilation failure or unrelated downgrade refusal.
- [x] Natural closure, full raw EOF, post-guard and ordinary residual query EMPTY.

B ownership:
`apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs`.

- [x] Add512-row resource-insert transaction budget to canonical_fixture! while
  retaining the old8192 insert and existing assertions.
- [x] Parent runs:
  `devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs --seed 988075`.
  Expect the explicit8192-versus512 setup assertion and four INVALID tests.
- [x] Natural closure, complete raw EOF, unchanged assertions/pins/source except
  reviewed RED contracts, ordinary residual query EMPTY. Neither RED is a GREEN.

## 3. Implement A after its confirmed RED

A additional files:
`apps/singularity_storage/test/support/fixtures.ex`,
`apps/singularity_storage/test/support/knowledge_fixture_resource_owner.ex`,
`apps/singularity_storage/test/support/migration_test_environment.ex`,
and
`apps/singularity_storage/test/singularity/storage/backup/knowledge_fixture_lifecycle_test.exs`.

- [x] Add explicit optional migration-pool2 acquisition; keep every default caller,
  snapshot and cleanup invariant unchanged.
- [x] Add explicit expected-PID borrowed seed paths for two_vaults!/outbox_event!;
  reuse their existing SQL/transaction bodies. Reject stale/wrong PID and never
  stop a borrowed repo. Original arities remain exact lifecycle equivalents.
- [x] Open owned database before seeds; assert different database/pool2/PID, keep
  existing guarded downgrade and all13 test bodies. Remove only now-orphaned
  manual cleanup/restoration; resource owner owns acknowledged release.
- [x] Add baseline pending sentinel preservation and pool/PID/config regressions;
  retain existing caller-death/exception/normal-release assertions and deadlines.
- [x] Register exact-ID/captured-baseline sentinel cleanup before insertion; run
  it only after destination-owner cleanup acknowledgement and verified baseline
  identity. Restore any test Runtime pause. Prove normal/exception/killed-caller
  cleanup ordering, sentinel removal and unrelated pending-row preservation.
- [x] Parent runs all Wake tests and lifecycle contracts through the exact
  integration wrapper, selected files only and --seed988075. Require every
  original assertion plus new contracts PASS; classify any failure honestly.

## 4. Implement B after its confirmed RED

- [x] Use512-row ordinal batches. All three canonical inserts share each
  transaction and assert exact batch counts; resource insert also retains budget.
- [x] Restrict dependent inserts to current IDs. Verify committed typed heads,
  identity joins, deterministic content/timestamps and empty seals per batch.
- [x] Assert final8192 canonical records/seals. Leave projection loop, GIN
  maintenance/ANALYZE and all four original plan/deadline assertions unchanged.
- [x] Parent runs the same complete search-plan test file, --seed988075, unchanged
 15s checkout/60s test deadlines/default concurrency. Require all four tests PASS.

## 5. Establish candidate C RED, then qualify the restricted lookup

C ownership:
`apps/singularity_storage/test/support/knowledge_backup_fixtures.ex`,
`apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs`.

- [x] Add privacy-safe per-caller canonical query counts around both existing
  verified_bundle modes. Retain the expected1 read/table and2 asset reads. The
  old implementation failed this count contract; RED printed no numeric map.
  No production/helper source edit preceded RED.
- [x] Register exact-handler on_exit fallback before attachment, alongside normal
  after detach/state restore. Test normal/exception cleanup and a monitored killed
  actor using the exact registered fallback; assert absence and idempotence without
  touching other handlers or retaining query/content data.
- [x] Parent runs the fixture authentication test at its actual sealed line,
  using the same integration wrapper and --seed988075; retain full intended RED.
- [x] Restrict only bundle's original-metadata lookup to canonical asset projection.
  Keep both full logical snapshots/oracles and all production integrity passes.
- [x] Add authenticated lookup_digest malformation regression; prove exactly one
  changed logical field, identical original ciphertext records, unchanged source.
- [x] Parent runs the full owning fixture test file and unchanged large-record
  import test at its actual selected line, --seed988075, original60s/default96.
  Require every original/new assertion PASS. The combined C selector actually
  ran only the large test (1/0,38excluded); supplemental whole-owner D ran all16
  fixture tests (16/0). Do not credit C's excluded cases. A residual timeout is
  FAIL, not a reason to relax deadline, data, durability or setup placement.

## 6. Review, requalify and hand off

- [x] Format/check changed Elixir files through reviewed parent Native route.
- [x] Verify complete patch and inverse against before-images; no production,
  released migration, Vault, custody, capability, lease, defaultV2 or deadline edits.
- [x] Actual implementation SPEC review first; then a newly assigned distinct
  fresh QUALITY reviewer reads actual changed artifacts and full raw results.
- [x] Complete bounded read-only V3 timeout diagnosis and risk disposition before
  qualification; the cause remains UNKNOWN. Focused C passed at its unchanged60s
  limit and the final ordinary full gate passed. No causal-fix claim, timeout
  increase or ordinary rerun substituted for diagnosis.
- [x] On the final changed source execute the complete permitted README gate:
  roles, deps, unused, format, compile, ordinary NO-ARGS unit, ordinary integration,
  restore oracle, JS/assets, xref zero cycles, actionlint. Use a new reviewed
  source-qualified generation of the established exact commands and raw paths.
- [x] Synchronize Phase5 design/plan/acceptance report with commands, counts,
  hashes, risks, scopes and counters. After final full-source SPEC→NEWfreshQUALITY
  PASS, five bounded local code commits preserve all28 qualified identities.
  Documentation review, its local commit and literal clean status are separate
  handoff closure conditions recorded in the Task10 handoff, not already-run
  verification. Phase5 remains unaccepted.
- [x] E2E NOT RUN; Task16 ALL-leases remains UNSATISFIED/UNWAIVED. No merge/push,
  version/tag/release/deploy or production activation.

During any Native or maintenance LIVE interval only exact-session polling and
commentary are permitted. Never edit/read/inspect another process or overlap
agents/SQL/checks. All commands must close naturally and complete raw1EOF be read.
