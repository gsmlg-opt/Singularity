# Task16 legacy restore transport compatibility design

Status: independently reviewed design; implementation and Task16 acceptance pending.
Companion:
`docs/superpowers/plans/2026-10-19-singularity-v0.2-phase-5-restore-transport.md`.
Canonical design:
`docs/superpowers/specs/2026-10-19-singularity-v0.2-phase-5-restore-transport-design.md`.
Continuing repository authority permits this necessary test-oracle compatibility
repair after independent DESIGN SPEC and distinct QUALITY review. No renewed
routine human approval is required. The parent owns execution and promotion.

## Evidence and cause

Worktree: `.trees/v0.2-phase-5-export-backup`, HEAD
`8fb1142ee593641544769658d03a96cb83ebaa56`; current candidate39 remains frozen.
Standalone203 failed naturally1; own204 was actual EMPTY/0. Diagnostic219
failed naturally1; own220 was actual EMPTY/0. These failures stay preserved.
219's fixed call-only trace reaches CLI parsing/configuration and actual
LocalDestination.normalize, then destination_invalid, before read_secrets,
OracleBackupOperation.request or BackupVault.request. It contains no traced
arguments, returned secrets, exception payloads or private snapshots.

The legacy task captures bundle_path from the initial configured backup_root
before creating its source installation (singularity.test.restore.ex:267-273).
Task16's approved TestEnvironment.create! now assigns a separate backup_root
and knowledge_export_root per installation (test_environment.ex:238-255).
backup_source! creates the installation before backup_runtime reads its new
backup_root (:313,325,924). The old absolute bundle is therefore outside the
new root. LocalDestination.normalize/2 correctly rejects it through
contained_relative/2 (local_destination.ex:27-37,165-172). This is a test
composition regression, not forbidden argv, FD transport, default V3, or Vault.

Relevant current pins:

- Legacy task: `bb1f0106a7ddfd1575c6fd9b176ff6c86a836d79ec902be9acf979201b38aace`.
- Existing five-unit file: `51f95b54176747a0c63a1d55bf9ed6bb4d94b2ff1b8f74ca4841ae44dfe532da`.
- TestEnvironment: `7e6c5c717c97e17c1455d79208309bf765209f496cea5b45de5b5195ce09bc4e`.
- 219 raw: `ed72e60fbeaec814bbbb74039ca3a8ee6c2a783ea26825dcee40def85a5a114f`.

## Decision and exact scope

Prefer two explicit oracle bindings over changing the shared TestEnvironment or
adding a new helper/selector. Reverting isolation would weaken Task16; copying
the bundle between installation roots would add unnecessary data ownership and
cleanup paths. Neither alternative is authorized by this repair.

Only these four future public paths may change:

1. `apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex`.
2. `apps/singularity_runtime/test/mix/tasks/singularity.test.restore_test.exs`.
3. The future canonical design named above.
4. `docs/superpowers/plans/2026-10-19-singularity-v0.2-phase-5-restore-transport.md`.

Immediately after TestEnvironment.create!(names), in backup_source!/3 and
restore_destination!/5 only, add exactly:

```elixir
Application.put_env(:singularity_storage, :backup_root, Path.dirname(bundle_path))
```

bundle_path was already constructed by this trusted test task beneath its
configured root using generated source/destination suffixes. Its parent exists
before descriptors are opened. This adds no request-selected authority, new root,
symlink selector or public adapter; unchanged production normalization still
checks containment and symlinks. Set the binding before runtime startup or restore
context construction so actual CLI normalization, worker destination and
restorer all use that same pre-existing transport root. Object storage and
knowledge-export roots remain installation-specific and disjoint. The normal
LocalDestination containment/symlink checks remain active and unchanged.

V1 needs no binding change: restore_v1_fixture! creates its own installation,
builds restore_context and copies its checked-in V1 fixture using the same
post-create backup_root (:391-410). It does not consume the shared V3 bundle.
Keep its copy, restore, fixture bytes and cleanup untouched.

## Configuration lifetime and cleanup

Add :backup_root to the task's @storage_env_keys and
{:singularity_runtime, :knowledge_export_root} to snapshot_environment's runtime
inventory. Preserve the existing Application.fetch_env snapshot representation
and restoration branches: put prior values; delete previously absent keys.
The existing cleanup! call in run/1's after must restore both keys after success
or failure, before returning to the later knowledge oracle. Do not move that
oracle entry, alter legacy cleanup order, or weaken any five existing tests.

No new filesystem allocation/removal or secret helper is needed. Existing
with_secret_descriptors retains its current files, 0600 mode, descriptor lifetime
and close/remove actions. Existing bundle cleanup and three installation drops
remain unchanged. Preserve all neighboring paths, backup/storage bytes and
historical V1/V2/V3 assertions. Partial creation and exceptions retain their
existing teardown; this amendment only restores the two newly changed settings.

## Regression and acceptance obligations

Add causal AST contracts to the five-test owner, without editing old tests or
helpers. Require the exact root binding immediately after each of the two
create! calls and before runtime/context construction; reject missing, misplaced
or wrong-parent bindings. On candidate39 this fails for absent bindings, not a
missing new API. Preserve 203/219 as separate actual integration RED evidence.

Add a real filesystem-only LocalDestination test with distinct mode-0700 roots:
an absolute bundle beneath the common root must be invalid under the disjoint
installation root and accepted under the common root as its canonical relative
reference. No parser/normalizer replacement, symlink or database is involved.
Add static snapshot/cleanup contracts for both newly tracked keys: capture before
legacy work, cleanup in after, and unchanged present/absent restoration branches.
These are explicitly source contracts, not a simulated native restore claim.

Parent must run the complete unit owner RED, then minimal implementation, full
unit GREEN, exact no-argument standalone restore, and whole backup/restore cohort.
Every required previously pending/failed Task16 gate must subsequently pass on
one frozen successor, including ordinary immediate ownership/residue posts.
Diagnostic execution is not standalone acceptance; 203/219 are not relabelled.
Independent SOURCE SPEC then fresh distinct QUALITY must review actual sources.

## Attribution and boundaries

Keep original frozen56 and Task12 raw manifests immutable. The task and unit
file are not frozen56 members; this does not authorize CLI/Vault changes.
Extend private forward attribution with exact unique literals, two-sided context
and whole-file inverse checks recovering the task/unit pins above. All original
five unit assertions/helpers and all other candidate39 bytes must survive.
Record actual formatter changes separately with exact inverses; never preload
normalizers into Mix/runtime or rewrite historical evidence. Four additions to
the candidate39 dirty-path set yield a specifically pinned successor43, not an
open-ended allowlist. Parent alone edits tooling/manifests and runs guards.

No TestEnvironment, LocalDestination, Backup/Restore CLI, Vault, custody, crypto,
capability, migration, production behavior, timeout or public API change. No new
helper, configuration feature, dependency, adapter, root allocation or cleanup.
Production repair counters remain0 at drafting; this is necessary test-composition
compatibility work. E2E remains NOT RUN; Task17/18, release, publication,
deployment and production activation remain gated and outside implementation.
