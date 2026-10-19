# Phase 5 Task16 Companion Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development`
> (recommended) or `executing-plans` task-by-task. Parent assigns exclusive
> ownership, closes writers before execution and owns the native validation lane.

**Goal:** Remove an established operation's owned envelope after companion hard
death, while preserving actual owner-DOWN-before-deletion ordering.

**Architecture:** The surviving owner confirms old companion DOWN and starts
one cleanup-only temporary replacement under the same Task.Supervisor. The
replacement monitors the owner before readiness; the owner exits; the
replacement waits for owner DOWN and calls existing ArtifactDirectory cleanup.

**Tech Stack:** Existing Elixir/OTP tasks, monitors, ArtifactDirectory and native
export-request leases. No dependency, migration, supervisor or public API addition.

---

## Authority, prerequisites and ownership

Read the [forward design](../specs/2026-10-19-singularity-v0.2-phase-5-export-companion-recovery-design.md),
[original Task16 plan](2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership.md)
and [acyclic composition plan](2026-10-19-singularity-v0.2-phase-5-export-acyclic-composition.md).
This supplements original Steps3–4/8; it does not replace the materialization,
native custody, startup, attribution or phase acceptance requirements.

Worktree `.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`, inspected HEAD
`65416569cbf5adffa8e5733900e29a2cf40c5161`. Native prerequisite and acyclic
composition design have their own recorded evidence; neither accepts this
recovery implementation. Preserve other authors' in-progress tests and all
historical candidate manifests, raw logs, failures and inverse baselines.

- [ ] Parent reads both complete documents and obtains independent DESIGN SPEC
  followed by NEW distinct DESIGN QUALITY before affected production edits.
- [ ] Parent records current source/doc hashes and exclusive ownership. Do not
  overlap writers in Artifact or either test file; native execution remains
  serial and parent-owned. Routine human reapproval is not required.

| Owner | Exact paths and responsibility |
| --- | --- |
| Artifact implementation author | `apps/singularity_runtime/lib/singularity/runtime/knowledge/export_artifact.ex`: loss detection, terminal handoff and private cleanup-only task |
| Lifecycle test author, before production writer | `apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs`: additive generation/completed-owner recovery, ordering/failure and bootstrap witnesses |
| Native test author, exclusive separate window | `apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs`: preserve prior cases; additive genuine native composition where its fixture is required |
| Architecture test author | `apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs`: exact recovery state/data-flow/order contracts and negative mutations, preserving accepted acyclic checks |
| Parent | Full reads, gates, source SPEC then NEW distinct QUALITY, new candidate pins, documentation status and explicit local commits |

No edit to Export, ArtifactDirectory, Writer, Spool, Snapshot, ExportRead,
OperationScope, native custody, Api/config/application blocks, frozen tests or
old design documents is needed for this amendment. A proven conflict returns
to the parent for bounded design disposition, not an unapproved workaround.

## Task A: capture the failure and strict recovery assertions

**Files:** the two runtime test owners above, in separately assigned windows.

- [ ] Retain existing genuine native failures and labels. Add a case that
  completes real export composition, exits the generating requester, then
  hard-kills the exact companion. Require the owner to terminate and its actual
  envelope to disappear without calling test scavenging or emergency cleanup.
  Independently preserve a second live export and foreign root sentinels.
- [ ] During generation use existing delegated repository/native barriers to
  know the owner/companion before fault injection. Cover acquisition/pre-record,
  recorded/pre-forward and known-forwarded native lease states. Retain actual
  public native read denial and reader/lease cleanup assertions; process DOWN
  or synthetic authority alone is insufficient.
- [ ] Use this concrete assertion sequence in the new recovery cases. Variables
  come from the real operation fixture and control-message witness described
  below; none is supplied to a production cleanup hook.

```elixir
owner_monitor = Process.monitor(owner)
companion_monitor = Process.monitor(companion)
Process.exit(companion, :kill)
assert_receive {:DOWN, ^companion_monitor, :process, ^companion, :killed}, 5_000

# Release the known repository/native barrier if this case blocks the owner.
# The fixed readiness witness identifies the actual cleanup replacement.
assert_receive {:cleanup_ready_witness, ^test_ref, ^owner, replacement}, 5_000
replacement_monitor = Process.monitor(replacement)
assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 5_000
assert_receive {:DOWN, ^replacement_monitor, :process, ^replacement, reason}, 5_000
assert reason in [:normal, :noproc]
assert {:error, :enoent} = File.lstat(envelope.path)
assert File.read!(foreign_sentinel) == foreign_bytes
refute_receive {:export_result, ^test_ref, {:ok, _}}
```

  A `:noproc` monitor result means the test attached after task termination;
  report that limitation rather than claiming its exit reason was observed.
  Actual filesystem absence is still required. A wrong or never-observed
  replacement identity is not repaired by searching all processes.

- [ ] Implement the witness only in the test file. Attach a test-owned tracer
  to the already-known owner PID with receive tracing before releasing its
  barrier. Correlate the fixed `export_cleanup_ready` tuple with the successful
  supervisor start-result PID received by that same terminal owner; handle
  either arrival order. Report the exact owner and matching PID with `test_ref`.
  Retain only control references/PIDs, never callback or runtime payloads.
  A tag-shaped or deliberately forged readiness message alone is not a witness.
  Discard other trace events without formatting or retaining their payloads.
  Do not use `:all`, `:new_processes`, native supervisor enumeration or `:sys`.
  Remove this exact trace registration and stop the tracer in `on_exit` even
  on failure. The trace observes a protocol message; it is not a barrier and
  must not be used to race a suspension against subsequent owner execution.
- [ ] Keep an explicit separate case where the owner is held at an existing
  real callback barrier when companion loss occurs. Before releasing the owner,
  the envelope must still exist and contain the previously observed sentinel.
  After release, require replacement completion and actual removal. Label this
  as blocked-owner behavior, not proof that arbitrary callbacks are interruptible.
- [ ] Parent runs the whole artifact pure owner and whole integration owner
  using Task F commands. Record the actual missing behavior/failure and each
  command's own residual check. A compiler/helper failure is not causal RED.

## Task B: specify recovery data flow and negative source contracts

**File:** `apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs`.

- [ ] Parse executable AST and retain all existing acyclic composition checks.
  Add a contract that recognizes the exact fixed context and the helper order
  shown in Task C. It must reject each of these mutations independently:

```elixir
@recovery_mutations [
  :spawn_before_companion_down,
  :accept_exit_without_matching_down,
  :ready_before_owner_monitor,
  :accept_wrong_operation_ref,
  :accept_wrong_recovery_ref,
  :accept_wrong_replacement_pid,
  :delete_before_owner_down,
  :monitor_different_owner,
  :cleanup_reconstructed_path,
  :pass_work_or_runtime,
  :link_replacement_to_owner,
  :restart_replacement,
  :retry_replacement_on_failure,
  :return_to_delivery_after_recovery,
  :ignore_supervisor_shutdown,
  :report_cleanup_error_as_success
]
```

  These atom names identify test-owned AST transformations; they are not
  production options. Each transformation changes the parsed actual candidate
  source once, then requires the contract to reject it. Verify every transform
  found its intended node; missing source must fail, not be skipped.
- [ ] Assert cleanup context has exactly four keys and contains the unchanged
  trusted envelope, not a Handle-derived path. Assert no recovery helper calls
  Writer, acquires leases, invokes work, calls Export, scans roots or looks up
  caller-selected functions. This is source evidence, not live recovery proof.
- [ ] Parent runs the whole architecture owner RED before production changes.
  Keep this source RED separate from runtime/native counts.

## Task C: implement the one-shot owner handoff

**File:** `apps/singularity_runtime/lib/singularity/runtime/knowledge/export_artifact.ex`.

- [ ] Install owner exit trapping before companion linkage/work. Store the
  exact companion monitor, owner envelope and existing task-supervisor identity.
  On matching companion loss transition irreversibly to recovery; confirm
  exact DOWN before the following handoff. Retain supervisor EXIT handling.
- [ ] Construct only this context and fixed task launch, using the actual owner
  state fields rather than values obtained from a request or Handle:

```elixir
cleanup_context = %{
  owner: self(),
  operation_ref: state.operation_ref,
  recovery_ref: make_ref(),
  envelope: state.envelope
}

Task.Supervisor.start_child(state.task_supervisor, fn ->
  cleanup_replacement(cleanup_context)
end)
```

  Encapsulate that call in `start_cleanup_replacement/2`, catching supervisor
  call exits into the existing sanitized storage-unavailable failure. Use the
  default temporary task and existing shutdown policy. Do not add a retry,
  replacement supervisor, `Task.async`, task-owner link or configurable function.
- [ ] On `{:ok, replacement}`, monitor that exact PID and await the fixed tuple
  matching operation reference, fresh recovery reference and PID. Other
  readiness/EXIT/DOWN messages cannot count as readiness or restart recovery.
  On readiness exit with `{:shutdown, :export_companion_lost}`. On replacement
  DOWN before readiness exit with `{:shutdown, :export_cleanup_unavailable}`.
  These reasons contain no path, body, runtime, session or exception term.
- [ ] On start failure/unknown result or observed supervisor shutdown, terminate
  fail-closed and do not report cleanup completed. Do not restart generation,
  remain in the completed receipt loop, or perform owner-side envelope deletion.
  Keep the original operation deadline; recovery grants no data-access time.
- [ ] Integrate loss checks at actual materialization return, final acceptance
  and content-response boundaries. Drain matching cancellation/loss and check
  companion liveness before successful replies. Existing native authorization,
  COMMIT ordering and original fixed work/2 invocation remain unchanged.
  Run terminal recovery outside generic exception wrappers so its shutdown
  exit cannot be caught and converted into another owner-loop iteration.

## Task D: implement cleanup only after exact owner DOWN

**File:** the same Artifact source, owned by the same author as Task C.

- [ ] Implement the fixed replacement body with this ordering and exact context:

```elixir
defp cleanup_replacement(%{
       owner: owner,
       operation_ref: operation_ref,
       recovery_ref: recovery_ref,
       envelope: envelope
     }) do
  owner_monitor = Process.monitor(owner)
  send(owner, {:export_cleanup_ready, operation_ref, recovery_ref, self()})

  receive do
    {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
      case ArtifactDirectory.cleanup(envelope) do
        :ok -> :ok
        {:error, %Error{}} -> exit({:shutdown, :export_cleanup_failed})
      end
  end
end
```

  The sole caller constructs the exact four-key map in Task C. Preserve that
  exact-key source contract; do not add a general public cleanup entry point.
  Do not catch a cleanup failure and return `:ok`. The existing cleanup API
  sanitizes its exceptions and identity failures; raw terms do not escape.
- [ ] Do not introduce timeout-driven deletion. An elapsed original deadline
  does not mean the owner has stopped. Do not call Writer.abort here: the
  replacement has no ledger and uses only the original envelope identity.
- [ ] Leave replacement shutdown linked to the existing task supervisor. It
  does not trap shutdown to extend its lifetime, restart, create successors,
  or act as a new native lease owner.
- [ ] Parent reruns the complete artifact pure/integration and architecture
  owners GREEN after the author closes. Diagnose any failure without weakening
  assertions; cumulative Sol/Astra recovery counters retain their prior values.

## Task E: failure, bootstrap and shutdown qualification

**Files:** runtime artifact/native tests and the composition architecture test,
in exclusive parent-assigned windows.

- [ ] Queue malformed/wrong-ref/wrong-PID readiness and duplicate companion
  notifications while an existing owner barrier holds it. Require actual
  accepted readiness from the one replacement and no successful delivery.
  Source mutations independently reject removal of each match/terminal guard.
  Do not describe a wrong-message runtime case as proof of an unobserved race.
- [ ] Test actual replacement-start failure using a dedicated test task
  supervisor with `max_children: 2`: owner and companion initially occupy it.
  Hold owner at its existing callback barrier, kill/observe companion DOWN,
  then use `Task.Supervisor.terminate_child(supervisor, companion)` as a
  supported registration fence for that already-dead exact child. Admit one
  test sentinel task into the freed slot before releasing the owner. The real
  recovery start must fail at capacity; require fail-closed owner termination,
  no false cleanup success and intact sentinel. This fixture changes no
  production supervisor policy and does not enumerate native leases.
- [ ] Test identity conflict by replacing the owned marker or operation entry
  using the existing isolated filesystem fixture while the owner is held.
  Trigger companion loss, release owner, observe recovery termination and
  require the foreign replacement to remain. Cleanup failure is the expected
  rejection for that deliberately invalid identity, never a successful removal.
- [ ] Test shutdown through the actual isolated Task.Supervisor. Require no
  recovery start after owner observes its supervisor shutdown. Preserve default
  shutdown behavior and record any residue for the separate startup gate.
  Do not increase shutdown timeouts to make the test pass.
- [ ] Preserve independent export/ordinary native sentinels in each genuine
  native loss case. Assert actual native public read denial for the affected
  lease and actual retained usability for the unaffected lease, separately from
  task monitors and filesystem assertions.
- [ ] Characterize companion loss before owner/envelope handoff. Use an existing
  mandatory bootstrap deadline check immediately after envelope creation as a
  PID-targeted operation-clock barrier, paired with a source-order assertion;
  do not add an observer configuration or a clock call solely for the test.
  Assert no Snapshot/Writer producer started and no Handle/data was returned.
  Record the actual recognized or partial envelope residue. If the implementation
  has no such existing transition check, return this witness arrangement to the
  parent rather than guessing from scheduler timing.
- [ ] After all fixture runtime tasks/supervisors are actually gone, run the
  original guarded startup path separately. A valid recognized orphan may be
  removed; a partial/unrecognized marker must remain. Label this STARTUP
  RECOVERY, never immediate companion cleanup. No test scavenging call may
  satisfy the post-owner single-fault assertions from Task A.
- [ ] Keep double-hard-kill before registration, independent replacement death,
  unavailable supervisor and VM loss as explicit recovery limits. Do not claim
  all such faults were executed if only source/failure-path checks were run.
  Any still-required immediate-bootstrap obligation remains an unresolved
  acceptance item for parent disposition; it is not waived by this plan.

## Task F: parent whole-owner gates, review and local handoff

Close all writers before execution. Parent uses the qualified private-PG
wrapper, fresh raw PTY output and each invocation's immediate own ordinary
residual check. Keep exact argv/exits/counts, source pins and log hashes. No
simultaneous author VM/SQL/service commands. Commands below are payloads inside
that established environment; they do not authorize another environment.

```sh
mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_web/test/singularity/architecture/knowledge_export_composition_contract_test.exs --seed 215378 --warnings-as-errors
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs --seed 215378 --warnings-as-errors
mix test apps/singularity_storage/test/singularity/storage/knowledge_export/artifact_directory_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/writer_test.exs apps/singularity_storage/test/singularity/storage/knowledge_export/spool_test.exs --seed 215378 --warnings-as-errors
mix format --check-formatted
mix compile --warnings-as-errors
mix xref graph --format cycles --fail-above 0
git diff --check
```

- [ ] Require all applicable whole-owner checks to pass. Report pure/integration
  execution and exclusions separately; an excluded native case is NOT RUN.
  Source contracts and pure synthetic authority do not prove native cleanup.
- [ ] Run retained original Task16 Step8/acyclic-plan gates and exact attribution
  owners as required by the full changed source. Preserve old native56 inverses,
  Task8/native-text layers, seven applications and unfiltered zero-cycle gate.
- [ ] Obtain independent source SPEC then NEW distinct source QUALITY on the
  complete affected source/tests and actual logs. Required review focus:
  trapping without continued delivery, confirmed old DOWN before spawn,
  readiness monitor/ref/PID ordering, exact owner DOWN before cleanup, no
  duplicate actor, no lost identity and honest failure/bootstrap limits.
- [ ] Parent records actual source, changed files, commands, findings and residual
  obligations, then makes only explicitly scoped local commits. Full Task16
  acceptance still needs every original applicable requirement; Phase5 needs
  the complete permitted README gate. E2E stays NOT RUN/manual-deferred.
  Do not mark the release goal complete at this recovery component boundary.

## Author self-review and evidence boundary

Design requirements map to Task A (strict failures/live evidence), B (source
counterproofs), C/D (handoff and cleanup), E (limits/bootstrap/shutdown) and F
(whole gates/reviews). Context keys, message tags and helper names agree across
the documents. No source change or native execution is claimed. The author
reads both complete files and checks their scoped whitespace and hashes before
handing them back; independent review remains the parent's next step.
