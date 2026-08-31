defmodule Singularity.Architecture.ReleaseContainerContractTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../..", __DIR__)

  @common_action_steps [
    {"Check out repository", "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"},
    {"Install Nix", "cachix/install-nix-action@13d8dd58da0234aa297dedd986986ccb8e7f3e24"},
    {"Configure Cachix", "cachix/cachix-action@5f2d7c5294214f71b873db4b969586b980625e71"}
  ]

  @concurrency %{
    "group" => "${{ github.workflow }}-${{ github.ref }}",
    "cancel-in-progress" => true
  }

  test "root project defines the singularity OTP release" do
    source = read!("mix.exs")

    assert source =~ ~r/releases:\s*releases\(\)/

    releases = root_releases()
    assert [singularity: release] = releases
    assert [singularity_web: :permanent] = Keyword.fetch!(release, :applications)
  end

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

  test "Dockerfile packages the runtime cookie policy without embedding a cookie" do
    dockerfile = read!("Dockerfile")

    assert {rel_offset, _length} = :binary.match(dockerfile, "COPY rel ./rel")

    assert {release_offset, _length} =
             :binary.match(dockerfile, "MIX_ENV=prod mix release singularity")

    assert rel_offset < release_offset

    assert {scrub_offset, _length} =
             :binary.match(
               dockerfile,
               "rm -f _build/prod/rel/singularity/releases/COOKIE"
             )

    assert release_offset < scrub_offset
    assert dockerfile =~ "RELEASE_DISTRIBUTION=none"
    refute dockerfile =~ "RELEASE_COOKIE"
  end

  test "release environment generates an ephemeral cookie unless the operator supplies one" do
    env = read!("rel/env.sh.eex")

    assert env =~ ~S<if [ -z "${RELEASE_COOKIE:-}" ]; then>

    assert env =~
             ~S<RELEASE_COOKIE="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')">

    assert env =~ "export RELEASE_COOKIE"

    assert [~S<RELEASE_COOKIE="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')">] =
             env
             |> String.split("\n")
             |> Enum.map(&String.trim/1)
             |> Enum.filter(&String.starts_with?(&1, "RELEASE_COOKIE="))

    refute env =~ "releases/COOKIE"
    refute env =~ ~r/>>?/
  end

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
    assert destination =~ "close_unsafe_partial(device, Error.new(:invalid))"
  end

  test "Docker build context excludes devenv state" do
    ignored = read!(".dockerignore")

    assert ".devenv/" in String.split(ignored, "\n")
  end

  test "runtime release stays root-owned while runtime state is writable" do
    dockerfile = read!("Dockerfile")

    refute dockerfile =~ "COPY --from=build --chown"
    refute dockerfile =~ ~r/chown[^\n]*\/app/
    refute dockerfile =~ ~r/mkdir[^\n]*\/app/

    assert dockerfile =~ "HOME=/tmp/singularity"
    assert dockerfile =~ "RELEASE_TMP=/tmp/singularity"
    assert dockerfile =~ "ERL_CRASH_DUMP=/tmp/singularity/erl_crash.dump"

    assert dockerfile =~
             "mkdir -p /tmp/singularity /var/lib/singularity/storage /var/lib/singularity/backups"

    assert dockerfile =~
             "chown -R 10001:10001 /tmp/singularity /var/lib/singularity"

    assert dockerfile =~
             "COPY --from=build /app/_build/prod/rel/singularity ./"
  end

  test "Dockerfile uses immutable package sources and pinned installers" do
    dockerfile = read!("Dockerfile")
    {build_stage, runtime_stage} = docker_stages(dockerfile)

    assert build_stage =~ "HEX_HTTP_CONCURRENCY=1"
    assert build_stage =~ "HEX_HTTP_TIMEOUT=120"
    refute runtime_stage =~ "HEX_HTTP_CONCURRENCY"
    refute runtime_stage =~ "HEX_HTTP_TIMEOUT"

    for stage <- [build_stage, runtime_stage] do
      assert {sources_offset, _length} =
               :binary.match(stage, "rm -f /etc/apt/sources.list.d/debian.sources")

      assert {apt_offset, _length} = :binary.match(stage, "apt-get update")
      assert sources_offset < apt_offset

      assert stage =~
               "http://snapshot.debian.org/archive/debian/20260610T000000Z"

      assert stage =~
               "http://snapshot.debian.org/archive/debian-security/20260610T000000Z"

      assert stage =~ "check-valid-until=no"

      assert stage =~
               "signed-by=/usr/share/keyrings/debian-archive-keyring.gpg"

      refute stage =~ "deb.debian.org"
      refute stage =~ "security.debian.org"
    end

    assert build_stage =~ "mix local.hex 2.5.1 --force"

    assert build_stage =~
             "https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3"

    assert build_stage =~
             "0d00494d849fdc521a55142278d1f6ba552954fbd65b80d40df8022f594f05d6c99ed1d731bc263691a04176e11d4c6e126c56ba20dca19c5e42d4ffab2e7e36"

    refute build_stage =~ "mix local.hex --force"
    refute build_stage =~ "mix local.rebar --force"
  end

  test "Docker stages install only required system packages" do
    dockerfile = read!("Dockerfile")
    {build_stage, runtime_stage} = docker_stages(dockerfile)

    assert ["build-essential", "ca-certificates"] = apt_packages(build_stage)

    assert ["ca-certificates", "libstdc++6", "libncurses6", "libssl3t64"] =
             apt_packages(runtime_stage)

    assert runtime_stage =~ "rm -f /usr/bin/openssl"
  end

  test "CI contains exact static checks and no tests or services" do
    ci = workflow!("ci.yml")

    assert ci["on"] == %{"push" => nil, "pull_request" => nil}
    assert ci["permissions"] == %{"contents" => "read"}
    assert ci["concurrency"] == @concurrency
    assert ci["jobs"] |> Map.keys() |> Enum.sort() == ["checks"]

    checks = job!(ci, "checks")
    assert_exact_keys!(checks, ["runs-on", "steps"])
    assert checks["runs-on"] == "ubuntu-latest"

    steps = Map.fetch!(checks, "steps")

    assert Enum.map(steps, &Map.fetch!(&1, "name")) == [
             "Check out repository",
             "Install Nix",
             "Configure Cachix",
             "Install devenv",
             "Restore build caches",
             "Fetch dependencies",
             "Check unused lock entries",
             "Check formatting",
             "Compile without warnings",
             "Install JavaScript dependencies",
             "Verify JavaScript dependencies",
             "Check JavaScript sources",
             "Build browser assets",
             "Check source cycles"
           ]

    assert_action_steps!(steps, "Restore build caches")

    assert_run_steps!(steps, [
      {"Install devenv", "nix profile add nixpkgs#devenv"},
      {"Fetch dependencies", "devenv shell -- mix deps.get"},
      {"Check unused lock entries", "devenv shell -- mix deps.unlock --check-unused"},
      {"Check formatting", "devenv shell -- mix format --check-formatted"},
      {"Compile without warnings", "devenv shell -- mix compile --warnings-as-errors"},
      {"Install JavaScript dependencies",
       "devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen"},
      {"Verify JavaScript dependencies", "devenv shell -- mix npm.verify"},
      {"Check JavaScript sources", "devenv shell -- mix duskmoon_bundler.js.check"},
      {"Build browser assets",
       "devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind"},
      {"Check source cycles", "devenv shell -- mix xref graph --format cycles --fail-above 0"}
    ])

    cache_key = step!(steps, "Restore build caches") |> get_in(["with", "key"])

    assert cache_key ==
             "ci-${{ runner.os }}-${{ hashFiles('mix.lock', 'package-lock.json', 'build/project.exs') }}"

    forbidden =
      ~r/(?:mix test|mix singularity\.test\.|mix npm\.run test:(?:js|e2e)|devenv up|devenv processes wait|bootstrap_roles\.sh|devenv processes down)/

    refute Enum.any?(steps, fn step ->
             run = Map.get(step, "run", "")
             Regex.match?(forbidden, run)
           end)

    assert_upstream_comments!("ci.yml")
  end

  test "test workflow preserves every exact acceptance gate" do
    workflow = workflow!("test.yml")

    assert workflow["on"] == %{
             "push" => %{"branches" => ["main"]},
             "pull_request" => %{"branches" => ["main"]}
           }

    assert workflow["permissions"] == %{"contents" => "read"}
    assert workflow["concurrency"] == @concurrency
    assert workflow["jobs"] |> Map.keys() |> Enum.sort() == ["test"]

    test_job = job!(workflow, "test")
    assert_exact_keys!(test_job, ["runs-on", "steps"])
    assert test_job["runs-on"] == "ubuntu-latest"

    steps = Map.fetch!(test_job, "steps")

    assert Enum.map(steps, &Map.fetch!(&1, "name")) == [
             "Check out repository",
             "Install Nix",
             "Configure Cachix",
             "Install devenv",
             "Restore test caches",
             "Start services",
             "Wait for PostgreSQL",
             "Provision PostgreSQL roles",
             "Fetch dependencies",
             "Run tests",
             "Run isolated PostgreSQL integration tests",
             "Run isolated restore acceptance",
             "Install JavaScript dependencies",
             "Verify JavaScript dependencies",
             "Run JavaScript tests",
             "Build browser assets",
             "Run Chromium acceptance tests",
             "Stop services"
           ]

    assert_action_steps!(steps, "Restore test caches")

    assert_run_steps!(steps, [
      {"Install devenv", "nix profile add nixpkgs#devenv"},
      {"Start services", "devenv up -d"},
      {"Wait for PostgreSQL", "devenv processes wait --timeout 120"},
      {"Provision PostgreSQL roles",
       "devenv shell -- bash apps/singularity_storage/priv/repo/bootstrap_roles.sh"},
      {"Fetch dependencies", "devenv shell -- mix deps.get"},
      {"Run tests", "devenv shell -- mix test"},
      {"Run isolated PostgreSQL integration tests",
       "devenv shell -- mix singularity.test.integration"},
      {"Run isolated restore acceptance", "devenv shell -- mix singularity.test.restore"},
      {"Install JavaScript dependencies",
       "devenv shell -- env NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen"},
      {"Verify JavaScript dependencies", "devenv shell -- mix npm.verify"},
      {"Run JavaScript tests", "devenv shell -- mix npm.run test:js"},
      {"Build browser assets",
       "devenv shell -- mix duskmoon_bundler.build singularity_web --tailwind"},
      {"Run Chromium acceptance tests", "devenv shell -- mix npm.run test:e2e"}
    ])

    cache_key = step!(steps, "Restore test caches") |> get_in(["with", "key"])

    assert cache_key ==
             "test-${{ runner.os }}-${{ hashFiles('mix.lock', 'package-lock.json', 'build/project.exs') }}"

    asset_index = Enum.find_index(steps, &(&1["name"] == "Build browser assets"))
    e2e_index = Enum.find_index(steps, &(&1["name"] == "Run Chromium acceptance tests"))
    assert asset_index < e2e_index

    assert List.last(steps) == %{
             "name" => "Stop services",
             "if" => "always()",
             "run" => "devenv processes down"
           }

    assert_upstream_comments!("test.yml")
  end

  test "release workflow exactly validates, packages, publishes, and tags a release" do
    workflow = workflow!("release.yml")

    assert_exact_keys!(workflow, ["concurrency", "env", "jobs", "name", "on", "permissions"])
    assert workflow["name"] == "Release"

    assert workflow["on"] == %{
             "workflow_dispatch" => %{
               "inputs" => %{
                 "version" => %{
                   "description" => "Release version (for example 1.2.3)",
                   "required" => true,
                   "type" => "string"
                 },
                 "git_ref" => %{
                   "description" => "Git branch to release from",
                   "required" => true,
                   "default" => "main",
                   "type" => "string"
                 }
               }
             }
           }

    assert workflow["permissions"] == %{
             "contents" => "write",
             "packages" => "write",
             "id-token" => "write"
           }

    assert workflow["concurrency"] == %{
             "group" => "${{ github.workflow }}",
             "cancel-in-progress" => false
           }

    assert workflow["env"] == %{"IMAGE_NAME" => "ghcr.io/gsmlg-dev/singularity"}
    assert workflow["jobs"] |> Map.keys() == ["release"]

    release_job = job!(workflow, "release")
    assert_exact_keys!(release_job, ["runs-on", "steps", "timeout-minutes"])
    assert release_job["runs-on"] == "ubuntu-latest"
    assert release_job["timeout-minutes"] == 120
    assert release_job["steps"] == release_steps()

    steps = release_job["steps"]

    build_index = Enum.find_index(steps, &(&1["name"] == "Build immutable release content"))
    source_index = Enum.find_index(steps, &(&1["name"] == "Publish source branch and tag"))
    promote_index = Enum.find_index(steps, &(&1["name"] == "Promote immutable image digest"))

    assert build_index < source_index
    assert source_index < promote_index

    refute Enum.any?(steps, &Map.has_key?(&1, "continue-on-error"))
    refute Enum.any?(steps, &Map.has_key?(&1, "if"))

    login = step!(steps, "Log in to GHCR")
    assert login["with"]["username"] == "${{ github.actor }}"
    assert login["with"]["password"] == "${{ secrets.GHCR_TOKEN }}"

    preparation_run = step!(steps, "Prepare release source")["run"]
    assert preparation_run =~ ~S<RELEASE_MODE=resume>
    assert preparation_run =~ ~S<RELEASE_MODE=new>
    assert preparation_run =~ ~S<git commit -m "chore(release): v${RELEASE_VERSION}">
    assert preparation_run =~ ~S<git tag -a "$RELEASE_TAG">
    assert preparation_run =~ ~S<echo "RELEASE_REF=$RELEASE_REF">
    assert preparation_run =~ ~S<echo "SOURCE_REVISION=$SOURCE_REVISION">

    assert preparation_run =~
             ~S<git merge-base --is-ancestor "$tag_source_revision" "refs/remotes/origin/$RELEASE_REF">

    assert preparation_run =~ ~S<git checkout --detach "$tag_source_revision">
    refute preparation_run =~ ~S<"$tag_source_revision" != "$remote_branch_sha">
    assert preparation_run =~ ~S<sort -V>
    assert preparation_run =~ ~S<"$RELEASE_VERSION" != "$highest_version">
    assert preparation_run =~ ~S<release already complete>
    assert preparation_run =~ ~S<gh api --include>
    assert preparation_run =~ ~S<"repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG">
    assert preparation_run =~ ~S<"404")>
    assert preparation_run =~ ~S<release API request failed>
    refute preparation_run =~ ~S<if gh release view>
    assert preparation_run =~ ~S<grep -Fxq "$archive_name">
    assert preparation_run =~ ~S<grep -Fxq "$checksum_name">

    assert preparation_run =~
             ~S<if [[ "$canonical_candidate" != "$RELEASE_VERSION" ]]; then>

    assert preparation_run =~
             ~S<new release version must not be lower than the canonical Mix version>

    assert preparation_run =~
             ~S<if [[ "$RELEASE_VERSION" != "$current_version" ]]; then>

    refute preparation_run =~ ~S<"$RELEASE_VERSION" == "$current_version">

    assert {identity_offset, _length} =
             :binary.match(preparation_run, "git config user.name github-actions[bot]")

    assert {bump_offset, _length} =
             :binary.match(
               preparation_run,
               ~S<if [[ "$RELEASE_VERSION" != "$current_version" ]]; then>
             )

    assert {tag_offset, _length} =
             :binary.match(preparation_run, ~S<git tag -a "$RELEASE_TAG">)

    assert identity_offset < bump_offset
    assert identity_offset < tag_offset

    metadata_labels = step!(steps, "Generate image metadata") |> get_in(["with", "labels"])
    assert metadata_labels =~ "org.opencontainers.image.revision=${{ env.SOURCE_REVISION }}"
    refute metadata_labels =~ "${{ github.sha }}"

    assert 1 ==
             workflow
             |> inspect(limit: :infinity)
             |> then(&Regex.scan(~r/secrets\.GHCR_TOKEN/, &1))
             |> length()

    for step <- steps, step["name"] != "Log in to GHCR" do
      refute inspect(step, limit: :infinity) =~ "secrets.GHCR_TOKEN"
    end

    build_steps =
      Enum.filter(
        steps,
        &String.starts_with?(Map.get(&1, "uses", ""), "docker/build-push-action@")
      )

    assert [build_step] = build_steps
    assert build_step["id"] == "build"
    refute Map.has_key?(build_step["with"], "tags")
    refute Map.has_key?(build_step["with"], "push")

    assert build_step["with"]["outputs"] ==
             "type=oci,dest=${{ env.OCI_ARCHIVE }}\ntype=image,name=${{ env.IMAGE_NAME }},push-by-digest=true,name-canonical=true,push=true,oci-mediatypes=true\n"

    build_args = build_step["with"]["build-args"]
    refute build_args =~ ~r/token/i
    assert build_args =~ "REVISION=${{ env.SOURCE_REVISION }}"
    refute build_args =~ "${{ github.sha }}"

    metadata = step!(steps, "Generate image metadata")
    refute Map.has_key?(metadata["with"], "tags")

    digest_run = step!(steps, "Verify immutable image digest")["run"]
    assert digest_run =~ ~S<jq -r '."containerimage.digest" // empty'>
    assert digest_run =~ "build action digest ("
    assert digest_run =~ "did not match build metadata digest ("

    assert digest_run =~
             ~S<docker buildx imagetools inspect "$IMAGE_NAME@$ACTION_DIGEST" --raw>

    assert digest_run =~ "immutable registry raw manifest digest ("
    assert digest_run =~ "did not match build action digest ("
    assert digest_run =~ ~S<tar -xOf "$OCI_ARCHIVE" index.json>
    assert digest_run =~ "expected exactly one OCI root descriptor"

    assert digest_run =~
             "OCI root descriptor must provide OCI image-index media type, a sha256 digest, and positive integer size"

    assert digest_run =~ ~S<oci_root_blob="$(mktemp)">
    assert digest_run =~ ~S<trap 'rm -f "$registry_root_blob" "${oci_root_blob:-}"' EXIT>

    assert digest_run =~
             ~S|tar -xOf "$OCI_ARCHIVE" "blobs/sha256/$oci_root_hex" > "$oci_root_blob"|

    assert digest_run =~ "OCI root blob digest ("
    assert digest_run =~ "OCI root blob size ("
    assert digest_run =~ "required_platform_descriptors()"
    assert digest_run =~ "jq -Sce"
    assert digest_run =~ "root index must have schemaVersion 2 and OCI image-index media type"
    assert digest_run =~ "unexpected descriptor platform"
    assert digest_run =~ "missing a platform object"
    assert digest_run =~ "{mediaType, size, digest, platform}"
    assert digest_run =~ "application/vnd.oci.image.manifest.v1+json"
    assert digest_run =~ "linux/amd64"
    assert digest_run =~ "linux/arm64"
    assert digest_run =~ "registry and OCI runnable platform descriptors differ"
    assert digest_run =~ "diff -u"
    refute digest_run =~ ~S<test "$oci_root_digest" = "$resolved_digest">

    source_run = step!(steps, "Publish source branch and tag")["run"]
    assert source_run =~ ~S<if [[ "$RELEASE_MODE" == "new" ]]; then>
    assert source_run =~ ~S<test "$remote_branch_sha" = "$RELEASE_PARENT_SHA">

    assert source_run =~
             ~S<git push --atomic origin "HEAD:refs/heads/$RELEASE_REF" "refs/tags/$RELEASE_TAG">

    assert source_run =~ ~S<elif [[ "$RELEASE_MODE" != "resume" ]]; then>
    assert source_run =~ ~S<competing release tag appeared before source publication>
    assert source_run =~ ~S<release tag is no longer the highest semver tag>

    promote_run = step!(steps, "Promote immutable image digest")["run"]
    assert promote_run =~ ~S<"$IMAGE_NAME@$IMAGE_DIGEST">
    assert promote_run =~ ~S<--tag "$IMAGE_NAME:$VERSION">
    assert promote_run =~ ~S<--tag "$IMAGE_NAME:$MINOR_VERSION">
    assert promote_run =~ ~S<--tag "$IMAGE_NAME:latest">

    steps
    |> Enum.take(promote_index)
    |> Enum.each(fn step ->
      refute inspect(step, limit: :infinity) =~
               ~r/\$IMAGE_NAME:(?:\$VERSION|\$MINOR_VERSION|latest)/
    end)

    release_run = step!(steps, "Create GitHub Release")["run"]
    assert release_run =~ ~S<archive_dir=$(dirname "$OCI_ARCHIVE")>
    assert release_run =~ ~S<archive_name=$(basename "$OCI_ARCHIVE")>

    assert release_run =~
             ~S|(cd "$archive_dir" && sha256sum "$archive_name" > "$archive_name.sha256")|

    refute release_run =~ ~S<sha256sum "$OCI_ARCHIVE">
    assert release_run =~ ~S<gh release view "$RELEASE_TAG">
    assert release_run =~ ~S<gh release upload "$RELEASE_TAG">
    assert release_run =~ "--clobber"
    assert release_run =~ ~S<gh release create "$RELEASE_TAG">
    assert release_run =~ "--generate-notes"

    refute File.exists?(Path.join([@repo_root, ".github", "workflows", "e2e.yml"]))
  end

  test "release verification executes the parsed runnable descriptor classifier" do
    amd64 = descriptor("amd64", "a")
    arm64 = descriptor("arm64", "b")
    unknown_attestation = descriptor("unknown", "unknown", "c")
    amd64_attestation = attestation(amd64, "c")
    arm64_attestation = attestation(arm64, "d")

    valid_registry = oci_index([amd64, arm64, amd64_attestation, arm64_attestation])

    valid_oci =
      oci_index([attestation(arm64, "e"), arm64, attestation(amd64, "f"), amd64])

    assert {0, registry_descriptors} = required_platform_descriptors(valid_registry)
    assert {0, oci_descriptors} = required_platform_descriptors(valid_oci)
    assert registry_descriptors == oci_descriptors

    changed_amd64 = put_in(amd64, ["digest"], digest("e"))

    assert {0, changed_amd64_descriptors} =
             required_platform_descriptors(
               oci_index([
                 changed_amd64,
                 arm64,
                 attestation(changed_amd64, "f"),
                 arm64_attestation
               ])
             )

    refute registry_descriptors == changed_amd64_descriptors

    changed_platform = put_in(amd64, ["platform", "variant"], "v3")

    assert {0, changed_platform_descriptors} =
             required_platform_descriptors(
               oci_index([changed_platform, arm64, amd64_attestation, arm64_attestation])
             )

    refute registry_descriptors == changed_platform_descriptors

    invalid_indexes = [
      {"extra runnable platform",
       oci_index([amd64, arm64, descriptor("s390x", "e"), amd64_attestation, arm64_attestation]),
       "unexpected descriptor platform"},
      {"missing platform",
       oci_index([amd64, arm64, Map.delete(amd64_attestation, "platform"), arm64_attestation]),
       "missing a platform object"},
      {"malformed unknown attestation",
       oci_index([amd64, arm64, put_in(amd64_attestation, ["size"], 0), arm64_attestation]),
       "must have OCI image-manifest media type"},
      {"bare unknown platform",
       oci_index([amd64, arm64, unknown_attestation, amd64_attestation, arm64_attestation]),
       "unknown/unknown descriptor must be an attestation manifest"},
      {"wrong reference type",
       oci_index([
         amd64,
         arm64,
         put_in(amd64_attestation, ["annotations", "vnd.docker.reference.type"], "other"),
         arm64_attestation
       ]), "unknown/unknown descriptor must be an attestation manifest"},
      {"malformed reference digest",
       oci_index([
         amd64,
         arm64,
         put_in(amd64_attestation, ["annotations", "vnd.docker.reference.digest"], "invalid"),
         arm64_attestation
       ]), "unknown/unknown descriptor must be an attestation manifest"},
      {"unknown attestation reference",
       oci_index([
         amd64,
         arm64,
         put_in(amd64_attestation, ["annotations", "vnd.docker.reference.digest"], digest("f")),
         arm64_attestation
       ]), "attestation references must match required runnable digests"},
      {"duplicate and missing attestation linkage",
       oci_index([amd64, arm64, amd64_attestation, attestation(amd64, "e")]),
       "attestation references must match required runnable digests"},
      {"Docker manifest-list root",
       oci_index([amd64, arm64, amd64_attestation, arm64_attestation], %{
         "mediaType" => "application/vnd.docker.distribution.manifest.list.v2+json"
       }), "root index must have schemaVersion 2 and OCI image-index media type"},
      {"wrong schema version",
       oci_index([amd64, arm64, amd64_attestation, arm64_attestation], %{"schemaVersion" => 1}),
       "root index must have schemaVersion 2 and OCI image-index media type"}
    ]

    for {name, index, diagnostic} <- invalid_indexes do
      assert {exit_status, output} = required_platform_descriptors(index), name
      assert exit_status != 0, name
      assert output =~ diagnostic, "#{name}: #{output}"
    end
  end

  defp release_steps do
    [
      %{
        "name" => "Check out release source",
        "uses" => "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
        "with" => %{"fetch-depth" => 0, "ref" => "${{ inputs.git_ref }}"}
      },
      %{
        "name" => "Set up Elixir and Erlang",
        "uses" => "erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124",
        "with" => %{"elixir-version" => "1.18.4", "otp-version" => "28.4.3"}
      },
      %{
        "name" => "Restore release caches",
        "uses" => "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
        "with" => %{
          "path" => "deps\n_build\nnode_modules\n~/.hex\n~/.mix\n~/.cache/rustler_precompiled\n",
          "key" =>
            "release-${{ runner.os }}-${{ hashFiles('mix.lock', 'package-lock.json', 'build/project.exs') }}"
        }
      },
      %{
        "name" => "Prepare release source",
        "shell" => "bash",
        "env" => %{
          "GH_TOKEN" => "${{ github.token }}",
          "RELEASE_REF" => "${{ inputs.git_ref }}",
          "RELEASE_VERSION" => "${{ inputs.version }}"
        },
        "run" => prepare_release_source_run()
      },
      %{
        "name" => "Install pinned Hex and Rebar",
        "shell" => "bash",
        "run" => install_release_tools_run()
      },
      %{
        "name" => "Build the OTP release artifact",
        "shell" => "bash",
        "run" => build_release_run()
      },
      %{
        "name" => "Set up QEMU",
        "uses" => "docker/setup-qemu-action@96fe6ef7f33517b61c61be40b68a1882f3264fb8",
        "with" => %{
          "image" =>
            "docker.io/tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0",
          "platforms" => "arm64"
        }
      },
      %{
        "name" => "Set up Docker Buildx",
        "uses" => "docker/setup-buildx-action@37fe631027851001ddb9b187196cc803df7f5f0e",
        "with" => %{
          "version" => "v0.36.1",
          "driver-opts" =>
            "image=moby/buildkit:v0.32.2@sha256:28a898719c18a33f4e8000685287fa36fd0dd9560c6440227d3a732d79bb41d8"
        }
      },
      %{
        "name" => "Log in to GHCR",
        "uses" => "docker/login-action@dbcb813823bdd20940b903addbd779551569679f",
        "with" => %{
          "registry" => "ghcr.io",
          "username" => "${{ github.actor }}",
          "password" => "${{ secrets.GHCR_TOKEN }}"
        }
      },
      %{
        "name" => "Generate image metadata",
        "id" => "metadata",
        "uses" => "docker/metadata-action@dc802804100637a589fabce1cb79ff13a1411302",
        "with" => %{
          "images" => "${{ env.IMAGE_NAME }}",
          "labels" =>
            "org.opencontainers.image.version=${{ env.VERSION }}\norg.opencontainers.image.revision=${{ env.SOURCE_REVISION }}\norg.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}\n"
        }
      },
      %{
        "name" => "Build immutable release content",
        "id" => "build",
        "uses" => "docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a",
        "with" => %{
          "context" => ".",
          "file" => "Dockerfile",
          "platforms" => "linux/amd64,linux/arm64",
          "outputs" =>
            "type=oci,dest=${{ env.OCI_ARCHIVE }}\ntype=image,name=${{ env.IMAGE_NAME }},push-by-digest=true,name-canonical=true,push=true,oci-mediatypes=true\n",
          "labels" => "${{ steps.metadata.outputs.labels }}",
          "build-args" => "VERSION=${{ env.VERSION }}\nREVISION=${{ env.SOURCE_REVISION }}\n",
          "cache-from" => "type=gha,scope=release",
          "cache-to" => "type=gha,mode=max,scope=release",
          "provenance" => "mode=max",
          "sbom" => true
        }
      },
      %{
        "name" => "Verify immutable image digest",
        "shell" => "bash",
        "env" => %{
          "ACTION_DIGEST" => "${{ steps.build.outputs.digest }}",
          "BUILD_METADATA" => "${{ steps.build.outputs.metadata }}"
        },
        "run" => verify_image_digest_run()
      },
      %{
        "name" => "Publish source branch and tag",
        "shell" => "bash",
        "run" => publish_source_run()
      },
      %{
        "name" => "Promote immutable image digest",
        "shell" => "bash",
        "run" => promote_image_run()
      },
      %{
        "name" => "Create GitHub Release",
        "shell" => "bash",
        "env" => %{"GH_TOKEN" => "${{ github.token }}"},
        "run" => create_github_release_run()
      }
    ]
  end

  defp prepare_release_source_run do
    ~S"""
    set -euo pipefail
    if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "version must use X.Y.Z" >&2
      exit 1
    fi
    git check-ref-format "refs/heads/$RELEASE_REF"
    remote_branch_sha="$(git ls-remote --exit-code --heads origin "refs/heads/$RELEASE_REF" | cut -f1)"
    test "$(git rev-parse HEAD)" = "$remote_branch_sha"
    git fetch --force --no-tags origin "refs/heads/$RELEASE_REF:refs/remotes/origin/$RELEASE_REF"
    test "$(git rev-parse "refs/remotes/origin/$RELEASE_REF")" = "$remote_branch_sha"
    RELEASE_TAG="v$RELEASE_VERSION"
    highest_version="$(
      git ls-remote --tags --refs origin 'refs/tags/v*' |
        sed -nE 's#^.*refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$#\1#p' |
        sort -V |
        tail -n 1
    )"
    archive_name="singularity-v$RELEASE_VERSION-linux-amd64-arm64.oci.tar"
    checksum_name="$archive_name.sha256"
    read_root_version() {
      python3 <<'PY'
    import pathlib
    import re

    path = pathlib.Path("mix.exs")
    source = path.read_text()
    match = re.search(r'(?m)^\s*version:\s*"([^"]+)",$', source)
    if match is None:
        raise SystemExit("canonical Mix version was not found")
    print(match.group(1))
    PY
    }
    if git ls-remote --exit-code --tags origin "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
      if [[ "$RELEASE_VERSION" != "$highest_version" ]]; then
        echo "only the highest release tag may be resumed" >&2
        exit 1
      fi
      git fetch --force origin "+refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG"
      tag_source_revision="$(git rev-list -n 1 "$RELEASE_TAG")"
      if ! git merge-base --is-ancestor "$tag_source_revision" "refs/remotes/origin/$RELEASE_REF"; then
        echo "release tag is not in the release branch history" >&2
        exit 1
      fi
      git checkout --detach "$tag_source_revision"
      current_version="$(read_root_version)"
      if [[ "$current_version" != "$RELEASE_VERSION" ]]; then
        echo "release tag version does not match the canonical Mix version" >&2
        exit 1
      fi
      release_response_file="$(mktemp)"
      if gh api --include "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG" \
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
      case "$release_http_status" in
        "200")
          if (( release_api_exit != 0 )); then
            echo "release API returned HTTP 200 with a failing exit status" >&2
            rm -f "$release_response_file"
            exit 1
          fi
          release_asset_names="$(
            sed -n '/^{/,$p' "$release_response_file" | jq -r '.assets[]?.name'
          )"
          if grep -Fxq "$archive_name" <<< "$release_asset_names" &&
              grep -Fxq "$checksum_name" <<< "$release_asset_names"; then
            echo "release already complete" >&2
            rm -f "$release_response_file"
            exit 1
          fi
          ;;
        "404")
          ;;
        *)
          echo "release API request failed (HTTP ${release_http_status:-none}, exit $release_api_exit)" >&2
          rm -f "$release_response_file"
          exit 1
          ;;
      esac
      rm -f "$release_response_file"
      RELEASE_MODE=resume
      SOURCE_REVISION="$tag_source_revision"
    else
      if [[ -n "$highest_version" ]]; then
        newest_candidate="$(printf '%s\n%s\n' "$highest_version" "$RELEASE_VERSION" | sort -V | tail -n 1)"
        if [[ "$newest_candidate" != "$RELEASE_VERSION" || "$RELEASE_VERSION" == "$highest_version" ]]; then
          echo "new release version must be higher than every existing release tag" >&2
          exit 1
        fi
      fi
      current_version="$(read_root_version)"
      canonical_candidate="$(printf '%s\n%s\n' "$current_version" "$RELEASE_VERSION" | sort -V | tail -n 1)"
      if [[ "$canonical_candidate" != "$RELEASE_VERSION" ]]; then
        echo "new release version must not be lower than the canonical Mix version" >&2
        exit 1
      fi
      git config user.name github-actions[bot]
      git config user.email 41898282+github-actions[bot]@users.noreply.github.com
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
        git add mix.exs
        git commit -m "chore(release): v${RELEASE_VERSION}"
      fi
      git tag -a "$RELEASE_TAG" -m "Singularity $RELEASE_TAG"
      RELEASE_MODE=new
      SOURCE_REVISION="$(git rev-parse HEAD)"
    fi
    test "$(git rev-parse HEAD)" = "$SOURCE_REVISION"
    {
      echo "VERSION=$RELEASE_VERSION"
      echo "MINOR_VERSION=${RELEASE_VERSION%.*}"
      echo "RELEASE_TAG=$RELEASE_TAG"
      echo "OCI_ARCHIVE=/tmp/singularity-v$RELEASE_VERSION-linux-amd64-arm64.oci.tar"
      echo "RELEASE_MODE=$RELEASE_MODE"
      echo "RELEASE_PARENT_SHA=$remote_branch_sha"
      echo "RELEASE_REF=$RELEASE_REF"
      echo "SOURCE_REVISION=$SOURCE_REVISION"
    } >> "$GITHUB_ENV"
    """
  end

  defp install_release_tools_run do
    ~S"""
    set -euo pipefail
    mix local.hex 2.5.1 --force
    mix local.rebar rebar3 \
      https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3 \
      --sha512 0d00494d849fdc521a55142278d1f6ba552954fbd65b80d40df8022f594f05d6c99ed1d731bc263691a04176e11d4c6e126c56ba20dca19c5e42d4ffab2e7e36 \
      --force
    """
  end

  defp build_release_run do
    ~S"""
    set -euo pipefail
    test "$(git rev-parse HEAD)" = "$SOURCE_REVISION"
    git diff --quiet
    MIX_ENV=prod mix deps.get --only prod
    NPM_EX_LINK_STRATEGY=copy MIX_ENV=prod mix npm.install --frozen
    MIX_ENV=prod mix npm.verify
    MIX_ENV=prod mix compile --warnings-as-errors
    MIX_ENV=prod mix assets.deploy
    MIX_ENV=prod mix release singularity --overwrite
    test -x _build/prod/rel/singularity/bin/singularity
    """
  end

  defp verify_image_digest_run do
    ~S"""
    set -euo pipefail
    required_platform_descriptors() {
      jq -Sce '
        def positive_integer:
          type == "number" and . > 0 and floor == .;
        def sha256_digest:
          type == "string" and test("^sha256:[0-9a-f]{64}$");
        def valid_descriptor:
          if type != "object" then
            error("image index descriptor must be an object")
          elif
            .mediaType != "application/vnd.oci.image.manifest.v1+json" or
              (.size | positive_integer | not) or
              (.digest | sha256_digest | not)
          then
            error("image index descriptor must have OCI image-manifest media type, positive integer size, and lowercase sha256 digest")
          else .
          end;
        def descriptor_kind:
          if (.platform | type) != "object" then
            error("image index descriptor is missing a platform object")
          elif
            (.platform.os | type) != "string" or
              (.platform.architecture | type) != "string"
          then
            error("image index descriptor has a malformed platform object")
          elif
            .platform.os == "linux" and
              (.platform.architecture == "amd64" or .platform.architecture == "arm64")
          then {kind: "runnable"}
          elif
            .platform.os == "unknown" and
              .platform.architecture == "unknown"
          then
            if
              ((.platform | keys | sort) == ["architecture", "os"]) and
                (.annotations | type) == "object" and
                .annotations["vnd.docker.reference.type"] == "attestation-manifest" and
                (.annotations["vnd.docker.reference.digest"] | sha256_digest)
            then {
              kind: "attestation",
              reference_digest: .annotations["vnd.docker.reference.digest"]
            }
            else error("unknown/unknown descriptor must be an attestation manifest with a valid runnable reference digest")
            end
          else
            error("unexpected descriptor platform \(.platform.os)/\(.platform.architecture)")
          end;
        if
          .schemaVersion == 2 and
            .mediaType == "application/vnd.oci.image.index.v1+json"
        then .
        else error("root index must have schemaVersion 2 and OCI image-index media type")
        end
        | if (.manifests | type) != "array" then
            error("image index must contain a manifests array")
          else .manifests
          end
        | map(
            . as $descriptor
            | valid_descriptor
            | descriptor_kind as $kind
            | $kind + {descriptor: $descriptor}
          )
        | . as $classified
        | [.[] | select(.kind == "runnable") | .descriptor | {mediaType, size, digest, platform}]
        | sort_by(.platform.os, .platform.architecture)
        | if length != 2 then
            error("expected exactly linux/amd64 and linux/arm64 runnable descriptors")
          elif (map(.platform | "\(.os)/\(.architecture)") | unique | sort) != ["linux/amd64", "linux/arm64"] then
            error("expected exactly one descriptor for each required runnable platform")
          else .
          end
        | . as $runnable_descriptors
        | [$classified[] | select(.kind == "attestation") | .reference_digest] | sort
        | if . == ($runnable_descriptors | map(.digest) | sort) then
            $runnable_descriptors
          else error("attestation references must match required runnable digests exactly once each")
          end
      '
    }

    metadata_digest="$(jq -r '."containerimage.digest" // empty' <<< "$BUILD_METADATA")"
    if [[ ! "$ACTION_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "build action did not return a valid image digest" >&2
      exit 1
    fi
    if [[ ! "$metadata_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "build metadata did not contain a valid image digest" >&2
      exit 1
    fi
    if [[ "$ACTION_DIGEST" != "$metadata_digest" ]]; then
      echo "build action digest ($ACTION_DIGEST) did not match build metadata digest ($metadata_digest)" >&2
      exit 1
    fi

    registry_root_blob="$(mktemp)"
    oci_root_blob=""
    trap 'rm -f "$registry_root_blob" "${oci_root_blob:-}"' EXIT
    oci_root_blob="$(mktemp)"
    docker buildx imagetools inspect "$IMAGE_NAME@$ACTION_DIGEST" --raw > "$registry_root_blob"
    resolved_digest="sha256:$(sha256sum "$registry_root_blob" | cut -d ' ' -f1)"
    if [[ "$ACTION_DIGEST" != "$resolved_digest" ]]; then
      echo "immutable registry raw manifest digest ($resolved_digest) did not match build action digest ($ACTION_DIGEST)" >&2
      exit 1
    fi

    oci_index="$(tar -xOf "$OCI_ARCHIVE" index.json)"
    oci_root_descriptor="$(
      jq -Sce '
        if (.manifests | type) != "array" or (.manifests | length) != 1 then
          error("expected exactly one OCI root descriptor")
        else
          .manifests[0] | {mediaType, digest, size}
        end
        | if
            (.mediaType == "application/vnd.oci.image.index.v1+json" and
              (.digest | if type == "string" then test("^sha256:[0-9a-f]{64}$") else false end) and
              (.size | (type == "number" and . > 0 and floor == .)))
          then .
          else error("OCI root descriptor must provide OCI image-index media type, a sha256 digest, and positive integer size")
          end
      ' <<< "$oci_index"
    )"
    oci_root_digest="$(jq -er '.digest' <<< "$oci_root_descriptor")"
    oci_root_size="$(jq -er '.size' <<< "$oci_root_descriptor")"
    oci_root_hex="${oci_root_digest#sha256:}"
    tar -xOf "$OCI_ARCHIVE" "blobs/sha256/$oci_root_hex" > "$oci_root_blob"
    oci_blob_digest="sha256:$(sha256sum "$oci_root_blob" | cut -d ' ' -f1)"
    oci_blob_size="$(wc -c < "$oci_root_blob" | tr -d ' ')"
    if [[ "$oci_root_digest" != "$oci_blob_digest" ]]; then
      echo "OCI root blob digest ($oci_blob_digest) did not match index digest ($oci_root_digest)" >&2
      exit 1
    fi
    if [[ "$oci_root_size" != "$oci_blob_size" ]]; then
      echo "OCI root blob size ($oci_blob_size) did not match index size ($oci_root_size)" >&2
      exit 1
    fi

    registry_platform_descriptors="$(required_platform_descriptors < "$registry_root_blob")"
    oci_platform_descriptors="$(required_platform_descriptors < "$oci_root_blob")"
    if [[ "$registry_platform_descriptors" != "$oci_platform_descriptors" ]]; then
      echo "registry and OCI runnable platform descriptors differ" >&2
      diff -u \
        <(jq . <<< "$registry_platform_descriptors") \
        <(jq . <<< "$oci_platform_descriptors") >&2 || true
      exit 1
    fi

    echo "IMAGE_DIGEST=$resolved_digest" >> "$GITHUB_ENV"
    """
  end

  defp publish_source_run do
    ~S"""
    set -euo pipefail
    if [[ "$RELEASE_MODE" == "new" ]]; then
      remote_branch_sha="$(git ls-remote --exit-code --heads origin "refs/heads/$RELEASE_REF" | cut -f1)"
      test "$remote_branch_sha" = "$RELEASE_PARENT_SHA"
      prepush_highest_version="$(
        git ls-remote --tags --refs origin 'refs/tags/v*' |
          sed -nE 's#^.*refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$#\1#p' |
          sort -V |
          tail -n 1
      )"
      if [[ -n "$prepush_highest_version" ]]; then
        prepush_candidate="$(printf '%s\n%s\n' "$prepush_highest_version" "$VERSION" | sort -V | tail -n 1)"
        if [[ "$prepush_candidate" != "$VERSION" || "$VERSION" == "$prepush_highest_version" ]]; then
          echo "competing release tag appeared before source publication" >&2
          exit 1
        fi
      fi
      git push --atomic origin "HEAD:refs/heads/$RELEASE_REF" "refs/tags/$RELEASE_TAG"
    elif [[ "$RELEASE_MODE" != "resume" ]]; then
      echo "unknown release mode" >&2
      exit 1
    fi
    remote_tag_revision="$(git ls-remote --exit-code origin "refs/tags/$RELEASE_TAG" "refs/tags/$RELEASE_TAG^{}" | tail -n 1 | cut -f1)"
    test "$remote_tag_revision" = "$SOURCE_REVISION"
    latest_remote_version="$(
      git ls-remote --tags --refs origin 'refs/tags/v*' |
        sed -nE 's#^.*refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$#\1#p' |
        sort -V |
        tail -n 1
    )"
    if [[ "$latest_remote_version" != "$VERSION" ]]; then
      echo "release tag is no longer the highest semver tag" >&2
      exit 1
    fi
    """
  end

  defp promote_image_run do
    ~S"""
    set -euo pipefail
    if [[ ! "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "invalid immutable image digest" >&2
      exit 1
    fi
    docker buildx imagetools create \
      --tag "$IMAGE_NAME:$VERSION" \
      --tag "$IMAGE_NAME:$MINOR_VERSION" \
      --tag "$IMAGE_NAME:latest" \
      "$IMAGE_NAME@$IMAGE_DIGEST"
    """
  end

  defp create_github_release_run do
    ~S"""
    set -euo pipefail
    archive_dir=$(dirname "$OCI_ARCHIVE")
    archive_name=$(basename "$OCI_ARCHIVE")
    (cd "$archive_dir" && sha256sum "$archive_name" > "$archive_name.sha256")
    if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
      gh release upload "$RELEASE_TAG" \
        "$OCI_ARCHIVE" \
        "$OCI_ARCHIVE.sha256" \
        --clobber
    else
      gh release create "$RELEASE_TAG" \
        "$OCI_ARCHIVE" \
        "$OCI_ARCHIVE.sha256" \
        --title "Singularity $RELEASE_TAG" \
        --generate-notes \
        --verify-tag
    fi
    """
  end

  defp workflow!(name) do
    YamlElixir.read_from_file!(Path.join([@repo_root, ".github", "workflows", name]))
  end

  defp required_platform_descriptors(index) do
    run =
      workflow!("release.yml")
      |> job!("release")
      |> Map.fetch!("steps")
      |> step!("Verify immutable image digest")
      |> Map.fetch!("run")

    [function] = Regex.run(~r/^required_platform_descriptors\(\) \{\n.*?^\}/ms, run)

    System.cmd(
      "bash",
      ["-ceu", function <> "\nprintf %s \"$INDEX\" | required_platform_descriptors"],
      env: [{"INDEX", Jason.encode!(index)}],
      stderr_to_stdout: true
    )
    |> then(fn {output, exit_status} -> {exit_status, output} end)
  end

  defp oci_index(manifests, overrides \\ %{}) do
    Map.merge(
      %{
        "schemaVersion" => 2,
        "mediaType" => "application/vnd.oci.image.index.v1+json",
        "manifests" => manifests
      },
      overrides
    )
  end

  defp descriptor(architecture, digest_character) do
    %{
      "mediaType" => "application/vnd.oci.image.manifest.v1+json",
      "size" => 100,
      "digest" => digest(digest_character),
      "platform" => %{"os" => "linux", "architecture" => architecture}
    }
  end

  defp descriptor(os, architecture, digest_character) do
    %{
      "mediaType" => "application/vnd.oci.image.manifest.v1+json",
      "size" => 100,
      "digest" => digest(digest_character),
      "platform" => %{"os" => os, "architecture" => architecture}
    }
  end

  defp attestation(runnable_descriptor, digest_character) do
    %{
      "mediaType" => "application/vnd.oci.image.manifest.v1+json",
      "size" => 1112,
      "digest" => digest(digest_character),
      "annotations" => %{
        "vnd.docker.reference.digest" => runnable_descriptor["digest"],
        "vnd.docker.reference.type" => "attestation-manifest"
      },
      "platform" => %{"os" => "unknown", "architecture" => "unknown"}
    }
  end

  defp digest(character), do: "sha256:" <> String.duplicate(character, 64)

  defp job!(workflow, name) do
    workflow
    |> Map.fetch!("jobs")
    |> Map.fetch!(name)
  end

  defp step!(steps, name) do
    case Enum.filter(steps, &(&1["name"] == name)) do
      [step] -> step
      [] -> flunk("workflow step #{inspect(name)} is missing")
      matches -> flunk("workflow step #{inspect(name)} appears #{length(matches)} times")
    end
  end

  defp assert_action_steps!(steps, cache_name) do
    for {name, uses} <- @common_action_steps do
      step = step!(steps, name)

      expected_keys =
        if name == "Configure Cachix", do: ["name", "uses", "with"], else: ["name", "uses"]

      assert_exact_keys!(step, expected_keys)
      assert step["uses"] == uses
    end

    assert step!(steps, "Configure Cachix")["with"] == %{"name" => "devenv"}

    cache_step = step!(steps, cache_name)
    assert_exact_keys!(cache_step, ["name", "uses", "with"])
    assert_exact_keys!(cache_step["with"], ["key", "path"])

    assert cache_step["uses"] ==
             "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
  end

  defp assert_run_steps!(steps, expected) do
    for {name, run} <- expected do
      step = step!(steps, name)
      assert_exact_keys!(step, ["name", "run"])
      assert step["run"] == run
    end
  end

  defp assert_exact_keys!(map, expected) do
    assert map |> Map.keys() |> Enum.sort() == Enum.sort(expected)
  end

  defp assert_upstream_comments!(name) do
    source = read!(Path.join([".github", "workflows", name]))

    assert length(
             Regex.scan(
               ~r/^\s*# TODO\(upstream\): duskmoon-dev\/phoenix-duskmoon-ui#129$/m,
               source
             )
           ) == 1

    assert length(
             Regex.scan(
               ~r/^\s*# WORKAROUND\(upstream\): duskmoon-dev\/phoenix-duskmoon-ui#129$/m,
               source
             )
           ) == 1
  end

  defp root_releases do
    ignore_module_conflict? = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Mix.ProjectStack.on_clean_slate(fn ->
        Mix.Project.in_project(:singularity_umbrella, @repo_root, fn _project ->
          Mix.Project.config()
          |> Keyword.fetch!(:releases)
        end)
      end)
    after
      Code.put_compiler_option(:ignore_module_conflict, ignore_module_conflict?)
    end
  end

  defp docker_stages(dockerfile) do
    runtime =
      "FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132 AS runtime"

    [build_stage, runtime_stage] = String.split(dockerfile, runtime, parts: 2)
    {build_stage, runtime_stage}
  end

  defp apt_packages(stage) do
    [_, packages] =
      Regex.run(~r/apt-get install --yes --no-install-recommends ([^\n]+)/, stage)

    packages
    |> String.trim()
    |> String.trim_trailing("\\")
    |> String.split()
  end

  defp read!(path), do: File.read!(Path.join(@repo_root, path))
end
