# Phase 5 Task10 — internal upload enumerable compatibility repair

Status: REVIEWED FOR IMPLEMENTATION — actual independent SPEC then NEW distinct
fresh QUALITY CLOSED PASS; parent Stage1 whole-file expected RED is verified.
Continuous development authority permits this necessary compatibility design;
no routine human approval wait. Stage1 Native56741 CLOSED2,9tests/one intended
actual-handoff structural failure,8 characterization PASS, raw9a517825; all24/
protected guards and ordinary maintenance EMPTY. Same Sol has bounded Stage2
production repair CLOSED: exact transformation/inverse PASS/runtime193186be,
scoped format24363 CLOSED0, new-file GREEN37929 9/0/raw0af537da, unchanged
lock83808 8executed/0failures/2excluded/rawfe807a67. Complete24/protected guards/
ordinary maintenanceEMPTY. Bounded actual Source SPEC then NEWdistinctfreshQUALITY
CLOSED PASS; ONE ordinary seed151533 cohort70920 PASS2092+10properties/0FAIL.
Fresh permitted README gates1–5 PASS; exact NO-ARGS unit34963 CLOSED2/default96/
seed879520,2092+10properties/1PDF classification FAIL/1874excluded, raw7456c42e.
Original malformed assertion/deadlines unchanged; Runtime1033/0 does not replace
that FAIL. All current seals/process absence/ordinary maintenanceEMPTY. Two
read-only Sol maps CLOSED; underlying Poppler failure boundary UNKNOWN. Reviewed
sanitized diagnosis is next; gates7–15 NOT STARTED. Cumulative Source qualification
FAILs Sol3/Astra5 preserve historical Sol2/Astra5; new PDF repair rounds0.
Final full Source reviews/local commits/literalGitclean and acceptance pending.
No phase acceptance follows from design review or expected RED.
Worktree `.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`, HEAD1c1ca7f68035e255247e0c2efb86d16000bb34c5.
Task10/Phase5 NOT ACCEPTED; Task11/12 Source NO GO; E2E NOT RUN.

## 1. Evidence and bounded objective

Historical Source5 exact no-args unit FAIL/rawf57a07a7 and Source6's seeded
Native41194/60276 FAIL remain FAIL. Source6 focused44/0 did not cure the seeded
failure; fresh Source6 no-args README qualification is NOT STARTED. The
preloading observer Native17632 PASS is diagnostic-only, never acceptance.

Non-preloading diagnostic Native60276 naturally CLOSED2 at2026-10-14
04:12:03UTC:2083executedtests+10properties/1original100msfailure/1874excluded;
complete973line/122668byte rawSHA256
`58bb34952b99fc86506641045607a80e275eb62ba93693c9c83fc8ea107a813f`.
Qualified observer COMPLETE/3session barriers/destructions/natural closure;
same failed writer<0.127890.0> waits in cold
Enumerable.Singularity.Runtime.Assets.UploadSession.MessageStream loading.
load_ok REQUEST84.923395ms after undefined entry is not completion; last
waiting sample92.975378ms after entry. Exact assertion-start/continuous100ms
blocking/code-server delay cause are NOT measured or established.

Bounded Astra recovery CLOSED under SOL_IMPASSE: existing evidence suffices
to remove this demonstrated source-specific protocol dependency without
explaining OTP loader latency. Standard Enumerable.Function remains lazily
loadable; this repair promises no universal100ms scheduling/loading bound.
Independent Sol inventory found exactly one concrete stream construction and
no other struct matching/serialization/custom-implementation dependency.
EncryptedStageWriter consumes Enumerable.t through Enum.reduce_while;
original test Writer uses Enum.each. Neither requires a custom struct.

Objective: replace only that internal representation, preserving stream
behavior and all public readiness, authorization, persistence and cleanup.
No additional observer implementation or unchanged-Source cohort repeat.
The proposed code-server diagnostic design remains unexecuted historical
preparation, not a required repair/acceptance gate.

## 2. Selected minimal design and alternatives

Inside the already-loaded UploadSession module, add a private constructor:

```elixir
defp message_stream(owner) do
  fn accumulator, reducer ->
    reduce_messages(owner, accumulator, reducer)
  end
end
```

At the sole current construction, replace `%MessageStream{owner: owner}`
with `message_stream(owner)`. Keep this position before the unchanged writer
spawn, custody attachment and handoff. Move existing private reduce_messages
and reduce_chunk clauses verbatim into UploadSession; remove only the obsolete
struct/defimpl/alias made unused by this repair. No new public/test-only helper.

The constructor only captures the owner PID. It does not enumerate, receive,
execute a reducer, preload, acknowledge, spawn or capture upload/key material.
Receives/reducers and self() in acknowledgements still run in the writer.

Rejected separate-module new(owner) at the existing construction: a new
remote load/constructor failure after material claim would occur before
claimed_state exists and outside the writer's rescue/ordinary abandonment.
Rejected constructing inside the writer: catches that failure, but adds an
unnecessary module load before adapter startup and changes the internal
start-message representation. Rejected consumer-readiness handshake: changes
readiness/order and can deadlock if it waits for the deliberately held chunk
ack. Rejected preload/warmup/test-order/timeout changes and unproved Markdown
optimization. Exact code-server measurement remains a fallback only if a new
failure supplies a concrete unresolved question; it is not needed first.

## 3. Preservation contract and explicit limits

- Initial halt and suspend do not consume messages or acknowledge chunks.
- Continue selectively receives only chunk/finish messages pinned to owner.
- Reducer completion precedes exactly one applied ack for cont/suspend and
  exactly one halted ack for halt. Suspended continuations preserve owner,
  accumulator and reducer; finish returns done without chunk acknowledgement.
- Reducer raise/throw remains in the executing writer's existing try, with
  existing error/abandonment cleanup and no false success/seal/chunk ack.
- No eager request-body consumption, changed backpressure, duplicate/lost
  ack, changed finish-after-second-commit, new readiness message or state.
- Public await_ready still guarantees consumed grant and committed stage,
  not consumer dispatch. All grant/stage/custody/lock/secret transitions and
  adapter calls remain byte-for-byte outside the selected stream delta.

Concrete representation changes from private struct to arity2 function.
Count/member/slice remain unsupported fast paths with ordinary reduction
fallback; their error-module identity becomes Enumerable.Function. No actual
repository consumer depends on the old module identity. Do not claim an
undocumented external struct API or live hot-code-upgrade equivalence: a local
closure retains its defining code version. Ordinary clean-build qualification
is required. Generic protocol loading/scheduling remains a residual risk.

## 4. Actual-handoff regression, not a copied stream implementation

New `upload_message_stream_test.exs` uses the actual public UploadSession
construction/handoff with test-local injected recording writer and minimal
pure adapter callbacks matching established unit interfaces. Do not require
the frozen .exs file or register its tests again. Do not copy reducer logic,
export private helpers, extract/recompile AST or substitute a synthetic stream.

Existing direct-material compatibility fixtures may supply only inert unit
bytes through the already-established adapter contract. No custodian or live
material_ref/key lease, key/Vault operation, SQL, filesystem encryption, new
secret behavior or production custody proof is introduced. This is isolated
stream characterization, NOT live crypto/custody/V3 acceptance. No global
Application configuration or shared test-helper changes.

Before production changes, verify existing behavior with exact PID/ref
barriers and bounded monitor/Task closure. A separate structural contract
inspects the ACTUAL handed-off stream: is_function(stream,2), defining module
UploadSession, captured environment exactly [owner_session_pid]. Baseline
struct deterministically fails this assertion; no undefined-helper failure
or timing failure is the intended RED.

Characterize laziness, executing writer identity, ACK-after-reducer-return,
cont/halt/suspend/resume/finish, initial halt/suspend, wrong-owner/unrelated
message preservation and exception/ordinary abandonment. Use established
public append/finish/abandon and controlled writer barriers; no sleeps, elapsed
time assertions or weakening existing100ms tests. Cleanup owns exact processes
and refs even on assertion failure; no orphan writer/session/Task.

ACKs target the actual session, not the test. Task.yield(...,0) alone is NOT
a deterministic absence proof. For strict ordering assertions, use one owned
OTP trace session scoped ONLY to that test's writer PID/send events. Keep it
inactive before the capture barrier, observe only inert fixture ACK/boundary
messages, validate exact owner/writer/reference identities, and use delivered
barriers to exclude pending earlier events while the reducer is held. No
application MFA/global/default-session tracing, raw content logging, unrelated
session mutation or test-process-as-owner substitution. Destroy that exact
owned session on all paths, including failed initialization and assertion
cleanup; no Native-side helper process persists. Positive applied/halted ACK
controls accompany negative pre-release/duplicate/exception assertions.
Tracing is isolated test evidence, never live custody or general latency proof.

## 5. Ownership, exclusions and qualification

One Sol author owns only:

- `apps/singularity_runtime/lib/singularity/runtime/assets/upload_session.ex`;
- NEW `apps/singularity_runtime/test/singularity/runtime/upload_message_stream_test.exs`.

Parent owns design/plan/evidence, manifests, Native execution and GO. All22
existing Source6 files remain unchanged; original lock test SHA
`187d107d66f19ef0e1df7bf8235cc8db39a9a13ff7f448213770303331c6e83b`
and EncryptedStageWriter are protected. Frozen56/current protected3/A1/locked13
and both historical utility seals remain current. Add a NEW combined24-source
seal containing unchanged22 plus these two files; never overwrite old receipts.

No Vault feature/test/UX/locking/key/capability/custody/DownloadLease/defaultV2
change; no migration, dependency/application/protocol scope expansion. Runtime
file's existing legacy Vault calls/imports are untouched; this is only its
necessary internal stream compatibility patch. Original Writer/assertions/
100ms/deadlines/async/default96/seed/discovery/test-helper/launcher unchanged.

After independent design/plan SPEC then NEW distinct QUALITY PASS, stage1
authorizes only new tests. Parent verifies intended structural RED and passing
preservation characterization before stage2 production GO. Focused GREEN plus
unchanged whole original lock tests, bounded actual Source SPEC→NEW fresh QUALITY
and ONE ordinary seed151533 cohort precede all15 exact fresh README gates.
No focused/instrumented PASS substitutes no-args unit/integration/restore;
required gates/final actual Source reviews/small LOCAL commits/literalGitclean
remain required before Task10 acceptance. Failures enter bounded diagnosis and
Astra routing; SourceSol2/Astra5 cumulative history is never reset, minimum
three attempts is not a maximum. E2E remains NOT RUN/manual deferred, not a
final browser/release waiver. No merge/push/version/tag/release/deploy/production.
