# Owned-SQL Algorithm-Metadata Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Admit both established owner algorithm literals through actual V3 destination validation without changing source metadata, crypto, permissions or any other predicate.

**Architecture:** Add a fail-closed exact-function forward migration following the existing storage-reference repair pattern. Prove the defect with single-variable structural full imports, preserve the complete owned-function catalog and then rerun the real native saga without tracing.

**Tech Stack:** Elixir1.18.4, OTP28.5.0.3, Ecto/PostgreSQL17.10, ExUnit, existing private Native integration harness.

---

Design: docs/superpowers/specs/2026-10-16-singularity-v0.2-phase-5-owned-algorithm-compatibility-design.md.
This supplements Task6 of the 2026-10-15 V3 saga and the preceding preflight
algorithm amendment. Continuing authority selects subagent-driven execution.
Root owns Native/format/SQL/receipts/Git. E2E NOT RUN; Task16 remains unwaived.

## Task A: Independent document review and additive source GO

Files: only the two new documents and root-owned ignored receipts/seals.

- [ ] Root self-reviews exact current migration ceiling20261011000800, one
  table-specific predicate, existing native failure evidence, preservation,
  commands and complete implementation contracts below. No placeholders.
- [ ] Actual fresh Sol SPEC reviews both complete documents; resolve findings.
- [ ] NEW distinct fresh Sol QUALITY reviews the corrected actual documents.
- [ ] Root records additive SourceGO for exactly the three new source/test paths
  below plus removal of the existing temporary Task6 probe. Do not rewrite old
  GO, migration, manifest or failure receipts.
- [ ] Archive the committed1693-line LogicalV3Import baseline before edits using
  apply_patch and cmp0. Seal all other source/frozen/prerequisite paths.
- [ ] Assign one fresh Sol author the test file only. Production migration does
  not exist until actual causal RED has completed naturally.

## Task B: Causal structural import contracts before production edits

Modify only apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs.
Preserve every old test and assertion. These fixtures use explicitly labelled
FixtureCrypto and are structural/import proof, never native custody proof.

- [ ] Add this option handling immediately before existing large? handling in
  prepare_source/2. The default nil leaves all old source construction unchanged:

~~~elixir
if algorithm = Keyword.get(options, :vault_algorithm) do
  owner(fn ->
    assert %{num_rows: 1} =
             sql("UPDATE core.vault_key_versions SET algorithm=$1", [algorithm])
  end)
end
~~~

- [ ] Add two independently named positives before the first old test:

~~~elixir
for algorithm <- ["aes_256_gcm", "aes-256-gcm"] do
  @tag :tmp_dir
  test "structural V3 full import preserves established owner algorithm #{algorithm}",
       %{tmp_dir: tmp_dir} do
    algorithm = unquote(algorithm)
    portable = Path.join(tmp_dir, "algorithm")
    File.mkdir!(portable)
    File.chmod!(portable, 0o700)
    source = prepare_source(portable, vault_algorithm: algorithm)

    with_destination(source, fn destination ->
      assert {:ok, %Restorer.Imported{} = imported} = import_bundle(source, destination)
      assert imported.cut.logical_version == 3
      assert Enum.map(source.rows["core.vault_key_versions"], & &1["algorithm"]) == [algorithm]
      assert owner_value(fn -> rows("SELECT algorithm FROM core.vault_key_versions") end) ==
               [[algorithm]]
      assert_complete(source, destination)
      before = snapshot(destination.object_root)
      assert {:ok, ^imported} = import_bundle(source, destination, ReadOnlyStorage)
      assert snapshot(destination.object_root) == before
      assert_complete(source, destination)
    end)
  end
end
~~~

- [ ] Add one direct owned-SQL deny contract; all values are fixed test literals:

~~~elixir
test "owned V3 graph keeps malformed and adjacent algorithm metadata denied",
     %{source: source} do
  vectors =
    Enum.map(
      ["", "unknown", "aes-128-gcm", "AES-256-GCM", "aes-256-gcm ", "aes_256_gcm "],
      &{"core.vault_key_versions", &1}
    ) ++
      Enum.map(
        ["core.domain_key_versions", "core.domain_dedup_key_wrappers",
         "content.asset_key_envelopes"],
        &{&1, "aes-256-gcm"}
      )

  with_destination(source, fn destination ->
    assert {:ok, %Restorer.Imported{}} = import_bundle(source, destination)
    before = snapshot(destination.object_root)

    for {table, algorithm} <- vectors do
      assert {:error, :algorithm_rejected} =
               owner(fn ->
                 assert %{num_rows: count} =
                          sql("UPDATE #{table} SET algorithm=$1", [algorithm])
                 assert count > 0

                 assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                          Singularity.Storage.SafeSQL.query(
                            MigrationRepo,
                            "SELECT audit.assert_knowledge_restore_graph($1)",
                            [dump(@ids.vault_id)]
                          )

                 MigrationRepo.rollback(:algorithm_rejected)
               end)

      assert snapshot(destination.object_root) == before
    end

    assert_complete(source, destination)
  end)
end
~~~

Table names above come only from the fixed literal allowlist, never callers.
Rollback is required after the deliberate PostgreSQL error; do not issue more
SQL in that aborted transaction. No key material or row content is printed.

- [ ] Author checks additive inverse against the archived baseline and reports
  exact hashes and CLOSED. No Native, format, SQL, Git or receipt writes.
- [ ] Root exclusively formats only this test, then ordinary-PG post-check;
  seals exact source/status and runs the COMPLETE owner:

~~~sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs --seed 215378 --warnings-as-errors
~~~

Expected:26 executed25PASS1FAIL. Only the new hyphen full-import positive fails
with nonretryable backup_invalid on current owned SQL. Underscore positive,
all23 old cases and direct negative contract pass. If other results occur,
diagnose; do not call missing-code or compilation failure a causal RED.
Save safe raw, exact counts/exit/duration and EMPTY post; all sessions CLOSED.

## Task C: Exact forward repair, upgrade contracts and probe removal

Create apps/singularity_storage/priv/repo/migrations/20261016000100_knowledge_restore_algorithm_metadata.exs.
Default Sol owns only this file, the dedicated new test below and the existing
Task6 probe removal regions. TaskB test is read-only during this step.

- [ ] After root hands off actual causal RED, add this complete migration:

~~~elixir
defmodule Singularity.Storage.Migrations.KnowledgeRestoreAlgorithmMetadata do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DO $migration$
    DECLARE
      definition text := pg_catalog.pg_get_functiondef(
        'audit.assert_knowledge_restore_graph(uuid)'::pg_catalog.regprocedure);
      old_predicate constant text := $predicate$EXISTS(SELECT 1 FROM core.vault_key_versions WHERE (generation>0 AND state IN ('pending','active','retired') AND algorithm='aes_256_gcm') IS NOT TRUE)$predicate$;
      new_predicate constant text := $predicate$EXISTS(SELECT 1 FROM core.vault_key_versions WHERE (generation>0 AND state IN ('pending','active','retired') AND algorithm IN ('aes_256_gcm','aes-256-gcm')) IS NOT TRUE)$predicate$;
    BEGIN
      IF pg_catalog.cardinality(pg_catalog.string_to_array(definition,old_predicate)) IS DISTINCT FROM 2
        OR pg_catalog.strpos(definition,new_predicate)<>0 THEN
        RAISE EXCEPTION 'knowledge restore algorithm metadata predicate mismatch' USING ERRCODE='23514';
      END IF;
      EXECUTE pg_catalog.replace(definition,old_predicate,new_predicate);
    END
    $migration$;
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "knowledge restore algorithm metadata is forward-only")
end
~~~

No old migration change, other predicate replacement, grants, function DROP,
schema/data/wire change or cryptographic behavior change.

- [ ] Create apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_algorithm_migration_test.exs
  with the following complete upgrade guard contracts:

~~~elixir
defmodule Singularity.Storage.Backup.KnowledgeRestoreAlgorithmMigrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Singularity.Storage.{MigrationRepo, MigrationTestEnvironment, SafeSQL}

  @previous 20_261_011_000_800
  @version 20_261_016_000_100
  @migration Singularity.Storage.Migrations.KnowledgeRestoreAlgorithmMetadata
  @signature "audit.assert_knowledge_restore_graph(uuid)"
  @old "EXISTS(SELECT 1 FROM core.vault_key_versions WHERE (generation>0 AND state IN ('pending','active','retired') AND algorithm='aes_256_gcm') IS NOT TRUE)"
  @new "EXISTS(SELECT 1 FROM core.vault_key_versions WHERE (generation>0 AND state IN ('pending','active','retired') AND algorithm IN ('aes_256_gcm','aes-256-gcm')) IS NOT TRUE)"

  test "historical upgrade changes exactly one predicate and preserves the complete function catalog" do
    historical(fn ->
      before = catalog()

      [[oid, definition]] =
        owner_query(
          "SELECT to_regprocedure($1)::oid::bigint,pg_get_functiondef(to_regprocedure($1))",
          [@signature]
        ).rows

      assert length(String.split(definition, @old)) == 2
      expected = String.replace(definition, @old, @new)
      assert [@version] == migrate()
      after_catalog = catalog()
      assert Enum.sort(Map.keys(after_catalog)) == Enum.sort(Map.keys(before))

      for {id, values} <- before do
        expected_values = if id == oid, do: List.replace_at(values, -1, expected), else: values
        assert after_catalog[id] == expected_values
      end

      assert expected =~ "(o.storage_ref<>o.id::text AND "

      assert [[false, ["search_path=pg_catalog"]]] ==
               owner_query(
                 "SELECT prosecdef,proconfig FROM pg_proc WHERE oid=to_regprocedure($1)",
                 [
                   @signature
                 ]
               ).rows

      for role <- [
            "singularity_web",
            "singularity_worker",
            "singularity_dispatcher",
            "singularity_pre_auth"
          ] do
        assert [[false]] ==
                 owner_query("SELECT has_function_privilege($1,to_regprocedure($2),'EXECUTE')", [
                   role,
                   @signature
                 ]).rows
      end

      assert [[false]] ==
               owner_query(
                 """
                 SELECT EXISTS(SELECT 1 FROM pg_proc p,
                   LATERAL aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a
                   WHERE p.oid=to_regprocedure($1) AND a.grantee=0 AND a.privilege_type='EXECUTE')
                 """,
                 [@signature]
               ).rows

      assert [] == migrate()
      assert catalog() == after_catalog

      assert_raise Ecto.MigrationError,
                   "knowledge restore algorithm metadata is forward-only",
                   fn ->
                     apply(@migration, :down, [])
                   end

      assert catalog() == after_catalog
    end)
  end

  for {mismatch, replacement} <- [
        {:absent, String.replace(@old, "algorithm='aes_256_gcm'", "algorithm='unknown'")},
        {:duplicate, @old <> " /* " <> @old <> " */"}
      ] do
    test "historical migration fails closed for #{mismatch} exact predicate" do
      historical(fn ->
        [[definition]] =
          owner_query("SELECT pg_get_functiondef(to_regprocedure($1))", [@signature]).rows

        assert length(String.split(definition, @old)) == 2

        altered = String.replace(definition, @old, unquote(replacement))

        assert {:ok, :altered} =
                 MigrationRepo.transaction(fn ->
                   query("SET LOCAL ROLE singularity_table_owner")
                   query(altered)
                   :altered
                 end)

        before = catalog()

        assert_raise Postgrex.Error,
                     ~r/knowledge restore algorithm metadata predicate mismatch/,
                     fn ->
                       migrate()
                     end

        assert catalog() == before
        refute @version in Ecto.Migrator.migrated_versions(MigrationRepo)
      end)
    end
  end

  defp historical(fun) do
    MigrationTestEnvironment.with_database(@previous, fn _environment ->
      {:ok, pid} = MigrationRepo.start_link(pool_size: 2)
      options = Code.compiler_options()
      Code.compiler_options(ignore_module_conflict: true)

      try do
        fun.()
      after
        Supervisor.stop(pid)
        Code.compiler_options(options)
      end
    end)
  end

  defp migrate do
    path = :singularity_storage |> :code.priv_dir() |> to_string() |> Path.join("repo/migrations")
    Ecto.Migrator.run(MigrationRepo, path, :up, to: @version, log: false)
  end

  defp catalog do
    owner_query("""
    SELECT p.oid::bigint,p.proowner::bigint,p.proacl::text,p.prosecdef,p.proleakproof,
      p.proisstrict,p.provolatile::text,p.proparallel::text,p.proconfig,
      p.prorettype::bigint,p.proargtypes::text,p.proargnames,pg_get_functiondef(p.oid)
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname IN ('identity','core','audit','content','jobs') AND p.prokind='f'
    ORDER BY p.oid
    """).rows
    |> Map.new(fn [oid | values] -> {oid, values} end)
  end

  defp owner_query(sql, params \\ []) do
    {:ok, result} =
      MigrationRepo.transaction(fn ->
        query("SET LOCAL ROLE singularity_table_owner")
        query(sql, params)
      end)

    result
  end

  defp query(sql, params \\ []), do: SafeSQL.query!(MigrationRepo, sql, params)
end
~~~

These upgrade contracts run AFTER the migration exists; absence/compile failure
is never counted as behavioral RED. Actual target owner and ACL are preserved
by the catalog comparison, not reset to expected constants. Historical helper
and runtime roles remain unchanged. The two malformed function definitions are
disposable test-only catalog states; do not publish them or change shared roles.
Bound function signatures use to_regprocedure(text), matching the installed
Postgrex OID codec; do not bind signature strings directly as regprocedure.

The first full111 run exposed three test-harness failures: audit schema lookup
requires the established short table-owner transaction. All inspection queries
now use owner_query/2; each transaction resets its role before the actual
Ecto.Migrator.run. The migrator and historical callback are not wrapped in that
owner context. Fixed absent/duplicate replacements are computed while generating
the two tests, avoiding unreachable literal case branches without removing either
contract. No runtime grants or schema privileges change. The corrected complete
three-case migration owner passed naturally with warnings-as-errors before the
full gate is retried; that focused result does not qualify the full111 gate.

- [ ] Remove temporary tracing by restoring the Runtime fixture/owner exactly
  to .devenv/phase5-task11-v3-task6-diag2-fixture.ex and
  .devenv/phase5-task11-v3-task6-diag2-runtime-owner.exs respectively. Root
  verified both actual archive paths and hashes during self-review. Target source
  hashes: fixture a973600ed2b5320b1597a453ddc49e6f13e55b018ccb7a47c391c613d91d40db
  and owner f6ef5b214d009eba0c8ad2aa1bc277d2c867b55b406df2214f26490c0f0f3c66.
  Keep every successful-result hook and assertion. Both Task5 inverse filters
  still recover their accepted archives; Oracle remains unchanged.
- [ ] Author self-reviews source diff, all protected/frozen hashes and old-test
  inverse; reports exact files/hashes and all commands CLOSED. Root seals actual
  formatted candidate and records Sol code-repair candidate1 pending validation.

## Task D: Actual qualification and continuation

- [ ] Root exclusively formats the changed files; ordinary private-PG residual
  EMPTY; capture exact current source/status and unchanged protections.
- [ ] When repairing an upgrade-test harness failure, first run the COMPLETE
  dedicated migration owner; require all three named contracts and no warnings:

~~~sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_algorithm_migration_test.exs --seed 215378 --warnings-as-errors
~~~

Focused GREEN does not replace the complete gate below.

- [ ] Run the COMPLETE migration, owned admission, preflight and import owners:

~~~sh
mix singularity.test.integration apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_algorithm_migration_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_restore_admission_test.exs apps/singularity_storage/test/singularity/storage/backup/knowledge_preflight_test.exs apps/singularity_storage/test/singularity/storage/backup/logical_v3_import_test.exs --seed 215378 --warnings-as-errors
~~~

Require natural GREEN, exact test/excluded counts, unchanged old tests, all direct
owned SQL denials and migration preservation. Also require ordinary-PG post0
EMPTY and final source/frozen/prerequisite guards PASS.

- [ ] Run the complete genuine Runtime/search/restore gate WITHOUT tracing:

~~~sh
mix singularity.test.integration apps/singularity_runtime/test/singularity/runtime/knowledge_backup_restore_live_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_search_api_test.exs apps/singularity_runtime/test/singularity/runtime/knowledge_search_privacy_test.exs apps/singularity_storage/test/singularity/storage/unified_search_restore_test.exs --seed 215378 --warnings-as-errors
~~~

Require full actual UUID saga, pre-rewrap38-projection equality, real typed native
plaintext/custody, five observed retained original bytes, public search and
deterministic recovery. Further failures enter diagnosis; no predicted success.

- [ ] All other actors/commands CLOSED during every Native/formatter/SQL LIVE
  interval; only exact-session empty polls/commentary until natural close.
  Preserve safe raw/exit/counts/duration/post0 EMPTY and final guards. Never open,
  copy or hash the credential-bearing historical raw.
- [ ] Actual combined-source SPEC covers Task6 and BOTH algorithm amendments.
- [ ] NEW distinct fresh QUALITY reviews the actual accepted-spec source.
- [ ] Only then accept Task6 and continue existing Task7. Task13 remains the
  combined qualification/local-commit boundary; do not stage unrelated files.
  All other permitted README gates remain required before phase acceptance.
- [ ] Record the smallest knowledge compatibility migration explicitly, no Vault
  feature work, exact repair/diagnostic counters and E2E NOT RUN. No merge/push,
  version/tag/release/deployment/production activation/backfill.
