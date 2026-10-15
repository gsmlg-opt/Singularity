# Phase 5 native-text ingestion prerequisite implementation plan

> Use subagent-driven-development, test-driven-development, systematic-debugging,
> and verification-before-completion. Designs and actual source require
> independent SPEC then NEW distinct fresh QUALITY. Unchecked means not done.

Design: docs/superpowers/specs/2026-10-15-singularity-v0.2-phase-5-native-text-ingestion-design.md.
Goal: genuinely publish empty/plain/Unicode/Markdown originals through native
authenticated upload without touching frozen metadata/custody protocols, while
new unsupported in-flight backup cuts fail closed. This is Task11 prerequisite
work, not full native knowledge-V3 acceptance.

Progress: design v2 passed independent SPEC and NEW distinct fresh QUALITY.
Implementation, focused qualification and actual independent source SPEC then
NEW distinct fresh QUALITY are complete. Four local code commits end at
`5f388ac88d5603b8c29df3a592d0843885a30912`; documentation reviews and final clean
handoff have their own closure requirements below. Final native generation
passed all15 genuine scenarios, including original-byte downloads,
producer-disconnect cleanup, six
live authorization refusals, four actual snapshot boundaries and ordinary
default-V2 restore to an empty destination. Retained regressions passed164
Ingest/Runtime unit tests,29 Storage unit tests and265 integration tests, with
route exclusions counted separately. The sole independent restore task passed
V1/V2 restore and rebuilt Note search3/3. Format, warnings-as-errors compilation
and xref zero-cycle checks passed. See
../../verification/2026-10-15-phase-5-native-text-prerequisite.md for exact
commands, generations, failures, repairs and evidence. These are scoped results,
not Task11 or Phase5 acceptance. E2E NOT RUN; defaultV2 and frozen boundaries
remain unchanged.

## 0. Prerequisites, baseline and design review

- [x] Verify Task10's actual documentation SPEC/QUALITY, docs-only commits, unchanged
  qualified code/evidence and literal clean local handoff closure. Preserve all
  historical source/gate manifests; do not run old HEAD guards as current checks.
  Actual clean handoff94efb34ae128298ab62bfbd7b77d387b882bbb62; closure SHA256
  5ef1d71832ed4b3d59e3a6f9c6d227b672eccd07f1a56d3df31738dfc351151d.
- [x] Read current instructions and governing Phase5/Task11 requirements. Read
  the actual UploadRequest, UploadSession append/finish/checkpoint, Api/AcceptUpload,
  AssetRepository sealing/replay/finalization, metadata schema, Exporter and
  existing focused tests. Characterize the exact current text/plain rejection.
- [x] Self-review this bounded design/plan; independent design SPEC then NEW
  distinct fresh QUALITY. Correct actual findings before implementation.
- [x] Record baseline source commit, exact authorized-file before-images and
  fresh source/pin/HEAD/index controls for planned Native generations. New files
  cannot mask older inputs. Existing pins, privatePG and wrappers stay literal.
- [x] Fix internal validator/checkpoint interfaces before parallel source work.
  Ownership is nonoverlapping; workers preserve other edits and do not run Native.

## 1. RED: existing admission and complete-stream contracts

Owner A: apps/singularity_ingest/lib/singularity/ingest/upload_request.ex,
new upload_text.ex, upload_request_test.exs and new upload_text_test.exs under
the existing Ingest namespace/test directories.
Owner B: Api, Assets.AcceptUpload, Assets.UploadSession, the smallest
Assets.Download MIME allowlist compatibility, and their scoped Runtime tests
(including asset_download_test.exs). Parent owns Storage/backup/native integration,
existing test-only ResourceOwner/MigrationTestEnvironment lifecycle and evidence.

- [x] Add focused UploadRequest contracts for exactly text/plain and text/markdown,
  honest zero size, min(existing maximum,67108864) and declaration immutability.
  Preserve/supersede only the reviewed old text/plain rejection; keep unsupported
  application/octet-stream/Office/other types, binary magic, foreign fields,
  configured smaller limits and existing filename/idempotency contracts.
- [x] Add validator contracts for all valid boundary codepoints and arbitrary
  partitions; BOM/CRLF/decomposed text/whitespace/empty; overlong, surrogate,
  >Unicode, stray continuation, late malformed, NUL and incomplete EOF. Split
  conflicting signatures reject, incomplete PDF prefix EOF remains text.
- [x] Add Runtime declaration/DTO/begin-upload bound cases and complete-stream
  append/finish tests: late invalid bytes after valid first chunk, split Unicode,
  empty EOF, exact/wrong length, lower configured ceiling and genuine cleanup.
  Preserve binary reducer/suspension/ACK/deadline/expiry/owner-death contracts.
- [x] Add inner Download.describe/public download contracts for exactly the two
  new MIME types. Retain binary/octet-stream/unsupported/auth/range negatives;
  no DownloadLease or download authorization/read/audit protocol change.
- [x] Parent seals exact selected first RED route/line and fresh raw path, then
  runs focused old-behavior admission assertions through pinned wrappers. The
  expected unsupported-media assertion failure is RED, not a compiler/setup or
  unrelated failure. Record exclusions and real executed counts, complete EOF,
  source/pin controls and ordinary EMPTY residual before/after.

## 2. Implement pure admission and native streaming

- [x] Owner A implements numeric-state UploadText.new/0, append/2, finish/1 and
  exact UploadRequest declarations/effective text limit. Keep detect_media_type
  a binary detector; validate_magic on a complete text value uses full validation.
- [x] Owner B integrates every text append BEFORE binary media_validated bypass;
  validate EOF and exact size before actual writer finish. Preserve bytes and
  existing process ownership, timers, suspension, writer ACK/recovery and errors.
- [x] Extend only necessary Api/AcceptUpload declaration and safe summary/grant/
  download compatibility, including the independent Assets.Download MIME gates.
  Preserve its auth/range/read/audit protocol and DownloadLease. DTO structs
  already permit strings; do not edit them merely for an allowlist change.
  Independent admission enforces the text bound.
- [x] Derive internal upload_text_v1 only after successful text EOF and genuine
  writer seal, absent on binaries. Public caller fields/metadata/marker remain
  rejected. Preserve all real stage/grant/session/source/size/digest bindings.
- [x] Parent formats/checks these focused owners and runs complete unit owners
  through exact reviewed routes. No runtime SQL while another actor is active.
  Diagnose actual failures; do not delete/relax old or new assertions.

## 3. RED -> GREEN: sealed evidence and atomic text finalization

Owner C (assigned after A/B dependency authoring closes, or parent):
Storage.Postgres.AssetRepository and its existing scoped integration owners.
Native helper/test files are parent-owned, including new
Runtime.NativeAssetFixture test support and native_text_ingestion_live_test.exs.

- [x] Compose test-owned disposable native infrastructure from public
  BootstrapOwner/Login/ResolveSession/UnlockVault and actual production adapters,
  borrowing established oracle context shapes but not its private helper calls,
  intercepted RNG, extracted keys or synthetic publication helpers. Source and
  destination globally named Repos must be owned/switched sequentially.
- [x] Add test-only ResourceOwner.start_infrastructure(owner, children), callable
  only by its original acquired caller. Owner starts one unnamed supervisor via
  MigrationTestEnvironment.start_owned_infrastructure and records its exact PID
  immediately. Reject second start; use a NEW request reference for startup
  success/error/exception replies. Keep open/0,1 defaults unchanged.
- [x] Stop that supervisor FIRST during normal/raised/caller-death cleanup,
  before owned Repos/drain/drop/root/config/baseline restart. Preserve independent
  cleanup failure receipts and existing caller monitor; notifier connection must
  be dead before database-drain checking, not a late before-drop callback.
- [x] On already-running owned MigrationRepo, bootstrap real identity/wrapping
  under transaction-local table-owner role. Configure genuine auth/custody after
  acquisition, take public Runtime.Application.application_children and remove
  EXACTLY the four already-owned Repo specs, retaining all other real children.
  Start via owner, then public login/resolve/unlock/upload; verify Repo PIDs and
  database bindings unchanged. Do not claim a second OTP application started.
- [x] Extend existing knowledge_fixture_lifecycle_test: normal/raise/killed caller,
  partial startup failure/new-reference reply, exact supervisor dead BEFORE Repo
  cleanup, no notifier/database/root residue, environment absent/present exact
  restoration, baseline Runtime initially-on/off and unrelated resource safety.
  Preserve existing deadlines and assertions; real authenticated upload proves
  genuine composition, not merely a synthetic child supervisor.
- [x] Add native text publication assertion with real Api grants/UploadSession/
  StageWriter, real UUIDs, actual Outbox dispatch/manual Oban verify/finalize and
  real authorization. Retain RED when the current repository yields old
  available/pending behavior instead of ready/completed/no-metadata-job. Do not
  replace this with test-created completed text metadata.
- [x] At real seal, validate internal evidence and store pending marker atomically.
  Add exact locked replay checks; no nil/legacy marker backfill. Keep binary
  sealing/replay behavior literal. Missing/inconsistent/foreign proof fails.
- [x] Independently lock/check text pending metadata/source/stage/grant/size before
  finalization effects, respecting existing lock order and lawful consumed-grant
  semantics (no newly imposed expiry). No fallback to binary metadata work.
- [x] Keep actual reserve/publish/reuse/stat/hash/wrapper/acknowledgement. In one
  transaction make available, finalize stage, attach object and perform existing
  transitions3->4->5; complete honest text metadata/search/audits and the genuine
  finalization receipt5. No metadata outbox/progress/checkpoint fabrication.
- [x] Test transactional failures at metadata/search/audit/effect, published-before-
  ack/uncertain ack, retry/concurrent replay and receipt<=laterrevision. Use
  test-only existing adapter/repository observation, not production hooks.
- [x] Test genuine empty/plain/Unicode/Markdown and same-bytes plain/Markdown
  shared-object dedup with independent declarations/metadata. Actual downloaded
  originals equal inputs byte-for-byte; real source/search/listing DTOs agree.
- [x] Test wrong owner/epoch/capability/classification, missing/inconsistent
  evidence, malformed late data, abandoned upload and normal/error/caller-death
  cleanup. Negative mutation is limited to exact test-owned rows.
- [x] Parent runs complete changed owners and existing native verification/
  finalization/upload-reconciliation regressions, all assertions/deadlines kept.

## 4. RED -> GREEN: read-only unsupported text backup guard

Parent/independent nonoverlapping owner: Backup.Exporter, focused Storage
logical_exporter tests, and native Runtime guard/cut scenarios.

- [x] Add deterministic actual uploaded/verified text cut refusals for default2,
  explicit2 and explicit3, BOTH snapshot_cut and records. Current unguarded
  behavior must produce a focused assertion RED, not invalid-cut/role/setup error.
- [x] For records-only checks build a truthful valid logical cut on the SAME
  connection/snapshot/owner/highwater/inventory using existing test support shape.
  Keep existing canonical guard privilege/error contracts and version1 denials.
- [x] Add private read-only EXISTS AFTER existing canonical guard, before
  inventory/stream; requested-owner uploaded/verified text by source OR metadata
  declaration OR marker. Missing metadata/stage/grant/receipt cannot evade.
  Exact false only admits; true unsupported; query/malformed errors remain errors.
- [x] Cover empty, failed verification, reserved and published-before-ack; missing
  metadata fallback, exact-owner isolation, preseal versus lawful deletion and
  preserved binary behavior. Invalid-state corruption is negative evidence only,
  never a native positive original/publication witness.
- [x] Implement four deterministic real snapshot barriers without production
  hooks: pin RR snapshot, commit actual seal/finalize from native connections,
  then inspect the old cut and a new transaction. Assert before/after outcomes
  and no stale-snapshot wait/second-connection freshness leak.
- [x] Parent runs complete guard/native-cut owners with source/role/cleanup proof.

## 5. Real completed Asset-only V2 compatibility

Parent-owned new native_text_backup_restore_live_test.exs and bounded native
test support; independent existing restore oracle remains unchanged.

- [x] Make completed genuine empty/plain/Unicode/Markdown originals and real
  Asset-only V2 backup through the actual public default, independently observing
  logical version2, with actual wrappers/custody/jobs.
  Capture pre-cut source/Asset/object identities and plaintext bytes.
- [x] Switch named repository/environment ownership sequentially to genuinely
  empty disposable destination; run public ordinary RestoreVault composition.
  Preserve native authentication/import/rewrap/integrity/reconcile/complete order.
- [x] After normal destination login/unlock, verify source/metadata/search and
  actual plaintext bytes for EVERY original. No hash-only byte-equality claim.
  Keep completed receipt replay and per-Asset declaration semantics.
- [x] Retain V1 golden/V2 assertions and complete binary upload/metadata owners;
  run the independent existing mix singularity.test.restore task. Its PASS does
  not substitute the new native text roundtrip or later full knowledge-V3 saga.

## 6. Qualification, review and handoff

- [x] Maintain exact per-run argv/logger, fresh raw paths, immutable before-images/
  generations and natural EOF/source/pin/HEAD/index/EMPTY-cleanup evidence.
  During every Native/maintenance LIVE interval, ALL other agents/commands are
  CLOSED; only exact-session polling/commentary. No hidden filtering/prewarm,
  forced cleanup, timeout/data/assertion relaxation, lease/default or pin change.
- [x] Focused complete owners, retained regressions and genuine V2 compatibility
  must PASS. Record failures and diagnosis/repair counters honestly. Sol default;
  Astra only after two failed Sol rounds/same defect or evidenced impasse, with
  at least three bounded attempts when required. Architecture advice separate.
- [x] Actual source SPEC then NEW distinct fresh QUALITY read full changed files/
  diffs and actual Native evidence. Correct findings and rerun affected gates;
  never credit old Task10 PASS to changed source.
- [x] Record exact commands/counts/hashes/changed paths, zero migrations unless a
  separately designed necessary delta, residual risk and no Vault feature work.
  Four explicit local code commits preserve all26 reg1 code hashes and all25
  common native-GREEN5 hashes. Actual source reviewers are
  `/root/task11_native_text_actual_spec` and the NEW distinct
  `/root/task11_native_text_actual_quality`, both CLOSED PASS.
- [ ] Final documentation SPEC then NEW distinct fresh QUALITY, explicit local
  documentation commit and literal clean handoff must close separately. The
  ignored immutable handoff receipt records their actual identities and SHA,
  unchanged code/control/document hashes, empty index/status and no publication;
  do not mark this obligation complete from the documentation text alone.
- [ ] Complete permitted README gate before phase acceptance per governing plan;
  no premature Task11/12/Phase5 acceptance. Next write/review/execute Task11's
  native knowledge-V3 saga design/plan, preserving all retry/failure obligations
  and distinguishing supported continuation from restart of a new destination.
  Task12's writer default remains gated on combined Tasks8–11 GREEN.
- [ ] E2E NOT RUN. Task16 BOTH strict ALL-leases remains UNSATISFIED/UNWAIVED/
  BLOCKED_DESIGN. No merge/push/version/tag/release/deploy/production/data changes.
