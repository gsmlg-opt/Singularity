# Phase 5 Task16: committed native transfer reads

## Status and authority

Architecture candidate for `task16_transfer_read_architecture`, mode
`architecture`, `astra_gate=PROJECT_ARCHITECTURE`. The gate concerns a genuine
transaction/lifecycle boundary conflict evidenced by native055; it does not
authorize this author to implement repairs. Continuing local-development
authority permits this forward design and its [detailed plan](../plans/2026-10-19-singularity-v0.2-phase-5-export-transfer-read.md).
Independent DESIGN SPEC then NEW distinct DESIGN QUALITY must close on exact
document bytes before the parent grants affected implementation GO.

Inspected worktree: `.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`, HEAD
`8fb1142ee593641544769658d03a96cb83ebaa56`. Eighteen existing dirty candidates
belong to the parent and other workers. This author changes only this new
design and its new plan; source, tests, governance, old documents and evidence
remain read-only. Received failed Sol production-repair counter: 0; cumulative
Astra implementation repairs: 0. Architecture consumes and resets neither.

Read with the unchanged [original Task16 design](2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership-design.md)
and [plan](../plans/2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership.md),
[zero-Asset design](2026-10-12-singularity-v0.2-phase-5-zero-asset-read-design.md)
and [plan](../plans/2026-10-12-singularity-v0.2-phase-5-zero-asset-read.md),
[acyclic composition](2026-10-19-singularity-v0.2-phase-5-export-acyclic-composition-design.md),
[companion recovery](2026-10-19-singularity-v0.2-phase-5-export-companion-recovery-design.md)
and [terminal close](2026-10-19-singularity-v0.2-phase-5-export-terminal-close-design.md)
amendments and their corresponding plans. Native export leases are independently
qualified at `6c7f867309470e23e8f34c06a8f53af0b496d48d`; see their
[handoff](../../verification/2026-10-19-phase-5-export-lease-ownership-handoff.md).
Neither that prerequisite nor this design accepts Task16 or Phase5.

## Evidence and exact forward change

Parent's native055 executed 99 Runtime cases with seven failures; Storage
TestEnvironment executed three actual integration cases with zero failures
(20 registered, 17 excluded). Raw
`.devenv/phase5-task16-resumed-native055-native-composition99-harness20-impl1.log`
has SHA256 `355e0b00d429f75654ea84d619fbdbcb62d3225669b79217714d7ec363941d63`.
Its own ordinary post056 naturally exited 0 with an EMPTY body. These are
parent-reported results corroborated by the read-only disposition JSON, not
tests rerun by this author. The disposition records full-raw review as false,
failure/warning/summary inventories reviewed, and 102 migration-module
redefinition warnings; do not suppress or silently reclassify those warnings.

Five failures observe `RequestRepo.in_transaction?() == true` during actual
Asset/Document native reads, where the retained assertion requires false.
The source explains this: `ExportRead.asset_pass/5` calls `asset_read!/4`, then
unchanged `Download.run`, `AssetScope`, `OperationScope` and `ScopedRepo`;
`Download.read_object/6` leases, reads and audits before its SQL callback returns.
`ExportRead.document_pass/5` similarly invokes its native reader within
`scoped_result/4`. The old isolated native81 success did not measure this new
transfer boundary. Some retained old tests deliberately require callback,
native read, audit and COMMIT in one transaction; those tests remain correct.

This amendment supersedes only Task16's choice of `ExportRead.asset/3` and
`document/3` at `Export.original_descriptor/4`, and its prohibition on adding
functions to that file. It adds fixed Task16-only internal entrypoints
`asset_for_export/3` and `document_for_export/3`. The old functions, AssetScope,
helpers, semantics and tests remain byte-identical. The old zero-only
lock-through-read contract remains applicable to the old entrypoint. For the
new entrypoint, locks cover acquisition of immutable native custody, followed
by real COMMIT, native read outside SQL, and fresh checks before byte delivery.
The new path is a separate authored contract, never a reinterpretation of an
old failed assertion as success.

Two other failures concern exact error assumptions; their distinct test-only
forward corrections are conditional on evidence in the section below. They do
not justify changing production errors, locks, Snapshot or native behavior.

## Alternatives and boundaries

1. **Selected: additive transfer entrypoints using existing scope and lease
   interfaces.** Reuse the descriptor/preflight/reduction contract, source guards,
   native immutable custody and companion cleanup. This duplicates a small
   amount of private orchestration but preserves accepted old behavior exactly.
2. Change ordinary Download, AssetScope or existing ExportRead functions to
   move all reads outside SQL. Rejected: changes established ordinary/isolated
   behavior and contradicts retained lock/read/audit tests.
3. Precheck, commit, then acquire a lease. Rejected: the zero-layout proof can
   change before the native custodian loads material, allowing a nonempty `:all`.
   A later size assertion cannot undo that read.

No new production module, process, public Runtime.Api operation, runtime/configuration mode,
adapter registry, process-dictionary authority, dependency, migration, grant or
capability. No key, crypto, TTL, native ownership or other frozen Vault change.
Ordinary Download, OperationScope, ScopedRepo, CustodyReader, CustodyRepository,
KeyCustodian and DownloadLease stay byte-identical to the current qualified
baseline. The existing source repository already supplies the required locks;
no Repository change is identified or authorized by this amendment.

## Fixed internal interface and cleanup ownership

Both new functions have the same three arguments, validations and descriptor
shape as their old counterparts: trusted operation runtime, authenticated
SessionContext and sealed captured binding. Asset descriptor preflight computes
the digest; Document verifies its captured original digest. Every reduce reruns
the authenticated pass and checks the preflight digest/size using unchanged
`descriptor/3`, `finish!/4` and bounded consumption helpers.

Before any scope, acquisition or native read, require both runtime adapters to
be exactly the same `{Singularity.Runtime.Knowledge.ExportArtifact.Leases,
context}` tuple. Context is an ordinary map with exactly `companion`,
`operation_ref`, `reader`; companion is a live local PID other than self,
operation_ref is a reference, and reader is the existing trusted native reader
adapter shape. Reject plain KeyCustodian, ordinary DownloadLease, mismatched
contexts, missing/extra fields and alternate wrapper modules. No fallback.
Capture the invoking owner PID lexically when constructing the pass and reject
descriptor reduction in another process before side effects. Recheck the fixed
context and owner on every pass, not just descriptor construction.

The shape check is not authentication and does not turn a map into authority.
Actual acquisition uses the literal Leases wrapper, whose existing companion
matches its stored operation reference, owner PID and generating phase before
calling `KeyCustodian.export_lease/2`. Only the owner with the established
private operation context can receive an admitted lease. The existing companion
records each returned lease and monitor before forwarding. Native export
ownership covers late/unreturned issuance and companion death before recording.
The reader/custodian in the authorization dependency bundle remain unchanged.
Trusted native test observers may exist behind the wrapper's reader, as today;
they are not public caller-selected adapters or substitutes for native proof.
This is the existing trusted-BEAM composition boundary, not protection against
hostile internal adapters forging protocol messages. Leases.lease retains its
existing receive semantics with no new local timeout; original companion
termination, operation deadline and native acquisition budget govern it. Add no
clock/context field, third task or native API to manufacture an identity check.

This fixed dependency is Read → Artifact.Leases; Export already depends on
both. Artifact must never reference Read or Export. There is no callback
registry, reverse dispatch or additional operation task. The only production
Export changes are its two literal calls in `original_descriptor/4`.

## Acquisition, COMMIT and read protocol

Use unchanged `OperationScope.with_read_request/4` and its
`{:after_commit_scoped, callback}` return protocol. Bind the existing private
`asset.read`, unlocked, owner and both-epoch requirement from the SessionContext.
Reject an already-open caller transaction through existing validation. The
outer scope performs its ordinary live authorization. Shared authorization locks
and checkout may span native work, but no SQL transaction may do so; this does
not add a Vault lock or change existing lock order.

| Stage | Asset | Document |
| --- | --- | --- |
| Initial scoped transaction | Existing `lock_asset_source(repo,binding,mode)`; exact download request; acquire through fixed Leases; repeat same guard | Existing `document_source(repo,captured)`; verify returned exact binding; acquire request-Document lease; repeat guard and equality |
| First actual COMMIT | Releases source row locks; only success invokes after_commit_scoped | Same; lease remains companion-owned even if COMMIT fails |
| Before native read | Assert caller outside SQL; initial guard/COMMIT covers first Asset range | First acquisition guard covers first chunk; subsequent chunks get fresh explicit authorization/source guard in run_scoped and actual COMMIT |
| Native read | One-use `read(lease, range)` or authenticated zero-only `:all` | Existing ordinal `read_document_chunk` or `authenticate_empty_document_original` |
| Post-read scoped transaction | Explicit fresh Authorize, exact source guard, real private read audit | Explicit fresh Authorize and exact Document/source equality |
| After post-read actual COMMIT | Validate byte count, then release bounded bytes to consumer outside SQL | Validate native chunk count; each emitted 64KiB piece also has a fresh explicit authorization/source guard and actual COMMIT before consumer |
| Pass end | Exact source guard after all pieces; digest/size check | Exact source guard, digest/size check and genuine lease revoke |

`run_scoped` only applies scoped transaction context; it does **not** call
Authorize. Every post-acquisition runner callback must explicitly call genuine
`Singularity.Runtime.Authorize.check(runtime.authorization, repo, session,
requirement)` before the source guard and any audit. Do not infer fresh authority
from held advisory locks, the previous authorization, DTO unlock state or lease
possession. Return only allowed `:ok`/`{:ok, value}`/`{:error, %Error{}}` shapes
from runner callbacks. Require the returned success and outside-transaction
state after actual runner return before consuming bytes. Never execute the
consumer in a transaction or recursively start a new OperationScope inside a
runner callback.

Asset acquisition request exactly matches existing Download request fields:
`job_id` = captured Asset ID, `purpose: :download`, session/principal/owner and
both epochs, `required_capability: "asset.read"`, captured object ID/generation.
Document request retains `purpose: :document_source`, `access: :request`, exact
historical Document version and object/generation, and the same authenticated
identity/epochs/capability. No supplied ownership, ticket, mode or deadline.

Every acquired returned lease gets explicit revoke in an `after` around its
after-COMMIT read work, using the existing strict `revoke/2` helper. An Asset's
one-use native termination is acceptable only when actually confirmed; a live
failed/unknown revoke is not success. The initial COMMIT can fail before the
after-COMMIT closure starts, leaving its lexical lease inaccessible to the
caller. This is why fixed companion ownership is mandatory: the companion
already recorded it, and Export's failed work causes the existing cancellation
path to revoke all recorded leases and remove the operation. Native ownership
covers the earlier unknown-identifier window. No standalone ordinary lease
may enter this path, and no failure may return a successful handle.

## Why the zero-only proof survives released row locks

`Repository.export_original!/4` locks Asset → object → actual selected envelope
and domain version, checks the exact original association, live/retained rules,
generation, sizes, storage reference, lookup and ciphertext hashes and rejects
ambiguous candidates. For Asset zero mode require independently loaded and
captured size 0, format 1, ciphertext size 134. All these locks remain held
through the real custodian material load and successful lease return, then the
same guard runs again before COMMIT. Document's existing guard preserves its
retained-original allowance and exact historical Document pin; do not replace
it with Asset-only liveness rules or follow a current head.

The immutable bridge is native source behavior, not assumed database metadata
immutability. `CustodyReader.load_object_key/3` returns a reader binding copied
into the new lease's private context. It includes object/generation, owner,
domain/classification, lookup digest, ciphertext hash, sizes and format.
`CustodyReader.read_range/3` and document reads use that captured context, and
`CustodyRepository.revalidate_reader/3` compares freshly loaded material to it.
A later association/metadata change can deny revalidation; it cannot silently
retarget the lease's reader to a different nonempty object. File replacement
still faces the captured ciphertext hash and genuine AEAD authentication.
The new path must not reload a different object and retry on conflict.

Only an acquired lease proven empty while those rows were locked may receive
`:all`; its actual result must be `{:ok, ""}`. Require real header/final AEAD
and ciphertext verification; a zero-length shortcut is forbidden. Nonempty
Assets always use positive ranges of at most 65,536 bytes, in preflight and
reduction. Documents retain maximum 67,108,864 bytes, existing 4,194,304-byte
native records/chunks and at most 65,536-byte consumer pieces. Never use
nonempty `:all`, eager whole originals, futures, plaintext caches or fake readers.

The new race test differs intentionally from the old primitive's lock-through-
read test: mutations while acquisition is held must still encounter real
55P03; after initial COMMIT they may proceed. A changed pin must cause native
or post-read denial with no substituted bytes/handle. Old tests continue to
exercise old entrypoints unchanged. At completion Export repeats its existing
exact original/text guards and final native authorization/COMMIT handshake.

## Audit and failure semantics

Every successful native Asset range/empty read gets the same private audit as
Download, in the post-read scoped transaction, after fresh authorization and
source guard: `Audit.append_principal/4`, trusted configured sink or existing
AuditSink default, action `"asset.downloaded"`, result `:completed`,
classification `:private`, generated correlation UUID, target type `"asset"`,
captured Asset ID, metadata `%{}`. No sensitive audit branch is added because
this interface accepts private sources only. Preserve existing audit-per-read
preflight/reduction behavior, not merely one synthetic export audit. Document
has no such existing Asset download audit; do not invent one.

Initial/pre-read/post-read COMMIT failure, fresh authorization/source rejection,
native authentication failure, audit failure, consumer failure and unconfirmed
revoke all fail the operation, cancel owned artifact state and publish no
handle. In particular no consumer call occurs on post-read audit/COMMIT failure.
Already written private pieces may exist temporarily; they never become a
successful export and are removed through existing owned cleanup. Preserve
sanitized Error codes/privacy, exact owner-DOWN-before-deletion, terminal-close
acknowledgement, replacement recovery, startup serialization, original deadlines,
native reader cleanup and all independent/ordinary lease isolation assertions.
No arbitrary raw exception, content, storage path or key enters telemetry/errors.

## Two separate exact-error contract corrections

**Capture/final COMMIT fixture:** native055 proves genuine Postgrex
`:foreign_key_violation`, `"23503"` inside the delegating scoped adapter, followed
by public `storage_unavailable`; it does not yet prove which exception reaches
Snapshot after lock unwinding. Source indicates AuthorizationLock and then
VaultLock `after` unlock queries on the disconnected connection may replace the
original exception. The old native test at lines 899–910 already expects exact
`storage_unavailable` for real deferred COMMIT failure.

Add a test-only `CompositionCommitLockObserver.with_shared/4` that delegates the
**entire** `Singularity.Storage.VaultLock.with_shared(repo, owner, callback)`.
Rescue outside that call, report only fixed tag, fixture token, observer PID,
fault point and `error.__struct__`, then `reraise error, __STACKTRACE__` unchanged.
Install that fixed observer only in the two `remaining_commit_failure_case!`
runtime fixtures. An AuthorizationLock-only observer is too early: VaultLock
can replace its exception again. The proposed exact final module
`DBConnection.ConnectionError` is source-supported by dependency holder cleanup
but remains a hypothesis until this witness executes. No exception text, SQL
values, connection credentials or user contents are reported.

First execute the observer while preserving the old expectations. Only after
the actual outer exception witness establishes the cause may the parent author
the forward contract selecting exact `storage_unavailable` for these two real
COMMIT cases (the prepared case already selects it). Require the exact observed
exception module, preserved real 23503, rollback, no successful COMMIT/handle,
no capture-failure reads and complete cleanup. If the proposed module is not
observed, stop that correction and report evidence; do not allow several codes
or change production locks/Snapshot to obtain a desired error.

**Initially dead owner:** after actual owner and replacement DOWN, existing
`ExportArtifact.route/5` deliberately returns exact `invalid` for entries/chunk;
only close uses the fresh authorized no-op. The original requirement is denied
delivery, not `storage_unavailable` in that already-dead branch. Author the
forward assertion as exact `invalid` for those two calls in the accepted-
companion-loss case, after its existing DOWN/cleanup witnesses. Preserve exact
`storage_unavailable` for in-flight loss, native cleanup, independent export,
ordinary leases and all other assertions. Record native055's old failure as
historical FAIL; neither correction is a production repair or generic weakening.

## Attribution, validation and acceptance boundary

The plan names the five future source/test files and parent-owned gates. Read
and ReadTest are protected accepted whole-file baselines even though Read is
not an original frozen56 entry. Require exact literal additive block/context
receipts whose inverse recovers Read
`9e7e20f235345627eee93a824b0b652a2b8cd582e657f9f92cc2a4716c00a091`
and ReadTest
`c9d5064d1058c58bd21c9411816a09fef21b889636d34a191041e7c4cbf3eb3e`.
Invert only the two Export calls to recover
`5d051af0bbd04a01710e1345223b86773142a2bf9184170eca12dbd9bf2146ad`.
Current Artifact stays
`a51aae83bd667e366e2bcb22cee52a0b7674be591387b8ab345f3e94557f04a4`;
that is a candidate pin, not terminal/native qualification.

NativeLive candidate before this amendment is
`4b3e34f019a13f193edd8af4a1a936220a224d9cb90f9d5f5ce47aa856e2ccf0`.
New additions and the two precisely scoped error-contract changes must invert
to it, then the existing three-block inverse recovers old92
`61f48e40d82ed8af73d1b80bb57b11d81583d87ef5e6df72ef58b840abf2cf2e`.
Keep original81, prior11 and new7 composition cases, all false-transaction
predicates and historical raw/manifests. No whole-module whitelist or optional
normalization. Mutation counterproofs must reject altered old helpers, missing,
duplicate, relocated or changed additions and any third Export call change.

Native proof requires actual initial and post-read COMMIT barriers and
`in_transaction? == false` at the real native call and consumer, real encrypted
empty/nonempty Assets and Documents, before-acquisition lock races, after-COMMIT
substitution denial, fresh authority/expiry checks, real audit persistence and
rollback, and all original native death/timeout/cleanup tests. Run complete
owners, not line filters; keep warnings, exclusions and causal counts explicit.
Unfiltered xref must have zero cycles and seven applications remain unchanged.

This design author performed source/document/hash inspection only. Mix, VM,
SQL, formatter, services, network, implementation tests and native gates were
NOT RUN. E2E remains NOT RUN/manual-deferred. No commit, merge, push, release,
deployment, activation, production-data operation or Vault feature work.
Independent design reviews and implementation acceptance remain pending.

## Task E compatibility amendment: retained lease-ownership contract

Gate103 actually failed with 404 tests and one failure: the retained
`export_lease_ownership_contract_test.exs` still checks the entire old Read
hash, although this design permits only its exact additive transfer block.
Own104 was EMPTY/0. This is a test-contract compatibility repair, not a new
production repair or a frozen56 exception; the failed receipt stays FAIL.

Preserve every existing byte of that contract, including `@unchanged_callers`,
its original assertion, the literal56 manifest, the two native transitions,
their helpers and all mutation assertions. Add three marked sections only:
literal Read transition data, raw-source positive/negative contracts, and an
exact-path `read_source/1` clause plus strict inverse helper. Place the clause
immediately before the unchanged generic clause. Only this Read path is
normalized; other paths still return raw bytes. Removing these three additions
must recover the original contract SHA256
`7615cb292537aae9f7fc17c42d210aee814104d72af8a1d3c3dce0f4b432f2a7`.

The Read candidate remains
`5377afeb0858e1d3bcd40c939a263b517ecb4454e9a7ff2f09ed46b3ede59ebb`.
Its literal 12264-byte addition has SHA256
`4d0da4e78d2dceef190f7fd8e55baec1a7f0a2fe739ec642cd913b6c938c5cdb`;
173-byte left and 65-byte right anchors have hashes
`5840c6cd9d15fcdd704a3e67786a277df54867e72d3ef9eae1357de8030b9435` and
`9e2c742b5c01f493b492a73a5ea095823444c853629ce26f2832d64594ff679a`.
Require exactly one literal block and two-sided context, reject old/new
coexistence, then check both the candidate whole hash and recovered original
`9e7e20f235345627eee93a824b0b652a2b8cd582e657f9f92cc2a4716c00a091`.
No absent-block fallback is allowed. New tests read raw bytes directly and
prove missing, changed, duplicate, relocated, context-damaged, coexistence and
unrelated-byte mutants fail at the intended inverse boundary, each after a
passing positive control. Do not replace the old hash or accept a module-wide
whitelist. Keep historical manifests immutable; derive a new candidate guard
with exact inverses for this contract and these documentation additions.

Independent design SPEC then distinct QUALITY precede implementation. Replay
the complete four-owner architecture gate, run actual formatting and retain
all other Task F obligations. This amendment does not change production,
native transitions, Vault authority, E2E deferral or phase acceptance.
