# Singularity v0.2 Phase 5 Export and Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task, with independent SPEC then fresh QUALITY review. Steps use checkboxes; unchecked steps are planned work, not passing evidence.

**Goal:** Produce readable portable knowledge artifacts, complete logical V3 backups, verified V1/V2/V3 restoration, and a reproducible historical `0.1.0` upgrade without enabling production canonical writes.

**Architecture:** Preserve the existing encrypted bundle and maintenance restore saga. Add an explicit immutable V3 schema, typed staging and maintenance-only historical admission, then verify canonical history and authenticated original bytes before rebuilding projections and completing restore. Core defines portable values and paths; Storage captures metadata and writes private streamed files; Runtime composes existing authenticated reads and owns temporary export handles.

**Tech Stack:** Existing seven-application Elixir/OTP umbrella, PostgreSQL 17, Ecto/Postgrex, SafeSQL, ExUnit, existing Asset storage/crypto/leases, Jason, devenv, and the existing integration/restore oracles. No new dependency or application.

---

## Status, evidence and execution boundary

### Qualified Task16 native prerequisite — 2026-10-19

Local native source acceptance is `6c7f867309470e23e8f34c06a8f53af0b496d48d`;
the [actual handoff](../../verification/2026-10-19-phase-5-export-lease-ownership-handoff.md)
records 132 unit,90 integration,254 architecture executions/zero failures,
format/devcompileWAE/xref0, independent SPEC then NEW distinct QUALITY and two
verified local commits. Original56 remains54 raw matches and2 exact inverses;
the original manifest and prior failed/P2 receipts remain unchanged.
Both native identifier-loss boundaries have component evidence; the original
Task16 strict end-to-end ALL-leases checkboxes remain unchecked until actual
companion/artifact integration. Resume that implementation, preserving accepted
Task8 and native-text attribution. Task17/18 dependencies and Task19 remain;
no wholeTask16/Phase5 acceptance, E2E run or publication is claimed.

### Task16 native ownership exception — 2026-10-19

The user explicitly approved the minimal native export-request ownership and
cleanup exception. The [new design](../specs/2026-10-19-singularity-v0.2-phase-5-export-lease-ownership-design.md)
and [detailed plan](2026-10-19-singularity-v0.2-phase-5-export-lease-ownership.md)
govern only that prerequisite in KeyCustodian/DownloadLease, associated focused
tests and exact attribution. They supersede conflicting unchanged-custody/
compile-only instructions solely for this seam. All ordinary request, worker,
authority, source, crypto and other Vault semantics remain frozen. Independent
DESIGN SPEC then NEW QUALITY precede source GO. Both strict Task16 native gaps
remain UNSATISFIED/UNWAIVED until actual checks pass; historical findings below
are retained. No Task16/Phase5 acceptance or publication/production permission.
E2E NOT RUN. Resume the original Task16 after this prerequisite qualifies.

### Current Task12 source/gate qualification — 2026-10-18

The Task12 source now writes logical3 through the genuine production default.
Final complete17 unit304 executed64 cases; integration294 executed258, together
covering322 registered cases with zero failures. Original three-owner296 passed
103 confirmation cases, not extra unique coverage. Sole restore302 passed
generated-default and genuineV1, three knowledge-reference variants and
late-corruption rejection; all had separate ordinary posts0/EMPTY. Earlier
failed candidates remain evidence, and timeout288 has no established cause.
Architecture306 passed131 cases; format308, devcompileWAE310 and xref0cycles312
passed, each with its own ordinary post0/EMPTY. Actual complete17 combined SOURCE
SPEC then NEW distinct QUALITY both CLOSED PASS before four verified local
source commits, ending at 4d832e91a5cf093ecd081be7b4fd515426b21f7d.
The [actual source/gate handoff](../../verification/2026-10-18-phase-5-task12-handoff.md)
records all commands, hashes, commits and historical failures. Final documentation
contract check, documentation reviews/commit and literal clean closure remain
PENDING at this snapshot; later facts belong in its separate ignored actual
closure receipt. This is not complete Task12 or Phase5 acceptance.
The [Task12 design](../specs/2026-10-18-singularity-v0.2-phase-5-task12-default-v3-design.md)
and [detailed plan](2026-10-18-singularity-v0.2-phase-5-task12-default-v3.md)
govern the transition and its two genuine fixture-composition repairs.
ExplicitV2 retains unsupported-content denial; production writes stay closed.
Task16 BOTH strict ALL-leases remains UNSATISFIED/UNWAIVED/BLOCKED_DESIGN,
Task17NOTGO and Task18 dependencies remain; E2E NOT RUN and no publication,
deployment, production activation or Vault work. Dated Task11 and earlier
defaultV2/preparation statuses below are historical, not current selection.

### Current Task11 source/gate qualification — 2026-10-18

Task11 source/gate qualification is complete on local source
`4a2e007649ab2d7c62aa72ee84bf1d2de0a93802`: all26 required non-E2E campaign rows and their26 separate
ordinary posts PASS, including2215 unit tests+10properties,2086 integration tests,
197 JS tests and the sole independent V1/V2/V3 restore. Combined final21 actual
SOURCE SPEC then NEW distinct SOURCE QUALITY both CLOSED PASS; committed source
blobs21/21 match the tested/reviewed bytes. Exact commands, six source commits,
raw hashes, warnings, historical failures and documentation closure conditions
are in [Task11 handoff](../../verification/2026-10-18-phase-5-task11-handoff.md).
Task11 documentation SPEC/NEW QUALITY, docs-only handoff
`e24b2b2b10f4bb2d21d7600ad8bdc2f931237d56` and literal clean closure passed;
actual receipt SHA25648a250ce5defba52410fbef62894d5fb5721611574a678da03296806f62e24b7
is recorded separately from the unchanged reviewed handoff snapshot.
This is historical Task11 qualification, not Phase5 acceptance. Its then-current
defaultV2/closed unsupported guard and Task16 BOTH strict ALL-leases
UNSATISFIED/UNWAIVED/BLOCKED_DESIGN, Task17NOTGO and Task18 dependencies remain.
E2E NOT RUN; no publication, production activation or Vault feature work.
Dated Task10 and earlier amendment/preparation paragraphs below are historical;
their old pending/source-NO-GO language does not replace this current record.

### Current Task10 qualification — 2026-10-15

Task10 source/gate qualification is complete on local source commit
`d1a8d4f73c570daa7177468b246a25819a2cdd39`: all15 permitted README gates PASS,
including2092 unit tests+10properties,1882 integration tests and197 JS tests.
Final whole28 actual SPEC followed by NEW distinct fresh QUALITY both CLOSED
PASS, no actionable P1/P2. Exact commands, five local code commits, immutable
evidence and documentation-handoff closure conditions are in [Task10 handoff](../../verification/2026-10-15-phase-5-task10-handoff.md).
Phase5 remains IN PROGRESS; Tasks11/12 are not accepted and defaultV2 stays.
Task16 BOTH strict ALL-leases remain UNSATISFIED/UNWAIVED/BLOCKED_DESIGN.
E2E NOT RUN; no publication, deployment, production activation or Vault feature work.

### Task11 design amendment — 2026-10-15

The native-text prerequisite is locally qualified at documentation commit
`239c1c322b47c095004690154f691fcf85eeff81`; its code bytes are unchanged from
`5f388ac88d5603b8c29df3a592d0843885a30912`. See [prerequisite evidence](../../verification/2026-10-15-phase-5-native-text-prerequisite.md).
The [native V3 saga amendment](../specs/2026-10-15-singularity-v0.2-phase-5-knowledge-v3-saga-design.md)
and [detailed plan](2026-10-15-singularity-v0.2-phase-5-knowledge-v3-saga.md)
synchronize the retry wording in master design §8, §11 and Task11 together. This
new amendment awaits actual independent SPEC then NEW distinct fresh QUALITY;
Task11 source is not yet authorized. Other reviewed plan requirements and
Task12/Task16 gates remain unchanged. E2E NOT RUN; defaultV2 remains.

### Task11 case-local execution-budget amendment — 2026-10-16

The [sentinel budget design](../specs/2026-10-16-singularity-v0.2-phase-5-task11-sentinel-budget-design.md)
and [detailed plan](2026-10-16-singularity-v0.2-phase-5-task11-sentinel-budget.md)
govern an explicit independently reviewed exception: only the original continuous
sentinel/failed-target/fresh-RESTART case may use `@tag timeout: 120_000`.
This supersedes originaltimer wording only for its aggregate ExUnit watchdog,
not any product assertion, native work, other deadline or qualification vector.
It takes effect only after design SPEC -> NEW distinct QUALITY and root source GO.
Native60/64 remain FAIL; Native63 remains diagnostic. No latency speedup or
Task11/Phase5 acceptance is claimed. Frozen56/Vault/Task16 remain unchanged;
E2E NOT RUN and publication/production restrictions remain in force.

### Historical qualification records

The statuses below belong to their recorded earlier source generations. Their
FAIL/NOT RUN results are preserved; they do not describe the current handoff.

Fresh sameSource permitted README gates1–6 now PASS. ONE ordinary NO-ARGS
unit revalidation f25c4a/session62510 naturally CLOSED0/f9d87b at2026-10-15
05:31:10+08/default96/auto-seed546534:2092executedtests+10properties/0FAIL/
1874existingexcluded. Complete untruncated raw78lines/24416bytes/9b1e6d6b
readEOF66359a, closure04b50ff1; all277/27/source/pins/indexHEAD/owned0 poste763e7
PASS, ordinarypost8b8e9c CLOSED0EMPTY. No observer/seed/filter/prewarm/deadline/
concurrency/source changes. This current PASS does NOT prove causalrepair or
reliability and does NOT reclassify originalFAIL; residual PDFcauseUNKNOWN
retained for final independent Source review.
README gate7 integration ONE execution029e56/session4152 naturally CLOSED2/
42160f at2026-10-15 07:16:12+08/default96/seed988075:Storage14FAIL/4INVALID
(1501selected/1497executed), Runtime373executed/0FAIL; others all excluded.
Aggregate1874selected/4invalid/1870executed/14FAIL/2102existingexcluded.
Raw925lines/118036bytes/SHAfff90b0f98bb4f424d4c879563ede664eb96e1f7afe6e338df299ae380ee0e8b
read complete1EOF/a74851. Post277/27/source/pins/HEAD/indexEMPTY/owned0/
rawSHA guard536f1c PASS; ordinaryposte30feb CLOSED0EMPTY.
Thirteen wake-migration preparation refusals, four search-plan setup invalidations
after15s checkout, and one V3 large typed-row public import timeout at60s require
separate diagnosis. No causal repair, assertion/deadline weakening or rerun.
Closure: `.devenv/phase5-task10-upload-stream-readme-integration1-failure-closure.md`.
Gate7 FAIL blocks acceptance; gates8–15 NOT STARTED. Continue diagnosis and
necessary reviewed repair under continuous authorization. E2E NOT RUN.
Historical preceding NO-ARGS unit gate6 Native34963 naturally CLOSED2 at
2026-10-14 05:51:22UTC/default96/seed879520:
2092executedtests+10properties/1FAIL/1874excluded NOT PASS. The sole failure is
PDFTest196/208: real Poppler malformed.pdf expected unsupported/malformed_document,
actual failed/extractor_failed. Runtime1033executed/0FAIL does not supersede the
failed required gate or establish causality. Full90line/25134byte rawSHA256
7456c42e93f3a974e419beae5804714cdbd379c5af5f850d858eeaf1f588caa3 retained/read.
All24/protected/indexEMPTY/HEAD unchanged/diffcheck0, exact-worktree BEAM/logger
absence and ordinary maintenance8163eb CLOSED0/EMPTY. No Native LIVE violation.
Two independent bounded read-only Sol maps CLOSED; originalfailure causeUNKNOWN.
Reviewed sanitized utilityV16 wholepreflightPASS, ONE owning and ONE full-cohort
characterization both nonrecurrenceINCONCLUSIVE; no PDF productrepair. Formal
ordinary unit revalidation above is separate current evidence, not diagnostics
substituting a gate or repeat-until-green. Final full Source reviews/local
commits/literalGitclean pending. Cumulative Source qualification
FAILs now Sol3/Astra5 (historical Sol2/Astra5 preserved); new PDF repair rounds0.
Task10/Phase5 NOT ACCEPTED; Task11/12 Source NO GO; E2E NOT RUN.


Bounded diagnostic design SPEC then fresh QUALITY CLOSED PASS. Actual utility V1
SPEC PASS, then NEW distinct fresh QUALITY CHANGES REQUIRED: cross-input-window
events may be ignored, and suppressed completion may be misclassified as await
failure. Exact V1 snapshots/review retained (snapshot seal d990b992, review1cd9aa92).
Utility correction1 actual SPEC CHANGES REQUIRED: same-window post-terminal
processing can retain COMPLETE. V2 snapshots/rejection retained (c2d83c7c/d9bdcb02).
Utility correction2 AUTHOR CLOSED: observer70a48f36/preflight56cb5808,
parent full EOF/diff checks and current14-input seal f4d41c19 PASS.
Actual independent SPEC CLOSED PASS (ff5d58bc), then NEW distinct fresh QUALITY
CHANGES REQUIRED (0d516647): extra conflicting control entries and contradictory
cleanup classifications can retain COMPLETE. Exact V3 snapshots/seal c391ec77
preserved. Two Sol repair qualifications failed; bounded Astra utility recovery1
AUTHOR CLOSED under design a61bb6d5/astra_gate=SOL_REPEATED_FAILURE: actual
observerdf910416/preflight0f7b4c8c, parent EOF/diff/guards PASS, V4 seal97c85166.
V4 nonauthor SPEC CLOSED PASS (5c87f33a), then NEW distinct fresh QUALITY
CHANGES REQUIRED (f377bb7c): unassociated root classifications and an initiating
close request contradicting terminal result can retain COMPLETE. V4 snapshots
seal50563b98 retained; bounded Astra utility recovery2 AUTHOR CLOSED under design
a699126f: actual observere43407d3/preflighte670f362, parent actual EOF/diff/guards
PASS, V5 seal19246dac (24inputs). V5 nonauthor SPEC CLOSED CHANGES REQUIRED
(7f7b186f): zero-status EXIT and output-limit/process_failed combinations may
incorrectly retain COMPLETE. Exact V5 snapshotseal929ddbb8 retained; bounded
Astra utility recovery3 AUTHOR CLOSED under design23b5900b: actual
observer19556449/preflight92a5bf1f, parent complete EOF/diff/guards PASS, V6
seal d9bdbbd5 (28inputs). Actual V6 nonauthor SPEC CLOSED PASS (3fe3b39c);
NEW distinct fresh QUALITY CLOSED CHANGES REQUIRED (859bde15): retained
normal_result can contradict or follow the initiating close yet retain COMPLETE.
Exact V6 snapshotseal76df416b preserved. Bounded Astra utility recovery4
AUTHOR CLOSED under design806ddc1e: observer00645d3c/preflightb3f37227,
parent complete EOF/diff/guards CLOSED, V7 seal9e7ea6e9 (33inputs).
Actual independent V7 SPEC CLOSED CHANGES REQUIRED (a62016ea): unreachable
running/closing await states and incompatible initiating close reader/request
labels still retain COMPLETE. Exact V7 snapshotseale4e7b179 preserved.
Bounded Astra utility recovery5 AUTHOR CLOSED under design22ae9488 and
Source-precision supplement183ca1fb: observer11d82791/preflight2185151e.
Parent complete EOF/diff/guards PASS, V8 seal6de49f4c (38inputs).
Actual independent V8 SPEC CLOSED CHANGES REQUIRED (b69ce761): terminal-pipe
close must immediately finish with identical pipe labels/stored request;
observed normal output bytes must respect recorded output cap.
Exact V8 snapshotsealf074d8c0 preserved. Bounded Astra utility recovery6
AUTHOR CLOSED under designf76f99e6: observer4acc2df0/preflight13939185.
Parent full actual EOF/deltas/guards CLOSED0, root18893052/current V9 seal
f46bad2b (42inputs). Actual V9 SPEC CLOSED PASS (ebabbec3); NEW distinct fresh
V9 QUALITY CLOSED PASS (ce72c12b). No V8 QUALITY started. FIRST isolated
preflight24961 naturally CLOSED1: observer588 ambiguous try/catch definition
does not compile. Raw13lines/1277bytes/aea2162f and closurecf9036de preserved;
no synthetic assertion or real PDF case ran. Protected guards PASS, owned
BEAM/logger absent, ordinary maintenance68058 CLOSED0 EMPTY. Exact V9 snapshot
pair0b2727ec preserved. Bounded Astra recovery7 AUTHOR CLOSED under89fe14fb:
observer6943092c (+7/-1), preflight13939185 unchanged. Root full closurefd99f162,
current V10 sealdfcd450f (49inputs), actual SPEC CLOSED PASS (fc2dda38);
NEW distinct fresh V10 QUALITY CLOSED PASS (a47639a2). Second isolated
preflight53922 naturally CLOSED1: first matchspec_projection contract fails;
initialize/2 recursive clauses also shadowed. Raw25lines/1834bytes/65ba8321,
exact V10 snapshots6667a133 and ordinary maintenance5e7778 CLOSED0 EMPTY.
Astra recovery8 diagnosis CLOSED (60694915): unsupported matchspec :<= atoms
and starter/recursive initialization overlap. Root confirmed pinned OTP source.
Recovery8 AUTHOR CLOSED under6c4a1095: observer5531f8ec exactly six replacements;
preflight13939185 byte-identical, assertions unchanged. Root complete EOF/diff/
guards CLOSED0, root95029f4f/current V11 seal98f9cc3d (57inputs).
Actual V11 SPEC CLOSED PASS (0206b5a6); NEW distinct fresh QUALITY CLOSED PASS
(4c93f993). Optional standalone BIF query NOT RUN. Third isolated preflight46228
naturally CLOSED139: complete raw6lines/838bytes/32f66ed7 has no stack, assertion
result or completion marker; runtime qualification INCOMPLETE/cause UNKNOWN.
Root abnormal-exit closure75e751e8, exact V11 snapshotsealecd39e8b,
protected guards438174 CLOSED0/owned BEAMlogger absent; ordinary maintenance961272
CLOSED0 EMPTY. Bounded Astra recovery9 read-only diagnosis CLOSED (1f30fc67):
no operation localized or OTP/PDF cause established. Recovery9 AUTHOR CLOSED
under63990f2d: preflight62b86c1e exactly +16/-0 fixed phase markers; observer5531f8ec
unchanged. Root fullEOF/diff/inverse/protected guards CLOSED0, rootbc6a0e73/current
V12 sealb31d0f56 (65inputs). Actual V12 SPEC CLOSED PASS (c2697a40), NEW distinct
fresh QUALITY CLOSED PASS (116679e2). Fourth whole preflight56388 naturally
CLOSED139: raw9lines/976bytes/05741069 prints installed_enter/returned then
matchspec_enter, not returned. Failure closureafb0c9d9; exact V12 snapshotsfc4ec28e,
postguards96f4e2 CLOSED0/owned BEAMlogger absent; ordinary posted949a CLOSED0 EMPTY.
This narrows only the matchspec interval, not an exact BIF, signal, OTP defect or
original PDF cause. Astra local diagnosis10 CLOSED (22f9a614) and root pinned-OTP
static hypothesis44a639fb preserved. Recovery10 AUTHOR CLOSED under0d70308b:
preflightfba2f365 exactly +8/-0 further fixed markers; observer5531f8ec unchanged.
Root fullEOF/diff/eight-line inverse/guards CLOSED0, root021ecfff/current V13
seal19cfbce3 (74inputs). Actual V13 SPEC CLOSED PASS (990e7a37); NEW distinct fresh
V13 QUALITY CLOSED PASS (064dae93). Fifth whole preflight14354 naturally CLOSED139:
raw12lines/1116bytes/3b0f6585 shows ordinary_returned then first hook_positive_enter,
not returned; no stack/BIF result/final marker. Failure closure678088eb, exact V13
snapshotsc58bb19d, postguardsce7c9f CLOSED0/ownedBEAMlogger absent; ordinary
post6520af CLOSED0 EMPTY. This narrows the positive selected-entry assignment
interval only, not a proven C fault/signal/OTP defect or original PDF cause.
SAME Astra recovery11 read-only diagnosis CLOSED (86455b6d); independent local
Nix source/patch metadata audit CLOSED (131db4f2: official28.5.0.3 tag/no declared
C patch, actual C bytes unavailable). Parent primary-source follow-upaeaac7c7
is static only; newer0.5/master fragments do not establish a fixed upgrade.
Independent obligation assessment allows an explicitly reviewed diagnostic
method correction, not relabeling full-positive BIF FAIL139. Exact full-negative
BIF checks plus positive/negative projection BIF checks alone are insufficient:
full unchanged hook specs require real-session selection/action/inheritance/
privacy/isolation/natural-cleanup contracts. Parent method amendment737d42b6
adds bounded six-actor/two-session contracts with all-step failure cleanup;
actual DESIGN SPEC CLOSED PASS (edab7d53) then NEW distinct fresh DESIGN QUALITY
CLOSED PASS (6d8c9cb9). Root6cca3f CLOSED0 all240entries/24manifests/pins/index/
HEAD/ownedabsence/freshlogs; SAME Astra recovery11 preflight-only AUTHOR CLOSED:
1520lines/93506bytes/8393cba7, V13delta+334/-1; observer5531f8ec unchanged.
Root full actual EOF/diff/non-hook byte inverse CLOSED PASS (900b5ae7), V14
seal31340a0b (87inputs)/immutable pairseal5e1a7139; fc314a all255entries/
25manifests/pins/HEAD/index/ownedabsence/freshlogs CLOSED0. Historical full-positive
BIF FAIL139 remains unchanged; all substantive assertions mandatory. Actual
artifact SPEC CLOSED PASS (98a2e0aa; corrected exact inverse790929, fresh96114e
all255/25 and4b5d81 ownedabsence/index/diff CLOSED0), THEN NEW distinct fresh actual
QUALITY CLOSED PASS (9559cd12; fresh3cd46e all255/25, corrected e5fd4e pins/owned0/
index/diff/logs CLOSED0). All review commands naturally CLOSED; no sessions.
Fresh parent guard40298/ea155b CLOSED0 all255/25/receipts/owned0/index/pins/logs,
ordinary prec59d78 CLOSED0 EMPTY; all review actors/commands CLOSED. Sixth whole
preflight42994 naturally CLOSED1 (b92e54): new hook-action contracts and existing
real-ExUnit integration returned/1test0failures, BUT final cleanup_beam line1263
true=:code.purge returnedfalse. No cleanup_returned/final complete marker.
Raw49lines/2980bytes/a7906f12 read EOFd1d466; failure closurea284f125. Post60da50
CLOSED0 all255/25/owned0/index/pins, ordinary85037a CLOSED0 EMPTY. Whole preflight
FAIL; partial success is not qualification. SAME Astra recovery12 read-only
diagnosis CLOSED (13a2c22d): installed purge boolean reflects process killing,
not generic success. Proposed strict non-killing soft_purge/current+old-code/
owned-file/dir absence, all-step cleanup and original-exception preservation.
Exact old residue remains untouched; exclusive bounded allocation avoids reuse.
Parent fixture-only design/plan0956e479 received independent DESIGN SPEC
CLOSED PASS (74d55d3e), THEN NEW distinct fresh DESIGN QUALITY CLOSED PASS
(391b6ee0). Immediate parenta7b1dc all255/25/pair/pins/index/HEAD/owned0/newlogs/
receipts CLOSED0; all reviewers/commands CLOSED. SAME Astra recovery12 bounded
preflight-fixture-only AUTHOR CLOSED:1639lines/98297bytes/738211f9,+133/-14;
observer5531f8ec unchanged. Parent actualEOFb1ce23/full difff74989 and exact
V14 non-fixture inverse/fixtureforms/markerorder PASS (rootclosure3c238d06);
preserved253 entries33d429 CLOSED0. V15 current97inputseal9a5af6aa/immutable
pairsealecc5d438; root4d3866 all267entries/26manifests/pair/pins/HEAD/index/
owned0/newlogs CLOSED0. Six new cleanup contract controls include both
acquisition stages and injected false after real soft purge (not live-obstruction
proof). Actual V15 SPEC CLOSED PASS (d6151d3e; c1436a exact inverse, b08de4
all267/26 and d511c1 pins/HEAD/index/diff/owned0/logs CLOSED). THEN NEW distinct
fresh actualQUALITY CLOSED PASS (d30c839a; 8c1f7c all267/26, bb458c inverse/
markerorder/pins/index/owned0/logs, b6fe7b hashes CLOSED0). All review commands
naturally CLOSED; no sessions. Parent52affe all267/26/receipts/pins/HEAD/index/
owned0/logs and ordinarypre8ac581 CLOSED0 EMPTY. Seventh whole preflight16428
naturally CLOSED1 (b44746): fixture_false_soft_purge_rejected at line1281;
synthetic_beam_returned/run/cleanup/final marker absent. Full raw35lines/
2401bytes/dbfe78b6 read EOFfae313, closure6218f801. Post0e60b8 all267/26/owned0/
pins/index CLOSED0; ordinarypostf29ddd CLOSED0 EMPTY. Whole FAIL, no owning GO.
Raw does not show caught result shape. SAME Astra recovery13 diagnosis CLOSED
(eea94d88): installed Elixir1.18.4 catch retains raw badmatch rather than
normalized MatchError; source-backed inference, not observed runtime tuple or
original PDF cause. Unchanged reviewed Design12 governs one-line correction
(plan300fcff9). Parentaeb18e fresh267/26/currentV15/pins/index/owned0/receipts/
freshlogs CLOSED0; SAME Astra bounded AUTHOR CLOSED (da30eb), exactly+1/-1 at
line1281: raw {:badmatch,false}; failed/error/exactfalse/nonempty-stack retained.
No normalization, broad acceptance or other byte change. Current V16 preflight
1639/98291/dbf76f44; observer unchanged. Parent fullEOF5ede8d/full dif d65072/
unique inverse to V15 PASS, root59a2ffd7; initial parent wrong-terminal-marker
wrapper error recorded, corrected actualEOF passes without artifact change.
Protected265 entries96e9dc CLOSED0. V16 current105seal702f824a/immutable pair
seala5473390; parent4b8b84 all277entries/27manifests/pair/pins/index/HEAD/owned0/
freshlogs CLOSED0. Actual V16 SPEC CLOSED PASS (49d3799b; bothfilesEOF,
12e21e exact inverse, 2d7926 all277/27, d80adf pins/index/owned0/logs CLOSED0).
THEN NEW distinct fresh actualQUALITY CLOSED PASS (ab835350; full pairEOF,
4902f2 all277/27, 99c2d8 exact inverse, cd8cb1/716eec pins/index/logs/ready,
4fb279 owned0). Reviewer's extra ready-file checker error corrected against
postmaster.pid; rawhash transcription corrected by parent3982fa. No artifact
change/runtime failure. All review commands naturally CLOSED, no sessions.
Parentb0c365 fresh277/27/currentpair/receipts/seals/pins/HEAD/index/owned0/
freshlogs CLOSED0; ordinarypre879a15 CLOSED0 EMPTY; all actors/commands CLOSED.
Eighth ONE whole preflight82881 naturally CLOSED0 (9332a9): all fixed phases,
six fixture controls, realExUnit1test/0failures/seed47747/default96, strict final
cleanup and complete marker returned. Full raw42lines/2474bytes/0d635626 read
EOF8218e0, PASSclosure23cf4a8c. Post8d8337 all277/27/raw/owned0/index/pins/logs
CLOSED0; ordinarypost66b566 CLOSED0 EMPTY. Whole diagnostic runtime PASS, not a
focused-only fallback. Historical Native5FAIL139/Native6+7FAIL1 retained.
No literal positive full-action BIF success or originalPDFcause/fix is claimed.
Fresh parenteb434a all277/27/passreceipt/raw/pins/index/owned0/freshowninglog
and ordinarypre8aa993 CLOSED0 EMPTY. ONE unchanged whole owning PDF file2898
naturally CLOSED0 (37ac20):22tests/0failures/seed879520/default96/original
deadlines; selectedCOMPLETE1/none/three numeric_exit1 routes/destroyed1/
watchdog+collectorclosedtrue. Full raw65lines/6376bytes/273e9e89 readEOF78ccce,
closured1efb1d7; post61d292 all277/27/owningraw/pins/index/owned0 CLOSED0,
ordinarypostb39af9 CLOSED0 EMPTY. Nonrecurrence INCONCLUSIVE; original34963
FAIL/causeUNKNOWN, no unfiltered README PASS or product repair.
Observed ready/ok→ready/error→closed/error/normal with successful numeric exits
does not establish actor authenticity/race/originalcause. Read-only source
interpretation843c4ad1 and independent full-cohort route assessmentfa7bceee
CLOSED: ordinary readerDOWN may overwrite state while capturednormal survives,
but receivebranch/actoridentity are not observed; await_failure/finalreadererror
remains conservatively INCONCLUSIVE. New contextual designf57c9f53 and
Nativeplanbdd100a7 permit ONE original full unit-cohort characterization,
removing ONLY owning-file operand: inner11/outer16/logger23, seven pure
negative controls PASS, originalseed879520/defaults/assertions/deadlines and
all seven helper integration exclusions unchanged. Extra formatter/eventcasts
and naturally-loaded registration perturb scheduling; same seed is not an
identical schedule. Parentcaee44 and DESIGN SPEC54c255 verified all277/27,
pins/index/owned0/freshraw. DESIGN SPECde34cb31 CLOSED PASS, then NEW distinct
fresh DESIGN QUALITYff745ea5 CLOSED PASS (801b09 pure route, 30cd24 all277/27,
096713 pins/owned0). Parent876074 full guard+SPEC CLOSED0. All review commands
CLOSED. ONE full-cohort Native1e22b4/session75917 naturally CLOSED0/2e813e:
allseven2092executedtests+10properties/0FAIL/1874excluded, seed879520/default96.
SelectedCOMPLETE1/none/three numeric_exit1 routes/destroyed1/watchdogcollector
closedtrue; raw130lines/30000bytes/c281976d readcompleteEOF72444b in bounded
literal windows after JSON presentation truncation, closure7da3c3e7. Fresh
preGOc602d3/postd9d894 all277/27/pins/indexHEAD/owned0 PASS; ordinarypre6c5cb1
andpost29d955 CLOSED0EMPTY. Actual apporder differs from original34963; both
owning and full-cohort nonrecurrenceINCONCLUSIVE, originalFAIL/causeUNKNOWN,
no productrepair or ordinary README PASS. Next ONE ordinary noargs gate6
revalidation under existing README15plan42fee147 removes instrumentation;
only freshlogname adaptation, no repeat-until-green. No repeated owning or
identical cohort, assertion weakening/prewarm/runtime change; all diagnostic
changes ignored, no product Source repair.
Complete-pipe closes require direct matching finish; normal sizes respect cap.
Synthetic INPUT corrections preserve every substantive assertion/COMPLETE
baseline; reader nonregression is scoped to the established reader protocol,
not an unconditional forged-message invariant or authenticity proof.
Utility failures Sol2/Astra12 retained; Native preflight attempts/failures8/7,
owning attempts1/commandFAIL0/nonrecurrenceINCONCLUSIVE1; full-cohort attempts1/
commandFAIL0/nonrecurrenceINCONCLUSIVE1; ordinary noargs revalidation1 CLOSED0
is fresh required-gate6 PASS only, originalcauseUNKNOWN/unfixed. Whole diagnostic PASS
does not supersede original unit34963 FAIL or provide product/phase acceptance.
No fresh V5/V7 QUALITY started.
This is diagnostic recovery, not product repair or original PDF causal evidence.
Source Sol3/Astra5 and PDF Source repair0 unchanged. Actual SPEC then NEW fresh
QUALITY and whole isolated preflight CLOSED PASS; ONE real owning characterization
ran successfully but did not reproduce originalFAIL. No originalcause/fix claimed.

Earlier ordinary changed-Source cohort70920 naturally CLOSED0/seed151533/
default96:2092executedtests+10properties/0failures/1874excluded NOT PASS, raw78lines/
24429bytes/16eb26f6. Bounded actual Source SPEC then NEWdistinctfreshQUALITY
CLOSED PASS, runtime193186be/test7f56ae34, future15Nativeplan42fee147 reviewed.
All24/protected/indexEMPTY/HEAD unchanged/diffcheck0/worktreeBEAM+loggerabsence/
ordinarymaintenanceEMPTY. Fresh15 permitted README gates GO, NOT STARTED at this
receipt; finalfullSource reviews/localcommits/literalGitclean still required.
Historical SourceSol2/Astra5 FAILs preserved; Task10/Phase5 NOT ACCEPTED,
Task11/12 SourceNO GO, Task16strictALLleasesUNSATISFIED/UNWAIVED; E2E NOT RUN.

Historical upload-stream Stage2 scoped qualification CLOSED: private stream runtime193186be,
newtest7f56ae34; parent exact transformation/inverse PASS, format24363 CLOSED0.
New wholefile37929 9executed/0failures/raw0af537da; unchanged original locks83808
8executed/0failures/2excluded NOT PASS/rawfe807a67. Complete24 sealc6f13232 and
protected guards/indexEMPTY/HEAD unchanged/diffcheck0/ordinary maintenanceEMPTY.
Actual bounded Source SPEC CLOSED PASS; NEWdistinctfreshQUALITY in progress;
cohort/fresh15/final
Source reviews/local commits remain pending. Task10/Phase5 NOT ACCEPTED,
Task11/12 Source NO GO, Task16strictALLleasesUNSATISFIED/UNWAIVED; E2E NOT RUN.

Historical upload-stream Stage1: parent format71816 CLOSED0 and whole-file ordinary
RED56741 CLOSED2/default96/seed338018,9tests/one intended handoff-function
assertion failure,8 characterization PASS/raw9a517825. Complete24/protected
guards and ordinary maintenanceEMPTY; original runtime8a72c25f unchanged,
new test7f56ae34, indexEMPTY/HEAD unchanged. Same Sol bounded Stage2 GO is only
private local closure/verbatim reducers; GREEN/reviews/cohort/fresh15/final
review/local commits pending. Task10/Phase5 NOT ACCEPTED; E2E NOT RUN.

Latest cold-loader diagnostic Native60276 naturally CLOSED2 at2026-10-14
04:12:03UTC on unchanged Source6/seed151533/default96:2083executedtests+
10properties/1original100msfailure/1874excluded, observer COMPLETE. Full
973line/122668byte rawSHA256
58bb34952b99fc86506641045607a80e275eb62ba93693c9c83fc8ea107a813f.
Utility actualSPEC→NEWfreshQUALITY PASS; synthetic13284 CLOSED0/3tests/0failures;
3owned session barriers/destructions and natural watchdog/collector closure.
All current seals/ordinary maintenance EMPTY; indexEMPTY/HEAD unchanged.
Task10/Phase5 NOT ACCEPTED; Task11/12 Source NO GO. Fresh15/final actual Source
reviews/local commits/literal clean remain outstanding; E2E NOT RUN.
Bounded Astra diagnosis CLOSED: exact failed writer<0.127890.0> waits in cold
Enumerable.MessageStream loading. load_ok REQUEST at84.923395ms is not reply;
last waiting sample92.975378ms after undefined. Exact100ms assertion-start,
continuous100ms blocking and code-server wait cause are NOT established.
No speculative Source/Markdown/preload/timeout fix. Sol scope assessment CLOSED:
narrow internal stream compatibility can be designed under continuous authority
with independent review/regression, without public readiness/lock/custody/ack
changes. Subsequent Astra/Sol assessments select a same-position private local
arity2 stream closure in already-loaded UploadSession, with verbatim reducer
helpers; no remote constructor failure/handshake/new readiness. Generic
Enumerable.Function loading remains, not a universal100ms guarantee. Actual
handoff regression is feasible; new 2026-10-14 upload-stream-compatibility
design/plan independent SPEC→NEWfreshQUALITY CLOSED PASS; Stage1 expected RED
now verified, bounded Stage2 Source GO, not GREEN/acceptance. No larger
observer implementation or unchanged-Source blind repeat first. Receipt
`.devenv/phase5-task10-unit-loader-observer-cohort-closure.md` records exact facts.
Historical Native17632 instrumented PASS/raw1bf94e3b remains preloading-confounded
diagnostic-only. Utility/static-review/launcher histories stay separate from
SourceSol2/Astra5; all freezes/assertions/defaultV2 unchanged.

Required-gate and Source-fixture evidence preceding that diagnostic:

Latest Task10 state2026-10-14 is NOT ACCEPTED; Task11/12 Source NO GO.
Source5 historical-isolation focused40/0 but exactnoargsunitFAIL/rawf57a07a7;
Source6 deferred-Document-fixtures metadataRED→focusedGREEN44/0 and bounded
SPEC→distinctfreshQUALITYPASS, but originalwholecohortseed151533FAIL/rawf8bc17ac
(2083executedtests+10properties/1original100msfailure/1874excluded). No cure or
causality established. Source22seal1e49d98e/frozen/protected/locked and ordinary
postEOFcleanup PASS; Source6fresh15README/finalreviews/localcommits/literalclean
outstanding. HistoricalSol2/Astra4 plusSource5(Astraauthor5)fullunitFAIL gives
cumulative5 failedAstraSourcequalifications; tool/utility/advisory/expectedRED
and Source6declared diagnostic remain separate, no reset or invented cap.
Reviewed 2026-10-14 historical-test-isolation/deferred-document-fixtures designs
and plans preserve every failure. Bounded readonly Astra diagnosis is closed
as summarized above; no blind retries or changes to frozenlocks/assertions/
timeouts. Full evidence
is in docs/verification/2026-10-11-phase-5-acceptance.md. E2E NOT RUN.
The following earlier statuses remain historical, not current acceptance:

Historical Task10 complete permitted README integration36198 naturally CLOSED
FAIL/exit2: 1831actual tests,739FAIL, final cleanup NOTEMPTY. Earlier focused
GREEN is not Task10/Phase5 acceptance. The next bounded test/fixture repair is
`2026-10-13-singularity-v0.2-phase-5-readme-compatibility.md` and its design;
actual DESIGN SPEC then NEW distinct fresh QUALITY CLOSED PASS; docs-only
commit1c1ca7f. Design-entry failedSol2/AstraRepair0; AstraRecovery1/2 now failed.
Whole callback-kill RED2 CLOSED exit2/1test1failure15.2s/full archive; exact
run-owned recovery CLOSED/maintenanceEMPTY, original cleanupFAIL unchanged.
Both source authors CLOSED; parent format/compile PASS. R1whole26/2+w warnings,
R2whole26/1/no priorwarnings; failedSol2/failedAstra2, exact residues recovered,
original cleanupFAIL unchanged. Recovery3 permission cast wholefourownersPASS72/0;
lifecycle DROP9sessionrace confirmed. AmendmentSPEC/freshQUALITY CLOSED PASS
before exacttwofile sourceGO. Recovery3 authorCLOSED/staticPASS/currentseal208911e2;
whole lifecycle27/0, permissionrepeat72/0, historicalwhole30/0 and unchangednative
sevenstate characterization PASS. EverypostEOF source/frozen/protected/locked/
rootabsence/maintenanceEMPTY check PASS, no manualrecovery. Existingcharacterization
unusedaliaswarning retained. RetainedH3/Runtime2/Base/Task9/Task8 whole pure/SQL
and static gates PASS on208911e2, actual exclusions recorded in compatibilityplan.
AllpostEOF checks/maintenanceEMPTY. FirstfiveREADME/fullunit2082tests+10properties
PASS; historical complete unfiltered integration95548 naturally CLOSED FAIL/exit2:
Storage1491executed/3FAIL, Runtime373executed/18FAIL, total1864executed/21FAIL.
AllpostEOF seals/normalmaintenanceEMPTY PASS; failedSol2/failedAstra3. Exact
Fournewowner amendment actualSPEC/freshQUALITY PASS beforeboundedAstraRecovery4
sourceGO, authorCLOSED/rootwholeinverses/staticPASS. Combinedcurrent22source whole
fournewowners172executed/0FAIL/43excluded, allseals/normalcleanup. OriginalACL7/7FAIL
retained; metadataonlyutilityrepair actualSPEC/freshQUALITY PASS beforeGO, corrected
whole7/0/seven A_B_C_D markers/normalcleanup. UnchangedwholeObserver16executed/0FAIL/
11excluded notcause/waiver of oldfullfailure; nextfull mustpass unchanged. Current22
retained67316 naturallyCLOSEDexit0/all13gates PASS at14:01:21UTC, raw6278e44c/
closure6301244f/allseals/normalcleanup; 500SQL+84pure testexecutions/0FAIL plus
actualsevenstates/staticzero cycles. Current22completeREADME50083 naturally
CLOSEDexit2 at2026-10-13 16:03:40UTC: firstsixgates PASS, integration1864executed/
2historical60000msFAIL, Runtime373/0; total2092excludedincludingproperties NOTPASS.
Fullraw28dcff3f/parent53ee8b47/closure31e98728; allpostEOF seals/rootabsence/
normalEMPTY PASS, gates8–15 NOTRUN. OverallRecovery4failed, failedSol2/Astra4;
cause/waits UNKNOWN, no waiver or finalSOURCE/Task10/Phase5acceptance.
Complete README GREEN/finalSOURCE reviews remain outstanding.
Subsequent ordinary seven-app diagnostic42661 naturally CLOSED0 at2026-10-13
19:36:03UTC:1864executed/0FAIL/2092excluded NOTPASS, raw8335138a/closure222df276,
allseals/normalcleanup PASS. Actual reviewed Astra utility attempt6 used no
owner/helper preload/source changes. Original targets59.315825s/59.820514s
approach unchanged60000ms; cause/waits/overhead UNKNOWN. Formatter-only diagnostic
does not supersede exact complete README FAIL. Next bounded causal measurement;
failedSol2/Astra4 unchanged, Task10/Phase5 NOT ACCEPTED, Task11/12 NO Source GO.
Historical phase/task receipts below
remain historical; E2ENOTRUN/frozen/defaultV2/publication restrictions persist.

**REVIEWED FOR IMPLEMENTATION — independent design and plan SPEC followed by
separate fresh QUALITY review have closed.** The coordinator verified the
reviewed design at 679 lines and this plan at 1,328 lines, SHA-256
`9ac947a920af6c95f8d9a20de2bbdac9c7038fccbea28618ea0968f812f7598b`.
That hash identifies the plan before this status update. The report retains
the original findings, bounded corrections and honest review coverage. Task 0
now executes; Phase 5 is IN PROGRESS, not implementation acceptance.
The governing [Phase 5 design](../specs/2026-10-11-singularity-v0.2-phase-5-export-backup-design.md)
was read completely at SHA-256
`8956200fb12784700b9148d6e94079eae08b3a1c282b41d09d0e95e27f5cf9d2`
(666 lines), then its reviewed §8 saga-order correction was inspected at
`3bf8957b42fd9136b23b4172ae17c7515d4e6c1486a735d996f088df0e7e7d3a`
(669 lines), then the reviewed requester-monitor handoff and additive Markdown
renderer clarifications were inspected at
`45ec328473ff1b92627ec27b6bbe21b4e18fdb02452b1d5affd8d09b2e150c6f`
(679 lines). These are historical design-read receipts, not the current
implementation baseline. The independently reviewed storage-reference
compatibility amendment was incorporated at
`e83f641f3e1bf1d83005c335401360b3766f416e64929d7fafbf99ef4be60230`.
The subsequent independently SOURCE SPEC/fresh QUALITY reviewed zero-only
Asset read amendment is incorporated in the current design at
`417844d47ca41a39c67face6a015097ea9d1bf64fa2a561bc50f457a2b59ed6b`.
Tasks 9 and 11 retain the reviewed storage-reference/integrity composition;
Task 13 retains its separately reviewed denial/audit and new-fixture reference
contracts; Task 14 incorporates only the reviewed zero-byte caller exception
and unchanged internal AEAD-record alignment. Other tasks and product
boundaries are unchanged. Task 14 still waits for Task 13's complete required
GREEN, actual independent reviews and local commit. If review changes the
design, reconcile every affected task and record the new hash before its
implementation. The complete
[master Phase 5 deliverables](2026-08-31-singularity-v0.2-release.md#phase-5--portable-export-backup-v3-restore-and-upgrade)
and §10 govern completion.

Task9E's new facade/size-proof/single fault-injection amendment has actual
NONAUTHOR DESIGN SPEC and distinct fresh QUALITY CLOSEDPASS/noP1P2 at exact
four-file hashes c161d673/bf434b49/78848c2e/13ba6ee2. Full parent/reviewer reads,
current source16/original frozen56/protected native5 checks and unchanged owning
baseline48pure/0+35SQL/0 with normalEMPTY/rootabsence precede test-only GO at
HEAD4e2499d. Prior C/D and Task14/15 evidence remains scoped history, not E
implementation qualification. All new native witnesses are NOT RUN; source GO
waits for complete causal RED. Architecture consumes zero repair rounds.

Use only `.trees/v0.2-phase-5-export-backup`, branch
`codex/v0.2-phase-5-export-backup`, based on documentation handoff
`5f7e6363be534dbfb4dfa1475538fddcbd29cf32`. Phase 4's tested implementation
source is `42c01a5c99b1df3d1e4284d277c6ea48046875cb`; the handoff is not a
new implementation qualification. Preserve main, other worktrees and unrelated
untracked files. The design and acceptance report are coordinator-owned.

The [initial Phase 5 report](../../verification/2026-10-11-phase-5-acceptance.md)
records a parent-executed clean baseline: seven full owning files, 136 tests,
zero failures, seed `215378`; compilation/format passed and xref had no cycles.
That was focused characterization, not SQL integration, V3, portable export,
the complete Phase 4 gate or implementation acceptance. This plan-writing task
runs no tests, Mix, formatter, databases, services, network or Git mutations.

Continuing user authority permits recommended in-scope implementation,
necessary repairs, forward migrations, documentation, independent review and
small local commits after review. It does not permit Vault feature work,
custody/key/capability/policy/crypto semantic changes, merge, push, version
bump, tag, release, deployment, production activation or production backfill.
New canonical writes remain unavailable to production runtime roles.
New backups use logical V3 after combined writer and restore qualification.
Explicit V2 retains its fail-closed unsupported-canonical guard.
Do not change frozen leases, use extraction authority for export, disable
triggers/RLS, synthesize sessions or use runtime commands to replay history.
The sole trigger exception is Task9E's review-gated, one-case
fault-injection contract in the compatibility design/plan: only the named
`document_fragments_immutable_guard` on `content.document_fragments`, only an
owned disposable migrated destination AFTER genuine import COMMIT, and only
the unreferenced old-ready nonhead ordinal1 canonical text/digest/id mutation.
Re-enable before corruption COMMIT, preserve all other triggers/RLS, prove exact
definition/enabled-state/RLS restoration and ordinary denial, then invoke the
helper in its fresh transaction. This necessary local test-contract authority
permits no production/released-migration bypass, shared corruption helper or
other disabled trigger. The selected test remains gated on the E amendment's
actual independent design reviews; it is not runtime evidence yet.
No browser/archive UI is added. E2E is manual-only **NOT RUN**, explicitly
deferred for local phase advancement; final browser/release acceptance remains
required. All other required gates and actual independent review must pass.

The narrow addition to `Runtime.IntegrityAudit.verify_final` in Task 9 passes
already authenticated plaintext evidence to a knowledge validator. Review and
report that exact compatibility seam; it must not change lease material,
cryptographic protocol, custody or completion authority.

The actual frozen `RestoreVault.restore_rewrapped/3` order is owner rewrap →
ciphertext verification → durable-work reconciliation → authenticated plaintext
and Document-source verification → projection rebuild → completion. Keep that
order and maintenance/dispatch barriers throughout. Reconciliation before the
plaintext stage is not publication; no running dispatch or exposed graph is
permitted while either integrity or projection verification remains incomplete.

## Source map and parent-owned execution discipline

| Responsibility | Files/modules |
| --- | --- |
| Frozen wire registries | `apps/singularity_storage/lib/singularity/storage/backup/logical_schema.ex`, `logical_schema_v2.ex`; never edit |
| V3/schema dispatch | New `backup/logical_schema_v3.ex`; existing `logical_record_codec.ex`, `logical_bundle_verifier.ex` |
| Complete cut and object inventory | Existing `backup/exporter.ex`; new forward backup-read/guard migration |
| Typed staging and preflight | New `backup/knowledge_preflight.ex`, `backup/knowledge_restore_digest.ex`; existing `backup/restorer.ex` |
| Historical admission and independent finalizer | New forward migrations after `20261011000200`; no edit to released migrations |
| Original evidence, search and work | New Storage `backup/knowledge_integrity_inventory.ex`, `backup/knowledge_integrity_audit.ex`; existing `backup/reconciler.ex`; narrow Runtime integrity call; preserve Base `backup/integrity_audit.ex` |
| Portable pure contract | New Core `knowledge_export.ex`, `knowledge_export_manifest.ex`; additive `note_markdown_sources.ex` entry point |
| Portable snapshot/read/write | New Storage `knowledge_export/repository.ex`, `knowledge_export/spool.ex`, `knowledge_export/writer.ex`; new Runtime `knowledge/export_snapshot.ex`, `knowledge/export.ex`, `knowledge/export_read.ex`, `knowledge/export_artifact.ex` |
| Public composition | Existing Runtime `api.ex`, `application.ex`; Task16 dedicated export-root setting in `config/dev.exs`, `config/test.exs`, `config/runtime.exs`; preserve existing production seams and architecture byte contracts |
| Deterministic fixtures and qualification | New support fixtures/tests listed in tasks; existing integration/restore tasks |
| Governance/operator evidence | `AGENTS.md`, `README.md`, `docs/guide.md`, master plan, Phase 5 design/plan/report and new portable-format documentation |

All abbreviated implementation paths below mean
`apps/singularity_storage/lib/singularity/storage/` unless explicitly written
in full. All test commands use full paths. Execute from the assigned worktree.
Use its isolated `_build` and only the existing locked dependency sources.

Parent owns all service, database, formatter, Mix and Git mutations; never run
two such operations concurrently. Workers have disjoint file ownership and
must be told they are not alone. Tasks 1 and 2 can proceed in parallel after
Task 0; all other dependencies are explicit. Parallel read-only investigations
and reviews are permitted; migrations, restore and live tests are serialized.
Track cumulative Sol repair rounds; at most two failed repair/validation
rounds before evidenced escalation. Architecture advice is not a repair round.
Characterize failures, amend the design when necessary, and preserve every
required assertion. Internal dependency blockers follow upstream issue routing.

Every task ends with the same concrete sequence: run the stated focused check
and its complete owning files; run `git diff --check`; self-review its source
against the design; independent SPEC review; fresh independent QUALITY review;
resolve findings and rerun only affected checks; stage exactly that task's
listed paths and make its stated local conventional commit. Never use `git add
.`. Record RED/GREEN commands, exit codes, test counts, source SHA, migration
IDs, changed files, reviewers/findings, repair counters and cleanup in the
acceptance report. An expected missing-module RED is not an implementation
repair. Do not record an expected result as an executed result.

At each task boundary and final handoff verify the parent's ignored frozen
baseline `.devenv/phase5-frozen-baseline.sha256`, SHA-256
`d0296d241c66e382baa09a0a092fe8add6df66364d5f2d5644f4f4ea1963a050`:

```sh
sha256sum .devenv/phase5-frozen-baseline.sha256
sha256sum -c .devenv/phase5-frozen-baseline.sha256
```

Expected: the baseline file hash matches and all 56 entries pass (43 existing
migrations plus 13 explicitly frozen source files). New forward migrations are
additive and are not entries in that historical baseline. This hash coverage is
not a claim that all 56 files were source-reviewed; do not stage ignored tooling
or regenerate baseline hashes from modified files.

The explicit 2026-10-19 native ownership exception changes only the expected
CURRENT check outcome after its reviewed implementation: run the original
manifest literally and retain exactly KeyCustodian/DownloadLease raw mismatches;
the other54 must pass raw. The new dedicated exact-hunk source contract must
reconstruct both original hashes by reviewed inverses and reject mutations.
The baseline itself and all historical all56 PASS receipts stay unchanged.
Do not report the expected two raw mismatches as all56 raw PASS or silently
filter them. Before native source changes the original all56 check still passes.

Focused pure check command pattern:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs --seed 215378 --warnings-as-errors
```

Focused SQL check pattern (the task accepts paths after the integration name):

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_schema_test.exs --seed 215378 --warnings-as-errors
```

SQL work requires the parent-owned isolated cluster, exact checked worktree
PGDATA/socket/port and existing external administrator bootstrap hook. Keep
EXIT cleanup. The harness allocates `singularity_test_<24 hex>` databases and
owned object roots; never use production, broad deletion or another worktree's
cluster. `MigrationTestEnvironment` is process-global and must be serialized.
Record shutdown/database/root cleanup after every failure and before handoff.

## Task 0: Preserve governance while advancing the active narrative to Phase 5

**Modify:** `apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs`,
`apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs`,
`AGENTS.md`, `README.md`, `docs/guide.md`.
**Record:** coordinator-owned Phase 5 design/plan and acceptance report.
**Depends on:** independent design/plan review resolving the draft condition.

- [x] Write active guidance tests requiring Phase 5 design/plan narrative links,
  exact Phase 4 tested SHA and handoff, the retained qualified Phase 3/4 history,
  V3 preparation default V2, closed production writes, Vault freeze and E2E
  deferral. Change only current active-phase expectations; retain all historical
  assertion bodies, exact ordered five governing-document bullets, complete
  continuous-authorization/protocol assertions and mutation/removal/duplication/
  relocation counterexamples. Add this direct assertion to the active section:

```elixir
assert section =~ "The active implementation slice is Phase 5"
assert section =~ "42c01a5c99b1df3d1e4284d277c6ea48046875cb"
assert section =~ "5f7e6363be534dbfb4dfa1475538fddcbd29cf32"
assert section =~ "2026-10-11-singularity-v0.2-phase-5-export-backup-design.md"
assert section =~ "2026-10-11-singularity-v0.2-phase-5-export-backup.md"
assert section =~ "New canonical writes remain unavailable to production runtime roles."
```

  Add an authority-contract test reading this plan between
  `## Status, evidence and execution boundary` and
  `## Source map and parent-owned execution discipline`, design §1 between
  `## 1. Baseline, scope, and fixed boundaries` and `## 2. Evidence and selected approach`,
  and design §6 between `## 6. Logical V3 wire schema and inventory` and
  `## 7. Semantic preflight and historical admission`. Require the actual
  production-write prohibition and staged default-V2/closed-guard declarations
  there as active prose, not a quoted command/test fence. Preserve historical
  Phase 3/4 authority tests and active-prose negative assertions.

- [x] Run both full governance suites before documentation edits:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --seed 215378 --warnings-as-errors
```

  Expected RED: current active narrative is Phase 4; old negative/historical
  assertions still pass. An unrelated failure is diagnosed, never stripped.
- [x] Add only narrative links outside the five governing bullets and update
  active guidance to: `The active implementation slice is Phase 5 under` the
  design/plan; Phase 4 accepted at the exact tested SHA, documentation handoff
  at the exact base; `Logical V3 preparation keeps default V2 and the current
  unsupported-canonical guard closed until writer and restore qualify together.`
  Keep historical Phase 4 design/plan exclusions historical and intact.
- [x] Run both complete suites to GREEN, format/compile/xref and diff checking.
  No application/guard/runtime baseline-stripping change belongs to this task.
- [x] Complete SPEC then QUALITY, record the unaccepted Phase 5 status and
  commit `docs: start phase five export and backup qualification` using exactly
  the reviewed guidance/contracts and Phase 5 documents.

## Task 1: Explicit isolated V3 schema and codec/verifier support, default V2

**Create:** `apps/singularity_storage/lib/singularity/storage/backup/logical_schema_v3.ex`,
`apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs`.
**Modify:** Storage `backup/logical_record_codec.ex`, `backup/logical_bundle_verifier.ex`,
their complete existing tests.
**Depends on:** Task 0; independent of Task 2.

- [x] Add RED pure schema tests with an independent literal schema contract:

```elixir
assert LogicalSchemaV3.version() == 3
assert LogicalSchemaV3.count() == 38
assert LogicalSchemaV3.column_count() == 367
assert Enum.take(LogicalSchemaV3.all(), 30) ==
         Enum.map(LogicalSchemaV2.all(), &Map.put(&1, :version, 3))
assert Enum.map(Enum.drop(LogicalSchemaV3.all(), 30), & &1.ordinal) == Enum.to_list(30..37)
assert LogicalRecordCodec.default_version() == 2
assert LogicalRecordCodec.tables() == LogicalSchemaV2.tables()
```

  Assert every appended column/tag/nullability/PK position below literally;
  missing/excess/reordered columns, wrong PK and nullable required values fail.
  Freeze V1 and V2 file hashes `ba0722ca85ce0a1259ce650927aa53ed728db0b28467adf308c3ada5a03036e8`
  and `992ef89fb52a91ccaa0d7cf2b3ae6607a465e7b345cca5d6c55a86c3fac9f3e6`.
- [x] Run the new schema file plus the codec/verifier and V1 owning files:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_schema_v3_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_record_codec_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_bundle_verifier_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
```

  Expected RED: missing V3 registry/dispatch; existing default V2 assertions pass.
- [x] Implement V3 by copying no V1/V2 source: map `LogicalSchemaV2.all()` with
  only `version: 3`, then append eight explicit definitions. Build the same
  `all/tables/count/column_count/fetch_table/fetch_ordinal` registry interface.
  Use these exact ordered definitions (`?` marks nullable, not part of name):

```text
30 content.document_versions; PK 0:uuid
resource_version_id:uuid resource_id:uuid vault_id:uuid classification:text
source_asset_id:uuid source_resource_id:uuid source_resource_version_id:uuid
source_object_id:uuid source_digest:bytes source_byte_size:integer media_type:text
title:text created_by_principal_id:uuid state:text attempt_generation:integer
extraction_adapter:text? extraction_format:integer? extracted_text_digest:bytes?
detected_language:text? failure_code:text? attempt_finished_at:timestamp?
inserted_at:timestamp attempt_job_id:uuid? attempt_started_at:timestamp?
attempt_deadline_at:timestamp?
31 content.document_fragments; PK 0:text
id:text resource_id:uuid resource_version_id:uuid vault_id:uuid classification:text
ordinal:integer text:text digest:bytes locator:json inserted_at:timestamp
32 content.document_import_receipts; PK 0:uuid 1:uuid 2:uuid
vault_id:uuid principal_id:uuid mutation_id:uuid request_fingerprint:bytes
state:text resource_id:uuid? version_id:uuid? inserted_at:timestamp
33 content.note_attachments; PK 0:uuid 1:uuid
note_resource_version_id:uuid id:uuid note_resource_id:uuid vault_id:uuid
classification:text target_resource_id:uuid target_resource_version_id:uuid
target_kind:text ordinal:integer role:text label:text? inserted_at:timestamp
34 content.note_citations; PK 0:uuid 1:uuid
note_resource_version_id:uuid id:uuid note_resource_id:uuid vault_id:uuid
classification:text source_resource_id:uuid source_resource_version_id:uuid
fragment_id:text locator:json ordinal:integer inserted_at:timestamp
35 content.tags; PK 0:uuid
id:uuid vault_id:uuid classification:text display_value:text normalized_key:text
created_by_principal_id:uuid inserted_at:timestamp
36 content.resource_tags; PK 0:uuid 1:uuid 2:uuid
resource_id:uuid tag_id:uuid vault_id:uuid classification:text inserted_at:timestamp
37 content.relationships; PK 0:uuid
id:uuid vault_id:uuid classification:text source_resource_id:uuid
target_resource_id:uuid target_resource_version_id:uuid? type:text
created_by_principal_id:uuid inserted_at:timestamp
```

  Register explicit `schema_for(3)` in codec/verifier and extend `1 | 2` types
  to `1 | 2 | 3`; leave `@default_version 2`, its typespec, and default test intact.
  No restorer or writer default enablement yet; no guard exception. Preserve
  explicit `Restorer.import` rejection of version 3 until the bounded complete
  historical import task is implemented; Task 1 never adds `logical_schema(3)`.

  The registry construction after the literal `@definitions` tuples is:

```elixir
@appended_schemas @definitions
                  |> Enum.with_index(30)
                  |> Enum.map(fn {{table, columns, primary_key}, ordinal} ->
                    %{
                      version: 3,
                      ordinal: ordinal,
                      table: table,
                      columns: Enum.map(columns, fn {name, tag, nullable?} ->
                        %{name: name, tag: tag, nullable?: nullable?}
                      end),
                      primary_key: Enum.map(primary_key, fn {position, tag} ->
                        %{position: position, tag: tag}
                      end)
                    }
                  end)
@schemas Enum.map(Singularity.Storage.Backup.LogicalSchemaV2.all(),
           &Map.put(&1, :version, 3)) ++ @appended_schemas
@by_table Map.new(@schemas, &{&1.table, &1})
@by_ordinal Map.new(@schemas, &{&1.ordinal, &1})

@spec version() :: 3
def version, do: 3
@spec all() :: [map()]
def all, do: @schemas
@spec tables() :: [binary()]
def tables, do: Enum.map(@schemas, & &1.table)
@spec count() :: pos_integer()
def count, do: 38
@spec column_count() :: pos_integer()
def column_count, do: 367
@spec fetch_table(term()) :: {:ok, map()} | :error
def fetch_table(table) when is_binary(table), do: Map.fetch(@by_table, table)
def fetch_table(_), do: :error
@spec fetch_ordinal(term()) :: {:ok, map()} | :error
def fetch_ordinal(ordinal) when is_integer(ordinal), do: Map.fetch(@by_ordinal, ordinal)
def fetch_ordinal(_), do: :error
```

  Construct each definition as `{table, [{name, tag, nullable?}], [{position,
  tag}]}` using the complete ordered contract above; for example the receipt
  definition is exactly:

```elixir
{"content.document_import_receipts",
 [
   {"vault_id", "uuid", false}, {"principal_id", "uuid", false},
   {"mutation_id", "uuid", false}, {"request_fingerprint", "bytes", false},
   {"state", "text", false}, {"resource_id", "uuid", true},
   {"version_id", "uuid", true}, {"inserted_at", "timestamp", false}
 ], [{0, "uuid"}, {1, "uuid"}, {2, "uuid"}]}
```

  Add the codec alias/table/schema clauses explicitly:

```elixir
alias Singularity.Storage.Backup.LogicalSchemaV3
def tables(3), do: LogicalSchemaV3.tables()
defp schema_for(3), do: {:ok, LogicalSchemaV3}
```

  Put clauses before existing fallback clauses. Verifier gets the same alias
  and private schema clause; its authenticated mixed-version checks stay intact.
- [x] Add independent explicit V3 cut/row/object literal golden cases, wrong
  count/vector/schema, malformed version 3 and mixed `3↔1`, `3↔2` row/object
  cases for both verifier entry paths. The current unknown-version fixture at
  verifier line 445 mutates to `3`; change that unknown value to `4` while
  retaining its exact rejection assertion. Assert `0`, `4` and forged terms fail.
- [x] Run all four full files to GREEN, verify frozen registry hashes/diff,
  SPEC then QUALITY, commit `feat(backup): define explicit logical v3 wire schema`.
  Exhaustive current-DDL comparison is Task 3's first SQL check; pure registry
  tests alone do not establish database schema agreement.

## Task 2: Pure portable options, safe paths, descriptors and ordinary Markdown

**Create:** `apps/singularity_core/lib/singularity/core/knowledge_export.ex`,
`apps/singularity_core/lib/singularity/core/knowledge_export_manifest.ex`,
`apps/singularity_core/test/singularity/core/knowledge_export_test.exs`,
`apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs`.
**Modify:** Core `note_markdown_sources.ex`, `note_markdown_sources_test.exs`.
**Depends on:** Task 0; independent of Task 1.

- [x] Write focused RED tests for strict options, manifest fields, UUID/version
  paths, deleted-source metadata and relative Markdown source links. Examples:

```elixir
assert {:ok, %{include_tombstones: false}} = KnowledgeExport.options(%{})
assert {:error, %Error{code: :invalid}} = KnowledgeExport.options(%{owner_scope_id: id})
assert {:error, %Error{code: :invalid}} = KnowledgeExport.options(%{destination: "/tmp"})
assert {:ok, "notes/" <> basename} = KnowledgeExport.path(:note, resource, version, nil)
assert basename == resource <> "--" <> version <> ".md"
assert {:error, %Error{code: :invalid}} = KnowledgeExport.path(:note, "../x", version, nil)
```

  Use canonical fixture UUID literals from the existing Core tests. Require
  boolean `include_tombstones`; reject unknown/string-duplicate keys, forged
  structs, caller scope/adapters/paths and unsafe IDs. Media mapping is exactly
  PDF→pdf, Markdown→md, text/plain→txt; Asset pins use `.bin`.
- [x] Run new Core files and the full existing Markdown sources file. Expected
  RED: constructors/portable renderer missing; existing text-only renderer passes.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_core/test/singularity/core/knowledge_export_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs --seed 215378 --warnings-as-errors
```

- [x] Define pure `KnowledgeExport.options/1`, `path/4`, `relative_source_path/2`
  and `limits/0`. Define `KnowledgeExportManifest.record/2` and `header/1`:
  reconstruct only the exact allowed record keys in design §5; validate canonical
  UUIDs, kind/state/availability, UTC microseconds, lowercase SHA-256, integer
  ordinals and nullable field shapes. All version fields are always present;
  no owner/principal/key/storage/session/receipt/job fields can be carried through.
  Files omit manifest.json; its descriptor is delivered separately.
- [x] Add `NoteMarkdownSources.render_portable/3` accepting canonical body,
  existing typed attachment/citation descriptors and a validated exact-version
  file map. Reuse escaping/fence/footnote logic while preserving `render/2`
  output bytes and its text-only header. Portable header declares included
  files; unavailable sources have readable metadata/locator/reason and no false
  file link. Compute relative paths from the containing Note directory; never
  use a proprietary URI. Preserve user body, existing footnote labels and
  separately record canonical-body and rendered-file digests.
- [x] Require tests for duplicate titles, hostile labels, brackets/parentheses,
  control characters, existing footnotes/open fences, URL escaping, absolute/
  traversal/NUL/symlink/case-fold collisions and two historical versions of one
  Document. Fixed global limits are 100,000 keys, 1,000,000 metadata records,
  1 GiB metadata, 64 GiB file bytes, 15 minutes, 500 rows/page, 64 KiB chunks;
  retain stricter Note/Document/fragment limits. No SQL/filesystem imports in Core.
- [x] Run complete owning files to GREEN, format/compile/xref/diff, SPEC then
  QUALITY; commit `feat(export): define portable knowledge values and markdown`.

## Task 3: Freeze current DDL agreement and build independent whole-graph fixtures

**Create:** `apps/singularity_storage/test/support/knowledge_backup_fixtures.ex`,
`apps/singularity_storage/test/singularity/storage/backup/logical_v3_schema_ddl_test.exs`,
`apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs`,
`apps/singularity_storage/test/fixtures/backup/logical-v3-schema.json`.
**Read/reuse:** existing `support/fixtures.ex`, `note_fixtures.ex`,
`knowledge_fixtures.ex`, `migration_test_environment.ex`, `backup/restore_import_test.exs`.
**Depends on:** Task 1.

- [x] Add the first scoped SQL RED contract: query `pg_attribute`, `pg_type`,
  `pg_index`, `pg_constraint` for all 87 appended columns and exact ordered PK
  positions. Match `uuid/text/bytea/bigint/integer/jsonb/timestamptz`, effective
  required/nullability and wire order. V2 uses historical wire projection order,
  not arbitrary `SELECT *`. Verify exactly eight appended tables/87 columns.
- [x] Run the schema-DDL and fixture contracts through the isolated integration
  task; missing fixture support is RED. Confirm an intentionally wrong type,
  missing column or swapped PK makes the contract fail, then remove only that
  test-local perturbation. Do not mutate actual DDL to test the test.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_schema_ddl_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs --seed 215378 --warnings-as-errors
```

- [x] Implement `KnowledgeBackupFixtures.seed!/1`, `canonical_rows/1`,
  `source_bytes/1`, `search_rows/1`, `verified_bundle/2`, `malformed_bundle/2`
  and `with_destination/2`. These are test helpers, not production interfaces.
  `seed!` returns owner/session IDs, stable logical row/byte oracles and all
  exact immutable IDs. `with_destination` owns a disposable migrated database
  and random object root and restores process-global configuration in `after`.
  Canonical comparisons use the explicit typed column projections and sorted
  PKs, excluding only established V2 identity transformations and derived state.
- [x] Seed live/deleted Notes, history, unresolved and resolved conflicts,
  merge ancestry and every Document state through established lifecycle SQL/
  runtime test seams; ready fragments come from real canonical constructors.
  Seed old/current Document versions, same-object deduplication, binary PDF,
  empty/plain/Unicode text, Markdown, completed import receipts, tags, edges,
  exact attachments/citations and all valid durable work. Delete the source
  Asset and release its association/clear its current object pointer while
  retaining a live and tombstoned historical Document original. Capture the
  unchanged `source_object_id/digest/byte_size` as the independent oracle.
- [x] Build fixed malformed logical records by changing one literal field and
  authenticating the fixture using the existing test crypto seam. A writer
  round trip is not the malformed/golden oracle. Store only sanitized synthetic
  fixture content; no real credentials/user content. Immutable V1 fixture stays
  byte-identical; fixed V2 vectors stay explicit version 2. V1 fixture encoding
  continues through the frozen codec/golden path, never a new V1 Exporter writer.
- [x] Assert fixture legality independently before testing export/restore;
  do not bypass source seals, lifecycle or constraints. Run owning fixtures/
  schema files to GREEN; SPEC then QUALITY, commit
  `test(backup): add independent v3 history and ddl fixtures`.

Task3 accepted locally at `465c377ade63b38bccabcac729e998ddc61ba473` after
the complete 18/0 owning SQL rerun, static gate, legacy SQL and 186/0 downstream
regressions. The non-author SOURCE SPEC closure carried its full prior source
review and read the complete bounded wrapper repair/new contract; a separate
fresh non-author SOURCE QUALITY read all four current files,2,680 lines, and
passed without findings. Exact receipts and coverage limitations are recorded
in the acceptance report. This closes only the fixture slice, not Phase5 or
live runtime acceptance. E2E remains NOT RUN.

## Task 4: Authenticate, type-stage and preflight before canonical mutation

**Create:** `apps/singularity_storage/lib/singularity/storage/backup/knowledge_preflight.ex`,
`apps/singularity_storage/lib/singularity/storage/backup/knowledge_restore_digest.ex`,
`apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs`,
`apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_digest_test.exs`.
**Modify:** Storage `backup/restorer.ex` only its V3 staging entry path.
**Necessary test-contract changes:** `apps/singularity_storage/test/support/knowledge_backup_fixtures.ex`
for genuine authenticated row/object transforms and the two generation-zero
idempotency literals; `apps/singularity_storage/test/singularity/storage/backup/knowledge_backup_fixtures_test.exs`
for the actual seeded-envelope decoder regression. The frozen producer/decoder
and all prior assertions remain unchanged; RED, diagnosis and bounded correction
are recorded in the acceptance report under continuous development authority.
**Depends on:** Tasks 1 and 3; does not enable V3 canonical import.

- [x] Add RED tests calling `KnowledgePreflight.stage/4` with an authenticated
  `%BundleReader.Verified{replay: %BundleReader.Replay{}}`, bound manifest/cut, migration connection and
  owned object staging adapter. Reject unauthenticated data before creating
  staging. Inspect canonical table counts before/after every rejection:

```elixir
before = KnowledgeBackupFixtures.canonical_rows(owner)
assert {:error, %Error{code: :backup_invalid}} =
         KnowledgePreflight.stage(repo, verified, cut, storage)
assert KnowledgeBackupFixtures.canonical_rows(owner) == before
```

- [x] Run the full preflight integration file; expected RED is missing stage
  implementation. Implement connection-local typed temporary tables with fixed
  compile-time identifiers/projections, `ON COMMIT DROP`, exact PK/secondary
  unique indexes and at most 500-row insertion batches. Consume bounded
  authenticated records and staged object chunks; never collect full text/
  fragments or execute bundle-supplied identifiers/functions. Retain 64 KiB
  header, 16 MiB record, 999,999 frame limits and immutable replay verification.
  `BundleReader.reduce_verified/3` events are provisional until its final authentication
  succeeds: effects stay in the uncommitted transaction and unpublished owned
  object stages. Keep the existing Verified/Replay types and crypto path.
- [x] Define `KnowledgePreflight.validate/3` to return only bound counts,
  canonical per-table digests and typed staged ownership after all joins pass.
  Check owner/classification/creator/membership; typed heads; Note digests,
  revisions/parent/merge DAG/conflicts; Document immutable historical source
  identities, retained object/size/format and attempt-state shapes; ready-only
  fragments with canonical IDs/locators/text hashes/contiguous ordinals and
  concatenated extracted hash; Note source types/owners/ordinals/uniqueness/
  no self links/limits/exact locator; tag Core normalization/owner uniqueness;
  edge types/version ownership; completed receipts and durable payload shapes.
  Every extraction event's expected generation must be no greater than its
  pinned Document version's persisted generation. Preserve legal pending
  equality and older/stale events; the current extracting job still requires
  exactly persisted generation minus1. Characterize with genuine authenticated
  undispatched events, not a forged Verified or syntactically invalid key.
- [x] Define `KnowledgeRestoreDigest.projection/1` from the immutable registry
  and `table_digest/3` using sorted PKs and explicit typed length-framed row
  encoding. Both staged and canonical rows use the same projection; never hash
  generic maps, destination-selected metadata or unstable timestamps. For byte
  values use their bytes; for UUIDs canonical 16 bytes; for timestamp exact UTC
  microseconds; frame null independently from empty; JSON uses canonical sorted
  object encoding. Freeze independent vectors for null/empty/multibyte/JSON and
  equal-count row changes. Expected digests are computed from authenticated
  staged rows before admission. SQL finalization must use the identical encoding.
- [x] Reject duplicates, mixed versions, extra/missing rows, wrong counts,
  dangling/cross-owner/type references, cyclic Note ancestry, incorrect fragment
  IDs/ordinals/locators/digests, non-ready fragments, unsupported formats,
  pending receipts, receipt disagreement, ambiguous Asset bindings and malformed
  job provenance. Historical released associations/nulled Asset pointers remain
  legal only with exact immutable Document pin and retained object.
- [x] Validate exact inventory union and evidence/raw one-to-one mapping;
  reject missing/extra foreign objects, truncated/changed ciphertext and lengths.
  Source plaintext hash comparison is deferred specifically to Task 9, not
  replaced with ciphertext hashing. Assert no canonical insert before complete
  preflight and bounded buffering with record/page observer barriers.
- [x] Run full file to GREEN:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs --seed 215378 --warnings-as-errors
```

  SPEC then QUALITY, commit `feat(restore): stage and preflight canonical v3 graph`.

### Task4 selected typed-digest and test-boundary detail

This implements the already required framed digest and its independent vectors;
it adds no product/API authorization or canonical V3 import. `projection/1`
returns the immutable V3 schema, never destination catalog metadata.
`table_digest(repo, table, :staged | :canonical)` returns a bound count/32-byte
SHA pair. Fixed staged relations are `pg_temp.knowledge_restore_0` through `_37`.
`install/1`, the fixed-tag, fixed-`value`-identifier `value_encoding_sql/1`
and fixed-registry `row_chunks_sql/2` are internal SQL compilation/test seams,
not runtime or bundle-selected SQL. The SQL side encodes bytes; Elixir streams
one at-most65,536-byte encoded-row slice per fetch and folds only a digest/count
and the current incremental hash context. Length is framed once per row;
the digest chain and count advance only after its final slice. Wire payload
limits remain unchanged: typed JSON framing can expand a legal16 MiB record.
No generic map/ETF/JSON text digest or Decimal rounding.

Let `U(n)` be unsigned 64-bit big-endian framing, within signed PostgreSQL
length/count limits, and `F(bytes) = U(byte_size(bytes)) || bytes`. Scalar tags
are boolean01, integer02, bytes03, text04, UUID05, timestamp06 and JSON07.
Every cell is `tag || presence || F(payload)`; presence00 for SQL NULL with
empty payload, presence01 otherwise. Payloads: Boolean00/01; signed big-endian
int64; raw bytea; UTF-8 text; canonical16-byte UUID; signed UTC epoch
microseconds; or the following recursive binary JSON:

- null00, false01, true02;
- number03 plus framed exact `trim_scale(numeric)::text`, no float/Decimal
  precision conversion (1/1.0/1e0 and -0/0 agree);
- string04 plus framed unescaped UTF-8;
- array05 plus element count, then framed recursively encoded elements;
- object06 plus key count, then framed key UTF-8 and framed encoded value,
  ordered by UTF-8 key bytes, not database locale.

Row bytes are `U(column_count)` followed by cells in immutable wire order.
Projection bytes `P` are `U(column_count)`, then each framed column name/tag/
nullable byte, then `U(PK_count)` and ordered zero-based PK positions. With
`domain = "singularity:knowledge-restore-digest:v1"`:

```text
D0 = SHA256(00 || F(domain) || U(3) || F(table_name) || F(P))
Di = SHA256(01 || D(i-1) || F(row_bytes_i))
final = SHA256(02 || Dn || U(row_count))
```

Native UUID/integer and byte-ordered text PK sorting is fixed. Task5 must
independently implement the identical protocol in owned, pinned SQL functions
and ordered cursors; it must not trust a caller-created pg_temp helper.
Independent scalar/JSON literal vectors include signed bounds, pre-epoch and
microsecond timestamps, multibyte/escaped strings, SQLNULL versus JSONnull,
empty containers, nested byte-sorted keys and numbers beyond34 digits. Literal
empty/two-row/reversed-row SHA vectors were calculated from separately framed
literal bytes before production code, not via the function under test.

Additional independent literal JSON/row vectors cover a legal wire row whose
framed row is16,785,376 bytes. Its exact SHA remains required, not an increased
wire limit. A separate real SafeSQL cursor contract observes only numeric chunk
lengths/offsets, proves at-most65,536-byte payloads and native PK order on reverse
inserted rows, and checks empty canonical/invalid-identifier selection. This
qualifies bounded client transport, not database/VM memory instrumentation.

Wire-invalid duplicates/mixed versions/order/count/evidence-raw equality are
rejected by the unchanged real verifier before Replay issuance; tests must not
forge Verified to shift those failures to Stage. Coherently counted semantic
graph and object-row/evidence disagreement negatives use genuine Replay.
Stage/validate share the caller migration transaction and use local savepoint
rollback plus an independent owned-stage cleanup ledger on failure. A narrowly
scoped trusted numeric observer measures real batches/metadata/object appends;
it makes no VM-memory or disabled Ecto-telemetry claim. Source plaintext SHA
equality remains Task9; Notes have no invented SHA column. E2E stays NOT RUN.

Task4 accepted locally at `854fad69915c937fe7dcdec0a12a6d487fffb7f6`
after owning27/0, post-repair static gate and actual independent full SOURCE
SPEC→bounded finding closure→fresh full SOURCE QUALITY. Exact reviewed source,
test and document receipts/coverage are recorded in the acceptance report.
This post-verdict checkpoint is not retroactively part of those reviews.
Canonical V3 import/default activation remain closed. E2E is NOT RUN.

## Task 5: Migration-only transaction-bound admission and deferred finalizer

**Create:** `apps/singularity_storage/priv/repo/migrations/20261011000300_knowledge_restore_admission.exs`,
`apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs`.
**Modify:** `knowledge_preflight.ex`, `knowledge_restore_digest.ex` for the
  explicit staged-to-destination verification call, not runtime authorization.
**Depends on:** Task 4.

- [x] Write RED SQL counterproofs for actual `session_user` web/worker/
  dispatcher/pre-auth connections, spoofed GUCs, table-owner SECURITY DEFINER
  nesting, absent advisory lock, wrong pending saga/owner/manifest/hash,
  nonempty destination, wrong backend/transaction, stale records, missing
  finalizer and post-validation equal-count mutation. Every failure must occur
  at admission, write or commit with no partial canonical visibility.
- [x] Run the admission integration file; expected RED: no admission relation/
  helpers. Create only `audit.knowledge_restore_admissions`, owned by
  `singularity_table_owner`, columns for manifest/owner/authenticated hash,
  full transaction `xid8`, backend PID, expected counts/per-table digests and
  loading/validated state. Exclude it from wire/export/destination canonical
  digests; no PUBLIC/runtime relation/helper grants. Pin helper search paths.
- [x] Implement admission functions `audit.begin_knowledge_restore`,
  `audit.validate_knowledge_restore`, `audit.knowledge_restore_is_bound` and
  `audit.enforce_knowledge_restore_final` with migration-only exact authority:

```sql
IF session_user <> 'singularity_migration'
   OR NOT pg_has_role(session_user, 'singularity_table_owner', 'SET') THEN
  RAISE EXCEPTION 'knowledge restore authority unavailable' USING ERRCODE='42501';
END IF;
```

  Bind `pg_current_xact_id()` and `pg_backend_pid()`, exact authenticated saga,
  owner/hash/manifest, loading state, empty destination and existing advisory
  lock `hashtextextended('singularity:restore-import:v1',0)`. Verify owned lock
  through exact `pg_locks` identity; acquiring a caller-specified lock is not
  proof. Helpers recheck binding, not a caller Boolean or GUC.
- [x] Add an initially deferred constraint trigger on admission insert/update:

```sql
CREATE CONSTRAINT TRIGGER knowledge_restore_final_check
AFTER INSERT OR UPDATE ON audit.knowledge_restore_admissions
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
EXECUTE FUNCTION audit.enforce_knowledge_restore_final();
```

  Re-read the final admission state and revalidate complete structural graph,
  every canonical count and per-table staged digest at commit. `validated`
  without actual equality fails. Explicit finalization alone is insufficient:
  later equal-count mutation, source-seal changes or missing rows must fail.
  Keep established V2 identity transformations separately verified, never
  exempt knowledge rows. Migration teardown is forward-only, not rollback of
  a released migration. Never alter role membership/attributes or Vault policy.
- [x] Run the full admission file and existing RLS/grant/schema files to GREEN:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs apps/singularity_storage/test/singularity/storage/knowledge_schema_test.exs --seed 215378 --warnings-as-errors
```

  SPEC then QUALITY, commit `feat(restore): bind historical admission to maintenance transaction`.

### Task5 selected admission, SQL oracle and commit-proof details

These choices implement approved design §7, not an expansion of runtime or
Vault authority. The singleton admission has boolean PK/CHECK, manifest/vault
UUIDs, 32-byte authenticated manifest hash, full `xid8`, backend PID, exactly
38 expected counts/digests and loading/validated state. Arrays must be
one-dimensional/lower-bound1, nonnull, counts nonnegative and each digest32
bytes. Store immutable full pending-saga snapshot: manifest tag16, inventory
hash32, destination-root hash32 and object count. Derive this snapshot from
the locked existing saga, not caller-supplied GUCs. Entry APIs are:

```sql
audit.begin_knowledge_restore(uuid,uuid,bytea,bigint[],bytea[]) RETURNS void
audit.validate_knowledge_restore(uuid,uuid,bytea) RETURNS void
audit.knowledge_restore_is_bound(uuid) RETURNS boolean
audit.enforce_knowledge_restore_final() RETURNS trigger
```

All relations/functions are table-owner owned, pinned to `pg_catalog`, fully
qualified, and revoke PUBLIC/runtime access. Check exact migration session and
existing table-owner SET authority. Check the current backend's granted
exclusive bigint advisory lock, using exact database/classid/objid/objsubid
identity for `hashtextextended('singularity:restore-import:v1',0)`; a different
lock or another backend's lock is not proof. Admission checks the full empty
destination union, including derived seals/excluded runtime tables. Immutable
binding/count/digest values cannot be rewritten; only defined validated-state
transition is permitted. Loading historical-write authorization requires the
same pending saga/current backend/full transaction. Validated rows never grant
historical writes. At final COMMIT allow only the same bound saga still pending
or legitimately imported: existing Restorer marks it imported before COMMIT.
Later saga states and stale admission rows do not authorize another transaction.

Private fixed SQL seams `audit.knowledge_restore_json_bytes(jsonb)` and
`audit.knowledge_restore_table_digest(integer)` implement Task4's exact framed
protocol independently; the latter returns `row_count bigint,digest bytea`
for a closed ordinal0..37. Inline frozen projections/types/PK positions and
ordered one-row cursors; no caller relation/SQL, destination-selected projection,
pg_temp encoder or whole-table aggregation. Legal typed row expansion does
not impose a new16 MiB framed-row cap. Private
`audit.assert_knowledge_restore_graph(uuid)` checks canonical structural history,
scope/typed heads/parents/source pins/fragments/source sets/organization/work
and exact derived seals independently. Existing FK/CHECK/immutability stays on.
Core Unicode Tag normalization remains genuine preflight plus exact all-field
digest equality; PostgreSQL lower() is not substituted for Core NFC/casefold.

Preserve authenticated manifest/hash/tag/inventory and private destination
binding in the typed Staged handle; never detach a caller-provided summary as
authorization. Expected destination digests derive before canonical insertion
from authenticated staging. The only established V2 wire-value transformation
is `core.vaults.locked=true`; retain raw staged digests and separately qualify
this transformed expectation. Omitted credential verifier/version/updated-at
and pending wrapper compatibility values remain separately checked; no knowledge
field is exempted or substituted. SQL does not itself authenticate the bundle.

Use genuine sequential source/different fresh destination databases. Reduce the
disposable authenticated fixture to live-compatible pending Document/original,
initial Note with Asset attachment, tag/assignment/pinned relationship and
completed receipt; keep real crypto/Reader/Replay and normal guards. Preserve
encrypted bytes in a test-owned private path and freshly authenticate them after
the source environment closes, rather than carrying a discarded Replay.
Historical deleted-source/ready-fragment insertion belongs to Task6, not a
disabled-trigger Task5 positive. Stage all38 expectations before admission.

Commit counterproofs let callbacks return normally and observe actual COMMIT,
then independently verify no canonical visibility. Cover omitted validation,
equal-count valid row mutation after validation, missing/inconsistent seals,
wrong full marker/backend/fullxid8, stale records and actual runtime sessions,
GUC spoof and table-owner SECURITY DEFINER nesting. Keep the admission constraint
trigger deferred while forcing only the fixed ordinary deferrable constraints:
`SET CONSTRAINTS ALL IMMEDIATE` would drain its queued COMMIT check. Later Task7
must preserve this queue and test its exact prepublication sequence. No V3 import
or historical guard branch is enabled by Task5. SPEC then fresh QUALITY remain
required; E2E stays NOT RUN.

Task5 qualification: actual first causal RED, initial two test-probe failures,
bounded assertion-preserving test correction, complete owning50/0,
Stage/Digest/genuine-fixture40/0, legacy/DDL15 actual SQL/0, pure186/0 and
full static/no-cycle gate completed. Fresh non-author full SOURCE SPEC followed
by separate fresh full SOURCE QUALITY returned PASS with no findings, reading
all four source files,5,044 lines. Exact receipts, native verdicts, original
failures, commands, cleanup and counters are in the acceptance report. The
parent committed exactly seven paths locally at
`4f9cf6a91a80e1cdb7213d0cd942be96d69d982a`; Phase5 remains incomplete,
Task6 historical guards and canonical V3 import/default remain closed.

## Task 6: Narrow historical guard branches with live constraints intact

**Create:** `apps/singularity_storage/priv/repo/migrations/20261011000400_knowledge_historical_restore_guards.exs`,
`apps/singularity_storage/test/singularity/storage/backup/knowledge_historical_admission_test.exs`.
**Read:** released `20260906000100`, `20260906000200`, `20260906000300`,
`20260922000100`, `20261011000000`, `20261011000200` migrations in full.
**Depends on:** Task 5.

- [x] Add RED real SQL insertion cases restoring a deleted Document whose source
  Asset is deleted, association released and Asset object pointer null; exact
  ready version/fragments; historical deleted Note targets; tags/edges on
  tombstoned endpoints. Add identical attempted live-runtime cases that fail.
- [x] Run the historical-admission file before the forward migration; expected
  RED is the current creation-time live/ready seal guard, not a failed FK ignored
  by the test. Implement explicit restore validators within these four functions:
  `content.enforce_document_source`, `content.enforce_document_fragment`,
  `content.enforce_note_source_set`, `content.enforce_knowledge_organization_resource`.
  Preserve normal branch behavior and all immutable/FK/CHECK/completion guards.
  There is no broad early `RETURN NEW`, trigger-disable or live-row rewriting.
- [x] Historical Document admission checks source Asset/version/association
  identity and owner/type agreement independently of current release/liveness;
  compare retained object/size/classification to immutable pin. Historical ready
  fragment INSERT requires exact admitted version and canonical digest/locator;
  UPDATE/DELETE stay forbidden. Note source admission checks exact historical
  source/fragment/locator/owner/kind/ordinals and seal binding, never substitutes
  a current head. Organization history checks exact typed endpoints and pinned
  versions with all natural uniqueness retained.
- [x] Assert actual runtime SQL still cannot append to ready fragments, sealed
  empty/nonempty sets, link deleted sources, change immutable pins or create
  organization edges on deleted endpoints. Wrong object, wrong source identity,
  cross-owner, missing fragments or unbound migration transaction also fail.
- [x] Run the new full file plus complete lifecycle/source/organization owners:

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_historical_admission_test.exs apps/singularity_storage/test/singularity/storage/document_lifecycle_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_asset_lifecycle_guards_test.exs apps/singularity_storage/test/singularity/storage/note_source_set_sealing_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs --seed 215378 --warnings-as-errors
```

  SPEC then QUALITY, commit `feat(restore): validate history without weakening live guards`.

The Task6 owning gate includes the complete established Note source-set sealing
and Note source repository files, not selected cases. Replacing their source
guard requires direct retained-source/merge/order/seal regression coverage as
well as the original Document/organization owners. This is a verification-only
amendment; no established assertion or source file is changed. The isolated
private PostgreSQL wrapper serializes parent-owned execution. E2E is NOT RUN.

The first complete implementation run executed15 tests, with13 passing and
two failures. The new test's ten independent bound-immutability cases are
split into ten ExUnit tests under the unchanged default timeout, retaining
all15 semantic groups, both sealed-append cases, all native mutation/error/
phase/rollback assertions and fresh authenticated source/destination for
every operation. The full file will therefore execute24 tests. A content-free
owned SQL diagnostic must expose the complete-history adapter rejection before
any production correction; matched38 digests and seals alone are not acceptance.
If the source-backed private payload-variable ambiguity is confirmed, use a
new forward migration rather than editing accepted00300. The intended change
is only unambiguous local-variable binding, with its existing private ownership,
ACL, security, search path and value predicates preserved. Record actual RED,
the necessary repair amendment and full subsequent regressions/reviews.

The actual whole-history diagnostic94926 confirmed SQLSTATE42702 on the
private extraction payload validator. Create only additive forward
`20261011000410_knowledge_restore_work_validation.exs`: replace the existing
private `audit.knowledge_restore_payload_is_valid(core.outbox_events)` with
an unambiguous local resource variable while preserving all value predicates,
signature, ownership/ACL/security and pinned search path. Accepted00300 stays
unchanged. Include new00410 in full source SPEC and fresh separate QUALITY;
rerun the complete24-case historical file and all six established owning files,
private-admission/DDL/legacy regressions, static and frozen checks before commit.

## Task 7: Ordered V3 canonical import and source-set finalization

**Modify:** Storage `backup/restorer.ex`, `knowledge_preflight.ex`.
**Necessary retained-owner contract sync:** `backup/knowledge_preflight_test.exs`,
its obsolete ordinary-import dispatch expectation/name and the characterized
22-variant Document-state group's independent-case split; preserve every
binding denial, original mutation and canonical/no-temp/no-stage/no-publication
assertion, helpers and default timeout.
**Create:** `apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs`.
**Retain owners:** existing `backup/restore_import_test.exs`, `logical_v1_compatibility_test.exs`.
**Depends on:** Tasks 5 and 6.

- [x] Add RED import of the authenticated complete fixture into empty staging:
  canonical rows at the cut equal the independent oracle; source seals have
  exact membership digests/counts; no search/Oban/session/excluded receipts are
  imported. Verify V1/V2 still derive empty source sets, never Document rows.
- [x] Run all three full owning files before import changes. Implement explicit
  `logical_schema(3)` and replace destination locking/emptiness with the union
  of V1/V2/V3 tables plus established exclusions, derived seals and maintenance
  admission bookkeeping handled separately. A V1/V2 restore into a destination
  containing any V3 row must reject before writes.
- [x] Keep the existing migration-authority check and serializable/advisory saga.
  Authenticate/type-stage/preflight before canonical inserts; bind admission;
  insert established identities/opaque owner/key compatibility and generic
  resources/versions before Assets/envelopes/associations and typed knowledge.
  Preserve existing credential/wrapper/cleanup-principal transformations exactly.
- [x] Insert Document versions in their actual final state, then fragments and
  completed receipts; tags/assignments/relationships after their endpoints;
  all Note attachments/citations only after exact versions/fragments exist.
  Do not rely on the deferred V1/V2 Note INSERT seal trigger for V3; finalize each Note only
  after its entire set is present, including legitimately empty historical sets.
  Force the fixed ordinary/source/completion constraints while admission is
  still loading, keeping the admission final-check queue deferred. Then compare
  staged/canonical equality and graph/count/digests, mark validated, publish
  owned objects and mark imported. Historical Note source checks are deferred
  AFTER INSERT and need loading-state authority when they actually execute;
  validating first would incorrectly enter their ordinary live branch.
  Transaction-end independent validation remains enabled after explicit checking.
- [x] Add failure barriers before/after canonical insert, finalization, object
  publication and imported marker. Check full rollback/owned cleanup for known
  failure, identity-bound pending/imported recovery for uncertain commit and
  exact-manifest retries. Never resume a different manifest/destination or delete
  foreign objects. Imported verification also checks V3 rows and seal equality.
- [x] Run complete import/V1 files to GREEN:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs --seed 215378 --warnings-as-errors
```

  Actual owning32/0, repaired Preflight39/0, complete retained334 SQL/0,
  pure5/0 and downstream186/0 passed on repair2. Format/compile/xref passed with
  zero cycles and frozen56+Task6+source receipts match. Formal actual NONAUTHOR
  SOURCE SPEC and separate fresh QUALITY passed on the final repair2 receipt.
  Parent locally accepts the exact source and verified local commit
  `3b2a1a43cfb0101a6ef57ee140b05021241fe6c1`
  (`feat(restore): import complete v3 history before sealing sources`).
  Phase5/Tasks8–19 are not accepted.

### Task7 selected fixed constraints and bounded native-row replay

Source-derived prepublication forcing covers the32 surviving ordinary
deferrable content constraints below (19 FKs,13 constraint triggers). Confirm
this exact set against the isolated current catalog during Task7 testing;
never select caller SQL or dynamically include the admission final check.
Every literal is qualified with `content.` in the actual SET statement:

```text
resource_versions_resource_classification_fkey
resources_version_head_fkey
note_versions_parent_fkey
note_versions_merge_parent_fkey
note_conflicts_base_version_fkey
note_conflicts_canonical_version_fkey
note_conflicts_competing_version_fkey
note_conflicts_resolution_version_fkey
note_mutation_receipts_resource_fkey
note_mutation_receipts_version_fkey
note_mutation_receipts_conflict_fkey
document_versions_resource_version_fkey
document_import_receipts_version_fkey
document_fragments_document_version_fkey
note_attachments_note_fkey
note_attachments_target_fkey
note_citations_note_fkey
note_citations_fragment_fkey
note_source_set_seals_note_fkey
note_versions_aggregate_check
note_mutation_receipts_resource_check
resources_00_typed_head_check
note_versions_00_typed_head_check
document_versions_00_typed_head_check
document_import_receipts_completed_check
document_versions_completion_check
document_fragments_completion_check
note_attachments_source_set_check
note_citations_source_set_check
note_versions_source_set_seal_check
note_attachments_source_set_seal_check
note_citations_source_set_seal_check
```

The obsolete `resources_note_version_head_fkey` was dropped by the Document
aggregate migration; it is not in this set. Keep
`audit.knowledge_restore_final_check` deferred through publication and actual
COMMIT. Existing Restorer has only ALL DEFERRED, not an existing ALL IMMEDIATE
path; current per-Note automatic sealing is also deferred, not immediate.

The V3 importer uses a narrow original-caller/repo/backend/full-xid bound
iterator over fixed native staged columns and PK order, one row per SQL fetch.
Its table order is explicit and dependency-safe; no caller relation/projection/
ordering/SQL. Do not re-encode temporary native rows through the wire codec:
legal JSON framing expansion can exceed the16 MiB wire-record bound. Retain
outbox `OVERRIDING SYSTEM VALUE`, all established credential/wrapper/cleanup
pointer transforms, one-use Replay disposal and owned artifact ledgers.

Imported-marker retry is read-only V3 row/digest/seal verification, not a reuse
of pending-only admission or another transaction's historical write authority.
It must not reinsert canonical rows or publish unintended objects. This section
records read-only source preparation, not an executed Task7 gate or acceptance.

Task7 implementation seam: keep `KnowledgePreflight.stage/4` behavior unchanged
and add only internal `stage_for_verification/4` sharing a private fixed-mode
authenticated implementation. Verification mode writes only temporary typed
relations and incrementally checks raw ciphertext lengths/hashes; it invokes no
object stage/append/seal/finalize/abort operation. Bind an explicit staged
purpose and disallow verification-only input from `begin_restore`. The eager
native-row reducer accepts either purpose only on its exact original caller,
repo, backend and full transaction, with fresh staged-summary equality before
consumption and identity rechecks. Use a new helper savepoint after the original
preflight validation releases its own; no escaped cursor or caller relation.
Imported verification compares all38 canonical digests, exact seal identities/
counts with their staged membership and exact published inventory. V1/V2
imported verification rejects extra V3 tables as well as taking the union locks.
Full established preflight/admission owner tests remain required after changes.

Actual Task7 full retained Preflight execution characterized the sole obsolete
Task4 ordinary-import expectation: the authenticated V3 fixture is also a
populated destination. Now that explicit V3 import is implemented, rejection
is `conflict`, not unsupported `backup_invalid`. Synchronize only that exact
final code and test name; malformed binding/cut still returns `backup_invalid`
and all18 cases and side-effect denials remain required. This is a necessary
phase contract repair under continuous authorization, not a validation waiver.
The added23rd native-row case uses two genuine committed outbox events whose
UUID PK order differs from identity sequence order. The protected wire remains
sequence ordered; the native iterator must use fixed registry PK order for all
38 tables, with no outbox exception. Execute its causal RED before correction.

The complete16-owner repair1 gate then failed at the retained Document-state
group's default60-second budget. Its22 independent authenticated mutations,
fixture creation and cleanup shared one ExUnit case. Actual private checkpoint
records show DROP started only about0.5 seconds before forced cancellation;
the checkpoint itself lasted0.954 seconds, not a60-second DROP wait. A temporary
content-free monotonic probe preserved all18 cases and22 mutation assertions:
isolated execution ended normally0,30.9 seconds, with fixture5,757 ms,
all22 mutations complete at27,183 ms and cleanup complete at28,842 ms.
This isolates the repeated body from cleanup; it does not qualify the failed
complete gate or prove the historical PID cascade. Remove the probe and split
only these22 independent mutations into separately named, freshly authenticated
cases, preserving every original input/assertion/helper and default60-second
timeout. The original18 semantic groups become39 executable cases; no required
case is excluded. Freeze a new repair2 receipt and rerun the entire39-case
Preflight owner and complete16-owner gate (334 actual SQL/337 reported/3 pure
excluded), then separate pure5/downstream186/static/frozen and actual final
NONAUTHOR SPEC followed by fresh QUALITY. Repair1 failures remain historical
FAIL evidence; neither a timeout increase nor a smaller final gate is allowed.

## Task 8: Explicit V3 writer with complete retained-original closure

Scoped local acceptance: tested source `21d066036edbcb3f0a0737ae2dca36a9cea79427`,
SQL78/0, pure50/0, static/frozen checks and actual full SOURCE SPEC followed by
distinct fresh QUALITY PASS. Exact commands, historical failures, receipts and
local commit handoff are in the Phase5 verification report. Default remains V2;
Task9/11/12 and whole-phase acceptance are not implied by these checked items.

**Modify:** Storage `backup/exporter.ex`, complete `backup/logical_exporter_test.exs`.
**Necessary composition compatibility:**
`apps/singularity_runtime/lib/singularity/runtime/application.ex` only its
WorkerRepo alias/object_storage context, and the corresponding exact
`apps/singularity_runtime/test/singularity/runtime/application_test.exs` assertion.
**Create:** `apps/singularity_storage/priv/repo/migrations/20261011000500_knowledge_backup_read_grants.exs`,
`apps/singularity_storage/priv/repo/migrations/20261011000600_knowledge_backup_v3_guard.exs`,
`apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs`.
**Depends on:** Tasks 3 and 7; default remains V2 until Task 12.

- [x] Add RED explicit `Exporter.snapshot_cut(repo, owner, 3)` and
  `Exporter.records(repo, cut, 3)` tests under the existing scoped WorkerRepo
  repeatable-read transaction. Default two-arity calls and explicit version 2
  still reject V3-only rows. All new version 1 writer requests and unknown
  writer versions unconditionally return `backup_unsupported`, including graphs
  with no V3-only rows. Do not add a version-selected guard exception before
  the complete explicit reader/import and this closure are present.
- [x] Implement explicit version selection without changing default adapter
  signatures or Runtime.BackupVault. New `Exporter.snapshot_cut/3` and
  `Exporter.records/3` accept writer versions 2/3 only. V1 omits resource kind,
  current head, Note versions and conflicts, so it cannot safely write a current
  Note-only graph. Deny version 1/unknown before queries or streams; preserve
  V1 codec/golden/decoder/restore behavior unchanged. Choose supported schemas
  explicitly, encode every logical record with that version and prove the same snapshot for counts,
  streamed rows, evidence, raw objects and acknowledgement. Keep `cut` shape
  compatible with the frozen runtime adapter; version is the internal overload
  parameter, never inferred from table count. Default is 2 in this task.

```elixir
def snapshot_cut(_repo, _owner, version) when version not in [2, 3],
  do: {:error, Error.new(:backup_unsupported)}
def records(_repo, _cut, version) when version not in [2, 3],
  do: {:error, Error.new(:backup_unsupported)}
```

- [x] Independently assert unconditional V1 writer denial for live Note-only,
  historical Note-only, conflicted Note-only and tombstoned Note-only graphs.
  Build these with existing `NoteFixtures.note!`, `insert_note_version!` and
  `note_with_conflict!` seams; tombstone with the established
  `Fixtures.with_owner` fixture transaction updating that Note's
  `content.resources.deleted_at`. Assert all eight V3-added tables have zero rows for each tested
  owner, then assert both cut and records requests deny version 1 even though
  explicit V2 export preserves the Note history. Also prove denial happens
  before any repository/object adapter call:

```elixir
assert {:error, %Error{code: :backup_unsupported}} =
         Exporter.snapshot_cut(:must_not_be_called, owner, 1)
assert {:error, %Error{code: :backup_unsupported}} =
         Exporter.records(:must_not_be_called, cut, 1)
```

- [x] Add only required SELECT/read-function grants for the existing worker,
  preserving current owner RLS and hardened identity/conflict export seams.
  Runtime web/pre-auth/dispatcher get no backup/grant/admission authority.
  Completed import receipts are canonical; pending receipts reject. Knowledge
  mutation receipts, search, source-set seals, sessions, Oban and staging do not
  enter payloads. Outbox/job provenance and V2 column order remain intact.
- [x] Compute inventory from the exact union:

```sql
SELECT asset_object_id FROM content.assets
WHERE vault_id=$1 AND state NOT IN ('deleted','pending_delete')
  AND asset_object_id IS NOT NULL
UNION
SELECT source_object_id FROM content.document_versions WHERE vault_id=$1
```

  Retain the existing live-Asset required-object predicates in the first branch;
  the second includes all states, heads and tombstones. Join retained available
  object/envelope evidence by exact owner/object, deduplicate/sort object ID.
  Missing required retained object is corruption. Do not demand a current Asset
  object pointer or unreleased association for Document history; absent allowed
  physically deleted Asset-only bytes are not invented. No foreign/extra objects.
- [x] After the complete Task 7 import and this retained-object closure exist,
  forward-create `content.backup_has_unsupported_canonical_rows(uuid,integer)`
  in `20261011000600_knowledge_backup_v3_guard.exs`. Preserve the existing
  one-argument function and its legacy denial behavior unchanged. The overload
  requires the same current owner/`backup.create` authorization; version 1 and
  unknown versions are always unsupported, version 2 retains the existing
  legacy unsupported-content behavior, and explicit
  version 3 admits only supported complete canonical graphs. Validate known
  resource kinds, Document state/attempt shapes, supported storage/extractor
  formats, exact historical source identity and retained-object closure,
  ready fragment/citation/source-set completeness, completed receipt agreement
  and owner/classification bindings. Unknown/incomplete content stays fail-closed;
  no unconditional false or production write/grant activation is permitted.
- [x] Route only explicit internal/test `Exporter.snapshot_cut(repo, owner, 3)`
  and `Exporter.records(repo, cut, 3)` selections through the new overload. Default two-arity
  adapters stay version 2 and use the unchanged original legacy guard. Add
  negative tests for unauthorized/foreign owner, unknown version/kind/format,
  malformed attempt/source shape, missing retained object, incomplete fragments/
  source sets/receipts and ciphertext/object-evidence disagreement, plus explicit
  version 1/2 rejection of live and tombstoned V3-only rows. Version 1 denial is
  unconditional and also covers Note-only history without V3 rows; version 2
  remains governed by its unchanged legacy content guard. This guard exists
  before Task 11 live qualification; Task 12 changes only qualified defaults.
- [x] Test historical pins after source Asset cleanup, shared objects, tombstoned
  Documents, all states, old heads, unknown kind/format, missing object/shape,
  foreign owner and a head/tag mutation barrier after capture. Instrument lazy
  pages/chunks; consuming rows/objects after scoped transaction closure fails.
- [x] Run explicit V3 exporter and full legacy exporter/identity/privacy owners:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/task14_backup_identity_export_security_test.exs --seed 215378 --warnings-as-errors
```

  Expected GREEN preserves default legacy rejection; SPEC then QUALITY, commit
  `feat(backup): stream complete v3 history and retained originals explicitly`.

### Task8 source-review storage-reference compatibility

Actual full SOURCE SPEC found the path-only guard rejects normal available
Asset objects whose stored reference remains their UUID after publication.
Preserve both exact supported forms: storage_ref equals object.id::text, or
equals the canonical owner/domain/HMAC lookup path. Never normalize or rewrite
stored/wire references; reject another object's UUID and foreign/malformed paths.
Add six in-file cases: two UUID/mixed-reference positives with full history,
inventory/evidence/immutable-pin oracles, and wrong UUID/owner/domain/lookup
negatives. Preserve all45 original V3 cases,21 legacy and6 privacy cases.
These owner-SQL fixtures are persisted-shape guard regressions, not actual upload
or authenticated-byte proof; Task11 must exercise that complete live composition.
Review this amendment, run all78 SQL cases to genuine RED, then correct only
unaccepted00600's reference predicate. Repeat all78, pure50, static/frozen and
actual SOURCE SPEC followed by separate fresh QUALITY before local acceptance.
Accepted preflight/admission and frozen-lease representation differences require
their own reviewed additive Task9 compatibility design; no old migration edit,
frozen lease change or restore-qualification claim belongs to this correction.

### Task8 selected owner-history, JSON and transaction-binding seams

Source preparation established three necessary details before source GO.
Independent bounded draft SPEC PASS is preparation, not implementation proof.
Apply this amendment, complete actual applied SPEC then fresh QUALITY, and
run test-only RED before production implementation. Parent alone runs formatter,
Mix, SQL/services and Git; disjoint test/production authors never run commands
or change each other's files. No frozen migration, helper, V1/V2 or custody edit.

- [x] Forward00500 grants worker SELECT only on document_versions/fragments,
  note_attachments/citations, tags/resource_tags/relationships. Preserve receipt
  RLS and existing direct grants; add worker-only EXECUTE of fixed eight-column
  `content.export_document_import_receipts_for_backup(uuid)` instead. It checks
  live exact owner, principal_kind owner, unrevoked principal/membership and
  backup.create, with STABLE SECURITY DEFINER/table-owner/pinned search_path/
  fixed qualified columns. PUBLIC/web/pre_auth/dispatcher cannot execute it.
  Return owner receipts without a completed-only filter; guard rejects pending.
  Prove two principals' same-owner receipts both exported, foreign/no-cap/
  revoked/system-principal denied, while original principal-specific RLS remains.
  A disposable test-only SELECT grant may probe actual policy filtering but
  must not replace production ACL assertions or change the policy definition.
- [x] Preserve the original one-argument guard body/ACL/owner/config. The new
  overload authenticates exact live owner before branching;1/unknown remain
  unsupported,2 delegates unchanged legacy,3 validates supported complete live
  history. Do not call audit.assert_knowledge_restore_graph or grant its private
  helpers to worker: restore-only dummy credentials/locked owner/restored wrapper
  assumptions are invalid live-backup rules. Keep advanced wrapper2/key1 valid
  and unsupported Document state representable. Test incomplete source/pin/
  attempt/fragment/citation/seal/receipt/format/object closure fails closed.
- [x] Use fixed explicit V3 JSON text projections in ordinary table queries and
  the identity helper's24-column projection (metadata positions2/8/21). Decode
  binary JSON text before tagging; distinguish nullable SQLNULL from JSONnull.
  Do not mutate frozen identity function or defaultV2 projections. Independent
  oracle compares literal all38 columns/counts/PKs, versioned codec and preserved
  wire outbox sequence/id, including native SQL JSONnull and nullable SQLNULL.
- [x] Bind lazy logical records and repository-aware raw entries/payloads to
  their construction caller/repo/backend/full-xid/RR/current owner/principal.
  Reject wrong caller and inactive repo before SQL; recheck full binding before
  header/each logical record, raw entry, open and every raw chunk. Same snapshot
  text is not full transaction identity. No process dictionary/cache/registry/
  cut authority fields. The historical cut remains plain data; actual frozen
  saga constructs/consumes/acknowledges inside its one owned transaction.
- [x] Implement the narrow composition without frozen BackupVault edits:

```elixir
def stream_inventory(%{repo: repo, storage: storage}, capture_cut),
  do: stream_inventory(repo, storage, capture_cut)

# Runtime.Application job_dependencies only; trusted WorkerRepo composition.
object_storage: {Exporter, %{repo: WorkerRepo, storage: storage}}
```

  New repository-aware `/3` validates the existing five-key capture cut and
  binds raw framing independently of logical wire version. Existing bare-storage
  `/2` behavior remains for compatibility; logical `/3` keeps six-key cut with
  manifest_id. Test closure, same-backend/new-full-xid, other PID/repo/scope and
  mid-raw-chunk closure deny before further storage calls; success V2 and runtime
  composition stay intact. Recompute explicitV3 required object inventory inside
  its scoped snapshot, preserve fabricated-cut legacyV2 contracts.
- [x] Synchronize only both legacy owner worker-SELECT assertions to the precise
  seven-table grant/receipt exception; retain original legacy guard denial,
  other-role/mutation/private identity/body/error assertions, all13 named tests
  and all eight generated guard cases (21 actual legacy cases).
  Run complete required Storage owners plus narrow composition/custody-free
  frozen-saga pure regressions:

```sh
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_exporter_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/task14_backup_identity_export_security_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
```

  Final gates use complete files/default timeout, no narrowed acceptance.
  Verify frozen56 plus accepted Task7 receipt, actual formal SOURCE SPEC then
  fresh QUALITY, and local commit. DefaultV3/complete live saga/portable export
  remain later tasks; E2E NOT RUN.

## Task 9: Verify original plaintext evidence before rebuild/completion

**Modify:** Storage `backup/knowledge_integrity_inventory.ex`, Runtime
`integrity_audit.ex` and their complete owning tests; retain complete Base
integrity/rewrap tests and unchanged Base `backup/integrity_audit.ex`.
**Create:** `apps/singularity_storage/lib/singularity/storage/backup/knowledge_integrity_audit.ex`,
`apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs`.
**Depends on:** Tasks 7 and 8.

Necessary original-reference compatibility is governed by the separately
SOURCE SPEC/fresh QUALITY-reviewed
[compatibility design](../specs/2026-10-12-singularity-v0.2-phase-5-storage-reference-compatibility-design.md)
and [detailed plan](2026-10-12-singularity-v0.2-phase-5-storage-reference-compatibility.md).
They add the internal Storage KnowledgeIntegrityInventory adapter, additive
00700 admission-predicate replacement, narrowly corresponding accepted
preflight/Restorer composition and their complete owning tests. Original I stays
unchanged; only explicit authenticated V3 derives the UUID lease view N(I).
Preserve accepted00300, frozen lease/digest/reader and all legacy assertions;
no default V3 before Task11 real normal-publication/lease qualification.
Follow detailed Tasks B–F after preceding Task8 acceptance; the checks below
remain required, not replaced by architecture approval.

The complete retained gate also requires synchronization of two old security
test contracts with Task8's already accepted seven-table worker SELECT grants,
under `docs/superpowers/specs/2026-10-12-singularity-v0.2-phase-5-backup-reader-grant-contract-design.md`
and matching plan. Actual independent SOURCE SPEC and distinct fresh QUALITY
PASS on complete design d19067aa/plan d68e4320. Keep all two Rls/thirteen Grants
cases, exact literal privileges/nongrantable ACLs, native DML/private-function/
receipt/seal/other-role denials and stronger real baseline owner-filter reads.
No production grant/policy/helper changes. Current Rls e24dcace/Grants efd5c7c8
passed focused15 and complete retained16; actual final nonauthor SOURCE SPEC
then distinct fresh QUALITY passed. Historical50680 FAIL remains recorded.
No focused repair PASS alone substitutes for complete retained16 qualification.

The owning Admission wrong-reference negative preserves its single case, all
ten variants/default60 and complete native body under the bounded test-only
`docs/superpowers/specs/2026-10-12-singularity-v0.2-phase-5-admission-fixture-lifecycle-design.md`
and matching plan. Actual nonauthor SOURCE SPEC then distinct fresh QUALITY
PASS on historical candidate28674f51/c798847e and native-close amendment
6a5607ac/dc697ab0. Prepare original independently
authenticated sources before one empty migrated rollback-only destination;
each variant retains its own actual native transaction/graph rejection and
complete before/after no-import/storage/replay checks. Ordinary other cases
still allocate separate destinations; protected helpers/production untouched.
Require exactly one same-process genuine successful native close with real
open-before/closed-after controls; discard only an unconsumed replay. Preserve
the original callback result/raised kind-reason-stack and unconditional stage
cleanup, including authentication/close failure. Duplicate/failed/foreign/
unqualified observations deny.
Initial full344actual/93FAIL/3excluded gate remains FAIL; interrupted private
resources were recovered and one captured chunk is declared incomplete.
Current Admission43b4c144 passed complete owning70 and full16 with normal
cleanup/static/frozen checks; final actual nonauthor SOURCE SPEC then distinct
fresh QUALITY both passed. Full16 executed344actual/0 with3 non-SQL exclusions,
covered separately by whole legacy pure5/0. Task9C test-first authoring may
proceed; compatibility TasksC–G and Phase5 remain unaccepted. Admission contains
pending Task9B cases, so commit its qualified repair with the combined TaskF
handoff rather than committing tests without required00700 implementation.

- [x] Close parent full reads and actual nonauthor DESIGN SPEC then distinct
  fresh QUALITY for the Task9E amendment before any E test/source authoring.
  Execute detailed E's baseline, test-only causal RED, implementation, whole
  owner GREEN and all retained F gates; preserve original C/D exact-gate history
  and cumulative repair counters. Every new native witness remains NOT RUN.
- [x] Add RED verifying every Document immutable `source_digest/byte_size`
  against the full inventory/material and authenticated plaintext hashes,
  including objects retained only by deleted/old Documents. A matching
  ciphertext hash with a wrong original plaintext digest must fail.
- [x] Define Storage `KnowledgeIntegrityInventory.verify_document_sources(repo,
  binding, original_inventory, plaintext_hashes)` where binding is EXACTLY the
  two owner/manifest keys. Validate
  restored saga and equal inventory identity; hashes contain exactly one
  `%{asset_object_id: id, sha256: <<32 bytes>>}` per inventory entry in canonical
  order. Reject missing/duplicate/extra evidence, foreign owner/manifest, wrong
  size/hash and unverified materials. No fabricated full C.Context or independent
  expected manifest-hash/tag/root authority absent from `/4` inputs. Hash and
  compare ORIGINAL I without normalizing refs; exact nine-field I/N(I) stay
  unchanged. Asset-only entries remain valid. Recheck
  all ready historical extracted concatenation digests, independent of heads.
- [x] Implement the strictly increasing frozen format1 size law using public
  Format constants: `C(P)=66+P+24*ceil(P/4194304)+68`. Match immutable Doc size
  against ORIGINAL inventory ciphertext size, plus current Object size/format.
  Current metadata equality alone is insufficient. Execute all nine independent
  literal vectors in the compatibility design, adjacent/gap/malformed/overflow
  negatives and real encrypted empty/chunk-edge authenticated-reader cases.
- [x] Use public KnowledgeBackupFixtures APIs and actual LocalDestination,
  BundleReader, LogicalBundleVerifier and Restorer.import into a different empty
  disposable destination. Prove actual committed import/saga before E negatives.
  Transform all sharing Doc digests coherently for the native plaintext mismatch;
  transform all sharing Doc/Object sizes coherently, correct Object size for a
  real reader then restore wrong matching Object size for the causal size-law
  denial. Qualify all states/retained historical/deleted originals, Asset-only
  entries, UUID/canonical/mixed refs and malformed hash/binding/ref negatives.
- [x] Execute ONLY the detailed E single-fragment-guard exception for historical
  extracted mismatch. Require successful helper baseline, actual original
  trigger/function/enabled-state/RLS snapshots, zero referencing FKs, canonical
  replacement tuple, separate native corruption COMMIT with guard re-enabled,
  all other guards/RLS retained, exact restoration and ordinary forbidden UPDATE
  proof, then E denial in its own transaction. Injection failure rolls back DDL
  and data. Do not substitute preflight/guard/nested-transaction denial or weaken
  the required aggregate mismatch; preserve imported saga/no completion.
- [x] Add a narrow call in Runtime `verify_final` after
  `validate_plaintext_summary/3` and before `rebuild_lexical/2`:

```elixir
:ok <- adapter_ok(call(adapters.search_rebuilder, :verify_document_sources,
  [search_binding(target), target.original_inventory, plaintext.plaintext_hashes]))
```

  For authenticated V3, compose `{KnowledgeIntegrityAudit, MigrationRepo}`:
  the three arguments reach its four-arity Document delegate with repo prepended.
  The facade delegates E verification to KnowledgeIntegrityInventory and initially
  delegates rebuild unchanged to Base. Do not add a reverse Base->C dependency.
  Require Document callback only for V3; retain version only from authenticated
  Imported/Rewrapped cut and preserve explicit V1/V2 and existing no-version
  legacy-map requirements. Explicit unknown version denies; no caller version
  option/inference/new handoff field. Preserve module `/3` and tuple `/4`
  dispatch. Update the full LexicalRebuilder recording fake and preserve its
  rebuild assertions. Do not put plaintext hashes into the search summary
  or logs. Keep `PlaintextSummary`, RestoreIntegrityLease, rewrap/key handoff,
  ciphertext/Note/Asset verification, crypto and completion authority unchanged.
  Fakes gain an exact recording callback and prove order/denial, not live custody.
  Test absence, malformed/error result, exact original-I/two-key arguments,
  summary validation before helper, denial before rebuild/audit and revocation.
- [x] Run full existing Runtime integrity tests and new Storage integration:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/integrity_audit_test.exs apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/integrity_audit_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_integrity_test.exs --seed 215378 --warnings-as-errors
```

  Assert denial prevents rebuild/completion and maintenance destination stays
  unpublished. No claim of rollback of an already committed import/rewrap.
  These master commands are retained minimum owners; the detailed E commands
  additionally require whole C pure/SQL and rewrap owners, and every retained F
  command remains required. Report actual counts/exclusions/native cleanup.
- [x] Obtain SPEC then fresh QUALITY on the precise compatibility addition,
  report frozen-substrate files unchanged, commit
  `feat(restore): verify retained document originals from authenticated evidence`.

Current Task9 B–F source handoff, 2026-10-13: all native owning/retained gates,
actual combined NONAUTHOR SOURCE SPEC and distinct fresh SOURCE QUALITY have
closed PASS/noP1P2, exact source14 and all79 protected entries unchanged at
HEAD `9f91c97eb392b4c49c888ed31795d520d15bb8dd`. Corrected E executes88 pure
and45 SQL; F executes344 SQL,5 legacy pure,203 downstream pure and separate
Task8 SQL78/pure50. Exclusions, historical failures, exact commands, full
archives and normal cleanup are in
`docs/verification/2026-10-13-phase-5-task9-compatibility-handoff.md`.
The combined compatibility plan selects the bounded commit message
`fix(restore): preserve v3 storage references across integrity verification`;
it includes the E source verification and replaces the older separate message.
The exact26-path local Git handoff closed at
`5619eccdbc2256c4c5aa702b653038fa57ada6fe`, with empty postcommit index.
No Task10/11 or Phase5 acceptance.

## Task 10: Rebuild unified search and reconcile interrupted extraction/work

**Modify:** Storage `backup/knowledge_integrity_audit.ex`, `backup/reconciler.ex`,
`unified_search_restore_test.exs`, `restore_reconciliation_test.exs`.
**Create:** `apps/singularity_storage/test/singularity/storage/backup/document_restore_reconciliation_test.exs`.
**Create:** forward migration
`apps/singularity_storage/priv/repo/migrations/20261011000800_document_restore_recovery_provenance.exs`.
**Retain:** Runtime recovery behavioral contracts and complete restart file;
only the stale SELECT permission case receives the necessary amendment below.
**Depends on:** Task 9.

Current Task10 source/gates and both final whole28 actual reviews are qualified
on `d1a8d4f73c570daa7177468b246a25819a2cdd39`; see the linked Task10 handoff.
Task11 source starts only after its reviewed documentation commit/clean handoff.

### Historical Task10 preparation and review records

Detailed Task10 reviewed design/plan:
`docs/superpowers/specs/2026-10-13-singularity-v0.2-phase-5-unified-restore-design.md`
and `docs/superpowers/plans/2026-10-13-singularity-v0.2-phase-5-unified-restore.md`.
Round 3 actual independent DESIGN SPEC then NEW distinct fresh QUALITY are
CLOSED PASS, no P1/P2; prior findings/outcomes remain in the detailed documents.
Prerequisite A.1 is locally committed at `47fabf1e3fcd4b1b149444c0c7d9bb4673b5ba81`
after whole Runtime2 GREEN (10 actual PASS, 0 failures, 185.8s, exit0) and actual
SOURCE SPEC then NEW distinct fresh QUALITY CLOSED PASS. Parent GO covers
D/E/F after complete B/C TaskH naturally CLOSED valid causal RED: 148 tests,
81 feature failures, 731.6s on exact archived source, normal cleanup EMPTY and
original frozen56 verified unchanged. B/C preparation Sol2/Astra1 resolved
fixture defects; GREEN/downstream gates and actual source reviews remain
required. Historical baseline
and initial A.1 FAILs remain FAIL; this prerequisite is not Task10 feature RED.
Supplementary disposable receiver authentication preparation has actual round2
independent DESIGN SPEC then NEW distinct fresh QUALITY CLOSED PASS, no P1/P2,
in detailed section7.1. It preserves FIRST
full wire-cut equality, actual fresh public login, locked-retry denial and exact
test-only credential/locked-bit deltas without unlock/rewrap/custody/Vault changes;
parent GO covers only that reviewed fixture preparation, no additional production
scope or current test/native qualification.
Round1 actual supplementary SPEC CLOSEDFAIL on one source identity-binding P2.
Corrected source fixture binds account/principal/owner IDs before seed/export
to unchanged PreAuth, with real native audit/session effects retained; both actual
round2 reviews CLOSED PASS. No receiver identity rewrite. Historical reviewed
hashes/actual receipts are retained in detailed section7.1; later parent status
bookkeeping is not retroactive review. Whole three-file TaskH RED is now CLOSED;
the full GREEN gate remains required. E2E NOT RUN/defaultV2/Task16 unwaived
remain unchanged.

### Qualified Task10 implementation checklist

- [x] First repair only the recovery permission test's obsolete total-SELECT
  denial for Document versions/fragments. The unchanged00500 migration grants
  both reads. Preserve all function metadata/EXECUTE/write-denial assertions,
  all9 other recovery cases, and every restart byte. Add actual same/foreign
  owner ready-Document/fragment RLS reads, absent/mismatched/revoked scope denial,
  independent42501 INSERT/UPDATE/DELETE/TRUNCATE with rollback/preserved rows,
  same-backend GUC cleanup. Original frozen56/protected3 receipts remain history;
  record the exact selective case delta and new explicit reviewed receipt.
  No production grant/policy change or bare assertion inversion is permitted.
  Original Runtime2 baseline10 actual9PASS1FAIL remains historical FAIL;
  corrected whole Runtime2 now10PASS/0, with both actual source reviews PASS.
- [x] Apply only the reviewed three-function/one-constraint knowledge delta in
  new00800: existing bounded scanner, expired-recovery mutator and authenticated
  runtime retry; exact owner/creator/event/raw provenance/current epochs and
  current head, eligibility before LIMIT, authoritative lock revalidation and
  atomic one-successor/collision rollback. New Document-only authorization-invalid
  retirement reason prevents automatic revival after same-epoch reauthorization.
  Authenticated ordinary retry covers both authorization-invalid pending work
  and expired extracting attempts through existing legal generation transitions.
  Preserve existing valid pending/pre-dispatch idempotence; no invented submission,
  identity, session, helper, grant or lifecycle-guard change. Native present-valid
  unretired attempt may lack its old submission; any present submission must
  match. Imported V3/reflected attempts still require matching submission;
  only true UUID-alone event absence permits native eventless compatibility.

- [x] Add RED stable search comparison for restored live ready Document heads
  and Notes, old/deleted/non-ready suppression and retained historical citation
  fragments. Seed stale derived rows; rebuild twice and compare exact stable
  kind/resource/version/fragment tuples, locators/text/IDs and summary digest.
- [x] Replace only the V3 facade's initial unchanged Base rebuild delegate with
  unified knowledge rebuilding; keep Base and native V1/V2 semantics unchanged.
  Implement `KnowledgeIntegrityAudit` rebuilding to enumerate owner resource IDs in
  stable order, clear stale projections and call
  `content.reconcile_search_resource_internal(owner, resource_id)` for current
  Note/Document heads, preserving established Asset metadata rebuilding.
  Canonical rows must not change and no search payload is imported.
- [x] Extend `Reconciler.event_job_type/1` and validation for exactly
  `document.extraction_requested`→`document_extract`, and
  `document.ready/deleted/restored`→`document_projection`, using current Phase 2
  envelope allowlists/provenance/owner/epoch rules. Retired/terminal work is
  cleared appropriately; unknown events/extra payload keys remain errors.
  Ready/failed/unsupported retire redundant extraction work; stale generation/
  head/destructive events retire; current live pending retains one valid
  extraction request/wake. Deleted pending work remains undispatched.
- [x] Restore an extracting snapshot with its exact generation/job/start/deadline
  and no fragments; do not create a running process or alter deadline/state.
  After canonical-cut equality is asserted, drive the existing guarded periodic
  recovery with a deterministic clock/barrier past its deadline. Expect the
  existing invalidation/new-generation behavior, not a newly invented job or
  custody bypass. Invalid historical authorization retires work and requires
  ordinary authenticated retry. Reconcile/rebuild retry is idempotent.
- [x] Keep dispatch stopped until validation, complete rebuild and completion
  pass. Preserve Task 8's V1 writer-denial tests and the explicit V2 unsupported
  tests in `unified_search_restore_test.exs`; do not erase them when default changes.
- [x] Run complete Storage owners plus unchanged Runtime recovery files:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs apps/singularity_storage/test/singularity/storage/restore_reconciliation_test.exs apps/singularity_storage/test/singularity/storage/backup/document_restore_reconciliation_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/document_extraction_reconciler_test.exs apps/singularity_runtime/test/singularity/runtime/document_extraction_runtime_restart_test.exs --seed 215378 --warnings-as-errors
```

  The focused commands above retain their original historical qualification
  routes. Late compatibility amendments have separate focused evidence; every
  owner then executed in the final ordinary NO-ARGS full-cohort qualification
  on exact current28. Do not claim a later focused seed/warnings invocation.
  Final actual whole28 SPEC then NEW fresh QUALITY CLOSED PASS; five local
  source commits end at `d1a8d4f73c570daa7177468b246a25819a2cdd39`
  (`feat(restore): reconstruct unified search and document work`). Documentation
  review/commit and clean handoff still govern Task11 source GO.

## Task 11: Qualify complete V3 saga, malformed rejection and legacy restoration

**Create:** `apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs`,
`apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs`,
`apps/singularity_runtime/test/mix/tasks/singularity.test.restore_test.exs`
  (focused oracle export/dynamic-entry/cleanup ordering only, not native proof).
**Modify:** `apps/singularity_runtime/lib/mix/tasks/singularity.test.restore.ex`
  only knowledge fixture/oracle stages; preserve existing crypto/operator tests.
**Retain owners:** Runtime backup/restore files and all legacy restore fixtures.
**Depends on:** Tasks 7–10, including Task 8's explicit version-aware guard.

Task9E local authenticated-reader/helper/import qualification is not this task's
native RestoreIntegrityLease, actual wrapper-chain or normal-publication proof.
Actual Task11 native lease/normal-publication witnesses are recorded in the
[final-source handoff](../../verification/2026-10-18-phase-5-task11-handoff.md);
they are not inferred from Task9E. Source/gate reviews and six local commits
are complete; documentation-review/commit/clean closure remains separate.
V3 uses `{KnowledgeIntegrityAudit, MigrationRepo}` with Task10's unified rebuild;
legacy native Base compositions and every old oracle assertion remain intact.

- [x] Add RED live composition through established backup, authenticated bundle,
  Restorer, existing rewrap/integrity lease and completion in disposable databases.
  The explicit writer version 3 is the test adapter; production default stays 2.
  Compare every canonical row at the cut before recovery, all IDs/source sets/
  locators/digests/receipts/conflicts/tombstones and original binary bytes; then
  compare public search after lawful recovery. Test empty clean destination and
  supported disposable replacement staging while active source data is unchanged.
- [x] Include normal Asset finalization with actual UUID persisted reference,
  plus retained canonical-path and mixed inventories, exact original I/N(I) and
  actual typed native PlaintextSummary through the unchanged frozen lease.
  Qualify the E size-mutation barrier with the actual native lease when E used
  only a local reader; fixture-known hashes/recording issuer/material ports
  cannot prove the lease used P. Preserve helper -> unified rebuild -> completion
  order and wrong-size/digest denial after successful genuine import/read.
- [x] Add independent malformed cases for duplicate PK/unique keys, extra/missing
  rows/objects, mixed versions, classification/owner/kind/head/ancestry/conflict
  errors, ordinal gaps, locator/fragment/digest tampering, unsupported format,
  receipt disagreement, ambiguous source association, foreign object and
  truncated/changed ciphertext/plaintext source mismatch.
- [x] Add deterministic fault barriers at authentication/preflight, canonical
  insert, staged publish, commit uncertainty, rewrap, ciphertext verification,
  durable-work reconciliation, authenticated plaintext/Document verification,
  unified search rebuild and integrity/restore completion in the existing saga
  order. Assert rollback and owned cleanup for pre/import failures and an
  unpublished maintenance graph after import failures, preserving every exact
  error/retryable, custody-cleanup, dispatch/isolation and invisibility assertion.
  Every supported native in-place retry must actually succeed on the identical
  authenticated manifest and destination without duplicate rows, objects, source
  seals or jobs. Qualify Storage pending/imported replay separately from complete
  Runtime continuation. Characterize the existing no-durable-continuation boundary
  after committed rewrap plus lost/consumed integrity custody; do not reclassify
  transient failures or bypass custody to satisfy qualification. Separately prove
  successful clean restore and supported disposable replacement staging while
  active installation/data remain unchanged. Fresh disposable-target success is
  RESTART, never successful RESUME. Retain every required barrier/assertion and
  never claim distributed transaction rollback or authorize a frozen protocol
  change.
- [x] Extend the independent restore oracle with known synthetic binary originals,
  all-state history/organization/source pins and negative corruption; reuse
  established real crypto and custody. Retain V1 golden `.backup` bytes, explicit
  V2 fixtures and every old assertion. No new Vault lifecycle behavior/test.
- [x] Run full focused saga/legacy owners, then the sole independent restore task:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_failure_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/backup_vault_test.exs apps/singularity_runtime/test/singularity/runtime/restore_vault_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.restore
```

  Expected GREEN is actual live qualified explicit V3 plus V1/V2 restoration, not fake-only
  wire success. Record exact outputs/cleanup, SPEC then QUALITY; commit
  `test(restore): qualify complete v3 saga and malformed rejection`.

## Task 12: Switch default to V3 only after writer and restore qualify together

**Modify:** Storage codec/exporter default selection and their complete tests;
  existing legacy guard tests; active backup operator guidance.
**Depends on:** Tasks 8–11 GREEN and independent SPEC/QUALITY for the combined boundary.

Execution follows the [Task12 design](../specs/2026-10-18-singularity-v0.2-phase-5-task12-default-v3-design.md)
and [detailed plan](2026-10-18-singularity-v0.2-phase-5-task12-default-v3.md).
Default writer/restore, architecture/static and actual combined SOURCE SPEC/
NEW QUALITY passed; all four source commits and exact blobs are verified.
Final documentation-contract verification, independent documentation reviews,
docs-only commit and literal clean closure remain pending at this snapshot.

- [x] Add RED default-backup test asserting logical 3 with and without Document
  content, full 38-table vector and qualified restore. Retain the Task 1 V2
  default characterization as historical evidence; amend the current-default
  test only now and add explicit legacy-version writer rejection cases. The
  version 1 Document-negative case below remains unconditional writer denial;
  version 2 rejects because the graph contains unsupported V3-only rows. Retain
  every Task 8 Note-only V1 denial after switching the default.

```elixir
assert LogicalRecordCodec.default_version() == 3
assert LogicalRecordCodec.tables() == LogicalSchemaV3.tables()
for version <- [1, 2] do
  assert {:error, %Error{code: :backup_unsupported}} =
           Exporter.snapshot_cut(repo, owner_with_document, version)
end
```

- [x] Reuse the complete Task 8 version-aware guard after its explicit V3 writer
  and Tasks 9–11 integrity/live-restore qualification pass. Retain the original
  one-argument legacy V2 content guard, unconditional new-V1-writer denial and
  all unknown/incomplete V3 negatives; V1 codec/golden/decoder/restore stay intact.
  This task creates no duplicate or no-op guard migration. Default selection
  switches only now; production canonical writes/grants remain closed.
- [x] Change codec/default writer selector and typespec to 3 together; production
  BackupVault still calls the same Storage adapter interface and receives the
  same outer cut/bundle/crypto structures. Add all default new-write round trips.
  Update tests asserting absent worker SELECT only for the precise new approved
  read grants, retaining denial of other roles and all mutation/custody grants.
- [x] Run full codec/verifier/exporter/unified legacy files and live saga/oracle
  again because default selection changed. Add unknown/incomplete V3 negatives
  as well as explicit legacy unsupported positives/negatives. Record guard
  behavior before/after and frozen source hashes.
- [x] SPEC then QUALITY, commit `feat(backup): select qualified logical v3 for new backups`.
  This changes backup output only; production canonical write guards remain closed.

## Task 13: Authenticated snapshot, promoted source closure and bounded text spool

**Create:** `apps/singularity_storage/lib/singularity/storage/knowledge_export/repository.ex`,
`apps/singularity_storage/test/singularity/storage/knowledge_export/repository_test.exs`,
`apps/singularity_storage/lib/singularity/storage/knowledge_export/spool.ex`,
`apps/singularity_storage/test/singularity/storage/knowledge_export/spool_test.exs`,
`apps/singularity_runtime/lib/singularity/runtime/knowledge/export_snapshot.ex`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs`,
`apps/singularity_runtime/test/support/knowledge_export_snapshot_fixture.ex`.
**Depends on:** Tasks 2 and 6; can precede Task 12 once file ownership is disjoint.
No existing OperationScope, Authorize, ScopedRepo, resolver, custody, Core
renderer, application/configuration or policy modification in this task.
Task16 owns production composition and the dedicated-root configuration.

The plain new test/support fixture is compiled before umbrella suites run.
Mix executes Storage before Runtime, so a Storage test cannot depend on a fixture
defined only in Runtime's selected case file. Extract the unchanged live fixture
and observation/barrier adapter into this module; add no cases, startup side
effects, fabricated authority or existing-helper/configuration changes. All
existing assertions and genuine Runtime/SQL authorization contracts remain.
This necessary test-layout amendment does not expand the product contract.

The bounded denied-authorization/audit SQL test-contract correction is governed
by `docs/superpowers/specs/2026-10-12-singularity-v0.2-phase-5-snapshot-denial-audit-contract-design.md`
and its matching plan. Actual independent SOURCE/SPEC and distinct fresh
QUALITY passed before test-only GO. For forged principal/owner and revoked
membership, keep exact genuine live Authorize denial separate from the existing
OperationScope real42501 audit failure/retryable storage_unavailable return.
Do not weaken the denial predicate, fake audit success, alter production policy
or treat failed/missing-Repository runs as Task13 acceptance. All other nine
denial cases/allowlists, selections, default timeouts and cleanup checks remain.

The NEW shared fixture's inherited schema-only knowledge-test storage reference
is corrected only in its existing owner setup, under
`docs/superpowers/specs/2026-10-12-singularity-v0.2-phase-5-snapshot-fixture-storage-reference-design.md`
and matching plan. Actual independent SOURCE SPEC and fresh QUALITY passed.
Exact id/owner/prior-reference UPDATE RETURNING asserts the stored object UUID;
established KnowledgeFixtures, production reference rejection and all assertions
remain unchanged. This is metadata setup, not authenticated original byte proof.

The two NEW owner-precommit malformed-content cases retain real native identity
authorization through the bounded test-only composition in
`docs/superpowers/specs/2026-10-12-singularity-v0.2-phase-5-precommit-native-authority-design.md`
and matching plan. Actual nonauthor SOURCE SPEC and distinct fresh QUALITY
PASS on complete design b1bc11db/plan c42238e0. The fixed existing definer hop
surrounds only unchanged native identity loading on the SAME pinned MigrationRepo
connection; real Authorize/custody and initial/repeated lexical checks remain.
Restore owner before content, preserve native returned errors/exceptions, add
outside-wrapper genuine native-result/restoration witnesses, exact integrity
errors and same-connection rollback role/GUC/lock checks. No grant, credential,
production/shared fixture or frozen-source change. The historical SQL50680 wait is closed; its failed gate remains historical.
The current source qualifies only after the complete gates and independent
reviews recorded below; publication and Phase5 acceptance remain separate.

Final actual implemented SOURCE SPEC identified two required corrections within
this existing contract. Select only the unique active domain-version envelope,
matching unchanged live readers; retained historical envelopes must neither
cause false ambiguity nor qualify an inactive-only binding. Preserve rejection
of multiple eligible active candidates. For a Document original, resolve the
immutable canonical `source_object_id`, not the source Asset's mutable pointer:
normal cleanup releases resource_assets and NULLs asset_object_id while the
Document pin retains its original. Match exact source Asset/version/resource,
owner/classification and size; ordinary live Asset capture still requires its
actual live, unreleased eligible association. Add causal SQL regressions for these actual
states, retain every original assertion, and repeat complete owning gates plus
actual NONAUTHOR SOURCE SPEC and distinct fresh QUALITY. No frozen rotation,
deletion, custody, key, grant or migration change is authorized or needed.

The subsequent actual implemented QUALITY review found that ordinary live Asset
capture must match the established download and Note-source state set:
available/processing/ready, not available alone. Add separate causal SQL
regressions for processing and ready pins with genuine existing authorization
and both unchanged Asset readers; retain exact pointer, unreleased association,
owner/classification/version/object/size/generation and envelope checks.
Correct only the NEW predicate after causal RED, keep deleted/released/tombstone
denial and retained Document admission separate, then repeat complete gates and
actual SOURCE SPEC followed by distinct fresh QUALITY. Prior reviewed results
and their failed coverage remain historical; no lifecycle or frozen change.

Current Task13 source is locally qualified: whole114pure/48SQL/static GREEN,
current13/frozen56 matches and normal cleanup; actual NONAUTHOR SOURCE SPEC
then distinct fresh QUALITY PASS on receipt3d7de0cf (Repository17e3874a,
Test76810aa3). Historical failure/initial fixture-witness gates remain FAIL.
The separate Legacy owning70 gate closed normally70/0 with clean resources.
Task13 local commit is09f8ee0c0a69cdd26612e0663a29a9d156c46986; its exact
seven owning files match the tested/reviewed receipt. No publication occurred.
Legacy retained16 and final reviews remain separate pending Task9C prerequisites.

- [x] Add RED tests for the fixed Runtime ExportSnapshot entry, authenticated
  `Repository.capture/4`, sealed `Repository.next_page/3` and concrete Spool
  open/append/seal/read_page/read_chunk/abort. Characterize unchanged request
  scope/auth/resolver behavior and existing Core rendering before implementation.
  Missing-module RED is not implementation acceptance. Complete applied design
  SPEC and separate fresh QUALITY precede test-first GO.
- [x] ExportSnapshot uses only a private per-call runtime copy with scoped_repo
  `{ExportSnapshot, existing_trusted_scoped_repo}`. Its fixed transact callback
  delegates to unchanged ScopedRepo.transact/4 with repeatable-read before
  context/auth SQL. Invoke unchanged OperationScope.with_shared_request and
  Authorize with existing private unlocked asset.read/note.read requirements;
  preserve advisory locks and denial audit, reject nested active transactions,
  never set READ ONLY. Separate single-Note note.export policy stays unchanged.
- [x] `capture(repo, authorize_snapshot, options, spool)` receives the trusted
  lexical arity-one closure created inside the successful Runtime scope, bound
  to original caller/repo/resolved session/fixed requirements. It repeats actual
  Authorize.check before selection; Repository requires active repeatable-read
  and matching current GUC principal/owner, deriving owner solely from the
  result. Reject maps/Booleans/GUC-only proof and wrong caller/context. This
  internal seam assumes trusted BEAM adapters, not hostile replacement code.
  Consume every SQL page inside the scope, return no SQL cursor/stream, expose
  sealed spool descriptor only after real COMMIT. Callback/COMMIT failure cleans
  even sealed output; binary transfer starts afterward with fresh authorization.
- [x] Select all live Note/Document heads; closure follows each selected Note's
  sealed attachments/citations to exact live Note versions recursively and exact
  live Document/Asset version bindings. Maintain separate bounded metadata
  discovery, body demand and body traversal indexes: an ancestry/endpoint
  discovery cannot suppress a later legitimate body promotion. Mark body
  traversal before expansion, queue a promotion once, sort frontier by
  `(kind, resource_id, version_id)`, terminate cycles and retain distinct pins.
  Validate existing sealed Storage.Postgres.KnowledgeLinkRepository.read_membership/3
  plus the combined100
  distinct-source-target limit. No successful truncation.
- [x] Include tags/assignments and relationships with at least one selected
  body/source-selected endpoint, after body closure settles. Authorized other
  endpoint/pinned-version descriptors remain metadata-only and do not expand
  edge traversal or bodies. Note parent/merge ancestry recursively contributes
  metadata-only descriptors, no ancestor bodies/source traversal. Produce one
  final descriptor per identity after promotions settle; resource reason
  precedence is head/source/tombstone/relationship_endpoint, separate from body
  admission. Every declared head/pin/parent/merge/source/endpoint must resolve.
- [x] Only positively resolved deleted Note sources receive existing authorized
  metadata/selected citation locator with null file/offset/size and no hidden
  plaintext. Optional tombstones add metadata-only versions/membership/edges,
  never deleted bytes. Private render descriptions use exact-version titles,
  not substituted heads. `metadata_only_unavailable` remains reserved but is
  never emitted: current resolver has no positive unavailable witness. Live
  not_found/missing bytes/unsupported storage/corruption/I/O/authorization errors
  abort the entire operation, never downgrade included content.
- [x] Spool fixed metadata, private render descriptions, canonical Note Markdown
  and canonical fragment text. Metadata keyset pages<=500; select at most one
  Note<=1MiB or fragment<=64KiB at a time, not500 TEXT values. Compute captured
  Note body_digest as SHA-256 of canonical Markdown bytes (no persisted Note
  digest column or new digest module).
  Validate fragment ID/hash/locator/contiguous ordinals,<=4096/16MiB aggregate,
  no-delimiter incremental SHA-256 and UTF-8 byte offsets, including empty hash.
  Seal exact capture-bound text identity/offset/length/digest refs, never expose
  private host paths/render refs in public descriptors.
- [x] Preserve ready-Document1–4096-fragment/1–16777216-byte lower bounds,
  characterized in current completion, original deferred completion and accepted
  restore admission. Correct only the newly authored invalid ready-zero SQL
  fixture to a legitimate terminal unsupported/no_extractable_text capture:
  unchanged actual original binding/digest/size/path, no extracted path/digest,
  no fragments/text refs. Do not fabricate authenticated empty bytes by changing
  SQL size/digest. Add explicit real SQL rejection of zero-ready completion,
  precommit Repository denial and actual deferred-COMMIT denial; clearly separate
  owner-role precommit probes from real Runtime/committed proofs. Leave pure
  Spool's existing exact empty Note/fragment SHA256, zero-size, read-boundary and
  all other valid assertions unchanged. The first invalid-fixture failure stays
  recorded; repeat complete Task13 SQL/pure gates after actual independent
  amendment SPEC/fresh QUALITY, before production GO. No trigger/schema/old
  migration/normal extraction behavior change or successful empty-ready export.
- [x] Asset plaintext SHA-256 is absent from canonical storage. Capture exact
  private pending-original binary bindings/known size, never substitute keyed
  lookup_digest or ciphertext_hash. A fixed private binary_bindings collection
  and null-digest Asset version drafts are internal only, not Core-valid public
  records/artifacts. Task14 verifies authenticated actual original bytes and
  Task15 fills their real SHA-256/size before unchanged manifest validation.
  Retain Document source_digest plus later actual-byte verification. Charge all
  private bindings toward existing budgets; no new digest column/unavailable
  status or private path/binding fields in public output.
- [x] Use the trusted dedicated root, exclusive0600 files/0700 owned directory,
  no symlink/overwrite, fixed selectors and capture-bound cursors/exact sealed
  refs; no caller paths, arbitrary SQL/fields, term or atom deserialization.
  Metadata indexes contain bounded flags/identities/offsets/lengths/hashes, not
  corpus payload; sort those indexes and consume one bounded record at a time.
  Enforce100k identities,1M all metadata/index records,1GiB all spool bytes
  including plaintext/framing/on-disk indexes/superseded records, fixed15min
  deadline and existing per-item limits. Temporary duplicate text copies count
  against spool; originals reserve known sizes toward64GiB final files including
  manifest but still require actual digest/byte validation. A valid escaped
  metadata record may exceed64KiB, which limits chunks, not record length;
  smaller pages are permitted. No quota override or successful partial export.
- [x] Trusted internal Spool context may inject only write(device,binary)/2,
  default real IO.binwrite, for deterministic bounded-write ENOSPC failure.
  No request/config/quota option/general filesystem abstraction; preserve all
  real root/path/mode/ref/cleanup checks. Label synthetic write-error and used-
  counter threshold arithmetic separately from actual filesystem/volume proof.
  Require normal real-filesystem byte/record/index accounting, owned cleanup and
  no sealed descriptor after failure; fixed limits/default timeouts unchanged.
- [x] Real Runtime SQL proves current session identity/epochs/expiry/revocation,
  existing read capabilities/unlock and owner denial, not a fabricated auth
  callback. Pure fakes prove only wiring/isolation-before-context. Genuine SQL
  proves RR before first query, no nested snapshot, source seals/promotion/
  historical-pin cycles/ancestry/edge/tombstone closure and exact independent
  output oracles. Barrier moves heads/tags and pending-to-ready after cut:
  captured metadata/text/pins remain unchanged. Verify source corruption/bounds,
  callback/COMMIT failure, no precommit descriptor, transaction closed before
  transfer, no escaped SQL stream and operation-only cleanup with neighbor
  sentinels. No arbitrary sleeps or default-timeout/required-assertion weakening.
- [x] Run complete pure spool/wiring/Core owners and real SQL owners, with SQL
  tags/exclusions reported separately rather than counted as pure coverage:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/knowledge_export/spool_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs apps/singularity_core/test/singularity/core/knowledge_export_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs --seed 215378 --warnings-as-errors
devenv shell -- bash .devenv/phase5-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_export/repository_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_snapshot_test.exs --seed 215378 --warnings-as-errors
```

  Run static/frozen/source checks; actual NONAUTHOR SOURCE SPEC then separate
  fresh QUALITY, commit `feat(export): capture exact live source closure in private spool`.


- [x] Make the bounded Task13 local commit after every live parent gate closes;
  record its SHA and exact seven-file/source verification scope. This does not
  qualify pending Legacy70/full16, Task14 authenticated bytes or Phase5.
## Task 14: Exact immutable source reads using unchanged request custody

**Create:** `apps/singularity_runtime/lib/singularity/runtime/knowledge/export_read.ex`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs`.
**Modify:** Storage `knowledge_export/repository.ex` for exact source binding reads.
**Depends on:** Task 13; frozen DownloadLease/KeyCustodian files remain unchanged.

The independently SOURCE SPEC/fresh QUALITY reviewed zero-only caller amendment
is `docs/superpowers/specs/2026-10-12-singularity-v0.2-phase-5-zero-asset-read-design.md`
and `docs/superpowers/plans/2026-10-12-singularity-v0.2-phase-5-zero-asset-read.md`.
Actual locked empty layout0/format1/cipher134 may use existing :all; nonempty
eager reads remain prohibited. Keep the Asset-first/object/selected-envelope/
domain-version locks through actual original callback/custody/audit/COMMIT.
No Task14 implementation before Task13's complete qualification/local commit.

Task13's prerequisite is qualified at local09f8ee0. Task14's two NEW test
authors closed before the initial full pure/live commands. Pure closed248592,
exit2:61 reported,38 actual,25 missing-module failures,23 SQL exclusions.
Initial live closed8e46b6/exit2:102 reported,89 actual,67 failures,13 pure
exclusions. All66 NEW cases failed an attachment timestamp fixture contract;
one old worker-permission assertion conflicts with accepted worker SELECT.
These failures remain FAIL, with bounded diagnosis/test repairs pending;
neither live binding nor Task14 acceptance is established.

The final NEW-only fixture correction closes complete initial RED: puref1e34b/
exit2,38 actual/25 missingNEWmodule failures,23 SQL exclusions; live9ed6a1/exit2,
89 actual/66 missingNEWwiring failures,13 pure exclusions,74.8s. All23 old native
cases pass. Full66 failure sections independently resolve to65ExportRead guards
and1AssetScope guard, not earlier constructor failures. All66 assertions/cases
remain; prior failures are retained. Native cleanup/source/frozen checks closed.
Bounded Task14 production authoring may now proceed; no behavior acceptance.

Initial concrete implementation passes complete pure3 closed5f960b/exit0:
38actual/0fail/23SQLexcluded and live3 closedcf7516/exit0:89actual/0fail/
13pureexcluded,103.4s (all66NEW plus23OLD native cases). Formatterd9d71bexit0,
new13source receipt86332714 matchedd1dd0c and frozen56matchedeb206a. Actual
SOURCE SPEC closed nofindings; distinct fresh QUALITY closed one P2: final
sealed capture check precedes final text eligibility guard, so capture can
expire/abort during that guard and still report completion. Previous GREEN is
historical scoped evidence, not Task14 qualification. TEST-ONLY causal native
Spool Note/fragment/empty expiry/abort regressions now authorized; production
order fix waits parent RED. All old assertions/66 live cases retained. No
custody/lease/Vault change; E2E NOT RUN. Parent review records are
`.devenv/phase5-task14-initial-source-source-spec.md` and
`.devenv/phase5-task14-initial-source-quality-finding.md`.

Completion-P2 test-only source closed with16 new native Note/fragment ×
normal/empty × expiry/abort × descriptor/reducer witnesses; all25 old pure
cases remain. Whole pure3 causal RED closed0ca7b0/exit2:77reported/54actual/
16newFAIL/23SQLexcluded. Every new case reaches its exact final-error assertion
after positive native reads, final invalidation, scope COMMIT/close and no-lease
witnesses; current source incorrectly returns OK. All38 retained actual cases
pass. Full archive `.devenv/phase5-task14-completion-initial-red-pure.log`
SHA9caabb3b4b546a8c2ea28e5c3e023442250d79a6242f788fe29e747e461ee103.
Formatted pure source3a249336; ExportReadf4987b44 and frozen56 remain unchanged.
Production completion-order repair1 now runs the final canonical guard before
the final native capture read. Whole pure3 closes152ccf/exit0:54actual/0fail/
23SQLexcluded; whole live3 closesd00380/exit0:89actual/0fail/13pureexcluded,
115.7s. An intermediate54actual/0assertion-failure run closed166afa/exit1 on
56 generated-test warnings; it remains FAIL. Test-only helper extraction keeps
all41 pure cases/assertions and removes static literal branch warnings without
suppression. Current ExportRead9e7e20f2/Testc9d5064d; source16matched890650 and
originalfrozen56matchede7b3d8. Actual SQL root absence d4caa2/normalmaintenance
40c2bf EMPTY. Final actual NONAUTHOR SOURCE SPEC and distinct fresh QUALITY both
closed PASS with no P1/P2, receipt18739b26. Fresh precommit whole pure3e82f6d
closes54actual/0fail/23SQLexcluded and staticd093b3 verifies format/WAE/zero
cycles. Task14 is qualified as an isolated component and locally committed at
444e4604f1131746d0350393e8d3e8d05b6a9db7; no Phase5/publication qualification.
Full GREEN logs27bc3fb4/dc61cbb1,
intermediate warningFAIL58a3aba6; Solrepair1 successful/Astra0.

`runtime.knowledge_export_repository` is a trusted internal BEAM composition
seam, defaulting to the actual Storage Repository. Module/tuple dispatch may
support deterministic tests but is never selected through session/binding/
request options or exposed by Task16. Original authorization, fixed real
OperationScope, Asset callback, custody, reader, audit and COMMIT stay intact.

- [x] Add RED `ExportRead.document(runtime, session, captured_binding)` and
  `ExportRead.asset(runtime, session, captured_binding)` tests. Exact old version
  of a live Document returns original bytes even when its source Asset is deleted;
  deleted Document, changed pin/object/size/hash and unknown storage format deny.
- [x] Implement owner-free exact binding lookup under `OperationScope`:
  specified live Document resource + immutable version + independently retained
  source object/digest/size; max 64 MiB; exact envelope generation. Use unchanged
  request custody `purpose: :document_source`, `access: :request`, session/
  principal/owner epochs, required `asset.read`, exact version/object/generation.
  Use existing `DownloadLease.read_document_chunk/2` and empty authentication.
  Authenticate complete preflight then bounded delivery; revoke leases in `after`.
- [x] For Asset pins prove one exact version/resource/Asset/object association,
  retain live Asset authorization and existing bounded delivery; never call the
  eager `:all` bytes variant for nonempty sources. Only the reviewed locked
  canonical-zero exception above may invoke existing :all. Revalidate binding
  before lease and at completion; no custody/lease/grant change.
  No worker/extraction identity, RestoreIntegrityLease or caller adapter.
- [x] Reject revocation/unlock loss between chunks and after preflight; exact
  historical pin must not follow current head. Fake tests prove callback order/
  bounds/revoke; live test uses real existing custody and source SQL binding.
  A fake lease cannot establish live correctness.
- [x] Revalidate originally included Note/fragment exact immutable binding and
  resource liveness after snapshot and at completion, without following a new
  head, tags or pending-to-ready extraction. Consume sealed captured canonical
  text with its exact digest; no invented text lease. Deleted/revoked selected
  source fails the whole export rather than metadata-only downgrade. Keep
  original binary custody/DownloadLease unchanged and distinguish these checks
  from authenticated original chunk delivery.
- [x] Resolve Task13's private included-Asset pending digest only from authenticated
  actual original bytes and exact captured binding/size. Do not substitute keyed
  lookup/ciphertext evidence or invent a persisted digest/lease authority.
- [x] Run pure and isolated live owners:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_read_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_custody_live_test.exs apps/singularity_runtime/test/singularity/runtime/document_api_test.exs apps/singularity_runtime/test/singularity/runtime/document_custody_test.exs --seed 215378 --warnings-as-errors
```

  Stop this task if satisfying exact reads would require frozen custody/lease
  semantics changes; report evidence and continue only independent valid work.
  SPEC then QUALITY, commit `feat(export): read captured sources with existing request custody`.

## Task 15: Private bounded writer, byte verification and portable manifest

Necessary scaling repair: draft design and detailed plan
`docs/superpowers/specs/2026-10-12-singularity-v0.2-phase-5-sealed-record-iteration-design.md`
and
`docs/superpowers/plans/2026-10-12-singularity-v0.2-phase-5-sealed-record-iteration.md`.
Resolve the actual independent quality P2 with reviewed internal metadata
point reads and one traversal, causal RED, whole owning/retained gates, then
fresh source/spec and quality review. No Writer acceptance or local commit
until this finding closes; previous116/0 remains historical scoped evidence.

Repair design actual SOURCE SPEC and distinct fresh QUALITY closed PASS at
reviewed interfaces ed5f601e/c67f0fa1. Test-only source closed; whole pure5
causal RED closed4696b3/exit2:180actual/21FAIL,17SQLexcluded. The20 additive
Spool cases reach missing concrete exports and Writer's native traversal witness
observes2080page calls before its expected zero-call assertion fails. All159
other cases pass, including all old Spool/Writer cases and additive near-limit
denial. No constructor/trace/cleanup failure. Full archivef98aae73; production
Spoolb643cd80/Writer4681a19e unchanged at that causal RED snapshot. Production
repair1 currentSpool2d6dfb4e/Writerb119b752 now passes whole pure5:
180actual/0fail/17SQLexcluded, retained Repository/Snapshot SQL48actual/0fail/
11pureexcluded, retained Task13pure134actual/0fail/17SQLexcluded and complete
format/WAE/zero-cycle static gate5e0b09. All old31Spool/50Writer assertions
are byte-identical after stripping only the additive marker blocks.
Actual nonauthor SOURCE SPEC closedPASS, receipt9254daf1; distinct fresh
QUALITY closed TWO P2: repeated global fragment/Note-source identity scans and
repeated growing whole-ETS-ledger copies during full materialization. Actual
review receipt6a7ff820 records both; point-read GREEN is not Task15 acceptance.
The bounded full-materialization amendment passed actual design SOURCE SPEC
then distinct fresh QUALITY at reviewed interfaces711deca5/4131e4b4. Test-only
author CLOSED with five added whole-path/bounds/ambiguity/inode cases; all old52
cases/helpers remain exact after removing only the new marked block. Parent
fullread/format closedca6aae; inverse5bef3a recovers entire oldbe8a650e.
Whole pure5 causal RED closes05eaca/exit2:185actual/3FAIL/17SQLexcluded,
all180oldactual plus newambiguity/inode cases PASS. The three failures reach
required zero-work counts (131globalcounts/1266ledgercopies) and missing charged
auxiliary-index denial, after native setup/output/cleanup assertions pass.
Complete archive3f17139c/source16receipt1119efdb matched8ee021. Cumulative
Sol scalability repair2 authoring is now CLOSED; parent fully read1640lines,
onlyWriterformat0b444fexit0. Writer841f3e6b/Test51d972c1/current16receipt3c6b7ee1
matchedfaae0b, originalfrozen56 allmatch. Wholepure5 4a39ebexit0:185actual/0fail/
17SQLexcluded logfd47fc89; retainedRepo/Snapshot SQL731f65exit0:48actual/0fail/
11pureexcluded log63219b0c, actualrootabsenceb042df andnormalmaintenanceb6a231
EMPTY log0e1665c4. RetainedTask13pure24a037exit0:134actual/0/17SQLexcluded
log764c576c; statica4ff05exit0format/WAE/zeroCycles log6fd24830. ActualNONAUTHOR
SOURCE SPEC CLOSEDPASS/noP1P2 wholeowningreads/nativeproof, receiptff9a8735;
distinct fresh SOURCE QUALITY subsequently CLOSEDPASS/noP1P2 after whole source/
test/native-path/archive reads and independent old52 inverse. Earlier thread-limit
and later separate E-review capacity failures are availability history, not
production repairs or waived reviews. Task15 qualified bounded component locally
committed4e2499d5b89664c3e7b63cb1f3136c243b276c83, exactly seven owned paths.
No measured million-record latency or Task16/Phase5/browser/release acceptance
claim; cumulative oldround1 remains unaccepted, currentrepair2gates/reviewsPASS,
Astra recovery0.

**Create:** `apps/singularity_storage/lib/singularity/storage/knowledge_export/writer.ex`,
`apps/singularity_storage/test/singularity/storage/knowledge_export/writer_test.exs`,
`docs/formats/portable-knowledge-v1.md`.
**Depends on:** Tasks 2 and 13.

Initial complete pure3 gate closedbd2e97/exit2:Core66/0 and NEW Writer40/40
failures. Thirty-nine failures are missing concrete Writer wiring; one NEW
constructor assertion incorrectly treats a legitimate metadata-only Asset
descriptor as a pending included original. Preserve its original-digest
assertions while characterizing the exact included subset. Additional genuine
sealed-but-inconsistent Note/fragment metadata counterexamples are test-only
authoring, not production qualification. No concrete Writer existed at that
initial snapshot. The corrected complete pure3 gate closed530a67/exit2:
Core66/0 and Writer46/45 failures,112 actual/no exclusions. All45 failures
reach missing concrete Writer; one genuine native Spool aggregate-digest
denial passes before Writer. Five additional sealed metadata/text witnesses
reach the Writer guard, not a constructor failure. Production Writer authoring
subsequently closed and the first production46/3 FAIL is retained. Bounded
repair1 plus four added regressions now pass the complete owner command:
Core66/0 and Writer50/0,116 actual/no exclusions, normal closeda5a31/exit0.
Whole format/WAE/xrefzero passed488c28/exit0. Independent actual SOURCE SPEC
then distinct fresh QUALITY and the bounded local commit remain pending.
Unit callbacks prove Writer semantics, not live custody or Task16 acceptance.

Completion publication uses an exclusive directory reservation under the
trusted application-owned0700 root, operation-bound inode/ownership/emptiness
witnesses and a shared finish/abort generation gate. Rename may replace only
that operation's reservation, never a preexisting destination. Recheck owned
identity and cancellation before returning an artifact; cleanup never follows
or removes a foreign replacement. This is not OS RENAME_NOREPLACE protection
against hostile same-UID root mutation; no such protection is claimed.

- [x] Add RED filesystem tests for `Writer.open/1`, `append_file/3`,
  `append_manifest_record/3`, `finish/1`, `abort/1`, `entries/2`, `read_chunk/3`.
  Root is application-configured, never caller input. Writer state has only
  private paths/IO/hash/byte counters; receives authenticated plaintext chunks,
  never keys, wrappers, leases or crypto material.
- [x] Use random operation-owned directories mode 0700, exclusive files mode
  0600 and no symlink traversal/overwrite. Validate UUID paths/case-fold collisions;
  append at most 64 KiB, update hash/size incrementally, stream one JSON record
  at a time through exact canonical record order. Use separate private array
  spools if needed to assemble the exact ordered top-level arrays without
  collecting the encoded manifest. Enforce bytes/records/deadline ceilings.
- [x] Write notes/<resource>--<version>.md; document original with fixed extension;
  extracted `.txt` concatenates canonical fragment text with **no delimiter**.
  Compute UTF-8 byte offsets, not character counts, and exact extracted digest.
  Non-ready Documents have original/state and no fabricated extracted file.
  Asset source pins use assets/<resource>--<version>.bin. Verify each canonical
  original/body/text digest separately from rendered-file hashes.
- [x] Consume only Task13 sealed capture refs. Rehash canonical Note Markdown,
  reassemble at most one<=1MiB Note and<=100 exact source descriptions, invoke
  unchanged Core.render_portable/3 and split its bounded<=16MiB rendered binary
  into<=64KiB chunks. This allowed per-Note allocation is not corpus buffering
  or a new Core streaming API. Rehash each canonical fragment and the complete
  no-delimiter stream; fixed captured UTF-8 offsets must match actual output.
  Count all temporary plaintext copies/framing/index bytes toward1GiB spool;
  all finalized files including manifest toward64GiB, with separate1GiB manifest
  ceiling. Fixed limits have no test/public override or plaintext exemption.
- [x] Finalize private Asset version drafts with Task14 verified original SHA-256
  and byte size before unchanged Core manifest validation. No pending digest or
  private binary binding/path can appear in a completed public manifest.
- [x] Assemble manifest last with exactly `format/version/selection/resources/
  versions/fragments/tags/tag_assignments/relationships/attachments/citations/files`
  as design §5 specifies. Stable arrays/keys/UTC timestamps/no export-clock
  timestamp make identical captured selections byte-identical. `files` excludes
  manifest.json; returned artifact descriptor includes its size/hash separately.
  Verify every listed file/reference/size/hash, then atomic rename to complete
  within the same staging root. An error returns no completed artifact.
- [x] Test disk-full injection, checksum mismatch, canceled writer, malformed
  record, symlink/collision, existing path, chunk/page size observers, exact
  binary/empty/Unicode originals, UTF-8 offsets, metadata-only descriptors and
  deterministic bytes. Never buffer whole original/fragment set/JSON in memory.
  Cleanup only the operation directory, preserving a sentinel neighboring root.
- [x] Document every record field/null/availability, selection scope, readable
  source links, metadata-only tombstones/history, bounds and privacy without
  treating the manifest as logical backup or an all-history recovery API.
- [x] Run the complete pure filesystem file and Core owners to GREEN:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/knowledge_export/writer_test.exs apps/singularity_core/test/singularity/core/knowledge_export_manifest_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs --seed 215378 --warnings-as-errors
```

  SPEC then QUALITY, commit `feat(export): stream private portable files and verified manifest`.

Actual nonauthor SOURCE SPEC passed on Writer4681a19e/Testa1d596e8. Distinct
fresh QUALITY closed with one P2: Writer reads each metadata record through
Spool.read_page(...,1), repeating fullcollection sorting in capture indexing
and again in append. This is static O(N^2 log N) work, not a measured large-
volume result. The fixed15m/ceilings and all50 assertions remain unchanged.
Writer handoff stays unqualified despite the prior whole116/0 GREEN. Required
design/test-first bounded repair and fresh independent reviews are pending;
parent factual records are `.devenv/phase5-task15-repair1-source-spec.md` and
`.devenv/phase5-task15-repair1-quality-finding.md`.

## Task 16: Runtime orchestration, session-bound handles and public API

The 2026-10-19 native prerequisite above is source-qualified; its original
frozen-interface blocker is resolved only for the approved native seam.
Wire the original companion acquisition adapter to `export_lease/2` when resuming
its implementation. Both
strict end-to-end assertions and all startup, exact Task8/native-text
attribution, handle, artifact and independent-review requirements below remain.
The older documentary NO-GO snapshots below are historical, not a renewed
routine approval requirement. No general custody/Vault expansion is authorized.

**Create:** `apps/singularity_runtime/lib/singularity/runtime/knowledge/export.ex`,
`apps/singularity_runtime/lib/singularity/runtime/knowledge/export_artifact.ex`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs`.
**Modify:** Runtime `api.ex`, `application.ex`,
`apps/singularity_runtime/test/singularity/runtime/application_test.exs`,
`config/dev.exs`, `config/test.exs`, `config/runtime.exs`; Web architecture contracts for
  exact reviewed additive blocks only; no web feature/controller/UI.
**Depends on:** Tasks 13–15.

Architecture design/plan are
`docs/superpowers/specs/2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership-design.md`
and `docs/superpowers/plans/2026-10-12-singularity-v0.2-phase-5-export-artifact-ownership.md`.
Actual nonauthor DESIGN_SOURCE_SPEC closed documentary disposition PASS WITH
UNSATISFIED BOUNDARIES: late unreturned native lease after public call timeout,
and companion death losing the sole lease identifier/map. Both strict cleanup
guarantees remain BLOCKED_DESIGN/unchecked/unwaived; native manifestations NOT RUN.
Historical distinct fresh DESIGN QUALITY found a startup P2: cleanup's supervisor-
absence check did not atomically cover later supervisor start, permitting
overlapping scavenging. Subsequent startup and Task8 positive-witness documentary
repair2 received actual independent DESIGN SPEC then NEW distinct fresh QUALITY
PASS on design58a9cc42/plan80fdebe81. Reviewed copies and actual receipts are
`.devenv/phase5-task16-attribution-design-repair2-reviewed-{design,plan}.md`,
`...-spec.md` and `...-fresh-quality.md`. This resolves the bounded documentary
finding, not its NOT RUN native implementation or either strict ALL-lease
guarantee. No affected source GO/Task16 acceptance; independent valid work may
continue without changing frozen custody or leases. This status synchronization
is bookkeeping, not a new design or source authorization.

- [ ] Add RED API/handle tests for these exact public operations and internal
  leading-config variants following the existing Api testing convention:

```elixir
export_knowledge(session, %{include_tombstones: false})
knowledge_export_entries(session, handle, cursor)
read_knowledge_export_chunk(session, handle, path, index)
close_knowledge_export(session, handle)
```

  Returns opaque verified handle; pages contain only relative path/media/size/
  SHA-256, at most 500 entries; read only manifest-listed path/ordinal chunks
  at most 64 KiB. Handles expose no host path. Unknown options, destinations,
  caller owners/adapters, absolute paths and invalid ordinals reject.
- [ ] Implement `Export.run/3` resolving current authenticated session, deriving
  owner, checking existing Note/Asset read requirements, capturing snapshot,
  transferring exact originals/Note/text and manifest, verifying output and
  reauthorizing completion. Keep metadata transaction closed for transfer/client
  delivery. No new capability or Vault grant. Errors are content-free atoms/
  existing sanitized Error values; canary content never reaches logs/telemetry.
- [ ] Compose the Task13 ExportSnapshot/Spool and trusted application-configured
  `knowledge_export_root`, separate and not nested under storage_root/backup_root
  or their aliases. Dev/test/prod supply only this ephemeral plaintext root;
  optional SINGULARITY_EXPORT_ROOT defaults to an isolated sibling beside the
  backup root, with a separate run-scoped test root. Existing required environment,
  storage/backup/key/custody roots and production-write activation stay unchanged.
  Validate absolute ownership/modes and reject root overlap/nesting/symlinks;
  never accept request-selected roots or silently reuse ciphertext/backup roots.
  Composition tests assert exact trusted root/adapters and existing contracts.
  Revalidate captured immutable text/original bindings after cut and at completion;
  starts no binary materialization before snapshot COMMIT.
- [ ] Implement temporary `ExportArtifact` under existing supervisor/task seams,
  bound to original session/principal/owner/authorization epochs, with maximum
  15 minutes from creation. Monitor the requester only during generation:
  requester death before completion aborts and cleans the operation. Before
  returning a verified handle, hand completed ownership to a supervised artifact
  owner under existing supervision and remove the generation-request monitor. A
  short-lived request PID exiting after successful return must not destroy
  the handle. Its owning authenticated session can still read until explicit
  close, revocation, expiry, artifact-owner death or restart cleanup.
  Any operation-local Writer ledger has the same owner lifetime: create and
  materialize it inside the eventual supervised artifact owner, or transfer
  it through a trusted internal ownership seam before generation exits. No
  caller option, global registry or new custody capability. The requester-exit
  test must read actual entries/chunks after the generating request is DOWN;
  checking only handle presence is insufficient.
  Authenticate live owning
  session before entries and every chunk; handle possession is insufficient.
  Use monotonic deadline and deterministic test clock/barriers, no arbitrary
  sleeps or new durable queue/domain GenServer. Idempotent owner close revokes
  delivery and removes only its owned artifact.
- [ ] On revocation, loss of unlock, timeout/cancel, denied chunk, checksum,
  generation-requester death, artifact-owner death or startup leftovers, clean only recognizable
  export-owned directories below dedicated configured staging root and revoke
  outstanding leases. Test another owner's/operation's sentinel survives.
  Add two deterministic monitor-handoff tests: kill generation requester before
  completion and assert no handle/owned files; let requester exit after success
  and assert same-session manifest/chunk access remains valid until owner close.
- [ ] Extend architecture baseline contracts with exact Phase 5 block/context
  hashes and mutation/removal/duplication/relocation tests. Strip only exact
  approved additions before existing hashes; retain all Phase 2/3/4 and legacy
  runtime assertions. Add exact Phase 5 knowledge-registration attribution and
  unknown-operation/function-clause negatives. Parent inspects and reviews the
  necessary addition protocol before changing it. Never blanket-whitelist
  `Knowledge.Export` terms or replace a baseline with the current file hash.
  Task 0 and Task 1 did not pre-authorize stripping. Dependency graph
  remains seven applications, zero cycles.
- [ ] Run full API/artifact and architecture owners:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/knowledge_export_api_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_artifact_test.exs apps/singularity_runtime/test/singularity/runtime/application_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --seed 215378 --warnings-as-errors
```

  SPEC then QUALITY, commit `feat(export): deliver verified artifacts through authenticated runtime api`.

## Task 17: Independent live portable acceptance, privacy and bounded streaming

**Create:** `apps/singularity_runtime/test/singularity/runtime/knowledge_export_live_test.exs`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_export_privacy_test.exs`.
**Modify:** fixture support only for additional selection/fault barriers.
**Depends on:** Task 16.

- [ ] Add live RED acceptance materializing entries/chunks through Runtime.Api
  into a separate test-owned directory. Parse manifest with Jason and verify
  every ordinary relative Markdown link/footnote, manifest reference, path/hash/
  byte count and UTF-8 offset without any database lookup/proprietary URI.
  Original PDF/plain/Markdown/empty bytes equal independent source oracles.
- [ ] Cover duplicate titles, malicious labels/paths, version cycles, two pins
  to historical versions, relationship metadata endpoints, parent/merge metadata,
  source Asset deletion with live Document retention, optional tombstones and
  positively resolved deleted-source metadata; reserved unavailable status is
  never emitted without a positive witness. No deleted body/original file
  or unselected conflict/history body appears. Live missing/denied source fails.
- [ ] Use barriers to move heads/change tags after capture (unchanged captured
  output), delete/revoke selected live source before transfer/completion (whole
  failure and cleanup), revoke between delivered chunks (denial), expire/cancel/
  kill requester during generation or artifact owner, restart scavenging and disk exhaustion.
  Assert no handle exists before completion and no partial artifact advertised.
- [ ] Instrument page/chunk sizes and spool counters; assert <=500 rows,
  <=64 KiB content chunks and fixed total limits. Memory observation must use
  deterministic retained-size/counter bounds plus a large fixture, not a flaky
  wall-clock/GC threshold. Inspect production code for eager `:all` reads and
  full-export `Enum.to_list`/JSON encoding. Identical captured selections produce
  identical manifest and file bytes, even with different handle/time IDs.
- [ ] Capture logs/telemetry/errors/Inspect with user-content canaries; no bodies,
  titles, source labels, storage references, principal/session/key/job fields
  leak. Artifact plaintext is private user content, mode 0700/0600.
- [ ] Run all live portable/privacy and existing Markdown integration owners:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_export_live_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_export_privacy_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_export_integration_test.exs --seed 215378 --warnings-as-errors
```

  This is scoped real runtime acceptance, not browser E2E. SPEC then QUALITY,
  commit `test(export): prove portable bytes source closure and denial cleanup`.

## Task 18: Exact local 0.1 migration fixture and V3 restore upgrade acceptance

**Create:** `apps/singularity_storage/test/fixtures/upgrade/v0.1.0/migrations/`
  containing the exact 22 historical Storage migration files,
`apps/singularity_storage/test/fixtures/upgrade/v0.1.0/source.json`,
`apps/singularity_storage/test/support/legacy_upgrade_fixtures.ex`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_upgrade_live_test.exs`.
**Modify:** `apps/singularity_storage/test/support/migration_test_environment.ex`
  only to accept a trusted test-owned frozen migration path when needed.
**Depends on:** Tasks 11, 12 and 17.

- [ ] Reproduce local source identity checks (no remote release verification):

```sh
git rev-parse 'c49dc0aeda1d0115b20ff291f0da658f7e558b43^{commit}'
git tag --points-at c49dc0aeda1d0115b20ff291f0da658f7e558b43
git show -s --format='%H %s' c49dc0aeda1d0115b20ff291f0da658f7e558b43
git ls-tree -r --name-only c49dc0aeda1d0115b20ff291f0da658f7e558b43 apps/singularity_storage/priv/repo/migrations
```

  Expected local commit exact SHA, tag `v0.1.0`, subject
  `merge: verify release exporter equivalence`, 22 migration files through
  `20260818000100_create_private_markdown_notes.exs`. Store commit ID, source
  path, ordered filename/blob hashes and SHA-256 in `source.json`; frozen files
  are copied through reviewed patches, never current migration substitutes.
- [ ] Write RED fixture identity and upgrade live test. A current ceiling alone
  is insufficient because a historical migration file might have drifted.
  Run frozen release migrations into allocated database A using the established
  table-owner/bootstrap/extension test lifecycle. Populate legitimate legacy
  Notes/history/conflicts, live/deleted Assets/bytes/associations/durable work
  using the historical schema; capture immutable IDs/digests and binary bytes.
- [ ] Apply all current forward migrations through Phase 5 to the same database
  without reset. Assert legacy data unchanged, derived source seals complete,
  current RLS/grants/constraints, seven apps and new knowledge tables empty
  where expected. Characterize failures before any necessary narrow forward
  repair; never rewrite the frozen fixture or released migration for GREEN.
- [ ] Add current knowledge through qualified existing contracts in test-only
  scope, create default V3, restore into fresh current database B with a new
  owned root and supported maintenance saga, then compare full canonical
  history/source sets/digests/original bytes and public search. Prove database A
  unchanged and B not published until verification completes.
- [ ] Run full upgrade live file plus existing migration and V1/V2 owners:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_upgrade_live_test.exs apps/singularity_storage/test/singularity/storage/knowledge_migration_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs --seed 215378 --warnings-as-errors
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/logical_v1_compatibility_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs --seed 215378 --warnings-as-errors
```

  Record both isolated identities/cleanup; SPEC then QUALITY, commit
  `test(upgrade): qualify exact v0.1 schema through v3 restore`.

## Task 19: Complete permitted README gate, independent acceptance and local handoff

**Modify:** `docs/verification/2026-10-11-phase-5-acceptance.md`, master release
  plan Phase 5 checklist, Phase 5 design/plan status, active guidance and
  `docs/formats/portable-knowledge-v1.md` only when supported by actual evidence.
**Depends on:** every preceding task GREEN, all independent findings resolved.

- [ ] Reconcile the entire design §§1–12 and master Phase 5 deliverables against
  source and tests, not completion checkboxes alone. Hash frozen Vault/custody/
  key/capability/policy/crypto files and compare baseline; report any narrow
  knowledge compatibility seam explicitly. Confirm new migration-only helpers
  have no runtime authority and production canonical-write guards remain closed.
- [ ] Stage/commit only reviewed implementation/docs so the required clean
  worktree check is meaningful. Record exact tested source; no history rewrite,
  merge/push/version/tag/release/deploy or production data operation.
- [ ] Run the complete permitted README gate from the exact checkout. Use the
  established isolated cluster environment; do not expose connection secrets.
  E2E is explicitly omitted under user deferral, never executed or claimed PASS:

```bash
(
set -euo pipefail
trap 'devenv processes down' EXIT
devenv up -d
devenv processes wait --timeout 120
devenv shell -- bash apps/singularity_storage/priv/repo/bootstrap_roles.sh
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix deps.get
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix deps.unlock --check-unused
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format --check-formatted
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix compile --warnings-as-errors
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.integration
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix singularity.test.restore
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix npm.verify
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix duskmoon_bundler.js.check
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix npm.run test:js
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix duskmoon_bundler.build singularity_web --tailwind
devenv shell -- env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix xref graph --format cycles --fail-above 0
nix run nixpkgs#actionlint -- .github/workflows/ci.yml .github/workflows/test.yml .github/workflows/e2e.yml .github/workflows/release.yml .github/workflows/docker-image.yml
git diff --check
git status --short
test -z "$(git status --porcelain)"
)
```

  Expected all executed commands exit 0; xref `No cycles found`, seven apps.
  Any executed gate failure blocks acceptance: diagnose/repair and rerun
  affected checks plus required gate, preserving assertions and repair counters.
  Service/database/object-root cleanup is verified, not inferred from trap text.
- [ ] Obtain final independent SOURCE SPEC review against exact tested commit,
  full design/master checklist, source/migration/test diffs and actual report.
  Then obtain fresh QUALITY review for security, streaming/memory, lifecycle,
  idempotency, SQL authority, maintenance visibility and frozen boundaries.
  Separate reviewers/findings and actual dispositions; no advisory review is
  implementation acceptance. New changes require relevant regression evidence.
- [ ] Record exact tested commit, docs handoff commit separately, migrations,
  changed files/test counts/commands/exit codes, wire hashes/original byte
  comparisons, upgrade source manifest, independent reviews and cumulative
  repair counts. Mark E2E **NOT RUN — explicitly deferred local development**;
  final browser/release acceptance unresolved. Check master Phase 5 deliverables
  only after their actual evidence passes. Record no Vault feature work,
  no production canonical-write activation/backfill and no publication.
- [ ] Commit the evidence-only handoff as
  `docs: record qualified phase five export and backup acceptance`, recheck clean
  worktree/finished owned commands, and stop Phase 5 work at the accepted local
  boundary. Automatic next-phase preparation requires its own design/plan and
  worktree; this plan contains no Phase 6 implementation or publication action.

## Coverage and acceptance ledger

| Design/master obligation | Planned task/evidence |
| --- | --- |
| Active governance, exact base, E2E deferral and frozen boundaries | 0, 19; full governance suites and frozen hashes |
| Exact 38-table/367-column V3 with immutable V1/V2 | 1, 3; literal schema/goldens and all 87 DDL columns |
| All canonical history/conflicts/tombstones/receipts/source pins | 3, 7, 8, 11; independent full-row comparison |
| Retained originals after source Asset deletion/shared objects | 3, 8, 9, 11; exact inventory and authenticated plaintext bytes |
| Preflight before mutation and historical SQL admission | 4–7; typed staging, role counterproofs and deferred equality |
| Complete immutable Note source-set sealing | 6, 7; empty/nonempty history and append denial |
| Saga failures/retry and no partial graph exposure | 7, 9, 11; pre/import rollback vs post-import maintenance assertions |
| Search rebuild and abandoned extraction recovery | 10, 11; stable results and existing guarded recovery |
| Explicit V3 fail-closed guard and default only after qualification | 8, 11, 12; writer accepts 2/3 only, V1/unknown denied including Note-only history, default V2 until 12, V2/incomplete V3 rejection retained |
| Portable exact live-head closure/metadata tombstones | 2, 13, 14, 17; no deleted-byte authority |
| Ordinary Markdown/original/text/non-secret manifest | 2, 15, 17; independent parser/path/hash/byte oracle |
| Bounded private artifact/session revocation/cleanup | 13–17; actual page/chunk counters and deterministic fault barriers |
| Local historical 0.1 upgrade and fresh V3 restore | 18; exact frozen 22 migration fixture, no reset |
| V1/V2 compatibility and complete permitted local gate | 1, 7, 11, 18, 19; independent fixtures/oracle and actual gate |
| No production writes, no publication, no Vault feature work | All tasks, final 19 audit; E2E remains NOT RUN |

Current task checkboxes and the acceptance report record bounded local evidence;
the initial design draft had no completed tasks. Phase5 overall, complete live
V3/portable-export composition and browser/release acceptance remain unqualified.
Necessary reviewed amendments follow continuous local-development authority.
Any requirement to change frozen custody/key/capability/policy semantics remains
a boundary blocker, not permission to silently work around it.
