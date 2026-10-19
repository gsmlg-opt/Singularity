# Phase 5 Task16: cleanup after companion death

## Status, authority and scope

Architecture candidate; production implementation and runtime qualification are
NOT STARTED by this document. Independent DESIGN SPEC followed by NEW distinct
DESIGN QUALITY on the exact design/plan bytes is required before source GO.
The parent owns that disposition and subsequent Sol implementation.

The continuing development authorization permits this necessary lifecycle
repair without another routine human approval. This is a bounded forward
amendment to original Task16, not an amendment to native custody or the product.
Read together with:

- [Original ownership design](2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership-design.md).
- [Original implementation plan](../plans/2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership.md).
- [Accepted acyclic composition design](2026-10-19-singularity-v0.2-phase-5-export-acyclic-composition-design.md).
- [Qualified native lease handoff](../../verification/2026-10-19-phase-5-export-lease-ownership-handoff.md).
- [This amendment's implementation plan](../plans/2026-10-19-singularity-v0.2-phase-5-export-companion-recovery.md).

Inspected worktree is `.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`, HEAD
`65416569cbf5adffa8e5733900e29a2cf40c5161`. The Artifact production file currently
contains only Handle/Inspect; owner/companion behavior is still prospective.
Other authors own the in-progress API, artifact, native and architecture tests.
This architecture assignment writes only this design and its new plan.

No public Api operation/arity, Handle field, native lease API, source format,
database migration, dependency, application child or supervisor policy changes.
Vault remains frozen except for the separately qualified native exception.
E2E remains NOT RUN/manual-deferred. No merge, push, version/tag/release,
deployment, activation, backfill or production-data action is authorized here.
Architecture work consumes zero implementation repair rounds and resets none.

## Evidence and the missing cleanup actor

Original design, "Owned directories, cancellation and restart," requires
stopping the owner and observing DOWN before removing its owned envelope.
Original plan Step4, lines 608–616 at the inspected revision, repeats this rule.
The companion retains an independent envelope identity because Writer ETS
disappears with the owner. Original Step3, lines 490–496, also requires actual
owned-filesystem removal after companion hard death, separately from native
lease inactivity and closed delivery.

If the sole companion dies and the owner simply exits, neither can subsequently
observe owner DOWN and perform deletion. The qualified native lease monitor
solves native custody cleanup; it does not remove an export directory. A
generating requester is not a sufficient fallback: it may already be dead,
and accepted artifacts intentionally outlive it.

The accepted acyclic amendment preserves cleanup-after-owner-DOWN. Its fixed
work closure does not supply a surviving cleanup actor. This document therefore
changes lifecycle responsibility explicitly rather than hiding it in that seam.

Local Elixir `Task.Supervisor.start_child/3` documentation/source states that
the task is linked to its supervisor, not to the caller; its default restart
policy is temporary. The existing Runtime child in `application.ex:72–77` is
`UploadRecoveryTaskSupervisor`. No new supervisor is needed.

## Alternatives and selected boundary

1. **Selected: one cleanup-only replacement.** After confirming original
   companion DOWN, the surviving owner starts one temporary task under the
   same existing task supervisor. The task monitors the owner, acknowledges
   readiness, waits for owner DOWN, then cleans the original envelope.
2. **Owner deletes before exiting.** Rejected: violates the required ordering
   and risks deleting while the producer still owns live work/resources.
3. **Generating requester performs cleanup.** Rejected as the general remedy:
   it cannot cover accepted artifacts after requester exit or requester death
   during generation.
4. **Permanent third watcher, global registry, or restarted materializer.**
   Rejected: expands infrastructure, ownership or execution unnecessarily.
5. **Count startup scavenging as immediate recovery.** Rejected: startup is
   separate recovery evidence and cannot pass the single-companion-fault tests.

There are at most two live operation tasks: original companion plus owner,
then replacement plus owner. Confirmation of old companion DOWN precedes
replacement creation. Supervisor bookkeeping may still retain a terminated
child temporarily; that is not another live operation task.

## State ownership and private interfaces

All production changes for this amendment belong in
`apps/singularity_runtime/lib/singularity/runtime/knowledge/export_artifact.ex`.
Keep the acyclic Export-to-Artifact dependency and fixed work/2 construction.
No Artifact reference back to Export is introduced.

The owner receives and retains the exact six-key operation envelope before
materialization: `id`, `path`, `root`, `root_identity`, `identity`,
`marker_identity`. This is the original trusted ArtifactDirectory descriptor,
not a descriptor reconstructed from a public Handle or directory name.
Its existing runtime holds the original task supervisor and deadline.

Use fixed private helpers with these responsibilities:

```elixir
defp recover_companion_loss(owner_state, down_message)
defp start_cleanup_replacement(task_supervisor, cleanup_context)
defp cleanup_replacement(cleanup_context)
```

The cleanup context contains exactly `owner`, `operation_ref`, `recovery_ref`,
and `envelope`. The original deadline remains in terminal owner state; the
replacement does not create a new deadline or timer and never delivers data.
No Writer descriptor is needed after owner DOWN. Do not pass runtime,
authorization, session, work closure, native adapters, leases, Handle, caller
callback, function selector or application configuration to the replacement.

The readiness message is fixed:

```elixir
{:export_cleanup_ready, operation_ref, recovery_ref, replacement_pid}
```

`recovery_ref` is a fresh reference created by the owner. Both references and
the PID must match stored values. A PID inside a message is not authenticated
merely by its position; acceptance relies on the private references plus the
exact task PID returned by the supported supervisor call. No new opcode accepts
work, a destination or a caller-supplied cleanup descriptor.

## Loss detection and handoff

1. Before linking to the companion or invoking work, the owner enables exit
   trapping and monitors the exact companion. It retains explicit supervisor
   shutdown handling; trapping does not make supervisor shutdown ignorable.
2. Companion EXIT, a failed companion protocol wait, or observed loss marks
   delivery terminal. The owner must confirm the matching companion monitor
   DOWN before starting recovery. An EXIT message alone does not launch it.
3. At generation/publication and content-delivery boundaries, drain matching
   loss/cancellation signals and check the known companion is still alive.
   Never rely solely on a later receive-loop turn. Loss prevents successful
   Handle/plaintext replies and re-entry to work. These checks supplement,
   rather than replace, native authorization and after-COMMIT checks.
4. After the exact DOWN, enter a single terminal recovery transition and
   discard the executable work. Start one temporary cleanup task through the
   original `Task.Supervisor.start_child/3` function variant. Do not link it to
   the owner or use a restarting/async-linked task.
5. The replacement installs its exact owner monitor before sending readiness.
   The owner monitors the replacement and waits for the exact readiness tuple
   or its DOWN. Unrelated/duplicate EXIT, DOWN, readiness and delivery messages
   cannot start another replacement or reopen the artifact.
6. On matching readiness the owner exits without another generation, delivery,
   native acquisition, closed-receipt loop or deletion attempt. Its ETS lifetime
   ends naturally. The replacement waits for its own exact owner DOWN, even if
   the original operation deadline has already expired.
7. Only after DOWN, call `ArtifactDirectory.cleanup(envelope)`. Use its existing
   identity checks and sanitized result. Success terminates normally; failure
   terminates with a fixed content-free shutdown reason indicating cleanup
   failure. Never return normal success for a refused identity check.

The terminal handoff runs outside generic materialization/delivery exception
wrappers. They must not catch its shutdown exit and resume the owner loop.

The owner may need a blocked callback to unwind before it processes loss.
Existing native ownership prevents abandoned native custody, but does not
make arbitrary owner code interruptible. Every release barrier needed for a
test's eventual cleanup must be identified. There is no universal wall-clock
cleanup bound while a callback or supervisor call is blocked.

The replacement receives no lease map. Native leases remain owned by the old
companion, and its death triggers the qualified native mechanism. Actual native
cleanup/read denial is tested independently; owner or replacement DOWN alone
does not prove it.

## Failure semantics and shutdown

If starting the replacement fails or its process dies before readiness, close
the owner with a sanitized failure; do not label cleanup completed. Do not start
an unsupervised fallback, loop over replacements, scan for leases, or reconstruct
the envelope. If the supervisor call's result is unknown, do not issue a second
start that could duplicate cleanup. A task that actually starts after owner
death installs a monitor, observes DOWN/noproc, and may still clean the envelope;
this is only accepted when its actual outcome is observed.

On owner supervisor shutdown, preserve the original shutdown path and native
supervisor policy. Do not create a new task after shutdown has been observed.
During recovery, a supervisor shutdown remains terminal. The replacement does
not trap shutdown merely to extend its lifetime. No shutdown interval, restart
policy, child order or infrastructure-disabled behavior changes.

Single-companion-fault recovery assumes a surviving owner and an available
task supervisor. Simultaneous owner death before replacement registration,
supervisor loss, replacement hard death, or VM loss can leave an envelope.
Startup scavenging handles recognized abandoned envelopes separately. These
are explicit limits, not successes, assertion waivers or reasons to weaken the
required single-fault cases.

## Bootstrap gap and minimal safe disposition

Before an owner exists and has received the envelope, owner-started recovery
cannot run. Do not silently claim this amendment covers companion death between
directory creation and owner/envelope handoff.

Preserve the existing bootstrap rule: the companion creates and records the
envelope before allowing any producer work; the owner must receive that exact
descriptor before Spool/Writer starts. A bootstrap failure yields no successful
Handle, no materialization and no data delivery. Do not introduce a requester
fallback with guessed inode identity, a live-root scan, or another watcher.

Characterize this interval explicitly. If a complete valid ownership marker
survives, real guarded startup scavenging may remove it after all runtime tasks
are gone. A partial or invalid marker is preserved under ArtifactDirectory's
existing rules and is reported as an unrecognized residue, not cleanup success.
This design does not grant authority to delete such entries.

The bootstrap interval is outside this amendment's immediate-recovery claim.
Any original acceptance obligation requiring immediate removal there remains
unresolved until separately designed and verified; neither a document checkbox
nor passing the post-owner single-fault cases may waive it. Parent Task16
acceptance must record the disposition rather than silently broadening this
amendment's guarantee.

## Deterministic evidence and acceptance

Keep every existing native boundary: acquired/pre-record, recorded/pre-forward,
known-forwarded, late issuance after timeout, and in-flight native read cleanup.
The pre-forward clock witness uses the already-approved operation clock:
record lease/monitor, read the pre-forward clock, drain cancellation/DOWN and
check liveness, then reply. No observer option or new lease protocol is added.

Add real-filesystem owner/recovery cases during generation and after accepted
completion plus requester exit. Observe exact owner and replacement monitors;
verify removal only after owner DOWN, no successful response after loss,
foreign/independent-operation preservation and unchanged identity-failure
refusal. Include duplicate loss notifications, malformed/wrong readiness,
start failure, supervisor shutdown and bootstrap characterization. Distinguish
source-order/mutation proof, synthetic authority composition, native custody
execution and actual startup recovery in results.

Test-only bounded tracing, when needed to identify the new task, is confined
to an already-known fixture owner PID and fixed control messages. Do not trace
all processes, enumerate native leases, collect/log user payloads, or use the
observed PID as a production cleanup input. Remove tracing in fixture teardown.
Tracing supplies a witness, never suspension or a substitute for barriers.
Correlate readiness with the actual supervisor start-result PID; a message
having the readiness tag alone is not evidence of an authentic replacement.

Require independent DESIGN SPEC then NEW distinct DESIGN QUALITY before
implementation, causal RED before changed production behavior, and source SPEC
then NEW distinct source QUALITY after actual whole-owner gates. Preserve
original manifests, exact inverses, seven applications and zero xref cycles.
No original assertion is removed, weakened, skipped or relabeled as passing.

## Author self-review

The missing actor is addressed only after original companion DOWN and trusted
owner/envelope establishment. The replacement has no production authority
except the original identity-checked cleanup descriptor. The successful
handoff orders monitor, readiness, owner exit, DOWN and deletion. Failure and
bootstrap limits are explicit. Accepted acyclic composition and native source
interfaces remain unchanged. Source implementation and runtime evidence remain
the parent's subsequent work; this document claims neither.
