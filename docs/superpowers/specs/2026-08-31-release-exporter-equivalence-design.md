# Release Exporter Equivalence Design

## Context

The first `v0.1.0` release build produced one multi-platform BuildKit result and exported it to both GHCR and an OCI archive. The release correctly stopped before publishing its source tag, promoted image tags, or GitHub Release because the verification step required the GHCR root index digest and OCI archive root index digest to be identical.

That requirement is stricter than content equivalence. BuildKit emitted the same runnable `linux/amd64` and `linux/arm64` image manifests through both exporters, but generated exporter-specific provenance and SBOM attestation manifests. Those different attestation descriptors made the root indexes different:

- GHCR root: `sha256:2c63339cb5cae3e39e84827421c446198878ac2eb7dbb6e88b13af7c86ec3085`
- OCI archive root: `sha256:4cf096315d7e238b4e08f49d3dd3d8990b4cfd28a5a81d8115501af93079c866`
- Shared `linux/amd64` manifest: `sha256:19232f35918ab75f3a01ab2396f0eb9670308fe0cfa86f5caa91343c15c81b51`
- Shared `linux/arm64` manifest: `sha256:e8e6142250436f031b726afb101ce8c40e5db7b0f3347d89b5094248e350e296`

## Decision

The release will retain the single multi-output BuildKit invocation, maximum provenance, and SBOM generation. Verification will treat the GHCR index and OCI archive index as independently addressed containers for the same runnable platform content.

The workflow will:

1. Require the action digest and BuildKit metadata digest to be valid and equal.
2. Fetch the GHCR root index by immutable digest, hash its exact bytes, and require that hash to equal the action digest.
3. Read the OCI layout root descriptor, require exactly one OCI image-index root with a valid digest and positive declared size, and verify the referenced blob's exact digest and size.
4. Require both GHCR and OCI root objects to use `schemaVersion: 2` and `application/vnd.oci.image.index.v1+json` before inspecting descriptors.
5. Validate and classify every descriptor in each root index. The only permitted descriptors are exactly one valid runnable `linux/amd64`, exactly one valid runnable `linux/arm64`, and exporter-specific attestations.
6. Require every attestation to use the exact `unknown/unknown` platform object, OCI image-manifest media type, positive size, lowercase SHA-256 digest, and BuildKit annotations `vnd.docker.reference.type=attestation-manifest` plus a lowercase SHA-256 `vnd.docker.reference.digest`.
7. Require exactly one attestation reference for each required runnable digest; missing, duplicate, or unknown references fail validation.
8. Canonicalize and compare the runnable descriptor sets, including the full platform object, media type, size, and digest.
9. Preserve the GHCR digest as `IMAGE_DIGEST` for later tag promotion.

Attestation manifest digests may differ between the GHCR and OCI exporters. Their reference linkage is validated independently in each root, while only the canonical runnable descriptors must match across exporters.

## Failure Behavior

Verification remains fail-closed. Unexpected or malformed descriptors, missing or duplicate required platforms or attestation references, invalid root schema/media types, malformed digests, a root blob digest or size mismatch, a registry byte hash mismatch, or any runnable descriptor difference must stop the workflow before source/tag publication and image-tag promotion.

The workflow will emit concise mismatch diagnostics identifying whether the registry digest, OCI root integrity, required platform set, or runnable descriptor equivalence failed.

## Testing

The focused release/container architecture test will first be changed to reject the old root-digest equality check and require the new invariants. That test must fail before the workflow changes and pass afterward.

Verification before redispatch includes:

- the focused ExUnit release/container contract test;
- `actionlint` on the release workflow;
- Bash syntax validation of the verification script;
- executable fixtures that run the helper extracted from the parsed workflow, including valid exporter-different attestations, runnable digest/platform drift, extra runnable platforms, malformed descriptors, malformed roots, and invalid attestation linkage;
- the focused contract test with `14 tests, 0 failures`.

After pushing the fix, a new `0.1.0` dispatch must reach terminal success. Final proof must cover the annotated source tag, GitHub Release assets and checksum, GHCR `0.1.0`, `0.1`, and `latest` tags resolving to one digest, both required platforms, and the source revision label.

## Scope

Only the release workflow, its focused architecture contract, and the associated design and implementation plan are in scope. The Dockerfile, application behavior, unrelated workflows, dependency versions, and known PostgreSQL integration failures are unchanged.
