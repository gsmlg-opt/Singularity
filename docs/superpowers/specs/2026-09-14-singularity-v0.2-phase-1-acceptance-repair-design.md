# Singularity v0.2.0 Phase 1 Acceptance Repair Design

**Date:** 2026-09-14
**Status:** Approved for design capture; implementation requires review of this written specification
**Release phase:** Phase 1 acceptance repair

## Problem

The complete README verification gate fails in
`Singularity.Storage.UploadGrantCsrfMigrationTest`. The test prepares the legacy
upload-grant schema by running every migration newer than
`20260728000100_secure_upload_grant_csrf.exs` downward. Phase 1 added three
intentionally forward-only knowledge migrations, so the rollback sweep now stops
at `20260906000300_create_knowledge_links_and_organization.exs` before it reaches
the upload-grant migration under test.

The failure is deterministic in the focused integration test. It is a test
environment conflict introduced by the later forward-only migrations, not a
failure of the upload-grant migration's behavior.

## Decision

Run the upload-grant migration compatibility test in a fresh isolated database
whose migration ceiling is the migration immediately before
`20260728000100_secure_upload_grant_csrf.exs`.

Inside that isolated database, the test will:

1. create its established owner, Asset, and legacy upload-grant fixtures;
2. apply only `SecureUploadGrantCsrf` directly;
3. retain every existing assertion for fail-closed digest handling;
4. roll back only `SecureUploadGrantCsrf` directly and retain the round-trip
   assertions;
5. reapply only `SecureUploadGrantCsrf`; and
6. let `MigrationTestEnvironment` destroy the isolated database and restore the
   normal repositories.

This follows the existing `MigrationTestEnvironment` pattern used by Phase 1
migration tests. It avoids rolling back unrelated later migrations and makes the
test independent of future forward-only migrations.

## Scope

Allowed implementation changes are limited to:

- `apps/singularity_storage/test/singularity/storage/upload_grant_csrf_migration_test.exs`;
- removal of imports, aliases, or helpers made unused by that test-only change;
- this design document and its detailed implementation plan.

No production module, released migration, database schema, runtime grant,
application behavior, dependency, or workflow may change.

## Vault and compatibility boundary

The test continues to use the established opaque `vault_id` owner encoding
because the legacy upload-grant schema requires it. The repair does not alter any
Vault assertion, capability, key lifecycle, policy, command, telemetry, or UX.
It changes only how the test database reaches the historical migration state.

All existing upload-grant assertions remain mandatory. No test is skipped,
weakened, deleted, or reclassified.

## Alternatives rejected

### Make the Phase 1 migrations reversible

Rejected because the approved Phase 1 migrations are forward-only and released
migrations must not be edited.

### Skip or exclude the legacy test

Rejected because Phase 1 acceptance requires existing Notes and Assets behavior
to remain green, and required assertions may not be weakened.

### Roll back only the target migration in the fully migrated shared database

Rejected because later migrations would remain applied over an older schema
state. An isolated database with an explicit ceiling gives the test the exact
historical state it claims to exercise.

## Verification

Implementation verification must run in this order:

1. the focused upload-grant migration integration test;
2. the complete README verification gate, including restore, frontend, browser,
   architecture, and workflow checks;
3. `git diff --check` and a clean-scope audit proving that only the approved
   files changed.

If the focused test or complete gate fails for another reason, stop and report
the evidence. Phase 1 is accepted only after the complete gate passes.
