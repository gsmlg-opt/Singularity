# Workflow test policy verification — 2026-10-08

Scope: workflow infrastructure only; no product-phase or release acceptance.

Worktree: `.trees/workflow-test-policy`, branch `codex/workflow-test-policy`.
Main remains at `f9ea06251d4b149b371e468609934b243afd1468`.
Design commit: `a461b0e1c2d4eb9b32d4b0dc4efb20ff52425ec0`.
Plan baseline: `bca424be8f52cc96e0cca1004e764403be06a8df`.
Verified implementation: `ac4497ef733be18f2ac985ab188af64c7b98e90b`
(`ci(github): update github actions workflows`).

## Changes and preserved boundaries

The implementation commit changes seven files:

- `.github/workflows/test.yml`: ExUnit/Vitest only on main pushes and main-targeting PRs.
- `.github/workflows/e2e.yml`: dispatch-only Manual Acceptance, preserving the original full test sequence.
- `.github/workflows/release.yml`: one exact RELEASE_TAG alias added to verified-digest promotion.
- `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`: exact unit/manual/tag contracts.
- `README.md`: trigger policy and five-workflow lint enumeration.
- `docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`: lint enumeration only.
- `docs/deployment/docker.md`: literal release tag and existing release-event distinction.

CI, Docker Image, application code, package scripts, dependencies/lockfiles,
Dockerfile, versions, migrations, and Vault are unchanged. No Vault feature work
or compatibility patch occurred. Existing upstream issue comments remain intact.
The full local phase/release acceptance gate remains required; moving checks to
manual execution does not remove those checks or accept the active product phase.

## Test-first evidence

Executed from this worktree:

```bash
devenv shell -- mix deps.get
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs
```

Dependency fetch exited 0 with unchanged lockfile. Unchanged baseline: 28 tests,
0 failures, seed 791973. After contract edits and before workflow edits: 29 tests,
4 expected failures, seed 264236, exit 2. Those failures identified the automatic
acceptance steps, missing manual workflow, missing exact release-tag promotion,
and old documented lint enumeration.

After implementation and synchronized documentation: 29 tests, 0 failures,
seed 45021, exit 0. Independent parent run: 29 tests, 0 failures, seed 290394,
exit 0. Post-implementation-commit run: 29 tests, 0 failures, seed 185387, exit 0.
Integration-tagged tests remained excluded throughout these focused runs.

## Static and architecture checks

```bash
devenv shell -- mix format apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
devenv shell -- mix format --check-formatted apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/e2e.yml .github/workflows/release.yml .github/workflows/docker-image.yml
devenv shell -- mix xref graph --format cycles --fail-above 0
git diff --check
git diff --cached --check
```

All exited 0. Xref reported `No cycles found`; the seven-application source graph
was not changed. Actionlint passed before and after the implementation commit.
The existing devenv version-notice was informational; devenv.lock was not changed.

Additional shell syntax-only check:

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

All 31 run blocks passed `bash -n`, exit 0. GitHub expression placeholders were
substituted for syntax checking only. None of those commands were executed.

Independent spec compliance and code-quality reviews inspected the actual diff,
manual workflow, preserved acceptance assertions, entry points, publication
guards, and documentation. Both approved with no actionable issues.

## Remaining limits and next action

No E2E/browser test, integration acceptance, restore acceptance, Vitest execution,
complete README acceptance gate, GitHub dispatch, Docker image build, registry
publication, version bump, tag, release, push, merge, or deployment occurred.
Hosted execution, cancellation cleanup on GitHub runners, multi-platform image
builds, and cross-organization GHCR write access remain unverified.

The infrastructure branch must be separately merged and pushed before these
workflow changes take effect on GitHub. Publication uses
`ghcr.io/gsmlg-dev/singularity`: the existing Release path now includes its
literal `vX.Y.Z` tag alongside numeric/minor/latest aliases, while human/App/PAT
published releases retain the image-only exact-tag path and eligible-latest guard.
This record proves local contract/static checks only, not a published image or
readiness of the unfinished `0.2.0` product release.
