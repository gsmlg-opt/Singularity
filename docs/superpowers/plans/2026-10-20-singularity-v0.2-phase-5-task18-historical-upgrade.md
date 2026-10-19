# Task18 Historical Native Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `subagent-driven-development` (recommended) or `executing-plans`, task by task,
> only after root GO on the exact independently reviewed canonical documents.

**Goal:** Populate genuine legacy A on exact22 schema, migrate SAME A, create an
actual defaultV3 backup, restore fresh B natively, and prove A unchanged.

**Architecture:** A fixed historical source corpus runs in an isolated subprocess
during surviving-owner acquisition. Historical shutdown precedes ready; current
infrastructure starts exactly once after forwards. Existing Task11 parking,
native saga and independent oracles own retained-A/B verification.

**Tech Stack:** Existing Elixir/OTP, ExUnit, Ecto/PostgreSQL, ExCmd, historical native
crypto/publication/deletion, current Runtime.Api and backup/restore contracts.

Read the COMPLETE
`docs/superpowers/specs/2026-10-20-singularity-v0.2-phase-5-task18-historical-upgrade-design.md`.
Its §1.1 is the durable actual Task17 prerequisite/handoff; do not duplicate or
reinterpret those results as Task18 qualification. The private draft1/2/3 pairs,
their actual findings/reviews and architecture advisory remain immutable.
All Task18 implementation/runtime commands below are FUTURE and NOT RUN at this
documentation-review boundary. The current source change is documentation-only:
this plan, its canonical design and the narrow AGENTS active-status update.
Canonical candidate1's SPEC PASS and subsequent QUALITY REQUEST_CHANGES remain
historical. This revision resolves its two Important MIME/UTF-8 boot findings;
new ordered reviews/root GO are required. Implementation repair counts stay0/0.

---

## Entry, ownership and gates

- [ ] Parent verifies actual Tasks11/12/17 qualification and Task16 dependency
  against design §1.1 and their recorded handoffs, fully reads this three-file
  documentation candidate, obtains independent DESIGN SPEC then NEW distinct
  QUALITY, records root GO and commits only the reviewed design/status files
  before opening specific implementation ownership. No preparation claim
  supplies GO. Parent retains exclusive runtime/SQL/service execution.
- [ ] Record new candidate HEAD/branch/dirty state and exact prior user edits.
  Current tested-source baseline is `d054d58155ab119a17cbcbd36f11ba3a23d44e1e`
  in W; record the actual subsequent design commit separately as implementation
  baseline. Never pretend the Task17 baseline guard accepts that new HEAD.
  Do not stash, reset or edit the frozen56 manifest, original draft1 pair,
  released migrations, historical source fixture bytes or old raw receipts.
- [ ] Assign Storage owner to frozen22/identity/explicit preparation seam and
  lifecycle tests; Runtime owner to the253 inert files/runner/driver/native live
  test after the preparation interface is fixed. Parent owns integration/reviews.
  They are not alone and must preserve each other's work. Maximum3 active agents.
- [ ] No new dependencies, public API, production process or migration is planned.
  Unanticipated need goes through bounded design/review; no hidden fallback.

### Root qualification lane, before any VM command

- [ ] Read the accepted stopped-context identity/control/archive, verify retained
  data/log/probe identities and no old process/socket. Prepare separate Task18
  root-owned source/command/lifecycle tooling with finite exact commands from
  this plan, fixed existing interpreter/toolchain/PG settings and no shell
  interpolation. Preserve every Task17 script/receipt/hash unchanged.
- [ ] Obtain actual independent SCRIPT SPEC then NEW distinct QUALITY on that
  exact candidate before restarting the exact owned qualification server with
  a separate new private log and observing its fresh actual tuple. Root alone
  runs VM/SQL/formatter/service/Git; workers never execute tests or manage PG.
- [ ] Require full actual role/settings/locale/HBA/trgm/no-other-clients facts,
  exact design/GO/source manifests, index state and unchanged native/frozen
  accounting before each primary. Every attempt, including RED/failure, gets
  immutable raw/natural result and its own separately executed ordinary post.
  Cleanup must stay operational even if source/gates fail. New run IDs/outputs
  are exclusive; no overwrite, symlink, cache/tuning or timeout shortcut.
- [ ] Do not rerun a green gate without a source change or concrete new evidence.
  Serial exact RED/GREEN and final whole owners are required; synthetic driver
  checks and narrowed diagnostics never replace actual historical/native gates.

## A. Freeze exact migration and executable source inputs

Create:

- `apps/singularity_storage/test/fixtures/upgrade/v0.1.0/source.json` and exact22
  `migrations/*.exs` files.
- `apps/singularity_storage/test/support/legacy_upgrade_fixtures.ex`.
- `apps/singularity_storage/test/singularity/storage/legacy_upgrade_fixtures_test.exs`.
- `apps/singularity_runtime/test/fixtures/legacy_v0_1_0/source.json` and253 exact
  `sources/<original_path>.source` files defined by design §2.
- `apps/singularity_runtime/test/support/legacy_upgrade_runtime_fixture.ex`.
- `apps/singularity_runtime/test/singularity/runtime/legacy_upgrade_source_test.exs`.

- [ ] Reproduce local release identity, tree,22 file inventory and253 source
  inventory from the exact commit. Produce manifests using those Git blobs,
  not HEAD. Source copies retain exact byte content despite their inert suffix.
  Coordinator verifies manifest records against local Git before review.

```sh
git rev-parse 'c49dc0aeda1d0115b20ff291f0da658f7e558b43^{commit}'
git rev-parse 'c49dc0aeda1d0115b20ff291f0da658f7e558b43^{tree}'
git tag --points-at c49dc0aeda1d0115b20ff291f0da658f7e558b43
git show -s --format='%H %s' c49dc0aeda1d0115b20ff291f0da658f7e558b43
git ls-tree -r c49dc0aeda1d0115b20ff291f0da658f7e558b43 apps/singularity_storage/priv/repo/migrations
git ls-tree -r c49dc0aeda1d0115b20ff291f0da658f7e558b43 -- apps/singularity_core/lib/singularity apps/singularity_domains/lib/singularity apps/singularity_storage/lib/singularity apps/singularity_ingest/lib/singularity apps/singularity_retrieval/lib/singularity apps/singularity_runtime/lib/singularity config/config.exs mix.lock
```

- [ ] Add pure identity contracts before helper behavior. Proposed fixed
  interfaces are Storage `LegacyUpgradeFixtures.identity!/0` and Runtime
  `LegacyUpgradeRuntimeFixture.source_identity!/0`; neither allocates resources.
  Independent expected literals: migrations22/fingerprint5e3c5b3a…f6eb62 and
  source253/bytes2135469/fingerprintd7506f51…a22924 (full values in design §2).
  Missing-module RED is reported honestly, then causal in-memory mutation RED
  is required before claiming boundary coverage.
- [ ] Every rejection vector starts with a valid positive control. Independently
  change byte, filename, path, blob, commit, tree, fingerprint, ordering, duplicate,
  omission, extra source, current replacement and symlink. Require the specific
  identity error and no allocation. Do not corrupt shared fixture files.
- [ ] Implement exact immutable validators and verify all original dependency
  lock entries still match. Test a changed dependency pin/application path as a
  rejection, not a reason to fetch a compatible package. Fixture source suffixes
  must not enter normal compile/format/app-graph inputs.

The two identity entrypoints return maps with `commit`, `tree`, `fingerprint`
and `files`; Runtime also returns `bytes`. `files` is the ordered manifest entry
list, not a lazy loader or current-Git lookup. Add these exact initial contracts
before their implementations:

```elixir
defmodule Singularity.Storage.LegacyUpgradeFixturesTest do
  use ExUnit.Case, async: false
  alias Singularity.Storage.LegacyUpgradeFixtures

  test "fixed release migrations are exact before allocation" do
    identity = apply(LegacyUpgradeFixtures, :identity!, [])
    assert identity.commit == "c49dc0aeda1d0115b20ff291f0da658f7e558b43"
    assert identity.tree == "203135f6e35b72aaab269b75a30dcf2ef080bfe3"
    assert identity.fingerprint ==
             "5e3c5b3ad94f294379a00c80136617910c3537fc8a6288266ecc9a53e5f6eb62"
    assert length(identity.files) == 22
    assert List.last(identity.files).filename ==
             "20260818000100_create_private_markdown_notes.exs"
  end
end
```

```elixir
defmodule Singularity.Runtime.LegacyUpgradeSourceTest do
  use ExUnit.Case, async: false
  alias Singularity.Runtime.LegacyUpgradeRuntimeFixture

  test "the inert historical corpus has its independent fixed identity" do
    identity = apply(LegacyUpgradeRuntimeFixture, :source_identity!, [])
    assert identity.commit == "c49dc0aeda1d0115b20ff291f0da658f7e558b43"
    assert identity.tree == "f68e1ed5507780db1e3c024e7f387557ac75f23b"
    assert identity.fingerprint ==
             "d7506f511de599dfb92cd2313f843abb27ca26eafd3bf89939ecbf07e2a22924"
    assert length(identity.files) == 253
    assert identity.bytes == 2_135_469
  end
end
```

- [ ] Run the complete two new owners before helper code; retain honest missing-
  entrypoint RED rather than calling it a causal integrity failure. Materialize
  frozen Git bytes with reviewed `apply_patch` additions, never archive/shell
  redirection/copying current files. Parent independently checks every fixture
  blob/SHA256 and both complete fingerprints against the fixed local commit.
- [ ] Implement the fixed identity entrypoints with one strict validator per
  corpus. Separate pure manifest/file-byte validation from filesystem acquisition
  so the SAME validator receives positive-controlled in-memory mutants without
  modifying shared fixture files. Its filesystem reader rejects symlinks and
  extra files; no network/Git/DB action belongs in ordinary identity tests.
- [ ] Assert canonical field sets, exact fixed count/order, no duplicates,
  safe fixed original-to-fixture mapping, regular-file inventory, raw-byte SHA256
  and Git-blob SHA1, raw total and independent metadata fingerprint. Fail closed
  with fixed content-free identity categories, not file contents/exception dumps.
- [ ] Observe causal validation RED for a deliberately missing boundary against
  the actual shared validator, restore the minimal correct validation and obtain
  whole-file GREEN. Then keep all named corruption rejections with a valid
  positive before each; do not weaken literal expected identities or assertions.

Future whole pure command:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/legacy_upgrade_fixtures_test.exs apps/singularity_runtime/test/singularity/runtime/legacy_upgrade_source_test.exs --seed 215378 --warnings-as-errors
```

## B. Explicit historical preparation acquisition, no infrastructure reset

Modify ONLY test support:

- `apps/singularity_storage/test/support/knowledge_fixture_resource_owner.ex`.
- `apps/singularity_storage/test/support/migration_test_environment.ex`.

Create:

- `apps/singularity_storage/test/singularity/storage/backup/legacy_upgrade_lifecycle_test.exs`.

- [ ] Add RED for `ResourceOwner.open_legacy_v0_1_0(prepare)` with arity2
  trusted preparation function, expecting `{owner, destination, receipt}` after
  actual22 migration. Its positive preparation checks owner PID != test caller,
  exact A identities and live five owned repos, reports running/closed, and
  returns a harmless private receipt. Existing ordinary destination callback
  still runs in the caller. No checkpoint performs mutation.
- [ ] Add before-allocation rejection for invalid function/arity and attempts
  to choose arbitrary paths/options/duplicate keys. Fixed historical selection
  is not exposed on open_child. Preserve original []/pool2 positive controls.
- [ ] Thread the explicit preparation field separately through owned acquisition,
  select the frozen path after identity verification, and retain unchanged
  ordinary paths. Add owner-local preparation state; do not clear infrastructure,
  change start_owned_infrastructure rejection, or start current runtime.
- [ ] Before ready, invoke trusted prepare(destination, context) in the surviving
  owner. Context exposes only caller PID and cleanup-state reporting. Require
  closed state before returning receipt; check caller liveness again before ready.
- [ ] Add causal tests for throw/raise, caller loss while preparing, preparation
  returning while still running, and unconfirmed cleanup. Confirmed failure must
  stop owned repos and remove exact database/root through normal ownership.
  Unconfirmed failure must expose cleanup failure and retain exact quarantined
  database/root without a successful ready/drop/removal receipt. Test-only cleanup
  of that intentionally quarantined fixture happens only after independently
  confirmed absence; never count it as automatic product/helper cleanup credit.
- [ ] Preserve every old lifecycle/nested-lifecycle assertion and helper byte.
  Run BOTH complete original owners together with the new owner. If pinned,
  new support deltas need exact reviewed forward/inverse attribution.

The new acquisition entrypoint has this exact call/return contract; the
preparation callback is local trusted test code, not a configured MFA:

```elixir
prepare = fn destination, context ->
  assert self() != context.caller
  assert is_binary(destination.database)
  assert is_pid(Process.whereis(Singularity.Storage.MigrationRepo))
  :ok = context.report_cleanup.(:running)
  :ok = context.report_cleanup.(:closed)
  %{prepared: true, database: destination.database}
end

{owner, destination, receipt} =
  ResourceOwner.open_legacy_v0_1_0(prepare)

try do
  assert receipt == %{prepared: true, database: destination.database}
  assert Process.alive?(owner)
after
  assert :ok = ResourceOwner.close(owner)
end
```

For the ordinary unchanged APIs, preserve their existing two-element return
tuples and original callbacks. Store a distinct preparation selection/state
rather than extending caller options with arbitrary migration paths. The
historical return tuple is3elements only after actual child/preparation closure.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/legacy_upgrade_lifecycle_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_fixture_lifecycle_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_fixture_nested_lifecycle_test.exs --seed 215378 --warnings-as-errors
```

## C. Offline historical child and its native population protocol

Create:

- `apps/singularity_runtime/test/fixtures/legacy_v0_1_0/runner.exs`.
- `apps/singularity_runtime/test/singularity/runtime/legacy_upgrade_process_test.exs`.

Extend only the new Runtime helper from TaskA.

- [ ] Define the fixed child protocol before execution: bounded framed private
  input with A's identity/role connections/root and literal input/credential
  values; typed bounded private output with source identity and native result
  IDs/digests. No arbitrary command, migration source or codepath from input.
  Use version1 unsigned32-bit-big-endian length-prefixed UTF-8 JSON, 16KiB input,
  64KiB output, execution 45,000ms plus cleanup 5,000ms, with exact-key/duplicate-key/
  trailing-byte rejection. Preserve existing test watchdogs. A demonstrated
  budget failure requires an evidenced amendment,
  never an automatic timeout increase or filtered acceptance command.

Use this exact frame construction after validating the fixed-key payload:

```elixir
payload = Jason.encode!(configuration)
true = byte_size(payload) <= 16_384
frame = <<byte_size(payload)::unsigned-big-integer-size(32), payload::binary>>
```

Read a4-byte header first; reject declared output above65_536 before retaining
its body. After precisely the declared body, probe for EOF with at most one byte.
At the full65_540-byte boundary any extra byte is `:legacy_output_limit`; a
shorter frame's trailer is `:legacy_protocol`. Decode the exact body with
duplicate-key rejection; never scan/trim the merged byte stream. Private
credentials/content enter only this framed stdin, never argv/env/error terms.

- [ ] Pure RED rejects a current Singularity ebin, wrong dependency lock/version,
  malformed input/receipt and oversized output before accepting native results.
  Require current VM module origins unchanged before/after the entire driver.
- [ ] Pin separate child argv entries `--erl`, `+fnu` before the fixed runner,
  clear inherited Erlang/Elixir startup injection, and assert native filename
  encoding `:utf8` before compilation. Keep parent/PG `LC_ALL=C`, ordinary gate
  argv,45,000ms/5,000ms and all other VM settings unchanged. This is fixed native
  encoding, not performance tuning or compiler-warning suppression. Add actual
  clean-frame positive under inherited C and a controlled no-switch native-name
  boot-diagnostic rejection via the same bounded private transport. Retain the
  actual older Task17 latin1 warning logs unchanged; never trim/filter them.
- [ ] Driver runs as the acquisition owner, reports running before spawn, retains
  actual ExCmd handle before sending input, owns await_exit, and monitors caller
  plus all pipe workers. Store no credentials/content in process labels/logs.
  Keep payload output private; report fixed failure categories externally.
- [ ] Before a historical child launch, pin explicit ExCmd options
  stderr: :redirect_to_stdout, log: nil; reject console/disable/default fallback.
  Existing ExCmd merges both descriptors into the private stdout reader, not a
  second stderr collector. Keep input16KiB, JSON payload65,536 bytes plus4-byte
  header, execution45,000ms/cleanup5,000ms and the existing exact frame grammar.
  Each read requests min(4096, remaining frame budget plus one); check the
  budget before retaining at most one permitted frame plus one probe byte.
  Require EOF/exit0, never trim/scan/filter output.
- [ ] Add causal diagnostic tests to legacy_upgrade_process_test.exs. Each starts
  with a valid framed positive child under the SAME explicit transport. A child
  writes stderr <<0,0,0,1,"!",canary::binary>> before its valid frame,
  inserts a canary outside a JSON string within its receipt, and appends a
  canary after a short valid frame; require :legacy_protocol for each and no
  raw diagnostic echo. In the prefix case hold stdout until reader rejection;
  use actual reader checkpoints/PID handshakes for payload/trailer cases, not
  an assumption about ordering between concurrently ready descriptors. Require no
  parent console/log/telemetry/error/Inspect canary. Also trigger a child compiler
  warning and a runtime exception with canaries; neither may bypass the bounded
  channel or be echoed. Capture both parent standard descriptors and Logger,
  assert content-free booleans/categories rather than printing captured bytes.
  Synthetic children qualify transport only, never historical native population.
- [ ] Add positive-controlled ASCII stderr flood/declared-length>65,536 cases
  requiring :legacy_output_limit immediately from the oversized header. Also
  pad a valid JSON receipt with JSON whitespace to65,536 payload bytes: first
  prove that full-boundary frame succeeds, then add one byte and require
  :legacy_output_limit before protocol parsing (short-frame trailers remain
  :legacy_protocol). Assert bounded retained state and a blocked-reader failure
  requiring :legacy_pipe. Use PID-targeted handshakes/monitors, no sleep races.
  For malformed prefixes declaring excess length, expect :legacy_output_limit rather
  than relabeling it a JSON parse error. Keep duplicate-key/trailing-byte cases.
  Preserve first observed primary category and distinct cleanup failure; no raw
  exception messages, stacktraces or buffer-bearing worker crash reports escape.
- [ ] In every diagnostic/oversize/reader failure positively assert the actual
  surviving owner invokes await_exit, all workers DOWN and child connections
  gone before closed/ordinary A removal. Unconfirmed await must quarantine A,
  with no ready/drop/removal success. Do not use manual cleanup as helper credit.
  Finally qualify the REAL pinned historical compiler/native workload with
  exactly one clean frame, EOF and exit0 under the same merged private transport.
  Do not suppress/filter warnings, change historical bytes or substitute a
  synthetic clean child to obtain historical acceptance.
- [ ] Add focused subprocess failure contracts: startup error; nonzero exit;
  child closes stdout early; reader/writer exits; caller dies before child ready
  and during native work; deadline; invalid/oversized final receipt; unconfirmed
  await. Assert actual exit/worker DOWN before ready or ordinary A destruction.
  A synthetic protocol child may test driver mechanics, but only the genuine
  historical child can satisfy population and upgrade acceptance.
- [ ] Compile the exact251 sources in the child with standard compiler into an
  owned private directory, with external-only codepaths. Read pinned config in
  prod mode and overlay only approved test bindings/manual job composition.
  Assert loaded source origin both before native work and before final receipt.
- [ ] Run actual historical bootstrap/login/unlock, upload/verify/finalize/native
  download, Note history/conflict/merge/tombstone, and Asset delete/cleanup.
  The fixed parent literals are a valid ASCII-only PDF/application/pdf and a
  valid PNG/image/png with NUL/high bytes and valid IHDR CRC, each at most1KiB.
  Input `originals` has exactly `text_pdf_base64`/`binary_png_base64`/
  `deleted_png_base64`; the trusted runner fixes MIME mapping. The deleted Asset
  is a separate genuine upload of a third valid PNG literal, at most1KiB with
  different bytes/digest and its own returned Asset/object identity. Require
  all three literal digests distinct so no live reference defeats orphan cleanup.
  No raw `text/plain`, generic-binary declaration, current plain/Markdown/empty
  input or native MIME
  bypass is allowed. Source-characterized zero-byte publication is unsupported,
  not a positive substitute. Keep any actual rejection diagnostic separate.
  Inputs and hashes originate independently in the parent. Assert real stored
  outbox/submission/progress/effect provenance, associations and lifecycle rows.
  Do not substitute copied AssetVertical fake setup or current adapters.
- [ ] Drain genuine `:asset_cleanup`, dispatch the real orphan cleanup request
  but leave `:object_cleanup` undrained. Historical default retention is0;
  assert genuinely pending work without claiming a future retention interval or
  manipulating clocks. Serialize only approved BootstrapOwner identity fields,
  never its returned credential_hash/full result. Record actual native UTF-8
  name mode in the bounded private work receipt.
- [ ] On success child stops its exact infrastructure/repos and exits0. Parent
  owner awaits native exit, verifies child connections gone, reports closed,
  and only then returns A with a private receipt and infrastructure still nil.
  No historical cleanup is deferred until after migration.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/legacy_upgrade_process_test.exs --seed 215378 --warnings-as-errors
```

## D. Same-A upgrade witness

Create:

- `apps/singularity_runtime/test/singularity/runtime/knowledge_upgrade_live_test.exs`.

- [ ] First live case stops after genuine legacy preparation to characterize the
  chosen source/toolchain without hiding setup failure in a full restore case.
  Assert exact22 ledger, absent later tables/functions/columns, original A name/
  OID/root/repo identity, verified native live/deleted data and durable work.
- [ ] Parent independently captures all legacy-column row sets and physical
  files AFTER historical child exit. Do not use current V3 projections against
  old schema or trust only child success counters. Keep private snapshots unprinted.
- [ ] Add RED for same-A forwards after the native positive succeeds. Run the
  current migration directory via existing MigrationRepo. Require unchanged
  database/root identity, original22 prefix and all29 reviewed forwards once.
  No schema reset, copy, early migration, trigger disable or ledger forgery.
- [ ] Compare exact original columns/rows/files without an allowed application-row
  transformation. The migration ledger is checked separately as22+29. Independently
  derive new wake counters from captured original metadata/reconciler generations
  under design §6 and prove the selected no-wake fixture's inputs are0. Check empty
  Note source seals. Check new knowledge tables empty before current writes.
- [ ] Assert actual current constraints/RLS/owners/ACLs/search paths and direct
  runtime/preauth/spoofed-GUC denials. A real migration failure retains exact
  SQLSTATE/constraint and needs additive repair design, never old-file edits.
- [ ] Before A's sole current-runtime start, set storage job handler to the
  unchanged transparent `KnowledgeBackupRestoreFixture.V3JobHandler`, and runtime
  observer to `%{owner: credentials.owner, receive_cut: callback}`. The callback
  records the actual independent worker-cut observation exactly once and returns
  `:ok`; delegate must return unchanged real cut/records. Restore env exactly.
- [ ] Assert original infrastructure slot is unused; start current native runtime
  exactly once on A. Freshly log in/unlock using real preserved credentials.
  Parent repo PIDs remain exact; historical child repos must be absent.

## E. Qualified current knowledge, actual defaultV3 and A/B saga

- [ ] Create the whole integration owner
  `apps/singularity_runtime/test/singularity/runtime/knowledge_upgrade_population_test.exs`
  first. Add RED for the new test-only
  `KnowledgeExportLiveFixture.with_existing_runtime(native,callback)` in design
  §6.1; ordinary current-schema native A is only the seam's positive/control
  test. Characterize its missing interface honestly before implementation.
- [ ] Add only a marked block before Task17 fixture's final module `end`:
  `TASK18_EXISTING_RUNTIME_POPULATION_BEGIN` through
  `TASK18_EXISTING_RUNTIME_POPULATION_END`. Preserve the complete old3550-line
  file via exact block removal/SHA2567bd3ac5f…d0004a. Mutants that change old
  assertions, omit restoration or accept replaced/dead identity must fail.
- [ ] Implement the exact constructor: validate real existing A/native/session
  identity; register its temporary infrastructure-owned journal before effects;
  initialize only needed private population inputs/state; run the trusted
  callback; unwind all permission scopes and exact child; recheck A identity.
  Keep successful callback value separate from any cleanup failure; no A stop,
  bootstrap, second runtime start, export collector or sentinel creation.
- [ ] Test real current population, exact ACL/effective/role-membership snapshots,
  unchanged A infrastructure/five repo/root identity and pre-existing witness
  rows/bytes, callback/partial setup errors and original caller loss. Require
  actual helper DOWN/removal and normal A usability. For caller loss require
  ResourceOwner's genuine A cleanup, not an invented ACL-restored receipt.
- [ ] After actual whole population GREEN, populate CURRENT knowledge in this
  existing upgraded A through the same accepted native contracts. Do not allocate
  another source installation or call a self-closing backup_source helper.
  Preserve all legacy witnesses and restore exact ACL state after test grants.

The only current-population callsite uses the exact constructor from design §6.1:

```elixir
native = Map.merge(runtime, %{credentials: credentials, session: session})

population =
  KnowledgeExportLiveFixture.with_existing_runtime(native, fn fixture ->
    fixture = KnowledgeExportLiveFixture.publish_sources!(fixture)
    fixture = KnowledgeExportLiveFixture.build_graph!(fixture)
    Map.take(fixture, [:inputs, :sources, :graph])
  end)

assert map_size(population.sources) == 4
assert population.graph.second_pdf.state == :ready
```

- [ ] Return from that scope BEFORE backup/parking. Do not call standalone
  Task17 `with_fixture/1` or its finalizer/inventory checks around parked A.
  Run whole new population owner and complete Task17 live/privacy and affected
  architecture owners after the additive seam, preserving all old assertions.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_upgrade_population_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_live_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_privacy_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Create actual default backup through Api.request_backup with no version
  override. Dispatch/drain genuine worker; require sealed operation and exact
  operation/owner/database cut. Capture independent canonical38 rows at that cut
  through transparent delegation and authenticate actual bundle version3.
- [ ] Preserve actual encrypted bundle outside A/B roots with0700/0600 ownership.
  Its closure follows V3 rules: deleted Asset-only orphan bytes need not be in
  the bundle; retained Document-only originals must be. Preserve all A bytes in
  A's separate unchanged oracle and do not conflate those two inventories.
- [ ] Park A via Task11 helper; capture full private rows/tree AFTER all source
  work and BEFORE B allocation. Keep A owner/database/root/private reader alive.
- [ ] Open fresh current B as A's child. Use a new Task18-local maintenance wrapper
  without pretending A meets the existing closed-source helper's precondition.
  Require distinct name/OID/root, empty root, and no ordinary B runtime.
- [ ] Run genuine RestoreVault/context with actual authentication/import/rewrap/
  native integrity/reconciliation/Document verification/search/completion.
  Transparent observations assert B is maintenance-only and not published before
  native verification/rebuild/completion; no replacement stage summaries.

The existing public composition call is fixed, with no injected failure:

```elixir
context =
  KnowledgeBackupRestoreFixture.restore_context(
    destination,
    portable_root,
    hooks,
    %{}
  )

assert {:ok, %{manifest_id: manifest_id}} =
         Singularity.Runtime.RestoreVault.run(context, %{
           source: preserved_ref,
           passphrase: original_passphrase,
           new_password: replacement_password
         })

assert manifest_id == operation_id
```

`hooks` has the exact required after_import/after_rewrap/after_complete/diagnostic
functions from design §7 and every one returns `:ok` after checking real results.

- [ ] Compare complete canonical/history/source membership/immutable digests and
  exact object closure before dispatch. Separately verify documented credential/
  key rewrap and durable reconciliation transformations and exact source seals.
- [ ] After real completion only, start B controlled runtime, authenticate with
  restored owner/new password, read native originals and call public search for
  stable IDs/versions/fragments/locators/text with deleted/old/nonready exclusions.
- [ ] Compare A full rows/files while B is live and after B closes. Require exact
  B child/lease/repo/connection/database/root cleanup before A reader/owner release.
  Task11 parking does not resume A inside callback; close A after final comparison.
  Require exact baseline application-config restoration and preserve primary plus
  secondary cleanup failures. Manual DROP/removal is not acceptance evidence.

## F. Whole gates and parent-owned completion

Master Task18 commands, unchanged and complete:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_upgrade_live_test.exs apps/singularity_storage/test/singularity/storage/knowledge_migration_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Run whole new source/identity/lifecycle/process owners from A/B/C, plus
  complete defaultV3/native restore regressions and sole independent restore.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.restore
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix compile --warnings-as-errors
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix xref graph --format cycles --fail-above 0
```

- [ ] Parent selects the complete existing role/source-set/historical-admission
  and architecture owners affected by actual diff. Require seven product apps,
  zero cycles and unchanged frozen56 accounting (54 exact +2 accepted inverses).
  No fixture module/codepath enters the production application graph.
- [ ] Every invocation has immutable raw/status/source receipt and its OWN next
  ordinary post. Parent uses only the accepted I/O lane; no added tuning, service
  transitions, symlinks, cache substitution or deadline changes. Do not duplicate
  a green gate without new evidence requiring it. Retain FAIL/INVALID/NOT RUN.
- [ ] Fully inspect exact final source/diff, preserve old assertion bytes and
  source manifests, then independent SOURCE SPEC followed by NEW distinct QUALITY.
  Review closure applies to exact tested bytes, not a later approximate patch.
- [ ] Parent records migration/source identity, native vs synthetic test labels,
  all command results, resource cleanup, residual risks and no Vault semantic
  changes, and makes only the authorized small local commits. Suggested final
  subject: `test(upgrade): qualify exact v0.1 schema through v3 restore`.
- [ ] Task19 still owns the full permitted README campaign/Phase5 acceptance.
  E2E NOT RUN/manual-deferred. No publication, deployment, activation/backfill,
  production data, merge, push, version or tag work occurs under Task18.

## Known future evidence, not claimed results

Offline compilation, native historical behavior, operation timing, all subprocess
failure-cleanup contracts, same-A preservation and full A/B restore are NOT RUN.
Task17 source acceptance is actual under design §1.1; its new existing-A seam
and the fresh reviewed Task18 parent lane remain implementation requirements.
Historical source compatibility failure is not permission to edit old
source or introduce early forwards. This plan is a test-first architecture handoff
for review; Task18 implementation repairs remain Sol0/Astra0, prior architecture
advisory1. Historical Task17 and other-task counters are neither reset nor changed.
