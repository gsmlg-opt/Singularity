# Phase 5 Task11 prerequisite: genuine native text originals

Status: design v2 CLOSED PASS after independent SPEC then NEW distinct fresh
QUALITY; implementation/focused checks and actual independent source SPEC then
NEW distinct fresh QUALITY PASS. Four local code commits end at
`5f388ac88d5603b8c29df3a592d0843885a30912`; documentation review and literal clean
handoff are separate closure requirements. Continuous development
authorization applies; no routine human approval is needed. This
bounded prerequisite is not Task11 saga acceptance, Phase5 acceptance, defaultV3
activation or production activation. Task10 local handoff CLOSED PASS at
94efb34ae128298ab62bfbd7b77d387b882bbb62 after all15 permitted gates and independent
code/documentation reviews; source d1a8d4f73c570daa7177468b246a25819a2cdd39.
See [Task10 handoff](../../verification/2026-10-15-phase-5-task10-handoff.md) and
its actual local closure. Phase5 remains IN PROGRESS, E2E NOT RUN.
The [prerequisite verification record](../../verification/2026-10-15-phase-5-native-text-prerequisite.md)
records exact qualified source generations, actual review identities, local code
commits and remaining acceptance boundaries. These scoped results do not credit
historical Task10 gates to changed code or enable defaultV3.

## Why this compatibility work is required

Task11 requires literal empty/plain/Unicode/Markdown originals through genuine
native upload, custody, verification, publication and download. At the Task10
baseline, native upload admits only PDF/JPEG/PNG. Document import consumes an
existing Asset, not input bytes. A mere allowlist change is insufficient: existing metadata parsing
and native terminal metadata checkpoints remain three-format and frozen.

Use upload-stream validation and genuine publication for exactly text/plain and
text/markdown. Do not alter metadata leases, fabricate their results, synthesize
keys/ciphertext, transform originals or pretend PDF fixtures are literal text.
This follows the source-backed architecture preparations, including the
in-flight backup-cut guard. Those ignored preparations were not source GO.

## Scope and fixed boundaries

Production changes are confined to Ingest UploadRequest plus a pure incremental
text validator; Runtime Api and AcceptUpload declaration/DTO gates, the smallest
Assets.Download MIME allowlist compatibility; the existing UploadSession;
Storage AssetRepository sealed evidence/replay and finalization;
and Backup.Exporter's read-only unsupported-state guard. Focused tests, bounded
test support and progress documentation are part of this prerequisite.

No new endpoint, browser behavior, option/configuration, dependency, application,
schema/migration or native metadata protocol. No production canonical-write
activation. No KeyCustodian, KeyLease, CustodyRepository, DownloadLease,
RestoreIntegrityLease, crypto/wrapping, role/grant/policy, CoreState, released
migration, metadata-lease or MetadataExtractor change. Existing PDF/JPEG/PNG
behavior, V1/V2 compatibility and defaultV2 remain literal.

Owner scope comes from authenticated runtime context. All existing grant/session,
CSRF, capability, current-epoch, classification and opaque-custody checks remain.
No caller-selected owner, supplied validation marker or public metadata fields.

## Complete original-byte validation

UploadRequest admits exactly the two additional MIME declarations. Detection
remains a binary-signature detector, not a text/Markdown content heuristic.
Plain versus Markdown identity is the immutable declaration, never a filename.
The effective text maximum is min(existing configured upload maximum,
67,108,864 bytes), the established Document bound; smaller configured limits
remain effective and existing binary limits do not change. Independent Runtime
selector/grant/session admission must preserve this bound, not trust an
arbitrary descriptor. Exact declared/observed length remains mandatory.

A pure incremental Ingest validator exposes new/0, append/2 and finish/1.
State contains only bounded numeric decoder/prefix counters, not buffered
content. It validates every appended byte, including after any existing binary
media_validated fast path. Handle arbitrary UTF8 codepoint partitions; reject
NUL, stray/overlong/surrogate/out-of-range encodings and incomplete EOF.
Reject a complete conflicting PDF/JPEG/PNG signature at the beginning, including
split signatures. A partial PDF prefix at honest EOF is ordinary valid text.
Return existing bounded content-free errors, without values from the stream.

Accept empty text only at genuine EOF. Preserve every original byte, including
BOM, CRLF, decomposition/normalization form, whitespace and Markdown syntax.
No normalization/extraction occurs on the original path. Before real StageWriter
finish, require successful text EOF validation and exact length; malformed/late
data must abandon through existing acknowledged lifecycle. Existing binary
signature buffering, deadlines, ACK/reducer protocol and cleanup stay unchanged.
Text validation state belongs to the existing UploadSession, not a new process.

## Internal sealed-stage evidence, not a metadata lease

Only successful native validation plus actual writer sealing may derive the
internal fixed upload_text_v1 evidence. Bind it to the existing exact stage,
grant, authenticated session/principal/owner/classification, Asset/resource
version, immutable source/declaration, real format/digests/size and sealing time.
Retain independent repository binding/current-authorization checks. The internal
checkpoint field is absent for binary uploads and rejected if inapplicable.
It is not accepted from public upload fields and is not cryptographic attestation
against a privileged backend that can fabricate arbitrary application commands.

Persist the fixed marker in the existing per-Asset extractor_version column
atomically with sealed stage, uploaded transition, genuine verification outbox
and existing upload audit. Metadata remains pending with detected MIME,
completed_at and PDF/image fields nil; plaintext size/declaration are exact.
No metadata job/checkpoint, synthetic effect receipt or new schema field.

Sealed replay independently locks/validates the exact existing metadata evidence
as well as the original stage/grant/source/size/epoch bindings. Missing, legacy,
changed, completed or inapplicable evidence fails closed; never backfill or
upgrade evidence on replay. Preserve normal binary replay behavior.

## Genuine finalization with atomic text completion

Keep actual verification, stage envelope, reservation, stat/hash/wrapper,
canonical object publication/reuse, dedup locks and acknowledgement unchanged.
Before any text finalization effects, independently lock/revalidate the pending
per-Asset evidence, immutable declaration/source and real stage/object size
binding. Preserve established lock order. Do not introduce a fresh grant-expiry
check after lawful consumed upload; current job authorization remains enforced.

On valid text, in the existing single acknowledgement transaction:
make the genuine object available and stage finalized; attach it to the Asset;
perform established available3 -> processing4 -> ready5 transitions; complete
honest text metadata with declared MIME, exact size, fixed validator version,
nil PDF/image fields and completion timestamp; rebuild Asset search; retain
accurate availability/completion audit events; record the genuine finalization
effect at ready revision5. Do not enqueue asset.metadata_requested or invent
metadata progress/custody checkpoints. No intermediate available/processing state
may commit. Any error rolls back metadata, projections, audits and effect together.

Binary uploads retain their existing available transition and metadata job path.
Inconsistent text evidence cannot silently fall back to that path. Finalization
replay uses the existing genuine receipt with entity_revision <= current Asset
revision, including lawful later lifecycle changes, not new pending-only checks.
Identical plain/Markdown bytes may reuse one real object while each Asset/version
retains its own declaration/metadata/source. Empty encrypted objects use the
normal writer envelope, never a special unencrypted representation.

## Fail-closed backup cut

Logical backups omit upload_grants and asset_stages, so newly reachable uploaded/
verified text cannot resume from an empty destination. Preserve frozen restore
and portable formats; do not substitute same-database crash recovery for backup
recovery. Add a private read-only EXISTS after the existing version-specific
canonical guard, before inventory/stream in BOTH snapshot_cut and records.
Use the same repeatable-read repository/cut for default2, explicit2 and explicit3.
Version1 remains unconditionally unsupported; existing canonical guards remain.

Reject requested-owner uploaded or verified Assets identified as text by any
durable source declaration, per-Asset metadata declaration or exact
upload_text_v1 marker. Missing metadata/stage/grant/receipt or verification
failure cannot evade the guard. No new locks, second freshness query, function,
grant or schema change. Only exact false admits; true returns existing
backup_unsupported, while query/malformed failures remain errors without content.

Open/grant-only staging is pre-seal and outside resumable-byte backup coverage.
Lawful pending_delete/deleted states must not reject solely for a retained marker;
old upload jobs become stale. Genuine text finalization commits ready/completed
atomically. Deterministic actual-transaction tests cover:
seal before cut rejects; seal after cut remains consistently pre-seal;
finalize before cut admits completed data; finalize after an in-flight cut still
rejects that old cut, while a new snapshot sees ready. Never wait on an old
snapshot or trust an earlier checked flag. Pin a real repeatable-read snapshot
using test SQL and existing separate native writer/worker connections, not a
production timing callback. A records-only test cut must be truthful and valid
on that same connection, not rejected by an earlier invalid-cut condition.

## Test-only native infrastructure ownership

Existing MigrationTestEnvironment owns all five named repositories, four also
listed by Runtime.Application. Do not start the Runtime application again over
those repositories. Extend test support only: ResourceOwner.start_infrastructure
accepts the acquired owner's original caller, sends a new request reference and
starts one unnamed supervisor inside that same owner via
MigrationTestEnvironment.start_owned_infrastructure. Record its exact PID
immediately; reject a second start. A startup failure replies on the new request
reference with its original error/exception, not the completed acquisition reply.

Cleanup stops that supervisor FIRST, before owned repositories, database-drain/
drop, root removal, configuration restoration and baseline restart. This includes
Oban's independently connected notifier. Preserve independent cleanup failures,
acknowledged receipts and the existing caller-death monitor. Keep open/0,1
defaults unchanged. No new production ownership or configuration protocol.

Acquire ResourceOwner with migration_pool_size2; verify live database bindings.
Bootstrap with actual BootstrapOwner/IdentityRepository/Argon2/KeyWrapper on the
already-running MigrationRepo under its existing transaction-local table-owner
role. Configure genuine authorization/custodian after acquisition. Use public
Runtime.Application.application_children, removing EXACTLY the four already-owned
repository module specs; retain every other real child, including Telemetry,
Outbox and Oban. Start through the owner, then public login/resolve/unlock/upload.
This witnesses genuine infrastructure, not registration of a second OTP Runtime
application. Source/destination repository ownership is sequential.

Reuse existing complete Runtime/Storage environment capture, including absent
versus present keys, plus baseline Runtime running state. Require unchanged
owned Repo PIDs at infrastructure startup; normal/raised/killed-caller and
partial-start-failure cleanup; infrastructure dead before Repo cleanup; no
notifier/database/root residue; initially-on/off baseline restoration; exact
configuration restoration and unrelated-resource preservation. Restarted baseline
processes need not retain old PIDs. Do not increase deadlines or weaken existing
lifecycle assertions.

## Verification and ownership

Characterize the old text/plain rejection and retain historical RED evidence.
Supersede that assertion only under this reviewed contract; retain strong
unsupported-format, binary magic, foreign-field, auth, limits, privacy and
lifecycle negatives. Assets.Download.describe and its private descriptor MIME
gates admit exactly the two new types with focused public download/descriptor
contracts; auth/range/read/audit behavior and DownloadLease remain unchanged.
Api-only admission cannot bypass this independent inner gate.
New pure contracts cover UTF8 partitions/EOF/NUL/signatures/
limits/byte preservation. Existing processes and protocols must remain intact.

Native positive evidence must use actual bootstrap/login/unlock, public Api
grant/upload, StageWriter, custody, verification/finalization, real UUID source/
object references and actual plaintext downloads. No fake owner keys, raw crypto
fixtures, source rebinding or fixture-only text metadata completion. Test-only
fault adapters/barriers may observe existing ports and transaction operations
without replacing the native positive witness or adding production hooks.

Required focused coverage: genuine empty/plain/Unicode/Markdown publication;
shared-object distinct declarations; all original bytes; source/search metadata;
missing/inconsistent marker, exact/no-upgrade replay; stale/wrong owner/epoch/
permission; atomic rollback at metadata/search/audit/effect; uncertain ack,
published-before-ack, retry/concurrent/final replay and abandoned-upload cleanup.
Test normal/exception/caller-death cleanup without increasing existing deadlines.
Negative malformed-state tests may corrupt only exact test-owned rows.

Required compatibility evidence includes both backup entrypoints/all supported
versions, all four actual snapshot barriers, empty/verification-failed/in-flight
states, missing-metadata fallback, exact-owner isolation and preseal/deletion.
Completed genuine Asset-only text must make a V2 backup to an empty destination,
then pass ordinary restore/search/source and actual original-byte observation.
Preserve V1 golden and binary owners; run the independent existing restore task.
This is not the later full native knowledge-V3 Task11 saga.

Use explicit nonoverlapping source ownership, parallel authoring only when
interfaces are fixed, parent-managed Native execution with all actors CLOSED.
Every Native/maintenance LIVE interval permits only exact-session polling and
commentary. Before/after: fresh exact source/pin/HEAD/index evidence, complete raw
EOF, natural closure and ordinary EMPTY residual query; no forced cleanup,
hidden filters, prewarm, timeout/data/assertion relaxation or source overlap.

Focused complete owners and retained regressions precede actual source SPEC
then NEW distinct fresh QUALITY and small local commits/clean handoff. Complete
permitted README verification remains required by the governing phase acceptance
plan; old Task10 PASS is not credited to changed source. E2E NOT RUN. Record every
failure and diagnose before repair; Sol default, Astra after two failed Sol
rounds or evidenced impasse, at least three bounded Astra attempts if necessary.

Task11's formal V3 saga amendment and Task12 remain dependent on qualified
prerequisite evidence. Task16 BOTH strict ALL-leases stay UNSATISFIED/UNWAIVED/
BLOCKED_DESIGN; no custody/lease workaround. No merge, push, version/tag/release,
deployment, production activation or production-data access.
