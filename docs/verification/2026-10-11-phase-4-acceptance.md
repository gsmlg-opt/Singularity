# Phase 4 versioned sources and organization qualification

## Current status

**IN PROGRESS — NOT ACCEPTED.** E2E is deferred and NOT RUN, not a passing
browser/release gate. Tasks 1, 2, 3 and the early Task 8 restore compatibility
slice are qualified locally after their owning checks and independent SPEC then
QUALITY review. Task 5's pure Query/Page/dispatch slice is qualified, but its
real SQL/cursor work and the remaining Phase 4 deliverables/whole-phase
acceptance are pending.
The active worktree is `.trees/v0.2-phase-4-knowledge-links`, branch
`codex/v0.2-phase-4-knowledge-links`, based on Phase 3 documentation handoff
`617f0b986a3ecffba14c952988e39e3afe022cea`. Phase 3's exact clean tested source
is `35c1f8360dd22b129832a1618b3723032a1983bd`; its complete permitted README
gate and independent reviews are recorded in the
[Phase 3 report](2026-10-09-phase-3-acceptance.md).

Local governance commit `0c78e36a428eb2709444ec9bd5f339e1d29bfdb3` synchronizes
the user's explicit E2E deferral after 31 governance tests, format/compile/xref,
Markdown link checks and independent SPEC then QUALITY review. It changes no
production source, workflow, migration or Vault behavior.

Governing [design](../superpowers/specs/2026-10-11-singularity-v0.2-phase-4-knowledge-links-design.md)
and [plan](../superpowers/plans/2026-10-11-singularity-v0.2-phase-4-knowledge-links.md)
require per-version source sealing, atomic Note source composition, exact
provenance, authenticated organization, Markdown citation export and unchanged
V1/V2 support. Astra's `PROJECT_ARCHITECTURE` advice is architecture evidence,
not implementation acceptance or a consumed repair attempt.

## Task 0 governance and reviewed architecture

Independent `phase4_design_plan_spec` SPEC/feasibility review passed after three
evidence-based clarifications: well-founded lower-revision stored parents before
retention; bounded resource-tag pages beyond the legacy internal 100-row list;
and explicit adapter ownership of only named source constraint modes.
Subsequent `phase4_e2e_policy_quality` QUALITY review passed with no Critical,
Important or Minor findings. This is design evidence, not implementation proof.
The exact v2 tuple encoding is specified for independently constructed HMAC
oracles; it does not change legacy v1 terms.

The active-phase governance test update initially produced **32 tests, four
failures** (`37693`, exit 2, seed `215378`, 1.7 seconds): three expected stale
Phase 3 guidance assertions and one new test's incomplete plan section marker.
Sol repair 1 (`94368`, exit 2, same seed, 2.0 seconds) exposed that the selected
authority section included a command fence forbidden by the existing strict
active-Markdown helper. Sol repair 2 (`19975`, exit 2, same seed, 1.8 seconds)
fixed that narrative boundary but exposed an incomplete design section heading.
All three failed attempts remain failures, not passing RED/GREEN claims.

After two failed Sol repair rounds, `phase4_governance_boundary_repair` used
`SOL_REPEATED_FAILURE` for bounded test-only Astra recovery. It changed exactly
the new test's closing heading to its full literal value; no assertion/helper
was weakened. The first actual Astra repair passed. Cumulative counters for
this test-harness defect are **Sol 2 / Astra 1 PASS**; the initial routing-only
turn made no edits and consumed no repair attempt. These are distinct from
the earlier architecture advice and later implementation repair counters.

After the three active guidance documents were synchronized, full owning
validation `36369` exited 0: **32 tests, zero failures**, seed `215378`,
1.6 seconds. Exact command:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs, test apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 215378
```

Independent handoff/governance SPEC review by `phase4_design_plan_spec` passed:
active Phase 4 guidance retains historical Phase 3 source contracts, runtime
byte guards, negative controls and all activation/publication/Vault limits.
Subsequent handoff QUALITY review by `phase4_e2e_policy_quality` passed with
no findings. Final format/compile/zero-cycle check (`78825`, exit 0), diff
check (`819d87`, exit 0), and local Markdown target scan (`a91732`, exit 0,
42 targets, zero missing) passed. The link scan used Node `fs`/`path` to
resolve `.md` links from all six active guidance/Phase 4 artifact files; it
did not mutate the repository. Static command:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
git diff --check
```

No production source or migration is part of this Task 0 handoff. Task 1's
separately owned test-only RED work is not included in the handoff commit.
The local Task 0 handoff is `5e05d57e83ecb48a3ab72649bf9491f4bf91373f`.

## Task 1 baseline

Session `46915`, exit 0, seed `215378`, at governance source `0c78e36...`:
Core **30 tests plus 2 properties**, Domains **14 tests**, Runtime **5 tests**,
all zero failures (0.8/0.6/0.1 seconds respectively). Integration was excluded
by the established default and is not counted as executed. Exact command:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_core/test/singularity/core/note_values_test.exs apps/singularity_core/test/singularity/core/knowledge_link_values_test.exs apps/singularity_domains/test/singularity/domains/notes_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutation_fingerprint_test.exs --seed 215378
```

## Task 1 source-intent RED and implementation validation

The worker wrote tests before production, using real constructors and the
existing Domains fake only to observe intent/absence of dispatch. Parent
`40081` exited 2, seed `215378`: Core **44 tests plus 2 properties, 14
failures**; Domains **17 tests, 3 failures**; Runtime **11 tests, 6 failures**.
All **23 new failures** were the intended missing source constructors/fields,
ignored source validation, or source-command rejection. The original 51
baseline cases continued passing. No compilation/fixture error masked that RED.

The first implementation validation (`7883`, exit 2, same seed) passed all
17 Domains and 11 Runtime cases, including independent literal v1/v2 HMAC
oracles, and all nine strict reference-constructor contracts. Core retained
four failures in positive snapshot-source cases (44 tests plus 2 properties).
Compilation also reported deprecated `Tuple.append/2` in the new v2 builder.
This is **FAIL**, not acceptance; bounded Sol repair 1 entered root-cause
diagnosis with unchanged tests and no timeout/assertion waiver.

Sol repair 1 traced those four positive fixtures to generated uppercase
hexadecimal UUID suffixes and fragments. The real strict constructors correctly
rejected them. Parent probe `794286`, exit 0, confirmed `Integer.to_string`
base-16 outputs `"1F5"`, `"3E9"`, and `"A"` for 501, 1001, and 10:

```sh
devenv shell -- elixir -e 'IO.inspect({Integer.to_string(501, 16), Integer.to_string(1001, 16), Integer.to_string(10, 16)}, label: "source fixture hex probe")'
```

The authorized fixture repair lowercases exactly the two generated hex helpers
before padding; every assertion and source bound stays unchanged. The v2 builder
uses nondeprecated `:erlang.append_element/2` instead of `Tuple.append/2`,
preserving the literal encoded term. No validator was relaxed.

Exact parent RED command:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_core/test/singularity/core/note_source_references_test.exs apps/singularity_core/test/singularity/core/note_values_test.exs apps/singularity_domains/test/singularity/domains/notes_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutation_fingerprint_test.exs, test apps/singularity_core/test/singularity/core/note_source_references_test.exs apps/singularity_core/test/singularity/core/note_values_test.exs apps/singularity_core/test/singularity/core/knowledge_link_values_test.exs apps/singularity_domains/test/singularity/domains/notes_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutation_fingerprint_test.exs --seed 215378
```

The first implementation command uses the same five owning files and seed,
with the six new/changed production files also passed to `mix format`.
No storage SQL, runtime client whitelist/grant, schema, Vault, E2E,
publication or production-data behavior changed in this pure-intent slice.

## Task 1 qualified slice

Parent GREEN `9493` exited 0, seed `215378`: Core **44 tests plus 2
properties**, Domains **17 tests**, Runtime **11 tests** — all **74 cases
passed** (1.1/5.1/0.5 seconds), without the deprecated tuple warning.
Cumulative Task 1 repair counters: **Sol 1 PASS / Astra 0**. Exact command:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_domains/lib/singularity/domains/notes/command.ex apps/singularity_core/test/singularity/core/note_values_test.exs, test apps/singularity_core/test/singularity/core/note_source_references_test.exs apps/singularity_core/test/singularity/core/note_values_test.exs apps/singularity_core/test/singularity/core/knowledge_link_values_test.exs apps/singularity_domains/test/singularity/domains/notes_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutation_fingerprint_test.exs --seed 215378
```

Static `99196` exited 0: full formatter check, compilation with warnings as
errors, and xref **zero cycles**. Additional existing Runtime/architecture
regressions `60758` exited 0: **27 Runtime + 32 Web tests**, zero failures,
same seed (0.9/2.1 seconds). Integration remained excluded, not executed.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/note_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs apps/singularity_runtime/test/singularity/runtime/note_observability_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --seed 215378
```

Independent `phase4_design_plan_spec` SPEC review passed, followed by separate
`phase4_e2e_policy_quality` QUALITY review: no required or Critical/Important/
Minor findings. Both read the actual six production/four test files; neither
mutated the checkout or claimed test-double behavior as live SQL proof.
Task 1 implements only canonical references, snapshot intent and fingerprints.
SQL sealing, authenticated composition and whole-phase acceptance remain pending.
The local Task 1 implementation commit is
`48bd434` (`feat(notes): model versioned source intent`).

## Task 2 fixture compatibility preparation

Read-only `phase4_links_storage_investigation` mapped the released schema/link,
privacy and unsupported-backup fixtures that append after committing a Note.
The plan now requires same-connection atomic construction while preserving all
existing constraint, replay, privacy and backup assertions. The oversized-reader
case remains real SQL with 101 rows and an unchanged rejection assertion inside
a deliberately rolled-back unsealed transaction; a separate contract checks
oversized commit rejection. No constraint disabling or fake database is used.
The necessary existing restore oracle inventory synchronization is recorded in
Task 8, not a V1/V2 wire-format or cryptographic change.
Independent `phase4_design_plan_spec` SPEC review of this bounded amendment
passed, followed by separate `phase4_e2e_policy_quality` QUALITY PASS with no
findings. These are plan reviews only; source-seal behavior is not yet proved.

This phase's owned PostgreSQL cluster is
`.devenv/phase4-pg.2P68Dm`, private socket
`/tmp/singularity-phase4-socket.GufHo0`, port `5432`, with TCP listening disabled.
Initialization `11965` and established test-only role bootstrap `26725` exited 0.
The ignored command harness verifies the exact data directory/listen identity
and stops only its own cluster in EXIT cleanup. It does not borrow another
worktree's database or change production roles/data.

Task 2 pre-change characterization `72408` exited 0, seed `215378`:
**57 integration tests, zero failures**, 34.8 seconds, across the complete
schema/link/RLS/privacy/exporter/migration owning suites. The generated database
was `singularity_test_b437e6249632de03ea08d3b2`; its temporary root was
`/tmp/singularity/integration/b437e6249632de03ea08d3b2`. The harness stopped its
owned server at exit. Expected negative-constraint disconnect logs are not
test failures. Exact command:

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_schema_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/knowledge_privacy_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/knowledge_migration_test.exs --seed 215378
```

## Task 2 initial RED and harness diagnosis

Two Sol implementers prepared tests/support fixtures before production edits:
21 new real PostgreSQL sealing/retention contracts, plus atomic construction in
the five established fixture/test files. Existing RLS fixtures were already
atomic and remain unchanged. Parent format/compile `87707` exited 0 with
warnings as errors, also checking separately owned Task 8 test-tooling changes.

Initial `94616` exited 2, seed `215378`: **78 tests, 22 failures**, 50.6 seconds.
The revised committed-citation append contract failed because old SQL still
accepted it; the other **56 established cases passed**, including the real
101-row reader rejection, publication barrier, privacy canaries and unsupported
backup rejection. New tests observed accepted empty/nonempty/concurrent appends,
accepted self ancestry and union overflow, absent seals/finalizers/migration,
and rejected historical retention. These are genuine missing behavior.

However, this run also contains **two unexpected new fixture defects**, not
valid missing-feature RED evidence: the reverse-parent test omitted the resource
row required by an immediate established FK, and the isolated empty-set adapter
test omitted necessary temporary test-only link read permissions, returning
`forbidden`. Production implementation remains held while bounded Sol harness
repair 1 fixes those setups without changing assertions, constraints, production
grants or seal write privileges. Neither defect is declared passing.

Harness repair 1 created the containing resource before inserting a child-first
version sequence, and temporarily granted only the missing web SELECT rights
on the three existing source tables, restoring exactly prior privileges. The
test now directly asserts its deliberate rollback error instead of a wrapper
that masked other errors. All enforced assertions and established FKs remain.
Parent repaired RED `2359` exited 2, same seed: **21 tests, 21 expected missing-
feature failures**, 16.1 seconds. Both corrected constructions now reach their
intended absent-seal assertions; neither original fixture defect remains.
The real invisible-append transaction still commits when it should be rejected.
Counters: **Sol harness repair 1 PASS, zero failed harness repair rounds;
production repairs 0; Astra 0**. SQL implementation may now start, not acceptance.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix do format apps/singularity_storage/test/singularity/storage/note_source_set_sealing_test.exs, singularity.test.integration apps/singularity_storage/test/singularity/storage/note_source_set_sealing_test.exs --seed 215378
```

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/note_source_set_sealing_test.exs apps/singularity_storage/test/singularity/storage/knowledge_schema_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/knowledge_privacy_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/knowledge_migration_test.exs --seed 215378
```

## Task 8 early restore characterization

Before adding derived-seal checks, `27089` exited 0, seed `215378`: the three
complete owning restore suites reported **17 cases, 4 excluded — 13 integration
cases executed**, zero failures, 8.2 seconds. Unit `28044` exited 0: **17 cases,
13 excluded — 4 unit cases executed**, zero failures, 2.8 seconds. Thus all
17 original cases were characterized; excluded cases are never counted as run.
The integration database/root were
`singularity_test_f07aefbf6527bae2153a5352` and
`/tmp/singularity/integration/f07aefbf6527bae2153a5352`; the owned server stopped.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs --seed 215378
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs --seed 215378
```

Parent prepared a real table-lock barrier regression, exact six-version restored
empty-seal assertions, immutable three-version Note-sentinel seals through the
existing rewrap oracle, and nine-version source/destination seal equality in the
full Runtime V1/V2 oracle. Only derived Note inventory/assertions changed; every
existing password/crypto/canonical assertion remains. These test/tooling checks
are pending the Task 2 schema; production Restorer is still unchanged. Its
future minimal destination-inventory patch remains separately reported/reviewed.
Independent `phase4_design_plan_spec` SPEC review passed for this early
three-file test preparation. It explicitly verified the real lock barrier,
committed Note-only sentinel snapshot, exact seal counts/identity and preserved
original assertions; it did not claim SQL behavior or Task 8 completion.
Preparation QUALITY review then failed with one Important finding: an await
timeout (an exit) or holder-transaction commit failure could leave the linked
restore task running during destination cleanup. Parent verified the actual
code and applied review fix 1: spawn a known bounded-start task, wrap the whole
holder transaction, await and assertions in outer `try/after`, and shut down
that task before destination reset/delete. The original lock assertions and
wait bounds remain unchanged. Fresh preparation SPEC recheck passed, followed
by QUALITY re-review PASS with no remaining findings. Review fix 1 is qualified
for test preparation only; actual restore runtime validation and Task 8
acceptance remain pending. This initial review failure was not treated as a
passing gate or an Astra recovery attempt.

## Task 2 first implementation validation

Sol implemented the forward-only seal migration and seal-aware adapter, adding
one further real adapter retention contract (22 new sealing cases in total).
The parent static check `68277` exited 0: the four selected changed Elixir files
formatted, compilation with warnings as errors passed, and xref found zero
cycles. No released migration was edited. Real SQL, concurrency and full owning
suite validation remained pending; this static result is not Task 2 acceptance.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_storage/priv/repo/migrations/20261011000000_seal_note_source_sets.exs apps/singularity_storage/lib/singularity/storage/postgres/knowledge_link_repository.ex apps/singularity_storage/test/singularity/storage/note_source_set_sealing_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
```

First implementation integration `97654` exited 2, seed `215378`: **79 tests,
one failure**, 85.1 seconds. All 22 new sealing cases passed, but the established
cross-owner RLS INSERT assertion received `check_violation` instead of the
required `insufficient_privilege`: the privileged visible-seal BEFORE trigger
masked row-security rejection on an already committed Note. This complete gate
is FAIL, not qualified acceptance. Bounded Sol production repair 1 must restore
the authenticated denial boundary without changing the original RLS assertion
or bypassing seal enforcement. Production failed repair rounds remain zero;
Astra attempts remain zero. The generated database/root were
`singularity_test_090c9d36f4cb0e0fe2374159` and
`/tmp/singularity/integration/090c9d36f4cb0e0fe2374159`; the owned server stopped.

Sol production repair 1 added an authorization-aware seal check and an extra
real nondisclosure regression without changing the original RLS test or grants.
Parent `56816` included the full migration-history suite and exited 2:
**115 tests, 66 failures**, 110.9 seconds, same seed. Root failure: the new
SECURITY DEFINER guard called the established authorization function as table
owner, which deliberately lacks its EXECUTE privilege. Splitting a Boolean
expression alone would not solve that runtime boundary. A child race task then
accessed a missing constraint key on the unexpected SQL error, causing a linked
exit, leaked test repository and cascading `already_started` fixture failures.
These cascading failures are recorded, not treated as separate missing features.

Bounded Sol production repair 2 must preserve native RLS nondisclosure without
changing authorization grants/policies, and make the race's unexpected-error
diagnostics safe while retaining its exact expected constraint assertion. The
parent also addressed the SPEC review's independent lifecycle finding in the
legacy publication race: both task lifetimes now have unconditional shutdown
covering handshakes, bounded lock checks, await and assertions. All original
assertions and wait bounds remain. The full source review is held, not PASS.
Counters: **failed Sol production repair rounds 1; Astra 0**. If repair 2 fails,
the next implementation recovery must use `SOL_REPEATED_FAILURE` Astra with
at least three bounded attempts available. Database/root:
`singularity_test_2ea1c33281566833f79051ab` and
`/tmp/singularity/integration/2ea1c33281566833f79051ab`; the owned server stopped.

Sol repair 2 changes only the new read-only BEFORE guard to SECURITY INVOKER:
its exact Note/version/owner/private seal lookup uses the caller's existing
SELECT grant and forced RLS. Native child RLS denies unauthorized web rows;
excluded roles still lack seal SELECT. All privileged write/provenance/parent
finalizers remain hardened SECURITY DEFINER. No existing authorization function,
grant, policy, role membership or capability is changed. The original security
regressions remain, with exact function owner/security/search-path/ACL assertions
added. Both new race tasks now return unexpected SQL/error/exit outcomes safely,
including an optional constraint lookup, and shut down unconditionally; the
required exact consistency-error assertion and existing time bounds remain.
Fresh real SQL/history validation is pending. Independent SPEC source mapping
found no further gap but correctly holds its final verdict for that gate.

Parent repair-2 gate `82416` exited 2: **115 tests, one failure**, 97.6 seconds,
same seed. The other 114 cases passed, including original RLS and concurrency
contracts. The remaining failure is the added function-catalog assertion:
binding a signature string directly to `$1::regprocedure` selects Postgrex's
integer OID codec. It does not invalidate the assertion or qualify the complete
gate. No leaked-repository cascade recurred. Database/root:
`singularity_test_fa8b9e34329aca494ad5ec61` and
`/tmp/singularity/integration/fa8b9e34329aca494ad5ec61`; the owned server stopped.

Two successive Sol qualification-repair rounds have failed, so parent routed
the bounded catalog-query encoding recovery to
`phase4_source_seal_catalog_recovery` Astra under `SOL_REPEATED_FAILURE`,
attempt 1. At least three bounded attempts remain available if needed. Only
the new test's query binding may change; every owner/security/search-path/ACL
assertion and the complete SQL/history rerun remains required. No production
or authorization change is requested for this recovery.

Astra recovery attempt 1 verified the supplied failing command/error against
the local Postgrex integer-only OID encoder and changed exactly one binding to
`$1::text::regprocedure`. The complete catalog assertion is unchanged, as are
all production files and existing test edits. Source/diff checks passed; parent
fresh full SQL/history execution is pending. This is bounded implementation
recovery, not Astra routine review or a passing test claim.

Parent Astra-1 GREEN `20944` exited 0, seed `215378`: **115 tests, zero
failures**, 98.8 seconds. This includes all **23** new sealing cases, all **57**
established owning cases and **35** full migration-environment/history cases.
No task/repository cascade recurred. Exact command:

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix do format apps/singularity_storage/test/singularity/storage/note_source_set_sealing_test.exs, singularity.test.integration apps/singularity_storage/test/singularity/storage/note_source_set_sealing_test.exs apps/singularity_storage/test/singularity/storage/knowledge_schema_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/knowledge_privacy_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_exporter_test.exs apps/singularity_storage/test/singularity/storage/knowledge_migration_test.exs apps/singularity_storage/test/singularity/storage/migrations_test.exs --seed 215378
```

Counters: Sol harness repair 1 PASS; two failed Sol qualification-repair rounds;
**Astra recovery 1 PASS**, zero failed Astra rounds. Database/root:
`singularity_test_3e7fc4692614cdd3f72a20e3` and
`/tmp/singularity/integration/3e7fc4692614cdd3f72a20e3`; the owned server stopped
and temporary root absence was verified. `git diff --check` passed. Final
static `47326` exited 0: complete formatter check, compilation with warnings as
errors and xref zero cycles. Independent `phase4_source_seal_spec` reviewed the
actual eight-file Task 2 candidate after repair and returned SPEC PASS with no
findings. Separate `phase4_source_seal_quality` then returned QUALITY PASS,
with no Critical, Important or Minor findings. Task 2 is qualified locally;
authenticated Note composition, runtime activation and whole-phase acceptance
remain pending. This reviewed slice changes no Vault production file or feature.
Local implementation commit: `2012526940ba68f43892467fffeafdabb4f72161`
(`feat(storage): seal note version sources`), containing only the eight reviewed
implementation/test/support files plus this report and Task 2 plan checklist.
The separately owned four Task 8 files remain uncommitted at this checkpoint.

## Task 8 observed restore RED and compatibility patch

After the seal schema existed, focused `40015` exited 2, seed `215378`: **12
reported cases, 11 excluded — one actual case executed and failed**, 5.3 seconds.
The real restore task never waited for the derived seal table's ACCESS EXCLUSIVE
lock while the holder retained ACCESS SHARE; the bounded actual `pg_locks` /
`pg_blocking_pids` assertion failed as designed. This is a genuine missing-lock
RED, not a fake restore or a missing-schema fixture error. Task cleanup completed
and the owned server stopped. Database/root:
`singularity_test_67dcb585f0316cd3b1110729` and
`/tmp/singularity/integration/67dcb585f0316cd3b1110729`.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs:264 --seed 215378
```

The parent applied the plan's smallest frozen-substrate compatibility patch:
`backup/restorer.ex` adds `content.note_source_set_seals` only to the derived
destination inventory used by pre-restore locking and emptiness checks. It does
not add seals to post-restore excluded data, because legitimate Note INSERT
finalizers regenerate them. No wire columns, V1/V2 schema/export, cryptographic
or Vault unlock/key/recovery behavior changed. Full owning restore suites and
the complete independent Runtime V1/V2 oracle remain required.

First implementation `13434` exited 0 after compiling with warnings as errors:
**18 reported cases, 4 excluded — 14 integration cases executed**, zero
failures, 12.6 seconds, seed `215378`, across all three complete owning files.
The actual seal-lock barrier and exact restored/rewrapped seal checks passed.
Database/root: `singularity_test_423df3a94abc1d1ec5f0819d` and
`/tmp/singularity/integration/423df3a94abc1d1ec5f0819d`; the owned server stopped.
Unit/static `16401` also exited 0: **18 reported cases, 14 excluded — four unit
cases executed**, zero failures, 2.7 seconds, same seed. Complete formatter
check, warnings-as-errors compile and xref zero cycles passed in that command.
All 17 original owning cases plus the new lock contract have now run across
integration and unit scopes; no excluded case is counted as executed. Full
Runtime oracle and implementation SPEC then QUALITY review remain pending;
Task 8 is not accepted yet.

Full independent Runtime V1/V2 oracle `57792` exited 0 using the exact owned
cluster. It completed encrypted backup, V2 restore, authenticated access/search
and canonical/byte/crypto comparisons, plus the established V1 destination
compatibility branch. Exact regenerated seal identity/private/count assertions
covered all nine source and destination Note versions; original assertions
remained. Expected repeated migration-module definition and enum-OID refresh
diagnostics do not change this successful terminal result. This oracle is not
browser/E2E or production activation proof.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.restore
```

Allocated databases/roots:

- `singularity_test_52c269ab39bb7adcdaa1f511`,
  `/tmp/singularity/integration/52c269ab39bb7adcdaa1f511` (source).
- `singularity_test_56c3b836240b74484baba74b`,
  `/tmp/singularity/integration/56c3b836240b74484baba74b` (V2 destination).
- `singularity_test_02a51592d3b341869fa84f8b`,
  `/tmp/singularity/integration/02a51592d3b341869fa84f8b` (V1 destination).

The owned server stopped. Final cleanup `25621` confirmed zero generated test
databases in that cluster; all five Task 8 integration/oracle roots above were
absent. Fresh `phase4_source_seal_spec` implementation SPEC review passed with
no findings on the actual four-file candidate against `2012526`. Separate
`phase4_source_seal_quality` then returned QUALITY PASS with no Critical,
Important or Minor findings, including fresh/pending/replay inventory paths,
task cleanup and preserved original assertions. Task 8 is qualified locally
at this schema checkpoint, with zero production repair rounds/Astra attempts;
prior test-preparation review fix 1 was recorded above. Relevant full restore
checks remain required after later Note composition changes and at whole-phase
acceptance. The only frozen-substrate production patch is the explicitly
reported derived destination inventory addition, not Vault feature work.
Local compatibility commit: `46be8193e13ec50eb705ed19123537d3f735e5e1`
(`fix(backup): regenerate note source seals`), containing the four reviewed
files plus this report and Task 8 checklist; the worker's separate new Task 3
test was preserved untracked and not staged.

## Task 3 pre-change characterization

While a Sol worker prepares only the new source-composition test file, parent
`3517` exited 0 on the complete existing Note repository/concurrency/rollback
owning suites: **28 tests, zero failures**, 34.2 seconds, seed `215378`.
Note composition production code is still unchanged. The generated database/root
were `singularity_test_5051e4813236000675a572b0` and
`/tmp/singularity/integration/5051e4813236000675a572b0`; the owned server stopped.
This is characterization, not new source inheritance/lock protocol acceptance.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs apps/singularity_storage/test/singularity/storage/note_mutation_concurrency_test.exs apps/singularity_storage/test/singularity/storage/note_mutation_rollback_test.exs --seed 215378
```

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix do format apps/singularity_storage/lib/singularity/storage/backup/restorer.ex, compile --warnings-as-errors, singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs --seed 215378
```

## Task 3 test-harness preparation

The Sol worker prepared 29 new real integration cases before production edits.
Parent `93018` exited 1 during formatting: a missing outer map delimiter in
the new `DocumentFragment.new` fixture caused `MismatchedDelimiterError`.
Compilation and tests did not run, so this attempt is a failed static/harness
check, not semantic RED. The owned PostgreSQL server stopped; no integration
database was allocated. Test-only Sol fixture repair 1 closed the missing map
and corrected one target helper's `version_id` shape; no assertion changed.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix do format apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs, compile --warnings-as-errors, singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs --seed 215378
```

The same command's repaired attempt `4569` passed formatting/compilation but
exited 2: **29 integration tests, 29 failures**, 33.1 seconds, seed `215378`.
Sixteen failures reached intended missing-source behavior (empty inherited
membership, rejected explicit collections or early actual race outcomes).
Thirteen failed before their behavior assertions because the new exact-state
helper named nonexistent `content.search_documents`; the real Phase 3 table
is `content.search_entries`. Those thirteen are invalid harness failures,
not missing-feature RED. Test-only Sol fixture repair 2 corrects the inventory
name while preserving every exact row/effect assertion. Production remains
unchanged; Task 3 Astra attempts remain zero. Database/root:
`singularity_test_3094f13535311835dc697618` and
`/tmp/singularity/integration/3094f13535311835dc697618`; the owned server stopped
and root absence was verified. One validated Sol harness repair has failed to
fully qualify the harness so far; the initial static failure is recorded
separately above.

Sol fixture repair 2 changed only the actual table name. Fresh `54329` ran
the same complete new suite after formatting and warnings-as-errors compile:
**29 tests, 16 expected missing-feature failures**, exit 2, 27.3 seconds,
seed `215378`. All thirteen former inventory failures now passed; no fixture
SQL failure or linked-task/repository cascade remained. The sixteen failures
are exact inherited membership absence, rejected explicit create/clear/replace/
merge collections and actual source race operations ending before their required
barriers. This qualifies semantic RED, not implementation acceptance.
Database/root: `singularity_test_14e4ab6a5d1ff3885772c211` and
`/tmp/singularity/integration/14e4ab6a5d1ff3885772c211`; the owned server stopped
and root absence was verified. Stage 2 production implementation is now
authorized. Counters: two Sol harness repair attempts, one unsuccessful
validated round followed by repair 2 PASS; production repair rounds 0,
Astra attempts 0.

Read-only `phase4_runtime_source_mapping` also mapped later Task 4 composition.
Existing all-of capabilities and the authorization lock support target checks
without changing OperationScope or Vault. Existing search resolution is
live-only and citation set reads hydrate fragment text too early for selected
source authorization. Task 4 therefore needs narrow scoped stored-reference
selection followed by exact historical typed metadata hydration only after
current target read authority, preserving pins and deletion status without
binary delivery or current-head substitution. Necessary adapter/DTO/registration
test inventory is recorded in the plan; this mapping is not test or review
acceptance.

Task 3's implementation inspection identified a necessary plan correction:
`Core.NoteSourceSet.new/1` validates full `DocumentFragment.text`, conflicting
with metadata-only retained copying if used unchanged in the mutation seam.
The plan now names strict canonical reference reconstruction plus derived
`NoteAttachment`/`NoteCitation` rows, real locked typed/fragment/locator witnesses,
resolved bounds and independent SQL provenance/parent/retention/seal constraints.
The existing full-text constructor and standalone adapter remain unchanged;
no forged Core struct or waived validation is authorized. Independent review
of this bounded clarification remains required, separate from implementation
qualification. Task 4 selected-source clarification received independent
`phase4_runtime_source_plan_spec` SPEC PASS before this additional amendment.
The same reviewer then performed fresh combined Task 3/4 clarification SPEC
review and returned PASS with no findings. Separate
`phase4_source_seal_quality` QUALITY review followed and passed with no
Critical, Important or Minor findings. These reviews cover documentation and
feasibility only, excluding the worker's mutable production candidate; all
implementation checks and reviews remain pending.

## Task 3 first implementation and receipt diagnosis

First implementation `69040` passed formatting/compilation but exited 2:
**72 integration tests, four failures**, 36.7 seconds, seed `215378`.
One new changed-source receipt case returned invalid rather than the design's
conflict. Three original Note repository cases returned not-found rather than
their established invalid lineage classification: a same-owner base from
another Note, a mismatched competing version and a same-owner conflict from
another Note. All failures remain FAIL; this is not accepted implementation.
Database/root: `singularity_test_a7a93a55f036f959d9330ec2` and
`/tmp/singularity/integration/a7a93a55f036f959d9330ec2`; the owned server stopped
and root absence was verified. Exact command:

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix do format apps/singularity_storage/lib/singularity/storage/postgres/note_sources.ex apps/singularity_storage/lib/singularity/storage/postgres/note_repository.ex apps/singularity_storage/lib/singularity/storage/postgres/knowledge_link_repository.ex apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs, compile --warnings-as-errors, singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs apps/singularity_storage/test/singularity/storage/note_mutation_concurrency_test.exs apps/singularity_storage/test/singularity/storage/note_mutation_rollback_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs --seed 215378
```

Read-only Sol diagnosis found exact-parent source lookup preceding established
aggregate lineage checks, masking their error classification. The recommended
repair performs nonlocking aggregate-input preflight inside the winning receipt
callback and retains all original post-ordered-lock checks. The unchanged
`NoteMutationReceipts.replay/2` also intentionally classified fingerprint
mismatch as invalid. A necessary explicit contract amendment now distinguishes
same authenticated receipt/operation/resource fingerprint conflict from still-
invalid structural operation/resource mismatches, retaining key/HMAC/result/
integrity semantics and strengthening unchanged-row/effect/precedence tests.
Complete unchanged receipt characterization, test RED and independent amendment
review are required before this production repair; repair rounds remain zero
at this diagnostic checkpoint.

Command `70557` exited 0 but only actually ran Core **15 tests + two properties**
and Domains **one test**, zero failures, seed `215378` (1.1/0.1 seconds).
It incorrectly combined `mix do test ..., singularity.test.integration ...`
in one VM: the already-run Mix test task produced no integration ExUnit output.
The requested receipt suite is therefore **NOT RUN**, not a passing baseline,
and is being rerun in a separate Mix invocation. It allocated database/root
`singularity_test_023567877c60d15216a86783` /
`/tmp/singularity/integration/023567877c60d15216a86783`; the owned server stopped.
This was command composition error, not a receipt implementation result.
Separate actual baseline `36949` exited 0: complete unchanged receipt suite
**eight integration tests, zero failures**, 1.5 seconds, seed `215378`.
Database/root: `singularity_test_d8a7d7b4967717bc3ecae121` and
`/tmp/singularity/integration/d8a7d7b4967717bc3ecae121`; the owned server stopped.
Both characterization roots above were confirmed absent. Exact command:

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs --seed 215378
```

Test-only preparation retained all eight original receipt cases and added one
combined-mismatch precedence case, explicitly distinguishing fingerprint-only
conflict from structural invalid. Every rejected attempt now checks exact
unchanged row JSON/timestamps across 13 canonical/source/seal/receipt/projection/
audit/outbox/job tables and receipt count, retaining callback-bypass assertions.
Actual RED `59698` exited 2: **nine tests, one expected fingerprint-only
classification failure**, 2.0 seconds, seed `215378`; all structural and
combined-mismatch controls passed. Database/root:
`singularity_test_4923effc840bb7a4ea8d24c6` and
`/tmp/singularity/integration/4923effc840bb7a4ea8d24c6`; the owned server stopped
and root absence was verified. The command formats the amended receipt test
then runs its complete integration suite in a fresh Mix invocation.
Independent `phase4_runtime_source_plan_spec` SPEC review of the receipt/preflight
and Task 5 pure-contract detail amendment passed, followed by separate
`phase4_source_seal_quality` QUALITY PASS with no findings. These are plan
reviews, not source acceptance. Task 3 production Sol repair round 1 is now
in progress; failed production repair rounds 0 and Astra attempts 0 at this
checkpoint. The initial failing implementation remains separately recorded.

### Task 3 repaired integration GREEN

Production Sol repair round 1 preserved every post-lock aggregate check and
added only nonlocking input preflight inside the winning receipt callback.
Receipt replay now classifies fingerprint-only mismatch as nonretryable
conflict after operation/resource checks; combined mismatches remain invalid.
Tests were unchanged after their qualified RED.

Fresh parent `31344` exited 0: formatting and warnings-as-errors compilation
passed, then **81 integration tests, zero failures**, 41.2 seconds, seed
`215378`. This includes all 29 new source cases and the complete Note
repository, concurrency, rollback, knowledge-link and nine-case receipt
suites. Database/root: `singularity_test_5c24e980b52b7aedf5062c47` /
`/tmp/singularity/integration/5c24e980b52b7aedf5062c47`; the owned server
stopped and root absence was verified. Counters: production Sol repair
round 1 PASS, zero failed production repair rounds, Astra attempts zero.
Broader seal/RLS/privacy/deadline/restore checks and actual SPEC then QUALITY
reviews remain pending; this is not complete Task 3 acceptance.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix do format apps/singularity_core/lib/singularity/core/organization_page_query.ex apps/singularity_storage/lib/singularity/storage/postgres/note_sources.ex apps/singularity_storage/lib/singularity/storage/postgres/note_repository.ex apps/singularity_storage/lib/singularity/storage/postgres/knowledge_link_repository.ex apps/singularity_storage/lib/singularity/storage/postgres/note_mutation_receipts.ex apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs, compile --warnings-as-errors, singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs apps/singularity_storage/test/singularity/storage/note_mutation_concurrency_test.exs apps/singularity_storage/test/singularity/storage/note_mutation_rollback_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs --seed 215378
```

Actual six-file `phase4_task3_actual_spec_review` returned SPEC FAIL with one
P2 finding: replay compared fingerprints before validating its completed
result. A real `state='completed', outcome=NULL` row is legally admitted by
the released CHECK's SQL NULL semantics; exact replay returns invalid but
changed fingerprint incorrectly masks that malformed result as conflict.
No other actionable production defect was found. Ordered locks, immutable
metadata composition and new real race Task cleanup were reviewed; this
does not waive the receipt finding. Add a real SQL regression before moving
the comparison after completed-result validation. Do not alter the released
migration. The unchanged legacy receipt concurrent-claim test's absent
explicit `after` cleanup is recorded as a pre-existing limitation, not a
new source-race regression. Fresh SPEC and separate QUALITY remain required.

The implementer added one real scoped SQL regression, retaining the previous
nine receipt cases. Fresh `36414` exited 2: **ten tests, one expected
malformed-completed fingerprint precedence failure**, 2.6 seconds, seed
`215378`. Exact replay and every structural/combined mismatch control
passed before the changed-fingerprint assertion. Every callback must remain
bypassed; exact 13-table rows/timestamps/counts remain unchanged. Database/root:
`singularity_test_edd469ef083db18ac0718e8b` /
`/tmp/singularity/integration/edd469ef083db18ac0718e8b`; server stopped and
root absence verified. This is qualified semantic RED, not a fixture failure.
Parent then moved only fingerprint comparison after completed-result
reconstruction/validation; no migration, schema, secret, key or claim change.
Extended integration and fresh actual reviews remain pending.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs --seed 215378
```

### Task 3 qualified local source composition

After the review-driven order fix, fresh `80035` exited 0 and passed
formatting/warnings-as-errors compilation. Storage reported **151 tests,
four excluded, zero failures** (147 actually executed), 75.1 seconds;
Runtime's complete unchanged search privacy/fixed-deadline suite executed
**eight tests, zero failures**, 10.4 seconds, seed `215378`.
The 155 actual cases include all six source/Note/receipt owning suites
(receipt now ten cases), schema/RLS/privacy/concurrency/projection checks,
complete restore fixtures, and the unchanged Tag/Relationship/RLS baseline
of 20 cases. Expected PostgreSQL constraint errors from negative assertions
are not test failures.

This command contained one mistyped sealing path under `postgres/`; warnings
explicitly reported that path unmatched. That suite was **NOT RUN**, despite
the command's exit 0; it is not included in the 155 executed cases or claimed
passing from that invocation. The corrected standalone command `22780`
then actually executed the full sealing suite: **23 tests, zero failures**,
20.3 seconds, seed `215378`, exit 0. Thus all required scoped suites were
eventually executed; no assertion or check was skipped.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix do format apps/singularity_storage/lib/singularity/storage/postgres/note_mutation_receipts.ex, compile --warnings-as-errors, singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_repository_test.exs apps/singularity_storage/test/singularity/storage/note_mutation_concurrency_test.exs apps/singularity_storage/test/singularity/storage/note_mutation_rollback_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_source_set_sealing_test.exs apps/singularity_storage/test/singularity/storage/knowledge_schema_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/knowledge_privacy_test.exs apps/singularity_storage/test/singularity/storage/knowledge_concurrency_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_projection_reconciler_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_search_privacy_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs apps/singularity_storage/test/singularity/storage/postgres/tag_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/relationship_repository_test.exs --seed 215378
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/note_source_set_sealing_test.exs --seed 215378
```

Fresh full `3091` ran `mix singularity.test.restore` with no scoped arguments,
exit 0: complete original V1/V2 crypto/canonical/original-byte/search assertions
and the committed exact nine-derived-seal assertions remained intact.
Source / V2 / V1 databases respectively:
`singularity_test_c27e46129d2a31e388809783`,
`singularity_test_39ed568bd25a47d434bd4be9`,
`singularity_test_ab76cc1c62bd2d2d09dbdee2`.
The oracle's existing migration-module redefinition and expected Postgrex type
reload messages are nonfailing runtime warnings, not a failed static compilation.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.restore
```

Static/unit `8289` exited 0: exact twelve frozen Task 3 and Task 5 pure files'
format checks, warnings-as-errors compilation and **zero xref cycles** passed.
Core 37 tests + two properties, Domains 12 tests, and four actual backup unit
cases passed (Storage reported 15, eleven integration cases excluded): **55
actually executed cases**, seed `215378`, 1.0/0.4/2.5 seconds. This is a
scoped format check while unrelated Task 5 test drafts were in progress, not
the later whole-phase README gate.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix do format --check-formatted apps/singularity_storage/lib/singularity/storage/postgres/note_sources.ex apps/singularity_storage/lib/singularity/storage/postgres/note_repository.ex apps/singularity_storage/lib/singularity/storage/postgres/knowledge_link_repository.ex apps/singularity_storage/lib/singularity/storage/postgres/note_mutation_receipts.ex apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs apps/singularity_core/lib/singularity/core/organization_page_query.ex apps/singularity_core/lib/singularity/core/organization_page.ex apps/singularity_domains/lib/singularity/domains/organization.ex apps/singularity_core/test/singularity/core/organization_page_query_test.exs apps/singularity_core/test/singularity/core/organization_page_test.exs apps/singularity_domains/test/singularity/domains/organization_test.exs, compile --warnings-as-errors, test apps/singularity_core/test/singularity/core/organization_page_query_test.exs apps/singularity_core/test/singularity/core/organization_page_test.exs apps/singularity_core/test/singularity/core/knowledge_link_values_test.exs apps/singularity_domains/test/singularity/domains/knowledge_ports_test.exs apps/singularity_domains/test/singularity/domains/organization_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_import_test.exs apps/singularity_storage/test/singularity/storage/backup/restore_rewrap_test.exs --seed 215378, xref graph --format cycles --fail-above 0
```

Fresh actual six-file SPEC follow-up `phase4_task3_actual_spec_review` passed
with the receipt finding resolved. Separate `phase4_task3_actual_quality_review`
then returned QUALITY PASS: zero Critical/Important/Minor findings. These are
actual production/test reviews, not only design reviews. Counters: initial
implementation failed as recorded above; production repair 1 PASS, narrow
review-follow-up repair PASS, zero failed completed production repair rounds,
Task 3 Astra attempts zero. No Vault feature change, new runtime grants,
migration, production activation or publication occurred.

Cleanup `da0bbd` confirmed **zero** generated `singularity_test_%` databases
on the exact owned isolated cluster and stopped that server. All five latest
integration/sealing/restore roots were verified absent; the ignored private
cluster/harness is retained for subsequent authorized local tasks, not deployed.
No other server or user data was stopped, changed or removed.
The six actual Task 3 source/test files plus reviewed design/plan/acceptance
records were committed locally as
`6108673035427b9656fd432e7c834ef5b182f59e`. Separate Task 5 cursor/adapter
test drafts remained unstaged and were not included.

## Task 5 pure contract preparation

Read-only `phase4_organization_contract_mapping` confirmed legacy standalone
adapter transactions and 100-row lists must remain unchanged. The design/plan
now specify narrow strict Query/Page constructors with fixed owner-free tag,
resource and edge items, UUID order and internal `:done`, plus literal Domains
query dispatch and trusted allowed kinds outside client params. Runtime/SQL
filtering precedes paging; no generic graph or Note Save coupling is introduced.
The same Sol worker drafted only three new pure test files (22 Core + 11
Domains cases). Production remains unchanged and RED has not yet executed.
`70557` above supplies the existing Core knowledge-link values / Domains port
baseline of 18 executed cases; it does not prove new pagination or real SQL.
Pure `45361` passed test formatting and exited 2: **22 Core tests, 22 failures**
and **11 Domains tests, 11 failures**, seed `215378`, 0.3/0.2 seconds.
The root is missing `OrganizationPageQuery.new/1`, not a syntax/undefined-struct
compile error. This establishes the eight query cases' focused RED; the 14
page and 11 dispatch cases stop at that dependency and do not yet isolate
their own missing interfaces. Implement only the query value first, then
observe fresh Page/dispatch RED before their production changes. No test is
skipped or claimed passing at this preparation checkpoint.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_core/test/singularity/core/organization_page_query_test.exs apps/singularity_core/test/singularity/core/organization_page_test.exs apps/singularity_domains/test/singularity/domains/organization_test.exs, test apps/singularity_core/test/singularity/core/organization_page_query_test.exs apps/singularity_core/test/singularity/core/organization_page_test.exs apps/singularity_domains/test/singularity/domains/organization_test.exs --seed 215378
```

Query-only implementation was followed by fresh `23770`, exit 2: Core
**37 tests + two properties, 14 expected failures**, 1.1 seconds; Domains
**12 tests, 11 expected failures**, 0.3 seconds, seed `215378`.
All eight new Query cases and all 18 existing cases passed. The 14 Page
cases now independently fail at missing `OrganizationPage.new/3`.
Ten Domains cases reach missing `Organization.page/5`; one still depends
on Page construction. Implement only Page next, then obtain fresh independent
Domains RED before its production change. The owned server stopped; this
pure invocation allocated no integration database. No test was weakened.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix test apps/singularity_core/test/singularity/core/organization_page_query_test.exs apps/singularity_core/test/singularity/core/organization_page_test.exs apps/singularity_core/test/singularity/core/knowledge_link_values_test.exs apps/singularity_domains/test/singularity/domains/knowledge_ports_test.exs apps/singularity_domains/test/singularity/domains/organization_test.exs --seed 215378
```

Page-only implementation passed formatting/compilation in fresh `28501`.
Core **37 tests + two properties, zero failures**, 1.0 seconds; Domains
**12 tests, 11 expected failures**, 0.4 seconds, seed `215378`, exit 2.
All eleven now independently reach missing `Organization.page/5`, including
canonical Page result reconstruction. This qualifies Domains RED before its
production implementation. No database/service was started for this invocation.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_core/lib/singularity/core/organization_page.ex, compile --warnings-as-errors, test apps/singularity_core/test/singularity/core/organization_page_query_test.exs apps/singularity_core/test/singularity/core/organization_page_test.exs apps/singularity_core/test/singularity/core/knowledge_link_values_test.exs apps/singularity_domains/test/singularity/domains/knowledge_ports_test.exs apps/singularity_domains/test/singularity/domains/organization_test.exs --seed 215378
```

Domain-only implementation completed the genuine pure GREEN in fresh
`75956`, exit 0: formatting/warnings-as-errors compilation PASS; Core
**37 tests + two properties, zero failures**, 0.8 seconds; Domains
**12 tests, zero failures**, 0.3 seconds, seed `215378` — 51 executed cases
in total including all 18 original regression cases. Independent actual
six-file `phase4_task3_actual_spec_review` PURE SPEC review passed with no
actionable findings. Separate QUALITY and remaining real adapter/cursor/RLS
checks are pending; this does not accept all of Task 5 or prove authorization.
No database/service was started by this pure invocation. Separate actual
six-file `phase4_task5_pure_quality_review` followed SPEC and returned QUALITY
PASS with zero Critical/Important/Minor findings; six frozen file hashes
matched before/after inspection. The pure slice is qualified locally, not the
whole Task 5 storage/authentication deliverable. Sol repair rounds zero, Astra zero.
The exact six-file pure slice was committed locally as
`2490da6da7ec8a0ddff799e0df2b0cd4c73439d3`, preserving separate Task 3 and
Task 5 SQL/test drafts unstaged.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_domains/lib/singularity/domains/organization.ex apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs, compile --warnings-as-errors, test apps/singularity_core/test/singularity/core/organization_page_query_test.exs apps/singularity_core/test/singularity/core/organization_page_test.exs apps/singularity_core/test/singularity/core/knowledge_link_values_test.exs apps/singularity_domains/test/singularity/domains/knowledge_ports_test.exs apps/singularity_domains/test/singularity/domains/organization_test.exs --seed 215378
```

### Task 5 real storage preparation

Read-only mapping confirmed explicit scoped methods can preserve all legacy
standalone transaction/ownerful/max100 behavior while adding UUID-keyset pages.
The unchanged Tag eight / Relationship ten / RLS two cases all passed in the
actual `80035` baseline. Test-only drafting now owns the two adapter suites
plus a new cursor test, preserving all existing cases. The design records the
minimal framed HMAC v1 envelope before production implementation; the worker's
literal oracle is independently computed with Perl/OpenSSL, not the decoder
under test. Independent detail review is still pending. This work does not
create a new secret, modify grants or authorize client capability input.

Parent unit attempt `88934` first formatted the four draft tests and passed
production `compile --warnings-as-errors`. The Domains callback contract ran
one case with an expected missing-Tag-callback failure, but the new cursor suite
failed compilation because private `binding/0` conflicts with Kernel's import.
Zero cursor cases ran: this is a test-harness failure, not semantic cursor RED.
The test-only Sol helper rename is repair attempt 1; production remains unchanged.

Fresh actual PostgreSQL RED `68368`, seed `215378`, ran all 39 Tag/Relationship
cases in 29.3 seconds: 21 expected UndefinedFunctionError failures for the new
scoped interfaces, all 18 unchanged legacy cases PASS, no fixture failures.
The owned isolated server stopped on exit (2). This qualifies the adapter
semantic RED only, not cursor behavior or final Storage acceptance.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/tag_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/relationship_repository_test.exs --seed 215378
```

### Task 4 winning-source authorization detail preparation

Read-only mapping confirms the existing opaque repository context can carry
the server-owned scoped-repo callback without changing Domains intents, Command,
HMAC, OperationScope or Vault. The design and plan now specify exact winning-only
new-member placement, same-connection current authorization with both epochs,
retained/replay bypass and ordinary sanitized denial rollback. This bounded
detail requires independent review before implementation; no Runtime or Storage
production change has been made for Task 4.

## Preserved boundaries and baseline inventory

No production activation, data/backfill, merge, push, version bump, tag,
release, image publication or deployment is included. Vault remains frozen;
no custody, key, capability, policy, UX or recovery change is authorized.
Backup's unsupported canonical guard stays fail-closed. Released migrations
must not be edited. No E2E workflow or browser assertion is changed or run.

Worktree inventory `dbd154` and protected file digest `234599` confirmed:

- Root `main`: `e866990fc0ee8682d139d70da9cbf5aff9b2ae2b`.
- Phase 2 import/extraction: `ff703bd710074738b0391bb2f29d585dc6166d5c`.
- Phase 2 verification: `c34935a112a2b4b807ed741e8e67e44d4e63eafe`.
- Phase 3: `617f0b986a3ecffba14c952988e39e3afe022cea`.
- Protected untracked Phase 2 runtime-outcomes integration plan SHA-256:
  `350a655703264603c4af8cea7fbbdba96126b22e2ee52f4e23bef6c561234281`.

Before Task 2, no PostgreSQL/service process or integration database had been
started for Phase 4. Task 2's exact isolated cluster is recorded above.
Whole-phase gates, full legacy restore,
implementation reviews and cleanup evidence remain required before acceptance.
