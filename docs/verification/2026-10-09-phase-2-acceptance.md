# Phase 2 exact-source acceptance handoff

## Current status

**Qualified local Phase 2 implementation acceptance: PASS, 2026-10-09.**
Tested source: `c34935a112a2b4b807ed741e8e67e44d4e63eafe`.
Implementation branch: `codex/v0.2-phase-2-import-extraction`.
The clean `codex/v0.2-phase-2-verification` worktree ran the same committed source.
Complete ordered README run `51109` exited 0, including manual E2E, zero xref
cycles, all five workflow lint checks, and its final clean-tree assertion.
Owned-resource cleanup audit `96165` also exited 0.

Complete ordered README attempt `49398` exited 1 at manual E2E: nine browser
cases passed; the Notes accessibility case failed in secondary-owner unlock
setup before reaching its accessibility assertions. A controlled probe confirmed
a matching initial-LiveView-mount readiness race on unchanged login code and
locked dependencies. The original failed run lacked a temporal trace; its exact
interleaving remains an inference. The unchanged owning browser case then passed
(`66877`); the race remains unresolved. Rerun `51109` passed after ordinary test
compilation was refreshed (`19617`, exit 0). This is local Phase 2 acceptance
with that explicit residual risk, not a fix for the race or whole-product
production acceptance. The failed gate is not relabeled as passing.

The [qualification matrix](2026-10-09-phase-2-task-15-matrix.md) contains
chronological RED, repair, scoped PASS, and previous incomplete-gate evidence.
Older NOT RUN and pending entries there describe those earlier attempts; they
are not independent open work once a later result explicitly resolves them.

## Acceptance boundary

This closes only the approved Phase 2 import/extraction implementation and
Task 15 qualification. It does not complete the `0.2.0` product release.
Production activation, Phase 3 search, Phase 4 Note source integration, V3 backup,
later browser features, publication and deployment remain outside this handoff.

The original five Task 15 qualification gaps have source-reviewed and executed
closures in the matrix: live import, recovery/scanner isolation, backup inventory
and snapshot isolation, inclusive extraction limits, and real extraction/process
cleanup/privacy. No required assertion was weakened, skipped, or reclassified.

## Current repair and verification

- `8612885341bdc134ca2519f036e77a61ea5af48f`: reconciles existing web-only
  Document SELECT contracts, preserves temporary-grant cleanup, and supplies
  narrowly scoped established authorization prerequisites to legacy fixtures.
  It changes no production migration or grant.
- `c34935a112a2b4b807ed741e8e67e44d4e63eafe`: two-line compile-preserving compatibility patch
  in `apps/singularity_runtime/lib/mix/tasks/singularity.test.browser_restore.ex`.
  The already compiled browser restore child loads `app.config --no-compile`,
  retaining configuration validation, role verification, and every secret/output
  contract. This is the explicit minimal restore-harness compatibility touch
  required by Phase 2's new native compiler, not Vault feature work.
- The verification checkout's absent local dependency search path was restored
  through an ignored `deps/` directory linking the locked shared packages.
  Application configuration and dependency versions were not changed.
- Fresh independent SPEC and QUALITY reviews passed the compatibility diff.
  Formatter and all 42 owning browser-task tests passed.
- Focused real-child checks retained exact silent cleanup on matched browser
  configuration and fail-closed rejection on mismatched compilation settings.
- All five owning Notes browser cases passed in session `63213` (43.2 seconds),
  including conflict, backup restore, owner isolation, and terminal purge.
- The final-source local container and executable parity checks passed. Complete
  run `51109` passed all 1,281 unit/property cases, all 875 PostgreSQL integration
  cases, V1/V2 restore, 197 JavaScript tests, all ten manual browser tests, locked
  dependencies, asset build, formatting, lint, and zero xref cycles.

## Complete README gate

Commands run from the clean verification checkout, in one Bash wrapper with
owned-service identity checks and EXIT/INT/TERM cleanup. Mix uses
`MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps`; bundler-relative
`deps` resolves those same packages. Neither database connection nor role
provisioning uses the borrowed original cluster.

```sh
devenv up -d
devenv processes wait --timeout 120
devenv shell -- bash apps/singularity_storage/priv/repo/bootstrap_roles.sh
devenv shell -- mix deps.get
devenv shell -- mix deps.unlock --check-unused
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test
devenv shell -- mix singularity.test.integration
devenv shell -- mix singularity.test.restore
devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
devenv shell -- mix npm.verify
devenv shell -- mix duskmoon_bundler.js.check
devenv shell -- mix npm.run test:js
devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind
devenv shell -- mix npm.run test:e2e
devenv shell -- mix xref graph --format cycles --fail-above 0
nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/e2e.yml .github/workflows/release.yml .github/workflows/docker-image.yml
git diff --check
git status --short
test -z "$(git status --porcelain)"
```

E2E is invoked manually for acceptance. Its workflow remains manual-only;
no automatic trigger was changed during this repair.

### Final results: session 51109, exit 0

Every command above passed in the documented order; none was skipped. No other
Mix, database test, browser run or container build ran concurrently.

| Gate | Result |
| --- | --- |
| Owned service startup, readiness, PostgreSQL identity, role bootstrap | PASS; private verification socket and PGDATA, no TCP listener |
| Hex dependencies and unused-lock check | PASS; lock unchanged |
| Elixir formatting and warnings-as-errors compilation | PASS |
| Unit/property tests, seed `250133` | PASS; 1,281 executed, including ten properties |
| PostgreSQL integration, seed `34544` | PASS; 875 executed: Storage 670 (559.2 s), Runtime 205 (797.2 s) |
| V1/V2 restore oracles | PASS; maintenance-mode and empty-destination checks, both restores completed |
| Frozen npm install and verification | PASS; 166 locked packages |
| JavaScript format/lint | PASS; all 22 files |
| JavaScript tests | PASS; 197 tests in nine files, 6.37 s total |
| Digested assets and Tailwind build | PASS |
| Manual Playwright | PASS; ten tests, 1.6 minutes, no retry flag added |
| Seven-application xref graph | PASS; zero cycles |
| actionlint | PASS; CI, Test, E2E, Release, Docker Image workflows |
| Whitespace and final Git status | PASS; verification tree clean at the exact tested source |
| Owned-service EXIT cleanup | PASS |

Unit executions by application: Core 123 including ten properties; Domains 38;
Storage 261; Retrieval 26; Ingest 62; Runtime 588; Web 183. The integration pass
excluded those unit cases and ran 670 Storage plus 205 Runtime cases. Excluded
tests are not counted as executed. Browser checks cover existing Notes/Asset
workflows, not a later-phase Document UI.

Non-fatal output remains recorded: test-module/migration redefinition warnings,
deliberate constraint/connection failures from negative contracts, migration
fixture replay notices, the devenv binary/lock version notice, Vite's future
native-config compatibility warning, and Node color-environment notices.
Warnings were not suppressed and assertions were not changed.

### Earlier failed attempts and diagnosis

A prior full-gate attempt `67458` stopped before unit execution because the
preceding browser harness had compiled the test endpoint with
`code_reloader: false`, while ordinary test configuration requires `true`.
Ordinary test compilation was refreshed with
`devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix compile --force --warnings-as-errors`
(`78049`, exit 0), then the entire sequence restarted. Compile-environment
validation was not disabled.

Attempt `36773` then stopped at one unchanged filesystem-concurrency test's
five-second task timeout (unit seed `857108`), while the image build was active.
Docker I/O is a plausible contributor, not a proven cause. The entire unchanged
owning file passed afterward (`73690`, same seed, 24 tests, zero failures,
4.1 seconds); the complete gate restarted as `49398` without concurrent image
building. The timeout and all assertions remain unchanged; no prior failed gate
is relabeled as passing.

Attempt `49398` passed unit seed `51150` and integration seed `392145`.
Storage executed 670 integration tests in 657.9 seconds; Runtime executed 205
in 816.6 seconds, all without failures. The manual E2E stage then exited 1:
9 passed, 1 failed (1.3 minutes). `notes_accessibility.spec.ts:192` called
`unlockSecondary`; `support/fixtures.ts:119` could not find the `Unlock vault`
heading within the unchanged 5,000 ms assertion deadline. This is a setup
failure, not a demonstrated accessibility finding. All other browser cases,
including real Notes backup restore, passed. Final xref, workflow lint and
clean-tree checks were NOT RUN by this failed wrapper; owned services were
stopped by its EXIT trap. Astra's controlled probe `71213` held the initial
LiveView reply until both login fields were filled, then observed the reply
clear the unfocused login, native validation reject submission, and the same
unlock-heading failure. An unchanged owning-file repeat `66877` passed in
28.2 seconds (40.3 total). The temporary probe was removed; no production code,
required assertion, timeout, or retry policy changed. The matrix preserves the
failed run and sanitized diagnostic evidence. A later full PASS proves that
run's result, not a fix for the readiness race.

### Final cleanup audit

Audit `96165` re-established the exact owned PostgreSQL identity, found no
remaining generated `singularity_test_%` databases, and verified absence of
these exact integration/restore storage roots:

```text
/tmp/singularity/integration/2b87619b9853022cce2a0220
/tmp/singularity/integration/2aba68be4d3ef4f7aa3b1829
/tmp/singularity/integration/e7e0cffcb0c365f3dda938f0
/tmp/singularity/integration/2cfa644e757f31f43fe0c1ce
```

The browser server's verified checkout and public run ID
`9336895c-f100-44c1-a51e-b352e112595c` bound cleanup to
`/tmp/singularity/browser/70500452ee79d8591fb364e9` and its corresponding
`/tmp/singularity/playwright/9336895c-f100-44c1-a51e-b352e112595c.json` state file;
both were absent. The audit exited 0 and stopped only its owned service.
Failure artifacts and the unpublished local images are retained; no existing
user database or storage root was deleted by this final cleanup.

Post-audit check `0bde38` exited 0: the owned manager/socket, process/postmaster
files and PostgreSQL socket were absent, and port 4002 had no listener. The
borrowed original PostgreSQL socket still accepted connections; root main was
clean and unchanged.

## Container evidence

Final-source image build `68624` passed for
`singularity:phase2-acceptance-c34935a112a2`, with exact
`REVISION=c34935a112a2b4b807ed741e8e67e44d4e63eafe` and metadata-only
`VERSION=local-phase2-verification`. No application version bump or publication
is implied. Immutable image ID:
`sha256:55d81ccf0c8918cd8268f134e61d5b077526f20621f6d537400a6cd2d6e9c72e`.
Inspection confirmed the matching OCI revision, amd64 architecture, nonroot
`10001:10001` user and `/app/bin/singularity` entrypoint. Smoke `8985` addressed
that ID with a read-only root filesystem and no network: release executable,
native guardian, digested assets and absent COOKIE checks passed, and both
`pdfinfo -v` and `pdftotext -v` reported **25.03.0**, exit 0. The temporary
container was removed; the unpublished local image remains. This is packaging
and executable parity, not a running application or deployment claim.

Only local amd64 packaging is being qualified. No arm64 runtime, GHCR manifest,
hosted workflow, app deployment, production data migration, or production
Document-write activation is claimed.

Host executable check `c6e612` exited 0:

```sh
devenv shell -- bash -ec 'command -v pdfinfo && command -v pdftotext && pdfinfo -v && pdftotext -v'
```

Both resolved beneath the same Nix `poppler-utils-26.06.0` store path and reported
**26.06.0**. Host fixture verification therefore used a different Poppler version
from the image's **25.03.0**. Task 6 packaging qualification establishes executable
availability and successful source/image construction, not identical Poppler
versions or a full in-container PDF-fixture run. That version difference remains
a deployment qualification limit. Final immutable-image inspection `dd2a2f`
reconfirmed the image ID, exact source revision, amd64 and nonroot user.

## Source inventories

Phase 1 accepted baseline: `a80957da41582de40bdf586a0cba1e14644acf0a`.
The exact candidate comparison contains 165 changed files
and 91 commits, including separately approved CI/container
work already on main. The current continuation from unchanged local main
`e866990fc0ee8682d139d70da9cbf5aff9b2ae2b` contains 85 changed files
and 43 commits. Inventories below are generated from
Git at these fixed endpoints, not from the dirty documentation working tree.

### New forward migrations

All migration changes against Phase 1 are additions; no released migration was
modified in this range.

```text
A	apps/singularity_storage/priv/repo/migrations/20260922000000_backup_unsupported_guard.exs
A	apps/singularity_storage/priv/repo/migrations/20260922000050_document_source_pin_count.exs
A	apps/singularity_storage/priv/repo/migrations/20260922000100_document_extraction_attempts.exs
A	apps/singularity_storage/priv/repo/migrations/20260922000110_document_terminal_tombstone.exs
A	apps/singularity_storage/priv/repo/migrations/20260922000200_document_extraction_recovery.exs
A	apps/singularity_storage/priv/repo/migrations/20260922000250_document_custody_binding.exs
A	apps/singularity_storage/priv/repo/migrations/20260922000300_document_runtime_mutations.exs
A	apps/singularity_storage/priv/repo/migrations/20261008000000_document_worker_bridge.exs
```

### Changed files against Phase 1

```text
.github/workflows/docker-image.yml
.github/workflows/e2e.yml
.github/workflows/release.yml
.github/workflows/test.yml
AGENTS.md
Dockerfile
README.md
apps/singularity_core/lib/singularity/core/document_fragmentation.ex
apps/singularity_core/lib/singularity/core/document_version.ex
apps/singularity_core/lib/singularity/core/error.ex
apps/singularity_core/test/singularity/core/document_fragmentation_test.exs
apps/singularity_core/test/singularity/core/document_values_test.exs
apps/singularity_core/test/singularity/core/error_test.exs
apps/singularity_domains/lib/singularity/domains/documents.ex
apps/singularity_domains/lib/singularity/domains/documents/repository.ex
apps/singularity_domains/test/singularity/domains/documents_test.exs
apps/singularity_domains/test/singularity/domains/knowledge_ports_test.exs
apps/singularity_ingest/Makefile
apps/singularity_ingest/c_src/poppler_guardian.c
apps/singularity_ingest/lib/singularity/ingest/documents/markdown.ex
apps/singularity_ingest/lib/singularity/ingest/documents/pdf.ex
apps/singularity_ingest/lib/singularity/ingest/documents/poppler.ex
apps/singularity_ingest/lib/singularity/ingest/documents/text.ex
apps/singularity_ingest/mix.exs
apps/singularity_ingest/test/fixtures/documents/empty.pdf
apps/singularity_ingest/test/fixtures/documents/encrypted.pdf
apps/singularity_ingest/test/fixtures/documents/encrypted_pdf20_xref_stream.pdf
apps/singularity_ingest/test/fixtures/documents/malformed.pdf
apps/singularity_ingest/test/fixtures/documents/scanned_image_only.pdf
apps/singularity_ingest/test/fixtures/documents/two_pages.pdf
apps/singularity_ingest/test/singularity/ingest/documents/markdown_test.exs
apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs
apps/singularity_ingest/test/singularity/ingest/documents/poppler_lifecycle_test.exs
apps/singularity_ingest/test/singularity/ingest/documents/text_test.exs
apps/singularity_runtime/lib/mix/tasks/singularity.test.browser_restore.ex
apps/singularity_runtime/lib/singularity/runtime/api.ex
apps/singularity_runtime/lib/singularity/runtime/application.ex
apps/singularity_runtime/lib/singularity/runtime/backup_vault.ex
apps/singularity_runtime/lib/singularity/runtime/documents/extract.ex
apps/singularity_runtime/lib/singularity/runtime/documents/extraction_reconciler.ex
apps/singularity_runtime/lib/singularity/runtime/documents/import.ex
apps/singularity_runtime/lib/singularity/runtime/documents/mutate.ex
apps/singularity_runtime/lib/singularity/runtime/documents/read.ex
apps/singularity_runtime/lib/singularity/runtime/download_lease.ex
apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex
apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex
apps/singularity_runtime/lib/singularity/runtime/key_lease.ex
apps/singularity_runtime/lib/singularity/runtime/observability/telemetry.ex
apps/singularity_runtime/lib/singularity/runtime/outbox_dispatcher.ex
apps/singularity_runtime/test/singularity/runtime/application_test.exs
apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs
apps/singularity_runtime/test/singularity/runtime/document_api_test.exs
apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs
apps/singularity_runtime/test/singularity/runtime/document_extraction_job_test.exs
apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs
apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs
apps/singularity_runtime/test/singularity/runtime/document_import_live_test.exs
apps/singularity_runtime/test/singularity/runtime/document_import_test.exs
apps/singularity_runtime/test/singularity/runtime/download_lease_test.exs
apps/singularity_runtime/test/singularity/runtime/generic_worker_telemetry_test.exs
apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs
apps/singularity_storage/lib/singularity/storage/backup/exporter.ex
apps/singularity_storage/lib/singularity/storage/jobs/envelope_codec.ex
apps/singularity_storage/lib/singularity/storage/jobs/oban_adapter.ex
apps/singularity_storage/lib/singularity/storage/jobs/worker_scope.ex
apps/singularity_storage/lib/singularity/storage/postgres/asset_deletion_repository.ex
apps/singularity_storage/lib/singularity/storage/postgres/custody_repository.ex
apps/singularity_storage/lib/singularity/storage/postgres/document_pinned_source.ex
apps/singularity_storage/lib/singularity/storage/postgres/document_repository.ex
apps/singularity_storage/lib/singularity/storage/postgres/document_worker_repository.ex
apps/singularity_storage/lib/singularity/storage/schema/content/document_version.ex
apps/singularity_storage/priv/repo/migrations/20260922000000_backup_unsupported_guard.exs
apps/singularity_storage/priv/repo/migrations/20260922000050_document_source_pin_count.exs
apps/singularity_storage/priv/repo/migrations/20260922000100_document_extraction_attempts.exs
apps/singularity_storage/priv/repo/migrations/20260922000110_document_terminal_tombstone.exs
apps/singularity_storage/priv/repo/migrations/20260922000200_document_extraction_recovery.exs
apps/singularity_storage/priv/repo/migrations/20260922000250_document_custody_binding.exs
apps/singularity_storage/priv/repo/migrations/20260922000300_document_runtime_mutations.exs
apps/singularity_storage/priv/repo/migrations/20261008000000_document_worker_bridge.exs
apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs
apps/singularity_storage/test/singularity/storage/backup_concurrency_test.exs
apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs
apps/singularity_storage/test/singularity/storage/document_schema_test.exs
apps/singularity_storage/test/singularity/storage/document_worker_scope_test.exs
apps/singularity_storage/test/singularity/storage/knowledge_concurrency_test.exs
apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs
apps/singularity_storage/test/singularity/storage/knowledge_privacy_test.exs
apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs
apps/singularity_storage/test/singularity/storage/knowledge_schema_test.exs
apps/singularity_storage/test/singularity/storage/object_cleanup_concurrency_test.exs
apps/singularity_storage/test/singularity/storage/orphan_cleanup_test.exs
apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs
apps/singularity_storage/test/singularity/storage/postgres/custody_repository_test.exs
apps/singularity_storage/test/singularity/storage/postgres/document_pinned_source_test.exs
apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs
apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
apps/singularity_storage/test/singularity/storage/roles_test.exs
apps/singularity_storage/test/support/knowledge_fixtures.ex
apps/singularity_storage/test/support/knowledge_test_grants.ex
apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs
apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs
apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs
apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
config/config.exs
devenv.nix
docs/deployment/2026-10-01-docker-verification.md
docs/deployment/2026-10-08-workflow-test-policy-verification.md
docs/deployment/docker.md
docs/guide.md
docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md
docs/superpowers/plans/2026-09-22-singularity-v0.2-phase-2-import-extraction.md
docs/superpowers/plans/2026-10-05-docker-image-workflow.md
docs/superpowers/plans/2026-10-08-singularity-v0.2-document-extraction-runtime-source-integration.md
docs/superpowers/plans/2026-10-08-singularity-v0.2-document-extraction-runtime.md
docs/superpowers/plans/2026-10-08-singularity-v0.2-document-fresh-lease-slice.md
docs/superpowers/plans/2026-10-08-singularity-v0.2-document-progress-slice.md
docs/superpowers/plans/2026-10-08-singularity-v0.2-document-worker-composition-guard.md
docs/superpowers/plans/2026-10-08-singularity-v0.2-phase-2-worker-bridge.md
docs/superpowers/plans/2026-10-08-singularity-v0.2-worker-adapter-slice.md
docs/superpowers/plans/2026-10-08-singularity-v0.2-worker-sql-slice.md
docs/superpowers/plans/2026-10-08-workflow-test-policy.md
docs/superpowers/plans/2026-10-09-singularity-v0.2-backup-qualification.md
docs/superpowers/plans/2026-10-09-singularity-v0.2-document-c3-isolation.md
docs/superpowers/plans/2026-10-09-singularity-v0.2-document-c4-c5-isolation.md
docs/superpowers/plans/2026-10-09-singularity-v0.2-document-supervised-restart.md
docs/superpowers/plans/2026-10-09-singularity-v0.2-document-tool-evidence.md
docs/superpowers/plans/2026-10-09-singularity-v0.2-document-worker-checkout-lifetime.md
docs/superpowers/plans/2026-10-09-singularity-v0.2-empty-original-authentication.md
docs/superpowers/plans/2026-10-09-singularity-v0.2-extraction-limits-qualification.md
docs/superpowers/plans/2026-10-09-singularity-v0.2-generic-worker-telemetry-compatibility.md
docs/superpowers/plans/2026-10-09-singularity-v0.2-live-import-qualification.md
docs/superpowers/plans/2026-10-09-singularity-v0.2-real-extractor-qualification.md
docs/superpowers/plans/2026-10-09-singularity-v0.2-recovery-qualification.md
docs/superpowers/specs/2026-09-22-singularity-v0.2-phase-2-import-extraction-design.md
docs/superpowers/specs/2026-10-04-docker-image-workflow-design.md
docs/superpowers/specs/2026-10-08-singularity-v0.2-document-source-replay-design.md
docs/superpowers/specs/2026-10-08-singularity-v0.2-phase-2-worker-bridge-proposal.md
docs/superpowers/specs/2026-10-08-workflow-test-policy-design.md
docs/superpowers/specs/2026-10-09-singularity-v0.2-backup-qualification-design.md
docs/superpowers/specs/2026-10-09-singularity-v0.2-document-c3-isolation-design.md
docs/superpowers/specs/2026-10-09-singularity-v0.2-document-c4-c5-isolation-design.md
docs/superpowers/specs/2026-10-09-singularity-v0.2-document-supervised-restart-design.md
docs/superpowers/specs/2026-10-09-singularity-v0.2-document-tool-evidence-design.md
docs/superpowers/specs/2026-10-09-singularity-v0.2-document-worker-checkout-lifetime-design.md
docs/superpowers/specs/2026-10-09-singularity-v0.2-empty-original-authentication-design.md
docs/superpowers/specs/2026-10-09-singularity-v0.2-extraction-limits-qualification-design.md
docs/superpowers/specs/2026-10-09-singularity-v0.2-generic-worker-telemetry-compatibility-design.md
docs/superpowers/specs/2026-10-09-singularity-v0.2-live-import-qualification-design.md
docs/superpowers/specs/2026-10-09-singularity-v0.2-real-extractor-qualification-design.md
docs/superpowers/specs/2026-10-09-singularity-v0.2-recovery-qualification-design.md
docs/verification/2026-10-08-document-extraction-runtime.md
docs/verification/2026-10-08-document-fresh-source-lease.md
docs/verification/2026-10-08-document-lifecycle-generation-repair.md
docs/verification/2026-10-08-document-progress.md
docs/verification/2026-10-08-document-runtime-source-integration.md
docs/verification/2026-10-08-document-worker-adapter.md
docs/verification/2026-10-08-document-worker-sql-bridge.md
docs/verification/2026-10-08-notes-scope-contract-alignment.md
docs/verification/2026-10-08-phase-2-contract-alignment.md
docs/verification/2026-10-08-phase-2-worker-baseline.md
docs/verification/2026-10-09-document-runtime-outcomes-integration.md
docs/verification/2026-10-09-document-supervised-restart-qualification.md
docs/verification/2026-10-09-empty-original-authentication.md
docs/verification/2026-10-09-phase-2-task-15-matrix.md
mix.lock
```

### Commits against Phase 1

```text
30ae0b38ad1d2bb5bccfa9816b6bf10c4d492af5 docs(ingest): design phase 2 document import and extraction
9ac2c17152e76774c9a92a36b6a1b095b5ffcfd1 docs(ingest): record phase 2 spec approval
eeb8c3ba646132bd1aa0c06bd1375583fe792abe docs(ingest): permit document-pinned custody lease
222652a3cb21497fa3492b1060683d8c9e1bdddd docs(ingest): plan phase 2 document import and extraction
90d84166ede74c4f8bc3e926fdbf6e4dc6c15ce3 docs(knowledge): activate phase 2 implementation guidance
f74420500185b1643d35131e34a7a9a72a498c83 fix(backup): refuse unsupported canonical document rows
450ec24b332cb36b116f16aaeaa250c76231057e test(storage): cover backup guard privileges
b6dca42cc1d8380ec631938d5b4ebbc300616628 fix(storage): retain document-pinned source objects
d0fbd50af84aa2a5c1a741b19dc20ddc23e6ac0a test(storage): prove both document pin cleanup orders
a7b3fa0a2717edf229de5c9f37bd1e04d353edf1 test(storage): prove import cleanup lock race
d4126922586488c01b5d1cf94ce643f72330d547 feat(storage): fence document extraction attempts
e4d64e2b3ecf57f11479ab24280fb4d23e51d93a fix(storage): finish claimed extraction after tombstone
ce769936da96c6bdc61057ef71e36a5f318a513e fix(storage): distinguish stale document attempt conflicts
8c06e6ccd0c58dbfb812615abe60c256e6595cc8 feat(ingest): fragment text and markdown documents
d27440e26ee5334f3dce5f67636bc52617e7d653 fix(ingest): preserve heading ancestry and allowed limits
b02ff271173828bd1ef47d01ec9a7ab30ba5fbf0 fix(ingest): bound fragmentation and heading locators
f63ccaa6639076bbcdac5fb3802b893fa26d57e3 feat(storage): read document-pinned source objects
87f7cf1f97fa7d2d9a4559da83d7498053c2a2cf fix(storage): fence pinned source to current event
0f041072e51f4a4967069cf0cc8bdabc93ab1893 feat(storage): schedule document extraction atomically
41d09081b977101e2c3d9a7d009311de9023b068 fix(storage): reject revoked document event principal
deeee14a50e4458842889c810a9c4cdf75590f11 feat(runtime): import authenticated documents
b4227140e95b8f1fb08b60bef80c941b0843495d fix(runtime): replay concurrent document imports after source deletion
77a81a359b2580b1df2ab4d1fb61627e4d8306ef feat(runtime): recover abandoned document extraction
d2bc4c94ffd2563d418fe74ae6506e7b22bcfc90 fix(storage): fence recovered document event generation
4e8328d17d7e43abae224e2cd6c0b1ab799d598e docs(phase2): approve bounded extraction and custody bridges
89aaf71b543630cb6fa89053b719afddc7dbd1c6 feat(runtime): lease document-pinned source reads
15a9ebd5dc9e68055010391f9e0094bc1b94789f test(storage): cover document custody lifecycle revocation
8bb7c439e2aa1e3abab748cb357c4f992b0ae6c1 feat(jobs): route document extraction events
41e8eff192516d42506af9695fb7a1c9d4e4503f feat(runtime): add document API mutations
f2a04a7c116c45238706805f29772ca85f96d7ea docs(phase2): approve poppler process guardian
943682aa04f971bb1f9a89baa24357f80b35b8ef docs(phase2): approve poppler control protocol
25ce650c82b73cba10ce6dfc047205e9511f8fa3 feat(ingest): add bounded poppler document extraction
397a7f0bb7039d3f71b6a0d73c340e8aec0d949a docs(phase2): approve bounded pdfinfo diagnostics
c7437ee2b8b553518e5ad6a79ffbc2e5085fbc6c docs(phase2): pin pdfinfo password exit status
96d6282098dbf98d0acc35fcf575ab51a3004482 fix(ingest): classify bounded poppler diagnostics
56e966e1fb7a62fd2593b857facef9672ee4b78e fix(storage): validate document-pinned source readers
6cf9744bbcf75e6fa9ce93775c52a94c11169fe2 chore(docker): verify release packaging and document deployment
00f391dc0baf128ff26668b6d10cdaea3e3604ff docs(ci): design manual and release-triggered Docker images
89251e0b10ad8dd6fb163931965549193966da48 docs(ci): plan verified Docker image workflow
c19c246a97f6a5980d7d4f2f20c8bb14b7d7619a ci(docker): add verified manual and release image publishing
253fcbba28e1596e04b94ae997ba19613a0e0a4f docs(docker): document image workflow and extend lint gate
f9ea06251d4b149b371e468609934b243afd1468 docs(ci): record Docker image workflow verification
a461b0e1c2d4eb9b32d4b0dc4efb20ff52425ec0 docs(ci): define manual acceptance and exact release image tags
bca424be8f52cc96e0cca1004e764403be06a8df docs(ci): plan workflow test policy implementation
ac4497ef733be18f2ac985ab188af64c7b98e90b ci(github): update github actions workflows
80cabbee8735158372ae3b4ac8f09a9cf400ad0d docs(ci): record workflow test policy verification
6f4083048748901d8f1b536edd8a930b1668164d test(knowledge): align approved phase 2 contracts
e866990fc0ee8682d139d70da9cbf5aff9b2ae2b docs(knowledge): record phase 2 contract verification
e6397e7e940a9ff6bf6b96764dafd010059fc6a3 docs(knowledge): propose phase 2 worker bridge
cbdd9098875ea2b3fcaf11c7914d4641da92ac98 test(knowledge): align remaining notes scope contract
9cf809b86ca9b12e169ca698a69fc7467bdb07ca docs(knowledge): record worker integration baseline
2b037f10d78b5227242acc6f15cd7351de1b3dca docs(knowledge): record worker bridge approval
9c82cfd4cf11f5a330ee8971ce8dea3a36f33fb7 docs(knowledge): record post-approval contract check
568ff38d2a423e1e040d099486df817c13f5ae47 docs(knowledge): define restart-safe document source reads
cf87c7ed79c2cc52c2727a1cfcfc3fe0d9a1e9e8 test(storage): align document reset generation contract
80bbcd538586bca6f1c38569e357e77f8ac361c3 docs(knowledge): record lifecycle baseline repair
b8db6d562d072c2de5dc77635d29159080d1401a feat(storage): add fenced document worker SQL bridge
78a8634527059b79014247b7bcf11567006cf4a7 docs(knowledge): record worker SQL bridge acceptance
0cc65c0cfa6c98144c0842ac01c8326248fa6674 feat(storage): add typed document worker adapter
bde0101e8883636e9beac545b9038d3c56d01b1f docs(knowledge): record worker adapter acceptance
03a1bc20ffc4bac36b92c6a1df6f9a1b4436b10d feat(runtime): add fresh document source leases
5f2b4cfba610069ffaaec3aaddb068cf2a650340 docs: record fresh document lease verification
ebb1f7c6e67686d78c79f9125a44814dda69c06e feat(storage): preserve document checkpoints in progress updates
5cf98c61172fba497bde1df2b4f81fa31c492011 docs: record document progress verification
d5ea128f3423e54df2381d78b941cafff291a62a feat(runtime): compose fenced document extraction jobs
e39bba9f93d183e76a1eee56d5734d5dbdebce71 docs: record document runtime composition verification
5be1e515ef9315933aed4bd7c65dc2b6abc4ed23 test(runtime): qualify document source acquisition and restart
33e9bdae575f531f8f907a3a4157bf314feb99a8 docs: record document source integration verification
4f9f316c6af4eaaca54ff6f82b1817342e21d1ae docs: record outcome integration prerequisite evidence
273322d7c74459e449b80001575084c6f46eebe9 docs: define bounded document worker checkout repair
ecb170349ae3ca021e8fe0ca194d4a9b73dfa738 fix(storage): bound document checkout and preserve short SQL limits
caf80fd4a1e71bc8b4253fbd058980c0be4a8275 docs: record verified document checkout repair
027b28bc1ca8a635a43fe37b3cceb76d811233cf fix(runtime): recognize canonical Oban worker telemetry
138b035e56c2bc7416e6840a0ad2ae2aff798093 test(runtime): qualify document extraction outcomes
26e16a5716dec8c3df835a7ff8e1d258249cde58 test(runtime): qualify supervised document recovery
52d9df11bd943ab7808896be3d0c49e9c7c7808a fix(runtime): authenticate empty document originals
7de5636928efee90948bbd7371f4938e10b388e7 docs(runtime): plan live document import qualification
125653e9dbb6d979703360138abf55fb888f2711 test(runtime): qualify live document import composition
326a7868538c584889182af54ad8ced5fe5ce8df docs(runtime): plan recovery security qualification
dfe60aa11ac471da243e0523a33a23b0bf426276 test(runtime): qualify extraction recovery security
a6960b6ab279e03c406fc3a9d7717f8a7cad8ad4 docs(backup): plan inventory and snapshot qualification
6fea564bc4868bb7cfe39094d3944f8aae67056f test(backup): authorize document refusal fixture
c7efaec657c1f3d18fad16bed39ea6ae0e85a083 test(backup): qualify inventory and snapshot isolation
f0735345e379f3dc1ec7f3ac16dd0e70f0d944e0 docs(ingest): plan inclusive extraction limit qualification
d39ad93f257df3a6e01a87a420c7a034c888192b test(ingest): qualify inclusive extraction limits
3f7ab99b863b7e7345a68c024a9dbf8fa3b8813e test(ingest): qualify real extractor lifecycle and privacy
5a41faa6bf1d410bbfe72b5e585f39704674b2fc style(runtime): format extraction outcome contracts
2335bf3b5f8f4af4dd62bd7c32ec2ccdf553cb44 test(runtime): synchronize document reader observation
0808d677af413e26169fbb1afe4cd204cc16f7fa docs(verification): record phase two integration blockers
8612885341bdc134ca2519f036e77a61ea5af48f test(storage): reconcile document read and fixture contracts
c34935a112a2b4b807ed741e8e67e44d4e63eafe fix(test): preserve browser restore output protocol
```

## Preserved state and residual limits

Root main is unchanged at `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`. This acceptance
run performed no main merge, push, tag, GitHub release, GHCR publication or
deployment. Seven application boundaries and zero xref cycles were verified.

No Vault feature work occurred. Approved Document-specific custody composition
retains existing key/capability semantics; the bounded restore-harness
compile-compatibility touch is identified above. V1/V2 restore checks are not
V3 support; the unsupported-canonical-row backup guard remains fail closed.

The original untracked
`docs/superpowers/plans/2026-10-09-singularity-v0.2-document-extraction-runtime-outcomes-integration.md`
is excluded from staging and retains SHA-256
`350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.
Owned verification databases, exact storage roots, browser state and service
cleanup passed the final audit. The borrowed original runtime was not owned by
this wrapper. Earlier mis-bound role-provisioner diagnosis is recorded explicitly
in the chronological matrix; this is not a claim that the entire repair history
never contacted the borrowed cluster.

The existing sign-in readiness race remains unresolved outside this Phase 2
Document implementation. It was reproduced on the current source with unchanged
relevant Phase 1 code and lock entries, not by executing the historic Phase 1
runtime. Local passing acceptance does not establish that race is fixed or
constitute production-readiness acceptance for the whole product.
