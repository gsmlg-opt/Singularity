# Phase 5 Task16: terminal close and cleanup acknowledgement

## Status and narrow amendment

Architecture candidate for task `task16_terminal_close_architecture`, mode
`architecture`, explicit `astra_gate=PROJECT_ARCHITECTURE`. Continuing local
development authority permits this forward disposition without routine human
reapproval. Parent must obtain independent DESIGN SPEC then NEW distinct DESIGN
QUALITY on these documents before affected normal-close implementation GO.

Inspected worktree: `.trees/v0.2-phase-5-export-backup`; branch
`codex/v0.2-phase-5-export-backup`; HEAD
`8fb1142ee593641544769658d03a96cb83ebaa56`. Parent and Sol concurrently own
source/tests/configuration. Initial Artifact inspection contained only
Handle/Inspect; subsequent source changes are in progress and unqualified.
This author owns only this new design and its [plan](../plans/2026-10-19-singularity-v0.2-phase-5-export-terminal-close.md).

Read with the unchanged [original ownership design](2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership-design.md)
and [plan](../plans/2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership.md),
[acyclic composition amendment](2026-10-19-singularity-v0.2-phase-5-export-acyclic-composition-design.md),
and [companion recovery amendment](2026-10-19-singularity-v0.2-phase-5-export-companion-recovery-design.md).
Native lease prerequisite remains qualified separately at
`6c7f867309470e23e8f34c06a8f53af0b496d48d`.

Only the impossible **same owner PID remains alive as a closed receipt**
requirement is superseded: original design lifetime paragraph at lines 275–277
and original plan Step4 at lines 620–623, at the inspected revision. Its public
idempotence and original deadline requirements remain. This amendment makes
the existing cleanup-before-success contract explicit; it does not waive the
original owner-DOWN-before-envelope-deletion rule at design lines 441–446 and
plan lines 608–616. Historical documents and assertions remain intact.

## Evidence and decision

The eventual Writer owner cannot both survive in a receipt loop and have its
actual DOWN observed before cleanup. Writer ETS disappears with that owner;
the surviving companion already owns the independent envelope identity needed
for deletion. Keeping the owner alive to answer repeat close contradicts that
ordering, while interpreting owner DOWN as completed cleanup loses the deletion
result and can falsely return success.

1. **Selected:** terminate the owner; let the existing companion acknowledge
   actual cleanup directly to the admitted close caller. Later calls use the
   already-approved freshly authorized dead-owner no-op. This needs only a
   bounded operation-local reply handoff.
2. Keep the owner alive and delete its envelope: rejected because it violates
   exact DOWN ordering and permits a surviving producer.
3. Add a receipt registry, third watcher or replacement delivery owner: rejected
   because neither public idempotence nor cleanup requires new infrastructure.

No new public arity, Handle field, task supervisor, dependency, migration,
native API, Vault/key/capability behavior or source authority is introduced.
The four Handle fields remain `owner`, `operation_ref`, `binding`, `deadline`;
binding remains the exact five values session ID, principal ID, opaque owner
scope, principal authorization epoch and owner authorization epoch. Inspect
stays opaque. No path, descriptor or companion routing field enters Handle.

## Live-close admission and reply ownership

`ExportArtifact.close/3` runs in the existing public caller, not another task.
Its original owner monitor and fresh per-call reply reference distinguish the
attempt. Initial validation retains exact Handle shape, original reference,
deadline and five-value binding checks against live owner state. Foreign or
malformed handles cannot cancel the owning operation. Current native shared
authorization and after-COMMIT admission retain the existing session, principal,
owner, both epochs, unlocked state and sorted capabilities. An admitted owning
session's authority failure remains a denial and starts terminal cleanup.

For an authorized live close, use the following fixed private handoff. Message
tags below specify the protocol; none accepts executable work or filesystem input.

1. Owner seals entries/chunks irreversibly and drops materialization work. It
   sends its known companion a registration containing operation ref, owner PID,
   caller PID and this call's reply ref. Companion checks its stored owner/ref,
   records one admitted waiter and installs an exact caller monitor before
   acknowledging registration to the owner. The original operation deadline is
   retained, never recomputed.
2. After that acknowledgement, owner sends the original caller
   `{:export_close_route, operation_ref, reply_ref, owner, companion}`. Caller
   accepts it only for its outstanding request to that exact owner, monitors
   that companion, then sends
   `{:export_close_waiting, operation_ref, reply_ref, caller}` to the companion.
   Private refs plus the established owner route bind this reply path; a PID in
   an arbitrary message alone is not trusted. The caller gains no cleanup
   descriptor or new authority.
3. After sending the route, owner requests terminal cancellation from its known
   companion. The companion starts cleanup independently of caller readiness;
   caller death or a lost reply cannot prevent cleanup. If owner dies before
   this request, its existing exact monitor triggers the same cleanup.
4. Companion signals known Writer cancellation, revokes recorded native leases
   with genuine acknowledgement, stops the owner and receives its exact monitor
   DOWN, then calls `ArtifactDirectory.cleanup` with its originally recorded
   envelope. No envelope deletion precedes actual owner DOWN. A missing ETS
   ledger after DOWN is expected and never reconstructed.
5. Only successful required cleanup permits
   `{:export_closed, operation_ref, reply_ref, companion, :ok}` directly to the
   registered, ready caller. The caller requires this exact known-companion
   result, its exact owner DOWN **and** the exact companion's normal DOWN before
   returning public `:ok`; these observations may arrive in either order.
   Companion sends the result then exits normally, without waiting for a further
   caller acknowledgement. The companion can retain only this operation's
   content-free cleanup result and caller/ref/monitor until readiness, reply or
   caller loss, bounded by the original deadline. It then exits. It retains no
   Writer artifact, work, plaintext, runtime authority or reusable receipt.

Registration, route and readiness are internal fixed messages, not additional
API calls. There are at most owner plus companion live operation tasks. The
public caller is the existing caller; no helper watcher is spawned. Concurrent
requests receive the existing sanitized terminal failure if they were not
admitted before sealing; they may retry after confirmed owner death. Do not
create an unbounded list of waiters or revive delivery to serve another close.

The same fixed internal per-call handoff also implements the original admitted
entries/chunk failure obligations. Once stored identity admission succeeds, an
owning-session native authorization, read/checksum or expiry failure seals
delivery and registers that original sanitized error code as the terminal
result. On successful cleanup, reply with that original error, after the same
owner/companion DOWN observations; cleanup failure returns sanitized
`storage_unavailable` instead. This is a fixed result value, never a selectable
callback, arbitrary function or materializer. It does not re-authorize denied
data delivery. Alien/malformed requests rejected before identity admission do
not register a cleanup waiter or cancel anything. Unexpected companion loss
returns terminal error and follows existing replacement recovery, without
claiming completed cleanup. The tag `export_close_route` names this private
terminal reply handoff, not a new public dispatch operation.

## Failure, deadline and retry semantics

| Situation | Required result and cleanup meaning |
| --- | --- |
| Live close completes all required cleanup | Exact companion success plus actual owner DOWN and normal companion DOWN precede public `:ok`. |
| Admitted owning entries/chunk operation fails | Preserve its original sanitized error after completed cleanup; cleanup failure returns `storage_unavailable`; never release plaintext. |
| Owner dies during an in-flight close before routing or acknowledgement | Continue known cleanup if possible; return sanitized failure when its result cannot be established. Never reinterpret this same call as a dead-owner no-op. |
| Companion dies during close | Fail this close; preserve the accepted cleanup-only replacement protocol after confirmed companion DOWN. Replacement success is not a native-cleanup acknowledgement and cannot manufacture this close's `:ok`. |
| Cleanup refuses identity or native revoke errors/times out/has unknown outcome | No successful cleanup reply. Preserve sanitized failure and questionable residue; continue only already-authorized safe cleanup. Never retire an unknown lease as revoked. |
| Close caller dies or its existing call wait expires | Remove its reply ownership; terminal cleanup continues. A timeout is failure/unknown, never proof of cleanup. No fresh cleanup TTL is created. |
| Deadline or idle authority tick cancels without a close caller | Same terminal cleanup ordering, no receipt owner and no invented public acknowledgement. |
| A later call initially observes the owner already dead | Fresh current native authentication and exact five-value Handle/session-hint equality may return no-op `:ok`. No filesystem access, cleanup targeting, descriptor reconstruction or task restart occurs. This is not an assertion that previous cleanup completed. |

An owner monitor firing after this call was sent does not select the last row.
The dead-owner path is selected only before sending an owner request, using a
confirmed dead local owner; it is not a catch-all for call exits. A live owner
always performs its stored exact-match checks, including a wrong operation ref
or changed deadline; caller-supplied hints cannot replace those checks.
Dead-owner hint comparison supplies no proof of the original operation's
existence and grants no filesystem or content authority, as in the original
design. Current authorization denial still fails, even for intact dead handles.

All delivery time remains bounded by the original `created_at + 900_000` and
native Spool deadline. Close, readiness, failure and retry never refresh either.
At deadline stop waiting for caller readiness; report failure if a waiting
call lacks its required result. Cleanup itself may have to finish beyond that
deadline to await genuine native completion and exact owner DOWN; expiration
never authorizes premature deletion or false success. No immediate wall-clock
cleanup bound is claimed for a blocked native call.

The companion-recovery design's four-key cleanup-only context is unchanged.
Single-companion-loss recovery requires surviving owner and supervisor;
bootstrap gaps, simultaneous hard deaths, replacement death, supervisor/VM
loss and unknown start/revoke results retain their honest unavailable/residue
limits. Guarded startup recovery is separate evidence, never a successful
normal-close acknowledgement. Local-node startup guard, infrastructure-disabled
path, original marker recognition and foreign-sentinel preservation stay fixed.

## Acceptance and evidence boundary

Parent adds the terminal-close contract to the existing
`apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs`
before affected source GO: monitor the actual owner and companion before close;
require both exact DOWNs, lost Writer ledger and real root cleanup before the
successful call returns; then repeat close
with the same Handle and show a fresh authority load, no resurrection and no
readable plaintext. Denied current authority, every foreign binding field and
wrong live reference/deadline must preserve their denial/noninterference rules.
Source/order counterproof plus controlled cleanup-failure cases must reject
reply-on-DOWN, success-before-cleanup and dead-no-op fallback after in-flight loss.
Identity-conflict residue and foreign files remain intact. The parent's three
additive regression cases preserve all preceding 22 cases: (1) actual terminal
owner/companion/ledger/root ordering plus repeat authentication; (2) all seven
current-authority denial variants and exact five-hint foreign denial; (3) a
genuine owned-envelope child with mode 000, verified `File.ls` EACCES, causing
actual cleanup refusal after owner DOWN. The third case requires first-close
failure without dead-owner fallback, restores fixture permissions to inspect
residue, then verifies a fresh authorized no-op leaves that residue untouched.
Do not skip the permission precondition or call fixture cleanup before recording
the outcome. Keep existing admitted entries/chunk failure cleanup assertions
and original error codes; test cleanup failure maps to `storage_unavailable`.

The lifecycle fixture's Agent-backed authority and simulated COMMIT are labeled
synthetic even though Writer, ETS and filesystem are real. Genuine native
ALL-leases late-issuance/pre-record-death assertions remain separate, required
and unwaived, including native read denial; primitive acceptance and root absence
are insufficient. All original lifecycle/startup/architecture assertions remain.

Parent reports pre-source native41 as RED: runtime 102 tests/31 failures and
architecture 28/28 failures; Api57, old Application11, real Writer1 and ordering
reproduction1 passed. The reported lifecycle20 and startup11 failures include
missing implementation/helpers; seven undefined-Artifact warnings are expected
pre-source evidence, not GREEN. Parent reports post42 natural residual EMPTY.
These are handoff facts, not reruns by this author. Do not overwrite those raw
logs or historical manifests. New candidate pins and reviews are separate.

## Author self-review and handoff

The same-PID receipt is the sole superseded requirement. Public idempotence,
fresh authorization, exact owner DOWN, genuine native cleanup, original
filesystem identity, source immutability, fixed deadlines, two-task bound and
one-way dependency all remain explicit. The caller observes a companion result,
not just death, and a later no-op cannot retroactively prove a failed close.
Failure and cleanup-replacement paths have no success shortcut.

Architecture deliverable only; independent DESIGN SPEC/NEW distinct QUALITY
pending. Mix, SQL, services, runtime/native tests and E2E NOT RUN by this author;
E2E remains manual-deferred. Sol production counter received: 0; cumulative
Astra implementation repair rounds: 0, unchanged. No Vault feature change,
implementation, old-document edit, commit, publication or production action.
Parent owns test-first implementation, source reviews and final acceptance.
