defmodule Singularity.Storage.MigrationsTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.{Fixtures, MigrationRepo}

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
    {"audit", "backup_manifest_objects"}
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

      assert [20_260_718_000_900] =
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

      assert [20_260_718_000_900] =
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

      assert [20_260_718_000_900] =
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
      assert [20_260_718_000_900] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 1,
                 log: false
               )
    after
      Supervisor.stop(migration_repo)
      Code.compiler_options(compiler_options)
    end
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
