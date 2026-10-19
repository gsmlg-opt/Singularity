# Task16 bounded tmpfs qualification design — draft

Status: architecture proposal only. No implementation, environment transition,
test PASS, Task16 acceptance, or advancement is granted by this document.
Parent must read both complete drafts and obtain independent DESIGN SPEC then a
distinct DESIGN QUALITY review before any implementation or environment change.

## Assignment and evidence

- Task: `task16_io_qualification_architecture`; mode: architecture;
  `astra_gate=PROJECT_ARCHITECTURE`. The assignment designs a different local
  qualification environment and its narrowly necessary test interface. It is
  not a production repair or routine source review.
- Worktree: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup`;
  branch `codex/v0.2-phase-5-export-backup`; HEAD
  `8fb1142ee593641544769658d03a96cb83ebaa56`.
- Existing C13 manifest:
  `.devenv/phase5-task16-c13-read-contract-twentyeight.sha256`, SHA256
  `b13effe6de158d80047560ef679d04b507757b7988db788ab40b6c78dabd1357`.
  Its 28 dirty/untracked paths are predecessor-owned, not this assignment's
  edits. Existing source SPEC and distinct QUALITY receipts pass source review
  only. Source writers were closed at handoff; root owns subsequent execution.
- Native117 actually failed: natural exit2, 146 reported, 11 excluded,
  135 executed = 118 native + 17 Snapshot SQL, 22 failures, 1356.2 seconds.
  Raw SHA256 `69c72b4fb0212ccf6bd2163aba233c014a9561501923c84726666f4352981a28`.
  Its immediate post118 was EMPTY/0. Keep both immutable.
- Read-only receipts
  `.devenv/phase5-task16-native117-failure-inventory.json` and
  `.devenv/phase5-task16-native117-environment-diagnosis.json` identify actual
  `prim_file.sync` fixture timeout, PostgreSQL COMMIT/checkout delays and a
  same-PID fixture-start cascade. Actual BEAM2231627 had a D-state thread in
  `jbd2_log_wait_commit`; sampled database blockers/open transactions were
  absent. These support contemporaneous I/O pressure, not a sole explanation
  of all22 failures. Native115 passing the same118 native cases does not
  disprove an ordering or product defect in117.
- Parent subsequently reports119 formatter natural0 and120 EMPTY/0;121 dev
  compile remains parent-controlled. These reports are not independently
  re-executed here and do not satisfy pending qualification gates.
- Sol production repair rounds received:0. Astra implementation rounds
  received/consumed:0/0. This architecture deliverable changes neither counter.

## Recommendation and alternatives

Recommend a fresh task-owned PostgreSQL17.10 cluster on existing `/dev/shm`,
`TMPDIR` pointing to a private real directory there, and a tiny opt-in test-only
root allocator at exactly two setup call sites. Preserve the existing worktree,
product bytes, database semantics, exact native117 inner argv and assertions.
This removes the observed synchronous fixture writes and test database writes
from the stalled ext4 journal. It does not assert that all failure mechanisms
are removed or that the original host filesystem is repaired.

1. Source-identical wait/replay is smallest when pressure genuinely subsides.
   It remains a valid fallback, but current pressure persistence makes its
   completion uncertain. Waiting cannot be recorded as a passing replay.
2. PostgreSQL plus TMPDIR alone avoids cluster writes, but leaves native
   encrypted fixture `File.sync` below ExUnit's checkout-relative directories.
   It cannot address that observed failure path. Native-only relocation also
   leaves Snapshot SQL's file roots on the journal. Reject these as the chosen
   whole-cohort arrangement.
3. The recommended two-call-site arrangement has a small reviewable test-only
   delta and exposes no new product configuration. It retains some ext4 work:
   ExUnit's empty per-test directories, source reads, builds and evidence logs.
   Residual stalls remain possible and must be reported honestly.

No supported source-byte-identical full relocation was found in installed
ExUnit1.18.4: `runner.ex:621-632` constructs
`Path.expand(Path.join(["tmp", module, test_name, extra_path]))`; `TMPDIR` is
not consulted. Installed `Path.join/2` makes its right operand relative, so an
absolute `@tag tmp_dir` suffix is not an override. CWD changes, dependency
patches, ExUnit monkeypatches, checkout copies outside `.trees`, symlink
redirects, bind mounts and new mounts are excluded. `ArtifactDirectory`
`directory_chain/1` at677 checks every ancestor with `File.lstat` and rejects
symlinks; weakening that check is prohibited.

## Scope and ownership

Sol implementation after design reviews may change only these test boundaries:

- New `apps/singularity_runtime/test/support/knowledge_export_qualification_root.ex`:
  `Singularity.Runtime.KnowledgeExportQualificationRoot.allocate!/1`.
- New `apps/singularity_runtime/test/singularity/runtime/knowledge_export_qualification_root_test.exs`:
  focused allocator safety/default contracts, separate from native118 cases.
- Existing `knowledge_export_custody_live_test.exs`: replace only the argument
  `context.tmp_dir` to `fixture!/3` at574 with the allocator call. Current full
  file SHA256 is
  `1a1f4fc65faf63cf92538bf89c10d7697b70e9d6457e843408e5bfe2be2c7831`.
- Existing `knowledge_export_snapshot_test.exs`: replace only the argument in
  `KnowledgeExportSnapshotSQLTest`'s `LiveFixture.live_fixture!(tmp_dir)` setup
  at489. Current full file SHA256 is
  `f6fd64c98824ec56fdb30c88725df37badaff3331922e36793ccb85c8188571f`.
  This currently clean file is outside C13's28; explicitly add its new candidate
  and exact old-file inverse to the forward attestation. The pure Snapshot
  setup at133 remains byte-identical and is among117's existing exclusions.

Use fully qualified allocator calls to avoid extra alias edits. Existing
Snapshot support remains byte-identical, SHA256
`d815a27c87ae5549c5b762ffad4b98e5ab0cb2d46401faada0a664c5e831fb41`.
All test names, tags, bodies, timeouts, barriers, consumers, byte counts, hashes,
COMMIT/audit witnesses, ALL-issued cleanup, independent custody and sentinel
assertions remain byte-identical. No production/Vault source, frozen test,
schema, dependency, global helper or shared ExUnit behavior changes.

Environment-only work belongs exclusively to root: new private wrappers,
identity receipts and append-only run evidence under a fresh `io-q1` namespace;
fresh `/dev/shm/singularity-t16.XXXXXX` run directory; private database lifecycle.
Do not overwrite any old wrapper, manifest, guard, source stage or raw receipt.
Existing Task11 static-native raw files remain out of inspection scope.

## Test allocator contract

`allocate!(fallback_tmp_dir)` reads only
`SINGULARITY_TASK16_FIXTURE_ROOT`, a trusted test-process environment variable.
It introduces no application configuration key or runtime code path.

- Unset: return `fallback_tmp_dir` exactly, with no filesystem mutation or
  cleanup registration. This preserves existing local/CI behavior.
- Set, including an empty value: fail closed unless the value is a canonical
  absolute existing real directory, every ancestor is a real directory with
  no symlink, the configured leaf is mode0700, and its UID equals the existing
  real fallback directory's UID. Wrapper independently proves that UID equals
  the executing account and the root belongs to this unique run on tmpfs.
  Reject relative paths, dot/parent aliases, missing paths, regular files,
  symlink leaves/ancestors and group/other-accessible leaves. Do not create,
  chmod, delete or repair the configured parent.
- Allocate exactly one cryptographically random lowercase-hex child with
  `File.mkdir`, not recursive creation or reuse. Parent runs under umask077;
  establish/check child mode0700 before use. Exclusive collision is failure,
  not permission to clear an existing directory. Check child UID/type and
  parent/ancestor device-inode identities again before returning its path.
- Use existing `:crypto`/`Base`/`File`/`Path`; no dependency or shell command.
  Errors use a fixed test-only message, not environment/path/content dumps.
- No helper deletion, on-exit cleanup, retries, failure swallowing, process
  stop, lease revoke or DB action. On allocation failure leave any newly
  created child for root's later owned cleanup; fail the test. Tests retain
  their real original `storage`, `export`, `backup` siblings under the child.

The private parent prevents untrusted users replacing children; same-UID hostile
mutation is outside this test harness's security model. Identity rechecks detect
observed replacement but are not an atomic openat-style adversarial filesystem
guarantee. Do not claim a stronger filesystem sandbox.

Dedicated contracts cover unset exact pass-through/no mutation; private root
success; distinct children;0700 mode/UID; fixed failure on empty/relative/missing,
file, exposed-mode and symlink/ancestor-symlink roots; invalid parent unchanged;
existing sentinel unchanged; no cleanup callback or hidden deletion. Run these
nonasync with environment restoration. Do not require privileged chown to test
UID rejection or manufacture a proof absent a portable local fixture.

## Run namespace and real filesystem semantics

Root creates one private real directory under existing `/dev/shm`, with separate
`pgdata`, `socket`, `tmp`, `fixtures` and private run-evidence siblings. All are
owned by the current account and mode0700. Root records absolute paths, filesystem
type, device/inode/UID/mode, available memory/tmpfs capacity and a unique run ID.
The new wrapper exports the new PGDATA/PGHOST/PGPORT, existing MIX_ENV=test and
MIX_DEPS_PATH, `TMPDIR=<run>/tmp`, and
`SINGULARITY_TASK16_FIXTURE_ROOT=<run>/fixtures`. It constructs the provisioner
URL from that exact socket/port and requires every expected path/identity before
`exec "$@"`. It must not fall back to the host's default socket or database.

Storage.TestEnvironment.allocate!/0 already derives its isolated storage root
from `System.tmp_dir!()` and supplies separate backup/export siblings. No change
to that production harness is needed. Preserve the actual isolated database
suffix and ordinary cleanup lifecycle; keep role verification and migrations.

Tmpfs is a real kernel filesystem: actual files, permissions, reads, hashes,
encrypted originals, directory identities, rename/removal and unmodified sync
calls still occur. PostgreSQL remains the real engine with actual transactions,
locks, WAL, COMMIT and durability settings. This is not a mocked filesystem or
database. Tmpfs is volatile, however: successful fsync/COMMIT here does NOT prove
power-loss persistence, host ext4 durability, recovery after host restart or
durable storage performance. Record that limitation on every new environment
receipt and the eventual local qualification summary. Tmpfs may use swap;
available space is not a guarantee against memory pressure or all host I/O.

No allocation-based stress test, host disk filling, external process termination,
new mount, tuning, permission expansion, fsync disablement, `--no-sync`, timeout
increase, filter, skip, seed change, assertion weakening or service auto-start.
If capacity/pressure becomes unsafe, stop starting new commands; only root may
perform safe owned shutdown, preserving incomplete/failed outcomes.

## PostgreSQL transition and rollback

Old owned cluster: PID21905 at
`<worktree>/.devenv/phase5-pg.0LPElO`, socket
`/tmp/singularity-phase5-socket.hzWDT0`, port5432. Version17.10 binary:
`/nix/store/y83y08rgfv0zag50cvq55aqx9hyc2ldv-postgresql-17.10/bin`.
Old wrapper `.devenv/phase5-pg-command.sh` SHA256
`66a4ace46937b352ca16e3099ce8d0c0b7d65338aba5e2cdacc5cccf788d19b5`;
old start script
`.devenv/phase5-task11-v3-saga13-native109-private-pg-start.sh` SHA256
`b018410f21663c94174f3e23000d59a2de8772bd2456d4951a409f3256352d78`.
All were verified by reading/hashing here; no database command was executed.

Before any stop, root waits for121 and every current VM/ordinary post to close.
Revalidate PID executable, UID, full PGDATA, postmaster start identity, socket,
port and server-reported data_directory against the old owned tuple. Record
actual version, effective `fsync`, `synchronous_commit`, `full_page_writes`,
WAL/storage-relevant settings, locale/provider/encoding, local authentication,
listen addresses, required extensions and role/bootstrap state. SQL/database
reads belong to root's later execution phase. Do not infer missing locale/auth
details from this design or dump credentials, role passwords or secret files.

Require zero task test clients/open transactions and an actual ordinary EMPTY/0
post. Root may then request graceful `pg_ctl ... -m fast -w -t60 stop` only for
the freshly verified old PGDATA. This is PostgreSQL's orderly shutdown, not a
SIGKILL. If it times out, the old cluster is not proved stopped: retain the
block, inspect owned state safely, do not start another cluster or escalate
signals. Preserve the old directory, socket directory, wrappers and logs.

Initialize an empty fresh RAM PGDATA with the exact17.10 binary, standard sync,
matching observed locale/provider/encoding and local auth. No pg_resetwal,
data copy, role relaxation or imported production data. Matching parameters
must be resolved into a recorded initdb argv before running it. Keep TCP
disabled and a new private Unix socket. Start only after old shutdown is
verified; verify the new PID/start/data/socket identity and actual settings,
including fsync=on, synchronous_commit=on, full_page_writes=on. Preserve matching
other relevant settings or stop for an explicit reviewed difference. A missing
locale or extension is BLOCKED_ENV, not permission to substitute it silently.

Run the unchanged bootstrap_roles.sh via the new wrapper, then normal
RoleVerifier/TestEnvironment lifecycle with the established external provisioner
connection. Establish search extension availability and normal migrations in
the fresh cluster; no copy of databases/users from production. Bootstrap and
native invocations remain serial. Root alone controls the sole VM/service lane.

Rollback: after all new commands/VMs close and the fresh cluster is orderly
stopped/verified, restart the preserved old cluster through its unchanged start
script and wrapper. Revalidate identity/settings and ordinary residual post.
Never run both clusters concurrently, modify host PostgreSQL, delete the old
cluster, or report old117 repaired. If old stop/restart cannot complete because
of journal pressure, report BLOCKED_ENV; do not force progress.

## Attestation, validation and completion boundary

Before edits, record complete C13 bytes and the clean Snapshot owner hash.
After edits, require two exact unique context-anchored reverse replacements to
recover those whole files byte-for-byte. New helper/tests have their own full
hashes. The other27 C13 entries stay identical. Original56 remains unchanged:
54 actual byte-identical entries and exactly the two existing qualified inverse
exceptions; this proposal adds no frozen exception. All previous inverse chains
and raw baselines remain authoritative. Extend only forward attribution tooling,
never its historical inputs. Attribution-only transforms must never load into
Mix, PostgreSQL, runtime execution or live tests.

New source-candidate and environment attestations are separate. An environment
receipt records toolchain/profile, wrapper/initdb/start hashes, actual identity
and settings, roots and mount, source manifest, exact inner argv, fresh raw path,
natural exit, executed/excluded cohort and immediate own ordinary post. The
old C13 guard is immutable: derive a named successor that checks the exact new
candidate and recovers C13 before its historical source checks. Separate its
old PG ownership condition from the new cluster identity; never suppress a
guard failure or replay an old environment success marker as current evidence.

Mandatory replay remains exactly:

```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs --seed 215378 --warnings-as-errors
```

It must naturally finish with all135 actual cases (118 native +17 SQL Snapshot),
zero failures, unchanged11 exclusions/146 reported, followed immediately by its
own new ordinary `psql --dbname=postgres --no-psqlrc --tuples-only --no-align
--file=.devenv/phase5-task11-residual.sql` yielding actual EMPTY/0 on the new
cluster. Additional helper contracts run separately so cohort comparisons stay
exact. Preserve all warnings; investigate unexpected count/filter changes.
Any failure stays FAIL and blocks acceptance. A successful replay supplies new
evidence; it neither erases117 nor proves its sole cause.

Run all remaining existing Task16 gates on the final frozen candidate, including
the original API/startup/architecture owners, committed-transfer Native/Storage
both-order gates, exact attribution and complete permitted README verification
before phase acceptance. Retained results are reusable only for exact unchanged
source/environment assumptions; do not silently carry database gates across the
new cluster or compiled-source claims across a new build. Zero xref cycles,
seven-application graph, independent SOURCE SPEC then new distinct QUALITY,
and final reviewed local-commit readiness remain required.

Fresh MIX_BUILD_PATH is not required by this minimal proposal. If root selects
it to reduce build I/O, treat that as a separately attested environment step:
fresh full compile, no copied/stale BEAM credit, verify actual loaded code paths
and the ingest Makefile's MIX_APP_PATH/priv output target (including symlink
resolution), then rerun applicable checks. Do not claim relocation from the env
variable alone or silently redirect dependencies. Persistent build/log stalls
may remain BLOCKED_ENV rather than justify further changes.

Capture fresh private raw logs and receipt hashes. If logs temporarily live on
tmpfs, archive exact bytes/hashes into a new private persistent evidence path
before acceptance or deleting the RAM run. Never overwrite historical raws;
archiving failure means evidence closure is incomplete. No cleanup may supply
credit for product-owned artifact removal. Preserve fixtures until strict
assertions, all owned tasks/VMs and PostgreSQL have closed. Eventual root cleanup
requires exact recorded run identity, no replacement/foreign child uncertainty,
and all evidence archived; otherwise preserve and report the residual path.

Task16/Phase5 remain UNACCEPTED pending actual results. Task17 remains dependent.
E2E NOT RUN/manual-deferred. No merge, push, version/tag/release, deployment,
activation, backfill, production data or expanded Vault work.
