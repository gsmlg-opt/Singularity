# Empty Document original authentication

Status: bounded source implementation accepted locally under standing approval.
Parent and independent Astra review found the bounded architecture sound. The
plan's environment commands and original repository gate were corrected before
TEST GO. Real API missing/corrupt regression RED preceded production edits; the
final scoped checks and independent source SPEC/QUALITY reviews passed.

## Scope and evidence

This is a bounded Task 14 repair within the approved Phase 2 import/extraction
design and plan. The inspected baseline is
`26e16a5716dec8c3df835a7ff8e1d258249cde58` in
`.trees/v0.2-phase-2-import-extraction`.

`Documents.Read.authenticate/3` currently skips storage for zero source chunks,
then accepts the locally computed SHA-256 of empty bytes. Lease acquisition
unwraps the database-bound key; it does not authenticate the ciphertext. Therefore
a missing or corrupt empty original can produce a successful download response.
`DownloadLease.read(lease, :all)` deliberately rejects request Document leases.
The existing `authenticate_empty_document_source/1` is worker-only and must keep
its current guards and lifecycle.

The repair changes only these production files:

- `apps/singularity_runtime/lib/singularity/runtime/documents/read.ex`
- `apps/singularity_runtime/lib/singularity/runtime/download_lease.ex`

Tests are additive in `document_api_test.exs` and `download_lease_test.exs` under
`apps/singularity_runtime/test/singularity/runtime/`. Existing nonempty and worker
tests remain intact. No new application, schema, storage behavior, KeyCustodian,
CustodyReader, capability, key, or Vault semantics change is included. No E2E,
release, push, deployment, or complete Phase 2 acceptance is included.

## Alternatives and decision

1. Add a request-only empty-original operation to DownloadLease. It reuses the
   established authenticated full storage read without exposing a general full
   read to request Documents. This is the selected, smallest bounded change.
2. Permit request Document `read(:all)`. Rejected because it broadens the public
   lease surface and bypasses the intended bounded Document API.
3. Extend the worker empty-source operation to requests. Rejected because worker
   consumer ownership and process termination differ from request leases; sharing
   that public operation would weaken an existing guard.

## Request-only lease contract

Add `DownloadLease.authenticate_empty_document_original/1`, returning only `:ok`
or a sanitized error. Invalid arguments return `Error.new(:invalid)`. Its accepted
lease shape is `mode: nil`, a binding containing `access: :request` and
`resource_version_id`, `next_index: 0`, and trusted
`reader_context.object_binding.plaintext_byte_size: 0`.

Only that request Document mode is eligible. A pending request operation returns
`:conflict`. Wrong mode, missing binding, missing/nonzero trusted size, and a
consumed chunk index return `:invalid`. For an otherwise eligible lease,
revocation or expiry returns `:waiting_for_unlock`; expiry also revokes state.
Caller-supplied source size never replaces trusted reader context.

The operation uses a distinct internal `:empty_document_original` range marker.
The existing `start_read/3` and `perform_read/1` execute authorization before and
after `key_reader.read_range(reader_context, binding, :all)`. The lease checks its
status again when completion arrives. Thus success requires all three fences and
an exact `{:ok, ""}` storage result. The existing storage reader authenticates
the empty object's header and final record.

Completion maps exact empty bytes to `:ok`, a nonempty or malformed success to
`:integrity_failure`, `:waiting_for_unlock` unchanged, and `%Error{}` through
`public_error/1`, preserving only code and retryability. Inactive completion
always returns `:waiting_for_unlock`. Success alone records authorized activity.
Exceptions already become a sanitized retryable `:storage_unavailable` through
`perform_read/1`.

Every completion consumes the lease using `revoke_state/1` and clears pending
state, but retains the request lease process. A repeated empty operation returns
`:waiting_for_unlock`; the existing `Read.authenticate/3` final `revoke/1` remains
safe. Do not change global `revoke/1` behavior. Request readers remain monitored
via `spawn_monitor`; this work makes no worker-style consumer-death or abrupt
lease-kill cleanup claim.

## Document read composition

For a zero-byte binding, `Read.authenticate/3` calls the new operation before
accepting SHA-256(empty). It still checks the immutable source digest, then runs
the established final revoke. A failed authentication or digest mismatch returns
an error before a delivery lease can be acquired.

After successful authentication and digest comparison, acquire the existing fresh
session-bound delivery lease required by Task 14. Since the returned reader has
zero chunks, immediately revoke that delivery lease before returning it. The DTO
is `%{byte_size: 0, chunk_count: 0, read_chunk: function}`; every chunk index is
invalid and no live delivery DEK remains. The nonempty reduction and delivery
behavior stay unchanged.

## Verification and privacy

The decisive regression uses `Api.download_document_original/3` with a config
callback to the real `Documents.Read`, a real PostgreSQL pinned Document, real
KeyCustodian/CustodyReader, and LocalFilesystemAdapter ciphertext. A valid empty
object succeeds; missing and same-length corrupted empty ciphertext fail before
any reader is returned. Both negative tests must be observed RED on the unchanged
production baseline, not merely fail on a missing new function.

The existing prepared fixture defaults to 12 bytes. Build and install the empty
encrypted object, set source-map size/digest to zero/SHA-256(empty), and only then
insert the immutable Document. Do not update an existing Document's source tuple.
Reuse the current local helpers without changing shared storage fixtures or
refactoring existing tests.

Focused lease contracts cover request/worker/Asset modes, generic range rejection,
trusted-size guards, pending conflict, index use, replay, pre-read authorization,
post-read authorization, pre-read expiry, in-flight expiry, and explicit revoke.
Use messages and controllable clocks, never sleeps. Tests must assert no reader
start on pre-read denial, no success after fencing, and no key material in the
consumed lease's reader context. Request process retention is deliberate.

Focused read contracts count leases: failed storage or digest checks acquire no
delivery lease; valid empty reads acquire and revoke both leases. Integration
controls retain the original after Asset deletion and deny tombstoned Documents,
cross-owner sessions, and revoked sessions. Existing nonempty controls must pass
unchanged. Error-message/detail canaries and captured logs must not expose source
text, object DEKs, or filesystem diagnostics.

The parent owns all Mix/service execution, sequentially. Stop after the approved
focused checks and review; record exact commands and outcomes. The complete README
gate is not run here because this slice is not Phase 2 acceptance and E2E is
explicitly excluded. The pre-existing untracked runtime-outcomes integration plan
must remain byte-identical and excluded from this change.
