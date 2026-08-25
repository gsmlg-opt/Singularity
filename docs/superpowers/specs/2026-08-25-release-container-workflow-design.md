# Release Container and GitHub Workflow Design

**Status:** Approved design

**Date:** 2026-08-25

## 1. Purpose

Singularity is a Phoenix/OTP application, but the repository currently has one
combined CI workflow, no explicit umbrella release, and no container build.
This design adds reproducible release packaging and publishes every manually
approved release as both a multi-architecture GHCR image and an OCI archive
attached to the corresponding GitHub Release.

## 2. Approved decisions

- Publish to `ghcr.io/gsmlg-dev/singularity`.
- Authenticate with `${{ github.actor }}` and the repository secret
  `${{ secrets.GHCR_TOKEN }}`.
- Build `linux/amd64` and `linux/arm64` images.
- Attach a multi-architecture OCI image archive to GitHub Release `vX.Y.Z`.
- Keep release execution manual through `workflow_dispatch` inputs `version`
  and `git_ref`.
- Use a conventional multi-stage Dockerfile and an explicit umbrella Mix
  release rather than introducing a new Nix image package or buildpacks.
- Do not add a separate `e2e.yml`; the `cmd-setup-workflows` invocation did not
  request its `e2e` argument.

## 3. Repository changes

### 3.1 Umbrella release

The root `mix.exs` defines a release named `singularity`. The release starts
`singularity_web` permanently; Mix includes its internal application dependency
closure, including Runtime, Storage, Domains, Ingest, Retrieval, and Core.

The root project version remains the canonical release version. The manual
release workflow updates it to the validated `X.Y.Z` input before building.

### 3.2 Container image

A root multi-stage `Dockerfile`:

1. Uses pinned Elixir/Erlang and Debian build/runtime bases with both target
   architectures available.
2. Installs Hex and Rebar, fetches production dependencies, restores the frozen
   JavaScript dependency graph through Duskmoon tooling, builds/digests browser
   assets, compiles, and produces `mix release singularity`.
3. Copies only the release into a Debian slim runtime stage with required native
   runtime libraries.
4. Runs as a non-root user, exposes port 4000, and starts
   `/app/bin/singularity start`.
5. Provides owned default storage and backup directories. Database URLs,
   `SECRET_KEY_BASE`, and fingerprint secrets remain required runtime inputs.

Container startup does not provision PostgreSQL roles or run schema migrations.
Those remain explicit operator actions so multiple replicas cannot race schema
mutation during startup.

A root `.dockerignore` excludes Git metadata, local builds, fetched
dependencies, JavaScript modules, test output, worktrees, and local runtime
data while retaining source and lockfiles needed by the builder.

## 4. GitHub Actions

All workflows declare least-privilege permissions and concurrency cancellation.
Existing custom PostgreSQL role, isolated integration/restore, Duskmoon, and
Playwright gates are preserved.

### 4.1 `ci.yml`

Runs on every push and pull request. It performs static/build checks only:

- dependency lock validation;
- Elixir formatting and warnings-as-errors compilation;
- JavaScript dependency verification and source checks;
- production browser-asset build;
- architecture cycle checks.

It contains no unit, integration, restore, or browser tests.

### 4.2 `test.yml`

Runs on pushes to `main` and pull requests targeting `main`. It starts the
declared PostgreSQL service through devenv, provisions roles, and preserves the
current complete test surface:

- ExUnit unit tests;
- isolated PostgreSQL integration tests;
- isolated restore acceptance;
- JavaScript unit tests;
- Chromium Playwright acceptance.

Services are stopped in an `always()` cleanup step.

### 4.3 `release.yml`

The manual workflow accepts:

- `version`: required strict `X.Y.Z` release version;
- `git_ref`: required source branch, default `main`.

It:

1. checks out the requested branch and validates the version/tag;
2. updates the canonical root Mix version;
3. builds the OTP release and Docker image;
4. logs in to GHCR with `${{ github.actor }}` and
   `${{ secrets.GHCR_TOKEN }}`;
5. publishes a multi-platform manifest tagged `X.Y.Z`, `X.Y`, and `latest` at
   `ghcr.io/gsmlg-dev/singularity`;
6. exports a multi-platform OCI archive named for `vX.Y.Z`;
7. commits the version bump as `chore(release): vX.Y.Z`, creates tag `vX.Y.Z`,
   and pushes the commit and tag;
8. creates a GitHub Release with generated notes and attaches the OCI archive.

The workflow uses Buildx cache reuse between registry and archive exports.
Failed builds do not push the release commit/tag or create a GitHub Release.

## 5. Security and failure handling

- `GHCR_TOKEN` is used only by the Docker login action and is never placed in
  build arguments, image labels, archives, logs, or release notes.
- Workflow permissions are explicit: read-only for CI/test; `contents: write`
  and `packages: write` for release.
- The image contains no production database credentials or fingerprint secrets.
- Release validation rejects malformed versions, existing tags, and non-branch
  `git_ref` inputs before mutation.
- The OCI archive and GHCR manifest are built from the same Dockerfile, version,
  and source checkout.
- Docker builds produce provenance and SBOM metadata where supported by the
  selected stable Buildx action.

## 6. Verification

Implementation verification includes:

- YAML parsing and workflow contract checks;
- `MIX_ENV=prod mix assets.deploy`;
- `MIX_ENV=prod mix release singularity --overwrite`;
- Dockerfile build-stage validation, and a local image build when the Docker
  daemon is available;
- inspection of the release contents, executable entrypoint, static assets,
  non-root runtime user, ports, and OCI labels;
- existing format, compile, architecture, and workflow tests;
- `git diff --check` and a clean final worktree.
