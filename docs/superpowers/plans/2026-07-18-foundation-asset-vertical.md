# Singularity Foundation and Asset Vertical Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Use test-driven development for every behavior change and
verification-before-completion before reporting a gate complete.

**Goal:** Replace the obsolete PRD-001 knowledge-core scaffold with the
approved seven-application foundation and deliver one complete, encrypted,
vault-scoped asset vertical: owner bootstrap, login and unlock, upload,
verification, finalization, technical metadata, PostgreSQL metadata search,
download, logical deletion, cleanup, encrypted backup, restore, audit, and the
Vault Workbench UI.

**Architecture:** Pure invariants and ports live in `singularity_core`; typed
Identity, Vault, and Assets contexts live in `singularity_domains`;
PostgreSQL, RLS, envelope encryption, local object storage, Oban, and backup
adapters live in `singularity_storage`; deterministic file inspection lives in
`singularity_ingest`; metadata-search orchestration lives in
`singularity_retrieval`; `singularity_runtime` wires adapters and owns use
cases, jobs, and session-bound key custody; `singularity_web` depends only on
runtime and owns Phoenix plus the React `AssetWorkspace` App-Clip.

**Tech stack:** Elixir 1.18.4, Erlang/OTP 28, Phoenix 1.8, LiveView, Ecto SQL,
Postgrex, PostgreSQL 17, Oban, Argon2id, OTP `:crypto` AES-256-GCM,
DuskmoonBundler profile `:singularity_web`, React, TypeScript, Vitest,
Playwright/Chromium, ExUnit, and StreamData.

**Authority:** The approved design at
`docs/superpowers/specs/2026-07-18-foundation-asset-vertical-design.md`
interprets `docs/guide.md` for this branch. If this plan appears to conflict
with the design, stop and resolve the design first rather than silently
changing an invariant.

---

## Scope guard

Implement the approved first complete asset vertical on one cumulative branch.
This is the local-storage portion of guide Milestone 1 plus the foundation
needed to prove it.

Do not add:

- CouchDB or compatibility code for the removed CouchDB design;
- embedded ESS until `gsmlg-opt/ex_storage_service#5` is published;
- S3, remote object storage, or multi-node storage coordination;
- Qdrant or embeddings; Qdrant remains required for semantic search in
  Milestone 8, not this branch;
- Backplane, external model calls, RAG, OCR, PDF body text, page counts, EXIF,
  thumbnails, captions, or media transcoding;
- password recovery, key escrow, a hidden administrator bypass, or `BYPASSRLS`;
- a Phoenix-to-storage shortcut or a direct web dependency on core/domains;
- public stubs that defer required behavior instead of implementing it;
- plaintext backup intermediates or whole-file upload buffering.

The local adapter is an approved temporary workaround. Its selection callsite
must contain exactly:

```elixir
# WORKAROUND(upstream): gsmlg-opt/ex_storage_service#5
```

If a new bug or missing feature appears in a dependency owned by an
organization listed in `AGENTS.md`, follow the upstream issue-routing policy.
Do not open a second issue for the already tracked ESS packaging request.

Only fix failures inside this plan. If an unrelated or later-milestone test
fails, record it and stop instead of broadening the branch.

## Fixed dependency graph

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

The architecture test must inspect only dependencies marked
`in_umbrella: true`, because external Hex dependencies are allowed. It must
also scan web production code and reject references to
`Singularity.Core`, `Singularity.Domains`, `Singularity.Storage`,
`Singularity.Ingest`, and `Singularity.Retrieval`.

## Fixed external dependencies

Keep dependencies in the application that owns their use:

```text
singularity_core:
  stream_data ~> 1.3                         # test only

singularity_storage:
  ecto_sql ~> 3.14
  postgrex ~> 0.22.3
  oban ~> 2.23
  argon2_elixir ~> 4.1
  telemetry ~> 1.4

singularity_runtime:
  logger_json ~> 7.0
  telemetry_metrics ~> 1.1
  telemetry_poller ~> 1.3

singularity_web:
  phoenix ~> 1.8
  phoenix_html ~> 4.1
  phoenix_live_view ~> 1.2
  bandit ~> 1.12
  duskmoon_bundler_runtime ~> 9.9.7       # runtime in every environment
  duskmoon_bundler ~> 9.9.7               # available all envs; OTP app dev/test
  floki >= 0.36.0                         # test only
  lazy_html >= 0.1.0                      # unrestricted environment scope
```

The DuskmoonBundler runtime package starts in every environment. The bundler
package itself remains available in every environment, but its OTP application
starts only in `:dev` and `:test`. LazyHTML deliberately has no `only`
restriction because DuskmoonBundler 9.9.7 declares it for every environment,
and Mix requires the direct dependency to use the same scope.

Use Elixir 1.18's `JSON` module for job and event payloads. Do not add Jason,
Cloak, or another cryptography abstraction. Use OTP `:crypto` for encryption,
HMAC, randomness, digesting, and constant-time comparison.

## Cross-cutting implementation rules

1. Every state-changing task starts with a failing focused test.
2. Core IDs remain opaque strings; Ecto adapters may generate `Ecto.UUID`
   values.
3. Domain code receives adapters explicitly and never selects infrastructure.
4. Ecto schemas use IDs across contexts rather than Ecto associations.
5. Every user-owned row carries `vault_id` directly or through a
   vault-aware composite constraint.
6. Lifecycle and classification columns are text with SQL checks, not
   PostgreSQL enums.
7. Every mutation and worker holds the shared vault advisory lock across its
   filesystem effect and database acknowledgement.
8. Public errors are stable domain errors and never expose Ecto, Oban,
   filesystem paths, key material, credential validity, or cross-vault
   existence.
9. Commits are conventional, scoped to one gate, and contain no AI trailers.
10. Do not begin the next task until the current task's focused checks pass.

## File structure

The final production tree is organized by one responsibility per file:

```text
apps/
├── singularity_core/
│   └── lib/singularity/core/
│       ├── *.ex                         # pure values and invariants
│       └── {object_storage,outbox,job_runner,job_handler,...}.ex
├── singularity_domains/
│   └── lib/singularity/domains/
│       ├── identity/                    # identity persistence contract
│       ├── vaults/                      # vault persistence contract
│       └── assets/                      # asset persistence contract
├── singularity_storage/
│   ├── lib/singularity/storage/
│   │   ├── schema/                      # one Ecto schema per table
│   │   ├── postgres/                    # domain/RLS adapters
│   │   ├── crypto/                      # KDF, wrappers, chunked AEAD
│   │   ├── local/                       # guarded local filesystem
│   │   ├── jobs/                        # Oban runner and worker
│   │   └── backup/                      # encrypted bundle and restore
│   └── priv/repo/                       # role bootstrap and migrations
├── singularity_ingest/
│   └── lib/singularity/ingest/          # upload primitives and parsers
├── singularity_retrieval/
│   └── lib/singularity/retrieval/       # metadata-query orchestration
├── singularity_runtime/
│   └── lib/singularity/runtime/
│       ├── assets/                      # asset use cases
│       ├── dto/                         # web-safe values
│       └── observability/               # redaction and telemetry
└── singularity_web/
    ├── lib/singularity/web/             # Phoenix boundary
    └── assets/
        ├── js/asset_workspace/          # React App-Clip
        └── css/app.css                  # semantic workbench theme

config/                                  # shared compile/runtime config
test/e2e/                                # Chromium acceptance workflow
```

Tasks below enumerate every created, modified, and deleted file.

## Verification commands used at every gate

Run from the implementation worktree inside one persistent `devenv shell`.
For non-interactive automation, prefix each command with `devenv shell --`.
Entering the shell does not start managed services: database gates must first
run `devenv up -d` and `devenv processes wait --timeout 120`, and must run
`devenv down` in their cleanup path. From Task 6 onward, a fresh environment
must then execute `bootstrap_roles.sql` through the local task-only provisioner
URL before a verifier, migration, integration, restore, or browser gate.

The common commands are:

```bash
mix deps.get
mix deps.unlock --check-unused
mix format --check-formatted
mix compile --warnings-as-errors
mix test <focused paths for the task>
mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
mix xref graph --format cycles --fail-above 0
git diff --check
```

Database/storage/job tasks additionally run:

```bash
devenv shell -- mix singularity.test.integration
```

Backup/restore tasks additionally run:

```bash
devenv shell -- mix singularity.test.restore
```

Web/toolchain tasks additionally run:

```bash
# TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
# WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
mix npm.verify
mix duskmoon_bundler.js.check
mix npm.run test:js
mix duskmoon_bundler.build singularity_web --tailwind
devenv shell -- mix npm.run test:e2e
```

---

## Task 1: Create the one implementation branch and capture the baseline

**Files:**

- Verify: `.gitignore`
- Verify:
  `docs/superpowers/specs/2026-07-18-foundation-asset-vertical-design.md`
- Verify:
  `docs/superpowers/plans/2026-07-18-foundation-asset-vertical.md`

- [ ] **Step 1: Confirm the approved documents and clean root checkout**

  Run:

  ```bash
  git status --short --branch
  git log -2 --oneline
  git diff --check
  grep -qxF '/.trees/' .gitignore
  ```

  Expected: `main` contains the approved design and this plan, has no pending
  files, and `.trees/` is ignored.

- [ ] **Step 2: Create the required project-local worktree**

  Run:

  ```bash
  git worktree add .trees/foundation-asset-vertical \
    -b codex/foundation-asset-vertical main
  cd .trees/foundation-asset-vertical
  git status --short --branch
  ```

  Expected: the new checkout is on
  `codex/foundation-asset-vertical`, clean, and located under `.trees/`.

- [ ] **Step 3: Prove the pre-change baseline**

  Run:

  ```bash
  devenv shell -- mix format --check-formatted
  devenv shell -- mix compile --warnings-as-errors
  devenv shell -- mix test
  devenv shell -- mix xref graph --format cycles --fail-above 0
  ```

  Expected baseline: formatting and compilation pass, all existing 41 tests
  pass, and no dependency cycle is reported. If the baseline differs, record
  the exact result before editing.

There is no commit for this task.

## Task 2: Replace the obsolete five-app topology with the seven-app boundary

**Files:**

- Modify: `README.md`
- Create: `docs/adr/0001-postgresql-is-canonical.md`
- Create: `docs/adr/0002-local-storage-until-embedded-ess.md`
- Modify:
  `apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs`
- Create: `apps/singularity_domains/mix.exs`
- Create: `apps/singularity_domains/lib/singularity/domains.ex`
- Create: `apps/singularity_domains/test/test_helper.exs`
- Create: `apps/singularity_storage/mix.exs`
- Create: `apps/singularity_storage/lib/singularity/storage.ex`
- Create: `apps/singularity_storage/test/test_helper.exs`
- Create: `apps/singularity_ingest/mix.exs`
- Create: `apps/singularity_ingest/lib/singularity/ingest.ex`
- Create: `apps/singularity_ingest/test/test_helper.exs`
- Modify: `apps/singularity_retrieval/mix.exs`
- Modify: `apps/singularity_retrieval/lib/singularity/retrieval.ex`
- Modify: `apps/singularity_runtime/mix.exs`
- Modify: `apps/singularity_runtime/lib/singularity/runtime.ex`
- Modify: `apps/singularity_web/mix.exs`
- Modify: `apps/singularity_web/lib/singularity/web.ex`
- Delete: `apps/singularity_store/**`

- [ ] **Step 1: Rewrite the architecture test first**

  Make the test enumerate `apps/*/mix.exs`, assert the exact seven app names,
  select only `in_umbrella: true` dependencies, and compare each app with the
  fixed allow-list above. Add a second assertion that scans
  `apps/singularity_web/lib/**/*.{ex,exs,heex}` and rejects direct forbidden
  module references.

  The allow-list in the test is:

  ```elixir
  @expected %{
    singularity_core: [],
    singularity_domains: [:singularity_core],
    singularity_storage: [:singularity_core, :singularity_domains],
    singularity_ingest: [:singularity_core, :singularity_domains],
    singularity_retrieval: [:singularity_core, :singularity_domains],
    singularity_runtime: [
      :singularity_core,
      :singularity_domains,
      :singularity_ingest,
      :singularity_retrieval,
      :singularity_storage
    ],
    singularity_web: [:singularity_runtime]
  }

  @forbidden_web_modules ~w[
    Singularity.Core
    Singularity.Domains
    Singularity.Storage
    Singularity.Ingest
    Singularity.Retrieval
  ]
  ```

  Run:

  ```bash
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  ```

  Expected: failure listing the missing `domains`, `storage`, and `ingest`
  applications and the obsolete `store` application.

- [ ] **Step 2: Create only the minimal application skeletons**

  Add the three new Mix children without supervisors. Update the existing
  Mix dependencies to exactly match the fixed graph. Remove
  `singularity_store`; do not copy its old API into `singularity_storage`.

  Use these exact dependency bodies:

  ```elixir
  # singularity_domains
  defp deps, do: [{:singularity_core, in_umbrella: true}]

  # singularity_storage, singularity_ingest, singularity_retrieval
  defp internal_deps do
    [
      {:singularity_core, in_umbrella: true},
      {:singularity_domains, in_umbrella: true}
    ]
  end

  # singularity_runtime
  defp deps do
    [
      {:singularity_core, in_umbrella: true},
      {:singularity_storage, in_umbrella: true},
      {:singularity_domains, in_umbrella: true},
      {:singularity_ingest, in_umbrella: true},
      {:singularity_retrieval, in_umbrella: true}
    ]
  end

  # singularity_web
  defp deps, do: [{:singularity_runtime, in_umbrella: true}]
  ```

  Run:

  ```bash
  mix format
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  ```

  Expected: exact graph test and cycle check pass.

- [ ] **Step 3: Record the clean-break decisions**

  `README.md` must describe the seven apps, PostgreSQL as canonical,
  encrypted local storage as the temporary adapter, Qdrant as a Milestone 8
  dependency, and the standard development commands. The ADRs must state why
  CouchDB is removed and why the local adapter is temporary, with
  `gsmlg-opt/ex_storage_service#5` linked as `needed`.

  Both ADRs use this literal decision shape:

  ```markdown
  # ADR 000N: <decision>

  Status: Accepted
  Date: 2026-07-18

  ## Context
  <the superseded design and current constraint>

  ## Decision
  <the approved PostgreSQL or local-adapter decision>

  ## Consequences
  <the exact migration boundary and out-of-scope items>
  ```

- [ ] **Step 4: Run the gate and commit**

  Run:

  ```bash
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add README.md docs/adr apps
  git commit -m "refactor: establish seven-app architecture"
  ```

  Expected: one topology/documentation commit with no old `singularity_store`
  path.

## Task 3: Add reproducible PostgreSQL and dependency configuration

**Files:**

- Modify: `.formatter.exs`
- Modify: `.github/workflows/ci.yml`
- Modify: `config/config.exs`
- Create: `config/dev.exs`
- Create: `config/test.exs`
- Create: `config/runtime.exs`
- Modify: `devenv.nix`
- Modify: `.github/workflows/ci.yml`
- Modify: `devenv.yaml`
- Modify: `devenv.lock`
- Modify: `apps/singularity_core/mix.exs`
- Modify: `apps/singularity_storage/mix.exs`
- Modify: `apps/singularity_runtime/mix.exs`
- Create:
  `apps/singularity_storage/test/singularity/storage/configuration_test.exs`
- Create: `mix.lock`

- [ ] **Step 1: Add a configuration-contract test**

  Create
  `apps/singularity_storage/test/singularity/storage/configuration_test.exs`
  asserting:

  - test mode has five distinct database URLs;
  - the storage root is under a generated test directory;
  - upload limit defaults to `536_870_912`;
  - maximum concurrent uploads default to `2` and RequestRepo pool size is at
    least `10`;
  - production refuses an absent `SINGULARITY_STORAGE_ROOT`;
  - Oban's prefix is `jobs`;
  - no configured repo uses a superuser or a migration URL at runtime;
  - `SINGULARITY_ROLE_PROVISIONER_DATABASE_URL` is absent from application
    configuration and no provisioner repo exists.

  The focused assertions begin with:

  ```elixir
  test "runtime pools and migration pool are distinct" do
    runtime_urls =
      for repo <- [
            Singularity.Storage.RequestRepo,
            Singularity.Storage.PreAuthRepo,
            Singularity.Storage.DispatcherRepo,
            Singularity.Storage.WorkerRepo
          ] do
        Application.fetch_env!(:singularity_storage, repo) |> Keyword.fetch!(:url)
      end

    migration_url =
      Application.fetch_env!(:singularity_storage, Singularity.Storage.MigrationRepo)
      |> Keyword.fetch!(:url)

    assert length(Enum.uniq(runtime_urls)) == 4
    refute migration_url in runtime_urls
    assert Application.fetch_env!(:singularity_runtime, :max_upload_bytes) == 536_870_912
    assert Application.fetch_env!(:singularity_runtime, :max_concurrent_uploads) == 2
    assert Application.fetch_env!(
             :singularity_storage,
             Singularity.Storage.RequestRepo
           )[:pool_size] >= 10
    assert Application.fetch_env!(:singularity_storage, Oban)[:prefix] == "jobs"
  end
  ```

  `config/test.exs` derives non-connecting test URLs and the temporary storage
  path from `SINGULARITY_TEST_RUN_ID`. The focused contract runs with the
  literal `config_contract` run ID; the later integration task replaces it
  with a random collision-resistant ID before any repo starts.

  Run:

  ```bash
  SINGULARITY_TEST_RUN_ID=config_contract \
    mix test apps/singularity_storage/test/singularity/storage/configuration_test.exs
  ```

  Expected: failure because no storage configuration or dependencies exist.

- [ ] **Step 2: Add dependencies in their owning apps**

  Add the fixed Hex dependencies from this plan, including test-only
  StreamData. Configure Phoenix's JSON library globally as `JSON`, but do not
  add Phoenix dependencies yet. Fetch and lock:

  ```elixir
  # singularity_core/mix.exs
  {:stream_data, "~> 1.3", only: :test}

  # singularity_storage/mix.exs
  {:ecto_sql, "~> 3.14"}
  {:postgrex, "~> 0.22.3"}
  {:oban, "~> 2.23"}
  {:argon2_elixir, "~> 4.1"}
  {:telemetry, "~> 1.4"}

  # singularity_runtime/mix.exs
  {:logger_json, "~> 7.0"}
  {:telemetry_metrics, "~> 1.1"}
  {:telemetry_poller, "~> 1.3"}
  ```

  ```bash
  mix deps.get
  mix deps.unlock --check-unused
  ```

  Expected: `mix.lock` is created and no dependency is available solely
  through an accidental transitive declaration.

- [ ] **Step 3: Configure development, test, and runtime environments**

  Define these independent URLs:

  ```text
  SINGULARITY_MIGRATION_DATABASE_URL
  SINGULARITY_DATABASE_URL
  SINGULARITY_PRE_AUTH_DATABASE_URL
  SINGULARITY_DISPATCHER_DATABASE_URL
  SINGULARITY_WORKER_DATABASE_URL
  ```

  Development may use explicit least-privilege local defaults after the role
  bootstrap task exists. Test configuration must consume unique database names
  supplied by the integration task. Production configuration must fetch all
  URLs and `SINGULARITY_STORAGE_ROOT`; it must not fall back to development
  credentials.

  The shared configuration contract is:

  ```elixir
  config :phoenix, :json_library, JSON

  config :singularity_runtime,
    max_upload_bytes: 536_870_912,
    max_concurrent_uploads: 2,
    vault_idle_timeout_ms: :timer.minutes(15)

  config :singularity_storage, Singularity.Storage.RequestRepo,
    pool_size: 10

  config :singularity_storage, Oban,
    name: Singularity.Oban,
    repo: Singularity.Storage.WorkerRepo,
    prefix: "jobs",
    queues: [
      asset_finalize: 2,
      asset_verify: 2,
      asset_metadata: 2,
      asset_cleanup: 1,
      object_cleanup: 1,
      backup: 1,
      maintenance: 1
    ]

  import_config "#{config_env()}.exs"
  ```

  `runtime.exs` fetches each production value with `System.fetch_env!/1`; the
  test config receives all generated paths from the integration task.
  `SINGULARITY_MAX_CONCURRENT_UPLOADS`, when set, must parse to a positive
  integer smaller than the configured RequestRepo pool.

- [ ] **Step 4: Add PostgreSQL 17 and browser-capable tooling to devenv**

  Enable the PostgreSQL 17 service and add Node, npm, and Chromium packages
  needed by later gates. Set the browser executable path for Playwright and
  `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`; do not run
  `npx playwright install`. Regenerate `devenv.lock` with the repository's
  pinned `release-26.05` input.

  The devenv shape is:

  ```nix
  packages = with pkgs-stable; [
    git
    beam28Packages.elixir-ls
    nodejs_24
    chromium
  ];

  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_17;
  };

  env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH =
    "${pkgs-stable.chromium}/bin/chromium";
  ```

  Run:

  ```bash
  devenv update
  devenv up -d
  trap 'devenv down' EXIT
  devenv processes wait --timeout 120
  devenv shell -- psql --version
  devenv shell -- node --version
  devenv shell -- chromium --version
  ```

  Expected: PostgreSQL reports major 17, and Node plus Chromium resolve from
  devenv.

- [ ] **Step 5: Make CI enter the same environment**

  Update CI to start PostgreSQL and run the existing Elixir checks from the
  pinned environment. Do not enable integration, restore, or browser commands
  before their tasks exist.

  Preserve least privileges:

  ```yaml
  permissions:
    contents: read

  steps:
    - uses: actions/checkout@v4
    - uses: cachix/install-nix-action@v31
    - uses: cachix/cachix-action@v16
      with:
        name: devenv
    - name: Install devenv
      shell: bash
      run: nix profile add nixpkgs#devenv
    - run: devenv up -d
    - run: devenv processes wait --timeout 120
    - run: devenv shell -- mix deps.get
    - run: devenv shell -- mix format --check-formatted
    - run: devenv shell -- mix compile --warnings-as-errors
    - run: devenv shell -- mix test
    - run: devenv shell -- mix xref graph --format cycles --fail-above 0
    - if: always()
      run: devenv down
  ```

- [ ] **Step 6: Run the focused gate and commit**

  Run:

  ```bash
  devenv shell -- mix deps.get
  devenv shell -- mix deps.unlock --check-unused
  devenv shell -- mix format --check-formatted
  devenv shell -- mix compile --warnings-as-errors
  devenv shell -- env SINGULARITY_TEST_RUN_ID=config_contract \
    mix test apps/singularity_storage/test/singularity/storage/configuration_test.exs
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add .formatter.exs .github config devenv.nix devenv.yaml devenv.lock \
    apps/singularity_core/mix.exs apps/singularity_storage/mix.exs \
    apps/singularity_runtime/mix.exs \
    apps/singularity_storage/test/singularity/storage/configuration_test.exs \
    mix.lock
  git commit -m "build: add PostgreSQL foundation"
  ```

## Task 4: Rebuild core values, invariants, and ports

**Files:**

- Retain and rewrite:
  `apps/singularity_core/lib/singularity/core.ex`
- Retain and rewrite:
  `apps/singularity_core/lib/singularity/core/{types,schema_version,error}.ex`
- Delete:
  `apps/singularity_core/lib/singularity/core/{answer_run,blob_ref,blob_store,block,citation,collection_spec,embedder,embedding,embedding_input,generation_event,generation_evidence,generation_request,generation_result,generator,knowledge_chunk,knowledge_item,knowledge_revision,knowledge_store,projection_state,retrieval,source,stored,vector_match,vector_point,vector_store}.ex`
- Delete: `apps/singularity_core/test/support/fake/**`
- Delete: `apps/singularity_core/test/support/contracts/{blob_store_contract,embedder_contract,generator_contract,knowledge_store_contract,vector_store_contract}.ex`
- Delete: `apps/singularity_core/test/singularity/core/{behaviours_test,domain_types_test}.exs`
- Delete:
  `apps/singularity_retrieval/test/singularity/retrieval/fake_contract_test.exs`
- Delete:
  `apps/singularity_runtime/test/singularity/runtime/fake_backplane_contract_test.exs`
- Create:
  `apps/singularity_core/lib/singularity/core/{person,account,principal,device,session,vault,classification,capability,resource,resource_version,asset,asset_state,source_reference,audit_event,outbox_event,stage_ref,object_ref,job_envelope}.ex`
- Create:
  `apps/singularity_core/lib/singularity/core/{object_storage,outbox,job_runner,job_handler,password_hasher,key_deriver,key_wrapper,audit_sink,asset_search_store,clock,id_generator}.ex`
- Create:
  `apps/singularity_core/test/singularity/core/{identity_values,vault_values,resource_values,asset_state,job_envelope,error}_test.exs`
- Create:
  `apps/singularity_core/test/singularity/core/invariant_properties_test.exs`
- Create:
  `apps/singularity_core/test/support/contracts/object_storage_contract.ex`

- [ ] **Step 1: Write lifecycle and privilege-invariant tests**

  Assert the authoritative state transitions:

  ```text
  staging -> uploaded -> verified -> available -> processing -> ready
  staging|uploaded|verified|available|processing|ready -> pending_delete
  pending_delete -> deleted
  ```

  Every transition increments `state_revision`; stale expected revisions fail
  with `conflict`. Failure metadata is orthogonal and cannot create a
  `failed` lifecycle state. Classification constructors may preserve or
  strengthen `private`, never weaken it.

  Use StreamData properties for opaque IDs, non-negative revisions,
  idempotency-key normalization, capability containment, and invalid
  transition rejection.

  The table-driven test uses:

  ```elixir
  @valid [
    {:staging, :uploaded},
    {:uploaded, :verified},
    {:verified, :available},
    {:available, :processing},
    {:processing, :ready},
    {:staging, :pending_delete},
    {:uploaded, :pending_delete},
    {:verified, :pending_delete},
    {:available, :pending_delete},
    {:processing, :pending_delete},
    {:ready, :pending_delete},
    {:pending_delete, :deleted}
  ]

  for {from, to} <- @valid do
    test "#{from} transitions to #{to}" do
      asset = asset(state: unquote(from), state_revision: 7)
      assert {:ok, %{state: unquote(to), state_revision: 8}} =
               AssetState.transition(asset, unquote(to), 7)
    end
  end
  ```

  Run:

  ```bash
  mix test apps/singularity_core/test/singularity/core/asset_state_test.exs
  mix test apps/singularity_core/test/singularity/core/invariant_properties_test.exs
  ```

  Expected: failures because the replacement types do not exist.

- [ ] **Step 2: Implement the smallest pure value layer**

  Use validated structs and pure constructors. Times are UTC `DateTime`;
  identifiers and opaque cursors are strings; extension metadata uses
  string-keyed maps. `AssetState.transition/3` is the only transition table.
  Add the stable errors:

  ```text
  unauthenticated, vault_locked, forbidden, not_found, conflict, invalid,
  upload_expired, upload_too_large, unsupported_media_type,
  integrity_failure, storage_unavailable, job_failed, backup_invalid
  ```

  The sole transition implementation has this shape:

  ```elixir
  @transitions %{
    staging: [:uploaded, :pending_delete],
    uploaded: [:verified, :pending_delete],
    verified: [:available, :pending_delete],
    available: [:processing, :pending_delete],
    processing: [:ready, :pending_delete],
    ready: [:pending_delete],
    pending_delete: [:deleted],
    deleted: []
  }

  def transition(%Asset{state_revision: actual}, _to, expected)
      when actual != expected,
      do: {:error, Error.new(:conflict)}

  def transition(%Asset{state: from} = asset, to, expected) do
    if to in Map.fetch!(@transitions, from) do
      {:ok, %{asset | state: to, state_revision: expected + 1}}
    else
      {:error, Error.new(:invalid)}
    end
  end
  ```

  Classification ordering is also fixed:

  ```elixir
  @rank %{private: 0, sensitive: 1, restricted: 2}

  def assert_not_downgraded(source, derived) do
    if Map.fetch!(@rank, derived) >= Map.fetch!(@rank, source),
      do: :ok,
      else: {:error, Error.new(:forbidden)}
  end
  ```

- [ ] **Step 3: Write port-contract tests**

  Assert callback signatures for:

  - `ObjectStorage`: stage, append encrypted chunk, seal, stage stat,
    finalize, abort, object stat/open/read range/verify/delete, list staged;
  - `Outbox`: append and claim/acknowledge with stable identities;
  - `JobRunner` and `JobHandler`: versioned envelopes and injected handling;
  - password hashing, raw key derivation, key wrapping, audit, clock, IDs,
    and metadata search.

  `JobEnvelope` must carry every field from design section 8 and reject an
  absent principal, vault, capability, classification, authorization epoch,
  revision, correlation ID, or string-keyed payload.

  Pin the public envelope fields:

  ```elixir
  @required_fields ~w[
    version job_id job_type idempotency_key vault_id principal_id
    required_capability authorization_epoch classification correlation_id
    causation_id expected_entity_revision attempt payload
  ]a

  test "job envelope rejects non-string payload keys" do
    assert {:error, %{code: :invalid}} =
             JobEnvelope.new(valid_envelope(payload: %{asset_id: "asset-1"}))
  end
  ```

- [ ] **Step 4: Implement behaviours without infrastructure**

  Each effect callback receives explicit adapter context as its first
  argument; `JobHandler.dependencies/0` is the composition-only exception.
  Keep `ObjectStorageContract` parameterized so the local adapter now and
  embedded ESS/S3 later can run the same assertions. Do not add a process,
  filesystem call, Ecto schema, or adapter selection to core.

  `JobHandler` also defines `dependencies/0` for the runtime composition
  bundle and `handle/2` for the per-attempt context. Storage treats the
  dependency map as opaque; its fake handler provides a literal map for
  contract tests:

  ```elixir
  @callback dependencies() :: map()
  @callback handle(map(), JobEnvelope.t()) ::
              :ok | {:ok, term()} | {:error, Error.t()} | {:snooze, pos_integer()}
  ```

  The object port is explicit:

  ```elixir
  @callback stage(context(), map()) :: {:ok, StageRef.t()} | {:error, Error.t()}
  @callback append_encrypted_chunk(context(), StageRef.t(), iodata()) ::
              :ok | {:error, Error.t()}
  @callback seal_stage(context(), StageRef.t(), map()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback stat_stage(context(), StageRef.t()) :: {:ok, map()} | {:error, Error.t()}
  @callback finalize(context(), StageRef.t(), ObjectRef.t()) ::
              {:ok, ObjectRef.t()} | {:error, Error.t()}
  @callback abort_stage(context(), StageRef.t()) :: :ok | {:error, Error.t()}
  @callback stat(context(), ObjectRef.t()) :: {:ok, map()} | {:error, Error.t()}
  @callback open(context(), ObjectRef.t()) :: {:ok, term()} | {:error, Error.t()}
  @callback read_range(context(), term(), Range.t()) ::
              {:ok, binary()} | {:error, Error.t()}
  @callback verify(context(), ObjectRef.t()) :: :ok | {:error, Error.t()}
  @callback delete(context(), ObjectRef.t()) :: :ok | {:error, Error.t()}
  @callback list_staged(context()) :: {:ok, [StageRef.t()]} | {:error, Error.t()}
  ```

- [ ] **Step 5: Run the core gate and commit**

  Run:

  ```bash
  mix format
  mix test apps/singularity_core/test
  mix compile --warnings-as-errors
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add apps/singularity_core
  git commit -m "feat(core): define foundation domain contracts"
  ```

## Task 5: Implement pure Identity, Vault, and Assets contexts

**Files:**

- Create:
  `apps/singularity_domains/lib/singularity/domains/identity.ex`
- Create:
  `apps/singularity_domains/lib/singularity/domains/identity/repository.ex`
- Create:
  `apps/singularity_domains/lib/singularity/domains/vaults.ex`
- Create:
  `apps/singularity_domains/lib/singularity/domains/vaults/repository.ex`
- Create:
  `apps/singularity_domains/lib/singularity/domains/assets.ex`
- Create:
  `apps/singularity_domains/lib/singularity/domains/assets/repository.ex`
- Create:
  `apps/singularity_domains/test/support/fake/{identity_repository,vault_repository,asset_repository,audit_sink,outbox}.ex`
- Create:
  `apps/singularity_domains/test/singularity/domains/{identity,vaults,assets}_test.exs`

- [ ] **Step 1: Write context tests against isolated fakes**

  Cover:

  - idempotent owner aggregate construction without credential replacement;
  - vault membership and capability checks at an authorization epoch;
  - locked-vault rejection before sensitive asset work;
  - upload intent creation with `private` classification and provenance;
  - transition plus audit plus outbox as one repository operation;
  - stale job revision as a successful no-op;
  - deletion creating a tombstone before release work;
  - classification inheritance across resource version, asset, event, and
    audit target.

  The transaction assertion is:

  ```elixir
  assert {:ok, %{asset: %{state: :uploaded}, outbox: outbox, audit: audit}} =
           Assets.record_sealed_upload(repositories, command)

  assert outbox.event_type == "asset.verify_requested"
  assert outbox.vault_id == command.vault_id
  assert audit.operation == "asset.uploaded"
  assert audit.classification == :private
  ```

  Run:

  ```bash
  mix test apps/singularity_domains/test/singularity/domains
  ```

  Expected: failure because the contexts and repository contracts do not
  exist.

- [ ] **Step 2: Define domain-facing repository contracts**

  Keep persistence operations intent-oriented, for example owner bootstrap,
  resolve authorization, create upload intent, consume a grant, record a
  sealed stage, apply an expected-revision transition, release a reference,
  and append the matching audit/outbox values. Do not expose Ecto queries or
  filesystem paths.

  The asset repository contract is:

  ```elixir
  @callback create_upload_intent(context(), map()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback consume_upload_grant(context(), map()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback record_sealed_stage(context(), map()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback transition(context(), map()) ::
              {:ok, :applied | :stale, Asset.t()} | {:error, Error.t()}
  @callback tombstone_and_release(context(), map()) ::
              {:ok, map()} | {:error, Error.t()}
  ```

- [ ] **Step 3: Implement the contexts as pure orchestration**

  `Identity`, `Vaults`, and `Assets` validate inputs, evaluate capability and
  classification rules, build core values, and call the injected repository.
  They do not choose PostgreSQL, local storage, Oban, or a runtime process.

  Context entrypoints accept an explicit adapter bundle:

  ```elixir
  @spec record_sealed_upload(
          %{repository: module(), context: term(), audit: module(), outbox: module()},
          map()
        ) :: {:ok, map()} | {:error, Error.t()}
  def record_sealed_upload(adapters, command) do
    with :ok <- validate_upload(command),
         :ok <- Classification.assert_not_downgraded(:private, command.classification) do
      adapters.repository.record_sealed_stage(adapters.context, command)
    end
  end
  ```

- [ ] **Step 4: Run the context gate and commit**

  Run:

  ```bash
  mix format
  mix test apps/singularity_domains/test
  mix test apps/singularity_core/test
  mix compile --warnings-as-errors
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add apps/singularity_domains
  git commit -m "feat(domains): add identity vault and asset contexts"
  ```

## Task 6: Create least-privilege PostgreSQL roles, schemas, RLS, and test isolation

**Files:**

- Create:
  `apps/singularity_storage/lib/singularity/storage/{migration_repo,request_repo,pre_auth_repo,dispatcher_repo,worker_repo,scoped_repo,vault_lock,authorization_lock}.ex`
- Create:
  `apps/singularity_storage/priv/repo/bootstrap_roles.sql`
- Create:
  `apps/singularity_storage/priv/repo/bootstrap_roles.sh`
- Create:
  `apps/singularity_storage/priv/repo/migrations/20260718000100_create_schemas.exs`
- Create:
  `apps/singularity_storage/priv/repo/migrations/20260718000200_create_identity_and_vault_tables.exs`
- Create:
  `apps/singularity_storage/priv/repo/migrations/20260718000300_create_content_asset_tables.exs`
- Create:
  `apps/singularity_storage/priv/repo/migrations/20260718000400_create_outbox_and_jobs.exs`
- Create:
  `apps/singularity_storage/priv/repo/migrations/20260718000500_create_audit_and_backup_tables.exs`
- Create:
  `apps/singularity_storage/priv/repo/migrations/20260718000600_create_security_functions_rls_and_grants.exs`
- Create:
  `apps/singularity_storage/priv/repo/migrations/20260718000700_create_asset_search_projection.exs`
- Create:
  `apps/singularity_storage/lib/mix/tasks/singularity.db.verify_roles.ex`
- Create:
  `apps/singularity_storage/lib/mix/tasks/singularity.test.integration.ex`
- Create:
  `apps/singularity_storage/lib/singularity/storage/role_verifier.ex`
- Modify: `devenv.nix`
- Modify: `mix.exs`
- Create:
  `apps/singularity_storage/lib/singularity/storage/test_environment.ex`
- Create:
  `apps/singularity_storage/test/support/{data_case,fixtures,failure_injector}.ex`
- Create:
  `apps/singularity_storage/test/singularity/storage/{migrations,roles,rls,pre_auth,scoped_repo,vault_lock,authorization_lock}_test.exs`
- Modify: `apps/*/test/test_helper.exs`

- [ ] **Step 1: Build the isolated integration runner first**

  `mix singularity.test.integration` must:

  1. refuse a non-test environment or a database name without its generated
     random suffix;
  2. verify the externally provisioned cluster roles and exact memberships;
  3. print its temporary database name and storage root;
  4. create the database through `MigrationRepo`, migrate all schemas, and
     run only `:integration` tests;
  5. drop the database and storage root in an `after` path.

  Real PostgreSQL/Oban tests use `@moduletag :integration`. Every child test
  helper starts ExUnit with:

  ```elixir
  ExUnit.start(exclude: [:integration])
  ```

  The task entrypoint owns cleanup:

  ```elixir
  def run(args) do
    Mix.Task.run("app.config")
    assert_test_environment!()
    Singularity.Storage.RoleVerifier.verify!()
    names = Singularity.Storage.TestEnvironment.allocate!()
    Mix.shell().info("database=#{names.database} storage_root=#{names.storage_root}")

    try do
      Singularity.Storage.TestEnvironment.create!(names)
      Mix.Task.run("test", ["--only", "integration" | args])
    after
      Singularity.Storage.TestEnvironment.drop!(names)
    end
  end
  ```

  Add the task's preferred environment at the umbrella root:

  ```elixir
  preferred_cli_env: [
    "singularity.test.integration": :test
  ]
  ```

  Run:

  ```bash
  devenv shell -- mix singularity.test.integration
  ```

  Expected: failure before any database is created because the task and repos
  do not exist.

- [ ] **Step 2: Create distinct repos and the role bootstrap**

  Create:

  - a no-login table owner;
  - separate no-login authentication, authorization, and outbox
    function-owner roles;
  - migration, pre-auth, request/web, dispatcher, and worker login roles.

  Cluster-role creation is external to Ecto and `MigrationRepo`.
  `bootstrap_roles.sql` must be executed by an environment provisioner that
  is actually a PostgreSQL superuser. It idempotently creates or normalizes
  every no-login owner/definer role, the task-only migration login, and the
  least-privilege runtime logins. `singularity_migration` is
  `LOGIN CREATEDB NOCREATEROLE NOINHERIT NOSUPERUSER NOBYPASSRLS`; it can
  create isolated test databases and perform database-local DDL but cannot
  create or administer cluster roles.

  For development and CI, `devenv.nix` exposes a local provisioner URL only
  inside the development shell. After PostgreSQL reports ready, the database
  gate and CI run:

  ```bash
  devenv shell -- bash \
    apps/singularity_storage/priv/repo/bootstrap_roles.sh
  ```

  That URL exists only in the local `devenv` shell environment and connects
  as the managed local PostgreSQL superuser. It is never read by
  `config/*.exs`, placed in application environment, logged, or available to
  a supervised repo. In production, the database platform provisioner or IaC
  runs the same reviewed role contract out of band before migrations and
  supplies login credentials separately; Singularity never receives the
  provisioner credential.

  The shell wrapper expands the provisioner URL only after entering
  `devenv`, refuses a missing value, invokes `psql` with
  `ON_ERROR_STOP=1`, never enables shell tracing, and never prints the URL.
  It executes only the checked adjacent SQL file. The SQL's first block
  verifies `pg_roles.rolsuper` for `SESSION_USER` and aborts before any DDL
  otherwise. Update the existing CI workflow to invoke this wrapper
  immediately after
  `devenv processes wait`; later workflow tasks must retain that step.

  The provisioner grants the task-only
  `singularity_migration` role `SET TRUE, INHERIT FALSE, ADMIN FALSE`
  membership in the table-owner and each no-login function-owner role. No
  runtime role receives those memberships:

  ```sql
  GRANT
    singularity_table_owner,
    singularity_auth_definer,
    singularity_authorization_definer,
    singularity_outbox_definer
  TO singularity_migration WITH SET TRUE;

  GRANT
    singularity_table_owner,
    singularity_auth_definer,
    singularity_authorization_definer,
    singularity_outbox_definer
  TO singularity_migration WITH INHERIT FALSE;

  GRANT
    singularity_table_owner,
    singularity_auth_definer,
    singularity_authorization_definer,
    singularity_outbox_definer
  TO singularity_migration WITH ADMIN FALSE;
  ```

  Because these statements run as the external superuser, PostgreSQL does not
  leave an unchangeable automatic `ADMIN TRUE` grant from a non-superuser role
  creator. `bootstrap_roles.sql` queries `pg_auth_members` after normalization
  and fails unless each final membership has exactly `SET TRUE`,
  `INHERIT FALSE`, and `ADMIN FALSE`.

  Migrations explicitly `SET LOCAL ROLE` to the owner needed for each DDL
  statement. A table owner grants a function-owner temporary `CREATE` on its
  schema; the migration sets the function-owner role and creates or replaces
  the function so ownership is correct at creation time; then the table owner
  revokes `CREATE`. Function owners retain only schema `USAGE` and their exact
  table/column privileges. `MigrationRepo` is the only component with the
  migration credential and is never supervised.

  `mix singularity.db.verify_roles` is read-only. It checks role attributes,
  grantor-independent final membership options, absence of runtime-role owner
  memberships, and the migration role's ability to `SET LOCAL ROLE` without
  inheriting owner privileges. It never creates, alters, grants, or revokes a
  cluster role. The integration runner calls this verifier before creating its
  temporary database and stops with the external provisioning command when
  verification fails.

  Runtime roles have no ownership and no `BYPASSRLS`.
  `ScopedRepo.transact/3` and its option-bearing
  `transact/4` must begin a
  transaction on the supplied repo, assert both context GUCs are initially
  absent (`NULL` or PostgreSQL's empty custom-GUC reset sentinel), set
  principal and vault using parameterized
  `set_config(..., true)`, run on the same connection, and prove the values
  return to that absent form after commit or rollback. Any nonempty
  pre-existing value fails checkout.

  The scoped transaction must use the caller's process-bound repo handle,
  which represents its already checked-out connection:

  ```elixir
  def transact(repo, context, fun), do: transact(repo, context, [], fun)

  def transact(
        repo,
        %{principal_id: principal_id, vault_id: vault_id},
        transaction_options,
        fun
      ) do
    case repo.transaction(
           fn ->
             assert_context_absent!(repo)

             Ecto.Adapters.SQL.query!(
               repo,
               "SELECT set_config('singularity.principal_id', $1, true), " <>
                 "set_config('singularity.vault_id', $2, true)",
               [principal_id, vault_id]
             )

             case fun.(repo) do
               {:error, reason} -> repo.rollback(reason)
               success -> success
             end
           end,
           transaction_options
         ) do
      {:ok, success} -> success
      {:error, reason} -> {:error, reason}
    end
  end
  ```

  Thus transaction callbacks use the domain result vocabulary directly:
  `:ok`, `{:ok, value}`, or `{:error, reason}`. `ScopedRepo` rolls back errors
  and removes only Ecto's outer transaction tuple; it never returns nested
  success/error tuples.

- [ ] **Step 3: Write migration and constraint tests**

  Assert the exact logical schemas:

  ```text
  identity, core, content, jobs, audit
  ```

  Assert tables for identity, vault/capabilities/keys/outbox,
  resources/versions/assets/stages/objects/envelopes/metadata/search/provenance/
  tombstones/grants, Oban/submission/progress/effect receipts, and
  audit/backup inventory. Assert composite vault-aware foreign keys,
  lifecycle/classification checks, immutable audit triggers, and Oban's
  `jobs` prefix.

- [ ] **Step 4: Add pre-auth and RLS tests before the policies**

  With two vault fixtures, prove:

  - missing or empty-reset either GUC fails closed without a UUID-cast error;
  - request and worker roles cannot read, mutate, search, count, or infer the
    other vault;
  - checked-in connections retain no context;
  - pre-auth cannot select identity tables;
  - all three pre-auth functions succeed without principal/vault GUCs for
    their permitted candidate, session, and attempt operations;
  - `authentication_candidate`, `resolve_session`, and
    `record_auth_attempt` return fixed minimal shapes;
  - unknown and known-login failure responses are indistinguishable;
  - direct execution by `PUBLIC` is revoked;
  - the request/worker policy can call
    `core.principal_is_authorized/2` for an active membership without RLS
    recursion or `42P17`, and returns false for a missing/revoked membership;
  - the authorization-definer role has `SELECT` only on the exact live
    membership table, cannot log in or `SET ROLE` from a runtime role, and
    does not match the ordinary request/worker policy;
  - the migration role is `NOCREATEROLE`, cannot create/alter/grant cluster
    roles, and has only SET-without-inheritance membership in owner roles;
  - direct calls to `core.principal_is_authorized/2` with a principal or
    vault different from the current transaction GUCs return false and cannot
    act as a membership oracle;
  - live membership is evaluated by policy, while the stale authorization
    epoch is rejected by the explicit use-time `Authorize` check in Task 11.

  Run:

  ```bash
  devenv shell -- mix singularity.test.integration
  ```

  Expected: focused failures identifying absent tables, functions, grants,
  and policies.

- [ ] **Step 5: Implement migrations and security functions**

  Use `Oban.Migrations.up(prefix: "jobs")`. Security-definer functions have a
  fixed `search_path`, validate parameters, expose minimum columns, and write
  audit context. `identity.record_auth_attempt(..., "started")` atomically
  reserves/checks login and source buckets before Argon2 work; a second call
  records a uniform anonymous failure. Successful session issuance records
  its principal audit event inside the scoped session transaction instead.
  Enable and force RLS on every user-data table.

  `VaultLock.with_shared/3` and `with_exclusive/3` use session advisory locks
  inside `Repo.checkout/2`. Ecto invokes checkout callbacks at arity zero; the
  helper deliberately passes the repo module back to its own callback as the
  process-bound checked-out-repo handle. All operations on that handle in the
  same process use the pinned connection. The handle must never cross into a
  `Task` or another process. The helper always unlocks in `after`:

  ```elixir
  def with_shared(repo, vault_id, callback) do
    repo.checkout(fn ->
      :ok = acquire_shared(repo, vault_id)

      try do
        callback.(repo)
      after
        release_shared(repo, vault_id)
      end
    end)
  end
  ```

  `AuthorizationLock` accepts that checked-out repo handle, never performs a
  nested checkout, and uses a separate deterministic advisory-lock namespace
  keyed by principal plus vault. Protected operations take it shared after the
  vault lock and hold it through their final effect acknowledgement. Session
  revocation, membership/capability changes, and authorization-epoch changes
  take it exclusive in the same lock order. Task 11 adds the custody-first
  revocation gate before these database locks. Tests prove the two database
  orderings serialize: an already-linearized non-plaintext operation may
  finish before revocation commits, while a revocation linearized first makes
  the operation fail live authorization before any effect.

  `core.principal_is_authorized/2` is a fixed-search-path
  `SECURITY DEFINER` function owned by the no-login,
  no-`BYPASSRLS` `singularity_authorization_definer` role. It reads only
  `core.vault_members`, whose active row is the canonical principal/vault
  authorization fact. That role receives `SELECT` on only the columns needed
  from that table and a role-specific non-recursive policy:

  ```sql
  SET LOCAL ROLE singularity_table_owner;

  CREATE POLICY authorization_definer_reads_membership
    ON core.vault_members
    FOR SELECT
    TO singularity_authorization_definer
    USING (true);

  GRANT USAGE, CREATE ON SCHEMA core
    TO singularity_authorization_definer;
  GRANT SELECT (principal_id, vault_id, revoked_at)
    ON core.vault_members
    TO singularity_authorization_definer;

  SET LOCAL ROLE NONE;
  SET LOCAL ROLE singularity_authorization_definer;

  CREATE OR REPLACE FUNCTION core.principal_is_authorized(
    requested_principal uuid,
    requested_vault uuid
  ) RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = pg_catalog, core
  AS $$
    SELECT COALESCE(
      requested_principal =
          NULLIF(
            current_setting('singularity.principal_id', true),
            ''
          )::uuid
        AND requested_vault =
          NULLIF(
            current_setting('singularity.vault_id', true),
            ''
          )::uuid
        AND EXISTS (
          SELECT 1
          FROM core.vault_members AS membership
          WHERE membership.principal_id = requested_principal
            AND membership.vault_id = requested_vault
            AND membership.revoked_at IS NULL
        ),
      false
    )
  $$;

  REVOKE ALL ON FUNCTION core.principal_is_authorized(uuid, uuid)
    FROM PUBLIC;
  GRANT EXECUTE ON FUNCTION core.principal_is_authorized(uuid, uuid)
    TO singularity_web, singularity_worker;

  SET LOCAL ROLE NONE;
  SET LOCAL ROLE singularity_table_owner;
  REVOKE CREATE ON SCHEMA core
    FROM singularity_authorization_definer;
  SET LOCAL ROLE NONE;
  ```

  Ordinary vault policies are explicitly `TO singularity_web,
  singularity_worker`; they are never `TO PUBLIC` and never include the
  authorization-definer role. Consequently the helper's membership lookup
  sees only `authorization_definer_reads_membership` and cannot recurse into
  itself. Its first predicates also bind both arguments to the current
  transaction GUCs, so direct calls cannot probe another principal or vault.
  Revoke function execution from `PUBLIC`, grant it only to the request and
  worker roles, and forbid runtime roles from membership in or `SET ROLE` to
  any definer role. Migration tests inspect `pg_policies`,
  `pg_proc.prosecdef`, ownership, the migration role's SET-only memberships,
  the final absence of schema `CREATE`, grants, and authorized, revoked,
  cross-GUC, and missing-GUC calls so recursion or an oracle cannot ship.

  Vault-scoped request/worker policies follow this fail-closed predicate:

  ```sql
  NULLIF(current_setting('singularity.principal_id', true), '') IS NOT NULL
  AND NULLIF(current_setting('singularity.vault_id', true), '') IS NOT NULL
  AND vault_id =
    NULLIF(current_setting('singularity.vault_id', true), '')::uuid
  AND core.principal_is_authorized(
        NULLIF(
          current_setting('singularity.principal_id', true),
          ''
        )::uuid,
        vault_id
      )
  ```

  Every forced-RLS exception is role-specific, not GUC-specific. Each
  no-login function owner gets only the minimum command policy needed by its
  fixed security-definer function:

  ```sql
  CREATE POLICY auth_definer_reads_candidate
    ON identity.credentials
    FOR SELECT
    TO singularity_auth_definer
    USING (true);

  CREATE POLICY auth_definer_records_attempt
    ON identity.auth_attempts
    FOR INSERT
    TO singularity_auth_definer
    WITH CHECK (true);
  ```

  Define equally narrow policies for session resolution and anonymous audit
  insertion, retain the non-recursive authorization-definer membership policy
  above, and define separate outbox-definer claim/ack policies. No definer role
  can log in or has `BYPASSRLS`; pre-auth/dispatcher roles still have no direct
  table grants. Tests must prove positive function execution and denied direct
  SQL under the calling runtime roles.

  Each security-definer function starts with:

  ```sql
  SECURITY DEFINER
  SET search_path = pg_catalog, identity, core, audit
  ```

  Revoke before granting the one runtime role:

  ```sql
  REVOKE ALL ON FUNCTION identity.authentication_candidate(text) FROM PUBLIC;
  GRANT EXECUTE ON FUNCTION identity.authentication_candidate(text)
    TO singularity_pre_auth;
  ```

  Every protected table is activated explicitly:

  ```sql
  ALTER TABLE content.assets ENABLE ROW LEVEL SECURITY;
  ALTER TABLE content.assets FORCE ROW LEVEL SECURITY;
  ```

- [ ] **Step 6: Pass the isolated database gate and commit**

  Run:

  ```bash
  devenv up -d
  trap 'devenv down' EXIT
  devenv processes wait --timeout 120
  devenv shell -- bash \
    apps/singularity_storage/priv/repo/bootstrap_roles.sh
  devenv shell -- mix singularity.test.integration
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add apps/singularity_storage apps/*/test/test_helper.exs config mix.exs \
    devenv.nix .github/workflows/ci.yml
  git commit -m "feat(storage): add PostgreSQL security foundation"
  ```

## Task 7: Add Ecto schemas and PostgreSQL domain adapters

**Files:**

- Create:
  `apps/singularity_storage/lib/singularity/storage/schema/identity/{person,account,credential,principal,session,device,auth_attempt,security_setting}.ex`
- Create:
  `apps/singularity_storage/lib/singularity/storage/schema/core/{vault,vault_member,capability,principal_capability,data_classification,key_domain,vault_key_version,vault_key_wrapper,domain_key_version,domain_dedup_key_wrapper,outbox_event}.ex`
- Create:
  `apps/singularity_storage/lib/singularity/storage/schema/content/{resource,resource_version,asset,asset_stage,asset_object,asset_key_envelope,asset_metadata,asset_search_document,resource_asset,source_reference,tombstone,upload_grant}.ex`
- Create:
  `apps/singularity_storage/lib/singularity/storage/schema/jobs/{job_submission,job_progress,effect_receipt}.ex`
- Create:
  `apps/singularity_storage/lib/singularity/storage/schema/audit/{event,backup_manifest,backup_manifest_object}.ex`
- Create:
  `apps/singularity_storage/lib/singularity/storage/postgres/{identity_repository,vault_repository,asset_repository,asset_search_store,audit_sink,pre_auth,outbox}.ex`
- Create:
  `apps/singularity_storage/test/singularity/storage/postgres/{identity_repository,vault_repository,asset_repository,audit_sink,outbox}_test.exs`
- Create:
  `apps/singularity_storage/test/singularity/storage/{provenance,classification_inheritance,audit_immutability}_test.exs`

- [ ] **Step 1: Write adapter tests from domain behavior**

  Re-run the pure domain scenarios using the real PostgreSQL adapters. Add
  concurrent tests for owner bootstrap, upload-idempotency conflict,
  expected-revision transition, tombstone creation, object-reference release,
  and outbox append in the same transaction.

  The concurrency assertion is:

  ```elixir
  results =
    1..2
    |> Task.async_stream(fn _ ->
      AssetRepository.create_upload_intent(context, attrs)
    end)
    |> Enum.map(fn {:ok, result} -> result end)

  assert Enum.count(results, &match?({:ok, _}, &1)) == 1
  assert Enum.count(results, &match?({:error, %{code: :conflict}}, &1)) == 1
  assert count_rows("content.resources", vault_id) == 1
  assert count_rows("core.outbox_events", vault_id) == 1
  ```

  Run:

  ```bash
  devenv shell -- mix singularity.test.integration
  ```

  Expected: focused failures because no schemas or adapters map the migrated
  tables.

- [ ] **Step 2: Define one Ecto schema per table**

  Schemas map storage records only; they do not become public domain values.
  Use explicit changesets at write boundaries, IDs instead of cross-context
  associations, UTC microsecond timestamps, string-keyed JSON payloads, and
  vault-aware foreign keys. Query-critical values are typed columns.

  `asset_stages`, `auth_attempts`, `security_settings`, `job_submissions`,
  `job_progress`, `effect_receipts`, and `backup_manifest_objects` are
  intentional support tables, not new product concepts.

  A user-owned schema follows this pattern:

  ```elixir
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @schema_prefix "content"
  schema "assets" do
    field :vault_id, Ecto.UUID
    field :resource_version_id, Ecto.UUID
    field :classification, :string
    field :state, Ecto.Enum,
      values: [:staging, :uploaded, :verified, :available, :processing,
               :ready, :pending_delete, :deleted]
    field :state_revision, :integer
    field :failure_code, :string
    field :retryable, :boolean
    field :failed_operation, :string
    field :attempt, :integer
    timestamps(type: :utc_datetime_usec)
  end
  ```

  The Ecto enum casts text but the migration column remains text with an
  explicit SQL check.

- [ ] **Step 3: Implement transactional repositories**

  Map database constraint failures to core errors. Repository functions must
  accept a scoped repo/transaction rather than checking out an unscoped pool.
  Transition functions compare `state_revision` and return a stale no-op for a
  replayed job. Audit and follow-up outbox rows commit with the domain effect.

  `Postgres.PreAuth` may call only the three approved security-definer
  functions. `Postgres.Outbox` may claim/acknowledge only through the approved
  security-definer interface.

  Transition, audit, and outbox use one `Ecto.Multi`:

  ```elixir
  Ecto.Multi.new()
  |> Ecto.Multi.update_all(
    :asset,
    from(a in Asset,
      where:
        a.id == ^command.asset_id and
          a.vault_id == ^command.vault_id and
          a.state_revision == ^command.expected_revision
    ),
    set: [
      state: command.to,
      state_revision: command.expected_revision + 1,
      updated_at: now
    ]
  )
  |> require_one_or_stale(:asset)
  |> Ecto.Multi.insert(:audit, audit_changeset(command))
  |> Ecto.Multi.insert(:outbox, outbox_changeset(command))
  |> repo.transaction()
  |> map_domain_result()
  ```

- [ ] **Step 4: Prove provenance, classification, and audit persistence**

  Assert a browser upload records source kind, server time, original filename,
  declared media type, exact byte size, initiating principal, and only a
  digest of the client idempotency key. Assert no client path is stored.

  Follow one fixture through resource version, asset, object, metadata, search
  document, outbox/job envelope, audit target, and backup inventory; every
  record must preserve `private` or become stricter. Prove audit update/delete
  fails under every runtime role.

  The chain assertion is explicit:

  ```elixir
  assert Enum.all?(
           [
             resource_version,
             asset,
             object,
             metadata,
             search_document,
             outbox_event,
             audit_event,
             backup_entry
           ],
           &(&1.vault_id == vault.id and &1.classification == :private)
         )

  assert_raise Postgrex.Error, fn ->
    RequestRepo.delete(audit_event)
  end
  ```

- [ ] **Step 5: Run the adapter gate and commit**

  Run:

  ```bash
  devenv shell -- mix singularity.test.integration
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix test apps/singularity_domains/test apps/singularity_core/test
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add apps/singularity_storage
  git commit -m "feat(storage): persist foundation domains"
  ```

## Task 8: Implement the key hierarchy, chunked AEAD, and revocable key leases

**Files:**

- Create:
  `apps/singularity_storage/lib/singularity/storage/crypto/{argon2_password_hasher,argon2_key_deriver,key_wrapper,chunked_aead,object_identity,format}.ex`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/{key_custodian,key_lease,key_lease_supervisor}.ex`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/{rotate_vault_key,rotate_domain_key}.ex`
- Create:
  `apps/singularity_storage/test/singularity/storage/crypto/{argon2,chunked_aead,format_vectors,key_rotation,object_identity}_test.exs`
- Create:
  `apps/singularity_storage/test/fixtures/crypto/format-v1.hex`
- Create:
  `apps/singularity_runtime/test/singularity/runtime/key_lease_test.exs`
- Create:
  `apps/singularity_runtime/test/singularity/runtime/key_rotation_test.exs`
- Create:
  `apps/singularity_runtime/test/support/fake/{clock,authorization,key_reader}.ex`

- [ ] **Step 1: Write deterministic format-vector tests**

  Assert:

  - AES-256-GCM with a 64-bit random prefix plus 32-bit big-endian counter;
  - four MiB data chunks use `0x00000000..0xFFFFFFFE`;
  - `0xFFFFFFFF` is reserved only for the final encrypted record;
  - sealing rejects a chunk count that enters the reserved counter;
  - the canonical clear header is included in every record's AAD;
  - AAD binds format, vault, domain, object, index, and plaintext chunk
    length;
  - the final record binds total size, chunk count, and plaintext SHA-256;
  - truncation, reordering, altered tags/header, wrong associated data, and
    counter overflow all fail before plaintext is returned;
  - wrapper-generation mismatch fails before a DEK reaches the codec.

  Pin at least one vector byte-for-byte:

  ```elixir
  vector = %{
    format_version: 1,
    algorithm: :aes_256_gcm,
    chunk_size: 4_194_304,
    key: Base.decode16!("000102030405060708090A0B0C0D0E0F" <>
                        "101112131415161718191A1B1C1D1E1F"),
    nonce_prefix: Base.decode16!("2021222324252627"),
    vault_id: "00000000-0000-0000-0000-000000000010",
    encryption_domain_id: "00000000-0000-0000-0000-000000000020",
    object_id: "00000000-0000-0000-0000-000000000001",
    chunk_index: 0,
    plaintext: "authenticated test vector"
  }

  assert {:ok, encoded} = ChunkedAEAD.encode(vector)
  assert Base.encode16(encoded) == fixture("format-v1.hex")
  assert {:ok, vector.plaintext} = ChunkedAEAD.decode(encoded, vector)
  ```

  Domain-key generation is authenticated by the DEK wrapper and is not a
  ciphertext-header/AAD field. That separation is what permits domain-key
  rotation to rewrap the DEK without rewriting canonical ciphertext.

  Run:

  ```bash
  mix test apps/singularity_storage/test/singularity/storage/crypto/chunked_aead_test.exs
  mix test apps/singularity_storage/test/singularity/storage/crypto/format_vectors_test.exs
  ```

  Expected: failure because the codec does not exist.

- [ ] **Step 2: Implement password and raw-key derivation separately**

  Authentication uses `Argon2.hash_pwd_salt/2` and `verify_pass/2`. The KEK
  derivation uses a separate salt and domain-separated password input with
  `Argon2.Base.hash_password/3`, `format: :raw_hash`, then decodes the returned
  hex to raw bytes. Version every KDF parameter set.

  `KeyWrapper` uses an authenticated, versioned wrapper. It must never reuse a
  salt/label/nonce across credential hashing, vault wrapping, domain wrapping,
  object wrapping, or backup recovery wrapping.

  The raw derivation is:

  ```elixir
  def derive(password, salt, params) do
    input = "singularity:v1:vault-kek:" <> password

    input
    |> Argon2.Base.hash_password(
      salt,
      t_cost: params.t_cost,
      m_cost: params.m_cost,
      parallelism: params.parallelism,
      hashlen: 32,
      argon2_type: 2,
      format: :raw_hash
    )
    |> Base.decode16!(case: :mixed)
  end
  ```

- [ ] **Step 3: Implement the exact key hierarchy and protected identity**

  Create:

  ```text
  password-derived KEK -> random vault key
  vault key            -> random domain key
  domain key           -> random object DEK
  domain key           -> stable random domain dedup key
  ```

  Store only wrapped keys. Compute
  `HMAC-SHA-256(domain_dedup_key, plaintext_sha256)` for lookup and SHA-256 of
  exact ciphertext for integrity. Never persist the raw plaintext digest in a
  queryable column.

  Rotation tests must prove:

  - password change rewrites credential and vault wrapper only;
  - vault-key rotation rewraps domain keys;
  - domain-key rotation rewraps object DEKs and the stable dedup key;
  - canonical ciphertext and lookup digests remain byte-identical;
  - a partially failed rotation leaves the old generation active.

  Key creation and lookup identity use only cryptographic randomness:

  ```elixir
  vault_key = :crypto.strong_rand_bytes(32)
  domain_key = :crypto.strong_rand_bytes(32)
  object_dek = :crypto.strong_rand_bytes(32)
  domain_dedup_key = :crypto.strong_rand_bytes(32)

  lookup_digest =
    :crypto.mac(:hmac, :sha256, domain_dedup_key, plaintext_sha256)
  ```

  Runtime rotation use cases create an inactive generation, rewrap and verify
  the complete child-key set, then activate in one transaction:

  ```elixir
  with {:ok, pending} <- repository.create_pending_generation(context),
       {:ok, wrappers} <- rewrap_all_children(context, pending),
       :ok <- verify_all_wrappers(context, wrappers),
       {:ok, active} <- repository.activate_generation(context, pending.id) do
    {:ok, active}
  else
    {:error, reason} ->
      repository.abandon_pending_generation(context)
      {:error, reason}
  end
  ```

- [ ] **Step 4: Test session-bound key-lease revocation**

  A lease is bound to job, vault, principal, capability, authorization epoch,
  object generation, and one unlocked session. It expires after 60 seconds.
  The custodian exposes only authenticated chunk reads, revalidates before
  each chunk, and never returns a vault key, domain key, or DEK.

  Assert no subsequent chunk is returned after lock, logout, timeout, session
  revocation, principal revocation, or authorization-epoch change. The caller
  receives `waiting_for_unlock`, resumes from a persisted checkpoint after a
  new unlock, and must obtain a new lease.

  The revocation edge is tested between reads:

  ```elixir
  assert {:ok, lease} = KeyCustodian.lease(custodian, request)
  assert {:ok, first} = KeyLease.read_chunk(lease, 0)
  :ok = KeyCustodian.lock(custodian, request.session_id)
  assert {:error, :waiting_for_unlock} = KeyLease.read_chunk(lease, 1)
  refute_receive {:plaintext_chunk, 1, _}
  assert first == expected_first_chunk
  ```

- [ ] **Step 5: Implement bounded secret custody**

  Argon2 work remains in request/task processes, not the custodian. Lease
  processes retain only the minimum derived key material for one reader.
  Overwrite temporary buffers on a best-effort basis and bound process
  lifetime; do not claim deterministic BEAM binary zeroization.

  The public process API never exposes keys:

  ```elixir
  @spec lease(GenServer.server(), LeaseRequest.t()) ::
          {:ok, KeyLease.ref()} | {:error, :waiting_for_unlock | Error.t()}
  def lease(server, request), do: GenServer.call(server, {:lease, request})

  @spec read_chunk(KeyLease.ref(), non_neg_integer()) ::
          {:ok, binary()} | {:error, :waiting_for_unlock | Error.t()}
  def read_chunk(lease, index), do: GenServer.call(lease, {:read_chunk, index})
  ```

- [ ] **Step 6: Run the crypto gate and commit**

  Run:

  ```bash
  mix format
  mix test apps/singularity_storage/test/singularity/storage/crypto
  mix test apps/singularity_runtime/test/singularity/runtime/key_lease_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/key_rotation_test.exs
  mix compile --warnings-as-errors
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add apps/singularity_storage apps/singularity_runtime
  git commit -m "feat(security): add envelope encryption and key leases"
  ```

## Task 9: Implement the durable local encrypted-object adapter

**Files:**

- Create:
  `apps/singularity_storage/lib/singularity/storage/local_filesystem_adapter.ex`
- Create:
  `apps/singularity_storage/lib/singularity/storage/local/{path_guard,stage,sync}.ex`
- Create:
  `apps/singularity_storage/lib/singularity/storage/encrypted_stage_writer.ex`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/storage_adapter.ex`
- Create:
  `apps/singularity_storage/test/singularity/storage/{local_filesystem_adapter,encrypted_stage_writer}_test.exs`
- Create:
  `apps/singularity_storage/test/singularity/storage/local/{path_guard,sync}_test.exs`
- Create:
  `apps/singularity_storage/test/singularity/storage/object_storage_contract_test.exs`

- [ ] **Step 1: Bind the reusable object-storage contract to a temp root**

  Run the core contract against a new isolated directory for every test. Cover
  staging, streaming append, authenticated seal, stat, atomic finalize, range
  read, verify, delete, abort, and stage listing. Add corruption, interrupted
  write, orphan, and duplicate-finalize cases.

  The contract is invoked with no shared fixture:

  ```elixir
  use Singularity.Core.ObjectStorageContract,
    adapter: Singularity.Storage.LocalFilesystemAdapter,
    context: fn ->
      root = Path.join(System.tmp_dir!(), "singularity-#{System.unique_integer([:positive])}")
      %{root: root}
    end
  ```

  Run:

  ```bash
  mix test apps/singularity_storage/test/singularity/storage/object_storage_contract_test.exs
  ```

  Expected: failure because the adapter does not exist.

- [ ] **Step 2: Test paths and durability before implementation**

  Assert the layout:

  ```text
  <root>/staging/<stage_id>
  <root>/objects/<vault_namespace>/<domain_namespace>/hmac-sha256/<prefix>/<lookup_digest>
  ```

  Only validated server UUID/digest segments are accepted. Original filenames
  never become paths. Reject absolute paths, `..`, separators, malformed
  digests, symlink stages, symlink parents, and destination races.

  Inject sync failures and prove the adapter does not acknowledge a sealed
  stage or available object until file and parent directory synchronization
  succeeds.

  The path test forbids user filenames:

  ```elixir
  for segment <- ["../escape", "/absolute", "a/b", "asset.pdf", "bad\\path"] do
    assert {:error, %{code: :invalid}} = PathGuard.segment(segment)
  end

  refute final_path =~ original_filename
  assert final_path =~ lookup_digest
  ```

- [ ] **Step 3: Implement streaming encrypted writes**

  `EncryptedStageWriter` composes `ChunkedAEAD`, streaming plaintext SHA-256,
  protected HMAC identity, ciphertext SHA-256, and `ObjectStorage` without
  buffering the upload. Enforce the configured size before and during the
  stream. Finalization is an atomic same-filesystem rename followed by final
  file and directory sync.

  Deduplicate only within `(vault_id, encryption_domain_id, lookup_digest)`.
  On a hit, destroy the new stage and its DEK wrapper. Never return a flag or
  timing-visible response that exposes cross-vault reuse.

  The writer folds chunks into bounded state:

  ```elixir
  Enum.reduce_while(stream, initial_state, fn plaintext, state ->
    with :ok <- enforce_limit(state.plaintext_bytes, byte_size(plaintext)),
         {:ok, record, cipher_state} <- ChunkedAEAD.encrypt_chunk(state.cipher, plaintext),
         :ok <- adapter.append_encrypted_chunk(context, state.stage_ref, record) do
      {:cont,
       %{state |
         cipher: cipher_state,
         plaintext_hash: :crypto.hash_update(state.plaintext_hash, plaintext),
         ciphertext_hash: :crypto.hash_update(state.ciphertext_hash, record),
         plaintext_bytes: state.plaintext_bytes + byte_size(plaintext)}}
    else
      {:error, reason} -> {:halt, {:error, reason, state}}
    end
  end)
  ```

- [ ] **Step 4: Add the temporary adapter selection marker**

  `Singularity.Runtime.StorageAdapter` selects the local adapter from runtime
  configuration and contains:

  ```elixir
  # WORKAROUND(upstream): gsmlg-opt/ex_storage_service#5
  ```

  Do not reference ESS modules or add a speculative embedded adapter.

- [ ] **Step 5: Run storage and integration gates, then commit**

  Run:

  ```bash
  mix format
  mix test apps/singularity_storage/test/singularity/storage/local
  mix test apps/singularity_storage/test/singularity/storage/object_storage_contract_test.exs
  mix test apps/singularity_storage/test/singularity/storage/local_filesystem_adapter_test.exs
  mix test apps/singularity_storage/test/singularity/storage/encrypted_stage_writer_test.exs
  devenv shell -- mix singularity.test.integration
  mix compile --warnings-as-errors
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add apps/singularity_storage apps/singularity_runtime
  git commit -m "feat(storage): add encrypted local object adapter"
  ```

## Task 10: Add transactional outbox delivery and injected Oban jobs

**Files:**

- Create:
  `apps/singularity_storage/lib/singularity/storage/jobs/{oban_adapter,generic_worker,worker_scope,envelope_codec,progress}.ex`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/{application,outbox_dispatcher,job_dispatcher,authorization_dependencies}.ex`
- Create:
  `apps/singularity_storage/test/support/fake/job_handler.ex`
- Create:
  `apps/singularity_storage/test/singularity/storage/{outbox_oban,runner_submission_recovery,effect_receipt}_test.exs`
- Create:
  `apps/singularity_runtime/test/singularity/runtime/{application,outbox_dispatcher,job_restart}_test.exs`
- Modify:
  `apps/singularity_storage/lib/mix/tasks/singularity.test.integration.ex`
- Modify: `apps/singularity_runtime/mix.exs`
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`

- [ ] **Step 1: Write envelope-codec and worker tests**

  Encode versioned envelopes as string-keyed JSON maps. Decode by matching
  string keys and revalidate every required core field. Missing callback
  configuration, missing principal/vault context, unknown version/job type,
  stale authorization epoch, or malformed payload must fail closed.

  The generic storage worker receives the `JobHandler` module by injection;
  it must not compile against runtime. The behavior exposes
  `dependencies/0` plus `handle/2`. The worker treats the returned dependency
  map as opaque, merges it into the per-attempt context, and fails closed when
  it is malformed or attempts to supply a worker-reserved key. The runtime
  handler separately fails startup when its required authorization bundle is
  absent or invalid. The fake handler returns explicit fake dependencies. Its
  tests prove two explicit
  `context.transact` phases can commit around an injected external effect, the
  scoped repo cannot escape a phase, and every phase restores `SET LOCAL`
  context without leaking it to the pool.

  The fail-closed assertion is:

  ```elixir
  assert {:cancel, %{code: :job_failed}} =
           GenericWorker.perform(%Oban.Job{
             args: %{"version" => 1, "job_type" => "unknown"}
           })

  refute dependency?(:singularity_storage, :singularity_runtime)
  ```

- [ ] **Step 2: Write crash-recovery tests around submission**

  Cover:

  1. outbox claimed, runner submission succeeds, process crashes before outbox
     acknowledgement;
  2. duplicate dispatcher claim;
  3. worker crashes after domain effect but before Oban acknowledgement;
  4. application restarts with a recorded runner ID.

  Assert one permanent `jobs.job_submissions` identity, one effect receipt,
  one logical domain effect, and stable recorded Oban job ID.

  After injected restart:

  ```elixir
  assert submission_before.runner_job_id == submission_after.runner_job_id
  assert count_effects(idempotency_key) == 1
  assert count_receipts(idempotency_key) == 1
  assert outbox_after.delivered_at
  ```

  Run:

  ```bash
  devenv shell -- mix singularity.test.integration
  ```

  Expected: focused failures because there is no runner or dispatcher.

- [ ] **Step 3: Implement correctness independently of Oban uniqueness**

  The transaction that submits work contains both the Oban insert and the
  unique permanent `job_submissions` row keyed by the outbox/idempotency
  identity. Configure Oban uniqueness as
  `unique: [period: :infinity, states: :all]` only as defense in depth.

  Handlers commit their domain effect and `effect_receipts` together. A stale
  expected revision is a recorded no-op, not a duplicate effect.

  Submission reserves the permanent receipt before inserting:

  ```elixir
  job =
    GenericWorker.new(envelope,
      queue: queue,
      unique: [period: :infinity, states: :all]
    )

  Ecto.Multi.new()
  |> Ecto.Multi.run(
    :submission,
    fn repo, _changes ->
      JobSubmissions.reserve(repo, receipt_attrs)
    end
  )
  |> Ecto.Multi.run(:job, fn
    repo, %{submission: {:new, submission}} ->
      with {:ok, oban_job} <- Oban.insert(Singularity.Oban, job),
           {:ok, _submission} <-
             JobSubmissions.record_runner_id(repo, submission, oban_job.id) do
        {:ok, oban_job.id}
      end

    _repo, %{submission: {:existing, submission}} ->
      {:ok, submission.runner_job_id}
  end)
  |> WorkerRepo.transaction()
  ```

- [ ] **Step 4: Implement audited cross-vault claim and scoped handling**

  `OutboxDispatcher` claims leased batches using only the dispatcher
  security-definer functions and `FOR UPDATE SKIP LOCKED`; it skips a vault
  under an exclusive backup lock. `GenericWorker` establishes WorkerRepo
  context from the envelope before calling the injected handler.

  Every generic worker takes the shared vault lock and shared authorization
  lock before dispatch. The single `"backup"` job type takes the corresponding
  exclusive vault lock. The process-bound WorkerRepo handle remains pinned
  through the complete handler attempt, but the generic worker does not wrap
  the whole handler in one database transaction. Instead it passes a
  `context.transact/2` capability that establishes the envelope's RLS context
  for each short, explicitly committed phase. Handlers may perform external
  effects between phases while both session advisory locks remain held, then
  commit the following acknowledgement in a new phase. They may not switch to
  RequestRepo.

  This phase boundary is required: logical deletion must commit before a
  separately retryable physical cleanup job, and metadata's processing
  revision/checkpoint must commit before plaintext extraction. Backup is the
  explicit handler that invokes one repeatable-read transaction through the
  same capability while its exclusive vault lock is held.

  `JobDispatcher` initially rejects every unregistered job type with a stable
  `job_failed` error. Later tasks add explicit handlers; it must never use
  arbitrary module names from payloads.

  `waiting_for_unlock` is stored in `job_progress` and snoozes the job.
  `JobRunner.wake_vault/2` is the only runtime wake interface.

  Worker execution is scoped before dispatch:

  ```elixir
  def perform(%Oban.Job{args: args}) do
    with {:ok, envelope} <- EnvelopeCodec.decode(args) do
      with_job_locks(envelope, fn repo_handle ->
        context = %{
          repo_handle: repo_handle,
          lock_mode: lock_mode(envelope),
          transact: fn options, fun ->
            ScopedRepo.transact(
              repo_handle,
              envelope,
              options,
              fun
            )
          end
        }

        handler = handler()
        dependencies = handler.dependencies() |> validate_dependencies!()
        handler.handle(Map.merge(dependencies, context), envelope)
      end)
      |> map_oban_result()
    end
  end

  defp with_job_locks(%{job_type: "backup"} = envelope, fun) do
    VaultLock.with_exclusive(WorkerRepo, envelope.vault_id, fn repo_handle ->
      AuthorizationLock.with_shared(
        repo_handle,
        envelope.principal_id,
        envelope.vault_id,
        fn -> fun.(repo_handle) end
      )
    end)
  end

  defp with_job_locks(envelope, fun) do
    VaultLock.with_shared(WorkerRepo, envelope.vault_id, fn repo_handle ->
      AuthorizationLock.with_shared(
        repo_handle,
        envelope.principal_id,
        envelope.vault_id,
        fn -> fun.(repo_handle) end
      )
    end)
  end
  ```

  A handler phase is explicit:

  ```elixir
  context.transact.([], fn repo ->
    with :ok <-
           Authorize.check_job(context.authorization, repo, envelope) do
      repository.apply_and_acknowledge(repo, envelope)
    end
  end)
  ```

  The callback receives the scoped repo only inside `transact`; it must not
  retain that value across phases. `context.repo_handle` is opaque to domain
  handlers except for the approved storage lock helpers.

  `Singularity.Runtime.JobDispatcher.dependencies/0` delegates to the
  supervised runtime composition root and returns the concrete ports as an
  in-memory map. Its `authorization` key holds an
  `%AuthorizationDependencies{}` containing the authoritative store and
  custodian.
  Startup and worker tests fail closed when either member is absent. The
  worker-owned `repo_handle`, `lock_mode`, and `transact` keys are merged last
  and cannot be overridden by injected dependencies. The
  dependency map is never encoded into the job envelope, persisted, or logged.
  `Authorize` itself has no application-environment or process-dictionary
  accessor.

  `JobDispatcher.handle/2` begins every explicit case with live authorization
  inside each received `context.transact` phase. The envelope epoch is compared
  to the reloaded membership epoch before the handler performs an effect.
  Storage cannot perform this check because it does not depend on runtime.

- [ ] **Step 5: Wire the supervision order**

  `Singularity.Runtime.Application` starts:

  1. RequestRepo, PreAuthRepo, DispatcherRepo, WorkerRepo;
  2. KeyLeaseSupervisor and KeyCustodian;
  3. the storage-owned Oban adapter with prefix `jobs`;
  4. OutboxDispatcher.

  `MigrationRepo` is never in the tree. Production configuration must refuse
  an absent runtime job-handler module.

  In test, infrastructure is opt-in so pure/core/web-fake tests do not require
  a shared database. The isolated integration runner sets
  `:start_infrastructure` before it starts applications:

  ```elixir
  def start(_type, _args) do
    children =
      if Application.fetch_env!(:singularity_runtime, :start_infrastructure) do
        infrastructure_children()
      else
        []
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Singularity.Runtime.Supervisor
    )
  end
  ```

  ```elixir
  # config/test.exs
  config :singularity_runtime, start_infrastructure: false

  # inside mix singularity.test.integration, before Mix.Task.run("test", ...)
  Application.put_env(:singularity_runtime, :start_infrastructure, true)
  ```

  The child order is literal:

  ```elixir
  children = [
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo,
    Singularity.Runtime.KeyLeaseSupervisor,
    Singularity.Runtime.KeyCustodian,
    Singularity.Storage.Jobs.ObanAdapter,
    Singularity.Runtime.OutboxDispatcher
  ]
  ```

  `Singularity.Storage.Jobs.ObanAdapter.child_spec/1` is the only module in
  that list that references Oban. Runtime starts the storage child spec and
  never compiles against a transitive Hex dependency.

- [ ] **Step 6: Run restart/integration gates and commit**

  Run:

  ```bash
  mix format
  mix test apps/singularity_runtime/test/singularity/runtime/application_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/outbox_dispatcher_test.exs
  devenv shell -- mix singularity.test.integration
  mix compile --warnings-as-errors
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add apps/singularity_storage apps/singularity_runtime config
  git commit -m "feat(runtime): add durable job dispatch"
  ```

## Task 11: Implement owner bootstrap, login, unlock, and authorization

**Files:**

- Create:
  `apps/singularity_runtime/lib/singularity/runtime/{bootstrap_owner,login,resolve_session,unlock_vault,lock_vault,logout,change_password,authorize,operation_scope}.ex`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/session_context.ex`
- Create:
  `apps/singularity_runtime/lib/mix/tasks/singularity.bootstrap_owner.ex`
- Create:
  `apps/singularity_runtime/test/singularity/runtime/{bootstrap_owner,login,unlock_vault,lock_vault,logout,change_password,authorization,custody_compensation}_test.exs`
- Create:
  `apps/singularity_runtime/test/singularity/runtime/authentication_timing_test.exs`
- Create:
  `apps/singularity_runtime/test/support/secret_input.ex`
- Modify:
  `apps/singularity_storage/lib/singularity/storage/postgres/{identity_repository,pre_auth}.ex`
- Modify:
  `apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex`
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`

- [ ] **Step 1: Write the owner-aggregate acceptance test**

  In one transaction, bootstrap person, account, credential, principal,
  personal vault, owner membership, initial capabilities, key domain, vault
  key generation, domain key generation, stable dedup key, and wrappers.
  Re-running with another password must return the existing owner without
  replacing its credential.

  The Mix task accepts the password only from a no-echo prompt or inherited
  secret file descriptor. Assert a password argument is rejected and never
  appears in process arguments or output.

  The idempotency assertion is:

  ```elixir
  assert {:ok, first} = BootstrapOwner.run(adapters, attrs(password: "first"))
  assert {:ok, second} = BootstrapOwner.run(adapters, attrs(password: "other"))
  assert first.account_id == second.account_id
  assert credential_hash(first.account_id) == credential_hash(second.account_id)
  assert count_owner_principals() == 1
  assert count_personal_vaults() == 1
  ```

- [ ] **Step 2: Write login/pre-auth behavior tests**

  Assert:

  - rate-limit reservation occurs before Argon2 work;
  - unknown login uses the fixed dummy verifier;
  - unknown and invalid credentials return the same error/body/category;
  - successful login creates an opaque session but leaves the vault locked;
  - the signed-cookie payload needed later contains only the opaque session
    identifier;
  - anonymous failures record only a keyed login/source fingerprint and
    `vault_id = NULL`;
  - audit rendering cannot reveal whether the login matched;
  - an injected successful-authentication audit failure rolls back session
    issuance;
  - absent or shorter-than-32-byte production fingerprint secrets fail
    startup, while test configuration injects a fixed 32-byte value;
  - spy persistence adapters never receive the password or the fingerprint
    secret, only normalized-login lookup input and sanitized fingerprint,
    session-digest, correlation, and audit commands.

  Compare the public outcomes:

  ```elixir
  unknown = Login.run(adapters, %{login: "missing", password: "wrong", source: source})
  invalid = Login.run(adapters, %{login: owner_login, password: "wrong", source: source})

  assert unknown == {:error, Error.new(:unauthenticated)}
  assert invalid == unknown
  assert audit_for(unknown).actor_kind == :anonymous
  assert audit_for(unknown).vault_id == nil
  ```

- [ ] **Step 3: Implement login and session resolution**

  Normalize login once. Call only `Postgres.PreAuth` before scoped context
  exists. Use constant-shape responses and the runtime audit-fingerprint
  secret. Persist only session-token digests. A successful scoped transaction
  atomically inserts both the session and its immutable authentication audit
  event. An audit failure therefore creates no usable session. Invalid and
  unknown credentials both attempt the same anonymous failure audit and still
  return the same public unauthenticated result.

  Production reads `SINGULARITY_AUDIT_FINGERPRINT_SECRET` as base64, requires
  at least 32 decoded bytes, and fails startup if it is absent, malformed, or
  short. Test configuration injects a fixed 32-byte binary. The secret is
  never persisted or logged. Compute independent HMAC-SHA-256 values for login
  and source so their rate-limit buckets cannot be collapsed into one combined
  key:

  ```elixir
  def fingerprints(secret, normalized_login, normalized_source) do
    %{
      login: mac(secret, "singularity/auth-login/v1", normalized_login),
      source: mac(secret, "singularity/auth-source/v1", normalized_source)
    }
  end

  defp mac(secret, label, value) do
    :crypto.mac(
      :hmac,
      :sha256,
      secret,
      [label, <<0>>, value]
    )
  end
  ```

  `runtime.exs` validates production configuration before starting children:

  ```elixir
  if config_env() == :prod do
    encoded = System.fetch_env!("SINGULARITY_AUDIT_FINGERPRINT_SECRET")

    secret =
      case Base.decode64(encoded) do
        {:ok, value} when byte_size(value) >= 32 -> value
        _ -> raise "SINGULARITY_AUDIT_FINGERPRINT_SECRET must decode to at least 32 bytes"
      end

    config :singularity_runtime, audit_fingerprint_secret: secret
  end

  # config/test.exs
  config :singularity_runtime,
    audit_fingerprint_secret: :binary.copy(<<0xA7>>, 32)
  ```

  The public flow is fixed:

  ```elixir
  def run(adapters, request) do
    normalized_login = normalize_login(request.login)
    normalized_source = normalize_source(request.source)

    fingerprints =
      fingerprints(
        adapters.audit_fingerprint_secret,
        normalized_login,
        normalized_source
      )

    attempt_command = %{
      login_fingerprint: fingerprints.login,
      source_fingerprint: fingerprints.source,
      correlation_id: request.correlation_id
    }

    with {:ok, attempt} <- adapters.pre_auth.reserve_attempt(attempt_command),
         {:ok, candidate} <-
           adapters.pre_auth.authentication_candidate(normalized_login) do
      authenticated? =
        adapters.password_hasher.verify(request.password, candidate.verifier) and
          not is_nil(candidate.scoped_context)

      if authenticated? do
        opaque_token = :crypto.strong_rand_bytes(32)

        session_command = %{
          attempt_id: attempt.id,
          token_digest: :crypto.hash(:sha256, opaque_token),
          source_fingerprint: fingerprints.source,
          correlation_id: request.correlation_id
        }

        with {:ok, session} <-
               adapters.identity.create_session_and_audit(
                 candidate.scoped_context,
                 session_command,
                 audit_result: "allowed"
               ) do
          {:ok, %{session: session, opaque_token: opaque_token}}
        else
          _ -> {:error, Error.new(:unauthenticated)}
        end
      else
        failure_command = %{
          attempt_id: attempt.id,
          login_fingerprint: fingerprints.login,
          source_fingerprint: fingerprints.source,
          correlation_id: request.correlation_id,
          result: "failed"
        }

        case adapters.pre_auth.record_attempt(failure_command) do
          :ok -> {:error, Error.new(:unauthenticated)}
          {:error, _audit_failure} -> {:error, Error.new(:unauthenticated)}
        end
      end
    else
      _ -> {:error, Error.new(:unauthenticated)}
    end
  end
  ```

  A failed anonymous-audit write is a redacted operational-health event, but
  it never permits login and does not change the public credential response.

  Opaque-session resolution is a separate pre-auth use case:

  ```elixir
  def run(adapters, opaque_token) do
    digest = :crypto.hash(:sha256, opaque_token)

    with {:ok, resolved} <- adapters.pre_auth.resolve_session(digest) do
      unlocked? = adapters.custodian.unlocked?(resolved.session_id)
      {:ok, SessionContext.from_resolved(resolved, unlocked?: unlocked?)}
    else
      _ -> {:error, Error.new(:unauthenticated)}
    end
  end
  ```

- [ ] **Step 4: Implement unlock, lock, logout, and password change**

  Unlock independently derives the KEK, verifies the active vault wrapper,
  and deposits the vault hierarchy in session-bound custody. Default idle
  timeout is 15 minutes and configurable. Lock/logout/restart/revocation
  terminates leases and wakes no plaintext job until a later unlock.

  Password change verifies the old wrapper, writes a new authentication hash
  plus independently derived vault wrapper atomically, and leaves canonical
  ciphertext untouched.

  Unlock, password change, and later backup-key re-entry use a live mutation
  scope with the shared authorization lock. Their requirements set
  `requires_unlocked?: false` only when the operation itself establishes or
  re-establishes custody. Custody installation is a post-commit effect:
  `prepare_unlock/2` creates a monitored, short-TTL pending reference that
  cannot issue leases or wake jobs. `activate_unlock/1` atomically turns that
  pending reference into usable session custody only after the live
  authorization transaction and unlock audit commit. `discard_pending/1` is
  idempotent and affects only an unresolved pending reference.

  `OperationScope` recognizes the trusted
  `{:after_commit, zero_arity_callback}` result returned by runtime use cases.
  It commits the scoped transaction first, then executes the callback before
  releasing the vault and authorization locks. A rollback or commit/audit
  error never executes the callback. Keep unlock and authentication separate:

  ```elixir
  @spec run(map(), SessionContext.t(), binary()) ::
          {:ok, SessionContext.t()} | {:error, Error.t()}
  def run(runtime, session, password) do
    requirement = requirement(:vault_unlock, requires_unlocked?: false)

    with {:ok, wrapper} <-
           OperationScope.with_read_request(
             runtime,
             session,
             requirement,
             &runtime.vaults.active_wrapper(&1, session)
           ),
         {:ok, kek} <- runtime.key_deriver.derive(password, wrapper.kdf),
         {:ok, vault_key} <- runtime.key_wrapper.unwrap(kek, wrapper),
         {:ok, pending} <-
           runtime.custodian.prepare_unlock(session, vault_key) do
      try do
        OperationScope.with_shared_request(
          runtime,
          session,
          requirement,
          fn repo ->
            with :ok <-
                   runtime.vaults.assert_active_wrapper(
                     repo,
                     session,
                     wrapper.generation
                   ),
                 :ok <-
                   runtime.vaults.record_unlock_audit(
                     repo,
                     session,
                     result: "allowed"
                   ) do
              {:after_commit,
               fn ->
                 with :ok <- runtime.custodian.activate_unlock(pending) do
                   {:ok, SessionContext.unlocked(session)}
                 end
               end}
            end
          end
        )
      after
        runtime.custodian.discard_pending(pending)
      end
    end
  end
  ```

  Inject transaction-body, audit-write, commit, and activation failures.
  Every failure must leave the session locked, issue no `KeyLease`, and emit
  no wake-up. An activation failure may leave the already-committed redacted
  `"allowed"` attempt audit, but it cannot return an unlocked session.

  Lock, logout, timeout, session/principal revocation, and
  membership/capability/epoch changes use custody-first revocation. Before
  waiting for database advisory locks they synchronously call
  `KeyCustodian.begin_revoke/2` for the affected session or
  principal/vault. That call atomically marks matching custody `:revoking`
  and terminates every matching lease; every lease checks that gate before
  each chunk. Only then does the use case take the vault lock followed by the
  exclusive authorization lock and persist the revocation plus audit.

  Custody revocation is not an anonymous public primitive. Self lock/logout
  requires the already-resolved opaque session; timeouts use an internal
  scheduler message; principal/vault-wide changes first perform a scoped
  preflight authorization, then close custody, then recheck authority under
  the exclusive lock before persistence. The preflight is only a
  denial-of-service guard, never the mutation's authority decision.

  If the database transaction or audit fails, custody remains conservatively
  revoking/locked and keys are never resurrected; the principal must
  authenticate/unlock again. The custody gate is the only pre-lock step, so
  database advisory-lock order remains vault then authorization.

  Prove immediate interruption while persistence is still waiting:

  ```elixir
  assert {:ok, first} = KeyLease.read_chunk(lease, 0)
  revoker = Task.async(fn -> Logout.run(runtime, session) end)
  assert :ok = KeyCustodian.await_revoking(custodian, session.session_id)
  assert {:error, :waiting_for_unlock} = KeyLease.read_chunk(lease, 1)
  assert Task.yield(revoker, 0) == nil
  release_paused_authorized_read()
  assert :ok = Task.await(revoker)
  assert first == expected_first_chunk
  ```

- [ ] **Step 5: Enforce use-time authorization**

  `SessionContext` is an identity hint, not authority. `Authorize` reloads the
  session, revocation state, live vault membership, capabilities, current
  authorization epoch, classification clearance, and custodian unlock state
  through the already-scoped repository. Grants and jobs created under an old
  epoch cannot perform a sensitive effect, including after revoke-and-regrant.
  Dependencies are explicit values assembled by the runtime composition root;
  `Authorize` has no hidden zero-arity accessors:

  ```elixir
  def check(
        %AuthorizationDependencies{store: store, custodian: custodian},
        repo,
        session,
        requirement
      ) do
    with {:ok, live} <-
           store.load_live_session(repo, session.session_id),
         false <- live.revoked?,
         true <- live.principal_id == session.principal_id,
         true <- live.vault_id == requirement.vault_id,
         true <- live.authorization_epoch == requirement.authorization_epoch,
         true <- requirement.capability in live.capabilities,
         true <- Classification.allows?(live.clearance, requirement.classification),
         :ok <- check_unlock(custodian, requirement, live) do
      :ok
    else
      false -> {:error, Error.new(:forbidden)}
      {:error, :vault_locked} -> {:error, Error.new(:vault_locked)}
      _ -> {:error, Error.new(:forbidden)}
    end
  end

  defp check_unlock(_custodian, %{requires_unlocked?: false}, _live), do: :ok

  defp check_unlock(custodian, _requirement, live),
    do: custodian.assert_unlocked(live.session_id, live.vault_id)

  def check_job(
        %AuthorizationDependencies{store: store},
        repo,
        envelope
      ) do
    with {:ok, live} <-
           store.load_live_principal(
             repo,
             envelope.principal_id,
             envelope.vault_id
           ),
         false <- live.revoked?,
         true <- live.authorization_epoch == envelope.authorization_epoch,
         true <- envelope.required_capability in live.capabilities,
         true <- Classification.allows?(live.clearance, envelope.classification) do
      :ok
    else
      _ -> {:error, Error.new(:forbidden)}
    end
  end
  ```

  `check_job/3` has a separate exact-operation branch for the named
  least-privilege system principal used by maintenance; it cannot impersonate
  an owner or broaden the envelope's vault/capability.

  Every request mutation uses one operation scope so authorization and effect
  use the same scoped transaction and pinned request connection:

  ```elixir
  def with_shared_request(runtime, session, requirement, effect) do
    VaultLock.with_shared(
      runtime.request_repo,
      requirement.vault_id,
      fn repo_handle ->
        AuthorizationLock.with_shared(
          repo_handle,
          session.principal_id,
          requirement.vault_id,
          fn ->
            ScopedRepo.transact(repo_handle, session, [], fn repo ->
              with :ok <-
                     Authorize.check(
                       runtime.authorization,
                       repo,
                       session,
                       requirement
                     ) do
                effect.(repo)
              end
            end)
            |> run_after_commit()
          end
        end)
      end
    )
  end

  def with_read_request(runtime, session, requirement, effect) do
    runtime.request_repo.checkout(fn ->
      AuthorizationLock.with_shared(
        runtime.request_repo,
        session.principal_id,
        requirement.vault_id,
        fn ->
          ScopedRepo.transact(runtime.request_repo, session, [], fn repo ->
            with :ok <-
                   Authorize.check(
                     runtime.authorization,
                     repo,
                     session,
                     requirement
                   ) do
              effect.(repo)
            end
          end)
        end
      )
    end)
  end

  defp run_after_commit({:after_commit, callback})
       when is_function(callback, 0),
       do: callback.()

  defp run_after_commit(result), do: result
  ```

  Read-only scopes pin the request transaction but do not take the vault
  advisory lock, so authorized reads may continue during a backup cut.

  Worker handlers perform the equivalent live check inside
  `context.transact` with `context.authorization`; they never open another
  pool. Revocation, membership, capability, and epoch mutation paths first
  close the custody gate, then acquire the vault and exclusive authorization
  locks. Add both database race orderings: an already-linearized non-plaintext
  operation may complete before revocation commits; once revocation commits,
  a waiting/new operation fails before any effect. A plaintext operation is
  interrupted at its next lease read as soon as custody enters `:revoking`,
  even while the database revocation is waiting. No protected external effect
  can overlap a committed revocation.

- [ ] **Step 6: Run auth/integration gates and commit**

  Run:

  ```bash
  mix format
  mix test apps/singularity_runtime/test/singularity/runtime/bootstrap_owner_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/login_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/unlock_vault_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/lock_vault_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/logout_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/change_password_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/authorization_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/custody_compensation_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/authentication_timing_test.exs
  devenv shell -- mix singularity.test.integration
  mix compile --warnings-as-errors
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add apps/singularity_runtime apps/singularity_storage config
  git commit -m "feat(runtime): add owner authentication and vault unlock"
  ```

## Task 12: Complete upload, verify, finalize, download, delete, and cleanup

**Files:**

- Create:
  `apps/singularity_ingest/lib/singularity/ingest/{upload_request,upload_checkpoint,idempotency}.ex`
- Create:
  `apps/singularity_ingest/test/singularity/ingest/{upload_request,upload_checkpoint,idempotency}_test.exs`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/assets/{create_upload_grant,accept_upload,verify,finalize,download,delete,cleanup,object_cleanup,retry,status}.ex`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/assets/upload_session.ex`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/upload_session_supervisor.ex`
- Modify:
  `apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex`
- Modify:
  `apps/singularity_runtime/lib/singularity/runtime/application.ex`
- Modify:
  `apps/singularity_storage/lib/singularity/storage/postgres/asset_repository.ex`
- Create:
  `apps/singularity_storage/lib/singularity/storage/object_lock.ex`
- Create:
  `apps/singularity_runtime/test/singularity/runtime/{asset_vertical,asset_failure_recovery,two_vault_isolation,upload_session_lock}_test.exs`
- Create:
  `apps/singularity_storage/test/singularity/storage/{asset_saga,orphan_cleanup,object_cleanup_concurrency,dedup_isolation}_test.exs`

- [ ] **Step 1: Write the vertical test through runtime ports**

  Exercise:

  ```text
  create grant -> consume once -> stream encrypted stage -> uploaded
  -> verify -> verified -> finalize/deduplicate -> available
  -> authenticated range/full download
  -> tombstone -> pending_delete -> logical cleanup -> deleted
  -> independently retain or delete the canonical object
  ```

  Assert every transition has the expected revision, audit row, and follow-up
  outbox event. Assert retry with a stale revision is a no-op.

  The acceptance spine is:

  ```elixir
  assert {:ok, grant} = CreateUploadGrant.run(runtime, session, upload_attrs)
  assert {:ok, uploaded} = AcceptUpload.run(runtime, session, grant, byte_stream)
  assert uploaded.state == :uploaded
  assert {:ok, verified} = Verify.run(runtime, job(uploaded))
  assert {:ok, available} = Finalize.run(runtime, job(verified))
  assert {:ok, bytes} = Download.run(runtime, session, available.id, :all)
  assert bytes == fixture_bytes
  assert {:ok, pending} = Delete.run(runtime, session, available.id, available.state_revision)
  assert {:ok, deleted} = Cleanup.run(runtime, job(pending))
  assert deleted.state == :deleted
  ```

- [ ] **Step 2: Write grant, media, and idempotency tests**

  A grant is random, five-minute, session/principal/vault/object bound,
  single-use, and stores only SHA-256 of its 256-bit token. It binds exact
  filename, byte size, declared type, idempotency key, and authorization
  epoch. Grant creation runs through `OperationScope.with_shared_request/4`
  and records the live epoch loaded inside that scope.

  Accepted types are exactly PDF, JPEG, and PNG. Validate magic bytes before
  seal; declared type is only a hint. Reuse with changed bound metadata
  returns `conflict`. Enforce 512 MiB default before streaming and on final
  observed byte count.

  ```elixir
  assert {:ok, grant} = CreateUploadGrant.run(runtime, session, attrs)
  assert {:ok, _} = AcceptUpload.run(runtime, session, grant, stream)
  assert {:error, %{code: :conflict}} =
           AcceptUpload.run(runtime, session, grant, stream)

  assert {:error, %{code: :conflict}} =
           CreateUploadGrant.run(runtime, session, %{attrs | size: attrs.size + 1})
  ```

- [ ] **Step 3: Implement the saga with explicit recovery evidence**

  Consume the grant atomically before reading bytes. On interruption, mark the
  stage abandoned. The sealed-stage transaction persists digests, wrapper,
  provenance, transition, audit, and verification outbox event. Verification
  checks envelope presence plus ciphertext size/hash. Finalization atomically
  renames or safely reuses a same-vault/domain object.

  Same-object finalization and physical object cleanup both take
  `ObjectLock.with_exclusive/3` on the canonical object after the vault and
  authorization locks. Finalization rechecks object state before adding a
  reference; cleanup rechecks zero references before deletion. This prevents
  a finalizer from adding a reference between orphan recheck and filesystem
  removal. `ObjectLock` uses a third advisory-lock namespace so its keys cannot
  collide with vault or authorization locks.

  Verification and finalization operate only on authenticated envelope
  structure and ciphertext metadata; they never request a KeyLease and must
  complete while the vault is locked. Only plaintext download and metadata
  extraction require an unlocked lease.

  There is no database/filesystem distributed transaction. Every boundary is
  restartable from persisted stage, object, revision, outbox, and effect
  receipt records.

  The persisted checkpoints are explicit:

  ```elixir
  with {:ok, consumed} <-
         upload_scope.transact(fn repo ->
           repository.consume_grant_and_create_stage(repo, grant)
         end),
       {:ok, sealed} <-
         writer.stream_and_seal(storage, consumed, body_stream),
       {:ok, uploaded} <-
         upload_scope.transact(fn repo ->
           repository.record_sealed_stage(repo, sealed)
         end) do
    {:ok, uploaded}
  else
    {:error, reason, stage_ref} ->
      upload_scope.transact(fn repo ->
        repository.mark_stage_abandoned(repo, stage_ref, reason)
      end)

      {:error, map_error(reason)}
  end
  ```

  A streaming PUT is represented by a short-lived
  `Singularity.Runtime.Assets.UploadSession` process under
  `UploadSessionSupervisor`. It checks out one RequestRepo connection, takes
  the shared vault and authorization advisory locks, and owns the encrypted
  writer. On that pinned connection it first commits a short scoped
  transaction that rechecks live authorization, consumes the grant, and
  creates the durable stage record. It then streams outside a database
  transaction. After stage sync it opens a second scoped transaction for the
  database acknowledgement. Cancellation/owner exit opens an idempotent
  abandonment transaction. A process or VM failure can never roll back grant
  consumption and make the token reusable.

  The controller receives only an opaque upload-session handle. It sends
  append, finish, and abort calls; `Plug.Conn` never enters runtime. The
  session monitors the controller, expires no later than the grant, abandons
  the stage idempotently on owner exit/timeout, and releases writer,
  connection, and locks in `after`.

  Bound concurrent upload sessions to `SINGULARITY_MAX_CONCURRENT_UPLOADS`
  (default `2`) through `DynamicSupervisor.max_children`; keep RequestRepo's
  pool at least `10`. When full, `begin_upload` returns
  `storage_unavailable`/`503` before reading a body, preserving capacity for
  normal requests.

  ```elixir
  children = [
    # existing repos, custody, Oban, and dispatcher children
    {DynamicSupervisor,
     strategy: :one_for_one,
     max_children:
       Application.fetch_env!(
         :singularity_runtime,
         :max_concurrent_uploads
       ),
     name: Singularity.Runtime.UploadSessionSupervisor}
  ]

  def begin_upload(runtime, session, grant, controller) do
    DynamicSupervisor.start_child(
      UploadSessionSupervisor,
      {UploadSession,
       runtime: runtime,
       session: session,
       grant: grant,
       owner: controller}
    )
  end
  ```

  Test that backup's exclusive lock waits throughout a paused upload, that a
  controller crash abandons exactly one stage, and that VM restart
  reconciliation does the same while leaving the grant consumed. Prove finish
  replies only after stage sync plus database acknowledgement. Fill the
  upload-session limit and prove a normal request still obtains RequestRepo
  capacity.

- [ ] **Step 4: Implement authorized reads and deletion**

  Downloads require current capability and an unlocked lease, authenticate
  every requested chunk, align ranges internally, and trim only after
  authentication. Do not expose a raw file path.

  Delete commits tombstone and logical release before scheduling projection
  and object cleanup. Logical completion is independent of canonical-object
  retention: after projection cleanup and reference release, the asset moves
  `pending_delete -> deleted` even when another logical asset shares the
  object. Physical cleanup is separately retryable. An orphan enters
  `orphan_pending`; after retention, cleanup rechecks zero live references
  before deleting bytes. A stale job cannot remove an object that gained a
  reference. Download enters through `OperationScope.with_read_request/4`;
  delete uses `with_shared_request/4`. Both authorization checks use the
  pinned request repo, while only the mutation participates in the vault lock.

  ```elixir
  def download(runtime, session, asset_id, range) do
    OperationScope.with_read_request(
      runtime,
      session,
      requirement(:asset_read, asset_id),
      fn repo ->
        with {:ok, object} <- runtime.assets.authorized_object(repo, asset_id),
             {:ok, lease} <-
               runtime.custodian.lease(lease_request(session, object)) do
          runtime.authenticated_reader.read(lease, range)
        end
      end
    )
  end

  def cleanup(context, envelope) do
    context.transact.([], fn repo ->
      with :ok <-
             Authorize.check_job(context.authorization, repo, envelope) do
        # Commits pending_delete -> deleted and, only for a newly orphaned
        # object, atomically appends a separate object_cleanup outbox event
        # for the named least-privilege cleanup system principal.
        context.assets.complete_logical_delete(repo, envelope)
      end
    end)
  end

  def object_cleanup(context, envelope) do
    ObjectLock.with_exclusive(
      context.repo_handle,
      envelope.object_id,
      fn ->
        with {:ok, %{object_ref: _} = deletion} <-
               context.transact.([], fn repo ->
                 with :ok <-
                        Authorize.check_job(
                          context.authorization,
                          repo,
                          envelope
                        ) do
                   context.assets.claim_orphan_delete(repo, envelope)
                 end
               end),
             :ok <- context.storage.delete(deletion.object_ref),
             {:ok, object} <-
               context.transact.([], fn repo ->
                 with :ok <-
                        Authorize.check_job(
                          context.authorization,
                          repo,
                          envelope
                        ) do
                   context.assets.acknowledge_object_deleted(repo, deletion)
                 end
               end) do
          {:ok, object}
        else
          {:ok, :retained} -> {:ok, :noop}
          other -> other
        end
      end
    )
  end
  ```

  The physical-cleanup envelope uses the named least-privilege cleanup system
  principal scoped to that vault/object; it retains the owner's operation as
  causation/audit context but does not impersonate the owner.
  `claim_orphan_delete/2` durably records the deleting receipt; storage delete
  and acknowledgement are idempotent so a crash after byte removal resumes
  from a missing-object check.

  Test deletion of one of two assets sharing an object: the selected asset
  reaches `deleted`, the other remains downloadable, and the canonical object
  is retained. Test an orphaned asset reaches `deleted` before a transient
  physical-delete failure is retried. Race object cleanup against dedup
  finalization and prove the object is either retained with the new reference
  or deleted before finalization chooses a new canonical object; it is never
  referenced after removal.

- [ ] **Step 5: Inject failures at every storage/database boundary**

  Fail during staging, after stage sync, before/after database commit,
  before/after final rename, before state acknowledgement, during deletion,
  and during cleanup. Restart must converge with no duplicate logical
  resource, lost reference, or untracked canonical bytes.

  Upload identical plaintext after domain-key rotation: same lookup digest and
  canonical object. Upload the same bytes to a second vault: no response,
  count, or timing-visible reuse signal.

  ```elixir
  for boundary <- [
        :during_stage,
        :after_stage_sync,
        :before_database_commit,
        :after_database_commit,
        :before_finalize,
        :after_finalize,
        :before_state_ack,
        :during_delete,
        :during_cleanup
      ] do
    inject_crash(boundary)
    restart_runtime()
    assert_converged_asset(idempotency_key,
      logical_resources: 1,
      live_references: 1,
      untracked_objects: 0
    )
  end
  ```

- [ ] **Step 6: Register only the implemented jobs**

  Extend `JobDispatcher` with explicit cases for verify, finalize, logical
  cleanup, and physical object cleanup.
  Each case reauthorizes the initiating/system principal through
  `context.transact`, uses the envelope's expected revision, and records an
  effect receipt in the same committed phase as its database effect.
  Verification, finalization, and cleanup rely on `GenericWorker`'s shared
  WorkerRepo locks and never switch to RequestRepo. Do not resolve a module
  name from payload data.

  ```elixir
  def handle(context, %{job_type: "asset_verify"} = envelope),
    do: Singularity.Runtime.Assets.Verify.run(context, envelope)

  def handle(context, %{job_type: "asset_finalize"} = envelope),
    do: Singularity.Runtime.Assets.Finalize.run(context, envelope)

  def handle(context, %{job_type: "asset_cleanup"} = envelope),
    do: Singularity.Runtime.Assets.Cleanup.run(context, envelope)

  def handle(context, %{job_type: "object_cleanup"} = envelope),
    do: Singularity.Runtime.Assets.ObjectCleanup.run(context, envelope)

  def handle(_context, _envelope),
    do: {:error, Error.new(:job_failed)}
  ```

- [ ] **Step 7: Run the asset/integration gate and commit**

  Run:

  ```bash
  mix format
  mix test apps/singularity_ingest/test
  mix test apps/singularity_runtime/test/singularity/runtime/asset_vertical_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/asset_failure_recovery_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/two_vault_isolation_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/upload_session_lock_test.exs
  mix test apps/singularity_storage/test/singularity/storage/object_cleanup_concurrency_test.exs
  devenv shell -- mix singularity.test.integration
  mix compile --warnings-as-errors
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add apps/singularity_ingest apps/singularity_runtime apps/singularity_storage
  git commit -m "feat(assets): complete encrypted asset lifecycle"
  ```

## Task 13: Add deterministic technical metadata and PostgreSQL asset search

**Files:**

- Create:
  `apps/singularity_ingest/lib/singularity/ingest/metadata_extractor.ex`
- Create:
  `apps/singularity_ingest/lib/singularity/ingest/metadata/{pdf,jpeg,png}.ex`
- Create:
  `apps/singularity_ingest/test/singularity/ingest/metadata/{pdf,jpeg,png}_test.exs`
- Create:
  `test/fixtures/assets/{sample.pdf,sample.jpg,sample.png,malformed.pdf,malformed.jpg,malformed.png}`
- Create:
  `apps/singularity_retrieval/lib/singularity/retrieval/{asset_metadata_search,asset_search_query,asset_search_page}.ex`
- Create:
  `apps/singularity_retrieval/test/singularity/retrieval/asset_metadata_search_test.exs`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/assets/{extract_metadata,search}.ex`
- Modify:
  `apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex`
- Modify:
  `apps/singularity_storage/lib/singularity/storage/postgres/{asset_repository,asset_search_store}.ex`
- Modify:
  `apps/singularity_storage/lib/singularity/storage/jobs/progress.ex`
- Create:
  `apps/singularity_runtime/test/singularity/runtime/{metadata_job,metadata_unlock_resume,metadata_lock_resume,asset_search}_test.exs`
- Create:
  `apps/singularity_storage/test/singularity/storage/{asset_search_projection,asset_search_pagination}_test.exs`

- [ ] **Step 1: Write pure parser tests with small binary fixtures**

  Cover:

  - PDF `%PDF-` signature and header version only;
  - JPEG SOI plus valid start-of-frame width/height;
  - PNG signature plus IHDR width/height;
  - detected media type, exact plaintext byte size, extractor version, and
    completion time;
  - truncated, malformed, and declared-type mismatch failures.

  Explicitly assert the result has no PDF text/page count, EXIF, thumbnail,
  OCR, caption, embedding, or arbitrary metadata map.

  Pin the result shape:

  ```elixir
  assert {:ok,
          %{
            detected_media_type: "image/png",
            plaintext_bytes: 67,
            width: 1,
            height: 1,
            pdf_version: nil,
            extractor_version: 1
          }} = MetadataExtractor.extract(reader_for("sample.png"))
  ```

  Run:

  ```bash
  mix test apps/singularity_ingest/test/singularity/ingest/metadata
  ```

  Expected: failure because the parsers do not exist.

- [ ] **Step 2: Implement bounded deterministic parsers**

  Parse only the bytes needed for the approved fields, through an
  authenticated chunk-reader interface. Never request a wrapping key and
  never buffer a 512 MiB object. Return stable terminal metadata failure for
  unsupported/malformed content while preserving canonical encrypted bytes.

  The extractor dispatches on authenticated prefixes only:

  ```elixir
  def extract(reader) do
    with {:ok, prefix} <- reader.read_range.(0, 64) do
      cond do
        match?(<<"%PDF-", _::binary>>, prefix) -> PDF.extract(reader, prefix)
        match?(<<0xFF, 0xD8, _::binary>>, prefix) -> JPEG.extract(reader, prefix)
        match?(<<137, "PNG\r\n", 26, 10, _::binary>>, prefix) -> PNG.extract(reader, prefix)
        true -> {:error, Error.new(:unsupported_media_type)}
      end
    end
  end
  ```

- [ ] **Step 3: Write search contract and PostgreSQL projection tests**

  Assert:

  - query text uses `websearch_to_tsquery('simple', ...)`;
  - generated `tsvector` covers current title plus original filename;
  - media type and lifecycle are typed filters;
  - results are vault scoped and capability checked;
  - ordering is rank, `updated_at DESC`, then asset ID;
  - empty query uses update time then asset ID;
  - 50-item keyset pages do not skip or duplicate tied results;
  - each result identifies its resource version;
  - projection rebuild returns equivalent results.

  `AssetSearchStore` remains a core behavior implemented by storage.
  Retrieval validates/orchestrates and receives the adapter explicitly; it
  must not depend on `singularity_storage`.

  The query value and page contract are fixed:

  ```elixir
  assert {:ok,
          %AssetSearchQuery{
            vault_id: vault_id,
            q: "annual report",
            state: :ready,
            media_type: "application/pdf",
            limit: 50,
            cursor: nil
          }} = AssetSearchQuery.new(params)

  assert {:ok, %AssetSearchPage{items: items, next_cursor: cursor}} =
           AssetMetadataSearch.search(store, store_context, query)
  assert Enum.all?(items, &(&1.vault_id == vault_id))
  assert length(items) <= 50
  ```

- [ ] **Step 4: Implement metadata job lifecycle and unlock pause**

  `begin_or_resume_processing/3` is keyed by job/effect identity. The first
  claim advances `available -> processing`, then persists the resulting
  `processing_revision` and extractor checkpoint. A retry of the same job
  while already `processing` returns that checkpoint and revision; a
  different or stale job is a no-op. The job requests a KeyLease; if locked
  or revoked, it persists `waiting_for_unlock` without discarding the
  checkpoint and snoozes. Unlock wakes bounded work through
  `JobRunner.wake_vault/2`, and the resumed attempt acquires a new lease.

  Success persists typed metadata, rebuilds the search document, writes audit
  and effect receipt, then advances `processing -> ready` atomically. Extend
  `JobDispatcher` with only the metadata job type. The handler uses
  `GenericWorker`'s shared locks and `context.transact` phases for live
  authorization, begin/resume, checkpoint persistence, and completion; it
  never opens RequestRepo or retries with the original `available` revision.
  The begin/resume transaction commits before any plaintext read.

  ```elixir
  def run(context, envelope) do
    with {:ok, asset, checkpoint} <-
           context.transact.([], fn repo ->
             with :ok <-
                    Authorize.check_job(
                      context.authorization,
                      repo,
                      envelope
                    ) do
               context.assets.begin_or_resume_processing(repo, envelope)
             end
           end),
         {:ok, lease} <-
           context.custodian.lease(metadata_lease(envelope, asset, checkpoint)) do
      extract_steps(context, envelope, lease, checkpoint)
    else
      {:error, :waiting_for_unlock} ->
        context.transact.([], fn repo ->
          with :ok <-
                 Authorize.check_job(
                   context.authorization,
                   repo,
                   envelope
                 ) do
            context.job_progress.wait_for_unlock(repo, envelope)
          end
        end)

        {:snooze, 60}
    end
  end

  defp extract_steps(context, envelope, lease, checkpoint) do
    case context.extractor.step(lease, checkpoint) do
      {:continue, next_checkpoint} ->
        with :ok <-
               context.transact.([], fn repo ->
                 with :ok <-
                        Authorize.check_job(
                          context.authorization,
                          repo,
                          envelope
                        ) do
                   context.job_progress.persist_checkpoint(
                     repo,
                     envelope,
                     next_checkpoint
                   )
                 end
               end) do
          extract_steps(context, envelope, lease, next_checkpoint)
        end

      {:done, metadata, final_checkpoint} ->
        context.transact.([], fn repo ->
          with :ok <-
                 Authorize.check_job(
                   context.authorization,
                   repo,
                   envelope
                 ) do
            context.assets.complete_metadata(
              repo,
              envelope,
              checkpoint.processing_revision,
              metadata,
              final_checkpoint
            )
          end
        end)

      {:waiting_for_unlock, next_checkpoint} ->
        context.transact.([], fn repo ->
          with :ok <-
                 Authorize.check_job(
                   context.authorization,
                   repo,
                   envelope
                 ) do
            context.job_progress.wait_for_unlock(
              repo,
              envelope,
              next_checkpoint
            )
          end
        end)

        {:snooze, 60}

      {:error, reason, next_checkpoint} ->
        context.transact.([], fn repo ->
          with :ok <-
                 Authorize.check_job(
                   context.authorization,
                   repo,
                   envelope
                 ) do
            context.assets.record_metadata_failure(
              repo,
              envelope,
              reason,
              next_checkpoint
            )
          end
        end)
    end
  end
  ```

  Add a lock/resume test that crashes after `available -> processing`, locks
  and unlocks the vault, and crashes again after a later checkpoint commit.
  Prove the same job completes from the persisted processing revision and last
  committed checkpoint exactly once.

- [ ] **Step 5: Run parser/search/integration gates and commit**

  Run:

  ```bash
  mix format
  mix test apps/singularity_ingest/test/singularity/ingest/metadata
  mix test apps/singularity_retrieval/test
  mix test apps/singularity_runtime/test/singularity/runtime/metadata_job_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/metadata_unlock_resume_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/metadata_lock_resume_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/asset_search_test.exs
  devenv shell -- mix singularity.test.integration
  mix compile --warnings-as-errors
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add apps/singularity_ingest apps/singularity_retrieval \
    apps/singularity_runtime apps/singularity_storage test/fixtures/assets
  git commit -m "feat(retrieval): add asset metadata search"
  ```

## Task 14: Implement encrypted backup, maintenance restore, and integrity audit

**Files:**

- Create:
  `apps/singularity_storage/lib/singularity/storage/backup/{manifest,bundle_writer,bundle_reader,exporter,restorer,reconciler,integrity_audit}.ex`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/{backup_vault,backup_key_lease,restore_vault,integrity_audit}.ex`
- Create:
  `apps/singularity_runtime/lib/mix/tasks/{singularity.backup,singularity.restore}.ex`
- Create:
  `apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex`
- Modify: `mix.exs`
- Create:
  `apps/singularity_storage/test/singularity/storage/{backup_restore,backup_concurrency,restore_reconciliation,integrity_audit}_test.exs`
- Create:
  `apps/singularity_runtime/test/singularity/runtime/{backup_vault,backup_key_lease,restore_vault}_test.exs`
- Modify:
  `apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex`
- Modify:
  `apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex`
- Modify:
  `apps/singularity_storage/lib/singularity/storage/jobs/progress.ex`
- Modify: `config/runtime.exs`

- [ ] **Step 1: Write the restore oracle before the exporter**

  `mix singularity.test.restore` must create a source database/root and a
  separate empty destination database/root, print their generated names,
  perform one-vault encrypted backup/restore, and always clean both.

  The oracle asserts:

  - exact live resource, version, asset, object, metadata, and tombstone
    counts;
  - source audit count plus exactly
    `backup.restore_completed`,
    `credential.rewrapped_after_restore`, and
    `integrity.audit_completed`;
  - exact manifest inventory count;
  - every ciphertext hash and every unlocked plaintext hash;
  - zero unreconciled stale jobs;
  - equivalent metadata-search results.

  The final assertions are literal:

  ```elixir
  assert destination.counts == source.counts
  assert destination.audit_count == source.audit_count + 3
  assert destination.added_audit_operations ==
           ~w[
             backup.restore_completed
             credential.rewrapped_after_restore
             integrity.audit_completed
           ]
  assert destination.manifest_object_count == source.live_object_count
  assert destination.ciphertext_hashes == source.ciphertext_hashes
  assert destination.plaintext_hashes == source.plaintext_hashes
  assert destination.unreconciled_jobs == 0
  assert destination.search_results == source.search_results
  ```

  Extend the umbrella task environment:

  ```elixir
  preferred_cli_env: [
    "singularity.test.integration": :test,
    "singularity.test.restore": :test
  ]
  ```

  Run:

  ```bash
  devenv shell -- mix singularity.test.restore
  ```

  Expected: failure because backup/restore tasks do not exist.

- [ ] **Step 2: Write bundle-format and passphrase tests**

  Use a versioned, length-framed streaming bundle encrypted directly with the
  chunked AEAD codec. Assert:

  - no plaintext tar, SQL, JSON, key, or object temp file appears;
  - manifest authentication fails before import on wrong passphrase,
    truncation, reordering, or altered inventory;
  - backup KDF parameters and recovery-wrapper labels are independent of
    account/vault wrapping;
  - CLI password/passphrase arguments are rejected;
  - no-echo prompt or inherited file descriptor is accepted;
  - raw passphrase and derived backup key never appear in the job envelope,
    outbox, database rows, logs, or inspected errors;
  - injected request-transaction, audit, and commit failures leave no pending
    manifest, outbox row, active `BackupKeyLease`, or orphaned in-memory key;
  - injected post-commit activation failure leaves the durable pending
    manifest waiting for re-entry but creates no usable key capability and
    wakes no job;
  - a runtime restart loses the in-memory lease, the job waits, operator
    re-entry of the passphrase verifies the recovery wrapper, and the same
    pending backup resumes without accepting a partial bundle.

  The framed record contract is:

  ```elixir
  <<record_type::16, payload_length::64, payload::binary-size(payload_length)>>
  ```

  Every frame is input to chunked AEAD; the final authenticated manifest
  contains version, vault IDs, snapshot ID, outbox high-water mark, exact
  ordered inventory, and hashes.

- [ ] **Step 3: Test the exclusive backup cut under concurrency**

  Start an upload, metadata effect, and physical cleanup while backup requests
  the exclusive vault lock. Prove it waits for already-running shared
  operations, blocks new mutations, makes outbox claims skip the vault, records
  a repeatable-read snapshot plus outbox high-water mark, copies exactly its
  immutable inventory, seals the manifest, then releases waiting work.

  Inject failure in copy and seal paths; the exclusive lock must release in
  every `after` path and an incomplete bundle must never be accepted.

  ```elixir
  worker = start_shared_mutation(vault_id)
  backup = Task.async(fn -> BackupVault.run(runtime, request) end)
  assert_task_blocked(backup)
  release_shared_mutation(worker)
  assert_receive {:backup_cut, cut}
  assert {:skip_locked, ^vault_id} = claim_outbox_during_cut(vault_id)
  assert {:ok, manifest} = Task.await(backup)
  assert manifest.outbox_high_water_mark == cut.outbox_high_water_mark
  ```

- [ ] **Step 4: Implement streaming export**

  Export the vault-scoped logical rows, wrapped-key metadata, immutable
  ciphertext inventory, integrity hashes, snapshot identity, and outbox cut.
  Request-time setup derives a dedicated backup key from an operator
  passphrase while the vault is unlocked. Before persistence,
  `prepare_backup_key/3` creates a monitored, short-TTL pending custody
  reference bound to the server-generated manifest ID. It cannot encrypt,
  issue a `BackupKeyLease`, or wake work. In one scoped request transaction
  runtime creates a pending manifest containing only KDF salt/parameters,
  destination reference, authenticated recovery-wrapper ciphertext, and that
  opaque reference; the same transaction appends its audit and outbox row.
  The outbox/job envelope contains only the pending manifest ID. Never use the
  account password as backup passphrase, and never persist the passphrase or
  derived key.

  `BackupVault.request/4` performs that setup through
  `OperationScope.with_shared_request/4`, so authorization, recovery-wrapper
  validation, pending-manifest insertion, audit, and outbox append use the
  pinned request connection under the shared vault lock. The transaction
  returns `{:after_commit, callback}`. While the same locks remain held, that
  callback atomically activates the pending custody reference. A transaction,
  audit, or commit failure never invokes activation and an `after` path
  discards the pending key. If activation fails after the manifest commits,
  the request reports the durable pending manifest as
  `waiting_for_backup_key`; no usable capability exists and no job is woken.

  The setup shape is literal:

  ```elixir
  def request(runtime, session, passphrase, destination_ref) do
    manifest_id = runtime.ids.generate()

    with {:ok, prepared} <-
           runtime.backup_crypto.prepare(
             runtime.custodian,
             session,
             manifest_id,
             passphrase
           ) do
      try do
        OperationScope.with_shared_request(
          runtime,
          session,
          requirement(:backup_create),
          fn repo ->
            with {:ok, manifest} <-
                   runtime.backups.insert_pending_and_enqueue(
                     repo,
                     manifest_id,
                     destination_ref,
                     prepared.public_metadata,
                     prepared.opaque_ref
                   ) do
              {:after_commit,
               fn ->
                 case runtime.custodian.activate_backup_key(prepared.opaque_ref) do
                   :ok -> {:ok, manifest}
                   {:error, _} -> {:ok, %{manifest | state: :waiting_for_backup_key}}
                 end
               end}
            end
          end
        )
      after
        runtime.custodian.discard_pending(prepared.opaque_ref)
      end
    end
  end
  ```

  The durable `"backup"` handler already owns GenericWorker's exclusive
  WorkerRepo vault lock and shared authorization lock. It opens the one
  repeatable-read `context.transact` phase that records the cut, streams the
  immutable inventory, seals the bundle, and acknowledges the manifest. The
  custodian exposes
  streaming encrypt/authenticate operations through the opaque lease but
  never returns the backup key to the handler or storage adapter.

  ```elixir
  def run(context, envelope) do
    with {:ok, pending} <-
           context.transact.([], fn repo ->
             with :ok <-
                    Authorize.check_job(
                      context.authorization,
                      repo,
                      envelope
                    ) do
               context.backups.load_pending(repo, envelope.pending_manifest_id)
             end
           end),
         {:ok, crypto} <-
           context.custodian.backup_crypto(
             pending.id,
             pending.backup_key_lease_id
           ),
         {:ok, manifest} <-
           context.transact.([isolation: :repeatable_read], fn repo ->
             with :ok <-
                    Authorize.check_job(
                      context.authorization,
                      repo,
                      envelope
                    ),
                  {:ok, cut} <-
                    context.exporter.snapshot_cut(repo, envelope.vault_id),
                  {:ok, sealed} <-
                    context.bundle_writer.stream(
                      pending.destination_ref,
                      context.exporter.records(repo, cut),
                      context.object_storage.stream_inventory(cut),
                      manifest(cut, pending.recovery_wrapper),
                      crypto
                    ) do
               context.backups.acknowledge_sealed(
                 repo,
                 pending,
                 cut,
                 sealed
               )
             end
           end) do
      {:ok, manifest}
    else
      {:error, :lease_missing} ->
        context.transact.([], fn repo ->
          with :ok <-
                 Authorize.check_job(
                   context.authorization,
                   repo,
                   envelope
                 ) do
            context.job_progress.wait_for_backup_key(repo, envelope)
          end
        end)

        {:snooze, 60}
    end
  end
  ```

  If restart or timeout destroys the lease, the job remains
  `waiting_for_backup_key`. Operator re-entry derives the same key from the
  persisted salt, authenticates the pending recovery wrapper, and calls
  `prepare_backup_key/3` for a new unusable opaque reference. A live shared
  request transaction replaces the reference and records the re-entry audit;
  only its after-commit callback activates the reference, cleans any
  incomplete destination, and wakes the job. Transaction/audit/commit failure
  discards it. Re-entry may use `requires_unlocked?: false` only if it verifies
  the recovery wrapper before preparing custody. A mismatched passphrase
  changes no durable state. Partial bundles are idempotently deleted or
  restarted and never marked sealed.

- [ ] **Step 5: Implement authenticated two-pass restore**

  Restore runs only in explicit maintenance mode with endpoint mutations,
  dispatcher, and workers disabled. First authenticate the complete bundle
  and inventory without importing. Then import into an empty destination
  through `MigrationRepo`, restore ciphertext, unwrap the recovery copy, take
  a new owner password through secret input, and atomically replace credential
  plus vault wrapper.

  Verify ciphertext while locked, reconcile work against the recorded cut,
  discard stale destructive jobs, unlock the test vault, verify every
  authenticated plaintext, rebuild search, and run integrity audit before
  enabling runtime work.

  ```elixir
  def run(context, request) do
    with :ok <- require_maintenance_mode(context),
         :ok <- require_empty_destination(context),
         {:ok, verified} <-
           context.bundle_reader.authenticate_all(request.source, request.passphrase),
         {:ok, imported} <- context.restorer.import(context.migration_repo, verified),
         {:ok, rewrapped} <- context.restorer.rewrap_owner(imported, request.new_password),
         :ok <- context.integrity.verify_ciphertext(rewrapped),
         :ok <- context.reconciler.reconcile(rewrapped),
         :ok <- context.integrity.verify_plaintext_and_search(rewrapped) do
      {:ok, rewrapped.manifest}
    end
  end
  ```

- [ ] **Step 6: Register backup/maintenance jobs and run both gates**

  Register only backup and integrity-audit job types in `JobDispatcher`.
  Maintenance work uses a named least-privilege system principal scoped to the
  target vault and operation.

  ```elixir
  def handle(context, %{job_type: "backup"} = envelope),
    do: Singularity.Runtime.BackupVault.run(context, envelope)

  def handle(context, %{job_type: "integrity_audit"} = envelope),
    do: Singularity.Runtime.IntegrityAudit.run(context, envelope)
  ```

  Run:

  ```bash
  mix format
  mix test apps/singularity_storage/test/singularity/storage/backup_restore_test.exs
  mix test apps/singularity_storage/test/singularity/storage/backup_concurrency_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/backup_key_lease_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/restore_vault_test.exs
  devenv shell -- mix singularity.test.integration
  devenv shell -- mix singularity.test.restore
  mix compile --warnings-as-errors
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add apps/singularity_storage apps/singularity_runtime config mix.exs
  git commit -m "feat(backup): add encrypted backup and restore"
  ```

## Task 15: Complete audit, redaction, telemetry, and secret-canary coverage

**Files:**

- Create:
  `apps/singularity_runtime/lib/singularity/runtime/observability/{telemetry,logger_metadata,redactor}.ex`
- Create:
  `apps/singularity_runtime/test/singularity/runtime/{audit_acceptance,telemetry,observability_redaction,secret_canary}_test.exs`
- Create:
  `apps/singularity_storage/test/singularity/storage/audit_test.exs`
- Create:
  `apps/singularity_web/test/singularity/architecture/observability_contract_test.exs`
- Modify:
  `apps/singularity_runtime/lib/singularity/runtime/application.ex`
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`

- [ ] **Step 1: Write the complete immutable-audit acceptance matrix**

  Assert one event for authentication success/failure, authorization denial,
  cross-vault denial, unlock/lock, upload/download, integrity verification,
  sensitive read, logical delete, physical cleanup, backup, restore,
  integrity audit, credential/key rewrap/rotation, capability change, and
  policy change.

  Every event has operation, result, correlation ID, timestamp, redacted
  target, and exactly one actor form:

  - principal plus vault;
  - named system principal plus vault;
  - anonymous keyed fingerprint plus null vault.

  ```elixir
  for operation <- @required_operations do
    event = audit_event!(operation)
    assert event.result in ["allowed", "denied", "completed", "failed"]
    assert event.correlation_id
    assert %DateTime{} = event.occurred_at
    assert actor_shape_count(event) == 1
    refute contains_secret?(event.metadata)
  end
  ```

- [ ] **Step 2: Seed distinct server-side secret canaries**

  Seed password, audit-fingerprint secret, upload token, CSRF token, vault key,
  domain key, domain-dedup key, DEK, object key, and backup-passphrase values.
  At this gate assert they are absent from supported `[:singularity, ...]`
  telemetry measurements and metadata, supported final JSON records
  originating from `LoggerMetadata.log/3`, audit metadata, raised exception text,
  persistence-adapter arguments, and runtime return values except the one
  documented upload-grant callback. Free-form, OTP/crash,
  framework/dependency, and combined raw Logger outputs are unsupported and
  sensitive; selected capture checks remain defense in depth.

  The upload-token canary may exist only in that callback and later XHR
  request header. The CSRF canary's browser-only allowances are added after
  Phoenix exists.

  ```elixir
  @canaries %{
    password: "CANARY_PASSWORD_8e4a",
    audit_fingerprint_secret: "CANARY_AUDIT_FINGERPRINT_SECRET_32B",
    upload_token: "CANARY_UPLOAD_TOKEN_6b21",
    csrf: "CANARY_CSRF_c091",
    vault_key: "CANARY_VAULT_KEY_d112",
    domain_key: "CANARY_DOMAIN_KEY_a477",
    domain_dedup_key: "CANARY_DOMAIN_DEDUP_KEY_b579",
    dek: "CANARY_DEK_f862",
    object_key: "CANARY_OBJECT_KEY_f862",
    backup_passphrase: "CANARY_BACKUP_1d0c"
  }

  for {kind, canary} <- @canaries do
    refute canary in supported_logger_metadata_json_records
    refute canary in encoded_audit
    refute canary in encoded_telemetry
    refute canary in inspected_errors
    assert allowed_occurrences(kind, canary, runtime_results) ==
             expected_allowance(kind)
  end
  ```

- [ ] **Step 3: Add default-deny application logging and telemetry**

  Supported final JSON records originating from `LoggerMetadata.log/3` may
  include correlation and permitted opaque entity IDs, never raw identifiers,
  content, credentials, tokens, filesystem paths, or keys. The boundary
  default-denies both structured message and metadata fields before the
  configured `LoggerJSON` formatter and redactor produce the final record.
  Free-form Logger messages, OTP/crash reports, framework/dependency logs, and
  the combined raw Logger stream remain unsupported and sensitive. Telemetry
  metadata is redacted before telemetry emission.

  `Singularity.Runtime.Observability.Telemetry` and the bounded RLS-denial
  emitter in `Singularity.Storage.SafeSQL` are the only direct emitters. The
  raw Oban source remains adapter-only: it may yield a bounded safe
  `[:singularity, ...]` event but is not part of the supported contract.
  Production reporters, exporters, and persistence handlers must not subscribe
  to raw dependency events.

  Emit metrics for upload bytes/latency, dedup, stage age, integrity failure,
  outbox lag, job retry/failure, authentication-audit write failure, RLS
  denial, unlock, backup/restore duration, and orphan cleanup. Telemetry
  handlers are supervised; domain code remains independent.

  ```elixir
  @redacted_keys ~w[
    password passphrase token csrf audit_fingerprint_secret vault_key
    domain_key dek plaintext authorization cookie path
  ]

  def redact(term), do: redact(term, MapSet.new(@redacted_keys))

  def emit(event, measurements, metadata) do
    :telemetry.execute(
      [:singularity | event],
      measurements,
      Redactor.redact(metadata)
    )
  end
  ```

- [ ] **Step 4: Run the observability gate and commit**

  Run:

  ```bash
  mix format
  mix test apps/singularity_runtime/test/singularity/runtime/audit_acceptance_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/telemetry_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/observability_redaction_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs
  devenv shell -- mix singularity.test.integration
  mix compile --warnings-as-errors
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix test apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add apps/singularity_runtime apps/singularity_storage config \
    apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
  git commit -m "feat(observability): audit and redact sensitive operations"
  ```

## Task 16: Build the Phoenix shell and runtime-only web boundary

**Files:**

- Modify: `apps/singularity_web/mix.exs`
- Modify: `.formatter.exs`
- Create:
  `apps/singularity_web/lib/singularity/web/application.ex`
- Create:
  `apps/singularity_web/lib/singularity/web/{endpoint,router}.ex`
- Create:
  `apps/singularity_web/lib/singularity/web/auth.ex`
- Create:
  `apps/singularity_web/lib/singularity/web/components/{core_components,layouts}.ex`
- Create:
  `apps/singularity_web/lib/singularity/web/components/layouts/{root,app}.html.heex`
- Create:
  `apps/singularity_web/lib/singularity/web/controllers/{session_controller,upload_controller,download_controller,error_html,error_json}.ex`
- Create:
  `apps/singularity_web/lib/singularity/web/controllers/error_html/404.html.heex`
- Create:
  `apps/singularity_web/lib/singularity/web/live/{login_live,unlock_live,assets_live,activity_live,audit_live,backups_live,settings_live}.ex`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/api.ex`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/dto/{session,asset_summary,search_page,upload_grant}.ex`
- Create:
  `apps/singularity_web/test/support/{conn_case,live_case}.ex`
- Create:
  `apps/singularity_web/test/singularity/web/{router,session_controller,upload_controller,download_controller}_test.exs`
- Create:
  `apps/singularity_web/test/singularity/web/live/{login_live,unlock_live,assets_live}_test.exs`
- Modify: `config/config.exs`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`

- [ ] **Step 1: Write route and boundary tests**

  Add exactly:

  ```text
  GET/POST /login
  GET/POST /vault/unlock
  GET      /assets
  PUT      /api/v1/uploads/:grant_id
  GET      /api/v1/assets/:asset_id/content
  GET      /activity
  GET      /audit
  GET      /backups
  GET      /settings
  DELETE   /logout
  ```

  Locked routes redirect to unlock; unauthenticated routes redirect to login.
  The upload/download controllers return only the stable status/error
  contracts. The architecture test must still reject any web reference to
  core, domains, storage, ingest, or retrieval.

  ```elixir
  test "web production code depends only on runtime" do
    forbidden = ~r/Singularity\.(Core|Domains|Storage|Ingest|Retrieval)/

    refute Enum.any?(web_source_files(), fn path ->
             Regex.match?(forbidden, File.read!(path))
           end)
  end
  ```

  Run:

  ```bash
  mix test apps/singularity_web/test/singularity/web/router_test.exs
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  ```

  Expected: route failures because Phoenix is not configured.

- [ ] **Step 2: Add Phoenix dependencies and a manual minimal shell**

  Convert the existing app in place rather than deleting the architecture
  test. Add Endpoint, Bandit, PubSub, session signing/encryption, CSRF, secure
  headers, error rendering, and LiveView. Production cookies are `HttpOnly`,
  `Secure`, and `SameSite=Lax`.

  `Singularity.Runtime.Api` is the only web dependency seam and returns
  runtime DTOs/maps. The cookie stores only an opaque session ID. HTML,
  assigns, JSON, and LiveView events never contain key material or reusable
  API credentials.

  Add:

  ```elixir
  {:phoenix, "~> 1.8"}
  {:phoenix_html, "~> 4.1"}
  {:phoenix_live_view, "~> 1.2"}
  {:bandit, "~> 1.12"}
  {:floki, ">= 0.36.0", only: :test}
  ```

  The router boundary is:

  ```elixir
  scope "/", Singularity.Web do
    pipe_through :browser
    live "/login", LoginLive
    post "/login", SessionController, :create
  end

  scope "/", Singularity.Web do
    pipe_through [:browser, :browser_authenticated]
    post "/vault/unlock", SessionController, :unlock
    delete "/logout", SessionController, :delete

    live_session :authenticated,
      on_mount: [{Auth, :require_authenticated}] do
      live "/vault/unlock", UnlockLive
    end
  end

  scope "/", Singularity.Web do
    pipe_through [
      :browser,
      :browser_authenticated,
      :browser_vault_unlocked
    ]

    live_session :unlocked,
      on_mount: [{Auth, :require_authenticated}, {Auth, :require_unlocked}] do
      live "/assets", AssetsLive
      live "/activity", ActivityLive
      live "/audit", AuditLive
      live "/backups", BackupsLive
      live "/settings", SettingsLive
    end
  end

  scope "/api/v1", Singularity.Web do
    pipe_through [:api_session, :api_authenticated, :api_vault_unlocked]
    put "/uploads/:grant_id", UploadController, :update
    get "/assets/:asset_id/content", DownloadController, :show
  end
  ```

  Both authenticated pipelines resolve only the opaque session. The browser
  variants redirect unauthenticated users to `/login` and locked users to
  `/vault/unlock`. The API variants never redirect: they return the stable
  `401 unauthenticated` or `403 vault_locked` JSON contract. LiveViews repeat
  browser checks in the named `live_session` on-mount hooks so websocket
  reconnects cannot bypass the router plugs. Route tests cover both browser
  redirects and API JSON status/body behavior.

- [ ] **Step 3: Implement session and vault pages**

  Phoenix owns login, logout, unlock, lock state, navigation, activity, audit,
  backup, and settings chrome. It establishes runtime session context for
  every request and performs capability checks before rendering data.

  Web-safe data is constructed in runtime:

  ```elixir
  defmodule Singularity.Runtime.DTO.AssetSummary do
    @enforce_keys ~w[
      id resource_version_id title original_filename detected_media_type
      state state_revision label progress failure updated_at
    ]a
    defstruct @enforce_keys
  end

  def session_from_cookie(opaque_id),
    do: configured_runtime().resolve_session(opaque_id)
  ```

- [ ] **Step 4: Implement the streaming upload/download controllers**

  Before accepting bytes, upload atomically consumes/rechecks grant, session,
  vault unlock, epoch, expiry, CSRF, token digest, declared size/type, and
  `Content-Length`. Stream `Plug.Conn.read_body/2` chunks into runtime; check
  final observed bytes. Cancellation/interruption marks the stage abandoned.

  Return the exact design status mapping, including `201`, `400`, `401`,
  `403`, `409`, `410`, `413`, `415`, `422`, and `503`. Redact upload/CSRF
  headers from logs. Download delegates range authorization and authenticated
  reads to runtime; it never opens a local path.

  The controller streams bounded body chunks:

  ```elixir
  def update(conn, %{"grant_id" => grant_id}) do
    case RuntimeAPI.begin_upload(
           session(conn),
           grant_id,
           request_meta(conn),
           self()
         ) do
      {:ok, upload} ->
        try do
          case stream_body(conn, upload) do
            {:ok, result, conn} ->
              conn
              |> put_status(:created)
              |> json(%{
                ok: true,
                assetId: result.asset_id,
                state: "uploaded",
                stateRevision: result.state_revision
              })

            {:error, error, conn} ->
              render_upload_error(conn, error)
          end
        after
          RuntimeAPI.end_upload(upload)
        end

      {:error, error} ->
        render_upload_error(conn, error)
    end
  end

  defp stream_body(conn, upload) do
    case Plug.Conn.read_body(conn, length: 1_048_576, read_length: 1_048_576) do
      {:more, chunk, conn} ->
        case RuntimeAPI.append_upload(upload, chunk) do
          :ok -> stream_body(conn, upload)
          {:error, error} -> {:error, error, conn}
        end

      {:ok, chunk, conn} ->
        case RuntimeAPI.finish_upload(upload, chunk) do
          {:ok, result} -> {:ok, result, conn}
          {:error, error} -> {:error, error, conn}
        end

      {:error, reason} ->
        RuntimeAPI.abandon_upload(upload, reason)
        {:error, :storage_unavailable, conn}
    end
  end
  ```

  `finish_upload/2`, `append_upload/2`, `abandon_upload/2`, and
  `end_upload/1` receive only the opaque runtime handle. `end_upload/1` is
  idempotent after success and guarantees abandonment after controller errors.

- [ ] **Step 5: Run Phoenix boundary tests and commit**

  Run:

  ```bash
  mix deps.get
  mix format
  mix test apps/singularity_web/test/singularity/web
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix compile --warnings-as-errors
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add .formatter.exs apps/singularity_web apps/singularity_runtime config \
    mix.lock
  git commit -m "feat(web): add Phoenix vault shell"
  ```

## Task 17: Add DuskmoonBundler and the React AssetWorkspace App-Clip

**Files:**

- Modify: `.formatter.exs`
- Modify: `.gitignore`
- Modify: `mix.exs`
- Modify: `mix.lock`
- Modify:
  `docs/superpowers/specs/2026-07-18-foundation-asset-vertical-design.md`
- Modify:
  `docs/superpowers/plans/2026-07-18-foundation-asset-vertical.md`
- Modify:
  `apps/singularity_core/lib/singularity/core/asset_search_store.ex`
- Modify: `apps/singularity_core/test/singularity/core/ports_test.exs`
- Modify: `apps/singularity_domains/lib/singularity/domains/assets/repository.ex`
- Modify: `apps/singularity_domains/test/singularity/domains/assets_test.exs`
- Modify: `apps/singularity_domains/test/support/fake/asset_repository.ex`
- Modify: `apps/singularity_ingest/lib/singularity/ingest/idempotency.ex`
- Modify: `apps/singularity_ingest/lib/singularity/ingest/upload_request.ex`
- Modify: `apps/singularity_ingest/test/singularity/ingest/idempotency_test.exs`
- Modify:
  `apps/singularity_ingest/test/singularity/ingest/upload_request_test.exs`
- Modify:
  `apps/singularity_retrieval/lib/singularity/retrieval/asset_metadata_search.ex`
- Modify:
  `apps/singularity_retrieval/test/singularity/retrieval/asset_metadata_search_test.exs`
- Modify: `apps/singularity_runtime/lib/singularity/runtime/api.ex`
- Modify: `apps/singularity_runtime/lib/singularity/runtime/application.ex`
- Create: `apps/singularity_runtime/lib/singularity/runtime/asset_events.ex`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/assets/cancel_upload_grant.ex`
- Modify:
  `apps/singularity_runtime/lib/singularity/runtime/assets/create_upload_grant.ex`
- Modify: `apps/singularity_runtime/lib/singularity/runtime/assets/search.ex`
- Modify: `apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex`
- Modify: `apps/singularity_runtime/test/singularity/runtime/api_test.exs`
- Modify:
  `apps/singularity_runtime/test/singularity/runtime/application_test.exs`
- Create:
  `apps/singularity_runtime/test/singularity/runtime/asset_events_test.exs`
- Modify:
  `apps/singularity_runtime/test/singularity/runtime/asset_failure_recovery_test.exs`
- Modify:
  `apps/singularity_runtime/test/singularity/runtime/asset_search_test.exs`
- Modify:
  `apps/singularity_runtime/test/singularity/runtime/asset_vertical_test.exs`
- Create:
  `apps/singularity_runtime/test/singularity/runtime/cancel_upload_grant_test.exs`
- Modify:
  `apps/singularity_runtime/test/singularity/runtime/create_upload_grant_test.exs`
- Create:
  `apps/singularity_runtime/test/singularity/runtime/job_dispatcher_asset_events_test.exs`
- Modify:
  `apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs`
- Modify:
  `apps/singularity_storage/lib/singularity/storage/postgres/asset_deletion_repository.ex`
- Modify:
  `apps/singularity_storage/lib/singularity/storage/postgres/asset_repository.ex`
- Modify:
  `apps/singularity_storage/lib/singularity/storage/postgres/asset_search_store.ex`
- Modify:
  `apps/singularity_storage/lib/singularity/storage/schema/content/upload_grant.ex`
- Create:
  `apps/singularity_storage/priv/repo/migrations/20260729000100_retire_superseded_upload_grants.exs`
- Modify:
  `apps/singularity_storage/test/singularity/storage/asset_search_pagination_test.exs`
- Modify:
  `apps/singularity_storage/test/singularity/storage/asset_search_projection_test.exs`
- Create:
  `apps/singularity_storage/test/singularity/storage/asset_search_store_fetch_test.exs`
- Modify:
  `apps/singularity_storage/test/singularity/storage/asset_stage_abandonment_test.exs`
- Modify: `apps/singularity_storage/test/singularity/storage/migrations_test.exs`
- Modify:
  `apps/singularity_storage/test/singularity/storage/orphan_cleanup_test.exs`
- Create:
  `apps/singularity_storage/test/singularity/storage/server_owned_upload_grant_test.exs`
- Modify: `apps/singularity_web/mix.exs`
- Modify:
  `apps/singularity_web/lib/singularity/web/components/layouts/app.html.heex`
- Modify:
  `apps/singularity_web/lib/singularity/web/components/layouts/root.html.heex`
- Modify: `apps/singularity_web/lib/singularity/web/endpoint.ex`
- Modify:
  `apps/singularity_web/lib/singularity/web/live/assets_live.ex`
- Modify:
  `apps/singularity_web/test/singularity/web/authentication_test.exs`
- Create:
  `apps/singularity_web/test/singularity/web/asset_toolchain_contract_test.exs`
- Create: `apps/singularity_web/test/singularity/web/assets_live_test.exs`
- Modify: `apps/singularity_web/test/singularity/web/live_shell_test.exs`
- Create:
  `apps/singularity_web/test/singularity/web/root_layout_assets_test.exs`
- Modify: `apps/singularity_web/test/support/conn_case.ex`
- Create: `apps/singularity_web/assets/css/app.css`
- Create: `apps/singularity_web/assets/js/app.ts`
- Create: `apps/singularity_web/assets/js/hooks.js`
- Create:
  `apps/singularity_web/assets/js/clips/mount_asset_workspace.tsx`
- Create:
  `apps/singularity_web/assets/js/asset_workspace/AssetWorkspace.tsx`
- Create: `apps/singularity_web/assets/js/asset_workspace/contracts.ts`
- Create: `apps/singularity_web/assets/js/asset_workspace/state.ts`
- Create: `apps/singularity_web/assets/js/asset_workspace/theme.ts`
- Create: `apps/singularity_web/assets/js/asset_workspace/upload.ts`
- Create: `apps/singularity_web/assets/test/asset_workspace.test.tsx`
- Create: `apps/singularity_web/assets/test/mount_asset_workspace.test.tsx`
- Create: `apps/singularity_web/assets/test/state.test.ts`
- Create: `apps/singularity_web/assets/test/theme.test.ts`
- Create: `apps/singularity_web/assets/test/upload.test.ts`
- Create: `package.json`
- Create: `package-lock.json`
- Create: `tsconfig.json`
- Create: `vitest.config.ts`
- Modify: `config/config.exs`
- Modify: `config/dev.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Configure one named DuskmoonBundler profile**

  Use `:singularity_web` consistently in config, endpoint watchers, dev
  server, build/verification tasks, and static helpers. Set:

  - root: `apps/singularity_web/assets`;
  - entry: `apps/singularity_web/assets/js/app.ts`;
  - CSS entry: `apps/singularity_web/assets/css/app.css`;
  - output: `apps/singularity_web/priv/static/assets`;
  - resolve roots: umbrella `apps` and `deps`;
  - React JSX/TypeScript, Tailwind, HMR, manifest, and preload metadata.

  Add DuskmoonBundler only. Do not add `phoenix_duskmoon`,
  `@duskmoon-dev/core`, or another UI component library.

  ```elixir
  # apps/singularity_web/mix.exs
  {:duskmoon_bundler_runtime, "~> 9.9.7"}
  {:duskmoon_bundler, "~> 9.9.7", runtime: Mix.env() in [:dev, :test]}

  # config/config.exs
  config :duskmoon_bundler, :singularity_web,
    root: "apps/singularity_web/assets",
    entry: "apps/singularity_web/assets/js/app.ts",
    outdir: "apps/singularity_web/priv/static/assets",
    resolve_dirs: ["apps", "deps"],
    tailwind: [
      css: "apps/singularity_web/assets/css/app.css",
      sources: [
        %{base: "apps/singularity_web/lib", pattern: "**/*.{ex,exs,heex}"},
        %{base: "apps/singularity_web/assets", pattern: "**/*.{css,js,ts,jsx,tsx}"}
      ]
    ],
    server: [
      watch_dirs: ["apps/singularity_web/lib", "apps/singularity_web/assets"]
    ]

  # config/dev.exs
  config :singularity_web, Singularity.Web.Endpoint,
    watchers: [
      duskmoon_bundler:
        {Mix.Tasks.DuskmoonBundler.Dev, :run, [["singularity_web"]]}
    ]
  ```

  DuskmoonBundler 9.9.7 must also start in `:test`: `config/test.exs`
  enables code reloading, which starts the DevServer/HMR path exercised by the
  web tests. Floki remains a direct test-only dependency. Although the
  application-owned LazyHTML call sites are also tests, DuskmoonBundler 9.9.7
  declares LazyHTML for all environments, so Mix requires the direct LazyHTML
  declaration to use the same unrestricted environment scope.

  In the endpoint and root layout:

  ```elixir
  if code_reloading? do
    plug DuskmoonBundler.DevServer,
      profile: :singularity_web,
      root: "apps/singularity_web/assets/js",
      prefix: "/assets/js"
  end
  ```

  ```heex
  <%= DuskmoonBundler.Preload.tags(
    Singularity.Web.Endpoint,
    "/assets/js/app.js",
    profile: :singularity_web
  ) %>
  <link
    phx-track-static
    rel="stylesheet"
    href={DuskmoonBundler.static_path(
      Singularity.Web.Endpoint,
      "/assets/css/app.css",
      profile: :singularity_web
    )}
  />
  <script
    defer
    phx-track-static
    type="module"
    src={DuskmoonBundler.static_path(
      Singularity.Web.Endpoint,
      "/assets/js/app.js",
      profile: :singularity_web
    )}
  >
  </script>
  ```

  Register `DuskmoonBundler.Formatter` in `.formatter.exs` only for
  `apps/singularity_web/assets/**/*.{js,ts,jsx,tsx}`; JSON and CSS remain
  outside that formatter's supported inputs. Add these aliases to the umbrella
  root `mix.exs`, not the child app:

  ```elixir
  "assets.build": ["duskmoon_bundler.build singularity_web --tailwind"],
  "assets.deploy": [
    "duskmoon_bundler.build singularity_web --tailwind",
    "phx.digest"
  ]
  ```

- [ ] **Step 2: Create and lock the npm workspace**

  Runtime dependencies are React and ReactDOM. Development dependencies are
  TypeScript, React types, Vitest, jsdom, Playwright test, and axe Playwright.
  Use `mix npm.install` to create `package-lock.json`; thereafter use
  `mix npm.install --frozen`. Do not add npm/yarn/Bun shell workflows or
  package lifecycle browser downloads.

  The root manifest has this script contract:

  ```json
  {
    "name": "singularity",
    "private": true,
    "scripts": {
      "test:js": "vitest run",
      "test:e2e": "playwright test"
    },
    "dependencies": {
      "react": "^19.2.0",
      "react-dom": "^19.2.0"
    },
    "devDependencies": {
      "@axe-core/playwright": "^4.12.0",
      "@playwright/test": "^1.61.0",
      "@types/react": "^19.2.0",
      "@types/react-dom": "^19.2.0",
      "jsdom": "^29.1.0",
      "typescript": "^7.0.0",
      "vitest": "^4.1.0"
    }
  }
  ```

  Fetch the newly declared Mix dependency before invoking its npm task, then
  create the lock:

  ```bash
  mix deps.get
  mix npm.install
  ```

  Keep the runners disjoint:

  ```ts
  // vitest.config.ts
  export default defineConfig({
    test: {
      environment: "jsdom",
      include: [
        "apps/singularity_web/assets/test/**/*.test.{ts,tsx}"
      ]
    }
  });
  ```

- [ ] **Step 3: Write the versioned bridge tests before React**

  Test:

  - one root created before asynchronous import and unmounted in
    `destroyed()`;
  - version-1 initial props;
  - `asset:snapshot` replacement and `asset:update` merge;
  - stale sequence/revision rejection;
  - search replacement and page append;
  - upload grant, progress, cancellation, expiry, and token reuse;
  - retry/delete with current revision;
  - navigation allow-list only;
  - reconnect snapshot before later updates.

  Component tests use React `createRoot`, React `act`, and native DOM
  assertions; do not add Testing Library or jest-dom for this seam.

  ```tsx
  it("ignores stale updates and unmounts exactly once", async () => {
    const container = document.createElement("div");
    const hook = mountHook(container, initialProps({stateRevision: 8}));
    await hook.receive("asset:snapshot", snapshot({sequence: 4}));
    await hook.receive("asset:update", update({sequence: 3, stateRevision: 7}));
    expect(container.textContent).toContain("Ready");
    hook.destroyed();
    expect(hook.root.unmount).toHaveBeenCalledTimes(1);
  });
  ```

  Run:

  ```bash
  mix npm.run test:js
  ```

  Expected: failure because the hook and component do not exist.

- [ ] **Step 4: Implement the App-Clip ownership seam**

  `AssetsLive` renders one React mount node with
  `phx-hook="MountAssetWorkspace"` and `phx-update="ignore"`. Initial
  `data-props` and every event/reply use the exact version-1 schemas from the
  design. React owns only the center workspace; LiveView owns session,
  authorization, vault state, chrome, subscriptions, and navigation.

  The hook creates one root, supplies `pushEvent`, allow-listed
  server-navigation, and upload functions, reuses the root on events, and
  always unmounts. Subscribe after connected mount; on reconnect query
  canonical PostgreSQL state and send a full snapshot.

  The LiveView mount node contains only non-sensitive initial props:

  ```heex
  <div
    id="asset-workspace"
    phx-hook="MountAssetWorkspace"
    phx-update="ignore"
    data-props={JSON.encode!(@initial_props)}
  >
  </div>
  ```

  `contracts.ts` owns the complete seam:

  ```ts
  export type AssetState =
    | "staging"
    | "uploaded"
    | "verified"
    | "available"
    | "processing"
    | "ready"
    | "pending_delete"
    | "deleted";

  export type AssetFailure = null | {
    code: string;
    retryable: boolean;
    operation: string;
    attempt: number;
  };

  export type AssetProgress =
    | {kind: "bytes"; sent: number; total: number}
    | {kind: "indeterminate"}
    | {kind: "complete"}
    | {kind: "waiting_for_unlock"}
    | null;

  export type AssetSummary = {
    id: string;
    resourceVersionId: string;
    title: string;
    originalFilename: string;
    detectedMediaType: string | null;
    state: AssetState;
    stateRevision: number;
    label: string;
    progress: AssetProgress;
    failure: AssetFailure;
    updatedAt: string;
  };

  export type InitialProps = {
    version: 1;
    vault: {ref: string; locked: boolean; expiresAt: string | null};
    assets: {items: AssetSummary[]; nextCursor: string | null};
    filters: {q: string; state: AssetState | null; mediaType: string | null};
    upload: {maxBytes: number; acceptedTypes: string[]};
  };

  export type UploadGrant = {
    ok: true;
    grantId: string;
    uploadToken: string;
    uploadUrl: string;
    expiresAt: string;
  };

  export type Bridge = {
    search(request: {
      version: 1;
      q: string;
      state: AssetState | null;
      mediaType: string | null;
    }): Promise<{ok: true; sequence: number; filters: InitialProps["filters"];
                 assets: InitialProps["assets"]}>;
    page(request: {
      version: 1;
      cursor: string;
      q: string;
      state: AssetState | null;
      mediaType: string | null;
    }): Promise<{ok: true; sequence: number; assets: InitialProps["assets"]}>;
    grant(request: {
      version: 1;
      filename: string;
      size: number;
      mediaType: string;
      idempotencyKey: string;
    }): Promise<UploadGrant>;
    cancel(request: {
      version: 1;
      grantId: string;
    }): Promise<{ok: true; accepted: boolean}>;
    retry(request: {
      version: 1;
      assetId: string;
      stateRevision: number;
    }): Promise<{ok: true; accepted: boolean}>;
    delete(request: {
      version: 1;
      assetId: string;
      stateRevision: number;
    }): Promise<{ok: true; accepted: boolean}>;
    navigate(to: "/assets" | "/activity" | "/audit" | "/backups" | "/settings"):
      Promise<{ok: true}>;
  };
  ```

  Snapshot and update payloads are
  `{version: 1, sequence, assets}` and
  `{version: 1, sequence, asset}` respectively. They never contain an upload
  token, CSRF token, opaque session ID, or key material.

  ```tsx
  export const MountAssetWorkspace = {
    mounted() {
      this.root = createRoot(this.el);
      this.props = JSON.parse(this.el.dataset.props ?? "{}");
      this.sequence = 0;
      this.handleEvent("asset:snapshot", payload => this.applySnapshot(payload));
      this.handleEvent("asset:update", payload => this.applyUpdate(payload));
      this.render();
    },
    destroyed() {
      this.root?.unmount();
    },
    render() {
      this.root.render(
        <AssetWorkspace {...this.props} bridge={this.bridge()} />
      );
    }
  };
  ```

  Initial `data-props` has no sequence by design. The client baseline is
  exactly zero, and the first accepted sequenced snapshot/update must be
  greater than zero.

  Register the hook and pass it to LiveSocket:

  ```ts
  import {MountAssetWorkspace} from "./clips/mount_asset_workspace";

  export const Hooks = {MountAssetWorkspace};

  const liveSocket = new LiveSocket("/live", Socket, {
    hooks: Hooks,
    params: {_csrf_token: csrfToken}
  });
  ```

- [ ] **Step 5: Implement XHR upload and lifecycle presentation**

  Request a grant through `pushEvent`, then use same-origin
  `XMLHttpRequest PUT` for bytes with `x-upload-token`, CSRF meta value, and
  session cookie. Use `xhr.upload.onprogress`; `xhr.abort()` cancels. After a
  valid grant, every terminal result except `201` awaits one best-effort
  `upload:cancel` reply keyed only by `grantId`, so the UI cannot retry before
  cleanup has been attempted. Phoenix binds session, principal, and vault from
  `current_session`; it never accepts those values or the upload token from the
  cancel payload. Storage atomically retires only an exact unconsumed grant and
  tombstones/releases its staging asset. If PUT consumption won the race, the
  existing upload-session abandonment path remains authoritative.

  AssetsLive retains at most one pending grant ID, cancels it before issuing a
  replacement, and attempts bounded cleanup before the validated expiry and on
  graceful termination. The database constraint records early retirement only
  when `cancelled_at == retired_at` and the grant was never consumed.

  Map every domain state and orthogonal failure exactly as design section 11.
  Retry is enabled only for `retryable: true` and sends `stateRevision`.
  Search uses signed opaque 50-item cursors; Phoenix rejects cursor/filter
  mismatch and arbitrary navigation paths.

  `state.ts` owns the display mapping:

  ```ts
  export const defaultLabel: Record<AssetState, string> = {
    staging: "Uploading",
    uploaded: "Verifying",
    verified: "Finalizing",
    available: "Available",
    processing: "Processing",
    ready: "Ready",
    pending_delete: "Deleting",
    deleted: "Deleted"
  };

  export function visibleLabel(asset: AssetSummary): string {
    return asset.failure
      ? `Failed: ${stableFailureMessage(asset.failure.code)}`
      : defaultLabel[asset.state];
  }

  export function canRetry(asset: AssetSummary): boolean {
    return asset.failure?.retryable === true;
  }
  ```

  ```ts
  export function upload(
    grant: UploadGrant,
    file: File,
    csrf: string,
    onProgress: Progress
  ) {
    const xhr = new XMLHttpRequest();
    xhr.open("PUT", grant.uploadUrl, true);
    xhr.setRequestHeader("x-upload-token", grant.uploadToken);
    xhr.setRequestHeader("x-csrf-token", csrf);
    xhr.upload.onprogress = event =>
      onProgress({loaded: event.loaded, total: event.total});
    xhr.send(file);

    return {
      abort: () => xhr.abort(),
      completed: completionPromise(xhr)
    };
  }
  ```

- [ ] **Step 6: Implement semantic, accessible Vault Workbench styling**

  Define project-owned semantic tokens for background, surface, text, muted,
  border, accent, success, warning, danger, and focus. Select light/dark via
  root `data-theme`; components use tokens, not literal palette classes.

  Use landmarks, accessible names, keyboard-complete controls, visible focus,
  focus restoration for the inspector, no horizontal overflow below 768px,
  reduced-motion behavior, and WCAG AA contrast in both themes.

  ```css
  :root {
    --dm-background: #f6f7fb;
    --dm-surface: #ffffff;
    --dm-text: #151823;
    --dm-muted-text: #596174;
    --dm-border: #c8ceda;
    --dm-accent: #3157d5;
    --dm-success: #147846;
    --dm-warning: #8a5a00;
    --dm-danger: #b4232f;
    --dm-focus: #174fd6;
  }

  [data-theme="dark"] {
    --dm-background: #10131a;
    --dm-surface: #181d27;
    --dm-text: #f4f6fb;
    --dm-muted-text: #b2bbca;
    --dm-border: #3b4352;
    --dm-accent: #8ca8ff;
    --dm-success: #5fd29a;
    --dm-warning: #f1c66b;
    --dm-danger: #ff8e98;
    --dm-focus: #a8bbff;
  }

  :focus-visible {
    outline: 3px solid var(--dm-focus);
    outline-offset: 2px;
  }

  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after { animation: none !important; }
  }

  @media (max-width: 767px) {
    .workbench { grid-template-columns: minmax(0, 1fr); }
  }
  ```

- [ ] **Step 7: Run JS, bundle, Phoenix, and architecture gates**

  Run:

  ```bash
  devenv up -d
  trap 'devenv processes down' EXIT
  devenv processes wait --timeout 120
  mix deps.get
  # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
  # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
  NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
  mix npm.verify
  mix duskmoon_bundler.js.check
  mix npm.run test:js
  mix duskmoon_bundler.build singularity_web --tailwind
  mix test apps/singularity_domains/test/singularity/domains/assets_test.exs
  mix test apps/singularity_runtime/test/singularity/runtime/cancel_upload_grant_test.exs \
    apps/singularity_runtime/test/singularity/runtime/api_test.exs
  devenv shell -- mix singularity.test.integration \
    apps/singularity_storage/test/singularity/storage/asset_search_pagination_test.exs \
    apps/singularity_storage/test/singularity/storage/asset_search_projection_test.exs \
    apps/singularity_storage/test/singularity/storage/asset_search_store_fetch_test.exs \
    apps/singularity_storage/test/singularity/storage/asset_stage_abandonment_test.exs \
    apps/singularity_storage/test/singularity/storage/orphan_cleanup_test.exs \
    apps/singularity_storage/test/singularity/storage/server_owned_upload_grant_test.exs
  devenv shell -- mix singularity.test.integration \
    apps/singularity_storage/test/singularity/storage/migrations_test.exs
  mix test apps/singularity_web/test
  mix compile --warnings-as-errors
  mix xref graph --format cycles --fail-above 0
  git diff --check
  git add .formatter.exs .gitignore mix.exs mix.lock config \
    apps/singularity_core apps/singularity_domains apps/singularity_ingest \
    apps/singularity_retrieval apps/singularity_runtime \
    apps/singularity_storage apps/singularity_web package.json \
    package-lock.json tsconfig.json vitest.config.ts \
    docs/superpowers/specs/2026-07-18-foundation-asset-vertical-design.md \
    docs/superpowers/plans/2026-07-18-foundation-asset-vertical.md
  git commit -m "feat(web): add Vault Workbench App-Clip"
  ```

## Task 18: Add browser workflow, browser secret canaries, and complete CI

**Approved amendment:**
[`2026-08-08-task-18-browser-acceptance-amendment.md`](../specs/2026-08-08-task-18-browser-acceptance-amendment.md)
is authoritative for restore-only integrity proof, browser backup transport,
pagination, and browser-versus-unit coverage.

**Files:**

- Create: `playwright.config.ts`
- Create:
  `test/e2e/{vault_workbench,upload_security,responsive_accessibility,theme_accessibility}.spec.ts`
- Create: `test/e2e/support/fixtures.ts`
- Create:
  `apps/singularity_runtime/lib/mix/tasks/singularity.test.browser.ex`
- Modify:
  `apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex`
- Create:
  `apps/singularity_runtime/test/mix/tasks/singularity.test.browser_test.exs`
- Create:
  `apps/singularity_core/lib/singularity/core/backup_status_store.ex`
- Modify: `apps/singularity_core/test/singularity/core/ports_test.exs`
- Create:
  `apps/singularity_storage/lib/singularity/storage/postgres/backup_status_store.ex`
- Create:
  `apps/singularity_storage/test/singularity/storage/postgres/backup_status_store_test.exs`
- Modify:
  `apps/singularity_storage/lib/singularity/storage/crypto/backup_key_deriver.ex`
- Modify:
  `apps/singularity_storage/test/singularity/storage/crypto/backup_crypto_adapters_test.exs`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/dto/backup_status.ex`
- Create:
  `apps/singularity_runtime/lib/singularity/runtime/backups/status.ex`
- Modify:
  `apps/singularity_runtime/lib/singularity/runtime/{api,backup_key_lease,backup_vault,key_custodian}.ex`
- Modify:
  `apps/singularity_runtime/test/singularity/runtime/{api,backup_key_lease,backup_vault}_test.exs`
- Create:
  `apps/singularity_runtime/test/singularity/runtime/{backup_status,key_custodian_backup}_test.exs`
- Create:
  `apps/singularity_web/test/singularity/web/secret_canary_test.exs`
- Modify:
  `apps/singularity_storage/lib/singularity/storage/test_environment.ex`
- Modify:
  `apps/singularity_storage/test/singularity/storage/test_environment_test.exs`
- Create:
  `apps/singularity_web/lib/singularity/web/controllers/backup_controller.ex`
- Modify: `apps/singularity_web/lib/singularity/web/router.ex`
- Modify:
  `apps/singularity_web/lib/singularity/web/live/{assets_live,audit_live,backups_live}.ex`
- Modify: `apps/singularity_web/test/support/conn_case.ex`
- Create:
  `apps/singularity_web/test/singularity/web/backup_controller_test.exs`
- Modify:
  `apps/singularity_web/assets/js/asset_workspace/AssetWorkspace.tsx`
- Modify:
  `apps/singularity_web/assets/test/asset_workspace.test.tsx`
- Create:
  `apps/singularity_web/test/singularity/web/live/{audit_live,backups_live}_test.exs`
- Modify:
  `apps/singularity_web/test/singularity/web/{assets_live,authentication,route_contract}_test.exs`
- Modify:
  `apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs`
- Modify: `mix.exs`
- Modify: `config/{config,test}.exs`
- Modify: `.formatter.exs`
- Modify: `tsconfig.json`
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md`
- Verify only unless dependencies change: `package.json`, `package-lock.json`
- Verify only:
  `apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs`
- Do not modify for Task 18:
  `apps/singularity_runtime/lib/singularity/runtime/job_dispatcher.ex`,
  `apps/singularity_storage/lib/singularity/storage/jobs/{envelope_codec,oban_adapter}.ex`

- [x] **Step 1: Build the isolated browser server and smoke workflow**

  Extend `Singularity.Storage.TestEnvironment` with a constructor that validates
  a Playwright run ID, derives its 24-character lowercase hexadecimal suffix,
  and returns the same narrowly scoped database/root shape accepted by
  `create!/1` and `drop!/1`. Add an explicit forced cleanup path that terminates
  connections only for that generated database, drops only that database, and
  removes only that generated root. Preserve random allocation and graceful
  cleanup for the integration/restore tasks.

  Add `mix singularity.test.browser serve` with focused task tests. It must
  configure the generated repositories, real authorization/custody adapters,
  active Oban queues, the endpoint, and the deterministic browser-test owner
  before starting application children. It must restore prior application
  configuration and invoke the exact generated cleanup path on partial setup,
  `SIGTERM`, and VM exit. No secret may be placed in OS process arguments,
  environment variables, or logs.

  Add Playwright configuration and fixtures, then prove one Chromium smoke path:

  ```text
  provision -> login -> unlock -> render the empty Vault Workbench -> shutdown
  -> generated database and roots are absent
  ```

  Include `playwright.config.ts` and `test/e2e/**/*.ts` in the TypeScript and
  formatter gates. Run the storage constructor/cleanup tests, browser-task
  lifecycle tests, and smoke test before extending the workflow.

  This slice is implemented in the current worktree. Playwright uses one worker,
  the system Chromium, a generated UUID passed to `webServer`, and
  `MIX_ENV=test mix singularity.test.browser serve`; it does not use
  `globalSetup`. The Mix task provisions before application startup, binds only
  to `127.0.0.1:4002`, derives the owner password independently in Elixir and
  TypeScript, and performs bounded idempotent cleanup on partial setup,
  `SIGTERM`, normal exit, and VM exit. The root `preferred_cli_env` includes
  `singularity.test.browser: :test`.

  Verified before this plan refresh:

  ```bash
  mix test apps/singularity_storage/test/singularity/storage/test_environment_test.exs
  mix test apps/singularity_runtime/test/mix/tasks/singularity.test.browser_test.exs
  devenv shell -- mix npm.run test:e2e
  ```

  Expected: storage and task tests pass; Chromium logs in, unlocks, renders an
  empty Vault Workbench, and generated database/storage roots are absent after
  shutdown.

- [x] **Step 2: Add the visible asset download action**

  `AssetWorkspace` now renders a same-origin
  `/api/v1/assets/:asset_id/content` download link with the original filename
  for `available`, `processing`, and `ready` assets. The action is hidden before
  availability, during/after deletion, while locked, and after local access
  expiry. Vitest covers the URL, filename, complete lifecycle matrix, lock, and
  expiry behavior.

  Verified before this plan refresh:

  ```bash
  mix npm.run test:js -- apps/singularity_web/assets/test/asset_workspace.test.tsx
  mix duskmoon_bundler.js.check
  ```

  Expected: all JS tests and Duskmoon checks pass.

- [ ] **Step 3: Write failing backup status port and adapter tests**

  Add `Singularity.Core.BackupStatusStore` with one read callback:

  ```elixir
  @callback fetch(context(), %{
              operation_id: String.t(),
              vault_id: String.t()
            }) :: {:ok, map()} | {:error, Error.t()}
  ```

  Extend the exact callback inventory in `ports_test.exs`; do not add a write
  callback or expose the backup manifest schema through the core port.

  Write PostgreSQL adapter tests first. Under a normal scoped read request they
  must prove that `fetch/2` returns only `operation_id`, `vault_id`, `status`,
  `requested_at`, and `updated_at`; supports every persisted stable state
  (`pending`, `waiting_for_backup_key`, `copying`, `sealed`, and `failed`); and
  returns the same `Error.new(:not_found)` for a missing UUID and a UUID owned
  by another vault. Assert the result never contains destination, KDF,
  recovery-wrapper, custody, manifest, snapshot, or object-inventory fields.

  Add a failing crypto assertion for a public `BackupKeyDeriver.profile/0`
  function that returns the existing allow-listed domain and Argon2id
  parameters without a salt or any key material. Do not change the KDF profile.

  Run:

  ```bash
  mix test apps/singularity_core/test/singularity/core/ports_test.exs
  devenv shell -- mix singularity.test.integration \
    apps/singularity_storage/test/singularity/storage/postgres/backup_status_store_test.exs
  mix test \
    apps/singularity_storage/test/singularity/storage/crypto/backup_crypto_adapters_test.exs
  ```

  Expected: the new callback/module/profile assertions fail because the port,
  adapter, and public profile do not exist yet; existing assertions still pass.

- [ ] **Step 4: Implement the redacted backup status storage seam**

  Implement the core behavior exactly as tested. Implement
  `Singularity.Storage.Postgres.BackupStatusStore` with one vault-and-operation
  query over `Singularity.Storage.Schema.Audit.BackupManifest`; select the five
  allow-listed public fields in SQL rather than loading a full manifest and
  trimming it afterward. Preserve RLS by accepting the scoped repository
  supplied by `OperationScope`.

  Add the non-secret runtime DTO:

  ```elixir
  defmodule Singularity.Runtime.DTO.BackupStatus do
    @enforce_keys [:operation_id, :status, :requested_at, :updated_at]
    defstruct @enforce_keys
  end
  ```

  `BackupStatus` must accept only the five persisted status atoms above. Add
  `BackupKeyDeriver.profile/0` by returning the module's existing domain and
  parameter constants; keep the random salt request-specific.

  Rerun the three commands from Step 3, then:

  ```bash
  mix format --check-formatted \
    apps/singularity_core/lib/singularity/core/backup_status_store.ex \
    apps/singularity_core/test/singularity/core/ports_test.exs \
    apps/singularity_storage/lib/singularity/storage/postgres/backup_status_store.ex \
    apps/singularity_storage/test/singularity/storage/postgres/backup_status_store_test.exs \
    apps/singularity_storage/lib/singularity/storage/crypto/backup_key_deriver.ex \
    apps/singularity_storage/test/singularity/storage/crypto/backup_crypto_adapters_test.exs \
    apps/singularity_runtime/lib/singularity/runtime/dto/backup_status.ex
  git diff --check
  ```

  Expected: all focused tests pass and the public result cannot contain backup
  secrets or storage locations.

- [ ] **Step 5: Write failing session-bound backup custody tests**

  Extend `backup_key_lease_test.exs`, `backup_vault_test.exs`, and a focused new
  `key_custodian_backup_test.exs` before changing production code. Prove:

  - Argon2id derivation occurs in the calling request process and never in the
    `KeyCustodian` process;
  - a redacted derived-key command binds session ID, principal ID, vault ID,
    principal/vault authorization epochs, expiry, manifest ID, KDF profile, and
    derived key material, while `Inspect` prints only `REDACTED`;
  - `KeyCustodian.prepare_backup_key/3` accepts only the matching active,
    unlocked, unexpired, non-revoked session and creates the recovery wrapper
    with the vault key already held by custody;
  - the caller session contains no `vault_key`, the raw vault key never appears
    in a reply, and neither the passphrase nor Argon2 work enters the GenServer;
  - mismatched principal/vault/epoch/manifest binding, expiry, revocation, and
    missing custody fail closed without installing a pending ref;
  - existing restore/reentry custody behavior remains unchanged;
  - a fresh `BackupVault.request/4` does not require `partial_bundles`, while
    resume still does; and successful post-commit activation invokes the
    existing `JobRunner.wake_vault/2` contract with the vault ID, not the
    nonexistent `wake_backup` contract or manifest ID.

  Run:

  ```bash
  mix test \
    apps/singularity_runtime/test/singularity/runtime/backup_key_lease_test.exs \
    apps/singularity_runtime/test/singularity/runtime/key_custodian_backup_test.exs \
    apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs
  ```

  Expected: only the new custody and wake-contract assertions fail.

- [ ] **Step 6: Implement session-bound custody without widening the mailbox**

  Add a redacted `BackupKeyLease.Derived` struct containing only the complete
  session/manifest binding, public KDF metadata, and the 32-byte derived key.
  Keep `prepare/4` as the caller-process boundary: generate the public salt,
  call `BackupKeyDeriver.derive/2` there, construct `Derived`, and call the
  session-bound custodian operation. Do not pass the passphrase to the
  custodian and do not require a `vault_key` field in the session.

  Overload `KeyCustodian.prepare_backup_key/3` as:

  ```elixir
  @spec prepare_backup_key(
          GenServer.server(),
          map(),
          BackupKeyLease.Derived.t()
        ) :: {:ok, BackupKeyLease.Prepared.t()} | {:error, Error.t()}
  ```

  Inside the GenServer, validate the active custody record and every session
  binding field before using its in-custody vault key with
  `BackupRecoveryWrapper`. Generate the opaque ref internally, monitor the
  pending lease, preserve the existing activate/revoke/expiry lifecycle, and
  return only `BackupKeyLease.Prepared`. Add the recovery-wrapper adapter to
  the production and browser-test custodian configuration without changing
  restore semantics.

  Split `BackupVault` adapter validation between fresh request and reentry.
  Replace both `wake_backup(pending.id)` calls with the existing job-runner
  `wake_vault(pending.vault_id)` call. Do not edit `JobDispatcher`,
  `EnvelopeCodec`, or `ObanAdapter`. Rename the restore oracle's contextless
  test adapter callback from `wake_backup/1` to `wake_vault/1`; this is the only
  Task 18 change allowed in `singularity.test.restore.ex`.

  Rerun Step 5. Then run the pre-existing restore-boundary regression tests:

  ```bash
  mix test \
    apps/singularity_runtime/test/singularity/runtime/restore_authenticator_test.exs \
    apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs
  mix format --check-formatted \
    apps/singularity_runtime/lib/singularity/runtime/backup_key_lease.ex \
    apps/singularity_runtime/lib/singularity/runtime/backup_vault.ex \
    apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex
  git diff --check
  ```

  Expected: all focused runtime tests pass; no raw key or passphrase appears in
  structs, errors, supported `LoggerMetadata.log/3` final JSON records, or
  messages observable outside custody.

- [ ] **Step 7: Write failing runtime facade and status-use-case tests**

  In `backup_status_test.exs`, prove `Singularity.Runtime.Backups.Status.run/3`
  uses `OperationScope.with_read_request`, requires classification `private`,
  capability `backup.create`, and an unlocked vault, passes both operation and
  current vault IDs to `BackupStatusStore`, validates the returned identity,
  and maps missing/cross-vault reads to the same public `not_found` result.

  In `api_test.exs`, add injected-config tests for:

  ```elixir
  request_backup(config, session, passphrase)
  backup_status(config, session, operation_id)
  ```

  Require a valid unlocked session DTO, non-empty passphrase, and UUID operation
  IDs. The injected `request_backup` seam must return only an operation identity,
  after which the facade invokes its injected `backup_status` seam to obtain
  timestamps and state. Assert both public functions return only
  `DTO.BackupStatus`; normalize internal errors to stable public atoms; reject
  malformed status maps as `:integrity_failure`; and never include passphrase,
  KDF, wrapper, custody, destination, filesystem path, or manifest data. Add
  runtime canary assertions that inspect replies, exceptions, supported final
  JSON records originating from `LoggerMetadata.log/3`, supported
  `[:singularity, ...]` telemetry, and audit metadata. Existing captured-log
  checks remain defense in depth only.

  Run:

  ```bash
  mix test \
    apps/singularity_runtime/test/singularity/runtime/backup_status_test.exs \
    apps/singularity_runtime/test/singularity/runtime/api_test.exs \
    apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs
  ```

  Expected: the new API and use-case tests fail because the functions and
  production wiring do not exist.

- [ ] **Step 8: Implement the sole web-to-runtime backup facade**

  Implement `Backups.Status` exactly as tested. Add public and injected-config
  arities to `Singularity.Runtime.Api`:

  ```elixir
  @spec request_backup(Session.t(), binary()) ::
          {:ok, DTO.BackupStatus.t()} | {:error, atom()}
  @spec backup_status(Session.t(), String.t()) ::
          {:ok, DTO.BackupStatus.t()} | {:error, atom()}
  ```

  `request_backup/2` must convert the session DTO to the internal session
  context, generate the canonical relative destination
  `"web/" <> Ecto.UUID.generate() <> ".bundle"`, normalize it beneath the
  configured local `backup_root`, and call `BackupVault.request/4`. Extract only
  the returned operation ID, then perform a post-commit
  `Backups.Status.run/3` read to obtain the public timestamps/state and convert
  that result to the allow-listed DTO. Do not widen `BackupRepository`'s public
  manifest. The passphrase may be present only in this call stack and the
  caller-process KDF invocation. The public facade must never accept a client
  destination.

  `backup_status/2` calls `Backups.Status` using the current session and the new
  status port. Build the production map from the existing operation-scope
  entries plus these exact backup entries:

  ```elixir
  %{
    backup_key_lease: BackupKeyLease,
    backups: BackupRepository,
    backup_status_store: BackupStatusStore,
    custodian: {KeyCustodian, KeyCustodian},
    ids: Ecto.UUID,
    jobs: {ObanAdapter, %{}},
    operation_scope: OperationScope,
    backup_key_deriver: BackupKeyDeriver,
    backup_key_wrapper: BackupRecoveryWrapper,
    backup_kdf_domain: profile.domain,
    backup_kdf_parameters: profile.parameters,
    random_bytes: &:crypto.strong_rand_bytes/1,
    backup_destination: {LocalDestination, %{backup_root: backup_root}}
  }
  ```

  Here the adapter tuple makes `BackupVault` call
  `ObanAdapter.wake_vault(%{}, vault_id)` through `JobRunner`'s two-argument
  contract; never configure a module that would receive `wake_vault/1`. Use
  `BackupKeyDeriver.profile/0` for `profile`, not duplicated KDF literals. Add no
  new job type, capability, migration, or schema.

  Rerun Step 7 plus:

  ```bash
  mix compile --warnings-as-errors
  mix xref graph --format cycles --fail-above 0
  git diff --check
  ```

  Expected: the facade and canary tests pass, and the dependency graph still
  permits the web application to depend only on `Singularity.Runtime.Api`.

- [ ] **Step 9: Write failing controller, LiveView, pagination, and browser-task tests**

  Add `BackupControllerTest` cases for authenticated/unlocked success,
  same-origin CSRF enforcement, a redirect to
  `/backups?operation_id=<public UUID>`, stable non-secret failure flash, absent
  or expired session, locked vault, and confirmation that an error response
  never repopulates the password input. The runtime test double must record
  only the call boundary; controller assertions must never inspect internal
  manifest maps.

  Add `BackupsLiveTest` cases for an ordinary HTML `POST` form with a password
  input and Phoenix CSRF field, no `phx-submit`, no passphrase assign, status
  polling through `Runtime.Api`, terminal `sealed` rendering, exact stable
  `"Encrypted backup could not be completed."` text for terminal `failed`, and
  identical missing/cross-vault `not_found` output. Add `AuditLiveTest` cases
  proving the page is read-only, names `mix singularity.test.restore` as the
  restore acceptance proof, and contains no request button or current-vault
  validity claim. Extend route-contract and authentication tests for the new
  controller action.

  Extend `AssetsLiveTest` so the production default is 50, configuration is
  bounded to `1..50`, and the selected value reaches the existing runtime search
  params without changing cursor semantics. Extend the browser-task tests so
  setup uses page size 2, grants only the existing `backup.create` capability in
  addition to the prior explicit browser-owner list, and restores both settings
  on partial setup, `SIGTERM`, normal exit, and VM exit. Assert production
  `BootstrapOwner` defaults remain unchanged and no `integrity.audit` grant is
  created.

  Run:

  ```bash
  mix test \
    apps/singularity_web/test/singularity/web/backup_controller_test.exs \
    apps/singularity_web/test/singularity/web/live/backups_live_test.exs \
    apps/singularity_web/test/singularity/web/live/audit_live_test.exs \
    apps/singularity_web/test/singularity/web/assets_live_test.exs \
    apps/singularity_web/test/singularity/web/authentication_test.exs \
    apps/singularity_web/test/singularity/web/route_contract_test.exs \
    apps/singularity_runtime/test/mix/tasks/singularity.test.browser_test.exs
  ```

  Expected: the new route, form, status, explanation, page-size, capability,
  and cleanup assertions fail before implementation.

- [ ] **Step 10: Implement the safe browser backup surface**

  Add `POST /backups` inside the authenticated-and-unlocked browser scope,
  before the unlocked LiveView session. `BackupController.create/2` must read
  only the URL-encoded `passphrase`, call only:

  ```elixir
  Auth.call_runtime(:request_backup, [current_session, passphrase])
  ```

  On success redirect with only the public operation ID. On failure, discard
  the passphrase and render a stable generic flash before redirecting to
  `/backups`. Never put it in a LiveView event, assign, URL, JSON, log,
  supported `[:singularity, ...]` telemetry, audit metadata, OS process
  argument, or environment variable.

  Render the backup form as a normal same-origin form:

  ```heex
  <form action={~p"/backups"} method="post">
    <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
    <input
      id="backup-passphrase"
      name="passphrase"
      type="password"
      autocomplete="new-password"
      required
    />
    <button type="submit">Create encrypted backup</button>
  </form>
  ```

  `BackupsLive` reads `operation_id` from the query string, calls only
  `Runtime.Api.backup_status/2`, assigns only the DTO, and polls boundedly while
  status is `pending`, `waiting_for_backup_key`, or `copying`. Stop polling for
  `sealed`, `failed`, and `not_found`. Render `sealed`, never `valid`; render the
  exact stable non-secret `"Encrypted backup could not be completed."` text for
  `failed`. `AuditLive` is static restore-only guidance with no mutation event.

  Replace `AssetsLive`'s hard-coded page size with
  `Application.get_env(:singularity_web, :asset_page_limit, 50)`, bounded to
  `1..50`, and set `config :singularity_web, :asset_page_limit, 50` in the base
  configuration. In the browser task, snapshot that exact key, set it to 2
  before application startup, create the configured generated
  `<storage_root>/backups` directory before `LocalDestination.normalize/2` can
  run, and restore the setting on every existing cleanup path. The existing
  generated-root cleanup removes that directory. Bootstrap the browser owner
  with the explicit capabilities:

  ```elixir
  ~w[asset.read asset.write backup.create vault.lock vault.unlock vault.password_change]
  ```

  Do not alter production bootstrap defaults and do not add `integrity.audit`.
  Rerun Step 9, then the dependency-graph test:

  ```bash
  mix test \
    apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix format --check-formatted \
    apps/singularity_web/lib/singularity/web/controllers/backup_controller.ex \
    apps/singularity_web/lib/singularity/web/live/backups_live.ex \
    apps/singularity_web/lib/singularity/web/live/audit_live.ex \
    apps/singularity_web/lib/singularity/web/live/assets_live.ex \
    apps/singularity_web/lib/singularity/web/router.ex
  git diff --check
  ```

  Expected: all controller, LiveView, route, pagination, task-cleanup, and
  architecture tests pass.

- [ ] **Step 11: Complete the Chromium asset-and-backup workflow**

  Add fixtures for one PDF, one JPEG, and one PNG. Extend the smoke workflow
  test-first to prove the user-visible path and nothing beyond it:

  ```text
  login -> unlock -> upload PDF/JPEG/PNG -> observe lifecycle
  -> search -> filter -> follow the real next cursor at page size 2
  -> download and verify original bytes -> delete -> observe cleanup
  -> submit backup form -> follow redirect -> poll -> observe sealed
  -> open Audit -> see restore-only acceptance explanation
  ```

  Keep one worker, system Chromium, the generated database/root, and the
  already implemented deterministic credential derivation. Do not seed rows,
  upload 51 objects, use `globalSetup`, or transport a credential through the
  environment. Intercept the backup form request only to prove it is a
  same-origin URL-encoded `POST`; do not log its body.

  Do not add Playwright cases for stale state revisions/event sequences, upload
  grant expiry/reuse, cancellation/retry, locked metadata waiting, reconnect
  snapshots, or navigation allow-list enforcement. Confirm their existing
  scoped ExUnit/Vitest tests remain green instead:

  ```bash
  mix npm.run test:js
  mix test \
    apps/singularity_web/test/singularity/web/assets_live_test.exs \
    apps/singularity_runtime/test/singularity/runtime/api_test.exs
  devenv shell -- mix npm.run test:e2e -- \
    test/e2e/vault_workbench.spec.ts
  ```

  Expected: the browser reaches `sealed`, downloads identical bytes, proves the
  real cursor path, and sees no live integrity request or result.

- [ ] **Step 12: Add responsive, keyboard, theme, and accessibility assertions**

  At 767 and 1280 CSS pixels, prove no horizontal overflow and usable collapsed
  navigation/inspector. Exercise the reachable workflow by keyboard, visible
  focus, logical focus restoration, reduced motion, and light/dark themes. Run
  axe and explicit contrast/focus checks for the workbench, backup form/status,
  and restore-only Audit page.

  ```ts
  for (const width of [767, 1280]) {
    await page.setViewportSize({width, height: 900});
    expect(await page.evaluate(() => document.documentElement.scrollWidth))
      .toBeLessThanOrEqual(width);
  }

  const results = await new AxeBuilder({page}).analyze();
  expect(results.violations).toEqual([]);
  ```

  Run:

  ```bash
  devenv shell -- mix npm.run test:e2e -- \
    test/e2e/responsive_accessibility.spec.ts \
    test/e2e/theme_accessibility.spec.ts
  ```

  Expected: both viewports, both themes, reduced motion, keyboard traversal,
  focus restoration, and axe assertions pass.

- [ ] **Step 13: Complete the browser and server secret canaries**

  Add ExUnit and Playwright canaries for password, vault key, domain key, DEK,
  and backup passphrase. The backup passphrase is allowed only in the transient
  DOM value of `#backup-passphrase` and the body of its same-origin URL-encoded
  `POST /backups`; clear the field after submission and never copy or print the
  body. It must be absent from initial/returned HTML, `data-props`, application
  and server-pushed LiveView payloads, application JSON, supported final JSON
  records originating from `LoggerMetadata.log/3`, audit metadata, supported
  `[:singularity, ...]` telemetry measurements and metadata, exception
  inspection, and browser console. Raw dependency telemetry and the combined
  raw Logger stream are unsupported and not blockers; selected Phoenix,
  request-log, and `capture_log` scrubbers are defense in depth and do not make
  those streams supported or secret-free.

  Preserve the upload-token allowance only for its grant callback and matching
  XHR header. The CSRF token may occur only in the dedicated meta tag,
  LiveSocket connection parameter, Phoenix-generated `_csrf_token` fields on
  same-origin controller forms including the backup form, and the same-origin
  upload request header. Collapse repeated occurrences to these location kinds
  before comparing the exact allow-list.

  ```ts
  expect([...new Set(csrfOccurrenceKinds)]).toEqual([
    "meta-tag",
    "live-socket-param",
    "controller-form-field",
    "xhr-header"
  ]);
  ```

  Run:

  ```bash
  mix test \
    apps/singularity_web/test/singularity/web/secret_canary_test.exs \
    apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs \
    apps/singularity_runtime/test/singularity/runtime/telemetry_test.exs \
    apps/singularity_runtime/test/singularity/runtime/observability_redaction_test.exs \
    apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
  devenv shell -- mix npm.run test:e2e -- \
    test/e2e/upload_security.spec.ts \
    test/e2e/vault_workbench.spec.ts
  ```

  Expected: all secret surfaces are clean and both token allow-lists are exact.

- [ ] **Step 14: Make CI and README run both authoritative gates**

  Update CI to use the pinned devenv PostgreSQL/Node/system-Chromium environment.
  Keep every command inside `devenv shell --`, do not download Playwright
  browsers in package lifecycle scripts, and always stop services. After the
  existing compile/unit/integration and JS/Duskmoon gates, run both independent
  acceptance gates:

  ```yaml
  - run: devenv shell -- mix singularity.test.restore
  - run: devenv shell -- mix npm.run test:e2e
  ```

  Preserve the existing upstream `phoenix-duskmoon-ui#129` marker and link-mode
  workaround only where needed by npm install. Update README with the exact
  local command order, explain that browser success ends at a sealed encrypted
  backup, identify `mix singularity.test.restore` as the only restore-scoped
  integrity proof, and warn that losing the backup passphrase makes recovery
  impossible. Do not document a live integrity endpoint or button.

  Validate the workflow and docs without dispatching CI:

  ```bash
  rg -n "singularity.test.restore|test:e2e|processes down" .github/workflows/ci.yml README.md
  ! rg -n "integrity.*(button|endpoint|request)|request.*integrity" \
    .github/workflows/ci.yml README.md
  git diff --check .github/workflows/ci.yml README.md
  ```

- [ ] **Step 15: Run the Task 18 scoped finish gate and commit**

  Run setup, gates, and teardown from one shell so the cleanup trap remains
  active for the entire sequence:

  ```bash
  devenv up -d
  trap 'devenv processes down' EXIT
  devenv processes wait --timeout 120
  devenv shell -- bash \
    apps/singularity_storage/priv/repo/bootstrap_roles.sh
  devenv shell -- mix deps.get
  devenv shell -- mix deps.unlock --check-unused
  devenv shell -- mix format --check-formatted
  devenv shell -- mix compile --warnings-as-errors
  devenv shell -- mix test \
    apps/singularity_core/test/singularity/core/ports_test.exs \
    apps/singularity_storage/test/singularity/storage/crypto/backup_crypto_adapters_test.exs \
    apps/singularity_storage/test/singularity/storage/test_environment_test.exs \
    apps/singularity_runtime/test/singularity/runtime/backup_key_lease_test.exs \
    apps/singularity_runtime/test/singularity/runtime/key_custodian_backup_test.exs \
    apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs \
    apps/singularity_runtime/test/singularity/runtime/backup_status_test.exs \
    apps/singularity_runtime/test/singularity/runtime/api_test.exs \
    apps/singularity_runtime/test/singularity/runtime/secret_canary_test.exs \
    apps/singularity_runtime/test/singularity/runtime/telemetry_test.exs \
    apps/singularity_runtime/test/singularity/runtime/observability_redaction_test.exs \
    apps/singularity_runtime/test/mix/tasks/singularity.test.browser_test.exs \
    apps/singularity_web/test/singularity/web/backup_controller_test.exs \
    apps/singularity_web/test/singularity/web/live/backups_live_test.exs \
    apps/singularity_web/test/singularity/web/live/audit_live_test.exs \
    apps/singularity_web/test/singularity/web/assets_live_test.exs \
    apps/singularity_web/test/singularity/web/authentication_test.exs \
    apps/singularity_web/test/singularity/web/route_contract_test.exs \
    apps/singularity_web/test/singularity/web/secret_canary_test.exs \
    apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs \
    apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
  devenv shell -- mix singularity.test.integration \
    apps/singularity_storage/test/singularity/storage/postgres/backup_status_store_test.exs
  devenv shell -- mix singularity.test.restore
  devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
  devenv shell -- mix npm.verify
  devenv shell -- mix duskmoon_bundler.js.check
  devenv shell -- mix npm.run test:js
  devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind
  devenv shell -- mix npm.run test:e2e
  devenv shell -- mix xref graph --format cycles --fail-above 0
  git diff --check
  ```

  Expected: every scoped test, the complete Chromium workflow, and the
  independent restore/integrity oracle pass; raw framework telemetry is outside
  this gate. If an out-of-scope test fails, list it and stop instead of changing
  unrelated code.

  Stage only Task 18 paths and make small green commits at the storage/status,
  custody, facade, web surface, browser workflow, and CI/doc boundaries. The
  final Task 18 commit must leave `git status --short` containing no Task 18
  changes and must not stage unrelated work. Do not modify or stage
  `JobDispatcher`, `EnvelopeCodec`, or `ObanAdapter`.

## Task 19: Run the final branch audit and stop at the approved boundary

**Files:** No planned changes.

- [ ] **Step 1: Check scope and dependency absence**

  Run:

  ```bash
  set -euo pipefail

  assert_no_matches() {
    local output status
    if output="$("$@" 2>&1)"; then
      printf '%s\n' "$output" >&2
      return 1
    else
      status=$?
    fi

    if [ "$status" -eq 1 ]; then
      return 0
    fi

    printf '%s\n' "$output" >&2
    return "$status"
  }

  assert_no_package_lock_matches() {
    local output status
    if output="$("$@" 2>&1)"; then
      output="$(printf '%s\n' "$output" | awk \
        '!/^[0-9]+:[[:space:]]*"integrity":[[:space:]]*/')"
      if [ -z "$output" ]; then
        return 0
      fi

      printf '%s\n' "$output" >&2
      return 1
    else
      status=$?
    fi

    if [ "$status" -eq 1 ]; then
      return 0
    fi

    printf '%s\n' "$output" >&2
    return "$status"
  }

  test ! -d apps/singularity_store
  forbidden_storage_references='(?i:couchdb|backplane|embeddedess)|S3[A-Z_][[:alnum:]_]*|(^|[^[:alnum:]])S3((?i:client|adapter|backend|bucket|config|object|provider|repository|repo|sdk|service|storage|store|url|uri|api)[[:alnum:]_]*|[A-Z_][[:alnum:]_]*|[an]([^[:alnum:]]|$)|fs[[:alnum:]_]*|[_-][[:alnum:]_]*|[^[:alnum:]_]|$)|(^|[^[:alnum:]])s3([A-Z][[:alnum:]_]*|(?i:client|adapter|backend|bucket|config|object|provider|repository|repo|sdk|service|storage|store|url|uri|api)[[:alnum:]_]*|[an]([^[:alnum:]]|$)|fs[[:alnum:]_]*|[_-][[:alnum:]_]*|[^[:alnum:]_]|$)'
  assert_no_matches rg -n "$forbidden_storage_references" \
    apps build config test .github/workflows .formatter.exs mix.exs mix.lock \
    package.json playwright.config.ts tsconfig.json vitest.config.ts \
    devenv.nix devenv.yaml devenv.lock
  assert_no_package_lock_matches rg -n --color=never \
    "$forbidden_storage_references" package-lock.json
  assert_no_matches rg -n -i 'qdrant' \
    build config test .github/workflows .formatter.exs mix.exs mix.lock \
    apps/*/mix.exs package.json playwright.config.ts tsconfig.json \
    vitest.config.ts devenv.nix devenv.yaml devenv.lock
  assert_no_package_lock_matches rg -n --color=never -i 'qdrant' \
    package-lock.json
  assert_no_matches rg --files -g '*[Qq][Dd][Rr][Aa][Nn][Tt]*' apps

  set +e
  qdrant_references="$(rg --no-line-number --with-filename --no-heading \
    --color=never -i 'qdrant' apps 2>&1)"
  qdrant_status=$?
  set -e
  if [ "$qdrant_status" -ge 2 ]; then
    printf '%s\n' "$qdrant_references" >&2
    exit "$qdrant_status"
  fi

  qdrant_references="$(printf '%s\n' "$qdrant_references" | LC_ALL=C sort)"
  expected_qdrant_references="$(printf '%s\n' \
    'apps/singularity_retrieval/lib/singularity/retrieval.ex:  @moduledoc "Knowledge retrieval boundary; Qdrant integration begins in Milestone 8."' \
    'apps/singularity_storage/lib/singularity/storage/backup/integrity_audit.ex:  implementation. The Qdrant vector adapter remains a separate required')"
  if [ "$qdrant_references" != "$expected_qdrant_references" ]; then
    printf '%s\n' "$qdrant_references" >&2
    exit 1
  fi

  test "$(rg -cF 'WORKAROUND(upstream): gsmlg-opt/ex_storage_service#5' \
    apps/singularity_runtime/lib/singularity/runtime/storage_adapter.ex)" = 1
  devenv shell -- mix test \
    apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs \
    apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
  git status --short --branch
  git log --oneline --decorate main..HEAD
  git diff --stat main...HEAD
  git diff --check main...HEAD
  ```

  Expected: the obsolete app and all CouchDB, Backplane, EmbeddedESS, and S3
  references are absent from application/configuration/dependency scope.
  Qdrant is absent from configuration, dependency manifests/locks, and
  implementation filenames; its complete `apps` reference set equals the two
  approved Milestone 8 documentation strings exactly.
  The one approved workaround marker has exactly one match.

- [ ] **Step 2: Run all scoped gates before the full suite**

  Run:

  ```bash
  devenv up -d
  trap 'devenv processes down' EXIT
  devenv processes wait --timeout 120
  devenv shell -- bash \
    apps/singularity_storage/priv/repo/bootstrap_roles.sh
  devenv shell -- mix deps.get
  devenv shell -- mix deps.unlock --check-unused
  devenv shell -- mix format --check-formatted
  devenv shell -- mix compile --warnings-as-errors
  devenv shell -- mix singularity.test.integration
  devenv shell -- mix singularity.test.restore
  # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
  # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
  NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
  mix npm.verify
  mix duskmoon_bundler.js.check
  mix npm.run test:js
  mix duskmoon_bundler.build singularity_web --tailwind
  devenv shell -- mix npm.run test:e2e
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix xref graph --format cycles --fail-above 0
  git diff --check
  ```

  Expected: every scoped gate passes. Fix only failures introduced inside this
  plan, rerun the smallest failing command, then rerun this sequence.

- [ ] **Step 3: Run the final full Elixir suite**

  Run only after every scoped gate passes:

  ```bash
  devenv shell -- mix test
  ```

  Expected: all tests pass. If an out-of-scope test fails, list it and stop;
  do not change unrelated behavior.

- [ ] **Step 4: Verify branch history and completion criteria**

  Run:

  ```bash
  mix test apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs
  mix test apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
  git status --short --branch
  git log --oneline --decorate main..HEAD
  git diff --stat main...HEAD
  git diff --check main...HEAD
  ```

  Expected: `codex/vault-workbench-app-clip` contains only the approved vertical
  in its commits, no whitespace errors, only protected Hex dependency sources,
  and no unsupported raw dependency telemetry subscriptions. The worktree has
  no staged changes and exactly the two pre-existing unstaged parent-plan edits:
  the `devenv processes down` teardown and the temporary npm copy-link
  workaround for `duskmoon-dev/phoenix-duskmoon-ui#129`. Do not merge, push, or
  open a pull request unless the user explicitly requests that external action.

There is no commit for this task unless verification finds an in-scope defect.

---

## Completion checklist

Stop only when all are true:

- [ ] The exact seven-app graph is mechanically enforced.
- [ ] PostgreSQL is canonical and every runtime role is least privilege with
      forced fail-closed RLS.
- [ ] Owner bootstrap, login, separate unlock, idle lock, logout, and password
      rewrap work without persisting plaintext secrets.
- [ ] PDF/JPEG/PNG upload is streamed, encrypted, durable, authenticated,
      vault-scoped, and deduplicated only through the protected lookup digest.
- [ ] Key leases stop plaintext delivery at the next chunk after revocation.
- [ ] Outbox/Oban crash recovery produces one logical effect and stable runner
      identity.
- [ ] Provenance and `private` classification propagate without downgrade.
- [ ] Metadata extraction pauses while locked, resumes idempotently, and
      produces typed searchable fields only.
- [ ] Authorized PostgreSQL search is ranked, filtered, keyset-paged,
      rebuildable, and two-vault isolated.
- [ ] Logical deletion precedes safe, idempotent physical cleanup.
- [ ] Encrypted backup/restore passes the exact row, object, hash, audit, job,
      and search-equivalence oracle under concurrent mutation pressure.
- [ ] Audit, supported final JSON records originating from
      `LoggerMetadata.log/3`, supported `[:singularity, ...]` telemetry, HTML,
      LiveView application payloads, JSON, and browser console satisfy the
      secret-canary rules; no production raw dependency telemetry subscription
      exists and application logs emit only through `LoggerMetadata.log/3`.
- [ ] The Phoenix/React seam uses the versioned contract, stale-event rules,
      XHR upload, reconnect snapshot, and mandatory unmount.
- [ ] Vault Workbench passes keyboard, responsive, reduced-motion, theme, and
      WCAG AA checks.
- [ ] Integration, restore, JS, bundle, browser, architecture, xref, full
      ExUnit, and whitespace gates pass.
- [ ] No ESS package, S3, CouchDB, Qdrant, Backplane, or later-milestone
      implementation entered the branch.
