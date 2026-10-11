# Singularity v0.2 Phase 5 Export and Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task, with independent SPEC then fresh QUALITY review. Steps use checkboxes; unchecked steps are planned work, not passing evidence.

**Goal:** Produce readable portable knowledge artifacts, complete logical V3 backups, verified V1/V2/V3 restoration, and a reproducible historical `0.1.0` upgrade without enabling production canonical writes.

**Architecture:** Preserve the existing encrypted bundle and maintenance restore saga. Add an explicit immutable V3 schema, typed staging and maintenance-only historical admission, then verify canonical history and authenticated original bytes before rebuilding projections and completing restore. Core defines portable values and paths; Storage captures metadata and writes private streamed files; Runtime composes existing authenticated reads and owns temporary export handles.

**Tech Stack:** Existing seven-application Elixir/OTP umbrella, PostgreSQL 17, Ecto/Postgrex, SafeSQL, ExUnit, existing Asset storage/crypto/leases, Jason, devenv, and the existing integration/restore oracles. No new dependency or application.

---

## Draft status, evidence and execution boundary

**REVIEWED FOR IMPLEMENTATION — independent design and plan SPEC followed by
separate fresh QUALITY review have closed.** The coordinator verified the
reviewed design at 679 lines and this plan at 1,328 lines, SHA-256
`9ac947a920af6c95f8d9a20de2bbdac9c7038fccbea28618ea0968f812f7598b`.
That hash identifies the plan before this status update. The report retains
the original findings, bounded corrections and honest review coverage. Task 0
now executes; Phase 5 is IN PROGRESS, not implementation acceptance.
The governing [Phase 5 design](../specs/2026-10-11-singularity-v0.2-phase-5-export-backup-design.md)
was read completely at SHA-256
`8956200fb12784700b9148d6e94079eae08b3a1c282b41d09d0e95e27f5cf9d2`
(666 lines), then its reviewed §8 saga-order correction was inspected at
`3bf8957b42fd9136b23b4172ae17c7515d4e6c1486a735d996f088df0e7e7d3a`
(669 lines), then the reviewed requester-monitor handoff and additive Markdown
renderer clarifications were inspected at
`45ec328473ff1b92627ec27b6bbe21b4e18fdb02452b1d5affd8d09b2e150c6f`
(679 lines). The latter is this plan's current design baseline. If review changes it, reconcile every task against the amended
design and record the new hash before implementation. The complete
[master Phase 5 deliverables](2026-08-31-singularity-v0.2-release.md#phase-5--portable-export-backup-v3-restore-and-upgrade)
and §10 govern completion.

Use only `.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`, based on documentation handoff
`5f7e6363be534dbfb4dfa1475538fddcbd29cf32`. Phase 4's tested implementation
source is `42c01a5c99b1df3d1e4284d277c6ea48046875cb`; the handoff is not a
new implementation qualification. Preserve main, other worktrees and unrelated
untracked files. The design and acceptance report are coordinator-owned.

The [initial Phase 5 report](../../verification/2026-10-11-phase-5-acceptance.md)
records a parent-executed clean baseline: seven full owning files, 136 tests,
zero failures, seed `215378`; compilation/format passed and xref had no cycles.
That was focused characterization, not SQL integration, V3, portable export,
the complete Phase 4 gate or implementation acceptance. This plan-writing task
runs no tests, Mix, formatter, databases, services, network or Git mutations.

Continuing user authority permits recommended in-scope implementation,
necessary repairs, forward migrations, documentation, independent review and
small local commits after review. It does not permit Vault feature work,
custody/key/capability/policy/crypto semantic changes, merge, push, version
bump, tag, release, deployment, production activation or production backfill.
New canonical writes remain unavailable to production runtime roles.
Logical V3 preparation keeps default V2 and the current unsupported-canonical
guard closed until writer and restore qualify together in Tasks 11 and 12.
Do not change frozen leases, use extraction authority for export, disable
triggers/RLS, synthesize sessions or use runtime commands to replay history.
No browser/archive UI is added. E2E is manual-only **NOT RUN**, explicitly
deferred for local phase advancement; final browser/release acceptance remains
required. All other required gates and actual independent review must pass.

The narrow addition to `Runtime.IntegrityAudit.verify_final` in Task 9 passes
already authenticated plaintext evidence to a knowledge validator. Review and
report that exact compatibility seam; it must not change lease material,
cryptographic protocol, custody or completion authority.

The actual frozen `RestoreVault.restore_rewrapped/3` order is owner rewrap →
ciphertext verification → durable-work reconciliation → authenticated plaintext
and Document-source verification → projection rebuild → completion. Keep that
order and maintenance/dispatch barriers throughout. Reconciliation before the
plaintext stage is not publication; no running dispatch or exposed graph is
permitted while either integrity or projection verification remains incomplete.

## Source map and parent-owned execution discipline

| Responsibility | Files/modules |
| --- | --- |
| Frozen wire registries | `apps/singularity_storage/lib/singularity/storage/backup/logical_schema.ex`, `logical_schema_v2.ex`; never edit |
| V3/schema dispatch | New `backup/logical_schema_v3.ex`; existing `logical_record_codec.ex`, `logical_bundle_verifier.ex` |
| Complete cut and object inventory | Existing `backup/exporter.ex`; new forward backup-read/guard migration |
| Typed staging and preflight | New `backup/knowledge_preflight.ex`, `backup/knowledge_restore_digest.ex`; existing `backup/restorer.ex` |
| Historical admission and independent finalizer | New forward migrations after `20261011000200`; no edit to released migrations |
| Original evidence, search and work | Existing Storage `backup/integrity_audit.ex`, `backup/reconciler.ex`; narrow Runtime integrity call |
| Portable pure contract | New Core `knowledge_export.ex`, `knowledge_export_manifest.ex`; additive `note_markdown_sources.ex` entry point |
| Portable snapshot/read/write | New Storage `knowledge_export/repository.ex`, `knowledge_export/writer.ex`; new Runtime `knowledge/export.ex`, `knowledge/export_read.ex`, `knowledge/export_artifact.ex` |
| Public composition | Existing Runtime `api.ex`, `application.ex`; preserve existing production seams and architecture byte contracts |
| Deterministic fixtures and qualification | New support fixtures/tests listed in tasks; existing integration/restore tasks |
| Governance/operator evidence | `AGENTS.md`, `README.md`, `docs/guide.md`, master plan, Phase 5 design/plan/report and new portable-format documentation |

All abbreviated implementation paths below mean
`apps/singularity_storage/lib/singularity/storage/` unless explicitly written
in full. All test commands use full paths. Execute from the assigned worktree.
Use its isolated `_build` and only the existing locked dependency sources.

Parent owns all service, database, formatter, Mix and Git mutations; never run
two such operations concurrently. Workers have disjoint file ownership and
must be told they are not alone. Tasks 1 and 2 can proceed in parallel after
Task 0; all other dependencies are explicit. Parallel read-only investigations
and reviews are permitted; migrations, restore and live tests are serialized.
Track cumulative Sol repair rounds; at most two failed repair/validation
rounds before evidenced escalation. Architecture advice is not a repair round.
Characterize failures, amend the design when necessary, and preserve every
required assertion. Internal dependency blockers follow upstream issue routing.

Every task ends with the same concrete sequence: run the stated focused check
and its complete owning files; run `git diff --check`; self-review its source
against the design; independent SPEC review; fresh independent QUALITY review;
resolve findings and rerun only affected checks; stage exactly that task's
listed paths and make its stated local conventional commit. Never use `git add
.`. Record RED/GREEN commands, exit codes, test counts, source SHA, migration
IDs, changed files, reviewers/findings, repair counters and cleanup in the
acceptance report. An expected missing-module RED is not an implementation
repair. Do not record an expected result as an executed result.

At each task boundary and final handoff verify the parent's ignored frozen
baseline `.devenv/phase5-frozen-baseline.sha256`, SHA-256
`d0296d241c66e382baa09a0a092fe8add6df66364d5f2d5644f4f4ea1963a050`:

```sh
sha256sum .devenv/phase5-frozen-baseline.sha256
sha256sum -c .devenv/phase5-frozen-baseline.sha256
```

Expected: the baseline file hash matches and all 56 entries pass (43 existing
migrations plus 13 explicitly frozen source files). New forward migrations are
additive and are not entries in that historical baseline. This hash coverage is
not a claim that all 56 files were source-reviewed; do not stage ignored tooling
or regenerate baseline hashes from modified files.

Focused pure check command pattern:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs --seed 215378 --warnings-as-errors
```

Focused SQL check pattern (the task accepts paths after the integration name):

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_schema_test.exs --seed 215378 --warnings-as-errors
```

SQL work requires the parent-owned isolated cluster, exact checked worktree
PGDATA/socket/port and existing external administrator bootstrap hook. Keep
EXIT cleanup. The harness allocates `singularity_test_<24 hex>` databases and
owned object roots; never use production, broad deletion or another worktree's
cluster. `MigrationTestEnvironment` is process-global and must be serialized.
Record shutdown/database/root cleanup after every failure and before handoff.

## Task 0: Preserve governance while advancing the active narrative to Phase 5

**Modify:** `apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs`,
`apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`,
`AGENTS.md`, `README.md`, `docs/guide.md`.
**Record:** coordinator-owned Phase 5 design/plan and acceptance report.
**Depends on:** independent design/plan review resolving the draft condition.

- [x] Write active guidance tests requiring Phase 5 design/plan narrative links,
  exact Phase 4 tested SHA and handoff, the retained qualified Phase 3/4 history,
  V3 preparation default V2, closed production writes, Vault freeze and E2E
  deferral. Change only current active-phase expectations; retain all historical
  assertion bodies, exact ordered five governing-document bullets, complete
  continuous-authorization/protocol assertions and mutation/removal/duplication/
  relocation counterexamples. Add this direct assertion to the active section:

```elixir
assert section =~ "The active implementation slice is Phase 5"
assert section =~ "42c01a5c99b1df3d1e4284d277c6ea48046875cb"
assert section =~ "5f7e6363be534dbfb4dfa1475538fddcbd29cf32"
assert section =~ "2026-10-11-singularity-v0.2-phase-5-export-backup-design.md"
assert section =~ "2026-10-11-singularity-v0.2-phase-5-export-backup.md"
assert section =~ "New canonical writes remain unavailable to production runtime roles."
```

  Add an authority-contract test reading this plan between
  `## Draft status, evidence and execution boundary` and
  `## Source map and parent-owned execution discipline`, design §1 between
  `## 1. Baseline, scope, and fixed boundaries` and `## 2. Evidence and selected approach`,
  and design §6 between `## 6. Logical V3 wire schema and inventory` and
  `## 7. Semantic preflight and historical admission`. Require the actual
  production-write prohibition and staged default-V2/closed-guard declarations
  there as active prose, not a quoted command/test fence. Preserve historical
  Phase 3/4 authority tests and active-prose negative assertions.

- [x] Run both full governance suites before documentation edits:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --seed 215378 --warnings-as-errors
```

  Expected RED: current active narrative is Phase 4; old negative/historical
  assertions still pass. An unrelated failure is diagnosed, never stripped.
- [x] Add only narrative links outside the five governing bullets and update
  active guidance to: `The active implementation slice is Phase 5 under` the
  design/plan; Phase 4 accepted at the exact tested SHA, documentation handoff
  at the exact base; `Logical V3 preparation keeps default V2 and the current
  unsupported-canonical guard closed until writer and restore qualify together.`
  Keep historical Phase 4 design/plan exclusions historical and intact.
- [x] Run both complete suites to GREEN, format/compile/xref and diff checking.
  No application/guard/runtime baseline-stripping change belongs to this task.
- [x] Complete SPEC then QUALITY, record the unaccepted Phase 5 status and
  commit `docs: start phase five export and backup qualification` using exactly
  the reviewed guidance/contracts and Phase 5 documents.

## Task 1: Explicit isolated V3 schema and codec/verifier support, default V2

**Create:** `apps/singularity_storage/lib/singularity/storage/backup/logical_schema_v3.ex`,
`apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs`.
**Modify:** Storage `backup/logical_record_codec.ex`, `backup/logical_bundle_verifier.ex`,
their complete existing tests.
**Depends on:** Task 0; independent of Task 2.

- [x] Add RED pure schema tests with an independent literal schema contract:

```elixir
assert LogicalSchemaV3.version() == 3
assert LogicalSchemaV3.count() == 38
assert LogicalSchemaV3.column_count() == 367
assert Enum.take(LogicalSchemaV3.all(), 30) ==
         Enum.map(LogicalSchemaV2.all(), &Map.put(&1, :version, 3))
assert Enum.map(Enum.drop(LogicalSchemaV3.all(), 30), & &1.ordinal) == Enum.to_list(30..37)
assert LogicalRecordCodec.default_version() == 2
assert LogicalRecordCodec.tables() == LogicalSchemaV2.tables()
```

  Assert every appended column/tag/nullability/PK position below literally;
  missing/excess/reordered columns, wrong PK and nullable required values fail.
  Freeze V1 and V2 file hashes `ba0722ca85ce0a1259ce650927aa53ed728db0b28467adf308c3ada5a03036e8`
  and `992ef89fb52a91ccaa0d7cf2b3ae6607a465e7b345cca5d6c55a86c3fac9f3e6`.
- [x] Run the new schema file plus the codec/verifier and V1 owning files:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_bundle_verifier_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
```

  Expected RED: missing V3 registry/dispatch; existing default V2 assertions pass.
- [x] Implement V3 by copying no V1/V2 source: map `LogicalSchemaV2.all()` with
  only `version: 3`, then append eight explicit definitions. Build the same
  `all/tables/count/column_count/fetch_table/fetch_ordinal` registry interface.
  Use these exact ordered definitions (`?` marks nullable, not part of name):

```text
30 content.document_versions; PK 0:uuid
resource_version_id:uuid resource_id:uuid vault_id:uuid classification:text
source_asset_id:uuid source_resource_id:uuid source_resource_version_id:uuid
source_object_id:uuid source_digest:bytes source_byte_size:integer media_type:text
title:text created_by_principal_id:uuid state:text attempt_generation:integer
extraction_adapter:text? extraction_format:integer? extracted_text_digest:bytes?
detected_language:text? failure_code:text? attempt_finished_at:timestamp?
inserted_at:timestamp attempt_job_id:uuid? attempt_started_at:timestamp?
attempt_deadline_at:timestamp?
31 content.document_fragments; PK 0:text
id:text resource_id:uuid resource_version_id:uuid vault_id:uuid classification:text
ordinal:integer text:text digest:bytes locator:json inserted_at:timestamp
32 content.document_import_receipts; PK 0:uuid 1:uuid 2:uuid
vault_id:uuid principal_id:uuid mutation_id:uuid request_fingerprint:bytes
state:text resource_id:uuid? version_id:uuid? inserted_at:timestamp
33 content.note_attachments; PK 0:uuid 1:uuid
note_resource_version_id:uuid id:uuid note_resource_id:uuid vault_id:uuid
classification:text target_resource_id:uuid target_resource_version_id:uuid
target_kind:text ordinal:integer role:text label:text? inserted_at:timestamp
34 content.note_citations; PK 0:uuid 1:uuid
note_resource_version_id:uuid id:uuid note_resource_id:uuid vault_id:uuid
classification:text source_resource_id:uuid source_resource_version_id:uuid
fragment_id:text locator:json ordinal:integer inserted_at:timestamp
35 content.tags; PK 0:uuid
id:uuid vault_id:uuid classification:text display_value:text normalized_key:text
created_by_principal_id:uuid inserted_at:timestamp
36 content.resource_tags; PK 0:uuid 1:uuid 2:uuid
resource_id:uuid tag_id:uuid vault_id:uuid classification:text inserted_at:timestamp
37 content.relationships; PK 0:uuid
id:uuid vault_id:uuid classification:text source_resource_id:uuid
target_resource_id:uuid target_resource_version_id:uuid? type:text
created_by_principal_id:uuid inserted_at:timestamp
```

  Register explicit `schema_for(3)` in codec/verifier and extend `1 | 2` types
  to `1 | 2 | 3`; leave `@default_version 2`, its typespec, and default test intact.
  No restorer or writer default enablement yet; no guard exception. Preserve
  explicit `Restorer.import` rejection of version 3 until the bounded complete
  historical import task is implemented; Task 1 never adds `logical_schema(3)`.

  The registry construction after the literal `@definitions` tuples is:

```elixir
@appended_schemas @definitions
                  |> Enum.with_index(30)
                  |> Enum.map(fn {{table, columns, primary_key}, ordinal} ->
                    %{
                      version: 3,
                      ordinal: ordinal,
                      table: table,
                      columns: Enum.map(columns, fn {name, tag, nullable?} ->
                        %{name: name, tag: tag, nullable?: nullable?}
                      end),
                      primary_key: Enum.map(primary_key, fn {position, tag} ->
                        %{position: position, tag: tag}
                      end)
                    }
                  end)
@schemas Enum.map(Singularity.Storage.Backup.LogicalSchemaV2.all(),
           &Map.put(&1, :version, 3)) ++ @appended_schemas
@by_table Map.new(@schemas, &{&1.table, &1})
@by_ordinal Map.new(@schemas, &{&1.ordinal, &1})

@spec version() :: 3
def version, do: 3
@spec all() :: [map()]
def all, do: @schemas
@spec tables() :: [binary()]
def tables, do: Enum.map(@schemas, & &1.table)
@spec count() :: pos_integer()
def count, do: 38
@spec column_count() :: pos_integer()
def column_count, do: 367
@spec fetch_table(term()) :: {:ok, map()} | :error
def fetch_table(table) when is_binary(table), do: Map.fetch(@by_table, table)
def fetch_table(_), do: :error
@spec fetch_ordinal(term()) :: {:ok, map()} | :error
def fetch_ordinal(ordinal) when is_integer(ordinal), do: Map.fetch(@by_ordinal, ordinal)
def fetch_ordinal(_), do: :error
```

  Construct each definition as `{table, [{name, tag, nullable?}], [{position,
  tag}]}` using the complete ordered contract above; for example the receipt
  definition is exactly:

```elixir
{"content.document_import_receipts",
 [
   {"vault_id", "uuid", false}, {"principal_id", "uuid", false},
   {"mutation_id", "uuid", false}, {"request_fingerprint", "bytes", false},
   {"state", "text", false}, {"resource_id", "uuid", true},
   {"version_id", "uuid", true}, {"inserted_at", "timestamp", false}
 ], [{0, "uuid"}, {1, "uuid"}, {2, "uuid"}]}
```

  Add the codec alias/table/schema clauses explicitly:

```elixir
alias Singularity.Storage.Backup.LogicalSchemaV3
def tables(3), do: LogicalSchemaV3.tables()
defp schema_for(3), do: {:ok, LogicalSchemaV3}
```

  Put clauses before existing fallback clauses. Verifier gets the same alias
  and private schema clause; its authenticated mixed-version checks stay intact.
- [x] Add independent explicit V3 cut/row/object literal golden cases, wrong
  count/vector/schema, malformed version 3 and mixed `3↔1`, `3↔2` row/object
  cases for both verifier entry paths. The current unknown-version fixture at
  verifier line 445 mutates to `3`; change that unknown value to `4` while
  retaining its exact rejection assertion. Assert `0`, `4` and forged terms fail.
- [x] Run all four full files to GREEN, verify frozen registry hashes/diff,
  SPEC then QUALITY, commit `feat(backup): define explicit logical v3 wire schema`.
  Exhaustive current-DDL comparison is Task 3's first SQL check; pure registry
  tests alone do not establish database schema agreement.

## Task 2: Pure portable options, safe paths, descriptors and ordinary Markdown

**Create:** `apps/singularity_core/lib/singularity/core/knowledge_export.ex`,
`apps/singularity_core/lib/singularity/core/knowledge_export_manifest.ex`,
`apps/singularity_core/test/singularity/core/knowledge_export_test.exs`,
`apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs`.
**Modify:** Core `note_markdown_sources.ex`, `note_markdown_sources_test.exs`.
**Depends on:** Task 0; independent of Task 1.

- [x] Write focused RED tests for strict options, manifest fields, UUID/version
  paths, deleted-source metadata and relative Markdown source links. Examples:

```elixir
assert {:ok, %{include_tombstones: false}} = KnowledgeExport.options(%{})
assert {:error, %Error{code: :invalid}} = KnowledgeExport.options(%{owner_scope_id: id})
assert {:error, %Error{code: :invalid}} = KnowledgeExport.options(%{destination: "/tmp"})
assert {:ok, "notes/" <> basename} = KnowledgeExport.path(:note, resource, version, nil)
assert basename == resource <> "--" <> version <> ".md"
assert {:error, %Error{code: :invalid}} = KnowledgeExport.path(:note, "../x", version, nil)
```

  Use canonical fixture UUID literals from the existing Core tests. Require
  boolean `include_tombstones`; reject unknown/string-duplicate keys, forged
  structs, caller scope/adapters/paths and unsafe IDs. Media mapping is exactly
  PDF→pdf, Markdown→md, text/plain→txt; Asset pins use `.bin`.
- [x] Run new Core files and the full existing Markdown sources file. Expected
  RED: constructors/portable renderer missing; existing text-only renderer passes.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_core/test/singularity/core/knowledge_export_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs --seed 215378 --warnings-as-errors
```

- [x] Define pure `KnowledgeExport.options/1`, `path/4`, `relative_source_path/2`
  and `limits/0`. Define `KnowledgeExportManifest.record/2` and `header/1`:
  reconstruct only the exact allowed record keys in design §5; validate canonical
  UUIDs, kind/state/availability, UTC microseconds, lowercase SHA-256, integer
  ordinals and nullable field shapes. All version fields are always present;
  no owner/principal/key/storage/session/receipt/job fields can be carried through.
  Files omit manifest.json; its descriptor is delivered separately.
- [x] Add `NoteMarkdownSources.render_portable/3` accepting canonical body,
  existing typed attachment/citation descriptors and a validated exact-version
  file map. Reuse escaping/fence/footnote logic while preserving `render/2`
  output bytes and its text-only header. Portable header declares included
  files; unavailable sources have readable metadata/locator/reason and no false
  file link. Compute relative paths from the containing Note directory; never
  use a proprietary URI. Preserve user body, existing footnote labels and
  separately record canonical-body and rendered-file digests.
- [x] Require tests for duplicate titles, hostile labels, brackets/parentheses,
  control characters, existing footnotes/open fences, URL escaping, absolute/
  traversal/NUL/symlink/case-fold collisions and two historical versions of one
  Document. Fixed global limits are 100,000 keys, 1,000,000 metadata records,
  1 GiB metadata, 64 GiB file bytes, 15 minutes, 500 rows/page, 64 KiB chunks;
  retain stricter Note/Document/fragment limits. No SQL/filesystem imports in Core.
- [x] Run complete owning files to GREEN, format/compile/xref/diff, SPEC then
  QUALITY; commit `feat(export): define portable knowledge values and markdown`.

## Task 3: Freeze current DDL agreement and build independent whole-graph fixtures

**Create:** `apps/singularity_storage/test/support/knowledge_backup_fixtures.ex`,
`apps/singularity_storage/test/singularity/storage/backup/logical_v3_schema_ddl_test.exs`,
`apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs`,
`apps/singularity_storage/test/fixtures/backup/logical-v3-schema.json`.
**Read/reuse:** existing `support/fixtures.ex`, `note_fixtures.ex`,
`knowledge_fixtures.ex`, `migration_test_environment.ex`, `backup/restore_import_test.exs`.
**Depends on:** Task 1.

- [x] Add the first scoped SQL RED contract: query `pg_attribute`, `pg_type`,
  `pg_index`, `pg_constraint` for all 87 appended columns and exact ordered PK
  positions. Match `uuid/text/bytea/bigint/integer/jsonb/timestamptz`, effective
  required/nullability and wire order. V2 uses historical wire projection order,
  not arbitrary `SELECT *`. Verify exactly eight appended tables/87 columns.
- [x] Run the schema-DDL and fixture contracts through the isolated integration
  task; missing fixture support is RED. Confirm an intentionally wrong type,
  missing column or swapped PK makes the contract fail, then remove only that
  test-local perturbation. Do not mutate actual DDL to test the test.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_schema_ddl_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs --seed 215378 --warnings-as-errors
```

- [x] Implement `KnowledgeBackupFixtures.seed!/1`, `canonical_rows/1`,
  `source_bytes/1`, `search_rows/1`, `verified_bundle/2`, `malformed_bundle/2`
  and `with_destination/2`. These are test helpers, not production interfaces.
  `seed!` returns owner/session IDs, stable logical row/byte oracles and all
  exact immutable IDs. `with_destination` owns a disposable migrated database
  and random object root and restores process-global configuration in `after`.
  Canonical comparisons use the explicit typed column projections and sorted
  PKs, excluding only established V2 identity transformations and derived state.
- [x] Seed live/deleted Notes, history, unresolved and resolved conflicts,
  merge ancestry and every Document state through established lifecycle SQL/
  runtime test seams; ready fragments come from real canonical constructors.
  Seed old/current Document versions, same-object deduplication, binary PDF,
  empty/plain/Unicode text, Markdown, completed import receipts, tags, edges,
  exact attachments/citations and all valid durable work. Delete the source
  Asset and release its association/clear its current object pointer while
  retaining a live and tombstoned historical Document original. Capture the
  unchanged `source_object_id/digest/byte_size` as the independent oracle.
- [x] Build fixed malformed logical records by changing one literal field and
  authenticating the fixture using the existing test crypto seam. A writer
  round trip is not the malformed/golden oracle. Store only sanitized synthetic
  fixture content; no real credentials/user content. Immutable V1 fixture stays
  byte-identical; fixed V2 vectors stay explicit version 2. V1 fixture encoding
  continues through the frozen codec/golden path, never a new V1 Exporter writer.
- [x] Assert fixture legality independently before testing export/restore;
  do not bypass source seals, lifecycle or constraints. Run owning fixtures/
  schema files to GREEN; SPEC then QUALITY, commit
  `test(backup): add independent v3 history and ddl fixtures`.

Task3 accepted locally at `465c377ade63b38bccabcac729e998ddc61ba473` after
the complete 18/0 owning SQL rerun, static gate, legacy SQL and 186/0 downstream
regressions. The non-author SOURCE SPEC closure carried its full prior source
review and read the complete bounded wrapper repair/new contract; a separate
fresh non-author SOURCE QUALITY read all four current files,2,680 lines, and
passed without findings. Exact receipts and coverage limitations are recorded
in the acceptance report. This closes only the fixture slice, not Phase5 or
live runtime acceptance. E2E remains NOT RUN.

## Task 4: Authenticate, type-stage and preflight before canonical mutation

**Create:** `apps/singularity_storage/lib/singularity/storage/backup/knowledge_preflight.ex`,
`apps/singularity_storage/lib/singularity/storage/backup/knowledge_restore_digest.ex`,
`apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs`,
`apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_digest_test.exs`.
**Modify:** Storage `backup/restorer.ex` only its V3 staging entry path.
**Necessary test-contract changes:** `apps/singularity_storage/test/support/knowledge_backup_fixtures.ex`
for genuine authenticated row/object transforms and the two generation-zero
idempotency literals; `apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs`
for the actual seeded-envelope decoder regression. The frozen producer/decoder
and all prior assertions remain unchanged; RED, diagnosis and bounded correction
are recorded in the acceptance report under continuous development authority.
**Depends on:** Tasks 1 and 3; does not enable V3 canonical import.

- [x] Add RED tests calling `KnowledgePreflight.stage/4` with an authenticated
  `%BundleReader.Verified{replay: %BundleReader.Replay{}}`, bound manifest/cut, migration connection and
  owned object staging adapter. Reject unauthenticated data before creating
  staging. Inspect canonical table counts before/after every rejection:

```elixir
before = KnowledgeBackupFixtures.canonical_rows(owner)
assert {:error, %Error{code: :backup_invalid}} =
         KnowledgePreflight.stage(repo, verified, cut, storage)
assert KnowledgeBackupFixtures.canonical_rows(owner) == before
```

- [x] Run the full preflight integration file; expected RED is missing stage
  implementation. Implement connection-local typed temporary tables with fixed
  compile-time identifiers/projections, `ON COMMIT DROP`, exact PK/secondary
  unique indexes and at most 500-row insertion batches. Consume bounded
  authenticated records and staged object chunks; never collect full text/
  fragments or execute bundle-supplied identifiers/functions. Retain 64 KiB
  header, 16 MiB record, 999,999 frame limits and immutable replay verification.
  `BundleReader.reduce_verified/3` events are provisional until its final authentication
  succeeds: effects stay in the uncommitted transaction and unpublished owned
  object stages. Keep the existing Verified/Replay types and crypto path.
- [x] Define `KnowledgePreflight.validate/3` to return only bound counts,
  canonical per-table digests and typed staged ownership after all joins pass.
  Check owner/classification/creator/membership; typed heads; Note digests,
  revisions/parent/merge DAG/conflicts; Document immutable historical source
  identities, retained object/size/format and attempt-state shapes; ready-only
  fragments with canonical IDs/locators/text hashes/contiguous ordinals and
  concatenated extracted hash; Note source types/owners/ordinals/uniqueness/
  no self links/limits/exact locator; tag Core normalization/owner uniqueness;
  edge types/version ownership; completed receipts and durable payload shapes.
  Every extraction event's expected generation must be no greater than its
  pinned Document version's persisted generation. Preserve legal pending
  equality and older/stale events; the current extracting job still requires
  exactly persisted generation minus1. Characterize with genuine authenticated
  undispatched events, not a forged Verified or syntactically invalid key.
- [x] Define `KnowledgeRestoreDigest.projection/1` from the immutable registry
  and `table_digest/3` using sorted PKs and explicit typed length-framed row
  encoding. Both staged and canonical rows use the same projection; never hash
  generic maps, destination-selected metadata or unstable timestamps. For byte
  values use their bytes; for UUIDs canonical 16 bytes; for timestamp exact UTC
  microseconds; frame null independently from empty; JSON uses canonical sorted
  object encoding. Freeze independent vectors for null/empty/multibyte/JSON and
  equal-count row changes. Expected digests are computed from authenticated
  staged rows before admission. SQL finalization must use the identical encoding.
- [x] Reject duplicates, mixed versions, extra/missing rows, wrong counts,
  dangling/cross-owner/type references, cyclic Note ancestry, incorrect fragment
  IDs/ordinals/locators/digests, non-ready fragments, unsupported formats,
  pending receipts, receipt disagreement, ambiguous Asset bindings and malformed
  job provenance. Historical released associations/nulled Asset pointers remain
  legal only with exact immutable Document pin and retained object.
- [x] Validate exact inventory union and evidence/raw one-to-one mapping;
  reject missing/extra foreign objects, truncated/changed ciphertext and lengths.
  Source plaintext hash comparison is deferred specifically to Task 9, not
  replaced with ciphertext hashing. Assert no canonical insert before complete
  preflight and bounded buffering with record/page observer barriers.
- [x] Run full file to GREEN:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs --seed 215378 --warnings-as-errors
```

  SPEC then QUALITY, commit `feat(restore): stage and preflight canonical v3 graph`.

### Task4 selected typed-digest and test-boundary detail

This implements the already required framed digest and its independent vectors;
it adds no product/API authorization or canonical V3 import. `projection/1`
returns the immutable V3 schema, never destination catalog metadata.
`table_digest(repo, table, :staged | :canonical)` returns a bound count/32-byte
SHA pair. Fixed staged relations are `pg_temp.knowledge_restore_0` through `_37`.
`install/1`, the fixed-tag, fixed-`value`-identifier `value_encoding_sql/1`
and fixed-registry `row_chunks_sql/2` are internal SQL compilation/test seams,
not runtime or bundle-selected SQL. The SQL side encodes bytes; Elixir streams
one at-most65,536-byte encoded-row slice per fetch and folds only a digest/count
and the current incremental hash context. Length is framed once per row;
the digest chain and count advance only after its final slice. Wire payload
limits remain unchanged: typed JSON framing can expand a legal16 MiB record.
No generic map/ETF/JSON text digest or Decimal rounding.

Let `U(n)` be unsigned 64-bit big-endian framing, within signed PostgreSQL
length/count limits, and `F(bytes) = U(byte_size(bytes)) || bytes`. Scalar tags
are boolean01, integer02, bytes03, text04, UUID05, timestamp06 and JSON07.
Every cell is `tag || presence || F(payload)`; presence00 for SQL NULL with
empty payload, presence01 otherwise. Payloads: Boolean00/01; signed big-endian
int64; raw bytea; UTF-8 text; canonical16-byte UUID; signed UTC epoch
microseconds; or the following recursive binary JSON:

- null00, false01, true02;
- number03 plus framed exact `trim_scale(numeric)::text`, no float/Decimal
  precision conversion (1/1.0/1e0 and -0/0 agree);
- string04 plus framed unescaped UTF-8;
- array05 plus element count, then framed recursively encoded elements;
- object06 plus key count, then framed key UTF-8 and framed encoded value,
  ordered by UTF-8 key bytes, not database locale.

Row bytes are `U(column_count)` followed by cells in immutable wire order.
Projection bytes `P` are `U(column_count)`, then each framed column name/tag/
nullable byte, then `U(PK_count)` and ordered zero-based PK positions. With
`domain = "singularity:knowledge-restore-digest:v1"`:

```text
D0 = SHA256(00 || F(domain) || U(3) || F(table_name) || F(P))
Di = SHA256(01 || D(i-1) || F(row_bytes_i))
final = SHA256(02 || Dn || U(row_count))
```

Native UUID/integer and byte-ordered text PK sorting is fixed. Task5 must
independently implement the identical protocol in owned, pinned SQL functions
and ordered cursors; it must not trust a caller-created pg_temp helper.
Independent scalar/JSON literal vectors include signed bounds, pre-epoch and
microsecond timestamps, multibyte/escaped strings, SQLNULL versus JSONnull,
empty containers, nested byte-sorted keys and numbers beyond34 digits. Literal
empty/two-row/reversed-row SHA vectors were calculated from separately framed
literal bytes before production code, not via the function under test.

Additional independent literal JSON/row vectors cover a legal wire row whose
framed row is16,785,376 bytes. Its exact SHA remains required, not an increased
wire limit. A separate real SafeSQL cursor contract observes only numeric chunk
lengths/offsets, proves at-most65,536-byte payloads and native PK order on reverse
inserted rows, and checks empty canonical/invalid-identifier selection. This
qualifies bounded client transport, not database/VM memory instrumentation.

Wire-invalid duplicates/mixed versions/order/count/evidence-raw equality are
rejected by the unchanged real verifier before Replay issuance; tests must not
forge Verified to shift those failures to Stage. Coherently counted semantic
graph and object-row/evidence disagreement negatives use genuine Replay.
Stage/validate share the caller migration transaction and use local savepoint
rollback plus an independent owned-stage cleanup ledger on failure. A narrowly
scoped trusted numeric observer measures real batches/metadata/object appends;
it makes no VM-memory or disabled Ecto-telemetry claim. Source plaintext SHA
equality remains Task9; Notes have no invented SHA column. E2E stays NOT RUN.

Task4 accepted locally at `854fad69915c937fe7dcdec0a12a6d487fffb7f6`
after owning27/0, post-repair static gate and actual independent full SOURCE
SPEC→bounded finding closure→fresh full SOURCE QUALITY. Exact reviewed source,
test and document receipts/coverage are recorded in the acceptance report.
This post-verdict checkpoint is not retroactively part of those reviews.
Canonical V3 import/default activation remain closed. E2E is NOT RUN.

## Task 5: Migration-only transaction-bound admission and deferred finalizer

**Create:** `apps/singularity_storage/priv/repo/migrations/20261011000300_knowledge_restore_admission.exs`,
`apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs`.
**Modify:** `knowledge_preflight.ex`, `knowledge_restore_digest.ex` for the
  explicit staged-to-destination verification call, not runtime authorization.
**Depends on:** Task 4.

- [x] Write RED SQL counterproofs for actual `session_user` web/worker/
  dispatcher/pre-auth connections, spoofed GUCs, table-owner SECURITY DEFINER
  nesting, absent advisory lock, wrong pending saga/owner/manifest/hash,
  nonempty destination, wrong backend/transaction, stale records, missing
  finalizer and post-validation equal-count mutation. Every failure must occur
  at admission, write or commit with no partial canonical visibility.
- [x] Run the admission integration file; expected RED: no admission relation/
  helpers. Create only `audit.knowledge_restore_admissions`, owned by
  `singularity_table_owner`, columns for manifest/owner/authenticated hash,
  full transaction `xid8`, backend PID, expected counts/per-table digests and
  loading/validated state. Exclude it from wire/export/destination canonical
  digests; no PUBLIC/runtime relation/helper grants. Pin helper search paths.
- [x] Implement admission functions `audit.begin_knowledge_restore`,
  `audit.validate_knowledge_restore`, `audit.knowledge_restore_is_bound` and
  `audit.enforce_knowledge_restore_final` with migration-only exact authority:

```sql
IF session_user <> 'singularity_migration'
   OR NOT pg_has_role(session_user, 'singularity_table_owner', 'SET') THEN
  RAISE EXCEPTION 'knowledge restore authority unavailable' USING ERRCODE='42501';
END IF;
```

  Bind `pg_current_xact_id()` and `pg_backend_pid()`, exact authenticated saga,
  owner/hash/manifest, loading state, empty destination and existing advisory
  lock `hashtextextended('singularity:restore-import:v1',0)`. Verify owned lock
  through exact `pg_locks` identity; acquiring a caller-specified lock is not
  proof. Helpers recheck binding, not a caller Boolean or GUC.
- [x] Add an initially deferred constraint trigger on admission insert/update:

```sql
CREATE CONSTRAINT TRIGGER knowledge_restore_final_check
AFTER INSERT OR UPDATE ON audit.knowledge_restore_admissions
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
EXECUTE FUNCTION audit.enforce_knowledge_restore_final();
```

  Re-read the final admission state and revalidate complete structural graph,
  every canonical count and per-table staged digest at commit. `validated`
  without actual equality fails. Explicit finalization alone is insufficient:
  later equal-count mutation, source-seal changes or missing rows must fail.
  Keep established V2 identity transformations separately verified, never
  exempt knowledge rows. Migration teardown is forward-only, not rollback of
  a released migration. Never alter role membership/attributes or Vault policy.
- [x] Run the full admission file and existing RLS/grant/schema files to GREEN:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs apps/singularity_storage/test/singularity/storage/knowledge_schema_test.exs --seed 215378 --warnings-as-errors
```

  SPEC then QUALITY, commit `feat(restore): bind historical admission to maintenance transaction`.

### Task5 selected admission, SQL oracle and commit-proof details

These choices implement approved design §7, not an expansion of runtime or
Vault authority. The singleton admission has boolean PK/CHECK, manifest/vault
UUIDs, 32-byte authenticated manifest hash, full `xid8`, backend PID, exactly
38 expected counts/digests and loading/validated state. Arrays must be
one-dimensional/lower-bound1, nonnull, counts nonnegative and each digest32
bytes. Store immutable full pending-saga snapshot: manifest tag16, inventory
hash32, destination-root hash32 and object count. Derive this snapshot from
the locked existing saga, not caller-supplied GUCs. Entry APIs are:

```sql
audit.begin_knowledge_restore(uuid,uuid,bytea,bigint[],bytea[]) RETURNS void
audit.validate_knowledge_restore(uuid,uuid,bytea) RETURNS void
audit.knowledge_restore_is_bound(uuid) RETURNS boolean
audit.enforce_knowledge_restore_final() RETURNS trigger
```

All relations/functions are table-owner owned, pinned to `pg_catalog`, fully
qualified, and revoke PUBLIC/runtime access. Check exact migration session and
existing table-owner SET authority. Check the current backend's granted
exclusive bigint advisory lock, using exact database/classid/objid/objsubid
identity for `hashtextextended('singularity:restore-import:v1',0)`; a different
lock or another backend's lock is not proof. Admission checks the full empty
destination union, including derived seals/excluded runtime tables. Immutable
binding/count/digest values cannot be rewritten; only defined validated-state
transition is permitted. Loading historical-write authorization requires the
same pending saga/current backend/full transaction. Validated rows never grant
historical writes. At final COMMIT allow only the same bound saga still pending
or legitimately imported: existing Restorer marks it imported before COMMIT.
Later saga states and stale admission rows do not authorize another transaction.

Private fixed SQL seams `audit.knowledge_restore_json_bytes(jsonb)` and
`audit.knowledge_restore_table_digest(integer)` implement Task4's exact framed
protocol independently; the latter returns `row_count bigint,digest bytea`
for a closed ordinal0..37. Inline frozen projections/types/PK positions and
ordered one-row cursors; no caller relation/SQL, destination-selected projection,
pg_temp encoder or whole-table aggregation. Legal typed row expansion does
not impose a new16 MiB framed-row cap. Private
`audit.assert_knowledge_restore_graph(uuid)` checks canonical structural history,
scope/typed heads/parents/source pins/fragments/source sets/organization/work
and exact derived seals independently. Existing FK/CHECK/immutability stays on.
Core Unicode Tag normalization remains genuine preflight plus exact all-field
digest equality; PostgreSQL lower() is not substituted for Core NFC/casefold.

Preserve authenticated manifest/hash/tag/inventory and private destination
binding in the typed Staged handle; never detach a caller-provided summary as
authorization. Expected destination digests derive before canonical insertion
from authenticated staging. The only established V2 wire-value transformation
is `core.vaults.locked=true`; retain raw staged digests and separately qualify
this transformed expectation. Omitted credential verifier/version/updated-at
and pending wrapper compatibility values remain separately checked; no knowledge
field is exempted or substituted. SQL does not itself authenticate the bundle.

Use genuine sequential source/different fresh destination databases. Reduce the
disposable authenticated fixture to live-compatible pending Document/original,
initial Note with Asset attachment, tag/assignment/pinned relationship and
completed receipt; keep real crypto/Reader/Replay and normal guards. Preserve
encrypted bytes in a test-owned private path and freshly authenticate them after
the source environment closes, rather than carrying a discarded Replay.
Historical deleted-source/ready-fragment insertion belongs to Task6, not a
disabled-trigger Task5 positive. Stage all38 expectations before admission.

Commit counterproofs let callbacks return normally and observe actual COMMIT,
then independently verify no canonical visibility. Cover omitted validation,
equal-count valid row mutation after validation, missing/inconsistent seals,
wrong full marker/backend/fullxid8, stale records and actual runtime sessions,
GUC spoof and table-owner SECURITY DEFINER nesting. Keep the admission constraint
trigger deferred while forcing only the fixed ordinary deferrable constraints:
`SET CONSTRAINTS ALL IMMEDIATE` would drain its queued COMMIT check. Later Task7
must preserve this queue and test its exact prepublication sequence. No V3 import
or historical guard branch is enabled by Task5. SPEC then fresh QUALITY remain
required; E2E stays NOT RUN.

Task5 qualification: actual first causal RED, initial two test-probe failures,
bounded assertion-preserving test correction, complete owning50/0,
Stage/Digest/genuine-fixture40/0, legacy/DDL15 actual SQL/0, pure186/0 and
full static/no-cycle gate completed. Fresh non-author full SOURCE SPEC followed
by separate fresh full SOURCE QUALITY returned PASS with no findings, reading
all four source files,5,044 lines. Exact receipts, native verdicts, original
failures, commands, cleanup and counters are in the acceptance report. The
parent committed exactly seven paths locally at
`4f9cf6a91a80e1cdb7213d0cd942be96d69d982a`; Phase5 remains incomplete,
Task6 historical guards and canonical V3 import/default remain closed.

## Task 6: Narrow historical guard branches with live constraints intact

**Create:** `apps/singularity_storage/priv/repo/migrations/20261011000400_knowledge_historical_restore_guards.exs`,
`apps/singularity_storage/test/singularity/storage/backup/knowledge_historical_admission_test.exs`.
**Read:** released `20260906000100`, `20260906000200`, `20260906000300`,
`20260922000100`, `20261011000000`, `20261011000200` migrations in full.
**Depends on:** Task 5.

- [x] Add RED real SQL insertion cases restoring a deleted Document whose source
  Asset is deleted, association released and Asset object pointer null; exact
  ready version/fragments; historical deleted Note targets; tags/edges on
  tombstoned endpoints. Add identical attempted live-runtime cases that fail.
- [x] Run the historical-admission file before the forward migration; expected
  RED is the current creation-time live/ready seal guard, not a failed FK ignored
  by the test. Implement explicit restore validators within these four functions:
  `content.enforce_document_source`, `content.enforce_document_fragment`,
  `content.enforce_note_source_set`, `content.enforce_knowledge_organization_resource`.
  Preserve normal branch behavior and all immutable/FK/CHECK/completion guards.
  There is no broad early `RETURN NEW`, trigger-disable or live-row rewriting.
- [x] Historical Document admission checks source Asset/version/association
  identity and owner/type agreement independently of current release/liveness;
  compare retained object/size/classification to immutable pin. Historical ready
  fragment INSERT requires exact admitted version and canonical digest/locator;
  UPDATE/DELETE stay forbidden. Note source admission checks exact historical
  source/fragment/locator/owner/kind/ordinals and seal binding, never substitutes
  a current head. Organization history checks exact typed endpoints and pinned
  versions with all natural uniqueness retained.
- [x] Assert actual runtime SQL still cannot append to ready fragments, sealed
  empty/nonempty sets, link deleted sources, change immutable pins or create
  organization edges on deleted endpoints. Wrong object, wrong source identity,
  cross-owner, missing fragments or unbound migration transaction also fail.
- [x] Run the new full file plus complete lifecycle/source/organization owners:

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_historical_admission_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_asset_lifecycle_guards_test.exs apps/singularity_storage/test/singularity/storage/note_source_set_sealing_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs --seed 215378 --warnings-as-errors
```

  SPEC then QUALITY, commit `feat(restore): validate history without weakening live guards`.

The Task6 owning gate includes the complete established Note source-set sealing
and Note source repository files, not selected cases. Replacing their source
guard requires direct retained-source/merge/order/seal regression coverage as
well as the original Document/organization owners. This is a verification-only
amendment; no established assertion or source file is changed. The isolated
private PostgreSQL wrapper serializes parent-owned execution. E2E is NOT RUN.

The first complete implementation run executed15 tests, with13 passing and
two failures. The new test's ten independent bound-immutability cases are
split into ten ExUnit tests under the unchanged default timeout, retaining
all15 semantic groups, both sealed-append cases, all native mutation/error/
phase/rollback assertions and fresh authenticated source/destination for
every operation. The full file will therefore execute24 tests. A content-free
owned SQL diagnostic must expose the complete-history adapter rejection before
any production correction; matched38 digests and seals alone are not acceptance.
If the source-backed private payload-variable ambiguity is confirmed, use a
new forward migration rather than editing accepted00300. The intended change
is only unambiguous local-variable binding, with its existing private ownership,
ACL, security, search path and value predicates preserved. Record actual RED,
the necessary repair amendment and full subsequent regressions/reviews.

The actual whole-history diagnostic94926 confirmed SQLSTATE42702 on the
private extraction payload validator. Create only additive forward
`20261011000410_knowledge_restore_work_validation.exs`: replace the existing
private `audit.knowledge_restore_payload_is_valid(core.outbox_events)` with
an unambiguous local resource variable while preserving all value predicates,
signature, ownership/ACL/security and pinned search path. Accepted00300 stays
unchanged. Include new00410 in full source SPEC and fresh separate QUALITY;
rerun the complete24-case historical file and all six established owning files,
private-admission/DDL/legacy regressions, static and frozen checks before commit.

## Task 7: Ordered V3 canonical import and source-set finalization

**Modify:** Storage `backup/restorer.ex`, `knowledge_preflight.ex`.
**Necessary retained-owner contract sync:** `backup/knowledge_preflight_test.exs`,
its obsolete ordinary-import dispatch expectation/name and the characterized
22-variant Document-state group's independent-case split; preserve every
binding denial, original mutation and canonical/no-temp/no-stage/no-publication
assertion, helpers and default timeout.
**Create:** `apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs`.
**Retain owners:** existing `backup/restore_import_test.exs`, `logical_v1_compatibility_test.exs`.
**Depends on:** Tasks 5 and 6.

- [x] Add RED import of the authenticated complete fixture into empty staging:
  canonical rows at the cut equal the independent oracle; source seals have
  exact membership digests/counts; no search/Oban/session/excluded receipts are
  imported. Verify V1/V2 still derive empty source sets, never Document rows.
- [x] Run all three full owning files before import changes. Implement explicit
  `logical_schema(3)` and replace destination locking/emptiness with the union
  of V1/V2/V3 tables plus established exclusions, derived seals and maintenance
  admission bookkeeping handled separately. A V1/V2 restore into a destination
  containing any V3 row must reject before writes.
- [x] Keep the existing migration-authority check and serializable/advisory saga.
  Authenticate/type-stage/preflight before canonical inserts; bind admission;
  insert established identities/opaque owner/key compatibility and generic
  resources/versions before Assets/envelopes/associations and typed knowledge.
  Preserve existing credential/wrapper/cleanup-principal transformations exactly.
- [x] Insert Document versions in their actual final state, then fragments and
  completed receipts; tags/assignments/relationships after their endpoints;
  all Note attachments/citations only after exact versions/fragments exist.
  Do not rely on the deferred V1/V2 Note INSERT seal trigger for V3; finalize each Note only
  after its entire set is present, including legitimately empty historical sets.
  Force the fixed ordinary/source/completion constraints while admission is
  still loading, keeping the admission final-check queue deferred. Then compare
  staged/canonical equality and graph/count/digests, mark validated, publish
  owned objects and mark imported. Historical Note source checks are deferred
  AFTER INSERT and need loading-state authority when they actually execute;
  validating first would incorrectly enter their ordinary live branch.
  Transaction-end independent validation remains enabled after explicit checking.
- [x] Add failure barriers before/after canonical insert, finalization, object
  publication and imported marker. Check full rollback/owned cleanup for known
  failure, identity-bound pending/imported recovery for uncertain commit and
  exact-manifest retries. Never resume a different manifest/destination or delete
  foreign objects. Imported verification also checks V3 rows and seal equality.
- [x] Run complete import/V1 files to GREEN:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs --seed 215378 --warnings-as-errors
```

  Actual owning32/0, repaired Preflight39/0, complete retained334 SQL/0,
  pure5/0 and downstream186/0 passed on repair2. Format/compile/xref passed with
  zero cycles and frozen56+Task6+source receipts match. Formal actual NONAUTHOR
  SOURCE SPEC and separate fresh QUALITY passed on the final repair2 receipt.
  Parent locally accepts the exact source; only the narrow local commit remains
  to execute and verify. Phase5/Tasks8–19 are not accepted. Local commit
  `feat(restore): import complete v3 history before sealing sources`.

### Task7 selected fixed constraints and bounded native-row replay

Source-derived prepublication forcing covers the32 surviving ordinary
deferrable content constraints below (19 FKs,13 constraint triggers). Confirm
this exact set against the isolated current catalog during Task7 testing;
never select caller SQL or dynamically include the admission final check.
Every literal is qualified with `content.` in the actual SET statement:

```text
resource_versions_resource_classification_fkey
resources_version_head_fkey
note_versions_parent_fkey
note_versions_merge_parent_fkey
note_conflicts_base_version_fkey
note_conflicts_canonical_version_fkey
note_conflicts_competing_version_fkey
note_conflicts_resolution_version_fkey
note_mutation_receipts_resource_fkey
note_mutation_receipts_version_fkey
note_mutation_receipts_conflict_fkey
document_versions_resource_version_fkey
document_import_receipts_version_fkey
document_fragments_document_version_fkey
note_attachments_note_fkey
note_attachments_target_fkey
note_citations_note_fkey
note_citations_fragment_fkey
note_source_set_seals_note_fkey
note_versions_aggregate_check
note_mutation_receipts_resource_check
resources_00_typed_head_check
note_versions_00_typed_head_check
document_versions_00_typed_head_check
document_import_receipts_completed_check
document_versions_completion_check
document_fragments_completion_check
note_attachments_source_set_check
note_citations_source_set_check
note_versions_source_set_seal_check
note_attachments_source_set_seal_check
note_citations_source_set_seal_check
```

The obsolete `resources_note_version_head_fkey` was dropped by the Document
aggregate migration; it is not in this set. Keep
`audit.knowledge_restore_final_check` deferred through publication and actual
COMMIT. Existing Restorer has only ALL DEFERRED, not an existing ALL IMMEDIATE
path; current per-Note automatic sealing is also deferred, not immediate.

The V3 importer uses a narrow original-caller/repo/backend/full-xid bound
iterator over fixed native staged columns and PK order, one row per SQL fetch.
Its table order is explicit and dependency-safe; no caller relation/projection/
ordering/SQL. Do not re-encode temporary native rows through the wire codec:
legal JSON framing expansion can exceed the16 MiB wire-record bound. Retain
outbox `OVERRIDING SYSTEM VALUE`, all established credential/wrapper/cleanup
pointer transforms, one-use Replay disposal and owned artifact ledgers.

Imported-marker retry is read-only V3 row/digest/seal verification, not a reuse
of pending-only admission or another transaction's historical write authority.
It must not reinsert canonical rows or publish unintended objects. This section
records read-only source preparation, not an executed Task7 gate or acceptance.

Task7 implementation seam: keep `KnowledgePreflight.stage/4` behavior unchanged
and add only internal `stage_for_verification/4` sharing a private fixed-mode
authenticated implementation. Verification mode writes only temporary typed
relations and incrementally checks raw ciphertext lengths/hashes; it invokes no
object stage/append/seal/finalize/abort operation. Bind an explicit staged
purpose and disallow verification-only input from `begin_restore`. The eager
native-row reducer accepts either purpose only on its exact original caller,
repo, backend and full transaction, with fresh staged-summary equality before
consumption and identity rechecks. Use a new helper savepoint after the original
preflight validation releases its own; no escaped cursor or caller relation.
Imported verification compares all38 canonical digests, exact seal identities/
counts with their staged membership and exact published inventory. V1/V2
imported verification rejects extra V3 tables as well as taking the union locks.
Full established preflight/admission owner tests remain required after changes.

Actual Task7 full retained Preflight execution characterized the sole obsolete
Task4 ordinary-import expectation: the authenticated V3 fixture is also a
populated destination. Now that explicit V3 import is implemented, rejection
is `conflict`, not unsupported `backup_invalid`. Synchronize only that exact
final code and test name; malformed binding/cut still returns `backup_invalid`
and all18 cases and side-effect denials remain required. This is a necessary
phase contract repair under continuous authorization, not a validation waiver.
The added23rd native-row case uses two genuine committed outbox events whose
UUID PK order differs from identity sequence order. The protected wire remains
sequence ordered; the native iterator must use fixed registry PK order for all
38 tables, with no outbox exception. Execute its causal RED before correction.

The complete16-owner repair1 gate then failed at the retained Document-state
group's default60-second budget. Its22 independent authenticated mutations,
fixture creation and cleanup shared one ExUnit case. Actual private checkpoint
records show DROP started only about0.5 seconds before forced cancellation;
the checkpoint itself lasted0.954 seconds, not a60-second DROP wait. A temporary
content-free monotonic probe preserved all18 cases and22 mutation assertions:
isolated execution ended normally0,30.9 seconds, with fixture5,757 ms,
all22 mutations complete at27,183 ms and cleanup complete at28,842 ms.
This isolates the repeated body from cleanup; it does not qualify the failed
complete gate or prove the historical PID cascade. Remove the probe and split
only these22 independent mutations into separately named, freshly authenticated
cases, preserving every original input/assertion/helper and default60-second
timeout. The original18 semantic groups become39 executable cases; no required
case is excluded. Freeze a new repair2 receipt and rerun the entire39-case
Preflight owner and complete16-owner gate (334 actual SQL/337 reported/3 pure
excluded), then separate pure5/downstream186/static/frozen and actual final
NONAUTHOR SPEC followed by fresh QUALITY. Repair1 failures remain historical
FAIL evidence; neither a timeout increase nor a smaller final gate is allowed.

## Task 8: Explicit V3 writer with complete retained-original closure

**Modify:** Storage `backup/exporter.ex`, complete `backup/logical_exporter_test.exs`.
**Create:** `apps/singularity_storage/priv/repo/migrations/20261011000500_knowledge_backup_read_grants.exs`,
`apps/singularity_storage/priv/repo/migrations/20261011000600_knowledge_backup_v3_guard.exs`,
`apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs`.
**Depends on:** Tasks 3 and 7; default remains V2 until Task 12.

- [ ] Add RED explicit `Exporter.snapshot_cut(repo, owner, 3)` and
  `Exporter.records(repo, cut, 3)` tests under the existing scoped WorkerRepo
  repeatable-read transaction. Default two-arity calls and explicit version 2
  still reject V3-only rows. All new version 1 writer requests and unknown
  writer versions unconditionally return `backup_unsupported`, including graphs
  with no V3-only rows. Do not add a version-selected guard exception before
  the complete explicit reader/import and this closure are present.
- [ ] Implement explicit version selection without changing default adapter
  signatures or Runtime.BackupVault. New `Exporter.snapshot_cut/3` and
  `Exporter.records/3` accept writer versions 2/3 only. V1 omits resource kind,
  current head, Note versions and conflicts, so it cannot safely write a current
  Note-only graph. Deny version 1/unknown before queries or streams; preserve
  V1 codec/golden/decoder/restore behavior unchanged. Choose supported schemas
  explicitly, encode every logical record with that version and prove the same snapshot for counts,
  streamed rows, evidence, raw objects and acknowledgement. Keep `cut` shape
  compatible with the frozen runtime adapter; version is the internal overload
  parameter, never inferred from table count. Default is 2 in this task.

```elixir
def snapshot_cut(_repo, _owner, version) when version not in [2, 3],
  do: {:error, Error.new(:backup_unsupported)}
def records(_repo, _cut, version) when version not in [2, 3],
  do: {:error, Error.new(:backup_unsupported)}
```

- [ ] Independently assert unconditional V1 writer denial for live Note-only,
  historical Note-only, conflicted Note-only and tombstoned Note-only graphs.
  Build these with existing `NoteFixtures.note!`, `insert_note_version!` and
  `note_with_conflict!` seams; tombstone with the established
  `Fixtures.with_owner` fixture transaction updating that Note's
  `content.resources.deleted_at`. Assert all eight V3-added tables have zero rows for each tested
  owner, then assert both cut and records requests deny version 1 even though
  explicit V2 export preserves the Note history. Also prove denial happens
  before any repository/object adapter call:

```elixir
assert {:error, %Error{code: :backup_unsupported}} =
         Exporter.snapshot_cut(:must_not_be_called, owner, 1)
assert {:error, %Error{code: :backup_unsupported}} =
         Exporter.records(:must_not_be_called, cut, 1)
```

- [ ] Add only required SELECT/read-function grants for the existing worker,
  preserving current owner RLS and hardened identity/conflict export seams.
  Runtime web/pre-auth/dispatcher get no backup/grant/admission authority.
  Completed import receipts are canonical; pending receipts reject. Knowledge
  mutation receipts, search, source-set seals, sessions, Oban and staging do not
  enter payloads. Outbox/job provenance and V2 column order remain intact.
- [ ] Compute inventory from the exact union:

```sql
SELECT asset_object_id FROM content.assets
WHERE vault_id=$1 AND state NOT IN ('deleted','pending_delete')
  AND asset_object_id IS NOT NULL
UNION
SELECT source_object_id FROM content.document_versions WHERE vault_id=$1
```

  Retain the existing live-Asset required-object predicates in the first branch;
  the second includes all states, heads and tombstones. Join retained available
  object/envelope evidence by exact owner/object, deduplicate/sort object ID.
  Missing required retained object is corruption. Do not demand a current Asset
  object pointer or unreleased association for Document history; absent allowed
  physically deleted Asset-only bytes are not invented. No foreign/extra objects.
- [ ] After the complete Task 7 import and this retained-object closure exist,
  forward-create `content.backup_has_unsupported_canonical_rows(uuid,integer)`
  in `20261011000600_knowledge_backup_v3_guard.exs`. Preserve the existing
  one-argument function and its legacy denial behavior unchanged. The overload
  requires the same current owner/`backup.create` authorization; version 1 and
  unknown versions are always unsupported, version 2 retains the existing
  legacy unsupported-content behavior, and explicit
  version 3 admits only supported complete canonical graphs. Validate known
  resource kinds, Document state/attempt shapes, supported storage/extractor
  formats, exact historical source identity and retained-object closure,
  ready fragment/citation/source-set completeness, completed receipt agreement
  and owner/classification bindings. Unknown/incomplete content stays fail-closed;
  no unconditional false or production write/grant activation is permitted.
- [ ] Route only explicit internal/test `Exporter.snapshot_cut(repo, owner, 3)`
  and `Exporter.records(repo, cut, 3)` selections through the new overload. Default two-arity
  adapters stay version 2 and use the unchanged original legacy guard. Add
  negative tests for unauthorized/foreign owner, unknown version/kind/format,
  malformed attempt/source shape, missing retained object, incomplete fragments/
  source sets/receipts and ciphertext/object-evidence disagreement, plus explicit
  version 1/2 rejection of live and tombstoned V3-only rows. Version 1 denial is
  unconditional and also covers Note-only history without V3 rows; version 2
  remains governed by its unchanged legacy content guard. This guard exists
  before Task 11 live qualification; Task 12 changes only qualified defaults.
- [ ] Test historical pins after source Asset cleanup, shared objects, tombstoned
  Documents, all states, old heads, unknown kind/format, missing object/shape,
  foreign owner and a head/tag mutation barrier after capture. Instrument lazy
  pages/chunks; consuming rows/objects after scoped transaction closure fails.
- [ ] Run explicit V3 exporter and full legacy exporter/identity/privacy owners:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/task14_backup_identity_export_security_test.exs --seed 215378 --warnings-as-errors
```

  Expected GREEN preserves default legacy rejection; SPEC then QUALITY, commit
  `feat(backup): stream complete v3 history and retained originals explicitly`.

## Task 9: Verify original plaintext evidence before rebuild/completion

**Modify:** Storage `backup/integrity_audit.ex`, Runtime `integrity_audit.ex`,
both complete integrity owning tests.
**Create:** `apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs`.
**Depends on:** Tasks 7 and 8.

- [ ] Add RED verifying every Document immutable `source_digest/byte_size`
  against the full inventory/material and authenticated plaintext hashes,
  including objects retained only by deleted/old Documents. A matching
  ciphertext hash with a wrong original plaintext digest must fail.
- [ ] Define Storage `IntegrityAudit.verify_document_sources(repo, binding,
  inventory, plaintext_hashes)` where binding is exact owner/manifest. Validate
  restored saga and equal inventory identity; hashes contain exactly one
  `%{asset_object_id: id, sha256: <<32 bytes>>}` per inventory entry in canonical
  order. Reject missing/duplicate/extra evidence, foreign owner/manifest, wrong
  size/hash and unverified materials. Asset-only entries remain valid. Recheck
  all ready historical extracted concatenation digests, independent of heads.
- [ ] Add a narrow call in Runtime `verify_final` after
  `validate_plaintext_summary/3` and before `rebuild_lexical/2`:

```elixir
:ok <- adapter_ok(call(adapters.search_rebuilder, :verify_document_sources,
  [search_binding(target), target.inventory, plaintext.plaintext_hashes]))
```

  The existing adapter is `{StorageIntegrityAudit, MigrationRepo}`, so the
  three supplied arguments reach Storage's four-arity helper with repo prepended.
  Require that callback in final-context adapter validation, update the full
  existing LexicalRebuilder fake and preserve its `rebuild` callback. Do not put plaintext hashes into the search summary
  or logs. Keep `PlaintextSummary`, RestoreIntegrityLease, rewrap/key handoff,
  ciphertext/Note/Asset verification, crypto and completion authority unchanged.
  Fakes gain an exact recording callback and prove order/denial, not live custody.
- [ ] Run full existing Runtime integrity tests and new Storage integration:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/integrity_audit_test.exs apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs --seed 215378 --warnings-as-errors
```

  Assert denial prevents rebuild/completion and maintenance destination stays
  unpublished. No claim of rollback of an already committed import/rewrap.
- [ ] Obtain SPEC then fresh QUALITY on the precise compatibility addition,
  report frozen-substrate files unchanged, commit
  `feat(restore): verify retained document originals from authenticated evidence`.

## Task 10: Rebuild unified search and reconcile interrupted extraction/work

**Modify:** Storage `backup/integrity_audit.ex`, `backup/reconciler.ex`,
`unified_search_restore_test.exs`, `restore_reconciliation_test.exs`.
**Create:** `apps/singularity_storage/test/singularity/storage/backup/document_restore_reconciliation_test.exs`.
**Retain:** Runtime extraction reconciler/restart contracts unchanged.
**Depends on:** Task 9.

- [ ] Add RED stable search comparison for restored live ready Document heads
  and Notes, old/deleted/non-ready suppression and retained historical citation
  fragments. Seed stale derived rows; rebuild twice and compare exact stable
  kind/resource/version/fragment tuples, locators/text/IDs and summary digest.
- [ ] Extend `IntegrityAudit.rebuild_locked` to enumerate owner resource IDs in
  stable order, clear stale projections and call
  `content.reconcile_search_resource_internal(owner, resource_id)` for current
  Note/Document heads, preserving established Asset metadata rebuilding.
  Canonical rows must not change and no search payload is imported.
- [ ] Extend `Reconciler.event_job_type/1` and validation for exactly
  `document.extraction_requested`→`document_extract`, and
  `document.ready/deleted/restored`→`document_projection`, using current Phase 2
  envelope allowlists/provenance/owner/epoch rules. Retired/terminal work is
  cleared appropriately; unknown events/extra payload keys remain errors.
  Ready/failed/unsupported retire redundant extraction work; stale generation/
  head/destructive events retire; current live pending retains one valid
  extraction request/wake. Deleted pending work remains undispatched.
- [ ] Restore an extracting snapshot with its exact generation/job/start/deadline
  and no fragments; do not create a running process or alter deadline/state.
  After canonical-cut equality is asserted, drive the existing guarded periodic
  recovery with a deterministic clock/barrier past its deadline. Expect the
  existing invalidation/new-generation behavior, not a newly invented job or
  custody bypass. Invalid historical authorization retires work and requires
  ordinary authenticated retry. Reconcile/rebuild retry is idempotent.
- [ ] Keep dispatch stopped until validation, complete rebuild and completion
  pass. Preserve Task 8's V1 writer-denial tests and the explicit V2 unsupported
  tests in `unified_search_restore_test.exs`; do not erase them when default changes.
- [ ] Run complete Storage owners plus unchanged Runtime recovery files:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs apps/singularity_storage/test/singularity/storage/restore_reconciliation_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_reconciliation_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs --seed 215378 --warnings-as-errors
```

  SPEC then QUALITY, commit `feat(restore): reconstruct unified search and document work`.

## Task 11: Qualify complete V3 saga, malformed rejection and legacy restoration

**Create:** `apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs`,
`apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs`.
**Modify:** `apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex`
  only knowledge fixture/oracle stages; preserve existing crypto/operator tests.
**Retain owners:** Runtime backup/restore files and all legacy restore fixtures.
**Depends on:** Tasks 7–10, including Task 8's explicit version-aware guard.

- [ ] Add RED live composition through established backup, authenticated bundle,
  Restorer, existing rewrap/integrity lease and completion in disposable databases.
  The explicit writer version 3 is the test adapter; production default stays 2.
  Compare every canonical row at the cut before recovery, all IDs/source sets/
  locators/digests/receipts/conflicts/tombstones and original binary bytes; then
  compare public search after lawful recovery. Test empty clean destination and
  supported disposable replacement staging while active source data is unchanged.
- [ ] Add independent malformed cases for duplicate PK/unique keys, extra/missing
  rows/objects, mixed versions, classification/owner/kind/head/ancestry/conflict
  errors, ordinal gaps, locator/fragment/digest tampering, unsupported format,
  receipt disagreement, ambiguous source association, foreign object and
  truncated/changed ciphertext/plaintext source mismatch.
- [ ] Add deterministic fault barriers at authentication/preflight, canonical
  insert, staged publish, commit uncertainty, rewrap, ciphertext verification,
  durable-work reconciliation, authenticated plaintext/Document verification,
  search rebuild and completion in the existing saga order. Assert rollback/owned
  cleanup before/import failure and unpublished maintenance graph after import
  failure. Resume exact-manifest retry only; verify zero duplicated rows,
  objects, source seals/jobs. Never assert distributed transaction rollback.
- [ ] Extend the independent restore oracle with known synthetic binary originals,
  all-state history/organization/source pins and negative corruption; reuse
  established real crypto and custody. Retain V1 golden `.backup` bytes, explicit
  V2 fixtures and every old assertion. No new Vault lifecycle behavior/test.
- [ ] Run full focused saga/legacy owners, then the sole independent restore task:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs apps/singularity_runtime/test/singularity/runtime/restore_vault_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.restore
```

  Expected GREEN is actual live qualified explicit V3 plus V1/V2 restoration, not fake-only
  wire success. Record exact outputs/cleanup, SPEC then QUALITY; commit
  `test(restore): qualify complete v3 saga and malformed rejection`.

## Task 12: Switch default to V3 only after writer and restore qualify together

**Modify:** Storage codec/exporter default selection and their complete tests;
  existing legacy guard tests; active backup operator guidance.
**Depends on:** Tasks 8–11 GREEN and independent SPEC/QUALITY for the combined boundary.

- [ ] Add RED default-backup test asserting logical 3 with and without Document
  content, full 38-table vector and qualified restore. Retain the Task 1 V2
  default characterization as historical evidence; amend the current-default
  test only now and add explicit legacy-version writer rejection cases. The
  version 1 Document-negative case below remains unconditional writer denial;
  version 2 rejects because the graph contains unsupported V3-only rows. Retain
  every Task 8 Note-only V1 denial after switching the default.

```elixir
assert LogicalRecordCodec.default_version() == 3
assert LogicalRecordCodec.tables() == LogicalSchemaV3.tables()
for version <- [1, 2] do
  assert {:error, %Error{code: :backup_unsupported}} =
           Exporter.snapshot_cut(repo, owner_with_document, version)
end
```

- [ ] Reuse the complete Task 8 version-aware guard after its explicit V3 writer
  and Tasks 9–11 integrity/live-restore qualification pass. Retain the original
  one-argument legacy V2 content guard, unconditional new-V1-writer denial and
  all unknown/incomplete V3 negatives; V1 codec/golden/decoder/restore stay intact.
  This task creates no duplicate or no-op guard migration. Default selection
  switches only now; production canonical writes/grants remain closed.
- [ ] Change codec/default writer selector and typespec to 3 together; production
  BackupVault still calls the same Storage adapter interface and receives the
  same outer cut/bundle/crypto structures. Add all default new-write round trips.
  Update tests asserting absent worker SELECT only for the precise new approved
  read grants, retaining denial of other roles and all mutation/custody grants.
- [ ] Run full codec/verifier/exporter/unified legacy files and live saga/oracle
  again because default selection changed. Add unknown/incomplete V3 negatives
  as well as explicit legacy unsupported positives/negatives. Record guard
  behavior before/after and frozen source hashes.
- [ ] SPEC then QUALITY, commit `feat(backup): select qualified logical v3 for new backups`.
  This changes backup output only; production canonical write guards remain closed.

## Task 13: Capture portable live-head closure and bounded metadata spool

**Create:** `apps/singularity_storage/lib/singularity/storage/knowledge_export/repository.ex`,
`apps/singularity_storage/test/singularity/storage/knowledge_export/repository_test.exs`.
**Depends on:** Tasks 2 and 6; can precede Task 12 once file ownership is disjoint.

- [ ] Add RED authenticated repeatable-read `Repository.capture/4` and
  `Repository.next_page/3` tests. `capture(repo, authenticated_scope, options,
  spool)` streams metadata into the operation-owned spool, returns bounded
  selection indexes/descriptors and closes the snapshot before binary delivery.
  Repository never receives keys/leases or caller owner scope.
- [ ] Select all live Note/Document heads; closure follows each selected Note's
  sealed attachments/citations to exact live Note versions recursively and exact
  live Document/Asset version bindings. Mark visited before traversal; frontier
  sorts `(kind, resource_id, version_id)`; two historical pins remain separate.
  Enforce all total/per-item limits without successful truncation.
- [ ] Include tags/assignments and relationships with at least one selected
  endpoint. Authorized other endpoint/pinned-version descriptors remain metadata
  only and do not expand edge traversal or bodies. Note parent/merge ancestry
  recursively contributes metadata-only descriptors, no ancestor bodies/source
  traversal. Every declared source/endpoint/version must resolve in manifest.
- [ ] Existing authorized deleted/unavailable Note source resolution yields
  readable metadata/allowed selected-fragment locator with null files/offsets.
  Optional tombstones add owner metadata/version/source/edge descriptors only;
  no deleted body/original authority. Live missing bytes/ambiguity/denial is a
  hard whole-export failure, never converted to metadata-only success.
- [ ] Capture a barrier, move heads/change tags after snapshot, and prove spool
  metadata/pins stay from the cut. Wrong-owner RLS/current context, forged scope,
  unsealed sets, corrupt fragment/source closure and bounds reject. Cursor is
  internally bounded; page max 500, no full content collection.
- [ ] Run full repository integration file:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_export/repository_test.exs --seed 215378 --warnings-as-errors
```

  SPEC then QUALITY, commit `feat(export): capture exact live source closure in private spool`.

## Task 14: Exact immutable source reads using unchanged request custody

**Create:** `apps/singularity_runtime/lib/singularity/runtime/knowledge/export_read.ex`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs`.
**Modify:** Storage `knowledge_export/repository.ex` for exact source binding reads.
**Depends on:** Task 13; frozen DownloadLease/KeyCustodian files remain unchanged.

- [ ] Add RED `ExportRead.document(runtime, session, captured_binding)` and
  `ExportRead.asset(runtime, session, captured_binding)` tests. Exact old version
  of a live Document returns original bytes even when its source Asset is deleted;
  deleted Document, changed pin/object/size/hash and unknown storage format deny.
- [ ] Implement owner-free exact binding lookup under `OperationScope`:
  specified live Document resource + immutable version + independently retained
  source object/digest/size; max 64 MiB; exact envelope generation. Use unchanged
  request custody `purpose: :document_source`, `access: :request`, session/
  principal/owner epochs, required `asset.read`, exact version/object/generation.
  Use existing `DownloadLease.read_document_chunk/2` and empty authentication.
  Authenticate complete preflight then bounded delivery; revoke leases in `after`.
- [ ] For Asset pins prove one exact version/resource/Asset/object association,
  retain live Asset authorization and existing bounded delivery; never call the
  eager `:all` bytes variant. Revalidate binding before lease and at completion.
  No worker/extraction identity, RestoreIntegrityLease or caller adapter.
- [ ] Reject revocation/unlock loss between chunks and after preflight; exact
  historical pin must not follow current head. Fake tests prove callback order/
  bounds/revoke; live test uses real existing custody and source SQL binding.
  A fake lease cannot establish live correctness.
- [ ] Run pure and isolated live owners:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs --seed 215378 --warnings-as-errors
```

  Stop this task if satisfying exact reads would require frozen custody/lease
  semantics changes; report evidence and continue only independent valid work.
  SPEC then QUALITY, commit `feat(export): read captured sources with existing request custody`.

## Task 15: Private bounded writer, byte verification and portable manifest

**Create:** `apps/singularity_storage/lib/singularity/storage/knowledge_export/writer.ex`,
`apps/singularity_storage/test/singularity/storage/knowledge_export/writer_test.exs`,
`docs/formats/portable-knowledge-v1.md`.
**Depends on:** Tasks 2 and 13.

- [ ] Add RED filesystem tests for `Writer.open/1`, `append_file/3`,
  `append_manifest_record/3`, `finish/1`, `abort/1`, `entries/2`, `read_chunk/3`.
  Root is application-configured, never caller input. Writer state has only
  private paths/IO/hash/byte counters; receives authenticated plaintext chunks,
  never keys, wrappers, leases or crypto material.
- [ ] Use random operation-owned directories mode 0700, exclusive files mode
  0600 and no symlink traversal/overwrite. Validate UUID paths/case-fold collisions;
  append at most 64 KiB, update hash/size incrementally, stream one JSON record
  at a time through exact canonical record order. Use separate private array
  spools if needed to assemble the exact ordered top-level arrays without
  collecting the encoded manifest. Enforce bytes/records/deadline ceilings.
- [ ] Write notes/<resource>--<version>.md; document original with fixed extension;
  extracted `.txt` concatenates canonical fragment text with **no delimiter**.
  Compute UTF-8 byte offsets, not character counts, and exact extracted digest.
  Non-ready Documents have original/state and no fabricated extracted file.
  Asset source pins use assets/<resource>--<version>.bin. Verify each canonical
  original/body/text digest separately from rendered-file hashes.
- [ ] Assemble manifest last with exactly `format/version/selection/resources/
  versions/fragments/tags/tag_assignments/relationships/attachments/citations/files`
  as design §5 specifies. Stable arrays/keys/UTC timestamps/no export-clock
  timestamp make identical captured selections byte-identical. `files` excludes
  manifest.json; returned artifact descriptor includes its size/hash separately.
  Verify every listed file/reference/size/hash, then atomic rename to complete
  within the same staging root. An error returns no completed artifact.
- [ ] Test disk-full injection, checksum mismatch, canceled writer, malformed
  record, symlink/collision, existing path, chunk/page size observers, exact
  binary/empty/Unicode originals, UTF-8 offsets, metadata-only descriptors and
  deterministic bytes. Never buffer whole original/fragment set/JSON in memory.
  Cleanup only the operation directory, preserving a sentinel neighboring root.
- [ ] Document every record field/null/availability, selection scope, readable
  source links, metadata-only tombstones/history, bounds and privacy without
  treating the manifest as logical backup or an all-history recovery API.
- [ ] Run the complete pure filesystem file and Core owners to GREEN:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/knowledge_export/writer_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs --seed 215378 --warnings-as-errors
```

  SPEC then QUALITY, commit `feat(export): stream private portable files and verified manifest`.

## Task 16: Runtime orchestration, session-bound handles and public API

**Create:** `apps/singularity_runtime/lib/singularity/runtime/knowledge/export.ex`,
`apps/singularity_runtime/lib/singularity/runtime/knowledge/export_artifact.ex`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs`.
**Modify:** Runtime `api.ex`, `application.ex`; Web architecture contracts for
  exact reviewed additive blocks only; no web feature/controller/UI.
**Depends on:** Tasks 13–15.

- [ ] Add RED API/handle tests for these exact public operations and internal
  leading-config variants following the existing Api testing convention:

```elixir
export_knowledge(session, %{include_tombstones: false})
knowledge_export_entries(session, handle, cursor)
read_knowledge_export_chunk(session, handle, path, index)
close_knowledge_export(session, handle)
```

  Returns opaque verified handle; pages contain only relative path/media/size/
  SHA-256, at most 500 entries; read only manifest-listed path/ordinal chunks
  at most 64 KiB. Handles expose no host path. Unknown options, destinations,
  caller owners/adapters, absolute paths and invalid ordinals reject.
- [ ] Implement `Export.run/3` resolving current authenticated session, deriving
  owner, checking existing Note/Asset read requirements, capturing snapshot,
  transferring exact originals/Note/text and manifest, verifying output and
  reauthorizing completion. Keep metadata transaction closed for transfer/client
  delivery. No new capability or Vault grant. Errors are content-free atoms/
  existing sanitized Error values; canary content never reaches logs/telemetry.
- [ ] Implement temporary `ExportArtifact` under existing supervisor/task seams,
  bound to original session/principal/owner/authorization epochs, with maximum
  15 minutes from creation. Monitor the requester only during generation:
  requester death before completion aborts and cleans the operation. Before
  returning a verified handle, hand completed ownership to a supervised artifact
  owner under existing supervision and remove the generation-request monitor. A
  short-lived request PID exiting after successful return must not destroy
  the handle. Its owning authenticated session can still read until explicit
  close, revocation, expiry, artifact-owner death or restart cleanup.
  Authenticate live owning
  session before entries and every chunk; handle possession is insufficient.
  Use monotonic deadline and deterministic test clock/barriers, no arbitrary
  sleeps or new durable queue/domain GenServer. Idempotent owner close revokes
  delivery and removes only its owned artifact.
- [ ] On revocation, loss of unlock, timeout/cancel, denied chunk, checksum,
  generation-requester death, artifact-owner death or startup leftovers, clean only recognizable
  export-owned directories below dedicated configured staging root and revoke
  outstanding leases. Test another owner's/operation's sentinel survives.
  Add two deterministic monitor-handoff tests: kill generation requester before
  completion and assert no handle/owned files; let requester exit after success
  and assert same-session manifest/chunk access remains valid until owner close.
- [ ] Extend architecture baseline contracts with exact Phase 5 block/context
  hashes and mutation/removal/duplication/relocation tests. Strip only exact
  approved additions before existing hashes; retain all Phase 2/3/4 and legacy
  runtime assertions. Add exact Phase 5 knowledge-registration attribution and
  unknown-operation/function-clause negatives. Parent inspects and reviews the
  necessary addition protocol before changing it. Never blanket-whitelist
  `Knowledge.Export` terms or replace a baseline with the current file hash.
  Task 0 and Task 1 did not pre-authorize stripping. Dependency graph
  remains seven applications, zero cycles.
- [ ] Run full API/artifact and architecture owners:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --seed 215378 --warnings-as-errors
```

  SPEC then QUALITY, commit `feat(export): deliver verified artifacts through authenticated runtime api`.

## Task 17: Independent live portable acceptance, privacy and bounded streaming

**Create:** `apps/singularity_runtime/test/singularity/runtime/knowledge_export_live_test.exs`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_export_privacy_test.exs`.
**Modify:** fixture support only for additional selection/fault barriers.
**Depends on:** Task 16.

- [ ] Add live RED acceptance materializing entries/chunks through Runtime.Api
  into a separate test-owned directory. Parse manifest with Jason and verify
  every ordinary relative Markdown link/footnote, manifest reference, path/hash/
  byte count and UTF-8 offset without any database lookup/proprietary URI.
  Original PDF/plain/Markdown/empty bytes equal independent source oracles.
- [ ] Cover duplicate titles, malicious labels/paths, version cycles, two pins
  to historical versions, relationship metadata endpoints, parent/merge metadata,
  source Asset deletion with live Document retention, optional tombstones and
  already-unavailable authorized source metadata. No deleted body/original file
  or unselected conflict/history body appears. Live missing/denied source fails.
- [ ] Use barriers to move heads/change tags after capture (unchanged captured
  output), delete/revoke selected live source before transfer/completion (whole
  failure and cleanup), revoke between delivered chunks (denial), expire/cancel/
  kill requester during generation or artifact owner, restart scavenging and disk exhaustion.
  Assert no handle exists before completion and no partial artifact advertised.
- [ ] Instrument page/chunk sizes and spool counters; assert <=500 rows,
  <=64 KiB content chunks and fixed total limits. Memory observation must use
  deterministic retained-size/counter bounds plus a large fixture, not a flaky
  wall-clock/GC threshold. Inspect production code for eager `:all` reads and
  full-export `Enum.to_list`/JSON encoding. Identical captured selections produce
  identical manifest and file bytes, even with different handle/time IDs.
- [ ] Capture logs/telemetry/errors/Inspect with user-content canaries; no bodies,
  titles, source labels, storage references, principal/session/key/job fields
  leak. Artifact plaintext is private user content, mode 0700/0600.
- [ ] Run all live portable/privacy and existing Markdown integration owners:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_live_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_privacy_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_export_integration_test.exs --seed 215378 --warnings-as-errors
```

  This is scoped real runtime acceptance, not browser E2E. SPEC then QUALITY,
  commit `test(export): prove portable bytes source closure and denial cleanup`.

## Task 18: Exact local 0.1 migration fixture and V3 restore upgrade acceptance

**Create:** `apps/singularity_storage/test/fixtures/upgrade/v0.1.0/migrations/`
  containing the exact 22 historical Storage migration files,
`apps/singularity_storage/test/fixtures/upgrade/v0.1.0/source.json`,
`apps/singularity_storage/test/support/legacy_upgrade_fixtures.ex`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_upgrade_live_test.exs`.
**Modify:** `apps/singularity_storage/test/support/migration_test_environment.ex`
  only to accept a trusted test-owned frozen migration path when needed.
**Depends on:** Tasks 11, 12 and 17.

- [ ] Reproduce local source identity checks (no remote release verification):

```sh
git rev-parse 'c49dc0aeda1d0115b20ff291f0da658f7e558b43^{commit}'
git tag --points-at c49dc0aeda1d0115b20ff291f0da658f7e558b43
git show -s --format='%H %s' c49dc0aeda1d0115b20ff291f0da658f7e558b43
git ls-tree -r --name-only c49dc0aeda1d0115b20ff291f0da658f7e558b43 apps/singularity_storage/priv/repo/migrations
```

  Expected local commit exact SHA, tag `v0.1.0`, subject
  `merge: verify release exporter equivalence`, 22 migration files through
  `20260818000100_create_private_markdown_notes.exs`. Store commit ID, source
  path, ordered filename/blob hashes and SHA-256 in `source.json`; frozen files
  are copied through reviewed patches, never current migration substitutes.
- [ ] Write RED fixture identity and upgrade live test. A current ceiling alone
  is insufficient because a historical migration file might have drifted.
  Run frozen release migrations into allocated database A using the established
  table-owner/bootstrap/extension test lifecycle. Populate legitimate legacy
  Notes/history/conflicts, live/deleted Assets/bytes/associations/durable work
  using the historical schema; capture immutable IDs/digests and binary bytes.
- [ ] Apply all current forward migrations through Phase 5 to the same database
  without reset. Assert legacy data unchanged, derived source seals complete,
  current RLS/grants/constraints, seven apps and new knowledge tables empty
  where expected. Characterize failures before any necessary narrow forward
  repair; never rewrite the frozen fixture or released migration for GREEN.
- [ ] Add current knowledge through qualified existing contracts in test-only
  scope, create default V3, restore into fresh current database B with a new
  owned root and supported maintenance saga, then compare full canonical
  history/source sets/digests/original bytes and public search. Prove database A
  unchanged and B not published until verification completes.
- [ ] Run full upgrade live file plus existing migration and V1/V2 owners:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_upgrade_live_test.exs apps/singularity_storage/test/singularity/storage/knowledge_migration_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs --seed 215378 --warnings-as-errors
```

  Record both isolated identities/cleanup; SPEC then QUALITY, commit
  `test(upgrade): qualify exact v0.1 schema through v3 restore`.

## Task 19: Complete permitted README gate, independent acceptance and local handoff

**Modify:** `docs/verification/2026-10-11-phase-5-acceptance.md`, master release
  plan Phase 5 checklist, Phase 5 design/plan status, active guidance and
  `docs/formats/portable-knowledge-v1.md` only when supported by actual evidence.
**Depends on:** every preceding task GREEN, all independent findings resolved.

- [ ] Reconcile the entire design §§1–12 and master Phase 5 deliverables against
  source and tests, not completion checkboxes alone. Hash frozen Vault/custody/
  key/capability/policy/crypto files and compare baseline; report any narrow
  knowledge compatibility seam explicitly. Confirm new migration-only helpers
  have no runtime authority and production canonical-write guards remain closed.
- [ ] Stage/commit only reviewed implementation/docs so the required clean
  worktree check is meaningful. Record exact tested source; no history rewrite,
  merge/push/version/tag/release/deploy or production data operation.
- [ ] Run the complete permitted README gate from the exact checkout. Use the
  established isolated cluster environment; do not expose connection secrets.
  E2E is explicitly omitted under user deferral, never executed or claimed PASS:

```bash
(
set -euo pipefail
trap 'devenv processes down' EXIT
devenv up -d
devenv processes wait --timeout 120
devenv shell -- bash apps/singularity_storage/priv/repo/bootstrap_roles.sh
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix deps.get
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix deps.unlock --check-unused
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix compile --warnings-as-errors
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.restore
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix npm.verify
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix duskmoon_bundler.js.check
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix npm.run test:js
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix duskmoon_bundler.build singularity_web --tailwind
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix xref graph --format cycles --fail-above 0
nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/e2e.yml .github/workflows/release.yml .github/workflows/docker-image.yml
git diff --check
git status --short
test -z "$(git status --porcelain)"
)
```

  Expected all executed commands exit 0; xref `No cycles found`, seven apps.
  Any executed gate failure blocks acceptance: diagnose/repair and rerun
  affected checks plus required gate, preserving assertions and repair counters.
  Service/database/object-root cleanup is verified, not inferred from trap text.
- [ ] Obtain final independent SOURCE SPEC review against exact tested commit,
  full design/master checklist, source/migration/test diffs and actual report.
  Then obtain fresh QUALITY review for security, streaming/memory, lifecycle,
  idempotency, SQL authority, maintenance visibility and frozen boundaries.
  Separate reviewers/findings and actual dispositions; no advisory review is
  implementation acceptance. New changes require relevant regression evidence.
- [ ] Record exact tested commit, docs handoff commit separately, migrations,
  changed files/test counts/commands/exit codes, wire hashes/original byte
  comparisons, upgrade source manifest, independent reviews and cumulative
  repair counts. Mark E2E **NOT RUN — explicitly deferred local development**;
  final browser/release acceptance unresolved. Check master Phase 5 deliverables
  only after their actual evidence passes. Record no Vault feature work,
  no production canonical-write activation/backfill and no publication.
- [ ] Commit the evidence-only handoff as
  `docs: record qualified phase five export and backup acceptance`, recheck clean
  worktree/finished owned commands, and stop Phase 5 work at the accepted local
  boundary. Automatic next-phase preparation requires its own design/plan and
  worktree; this plan contains no Phase 6 implementation or publication action.

## Coverage and acceptance ledger

| Design/master obligation | Planned task/evidence |
| --- | --- |
| Active governance, exact base, E2E deferral and frozen boundaries | 0, 19; full governance suites and frozen hashes |
| Exact 38-table/367-column V3 with immutable V1/V2 | 1, 3; literal schema/goldens and all 87 DDL columns |
| All canonical history/conflicts/tombstones/receipts/source pins | 3, 7, 8, 11; independent full-row comparison |
| Retained originals after source Asset deletion/shared objects | 3, 8, 9, 11; exact inventory and authenticated plaintext bytes |
| Preflight before mutation and historical SQL admission | 4–7; typed staging, role counterproofs and deferred equality |
| Complete immutable Note source-set sealing | 6, 7; empty/nonempty history and append denial |
| Saga failures/retry and no partial graph exposure | 7, 9, 11; pre/import rollback vs post-import maintenance assertions |
| Search rebuild and abandoned extraction recovery | 10, 11; stable results and existing guarded recovery |
| Explicit V3 fail-closed guard and default only after qualification | 8, 11, 12; writer accepts 2/3 only, V1/unknown denied including Note-only history, default V2 until 12, V2/incomplete V3 rejection retained |
| Portable exact live-head closure/metadata tombstones | 2, 13, 14, 17; no deleted-byte authority |
| Ordinary Markdown/original/text/non-secret manifest | 2, 15, 17; independent parser/path/hash/byte oracle |
| Bounded private artifact/session revocation/cleanup | 13–17; actual page/chunk counters and deterministic fault barriers |
| Local historical 0.1 upgrade and fresh V3 restore | 18; exact frozen 22 migration fixture, no reset |
| V1/V2 compatibility and complete permitted local gate | 1, 7, 11, 18, 19; independent fixtures/oracle and actual gate |
| No production writes, no publication, no Vault feature work | All tasks, final 19 audit; E2E remains NOT RUN |

No task is marked completed in this draft. No implementation/test acceptance
or current V3/portable-export behavior is claimed. Independent design review
may require concrete amendments; any requirement to change frozen custody/key/
capability/policy semantics is a boundary blocker, not an omitted implementation
step or permission to silently work around it.
