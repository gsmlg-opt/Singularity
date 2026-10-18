# Phase 5 Task12 Default Logical V3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [x]) syntax for tracking.

**Goal:** Select the jointly qualified logical V3 writer for new backups while preserving explicit V1/V2 historical compatibility and fail-closed unsupported writes.
**Architecture:** Reuse LogicalRecordCodec.default_version as the only implicit writer selector; preserve all versioned codec/guard/restore implementations. Real worker/default backup and native authenticated restore witnesses prove both Document and no-Document cases.
**Tech Stack:** Elixir1.18.4/OTP28.5.0.3, seven Mix applications, existing private PostgreSQL17.10 and approved script/devenv wrapper.

---

## Current execution snapshot — 2026-10-18

Tasks1–4 and the first four Task5 source/evidence steps below are complete.
All required scoped writer/restore and architecture/static gates passed;
actual combined17-owner SOURCE SPEC then NEW distinct SOURCE QUALITY CLOSED
PASS before four exact-path local source commits:

- 3205a9616b275ef3162b0543a70b8e9da44e6135
- 427381875f7c2b27938bf79b5779f6e45c990515
- 35db21e0971374b768794afab5585ecf0e78d056
- 4d832e91a5cf093ecd081be7b4fd515426b21f7d

The [actual source/gate handoff](../../verification/2026-10-18-phase-5-task12-handoff.md)
records complete command/raw/source bindings and preserved failures. Earlier
candidate/failure descriptions below are historical, not current verdicts.
Final documentation-contract check, documentation SPEC/NEW QUALITY, docs-only
commit and literal clean closure are PENDING at this snapshot. The final two
Task5 boxes deliberately remain unchecked until their actual later facts are
recorded in the separate ignored documentation-handoff-closure receipt.
Phase5 remains unaccepted; Task16 BLOCKED_DESIGN/unwaived, Task17NOTGO and
Task18 dependencies remain. E2E NOT RUN/manual-only; no publication or Vault work.

## Baseline and responsibilities

Design: docs/superpowers/specs/2026-10-18-singularity-v0.2-phase-5-task12-default-v3-design.md.
Baseline HEAD e24b2b2b10f4bb2d21d7600ad8bdc2f931237d56, source parent
4a2e007649ab2d7c62aa72ee84bf1d2de0a93802, clean branch
codex/v0.2-phase-5-export-backup in the existing project-local Phase5 worktree.
Task11 actual closure receipt and qualified source hashes are in design authority;
they are prerequisites, not a claim that changed Task12 bytes have passed.
Root owns this design/plan, guidance, fresh ignored GO/pins/raw/ledgers and Git.
One Sol implementer owns the17 persistent source/test paths in design section4;
the additional sole-restore task owner is restricted to one reviewed binding.
No parallel implementation writers; independent read-only work may be disjoint.
The worker must not mutate production selectors until root supplies meaningful
actual RED evidence. Root alone runs VMs and commits after actual reviews.

## Task 1: Review and seal the bounded transition

- [x] Verify actual Task11 documentation closure SHA48a250ce, source21/committed
  blobs, docs32, raw52, frozen56, baseline HEAD/indexEMPTY/literal clean checks.
- [x] Save this design and plan only; perform inline self-review for scope,
  explicit legacy preservation, exact selectors, interface signatures and gates.
- [x] Independent DESIGN SPEC reviews both complete documents and necessary
  actual source context; NEW distinct DESIGN QUALITY follows actual SPEC PASS.
  Root records their real verdicts; no implementation or Native before both.
- [x] Commit only these two reviewed planning files locally, then seal actual
  Task12 planning HEAD, expected status, source16/guidance6/current docs hashes,
  historical pin transitions and unchanged56/control rows. Never rewrite old
  original guards/manifests or claim their fixed old HEAD/status still passes.

## Task 2: Write current-default RED contracts without production changes

**Modify/Test:** the12 Storage/Runtime test/support paths in design section4.
  Both architecture test owners remain unchanged until Task4; the same source
  worker owns their later synchronization after parent guidance updates.
**Read-only:** both production selector paths until actual meaningful RED.

- [x] Add LogicalSchemaV3 alias to LogicalRecordCodecTest and a complete default
  contract using existing cut_attrs/object_attrs/valid_row helpers:

```elixir
test "default V3 encodes the complete schema and rejects a legacy-size cut" do
  assert LogicalRecordCodec.default_version() == 3
  assert LogicalRecordCodec.tables() == LogicalSchemaV3.tables()
  counts = List.duplicate(0, 38)
  attrs = cut_attrs(table_count_vector: counts)
  assert {:ok, cut} = LogicalRecordCodec.encode_cut(attrs)
  assert {:ok, ^cut} = LogicalRecordCodec.encode_cut(attrs, 3)
  assert {:ok, %{logical_version: 3, table_count_vector: ^counts}} =
           LogicalRecordCodec.decode(cut.type, cut.payload)

  for schema <- LogicalSchemaV3.all() do
    {primary_key, values} = valid_row(schema)
    assert {:ok, row} = LogicalRecordCodec.encode_row(schema.table, primary_key, values)
    assert {:ok, ^row} = LogicalRecordCodec.encode_row(schema.table, primary_key, values, 3)
    assert {:ok, %{logical_version: 3, table: table}} =
             LogicalRecordCodec.decode(row.type, row.payload)
    assert table == schema.table
  end

  assert {:ok, object} = LogicalRecordCodec.encode_object(object_attrs())
  assert {:ok, ^object} = LogicalRecordCodec.encode_object(object_attrs(), 3)
  assert {:ok, %{logical_version: 3}} =
           LogicalRecordCodec.decode(object.type, object.payload)
  assert_invalid(LogicalRecordCodec.encode_cut(cut_attrs()))
end
```

- [x] Preserve every existing V2 byte/vector/bounds/schema assertion by making
  its intentional V2 encoding explicit. The complete pre-V3 codec test section
  uses the following arities, while the old default-only clauses now assert3:

```elixir
LogicalRecordCodec.encode_cut(attrs, 2)
LogicalRecordCodec.encode_row(table, primary_key_values, ordered_column_values, 2)
LogicalRecordCodec.encode_object(attrs, 2)
```

  Keep cut_attrs default30 and all exact V1/V2/V3 goldens/schema/hash assertions.
  Do not alter explicitly versioned unknown/mixed-format negatives.
- [x] LogicalSchemaV3Test current default/tables becomes3/V3; the appended-row
  case proves implicit encode_row equals explicit3 for all eight definitions
  while retaining BOTH explicit1/2 invalid assertions. LogicalV1CompatibilityTest
  changes only its current-default assertion to3; all golden/read/ordinal/PK
  checks remain. KnowledgeBackupFixturesTest changes only the two default
  assertions930/1131 to3; fixed legacy_v2 still explicitly2 with every old check.
- [x] LogicalExporterTest preserves legacy30-table/denial contracts with explicit2
  in its existing cut/records helpers and direct legacy calls. Keep the existing
  text_export_result :default/2/3 matrix genuine, not rewritten to2. Unprivileged,
  cross-owner, stream binding, canary, ordering and no-drift assertions remain.
  Label formerly implicit V2-only claims accurately. UnifiedSearchRestoreTest's
  legacy backup_cut helper calls snapshot_cut(repo,owner,2).
  BackupConcurrencyTest's legacy inventory cut at569 uses explicit2; leave the
  actual default read-committed invalid caller and all concurrency assertions.
- [x] LogicalV3ExporterTest retains every V1 Note-only writer denial and explicit
  V2 history/conflict/tombstone positive. Compare production-default records
  against explicit3, independently of the preserved explicit2 assertions.
  Run the complete independent38-table/367-column SQL/ciphertext oracle for
  BOTH :default and3 selectors through these test-local helper clauses:

```elixir
defp snapshot(repo, owner, :default), do: Exporter.snapshot_cut(repo, owner)
defp records(repo, cut, :default), do: Exporter.records(repo, cut)
```

  Preserve existing explicit-version helper clauses. For live/tombstoned V3
  graphs assert default3 successful full export and explicit1/2 snapshot AND
  records denial on a truthful same-connection cut. Preserve unknown/NoCalls,
  incomplete graph, role/grant, mutation, nonsecret and lazy binding tests.
- [x] KnowledgeBackupRestoreFixture V3Exporter observation wrapper delegates
  to default arity2 calls; no shadow3 path remains on the actual job:

```elixir
Exporter.snapshot_cut(repo, vault_id)
Exporter.records(repo, cut)
```

  Keep synchronous capture_worker_cut!/receive_cut and wrapper/module identities.
  Rename only obsolete default denial helper/result. Inside its existing real
  authorized repeatable-read callback use:

```elixir
with {:ok, cut} <- Singularity.Storage.Backup.Exporter.snapshot_cut(repo, session.vault_id) do
  cut = Map.put(cut, :manifest_id, Ecto.UUID.generate())
  Map.new([1, 2], fn version ->
    {:error, %{code: :backup_unsupported}} =
      Singularity.Storage.Backup.Exporter.snapshot_cut(repo, session.vault_id, version)
    {:error, %{code: :backup_unsupported}} =
      Singularity.Storage.Backup.Exporter.records(repo, cut, version)
    {version, :backup_unsupported}
  end)
end
```

  Require the exact success map after ScopedRepo.transact; on current2 RED its
  default cut rejection must be diagnosed as the missing default3 selector, not
  accepted as legacy guard evidence. Store legacy_backup_errors and update the
  live/oracle consumers to exact %{1=>:backup_unsupported,2=>:backup_unsupported}.
  All same-cut SQL, crypto, source references, sentinels, public search, cleanup,
  configuration/lifecycle and malformed retry/rollback assertions remain.
- [x] NativeTextBackupRestoreLiveTest changes default title/version2 to3 and
  adds the following test-local adapter at the existing logical_verifier seam:

```elixir
defmodule ObservedLogicalVerifier do
  alias Singularity.Storage.Backup.LogicalBundleVerifier
  def init(_context, binding), do: LogicalBundleVerifier.init(binding)
  def handle_event(_context, state, event), do: LogicalBundleVerifier.handle_event(state, event)
  def finish(context, state, manifest) do
    result = LogicalBundleVerifier.finish(state, manifest)
    case result do
      {:ok, _cut} -> send(context.observer, {context.reference, :wire_cut, state.cut})
      _error -> :ok
    end
    result
  end
end
```

  Set logical_verifier to {ObservedLogicalVerifier,%{observer:self(),reference:reference}}.
  ObservedRestorer imports ExUnit.Assertions and, before the unchanged genuine
  import, consumes/asserts the authenticated witness:

```elixir
assert_received {^reference, :wire_cut, wire_cut}
assert wire_cut.logical_version == 3
assert wire_cut.manifest_id == input.cut.manifest_id
assert wire_cut.vault_id == input.cut.vault_id
assert length(wire_cut.table_count_vector) == 38
assert Enum.drop(wire_cut.table_count_vector, 30) == List.duplicate(0, 8)
```

  Native verifier validates actual vector counts; do not claim independent SQL
  counting here. Do not consume replay, authenticate again, replace crypto,
  change lease timeouts, or demand a globally single finish. Preserve exact
  originals, identities/listing, manifest and sequential lifecycle assertions.
- [x] Worker self-reviews complete diffs, confirms codec/exporter files still
  byte-identical to baseline, then closes ALL commands and returns to root.
- [x] Root seals test-only source and runs these exact RED vectors, each with
  its own raw, ordinary post and closing integrity checks:

```sh
mix test apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs --seed 215378 --warnings-as-errors
```

```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs --seed 215378 --warnings-as-errors
```

  Expected: actual tests fail for missing current default3/default cut rejection;
  all selected cases are genuinely invoked. No compilation/environment failure
  counts as RED. Preserve actual counts/exclusions and all other failures.

## Task 3: Minimal production transition and scoped GREEN qualification

**Modify:** LogicalRecordCodec and Exporter only. No migration/grant/config.
The following native fixture repair changes an already-owned test path, not
another production owner.

### Native fixture compatibility repair after candidate failure

Native280/281 passed30 pure cases. Native282 executed the exact three-owner
integration vector: Storage51/0, Runtime52/1; natural2, own post283 natural0/EMPTY.
The sole no-Document restore returned :invalid with unchanged native test bytes.
Full raw SHA256 is f70fa11822e4848dfd51b430deddff37d6d6109058b53c9c60d408b5d8cd1235.
This failed candidate does not qualify the default or authorize guidance changes.

- [x] Independently review the design's native fixture-composition amendment:
  actual SPEC then NEW distinct QUALITY before repair; record both real verdicts.
- [x] In NativeTextBackupRestoreLiveTest.restore_context/3, replace only the
  search_rebuilder binding {StorageIntegrityAudit, MigrationRepo} with
  {Singularity.Storage.Backup.KnowledgeIntegrityAudit, MigrationRepo}.
  Preserve the genuine ciphertext/completion auditors and every original assertion.
  Runtime requires the real verify_document_sources callback even for zero
  Document rows; do not weaken that rule or invent a no-op test callback.
- [x] Root seals the one-test-context delta and runs this complete focused owner
  with its own ordinary post and closing source/frozen/HEAD/index/status/owned0:

```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs --seed 215378 --warnings-as-errors
```

  Native282 is the actual failing characterization; focused GREEN must establish
  this source-supported causal hypothesis. Preserve FAIL if it does not pass,
  diagnose the next boundary, and count actual failed Sol causal repair attempts.
  Then rerun the exact original three-owner integration vector and all complete
  owner/restore/architecture/static gates below on final bytes; focused success
  alone never substitutes for them.

### Fresh large-import diagnostic after complete-owner failure

Native284/285 established the one-binding native repair with one actual test,
zero failures and own ordinary postEMPTY. Complete unit286/287 executed64 of322
registered cases,258 excluded, zero failures. Complete integration288 executed
258 of322,64 excluded, with one large-import60000ms timeout; own post289 was
natural0/EMPTY. Raw447lines/29767bytes SHA256
282788d13da7e1878b6e8fc3c71cf5fc48ab84927a4f8dc0c2e3cb820c705f31 was read
unfiltered through its natural2 footer. Task12 qualification remains FAIL.
Cleanup stack alone does not establish destination callback success or cause.

- [x] Independent SPEC then NEW distinct QUALITY review the complete amended
  design/plan and actual failing source/evidence. All reviewer commands close
  before instrumentation or any VM. Record actual verdicts, not forecasts.
- [x] Record clean baseline SHA and exact inverse of ONLY
  apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs.
  One Sol worker owns the temporary observation; all other source stays exact.
  Do not change shared fixtures, resource-owner protocol or production code.
- [x] Wrap only the large test's existing source/destination calls with existing
  ResourceOwner.with_checkpoint/2 and fixed source/destination labels. Mark
  source entry/return, callback entry/empty/import/full-oracle/dimensions/return,
  and original exception KIND before the existing cleanup can mask it.
  Preserve original return and re-raise original kind/reason/stack unchanged.
  A monitored writer receives only static phase/stage atoms and elapsed time,
  terminates on test death or wrapper completion, and never delays checkpoints
  or takes resource ownership. No content, identifiers, exception text, sampling,
  sleep, barrier, signals, forced cleanup or timeout/selection changes.
- [x] Root seals all25 current paths (original24 plus diagnostic-only owner),
  exact named historical transitions, frozen56, HEAD/index/status/environment.
  Root launches this whole owner ONCE, unchanged seed and warnings policy:

```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs --seed 215378 --warnings-as-errors
```

- [x] Wait for natural closure, read complete safe raw/footer, record actual
  counts and static phase evidence. Run its own unchanged ordinary residual
  post and closing current/frozen/HEAD/index/status/owned0 guard. A GREEN
  diagnostic is not proof of a repair or a replacement for complete gates.
- [x] Remove instrumentation by exact inverse and require original whole-file
  SHA before qualification. Preserve any observed failure honestly. Diagnose
  actual phase evidence; if insufficient, amend a bounded next observation.
  Any necessary causal repair receives source-backed design/plan and actual
  independent review, not another routine approval request. This issue starts
  at zero failed causal repair rounds. No deadline or input-size relaxation.
- [x] Rerun relevant complete gates on FINAL noninstrumented bytes, including
  full17 unit/integration routes, original three-owner confirmation, sole
  restore and later architecture/static gates. Do not update default guidance
  or claim Task12 acceptance while a required gate fails.

### Sole-restore fixture compatibility after final restore failure

Final noninstrumented292/293 unit64 actual/258 excluded and294/295 integration
258 actual/64 excluded passed, covering322 registered cases. Original three-owner
296/297 passed103 actual, confirmation only. Sole restore298 then failed at
restore_vault :invalid, natural1, own post2990/EMPTY. Full safe raw377lines,
29343bytes, SHA256c493dbc42e55bc6c2792283068e9f6d2d5e1d025b201baa81dd716cbac3e5018
was read through its footer. Later destination/V1/knowledge families were
NOT REACHED. Do not infer bad password argv from the generic public CLI message.

- [x] Actual amendment SPEC then NEW distinct QUALITY inspect complete design/
  plan, genuine production-default producer, existing Runtime V3 callback rule,
  genuine knowledge adapter and unchanged task contracts. No VM/source change
  before both closed PASS; make a docs-only planning commit and actual binding.
- [x] One Sol worker changes ONLY search_rebuilder in the existing test-only
  apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex:

```elixir
search_rebuilder: {Singularity.Storage.Backup.KnowledgeIntegrityAudit, MigrationRepo}
```

  Preserve audit/ciphertext adapters, genuine authentication and leases, default
  producer, V1 fixture/assertions, single cleanup, dynamic oracle and public CLI.
  No producer pin toV2 or assertion/deadline/selection change. Read-only baseline
  whole-file SHA320b5ae99d6687692d8bf39daaade648c7bb5733717367b83ef5c43f3bad1cac
  and inverse single-line substitution prove the exact delta.
- [x] Root seals26 current paths (original24, restored diagnostic and new Mix
  task), all1860 old rows unfiltered with named transition, frozen56/control
  invariants, HEAD/index/status/toolchain/privatePG/owned0. The immutable17-owner
  test-selection control is unchanged; the new Mix task is not a new test owner.
- [x] Run the WHOLE existing task contract owner, then WHOLE sole restore:

```sh
mix test apps/singularity_runtime/test/mix/tasks/singularity.test.restore_test.exs --seed 215378 --warnings-as-errors
```

```sh
mix singularity.test.restore
```

  Each has its own direct launch, complete safe raw/footer, natural closure,
  ordinary residual post0/EMPTY and current integrity guard. A successful first
  restore stage does not qualify the task: default destination comparison,
  genuineV1 and all downstream knowledge positive/negative families must pass.
- [x] Record actual causal result without erasing298FAIL or module warnings.
  Starts Sol0/Astra0. On failure diagnose/count actual failed causal rounds;
  retain full-task requirement and established escalation, no approval loop.
- [x] Rerun final complete17 unit route after this source change. Preserve
  prior full17 integration/original-three-owner byte-bound evidence only for
  unaffected paths; run all remaining architecture/static gates on final bytes.
  Any broader delta requires relevant reruns. Combined qualification and later
  actual SOURCE SPEC/NEW QUALITY precede guidance/commit claims as specified.

- [x] After actual meaningful RED, the production transition remains only:

```elixir
# apps/singularity_storage/lib/singularity/storage/backup/logical_record_codec.ex
@default_version 3
@spec default_version() :: 3
# apps/singularity_storage/lib/singularity/storage/backup/exporter.ex
def snapshot_cut(repo, vault_id),
  do: snapshot_cut(repo, vault_id, LogicalRecordCodec.default_version())
def records(repo, cut), do: records(repo, cut, LogicalRecordCodec.default_version())
```

- [x] Worker checks complete owned diff and formats ONLY changed .ex/.exs paths
  through mix format after root schedules its owned command; no unscoped rewrite.
  Record formatting as an implementation action, not a successful check.
- [x] Root freezes exact final source bytes and runs the same RED vectors once
  as GREEN characterization, then the complete owner routes below. Every gate
  has a separate fresh ordinary post and current source/frozen/owned0 check.

### U: Complete unit route for all17 mixed test owners

```sh
mix test apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs apps/singularity_storage/test/singularity/storage/backup_concurrency_test.exs apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_bundle_verifier_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs apps/singularity_runtime/test/mix/tasks/singularity.test.restore_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_cut_live_test.exs --seed 215378 --warnings-as-errors
```

### I: Complete integration route for the same17 owners

```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs apps/singularity_storage/test/singularity/storage/backup_concurrency_test.exs apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_bundle_verifier_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs apps/singularity_runtime/test/mix/tasks/singularity.test.restore_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_cut_live_test.exs --seed 215378 --warnings-as-errors
```

These routes intentionally retain normal integration selection. Excluded cases
are NOT passes; together they must account for the full listed owners. No
line-only, tag-only or max_cases substitution qualifies these complete gates.

### S: Sole independent restore after complete focused owners

```sh
mix singularity.test.restore
```

Keep genuine current-default and historicalV1 restoration, existing explicitV2
coverage in the complete17 routes, and every UUID/canonical/mixed knowledge
positive/late-corruption negative. The guarded oracle exercises real defaults.
No separate fake restore task, browser run or double-counted restore credit.

## Task 4: Current authority and architecture-contract synchronization

**Modify:** parent owns six guidance/master paths; the same source worker owns
the two architecture test owners only for the selector's current statement.

- [x] After default writer/restore GREEN, replace current default2 preparation
  notices with this exact active statement, preserving all other prohibitions:

    New backups use logical V3 after combined writer and restore qualification.
    Explicit V2 retains its fail-closed unsupported-canonical guard.

- [x] Apply to active AGENTS/README/guide notices and master active authority/
  design status. Link this Task12 design/plan and completed Task11 closure.
  Keep old Task1/Task8/Task11 baseline/default2 narratives historical. Do not
  edit Task11 reviewed snapshots or alter Vault freeze/phase dependencies.
- [x] Update the exact current-default literal assertions and raw active-prose
  mutation value in KnowledgePhase1ContractTest and NotesScopeContractTest.
  Every existing outside/quote/comment/fence/indent/header-order mutation must
  still fail when its new active statement is moved/hidden. No deletion or
  reclassification of old required assertion families.
- [x] Docker upgrade guidance states new logical3, retained historical1/2 reads
  and still-required operator PG/filesystem snapshot, no production acceptance.
- [x] Root runs complete architecture owners and final static gates:

```sh
mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs --seed 215378 --warnings-as-errors
```

```sh
env MIX_ENV=dev mix format --check-formatted
```

```sh
env MIX_ENV=dev mix compile --warnings-as-errors
```

```sh
env MIX_ENV=dev mix xref graph --format cycles --fail-above 0
```

Each is a separate direct invocation with its own ordinary residual post.
Changing documentation/literal tests does not requalify earlier source runs;
source changes after final GREEN require relevant gates rerun on final bytes.

## Task 5: Independent reviews, local commits and true handoff

- [x] Account for all actual gates, complete raw footers/hashes, selections and
  warnings, each ordinary post0/EMPTY and frozen/control transitions. No new
  production writes, schema/migrations, Vault feature or E2E. Phase5 remains
  unaccepted until its later complete permitted README/phase gate.
- [x] Actual combined SOURCE SPEC on every changed complete source/diff and
  primary evidence, then NEW distinct SOURCE QUALITY only after actual PASS.
  Address actionable findings under continuous authority; do not defer ordinary
  failures to approval. Count actual failed Sol repair rounds separately from
  expected RED/design work; escalate after two failures/evidenced impasse.
- [x] Parent explicitly stages source owners only and verifies index hashes;
  make small local source commits by responsibility, final selector message
  feat(backup): select qualified logical v3 for new backups. Verify exact
  parent/path/blob binding after each; do not include unrelated user files.
- [x] Record actual Task12 commands/raw hashes/results/source commits and
  historical pin deltas in docs/verification/2026-10-18-phase-5-task12-handoff.md.
  Source/plan/current authority status updates must not claim their own pending
  docs review/commit/clean result; a separate ignored post-review receipt
  .devenv/phase5-task12-default-v3-documentation-handoff-closure.json records
  actual later facts without self-changing already-reviewed bytes.
- [ ] Independent documentation SPEC then NEW distinct QUALITY on the exact
  changed/new docs and necessary context; close every command. Explicit docs-only
  commit after both actual PASS. Verify source/doc Git blob hashes and literal:

```sh
git diff --check
git status --short
test -z "$(git status --porcelain)"
```

- [ ] Write actual closure only after success, then automatically continue the
  next valid in-scope task. Task16 strict ALL-leases remains blocked/unwaived;
  do not evade it or claim Task17/18/Phase5/release acceptance. E2E NOT RUN and
  manual-only; final browser/release acceptance remains required.
