# Workflow test policy implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make acceptance manual-only and publish literal GitHub release image tags without weakening verification.

**Architecture:** Keep Tests automatic for ExUnit/Vitest on main pushes and main-targeting PRs. Preserve full acceptance in a dispatch-only workflow and add one verified-digest release tag alias. Keep the image-only publication workflow unchanged.

**Tech Stack:** GitHub Actions YAML, Nix/devenv, Elixir/ExUnit, Vitest, Playwright, Docker Buildx, GHCR, actionlint.

---

Approved spec: `docs/superpowers/specs/2026-10-08-workflow-test-policy-design.md`.
User approved the written spec and explicitly requested implementation on 2026-10-08.
Worktree: `.trees/workflow-test-policy`; branch: `codex/workflow-test-policy`.
Never run E2E, integration/restore acceptance, dispatch workflows, push, merge, tag,
build/publish images, or deploy during this plan. No Vault, application, dependency,
package script, or migration changes. Scoped failures must be resolved only in scope.

## Task 1: Workflow split and promotion contracts

Owner: implementation subagent. Main owns Task 2 documentation and plan/evidence.
Do not revert another contributor's edits. Use `apply_patch` for all local edits.

**Files:**
- Modify: `.github/workflows/test.yml`
- Create: `.github/workflows/e2e.yml`
- Modify: `.github/workflows/release.yml` (promotion only)
- Modify: `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [x] **Step 1: Characterize clean baseline**

```bash
devenv shell -- mix deps.get
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs
```

Expected: 28 tests, 0 failures on unchanged source. Dependency lock must stay unchanged.

- [x] **Step 2: Add failing contracts before workflow changes**

Replace the old combined automatic acceptance test with these two complete tests.
Keep every original manual acceptance assertion; no scanner/helper relaxation.

```elixir
  test "test workflow automatically runs only unit tests" do
    workflow = workflow!("test.yml")

    assert workflow["on"] == %{
             "push" => %{"branches" => ["main"]},
             "pull_request" => %{"branches" => ["main"]}
           }

    assert workflow["permissions"] == %{"contents" => "read"}
    assert workflow["concurrency"] == @concurrency
    assert workflow["jobs"] |> Map.keys() |> Enum.sort() == ["test"]

    test_job = job!(workflow, "test")
    assert_exact_keys!(test_job, ["runs-on", "steps"])
    assert test_job["runs-on"] == "ubuntu-latest"

    steps = Map.fetch!(test_job, "steps")

    assert Enum.map(steps, &Map.fetch!(&1, "name")) == [
             "Check out repository",
             "Install Nix",
             "Configure Cachix",
             "Install devenv",
             "Restore test caches",
             "Start services",
             "Wait for PostgreSQL",
             "Provision PostgreSQL roles",
             "Fetch dependencies",
             "Run tests",
             "Install JavaScript dependencies",
             "Verify JavaScript dependencies",
             "Run JavaScript tests",
             "Stop services"
           ]

    assert_action_steps!(steps, "Restore test caches")

    assert_run_steps!(steps, [
      {"Install devenv", "nix profile add nixpkgs#devenv"},
      {"Start services", "devenv up -d"},
      {"Wait for PostgreSQL", "devenv processes wait --timeout 120"},
      {"Provision PostgreSQL roles",
       "devenv shell -- bash apps/singularity_storage/priv/repo/bootstrap_roles.sh"},
      {"Fetch dependencies", "devenv shell -- mix deps.get"},
      {"Run tests", "devenv shell -- mix test"},
      {"Install JavaScript dependencies",
       "devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen"},
      {"Verify JavaScript dependencies", "devenv shell -- mix npm.verify"},
      {"Run JavaScript tests", "devenv shell -- mix npm.run test:js"}
    ])

    cache_key = step!(steps, "Restore test caches") |> get_in(["with", "key"])

    assert cache_key ==
             "test-${{ runner.os }}-${{ hashFiles('mix.lock', 'package-lock.json', 'build/project.exs') }}"

    forbidden = ~r/(?:mix singularity\.test\.|mix npm\.run test:e2e|--include\s+integration|--only\s+integration)/
    refute Enum.any?(steps, &Regex.match?(forbidden, Map.get(&1, "run", "")))

    assert List.last(steps) == %{
             "name" => "Stop services",
             "if" => "always()",
             "run" => "devenv processes down"
           }

    assert_upstream_comments!("test.yml")
  end

  test "manual workflow preserves every exact acceptance gate" do
    workflow = workflow!("e2e.yml")

    assert workflow["name"] == "Manual Acceptance"
    assert workflow["on"] == %{"workflow_dispatch" => nil}

    assert workflow["permissions"] == %{"contents" => "read"}
    assert workflow["concurrency"] == @concurrency
    assert workflow["jobs"] |> Map.keys() |> Enum.sort() == ["acceptance"]

    test_job = job!(workflow, "acceptance")
    assert_exact_keys!(test_job, ["runs-on", "steps"])
    assert test_job["runs-on"] == "ubuntu-latest"

    steps = Map.fetch!(test_job, "steps")

    assert Enum.map(steps, &Map.fetch!(&1, "name")) == [
             "Check out repository",
             "Install Nix",
             "Configure Cachix",
             "Install devenv",
             "Restore test caches",
             "Start services",
             "Wait for PostgreSQL",
             "Provision PostgreSQL roles",
             "Fetch dependencies",
             "Run tests",
             "Run isolated PostgreSQL integration tests",
             "Run isolated restore acceptance",
             "Install JavaScript dependencies",
             "Verify JavaScript dependencies",
             "Run JavaScript tests",
             "Build browser assets",
             "Run Chromium acceptance tests",
             "Stop services"
           ]

    assert_action_steps!(steps, "Restore test caches")

    assert_run_steps!(steps, [
      {"Install devenv", "nix profile add nixpkgs#devenv"},
      {"Start services", "devenv up -d"},
      {"Wait for PostgreSQL", "devenv processes wait --timeout 120"},
      {"Provision PostgreSQL roles",
       "devenv shell -- bash apps/singularity_storage/priv/repo/bootstrap_roles.sh"},
      {"Fetch dependencies", "devenv shell -- mix deps.get"},
      {"Run tests", "devenv shell -- mix test"},
      {"Run isolated PostgreSQL integration tests",
       "devenv shell -- mix singularity.test.integration"},
      {"Run isolated restore acceptance", "devenv shell -- mix singularity.test.restore"},
      {"Install JavaScript dependencies",
       "devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen"},
      {"Verify JavaScript dependencies", "devenv shell -- mix npm.verify"},
      {"Run JavaScript tests", "devenv shell -- mix npm.run test:js"},
      {"Build browser assets",
       "devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind"},
      {"Run Chromium acceptance tests", "devenv shell -- mix npm.run test:e2e"}
    ])

    cache_key = step!(steps, "Restore test caches") |> get_in(["with", "key"])

    assert cache_key ==
             "acceptance-${{ runner.os }}-${{ hashFiles('mix.lock', 'package-lock.json', 'build/project.exs') }}"

    asset_index = Enum.find_index(steps, &(&1["name"] == "Build browser assets"))
    e2e_index = Enum.find_index(steps, &(&1["name"] == "Run Chromium acceptance tests"))
    assert asset_index < e2e_index

    assert List.last(steps) == %{
             "name" => "Stop services",
             "if" => "always()",
             "run" => "devenv processes down"
           }

    assert_upstream_comments!("e2e.yml")
  end
```

Extend the complete verification sequence test with:

```elixir
acceptance_commands = workflow_verification_commands("e2e.yml", "acceptance")
assert ordered_subsequence?(acceptance_commands, plan_commands),
       "Manual Acceptance workflow commands are not an ordered subsequence of the canonical release plan"
```

In the release contract, add:

```elixir
assert promote_run =~ ~S<--tag "$IMAGE_NAME:$RELEASE_TAG">
```

Change the pre-promotion forbidden alias regex to:

```elixir
~r/\$IMAGE_NAME:(?:\$RELEASE_TAG|\$VERSION|\$MINOR_VERSION|latest)/
```

Replace the old `refute File.exists?(... e2e.yml)` assertion with:

```elixir
assert workflow!("e2e.yml")["on"] == %{"workflow_dispatch" => nil}
```

Add this exact line before the VERSION alias in the existing
`promote_image_run/0` fixture, preserving the full existing script:

```bash
      --tag "$IMAGE_NAME:$RELEASE_TAG" \
```

Finally, the canonical actionlint command constant becomes:

```elixir
"nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/e2e.yml .github/workflows/release.yml .github/workflows/docker-image.yml"
```

- [x] **Step 3: Run RED and report exact failures before implementation**

```bash
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs
```

Expected failures: Tests still contains acceptance steps; e2e.yml missing;
literal release tag missing; documented lint enumeration still old.
Main can update documentation after RED evidence is recorded.

- [x] **Step 4: Implement the minimal approved workflows**

Complete replacement `test.yml`:

```yaml
name: Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - name: Check out repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Install Nix
        uses: cachix/install-nix-action@13d8dd58da0234aa297dedd986986ccb8e7f3e24 # v31.11.1

      - name: Configure Cachix
        uses: cachix/cachix-action@5f2d7c5294214f71b873db4b969586b980625e71 # v17
        with:
          name: devenv

      - name: Install devenv
        run: nix profile add nixpkgs#devenv

      - name: Restore test caches
        uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: |
            deps
            _build
            node_modules
            ~/.hex
            ~/.mix
            ~/.cache/rustler_precompiled
          key: test-${{ runner.os }}-${{ hashFiles('mix.lock', 'package-lock.json', 'build/project.exs') }}

      - name: Start services
        run: devenv up -d

      - name: Wait for PostgreSQL
        run: devenv processes wait --timeout 120

      - name: Provision PostgreSQL roles
        run: >-
          devenv shell -- bash
          apps/singularity_storage/priv/repo/bootstrap_roles.sh

      - name: Fetch dependencies
        run: devenv shell -- mix deps.get

      - name: Run tests
        run: devenv shell -- mix test

      - name: Install JavaScript dependencies
        # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
        # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
        run: devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen

      - name: Verify JavaScript dependencies
        run: devenv shell -- mix npm.verify

      - name: Run JavaScript tests
        run: devenv shell -- mix npm.run test:js

      - name: Stop services
        if: always()
        run: devenv processes down
```

Complete new `e2e.yml`:

```yaml
name: Manual Acceptance

on:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  acceptance:
    runs-on: ubuntu-latest

    steps:
      - name: Check out repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - name: Install Nix
        uses: cachix/install-nix-action@13d8dd58da0234aa297dedd986986ccb8e7f3e24 # v31.11.1

      - name: Configure Cachix
        uses: cachix/cachix-action@5f2d7c5294214f71b873db4b969586b980625e71 # v17
        with:
          name: devenv

      - name: Install devenv
        run: nix profile add nixpkgs#devenv

      - name: Restore test caches
        uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: |
            deps
            _build
            node_modules
            ~/.hex
            ~/.mix
            ~/.cache/rustler_precompiled
          key: acceptance-${{ runner.os }}-${{ hashFiles('mix.lock', 'package-lock.json', 'build/project.exs') }}

      - name: Start services
        run: devenv up -d

      - name: Wait for PostgreSQL
        run: devenv processes wait --timeout 120

      - name: Provision PostgreSQL roles
        run: >-
          devenv shell -- bash
          apps/singularity_storage/priv/repo/bootstrap_roles.sh

      - name: Fetch dependencies
        run: devenv shell -- mix deps.get

      - name: Run tests
        run: devenv shell -- mix test

      - name: Run isolated PostgreSQL integration tests
        run: devenv shell -- mix singularity.test.integration

      - name: Run isolated restore acceptance
        run: devenv shell -- mix singularity.test.restore

      - name: Install JavaScript dependencies
        # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
        # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
        run: devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen

      - name: Verify JavaScript dependencies
        run: devenv shell -- mix npm.verify

      - name: Run JavaScript tests
        run: devenv shell -- mix npm.run test:js

      - name: Build browser assets
        run: devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind

      - name: Run Chromium acceptance tests
        run: devenv shell -- mix npm.run test:e2e

      - name: Stop services
        if: always()
        run: devenv processes down
```

In release.yml replace only the promotion invocation with:

```bash
          docker buildx imagetools create \
            --tag "$IMAGE_NAME:$RELEASE_TAG" \
            --tag "$IMAGE_NAME:$VERSION" \
            --tag "$IMAGE_NAME:$MINOR_VERSION" \
            --tag "$IMAGE_NAME:latest" \
            "$IMAGE_NAME@$IMAGE_DIGEST"
```

- [x] **Step 5: Verify GREEN, format, lint, and review**

After Task 2 documentation lands:

```bash
devenv shell -- mix format apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs
nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/e2e.yml .github/workflows/release.yml .github/workflows/docker-image.yml
git diff --check
```

Expected: all focused tests pass; lint and whitespace checks exit 0.
Report red/green counts, seeds, changes, and concerns. Obtain independent
spec compliance review, then quality review. Fix in-scope findings and re-review.
Main commits only after the integrated checks; worker must not stage Task 2 files.

## Task 2: Documentation and integrated local evidence

Owner: main agent. Start documentation edits only after Task 1 RED is recorded.

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md` (lint enumeration only)
- Modify: `docs/deployment/docker.md`
- Modify: this plan and approved spec status
- Create: `docs/deployment/2026-10-08-workflow-test-policy-verification.md`

- [x] **Step 1: Synchronize lint commands without removing product gates**

Insert `.github/workflows/e2e.yml` immediately after test.yml in README and the
canonical release plan's existing actionlint command. Keep every other command.

```bash
nix run nixpkgs#actionlint -- \
  .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/e2e.yml \
  .github/workflows/release.yml \
  .github/workflows/docker-image.yml
```

Add this paragraph before README's full verification instructions:

```markdown
GitHub Actions runs ExUnit and JavaScript unit tests automatically on pushes to
`main` and pull requests targeting `main`. Integration, restore, and Chromium
acceptance run only through Actions → Manual Acceptance → Run workflow; select
the branch or tag to test. Static CI checks remain automatic. Unit CI does not
replace the complete phase/release verification gate below.
```

Replace the deployment guide paragraph starting "The existing `Release`
workflow remains unchanged" with:

```markdown
The existing `Release` workflow verifies and publishes images before creating
the GitHub Release. It promotes the exact release tag (for example, `v0.2.0`),
the existing numeric version (`0.2.0`), minor-version alias (`0.2`), and
`latest` from the same verified digest under its existing stable-release guards.
It creates the release using `GITHUB_TOKEN`; those token-created release events
do not trigger a second downstream image workflow. Human-, GitHub App-, or
PAT-published releases can trigger Docker Image, which publishes their exact
release tag and updates `latest` only when eligible.
See [GitHub's trigger rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).
```

- [x] **Step 2: Run integrated focused checks independently**

```bash
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs
devenv shell -- mix format --check-formatted apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/e2e.yml .github/workflows/release.yml .github/workflows/docker-image.yml
devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
```

Actionlint checks embedded shell syntax. Additionally check the changed workflow
run blocks without executing them:

```bash
devenv shell -- env MIX_ENV=test mix run --no-start -e '
for name <- ["test.yml", "e2e.yml", "release.yml"] do
  workflow = YamlElixir.read_from_file!(".github/workflows/" <> name)
  for {_job_name, job} <- workflow["jobs"], step <- job["steps"], is_binary(step["run"]) do
    source = Regex.replace(~r/\$\{\{.*?\}\}/s, step["run"], "checked-expression")
    {output, status} = System.cmd("bash", ["-n", "-c", source], stderr_to_stdout: true)
    if status != 0, do: raise("#{name}/#{step["name"]}: #{output}")
    IO.puts("syntax OK: #{name}/#{step["name"]}")
  end
end
'
```

GitHub expression placeholders are substituted only for syntax checking.
Full acceptance/E2E remains unrun.

- [x] **Step 3: Commit reviewed workflow/documentation changes**

```bash
git add .github/workflows/test.yml .github/workflows/e2e.yml .github/workflows/release.yml apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs README.md docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md docs/deployment/docker.md
git diff --cached --check
git commit -m "ci(github): update github actions workflows"
```

- [x] **Step 4: Record evidence and hand off without publication**

Record actual test/lint/xref/syntax commands, exit codes/counts/seeds, reviewed
source commit, seven changed implementation files, no migrations or Vault
changes, and no E2E/publication/merge. Mark completed plan steps and approved spec
status accurately; commit these records separately. Include remaining risks:
hosted execution and GHCR credentials/publication are unverified; default-branch
merge/push is required before the dispatch workflow is available.

## Execution selection

The user explicitly requested implementation after approving the written spec.
Use subagent-driven execution now; no additional choice gate is needed. Main
self-reviewed this plan for coverage, concrete content, bounded ownership, and
preserved acceptance requirements before implementation.
