# Phase 5 Task 16 Export Artifact Ownership Implementation Plan

> **For agentic workers:** Use `subagent-driven-development` or `executing-plans`
> after parent-managed design review and an explicit implementation GO. The parent
> owns allocation, author/gate windows, native validation and final acceptance.

**Goal:** Deliver a completely verified portable export through the four
authenticated Runtime.Api operations, with correct Writer ownership and scoped
temporary-artifact cleanup.

**Architecture:** `Knowledge.Export` orchestrates the existing snapshot/read/writer
interfaces. An eventual supervised owner creates Writer's ETS and survives the
generating request; an operation-local companion monitors generation and cleanup.
Storage owns recognizable private artifact envelopes. Existing native authority,
custody and lease semantics remain unchanged.

**Tech Stack:** Existing seven-application Elixir umbrella, OTP Task.Supervisor,
Ecto/PostgreSQL request scopes, native filesystem APIs and existing JSON codecs.
No new dependency, registry, queue, domain process or migration.

---

## Execution boundary and unresolved requirement

Read the complete companion design
`../specs/2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership-design.md`.
It supplies the native source trace and fingerprints. Inspected worktree is
`.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`, HEAD
`09f8ee0c0a69cdd26612e0663a29a9d156c46986`, with substantial pre-existing parent/Sol
changes. This document does not qualify those changes or authorize overlapping
writers. Check current parent receipts before touching any source.

**The strict late-unreturned-lease cleanup guarantee is BLOCKED_DESIGN.** Native
`KeyCustodian.lease/2` has a default call timeout and no operation-local public
lookup for a lease returned after timeout. Successful returned leases can be
tracked; an unreturned identifier cannot be revoked by the wrapper. The master
design and Task 16 do not exempt this case from “revoke outstanding leases.”
Keep that assertion unchecked. No private custody messages, `:sys` inspection,
global enumeration, timeout/TTL/monitor changes or whole-session revocation.
Parent review must exhaust existing public alternatives before deciding the
affected boundary. Supported steps below are separately reviewable; they do
not imply complete Task 16 readiness or acceptance.

Actual nonauthor DESIGN_SOURCE_SPEC additionally closed one P2: hard companion
death after native issuance but before recording/forwarding loses the only
export-observable lease identifier. The companion's exclusive map and owner
link do not supply a surviving native revoker. This second strict death-cleanup
boundary is also BLOCKED_DESIGN; native manifestation NOT RUN. Successful
owner/requester races cannot qualify it. No implementation GO for either
affected promise until parent disposition; all original assertions remain.

2026-10-13 startup-only PROJECT_ARCHITECTURE amendment, inspected HEAD
`4e2499d5b89664c3e7b63cb1f3136c243b276c83`: historical actual nonauthor
DESIGN_SOURCE_SPEC disposition was PASS WITH UNSATISFIED BOUNDARIES. Distinct
fresh DESIGN QUALITY found another P2: the original P5-A5 cleanup returned
before application.ex:37–40 registered/started the native supervisor. Two
starters could both see absence and the delayed one scavenge the other's live
artifact. Step6 now holds one LOCAL OTP guard through the native start result;
Step7 replaces only P5-A5's additive rule with an exact inverse replacement.
Historical reviewed receipts, not current-document acceptance hashes: design
`82a35ebd586613d673d01c605738abb5b292a285ea14d8aeb4acd2a1cedcc33b`, plan
`7d28f42cbd8d57a7e2b6ddbd112a4a817fd8ce6798d1e51b971521f343ffef39`.
Historical rejected P5-A5 insertion/context hashes were
`ccc44e6f2bbb18c6d78f052fff29705ac60c6677f8533867f98fe95bbe965363` /
`151da9a36bfa44cabe09eab9c58a6ca2d60d9947c50b346b77f8c801f1b684b4`;
they must not qualify the replacement. Both strict ALL-lease cleanup guarantees
remain UNSATISFIED/UNWAIVED/BLOCKED_DESIGN. Startup repair does not repair either
lease gap. No Task16 test/source GO until actual independent amendment reviews
and genuine resolution of the boundaries; all new runtime witnesses NOT RUN.
Independent valid Task9/15 continues. Architecture consumes zero Astra recovery
rounds and resets no Sol counter.

2026-10-13 Task8 attribution P2 design repair1: actual nonauthor SPEC of the
startup amendment FAILED because Step7 omitted accepted Task8 Application
composition changes. Reviewed receipts were design
`b162cd513c50abaf578f3e0773759dd9b5d17ccb854f6852c8ecda5f6c0c9b2b`, plan
`1a93e20f71cda105de97d5cef59c365edffdd6add0727f1d58fcc4e31bd1efb3`.
Keep this FAIL and the older startup receipts above. Step7a below supplies a
separate exact test-attribution prerequisite, not Task8 source repair or lease
qualification. Startup P5-A5 and the seven additions retain every proposed
literal/hash. Production repair0/Astra recovery0; received Sol production
repair counter0 for this assignment. No other counter is reset. Actual nonauthor
SPEC, distinct fresh QUALITY and genuine boundary disposition remain required;
Task16 source/tests are NO GO and both strict lease guarantees remain
UNSATISFIED/UNWAIVED/BLOCKED_DESIGN. SQL and maintenance windows remain CLOSED.

2026-10-13 positive-witness input-stage design repair2, inspected HEAD
`2a7873b8e40ca7aebd27a32de54fdf49ab3cf933`: actual independent repair1 DESIGN
SPEC FAILED one P2. Its exact reviewed receipts were design
`496dffbf17a44a13aa4c9908c791fe875563a2796eb0b783d7cf4babbc4a8559`, plan
`5dffa0cdd26b4554c16d4a82a765c157d52c9c53843b30141cf4d83121067486`;
the actual review is archived at
`.devenv/phase5-task16-attribution-design-repair1-spec.md`.
Step7b's helper-only replacement missed the accepted Task8 positive witness's
direct inverse calls on raw Application (architecture-test lines 1201–1214).
The independent read-only calculation found that Task8-only inversion of
proposed P5-A5 source `f562d82432fea2ec50e5599c780634deccb9266fc0b729525699b457f582bd39`
retains the startup replacement at
`e4bfadb63a5b6033b42214a499dc238772f9afd42b4e980c189fec850366e1e1`,
instead of the fixed pre-Task8 digest. Strict P5-A5 inversion before Task8
inversion recovered the actual parent byte-for-byte. Preserve this actual FAIL
and all earlier receipts. Repair2 adds only the explicit future positive-input
adapter in Step7b plus documentary status/self-review; no source/test edit.
Documentary repair2's actual corrected DESIGN SPEC and NEW distinct fresh DESIGN
QUALITY are CLOSED PASS on the exact archived copies identified at this plan's
self-review; this later status metadata is not retroactive review. Production Sol0/Astra
recovery0 and parent Task10 Sol1/Astra0 remain separate and unchanged. Task16
source/tests remain NO GO, native NOT RUN, and both strict ALL-lease guarantees
remain UNSATISFIED/UNWAIVED/BLOCKED_DESIGN. The attribution correction does not
qualify either lease promise.

The existing brainstorming and writing-plans workflow is used for options,
boundaries, concrete test-first steps and self-review. Repository continuing
authority supersedes routine approval pauses and skill-suggested commits by this
architecture author. The author writes only these two documents. Sol implements
only after parent disposition. E2E is NOT RUN/manual-only. No merge, push,
release, tag, version bump, deploy, activation, backfill or production data work.

## File responsibility map

Create:

- `apps/singularity_runtime/lib/singularity/runtime/knowledge/export.ex`:
  validation, native authority, capture/materialization and facade result checks.
- `apps/singularity_runtime/lib/singularity/runtime/knowledge/export_artifact.ex`:
  opaque Handle and Inspect, owner/companion task protocol, fixed private lease
  adapters, monotonic deadline and startup coordination.
- `apps/singularity_storage/lib/singularity/storage/knowledge_export/artifact_directory.ex`:
  dedicated root validation, ownership markers and identity-checked cleanup.
- `apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs`.
- `apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs`.
- `apps/singularity_storage/test/singularity/storage/knowledge_export/artifact_directory_test.exs`.

Modify only for the stated additions and one exact startup-call replacement:

- `apps/singularity_storage/lib/singularity/storage/knowledge_export/repository.ex`:
  additive `document_source_selector/2`; preserve every existing public function.
- `apps/singularity_runtime/lib/singularity/runtime/api.ex` and `application.ex`:
  exact blocks P5-A1 through P5-A5 below.
- `config/dev.exs`, `config/test.exs`, `config/runtime.exs`: P5-C1 through P5-C3.
- `apps/singularity_runtime/test/singularity/runtime/application_test.exs`:
  new root/startup composition checks; preserve old child/dependency assertions.
- `apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs`:
  additive native wrapper/owner race witnesses using its actual fixture and
  unchanged custody. Do not rewrite its earlier assertions or frozen fixtures.
  The new strict timeout/companion-death characterization cases belong in the
  new `knowledge_export_artifact_test.exs`, with integration tagging and genuine
  public native composition; retain this existing whole live owner unchanged
  for those cases. No frozen Vault test edits or private fixture imports.
- `apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs`:
  NEW necessary test-only Task8 attribution prerequisite in Step7a, then exact
  Task16 additions/contexts/digests and closed registration tests in Step7b.
  Preserve every historical tuple/hash/assertion. Task8's accepted Application
  source and its application-test assertion are not rewritten by this prerequisite.

Retain whole-file ownership checks for `notes_scope_contract_test.exs`,
`knowledge_export_snapshot_test.exs`, `knowledge_export_read_test.exs`,
`knowledge_export_custody_live_test.exs`, Spool/Writer tests and existing Note
export tests. Do not change Snapshot, Spool, Writer, Core portable format,
OperationScope, Authorize, KeyCustodian, DownloadLease or frozen 56-file inventory
to accommodate Task 16. A new finding there returns to the parent for bounded
design/disposition; this plan grants no repair scope over it.

## Parent preflight

- [ ] Confirm Tasks 13, 14 and 15 have their required whole owners, native evidence
  and independent reviews on the actual implementation source. Do not infer
  qualification from this document's inspection fingerprints.
- [ ] Record `git status --short`, branch, HEAD and current diff; preserve every
  unrelated/pre-existing path. Allocate disjoint source writers, then close all
  authors before a formatter/Mix/SQL/runtime gate.
- [ ] Record both unresolved cleanup guarantees in the parent master/report without
  checking Task 16 complete. Parent independently reviews this design and the
  separate Step7a Task8 attribution prerequisite, seven additions and one
  startup inverse before implementation GO; no user
  permission pause is required for ordinary supported local work.
- [ ] Qualify Step7a's test-only prerequisite before Task16 source authoring or
  Step7b attribution. It depends on accepted Task8 commit
  `21d066036edbcb3f0a0737ae2dca36a9cea79427`, not Task16 implementation. The parent
  separately allocates any prerequisite test-author window after the amendment's
  independent reviews; this document author may write only the two owned docs.

All subsequent commands are **planned commands for the parent**, NOT RUN by the
architecture author. Run from the Phase 5 worktree, keep its local `_build`, and
reuse only the locked dependency checkout at the explicit MIX_DEPS_PATH below.

## Step 1: owned filesystem envelopes, first RED

**Files:** new Storage `artifact_directory.ex` and its whole owning test file.

- [ ] Write a pure filesystem RED test that builds three separate temporary roots
  with mode 0700, creates an operation, places a foreign sibling sentinel, calls
  cleanup twice, and proves only the operation was removed:

```elixir
test "cleanup is idempotent and preserves foreign siblings", %{tmp_dir: tmp} do
  context = Map.new([:root, :storage_root, :backup_root], fn key ->
    path = Path.join(tmp, Atom.to_string(key))
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    {key, path}
  end)
  sentinel = Path.join(context.root, "foreign-sentinel")
  File.write!(sentinel, "unchanged")
  assert {:ok, root} = ArtifactDirectory.prepare(context)
  assert {:ok, operation} = ArtifactDirectory.create(root)
  assert File.dir?(operation.path)
  assert :ok = ArtifactDirectory.cleanup(operation)
  assert :ok = ArtifactDirectory.cleanup(operation)
  refute File.exists?(operation.path)
  assert File.read!(sentinel) == "unchanged"
end
```

  Add separate RED cases for equal/nested roots in both directions, relative/NUL/
  noncanonical paths, symlink components, native root alias, wrong mode/uid,
  replaced root/operation inode, malformed/oversized marker, symlink marker,
  foreign directory bearing only the prefix, and two independent operations.
  Startup scavenging must remove a fully recognized dead operation and leave
  each foreign sentinel; a child symlink must never traverse to its target.

- [ ] Run RED:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/knowledge_export/artifact_directory_test.exs --seed 215378 --warnings-as-errors
```

  Expected: missing module/functions or the specific new assertion, never an
  unrelated suite failure counted as RED.

- [ ] Implement `prepare/1`, `create/1`, `cleanup/1`, `scavenge/1` with these exact
  internal interfaces. Context keys are exactly `root`, `storage_root`,
  `backup_root`; structs and extra keys fail. `prepare/1` returns
  `{:ok, %{root: path, identity: identity}}`, where identity is
  `{major_device, minor_device, inode, uid, gid}`. It verifies every ancestor
  with `File.lstat/1`, root 0700 and OS ownership; an exclusive empty 0600 probe
  supplies the current creating uid without a shell command. Check lexical
  ancestor relationships and root/ancestor native identities against both
  protected roots. Only a missing configured root may be created; no recursive
  repair/chmod of existing user directories.

```elixir
defp disjoint?(left, right) do
  left != right and
    not String.starts_with?(left, right <> "/") and
    not String.starts_with?(right, left <> "/")
end

defp identity(stat) do
  {stat.major_device, stat.minor_device, stat.inode, stat.uid, stat.gid}
end

defp canonical_absolute?(path) do
  is_binary(path) and Path.type(path) == :absolute and path != "/" and
    Path.expand(path) == path and not String.contains?(path, <<0>>)
end
```

  `create/1` returns an operation map with `id`, `path`, `root`, `root_identity`,
  `identity`, `marker_identity`. Use canonical Ecto.UUID and exclusive
  `File.mkdir/1` for `knowledge-export-<id>`, chmod 0700, then exclusive 0600
  `.ownership`. Write exactly the design's marker fields and reject encoded
  marker size above 1,024 bytes. Marker must exist before any producer starts.
  On partial creation failure remove only successfully recorded own inodes.

  `cleanup/1` first revalidates root and operation identity and the exact marker;
  lstat each child, never follow symlinks, recheck identity before removal, and
  remove marker/operation last. A missing operation is `:ok`; an identity change
  is `{:error, Error.new(:integrity_failure)}`. Preserve questionable entries.
  `scavenge/1` examines only immediate children with exact prefix/canonical UUID;
  reconstruct cleanup identity only from a valid bounded marker agreeing with
  actual stat/root identity. Return counts, never paths or marker contents.

- [ ] Rerun the whole Step 1 command GREEN. Inspect sentinel and failed-cleanup
  assertions; do not replace identity assertions with filename-only checks.

## Step 2: exact session binding, inputs and result shapes

**Files:** new `export.ex`, `export_artifact.ex`, `knowledge_export_api_test.exs`.

- [ ] Add RED tests for exact public arities, `%{}` default, true/false tombstones,
  unexpected option keys, keyword options/structs, foreign session, changed
  principal/owner/epochs, locked/revoked session, unknown/absolute/parent path,
  negative/float/string ordinal, foreign cursor and malformed handle. Unknown
  destination/root/adapter/owner options must fail before any configured callback.
  Include canary values in malformed fields and assert sanitized errors/Inspect.

```elixir
test "caller-selected owner and destination do not reach export composition" do
  parent = self()
  config = %{export_knowledge: fn _, _ -> send(parent, :unexpected_export) end}
  session = session_dto()
  for options <- [%{owner_scope_id: "CANARY"}, %{destination: "/tmp/CANARY"},
                  %{root: "/tmp/CANARY"}, %{adapter: __MODULE__}] do
    assert {:error, :invalid} = Api.export_knowledge(config, session, options)
    refute_received :unexpected_export
  end
end
```

  Define `session_dto/0` in this test with canonical fixed UUIDs, future
  `expires_at`, both epochs 0, matching `authorization_epoch: 0` and
  `unlocked?: true`; use `struct!(Singularity.Runtime.DTO.Session, fields)`.
  This test is facade-shape evidence only, not live authentication evidence.

- [ ] Run the new whole Api file RED with the Step 6 command below.
- [ ] Implement `Export.validate/2` with exactly four operation clauses. Generation
  calls `Core.KnowledgeExport.options/1`, but first requires an ordinary map.
  Entries require an exact Handle and nil or Writer's exact cursor keys;
  read requires exact Handle, normalized relative path, integer ordinal >= 0;
  close requires exact Handle. An unknown operation returns `Error.new(:invalid)`.

```elixir
defp binding(session) do
  {session.session_id, session.principal_id, session.vault_id,
   session.principal_authorization_epoch, session.vault_authorization_epoch}
end

defp requirement do
  %{required_capabilities: ["asset.read", "note.read"],
    classification: :private, requires_unlocked?: true}
end

defp relative_path?(path) when is_binary(path) do
  path != "" and Path.type(path) == :relative and
    not String.contains?(path, ["\\", <<0>>]) and
    Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
end

defp relative_path?(_), do: false
```

  Handle's enforced fields are `owner`, `operation_ref`, `binding`, `deadline`;
  owner must be a local PID, operation_ref a reference, binding five strictly
  validated identity/epoch fields, deadline an integer. Add a redacted Inspect
  implementation; do not derive JSON or include host paths. Live owner verifies
  both token and stored binding; structural validity alone does not authenticate.

  `Export.public_result/2` accepts only exact success shape per operation:
  Handle; page with exactly `entries/next_cursor`; bounded binary; or `:ok`.
  Descriptor string keys are exactly `path/media_type/byte_size/sha256`, size is
  nonnegative and digest is 64 lowercase hex characters. Reject extra host-path/
  session fields, >500 descriptors or >65,536 bytes as integrity failure.
  Pass only sanitized native Error/stable errors through Api normalization.

- [ ] Add synthetic Authorize/OperationScope composition tests with an explicit
  authoritative test store, not `session.unlocked?` alone. Change that store
  between calls and assert denial. Preserve distinct labeling from live tests.

## Step 3: prove the native lease wrapper before depending on it

**Files:** `export_artifact.ex`; additive supported-race tests in
`knowledge_export_custody_live_test.exs`; new strict characterization in
`knowledge_export_artifact_test.exs`. Frozen native files stay unchanged.

- [ ] Extend the existing live file using its `fixture!/3` and actual
  KeyCustodian/DownloadLease/SQL fixture. Add fixed trusted adapters nested in
  ExportArtifact: `Leases.lease/2`, `Leases.read/3`,
  `Leases.read_document_chunk/3`, `Leases.authenticate_empty_document_original/2`,
  `Leases.revoke/2`. Their context contains companion PID/ref and the original
  native adapters. These are not request options or new application knobs.

  Only `runtime.custodian` and `runtime.authenticated_reader` in a private copy
  are wrapped; `runtime.authorization` and its custodian remain unchanged.
  The materializer remains the SQL/read caller. Companion acquisition delegates
  the exact original native request; it changes no field or mode.

```elixir
wrapped =
  runtime
  |> Map.put(:custodian, {ExportArtifact.Leases, lease_context})
  |> Map.put(:authenticated_reader, {ExportArtifact.Leases, lease_context})
```

  Acquisition message is
  `{:export_lease, operation_ref, owner_pid, reply_ref, native_request}`.
  Companion admits it only for the stored owner/ref while generating, calls the
  original `lease/2`, records a successful lease and its monitor, then checks
  queued owner/requester DOWN and cancellation before replying. Native revoke
  is called if cancellation won; no successful lease reply is forwarded then.
  Asset read delegates and retires after native completion/termination;
  Document read delegates without changing native ordinal state. Revoke retires
  only after `:ok` or a confirmed already-dead native lease. Do not remove a
  still-live failed revoke from bookkeeping or declare cleanup complete.
  Existing synchronous native calls temporarily prevent companion mailbox
  processing; drain cancellation before forwarding after they return. Do not
  claim immediate cancellation or bounded revoke completion when native custody
  is stalled, and never report a timeout/unknown revoke result as cleanup.

- [ ] Add deterministic native tests with barriers supplied by test-owned wrapper
  adapters that delegate to the real KeyCustodian before blocking. Test both:

```elixir
for point <- [:acquired_before_recording, :recorded_before_forwarding] do
  test "owner death at #{point} revokes the real returned lease", %{tmp_dir: tmp} do
    point = unquote(point)
    fixture = fixture!(tmp, "native export source", nil)
    parent = self()
    barrier = make_ref()
    {requester, request_monitor} = spawn_monitor(fn ->
      result = Export.run(export_runtime(fixture, parent, point, barrier),
                          fixture.session, %{include_tombstones: false})
      send(parent, {:export_result, barrier, result})
    end)
    assert_receive {:lease_barrier, ^barrier, ^point, owner, companion, lease}
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}
    send(companion, {:continue_lease, barrier})
    assert_receive {:lease_revoked, ^barrier, ^lease}
    assert_receive {:DOWN, ^request_monitor, :process, ^requester, :normal}
    refute_receive {:export_result, ^barrier, {:ok, _}}
    assert_native_lease_inactive!(lease)
    assert_owned_export_removed!(fixture)
  end
end
```

  Add the requester-killed variation while owner is blocked in actual native
  document read. `export_runtime/4` creates only trusted test configuration with
  local supervisor, dedicated root, monotonic clock and the named observer.
  Its barriers are test adapters, not production options. Define
  `assert_native_lease_inactive!/1` using native read denial (`:waiting_for_unlock`
  or unavailable for terminated PID), not private process state. Define
  `assert_owned_export_removed!/1` by comparing the exact test root inventory
  after companion cleanup acknowledgement with its pre-existing sentinel list.

- [ ] In the new artifact test file, add the distinct native late-issuance witness:
  compose genuine public scope/custody and encrypted sources, retaining the
  existing live owner as regression evidence. Pause the real fixture's delegated
  key-reader before native lease construction; allow the existing public
  `KeyCustodian.lease/2` call to time out; observe owner/companion failure; release
  the native barrier and observe whether a lease is subsequently created. Do
  not change the native timeout or use arbitrary sleeps. The test receives the
  timeout result and barrier messages, with a bounded assertion timeout greater
  than the existing native five-second call timeout. Do not increase that
  timeout or change TTL. Use an isolated native lease supervisor and a test-only
  clock adapter delegating the unchanged `CustodyReader.utc_now/1` result. At
  `DownloadLease.init/1`'s existing clock call (download_lease.ex:96–102), the
  fixture's exact object-bound reader context identifies issuance; send only
  `{:native_lease_started, observer_ref, self()}` to the test observer. This
  observes the actual native PID even though the acquisition caller received
  none. After releasing the loader, existing `KeyCustodian.unlocked?/2` supplies
  a mailbox fence; it is not lease lookup. No `which_children` enumeration,
  private custody state/messages or key material. The observer never forwards
  the PID into production cleanup: retain it only for public-read assertions
  and final isolated cleanup AFTER recording the native outcome.
  Assert the strict original
  no-active-late-lease requirement. If it fails or cannot be observed through
  authorized seams, record FAILED/NOT RUN with BLOCKED_DESIGN; do not skip,
  weaken, mark expected-green, or accept Task 16.

- [ ] Parent runs the entire live owner, not a line filter:

  In the new artifact file, first add separate companion hard-death cases at
  native-acquired-before-recording, recorded-before-forwarding and known-forwarded points. Use the
  same genuine request-mode lease and ref-tagged delegate barriers, not a
  worker-mode lease or fake PID. Observe owner/companion DOWN and require actual
  native lease inactivity, no successful handle/plaintext and owned filesystem
  cleanup. A test-owned observer may retain the PID solely to assert and clean
  its isolated fixture after failure; this does not provide production lookup.
  Keep failures unsatisfied, never expected-green or waived. This additionally
  characterizes the actual nonauthor P2; runtime manifestation is NOT RUN.

  The new artifact file's native cases use the repository integration tag;
  parent runs the WHOLE new artifact file through the integration runner as
  well as its pure owner, and the retained live file below. Never count pure
  exclusion of integration cases as evidence that the strict guarantee passed:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs --seed 215378 --warnings-as-errors
```

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs --seed 215378 --warnings-as-errors
```

  This is native API/custody evidence, not browser E2E. The late-issuance
  and companion-hard-death boundaries remain unchecked until parent disposition;
  the passing ordinary
  acquisition races cannot substitute for it.

## Step 4: eventual owner, monitor handoff and bounded cancellation

**Files:** `export_artifact.ex`, new `knowledge_export_artifact_test.exs`.

- [ ] Build a real Spool/Writer test fixture inside the new owning test module:
  use `Spool.open/1`, append one valid Note resource/version and text, seal, then
  actual Writer metadata/file/finish calls. A second fixture adds one retained
  original and a ready Document fragment. Tests may use synthetic authorization
  stores, but must never replace Writer or its ETS with a fake handle map.
  Keep the fixture construction in `sealed_fixture!/1`; records use the Core
  constructors and exact fields from existing Writer fixtures, fixed UUIDs and
  independently computed SHA-256/byte sizes. Do not import a test module's
  private functions or duplicate full existing test files.

- [ ] Write the two mandatory RED lifetime tests:

```elixir
test "requester DOWN before completion leaves no handle or files", context do
  {runtime, session, root, observer} = artifact_fixture!(context)
  requester = spawn(fn -> Export.run(runtime, session, %{}) end)
  monitor = Process.monitor(requester)
  assert_receive {:export_barrier, ^observer, :before_completion, owner, companion}
  Process.exit(requester, :kill)
  assert_receive {:DOWN, ^monitor, :process, ^requester, :killed}
  send(companion, {:release_barrier, observer})
  assert_receive {:export_cleaned, ^observer}
  refute Process.alive?(owner)
  assert File.ls!(root) == ["foreign-sentinel"]
end

test "successful requester DOWN preserves actual manifest and chunks", context do
  {runtime, session, root, observer} = artifact_fixture!(context)
  parent = self()
  {requester, monitor} = spawn_monitor(fn ->
    send(parent, {:created_export, Export.run(runtime, session, %{})})
  end)
  assert_receive {:created_export, {:ok, handle}}
  assert_receive {:DOWN, ^monitor, :process, ^requester, :normal}
  assert_receive {:writer_owner, ^observer, ledger, owner}
  assert :ets.info(ledger, :owner) == owner
  assert owner != requester
  assert {:ok, page} = Export.entries(runtime, session, handle, nil)
  manifest = Enum.find(page.entries, &(&1["path"] == "manifest.json"))
  assert manifest["byte_size"] > 0
  assert {:ok, bytes} = Export.read_chunk(runtime, session, handle, "manifest.json", 0)
  assert bytes != ""
  assert {:ok, _decoded} = Jason.decode(bytes)
  assert :ok = Export.close(runtime, session, handle)
  assert :ok = Export.close(runtime, session, handle)
  assert File.ls!(root) == ["foreign-sentinel"]
end
```

  `artifact_fixture!/1` returns real directory roots and a local supervised
  Task.Supervisor plus strict SessionContext, real Writer fixture, test authority
  adapter and reference-tagged barriers. `observer` is a test-only ref; no root
  path/ledger escapes a production handle. For a manifest larger than one chunk,
  concatenate bounded ordinals according to its independently verified size;
  the compact fixture above deliberately fits one chunk.

- [ ] Run whole artifact test RED:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Implement `ExportArtifact.generate(runtime, session, options)` by starting
  the companion using the trusted `runtime.knowledge_export.task_supervisor`.
  Default is the existing `UploadRecoveryTaskSupervisor`; disabled infrastructure
  does not silently start a replacement. Companion state is exactly operation
  ref, creation/deadline/clock, requester+monitor, owner+monitor, envelope,
  optional initial Writer descriptor, native lease map and phase. Owner state
  holds runtime, original binding, handle/ref, companion+monitor, deadline and
  current Writer artifact. No central collection of artifacts is introduced.

```elixir
created_at = clock.()
deadline = created_at + 900_000
requester_monitor = Process.monitor(requester)
operation_ref = make_ref()
```

  The companion creates the directory before starting the owner. The owner
  executes `Export.materialize/4`, owns every Writer.open call, then sends
  preparation only after verification/final authorization. Define
  `accept_prepared/2` to match exact owner/ref, reject current cancellation or
  expired clock, drain a matching requester DOWN, check `Process.alive?/1`,
  demonitor with `[:flush]`, and transition to delivered before acknowledging.
  Duplicate preparation is invalid; it cannot refresh the deadline.

  Define `cancel/2` to mark closed before effects; call Writer.abort if known;
  revoke every recorded lease; stop the owner and await its exact monitor DOWN;
  call ArtifactDirectory.cleanup only after DOWN. Never delete Spool concurrently
  with generation. Cleanup failure remains recorded and content-free. An owner
  DOWN before normal close uses the same cleanup path even if ETS disappeared.
  Companion traps supervisor EXIT, performs the same bounded cleanup, then exits;
  owner monitors/links companion and fails closed on its unexpected loss.
  This closes delivery only; it does not prove lease revocation when the sole
  companion/map dies. The Step3 strict companion-death checks remain unsatisfied.

  Owner's receive loop admits only `{operation, operation_ref, caller, reply_ref,
  session, arguments}` for entries/chunk/close. All other operations fail closed.
  Recheck monotonic deadline before and after each work item. Fixed internal
  authority ticks occur at min(1,000 ms, remaining lifetime). Close discards
  artifact metadata after cleanup and serves a minimal closed receipt until the
  original deadline. On dead-owner close, perform native current authentication
  and identity-hint equality, then return a no-op `:ok`; never reconstruct files
  or direct cleanup using handle fields.

- [ ] Add cases for death inside capture, Writer.open before descriptor receipt,
  a blocked original fold, Writer.finish, accepted-before-reply, delivery-owner
  death, companion death, supervisor shutdown/restart, cancellation, exact
  deadline, session revocation, epoch change and unlock loss. Use monitor/barrier
  messages and trusted clock advancement, never Process.sleep. Assert foreign
  sentinel survival and actual native lease inactivity where native fixtures apply.
- [ ] Rerun the whole artifact file GREEN for supported cases; keep the separate
  blocked native timeout and companion-hard-death assertions unsatisfied until
  resolved. Supported-case GREEN never qualifies complete Task16.

## Step 5: exact materialization and source revalidation

**Files:** `export.ex`; additive repository `document_source_selector/2`;
artifact owning tests and the existing native live file.

- [ ] Write RED ordering tests: no Writer.open/original callback before actual
  Snapshot COMMIT; commit failure creates no handle; binary or text binding
  changed after capture fails; head/tag changes do not retarget capture; selected
  source deletion/revocation at final revalidation fails; empty source is actually
  authenticated. Assert no SQL transaction is open in Writer materialization or
  delivery callbacks. These retain Task 13/14 native checks, not replace them.
- [ ] Add the repository helper using the existing owner/RLS/export guard methods:

```sql
SELECT source_resource_id, source_resource_version_id, source_digest, source_byte_size
FROM content.document_versions
WHERE resource_id=$1 AND resource_version_id=$2 AND vault_id=$3
  AND classification='private'
LIMIT 2
```

  Require exactly one row, canonical selected version kind `document`, live
  selected version eligibility and exact captured digest/byte size. Return only
  `{:ok, {:binary_binding, :asset, source_resource_id, source_resource_version_id}}`.
  Existing `document_source/2` still validates Asset/object/version/generation
  after the sealed ref is obtained. No unauthenticated selector, head lookup,
  worker identity or cross-source fallback is allowed.

- [ ] Implement these plain orchestration entry points:

```elixir
def run(runtime, session, options)
def entries(runtime, session, handle, cursor)
def read_chunk(runtime, session, handle, path, ordinal)
def close(runtime, session, handle)
def materialize(runtime, session, options, operation)
def configuration()
def validate(operation, arguments)
def public_result(result, operation)
```

  `configuration/0` delegates to fixed Artifact configuration: three trusted
  roots, monotonic clock and existing task supervisor. There is no request-driven
  adapter lookup. `run/3` uses Core options and native live scope before starting
  generation. The delivery methods validate the exact operation/handle and
  route only to that owner's operation-ref protocol.

  `materialize/4` opens Spool with operation.path, configured storage/backup roots
  and trusted clock. It calls Snapshot.capture and checks the request repo is
  outside a transaction, then opens Writer with sealed capture, normalized
  options and `original_fold`. Notify companion of the initial Writer descriptor
  before the first mutation. Reduce the eight collections in native fixed order:

```elixir
@collections ~w(resources versions fragments tags tag_assignments relationships attachments citations)a

defp append_records(capture, writer) do
  Enum.reduce_while(@collections, {:ok, writer}, fn collection, {:ok, current} ->
    result = Spool.reduce_metadata(capture, collection, current, fn record, acc ->
      Writer.append_manifest_record(acc, collection, record)
    end)
    case result do
      {:ok, next} -> {:cont, {:ok, next}}
      {:error, _} = error -> {:halt, error}
    end
  end)
end
```

  Iterate selected versions to append only included Asset/Document originals.
  `original_fold(selector, acc, emit)` loads one sealed binding, builds the exact
  ExportRead descriptor and calls `descriptor.reduce.(acc, emit)`. For Document,
  obtain the exact selector using the new repository helper in a short native
  read scope, then retrieve the sealed ref; do not scan/trial every binary_ref.
  Decode one bounded binding record, check its full digest/size using Spool,
  and discard it after that original is complete.

  Iterate fragment text refs in `{resource, version, ordinal, fragment_id}` order.
  Build `%{capture: capture, text_ref: ref, fragment: record}`, call
  ExportRead.fragment, require exact descriptor size/digest, then
  Writer.append_file with the original sealed ref. Iterate Note refs afterward,
  with `%{capture: capture, text_ref: ref, version: version}` and ExportRead.note.
  Do not substitute descriptor plaintext for the Writer's sealed reference or
  change existing portable rendering.

  After Writer.finish, repeat native exact-source guards for all included
  originals and text versions. Asset guard calls existing `lock_asset_source/3`
  with `:zero` for empty or `0..0` otherwise; Document uses existing
  `document_source/2`; Note/fragment use existing revalidation methods. Every
  guard runs through unchanged OperationScope/Authorize with its capability.
  A final combined authorization scope performs publication only after COMMIT:

```elixir
OperationScope.with_shared_request(runtime, session, requirement(), fn _repo ->
  {:after_commit, fn -> ExportArtifact.accept_completed(operation, artifact) end}
end)
```

  `accept_completed/2` is the exact prepared/accepted handshake from Step 4,
  executed by the eventual owner; it cannot be called by a public request to
  turn a caller map into an artifact. Abort and remove the capture after successful
  completion, retaining only Writer's completed artifact until owner close.
  On failure cleanup is coordinated with the companion; raw exceptions and
  caught terms never leave the orchestrator.

- [ ] Implement bounded delivery through the same shared native scope:

```elixir
OperationScope.with_shared_request(runtime, session, requirement(), fn _repo ->
  {:after_commit, fn -> Writer.read_chunk(artifact, path, ordinal) end}
end)
```

  Entries uses Writer.entries in that callback. Original session/principal/owner/
  both epochs must equal the owner's stored binding before entering the scope.
  Native live checks still run each time. A foreign mismatch denies without
  cancelling the victim artifact. Owning-session native denial or checksum/read
  failure closes delivery and triggers cleanup. No whole transfer transaction.

- [ ] Run the whole source/read/snapshot/writer owners in Step 8; ensure previous
  large-metadata record iteration and fixed quota assertions remain intact.

## Step 6: seven exact additions and one atomic startup replacement

**Files:** Api, application, three config files, Api/application owning tests.
Every block below includes its final newline. Code fences do not belong to
source. Context strings are literal existing bytes; insert the seven additions
once and replace only the P5-A5 old call, preserve every
other byte, then parent formatting/review reconciles any changed planned block
before its approved hash is frozen. Never update a historical baseline hash.

### P5-A1 — Api orchestration alias

Before: `  alias Singularity.Runtime.StorageAdapter\n`

After: `  alias Singularity.Runtime.UnlockVault\n`

```elixir
  alias Singularity.Runtime.Knowledge.Export, as: KnowledgeExport
```

### P5-A2 — Api four operations and closed shared helper

Before: `  def export_note(_config, _session, _resource_id), do: {:error, :invalid}\n\n`

After: `  @spec create_note(Session.t(), map() | keyword()) ::\n`

```elixir
  def export_knowledge(session, options),
    do: with_production(&export_knowledge(&1, session, options))

  @doc false
  def export_knowledge(config, session, options),
    do: knowledge_export_call(config, :export_knowledge, session, [options])

  def knowledge_export_entries(session, handle, cursor),
    do: with_production(&knowledge_export_entries(&1, session, handle, cursor))

  @doc false
  def knowledge_export_entries(config, session, handle, cursor),
    do: knowledge_export_call(config, :knowledge_export_entries, session, [handle, cursor])

  def read_knowledge_export_chunk(session, handle, path, index),
    do: with_production(&read_knowledge_export_chunk(&1, session, handle, path, index))

  @doc false
  def read_knowledge_export_chunk(config, session, handle, path, index),
    do: knowledge_export_call(config, :read_knowledge_export_chunk, session, [handle, path, index])

  def close_knowledge_export(session, handle),
    do: with_production(&close_knowledge_export(&1, session, handle))

  @doc false
  def close_knowledge_export(config, session, handle),
    do: knowledge_export_call(config, :close_knowledge_export, session, [handle])

  defp knowledge_export_call(config, operation, %Session{} = session, arguments)
       when is_map(config) and not is_struct(config) and
              operation in [
                :export_knowledge,
                :knowledge_export_entries,
                :read_knowledge_export_chunk,
                :close_knowledge_export
              ] do
    with :ok <- KnowledgeExport.validate(operation, arguments),
         {:ok, context} <- note_source_session(session) do
      config
      |> invoke(operation, [context | arguments])
      |> KnowledgeExport.public_result(operation)
      |> normalize_knowledge_export_result()
    else
      result -> normalize_error(result)
    end
  end

  defp knowledge_export_call(_config, _operation, _session, _arguments),
    do: {:error, :invalid}

  defp normalize_knowledge_export_result(:ok), do: :ok
  defp normalize_knowledge_export_result({:ok, _} = result), do: result
  defp normalize_knowledge_export_result(result), do: normalize_error(result)

```

### P5-A3 — Api production callbacks

Before: `      export_note: fn session, resource_id ->\n        NoteExportReader.run(runtime, session, resource_id)\n      end,\n`

After: `      finish_upload: &UploadSession.finish/1,\n`

```elixir
      export_knowledge: &KnowledgeExport.run(runtime, &1, &2),
      knowledge_export_entries: &KnowledgeExport.entries(runtime, &1, &2, &3),
      read_knowledge_export_chunk: &KnowledgeExport.read_chunk(runtime, &1, &2, &3, &4),
      close_knowledge_export: &KnowledgeExport.close(runtime, &1, &2),
```

### P5-A4 — Api trusted operation configuration

Before: `      key_wrapper: KeyWrapper,\n`

After: `      note_repository: NoteRepository,\n`

```elixir
      knowledge_export: KnowledgeExport.configuration(),
```

### P5-A5 — one exact application startup-call replacement

Before: `    children = application_children(composition())\n\n`

After: `  end\n\n  @doc false\n`

Old (actual application.ex:37–40, including final LF):

```elixir
    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Singularity.Runtime.Supervisor
    )
```

New (replace Old exactly once; this is not a prefix insertion):

```elixir
    Singularity.Runtime.Knowledge.ExportArtifact.start_runtime(
      children,
      [strategy: :one_for_one, name: Singularity.Runtime.Supervisor],
      Application.fetch_env!(:singularity_runtime, :start_infrastructure)
    )
```

`start_runtime/3` is trusted internal composition, never an Api option or
generic public callback executor. In new ExportArtifact implement this shape:

```elixir
@doc false
def start_runtime(children, options, false),
  do: Supervisor.start_link(children, options)

def start_runtime(children, options, true) do
  lock = {{__MODULE__, :runtime_start}, self()}

  case :global.trans(lock, fn -> start_guarded(children, options) end, [node()], 0) do
    :aborted -> {:error, :storage_unavailable}
    result -> result
  end
end

defp start_guarded(children, options) do
  case Process.whereis(Keyword.fetch!(options, :name)) do
    pid when is_pid(pid) ->
      {:error, {:already_started, pid}}

    nil ->
      case Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor) do
        pid when is_pid(pid) ->
          {:error, :storage_unavailable}

        nil ->
          with {:ok, root} <- prepare_startup_root(),
               {:ok, _counts} <- ArtifactDirectory.scavenge(root) do
            Supervisor.start_link(children, options)
          else
            _error -> {:error, :storage_unavailable}
          end
      end
  end
end

defp prepare_startup_root do
  configuration()
  |> Map.take([:root, :storage_root, :backup_root])
  |> ArtifactDirectory.prepare()
end
```

`configuration/0` is the already planned trusted configuration; its filesystem
keys are `root`, `storage_root`, `backup_root` and its remaining fields are the
existing task supervisor and clock. Step1 `scavenge/1` success is explicitly
`{:ok, counts}`. Root/cleanup errors are content-free and never start the tree.
The exact Application call fixes the production supervisor name/options;
test-owned callers can supply their own named native supervisor, not a fake
start-result callback. No request chooses children, names, roots or lock IDs.

The resource `{{ExportArtifact, :runtime_start}, self()}` serializes all such
starts on this node regardless of root. Explicit `[node()]` prevents a
distributed-lock expansion; zero retries means contention has no filesystem
effects and no queue. There is no separate pre-start cleanup call. Guarded
execution includes absence rechecks, validated preparation/scavenging AND the
actual synchronous `Supervisor.start_link/2` return. Preserve native caller/link,
child list/order, options and native result; false never accesses roots/guard.
OTP releases the lock after return/exception and when its holder dies. A live
registered runtime or remaining task supervisor still prevents later cleanup.
Do not increase native start timeouts, detach startup into a new process, catch
native failures as success or add a registry/catalog/coordinator. This is local
startup exclusion, not shared-root multi-node support.

- [ ] Before implementation, write causal RED startup tests in the whole
  application/artifact owners with real native Supervisor.start_link and real
  owned directories. Use unique reference-tagged messages and fixture-owned
  supervisor names; never stop the running test application or parent services.
- [ ] First expose the old check/cleanup/start gap in an explicitly labeled
  test-owned reproduction of that old ordering using actual ArtifactDirectory
  and Supervisor functions. Ref-tagged barriers pause B after its absence
  check while A starts and creates a recognized live operation; releasing B
  demonstrates wrongful deletion. This synthetic ordering arrangement is not
  proof of the new helper. For actual helper contention before filesystem work,
  a test process holds the exact fixed local OTP lock and acknowledges its ref;
  invoke actual start_runtime and require `{:error, :storage_unavailable}` with
  untouched roots. Release the holder and use the real child-init case below
  to prove the helper itself retains that same lock through native startup.
  No production observer knob, replaceable start callback or new dependency.
- [ ] Use a real child start/initialization barrier to hold A AFTER supervisor
  registration but BEFORE start_link returns. B still fails lock contention;
  release the child, observe A's actual successful return, create a recognized
  live operation through ArtifactDirectory under that tree, then retry B.
  Assert `{:error, {:already_started, a_supervisor}}`, unchanged operation
  inode/marker/content and unchanged foreign-sibling sentinel. A recorder that
  merely reports success cannot qualify registration or this live-file case.
- [ ] Repeat with root/cleanup failure, native child-start failure, an exception
  during trusted preparation and starter hard kill at native child init. Observe
  exact DOWN/result; after
  failure or death a fresh attempt acquires the lock. It must still refuse
  while either registered supervisor survives; after owned supervisors are DOWN
  a retry can scavenge recognized leftovers and actually start. Preserve foreign
  and malformed-marker sentinels in every case. No arbitrary sleeps or longer
  production timeout; bounded test receive deadlines are only harness limits.
- [ ] Exercise false with nonexistent/invalid configured roots and actual native
  supervision: no root created/read/validated, same native options/results and
  caller link. Retain literal child-order and all existing application assertions.
- [ ] Parent records focused causal RED before source edits, then whole Step6
  owning files GREEN after the minimal implementation; all runtime checks here
  are currently NOT RUN and do not bypass the strict lease blockers.

### P5-C1 — dev ephemeral export root

Before: `      Path.expand("../var/storage", __DIR__)\n    )\n\n`

After: `config :singularity_storage, Singularity.Storage.MigrationRepo,\n`

```elixir
export_backup_root =
  System.get_env("SINGULARITY_BACKUP_ROOT", Path.expand("../var/backups", __DIR__))

config :singularity_runtime,
  knowledge_export_root:
    System.get_env(
      "SINGULARITY_EXPORT_ROOT",
      Path.join(Path.dirname(export_backup_root), Path.basename(export_backup_root) <> "-knowledge-export")
    )

```

### P5-C2 — test run-scoped ephemeral export root

Before: `  storage_root: Path.join([System.tmp_dir!(), "singularity", "test", test_run_id])\n\n`

After: `config :singularity_runtime,\n  start_infrastructure: false,\n`

```elixir
config :singularity_runtime,
  knowledge_export_root:
    Path.join([System.tmp_dir!(), "singularity-knowledge-export", "test", test_run_id])

```

### P5-C3 — optional production root, no new required environment

Before: `  storage_root = System.fetch_env!("SINGULARITY_STORAGE_ROOT")\n\n`

After: `  audit_fingerprint_secret =\n`

```elixir
  config :singularity_runtime,
    knowledge_export_root:
      System.get_env(
        "SINGULARITY_EXPORT_ROOT",
        Path.join(Path.dirname(backup_root), Path.basename(backup_root) <> "-knowledge-export")
      )

```

- [ ] Add RED composition assertions with Config.Reader for dev/test and a
  test-owned prod environment. Check the exact sibling/run-scoped defaults,
  optional override, unchanged pre-existing required variables and trusted
  adapter/supervisor identity. Do not start a production runtime or modify real
  environment secrets. Root overlap/symlink rejection is tested through the
  storage helper and startup; configuration alone is not validation.
- [ ] Insert P5-A1–A4/C1–C3, replace exactly P5-A5, implement `configuration/0`
  and the guarded startup helper, then
  run whole facade/application owners:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs --seed 215378 --warnings-as-errors
```

## Step 7: exact architecture attribution, preserving all old baselines

### Step7a — prerequisite: exact accepted Task8 attribution (test-only)

**Only implementation file for this prerequisite:**
`apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs`.
Master Phase5 Task8 explicitly authorizes Application's WorkerRepo alias and
`object_storage` compatibility; governing design §6 supplies the same boundary.
`git show 21d066036edbcb3f0a0737ae2dca36a9cea79427 -- apps/singularity_runtime/lib/singularity/runtime/application.ex`
confirms exactly those two changes. This amendment allows their missing test
attribution, not a new Application edit. Do not amend Task8's source, owning
dependency assertion, custody plumbing, any frozen file or any earlier tuple.

The first Application Phase3 alias tuple currently has ZERO context matches:
WorkerRepo now follows SearchProjectionReconciler before `@impl true`.
Phase4 has no Application tuples. The old `worker_additions/0` list also lacks
Task8. Reversing P5-A5 alone recovers current raw `3ce2dad6…`, not the historical
`4bed50e5…`. This is the actual reviewed P2, not unauthorized startup drift.

Use two separate fixed tuples, P5-T8A then P5-T8B, scoped only to `@application`.
All nonempty Old/New blocks below include their final LF. Before/After are
literal decoded strings; Old for P5-T8A is exactly the empty binary `""`, with
zero bytes, not an LF. Inversion operates on the test's source copy only.

**P5-T8A — accepted alias addition:**

Before: `  alias Singularity.Storage.Postgres.SearchProjectionReconciler\n`

After: `\n  @impl true\n`

Old: `""`

New:

```elixir
  alias Singularity.Storage.WorkerRepo
```

Relocation destination: after the unique
`  alias Singularity.Runtime.BackupKeyLease\n`.

**P5-T8B — accepted object-storage replacement:**

Before: `      object_lock: ObjectLock,\n`

After: `      storage: storage\n`

Old:

```elixir
      object_storage: {Exporter, storage},
```

New:

```elixir
      object_storage: {Exporter, %{repo: WorkerRepo, storage: storage}},
```

Relocation destination: after the unique `      assets: AssetRepository,\n`.

| Tuple | Old SHA-256 | New SHA-256 |
| --- | --- | --- |
| P5-T8A | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `39a200187ee4217b6af3360373f70fa99161596960c6d41bf1a5505b4593ef54` |
| P5-T8B | `765151e924b1527ee46e84b28c1f4767fb8a24f7e4a0002f4bfb3bc92d978f63` | `c7135faaa946b7ee597e9671c314a92a1ece93aaf2b3a0da4d72ffc92e84adc2` |

| Tuple | Before + Old + After SHA-256 | Before + New + After SHA-256 |
| --- | --- | --- |
| P5-T8A | `1eb83e25ae05b4c71e16192cd860d41bcd2276680872dc14f309790e8a84bb1f` | `3d711a1b22e36f343aedd6f100553d22a36aecc0d9a53fcca215a99ac6cb0b0b` |
| P5-T8B | `ab107ddaf89d242ac18e359d680c0f11b7b35199be202c119672c769fcfe8050` | `bb3696cd1d51ab0af2f6cb7a04cb6f8d388b38830892703f4ead6f591baf2c63` |

- [ ] Characterize the existing whole architecture owner before changing it;
  retain the actual missing Phase3 context failure as prerequisite evidence,
  not a Task16 startup or production regression. Add RED cases for both tuples:
  missing New/restored Old, duplicate New, altered WorkerRepo token, moved New
  with original Old/context restored, and changed Before/After. For T8B also
  reject Old and New coexisting. Require one New and one exact New context;
  require no nonempty Old. Verify relocation actually moved the bytes and
  restored the old site. Mutate both boundaries independently. Reject any extra
  alias/object-storage clause or adjacent unauthorized registration through the
  original digest check; do not ignore WorkerRepo/Exporter terms globally.
- [ ] Implement `phase5_task8_replacements/0` with exactly two fixed tuples:
  `{id, before, old, new, after_bytes, old_hash, new_hash, old_context_hash,
  new_context_hash, relocation_destination}` from the literals/tables above.
  Never calculate expected literals/digests from whichever source is current.
  Implement the separate inverse with no permissive already-normalized branch:

```elixir
defp undo_phase5_task8!(@application = path, source) do
  Enum.reduce(phase5_task8_replacements(), source, fn
    {id, before, old, new, after_bytes, old_hash, new_hash, old_context_hash,
     new_context_hash, _destination}, remaining ->
      assert_digest!(path <> id <> " old", old, old_hash)
      assert_digest!(path <> id <> " new", new, new_hash)
      assert_digest!(path <> id <> " old context", before <> old <> after_bytes, old_context_hash)
      context = before <> new <> after_bytes
      assert_digest!(path <> id <> " new context", context, new_context_hash)
      assert [_, _] = String.split(remaining, new)
      if old != "", do: refute(String.contains?(remaining, old))
      assert [prefix, suffix] = String.split(remaining, context)
      prefix <> before <> old <> after_bytes <> suffix
  end)
end

defp undo_phase5_task8!(_path, source), do: source
```

- [ ] Preserve the existing `assert_runtime_baseline!/3` BODY as a separate
  `assert_historical_runtime_baseline!/3`: unchanged Phase4 organization, Phase4,
  Phase3, Phase2 special additions, Phase2 workers, then original digest. Add
  an outer current-source entry point. During this prerequisite ONLY:

```elixir
defp normalize_phase5!(path, source), do: undo_phase5_task8!(path, source)

defp assert_runtime_baseline!(path, source, expected) do
  assert_historical_runtime_baseline!(path, normalize_phase5!(path, source), expected)
end
```

  The existing positive loop over `@runtime_baselines` always uses this outer
  strict entry point on raw source. Do not replace the five historical digests.
  Preserve the full earlier helper body, `assert_phase2_runtime_baseline!/3`,
  all four old tuple lists, Api regex/digest pairs and registration assertions.

- [ ] Explicitly adapt ALL seven existing mutation groups, preserving every
  case, input, assertion and `assert_raise`: generated queue/alias/child
  relocation; unauthorized Document/legacy changes; approved additions;
  worker blocks; Phase3 blocks; Phase4 blocks; Task6 organization blocks.
  At each raw source read, first assert the outer current-source baseline,
  then assign `source = normalize_phase5!(path, source)` BEFORE constructing
  mutations or checking literal contexts. Existing calls on these normalized
  mutations use `assert_historical_runtime_baseline!/3`, never the outer helper
  that would demand a second Task8 inverse. Worker tests still additionally
  strip Phase4 then Phase3 and call the unchanged Phase2 helper on mutations.
  Phase4 tests still normalize organization additions in their existing place.
  Keep all registration scans, token mutations and relocation checks. This
  explicit source-stage change preserves historical witnesses; catching their
  failures at a missing newer tuple would not exercise the intended old guard.

- [ ] Add separate Task8 current-source mutation tests using the outer helper;
  prove that a missing Task8 tuple fails instead of being admitted as a
  historical source. Independently check inverse output and the original
  Application digest, retaining all whole-owner assertions. During this
  prerequisite do not require the as-yet absent Task16 blocks.
- [ ] Parent runs the whole architecture and application owners, without line
  filters, then independent SPEC and distinct fresh QUALITY for the test change:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs --seed 215378 --warnings-as-errors
```

  These commands are NOT RUN by this author. Preserve every application assertion
  including accepted Task8 composition. Do not run E2E. Prerequisite acceptance
  qualifies attribution only; neither strict lease guarantee nor Task16 GO follows.

### Step7b — Task16 layer after the qualified Step7a prerequisite

Exact proposed addition and context SHA-256 values for the seven UNCHANGED
additions follow. P5-A5 has its separate old/new replacement receipt below.
Context is the
decoded literal Before bytes, followed by the fenced block including its final
newline, followed by the decoded literal After bytes. `\\n` in the prose means
one LF byte. These are source proposals frozen for review, not a claim that the
formatter or compiler was run by this author.

| Block | Addition SHA-256 | Context SHA-256 |
| --- | --- | --- |
| P5-A1 | `bafbd33be306cb42c49cc94eb8ceb15e22c74cac3373d6fc0f0b982ccabee525` | `d35cf69e969c288154f56a5cd178d98489a5d02e5af10583f835da2640bb30da` |
| P5-A2 | `a42d2e03a9b424de2267a5c80d4853fca8cf13c3d39e7cbef1b18bc4702c5224` | `002c4066ea063568421c00649d1a2a8f0cd7a0a062ffa58787cc8fc7e3a081f0` |
| P5-A3 | `3bd6d3d4cf89fa5ca6f8f0f6d3a6b3ce9aefe20eae016d133f0ec9d470df7767` | `84f7d773db76740d8cd33772f8ae2936ca01590e9ba5102808df0a9c9a211275` |
| P5-A4 | `4a0c358b71f8262563abe79f3235339699348472e1179603c223a6add01acadd` | `7a29bb7d9a9145cec7538b412ee8d082a76276066406c9e7a924f82d48b24813` |
| P5-C1 | `414ee65a6c7c333fca7a3d84fe181b1b231f67b44ef9e5a134e28afdb517c052` | `cd255aed0ce6420944d42bf66b2929adb7c7b14f9285f760cd06ef5d36832d35` |
| P5-C2 | `bcfc6c807c63982522bd2294aacca2758f1531382bf4843f6f732af2d8d0f298` | `f46a458f657f53d3dea0f8d42891eef4c6c78188f54ceabb6920506e0bb62a00` |
| P5-C3 | `8e04ee2d4050d7f13b1725c5106e3c365f0c8416464a4b45b0208f075530e099` | `4bd5f62e207938b44857bf2ba76e0368cfadb62acbf4b6868d5c638eb22db621` |

P5-A5 exact replacement receipt (each fenced call includes its final LF):

| Bytes | SHA-256 |
| --- | --- |
| Old native call | `4d3a4b83c158a6934ec69ee8040001792f2aca027f0688ccc5924c5830541359` |
| New guarded call | `6dbc92f768417e9ff94187ad848dcce494b3dd0aff7226f1173161c2be6ac275` |
| Before + Old + After | `4efa62de7c4f815e083641f2e31f1d6d7cdca3a85e49c05305eb03cb22626529` |
| Before + New + After | `1ae1d3a76f2cfed98ce35885974d80a6a8188f0e5c55f9946d4ed5ad2e4e19e7` |

Document-only byte calculation at amendment HEAD found exactly one native old
context. Applying this single replacement IN MEMORY then its inverse recovered
the original application bytes exactly, SHA-256
`3ce2dad60cb851170ad295cf6a37024d192351fc6cf420e9401694fb7cacbe4c`.
No source was written, formatted, compiled or executed. This original startup
round-trip receipt remains valid but was INSUFFICIENT to establish the full
pipeline: actual nonauthor SPEC found the omitted Task8 prerequisite. It is not
a new whole-module acceptance whitelist. After Task16 inversion/stripping AND
Step7a's exact Task8 inverse, unchanged Phase4/3/2 normalization reaches digest
`4bed50e5ab4f7ed351b0e7497a943f940466bce53101928ce4e906ae910abe35`.

The repair's complete read-only byte calculation used the actual architecture
test's 5 organization tuples, 5 Phase4 tuples, 15 Phase3 tuples, 7 worker tuples,
Phase2 special additions and all 4 Api addition regex/digest pairs. Proposed
Task16 additions were applied and removed in memory; P5-A5 was applied and
inverted. Task8's two inverses then ran before the unchanged historical stages:

| Application stage | Exact SHA-256 |
| --- | --- |
| Proposed P5-A5 applied in memory | `f562d82432fea2ec50e5599c780634deccb9266fc0b729525699b457f582bd39` |
| P5-A5 inverse; Task8 still present | `3ce2dad60cb851170ad295cf6a37024d192351fc6cf420e9401694fb7cacbe4c` |
| P5-T8A then P5-T8B inverse; Phase4 has no Application tuples | `4deda19432de3174c2f737216c8185e3cdea8bb91d3960475308a27558bdfbca` |
| Existing Phase3 stripped | `3ef291feb5d5510d3bbb97448c6d4f1cbe88c056ebdef01bc2576d702fb9b192` |
| Existing Phase2 special additions then worker additions stripped | `4bed50e5ab4f7ed351b0e7497a943f940466bce53101928ce4e906ae910abe35` |

Pre-Task8 output equaled Task8's actual parent Application byte-for-byte; final
output equaled Application at `6c3e8d5afb2cc9dbf264d276796070e16aa49e55`.
All other four `@runtime_baselines` also recovered their existing exact digests:
Api `eded245a1bd95410b323192de836c9b1de8cec14de4b26cb8e41263d66ebf3c4`,
dispatcher `2f92227526e692931e4d8e501635eb94f79e59f90f54bab7f5f9891581f507c8`,
config/config `ebbf6e0d51ce707a67d7e29115ad0e2af7fbc372ff68072a67279ec1fa5304f8`,
config/runtime `1847759a3e3461681f5e832cb4b9e35cfb1ae0217665afd7c60b375128fa55ca`.
Dev/test additions round-tripped to the unchanged raw hashes below. All seven
addition/context receipts and P5-A5's four receipts were retained. Eleven
Task8 negative byte variants were rejected in memory; native/ExUnit acceptance
and the complete planned negative matrix remain NOT RUN, not inferred PASS.

P5-A1–A4 belong only to `apps/singularity_runtime/lib/singularity/runtime/api.ex`;
P5-A5 only to `apps/singularity_runtime/lib/singularity/runtime/application.ex`;
P5-C1/C2/C3 only to `config/dev.exs`, `config/test.exs`, `config/runtime.exs`.
Pre-Task16 raw config digests observed during inspection are:

| Path | Raw SHA-256 before additions |
| --- | --- |
| `config/dev.exs` | `b028676aba7578fad1e217fbecc94c0aad66610c671eeec1220d1808b3d6c8d0` |
| `config/test.exs` | `587ad6ff1dadd4cd3efe69a8dd485b26c9f28175e6a19edb565ae11c857e0ea2` |
| `config/runtime.exs` | `1847759a3e3461681f5e832cb4b9e35cfb1ae0217665afd7c60b375128fa55ca` |

Use these exact relocation destinations: Api alias after
`  alias Singularity.Core.Error\n`; public/helper block before
`  @spec login(map()) :: {:ok, String.t(), Session.t()} | {:error, atom()}\n`;
production callbacks before `      list_assets: fn session, params ->\n`;
runtime configuration after `      assets: AssetRepository,\n`; application
replacement before the unique `  @doc false\n  @spec application_children(map())`;
each config block immediately after
`import Config\n`. Relocation tests must verify that they actually moved the
block and that its original surrounding bytes were restored.
For P5-A5 relocation, restore the exact Old call at its original site and move
New to that unrelated destination. This must fail, not normalize successfully.

**File:** `knowledge_phase1_contract_test.exs`; `notes_scope_contract_test.exs`
remains an unchanged whole owner.

- [ ] First write RED mutations for every P5 block: remove, duplicate, alter a
  token/constant, and relocate identical bytes to an unrelated unique anchor.
  Add unknown-operation, unknown callback and extra function-clause source
  mutations. A documentation attribute must not hide an adjacent registration.
  Assert exact Api public arities: export 2/3; entries 3/4; chunk 4/5; close 2/3.
- [ ] Add `phase5_additions/0` tuples containing exact path, literal preceding,
  literal addition, literal following, block hash, context hash and relocation
  destination. The hash inventory above is computed from this plan's exact
  proposed blocks, not from accepting arbitrary current implementation bytes.
  Parent formatting changes require review of the resulting block and its
  corresponding planned hash before contract insertion.
  This list has exactly seven tuples; P5-A5 is never stripped as an addition.
- [ ] Add `phase5_startup_replacement/0` returning exactly
  `{before, old, new, after, old_hash, new_hash, old_context_hash, new_context_hash}`
  using the complete Step6 literals and receipt above, not source-derived values.
  Add RED lexical negatives: remove New; duplicate New; alter module/function,
  children/options/boolean; restore Old alone; keep Old as well as New; relocate
  New while restoring Old; change either surrounding context; add another
  startup call/clause outside the approved replacement. No ignored comments or
  documentation attributes may hide adjacent code. Assert literal uniqueness
  BEFORE inversion, then run the unchanged historical baseline checks.
- [ ] Implement Task16 exact inversion and seven-addition stripping ahead of
  qualified Step7a Task8 normalization and the unchanged historical pipeline:

```elixir
defp undo_phase5_startup!(@application = path, source) do
  {before, old, new, after_bytes, old_hash, new_hash, old_context_hash,
   new_context_hash} = phase5_startup_replacement()
  assert_digest!(path <> " P5-A5 old", old, old_hash)
  assert_digest!(path <> " P5-A5 new", new, new_hash)
  assert_digest!(path <> " P5-A5 old context", before <> old <> after_bytes, old_context_hash)
  context = before <> new <> after_bytes
  assert_digest!(path <> " P5-A5 new context", context, new_context_hash)
  assert [_, _] = String.split(source, new)
  refute String.contains?(source, old)
  assert [prefix, suffix] = String.split(source, context)
  prefix <> before <> old <> after_bytes <> suffix
end

defp undo_phase5_startup!(_path, source), do: source
```

```elixir
defp strip_phase5_additions!(path, source) do
  source = undo_phase5_startup!(path, source)
  Enum.reduce(phase5_additions(), source, fn
    {^path, preceding, addition, following, block_hash, context_hash, _destination}, remaining ->
      assert [_, _] = String.split(remaining, addition)
      assert_digest!(path <> " Phase 5 addition", addition, block_hash)
      context = preceding <> addition <> following
      assert [_, _] = String.split(remaining, context)
      assert_digest!(path <> " Phase 5 context", context, context_hash)
      strip_unique!(remaining, addition)

    _other, remaining ->
      remaining
  end)
end
```

  Replace Step7a's `normalize_phase5!/2` body with the explicit ordered
  composition below; all old mutation setups already use that one boundary.
  Also adapt the separate accepted Task8 positive witness as specified next.
  Both input boundaries require Task16 blocks on raw input, never optional
  detection:

```elixir
defp normalize_phase5!(path, source) do
  source = strip_phase5_additions!(path, source)
  undo_phase5_task8!(path, source)
end
```

  The accepted positive witness currently calls `undo_phase5_task8!/2` directly
  twice on raw Application, so changing only `normalize_phase5!/2` cannot stage
  it. Replace only that witness's input stage with this exact future test body:

```elixir
test "accepted Task8 inverse recovers independently fixed pre-Task8 Application bytes" do
  raw = read_source(@application)
  Enum.each(phase5_task8_replacements(), &assert_task8_tuple!(raw, &1))
  staged = strip_phase5_additions!(@application, raw)
  inverse = undo_phase5_task8!(@application, staged)

  assert_digest!(
    @application <> " Task8 inverse",
    inverse,
    "4deda19432de3174c2f737216c8185e3cdea8bb91d3960475308a27558bdfbca"
  )

  assert_historical_runtime_baseline!(
    @application,
    inverse,
    @runtime_baselines[@application]
  )
end
```

  Retain raw current-source Task8 tuple guards BEFORE strict Task16-only
  stripping. `strip_phase5_additions!/2` already performs the P5-A5 inverse;
  it neither strips Task8 nor accepts absent required Task16 bytes. The fixed
  pre-Task8 digest and historical-baseline assertions above are unchanged;
  only their source input is staged. Do not use `normalize_phase5!/2` here
  before another Task8 inverse, add optional detection/broad stripping, or
  change a digest. This snippet is a source proposal, NOT RUN by this author.

  Complete order is P5-A5 inverse → seven Task16 additions → P5-T8A inverse →
  P5-T8B inverse → existing Phase4 organization → Phase4 → Phase3 → Phase2
  special additions → Phase2 workers → original digest. Path-specific no-op
  clauses apply only to other files, never to a missing required Application
  tuple. The thirteen accepted Task8 tuple mutation cases retain raw Task16
  blocks, `task8_mutation!/3` and their direct `undo_phase5_task8!/2`
  `assert_raise` route: the missing/duplicate/altered/relocated/context/coexisting
  tuple itself still causes rejection. The three extra-registration cases
  retain raw inputs, their direct inverse comparisons, the outer baseline
  helper and exact digest-error message assertion. P5-A5 survives identically
  in both direct comparison inputs; the outer helper then strictly removes
  Task16 before Task8 and the historical digest, preserving causal rejection
  of each extra registration. Do not turn those witnesses into an earlier
  missing-Task16 failure. Old phase mutation cases use normalized source and the
  historical helper exactly as Step7a requires. Do not change
  old tuples, digests, required assertions or old phase documents. Dev/test
  files get their own pre-Task16 raw baselines (recorded above); runtime.exs
  retains its existing historical digest after the one addition is stripped.
  `config/config.exs` and dispatcher receive no Phase 5 export exception.

  Closed attribution scans parsed AST after removing only documentation
  attributes, and compares exact operation names/arities and exact qualified
  Export/ExportArtifact references in the approved blocks. Invert the one call
  and strip the seven exact additions; assert no new export registration remains.
  Do not add an allowlist
  that ignores all `Knowledge.Export`/`KnowledgeExport` terms. Additional clauses
  of an existing name must fail the byte guard even if its arity is unchanged.

- [ ] Run the entire Task 16 pure owner command from the master, unchanged:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --seed 215378 --warnings-as-errors
```

## Step 8: parent whole-file verification and independent disposition

- [ ] Close all authors. Parent reads full changed source, tests and exact diff,
  including native authority path and every cleanup/error branch. Confirm no
  host path or body/title/label/storage-reference/session/key/job fields appear
  in errors/logs/telemetry/Inspect. Check phase/lease map cleanup for each exit.
- [ ] Run the retained source/read/Writer pure owners and new filesystem owner:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/spool_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/writer_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/artifact_directory_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Run the whole native owner from Step 3 plus retained snapshot native owner:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs --seed 215378 --warnings-as-errors
```

- [ ] Run parent static/format/compile/zero-cycle checks appropriate to the changed
  files, with no scope-wide autofix or acceptance bypass:

```sh
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix compile --warnings-as-errors
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix xref graph --format cycles --fail-above 0
```

- [ ] Compare the parent's existing exact 56 frozen-file manifest and all protected
  source hashes; preserve seven applications. Record actual commands/exits/counts,
  SQL fixture identity, scratch-root removal and normal repository cleanup.
  Do not expose connection strings, content or credentials in the report.
- [ ] Obtain nonauthor SPEC review followed by a distinct fresh QUALITY review.
  Review must include actual cross-process ETS owner survival, both native
  acquisition-recording races, the timeout limitation, final COMMIT/authorization
  ordering, source binding, atomic startup through actual registration/return,
  inverse-baseline mutations and live/foreign sentinel survival. A fake-handle
  or recording startup port pass is insufficient.
- [ ] Keep BOTH strict late-unreturned-lease and companion-hard-death cleanup
  unchecked unless the parent has evidence for an authorized complete solution.
  These blocked guarantees prevent
  complete Task 16 acceptance; this does not erase passing supported checks or stop
  unrelated valid Phase 5 work. Do not begin Task 17 on a falsely complete Task 16.
- [ ] Only after the parent qualifies all applicable assertions, stage explicit
  reviewed files and make the authorized local commit:
  `feat(export): deliver verified artifacts through authenticated runtime api`.
  The architecture author does not commit. Parent records the exact tested source
  and updates master/report. Publication and E2E remain excluded.

## Document self-review and evidence boundary

This plan maps facade shape to Steps 2/6/7, root ownership to Step 1, native lease
trace/races/limitation to Step 3, ETS and requester handoff to Step 4, source
materialization/COMMIT/delivery to Step 5, and whole owners/review to Step 8.
The startup P2 amendment is Step6's actual guarded native start plus Step7's
one exact startup inverse. Task8 attribution P2 design repair1 adds Step7a's
separate prerequisite before Step7b: two exact accepted-composition inverses,
stage-aware old mutation inputs, and complete original digest recovery. It
preserves seven Task16 additions, every old tuple/digest/assertion, Task8 source,
all previous receipts and the historical reviewer FAIL.
Actual independent repair1 DESIGN SPEC then FAILED the positive-witness P2:
its direct inverse input bypassed the changed outer helper. Design repair2
adds the exact raw tuple checks → strict Task16-only stage → Task8 inverse
positive witness above, preserving both fixed assertions and every causal
Task8/earlier-phase negative route. All seven additions and all P5-A5/Task8
literals, hashes and source bytes remain unchanged. Actual corrected DESIGN SPEC
and a NEW distinct fresh DESIGN QUALITY are CLOSED PASS without actionable P1/P2
on reviewed design `58a9cc42b98d59c648d2168c8a048855c8120ca720ef359efffa5207be63fce0`
and plan `80fdebe81db0b35acc51390a524e9122257e8704bc591fad77e96734c8f56081`.
Exact copies are archived as
`.devenv/phase5-task16-attribution-design-repair2-reviewed-{design,plan}.md`;
parent records are `...-spec.md` and `...-fresh-quality.md`. These later status
metadata changes are not retroactive review; the archived repair1 FAIL and all
earlier reviewed receipts remain evidence.
It does not close either native lease identifier-loss boundary. All source/test
execution remains parent-gated; runtime characterization and E2E are NOT RUN.
All acceptance checkboxes deliberately remain open: documentation is not runtime
proof. Architecture consumes zero implementation-repair rounds. The parent owns
Sol counters and any later recovery gate; no repair budget is reset here.
This assignment's production Sol0/Astra recovery0 remains distinct from
Task8 attribution documentary repairs: repair1 failed SPEC; repair2's actual
corrected SPEC and NEW fresh QUALITY CLOSED PASS. Parent Task10 Sol1/Astra0 is
unchanged. Documentation author
CLOSED at handoff;
Task16 source/test authoring, SQL and maintenance remain CLOSED. Both strict
ALL-lease guarantees remain UNSATISFIED/UNWAIVED/BLOCKED_DESIGN pending genuine
boundary disposition. Documentary SPEC/QUALITY PASS is not native qualification
or implementation GO.
