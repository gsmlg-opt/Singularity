# Phase 5 Task16 Transfer Read Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development`
> or `executing-plans`. Parent allocates exclusive ownership and all native
> validation windows. This architecture author implements no source or tests.

**Goal:** Run Task16's genuine original-byte reads outside SQL without changing
the accepted old read primitives or losing immutable source/cleanup guarantees.

**Architecture:** Two additive ExportRead entrypoints acquire companion-owned
native export leases while exact source rows are locked. Existing
after_commit_scoped separates actual read from SQL, and explicit fresh authority,
source checks and private Asset audit commit before consumer delivery.

**Tech Stack:** Existing Elixir/OTP, Ecto/PostgreSQL, native export leases,
OperationScope, ExportRead descriptors and real Spool/Writer. No new dependency.

---

## Preconditions and exclusive file ownership

Read the complete [forward design](../specs/2026-10-19-singularity-v0.2-phase-5-export-transfer-read-design.md)
and its linked original Task16/zero-read/acyclic/recovery/terminal/native
contracts. This delta preserves every other requirement of their plans.
Worktree `.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`, inspected HEAD
`8fb1142ee593641544769658d03a96cb83ebaa56`. Preserve the parent's eighteen
dirty candidates. No simultaneous author and VM/SQL windows.

| Owner/window | Exact path and permitted change |
| --- | --- |
| Read test author, before production | `apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs`: additive transfer contracts only; exact inverse to old whole file |
| Native test author, separate window | `apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs`: additive native witnesses/outer lock observer; only two explicit exact-error corrections after required evidence |
| Composition test author, before production | `apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs`: additive fixed routing/order/ownership contracts and exact inverse counterproofs |
| One Sol implementation owner, after RED/reviews | `apps/singularity_runtime/lib/singularity/runtime/knowledge/export_read.ex`: strictly additive functions/helpers; `apps/singularity_runtime/lib/singularity/runtime/knowledge/export.ex`: exactly two literal calls |
| Parent | Review, actual execution, formatting only owned additions, new derived guards/receipts, governance pointer and eventual explicit scoped local commit |

Artifact, Repository, Snapshot, Download, OperationScope, ScopedRepo,
CustodyReader/Repository, native custody, Writer/Spool, configuration and all
other source are closed for this delta. A genuine incompatibility returns for
bounded design disposition. No old document, historical manifest or raw rewrite.

## Task A: retain causal RED and close design review

- [ ] Parent confirms current HEAD/status/diff, all pins from the design and
  closed author/runtime windows. Record new candidate manifest/guard names;
  never update native055's accepted input manifest to describe new bytes.
- [ ] Preserve native055 Runtime99/7fail, TestEnvironment3/0fail, warning102,
  natural exit2 and ownpost056 EMPTY/0. Its five transaction failures already
  provide causal production RED; do not repeat them merely to manufacture RED.
  Old isolated native81 does not qualify reads during SQL; retain both records.
- [ ] Independent nonauthor DESIGN SPEC, then NEW distinct DESIGN QUALITY on
  exact full design/plan bytes. Resolve findings without changing preserved
  ordinary/native contracts. Parent continuing authority supplies implementation
  authorization after review; no routine approval pause or architecture commit.
- [ ] Keep failed Sol production rounds0 and Astra implementation rounds0 as
  received. Parent records later repair rounds; documentary work resets none.

## Task B: additive behavior and ordering contracts before source

- [ ] Add separate new entrypoint tests for both kinds. Ordinary runtime with
  raw custodian/reader must return exact invalid before acquisition. Reject
  alternate wrapper, unequal contexts, extra keys, dead/nonlocal companion,
  invalid ref and a descriptor reduction from another process. Positive tests
  use actual Artifact owner/companion composition with synthetic authority
  explicitly labeled, never a fake companion claiming native ownership.
- [ ] Assert initial acquired lease remains tracked when its real COMMIT fails
  before after_commit_scoped runs: no native read, consumer or handle; actual
  revoke/termination, owner DOWN and operation removal. Use the existing real
  companion, genuine native fixture and delegating scoped fault injection.
- [ ] For Asset and Document empty/nonempty fixtures add exact events from
  delegating adapters around real scope/native calls, with owner PID/reference
  correlation. Preserve the existing composition read event unchanged:

```elixir
assert_receive {:composition, ^token, :forwarded_read, ^owner, ^kind, lease, false}, 5_000
```

  Require the real initial scoped transaction return/COMMIT event before that
  event, not merely a callback-return marker. Observe actual post-read scoped
  return/COMMIT before each consumer. RequestRepo must be outside SQL at both
  sites. Test-only consumer observer may record size, PID, ref and transaction
  boolean, never plaintext. A no-transaction boolean alone does not prove a
  preceding successful COMMIT; keep both witnesses.
- [ ] Add real before-acquisition barrier after source locks and before native
  material load. Concurrent runtime-role association/object/envelope/domain
  mutation must actually fail SQLSTATE55P03 with bounded LOCAL lock_timeout.
  Preserve old lock-through-read tests on old APIs unchanged. Add a distinct
  after-initial-COMMIT barrier; allow a genuine zero-to-nonempty association or
  metadata mutation to commit, then require native/post-read denial, no
  substituted nonempty `:all`, no consumer/handle and actual cleanup. Preserve
  old-version/retained-Document and ambiguous-envelope cases.
- [ ] Add post-read authority/source/audit/COMMIT failures. Require no consumer
  on each failure. Asset success persists actual `asset.downloaded` with exact
  private attributes; audit error and genuine deferred COMMIT rollback leave
  no persisted read audit. Cover empty authentication, corrupted final record,
  multi-range Asset, multi-native-chunk Document and per-piece authority change.
  Keep maximum64MiB Document, native4MiB and consumer65,536-byte assertions.
- [ ] Add exact first/pre/post COMMIT, failed revoke and early consumer failure
  cleanup witnesses. Every issued lease remains under existing companion/native
  ownership; retain late-unreturned and companion-pre-record death cases, real
  reader DOWN and native inactivity, unaffected ordinary and independent leases.
- [ ] Composition AST contracts require only literal new calls from
  `original_descriptor/4`, exact same fixed Leases tuples, no ordinary fallback,
  explicit Authorize in each runner guard, first/post COMMIT ordering, actual
  private audit and no consumer under SQL. Mutations remove/move each guard,
  substitute a dynamic mode/adapter, acquire after first COMMIT, use nonempty
  `:all`, restore either old call, add a third routing call, skip revoke or add a
  reverse Artifact→Read/Export dependency. Each mutation must find its target
  and reject for its intended reason.
- [ ] Parent executes complete new/retained owners with source frozen. Record
  actual new test counts; missing new API/expected source contracts are RED,
  compiler/helper failures are separate failures. Preserve false assertions.

## Task C: establish and author the two exact-error corrections

**Only file:** NativeLive from the ownership table. These changes do not repair
production errors. Keep them separately attributable from new transfer tests.

- [ ] Add this test-only observer in the existing Task16 composition-adapter
  area, preserving all old adapter bodies:

```elixir
defmodule CompositionCommitLockObserver do
  def with_shared(context, repo, owner, callback) do
    Singularity.Storage.VaultLock.with_shared(repo, owner, callback)
  rescue
    error ->
      send(context.parent,
        {:composition, context.token, :outer_commit_exception, self(),
         context.fail_commit, error.__struct__})

      reraise error, __STACKTRACE__
  end
end
```

  Only `remaining_commit_failure_case!/3` wraps `c.runtime.vault_lock` with this
  observer/context for its two fault points. Existing scoped adapter still
  observes/rethrows genuine Postgrex23503. This wrapper covers all VaultLock
  checkout/unlock unwinding; do not observe only AuthorizationLock. No logging
  of exception messages/struct contents, SQL or secrets.
- [ ] Run the whole NativeLive owner with old error expectations still present,
  adding an exact outer-module witness. Candidate expectation is
  `DBConnection.ConnectionError`, not yet runtime evidence. Preserve actual
  witness and result before correcting the contract. If different, return the
  correction for diagnosis; do not broaden to multiple errors or edit locks.
- [ ] After that evidence, replace only the expected selection/comment in
  `remaining_commit_failure_case!/3` with exact `:storage_unavailable` for both
  capture/prepared cases. Retain exact outer-module and inner
  `:foreign_key_violation, "23503", false` assertions, rollback, no COMMIT,
  no capture-failure read, no handle and native/filesystem cleanup.
- [ ] Separately change only the two post-owner/replacement-DOWN entries/chunk
  assertions in `remaining_accepted_companion_loss_case!/2` to exact `:invalid`.
  Preserve all in-flight `:storage_unavailable`, both DOWN witnesses, genuine
  native cleanup and independent/ordinary sentinel checks. Do not change a
  shared assertion helper or other error expectation. Archive the exact inverse
  for these replacements and observer installation/addition.

## Task D: additive Read implementation and two fixed callers

**Only production files:** Read and Export from the ownership table.

- [ ] Add one contiguous reviewed block inside ExportRead, before existing
  `defp text/4`, containing the two public internal entrypoints and new private
  transfer helpers. Fully qualify new module references if needed; do not edit
  old aliases, functions or AssetScope. Reuse existing validation/descriptor/
  consume/digest/revoke helpers without modifying them. Document validation
  repeats the old exact binding/size/version checks in the new entrypoint.
- [ ] Fix these signatures and pass boundaries; names of private helpers are
  implementation-local, not new public extension points:

```elixir
def asset_for_export(runtime, session, binding)
def document_for_export(runtime, session, captured)
```

  Validate session, caller outside SQL, captured binding and exact matching
  Leases wrapper/context before descriptor preflight. Capture `owner = self()`
  in the private pass closure and reject another caller on every invocation.
  The companion still validates actual owner/ref during acquisition; no shape
  predicate is represented as native authentication.
- [ ] Asset pass iterates the existing65,536-byte ranges, or one zero operation.
  For each read call real with_read_request using the fixed private requirement.
  In its callback: source lock/check → literal Leases acquisition of exact
  Download request → repeated source guard → after_commit_scoped. Within its
  after-COMMIT callback: assert outside SQL → genuine native read → run_scoped
  containing explicit Authorize, source guard and actual read audit → require
  real successful return and outside SQL → return validated bytes. Revoke in
  after; only then consume outside SQL. At pass end repeat source guard and
  retain descriptor's full size/digest validation.
- [ ] Use this exact Asset audit contract in the post-read transaction, with a
  generated UUID per range/empty operation and existing sink default:

```elixir
Singularity.Runtime.Audit.append_principal(audit, repo, session, %{
  action: "asset.downloaded",
  result: :completed,
  classification: :private,
  correlation_id: correlation_id,
  target_type: "asset",
  target_id: binding["asset_id"],
  metadata: %{}
})
```

  `audit` is `Map.get(runtime, :audit,
  Singularity.Storage.Postgres.AuditSink)`. Its failure aborts the scoped result;
  no recorded fake audit or weaker sink path qualifies.
- [ ] Document pass obtains one exact `document_source` binding and request
  lease while source locks are held, repeats equality and commits. Inside the
  after_commit_scoped callback, native ordinal reads remain outside SQL. Before
  each later native chunk, and after every read, runner performs explicit fresh
  Authorize then exact `document_source == acquired_binding`; require real
  COMMIT. Use existing split_document! with a guard closure that performs those
  fresh checks/COMMIT before each consumer piece. Empty uses genuine empty-
  original authentication and post-read guard; no emitted empty-body shortcut.
  Final same guard runs before pass success. Revoke in after with failure
  propagated. No extra Document audit is introduced.
- [ ] Do not catch first-COMMIT loss as success or retry with a new object.
  Outer safely sanitizes failure; existing Export/Artifact cancels the already
  owned operation. The companion retains unreturned-on-COMMIT lease ownership;
  any failure with a returned lease uses strict revoke. No lease enumeration,
  session-wide revoke, changed timeout, process dictionary or new cleanup task.
- [ ] Replace exactly these two Export calls:

```elixir
defp original_descriptor(runtime, session, %{"kind" => "asset"}, source),
  do: ExportRead.asset_for_export(runtime, session, source)

defp original_descriptor(runtime, session, %{"kind" => "document"} = version, source),
  do: ExportRead.document_for_export(runtime, session, %{version: version, source: source})
```

  No other Export change, including completion guards, source selection,
  materializer closure, error mapping, Handle or Writer behavior. Close author
  window before parent full-file inspection and focused GREEN.

## Task E: exact attribution without new baselines

- [ ] Record actual new block bytes, both unchanged context anchors and SHA256
  in a separately reviewed literal transition table. Invert Read's addition
  and recover exactly
  `9e7e20f235345627eee93a824b0b652a2b8cd582e657f9f92cc2a4716c00a091`.
  An unexpected formatter change to old Read bytes is a failure; preserve it
  for diagnosis, do not accept a new whole-file baseline.
- [ ] ReadTest additions similarly recover
  `c9d5064d1058c58bd21c9411816a09fef21b889636d34a191041e7c4cbf3eb3e`.
  Exact two-call Export inverse recovers
  `5d051af0bbd04a01710e1345223b86773142a2bf9184170eca12dbd9bf2146ad`.
  NativeLive forward additions/replacements recover
  `4b3e34f019a13f193edd8af4a1a936220a224d9cb90f9d5f5ce47aa856e2ccf0`
  before its existing three-block inverse recovers
  `61f48e40d82ed8af73d1b80bb57b11d81583d87ef5e6df72ef58b840abf2cf2e`.
- [ ] Require unique new blocks and two-sided contexts; fail on missing,
  altered, duplicate, relocated, old/new coexistence or unrelated old-byte
  mutations. Inverse expected data is a reviewed literal, never derived from
  whichever candidate currently exists. Preserve original81/prior11/new7
  native composition tests and all other assertions except Task C's named
  forward corrections. Check source stages before applying each inverse once.
- [ ] Preserve existing native56 (54 raw +2 qualified native inverses), all
  original1860/source baselines, Task8/native-text/Task16 layers and raw logs.
  Read is a separately protected accepted file, not a new frozen56 exception.
  Artifact remains pinned unchanged; Download remains
  `983813d9244620c030292fe47db20c234a75b3cc891807f799a6b4eedb58780e`
  and OperationScope remains
  `458c9fad4b48bed99e39e02611ab38f137a185d2db966bdf23f0bca158f0fde6`.
  Parent derives fresh guard/manifest names for this candidate only.

## Task F: root-controlled whole-owner qualification and review

All commands below are **planned, NOT RUN by the architecture author**. Root
uses the established private-PG wrapper/PTY lane, fresh mode0600 raw output,
natural completion and each invocation's immediate own ordinary post check.
No competing VM/service, default timeout increase, line filter, output filter,
seed change, hidden warnings or manual cleanup credited to production.

Whole-owner payload commands within that established environment:

```sh
mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs apps/singularity_runtime/test/singularity/runtime/asset_download_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs apps/singularity_runtime/test/singularity/runtime/export_lease_ownership_test.exs --seed 215378 --warnings-as-errors
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs apps/singularity_storage/test/singularity/storage/test_environment_test.exs --seed 215379 --warnings-as-errors
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/test_environment_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs --seed 215378 --warnings-as-errors
mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs --seed 215378 --warnings-as-errors
mix test apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/export_lease_ownership_contract_test.exs --seed 215378 --warnings-as-errors
mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/writer_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/spool_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/artifact_directory_test.exs --seed 215378 --warnings-as-errors
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs --seed 215378 --warnings-as-errors
mix format --check-formatted apps/singularity_runtime/lib/singularity/runtime/knowledge/export_read.ex apps/singularity_runtime/lib/singularity/runtime/knowledge/export.ex apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs
env MIX_ENV=dev mix compile --warnings-as-errors
env MIX_ENV=dev mix xref graph --format cycles --fail-above 0
git diff --check
```

Each native invocation's ordinary post payload remains:

```sh
psql --dbname=postgres --no-psqlrc --tuples-only --no-align --file=.devenv/phase5-task11-residual.sql
```

The Runtime-then-Storage integration command with seed215379 is the exact
native055 failing-command replay and is mandatory after the fix, with its own
fresh raw and ordinary post. The additional Storage-then-Runtime seed215378
command is retained as a separate gate, not a replacement for that replay.

- [ ] Parent archives exact argv, natural exit, executed/registered/excluded
  counts, warnings and complete safe raw hashes; ownpost must actually be
  EMPTY/0. Native055 failures and incomplete raw review stay historical facts.
  Never open the explicitly excluded Task11 static-native raw.
- [ ] Require actual zero failures and retained checks in every applicable
  owner. Distinguish pure synthetic scope from real PostgreSQL/lease proof;
  excluded integration cases remain NOT RUN. Original whole Task16 startup,
  cleanup/ALL-leases and exact-attribution requirements remain mandatory.
- [ ] Parent full-source self-review, then independent SOURCE SPEC followed by
  NEW distinct SOURCE QUALITY using exact source/test/raw pins. Review first-
  COMMIT lease escape, real native binding immutability, zero-only authentication,
  explicit post-read Authorize, audit/COMMIT ordering, guard-before-piece, all
  failures/cleanup and attribution. Design review is not source acceptance.
- [ ] Only after required gates/reviews, parent may make explicit scoped local
  commits and verify committed blobs match tested bytes. This author does not
  commit. Task16 completion requires all its obligations, and Phase5 requires
  the complete permitted README gate. E2E stays NOT RUN/manual-deferred. No
  merge, push, version/tag/release, deployment or production-data operations.

## Self-review and handoff

Task A preserves evidence/authority; B defines strict test-first transfer proofs;
C separates two exact contract corrections from production fixes; D implements
the fixed additive transfer path; E preserves old source/tests byte-for-byte
through exact inverses; F retains all whole-owner and independent review gates.
No runtime or phase acceptance is claimed. Source, VM, SQL and test execution
remain parent-owned. Architecture author closes after scoped document checks
and hashes; Sol0/Astra implementation0 are unchanged.

## Task E follow-up: retained lease contract compatibility

The gate103 failure is retained as FAIL (404 tests, one failure); own104 was
EMPTY/0. Under the design's matching compatibility amendment:

1. Obtain independent design SPEC and then distinct QUALITY review before
   implementation. Change only the retained
   `apps/singularity_web/test/singularity/architecture/export_lease_ownership_contract_test.exs`
   with three marked additive sections. Preserve its complete old contents,
   literal56 and native transition table; exact deletion of the additions must
   recover whole SHA256
   `7615cb292537aae9f7fc17c42d210aee814104d72af8a1d3c3dce0f4b432f2a7`.
2. Add reviewed literal Read addition, unchanged anchors and all hashes named
   in the design. Add raw-source positive controls and boundary-specific
   negative cases for absent/changed/duplicate/relocated blocks and contexts,
   old/new coexistence and unrelated old/new outside bytes. Reject an old raw
   source too; no fallback or self-derived expected transition.
3. Add a Read-only `read_source/1` clause immediately before the old generic
   clause. Strict inverse checks unique block/context and coexistence before
   requiring candidate whole `5377afeb0858e1d3bcd40c939a263b517ecb4454e9a7ff2f09ed46b3ede59ebb`
   and recovered old `9e7e20f235345627eee93a824b0b652a2b8cd582e657f9f92cc2a4716c00a091`.
   Keep the existing caller assertion and hashes byte-identical. Other source
   reads remain raw. New mutation tests bypass this clause for raw evidence.
4. Parent records actual formatter effects and exact additive inverse,
   derives fresh candidate manifest/guard names without rewriting historical
   manifests, and replays Task F's complete four-owner architecture command
   with its own ordinary EMPTY/0 post. Preserve every remaining required gate.
5. Independently review implemented SOURCE SPEC, then fresh distinct SOURCE
   QUALITY on exact source and raw pins. No production repair, native-table
   change, new Vault exception, publication or phase acceptance is implied.
