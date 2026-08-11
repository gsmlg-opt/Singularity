# Supported Observability Boundary Design

**Status:** Approved design amendment

**Date:** 2026-08-11

**Amends:**
[`2026-07-18-foundation-asset-vertical-design.md`](2026-07-18-foundation-asset-vertical-design.md),
[`2026-08-08-task-18-browser-acceptance-amendment.md`](2026-08-08-task-18-browser-acceptance-amendment.md),
and Tasks 15, 18, and 19 of
[`2026-07-18-foundation-asset-vertical.md`](../plans/2026-07-18-foundation-asset-vertical.md)

## 1. Decision

Singularity supports only its application-owned observability contract:

- telemetry events whose name begins with `[:singularity]` and which are emitted
  through an explicitly approved Singularity-owned boundary;
- final JSON log records that originate from
  `Singularity.Runtime.Observability.LoggerMetadata.log/3`, after that boundary
  default-denies structured message and metadata fields and the configured
  `LoggerJSON` formatter and redactor have run; and
- immutable audit records produced through Singularity's audit boundary.

Raw telemetry owned by Thousand Island, Bandit, Plug, Phoenix, Phoenix
LiveView, Oban, Ecto, or any other dependency is not a supported Singularity
integration surface. In particular, `[:thousand_island, ...]`,
`[:bandit, ...]`, and `[:phoenix, ...]` events can contain request, response,
connection, session, socket, exception, or transport data. Singularity makes no
secret-absence guarantee for those raw events.

Free-form Logger messages, OTP and crash reports, dependency or framework
logs, and the combined raw Logger output stream are not supported Singularity
surfaces. Operators must treat all of them as sensitive data.

Supported deployments must not attach Singularity-owned reporters, exporters,
or persistence handlers directly to dependency-owned telemetry. An external
observer that subscribes to raw framework events operates outside the supported
security boundary and must treat those events as sensitive data.

This amendment does not fork, patch, vendor, or replace Thousand Island,
Bandit, Plug, Phoenix, Phoenix LiveView, or `:telemetry`. Those dependencies
remain normal Hex dependencies. A future upstream safe-mode capability may be
evaluated separately, but Task 18 does not wait for it.

## 2. Rationale

The current framework stack emits data before Singularity application code can
redact it:

- Thousand Island connection events may include complete received or sent
  socket bytes in telemetry measurements.
- Bandit request events may include the complete `Plug.Conn`, including unread
  adapter buffer data, before the endpoint or router runs.
- Plug and Phoenix endpoint, router, error, socket, and channel events may
  include complete connections, params, sessions, exceptions, or payloads.
- Phoenix LiveView spans may include sockets, params, sessions, and assigns.

No supported option in the locked or current upstream releases provides a
producer-side safe mode across those surfaces. A telemetry handler cannot
sanitize an event for other handlers because every handler receives the event
that the producer emitted. Therefore a literal guarantee over all dependency
events would require maintaining dependency forks, which this design rejects.

The honest boundary is the contract Singularity controls. Singularity already
owns a backend-neutral telemetry module that admits numeric measurements and
redacts bounded metadata before emission. It also owns a default-deny
structured-log entry point, the final formatting/redaction of records that pass
through it, and the audit persistence contract. Those remain meaningful,
testable security surfaces without claiming control over dependency internals.

## 3. Supported telemetry contract

`Singularity.Runtime.Observability.Telemetry` remains the public telemetry
emission API for runtime operations. The existing bounded RLS-denial emitter in
`Singularity.Storage.SafeSQL` is the one approved lower-layer emitter because
the storage application cannot depend on the runtime application. Adding any
other emitter requires an explicit architecture allow-list and the same
acceptance checks.

Every supported event must satisfy all of the following:

1. Its event name begins with `[:singularity]`.
2. Every measurement is numeric.
3. Metadata is bounded operational data and is passed through the Singularity
   redactor before `:telemetry.execute/3`.
4. Callback results, raw exceptions, stack traces, connections, sockets,
   request or response bodies, headers, cookies, params, sessions, filesystem
   paths, and key material are not included.
5. A malformed event is dropped without changing the domain operation result.

The supervised telemetry adapter may consume a specifically allow-listed
dependency event, currently Oban job stop/exception events, solely to derive a
safe `[:singularity, ...]` event. The raw source event is not thereby promoted
to the supported contract. New source adapters require an explicit allow-list,
bounded extraction, and secret-canary coverage.

Reporters consume only Singularity metric definitions and
`[:singularity, ...]` events. They must not subscribe directly to framework
namespaces.

## 4. Supported logs and audit records

The only supported logging surface is each final JSON record that originates
from `Singularity.Runtime.Observability.LoggerMetadata.log/3`. That boundary
default-denies fields in both the structured message and structured metadata
before the event reaches Logger. The configured `LoggerJSON` formatter and
`Singularity.Runtime.Observability.Redactor` then format and redact the admitted
record. Acceptance of the logging contract requires emitting through
`LoggerMetadata.log/3` and inspecting the resulting JSON record.

Free-form Logger messages, OTP and crash reports, dependency or framework
logs, and the combined raw Logger output stream are unsupported and must be
treated as sensitive. Selected `capture_log` and request-log checks remain as
defense in depth; they do not promote their captured raw output into the
supported logging contract.

Supported application operational records must use the default-deny
`Singularity.Runtime.Observability.LoggerMetadata` contract. Only approved
opaque identifiers and bounded operation/result values are admitted. Existing
parameter filtering and request scrubbing remain defense in depth.

Audit records remain a separate supported surface. Audit values are built and
redacted before the persistence port. They must retain the required immutable
operation, result, actor, vault, correlation, timestamp, and redacted target
fields without carrying credentials, tokens, keys, plaintext, or free-form
secret values.

## 5. Unsupported framework telemetry

The following rules apply to dependency-owned telemetry:

- Singularity does not advertise its names or metadata shapes as a product API.
- Singularity does not configure an application reporter or exporter for it.
- Secret-canary acceptance does not attach observers to it or claim that its
  measurements or metadata are secret-free.
- Operators must not persist, export, or expose it in a supported deployment.
- Adding a production Singularity subscription to it is a contract violation.

Existing application scrubbers for selected Phoenix stop, exception, and error
paths remain in place as defense in depth. Their focused tests may remain, but
they do not establish or imply support for the complete Phoenix, Bandit, or
Thousand Island event streams.

Framework-internal logging or instrumentation may continue to exist, but its
output remains unsupported and sensitive regardless of the configured
formatter. The supported security assertion applies only to final JSON records
originating from `LoggerMetadata.log/3`, not to transient dependency event
arguments or the combined raw Logger stream.

## 6. Secret-canary boundary

The existing browser token allowances do not change:

- a backup passphrase may occur only in the transient password input value and
  the body of its same-origin URL-encoded `POST /backups`;
- an upload token may occur only in its grant reply and matching upload request
  header; and
- a CSRF token may occur only in its dedicated meta tag, LiveSocket connection
  parameter, Phoenix-generated controller form field, and matching same-origin
  upload request header.

Password, passphrase, key, and server-secret canaries must remain absent from:

- `[:singularity, ...]` event measurements and metadata;
- final JSON records originating from `LoggerMetadata.log/3`;
- audit records and persistence-adapter arguments;
- initial and returned HTML, `data-props`, application and server-pushed
  LiveView payloads, and application JSON;
- exception text returned by Singularity; and
- browser console, page errors, and captured application responses.

The upload-token and CSRF-token exact allow-lists continue to govern browser
and application surfaces. Their presence in unsupported raw transport or
framework telemetry is neither tested nor represented as safe.

## 7. Enforcement and verification

Acceptance adds or preserves the following checks:

1. Runtime telemetry tests attach only to expected `[:singularity, ...]`
   events and recursively scan both measurements and metadata for every seeded
   canary.
2. Runtime secret-canary and logging-contract tests continue to cover
   telemetry, the structured fields admitted by `LoggerMetadata.log/3`, the
   configured JSON formatter/redactor output, audit values, adapter arguments,
   and returned domain values.
3. Web and browser secret-canary tests continue to cover HTML, response
   headers and bodies, application JSON, LiveView application payloads,
   browser console, and page errors.
4. An architecture contract rejects production Singularity reporters,
   exporters, or persistence handlers that subscribe directly to
   dependency-owned telemetry. The existing bounded Oban-to-Singularity
   adapter is the explicit internal exception.
   It also rejects unapproved direct `[:singularity, ...]` emitters while
   allowing the runtime telemetry boundary and bounded storage RLS-denial
   emitter.
5. Dependency-source checks reject Git, GitHub, path, or vendored overrides for
   Thousand Island, Bandit, Plug, Phoenix, Phoenix LiveView, and `:telemetry`.
6. Existing focused Phoenix scrubber, request-log, and `capture_log` tests
   remain defense-in-depth tests. They are not used to claim complete framework
   telemetry secrecy or support for the combined raw Logger output stream.

The scoped finish gate still runs the runtime telemetry and secret-canary
tests, web secret-canary tests, browser workflow, restore acceptance, compile,
format, architecture, xref, and whitespace checks. With this amended contract,
raw framework telemetry is not a Step 13 blocker.

## 8. Documentation and plan refresh

Implementation must update the following documents without changing the
boundary again:

- the foundation design's observability and security-test sections;
- the Task 18 browser acceptance amendment's backup-passphrase and CSRF
  statements;
- `docs/guide.md` operational telemetry guidance;
- Step 13, Step 15, Task 19, and the completion checklist in the parent
  implementation plan; and
- any README statement that describes the telemetry secrecy guarantee.

In those documents, an unqualified Singularity security requirement referring
to "telemetry" means supported `[:singularity, ...]` telemetry. Statements
about dependency-owned telemetry must explicitly call it raw framework
telemetry and mark it unsupported.

An unqualified logging security claim means only final JSON records originating
from `LoggerMetadata.log/3`. Free-form messages, OTP and crash reports,
dependency or framework logs, and the combined raw Logger stream must be
identified as unsupported sensitive data.

The parent plan already contains unrelated uncommitted user edits. The refresh
must preserve them and stage only the observability-boundary hunks.

## 9. Non-goals and completion

This amendment does not:

- create or modify dependency forks or upstream repositories;
- add a global telemetry filter, runtime handler firewall, or handler-order
  assumption;
- claim that raw HTTP, WebSocket, Phoenix, LiveView, Bandit, or Thousand Island
  instrumentation is secret-free;
- remove supported Singularity metrics, `LoggerMetadata.log/3` final JSON
  records, or audit records; or
- change browser token transport allowances.

The amendment is complete when the documentation consistently states the
supported boundary, production Singularity integrations cannot subscribe to
raw framework telemetry without failing the architecture guard, supported
secret-canary surfaces pass, no dependency source override exists, and the
remaining Task 18 and Task 19 gates pass.
