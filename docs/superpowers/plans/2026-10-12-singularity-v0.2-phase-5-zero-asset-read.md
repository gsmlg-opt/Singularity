# Task 14 Zero-Byte Asset Read Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Parent alone formats/runs gates; never overlap source authoring with Mix or SQL.

**Goal:** Retain authenticated empty Asset originals without any nonempty eager read or frozen custody change.

**Architecture:** The new knowledge caller composes a fixed internal OperationScope wrapper with the unchanged Asset download callback. Real Asset/object/envelope/domain-version row locks protect the independently verified zero layout through custody, authentication, audit and COMMIT.

**Tech Stack:** Elixir/OTP, ExUnit, Ecto/PostgreSQL17 owner RLS, existing request custody and local encrypted storage.

Design: `docs/superpowers/specs/2026-10-12-singularity-v0.2-phase-5-zero-asset-read-design.md`.
This plan amends only master Task14's zero-Asset prohibition; all other Task14
source, digest, preflight, completion and cleanup requirements remain mandatory.

Current source evidence: completion-order repair1 and the separate test-warning
helper repair now pass whole pure3 54actual/0fail/23SQLexcluded and live3
89actual/0fail/13pureexcluded. Original38 pure and66new+23old live cases remain;
16 additive native capture completion cases pass. Initial RED and intermediate
warnings-as-errors FAIL remain in the acceptance history. Final actual
NONAUTHOR SOURCE SPEC and distinct fresh QUALITY both CLOSED PASS, allfive
owning source/test hashes independently match. Parent final verification and
the scoped localcommit remain pending; Phase5 acceptance is still unqualified.

## A. Actual design review and prerequisite

- [x] Actual nonauthor SOURCE SPEC reviews full design/plan against original
  Assets.Download, OperationScope/ScopedRepo, actual AssetRepository selection,
  CustodyRepository material reload, released privileges, AuthenticatedReader,
  local complete-ciphertext verification and Format constants.
- [x] A distinct fresh actual-source QUALITY reviewer checks the late association/
  material-load races and genuine test observability. Record reviewed hashes,
  all findings and actual disposition; do not substitute an author's own review.
- [x] Synchronize the master's sole zero-only exception after both reviews.
  Before Task14 authoring, Task13 must have complete required GREEN plus actual
  SOURCE SPEC/fresh QUALITY and a small local commit. No dependency bypass.
  Qualified Task13 local commit:09f8ee0c0a69cdd26612e0663a29a9d156c46986.
  This records Task14's historical prerequisite, not its current implementation
  state. No source authoring during any live parent gate.

## B. RED source composition and owning live cases

**Create:** `apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs`.
**Create:** `apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs`.
**Create production only after RED:** `apps/singularity_runtime/lib/singularity/runtime/knowledge/export_read.ex`.
**Modify after RED:** `apps/singularity_storage/lib/singularity/storage/knowledge_export/repository.ex` for exact source methods.
**Preserve:** every frozen DownloadLease/KeyCustodian/crypto/Vault file and released migration.

- [ ] Characterize unchanged zero layout using a genuine existing format1
  encrypted empty object. Prepare actual normal object/envelope/wrapper metadata
  and real session authorization/custody in the NEW owning live test only.
  Do not use Task13's metadata-only prepared_source fixture as byte proof.
- [ ] Add the real zero composition regression around the ORIGINAL download:

```elixir
zero_runtime =
  Map.put(runtime, :operation_scope, {
    Singularity.Runtime.Knowledge.ExportRead.AssetScope,
    %{binding: captured_binding, mode: :zero}
  })

assert {:ok, ""} =
         Singularity.Runtime.Assets.Download.run(
           zero_runtime,
           session,
           captured_binding["asset_id"],
           :all
         )
```

  Assert actual RequestRepo caller/backend/transaction/GUC identity, real
  authorization and material load, complete ciphertext verification, final AEAD,
  exact empty SHA256, original read audit persisted after genuine COMMIT, and
  actual header/final-only storage reads. This is the fixed internal composition's
  live oracle, not completed portable-export acceptance.
- [ ] Unit tests of public internal ExportRead.asset/3 must assert that only its
  fixed zero guard can select `:all`, Range length <=65536 for every nonempty
  read/preflight/retry, exact captured association/classification/generations,
  no request-selected adapter/owner, no nested caller transaction and completion
  revalidation. Fake return values qualify wiring only.
- [ ] Add committed-before-guard association/size/hash/layout mutations and
  genuine late two-connection races. Barrier at original AssetRepository
  selection entry delegates that actual method unchanged after release: all
  binding locks/checks have run, but its actual selection has not. A second
  runtime-role transaction sets bounded LOCAL lock_timeout and attempts an
  association replacement to a genuine nonempty object:

```sql
SET LOCAL lock_timeout = '250ms';
UPDATE content.assets SET asset_object_id = $1 WHERE id = $2;
```

  Require the actual exception SQLSTATE55P03/lock_not_available, original
  association unchanged, no nonempty eager storage read, and the real zero
  callback outcome. Do not manufacture the exception or use sleeps.
- [ ] Add a material-load/read barrier which delegates the actual custody/
  repository query unchanged, then exercise object size/identity and selected
  envelope/domain-version mutations with genuine runtime-role UPDATE/55P03.
  A second eligible envelope must trigger the frozen real two-candidate denial
  before lease. After operation closure, prove writer progress and GUC/lock
  cleanup. Retain corrupted final record, revocation/unlock, audit/read/COMMIT
  failures and original nonempty Range regression.
- [ ] Parent freezes source and runs both COMPLETE commands in section D.
  Archive missing-method/race failures as causal RED. No line/test narrowing,
  trace-only substitute, weakened assertions or default timeout increases.

## C. Minimal fixed caller implementation

- [ ] Add `Repository.lock_asset_source(repo,binding,mode)` inside the NEW export
  Repository. Require an actual live authorized scoped transaction; derive owner
  from that context and match the captured binding, never grant authority from it.
  Lock Asset first, object second, then actual selected envelope/domain-version
  rows. Use real FOR SHARE with exact owner/classification/identity predicates.
  Recheck exact version/resource/Asset association, eligible states, lookup and
  ciphertext hashes, literal stored ref, sizes, format and actual generations.
  Reject absent/ambiguous/changed rows before callback; no wrapped key selection,
  extra grant or migration. Zero requires actual AND captured size0/format1/
  ciphertext134; positive Range is <=65536 and within actual captured size.
- [ ] Implement the fixed scope wrapper in the NEW ExportRead file:

```elixir
defmodule AssetScope do
  alias Singularity.Runtime.OperationScope
  alias Singularity.Storage.KnowledgeExport.Repository

  def with_read_request(
        %{binding: binding, mode: mode},
        runtime,
        session,
        requirement,
        callback
      ) do
    OperationScope.with_read_request(runtime, session, requirement, fn repo ->
      with :ok <- Repository.lock_asset_source(repo, binding, mode) do
        callback.(repo)
      end
    end)
  end
end
```

  Construct this tuple only within ExportRead's private invocation of unchanged
  Assets.Download. Do not replace original AssetRepository/Authorize/audit/
  custodian/reader results. Every discovery/reauthorization scope repeats locks.
  Keep locks until real callback/audit/COMMIT closure; do not open an outer
  request transaction or use old RR capture as current-size proof.
- [ ] Zero delivery requires the genuine authenticated `{:ok, ""}` result and
  derives empty SHA256 from those actual bytes. Nonempty sources remain bounded
  Range only; keep complete captured ciphertext verification and actual AEAD
  record alignment. Export/writer chunks are <=64KiB, but existing crypto may
  authenticate one bounded4MiB record internally. Do not change Format/lease.
- [ ] Complete all unchanged master Task14 requirements for exact historical
  Documents, retained originals after source Asset deletion, Note/fragment
  revalidation, original digest preflight/completion, revocation and lease
  cleanup. No head-following substitution or fake-source proof.
- [ ] Close author commands; parent reads full source, formats, records an
  immutable complete source receipt and freezes ALL source/test/support.

## D. Complete validation and handoff

- [x] Whole pure owner files must pass, zero warnings; record actual executed
  counts/exclusions and normal exit0, not a predicted count:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs --seed 215378 --warnings-as-errors
```

- [x] Whole live owning file set must pass on the existing private PostgreSQL,
  genuine source/custody races and real clean closure included:

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs --seed 215378 --warnings-as-errors
```

- [x] Since Task14 adds Repository methods, retain the COMPLETE two-file Task13
  SQL gate and whole five-file pure command from its accepted plan; preserve all
  provenance/seal/page/source-set/cut/audit/COMMIT assertions.
- [x] Compile with warnings-as-errors, changed-file format check, seven-app/
  zero-xref-cycle check; verify frozen56 and exact source receipts. Archive full
  gate output/normal exit/actual counts and private DB/root/lease/GUC/lock cleanup.
- [ ] Ordinary failure remains FAIL and enters bounded diagnosis/repair; escalate
  after two failed Sol repair rounds on the same defect or evidenced technical
  impasse. No skipped gate, assertion weakening, fake blocked-writer proof or
  frozen substrate change.
- [ ] Obtain actual final nonauthor SOURCE SPEC then distinct fresh QUALITY.
  Record source hashes, commands/results and no Vault feature work. Only then
  small local commit `feat(export): read captured sources with existing request custody`
  and automatic next valid task; Phase5 is not yet accepted.

E2E NOT RUN/manual-only. No merge/push/version/tag/release/deploy/activation/
backfill/production-data action. All other required gates remain mandatory.
