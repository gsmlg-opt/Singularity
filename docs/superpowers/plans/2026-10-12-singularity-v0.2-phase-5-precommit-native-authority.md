# Task 13 Precommit Native-Authority Implementation Plan

> For agentic workers: use subagent-driven-development or executing-plans under
> parent-managed ownership. Checkboxes are evidence, not predicted success.

Goal: restore the two genuine owner-precommit content contracts without
changing authority, weakening assertions or adding privileged runtime plumbing.

Design: [bounded native-authority amendment](../specs/2026-10-12-singularity-v0.2-phase-5-precommit-native-authority-design.md).
Status: implemented and source-qualified on current receipt3d7de0cf after
complete pure114/0,SQL48/0,static0 and actual NONAUTHOR SOURCE SPEC followed by
distinct fresh QUALITY PASS. The original SQL43/2 and retained SQL50680 failures
remain historical; no weakening or timeout/selection change. Task13 local commit
closed at09f8ee0c0a69cdd26612e0663a29a9d156c46986 after the separate Legacy
owning70 gate closed normally70/0. No publication or Phase5 acceptance.
Architecture advice is Astra PROJECT_ARCHITECTURE; Astra repair rounds0.

## A. Prerequisites and independent design review

- [x] Parent records original43/12 and repair1 full43/2 FAIL, exact source
  receipts, archive hashes and normal private cleanup. Do not relabel them.
- [x] Parent actual existing-role probe proves SET membership/function ownership,
  native execution and same pinned backend/transaction/GUC/role cleanup.
  A no-row permission query is not live authorization.
- [x] Actual nonauthor SOURCE SPEC reviews full design/plan against released role
  grants/function, real identity/Authorize/ObservedIdentity/ScopedRepo, both
  full owning tests and native-call/restore/cleanup observability.
- [x] Distinct fresh actual-source QUALITY reviews same-connection/RR/role
  restoration/error-preservation boundaries. Resolve blockers, record hashes
  and synchronize master Task13 before test-only implementation GO.
- [x] Parent closes any live gate before authoring; freeze ALL source/test/
  support while verification runs. Task9B complete16-file SQL may proceed
  independently, but no test authoring may overlap it.

## B. Sole NEW test-file correction and stronger witnesses

Owner: Sol, only
`apps/singularity_storage/test/singularity/storage/knowledge_export/repository_test.exs`.
Workers are not alone; preserve Task9B/Task13 and unrelated edits. Parent owns
docs/formatter/Mix/SQL/services/Git. No other file or grant/credential changes.

- [x] Retain all original tests/assertions/timeouts and PrecommitOwnerScope.
  Add fixed test-local native Identity decorator around unchanged ObservedIdentity
  only in the two private runtime copies; initial and lexical Authorize use it.
  Do not replace Authorize, session/requirements, live row or actual custodian.
- [x] Check exact caller/repo/migration login/owner role/RR/off/GUC context.
  Native load executes on SAME repo as existing authorization_definer; preserve
  exact return/exception and restore owner before content. If needed use the
  design's fixed read-only savepoint for aborted native SQL; cleanup failure is
  separate FAIL, never expected integrity_failure.
- [x] Add successful live-native-call and same backend/transaction/role/context
  witnesses for initial authorization, explicit ready-zero repeat and Repository
  capture. No cached auth, fake query/barrier or copied authorization SQL.
- [x] Strengthen unsealed case to exact integrity_failure plus actual unchanged
  sealed-membership read witness. Preserve all ready-zero and deferred-COMMIT
  assertions, source rollback, no private-text leak, sentinel and cleanup.
- [x] Pin existing connection until actual post-closure role/GUC/lock checks,
  then stop only own MigrationRepo supervisor. Preserve ordinary Runtime/web
  tests and all shared fixtures/production/frozen sources.
- [x] Author closes every command, reports narrow diff/raw hash without PASS.
  Parent reads full changed source and reconstructs unaffected original regions,
  formats sole test, records new immutable receipt, freezes all source.

## C. Complete permitted validation and final Task13 handoff

- [x] Parent repeats both unchanged COMPLETE owning selections; report actual
  counts/exclusions, zero warnings, normal exit and full output archives:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/knowledge_export/spool_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_core/test/singularity/core/knowledge_export_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_export/repository_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs --seed 215378 --warnings-as-errors
```

- [x] Require actual native successful rows and owner restoration in BOTH
  malformed precommit cases, existing content witnesses, exact integrity errors,
  native repeated membership call, genuine rollback and same-connection cleanup.
  A permission-only probe/partial selection cannot qualify any of them.
- [x] Check changed-file formatting, compile warnings-as-errors, unchanged
  seven-application graph/zero xref cycles, all frozen56 and source receipts,
  git diff --check, allocated DB/root/role/GUC/lock/operation cleanup.
- [x] Diagnose ordinary failures, preserving full failed gates. Use bounded
  Sol first, Astra after two failed Sol rounds on same defect/evidenced impasse.
  Keep architecture advice and repair counters separate.
- [x] Obtain final actual Task13 NONAUTHOR SOURCE SPEC then distinct fresh
  QUALITY on exact source; record verdict/findings and source receipt.
- [x] Only after all required GREEN/reviews, parent makes bounded local commit
  per masterTask13 and advances next valid task. Task14 still depends on that
  qualification/commit; Phase5 complete permitted README acceptance remains later.

E2E NOT RUN/manual-only. No skipped/weak assertion, production change, Vault
feature work, merge/push/version/tag/release/deploy/activation/backfill/data.
