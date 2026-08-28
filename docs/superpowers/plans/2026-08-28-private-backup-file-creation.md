# Private Backup File Creation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make local backup partials atomically private on supported launch surfaces and fail closed before writing if their actual descriptor mode is not `0600`.

**Architecture:** Set process umask `077` before BEAM starts in devenv and OTP release wrappers, because OTP 28 creates files with `0666 & umask` and ignores the current `{:mode, 0o600}` tuple. Capture descriptor identity and permission mode in one `fstat`, accept only `0600`, and use the captured identity to remove an unsafe still-empty partial.

**Tech Stack:** Elixir 1.18.4, Erlang/OTP 28, ExUnit, devenv/Nix, POSIX shell, GitHub Actions.

---

## File map

- Modify `devenv.nix`: establish `umask 077` for local, CI, test, and operational Mix processes.
- Modify `rel/env.sh.eex`: establish `umask 077` before release cookie generation and VM startup.
- Modify `apps/singularity_storage/lib/singularity/storage/backup/local_destination.ex`: remove the ignored open option and verify descriptor identity plus permission mode.
- Modify `apps/singularity_storage/test/singularity/storage/backup/local_destination_test.exs`: preserve the at-open test and add a real child-process permissive-umask fail-closed regression.
- Modify `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`: pin both launch surfaces and reject the obsolete OTP mode tuple.

### Task 1: Add failing private-creation contracts

**Files:**

- Modify: `apps/singularity_storage/test/singularity/storage/backup/local_destination_test.exs`
- Modify: `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Create the isolated implementation worktree**

Use the `using-git-worktrees` skill from the clean main repository:

```bash
git worktree add .trees/private-backup-file-mode -b codex/private-backup-file-mode main
cd .trees/private-backup-file-mode
devenv shell -- mix deps.get
```

Expected: the worktree starts at the approved design/plan commit with no tracked changes.

- [ ] **Step 2: Re-run the existing CI failure as RED**

```bash
devenv shell -- mix test \
  apps/singularity_storage/test/singularity/storage/backup/local_destination_test.exs:332
```

Expected: one selected test fails because actual permissions are `0644` instead of `0600`.

- [ ] **Step 3: Add the permissive-umask child-process regression**

Add the repository-root attribute beside the existing module attributes:

```elixir
@repo_root Path.expand("../../../../../..", __DIR__)
```

Add this test immediately after the existing `0600 at open time` test:

```elixir
@tag :insecure_umask_probe
test "rejects and removes an empty partial under a permissive process umask", %{
  tmp_dir: tmp_dir
} do
  if System.get_env("SINGULARITY_INSECURE_UMASK_PROBE") == "1" do
    root = Path.join(tmp_dir, "backups")
    context = backup_context(root)
    reference = "backup.bundle"

    assert {:ok, destination} = LocalDestination.writer_destination(context, reference)
    partial = destination.partial_path.(@manifest_id)

    assert {:error, %Error{code: :invalid}} =
             destination.file_system.open.(partial, [:write, :binary, :exclusive])

    refute File.exists?(partial)
  else
    {output, status} =
      System.cmd(
        "sh",
        [
          "-c",
          "umask 022; export SINGULARITY_INSECURE_UMASK_PROBE=1; exec mix test --no-compile apps/singularity_storage/test/singularity/storage/backup/local_destination_test.exs --only insecure_umask_probe"
        ],
        cd: @repo_root,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
```

The outer test uses the supported devenv environment. The inner test explicitly starts a new BEAM process with umask `0022`, proves the destination returns an error before the first write, and proves identity-bound cleanup removes the empty partial.

- [ ] **Step 4: Add launch-surface and source contracts**

Add this test to `release_container_contract_test.exs`:

```elixir
test "supported launch surfaces enforce private file creation" do
  devenv = read!("devenv.nix")
  release_env = read!("rel/env.sh.eex")
  destination =
    read!("apps/singularity_storage/lib/singularity/storage/backup/local_destination.ex")

  assert devenv =~ ~S<enterShell = ''
    umask 077>

  assert release_env =~ "#!/bin/sh\n\numask 077\n"
  refute destination =~ "{:mode, 0o600}"
  assert destination =~ "{:ok, ownership, 0o600}"
  assert destination =~ "Bitwise.band(mode, 0o777)"
end
```

- [ ] **Step 5: Run the new contracts and verify RED**

```bash
devenv shell -- mix test \
  apps/singularity_storage/test/singularity/storage/backup/local_destination_test.exs \
  --only insecure_umask_probe
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected: the child-process test fails because insecure mode is accepted, and the release/container contract fails because neither launch surface sets umask and the obsolete tuple remains.

### Task 2: Enforce private creation and descriptor verification

**Files:**

- Modify: `devenv.nix`
- Modify: `rel/env.sh.eex`
- Modify: `apps/singularity_storage/lib/singularity/storage/backup/local_destination.ex`
- Test: `apps/singularity_storage/test/singularity/storage/backup/local_destination_test.exs`
- Test: `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Set the devenv process umask**

Change `enterShell` to:

```nix
enterShell = ''
  umask 077
  export SINGULARITY_ROLE_PROVISIONER_DATABASE_URL="postgresql:///postgres?host=$PGHOST&port=$PGPORT"
'';
```

- [ ] **Step 2: Set the OTP release process umask**

Change the beginning of `rel/env.sh.eex` to:

```sh
#!/bin/sh

umask 077

if [ -z "${RELEASE_COOKIE:-}" ]; then
```

Keep the existing cookie generation and export unchanged after that point.

- [ ] **Step 3: Remove the ignored file option**

Change the raw exclusive open list to:

```elixir
:file.open(String.to_charlist(path), [
  :write,
  :binary,
  :raw,
  :exclusive
])
```

- [ ] **Step 4: Return identity and permission mode from descriptor metadata**

Replace `descriptor_identity_from_stat/1` with:

```elixir
defp descriptor_identity_from_stat(
       {:file_info, _, :regular, _, _, _, _, mode, _, major, _, inode, _, _}
     ) do
  {:ok, {:local_file, major, inode}, Bitwise.band(mode, 0o777)}
end

defp descriptor_identity_from_stat(_descriptor_stat), do: invalid()
```

- [ ] **Step 5: Fail closed on an unsafe descriptor before path verification**

Change the beginning of `verify_opened_partial/4` to distinguish a safe descriptor from an unsafe one while retaining the existing path identity branch:

```elixir
defp verify_opened_partial(root, path, device, options) do
  case descriptor_identity(device) do
    {:ok, ownership, 0o600} ->
      case regular_identity(path) do
        {:ok, ^ownership} ->
          {:ok, device, ownership}

        {:ok, _replacement} ->
          open_verification_failure(
            root,
            path,
            device,
            ownership,
            Error.new(:invalid),
            options
          )

        {:error, %Error{} = error} ->
          open_verification_failure(root, path, device, ownership, error, options)
      end

    {:ok, ownership, _unsafe_mode} ->
      open_verification_failure(
        root,
        path,
        device,
        ownership,
        Error.new(:invalid),
        options
      )

    {:error, %Error{} = error} ->
      open_verification_failure(root, path, device, nil, error, options)
  end
end
```

This captures ownership and mode in one descriptor read. Unsafe-mode cleanup uses the captured identity, so a concurrently substituted pathname is never deleted.

- [ ] **Step 6: Verify GREEN behavior**

Run:

```bash
devenv shell -- mix test \
  apps/singularity_storage/test/singularity/storage/backup/local_destination_test.exs
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected: all local-destination tests pass, including the nested umask-`0022` rejection, and all release/container contracts pass.

- [ ] **Step 7: Prove each guard detects regression**

Perform and restore these mutations one at a time:

1. Remove `umask 077` from `devenv.nix`; the existing at-open test must fail with `0644`.
2. Remove `umask 077` from `rel/env.sh.eex`; the release/container contract must fail.
3. Change the safe descriptor match from `0o600` to `_mode`; the nested permissive-umask test must fail because open succeeds.

After restoring all three, rerun both commands from Step 6 and require zero failures.

- [ ] **Step 8: Run the scoped finish gate**

```bash
devenv shell -- mix deps.unlock --check-unused
devenv shell -- mix format --check-formatted \
  apps/singularity_storage/lib/singularity/storage/backup/local_destination.ex \
  apps/singularity_storage/test/singularity/storage/backup/local_destination_test.exs \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test \
  apps/singularity_storage/test/singularity/storage/backup/local_destination_test.exs \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs \
  apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs
devenv shell -- sh -c 'test "$(umask)" = 0077'
sh -n rel/env.sh.eex
MIX_ENV=prod devenv shell -- mix release singularity --overwrite
test -x _build/prod/rel/singularity/bin/singularity
rg -n '^umask 077$' _build/prod/rel/singularity/releases/0.1.0/env.sh
nix run nixpkgs#actionlint -- \
  .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/release.yml
git diff --check
git status --short
```

Expected: every command exits zero and exactly the five scoped files are modified.

- [ ] **Step 9: Commit the security fix**

```bash
git add devenv.nix rel/env.sh.eex \
  apps/singularity_storage/lib/singularity/storage/backup/local_destination.ex \
  apps/singularity_storage/test/singularity/storage/backup/local_destination_test.exs \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
git diff --cached --check
git commit -m "fix(backup): enforce private partial creation"
git show --check --stat --oneline HEAD
git status --short --branch
```

Expected: one commit contains exactly the five scoped paths and the worktree is clean.

### Task 3: Review, merge, push, and clear the required Tests gate

**Files:**

- Review and integrate the Task 2 commit.
- No additional source changes unless a reviewer finds a Critical or Important defect.

- [ ] **Step 1: Complete two-stage review**

Use `requesting-code-review` after spec compliance passes. Reviewers must verify the five-file boundary, atomic process umask, unsafe-mode identity-bound cleanup, nested permissive-umask proof, release wrapper coverage, and absence of a post-open chmod window. Fix any Critical or Important finding test-first and repeat the corresponding review.

- [ ] **Step 2: Fast-forward local main and reverify**

From the clean main worktree:

```bash
git merge --ff-only codex/private-backup-file-mode
devenv shell -- mix deps.get
devenv shell -- mix deps.unlock --check-unused
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test \
  apps/singularity_storage/test/singularity/storage/backup/local_destination_test.exs \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs \
  apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs
nix run nixpkgs#actionlint -- \
  .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/release.yml
git diff --check
git status --short --branch
```

Expected: all scoped tests and checks pass on local main.

- [ ] **Step 3: Remove the merged worktree**

```bash
git worktree remove .trees/private-backup-file-mode
git worktree prune
git branch -d codex/private-backup-file-mode
```

- [ ] **Step 4: Push and prove the exact remote SHA**

```bash
push_sha="$(git rev-parse HEAD)"
git push origin main
remote_sha="$(git ls-remote --exit-code --heads origin refs/heads/main | cut -f1)"
test "$remote_sha" = "$push_sha"
```

Never force-push. Stop if remote main advanced unexpectedly.

- [ ] **Step 5: Require new CI and Tests runs for the pushed SHA**

Use GitHub CLI with `GODEBUG=http2client=0` in this proxy environment. Locate the `ci.yml` and `test.yml` push runs whose `headSha` equals `push_sha`, then monitor both to terminal success:

```bash
export GODEBUG=http2client=0
push_sha="$(git rev-parse HEAD)"
find_run() {
  workflow_file="$1"
  for attempt in $(seq 1 30); do
    run_id="$(gh run list --repo gsmlg-opt/Singularity --workflow "$workflow_file" --event push --commit "$push_sha" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
    if [[ -n "$run_id" ]]; then
      printf '%s\n' "$run_id"
      return 0
    fi
    sleep 5
  done
  return 1
}
ci_run_id="$(find_run ci.yml)"
test_run_id="$(find_run test.yml)"
test -n "$ci_run_id"
test -n "$test_run_id"
gh run watch "$ci_run_id" --repo gsmlg-opt/Singularity --exit-status --interval 10
gh run watch "$test_run_id" --repo gsmlg-opt/Singularity --exit-status --interval 10
```

Expected: both runs conclude `success`. If either fails, inspect its failed logs and do not dispatch the release.

- [ ] **Step 6: Resume the approved first-release plan**

After both workflow conclusions are proven successful, continue with Task 4 and Task 5 in:

```text
docs/superpowers/plans/2026-08-27-first-release-bootstrap.md
```

Those tasks contain the exact `release.yml` dispatch for `version=0.1.0`, terminal run monitoring, annotated tag proof, GitHub archive/checksum verification, GHCR `0.1.0`/`0.1`/`latest` digest comparison, `linux/amd64` and `linux/arm64` manifest checks, OCI archive equivalence, and image revision-label proof. Do not dispatch before the CI and Tests runs in Step 5 succeed.
