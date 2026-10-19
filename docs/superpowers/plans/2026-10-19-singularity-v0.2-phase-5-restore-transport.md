# Task16 legacy restore transport compatibility implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement
> task-by-task; the parent owns delegation, runtime serialization and review.

**Goal:** Restore the genuine standalone oracle's shared backup transport after
Task16 introduced isolated installation roots, without changing product code.
**Architecture:** Two explicit post-create backup-root bindings in the existing
legacy task, plus exact restoration of its two newly mutated configuration keys.
**Tech Stack:** Elixir/Mix, ExUnit AST contracts, actual LocalDestination and
filesystem, existing PostgreSQL/native backup-restore composition.

Companion: `docs/superpowers/specs/2026-10-19-singularity-v0.2-phase-5-restore-transport-design.md`.
Canonical companion:
`docs/superpowers/specs/2026-10-19-singularity-v0.2-phase-5-restore-transport-design.md`.
This is planning only. Task16 is unaccepted; standalone203 and diagnostic219
remain FAIL with EMPTY/0 ownership posts204/220. No implementation begins until
independent DESIGN SPEC and fresh distinct QUALITY pass this pair.

## 1. Freeze and promote reviewed scope

- [ ] Parent verifies W `.trees/v0.2-phase-5-export-backup`, HEAD
  `8fb1142ee593641544769658d03a96cb83ebaa56`, candidate39 unchanged, no live
  conflicting writer/VM. Read applicable AGENTS and the full companion design.
- [ ] Promote only the canonical design and
  `docs/superpowers/plans/2026-10-19-singularity-v0.2-phase-5-restore-transport.md`;
  record exact private-to-canonical companion-reference inverses.
- [ ] Assign one source worker only these two files; parent owns docs/tooling:
  `apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex` and
  `apps/singularity_runtime/test/mix/tasks/singularity.test.restore_test.exs`.
  Preserve all other authors' changes and original five tests/helpers.
- [ ] Assert task whole SHA
  `bb1f0106a7ddfd1575c6fd9b176ff6c86a836d79ec902be9acf979201b38aace` and
  unit whole SHA `51f95b54176747a0c63a1d55bf9ed6bb4d94b2ff1b8f74ca4841ae44dfe532da`.
  A mismatch is a handoff issue; do not repair it by overwriting bytes.

## 2. Add causal contracts, then obtain actual RED

- [ ] Add a uniquely marked contiguous block of new tests/helpers to the unit
  owner; stripping it must recover its entire old hash. Keep async:false; use
  @tag :tmp_dir for the filesystem case. Do not execute the native task in units.
- [ ] Parse actual task source using its existing parse!/expressions pattern.
  Locate backup_source!/3 and restore_destination!/5 explicitly. Require exactly
  one TestEnvironment.create!(names) in each, followed immediately by:

  ```elixir
  Application.put_env(:singularity_storage, :backup_root, Path.dirname(bundle_path))
  ```

  Require this before backup runtime startup/configuration and restore_context
  creation. Negative structural controls remove the binding, move it after
  context/startup, or replace bundle parent with the installation root; each must
  fail the intended ordering/binding assertion after a passing positive control.
- [ ] Add a filesystem-only test using two actual disjoint temporary directories
  under ExUnit's owned tmp_dir, chmod0700. A safe server-like bundle filename can
  remain absent; LocalDestination supports absent final files. For example:

  ```elixir
  assert {:error, %{code: :invalid}} =
           LocalDestination.normalize(%{backup_root: installation}, bundle)
  assert {:ok, "transport.bundle"} =
           LocalDestination.normalize(%{backup_root: common}, bundle)
  ```

  Here bundle is Path.join(common,"transport.bundle"); both roots exist. Do not
  replace production normalization, grant authority, copy source content or use
  symlinks. The test illustrates the exact rejected/accepted containment boundary.
- [ ] Add source contracts requiring :backup_root in @storage_env_keys and
  knowledge_export_root in snapshot_environment's runtime list. Verify snapshot
  precedes legacy try; its after invokes cleanup!, which invokes restoration.
  Require unchanged restoration of {:ok,value} by put_env and :error by delete_env.
  Check both new keys are covered on the success and exception cleanup paths;
  describe these honestly as static control-flow contracts, not runtime proof.
- [ ] Parent formats only the additive test block as needed, freezes the test-only
  stage and runs the whole owner using the accepted qualification wrapper:

  ```sh
  devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh mix test apps/singularity_runtime/test/mix/tasks/singularity.test.restore_test.exs --seed 215378 --warnings-as-errors
  ```

  Expected RED: new causal bindings/snapshot contracts fail against actual old
  task; original five remain passing and containment test passes. Close the test
  command, then run the ordinary owned-residue post as the next operation upon
  observed completion. Preserve raw receipt, exact natural status and polling gap.

## 3. Implement the four minimal task edits

- [ ] Only after actual RED, add the exact Application.put_env line immediately
  after create! in backup_source!/3 and restore_destination!/5. No helper or new
  filesystem operation; do not alter restore_v1_fixture! (its context/copy both
  use the same post-create installation backup root).
- [ ] Append :backup_root to @storage_env_keys; append
  {:singularity_runtime,:knowledge_export_root} to snapshot_environment's runtime
  inventory. Preserve all restoration/cleanup bodies, FD/argv handling, capture,
  V1 fixture, native assertions, KDF/crypto and later guarded knowledge entry.
- [ ] Worker self-reviews exact diff, proves whole-task inverse to bb1f0106… and
  whole-unit inverse to51f95b54…, closes its author window, and reports hashes.
  Parent serializes actual formatter and records exact pre/post attribution.

## 4. Freeze successor and run real acceptance gates

- [ ] Parent extends immutable-history forward tooling: candidate39 raw entries
  remain exact; add only task, unit and two canonical docs for pinned43 paths.
  New exact inverse rules must require unique literals/contexts and full old/new
  hashes; malformed, duplicated, relocated or unrelated changes fail closed.
  Preserve frozen56/Task12 raw manifests; no runtime preloads or relaxed guards.
- [ ] Run the complete unit command from Task2 again, requiring all old/new tests
  and warnings-as-errors GREEN; close and obtain immediate ordinary residue post.
- [ ] Run the exact original no-argument standalone command, not a diagnostic:

  ```sh
  devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh mix singularity.test.restore
  ```

  Require natural0, real legacy backup and V3 restore, checked-in V1 restore and
  genuine later knowledge oracle completion, followed by actual EMPTY/0 residue.
- [ ] Replay whole backup/restore cohort with unchanged owners/assertions:

  ```sh
  devenv shell -- bash .devenv/phase5-task16-io-q1-command-v2.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs --seed 215378 --warnings-as-errors
  ```

  This is the literal actual201 integration cohort command, not a reduced unit
  selection. Require every original test and natural0, then EMPTY/0 post.
- [ ] Replay both dev/test compile and zero-cycle xref, full architecture, affected
  pure/native owners and remaining permitted Task16 gates on this frozen43.
  Earlier205/207 or other passes remain historical until source-change impact is
  explicitly assessed; no blanket inherited PASS. Format, static checks, exact
  attribution, owned environment guards and ordinary postgates remain mandatory.

## 5. Independent review and local handoff

- [ ] Independent SOURCE SPEC inspects actual task/tests, causal RED/GREEN,
  success/error environment coverage, V1 non-change and attribution. A fresh
  distinct QUALITY reviewer then checks minimality, privacy and cleanup.
- [ ] Parent records exact commands, source hashes, raw outcomes, preserved
  failures, repair counters and limitations. No repair is called complete until
  all required gates/reviews pass; investigate any new failure without weakening
  assertions or changing excluded CLI/Vault behavior.
- [ ] Only parent performs any authorized small local commit/handoff after all
  gates; workers never commit/stage. E2E remains NOT RUN; no push, release,
  publication, deployment, activation, or Task17/18 implementation is included.
