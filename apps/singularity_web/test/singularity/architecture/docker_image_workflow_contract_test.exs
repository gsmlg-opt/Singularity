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
    assert checkout["with"]["fetch-depth"] == 0
    assert checkout["with"]["ref"] == "${{ steps.request.outputs.checkout_ref }}"
    assert step!("Validate image request")["id"] == "request"
    assert step!("Resolve image source")["id"] == "source"
    assert step!("Build immutable image content")["id"] == "build"
    assert step!("Verify immutable image digest")["id"] == "verify"
    assert step!("Promote image tags")["id"] == "promote"
    assert step!("Validate image request")["env"]["EVENT_NAME"] == "${{ github.event_name }}"
    assert step!("Validate image request")["env"]["INPUT_TAG"] == "${{ inputs.tag_name }}"
    assert step!("Validate image request")["env"]["INPUT_REF"] == "${{ inputs.git_ref }}"

    assert step!("Validate image request")["env"]["INPUT_LATEST"] ==
             "${{ inputs.generate_latest }}"

    assert step!("Resolve image source")["env"]["EVENT_NAME"] == "${{ github.event_name }}"

    assert step!("Resolve image source")["env"]["CHECKOUT_REF"] ==
             "${{ steps.request.outputs.checkout_ref }}"

    assert step!("Resolve image source")["env"]["EVENT_SHA"] == "${{ github.sha }}"

    assert step!("Verify immutable image digest")["env"]["ACTION_DIGEST"] ==
             "${{ steps.build.outputs.digest }}"

    assert step!("Verify immutable image digest")["env"]["BUILD_METADATA"] ==
             "${{ steps.build.outputs.metadata }}"

    promotion = step!("Promote image tags")["env"]
    assert promotion["EVENT_NAME"] == "${{ github.event_name }}"
    assert promotion["IMAGE_TAG"] == "${{ steps.request.outputs.image_tag }}"
    assert promotion["LATEST_REQUESTED"] == "${{ steps.request.outputs.latest_requested }}"
    assert promotion["IMAGE_DIGEST"] == "${{ steps.verify.outputs.image_digest }}"
    assert promotion["GH_TOKEN"] == "${{ github.token }}"
    summary = step!("Summarize image publication")["env"]
    assert summary["IMAGE_TAG"] == "${{ steps.request.outputs.image_tag }}"
    assert summary["SOURCE_REVISION"] == "${{ steps.source.outputs.source_revision }}"
    assert summary["IMAGE_DIGEST"] == "${{ steps.verify.outputs.image_digest }}"
    assert summary["LATEST_UPDATED"] == "${{ steps.promote.outputs.latest_updated }}"

    release = YamlElixir.read_from_file!(Path.join(@repo_root, ".github/workflows/release.yml"))
    release_steps = release["jobs"]["release"]["steps"]

    for {image_name, release_name} <- [
          {"Check out image source", "Check out release source"},
          {"Set up QEMU", "Set up QEMU"},
          {"Set up Docker Buildx", "Set up Docker Buildx"},
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
    assert build["cache-to"] == "type=gha,mode=max,scope=docker-image"
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

    for tag <- [
          "",
          "latest",
          "bad/tag",
          "-bad",
          "has space",
          "bad\ninput",
          String.duplicate("a", 129),
          "$(touch forbidden)"
        ] do
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
          %{
            "EVENT_NAME" => "release",
            "CHECKOUT_REF" => "refs/tags/v0.2.0",
            "EVENT_SHA" => String.duplicate("c", 40)
          }
        ] do
      result = run!(["Resolve image source", "Promote image tags"], overrides)
      assert result.status != 0, result.output
      assert result.trace == ""
    end
  end

  test "manual named and latest aliases use the same verified digest" do
    digest =
      "sha256:" <> Base.encode16(:crypto.hash(:sha256, Jason.encode!(manifest!())), case: :lower)

    result =
      run!(["Verify immutable image digest", "Promote image tags", "Summarize image publication"])

    assert result.status == 0, result.output
    assert result.trace =~ "--tag #{@image}:v0.2.0 --tag #{@image}:latest #{@image}@"

    assert result.trace ==
             "buildx imagetools create --tag #{@image}:v0.2.0 --tag #{@image}:latest #{@image}@#{digest}\n"

    assert result.outputs =~ "image_digest=#{digest}\n"
    assert result.outputs =~ "latest_updated=true\n"
    assert result.summary =~ "Source revision: #{@source}"
    assert result.summary =~ "Immutable image: #{@image}@sha256:"
    assert result.summary =~ "Immutable image: #{@image}@#{digest}"
    assert result.summary =~ "Updated latest: true"

    result = run!(["Promote image tags"], %{"LATEST_REQUESTED" => "false"})
    assert result.status == 0, result.output
    assert result.trace =~ "--tag #{@image}:v0.2.0"
    assert result.trace == "buildx imagetools create --tag #{@image}:v0.2.0 #{@image}@#{digest}\n"
    assert result.outputs =~ "latest_updated=false\n"
    refute result.trace =~ ":latest"
  end

  test "release request uses the tag namespace and prereleases disable latest" do
    event = Jason.encode!(%{release: %{tag_name: "v0.2.0", prerelease: true, id: 123}})
    result = run!(["Validate image request"], %{"EVENT_NAME" => "release", "EVENT_JSON" => event})
    assert result.status == 0, result.output
    assert result.outputs =~ "checkout_ref=refs/tags/v0.2.0\n"
    assert result.outputs =~ "latest_requested=false\n"

    result =
      run!(["Promote image tags"], %{"EVENT_NAME" => "release", "LATEST_REQUESTED" => "false"})

    assert result.status == 0, result.output
    refute result.trace =~ ":latest"
    assert result.outputs =~ "latest_updated=false\n"
  end

  test "stable latest is rechecked and API uncertainty stops promotion" do
    result = run!(["Promote image tags"], %{"EVENT_NAME" => "release"})
    assert result.status == 0, result.output
    assert result.trace =~ ":latest"
    assert result.outputs =~ "latest_updated=true\n"

    result =
      run!(["Promote image tags"], %{"EVENT_NAME" => "release", "FIXTURE_LATEST_ID" => "999"})

    assert result.status == 0, result.output
    refute result.trace =~ ":latest"
    assert result.outputs =~ "latest_updated=false\n"

    for overrides <- [%{"FIXTURE_API_FAILURE" => "true"}, %{"FIXTURE_LATEST_ID" => "null"}] do
      result = run!(["Promote image tags"], Map.put(overrides, "EVENT_NAME", "release"))
      assert result.status != 0, result.output
      assert result.trace == ""
    end
  end

  test "metadata and raw digest disagreement prevent promotion" do
    for overrides <- [
          %{"ACTION_DIGEST" => "invalid"},
          %{
            "BUILD_METADATA" =>
              Jason.encode!(%{"containerimage.digest" => "sha256:" <> String.duplicate("0", 64)})
          },
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
      Map.put(index, "manifests", [
        amd,
        arm,
        amd_att,
        arm_att,
        Map.put(amd, "platform", %{"os" => "linux", "architecture" => "s390x"})
      ])
    ]

    for invalid <- invalid_indexes do
      result =
        run!(
          ["Verify immutable image digest", "Promote image tags"],
          %{"MANIFEST_JSON" => Jason.encode!(invalid)}
        )

      assert result.status != 0, result.output
      assert result.trace == ""
    end
  end

  test "all workflow shell snippets have valid Bash syntax" do
    for step <- steps!(), script = step["run"], is_binary(script) do
      assert {"", 0} = System.cmd("bash", ["-n", "-c", script], stderr_to_stdout: true)
    end
  end

  defp workflow!,
    do: YamlElixir.read_from_file!(Path.join(@repo_root, ".github/workflows/docker-image.yml"))

  defp steps!, do: workflow!()["jobs"]["image"]["steps"]

  defp step!(name),
    do: Enum.find(steps!(), &(&1["name"] == name)) || flunk("missing step #{name}")

  defp index!(names, name),
    do: Enum.find_index(names, &(&1 == name)) || flunk("missing step #{name}")

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

      event =
        Map.get(
          overrides,
          "EVENT_JSON",
          Jason.encode!(%{release: %{tag_name: "v0.2.0", prerelease: false, id: 123}})
        )

      File.write!(Path.join(directory, "manifest.json"), manifest)
      File.write!(Path.join(directory, "event.json"), event)
      for name <- ["outputs", "trace", "summary"], do: File.write!(Path.join(directory, name), "")

      environment =
        Map.merge(
          %{
            "PATH" => directory <> ":" <> System.fetch_env!("PATH"),
            "REAL_GIT" => System.find_executable("git"),
            "GITHUB_OUTPUT" => Path.join(directory, "outputs"),
            "GITHUB_STEP_SUMMARY" => Path.join(directory, "summary"),
            "GITHUB_EVENT_PATH" => Path.join(directory, "event.json"),
            "GITHUB_REPOSITORY" => "gsmlg-opt/Singularity",
            "FIXTURE_MANIFEST" => Path.join(directory, "manifest.json"),
            "FIXTURE_TRACE" => Path.join(directory, "trace"),
            "FIXTURE_HEAD_SHA" => @source,
            "FIXTURE_TARGET_SHA" => @source,
            "FIXTURE_LATEST_ID" => "123",
            "EVENT_NAME" => "workflow_dispatch",
            "EVENT_SHA" => @source,
            "INPUT_TAG" => "v0.2.0",
            "INPUT_REF" => "main",
            "INPUT_LATEST" => "true",
            "CHECKOUT_REF" => "main",
            "IMAGE_TAG" => "v0.2.0",
            "IMAGE_NAME" => @image,
            "LATEST_REQUESTED" => "true",
            "IMAGE_DIGEST" => digest,
            "ACTION_DIGEST" => digest,
            "SOURCE_REVISION" => @source,
            "LATEST_UPDATED" => "true",
            "BUILD_METADATA" => Jason.encode!(%{"containerimage.digest" => digest})
          },
          overrides
        )

      script = Enum.map_join(names, "\n", &step!(&1)["run"])

      {output, status} =
        System.cmd("bash", ["-c", script],
          env: Map.to_list(environment),
          cd: directory,
          stderr_to_stdout: true
        )

      %{
        status: status,
        output: output,
        outputs: File.read!(Path.join(directory, "outputs")),
        trace: File.read!(Path.join(directory, "trace")),
        summary: File.read!(Path.join(directory, "summary"))
      }
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

    amd = %{
      "mediaType" => media_type,
      "size" => 100,
      "digest" => digest!("1"),
      "platform" => %{"os" => "linux", "architecture" => "amd64"}
    }

    arm = %{
      "mediaType" => media_type,
      "size" => 100,
      "digest" => digest!("2"),
      "platform" => %{"os" => "linux", "architecture" => "arm64"}
    }

    attestation = fn descriptor, digit ->
      %{
        "mediaType" => media_type,
        "size" => 100,
        "digest" => digest!(digit),
        "platform" => %{"os" => "unknown", "architecture" => "unknown"},
        "annotations" => %{
          "vnd.docker.reference.type" => "attestation-manifest",
          "vnd.docker.reference.digest" => descriptor["digest"]
        }
      }
    end

    %{
      "schemaVersion" => 2,
      "mediaType" => "application/vnd.oci.image.index.v1+json",
      "manifests" => [amd, arm, attestation.(amd, "3"), attestation.(arm, "4")]
    }
  end

  defp digest!(digit), do: "sha256:" <> String.duplicate(digit, 64)
end
