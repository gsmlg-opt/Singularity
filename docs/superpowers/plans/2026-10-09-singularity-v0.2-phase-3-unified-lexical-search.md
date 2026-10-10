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

- [x] Add a failing real-constructor contract before adding the module. Use
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

- [x] Run `devenv shell -- mix do --app singularity_core test test/singularity/core/search_source_test.exs`.
  Expected RED: the missing source constructor, not a database or fixture error.
- [x] Implement a four-field enforced struct and `new/1`, using
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

- [x] Add focused cases for string keys, matching/conflicting
  aliases, missing keys, extra owner/locator/text fields, unknown kind, malformed
  UUIDs, invalid fragment bytes/length/case, wrong-kind fragments, keyword
  duplicate conflicts, other structs, and handcrafted invalid/extra-field
  structs. Every public entrypoint returns the existing sanitized
  `{:error, %Error{code: :invalid}}`, without input content.
- [x] Run the owning file and the baseline locator/link files, format those
  files, review spec then quality, and commit
  `feat(core): add exact search source selectors`.

Task 1 execution: missing-module RED was 1/1 failing (seed 507621), followed
by 1/1 passing (971676). The expanded identity/invalid-input group produced
3/11 failures (372617), exposing Document support and extra-alias forged
struct acceptance. After correction, the owning 11 tests plus baseline
21 tests and 2 properties passed (429003), then passed again after formatting
(745052). Scoped formatting passed. Separate
read-only spec and quality reviewers both passed these two files; neither
claimed runtime or phase acceptance. No database, grant, API, or Vault change.

## Task 2: Typed query, result, page, and shared policy

**Files:** Create the remaining pure files in the interface map and tests
`apps/singularity_core/test/singularity/core/search_policy_test.exs`,
`apps/singularity_retrieval/test/singularity/retrieval/knowledge_search_test.exs`.

- [x] Add failing query tests with a separately supplied owner:

```elixir
owner = "00000000-0000-4000-8000-000000000a03"
assert {:ok, query} = KnowledgeSearchQuery.new(owner, %{q: "  知识  ", kind: "document"})
assert %{owner_scope_id: ^owner, q: "知识", kind: :document, tag_ids: [],
         limit: 20, cursor: nil, classification: :private, policy_version: 1} = query
assert {:error, %Error{code: :invalid}} =
         KnowledgeSearchQuery.new(owner, %{owner_scope_id: owner})
```

- [x] Implement `SearchPolicy.current/0` as a fixed pure value containing
  `version: 1`, `rank_scale: 1_000_000`, `fts_weight: 4`, `title_weight: 2`,
  `literal_weight: 1`, `title_threshold: 0.3`, `max_rank: 7_000_000`,
  `query_bytes: 1_024`, `cursor_bytes: 2_048`, `tag_count: 20`,
  `page_limit: 50`, `snippet_codepoints: 160`, `snippet_bytes: 640`,
  `statement_timeout_ms: 5_000`, and `rebuild_batch_size: 100`.
  No mutable configuration, process, Ecto, or SQL dependency belongs here.
- [x] Implement exact public-key validation before trimming/deduplication;
  preserve strict duplicate aliases. Sort/dedupe canonical tag UUIDs only after
  the raw list's 20-element bound is checked. Empty q lists; nil cursor is
  terminal. Reject unknown owner/classification/policy fields and forged structs.
- [x] Define the Core behaviour callbacks `search/2` and `resolve/2`, returning
  the existing `Error.t()` on failure. Search returns exactly
  `{:ok, %{items: list, next_cursor: binary | :done}}`.
- [x] Validate all result keys, owner/classification, selector/entry-ID
  equality, ordinal, source timestamp, canonical locator, title bounds inherited
  from source types, snippet codepoint and byte bounds, and integer rank bound.
  Validate page size against the query limit, reject duplicate entry IDs,
  require a bounded next cursor or `:done`, and expose nil for terminal pages.
  Malformed adapter output becomes sanitized retryable `storage_unavailable`.
- [x] Use a contract fake only at the persistence port; assert the actual
  retrieval validator rejects each malformed field, foreign owner, wrong kind,
  malformed locator, oversized page, and raised/thrown content-bearing error.
  Constructor tests use real values, not mocks of constructors.

```sh
devenv shell -- mix do --app singularity_core test test/singularity/core/search_source_test.exs test/singularity/core/search_policy_test.exs
devenv shell -- mix do --app singularity_retrieval test test/singularity/retrieval/knowledge_search_test.exs test/singularity/retrieval/note_lexical_search_test.exs
```

- [x] Observe RED then GREEN for the contract groups, preserve old search behavior,
  review, and commit `feat(retrieval): validate unified knowledge search contracts`.

Task 2 execution: policy/query constructor RED was 1 Core and 10 Retrieval
failures (seed 797294), then GREEN with the 13 legacy search tests (100339).
Result/port/page RED produced 14/24 failures (388280), then passed alongside
legacy search (881689). A direct improper-list page regression failed 1/24
(463926); bounded-list validation fixed it. Independent spec review passed.
Independent quality review identified extra fields surviving inside a forged
DateTime. Its direct/composition regression failed 1/25 (484448); exact UTC
timestamp shape checks fixed it without changing the shared helper. The
reviewer rechecked the fix and passed the bounded Task 2 quality review.

Final focused command (the environment exports above apply):

```sh
devenv shell -- mix test apps/singularity_core/test/singularity/core/search_source_test.exs apps/singularity_core/test/singularity/core/search_policy_test.exs apps/singularity_core/test/singularity/core/source_locator_test.exs apps/singularity_core/test/singularity/core/knowledge_link_values_test.exs apps/singularity_retrieval/test/singularity/retrieval/knowledge_search_test.exs apps/singularity_retrieval/test/singularity/retrieval/note_lexical_search_test.exs
```

Result: Core 33 tests plus 2 properties; Retrieval 38 tests (25 new, 13
legacy); zero failures, seed 636201. All eight new files passed scoped
formatting and `git diff --check`; xref reported no cycles. These are pure
contract checks, not PostgreSQL, Runtime authorization, or Phase 3 acceptance.
No Vault file or legacy search implementation changed; E2E was not run.

Task 2 follow-up `a704d34`: a forged timestamp precision could discard ordering
microseconds during ISO serialization. Its focused regression first failed
1/26 (seed 209188); requiring a lossless UTC round trip fixed it. Valid zero,
three, and six-digit fractional precision remains supported. Independent spec
and quality reviews passed this correction together with the pure cursor
slice below.

## Task 3: Projection schema, extension, and production-role boundaries

**Files:** Create the `20261009000100` migration and
`apps/singularity_storage/test/singularity/storage/search_projection_schema_test.exs`.

### Task 3a: Approved administrator provisioning amendment

The user approved this amendment on 2026-10-10. The existing Phase 3 worktree
at `aa8e473` remains the implementation base. Complete this prerequisite with
its own focused evidence before adding the projection migration.

**Create:**

- `apps/singularity_storage/lib/singularity/storage/search_extension_bootstrap.ex`
- `apps/singularity_storage/priv/repo/bootstrap_search_extensions.sh`
- `apps/singularity_storage/priv/repo/bootstrap_search_extensions.sql`
- `apps/singularity_storage/test/singularity/storage/search_extension_bootstrap_test.exs`

**Modify narrowly:** Storage `test_environment.ex`, test support
`migration_test_environment.ex`, owning `test_environment_test.exs`,
`migrations_test.exs` and `configuration_test.exs` as required for regressions;
`docs/deployment/docker.md` and the README development explanation. Reuse
`bootstrap_roles.exs` unchanged. Do not change existing role provisioning,
runtime configuration, released migrations, or Vault files.

- [x] Add failing pure wrapper transport tests and real PostgreSQL contracts.
  The initial fresh-application schema RED below is already observed. Add
  missing bootstrap entrypoint assertions before implementation:

```elixir
assert Code.ensure_loaded?(Singularity.Storage.SearchExtensionBootstrap)
assert :ok = apply(Singularity.Storage.SearchExtensionBootstrap, :run!, [database])
```

- [x] Implement only `SearchExtensionBootstrap.run!(database)` as a task-side
  shell adapter. Validate an explicit bounded simple database name and reject
  `postgres`, `template0`, and `template1`. Raise a fixed sanitized error on
  subprocess failure; never persist an administrator Repo/configuration.
  Wrapper credential transport uses the existing helper with checked exit
  status, an anonymous libpq service FD, an explicit `--dbname` argument, and
  `ON_ERROR_STOP`; unset credential variables before executing `psql`.
- [x] Share one transactional SQL file between the wrapper and operator
  instructions. Verify administrator authority and target first. For a new
  installation create the controlled schema and trusted extension under the
  table-owner role, return to administrator authority for PUBLIC function
  revocation, then delegate only these signatures:

```sql
GRANT EXECUTE ON FUNCTION search_extensions.similarity(text, text),
  search_extensions.similarity_op(text, text)
  TO singularity_table_owner WITH GRANT OPTION;
```

  Verify `pg_trgm` 1.6, ownership and exact ACLs after installation. Compatible
  reruns must preserve state before and after final migration grants; wrong
  schema/owner/version/ACL state fails without changing it. No role attribute,
  membership, function ownership, or final runtime grant changes belong here.
- [x] Hook fresh database provisioning immediately after `create_database!/1`
  and before repository configuration, with bounded cleanup on bootstrap
  failure. In historical setup, call bootstrap inside the second protected
  `try`, after its existing table-owner CREATE grant and before Migrator.run.
  Preserve its existing close/restore failure path. No admin connection enters
  the application supervision tree or runtime repository settings.
- [x] Prove actual-role function/schema ACLs, table-owner grant options,
  idempotency, wrong namespace/owner/ACL rejection, non-admin failure, and real
  fresh/historical cleanup on failure. Preserve existing role-attribute and
  membership assertions. Wrapper fakes establish transport hygiene only.
- [x] Document the explicit per-application administrator provisioning step
  before migrations, the supported package/version, failure handling, and the
  absence of administrator credentials from runtime env files.

```sh
devenv shell -- mix test apps/singularity_storage/test/singularity/storage/search_extension_bootstrap_test.exs apps/singularity_storage/test/singularity/storage/configuration_test.exs apps/singularity_storage/test/singularity/storage/test_environment_test.exs
devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/search_extension_bootstrap_test.exs apps/singularity_storage/test/singularity/storage/test_environment_test.exs apps/singularity_storage/test/singularity/storage/migrations_test.exs apps/singularity_storage/test/singularity/storage/roles_test.exs
```

- [x] Obtain spec then quality review, record exact execution evidence, and
  commit `feat(storage): provision constrained search extensions`.

Task 3a execution evidence, 2026-10-10 (locally verified prerequisite):

- Live `origin` default HEAD and `main` were rechecked at
  `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`. Work remains isolated in
  `codex/v0.2-phase-3-search-design`; amendment authority is recorded in
  `b66849f` after independent plan review passed.
- Pre-change unit characterization of `test_environment_test.exs`: **12 tests,
  0 failures, 1 integration excluded**, seed `10736`.
- Pre-change real PostgreSQL characterization of `test_environment_test.exs`,
  `migrations_test.exs`, and `roles_test.exs`: **61 tests, 0 failures,
  11 excluded**, seed `280003`.
- New bootstrap contracts before implementation: unit **RED, 14 tests,
  6 failures, 8 integration excluded**, seed `35404`; actual PostgreSQL
  **RED, 14 tests, 8 failures, 6 excluded**, seed `569336`. All failures identify
  the absent wrapper or `SearchExtensionBootstrap` module, not setup failures.
- A 96 KiB fake credential-service contract reproduced Bash's temporary-file
  backing of a large here-string: **RED, 15 tests, 1 failure, 14 excluded**,
  seed `490770`. A separate non-secret descriptor probe confirmed the backing
  file. Feeding the checked helper output through an anonymous pipe then passed
  the scoped bootstrap/configuration/test-environment unit selection:
  **37 tests, 0 failures, 10 excluded**, seed `871815`.
- Attaching an unexpected function from `public` to the extension reproduced
  missing member-namespace validation: **RED, 16 tests, 1 failure,
  14 excluded**, seed `55299`. After the guard, the scoped real PostgreSQL
  bootstrap/lifecycle/migration/role selection passed **77 tests, 0 failures,
  18 excluded**, seed `955578`. Known historical migration-module redefinition
  warnings and the intentional setup-failure log matched the baseline.
- Spec review passed. Independent quality review identified missing required
  non-function membership validation. Five independent real PostgreSQL
  regressions reproduced accepted detached operator/type/opclass/opfamily state
  and a substituted `%` implementation: **RED, 21 tests, 5 failures,
  15 excluded**, seed `373343`. Each fixture alteration succeeded; failures were
  missing rejection, not fixture errors. Direct membership and required operator
  binding checks closed the gap; independent quality re-review passed. The
  automatic array dependency remains supported without ownership changes.
- Final candidate unit selection: **42 tests, 0 failures, 15 integration
  excluded**, seed `895552`. Final actual PostgreSQL selection: **82 tests,
  0 failures, 18 excluded**, seed `818098`. Fresh/historical provisioning,
  compatible pre/post-web-grant reruns, exact ACLs/role invariants, incompatible
  catalog rejection, and allocation cleanup/outer restoration all passed.
  Both SPEC and QUALITY review passed; no unresolved in-scope findings remain.
- `mix do compile --warnings-as-errors, xref graph --format cycles --fail-above 0`
  passed with **zero cycles**; the seven-application graph remains unchanged.
  Changed Elixir files passed `mix format --check-formatted`; the wrapper passed
  `bash -n`, and `git diff --check` passed. The new wrapper has executable mode
  matching the existing role-bootstrap wrapper, which remains unchanged.
- Commands ran from the Phase 3 worktree with `devenv shell --`, `MIX_ENV=test`,
  and shared `MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps`.
  Unit selection used `mix test <listed files>`. Integration selection used
  `mix singularity.test.integration <listed files>` through the worktree-local
  `.devenv/phase3-integration.sh` owned-cluster harness. The harness verifies its
  PostgreSQL data directory and Unix-socket-only listener, supplies the existing
  administrator URL, and stops only that owned instance on exit. Baseline, RED,
  and GREEN integration runs cleaned their allocated fixtures and stopped it.
  Final absence of its postmaster PID file and Unix socket was verified
  separately.
- E2E, the complete phase gate, publication, deployment, and Vault changes
  remain **NOT RUN / not performed**. The projection schema contract remains
  deliberately RED for Task 3b; Task 3a is not phase acceptance.

Final focused commands (executed serially from this worktree):

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/search_extension_bootstrap_test.exs apps/singularity_storage/test/singularity/storage/configuration_test.exs apps/singularity_storage/test/singularity/storage/test_environment_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/search_extension_bootstrap_test.exs apps/singularity_storage/test/singularity/storage/test_environment_test.exs apps/singularity_storage/test/singularity/storage/migrations_test.exs apps/singularity_storage/test/singularity/storage/roles_test.exs
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted apps/singularity_storage/lib/singularity/storage/search_extension_bootstrap.ex apps/singularity_storage/lib/singularity/storage/test_environment.ex apps/singularity_storage/test/support/migration_test_environment.ex apps/singularity_storage/test/singularity/storage/search_extension_bootstrap_test.exs
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do compile --warnings-as-errors, xref graph --format cycles --fail-above 0
bash -n apps/singularity_storage/priv/repo/bootstrap_search_extensions.sh
git diff --check
```

### Task 3b: Forward projection migration and actual-role boundaries

Task 3a is committed locally at
`aecff46a4c350cbe6adfa3b25118e85021cf10f9`. The preserved fresh-database
projection contract was rerun immediately afterward through the owned-cluster
integration harness: **RED, 1 test, 1 failure**, seed `711089`. The extension
namespace assertion now passes; the expected remaining failure is the absent
`content.search_entries` table. The allocated fixture and owned PostgreSQL
instance were cleaned up. Task 3b's migration has subsequently been exercised
only in isolated test databases; final scoped acceptance is recorded below.

The expanded test-first schema contract was then exercised before creating
the migration. The isolated table-owner GIN authority characterization passed
with exactly two executable extension functions: 19 tests, zero failures,
18 excluded, seed `709643`. The complete new module reported **RED, 19 tests,
18 failures**, seed `389426`: the authority characterization passed and the
remaining contracts failed because the projection or migration was absent.
Canonical Note/Document fixture construction succeeded. Both runs removed their
allocated fixtures and stopped the owned PostgreSQL instance. Implementation
was authorized only after this observed baseline.

The first candidate run reported **27 tests, 16 failures**, seed `452047`.
The failures identified three test-fixture/API defects: the explicit migration
list lacked a Migrator strategy (13 cases), revision-one Note fixtures lacked
their canonical parent (two cases), and the catalog query compared PostgreSQL's
internal `char` value without the established `::text` cast (one case).
The 11 other contracts passed, including constrained GIN execution and actual
tag-read isolation. These fixture corrections preserve every required
assertion and do not change production behavior. The next run reported 27 tests,
12 failures, seed `660315`: all positive schema/authority/boundary/upgrade cases
passed, while the 12 rejected-bootstrap cases reached their final rollback
assertion and exposed a fixture querying migration metadata through the web
Repo. That assertion must use the existing task-only migration login; no
additional runtime grant is justified.

Independent spec review also requires the immutable migration preflight to
reject the same incompatible extension inventory that provisioning rejects.
The initial candidate omitted checks for detached nonfunction members,
renamed support functions, and extension members outside the controlled schema.
Focused reproductions are being added before changing those guards.

The next expanded run reported **31 tests, 17 failures**, seed `408111`.
Four new catalog cases demonstrated that the candidate incorrectly accepted a
detached `gtrgm` type, detached GIN operator family, renamed support function,
and outside-namespace extension member. A fifth regression showed JSONB
equality alone accepted a Note locator with version `1.0` instead of the
canonical integer `1`. These five observed failures authorize corrections to
the already-approved compatibility and locator checks, not new privileges.
The other 12 failures were the rollback fixture's combined absence query:
moving it to the migration login fixed metadata access but that NOINHERIT
login cannot resolve the content-schema relation. After two unsuccessful Sol
fixture repair rounds, the bounded assertion-routing repair was escalated to
Astra (`SOL_REPEATED_FAILURE`, initial repair counter zero). Production guard
correction remains separately Sol-owned; parent verification remains serial.

After those corrections, the full schema module reported **GREEN, 31 tests,
zero failures**, seed `336659`, in 179.5 seconds. This includes all 16
incompatible-bootstrap rollback cases, the strict Note-locator regression,
constrained-role GIN execution, exact canonical content bounds, actual read
isolation, and historical upgrade preservation. Astra's first bounded repair
passed parent verification (one completed round, zero failed Astra rounds).
The three bootstrap/configuration/test-environment unit files also passed:
42 tests, zero failures, 15 integration cases excluded (27 executed), seed
`121375`. Independent final spec and code-quality reviews both passed.
The adjacent bootstrap/test-environment/migration/role/Document-schema/Note-RLS
run also passed: **106 tests, zero failures, 18 excluded** (88 executed), seed
`953087`, in 181.5 seconds. This run emitted migration-module redefinition
warnings and fixture-related database error logs; no unrelated repair was made.
Scoped formatting, compilation with warnings as errors, and xref's zero-cycle
check passed. Owned test instances were stopped after each completed run.

The initial compatibility concern was that the existing
`knowledge_rls_test.exs` rollback test still expects web tag SELECT denial.
That historical expectation conflicts with the explicitly approved read-only
tag grant. Its worker-read denial, mutation denials, rollback, and context
cleanup must remain enforced. The file was outside Task 3b's original two-file
edit scope, so it was left unchanged pending the explicit amendment below.

Read-only characterization confirmed this conflict: the existing rollback
test selected at line 78 reported **2 tests, 1 failure, 1 excluded**, seed
`197091`. At `knowledge_rls_test.exs:117` it expected `[SELECT=false,
INSERT=false]` but the actual web role correctly had `[true,false]`. The
allocated fixture was removed and the owned PostgreSQL instance stopped.
Work stopped under the repository's outside-scope failure rule. The migration,
new test, and this evidence record remained uncommitted at that boundary; no
assertion was weakened or reclassified to obtain a green result.

Amendment approved 2026-10-10: permit editing only that existing rollback test
to require the approved web SELECT grant while preserving rollback/context
cleanup, worker SELECT denial, all mutation denials, and exact restoration of
the production permission baseline. No production code, grant, helper, or Vault
change is authorized for this alignment. Task 3b verification and its local
commit may resume; later work stays within the approved Phase 3 plan.

Before editing the test, the same focused command reproduced **RED, 2 tests,
1 failure, 1 excluded**, seed `9099`, with the same expected `[false,false]`
versus actual `[true,false]` permission mismatch. Its fixture was removed and
the owned PostgreSQL instance stopped.

The approved test-only alignment now asserts the exact web/worker permission
baseline both before and after temporary grants, retaining same-connection
rollback/context cleanup. It verifies a scoped web read, actual worker SELECT
denial, and actual INSERT/UPDATE/DELETE/TRUNCATE denials for both roles. The
first test and shared helper are unchanged. The complete two-test module
passed, seed `987326`; the owned PostgreSQL instance stopped afterward. The
three focused unit files also passed again: 42 tests, zero failures, 15 excluded
(27 executed), seed `678122`. Independent amendment spec and code-quality
reviews both passed. The combined schema/knowledge-RLS/adjacent PostgreSQL run
then passed: **139 tests, zero failures, 18 excluded** (121 executed), seed
`85445`, in 344.6 seconds. The owned PostgreSQL instance stopped after cleanup.
The historical-fixture run retained the previously noted migration redefinition
warnings and negative-fixture/connection-cleanup database logs; no assertion
failed and no unrelated repair was made.

Task 3b's constrained extension evidence is PostgreSQL 17.10 with `pg_trgm`
1.6 in `search_extensions`, table-owner-controlled schema/extension and
administrator-owned functions. Only the two approved function signatures are
delegated; actual-role GIN creation, mutation, and query plans passed. The
migration and new schema-test SHA-256 values remain those independently
reviewed: `b07003c4b3c2150ba75f1f3bbf2298c6e54e0f346aee0019770cc6a1166b1aad`
and `2068e3bca042cfd1b337ed0c9437e968e4f4c5d4c85f3bd9942261b28848871f`.
The reviewed amended RLS test hash is
`aae1d6dca515e4000caf4fe6f5364d6400e977c1c94cb0085d74e0541264bfb6`.
Final scoped formatting, compilation with warnings as errors, zero-cycle xref,
and `git diff --check` passed again. Task 3b is accepted locally for the bounded
schema slice; it is not whole-phase acceptance or publication authority.

Final scoped commands (serial, from this worktree):

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/search_extension_bootstrap_test.exs apps/singularity_storage/test/singularity/storage/configuration_test.exs apps/singularity_storage/test/singularity/storage/test_environment_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/search_projection_schema_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/search_extension_bootstrap_test.exs apps/singularity_storage/test/singularity/storage/test_environment_test.exs apps/singularity_storage/test/singularity/storage/migrations_test.exs apps/singularity_storage/test/singularity/storage/roles_test.exs apps/singularity_storage/test/singularity/storage/document_schema_test.exs apps/singularity_storage/test/singularity/storage/note_rls_test.exs
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted apps/singularity_storage/priv/repo/migrations/20261009000100_create_unified_search_projection.exs apps/singularity_storage/test/singularity/storage/search_projection_schema_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do compile --warnings-as-errors, xref graph --format cycles --fail-above 0
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs:78
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/search_projection_schema_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/search_extension_bootstrap_test.exs apps/singularity_storage/test/singularity/storage/test_environment_test.exs apps/singularity_storage/test/singularity/storage/migrations_test.exs apps/singularity_storage/test/singularity/storage/roles_test.exs apps/singularity_storage/test/singularity/storage/document_schema_test.exs apps/singularity_storage/test/singularity/storage/note_rls_test.exs
git diff --check
```

The line-selected pre-amendment command is the documented historical **FAIL**;
the complete amended module is **PASS**. The combined run is recorded above.
No released migration, canonical row, shared fixture helper, runtime role
definition, or Vault file was edited. The seven-application graph has no cycles.
E2E, the complete phase acceptance gate, merge, push, release, deployment, and
production activation remain **NOT RUN / not performed**.

- [x] Add an integration module using `Singularity.Storage.DataCase`,
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

- [x] Under `SET LOCAL ROLE singularity_table_owner`, preflight the separately
  provisioned extension's namespace, owner, version and ACLs. Fail if missing
  or incompatible; never install/relocate/harden it through runtime authority.
  Grant web only schema USAGE and EXECUTE on the two approved signatures.
  No role attributes/memberships or other function grants change.
- [x] Create `content.search_entries`: text primary key `entry_id`, UUID
  `resource_id/resource_version_id/vault_id`, private `classification`, text
  `kind`, nullable UUID `note_resource_version_id`, nullable text `fragment_id`,
  bigint `ordinal`, title/body text, locator jsonb, immutable source timestamp,
  and projection format integer constrained to 1. Use canonical source bounds.
  Add generated title-A/body-D simple FTS vector and its GIN index, trigram
  title/body GIN indexes, and owner/kind/source-time/identity indexes.
- [x] Use existing unique keys; do not alter canonical data or add a universal
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
- [x] ENABLE/FORCE RLS; preserve the established table-owner internal policy.
  The web policy requires nonempty scoped principal/owner, matching row owner,
  and `core.principal_is_authorized(principal, owner)`. Grant only web SELECT on
  the new projection and existing `tags/resource_tags`. Runtime projection DML,
  worker Document SELECT, and all tag mutation grants remain denied.
- [x] Add actual-role cross-owner/missing-context and ACL tests, FK mismatch
  tests, old-table grant preservation, and forward-upgrade tests through
  `MigrationTestEnvironment.with_database(20261008000000, callback)`.
  No temporary `KnowledgeTestGrants` permissions are acceptance evidence.

```sh
devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/search_projection_schema_test.exs
```

- [x] Record extension package/version/schema and least-privilege installation
  results. Review and commit `feat(storage): add constrained unified search projection`.

Task 3 historical status, 2026-10-09: **installation-authority amendment pending approval**.
The new focused schema contract was run against a fresh application database:
1 test, 1 expected failure because `pg_trgm` is absent (seed 426598), before
adding a migration. Its isolated database/storage cleanup and owned PostgreSQL
shutdown completed. No production migration or grant change was implemented.

A separate owned PostgreSQL 17.10 probe installed `pg_trgm` 1.6 under
`singularity_table_owner`. The extension belonged to that role, but functions
belonged to bootstrap administrator `gao`. Attempted PUBLIC function revocation
and web EXECUTE grants only warned that no privileges could be changed;
PUBLIC EXECUTE remained, while the worker correctly lacked schema USAGE.
The probe rolled back its extension transaction and stopped its private
socket-only server. This agrees with PostgreSQL's documented
[trusted-extension ownership](https://www.postgresql.org/docs/17/sql-createextension.html).
Warning-only SQL completion is not accepted privilege evidence.

Astra architecture assessment recommends a narrow amendment: per-application
administrator provisioning for initial installation/hardening, exact required
function EXECUTE delegation with grant option to the table owner, then a
fail-closed forward migration for final web grants and projection creation.
No role attributes/memberships, runtime administrator credentials, extension
function ownership transfer, or Vault behavior would change. Bootstrap files,
fresh/historical test-database lifecycle hooks, operator documentation, and
explicit installation exception need approval before those edits. Approval
was requested; the original installation step above is not silently relaxed.
The independent pure cursor slice of Task 7 can proceed without this change.

Amendment approved 2026-10-10: the decision above is resolved by Task 3a and
the amended installation section of the approved spec. Database work resumes
under that explicit boundary. The pre-change test-environment unit baseline
reported 12 tests, zero failures, 1 integration case excluded (seed 10736).

## Task 4: Canonical builder and dual Note reconciliation

Task 3b is committed locally at
`5ad2c8193090dd9cefee4d6a2529e0911253e2ce`. Task 4 begins with an unchanged
legacy Note baseline and a new failing canonical-builder contract. The
private builder and guarded adapters are verified before composing the dual
Note path. Existing direct-repository fixtures lack explicit `note.write`
capabilities; production authorization will not be bypassed to accommodate
those fixtures, and shared helpers remain outside the edit scope.

The unchanged Note reconciler/repository/search-store baseline passed on that
commit: **27 tests, zero failures**, seed `411261`, in 12.7 seconds. Its isolated
database was cleaned up and the owned PostgreSQL instance stopped.
The initial canonical-builder module then reported **RED, 2 tests, 2 failures**,
seed `73038`: both canonical fixtures loaded successfully, and both failures
were the missing `content.reconcile_search_resource_internal` function. Only
the private builder was authorized for the first GREEN implementation step;
public entrypoints, adapter, and dual Note integration remain later steps.
The minimal private-builder migration then passed the same two tests, seed
`573164`, in 0.9 seconds, with owned PostgreSQL shutdown afterward. It remains
uncommitted. Expanded eligibility, reconstruction, rollback, actual-role ACL,
and public-entrypoint contracts are being added before their implementation;
the initial two-test result is not Task 4 acceptance.
The expanded contract reported **23 tests, 14 expected failures**, seed
`200307`, in 5.2 seconds. All nine private-builder/ACL cases passed, including
multi-fragment reconstruction, current-head selection, tombstone/non-ready
cleanup, cross-owner isolation, and canonical/projection rollback. Remaining
failures were absent guarded SQL functions or adapter. The next implementation
step adds only those public entrypoints and the scoped adapter. The concurrency
fixture's catalog-only Resource-lock probe uses the web Repo, which already has
schema USAGE, rather than granting the NOINHERIT migration login new access.

The guarded SQL entrypoints and scoped adapter then passed the full four-module
Task 4 command: **50 tests, zero failures**, seed `209941`, in 11.5 seconds.
This includes the 23 new contracts and all 27 unchanged legacy Note contracts;
the isolated database was cleaned up and the owned PostgreSQL stopped. Dual
Note integration remains unimplemented pending its next RED contracts.
Those contracts extend the explicitly listed Note repository/reconciler tests
with local `note.write` assignments for valid mutation fixtures and dual
projection assertions. All existing assertions are preserved; no shared helper,
runtime role grant, or production authorization exception is introduced.
The first dual-Note RED run reported **56 tests, 14 failures**, seed `965045`,
in 22.5 seconds: seven expected absent-unified/owning-rollback failures and
seven fixture failures because the isolated database initially had no
`note.write` capability definition. Each amended test module now seeds that
existing capability definition locally before asserting its assignment,
without depending on module order or changing shared helpers. Production Note
code remains unchanged until a clean behavioral RED is observed.
The second run reported **56 tests, 47 failures**, seed `810795`, in 18.3
seconds. Four initial failures exercised the intended missing behavior; the
lock-mode failure then exposed test-owned cleanup that killed a blocker before
its linked MigrationRepo could stop, causing 43 downstream `already_started`
fixture failures. The local barrier fixtures are being moved under test-owned
Repo supervision with bounded task cleanup. Lock assertions and production
semantics are unchanged by this fixture repair; no Task 4 acceptance is claimed.
The corrected behavioral RED then reported **56 tests, 14 expected failures**,
seed `718960`, in 19.2 seconds, with no fixture failures. Seven reconciler
contracts expose missing scope/transaction checks, UPDATE lock order, dual
repair/tombstone behavior, and projection-failure rollback. Seven owning
mutation contracts expose absent unified projections or an uncalled faulting
projection. The other 42 tests passed. The owned database was cleaned up and
PostgreSQL stopped before authorizing the minimal Note reconciler composition.
The first composed run reported **56 tests, 5 failures**, seed `691777`, in
18.0 seconds. All new reconciler and owning mutation contracts passed; the
five failures were the explicitly listed legacy search suite's Note-creation
setup lacking `note.write`. Its local setup receives the same existing
capability definition/assignment as the other two test modules. Every search
ranking, summary, cursor, and input-validation assertion remains unchanged.

The full four-module Task 4 command then passed: **56 tests, zero failures**,
seed `260253`, in 27.0 seconds. Both projection changes and owning Note effects
now roll back under a real projection constraint failure; competing repair
transactions hold Resource UPDATE locks before either projection write. The
existing legacy-only rebuild contract passes without added live authority.
The isolated database was cleaned up and the owned PostgreSQL stopped.
Scoped formatting across all seven Elixir files, compilation with
`--warnings-as-errors`, `xref graph --format cycles --fail-above 0`, and
`git diff --check` also passed (zero cycles). The legacy search suite also
passed alone on a fresh database: **6 tests, zero failures**, seed `182798`,
in 3.0 seconds, proving its setup no longer depends on another module seeding
the existing capability. Independent spec review and a separate code-quality
review both passed with no actionable findings. No released migration, shared
fixture helper, production Note repository, or Vault file changed. This focused
result is not complete Phase 3 or production acceptance. E2E, merge, push,
release, deployment, and production activation were not performed.

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/note_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/search_projection_reconciler_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/search_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted apps/singularity_storage/priv/repo/migrations/20261009000200_unified_search_reconciliation.exs apps/singularity_storage/lib/singularity/storage/postgres/search_projection_reconciler.ex apps/singularity_storage/lib/singularity/storage/postgres/note_projection_reconciler.ex apps/singularity_storage/test/singularity/storage/postgres/search_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do compile --warnings-as-errors, xref graph --format cycles --fail-above 0
git diff --check
```

**Files:** Create the `20261009000200` migration,
`apps/singularity_storage/lib/singularity/storage/postgres/search_projection_reconciler.ex`,
and `apps/singularity_storage/test/singularity/storage/postgres/search_projection_reconciler_test.exs`.
Modify `apps/singularity_storage/lib/singularity/storage/postgres/note_projection_reconciler.ex`
and its existing test. Extend the explicitly listed
`apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs`
with mutation-local fixture authority and dual-projection regressions. Align
only the setup of the explicitly listed
`apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs`
with the same existing write authority while preserving all assertions; modify
`note_repository.ex` only if its established
reconciliation calls cannot preserve the owning transaction/lock order.

- [x] With `KnowledgeFixtures.source!/0`, `note!/1`, and `ready_document!/1`,
  assert a canonical builder creates exactly one Note and every canonical
  Document fragment with source timestamps, locators, and deterministic IDs.
  Observe RED before creating the definer/adapter.
- [x] Add an ungranted private SQL helper
  `content.reconcile_search_resource_internal(owner uuid, resource uuid)`.
  Lock Resource `FOR UPDATE`, then Document version when relevant. Delete this
  resource's old derived rows, then INSERT SELECT only eligible canonical data
  in the same transaction. Notes read current typed Markdown; Documents read
  current ready fragments. Tombstones/non-ready sources leave zero entries.
  Never accept content, locator, or an arbitrary SQL fragment from callers.
- [x] Add distinct public definer entrypoints for scoped read maintenance and
  existing Note-write reconciliation. They derive owner/principal from scoped
  GUCs and revalidate the appropriate existing capability before invoking the
  private helper. Preserve fixed search path, explicit owner, and EXECUTE ACLs.
  Return count/status only. Do not make `note.write` require `note.read`.
- [x] In `NoteProjectionReconciler.reconcile/2`, acquire the resource
  `FOR UPDATE` before either projection and keep the old projection's
  delete-before-head-change rule in owning mutations. Both projection changes
  and the mutation receipt/outbox effect must commit or roll back together.
  Existing Note repair jobs therefore repair both through the same reconciler.
- [x] Keep `rebuild_vault/2` as the existing legacy-only reconstruction used
  by restore. Extract a private legacy reconciliation helper: the normal
  `reconcile/2` composes it with the guarded unified Note-write path, whereas
  `rebuild_vault/2` calls only the legacy helper under its established caller
  authority. Task 10 separately invokes the ungranted unified SQL builder from
  the already-authorized owner transaction. Do not branch on ambient DB role,
  add a public bypass flag, or require a live session for legacy restore.
- [x] Add create/save/conflict-only/merge/tombstone/restore and failure-rollback
  regressions. Preserve every existing Note search summary/cursor assertion.
  Force competing reconcilers through deterministic barriers to test lock order.

```sh
devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/search_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs
```

- [x] Review and commit `feat(storage): reconcile canonical unified search entries`.

## Task 5: Transactional Document lifecycle events

Task 4 is committed locally at
`cb60599670db25bb852cdff454c5400f8f7e139b`. Before any Task 5 source changes,
the unchanged Document repository and worker-repository suites passed:
**91 tests, zero failures**, seed `145960`, in 73.8 seconds. The isolated
database was cleaned up and the owned PostgreSQL instance stopped. New
lifecycle-event contracts were written before the forward migration;
existing extraction, custody, and released migration files remained unchanged.
The new event module then reported **RED, 13 tests, 9 expected failures**,
seed `665218`, in 10.8 seconds. The absent events, uncalled faulting event
inserts, stale rows after deletion, and Document-before-Resource row lock
were all observed against the unchanged producers. Four existing
retry/recovery/authority/isolation contracts passed. The owned database was
cleaned up and PostgreSQL stopped before authorizing the new forward migration.
The Runtime lifecycle already holds its compatibility and shared authorization
locks through `OperationScope.with_shared_request/4`; the worker bridge also
holds the established authorization lock. The migration changes the target's
row locks to explicit Resource then Document order, preserving those callers
and their existing authority/isolation rules rather than inventing a new
web-isolation or custody policy.

The forward migration's first GREEN run passed **13 tests, zero failures**,
seed `649804`, in 9.5 seconds. The combined lifecycle, existing Document
repository/worker, and all four Task 4 reconciliation/search suites then passed
**160 tests, zero failures**, seed `447737`, in 62.9 seconds. Both commands
exited zero, cleaned their isolated databases, and stopped the owned PostgreSQL
instance. Retention assertions cover canonical source pins and unchanged
stored-object metadata, not live decryption or new custody qualification.
Scoped formatting, warnings-as-errors compilation, and `git diff --check`
passed; xref reported zero cycles. Specification review passed, followed by
quality review with no actionable findings. No existing extraction tests or
released migrations were edited, and no Vault feature/custody change, E2E,
full phase gate, merge, push, release, deployment, or activation occurred.
Three attempts to dispatch a fresh quality-review agent failed with the
runner's `agent thread limit reached` error. A separate quality stage was
therefore assigned to the existing reviewer, who did not author the code;
this is not evidence of two different reviewers or a substitute for the
later full-phase review.

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/document_projection_events_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/document_projection_events_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/search_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted apps/singularity_storage/priv/repo/migrations/20261009000300_document_projection_events.exs apps/singularity_storage/test/singularity/storage/postgres/document_projection_events_test.exs
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix compile --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix xref graph --format cycles
```

**Files:** Create the `20261009000300` migration and
`apps/singularity_storage/test/singularity/storage/postgres/document_projection_events_test.exs`.
Read, but never modify, the existing extraction-attempt, terminal-tombstone,
runtime-mutations, and worker-bridge migrations.

- [x] Add failing integration tests around actual `complete`, `delete`, and
  `restore` paths. Assert exactly one identifier-only event on each real
  transition, none for terminal/no-op replay, and distinct keys across two
  complete delete→restore cycles on the same immutable version/generation.
- [x] Forward-replace the current definitions of
  `content.complete_document_extraction`, `content.delete_document_runtime`,
  and `content.restore_document_runtime`, preserving all existing checks and
  signatures. Add event insertion only after the successful real state change,
  in the same transaction. Keep the exact-ready replay early return event-free.
  Deletion also deletes the resource's unified rows synchronously.
- [x] Event types are `document.ready`, `document.deleted`,
  `document.restored`; payload is exactly the two IDs:

```elixir
%{"resource_id" => resource_id, "resource_version_id" => resource_version_id}
```

  Generate one event UUID within the locked transition and set the key to
  `document-projection:<event UUID>`. Persist the actual authenticated actor,
  checked authorization epochs, `asset.read`, private classification, and the
  current immutable revision snapshot using the existing outbox shape. Never
  substitute creator identity for the actual actor or use generation as the key.
- [x] Express Resource-before-Document row locking explicitly in the forward
  definition of `document_runtime_target`; preserve existing outer locks and
  every creator/capability/isolation check. A completion after tombstone still
  persists valid canonical extraction, but its projection remains hidden.
- [x] Assert event-insertion failure rolls back the canonical transition,
  source pin/bytes remain retained, and old extraction retry/recovery events
  keep their unchanged contract. No extractor or custody changes are allowed.

```sh
devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_projection_events_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
```

- [x] Review and commit `feat(storage): emit durable document projection events`.

## Task 6: Narrow Document projection worker and dispatch

Task 5 is committed locally at
`5e5917212d4ead14d4de35f5bdc7c440bb2cf75e`. Task 6 baseline characterization
passed before edits: the existing codec/Oban unit suite had **16 tests, zero
failures**, and the existing Note projection dispatcher had **3 tests, zero
failures**, seed `328616`; the existing Outbox dispatcher integration suite
had **13 tests, zero failures**, seed `587992`, in 5.9 seconds. The integration
database was cleaned and the owned PostgreSQL instance stopped. A fresh Sol
worker is writing focused contracts before production changes.

Initial unit RED: **17 Storage tests, one expected failure**, and **8 Runtime
tests, three expected failures**, seed `756377`. The codec rejects the new
valid job and the dispatcher lacks its handler; existing tests remain green.
Malformed-envelope negative contracts already fail closed. No production file
had changed during this RED run.
The initial Outbox integration RED then reported **15 tests, one expected
failure**, seed `754681`, in 5.3 seconds: the three new lifecycle events were
not mapped to jobs. All existing 13 Outbox contracts passed, as did rejection
of malformed new event payloads. The owned database was cleaned and PostgreSQL
stopped. A subsequent contract uses the actual Oban reservation and queue;
the earlier fake-runner replay check alone is not durable-reservation evidence.
After adding the real reservation, historical-event/current-head, scoped
adapter identity, shared authorization lock, and bigint-bound contracts,
the repeated unit RED remained **17/1 Storage and 8/3 Runtime**, seed `414453`.
The combined integration RED reported **20 new worker tests, 20 expected
failures**, plus **16 Outbox tests, two expected failures**, seed `372771`,
5.5 seconds per application. Missing worker SQL/adapter/ACL and event mappings
caused the failures, not fixture setup. No production files had changed;
the owned database was cleaned and PostgreSQL stopped.

The final pre-implementation non-owner-principal contract was included in a
focused authority RED: **21 tests, seven expected failures, 14 excluded**
(seven executed), seed `610444`, in 2.4 seconds. All seven reached the absent
worker SQL function; no fixture failed. Only after this run completed and
owned PostgreSQL stopped was Task 6 production implementation authorized.

First GREEN: **17 Storage unit tests and 19 Runtime unit tests, zero
failures**, seed `162980`, including the unchanged Note dispatcher and Runtime
application composition. The first integration GREEN passed **21 worker
tests and 16 Outbox tests, zero failures**, seed `721670`, in 7.5 and 5.5
seconds respectively. The latter includes real Oban reservation identity,
queue selection and replay. Both commands exited zero; the integration
database was cleaned and owned PostgreSQL stopped. No failed production
repair round or Astra escalation was needed.

The combined Task 4/5/6 and unchanged Document extraction regression passed
**181 Storage tests plus 16 Runtime Outbox tests, zero failures**, seed
`784820`, in 69.6 and 10.0 seconds respectively (197 total). It exited zero,
cleaned the isolated database and stopped owned PostgreSQL. Independent
specification review passed, followed by a separate independent quality
review with no actionable findings. No E2E or full
phase acceptance gate has run, and no publication or Vault feature work
occurred.
Scoped formatting of all 13 changed Elixir/config/test files, compilation
with warnings as errors, and `git diff --check` passed. Xref reported zero
cycles; the seven-application graph remains unchanged.

The existing durable-job authority snapshot has no expiry timestamp or session
binding. This task tests its actual invalidation rules (revoked principal,
membership or capability, disabled account, and stale checked epochs), without
adding a new session/expiry policy. Session expiry belongs to the authenticated
API checks in Task 8. The worker calls the existing ungranted
`reconcile_search_resource_internal(owner, resource)` only with owner derived
from validated scoped context; no public owner argument is added.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_note_projection_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_document_projection_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_note_projection_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/document_projection_worker_test.exs apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/document_projection_worker_test.exs:254
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_document_projection_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_note_projection_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/document_projection_worker_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_projection_events_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/search_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_projection_reconciler_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted apps/singularity_storage/priv/repo/migrations/20261009000400_document_projection_worker.exs apps/singularity_runtime/lib/singularity/runtime/documents/projection.ex apps/singularity_storage/lib/singularity/storage/jobs/envelope_codec.ex apps/singularity_storage/lib/singularity/storage/jobs/oban_adapter.ex apps/singularity_storage/lib/singularity/storage/postgres/search_projection_reconciler.ex apps/singularity_runtime/lib/singularity/runtime/outbox_dispatcher.ex apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex apps/singularity_runtime/lib/singularity/runtime/application.ex config/config.exs apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs apps/singularity_runtime/test/singularity/runtime/job_dispatcher_document_projection_test.exs apps/singularity_storage/test/singularity/storage/postgres/document_projection_worker_test.exs
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix compile --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix xref graph --format cycles
```

**Files:** Create the `20261009000400` migration,
`apps/singularity_runtime/lib/singularity/runtime/documents/projection.ex`,
`apps/singularity_storage/test/singularity/storage/postgres/document_projection_worker_test.exs`,
and `apps/singularity_runtime/test/singularity/runtime/job_dispatcher_document_projection_test.exs`.
Modify Storage `jobs/envelope_codec.ex`, `jobs/oban_adapter.ex`, the new
reconciler adapter, Runtime `outbox_dispatcher.ex`, `job_dispatcher.ex`,
`application.ex`, and existing owning codec/outbox tests; add only the required
queue entry in `config/config.exs` if the established queue mapping needs one.

- [x] RED: reject an otherwise valid `document_projection` envelope before
  adding it to the closed codec/dispatcher mappings; test malformed keys,
  content-bearing payloads, wrong capability/classification, and key/job mismatch.
- [x] Add a worker-only definer with the accepted bridge prefix:

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
- [x] Add `document_projection` JSON codec validation with `asset.read`,
  private classification, exact two-ID payload, and event-UUID idempotency key.
  Map the three events to that job; keep durable reservations keyed by existing
  outbox identity. Runtime handler validates the closed envelope before DB work
  and routes sanitized errors through existing retry/terminal behavior.
- [x] Test duplicate/out-of-order events; ready-after-delete and
  delete-after-restore must reconcile current state. Cover revoked/expired
  authority, wrong creator/owner, substituted IDs/epochs, absent/retired events,
  no source content in job metadata, and preserved extraction envelopes.

```sh
devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/job_dispatcher_document_projection_test.exs apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs
devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_projection_worker_test.exs
```

- [x] Review and commit `feat(runtime): dispatch authorized document projection jobs`.

## Task 7: PostgreSQL search, literal fallback, and signed keysets

Task 6 is committed locally at
`547f73cab46f21d9545d6d53ded382880449373c`. Before the SQL search slice,
the existing independently reviewed cursor suite passed **11 tests, zero
failures**, seed `396126`, in 0.4 seconds. The cursor source remains unchanged;
a fresh worker added the PostgreSQL search contracts first. The new
adapter uses the established repository/query seam and existing audit
fingerprint secret. Exact source resolution and its Runtime API remain
Task 8 work, not an unimplemented public fallback in Task 7.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_cursor_test.exs
```

**Files:** Create `apps/singularity_storage/lib/singularity/storage/postgres/knowledge_search_store.ex`,
`knowledge_search_cursor.ex`, and tests in the same test directory named
`knowledge_search_cursor_test.exs`, `knowledge_search_store_test.exs`, and
`knowledge_search_pagination_test.exs`.

- [x] RED: a real canonical Note plus ready Document search with empty q returns
  both kinds and exact version/fragment IDs. Use fresh production-role scoped
  queries, not direct fixture grants to the new table.
- [x] Validate the internal query map again before repository work. Use
  SafeSQL bound parameters, the same canonical visibility joins for every
  branch, AND tag membership through owner-bound canonical EXISTS, and a
  deduplicated candidate set. Never hydrate all bodies into Elixir to rank.
- [x] Apply transaction-local five-second statement timeout and fixed trigram
  threshold. The SQL policy is exactly:

```sql
plainto_tsquery('simple', $1)
```

  Combine weighted FTS match, escaped literal ILIKE on title/body, and title
  trigram similarity at 0.3 for at least three Unicode codepoints. Use
  schema-qualified `search_extensions` functions/operators/opclasses. Escape
  backslash, `%`, and `_` as literals; no caller syntax is SQL or tsquery code.
- [x] Compute integer score `4*F + 2*T + L` from the approved million-scale
  formula; return `left(body,160)` only as the snippet. Order by rank DESC,
  immutable source time DESC, resource UUID ASC, version UUID ASC, ordinal ASC,
  entry ID COLLATE `C` ASC. Apply the complete keyset predicate before LIMIT.
- [x] Cursor functions encode/decode the exact ordering tuple with distinct
  HMAC domains `knowledge-search-filter:v1` and `knowledge-search-cursor:v1`.
  Canonically frame fields, bind owner/private/q/kind/sorted tags/policy version,
  use the existing secret of at least 32 bytes, and compare MACs in constant
  time. Reject unknown keys, malformed/oversized payloads, noninteger ranks,
  invalid identities/timestamps, wrong filters, and legacy cursor domains before
  SQL. No plaintext q/title/locator in the token; limit is not fingerprinted.
- [x] Cover FTS-only, title typo, CJK/short substrings, literal wildcards,
  punctuation/empty q, tag filters, foreign/deleted/nonready/historical/conflict
  rows, tied mixed-kind paging, body/snippet boundaries, and timeout sanitization.

```sh
devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs
```

- [x] Review and commit `feat(storage): search version-pinned knowledge with stable keysets`.

The first SQL contract reached the production request-role query after creating
and reconciling a canonical Note and ready Document. It failed only because
`KnowledgeSearchStore.search/2` does not yet exist: **one test, one expected
failure**, seed `730080`, 0.7 seconds. The owned integration database/storage
were cleaned and the isolated PostgreSQL cluster stopped. This is a missing
feature RED, not a fixture or privilege failure. No production search code
was written before this run.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs
```

The expanded pre-implementation run reported **18 tests, 18 failures**, seed
`956041`, in 6.0 seconds: 17 expected missing-adapter failures and one fixture
failure for an uninitialized connection-local `pg_trgm.similarity_threshold`.
The settings fixture was corrected to pin initialization and before/after
checks to one checked-out connection. A test-only edit overlapped that run, so
it is retained as diagnostic evidence, not an exact-source qualification run.
Production code remained absent; the owned database was cleaned and PostgreSQL
stopped.

After pinning that settings fixture and adding Unicode-codepoint eligibility
and descending rank/recency paging cases, the same command produced **20 tests,
20 expected missing-adapter failures**, seed `480917`, 6.3 seconds. Every
fixture reached the missing feature; independent score/fixture prechecks
passed. Both test-file SHA-256 values were unchanged before and after this
frozen-source run. The isolated database/storage were cleaned and PostgreSQL
stopped before production implementation was authorized.

The first implementation run of those 20 contracts passed **19**, with one
test-fixture failure, seed `643934`, 8.4 seconds. The separate lock observer
used the migration login without table-owner schema usage when resolving
`content.search_entries` as a `regclass`. This prevented observing the real
timeout; it did not demonstrate a search-query failure. The corrected test receives
the relation OID from its already-authorized blocker instead of changing any
grant. The isolated database/storage were cleaned and PostgreSQL stopped.

With the observer corrected, a real three-version open-conflict contract also
proved that the canonical head remains searchable and a deliberately stale
derived competing-version entry is omitted. Production search code did not
change after the first implementation run. The combined suite passed **27
tests, zero failures** (21 new, six legacy Note search), seed `465079`, in
15.1 seconds. This includes the real five-second database cancellation,
sanitized retryable error, successful subsequent query, fixed transaction-local
settings, all branch scores, literal/CJK/codepoint behavior, tag filtering,
canonical visibility, and mixed-direction/tied-fragment cursor pagination.
The owned database/storage were cleaned and isolated PostgreSQL stopped.

Pure cursor and Retrieval compatibility then passed **50 tests, zero failures**
(Storage 11, Retrieval 39), seed `296436`, in 0.5 and 0.7 seconds respectively.

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_cursor_test.exs apps/singularity_retrieval/test/singularity/retrieval/knowledge_search_test.exs apps/singularity_retrieval/test/singularity/retrieval/note_lexical_search_test.exs
```

Scoped formatting, warnings-as-errors compilation, `git diff --check`, and
the zero-cycle xref gate passed. Independent SPEC review passed first, then a
separate independent QUALITY reviewer passed without findings. Task 7 is
complete locally: three new Storage source/test files plus this evidence
record, with the earlier cursor implementation unchanged. There were zero
production repair rounds; two test-fixture corrections are preserved above.
No migration, grant, shared fixture, Runtime API, Vault, E2E, merge, push,
release, or deployment change occurred. Exact-source resolution/API work is
Task 8; query-plan/privacy/full-phase qualification remains Task 11. These
scoped results do not establish Phase 3 or release acceptance.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted apps/singularity_storage/lib/singularity/storage/postgres/knowledge_search_store.ex apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs + compile --warnings-as-errors + xref graph --format cycles --fail-above 0
git diff --check
```

Historical Task 7 independent pure cursor slice: **implemented and reviewed**, commit
`613a4b3`. Eleven unit tests first failed because the module did not exist
(seed 88782), then passed (827002). They cover the complete ordering tuple,
normalized owner/filter binding, independently calculated HMAC values,
limit-independent paging, old-domain rejection, malformed signed payloads,
tampering, size bounds, and lossless timestamp serialization. Spec review
passed before a separate quality review passed. No SQL or database dependency
was added; SQL keyset integration and the remaining Task 7 checks are pending.

Final combined pure-contract regression command:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_core/test/singularity/core/search_source_test.exs apps/singularity_core/test/singularity/core/search_policy_test.exs apps/singularity_core/test/singularity/core/source_locator_test.exs apps/singularity_core/test/singularity/core/knowledge_link_values_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_cursor_test.exs apps/singularity_retrieval/test/singularity/retrieval/knowledge_search_test.exs apps/singularity_retrieval/test/singularity/retrieval/note_lexical_search_test.exs
```

Result: Core 33 tests plus 2 properties; Storage 11 tests; Retrieval 39 tests
(26 new, 13 legacy); zero failures, seed 364944. Scoped
`mix format --check-formatted` and `git diff --check` passed;
`mix xref graph --format cycles` reported no cycles. No E2E, full phase gate,
merge, push, publication, deployment, or Vault change occurred. These results
do not establish PostgreSQL search, Runtime authorization, or Phase 3
acceptance. The separate Task 3 schema RED test remains uncommitted, pending
the installation-authority amendment above.

## Task 8: Authenticated API and exact source reads

Task 8 is locally complete after the separately approved architecture-contract
and guide alignments recorded below. Its scoped acceptance is not full Phase 3
or release acceptance; Tasks 9–11 and all later release phases remain pending.

Task 7 is committed locally at
`75df901dc70047c16aeabbcdd92d7b71ef514dc5`. A fresh worker is starting
Task 8 tests first. Before any Task 8 edits, the existing DTO/legacy Note-read
baseline passed **22 tests, zero failures**, seed `34731`, in 0.9 seconds.
The existing 13 DTO contracts remain required. Actual authorization coverage
must use the established `OperationScope` and live identity adapter; a scope
or custodian double alone is not proof of live authorization or unlock.

The exact-source adapter shape is closed to `owner_scope_id`, `classification`,
`kind`, `resource_id`, `resource_version_id`, `fragment_id`, `ordinal`, `title`,
`body`, `locator`, and `source_inserted_at`. The public `KnowledgeSource` DTO
removes owner/classification only, retaining ordinal and immutable source time.
Notes use their exact Markdown body, ordinal zero, and the whole-source
Markdown locator. Document fragments retain their canonical text/ordinal/locator.
No digest, storage coordinate, key, or custody descriptor belongs in this value.

The first new unit attempt stopped at a test-fixture compile error: its
`SessionContext` literal omitted enforced fields (seed `212053`). Reusing the
complete Session fixture corrected the setup before any production edit.
The stable unit RED then reported **26 tests, three expected missing
API/use-case failures, one integration exclusion**, seed `154394`, 0.9 seconds;
all 22 established tests passed. The real-role exact-source fixture then reached
the absent `KnowledgeSearchStore.resolve/2` after constructing canonical Note
and ready Document rows and deleting the projection: **17 reported tests, one
expected failure, 16 pure exclusions** (one integration test executed), seed
`401094`, 0.9 seconds. Its owned database/storage were cleaned and PostgreSQL
stopped.

The expanded unit RED reported **39 tests, ten expected missing API/use-case/DTO
failures, seven integration exclusions**, seed `10707`, in 1.3 seconds; all 22
established tests still passed. Expanded integration RED reported **30 tests,
seven expected missing API/resolve failures, 23 pure exclusions**, seed `85439`,
in 4.6 seconds. All seven real-role cases reached absent behavior after their
canonical/live identity/actual custodian fixture setup. These setup successes
are not yet proof that the new use cases authorize correctly. The owned
database/storage were cleaned and PostgreSQL stopped before implementation
was authorized. No production repair round has occurred.

The first implementation unit run passed **39 reported tests, zero failures,
seven integration exclusions** (32 executed), seed `290968`, in 1.3 seconds.
The first integration candidate reported **30 tests, two failures, 23 pure
exclusions** (five of seven executed cases passed), seed `11689`, 8.1 seconds.
One well-formed mismatched identity returned `invalid` instead of `not_found`;
one live authority-denial case returned `storage_unavailable` instead of its
expected authorization error. Historical resolution and the actual unlock
boundary passed. Both failures require scoped diagnosis against the existing
repository/read/audit seams before any repair; no authorization, audit, or
Vault substrate change is authorized. Owned database/storage cleanup and
PostgreSQL shutdown completed.

The diagnostic rerun preserved both failing assertions and compared the new
authority path with the established Document read and direct authorizer.
It reported **30 tests, two failures, 26 exclusions** (four executed), seed
`88184`, in 7.1 seconds. The first forged Note resource/version pair returned
the legacy repository's `invalid`. The other failure was specifically revoked
owner membership: direct authorization returned `forbidden`, while established
Document read and both new APIs all returned `storage_unavailable`. The existing
operation scope gives denial-audit failure precedence over the authorization
error. The isolated database/storage were cleaned and PostgreSQL stopped.
Only the additive exact-source identity normalization is authorized for repair;
the erroneous-expectation-versus-boundary question requires independent scope
review before any test expectation changes. No failed gate is accepted or
reclassified as passing, and no authorization/audit/Vault change is authorized.

The first bounded product repair normalizes the legacy Note reader's
nonretryable `invalid` to `not_found` only after the new adapter has validated
the closed typed selector and scoped owner. Its full owning integration rerun
reported **30 tests, one failure, 23 exclusions** (six of seven executed cases
passed), seed `792374`, in 8.1 seconds. Every forged identity now meets the
unchanged `not_found` assertions; the membership-revocation expectation remains
failing and untouched pending independent contract review. Owned database/
storage cleanup and PostgreSQL shutdown completed. No Astra escalation has
been triggered: the one product repair succeeded for its bounded defect.

**STOP — compatibility gate, 2026-10-10.** The owning Runtime and directly
related legacy/API/architecture command below exited 2, seed `273163`.
Runtime reported **106 tests, zero failures, 22 integration exclusions**
(84 executed), in 1.9 seconds. Web reported **42 tests, eight failures**, in
1.8 seconds. The failures are outside Task 8's approved edit allowlist:

- `knowledge_phase1_contract_test.exs:182`: application alias cannot be
  relocated outside its approved insertion context.
- `notes_scope_contract_test.exs:271`: active README and guide state the v0.2
  scope lock; it still expects the Phase 1 acceptance/Phase 2 active text.
- `knowledge_phase1_contract_test.exs:182`: supervisor child cannot be relocated
  outside its approved insertion context.
- `knowledge_phase1_contract_test.exs:168`: approved Phase 2 additions preserve
  every original legacy composition byte; the API no longer matches that
  contract's exact stripped baseline.
- `knowledge_phase1_contract_test.exs:182`: Oban queue cannot be relocated
  outside its approved insertion context.
- `knowledge_phase1_contract_test.exs:260`: every approved worker block rejects
  mutation, removal, duplication and relocation.
- `knowledge_phase1_contract_test.exs:122`: public Document browser routes
  remain absent and runtime registration is bounded; registration checks fail.
- `knowledge_phase1_contract_test.exs:55`: active guidance authorizes only the
  approved Phase 2 slice.

These contracts still encode Phase 2 guidance and exact approved composition
contexts. Their failures are not yet qualified as harmless or repaired by
changing expected hashes. Implementation is stopped under the repository's
out-of-scope-test rule. Both architecture files and every required assertion
remain untouched. Task 8 is uncommitted and unaccepted; its separate live
membership-revocation assertion still fails. The read-only contract review
below does not lift this stop; no Task 9 work,
authorization/audit change, architecture repair, full-phase acceptance, E2E,
merge, push, release, or deployment is authorized by this failed gate.
A narrowly approved architecture-contract amendment would need to enumerate
the already approved Phase 3 additions while retaining original legacy-byte,
closed-registration, relocation/mutation, browser-exclusion, and scope-lock
guarantees; simply replacing baseline hashes is not an acceptable repair.

Independent read-only review concluded that the membership test's new public
`forbidden` expectation is unsupported by the approved existing-error contract,
not a requirement to change authorization/audit behavior. A future test-only
correction must assert direct live authorization's exact `forbidden`, established
Document read's exact retryable `storage_unavailable`, corresponding stable errors
from both new APIs, and no new content callback invocation after denial with a
working positive control. Other denial expectations and all 13 existing DTO
contracts must stay unchanged. This correction is **not applied** because the
architecture failures independently require a stop. No successful denial-audit
persistence or full Task 8 spec/quality acceptance is claimed.

Final read-only preservation checks passed: `git diff --check`, no owned
PostgreSQL postmaster PID, clean root main at
`e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`, and unchanged Phase 2 worktree at
`ff703bd710074738b0391bb2f29d585dc6166d5c`. Its unrelated untracked runtime-outcomes
plan remains present with SHA-256
`350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.

### Approved architecture-contract amendment, 2026-10-10

The user explicitly approved resuming with changes to only
`apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs`
and `apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`
for already-approved Phase 3 additions. Existing Task 8 ownership is unchanged.
This approval does not authorize production changes to satisfy architecture
tests, new Vault behavior, E2E, publication, or later phases.

- [x] Reproduce the unchanged two-file gate: **27 tests, eight failures**, seed
  `56569`, 1.8 seconds, exit 2. No assertion was edited before this rerun.
- [x] Strip the 12 exact Phase 3 API/application/dispatcher/queue additions
  once in their approved insertion contexts before the existing Phase 2
  normalization. Preserve every original legacy-byte digest and negative guard.
- [x] Exercise mutation, removal, duplication, and relocation of every new
  approved block; retain existing browser exclusions and scope-lock checks.
- [x] Require active guidance to agree on Phase 3, retaining all activation,
  custody, Vault-freeze, and publication restrictions. Do not relabel active
  Phase 2 guidance as historical merely to pass.
- [x] Independently review the amendment and rerun the complete scoped
  compatibility command before accepting Task 8.

Read-only diagnosis found that `docs/guide.md` still declares Phase 2 active in
its governing links, roadmap, and current implementation gate, unlike README
and AGENTS. That file is outside this explicitly approved two-file amendment.
Its consistency failure must remain visible; a guide edit needs separate
scope approval. Exact composition guards and the already-reviewed in-scope
Task 8 denial regression can proceed independently without waiving it.

The unchanged owning Runtime integration rerun reported **30 tests, two
failures, 23 exclusions** (seven executed), seed `787911`, in 7.8 seconds,
exit 2. Besides the known membership expectation, running the malformed-port
test first exposed lazy module loading before `function_exported?/3`.
A fresh no-start VM reproduced `is_loaded == false` and exported-check false;
`Code.ensure_loaded/1` returned the actual module, after which the exported-check
was true. The test-only correction adds explicit successful loading before
the unchanged export and malformed-selector assertions. No source behavior
change is needed. Owned database/storage cleanup and PostgreSQL shutdown
completed before any test edit was authorized.

The test-only corrections passed the full owning live suite: **30 reported
tests, zero failures, 23 exclusions** (seven executed), seed `216576`, in
8.2 seconds, exit 0. The denial matrix now proves exact direct-authorizer and
established Document-read errors, exact public errors, successful real-adapter
callback positive controls, and no content callbacks after each denial.
Membership revocation retains direct `forbidden` and existing retryable
`storage_unavailable` public behavior; all other expected denial codes and the
original 13 DTO contracts remain unchanged. The explicit module-loading
assertion precedes the unchanged export/malformed-port assertions. This result
does not establish successful denial-audit persistence. Owned database/storage
cleanup and PostgreSQL shutdown completed; no auth/audit/Vault source changed.

The amendment's initial combined gate reported Runtime **106 tests, zero
failures, 22 exclusions** (84 executed), 1.8 seconds, and Web **44 tests, four
failures**, 1.7 seconds, seed `359211`, exit 2. Three failures were the unchanged
guide's active-phase inconsistency. One new negative fixture relocated API map
entries inside an incomplete function body, so its syntax/registration positive
control failed before reaching the byte guard. Amendment repair 1 changed only
the two relocation destinations to complete syntax boundaries; no parse,
registration, mutation, or baseline assertion was removed.

The complete same scoped command then reported Runtime **106 tests, zero
failures, 22 exclusions** (84 executed), 1.9 seconds, and Web **44 tests, three
failures**, 1.7 seconds, seed `839908`, exit 2. All 48 new Phase 3 mutation/removal/
duplication/relocation scenarios, original Phase 2 guards, closed registration,
legacy-byte digests, browser exclusions, and dependency-boundary checks passed.
The only remaining failures are:

- `notes_scope_contract_test.exs:271`: guide roadmap declares Phase 2, not Phase 3.
- `knowledge_phase1_contract_test.exs:61`: active guide disagrees with README/AGENTS.
- `knowledge_phase1_contract_test.exs:120`: guide governing links/current gate
  still target Phase 2.

The guide remains untouched. These failures are not waived: full Task 8
acceptance and commit remain blocked on separately authorized alignment of
the guide's active header, roadmap, and current gate, preserving historical
sections and all existing restrictions. One bounded amendment fixture repair
succeeded; no Astra escalation was needed. Two fresh parallel review dispatches
hit the runner's thread limit; independent review stages are serialized instead.

Combined live regressions also passed on an owned fresh database: Storage
**27 tests, zero failures**, 15.3 seconds, plus Runtime **60 reported tests,
zero failures, 38 exclusions** (22 executed), 15.7 seconds, seed `273758`,
exit 0. This is **49 executed integration tests**, covering new search/exact
source behavior plus legacy Note search, Asset search, and Document APIs.
Owned database/storage cleanup and PostgreSQL shutdown completed.

Independent read-only Task 8 SPEC review passed, followed by a separate
QUALITY review with no actionable findings in the six Runtime/Storage
implementation and test paths. The two-file architecture amendment then
passed its separate SPEC review: all 12 source additions matched their exact
normalization blocks, original Phase 2 hashes/registration/negative controls
were retained, and the three guide-consistency failures remained required.
The amendment's separate independent QUALITY review also passed with no
Critical, Important, or Minor findings. Reviewers made no edits or test/service
mutations. These bounded reviews do not waive the failed compatibility gate
or establish Task 8 acceptance.

Scoped formatting verification, warnings-as-errors compilation, and xref
completed successfully (exit 0); xref reported **No cycles found**.
`git diff --check` passed. A protected-path diff confirmed no changes to
`docs/guide.md`, AGENTS, README, configuration, `OperationScope`, `Authorize`,
or migrations. No E2E, Vault feature work, authorization/audit behavior change,
Task 9 work, commit, merge, push, tag, release, or deployment occurred.

Final preservation checks passed again: no owned PostgreSQL postmaster PID,
clean root main at `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`, and unchanged
Phase 2 worktree at `ff703bd710074738b0391bb2f29d585dc6166d5c`. Its unrelated
untracked runtime-outcomes plan remains present with unchanged SHA-256
`350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.
All task processes and review commands have finished; owned code/test files
remain frozen pending the guide-only scope decision. The full release goal
remains incomplete.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted apps/singularity_runtime/lib/singularity/runtime/api.ex apps/singularity_runtime/lib/singularity/runtime/search/search.ex apps/singularity_runtime/lib/singularity/runtime/search/resolve.ex apps/singularity_runtime/lib/singularity/runtime/dto/knowledge_source.ex apps/singularity_storage/lib/singularity/storage/postgres/knowledge_search_store.ex apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs + compile --warnings-as-errors + xref graph --format cycles --fail-above 0
git diff --check
git diff --exit-code -- docs/guide.md AGENTS.md README.md config apps/singularity_runtime/lib/singularity/runtime/operation_scope.ex apps/singularity_runtime/lib/singularity/runtime/authorize.ex apps/singularity_storage/priv/repo/migrations
```

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/asset_search_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_store_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_pagination_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs
```

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix run --no-start --no-compile -e 'module = Singularity.Storage.Postgres.KnowledgeSearchStore; IO.inspect({:before, :code.is_loaded(module), function_exported?(module, :resolve, 2)}); IO.inspect(Code.ensure_loaded(module)); IO.inspect({:after, function_exported?(module, :resolve, 2)})'
```

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs apps/singularity_runtime/test/singularity/runtime/note_api_test.exs apps/singularity_runtime/test/singularity/runtime/asset_search_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_runtime/test/singularity/runtime/api_test.exs apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs
```

```sh
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs:931 apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs:1091
```

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_runtime/lib/singularity/runtime/search/search.ex apps/singularity_runtime/lib/singularity/runtime/search/resolve.ex apps/singularity_runtime/lib/singularity/runtime/dto/knowledge_source.ex apps/singularity_runtime/lib/singularity/runtime/api.ex apps/singularity_storage/lib/singularity/storage/postgres/knowledge_search_store.ex apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs + test apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs
```

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs + test apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs
devenv shell -- bash .devenv/phase3-integration.sh apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs
```

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs
```

### Approved guide alignment, 2026-10-10

The user approved the guide-only alignment requested after the three remaining
consistency failures: update the active governing links, roadmap, and current
implementation gate to Phase 3, preserving historical material and all existing
restrictions. Existing Task 8 ownership remains unchanged; no test assertion,
Vault/auth/audit behavior, E2E, later-phase work, or publication is authorized
by this documentation amendment.

Before any guide edit, the complete two-module architecture command reproduced
**29 tests, three failures**, seed `791684`, 1.6 seconds, exit 2. The failures
were exactly the guide's Phase 2 roadmap and missing Phase 3 governing links/
current gate. All other architecture assertions passed. The guide was clean
against HEAD `75df901dc70047c16aeabbcdd92d7b71ef514dc5` at this baseline.

- [x] Apply only the approved guide sections; retain all historical and
  activation/publication/custody/Vault restrictions.
- [x] Rerun the complete scoped unit/architecture compatibility command and
  live search/legacy regressions without editing their assertions.
- [x] Obtain independent guide SPEC review followed by QUALITY review; record
  exact verification and preservation evidence before Task 8 acceptance.

Only the three approved guide regions changed. The original governing links,
Phase 1 acceptance, qualified Phase 2 tested source/documentation handoff,
historical sections 1–20, invariants/ADRs in sections 22–23, and all existing
restrictions are preserved. Independent SPEC review passed, followed by a
separate QUALITY review with no findings. Both reviewers independently checked
the actual diff, link targets, and byte-identical historical regions. No repair
round or Astra escalation was needed for this guide amendment.

The exact complete scoped compatibility command recorded above passed:
Runtime **106 reported tests, zero failures, 22 exclusions** (84 executed),
1.9 seconds, and Web **44 tests, zero failures**, 1.7 seconds, seed `292933`,
exit 0. The two architecture files' SHA-256 values remained unchanged across
this guide-only repair (`90ea2b3f90c77a36599b83596dae7d0a866db503f096db4d65a39fdcb916b105`
and `213771fb89c8bd39e61d9ab402fca10366014bfc6fa06eab15272c6971d59926`).
No required assertion was changed, skipped, weakened, or reclassified.

The exact combined live regression command recorded above also passed:
Storage **27 tests, zero failures**, 13.3 seconds, and Runtime **60 reported
tests, zero failures, 38 exclusions** (22 executed), 10.5 seconds, seed
`281966`, exit 0: **49 executed integration tests**. The owned database/storage
lifecycle completed, its allocated storage root was absent afterward, and the
owned PostgreSQL instance stopped with no postmaster PID remaining.

The exact scoped format/compile/xref command recorded above passed again,
exit 0, with **No cycles found**. `git diff --check` and protected-path checks
passed. AGENTS, README, configuration, `OperationScope`, `Authorize`, and
migrations remained unchanged. The previously reviewed Task 8 implementation
and test-only denial correction remained frozen during this amendment.

Task 8's six Runtime/Storage implementation/test paths, two architecture
contracts, guide alignment, and this evidence record form one locally tested
and independently reviewed change. Exact immutable source resolution, live
authorization/unlock boundaries, denial callback exclusion, and legacy
Note/Asset/Document API compatibility have scoped evidence above. Successful
denial-audit persistence is not established by these tests. No migration,
grant, Vault feature, auth/audit behavior change, E2E, full-phase acceptance,
merge, push, tag, release, deployment, or production activation occurred.

**Files:** Create Runtime `search/search.ex`, `search/resolve.ex`, the three DTO
files in the map, and `apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs`.
Modify Runtime `api.ex` and the new Storage search adapter for `resolve/2`.

Independent execution boundary: the result/page DTO conversion can proceed
using the completed Core/Retrieval contracts while Task 3 awaits its authority
amendment. This sub-slice creates only the two result/page DTO files and pure
cases in `knowledge_search_api_test.exs`; it does not wire `Api`, change
`OperationScope` or configuration, or add a persistence fallback. Exact-source
DTO conversion remains deferred until its canonical adapter shape is defined.
The DTO seam accepts exact typed internal values, revalidates owner, identity,
bounds, and query before removing internal fields, and preserves validated
content/locator/timestamp values. It does not prove live authorization or SQL.

Pre-change baseline: existing Retrieval knowledge/legacy search and Runtime
`note_reads_test.exs` passed 48 tests, zero failures (seed 203470). The command
used the explicit test environment and shared locked dependency path above;
no PostgreSQL or E2E ran.

- [x] RED: injected-runtime API rejects owner overrides and converts a valid
  internal page to exactly the public result keys; malformed/foreign adapter
  values never escape. Use the established `note_reads_test.exs` scope fake
  only for orchestration, followed by actual-role integration coverage.
- [x] Compose existing `OperationScope.with_read_request/4`: Note uses
  `note.read` plus existing unlock; Document uses `asset.read` and
  `requires_unlocked?: false`; mixed uses both capabilities, sorted and conjunctive,
  with the Note unlock requirement. Never silently return only one authorized kind.
- [x] Add exact `SearchSource` resolution independent of projection presence.
  Reuse NoteRepository exact version lookup; read Document fragment by full
  resource/version/fragment/owner identity and live parent/ready state. Do not
  join a current-head equality into historical exact resolution. Revalidate
  canonical locator, identity, and content bounds before constructing the DTO.
- [x] API errors distinguish malformed `invalid` from identity/tombstone
  `not_found`; preserve established authorization errors. Return exact title/body
  and locator, never source storage coordinates or a silently updated head.
  No binary download/custody change belongs in this use case.
- [x] Real tests remove the projection, advance a Note head, and resolve the
  older result; forge each identity component and verify failure. Assert public
  API dependency boundaries and all legacy Notes/Asset API contracts remain intact.

```sh
devenv shell -- mix test apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs
devenv shell -- mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs
```

- [x] Review and commit `feat(runtime): expose authenticated unified search and exact sources`.

Task 8 independent result/page DTO slice: **implemented and reviewed**, commit
`1f9f71b`. `KnowledgeSearchResult.from_result/2` and
`KnowledgeSearchPage.from_page/2` accept exact typed Retrieval values only,
validate the query first, revalidate the complete internal value, then expose
only the approved public fields. Revalidation must preserve the typed value
exactly; forged locators or timestamps cannot be normalized into a different
source at this boundary. Typed terminal `nil` is translated to raw `:done`
only while reusing the existing page validator; the raw port is unchanged.
Malformed queries return sanitized `invalid`; malformed internal output returns
content-free retryable `storage_unavailable`.

The following test-only command failed all 13 new cases at the expected
missing-module assertions (seed 221894), before either DTO was implemented:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs
```

The same cases then passed with the existing Note-read and Retrieval contracts
(61 tests, seed 356034). Independent spec review passed before a separate
quality review passed. The final combined focused command was:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_core/test/singularity/core/search_source_test.exs apps/singularity_core/test/singularity/core/search_policy_test.exs apps/singularity_core/test/singularity/core/source_locator_test.exs apps/singularity_core/test/singularity/core/knowledge_link_values_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_search_cursor_test.exs apps/singularity_retrieval/test/singularity/retrieval/knowledge_search_test.exs apps/singularity_retrieval/test/singularity/retrieval/note_lexical_search_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs
```

Result: Core 33 tests plus 2 properties, Storage 11 tests, Retrieval 39 tests,
Runtime 22 tests (13 new DTO, 9 legacy); **105 tests plus 2 properties, zero
failures**, seed 114286. Scoped formatting checks and `git diff --check`
passed; `mix xref graph --format cycles --fail-above 0` reported no cycles.
No API wiring, authorization, canonical exact-source read, database migration,
bootstrap, configuration, or Vault file changed. No PostgreSQL, E2E, full phase
gate, merge, push, release, or deployment ran in this sub-slice. Task 8 as a
whole remains pending; these are pure boundary contracts, not live acceptance.

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
