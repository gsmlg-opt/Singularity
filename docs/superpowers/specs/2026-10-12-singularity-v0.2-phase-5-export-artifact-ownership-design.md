# Phase 5 Task 16: authenticated export artifact ownership

## Status and authority

### Dated native lifecycle exception — 2026-10-19

The user explicitly approved the minimal KeyCustodian/DownloadLease native
export-request ownership exception. The [new design](2026-10-19-singularity-v0.2-phase-5-export-lease-ownership-design.md)
and [plan](../plans/2026-10-19-singularity-v0.2-phase-5-export-lease-ownership.md)
supersede this document's frozen-interface/source-NO-GO wording only for that
prerequisite after actual DESIGN SPEC then NEW distinct QUALITY closure. They
do not waive either strict ALL-lease assertion or qualify any native behavior.
The historical BLOCKED_DESIGN/failed-review records below remain intact. All
startup, Task8 exact inverse, authority, source, handle and artifact contracts
remain unchanged. The eventual companion adapter uses `export_lease/2` through
the existing injected acquisition seam. Native prerequisite qualification is
not Task16 acceptance. Ordinary requests, workers and other Vault behavior stay
frozen; E2E NOT RUN and publication/production restrictions remain in force.

### Historical architecture and review records

Architecture assignment `phase5_artifact_ownership_architecture`, mode
`architecture`, gate `PROJECT_ARCHITECTURE`. This is a design and implementation
plan, not an implementation, prerequisite acceptance, or implementation GO.
The parent must review this design and independently resolve both strict
`BLOCKED_DESIGN` lease findings below before accepting their cleanup guarantees.
Other Phase 5 work remains independent of those findings.

Worktree: `.trees/v0.2-phase-5-export-backup`; branch:
`codex/v0.2-phase-5-export-backup`; inspected HEAD:
`09f8ee0c0a69cdd26612e0663a29a9d156c46986`. The worktree already contains parent
and Sol changes for Tasks 13–15 and earlier repairs. Those changes are preserved.
No implementation, formatter, Mix, SQL, service, Git mutation, or native probe
was performed for this architecture assignment.

Governing requirements are the Phase 5 design
`2026-10-11-singularity-v0.2-phase-5-export-backup-design.md`, especially §§3–5,
and Task 16 of `2026-10-11-singularity-v0.2-phase-5-export-backup.md`.
The companion detailed plan is
`../plans/2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership.md`.
Continuing local-development authority selects the recommended in-scope design
without another routine human approval. It does not accept unrun checks.

2026-10-13 startup-only architecture amendment inspected HEAD
`4e2499d5b89664c3e7b63cb1f3136c243b276c83`. Historical actual nonauthor
DESIGN_SOURCE_SPEC disposition was PASS WITH UNSATISFIED BOUNDARIES, including
the companion-death P2 below. Distinct fresh DESIGN QUALITY then found the
startup P2: the proposed absence-check/scavenge call returned before native
`Application.start/2` called `Supervisor.start_link/2` at application.ex:37–40.
Two starters could observe absence and the delayed starter delete the first
starter's live recognized artifact. This is source-inferred, runtime NOT RUN.
The reviewed pre-amendment receipts remain historical: design SHA-256
`82a35ebd586613d673d01c605738abb5b292a285ea14d8aeb4acd2a1cedcc33b`;
plan SHA-256 `7d28f42cbd8d57a7e2b6ddbd112a4a817fd8ce6798d1e51b971521f343ffef39`.
The bounded amendment below needs actual nonauthor design review and fresh
QUALITY. Neither documentary repair nor review supplies Task16 source/test GO:
both strict ALL-outstanding-lease guarantees remain UNSATISFIED, UNWAIVED and
BLOCKED_DESIGN until genuinely addressed. Independent valid Task9/15 continues.

2026-10-13 Task8 attribution amendment, assignment
`phase5_task16_task8_attribution_design_repair`, mode `architecture`, explicit
parent gate `PROJECT_ARCHITECTURE`, inspected HEAD unchanged at `4e2499d5…`:
actual nonauthor SPEC of the startup
amendment FAILED one P2. Its reviewed design/plan SHA-256 receipts were
`b162cd513c50abaf578f3e0773759dd9b5d17ccb854f6852c8ecda5f6c0c9b2b` /
`1a93e20f71cda105de97d5cef59c365edffdd6add0727f1d58fcc4e31bd1efb3`.
The startup inverse recovers current Application, but current Application also
contains two accepted Task8 changes missing from the historical attribution
pipeline. This bounded PROJECT_ARCHITECTURE repair adds their separate exact
test-contract prerequisite; it changes no Task8 source or startup proposal.
The historical FAIL remains evidence. This repair1 subsequently received actual
nonauthor DESIGN SPEC FAIL/P2, recorded below. Task16 source/test GO remains
CLOSED, and neither strict lease guarantee is satisfied or waived.

2026-10-13 positive-witness input-stage design repair2, assignment
`phase5_task16_positive_witness_design_repair`, inspected HEAD
`2a7873b8e40ca7aebd27a32de54fdf49ab3cf933`: actual independent repair1 DESIGN
SPEC FAILED one P2. Exact reviewed receipts were design
`496dffbf17a44a13aa4c9908c791fe875563a2796eb0b783d7cf4babbc4a8559` and plan
`5dffa0cdd26b4554c16d4a82a765c157d52c9c53843b30141cf4d83121067486`;
the parent archived that review in
`.devenv/phase5-task16-attribution-design-repair1-spec.md`.
Step7b replaced only `normalize_phase5!/2`, but the accepted positive witness
at architecture-test lines 1201–1214 reads raw Application and directly calls
`undo_phase5_task8!/2` twice, bypassing that outer normalizer. On proposed P5-A5
bytes `f562d82432fea2ec50e5599c780634deccb9266fc0b729525699b457f582bd39`,
Task8-only inversion leaves the startup replacement, producing
`e4bfadb63a5b6033b42214a499dc238772f9afd42b4e980c189fec850366e1e1`
instead of the fixed pre-Task8 digest. The independent review found that strict
P5-A5 inversion before Task8 inversion recovers the actual parent byte-for-byte;
this is read-only calculation evidence, not an executed test.
Repair2 below explicitly stages that positive input through the existing strict
Task16-only helper after its raw Task8 tuple checks, preserving both fixed digest
and historical-baseline assertions. Seven additions, all startup literals/hashes,
Task8 tuples/source and causal negative routes remain unchanged. Documentary
repair2 received actual corrected DESIGN SPEC PASS and a NEW distinct fresh
DESIGN QUALITY PASS, both without actionable P1/P2, on the exact reviewed design
`58a9cc42b98d59c648d2168c8a048855c8120ca720ef359efffa5207be63fce0`
and plan `80fdebe81db0b35acc51390a524e9122257e8704bc591fad77e96734c8f56081`.
Those reviewed copies and parent records are archived under
`.devenv/phase5-task16-attribution-design-repair2-reviewed-{design,plan}.md`,
`...-spec.md` and `...-fresh-quality.md`. This later status metadata is not
retroactive review. Neither documentary verdict nor the input-stage correction
supplies source/test GO or qualifies either lease promise.

Seven applications, PostgreSQL ownership, Ecto/Oban boundaries, and the existing
source-proof contracts remain settled. No dependency, domain GenServer, durable
queue, cache, global handle registry, capability, Vault grant, custody policy,
lease protocol, key, cryptography, migration, or production-write activation
change is included. E2E remains manual-only and NOT RUN. No merge, push, version,
tag, release, deployment, activation, backfill, or production data operation.

## Source evidence and the ownership problem

Paths are relative to the worktree. In the source tables, `runtime/` abbreviates
`apps/singularity_runtime/lib/singularity/runtime/`, and `storage/` abbreviates
`apps/singularity_storage/lib/singularity/storage/`.

| Actual source edge | Consequence |
| --- | --- |
| `apps/singularity_runtime/lib/singularity/runtime/api.ex`: `production_config/0`, `production_runtime/0`, `session_context/1`, `invoke/3` | Add the four facade operations through existing trusted leading-config and production callback conventions. A DTO is an identity hint, not live authority. |
| `runtime/authorize.ex`: `check/4`, `load_session/3`, `check_session_binding/2`, `check_unlock/3` | Native checks reload session, membership, revocation, capabilities, both epochs and custody unlock state. Reuse them unchanged. |
| `runtime/operation_scope.ex`: `with_shared_request/4`, `finish_transaction/6`, `run_after_commit/5` | Native shared vault/authorization locks can cover a bounded delivery callback after its SQL transaction commits. |
| `runtime/knowledge/export_snapshot.ex: capture/4`, `capture_scoped/4`, `transact/4` | Snapshot already refuses an outer transaction and returns its sealed descriptor only after the real scoped COMMIT. |
| `storage/knowledge_export/spool.ex: open/1`, `reduce_metadata/4`, `read_chunk/3`, `abort/1` | Capture metadata/text is private, bounded and identity checked. The descriptor has atomics and a creation deadline; it is not a public handle. No startup scavenger exists here. |
| `storage/knowledge_export/writer.ex: open/1` | The calling process creates an unnamed `:ets.new(__MODULE__, [:set, :public])` ledger. Public ETS access supports trusted concurrent cancellation; it does not detach table lifetime from its creator. |
| `Writer.identity_valid!/1`, `mutate/2`, `deliver/2`, `publish!/1` | Every delivery needs the live ledger's exact binding and phase. Completed descriptors retain `_ledger`, `_phase`, `_identity`, deadline, output digests and chunk indexes. Merely passing a descriptor to another process cannot preserve the ledger after its creator dies. |
| `Writer.abort/1`, `alive!/1`, `with_device!/3` | Aborting `@busy` sets cancellation; the active call owns its open descriptor and performs cleanup as it unwinds. A monitor message queued in that same busy process cannot interrupt it. |
| `Writer.write_manifest!/1`, `entries/2`, `read_chunk/3` | Pages contain at most 500 descriptors and chunks at most 65,536 bytes. `manifest.json` is registered after writing the manifest's content-file list: it is a bootstrap entry, not a self-checksummed member of that list. |
| `runtime/application.ex: infrastructure_children/1` | `start_infrastructure: true` always starts `UploadRecoveryTaskSupervisor`; false starts no infrastructure. Its name is historical, but it is an ordinary Task.Supervisor. Do not use custody/upload session supervisors for export. |

Source fingerprints recorded during inspection, before this document was written:

| File suffix | Raw SHA-256 |
| --- | --- |
| `runtime/api.ex` | `6212a126be413c4b19bc0e24e8cc3c86f1e8ce776ebd2e8a7427ee2e2695fda1` |
| `runtime/application.ex` | `3ce2dad60cb851170ad295cf6a37024d192351fc6cf420e9401694fb7cacbe4c` |
| `runtime/authorize.ex` | `e00bf92fef6e5b8e5dea16b10d9c6e035aa824b3934ef59caf474364c7566ce9` |
| `runtime/operation_scope.ex` | `458c9fad4b48bed99e39e02611ab38f137a185d2db966bdf23f0bca158f0fde6` |
| `runtime/knowledge/export_snapshot.ex` | `c5a03af6b2b84c1d136869d6db5db81a999ab964aa6ff6e7952c3a609c643563` |
| `runtime/knowledge/export_read.ex` | `9e7e20f235345627eee93a824b0b652a2b8cd582e657f9f92cc2a4716c00a091` |
| `storage/knowledge_export/spool.ex` | `2d6dfb4e10b78a4ac27e0e868a6f33326e746c96a309a4d5a833511f63f18556` |
| `storage/knowledge_export/writer.ex` | `b119b7525cce36b5af52b8a70b624c725db5792f9bbc76f9b7c70dc19d3c11d9` |

These identify inspected source; they are not replacements for historical
architecture baseline hashes or assertions that Tasks 14/15 have passed.

## Alternatives and selected boundary

1. **Recommended: eventual owner plus operation-local companion.** Two temporary
   tasks reuse `UploadRecoveryTaskSupervisor`. The owner creates and materializes
   Writer, then remains its ledger owner during delivery. The companion handles
   requester/owner death and deadline independently while the owner performs
   blocking work, subject to the native-call limitation below. The extra process
   is necessary cancellation infrastructure,
   not a domain entity or global registry.
2. **Request-owned generation followed by ETS handoff.** This requires a new
   trusted Writer ownership-transfer API, an ETS transfer acknowledgement and
   recovery for death on each side of that acknowledgement. It adds races and
   changes a qualified storage interface. Passing a map alone is invalid.
3. **One owner task with a mailbox cancellation check.** This preserves ETS
   lifetime but leaves cancellation pending during native reads and Writer
   folds. Accepting only eventual mailbox handling would not meet the required
   requester-death behavior.

`Knowledge.Export` is plain orchestration and validation. `Knowledge.ExportArtifact`
owns temporary process lifetimes, private handle routing, cancellation and
native lease bookkeeping. `Storage.KnowledgeExport.ArtifactDirectory` owns the
private filesystem envelope and recognition rules. Domain modules remain pure.

## Public interface and trust boundary

Exactly these operations and existing-style leading-config variants are added:

```elixir
Api.export_knowledge(session, %{include_tombstones: false})
Api.knowledge_export_entries(session, handle, cursor)
Api.read_knowledge_export_chunk(session, handle, path, index)
Api.close_knowledge_export(session, handle)
```

`%{}` means `include_tombstones: false`; unknown keys, structs, caller-selected
owner, destination, root, adapters, clocks and limits are rejected. No new /1
convenience operation or generic dispatch API is introduced. Chunk index is a
nonnegative integer ordinal, never a byte range. Paths must be normalized
relative paths with no empty, dot, parent, backslash or NUL components. The
owner admits only the verified bootstrap `manifest.json` and content paths in
its completed manifest. Writer remains the exact membership/checksum authority.

Success is `{:ok, opaque_handle}`, `{:ok, %{entries: entries, next_cursor: cursor}}`,
`{:ok, bytes}`, or `:ok` respectively. Descriptors have exactly string keys
`path`, `media_type`, `byte_size`, `sha256`. Pages contain at most 500 entries;
chunks contain at most 65,536 bytes, including the single valid empty-file
ordinal 0. No host path, Writer/Spool descriptor, lease, key or runtime map is
returned. Errors use existing sanitized `Error` values internally and stable
atoms at Api.

The handle is an opaque BEAM struct defined inside `export_artifact.ex`, with
owner PID, unforgeable operation reference, original identity/epoch binding and
monotonic deadline. Its Inspect implementation emits only `#KnowledgeExport<opaque>`;
it has no JSON encoder and is never logged or included in telemetry. These
fields are routing/binding evidence, not authority. A live owner verifies its
stored reference and binding, and native authority is checked on every use.
Altering handle fields never creates authority. After an owner is gone, close
may return `:ok` only as a no-op after current authentication and matching the
handle's original identity hints; it cannot read data, target a path, or close
another live operation. Foreign-session use of an intact handle is denied.

## Lifetime and protocol

1. `Export.run/3` validates options and a strict SessionContext, then performs
   native live authorization for sorted existing capabilities
   `["asset.read", "note.read"]`, private classification and unlocked state.
2. `ExportArtifact.generate/3` records one monotonic creation time and starts a
   companion under the existing task supervisor. The companion monitors the
   generating requester before starting work, creates an exclusive owned
   envelope, and starts the eventual artifact owner. The companion owns the
   envelope's cleanup identity before the owner can write content.
3. The owner opens Spool inside that envelope, captures the snapshot, observes
   actual COMMIT, and only then opens Writer and performs binary materialization.
   Writer ETS is created by this owner and never transferred. The companion
   receives the initial Writer descriptor solely for trusted `Writer.abort/1`;
   its atomics/ledger identity remain valid across generation updates.
4. The owner finishes all files and exact-source completion revalidation. In a
   final shared native authorization scope it returns an `:after_commit`
   callback that sends `{:export_prepared, operation_ref, owner_pid}` to the
   companion and awaits the matching acceptance reply.
5. The companion rejects preparation if requester DOWN/cancel/deadline has won.
   Otherwise it checks requester liveness, removes the generation monitor with
   `Process.demonitor(ref, [:flush])`, marks the operation delivered, and sends
   `{:export_accepted, operation_ref}`. This is the completion linearization
   point. The owner can now reply with the verified handle. Death before this
   point aborts; death after it is ordinary request completion and cannot remove
   the artifact. No later code recreates a requester monitor.
6. The owner serializes entries, chunks and close. Each content response runs
   through `OperationScope.with_shared_request/4` with the original identity and
   epoch binding and an `{:after_commit, callback}`. Writer reads execute in that
   callback, while shared authorization/vault locks remain held, with no SQL
   transaction open. Handle possession and stale DTO `unlocked?` are insufficient.
7. A fixed internal 1,000 ms idle authority tick checks an unused completed
   artifact for session revocation/unlock loss. Every actual delivery checks
   authority regardless of the tick. Tests advance a trusted monotonic clock
   and send a matching internal tick message; they do not sleep. No public timer
   or expiry option exists.
8. The companion enforces `created_at + 900_000` independently of a later Spool
   open. Effective lifetime is the earlier of that deadline and Spool's native
   deadline; finish, reads and close never extend it. Deadline checking occurs
   before and after work and at protocol transitions, not only on a timer.

Private messages include the operation reference and expected sender/owner PID:
`export_prepared`, `export_accepted`, `export_cancel`, `export_writer`,
`export_lease`, `export_lease_retired`, `export_closed`, and `export_tick`.
Unexpected messages never invoke an arbitrary function/module. Monitor refs
are matched exactly; replies use a per-call reference and a monitored caller.
No message contains user body/title/label data or plaintext chunks except the
direct requested delivery reply.

An invalid foreign caller must not be able to destroy the owning session's
artifact. Malformed requests rejected before admission do not mutate it. An
admitted owning-session authorization/read/checksum failure closes delivery and
starts cleanup. Close is idempotent; a live closed owner retains only a minimal
receipt until the original deadline and rejects entries/chunks. A dead owner
cannot be restarted to resurrect its ledger or plaintext.

## Materialization and exact source selection

Use actual `ExportSnapshot`, `Spool`, `ExportRead`, `Repository` and `Writer`.
No public adapter chooses a source or grants authority. Metadata is reduced one
record at a time in the fixed eight-collection order; do not use a full-export
`Enum.to_list`, eager JSON object or list of bodies. Preserve all existing
record, selected-key, spool, original, output and 15-minute limits.

Append metadata first, then originals, then fragments in version/ordinal order,
then Note Markdown. For each original, Writer's fixed `original_fold/3` selects
the exact sealed binding and invokes `ExportRead.asset/3` or `document/3`, then
the descriptor's `reduce/2` callback. Text remains the exact sealed Spool bytes;
`ExportRead.note/3` and `fragment/3` validate the immutable live binding before
Writer consumes them; their existing exact-source guards are repeated at
completion. Writer's existing portable Note rendering and checksums remain
unchanged.

One bounded repository addition is necessary. Captured Document records do not
contain the source Asset version key; Spool binary refs are keyed by that Asset
version. Add `Repository.document_source_selector(repo, version)` to load the
already-existing immutable Document source pair under authenticated owner/RLS,
verify the selected Document version, original digest and byte size, and return
`{:binary_binding, :asset, source_resource_id, source_version_id}`. Export must
then fetch that exact key from the sealed capture, decode its individually
bounded binding, and pass `%{version: version, source: source}` through existing
`ExportRead.document/3` and `Repository.document_source/2`. Missing/changed pairs
fail; do not try every Asset binding or follow a new head. This is a read-only
composition helper, not a new source-selection contract or schema change.

Before completion, repeat the existing exact binding guards for every selected
live original and text version. Compare the same immutable identifiers/digests
and captured state, not current head membership. No new binary materialization
starts inside the metadata snapshot transaction. Native per-source scoped reads
remain bounded; no whole-transfer or client-delivery transaction is introduced.

## Native lease path and the limited blocked guarantee

Actual path for Asset: `ExportRead.asset_pass/5` →
`Assets.Download.run/4` → `Download.read_object/6` →
`runtime.custodian.lease(request)` → `KeyCustodian.handle_call/3` for
`purpose: :download` → `start_download_lease/5` →
`DownloadLease.read/2`. Document uses `ExportRead.document_pass/5`, a
`purpose: :document_source, access: :request` request, then
`DownloadLease.read_document_chunk/2` or
`authenticate_empty_document_original/1`, and explicit `revoke/1` in `after`.

`key_custodian.ex:814` and `:925` ignore `_from` for these two request cases;
`start_download_lease/5` supplies no consumer PID or worker mode. In
`download_lease.ex:178`, caller equality belongs only to
`:document_worker_source`. The request Document clause at `:216` enforces
sequence/live binding but not an acquisition-caller PID. `revoke/1` uses the
existing synchronous native call that clears custody and stops its in-flight
reader. The one-use Asset read normally terminates its own lease; request
Document revocation may erase custody while leaving an inert lease process.
Tests must check native revoked behavior, not assume every revoked PID exits.

A fixed, private `ExportArtifact.Leases` wrapper composes through the existing
runtime custodian/authenticated-reader seams. The companion, rather than a
killable materializer, calls the unchanged native `lease/2`, records every
success before forwarding it, and retires it only after native termination or
successful unchanged revoke. It does not alter request fields, authenticated
session, principal, owner, epochs, object/version, capability, request access,
native consumer mode or SQL scope. The owner remains the native read caller.
The authorization dependency bundle still points directly to the existing
custodian; only the operation-local acquisition/read adapters are wrapped.

The companion is not continuously mailbox-responsive while it is inside the
unchanged synchronous native acquisition/revoke calls. Acquisition has the
existing default call timeout; native revoke itself has its existing waiting
semantics. During this interval DOWN/cancel remains queued and must be checked
before forwarding any returned lease. No immediate cleanup bound is claimed
for a stalled native custodian/reader, and no wrapper timeout may convert an
unknown result into successful cleanup. During the owner's long fold/read,
outside companion-native calls, cancellation is independently serviceable.

Required native witnesses kill the owner/requester after native acquisition but
before recording, and after recording but before forwarding. The companion
must record/revoke the returned lease in both cases and release no handle or
plaintext. These are NOT RUN; static source compatibility is not native proof.

**BLOCKED_DESIGN — UNSUPPORTED frozen-native delayed issuance:**
`KeyCustodian.lease/2` (`key_custodian.ex:245`) calls `GenServer.call/2` with its
default timeout. If that call times out before a subsequently issued lease PID
is returned, the public API gives this operation no identifier with which to
revoke the late lease. A companion can protect an observable successful result;
it cannot manufacture an unreturned identifier. The source supports this gap;
the deterministic late-issuance native witness is still required to establish
its actual runtime manifestation. It must not be reported as already tested.

**BLOCKED_DESIGN — UNSUPPORTED companion death during acquisition:**
Actual nonauthor DESIGN_SOURCE_SPEC found an additional P2. The companion owns
the only lease map. A hard kill after native issuance but before recording or
forwarding loses the export-observable lease identifier. Linking/monitoring the
owner closes delivery but creates no surviving revoker; request-mode native
leases monitor custody, not the acquisition caller. Companion death after
recording also cannot be qualified by owner/requester-death tests. Add separate
deterministic acquisition-window and recorded/forwarded-lease witnesses and
keep strict native inactivity assertions unsatisfied until actually resolved.
This is a source-supported design gap; runtime manifestation is NOT RUN.

The governing design says, “On cancel, disk-full, timeout, process death, denied
chunk or checksum mismatch, revoke outstanding leases”; Task 16 repeats that
requirement without a returned-lease-only exception. Consequently the strict
Task 16 assertion remains unchecked for both identifier-loss boundaries and
its affected guarantee cannot be accepted on the two owner/requester
successful-acquisition races alone. Do not weaken or
reclassify that assertion as an expected pass. This does not invalidate unrelated
Task 14/15 work or declare the entire Phase 5 externally blocked.

No private custody messages, `:sys` state inspection, global lease enumeration,
changed timeout/monitor/TTL, worker-mode substitution, whole-session revocation,
or Vault/custody modification is authorized as a workaround. The parent must
inspect existing public alternatives and decide the boundary before granting
implementation GO for the affected promise. The plan records supported work
separately and retains the unsatisfied acceptance check.

Bounded native characterization belongs in new export-artifact tests using
genuine public KeyCustodian/DownloadLease composition, native encrypted sources
and ref-tagged delegated barriers. Companion hard-kill witnesses cover
pre-record, pre-forward and known-forwarded states; require native public read
DENY separately from closed delivery, process DOWN and owned-file cleanup.
For late issuance, hold the existing delegated object-key loader, observe the
real unchanged five-second public-call timeout, then release the loader. A
test-only delegating clock observer can report `self()` at the new lease's
existing `DownloadLease.init/1` `utc_now/1` call (download_lease.ex:96–102),
identified by the fixture's exact object-bound reader context. Its PID/ref
message contains no key or content. The observer alone retains the PID for the
required native-denial assertion and final isolated fixture cleanup; it never
supplies production lookup/recovery authority. No lease enumeration, altered
clock result, private wire/state inspection or frozen Vault test edit is needed.
If actual public read still succeeds, retain the strict assertion failure as
evidence, not expected GREEN. All these witnesses remain NOT RUN.

## Owned directories, cancellation and restart

Trusted `knowledge_export_root` is the only new setting. Dev/prod optionally
read `SINGULARITY_EXPORT_ROOT`; the default is a sibling of backup_root named
`basename(backup_root) <> "-knowledge-export"`. Tests use a separate run-scoped
root. Existing required environment, storage/backup roots, custody paths,
production activation and source-format settings remain unchanged.

`ArtifactDirectory` validates normalized absolute paths, existing parent
components without symlinks, root mode 0700, process ownership and disjointness
from storage_root/backup_root in both ancestor directions. Compare native
device/inode identities as well as lexical paths to reject aliases. Creating
an absent dedicated root is allowed only at the configured path beneath an
existing validated parent. Never chmod/reuse a foreign existing directory.
An exclusive empty ownership probe may establish the creating OS uid without
shelling out; remove only that probe's recorded inode.

Each operation creates `knowledge-export-<canonical UUID>` with mode 0700,
then an exclusive 0600 `.ownership` JSON marker before writing content.
Its exact JSON keys are `format`, `version`, `operation_id`, `root`, `operation`.
`format` is `singularity.knowledge-export-owner`, `version` is integer 1, and
`operation_id` is the canonical UUID from the directory name. Both `root` and
`operation` contain exactly the string keys `major_device`, `minor_device`,
`inode`, `uid`, `gid`, each with an integer value.
It contains no session, principal, content, keys, filesystem destination, or
lease. Control metadata is fixed-size and bounded to 1,024 bytes; existing
Spool/Writer content-accounting ceilings remain unchanged. Spool and Writer
roots are this operation envelope, not caller input.

On cancellation: seal delivery first; signal native Writer cancellation when a
descriptor exists; revoke known native leases; stop the owner and observe its
DOWN; only then remove its owned envelope. Do not run Spool deletion while its
snapshot producer is still writing. Ledger disappearance after owner death is
expected: cleanup then uses the companion's independent envelope identity,
not a fabricated Writer descriptor or a dead ETS table.

The companion traps its own task-supervisor EXIT for bounded cleanup, and the
owner monitors/links the companion so losing its cleanup authority closes the
owner. This is fail-closed delivery, not proof of native lease revocation when
the companion itself is killed; the acquisition/death boundary above remains
unsatisfied. Normal completion drops the requester monitor, not the owner monitor.
Abrupt VM loss cannot execute callbacks; startup scavenging is required.
The application startup replacement calls
`ExportArtifact.start_runtime(children, options, start_infrastructure)` in the
original application caller. False delegates directly to native
`Supervisor.start_link/2` without reading/validating roots or taking the guard.
True uses `:global.trans({{ExportArtifact, :runtime_start}, self()}, fun,
[node()], 0)`: one fixed local-node lock resource, a distinct requesting PID,
zero retries and no waiting queue. `:aborted` becomes
`{:error, :storage_unavailable}` without filesystem effects. Never use the
default distributed node set, caller-selected lock identity or artifact catalog.
Inside the guard, recheck the named Runtime supervisor and existing
UploadRecoveryTaskSupervisor before root preparation/scavenging. A live Runtime
returns `{:error, {:already_started, pid}}`; a remaining task supervisor refuses
with `{:error, :storage_unavailable}`. Neither branch touches the roots.
After successful cleanup, call the actual `Supervisor.start_link(children,
options)` inside the same critical section and retain the guard THROUGH its
return, registration or error. Preserve native caller/link, child order, options
and result; do not spawn a substitute starter or return a deferred callback.
Normal return/exception releases the guard; OTP releases it on holder death.
A later attempt still checks any surviving registered supervisor before cleanup.
Root/cleanup failures return a content-free storage error without starting the
tree. No timeout or supervision policy is increased or changed.
This is same-node startup exclusion only, not shared-root multi-node support.
The selected mechanism avoids a new coordinator/registry; retaining the old
pre-start-only call is rejected because it cannot cover registration, and a
distributed lock or artifact catalog is unnecessary scope.
[OTP lock and transaction semantics](https://www.erlang.org/doc/apps/kernel/global.html#trans/4)
provide the existing primitive; native behavior remains to be qualified.

The guarded scavenger scans only immediate children matching the exact prefix and a
valid ownership marker under the validated root. It refuses malformed markers,
identity/mode/uid mismatches, symlink parents and unrecognized directories.
It never searches storage_root or backup_root.

Deletion walks only the recognized operation, lstat-checks every entry, never
follows symlinks, and rechecks root/operation identity before destructive steps.
A foreign sibling, another operation's sentinel, and all nonrecognizable files
must survive. An identity conflict produces a sanitized cleanup failure and
retains the questionable entry; it is not recorded as successful cleanup.
Concurrent runtime-start attempts must not scavenge a live runtime's artifacts.

## Exact attribution prerequisites and startup replacement contract

Task8 is accepted at `21d066036edbcb3f0a0737ae2dca36a9cea79427`.
The governing Phase5 master plan's Task8 “Necessary composition compatibility”
and governing design §6 explicitly authorize only the Application WorkerRepo
alias and repository-aware `object_storage` context, plus its owning assertion.
Those accepted production bytes remain unchanged. The necessary NEW allowance
is test-only attribution in
`apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs`.
It must qualify separately before Task16 attribution depends on it; documentary
allowlisting does not grant this author or Task16 an implementation window.

Recommended: two exact reversible Task8 tuples in a separate helper before the
existing historical pipeline. P5-T8A removes only the exact WorkerRepo alias;
P5-T8B restores only `object_storage: {Exporter, storage}` in the source copy.
The plan's Step7a fixes every literal, unique context, digest and negative.
Changing old Phase3 contexts would rewrite historical evidence, and accepting a
current whole-file hash would mask unrelated drift; neither is permitted.
No module/term-wide exception, reordering of old tuples or new frozen baseline.

The actual old Phase3 alias tuple expects SearchProjectionReconciler immediately
before `\n  @impl true\n`; Task8's alias intervenes. Its context has zero matches
before the Task8 inverse, one afterward. Phase4 has no Application tuples;
the seven old Application additions across Phase3/Phase2 do not include Task8.
Bypassing context and diagnostically removing those old seven alone leaves
`58a65b654bb708a74c90f83ba3cf5e88c3c23cbb235d8f6f0aab15c654e378e8`,
differing from baseline in exactly the two Task8 changes. That
diagnostic is historical FAIL evidence, never an approved normalization.

The implementation plan retains seven unchanged Api/config additions P5-A1–A4
and P5-C1–C3. P5-A5 is ONE exact literal native-start-call replacement, not an
eighth insertion. Verify its old/new digests and exact preceding/following
context; require one new call and no retained old call, then invert only that
replacement to recover the pre-Task16 application bytes, which still contain
Task8. Reject missing,
duplicate, relocated, altered or extra calls. For the seven additions verify
exactly one copy, block digest and context before stripping. Then verify and
invert Task8 P5-T8A and P5-T8B, in that order, before running unchanged Phase4
organization additions → Phase4 additions → Phase3 additions → Phase2 special
additions → Phase2 worker additions → original legacy digest assertions.
Existing historical mutation tests receive this explicitly normalized source
once; their historical assertions remain in force and do not reapply an
inverse to bytes already normalized. Missing tuples must fail, never trigger
an “already normalized” fallback on current-source checks.
The accepted Task8 positive witness has a separate input boundary: first read
raw Application and keep every `assert_task8_tuple!/2` check on those raw bytes;
then use strict `strip_phase5_additions!/2` to invert only Task16, followed by
`undo_phase5_task8!/2`. Its fixed pre-Task8 digest and historical-baseline checks
consume that inverse unchanged. It must not use `normalize_phase5!/2` before a
second Task8 inverse. Step7b supplies the exact future test body. The thirteen
Task8 tuple negatives retain their raw mutations and direct Task8 inverse;
the extra-registration negatives retain their outer baseline route and causal
digest-error assertion. Earlier phase mutation setups remain unchanged.
Do not replace an old hash with the current file hash or blanket-whitelist
`Knowledge.Export`, `KnowledgeExport` or new function clauses.

Add separate closed registration attribution for the four operations and
arities, the one orchestration alias, the four production callbacks, the one
trusted runtime setting, the startup call and the three config blocks. For
every block test mutation, removal, duplication and relocation. Test an extra
export operation, an extra clause of an existing operation, an unknown
callback and an adjacent registration after a documentation attribute.
No Phase 2/3/4 tuple, digest, assertion or historical document is rewritten.

Read-only in-memory verification applied and inverted the proposed startup
replacement and all seven additions, then used all existing historical tuple
lists and Api addition hashes. Application recovered pre-Task8 SHA-256
`4deda19432de3174c2f737216c8185e3cdea8bb91d3960475308a27558bdfbca`,
equal byte-for-byte to Task8's parent, then original
`4bed50e5ab4f7ed351b0e7497a943f940466bce53101928ce4e906ae910abe35`,
equal byte-for-byte to `6c3e8d5afb2cc9dbf264d276796070e16aa49e55`.
The other four runtime-baseline paths also recovered their original digests.
Eleven Task8 missing/duplicate/altered/relocated/context/coexistence byte
mutations were rejected in memory. These are document-calculation evidence,
not execution of ExUnit, native startup or lease tests. Step7a retains required
whole-owner verification and all original assertions.

## Acceptance and handoff

- [ ] Parent-qualified Tasks 13–15 and exact current source reviewed before execution.
- [ ] Native requester-death-before-completion and requester-DOWN-after-success
  tests read real entries/chunks and prove the actual ledger owner's lifetime.
- [ ] Native acquisition/recording races revoke all observable returned leases.
- [ ] Strict timeout/late-unreturned-lease cleanup guarantee: **BLOCKED_DESIGN;
  UNSUPPORTED by the frozen public API; not satisfied or waived.**
- [ ] Strict companion-death/acquisition-window lease cleanup guarantee:
  **BLOCKED_DESIGN; source-supported P2, native witness NOT RUN; not waived.**
- [ ] Live owning session, both epochs, owner/principal, unlock and capabilities
  are checked for generation, completion, entries and every chunk.
- [ ] Snapshot COMMIT precedes materialization; delivery uses after-COMMIT scope;
  original/text/version/digest bindings remain exact and bounded.
- [ ] Deadline, close, denied owning-session read, checksum, owner death and
  startup cleanup preserve foreign sentinels and advertise no partial artifact.
- [ ] Real-supervisor startup barriers prove overlapping starts cannot clean a
  live recognized artifact, the guard spans child init and actual start return,
  and failure/exception/hard-death release permits a safe rechecked retry.
  False path has no filesystem effects; native timeouts/options stay unchanged.
- [ ] Separate exact Task8 attribution prerequisite and its negatives qualify;
  seven exact Task16 additions, one startup inverse and registration
  negatives then pass through the full ordered pipeline while all old architecture
  baselines, seven apps, zero cycles and frozen 56-file inventory remain intact.
- [ ] Parent executes whole owning pure/native commands from the detailed plan,
  inspects cleanup, and obtains independent nonauthor SPEC then fresh QUALITY.

This bounded Task8 attribution P2 design repair count: 2; production repair: 0;
Astra recovery rounds: 0. The preceding startup design amendment remains
historical; no earlier attempt or failed review is erased. Received Sol
production-repair counter for this assignment: 0; no other task counter resets.
Parent Task10 Sol1/Astra0 remains separate and unchanged. Repair1's actual SPEC
FAIL/P2 is preserved; repair2's actual corrected DESIGN SPEC and NEW distinct
fresh DESIGN QUALITY are CLOSED PASS on the exact archived copies above.
Tests, native probes and E2E: NOT RUN by this
author. No Vault feature or frozen-source change occurred. Parent owns the
master plan, acceptance report, source disposition and all subsequent execution.
Both strict native lease guarantees remain UNSATISFIED/UNWAIVED/BLOCKED_DESIGN.
This documentation author is CLOSED after handoff; Task16 source/tests remain
NO GO pending genuine resolution of both strict lease boundaries. Documentary
SPEC/QUALITY PASS is not native qualification. SQL and maintenance windows remain
CLOSED for Task16 implementation.
