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
