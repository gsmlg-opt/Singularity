# First Release Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the transactional GitHub workflow support the repository's first `0.1.0` release, then push `main`, pass CI, publish the release, and prove every GitHub and GHCR artifact.

**Architecture:** Extend only the new-tag preparation branch: a requested version equal to the canonical Mix version tags the verified source commit without an empty version-bump commit, while a greater version retains the existing update-and-commit path. Keep all existing monotonicity, resume, digest-equivalence, and atomic publication guards, then release only after the pushed SHA's CI and Test workflows pass.

**Tech Stack:** Elixir 1.18.4, ExUnit, YAML/GitHub Actions, GitHub CLI, Docker Buildx, GHCR, OCI archives.

---

## File map

- Modify `.github/workflows/release.yml`: permit an equal canonical version only on the absent-tag new-release path and skip the version-bump commit in that case.
- Modify `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`: pin the bootstrap guard and the complete parsed workflow structure.
- No other production, dependency, container, or workflow file changes are permitted.

### Task 1: Implement the equal-version bootstrap path test-first

**Files:**

- Modify: `.github/workflows/release.yml`
- Modify: `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Create an isolated implementation worktree**

Use the `using-git-worktrees` skill and create the named branch under the project-local worktree directory:

```bash
git worktree add .trees/first-release-bootstrap -b codex/first-release-bootstrap main
cd .trees/first-release-bootstrap
```

Expected: the new worktree is clean and starts at the approved design/plan commit on `main`.

- [ ] **Step 2: Add the failing bootstrap contract**

In the release workflow contract test, replace the canonical-version assertion with these exact assertions:

```elixir
assert preparation_run =~
         ~S<if [[ "$canonical_candidate" != "$RELEASE_VERSION" ]]; then>

assert preparation_run =~
         ~S<new release version must not be lower than the canonical Mix version>

assert preparation_run =~
         ~S<if [[ "$RELEASE_VERSION" != "$current_version" ]]; then>

refute preparation_run =~
         ~S<"$RELEASE_VERSION" == "$current_version">
```

Update the exact `prepare_release_source_run/0` fixture in the same test file so it describes the intended shell block shown in Step 4. Do not edit the real workflow yet.

- [ ] **Step 3: Run the focused test and verify RED**

Run:

```bash
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected: 12 tests run with exactly one failure because the real workflow still rejects equality and does not guard the version update with `RELEASE_VERSION != current_version`.

- [ ] **Step 4: Implement the minimal workflow change**

In the absent-tag branch of `Prepare release source`, replace the canonical comparison and version update with this structure. Retain the existing Python body unchanged inside the indicated guard:

```bash
current_version="$(read_root_version)"
canonical_candidate="$(printf '%s\n%s\n' "$current_version" "$RELEASE_VERSION" | sort -V | tail -n 1)"
if [[ "$canonical_candidate" != "$RELEASE_VERSION" ]]; then
  echo "new release version must not be lower than the canonical Mix version" >&2
  exit 1
fi
if [[ "$RELEASE_VERSION" != "$current_version" ]]; then
  python3 - "$RELEASE_VERSION" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path("mix.exs")
source = path.read_text()
updated, count = re.subn(
    r'(?m)^(\s*version:\s*")[^"]+(",)$',
    rf'\g<1>{sys.argv[1]}\g<2>',
    source,
    count=1,
)
if count != 1 or updated == source:
    raise SystemExit("canonical Mix version was not updated")
path.write_text(updated)
PY
  git diff --check -- mix.exs
  git diff --quiet -- mix.exs && {
    echo "canonical Mix version was not updated" >&2
    exit 1
  }
  git config user.name github-actions[bot]
  git config user.email 41898282+github-actions[bot]@users.noreply.github.com
  git add mix.exs
  git commit -m "chore(release): v${RELEASE_VERSION}"
fi
git tag -a "$RELEASE_TAG" -m "Singularity $RELEASE_TAG"
RELEASE_MODE=new
SOURCE_REVISION="$(git rev-parse HEAD)"
```

Apply the same exact block to `prepare_release_source_run/0` in the contract test. Equality now skips only the version edit and commit; tag creation, source revision capture, builds, digest checks, atomic push, and promotion remain common.

- [ ] **Step 5: Run the focused test and verify GREEN**

Run:

```bash
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected: 12 tests, 0 failures.

- [ ] **Step 6: Prove mutation resistance**

Temporarily restore equality rejection in `.github/workflows/release.yml` only:

```bash
if [[ "$canonical_candidate" != "$RELEASE_VERSION" || "$RELEASE_VERSION" == "$current_version" ]]; then
```

Run the focused test and expect exactly one failure. Restore the approved inequality-only guard and rerun for 12 tests, 0 failures.

- [ ] **Step 7: Run the scoped implementation gate**

Run:

```bash
devenv shell -- mix format --check-formatted apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs \
  apps/singularity_web/test/singularity/web/asset_toolchain_contract_test.exs
nix run nixpkgs#actionlint -- .github/workflows/release.yml
git diff --check
git status --short
```

Expected: 19 tests pass; compilation, formatting, workflow lint, and diff checks exit zero; only the two scoped files are modified.

- [ ] **Step 8: Commit the bootstrap fix**

```bash
git add .github/workflows/release.yml \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
git diff --cached --check
git commit -m "fix(release): support canonical-version bootstrap"
git show --check --stat --oneline HEAD
```

Expected: one commit contains exactly the two scoped paths.

### Task 2: Review, merge locally, and reverify

**Files:**

- Review the Task 1 commit and the approved bootstrap design.
- No new source files.

- [ ] **Step 1: Request independent code review**

Use the `requesting-code-review` skill. Require the reviewer to check:

- equality is accepted only when the requested tag is absent;
- lower canonical versions remain rejected;
- greater versions still create the version-bump commit;
- equal versions tag the verified branch commit without an empty commit;
- existing-tag resume and every publication guard are unchanged.

Fix any Critical or Important finding test-first and recommit before proceeding.

- [ ] **Step 2: Merge the reviewed branch into local `main`**

From the main worktree:

```bash
git status --short --branch
git merge --ff-only codex/first-release-bootstrap
```

Expected: clean fast-forward merge.

- [ ] **Step 3: Run the post-merge gate**

```bash
devenv shell -- mix deps.get
devenv shell -- mix deps.unlock --check-unused
devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
devenv shell -- mix test \
  apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs \
  apps/singularity_web/test/singularity/web/asset_toolchain_contract_test.exs \
  apps/singularity_storage/test/singularity/storage/outbox_oban_test.exs
devenv shell -- mix xref graph --format cycles --fail-above 0
nix run nixpkgs#actionlint -- \
  .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/release.yml
git diff --check
git status --short --branch
```

Expected: 33 tests pass and the main worktree is clean.

- [ ] **Step 4: Remove the merged implementation worktree**

From the main repository root:

```bash
git worktree remove .trees/first-release-bootstrap
git worktree prune
git branch -d codex/first-release-bootstrap
```

Expected: the implementation branch is deleted only after the merge and post-merge verification pass.

### Task 3: Push `main` and require CI success

**Files:**

- No local file changes.
- External state: `origin/main`, repository Actions secret, CI and Test workflow runs.

- [ ] **Step 1: Recheck release and remote preconditions**

```bash
test -n "$GHCR_TOKEN"
test -z "$(git status --porcelain)"
test -z "$(git ls-remote origin refs/tags/v0.1.0 'refs/tags/v0.1.0^{}')"
release_response_file="$(mktemp)"
if gh api --include repos/gsmlg-opt/Singularity/releases/tags/v0.1.0 \
    > "$release_response_file" 2>&1; then
  release_api_exit=0
else
  release_api_exit=$?
fi
release_http_status="$(
  sed -nE \
    -e 's#^HTTP/[0-9.]+ ([0-9]{3}).*$#\1#p' \
    -e 's#^.*\(HTTP ([0-9]{3})\).*$#\1#p' \
    "$release_response_file" | head -n 1
)"
rm -f "$release_response_file"
test "$release_api_exit" -ne 0
test "$release_http_status" = 404
git fetch origin main
test "$(git rev-parse origin/main)" = "$(git merge-base HEAD origin/main)"
```

Expected: the secret exists in the local environment, the worktree is clean, no release tag or GitHub Release exists, and local `main` is a descendant of remote `main`.

- [ ] **Step 2: Install the repository secret without exposing it**

```bash
gh secret set GHCR_TOKEN \
  --repo gsmlg-opt/Singularity \
  --app actions \
  --body "$GHCR_TOKEN"
gh secret list --repo gsmlg-opt/Singularity --app actions | grep -q '^GHCR_TOKEN'
```

Expected: `GHCR_TOKEN` is listed by name; its value is never printed.

- [ ] **Step 3: Push `main` and prove the remote SHA**

```bash
push_sha="$(git rev-parse HEAD)"
git push origin main
remote_sha="$(git ls-remote --exit-code --heads origin refs/heads/main | cut -f1)"
test "$remote_sha" = "$push_sha"
```

Expected: `origin/main` equals the exact local source SHA. Never force-push; stop if the remote has advanced.

- [ ] **Step 4: Locate the push-triggered CI and Test runs**

For each workflow file, poll until GitHub returns a run for `push_sha`:

```bash
push_sha="$(git rev-parse HEAD)"
find_run() {
  workflow_file="$1"
  for attempt in $(seq 1 30); do
    run_id="$(
      gh run list \
        --repo gsmlg-opt/Singularity \
        --workflow "$workflow_file" \
        --event push \
        --commit "$push_sha" \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId // empty'
    )"
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
```

Expected: both run IDs are non-empty and belong to the pushed SHA.

- [ ] **Step 5: Wait for both required workflows**

```bash
push_sha="$(git rev-parse HEAD)"
ci_run_id="$(
  gh run list \
    --repo gsmlg-opt/Singularity \
    --workflow ci.yml \
    --event push \
    --commit "$push_sha" \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId // empty'
)"
test_run_id="$(
  gh run list \
    --repo gsmlg-opt/Singularity \
    --workflow test.yml \
    --event push \
    --commit "$push_sha" \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId // empty'
)"
test -n "$ci_run_id"
test -n "$test_run_id"
gh run watch "$ci_run_id" --repo gsmlg-opt/Singularity --exit-status --interval 10
gh run watch "$test_run_id" --repo gsmlg-opt/Singularity --exit-status --interval 10
```

Expected: both runs conclude `success`. On failure, inspect with `gh run view "$ci_run_id" --log-failed` or `gh run view "$test_run_id" --log-failed`; do not dispatch the release. A zero-step billing/account-lock failure is an external blocker.

### Task 4: Dispatch and monitor `v0.1.0`

**Files:**

- No local file changes.
- External state: Release workflow run, annotated Git tag, GHCR manifest/tags, GitHub Release/assets.

- [ ] **Step 1: Repeat the no-release preflight immediately before dispatch**

```bash
test -z "$(git ls-remote origin refs/tags/v0.1.0 'refs/tags/v0.1.0^{}')"
release_response_file="$(mktemp)"
if gh api --include repos/gsmlg-opt/Singularity/releases/tags/v0.1.0 \
    > "$release_response_file" 2>&1; then
  release_api_exit=0
else
  release_api_exit=$?
fi
release_http_status="$(
  sed -nE \
    -e 's#^HTTP/[0-9.]+ ([0-9]{3}).*$#\1#p' \
    -e 's#^.*\(HTTP ([0-9]{3})\).*$#\1#p' \
    "$release_response_file" | head -n 1
)"
rm -f "$release_response_file"
test "$release_api_exit" -ne 0
test "$release_http_status" = 404
```

Expected: tag and release remain absent.

- [ ] **Step 2: Dispatch the manual workflow**

```bash
dispatch_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$dispatch_started" > /tmp/singularity-v0.1.0-dispatch-started
gh workflow run release.yml \
  --repo gsmlg-opt/Singularity \
  --ref main \
  --field version=0.1.0 \
  --field git_ref=main
```

Expected: GitHub accepts the dispatch.

- [ ] **Step 3: Identify the exact release run**

```bash
push_sha="$(git rev-parse HEAD)"
dispatch_started="$(cat /tmp/singularity-v0.1.0-dispatch-started)"
for attempt in $(seq 1 30); do
  release_run_id="$(
    gh run list \
      --repo gsmlg-opt/Singularity \
      --workflow release.yml \
      --event workflow_dispatch \
      --limit 10 \
      --json databaseId,createdAt,headSha |
      jq -r \
        --arg sha "$push_sha" \
        --arg started "$dispatch_started" \
        '.[] | select(.headSha == $sha and .createdAt >= $started) | .databaseId' |
      head -n 1
  )"
  [[ -n "$release_run_id" ]] && break
  sleep 5
done
test -n "$release_run_id"
printf '%s\n' "$release_run_id" > /tmp/singularity-v0.1.0-release-run-id
```

Expected: one run ID matches the pushed source SHA and dispatch time.

- [ ] **Step 4: Monitor to terminal success**

```bash
push_sha="$(git rev-parse HEAD)"
release_run_id="$(cat /tmp/singularity-v0.1.0-release-run-id)"
gh run watch "$release_run_id" \
  --repo gsmlg-opt/Singularity \
  --exit-status \
  --interval 10
gh run view "$release_run_id" \
  --repo gsmlg-opt/Singularity \
  --json status,conclusion,url,headSha |
  tee /tmp/singularity-v0.1.0-release-run.json
jq -e \
  --arg sha "$push_sha" \
  '.status == "completed" and .conclusion == "success" and .headSha == $sha' \
  /tmp/singularity-v0.1.0-release-run.json
```

Expected: `status=completed`, `conclusion=success`, and `headSha=push_sha`.

If the conclusion is not `success`, run:

```bash
gh run view "$release_run_id" --repo gsmlg-opt/Singularity --log-failed
```

Do not create tags, GHCR tags, or release assets manually. For a transient runner/network failure, rerun the failed jobs with `gh run rerun "$release_run_id" --failed`; for a workflow defect, add a failing regression test and return to Task 1; for a billing/account lock, stop and report the external blocker.

### Task 5: Prove the release, assets, and GHCR image

**Files:**

- No repository file changes.
- Read-only verification of remote Git, GitHub Release, downloaded assets, and GHCR.

- [ ] **Step 1: Verify the remote branch and annotated tag identity**

```bash
push_sha="$(git rev-parse HEAD)"
remote_main="$(git ls-remote --exit-code --heads origin refs/heads/main | cut -f1)"
tag_object="$(git ls-remote --exit-code origin refs/tags/v0.1.0 | cut -f1)"
tag_commit="$(git ls-remote --exit-code origin 'refs/tags/v0.1.0^{}' | cut -f1)"
test -n "$tag_object"
test "$tag_commit" = "$push_sha"
test "$remote_main" = "$push_sha"
```

Expected: `v0.1.0` is annotated and peels to the unchanged bootstrap source commit on remote `main`.

- [ ] **Step 2: Verify GitHub Release metadata and exact assets**

```bash
gh release view v0.1.0 \
  --repo gsmlg-opt/Singularity \
  --json tagName,isDraft,isPrerelease,publishedAt,url,targetCommitish,assets |
  tee /tmp/singularity-v0.1.0-release.json
jq -e '
  .tagName == "v0.1.0" and
  .isDraft == false and
  .isPrerelease == false and
  ([.assets[].name] | sort) == [
    "singularity-v0.1.0-linux-amd64-arm64.oci.tar",
    "singularity-v0.1.0-linux-amd64-arm64.oci.tar.sha256"
  ] and
  all(.assets[]; .size > 0)
' /tmp/singularity-v0.1.0-release.json
```

Expected: a published, non-prerelease release has exactly the archive and checksum assets, both non-empty.

- [ ] **Step 3: Download and validate the release archive**

```bash
release_dir="$(mktemp -d)"
printf '%s\n' "$release_dir" > /tmp/singularity-v0.1.0-release-dir
gh release download v0.1.0 \
  --repo gsmlg-opt/Singularity \
  --dir "$release_dir" \
  --pattern 'singularity-v0.1.0-linux-amd64-arm64.oci.tar*'
(
  cd "$release_dir"
  sha256sum -c singularity-v0.1.0-linux-amd64-arm64.oci.tar.sha256
)
```

Expected: SHA-256 validation prints `OK`.

- [ ] **Step 4: Authenticate locally and compare all GHCR tags**

```bash
printf '%s' "$GHCR_TOKEN" |
  docker login ghcr.io --username gsmlg --password-stdin
image_name=ghcr.io/gsmlg-dev/singularity
version_digest="$(docker buildx imagetools inspect "$image_name:0.1.0" | awk '$1 == "Digest:" {print $2; exit}')"
minor_digest="$(docker buildx imagetools inspect "$image_name:0.1" | awk '$1 == "Digest:" {print $2; exit}')"
latest_digest="$(docker buildx imagetools inspect "$image_name:latest" | awk '$1 == "Digest:" {print $2; exit}')"
test -n "$version_digest"
test "$minor_digest" = "$version_digest"
test "$latest_digest" = "$version_digest"
```

Expected: `0.1.0`, `0.1`, and `latest` resolve to one immutable index digest.

- [ ] **Step 5: Verify platforms, archive equivalence, and revision label**

```bash
release_dir="$(cat /tmp/singularity-v0.1.0-release-dir)"
tag_commit="$(git ls-remote --exit-code origin 'refs/tags/v0.1.0^{}' | cut -f1)"
image_name=ghcr.io/gsmlg-dev/singularity
version_digest="$(docker buildx imagetools inspect "$image_name:0.1.0" | awk '$1 == "Digest:" {print $2; exit}')"
registry_index="$(docker buildx imagetools inspect "$image_name:0.1.0" --raw)"
jq -e '
  ([.manifests[].platform | select(.os == "linux") | .architecture] | index("amd64")) != null and
  ([.manifests[].platform | select(.os == "linux") | .architecture] | index("arm64")) != null
' <<< "$registry_index"
archive_digest="$(
  tar -xOf "$release_dir/singularity-v0.1.0-linux-amd64-arm64.oci.tar" index.json |
    jq -er '.manifests | if length == 1 then .[0].digest else error("expected one OCI root descriptor") end'
)"
test "$archive_digest" = "$version_digest"
image_revision="$(
  docker buildx imagetools inspect "$image_name:0.1.0" --format '{{json .Image}}' |
    jq -r '.config.Labels["org.opencontainers.image.revision"]'
)"
test "$image_revision" = "$tag_commit"
```

Expected: the registry has both required Linux architectures, the OCI archive root equals the promoted registry digest, and the image revision label equals the peeled release-tag commit.

- [ ] **Step 6: Record the final release evidence**

Report:

- pushed and remote `main` SHA;
- CI, Test, and Release run IDs plus URLs and conclusions;
- GitHub Release URL and asset names;
- annotated tag object and peeled commit;
- GHCR digest shared by `0.1.0`, `0.1`, and `latest`;
- confirmed `linux/amd64` and `linux/arm64` manifests;
- checksum result and revision label.

Do not deploy, restart a service, or alter any host as part of this task.
