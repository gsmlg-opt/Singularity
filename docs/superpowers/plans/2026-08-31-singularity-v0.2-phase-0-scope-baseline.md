# Singularity v0.2.0 Phase 0 Scope Lock and Green Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish an enforceable Vault freeze and authoritative `0.2.0` knowledge-base scope, reconcile active verification guidance with CI and Tests, and prove a clean local and live-remote baseline without changing production code or behavior.

**Architecture:** Keep Phase 0 entirely in governance documents, active documentation, and architecture contract tests. Extend the existing Notes scope contract to enforce the approved owner-scope, Vault, and Qdrant boundaries; extend the existing release/container contract to prove that the README gate matches the canonical release directive and covers CI and Tests. Preserve all production paths, released migrations, historical specifications, application versions, and release automation.

**Tech Stack:** Markdown, Elixir 1.18.4, Erlang/OTP 28, ExUnit, YAML workflow contracts, devenv/Nix, PostgreSQL, npm_ex, Vitest, Playwright, actionlint, Git, and GitHub CLI.

---

## Scope and execution boundary

This plan implements only Phase 0 from:

- `docs/superpowers/specs/2026-08-31-singularity-v0.2-release-design.md`
- `docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`

The implementation branch and worktree already exist:

- Branch: `codex/v0.2-phase-0-scope-baseline`
- Worktree: `.trees/v0.2-phase-0-scope-baseline`
- Starting main SHA: `5151febde7d94c92877f7a49525e0e2add5b2faf`
- Reviewed `v0.1.0` source: `c49dc0aeda1d0115b20ff291f0da658f7e558b43`
- Approved design commit: `a4cdd0b`

Execution prerequisite: the planner commits this detailed plan before the
implementation handoff. Task 1 therefore starts from a clean worktree whose
newest commit is the plan checkpoint.

Allowed implementation files:

- `AGENTS.md`
- `README.md`
- `docs/guide.md`
- `docs/adr/0003-vault-frozen-for-knowledge-base-development.md`
- `apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`
- `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

This detailed plan is added before implementation. The approved design and
canonical release directive are already committed and must not be rewritten
except for an independently reviewed correction to a proven contradiction.

Phase 0 must not modify:

- any production file under `apps/*/lib`, `apps/*/priv`, `config`, `rel`, or
  `Dockerfile`;
- any released migration;
- `.github/workflows/release.yml` or release behavior;
- any application version;
- any existing historical specification or implementation plan;
- Vault production behavior, schema, APIs, tests, commands, telemetry, or UX;
- Phase 1 model, migration, extraction, retrieval, or Web code.

Any production-code or production-behavior repair requires a design amendment
and explicit user approval before work begins. A failing required gate is
evidence to report, not authority to expand this plan.

## File map

- Create `AGENTS.md`: project-local scope lock, phase protocol, Vault freeze,
  architectural boundaries, verification policy, and stop conditions.
- Create
  `docs/adr/0003-vault-frozen-for-knowledge-base-development.md`: accepted
  decision that freezes Vault and replaces the active ownership invariant.
- Modify `README.md`: identify the active `0.2.0` knowledge-base release,
  point to governing documents, remove active Qdrant direction, and copy the
  canonical complete verification sequence exactly.
- Modify `docs/guide.md`: add the `0.2.0` supersession notice, preserve
  sections 1–20 as architecture and compatibility context, replace the stale
  forward-looking roadmap, correct the owner-scope invariant and ADR index,
  and define the current Phase 0 gate.
- Modify
  `apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`:
  enforce the governance documents and active README/guide scope markers
  without globally banning legitimate historical Vault or Qdrant text.
- Modify
  `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`:
  require README and the canonical plan to expose the same complete gate and
  require that gate to contain the CI and Tests workflow commands in order.

### Task 1: Confirm the isolated branch and live release baseline

**Files:**

- Verify: `.gitignore`
- Verify: `mix.exs`
- Verify: `apps/*/mix.exs`
- Verify: `docs/superpowers/specs/2026-08-31-singularity-v0.2-release-design.md`
- Verify: `docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`
- Verify: `.github/workflows/ci.yml`
- Verify: `.github/workflows/test.yml`

- [ ] **Step 1: Confirm the existing Phase 0 worktree**

Run from the Phase 0 worktree:

```bash
git branch --show-current
git status --short --branch
git merge-base HEAD main
git log -3 --oneline
grep -qxF '/.trees/' .gitignore
```

Expected:

- the branch is `codex/v0.2-phase-0-scope-baseline`;
- the tree is clean;
- the merge base is
  `5151febde7d94c92877f7a49525e0e2add5b2faf`;
- the approved design and this plan are the newest documentation commits; and
- `.trees` is ignored.

If this worktree is absent, use the `using-git-worktrees` skill from the clean
root checkout and recreate it under `.trees/v0.2-phase-0-scope-baseline`.
Never create a worktree outside the project `.trees` directory.

- [ ] **Step 2: Prove the local baseline and version freeze**

Run:

```bash
set -euo pipefail
test "$(git rev-parse main)" = "5151febde7d94c92877f7a49525e0e2add5b2faf"
test "$(git rev-parse origin/main)" = "5151febde7d94c92877f7a49525e0e2add5b2faf"
test "$(git rev-list -n 1 v0.1.0)" = "c49dc0aeda1d0115b20ff291f0da658f7e558b43"

for phase0_mix_file in mix.exs apps/*/mix.exs; do
  rg -q 'version: "0\.1\.0"' "$phase0_mix_file"
done

test "$(find apps -mindepth 2 -maxdepth 2 -name mix.exs | wc -l | tr -d ' ')" = "7"
```

Expected: all assertions pass. The umbrella root and all seven child
applications remain `0.1.0`. Do not bump any version during Phase 0.

- [ ] **Step 3: Verify the live remote baseline fail-closed**

Run this bounded, read-only script. It uses a private temporary directory and
removes only that exact directory on exit:

```bash
(
set -euo pipefail

phase0_repo="gsmlg-opt/Singularity"
phase0_expected_main="5151febde7d94c92877f7a49525e0e2add5b2faf"
phase0_expected_v01_source="c49dc0aeda1d0115b20ff291f0da658f7e558b43"
phase0_remote_timeout="45s"
phase0_evidence_dir="$(mktemp -d)"
trap 'rm -rf "$phase0_evidence_dir"' EXIT

test "$(git branch --show-current)" = "codex/v0.2-phase-0-scope-baseline"
test -z "$(git status --porcelain)"
test "$(git rev-parse main)" = "$phase0_expected_main"
test "$(git rev-parse origin/main)" = "$phase0_expected_main"
test "$(git merge-base HEAD main)" = "$phase0_expected_main"

phase0_remote_main="$(
  timeout --foreground "$phase0_remote_timeout" \
    git ls-remote --exit-code --heads origin refs/heads/main |
    awk 'NR == 1 { print $1 } END { if (NR != 1) exit 1 }'
)"
test "$phase0_remote_main" = "$phase0_expected_main"

phase0_remote_tags="$(
  timeout --foreground "$phase0_remote_timeout" \
    git ls-remote --exit-code origin \
      refs/tags/v0.1.0 'refs/tags/v0.1.0^{}'
)"
phase0_remote_tag_object="$(
  awk '$2 == "refs/tags/v0.1.0" { print $1 }' <<<"$phase0_remote_tags"
)"
phase0_remote_tag_source="$(
  awk '$2 == "refs/tags/v0.1.0^{}" { print $1 }' <<<"$phase0_remote_tags"
)"
test -n "$phase0_remote_tag_object"
test "$phase0_remote_tag_object" = "$(git rev-parse 'v0.1.0^{tag}')"
test "$phase0_remote_tag_source" = "$phase0_expected_v01_source"
test "$phase0_remote_tag_source" = "$(git rev-parse 'v0.1.0^{commit}')"

phase0_gh_api() {
  timeout --foreground "$phase0_remote_timeout" \
    env GODEBUG=http2client=0 gh api "$@"
}

phase0_gh_api "repos/$phase0_repo/releases/tags/v0.1.0" \
  >"$phase0_evidence_dir/release.json"

jq -e '
  .tag_name == "v0.1.0" and
  .draft == false and
  .prerelease == false and
  ([.assets[].name] | sort) ==
    [
      "singularity-v0.1.0-linux-amd64-arm64.oci.tar",
      "singularity-v0.1.0-linux-amd64-arm64.oci.tar.sha256"
    ]
' "$phase0_evidence_dir/release.json" >/dev/null

jq -n \
  --arg remote_main "$phase0_remote_main" \
  --arg tag_object "$phase0_remote_tag_object" \
  --arg tag_source "$phase0_remote_tag_source" \
  '{remote_main: $remote_main, tag_object: $tag_object, tag_source: $tag_source}'

jq '{
  tag_name,
  draft,
  prerelease,
  published_at,
  html_url,
  assets: [.assets[].name]
}' "$phase0_evidence_dir/release.json"

for phase0_workflow in ci.yml test.yml; do
  phase0_gh_api "repos/$phase0_repo/actions/workflows/$phase0_workflow" \
    >"$phase0_evidence_dir/$phase0_workflow.json"

  jq -e --arg path ".github/workflows/$phase0_workflow" '
    .path == $path and .state == "active"
  ' "$phase0_evidence_dir/$phase0_workflow.json" >/dev/null

  phase0_gh_api \
    "repos/$phase0_repo/actions/workflows/$phase0_workflow/runs?branch=main&event=push&per_page=100" \
    >"$phase0_evidence_dir/$phase0_workflow-runs.json"

  jq -e --arg sha "$phase0_remote_main" '
    [.workflow_runs[] | select(.head_sha == $sha)]
    | sort_by(.run_started_at // .created_at)
    | . as $runs
    | ($runs | length) > 0
      and $runs[-1].status == "completed"
      and $runs[-1].conclusion == "success"
  ' "$phase0_evidence_dir/$phase0_workflow-runs.json" >/dev/null

  jq --arg sha "$phase0_remote_main" '
    [.workflow_runs[] | select(.head_sha == $sha)]
    | sort_by(.run_started_at // .created_at)
    | last
    | {
        id,
        name,
        head_sha,
        status,
        conclusion,
        event,
        created_at,
        run_started_at,
        html_url
      }
  ' "$phase0_evidence_dir/$phase0_workflow-runs.json"
done
)
```

Expected:

- remote `main` equals `5151febde7d94c92877f7a49525e0e2add5b2faf`;
- annotated tag `v0.1.0` peels to
  `c49dc0aeda1d0115b20ff291f0da658f7e558b43`;
- GitHub Release `v0.1.0` is published, not draft/prerelease, and contains
  exactly the OCI archive and checksum assets;
- `ci.yml` and `test.yml` are active; and
- the latest push run for each workflow at the exact remote main SHA completed
  successfully, with its literal JSON evidence printed.

A timeout exits `124`. A timeout, missing ref, unexpected asset set, inactive
workflow, absent exact-SHA run, or non-success conclusion is unverified
baseline evidence. Report it and stop completion of Phase 0. Independent
documentation work may continue only if it does not conceal, weaken, or
bypass the missing evidence.

- [ ] **Step 4: Re-run the focused unchanged architecture baseline**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs \
  apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs \
  apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
```

Expected before new tests: `36 tests, 0 failures`.

- [ ] **Step 5: Record the established behavior inventory**

Verify the representative characterization tests that later phases must
preserve:

```bash
set -euo pipefail

for phase0_characterization_test in \
  apps/singularity_runtime/test/singularity/runtime/api_test.exs \
  apps/singularity_runtime/test/singularity/runtime/note_api_test.exs \
  apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs \
  apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs \
  apps/singularity_storage/test/singularity/storage/note_schema_test.exs \
  apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs \
  apps/singularity_storage/test/singularity/storage/postgres/note_search_store_test.exs \
  apps/singularity_retrieval/test/singularity/retrieval/note_lexical_search_test.exs \
  apps/singularity_web/test/singularity/web/notes_live_test.exs \
  apps/singularity_web/test/singularity/web/note_export_controller_test.exs \
  apps/singularity_runtime/test/singularity/runtime/asset_vertical_test.exs \
  apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs \
  apps/singularity_runtime/test/singularity/runtime/asset_deletion_test.exs \
  apps/singularity_runtime/test/singularity/runtime/asset_search_test.exs \
  apps/singularity_storage/test/singularity/storage/postgres/asset_repository_test.exs \
  apps/singularity_storage/test/singularity/storage/asset_search_projection_test.exs \
  apps/singularity_retrieval/test/singularity/retrieval/asset_metadata_search_test.exs \
  apps/singularity_web/test/singularity/web/assets_live_test.exs \
  apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs \
  apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs \
  apps/singularity_storage/test/singularity/storage/backup_restore_test.exs \
  apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs \
  apps/singularity_runtime/test/singularity/runtime/restore_vault_test.exs \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs \
  apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs; do
  test -f "$phase0_characterization_test"
  rg -n '^\s*test "' "$phase0_characterization_test"
done
```

Expected: every named test file exists and prints its public behavior cases.
Group the literal output in the Phase 0 execution report under Notes, Assets,
backup/restore, release, Runtime facade, and application boundary. This is the
pre-change characterization record; do not edit these behavior tests in
Phase 0.

There is no commit for Task 1.

### Task 2: Add failing Phase 0 architecture contracts

**Files:**

- Modify:
  `apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`
- Modify:
  `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Add the governance and active-document markers**

Add these module attributes after `@required_root_paths` in
`notes_scope_contract_test.exs`:

```elixir
@repo_root Path.expand("../../../../..", __DIR__)
@vault_adr "docs/adr/0003-vault-frozen-for-knowledge-base-development.md"
@vault_adr_name "0003-vault-frozen-for-knowledge-base-development.md"

@scope_lock "Vault is frozen compatibility substrate for `0.2.0`, not an active product module or release deliverable."
@qdrant_lock "Qdrant is out of scope for `0.2.0`."
@owner_scope_invariant "Every user-owned object belongs to an authenticated owner scope, and every projection points to an immutable source version."
```

Change the existing first test's local `root` assignment to:

```elixir
root = @repo_root
```

Add these tests before the existing documentation-exclusion test:

```elixir
test "Phase 0 governance documents record the approved scope lock" do
  agents = read_required!("AGENTS.md")
  adr = read_required!(@vault_adr)

  for source <- Enum.map([agents, adr], &normalize_markdown/1) do
    assert source =~ @scope_lock
    assert source =~ @owner_scope_invariant
    assert source =~ "requires a separately approved migration project"
  end

  assert normalize_markdown(agents) =~ @qdrant_lock
  assert adr =~ "Status: Accepted"
end

test "active README and guide state the v0.2 scope lock" do
  readme = read_required!("README.md")
  guide = read_required!("docs/guide.md")

  for source <- Enum.map([readme, guide], &normalize_markdown/1) do
    assert source =~ @scope_lock
    assert source =~ @qdrant_lock
    assert source =~ @owner_scope_invariant
    assert source =~ @vault_adr_name
  end

  refute readme =~ "Qdrant is required"

  roadmap =
    markdown_section!(
      guide,
      "# 21. Active implementation roadmap",
      "# 22. Cross-cutting invariants"
    )

  assert normalize_markdown(roadmap) =~ @scope_lock
  assert roadmap =~ "Conflicting roadmap guidance is superseded by ADR 0003."

  invariants =
    markdown_section!(
      guide,
      "# 22. Cross-cutting invariants",
      "# 23. Architecture decision records"
    )

  assert normalize_markdown(invariants) =~ @owner_scope_invariant
  refute invariants =~ "Every user-owned object belongs to a vault."
end
```

Add these helpers before `tracked_files/1`:

```elixir
defp read_required!(path) do
  absolute = Path.join(@repo_root, path)

  assert File.regular?(absolute),
         "required Phase 0 document is missing: #{path}"

  File.read!(absolute)
end

defp markdown_section!(source, heading, next_heading) do
  with [_, tail] <- String.split(source, heading, parts: 2),
       [section, _] <- String.split(tail, next_heading, parts: 2) do
    heading <> section
  else
    _ -> flunk("required Markdown section is missing: #{heading}")
  end
end

defp normalize_markdown(source) do
  source
  |> String.replace(~r/\s+/, " ")
  |> String.trim()
end
```

Do not change `active_path?/1`. Documentation and tests must remain excluded
from the production Qdrant inventory because legitimate compatibility and
historical text names Qdrant and Vault.

- [ ] **Step 2: Add the verification reconciliation contract**

Add this test to
`release_container_contract_test.exs` immediately after
`"test workflow preserves every exact acceptance gate"`:

```elixir
test "documented complete verification sequence exactly covers CI and Tests" do
  readme_block = complete_verification_block!("README.md")

  plan_block =
    complete_verification_block!(
      "docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md"
    )

  assert readme_block =~ "trap 'devenv processes down' EXIT"
  assert plan_block =~ "trap 'devenv processes down' EXIT"

  readme_commands = verification_commands(readme_block)
  plan_commands = verification_commands(plan_block)

  assert readme_commands == plan_commands

  excluded_workflow_commands =
    MapSet.new([
      "nix profile add nixpkgs#devenv",
      "devenv processes down"
    ])

  for {workflow_name, job_name} <- [{"ci.yml", "checks"}, {"test.yml", "test"}] do
    required =
      workflow_verification_commands(workflow_name, job_name)
      |> Enum.reject(&MapSet.member?(excluded_workflow_commands, &1))

    assert ordered_subsequence?(plan_commands, required),
           "#{workflow_name} verification commands are not an ordered subsequence"
  end

  assert Enum.take(plan_commands, -3) == [
           "nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/release.yml",
           "git diff --check",
           "git status --short"
         ]
end
```

Add these helpers immediately before the existing `workflow!/1` helper:

```elixir
defp complete_verification_block!(path) do
  blocks =
    Regex.scan(
      ~r/```bash\n(.*?)\n```/s,
      read!(path),
      capture: :all_but_first
    )
    |> List.flatten()
    |> Enum.filter(
      &String.starts_with?(
        &1,
        "(\nset -euo pipefail\ntrap 'devenv processes down' EXIT"
      )
    )

  case blocks do
    [block] -> block
    [] -> flunk("complete verification block is missing from #{path}")
    matches -> flunk("#{length(matches)} complete verification blocks found in #{path}")
  end
end

defp verification_commands(block) do
  block
  |> String.replace(~r/\\\n\s*/, " ")
  |> String.split("\n")
  |> Enum.map(&String.trim/1)
  |> Enum.reject(fn line ->
    line == "" or line in ["(", ")", "set -euo pipefail"] or
      String.starts_with?(line, "#") or String.starts_with?(line, "trap ")
  end)
  |> Enum.map(&normalize_command/1)
end

defp workflow_verification_commands(workflow_name, job_name) do
  workflow_name
  |> workflow!()
  |> job!(job_name)
  |> Map.fetch!("steps")
  |> Enum.flat_map(fn step ->
    case Map.fetch(step, "run") do
      {:ok, command} -> [normalize_command(command)]
      :error -> []
    end
  end)
end

defp ordered_subsequence?(_available, []), do: true
defp ordered_subsequence?([], _required), do: false

defp ordered_subsequence?(
       [command | available],
       [command | required]
     ),
     do: ordered_subsequence?(available, required)

defp ordered_subsequence?([_command | available], required),
  do: ordered_subsequence?(available, required)

defp normalize_command(command) do
  command
  |> String.replace(~r/\\\s*\n\s*/, " ")
  |> String.replace(~r/\s+/, " ")
  |> String.trim()
end
```

- [ ] **Step 3: Format the changed tests**

Run:

```bash
devenv shell -- mix format \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected: the formatter exits `0` and changes no file outside the two named
tests.

- [ ] **Step 4: Run the contracts and prove RED**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs

devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected RED:

- the Notes scope contract reports missing `AGENTS.md` and ADR 0003, the old
  README Qdrant direction, and the stale guide invariant/roadmap;
- the release/container contract reports that README lacks exactly the
  canonical `actionlint`, `git diff --check`, and `git status --short` tail;
- every pre-existing test remains green.

Do not commit RED tests. Continue directly to Tasks 3 and 4.

### Task 3: Add the Vault freeze governance documents

**Files:**

- Create: `AGENTS.md`
- Create: `docs/adr/0003-vault-frozen-for-knowledge-base-development.md`
- Test:
  `apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`

- [ ] **Step 1: Create the root repository instructions**

Create `AGENTS.md` with exactly this content:

```markdown
# Singularity Repository Instructions

## Active release

The only active product release is Singularity `0.2.0`, the first complete
single-user personal knowledge base. Its governing documents are:

- `docs/superpowers/specs/2026-08-31-singularity-v0.2-release-design.md`
- `docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`

Work proceeds one accepted phase at a time in a separate project-local
worktree and branch. Phase 1 must not begin until Phase 0 is accepted and
Phase 1 has its own approved design and detailed implementation plan.

## Vault freeze

Vault is frozen compatibility substrate for `0.2.0`, not an active product
module or release deliverable.

- Do not add, redesign, clean up, remove, migrate, or make Vault optional.
- Do not change Vault unlock, locking, keys, passwords, recovery,
  capabilities, administration, policies, commands, telemetry, tests, or UX.
- Do not investigate or repair unrelated Vault issues.
- Existing `vault_id` columns and adapter plumbing may remain only as opaque
  legacy owner-scope encoding required by current persistence.
- New knowledge APIs derive owner scope from authenticated runtime context and
  never accept a caller-selected Vault scope.
- A Vault-related file may change only for the smallest compile-preserving
  compatibility patch required by approved knowledge work, and that patch
  must be reported explicitly.
- Removing or replacing legacy Vault infrastructure requires a separately
  approved migration project.

The active invariant is:

> Every user-owned object belongs to an authenticated owner scope, and every
> projection points to an immutable source version.

## Active exclusions

Qdrant is out of scope for `0.2.0`.

Embeddings, vector or hybrid retrieval, reranking, RAG, LLM or Agent
execution, OCR, Office formats, autosave, WYSIWYG editing, CRDTs,
collaboration, synchronization, sharing, media domains, finance, health,
external connectors, ESS/S3 redesign, Activity expansion, and Settings
expansion are also out of scope.

## Architectural boundaries

- PostgreSQL is canonical for structured knowledge records.
- Original binary bytes remain in the established Asset storage path.
- Search rows are rebuildable projections, never canonical records.
- Every search result and citation resolves to an immutable source version.
- `singularity_web` calls only `Singularity.Runtime.Api`.
- Domain code does not acquire Ecto, Phoenix, filesystem, shell, PostgreSQL,
  or React concerns.
- External extraction stays outside long PostgreSQL transactions.
- Imports, jobs, and projection rebuilds are idempotent.
- User content stays out of logs, telemetry metadata, exceptions, outbox
  payloads, job arguments, and audit metadata.

## Phase and verification protocol

- Characterize established behavior before changing it.
- Add a failing focused contract before changing enforced behavior.
- Never edit a released migration.
- Never weaken, skip, delete, or reclassify a required assertion.
- Run focused checks during a phase and the complete README verification gate
  before accepting the phase.
- Preserve the seven-application dependency graph and require zero xref
  cycles.
- Record commits, changed files, migrations, tests, exact commands and
  results, remaining risks, and confirmation that no Vault feature work
  occurred.

Phase 0 permits documentation, test-contract, and workflow-contract
corrections only. It does not authorize production-code or
production-behavior changes, version bumps, tags, releases, pushes,
deployments, or Phase 1 work.

## Stop conditions

Stop the affected work and report evidence when:

- live remote identity or required workflow state cannot be verified;
- a complete required gate fails;
- work would change Vault semantics or require an unapproved migration;
- an additive implementation cannot preserve immutable source provenance;
- backup compatibility would break;
- release automation cannot prove the exact tested source; or
- a dependency issue in a configured internal organization blocks the task.

Follow the repository upstream-issue routing policy. Do not hide a dependency
defect behind an unapproved local workaround. Independent work may continue
only when it remains valid and does not evade the blocker.
```

- [ ] **Step 2: Add ADR 0003**

Create
`docs/adr/0003-vault-frozen-for-knowledge-base-development.md` with exactly this
content:

```markdown
# ADR 0003: Vault frozen for knowledge-base development

Status: Accepted
Date: 2026-08-31

## Context

Singularity is currently being developed as a single-user, local-first
personal knowledge base. The established storage and runtime foundation still
contains Vault tables, `vault_id` columns, cryptographic behavior, and adapter
plumbing from the earlier product model. Active roadmap guidance continued to
describe Vault as a feature and ownership boundary, which could direct new
knowledge-base work into Vault redesign or expansion.

The `0.2.0` release must build Documents, source-pinned knowledge links,
PostgreSQL lexical search, portable export, and complete backup/restore while
preserving the released foundation. Removing legacy Vault infrastructure
would be a separate migration with different compatibility and security risk.

## Decision

Vault is frozen compatibility substrate for `0.2.0`, not an active product
module or release deliverable.

1. Existing Vault implementation remains unchanged for compatibility.
2. New knowledge-domain APIs derive owner scope from authenticated runtime
   context and never expose a caller-selected `vault_id`.
3. Existing `vault_id` fields and adapter plumbing may remain only as opaque
   legacy owner-scope encoding where current persistence requires them.
4. New knowledge rules do not depend on Vault behavior.
5. Removing or replacing legacy Vault infrastructure requires a separately
   approved migration project.
6. Historical specifications remain historical records; this ADR governs
   active development and supersedes conflicting active roadmap guidance.

The active invariant is:

> Every user-owned object belongs to an authenticated owner scope, and every
> projection points to an immutable source version.

## Consequences

`0.2.0` work does not add Vault features, migrations, policies, commands,
telemetry, tests, or acceptance criteria. A Vault-related file may be touched
only for the smallest compile-preserving compatibility patch required by
approved knowledge work, and the implementation report must identify it.

Current persistence may continue to encode authenticated owner scope with
legacy columns until a separately approved migration is designed. That
encoding is not a caller-selectable knowledge-domain concept.

Active README and guide text points to this ADR. Historical implementation
records are not rewritten to erase earlier decisions.
```

- [ ] **Step 3: Verify the governance half of the scope contract**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs
```

Expected: the governance-document test passes. The same file remains RED only
because README and guide still contain stale active guidance. Do not commit
until the entire scope contract is green.

### Task 4: Correct active README and guide guidance

**Files:**

- Modify: `README.md`
- Modify: `docs/guide.md`
- Test:
  `apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`
- Test:
  `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Update the README identity and active scope**

Replace the opening sentence with:

```markdown
Singularity is a local-first personal data and knowledge operating system; its active `0.2.0` release is a single-user personal knowledge base.
```

Replace the old Qdrant paragraph and two-ADR sentence after the application
list with:

```markdown
## Active `0.2.0` scope

Current work is Phase 0 only: scope lock, governance, characterization, and a
green baseline. Phase 1 must not begin until Phase 0 is accepted and receives
its own approved design and detailed implementation plan.

Vault is frozen compatibility substrate for `0.2.0`, not an active product
module or release deliverable. Existing `vault_id` persistence and adapter
plumbing may remain as opaque legacy owner-scope encoding. New knowledge APIs
derive owner scope from authenticated runtime context and never accept a
caller-selected Vault scope. Removing or replacing legacy Vault
infrastructure requires a separately approved migration project.

> Every user-owned object belongs to an authenticated owner scope, and every
> projection points to an immutable source version.

Qdrant is out of scope for `0.2.0`.

Embeddings, semantic or vector search, RAG, Agents, OCR, and unrelated domains
or connectors are also out of scope.

The storage decisions are recorded in
[ADR 0001](docs/adr/0001-postgresql-is-canonical.md) and
[ADR 0002](docs/adr/0002-local-storage-until-embedded-ess.md). The active
Vault compatibility decision is
[ADR 0003](docs/adr/0003-vault-frozen-for-knowledge-base-development.md).
The
[approved release design](docs/superpowers/specs/2026-08-31-singularity-v0.2-release-design.md)
and
[canonical release directive](docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md)
govern `0.2.0`.
```

Replace the final guide sentence with:

```markdown
See the [Architecture and Implementation Guide](docs/guide.md) as an
architecture reference. Its active `0.2.0` status notice, roadmap, and
invariants govern current work together with the approved release design.
```

- [ ] **Step 2: Make the README verification block canonical**

Replace the entire existing fenced Bash block under `## Development` with the
exact canonical block from the master release directive:

```bash
(
set -euo pipefail
trap 'devenv processes down' EXIT

devenv up -d
devenv processes wait --timeout 120

devenv shell -- bash \
  apps/singularity_storage/priv/repo/bootstrap_roles.sh

devenv shell -- mix deps.get
devenv shell -- mix deps.unlock --check-unused
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test
devenv shell -- mix singularity.test.integration
devenv shell -- mix singularity.test.restore

devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
devenv shell -- mix npm.verify
devenv shell -- mix duskmoon_bundler.js.check
devenv shell -- mix npm.run test:js
devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind
devenv shell -- mix npm.run test:e2e

devenv shell -- mix xref graph --format cycles --fail-above 0
nix run nixpkgs#actionlint -- \
  .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/release.yml

git diff --check
git status --short
)
```

The upstream issue and temporary-workaround markers remain at the actual
workflow callsites in `ci.yml` and `test.yml`. Do not duplicate them into the
canonical command block.

- [ ] **Step 3: Add the guide-wide active-scope notice**

Replace the guide metadata at the top with:

```markdown
**Status:** Draft v0.1 architecture reference; conflicting active guidance is superseded for `0.2.0`<br>
**Product type:** Personal Data and Knowledge Operating System<br>
**Initial deployment:** Single owner, multiple devices, local-first<br>
**Active release:** `0.2.0`, the first complete single-user personal knowledge base<br>
**Governing documents:** [approved release design](superpowers/specs/2026-08-31-singularity-v0.2-release-design.md), [canonical release directive](superpowers/plans/2026-08-31-singularity-v0.2-release.md), and [ADR 0003](adr/0003-vault-frozen-for-knowledge-base-development.md)

> **Active `0.2.0` scope**
>
> Vault is frozen compatibility substrate for `0.2.0`, not an active product
> module or release deliverable.
>
> Qdrant is out of scope for `0.2.0`.
>
> Every user-owned object belongs to an authenticated owner scope, and every
> projection points to an immutable source version.
>
> ADR 0003 supersedes conflicting active Vault guidance in this document.
> Vault passages in sections 1–20 remain architecture and compatibility
> context; they do not authorize Vault features, redesign, cleanup, removal,
> migration, UX, policies, commands, telemetry, tests, or acceptance work.
> Existing `vault_id` fields may remain as opaque legacy owner-scope encoding.
> New knowledge APIs derive owner scope from authenticated runtime context and
> never accept caller-selected Vault scope.
```

Immediately after `## 4.4 Vault`, insert:

```markdown
> **Legacy compatibility model:** This section records the superseded v0.1
> model. For active development, follow ADR 0003 and the authenticated
> owner-scope invariant. Do not implement or migrate the model described below
> during `0.2.0`.
```

Do not edit the existing `4.4` body or mechanically replace Vault terms in
sections 1–20.

- [ ] **Step 4: Replace the stale active roadmap**

Replace everything from `# 21. Implementation roadmap` through the separator
immediately before `# 22. Cross-cutting invariants` with:

```markdown
# 21. Active implementation roadmap

The
[canonical `0.2.0` release directive](superpowers/plans/2026-08-31-singularity-v0.2-release.md)
is the sole detailed roadmap. Work proceeds one accepted phase at a time in
separate branches and worktrees.

Conflicting roadmap guidance is superseded by ADR 0003.

Vault is frozen compatibility substrate for `0.2.0`, not an active product
module or release deliverable.

Qdrant is out of scope for `0.2.0`.

The only currently authorized work is **Phase 0 — Scope lock and green
baseline**. Phase 0 is limited to documentation, governance,
characterization, verification-contract reconciliation, and baseline
evidence. It does not change production code or behavior, Vault
functionality, application versions, tags, releases, pushes, or deployments.

Phases 1–7 remain unstarted. No later phase begins until its predecessor is
accepted and the new phase has its own approved design and detailed
implementation plan.

Embeddings, semantic retrieval, RAG, Agents, OCR, photos, media,
subscriptions, finance, health, synchronization, and external connectors are
not `0.2.0` work.

---
```

The removed Milestone 0–8 text is the guide's stale forward-looking draft
roadmap, not an implementation-history document. Git history preserves it.
Do not edit older documents under `docs/superpowers/specs` or
`docs/superpowers/plans`.

- [ ] **Step 5: Correct the active invariant, ADR index, and current gate**

Replace invariant 1 in section 22 with:

```markdown
1. **Every user-owned object belongs to an authenticated owner scope, and every projection points to an immutable source version.**
```

After the invariant list, add:

```markdown
Current persistence may encode authenticated owner scope through legacy
`vault_id` columns and adapter plumbing until a separately approved migration
is performed. That compatibility encoding is not a caller-selectable
knowledge-domain concept.
```

Replace section 23 with:

```markdown
# 23. Architecture decision records

Active records:

* [ADR 0001 — PostgreSQL is canonical](adr/0001-postgresql-is-canonical.md)
* [ADR 0002 — Local storage until embedded ESS](adr/0002-local-storage-until-embedded-ess.md)
* [ADR 0003 — Vault frozen for knowledge-base development](adr/0003-vault-frozen-for-knowledge-base-development.md)

The unimplemented v0.1 draft ADR backlog is not an active task list.
Additional ADR work requires phase-specific approval.

---
```

Replace section 24 through the end of the guide with:

```markdown
# 24. Current implementation gate

Phase 0 is the current target. Follow the approved release design and
canonical directive; do not infer product implementation authority from the
historical architecture material in this guide.

Phase 0 must finish with corrected active guidance, recorded baseline
evidence, a clean worktree, the complete supported verification gate passing,
and independent review. It must not begin Phase 1, change production code or
behavior, modify Vault functionality, bump versions, tag, publish, push, or
deploy.
```

- [ ] **Step 6: Format and run the focused GREEN gates**

Run:

```bash
devenv shell -- mix format \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs

devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs

devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs

devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs \
  apps/singularity_web/test/singularity/architecture/dependency_graph_test.exs \
  apps/singularity_web/test/singularity/architecture/observability_contract_test.exs
```

Expected:

- Notes scope contract: all tests pass;
- release/container contract: all tests pass;
- combined four-file architecture gate: `39 tests, 0 failures`;
- no workflow or production file changed.

- [ ] **Step 7: Inspect the complete scope diff**

Run:

```bash
git add -- \
  AGENTS.md \
  README.md \
  docs/guide.md \
  docs/adr/0003-vault-frozen-for-knowledge-base-development.md \
  apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs

git diff --cached --check
git status --short
git diff --cached --stat

phase0_expected_paths="$(
  printf '%s\n' \
    AGENTS.md \
    README.md \
    apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs \
    apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs \
    docs/adr/0003-vault-frozen-for-knowledge-base-development.md \
    docs/guide.md |
    sort
)"
phase0_actual_paths="$(git diff --cached --name-only | sort)"
test "$phase0_actual_paths" = "$phase0_expected_paths"
```

Expected: exactly the six allowed implementation files appear; no production
path, migration, workflow, version file, or historical document appears.

- [ ] **Step 8: Commit the green scope slice**

Run:

```bash
git diff --cached --check
git diff --cached --stat
git commit -m "docs(scope): freeze vault work for knowledge v0.2"
```

Expected: one commit containing the two green architecture contracts and four
governance/active-document changes. Do not push.

### Task 5: Run the complete Phase 0 verification gate

**Files:**

- Verify: all repository checks
- Verify: `.github/workflows/ci.yml`
- Verify: `.github/workflows/test.yml`
- Verify: `.github/workflows/release.yml`

- [ ] **Step 1: Require a clean committed source**

Run:

```bash
git status --short --branch
git diff --check
test -z "$(git status --porcelain)"
```

Expected: the Phase 0 branch is clean at the green scope commit.

- [ ] **Step 2: Run the canonical complete gate verbatim**

Run from one shell so cleanup remains active:

```bash
(
set -euo pipefail
trap 'devenv processes down' EXIT

devenv up -d
devenv processes wait --timeout 120

devenv shell -- bash \
  apps/singularity_storage/priv/repo/bootstrap_roles.sh

devenv shell -- mix deps.get
devenv shell -- mix deps.unlock --check-unused
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test
devenv shell -- mix singularity.test.integration
devenv shell -- mix singularity.test.restore

devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
devenv shell -- mix npm.verify
devenv shell -- mix duskmoon_bundler.js.check
devenv shell -- mix npm.run test:js
devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind
devenv shell -- mix npm.run test:e2e

devenv shell -- mix xref graph --format cycles --fail-above 0
nix run nixpkgs#actionlint -- \
  .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/release.yml

git diff --check
git status --short
)

test -z "$(git status --porcelain)"
```

Expected: every command exits `0`; ExUnit, PostgreSQL integration, restore,
Vitest, and Playwright report zero failures; the production asset build
succeeds; xref reports no cycles; actionlint reports no findings; final Git
checks are clean.

- [ ] **Step 3: Apply the failure policy**

If any required command fails:

1. capture the exact command, exit status, and smallest useful failure output;
2. reproduce it with the narrowest focused command;
3. classify it as documentation/test-contract, environment, remote,
   production behavior, Vault, migration, dependency, or unrelated;
4. stop before changing production code, Vault behavior, schemas, workflows,
   versions, or assertions;
5. route an internal dependency defect upstream using the repository policy;
6. request a design amendment and user approval for any production repair.

Do not mark Phase 0 complete, weaken the gate, delete a case, call a
reproducible failure flaky, or begin Phase 1.

There is no commit for Task 5.

### Task 6: Review the Phase 0 scope and preserve historical material

**Files:**

- Review: `AGENTS.md`
- Review: `README.md`
- Review: `docs/guide.md`
- Review: `docs/adr/0003-vault-frozen-for-knowledge-base-development.md`
- Review:
  `apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`
- Review:
  `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Request independent specification review**

Use the `requesting-code-review` skill or a fresh review agent. Ask it to
compare the Phase 0 diff with both governing documents and report:

- missing Phase 0 deliverables or acceptance criteria;
- any production behavior, Vault, Phase 1, release, version, or deployment
  scope leak;
- any active guide statement that still authorizes Vault, Qdrant, or a later
  domain;
- any historical specification or implementation plan changed beyond the
  already approved design, master directive, and this detailed plan;
- any required verification command absent or reordered.

Expected: no Critical or Important findings.

- [ ] **Step 2: Request independent quality review**

Ask a separate reviewer to inspect:

- whether the tests enforce active sections rather than globally banning
  compatibility terms;
- whether the Markdown section extraction fails clearly;
- whether verification normalization preserves command order and cannot hide
  a missing command;
- whether README and the canonical plan remain byte-logically equivalent for
  the complete gate;
- whether all links and relative paths resolve;
- whether edits are the smallest active-guidance changes that satisfy the
  approved design.

Expected: no Critical or Important findings.

- [ ] **Step 3: Resolve review findings without scope expansion**

For each Critical or Important finding:

1. add or tighten the focused failing contract;
2. prove RED;
3. make the smallest documentation or contract correction;
4. rerun both focused files and the four-file architecture gate;
5. commit with a conventional `docs(scope)` or `test(architecture)` message;
6. rerun the complete Task 5 gate on the new HEAD.

Any proposed production change, Vault change, workflow-release change, version
bump, or later-phase work stops for explicit approval.

### Task 7: Prove final Phase 0 acceptance and hand off

**Files:**

- Verify: final Git history and path allowlist
- Verify: all eight Mix version declarations
- Report: execution handoff only; do not create an unapproved report
  subsystem

- [ ] **Step 1: Verify the final path and version allowlists**

Run:

```bash
set -euo pipefail

for phase0_mix_file in mix.exs apps/*/mix.exs; do
  rg -q 'version: "0\.1\.0"' "$phase0_mix_file"
done

git diff --name-only 5151febde7d94c92877f7a49525e0e2add5b2faf..HEAD |
  while IFS= read -r phase0_path; do
    case "$phase0_path" in
      AGENTS.md | \
      README.md | \
      docs/guide.md | \
      docs/adr/0003-vault-frozen-for-knowledge-base-development.md | \
      docs/superpowers/specs/2026-08-31-singularity-v0.2-release-design.md | \
      docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md | \
      docs/superpowers/plans/2026-08-31-singularity-v0.2-phase-0-scope-baseline.md | \
      apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs | \
      apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs)
        ;;
      *)
        echo "unexpected Phase 0 history path: $phase0_path" >&2
        exit 1
        ;;
    esac
  done

test -z "$(git status --porcelain)"
git diff --check 5151febde7d94c92877f7a49525e0e2add5b2faf..HEAD
git log --oneline 5151febde7d94c92877f7a49525e0e2add5b2faf..HEAD
```

Expected:

- only the approved design, master directive, detailed plan, two governance
  documents, two active docs, and two architecture tests changed;
- all eight Mix projects remain `0.1.0`;
- the worktree is clean; and
- no migration, production file, workflow, version, or historical document is
  in the diff.

- [ ] **Step 2: Re-run live remote verification**

Re-run Task 1 Step 3 unchanged. Record the literal release asset names and
the exact CI and Tests run IDs, URLs, head SHAs, statuses, and conclusions.

Expected: remote `main` remains the approved baseline and both exact-SHA runs
remain successful. If the remote moved, inspect the delta and update the
baseline design/plan through review before accepting Phase 0.

- [ ] **Step 3: Produce the required Phase 0 execution report**

The final handoff must record:

- every Phase 0 commit hash and subject;
- every changed file;
- migrations added: `none`;
- the three tests added and their final counts;
- every focused and complete command run, exit result, test count, and
  duration available from output;
- remote main SHA, `v0.1.0` tag object and peeled source, GitHub Release
  asset names, and exact CI/Tests run IDs and URLs;
- independent review findings and their resolution;
- remaining risks, including any branch-protection state deferred to Phase 7;
- confirmation that no production code or behavior changed;
- confirmation that no Vault feature work occurred;
- confirmation that no application version changed;
- confirmation that nothing was pushed, tagged, released, or deployed;
- confirmation that Phase 1 did not start.

Do not create a repository report directory in Phase 0. The governing design
requires an execution report, not a new reporting subsystem; the task handoff
is the evidence record.

- [ ] **Step 4: Stop at the Phase 0 boundary**

Do not merge, push, open a pull request, tag, publish, deploy, bump `0.2.0`, or
start Phase 1 unless the user explicitly requests the next action.

Phase 0 is ready for the user's integration decision only when all local
checks, live remote evidence, independent reviews, path/version allowlists,
and the final clean-tree check pass on the final Phase 0 HEAD.
