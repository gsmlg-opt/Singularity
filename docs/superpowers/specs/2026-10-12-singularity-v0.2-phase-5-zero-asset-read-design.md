# Phase 5 Task 14 zero-byte Asset request-read composition

Status: proposed bounded caller-only amendment. Actual independent nonauthor
SOURCE SPEC and distinct fresh QUALITY must pass before Task14 authoring.
Task13 must qualify first. Continuing development authority selects the
recommended approach; it does not waive source review or live validation.

## Purpose and actual source evidence

Task14 must retain every included original, including valid empty Assets.
The master design/plan prohibit eager `:all` reads. Existing
`Storage.AuthenticatedReader.valid_range?/2` requires last < plaintext size:
no Range is valid for size0. The frozen `:all` path with chunk_count0 reads
no data records, authenticates the final record and checks empty size/count/
SHA256. Canonical format1 has header66 plus final68 = ciphertext134 bytes.
The Document-only empty authentication APIs must remain Document-only.

The frozen Asset request contains AssetID/objectID/object generation and
session epochs, not an expected-size constraint. KeyCustodian material loading
uses its own real scoped repository and reloads object sizes. A stale captured
zero size, a previous SQL check, or a post-read length assertion cannot prevent
a concurrent association/object change from causing a nonempty eager read.

Actual evidence:

- `runtime/assets/download.ex:163-211,258-333,438-480` passes an ORIGINAL
  callback through the existing `:operation_scope` adapter and retains real
  AssetRepository selection, custodian leasing, authenticated read and audit.
- `storage/scoped_repo.ex:25-48` rejects pre-existing request GUCs; do not
  surround this operation with a separate nested scoped transaction.
- `storage/postgres/asset_repository.ex:989-1048` selects exactly a/o/e/dv,
  returns one candidate only, and denies two eligible envelope candidates.
  `lock_job_asset/2` locks Asset first; follow this order.
- `storage/postgres/custody_repository.ex:375-427` reloads exact object and
  generation through envelope/object/domain-version/domain joins.
- Released `20260718000600` already grants runtime SELECT/UPDATE and owner RLS
  on Assets, objects, envelopes and domain versions. No grant or DDL expansion
  is needed for their real FOR SHARE locks.
- `storage/authenticated_reader.ex:251-305` and `crypto/format.ex:14-22`
  establish zero layout/final authentication. Existing local storage open also
  verifies the complete captured ciphertext hash; retain that check.

This is a source-backed feasibility argument, not successful live execution.

## Alternatives and selected boundary

1. Recommended: fixed NEW knowledge caller operation-scope wrapper delegates
   real OperationScope, locks/rechecks exact binding within each actual
   authorized transaction, then invokes the ORIGINAL Asset callback unchanged.
   A strict zero-only gate permits existing `:all` for this canonical empty
   layout. Nonempty requests use bounded Range only.
2. A preflight query or object-only lock leaves the Asset association race and
   separate custodian reload unsafe. A check after reading is too late.
3. A new custody/lease expected-size flag, key-bearing reader, worker authority,
   RestoreIntegrityLease or frozen infrastructure change is not authorized.

The sole master-contract exception is `:all` for the fully locked,
independently revalidated canonical zero-byte Asset described here. It is not
an eager nonempty download exemption, new public option or quota override.

## Exact caller composition

`Runtime.Knowledge.ExportRead.asset/3` accepts only the private captured
binding obtained from the sealed snapshot, plus authenticated runtime/session.
It rejects an already-open caller RequestRepo transaction and mismatched or
malformed captured identity. Scope derives from the actual session/authorization,
not a caller-selected owner or merely captured owner metadata.

Construct a fixed internal adapter `{ExportRead.AssetScope, context}` in the
private runtime map used only by the existing Assets.Download invocation.
Its `with_read_request(context, runtime, session, requirement, callback)`
delegates to real `OperationScope.with_read_request/4`. Inside the delegated
authorized transaction, call new
`Storage.KnowledgeExport.Repository.lock_asset_source(repo,binding,mode)`,
then invoke `callback.(repo)` unchanged. mode is fixed internally to
`:zero` or a validated Range, never caller-configurable.

Do not replace AssetRepository, Authorize, the actual audit sink, custodian,
reader or frozen callback result. Do not expose the wrapper through product
configuration or accept request-selected adapters. Existing trusted runtime
configuration remains trusted and intact, except this private fixed composition.
Discovery and classification reauthorization must EACH rerun the exact guard
inside their own actual transaction; the wrapper cannot authorize classification
itself. Any authorization/audit/storage error propagates unchanged.

## Locks and independently revalidated binding

Acquire FOR SHARE locks in this order on the actual authorized RequestRepo:

1. Exact `content.assets a` first. Match captured AssetID, actual owner,
   classification, eligible state and captured object association. Hold the
   Asset-to-object relationship through the original callback and COMMIT.
2. Exact `content.asset_objects o`. Match actual owner/classification/domain,
   available lifecycle, object UUID, original sizes, format, lookup digest,
   ciphertext hash and literal stored reference to the captured binding.
3. The one actual eligible `content.asset_key_envelopes e` and its active
   `core.domain_key_versions dv`. Match owner/object/domain/classification,
   domain-version ID, object generation and domain generation. Lock the actual
   selected rows, reject absent/ambiguous results and recheck all joins after
   locks. Do not assume predicate/gap locking.

For zero mode require captured AND independently loaded plaintext size0,
format1, ciphertext size134; the captured plaintext SHA remains pending until
the actual empty authentication. All original hash/storage evidence must match.
The exact version/resource/Asset association and live resource remain required;
revalidate immutable source provenance/liveness at completion without following
a newer head. Binding metadata is not authority.

The Asset-first lock is essential: object-only locks allow the frozen original
callback to follow a concurrently changed `a.asset_object_id` into a different
nonempty object. Holding the selected envelope/domain-version keeps that exact
candidate eligible. A newly inserted second eligible envelope causes the
existing two-row AssetRepository integrity denial before leasing; never select
the newest candidate. Separate custody reads may fail because a key-domain
changes, but cannot turn the locked object's zero layout into a nonempty one.
No key-domain policy/state, key loader or key material is changed.

Hold every row lock through actual original Asset selection, custodian material
loading, DownloadLease authentication/revalidation, actual audit and SQL COMMIT.
Normal error/rollback/closure releases them and request GUCs. A prior RR capture
is not this live locked proof. Arbitrary object metadata immutability must not
be assumed: the owning tests exercise real concurrent UPDATE attempts.

## Read bounds and original authentication

Only locked zero mode calls unchanged Assets.Download.run with `:all`; require
actual authenticated result `{:ok, ""}`. Canonical header/final AEAD and complete
ciphertext hash authentication remain mandatory. Nonempty Assets use positive
Ranges returning at most65536 plaintext bytes and never `:all`, including
preflight, retries and completion. Existing crypto record alignment remains
unchanged; Range authentication can read a full existing 4MiB AEAD record
internally, not the whole corpus. No new 64KiB cipher-format assumption.

Exact Documents keep the existing request document_source purpose/access,
exact historical version and Document-specific empty authentication. This
amendment does not alter Document custody or its chunk protocol. Export delivery/
writer still emits at most64KiB plaintext chunks; existing bounded AEAD records
must not be mistaken for eager corpus reads. Task14 implementation must preserve
the master digest/preflight/completion, revocation and cleanup requirements.

## Required owning tests

Use real local SQL, actual runtime-role connections, real resolver/authorization,
original callback, genuine existing key wrappers/KeyCustodian/DownloadLease,
real encrypted empty format1 object, actual LocalFilesystemAdapter and audit.
The existing metadata-only Task13 fixture cannot prove authenticated originals.

1. Authenticated empty Asset success reaches real audit and COMMIT, matches exact
   pin and empty SHA256, and a keyless delegate observer sees header/final reads
   but no data-record read. Fake callbacks prove wiring only.
2. An already committed changed Asset association or changed object size/hash/
   layout before the guard denies before leasing or reading.
3. A deterministic barrier AFTER all binding checks/locks but BEFORE the
   ORIGINAL callback's actual AssetRepository selection lets a second
   runtime-role transaction attempt Asset
   reassociation to a genuine nonempty object. With bounded LOCAL lock_timeout,
   the actual UPDATE returns SQLSTATE55P03; original association remains intact.
4. A barrier through actual custodian loading/read proves object-size/identity
   and selected envelope/domain-version mutations cannot succeed while locks
   remain. Observe genuine blocked UPDATE/55P03, not a sleep or fake error.
   Preserve connection/backend identities, GUC and transaction witnesses.
5. A real additional eligible envelope yields the existing multiple-candidate
   denial before lease; no forced generation/newest-row selection.
6. Final-record corruption, revoked authorization/unlock loss, read/audit/COMMIT
   failure and cleanup propagate actual failures, publish no artifact and release
   GUCs/locks. After closure the previously blocked writer can proceed, proving
   ownership release. Include existing nonempty bounded Range regression.

No weakened assertions, skipped gates, arbitrary sleep, raised default timeout,
after-nonempty-read guard or synthetic blocked-writer claim is allowed.

## Acceptance and restrictions

Author only the NEW ExportRead owning files and new exact source-binding methods
in Task13 Repository after Task13 qualifies and both design reviews pass. Add no
migration, grant, frozen custody/lease/key/crypto change or new public option.
Parent alone formats/runs complete pure and live owning file sets, archives
full output/exact counts/source/frozen hashes/database/root cleanup, and obtains
actual final nonauthor SOURCE SPEC then distinct fresh QUALITY before the small
local Task14 commit. Ordinary failures enter Sol diagnosis/repair; escalate under
the repository's cumulative two-failed-Sol/evidenced-impasse rule.

E2E NOT RUN/manual-only. Live isolated SQL/custody contract tests are not browser
or release-artifact E2E, and do not establish browser/release/production
acceptance. No publication, deployment, activation, backfill or production data.
