# Phase 2 Document extraction source replay

Status: selected architecture under the owner's 2026-10-08 standing repository
approval. This is a bounded Task 8/12 amendment, not implementation evidence or
phase acceptance. The existing lifecycle integration failure remains recorded in
[the worker baseline](../../verification/2026-10-08-phase-2-worker-baseline.md).
Affected implementation/acceptance is stopped; this document does not authorize
silently repairing an outside-scope assertion. E2E remains prohibited.

## Problem and decision

Task 12 authenticates and hashes the entire original before claim, then extracts
from an in-memory buffer. The existing `:document_source` worker lease loads a
durable version-4 `document_source_v1` checkpoint. Each delivered chunk advances
its persisted next index. After process death the buffer disappears, while a new
lease resumes that index. A partial preclaim death leaves the Document pending,
so extraction-deadline recovery cannot solve this mismatch.

Add a fresh, sequential-only Document extraction worker lease using the existing
DownloadLease machinery. Each invocation starts at zero and rereads at most
64 MiB. Keep the old Document worker lease and its checkpoint behavior unchanged.

An incarnation-fenced checkpoint could be safe but adds unnecessary durable
protocol/CAS work for a whole-source in-memory consumer. Resetting/deleting v4
progress is rejected: old leases could collide with the reset index (ABA).
Durable plaintext caching, RequestRepo substitution, request impersonation, and
invented replacement job IDs are also rejected.

## Closed issuance contract

Add exactly one external request purpose:

```elixir
%{
  purpose: :document_extraction_source,
  access: :worker,
  job_id: envelope.job_id,
  resource_version_id: descriptor.resource_version_id,
  vault_id: envelope.vault_id,
  principal_id: envelope.principal_id,
  required_capability: "asset.read",
  principal_authorization_epoch: envelope.principal_authorization_epoch,
  vault_authorization_epoch: envelope.vault_authorization_epoch,
  object_id: descriptor.object_id,
  object_generation: descriptor.object_generation
}
```

Validate the exact atom-key set, UUIDs, epochs, capability, access and positive
object generation. Reject string/extra keys and caller-selected session, mode,
range, index or checkpoint. Malformed requests carrying this purpose must be
rejected before the generic lease fallback.

KeyCustodian selects an existing eligible session through `metadata_session/2`.
The caller never chooses it. Preserve current principal/owner/epoch, expiry,
revocation, unlock and object-key checks.

Construct the storage binding exactly as the current worker handler does:

```elixir
binding =
  request
  |> Map.take(@document_worker_fields)
  |> Map.put(:session_id, selected_session.session_id)
```

Purpose and lease mode must not enter this binding: CustodyRepository's exact-key
validation would reject them. Pass private `mode: :document_worker_source` and a
consumer PID derived from `GenServer.from` separately to lease startup. These
internal values are not authorization and never reach SQL or checkpoints.

## Fresh lease behavior

The new handler uses the existing `object_key` and authorization paths, but does
not load, initialize, persist, reset or delete a checkpoint. The new mode:

- starts at index zero for every lease;
- accepts sequential `read_document_chunk/2` and the empty-source authentication
  operation below only from its bound consumer;
- denies full/ranged reads, skipped/repeated/negative indices and concurrent reads;
- preserves the existing 60-second lifetime and before/after-chunk authorization;
- registers under the selected session for existing custodian revocation;
- monitors the consumer and cancels reads on consumer death;
- cancels its reader and terminates on revoke, expiry, custodian death or failure.

Runtime always revokes the lease in cleanup before external extraction begins.
The mode and consumer binding are immutable inside the lease.

### Empty originals and the authentication claim

For nonempty sources, authenticate every original plaintext data record, check
the exact complete plaintext length, and compare its SHA-256 with the immutable
canonical pin. Existing chunk/range reads do not authenticate the container's
final record. Do not claim complete nonempty-container authentication.

Zero expected data chunks must not mean zero storage operations. Add
`DownloadLease.authenticate_empty_document_source/1`, available only in the new
mode to its bound consumer with no pending call, index zero and a trusted loaded
`reader_context.object_binding.plaintext_byte_size` of zero. The caller supplies
no size assertion or range. Preserve before/after authorization, expiry,
revocation and reader lifetime handling. Internally use the unchanged
`key_reader.read_range(reader_context, binding, :all)` and require `{:ok, ""}`;
this authenticates the existing header and final AEAD record. On success return
`:ok`, consume/revoke and terminate the lease. On failure return a sanitized
error and terminate. Reject this operation for nonempty bindings or old modes.
Public `read(:all)` and ranged reads remain denied for the new mode.

Runtime must complete this operation before comparing the empty digest or
claiming. A hash of an in-memory empty binary alone proves neither the retained
object's existence nor its storage authentication. This special operation adds
no storage binding, CustodyReader method, checkpoint or raw-key access.

The existing DownloadLease read child uses `spawn_monitor`, so killing its parent
alone does not terminate that child. For the new mode only, lifetime-bind reader
and lease (for example linked+monitored with exit handling confined to this mode).
Normal cancellation must still kill and await the reader before returning.
Test arbitrary lease kill as well as ordinary revoke. Do not change ordinary
Asset download child lifecycle or existing request Document lease behavior.

The unchanged Document custody predicate continues to validate the retained
extraction event, selected live session, object/version/generation and authority.
Pending requires a live Document; matching unexpired claimed work may continue
after tombstone. Asset deletion does not revoke the retained original. Changed
authority/recovery fences subsequent reads, and the worker bridge independently
rechecks generation/job/deadline at claim and completion.

Concurrent fresh leases only reread immutable bytes. They confer no mutation
authority and share no mutable read checkpoint, so no new incarnation/CAS fence
is required for this selected design.

## Progress and unlock wake

Add only `put_progress_state(context, document_extract_envelope, state)` to the
planned DocumentWorkerRepository, restricted to `:running | :waiting_for_unlock`.
Use its trusted envelope-bound short WorkerRepo transaction and current authority.
Validate submission, owner and private classification binding before mutation.

For an absent progress row create the existing generic shape: version 1,
processing revision 0, empty checkpoint. On conflict lock/reload and validate the
existing row before updating only `state` and `updated_at`. Preserve checkpoint
version, processing revision and checkpoint JSON verbatim, including v4 rows.
Completed/failed rows must not reopen through a stale state update. No fifth
canonical SQL entrypoint or new worker grant is needed for existing job progress.

Record waiting before returning `{:snooze, 60}`, and running on resumed work.
Propagate a sanitized persistence error rather than claiming the wake state was
saved. Existing wake machinery only needs waiting state and continues using
generation counters in job submissions. Do not change GenericWorker, WakeHandshake
or generic Progress, and never use `Progress.put_state` to overwrite v4 data.

## Worker sequence and boundaries

Each invocation: authorize/describe, fresh lease and authenticated plaintext
(including the empty-source operation) plus full digest, claim/resume,
extract, then fenced outcome. A preclaim crash safely rereads from zero next time;
a postclaim retry rereads from zero without extending the original deadline.
Expired attempts remain the existing reconciler's responsibility. Terminal replay
returns the bounded receipt without acquiring a lease.

Descriptor/progress/claim/outcome transactions stay separate. No transaction spans
byte reads, hashing or extraction. No plaintext enters progress, logs, telemetry,
errors, outbox or Oban arguments.

## Exact additional file boundary and required evidence

Beyond the [worker bridge](2026-10-08-singularity-v0.2-phase-2-worker-bridge-proposal.md):

- Runtime `key_custodian.ex`: closed purpose and trusted session/startup metadata.
- Runtime `download_lease.ex`: private sequential-only worker mode and lifetime.
- Planned Runtime `documents/extract.ex`: fresh request and guaranteed cleanup.
- Planned storage `postgres/document_worker_repository.ex`: preserving progress update.
- Runtime tests `document_custody_test.exs`, `download_lease_test.exs`, and planned
  `document_extraction_job_test.exs`; planned storage worker repository tests.

Keep CustodyReader, CustodyRepository, SQL custody predicate, old KeyLease/v4
protocol, keys/capabilities, unlock/locking and Asset behavior unchanged. Existing
custody repository tests remain regressions, not permission to expand their scope.
Report both shared Runtime file changes explicitly. This is Document-only source
custody work, not Vault feature work or a Vault compatibility patch.

Required red/green contracts before implementation acceptance:

1. Real fresh leases reread from zero after partial/full reads; old v4 behavior
   remains unchanged, including pre-existing v4 progress.
   Real valid empty originals authenticate before claim; missing objects,
   corrupt headers/final records and nonempty bindings presented to the empty
   operation fail without claiming or invoking extraction.
2. Reject injected session/mode/range/index, missing unlock, forged binding and
   full/ranged/repeated/skipped/concurrent calls; reject a different consumer PID.
3. Consumer/reader death, lease kill, expiry and revocation terminate owned readers
   and release no late plaintext. Existing Asset/request lease regressions pass.
4. Real worker death before claim (partial and complete read) then restart yields
   identical whole-source digest; postclaim death resumes without deadline reset.
5. Integrity failure never claims; deletion/recovery/epoch changes fence reads and
   outcomes under actual WorkerRepo privileges without temporary grants.
6. Waiting/running transitions preserve v4 fields byte-for-byte, reject terminal
   reopening and integrate with existing unlock wake; no content leaks.

Architecture inspection was read-only; no implementation or tests establish these
new behaviors yet. Expand the Runtime implementation plan with exact executable
contracts before coding this extension. Full phase/release gates remain required.

Independent read-only design review found the original zero-chunk shortcut
unsafe. Source inspection confirmed the finding; the empty-source operation and
precise plaintext-versus-container claim above address it. The reviewer confirmed
this correction is within the bounded design. No production repair was made.
