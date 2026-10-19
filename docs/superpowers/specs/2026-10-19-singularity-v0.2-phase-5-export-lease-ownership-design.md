# Phase 5 Task16: native export-request lease ownership

Current source snapshot: native prerequisite locally qualified at
`6c7f867309470e23e8f34c06a8f53af0b496d48d`, after actual independent SOURCE SPEC
then NEW distinct QUALITY. See the
[handoff](../../verification/2026-10-19-phase-5-export-lease-ownership-handoff.md)
for gates, source commits, the preserved P2 finding and evidence limits.
Original Task16/Phase5 remain unaccepted. Documentation reviews/commit/clean
closure are subsequent actual facts, not proven by this snapshot.

Historical design-stage status: approved product boundary; implementation NOT STARTED. Coordinator
self-review is complete; independent DESIGN SPEC then NEW distinct QUALITY
remain required before source GO. This document is not native qualification.

## 1. Authority and baseline

On 2026-10-19 the user explicitly approved the recommended minimal native
ownership exception: “好的, 就这么做, approved”. This supersedes the compile-only
Vault rule solely for export-request acquisition, ownership and cleanup in
`KeyCustodian` and `DownloadLease`. It does not authorize general Vault work.
The continuous-development mandate covers design, tests, necessary repairs,
independent reviews and small local commits without routine approval pauses.

Worktree: `.trees/v0.2-phase-5-export-backup`; branch
`codex/v0.2-phase-5-export-backup`; initial clean HEAD
`a5afb537e7d8f7455ec71e7c98bc120d5d397673`. The Task12 source and documentation
closure are historical qualified evidence, not Task16 or Phase5 acceptance.

The [original artifact ownership design](2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership-design.md)
and [plan](../plans/2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership.md)
still govern orchestration, startup serialization, exact Task8 attribution,
handles, authorization, deadlines and artifact cleanup. Their two strict native
lease gaps remain UNSATISFIED and UNWAIVED until actual checks pass. Their old
frozen-interface prohibition is superseded only by this explicit exception.

E2E is manual-deferred and NOT RUN. No merge, push, version bump, tag, release,
deployment, production activation/backfill, migration or production data change.
Seven applications, zero xref cycles and all original source/security assertions
remain required. No new telemetry, dependencies, public flags or configuration.

## 2. Observed problem and alternatives

Ordinary `KeyCustodian.lease/2` uses a default-timeout `GenServer.call/2`.
Asset and Document request handlers ignore the caller and create leases with
neither export ownership nor acquisition cancellation. A wrapper cannot revoke
an identifier it never received. Monitoring a companion after issuance does not
cover its death before it records/forwards the PID. Monitoring only the requester
also misses a public-call timeout when that requester remains alive.

Selected architecture: a dedicated native export entry point, pre-enqueue
monotonic deadline and private pending/accepted/cancelled acquisition ticket,
with a native caller monitor and real cleanup timer. Ordinary requests retain
their old path. Merely shortening the existing TTL, denying later reads without
cleaning idle custody, reusing extraction-worker mode, global enumeration,
private custody messages, `:sys`, and session-wide revocation are rejected.

The Astra architecture advisory supplied lifecycle analysis, not production
implementation or a repair attempt. Initial source repair counters are Sol0,
Astra0. No failed historical review or native result is erased by this design.

## 3. Native API and acquisition handshake

Add only the dedicated public entry point:

```elixir
@spec export_lease(GenServer.server(), map()) ::
        {:ok, pid()} | {:error, :waiting_for_unlock | Singularity.Core.Error.t()}
def export_lease(server, request)
```

Accept exactly the current Asset `purpose: :download` and Document
`purpose: :document_source, access: :request` shapes. Reject every other mode,
extra caller-selected field and malformed request through existing sanitized
errors. No owner PID, timeout, clock, ticket or export option enters the request.

Before sending, allocate a private atomic ticket and native monotonic deadline
`System.monotonic_time(:millisecond) + 5_000`. The five seconds are acquisition
budget, not the successful lease lifetime. A small internal
`DownloadLease.ExportOwnership` module in the existing source file owns:

```text
new/0, remaining_ms/1, status/1, accept/1, cancel/1, expire_pending/1
pending -> accepted -> cancelled
pending ------------> cancelled
```

Cancelled is terminal. Acceptance must never change cancelled back to accepted.
`expire_pending/1` atomically changes only pending to cancelled; observing an
accepted ticket does not expire a successfully acquired lease.

The internal call is `{:export_lease, request, ticket}`. The native handler
derives cleanup owner from the real `{caller_pid, tag}` call origin, never from
request/ticket fields. The ticket is lifecycle state, not authority, source
binding, key material, an external handle or a logging/telemetry value.

The wrapper calls with the remaining budget. On call timeout/exit it cancels
before returning the existing retryable storage-unavailable error, even if the
caller survives. On `{:ok, lease}` it checks the deadline, CASes pending to
accepted, then checks the deadline again. If any step fails it cancels and
synchronously revokes the known PID, or confirms it is already terminated.
It must not claim completed cleanup before native acknowledgement/termination.
The post-CAS check matters: the acquisition timer may have observed accepted
and stopped acquisition cleanup before the wrapper discovers deadline expiry.
That path therefore explicitly revokes the known lease; cancellation alone is
insufficient. An unknown-PID timeout cannot have an accepted ticket because
only the wrapper accepts after receiving a successful native reply.

## 4. Custodian composition and unchanged authority

Add narrowly separate export clauses rather than refactoring ordinary handlers.
Keep the old request validation, binding projections, session matching,
principal/owner checks, epoch/revocation checks, capability and source binding,
object-key loading and validation, and session lease registration unchanged.
Document request mode remains `mode: nil`; do not borrow worker mode.

Check ticket/deadline and actual caller liveness before and after potentially
blocking object-key loading. If cancelled/expired/dead, do not start a usable
child. The existing `start_download_lease/5` private-options seam carries:

```elixir
%{export_ownership: %{owner_pid: actual_caller, ticket: ticket}}
```

These private options do not enlarge either validated request. The authorization
dependency bundle stays pointed directly at the genuine existing custodian.
No change to session registration/revocation policy or broader cancellation.

## 5. Native lease lifecycle and cleanup

For export-owned leases only, install the owner monitor and acquisition timer
before the clock callback and before constructing usable key-bearing state.
Check ownership/ticket/deadline before and after that callback. A delayed init
must reject a dead owner or cancelled/expired acquisition; a fresh ordinary TTL
must not revive an abandoned acquisition. Keep existing 60-second TTL semantics
for accepted leases, including Document reads after the acquisition deadline.

Pending tickets deny reads without storage I/O. Acquisition timer expiry CASes
pending to cancelled, executes actual `revoke_state/1`, kills and awaits an
in-flight reader, clears custody, and stops. Accepted makes only that acquisition
timer a no-op. Owner DOWN cancels, revokes and stops. Explicit export revoke
cancels, completes existing reader cleanup, acknowledges and stops. Custodian
death and original expiry remain fail-closed.

Guard cancellation/owner liveness both before storage I/O and immediately before
successful delivery, including after potentially blocking clock/revalidation
work. Do not rely only on queued DOWN/timer messages. Existing authority
revalidation before/after storage is retained. Extend existing worker reader
link/trap-exit cleanup to export ownership without changing its mode: hard-killing
an export lease must not orphan its reader. Do not change ordinary request or
extraction-worker behavior, including their caller restrictions and empty-source
authentication. No key bytes or user content in observers, logs or errors.

There is no universal wall-clock cleanup guarantee while the established
loader/clock/revoke callback itself is blocked. Distinguish cancellation
requested, delivery denied and cleanup confirmed. Tests release their barriers
before asserting final native cleanup, without treating manual teardown as
autonomous cleanup. A PID becoming unreadable alone is not proof its in-flight
reader and key custody were cleaned.

## 6. Orchestrator integration boundary

The eventual Task16 companion-side `ExportArtifact.Leases` adapter delegates
acquisition to `KeyCustodian.export_lease/2`, retaining its signatures. It records
returned PIDs before forwarding and retires them only after native revoke or
termination. Native ownership covers companion death before that recording.
Existing `Assets.Download` and `Knowledge.ExportRead` custodian seams suffice;
both source files should remain byte-identical in this prerequisite.

An artifact-generation/handle-call timeout while its caller survives must also
explicitly cancel by its already-known operation reference; requester monitoring
alone is insufficient. Cancelling known leases remains explicit. A companion
blocked in acquisition handles its operation message after return/timeout; the
native deadline prevents abandoned unknown custody during that interval.
This prerequisite does not implement the artifact owner, Api or startup changes.
After its qualification, resume the original Task16 plan, do not mark Task16 or
Phase5 complete merely because this native primitive passes.

## 7. Exact source scope and frozen attribution

Production edits in this prerequisite are exactly:

- `apps/singularity_runtime/lib/singularity/runtime/key_custodian.ex`.
- `apps/singularity_runtime/lib/singularity/runtime/download_lease.ex`.

Add new focused `export_lease_ownership_test.exs` and
`export_lease_ownership_contract_test.exs`; add only new cases/delegating observers
to `knowledge_export_custody_live_test.exs`. Preserve all its previous assertions,
fixtures and genuine authority/source paths. Ordinary unit owners remain
unchanged. The detailed plan names complete paths and commands.

The original ignored frozen56 manifest remains immutable, SHA256
`d0296d241c66e382baa09a0a092fe8add6df66364d5f2d5644f4f4ea1963a050`.
Original raw DownloadLease SHA256 is
`3ecce1470e11d506435d8213faa1b2c0c012ffb360cb3e4b82f67bdd5277636e`;
KeyCustodian is
`33a5eb62e2e8ff951dfddbb65cb029a66654a56bdab51e553a89e7d98d95b7bd`.
After the authorized patch, literal `sha256sum -c` is expected to report exactly
these two raw mismatches, never described as all56 raw PASS. Remaining54 must
match byte-for-byte. A checked source contract inverts each reviewed exact hunk,
including unique old/new text, both context edges and digests, and reconstructs
these two original raw hashes. Reject missing, altered, duplicate, relocated,
coexisting registrations/clauses, extra fields and unrelated legacy mutations.
Do not replace original hashes, normalize a whole module or silently filter
mismatches. Existing Task8/native-text attribution remains unchanged.

## 8. Required evidence and acceptance

First characterize unchanged complete ordinary owners and live custody. Write
focused tests and execute genuine RED before native source changes. Additive
real-encrypted Asset and retained-Document witnesses must cover:

- Loader returns after the actual public five-second timeout; caller survives.
- Init clock spans that timeout, with observed PID never used for production
  recovery; release it and prove cleanup without a later read triggering it.
- Cleanup owner dies before init usability and after genuine return but before
  the wrapper records/forwards the PID.
- Owner cancellation/death during a genuine read kills/awaits the actual reader
  and delivers no plaintext, including hard lease death.
- Accepted Document leases survive acquisition deadline under original TTL.
- Acceptance/cancellation/deadline transition counterproofs and explicit known-PID
  revoke on post-accept deadline failure; label pure state/source proofs as such,
  never as live race execution.
- Same-session ordinary sentinel and second independent export remain usable;
  forged bindings, modes, epochs and unsupported access remain denied.

Do not insist late issuance starts a child: rejection before spawning is valid.
Fence the custodian by a supported public call after releasing a loader. If an
init observer reports a PID, require its cleanup outcome. No private protocol,
`:sys`, dynamic-supervisor enumeration, ticket/key disclosure or manual revoke
of an unknown PID as a substitute for production recovery.

Root alone executes serial private-PG native gates, retaining complete raw PTY
outputs, exact argv/exits/counts/hashes, and each invocation's own ordinary
post0/EMPTY. No simultaneous author commands or VM work. Required final scope:
whole new unit and source-contract owners, whole unchanged ordinary owners,
whole genuine live owner, architecture owners, format check, warnings-as-errors
compile and xref zero cycles. Independent SOURCE SPEC then NEW distinct QUALITY
review actual complete changed owners and evidence. Fix failures without
weakening assertions; escalate after two failed Sol rounds/evidenced impasse.
Keep design advisory separate from repair counters. Local source commits and
docs/clean closure follow actual qualification. Full Phase5 README gate remains
Task19, not a claim of this prerequisite. E2E NOT RUN.
