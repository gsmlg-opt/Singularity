# Phase 5 Task 11 Native Knowledge V3 Saga Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Qualify explicit V3 through genuine public original publication, public backup, authenticated native restore/rewrap/integrity, exact canonical history, unified public search, and observed decrypted bytes of every retained original, with complete malformed/fault/retry and V1/V2 regression evidence.

**Architecture:** Compose existing production interfaces without changing their contracts. A separately owned test fixture publishes genuine originals and appends canonical knowledge history; an independent literal SQL oracle observes the actual worker snapshot and the imported graph before rewrap/recovery. Transparent test adapters provide deterministic barriers while delegating real crypto, repositories, filesystem publication, custody, and verification.

**Tech Stack:** Elixir/OTP umbrella, ExUnit, Ecto/PostgreSQL, existing Oban GenericWorker/WorkerScope, LocalFilesystemAdapter, ChunkedAEAD, BackupKeyLease/RecoveredVaultKey/RestoreIntegrityLease, private disposable database/resource ownership, parent-controlled devenv verification.

---

## Preparation status and execution boundary

Date: 2026-10-15. Status: PLAN AMENDMENT — independent SPEC/QUALITY pending.
Governing design:
[Native knowledge V3 saga](../specs/2026-10-15-singularity-v0.2-phase-5-knowledge-v3-saga-design.md).
The parent fully read and self-reviewed the entire1334-line ignored author draft,
SHA256 `c8e63e69204224e3998f2ec9acfe626b67dcbb9620248908fa6cec9077982769`,
then synchronized this formal plan with the current design and prerequisite
handoff. This is one qualification project, not permission to redesign separate
storage, custody, search, or Vault subsystems.

Worktree: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup`.
Branch: `codex/v0.2-phase-5-export-backup`. Source inspected at
`5f388ac88d5603b8c29df3a592d0843885a30912`; parent then reported prerequisite
documentation handoff commit `239c1c322b47c095004690154f691fcf85eeff81`, with
all qualified code bytes unchanged. Task 10 and the native-text prerequisite are
parent-reported locally qualified; prerequisite handoff is
`.devenv/phase5-task11-native-text-handoff.md`, reported SHA-256
`4f4b209b07c88c4c081ea81277fb120f32730e284bf7a944de40f2b427b8b32a`.
These are handoff facts, not Task 11 execution by this author.

The parent has submitted the exact design §13 amendments together in master
design §8, master design §11 and master plan Task11. Before implementation,
independent full SPEC followed by NEW distinct fresh QUALITY must accept the
updated Task11 design, this plan, and all three amendments. Design review does
not replace later source review. The continuous authorization selects the
recommended real-publication/graph-only approach; it does not remove these gates.

Default logical version stays **2**. Task 12 still requires Tasks 8–11 GREEN and
combined-boundary review. Task 16 BOTH strict ALL-leases remains independently
UNSATISFIED / UNWAIVED / BLOCKED_DESIGN. There is no Vault feature/semantic work,
new key/custody authority, production reference rewrite, migration, dependency,
role/grant change, journal, new unwrap, key bridge, distributed rollback claim,
merge, push, version, tag, release, deployment, production activation/backfill,
or E2E authorization. E2E MUST NOT RUN.

All proposed checks below are NOT RUN. Expected outcomes are requirements, not
reported results. Every required test remains required after a failure. Retain
failed evidence and diagnose; do not skip, weaken or reclassify an assertion.
Implementation and review can use independent agents only when the parent has
assigned disjoint ownership; every native invocation remains exclusively owned
and serialized. This draft author performs no delegation or implementation.

## Locked file map

| File | Responsibility |
| --- | --- |
| NEW `apps/singularity_runtime/test/support/knowledge_backup_restore_fixture.ex` | Source/destination lifecycle, real bootstrap/publication, graph construction call, V3 worker adapter, transparent restore/integrity observers, native fault closures |
| NEW `apps/singularity_runtime/test/support/knowledge_restore_oracle.ex` | Independent task entry and explicit expected identity/cardinality, canonical, search, original-byte and corruption assertions; no ExUnit-file invocation |
| NEW `apps/singularity_storage/test/support/knowledge_canonical_oracle.ex` | Literal independent 38-table/367-column/PK projection, read-only worker-snapshot import, committed destination observation |
| MODIFY `apps/singularity_storage/test/support/knowledge_backup_fixtures.ex` | Add graph-only public entry and private work parameterization only; preserve old `seed!/1` and every existing caller |
| NEW `apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs` | Native UUID/canonical/mixed full sagas, exact cuts, all original bytes/public search, native material negatives and Runtime barrier/retry cases |
| NEW `apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs` | Independent malformed protocol matrix, actual SQL/insert/seal/publication/commit-resolution failures and exact Storage replay |
| MODIFY `apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex` | Additive guarded dynamic knowledge oracle after existing legacy cleanup; no change to old flow or assertions |
| Parent-owned eventual Task 11 design/plan, master design/master plan and verification handoff | Reviewed requirements, three synchronized retry amendments, actual commands/results and acceptance boundaries |

All Runtime/Storage support modules above except `KnowledgeBackupFixtures` are
NEW proposed test APIs. Existing `NativeAssetFixture`, ResourceOwner, production
crypto/custody/lease/search/backup/restore files and all old tests remain intact.
Runtime and Storage support compile only in MIX_ENV=test. No new production
module may depend statically on those support modules.

## Task 1: Seal prerequisites and turn the design into executable contracts

**Files:** Parent-owned design/plan/master amendments only; no source edits yet.

- [ ] Read the final prerequisite handoff and confirm its source SHA, final doc
  commit, actual SPEC/QUALITY, frozen controls and required test results; check
  the live worktree/index against the parent's expected inventory. Preserve
  unrelated work. A mismatch is a handoff finding, not permission to reset.
- [ ] Apply all three exact replacement paragraphs/checklist text from design
  §13 in the parent-owned tracked documents, including the distinction between
  successful supported SAME-destination retry and RESTART into a fresh target.
  Do not edit Task 12 dependencies or Task 16.
- [ ] Obtain independent SPEC then new distinct QUALITY on the full updated
  design, plan and three amendments. Resolve findings before source GO. Record
  review scope/SHA; no source implementation on a partial design pass.
- [ ] Establish this non-content stage trace as an explicit test contract:

```elixir
@restore_order [
  :admitted, :authenticated, :preflight, :canonical_insert, :source_sets_sealed,
  :staged_publish, :import_committed, :rewrapped, :ciphertext_early,
  :durable_work, :ciphertext_final, :plaintext_typed, :document_sources,
  :unified_rebuild, :integrity_complete, :restore_complete
]
```

  Record counts/identifiers only, never body/keys/passphrases/raw wrappers. SQL
  and real adapter counters establish stages unavailable at outer ports. A
  missing event fails the causal case; a synthetic event cannot prove a stage.
- [ ] Parent records SOURCE GO only after every preceding dependency/review.
  Later source failures stay within the documented diagnosis/repair protocol:
  ordinary Sol diagnosis; at most two repair-and-validation rounds for the same
  task; parent-managed Astra escalation only at the actual gate. New complete
  qualification tests can characterize PASS directly because production paths
  already exist. Missing helpers, compile errors and staging defects are FAIL,
  not causal RED. Before changing enforced fixture/Mix-task behavior, retain a
  meaningful focused failing contract for that change; never manufacture RED
  with an unrelated compile failure or no-op stub.

## Task 2: Independent literal canonical SQL oracle

**Create:** Storage `test/support/knowledge_canonical_oracle.ex`.
**Test:** New Runtime and Storage owning test files, `async: false`.

- [ ] Add the focused contract that the new oracle has exactly 38 tables,
  367 columns, fixed first-30 prefix, explicit PKs and owner filters. Compare its
  literal metadata to the wire registry only as a test assertion; the oracle
  must not construct its expected metadata by calling either registry.

```elixir
alias Singularity.Storage.Backup.KnowledgeCanonicalOracle, as: Canonical

test "canonical oracle owns the fixed complete projection" do
  projection = Canonical.projection()
  assert length(projection) == 38
  assert Enum.sum(for {_table, columns, _pk} <- projection, do: length(columns)) == 367
  assert elem(hd(projection), 0) == "identity.people"
  assert elem(Enum.at(projection, 29), 0) == "content.note_conflicts"
  assert elem(Enum.at(projection, 30), 0) == "content.document_versions"
  assert elem(List.last(projection), 0) == "content.relationships"
  assert Enum.all?(projection, fn {_table, columns, pk} ->
           pk != [] and Enum.all?(pk, &(&1 in columns))
         end)
end
```

- [ ] Stage the complete support implementation with this contract before its
  native invocation; the new qualification contract may PASS directly. A
  projection/count mismatch is a meaningful failed contract; an absent module
  is a compile/staging FAIL requiring repair, not acceptance evidence. Run the
  complete owner, not a regex-selected substitute.
- [ ] Define the following literal `@projection` and `projection/0`. This is
  the complete expected wire-column inventory, not the derived seal/search or
  transient credentials/session schemas. Do not generate this module from V3,
  V2, codecs, `KnowledgeRestoreDigest` or manifest-selected table metadata.

```elixir
@projection [
  {"identity.people", ~w(id display_name metadata inserted_at updated_at), ~w(id)},
  {"identity.accounts", ~w(id person_id status metadata inserted_at updated_at), ~w(id)},
  {"identity.credentials", ~w(id account_id normalized_login revoked_at inserted_at), ~w(id)},
  {"identity.principals", ~w(id account_id kind authorization_epoch revoked_at metadata inserted_at updated_at), ~w(id)},
  {"core.capabilities", ~w(id name inserted_at), ~w(id)},
  {"core.vaults", ~w(id kind authorization_epoch locked metadata inserted_at updated_at object_cleanup_principal_id), ~w(id)},
  {"core.vault_members", ~w(principal_id vault_id clearance revoked_at inserted_at updated_at), ~w(principal_id vault_id)},
  {"core.principal_capabilities", ~w(principal_id vault_id capability_id revoked_at inserted_at), ~w(principal_id vault_id capability_id)},
  {"identity.devices", ~w(id principal_id vault_id label revoked_at inserted_at updated_at), ~w(id)},
  {"core.key_domains", ~w(id vault_id classification kind state inserted_at updated_at), ~w(id)},
  {"core.vault_key_versions", ~w(id vault_id generation state algorithm activated_at retired_at inserted_at), ~w(id)},
  {"core.vault_key_wrappers", ~w(id vault_id vault_key_version_id account_id generation inserted_at), ~w(id)},
  {"core.domain_key_versions", ~w(id vault_id key_domain_id vault_key_version_id generation state algorithm wrapped_key inserted_at), ~w(id)},
  {"core.domain_dedup_key_wrappers", ~w(id vault_id key_domain_id domain_key_version_id algorithm wrapped_key inserted_at), ~w(id)},
  {"content.resources", ~w(id vault_id classification title deleted_at metadata inserted_at updated_at kind current_version_id), ~w(id)},
  {"content.resource_versions", ~w(id resource_id vault_id classification revision inserted_at updated_at), ~w(id)},
  {"content.asset_objects", ~w(id vault_id key_domain_id classification lookup_digest ciphertext_hash plaintext_byte_size ciphertext_byte_size storage_ref format_version lifecycle retained_until deleted_at deletion_evidence inserted_at updated_at lifecycle_revision delete_claim_token delete_claimed_at), ~w(id)},
  {"content.assets", ~w(id vault_id resource_version_id asset_object_id classification state state_revision failure_code retryable failed_operation attempt inserted_at updated_at), ~w(id)},
  {"content.asset_key_envelopes", ~w(id vault_id asset_object_id domain_key_version_id key_domain_id classification algorithm key_generation wrapped_dek inserted_at), ~w(id)},
  {"content.asset_metadata", ~w(id asset_id resource_version_id vault_id classification projection_version original_filename declared_media_type detected_media_type plaintext_byte_size pdf_header_version image_width image_height extraction_state extractor_version completed_at inserted_at updated_at), ~w(id)},
  {"content.resource_assets", ~w(resource_version_id asset_id vault_id classification released_at inserted_at), ~w(resource_version_id asset_id)},
  {"content.source_references", ~w(id vault_id resource_version_id principal_id classification kind observed_at original_filename declared_media_type byte_size idempotency_key_digest inserted_at), ~w(id)},
  {"content.tombstones", ~w(id vault_id asset_id principal_id classification reason retention_metadata deleted_at), ~w(id)},
  {"audit.events", ~w(id vault_id actor_kind principal_id anonymous_fingerprint system_principal_name operation result classification correlation_id target_type target_id metadata occurred_at inserted_at), ~w(id)},
  {"core.outbox_events", ~w(id sequence event_type idempotency_key vault_id principal_id required_capability vault_authorization_epoch classification correlation_id causation_id expected_entity_revision envelope_version payload occurred_at claim_token claimed_until runner_job_id delivered_at inserted_at updated_at principal_authorization_epoch retired_at retirement_reason), ~w(id)},
  {"jobs.job_submissions", ~w(id vault_id outbox_event_id classification idempotency_key job_type runner_job_id inserted_at updated_at), ~w(id)},
  {"jobs.job_progress", ~w(id vault_id submission_id classification state processing_revision checkpoint_version checkpoint inserted_at updated_at), ~w(id)},
  {"jobs.effect_receipts", ~w(id vault_id submission_id classification effect_key result entity_revision inserted_at), ~w(id)},
  {"content.note_versions", ~w(resource_version_id resource_id vault_id classification title markdown created_by_principal_id parent_version_id merge_parent_version_id inserted_at), ~w(resource_version_id)},
  {"content.note_conflicts", ~w(id resource_id vault_id classification base_version_id canonical_version_id competing_version_id state resolution_version_id created_at resolved_at), ~w(id)},
  {"content.document_versions", ~w(resource_version_id resource_id vault_id classification source_asset_id source_resource_id source_resource_version_id source_object_id source_digest source_byte_size media_type title created_by_principal_id state attempt_generation extraction_adapter extraction_format extracted_text_digest detected_language failure_code attempt_finished_at inserted_at attempt_job_id attempt_started_at attempt_deadline_at), ~w(resource_version_id)},
  {"content.document_fragments", ~w(id resource_id resource_version_id vault_id classification ordinal text digest locator inserted_at), ~w(id)},
  {"content.document_import_receipts", ~w(vault_id principal_id mutation_id request_fingerprint state resource_id version_id inserted_at), ~w(vault_id principal_id mutation_id)},
  {"content.note_attachments", ~w(note_resource_version_id id note_resource_id vault_id classification target_resource_id target_resource_version_id target_kind ordinal role label inserted_at), ~w(note_resource_version_id id)},
  {"content.note_citations", ~w(note_resource_version_id id note_resource_id vault_id classification source_resource_id source_resource_version_id fragment_id locator ordinal inserted_at), ~w(note_resource_version_id id)},
  {"content.tags", ~w(id vault_id classification display_value normalized_key created_by_principal_id inserted_at), ~w(id)},
  {"content.resource_tags", ~w(resource_id tag_id vault_id classification inserted_at), ~w(resource_id tag_id vault_id)},
  {"content.relationships", ~w(id vault_id classification source_resource_id target_resource_id target_resource_version_id type created_by_principal_id inserted_at), ~w(id)}
]
def projection, do: @projection
```

- [ ] Implement independently scoped SELECT construction with literal filters
  below. The owner is actual bootstrap `%{account_id:,principal_id:,vault_id:}`;
  identity principal export includes only this account's vault members, matching
  the source contract without invoking its SECURITY DEFINER export function.
  Select credentials by account, people through account.person_id, capabilities
  through assignments in this scope, and only the active account wrapper.

```elixir
alias Singularity.Storage.{MigrationRepo, SafeSQL}

defp scope("identity.people", owner, _cut),
  do: {"source.id IN (SELECT person_id FROM identity.accounts WHERE id=$1)",
       [Ecto.UUID.dump!(owner.account_id)]}
defp scope("identity.accounts", owner, _cut),
  do: {"source.id=$1", [Ecto.UUID.dump!(owner.account_id)]}
defp scope("identity.credentials", owner, _cut),
  do: {"source.account_id=$1", [Ecto.UUID.dump!(owner.account_id)]}
defp scope("identity.principals", owner, _cut),
  do: {"source.account_id=$1 AND EXISTS (SELECT 1 FROM core.vault_members m WHERE m.principal_id=source.id AND m.vault_id=$2)",
       [Ecto.UUID.dump!(owner.account_id), Ecto.UUID.dump!(owner.vault_id)]}
defp scope("core.capabilities", owner, _cut),
  do: {"EXISTS (SELECT 1 FROM core.principal_capabilities a WHERE a.capability_id=source.id AND a.vault_id=$1)",
       [Ecto.UUID.dump!(owner.vault_id)]}
defp scope("core.vaults", owner, _cut),
  do: {"source.id=$1", [Ecto.UUID.dump!(owner.vault_id)]}
defp scope("core.vault_key_wrappers", owner, _cut),
  do: {"source.vault_id=$1 AND source.account_id=$2 AND EXISTS (SELECT 1 FROM core.vault_key_versions v WHERE v.id=source.vault_key_version_id AND v.vault_id=source.vault_id AND v.state='active')",
       [Ecto.UUID.dump!(owner.vault_id), Ecto.UUID.dump!(owner.account_id)]}
defp scope("core.outbox_events", owner, cut),
  do: {"source.vault_id=$1 AND source.sequence<=$2",
       [Ecto.UUID.dump!(owner.vault_id), cut.outbox_high_water_mark]}
defp scope(_table, owner, _cut),
  do: {"source.vault_id=$1", [Ecto.UUID.dump!(owner.vault_id)]}

defp identifier(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")
defp table_name(value), do: value |> String.split(".") |> Enum.map_join(".", &identifier/1)
defp value(_table, _column, %DateTime{} = value), do: DateTime.to_iso8601(value)
defp value(_table, _column, %NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
defp value("content.document_fragments", "id", value), do: value
defp value(_table, "fragment_id", value), do: value
defp value(_table, column, <<_::128>> = value) do
  if column == "id" or String.ends_with?(column, "_id"),
    do: Ecto.UUID.load!(value), else: value
end
defp value(_table, _column, value), do: value

defp rows_on_connection(repo, owner, cut) do
  Map.new(@projection, fn {table, columns, pk} ->
    {predicate, parameters} = scope(table, owner, cut)
    select = Enum.map_join(columns, ",", &("source." <> identifier(&1)))
    order = Enum.map_join(pk, ",", &("source." <> identifier(&1)))
    result = SafeSQL.query!(repo,
      "SELECT #{select} FROM #{table_name(table)} source WHERE #{predicate} ORDER BY #{order}",
      parameters)
    rows = Enum.map(result.rows, fn values ->
      columns |> Enum.zip(values) |> Map.new(fn {column, v} ->
        {column, value(table, column, v)}
      end)
    end)
    {table, rows}
  end)
end

def read_committed!(repo, owner, cut) do
  {:ok, result} = repo.transaction(fn ->
    SafeSQL.query!(repo, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])
    SafeSQL.query!(repo, "SET LOCAL ROLE singularity_table_owner", [])
    rows_on_connection(repo, owner, cut)
  end)
  result
end
```

  SQL orders by independently literal PKs for stable comparison; the backup wire
  may order outbox by sequence/id, so do not compare unnormalized wire row order
  to this PK order. JSONB is read as ordinary native JSON values, bytea remains
  bytes, timestamps retain microseconds, text fragment IDs remain text. No
  truncated digest or formatted-content summary replaces the complete rows.
- [ ] Implement the exact worker snapshot observer, not a before-request or
  after-success source read. Its `worker` argument is the actual scoped repo
  module passed to Exporter, with its real dynamic connection and unchanged role.

```elixir
def capture_worker_cut!(worker, owner, cut) do
  connection = worker.get_dynamic_repo()
  %{rows: [[token, worker_backend, database, role]]} = SafeSQL.query!(connection,
    "SELECT pg_export_snapshot()::text,pg_backend_pid(),current_database(),current_user", [])
  true = is_binary(token) and Regex.match?(~r/\A[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9]+\z/, token)
  {:ok, observation} = MigrationRepo.transaction(fn ->
    SafeSQL.query!(MigrationRepo,
      "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])
    SafeSQL.query!(MigrationRepo, "SET TRANSACTION SNAPSHOT '#{token}'", [])
    %{rows: [[snapshot, observer_backend, ^database]]} = SafeSQL.query!(MigrationRepo,
      "SELECT txid_current_snapshot()::text,pg_backend_pid(),current_database()", [])
    true = snapshot == cut.database_snapshot
    true = observer_backend != worker_backend
    SafeSQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [])
    %{rows: rows_on_connection(MigrationRepo, owner, cut), snapshot: snapshot,
      worker_backend: worker_backend, observer_backend: observer_backend,
      database: database, worker_role: role, cut: cut}
  end)
  %{rows: [[^role, ^worker_backend]]} = SafeSQL.query!(connection,
    "SELECT current_user,pg_backend_pid()", [])
  observation
end
```

  Import snapshot precedes every query in the observer transaction. Token is
  generated by the database and validated before SQL interpolation; it is not
  caller input. No DML, worker role switch, repo replacement, reserved worker
  transaction injection, codec-based oracle or worker connection sharing is
  permitted. The real worker RR transaction remains open synchronously. Parent
  source inspection established no hidden canonical DML before this cut.
- [ ] Specify the causal observer contract now and execute it after Tasks4–6
  provide the genuine source worker and destination: imported snapshot equality,
  backend inequality, same database, same worker role, all38 table projections
  and exact source/import row equality. Deliberately alter one lawful mutable
  destination field in a separate disposable case and require comparison denial;
  do not bypass an immutable guard. Never log complete row maps on failure:
  independently read complete rows feed a fixed per-table binary equality
  commitment, with table/PK mismatch identifiers only.
- [ ] Run complete currently authored owners for projection/connection contracts.
  This initial result does NOT qualify the real worker snapshot. The causal
  worker/import-cut tests remain mandatory in Task6 after their dependencies
  exist; do not mark them complete from a metadata-count assertion. Defer commits
  to Task13 source review.

## Task 3: Add graph-only construction without changing old fixture behavior

**Modify:** Storage `test/support/knowledge_backup_fixtures.ex` only.
**Tests:** Existing full `logical_v3_import_test.exs` and new owning files.

- [ ] Add RED that the new entry preserves genuine owner/hierarchy/wrappers,
  takes all six real descriptors, inserts only knowledge/work graph, leaves all
  source Assets live until public deletion, and keeps every ordinary guard.
- [ ] Add a NEW `seed_graph!/1` entry with this exact input contract and body;
  `seed_documents/3`, `seed_notes/4`, `seed_organization/2`, `owner_query/1` are
  existing private functions in this same file, not new external helpers.

```elixir
def seed_graph!(%{owner: owner, ids: ids, sources: sources, work: work} = input) do
  true = Enum.sort(Map.keys(sources)) == Enum.sort([:pdf, :pdf_duplicate, :empty,
    :plain, :unicode, :markdown])
  true = Enum.all?(sources, fn {_name, source} ->
    Enum.all?([:resource_id, :resource_version_id, :asset_id, :object_id,
      :digest, :byte_size], &Map.has_key?(source, &1))
  end)
  owner_query(fn ->
    fragments = seed_documents(owner, ids, sources)
    seed_notes(owner, ids, sources, fragments)
    seed_organization(owner, ids)
    seed_work(owner, ids, work)
  end)
  Map.take(input, [:owner, :ids, :sources, :work])
end
```

  It must never call `seed_owner`, `seed_sources`, `FixtureCrypto`,
  `ObjectIdentity.generate_hierarchy`, old seed!'s retirement block, or mutate
  descriptor IDs/digests after fragment/source-set construction. Existing
  DocumentFragment.new creates final fragment IDs from final owner/resource/
  version IDs. Existing six source-set finalizers include the empty set.
- [ ] Preserve `seed_work/2` as the old behavior delegating to a new private
  `seed_work/3`; change only submission ID and epoch values in the shared insert
  statements. These are the exact substitutions in its existing complete body:

```elixir
defp seed_work(owner, ids), do: seed_work(owner, ids, %{
  submission_id: id(702), principal_authorization_epoch: 0,
  vault_authorization_epoch: 0
})
```

  New `seed_work(owner, ids, work)` retains event `id(700)`, correlation `id(701)`,
  progress `id(703)` and effect `id(704)`, all existing payload/type/revision/
  checkpoint fields. Replace literal epoch0 values with
  `work.principal_authorization_epoch` and `work.vault_authorization_epoch`;
  replace submission insert `id(702)` and both progress/effect submission
  references with `work.submission_id`. The native caller passes submission
  `id(700)` so the existing extracting Document's attempt_job_id equals its
  real outbox/submission identity. The old caller still uses702, exactly as
  before. No post-import repair is allowed to manufacture a matching cut.
- [ ] Define new fixture's knowledge IDs by generating an Ecto UUID for each
  atom below, then merge actual account/principal/vault/session IDs. Object IDs
  come only from real publication descriptors, never this ID generator.

```elixir
knowledge_ids = ~w(live_note_id deleted_note_id initial_note_version_id
  canonical_note_version_id competing_note_version_id merge_note_version_id
  open_competing_note_version_id deleted_note_version_id resolved_conflict_id
  open_conflict_id ready_document_id ready_old_version_id ready_current_version_id
  deleted_document_id deleted_document_version_id pending_document_id
  pending_version_id extracting_document_id extracting_version_id failed_document_id
  failed_version_id unsupported_document_id unsupported_version_id attachment_id
  citation_id deleted_attachment_id deleted_citation_id tag_id relationship_id)a
ids = Map.new(knowledge_ids, &{&1, Ecto.UUID.generate()})
work = %{submission_id: "60000000-0000-4000-8000-000000000700",
  principal_authorization_epoch: session.principal_authorization_epoch,
  vault_authorization_epoch: session.vault_authorization_epoch}
```

  Existing private `id(700)` formats that exact600-prefix UUID. Use that value
  consistently in native construction and assertions; preserve the old helper.
- [ ] Independently assert these graph cardinalities/relationships, not the old
  114-row fixture total: 6 Document resources,7 Document versions (ready3,
  pending1,extracting1,failed1,unsupported1),6 ready fragments,7 completed Document
  receipts;2 Note resources,6 Note versions,2 conflicts (resolved/open),4
  attachments,3 citations,6 derived source-set seals (including empty),1 tag
  `Straße`/`strasse`,1 assignment,1 relationship pinned to ready-old. Six source
  Asset resources/versions plus8 knowledge resources/13 knowledge versions give
  resources14/resource_versions19. Five real objects and six Assets; two public
  PDF tombstones are added in Task 5. Real native audit/outbox/submission/progress/
  metadata/source-reference counts are observed at the worker cut, never fixed
  to old synthetic counts. Assert every defined identity and ancestry edge,
  not just counts.
- [ ] Run new contracts and every old fixture/import/preflight owner. Expected
  GREEN preserves old `seed!/1` return shape, exact old rows/keys/wrapper behavior
  and all old callers. No implementation test may be deleted to make this pass.

## Task 4: Own sequential native infrastructure and the V3 worker snapshot

**Create:** Runtime `test/support/knowledge_backup_restore_fixture.ex`.
**Test:** Runtime new complete owner.

- [ ] Add RED for `KnowledgeBackupRestoreFixture.with_source/2` and
  `with_destination/2` (NEW APIs): each calls callback once inside one owned
  ResourceOwner lifetime, closes on success/error/throw, restores touched config,
  and cannot overlap source/destination global repositories. `with_source/2`
  returns only ciphertext portability metadata and expected content-safe test
  data after closing source. `with_destination/2` yields an EMPTY unbootstrapped
  destination and never starts an ordinary runtime before restore completion.
- [ ] Implement those NEW entries with `ResourceOwner.open(migration_pool_size: 2)`
  and `try/after ResourceOwner.close(owner)`. Snapshot each touched application
  setting as `Application.fetch_env(app,key)` and restore exactly (`{:ok,value}`
  → put_env, `:error` → delete_env) in an outer try/after, including on failure
  before `start_infrastructure`. Copy the small private bootstrap/configuration
  bodies from current `NativeAssetFixture` into this NEW support file without
  changing the original. Preserve genuine BootstrapOwner adapters, initial
  capabilities, native CustodyReader/Repository/KeyWrapper/StorageAdapter,
  ChunkedAEAD, recovery wrapper, real KeyCustodian and runtime authorization.
  Bootstrap source with table-owner transaction; credentials are random and
  private. Login uses actual existing `NativeAssetFixture.login!/1`.
- [ ] Implement NEW `start_controlled_runtime!/2` by selecting existing child
  specs; do not call the old full starter and try to stop recovery afterward.
  The selection contract is executable Elixir:

```elixir
borrowed = [Singularity.Storage.RequestRepo, Singularity.Storage.PreAuthRepo,
  Singularity.Storage.DispatcherRepo, Singularity.Storage.WorkerRepo]
composition = %{start_infrastructure: true,
  job_handler: Application.fetch_env!(:singularity_storage, :job_handler),
  authorization: Application.fetch_env!(:singularity_runtime, :authorization_dependencies),
  key_custodian: Application.fetch_env!(:singularity_runtime, :key_custodian),
  oban: Application.fetch_env!(:singularity_runtime, :oban_options),
  outbox_dispatcher: Application.fetch_env!(:singularity_runtime, :outbox_dispatcher_options)}
children = Singularity.Runtime.Application.application_children(composition)
{removed, retained} = Enum.split_with(children, fn child ->
  Supervisor.child_spec(child, []).id in borrowed
end)
true = Enum.sort(Enum.map(removed, &Supervisor.child_spec(&1, []).id)) == Enum.sort(borrowed)
{deferred, infrastructure} = Enum.split_with(retained, fn child ->
  Supervisor.child_spec(child, []).id == Singularity.Runtime.Documents.ExtractionReconciler
end)
true = length(deferred) == 1
{:ok, supervisor} = ResourceOwner.start_infrastructure(owner, infrastructure)
```

  ResourceOwner.start_infrastructure/2 currently returns `{:ok, supervisor}`
  after starting all children; an owned partial-start failure returns its error
  and is cleaned by ResourceOwner.close/1. Do not invent a supervision API.
  Return/store the one deferred child spec and actual infrastructure PID in
  fixture state. Explicitly account for every retained actual child and verify
  each repository identity/database. Defer ONLY ExtractionReconciler; do not
  remove dispatcher/Oban/custodian/job scope or other services. Its init triggers
  immediate work; no signals or arbitrary sleeps are allowed.
- [ ] Define NEW nested `V3Exporter` and `V3JobHandler` adapters. Configure a
  synchronous observer closure in the NEW test fixture's saved/restored setting;
  GenericWorker calls the real dependencies/WorkerScope, not a direct BackupVault
  shortcut. The code contract is:

```elixir
defmodule V3Exporter do
  alias Singularity.Storage.Backup.{Exporter, KnowledgeCanonicalOracle}
  def snapshot_cut(repo, vault_id) do
    with {:ok, cut} <- Exporter.snapshot_cut(repo, vault_id, 3) do
      %{owner: owner, receive_cut: receive_cut} =
        Application.fetch_env!(:singularity_runtime, :knowledge_v3_test_observer)
      observation = KnowledgeCanonicalOracle.capture_worker_cut!(repo, owner, cut)
      :ok = receive_cut.(observation)
      {:ok, cut}
    end
  end
  def records(repo, cut), do: Singularity.Storage.Backup.Exporter.records(repo, cut, 3)
end

defmodule V3JobHandler do
  @behaviour Singularity.Core.JobHandler
  alias Singularity.Runtime.JobDispatcher
  def dependencies, do: Map.put(JobDispatcher.dependencies(), :exporter, V3Exporter)
  def handle(context, envelope), do: JobDispatcher.handle(context, envelope)
  def handle_failure(context, envelope, error, attempt),
    do: JobDispatcher.handle_failure(context, envelope, error, attempt)
end
```

  In nested module resolve V3Exporter with its fully qualified NEW fixture module
  name or lexical alias, not an unbound top-level module. Actual callback is
  `handle_failure/4`, not `failure/4`. Snapshot input cut has no manifest ID yet;
  preserve it byte-for-byte and bind the later genuine operation ID separately.
  Do not inject reserved `:repo_handle`, `:lock_mode`, `:transact` worker fields.
- [ ] Add a NEW fixture `with_destination/2` failure contract that asserts exact
  owned source supervisor/repo deaths and source root removal before opening the
  destination; assert database identity differs and destination object root is
  empty. Use only the ResourceOwner's exact owned cleanup. Foreign/sentinel
  paths survive. Save/restore settings includes job handler/observer,
  authorization, custodian, maintenance/start flags, backup root, repository
  options and Oban settings. The oracle outside ExUnit uses the same explicit
  try/after, not only on_exit.
- [ ] Run complete Runtime owner. Expected GREEN proves real child ownership,
  proper snapshot observer invocation, no concurrent infrastructure and clean
  closure; no successful backup/restore claim until later tasks.

## Task 5: Genuine public source publication, deletion and portable backup

**Files:** NEW Runtime fixture and owning Runtime test.

- [ ] Add RED for six normal publications. Use existing public
  `NativeAssetFixture.upload!/4`, `verify_and_finalize!/0`, `dispatch!/0` only
  after NEW controlled fixture bootstrap/start. Inputs are exact synthetic bytes:

```elixir
pdf = "%PDF-1.7\n" <> <<0, 1, 255>> <> "\n%%EOF\n"
inputs = [
  {:pdf, "application/pdf", [pdf], "native.pdf"},
  {:pdf_duplicate, "application/pdf", [pdf], "duplicate.pdf"},
  {:empty, "text/plain", [], "empty.txt"},
  {:plain, "text/plain", ["plain original\r\nsecond line\n"], "plain.txt"},
  {:unicode, "text/plain", [<<0xEF>>, <<0xBB, 0xBF, 0xE4>>, <<0xB8, 0xAD>>, "é\r\n"], "unicode.txt"},
  {:markdown, "text/markdown", ["# Original Markdown\r\n", "[source](https://example.test/)\n"], "original.md"}
]
```

  For each input call actual grant→begin→append chunks→finish, real verify and
  finalize queues, then independently read exact finalized resource association,
  object/envelope and metadata with table-owner observation. Capture input binary
  as expected bytes, its SHA256 and exact size, not a replacement for later
  native observed bytes. Return six real descriptors defined in design §5.
  Assert UUID storage_ref for all5 objects, actual native envelope generations,
  availability and source/media identity. Two PDFs must have distinct Asset,
  resource and version IDs but the SAME real deduplicated object/ciphertext.
  PDFs may have finalized available/pending extraction metadata; only text is
  completed `upload_text_v1`, ready/revision5. No synthetic metadata completion.
- [ ] Call NEW graph entry only after finalized descriptors exist, with actual
  owner/epochs. Preserve original bootstrap secret/key hierarchy and assert
  wrapper rows unchanged across graph seeding. The graph must commit with all
  source targets live and its six Note source sets sealed.
- [ ] Publicly delete both PDF Assets only AFTER graph commit:

```elixir
for asset_id <- [sources.pdf.asset_id, sources.pdf_duplicate.asset_id] do
  {:ok, summary} = Singularity.Runtime.Api.asset_summary(session, asset_id)
  {:ok, _deleted} = Singularity.Runtime.Api.delete_asset(session, asset_id, summary.state_revision)
  _dispatch = Singularity.Runtime.NativeAssetFixture.dispatch!()
  %{failure: 0, success: 1} = Oban.drain_queue(Singularity.Oban, queue: :asset_cleanup)
end
```

  Observe exactly two actual `content.tombstones` with bound owner/principal/
  Asset/reason/retention metadata and actual revision causality; released
  resource_assets, deleted Assets with NULL object pointers, no live Asset
  reference to sharedPDFObject, available PDF object and unchanged encrypted
  file/envelopes retained by actual `document_source_pin_count`. Assert cleanup
  was actual worker admission under existing asset.write; a resource.deleted_at
  update alone is not tombstone coverage. Drain only the owned targeted queue;
  dispatch event counts include real earlier native activity, not legacy1.
- [ ] Retire only selected Note/Document/resource metadata in a second fixture
  transaction with ordinary constraints/triggers active, using the same deleted
  IDs as old graph shape; reconcile only live Note/current ready Document source
  projections through existing internal rebuild functions. Keep source snapshots
  stable by withholding periodic extraction recovery, not by bypassing guards.
- [ ] Implement NEW `backup_source!/2` (fixture-internal construction contract):
  take private portable root and reference mode; publish/seed/delete as above,
  request real backup and preserve encrypted bundle before source closes:

```elixir
passphrase = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
{:ok, request} = Singularity.Runtime.Api.request_backup(session, passphrase)
operation_id = request.operation_id
_dispatch = Singularity.Runtime.NativeAssetFixture.dispatch!()
%{failure: 0, success: 1} = Oban.drain_queue(Singularity.Oban, queue: :backup)
{:ok, %{operation_id: ^operation_id, status: :sealed}} =
  Singularity.Runtime.Api.backup_status(session, operation_id)
%{rows: [[destination_ref]]} = Singularity.Runtime.NativeAssetFixture.observe!(
  "SELECT destination_ref FROM audit.backup_manifests WHERE id=$1 AND vault_id=$2 AND status='sealed'",
  [Ecto.UUID.dump!(operation_id), Ecto.UUID.dump!(session.vault_id)])
{:ok, source} = Singularity.Storage.Backup.LocalDestination.reader_source(
  %{backup_root: Application.fetch_env!(:singularity_storage, :backup_root)}, destination_ref)
preserved_ref = operation_id <> ".bundle"
preserved_path = Path.join(portable_root, preserved_ref)
:ok = File.cp(source.path, preserved_path)
:ok = File.chmod(preserved_path, 0o600)
```

  Private portable root is newly operation-owned mode0700. Store only bundle,
  actual snapshot observation, genuine inventory, credentials/passphrase/new
  password kept privately, IDs, expected original binaries and content-safe
  lifecycle identities. Assert source closed before using destination. Do not
  hold source processes/raw keys as transport. Receive observer synchronously
  and bind its cut/rows to the real backup request/manifest. Exact runtime
  event/session/progress state is the cut, not an after-seal observation.
- [ ] Run full Runtime owner. Expected GREEN here includes genuine publicbackup
  with actual worker-scoped explicit3 and unchanged default2 negative guard.

## Task 6: Observe imported rows and complete the real UUID native saga

**Files:** NEW Runtime fixture, NEW Runtime owning test, NEW Runtime oracle.

- [ ] Add RED full UUID saga requiring exact cut BEFORE rewrap/recovery, actual
  typed native summary, all stages, normal postrestore login/unlock/publicsearch
  and every retained original. A test using existing known-hash fixture cannot
  satisfy it. New complete owner is `use ExUnit.Case, async: false` with
  `@moduletag :integration`.
- [ ] Define NEW nested transparent `ObservedRestorer` with context fields
  `:restorer`,`:after_import`,`:after_rewrap`,`:after_complete`. Each hook is a
  test-owned closure receiving the successful actual value; invoke it only
  after the real result and return that exact unmodified result. Hooks can
  assert/capture/mutate disposable test metadata, not manufacture authority.

```elixir
defmodule ObservedRestorer do
  alias Singularity.Storage.Backup.Restorer
  def import(context, repo, input) do
    result = Restorer.import(context.restorer, repo, input)
    case result do
      {:ok, %Restorer.Imported{} = imported} -> :ok = context.after_import.(imported)
      _ -> :ok
    end
    result
  end
  def rewrap_owner(context, imported, password, capability) do
    result = Restorer.rewrap_owner(context.restorer, imported, password, capability)
    case result do
      {:ok, rewrapped} -> :ok = context.after_rewrap.(rewrapped)
      _ -> :ok
    end
    result
  end
  def complete_restore(context, rewrapped) do
    result = Restorer.complete_restore(context.restorer, rewrapped)
    case result do
      :ok -> :ok = context.after_complete.(:ok)
      _ -> :ok
    end
    result
  end
end
```

  Native complete_restore/2 succeeds with :ok, not an ok-tuple. Its observer
  receives that exact successful value, returns the unchanged result, and only
  then records restore_complete. Positive observer hooks do not withhold native
  successful capabilities or manufacture errors; use the separately owned fault
  adapter below for reply-loss characterization.

  `after_import` calls `Canonical.read_committed!(MigrationRepo, source.owner,
  imported.cut)` before returning Imported. Compare all38 projections to source
  observation after transforming ONLY each `core.vaults.locked` to true.
  Compare complete rows and PK identities/ordinal/hash/source seals, not only a
  production digest. Retain separate existing credential-verifier/password and
  pending-wrapper transformations because their secret fields are not wire columns.
  Assertions must not exempt timestamps/epochs/work or arbitrary secret-labelled
  fields from the367 wire-column comparison.
- [ ] Define NEW `restore_context/4` constructor in fixture, taking actual empty
  destination, portable root, actual hooks and fault closures. Use EXACT current
  native authenticator/restorer components below; base positive hooks default
  `fn _ -> :ok end`. Existing OracleDestination/OracleMaintenanceMode are reused
  as destination admission ports, not a crypto shortcut.

```elixir
bootstrap = Application.fetch_env!(:singularity_runtime, :bootstrap_owner)
storage = Singularity.Runtime.StorageAdapter.configured()
authenticator = %{
  backup_cipher: Singularity.Storage.Crypto.ChunkedAEAD,
  backup_key_deriver: Singularity.Storage.Crypto.BackupKeyDeriver,
  backup_key_lease: Singularity.Runtime.BackupKeyLease,
  bundle_reader: Singularity.Storage.Backup.BundleReader,
  destination: {Singularity.Storage.Backup.LocalDestination, %{backup_root: portable_root}},
  logical_verifier: Singularity.Storage.Backup.LogicalBundleVerifier,
  recovered_vault_key: Singularity.Storage.Crypto.RecoveredVaultKey,
  restore_crypto_adapter: Singularity.Runtime.BackupKeyLease.StorageAdapter,
  restore_key_ttl_ms: :timer.minutes(5)
}
restorer = %{
  integrity_issuer: Singularity.Runtime.RestoreIntegrityLease,
  integrity_ttl_ms: :timer.minutes(5), key_deriver: bootstrap.key_deriver,
  key_wrapper: bootstrap.key_wrapper, migration_repo: Singularity.Storage.MigrationRepo,
  object_storage: storage, password_hasher: bootstrap.password_hasher,
  password_hasher_context: bootstrap.password_hasher_context,
  random_bytes: bootstrap.random_bytes,
  recovered_vault_key: Singularity.Storage.Crypto.RecoveredVaultKey,
  vault_kdf_params: bootstrap.vault_kdf_params
}
integrity = %{
  audit: {Singularity.Storage.Backup.IntegrityAudit, Singularity.Storage.MigrationRepo},
  ciphertext_auditor: Singularity.Storage.Backup.IntegrityAudit,
  object_storage: storage, restore_integrity_lease: Singularity.Runtime.RestoreIntegrityLease,
  search_rebuilder: {Singularity.Storage.Backup.KnowledgeIntegrityAudit, Singularity.Storage.MigrationRepo}
}
context = %{
  authenticator: {Singularity.Runtime.RestoreAuthenticator, authenticator},
  destination: {Mix.Tasks.Singularity.Test.Restore.OracleDestination,
    %{backup_root: portable_root, storage_root: destination.object_root}},
  integrity: {Singularity.Runtime.IntegrityAudit, integrity},
  maintenance_mode: {Mix.Tasks.Singularity.Test.Restore.OracleMaintenanceMode, true},
  migration_repo: Singularity.Storage.MigrationRepo,
  reconciler: {Singularity.Storage.Backup.Reconciler, Singularity.Storage.MigrationRepo},
  restorer: {ObservedRestorer, Map.put(hooks, :restorer, restorer)}
}
```

  V3 search uses KnowledgeIntegrityAudit, not the Base legacy facade. Do not
  change legacy native Base tests or storage inventory protocol. No destination
  bootstrap, manual wrapper strings, raw-key issue call or pretend issuer.
- [ ] Define NEW transparent `ObservedIntegrityLease` module callbacks
  `verify_all(capability)` and `revoke(capability)` which directly delegate to
  `RestoreIntegrityLease`, with a test setting closure called on successful
  real summary and on revocation. Preserve exact actual struct/result, no
  callback to replace material or plaintext reader:

```elixir
def verify_all(capability) do
  result = Singularity.Runtime.RestoreIntegrityLease.verify_all(capability)
  case result do
    {:ok, %Singularity.Runtime.RestoreIntegrityLease.PlaintextSummary{} = summary} ->
      observer = Application.fetch_env!(:singularity_runtime, :knowledge_v3_plaintext_observer)
      :ok = observer.(summary)
    _ -> :ok
  end
  result
end
def revoke(capability), do: Singularity.Runtime.RestoreIntegrityLease.revoke(capability)
```

  Install this only in Runtime IntegrityAudit's lease adapter; Restorer's issuer
  remains the actual native module. Typed-summary observer proves actual native
  hash/ordered IDs/inventory_count, while Runtime's real validation proves shape
  and inventory binding. NEW negative shape cases are separately labeled
  contracts, never a substitute for this positive.
- [ ] Execute actual `RestoreVault.run(context,%{source: preserved_ref,
  passphrase: passphrase,new_password: new_password})`; require actual success,
  manifest ID equality, exact import comparison and native typed summary. Only
  now disable maintenance and start ordinary runtime with controlled assembly;
  expose/enable deferred recovery after import comparison, in source-backed
  lifecycle order. Let actual Reconciler and recovery functions perform their
  lawful work; assert expected stale attempt/work changes and no duplicate jobs.
- [ ] Define NEW oracle `assert_originals!/2` with inputs actual unlockedsession
  and actual source-retained-object descriptors `%{asset_id:,object_id:,
  object_generation:,bytes:}`. Deduplicate expected objects by actual object ID
  (two PDFAssets share one), assert count5, then use actual public custody:

```elixir
for original <- retained_objects do
  command = %{purpose: :download, job_id: original.asset_id,
    session_id: session.session_id, principal_id: session.principal_id,
    vault_id: session.vault_id, required_capability: "asset.read",
    principal_authorization_epoch: session.principal_authorization_epoch,
    vault_authorization_epoch: session.vault_authorization_epoch,
    object_id: original.object_id, object_generation: original.object_generation}
  {:ok, lease} = Singularity.Runtime.KeyCustodian.lease(Singularity.Runtime.KeyCustodian, command)
  try do
    {:ok, observed_bytes} = Singularity.Runtime.DownloadLease.read(lease, :all)
    true = observed_bytes == original.bytes
  after
    Singularity.Runtime.DownloadLease.revoke(lease)
  end
end
```

  Use current registered KeyCustodian identity from actual fixture, not a fake
  material port. Query actual available object's current native envelope
  generation after rewrap. AssetID remains actual owner identity even when
  deleted; genuine lease material loading is object-bound, not asset-list
  liveness. Require PDF only-Doc pins, ready-old/nonhead, ready-current and
  deleted-ready membership all covered by this observed shared binary. Check
  every retained5 object including empty, plain, Unicode/BOM and Markdown;
  no known digest/source input counts as observation. Bytes never printed.
- [ ] Define NEW oracle `assert_search!/2` using real `Api.search_knowledge/2`,
  checking current liveNote and ready-current Document hits, pinned immutable
  versions and actual fragment locator/digest source resolution; historical,
  deleted, pending/extracting/failed/unsupported are absent as current search
  hits. Fixed expected IDs come from the designed graph, not query result IDs.
  Use the actual accepted query `%{q: "fixture", kind: :all, limit: 50}`. Assert
  each public result DTO's actual `resource_id`, `resource_version_id`, kind
  and source fields, not legacy asset Api.search. Resolve citation source with
  actual `Api.resolve_search_source/2` and immutable source identity.
- [ ] Run complete Runtime owner and retained public search regressions.
  Expected GREEN is UUID whole-saga proof, not normal text V2 prerequisite proof.

## Task 7: Historical canonical and mixed real inventories

**Files:** NEW Runtime fixture/owner/oracle only; no production reference edits.

- [ ] Add two RED whole-saga cases separate from untouched UUID baseline:
  `:canonical_compatibility` converts all five published objects to historical
  canonical refs; `:mixed_compatibility` converts exactly PDF and empty objects,
  retaining plain/Unicode/Markdown UUID refs. Label these compatibility source
  compositions, never normal UUID publication.
- [ ] Implement alias composition ONLY in owned source before backup, after
  genuine native finalization, against actual LocalFilesystemAdapter. For each
  selected object's existing owner/domain/lookup-digest and object root:

```elixir
{:ok, canonical_path} = Singularity.Storage.Local.PathGuard.object_path(
  object_root, object.vault_id, object.key_domain_id, Base.encode16(object.lookup_digest, case: :lower))
canonical_ref = Path.relative_to(canonical_path, object_root)
true = File.regular?(canonical_path)
%{rows: [[old_ref, old_hash, old_size]]} = Singularity.Runtime.NativeAssetFixture.observe!(
  "SELECT storage_ref,ciphertext_hash,ciphertext_byte_size FROM content.asset_objects WHERE id=$1",
  [Ecto.UUID.dump!(object.asset_object_id)])
%{num_rows: 1} = Singularity.Runtime.NativeAssetFixture.observe!(
  "UPDATE content.asset_objects SET storage_ref=$1 WHERE id=$2 AND storage_ref=$3",
  [canonical_ref, Ecto.UUID.dump!(object.asset_object_id), old_ref])
true = :crypto.hash(:sha256, File.read!(canonical_path)) == old_hash
true = File.stat!(canonical_path).size == old_size
```

  PathGuard.object_path/4 takes root,vaultUUID,domainUUID,lowercase64-hex digest
  in that order; no file copying or invented alias resolver. Actual adapter
  resolves physical path by owner/domain/lookup
  when object context is supplied. Require UUID lookup and canonical lookup
  resolve the same existing genuine file and actual cipher decrypts it. An
  immutable guard refusal is a design finding, not permission to disable it.
- [ ] Independently capture and compare all nine I fields at source worker cut,
  authenticated cut, imported result, rewrapped result, and saga target:

```elixir
@inventory_fields ~w(asset_object_id vault_id key_domain_id classification
  lookup_digest ciphertext_hash ciphertext_byte_size storage_ref inventory_position)a
```

  I remains persisted/authenticated exactly; N(I) changes ONLY storage_ref to
  UUID for runtime physical admission, preserving all other8 fields, order,
  object count and ciphertext physical identity. Compare actual callback
  arguments/results rather than calculating a normalization and assuming use.
  Source/import `content.asset_objects.storage_ref` retains I. Do not normalize
  production database rows. Keep actual LocalFilesystemAdapter in canonical
  positive paths; a wrapper that loses adapter identity is not equivalent.
- [ ] For all three full sagas require exact38 cut, typed native summary,
  every object's postlogin native decrypted bytes, public unified search,
  cleanup and all completion order. Run complete owner. Expected GREEN is three
  native full-saga variants, not shape-only helper known-hash tests.

## Task 8: Causal native size, digest and late cipher negatives

**Files:** NEW Runtime fixture/owner/oracle. Existing frozen readers unchanged.

- [ ] Add RED wrong-size native case starting from genuine UUID publication.
  Use actual PDF plaintext byte length P and genuine unchanged ciphertext with
  `C(P)=66+P+24*ceil(P/4194304)+68`; set disposable Object plaintext size and all
  three corresponding immutable Document source sizes to P+1 BEFORE graph
  admission/backup. Do not alter ciphertext_byte_size/hash or source IDs. Require
  actual authenticated bundle/import/rewrap success and earliercipher success.
- [ ] In transparent after-import/after-rewrap hook restore Object-only size to
  P before actual native RestoreIntegrityLease material load. Typed summary hook
  records genuine actual successful summary. At Document helper callback,
  AFTER Runtime's real typed validation, reset Object size to wrong immutable
  Doc size P+1; delegate real `KnowledgeIntegrityAudit.verify_document_sources`
  with the exact native summary. It must deny C(P) versus C(P+1), with no
  unified rebuild/integrity complete/restore complete. No fake summary/material
  loader or cryptoreader change is permitted.
- [ ] Implement contextual NEW `ObservedKnowledgeAudit` callbacks matching the
  current facade arities, forwarding actual repo/target/summary. The essential
  E-barrier body is:

```elixir
def verify_document_sources(context, binding, inventory, plaintext_hashes) do
  :ok = context.before_documents.(binding, inventory, plaintext_hashes)
  Singularity.Storage.Backup.KnowledgeIntegrityAudit.verify_document_sources(
    context.repo, binding, inventory, plaintext_hashes)
end
def rebuild(context, binding) do
  :ok = context.before_rebuild.(binding)
  result = Singularity.Storage.Backup.KnowledgeIntegrityAudit.rebuild(context.repo, binding)
  case result do
    {:ok, summary} -> :ok = context.after_rebuild.(summary)
    _ -> :ok
  end
  result
end
```

  Runtime passes actual `%{manifest_id:,vault_id:}` binding, original inventory
  and `plaintext.plaintext_hashes` to verify_document_sources/4, not the full
  typed struct. The typed observer separately records that actual struct and
  the callback proves real validation already succeeded. Do not add an
  imaginary plaintext-reader callback: actual native
  lease hardcodes AuthenticatedReader. Spy outside typed validation does not
  prove the E barrier; the helper callback stage does.
- [ ] Retain the nine exact existing size boundary vectors without altering
  input or arithmetic (they are additional contracts, not native proof):

| P | C(P) |
| --- | --- |
| 0 | 134 |
| 1 | 159 |
| 4194303 | 4194461 |
| 4194304 | 4194462 |
| 4194305 | 4194487 |
| 8388607 | 8388789 |
| 8388608 | 8388790 |
| 8388609 | 8388815 |
| 67108864 | 67109382 |

- [ ] Add independent wrong-source-digest native case: set the same incorrect
  32-byte digest on every graph Document referencing the genuine PDF object
  before final graph admission; real backup/import/rewrap/reader still succeed,
  actual typed summary contains real decrypted hash, Document helper denies,
  all downstream stages absent. Do not mutate imported immutable Document rows.
- [ ] Add actual late-cipher mutation cases through transparent real auditor:
  first mutates after earlycipher success before finalcipher; second mutates
  only after actual finalcipher result before native plaintext verification.
  Flip one byte or truncate the actual owned ciphertext file, retaining metadata
  and genuine wrappers. Verify changed physical hash/length, exact reached stage,
  real native denial, revoked capability, maintenance invisibility and no later
  completion. Source/import succeeded; a preauth corrupted bundle alone is not
  this negative. Preserve the actual real cipher result before mutation.
- [ ] Add separate typed-evidence shape contracts (missing/duplicate/extra/
  reordered object hashes, wrong owner/count/inventory digest, malformed hash,
  wrong struct/shape) with explicit label “adapter contract, not native crypto
  evidence.” Keep the genuine native typed positive and both material negatives
  independently required. Do not enlarge the old historical fragment-mutation
  exception from `document_restore_integrity_test.exs` into a generic guard bypass.
- [ ] Run complete Runtime owner and all Document integrity owners. Expected
  GREEN includes successful native read before Document size/digest denial and
  actual latecipher denial, never an earlier accidentally failing admission.

## Task 9: Independent malformed V3 matrix with stage/error contracts

**Create:** Storage `test/singularity/storage/backup/logical_v3_failure_test.exs`.
**Retain:** Complete old `knowledge_preflight_test.exs`, `logical_v3_import_test.exs`.

- [ ] Add new integration module, `async: false`, using existing
  `KnowledgeBackupFixtures.with_destination(:current, callback)` and old
  `seed!/1` ONLY for isolated protocol/import malformed cases. These bundles
  explicitly use FixtureCrypto and literal fixture recovery wrapper, so label
  them “protocol/import contracts, NOT native wrapper/custody proof.” Real
  native positives/material negatives remain Task6–8, never counted here.
- [ ] Define each mutation as a pure closure on independently observed rows or
  `transformed_bundle/2`'s existing cut/evidence/raw/records/source transform.
  Every row owns `name`, `mutation`, `earliest_stage`, `exact_error` and
  `retryable?` expectation. No test can pass because ANY error occurred. For
  cases where the old source only establishes `%Error{}`, first add causal
  characterization asserting actual stage and no-write/no-downstream effects;
  record actual sanitized code/flag from that execution, trace the returning
  source branch, then lock its exact contract and rerun the FULL matrix. This
  characterization cannot be left as final generic-error acceptance.
- [ ] Implement these independently named cases; list membership is checked by
  the owning test so none silently disappears:

| Case family | Concrete mutations and required reached boundary |
| --- | --- |
| PK and each secondary unique | duplicate Document version,fragment ID,receipt PK,attachment PK,citation PK,tag ID,assignment PK,relationship ID; duplicate fragment(version,ordinal),Note member(version,ordinal),normalized tag key and other actual canonical unique indexes; authenticated parse/preflight rejects before canonical insert |
| Counts/coverage | remove/add canonical row without matching count; remove/add object evidence/raw; wrong table_count_vector/object_count; duplicated object identity/index; preflight denies with zero canonical rows |
| Version | cut3/row2,cut3/object2,row3/cut2,unknown wire version; exact codec/auth/preflight boundary proved |
| Scope/type/head | foreign owner in each appended table,classification mismatch,resource.kind wrong,head absent/wrongresource/wrongtype,noncurrent historical state inconsistent; preflight denies before insert |
| Ancestry/conflicts | cross-resource/foreign parent,cycle,missingmergeparent,mergeparents invalid,resolvedconflict missing/wrongresolution,openconflict withresolution,state/ancestry disagreement; typed preflight denies |
| Members | attachment/citation duplicate or gap ordinal,wrongtargetkind,foreign/missing target,wrongNoteversion/resource; remove/add an encoded member AFTER logical cut counts are fixed, preserving that cut, so authenticated logical counts disagree; rejection admits no seals |
| Fragments | wrong ID for finalidentity,changed text without digest,changed digest,noncontiguousordinal,locatorwrongkind/page/shape,duplicatefragment,wrongextractedaggregate,history locator substitution; preflight or actual source validation denies causally |
| Organization | normalized key collision,display/key disagreement,foreign tag assignment,crossowner/missing relationship,pinned wrongversion/unpinned invalidkind; preflight denies |
| Receipt/work | completedreceipt missingresult,wrongresource/version,fingerprintlength/identity disagreement,principalowner mismatch,attempt_job/outbox/submission mismatch,wrong epochs/type/revision/provenance; preflight denies |
| Objects/material | unsupportedformat,canonicalpath wrong owner/domain/digest,traversal/noncanonicalUUID,foreign object,ambiguoussourceassociation,changed/truncatedrawcipher,metadatahash/length mismatch,plain source digest/size mismatch; exact actual auth/stage/import/helper boundary proved |

  Inspect actual current database unique indexes and enumerate their names in
  the test alongside mutations; do not assume “duplicate PK” covers all unique
  keys. New fixture data missing a specific eligible unique needs an explicit
  lawful seed row and its exact mutation, not omission. Native foreign/format/
  ciphertext/source mismatch counterparts must use Task6 fixture real crypto.
- [ ] Keep authenticated member/count disagreement distinct from a different
  valid source set. Use transformed_bundle's existing records transform, after
  cut and row encoding but before outer manifest inventory/authentication, to
  remove or duplicate a chosen encoded attachment/citation while leaving the
  original logical cut table_count_vector unchanged. The rebuilt outer manifest
  authenticates the altered records; logical count verification must reject
  before canonical writes. A rows transform that recomputes every count and
  produces a lawful different set is not intrinsically malformed and cannot
  count as this negative. Never invent an empty-set wire evidence/seal table.
  Separately, Task10 installs an owned failing BEFORE INSERT seal trigger for a
  specific empty Note version: assert real loading admission and zero attachment/
  citation rows before its nontransactional hit and error. Require native import
  rollback and zero committed seals. The successful replay/positive must have
  all six derived seals, with exact per-version attachment_count/citation_count
  including the empty versions'0/0. No ordinary guard is disabled or seal skipped.
- [ ] Use existing transforms concretely, for example this single-field case
  (variables are actual old fixture and static table name):

```elixir
mutation = fn rows ->
  Map.update!(rows, "content.document_fragments", fn [first | rest] ->
    [Map.put(first, "digest", :crypto.hash(:sha256, "incorrect-fragment")) | rest]
  end)
end
result = Singularity.Storage.Backup.KnowledgeBackupFixtures.transformed_bundle(
  fixture, rows: mutation, mode: :replay)
```

  For semantically malformed but authentic streams, successful authenticate is
  required before native Restorer/KnowledgePreflight rejection; for deliberately
  bad wire/header records, assert the exact earlier parser/auth stage. Snapshot
  all destination canonical/derived rows and owned filesystem before/after.
- [ ] Error source contracts currently certain: explicit Restorer helper
  `backup_invalid()` returns `Error.new(:backup_invalid)` (default false),
  `integrity_failure()` returns `Error.new(:integrity_failure)` (default false),
  `storage_unavailable()` returns `Error.new(:storage_unavailable)` (default
  false); Runtime/Exporter availability paths may explicitly set true. Never
  infer a particular mutated case's code/flag from that vocabulary alone.
  Exact reached branch and original flag are the test contract; preserve all
  old stricter exact assertions. Clean rollback/owned artifacts and no native
  decrypt/rebuild/completion after earlier rejection are always required.
- [ ] Run complete newStorage owner plus all retained codec/schema/import/
  preflight owners. Expected GREEN means every enumerated mutation is distinct,
  causal, exact and unskipped, not test-count growth with generic rejection.

## Task 10: Real SQL/publication/commit-resolution failures and Storage replay

**Files:** NEW Storage failure owner and bounded NEW Runtime fixture seam.

- [ ] Add RED canonical insert,source-seal,stagepublish,postpublishstat,
  markerupdate and commit-result uncertainty cases. Reuse actual patterns from
  `logical_v3_import_test.exs`, not its ExUnit test functions. New helpers live
  privately in the new owner or NEW fixture; never alter production Repo or
  disable canonical guards.
- [ ] Define test-owned real CommitUncertaintyRepo with actual super COMMIT:

```elixir
defmodule CommitUncertaintyRepo do
  use Ecto.Repo, otp_app: :singularity_storage, adapter: Ecto.Adapters.Postgres
  def default_options(_operation), do: [telemetry_event: nil]
  defoverridable transact: 2
  def transact(fun, options) do
    result = super(fun, options)
    if result == {:ok, :imported} and Process.get({__MODULE__, :armed}, false) do
      false = in_transaction?()
      Process.put({__MODULE__, :armed}, false)
      Process.put({__MODULE__, :hits}, Process.get({__MODULE__, :hits}, 0) + 1)
      Process.put({__MODULE__, :committed_result}, result)
      {:error, :simulated_commit_uncertainty}
    else
      result
    end
  end
end
```

  Start this registered real Ecto Repo from actual MigrationRepo.config with
  own name; unlink only its own started PID; stop it naturally in try/after;
  clear only its own Process keys. Arm immediately before real import in the
  same calling process. Assert one hit, committed_result exactly `{:ok,:imported}`,
  real complete committedgraph and actual Restorer returned storage_unavailable.
  This reaches finish_failed_stream_import/current_marker_state. It simulates
  actual COMMIT followed by erroneous Repo result, NOT a network-loss proof.
  An outer adapter hiding Imported is merely lost reply after known commit and
  must not replace this uncertainty-branch contract. A nonregistered proxy is
  invalid for SafeSQL/Ecto metadata; no production transaction/protocol change.
- [ ] Define NEW private SQL-fault helper with exact uniquely named sequence,
  function and trigger under existing audit schema. Create/drop only those
  owned names in try/after. The stage guard must assert expected prior real
  rows/seals/admission/marker state before raising; sequence nextval survives
  transaction rollback and proves the trigger was reached. Example exact body:

```sql
BEGIN
  IF (OLD.state='pending' AND NEW.state='imported'
      AND (SELECT count(*) FROM content.note_source_set_seals)=6
      AND (SELECT state FROM audit.knowledge_restore_admissions)='validated') IS NOT TRUE THEN
    RAISE EXCEPTION 'task11_wrong_fault_stage';
  END IF;
  PERFORM pg_catalog.nextval(TG_ARGV[0]::regclass);
  RAISE EXCEPTION 'task11_marker_fault';
END
```

  Install BEFORE UPDATE ON audit.restore_import_sagas; the actual marker
  column is state. Pass the owned sequence name as trigger argument. Extend
  the guarded predicate with the independently observed total canonical count,
  never114. Seal trigger requires actual6 Notes/4 attachments/3 citations and
  loading admission; marker trigger requires
  validated admission,6 seals, allpublished objects and source-observed full
  canonical count (not114). Canonical insert trigger chooses one known row and
  exact earlier-stage counts. All RLS, immutable triggers and deferred ordinary
  constraints remain enabled. Counter==1 alone is insufficient without guards.
- [ ] Define NEW fault storage as an exact delegate of the actual
  LocalFilesystemAdapter callback signatures currently implemented by old
  FaultStorage: stage/append/seal/finalize/stat/rollback_finalize/abort/list.
  Use these actual signatures in the new owner; closures fail once at
  selected real boundaries. Stage failure proves rows/admissions0; finalize
  failure checks validated admission/seals before publication; post-finalize
  failure executes actual finalize then fails actual stat once; rollback fault
  is armed only after actual receipt/hash exists. Preserve real ownership
  receipts, identity-bound cleanup and foreign sentinel artifacts. Do not wrap
  canonical positive storage if that changes actual adapter identity.

```elixir
defdelegate append_encrypted_chunk(context, stage, bytes), to: Singularity.Storage.LocalFilesystemAdapter
defdelegate seal_stage(context, stage, metadata), to: Singularity.Storage.LocalFilesystemAdapter
defdelegate stat_stage(context, stage), to: Singularity.Storage.LocalFilesystemAdapter
defdelegate abort_stage(context, stage), to: Singularity.Storage.LocalFilesystemAdapter
defdelegate delete(context, object), to: Singularity.Storage.LocalFilesystemAdapter
defdelegate list_staged(context), to: Singularity.Storage.LocalFilesystemAdapter
```

  Faulted callbacks are `stage(context,options)`,
  `finalize(context,stage,object)`, `stat(context,object)` and
  `rollback_finalize(context,stage,object)`. Their closure settings/counters
  remain test-only; execute each actual LocalFilesystemAdapter delegate before
  its defined after-success barrier.
- [ ] Qualify pending and imported replay as separate actualStoragecases. For
  each supported case use fresh authenticate/replay stream on the EXACT same
  manifest and SAME destination, require actual `{:ok,%Restorer.Imported{}}`,
  compare complete canonical rows/objectlist/seals/jobs before/after and require
  no duplicates or unintended cleanup. Read-only imported replay must not
  republish/rewrap. Every attempt uses a fresh one-shot authenticated replay;
  consumed verified handles cannot be reused. Wrong manifest/tag/hash/root,
  mutated graph, foreign artifacts and stale/ambiguous marker deny exactly.
- [ ] Run complete Storage failure/import/preflight and Runtime owning files.
  Expected GREEN preserves actual import rollback/owned cleanup versus genuine
  committed-graph uncertainty branch, plus successful exact replay. No
  distributed transaction rollback or wholeRuntime resume claim follows.

## Task 11: Full Runtime fault order and honest continuation boundary

**Files:** NEW Runtime fixture/owner/oracle, no production changes.

- [ ] Add RED case rows for each boundary below. Transparent contextual
  adapters call the actual native delegate until the selected fault; return
  original exact Error and flag. Counter/trace assertions prove prior stages
  and absence of every downstream stage; custody status is checked after each
  failure, not only at suite cleanup.

| Fault | Required consequence and retry class |
| --- | --- |
| empty admission/authentication/preflight | no canonical publication; revoked/discarded authenticated custody as applicable; same emptydest authretry must actually complete with identical source |
| canonical insert/seal/staged publish | transaction rollback plus exact owned object/stage cleanup; correct original code/flag; supported same-dest retries actually succeed |
| real commit uncertainty | committedgraph/error as Task10; exact Storage imported replay succeeds; Runtime empty admission is a distinct barrier |
| rewrap before commit | actual imported maintenance graph unpublished; original failure/custody cleanup; characterize current supported continuation only |
| rewrap committed then reply fault | a dedicated test fault adapter owns the real returned capability, proves committed wrapper change, explicitly revokes it before withholding result; caller cannot revoke authority it never receives; characterize the same-destination admission boundary, not native caller cleanup or successful resume |
| earlycipher/durablework/finalcipher | only actual prior work committed; no plaintext/search/completion after failed stage; preserve original availability retry flag |
| nativeplaintext/Document helper | actual typed native summary required before Document case; no rebuild/completion; native capability revoked/consumed, no bypass |
| unifiedrebuild/integritycomplete/restorecomplete | real earlier stages recorded; maintenance unpublished target; final completion audit/restore status only when their real delegate succeeds |

- [ ] Add actual completeRuntime retry success on one same initially empty
  destination: first wrong passphrase/failed authentication, assert empty graph,
  roots/authority cleanup; authenticate fresh with correct passphrase into that
  IDENTICAL dest and require all native success/canonical/bytes/search checks.
  Other supported in-place completeRuntime retries require the same positive
  completion evidence; testing only the second error is insufficient.
- [ ] Implement committed-rewrap reply loss in a separate test-only fault
  adapter, NOT by throwing from the positive ObservedRestorer.after_rewrap hook.
  It calls native Restorer.rewrap_owner exactly once in the same caller and
  retains the actual successful Rewrapped and its native integrity_capability.
  In try/after, observe committed credentials/wrapper generation and retain the
  exact deliberately injected Error; in after synchronously call native
  RestoreIntegrityLease.revoke on that returned capability before suppressing
  the result. Monitor its actual lease PID before revoke and require normal DOWN
  under the existing test deadline, then require verify_all denial with actual
  backup_invalid/nonretryable contract. Return the original injected Error with
  its exact retryable flag unchanged. Preserve native error results untouched
  if rewrap itself fails. This is adapter-owned fault cleanup of a real capability,
  not proof that unreachable RestoreVault cleanup handled an unknown capability.
  No raw key, test-minted authority, TTL/expiry credit, new issuer or production
  callback/protocol change is allowed. The separate postconsumption fault uses
  actual native successful verify_all and its consumed capability, not a fake
  status. Both leave the graph unpublished and the original error unchanged.
- [ ] Characterize postrewrap consumed/lost-integrity-custody boundary without
  frozen changes. Inject a transient error after actual committedrewrap and
  consumed/removed native integrity custody; assert ORIGINAL exact Error and
  retryable flag, all appropriate revocations, maintenance invisibility,
  no dispatch/ordinaryruntime/restorecompletion. A fresh wholeRuntime invocation
  into same nonemptydest fails current empty-admission contract; record exact
  code/flag from source-backed causal execution. Do not set transient flagfalse,
  mint custody, bridge a key, journal a password, reopen unwrap, or bypass
  admission to make an impossible continuation appear successful.
- [ ] Separately restore exact same encrypted manifest into a NEW disposable
  emptydest and require full actual native success, naming this RESTART. Add
  supported replacement-staging case with an independently allocated active
  sentinel installation/root and its complete pre/post digest unchanged; no
  production cutover. All graph/object/secret ownership closes after each
  attempt, preserving foreign/active artifacts. This does not weaken a required
  fault or retry assertion; it makes supported retry versus unsupported durable
  wholeRuntime continuation explicit as the three governing amendments require.
- [ ] Run full Runtime andStorageowners plus existing restore_vault_test.
  Expected GREEN includes supported same-dest actualsuccess, precise unchanged
  unsupported continuation, successful newdest RESTART and unchanged active
  installation, with no arbitrary sleep/process signal/deadline relaxation.

## Task 12: Add the sole independent restore oracle and run exact gates

**Create:** Runtime `test/support/knowledge_restore_oracle.ex`.
**Modify:** Runtime lib `mix/tasks/singularity.test.restore.ex`, additive only.

- [ ] Add RED that the independent task must load NEW oracle and run its actual
  knowledge checks after ALL existing legacy cleanup. NEW oracle `run!/0` owns
  its own sequential native fixture construction; it must not execute ExUnit
  test files or count an empty marker as qualification. Define its independent
  assertions explicitly from Task2 projection,Task3 fixed knowledge identities,
  Task6 public search/everybinary andTask8 real latecorruption, not production
  codecs/digests or the assertions of another ExUnit module. Shared fixture
  construction is allowed; the independent expected contract remains explicit.
- [ ] Implement `run!/0` as three positive variant runs (UUID,allcanonical,mixed)
  with independent exact canonical+typedsummary+originalbyte+publicsearch
  assertions and a separate actual latecorruption denied run, each resource
  lifetime in explicit try/after. It raises a sanitized failure for any mismatch,
  prints only stage/count/status and returns `:ok` only when every check passes.
  Preserve separate oldlegacy/newknowledge outcomes; failure of either fails the
  sole task. Reuse no fake source/recovery wrapper in this entry.
- [ ] Add ONLY this guarded dynamic block after the existing run/0 try/after
  legacy `cleanup!`, before its final end:

```elixir
oracle = :"Elixir.Singularity.Runtime.KnowledgeRestoreOracle"
unless Code.ensure_loaded?(oracle) and function_exported?(oracle, :run!, 0) do
  Mix.raise("knowledge restore oracle is unavailable in the required test environment")
end
:ok = apply(oracle, :run!, [])
```

  Existing assert_test_environment! remains earlier. No lib static struct/call
  to support modules absent from dev/prod. Preserve old run→backup_source!→
  restore_destination!→assert_restored!→restore_v1_fixture! flow, old operators,
  descriptor/secret prompts, goldenV1 `.backup` bytes/hash, explicitV2 and ALL
  crypto/assertions. Legacy backup `submitted:1` stays on oldgraph; newfixture
  uses separate accounting. New code runs only after legacy resources close.
- [ ] Parent runs test and non-test warnings-as-errors compilation (separate
  owned direct invocations) to prove dynamic composition does not introduce
  undefinedtestsupport warnings; run format/diff,architecture,sevenapps,zero
  xrefcycles and frozen registry checks. No compiler or formatter run by draft
  author. Current frozen56 registry expected SHA-256 is
  `d0296d241c66e382baa09a0a092fe8add6df66364d5f2d5644f4f4ea1963a050`;
  never regenerate it from changedfiles. Preserve acceptedsource/native seals.

### Native execution protocol (parent only)

Every invocation below is its OWN direct argv, fresh raw capture and complete
natural process lifetime. Do not paste the following table as one compound
shell command. Parent prepares umask077, validates fresh raw absent/nonsymlink,
exact HEAD/index/source/pins/private PostgreSQL identity, and owned BEAM0 before
starting. First master invocation's concrete launcher is:

```sh
script --quiet --return --flush --log-out /home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup/.devenv/phase5-task11-v3-saga-native-integration-20261015-01.log -- devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
```

Use this log path only if parent proves absent/nonsymlink before launch;
otherwise select and record a different fresh explicit filename. Each following
argv set uses its own likewise validated explicit private raw path under the
same launcher. No overwrite/append of existing logs. No inner bash-c,
compound forwarding, envdump, launcher deadline, test input/assertion/concurrency/
pin/version relaxation or filteredtail evidence. Never inspect the historical
secret-containing `.devenv/phase5-task11-native-text-regression-static-native.log`.

While LIVE: all other agents' commands CLOSED; parent only exactsession polling
and concise commentary. Wait only the exact owned session; no extra repository
commands run concurrently. At natural EOF retain whole unfiltered private raw,
actual exit code and per-owner result. Then prove ordinary residual cleanup
natural0/EMPTY with exact owned identities; preserve ordinary failures without
signals or unrelated process cleanup. If a privatePG service cannot be
established, record BLOCKED_ENV and unvalidated gates rather than bypassing it.

Required masterTask11 native argv (unchanged owners/seed/warnings):

```text
singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
test apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs apps/singularity_runtime/test/singularity/runtime/restore_vault_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
singularity.test.restore
```

Additional full retained owners, not test-name selections, in serialized
invocations sized only for ownership and normal task semantics:

```text
singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_reconciliation_test.exs apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs --seed 215378 --warnings-as-errors
singularity.test.integration apps/singularity_runtime/test/singularity/runtime/native_text_ingestion_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_authorization_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_cut_live_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs --seed 215378 --warnings-as-errors
test apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_schema_ddl_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Retain all four complete command vectors from the prerequisite verification
  document §4 (native15,unit164,integration265,Storageunit29), preserving seed0;
  run each through the same parent-owned direct launcher, separately from the
  seed215378 Task11 commands. Also retain the independent Note-search store
  owner `apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs`
  and its existing actual integration tag selection. Exact prerequisite commands
  are already recorded in the committed
  `docs/verification/2026-10-15-phase-5-native-text-prerequisite.md`; copy their
  argument vectors verbatim to the run manifest, never infer a reduced owner
  subset from the four live files listed here. No prior test is dropped.
- [ ] Execute all master commands above, all retained owners, complete static
  checks and the sole independent restore task. Expected GREEN requires all
  wholefile assertions, actualprocess exit0, no failures/skips, normalcleanup and
  recorded exactsource. Repeat wholeowner after any repair, never shorten it to
  a passing selected test. Keep RED/failed/repair/GREEN evidence distinct.
- [ ] Before Phase5 local acceptance execute the complete permitted README gate,
  preserving each actual command/normal termination, omitting ONLY forbiddenE2E.
  E2E remains NOT RUN and finalbrowser/releaseacceptance required. A failed
  executed required gate blocks acceptance/advancement, even if focusedtests
  pass. Task11 is not Phase5 acceptance by itself.

## Task 13: Source reviews, small local commits and evidence handoff

**Files:** Exact seven source/test paths in locked map, parent-owned documents.

- [ ] Freeze exact changedsource bytes/index/diff and check no forbiddenpath,
  frozenmodule,prerequisitefixture,productionreference,default2,Task16 orVault
  behavior changed. Record allnewtestnames/counts/exactcommands,typedsummary and
  fullcut/everybinary/nativevariant/fault/retry results,private raw hashes,
  cleanup/source SHA and remaininglimits. No content/secrets in handoff.
- [ ] Obtain independent SOURCE SPEC review against complete updated governing
  documents and actual raw evidence. Resolve findings with actual diagnosis,
  scoped tests and unchanged required assertions. Then obtain NEW DISTINCT
  SOURCE QUALITY review on exact reviewed bytes. A historical review or a
  design reviewer summary cannot substitute for this source review.
- [ ] Only after actualsource SPEC→NEWQUALITY and passing requiredchecks make
  small parent-owned local commits, separated by responsibility when their
  exactbytes are covered by review: independentoracle+graphfixture; realnative
  saga+faultmatrix; additiveindependenttask. Use explicitfile staging only,
  preserve unrelated untrackedwork, no autofix/reformat outside scope. Suggested
  final qualification subject is
  `test(restore): qualify complete v3 saga and malformed rejection`. Do not
  commit merely because a plan checkbox says commit before source review.
- [ ] Synchronize tracked verification/design/plan docs with actual sourcecommits,
  commands/results,retryboundary and Task11onlystatus; independent docSPEC then
  NEWdocQUALITY; commit separately. Parent verifies final HEAD/index/source/seals,
  clean ownedresources,allcommandtermination and unchanged controls.
- [ ] Hand off Task11 explicit3 qualified only when EVERYrequiredacceptance item
  truly passes; leave default2/Task12gate and Task16 BOTHstrictALLleases unchanged.
  No merge/push/tag/version/release/deploy/production/E2E claim. No completion
  claim based solely on this draft or a source-only preparation report.

## Coverage and self-review

| Parent design requirement | Implementation/verification owner |
| --- | --- |
| §1–3 gates,alternatives,nativechain,order,no distributedrollback | Tasks1,6,10–13 |
| §4 ownership,sequential resources,recovery deferral/config | Tasks2,4–6,12 |
| §5 real sixpublication,graph,actual epochs,tombstones/Doc-only retention | Tasks3–5 |
| §6–7 exact real snapshot38/367/PK and pre-rewrap independent cut | Tasks2,4,6 |
| §8 normalUUID plus canonical/mixed I/N(I) physicalidentity | Tasks5–7 |
| §9 native typedsummary,allretained actualbinary/publicsearch | Tasks6–8,12 |
| §10 size Ebarrier,C(P),digest/cipher causaldenial | Task8 |
| §11 independentcomplete malformedmatrix,error/stage/flags | Tasks8–10 |
| §12 real insert/publication/uncertainty faults,custody/order | Tasks10–11 |
| §12 supportedSameManifestSameDest retry vs nondurableRuntime/RESTART | Tasks10–11 |
| §13 exact threegoverningamendments | Task1 parentownership |
| §14 sole independentoracle oldV1/V2/crypto/operatorpreservation | Task12 |
| §15 exactfocused/legacy/static/permittedREADME/reviews/limits | Tasks12–13 |
| §16 causal feasibility checks,not fabricatedGREEN | Tasks2,7–8 and actualevidence |

Self-review of this draft: all38 independently fixed projections and367columns
are included; only one wire transform is locked=true; normalUUID and two
compatibility variants remain separate; genuinebootstrap/recoverywrapper and
nativeissuer are retained; all5 retained binaries must be observed; tombstones
are publicdelete-generated; size/digestnegatives must reach actual native read;
commituncertainty uses realRepo.super COMMIT; originalerror/flags survive late
custodyloss; oldlegacy task is additiveonly; all nativechecks remain NOT RUN.

Remaining source-bound execution questions are causal obligations, not new
product decisions: exported snapshot must prove sameMVCCcut/role/backend;
historicalalias update must be lawful and samephysicalobject; wrongsize/digest
graph must reach genuine import+native read; each malformedcase must tighten
actual branch's exacterror/flag; latefault SameRuntime continuation must match
the unchanged admission/custody contract. A failure requires a reviewed design
finding or scoped repair, never a fake wrapper/material/summary, guard bypass,
assertion relaxation or new frozen authority. No required case is waived.

The parent authored a separate ignored non-test compiler wrapper,
`.devenv/phase5-task11-non-test-compile.sh`, SHA256
`4463f5618696931d36fb114bc566fb0c879f7f3641103febda2fcea1205760cd`.
It accepts exactly one literal environment, dev or prod, fixes the existing
shared dependency path, isolates each environment's build path under this
worktree's .devenv, and execs ONLY mix compile --warnings-as-errors. It neither
changes the test/PG wrapper nor prints the environment. Include it in this
design/plan review and execution seal. Run each separately, under the same
exclusive natural-lifetime/raw-capture protocol, with a fresh private raw:

```sh
devenv shell -- bash .devenv/phase5-task11-non-test-compile.sh dev
devenv shell -- bash .devenv/phase5-task11-non-test-compile.sh prod
```

Both remain NOT RUN. The existing PG wrapper fixes MIX_ENV=test and cannot
qualify these two gates. No nested shell, environment dump, environment
relaxation of native tests or weakened non-test check is authorized here.

Preparation author validation was read-only inspection and ignored-draft
self-review only. Parent fully read that final draft and corrected the two runtime
configuration application names, made the worker-cut causal test depend on
Tasks4–6, corrected coverage section links, and supplied the exact separate
non-test compiler wrapper above. No Mix/VM/compiler/formatter/SQL/service/test/E2E
execution or Task11 source implementation occurred. These are preparation
corrections, not failed Sol implementation-repair rounds or native qualification.
Actual initial independent SPEC review1 subsequently found three Important plan
contracts: completion returns :ok, empty-set seals are derived rather than wire
evidence, and a fault adapter suppressing successful rewrap owns explicit native
capability cleanup. Parent correction1 fixes all three above and submits a new
immutable review generation. Review1 remains FAIL; correction validation and
distinct QUALITY remain required before source GO. No production repair or
Task11 native check occurred, and no frozen authority/assertion was relaxed.
