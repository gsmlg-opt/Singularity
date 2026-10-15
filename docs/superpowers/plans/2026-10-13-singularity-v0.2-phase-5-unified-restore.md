# Phase 5 Task 10 Unified Restore Implementation Plan

> **For agentic workers:** Use the executing-plans skill task by task under
> parent-managed ownership. After explicit GO, two disjoint implementation
> chunks may run in parallel; native operations and dependent gates are serial.
> Checkboxes record evidence, not anticipated success.

**Goal:** Rebuild complete V3 Asset/unified knowledge search and reconcile
Document work while preserving the restored cut and ordinary authenticated retry.

**Architecture:** Extend the existing KnowledgeIntegrityAudit facade and
Reconciler; add one forward migration replacing only the scanner, recovery and
retry functions plus one Document retirement constraint alternative. Keep Base,
Runtime APIs, existing worker adapters and all frozen sources unchanged.

**Tech Stack:** Existing Elixir/Ecto/PostgreSQL seven-application umbrella;
existing native integration harness, logical V3 fixture and WorkerRepo APIs.

Status: DESIGN REVIEWED — round 3 actual SPEC then NEW distinct fresh QUALITY
CLOSED PASS, no P1/P2. Prerequisite A.1 has complete Runtime2 GREEN and actual
SOURCE SPEC then NEW distinct fresh QUALITY CLOSED PASS, locally committed at
`47fabf1e3fcd4b1b149444c0c7d9bb4673b5ba81`. Whole B/C TaskH is now CLOSED
valid causal RED: 148 tests, 81 failures, 731.6s, exact archived source and
normal cleanup CLOSED/EMPTY. Parent GO now covers production D/E/F;
GREEN/downstream gates and actual source reviews remain required. Native receipts are parent-run,
not native checks run by the author.
Initial complete D/E/F native qualification is CLOSED FAIL: 148 tests, 6 failures,
781.0s. Continue only the evidenced bounded repair in
`2026-10-13-singularity-v0.2-phase-5-task10-contract-compatibility.md` and its
companion design; preserve historical RED and all remaining main gates.
First combined compatibility repair naturally CLOSED FAIL: 148 tests, 3 failures,
827.6s; actual SOURCE SPEC FAIL/P2x2. Bounded test-only repair attempt2 is drafted
in `2026-10-13-singularity-v0.2-phase-5-task10-native-denial-contract.md` and its
design, with independent design reviews required before test author GO. Only
post-denial pending-intent expectation and invalid column DELETE probe change;
all production/seven other sources, true security/canonical/storage denials,
downstream gates and final source review remain required.
Actual independent R2 DESIGN SPEC then NEW distinct fresh DESIGN QUALITY CLOSED
PASS/noP1P2; bounded Doc-test-only attempt2 followed verified design-only
commit2a7873b and actual author closure before parent format/compile. Whole H3
naturally CLOSED148tests0FAIL631.0s; repeated complete Runtime2 CLOSED10tests0FAIL
187.3s. Both maintenance EMPTY/exact roots absent/eight sources/frozen56/protected3
unchanged. Retained Base/Task9/Task8 whole pure/SQL and static/frozen checks
subsequently CLOSED PASS with actual exclusions recorded. Complete permitted
README/corrected actual SOURCE SPEC then NEW distinct fresh QUALITY remain
required. At that focused closure failed Sol1/Astra0 was unchanged;
parent native/Git remain prohibited while any test author is LIVE.

Complete permitted README integration subsequently naturally CLOSED FAIL:
session36198/exit2, Storage370FAIL and Runtime369FAIL (1831executed/739FAIL).
Normal final maintenance is NOTEMPTY: one exact test-owned orphan DB/root.
Current8/frozen56/protected3/locked13 remain unchanged. Earlier focused PASSs
remain scoped evidence, not full README or Task10 acceptance. Cumulative
combined failedSol2/AstraRepair0 now requires bounded Astra recovery1;
historical failedSol1 receipts and separate preparation counters are preserved.
The precisely scoped next amendment is
`2026-10-13-singularity-v0.2-phase-5-readme-compatibility-design.md` and its
companion plan. Actual DESIGN SPEC then NEW distinct fresh QUALITY CLOSED PASS;
docs-only commit1c1ca7f. Whole callback-kill RED2 naturally CLOSED exit2/1failure
15.2s, fullarchivee0ccc4c4/testsourceecd8d1bb. Exact owned recovery CLOSED/
maintenanceEMPTY, original cleanupFAIL preserved. Both source authors CLOSED.
Format/compile PASS; AstraR1lifecycle26/2+w warnings, R2lifecycle26/1/no priorwarnings;
failedSol2/failedAstra2. Exact residues recovered, originalcleanupFAIL retained.
Recovery3 permission cast wholefourownersPASS72/0, lifecycle DROP9sessionrace
proven by taskPGlog. Narrow design4.1/planC.1 actualamendmentSPEC thenNEWfreshQUALITY
CLOSED PASS before exacttwofile sourceGO; authorCLOSED/staticPASS/combinedseal208911e2.
Whole lifecycle27/0, permissionrepeat72/0, historicalwhole30/0 and unchangednative
sevenstate PASS; everypostEOF source/frozen/protected/locked/rootabsence/maintenance
EMPTY check PASS, no manualrecovery. Existingcharacterizationunusedaliaswarning
retained. RetainedH3/Runtime2/Base/Task9/Task8 whole pure/SQL and static gates
PASS on208911e2, actual exclusions recorded in compatibilityplan; allseals/
normalEMPTY. FirstfiveREADME/fullunit2082tests+10properties PASS; historical complete
unfiltered integration95548 naturally CLOSED FAIL/exit2, Storage1491executed/3FAIL,
Runtime373executed/18FAIL, total1864executed/21FAIL. PostEOF allseals/normalEMPTY
PASS; failedSol2/failedAstra3. Fournewowner amendment actualSPEC/freshQUALITY PASS
beforeboundedAstraRecovery4sourceGO, authorCLOSED/rootwholeinverses/staticPASS.
Current22source wholefournewowners172executed/0FAIL/43excluded; metadatautility
original7/7FAIL retained, reviewedrepair correctedwhole7/0/seven A_B_C_D markers.
Allseals/normalcleanup PASS. UnchangedwholeObserver16/0/11excluded notcause/waiver;
nextfull mustpass unchanged. Current22retained67316 naturallyCLOSEDexit0/all13
gates PASS at14:01:21UTC, raw6278e44c/closure6301244f/allseals/normalcleanup;
500SQL+84pure testexecutions/0FAIL plusactualsevenstates/staticzero cycles.
Current22completeREADME50083 naturallyCLOSEDexit2 at2026-10-13 16:03:40UTC:
firstsixgates PASS, integration1864executed/2historical60000msFAIL, Runtime373/0,
2092excludedincludingproperties NOTPASS. Fullraw28dcff3f/parent53ee8b47/closure
31e98728; allpostEOF seals/rootabsence/normalEMPTY PASS, gates8–15 NOTRUN.
OverallRecovery4failed, failedSol2/Astra4; cause/waits UNKNOWN, no waiver.
CompleteREADME GREEN/finalSOURCE outstanding; Task11/12 no Source GO.
No Task10/Phase5 acceptance or weakened Observer/Runtime/security assertion follows.
Subsequent ordinary seven-app diagnostic42661 naturally CLOSED0 at2026-10-13
19:36:03UTC:1864executed/0FAIL/2092excluded NOTPASS, raw8335138a/closure222df276,
allseals/normalcleanup PASS. Actual reviewed Astra utility attempt6 used no
owner/helper preload/source changes. Original targets59.315825s/59.820514s
approach unchanged60000ms; cause/waits/overhead UNKNOWN. Formatter-only diagnostic
does not supersede exact complete README FAIL. Next bounded causal measurement;
failedSol2/Astra4 unchanged, Task10/Phase5 NOT ACCEPTED, Task11/12 NO Source GO.
Supplementary receiver-auth design §7.1 now has actual round2 SPEC then NEW
distinct fresh QUALITY CLOSED PASS, no P1/P2. Parent test-only preparation GO
does not qualify the authored test or waive the whole TaskH gate.
Task 9F native PASS is reported
in `docs/verification/2026-10-13-phase-5-task9-compatibility-handoff.md`; the
parent reports actual SOURCE SPEC, distinct fresh SOURCE QUALITY and bounded
F commit `5619eccdbc2256c4c5aa702b653038fa57ada6fe` CLOSED PASS/CLOSED.
The subsequent complete Runtime2 baseline is CLOSED FAIL: 10 actual tests,
9 PASS, 1 FAIL, 185.7 seconds, exit 2. A.1 subsequently closes the stronger
reviewed prerequisite below. Historical FAIL remains FAIL, not Task 10 causal
RED. No GO follows merely from writing this plan.
Initial actual DESIGN SPEC and distinct fresh DESIGN QUALITY are CLOSED FAIL
on one shared P2: the earlier 0/1 reconcile-result restriction rejects valid
multi-fragment Documents. Round 2 actual SPEC is CLOSED PASS; the NEW distinct
fresh QUALITY is CLOSED FAIL on one P2: impossible returned-contract cases
need an explicit response-injection mechanism. Round 3 corrected actual SPEC
and another NEW distinct fresh QUALITY subsequently CLOSED PASS; earlier
FAILs and the separate round 2 SPEC PASS remain historical and unrelabeled.
Preserve actual receipts `.devenv/phase5-task10-design-spec-round1-final.md`
and `.devenv/phase5-task10-design-fresh-quality-review-round1.md`.
Preserve round 2 `.devenv/phase5-task10-design-spec-review-round2.md` and
`.devenv/phase5-task10-design-fresh-quality-review-round2.md`.
Round 3 actual receipt captures/hashes and four reviewed pre-bookkeeping
document hashes are recorded in the design's status section. Parent status
bookkeeping is not retroactively part of either independent review.
The initial lock-order concern was withdrawn after reviewing the latest released
`20261009000300_document_projection_events.exs` resource-before-version target;
do not add redundant retry prelocks or widen helper/frozen-source scope.

Design: `../specs/2026-10-13-singularity-v0.2-phase-5-unified-restore-design.md`.
Master: `2026-10-11-singularity-v0.2-phase-5-export-backup.md`, Task 10;
master design section 9 remains authoritative and unwaived.

Worktree: `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-5-export-backup`.
Branch: `codex/v0.2-phase-5-export-backup`.
Current local HEAD: `c98b4a6aad7516489b0615163340b225ea58a954` (separately
reviewed Task16 documentation only; no Task16 implementation GO or lease waiver;
accepted A.1 source baseline remains47fabf1).
Task 9F baseline: `5619eccdbc2256c4c5aa702b653038fa57ada6fe`.
Original preparation baseline: `9f91c97eb392b4c49c888ed31795d520d15bb8dd`.
The author read local HEAD, not reran parent native/review receipts. Recheck
exact source before gates; preserve all existing dirty/untracked ownership.

## Task A: Close prerequisites and freeze reviewed boundaries

Files: parent-owned master design/plan amendment and acceptance record;
this design/plan. No production edit is authorized by Task A.

- [x] Confirm F's exact tested fourteen-file source receipts, whole native
  outputs, normal cleanup, actual SOURCE SPEC then distinct fresh QUALITY PASS
  and bounded local commit. Record the new baseline and current diff. Stop an
  affected dependent task if source identity or F's required gate is unresolved.
- [x] Parent amends master section 9/Task 10 to name the additive `00800`
  migration and narrow native knowledge SQL semantic change. Preserve historical
  failed evidence and the unwaived authenticated ordinary-retry requirement.
  Include the sole prerequisite permission-case correction in A.1 and the
  unretired-native optional/reflected-V3 mandatory submission distinction in F.
- [x] Obtain independent DESIGN SPEC on both actual documents and master
  amendment, then distinct fresh DESIGN QUALITY. Record exact hashes and
  findings. Resolve design findings before test-authoring GO.
- [x] Review the parent-authorized pending-work extension in design section 6
  and the minimal master amendment: exact current event/submission validation,
  authenticated pending generation+1 retry, and no automatic wake/old event
  rewrite. Source lifecycle guard already permits generation-only
  pending-to-pending+1; no lifecycle-guard change is authorized or needed.
- [x] Parent verifies proposed native ETF vectors below before test-authoring
  GO. Record actual bytes/digests; mismatch requires repairing the proposal and
  review, never relabeling an unexecuted vector as verified.

```elixir
empty = :erlang.term_to_binary(%{assets: [], knowledge: []},
  [:deterministic, {:minor_version, 2}])
true = Base.encode16(empty, case: :lower) ==
  "83740000000277066173736574736a77096b6e6f776c656467656a"
true = Base.encode16(:crypto.hash(:sha256, empty), case: :lower) ==
  "4a29cf8e8bc7cc6ed0f147e2b94bcdee7a1dd0eadf55971d702f0f00e92331c6"
row = ["note:00000000-0000-4000-8000-000000000002", "note",
  "00000000-0000-4000-8000-000000000001",
  "00000000-0000-4000-8000-000000000002", nil, 0, "Alpha", "Beta",
  %{"version" => 1, "kind" => "markdown", "heading_path" => []},
  "2026-01-01T00:00:00.000000Z", "'alpha':1A 'beta':2"]
bytes = :erlang.term_to_binary(%{assets: [], knowledge: [row]},
  [:deterministic, {:minor_version, 2}])
true = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
  "83571fc40de7553cbf9504066d3a05bb1d73de1543d06f37fdd6ee2d19f2d0b0"
```

- [x] Freeze the original `.devenv/phase5-frozen-baseline.sha256`: 43 released
  migrations plus 13 sources. Do not regenerate it to absorb changes. Also
  preserve the original `.devenv/phase5-task10-protected-native-baseline.sha256`
  three-file Runtime2/Base receipt. Review the exact A.1 permission-case delta
  and a separate current receipt: inverse only that delta to reproduce the
  original recovery-file hash; restart and Base must match originals directly.
- [x] Parent characterizes whole existing Base/unified restore, Reconciler,
  Runtime integrity, extraction recovery/restart owners using commands in H.
  Require actual Base success with the genuine seven-state graph before using
  it as a precondition in new RED; new contracts must reach their intended seam.
- [x] Record all author/command closures. Only parent starts/stops its services;
  no author edits during any native operation. No global-env fixture concurrency.

### Task A.1: Close the narrowly authorized Runtime permission prerequisite

Own only the case `"recovery functions expose only narrow worker execution"`
in `apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs`.
No edits to its other cases, the restart file, production, grants, policies or
migrations. This is a separately reviewed prerequisite, not chunk B's new RED.
The documentation correction itself consumes no native Sol repair round.

- [x] Review exact current file and original case against released
  `20261011000500_knowledge_backup_read_grants.exs` lines 7–9 and the complete
  reviewed `2026-10-12-singularity-v0.2-phase-5-document-worker-read-contract`
  design/plan. Both Document tables legitimately have worker SELECT. Preserve
  the historical reached versions mismatch `[[true, true]]` versus expected
  `[[false, false]]`; fragments' equivalent grant is source evidence until its
  own native assertion is reached. Obtain precise test-contract GO separately.
- [x] Preserve all existing function metadata/owner/security-definer/fixed
  search-path/return/Public ACL, role-specific EXECUTE, table/column DML and
  private-function assertions. Preserve all nine other cases across Runtime2
  and the entire restart file byte-for-byte. Never simply invert SELECT booleans.
- [x] In this case seed actual same-owner and foreign-owner ready Documents
  with real fragments. As actual WorkerRepo prove table/column SELECT plus
  ENABLE/FORCE RLS on both tables. Under correct principal/owner GUCs compare
  exact same-owner version/fragment identities and immutable values/locators;
  assert foreign rows are invisible.
- [x] Independently prove both tables hide rows with missing principal, missing
  owner, mismatched principal/owner and revoked membership. Exercise actual
  existing GUC/membership RLS, not TableOwner reads or claimed session/epoch/
  custody security. Do not alter authorization policy to make a test pass.
- [x] For each table independently execute worker INSERT, UPDATE, DELETE and
  TRUNCATE; every reached statement must yield native SQLSTATE `42501` inside
  its own rollback boundary. A zero-row update is not permission proof. Check
  exact same/foreign row identities and values before/after all attempts.
- [x] Use one WorkerRepo checkout and assert same backend across normal scoped
  and explicit rollback transactions. Assert principal/owner GUC cleanup after
  each, and no access on subsequent unscoped reads. Preserve row identities.
- [x] Close authoring; parent alone runs the complete Runtime2 command in H,
  every case and the whole unchanged restart file. Record actual outcome and
  reached assertions, exact case diff/inverse preservation, original frozen56/
  protected3 history and independently reviewed current receipt. Obtain actual
  SOURCE SPEC then distinct fresh QUALITY for this prerequisite correction.
  Require whole Runtime2 GREEN before dependent Task 10 GO; preserve original
  FAIL and do not silently regenerate old receipts. No expected totals invented.

### A/A.1 actual prerequisite closure

Parent closed the stronger permission case at local single-file commit
`47fabf1e3fcd4b1b149444c0c7d9bb4673b5ba81`; no production or migration change.
Complete unfiltered Runtime2 command in H: 10 actual PASS, 0 failures, 185.8s,
exit0; session10348 CLOSED. Check-formatted session20045 CLOSED/exit0.
Normal maintenance EMPTY and exact root `e2884620935248d948f312e3` absent.
Actual nonauthor SOURCE SPEC and NEW distinct fresh QUALITY CLOSED PASS, no
P1/P2. Full commands, archives, hashes, inverses and historical failures are in
`docs/verification/2026-10-11-phase-5-acceptance.md`, A.1 closure section.

Original baseline9PASS/1FAIL and initial A.1 9PASS/1FAIL remain FAIL. Initial
authoring reached a locator map-versus-struct mismatch, so later adversarial
assertions were not reached in that run. Sol repair1 changes only that expected
cell to the independent literal native JSON map; corrected whole Runtime2
reaches the full stronger contract. Cumulative A.1 Sol repair1 GREEN/Astra0.
Neither failure nor prerequisite GREEN is Task10 feature causal RED.

Task9F source14 and original frozen56 directly match their preserved receipts.
Original Runtime2/Base protected3 remains historical; reversing only the owned
case reproduces the original recovery source, and restart/Base match directly.
Current source3 has its own explicit independently reviewed repair1 receipt.
ETF vectors, whole Base/Runtime pure68 actual PASS, existing Storage SQL27
actual PASS and genuine seven-state Base characterization are recorded in the
earlier preparation evidence. That Base probe reports combined projection
count1; it does not qualify B's independent two-Asset positive.

All prerequisite authors/native commands were CLOSED before the one-path
local commit; index empty afterward. Parent now gives TEST-ONLY B/C GO with
disjoint author ownership. Native operations remain serial after all authors
close. D/E/F production remains NO GO until whole causal RED and diagnostics.
E2E NOT RUN/manual-only; Task16 unwaived; no Phase5/publication acceptance.


## Task B: Author all causal RED contracts, then stop for parent execution

Own tests only:

- Modify `apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs`.
- Modify `apps/singularity_storage/test/singularity/storage/restore_reconciliation_test.exs`.
- Create `apps/singularity_storage/test/singularity/storage/backup/document_restore_reconciliation_test.exs`.

Do not change shared fixture sources, production or released migrations.

- [ ] Retain the existing Base Note characterization test and every V2
  unsupported-canonical test. Add V3 facade tests with a current ready Document
  containing at least two real canonical fragments,
  old ready version, deleted ready head, pending/extracting/failed/unsupported
  heads, a live and deleted Note and foreign-owner projections. Seed stale
  owner rows; include an extra stale row that canonical joins would hide.
- [ ] Build expected rows from canonical input values, with independently
  fixed Note/fragment IDs, locators, text, UTC timestamps and token strings.
  Compare all eleven columns and both six-column Asset rows/count/digest.
  Rebuild twice, compare exact results, all canonical history and foreign rows.
  Assert both fragment rows individually in full eleven-column form and retain
  the positive two-Asset six-column rows contract. Count actual projection rows,
  not resources. Do not use production SELECT or its digest as the expected
  oracle. The multi-fragment positive must reach successful rebuilding even
  when the native per-resource reconcile return is `[[2]]`.
- [ ] Add empty/single-Note native ETF literal assertions from A. Cover nil
  fragment IDs and every evidence field with a mutation witness; ensure Note
  rows are not double-counted via legacy note_search_documents.
- [ ] Add nested-entry denial and same-connection repeatable-read/TableOwner/
  owner-GUC evidence. Separate the THREE evidence paths in design section 3.1:
  genuine native multi-fragment success above, disposable native `-1`/late-SQL
  faults, and explicitly injected impossible returned-contract faults below.
- [ ] In the disposable test-owned database, separately reach native `-1` and
  a late SQL failure after real Base writes and owner unified-row deletion.
  Capture exact original installed definitions/metadata before arming any
  bounded test-only function-body fault. Preserve signatures, bigint return,
  owners, security modes, pinned search paths and ACLs throughout; never disable
  canonical/security guards or change grants/policies. Restore exact original
  definitions in `after` on every exit and verify original metadata/definitions.
  Native SQL failure covers the error path, not a malformed successful result.
- [ ] For malformed row/cell shape, noninteger and out-of-bigint-range variants,
  implement a test-LOCAL real-query-delegate-then-response-alter proxy only in
  these three owned Storage test files. Alias actual MigrationRepo metadata/
  pool with only `adapter_meta.sql` changed to the forwarding proxy; every repo
  operation/backend/checkout/transaction/rollback remains native. Keep SafeSQL
  and Base unchanged. Forward all SQL callbacks to the original native SQL
  module; execute the selected exact facade reconcile SQL/parameters FIRST,
  record the original native result, then substitute ONLY its returned contract.
  Leave all other queries/results/errors untouched. Fault state is process-local
  and the alias is test-owned, with no separate pool or fake transaction.
  SafeSQL→EctoSQL's installed sql.ex lines 684–697 dispatches this metadata SQL
  module on the native connection. Existing inventory-test RecordingRepo only
  aliases native metadata; it is NOT already a response proxy. Do not assume
  adding repo query/4 intercepts SafeSQL. No dependency/shared-helper/source
  change or production hook is authorized.
- [ ] Assert each fault/interception is actually reached AFTER real Base writes
  and owner search deletion. Independently snapshot pretransaction rows and
  record in-flight same native backend/TableOwner/repeatable-read/owner-GUC
  witnesses and actual derived rows proving changes. For response substitution
  record the successful native target result and real fragment inserts before
  altering it. For late SQL error witness before failing dispatch and record
  its native error; do not query an aborted transaction or invent a result.
  After the returned error and real outer rollback compare exact before/after
  all-owner projections, foreign projections and canonical/history rows.
  Cleanup native DB definitions, alias/registry/proxy/process fault state in
  `after` on every exit; verify original metadata/definitions and backend/GUC
  cleanup. Label impossible variants `INJECTED_CONTRACT_FAULT`: real SQL and
  rollback evidence, NOT PostgreSQL-generated malformed bigint output. Preserve
  the genuine >=2-fragment/two-Asset positive independently, with no injection.
- [ ] Add raw NULL-causation positive cases for extraction and each projection
  event, plus explicit UUID causation. Prove raw storage remains NULL and
  codec-facing fallback is event ID. Retain Note's existing malformed-nil
  contract unchanged. Reject wrong correlation/cause shape without codec edits.
- [ ] Add exactly four Document event mappings, exact two-key payload, capability,
  private/version-1, submission owner/job/key, creator/resource/version/revision/
  epochs and retirement-pair tests. Unknown event, extra key, wrong owner/type/
  creator/key/revision, malformed epoch and retired malformed variants must
  reach integrity rollback and preserve all earlier reset/retirement rows.
- [ ] Cover current pending wake once, deleted pending undispatched, all terminal
  extraction reflected, obsolete generation/head destructive and projection
  reconciliation against current final state. Reconcile twice and prove stable
  retirement timestamps and no extra wake/submission/successor.
- [ ] Add the genuine imported extracting-cut contracts from C, scanner/mutator/
  retry causal assertions from F and migration/security checks from G.
- [ ] Close test authors, record exact full-file hashes and parent-run **whole**
  RED commands from H. Record actual failures/exclusions. A compile error or
  earlier Base/import rejection is not evidence for a new provenance assertion.
  All required new causal failures must be explained before production GO.

Core snapshot assertion shape (test-local helpers described in C separately
read the full wire cut and canonical knowledge/history excluding derived work;
they are not new production interfaces):

```elixir
assert full_wire_cut_after_import == full_wire_cut_source
assert canonical_after_import == canonical_source
assert :ok = Reconciler.reconcile(MigrationRepo, restored_cut)
assert canonical_after_reconcile == canonical_source
assert :ok = Reconciler.reconcile(MigrationRepo, restored_cut)
assert canonical_after_repeat == canonical_source
assert {:ok, first} = KnowledgeIntegrityAudit.rebuild(MigrationRepo, binding)
assert actual_projection == expected_projection_from_fixture
assert {:ok, ^first} = KnowledgeIntegrityAudit.rebuild(MigrationRepo, binding)
assert actual_projection_after_repeat == expected_projection_from_fixture
```

## Task C: Construct the deterministic actual restored attempt fixture

File: the new `backup/document_restore_reconciliation_test.exs` only.
This task is part of B's test-only authorization and precedes production GO.

- [ ] Use `ExUnit.Case, async: false`, `@moduletag :integration` and a uniquely
  allocated private portable directory cleaned only by its test owner.
  Seed via `KnowledgeBackupFixtures.seed!` with the established seven-state
  IDs/originals pattern in document_restore_integrity_test. Reuse public
  `canonical_rows/1`, `source_bytes/1`, `verified_bundle/2` and
  `transformed_bundle/2`; keep test-local helpers in this new file.
- [ ] In the source's single `with_destination(:current, ...)`, obtain the
  complete source canonical rows, actual encrypted V3 replay bundle and binding.
  Copy `bundle.binding.destination_ref` from source object_root to portable
  storage before the source `after` cleanup; chmod the copied file 0600 and
  discard its source verified handle through `BundleReader.discard_verified/1`.
- [ ] Open receiver only after source environment closes. Prove distinct database
  and source-root absence, receiver canonical/saga empty, and Runtime periodic
  `Singularity.Runtime.Documents.ExtractionReconciler` absent. Start only the
  existing test-owned repositories needed by ordinary public APIs, with the
  harness credentials; restore every changed application configuration on exit.
- [ ] Authenticate actual bytes using `LocalDestination.reader_source/2`,
  `BundleReader.authenticate_all/2`, existing FixtureCrypto/LogicalBundleVerifier
  and exact binding. Import with `Restorer.import/3` into MigrationRepo; prove
  transaction COMMIT, authenticated logical_version 3, original nine-field
  object inventory, source equality and no dispatcher publication.
- [ ] Assert complete canonical source/receiver equality first, including all
  resource/version/Note/Document/fragment/attachment/citation/tag/relationship
  histories and import receipts. Compare actual claim generation 1, job UUID,
  fixed start/deadline, adapter/format, no extracting fragments, event revision 0,
  extraction submission/progress/effect receipt. Neither reconcile nor rebuild
  may change that canonical cut.
  Capture full imported wire rows separately for the first equality, including
  outbox/submissions/progress/receipts; after reconciliation compare unchanged
  canonical knowledge/history and exact expected derived-work changes.
- [ ] Qualify the narrowly scoped receiver authentication preparation in design
  section 7.1 after supplementary independent DESIGN SPEC/fresh QUALITY close.
  Round1 actual SPEC remains CLOSEDFAIL on the source identity-binding P2.
  BEFORE source seed/capture/export, use only test-local
  account_id==principal_id==vault_id matching unchanged PreAuth.owner_scope;
  preserve all knowledge/object/version IDs and assert the imported/native
  issued session binding. No receiver identity rewrite or sharedfixture/PreAuth
  change. Corrected round2 actual SPEC and NEW distinct fresh QUALITY CLOSED
  PASS; parent GO now covers only this reviewed test-local preparation. Native
  fixture/contracts remain unqualified until the parent whole TaskH command.
  FIRST prove complete wire-cut equality, source expired-session/receiver absence,
  imported dummy verifier, locked owner and restore-pending wrapper snapshots.
  Actual public login before preparation denies. Then change only the exact
  fixture credential's nonwire verifier to an existing real Argon2 hash and use
  real public login/resolve to issue and verify a fresh native session/token.
  Preserve and account for failed pre-auth/anonymous denied-audit and successful
  native attempt/session/login-audit effects; do not claim post-login wire equality.
  Actual public retry while the imported owner remains locked must deny without
  knowledge/work changes. Only afterward prepare the exact fixture locked bit
  false, comparing the sole wire-field delta and byte-identical wrappers/other
  authority fields. Custodian/session remain actually locked; no unlock, rewrap,
  keys, capabilities, synthetic session or Vault behavior/source changes.
  Public retry then traverses real Mutate/authorization/locks/RequestRepo.
  This is disposable fixture metadata qualification, not custody or production
  activation proof; preserve immutable history and explicit later causal deltas.
- [ ] After equality, read `attempt_deadline_at < clock_timestamp()` as an
  asserted actual barrier. Use the persisted fixed 2026-10-11 start/deadline,
  not a deadline UPDATE, artificial timeout failure, sleep or new clock API.
- [ ] A separate positive native fixture with genuine future deadline covers
  unexpired denial; it need not be the expired imported fixture or edit its cut.
- [ ] For the valid imported claim, assert derived retirement
  `restore_effect_already_reflected` without redispatching the old runner, then:

```elixir
context = %{repo: WorkerRepo}
assert {:ok, candidates} = DocumentRepository.list_expired_recovery_ids(context, 100)
assert {version_id, owner_id} in candidates
assert {:ok, true} =
  DocumentRepository.recover_expired_with_event(context, version_id, owner_id)
assert {:ok, false} =
  DocumentRepository.recover_expired_with_event(context, version_id, owner_id)
```

- [ ] Compare the complete postrecovery canonical delta: pending generation 2,
  cleared attempt fields, unchanged immutable source/head/history/fragments,
  exactly one normal successor with original creator/current epochs, revision 2,
  `document-extraction:<version>:2` and causation original attempt job UUID.
  The Storage test must not call Runtime's module; both whole Runtime owners
  separately qualify the same periodic algorithm and restart, with only the
  reviewed A.1 permission-case correction and byte-identical restart file.

## Task D: Implement unified facade rebuilding (chunk A)

Own only `backup/knowledge_integrity_audit.ex` and
`unified_search_restore_test.exs`; chunk B owns the other production/test paths.
Workers are not alone and must preserve Task 9E/other changes. Depends on whole
causal RED and explicit parent production GO. No shared fixture edits.

- [ ] Preserve `verify_document_sources/4` unchanged. Replace rebuild delegation
  with exact two-key canonical-UUID validation and fresh transaction entry;
  follow KnowledgeIntegrityInventory's established repeatable-read role/login/
  owner-GUC pattern. Reject `repo.in_transaction?()` before Base/deletion.
- [ ] Call unchanged Base inside the same transaction. Validate the complete
  SearchSummary shape/literal/count/32-byte digest; outer rollback on every
  error/malformed response. Do not rely on Base's transaction wrapper to roll
  back a returned error tuple.
- [ ] Select owner Note/Document UUIDs with stable `ORDER BY id`, then owner-only
  `DELETE FROM content.search_entries WHERE vault_id=$1`. Iterate these UUIDs
  with `SELECT content.reconcile_search_resource_internal($1,$2)` and require
  exactly `[[count]]`: one row, one integer cell, with
  `0 <= count <= 9223372036854775807`. Released `20261009000200` returns bigint
  inserted-fragment `ROW_COUNT`, not a resource-success boolean; permit valid
  `[[2]]` and higher counts. Reject `-1`, malformed shape/type and out-of-range
  values with complete outer rollback. Never use live definers/session authority.
- [ ] Read and validate exact Asset six/unified eleven rows using design section 4.
  Return the existing SearchSummary with the following evidence construction;
  Base's Note rows are intentionally excluded from this V3 summary:

```elixir
evidence = %{assets: asset_rows, knowledge: unified_rows}
{:ok, %IntegrityAudit.SearchSummary{
  projection: "postgres_metadata_v1",
  document_count: length(asset_rows) + length(unified_rows),
  result_sha256: :crypto.hash(:sha256,
    :erlang.term_to_binary(evidence, [:deterministic, {:minor_version, 2}]))
}}
```

- [ ] Sanitize errors; suppress content-bearing SQL/telemetry. Keep public type,
  Runtime validator and completion digest storage unchanged. Close author and
  report actual diff/hash to parent; parent runs H, not the chunk worker.

## Task E: Implement raw Document reconciliation (chunk B)

Own `backup/reconciler.ex`, new migration, existing
`restore_reconciliation_test.exs`, new
`backup/document_restore_reconciliation_test.exs`. Depends on whole causal RED
and parent production GO; may overlap D only with disjoint file ownership.

- [ ] Extend event_job_type/1 with exact Document extract/projection mapping.
  Put Document clauses before the existing generic retired shortcut. Keep the
  legacy event list/Note/Asset paths intact and all unknown-event denials.
- [ ] Load raw provenance and matching submission. Validate exact event/creator/
  owner/resource/version/private/capability/envelope/revision/key/epochs and raw
  correlation/optional-causation shape before state/retirement decisions.
  Use temporary JobEnvelope cause `raw_cause || event_id` only after validation,
  then unchanged EnvelopeCodec encode/decode. Persisted NULL stays NULL.
- [ ] Separate structural failure from current epoch/authorization rejection.
  Claimed event binds revision `generation-1`; obsolete events validate against
  their own lawful revision/key and retire rather than becoming malformed.
  Do not require current authority for a malformed row to escape validation.
  Resolve obsolete generation/head/destructive classification before choosing
  the new authorization-invalid reason; it cannot stand for those other causes.
- [ ] Apply the exact state table in design section 5. Pending current work keeps
  one valid request/wake; deleted/terminal/obsolete work does not dispatch.
  Claimed extracting retires reflected without `reset_for_dispatch`; verify
  runner-clearing does not resurrect it. Preserve all canonical fields.
- [ ] Add the literal `restore_document_authorization_invalid` to Reconciler's
  reasons, restricted to exact structurally valid extraction authorization
  rejection. Preserve the old three reasons and repeated retired_at values.
  Validate retired Document rows in full before clearing their terminal runner.
- [ ] Invalid work rolls back all previous reconciled changes and yields sanitized
  integrity_failure. Close author before parent operations.

## Task F: Implement the paired native recovery/retry amendment (chunk B)

Create only
`apps/singularity_storage/priv/repo/migrations/20261011000800_document_restore_recovery_provenance.exs`.
No released migration edit; no helper/grant/owner/membership/policy changes.

- [ ] Copy the currently installed three function bodies from their defining
  released migration sources into the new migration using CREATE OR REPLACE.
  Apply only the reviewed eligibility/locking/provenance changes below; compare
  installed function definitions before/after, not just source substrings.
- [ ] Extend the retirement constraint only with this additional alternative:

```sql
OR (retired_at IS NOT NULL
    AND retirement_reason IS NOT NULL
    AND retirement_reason = 'restore_document_authorization_invalid'
    AND event_type = 'document.extraction_requested')
```

  Preserve the existing null/null case and all three old non-null reasons.
  The explicit non-null reason guard preserves malformed timestamp/reason-pair
  rejection under SQL CHECK three-valued logic; it adds no new accepted state.
  Keep nullable text columns and frozen V1/V2 wire bytes unchanged.
- [ ] Mutator first reads only version identity/creator, takes existing shared
  authorization advisory lock with key
  `singularity:authorization:<principal>:<owner>`, then locks resource before
  version. Require current live head, private owner/creator/current authority,
  expiry/overflow and exact current attempt. Evaluate existing authority under
  these locks; locked custody alone must continue to allow native recovery.
- [ ] Select original outbox row by `id=attempt_job_id` alone. Record FOUND
  immediately; only NOT FOUND enters native eventless compatibility. Present
  invalid owner/type/revision/key/payload/creator/epochs/retirement never falls
  into that branch. Validate raw non-null correlation/optional UUID cause.
- [ ] Present event automatic eligibility requires exact raw extraction binding,
  event revision generation-1, current original epochs and current authorization,
  plus unretired or valid reflected retirement only. For valid unretired native
  attempts permit no submission; if present require exact event UUID/owner/
  private/document_extract/key binding. For reflected-retired V3 imported
  attempts require the exact matching submission. Scanner and locked mutator
  share these rules. Missing submission never means missing event. Preserve
  Reconciler/V3 preflight/finalizer mandatory-submission validation unchanged.
  Deny authorization-invalid, destructive and legacy retirement; retain the
  true-eventless native path separately. The unchanged restart test's real
  outbox-only fixture and direct WorkerScope→claim call are source evidence
  for the optional-submission native case, not license to loosen V3 import.
- [ ] Scanner applies the same present-event/absence/current-head/authority/
  expiry exclusions in WHERE before ORDER BY/LIMIT; retain limit 1..100 and
  version/owner-only return. Mutator repeats all checks; no scanner authority.
- [ ] Keep native recovery transition and successor insertion atomic. Preserve
  generation g+1/revision g+1/key g+1, original creator/current epochs,
  existing correlation and cause old job. Collision must roll back transition,
  never suppress conflict and claim successful recovery.
- [ ] Retry reads authenticated GUC identity, takes existing authorization
  serialization before invoking unchanged `document_runtime_target`, then under
  resource/version locks allows only these paired additional eligibility cases:

```text
((extracting AND expired AND exact_present_attempt_structural_binding)
 OR (pending AND exact_present_current_pending_event_submission_binding))
AND current_authenticated_original_creator_owner_authorized
AND current_live_head AND generation_can_increment
AND (original_principal_epoch != current_principal_epoch
     OR original_owner_epoch != current_owner_epoch
     OR retirement_reason == restore_document_authorization_invalid)
```

  Retired marker must have the exact valid timestamp/reason shape. Present
  malformed and true eventless attempts do not enter this authenticated path.
  Generic destructive pending work is denied even with stale epochs; generic
  destructive/equal-epoch extracting work is denied.
- [ ] For pending, select the exact original current request via unique owner/key
  (attempt_job_id is NULL). Generation 0 uses the unsuffixed Phase 2 key;
  positive generation uses its suffix. Validate event revision=current
  generation, full resource/version/creator/type/exact payload/private/capability/
  version/epochs/raw correlation/optional cause and matching extraction
  submission. Perform validation before the old pending idempotent return.
  The advancing authorization-invalid imported route requires that submission.
  Valid unretired/current-authority pending idempotence validates any present
  submission and permits ordinary pre-dispatch absence, because native retry
  inserts its outbox before dispatcher submission. Do not create a submission
  in retry SQL. Malformed/foreign/wrong/destructive/obsolete work is denied,
  not silently accepted by key alone.
- [ ] Eligible authenticated pending retry updates **only** attempt_generation
  by +1, preserving every other field under the existing lifecycle guard
  (20260922000300 lines 125–128). Insert the normal new current-epoch event in
  the same transaction; never unretire/overwrite old provenance. Repeated retry
  validates the new current request and returns idempotently without another
  increment. Collision rolls back generation; no new lifecycle guard/function.
- [ ] For expired extracting use ordinary retry's generation increment and
  clearing of attempt fields; for pending change only generation. Both emit
  the ordinary current-epoch event with fresh correlation/raw NULL cause.
  Preserve failure/unsupported rules, native errors and pending idempotence.
  Protect collision/concurrency so no canonical success without its exact
  normal successor; preserve existing already-pending idempotent behavior.
- [ ] `down` raises `Ecto.MigrationError` with a forward-only message. SET LOCAL
  TableOwner and restore role as existing migration style. No ACL statements
  widening execution; no definition/ownership/grant changes elsewhere.

Required native causal tests in the new owner:

- [ ] Principal-stale and owner-stale variants independently retire authorization
  invalid and preserve imported cut; scanner omits them and direct mutator
  returns false. A later current authorization snapshot cannot auto-revive them.
- [ ] Same-epoch revoke, reconcile to distinct marker, reauthorize: scanner/direct
  recovery still denied; ordinary fresh authenticated retry creates one current
  epoch successor. Equal-epoch generic destructive control cannot use this route.
- [ ] For pending independently cover stale principal epoch, stale owner epoch
  and same-epoch revoke/retire/reauthorize: preserve imported cut, retire the
  exact request with the distinct reason, and prove no automatic wake. Real
  authenticated retry advances generation once and inserts one normal new
  current-epoch request, preserving the old retired event unchanged. Repeated
  retry immediately before dispatcher submission is idempotent. Validate both
  legitimate pre-dispatch absence and exact present submission, rejecting a
  mismatched present submission. Valid unretired/current-authority pending control remains
  unchanged; malformed/destructive/foreign/stale-head/missing work is denied.
  Seed exact pending generation-0 event/submission in the disposable source
  before V3 export when needed; never manufacture an extracting job ID for it.
- [ ] Real fresh authenticated session uses unchanged public Runtime retry path;
  expired eligible attempt succeeds once, repeated pending call follows existing
  idempotence, while unauthenticated/revoked/foreign owner/foreign creator/
  malformed/stale-head/unexpired paths remain denied. Do not replace session
  evidence with TableOwner/GUC-only SQL and call it authenticated acceptance.
- [ ] Seed 100 earlier expired ineligible structurally bound attempts followed by
  one valid later attempt; scanner(limit=1) returns valid candidate. Directly
  call mutator on excluded rows and prove no generation/successor change.
- [ ] Coordinate two actual connections with message/lock barriers; recovery vs
  recovery and eligible retry vs retry/recovery produce at most one successor.
  Hold the existing authorization serialization lock in a test-owned connection,
  change revocation/epochs, then release and prove postlock revalidation denial.
  Bound waits/polling; do not use arbitrary sleep as the race proof.
- [ ] Prove present valid unretired native attempts recover with absent and
  exact matching submissions; a mismatched present submission denies scanner
  and mutator without canonical/successor changes. Reflected-retired imported
  missing/malformed-submission controls must deny both. Preserve eventless
  native and successor-collision regressions with both complete Runtime owners:
  only the already reviewed A.1 permission case differs, restart unchanged.
  Independently prove V3 missing attempt event/submission remains denied by
  preflight/finalizer; do not weaken either.

## Task G: Verify exact SQL/security delta and source preservation

New owner contains the following metadata/behavior assertions; parent runs it.

- [ ] Receipt pg_get_functiondef, owner, return type, security mode, proconfig,
  ACLs and grants for all three replaced functions before/after migration.
  Assert same TableOwner ownership and fixed search paths; scanner/recovery
  remain Worker-only and retry remains existing web-only. Public/dispatcher/
  preauth execute and runtime direct table writes stay denied.
- [ ] Compare installed before/after bodies against the reviewed bounded clauses;
  no lifecycle/custody/authority helper, source pin, policy, grant or membership
  is changed. Constraint permits the old three reasons and the new reason only
  for document.extraction_requested; malformed retirement pairs still reject.
- [ ] Assert scanner UUID-only columns/limit bounds, no content payload returned,
  no added security-definer functions, same seven-application graph.
- [ ] Parent checks original frozen56, original protected3 history, A.1's exact
  reviewed permission-case inverse and separate current receipt, and exact task
  source hashes before/after each complete native gate. Restart/Base remain
  original-byte identical; other recovery cases/assertions remain intact.
  Never regenerate historical receipts, edit released migrations or silently
  reinterpret assertions beyond the explicitly stronger A.1 read contract.

## Task H: Parent serial verification commands and actual evidence

All commands are future parent operations, NOT RUN by this author. The existing
`.devenv/phase5-pg-command.sh` is an environment-owned wrapper with fixed owned
PG paths; parent must confirm its allocation still belongs to this task and
is available. Do not copy stale paths, create parallel services or bypass limits.

Whole changed Storage owners, both RED and GREEN, no line filters:

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs apps/singularity_storage/test/singularity/storage/restore_reconciliation_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_reconciliation_test.exs --seed 215378 --warnings-as-errors
```

Complete Runtime recovery owner with only the reviewed A.1 permission-case
correction, and complete byte-identical restart owner (first prerequisite GREEN,
then repeated after Task 10 changes; no case/line filters):

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs --seed 215378 --warnings-as-errors
```

Legacy Base and Runtime integrity owners, whole pure and integration sections:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs apps/singularity_runtime/test/singularity/runtime/integrity_audit_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs apps/singularity_runtime/test/singularity/runtime/integrity_audit_test.exs --seed 215378 --warnings-as-errors
```

Retained V3 integrity/admission/document and original-evidence composition:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs --seed 215378 --warnings-as-errors
```

Retain Task 8 version-aware writer denials and legacy V1 compatibility:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/task14_backup_identity_export_security_test.exs --seed 215378 --warnings-as-errors
```

Static/frozen gate:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
sha256sum -c .devenv/phase5-frozen-baseline.sha256
git diff --check
```

- [ ] Before acceptance run the remaining permitted complete README verification
  gate in its single owned shell/cleanup trap, excluding prohibited manual E2E.
  Record actual command/result/source identity; dirty user files are preserved,
  so distinguish exact owned diff receipts from a clean-worktree assertion.
- [ ] Record every full command's exit status, actual tests/failures/exclusions,
  reached causal assertions, exact source hashes and archives. Do not predict
  totals, count excluded tests as passed or classify an unrun command as PASS.
- [ ] Confirm all own commands closed, normal maintenance EMPTY and each allocated
  DB/root/role/GUC/lock cleanup through the established harness; retain root
  absence evidence. No broad/manual deletion or touching another process.
- [ ] On ordinary failure use bounded Sol diagnosis/repair, recording cumulative
  counters. After two failed Sol repair rounds or an evidenced technical
  impasse, parent escalates to actual Astra with evidence under the continuous
  authorization in AGENTS.md; allow at least three bounded Astra attempts if
  needed. Genuine scope/external limits are BLOCKED_DESIGN/
  BLOCKED_ENV; never change frozen sources/assertions to manufacture GREEN.

## Task I: Actual source review and bounded local handoff

- [ ] Freeze all Task 10 source/test/migration/doc authors. Parent captures exact
  current diff, frozen/protected receipts, complete native logs and cleanup.
- [ ] Obtain actual independent SOURCE SPEC on the complete implementation and
  governing amendment, then distinct fresh SOURCE QUALITY. Both inspect actual
  files/delta and evidence, not only this plan or another review's summary.
- [ ] Resolve findings within scope, rerun affected whole owners and necessary
  downstream gates, and obtain final exact-source reviews. Preserve prior FAIL.
- [ ] Parent alone makes the authorized bounded local commit:
  `feat(restore): reconstruct unified search and document work`. Stage only the
  reviewed task paths/amendment/evidence. Preserve unrelated dirty/untracked
  files; no merge/push/version/tag/release/deploy.
- [ ] Record commit, changed files, new migration, exact tests/results, original
  frozen preservation, zero cycles and no Vault feature work. Explicitly state
  E2E NOT RUN/manual-only/deferred, Tasks 11/12 not yet qualified, Task 16 strict
  lease-cleanup guarantees unresolved and default V2 unchanged. Stop this Task 10
  handoff at its acceptance boundary; no broad later-task design is included.
