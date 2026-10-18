# Phase 5 Task11 bounded latency observation design

## Status and authority

This is a temporary diagnostic slice under the existing 0.2.0 continuous
development authorization and the accepted nested-fixture lifecycle design.
It is not a performance repair, Task11 acceptance, a timeout waiver, or a new
product feature. E2E remains NOT RUN. Task16 remains UNSATISFIED / UNWAIVED /
BLOCKED_DESIGN. No commit, publication, deployment, activation or production data.

## Later qualification amendment — 2026-10-16

The temporary observer was removed exactly after Native64. Its Native63/64
measurements kept the original60_000ms timer and their actual results remain
immutable. For FUTURE observer-free qualification, only the original sentinel
case's aggregate ExUnit watchdog has the separately reviewed
[sentinel budget amendment](2026-10-16-singularity-v0.2-phase-5-task11-sentinel-budget-design.md)
and [plan](../plans/2026-10-16-singularity-v0.2-phase-5-task11-sentinel-budget.md).
This is effective only after design SPEC -> NEW QUALITY and root source GO.
The no-timer-change clauses below remain historical requirements for this
completed diagnostic slice; they do not override that explicit future exception.
Every semantic assertion/native operation and all other restrictions stay.

## Evidence and question

Native60 ran the unchanged required four-owner master, seed215378/WAE:
Storage59 actual PASS, Runtime51 actual with one failure, natural exit2.
Its sole failure remains the original sentinel/new-target RESTART case3192 at
60_000ms. Restart native restore, originals and search completed at59987ms;
restart close then crossed the deadline. The final close, sentinel-after-restart
snapshot and remaining cleanup assertions were not completed and receive no credit.
Ordinary separate postSQL exited0/EMPTY; full source/index/status/pins/owned0
guard passed. Native13's earlier FAIL remains preserved.

The first child acquisition took14065ms, failed close4096ms, fresh child
acquisition6526ms. These broad intervals do not prove a protocol wait, database
lock, slow fsync, extension-process cost, or other causal bottleneck.

Two independent read-only Sol investigations found no justified removable work.
The preserved latency map already identifies mixed acquisition/cleanup buckets.
We will measure existing boundaries before proposing a behavioral repair.
Latency actual repair counters remain Sol0/Astra0. Native13's historical
SOL_IMPASSE/advisory routing is preserved; advice and observation are not repairs.

## Exact ownership

Only the NEW Task11 block in:
apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs

Temporary baseline:4166 lines,
28e910d7f74199be5d88a70a24a271fd53be659bab90bc2d785eac5466c25d56.
Root creates an immutable exact archive before editing. Removing only the new
observer delta must recover those bytes, and deleting the complete NEW Task11
block must retain original inverse e897f3e6fc8eb2f517aaabdb9b3e1943db94bbe382aada95f0e87000984eefd7.

Parent-owned design/plan and ignored diagnostic receipts are also in scope.
Runtime fixture2904/312bf952, oracle937/4dd69f7d, ResourceOwner582/bdda89e1,
MigrationTestEnvironment594/ef2627fe, production/reference code, frozen56,
released migrations, Vault, keys, custody, capabilities and DownloadLease remain
byte-exact. No guard exception or dependency/toolchain update.

## Observer composition

Use existing ResourceOwner.with_checkpoint/2; do not add a helper/MTE API.
Add one private lifetime observer and a literal stage projection inside the
owner's NEW Task11 block. Wrap exactly four existing expressions:

| Fixed lifetime | Existing expression |
| --- | --- |
| source | backup_source!(portable_root, :uuid) inside task11_with_source!/2 |
| sentinel | entire outer with_destination(source.lifecycle, fn sentinel -> ... end) in case3192 |
| failed | entire child-destination expression with sentinel.owner |
| restart | entire fresh child-destination expression with sentinel.owner |

Every original expression, callback, assertion, marker and return value remains.
Each wrapper calls its zero-arity function once. No rescue/catch or error
translation. with_checkpoint/2 restores the caller's previous hook in after;
each resource owner captures its own hook at acquisition. Therefore the sentinel
retains its label while nested children use distinct fixed labels.

Capture the existing numeric task11_diagnostic_epoch in the caller closure.
Owner processes must not read the caller's process dictionary. Check the epoch
is an integer before acquisition; do not invent a default epoch. The callback
discards its resource-map argument and projects only literal known stages.
Output ONLY:
task11_fixture=<fixed lifetime> stage=<fixed stage> status=observed elapsed_ms=<integer>
Never inspect/print resource maps, PID/database/path/configuration/error objects,
content, credentials, keys, capabilities or source identities. Unknown stage
shapes produce no observation; they do not catch or suppress native failures.
Preserve ordinary checkpoint error propagation. No new threads, processes,
services, telemetry handlers, shell commands, sleeps, polling or parallelization.

The exact atom/tuple allowlist is in the implementation plan. It distinguishes:
admission; native create/readiness; external extension provisioning; migrations;
destination Repo startup; child drain; native shutdown/connection drain; native
DROP/rest-of-cleanup; parent terminal receipt. Existing close-return markers
also include configuration equality and lifecycle assertions: their tail is not
solely protocol time. No existing after-DROP boundary exists, so that bucket
remains unresolved. Count repeated database_drop_in_use observations offline.

## Verification and limits

Root-only guarded formatter/check, actual SOURCE SPEC then NEW distinct QUALITY
must review the exact reversible observer before Native. This observation does
not alter enforced behavior and is not a behavioral bugfix; no production
contract or required test is replaced. No original assertion may change.
All actors/commands close before any VM/Native/SQL. Preserve exact direct launcher,
source/index/status/frozen pins, toolchain/privatePG identity and ownedBEAM0;
fresh absent/nonsymlink raw, umask077, natural EOF, exact-session empty polls
and commentary only while LIVE, complete safe raw/hash, separate ordinary
postSQL0/EMPTY and closing guard. Never read the known credential log.

First run the single unchanged case3192 through the existing integration route,
seed215378/WAE. Expected selection is one actual case and50 exclusions, not51
passes. This run receives DIAGNOSTIC credit only, whether PASS or FAIL.
Observer IO adds overhead; a focused PASS does not qualify the failed master.
Record reached/missing stages explicitly and preserve every actual failure.
If failed-master context remains unresolved, a separately recorded measured
whole-owner/master invocation may follow only with a concrete evidence question;
do not repeat a master without new measurement or a causal repair.

After measurement, remove only this observer and prove exact archived owner hash
before any behavioral repair or qualification. Keep all historical failures and
raw evidence. A causal repair needs its own bounded design/plan, regression and
independent review. Apply the established Sol/Astra recovery rules; at least
three actual bounded Astra repair attempts are allowed if needed, not counted
from advice/diagnostic attempts.

No native work, migration, crypto, publication, download, fsync, source parking,
reader, identity comparison, snapshot, timeout, input, seed, WAE, concurrency,
pool setting or required coverage may be reduced. No template database, cache,
prewarm, setup_all lift, split test, fake production boundary or acceptance waiver.
All remaining saga/README gates remain required; Task11/Phase5 remain unaccepted.
