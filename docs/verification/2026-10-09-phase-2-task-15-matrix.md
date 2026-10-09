# Phase 2 Task 15 qualification matrix

## Status and scope

Task 15 is open. This record is not Phase 2 acceptance, a complete README
verification gate, or publication evidence. Source baseline is
`52d9df11bd943ab7808896be3d0c49e9c7c7808a` on
`codex/v0.2-phase-2-import-extraction` in the existing project-local worktree.
E2E remains NOT RUN under the user's explicit exclusion; the required full
Phase 2 gate cannot be marked accepted without it.

No production activation, Vault feature change, new migration, backup V3,
search projection, Note Save, merge, push, release, or deployment is included.

## Read-only Astra audit

Two independent Astra source audits reviewed the extractor/Core and
Runtime/storage security matrices. Their findings identify source assertions,
not new passing test evidence. Existing tests cover cross-owner/RLS rejection,
forged source proofs, receipt replay and SQL races, cleanup collisions,
stale completion, native timeout/cancellation, custody lock/revocation,
retained-source reads, and content-free diagnostic/persistence channels.

Remaining qualification slices, in recommended order:

1. Real public import through `Api`, `Documents.Import`, `OperationScope`,
   authorization, custody, authenticated encrypted storage, and PostgreSQL.
   Existing public API import tests replace those boundaries with doubles;
   existing live original-download fixtures precreate the Document.
2. Extraction recovery catalog/UUID-only scanner and atomic rollback on a
   legally constructed successor-event collision; inspect actual SQL semantics
   before selecting the failure assertion.
3. Backup unsupported-inventory owner scoping and two-connection repeatable-read
   snapshot behavior. Do not bypass constraints to manufacture invalid rows.
4. Positive inclusive extraction limits: 4096 pages, 4096 fragments, and exact
   output boundary alongside existing over-limit refusals. Distinguish native
   raw-output bounds from normalized-text bounds before choosing the contract.
5. Real image-only scanned PDF, blocked stdin/native output-overflow descendant
   cleanup, repeated real PDF-to-fragment digest, and adapter log privacy.

These are evidence gaps, not established production defects. Any real failing
contract requires diagnosis and a bounded reviewed repair before production
edits. Never weaken an existing refusal, alter custody semantics, or enable
production canonical writes to make a qualification test pass.

## Live import design review

Parent read the complete live-import design and plan, then a separate Astra
reviewer traced the real adapters, after-commit runner, two authenticated
preparations, isolated grant helpers, deletion path, and denied SafeSQL
telemetry listener control. No Critical or Important finding remained.
Parent issued test-only GO under standing approval, confined to the new
`document_import_live_test.exs`. A valid behavioral failure remains RED pending
bounded diagnosis/repair; no production repair is preauthorized by this plan.

## Unchanged scoped baselines

Commands below ran with
`MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps` in the Phase 2
worktree. Only one Mix process ran at a time. Existing ready PostgreSQL was
borrowed; no service restart or shutdown was performed.

```sh
devenv shell -- mix test \
  apps/singularity_core/test/singularity/core/document_fragmentation_test.exs \
  apps/singularity_core/test/singularity/core/document_values_test.exs \
  apps/singularity_core/test/singularity/core/knowledge_properties_test.exs \
  apps/singularity_ingest/test/singularity/ingest/documents/text_test.exs \
  apps/singularity_ingest/test/singularity/ingest/documents/markdown_test.exs \
  apps/singularity_ingest/test/singularity/ingest/documents/pdf_test.exs \
  --seed 1208
```

PASS, session `41123`, exit 0. Core: 3 properties and 20 tests, 0 failures
(6.2 seconds). Ingest: 24 tests, 0 failures (10.2 seconds). Total 47 executions,
including 3 properties; no integration database was allocated.

```sh
devenv shell -- mix test \
  apps/singularity_runtime/test/singularity/runtime/document_import_test.exs \
  apps/singularity_domains/test/singularity/domains/documents_test.exs \
  --seed 1208
```

PASS, session `5523`, exit 0. Domain: 5 tests, 0 failures (1.0 second).
Runtime: 7 tests, 0 failures (0.6 seconds). These are unchanged unit contracts,
not proof of the live import composition.

```sh
devenv shell -- mix singularity.test.integration \
  apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs \
  apps/singularity_storage/test/singularity/storage/documents/prepare_source_test.exs \
  --seed 1208
```

PASS, session `85402`, exit 0. Storage: 29 tests, 0 failures (8.1 seconds).
Observed database `singularity_test_13a7b071740c23f89160d1c1` was independently
absent after exit (`pg_database` count 0), and the exact storage directory
`/tmp/singularity/integration/13a7b071740c23f89160d1c1` was absent.

## Protected artifacts

The original untracked full-C integration plan remains excluded from staging
and byte-identical: SHA-256
`350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.
The frozen Runtime extraction test remains SHA-256
`b8c6f602344926f4ec085edbd7b3a3b84173efb3d58654cc90ce20d31ba07e42`;
the accepted supervised-restart test remains SHA-256
`3fe960f0afb64f5253626bafbd3acda5b6a04d14c9c884c2b3dc380401f9aed9`.
These hashes and `git diff --check` were verified before new qualification
source changes.
