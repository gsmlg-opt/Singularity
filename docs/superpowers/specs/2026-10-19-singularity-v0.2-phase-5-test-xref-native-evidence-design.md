# Task16 fixed native-evidence test leaf — design draft1

Private design only. NOT implementation GO, Task16 acceptance, Phase5 acceptance,
release qualification or permission to run E2E. The parent owns promotion and all
runtime execution. Governing authority is current AGENTS continuing authorization;
Vault, production-data, publication and provenance restrictions are unchanged.

## Problem and decision

Required test xref gate189 genuinely failed because the existing restore Oracle
orchestrates KnowledgeBackupRestoreFixture while that Fixture calls four Oracle
native-evidence primitives. The exact source pins, nine reverse calls, original
introduction, RED and own EMPTY post are recorded in sibling
`.devenv/phase5-task16-test-xref-diagnosis1.md` and incorporated here unchanged.

Choose a fixed test-only `KnowledgeRestoreNativeEvidence` leaf. Move exactly four
existing public function bodies and copy exactly four private helper clauses,
retaining every expression. Preserve Oracle's public API as direct wrappers and
change only the nine Fixture receivers plus two aliases. Do not split unrelated
orchestration, add configurable dispatch, use dynamic apply to conceal a cycle,
exclude support from test compilation or alter any original assertion.

The resulting static edges are:

```text
KnowledgeRestoreOracle ──> KnowledgeBackupRestoreFixture ──> NativeEvidence
          └─────────────────────────────────────────────> NativeEvidence
NativeEvidence ──> existing Storage adapter / PathGuard / Core.ObjectRef only
```

The leaf must have no Oracle/Fixture alias, call, struct, macro or compile-time
dependency. Existing Mix task dynamic entry into Oracle is unrelated test-module
loading infrastructure and remains byte-identical, not a pattern for this repair.

## Exact ownership

After independent design reviews and parent promotion, source ownership is only:

- Modify `apps/singularity_runtime/test/support/knowledge_restore_oracle.ex`.
- Modify `apps/singularity_runtime/test/support/knowledge_backup_restore_fixture.ex`.
- Create `apps/singularity_runtime/test/support/knowledge_restore_native_evidence.ex`.
- Create `apps/singularity_runtime/test/singularity/runtime/knowledge_restore_native_evidence_test.exs`.

Canonical documentation targets are:

- `docs/superpowers/specs/2026-10-19-singularity-v0.2-phase-5-test-xref-native-evidence-design.md`.
- `docs/superpowers/plans/2026-10-19-singularity-v0.2-phase-5-test-xref-native-evidence.md`.

Private attribution/receipt successors are separately parent-owned. No AGENTS,
production, migration, dependency, configuration, existing test or shared storage
support edit is authorized. Test support already compiles only in MIX_ENV=test;
`apps/singularity_runtime/mix.exs` remains unchanged. No production grant or
capability, custody, ResourceOwner, timeout, cancellation or native ownership
change is included.

## Exact extraction contract

Baseline whole Oracle is
`5a2785715058945ab43b544feb108e9d91f92ff56bde4f0aec606382052ab3e5`;
baseline whole Fixture is
`60485cecc8c4897cb5926b8af72a6a6a5e44a62f5392e939f1b409776f2481a4`.
Both were already accepted Task12 source; do not replace their historical pins.

Copy these Oracle definition slices including two-space indentation and final LF:

| Definition | Original lines | Bytes | SHA256 |
| --- | --- | ---: | --- |
| `original_inventory!/1` | 11–28 | 590 | `deb03c9d19153394a86093d6055ce8b34b51b0501c13363e57b2e14fb0abcc7d` |
| `reference_witness!/2` | 36–89 | 1885 | `28d93219e9d2634d70d93f50ef30d2e4d4901b817c496bd2aa8953b2505baaf3` |
| `inventory_handoff/1` | 165–174 | 328 | `1f8e92cd48a4bbd1816a9707970bcfb3b199247517c0ab69cc2b95e6a8ac1717` |
| `replace_ciphertext!/3` | 177–240 | 2005 | `05c0c415a54ba170432c504989c3fc6d858717c3ce1c008835f4ff9b858548f8` |
| four helper clauses | 741–744 | 245 | `a491b2cfc54b62dc578209b899723a2a54ab5ae49b59e2db9b3d7d5a0262bb2e` |

Create the leaf with only `defmodule Singularity.Runtime.KnowledgeRestoreNativeEvidence do`,
`@moduledoc false`, these five exact slices separated by blank lines, and `end`.
The existing function-local aliases are sufficient. No body adaptation is needed.
The four private clauses are `expect_ok!/2` success/error and `require!/2`
true/false. Their Oracle copies remain untouched for other callers.

Add a single fixed Oracle alias and use these explicit wrappers; retain the
surrounding old comments and every other old byte:

```elixir
  alias Singularity.Runtime.KnowledgeRestoreNativeEvidence

  def original_inventory!(rows), do: KnowledgeRestoreNativeEvidence.original_inventory!(rows)

  def reference_witness!(root, entry),
    do: KnowledgeRestoreNativeEvidence.reference_witness!(root, entry)

  def inventory_handoff(value), do: KnowledgeRestoreNativeEvidence.inventory_handoff(value)

  def replace_ciphertext!(root, entry, replacement) when is_binary(replacement),
    do: KnowledgeRestoreNativeEvidence.replace_ciphertext!(root, entry, replacement)
```

Formatter spelling may split a wrapper line but cannot alter its body semantics.
Pin actual formatted literals and require exact whole-source inverse recovery.
No `defdelegate` guard drift, input validation, error/message change, fallback,
extra API or broadened accepted input is permitted.

In Fixture replace `KnowledgeRestoreOracle` with `KnowledgeRestoreNativeEvidence`
in exactly its two alias declarations and nine direct calls: two handoffs at
401/407, inventory935, replace1160, witnesses1206/1244/1270/1312/1361 in baseline.
No other Fixture body changes. Oracle's five Fixture orchestration calls remain.

## Native semantics and independent custody remain

`original_inventory!` still maps literal rows independently of exporter/project/
prepare, preserving sort, position and every field. `inventory_handoff` retains
the exact fixed selected fields. `reference_witness!` still opens actual opaque
UUID and canonical relative references using full native lookup context, reads
through the real adapter, validates actual SHA256 and sizes and regular-file
physical identity. `replace_ciphertext!` still requires one existing0400 file,
equal-length foreign bytes, safe path checks, pwrite and actual file sync, finally
restores mode and requires unchanged inode, mode and length.

The leaf may witness synthetic local ciphertext in its new pure unit tests.
Those bytes are explicitly not AEAD/native publication or live custody proof.
Original live backup/restore and standalone tests continue to establish genuine
native publication, rewrap, worker/extraction, source/search and restore behavior.
All old canonical/native/parked-installation assertions, ALL-issued cleanup,
startup, ordinary native errors, first-close/replacement semantics, ResourceOwner
custody and cleanup are retained; no existing test assertion is edited.

## Test-first evidence and new functional matrix

Keep actual189 FAIL1 / own190 EMPTY0 as the causal cycle RED. Add new leaf tests
first, execute their whole file and preserve absent-module RED before extraction.
It is a separate functional RED, not a replacement for189. Tests use async ExUnit
owned `:tmp_dir` roots and fixed low-level fixture bytes, no DB/process-global
configuration, new grants, runtime startup or fabricated native publication.

Required deterministic functional cases are:

1. Literal inventory sorting and all mapped fields; direct Oracle wrapper parity.
2. Invalid non-existing classification atom rejection with unchanged input.
3. Exact handoff projection and removal of unrelated owner/top-level canaries;
   direct Oracle wrapper parity; missing required top-level field raises KeyError.
4. Actual UUID/canonical adapter witnesses agree, with exact bytes/hash/size and
   physical identity; direct Oracle wrapper parity.
5. Wrong expected size and wrong expected hash fail without changing file bytes,
   inode or mode; test existing error type/message rather than adding validation.
6. Equal-length foreign replacement changes only bytes/hash, preserving actual
   inode, size and0400 mode; check exact returned before/after evidence. Exercise
   Oracle replacement wrapper independently on a separate untouched owned file.
7. Same bytes, wrong-length bytes and non0400 mode are each rejected with all
   file bytes/inode/mode preserved. Non-binary replacement preserves guarded
   FunctionClauseError behavior in both public paths.

Keep fixtures readable after rejected tests; no cleanup callback is credited as
production/ResourceOwner cleanup. Do not overconstrain arbitrary malformed row
maps that the original implementation never validated. Source inverses plus
functional cases establish preservation; xref alone cannot do so.

## Strict source attribution and successor guard

Preserve the immutable33 manifest, SHA256
`62aca10911d98a035aee0894eee5a26b88067a9495fd2296cd925611b277973d`,
and all33 raw candidate pins. Extend a NEW successor manifest with exactly six
paths above: two newly modified tracked support sources, two new sources/tests,
two canonical docs. Expected successor status39 / tracked21 is checked against
actual unmodified Git output, never fabricated or filtered. Parent must resolve
an unexpected status before writing the successor, not silently expand scope.

The new strict guard must check current whole Oracle/Fixture pins before any
attribution, and four exact old→wrapper replacements plus one Oracle alias
addition, two Fixture alias replacements plus nine call receiver replacements.
Record full before/after literals, byte offsets, both context edges, occurrence
counts, body hashes and whole hashes; inverse must recover both whole baselines.
The new leaf must contain each four old function bodies and helper slice exactly
once and only the fixed module envelope. Require zero remaining Fixture→Oracle
references and no leaf→Oracle/Fixture edges.

Run inverse counterproofs for missing/altered/duplicate/relocated replacements,
changed left/right context, unrelated old bytes and unauthorized outside edits;
each must fail at its intended strict check. Formatting is not a blanket inverse.
An entire-source SHA is necessary in addition to literal presence checks.

A new independently reviewed guard may strictly derive the actual
`.devenv/phase5-task16-c13-read-contract-guard.sh` / IO-Q1 guard with only reviewed
status/tracked-array successors and source attribution before old Task12 pin
checks, or implement the same exact checks directly if simpler. It must retain
all existing source/formatter/stage inverses, profile checks, owned0 checks and
original56 handling (54 raw unchanged plus two accepted exact inverses). Do not
rewrite historical guards, manifests, Task11/12 handoffs or receipts. Do not
intercept Git/xref/process status, mark failures successful, add allowlist globs,
hide extra source edits, or claim an old guard accepted changed raw bytes.

## Verification scope and qualification boundary

The parent serializes each VM/SQL owner command and its actual own EMPTY post.
Capture exact argv/environment/source manifest, natural footer/exit, complete
private0600 raw, counts/warnings/errors and post timestamps. All tests retain
their existing seed215378 and warnings-as-errors; no timeout or ExUnit tags move.

Required affected replays are the new pure leaf file (RED, GREEN and repeat),
full restore Mix-task unit file, original whole logical-V3 exporter + native-text
backup/restore + knowledge backup/restore integration cohort, original standalone
`mix singularity.test.restore` with no args, existing affected architecture and
pure whole harness cohorts, global format, test/dev warnings-as-errors compile
and test/dev zero-cycle xref. Exact commands are in the sibling plan. Do not
replace a full original native gate by filtered tests. Preserve intentional SQL
negative-path logs and previously observed migration redefinition warnings as
classified evidence, not a false warning-free claim.

Do not blindly rerun all19 Task16 gates. The unchanged33 raw pins, prior source
reviews and18 previously passing gate records remain explicitly bounded evidence
for those exact inputs; affected successor gates provide incremental credit for
this test-only change. The final packet must identify each retained versus fresh
gate and explain its applicability, with no inference of a full new-manifest run
from old receipts.189 remains FAIL historically.117 runtime FAIL,133 fixture FAIL
and lifecycle001 transport FAIL also remain. Tmpfs stays volatile; fsync-on does
not prove durable power-loss recovery. E2E remains NOT RUN.

Independent DESIGN SPEC then distinct DESIGN QUALITY precede implementation.
After source work, fresh SOURCE SPEC then distinct QUALITY inspect actual bytes,
strict inverses, tests and source guard; parent closes affected gates and final
evidence before any bounded Task16 readiness decision. No reviewer is credited
for broader source coverage than actually read. A worker stops at its assigned
handoff, not by overriding parent continuing authority after completed gates.
