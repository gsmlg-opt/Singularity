# Phase 4 versioned sources and organization qualification

## Current status

**IN PROGRESS — NOT ACCEPTED.** E2E is deferred and NOT RUN, not a passing
browser/release gate. Tasks 1, 2 and the early Task 8 restore compatibility
slice are qualified locally after their owning checks and independent SPEC then
QUALITY review. Atomic Note source composition and remaining Phase 4
deliverables/whole-phase acceptance are pending.
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
