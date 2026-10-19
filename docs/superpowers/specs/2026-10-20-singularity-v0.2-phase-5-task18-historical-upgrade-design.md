# Task18: historical native population, same-A upgrade and default-V3 restore

Status: CANONICAL DESIGN FOR INDEPENDENT REVIEW. No Task18 implementation GO.
Date: 2026-10-20. Baseline: `d054d58155ab119a17cbcbd36f11ba3a23d44e1e` on
`codex/v0.2-phase-5-export-backup` in `.trees/v0.2-phase-5-export-backup`.
Task17's postcommit check was clean and its qualification server is stopped;
the current candidate changes only this design, its plan and AGENTS status.
Companion: `docs/superpowers/plans/2026-10-20-singularity-v0.2-phase-5-task18-historical-upgrade.md`.

## 1. Governing scope and correction

The worktree AGENTS and Phase5 design/plan, especially master Task18, govern.
Task18 depends on qualified Tasks11/12/17; their local source prerequisites are
now met. Independent DESIGN SPEC then a new distinct QUALITY
and parent source ownership are required before implementation. Continuing
authorization permits the recommended in-scope architecture without another
routine human approval; it does not waive dependencies or review.

The three private earlier draft pairs remain immutable evidence, including
draft1's actual DESIGN SPEC REQUEST_CHANGES and draft3's ordered design PASS.
This canonical revision retains draft3's private bounded stderr/log transport
and architecture, binds the actual Task17 prerequisite, and specifies the missing
existing-A population seam. All Task18 runtime qualification remains NOT RUN.
The selected architecture replaces draft1's assumed current-constructor legacy population and
stop/reacquire infrastructure sequence. Current JobSubmission reads post-v0.1
wake columns; current Asset deletion calls the post-v0.1 Document pin function.
The infrastructure owner rejects a second start even after its stored PID dies.
Neither finding can be closed by trying the draft1 instructions again.

The selected correction runs native historical source in a separate child VM
during explicit owner-controlled preparation. That VM closes before A becomes
ready. Current runtime starts once, only after same-A forward migration.
Historical source evidence is retained in
`.devenv/phase5-task18-legacy-architecture-draft1.md` (SHA256
`1c6427629f54f87a948c61b6eadf8ab5e3d8c59ab140b49ba329399e88b48efa`).
This complete canonical document, not an unavailable private draft, defines the
implementation contract. The advisory counts as architecture1, not a repair.

Canonical candidate1 received DESIGN SPEC PASS followed by NEW distinct QUALITY
REQUEST_CHANGES for two Important compatibility gaps: historical MIME/payload
selection and native UTF-8 child boot. Its exact three-document bytes and both
receipts remain retained privately. This candidate resolves those findings below;
neither the earlier PASS nor this correction supplies implementation GO. These
are design corrections, not failed implementation repair rounds.

This is historical source/schema upgrade qualification on the current test
toolchain, not an old release binary deployment, remote release verification,
production upgrade, replacement activation, Phase5 acceptance or E2E.

### 1.1 Actual Task17 prerequisite and bounded local handoff

Task17 has qualified local source acceptance at
`d054d58155ab119a17cbcbd36f11ba3a23d44e1e`, tree
`90e4a13dfe23740333a530dbf52c709219e3dca5`, parent
`a0fb0f854509cb69e42ec598deb6aa2f4116729f`.
Its subject is `test(export): prove portable bytes source closure and denial cleanup`.
The commit contains exactly11 reviewed/tested files, four modified and seven new,
12135 insertions/two deletions. The exact file/SHA256 list is preserved in
`.devenv/phase5-task17-format-postwrite-format11-observed.sha256` (SHA256
`679acf301c63a1a01b8b3259b81fefe592e500e1b91431d7c5fa76fcf7307342`).
The durable changed-file inventory is the exact commit's `git diff-tree -r`;
all11 committed blobs and working files were independently matched to that
tested manifest after the commit, with1076 committed leaves and clean status.

Actual final gate bundle:
`.devenv/phase5-task17-final-gate-bundle1.json`, SHA256
`8b5d32c4caa0b4d3d9e24d440b01677523fc01654c306b5b73fd3ac4b1125cfe`.
It records complete outer/inner argv/environment, executable/source pins,
raw output, natural statuses, before/after facts and separate ownership posts.
Every final gate ran the same exact11-file source and exited naturally0.

| Final whole gate/run ID | Actual result |
| --- | --- |
| `postwrite-pure9-final2` | Storage216/0; Runtime250/0/17integration-excluded |
| `postwrite-arch5-final2` | 425/0 |
| `postwrite-formatcheck-final2` | format check0 |
| `postwrite-compile-dev-final2` / `postwrite-compile-test-final2` | warnings-as-errors compile0 in both environments |
| `postwrite-xref-dev-final2` / `postwrite-xref-test-final2` | no cycles, natural0 in both environments |
| `postwrite-privacy-final2` | actual integration2/0 |
| `postwrite-native2-final2` | actual native/snapshot integration146/0/11nonintegration-excluded |
| `postwrite-live7` | complete live owner33/0,638.9s |
| `postwrite-master2` | all four whole owners62/0,698.3s |

Every gate's own next ownership post was actual EMPTY/natural0. Before/after
facts retained SHA256
`041213c1974e07501454da81f65fe1eda33cad040c766b97a01e959f2ee16689`,
with no after-facts/source/Mix-authority errors. The master inner command was:

```sh
env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_live_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_privacy_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_export_integration_test.exs apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs --seed 215378 --warnings-as-errors
```

Actual ordered SOURCE SPEC then NEW distinct SOURCE QUALITY were fully read and
verified by root before closure and commit:

- `.devenv/phase5-task17-final-source-spec.json`, reviewer
  `/root/task17_final_source_spec`, DONE/PASS/no findings, SHA256
  `009ff8a8b1095f338ab695bdb6572701fdfc6500943b6d6acd9c2ff695013810`.
- `.devenv/phase5-task17-final-source-quality.json`, reviewer
  `/root/task17_final_source_quality`, DONE/PASS/no findings, SHA256
  `fa10654b03129c25122b6a620042b9c3ecdddd17b8e9a46e5d55bb6a24e005d5`;
  its exact preceding-SPEC pin names the actual receipt above.

Root then ran the independently reviewed fixed closure wrapper in order,
one mode at a time, inspecting each actual result before its successor:

```sh
/nix/store/3307vfpkpybyzf4w7mcn1pavnylsvb35-nodejs-slim-24.19.0/bin/node .devenv/phase5-task17-closure-capture-candidate1.js post
/nix/store/3307vfpkpybyzf4w7mcn1pavnylsvb35-nodejs-slim-24.19.0/bin/node .devenv/phase5-task17-closure-capture-candidate1.js stop
/nix/store/3307vfpkpybyzf4w7mcn1pavnylsvb35-nodejs-slim-24.19.0/bin/node .devenv/phase5-task17-closure-capture-candidate1.js archive
```

All three exited naturally0, no signal/error. Final post was0bytes/EMPTY;
actual owned PID2815435/startTicks20564354 was stopped normally using its fixed
data/socket/system7698329256660747305 identity. Actual control state is
`shut down`, exact PID/postmaster/socket/lock absent, and no worktree-owned BEAM
remained. The archive is byte-identical to its retained original:
1058855bytes/SHA256
`02c029750aff610a7dcaa6389f30d430353223437cc1b54a64da097713228e0b`.
PGdata/fixtures/probe/historical evidence were retained, not deleted.

| Actual closure receipt under `.devenv/` | SHA256 |
| --- | --- |
| `phase5-task17-qualification-run-task17-final-post-result.json` | `bc87d6a00f89dc5ddc88af47880c8d505ff3a91b7bd3922d45de29a236af8d0d` |
| `phase5-task17-qualification-stop-result.json` | `413d823c6993accf6140b957c4315c4b6ba455de9b6f7fb4d5d8ff6b9211a814` |
| `phase5-task17-qualification-archive-capture-result.json` | `fd5ea0edc57d6b402afaf668c1c4851f486416404463136dba010975d62c9748` |
| `phase5-task17-qualification-closed-ram-archive.json` | `27c431d40f300fd7da8bbc7469d68f4a8498bc68f883e6b623167e4253d3120a` |
| `phase5-task17-postcommit-acceptance.json` | `63e57d3d76abeb7dd15fd237f0debe3c14e0029d72c6e13e81a6085ad659801a` |

This local handoff is bounded to Task17. No new migration, permanent grant,
dependency, native custody or Vault feature change occurred. Its source deltas
are trusted internal Writer I/O forwarding, fixed digest backing detachment,
additive attribution and new tests/support/design/plan. The1/501 shared body,
180000ms cases, ENOSPC and every old assertion are preserved. Logical metadata/
backing checks are not RSS/heap guarantees; ENOSPC is an actual injected I/O
failure, not physical disk exhaustion. All22 failed historical primaries remain
failed, including master1's49/14/natural2; actual oracle causal RED33/1/32,
GREEN33/0/32 and paired unchanged Note27/0 remain diagnostics, not whole gates.
E2E NOT RUN/manual-user-deferred. Task18/19, full README/Phase5, browser,
product/release and production acceptance are not supplied by this handoff.

### 1.2 Selected architecture and alternatives

Use one fixed historical source child during surviving-owner preparation.
This executes genuine old constructors without current schema assumptions and
leaves the parent's current infrastructure slot unused until forward migration.
A current-VM legacy SQL adapter is rejected: it would reimplement native job
submission/deletion protocols and no longer prove genuine old population.
A second current-supervisor start is rejected: it violates the existing
already-started contract and does not solve old-schema incompatibility.
A full historical checkout/container is rejected: it adds old Mix/web/build and
runtime Git/network dependencies beyond the fixed source proof. The fixed
corpus costs checked-in data and a bounded child, not a general version loader.

## 2. Frozen historical inputs

Use local commit `c49dc0aeda1d0115b20ff291f0da658f7e558b43`, local tag `v0.1.0`,
subject `merge: verify release exporter equivalence`, root tree
`f68e1ed5507780db1e3c024e7f387557ac75f23b`.

The Storage fixture contains exactly22 migration files through
`20260818000100_create_private_markdown_notes.exs`. Its historical tree is
`203135f6e35b72aaab269b75a30dcf2ef080bfe3`; sorted
`filename TAB git_blob TAB sha256 LF` fingerprint is
`5e3c5b3ad94f294379a00c80136617910c3537fc8a6288266ecc9a53e5f6eb62`.
Freeze these actual bytes and an explicit source.json in
`apps/singularity_storage/test/fixtures/upgrade/v0.1.0/`. A current ceiling is
not acceptable provenance. B always uses current migrations.

Separately freeze 253 historical source files: all251 files under
`apps/{singularity_core,singularity_domains,singularity_storage,singularity_ingest,singularity_retrieval,singularity_runtime}/lib/singularity/`,
plus `config/config.exs` and `mix.lock`. Exact raw total: 2,135,469 bytes.
Sorted `original_path TAB git_blob TAB sha256 LF` fingerprint:
`d7506f511de599dfb92cd2313f843abb27ca26eafd3bf89939ecbf07e2a22924`.
Store them as inert
`apps/singularity_runtime/test/fixtures/legacy_v0_1_0/sources/<original_path>.source`
with separate source.json containing original path, fixture path, blob and digest.
No source rewrite, namespace rewrite, generated substitute or fallback to
current files is permitted. Historical code never enters normal compilation.

Both validators require fixed reviewed count/order/path/blob/digests/fingerprint,
exact directory inventory, regular files and no symlinks. Reject extra/missing/
duplicate/reordered/renamed entries, current-file substitution and changed bytes.
Expected fingerprints are independent literals, not regenerated from fixtures.
Coordinator verifies initial provenance against local Git before review; ordinary
tests use checked-in fixtures and require neither Git history nor network.

The source corpus is a single fixed data fixture, not a new application, vendored
dependency, arbitrary-version loader or nested historical build framework.

## 3. Historical VM boundary

A new test-only runner script and parent helper own this fixed operation.
Use argv, never a shell. The child receives only standard OTP/Elixir paths,
verified external dependency ebins, its private historical output directory,
and the fixed runner script. Clear inherited project code-path injection;
reject all current Singularity ebins before compilation and after population.
Do not pass credentials/content through argv or environment.

Pin child Elixir argv to separate `--erl`, `+fnu` entries before the fixed runner;
this sets native filename encoding to UTF-8, not a performance/deadline override.
Clear inherited Erlang/Elixir startup injection and require
`:file.native_name_encoding() == :utf8` in the runner before compilation.
Keep parent/PostgreSQL locale and all ordinary gate argv unchanged. Actual
Task17 native2/master2 logs retain the latin1 boot warning under `LC_ALL=C`;
ignoring/filtering it would violate the frame contract. Qualify a clean child
under that same inherited C locale with the fixed switch, plus a controlled
no-switch boot-diagnostic rejection through the same bounded private transport.
Do not suppress compiler warnings, change locale or add other VM tuning.

The existing historical lock entries equal the current ones at this baseline;
current mix.lock has only an additional ex_cmd entry. External application roots
are ecto_sql, postgrex, oban, argon2_elixir, logger_json, telemetry_metrics and
telemetry_poller and their dependency closure. Compare exact lock entries,
application versions and actual ebin provenance. Missing/mismatched dependencies
fail before database work; never fetch or substitute them. Parent-side ExCmd is
already present and is not passed into the historical child.
The Runtime wrapper performs both source and external-dependency checks before
calling open_legacy_v0_1_0; the acquisition callback repeats the identity check
before child compilation. A changed fixture between those checks fails closed.

Compile the251 source files in the child with Kernel.ParallelCompiler into its
owned private directory. Use no old Mix tasks, test support, web modules or
current Singularity modules. Read historical config/config.exs through
Config.Reader with env :prod; it imports no test/dev config in that mode.
Overlay only test database connection values, root locations, test fingerprint
secrets, explicit bootstrap capabilities, and controlled manual job options.
Start actual historical repository and runtime child specifications; do not
start a fake authorizer or a current Runtime.Application.

Check all loaded Singularity module origins before native work and again at
completion: historical output directory and original source metadata must match
the corpus. Record toolchain and dependency identities privately. Compile
failure, unknown module origin or a native source incompatibility is a failed
prerequisite, not authorization to patch the corpus or frozen production files.

## 4. Explicit preparation ownership

Add test-only `KnowledgeFixtureResourceOwner.open_legacy_v0_1_0(prepare)`.
It accepts exactly a trusted local arity2 preparation function and selects the
fixed22 migration source with migration_pool_size2. Return
`{owner, destination, legacy_receipt}`. Existing open/open_child signatures,
options and behavior remain unchanged. No arbitrary migration path is added.

Thread preparation separately from ordinary options into
MigrationTestEnvironment's owned acquisition. After frozen migration and the
existing five owned repo starts, but BEFORE ready/reply, call prepare with
`destination` and `%{caller: caller_pid, report_cleanup: report_function}`.
The report function updates only owner-local preparation state and accepts
`:running`, `:closed` or `:unconfirmed` with content-free failure categories.
Preparation success is legal only after :closed. The normal test callback is
never executed in the owner; observation checkpoints remain observation-only.
Reject invalid preparation/options before allocation. Child B cannot choose
the legacy preparation entrypoint.

The Runtime helper is invoked in that surviving owner and owns ExCmd directly.
Set :running before launch; obtain its handle before sending bounded framed
configuration over stdin. One monitored reader (and writer if required) may own
pipes. The owner monitors the original test caller, receives helper/native exits,
enforces a 45,000ms execution deadline plus a 5,000ms cleanup allowance, and calls
ExCmd.Process.await_exit itself on EVERY
terminal path. The owner already traps exits; explicitly consume relevant ExCmd
EXIT messages and preserve cleanup rather than treating a linked exit as success.
Those are new helper bounds, not increased existing ExUnit/product deadlines.
Use one version1 length-prefixed JSON frame each way: unsigned32-bit big-endian
byte length, then UTF-8 JSON, with 16KiB input and 64KiB output limits. Input keys
are exactly protocol, source_fingerprint, database, database_oid, object_root,
build_root, repositories, credentials and originals. Repositories has exactly
migration/request/pre_auth/dispatcher/worker connection maps, copied from the
owned parent bindings with database A and the respective existing role. Credentials
contains login/password; originals has exactly `text_pdf_base64`,
`binary_png_base64` and `deleted_png_base64`, containing the parent literals
from §5. The trusted runner fixes their MIME types; input cannot select arbitrary
MIME declarations. No
original exceeds 1KiB in this bounded legacy fixture. Output keys are exactly
protocol, source_fingerprint, owner, notes, assets and work. These are the typed
identities/digests/lifecycle receipt from §5; they carry no credentials/content.
Parent-side database observation independently checks all returned identities.
Reject extra
frames, trailing bytes, duplicate JSON keys, missing/unknown keys and noncanonical
UUID/digest/length fields. No arbitrary MFA, code, SQL, codepath or command field.
Compilation files live in a separate private subdirectory of A's owned allocation,
outside object_root. Close/remove that helper workspace after confirmed child
exit and before ready; never include compiler artifacts in the object oracle.

Private diagnostic transport is mandatory. Installed ExCmd.Process has
@default_opts stderr: :console despite the prose claiming a different default
(deps/ex_cmd/lib/ex_cmd/process.ex:299,348-363). Launch explicitly with
stderr: :redirect_to_stdout and log: nil. This is the existing ExCmd transport,
not a custom process runner or dependency change. :console/inherited console
and :disable (/dev/null) are forbidden: neither leaking diagnostics nor silently
discarding them can produce a successful historical receipt. ExCmd's middleware
log stays disabled (process/proto.ex:194-197); do not pass a log file or attach
raw child data to parent Logger/telemetry/error terms.

Stdout and stderr therefore form ONE private bounded byte stream, with no
source-channel or ordering assumption (process.ex:130-168). Read through the
existing monitored pipe worker in chunks at most4096 bytes. The declared JSON
payload limit is65,536 bytes plus its4-byte header; incrementally reject a
larger length immediately. Limit each read to min(4096, remaining frame budget
plus one), checking the byte budget before retaining data. Retain at most that
frame plus one trailing-byte probe, then require actual EOF and successful
child exit before accepting it.
Do not accumulate arbitrary diagnostic output, drain it into a list/string,
scan for a later valid frame, trim warning lines or decode a last JSON object.
Any non-frame diagnostic prefix/interleaving/trailer is protocol failure;
duplicate JSON keys, extra frames and trailing bytes remain strict failures.
Merged bytes cannot identify which descriptor wrote them; the trusted fixed
runner writes only its one receipt frame, and real clean output is qualified,
not inferred from an indistinguishable stream or a synthetic child's success.

Use fixed content-free categories: an oversized declared length/total stream is
:legacy_output_limit; check the byte ceiling before protocol parsing. At the
full65,540-byte frame boundary, an additional probe byte is :legacy_output_limit;
for a shorter frame a trailer is :legacy_protocol. Other malformed/extra/
duplicate-key output is :legacy_protocol; a reader failure is :legacy_pipe.
Preserve the first observed primary category plus a separate cleanup failure,
without exception messages, stacktraces, raw frames, child exit text or canary
values in outward errors,
Inspect, logs or telemetry. Catch reader/writer/driver exceptions at the trusted
helper boundary without re-raising raw diagnostic terms or crash-reporting
buffer-bearing state; retain only bounded private test observations. Child
compiler warnings, runtime exceptions and ordinary Logger/stdio bytes all enter
the same bounded private channel and fail closed if they disturb the frame.
A real historical native success must demonstrate exactly one clean frame,
EOF and exit0 under this configuration. Do not filter diagnostics, suppress
compiler warnings or alter historical source to obtain that positive result;
an incompatibility requires diagnosis and an evidenced amendment.

All diagnostic/oversize/reader failures still take the surviving-owner
terminate/await_exit path below. They never imply :closed, ready or A destruction
before actual child exit, pipe-worker DOWN and connection absence; unconfirmed
termination still quarantines the exact A allocation. This amendment adds no
timeout, extra receipt channel or helper-cleanup credit.

On success, require a complete typed receipt, exit0, all pipe helpers DOWN,
child-owned database connections gone and closed cleanup state. On caller death,
nonzero exit, pipe/parse/deadline failure, terminate/await the owned child before
propagating the primary failure into normal A cleanup. Use ExCmd's bounded exit
sequence; do not send process-wide signals or stop unrelated processes.

If termination cannot be confirmed, report unconfirmed, retain primary and
secondary cleanup failures, and quarantine A's exact database/root. Owned cleanup
must not DROP or remove that root while an external writer may remain. This
exception is restricted to the new preparation state; ordinary fixtures retain
their existing cleanup behavior. Never report ready or a successful cleanup
receipt for quarantine. Parent diagnosis is then required; do not hide it with
manual deletion. Force-killing the surviving resource owner/whole test VM is
outside the helper's guarantee, as in the current owner protocol.

The parent VM's five repos retain their exact PIDs/database A throughout legacy
preparation and migration. The child has separate historical repo processes
connected to the same A; they close before ready. Parent infrastructure remains
nil. No restart/replacement/reset is needed to start current runtime later.

## 5. Native legacy population and pre-upgrade capture

Parent supplies fixed literal text/binary inputs and private generated credentials.
Historical BootstrapOwner creates a real owner and recoverable keys. Historical
Api.login/resolve_session/unlock establish the authenticated session. Upload via
real grant/begin/chunk/finish; dispatch and drain actual verify/finalize workers;
native download must reproduce literal input bytes before any forward migration.
The text-bearing live Asset is a fixed valid ASCII-only PDF declared
`application/pdf`. The binary live Asset is a fixed valid PNG declared
`image/png`, containing NUL/high bytes and a valid IHDR/CRC. Both parent literals
are at most1KiB; require distinct bytes and independent digests. The separately
deleted Asset uses a third fixed valid PNG literal with different bytes/digest
and its own native upload/Asset/object identity. This prevents a live witness's
shared object reference from invalidating genuine orphan cleanup. All three
originals remain parent-owned literals at most1KiB, not fabricated publications.
Historical UploadRequest accepts only PDF/JPEG/PNG with matching magic, and its
PDF/PNG metadata parsers check the format. Do not relabel arbitrary raw text as
PDF, declare `text/plain`/`application/octet-stream`, reuse current plain/Markdown/
empty inputs, or bypass those checks. Historical zero-byte finish is unsupported
by source characterization, not a positive witness or an implementation repair.
Keep any actual negative characterization distinct from native success.

Historical public Note create/save/merge/delete build initial and accepted
versions, one open conflict, a separate resolved conflict with merge lineage,
and a tombstoned Note retaining its history. No current source-set plumbing runs
on this schema. Do not copy AssetVertical's synthetic sessions/random wrapped
keys, use KnowledgeFixtures.source! metadata, or synthesize publication/deletion
rows. Preserve actual event/submission/progress/effect provenance from the native
jobs. Finish needed metadata/projection jobs deterministically, while leaving
the genuine orphan cleanup work pending rather than expiring retention clocks.
Specifically drain `:asset_cleanup` for the deleted Asset, then emit/dispatch its
real `object.cleanup_requested` submission but do not drain `:object_cleanup`.
Historical retention defaults to0: pending here means unexecuted genuine work,
not proof of a future retention interval. Do not advance or rewrite clocks.

Child receipt contains exact owner/resource/version/conflict/Asset/object/event/
submission identities, literal-input digests, observed lifecycle outcomes and
source identity. Credentials, keys, full rows and content never enter logs,
telemetry, exception text or outer test failure diffs. Pipe output is bounded and
private. Reject malformed/oversized/unexpected output without echoing it.
Historical BootstrapOwner also returns `credential_hash`; serialize only its
approved account/credential/principal/owner-scope identity fields, never the
whole result. The work receipt includes the observed UTF-8 native-name mode.

After historical VM exit, parent independently reads explicit old-schema columns
and snapshots every old table row and owned physical file. Capture A name/OID,
root device/inode, exact22 ledger, repo PIDs and original bytes/hashes. Independently
check receipt associations, tombstones, source/version ownership and durable
provenance. This snapshot is not derived from V3 exporter or restored output.

## 6. Same-A forward migration and current knowledge

Apply all29 current forward files at this baseline to SAME A using real
Ecto.Migrator/MigrationRepo. No reset, dump/reimport, TRUNCATE, ledger editing,
early forwards, disabled guards or rewritten released files. Require original
database/OID/root identity, fixed22 prefix and exact reviewed forward ledger delta.

Compare every legacy row projected onto its original columns and every retained
physical byte. For the selected native population, require exact original-column
equality across application tables in identity/core/content/jobs/audit, with NO
allowed original-column transformations. Compare schema_migrations separately as
the exact22 prefix plus29 forwards. New counters are checked against captured
legacy metadata and active reconciler generations using the independent rule
requested=max(legacy_requested, legacy_consumed, active_requested),
consumed=legacy_consumed, absent values0. The selected no-wake fixture must also
prove those inputs are0; do not assume it. Never omit timestamps or whole tables.
Independently verify other new defaults
and one complete empty derived source seal per historical Note version with
zero source members. New knowledge tables remain empty where specified.
Assert actual constraints, deferral/validation flags, enabled guards, RLS/FORCE
RLS, owners, pinned search paths and ACLs. Retain runtime/preauth/spoofed-GUC
denials for admission, sealed membership and canonical writes.

Only now call NativeAssetFixture.start_runtime! once on A. Authenticate afresh
with the preserved owner credentials. Populate current Documents through public
import/real extraction, current sealed Note attachments/citations, tags and
relationships through Task17's accepted contracts and the explicit seam below.
Include retained Document originals after source Asset deletion.
Preserve all legacy witnesses. Scoped test grants must restore the exact prior
ACL state; production-role write closure remains asserted outside the scope.

### 6.1 Existing-A current population, without fixture ownership theft

Actual Task17 `with_fixture/1` allocates/bootstrap/closes a fresh native
installation; it is not an existing-A API. Its public `publish_sources!/1` and
`build_graph!/1` require private inputs/root/permission-journal state. Its finalizer
requires the original live MigrationRepo, and `assert_quiescent!/1` preserves
the pre-backup inventory. Neither can be put around Task11 parking/backup.
The original source at the accepted Task17 commit remains the strict baseline.

Add only test-support
`KnowledgeExportLiveFixture.with_existing_runtime(native, callback)` with a
trusted local arity1 callback. `native` is the actual map from A's single
`NativeAssetFixture.start_runtime!(owner,destination)`, merged with the preserved
credentials and freshly authenticated session. Validate the owned database/root,
actual owner/infrastructure/five repo PIDs, matching credential owner/session
and original registered MigrationRepo before effects. No arbitrary owner/root,
repository selector, code or product configuration is introduced.

The constructor initializes its own minimal private population state, including
the existing independent inputs and a scope journal owned by a temporary child
under A's existing infrastructure. It registers that child before any GRANT.
It reuses unchanged `permission_scope`, `publish_sources!` and `build_graph!`;
callers must not fabricate the old fixture's lifecycle Agent/collector maps.
No export trace/lease collector, artifact root/sentinel, new custodian or second
runtime start is needed just to populate data. The existing standalone Task17
fixture, finalizer, barriers, native cleanup and every assertion stay unchanged.
Keep all new seam code in one marked additive block so removing that exact block
recovers the complete accepted Task17 fixture SHA256
`7bd3ac5feec3ae3ee3c0cfda3f2cd5ebc713ddef3d7ef0618a9deaeae2d0004a`.

The Task18 call is deliberately completed before backup/parking:

```elixir
native = Map.merge(runtime, %{credentials: credentials, session: session})

population =
  KnowledgeExportLiveFixture.with_existing_runtime(native, fn fixture ->
    fixture = KnowledgeExportLiveFixture.publish_sources!(fixture)
    fixture = KnowledgeExportLiveFixture.build_graph!(fixture)
    Map.take(fixture, [:inputs, :sources, :graph])
  end)
```

Return the callback's private value only after every temporary ACL/effective-
privilege/role-membership snapshot is restored exactly, permission scopes empty,
the exact helper child DOWN/removed, and A's owner/infrastructure/repos/database/
root still match and remain usable. The callback cannot park or close A; such
misuse fails rather than receiving cleanup credit. The constructor never owns
or stops A. It does not call Task17's inventory-based `assert_quiescent!` after
backup or weaken its checks. The Task18 callback returns only the private
inputs/source/graph observations above, not helper control PIDs for later use.

Raise/partial setup unwind must restore localized ACLs while A is live and
remove only the exact helper child, preserving the primary and any cleanup
failure separately. If the original test caller dies, ResourceOwner remains
cleanup authority for A's actual infrastructure/repos/database/root; no generic
supervisor kill, process-wide signal or lingering database with scoped grants
can be called success. Parent tests prove actual owner cleanup in that route;
they do not mislabel database destruction as an observed ACL-restoration receipt.
Pre-existing legacy row/file witnesses are compared before and after population.

Add a complete integration owner
`apps/singularity_runtime/test/singularity/runtime/knowledge_upgrade_population_test.exs`
for native already-running-A success, exact ACL/child/identity restoration,
callback error/partial setup and original caller loss, plus wrong/dead/replaced
identity rejection before effects. Its simple current-schema A qualifies only
the seam, not historical upgrade. The same seam then runs in the genuine
upgraded A. Re-run the full Task17 live/privacy and affected architecture owners
after this additive fixture change; source-only attribution does not replace
their actual regressions.

## 7. Real defaultV3 backup and retained-A/new-B saga

Set the existing transparent
`KnowledgeBackupRestoreFixture.V3JobHandler` as A's job handler before its sole
current runtime start. Set `:knowledge_v3_test_observer` to exactly
`%{owner: preserved_owner, receive_cut: callback}`; its callback receives the
actual `KnowledgeCanonicalOracle.capture_worker_cut!(worker,owner,cut)` result
and returns `:ok`. The delegate preserves actual Exporter results. Do not use
the self-allocating/self-closing `backup_source!` helper.

Call Api.request_backup(session, passphrase) without logical_version override;
dispatch/drain the actual backup worker. Require sealed operation and matching
worker cut, owner and database. A transparent delegating observation captures
the independent38-table canonical projection at that actual cut. Authenticate
the produced bundle using the real reader; observe logical_version3 explicitly.
Keep the encrypted bundle in a separately owned0700/0600 backup location outside
both object roots, preserving its digest and cut. Do not call a self-closing
source fixture or replace the worker with a direct exporter invocation.

Use Task11's parked-installation helper to stop A infrastructure and exact global
repos naturally while retaining A owner/database/files and its private reader.
Capture the FULL private installation oracle after parking and before B opens.
Allocate B with ResourceOwner.open_child(A_owner, migration_pool_size: 2).
Add a Task18-local maintenance/configuration wrapper in the new Runtime helper.
It may copy the existing maintenance/configuration pattern, but
must not lie to Task11 child helper's closed-source precondition. A remains live
as retained data and reader. Require distinct B database/OID/root and empty root.

Run actual RestoreVault with the genuine BundleReader/import/rewrap/native
integrity lease/reconciliation/plaintext and Document verification/search rebuild/
completion composition through existing public
`KnowledgeBackupRestoreFixture.restore_context(destination,portable_root,hooks,%{})`
and `RestoreVault.run`. Required hooks are `after_import/1`, `after_rewrap/1`,
`after_complete/1` and `diagnostic/1`, returning `:ok`; existing Document/search/
inventory/native-lease observation hooks may be passed to observe real stages.
Transparent boundaries must observe real results and
maintenance-only B until completion. No ordinary B custodian/Oban/dispatcher,
public graph visibility or successful completion before all native verification.
Canonical import/object publication are not public activation.

Before dispatch recovery, compare every canonical table, history, tombstone,
source membership, immutable digest and ID against the independent A cut.
Assert the exact established key/credential rewrap and durable reconciliation
transforms separately; do not omit them wholesale. Reconstruct seals exactly once.
Check exact original closure, including Document-only objects. The deleted legacy
Asset's retained physical bytes belong in A preservation but need not be in B
inventory when V3's Asset-only closure excludes them; assert the actual lifecycle
and wire closure rule rather than demanding invented B bytes.

After genuine completion only, use the existing
`KnowledgeBackupRestoreFixture.start_controlled_runtime!(B_owner,B_destination)`;
preserve its deferred-extraction/canonical observation contract. Do not start B
again through NativeAssetFixture or recreate its configured backup directory.
Authenticate
with restored owner/new password, perform native original reads and public
Api.search_knowledge assertions for stable Note/Document/version/fragment/locator/
text values and deleted/old/nonready exclusions. Any lawful later recovery is
compared separately from the canonical cut.

Compare A's full private rows/files while B is live and again after B closes.
B must close its exact repos/children/leases/connections/database/root before A
reader/owner is released. Restore all application configuration exactly. Existing
Task11 parking does not resume A inside the callback; this design closes A after
the unchanged oracle rather than inventing a restart capability. Primary and
cleanup errors remain independent; no manual deletion supplies cleanup credit.

## 8. Acceptance, migration limits and handoff

The sibling plan lists test-first phases and complete required commands. Preserve
all V1/V2/native/source-set/admission/lifecycle tests and the original56 frozen
manifest, with only the already accepted two export-lease source exceptions.
The253 inert historical copies are not edits to that manifest or product files.
No new production migration or dependency is anticipated. A real new migration
defect requires an evidenced additive amendment/review; never change old bytes.

Actual offline child compilation, native legacy operations, finite execution
budget and Task18 cleanup behavior are NOT RUN. Task17 is accepted at §1.1;
the new existing-A seam is designed here, not already implemented. The parent
must establish a freshly reviewed Task18 qualification lane from the stopped
owned context without running historical Task17 primary tooling against new
HEAD/source. These are implementation prerequisites,
not inferred passes or reasons to weaken proof. Parent owns serial service/VM/SQL
execution, source pins, independent reviews and eventual small local commits.

Task19 still owns the complete permitted README campaign and Phase5 acceptance.
E2E NOT RUN/manual-deferred; no merge/push/version/tag/release/deploy/activation,
production data, frozen Vault semantics or excluded product work. This canonical
revision defines architecture for review, not Task18 GO or acceptance.

### 8.1 Exact source responsibilities and review boundaries

The initial documentation-only change comprises this canonical design, its
canonical companion plan and the narrow active-status paragraph in AGENTS.md.
Validate actual Task17 source/evidence/closure pins and local links, exact scope
and `git diff --check`; no VM/PG reopening is needed merely to record that handoff.
Obtain independent complete DESIGN SPEC then NEW distinct QUALITY on this exact
three-file candidate; root records GO and commits the design before code.

Implementation creates the exact22 historical Storage migration data and its
source.json, Storage `legacy_upgrade_fixtures.ex` and identity/lifecycle tests,
the exact253 inert Runtime source files and source.json, Runtime
`legacy_upgrade_runtime_fixture.ex`, fixed `runner.exs`, source/process/population/
upgrade live tests. Modify only existing test support ResourceOwner,
MigrationTestEnvironment and the marked Task17 fixture seam as needed. No product
source, released migration, lock/dependency or Vault/native change is planned.
Existing whole-source assertions and manifests are never rebased or normalized.

Root's formatter glob includes new historical migration `.exs` fixture data.
Their actual current-formatter compatibility is not yet measured. Preserve the
exact historical bytes; do not preemptively rewrite/exclude them. A demonstrated
format conflict requires an evidenced minimal amendment limited to immutable
fixture-data handling while retaining all established code-format checks.
The253 `.source` files remain inert normal compile/format inputs throughout.

Storage owns frozen22 validation/preparation acquisition and its lifecycle
regressions. Runtime owns fixed source-corpus validation/child/upgrade composition
and the explicit existing-A seam after the Storage interface is fixed. Parallel
pure fixture work is allowed; runtime/SQL/formatter/service/Git execution stays
root-exclusive and serial. Root fully reads worker source, runs test-first exact
commands, obtains independent source SPEC then fresh QUALITY before scoped
commits, and never advances a failing or unqualified dependency.
