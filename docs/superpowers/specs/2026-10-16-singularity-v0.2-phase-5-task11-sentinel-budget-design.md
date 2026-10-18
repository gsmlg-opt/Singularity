# Phase 5 Task11 sentinel execution-budget amendment design

## Status, authority and scope

IMPLEMENTED / DECISIVE MASTER PASS. Independent design SPEC -> NEW distinct
QUALITY and actual SOURCE SPEC -> NEW distinct QUALITY passed. The one-case tag
remains owner4167/860295eb; Native65/66 format/check passed with no delta.
Native67's unchanged whole master passed110 actual tests, all late sentinel
checks, natural0/post0EMPTY; Native68 retained Storage passed167 actual tests.
Remaining combined saga/oracle/README gates and final reviews are still required.
This status does not claim Task11/Phase5 acceptance or an original60s PASS.
The candidate-review snapshots are preserved byte-exact in parent-owned ignored
evidence; no historical timer restriction or FAIL result is rewritten. Only
status is updated here; all reviewed requirements below remain intact.
The authority permits necessary test-contract updates with evidence and review;
it does not permit weakening product assertions or pretending a failed gate passed.

This amendment changes only one test's aggregate ExUnit execution watchdog.
It is NOT a native latency repair, production timeout change, product SLA change,
or Task11/Phase5 acceptance. Preserve every existing assertion and operation.
E2E remains NOT RUN. Task16 remains UNSATISFIED / UNWAIVED / BLOCKED_DESIGN;
Task17 remains NOT GO. No Vault/key/custody/capability/DownloadLease, frozen56,
production, migration, default-V2, publication or production-data change.
No local commit until the existing combined saga/source-review gates pass.

## Evidence and diagnosis

Source baseline: branch codex/v0.2-phase-5-export-backup,
HEAD fed04c1259450a6be3e8ce5bf6a9a1e03c9758c8, index empty.
Runtime owner4166 SHA-256:
28e910d7f74199be5d88a70a24a271fd53be659bab90bc2d785eac5466c25d56.
The temporary observer is removed and the baseline archive comparison is exact.
Native60 and measured Native64 each executed110 actual tests with one FAIL at
the original sentinel/new-target RESTART case's default60_000ms watchdog.
Both failures and all unexecuted assertions remain failed/incomplete historical
evidence. Native63 focused1 actual PASS/50excluded is diagnostic, not master GREEN.

The case has only tmp_dir metadata and no elapsed-time assertion. Runtime's
test_helper starts ExUnit without a timeout override; the pinned ExUnit1.18.4
default is60_000 and its runner honors a per-test timeout tag. No inspected user
or product contract requires this aggregate four-database scenario to finish
within60 seconds. However later nested/saga/observation plans expressly locked
the original timer. This is an explicit amendment of that local-plan restriction,
not a claim it never existed or an automatic waiver under continuous authority.

Measured Native63 ->64 time before fresh RESTART publication grew35079->56120ms:
source preparation+7223, sentinel acquisition+2477, sentinel success+863,
parking/snapshot+13, failed acquisition+1700, failed restore+1036,
failed close+6131, sentinel comparison+15, restart acquisition+1583.
Native64 left3880ms before60_000; successful native restore alone took4855ms
in Native63 and6387ms in Native60, before all remaining original/search/cleanup
checks. Source creation, full migrations, real crypto/fsync, ordinary native DROP
and exact checks are substantive required work, not a proven removable defect.

Astra verified the exact private PostgreSQL stderr target and read only fixed
checkpoint lines. Native64's failed-child cleanup bucket5972ms correlates with
an immediate forced checkpoint total5885ms/sync4905ms; Native60 cleanup4096ms
correlates with checkpoint3869ms. These lack query identity and exact callsite
wall-clock anchors: correlation is NOT attribution or proof of the whole cause.
PostgreSQL17.10's ordinary dropdb calls a forced synchronous checkpoint after
forgetting database sync requests. This is expected native work, not an upstream
bug or permission to omit it. Primary source:
[PostgreSQL REL_17_10 dbcommands.c](https://raw.githubusercontent.com/postgres/postgres/REL_17_10/src/backend/commands/dbcommands.c).
No checkpoint/fsync/database-setting change is proposed.

Two Sol read-only investigations and measured Astra recovery found no justified
removable protocol work under the current locks. The final fsync timeout stack
does not prove a hung final fsync: substantial extra time was already spent before
that restore began. Do not invent a behavioral fix or classify this BLOCKED_ENV.

## Recommended change and alternatives

Add exactly `@tag timeout: 120_000` to the ONE original test named
"Task11 a new-target RESTART preserves a genuinely published parked sentinel installation".
Keep its existing tmp_dir tag, name, body, assertions, callback order and native
operations byte-exact. No module/global/CLI timeout or helper timer changes.

120_000 is a fixed finite engineering budget for the aggregate scenario, with
headroom above the demonstrated60s censoring. It is not a measured worst-case
guarantee or performance claim. A timeout/error/assertion/cleanup failure still
fails the gate. If this budget fails, diagnose again; no automatic increase.
All other test deadlines, process/protocol/lease/SQL deadlines remain unchanged.

Rejected alternatives: blind unchanged master reruns; unsupported production
optimization; reducing migrations/crypto/fsync/data/assertions; template/cache/
prewarm/setup_all lift; splitting the continuous sentinel-preservation scenario;
parallel/pool/toolchain changes; unlimited or suite-wide timeout.
Extra after-DROP/wall-clock instrumentation is useful only for a separately
justified causal latency investigation; it is not needed to establish that the
current aggregate harness budget censors real required work.

## Governing-document synchronization

After design reviews, root updates the conflicting active clauses in the
nested lifecycle design section6/7, nested plan governing boundary/Task4, and
saga plan Task11. Add the same narrowly dated cross-reference in saga design,
Phase5 master design/plan Task11 amendment sections, and observation design/plan.
These eight document updates retain every original deadline except this single
reviewed case-local ExUnit watchdog. The new declaration explicitly supersedes
their originaltimer/no-deadline-relaxation wording ONLY for this case.
No semantic requirement, native work, required assertion or qualification vector
is superseded. Observation notes explicitly preserve historical slice scope:
Native63/64 actually retained the original timer and the observer is removed.
Historical raw logs, source seals, reviews, results and failures are immutable.

## Ownership and verification

Source ownership: only the single new timeout tag in the new Task11 block of
apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs.
Root owns this design/plan, eight bounded governing-document synchronizations and
ignored evidence/seals. All other source is byte-exact, including fixture2904/
312bf952, oracle937/4dd69f7d, ResourceOwner582/bdda89e1, MTE594/ef2627fe,
old lifecycle owner, production and frozen56.

Existing exact whole-master FAIL is RED evidence; no artificial product failure
or unrelated metatest is introduced. Prove removing ONLY the one added tag
reproduces archive4166/28e910d7 exactly. Removing the whole NEW Task11 block must
still yield e897f3e6fc8eb2f517aaabdb9b3e1943db94bbe382aada95f0e87000984eefd7.
Root runs guarded formatting/check, then direct actual SOURCE SPEC and NEW
distinct QUALITY on the precise one-line delta before the fresh whole master.
Focused GREEN is never a substitute for the required whole-owner/master.

Decisive GREEN: unchanged four-owner master/seed215378/warnings-as-errors,
110 actual tests, zero failures, all original sentinel/failed/restart/source
checks reached, natural process exit0, ordinary residual postSQL0/EMPTY,
source/index/status/frozen/toolchain/privatePG/owned0 guards PASS.
All four nested Task4 vectors, saga Tasks12/13, seed0 prerequisites, independent
restore task and complete permitted README gate remain mandatory.
Only forbidden E2E is deferred; final browser/release acceptance is unresolved.

All Native remains parent-owned and exclusive: fresh absent/nonsymlink raw,
umask077, direct existing launcher, no live parallel commands, natural EOF,
complete safe raw review/hash and separate ordinary residual check.
Never access the known credential log. No signals or forced database deletion.

## Counters and honest handoff

This analysis/design is advisory, not an actual behavioral repair.
Original60s behavioral repairs remain Sol0/Astra0; prior SOL_IMPASSE/advisory1
is preserved and this new Astra analysis is separately recorded.
If implemented, record one bounded Astra harness-contract repair attempt;
do not claim it made native latency faster. At least three bounded actual Astra
attempts remain allowed if needed, subject to preserved restrictions.
No Task11/Phase5 completion, commit or advancement until all required gates and
independent reviews actually pass.
