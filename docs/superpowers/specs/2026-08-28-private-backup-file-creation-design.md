# Private Backup File Creation Design

**Status:** Approved design amendment

**Date:** 2026-08-28

## 1. Purpose

The required Tests workflow for the first `0.1.0` release fails because a local
backup partial is created with mode `0644` while the storage security contract
requires `0600` before the writer receives the file descriptor.

The production code currently passes `{:mode, 0o600}` to `:file.open/2`. OTP 28
does not define that option. Its native file layer ignores unknown list entries
and creates regular files with mode `0666` filtered only by the process umask.
The normal `0022` umask therefore produces `0644` locally and on GitHub's
runner. The fix must establish a restrictive process umask before BEAM starts
and must fail closed if the actual descriptor mode is ever unsafe.

## 2. Approved approach

Use a process-level `077` umask on the two supported launch surfaces:

- `devenv.nix` sets `umask 077` in `enterShell`, covering local development,
  CI, tests, Mix tasks, and the repository's operational helper commands.
- `rel/env.sh.eex` sets `umask 077` before generating the release cookie or
  starting the VM, covering Docker and non-Docker OTP releases.

This is the only mechanism available to OTP's built-in file API that affects
the mode atomically in the underlying `open(..., O_CREAT, 0666)` call. A
post-open `chmod` is rejected because another local process could open the file
during the permissive interval and keep its descriptor after permissions are
tightened.

The local destination removes the ineffective `{:mode, 0o600}` option. After
exclusive open, it reads metadata from the open descriptor, requires an exact
permission mask of `0600`, and only then returns the descriptor to the backup
writer. If the mode is unsafe, it closes and removes the still-empty partial by
its already captured device/inode identity and returns a typed error. No backup
bytes are written on the unsafe path.

## 3. Alternatives rejected

- Setting `umask 077` only in GitHub Actions would make CI green while leaving
  production and local operational commands dependent on their caller's umask.
- Calling `chmod` after open creates a security window and does not satisfy the
  at-creation requirement.
- Adding an application-owned native `open(2)` NIF would provide per-call mode
  control but adds cross-platform native code, packaging, and multi-architecture
  release risk for behavior already provided by a correctly inherited umask.

## 4. Scope

The implementation is limited to:

- `devenv.nix` for development/CI process inheritance;
- `rel/env.sh.eex` for OTP release process inheritance;
- `apps/singularity_storage/lib/singularity/storage/backup/local_destination.ex`
  for removing the ignored option and verifying the descriptor mode;
- the existing local-destination and release/container contract tests required
  to prove those boundaries.

No backup format, encryption, publication, cleanup, database, container image,
or GitHub release transaction behavior changes.

## 5. Error handling

Exclusive creation, path containment, symlink rejection, and inode ownership
checks remain in their current order. Descriptor identity is captured before
the permission check so an unsafe empty partial can be removed without deleting
a replacement path. Any close, identity, inspection, or cleanup failure keeps
the existing fail-closed typed error behavior.

Running the application outside devenv or the OTP release wrapper with a
permissive umask cannot silently write a permissive backup: descriptor
verification rejects the file before the first write.

## 6. Verification and release continuation

The already-failing test `exclusive partial creation sets mode 0600 at open
time` is the RED proof. Additional contracts require `umask 077` in both launch
surfaces and reject the obsolete mode tuple. After implementation:

- the focused local-destination test passes under devenv;
- a direct Mix probe launched with umask `0022` fails closed before writing and
  leaves no owned partial;
- storage tests, release/container contracts, formatting, warnings-as-errors
  compilation, and workflow lint pass;
- the narrow fix is reviewed, committed, merged, and pushed;
- CI and Tests are rerun for the new exact SHA.

Only after both required workflows conclude successfully may `release.yml` be
dispatched for `version=0.1.0` and `git_ref=main`. The existing tag, GitHub
Release asset, checksum, OCI/GHCR digest, platform, and revision-label proofs
remain mandatory. No deployment is included.
