defmodule Singularity.Storage.MigrationsTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.MigrationRepo

  @schemas ~w(identity core content jobs audit)
  @tables [
    {"identity", "people"},
    {"identity", "accounts"},
    {"identity", "credentials"},
    {"identity", "principals"},
    {"identity", "sessions"},
    {"identity", "devices"},
    {"identity", "auth_attempts"},
    {"identity", "security_settings"},
    {"core", "vaults"},
    {"core", "vault_members"},
    {"core", "capabilities"},
    {"core", "principal_capabilities"},
    {"core", "data_classifications"},
    {"core", "key_domains"},
    {"core", "vault_key_versions"},
    {"core", "vault_key_wrappers"},
    {"core", "domain_key_versions"},
    {"core", "domain_dedup_key_wrappers"},
    {"core", "outbox_events"},
    {"content", "resources"},
    {"content", "resource_versions"},
    {"content", "assets"},
    {"content", "asset_stages"},
    {"content", "asset_objects"},
    {"content", "asset_key_envelopes"},
    {"content", "asset_metadata"},
    {"content", "asset_search_documents"},
    {"content", "resource_assets"},
    {"content", "source_references"},
    {"content", "tombstones"},
    {"content", "upload_grants"},
    {"jobs", "oban_jobs"},
    {"jobs", "oban_peers"},
    {"jobs", "job_submissions"},
    {"jobs", "job_progress"},
    {"jobs", "effect_receipts"},
    {"audit", "events"},
    {"audit", "backup_manifests"},
    {"audit", "backup_manifest_objects"}
  ]
  @protected_tables @tables -- [{"jobs", "oban_jobs"}, {"jobs", "oban_peers"}]

  test "creates the exact logical schemas and Task 6 tables" do
    %{rows: schema_rows} =
      query!(
        RequestRepo,
        """
        SELECT nspname
        FROM pg_catalog.pg_namespace
        WHERE nspname = ANY($1)
        ORDER BY nspname
        """,
        [@schemas]
      )

    assert schema_rows == @schemas |> Enum.sort() |> Enum.map(&[&1])

    %{rows: table_rows} =
      query!(
        RequestRepo,
        """
        SELECT namespace.nspname, relation.relname
        FROM pg_catalog.pg_class AS relation
        JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE relation.relkind IN ('r', 'p')
          AND (namespace.nspname, relation.relname) IN (
          SELECT unnest($1::text[]), unnest($2::text[])
        )
        ORDER BY namespace.nspname, relation.relname
        """,
        [
          Enum.map(@tables, &elem(&1, 0)),
          Enum.map(@tables, &elem(&1, 1))
        ]
      )

    assert table_rows == @tables |> Enum.sort() |> Enum.map(&Tuple.to_list/1)
  end

  test "tables are owned by the no-login table owner" do
    %{rows: rows} =
      query!(
        RequestRepo,
        """
        SELECT namespace.nspname, relation.relname, owner.rolname
        FROM pg_catalog.pg_class AS relation
        JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        JOIN pg_catalog.pg_roles AS owner ON owner.oid = relation.relowner
        WHERE relation.relkind IN ('r', 'p')
          AND namespace.nspname = ANY($1)
        ORDER BY namespace.nspname, relation.relname
        """,
        [@schemas]
      )

    assert Enum.all?(rows, fn [_schema, _table, owner] ->
             owner == "singularity_table_owner"
           end)

    assert length(rows) == length(@tables)
  end

  test "defines vault-aware foreign keys, lifecycle checks, and immutable audit events" do
    %{rows: constraint_rows} =
      query!(
        RequestRepo,
        """
        SELECT con.conname
        FROM pg_catalog.pg_constraint AS con
        JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = con.connamespace
        WHERE namespace.nspname IN ('identity', 'core', 'content', 'jobs', 'audit')
          AND con.conname = ANY($1)
        ORDER BY con.conname
        """,
        [
          [
            "assets_resource_version_vault_fkey",
            "asset_objects_key_domain_vault_fkey",
            "principal_capabilities_membership_fkey",
            "resource_versions_resource_vault_fkey"
          ]
        ]
      )

    assert constraint_rows == [
             ["asset_objects_key_domain_vault_fkey"],
             ["assets_resource_version_vault_fkey"],
             ["principal_capabilities_membership_fkey"],
             ["resource_versions_resource_vault_fkey"]
           ]

    %{rows: key_domain_constraint_rows} =
      query!(
        RequestRepo,
        """
        SELECT conname, pg_get_constraintdef(oid)
        FROM pg_catalog.pg_constraint
        WHERE conname = ANY($1)
        ORDER BY conname
        """,
        [
          [
            "asset_key_envelopes_domain_version_vault_fkey",
            "asset_key_envelopes_object_vault_fkey",
            "domain_dedup_key_wrappers_version_fkey"
          ]
        ]
      )

    assert key_domain_constraint_rows == [
             [
               "asset_key_envelopes_domain_version_vault_fkey",
               "FOREIGN KEY (domain_key_version_id, vault_id, key_domain_id) " <>
                 "REFERENCES core.domain_key_versions(id, vault_id, key_domain_id) MATCH FULL"
             ],
             [
               "asset_key_envelopes_object_vault_fkey",
               "FOREIGN KEY (asset_object_id, vault_id, key_domain_id) " <>
                 "REFERENCES content.asset_objects(id, vault_id, key_domain_id) MATCH FULL"
             ],
             [
               "domain_dedup_key_wrappers_version_fkey",
               "FOREIGN KEY (domain_key_version_id, vault_id, key_domain_id) " <>
                 "REFERENCES core.domain_key_versions(id, vault_id, key_domain_id) MATCH FULL"
             ]
           ]

    %{rows: check_rows} =
      query!(
        RequestRepo,
        """
        SELECT conname
        FROM pg_catalog.pg_constraint
        WHERE contype = 'c'
          AND conname IN (
          'assets_classification_check',
          'assets_state_check',
          'assets_state_revision_check'
        )
        ORDER BY conname
        """
      )

    assert check_rows == [
             ["assets_classification_check"],
             ["assets_state_check"],
             ["assets_state_revision_check"]
           ]

    %{rows: [[trigger_count]]} =
      query!(
        RequestRepo,
        """
        SELECT count(*)
        FROM pg_catalog.pg_trigger
        WHERE tgrelid = 'audit.events'::regclass
          AND tgname = 'events_immutable'
          AND NOT tgisinternal
        """
      )

    assert trigger_count == 1
  end

  test "Task 11 stores distinct principal and vault authorization epochs on outbox events" do
    %{rows: epoch_columns} =
      query!(
        RequestRepo,
        """
        SELECT column_name, is_nullable, data_type
        FROM information_schema.columns
        WHERE table_schema = 'core'
          AND table_name = 'outbox_events'
          AND column_name LIKE '%authorization_epoch'
        ORDER BY column_name
        """
      )

    assert epoch_columns == [
             ["principal_authorization_epoch", "NO", "bigint"],
             ["vault_authorization_epoch", "NO", "bigint"]
           ]

    %{rows: epoch_constraints} =
      query!(
        RequestRepo,
        """
        SELECT conname
        FROM pg_catalog.pg_constraint
        WHERE conrelid = 'core.outbox_events'::regclass
          AND conname LIKE 'outbox_events_%authorization_epoch_check'
        ORDER BY conname
        """
      )

    assert epoch_constraints == [
             ["outbox_events_principal_authorization_epoch_check"],
             ["outbox_events_vault_authorization_epoch_check"]
           ]
  end

  test "forces row-level security on every user-data table" do
    %{rows: rows} =
      query!(
        RequestRepo,
        """
        SELECT
          namespace.nspname,
          relation.relname,
          relation.relrowsecurity,
          relation.relforcerowsecurity
        FROM pg_catalog.pg_class AS relation
        JOIN pg_catalog.pg_namespace AS namespace
          ON namespace.oid = relation.relnamespace
        WHERE (namespace.nspname, relation.relname) IN (
          SELECT unnest($1::text[]), unnest($2::text[])
        )
        ORDER BY namespace.nspname, relation.relname
        """,
        [
          Enum.map(@protected_tables, &elem(&1, 0)),
          Enum.map(@protected_tables, &elem(&1, 1))
        ]
      )

    assert rows ==
             @protected_tables
             |> Enum.sort()
             |> Enum.map(fn {schema, table} -> [schema, table, true, true] end)
  end

  test "ordinary RLS policies are role-specific and never include a definer or PUBLIC" do
    %{rows: rows} =
      query!(
        RequestRepo,
        """
        SELECT schemaname, tablename, policyname, roles
        FROM pg_catalog.pg_policies
        WHERE roles && ARRAY['singularity_web', 'singularity_worker']::name[]
        ORDER BY schemaname, tablename, policyname
        """
      )

    assert rows != []

    assert Enum.all?(rows, fn [_schema, _table, _policy, roles] ->
             Enum.sort(roles) == ["singularity_web", "singularity_worker"]
           end)

    refute Enum.any?(rows, fn [_schema, _table, _policy, roles] ->
             Enum.any?(
               roles,
               &(&1 in [
                   "public",
                   "singularity_auth_definer",
                   "singularity_authorization_definer",
                   "singularity_outbox_definer"
                 ])
             )
           end)
  end

  test "rolling back the security migrations removes runtime grants before disabling RLS" do
    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert [20_260_718_000_800, 20_260_718_000_700, 20_260_718_000_600] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 3,
                 log: false
               )

      %{rows: [[false, false, false]]} =
        query!(
          RequestRepo,
          """
          SELECT
            has_table_privilege(
              'singularity_web',
              relation.oid,
              'SELECT'
            ),
            relation.relrowsecurity,
            relation.relforcerowsecurity
          FROM pg_catalog.pg_class AS relation
          JOIN pg_catalog.pg_namespace AS namespace
            ON namespace.oid = relation.relnamespace
          WHERE namespace.nspname = 'content'
            AND relation.relname = 'assets'
          """
        )
    after
      try do
        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :up,
          all: true,
          log: false
        )
      after
        Supervisor.stop(migration_repo)
        Code.compiler_options(compiler_options)
      end
    end
  end
end
