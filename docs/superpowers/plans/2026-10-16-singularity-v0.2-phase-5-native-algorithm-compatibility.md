# Native V3 Algorithm-Metadata Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept unchanged native bootstrap algorithm metadata in V3 knowledge preflight while retaining exact two-literal validation and all native saga obligations.

**Architecture:** Extend only one knowledge-restore scalar predicate; preserve source/wire values and all crypto/custody/bootstrap behavior. Add structural contracts using the existing authenticated staging harness, then qualify the unchanged real native saga without its temporary checkpoint trace.

**Tech Stack:** Elixir1.18.4 / OTP28.5.0.3, Ecto/PostgreSQL17.10, ExUnit, existing private Native integration harness.

---

Design:
`docs/superpowers/specs/2026-10-16-singularity-v0.2-phase-5-native-algorithm-compatibility-design.md`.
Continuing authority selects the recommended in-scope option automatically;
independent document/source reviews and required tests remain mandatory.
This supplements Task6 of the 2026-10-15 native V3 saga plan, not later-task
dependencies. No E2E, publication, production or Vault semantic change.

## Task A: Review the forward amendment and seal additive source GO

**Files:** the two new design/plan documents; parent-owned ignored receipts and
source/status manifests only. Old formal documents and seals remain unchanged.

- [ ] Parent self-review: verify source chain, exact two literals, preservation,
  actual RED/GREEN commands and no placeholder or scope ambiguity.
- [ ] Actual independent Sol SPEC reviews both complete documents; resolve
  concrete findings, preserving prior versions and evidence.
- [ ] NEW distinct fresh Sol QUALITY reviews the corrected actual documents.
- [ ] Parent records forward SourceGO after both reviews CLOSED/PASS. Capture
  current HEAD/index/dirty paths and unchanged baselines, adding the two
  production/test paths named below without broadening frozen scope. Do not run
  the historical six-path status guard after adding these documents/paths.
- [ ] Assign one fresh Sol test author ONLY the preflight test file; Astra remains
  quiescent until causal RED has naturally finished and parent issues the
  reviewed repair handoff. Parent owns receipts/Native/Git. All writers preserve
  others' work and report CLOSED before execution.

## Task B: Add exact algorithm structural contracts before production changes

**Modify/test:** `apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs`.
No production changes yet. Reuse existing private helpers and unchanged
`KnowledgeBackupFixtures`; these are structural tests, not genuine custody proof.

- [ ] Add two independently named positives before the first existing test,
  preserving every old test:

```elixir
for algorithm <- ["aes_256_gcm", "aes-256-gcm"] do
  test "V3 stages exact established owner algorithm metadata #{algorithm}" do
    algorithm = unquote(algorithm)

    with_fixture(fn fixture, storage ->
      before = @fixtures.canonical_rows(fixture)

      expected =
        put_rows(
          before,
          "core.vault_key_versions",
          Enum.map(before["core.vault_key_versions"], &Map.replace!(&1, "algorithm", algorithm))
        )

      bundle = authenticated(fixture, rows: fn _rows -> expected end)

      assert {:error, :algorithm_qualified} =
               owner_transaction(fn ->
                 assert {:ok, staged} = stage(bundle, storage)
                 assert {:ok, summary} = validate(staged, bundle.cut)
                 assert summary.counts == Map.new(expected, fn {table, rows} -> {table, length(rows)} end)

                 for schema <- LogicalSchemaV3.all(),
                     do: assert(staged_rows(schema) == expected[schema.table])

                 {:ok, schema} = LogicalSchemaV3.fetch_table("core.vault_key_versions")
                 assert Enum.map(staged_rows(schema), & &1["algorithm"]) == [algorithm]
                 MigrationRepo.rollback(:algorithm_qualified)
               end)

      assert @fixtures.canonical_rows(fixture) == before
      assert_no_temp_tables()
      cleanup_stages(storage)
      assert_no_publication(storage)
    end)
  end
end
```

- [ ] Add independently named malformed variants and adjacent-table boundaries:

```elixir
for algorithm <- ["", "unknown", "aes-128-gcm", "AES-256-GCM", "aes-256-gcm ", "aes_256_gcm "] do
  test "V3 rejects unestablished owner algorithm #{inspect(algorithm)}" do
    algorithm = unquote(algorithm)

    with_fixture(fn fixture, storage ->
      reject_rows(fixture, storage, fn rows ->
        put_rows(
          rows,
          "core.vault_key_versions",
          Enum.map(rows["core.vault_key_versions"], &Map.replace!(&1, "algorithm", algorithm))
        )
      end)
    end)
  end
end

for table <- ["core.domain_key_versions", "core.domain_dedup_key_wrappers", "content.asset_key_envelopes"] do
  test "V3 keeps hyphenated algorithm metadata denied in #{table}" do
    table = unquote(table)

    with_fixture(fn fixture, storage ->
      reject_rows(fixture, storage, fn rows ->
        put_rows(rows, table, Enum.map(rows[table], &Map.replace!(&1, "algorithm", "aes-256-gcm")))
      end)
    end)
  end
end
```

These names inspect only fixed test-owned algorithm literals, never rows, keys or
user content. No new assertion prints native source metadata.

- [ ] Strengthen the existing `reject_bundle/5` success-match to require
  `retryable?: false` in its existing Error pattern. Keep its expected code,
  empty-details, queryable-transaction, source equality, no-temp, no-stage and
  no-publication assertions byte-for-byte otherwise:

```elixir
assert {:error, %Error{code: ^expected_code, retryable?: false, details: %{}} = error} = result
```

- [ ] Author reports exact file diff/hash, unchanged production hash
  b05f0b5e61be7ba5a2c3ae4da6bbcfc292627fcc73ca689978294fd4b0bf8ff9,
  no old-test/assertion deletion, all commands CLOSED.
- [ ] Parent exclusively formats only this test, runs ordinary private-PG
  residual check, seals actual candidate, and runs the COMPLETE owner RED:

```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs --seed 215378 --warnings-as-errors
```

Expected: ONLY the new exact native hyphen positive fails at stage with
backup_invalid on the old predicate; all other tests pass. If another failure
occurs, diagnose it rather than claiming this causal RED. Save raw/exit/counts
and EMPTY post-check; no smaller case filter or fabricated compile RED.

## Task C: Apply the bounded repair and remove the temporary probe

**Modify:** `apps/singularity_storage/lib/singularity/storage/backup/knowledge_preflight.ex`.
**Modify only existing Task6 insertion regions for trace removal:**
`apps/singularity_runtime/test/support/knowledge_backup_restore_fixture.ex`,
`apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs`.

- [ ] After actual causal RED, parent issues Astra the reviewed four-path handoff
  (test file read-only during this step). Sol author is CLOSED. Same evidenced
  SOL_IMPASSE gate remains; keep diagnostic counts separate from code repairs.
- [ ] Replace exactly one SQL predicate and no adjacent rule:

```elixir
{"core.vault_key_versions",
 "generation>0 AND state IN ('pending','active','retired') AND algorithm IN ('aes_256_gcm','aes-256-gcm')"},
```

- [ ] Remove the temporary fixture probe by restoring the direct call:

```elixir
result = Restorer.import(context.restorer, repo, input)
```

Remove its KnowledgePreflight alias, @checkpoints/@checkpoint_names,
checkpoint_label/1, observe_import_checkpoints/2, with_checkpoint_patterns/2 and
checkpoint_loop/4. In the owner remove only the checkpoint label clause and
restore diagnostic collection limit12, as in the archived diag2 baseline.
Keep all native result/hook/authentication observations and every assertion.
Do not change genuine bootstrap/source metadata or weaken any expected rows.
The Task5 fixture and owner inverse filters must still match both accepted
Task5 archives exactly. Oracle remains unchanged.

- [ ] Report diff/hash, frozen/prerequisite preservation, no trace primitives in
  these Task6 helpers, all commands CLOSED; root seals/executes after author
  handoff. No production semantic change beyond the one predicate.

## Task D: Qualify repair and actual Task6, then advance

- [ ] Parent exclusively formats the changed files; ordinary-PG residual EMPTY;
  capture new source/status seal and exact preservation checks.
- [ ] Execute complete preflight and V3 import owners:

```sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs --seed 215378 --warnings-as-errors
```

Expected GREEN, including established underscore compatibility, new native
hyphen positive and all malformed/adjacent negatives. This is structural/import
qualification, not full native runtime proof.

- [ ] Execute complete native owner plus retained public search/restore gate:

```sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_search_privacy_test.exs apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs --seed 215378 --warnings-as-errors
```

Expected GREEN. UUID positive and mutable mismatch witness retain full actual
source history/pre-rewrap equality, exact algorithm string, real rewrap/typed
plaintext/custody, five retained original bytes, current public search,
deterministic stale extraction recovery and no duplicate work. Downstream
failures remain failures and enter diagnosis; this amendment predicts no
unexecuted success.

- [ ] Every Native/formatter/ordinary-PG LIVE interval is exclusive: all other
  actors/commands CLOSED, only exact-session empty polls and commentary until
  natural close. Capture full safe raw, exit/count/duration, post0 EMPTY,
  final source guard and unchanged frozen56/prerequisite26/controls49/common25.
  Never inspect the credential-bearing historical raw.
- [ ] Actual combined source SPEC then NEW distinct fresh QUALITY covers this
  repair AND Task6. No self-certification or probe-loaded acceptance.
- [ ] Record minimal compatibility patch explicitly, exact tests/counters,
  unchanged Vault behavior and E2E NOT RUN. Update ongoing Task11 evidence.
- [ ] After actual Task6 acceptance continue Task7 of the existing plan.
  Preserve Task13's combined qualification/local-commit boundary; commit only
  owned reviewed paths then, with no automatic merge/push/version/release.
  All complete permitted README checks remain phase-acceptance prerequisites.

Task16 strict BOTH/ALL leases remains UNSATISFIED/UNWAIVED/BLOCKED_DESIGN;
this amendment neither waives nor repairs it.
