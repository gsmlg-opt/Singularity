# Task 13 SQL Fixture Storage Reference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans; parent controls all gates and source serialization.

**Goal:** Construct a valid exact stored-reference fixture without weakening capture validation.

**Architecture:** Add one exact owner-fixture UPDATE/RETURNING assertion to the new shared fixture; unchanged real request capture reads and preserves that actual value.

**Tech Stack:** Elixir/ExUnit, PostgreSQL17, existing DataCase/owner fixture and devenv.

Design: `docs/superpowers/specs/2026-10-12-singularity-v0.2-phase-5-snapshot-fixture-storage-reference-design.md`.

## A. Source review before the sole edit

- [x] Actual nonauthor SOURCE SPEC reads new fixture, unchanged KnowledgeFixtures
  source/preparation, exact Spool reference predicate and RepositoryTest's real
  persisted-value equality. Verify this is setup only and capture cannot
  normalize a bad reference. Obtain distinct fresh actual-source QUALITY.
- [x] Record both reviews and exact reviewed document hashes. This does not
  accept Task13 or authorize production edits.

## B. Sole setup correction

**Modify:** `apps/singularity_runtime/test/support/knowledge_export_snapshot_fixture.ex`.
**Unchanged:** all other source/test/support files, established KnowledgeFixtures,
released migrations and frozen56.

- [x] Archive/read the whole original helper and its SHA90d71d43. Parent applies
  exactly the UPDATE/RETURNING and equality assertion shown in the design
  inside the existing owner-only block before the token update.
- [x] Read the complete changed source. Remove only that added block in memory
  and verify reconstructed bytes equal the entire original helper. Do not edit
  identity observers, the barrier, five-second timeout, setup authority or tests.
- [x] Wait for Repository author closure, format only authorized changed/new
  Task13 files, preserve the old receipt, and write a new complete source receipt
  including actual Repository if present. Freeze all source/support for gates.

## C. Complete validation

- [x] Run this whole five-file pure command; require normal exit0, all114 actual
  pure tests passing with zero warnings and unchanged exclusion semantics:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/knowledge_export/spool_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_core/test/singularity/core/knowledge_export_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs --seed 215378 --warnings-as-errors
```

- [x] Run both complete SQL files; require genuine persisted reference equality,
  real authorization/denial/audit witnesses, cleanup and exact closure contracts:

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_export/repository_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs --seed 215378 --warnings-as-errors
```

- [x] Archive full output/actual counts/normal exit. Check current source receipt
  and frozen56, exact allocated root removal, and leftover database query:

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh psql --dbname=postgres --no-psqlrc --tuples-only --no-align --command="SELECT datname FROM pg_database WHERE datname LIKE 'singularity_test_%' ORDER BY datname;"
```

- [x] Preserve any failing full gate as FAIL; diagnose/repair under continuous
  authority with separate Sol/Astra round counts. No narrowing, assertion or
  timeout changes. Repository implementation stays independently scoped.
- [x] Fold this factual correction into Task13 final actual independent SOURCE
  SPEC and distinct fresh QUALITY. Do not mark Task13 accepted or commit source
  until complete required gates/reviews pass.

E2E NOT RUN/manual-only. No frozen substrate or publication/production action.
