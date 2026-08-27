# First Release Bootstrap Design

**Status:** Approved design amendment

**Date:** 2026-08-27

## 1. Purpose

The repository's canonical Mix version is already `0.1.0`, while no remote
`v0.1.0` tag or GitHub Release exists. The transactional release workflow
currently accepts only a version greater than the canonical version, so it
cannot create the requested first `0.1.0` release.

This amendment adds a safe equal-version bootstrap path without weakening the
monotonic and resumable behavior for later releases. It supplements the
approved release-container design and leaves the image, archive, and publish
transaction unchanged.

## 2. Bootstrap behavior

Release preparation continues to validate a strict numeric `X.Y.Z` version,
the requested branch, the remote branch head, existing tags, and existing
GitHub Release state.

When the requested tag does not exist:

- A requested version lower than the canonical Mix version is rejected.
- A requested version equal to the canonical Mix version uses bootstrap mode.
  The workflow creates the annotated release tag at the already verified
  branch commit without editing `mix.exs` or creating an empty version-bump
  commit.
- A requested version greater than the canonical Mix version retains the
  existing path: update `mix.exs`, create `chore(release): vX.Y.Z`, and tag the
  resulting commit.

Both equal and greater versions must still be higher than every existing
numeric release tag. Existing-tag resume, completed-release rejection, branch
ancestry, remote race checks, global release serialization, and fail-closed
GitHub API behavior remain unchanged.

## 3. Transaction and artifacts

Bootstrap mode uses the current verified branch commit as `SOURCE_REVISION`.
The established transaction remains:

1. build one multi-platform image export;
2. verify the action, registry manifest, OCI root descriptor, and archived blob
   all have the same digest;
3. atomically publish the branch ref and annotated tag;
4. recheck that the requested tag is still the highest numeric release;
5. promote the immutable digest to `0.1.0`, `0.1`, and `latest`;
6. create GitHub Release `v0.1.0` with the OCI archive and basename-only SHA-256
   checksum.

No manual tag, image, or GitHub Release bypass is permitted if the workflow
fails.

## 4. Release execution

Before dispatch:

- push local `main` and verify its remote SHA;
- install the available `GHCR_TOKEN` as the repository Actions secret without
  printing its value;
- wait for the pushed SHA's CI and Test workflows to succeed;
- confirm `v0.1.0` and its GitHub Release still do not exist.

Then dispatch `release.yml` with `version=0.1.0` and `git_ref=main`. If GitHub
Actions fails, diagnose the run and fix the workflow rather than creating
partial artifacts manually. A runner/account billing lock is an external stop
condition, not a build failure.

## 5. Verification

The workflow contract test must fail before implementation and prove the final
bootstrap branch afterward. It must distinguish equal-version bootstrap from a
greater-version bump and continue rejecting a downgrade. The existing focused
release/container tests, formatter, compiler, actionlint, and diff checks must
remain green.

Release success requires all of the following live evidence:

- remote `main` points to the expected source or release commit;
- annotated tag `v0.1.0` peels to the image source revision;
- the Release workflow concluded successfully;
- GitHub Release `v0.1.0` is published with the OCI archive and `.sha256` asset;
- the downloaded archive matches its checksum;
- GHCR tags `0.1.0`, `0.1`, and `latest` resolve to the promoted digest;
- the GHCR index contains `linux/amd64` and `linux/arm64` manifests;
- the published image revision label matches the peeled release-tag commit.

No deployment or service restart is included in this release task.
