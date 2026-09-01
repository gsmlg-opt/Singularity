defmodule Singularity.Storage.WakeGenerationMigrationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Schema.Jobs.JobSubmission

  @version 20_260_901_000_200
  @migration Singularity.Storage.Migrations.MoveWakeGenerationsToJobSubmissions
  @generic_worker "Singularity.Storage.Jobs.GenericWorker"
  @reconciler "Singularity.Storage.Jobs.WakeReconciler"

  setup do
    %{one: fixture} = Fixtures.two_vaults!()
    event = Fixtures.outbox_event!(fixture)
    runtime_started? = runtime_started?()

    {:ok, migration_repo} = MigrationRepo.start_link(pool_size: 2)
    Process.unlink(migration_repo)

    on_exit(fn ->
      try do
        cleanup_test_state!(event.id)

        if Code.ensure_loaded?(@migration) and not migration_up?() do
          assert :ok = Ecto.Migrator.up(MigrationRepo, @version, @migration, log: false)
        end

        if Code.ensure_loaded?(@migration), do: assert(migration_up?())
      after
        if Process.alive?(migration_repo), do: Supervisor.stop(migration_repo)
      end

      if runtime_started? do
        assert {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
      end
    end)

    if runtime_started?, do: assert(:ok == Application.stop(:singularity_runtime))

    if migration_up?() do
      assert :ok = Ecto.Migrator.down(MigrationRepo, @version, @migration, log: false)
    end

    %{event: event, fixture: fixture}
  end

  test "JobSubmission exposes zero application-owned wake defaults" do
    submission = struct(JobSubmission)

    assert Map.fetch(submission, :wake_requested_generation) == {:ok, 0}
    assert Map.fetch(submission, :wake_consumed_generation) == {:ok, 0}
    assert JobSubmission.__schema__(:type, :wake_requested_generation) == :integer
    assert JobSubmission.__schema__(:type, :wake_consumed_generation) == :integer

    changeset =
      JobSubmission.wake_generation_changeset(submission, %{
        wake_requested_generation: 1,
        wake_consumed_generation: 1
      })

    assert changeset.changes == %{
             wake_requested_generation: 1,
             wake_consumed_generation: 1
           }

    assert Enum.any?(changeset.constraints, fn constraint ->
             constraint.constraint == "job_submissions_wake_generations_check" and
               constraint.field == :wake_consumed_generation
           end)

    reserve_changeset =
      JobSubmission.reserve_changeset(submission, %{
        id: Ecto.UUID.generate(),
        vault_id: Ecto.UUID.generate(),
        outbox_event_id: Ecto.UUID.generate(),
        classification: :private,
        idempotency_key: "caller-cannot-set-wake-generations",
        job_type: "asset_verify",
        wake_requested_generation: 99,
        wake_consumed_generation: 98
      })

    refute Map.has_key?(reserve_changeset.changes, :wake_requested_generation)
    refute Map.has_key?(reserve_changeset.changes, :wake_consumed_generation)
  end

  test "transfers valid legacy target generations exactly",
       %{event: event, fixture: fixture} do
    %{submission_id: submission_id} =
      insert_legacy_submission!(fixture, event, %{
        "singularity_wake_requested_generation" => 5,
        "singularity_wake_consumed_generation" => 3
      })

    migrate_up!()

    assert wake_generations!(submission_id) == {5, 3}
  end

  test "normalizes legacy consumed generation above requested generation",
       %{event: event, fixture: fixture} do
    %{submission_id: submission_id} =
      insert_legacy_submission!(fixture, event, %{
        "singularity_wake_requested_generation" => 1,
        "singularity_wake_consumed_generation" => 4
      })

    migrate_up!()

    assert wake_generations!(submission_id) == {4, 4}
  end

  test "submission without a matching GenericWorker target keeps zero defaults",
       %{event: event, fixture: fixture} do
    owner_transaction(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO jobs.job_submissions (
          id,
          vault_id,
          outbox_event_id,
          classification,
          idempotency_key,
          job_type,
          runner_job_id
        ) VALUES ($1, $2, $1, 'private', $3, 'asset_verify', '999999999')
        """,
        [event.id, fixture.vault_id, "unmatched-wake-#{Ecto.UUID.load!(event.id)}"]
      )
    end)

    migrate_up!()

    assert wake_generations!(event.id) == {0, 0}
  end

  test "submission pointing to a non-GenericWorker target keeps zero defaults",
       %{event: event, fixture: fixture} do
    owner_transaction(fn ->
      target_id =
        insert_oban_job!(
          "scheduled",
          "Singularity.Storage.Jobs.OtherWorker",
          %{"job_id" => Ecto.UUID.load!(event.id)},
          %{
            "singularity_wake_requested_generation" => 5,
            "singularity_wake_consumed_generation" => 3
          },
          Ecto.UUID.load!(event.id)
        )

      query!(
        MigrationRepo,
        """
        INSERT INTO jobs.job_submissions (
          id,
          vault_id,
          outbox_event_id,
          classification,
          idempotency_key,
          job_type,
          runner_job_id
        ) VALUES ($1, $2, $1, 'private', $3, 'asset_verify', $4)
        """,
        [
          event.id,
          fixture.vault_id,
          "non-generic-wake-#{Ecto.UUID.load!(event.id)}",
          Integer.to_string(target_id)
        ]
      )
    end)

    migrate_up!()

    assert wake_generations!(event.id) == {0, 0}
  end

  test "adds bounded wake counters and transfers legacy and reconciler generations",
       %{event: event, fixture: fixture} do
    legacy_meta = %{
      "singularity_wake_requested_generation" => 5,
      "singularity_wake_consumed_generation" => 3,
      "unrelated" => "preserved"
    }

    %{submission_id: submission_id, target_id: target_id} =
      insert_legacy_submission!(fixture, event, legacy_meta, [
        {"available", 4},
        {"scheduled", 7},
        {"executing", 6},
        {"retryable", 2},
        {"completed", 99},
        {"discarded", 100},
        {"cancelled", 101}
      ])

    migrate_up!()

    assert wake_columns_exist?()
    assert wake_generations!(submission_id) == {7, 3}

    expected_meta =
      Map.put(legacy_meta, "wake_migration_test_id", Ecto.UUID.load!(event.id))

    assert %{rows: [[^expected_meta]]} =
             owner_query!("SELECT meta FROM jobs.oban_jobs WHERE id = $1", [target_id])

    assert %{rows: column_rows} =
             owner_query!("""
             SELECT
               column_name,
               data_type,
               is_nullable,
               column_default
             FROM information_schema.columns
             WHERE table_schema = 'jobs'
               AND table_name = 'job_submissions'
               AND column_name IN (
                 'wake_requested_generation',
                 'wake_consumed_generation'
               )
             ORDER BY column_name
             """)

    assert [
             ["wake_consumed_generation", "bigint", "NO", consumed_default],
             ["wake_requested_generation", "bigint", "NO", requested_default]
           ] = column_rows

    assert consumed_default =~ "0"
    assert requested_default =~ "0"

    assert %{rows: [[constraint_definition]]} =
             owner_query!("""
             SELECT pg_get_constraintdef(oid)
             FROM pg_catalog.pg_constraint
             WHERE conrelid = 'jobs.job_submissions'::regclass
               AND conname = 'job_submissions_wake_generations_check'
             """)

    assert constraint_definition =~ "wake_requested_generation >= 0"
    assert constraint_definition =~ "wake_consumed_generation >= 0"

    assert constraint_definition =~
             "wake_consumed_generation <= wake_requested_generation"
  end

  test "active reconciler recovers a generation erased from target metadata",
       %{event: event, fixture: fixture} do
    %{submission_id: submission_id} =
      insert_legacy_submission!(
        fixture,
        event,
        %{
          "singularity_wake_requested_generation" => 1,
          "singularity_wake_consumed_generation" => 1
        },
        [{"scheduled", 4}]
      )

    migrate_up!()

    assert wake_generations!(submission_id) == {4, 1}
  end

  test "rejects malformed legacy target generations before casting",
       %{event: event, fixture: fixture} do
    invalid_values = ["1", -1, 1.5, nil, 9_223_372_036_854_775_808]

    for key <- [
          "singularity_wake_requested_generation",
          "singularity_wake_consumed_generation"
        ],
        value <- invalid_values do
      %{submission_id: submission_id} =
        insert_legacy_submission!(fixture, event, %{key => value})

      error =
        assert_raise Postgrex.Error,
                     ~r/invalid legacy Singularity wake generation/i,
                     fn ->
                       Ecto.Migrator.up(MigrationRepo, @version, @migration, log: false)
                     end

      assert error.postgres.code == :invalid_parameter_value

      refute migration_up?()
      refute wake_columns_exist?()
      delete_legacy_submission!(submission_id)
    end
  end

  test "rejects malformed active reconciler generations before casting",
       %{event: event, fixture: fixture} do
    for value <- ["1", -1, 0, 1.5, nil, 9_223_372_036_854_775_808] do
      %{submission_id: submission_id} =
        insert_legacy_submission!(fixture, event, %{}, [{"scheduled", value}])

      error =
        assert_raise Postgrex.Error,
                     ~r/invalid active wake reconciler generation/i,
                     fn ->
                       Ecto.Migrator.up(MigrationRepo, @version, @migration, log: false)
                     end

      assert error.postgres.code == :invalid_parameter_value

      refute migration_up?()
      refute wake_columns_exist?()
      delete_legacy_submission!(submission_id)
    end
  end

  test "terminal and unmatched malformed reconcilers do not poison valid migration",
       %{event: event, fixture: fixture} do
    %{submission_id: submission_id, target_id: target_id} =
      insert_legacy_submission!(
        fixture,
        event,
        %{
          "singularity_wake_requested_generation" => 5,
          "singularity_wake_consumed_generation" => 3
        },
        [{"completed", "malformed"}]
      )

    owner_transaction(fn ->
      insert_oban_job!(
        "scheduled",
        @reconciler,
        %{
          "target_job_id" => target_id + 1_000_000,
          "wake_generation" => "malformed"
        },
        %{},
        Ecto.UUID.load!(event.id)
      )
    end)

    migrate_up!()

    assert wake_generations!(submission_id) == {5, 3}
  end

  test "database defaults and named constraint bound wake generations",
       %{event: event, fixture: fixture} do
    migrate_up!()

    %{submission_id: submission_id} = insert_legacy_submission!(fixture, event, %{})

    for {requested, consumed} <- [{-1, 0}, {0, -1}, {1, 2}] do
      assert_raise Postgrex.Error,
                   ~r/job_submissions_wake_generations_check/,
                   fn ->
                     owner_transaction(fn ->
                       query!(
                         MigrationRepo,
                         """
                         UPDATE jobs.job_submissions
                         SET wake_requested_generation = $2,
                             wake_consumed_generation = $3
                         WHERE id = $1
                         """,
                         [submission_id, requested, consumed]
                       )
                     end)
                   end
    end

    assert wake_generations!(submission_id) == {0, 0}
  end

  test "downgrade refuses pending, active reconciler, and live peer state in order",
       %{event: event, fixture: fixture} do
    %{reconciler_ids: [reconciler_id], submission_id: submission_id} =
      insert_legacy_submission!(fixture, event, %{}, [{"scheduled", 2}])

    migrate_up!()

    owner_transaction(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE jobs.job_submissions
        SET wake_requested_generation = 2,
            wake_consumed_generation = 1
        WHERE id = $1
        """,
        [submission_id]
      )
    end)

    error =
      assert_raise Postgrex.Error, ~r/pending wake generations/i, fn -> migrate_down!() end

    assert error.postgres.code == :object_not_in_prerequisite_state

    owner_transaction(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE jobs.job_submissions
        SET wake_consumed_generation = wake_requested_generation
        WHERE id = $1
        """,
        [submission_id]
      )
    end)

    error =
      assert_raise Postgrex.Error, ~r/active wake reconcilers/i, fn -> migrate_down!() end

    assert error.postgres.code == :object_not_in_prerequisite_state

    owner_transaction(fn ->
      query!(
        MigrationRepo,
        "UPDATE jobs.oban_jobs SET state = 'completed' WHERE id = $1",
        [reconciler_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO jobs.oban_peers (name, node, started_at, expires_at)
        VALUES (
          'wake-migration-test',
          'test@localhost',
          CURRENT_TIMESTAMP,
          CURRENT_TIMESTAMP + interval '1 minute'
        )
        """
      )
    end)

    error =
      assert_raise Postgrex.Error, ~r/Oban peers are active/i, fn -> migrate_down!() end

    assert error.postgres.code == :object_not_in_prerequisite_state

    owner_transaction(fn ->
      query!(MigrationRepo, "DELETE FROM jobs.oban_peers WHERE name = 'wake-migration-test'")
    end)

    migrate_down!()
    refute wake_columns_exist?()
  end

  test "downgrade recognizes UTC-naive live peers in a non-UTC session" do
    migrate_up!()

    owner_transaction(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO jobs.oban_peers (name, node, started_at, expires_at)
        VALUES (
          'wake-migration-test',
          'test@localhost',
          CURRENT_TIMESTAMP AT TIME ZONE 'UTC',
          (CURRENT_TIMESTAMP AT TIME ZONE 'UTC') + interval '1 minute'
        )
        """
      )
    end)

    try do
      set_migration_pool_timezone!("Asia/Shanghai")

      error =
        assert_raise Postgrex.Error, ~r/Oban peers are active/i, fn -> migrate_down!() end

      assert error.postgres.code == :object_not_in_prerequisite_state
    after
      set_migration_pool_timezone!("UTC")
    end
  end

  defp runtime_started? do
    Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
      app == :singularity_runtime
    end)
  end

  defp migration_up? do
    %{rows: rows} =
      query!(
        MigrationRepo,
        "SELECT 1 FROM public.schema_migrations WHERE version = $1",
        [@version]
      )

    rows == [[1]]
  end

  defp migrate_up! do
    assert :ok = Ecto.Migrator.up(MigrationRepo, @version, @migration, log: false)
  end

  defp migrate_down! do
    assert :ok = Ecto.Migrator.down(MigrationRepo, @version, @migration, log: false)
  end

  defp cleanup_test_state!(event_id) do
    test_id = Ecto.UUID.load!(event_id)

    owner_transaction(fn ->
      query!(
        MigrationRepo,
        "DELETE FROM jobs.oban_jobs WHERE meta->>'wake_migration_test_id' = $1",
        [test_id]
      )

      query!(
        MigrationRepo,
        "DELETE FROM jobs.job_submissions WHERE outbox_event_id = $1",
        [event_id]
      )

      query!(
        MigrationRepo,
        "DELETE FROM core.outbox_events WHERE id = $1",
        [event_id]
      )

      query!(
        MigrationRepo,
        "DELETE FROM jobs.oban_peers WHERE name = 'wake-migration-test'"
      )
    end)
  end

  defp insert_legacy_submission!(fixture, event, meta, reconcilers \\ []) do
    owner_transaction(fn ->
      test_id = Ecto.UUID.load!(event.id)

      target_id =
        insert_oban_job!(
          "scheduled",
          @generic_worker,
          %{"job_id" => Ecto.UUID.load!(event.id)},
          meta,
          test_id
        )

      query!(
        MigrationRepo,
        """
        INSERT INTO jobs.job_submissions (
          id,
          vault_id,
          outbox_event_id,
          classification,
          idempotency_key,
          job_type,
          runner_job_id
        ) VALUES ($1, $2, $1, 'private', $3, 'asset_verify', $4)
        """,
        [
          event.id,
          fixture.vault_id,
          "legacy-wake-#{Ecto.UUID.load!(event.id)}",
          Integer.to_string(target_id)
        ]
      )

      reconciler_ids =
        Enum.map(reconcilers, fn {state, generation} ->
          insert_oban_job!(
            state,
            @reconciler,
            %{
              "target_job_id" => target_id,
              "wake_generation" => generation
            },
            %{},
            test_id
          )
        end)

      %{reconciler_ids: reconciler_ids, submission_id: event.id, target_id: target_id}
    end)
  end

  defp insert_oban_job!(state, worker, args, meta, test_id) do
    meta = Map.put(meta, "wake_migration_test_id", test_id)

    %{rows: [[job_id]]} =
      query!(
        MigrationRepo,
        """
        INSERT INTO jobs.oban_jobs (
          state,
          queue,
          worker,
          args,
          meta,
          scheduled_at
        ) VALUES (
          $1,
          'maintenance',
          $2,
          $3::text::jsonb,
          $4::text::jsonb,
          CURRENT_TIMESTAMP + interval '1 day'
        )
        RETURNING id
        """,
        [state, worker, JSON.encode!(args), JSON.encode!(meta)]
      )

    job_id
  end

  defp delete_legacy_submission!(submission_id) do
    test_id = Ecto.UUID.load!(submission_id)

    owner_transaction(fn ->
      %{rows: [[runner_job_id]]} =
        query!(
          MigrationRepo,
          "SELECT runner_job_id FROM jobs.job_submissions WHERE id = $1",
          [submission_id]
        )

      query!(
        MigrationRepo,
        """
        DELETE FROM jobs.oban_jobs
        WHERE meta->>'wake_migration_test_id' = $1
          AND (
            id::text = $2
            OR (worker = $3 AND args->>'target_job_id' = $2)
          )
        """,
        [test_id, runner_job_id, @reconciler]
      )

      query!(
        MigrationRepo,
        """
        DELETE FROM jobs.job_submissions
        WHERE id = $1 AND outbox_event_id = $1
        """,
        [submission_id]
      )
    end)
  end

  defp owner_transaction(fun) do
    assert {:ok, result} =
             MigrationRepo.transaction(fn ->
               query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner")
               fun.()
             end)

    result
  end

  defp owner_query!(statement, params \\ []) do
    owner_transaction(fn -> query!(MigrationRepo, statement, params) end)
  end

  defp set_migration_pool_timezone!(timezone) do
    parent = self()

    holders =
      Enum.map(1..2, fn _index ->
        Task.async(fn ->
          MigrationRepo.checkout(fn ->
            assert %{rows: [[^timezone]]} =
                     query!(
                       MigrationRepo,
                       "SELECT set_config('TimeZone', $1, false)",
                       [timezone]
                     )

            send(parent, {:migration_timezone_set, self()})

            receive do
              {:release_migration_connection, ^parent} -> :ok
            end
          end)
        end)
      end)

    try do
      Enum.each(holders, fn holder ->
        holder_pid = holder.pid
        assert_receive {:migration_timezone_set, ^holder_pid}, 5_000
      end)
    after
      Enum.each(holders, fn holder ->
        send(holder.pid, {:release_migration_connection, parent})
      end)
    end

    Enum.each(holders, fn holder ->
      assert Task.await(holder, 5_000) == :ok
    end)
  end

  defp wake_generations!(submission_id) do
    %{rows: [[requested, consumed]]} =
      owner_query!(
        """
        SELECT wake_requested_generation, wake_consumed_generation
        FROM jobs.job_submissions
        WHERE id = $1
        """,
        [submission_id]
      )

    {requested, consumed}
  end

  defp wake_columns_exist? do
    %{rows: [[count]]} =
      owner_query!("""
      SELECT count(*)
      FROM information_schema.columns
      WHERE table_schema = 'jobs'
        AND table_name = 'job_submissions'
        AND column_name IN (
          'wake_requested_generation',
          'wake_consumed_generation'
        )
      """)

    count == 2
  end
end
