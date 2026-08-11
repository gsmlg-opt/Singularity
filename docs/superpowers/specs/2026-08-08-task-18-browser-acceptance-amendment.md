# Task 18 Browser Acceptance Amendment

**Status:** Approved design amendment

**Date:** 2026-08-08

**Amends:**
[`2026-07-18-foundation-asset-vertical-design.md`](2026-07-18-foundation-asset-vertical-design.md)
and Task 18 of
[`2026-07-18-foundation-asset-vertical.md`](../plans/2026-07-18-foundation-asset-vertical.md)

## 1. Decision

Task 18 will not add a live-vault integrity-audit request, capability, durable
job, dispatcher mapping, or browser action. The implemented integrity audit is
restore-scoped: it depends on the authenticated backup manifest, restored cut,
restored object inventory, restore lease, and restore-created system authority.
Turning it into a live-vault operation would be a new product design rather
than browser wiring.

The existing `mix singularity.test.restore` command remains the sole acceptance
proof for restore and integrity audit. Task 18 completes only when both the
browser gate and this independent restore gate pass.

Until the parent implementation plan is refreshed, this amendment supersedes
Task 18's requirements for integrity-audit request/status APIs, integrity-audit
Oban routing, a browser-owner integrity capability, a browser request action,
and a browser-rendered `Integrity audit passed` result. It also supersedes the
requirement to reproduce every listed protocol edge case in Playwright; the
coverage allocation in section 5 is authoritative.

## 2. Acceptance split

The Chromium workflow proves the live Vault Workbench path:

```text
provision -> login -> unlock -> upload PDF/JPEG/PNG
-> observe lifecycle -> search/filter/page -> download
-> delete -> cleanup -> request backup -> observe sealed backup status
```

The restore gate separately proves:

```text
create backup -> restore into an empty isolated environment
-> authenticate ciphertext and plaintext -> rebuild search
-> run the restore-scoped integrity audit -> pass the restore oracle
```

Neither gate substitutes for the other. A successful browser backup must not
be rendered as an integrity-audit result, and a successful restore test must
not be represented as an audit performed against the running browser vault.

`AuditLive` remains read-only. It must explain that integrity verification is a
restore acceptance operation proven by `mix singularity.test.restore`; it must
not expose a request button or claim a current-vault result. The CI result from
that command is the authoritative proof.

## 3. Browser backup boundary

The backup passphrase is submitted through an authenticated, unlocked,
same-origin, CSRF-protected HTML `POST /backups` controller action. It must not
cross a LiveView event, LiveView assign, React property, JSON response, URL,
OS process argument, environment variable, supported final JSON record
originating from `Singularity.Runtime.Observability.LoggerMetadata.log/3`,
supported `[:singularity, ...]` telemetry field, or audit metadata.

The controller calls only `Singularity.Runtime.Api`. The runtime facade accepts
the non-secret session DTO plus the request passphrase. Argon2id derivation runs
in the request process, outside `KeyCustodian`'s serialized mailbox. The
derived key and public KDF metadata then enter a session-bound custodian
operation that verifies the active unlocked session and its authorization
epochs, creates the recovery wrapper using the in-custody vault key, and
installs pending backup-key custody. The raw vault key never leaves custody,
and neither the passphrase nor Argon2id work enters the custodian process.
Neither the controller nor a runtime DTO receives raw key material.

The destination is selected server-side from configured local backup storage.
The public result is reduced to an allow-listed backup status DTO. It may
contain a public operation identifier, stable status, and timestamps; it must
not contain the passphrase, derived key, recovery wrapper, KDF material,
custody reference, filesystem path, destination reference, manifest internals,
or object inventory.

After submission, the controller redirects to `GET /backups`. `BackupsLive` is
status-only: it renders the redacted request state and stable failure text and
never retains the submitted passphrase. It reads or polls status only through
`Singularity.Runtime.Api` under the current session. The read requires the
existing `backup.create` capability and scopes the public operation identifier
to the current vault under the normal operation scope and RLS context. A
missing operation and an operation in another vault return the same public
`not_found` result. `BackupsLive` never consumes an internal manifest map.

The completed browser-visible state is `sealed`, not `valid`. The architecture
guide reserves backup validity for the separate successful restore test.

The browser secret canary permits the backup passphrase only in the transient
DOM value of its password input and the body of its same-origin URL-encoded
backup form submission. It must be absent from initial and returned HTML,
`data-props`, application and server-pushed LiveView payloads, application
JSON, supported final JSON records originating from `LoggerMetadata.log/3`,
audit metadata, supported `[:singularity, ...]` telemetry, and the browser
console.

The CSRF allow-list adds the Phoenix-generated hidden field on the backup form
to the existing framework locations: the dedicated meta tag, LiveSocket
connection parameter, Phoenix-generated controller-form fields, and the
same-origin upload request header. The token remains forbidden from
application/server-pushed events, `data-props`, application JSON, supported
final JSON records originating from `LoggerMetadata.log/3`, audit metadata,
supported `[:singularity, ...]` telemetry, and the browser console.

These canaries cover application responses and supported observability. Raw
Thousand Island, Bandit, Plug, Phoenix, and Phoenix LiveView telemetry is
unsupported: the browser gate neither attaches to it nor claims it is safe, and
supported deployments must not persist or export it. Selected scrubbers remain
defense in depth.

Free-form Logger messages, OTP and crash reports, dependency or framework
logs, and the combined raw Logger output stream are likewise unsupported and
must be treated as sensitive. Selected request-log and `capture_log` tests
remain defense in depth and do not extend the supported logging boundary.

The deterministic browser owner gains only the existing `backup.create`
capability needed for this workflow. Task 18 does not widen the production
`BootstrapOwner` default capability set; a normally provisioned principal must
already have `backup.create` to use the control. Task 18 grants no principal
`integrity.audit` authority.

## 4. Pagination proof

Production asset pages retain the default limit of 50. The browser server may
set a test-only page limit of 2 before application startup. Uploading the three
required media types then proves the real next-cursor path without seeding
database rows or performing 51 uploads.

The override is confined to the generated browser-test environment. Unit tests
must prove the production default remains 50 and that the configured browser
limit reaches the existing runtime search call without changing cursor
semantics. Browser-server cleanup restores the prior page-limit configuration
on partial setup, `SIGTERM`, and VM exit.

## 5. Coverage allocation

Playwright covers behavior that is both user-visible and reachable through the
current product surface: authentication, unlock, the three supported media
types, lifecycle presentation, search, filters, pagination, download, delete,
cleanup, backup submission/status, responsive layout, keyboard use, themes,
accessibility, and browser-visible secret canaries.

Existing scoped ExUnit and Vitest tests remain the acceptance layer for stale
state revisions and event sequences, upload grant expiry and reuse, upload
cancellation and retry, metadata waiting while locked, reconnect snapshots,
and navigation allow-list enforcement. Task 18 will not add slow or synthetic
browser scenarios for states the UI cannot reach or whose real expiry window
would make the gate brittle.

## 6. Failure and completion rules

- Backup form errors use stable, non-secret messages and never repopulate the
  passphrase.
- A missing or expired session follows the existing authentication flow; a
  locked vault follows the existing unlock flow.
- A failed backup remains a browser-gate failure even if the restore gate
  passes.
- A failed `mix singularity.test.restore` remains a Task 18 blocker even if all
  browser tests pass.
- No integrity-audit event may be routed through Oban or the outbox as part of
  Task 18.
- Task 18 is complete only when the scoped runtime/controller/LiveView tests,
  Chromium workflow, secret canaries, and existing restore gate all pass.

## 7. Parent-plan refresh

The executable Task 18 file list and steps must remove integrity-only changes
to the runtime job dispatcher and Oban adapter. They must instead include the
authenticated backup controller and router, the session-bound backup custody
operation, an authorized vault-scoped backup status port and redacted DTO,
`BackupsLive` and `AuditLive`, the configurable `AssetsLive` page limit, browser
configuration cleanup, and their scoped tests. The plan must preserve
`Singularity.Runtime.Api` as the only web-to-runtime dependency seam.
