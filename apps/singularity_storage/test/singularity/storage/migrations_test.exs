defmodule Singularity.Storage.MigrationsTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.{Fixtures, MigrationRepo}
  alias Singularity.Storage.Schema.Audit.BackupManifest

  @legacy_retirement_reason "legacy_missing_principal_authorization_epoch_provenance"
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
    {"audit", "backup_manifest_objects"},
    {"audit", "restore_import_sagas"}
  ]
  @protected_tables @tables -- [{"jobs", "oban_jobs"}, {"jobs", "oban_peers"}]

  setup do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE core.outbox_events
        SET
          claim_token = NULL,
          claimed_until = NULL,
          delivered_at = COALESCE(delivered_at, CURRENT_TIMESTAMP),
          retired_at = NULL,
          retirement_reason = NULL,
          updated_at = CURRENT_TIMESTAMP
        WHERE delivered_at IS NULL
          OR retired_at IS NOT NULL
          OR retirement_reason IS NOT NULL
        """
      )

      query!(MigrationRepo, "DELETE FROM audit.restore_import_sagas")
    end)

    :ok
  end

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

  test "Task 11 retirement markers require both a timestamp and a reason" do
    %{one: fixture} = Fixtures.two_vaults!()
    event = Fixtures.outbox_event!(fixture)

    try do
      assert_raise Postgrex.Error, fn ->
        Fixtures.with_owner(fn ->
          query!(
            MigrationRepo,
            """
            UPDATE core.outbox_events
            SET retired_at = CURRENT_TIMESTAMP
            WHERE id = $1
            """,
            [event.id]
          )
        end)
      end
    after
      Fixtures.with_owner(fn ->
        query!(MigrationRepo, "DELETE FROM core.outbox_events WHERE id = $1", [event.id])
      end)
    end
  end

  test "Task 11 migration retires legacy pending events across principal revoke and regrant" do
    rollback_task12!()
    %{one: fixture} = Fixtures.two_vaults!()

    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    event_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    correlation_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    legacy_claim_token = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    replacement_claim_token = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert [20_260_718_000_800] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 1,
                 log: false
               )

      assert {:ok, legacy_claimed_until} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                 query!(
                   MigrationRepo,
                   """
                   UPDATE identity.principals
                   SET authorization_epoch = 7
                   WHERE id = $1
                   """,
                   [fixture.principal_id]
                 )

                 %{rows: [[claimed_until]]} =
                   query!(
                     MigrationRepo,
                     """
                     INSERT INTO core.outbox_events (
                       id,
                       event_type,
                       idempotency_key,
                       vault_id,
                       principal_id,
                       required_capability,
                       authorization_epoch,
                       classification,
                       correlation_id,
                       expected_entity_revision,
                       envelope_version,
                       payload,
                       occurred_at,
                       claim_token,
                       claimed_until
                     ) VALUES (
                       $1,
                       'asset.verify_requested',
                       $2,
                       $3,
                       $4,
                       'asset.verify',
                       23,
                       'private',
                       $5,
                       0,
                       1,
                       '{}'::jsonb,
                       CURRENT_TIMESTAMP,
                       $6,
                       CURRENT_TIMESTAMP - interval '5 minutes'
                     )
                     RETURNING claimed_until
                     """,
                     [
                       event_id,
                       "legacy-outbox-#{Ecto.UUID.generate()}",
                       fixture.vault_id,
                       fixture.principal_id,
                       correlation_id,
                       legacy_claim_token
                     ]
                   )

                 claimed_until
               end)

      assert {:ok, :regranted} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                 query!(
                   MigrationRepo,
                   """
                   UPDATE identity.principals
                   SET authorization_epoch = 9
                   WHERE id = $1
                   """,
                   [fixture.principal_id]
                 )

                 :regranted
               end)

      assert [20_260_718_000_800] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 1,
                 log: false
               )

      assert {:ok, {0, 23, retired_at, @legacy_retirement_reason, nil, nil, nil}} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                 %{rows: [row]} =
                   query!(
                     MigrationRepo,
                     """
                     SELECT
                       principal_authorization_epoch,
                       vault_authorization_epoch,
                       retired_at,
                       retirement_reason,
                       delivered_at,
                       claim_token,
                       claimed_until
                     FROM core.outbox_events
                     WHERE id = $1
                     """,
                     [event_id]
                   )

                 List.to_tuple(row)
               end)

      assert %DateTime{} = retired_at
      assert %DateTime{} = legacy_claimed_until
      assert is_binary(legacy_claim_token)

      %{rows: claimed_rows} =
        query!(
          DispatcherRepo,
          """
          SELECT outbox_event_id, claim_token
          FROM core.claim_outbox_events(100, 30, $1)
          """,
          [replacement_claim_token]
        )

      refute Enum.any?(claimed_rows, fn [claimed_event_id, _token] ->
               claimed_event_id == event_id
             end)
    after
      try do
        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :up,
          all: true,
          log: false
        )

        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
          query!(MigrationRepo, "DELETE FROM core.outbox_events WHERE id = $1", [event_id])
        end)
      after
        Supervisor.stop(migration_repo)
        Code.compiler_options(compiler_options)
      end
    end
  end

  test "Task 11 downgrade refuses retirement markers before changing schema state" do
    rollback_task12!()
    %{one: fixture} = Fixtures.two_vaults!()

    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    event_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    correlation_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.outbox_events (
          id,
          event_type,
          idempotency_key,
          vault_id,
          principal_id,
          required_capability,
          principal_authorization_epoch,
          vault_authorization_epoch,
          classification,
          correlation_id,
          expected_entity_revision,
          envelope_version,
          payload,
          occurred_at,
          retired_at,
          retirement_reason
        ) VALUES (
          $1,
          'asset.verify_requested',
          $2,
          $3,
          $4,
          'asset.verify',
          0,
          23,
          'private',
          $5,
          0,
          1,
          '{}'::jsonb,
          CURRENT_TIMESTAMP,
          CURRENT_TIMESTAMP,
          $6
        )
        """,
        [
          event_id,
          "retired-outbox-#{Ecto.UUID.generate()}",
          fixture.vault_id,
          fixture.principal_id,
          correlation_id,
          @legacy_retirement_reason
        ]
      )
    end)

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert_raise Postgrex.Error, ~r/cannot downgrade.*retired legacy outbox/i, fn ->
        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :down,
          step: 1,
          log: false
        )
      end

      assert [
               20_260_718_000_900,
               20_260_722_000_100,
               20_260_722_000_200,
               20_260_722_000_300,
               20_260_722_000_400,
               20_260_722_000_500,
               20_260_722_000_600
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 all: true,
                 log: false
               )

      assert {:ok, {@legacy_retirement_reason, true, true, true}} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                 %{rows: [[reason]]} =
                   query!(
                     MigrationRepo,
                     """
                     SELECT retirement_reason
                     FROM core.outbox_events
                     WHERE id = $1
                     """,
                     [event_id]
                   )

                 %{rows: [[principal_epoch, vault_epoch, retired_at]]} =
                   query!(
                     MigrationRepo,
                     """
                     SELECT
                       to_regclass('core.outbox_events') IS NOT NULL
                         AND EXISTS (
                           SELECT 1
                           FROM information_schema.columns
                           WHERE table_schema = 'core'
                             AND table_name = 'outbox_events'
                             AND column_name = 'principal_authorization_epoch'
                         ),
                       to_regclass('core.outbox_events') IS NOT NULL
                         AND EXISTS (
                           SELECT 1
                           FROM information_schema.columns
                           WHERE table_schema = 'core'
                             AND table_name = 'outbox_events'
                             AND column_name = 'vault_authorization_epoch'
                         ),
                       retired_at IS NOT NULL
                     FROM core.outbox_events
                     WHERE id = $1
                     """,
                     [event_id]
                   )

                 {reason, principal_epoch, vault_epoch, retired_at}
               end)
    after
      try do
        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
          query!(MigrationRepo, "DELETE FROM core.outbox_events WHERE id = $1", [event_id])
        end)

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

  test "Task 11 downgrade refuses native pending events without changing state" do
    rollback_task12!()
    %{one: fixture} = Fixtures.two_vaults!()
    event = Fixtures.outbox_event!(fixture)

    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert_raise Postgrex.Error, ~r/cannot downgrade.*pending outbox/i, fn ->
        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :down,
          step: 1,
          log: false
        )
      end

      assert [
               20_260_718_000_900,
               20_260_722_000_100,
               20_260_722_000_200,
               20_260_722_000_300,
               20_260_722_000_400,
               20_260_722_000_500,
               20_260_722_000_600
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 all: true,
                 log: false
               )

      assert {:ok, {7, 23, nil, nil, nil, true}} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                 %{rows: [row]} =
                   query!(
                     MigrationRepo,
                     """
                     SELECT
                       principal_authorization_epoch,
                       vault_authorization_epoch,
                       retired_at,
                       retirement_reason,
                       delivered_at,
                       to_regprocedure(
                         'core.claim_outbox_events(integer,integer,uuid)'
                       ) IS NOT NULL
                     FROM core.outbox_events
                     WHERE id = $1
                     """,
                     [event.id]
                   )

                 List.to_tuple(row)
               end)
    after
      try do
        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
          query!(MigrationRepo, "DELETE FROM core.outbox_events WHERE id = $1", [event.id])
        end)

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

  test "Task 11 downgrade locks out concurrent pending inserts before preflight" do
    rollback_task12!()
    %{one: fixture} = Fixtures.two_vaults!()

    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    event_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    correlation_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    test_pid = self()

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 5)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    writer_task =
      Task.async(fn ->
        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

          query!(
            MigrationRepo,
            """
            INSERT INTO core.outbox_events (
              id,
              event_type,
              idempotency_key,
              vault_id,
              principal_id,
              required_capability,
              principal_authorization_epoch,
              vault_authorization_epoch,
              classification,
              correlation_id,
              expected_entity_revision,
              envelope_version,
              payload,
              occurred_at
            ) VALUES (
              $1,
              'asset.verify_requested',
              $2,
              $3,
              $4,
              'asset.verify',
              7,
              23,
              'private',
              $5,
              0,
              1,
              '{}'::jsonb,
              CURRENT_TIMESTAMP
            )
            """,
            [
              event_id,
              "concurrent-outbox-#{Ecto.UUID.generate()}",
              fixture.vault_id,
              fixture.principal_id,
              correlation_id
            ]
          )

          send(test_pid, {:pending_insert_uncommitted, event_id})

          receive do
            {:commit_pending_insert, ^event_id} -> :inserted
          end
        end)
      end)

    assert_receive {:pending_insert_uncommitted, ^event_id}, 2_000

    migration_task =
      Task.async(fn ->
        try do
          {:ok,
           Ecto.Migrator.run(
             MigrationRepo,
             migrations_path,
             :down,
             step: 1,
             log: false
           )}
        rescue
          exception in Postgrex.Error -> {:error, exception}
        end
      end)

    try do
      :ok = await_outbox_exclusive_wait!()

      send(writer_task.pid, {:commit_pending_insert, event_id})
      assert {:ok, :inserted} = Task.await(writer_task, 2_000)

      assert {:error, exception} = Task.await(migration_task, 5_000)
      assert Exception.message(exception) =~ ~r/cannot downgrade.*pending outbox/i
    after
      send(writer_task.pid, {:commit_pending_insert, event_id})
      Task.shutdown(writer_task, 1_000)
      Task.shutdown(migration_task, 5_000)

      try do
        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :up,
          all: true,
          log: false
        )

        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
          query!(MigrationRepo, "DELETE FROM core.outbox_events WHERE id = $1", [event_id])
        end)
      after
        Supervisor.stop(migration_repo)
        Code.compiler_options(compiler_options)
      end
    end
  end

  test "Task 11 migration round-trips when no retirement markers exist" do
    rollback_task12!()

    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert {:ok, 0} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                 %{rows: [[count]]} =
                   query!(
                     MigrationRepo,
                     """
                     SELECT count(*)
                     FROM core.outbox_events
                     WHERE retired_at IS NOT NULL OR retirement_reason IS NOT NULL
                     """
                   )

                 count
               end)

      assert [20_260_718_000_800] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 1,
                 log: false
               )

      assert {:ok, ["authorization_epoch"]} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                 %{rows: [[columns]]} =
                   query!(
                     MigrationRepo,
                     """
                     SELECT array_agg(column_name ORDER BY column_name)
                     FROM information_schema.columns
                     WHERE table_schema = 'core'
                       AND table_name = 'outbox_events'
                       AND (
                         column_name LIKE '%authorization_epoch'
                         OR column_name IN ('retired_at', 'retirement_reason')
                       )
                     """
                   )

                 columns
               end)

      assert [20_260_718_000_800] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 1,
                 log: false
               )

      assert {:ok, columns} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                 %{rows: [[columns]]} =
                   query!(
                     MigrationRepo,
                     """
                     SELECT array_agg(column_name ORDER BY column_name)
                     FROM information_schema.columns
                     WHERE table_schema = 'core'
                       AND table_name = 'outbox_events'
                       AND (
                         column_name LIKE '%authorization_epoch'
                         OR column_name IN ('retired_at', 'retirement_reason')
                       )
                     """
                   )

                 columns
               end)

      assert columns == [
               "principal_authorization_epoch",
               "retired_at",
               "retirement_reason",
               "vault_authorization_epoch"
             ]
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

  test "Task 11 migration refuses to discard a rotated wrapper generation on downgrade" do
    rollback_task12!()
    %{one: fixture} = Fixtures.two_vaults!()

    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    version_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    wrapper_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id,
          vault_id,
          generation,
          state,
          algorithm
        ) VALUES ($1, $2, 1, 'active', 'aes-256-gcm')
        """,
        [version_id, fixture.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_wrappers (
          id,
          vault_id,
          vault_key_version_id,
          account_id,
          generation,
          kdf_version,
          kdf_salt,
          kdf_parameters,
          wrapper_algorithm,
          wrapped_key
        ) VALUES (
          $1,
          $2,
          $3,
          $4,
          2,
          1,
          decode('00112233445566778899aabbccddeeff', 'hex'),
          '{"version":1,"t_cost":1,"m_cost":8,"parallelism":1}'::jsonb,
          'aes_256_gcm',
          decode('aabbccdd', 'hex')
        )
        """,
        [wrapper_id, fixture.vault_id, version_id, fixture.account_id]
      )
    end)

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert_raise Postgrex.Error, ~r/cannot downgrade.*wrapper generation/i, fn ->
        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :down,
          step: 1,
          log: false
        )
      end

      assert [
               20_260_718_000_900,
               20_260_722_000_100,
               20_260_722_000_200,
               20_260_722_000_300,
               20_260_722_000_400,
               20_260_722_000_500,
               20_260_722_000_600
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 all: true,
                 log: false
               )

      assert {:ok, 2} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                 %{rows: [[generation]]} =
                   query!(
                     MigrationRepo,
                     """
                     SELECT generation
                     FROM core.vault_key_wrappers
                     WHERE id = $1
                     """,
                     [wrapper_id]
                   )

                 generation
               end)
    after
      try do
        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :up,
          all: true,
          log: false
        )

        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

          query!(
            MigrationRepo,
            "DELETE FROM core.vault_key_wrappers WHERE id = $1",
            [wrapper_id]
          )

          query!(
            MigrationRepo,
            "DELETE FROM core.vault_key_versions WHERE id = $1",
            [version_id]
          )
        end)
      after
        Supervisor.stop(migration_repo)
        Code.compiler_options(compiler_options)
      end
    end
  end

  test "Task 14 backup manifest tag constraint is named, reversible, and schema-aware" do
    %{one: fixture} = Fixtures.two_vaults!()

    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert backup_manifest_seal_constraints() == [
               ["backup_manifests_hash_check", "manifest_hash"],
               ["backup_manifests_tag_check", "manifest_tag"]
             ]

      changeset =
        BackupManifest.seal_changeset(%BackupManifest{}, %{
          manifest_hash: :binary.copy(<<0xA1>>, 32),
          manifest_tag: :binary.copy(<<0xB1>>, 16),
          outbox_high_water: 0,
          sealed_at: DateTime.utc_now(),
          snapshot_id: Ecto.UUID.generate()
        })

      assert Enum.any?(changeset.constraints, fn constraint ->
               constraint.constraint == "backup_manifests_tag_check" and
                 constraint.field == :manifest_tag
             end)

      for manifest_tag <- [nil, :binary.copy(<<0xC1>>, 16)] do
        assert {:ok, manifest_id} = insert_backup_manifest(fixture.vault_id, manifest_tag)
        delete_backup_manifest!(manifest_id)
      end

      for invalid_length <- [15, 17] do
        error =
          assert_raise Postgrex.Error, fn ->
            insert_backup_manifest(
              fixture.vault_id,
              :binary.copy(<<0xD1>>, invalid_length)
            )
          end

        assert error.postgres.constraint == "backup_manifests_tag_check"
      end

      assert [
               20_260_722_000_600,
               20_260_722_000_500,
               20_260_722_000_400,
               20_260_722_000_300
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 4,
                 log: false
               )

      assert backup_manifest_seal_constraints() == [
               ["backup_manifests_hash_check", "manifest_hash"]
             ]

      assert [
               20_260_722_000_300,
               20_260_722_000_400,
               20_260_722_000_500,
               20_260_722_000_600
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 4,
                 log: false
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

  test "Task 14 identity export migration round-trips without weakening Task 11" do
    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert [
               20_260_722_000_600,
               20_260_722_000_500,
               20_260_722_000_400,
               20_260_722_000_300,
               20_260_722_000_200
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 5,
                 log: false
               )

      %{rows: down_contract} = task14_identity_contract()

      assert down_contract == [
               [nil, true, true, false, false, false]
             ]

      assert task14_identity_column_privileges() == []
      assert %{rows: [[true]]} = query!(MigrationRepo, "SELECT current_user = session_user")

      assert [
               20_260_722_000_200,
               20_260_722_000_300,
               20_260_722_000_400,
               20_260_722_000_500,
               20_260_722_000_600
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 5,
                 log: false
               )

      %{rows: up_contract} = task14_identity_contract()

      assert up_contract == [
               [
                 "identity.export_current_vault_owner(uuid)",
                 true,
                 true,
                 true,
                 false,
                 false
               ]
             ]

      assert task14_identity_column_privileges() == [
               ["accounts", "inserted_at", "SELECT"],
               ["accounts", "metadata", "SELECT"],
               ["accounts", "person_id", "SELECT"],
               ["accounts", "updated_at", "SELECT"],
               ["credentials", "inserted_at", "SELECT"],
               ["credentials", "normalized_login", "SELECT"],
               ["people", "display_name", "SELECT"],
               ["people", "id", "SELECT"],
               ["people", "inserted_at", "SELECT"],
               ["people", "metadata", "SELECT"],
               ["people", "updated_at", "SELECT"],
               ["principals", "inserted_at", "SELECT"],
               ["principals", "metadata", "SELECT"],
               ["principals", "updated_at", "SELECT"]
             ]

      assert %{rows: [[true]]} = query!(MigrationRepo, "SELECT current_user = session_user")
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

  test "Task 14 backup repository hardening migration round-trips its boundary" do
    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert task14_backup_repository_contract() == [
               [9, true, true, true, true, false, false]
             ]

      assert [
               20_260_722_000_600,
               20_260_722_000_500,
               20_260_722_000_400
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 3,
                 log: false
               )

      assert task14_backup_repository_contract() == [
               [0, false, false, true, true, true, true]
             ]

      assert [
               20_260_722_000_400,
               20_260_722_000_500,
               20_260_722_000_600
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 3,
                 log: false
               )

      assert task14_backup_repository_contract() == [
               [9, true, true, true, true, false, false]
             ]
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

  test "Task 14 restore import saga marker guards downgrade and round-trips security" do
    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    manifest_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    vault_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO audit.restore_import_sagas (
          singleton,
          manifest_id,
          vault_id,
          manifest_hash,
          manifest_tag,
          inventory_hash,
          destination_root_hash,
          object_count,
          state
        ) VALUES (
          TRUE,
          $1,
          $2,
          $3,
          $4,
          $5,
          $6,
          0,
          'pending'
        )
        """,
        [
          manifest_id,
          vault_id,
          :binary.copy(<<0xA1>>, 32),
          :binary.copy(<<0xB1>>, 16),
          :binary.copy(<<0xC1>>, 32),
          :binary.copy(<<0xD1>>, 32)
        ]
      )
    end)

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert restore_import_saga_contract() == [
               ["singularity_table_owner", true, true, false, false, true, true, 9]
             ]

      assert_raise Postgrex.Error, ~r/cannot downgrade.*restore import saga marker/i, fn ->
        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :down,
          step: 1,
          log: false
        )
      end

      assert restore_import_saga_contract() == [
               ["singularity_table_owner", true, true, false, false, true, true, 9]
             ]

      MigrationRepo.transaction(fn ->
        query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
        query!(MigrationRepo, "DELETE FROM audit.restore_import_sagas")
      end)

      assert [20_260_722_000_600] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 1,
                 log: false
               )

      assert {:ok, nil} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                 %{rows: [[relation]]} =
                   query!(MigrationRepo, "SELECT to_regclass('audit.restore_import_sagas')")

                 relation
               end)

      assert [20_260_722_000_600] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 1,
                 log: false
               )

      assert restore_import_saga_contract() == [
               ["singularity_table_owner", true, true, false, false, true, true, 9]
             ]
    after
      try do
        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :up,
          all: true,
          log: false
        )

        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
          query!(MigrationRepo, "DELETE FROM audit.restore_import_sagas")
        end)
      after
        Supervisor.stop(migration_repo)
        Code.compiler_options(compiler_options)
      end
    end
  end

  test "Task 14 restore import saga permits only contiguous crash-resume phases" do
    valid_shapes = [
      {"pending", [], nil, nil},
      {"imported", [:imported], nil, nil},
      {"rewrapped", [:imported, :rewrapped], Ecto.UUID.generate(), 2},
      {"reconciled", [:imported, :rewrapped, :reconciled], Ecto.UUID.generate(), 2},
      {"verified", [:imported, :rewrapped, :reconciled, :verified], Ecto.UUID.generate(), 2},
      {
        "completed",
        [:imported, :rewrapped, :reconciled, :verified, :completed],
        Ecto.UUID.generate(),
        2
      }
    ]

    for {state, timestamps, integrity_principal_id, wrapper_generation} <- valid_shapes do
      Fixtures.with_owner(fn ->
        insert_restore_import_saga!(
          state,
          timestamps,
          integrity_principal_id,
          wrapper_generation
        )

        query!(MigrationRepo, "DELETE FROM audit.restore_import_sagas")
      end)
    end

    for wrapper_generation <- [1, 2_147_483_647, 2_147_483_648, 4_294_967_295] do
      Fixtures.with_owner(fn ->
        insert_restore_import_saga!(
          "rewrapped",
          [:imported, :rewrapped],
          Ecto.UUID.generate(),
          wrapper_generation
        )

        query!(MigrationRepo, "DELETE FROM audit.restore_import_sagas")
      end)
    end

    invalid_shapes = [
      {"pending", [:imported], nil, nil},
      {"pending", [], Ecto.UUID.generate(), 2},
      {"imported", [], nil, nil},
      {"imported", [:imported, :rewrapped], nil, nil},
      {"imported", [:imported], Ecto.UUID.generate(), 2},
      {"rewrapped", [:imported], Ecto.UUID.generate(), 2},
      {"rewrapped", [:imported, :rewrapped], nil, 2},
      {"rewrapped", [:imported, :rewrapped], Ecto.UUID.generate(), nil},
      {
        "rewrapped",
        [:imported, :rewrapped, :reconciled],
        Ecto.UUID.generate(),
        2
      },
      {"reconciled", [:imported, :reconciled], Ecto.UUID.generate(), 2},
      {
        "reconciled",
        [:imported, :rewrapped, :reconciled, :verified],
        Ecto.UUID.generate(),
        2
      },
      {"verified", [:imported, :rewrapped, :verified], Ecto.UUID.generate(), 2},
      {
        "verified",
        [:imported, :rewrapped, :reconciled, :verified, :completed],
        Ecto.UUID.generate(),
        2
      },
      {
        "completed",
        [:imported, :rewrapped, :reconciled, :completed],
        Ecto.UUID.generate(),
        2
      },
      {"rewrapped", [:imported, :rewrapped], Ecto.UUID.generate(), 0},
      {"rewrapped", [:imported, :rewrapped], Ecto.UUID.generate(), 4_294_967_296}
    ]

    for {state, timestamps, integrity_principal_id, wrapper_generation} <- invalid_shapes do
      assert_raise Postgrex.Error, fn ->
        Fixtures.with_owner(fn ->
          insert_restore_import_saga!(
            state,
            timestamps,
            integrity_principal_id,
            wrapper_generation
          )
        end)
      end
    end
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
    rollback_task12!()

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

  defp rollback_task12! do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "TRUNCATE TABLE core.vaults, identity.people CASCADE"
      )
    end)

    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert [
               20_260_722_000_600,
               20_260_722_000_500,
               20_260_722_000_400,
               20_260_722_000_300,
               20_260_722_000_200,
               20_260_722_000_100,
               20_260_718_000_900
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 7,
                 log: false
               )
    after
      Supervisor.stop(migration_repo)
      Code.compiler_options(compiler_options)
    end
  end

  defp backup_manifest_seal_constraints do
    %{rows: rows} =
      query!(
        RequestRepo,
        """
        SELECT
          conname,
          CASE
            WHEN pg_get_constraintdef(oid) LIKE '%manifest_hash%' THEN 'manifest_hash'
            WHEN pg_get_constraintdef(oid) LIKE '%manifest_tag%' THEN 'manifest_tag'
          END
        FROM pg_catalog.pg_constraint
        WHERE conrelid = 'audit.backup_manifests'::regclass
          AND conname IN (
            'backup_manifests_hash_check',
            'backup_manifests_tag_check'
          )
        ORDER BY conname
        """
      )

    rows
  end

  defp restore_import_saga_contract do
    %{rows: rows} =
      query!(
        RequestRepo,
        """
        SELECT
          owner.rolname,
          relation.relrowsecurity,
          relation.relforcerowsecurity,
          has_table_privilege('singularity_web', relation.oid, 'SELECT'),
          has_table_privilege('singularity_worker', relation.oid, 'SELECT'),
          NOT (
            has_table_privilege('singularity_web', relation.oid, 'INSERT')
            OR has_table_privilege('singularity_web', relation.oid, 'UPDATE')
            OR has_table_privilege('singularity_web', relation.oid, 'DELETE')
            OR has_table_privilege('singularity_worker', relation.oid, 'INSERT')
            OR has_table_privilege('singularity_worker', relation.oid, 'UPDATE')
            OR has_table_privilege('singularity_worker', relation.oid, 'DELETE')
            OR EXISTS (
              SELECT 1
              FROM aclexplode(
                COALESCE(
                  relation.relacl,
                  acldefault('r', relation.relowner)
                )
              ) AS privilege
              WHERE privilege.grantee = 0
                AND privilege.privilege_type IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
            )
          ),
          EXISTS (
            SELECT 1
            FROM pg_catalog.pg_policies AS policy
            WHERE policy.schemaname = 'audit'
              AND policy.tablename = 'restore_import_sagas'
              AND policy.policyname = 'restore_import_sagas_table_owner'
              AND policy.roles = ARRAY['singularity_table_owner']::name[]
              AND policy.cmd = 'ALL'
              AND policy.qual = 'true'
              AND policy.with_check = 'true'
          ),
          (
            SELECT count(*)
            FROM pg_catalog.pg_constraint AS table_constraint
            WHERE table_constraint.conrelid = relation.oid
              AND table_constraint.conname = ANY($1)
          )
        FROM pg_catalog.pg_class AS relation
        JOIN pg_catalog.pg_namespace AS namespace
          ON namespace.oid = relation.relnamespace
        JOIN pg_catalog.pg_roles AS owner
          ON owner.oid = relation.relowner
        WHERE namespace.nspname = 'audit'
          AND relation.relname = 'restore_import_sagas'
        """,
        [
          [
            "restore_import_sagas_singleton_check",
            "restore_import_sagas_manifest_hash_check",
            "restore_import_sagas_manifest_tag_check",
            "restore_import_sagas_inventory_hash_check",
            "restore_import_sagas_destination_root_hash_check",
            "restore_import_sagas_object_count_check",
            "restore_import_sagas_wrapper_generation_check",
            "restore_import_sagas_state_check",
            "restore_import_sagas_state_shape_check"
          ]
        ]
      )

    rows
  end

  defp insert_restore_import_saga!(
         state,
         timestamps,
         integrity_principal_id,
         wrapper_generation
       ) do
    timestamp = DateTime.utc_now()

    query!(
      MigrationRepo,
      """
      INSERT INTO audit.restore_import_sagas (
        singleton,
        manifest_id,
        vault_id,
        manifest_hash,
        manifest_tag,
        inventory_hash,
        destination_root_hash,
        object_count,
        state,
        imported_at,
        rewrapped_at,
        reconciled_at,
        verified_at,
        completed_at,
        integrity_principal_id,
        wrapper_generation
      ) VALUES (
        TRUE,
        $1,
        $2,
        $3,
        $4,
        $5,
        $6,
        0,
        $7,
        $8,
        $9,
        $10,
        $11,
        $12,
        $13,
        $14
      )
      """,
      [
        Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        :binary.copy(<<0xA1>>, 32),
        :binary.copy(<<0xB1>>, 16),
        :binary.copy(<<0xC1>>, 32),
        :binary.copy(<<0xD1>>, 32),
        state,
        timestamp_if_present(timestamps, :imported, timestamp),
        timestamp_if_present(timestamps, :rewrapped, timestamp),
        timestamp_if_present(timestamps, :reconciled, timestamp),
        timestamp_if_present(timestamps, :verified, timestamp),
        timestamp_if_present(timestamps, :completed, timestamp),
        dump_uuid(integrity_principal_id),
        wrapper_generation
      ]
    )
  end

  defp timestamp_if_present(timestamps, phase, timestamp) do
    if phase in timestamps, do: timestamp, else: nil
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(uuid), do: Ecto.UUID.dump!(uuid)

  defp insert_backup_manifest(vault_id, manifest_tag) do
    manifest_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    case MigrationRepo.transaction(fn ->
           query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

           query!(
             MigrationRepo,
             """
             INSERT INTO audit.backup_manifests (
               id,
               vault_id,
               classification,
               status,
               destination_ref,
               kdf_version,
               kdf_salt,
               kdf_parameters,
               recovery_wrapper,
               manifest_tag
             ) VALUES (
               $1,
               $2,
               'private',
               'pending',
               'migration-test.bundle',
               1,
               decode('00112233445566778899aabbccddeeff', 'hex'),
               '{}'::jsonb,
               decode('aabbccdd', 'hex'),
               $3
             )
             """,
             [manifest_id, vault_id, manifest_tag]
           )
         end) do
      {:ok, _result} -> {:ok, manifest_id}
      {:error, %Postgrex.Error{} = error} -> {:error, error}
    end
  end

  defp delete_backup_manifest!(manifest_id) do
    {:ok, _result} =
      MigrationRepo.transaction(fn ->
        query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

        query!(MigrationRepo, "DELETE FROM audit.backup_manifests WHERE id = $1", [manifest_id])
      end)

    :ok
  end

  defp task14_identity_contract do
    query!(
      RequestRepo,
      """
      SELECT
        to_regprocedure('identity.export_current_vault_owner(uuid)')::text,
        to_regprocedure('core.live_principal_authorization()') IS NOT NULL,
        EXISTS (
          SELECT 1
          FROM pg_catalog.pg_policies
          WHERE schemaname = 'identity'
            AND tablename = 'accounts'
            AND policyname = 'task11_authorization_reads_accounts'
        ),
        EXISTS (
          SELECT 1
          FROM pg_catalog.pg_policies
          WHERE schemaname = 'identity'
            AND tablename = 'people'
            AND policyname = 'task14_authorization_reads_people'
        ),
        has_schema_privilege(
          'singularity_authorization_definer',
          'identity',
          'CREATE'
        ),
        has_table_privilege(
          'singularity_authorization_definer',
          'identity.people',
          'SELECT'
        )
      """
    )
  end

  defp task14_identity_column_privileges do
    %{rows: rows} =
      query!(
        RequestRepo,
        """
        SELECT relation.relname, attribute.attname, privilege.privilege_type
        FROM pg_catalog.pg_attribute AS attribute
        JOIN pg_catalog.pg_class AS relation ON relation.oid = attribute.attrelid
        JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        CROSS JOIN LATERAL aclexplode(attribute.attacl) AS privilege
        JOIN pg_catalog.pg_roles AS grantee ON grantee.oid = privilege.grantee
        WHERE namespace.nspname = 'identity'
          AND grantee.rolname = 'singularity_authorization_definer'
          AND relation.relname || '.' || attribute.attname = ANY($1)
        ORDER BY relation.relname, attribute.attname, privilege.privilege_type
        """,
        [
          ~w(
            accounts.person_id
            accounts.metadata
            accounts.inserted_at
            accounts.updated_at
            credentials.normalized_login
            credentials.inserted_at
            people.id
            people.display_name
            people.metadata
            people.inserted_at
            people.updated_at
            principals.metadata
            principals.inserted_at
            principals.updated_at
          )
        ]
      )

    rows
  end

  defp task14_backup_repository_contract do
    %{rows: rows} =
      query!(
        RequestRepo,
        """
        SELECT
          (
            SELECT count(*)
            FROM pg_catalog.pg_proc AS procedure
            JOIN pg_catalog.pg_namespace AS namespace
              ON namespace.oid = procedure.pronamespace
            WHERE namespace.nspname = 'audit'
              AND procedure.proname = ANY($1)
          ),
          EXISTS (
            SELECT 1
            FROM pg_catalog.pg_trigger
            WHERE tgrelid = 'audit.backup_manifest_objects'::regclass
              AND tgname = 'backup_manifest_objects_immutable'
              AND NOT tgisinternal
          ),
          EXISTS (
            SELECT 1
            FROM pg_catalog.pg_constraint
            WHERE conrelid = 'audit.backup_manifest_objects'::regclass
              AND conname =
                'backup_manifest_objects_manifest_id_inventory_position_key'
          ),
          has_table_privilege(
            'singularity_web',
            'audit.backup_manifests',
            'SELECT'
          ),
          has_table_privilege(
            'singularity_worker',
            'audit.backup_manifest_objects',
            'SELECT'
          ),
          has_table_privilege(
            'singularity_web',
            'audit.backup_manifests',
            'INSERT, UPDATE, DELETE'
          ),
          has_table_privilege(
            'singularity_worker',
            'audit.backup_manifest_objects',
            'INSERT, UPDATE, DELETE'
          )
        """,
        [
          ~w(
            activate_backup_manifest
            backup_scope_authorized
            claim_backup_manifest
            create_backup_request
            lock_backup_manifest
            mark_backup_waiting
            reject_backup_inventory_mutation
            replace_backup_custody
            seal_backup_manifest
          )
        ]
      )

    rows
  end

  defp await_outbox_exclusive_wait!(attempts \\ 250)

  defp await_outbox_exclusive_wait!(0) do
    flunk("migration did not wait for an exclusive outbox lock")
  end

  defp await_outbox_exclusive_wait!(attempts) do
    {:ok, rows} =
      MigrationRepo.transaction(fn ->
        query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

        %{rows: rows} =
          query!(
            MigrationRepo,
            """
            SELECT 1
            FROM pg_catalog.pg_locks AS lock
            WHERE lock.relation = 'core.outbox_events'::regclass
              AND lock.mode = 'AccessExclusiveLock'
              AND NOT lock.granted
            """
          )

        rows
      end)

    case rows do
      [[1] | _] ->
        :ok

      [] ->
        Process.sleep(20)
        await_outbox_exclusive_wait!(attempts - 1)
    end
  end
end
