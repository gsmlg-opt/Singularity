# Singularity v0.2 Phase 3 Unified Lexical Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Search live current Notes and ready Document fragments through one
authenticated PostgreSQL surface, preserving exact immutable provenance and
deterministic canonical reconstruction.

**Architecture:** Add `content.search_entries` without replacing legacy
Note/Asset search. Keep pure values in Core/Retrieval, database construction and
queries in Storage, and authenticated orchestration in Runtime. Reconcile Notes
synchronously and Documents through narrowly authorized lifecycle jobs; use
canonical live/current joins on every search read.

**Tech Stack:** Existing Elixir umbrella, PostgreSQL 17, Ecto/Postgrex, Oban,
`simple` FTS, `pg_trgm`, ExUnit, existing safe SQL and scoped authorization.

---

## Authority, baseline, and execution discipline

The user approved the [Phase 3 design](../specs/2026-10-09-singularity-v0.2-phase-3-unified-lexical-search-design.md)
on 2026-10-09. Its proposal was `7a9a32a0607b80c11c4aea0a156169325d543b94`.
The implementation base is accepted Phase 2 source `c34935a112a2b4b807ed741e8e67e44d4e63eafe`
plus documentation handoff `ff703bd710074738b0391bb2f29d585dc6166d5c`.
The existing isolated worktree is `.trees/v0.2-phase-3-search-design`, branch
`codex/v0.2-phase-3-search-design`; keep using it rather than nesting worktrees.

No merge, push, release, deployment, version bump, Phase 4 write, V3 payload,
browser feature, or Vault feature is authorized here. E2E remains manual; do
not run it as part of focused development. Preserve all earlier worktrees and
their untracked files. Never edit a released migration or weaken an assertion.

Use red/green steps for each enforced behavior. Run parent-owned Mix/database
commands serially, even when agents investigate or edit disjoint files.
Default workers are Sol; use Astra only for an actual architectural decision
or the documented failed-repair escalation. Review spec compliance before
quality, and record exact commands, seeds, results, and review gaps. An agent
dispatch limit permits inline execution; it does not count as an independent
review or authorize claiming acceptance without required review evidence.

All commands below run from the Phase 3 worktree root. Its local `_build`
must remain separate. Reuse only the locked dependency sources:

```sh
export MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps
export MIX_ENV=test
devenv shell -- mix do --app singularity_core test test/singularity/core/source_locator_test.exs test/singularity/core/knowledge_link_values_test.exs
devenv shell -- mix do --app singularity_retrieval test test/singularity/retrieval/note_lexical_search_test.exs
```

Expected: the existing focused contracts pass before any behavior change.
`unbuffer` is unavailable in this checkout's host PATH; use a PTY for live test
output, without adding an unrelated project dependency. The devenv executable
version notice is environment evidence, not an instruction to update the lock.

Integration commands require an owned worktree PostgreSQL instance. Before
starting it, resolve and record the worktree's actual PGDATA/socket/port; never
reuse or stop the borrowed original cluster. Run bootstrap against that exact
owned instance, and preserve an EXIT cleanup trap for owned processes. The
integration task allocates/migrates/drops its own database; it is not permission
to delete another worktree's database or storage root.

## File and interface map

New pure files:

- `apps/singularity_core/lib/singularity/core/search_source.ex`: exact
  owner-free source selector and deterministic entry identity.
- `apps/singularity_core/lib/singularity/core/search_policy.ex`: fixed v1
  ranking/bounds value shared without a Storage→Retrieval dependency.
- `apps/singularity_core/lib/singularity/core/knowledge_search_store.ex`:
  `search(context, query_map)` and `resolve(context, source)` ports.
- `apps/singularity_retrieval/lib/singularity/retrieval/knowledge_search_query.ex`:
  `new(owner_scope_id, public_params)`; the owner argument is trusted Runtime
  context, never a public query field.
- `apps/singularity_retrieval/lib/singularity/retrieval/knowledge_search_result.ex`,
  `knowledge_search_page.ex`, and `knowledge_search.ex`: exact bounded output
  validation and `search(store, context, query)` composition.

New Storage files:

- `priv/repo/migrations/20261009000100_create_unified_search_projection.exs`:
  extension, projection, constraints, RLS, and SELECT-only read grants.
- `priv/repo/migrations/20261009000200_unified_search_reconciliation.exs`:
  private canonical builder and distinct read/Note-write entrypoints.
- `priv/repo/migrations/20261009000300_document_projection_events.exs`:
  forward replacement of lifecycle functions and transactional events.
- `priv/repo/migrations/20261009000400_document_projection_worker.exs`:
  retained-event-bound worker definer.
- `lib/singularity/storage/postgres/search_projection_reconciler.ex`:
  closed SQL adapter for reconciliation and IDs-only enumeration.
- `lib/singularity/storage/postgres/knowledge_search_store.ex` and
  `knowledge_search_cursor.ex`: parameterized search/exact resolution and
  domain-separated bounded keysets.

Storage paths above are under `apps/singularity_storage/`. Existing Note
repository/reconciler, jobs codec/adapter, and the two explicitly approved
legacy restore integration files are surgical modification sites.

New Runtime files under `apps/singularity_runtime/lib/singularity/runtime/`:

- `search/search.ex`, `search/resolve.ex`, `search/rebuild.ex`: authorized
  operations, composed through existing `OperationScope`.
- `documents/projection.ex`: durable Document projection job handler.
- `dto/knowledge_search_result.ex`, `dto/knowledge_search_page.ex`, and
  `dto/knowledge_source.ex`: owner-free closed response values.

Public APIs: `search_knowledge(session, params)`,
`resolve_search_source(session, selector)`, and
`rebuild_search(session, resource_id | :all)`, each with the existing explicit
runtime-config test seam. No standalone Mix command, remote transport, or
new authentication/unlock mechanism is part of this phase.

Internal query keys are exactly `owner_scope_id`, `classification`, `q`,
`kind`, `tag_ids`, `limit`, `cursor`, and `policy_version`. Internal result
keys are exactly `owner_scope_id`, `classification`, `kind`, `resource_id`,
`resource_version_id`, `fragment_id`, `entry_id`, `ordinal`, `title`, `snippet`,
`locator`, `source_inserted_at`, and `rank`. Storage accepts the validated map
shape; it must not depend on Retrieval structs. Runtime removes owner,
classification, entry identity, and ordinal from search summaries.

## Task 1: Pure exact-source identity

**Files:** Create `apps/singularity_core/lib/singularity/core/search_source.ex`
and `apps/singularity_core/test/singularity/core/search_source_test.exs`.

- [ ] Add a failing real-constructor contract before adding the module. Use
  UUIDs `00000000-0000-4000-8000-000000000a01` and
  `00000000-0000-4000-8000-000000000a02` for resource/version:

```elixir
assert Code.ensure_loaded?(Singularity.Core.SearchSource)
input = %{
  kind: :note,
  resource_id: "00000000-0000-4000-8000-000000000a01",
  resource_version_id: "00000000-0000-4000-8000-000000000a02",
  fragment_id: nil
}
assert {:ok, source} = apply(Singularity.Core.SearchSource, :new, [input])
assert Map.from_struct(source) == input
assert {:ok, "note:00000000-0000-4000-8000-000000000a02"} =
         apply(Singularity.Core.SearchSource, :entry_id, [source])
```

- [ ] Run `devenv shell -- mix do --app singularity_core test test/singularity/core/search_source_test.exs`.
  Expected RED: the missing source constructor, not a database or fixture error.
- [ ] Implement a four-field enforced struct and `new/1`, using
  `KnowledgeValidation.attrs/2` and `Types.canonical_uuid/2`. Require all four
  keys after normalization. Revalidate only this module's structs via
  `Map.from_struct/1`; reject other structs. Accept `:note`/`"note"` and
  `:document`/`"document"` through fixed clauses. A Note requires nil fragment;
  a Document requires exactly 64 lowercase hexadecimal bytes.

```elixir
def entry_id(input) do
  with {:ok, source} <- new(input) do
    case source.kind do
      :note -> {:ok, "note:" <> source.resource_version_id}
      :document -> {:ok, "document:" <> source.fragment_id}
    end
  end
end
```

- [ ] Add one failing case at a time for string keys, matching/conflicting
  aliases, missing keys, extra owner/locator/text fields, unknown kind, malformed
  UUIDs, invalid fragment bytes/length/case, wrong-kind fragments, keyword
  duplicate conflicts, other structs, and handcrafted invalid/extra-field
  structs. Every public entrypoint returns the existing sanitized
  `{:error, %Error{code: :invalid}}`, without input content.
- [ ] Run the owning file and the baseline locator/link files, format those
  files, review spec then quality, and commit
  `feat(core): add exact search source selectors`.

## Task 2: Typed query, result, page, and shared policy

**Files:** Create the remaining pure files in the interface map and tests
`apps/singularity_core/test/singularity/core/search_policy_test.exs`,
`apps/singularity_retrieval/test/singularity/retrieval/knowledge_search_test.exs`.

- [ ] Add failing query tests with a separately supplied owner:

```elixir
owner = "00000000-0000-4000-8000-000000000a03"
assert {:ok, query} = KnowledgeSearchQuery.new(owner, %{q: "  知识  ", kind: "document"})
assert %{owner_scope_id: ^owner, q: "知识", kind: :document, tag_ids: [],
         limit: 20, cursor: nil, classification: :private, policy_version: 1} = query
assert {:error, %Error{code: :invalid}} =
         KnowledgeSearchQuery.new(owner, %{owner_scope_id: owner})
```

- [ ] Implement `SearchPolicy.current/0` as a fixed pure value containing
  `version: 1`, `rank_scale: 1_000_000`, `fts_weight: 4`, `title_weight: 2`,
  `literal_weight: 1`, `title_threshold: 0.3`, `max_rank: 7_000_000`,
  `query_bytes: 1_024`, `cursor_bytes: 2_048`, `tag_count: 20`,
  `page_limit: 50`, `snippet_codepoints: 160`, `snippet_bytes: 640`,
  `statement_timeout_ms: 5_000`, and `rebuild_batch_size: 100`.
  No mutable configuration, process, Ecto, or SQL dependency belongs here.
- [ ] Implement exact public-key validation before trimming/deduplication;
  preserve strict duplicate aliases. Sort/dedupe canonical tag UUIDs only after
  the raw list's 20-element bound is checked. Empty q lists; nil cursor is
  terminal. Reject unknown owner/classification/policy fields and forged structs.
- [ ] Define the Core behaviour callbacks `search/2` and `resolve/2`, returning
  the existing `Error.t()` on failure. Search returns exactly
  `{:ok, %{items: list, next_cursor: binary | :done}}`.
- [ ] Validate all result keys, owner/classification, selector/entry-ID
  equality, ordinal, source timestamp, canonical locator, title bounds inherited
  from source types, snippet codepoint and byte bounds, and integer rank bound.
  Validate page size against the query limit, reject duplicate entry IDs,
  require a bounded next cursor or `:done`, and expose nil for terminal pages.
  Malformed adapter output becomes sanitized retryable `storage_unavailable`.
- [ ] Use a contract fake only at the persistence port; assert the actual
  retrieval validator rejects each malformed field, foreign owner, wrong kind,
  malformed locator, oversized page, and raised/thrown content-bearing error.
  Constructor tests use real values, not mocks of constructors.

```sh
devenv shell -- mix do --app singularity_core test test/singularity/core/search_source_test.exs test/singularity/core/search_policy_test.exs
devenv shell -- mix do --app singularity_retrieval test test/singularity/retrieval/knowledge_search_test.exs test/singularity/retrieval/note_lexical_search_test.exs
```

- [ ] Observe RED then GREEN for each contract, preserve old search behavior,
  review, and commit `feat(retrieval): validate unified knowledge search contracts`.

## Task 3: Projection schema, extension, and production-role boundaries

**Files:** Create the `20261009000100` migration and
`apps/singularity_storage/test/singularity/storage/search_projection_schema_test.exs`.

- [ ] Add an integration module using `Singularity.Storage.DataCase`,
  `async: false`, and `@moduletag :integration`. Assert the new table/extension
  are present on a fresh application database, then observe RED:

```elixir
Fixtures.with_owner(fn ->
  assert %{rows: [["search_extensions"]]} =
           query!(MigrationRepo, """
           SELECT n.nspname FROM pg_extension e
           JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_trgm'
           """)
end)
```

- [ ] Under `SET LOCAL ROLE singularity_table_owner`, create the controlled
  `search_extensions` schema and install trusted `pg_trgm` in that schema.
  Preflight rejects an existing extension in another namespace. Revoke PUBLIC
  schema access; grant web only required USAGE/EXECUTE. Do not change role
  attributes or bootstrap the extension in the `postgres` maintenance DB.
- [ ] Create `content.search_entries`: text primary key `entry_id`, UUID
  `resource_id/resource_version_id/vault_id`, private `classification`, text
  `kind`, nullable UUID `note_resource_version_id`, nullable text `fragment_id`,
  bigint `ordinal`, title/body text, locator jsonb, immutable source timestamp,
  and projection format integer constrained to 1. Use canonical source bounds.
  Add generated title-A/body-D simple FTS vector and its GIN index, trigram
  title/body GIN indexes, and owner/kind/source-time/identity indexes.
- [ ] Use existing unique keys; do not alter canonical data or add a universal
  current-head FK. Conditional references must use MATCH SIMPLE:

```sql
FOREIGN KEY (note_resource_version_id, resource_id, vault_id, classification)
  REFERENCES content.note_versions
    (resource_version_id, resource_id, vault_id, classification),
FOREIGN KEY (fragment_id, resource_id, resource_version_id, vault_id, classification)
  REFERENCES content.document_fragments
    (id, resource_id, resource_version_id, vault_id, classification)
```

  Also bind the common immutable version through
  `resource_versions(id,resource_id,vault_id,classification)`. Check the active
  branch cannot bypass a nullable FK, Note ordinal is zero, entry IDs match
  their source, and Document ordinals/locators agree with canonical construction.
  Enforce one Note row per resource and one row per Document fragment.
- [ ] ENABLE/FORCE RLS; preserve the established table-owner internal policy.
  The web policy requires nonempty scoped principal/owner, matching row owner,
  and `core.principal_is_authorized(principal, owner)`. Grant only web SELECT on
  the new projection and existing `tags/resource_tags`. Runtime projection DML,
  worker Document SELECT, and all tag mutation grants remain denied.
- [ ] Add actual-role cross-owner/missing-context and ACL tests, FK mismatch
  tests, old-table grant preservation, and forward-upgrade tests through
  `MigrationTestEnvironment.with_database(20261008000000, callback)`.
  No temporary `KnowledgeTestGrants` permissions are acceptance evidence.

```sh
devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/search_projection_schema_test.exs
```

- [ ] Record extension package/version/schema and least-privilege installation
  results. Review and commit `feat(storage): add constrained unified search projection`.

## Task 4: Canonical builder and dual Note reconciliation

**Files:** Create the `20261009000200` migration,
`apps/singularity_storage/lib/singularity/storage/postgres/search_projection_reconciler.ex`,
and `apps/singularity_storage/test/singularity/storage/postgres/search_projection_reconciler_test.exs`.
Modify `apps/singularity_storage/lib/singularity/storage/postgres/note_projection_reconciler.ex`
and its existing test; modify `note_repository.ex` only if its established
reconciliation calls cannot preserve the owning transaction/lock order.

- [ ] With `KnowledgeFixtures.source!/0`, `note!/1`, and `ready_document!/1`,
  assert a canonical builder creates exactly one Note and every canonical
  Document fragment with source timestamps, locators, and deterministic IDs.
  Observe RED before creating the definer/adapter.
- [ ] Add an ungranted private SQL helper
  `content.reconcile_search_resource_internal(owner uuid, resource uuid)`.
  Lock Resource `FOR UPDATE`, then Document version when relevant. Delete this
  resource's old derived rows, then INSERT SELECT only eligible canonical data
  in the same transaction. Notes read current typed Markdown; Documents read
  current ready fragments. Tombstones/non-ready sources leave zero entries.
  Never accept content, locator, or an arbitrary SQL fragment from callers.
- [ ] Add distinct public definer entrypoints for scoped read maintenance and
  existing Note-write reconciliation. They derive owner/principal from scoped
  GUCs and revalidate the appropriate existing capability before invoking the
  private helper. Preserve fixed search path, explicit owner, and EXECUTE ACLs.
  Return count/status only. Do not make `note.write` require `note.read`.
- [ ] In `NoteProjectionReconciler.reconcile/2`, acquire the resource
  `FOR UPDATE` before either projection and keep the old projection's
  delete-before-head-change rule in owning mutations. Both projection changes
  and the mutation receipt/outbox effect must commit or roll back together.
  Existing Note repair jobs therefore repair both through the same reconciler.
- [ ] Keep `rebuild_vault/2` as the existing legacy-only reconstruction used
  by restore. Extract a private legacy reconciliation helper: the normal
  `reconcile/2` composes it with the guarded unified Note-write path, whereas
  `rebuild_vault/2` calls only the legacy helper under its established caller
  authority. Task 10 separately invokes the ungranted unified SQL builder from
  the already-authorized owner transaction. Do not branch on ambient DB role,
  add a public bypass flag, or require a live session for legacy restore.
- [ ] Add create/save/conflict-only/merge/tombstone/restore and failure-rollback
  regressions. Preserve every existing Note search summary/cursor assertion.
  Force competing reconcilers through deterministic barriers to test lock order.

```sh
devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/search_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs
```

- [ ] Review and commit `feat(storage): reconcile canonical unified search entries`.

## Task 5: Transactional Document lifecycle events

**Files:** Create the `20261009000300` migration and
`apps/singularity_storage/test/singularity/storage/postgres/document_projection_events_test.exs`.
Read, but never modify, the existing extraction-attempt, terminal-tombstone,
runtime-mutations, and worker-bridge migrations.

- [ ] Add failing integration tests around actual `complete`, `delete`, and
  `restore` paths. Assert exactly one identifier-only event on each real
  transition, none for terminal/no-op replay, and distinct keys across two
  complete delete→restore cycles on the same immutable version/generation.
- [ ] Forward-replace the current definitions of
  `content.complete_document_extraction`, `content.delete_document_runtime`,
  and `content.restore_document_runtime`, preserving all existing checks and
  signatures. Add event insertion only after the successful real state change,
  in the same transaction. Keep the exact-ready replay early return event-free.
  Deletion also deletes the resource's unified rows synchronously.
- [ ] Event types are `document.ready`, `document.deleted`,
  `document.restored`; payload is exactly the two IDs:

```elixir
%{"resource_id" => resource_id, "resource_version_id" => resource_version_id}
```

  Generate one event UUID within the locked transition and set the key to
  `document-projection:<event UUID>`. Persist the actual authenticated actor,
  checked authorization epochs, `asset.read`, private classification, and the
  current immutable revision snapshot using the existing outbox shape. Never
  substitute creator identity for the actual actor or use generation as the key.
- [ ] Express Resource-before-Document row locking explicitly in the forward
  definition of `document_runtime_target`; preserve existing outer locks and
  every creator/capability/isolation check. A completion after tombstone still
  persists valid canonical extraction, but its projection remains hidden.
- [ ] Assert event-insertion failure rolls back the canonical transition,
  source pin/bytes remain retained, and old extraction retry/recovery events
  keep their unchanged contract. No extractor or custody changes are allowed.

```sh
devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_projection_events_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
```

- [ ] Review and commit `feat(storage): emit durable document projection events`.

## Task 6: Narrow Document projection worker and dispatch

**Files:** Create the `20261009000400` migration,
`apps/singularity_runtime/lib/singularity/runtime/documents/projection.ex`,
`apps/singularity_storage/test/singularity/storage/postgres/document_projection_worker_test.exs`,
and `apps/singularity_runtime/test/singularity/runtime/job_dispatcher_document_projection_test.exs`.
Modify Storage `jobs/envelope_codec.ex`, `jobs/oban_adapter.ex`, the new
reconciler adapter, Runtime `outbox_dispatcher.ex`, `job_dispatcher.ex`,
`application.ex`, and existing owning codec/outbox tests; add only the required
queue entry in `config/config.exs` if the established queue mapping needs one.

- [ ] RED: reject an otherwise valid `document_projection` envelope before
  adding it to the closed codec/dispatcher mappings; test malformed keys,
  content-bearing payloads, wrong capability/classification, and key/job mismatch.
- [ ] Add a worker-only definer with the accepted bridge prefix:

```sql
(requested_resource uuid, requested_version uuid, requested_job uuid,
 expected_revision bigint, requested_principal_epoch bigint,
 requested_owner_epoch bigint)
```

  Revalidate transaction isolation, scoped context, authorization lock, live
  owner/principal/capability, creator equality, checked epochs, and exact retained
  outbox type/key/payload/revision/identity. Dispatch acknowledgment is not
  retirement. It invokes the private current-state builder and returns count
  metadata only. Worker canonical/projection SELECT and direct DML stay denied.
- [ ] Add `document_projection` JSON codec validation with `asset.read`,
  private classification, exact two-ID payload, and event-UUID idempotency key.
  Map the three events to that job; keep durable reservations keyed by existing
  outbox identity. Runtime handler validates the closed envelope before DB work
  and routes sanitized errors through existing retry/terminal behavior.
- [ ] Test duplicate/out-of-order events; ready-after-delete and
  delete-after-restore must reconcile current state. Cover revoked/expired
  authority, wrong creator/owner, substituted IDs/epochs, absent/retired events,
  no source content in job metadata, and preserved extraction envelopes.

```sh
devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/job_dispatcher_document_projection_test.exs apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs
devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_projection_worker_test.exs
```

- [ ] Review and commit `feat(runtime): dispatch authorized document projection jobs`.

## Task 7: PostgreSQL search, literal fallback, and signed keysets

**Files:** Create `apps/singularity_storage/lib/singularity/storage/postgres/knowledge_search_store.ex`,
`knowledge_search_cursor.ex`, and tests in the same test directory named
`knowledge_search_store_test.exs` and `knowledge_search_pagination_test.exs`.

- [ ] RED: a real canonical Note plus ready Document search with empty q returns
  both kinds and exact version/fragment IDs. Use fresh production-role scoped
  queries, not direct fixture grants to the new table.
- [ ] Validate the internal query map again before repository work. Use
  SafeSQL bound parameters, the same canonical visibility joins for every
  branch, AND tag membership through owner-bound canonical EXISTS, and a
  deduplicated candidate set. Never hydrate all bodies into Elixir to rank.
- [ ] Apply transaction-local five-second statement timeout and fixed trigram
  threshold. The SQL policy is exactly:

```sql
plainto_tsquery('simple', $1)
```

  Combine weighted FTS match, escaped literal ILIKE on title/body, and title
  trigram similarity at 0.3 for at least three Unicode codepoints. Use
  schema-qualified `search_extensions` functions/operators/opclasses. Escape
  backslash, `%`, and `_` as literals; no caller syntax is SQL or tsquery code.
- [ ] Compute integer score `4*F + 2*T + L` from the approved million-scale
  formula; return `left(body,160)` only as the snippet. Order by rank DESC,
  immutable source time DESC, resource UUID ASC, version UUID ASC, ordinal ASC,
  entry ID COLLATE `C` ASC. Apply the complete keyset predicate before LIMIT.
- [ ] Cursor functions encode/decode the exact ordering tuple with distinct
  HMAC domains `knowledge-search-filter:v1` and `knowledge-search-cursor:v1`.
  Canonically frame fields, bind owner/private/q/kind/sorted tags/policy version,
  use the existing secret of at least 32 bytes, and compare MACs in constant
  time. Reject unknown keys, malformed/oversized payloads, noninteger ranks,
  invalid identities/timestamps, wrong filters, and legacy cursor domains before
  SQL. No plaintext q/title/locator in the token; limit is not fingerprinted.
- [ ] Cover FTS-only, title typo, CJK/short substrings, literal wildcards,
  punctuation/empty q, tag filters, foreign/deleted/nonready/historical/conflict
  rows, tied mixed-kind paging, body/snippet boundaries, and timeout sanitization.

```sh
devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs
```

- [ ] Review and commit `feat(storage): search version-pinned knowledge with stable keysets`.

## Task 8: Authenticated API and exact source reads

**Files:** Create Runtime `search/search.ex`, `search/resolve.ex`, the three DTO
files in the map, and `apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs`.
Modify Runtime `api.ex` and the new Storage search adapter for `resolve/2`.

- [ ] RED: injected-runtime API rejects owner overrides and converts a valid
  internal page to exactly the public result keys; malformed/foreign adapter
  values never escape. Use the established `note_reads_test.exs` scope fake
  only for orchestration, followed by actual-role integration coverage.
- [ ] Compose existing `OperationScope.with_read_request/4`: Note uses
  `note.read` plus existing unlock; Document uses `asset.read` and
  `requires_unlocked?: false`; mixed uses both capabilities, sorted and conjunctive,
  with the Note unlock requirement. Never silently return only one authorized kind.
- [ ] Add exact `SearchSource` resolution independent of projection presence.
  Reuse NoteRepository exact version lookup; read Document fragment by full
  resource/version/fragment/owner identity and live parent/ready state. Do not
  join a current-head equality into historical exact resolution. Revalidate
  canonical locator, identity, and content bounds before constructing the DTO.
- [ ] API errors distinguish malformed `invalid` from identity/tombstone
  `not_found`; preserve established authorization errors. Return exact title/body
  and locator, never source storage coordinates or a silently updated head.
  No binary download/custody change belongs in this use case.
- [ ] Real tests remove the projection, advance a Note head, and resolve the
  older result; forge each identity component and verify failure. Assert public
  API dependency boundaries and all legacy Notes/Asset API contracts remain intact.

```sh
devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs
devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs
```

- [ ] Review and commit `feat(runtime): expose authenticated unified search and exact sources`.

## Task 9: Deterministic in-process maintenance

**Files:** Create Runtime `search/rebuild.ex` and
`apps/singularity_runtime/test/singularity/runtime/search_rebuild_test.exs`.
Modify the new projection adapter and Runtime `api.ex`.

- [ ] RED: rebuild one resource succeeds after its projection is removed;
  full rebuild discovers all canonical Note/Document resources including tombstones.
  Do not enumerate through the public live Document list or stale projection table.
- [ ] Add bounded IDs-only UUID-keyset enumeration with at most 100 IDs per
  page. Full command requires both read capabilities before enumeration; each
  resource transaction reauthorizes. One-resource command determines only
  owner-scoped canonical kind before requiring that kind's read authority.
- [ ] Reuse atomic private canonical construction through the read-authorized
  entrypoint. No event identity is required for manual maintenance. Stop on a
  sanitized failure, never skip a failed resource and report success. Return
  counts only; no whole-owner transaction, truncate, owner override, or credentials.
- [ ] Exercise the actual running Runtime session path:

```elixir
assert {:ok, %{resources: 2, entries: 2}} =
         Api.rebuild_search(config, live_session, :all)
```

  The fixture supplies the established live session/config; no new login/unlock
  path or standalone Mix task is introduced. Fresh independent custody does not
  regain a required unlock from a token/DTO.
- [ ] Compare complete ordered visible rows, rank, timestamps, locators, and
  paging after deleting all derived entries and rebuilding. Test interrupted
  restart, revocation between pages, and deterministic concurrent delete/restore.
  Assert immutable canonical rows/digests are byte-identical before and after.
- [ ] Prove the initial backfill path for canonical Notes and ready Documents
  that predate this projection, with no later lifecycle event to populate it.
  Upgrade a historical fixture, invoke the guarded in-process full rebuild,
  and compare its exact entries with a fresh canonical rebuild. Record this
  command as a required operator step before activation; migrations do not
  silently broaden runtime authority or require content-bearing job payloads.
  No live deployment or production backfill is authorized by this local test.

```sh
devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/search_rebuild_test.exs
devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/search_rebuild_test.exs
```

- [ ] Review and commit `feat(runtime): rebuild unified search from canonical resources`.

## Task 10: Minimal legacy restore compatibility

**Files:** Modify only the derived-projection integration in
`apps/singularity_storage/lib/singularity/storage/backup/restorer.ex` and
`apps/singularity_storage/lib/singularity/storage/backup/integrity_audit.ex`;
add `apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs`
and extend owning existing restore integration assertions without weakening them.

- [ ] RED: a supported V2 Note restore completes with canonical Notes but no
  unified results under the new API. Also assert nonempty derived destination
  rows are not silently ignored. Existing V1 behavior remains zero unified rows.
- [ ] Add `content.search_entries` to Restorer's excluded/destination-check
  inventory; never to canonical V1/V2 payloads. In
  `IntegrityAudit.rebuild_locked/2`, rebuild and verify unified Note rows from
  the restored canonical inventory during the existing pre-completion stage.
  Keep existing Asset/Note verification and evidence contracts intact; the
  preserved legacy-only `NoteProjectionReconciler.rebuild_vault/2` from Task 4
  must not enter the live `note.write` definer. Add a regression without live
  principal/session context so this separation is exercised, not inferred.
- [ ] Invoke the private helper only through the existing restore-owned
  table-owner transaction and authenticated restore binding. No Runtime session,
  new capability, unlock, event, or public EXECUTE grant is introduced. Preserve
  restore's established exclusive locks rather than imposing the online sweep.
- [ ] Assert the accepted unsupported-canonical guard still refuses live and
  tombstoned Documents/tags. No V3, Document restore, backup wire-format change,
  key/recovery redesign, or unrelated Vault repair is authorized.

```sh
devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs
devenv shell -- mix singularity.test.restore
```

- [ ] Report both frozen-substrate compatibility file touches explicitly,
  review their complete diff, and commit `fix(storage): rebuild unified note search after legacy restore`.

## Task 11: Query plans, privacy, and full phase qualification

**Files:** Create
`apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_plan_test.exs`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_search_privacy_test.exs`,
and `docs/verification/2026-10-09-phase-3-acceptance.md`.
Update only Phase 3 checklist/evidence and active-phase documentation on acceptance.

- [ ] Add deterministic synthetic, analyzed query-plan fixtures. Verify
  selective FTS/trigram queries have viable indexed plans without forcing the
  planner. Record the intentional nonselectivity of short literal queries;
  verify the fixed timeout fails with a sanitized error, not an empty success.
- [ ] Add diagnostic canaries for q/title/body/snippet/locator headings/tag labels
  across success, malformed input, adapter failure, SQL cancellation, retries,
  exact-source denial, and rebuild failure. Assert no raw content in logs,
  supported telemetry, job/outbox/audit metadata, or exception messages.
- [ ] Run all new owning suites plus the directly affected legacy Note,
  Document-worker, codec/outbox, and V1/V2 restore suites. Record source SHA,
  exact commands, seeds, counts, forward migrations/grants, and reviews.
- [ ] After scoped gates pass, commit the candidate and run the entire ordered
  README gate from that exact clean SHA with owned process identity and cleanup.
  This includes the explicitly manual acceptance run, not an automatic workflow
  trigger. Retain the Phase 2 residual login race and Poppler qualification until
  separately evidenced; do not repair unrelated failures under this plan.

```sh
devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
```

  These static checks supplement, not replace, the complete README sequence.
  No green subset is phase or release acceptance.
- [ ] Obtain independent spec and quality review of the complete candidate.
  Resolve findings within approved scope; route internal-organization dependency
  defects upstream under AGENTS.md. Preserve any failed gate's evidence rather
  than relabeling it passing after a narrower rerun.
- [ ] Verify every Phase 3 deliverable against runtime/source evidence, record
  remaining risks and no Vault feature work, and commit the local acceptance
  report. Stop at the next separate Phase 4 design gate; do not mark the full
  release goal complete or publish anything merely because Phase 3 passes.

## Coverage and execution record

Tasks 1–2 cover typed values and closed contracts; Task 3 covers extensions,
schema, indexes and read grants; Tasks 4–6 cover current-head projection and
lifecycle/durable authorization; Tasks 7–8 cover ranking, filters, keysets, exact
source resolution and Runtime APIs; Task 9 covers reconstruction; Task 10 covers
required legacy compatibility; Task 11 covers plans, privacy, review and the
complete acceptance gate. Legacy search compatibility is checked in Tasks
2, 4, 7, 8 and 11. No master Phase 3 checkbox is complete before executed evidence.

Append actual execution results beneath the owning task or in the acceptance
record. Do not turn intended commands, source inspection, temporary test grants,
or successful mocks into claims about live production-role behavior.

### Approval and planning evidence, 2026-10-09

- Existing Core locator/link baseline: 21 tests and 2 properties, zero
  failures (seed 173027). Existing Retrieval Note lexical baseline: 13 tests,
  zero failures (seed 315155). Both used the commands above with explicit
  `MIX_ENV=test` and shared locked dependency sources; neither used PostgreSQL
  or E2E. A first `mix do` invocation without `MIX_ENV=test` stopped before
  tests with Mix's dev-environment error; it was an invocation failure, not a
  failing application assertion.
- Independent read-only plan review found three issues: the migration-repo
  fixture, restore's legacy-only path, and initial backfill. The corrections
  above were independently rechecked and passed. This is plan review only.
- All 14 local Markdown links across the changed README/spec/plan resolved;
  `git diff --check` passed. No runtime behavior is enabled by these documents.
- A new implementation worker could not be dispatched because the session's
  agent thread limit was reached. Continue inline under executing-plans, reuse
  available read-only reviewers, and do not equate inline checks with an
  independent implementation review.
