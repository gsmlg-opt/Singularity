# Phase 5 upload-stage cleanup observation

## Status and authority

Diagnostic candidate only, under AGENTS.md continuous development authorization.
This is not a behavioral repair, timing waiver, Task11/Phase5 acceptance or a new
product feature. Native134 FAIL remains immutable. E2E is NOT RUN. Default2 and
its unsupported-canonical guard stay; Task16 remains UNSATISFIED/UNWAIVED/
BLOCKED_DESIGN, Task17 NOT GO, masterTask18 still depends on11,12,17. No commit,
merge, push, version/tag/release/deployment/activation/backfill in this slice.
Independent design SPEC then NEW distinct QUALITY precedes observer changes;
actual observer SOURCE SPEC then NEW distinct QUALITY precedes Native observation.

## Evidence and causal question

Native134 ordinary NOARGS `mix test`, seed293439/max_cases96, naturally exited2
at2026-10-17 14:32:17+08. Actual2215tests+10properties/1FAIL,2083 normal integration
exclusions. Full safe raw SHA256
`4b7a4ec76ae5d8610e4e57e77ba026a7893ded6a7af725c8e5fadfff3de44f23`.
The sole failure is UploadSessionLockTest's real partially-written stage case:
no stage_abandoned notification within the unchanged default100ms.
Its six queued messages all belong to initial creation. There is no observed
post-controller-death abort-entry, abort-return, abandonment transaction or
session-DOWN witness. This does NOT prove fsync, a lock, scheduling delay, or
eventual cleanup failure. Native135 separate ordinary postSQL was natural0/EMPTY,
rawSHA `c5f161cbeefd4ecfc99a85603a3d50688fda10929da145540ecb283ce483e3ec`.

Two independent read-only Sol diagnoses found source ordering already requires
real physical abort/unlink/directory fsync to return :ok before abandonment.
The writer is killed asynchronously before abort. Native136 unchanged whole
owner at seed293439/WAE naturally passed23actual tests,2 normal integration
exclusions; rawSHA
`0870f81e1258d686c3a5a27323cc63bb97364a6eb14f10b1cbf3a499c1978340`.
Native137 ordinary postSQL natural0/EMPTY, rawSHA
`b004c46962fa2a170bc52d186db0b21c4d237b956d41bbc271ddc8483bc09747`.
Standalone PASS is not a fix or qualification of failed full context.

Initial reviewed measurement: a reversible, delegating adapter observer
separates no-abort-entry, inside-real-abort and returned-real-abort at the
original assertion window. It cannot distinguish the lock, scheduler and
fsync sub-buckets within abort. Further observation requires a new concrete
evidence question, not an attributed cause or blind rerun.
Rejected: timeout extension or an extra settlement wait shifts the original
window without explaining the failure. sync_fun injection is not chosen:
delegating to public Sync functions would wrap errors again unless translated.
Global tracing is unnecessary for this first, narrower question.

## Native142 late-invalid-text observation amendment

The first observer passed actual independent SOURCE SPEC then NEW distinct
SOURCE QUALITY, scoped format/check and ordinary posts. Its immutable1255-line
owner is archived at
`.devenv/phase5-task11-v3-saga13-native142-first-observer-owner.exs`, SHA256
`b1cff65894aa4c85c386ae652e7ab0f50559a4be7e28b28b91c0d5c7def70a5e`.
The four pre-amendment governing documents are separately archived unchanged.

Native142 exact whole owner, seed293439/WAE/max_cases96, naturally exited2:
23actualtests/1FAIL/2ordinary integration exclusions,3.6s. Safe full raw SHA256
`fdd641ce462182cb3e5def2bb9516093b9c3a9c0ba71af5e85e265b8c7a5c6ba`.
Native143 ordinary postSQL naturally exited0/EMPTY, rawSHA256
`184c90b1042b5a8f50b16e8dea6fbd48e7abd69dc2a80664748e0c1a251479a2`.
Both complete safe raws/natural footers were read and sealed with closing guard.
The controller case passed with trigger229166us, abort-entry229206us and
returnOK265752us:40us dispatch and36546us inside real abort. This does not
explain Native134's failure or qualify any required gate.

The new failure is the previously unmodified real partial-encrypted-stage
late-invalid-text case, original687/current743. Its original unsupported_media_type
append assertion succeeds, then abandonment is not observed in100ms. Again only
initial creation events are queued. Declared18 bytes comprise the original17-byte
valid first chunk and one NUL byte; no length mismatch or concrete shared fixture
pollution was found. Source proof: UploadSession.append_chunk/5 sends the error
reply BEFORE terminate_abandoned/3. The rejection is not a cleanup-completion
witness. Both triggers reach the same cleanup function, but their failures need
not share a cause. The prior valid append already completed its real stage write;
asynchronous writer kill alone does not prove held-lock contention. No runtime
cause is yet established and no production repair is authorized by this slice.

Extend ONLY the same reversible observer to that second named real-file case.
Reuse the existing real delegating adapter and after0 drain; add its case-local
recorder, a fixed invalid_append/trigger marker immediately before the ORIGINAL
invalid append assertion and invalid_append/return/error immediately afterward.
The original append, abandonment/DOWN/empty-stage and no-seal assertions remain
in their original order with their exact deadlines. No awaited marker, sleep,
poll, settlement barrier, replacement return, or extra native operation.
Extend only the drain's fixed phase allowlist with invalid_append; existing
edge/status labels suffice. Each case drains its own test-process observations,
so no PID/path/content label or shared recorder is needed. This separates public
error return, pre-abort delay and real abort duration without attributing a cause.
No sync_fun override or error translation is introduced.

This amended scope needs fresh independent design SPEC then NEW distinct QUALITY,
then actual SOURCE SPEC and NEW distinct QUALITY on the resulting complete owner
before any amended diagnostic test. The original1199/15d01e52 archive remains
immutable. The642b52be diagnostic guard and its two one-owner derivatives remain
unchanged; only the current full source manifest pins the next owner hash.
There is no second pin exception. New delta must be independently reversible to
first-observer1255/b1cff658; removing ALL observer delta must restore1199/15d01e52.
Native134 FAIL, Native136 standalone PASS and Native142 FAIL stay distinct.

## Exact test-only ownership and observation

Only temporarily change
`apps/singularity_runtime/test/singularity/runtime/upload_session_lock_test.exs`,
original1199lines/SHA256
`15d01e52d2c2fadf738ab0c7db53c9f707cb2c19cfddaf5ad282bdffc70c9f50`.
Parent first archives exact original bytes privately and seals archive/hash.
Only the named real-file controller-exit and late-invalid-text cases use the
temporary nested observing adapter and case-local recorders/drain.
Do not change another test, shared
helper, production code, released migration, Vault mock/locking/key/custody/
capability/DownloadLease, crypto, bytes, fsync or semantic assertion.

Explicitly delegate the real adapter functions required by EncryptedStageWriter
unchanged; no mock return or replacement operation. Only abort_stage/2 records
a begin event, calls LocalFilesystemAdapter.abort_stage/2 ONCE with the original
arguments, records a normalized returned-status event, and returns the exact
original result. No rescue/catch/error translation, fake success, injected error,
sleep, retry or extra physical operation. Exceptions keep existing propagation.
Use a case-local observer closure added to storage context; no global config.
The original root/stage/upload/material/key functions and original real adapter
filesystem observations stay. No shortening input or reducing native work.

Recorder uses only send to the test process and monotonic integer offsets.
A trigger event is recorded immediately before the ORIGINAL controller kill
or invalid append. The second case also records its original append-error return.
Wrap only their original trigger/notification/DOWN/empty-stage assertions in try/after
to drain received diagnostic events with receive-after0. Never await a diagnostic
event before an original assertion. Output only fixed phase/kind/status labels
and integer elapsed values; no PID/path/resource/UUID/content/error/config/key.
Do not perform synchronous diagnostic IO on the session's cleanup path.
Missing return is merely not observed in that original window, not a claim that
it never returned. Preserve original default100ms receives, cleanup callbacks,
async:true, max_cases, complete test body, and both final assertions.
Observation overhead means no diagnostic run qualifies a required gate.

## Source guards and restoration

The owner is not in truefrozen56 but IS in both accepted native-text source
registries. Old manifests/guards/pins/raw remain immutable. Derive a NEW
diagnostic guard from recovered21905 guard: ONLY replace the two already-filtered
native-text code/common manifest references with new derivatives that exclude
this one exact original owner row. Add exact-count and diff proofs that each
derivative removes only that literal1199-line owner's hash/path row. Keep the
existing ResourceOwner historical exception, truefrozen56, every other source,
branch/HEAD/index/status/toolchain/privatePG21905 and owned0 checks unchanged.
The current full source generation explicitly pins the observed owner's NEW
exact bytes; this is not unpinned source or a frozen-registry regeneration.
Parent records exact old/new guard bytes and deterministic narrow derivation.
Independent observer SOURCE reviews cover guard derivatives and full owner diff.

After measurement remove ONLY observer delta and prove exact original1199lines/
15d01e52 hash. Switch back to the original recovered21905 guard, retaining the
diagnostic guard as immutable historical evidence. No observer or pin exception
may remain active for final qualification. A behavioral repair needs its own
causal design/plan, meaningful RED, Sol repair and independent reviews; this
observation authorizes none. Existing failed Sol repair rounds0/Astra0 here;
diagnosis, observation and design advice are not repair attempts.

## Native protocol and remaining gates

Parent-only exclusive direct Native launcher, fresh private umask077 raw,
fresh exact source/status seals, natural actual lifetime/exit/full safe raw
through EOF, ordinary separate postSQL0/EMPTY and closing guard. All other
actors/commands CLOSED before Native; while LIVE ONLY exact empty owned polls
and commentary. Never access the prohibited historical credential log.
Each reviewed observer generation's first whole owner uses the same Native136
argv, seed293439/WAE.
If a concrete unanswered measurement question needs the original full context,
run at most one diagnostic full `mix test --seed 293439`, unchanged max_cases96
and async scheduling, not a selected subset. Do not run it automatically.
Preserve every outcome and ordinary exclusion separately.
No repeated full run without a concrete new measurement question.

All master/prerequisite/retained-owner/sole-restore and permitted README gates,
actual combined source SPEC then NEW QUALITY, small local source commits and
separate reviewed documentation handoff remain required after real qualification.
No focused or observed PASS erases Native134 FAIL or advances a failed phase.
