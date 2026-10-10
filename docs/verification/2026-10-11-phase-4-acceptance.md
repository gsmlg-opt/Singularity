# Phase 4 versioned sources and organization qualification

## Current status

**IN PROGRESS — NOT ACCEPTED.** E2E is deferred and NOT RUN, not a passing
browser/release gate. No Phase 4 implementation deliverable is claimed complete.
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
