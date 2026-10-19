# Task16 bounded tmpfs qualification implementation plan — draft

> For agentic workers: the Sol coordinator owns execution and assigns the
> approved steps using executing-plans or subagent-driven-development as
> appropriate. This Astra assignment ends at the two private draft documents.

**Goal:** Obtain honest local Task16 qualification after reducing the observed
ext4 journal exposure, preserving every product assertion and historical failure.

**Architecture:** One opt-in test-only allocator replaces exactly two fixture
root arguments. Existing TMPDIR support moves harness roots; a fresh owned
PostgreSQL17.10 cluster uses existing tmpfs with unchanged durability settings.
No product behavior or original evidence changes.

**Tech stack:** Existing Elixir1.18.4/ExUnit, PostgreSQL17.10, Linux tmpfs,
project toolchain/profile and exact source-attribution checks.

Read the complete design at
`docs/superpowers/specs/2026-10-19-singularity-v0.2-phase-5-export-io-qualification-design.md`.
All steps below are pending. Root is the only VM/service controller. No
implementation command in this plan has been executed by its author.

## 1. Freeze, preserve and independently review

- [ ] Root confirms current121 and its immediate ordinary post naturally closed;
  no source writer, test VM, compiler or other owned command remains live.
  Do not signal another owner's process or infer closure from a lost session.
- [ ] Record `git rev-parse HEAD`, `git status --short`, `git diff --cached
  --quiet`, `git diff --check`, and the C13 manifest hash. Verify all28 C13 pins.
  Record Snapshot test full hash `f6fd64c98824ec56fdb30c88725df37badaff3331922e36793ccb85c8188571f`.
  Preserve predecessor edits and all excluded frozen content.
- [ ] Preserve117FAIL/118EMPTY0 and parent119/120 receipts unchanged. Read both
  complete drafts; independent DESIGN SPEC then a different DESIGN QUALITY
  reviewer inspect exact draft hashes, especially safety/cleanup/attribution.
  Close findings before edits or service/environment changes. No review PASS
  substitutes for runtime evidence. Publish design/plan to canonical docs only
  under a separate explicit parent file assignment, with exact attribution.
- [ ] Reserve unused `.devenv/phase5-task16-io-q1-*` paths for forward candidate,
  environment, wrapper, initdb/start and run receipts. If any exist, choose a
  fresh increasing namespace; never overwrite history.

## 2. Add the smallest test-only interface

Files: create Runtime test support `knowledge_export_qualification_root.ex` and
focused `knowledge_export_qualification_root_test.exs`; modify only the native
and Snapshot SQL root arguments identified in the design.

- [ ] Sol first writes focused failing contracts for
  `Singularity.Runtime.KnowledgeExportQualificationRoot.allocate!/1`: unset
  returns exactly its argument/no mutation; set valid private real owned parent
  yields unique0700 owned real child; invalid root variants fail with the same
  fixed message and never change parent/sentinel. Include both leaf and ancestor
  symlink, empty/relative/missing/file and exposed-mode failures. Keep tests
  nonasync; restore the environment in on_exit. No privileged ownership test.
  Use `apply(Singularity.Runtime.KnowledgeExportQualificationRoot, :allocate!,
  [fallback])` for the initial absence witness so a missing-module compiler
  warning does not replace the intended failing test invocation.
- [ ] Through root's existing serialized command lane, run:

  ```sh
  mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_qualification_root_test.exs --seed 215378 --warnings-as-errors
  ```

  Required RED: allocator is absent, not an unrelated compile/setup failure.
  Preserve actual raw/exit and immediate ordinary post as the lane requires.
  If host pressure prevents this check, report environment blockage; do not
  fabricate a red witness or change timeouts.
- [ ] Implement only the contract: absent env direct return; fixed-message
  validation of canonical absolute real ancestor chain,0700 leaf and fallback
  UID; random16-byte hex child exclusive `File.mkdir`; establish/check0700,
  UID/type and unchanged parent chain identities. No recursive mkdir/reuse,
  retries or deletion. Use existing crypto/File/Path APIs, no dependencies.
- [ ] Replace native fixture argument with the fully qualified allocator call:

  ```elixir
  Singularity.Runtime.KnowledgeExportQualificationRoot.allocate!(context.tmp_dir)
  ```

  Replace only Snapshot SQL's `LiveFixture.live_fixture!(tmp_dir)` setup with:

  ```elixir
  setup %{tmp_dir: tmp_dir},
    do:
      LiveFixture.live_fixture!(
        Singularity.Runtime.KnowledgeExportQualificationRoot.allocate!(tmp_dir)
      )
  ```

  Preserve exact unique before/after literals and two-sided context anchors;
  let formatter determine final layout, then pin that actual layout. Do not
  touch pure Snapshot setup, shared fixture, tags, bodies or assertions.
- [ ] Rerun focused allocator contracts to actual GREEN. Review cleanup behavior
  explicitly: helper must not register any cleanup or delete any path, even on
  failure. Establish that runtime imports/compilation do not include test helper.
- [ ] Read full new helper/tests and complete two-call-site diff. Capture forward
  whole-file hashes and exact inverses to C13 native/Snapshot old hashes; all
  other C13 entries unchanged. Preserve all original56 and prior inverse chains.
  Add separate exact ownership of the three newly dirty/new paths: Snapshot
  existing file, new helper and new focused tests. Candidate count is derived
  from actual path set, not assumed from a stale label.

## 3. Prepare immutable environment scripts and preflight

Files: new private `io-q1` wrapper, initdb/start scripts and environment receipt;
no change to existing wrappers, toolchain, PostgreSQL config or product config.

- [ ] Root verifies existing `/dev/shm` is tmpfs, executable as required, writable
  with sufficient available capacity and memory. Record mount type/options and
  current memory/I/O pressure without modifying them. Do not mount or tune.
- [ ] Record owned old PostgreSQL tuple and settings through explicit socket
  connection. Useful read-only query for locale discovery without relying on
  version-specific field spelling:

  ```sql
  SELECT datname, pg_encoding_to_char(encoding), datcollate, datctype,
         datlocprovider, to_jsonb(d)->>'datlocale' AS datlocale,
         to_jsonb(d)->>'daticulocale' AS daticulocale
  FROM pg_database AS d
  WHERE datname IN ('postgres','template0','template1');
  ```

  Also record server_version, data_directory, port, unix_socket_directories,
  listen_addresses, fsync, synchronous_commit, full_page_writes and relevant
  WAL settings; inspect only authentication method/config required for matching,
  never credentials/keys/password hashes. If ownership or settings cannot be
  established, stop transition as BLOCKED_HANDOFF or BLOCKED_ENV respectively.
- [ ] With `umask 077`, allocate the exact run root using
  `mktemp -d /dev/shm/singularity-t16.XXXXXX`; create separate0700 pgdata/socket/
  tmp/fixtures/evidence children. Record real ancestor/UID/mode/device/inode
  identity. Validate socket pathname length. No symlink and no pre-existing
  directory reuse; root remains project-local for source/worktree purposes.
- [ ] Write new scripts using apply_patch with those exact recorded absolute
  paths; syntax-check with `bash -n`. Wrapper pins MIX_ENV=test, existing
  MIX_DEPS_PATH and explicit PGDATA/PGHOST/PGPORT/provisioner URL, TMPDIR and
  SINGULARITY_TASK16_FIXTURE_ROOT; validates identities before exec. No default
  host DB fallback. Record file hashes and exact reviewed script contents.
- [ ] Resolve initdb argv from actual old locale/provider/encoding/auth evidence,
  using the exact Nix PostgreSQL17.10 binary. Pass the recorded fresh PGDATA with
  `-D`, the observed encoding with `--encoding`, the observed provider with
  `--locale-provider`, its corresponding observed locale flags, and observed
  authentication methods with `--auth-local` and `--auth-host`. Record the full
  populated argv before running it. Locale/auth values were not supplied and
  SQL inspection was prohibited for this design assignment; measuring them is
  an explicit execution preflight requirement, not a choice of new defaults.
  Preserve standard initdb sync. New start uses a private Unix socket with
  `listen_addresses=''`; all durability settings remain on. Match required
  extensions and bootstrap identity. Independent environment-script inspection
  verifies these populated literal values before lifecycle execution.

## 4. Serialize the owned PostgreSQL transition

- [ ] Close every VM/command and its own post. Verify no target clients/open
  transactions; actual ordinary EMPTY/0 on the old cluster. Freshly validate old
  PID/start/UID/executable/PGDATA/socket/port, not only the historical PID21905.
- [ ] Root executes the reviewed old-cluster graceful stop:

  ```sh
  /nix/store/y83y08rgfv0zag50cvq55aqx9hyc2ldv-postgresql-17.10/bin/pg_ctl -D /home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup/.devenv/phase5-pg.0LPElO -m fast -w -t 60 stop
  ```

  Record outcome; verify shutdown by matching process/start/socket/cluster
  state. Timeout is not proof of shutdown. Do not start fresh PG until closed;
  never SIGKILL or touch host/external clusters. Keep all old files.
- [ ] Execute the resolved/pinned fresh initdb and start scripts serially.
  Verify actual new identity,17.10 version, matched locale/auth and settings,
  including fsync/on, synchronous_commit/on, full_page_writes/on and TCP off.
  Any mismatch blocks native qualification; do not relax requirements.
- [ ] Run unchanged bootstrap through new wrapper/profile:

  ```sh
  bash apps/singularity_storage/priv/repo/bootstrap_roles.sh
  ```

  Preserve raw/natural exit and immediate ordinary post. Normal integration task
  will run RoleVerifier, isolated database creation, extension provisioning,
  migrations and cleanup; no direct bootstrap bypass. Record those actual
  outcomes. No copying the old cluster or production data into RAM.

## 5. Forward attestation and exact replay

- [ ] Root derives new source/identity guard names. Two exact inverse replacements
  recover full C13 native and original Snapshot bytes; historical guards/stages
  are untouched. New helper/tests and new source path set pinned independently.
  Keep old environment verification as historical; new active ownership check
  targets only new PG tuple. Never preload attribution transforms in test VM.
- [ ] Freeze final formatted source. Verify compilation/helper contracts and
  relevant source protections; any changed bytes invalidate current candidate
  hashes and require new forward names. No production changes allowed here.
- [ ] Run the following unchanged inner argv once in the new attested wrapper
  using the root's normal serialized PTY/log lane and a fresh private raw:

  ```sh
  mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs --seed 215378 --warnings-as-errors
  ```

- [ ] Immediately execute its own fresh ordinary post via the same new wrapper:

  ```sh
  psql --dbname=postgres --no-psqlrc --tuples-only --no-align --file=.devenv/phase5-task11-residual.sql
  ```

- [ ] Record actual natural exit,135 executed (118 native +17 SQL Snapshot),
  146 reported/11 existing exclusions, zero failures required, all warnings,
  raw SHA/bytes/lines, actual paths/filesystem observed and actual post EMPTY/0.
  Check fixture roots in the run namespace without logging content or secrets.
  Keep the pure Snapshot exclusions unchanged; run helper contracts separately.
- [ ] Failure enters focused diagnosis and blocks acceptance. Do not weaken,
  retry blindly, increase a timeout or infer that tmpfs proves root cause.
  Preserve117 and new failure separately. A pass records qualified local tmpfs
  evidence, not durable filesystem/power-loss/host-ext4 qualification.

## 6. Remaining gates, evidence retention and rollback readiness

- [ ] Complete every still-required original/amended Task16 gate on final source,
  including full original six API/startup/architecture owners; the committed
  transfer Native/Storage pair in both orders; exact ownership/attribution,
  formatter, compiler and zero-cycle graph checks. Existing governing commands
  remain exact; no selection narrowing. Do not run E2E.
- [ ] Phase acceptance additionally needs the permitted README gate: dependency
  resolution/unused check, format, compile, unit, integration, restore, npm frozen
  install/verify, JS check/tests, asset build, xref and workflow validation.
  Use the approved owned service lane, not README's generic host-service startup.
  Missing network/environment authority remains an explicit unrun/blocker,
  never a successful substituted check. E2E remains NOT RUN/manual-deferred.
- [ ] Default build remains unchanged. If parent deliberately selects fresh
  MIX_BUILD_PATH, first record a separate environment delta and fresh compile
  qualification with actual loaded paths/native executable provenance, including
  real target of MIX_APP_PATH/priv; then repeat affected gates. No assumed
  all-RAM build and no copied stale compilation artifacts.
- [ ] Independent SOURCE SPEC then fresh distinct SOURCE QUALITY inspect final
  test delta, two exact whole-file inverses, environment scripts/identity and
  actual new results. C13 source reviews remain historical credit only for
  explicitly unchanged portions. Root decides final local-commit readiness;
  this plan does not accept Task16 or advance17.
- [ ] Preserve fixture run namespace through assertions, every owned task/VM
  shutdown and PG shutdown. No helper/outer deletion can count as product cleanup.
  Archive all temporary RAM logs byte-for-byte with hashes to new persistent
  evidence files before acceptance or RAM cleanup. If archiving stalls, keep
  run/evidence and report incomplete closure.
- [ ] For rollback, close fresh commands/VMs, stop/verify the fresh owned PG only,
  then use unchanged old start script and wrapper. Revalidate old identity and
  settings and ordinary post. Never run both clusters, force shutdown, overwrite
  old files or silently switch the target DB. Failed orderly transition is
  BLOCKED_ENV/HANDOFF as supported by evidence.
- [ ] Eventual run cleanup is optional and separate: root proves the recorded
  run inode/UID/path and absence of all writers, ensures every child is owned
  and no replacement uncertainty exists, and removes only the verified run
  namespace after evidence archive. Otherwise preserve it and report its path.
  No broad `/dev/shm`, `.devenv`, workspace or host cleanup.
- [ ] Final report distinguishes actual PASS/FAIL/NOT RUN, original117FAIL,
  tmpfs durability limits, residual journal exposure, all command shutdown
  states, preserved old cluster, source hashes/inverses, unchanged Vault/product
  code and counters (Sol production0/Astra implementation0 for this design).
  No merge/push/version/tag/release/deployment/activation/backfill/production data.
