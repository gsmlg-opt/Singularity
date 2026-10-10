# Phase 4 versioned sources and organization qualification

## Current status

**IN PROGRESS — NOT ACCEPTED.** E2E is deferred and NOT RUN, not a passing
browser/release gate. Tasks 1, 2, 3 and the early Task 8 restore compatibility
slice are qualified locally after their owning checks and independent SPEC then
QUALITY review. Task 5's pure Query/Page/dispatch and real Storage cursor/paging
slices are qualified. Task 4's bounded winning-source Runtime mutation,
source DTOs/resolution and narrow permanent grants are locally qualified after
their owning gates and independent SPEC then QUALITY. Source resolution was
committed locally at `969554c7659316b36ae7ec147545d5a0ac6bccb6` (exact 14 files),
without Task 6 drafts. Task 6 authenticated organization facades are now locally
qualified after owning tests and independent SPEC then QUALITY. Markdown
rendering, remaining Phase 4 deliverables and whole-phase acceptance are pending.
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
retained/replay bypass and ordinary sanitized denial rollback. At preparation
time this detail required independent review before implementation, and no
Runtime or Storage production change had been made for Task 4. Separate
`phase4_internal_detail_spec_review` SPEC and `phase4_internal_detail_quality_review`
QUALITY subsequently passed with no findings and unchanged document hashes.
The three reviewed documents were committed locally as
`594d10606a39c66461e97c9c05bf951e1ade051d`.

### Task 5 real Storage qualification

Test-only cursor harness repair 1 renamed `binding/0` without changing any
assertion or vector. Fresh `38864` passed compilation and executed all nine
cursor cases with nine expected missing-module failures (0.2 seconds); this is
actual cursor semantic RED, unlike the earlier compilation failure.

The parent separated the existing complete four-port assertion loop into four
independent cases so the Tag failure could not hide Relationship RED. Attempt
`69822` ran four cases with two expected missing-callback failures but generated
static unreachable-clause warnings from compile-time module constants. A
generic shared assertion helper preserved every original assertion and removed
that harness warning: fresh `47392` with `--warnings-as-errors` ran four cases,
two expected Tag/Relationship callback failures, and both established ports
PASS (0.1 seconds).

The actual nine-file implementation extends the two Domains repository ports,
adds Storage `OrganizationCursor`, updates Tag/Relationship adapters and the
four owning test files. Cursor `10338` passed format/compile and all 20 actual
organization/search cursor cases (nine new, 11 existing; 0.3 seconds).

First full unit/property check `91031` passed exact nine-file formatting and
`compile --warnings-as-errors`, then Core **37 tests + two properties**, Domains
**15 tests** and Storage **20 tests**, all zero failures: **74 actual cases**
(0.8/0.2/0.3 seconds, seed `215378`). Real PostgreSQL `72452` passed Tag **19**,
Relationship **20** and unchanged RLS **two** cases: **41 actual cases, zero
failures**, 20.1 seconds, same seed, exit 0. It proves all four 101-item traversals,
pre-limit live/kind filtering, exact UUID continuations, matching GUCs, atomic
outer rollback, idempotent audits, pins/direction and preserved legacy max100.
It does not prove Runtime current capability checks or public facades.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/tag_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/relationship_repository_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs --seed 215378
```

Independent actual `phase4_organization_storage_spec_review` SPEC passed with no
blocking findings; subsequent separate `phase4_internal_detail_quality_review`
actual Storage QUALITY passed with zero findings. All nine reviewed file hashes
stayed unchanged. Internal Tag attach/detach retain the established validator's
UUID spelling tolerance; the review found no owner/RLS bypass or contrary
internal contract. Task 6 must enforce canonical client identifiers.
Fresh `45999` passed exact nine-file `format --check-formatted`, production
`compile --warnings-as-errors`, and `xref graph --format cycles --fail-above 0`
with **No cycles found**. `git diff --check` passed. Production Sol repair
rounds **0**, Astra **0**. This qualifies only the scoped Storage slice; the
resource-tag public facade and permanent-grant-helper cleanup remain pending.
Owned-cluster cleanup check `46669` confirmed **zero** generated
`singularity_test_%` databases and stopped only that private server. All five
latest generated integration roots were verified absent. The ignored private
cluster/harness is retained for the remaining authorized local work.
The exact nine source/test files plus the plan/report were committed locally as
`9bf06e9434391d960662f55a0ed49f79067f63e4`; the independent Task 4 drafts
remained unstaged.

### Task 4 winning-source authorization execution, still in progress

Unchanged Runtime Note mutation/read/API/observability baseline `43434` passed
all **27 actual unit cases** (0.8 seconds, seed `215378`, warnings-as-errors).
Additive test-only preparation preserves all 29 existing Storage source cases
and adds 19 real scoped authorization-context cases, including all three winning
mutations, exact new-only references, same connection/transaction/GUC, authorization
before row-share locks/checkpoints, denial full-state rollback, retained/empty
skip, deleted-source replay and malformed callback contexts.

Fresh PostgreSQL RED `47285` passed production compilation and executed Storage
**48 cases with 19 expected mapped-repo ArgumentError failures**, all 29 legacy
cases PASS (25.0 seconds), plus unchanged Runtime authorization **three cases,
zero failures** (2.3 seconds). No fixture failure; **51 actual cases, 19 expected
failures**. Parent production changes are limited to NoteRepository unpacking
the server context and threading its authorization callback separately through
winning source preparation; no intent/HMAC, Domains, OperationScope or Vault
change. First implementation `65144` passed format/compile and ran Storage
**58 cases, four failures** plus Runtime **three, zero failures** (27.4/2.4
seconds). All four failures were the new test checkpoint helper returning the
`send/2` tuple instead of the required `:ok`; they are harness failures, not
GREEN. Sol harness repair 1 adds explicit `:ok` after both callbacks' unchanged
assertions/messages. No failed production repair round or Astra attempt has
occurred. Fresh owning validation is recorded after completion below.
Fresh harness-repair validation `79382` passed production compilation and
Storage **58 cases, zero failures** (37.7 seconds), plus Runtime authorization
**three cases, zero failures** (2.2 seconds): **61 actual integration cases
PASS**, seed `215378`, exit 0, owned server stopped. The source context remains
an independently unreviewed Task 4 production slice, not Task 4 acceptance.

Runtime test-only preparation adds 34 composition units and minimally updates
the existing mutation fake's server-context argument assertions. Fresh `13287`
passed test compilation with warnings-as-errors and ran **61 unit cases, 38
expected failures**, 3.7 seconds: 32 new missing-source-context/whitelist/check
failures and six existing cases at the deliberately updated context contract;
23 controls PASS. Runtime production remains unchanged at this RED. Unit fakes
and independent literal HMAC terms prove composition contracts, not live source
authorization. Actual Runtime/Storage integration, DTOs, resolution, grants and
independent Task 4 reviews remain required.

### Task 4 winning-source Runtime composition GREEN

Runtime production implementation changes only `notes/create.ex`: the two
collection client fields, the exact server-only context for create/save/merge,
and the new-member callback using the existing authorizer/dependencies, the
captured scoped repo, both session epochs and fixed sorted existing capabilities.
Hydration/lifecycle contracts remain raw-repo; Command, HMAC, Domains,
OperationScope, custody, Vault and capability definitions are unchanged.
Fresh unit `31770` passed exact six-file formatting and warnings-as-errors
compilation, then all **61 actual Runtime units, zero failures**, 3.5 seconds,
seed `215378`, including every original mutation/read/API/observability assertion.

The parent adds ten real Runtime/Domain/NoteRepository/OperationScope/live-identity
authorization cases to the existing three. They cover create/save/merge denial
and exact 13-table rollback, authorized ordered membership/seals/completed
receipts, mixed-kind all-of checks, current revocation of new evidence versus
retained/inherited copies, deleted-source winning replay with latest-head
hydration, and nondisclosing foreign-owner rejection. Custody remains the
established test adapter, not proof of production unlock or source-byte custody.
These real cases were added after Runtime implementation; their first passing
run is additional qualification, not a claimed prior semantic RED. The earlier
38-failure Runtime RED and 19-failure Storage RED remain the TDD evidence.

An initial parent invocation `30794` mistakenly used ordinary `mix test
--include integration`, without the repository's isolated-database task. Seven
setup cases failed against the deliberately unusable default `127.0.0.1:1`
in 38.0 seconds. The exact owned BEAM was terminated, the private server stopped,
and no test database/root had been allocated. This is **FAIL/ABORTED**, not a
production failure or a completed 71-case gate; remaining cases were NOT RUN.
No source/test assertion or database configuration was changed to accommodate it.
The parent command correction reruns the complete requested suites through
`mix singularity.test.integration` in a fresh VM and isolated database.

Fresh actual `6370` passed Storage **58 cases, zero failures**, 39.8 seconds,
and Runtime **13 cases, zero failures**, 12.7 seconds: **71 executed integration
cases PASS**, seed `215378`, exit 0, owned server stopped. Fresh static `98123`
passed exact six-file `format --check-formatted`, production
`compile --warnings-as-errors`, and zero-cycle xref (**No cycles found**).
Sol source-context harness repair 1 remains PASS; parent integration-command
repair 1 PASS; production repair rounds **0**, Astra attempts **0** in this slice.
Actual six-file independent `phase4_internal_detail_spec_review` SPEC passed
with zero actionable findings. Subsequent separate
`phase4_internal_detail_quality_review` actual mutation QUALITY passed with
zero findings. All six before/after source/test hashes matched in both reviews,
and scoped diff checks passed. Owned-cluster cleanup `5686` confirmed zero
generated integration databases and stopped only that private server. The latest
allocated storage root `e6db7aac98422c9634e96036` was verified absent. No material
user data was removed; the ignored owned cluster remains for subsequent local
checks. Local commit remains pending.
DTOs, exact selected-source resolution, grants, organization
Runtime facades, Markdown export and whole-phase acceptance remain incomplete.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_runtime/lib/singularity/runtime/notes/create.ex apps/singularity_runtime/test/singularity/runtime/note_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs apps/singularity_storage/lib/singularity/storage/postgres/note_repository.ex apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs, compile --warnings-as-errors, test apps/singularity_runtime/test/singularity/runtime/note_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs apps/singularity_runtime/test/singularity/runtime/note_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_observability_test.exs --warnings-as-errors --seed 215378
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs --warnings-as-errors --seed 215378
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted apps/singularity_runtime/lib/singularity/runtime/notes/create.ex apps/singularity_runtime/test/singularity/runtime/note_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs apps/singularity_storage/lib/singularity/storage/postgres/note_repository.ex apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs, compile --warnings-as-errors, xref graph --format cycles --fail-above 0
```

### Task 4 selected historical resolution detail preparation

The qualified winning-source slice is recorded by local commit
`a6376d6055df13a885d7427012018eab754c4778`; only its exact six source/test
files and plan/report were staged. It does not accept all of Task 4 or Phase 4.
Read-only mapping confirmed existing `list_set` hydrates every citation fragment
and `read_membership` selects the whole metadata set; neither is the requested
single-member pre-target-authorization selector. Ordinary Note, Document and
Search readers remain live-only and cannot be reused unchanged for tombstones.

The design and plan now specify four minimal existing-scope typed selector and
historical-resolution callbacks, exact owner-free metadata/selected-fragment
shapes, live/private/sealed containing identity, matching GUCs, separate current
target authorization, immutable pins/deleted status, and exact AssetMetadata
filename binding with nondisclosing not-found instead of a mutable-head fallback.
Domain port/test synchronization is necessary bounded interface work, not a
product expansion. Independent detail SPEC then QUALITY remain required before
production implementation. Test-only drafting owns just the existing adapter
and Domains port suites; all legacy assertions are preserved, no required seal,
trigger or policy is disabled, and temporary isolated ACL probes restore their
original state. No selected-reader production implementation or additional
integration process has been started for this detail yet.

Additional read-only mapping found raw NoteRepository reads have a broader
contract than the scoped membership reader. Runtime will use one shared
metadata-only composer inside the existing OperationScope callbacks, including
ordinary Export's direct raw read, rather than silently imposing GUC/transaction
requirements on legacy Storage readers. The design/plan now include the small
helper, explicit internal adapter injection, exact row/revision/scope binding,
strict required Note/NoteVersion arrays, and necessary Web constructor fixtures.
These compatibility changes do not enable browser behavior or Task 7 rendering.
All failed/missing real membership reads stay fail-closed; fake readers remain
explicit and are not canonical-source evidence. This composition detail shares
the pending independent SPEC then QUALITY review before production changes.

Independent actual three-document `phase4_internal_detail_spec_review` SPEC
passed with zero actionable findings; subsequent separate
`phase4_internal_detail_quality_review` resolution-detail QUALITY passed with
zero findings. Both captured unchanged design/plan/report hashes. This qualifies
only the detail, not its unimplemented code or the whole task.

Test-only drafting preserves all 15 legacy KnowledgeLink cases and adds 22,
including scoped/GUC checks, requested-member isolation with target-hydration
SELECT revoked and restored, exact historical/tombstone/restore pins, pinned
Asset filename/no fallback, selected fragment/locator and nondisclosing errors.
The Domains suite retains its four port cases, extends the exact KnowledgeLinks
inventory and adds one explicit named-map-type case. Fresh `69014` passed
formatting/warnings-as-errors compilation and ran **five units, two expected
missing-callback/type failures**, 0.2 seconds, seed `215378`; the other three
established port controls passed. Fresh isolated SQL `16379` ran **37 cases,
22 missing-reader failures**, 14.0 seconds, same seed, exit 2. The unchanged 15
legacy cases passed. No selected-reader production existed during this RED.
The private server stopped, and generated database/root cleanup still must be
confirmed before qualified acceptance. Sol harness/production repair rounds
**0**, Astra attempts **0** for this selected-reader slice.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_domains/test/singularity/domains/knowledge_ports_test.exs, compile --warnings-as-errors, test apps/singularity_domains/test/singularity/domains/knowledge_ports_test.exs --warnings-as-errors --seed 215378
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs --warnings-as-errors --seed 215378
```

Runtime test-only preparation now includes 15 explicit source-collection/DTO
cases requiring strict owner-free nested references, both Note/version arrays,
canonical order, bounds/uniqueness, exact session/row/revision binding, and
fail-closed missing/malformed membership replies. Its reader is an explicit
unit fake, not evidence of SQL membership or live authorization.
The shared `NoteValidation` helper is physically in `dto/note_summary.ex`, not
a separate file; the plan now includes only that necessary validation section,
without modifying summary fields or behavior. This inventory correction does
not change the reviewed composition contract.

### Task 4 selected readers implementation and Runtime collections RED

The reviewed detail is recorded by local commit
`dbf579167504f1e6c8b1b95ab7a983698145459b`, with only the exact three
governing/evidence documents staged. Selected-reader implementation adds four
callbacks and four explicit named result types to the existing Domains port,
and four matching scoped selectors/resolvers to the existing Storage adapter.
Legacy reader/write/lock contracts remain unchanged. Production is frozen
pending the parent's real owning integration and independent SPEC then QUALITY.

Fresh `64390` passed scoped formatting and production warnings-as-errors
compilation, and all five Domains port cases, but the new Runtime suite did not
compile: its session fixture omitted the enforced `expires_at`. This is a
test-harness FAIL, not semantic RED or implementation failure. Harness repair 1
adds the normal explicit expiry without changing production or any assertion.
`91209` compiled and ran the 15 expected missing-DTO/composer failures, but
generated literal-mode comparisons emitted compiler warnings; that warning gate
is not accepted. Harness repair 2 replaces only constant comparison fixture
selection with four explicit mode clauses, preserving all four cases and
business assertions.

Fresh `89624` passed formatting and warnings-as-errors compilation with no
compiler warnings. Domains **five cases, zero failures**, 0.2 seconds; Runtime
**15 cases, 15 expected semantic failures**, 0.6 seconds, seed `215378`,
exit 2. Undefined new DTO/composer functions and current constructors' rejection
of the required arrays are the expected failures. No Runtime DTO/composer
production existed during this RED. Harness repair 2 PASS; no failed production
repair round or Astra attempt in this new slice. This does not accept Task 4.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_runtime/test/singularity/runtime/note_source_collections_test.exs, compile --warnings-as-errors, test apps/singularity_domains/test/singularity/domains/knowledge_ports_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collections_test.exs --warnings-as-errors --seed 215378
```

### Task 4 selected readers qualified locally

Fresh real owning integration `91302` uses the repository's isolated task,
not ordinary `mix test --include integration`. KnowledgeLink **37**, atomic
NoteSources **48**, and knowledge RLS **two**: **87 actual cases, zero
failures**, 98.9 seconds, seed `215378`, exit 0; the owned private server stopped.
All 15 original KnowledgeLink cases remain unchanged. No selected-reader
production repair round or Astra attempt was needed.

Actual four-file independent `phase4_internal_detail_spec_review` SPEC passed
with zero actionable findings; subsequent separate
`phase4_internal_detail_quality_review` selected-reader QUALITY passed with
zero findings. The exact four source/test hashes matched before and after both
read-only reviews, including the legal sealed fixtures and privilege-restoring
SELECT revocation probes. Scoped diff checks passed.

Fresh `85568` passed selected four-file `format --check-formatted`, production
`compile --warnings-as-errors`, the five Domains port cases and zero-cycle
xref (**No cycles found**). Cleanup `2906` confirmed **zero generated test
databases** and stopped only the owned private server. Both selected-reader
allocated roots `114fb29f8ef042df19fddd1b` and
`bea56073351c94f8f5d43c93`, and its `postmaster.pid`, are verified absent by
three separate read-only checks. The ignored private cluster remains available;
no material user data was removed. The bounded selected-reader source commit is
`68c9c4cd96f8d350f00749a58fff4b79a21ffbc1`.

This qualifies the four internal Storage/Domain reader operations only.
Runtime current target authorization and public resolution, DTO/composer
integration, permanent grants and whole Task 4 remain incomplete. E2E NOT RUN.

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs --warnings-as-errors --seed 215378
devenv shell -- bash .devenv/phase4-pg-command.sh psql -X --dbname=postgres --tuples-only --no-align --command="SELECT count(*) FROM pg_database WHERE datname LIKE 'singularity_test_%'"
```

### Task 4 DTO/composer and route preparation

Initial DTO/composer implementation is limited to the two owner-free reference
DTOs, shared validation, required Note/version arrays and the metadata-only
composer. `37590` passed production compile, but its combined 56 Runtime cases
had 35 failures: two positive NoteVersion fixtures had a noninitial revision
without its required parent; the other 33 were missing route composition plus
route fake inventory/warnings. This is FAIL, not a passing implementation gate.
The parent's DTO fixture repair changes only the positive parent identity to
the existing valid contract. Fresh `85568` ran **15 DTO/composer cases, zero
failures**, 0.7 seconds, plus the five port cases, with warnings-as-errors and
zero xref cycles. All malformed, private, duplicate, improper and oversized
collection assertions remain intact. DTO/composer integration and independent
review are not yet accepted.

The new route suite contains 41 unit cases for current/exact Get, both conflict
branches, create/save/merge/restore hydration, stale receipt versus latest-head
replay, Export-before-audit and pre-primary-authorization denial. It uses real
Domain command dispatch with explicitly labeled unit-only adapters, not SQL or
custody proof. Its initial fake omitted the required forbidden tombstone
callback, used noninitial versions without parents, and generated literal
comparison warnings. Sol route harness repair 1 corrects only these fixture
problems, preserving all 41 cases and assertions. Fresh `83288` passed
formatting/production compile with no warnings and ran **41 cases, 32 expected
missing-composition failures**, nine controls PASS, 1.5 seconds, seed `215378`,
exit 2. Consumer production was still unchanged during this clean RED.

The parent now composes the complete arrays inside the existing authorized
scoped Get/Mutation/Export callbacks and extends strict internal-to-DTO shapes.
Fresh `99779` passed exact formatting, warnings-as-errors production compile,
all **56 new Runtime DTO/composer/route cases, zero failures**, 1.3 seconds,
the five port cases and zero xref cycles; seed `215378`, exit 0. This is the
initial consumer implementation's focused GREEN, not owning-suite or real
integration acceptance. No production repair round or Astra attempt was needed.
All changes remain frozen for broader parent validation. Necessary existing fake readers
and explicit constructor-array fixtures are being drafted separately; real
source integration keeps its actual Storage reader. No browser behavior,
authorization/custody/Command/HMAC semantics or released migration is changed.

### Task 4 owning collection qualification and SPEC repair

Fresh `55290` passed scoped formatting, warnings-as-errors compilation and
zero-cycle xref, with **117 Runtime and five Web cases, zero failures**.
Existing unit adapters now explicitly inject their metadata-only membership
reader, and DTO fixtures provide the required arrays. Real source integration
retains the actual Storage reader; no browser behavior or assertion was changed.
Fresh isolated integration `93683` passed **58 Storage and 13 Runtime cases,
zero failures**, 36.8 and 14.3 seconds respectively, seed `215378`, exit 0.

Actual independent 19-file SPEC found one P2: the server membership boundary
accepted normalization-changing maps because generic client constructors fill
defaults and normalize values. This was **SPEC FAIL**, not acceptance. The
parent added two regressions without removing or weakening the original cases.
Fresh `13136` ran **17 cases, one reproduced semantic failure**, 1.0 seconds,
with warnings-as-errors compilation; the missing-role server map demonstrated
the unwanted default filling.

Sol review repair 1 now requires a plain exact membership map and unchanged
canonical nested attributes after reconstruction. Canonical Core references,
DTOs and complete canonical maps remain valid; missing output fields, aliases,
value/representation rewriting and forged membership structs fail closed.
Generic constructor input normalization remains unchanged.

Fresh `23687` passed the exact 19-file format check, production compilation
without warnings, all **119 Runtime and five Web cases**, 4.0 and 0.6 seconds,
and xref **No cycles found**, seed `215378`, exit 0. Fresh real integration
`38362` again passed **58 Storage and 13 Runtime cases**, 36.2 and 12.8 seconds,
same seed, exit 0, after the repair. No failed production repair round or Astra
attempt was required. Fresh independent `phase4_internal_detail_spec_review`
SPEC rereview passed with zero actionable findings; subsequent separate
`phase4_collection_quality_rereview` QUALITY passed with zero findings. All
19 source/test hashes remained unchanged during both read-only reviews.
This qualifies the collection slice only; neither Task 4 nor Phase 4 is accepted.
The local collection commit includes exactly the 19 reviewed source/test files
and these governing/evidence documents. Resolution drafts remain outside it.

Cleanup `38684` confirmed **zero generated test databases** and stopped only
the owned private server. The two integration roots
`75828746daccc4ac7ecbc12a` and `8df9e57683e0230140f3390f`, and the private
cluster's `postmaster.pid`, were individually verified absent, each exit 0.
The ignored private cluster remains; no material user data was removed.

Exact repair and integration commands:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_runtime/test/singularity/runtime/note_source_collections_test.exs, compile --warnings-as-errors, test apps/singularity_runtime/test/singularity/runtime/note_source_collections_test.exs --warnings-as-errors --seed 215378
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_runtime/lib/singularity/runtime/notes/source_collections.ex apps/singularity_runtime/test/singularity/runtime/note_source_collections_test.exs, format --check-formatted apps/singularity_runtime/lib/singularity/runtime/dto/note_attachment.ex apps/singularity_runtime/lib/singularity/runtime/dto/note_citation.ex apps/singularity_runtime/lib/singularity/runtime/dto/note_summary.ex apps/singularity_runtime/lib/singularity/runtime/dto/note.ex apps/singularity_runtime/lib/singularity/runtime/dto/note_version.ex apps/singularity_runtime/lib/singularity/runtime/notes/source_collections.ex apps/singularity_runtime/lib/singularity/runtime/notes/get.ex apps/singularity_runtime/lib/singularity/runtime/notes/create.ex apps/singularity_runtime/lib/singularity/runtime/notes/export.ex apps/singularity_runtime/lib/singularity/runtime/notes/dto.ex apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs apps/singularity_runtime/test/singularity/runtime/note_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_observability_test.exs apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs apps/singularity_web/test/singularity/web/notes_live_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collections_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collection_routes_test.exs, compile --warnings-as-errors, test apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs apps/singularity_runtime/test/singularity/runtime/note_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_observability_test.exs apps/singularity_web/test/singularity/web/notes_live_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collections_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collection_routes_test.exs --warnings-as-errors --seed 215378, xref graph --format cycles --fail-above 0
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs --warnings-as-errors --seed 215378
devenv shell -- bash .devenv/phase4-pg-command.sh psql -X --dbname=postgres --tuples-only --no-align --command="SELECT count(*) FROM pg_database WHERE datname LIKE 'singularity_test_%'"
```

### Task 4 exact source resolution RED

The new explicit unit adapters require one containing Note read scope, one
requested-member selection, current target authorization with both session
epochs, and only then exact pinned source/selected-fragment hydration on the
same scoped connection. Strict results preserve canonical references, pins,
historical deletion status, UTF-8 titles and canonical fragment identity; they
reject private fields, rewritten values, malformed replies and oversized text.
These fakes prove ordering and wire contracts only, not SQL or live custody.

Fresh `67562` passed test formatting and production warnings-as-errors
compilation, then ran **37 cases, 37 expected missing-ResolveSource-function
failures**, 0.8 seconds, seed `215378`, exit 2. No production resolver existed
during this clean semantic RED. Source resolution implementation is now being
drafted but remains unqualified; the public API and permanent grants are pending.
E2E **NOT RUN**, as explicitly deferred by the user.

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format apps/singularity_runtime/test/singularity/runtime/note_source_resolution_test.exs, compile --warnings-as-errors, test apps/singularity_runtime/test/singularity/runtime/note_source_resolution_test.exs --warnings-as-errors --seed 215378
```


### Task 4 public source resolution and actual authorization

The selected resolver now checks containing Note authority, selects exactly one
stored member, checks its current kind-specific target authority, and only then
hydrates its immutable typed version/fragment on that same scoped connection.
Shared strict conversion reconstructs exact owner-free references, source
metadata and selected fragments without private fields or rewritten values.
The two public/configured Api facades reject noncanonical selectors and malformed
Session structs before dispatch; existing generic Session/Vault behavior is
unchanged. Web registration preserves the original archived byte hashes and
accepts only five exact contextual Phase 4 additions, with mutation/removal/
duplication/relocation negatives rather than a broad baseline reset.

Fresh `79267` passed compilation: **37 resolver cases PASS** and **28 expected
missing-Api failures**, plus the original 18 architecture cases PASS. Initial
Api `23914` had **65 cases, four failures**, exposing the generic UUID validator's
uppercase/16-byte acceptance. Narrow seam-only validation repair passed all 65
in `45863`. Two added forged-Session regressions reproduced KeyError in `67973`
(28 cases, two failures); exact-key validation before field access then passed
all 65 in `51187`. Fresh owning `53604` passed **184 Runtime and 25 Web cases**,
warnings-as-errors compilation and **zero xref cycles**, seed `215378`, exit 0.

Actual new SQL tests initially had test-harness failures, not feature proof:
`3571` failed test compilation on a non-invoked function variable; harness repair
1 preserved all 11 cases but `87662` still had **24 tests, 11 setup failures**
because Create returns a Note directly and Save returns `.canonical`. Harness
repair 2 corrected exactly six selectors without changing assertions. Fresh
`92889` passed **24 Runtime integration tests, zero failures**, 23.2 seconds,
plus **13 Storage grant tests, zero failures**, 3.7 seconds, same seed, exit 0.
These use actual OperationScope, Authorize and PostgreSQL readers. Existing
integration-only custody/audit doubles remain explicitly not live custody proof.

### Task 4 narrow permanent grants and cleanup regression

Before adding permanent grants, three focused ACL-preservation regressions in
`11997` produced **13 tests, three expected failures**: temporary organization
DELETE cleanup revoked already-existing permissions after success, raise and
throw. The smallest helper change reuses its existing permission-preserving
cleanup. `92889` passed all 13, including exact full-ACL restoration and mixed
durable/temporary permissions. No production role or authorization policy was
changed by this test-helper repair.

The exact permanent matrix adds only web SELECT/INSERT for attachment/citation
children and tags, and SELECT/INSERT/DELETE for resource tags/relationships.
Existing Document and seal SELECT remain unchanged; seal writes, receipts,
worker/dispatcher/pre-auth grants, grant options and PUBLIC remain excluded.
There is no separately managed PostgreSQL download role; no download path or
role is added or changed. Existing RLS rollback/cleanup assertions now require
the new durable tag INSERT rather than silently reverting it.

Fresh `17081` ran **15 tests, two expected missing-permanent-grant failures**,
5.7 seconds, seed `215378`, exit 2, before the new forward-only
`20261011000100_knowledge_runtime_grants.exs`. Released migrations remain
untouched. The new Runtime source integration's temporary source/Document grant
wrapper is removed for qualification under the actual permanent web grants.
Owning integration and independent review are still pending; Task 4 and Phase 4
are not yet accepted. E2E **NOT RUN**, explicitly deferred.

Exact helper RED/GREEN and permanent-matrix RED commands:

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs --warnings-as-errors --seed 215378
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_integration_test.exs --warnings-as-errors --seed 215378
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs --warnings-as-errors --seed 215378
```

### Task 4 final owning qualification and independent review

`26372` was FAIL: **149 Storage tests, one failure**, 94.2 seconds; its
**24 Runtime tests passed**, 21.5 seconds, under permanent grants without the
temporary source wrapper. The failure was a contract mismatch: invalid default
organization rows reach the existing BEFORE INSERT provenance guard before
native RLS. Repair 1 requires exact `23514` plus the named resource constraint,
and adds valid-row missing-GUC INSERT `42501` negatives for all five source/
organization tables. No assertion was removed, bypassed or relaxed.

Focused `97622` passed **15 grant/RLS cases**, 3.7 seconds. Fresh whole owning
`86382` passed **149 Storage and 24 Runtime integration cases**, 97.2 and 21.0
seconds, seed `215378`, exit 0. Fresh `82329` checked formatting of all 11
candidate files, compiled without warnings, passed **184 Runtime and 25 Web
cases**, 4.1 and 2.3 seconds, and reported **No cycles found**, same seed, exit 0.

Actual independent 11-file SPEC passed with zero actionable findings, followed
by separate actual QUALITY with zero findings. Both reviewers checked unchanged
source/test SHA-256 manifests; neither relied on a docs-only review. The public
resolution/grants slice and all Task 4 checks are now locally qualified, but
Phase 4 acceptance, Task 6/7 and whole-phase gates remain incomplete.

Cleanup `23855` confirmed **zero generated test databases** and stopped only
the owned private server. Each of the eight allocated roots
`602147418251fbcf1bd35f59`, `dc5d768d61be82854faf4e14`,
`7d9a5bd98b489d6c2452ede5`, `cf1ab2a258a8f8f8c59e6041`,
`e400e2c5f96dcf57f99d466c`, `072bda61afda255a4f79194a`,
`ea2054a3d8c86a75a093c416`, `a54973c7825bc4953a71db6b`, and the
private cluster `postmaster.pid`, was individually verified absent, each exit 0.
The ignored private cluster remains; no material user data was removed.

Exact final qualification and cleanup commands:

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs apps/singularity_storage/test/singularity/storage/postgres/tag_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/relationship_repository_test.exs apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_integration_test.exs --warnings-as-errors --seed 215378
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix do format --check-formatted apps/singularity_runtime/lib/singularity/runtime/api.ex apps/singularity_runtime/lib/singularity/runtime/notes/dto.ex apps/singularity_runtime/lib/singularity/runtime/notes/resolve_source.ex apps/singularity_runtime/test/singularity/runtime/note_source_resolution_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_integration_test.exs apps/singularity_storage/priv/repo/migrations/20261011000100_knowledge_runtime_grants.exs apps/singularity_storage/test/support/knowledge_test_grants.ex apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs, compile --warnings-as-errors, test apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs apps/singularity_runtime/test/singularity/runtime/note_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_observability_test.exs apps/singularity_web/test/singularity/web/notes_live_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collections_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collection_routes_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_api_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --warnings-as-errors --seed 215378, xref graph --format cycles --fail-above 0
devenv shell -- bash .devenv/phase4-pg-command.sh psql -X --dbname=postgres --tuples-only --no-align --command="SELECT count(*) FROM pg_database WHERE datname LIKE 'singularity_test_%'"
```

### Task 6 result detail preparation

The fixed owner-free Tag/Resource/Relationship/Page DTO contracts and natural-key
replay identity detail passed bounded independent DESIGN SPEC, then separate
DESIGN QUALITY, zero actionable findings and unchanged two-document hashes.
This is not implementation acceptance. Astra architecture-only assistance under
`astra_gate=PROJECT_ARCHITECTURE` supplied the minimal invocation-local entry
wrapper and bounded selector/conditional-delete detail. DESIGN SPEC found one
P2 overclaim about failures already hidden as forbidden by existing Authorize;
repair explicitly describes that returned-result opacity and current exact-kind
checks. Fresh SPEC then separate QUALITY passed, zero remaining findings.
The typed-Page clarification separately passed SPEC then QUALITY: raw Core page
maps keep `:done`; only typed public Page DTOs accept nil terminals. No general
authorization, custody or capability change is planned.

Api now has 47 draft cases (four added typed Page roundtrips, every original
negative retained); Operations has 41 and the entry Authorizer 18. `8585` was
test compilation FAIL because UUID `@tag` collided with ExUnit's reserved
attribute, not feature RED. Parent's first harness repair mechanically renamed
it in the two affected unit files. Fresh `75646` passed test formatting and
production warnings-as-errors compilation, then ran **106 cases, 106 failures**,
1.5 seconds, seed `215378`, exit 2; missing new facade/Operations/Authorizer
functions are reproduced before any Task 6 production implementation. This is
RED, not implementation or phase acceptance. No production repair failure or
Astra repair round is claimed; architecture assistance is distinct. E2E NOT RUN.

### Task 6 initial implementation and focused contracts

Actual isolated PostgreSQL RED `11159` ran **44 cases, 24 failures**, 33.5
seconds, seed `215378`, exit 2, before the metadata and selected-delete
callbacks existed. The 16 new metadata and eight selected-delete cases fail;
all 20 established relationship cases pass. The owned private server stopped.
The test-only ACL probe revokes web typed-content SELECT in the allocated test
database and restores the exact grantor/grant-option ACL, not broad grants.
No typed-content hydration or Runtime authorization proof is inferred from
this Storage-only probe.

Initial implementation `12595` formatted the exact 17 selected files and
compiled with warnings-as-errors, then ran **106 Runtime cases, two failures**,
1.5 seconds. Both failures were incorrect backlink fixtures: the row pointed
away from the requested incoming selector and the new strict DTO correctly
rejected it. Harness repair 1 binds the positive backlink to the actual target,
preserves every assertion, and adds a directed-selector negative covering
both edge page operations. Fresh `86854` passed **107 cases, zero failures**,
1.6 seconds, same seed, exit 0. No production logic was weakened. This is
focused unit evidence only; actual organization SQL/authorization, registration
contracts, independent reviews and whole owning suites remain pending.
Sol production repair attempts 0; this harness repair 1 passed. Astra repair
attempts 0, distinct from the recorded architecture advice. E2E NOT RUN.

Exact RED and focused GREEN commands:

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/organization_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/relationship_repository_test.exs --warnings-as-errors --seed 215378
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps bash -c 'mix format apps/singularity_runtime/test/singularity/runtime/organization_operations_test.exs && mix test apps/singularity_runtime/test/singularity/runtime/organization_api_test.exs apps/singularity_runtime/test/singularity/runtime/organization_authorizer_test.exs apps/singularity_runtime/test/singularity/runtime/organization_operations_test.exs --warnings-as-errors --seed 215378'
```

Fresh actual Storage `71445` passed **44 cases, zero failures**, 20.7 seconds,
same seed, exit 0; private server stopped. Registration `95860` first ran
**20 cases, three expected stale-registration failures**, 1.0 second, exit 2.
The additive guard amendment freezes the five exact Task 6 insertion blocks
before removing them, retains every historical digest, and adds closed arity
registration plus mutation/removal/duplication/relocation negatives. The first
harness repair `5134` failed formatting because it duplicated an existing
test declaration (exit 1, not RED/PASS). Repair 2 removed that one erroneous
declaration without changing assertions; `1002` passed **22 cases, zero
failures**, 2.0 seconds, exit 0. Cumulative registration harness counters are
Sol 1 failed repair / 1 passing repair, Astra 0. Full actual Runtime integration
and final owning qualification remain pending, not phase acceptance.

Fresh owning unit/static `81421` passed exact 18-file format verification,
warnings-as-errors compilation, **Core 22 / Domains 11 / Storage 9 / Runtime
291 / Web 41 cases**, zero failures (0.3 / 0.4 / 0.3 / 5.6 / 2.9 seconds),
seed `215378`, exit 0, and **No cycles found**. Prior Note source contracts and
legacy composition digests remain included. Diff whitespace check passed.
The new real organization Runtime integration file is not yet selected or
executed; this unit/static evidence does not establish its acceptance.

Subsequent actual Runtime organization integration `96891` ran **18 cases,
one failure**, 21.9 seconds, seed `215378`, exit 2. The expected edge fixture
used uppercase hexadecimal suffixes from `Integer.to_string/2`; PostgreSQL
returned canonical lowercase UUIDs. Harness repair 1 lowercases only the
test UUID generator and adds an exact canonical assertion before edge seeding,
retaining all page equality, uniqueness, count, permission and audit assertions.
Fresh `30585` passed **18 cases, zero failures**, 22.0 seconds, same seed,
exit 0, private server stopped. No production change was needed.

These actual cases use OperationScope, Authorize, IdentityRepository,
ScopedRepo, native RLS, permanent web grants, organization repositories and
AuditSink. They cover Note-only and locked Asset/Document-only authority,
all endpoint capabilities, current kind revocation/regrant, both epochs,
actual MAC cursor bindings, exact replay/audit identities, tombstone/restore,
all eight configured facade callbacks into actual operations, and pages of
105 tags, 105 outgoing and 105 incoming edges without truncation. The read-only
observer delegates real authorizer/storage results and requires one backend,
both scoped GUCs and the exact existing authorization ShareLock at each step;
this is not an interleaving/concurrency proof. Its Custodian fixture remains
explicitly test-only, not live custody or byte-delivery acceptance.
Runtime integration harness counters: Sol repair 1 PASS / Astra repair 0;
production repair 0. E2E NOT RUN.

Independent actual 19-file SPEC review passed with zero actionable P0–P2
findings, unchanged SHA-256 manifests before/after. Separate QUALITY and the
complete owning SQL gate are still in progress; Task 6 is not yet accepted.

Exact new Runtime integration qualification command:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format apps/singularity_runtime/test/singularity/runtime/organization_integration_test.exs && devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/organization_integration_test.exs --warnings-as-errors --seed 215378
```

Exact registration RED and GREEN commands:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --warnings-as-errors --seed 215378
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps bash -c 'mix format apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs && mix test apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs --warnings-as-errors --seed 215378'
```

### Task 6 final local qualification

Fresh complete owning SQL `56521` passed **173 Storage / 42 Runtime cases**,
zero failures, 106.3 / 49.5 seconds, seed `215378`, exit 0. Fresh final static/
unit `31529` checked all **19 candidate files**, compiled without warnings,
passed **Core 22 / Domains 11 / Storage 9 / Runtime 291 / Web 41 cases**,
zero failures (0.3 / 0.3 / 0.2 / 4.9 / 3.1 seconds), same seed, exit 0,
and reported **No cycles found**.

Actual independent `phase4_organization_spec_review` SPEC passed, followed by
separate `phase4_organization_quality_review` QUALITY, both zero actionable
P0–P2 findings. All 19 source/test SHA-256 hashes were unchanged before/after
each review and the parent final check. No production repair or Astra repair
attempt was needed. No new grant, migration, general authorization/Vault
policy, custody or capability change was made in Task 6.

Cleanup `95186` confirmed **zero generated test databases**, exit 0, then
stopped only the owned server. Roots `0026c5f71b6fc320f15ee45d`,
`bcb2053e1c4bd61b97625934`, `bfac084c84f712d829e66556`,
`128283b6e967192d3de1263c`, `1d59d9f2d084ce0c3c6623a5` and the owned
cluster's `postmaster.pid` were each verified absent, all six exit 0.
Only generated test databases/roots were cleaned by the test lifecycle;
no material user data was removed. The ignored private cluster is retained.
Task 6 is locally qualified; Task 7 and whole-phase acceptance remain pending.
E2E NOT RUN, final browser/release acceptance and publication still excluded.

The exact 19 source/test files plus plan and report were committed locally as
`4d6d82bcda34a5240ca1b482c4f23bc76b62da72`
(`feat(runtime): add knowledge organization APIs`, 21 files). The staged
inventory and whitespace check passed; post-commit worktree status was clean.
No merge, push, publication or deployment occurred.

Exact final SQL, static/unit and cleanup commands:

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs apps/singularity_storage/test/singularity/storage/postgres/tag_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/relationship_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/organization_repository_test.exs apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_integration_test.exs apps/singularity_runtime/test/singularity/runtime/organization_integration_test.exs --warnings-as-errors --seed 215378
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps bash -c 'mix format --check-formatted apps/singularity_runtime/lib/singularity/runtime/api.ex apps/singularity_runtime/lib/singularity/runtime/organization/operations.ex apps/singularity_runtime/lib/singularity/runtime/organization/authorizer.ex apps/singularity_runtime/lib/singularity/runtime/organization/dto.ex apps/singularity_runtime/lib/singularity/runtime/dto/organization_tag.ex apps/singularity_runtime/lib/singularity/runtime/dto/organization_resource.ex apps/singularity_runtime/lib/singularity/runtime/dto/organization_relationship.ex apps/singularity_runtime/lib/singularity/runtime/dto/organization_page.ex apps/singularity_domains/lib/singularity/domains/organization/repository.ex apps/singularity_domains/lib/singularity/domains/relationships/repository.ex apps/singularity_storage/lib/singularity/storage/postgres/organization_repository.ex apps/singularity_storage/lib/singularity/storage/postgres/relationship_repository.ex apps/singularity_runtime/test/singularity/runtime/organization_api_test.exs apps/singularity_runtime/test/singularity/runtime/organization_authorizer_test.exs apps/singularity_runtime/test/singularity/runtime/organization_operations_test.exs apps/singularity_storage/test/singularity/storage/postgres/organization_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/relationship_repository_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_runtime/test/singularity/runtime/organization_integration_test.exs && mix compile --warnings-as-errors && mix test apps/singularity_core/test/singularity/core/organization_page_query_test.exs apps/singularity_core/test/singularity/core/organization_page_test.exs apps/singularity_domains/test/singularity/domains/organization_test.exs apps/singularity_storage/test/singularity/storage/postgres/organization_cursor_test.exs apps/singularity_runtime/test/singularity/runtime/organization_api_test.exs apps/singularity_runtime/test/singularity/runtime/organization_authorizer_test.exs apps/singularity_runtime/test/singularity/runtime/organization_operations_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs apps/singularity_runtime/test/singularity/runtime/note_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_observability_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collections_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collection_routes_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_api_test.exs apps/singularity_web/test/singularity/web/notes_live_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --warnings-as-errors --seed 215378 && mix xref graph --format cycles --fail-above 0'
devenv shell -- bash .devenv/phase4-pg-command.sh psql -X --dbname=postgres --tuples-only --no-align --command="SELECT count(*) FROM pg_database WHERE datname LIKE 'singularity_test_%'"
```

### Task 7 reviewed boundary, RED and first GREEN

Task 7 is in progress, not locally accepted or whole-phase acceptance. The
reviewed detail keeps canonical Note writes at 1,048,576 bytes and gives only
the rendered NoteExport payload a separate 16,777,216-byte ceiling. Relative
links identify exact immutable logical destinations; no source files or bytes
are included. All required current source capabilities pass inside the
original request before any referenced selector/title/fragment hydration.
The completed DTO is validated before the existing ID-only success audit.

Initial design SPEC found one P2 conflict between UUID sorting and canonical
membership ordinal order. The repair retains caller/ordinal order, including
descending UUIDs and retained-member reordering. Subsequent design QUALITY
found two P2 issues: an appendix could be swallowed by unfinished fenced/HTML
contexts, and attachment natural-key uniqueness was missing. A bounded
read-only Astra `PROJECT_ARCHITECTURE` advisory recommended a conservative
dependency-free formatter scanner and the established natural-key invariant.
The first advisory handoff lacked its literal routing keys and was corrected
before inspection; this was not an implementation repair. Fresh SPEC then
separate QUALITY passed with zero actionable P0–P2 findings on design SHA-256
`7a9414fffa9ee9e37baef5325b21a0fd2c477e9022eeeec8e6792ae53c616bee` and plan SHA-256
`083f15cfab12b1a8868ea614aff44d841aca32965a05dce63fc49ac47a888466`.
Astra architecture advisory count is one; Astra recovery attempts remain zero.

For nonempty sets, raw HTML/autolinks/literal `<` outside proven column-zero
fences and ambiguous indented/container/inline/escaped triple-marker runs fail
closed. Recognized open fences receive only a proven matching closing run;
the original body remains an exact byte prefix. This is an explicit formatter
admission limitation, not a claim that rejected bodies are invalid Markdown.
Empty sets retain exact bytes, including BOM/line endings and those contexts.
The counting pass includes escapes and closers before output allocation.
The rendered ceiling is not a total BEAM heap bound; Runtime separately bounds
aggregate retained raw titles.

Initial unit `5007` passed formatting and warnings-as-errors compilation but
exited 2: **Runtime 26 cases / 23 failures**, 2.0 seconds, seed `215378`.
The initial Core failures mixed missing production behavior with noncanonical
uppercase hexadecimal fixture UUIDs, so they were not all accepted as RED.
Core harness repair 1 lowercased fixture UUIDs and added an exact constructor
characterization without removing assertions. Run `69258` had **40 cases /
39 failures**, 2.6 seconds, same seed, exit 2; its enormous missing-module
argument output was truncated, not a complete per-failure diagnostic record.
An additive module/function presence assertion made that diagnostic bounded.
Fresh `30814` had **40 cases / 39 explicit missing-renderer failures**, one
fixture characterization PASS, 2.5 seconds, exit 2. Runtime and Core behavioral
RED were thereby established, not silently reclassified as passing.

Initial production validation `84810` failed compilation before tests:
an opaque reference returned by `:binary.compile_pattern/1` could not be
injected from a module attribute. This is FAIL, not GREEN. Core Sol production
repair 1 compiles the quotable pattern list once per render and threads it
through the same counting/emission passes; all tests were retained. Fresh
`68188` passed formatting, warnings-as-errors compilation, **Core 40 /
Runtime 26 cases**, zero failures (16.2 / 5.7 seconds), same seed, exit 0.
Production Sol repair 1 PASS; failed repair rounds zero; Astra recovery zero.

The existing collection-route characterization `85950` ran **41 cases /
one failure**, 1.9 seconds, same seed, exit 2: its nonempty export still
assumed raw-body-only output without source authorization/resolution. The
necessary test-contract update permits hydration only for export, requires
fresh source authorization and exact context first, preserves forbidden reads
for the other seven routes, and replaces arbitrary citation fragment IDs with
actual content-derived canonical fragment fixtures. It retains the original
membership/version/scope/audit checks and adds order/pin/privacy checks.
Fresh `91335` passed this suite plus the new Runtime contracts: **67 cases,
zero failures**, 4.8 seconds, same seed, exit 0. No production repair was needed.

Independent local parser characterization initially showed why bare appendix
concatenation is unsafe. A manual closure prototype's first 14-vector runner
failed all 14 diagnostics because the sample omitted the ordinary citation
link while requiring two links; correcting the sample retained that assertion
and passed all 14. These prototypes were not implementation acceptance.
One attempted actual-runner tool script had a JavaScript quoting syntax error
before any file edit/execution and was corrected. Actual compiled Core output
`36664` then passed **41 vectors / zero failures**, exit 0: 23 accepted
outputs had a top-level Sources heading, exact ordered ordinary pinned links
and visible citation metadata outside code/HTML, with the exact original
prefix; 18 rejected contexts produced sanitized invalid errors and retained
empty-set byte identity. The established local `mdast-util-from-markdown`
parser was read-only, with no dependency change. This is CommonMark
characterization, not GFM UI, browser or E2E acceptance. E2E remains NOT RUN.

Exact first GREEN, necessary route characterization/repair and actual parser
commands (ignored parser scripts remain diagnostic artifacts, not product):

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps bash -c 'mix format apps/singularity_core/lib/singularity/core/note_markdown_sources.ex apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs apps/singularity_runtime/lib/singularity/runtime/notes/export.ex apps/singularity_runtime/lib/singularity/runtime/dto/note_export.ex apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs && mix compile --warnings-as-errors && mix test apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs --warnings-as-errors --seed 215378'
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix test apps/singularity_runtime/test/singularity/runtime/note_source_collection_routes_test.exs --warnings-as-errors --seed 215378
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps bash -c 'mix format apps/singularity_runtime/test/singularity/runtime/note_source_collection_routes_test.exs && mix test apps/singularity_runtime/test/singularity/runtime/note_source_collection_routes_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs --warnings-as-errors --seed 215378'
devenv shell -- bash -o pipefail -c 'elixir -pa _build/test/lib/singularity_core/ebin -pa _build/test/lib/jason/ebin .devenv/phase4-task7-ast.exs | node .devenv/phase4-task7-ast.mjs'
```

Owning static/unit `38406` passed six-file formatting verification,
warnings-as-errors compilation, **Core 91 / Domains 11 / Storage 9 / Runtime
317 / Web 44 cases**, zero failures (16.5 / 0.4 / 0.2 / 7.0 / 2.8 seconds),
seed `215378`, exit 0, and **No cycles found**. Existing export-controller
and source/organization contracts remain included.

The new actual Runtime integration draft was formatted without manual repair.
Fresh `80169` passed **26 cases, zero failures**, 30.8 seconds, same seed,
exit 0, comprising the existing 13-case authorization suite and 13 new export
cases. Database/root: `singularity_test_fa802e1a0a3412e62ae462a1` /
`/tmp/singularity/integration/fa802e1a0a3412e62ae462a1`; private server stopped.
This uses real OperationScope, Authorize, IdentityRepository, RequestRepo,
ScopedRepo, canonical repositories, permanent grants and **real AuditSink**.
The established Custodian alone remains an integration adapter, not live
custody. It proves exact mixed descending membership and all four locators,
historical metadata after new heads, source tombstone/restore, current
capability and both-epoch denial before referenced SQL, public facade/Save
reordering with old version bytes/rows untouched, empty byte identity, a
canonical 1 MiB body, raw/escaped budget and formatter failures without audits.
The read-only observer delegates real results and checks the same backend,
both GUCs and existing authorization ShareLock at each step; it is not an
interleaving/concurrency proof. New SQL harness/production repair counts zero.

Independent actual `phase4_organization_spec_review` SPEC passed with zero
actionable P0–P2 findings and identical seven-file/design/plan hashes before
and after. Its final pending-SQL limitation preceded the parent's completion
update; the actual parent result above is the SQL evidence, not an inferred
review result. The native separate QUALITY resumption/fresh spawn encountered
the agent-thread capacity limit, without starting a review or changing files.
A fresh isolated Sol/high read-only Codex reviewer is running instead, with
no inherited implementation/SPEC context, frozen seven-file hashes, no
delegation, writes, tests or database operations. This preserves independent
QUALITY rather than treating capacity as a passing review or replacing it
with implementation self-review. A pre-existing ignored user configuration
key warning was reported; no user configuration was changed.

Exact owning unit/static and first actual SQL commands:

```sh
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps bash -c 'mix format --check-formatted apps/singularity_core/lib/singularity/core/note_markdown_sources.ex apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs apps/singularity_runtime/lib/singularity/runtime/notes/export.ex apps/singularity_runtime/lib/singularity/runtime/dto/note_export.ex apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collection_routes_test.exs && mix compile --warnings-as-errors && mix test apps/singularity_core/test/singularity/core/note_values_test.exs apps/singularity_core/test/singularity/core/note_source_references_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs apps/singularity_core/test/singularity/core/organization_page_query_test.exs apps/singularity_core/test/singularity/core/organization_page_test.exs apps/singularity_domains/test/singularity/domains/organization_test.exs apps/singularity_storage/test/singularity/storage/postgres/organization_cursor_test.exs apps/singularity_runtime/test/singularity/runtime/organization_api_test.exs apps/singularity_runtime/test/singularity/runtime/organization_authorizer_test.exs apps/singularity_runtime/test/singularity/runtime/organization_operations_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs apps/singularity_runtime/test/singularity/runtime/note_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_observability_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collections_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collection_routes_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs apps/singularity_web/test/singularity/web/notes_live_test.exs apps/singularity_web/test/singularity/web/note_export_controller_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --warnings-as-errors --seed 215378 && mix xref graph --format cycles --fail-above 0'
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps mix format apps/singularity_runtime/test/singularity/runtime/note_markdown_export_integration_test.exs
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_export_integration_test.exs --warnings-as-errors --seed 215378
```

Complete owning SQL `21537` passed **173 Storage / 55 Runtime cases**,
zero failures, 109.3 / 75.3 seconds, seed `215378`, exit 0. Its allocated
database/root were `singularity_test_2bcb8def88d71a8222ac5557` /
`/tmp/singularity/integration/2bcb8def88d71a8222ac5557`; private server stopped.
Fresh final static/unit `76859` verified all seven candidate files, compiled
without warnings, passed **Core 91 / Domains 11 / Storage 9 / Runtime 317 /
Web 44 cases**, zero failures (15.0 / 0.4 / 0.2 / 6.0 / 2.9 seconds),
same seed, exit 0, and reported **No cycles found**.

Separate actual QUALITY ran in fresh ephemeral read-only Sol/high thread
`01a127cb-7f53-7463-b89e-74ab00861cc0`, process `13307`, exit 0. It passed
with zero actionable P0–P2 findings and the exact seven-file/design/plan hashes
unchanged before and after. One guessed NoteValidation file lookup failed;
corrected repository discovery/read completed. This inspection error and the
ignored user configuration warning are not production failures or test passes.
No reviewer edited files or ran tests/DB/services. Parent verified the same
seven source/test hashes after both reviews and final tests. The reviewed
design/plan hashes precede only the qualification checkbox update.

Cleanup `83351` confirmed **zero generated test databases**, exit 0, and
stopped only the owned private server. Both exact roots above and
`.devenv/phase4-pg.2P68Dm/postmaster.pid` were individually verified absent,
each exit 0. Only generated test data were cleaned by the test lifecycle; no
material user data were removed. The ignored private cluster and parser/
review diagnostic artifacts are retained. Task 7 source is locally qualified
and ready for its exact scoped local commit; Task 9 and whole-phase acceptance
remain pending. E2E remains NOT RUN. No Vault file, source-custody primitive,
capability, grant, migration, Api signature, browser assertion or workflow was
changed.

Exact complete owning SQL, final static/unit and cleanup commands:

```sh
devenv shell -- bash .devenv/phase4-pg-command.sh mix singularity.test.integration apps/singularity_storage/test/singularity/storage/knowledge_grants_test.exs apps/singularity_storage/test/singularity/storage/knowledge_rls_test.exs apps/singularity_storage/test/singularity/storage/postgres/knowledge_link_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_sources_test.exs apps/singularity_storage/test/singularity/storage/postgres/note_mutation_receipts_test.exs apps/singularity_storage/test/singularity/storage/postgres/tag_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/relationship_repository_test.exs apps/singularity_storage/test/singularity/storage/postgres/organization_repository_test.exs apps/singularity_runtime/test/singularity/runtime/note_authorization_integration_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_integration_test.exs apps/singularity_runtime/test/singularity/runtime/organization_integration_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_export_integration_test.exs --warnings-as-errors --seed 215378
devenv shell -- env MIX_ENV=test MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps bash -c 'mix format --check-formatted apps/singularity_core/lib/singularity/core/note_markdown_sources.ex apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs apps/singularity_runtime/lib/singularity/runtime/notes/export.ex apps/singularity_runtime/lib/singularity/runtime/dto/note_export.ex apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collection_routes_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_export_integration_test.exs && mix compile --warnings-as-errors && mix test apps/singularity_core/test/singularity/core/note_values_test.exs apps/singularity_core/test/singularity/core/note_source_references_test.exs apps/singularity_core/test/singularity/core/note_markdown_sources_test.exs apps/singularity_core/test/singularity/core/organization_page_query_test.exs apps/singularity_core/test/singularity/core/organization_page_test.exs apps/singularity_domains/test/singularity/domains/organization_test.exs apps/singularity_storage/test/singularity/storage/postgres/organization_cursor_test.exs apps/singularity_runtime/test/singularity/runtime/organization_api_test.exs apps/singularity_runtime/test/singularity/runtime/organization_authorizer_test.exs apps/singularity_runtime/test/singularity/runtime/organization_operations_test.exs apps/singularity_runtime/test/singularity/runtime/note_reads_test.exs apps/singularity_runtime/test/singularity/runtime/note_mutations_test.exs apps/singularity_runtime/test/singularity/runtime/note_sources_test.exs apps/singularity_runtime/test/singularity/runtime/note_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_observability_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collections_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_collection_routes_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_test.exs apps/singularity_runtime/test/singularity/runtime/note_source_resolution_api_test.exs apps/singularity_runtime/test/singularity/runtime/note_markdown_source_export_test.exs apps/singularity_web/test/singularity/web/notes_live_test.exs apps/singularity_web/test/singularity/web/note_export_controller_test.exs apps/singularity_web/test/singularity/architecture/knowledge_phase1_contract_test.exs apps/singularity_web/test/singularity/architecture/notes_scope_contract_test.exs --warnings-as-errors --seed 215378 && mix xref graph --format cycles --fail-above 0'
devenv shell -- bash .devenv/phase4-pg-command.sh psql -X --dbname=postgres --tuples-only --no-align --command="SELECT count(*) FROM pg_database WHERE datname LIKE 'singularity_test_%'"
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
