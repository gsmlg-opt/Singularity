# Workflow test policy and exact release image tags

Date: 2026-10-08

Status: written specification approved by the user on 2026-10-08; implementation
explicitly authorized. Publication and deployment remain separately gated.

## Goal and approved boundary

Publish images under `ghcr.io/gsmlg-dev/singularity`, with a Docker tag exactly
matching each published GitHub Release tag. Run only unit tests automatically
on pushes to `main` and retain the existing unit checks for pull requests
targeting `main`. Integration, restore, and browser acceptance become manual-only
GitHub Actions checks, not removed verification requirements.

The user approved separate automatic unit and manual acceptance workflows over
a single workflow with conditional acceptance jobs. Static CI checks remain
unchanged. This is infrastructure work, not acceptance of a product phase.
Application behavior, package scripts, dependencies, migrations, Dockerfiles,
Vault, and version numbers are outside scope. Pushes, release dispatches, image
publication, tags, merges, and deployment remain separately authorized actions.
Do not execute browser/E2E tests while implementing this change.

## Automatic unit workflow

Keep `.github/workflows/test.yml`, its existing push-to-main and
pull-request-to-main triggers, read-only contents permission, concurrency,
pinned actions, and dependency/toolchain setup. Run `mix test` with its existing
integration exclusions and `mix npm.run test:js` (Vitest). Retain dependency
installation and verification, including the established upstream issue comments.

Retain the established PostgreSQL service startup, bounded readiness, role
bootstrap, and `always()` cleanup; do not combine this trigger-policy change
with a speculative test-environment redesign.

Remove the explicit integration, restore, asset-build-for-browser, and Chromium
acceptance steps from this automatic workflow. It must not execute
`mix singularity.test.integration`, `mix singularity.test.restore`,
`mix singularity.test.browser_restore`, or `mix npm.run test:e2e`, directly or
through a newly introduced alias. Existing test exclusions and package scripts
remain unchanged.

## Manual acceptance workflow

Create `.github/workflows/e2e.yml`, named `Manual Acceptance`, with
`workflow_dispatch` as its only event. No push, pull-request, release, schedule,
or workflow-to-workflow automatic trigger is allowed. Use the ref selected in
the Actions dispatch interface with the existing pinned checkout action; no new
version input, release download, or custom ref input is needed.

Preserve the current complete test workflow's acceptance sequence in this manual
workflow: toolchain/cache setup, service startup and readiness, role bootstrap,
dependencies, ExUnit tests, isolated PostgreSQL integration, isolated restore,
JavaScript dependency installation/verification and unit tests, browser asset
build, and Chromium acceptance. Keep assets before browser tests. Use a distinct
acceptance cache prefix, read-only contents permission, and workflow/ref-scoped
concurrency. Preserve upstream issue comments at the npm installation callsite.

Every failed prerequisite stops subsequent acceptance steps. Keep PostgreSQL
readiness bounded and always stop services, including after test failure or
cancellation. A successful unit run is not evidence of acceptance; acceptance
still needs a separately requested manual run against the relevant source.

## Release image tag amendment

The existing image-only `.github/workflows/docker-image.yml` already uses the
literal published release tag and builds its resolved Git tag source. Preserve
its manual inputs, `release: published` event, platform/digest/source validation,
shared publication concurrency, credential boundary, and stable-only `latest`
eligibility policy without modification.

The repository's own `.github/workflows/release.yml` creates releases using
`GITHUB_TOKEN`; its published-release event does not start a downstream image
workflow. Its existing image promotion currently uses the numeric version,
minor version, and `latest`, but not the literal `v`-prefixed release tag.

Amend only its verified-digest promotion by adding
`--tag "$IMAGE_NAME:$RELEASE_TAG"`. For release `v0.2.0`, the same verified digest
then backs `v0.2.0`, `0.2.0`, `0.2`, and `latest` under the existing stable-release
policy. Preserve atomic source publication, exact remote/source validation,
manifest and OCI verification, highest-version guards, existing aliases, secret
usage, and publication ordering. No named alias may be promoted before those
checks. Do not add a downstream dispatch or duplicate image rebuild.

This narrowly supersedes the prior Docker image design's prohibition on editing
`release.yml`; all its other boundaries remain intact. Workflow configuration
does not constitute proof of a hosted build or GHCR publication.

## Contracts and documentation

Amend `release_container_contract_test.exs` with failing contracts first. Replace
the old combined automatic acceptance contract with positive exact contracts
for automatic unit steps and manual-only acceptance steps. Preserve all commands
and ordering assertions in their appropriate workflow; do not delete assertions
merely to make the split pass. Replace the prohibition on `e2e.yml` with positive
coverage of its dispatch-only trigger, permissions, setup, acceptance sequence,
and always-run cleanup.

Extend release promotion checks and the executable promotion fixture to require
the exact release tag, including its absence before verified promotion. Keep the
existing image workflow contracts and fail-closed release cases passing.

Keep README's complete local verification sequence and the synchronized
canonical release plan unchanged except for adding `e2e.yml` to their explicit
actionlint file enumeration. Synchronize that enumeration in the contract and
check that manual acceptance commands remain an ordered subsequence of the
canonical full gate. Explain automatic versus manual checks in README. Update
`docs/deployment/docker.md` to document the exact tag alias and both publication
paths, retaining the token-created-event caveat and cross-organization
`GHCR_TOKEN` requirement. Do not imply full phase/release acceptance from unit CI.

Implementation files are limited to `test.yml`, new `e2e.yml`, the single release
promotion amendment, the focused release/container architecture contract,
README, the canonical release plan's actionlint enumeration, Docker deployment
documentation, and this change's design, plan, and verification record.

## Verification and next gate

Baseline: clean `main` at
`f9ea06251d4b149b371e468609934b243afd1468`. On 2026-10-08,
`devenv shell -- mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs`
passed: 28 tests, 0 failures, seed 407456. No E2E test ran. Read-only remote
inspection confirmed origin `https://github.com/gsmlg-opt/Singularity.git` and
remote `main` at `a80957da41582de40bdf586a0cba1e14644acf0a`; it does not yet contain
the locally merged Docker Image workflow.

After written-spec approval, prepare the detailed implementation plan. Execute
in `.trees/workflow-test-policy` on `codex/workflow-test-policy`, using focused
red/green architecture contracts, formatting for changed tests, actionlint for
all five workflows, shell syntax checks, zero-cycle xref, and `git diff --check`.
Record exact source commits, commands/results, changed files, and remaining
hosted-run risks. No E2E execution, GitHub dispatch, image build/publication,
push, merge, or product acceptance is included in these local checks.
