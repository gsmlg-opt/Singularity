# Phase 5 Task12 qualified logical V3 default selection

## Status and authority

The original design passed independent DESIGN SPEC and NEW distinct QUALITY
before planning commit e5c0915943214f9f6c7e0bbb650347203e5ac1bc and test-only RED.
The native V3 fixture-composition amendment passed independent SPEC and NEW
distinct QUALITY before planning commit f2e0899fa15bdf7b313d568ea9c23a05a4a8fe55.
The fresh large-import diagnostic amendment below is a review candidate;
independent SPEC then NEW distinct QUALITY must pass before instrumentation.
Task12 default writer/restore qualification has not passed.
Continuous local development authorization applies; no renewed routine human
approval is needed. E2E remains NOT RUN/manual-deferred and is not authorized.

Baseline branch codex/v0.2-phase-5-export-backup in
/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup.
Baseline HEAD e24b2b2b10f4bb2d21d7600ad8bdc2f931237d56 is the completed Task11
documentation handoff, parent/source 4a2e007649ab2d7c62aa72ee84bf1d2de0a93802.
Task11 all26 gates plus26 own ordinary posts and combined SOURCE SPEC/QUALITY
passed before six source commits; distinct documentation SPEC/QUALITY passed
before e24b2b2 and literal clean-handoff checks. Actual post-review receipt:
.devenv/phase5-task11-v3-task11-documentation-handoff-closure.json, SHA256
48a250ce5defba52410fbef62894d5fb5721611574a678da03296806f62e24b7.
The committed Task11 handoff is a snapshot; its later closure is supplied by
that actual receipt, not by rewriting its reviewed bytes to predict its verdict.

Master Task12 depends on Tasks8–11 and combined writer/restore qualification.
This design records the bounded selector transition after that dependency
closure. It does not accept Phase5, resolve portable export Task16, or authorize
Task17/18 to bypass their dependencies. Matching detailed plan:
docs/superpowers/plans/2026-10-18-singularity-v0.2-phase-5-task12-default-v3.md.

## 1. Inspected source and selected approach

At the Task11 baseline LogicalRecordCodec has @default_version2 and a literal2 default_version typespec.
Exporter.snapshot_cut/2 and records/2 separately hardcode2; explicit2/3 paths
already exist. The existing Task8 version-aware guard supports V3, retains the
one-argument V2 guard, and rejects all new V1/unknown/nil selections. Existing
V3 decoding, preflight, historical admission, restoration and integrity have
qualified together in Tasks9–11. No new guard or no-op migration is needed.

Recommended: switch the existing codec default/typespec to3 and have both
Exporter arity2 functions delegate to LogicalRecordCodec.default_version().
This keeps a single existing selector without new modules, flags or configuration.
The Runtime BackupVault interface, cut/bundle shape, crypto and role grants do
not change. Two alternatives are rejected: hardcoding3 in three separate
places preserves selector drift; a runtime opt-in flag or shadow exporter adds
unrequested configuration and would not qualify the real default path.

Source inspection also identifies deliberate legacy tests expressed through
implicit defaults. Preserve their V2 wire bytes,30-table vectors and assertions
by selecting version2 explicitly, not by globally changing expected2 to3.
Preserve Task1's old default2 characterization in its committed history and
Task11 qualified source hashes; amend only the current-default clauses now.

The legacy BackupConcurrencyTest cut fixture uses noncanonical object references
and lacks eligible envelopes. Existing V3 admission correctly rejects it; that
test remains an explicitV2 inventory/concurrency contract. This is a source-derived
compatibility consequence, not an executed failure or permission to weaken V3.

## 2. Required behavior and preserved boundaries

New codec default_version/tables/cut/row/object entrypoints select logical3 and
the exact38-table/367-column schema, including an owner with no Documents.
Explicit1/2 codecs, immutable V1/V2 schema modules and historical restore remain.
New V1 writers stay unconditionally denied for every Note-only shape and all
other callers; this is not limited to Document owners. ExplicitV2 writes retain
represented Note/history/conflict/tombstone positives and reject V3-only
canonical rows at BOTH snapshot_cut and records, live and tombstoned.
Unknown selections, invalid cuts and incomplete V3 graphs remain fail-closed.

No schema, migrations, grants, role attributes, runtime policy, capability,
keys, passwords, leases or crypto changes. Production canonical writes remain
closed. Existing strict unsupported V3 graph admission is reused, not disabled.
Do not alter released migrations, V1 authenticated golden bytes, V1/V2 schema
hashes, exactV3 wire goldens or any required assertion, tag, deadline or selection.

Vault/DownloadLease/KeyCustodian/RestoreIntegrityLease and Runtime BackupVault/
RestoreVault are frozen. There is no new frozen-substrate compatibility patch
in this task; all observation changes are knowledge test fixtures/owners.
Task16 BOTH strict ALL-leases remains UNSATISFIED/UNWAIVED/BLOCKED_DESIGN.
Task17 remains NOT GO; Task18 retains Tasks11/12/17 dependencies.
No merge/push/version bump/tag/release/workflow dispatch/deploy/activation/backfill.

## 3. Genuine default-path evidence

### Document graph

Keep KnowledgeBackupRestoreFixture.V3Exporter/V3JobHandler names to preserve
the existing dependency identity contract. Replace only the two explicit3
delegates with production arity2 snapshot_cut/records. The wrapper becomes
observation-only: its unchanged synchronous independent canonical capture
still observes the SAME actual worker transaction/snapshot, not a second export.
Keep the distinct backend, authenticated role,38-table/367-column independent
SQL projection, complete source/history/original inventory and manifest binding.

Replace obsolete default_backup_guard!/default_backup_error with
legacy_backup_guards!/legacy_backup_errors. On the same authorized WorkerRepo
repeatable-read connection obtain a truthful default cut, attach manifest_id,
then require BOTH snapshot_cut/3 and records/3 for each explicit1/2 to return
backup_unsupported. The result map is exactly %{1 => :backup_unsupported,
2 => :backup_unsupported}. Update only its two existing live/oracle consumers.
This preserves and strengthens explicit legacy denial; it does not fabricate
a default backup result. Actual publication still uses Api.request_backup,
the real job/crypto, sealed status and exactly one worker-cut observation.

Run the complete live owner and independent restore oracle after switching,
retaining UUID/canonical/mixed source references, real bytes/history/search,
late-corruption rejection, saga faults, sentinels and lifecycle/config restoration.

### No Document graph

NativeTextBackupRestoreLiveTest already creates four genuine text originals
through public Asset publication and requests a real production default backup.
Change its current default title/imported-version expectation toV3. Add only a
test-local contextful logical-verifier observer at the existing supported
BundleReader adapter seam; delegate every native init/handle_event/finish
result unchanged. After successful native finish, send only the reference-tagged
wire cut to the existing test observer, never row bodies or key material.
ObservedRestorer.import consumes/asserts that witness after successful genuine
authentication and BEFORE the unchanged real Restorer.import call:

    wire_cut.logical_version == 3
    wire_cut.manifest_id == input.cut.manifest_id
    wire_cut.vault_id == input.cut.vault_id
    length(wire_cut.table_count_vector) == 38
    Enum.drop(wire_cut.table_count_vector, 30) == List.duplicate(0, 8)

Imported.cut intentionally omits table_count_vector, so imported version alone
is insufficient. Native verifier still checks actual row counts against the
full signed vector; the observer does not replace its checks. This is an
authenticated wire-vector witness, not an independent SQL-content oracle.
Keep the Document graph's stronger independent same-cut SQL oracle separately.
No second authentication, replay preview/consumption, fake AEAD/lease, global
single-finish assumption, original-byte/identity relaxation or infrastructure
overlap is permitted. The original sequentially owned restore remains real.

### Native V3 fixture-composition amendment — observed candidate failure

The first four-semantic-line selector candidate passed the same30 pure contracts
and all51 Storage integration cases, but the complete52 Runtime cases retained
one failure: the no-Document native restore returned :invalid. Native282 ran the
exact original three-owner integration vector with seed215378, exited naturally2,
and its own ordinary post283 exited0/EMPTY. Full raw445lines/26169bytes SHA256
f70fa11822e4848dfd51b430deddff37d6d6109058b53c9c60d408b5d8cd1235 was read
through its footer. All other102 executed integration cases passed; this candidate
is FAIL, not combined qualification. The native test bytes were identical to RED.

Two disjoint read-only investigations found the native test restore_context
still binds search_rebuilder to the legacy Storage.Backup.IntegrityAudit, which
lacks verify_document_sources. Runtime.IntegrityAudit deliberately requires that
callback for EVERY logical3 cut, including zero Document rows, and returns
:invalid when this tuple adapter lacks arity4. The existing working Document
fixture instead binds Storage.Backup.KnowledgeIntegrityAudit with MigrationRepo;
it supplies genuine source verification and retains the legacy rebuild delegate.
This is source-supported attribution of Native282, not yet a controlled runtime
repair proof. No production empty-table defect was found or production fix justified.

Recommended repair: change only the native test's search_rebuilder value to
{Singularity.Storage.Backup.KnowledgeIntegrityAudit, MigrationRepo}. Keep its
original ciphertext/completion auditors, observer, genuine Restorer calls,
authenticated38-count witness, original bytes/identities and lifecycle assertions.
Do not bypass the V3 callback for zero Documents or add a fake callback. This is
one necessary test-fixture compatibility change inside an already-owned path;
the production transition remains exactly the four selector changes above.
After review, root runs the complete native owner with the same seed/WAE, its own
ordinary post and current integrity guard. Only focused GREEN can establish the
causal repair; then rerun the original three-owner vector and all complete gates.

### Large-import timeout — fresh bounded diagnostic amendment

The one-binding native fixture repair passed its complete one-test owner in
Native284, natural0, with own post285 natural0/EMPTY. The complete17-owner unit
route286 reported322 registered/64 executed/258 excluded, zero failures; its
own post287 was natural0/EMPTY. These are scoped results, not Task12 acceptance.
The complete integration route288 then reported Storage264 registered/205
executed/59 excluded/one failure and Runtime58 registered/53 executed/five
excluded/zero failures:258 executed, one failure,64 excluded overall. Native288
closed naturally2; own post289 closed0/EMPTY. Complete raw447lines/29767bytes,
SHA256282788d13da7e1878b6e8fc3c71cf5fc48ab84927a4f8dc0c2e3cb820c705f31,
was read unfiltered through its footer. No compiler warning was reported.

The sole failure is LogicalV3ImportTest's legal wire JSON/typed native row
beyond16MiB contract, at its unchanged60000ms test deadline. The captured stack
is waiting for KnowledgeFixtureResourceOwner.close from the destination
fixture's unconditional after. Source preparation and its wire/native-size,
literal114-row counts and38-digest assertions had returned. It is UNKNOWN
whether the destination callback returned or raised before cleanup; no claim
that import assertions passed, that cleanup alone is defective, or that an
environment problem caused this failure is supported. Source inspection found
no implicit-selector dependency explaining this already-explicitV3 path.

Recommended next step is one fresh diagnostic campaign, not a causal repair or
automatic repeat-until-green. Temporarily change ONLY
apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs.
Before editing, record its complete clean baseline SHA and an exact inverse
patch; preserve all existing expressions, assertions, input sizes, deadlines,
tags, ordering and resource ownership. No shared fixture, resource-owner,
MigrationTestEnvironment or production change is authorized by this diagnostic.

Wrap only the failing test's existing source preparation and destination call
with test-local observation. Use the EXISTING ResourceOwner.with_checkpoint/2
hook with separate fixed source/destination labels. Add fixed phase markers
before/after source preparation and callback entry, empty-check completion,
real import completion, full oracle completion, dimensions assertion completion,
and callback return or exception KIND. Re-raise the original kind/reason/stack
unchanged BEFORE the fixture's existing after cleanup. Observe the outer call
return/exception category separately; do not catch a timeout to convert it into
success or move any test/cleanup work outside the timed test.

Checkpoint callbacks send only fixed stage/phase atoms and monotonic elapsed
milliseconds to a test-local diagnostic writer without waiting. Never output
resources, PIDs, refs, paths, SQL, keys, rows, JSON, exception messages/reasons,
mailboxes, dictionaries or stack arguments. The writer monitors the test caller
and stops on caller death or the wrapper's normal/error completion; it neither
owns nor changes fixture cleanup. No sampling loop, arbitrary sleep, barrier,
deadline extension, signal, forced database drop or service change is permitted.
If existing stage evidence is insufficient, design a separately bounded next
observation instead of silently adding it to this allowance.

After actual independent SPEC then NEW distinct QUALITY, seal the temporary
17th source owner alongside all original24 current pins and every historical
row/frozen control. Root runs the WHOLE LogicalV3ImportTest with the existing
seed215378 and warnings-as-errors, direct approved route and its OWN ordinary
post; complete raw/footer and exact observed/excluded counts remain required.
Whether GREEN or FAIL, interpret actual phase evidence without inventing a
cause. Remove the temporary diagnostic by exact inverse and prove its original
SHA before final gates. A necessary causal repair requires a source-backed
amendment, failing characterization, independent review and relevant reruns;
do not increase60000ms, lower the large-input threshold, weaken assertions,
change test selection or classify this failure away. This independent issue
starts with zero failed causal repairs; successful native repair1 is unrelated.

## 4. Exact ownership and authority transition

Only the following16 existing source/test paths may change for this task:

- apps/singularity_storage/lib/singularity/storage/backup/logical_record_codec.ex
- apps/singularity_storage/lib/singularity/storage/backup/exporter.ex
- apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs
- apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs
- apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs
- apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs
- apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs
- apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs
- apps/singularity_storage/test/singularity/storage/backup_concurrency_test.exs
- apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs
- apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs
- apps/singularity_runtime/test/singularity/runtime/native_text_backup_restore_live_test.exs
- apps/singularity_runtime/test/support/knowledge_backup_restore_fixture.ex
- apps/singularity_runtime/test/support/knowledge_restore_oracle.ex
- apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs
- apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs

Runtime native Asset fixture, storage knowledge builders/resource owner,
canonical SQL oracle and restore task remain unchanged. Tests in frozen Vault
owners remain unchanged; relevant existing compatibility gates may run without
modifying them. The temporary17th owner above is diagnostic-only, restored
byte-for-byte before final qualification; it does not expand production scope.
Disjoint guidance/docs are parent-owned:

- AGENTS.md
- README.md
- docs/guide.md
- docs/deployment/docker.md
- docs/superpowers/specs/2026-10-11-singularity-v0.2-phase-5-export-backup-design.md
- docs/superpowers/plans/2026-10-11-singularity-v0.2-phase-5-export-backup.md
- docs/superpowers/specs/2026-10-18-singularity-v0.2-phase-5-task12-default-v3-design.md
- docs/superpowers/plans/2026-10-18-singularity-v0.2-phase-5-task12-default-v3.md
- docs/verification/2026-10-18-phase-5-task12-handoff.md (actual results only after execution)

Use the same exact active current statement in AGENTS/README/guide and their
literal architecture contracts once the combined default writer/restore gates
pass: New backups use logical V3 after combined writer and restore qualification.
Explicit V2 retains its fail-closed unsupported-canonical guard.
Master active plan/design receives the same current status and a Task12 link;
historical Task1/preparation/defaultV2 evidence stays expressly historical.
Retain every other active-prose/heading mutation test and publication/freeze/
production-write exclusion. Update Docker upgrade instructions to describe
current logical3 and historical1/2 read compatibility without equating logical
backup with an operator's PostgreSQL/filesystem recovery snapshot or acceptance.

Task11 original qualification guard and all historical manifests remain intact.
The fixed fed04/status guard and fixed4a2/docs guard are now historical, not
postcommit GO. Preserve all1860 old rows unfiltered: Task11's six doc transitions
remain explicit, and additional Task12 owner transitions are named/checked, not
silently rebaselined. Frozen56 must still match exactly. Native text qualification
controls permit ONLY the named Task12 deltas for Exporter, LogicalExporterTest,
NativeTextBackupRestoreLiveTest and AGENTS; all other rows stay exact.
Root seals a new Task12 current source/doc/status/HEAD manifest and explicit
transition ledger per RED/GREEN stage. Any unexpected delta is diagnosed before
a new seal, never accepted by filtering a historical manifest.

## 5. Verification, review and closure

Use test-first RED on the current default2 source, then the four-line minimal
production selector transition. Add the real default path/38-vector contracts
before that production change. RED must be an assertion/expected default denial
caused by absent V3 selection, not compilation, invalid fixture or infrastructure.

Root alone launches exact direct commands through the unchanged approved
script --return/devenv/private PostgreSQL wrapper. Source/test writers and
reviewers close all commands before a VM starts. While LIVE root only polls
its owned session and reports progress; do not inspect/mutate or start other
commands/agents. Require natural closure, complete safe private raw through
footer, actual executed/excluded counts and SHA256. Every invocation has its
OWN fresh ordinary residual post, natural0/EMPTY, followed by source/frozen/
HEAD/index/status/owned0 checks. Failed or interrupted output is never PASS;
no fixed launcher deadline, automatic repeat-until-green or forced cleanup.

Run complete codec/schema/verifier/exporter/legacy/unified/concurrency owners,
both unit and integration routes for mixed selections, the complete live saga,
architecture owners, sole independent restore, format/devcompileWAE/xref0.
Exact vectors are in the plan. These are scoped Task12 gates; Task11's prior
26-row campaign is historical source qualification, not rerun on Task12 bytes.
The complete permitted README gate still precedes Phase5 acceptance.
E2E is NOT RUN, the sole explicit local deferral, and final browser/release
acceptance remains required. Do not add an automatic E2E trigger.

An ordinary failure enters evidence-driven diagnosis/repair within continuous
authority. Amend design/plan for a necessary compatibility repair. Two failed
Sol causal repair rounds or evidenced technical impasse escalate to Astra, with
at least three bounded Astra attempts if needed and permitted. Expected TDD RED,
design reviews and read-only typos are not failed causal repair rounds.
Internal upstream blockers follow issue routing; no silent blocking workaround.

After required GREEN gates obtain actual combined SOURCE SPEC then NEW distinct
QUALITY on complete changed sources/diffs and actual safe evidence. Only then
explicitly stage small local source commits. Record accurate command/results/
source hashes/commits and limitations; obtain distinct documentation SPEC then
NEW QUALITY before docs-only commit and literal clean-handoff checks.
Do not predict a review/commit in its own candidate bytes. A named ignored
post-review closure supplies later facts without self-mutating reviewed docs.
Task12 local closure is not Phase5 or release/browser acceptance.
