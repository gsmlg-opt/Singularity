# Release Container and GitHub Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a production Singularity OTP container and publish each manually approved release to `ghcr.io/gsmlg-dev/singularity` plus a multi-platform OCI archive attached to GitHub Releases.

**Architecture:** Define one explicit root umbrella release whose permanent entry application is `singularity_web`. Build it in a pinned multi-stage Dockerfile, split static checks from tests, and add a manual Buildx release workflow that uses `${{ github.actor }}` with `${{ secrets.GHCR_TOKEN }}` to publish `linux/amd64` and `linux/arm64` images.

**Tech Stack:** Elixir 1.18.4, Erlang/OTP 28.4.3, Phoenix 1.8, DuskmoonBundler 9.12.2, Debian Trixie slim, Docker Buildx, GHCR, GitHub Actions, ExUnit.

---

## File map

- Modify `mix.exs`: define the canonical `singularity` umbrella release.
- Create `Dockerfile`: build assets and the OTP release, then copy it into a non-root runtime image.
- Create `.dockerignore`: keep local build/runtime/test data outside the build context.
- Modify `.github/workflows/ci.yml`: retain static and build checks only.
- Create `.github/workflows/test.yml`: preserve the current unit, integration, restore, JavaScript, and browser test gates.
- Create `.github/workflows/release.yml`: validate, build, publish, version, tag, and create the GitHub Release.
- Create `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`: pin the release, container, and workflow contracts.

The implementation is committed once at the end as required by `cmd-setup-workflows`.

### Task 1: Define and prove the umbrella release

**Files:**

- Modify: `mix.exs`
- Create: `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Add the failing root-release contract test**

Create `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs` with the initial release assertion:

```elixir
defmodule Singularity.Architecture.ReleaseContainerContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)

  test "root project defines the singularity OTP release" do
    source = read!("mix.exs")

    assert source =~ ~r/releases:\s*\[/
    assert source =~ ~r/singularity:\s*\[/

    assert source =~
             ~r/applications:\s*\[\s*singularity_web:\s*:permanent\s*\]/
  end

  defp read!(path), do: File.read!(Path.join(@repo_root, path))
end
```

- [ ] **Step 2: Run the test and the current release command to verify RED**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
MIX_ENV=prod devenv shell -- mix release singularity --overwrite
```

Expected:

- ExUnit fails because `releases:` is absent.
- `mix release` fails because the umbrella has no release named `singularity` or no explicit applications.

- [ ] **Step 3: Add the explicit release definition**

Add `releases: releases()` to the root project configuration and add the function:

```elixir
def project do
  [
    apps_path: "apps",
    version: "0.1.0",
    elixir: Singularity.Build.elixir_requirement(),
    start_permanent: Mix.env() == :prod,
    preferred_cli_env: [
      "singularity.test.integration": :test,
      "singularity.test.restore": :test,
      "singularity.test.browser": :test,
      "singularity.test.browser_restore": :test
    ],
    releases: releases(),
    aliases: aliases(),
    deps: deps()
  ]
end

defp releases do
  [
    singularity: [
      applications: [singularity_web: :permanent]
    ]
  ]
end
```

- [ ] **Step 4: Verify the release is GREEN**

Run:

```bash
devenv shell -- mix format --check-formatted mix.exs \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
MIX_ENV=prod devenv shell -- mix release singularity --overwrite
test -x _build/prod/rel/singularity/bin/singularity
```

Expected: one ExUnit test passes, the release builds, and the launcher is executable.

### Task 2: Add the production Docker image

**Files:**

- Create: `Dockerfile`
- Create: `.dockerignore`
- Modify: `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Add failing Dockerfile and build-context contract tests**

Add these tests before creating either file:

```elixir
test "Dockerfile builds and runs only the OTP release" do
  dockerfile = read!("Dockerfile")

  assert dockerfile =~
           "hexpm/elixir:1.18.4-erlang-28.4.3-debian-trixie-20260610-slim@sha256:4098ebb001f526e4891ce6fe900d2057ceed9fe18f7c4351595c3c39efe53251"

  assert dockerfile =~
           "debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132"

  assert dockerfile =~ "MIX_ENV=prod mix assets.deploy"
  assert dockerfile =~ "MIX_ENV=prod mix release singularity"
  assert dockerfile =~ "COPY --from=build"
  assert dockerfile =~ "_build/prod/rel/singularity"
  assert dockerfile =~ "USER 10001:10001"
  assert dockerfile =~ ~s(EXPOSE 4000)
  assert dockerfile =~ ~s(ENTRYPOINT ["/app/bin/singularity"])
  assert dockerfile =~ ~s(CMD ["start"])

  refute dockerfile =~ "SECRET_KEY_BASE="
  refute dockerfile =~ "SINGULARITY_DATABASE_URL="
  refute dockerfile =~ "GHCR_TOKEN"
end

test "Docker build context excludes local and private state" do
  ignored = read!(".dockerignore")

  for path <- [
        ".git",
        ".trees",
        "_build",
        "deps",
        "node_modules",
        "test-results",
        "playwright-report",
        ".env*"
      ] do
    assert ignored =~ path
  end
end
```

- [ ] **Step 2: Run the focused test to verify RED**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected: the release test passes and both Docker tests fail because the files are absent.

- [ ] **Step 3: Create the multi-stage Dockerfile**

Create `Dockerfile`:

```dockerfile
FROM hexpm/elixir:1.18.4-erlang-28.4.3-debian-trixie-20260610-slim@sha256:4098ebb001f526e4891ce6fe900d2057ceed9fe18f7c4351595c3c39efe53251 AS build

ENV LANG=C.UTF-8 \
    MIX_ENV=prod

WORKDIR /app

RUN apt-get update \
    && apt-get install --yes --no-install-recommends build-essential ca-certificates git \
    && rm -rf /var/lib/apt/lists/* \
    && mix local.hex --force \
    && mix local.rebar --force

COPY mix.exs mix.lock package.json package-lock.json ./
COPY build ./build
COPY config/config.exs config/config.exs
COPY apps/singularity_core/mix.exs apps/singularity_core/
COPY apps/singularity_domains/mix.exs apps/singularity_domains/
COPY apps/singularity_ingest/mix.exs apps/singularity_ingest/
COPY apps/singularity_retrieval/mix.exs apps/singularity_retrieval/
COPY apps/singularity_runtime/mix.exs apps/singularity_runtime/
COPY apps/singularity_storage/mix.exs apps/singularity_storage/
COPY apps/singularity_web/mix.exs apps/singularity_web/

RUN mix deps.get --only prod \
    && mix deps.compile

COPY config ./config
COPY apps ./apps

RUN NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen \
    && mix npm.verify \
    && mix compile \
    && MIX_ENV=prod mix assets.deploy \
    && MIX_ENV=prod mix release singularity

FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132 AS runtime

ARG VERSION=0.0.0-dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="Singularity" \
      org.opencontainers.image.description="Private knowledge core" \
      org.opencontainers.image.source="https://github.com/gsmlg-opt/Singularity" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

ENV LANG=C.UTF-8 \
    HOME=/app \
    PORT=4000 \
    SINGULARITY_STORAGE_ROOT=/var/lib/singularity/storage \
    SINGULARITY_BACKUP_ROOT=/var/lib/singularity/backups

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates libstdc++6 libncurses6 locales openssl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 singularity \
    && useradd --uid 10001 --gid 10001 --home-dir /app --shell /usr/sbin/nologin singularity \
    && mkdir -p /app /var/lib/singularity/storage /var/lib/singularity/backups \
    && chown -R 10001:10001 /app /var/lib/singularity

WORKDIR /app

COPY --from=build --chown=10001:10001 /app/_build/prod/rel/singularity ./

USER 10001:10001

EXPOSE 4000

ENTRYPOINT ["/app/bin/singularity"]
CMD ["start"]
```

- [ ] **Step 4: Create the build-context exclusions**

Create `.dockerignore`:

```text
.git
.github
.trees
_build
deps
node_modules
test
test-results
playwright-report
docs
.env*
*.log
tmp
result
apps/singularity_web/priv/static/assets
apps/singularity_web/priv/static/cache_manifest.json
```

- [ ] **Step 5: Verify the Docker contracts and local image when available**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
git diff --check
if docker info >/dev/null 2>&1; then
  docker buildx build \
    --platform linux/amd64 \
    --build-arg VERSION=0.1.0 \
    --build-arg REVISION="$(git rev-parse HEAD)" \
    --load \
    --tag singularity:workflow-test \
    .
  test "$(docker image inspect singularity:workflow-test --format '{{.Config.User}}')" = "10001:10001"
  test "$(docker image inspect singularity:workflow-test --format '{{json .Config.Entrypoint}}')" = '["/app/bin/singularity"]'
fi
```

Expected: all contract tests pass. When Docker is available, the image builds and its user/entrypoint are exact.

### Task 3: Split static checks from tests

**Files:**

- Modify: `.github/workflows/ci.yml`
- Create: `.github/workflows/test.yml`
- Modify: `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Add failing CI/test workflow contract tests**

Append:

```elixir
test "CI contains static checks and no tests" do
  ci = read!(".github/workflows/ci.yml")

  assert ci =~ "actions/checkout@v7.0.1"
  assert ci =~ "cachix/install-nix-action@v31.11.1"
  assert ci =~ "cachix/cachix-action@v17"
  assert ci =~ "actions/cache@v6.1.0"
  assert ci =~ "mix format --check-formatted"
  assert ci =~ "mix compile --warnings-as-errors"
  assert ci =~ "mix duskmoon_bundler.js.check"
  assert ci =~ "mix duskmoon_bundler.build singularity_web --tailwind"
  assert ci =~ "mix xref graph --format cycles --fail-above 0"
  assert ci =~ "permissions:\n  contents: read"
  assert ci =~ "concurrency:"

  refute ci =~ "mix test"
  refute ci =~ "singularity.test.integration"
  refute ci =~ "singularity.test.restore"
  refute ci =~ "test:js"
  refute ci =~ "test:e2e"
end

test "test workflow preserves every current acceptance gate" do
  workflow = read!(".github/workflows/test.yml")

  assert workflow =~ "push:\n    branches: [main]"
  assert workflow =~ "pull_request:\n    branches: [main]"
  assert workflow =~ "permissions:\n  contents: read"
  assert workflow =~ "concurrency:"
  assert workflow =~ "devenv up -d"
  assert workflow =~ "bootstrap_roles.sh"
  assert workflow =~ "devenv shell -- mix test"
  assert workflow =~ "mix singularity.test.integration"
  assert workflow =~ "mix singularity.test.restore"
  assert workflow =~ "mix npm.run test:js"
  assert workflow =~ "mix duskmoon_bundler.build singularity_web --tailwind"
  assert workflow =~ "mix npm.run test:e2e"
  assert workflow =~ "if: always()"
  assert workflow =~ "devenv processes down"
end
```

- [ ] **Step 2: Run the contract test to verify RED**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected: Docker/release tests pass; workflow tests fail because `ci.yml` is still combined and `test.yml` is absent.

- [ ] **Step 3: Replace `ci.yml` with the static/build workflow**

Write `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
  pull_request:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  checks:
    runs-on: ubuntu-latest

    steps:
      - name: Check out repository
        uses: actions/checkout@v7.0.1

      - name: Install Nix
        uses: cachix/install-nix-action@v31.11.1

      - name: Configure Cachix
        uses: cachix/cachix-action@v17
        with:
          name: devenv

      - name: Install devenv
        run: nix profile add nixpkgs#devenv

      - name: Restore build caches
        uses: actions/cache@v6.1.0
        with:
          path: |
            deps
            _build
            node_modules
            ~/.hex
            ~/.mix
            ~/.cache/rustler_precompiled
          key: ci-${{ runner.os }}-${{ hashFiles('mix.lock', 'package-lock.json', 'build/project.exs') }}

      - name: Fetch dependencies
        run: devenv shell -- mix deps.get

      - name: Check unused lock entries
        run: devenv shell -- mix deps.unlock --check-unused

      - name: Check formatting
        run: devenv shell -- mix format --check-formatted

      - name: Compile without warnings
        run: devenv shell -- mix compile --warnings-as-errors

      - name: Install JavaScript dependencies
        # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
        # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#129
        run: devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen

      - name: Verify JavaScript dependencies
        run: devenv shell -- mix npm.verify

      - name: Check JavaScript sources
        run: devenv shell -- mix duskmoon_bundler.js.check

      - name: Build browser assets
        run: devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind

      - name: Check source cycles
        run: devenv shell -- mix xref graph --format cycles --fail-above 0
```

- [ ] **Step 4: Create `test.yml` with the preserved test surface**

Create `.github/workflows/test.yml`:

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
        uses: actions/checkout@v7.0.1

      - name: Install Nix
        uses: cachix/install-nix-action@v31.11.1

      - name: Configure Cachix
        uses: cachix/cachix-action@v17
        with:
          name: devenv

      - name: Install devenv
        run: nix profile add nixpkgs#devenv

      - name: Restore test caches
        uses: actions/cache@v6.1.0
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

- [ ] **Step 5: Verify the split workflows**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml
```

Expected: contract tests pass and actionlint emits no diagnostics.

### Task 4: Add the manual multi-platform release workflow

**Files:**

- Create: `.github/workflows/release.yml`
- Modify: `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Add the failing release-workflow contract test**

Append:

```elixir
test "release workflow publishes GHCR images and an OCI release archive" do
  release = read!(".github/workflows/release.yml")

  assert release =~ "workflow_dispatch:"
  assert release =~ "version:"
  assert release =~ "git_ref:"
  assert release =~ "contents: write"
  assert release =~ "packages: write"
  assert release =~ "actions/checkout@v7.0.1"
  assert release =~ "erlef/setup-beam@v1.24.1"
  assert release =~ "docker/setup-qemu-action@v4.2.0"
  assert release =~ "docker/setup-buildx-action@v4.3.0"
  assert release =~ "docker/login-action@v4.6.0"
  assert release =~ "docker/metadata-action@v6.2.0"
  assert release =~ "docker/build-push-action@v7.3.0"
  assert release =~ "ghcr.io/gsmlg-dev/singularity"
  assert release =~ "linux/amd64,linux/arm64"
  assert release =~ "secrets.GHCR_TOKEN"
  assert release =~ "github.actor"
  assert release =~ "outputs: type=oci,dest=${{ env.OCI_ARCHIVE }}"
  assert release =~ "OCI_ARCHIVE=/tmp/"
  assert release =~ "chore(release): v${VERSION}"
  assert release =~ "gh release create"
  assert release =~ "--generate-notes"

  refute release =~ "GHCR_TOKEN="
  refute release =~ "build-args: |\n          GHCR_TOKEN"
end
```

- [ ] **Step 2: Run the contract test to verify RED**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected: prior tests pass; the release workflow test fails because `release.yml` is absent.

- [ ] **Step 3: Create the release workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  workflow_dispatch:
    inputs:
      version:
        description: Release version (for example 1.2.3)
        required: true
        type: string
      git_ref:
        description: Git branch to release from
        required: true
        default: main
        type: string

permissions:
  contents: write
  packages: write
  id-token: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

env:
  IMAGE_NAME: ghcr.io/gsmlg-dev/singularity

jobs:
  release:
    runs-on: ubuntu-latest
    timeout-minutes: 120

    steps:
      - name: Check out release source
        uses: actions/checkout@v7.0.1
        with:
          ref: ${{ inputs.git_ref }}
          fetch-depth: 0

      - name: Set up Elixir and Erlang
        uses: erlef/setup-beam@v1.24.1
        with:
          elixir-version: 1.18.4
          otp-version: 28.4.3

      - name: Validate release inputs and update version
        shell: bash
        env:
          RELEASE_VERSION: ${{ inputs.version }}
          RELEASE_REF: ${{ inputs.git_ref }}
        run: |
          set -euo pipefail
          if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "version must use X.Y.Z" >&2
            exit 1
          fi
          git check-ref-format "refs/heads/$RELEASE_REF"
          git ls-remote --exit-code --heads origin "refs/heads/$RELEASE_REF" >/dev/null
          if git ls-remote --exit-code --tags origin "refs/tags/v$RELEASE_VERSION" >/dev/null; then
            echo "release tag already exists" >&2
            exit 1
          fi
          python3 - "$RELEASE_VERSION" <<'PY'
          import pathlib
          import re
          import sys

          path = pathlib.Path("mix.exs")
          source = path.read_text()
          updated, count = re.subn(
              r'(version:\s*")[^"]+(")',
              rf'\g<1>{sys.argv[1]}\g<2>',
              source,
              count=1,
          )
          if count != 1 or updated == source:
              raise SystemExit("canonical Mix version was not updated")
          path.write_text(updated)
          PY
          git diff --check
          echo "VERSION=$RELEASE_VERSION" >> "$GITHUB_ENV"
          echo "MINOR_VERSION=${RELEASE_VERSION%.*}" >> "$GITHUB_ENV"
          echo "RELEASE_TAG=v$RELEASE_VERSION" >> "$GITHUB_ENV"
          echo "OCI_ARCHIVE=/tmp/singularity-v$RELEASE_VERSION-linux-amd64-arm64.oci.tar" >> "$GITHUB_ENV"

      - name: Build the OTP release artifact
        shell: bash
        run: |
          set -euo pipefail
          mix local.hex --force
          mix local.rebar --force
          MIX_ENV=prod mix deps.get --only prod
          NPM_EX_LINK_STRATEGY=copy MIX_ENV=prod mix npm.install --frozen
          MIX_ENV=prod mix npm.verify
          MIX_ENV=prod mix compile --warnings-as-errors
          MIX_ENV=prod mix assets.deploy
          MIX_ENV=prod mix release singularity --overwrite
          test -x _build/prod/rel/singularity/bin/singularity

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v4.2.0

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v4.3.0

      - name: Log in to GHCR
        uses: docker/login-action@v4.6.0
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GHCR_TOKEN }}

      - name: Generate image metadata
        id: metadata
        uses: docker/metadata-action@v6.2.0
        with:
          images: ${{ env.IMAGE_NAME }}
          tags: |
            type=raw,value=${{ env.VERSION }}
            type=raw,value=${{ env.MINOR_VERSION }}
            type=raw,value=latest
          labels: |
            org.opencontainers.image.version=${{ env.VERSION }}
            org.opencontainers.image.revision=${{ github.sha }}
            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}

      - name: Export the multi-platform OCI archive
        uses: docker/build-push-action@v7.3.0
        with:
          context: .
          file: Dockerfile
          platforms: linux/amd64,linux/arm64
          push: false
          outputs: type=oci,dest=${{ env.OCI_ARCHIVE }}
          build-args: |
            VERSION=${{ env.VERSION }}
            REVISION=${{ github.sha }}
          cache-from: type=gha,scope=release
          cache-to: type=gha,mode=max,scope=release
          provenance: false
          sbom: false

      - name: Build and push the multi-platform image
        uses: docker/build-push-action@v7.3.0
        with:
          context: .
          file: Dockerfile
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ steps.metadata.outputs.tags }}
          labels: ${{ steps.metadata.outputs.labels }}
          build-args: |
            VERSION=${{ env.VERSION }}
            REVISION=${{ github.sha }}
          cache-from: type=gha,scope=release
          provenance: mode=max
          sbom: true

      - name: Commit and tag the release
        shell: bash
        env:
          RELEASE_REF: ${{ inputs.git_ref }}
        run: |
          set -euo pipefail
          git config user.name github-actions[bot]
          git config user.email 41898282+github-actions[bot]@users.noreply.github.com
          git add mix.exs
          git commit -m "chore(release): v${VERSION}"
          git tag -a "$RELEASE_TAG" -m "Singularity $RELEASE_TAG"
          git push origin "HEAD:refs/heads/$RELEASE_REF"
          git push origin "$RELEASE_TAG"

      - name: Create GitHub Release
        shell: bash
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          sha256sum "$OCI_ARCHIVE" > "$OCI_ARCHIVE.sha256"
          gh release create "$RELEASE_TAG" \
            "$OCI_ARCHIVE" \
            "$OCI_ARCHIVE.sha256" \
            --title "Singularity $RELEASE_TAG" \
            --generate-notes \
            --verify-tag
```

- [ ] **Step 4: Verify all workflow contracts and YAML**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
nix run nixpkgs#actionlint -- .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/release.yml
```

Expected: all contract tests pass and actionlint emits no diagnostics.

### Task 5: Run the release/container finish gate and commit once

**Files:**

- Modify: `mix.exs`
- Create: `Dockerfile`
- Create: `.dockerignore`
- Modify: `.github/workflows/ci.yml`
- Create: `.github/workflows/test.yml`
- Create: `.github/workflows/release.yml`
- Create: `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Run the complete static and release build gate**

Run:

```bash
devenv shell -- mix deps.get
devenv shell -- mix deps.unlock --check-unused
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs \
  apps/singularity_web/test/singularity/web/asset_toolchain_contract_test.exs \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs
devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
devenv shell -- mix npm.verify
devenv shell -- mix duskmoon_bundler.js.check
MIX_ENV=prod devenv shell -- mix assets.deploy
MIX_ENV=prod devenv shell -- mix release singularity --overwrite
test -x _build/prod/rel/singularity/bin/singularity
devenv shell -- mix xref graph --format cycles --fail-above 0
nix run nixpkgs#actionlint -- .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/release.yml
git diff --check
git status --short --branch
```

Expected: all checks pass and status lists only the seven intended paths.

- [ ] **Step 2: Inspect release and workflow security boundaries**

Run:

```bash
test ! -e _build/prod/rel/singularity/releases/COOKIE
rg -n 'GHCR_TOKEN|SECRET_KEY_BASE|SINGULARITY_.*DATABASE_URL' Dockerfile .github/workflows/release.yml
rg -n 'linux/amd64,linux/arm64|type=oci|ghcr.io/gsmlg-dev/singularity' \
  .github/workflows/release.yml
```

Expected:

- No release cookie file is committed or added to the Docker context.
- `GHCR_TOKEN` appears only as `secrets.GHCR_TOKEN` in the login step.
- Production secrets and database URLs do not appear as Docker build arguments or image defaults.
- Multi-platform registry and OCI archive outputs are explicit.

- [ ] **Step 3: Run the local Docker inspection when a daemon is available**

Run:

```bash
if docker info >/dev/null 2>&1; then
  docker buildx build \
    --platform linux/amd64 \
    --build-arg VERSION=0.1.0 \
    --build-arg REVISION="$(git rev-parse HEAD)" \
    --load \
    --tag singularity:workflow-test \
    .
  docker image inspect singularity:workflow-test --format '{{json .Config}}'
  docker image rm singularity:workflow-test
fi
```

Expected: when Docker is available, the image builds, inspection shows user `10001:10001`, entrypoint `/app/bin/singularity`, command `start`, and exposed port `4000/tcp`; the temporary image is removed.

- [ ] **Step 4: Create the single required implementation commit**

Run:

```bash
git add mix.exs Dockerfile .dockerignore \
  .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/release.yml \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
git diff --cached --check
git commit -m "ci(github): update github actions workflows"
git show --check --stat --oneline HEAD
git status --short --branch
```

Expected: one implementation commit contains exactly the seven intended paths; the worktree is clean and nothing is pushed.
