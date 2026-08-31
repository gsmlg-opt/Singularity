# Release Exporter Equivalence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept exporter-specific BuildKit attestation manifest digests while proving GHCR and the OCI archive contain the same runnable `linux/amd64` and `linux/arm64` images.

**Architecture:** One BuildKit invocation writes both outputs. The verifier proves the GHCR and OCI roots independently, validates and classifies every root descriptor, verifies attestation linkage within each root, then compares only canonical runnable descriptors.

**Tech Stack:** GitHub Actions YAML, Bash, BuildKit/Buildx, OCI layout, `jq`, Elixir/ExUnit, cached `/tmp/actionlint`

---

### Task 1: Write executable parsed-helper coverage

**Files:**

- Modify: `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Parse and execute the workflow helper in table-driven fixtures**

Read `Verify immutable image digest` with `YamlElixir`, extract `required_platform_descriptors()`, and execute it through Bash; do not retype the classifier in Elixir. Each valid root must include `schemaVersion: 2`, OCI index media type, exactly two runnable descriptors, and these two properly linked but exporter-different attestations:

```json
[
  {"mediaType":"application/vnd.oci.image.manifest.v1+json","size":1112,"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","annotations":{"vnd.docker.reference.digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","vnd.docker.reference.type":"attestation-manifest"},"platform":{"os":"unknown","architecture":"unknown"}},
  {"mediaType":"application/vnd.oci.image.manifest.v1+json","size":1112,"digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","annotations":{"vnd.docker.reference.digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","vnd.docker.reference.type":"attestation-manifest"},"platform":{"os":"unknown","architecture":"unknown"}}
]
```

The accompanying runnable descriptors use the same two reference digests with `linux/amd64` and `linux/arm64` platforms. Two roots with different attestation *descriptor* digests but the same references must compare equal. A changed runnable digest must change its corresponding attestation reference before comparing it unequally. A changed full runnable platform object also compares unequally.

- [ ] **Step 2: Add and run adversarial cases (RED)**

Reject: extra `linux/s390x`; missing platform; malformed descriptor; bare `unknown/unknown`; wrong or missing `vnd.docker.reference.type`; malformed `vnd.docker.reference.digest`; reference to a non-runnable digest; duplicate or missing linkage; Docker manifest-list root media type; and a non-`2` schema version.

```bash
mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
```

Expected before the implementation: a new adversarial fixture fails because the old classifier accepts a bare `unknown/unknown` descriptor or fails to enforce one-to-one linkage.

### Task 2: Implement final root and descriptor verification

**Files:**

- Modify: `.github/workflows/release.yml:285-430`
- Modify: `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Install the final classifier**

```bash
required_platform_descriptors() {
  jq -Sce '
    def positive_integer: type == "number" and . > 0 and floor == .;
    def sha256_digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
    def valid_descriptor:
      if type != "object" then error("image index descriptor must be an object")
      elif .mediaType != "application/vnd.oci.image.manifest.v1+json" or (.size | positive_integer | not) or (.digest | sha256_digest | not)
      then error("image index descriptor must have OCI image-manifest media type, positive integer size, and lowercase sha256 digest")
      else . end;
    def descriptor_kind:
      if (.platform | type) != "object" then error("image index descriptor is missing a platform object")
      elif (.platform.os | type) != "string" or (.platform.architecture | type) != "string"
      then error("image index descriptor has a malformed platform object")
      elif .platform.os == "linux" and (.platform.architecture == "amd64" or .platform.architecture == "arm64")
      then {kind: "runnable"}
      elif .platform.os == "unknown" and .platform.architecture == "unknown"
      then if ((.platform | keys | sort) == ["architecture", "os"]) and (.annotations | type) == "object" and .annotations["vnd.docker.reference.type"] == "attestation-manifest" and (.annotations["vnd.docker.reference.digest"] | sha256_digest)
      then {kind: "attestation", reference_digest: .annotations["vnd.docker.reference.digest"]}
      else error("unknown/unknown descriptor must be an attestation manifest with a valid runnable reference digest") end
      else error("unexpected descriptor platform \(.platform.os)/\(.platform.architecture)") end;
    if .schemaVersion == 2 and .mediaType == "application/vnd.oci.image.index.v1+json"
    then . else error("root index must have schemaVersion 2 and OCI image-index media type") end
    | if (.manifests | type) != "array" then error("image index must contain a manifests array") else .manifests end
    | map(. as $descriptor | valid_descriptor | descriptor_kind as $kind | $kind + {descriptor: $descriptor})
    | . as $classified
    | [.[] | select(.kind == "runnable") | .descriptor | {mediaType, size, digest, platform}]
    | sort_by(.platform.os, .platform.architecture)
    | if length != 2 then error("expected exactly linux/amd64 and linux/arm64 runnable descriptors")
      elif (map(.platform | "\(.os)/\(.architecture)") | unique | sort) != ["linux/amd64", "linux/arm64"] then error("expected exactly one descriptor for each required runnable platform")
      else . end
    | . as $runnable_descriptors
    | [$classified[] | select(.kind == "attestation") | .reference_digest] | sort
    | if . == ($runnable_descriptors | map(.digest) | sort) then $runnable_descriptors
      else error("attestation references must match required runnable digests exactly once each") end
  '
}
```

This classifies every descriptor. It permits exactly one `linux/amd64`, exactly one `linux/arm64`, and only exact `unknown/unknown` BuildKit attestation manifests. The returned value deliberately excludes attestation manifest digests.

- [ ] **Step 2: Preserve independent root integrity and promotion**

Keep the action/metadata equality and immutable registry raw-byte hash. Install cleanup immediately after the first temporary file so `set -u` cannot leave it behind if the second allocation fails:

```bash
registry_root_blob="$(mktemp)"
oci_root_blob=""
trap 'rm -f "$registry_root_blob" "${oci_root_blob:-}"' EXIT
oci_root_blob="$(mktemp)"
```

Require exactly one OCI layout root descriptor with `application/vnd.oci.image.index.v1+json`, lowercase SHA-256 digest, and positive integer size. Hash and count its exact blob bytes. Require both the verified GHCR root and OCI root blob to pass the helper's `schemaVersion: 2` and OCI-index checks. Never compare their root digests. Compare canonical runnable strings and retain `IMAGE_DIGEST=$resolved_digest`:

```bash
registry_platform_descriptors="$(required_platform_descriptors < "$registry_root_blob")"
oci_platform_descriptors="$(required_platform_descriptors < "$oci_root_blob")"
if [[ "$registry_platform_descriptors" != "$oci_platform_descriptors" ]]; then
  echo "registry and OCI runnable platform descriptors differ" >&2
  diff -u <(jq . <<< "$registry_platform_descriptors") <(jq . <<< "$oci_platform_descriptors") >&2 || true
  exit 1
fi
echo "IMAGE_DIGEST=$resolved_digest" >> "$GITHUB_ENV"
```

- [ ] **Step 3: Run GREEN and static verification**

```bash
mix test apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
mix format apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
mix format --check-formatted apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
PATH="/tmp:$PATH" actionlint .github/workflows/release.yml
MIX_ENV=test mix run --no-start -e '
workflow = YamlElixir.read_from_file!(".github/workflows/release.yml")
run = workflow |> Map.fetch!("jobs") |> Map.fetch!("release") |> Map.fetch!("steps") |> Enum.find(&(&1["name"] == "Verify immutable image digest")) |> Map.fetch!("run")
File.write!("/tmp/singularity-verify-image-digest.sh", run)
'
bash -n /tmp/singularity-verify-image-digest.sh
```

Expected: `14 tests, 0 failures`; format, actionlint, and Bash syntax checks exit `0`.

- [ ] **Step 4: Probe the actual failed-run root**

```bash
sed -n '/^required_platform_descriptors()/,/^}/p' /tmp/singularity-verify-image-digest.sh > /tmp/singularity-required-platform-descriptors.sh
bash -ceu 'source /tmp/singularity-required-platform-descriptors.sh; required_platform_descriptors < /tmp/singularity-registry-manifest.json'
```

Expected: canonical amd64 and arm64 descriptors print. The failed-run root's two attestation descriptors may have exporter-specific manifest digests, but each has an `attestation-manifest` annotation linked to one runnable digest.

### Task 3: Review and commit the fail-closed gate

**Files:**

- Review: `.github/workflows/release.yml`
- Review: `apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs`

- [ ] **Step 1: Verify ordering and scope**

Confirm action/metadata mismatch, registry-byte mismatch, OCI root descriptor/blob mismatch, root schema/media mismatch, descriptor or linkage mismatch, and runnable-equivalence mismatch all exit before `Publish source branch and tag`.

```bash
git diff --check
git status --short
git add .github/workflows/release.yml apps/singularity_web/test/singularity/architecture/release_container_contract_test.exs
git diff --cached --check
git commit -m "fix(release): verify exporter-equivalent images"
```

Expected: only the workflow and focused contract test are committed; source publication, tag promotion, and GitHub Release creation remain behind the validation gate.
