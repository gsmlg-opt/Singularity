# Docker infrastructure verification — 2026-10-01

Scope: strengthen the existing image build and add operator deployment guidance,
not accept a product phase or activate production.

Source base: `56e966e1fb7a62fd2593b857facef9672ee4b78e`, with uncommitted
Docker/deployment changes on `codex/docker-deployment`. No new commit was made.
Changed files: `Dockerfile`, `README.md`, the release/container architecture test,
`docs/deployment/docker.md`, and this record. No migration or application behavior
changed, and no Vault feature work occurred.

## Image and focused checks

Executed from the project-local Docker deployment worktree:

```bash
docker build --build-arg VERSION=0.1.0-dev \
  --build-arg REVISION=56e966e1fb7a62fd2593b857facef9672ee4b78e-dirty \
  --tag singularity:docker-deployment-56e966e .
docker build --target build --tag singularity-admin:docker-deployment-56e966e .
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
devenv shell -- mix format --check-formatted apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
devenv shell -- env MIX_ENV=test mix xref graph --format cycles --fail-above 0
git diff --check
```

Both image builds succeeded on amd64. Runtime image ID:
`sha256:b4fcef144a410fa36d169ff570f488043d8b4e0b7633ad4b1d51be16715a0dd1`.
The focused suite passed with **18 tests, 0 failures**; formatting passed and xref
reported **No cycles found**. Build-time and runtime shell checks confirmed the
release launcher, native PDF guardian, digested asset manifest, `pdfinfo`, and
`pdftotext`, with no embedded release cookie. The guide's Bash examples also
passed `bash -n` syntax validation.

## Isolated runtime smoke

A disposable PostgreSQL **17.11** instance used the existing role-provisioning
SQL, a fresh database owned by `singularity_migration`, the documented table-owner
`CREATE` grant, and fixture-only role passwords and secrets. The guide's release
migration `eval` applied all **34 migrations** successfully. Its administrative
`mix run --no-start` role-verification command reported
`PostgreSQL role contract verified`.

Each of RequestRepo, PreAuthRepo, DispatcherRepo, and WorkerRepo returned
`SELECT current_user, 1` with its expected separate role. The running container
used UID/GID **10001:10001**, the exact image ID above, and returned **HTTP 200**
from `/login`. The first-owner task's availability was checked with `mix help`,
not by creating an owner. All disposable containers, their PostgreSQL anonymous
volume, and the test network were removed after validation.

## Remaining limits

No arm64 build, browser/E2E test, owner bootstrap, public TLS check, extraction
acceptance, backup/restore acceptance, or complete README release gate was run.
These checks do not accept `0.2.0` or any unfinished product phase. The development
image carries a dirty-source label; build and record a clean exact-source artifact
before any separately authorized publication or deployment. No version bump,
tag, release, push, or production deployment occurred.
