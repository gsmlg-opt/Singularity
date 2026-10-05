# Docker Image Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an image-only workflow with manual tag/ref/latest inputs and published-release builds, without modifying the existing product release workflow.

**Architecture:** Validate the request, resolve exact source, build amd64/arm64 content by digest, verify its manifest, and only then promote aliases. Serialize promotion with the existing Release workflow. Execute the actual workflow Bash snippets against local command stubs to test policy without publishing.

**Tech Stack:** GitHub Actions, pinned Docker Buildx/QEMU actions, GHCR, Bash, jq, Git, ExUnit, YamlElixir, actionlint, devenv.

---

## Approved scope and starting state

- Design: `docs/superpowers/specs/2026-10-04-docker-image-workflow-design.md`.
- Worktree: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/docker-image-workflow`.
- Branch: `codex/docker-image-workflow`; design commit: `00f391d`.
- Base application source: `6cf9744bbcf75e6fa9ce93775c52a94c11169fe2`.
- Existing release/container baseline: 18 tests, 0 failures on the base source.
- Do not change `.github/workflows/release.yml`, `Dockerfile`, dependencies,
  application code, migrations, product phase status, or Vault behavior.
- Do not run E2E/browser tests, dispatch Actions, publish images, push Git,
  create releases/tags, deploy, merge, or delete this worktree during execution.

## File responsibilities

| File | Responsibility |
| --- | --- |
| `.github/workflows/docker-image.yml` | Image-only trigger, source, build, verification, and promotion pipeline. |
| `apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs` | YAML wiring and real Bash policy tests with isolated local stubs. |
| `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs` | Add the new workflow to the exact actionlint enumeration only. |
| `README.md` | Add the new workflow to the existing verification command only. |
| `docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md` | Synchronize only the canonical actionlint file list. |
| `docs/deployment/docker.md` | Explain workflow inputs, image tags, registry credentials, and trigger behavior. |
| This plan | Track steps and append actual local verification evidence. |

Tasks 1 and 2 are dependent (red then green). Task 3 documentation/enumeration
can be prepared independently of Task 2, with separate file ownership. Task 4
depends on both. Workers are not alone in the codebase and must preserve others'
changes. The main agent owns scope decisions and the final evidence review.
Workers must report readiness before staging; the main agent serializes staging
and commits so independent workers do not race on the shared Git index.

## Task 0: Set up the existing isolated checkout

- [x] Confirm the worktree/branch and preserve any unrelated changes:

```bash
git branch --show-current
git status --short
git worktree list
```

Expected branch: `codex/docker-image-workflow`; no unexpected modifications.
Do not create another worktree or copy/symlink another checkout's build cache.

- [x] Fetch locked dependencies in this worktree:

```bash
devenv shell -- mix deps.get
git diff --exit-code -- mix.lock
```

Expected: existing locked versions retained, no lockfile diff. Dependency setup
is not an upstream defect. Do not install Node packages or start database services
for these architecture-only checks.

- [x] Run the existing focused baseline:

```bash
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected: 18 tests, 0 failures. Stop and report a failing baseline assertion; do
not repair unrelated production behavior. No complete product gate is authorized.

## Task 1: Add failing image contracts

**Create:** `apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs`.

- [x] Add this complete test module. Its fixture executables accept only the
  calls exercised by the workflow; all other calls fail. Real Git is used only
  for read-only `check-ref-format`, and no network-capable command is delegated.

```elixir
defmodule Singularity.Architecture.DockerImageWorkflowContractTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../..", __DIR__)
  @source String.duplicate("a", 40)
  @image "ghcr.io/gsmlg-dev/singularity"

  test "image trigger, inputs, permissions and checkout are bounded" do
    workflow = workflow!()
    assert workflow["name"] == "Docker Image"
    assert Map.keys(workflow["on"]) |> Enum.sort() == ["release", "workflow_dispatch"]
    assert workflow["on"]["release"] == %{"types" => ["published"]}
    inputs = workflow["on"]["workflow_dispatch"]["inputs"]
    assert Map.keys(inputs) |> Enum.sort() == ["generate_latest", "git_ref", "tag_name"]
    assert inputs["tag_name"]["required"] == true
    assert inputs["tag_name"]["type"] == "string"
    assert inputs["git_ref"]["default"] == "main"
    assert inputs["git_ref"]["required"] == true
    assert inputs["git_ref"]["type"] == "string"
    assert inputs["generate_latest"]["type"] == "boolean"
    assert inputs["generate_latest"]["default"] == true
    assert workflow["permissions"] == %{"contents" => "read", "packages" => "write"}
    assert workflow["concurrency"] == %{"group" => "Release", "cancel-in-progress" => false}
    assert workflow["env"]["IMAGE_NAME"] == @image
    assert workflow["jobs"]["image"]["timeout-minutes"] == 120

    checkout = step!("Check out image source")
    assert checkout["with"]["persist-credentials"] == false
    assert checkout["with"]["ref"] == "${{ steps.request.outputs.checkout_ref }}"
    assert step!("Validate image request")["env"]["INPUT_TAG"] == "${{ inputs.tag_name }}"
    assert step!("Validate image request")["env"]["INPUT_REF"] == "${{ inputs.git_ref }}"
    assert step!("Resolve image source")["env"]["EVENT_SHA"] == "${{ github.sha }}"
    summary = step!("Summarize image publication")["env"]
    assert summary["SOURCE_REVISION"] == "${{ steps.source.outputs.source_revision }}"
    assert summary["IMAGE_DIGEST"] == "${{ steps.verify.outputs.image_digest }}"
    assert summary["LATEST_UPDATED"] == "${{ steps.promote.outputs.latest_updated }}"

    release = YamlElixir.read_from_file!(Path.join(@repo_root, ".github/workflows/release.yml"))
    release_steps = release["jobs"]["release"]["steps"]
    for {image_name, release_name} <- [
          {"Check out image source", "Check out release source"},
          {"Set up QEMU", "Set up QEMU"}, {"Set up Docker Buildx", "Set up Docker Buildx"},
          {"Log in to GHCR", "Log in to GHCR"},
          {"Build immutable image content", "Build immutable release content"}
        ] do
      release_step = Enum.find(release_steps, &(&1["name"] == release_name))
      assert step!(image_name)["uses"] == release_step["uses"]
    end

    for name <- ["Set up QEMU", "Set up Docker Buildx"] do
      release_step = Enum.find(release_steps, &(&1["name"] == name))
      assert step!(name)["with"] == release_step["with"]
    end

    for step <- steps!() do
      if uses = step["uses"], do: assert(uses =~ ~r/@[0-9a-f]{40}$/)
      if run = step["run"], do: refute(run =~ "${{")
    end
  end

  test "build is immutable, multi-platform and verified before promotion" do
    build = step!("Build immutable image content")["with"]
    assert build["platforms"] == "linux/amd64,linux/arm64"
    assert build["outputs"] =~ "push-by-digest=true"
    refute build["outputs"] =~ "type=oci"
    refute Map.has_key?(build, "tags")
    assert build["build-args"] =~ "VERSION=${{ steps.request.outputs.image_tag }}"
    assert build["build-args"] =~ "REVISION=${{ steps.source.outputs.source_revision }}"
    assert build["provenance"] == "mode=max"
    assert build["sbom"] == true
    assert build["cache-from"] == "type=gha,scope=docker-image"
    names = Enum.map(steps!(), & &1["name"])
    assert index!(names, "Validate image request") < index!(names, "Check out image source")
    assert index!(names, "Resolve image source") < index!(names, "Build immutable image content")
    assert index!(names, "Verify immutable image digest") < index!(names, "Promote image tags")
    assert step!("Log in to GHCR")["with"]["password"] == "${{ secrets.GHCR_TOKEN }}"
    assert step!("Promote image tags")["env"]["IMAGE_DIGEST"] ==
             "${{ steps.verify.outputs.image_digest }}"
  end

  test "tag validation preserves valid tags and rejects invalid tags before promotion" do
    for tag <- ["v0.2.0", "_development.1", String.duplicate("a", 128)] do
      result = run!(["Validate image request"], %{"INPUT_TAG" => tag})
      assert result.status == 0, result.output
      assert result.outputs =~ "image_tag=#{tag}\n"
    end

    for tag <- ["", "latest", "bad/tag", "-bad", "has space", "bad\ninput",
                String.duplicate("a", 129), "$(touch forbidden)"] do
      result = run!(["Validate image request", "Promote image tags"], %{"INPUT_TAG" => tag})
      assert result.status != 0, tag
      assert result.trace == ""
    end

    result = run!(["Validate image request"], %{"INPUT_REF" => "bad\nref"})
    assert result.status != 0

    result = run!(["Validate image request"], %{"INPUT_LATEST" => "invalid"})
    assert result.status != 0
  end

  test "source resolution rejects unresolved refs and moved release tags" do
    result = run!(["Resolve image source"])
    assert result.status == 0, result.output
    assert result.outputs =~ "source_revision=#{@source}\n"

    for overrides <- [
          %{"FIXTURE_MISSING_REF" => "true"},
          %{"FIXTURE_TARGET_SHA" => String.duplicate("b", 40)},
          %{"EVENT_NAME" => "release", "CHECKOUT_REF" => "refs/tags/v0.2.0",
            "EVENT_SHA" => String.duplicate("c", 40)}
        ] do
      result = run!(["Resolve image source", "Promote image tags"], overrides)
      assert result.status != 0, result.output
      assert result.trace == ""
    end
  end

  test "manual named and latest aliases use the same verified digest" do
    result = run!(["Verify immutable image digest", "Promote image tags", "Summarize image publication"])
    assert result.status == 0, result.output
    assert result.trace =~ "--tag #{@image}:v0.2.0 --tag #{@image}:latest #{@image}@"
    assert result.summary =~ "Source revision: #{@source}"
    assert result.summary =~ "Immutable image: #{@image}@sha256:"
    assert result.summary =~ "Updated latest: true"

    result = run!(["Promote image tags"], %{"LATEST_REQUESTED" => "false"})
    assert result.status == 0, result.output
    assert result.trace =~ "--tag #{@image}:v0.2.0"
    refute result.trace =~ ":latest"
  end

  test "release request uses the tag namespace and prereleases disable latest" do
    event = Jason.encode!(%{release: %{tag_name: "v0.2.0", prerelease: true, id: 123}})
    result = run!(["Validate image request"], %{"EVENT_NAME" => "release", "EVENT_JSON" => event})
    assert result.status == 0, result.output
    assert result.outputs =~ "checkout_ref=refs/tags/v0.2.0\n"
    assert result.outputs =~ "latest_requested=false\n"

    result = run!(["Promote image tags"], %{"EVENT_NAME" => "release", "LATEST_REQUESTED" => "false"})
    assert result.status == 0, result.output
    refute result.trace =~ ":latest"
  end

  test "stable latest is rechecked and API uncertainty stops promotion" do
    result = run!(["Promote image tags"], %{"EVENT_NAME" => "release"})
    assert result.status == 0, result.output
    assert result.trace =~ ":latest"

    result = run!(["Promote image tags"], %{"EVENT_NAME" => "release", "FIXTURE_LATEST_ID" => "999"})
    assert result.status == 0, result.output
    refute result.trace =~ ":latest"

    for overrides <- [%{"FIXTURE_API_FAILURE" => "true"}, %{"FIXTURE_LATEST_ID" => "null"}] do
      result = run!(["Promote image tags"], Map.put(overrides, "EVENT_NAME", "release"))
      assert result.status != 0, result.output
      assert result.trace == ""
    end
  end

  test "metadata and raw digest disagreement prevent promotion" do
    for overrides <- [
          %{"ACTION_DIGEST" => "invalid"},
          %{"BUILD_METADATA" => Jason.encode!(%{"containerimage.digest" => "sha256:" <> String.duplicate("0", 64)})},
          %{"FIXTURE_RAW_MISMATCH" => "true"}
        ] do
      result = run!(["Verify immutable image digest", "Promote image tags"], overrides)
      assert result.status != 0, result.output
      assert result.trace == ""
    end
  end

  test "malformed platforms, descriptors and attestations prevent promotion" do
    index = manifest!()
    [amd, arm, amd_att, arm_att] = index["manifests"]
    invalid_indexes = [
      Map.put(index, "mediaType", "application/vnd.docker.distribution.manifest.list.v2+json"),
      Map.put(index, "schemaVersion", 1),
      Map.put(index, "manifests", [amd, amd_att]),
      Map.put(index, "manifests", [amd, amd, arm, amd_att, arm_att]),
      Map.put(index, "manifests", [Map.put(amd, "size", 0), arm, amd_att, arm_att]),
      Map.put(index, "manifests", [amd, arm, Map.delete(amd_att, "annotations"), arm_att]),
      Map.put(index, "manifests", [amd, arm, arm_att, arm_att]),
      Map.put(index, "manifests", [amd, arm, amd_att, arm_att,
        Map.put(amd, "platform", %{"os" => "linux", "architecture" => "s390x"})])
    ]

    for invalid <- invalid_indexes do
      result = run!(["Verify immutable image digest", "Promote image tags"],
        %{"MANIFEST_JSON" => Jason.encode!(invalid)})
      assert result.status != 0, result.output
      assert result.trace == ""
    end
  end

  test "all workflow shell snippets have valid Bash syntax" do
    for step <- steps!(), script = step["run"], is_binary(script) do
      assert {"", 0} = System.cmd("bash", ["-n", "-c", script], stderr_to_stdout: true)
    end
  end

  defp workflow!, do: YamlElixir.read_from_file!(Path.join(@repo_root, ".github/workflows/docker-image.yml"))
  defp steps!, do: workflow!()["jobs"]["image"]["steps"]
  defp step!(name), do: Enum.find(steps!(), &(&1["name"] == name)) || flunk("missing step #{name}")
  defp index!(names, name), do: Enum.find_index(names, &(&1 == name)) || flunk("missing step #{name}")

  defp run!(names, overrides \\ %{}) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    directory = Path.join(System.tmp_dir!(), "singularity-image-contract-#{suffix}")
    File.mkdir!(directory)

    try do
      for {name, body} <- commands!() do
        path = Path.join(directory, name)
        File.write!(path, "#!/usr/bin/env bash\nset -euo pipefail\n" <> body)
        File.chmod!(path, 0o700)
      end

      manifest = Map.get(overrides, "MANIFEST_JSON", Jason.encode!(manifest!()))
      digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, manifest), case: :lower)
      event = Map.get(overrides, "EVENT_JSON", Jason.encode!(%{release: %{tag_name: "v0.2.0", prerelease: false, id: 123}}))
      File.write!(Path.join(directory, "manifest.json"), manifest)
      File.write!(Path.join(directory, "event.json"), event)
      for name <- ["outputs", "trace", "summary"], do: File.write!(Path.join(directory, name), "")

      environment = Map.merge(%{
        "PATH" => directory <> ":" <> System.fetch_env!("PATH"),
        "REAL_GIT" => System.find_executable("git"),
        "GITHUB_OUTPUT" => Path.join(directory, "outputs"),
        "GITHUB_STEP_SUMMARY" => Path.join(directory, "summary"),
        "GITHUB_EVENT_PATH" => Path.join(directory, "event.json"),
        "GITHUB_REPOSITORY" => "gsmlg-opt/Singularity",
        "FIXTURE_MANIFEST" => Path.join(directory, "manifest.json"),
        "FIXTURE_TRACE" => Path.join(directory, "trace"),
        "FIXTURE_HEAD_SHA" => @source, "FIXTURE_TARGET_SHA" => @source,
        "FIXTURE_LATEST_ID" => "123", "EVENT_NAME" => "workflow_dispatch",
        "EVENT_SHA" => @source, "INPUT_TAG" => "v0.2.0", "INPUT_REF" => "main",
        "INPUT_LATEST" => "true", "CHECKOUT_REF" => "main", "IMAGE_TAG" => "v0.2.0",
        "IMAGE_NAME" => @image, "LATEST_REQUESTED" => "true", "IMAGE_DIGEST" => digest,
        "ACTION_DIGEST" => digest, "SOURCE_REVISION" => @source, "LATEST_UPDATED" => "true",
        "BUILD_METADATA" => Jason.encode!(%{"containerimage.digest" => digest})
      }, overrides)

      script = Enum.map_join(names, "\n", &(step!(&1)["run"]))
      {output, status} = System.cmd("bash", ["-c", script],
        env: Map.to_list(environment), cd: directory, stderr_to_stdout: true)
      %{status: status, output: output, outputs: File.read!(Path.join(directory, "outputs")),
        trace: File.read!(Path.join(directory, "trace")),
        summary: File.read!(Path.join(directory, "summary"))}
    after
      File.rm_rf!(directory)
    end
  end

  defp commands! do
    %{
      "git" => ~S"""
      case "$*" in
        check-ref-format\ --branch\ *) exec "$REAL_GIT" "$@" ;;
        'rev-parse --verify --end-of-options HEAD^{commit}') printf '%s\n' "$FIXTURE_HEAD_SHA" ;;
        rev-parse\ --verify\ --end-of-options\ *)
          test "${FIXTURE_MISSING_REF:-false}" != true
          printf '%s\n' "$FIXTURE_TARGET_SHA" ;;
        *) echo 'unexpected git call' >&2; exit 97 ;;
      esac
      """,
      "gh" => ~S"""
      test "$*" = "api repos/$GITHUB_REPOSITORY/releases/latest --jq .id"
      test "${FIXTURE_API_FAILURE:-false}" != true
      printf '%s\n' "$FIXTURE_LATEST_ID"
      """,
      "docker" => ~S"""
      case "$*" in
        "buildx imagetools inspect $IMAGE_NAME@$ACTION_DIGEST --raw")
          if [[ "${FIXTURE_RAW_MISMATCH:-false}" == true ]]; then
            printf 'different bytes'
          else
            cat "$FIXTURE_MANIFEST"
          fi ;;
        buildx\ imagetools\ create\ *) printf '%s\n' "$*" >> "$FIXTURE_TRACE" ;;
        *) echo 'unexpected docker call' >&2; exit 97 ;;
      esac
      """
    }
  end

  defp manifest! do
    media_type = "application/vnd.oci.image.manifest.v1+json"
    amd = %{"mediaType" => media_type, "size" => 100, "digest" => digest!("1"),
      "platform" => %{"os" => "linux", "architecture" => "amd64"}}
    arm = %{"mediaType" => media_type, "size" => 100, "digest" => digest!("2"),
      "platform" => %{"os" => "linux", "architecture" => "arm64"}}
    attestation = fn descriptor, digit ->
      %{"mediaType" => media_type, "size" => 100, "digest" => digest!(digit),
        "platform" => %{"os" => "unknown", "architecture" => "unknown"},
        "annotations" => %{"vnd.docker.reference.type" => "attestation-manifest",
          "vnd.docker.reference.digest" => descriptor["digest"]}}
    end
    %{"schemaVersion" => 2, "mediaType" => "application/vnd.oci.image.index.v1+json",
      "manifests" => [amd, arm, attestation.(amd, "3"), attestation.(arm, "4")]}
  end

  defp digest!(digit), do: "sha256:" <> String.duplicate(digit, 64)
end
```

- [x] Run the new focused module before adding the workflow:

```bash
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs
```

Expected: failure because `.github/workflows/docker-image.yml` does not exist.
Save the red output. Do not mask missing workflow errors or skip assertions.
The two-filename green suite later should contain 28 tests (18 existing + 10 new).

## Task 2: Implement the image-only pipeline and reach green

**Create:** `.github/workflows/docker-image.yml`.
**Test:** `apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs`.

- [x] Add the complete workflow below. Reuse the approved pins; do not update
  dependency/action versions or the existing release workflow as part of this
  task. `github.sha` for release events is the event's tagged commit, whereas
  manual source identity comes from the selected `git_ref` checkout.

```yaml
name: Docker Image

on:
  workflow_dispatch:
    inputs:
      tag_name:
        description: Named Docker tag to publish (not latest)
        required: true
        type: string
      git_ref:
        description: Repository branch, tag, or commit SHA to build
        required: true
        default: main
        type: string
      generate_latest:
        description: Also promote the image to latest
        default: true
        type: boolean
  release:
    types: [published]

permissions:
  contents: read
  packages: write

# Serialize promotion with the existing workflow named Release.
concurrency:
  group: Release
  cancel-in-progress: false

env:
  IMAGE_NAME: ghcr.io/gsmlg-dev/singularity

jobs:
  image:
    runs-on: ubuntu-latest
    timeout-minutes: 120
    steps:
      - name: Validate image request
        id: request
        shell: bash
        env:
          EVENT_NAME: ${{ github.event_name }}
          INPUT_TAG: ${{ inputs.tag_name }}
          INPUT_REF: ${{ inputs.git_ref }}
          INPUT_LATEST: ${{ inputs.generate_latest }}
        run: |
          set -euo pipefail
          case "$EVENT_NAME" in
            workflow_dispatch)
              tag="$INPUT_TAG"
              ref="$INPUT_REF"
              latest="$INPUT_LATEST"
              ;;
            release)
              tag="$(jq -er '.release.tag_name | select(type == "string")' "$GITHUB_EVENT_PATH")"
              ref="refs/tags/$tag"
              if jq -e '.release.prerelease == false' "$GITHUB_EVENT_PATH" >/dev/null; then
                latest=true
              elif jq -e '.release.prerelease == true' "$GITHUB_EVENT_PATH" >/dev/null; then
                latest=false
              else
                echo 'invalid release prerelease flag' >&2
                exit 1
              fi
              ;;
            *) echo 'unsupported image event' >&2; exit 1 ;;
          esac
          if [[ ! "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ || "$tag" == latest ]]; then
            echo 'invalid named Docker tag; latest is a reserved alias' >&2
            exit 1
          fi
          [[ "$latest" == true || "$latest" == false ]] || exit 1
          [[ -n "$ref" && "$ref" != -* ]] || exit 1
          git check-ref-format --branch "$ref" >/dev/null
          {
            echo "image_tag=$tag"
            echo "checkout_ref=$ref"
            echo "latest_requested=$latest"
          } >> "$GITHUB_OUTPUT"

      - name: Check out image source
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          ref: ${{ steps.request.outputs.checkout_ref }}
          fetch-depth: 0
          persist-credentials: false

      - name: Resolve image source
        id: source
        shell: bash
        env:
          CHECKOUT_REF: ${{ steps.request.outputs.checkout_ref }}
          EVENT_NAME: ${{ github.event_name }}
          EVENT_SHA: ${{ github.sha }}
        run: |
          set -euo pipefail
          head="$(git rev-parse --verify --end-of-options 'HEAD^{commit}')"
          selected="$(git rev-parse --verify --end-of-options "$CHECKOUT_REF^{commit}")"
          [[ "$head" =~ ^[0-9a-f]{40}$ && "$head" == "$selected" ]] || exit 1
          if [[ "$EVENT_NAME" == release ]]; then
            [[ "$selected" == "$EVENT_SHA" ]] || {
              echo 'release source differs from event commit' >&2
              exit 1
            }
          fi
          echo "source_revision=$head" >> "$GITHUB_OUTPUT"

      - name: Set up QEMU
        uses: docker/setup-qemu-action@96fe6ef7f33517b61c61be40b68a1882f3264fb8
        with:
          image: docker.io/tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0
          platforms: arm64

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@37fe631027851001ddb9b187196cc803df7f5f0e
        with:
          version: v0.36.1
          driver-opts: image=moby/buildkit:v0.32.2@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8

      - name: Log in to GHCR
        uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GHCR_TOKEN }}

      - name: Build immutable image content
        id: build
        uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a
        with:
          context: .
          file: Dockerfile
          platforms: linux/amd64,linux/arm64
          outputs: type=image,name=${{ env.IMAGE_NAME }},push-by-digest=true,name-canonical=true,push=true,oci-mediatypes=true
          labels: |
            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}
            org.opencontainers.image.version=${{ steps.request.outputs.image_tag }}
            org.opencontainers.image.revision=${{ steps.source.outputs.source_revision }}
          build-args: |
            VERSION=${{ steps.request.outputs.image_tag }}
            REVISION=${{ steps.source.outputs.source_revision }}
          cache-from: type=gha,scope=docker-image
          cache-to: type=gha,mode=max,scope=docker-image
          provenance: mode=max
          sbom: true

      - name: Verify immutable image digest
        id: verify
        shell: bash
        env:
          ACTION_DIGEST: ${{ steps.build.outputs.digest }}
          BUILD_METADATA: ${{ steps.build.outputs.metadata }}
        run: |
          set -euo pipefail
          [[ "$ACTION_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
          metadata_digest="$(jq -er '."containerimage.digest"' <<< "$BUILD_METADATA")"
          [[ "$metadata_digest" == "$ACTION_DIGEST" ]] || exit 1
          manifest_file="$(mktemp)"
          trap 'rm -f "$manifest_file"' EXIT
          docker buildx imagetools inspect "$IMAGE_NAME@$ACTION_DIGEST" --raw > "$manifest_file"
          raw_digest="sha256:$(sha256sum "$manifest_file" | cut -d ' ' -f1)"
          [[ "$raw_digest" == "$ACTION_DIGEST" ]] || exit 1
          jq -e '
            def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
            def positive_integer: type == "number" and . > 0 and floor == .;
            def descriptor:
              if type == "object" and
                 .mediaType == "application/vnd.oci.image.manifest.v1+json" and
                 (.digest | digest) and (.size | positive_integer) and
                 (.platform | type) == "object"
              then . else error("invalid OCI descriptor") end;
            def kind:
              if .platform.os == "linux" and
                 (.platform.architecture == "amd64" or .platform.architecture == "arm64")
              then "runnable"
              elif .platform.os == "unknown" and .platform.architecture == "unknown" and
                   (.platform | keys | sort) == ["architecture", "os"] and
                   (.annotations | type) == "object" and
                   .annotations["vnd.docker.reference.type"] == "attestation-manifest" and
                   (.annotations["vnd.docker.reference.digest"] | digest)
              then "attestation" else error("unexpected OCI platform") end;
            if .schemaVersion == 2 and
               .mediaType == "application/vnd.oci.image.index.v1+json" and
               (.manifests | type) == "array"
            then . else error("invalid OCI root index") end
            | [.manifests[] | descriptor | . + {kind: kind}] as $entries
            | [$entries[] | select(.kind == "runnable")] as $runs
            | if ($runs | length) == 2 and
                 ($runs | map(.platform.os + "/" + .platform.architecture) | sort) ==
                   ["linux/amd64", "linux/arm64"] and
                 ($runs | map(.digest) | unique | length) == 2 and
                 ([$entries[] | select(.kind == "attestation") |
                    .annotations["vnd.docker.reference.digest"]] | sort) ==
                   ($runs | map(.digest) | sort)
              then true else error("required platforms or attestation references differ") end
          ' "$manifest_file" >/dev/null
          echo "image_digest=$ACTION_DIGEST" >> "$GITHUB_OUTPUT"

      - name: Promote image tags
        id: promote
        shell: bash
        env:
          GH_TOKEN: ${{ github.token }}
          EVENT_NAME: ${{ github.event_name }}
          IMAGE_TAG: ${{ steps.request.outputs.image_tag }}
          LATEST_REQUESTED: ${{ steps.request.outputs.latest_requested }}
          IMAGE_DIGEST: ${{ steps.verify.outputs.image_digest }}
        run: |
          set -euo pipefail
          [[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
          [[ "$LATEST_REQUESTED" == true || "$LATEST_REQUESTED" == false ]] || exit 1
          latest="$LATEST_REQUESTED"
          if [[ "$EVENT_NAME" == release && "$latest" == true ]]; then
            release_id="$(jq -er '.release.id | select(type == "number" and . > 0 and floor == .)' "$GITHUB_EVENT_PATH")"
            latest_id="$(gh api "repos/$GITHUB_REPOSITORY/releases/latest" --jq '.id')"
            [[ "$latest_id" =~ ^[1-9][0-9]*$ ]] || exit 1
            if [[ "$release_id" != "$latest_id" ]]; then
              latest=false
            fi
          fi
          tags=(--tag "$IMAGE_NAME:$IMAGE_TAG")
          if [[ "$latest" == true ]]; then
            tags+=(--tag "$IMAGE_NAME:latest")
          fi
          docker buildx imagetools create "${tags[@]}" "$IMAGE_NAME@$IMAGE_DIGEST"
          echo "latest_updated=$latest" >> "$GITHUB_OUTPUT"

      - name: Summarize image publication
        shell: bash
        env:
          IMAGE_TAG: ${{ steps.request.outputs.image_tag }}
          SOURCE_REVISION: ${{ steps.source.outputs.source_revision }}
          IMAGE_DIGEST: ${{ steps.verify.outputs.image_digest }}
          LATEST_UPDATED: ${{ steps.promote.outputs.latest_updated }}
        run: |
          set -euo pipefail
          {
            echo '### Docker image publication'
            printf '* Named image: %s:%s\n' "$IMAGE_NAME" "$IMAGE_TAG"
            printf '* Source revision: %s\n' "$SOURCE_REVISION"
            printf '* Immutable image: %s@%s\n' "$IMAGE_NAME" "$IMAGE_DIGEST"
            echo '* Platforms: linux/amd64,linux/arm64'
            printf '* Updated latest: %s\n' "$LATEST_UPDATED"
          } >> "$GITHUB_STEP_SUMMARY"
```

- [x] Run the new contract module. Expected: 10 tests, 0 failures; real Bash
  accepts valid requests and rejects invalid inputs, source identity mismatches,
  digest disagreements, and unsafe latest eligibility.

```bash
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs
```

- [x] Format the new module and check both focused contracts:

```bash
devenv shell -- mix format apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected: 28 tests, 0 failures. If Task 3 is editing the enumeration concurrently,
wait until its three files are synchronized before treating a gate failure as a
workflow defect. Never weaken the existing release contract.

- [x] Commit only this task's files after green checks:

```bash
git add .github/workflows/docker-image.yml apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs
git diff --cached --check
git commit -m "ci(docker): add verified manual and release image publishing"
```

## Task 3: Synchronize verification lists and add operator usage

**Modify:** `README.md`,
`docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`,
`apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`,
and `docs/deployment/docker.md`.

- [x] Update only the expected command string in the existing contract first:

```elixir
    "nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/release.yml .github/workflows/docker-image.yml",
```

This replaces its current actionlint string, not the rest of
`@canonical_verification_commands`. Preserve every required assertion and command.

- [x] Run the existing focused contract before editing the Markdown lists:

```bash
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected red: the explicit command oracle includes the new workflow, but README
and the canonical plan still have the old file list. Record that mismatch; do
not change the parser, wrapper requirements, E2E command, or any release assertion.

- [x] Replace the actionlint block in each of `README.md` and
  `docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md` with this exact
  block, keeping the surrounding verification sequence unchanged:

```bash
nix run nixpkgs#actionlint -- \
  .github/workflows/ci.yml \
  .github/workflows/test.yml \
  .github/workflows/release.yml \
  .github/workflows/docker-image.yml
```

- [x] Append the following complete section to `docs/deployment/docker.md`.
  The nested examples are documentation only: do not dispatch them during this
  task. The existing deployment instructions remain unchanged.

````markdown
## GitHub Actions image builds

The `Docker Image` workflow is image-only. It builds `linux/amd64,linux/arm64`
from an exact resolved source commit and publishes to
`ghcr.io/gsmlg-dev/singularity`. It does not bump the application version, create
a Git tag or GitHub Release, generate a release OCI archive, or deploy anything.

After the workflow is separately pushed/merged to the default branch, authorized
operators can open Actions → Docker Image → Run workflow. Inputs are:

| Input | Purpose |
| --- | --- |
| `tag_name` | Exact named Docker tag, such as `preview-6cf9744`. Required; `latest` is reserved. |
| `git_ref` | Source branch, Git tag, or commit SHA. Defaults to `main`. |
| `generate_latest` | Also update the `latest` image alias. Defaults to `true`; disable for development snapshots. |

With separate authorization to publish, the equivalent CLI invocation is:

```bash
gh workflow run docker-image.yml --repo gsmlg-opt/Singularity --ref main \
  -f tag_name=preview-6cf9744 \
  -f git_ref=6cf9744bbcf75e6fa9ce93775c52a94c11169fe2 \
  -f generate_latest=false
```

`--ref main` selects the workflow definition; the `git_ref` input selects the
application source to build. The resolved full commit SHA is stored in the image
revision label and the `REVISION` build argument. `tag_name` supplies image
metadata through `VERSION`; it does not override Mix's application version.
Invalid tags or unavailable refs fail before the Docker build. Credentials are
never passed to the build as arguments.

For automatic `release: published` runs, the GitHub Release tag supplies both
the named Docker tag and source Git tag. The tag must still resolve to the event's
commit, so a moved tag cannot silently replace the published source. Prereleases
publish only the named tag. A stable release updates `latest` only if its release
ID is still the designated latest stable release when promotion occurs. Older
releases that are not the designated latest stable release retain their named
image tag without changing `latest`.

The existing `Release` workflow remains unchanged: it already verifies and
publishes images, including its minor-version aliases, before creating a GitHub
Release using `GITHUB_TOKEN`. Those token-created release events do not trigger a
second downstream image workflow. Human-, GitHub App-, or PAT-published releases
can trigger the new workflow. See [GitHub's trigger rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).

The repository must retain the existing `GHCR_TOKEN` secret with write access to
the `gsmlg-dev/singularity` package namespace. The repository's ordinary
`GITHUB_TOKEN` is used only for read-only release-state checks in this workflow;
do not assume it can publish to another organization's package namespace. The
workflow does not create or modify secrets.

Builds push immutable content by digest, validate the registry manifest, then
promote the named tag and eligible `latest` alias from that verified digest.
Both workflows share the `Release` concurrency group without cancelling an
in-flight publication. The run summary records source SHA, named image tag,
immutable digest, platforms, and whether `latest` was updated. Deployment should
use the recorded immutable digest, not assume a mutable alias remains unchanged.

Local workflow-contract tests and actionlint do not prove a hosted multi-platform
build or publication. Running this workflow publishes an image but does not
accept an unfinished `0.2.0` phase or authorize production activation.
````

- [x] Format the changed existing test and run the existing contract after both
  Markdown lists are synchronized. Wait for Task 2 before running actionlint on
  a workflow that has not yet been added.

```bash
devenv shell -- mix format apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected: 18 tests, 0 failures. Only the actionlint enumeration changes in the
canonical release plan and its contract; the product gate remains mandatory.

- [x] Commit only this task's files after the workflow exists and checks pass:

```bash
git add README.md docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs docs/deployment/docker.md
git diff --cached --check
git commit -m "docs(docker): document image workflow and extend lint gate"
```

## Task 4: Final scoped verification and handoff

**Modify:** this plan's execution record, after actual checks.

- [x] Verify the complete changed-test suite and formatting:

```bash
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
devenv shell -- mix format --check-formatted apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected: 28 tests, 0 failures; formatting exit 0. The new module also executes
`bash -n` for every actual workflow shell snippet. If a required focused
assertion fails, stop the affected step, record evidence, and repair only an
in-scope defect without weakening the assertion.

- [x] Lint all four workflow files without running them:

```bash
nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/release.yml .github/workflows/docker-image.yml
```

Expected: exit 0. Do not dispatch the workflow or publish to obtain evidence.

- [x] Confirm zero application source cycles and that the existing release,
  Dockerfile, dependencies, and application source are unchanged:

```bash
devenv shell -- env MIX_ENV=test mix xref graph --format cycles --fail-above 0
git diff --exit-code 6cf9744bbcf75e6fa9ce93775c52a94c11169fe2 -- .github/workflows/release.yml Dockerfile mix.exs mix.lock apps/singularity_core apps/singularity_domains apps/singularity_storage apps/singularity_ingest apps/singularity_retrieval apps/singularity_runtime apps/singularity_web/lib
git diff --check 6cf9744bbcf75e6fa9ce93775c52a94c11169fe2
git status --short
git log --oneline -n 5
```

Expected: `No cycles found`; no diff for excluded production files; no whitespace
errors. Review the complete changed-file list against this plan's scope.

- [x] Append an `Execution record` section to this plan containing the actual
  source commits, changed files, red failures, green counts, exact commands and
  exit results, remaining platform/registry risks, and an explicit statement
  that no Vault work, migrations, E2E tests, push, dispatch, publication, release,
  or deployment occurred. Do not invent results for checks not performed.
  The execution-record format is:

```markdown
## Execution record

Document each executed command with its exit code and observed output. Include
the resulting implementation commits and distinguish local policy verification
from a real hosted image build, image publication, and product acceptance.
Record any checks not run and preserve the separately gated operations.
```

The sentences above are instructions for writing an evidence record, not claimed
results. Replace them with the actual chronological evidence during execution.

- [x] Commit the evidence record using `git add` for this plan only, followed by
  `git diff --cached --check` and:

```bash
git commit -m "docs(ci): record Docker image workflow verification"
```

- [x] Stop after scoped verification. Hand off the branch, commits, workflow and
  operator-guide paths, tests, and limitations. Ask for separate authority before
  merging, pushing, dispatching, publishing, or deploying.

## Plan self-review checklist

- [x] Every approved trigger/input/source requirement maps to Tasks 1–2.
- [x] Every digest/platform/promotion/latest requirement maps to Tasks 1–2.
- [x] Existing release behavior remains unchanged; only its actionlint oracle
  and synchronized Markdown enumeration change in Task 3.
- [x] Local test stubs cannot invoke Docker publication or GitHub mutation.
- [x] No dependencies, migrations, runtime behavior, or Vault files change.
- [x] Task 4 distinguishes local static/policy evidence from real publication
  and product acceptance, and preserves the no-E2E boundary.

## Planning-only validation — 2026-10-05

The main agent reviewed this plan against the approved spec, checked placeholder
absence and file ownership, and validated the embedded examples without adding
the actual workflow or test module to the repository. At planning time, execution
checkboxes above remained unchecked. The spec status recorded the user's approval.

The following command was run from the unchanged main checkout. It parses the
plan's YAML and substitutes that map into the planned test module **in memory**,
so the fixture tests can run before source files are added:

```bash
devenv shell -- env MIX_ENV=test mix run --no-start -e '
plan = File.read!("/home/gao/Workspace/gsmlg-opt/Singularity/.trees/docker-image-workflow/docs/superpowers/plans/2026-10-05-docker-image-workflow.md")
[_, source] = Regex.run(~r/```elixir\n(defmodule .*?)\n```/s, plan)
[_, yaml] = Regex.run(~r/```yaml\n(.*?)\n```/s, plan)
workflow = YamlElixir.read_from_string!(yaml)
quoted_workflow = Macro.to_string(Macro.escape(workflow))
source = String.replace(source, ~S|Path.expand("../../../../..", __DIR__)|, inspect(File.cwd!()))
source = String.replace(source, ~S|YamlElixir.read_from_file!(Path.join(@repo_root, ".github/workflows/docker-image.yml"))|, quoted_workflow)
ExUnit.start(autorun: false)
Code.compile_string(source, "planned_image_contract.exs")
result = ExUnit.run()
if result.failures > 0, do: System.halt(1)
'
```

Observed: exit 0, **10 tests, 0 failures**, including actual Bash policy and
syntax checks. Temporary fixture directories were cleaned by the harness. An
initial wrapper command had a sigil-delimiter syntax error before evaluating
any examples; only that wrapper was corrected. No feature-source repair occurred.

The workflow example was also linted from standard input:

```bash
awk '/^```yaml$/ {in_yaml=1; next} /^```$/ && in_yaml {exit} in_yaml {print}' /home/gao/Workspace/gsmlg-opt/Singularity/.trees/docker-image-workflow/docs/superpowers/plans/2026-10-05-docker-image-workflow.md | nix run nixpkgs#actionlint -- -
```

Observed: actionlint 1.7.12, final exit 0 with no diagnostics. Its first run
reported ShellCheck SC2016 for literal Markdown backticks in summary strings;
the planned summary was changed to plain text and checked again, without
disabling lint or weakening an assertion. The updated examples were then rerun
in memory with the same 10-test passing result.

Only this plan and the spec's approval-status line changed. No workflow, real
test module, application code, migration, dependency lock, or Vault feature was
modified. No E2E test, hosted build, registry publication, Git push, dispatch,
release, merge, or deployment occurred. Real GitHub permissions, registry access,
and an actual amd64/arm64 build remain unverified and separately gated.

## Execution record — 2026-10-05

Implementation was authorized by the user's selection of subagent-driven
execution. All commands below ran in
`/home/gao/Workspace/gsmlg-opt/Singularity/.trees/docker-image-workflow`,
on `codex/docker-image-workflow`, unless explicitly described as review only.
The existing main checkout was not modified by this execution.

### Source and local commits

- Application baseline: `6cf9744bbcf75e6fa9ce93775c52a94c11169fe2`.
- Approved design: `00f391dc0baf128ff26668b6d10cdaea3e3604ff`.
- Starting plan: `89251e0b10ad8dd6fb163931965549193966da48`.
- Workflow and focused contracts:
  `c19c246a97f6a5980d7d4f2f20c8bb14b7d7619a`
  (`ci(docker): add verified manual and release image publishing`).
- Operator documentation and synchronized lint gate:
  `253fcbba28e1596e04b94ae997ba19613a0e0a4f`
  (`docs(docker): document image workflow and extend lint gate`).

The evidence record is committed separately; its resulting SHA is reported in
the final handoff rather than embedded in its own contents.

### Setup and red evidence

```bash
git branch --show-current
git status --short
git worktree list
devenv shell -- mix deps.get
git diff --exit-code -- mix.lock
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

All exited 0. The initial worktree was clean on the expected branch at the
starting plan commit. Locked dependencies were fetched without a lockfile diff.
The baseline contained **18 tests, 0 failures**, seed `423786`. No Node install
or database service was required. Devenv warned that the installed CLI is newer
than the locked devenv input; no environment or dependency version was changed.

Before adding the workflow:

```bash
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs
```

Exit 2: **10 tests, 10 failures**, seed `87369`. Each failure was
`YamlElixir.FileNotFoundError` for the absent `docker-image.yml`, not a fixture
syntax or dependency error. After review strengthened the assertions, the same
command again exited 2 with **10 tests, 10 failures**, seed `705890`, for that
same missing workflow. No assertion was removed, skipped, or weakened.

After changing only the existing contract's expected actionlint enumeration,
the existing focused command above exited 2: **18 tests, 1 failure**, seed
`195634`. The failure was
`canonical release plan complete verification commands differ from the explicit canonical order`.
README and the canonical release plan still contained the original three-file
list at this point. Synchronizing their lists restored **18 tests, 0 failures**,
exit 0, seed `726106`.

### Formatting and green evidence

```bash
devenv shell -- mix format apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs
devenv shell -- mix format apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
devenv shell -- mix format --check-formatted apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Both scoped formatting commands and the final two-file formatting check exited
0. A preliminary one-file `--check-formatted` invocation exited 1 while the
copied example was still unformatted; formatting corrected that without changing
its assertions. Subsequent one-file checks also exited 0.

After implementing the actual workflow, the new focused command above exited 0:
**10 tests, 0 failures**. Both the implementer and the main agent then ran:

```bash
devenv shell -- mix test apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Exit 0: **28 tests, 0 failures**. Main-agent runs used seeds `725940` and
`982877`; the latter ran after the implementation and documentation commits.
The suite executes the actual five workflow Bash snippets against local stubs
and runs `bash -n` on each. Valid requests succeeded; invalid tags, unresolved or
mismatched source identity, digest disagreements, malformed OCI indexes,
prereleases, older stable releases, and API failures followed their required
fail-closed or no-latest paths without network publication.

```bash
nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/release.yml .github/workflows/docker-image.yml
devenv shell -- env MIX_ENV=test mix xref graph --format cycles --fail-above 0
git diff --exit-code 6cf9744bbcf75e6fa9ce93775c52a94c11169fe2 -- .github/workflows/release.yml Dockerfile mix.exs mix.lock apps/singularity_core apps/singularity_domains apps/singularity_storage apps/singularity_ingest apps/singularity_retrieval apps/singularity_runtime apps/singularity_web/lib
git diff --check 6cf9744bbcf75e6fa9ce93775c52a94c11169fe2
```

All exited 0. Actionlint produced no diagnostics; xref reported `No cycles found`.
Excluded production files had no diff, and no whitespace errors were found.
All four checks and the two-file formatting check were repeated after the
implementation/documentation commits with the same successful results. Parallel
Mix commands briefly waited for normal build-directory locks and all completed.
`git diff --cached --check` exited 0 before each implementation commit. Explicit
file staging kept the workflow/test and documentation commits separate from
this record.

### Reviews and changed files

Independent specification review followed by code-quality review approved each
task. Review identified two weaknesses in the planned test example: successful
promotion asserted only a digest prefix, and the fixture's preseeded values could
mask missing producer IDs or expression wiring. The same ten tests now assert
the complete expected digest, verifier and promotion outputs, producer IDs, and
all consumed environment bindings. All original assertions remain. Both review
stages approved the bounded additions before the workflow was implemented.

The operator guide also clarifies fail-closed release-state API checks and that
the ordinary GitHub token serves read-only checkout and release-state checks;
registry publication uses `GHCR_TOKEN`. Documentation re-review approved that
accuracy correction. The actual workflow matches the approved YAML.
The independent final overall review found no critical, important, or minor
issues and confirmed the eight-file branch scope, Bash syntax, unchanged
production paths, and execution-record consistency.

This execution changed only:

- `.github/workflows/docker-image.yml`
- `apps/singularity_web/test/singularity/architecture/docker_image_workflow_contract_test.exs`
- `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`
- `README.md`
- `docs/superpowers/plans/2026-08-31-singularity-v0.2-release.md`
- `docs/deployment/docker.md`
- This plan's tracking and evidence record.

The branch additionally contains the previously approved design document. No
released migration, dependency, Dockerfile, existing release workflow,
application source, product phase status, or Vault feature changed. The complete
README product gate remains intact; only its actionlint enumeration changed.

### Limitations and retained gates

This is local workflow policy, syntax, and architecture evidence, not a hosted
multi-platform image build, registry publication, deployment, or product
acceptance. Actual GitHub secret permissions, cross-organization package access,
runner emulation, registry behavior, and real amd64/arm64 builds remain
unverified. No E2E/browser test, complete product verification gate, Vault work,
migration, Git push, merge, tag, workflow dispatch, image publication, GitHub
release, deployment, or worktree deletion occurred. The branch and worktree are
retained; integration and publication require separate authorization.
