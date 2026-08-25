defmodule Singularity.Storage.MigrationsTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.{Fixtures, MigrationRepo, ScopedRepo}
  alias Singularity.Storage.Schema.Audit.BackupManifest

  @notes_migration_version 20_260_818_000_100
  @notes_migration Singularity.Storage.Migrations.CreatePrivateMarkdownNotes
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
    {"content", "note_versions"},
    {"content", "note_conflicts"},
    {"content", "note_search_documents"},
    {"content", "note_mutation_receipts"},
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

  setup context do
    prepare_private_notes_migration!(context[:with_private_notes] == true)
    on_exit(&restore_all_migrations!/0)

    # Migration DDL and the audit baseline are database-global, so this module
    # remains async: false and removes only residue that Task 15 cannot map back.
    Fixtures.with_owner(fn ->
      delete_unmappable_system_audit_events!()

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

  defp migrations_path do
    :singularity_storage
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("repo/migrations")
  end

  defp prepare_private_notes_migration!(true) do
    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)

    try do
      unless notes_migration_up?() do
        Ecto.Migrator.run(MigrationRepo, migrations_path(), :up, all: true, log: false)
      end
    after
      Supervisor.stop(migration_repo)
    end
  end

  defp prepare_private_notes_migration!(false) do
    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)

    try do
      if notes_migration_up?() do
        cleanup_notes_with_started_repo!()

        :ok =
          Ecto.Migrator.down(
            MigrationRepo,
            @notes_migration_version,
            @notes_migration,
            log: false
          )

        :code.purge(@notes_migration)
        :code.delete(@notes_migration)
      end
    after
      Supervisor.stop(migration_repo)
    end
  end

  defp restore_all_migrations! do
    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      Ecto.Migrator.run(MigrationRepo, migrations_path(), :up, all: true, log: false)
    after
      Supervisor.stop(migration_repo)
      Code.compiler_options(compiler_options)
    end
  end

  defp notes_migration_up? do
    %{rows: rows} =
      query!(
        MigrationRepo,
        "SELECT 1 FROM public.schema_migrations WHERE version = $1",
        [@notes_migration_version]
      )

    rows == [[1]]
  end

  @tag :with_private_notes
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

  @tag :with_private_notes
  test "private notes migration refuses destructive downgrade with canonical rows" do
    note = Singularity.Storage.NoteFixtures.note!()
    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)

    try do
      assert_raise Postgrex.Error,
                   ~r/cannot downgrade private notes while canonical note data exists/i,
                   fn ->
                     Ecto.Migrator.down(
                       MigrationRepo,
                       @notes_migration_version,
                       @notes_migration,
                       log: false
                     )
                   end

      assert %{rows: [[1]]} =
               Singularity.Storage.NoteFixtures.scoped(note, RequestRepo, fn repo ->
                 query!(
                   repo,
                   "SELECT count(*) FROM content.note_versions WHERE resource_id = $1",
                   [Ecto.UUID.dump!(note.resource_id)]
                 )
               end)
    after
      cleanup_notes_with_started_repo!()

      Ecto.Migrator.up(
        MigrationRepo,
        @notes_migration_version,
        @notes_migration,
        log: false
      )

      Supervisor.stop(migration_repo)
    end
  end

  defp cleanup_notes_with_started_repo! do
    MigrationRepo.transaction(fn ->
      query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
      query!(MigrationRepo, "SET CONSTRAINTS ALL DEFERRED")
      query!(MigrationRepo, "DELETE FROM content.note_mutation_receipts")
      query!(MigrationRepo, "DELETE FROM content.note_search_documents")
      query!(MigrationRepo, "DELETE FROM content.note_conflicts")
      query!(MigrationRepo, "DELETE FROM content.note_versions")

      query!(
        MigrationRepo,
        """
        DELETE FROM content.resource_versions AS version
        USING content.resources AS resource
        WHERE version.resource_id = resource.id AND resource.kind = 'note'
        """
      )

      query!(MigrationRepo, "DELETE FROM content.resources WHERE kind = 'note'")
    end)
  end

  @tag :with_private_notes
  test "private notes downgrade declares the complete runtime-compatible lock order" do
    migration =
      migrations_path()
      |> Path.join("20260818000100_create_private_markdown_notes.exs")
      |> File.read!()

    assert [_, lock_block] =
             Regex.run(~r/LOCK TABLE\s+(.*?)\s+IN ACCESS EXCLUSIVE MODE/s, migration)

    expected_order = [
      "content.note_mutation_receipts",
      "content.resources",
      "content.resource_versions",
      "content.note_versions",
      "content.note_conflicts",
      "content.note_search_documents"
    ]

    positions =
      Enum.map(expected_order, fn table ->
        case :binary.match(lock_block, table) do
          {position, _length} -> position
          :nomatch -> flunk("downgrade lock order is missing #{table}")
        end
      end)

    assert positions == Enum.sort(positions)
  end

  @tag :with_private_notes
  test "private notes downgrade serializes behind capability reconciliation" do
    Singularity.Storage.NoteFixtures.cleanup_notes!()
    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    {:ok, blocker} = Postgrex.start_link(postgrex_options())
    {:ok, observer} = Postgrex.start_link(postgrex_options())
    Postgrex.query!(blocker, "BEGIN", [])
    Postgrex.query!(blocker, "SELECT core.reconcile_note_capabilities()", [])
    %{rows: [[blocker_pid]]} = Postgrex.query!(blocker, "SELECT pg_backend_pid()", [])

    migrator =
      Task.async(fn ->
        Ecto.Migrator.down(
          MigrationRepo,
          @notes_migration_version,
          @notes_migration,
          log: false
        )
      end)

    try do
      assert nil == Task.yield(migrator, 200)
      await_reconcile_advisory_waiter!(observer, blocker_pid)
      Postgrex.query!(blocker, "COMMIT", [])
      assert {:ok, :ok} = Task.yield(migrator, 5_000)
    after
      Postgrex.query(blocker, "ROLLBACK", [])
      Task.shutdown(migrator, :brutal_kill)

      _ =
        Ecto.Migrator.up(
          MigrationRepo,
          @notes_migration_version,
          @notes_migration,
          log: false
        )

      GenServer.stop(blocker)
      GenServer.stop(observer)
      Supervisor.stop(migration_repo)
    end
  end

  defp await_reconcile_advisory_waiter!(observer, blocker_pid, attempts \\ 200)

  defp await_reconcile_advisory_waiter!(_observer, _blocker_pid, 0) do
    flunk("private notes downgrade did not wait on the reconciliation advisory lock")
  end

  defp await_reconcile_advisory_waiter!(observer, blocker_pid, attempts) do
    %{rows: [[waiting?]]} =
      Postgrex.query!(
        observer,
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_catalog.pg_locks AS waiting
          JOIN pg_catalog.pg_locks AS held
            ON held.locktype = waiting.locktype
           AND held.database IS NOT DISTINCT FROM waiting.database
           AND held.classid IS NOT DISTINCT FROM waiting.classid
           AND held.objid IS NOT DISTINCT FROM waiting.objid
           AND held.objsubid IS NOT DISTINCT FROM waiting.objsubid
          WHERE waiting.locktype = 'advisory'
            AND NOT waiting.granted
            AND held.granted
            AND held.pid = $1
        )
        """,
        [blocker_pid]
      )

    if waiting? do
      :ok
    else
      Process.sleep(10)
      await_reconcile_advisory_waiter!(observer, blocker_pid, attempts - 1)
    end
  end

  @tag :with_private_notes
  test "private notes migration safely restores the prior empty schema on downgrade" do
    Singularity.Storage.NoteFixtures.cleanup_notes!()
    %{one: raw_eligible} = Fixtures.two_vaults!()

    eligible = %{
      principal_id: Ecto.UUID.load!(raw_eligible.principal_id),
      vault_id: Ecto.UUID.load!(raw_eligible.vault_id)
    }

    Singularity.Storage.NoteFixtures.grant_password_change!(eligible)
    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)

    try do
      assert :ok =
               Singularity.Storage.Postgres.NoteCapabilityReconciler.reconcile(MigrationRepo)

      assert :ok =
               Ecto.Migrator.down(
                 MigrationRepo,
                 @notes_migration_version,
                 @notes_migration,
                 log: false
               )

      assert {:ok, %{rows: [[nil, nil, nil, nil, nil, nil]]}} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                 query!(
                   MigrationRepo,
                   """
                   SELECT to_regclass('content.note_versions'),
                          to_regclass('content.note_conflicts'),
                          to_regclass('content.note_search_documents'),
                          to_regclass('content.note_mutation_receipts'),
                          (SELECT 1 FROM information_schema.columns WHERE table_schema = 'content' AND table_name = 'resources' AND column_name = 'kind'),
                          (SELECT 1 FROM information_schema.columns WHERE table_schema = 'content' AND table_name = 'resources' AND column_name = 'current_version_id')
                   """
                 )
               end)

      assert {:ok, %{rows: [[0, 0]]}} =
               MigrationRepo.transaction(fn ->
                 query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

                 query!(
                   MigrationRepo,
                   """
                   SELECT
                     (SELECT count(*) FROM core.capabilities WHERE name LIKE 'note.%'),
                     (
                       SELECT count(*)
                       FROM core.principal_capabilities AS assignment
                       JOIN core.capabilities AS capability
                         ON capability.id = assignment.capability_id
                       WHERE capability.name LIKE 'note.%'
                     )
                   """
                 )
               end)

      assert %{rows: [[resource_id, "Resource one", "private"]]} =
               owner_query!(
                 "SELECT id, title, classification FROM content.resources WHERE id = $1",
                 [raw_eligible.resource_id]
               )

      assert resource_id == raw_eligible.resource_id

      assert %{rows: [[version_id, resource_id, 0]]} =
               owner_query!(
                 "SELECT id, resource_id, revision FROM content.resource_versions WHERE id = $1",
                 [raw_eligible.resource_version_id]
               )

      assert version_id == raw_eligible.resource_version_id
      assert resource_id == raw_eligible.resource_id

      assert :ok =
               Ecto.Migrator.up(
                 MigrationRepo,
                 @notes_migration_version,
                 @notes_migration,
                 log: false
               )

      assert %{rows: [["asset", nil]]} =
               owner_query!(
                 "SELECT kind, current_version_id FROM content.resources WHERE id = $1",
                 [raw_eligible.resource_id]
               )

      assert %{rows: [[0]]} =
               owner_query!(
                 "SELECT revision FROM content.resource_versions WHERE id = $1",
                 [raw_eligible.resource_version_id]
               )
    after
      MigrationRepo.transaction(fn ->
        query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
        query!(MigrationRepo, "TRUNCATE TABLE identity.people CASCADE")
      end)

      Ecto.Migrator.up(
        MigrationRepo,
        @notes_migration_version,
        @notes_migration,
        log: false
      )

      Supervisor.stop(migration_repo)
    end
  end

  test "Task 17 upload grant retirement guards ambiguous upgrade history and downgrade" do
    %{one: fixture} = Fixtures.two_vaults!()

    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    retired_grant_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    first_duplicate_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    second_duplicate_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    duplicate_key = "ambiguous-upload-history-#{Ecto.UUID.generate()}"

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO content.upload_grants (
          id,
          vault_id,
          session_id,
          principal_id,
          asset_id,
          classification,
          token_digest,
          csrf_token_digest,
          filename,
          byte_size,
          declared_media_type,
          idempotency_key,
          principal_authorization_epoch,
          vault_authorization_epoch,
          expires_at,
          inserted_at,
          retired_at
        ) VALUES (
          $1,
          $2,
          $3,
          $4,
          $5,
          'private',
          $6,
          $7,
          'retired-history.pdf',
          1,
          'application/pdf',
          $8,
          0,
          0,
          statement_timestamp() - interval '2 hours',
          statement_timestamp() - interval '3 hours',
          statement_timestamp() - interval '1 hour'
        )
        """,
        [
          retired_grant_id,
          fixture.vault_id,
          fixture.session_id,
          fixture.principal_id,
          fixture.asset_id,
          :crypto.hash(:sha256, "retired-token-#{Ecto.UUID.generate()}"),
          :crypto.hash(:sha256, "retired-csrf-#{Ecto.UUID.generate()}"),
          "retired-upload-#{Ecto.UUID.generate()}"
        ]
      )
    end)

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert_raise Postgrex.Error, ~r/cannot downgrade.*retired history/i, fn ->
        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :down,
          step: 1,
          log: false
        )
      end

      assert %{
               rows: [
                 [
                   true,
                   true,
                   true,
                   current_constraint,
                   current_index
                 ]
               ]
             } = upload_grant_retirement_contract()

      assert current_constraint =~ "cancelled_at IS NULL"
      assert current_constraint =~ "retired_at = cancelled_at"
      assert current_index =~ "retired_at IS NULL"
      refute current_index =~ "consumed_at IS NULL"

      MigrationRepo.transaction(fn ->
        query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

        query!(
          MigrationRepo,
          "DELETE FROM content.upload_grants WHERE id = $1",
          [retired_grant_id]
        )
      end)

      assert [20_260_729_000_100] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 1,
                 log: false
               )

      assert %{rows: [[false, false, false, nil, legacy_index]]} =
               upload_grant_retirement_contract()

      assert legacy_index =~ "consumed_at IS NULL"
      refute legacy_index =~ "retired_at IS NULL"

      MigrationRepo.transaction(fn ->
        query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

        query!(
          MigrationRepo,
          """
          INSERT INTO content.upload_grants (
            id,
            vault_id,
            session_id,
            principal_id,
            asset_id,
            classification,
            token_digest,
            csrf_token_digest,
            filename,
            byte_size,
            declared_media_type,
            idempotency_key,
            principal_authorization_epoch,
            vault_authorization_epoch,
            expires_at,
            consumed_at,
            inserted_at
          ) VALUES
            (
              $1, $3, $4, $5, $6, 'private', $7, $8,
              'ambiguous-first.pdf', 1, 'application/pdf', $9,
              0, 0, statement_timestamp() + interval '1 hour',
              statement_timestamp(), statement_timestamp() - interval '1 minute'
            ),
            (
              $2, $3, $4, $5, $6, 'private', $10, $11,
              'ambiguous-second.pdf', 1, 'application/pdf', $9,
              0, 0, statement_timestamp() + interval '1 hour',
              statement_timestamp(), statement_timestamp()
            )
          """,
          [
            first_duplicate_id,
            second_duplicate_id,
            fixture.vault_id,
            fixture.session_id,
            fixture.principal_id,
            fixture.asset_id,
            :crypto.hash(:sha256, "first-token-#{Ecto.UUID.generate()}"),
            :crypto.hash(:sha256, "first-csrf-#{Ecto.UUID.generate()}"),
            duplicate_key,
            :crypto.hash(:sha256, "second-token-#{Ecto.UUID.generate()}"),
            :crypto.hash(:sha256, "second-csrf-#{Ecto.UUID.generate()}")
          ]
        )
      end)

      assert_raise Postgrex.Error, ~r/cannot enforce.*duplicate unretired/i, fn ->
        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :up,
          step: 1,
          log: false
        )
      end

      assert %{rows: [[false, false, false, nil, ^legacy_index]]} =
               upload_grant_retirement_contract()

      MigrationRepo.transaction(fn ->
        query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

        query!(
          MigrationRepo,
          "DELETE FROM content.upload_grants WHERE id IN ($1, $2)",
          [first_duplicate_id, second_duplicate_id]
        )
      end)

      assert [20_260_729_000_100] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 1,
                 log: false
               )

      assert %{
               rows: [
                 [
                   true,
                   true,
                   true,
                   restored_constraint,
                   restored_index
                 ]
               ]
             } = upload_grant_retirement_contract()

      assert restored_constraint =~ "cancelled_at IS NULL"
      assert restored_constraint =~ "retired_at = cancelled_at"
      assert restored_index =~ "retired_at IS NULL"
      refute restored_index =~ "consumed_at IS NULL"
    after
      try do
        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

          query!(
            MigrationRepo,
            "DELETE FROM content.upload_grants WHERE id IN ($1, $2, $3)",
            [retired_grant_id, first_duplicate_id, second_duplicate_id]
          )
        end)

        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :up,
          all: true,
          log: false
        )
      after
        Code.compiler_options(compiler_options)
        Supervisor.stop(migration_repo)
      end
    end
  end

  test "Task 17 downgrade serializes the retirement guard against concurrent writes" do
    %{one: fixture} = Fixtures.two_vaults!()

    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    grant_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO content.upload_grants (
          id,
          vault_id,
          session_id,
          principal_id,
          asset_id,
          classification,
          token_digest,
          csrf_token_digest,
          filename,
          byte_size,
          declared_media_type,
          idempotency_key,
          principal_authorization_epoch,
          vault_authorization_epoch,
          expires_at,
          inserted_at
        ) VALUES (
          $1,
          $2,
          $3,
          $4,
          $5,
          'private',
          $6,
          $7,
          'concurrent-retirement.pdf',
          1,
          'application/pdf',
          $8,
          0,
          0,
          statement_timestamp() - interval '1 hour',
          statement_timestamp() - interval '2 hours'
        )
        """,
        [
          grant_id,
          fixture.vault_id,
          fixture.session_id,
          fixture.principal_id,
          fixture.asset_id,
          :crypto.hash(:sha256, "concurrent-token-#{Ecto.UUID.generate()}"),
          :crypto.hash(:sha256, "concurrent-csrf-#{Ecto.UUID.generate()}"),
          "concurrent-upload-#{Ecto.UUID.generate()}"
        ]
      )
    end)

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 4)
    {:ok, blocker_connection} = Postgrex.start_link(postgrex_options())
    {:ok, observer_connection} = Postgrex.start_link(postgrex_options())
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    Postgrex.query!(blocker_connection, "BEGIN", [])
    Postgrex.query!(blocker_connection, "SET LOCAL ROLE singularity_table_owner", [])
    Postgrex.query!(observer_connection, "SET ROLE singularity_table_owner", [])

    Postgrex.query!(
      blocker_connection,
      "LOCK TABLE content.upload_grants IN ROW EXCLUSIVE MODE",
      []
    )

    migrator =
      Task.async(fn ->
        try do
          {:ok,
           Ecto.Migrator.down(
             MigrationRepo,
             20_260_729_000_100,
             Singularity.Storage.Migrations.RetireSupersededUploadGrants,
             log: false
           )}
        rescue
          error in Postgrex.Error -> {:error, error}
        end
      end)

    try do
      assert nil == Task.yield(migrator, 100)
      wait_for_upload_grant_ddl_waiter!(observer_connection)

      Postgrex.query!(
        blocker_connection,
        """
        UPDATE content.upload_grants
        SET retired_at = statement_timestamp()
        WHERE id = $1
        """,
        [grant_id]
      )

      Postgrex.query!(blocker_connection, "COMMIT", [])
      migration_result = Task.await(migrator, 5_000)

      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               migration_result

      assert message =~
               "cannot downgrade upload grant retirement while retired history exists"

      assert %{rows: [[true, true, true, _, _]]} =
               upload_grant_retirement_contract()
    after
      try do
        Task.shutdown(migrator, :brutal_kill)
        Postgrex.query(blocker_connection, "ROLLBACK", [])

        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

          query!(
            MigrationRepo,
            "DELETE FROM content.upload_grants WHERE id = $1",
            [grant_id]
          )
        end)

        Ecto.Migrator.run(
          MigrationRepo,
          migrations_path,
          :up,
          all: true,
          log: false
        )
      after
        Code.compiler_options(compiler_options)
        GenServer.stop(observer_connection)
        GenServer.stop(blocker_connection)
        Supervisor.stop(migration_repo)
      end
    end
  end

  @tag :with_private_notes
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

  test "Task 15 audit contract deterministically migrates legacy actor and target rows" do
    %{one: one, two: two} = Fixtures.two_vaults!()

    {fixture, decoy_principal_id} =
      if one.principal_id > two.principal_id do
        {one, two.principal_id}
      else
        {two, one.principal_id}
      end

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_members (principal_id, vault_id)
        VALUES ($1, $2)
        """,
        [decoy_principal_id, fixture.vault_id]
      )
    end)

    assert fixture.principal_id > decoy_principal_id

    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    system_event_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    anonymous_event_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    system_correlation_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    anonymous_correlation_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    anonymous_fingerprint = :crypto.hash(:sha256, "legacy-anonymous")
    fixture_principal_id = fixture.principal_id
    fixture_vault_id = fixture.vault_id
    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert [
               20_260_729_000_100,
               20_260_728_000_100,
               20_260_722_001_000,
               20_260_722_000_900,
               20_260_722_000_800,
               20_260_722_000_700
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 6,
                 log: false
               )

      {:ok, :ok} =
        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

          query!(
            MigrationRepo,
            """
            INSERT INTO audit.events (
              id,
              vault_id,
              actor_kind,
              principal_id,
              operation,
              result,
              classification,
              correlation_id,
              occurred_at
            ) VALUES (
              $1, $2, 'system', $3, 'outbox.claim', 'completed',
              'private', $4, CURRENT_TIMESTAMP
            )
            """,
            [
              system_event_id,
              fixture.vault_id,
              fixture.principal_id,
              system_correlation_id
            ]
          )

          query!(
            MigrationRepo,
            """
            INSERT INTO audit.events (
              id,
              actor_kind,
              anonymous_fingerprint,
              operation,
              result,
              classification,
              correlation_id,
              occurred_at
            ) VALUES (
              $1, 'anonymous', $2, 'identity.authentication_attempt',
              'denied', 'private', $3, CURRENT_TIMESTAMP
            )
            """,
            [
              anonymous_event_id,
              anonymous_fingerprint,
              anonymous_correlation_id
            ]
          )

          :ok
        end)

      assert [20_260_722_000_700] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 1,
                 log: false
               )

      assert %{
               rows: [
                 [
                   nil,
                   ^fixture_vault_id,
                   nil,
                   "singularity.system",
                   "audit_event",
                   ^system_event_id,
                   %{"initiating_principal_id" => initiating_principal_id}
                 ]
               ]
             } =
               owner_query!(
                 """
                 SELECT
                   principal_id,
                   vault_id,
                   anonymous_fingerprint,
                   system_principal_name,
                   target_type,
                   target_id,
                   metadata
                 FROM audit.events
                 WHERE id = $1
                 """,
                 [system_event_id]
               )

      assert initiating_principal_id == Ecto.UUID.load!(fixture.principal_id)

      assert %{
               rows: [
                 [
                   nil,
                   nil,
                   ^anonymous_fingerprint,
                   nil,
                   "audit_event",
                   ^anonymous_event_id
                 ]
               ]
             } =
               owner_query!(
                 """
                 SELECT
                   principal_id,
                   vault_id,
                   anonymous_fingerprint,
                   system_principal_name,
                   target_type,
                   target_id
                 FROM audit.events
                 WHERE id = $1
                 """,
                 [anonymous_event_id]
               )

      assert [20_260_722_000_700] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 1,
                 log: false
               )

      assert %{rows: [[^fixture_principal_id, "audit_event", ^system_event_id]]} =
               owner_query!(
                 """
                 SELECT principal_id, target_type, target_id
                 FROM audit.events
                 WHERE id = $1
                 """,
                 [system_event_id]
               )

      assert [20_260_722_000_700] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 1,
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
        Code.compiler_options(compiler_options)
        Supervisor.stop(migration_repo)
      end
    end
  end

  test "Task 15 audit downgrade rejects named system attribution without an initiating principal" do
    %{one: fixture} = Fixtures.two_vaults!()
    baseline_event_ids = assert_precise_audit_baseline_cleanup!(fixture)
    event_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    correlation_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    fixture_vault_id = fixture.vault_id
    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)

    try do
      {:ok, :ok} =
        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")

          query!(
            MigrationRepo,
            """
            INSERT INTO audit.events (
              id,
              vault_id,
              actor_kind,
              system_principal_name,
              operation,
              result,
              classification,
              correlation_id,
              target_type,
              target_id,
              occurred_at
            ) VALUES (
              $1,
              $2,
              'system',
              'integrity_audit',
              'integrity.audit_completed',
              'completed',
              'private',
              $3,
              'vault',
              $2,
              CURRENT_TIMESTAMP
            )
            """,
            [event_id, fixture.vault_id, correlation_id]
          )

          :ok
        end)

      assert_raise Postgrex.Error,
                   ~r/cannot downgrade Task 15.*initiating principal/i,
                   fn ->
                     Ecto.Migrator.down(
                       MigrationRepo,
                       20_260_722_000_700,
                       Singularity.Storage.Migrations.HardenAuditEventContract,
                       log: false
                     )
                   end

      assert %{
               rows: [
                 [
                   nil,
                   "integrity_audit",
                   %{},
                   "vault",
                   ^fixture_vault_id
                 ]
               ]
             } =
               owner_query!(
                 """
                 SELECT
                   principal_id,
                   system_principal_name,
                   metadata,
                   target_type,
                   target_id
                 FROM audit.events
                 WHERE id = $1
                 """,
                 [event_id]
               )
    after
      try do
        Ecto.Migrator.up(
          MigrationRepo,
          20_260_722_000_700,
          Singularity.Storage.Migrations.HardenAuditEventContract,
          log: false
        )

        MigrationRepo.transaction(fn ->
          query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
          delete_audit_events!([event_id | baseline_event_ids])
        end)
      after
        Supervisor.stop(migration_repo)
      end
    end
  end

  test "Task 15 anonymous audit migration binds one combined fingerprint to the final attempt" do
    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    login_fingerprint = :crypto.hash(:sha256, "bound-login-#{Ecto.UUID.generate()}")
    source_fingerprint = :crypto.hash(:sha256, "bound-source-#{Ecto.UUID.generate()}")
    audit_fingerprint = :crypto.hash(:sha256, login_fingerprint <> source_fingerprint)
    correlation_id = Ecto.UUID.generate()
    dumped_correlation_id = Ecto.UUID.dump!(correlation_id)
    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      assert %{rows: [[attempt_id, true]]} =
               record_auth_attempt!(
                 login_fingerprint,
                 source_fingerprint,
                 "started",
                 correlation_id,
                 nil
               )

      assert %{rows: [[0]]} =
               owner_query!(
                 "SELECT count(*) FROM audit.events WHERE correlation_id = $1",
                 [dumped_correlation_id]
               )

      assert %{rows: [[^attempt_id, false]]} =
               record_auth_attempt!(
                 login_fingerprint,
                 source_fingerprint,
                 "failed",
                 correlation_id,
                 attempt_id
               )

      assert %{
               rows: [
                 [
                   ^audit_fingerprint,
                   "authentication_attempt",
                   ^attempt_id,
                   "denied"
                 ]
               ]
             } =
               owner_query!(
                 """
                 SELECT anonymous_fingerprint, target_type, target_id, result
                 FROM audit.events
                 WHERE correlation_id = $1
                 """,
                 [dumped_correlation_id]
               )

      assert [
               20_260_729_000_100,
               20_260_728_000_100,
               20_260_722_001_000,
               20_260_722_000_900,
               20_260_722_000_800
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 5,
                 log: false
               )

      assert auth_definer_audit_insert_column_privileges() == [
               ["actor_kind", "INSERT"],
               ["anonymous_fingerprint", "INSERT"],
               ["classification", "INSERT"],
               ["correlation_id", "INSERT"],
               ["id", "INSERT"],
               ["occurred_at", "INSERT"],
               ["operation", "INSERT"],
               ["principal_id", "INSERT"],
               ["result", "INSERT"],
               ["vault_id", "INSERT"]
             ]

      legacy_login_fingerprint =
        :crypto.hash(:sha256, "legacy-login-#{Ecto.UUID.generate()}")

      legacy_source_fingerprint =
        :crypto.hash(:sha256, "legacy-source-#{Ecto.UUID.generate()}")

      legacy_correlation_id = Ecto.UUID.generate()
      dumped_legacy_correlation_id = Ecto.UUID.dump!(legacy_correlation_id)

      assert %{rows: [[legacy_attempt_id, true]]} =
               record_auth_attempt!(
                 legacy_login_fingerprint,
                 legacy_source_fingerprint,
                 "started",
                 legacy_correlation_id,
                 nil
               )

      assert %{rows: [[^legacy_attempt_id, false]]} =
               record_auth_attempt!(
                 legacy_login_fingerprint,
                 legacy_source_fingerprint,
                 "failed",
                 legacy_correlation_id,
                 legacy_attempt_id
               )

      assert %{
               rows: [
                 ["allowed", ^legacy_login_fingerprint, "audit_event", false],
                 ["denied", ^legacy_login_fingerprint, "audit_event", false]
               ]
             } =
               owner_query!(
                 """
                 SELECT
                   result,
                   anonymous_fingerprint,
                   target_type,
                   target_id = $2
                 FROM audit.events
                 WHERE correlation_id = $1
                 ORDER BY result
                 """,
                 [dumped_legacy_correlation_id, legacy_attempt_id]
               )

      assert [20_260_722_000_800] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 1,
                 log: false
               )

      assert auth_definer_audit_insert_column_privileges() == [
               ["actor_kind", "INSERT"],
               ["anonymous_fingerprint", "INSERT"],
               ["classification", "INSERT"],
               ["correlation_id", "INSERT"],
               ["id", "INSERT"],
               ["occurred_at", "INSERT"],
               ["operation", "INSERT"],
               ["principal_id", "INSERT"],
               ["result", "INSERT"],
               ["target_id", "INSERT"],
               ["target_type", "INSERT"],
               ["vault_id", "INSERT"]
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
        Code.compiler_options(compiler_options)
        Supervisor.stop(migration_repo)
      end
    end
  end

  test "Task 15 upload recovery timestamp migration preserves its least-privilege boundary" do
    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    expected_boundary = [
      [
        "singularity_table_owner",
        true,
        "s",
        ["search_path=pg_catalog, content, audit"],
        true,
        false
      ]
    ]

    try do
      assert %{rows: [["stage_id", "uuid"], ["storage_ref", "text"], ["stage_inserted_at", type]]} =
               recovery_result_columns()

      assert type =~ "timestamp with time zone"
      assert %{rows: ^expected_boundary} = recovery_function_boundary()

      assert [
               20_260_729_000_100,
               20_260_728_000_100,
               20_260_722_001_000,
               20_260_722_000_900
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 4,
                 log: false
               )

      assert %{rows: [["stage_id", "uuid"], ["storage_ref", "text"]]} =
               recovery_result_columns()

      assert %{rows: ^expected_boundary} = recovery_function_boundary()

      assert [20_260_722_000_900] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 1,
                 log: false
               )

      assert %{rows: [["stage_id", "uuid"], ["storage_ref", "text"], ["stage_inserted_at", _]]} =
               recovery_result_columns()

      assert %{rows: ^expected_boundary} = recovery_function_boundary()
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
        Code.compiler_options(compiler_options)
        Supervisor.stop(migration_repo)
      end
    end
  end

  test "Task 15 active domain envelope guard is role-safe and round-trips" do
    migrations_path =
      :singularity_storage
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("repo/migrations")

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    expected_boundary = [
      [
        "singularity_table_owner",
        true,
        "v",
        ["search_path=pg_catalog, core, content"],
        23,
        "O",
        ["domain_key_version_id", "key_domain_id", "key_generation", "vault_id"],
        false,
        false
      ]
    ]

    try do
      assert %{rows: ^expected_boundary} = active_domain_envelope_guard_boundary()

      assert [
               20_260_729_000_100,
               20_260_728_000_100,
               20_260_722_001_000
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 3,
                 log: false
               )

      assert %{rows: [[0, 0]]} = active_domain_envelope_guard_counts()

      assert [20_260_722_001_000] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 1,
                 log: false
               )

      assert %{rows: ^expected_boundary} = active_domain_envelope_guard_boundary()
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
        Code.compiler_options(compiler_options)
        Supervisor.stop(migration_repo)
      end
    end
  end

  test "Task 15 active domain envelope guard preserves independent generations" do
    fixture = active_domain_envelope_fixture!()

    assert :ok =
             insert_scoped_asset_key_envelope!(
               fixture,
               fixture.active_domain_key_version_id,
               3
             )

    for invalid_version_id <- [
          fixture.mismatched_domain_key_version_id,
          fixture.retired_domain_key_version_id
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          insert_scoped_asset_key_envelope!(fixture, invalid_version_id, 4)
        end

      assert error.postgres.constraint == "asset_key_envelopes_active_domain_key_check"
    end
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
               20_260_722_000_600,
               20_260_722_000_700,
               20_260_722_000_800,
               20_260_722_000_900,
               20_260_722_001_000,
               20_260_728_000_100,
               20_260_729_000_100,
               @notes_migration_version
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
               20_260_722_000_600,
               20_260_722_000_700,
               20_260_722_000_800,
               20_260_722_000_900,
               20_260_722_001_000,
               20_260_728_000_100,
               20_260_729_000_100,
               @notes_migration_version
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
               20_260_722_000_600,
               20_260_722_000_700,
               20_260_722_000_800,
               20_260_722_000_900,
               20_260_722_001_000,
               20_260_728_000_100,
               20_260_729_000_100,
               @notes_migration_version
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
               20_260_729_000_100,
               20_260_728_000_100,
               20_260_722_001_000,
               20_260_722_000_900,
               20_260_722_000_800,
               20_260_722_000_700,
               20_260_722_000_600,
               20_260_722_000_500,
               20_260_722_000_400,
               20_260_722_000_300
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 10,
                 log: false
               )

      assert backup_manifest_seal_constraints() == [
               ["backup_manifests_hash_check", "manifest_hash"]
             ]

      assert [
               20_260_722_000_300,
               20_260_722_000_400,
               20_260_722_000_500,
               20_260_722_000_600,
               20_260_722_000_700,
               20_260_722_000_800,
               20_260_722_000_900,
               20_260_722_001_000
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 8,
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
               20_260_729_000_100,
               20_260_728_000_100,
               20_260_722_001_000,
               20_260_722_000_900,
               20_260_722_000_800,
               20_260_722_000_700,
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
                 step: 11,
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
               20_260_722_000_600,
               20_260_722_000_700,
               20_260_722_000_800,
               20_260_722_000_900,
               20_260_722_001_000
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 9,
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
               20_260_729_000_100,
               20_260_728_000_100,
               20_260_722_001_000,
               20_260_722_000_900,
               20_260_722_000_800,
               20_260_722_000_700,
               20_260_722_000_600,
               20_260_722_000_500,
               20_260_722_000_400
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :down,
                 step: 9,
                 log: false
               )

      assert task14_backup_repository_contract() == [
               [0, false, false, true, true, true, true]
             ]

      assert [
               20_260_722_000_400,
               20_260_722_000_500,
               20_260_722_000_600,
               20_260_722_000_700,
               20_260_722_000_800,
               20_260_722_000_900,
               20_260_722_001_000
             ] =
               Ecto.Migrator.run(
                 MigrationRepo,
                 migrations_path,
                 :up,
                 step: 7,
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
          step: 7,
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

  @tag :with_private_notes
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
               20_260_729_000_100,
               20_260_728_000_100,
               20_260_722_001_000,
               20_260_722_000_900,
               20_260_722_000_800,
               20_260_722_000_700,
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
                 step: 13,
                 log: false
               )
    after
      Supervisor.stop(migration_repo)
      Code.compiler_options(compiler_options)
    end
  end

  defp upload_grant_retirement_contract do
    owner_query!(
      """
      SELECT
        EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema = 'content'
            AND table_name = 'upload_grants'
            AND column_name = 'retired_at'
        ),
        EXISTS (
          SELECT 1
          FROM pg_catalog.pg_constraint
          WHERE conrelid = 'content.upload_grants'::regclass
            AND conname = 'upload_grants_retirement_check'
        ),
        EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema = 'content'
            AND table_name = 'upload_grants'
            AND column_name = 'cancelled_at'
        ),
        (
          SELECT pg_get_constraintdef(oid)
          FROM pg_catalog.pg_constraint
          WHERE conrelid = 'content.upload_grants'::regclass
            AND conname = 'upload_grants_retirement_check'
        ),
        (
          SELECT indexdef
          FROM pg_catalog.pg_indexes
          WHERE schemaname = 'content'
            AND tablename = 'upload_grants'
            AND indexname = 'upload_grants_active_idempotency_key'
        )
      """,
      []
    )
  end

  defp wait_for_upload_grant_ddl_waiter!(connection, attempts \\ 200)

  defp wait_for_upload_grant_ddl_waiter!(_connection, 0) do
    flunk("timed out waiting for the Task 17 downgrade table lock")
  end

  defp wait_for_upload_grant_ddl_waiter!(connection, attempts) do
    %{rows: [[waiting?]]} =
      Postgrex.query!(
        connection,
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_catalog.pg_locks
          WHERE database = (
            SELECT oid
            FROM pg_catalog.pg_database
            WHERE datname = current_database()
          )
            AND relation = 'content.upload_grants'::regclass
            AND NOT granted
        )
        """,
        []
      )

    if waiting? do
      :ok
    else
      Process.sleep(10)
      wait_for_upload_grant_ddl_waiter!(connection, attempts - 1)
    end
  end

  defp postgrex_options do
    MigrationRepo.config()
    |> Keyword.take([
      :hostname,
      :socket_dir,
      :port,
      :database,
      :username,
      :password
    ])
  end

  defp assert_precise_audit_baseline_cleanup!(fixture) do
    event_ids = for _index <- 1..4, do: Ecto.UUID.generate() |> Ecto.UUID.dump!()
    correlation_ids = for _index <- 1..4, do: Ecto.UUID.generate() |> Ecto.UUID.dump!()

    [unmappable_id, mappable_id, principal_id, anonymous_id] = event_ids

    [unmappable_correlation, mappable_correlation, principal_correlation, anonymous_correlation] =
      correlation_ids

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO audit.events (
          id,
          vault_id,
          actor_kind,
          principal_id,
          anonymous_fingerprint,
          system_principal_name,
          operation,
          result,
          classification,
          correlation_id,
          target_type,
          target_id,
          metadata,
          occurred_at
        ) VALUES
          (
            $1, $5, 'system', NULL, NULL, 'migration_test.decoy',
            'migration_test.unmappable', 'completed', 'private', $6,
            'audit_event', $1, '{}'::jsonb, CURRENT_TIMESTAMP
          ),
          (
            $2, $5, 'system', NULL, NULL, 'migration_test.mappable',
            'migration_test.mappable', 'completed', 'private', $7,
            'audit_event', $2,
            jsonb_build_object('initiating_principal_id', $9::uuid),
            CURRENT_TIMESTAMP
          ),
          (
            $3, $5, 'principal', $9, NULL, NULL,
            'migration_test.principal', 'completed', 'private', $8,
            'audit_event', $3, '{}'::jsonb, CURRENT_TIMESTAMP
          ),
          (
            $4, NULL, 'anonymous', NULL, $10, NULL,
            'migration_test.anonymous', 'completed', 'private', $11,
            'audit_event', $4, '{}'::jsonb, CURRENT_TIMESTAMP
          )
        """,
        [
          unmappable_id,
          mappable_id,
          principal_id,
          anonymous_id,
          fixture.vault_id,
          unmappable_correlation,
          mappable_correlation,
          principal_correlation,
          fixture.principal_id,
          :crypto.hash(:sha256, "migration-test-anonymous"),
          anonymous_correlation
        ]
      )

      assert delete_unmappable_system_audit_events!() == 1

      assert %{rows: rows} =
               query!(
                 MigrationRepo,
                 """
                 SELECT operation, actor_kind
                 FROM audit.events
                 WHERE id = ANY($1::uuid[])
                 ORDER BY operation
                 """,
                 [event_ids]
               )

      assert rows == [
               ["migration_test.anonymous", "anonymous"],
               ["migration_test.mappable", "system"],
               ["migration_test.principal", "principal"]
             ]

      event_ids
    end)
  end

  defp delete_unmappable_system_audit_events! do
    with_mutable_audit_events!(fn ->
      %{num_rows: deleted_count} =
        query!(
          MigrationRepo,
          """
          DELETE FROM audit.events AS event
          WHERE event.actor_kind = 'system'
            AND NOT EXISTS (
              SELECT 1
              FROM core.vault_members AS member
              WHERE member.vault_id = event.vault_id
                AND member.principal_id::text =
                  event.metadata ->> 'initiating_principal_id'
            )
          """
        )

      deleted_count
    end)
  end

  defp delete_audit_events!(event_ids) do
    with_mutable_audit_events!(fn ->
      query!(
        MigrationRepo,
        "DELETE FROM audit.events WHERE id = ANY($1::uuid[])",
        [event_ids]
      )
    end)
  end

  defp with_mutable_audit_events!(operation) do
    query!(MigrationRepo, "ALTER TABLE audit.events DISABLE TRIGGER events_immutable")

    try do
      operation.()
    after
      query!(MigrationRepo, "ALTER TABLE audit.events ENABLE TRIGGER events_immutable")
    end
  end

  defp owner_query!(statement, parameters) do
    {:ok, result} =
      MigrationRepo.transaction(fn ->
        query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
        query!(MigrationRepo, statement, parameters)
      end)

    result
  end

  defp record_auth_attempt!(
         login_fingerprint,
         source_fingerprint,
         result,
         correlation_id,
         attempt_id
       ) do
    query!(
      PreAuthRepo,
      "SELECT * FROM identity.record_auth_attempt($1, $2, $3, $4, $5)",
      [
        login_fingerprint,
        source_fingerprint,
        result,
        Ecto.UUID.dump!(correlation_id),
        attempt_id
      ]
    )
  end

  defp auth_definer_audit_insert_column_privileges do
    %{rows: rows} =
      owner_query!(
        """
        SELECT column_name, privilege_type
        FROM information_schema.column_privileges
        WHERE table_schema = 'audit'
          AND table_name = 'events'
          AND grantee = 'singularity_auth_definer'
          AND privilege_type = 'INSERT'
        ORDER BY column_name, privilege_type
        """,
        []
      )

    rows
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

  defp recovery_result_columns do
    query!(
      RequestRepo,
      """
      SELECT argument.name, pg_catalog.format_type(argument.type_oid, NULL)
      FROM pg_catalog.pg_proc AS procedure
      CROSS JOIN LATERAL unnest(
        procedure.proallargtypes,
        procedure.proargmodes,
        procedure.proargnames
      ) WITH ORDINALITY AS argument(type_oid, mode, name, position)
      WHERE procedure.oid =
        'content.list_open_upload_stages()'::regprocedure
        AND argument.mode IN ('o', 't')
      ORDER BY argument.position
      """
    )
  end

  defp recovery_function_boundary do
    query!(
      RequestRepo,
      """
      SELECT
        owner.rolname,
        procedure.prosecdef,
        procedure.provolatile::text,
        procedure.proconfig,
        has_function_privilege(
          'singularity_worker',
          procedure.oid,
          'EXECUTE'
        ),
        has_function_privilege('public', procedure.oid, 'EXECUTE')
      FROM pg_catalog.pg_proc AS procedure
      JOIN pg_catalog.pg_roles AS owner ON owner.oid = procedure.proowner
      WHERE procedure.oid =
        'content.list_open_upload_stages()'::regprocedure
      """
    )
  end

  defp active_domain_envelope_guard_boundary do
    query!(
      RequestRepo,
      """
      SELECT
        owner.rolname,
        procedure.prosecdef,
        procedure.provolatile::text,
        procedure.proconfig,
        trigger.tgtype,
        trigger.tgenabled::text,
        ARRAY(
          SELECT attribute.attname
          FROM unnest(trigger.tgattr::smallint[]) AS guarded(attnum)
          JOIN pg_catalog.pg_attribute AS attribute
            ON attribute.attrelid = trigger.tgrelid
           AND attribute.attnum = guarded.attnum
          ORDER BY attribute.attname
        ),
        has_function_privilege('public', procedure.oid, 'EXECUTE'),
        has_function_privilege('singularity_web', procedure.oid, 'EXECUTE')
      FROM pg_catalog.pg_proc AS procedure
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = procedure.pronamespace
      JOIN pg_catalog.pg_roles AS owner
        ON owner.oid = procedure.proowner
      JOIN pg_catalog.pg_trigger AS trigger
        ON trigger.tgfoid = procedure.oid
       AND trigger.tgrelid = 'content.asset_key_envelopes'::regclass
       AND trigger.tgname = 'asset_key_envelopes_active_domain_key'
       AND NOT trigger.tgisinternal
      WHERE namespace.nspname = 'content'
        AND procedure.proname = 'enforce_active_domain_key_envelope'
      """
    )
  end

  defp active_domain_envelope_guard_counts do
    query!(
      RequestRepo,
      """
      SELECT
        (
          SELECT count(*)
          FROM pg_catalog.pg_proc AS procedure
          JOIN pg_catalog.pg_namespace AS namespace
            ON namespace.oid = procedure.pronamespace
          WHERE namespace.nspname = 'content'
            AND procedure.proname = 'enforce_active_domain_key_envelope'
        ),
        (
          SELECT count(*)
          FROM pg_catalog.pg_trigger
          WHERE tgrelid = 'content.asset_key_envelopes'::regclass
            AND tgname = 'asset_key_envelopes_active_domain_key'
            AND NOT tgisinternal
        )
      """
    )
  end

  defp active_domain_envelope_fixture! do
    %{one: raw} = Fixtures.two_vaults!()

    fixture = %{
      active_domain_key_version_id: Ecto.UUID.generate(),
      key_domain_id: Ecto.UUID.generate(),
      mismatched_domain_key_version_id: Ecto.UUID.generate(),
      mismatched_key_domain_id: Ecto.UUID.generate(),
      object_id: Ecto.UUID.generate(),
      principal_id: Ecto.UUID.load!(raw.principal_id),
      retired_domain_key_version_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.load!(raw.vault_id),
      vault_key_version_id: Ecto.UUID.generate()
    }

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 1, 'active', 'aes_256_gcm', CURRENT_TIMESTAMP)
        """,
        [Ecto.UUID.dump!(fixture.vault_key_version_id), raw.vault_id]
      )

      for key_domain_id <- [fixture.key_domain_id, fixture.mismatched_key_domain_id] do
        query!(
          MigrationRepo,
          """
          INSERT INTO core.key_domains (
            id, vault_id, classification, kind, state
          ) VALUES ($1, $2, 'private', 'content', 'active')
          """,
          [Ecto.UUID.dump!(key_domain_id), raw.vault_id]
        )
      end

      for {id, key_domain_id, generation, state} <- [
            {fixture.active_domain_key_version_id, fixture.key_domain_id, 5, "active"},
            {
              fixture.mismatched_domain_key_version_id,
              fixture.mismatched_key_domain_id,
              6,
              "active"
            },
            {fixture.retired_domain_key_version_id, fixture.key_domain_id, 7, "retired"}
          ] do
        query!(
          MigrationRepo,
          """
          INSERT INTO core.domain_key_versions (
            id, vault_id, key_domain_id, vault_key_version_id, generation,
            state, algorithm, wrapped_key
          ) VALUES ($1, $2, $3, $4, $5, $6, 'aes_256_gcm', $7)
          """,
          [
            Ecto.UUID.dump!(id),
            raw.vault_id,
            Ecto.UUID.dump!(key_domain_id),
            Ecto.UUID.dump!(fixture.vault_key_version_id),
            generation,
            state,
            :crypto.strong_rand_bytes(60)
          ]
        )
      end

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_objects (
          id, vault_id, key_domain_id, classification, lookup_digest,
          ciphertext_hash, plaintext_byte_size, ciphertext_byte_size,
          storage_ref, format_version, lifecycle
        ) VALUES ($1, $2, $3, 'private', $4, $5, 31, 189, $6, 1, 'available')
        """,
        [
          Ecto.UUID.dump!(fixture.object_id),
          raw.vault_id,
          Ecto.UUID.dump!(fixture.key_domain_id),
          :crypto.strong_rand_bytes(32),
          :crypto.strong_rand_bytes(32),
          fixture.object_id
        ]
      )
    end)

    fixture
  end

  defp insert_scoped_asset_key_envelope!(fixture, domain_key_version_id, key_generation) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      fn repo ->
        query!(
          repo,
          """
          INSERT INTO content.asset_key_envelopes (
            id, vault_id, asset_object_id, domain_key_version_id, key_domain_id,
            classification, algorithm, key_generation, wrapped_dek
          ) VALUES ($1, $2, $3, $4, $5, 'private', 'aes_256_gcm', $6, $7)
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(fixture.vault_id),
            Ecto.UUID.dump!(fixture.object_id),
            Ecto.UUID.dump!(domain_key_version_id),
            Ecto.UUID.dump!(fixture.key_domain_id),
            key_generation,
            :crypto.strong_rand_bytes(60)
          ]
        )

        :ok
      end
    )
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
