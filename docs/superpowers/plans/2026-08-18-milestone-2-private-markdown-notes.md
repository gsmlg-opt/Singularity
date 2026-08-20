# Milestone 2 Private Markdown Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the first Milestone 2 vertical: private Markdown notes with
explicit Save, immutable versions, deterministic conflict preservation and
merge, current-only PostgreSQL lexical search, exact Markdown export,
tombstone/restore, logical backup V2, and the focused Notes App-Clip workspace.

**Architecture:** Pure note values live in `singularity_core`; mutation intent
construction lives in `singularity_domains`; PostgreSQL, RLS, canonical note
tables, receipts, projections, and backup live in `singularity_storage`;
lexical query/page semantics live in `singularity_retrieval`; authorized use
cases and DTO conversion live in `singularity_runtime`; Phoenix and the React
App Clip live in `singularity_web`. PostgreSQL remains canonical, the lexical
row is a synchronously maintained projection, and identifier-only outbox jobs
reconcile from canonical state.

**Tech Stack:** Elixir 1.18.4, Erlang/OTP 28, Ecto SQL, Postgrex, PostgreSQL 17,
Oban, Phoenix 1.8, LiveView, DuskmoonBundler 9.9.7, React 19, TypeScript 7,
`react-markdown` 10.1.0, Vitest, Playwright/Chromium, ExUnit, StreamData, and
OTP `:crypto` HMAC-SHA-256.

**Authority:**
[`docs/superpowers/specs/2026-08-18-milestone-2-private-markdown-notes-design.md`](../specs/2026-08-18-milestone-2-private-markdown-notes-design.md)
is the approved contract. If implementation pressure conflicts with it, stop
and amend the design rather than silently changing behavior.

---

## Scope check

This is one dependent tracer-bullet vertical, not a set of independent
subsystems. Core, persistence, runtime, backup, and UI are all required to
prove the same note lifecycle, so they remain in one cumulative plan and one
implementation branch.

Do not add:

- CouchDB or a CouchDB compatibility layer;
- attachments or ESS integration;
- tags, relationships, PDF import, extraction, citations, or RAG;
- Qdrant dependencies, configuration, collections, workers, adapters, or
  supervision children;
- agents or model calls;
- autosave, offline draft persistence, CRDTs, or live collaboration;
- public, sensitive, or restricted notes;
- rich-text/WYSIWYG editing;
- framework forks or dependency source overrides;
- a direct web dependency on Core, Domains, Storage, or Retrieval.

Qdrant remains required for a later semantic-search slice. This plan creates
only the identifier-only canonical-state reconciliation seam and an executable
exclusion guard.

Only run the focused paths named by each task. If an unrelated or deferred test
fails, record it and stop instead of broadening this plan.

## Execution worktree

At execution time, use `superpowers:using-git-worktrees` and create exactly one
cumulative worktree under:

```text
.trees/codex-milestone-2-private-notes
```

Use branch:

```text
codex/milestone-2-private-notes
```

All tasks, reviews, and fixes stay on that branch. Do not create one branch per
task.

## Fixed dependency graph

The existing graph must not change:

```text
singularity_core      -> []
singularity_domains   -> [singularity_core]
singularity_storage   -> [singularity_core, singularity_domains]
singularity_ingest    -> [singularity_core, singularity_domains]
singularity_retrieval -> [singularity_core, singularity_domains]
singularity_runtime   -> [singularity_core, singularity_storage,
                          singularity_domains, singularity_ingest,
                          singularity_retrieval]
singularity_web       -> [singularity_runtime]
```

## Cross-cutting implementation rules

1. Start every behavior with a failing focused test.
2. Every mutation enters through `ScopedRepo.transact/4`, holds the resource
   row lock, and commits receipt, canonical rows, projection, audit, and outbox
   atomically.
3. `revision` is the global snapshot-creation sequence for one resource. Never
   infer canonical state from the greatest revision.
4. Note classification is server-composed as `:private`; no browser payload
   accepts classification.
5. Note Markdown is allowed only in authorized DTO/bridge payloads, canonical
   repository/search arguments, and export output.
6. Supported logs, Singularity telemetry, audit, outbox, receipts, and errors
   contain identifiers and bounded metadata only.
7. Keep immutable note snapshots INSERT/SELECT-only for runtime roles.
8. Keep the existing supported observability boundary; do not subscribe to raw
   dependency events.
9. Use exact request/reply key validation on both LiveView and TypeScript sides.
10. Make one conventional commit per completed task and use no AI trailers.

## Final file structure

New production files are organized by one responsibility:

```text
apps/singularity_core/lib/singularity/core/
├── note_snapshot.ex
├── note_conflict.ex
├── note_save_result.ex
└── note_search_store.ex

apps/singularity_domains/lib/singularity/domains/
├── notes.ex
└── notes/repository.ex

apps/singularity_retrieval/lib/singularity/retrieval/
├── note_search_query.ex
├── note_search_page.ex
└── note_lexical_search.ex

apps/singularity_storage/lib/singularity/storage/
├── schema/content/
│   ├── note_version.ex
│   ├── note_conflict.ex
│   ├── note_search_document.ex
│   └── note_mutation_receipt.ex
├── postgres/
│   ├── note_mutation_receipts.ex
│   ├── note_repository.ex
│   ├── note_search_store.ex
│   └── note_projection_reconciler.ex
└── backup/logical_schema_v2.ex

apps/singularity_runtime/lib/singularity/runtime/
├── notes/
│   ├── create.ex
│   ├── get.ex
│   ├── search.ex
│   ├── trash.ex
│   ├── history.ex
│   ├── save.ex
│   ├── merge.ex
│   ├── delete.ex
│   ├── restore.ex
│   ├── export.ex
│   ├── mutation_fingerprint.ex
│   ├── projection.ex
│   └── dto.ex
└── dto/
    ├── note_summary.ex
    ├── note.ex
    ├── note_version_summary.ex
    ├── note_version.ex
    ├── note_conflict.ex
    ├── note_conflict_detail.ex
    ├── note_search_page.ex
    ├── note_trash_page.ex
    ├── note_history_page.ex
    ├── note_save_result.ex
    └── note_export.ex

apps/singularity_web/
├── lib/singularity/web/
│   ├── live/notes_live.ex
│   └── controllers/note_export_controller.ex
└── assets/js/
    ├── clips/mount_notes_workspace.tsx
    └── notes_workspace/
        ├── contracts.ts
        ├── state.ts
        ├── safe_markdown.tsx
        └── NotesWorkspace.tsx
```

Tests live beside the existing app-specific suites and are listed exactly in
each task.

## Common verification commands

Run from the implementation worktree. Enter one persistent `devenv shell` when
possible; non-interactive calls use the prefix shown below.

```bash
devenv up -d
devenv processes wait --timeout 120
devenv shell -- mix deps.get
devenv shell -- mix deps.unlock --check-unused
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test <focused paths named by the task>
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
```

Database tasks use:

```bash
devenv shell -- mix singularity.test.integration <focused integration paths>
```

Backup tasks use:

```bash
devenv shell -- mix singularity.test.restore
```

Frontend tasks use:

```bash
devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install
devenv shell -- mix npm.verify
devenv shell -- mix duskmoon_bundler.js.check
devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind
```

Stop managed services after the final gate:

```bash
devenv down
```

---

### Task 1: Add pure note values and the search-store port

**Files:**

- Create: `apps/singularity_core/lib/singularity/core/note_snapshot.ex`
- Create: `apps/singularity_core/lib/singularity/core/note_conflict.ex`
- Create: `apps/singularity_core/lib/singularity/core/note_save_result.ex`
- Create: `apps/singularity_core/lib/singularity/core/note_search_store.ex`
- Modify: `apps/singularity_core/lib/singularity/core/types.ex`
- Create: `apps/singularity_core/test/singularity/core/note_values_test.exs`
- Modify: `apps/singularity_core/test/singularity/core/ports_test.exs`

- [ ] **Step 1: Write failing note-value tests**

  Add focused tests with canonical UUID fixtures:

  ```elixir
  test "normal snapshots trim title and preserve Markdown exactly" do
    markdown = "# Heading\n\n<body onclick='x'>kept as source</body>\n"

    assert {:ok,
            %NoteSnapshot{
              classification: :private,
              title: "Heading",
              markdown: ^markdown,
              parent_version_id: @version_id,
              merge_parent_version_id: nil
            }} =
             NoteSnapshot.normal(%{
               classification: :private,
               title: "  Heading  ",
               markdown: markdown,
               parent_version_id: @version_id
             })
  end

  test "merge snapshots require two distinct parents" do
    assert {:error, %Error{code: :invalid}} =
             NoteSnapshot.merge(%{
               classification: :private,
               title: "Merged",
               markdown: "result",
               parent_version_id: @version_id,
               merge_parent_version_id: @version_id
             })
  end

  test "Markdown rejects NUL and values over one MiB" do
    assert {:error, %Error{code: :invalid}} =
             NoteSnapshot.initial(%{
               classification: :private,
               title: "NUL",
               markdown: <<"bad", 0>>
             })

    assert {:error, %Error{code: :invalid}} =
             NoteSnapshot.initial(%{
               classification: :private,
               title: "Large",
               markdown: :binary.copy("x", 1_048_577)
             })
  end
  ```

  Cover invalid UTF-8, whitespace-only/256-byte titles, non-private
  classification, initial/normal/merge parent shapes, open/resolved conflicts,
  and saved/conflict result shapes.

- [ ] **Step 2: Run the tests and verify RED**

  Run:

  ```bash
  devenv shell -- mix test \
    apps/singularity_core/test/singularity/core/note_values_test.exs \
    apps/singularity_core/test/singularity/core/ports_test.exs
  ```

  Expected: compilation fails because the four Note modules do not exist.

- [ ] **Step 3: Add a canonical UUID helper without changing opaque IDs**

  Add to `Types`:

  ```elixir
  @canonical_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @spec canonical_uuid(map(), atom()) :: {:ok, String.t()} | {:error, Error.t()}
  def canonical_uuid(attrs, key) when is_map(attrs) and is_atom(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        if Regex.match?(@canonical_uuid, value), do: {:ok, value}, else: invalid()

      _other ->
        invalid()
    end
  end
  ```

  Keep `opaque_string/2` unchanged for existing values.

- [ ] **Step 4: Implement `NoteSnapshot`**

  Use this exact public shape:

  ```elixir
  defmodule Singularity.Core.NoteSnapshot do
    alias Singularity.Core.Classification
    alias Singularity.Core.Error
    alias Singularity.Core.Types

    @max_title_bytes 255
    @max_markdown_bytes 1_048_576
    @enforce_keys [:classification, :title, :markdown]
    defstruct @enforce_keys ++ [:parent_version_id, :merge_parent_version_id]

    def initial(attrs), do: build(attrs, :initial)
    def normal(attrs), do: build(attrs, :normal)
    def merge(attrs), do: build(attrs, :merge)

    defp build(attrs, shape) do
      with {:ok, attrs} <- Types.attrs(attrs),
           {:ok, classification} <- Classification.new(Map.get(attrs, :classification)),
           :ok <- require_private(classification),
           {:ok, title} <- title(attrs),
           {:ok, markdown} <- markdown(attrs),
           {:ok, parent, merge_parent} <- parents(attrs, shape) do
        {:ok,
         %__MODULE__{
           classification: classification,
           title: title,
           markdown: markdown,
           parent_version_id: parent,
           merge_parent_version_id: merge_parent
         }}
      else
        {:error, %Error{}} = error -> error
        _invalid -> invalid()
      end
    end

    defp require_private(:private), do: :ok
    defp require_private(_classification), do: invalid()
    defp invalid, do: {:error, Error.new(:invalid)}
  end
  ```

  Implement `title/1`, `markdown/1`, and `parents/2` directly from the approved
  byte, UTF-8, NUL, and parent rules. Do not normalize Markdown.

- [ ] **Step 5: Implement conflict, Save result, and search-store contracts**

  `NoteConflict.open/1` and `resolved/1` must return structs with exact IDs,
  classification, state, resolution ID, and UTC timestamps. Define the port:

  `Singularity.Core.NoteSaveResult` is an internal reference result only. Its
  exact fields are `outcome`, `resource_id`, `canonical_version_id`,
  `submitted_version_id`, and nullable `conflict_id`; it never contains
  Markdown or a hydrated Note. Runtime reloads canonical state before creating
  `Singularity.Runtime.DTO.NoteSaveResult`.

  ```elixir
  defmodule Singularity.Core.NoteSearchStore do
    alias Singularity.Core.Error

    @callback search(term(), term()) :: {:ok, map()} | {:error, Error.t()}
    @callback upsert(term(), map()) :: :ok | {:error, Error.t()}
    @callback delete(term(), map()) :: :ok | {:error, Error.t()}
  end
  ```

  Add the callback list to `ports_test.exs`.

- [ ] **Step 6: Run focused Core checks**

  Run the Step 2 command again.

  Expected: all focused tests pass.

- [ ] **Step 7: Commit**

  ```bash
  git add apps/singularity_core
  git commit -m "feat(core): add private note values"
  ```

### Task 2: Add the `Domains.Notes` mutation boundary

**Files:**

- Create: `apps/singularity_domains/lib/singularity/domains/notes.ex`
- Create: `apps/singularity_domains/lib/singularity/domains/notes/command.ex`
- Create: `apps/singularity_domains/lib/singularity/domains/notes/repository.ex`
- Create: `apps/singularity_domains/test/support/fake/note_repository.ex`
- Create: `apps/singularity_domains/test/singularity/domains/notes_test.exs`

- [ ] **Step 1: Write failing intent-forwarding tests**

  Use an Agent-backed fake and assert exact intent fields:

  ```elixir
  test "save builds one-parent immutable intent" do
    command = %{
      mutation_id: @mutation_id,
      resource_id: @resource_id,
      base_version_id: @base_version_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      classification: :private,
      title: "  Revised  ",
      markdown: "body",
      correlation_id: @correlation_id
    }

    assert {:ok, prepared} = Command.new(:save, command)
    assert {:ok, :stored} =
             Notes.execute(adapters(), prepared, :binary.copy(<<7>>, 32))
    assert_receive {:save, %{snapshot: %NoteSnapshot{title: "Revised"}} = intent}
    assert intent.snapshot.parent_version_id == @base_version_id
    assert intent.snapshot.merge_parent_version_id == nil
    assert intent.request_fingerprint == :binary.copy(<<7>>, 32)
  end
  ```

  Add equivalent create, merge, tombstone, restore, malformed UUID, and
  non-32-byte fingerprint tests.

- [ ] **Step 2: Verify RED**

  Run:

  ```bash
  devenv shell -- mix test apps/singularity_domains/test/singularity/domains/notes_test.exs
  ```

  Expected: compilation fails because `Singularity.Domains.Notes` is missing.

- [ ] **Step 3: Define the repository behaviour**

  ```elixir
  defmodule Singularity.Domains.Notes.Repository do
    alias Singularity.Core.Error

    @callback create(term(), map()) :: {:ok, map()} | {:error, Error.t()}
    @callback save(term(), map()) :: {:ok, map()} | {:error, Error.t()}
    @callback merge(term(), map()) :: {:ok, map()} | {:error, Error.t()}
    @callback tombstone(term(), map()) :: {:ok, map()} | {:error, Error.t()}
    @callback restore(term(), map()) :: {:ok, map()} | {:error, Error.t()}
  end
  ```

- [ ] **Step 4: Implement canonical command preparation**

  `Singularity.Domains.Notes.Command.new/2` accepts the operation and raw
  caller fields, validates every canonical UUID and byte bound, builds the
  appropriate `NoteSnapshot`, and returns one immutable command struct. It also
  exposes `fingerprint_term/1`, a fixed operation-specific tuple containing
  every canonical caller field and no server-generated result ID.

  The tuples are exact:

  ```text
  create:    mutation_id title markdown
  save:      mutation_id resource_id base_version_id title markdown
  merge:     mutation_id resource_id conflict_id expected_current_version_id
             competing_version_id title markdown
  tombstone: mutation_id resource_id expected_current_version_id
  restore:   mutation_id resource_id
  ```

  Transport `version`, server-derived principal/vault/correlation values, and
  generated result IDs are not caller command fields and are excluded.

  ```elixir
  with {:ok, command} <- Command.new(:save, raw_command),
       {:ok, result} <- Notes.execute(adapters, command, :binary.copy(<<7>>, 32)) do
    {:ok, result}
  end
  ```

- [ ] **Step 5: Implement exact intent construction**

  Expose:

  ```elixir
  execute(adapters, %Command{} = command, <<_::binary-size(32)>> = fingerprint)
  ```

  Merge the fingerprint into the already canonical intent and call the
  operation's repository callback with `adapters.repository_context`. Reject
  any non-Command input. Keep outcome-dependent audit/outbox selection in the
  repository because it depends on locked canonical state.

- [ ] **Step 6: Implement the strict fake**

  The fake records `{operation, intent}` to the test process and returns a
  configured exact result. Reject callback names or intent keys not declared by
  the behaviour.

  ```elixir
  def save(%{owner: owner, result: result}, intent) when is_map(intent) do
    send(owner, {:save, intent})
    result
  end
  ```

- [ ] **Step 7: Run focused tests and architecture guard**

  ```bash
  devenv shell -- mix test \
    apps/singularity_domains/test/singularity/domains/notes_test.exs \
    apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  ```

  Expected: all focused tests pass and the dependency graph is unchanged.

- [ ] **Step 8: Commit**

  ```bash
  git add apps/singularity_domains
  git commit -m "feat(domains): add note mutation intents"
  ```

### Task 3: Add lexical query, page, and orchestration values

**Files:**

- Create: `apps/singularity_retrieval/lib/singularity/retrieval/note_search_query.ex`
- Create: `apps/singularity_retrieval/lib/singularity/retrieval/note_search_page.ex`
- Create: `apps/singularity_retrieval/lib/singularity/retrieval/note_lexical_search.ex`
- Create: `apps/singularity_retrieval/test/singularity/retrieval/note_lexical_search_test.exs`

- [ ] **Step 1: Write failing query/page tests**

  ```elixir
  test "query defaults to current private notes" do
    assert {:ok,
            %NoteSearchQuery{
              vault_id: @vault_id,
              q: "",
              limit: 20,
              cursor: nil,
              classification: :private
            }} = NoteSearchQuery.new(%{vault_id: @vault_id})
  end

  test "query rejects unknown and conflicting atom/string keys" do
    assert {:error, %Error{code: :invalid}} =
             NoteSearchQuery.new(%{vault_id: @vault_id, state: "deleted"})

    assert {:error, %Error{code: :invalid}} =
             NoteSearchQuery.new(%{vault_id: @vault_id, "vault_id" => @other_vault_id})
  end
  ```

  Cover 1,024-byte query, 2,048-byte cursor, UTF-8/NUL, limits 1 and 50,
  invalid 0/51, cursor normalization, malformed store pages, cross-vault items,
  non-private items, too many items, and Markdown/snippet field rejection.

- [ ] **Step 2: Verify RED**

  ```bash
  devenv shell -- mix test apps/singularity_retrieval/test/singularity/retrieval/note_lexical_search_test.exs
  ```

  Expected: compilation fails because the Note retrieval modules are absent.

- [ ] **Step 3: Implement `NoteSearchQuery` and `NoteSearchPage`**

  Mirror the exact atom/string-key normalization of `AssetSearchQuery`, but
  accept only `vault_id`, `q`, `limit`, and `cursor`. Require a canonical vault
  UUID, set classification internally to `:private`, trim query text, default
  limit to 20, and normalize store cursor `:done` to `nil`.

  ```elixir
  @fields [:vault_id, :q, :limit, :cursor]
  @enforce_keys @fields ++ [:classification]
  defstruct @enforce_keys

  defp limit(params) do
    case Map.get(params, :limit, 20) do
      value when is_integer(value) and value in 1..50 -> {:ok, value}
      _invalid -> {:error, Error.new(:invalid)}
    end
  end
  ```

- [ ] **Step 4: Implement defensive lexical orchestration**

  ```elixir
  defmodule Singularity.Retrieval.NoteLexicalSearch do
    alias Singularity.Core.Error
    alias Singularity.Retrieval.NoteSearchPage

    def search(store, context, query) do
      case store.search(context, query) do
        {:ok, %{items: items, next_cursor: cursor}}
        when is_list(items) and length(items) <= query.limit ->
          with :ok <- validate_items(items, query),
               {:ok, page} <- NoteSearchPage.new(items, cursor) do
            {:ok, page}
          end

        {:error, %Error{}} = error ->
          error

        _malformed ->
          {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    rescue
      _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    catch
      _kind, _reason -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end
  ```

  `validate_items/2` requires exact summary keys, matching vault, private
  classification, canonical resource/version UUIDs, nonnegative revision and
  conflict count, and no Markdown/snippet key.

- [ ] **Step 5: Run focused tests**

  Run the Step 2 command again.

  Expected: all tests pass.

- [ ] **Step 6: Commit**

  ```bash
  git add apps/singularity_retrieval
  git commit -m "feat(retrieval): add note lexical query contracts"
  ```

### Task 4: Create the Notes schema, constraints, RLS, and capabilities

**Files:**

- Create: `apps/singularity_storage/priv/repo/migrations/20260818000100_create_private_markdown_notes.exs`
- Modify: `apps/singularity_storage/lib/singularity/storage/schema/content/resource.ex`
- Modify: `apps/singularity_storage/lib/singularity/storage/schema/content/resource_version.ex`
- Create: `apps/singularity_storage/lib/singularity/storage/schema/content/note_version.ex`
- Create: `apps/singularity_storage/lib/singularity/storage/schema/content/note_conflict.ex`
- Create: `apps/singularity_storage/lib/singularity/storage/schema/content/note_search_document.ex`
- Create: `apps/singularity_storage/lib/singularity/storage/schema/content/note_mutation_receipt.ex`
- Create: `apps/singularity_storage/lib/singularity/storage/postgres/note_capability_reconciler.ex`
- Create: `apps/singularity_storage/test/support/note_fixtures.ex`
- Create: `apps/singularity_storage/test/singularity/storage/note_schema_test.exs`
- Create: `apps/singularity_storage/test/singularity/storage/note_rls_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/migrations_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/roles_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/classification_inheritance_test.exs`

- [ ] **Step 1: Write failing schema and downgrade tests**

  Mark database tests `@tag :integration` and assert:

  ```elixir
  assert column!("content", "resources", "kind").default == "'asset'::text"
  assert column!("content", "resources", "current_version_id").nullable
  assert forced_rls?(repo, "content", "note_versions")
  assert forced_rls?(repo, "content", "note_conflicts")
  assert forced_rls?(repo, "content", "note_search_documents")
  assert forced_rls?(repo, "content", "note_mutation_receipts")
  ```

  Add SQL attempts that must fail for a note head pointing to an asset version,
  mismatched classification, same merge parents, malformed conflict state,
  31-byte receipt fingerprint, and direct UPDATE/DELETE of `note_versions` as
  `singularity_web`. Add a downgrade test that inserts one note and expects the
  migration down path to refuse data loss.

- [ ] **Step 2: Write failing RLS and capability tests**

  Cover missing GUC context, another vault, non-member, revoked member, active
  owner, table owner, and worker grants for every table. Verify the migration
  creates `note.read`, `note.write`, and `note.export` and grants them only to
  active principals already holding `vault.password_change`.

  Also assert `singularity_worker` retains no direct `SELECT` on
  `content.note_conflicts`. Cover the backup-only
  `content.export_note_conflicts_for_backup(uuid)` seam: web and PUBLIC cannot
  execute it; worker calls with missing/mismatched GUCs, missing or revoked
  `backup.create`, revoked principal/membership, or inactive account return no
  rows; an active authorized worker receives only its requested private vault's
  exact 11 conflict columns in conflict-ID order.

- [ ] **Step 3: Verify RED**

  ```bash
  devenv shell -- mix singularity.test.integration \
    apps/singularity_storage/test/singularity/storage/note_schema_test.exs \
    apps/singularity_storage/test/singularity/storage/note_rls_test.exs \
    apps/singularity_storage/test/singularity/storage/migrations_test.exs \
    apps/singularity_storage/test/singularity/storage/roles_test.exs \
    apps/singularity_storage/test/singularity/storage/classification_inheritance_test.exs
  ```

  Expected: tests fail because the Notes migration and tables do not exist.

- [ ] **Step 4: Implement the migration's aggregate constraints**

  The migration must execute as `singularity_table_owner` and create these
  exact structural keys:

  ```sql
  ALTER TABLE content.resources
    ADD COLUMN kind text NOT NULL DEFAULT 'asset',
    ADD COLUMN current_version_id uuid,
    ADD CONSTRAINT resources_kind_check CHECK (kind IN ('asset', 'note')),
    ADD CONSTRAINT resources_note_head_check
      CHECK (kind <> 'note' OR current_version_id IS NOT NULL),
    ADD CONSTRAINT resources_id_vault_classification_key
      UNIQUE (id, vault_id, classification),
    ADD CONSTRAINT resources_head_vault_classification_key
      UNIQUE (id, current_version_id, vault_id, classification);

  ALTER TABLE content.resource_versions
    ADD CONSTRAINT resource_versions_identity_aggregate_key
      UNIQUE (id, resource_id, vault_id, classification),
    ADD CONSTRAINT resource_versions_resource_classification_fkey
      FOREIGN KEY (resource_id, vault_id, classification)
      REFERENCES content.resources(id, vault_id, classification);
  ```

  Create `note_versions`, `note_conflicts`, `note_search_documents`, and
  `note_mutation_receipts` with exactly the approved columns. Add the deferred
  typed-head and parent FKs only after all target tables exist. Add canonical
  projection FKs to both `resources(id, current_version_id, vault_id,
  classification)` and typed `note_versions`.

- [ ] **Step 5: Add exact checks, indexes, RLS, and grants**

  Add checks for private classification, valid parent shapes, distinct merge
  parents, open/resolved conflict fields, 32-byte receipt fingerprints, and
  pending/completed receipt fields. Add the GIN search-vector index and keyset
  indexes for canonical `head_inserted_at`, revision history, Trash deletion
  time, and receipts.

  Enable and force RLS. Reuse the existing principal/vault GUC and
  `core.principal_is_authorized` policy shape. Grant:

  ```text
  note_versions:          web SELECT, INSERT; worker SELECT
  note_conflicts:         web SELECT, INSERT, UPDATE; worker no grant
  note_search_documents: web SELECT, INSERT, UPDATE, DELETE; worker same
  note_mutation_receipts:web SELECT, INSERT, UPDATE; worker no grant
  ```

  Do not grant snapshot UPDATE or DELETE.

  Create `content.export_note_conflicts_for_backup(requested_vault_id uuid)` as
  a `LANGUAGE sql STABLE SECURITY DEFINER` function owned by
  `singularity_table_owner`, with fixed `search_path` `pg_catalog, content,
  core, identity`. Derive authority only from
  `core.live_principal_authorization()`: the live snapshot vault must equal the
  requested vault, the account/principal/membership must be active, and
  `backup.create` must be active. Return the exact 11 V2 conflict columns for
  private rows in deterministic conflict-ID order. Revoke PUBLIC and web;
  grant `EXECUTE` only to worker. Drop the function before table/privilege
  teardown on down.

  ```sql
  ALTER TABLE content.note_versions ENABLE ROW LEVEL SECURITY;
  ALTER TABLE content.note_versions FORCE ROW LEVEL SECURITY;

  CREATE POLICY note_versions_vault_isolation
  ON content.note_versions
  FOR ALL TO singularity_web, singularity_worker
  USING (
    vault_id = NULLIF(current_setting('singularity.vault_id', true), '')::uuid
    AND core.principal_is_authorized(
      NULLIF(current_setting('singularity.principal_id', true), '')::uuid,
      vault_id
    )
  )
  WITH CHECK (
    vault_id = NULLIF(current_setting('singularity.vault_id', true), '')::uuid
    AND core.principal_is_authorized(
      NULLIF(current_setting('singularity.principal_id', true), '')::uuid,
      vault_id
    )
  );
  ```

- [ ] **Step 6: Seed and reconcile note capabilities**

  Define a table-owner-only SQL function that inserts the three capability
  names and grants them idempotently to active non-system principals with an
  active `vault.password_change` assignment. Increment affected authorization
  epochs. Invoke it at migration end and leave it callable by the restore
  adapter through the migration role only.

  ```sql
  WITH owner_authority AS (
    SELECT 1
    FROM core.principal_capabilities AS assignment
    JOIN core.capabilities AS capability ON capability.id = assignment.capability_id
    WHERE capability.name = 'vault.password_change'
      AND assignment.revoked_at IS NULL
    LIMIT 1
  )
  INSERT INTO core.capabilities (id, name, inserted_at)
  SELECT gen_random_uuid(), requested.name, CURRENT_TIMESTAMP
  FROM (VALUES ('note.export'), ('note.read'), ('note.write')) AS requested(name)
  WHERE EXISTS (SELECT 1 FROM owner_authority)
  ON CONFLICT (name) DO NOTHING;
  ```

  On an empty freshly migrated restore destination, the function inserts
  nothing before import. This avoids name/ID conflicts with V2 capability rows;
  the mandatory post-import reconciliation then creates only missing V1 rows
  and grants.

  Define it as `SECURITY DEFINER` with a fixed `search_path`, owner
  `singularity_table_owner`, `REVOKE ALL ... FROM PUBLIC`, and `GRANT EXECUTE`
  only to `singularity_migration`. Prove web and worker roles cannot
  invoke it. `NoteCapabilityReconciler.reconcile/1` is the sole Elixir adapter
  and executes that fixed function through `MigrationRepo`.

- [ ] **Step 7: Add strict Ecto schemas and fixtures**

  Each changeset casts only declared fields, validates string-keyed JSON where
  applicable, maps every named SQL constraint, and never exposes a general
  update changeset for `NoteVersion`. `NoteFixtures` creates two vaults and
  scoped note attributes without bypassing RLS.

  ```elixir
  def create_changeset(note_version, attrs) do
    note_version
    |> cast(attrs, @fields)
    |> validate_required(@fields -- [:parent_version_id, :merge_parent_version_id])
    |> validate_inclusion(:classification, [:private])
    |> check_constraint(:classification, name: :note_versions_private_check)
  end
  ```

- [ ] **Step 8: Run integration tests**

  Run the Step 3 command again.

  Expected: all focused schema, role, RLS, classification, and downgrade tests
  pass.

- [ ] **Step 9: Commit**

  ```bash
  git add apps/singularity_storage
  git commit -m "feat(storage): add private note schema"
  ```

### Task 5: Implement mutation receipts, create, and canonical Save

**Files:**

- Create: `apps/singularity_storage/lib/singularity/storage/postgres/note_mutation_receipts.ex`
- Create: `apps/singularity_storage/lib/singularity/storage/postgres/note_repository.ex`
- Create: `apps/singularity_storage/lib/singularity/storage/postgres/note_search_store.ex`
- Create: `apps/singularity_storage/lib/singularity/storage/postgres/note_projection_reconciler.ex`
- Create: `apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs`
- Create: `apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs`

- [ ] **Step 1: Write failing receipt tests**

  Add `@tag :integration` tests for a first claim, completed replay, same key
  with another operation/resource/fingerprint, rollback, and two simultaneous
  claims. The winner must run its callback once:

  ```elixir
  tasks =
    for _index <- 1..2 do
      Task.async(fn ->
        scoped(fixture, fn repo ->
          Receipts.with_claim(repo, command, fn ->
            Agent.update(counter, &(&1 + 1))
            {:ok, %{outcome: "saved", resource_id: @resource_id, version_id: @version_id}}
          end)
        end)
      end)
    end

  assert Enum.map(tasks, &Task.await(&1, 5_000)) == [
           {:ok, %{outcome: "saved", resource_id: @resource_id, version_id: @version_id}},
           {:ok, %{outcome: "saved", resource_id: @resource_id, version_id: @version_id}}
         ]

  assert Agent.get(counter, & &1) == 1
  ```

- [ ] **Step 2: Write failing create and canonical-Save tests**

  Assert one transaction creates resource revision zero, immutable snapshot,
  canonical pointer/title, search row with canonical `head_inserted_at`, audit,
  identifier-only `note.current_changed` outbox event, and completed receipt.
  Then Save from that head and assert revision one plus updated canonical state.

  Seed title/Markdown canaries and recursively refute them from audit, outbox,
  and receipt rows while asserting exact canonical/search text.

- [ ] **Step 3: Verify RED**

  ```bash
  devenv shell -- mix singularity.test.integration \
    apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs \
    apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs
  ```

  Expected: compilation fails because the receipt and repository adapters are
  missing.

- [ ] **Step 4: Implement receipt claiming**

  `with_claim/3` must use one outer scoped transaction and this SQL shape:

  ```sql
  INSERT INTO content.note_mutation_receipts (
    vault_id, principal_id, mutation_id, operation, request_fingerprint,
    state, resource_id, inserted_at
  ) VALUES ($1, $2, $3, $4, $5, 'pending', $6, $7)
  ON CONFLICT (vault_id, principal_id, mutation_id) DO NOTHING
  RETURNING mutation_id;
  ```

  If no row returns, lock and load the winner, compare exact operation,
  caller-supplied resource identity when applicable, and fingerprint, require
  `completed`, then return stored IDs. If this transaction owns the pending
  row, run the callback and update state/outcome/result IDs before returning.
  Never commit `pending`.

- [ ] **Step 5: Implement the canonical projection reconciler**

  Expose:

  ```elixir
  reconcile(repo, %{vault_id: vault_id, resource_id: resource_id})
  ```

  Lock/read `resources.current_version_id` joined to the matching typed
  snapshot. Upsert the exact head when live; delete the projection when
  tombstoned. Set `head_inserted_at` from the canonical resource version, not
  wall-clock reconciliation time.

  ```elixir
  def reconcile(repo, %{vault_id: vault_id, resource_id: resource_id}) do
    case load_canonical(repo, vault_id, resource_id) do
      {:ok, %{deleted_at: nil} = canonical} -> upsert(repo, canonical)
      {:ok, %{deleted_at: %DateTime{}}} -> delete(repo, vault_id, resource_id)
      {:error, %Error{}} = error -> error
    end
  end
  ```

  Implement `NoteSearchStore.upsert/2` and `delete/2` in this task and inject
  that Core port into the reconciler. Task 7 will add the store's `search/2`
  query; Task 5 must not bypass the port with private projection SQL.

- [ ] **Step 6: Implement Create**

  `NoteRepository.create/2` must pre-generate candidate resource and version
  IDs, claim the receipt with the candidate resource ID, then insert the `note`
  resource with the deferred head pointer,
  resource revision zero, typed initial snapshot, projection, audit, outbox,
  and receipt outcome. Use `Ecto.Multi` or checked SQL results; map constraint
  and connectivity failures to existing stable errors.

  ```elixir
  def create(repo, intent) do
    candidate_resource_id = Ecto.UUID.generate()
    candidate_version_id = Ecto.UUID.generate()

    claim =
      Map.merge(intent, %{
        resource_id: candidate_resource_id,
        version_id: candidate_version_id
      })

    Receipts.with_claim(repo, claim, fn ->
      with :ok <- insert_resource(repo, intent, candidate_resource_id, candidate_version_id),
           :ok <- insert_version(repo, intent, candidate_resource_id, candidate_version_id, 0),
           :ok <- insert_snapshot(repo, intent, candidate_resource_id, candidate_version_id),
           :ok <- ProjectionReconciler.reconcile(repo, %{vault_id: intent.vault_id, resource_id: candidate_resource_id}),
           :ok <- record_create_effects(repo, intent, candidate_resource_id, candidate_version_id) do
        {:ok,
         %{
           outcome: "saved",
           resource_id: candidate_resource_id,
           version_id: candidate_version_id
         }}
      end
    end)
  end
  ```

  Create IDs are generated before receipt insertion because `resource_id` is
  required on a pending receipt. When another Create already won the same
  mutation key/fingerprint, ignore the losing candidate IDs and return the IDs
  stored by the completed winner.

- [ ] **Step 7: Implement canonical Save**

  Under `SELECT ... FOR UPDATE`, require a live note, verify the base belongs to
  it, compute `max(revision) + 1`, insert generic and typed versions, update
  head/title, call the reconciler, then insert audit/outbox and complete the
  receipt as `saved`. Return `NoteSaveResult.saved/1` identifiers.

  ```elixir
  case lock_resource(repo, intent.vault_id, intent.resource_id) do
    {:ok, %{deleted_at: nil, current_version_id: base}} when base == intent.base_version_id ->
      persist_canonical_save(repo, intent, next_revision(repo, intent.resource_id))

    {:ok, %{deleted_at: nil}} ->
      persist_competing_save(repo, intent, next_revision(repo, intent.resource_id))

    {:ok, %{deleted_at: %DateTime{}}} ->
      {:error, Error.new(:not_found)}

    {:error, %Error{}} = error ->
      error
  end
  ```

- [ ] **Step 8: Run focused integration checks**

  Run the Step 3 command again.

  Expected: receipt, create, and canonical Save tests pass.

- [ ] **Step 9: Commit**

  ```bash
  git add apps/singularity_storage
  git commit -m "feat(storage): persist canonical note versions"
  ```

### Task 6: Preserve stale saves and merge conflicts atomically

**Files:**

- Modify: `apps/singularity_storage/lib/singularity/storage/postgres/note_repository.ex`
- Create: `apps/singularity_storage/test/singularity/storage/note_mutation_concurrency_test.exs`
- Create: `apps/singularity_storage/test/singularity/storage/note_mutation_rollback_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs`

- [ ] **Step 1: Write failing stale-Save and merge tests**

  Assert a stale Save:

  ```elixir
  assert {:ok,
          %NoteSaveResult{
            outcome: :conflict,
            canonical_version_id: ^accepted_id,
            submitted_version_id: competing_id,
            conflict_id: conflict_id
          }} = scoped(fixture, &NoteRepository.save(&1, stale_intent))

  assert current_head(fixture) == accepted_id
  assert search_version(fixture) == accepted_id
  assert snapshot_parent(fixture, competing_id) == base_id
  assert open_conflict(fixture, conflict_id).competing_version_id == competing_id
  ```

  Merge must create a two-parent snapshot using the then-current head and the
  competing version, resolve only the selected conflict, and advance search.
  A stale expected merge head must return `:conflict` without writes.

- [ ] **Step 2: Write failing race and rollback tests**

  Use two independent scoped connections released by a barrier to Save from the
  same head. Assert exactly one canonical result, one preserved conflict,
  revisions 1 and 2, and no duplicate projection. Add fault injection after
  each of snapshot, head, conflict, projection, audit, outbox, and receipt
  writes; every failure must leave the pre-command database state.

- [ ] **Step 3: Verify RED**

  ```bash
  devenv shell -- mix singularity.test.integration \
    apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs \
    apps/singularity_storage/test/singularity/storage/note_mutation_concurrency_test.exs \
    apps/singularity_storage/test/singularity/storage/note_mutation_rollback_test.exs
  ```

  Expected: stale Save and merge behavior is absent or incomplete.

- [ ] **Step 4: Implement stale Save**

  Reuse the same resource lock and revision allocator as canonical Save. Insert
  the immutable competing version and open conflict with base, observed head,
  and competitor. Do not update resource head/title or search. Emit
  `note.conflict_created`, identifier-only audit, and receipt outcome
  `conflict`.

  ```elixir
  conflict = %{
    id: Ecto.UUID.generate(),
    resource_id: intent.resource_id,
    vault_id: intent.vault_id,
    classification: :private,
    base_version_id: intent.base_version_id,
    canonical_version_id: locked.current_version_id,
    competing_version_id: competing_version_id,
    state: :open
  }
  ```

- [ ] **Step 5: Implement merge**

  Require a live resource, open conflict, matching competitor, and matching
  expected current head. Insert a snapshot with:

  ```elixir
  %{
    parent_version_id: locked_resource.current_version_id,
    merge_parent_version_id: intent.competing_version_id
  }
  ```

  Advance head/title, reconcile search, resolve only the selected conflict with
  the new version/timestamp, emit `note.conflict_resolved` and
  `note.current_changed`, and complete the receipt. Return `:conflict` before
  any insert when the expected head is stale.

- [ ] **Step 6: Make failure injection explicit**

  Accept an internal test-only callback map at named write boundaries, default
  every callback to `fn -> :ok end`, and invoke it inside the same transaction.
  Do not add a production process or environment switch.

  ```elixir
  defp checkpoint(runtime, name) do
    runtime
    |> Map.get(:failure_injector, %{})
    |> Map.get(name, fn -> :ok end)
    |> then(fn callback -> callback.() end)
  end
  ```

- [ ] **Step 7: Run focused integration checks**

  Run the Step 3 command again.

  Expected: all conflict, race, and rollback tests pass.

- [ ] **Step 8: Commit**

  ```bash
  git add apps/singularity_storage
  git commit -m "feat(storage): preserve note conflicts"
  ```

### Task 7: Add note reads, lexical search, Trash, delete, restore, and reconciliation

**Files:**

- Modify: `apps/singularity_storage/lib/singularity/storage/postgres/note_search_store.ex`
- Modify: `apps/singularity_storage/lib/singularity/storage/postgres/note_projection_reconciler.ex`
- Modify: `apps/singularity_storage/lib/singularity/storage/postgres/note_repository.ex`
- Create: `apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs`
- Create: `apps/singularity_storage/test/singularity/storage/postgres/note_projection_reconciler_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/note_mutation_concurrency_test.exs`

- [ ] **Step 1: Write failing read/search tests**

  Cover canonical Get, exact retained version, conflict detail, history cursor,
  empty-query list, ranked search, deterministic keyset pagination, no body
  snippets, and exact canonical version IDs. Rebuild a projection after changing
  its operational `updated_at` and prove order remains based on
  `head_inserted_at`.

- [ ] **Step 2: Write failing lifecycle tests**

  Cover Trash ordering, delete with expected head, stale delete, restore,
  repeated receipt replay, edit/merge while tombstoned, restore while live, and
  Save/delete, merge/delete, restore/delete races. Assert normal Get/search
  return `not_found` for tombstoned notes.

- [ ] **Step 3: Verify RED**

  ```bash
  devenv shell -- mix singularity.test.integration \
    apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs \
    apps/singularity_storage/test/singularity/storage/postgres/note_projection_reconciler_test.exs \
    apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs \
    apps/singularity_storage/test/singularity/storage/note_mutation_concurrency_test.exs
  ```

  Expected: read/search/lifecycle entry points are missing.

- [ ] **Step 4: Implement canonical and exact reads**

  Add repository functions for canonical note, exact typed version, conflict
  detail, history page, and Trash page. Every SQL query includes vault and
  resource identity and runs inside the already-authorized scoped repo. Normal
  reads require `deleted_at IS NULL`; Trash requires `deleted_at IS NOT NULL`.

  ```elixir
  def get(repo, vault_id, resource_id) do
    from(resource in Resource,
      join: version in NoteVersion,
      on: version.resource_version_id == resource.current_version_id,
      where:
        resource.id == ^resource_id and resource.vault_id == ^vault_id and
          is_nil(resource.deleted_at),
      select: %{resource: resource, version: version}
    )
    |> repo.one()
    |> normalize_note_read()
  end
  ```

- [ ] **Step 5: Implement `NoteSearchStore`**

  Use `websearch_to_tsquery('simple', $query)` for non-empty text and recency
  ordering for empty text. Apply vault, `private`, live resource, and
  `resources.current_version_id = projection.resource_version_id` predicates
  before ranking. Order by rank descending, `head_inserted_at` descending, and
  resource ID ascending. Encode bounded opaque cursors with filter identity and
  ordering values only.

  ```sql
  WHERE document.vault_id = $1
    AND document.classification = 'private'
    AND resource.deleted_at IS NULL
    AND resource.current_version_id = document.resource_version_id
    AND ($2 = '' OR document.search_vector @@ websearch_to_tsquery('simple', $2))
  ORDER BY rank DESC, document.head_inserted_at DESC, document.resource_id ASC
  LIMIT $3;
  ```

- [ ] **Step 6: Implement tombstone and restore**

  Tombstone locks a live resource, compares the expected head, sets
  `deleted_at`, reconciles projection deletion, writes events/audit/receipt, and
  creates no content version. Restore requires tombstoned state, clears
  `deleted_at`, reconciles the same head, and creates no content version.

  ```elixir
  defp require_state(%{deleted_at: nil}, :live), do: :ok
  defp require_state(%{deleted_at: %DateTime{}}, :tombstoned), do: :ok
  defp require_state(_resource, _expected), do: {:error, Error.new(:not_found)}
  ```

- [ ] **Step 7: Harden asynchronous reconciliation**

  Make the reconciler accept only vault/resource IDs, re-read canonical state,
  and converge stale events to the current live head or deletion. It must never
  use event title, Markdown, or revision as source data.

  ```elixir
  def reconcile_event(repo, %{"resource_id" => resource_id}, vault_id) do
    ProjectionReconciler.reconcile(repo, %{vault_id: vault_id, resource_id: resource_id})
  end
  ```

  Add `rebuild_vault/2`, which enumerates every note resource in one vault and
  calls the same canonical reconciliation path. Test repeated rebuilds, live
  notes, tombstoned notes, open conflicts, and a deliberately stale projection.

- [ ] **Step 8: Run focused integration checks**

  Run the Step 3 command again.

  Expected: all read, search, Trash, lifecycle, race, and reconciliation tests
  pass.

- [ ] **Step 9: Commit**

  ```bash
  git add apps/singularity_storage
  git commit -m "feat(storage): complete private note lifecycle"
  ```

### Task 8: Add conjunctive authorization and mutation fingerprints

**Files:**

- Create: `apps/singularity_runtime/lib/singularity/runtime/notes/mutation_fingerprint.ex`
- Modify: `apps/singularity_runtime/lib/singularity/runtime/authorize.ex`
- Modify: `apps/singularity_runtime/lib/singularity/runtime/bootstrap_owner.ex`
- Modify: `config/runtime.exs`
- Modify: `config/test.exs`
- Create: `apps/singularity_runtime/test/singularity/runtime/note_mutation_fingerprint_test.exs`
- Modify: `apps/singularity_runtime/test/singularity/runtime/authorization_test.exs`
- Modify: `apps/singularity_runtime/test/singularity/runtime/bootstrap_owner_test.exs`
- Modify: `apps/singularity_runtime/test/singularity/runtime/authentication_timing_test.exs`

- [ ] **Step 1: Write failing all-of authorization tests**

  Assert existing singular requirements are unchanged and plural requirements
  are sorted, unique, non-empty, mutually exclusive with the singular field,
  and require every active capability:

  ```elixir
  requirement = %{
    vault_id: vault_id,
    required_capabilities: ["note.export", "note.read"],
    classification: :private,
    requires_unlocked?: true
  }

  assert :ok = Authorize.check(dependencies_with_both, repo, session, requirement)
  assert {:error, %Error{code: :forbidden}} =
           Authorize.check(dependencies_with_read_only, repo, session, requirement)
  ```

- [ ] **Step 2: Write failing fingerprint/config/bootstrap tests**

  Test each operation's fixed caller-field order, exact repeat digest, one-field
  change, 31/33-byte secrets, malformed/unknown fields, and HMAC output length.
  Add production-config tests for missing, malformed Base64, 31-byte, 33-byte,
  and valid 32-byte `SINGULARITY_MUTATION_FINGERPRINT_SECRET`. Assert new owners
  receive exactly the three note capabilities in addition to existing defaults.

- [ ] **Step 3: Verify RED**

  ```bash
  devenv shell -- mix test \
    apps/singularity_runtime/test/singularity/runtime/note_mutation_fingerprint_test.exs \
    apps/singularity_runtime/test/singularity/runtime/authorization_test.exs \
    apps/singularity_runtime/test/singularity/runtime/bootstrap_owner_test.exs \
    apps/singularity_runtime/test/singularity/runtime/authentication_timing_test.exs
  ```

  Expected: plural authorization and mutation secret support are missing.

- [ ] **Step 4: Implement conjunctive request authorization**

  Normalize requirements with this exclusive shape:

  ```elixir
  defp required_capabilities(requirement) do
    case {Map.fetch(requirement, :required_capability),
          Map.fetch(requirement, :required_capabilities)} do
      {{:ok, capability}, :error} when is_binary(capability) ->
        {:ok, [capability]}

      {:error, {:ok, capabilities}} when is_list(capabilities) ->
        if capabilities != [] and capabilities == Enum.sort(capabilities) and
             capabilities == Enum.uniq(capabilities) and
             Enum.all?(capabilities, &nonblank_capability?/1),
          do: {:ok, capabilities},
          else: {:error, Error.new(:invalid)}

      _invalid ->
        {:error, Error.new(:invalid)}
    end
  end
  ```

  Check every normalized capability. Leave JobEnvelope and all existing
  singular callers unchanged.

- [ ] **Step 5: Implement operation-specific HMAC fingerprints**

  `MutationFingerprint.compute/2` accepts the 32-byte secret and an already
  canonical `%Singularity.Domains.Notes.Command{}`. Encode
  `Command.fingerprint_term/1` with
  `:erlang.term_to_binary(term, [:deterministic])`, and return:

  ```elixir
  :crypto.mac(:hmac, :sha256, secret, encoded)
  ```

  `Command.new/2` must run before this boundary. Include every canonical
  caller-supplied field and exclude server-generated result IDs.

- [ ] **Step 6: Wire fail-closed config and owner defaults**

  Decode the runtime environment value with `Base.decode64/1`, require exactly
  32 bytes, and place the binary only in runtime Notes composition. Add a fixed
  test-only 32-byte value. Extend `@default_capabilities` with `note.read`,
  `note.write`, and `note.export` in sorted deterministic order.

- [ ] **Step 7: Run focused runtime tests**

  Run the Step 3 command again.

  Expected: all authorization, fingerprint, config, and bootstrap tests pass.

- [ ] **Step 8: Commit**

  ```bash
  git add apps/singularity_runtime config
  git commit -m "feat(runtime): authorize private note operations"
  ```

### Task 9: Add strict Notes DTOs, read use cases, and Runtime API

**Files:**

- Create: `apps/singularity_runtime/lib/singularity/runtime/notes/get.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/notes/search.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/notes/trash.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/notes/history.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/notes/export.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/notes/dto.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/dto/note_summary.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/dto/note.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/dto/note_version_summary.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/dto/note_version.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/dto/note_conflict.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/dto/note_conflict_detail.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/dto/note_search_page.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/dto/note_trash_page.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/dto/note_history_page.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/dto/note_save_result.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/dto/note_export.ex`
- Modify: `apps/singularity_runtime/lib/singularity/runtime/api.ex`
- Create: `apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs`
- Create: `apps/singularity_runtime/test/singularity/runtime/note_api_test.exs`

- [ ] **Step 1: Write failing DTO contract tests**

  Test exact field sets, canonical IDs, UTC timestamps, nonnegative revisions,
  `display_version == revision + 1`, canonical/conflict flags, bounded cursors,
  no Markdown in summary pages, exact History/Trash wrappers, Save outcome
  invariants, and conflict detail with current and competing snapshots.
  For `NoteExport`, require the live canonical resource/version IDs, filename
  derived from the current trimmed title plus `.md`, media type
  `text/markdown; charset=utf-8`, and exact stored Markdown bytes.

- [ ] **Step 2: Write failing read/API tests**

  Inject fake scope/repository/retrieval adapters and assert Search/Get/History
  use `note.read`; Trash uses a separate tombstone read; exact-version Get
  returns pinned stale content read-only metadata; Export requires sorted
  `required_capabilities: ["note.export", "note.read"]` and writes an audit
  record without title/Markdown. Assert it pins the current head, returns
  `not_found` for tombstoned notes, and never adds title/frontmatter/version text
  to the Markdown bytes.

  Assert these exact facade functions and test-leading config arities:

  ```elixir
  search_notes(session, params)
  trash_notes(session, params)
  get_note(session, resource_id)
  get_note_version(session, resource_id, version_id)
  get_note_conflict(session, resource_id, conflict_id)
  note_history(session, resource_id, params)
  export_note(session, resource_id)
  ```

- [ ] **Step 3: Verify RED**

  ```bash
  devenv shell -- mix test \
    apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs \
    apps/singularity_runtime/test/singularity/runtime/note_api_test.exs
  ```

  Expected: DTO and Notes API modules are missing.

- [ ] **Step 4: Implement focused DTO modules and mapper**

  Give each DTO an exact `@enforce_keys`, struct, type, and validating
  constructor. Keep structural conversion in `Singularity.Runtime.Notes.DTO` so
  `Runtime.Api` delegates instead of embedding every shape in its existing
  large module.

  ```elixir
  defmodule Singularity.Runtime.DTO.NoteSaveResult do
    @enforce_keys [:outcome, :canonical, :submitted_version_id]
    defstruct @enforce_keys ++ [:conflict_id]
  end

  def save_result(%{outcome: :saved, canonical: canonical, submitted_version_id: id}) do
    with {:ok, canonical} <- note(canonical),
         true <- canonical.resource_version_id == id do
      {:ok,
       %NoteSaveResult{
         outcome: :saved,
         canonical: canonical,
         submitted_version_id: id
       }}
    else
      _invalid -> {:error, Error.new(:integrity_failure)}
    end
  end
  ```

- [ ] **Step 5: Implement read use cases**

  Use `OperationScope.with_read_request/4` for Search, Trash, canonical Get,
  exact version, conflict detail, and History. Bind vault ID server-side and
  require private classification. Export uses `with_shared_request/4` because
  it atomically writes the identifier-only export audit event.

  ```elixir
  def run(runtime, %SessionContext{} = session, params) do
    with {:ok, query} <- bind_query(params, session.vault_id) do
      OperationScope.with_read_request(runtime, session, requirement(session), fn repo ->
        NoteLexicalSearch.search(runtime.note_search_store, repo, query)
      end)
    end
  end
  ```

  `Export.run/3` loads the live canonical note inside that scope and constructs
  all `NoteExport` fields from it. Runtime derives `<title>.md`, replaces
  controls/path separators, and applies the `note.md` fallback. The Web
  controller percent-encodes and defensively rejects header injection without
  changing body bytes.

- [ ] **Step 6: Extend `Runtime.Api` without leaking internal structs**

  Add production and config-leading arities, call the focused use cases, pass
  every success through `Notes.DTO`, and normalize existing stable errors.
  Reject malformed use-case success values as `:integrity_failure`.

  ```elixir
  def search_notes(config, %Session{} = session, params) when is_map(config) do
    with {:ok, context} <- session_context(session),
         {:ok, page} <- invoke(config, :search_notes, [context, params]),
         {:ok, dto} <- NotesDTO.search_page(page) do
      {:ok, dto}
    else
      result -> normalize_error(result)
    end
  end
  ```

- [ ] **Step 7: Run focused runtime tests**

  Run the Step 3 command again.

  Expected: all DTO, read, authorization, export, and API tests pass.

- [ ] **Step 8: Commit**

  ```bash
  git add apps/singularity_runtime
  git commit -m "feat(runtime): expose private note reads"
  ```

### Task 10: Add runtime mutations, projection jobs, observability, and scope guards

**Files:**

- Create: `apps/singularity_runtime/lib/singularity/runtime/notes/create.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/notes/save.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/notes/merge.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/notes/delete.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/notes/restore.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/notes/projection.ex`
- Modify: `apps/singularity_runtime/lib/singularity/runtime/api.ex`
- Modify: `apps/singularity_runtime/lib/singularity/runtime/outbox_dispatcher.ex`
- Modify: `apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex`
- Modify: `apps/singularity_runtime/lib/singularity/runtime/application.ex`
- Modify: `apps/singularity_storage/lib/singularity/storage/jobs/envelope_codec.ex`
- Modify: `apps/singularity_storage/lib/singularity/storage/jobs/oban_adapter.ex`
- Modify: `apps/singularity_runtime/lib/singularity/runtime/observability/redactor.ex`
- Modify: `apps/singularity_runtime/lib/singularity/runtime/observability/telemetry.ex`
- Modify: `config/config.exs`
- Create: `apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs`
- Create: `apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs`
- Create: `apps/singularity_runtime/test/singularity/runtime/note_observability_test.exs`
- Modify: `apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs`
- Create: `apps/singularity_runtime/test/singularity/runtime/job_dispatcher_note_projection_test.exs`
- Modify: `apps/singularity_runtime/test/singularity/runtime/application_test.exs`
- Modify: `apps/singularity_runtime/test/singularity/runtime/job_restart_test.exs`
- Modify: `apps/singularity_runtime/test/singularity/runtime/observability_redaction_test.exs`
- Modify: `apps/singularity_runtime/test/singularity/runtime/telemetry_test.exs`
- Modify: `apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs`
- Create: `apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`

- [ ] **Step 1: Write failing mutation use-case tests**

  Assert Create/Save/Merge/Delete/Restore require unlocked `note.write`, call
  `Domains.Notes.Command.new/2` before computing the fingerprint, enter one
  shared-request scope, preserve Save's `saved | conflict` success, reload the
  current canonical note after every new or replayed mutation result, and map
  stale merge/delete to `:conflict`. Cover malformed repository successes,
  replay of every mutation outcome after a later Save/merge, and cross-vault
  IDs.

  In `note_authorization_integration_test.exs`, create same-vault principals
  with read-only, write-only, export-only, and read-plus-export grants. Exercise
  every public Notes operation, then revoke each grant and advance principal/
  vault authorization epochs to prove live checks deny stale session authority.
  Mark that module `@moduletag :integration` so it runs only through the isolated
  database harness.

- [ ] **Step 2: Write failing outbox/job tests**

  For all five lifecycle event names, assert OutboxDispatcher builds one
  `note_projection` envelope with `note.write`, private classification, and only
  `resource_id` payload. Assert EnvelopeCodec, Oban queue mapping, JobDispatcher,
  and runtime dependencies accept this closed job type. The handler must call
  live `authorize.check_job/3` before
  `NoteProjectionReconciler.reconcile/2`, honor revocation/authorization epochs,
  and ignore event revision/content.

- [ ] **Step 3: Write failing observability and Qdrant-exclusion tests**

  Seed title, Markdown, raw search query, rendered HTML, export bytes, and
  mutation-secret canaries. Assert absence from supported final JSON,
  Singularity telemetry, audit, outbox, receipts, errors, and non-content
  adapter metadata while allowing exact canonical/UI/export paths.

  `notes_scope_contract_test.exs` must scan dependency manifests/lockfiles,
  production code, config, collections, workers, adapters, and supervision
  children for Qdrant while allowing only approved documentation references.

- [ ] **Step 4: Verify RED**

  ```bash
  devenv shell -- mix test \
    apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs \
    apps/singularity_runtime/test/singularity/runtime/note_observability_test.exs \
    apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs \
    apps/singularity_runtime/test/singularity/runtime/job_dispatcher_note_projection_test.exs \
    apps/singularity_runtime/test/singularity/runtime/application_test.exs \
    apps/singularity_runtime/test/singularity/runtime/job_restart_test.exs \
    apps/singularity_runtime/test/singularity/runtime/observability_redaction_test.exs \
    apps/singularity_runtime/test/singularity/runtime/telemetry_test.exs \
    apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs \
    apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs \
    apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs

  devenv shell -- mix singularity.test.integration \
    apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs
  ```

  Expected: mutation use cases, job type, redaction keys, and exclusion guard
  are missing.

- [ ] **Step 5: Implement mutations and API arities**

  Each use case canonicalizes through `Domains.Notes.Command.new/2`, computes
  the exact fingerprint, passes the prepared command and fingerprint to
  `Domains.Notes.execute/3`, and uses a shared request with `note.write`. After
  the repository returns identifier references—including receipt replay—the
  use case reloads the current canonical note inside the same scope and builds
  the hydrated internal result expected by the DTO mapper. Extend
  `Runtime.Api` with:

  ```elixir
  create_note(session, attrs)
  save_note(session, resource_id, attrs)
  merge_note(session, resource_id, attrs)
  delete_note(session, resource_id, attrs)
  restore_note(session, resource_id, attrs)
  ```

  Convert every success through strict Notes DTO mapping.

  ```elixir
  OperationScope.with_shared_request(runtime, session, requirement(session), fn repo ->
    with {:ok, command} <- Command.new(:save, bind_session(attrs, session)),
         {:ok, fingerprint} <- MutationFingerprint.compute(runtime.fingerprint_secret, command),
         {:ok, references} <- Notes.execute(domain_adapters(repo), command, fingerprint),
         {:ok, canonical} <- NoteRepository.get(repo, session.vault_id, references.resource_id) do
      {:ok, Map.put(Map.from_struct(references), :canonical, canonical)}
    end
  end)
  ```

- [ ] **Step 6: Add the closed projection job seam**

  Map all `note.*` lifecycle events to `note_projection`; add queue
  `note_projection: 2`; encode only `%{"resource_id" => uuid}`; and dispatch to
  `Runtime.Notes.Projection.run/2`. Add the repository and reconciler to
  `Application.job_dependencies/0`. The job re-reads canonical state and is
  idempotent.

  ```elixir
  def handle(context, %{job_type: "note_projection"} = envelope),
    do: Singularity.Runtime.Notes.Projection.run(context, envelope)

  def run(context, %{vault_id: vault_id, payload: %{"resource_id" => resource_id}} = envelope) do
    authorize = context.authorize
    authorization = context.authorization
    note_projection = context.note_projection
    transact = context.transact

    transact.([], fn repo ->
      with :ok <- authorize.check_job(authorization, repo, envelope),
           :ok <-
             note_projection.reconcile(repo, %{
               vault_id: vault_id,
               resource_id: resource_id
             }) do
        :ok
      end
    end)
  end
  ```

- [ ] **Step 7: Extend default-deny observability**

  Add sensitive keys for mutation fingerprint secret, title, Markdown, query,
  rendered HTML, and export bytes to both supported redaction boundaries. Do
  not add raw framework subscriptions or new content-bearing metrics.

  ```elixir
  @sensitive_keys ~w[
    mutation_fingerprint_secret note_title markdown raw_search_query
    rendered_html export_bytes
  ]
  ```

- [ ] **Step 8: Implement the Qdrant exclusion guard**

  Make the test inspect active dependency/config/code paths rather than a blind
  repository substring scan. Explicitly exclude `docs/**` and this approved
  plan/spec from active violations. Include `devenv.nix`, `devenv.yaml`,
  `devenv.lock`, any `flake.nix`/`flake.lock`, `.github/workflows/**`, and any
  Dockerfile/Compose/deployment manifest. Assert the inventory contains every
  existing required path so a missing glob cannot silently pass.

  ```elixir
  active_paths = [
    "apps", "config", "mix.exs", "mix.lock", "package.json", "package-lock.json",
    "devenv.nix", "devenv.yaml", "devenv.lock", ".github/workflows"
  ]

  for path <- production_files(active_paths) do
    refute File.read!(path) =~ ~r/qdrant/i, "active Qdrant scope in #{path}"
  end
  ```

- [ ] **Step 9: Run focused runtime and architecture checks**

  Run the Step 4 command again, then:

  ```bash
  devenv shell -- mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  devenv shell -- mix xref graph --format cycles --fail-above 0
  ```

  Expected: all focused tests and architecture gates pass.

- [ ] **Step 10: Commit**

  ```bash
  git add apps/singularity_runtime apps/singularity_storage config apps/singularity_web/test/singularity/architecture
  git commit -m "feat(runtime): orchestrate private note mutations"
  ```

### Task 11: Freeze logical V1 and add the V2 codec and exporter

**Files:**

- Modify: `apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex`
- Create: `apps/singularity_storage/test/fixtures/backup/logical-v1-pre-notes.backup`
- Create: `apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs`
- Create: `apps/singularity_storage/lib/singularity/storage/backup/logical_schema_v2.ex`
- Modify: `apps/singularity_storage/lib/singularity/storage/backup/logical_record_codec.ex`
- Modify: `apps/singularity_storage/lib/singularity/storage/backup/exporter.ex`
- Modify: `apps/singularity_storage/lib/singularity/storage/backup/logical_bundle_verifier.ex`
- Modify: `apps/singularity_storage/priv/repo/migrations/20260818000100_create_private_markdown_notes.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/roles_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/note_schema_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/backup/logical_bundle_verifier_test.exs`

- [ ] **Step 1: Add a guarded one-time V1 capture path before changing the codec**

  In the restore oracle, read `SINGULARITY_CAPTURE_LOGICAL_V1`. When set in
  `MIX_ENV=test`, use the fixed test passphrase
  `singularity-v1-compatibility-passphrase`, run the existing V1 backup and
  restore proof, copy the authenticated bundle to the supplied path before
  cleanup, and print its SHA-256. Refuse capture when:

  ```elixir
  version =
    if function_exported?(LogicalRecordCodec, :default_version, 0),
      do: LogicalRecordCodec.default_version(),
      else: LogicalSchema.version()

  version != 1
  ```

  The capture path is test-only and does not weaken normal task secret inputs.

- [ ] **Step 2: Capture and pin the genuine V1 fixture**

  Run before editing `LogicalRecordCodec`:

  ```bash
  mkdir -p apps/singularity_storage/test/fixtures/backup
  SINGULARITY_CAPTURE_LOGICAL_V1="$PWD/apps/singularity_storage/test/fixtures/backup/logical-v1-pre-notes.backup" \
    devenv shell -- mix singularity.test.restore
  sha256sum apps/singularity_storage/test/fixtures/backup/logical-v1-pre-notes.backup
  ```

  Copy the exact 64-character output into `@fixture_sha256` in the compatibility
  test. The test must read the committed binary, compare the literal hash,
  authenticate with the fixed test passphrase, and assert embedded logical
  version 1. It must never regenerate the file.

- [ ] **Step 3: Run the V1 fixture test before V2 changes**

  ```bash
  devenv shell -- mix test apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs
  ```

  Expected: PASS against the current V1 reader.

- [ ] **Step 4: Write failing V2 schema/codec tests**

  Assert V1 remains 28 tables and 257 columns with unchanged ordinals. Assert
  V2 is 30 tables and 280 columns, retains every V1 table/column ordinal,
  appends `kind` and `current_version_id` to V2 resources, and appends note
  versions/conflicts as table ordinals 28/29.

  Test V2 cut/row/object round trips, version returned from decode, mixed-version
  rejection, unchanged outer bundle version 1, and unchanged manifest version
  1.

  Add integration coverage for the backup-conflict function's exact owner,
  language, volatility, security-definer flag, fixed search path, ACL, live
  authority matrix, deterministic 11-column result, and absence of worker
  direct table access. Assert the V2 exporter uses that function through
  `WorkerRepo` without `SET ROLE`, `MigrationRepo`, or a direct grant.

- [ ] **Step 5: Verify RED for V2**

  ```bash
  devenv shell -- mix test \
    apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/logical_bundle_verifier_test.exs

  devenv shell -- mix singularity.test.integration \
    apps/singularity_storage/test/singularity/storage/roles_test.exs \
    apps/singularity_storage/test/singularity/storage/note_schema_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs
  ```

  Expected: V2 module and version dispatch are missing while the V1 fixture
  remains green.

- [ ] **Step 6: Freeze V1 and define V2 separately**

  Leave `LogicalSchema` definitions and version unchanged. Add
  `LogicalSchemaV2` with existing ordinals/columns copied exactly, two appended
  resource columns, and the two canonical Notes tables. Do not include search
  documents or mutation receipts.

  ```elixir
  defmodule Singularity.Storage.Backup.LogicalSchemaV2 do
    @version 2
    @table_count 30
    @column_count 280

    def version, do: @version
    def count, do: @table_count
    def column_count, do: @column_count
  end
  ```

  The production module also contains the complete 30 definitions described in
  this step; do not reference V1 private module attributes or derive V2 ordinals
  dynamically.

- [ ] **Step 7: Implement multi-version logical records**

  Add:

  ```elixir
  @default_version 2
  def default_version, do: @default_version
  def tables(1), do: LogicalSchema.tables()
  def tables(2), do: LogicalSchemaV2.tables()
  ```

  Encode V2 by default. Decode cut/row/object tuples by their embedded version,
  return `logical_version`, select that version's schema, and reject unknown or
  mixed versions. The V2 object tuple changes only its embedded version.

- [ ] **Step 8: Make exporter and verifier schema-aware**

  Export V2 rows in the approved dependency order and construct the V2 table
  count vector. The verifier selects one schema from the authenticated cut
  before validating row ordinals/counts. Keep BundleWriter/Reader outer format
  and Manifest version unchanged.

  Export `content.note_conflicts` only by calling
  `content.export_note_conflicts_for_backup($1)` through `WorkerRepo`; retain no
  worker table grant and do not use role switching or `MigrationRepo`.

  ```elixir
  with {:ok, schema} <- schema_for(cut.logical_version),
       true <- length(cut.table_count_vector) == schema.count(),
       :ok <- verify_rows(records, schema) do
    {:ok, %{logical_version: cut.logical_version, records: records}}
  else
    _invalid -> {:error, Error.new(:backup_invalid)}
  end
  ```

- [ ] **Step 9: Run focused backup codec tests**

  Run the Step 5 command again.

  Expected: all V1 compatibility and V2 codec/export/verifier tests pass.

- [ ] **Step 10: Commit**

  ```bash
  git add apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex \
    apps/singularity_storage/priv/repo/migrations/20260818000100_create_private_markdown_notes.exs \
    apps/singularity_storage/lib/singularity/storage/backup \
    apps/singularity_storage/test/fixtures/backup \
    apps/singularity_storage/test/singularity/storage/backup \
    apps/singularity_storage/test/singularity/storage/roles_test.exs \
    apps/singularity_storage/test/singularity/storage/note_schema_test.exs
  git commit -m "feat(backup): add logical notes format v2"
  ```

### Task 12: Restore V1/V2 notes, reconcile capabilities, and rebuild projections

**Files:**

- Modify: `apps/singularity_storage/lib/singularity/storage/postgres/note_projection_reconciler.ex`
- Modify: `apps/singularity_storage/lib/singularity/storage/postgres/note_capability_reconciler.ex`
- Modify: `apps/singularity_storage/lib/singularity/storage/backup/restorer.ex`
- Modify: `apps/singularity_storage/lib/singularity/storage/backup/reconciler.ex`
- Modify: `apps/singularity_storage/lib/singularity/storage/backup/integrity_audit.ex`
- Modify: `apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/restore_reconciliation_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs`
- Modify: `apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex`

- [ ] **Step 1: Write failing dual-version restore tests**

  Restore the checked-in V1 bundle into the current physical schema and assert
  resources default to `kind = 'asset'`, no head, no Notes rows/projections/
  receipts/sessions, and the owner receives note capabilities after
  reconciliation.

  Build a V2 bundle containing live, open-conflict, merged, tombstoned, and
  restored notes. Assert exact IDs, Markdown, titles, revisions, parents, head
  pointers, conflicts, deleted state, and export bytes after restore.

- [ ] **Step 2: Write failing reconciliation/integrity tests**

  Assert deferred circular head/parent constraints validate at commit; only
  active non-system principals with active `vault.password_change` receive note
  capabilities; search/receipts/sessions are absent before reconciliation;
  live projections rebuild; tombstoned projections remain absent; and restored
  `note.*` events converge through `note_projection` without interpreting their
  payload as content.

- [ ] **Step 3: Verify RED**

  ```bash
  devenv shell -- mix test \
    apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs \
    apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs

  devenv shell -- mix singularity.test.integration \
    apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs \
    apps/singularity_storage/test/singularity/storage/restore_reconciliation_test.exs \
    apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs
  ```

  Expected: Restorer assumes V1 and does not restore/reconcile Notes.

- [ ] **Step 4: Select one logical schema before import**

  Thread authenticated `logical_version` from the cut through row decoding and
  import. V1 inserts omit appended resource columns so DB defaults apply. V2
  uses the extended resource row and typed Notes tables. Reject mixed/unknown
  versions before any destination commit.

  ```elixir
  defp import_verified(context, verified, cut) do
    with {:ok, schema} <- logical_schema(cut.logical_version),
         :ok <- verify_single_version(verified.records, cut.logical_version),
         {:ok, imported} <- import_rows(context, schema, verified.records) do
      {:ok, imported}
    else
      _invalid -> {:error, Error.new(:backup_invalid)}
    end
  end
  ```

- [ ] **Step 5: Extend relation ordering and exclusion sets**

  Add typed Notes tables to canonical relation import ordering. Keep
  `note_search_documents` and `note_mutation_receipts` excluded alongside
  sessions, stages, grants, jobs, and existing search projections. Defer
  canonical head and parent constraints until the import transaction commits.

- [ ] **Step 6: Reconcile capabilities and projections**

  Invoke the table-owner note-capability reconciliation function after either
  version imports. Then use `NoteProjectionReconciler` to rebuild every live
  canonical row and remove every tombstoned row. Reset restored note lifecycle
  events for idempotent projection redispatch.

  ```elixir
  with :ok <- NoteCapabilityReconciler.reconcile(migration_repo),
       :ok <- NoteProjectionReconciler.rebuild_vault(migration_repo, vault_id),
       :ok <- Singularity.Storage.Backup.Reconciler.reset_note_projection_events(migration_repo, vault_id) do
    :ok
  end
  ```

  Add these concrete modules to the Restorer/Reconciler context maps used by
  production restore, integration tests, and `singularity.test.restore`; do not
  introduce unnamed adapter keys.

- [ ] **Step 7: Extend integrity and restore oracle snapshots**

  IntegrityAudit verifies typed head/parent/classification membership and
  canonical projection identity. Extend `singularity.test.restore` source and
  destination snapshots with note history/conflicts/export bytes and verify a
  V1-restored owner can create/read/export a new note.

- [ ] **Step 8: Run restore gates**

  Run the Step 3 command, then:

  ```bash
  devenv shell -- mix singularity.test.restore
  ```

  Expected: focused restore tests and the full isolated restore oracle pass.

- [ ] **Step 9: Commit**

  ```bash
  git add apps/singularity_storage apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex
  git commit -m "feat(backup): restore private note history"
  ```

### Task 13: Add the Notes LiveView bridge and Markdown export controller

**Files:**

- Create: `apps/singularity_web/lib/singularity/web/live/notes_live.ex`
- Create: `apps/singularity_web/lib/singularity/web/controllers/note_export_controller.ex`
- Modify: `apps/singularity_web/lib/singularity/web/router.ex`
- Modify: `apps/singularity_web/lib/singularity/web/components/layouts/app.html.heex`
- Modify: `apps/singularity_web/test/support/conn_case.ex`
- Create: `apps/singularity_web/test/singularity/web/notes_live_test.exs`
- Create: `apps/singularity_web/test/singularity/web/note_export_controller_test.exs`
- Modify: `apps/singularity_web/test/singularity/web/route_contract_test.exs`
- Modify: `apps/singularity_web/test/singularity/web/live_shell_test.exs`
- Modify: `apps/singularity_web/test/singularity/web/secret_canary_test.exs`

- [ ] **Step 1: Write failing route and disconnected-mount tests**

  Assert `/notes` is authenticated and unlocked, uses `Cache-Control: no-store`,
  mounts one `notes-workspace` App-Clip with version-one summaries/filters and no
  Markdown, and appears in shell navigation. Assert locked/anonymous requests
  follow existing redirects without exposing props.

- [ ] **Step 2: Write failing exact bridge tests**

  Cover exact version-one objects for:

  ```text
  note:search note:trash note:open note:create note:save note:history
  note:conflict note:merge note:delete note:restore navigate
  ```

  The request keys are fixed:

  ```text
  note:search   version q cursor limit
  note:trash    version cursor limit
  note:open     version resourceId resourceVersionId
  note:create   version mutationId title markdown
  note:save     version mutationId resourceId baseVersionId title markdown
  note:history  version resourceId cursor limit
  note:conflict version resourceId conflictId
  note:merge    version mutationId resourceId conflictId
                expectedCurrentVersionId competingVersionId title markdown
  note:delete   version mutationId resourceId expectedCurrentVersionId
  note:restore  version mutationId resourceId
  navigate      version to
  ```

  Every listed key is present. Optional cursor/version values use JSON `null`;
  omitted keys are invalid. `navigate.to` is one of the existing shell paths
  plus `/notes`.

  Reject unknown/missing/duplicate-shape keys, invalid UUIDs/cursors/limits,
  classification input, and payloads over approved limits. Assert only the
  matching `Runtime.Api` function is called and replies have exact DTO keys.

- [ ] **Step 3: Write failing export-controller tests**

  Assert authorization, no-store/nosniff, exact `text/markdown; charset=utf-8`,
  dual safe `Content-Disposition`, exact Markdown body, fallback `note.md`, CRLF
  defense, tombstoned/cross-vault not-found behavior, and no title/Markdown in
  logs/errors.

- [ ] **Step 4: Verify RED**

  ```bash
  devenv shell -- mix test \
    apps/singularity_web/test/singularity/web/notes_live_test.exs \
    apps/singularity_web/test/singularity/web/note_export_controller_test.exs \
    apps/singularity_web/test/singularity/web/route_contract_test.exs \
    apps/singularity_web/test/singularity/web/live_shell_test.exs \
    apps/singularity_web/test/singularity/web/secret_canary_test.exs
  ```

  Expected: Notes routes, LiveView, and controller are absent.

- [ ] **Step 5: Add the private no-store route boundary**

  Add `/notes` under the existing authenticated/unlocked LiveView session and a
  Notes-specific pipeline that sets no-store without changing unrelated pages.
  Add `GET /api/v1/notes/:resource_id/export` under authenticated/unlocked API
  session guards.

  ```elixir
  pipeline :private_no_store do
    plug :put_private_no_store
  end

  scope "/", Singularity.Web do
    pipe_through [:browser, :browser_authenticated, :browser_vault_unlocked, :private_no_store]

    live_session :notes_unlocked,
      on_mount: [{Auth, :require_authenticated}, {Auth, :require_unlocked}] do
      live "/notes", NotesLive
    end
  end

  defp put_private_no_store(conn, _options),
    do: Plug.Conn.put_resp_header(conn, "cache-control", "no-store")

  scope "/api/v1", Singularity.Web do
    pipe_through [:api_session, :api_authenticated, :api_vault_unlocked, :private_no_store]
    get "/notes/:resource_id/export", NoteExportController, :show
  end
  ```

- [ ] **Step 6: Implement `NotesLive` exact decoding**

  Mount summaries only. Implement one private decoder per event, with all keys
  always present and `nil` for optional cursor/version IDs. Call only
  `Auth.call_runtime/2`; normalize public failures to existing stable codes;
  never place title/Markdown in flash or error messages.

  ```elixir
  def handle_event("note:save", params, socket) do
    with {:ok, request} <- save_request(params),
         {:ok, result} <-
           safe_runtime(:save_note, [socket.assigns.current_session, request.resource_id, request]) do
      {:reply, %{ok: true, result: encode_save_result(result)}, socket}
    else
      result -> error_reply(socket, result)
    end
  end
  ```

- [ ] **Step 7: Implement safe export headers**

  Call `Runtime.Api.export_note/2`, sanitize only the filename, percent-encode
  `filename*`, strip controls/path separators, set fallback `note.md`, and send
  the DTO's exact Markdown bytes without rendering or frontmatter.

  ```elixir
  conn
  |> put_resp_content_type("text/markdown", "utf-8")
  |> put_resp_header("cache-control", "no-store")
  |> put_resp_header("x-content-type-options", "nosniff")
  |> put_resp_header("content-disposition", content_disposition(export.filename))
  |> send_resp(200, export.markdown)
  ```

- [ ] **Step 8: Extend test Runtime API and shell**

  Add strict Notes functions and DTO aliases to `ConnCase.TestRuntimeApi`, add
  the Notes nav link, and preserve the existing route and dependency graph.

- [ ] **Step 9: Run focused Web tests**

  Run the Step 4 command again.

  Expected: all Notes route, bridge, controller, shell, and canary tests pass.

- [ ] **Step 10: Commit**

  ```bash
  git add apps/singularity_web
  git commit -m "feat(web): add private notes boundary"
  ```

### Task 14: Add strict App-Clip contracts, state, and mount lifecycle

**Files:**

- Create: `apps/singularity_web/assets/js/notes_workspace/contracts.ts`
- Create: `apps/singularity_web/assets/js/notes_workspace/state.ts`
- Create: `apps/singularity_web/assets/js/clips/mount_notes_workspace.tsx`
- Modify: `apps/singularity_web/assets/js/hooks.js`
- Create: `apps/singularity_web/assets/test/mount_notes_workspace.test.tsx`
- Create: `apps/singularity_web/assets/test/notes_state.test.ts`

- [ ] **Step 1: Write failing exact-decoder tests**

  Define valid fixtures for initial props and every request/reply. Mutate each
  fixture by missing one key, adding one key, wrong version, unsafe number,
  malformed timestamp/UUID, Markdown in summaries, invalid Save outcome, and
  mismatched conflict detail. Every malformed value must decode to the stable
  unavailable/invalid reply without partial state.

- [ ] **Step 2: Write failing store/generation tests**

  Cover separate generation lanes for search, open, history, conflict, and
  mutations. Prove an older reply cannot overwrite a newer lane, a conflict
  Save retains canonical and competing IDs, and terminal auth/expiry clears all
  summaries, drafts, snapshots, history, and conflict sources synchronously.

- [ ] **Step 3: Write failing hook lifecycle tests**

  Assert synchronous root creation, one dynamic workspace import, exact props
  parsing, `pushEvent` reply decoding, handler registration, one unmount, and an
  accessible unavailable alert on any bootstrap failure.

- [ ] **Step 4: Verify RED**

  ```bash
  devenv shell -- mix npm.run test:js \
    apps/singularity_web/assets/test/mount_notes_workspace.test.tsx \
    apps/singularity_web/assets/test/notes_state.test.ts
  ```

  Expected: Notes TypeScript modules do not exist.

- [ ] **Step 5: Implement exact contracts**

  Export concrete TypeScript types and one runtime decoder per DTO. Use
  `hasExactKeys`, safe integer checks, canonical UUID checks, ISO timestamp
  checks, and explicit unions. Define bridge methods matching all LiveView
  events; do not expose a generic untyped `push` method to the workspace.

  ```ts
  export type SaveRequest = {
    version: 1;
    mutationId: string;
    resourceId: string;
    baseVersionId: string;
    title: string;
    markdown: string;
  };

  export type Bridge = {
    save(request: SaveRequest): Promise<SaveReply>;
    merge(request: MergeRequest): Promise<MergeReply>;
    open(request: OpenRequest): Promise<OpenReply>;
  };
  ```

- [ ] **Step 6: Implement the state store**

  Keep canonical snapshots separate from the mutable draft. Actions must carry
  their generation and refuse stale writes. Implement one `purgePrivateState`
  action that returns empty summaries/selection/draft/history/conflicts and is
  used for `vault_locked`, `unauthenticated`, and local expiry. Terminal purge
  advances one epoch checked by every lane so an in-flight completion cannot
  repopulate private state.

  ```ts
  function purgePrivateState(state: WorkspaceState): WorkspaceState {
    return {
      ...state,
      terminalEpoch: state.terminalEpoch + 1,
      generations: {
        search: state.generations.search + 1,
        open: state.generations.open + 1,
        history: state.generations.history + 1,
        conflict: state.generations.conflict + 1,
        mutation: state.generations.mutation + 1,
      },
      notes: [],
      selected: null,
      draft: null,
      history: [],
      conflict: null,
      dirty: false,
    };
  }

  function acceptsReply(state: WorkspaceState, replyEpoch: number): boolean {
    return replyEpoch === state.terminalEpoch;
  }
  ```

- [ ] **Step 7: Implement the mount hook**

  Mirror the proven Asset App-Clip lifecycle but use Notes decoders/store. The
  hook creates the root immediately, dynamically imports `NotesWorkspace`,
  wires typed bridge methods, and unmounts exactly once.

  ```ts
  const root = createRoot(context.el);
  const props = decodeInitialProps(JSON.parse(context.el.dataset.props ?? "null"));
  const { NotesWorkspace } = await loadWorkspace();
  root.render(<NotesWorkspace bridge={bridge(context)} initial={props} />);
  ```

- [ ] **Step 8: Run focused frontend tests and formatter**

  Run the Step 4 command, then:

  ```bash
  devenv shell -- mix duskmoon_bundler.js.check
  ```

  Expected: focused tests and JS/TS checks pass.

- [ ] **Step 9: Commit**

  ```bash
  git add apps/singularity_web/assets
  git commit -m "feat(web): bridge the notes app clip"
  ```

### Task 15: Build the focused Notes workspace and safe Markdown preview

**Files:**

- Modify: `package.json`
- Modify: `package-lock.json`
- Create: `apps/singularity_web/assets/js/notes_workspace/safe_markdown.tsx`
- Create: `apps/singularity_web/assets/js/notes_workspace/NotesWorkspace.tsx`
- Modify: `apps/singularity_web/assets/css/app.css`
- Create: `apps/singularity_web/assets/test/safe_markdown.test.tsx`
- Create: `apps/singularity_web/assets/test/notes_workspace.test.tsx`

- [ ] **Step 1: Add failing safe-renderer tests**

  Test paragraphs, headings, emphasis, strong, lists, blockquotes, inline/fenced
  code, thematic breaks, and safe `http`, `https`, and `mailto` links. Assert raw
  HTML/scripts/event handlers render as inert text; Markdown/HTML images and
  embeds never request a resource; unsafe/relative schemes are inert; and no
  `dangerouslySetInnerHTML` appears in source or rendered output.

- [ ] **Step 2: Add failing workspace behavior tests**

  Cover current rail search, Trash, open, explicit Save, disabled clean Save,
  dirty Stay/Discard dialog, real `beforeunload`, shell LiveView-link capture,
  Preview/History/Conflict drawer exclusivity, stale pinned read-only display,
  merge mode, Save merge, delete/restore, export link, retryable draft retention,
  terminal purge, keyboard flow, focus return, live regions, and narrow panels.

- [ ] **Step 3: Verify RED**

  ```bash
  devenv shell -- mix npm.run test:js \
    apps/singularity_web/assets/test/safe_markdown.test.tsx \
    apps/singularity_web/assets/test/notes_workspace.test.tsx
  ```

  Expected: renderer and workspace modules are missing.

- [ ] **Step 4: Add the Markdown AST dependency**

  Add exact production dependency:

  ```json
  "react-markdown": "10.1.0"
  ```

  Then update the lock through the approved toolchain:

  ```bash
  devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install
  devenv shell -- mix npm.verify
  ```

- [ ] **Step 5: Implement `SafeMarkdown` without raw HTML injection**

  Use `react-markdown` without `rehypeRaw`. Add a local remark transformer that
  recursively changes mdast `html` nodes to `text` nodes, an explicit allowed
  element list, an `img` override that returns inert alt text, and a URL
  transform allowing only `http:`, `https:`, and `mailto:`. External links use
  `target="_blank" rel="noopener noreferrer"`.

  ```tsx
  export function SafeMarkdown({ markdown }: { markdown: string }) {
    return (
      <ReactMarkdown
        remarkPlugins={[inertRawHtml]}
        allowedElements={allowedElements}
        urlTransform={safeUrl}
        components={{ img: InertImage, a: SafeLink }}
      >
        {markdown}
      </ReactMarkdown>
    );
  }
  ```

- [ ] **Step 6: Implement the focused split workspace**

  Build a compact rail, primary title/Markdown canvas, and collapsed-by-default
  mutually exclusive drawer. Keep draft/base version local; Save only on user
  action; generate a fresh mutation UUID per distinct command; enter conflict
  and merge modes from exact DTOs; and use ordinary same-origin export links.

  ```tsx
  return (
    <main className="notes-workspace">
      <NotesRail state={state} bridge={bridge} />
      <NoteEditor state={state} dispatch={dispatch} bridge={bridge} />
      {state.drawer !== "closed" && <NotesDrawer state={state} bridge={bridge} />}
    </main>
  );
  ```

- [ ] **Step 7: Protect all dirty navigation**

  Add `beforeunload` only for document exits. Add a capturing document click
  listener while dirty that recognizes same-origin shell navigation anchors,
  prevents LiveView navigation, and opens the accessible Stay/Discard dialog.
  Discard resumes the exact target through the typed `navigate` bridge.

  ```ts
  function interceptDirtyNavigation(event: MouseEvent): void {
    const anchor = (event.target as Element | null)?.closest("a[href]");
    if (!dirty || !anchor || !sameOriginShellPath(anchor.getAttribute("href"))) return;
    event.preventDefault();
    setPendingNavigation(anchor.getAttribute("href"));
  }
  ```

- [ ] **Step 8: Add responsive, themed, accessible CSS**

  Reuse existing `--dm-*` tokens. At wide widths show rail/editor with optional
  drawer; at narrow widths expose rail/drawer as named panels rather than hiding
  their functions. Preserve 3:1 control boundaries, 4.5:1 text, visible focus,
  44px touch targets, reduced motion, and current light/dark themes.

- [ ] **Step 9: Run focused frontend and production asset checks**

  Run the Step 3 command, then:

  ```bash
  devenv shell -- mix duskmoon_bundler.js.check
  devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind
  ```

  Expected: focused tests, formatting/lint, and production asset build pass.

- [ ] **Step 10: Commit**

  ```bash
  git add package.json package-lock.json apps/singularity_web/assets
  git commit -m "feat(web): build the private notes workspace"
  ```

### Task 16: Prove the complete browser and restore acceptance flow

**Files:**

- Modify: `apps/singularity_runtime/lib/mix/tasks/singularity.test.browser.ex`
- Create: `apps/singularity_runtime/lib/mix/tasks/singularity.test.browser_restore.ex`
- Modify: `apps/singularity_runtime/test/mix/tasks/singularity.test.browser_test.exs`
- Modify: `mix.exs`
- Modify: `test/e2e/support/fixtures.ts`
- Create: `test/e2e/notes_workspace.spec.ts`
- Create: `test/e2e/notes_accessibility.spec.ts`
- Modify: `playwright.config.ts`
- Modify: `package.json`
- Modify: `package-lock.json`

- [ ] **Step 1: Write failing browser-harness tests**

  Assert the browser task bootstraps two deterministic owners/vaults with note
  capabilities, uses domain-separated passwords, writes a mode-0600 state file
  named by `SINGULARITY_BROWSER_STATE_FILE`, records only backup-root and public
  fixture coordinates, and removes it during bounded cleanup.

  Add parser/cleanup tests for `singularity.test.browser_restore`: test-only
  environment, canonical source path, passphrase FD, expected snapshot path,
  isolated destination allocation/drop, no web listener, and secret-safe errors.
  Assert root `preferred_cli_env` maps `singularity.test.browser_restore` to
  `:test`.

- [ ] **Step 2: Extend Playwright support with Node APIs**

  Add exact dev dependency:

  ```json
  "@types/node": "26.2.0"
  ```

  Set `SINGULARITY_BROWSER_STATE_FILE` in `playwright.config.ts` to a unique
  temp path derived from the run ID. Extend fixtures with primary/secondary
  login helpers, state-file loading, and a bounded `spawnSync` wrapper that sends
  the backup passphrase only through child stdin (`--passphrase-fd 0`).

- [ ] **Step 3: Implement the second-vault browser fixture**

  Extend owner-password derivation with exact domains:

  ```text
  singularity-browser-test-owner-password:v1:primary:
  singularity-browser-test-owner-password:v1:secondary:
  ```

  Use deterministic distinct logins:

  ```text
  owner@singularity.local
  secondary-owner@singularity.local
  ```

  Bootstrap both owners, keep their credentials and vault IDs distinct, grant
  note capabilities, and expose no password in the state file or server output.

  ```elixir
  def derive_owner_password(run_id, role) when role in [:primary, :secondary] do
    domain = "singularity-browser-test-owner-password:v1:#{role}:"
    digest = :crypto.hash(:sha256, domain <> run_id)
    "singularity-test-" <> Base.url_encode64(digest, padding: false)
  end
  ```

- [ ] **Step 4: Implement the isolated browser-backup restore task**

  The task authenticates the browser-created encrypted bundle from the supplied
  path, creates a fresh destination through `TestEnvironment`, restores under
  maintenance mode with descriptor-supplied passphrase, runs integrity and
  projection reconciliation, compares exact note IDs/Markdown/revisions/parents/
  conflicts/tombstone/export expectations from the supplied JSON, prints only
  `notes_browser_restore_ok=true`, and always drops the destination.

  The expected-snapshot JSON contains private Markdown. Create it as an owned
  mode-0600 file, never attach it to Playwright reports or stdout/stderr, and
  delete it in `finally` on success, assertion failure, timeout, or child-process
  failure. Add a Markdown canary proving cleanup and output absence.

  ```elixir
  def run(arguments) do
    with {:ok, request} <- parse(arguments),
         {:ok, passphrase} <- read_descriptor_once(request.passphrase_fd),
         {:ok, restored} <- restore_into_isolated_destination(request.source, passphrase),
         :ok <- compare_expected(restored, request.expected_snapshot) do
      Mix.shell().info("notes_browser_restore_ok=true")
    else
      _failure -> Mix.raise("notes browser restore failed")
    end
  end
  ```

  Add `"singularity.test.browser_restore": :test` to the root
  `preferred_cli_env` list.

- [ ] **Step 5: Write the complete Notes workflow test**

  In one primary browser context:

  1. Create revision zero and assert Version 1.
  2. Save a canonical edit and search its exact version.
  3. Use a second primary-login browser context to Save from the old base.
  4. Assert canonical and competing snapshots plus open conflict.
  5. Merge and assert the two-parent canonical result.
  6. Export and compare exact bytes and headers.
  7. Tombstone, prove normal read/search absence, open Trash, and restore.
  8. Create an encrypted backup through the existing Backups UI and wait for
     sealed status.
  9. Write the expected note snapshot JSON and invoke the isolated restore task
     against the single bundle in the state-file backup root.
  10. Assert the restore task's exact success marker.
  11. Load the note again, issue a same-origin CSRF-protected `DELETE /logout`,
      trigger a Notes bridge operation, and prove synchronous React purge plus
      redirect to authentication or Unlock.
  12. Prove direct `/notes` and export requests after lock/logout cannot expose
      the target IDs, count, title, version, or Markdown in DOM, bridge traffic,
      headers, or response bodies.

  In a secondary-owner context, prove the target vault's note IDs, counts,
  titles, versions, and content never appear.

- [ ] **Step 6: Write responsive and accessibility acceptance**

  Test keyboard-only create/edit/Save/drawer/merge/Trash flows, focus trapping
  and return, accessible names and live status, dirty navigation dialog, 390px
  and desktop layouts, reduced motion, light/dark themes, no horizontal page
  overflow, and axe results for each workspace state.

- [ ] **Step 7: Verify RED, then implement the harness**

  First run:

  ```bash
  devenv shell -- mix test apps/singularity_runtime/test/mix/tasks/singularity.test.browser_test.exs
  devenv shell -- mix npm.run test:e2e \
    test/e2e/notes_workspace.spec.ts \
    test/e2e/notes_accessibility.spec.ts
  ```

  Expected before implementation: harness and browser tests fail for missing
  second-vault/restore support. Implement Steps 3-4, then rerun until both pass.

- [ ] **Step 8: Run the complete scoped finish gate**

  ```bash
  devenv shell -- mix deps.unlock --check-unused
  devenv shell -- mix format --check-formatted
  devenv shell -- mix compile --warnings-as-errors

  devenv shell -- mix test \
    apps/singularity_core/test/singularity/core/note_values_test.exs \
    apps/singularity_core/test/singularity/core/ports_test.exs \
    apps/singularity_domains/test/singularity/domains/notes_test.exs \
    apps/singularity_retrieval/test/singularity/retrieval/note_lexical_search_test.exs \
    apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs \
    apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs \
    apps/singularity_runtime/test/singularity/runtime/note_api_test.exs \
    apps/singularity_runtime/test/singularity/runtime/note_mutation_fingerprint_test.exs \
    apps/singularity_runtime/test/singularity/runtime/note_observability_test.exs \
    apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs \
    apps/singularity_runtime/test/singularity/runtime/job_dispatcher_note_projection_test.exs \
    apps/singularity_runtime/test/singularity/runtime/application_test.exs \
    apps/singularity_runtime/test/singularity/runtime/job_restart_test.exs \
    apps/singularity_runtime/test/singularity/runtime/authorization_test.exs \
    apps/singularity_runtime/test/singularity/runtime/bootstrap_owner_test.exs \
    apps/singularity_runtime/test/singularity/runtime/authentication_timing_test.exs \
    apps/singularity_runtime/test/singularity/runtime/observability_redaction_test.exs \
    apps/singularity_runtime/test/singularity/runtime/telemetry_test.exs \
    apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs \
    apps/singularity_runtime/test/mix/tasks/singularity.test.browser_test.exs \
    apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/logical_bundle_verifier_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs \
    apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs \
    apps/singularity_web/test/singularity/web/notes_live_test.exs \
    apps/singularity_web/test/singularity/web/note_export_controller_test.exs \
    apps/singularity_web/test/singularity/web/route_contract_test.exs \
    apps/singularity_web/test/singularity/web/live_shell_test.exs \
    apps/singularity_web/test/singularity/web/secret_canary_test.exs \
    apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs \
    apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs

  devenv shell -- mix singularity.test.integration \
    apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs \
    apps/singularity_storage/test/singularity/storage/note_schema_test.exs \
    apps/singularity_storage/test/singularity/storage/note_rls_test.exs \
    apps/singularity_storage/test/singularity/storage/migrations_test.exs \
    apps/singularity_storage/test/singularity/storage/roles_test.exs \
    apps/singularity_storage/test/singularity/storage/classification_inheritance_test.exs \
    apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs \
    apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs \
    apps/singularity_storage/test/singularity/storage/note_mutation_concurrency_test.exs \
    apps/singularity_storage/test/singularity/storage/note_mutation_rollback_test.exs \
    apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs \
    apps/singularity_storage/test/singularity/storage/postgres/note_projection_reconciler_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs \
    apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs \
    apps/singularity_storage/test/singularity/storage/restore_reconciliation_test.exs \
    apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs

  devenv shell -- mix singularity.test.restore

  devenv shell -- mix npm.verify
  devenv shell -- mix npm.run test:js \
    apps/singularity_web/assets/test/mount_notes_workspace.test.tsx \
    apps/singularity_web/assets/test/notes_state.test.ts \
    apps/singularity_web/assets/test/safe_markdown.test.tsx \
    apps/singularity_web/assets/test/notes_workspace.test.tsx
  devenv shell -- mix duskmoon_bundler.js.check
  devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind
  devenv shell -- mix npm.run test:e2e \
    test/e2e/notes_workspace.spec.ts \
    test/e2e/notes_accessibility.spec.ts

  devenv shell -- mix xref graph --format cycles --fail-above 0
  git diff --check
  git status --short --branch
  ```

  Expected: every scoped check passes; no Qdrant active scope appears; worktree
  contains only the intended cumulative branch changes.

- [ ] **Step 9: Commit the acceptance harness**

  ```bash
  git add apps/singularity_runtime/lib/mix/tasks \
    apps/singularity_runtime/test/mix/tasks \
    test/e2e playwright.config.ts package.json package-lock.json mix.exs
  git commit -m "test(notes): prove private notes acceptance"
  ```

- [ ] **Step 10: Stop at the approved boundary**

  Run:

  ```bash
  devenv down
  ```

  Stop when the Task 16 finish gate passes. Report any unrelated failure without
  fixing it. Do not begin attachments, PDF extraction, citations, Qdrant, or
  another Milestone 2 slice.
