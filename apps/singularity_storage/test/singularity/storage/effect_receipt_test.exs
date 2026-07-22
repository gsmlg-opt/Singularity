defmodule Singularity.Storage.EffectReceiptTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  import Ecto.Query, only: [from: 2]

  alias Singularity.Core.JobEnvelope
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Jobs.EnvelopeCodec
  alias Singularity.Storage.Jobs.GenericWorker
  alias Singularity.Storage.Jobs.ObanAdapter
  alias Singularity.Storage.Jobs.Progress
  alias Singularity.Storage.Jobs.WakeReconciler
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.Schema.Jobs.EffectReceipt

  setup do
    previous_handler = Application.get_env(:singularity_storage, :job_handler)

    previous_fake_dependencies =
      Application.get_env(:singularity_storage, :fake_job_dependencies)

    external_effects =
      start_supervised!({Agent, fn -> %{applied: MapSet.new(), calls: %{}} end})

    Application.put_env(
      :singularity_storage,
      :job_handler,
      Singularity.Storage.Fake.JobHandler
    )

    Application.put_env(:singularity_storage, :fake_job_dependencies, %{
      crash_after_external_effect?: false,
      external_effects: external_effects,
      observer: self()
    })

    on_exit(fn ->
      if previous_handler do
        Application.put_env(:singularity_storage, :job_handler, previous_handler)
      else
        Application.delete_env(:singularity_storage, :job_handler)
      end

      if previous_fake_dependencies do
        Application.put_env(
          :singularity_storage,
          :fake_job_dependencies,
          previous_fake_dependencies
        )
      else
        Application.delete_env(:singularity_storage, :fake_job_dependencies)
      end
    end)

    assert Oban.whereis(Singularity.Oban)
    complete_existing_oban_jobs!()
    %{external_effects: external_effects, fixture: Fixtures.two_vaults!().one}
  end

  test "an Oban retry after a post-effect worker crash applies one logical external effect",
       %{external_effects: external_effects, fixture: fixture} do
    Application.put_env(:singularity_storage, :fake_job_dependencies, %{
      crash_after_external_effect?: true,
      external_effects: external_effects,
      observer: self()
    })

    envelope = submitted_envelope(fixture, 0)
    runner_id = runner_id(envelope)

    assert %{failure: 1, snoozed: 0, success: 0} =
             Oban.drain_queue(Singularity.Oban, queue: :asset_verify)

    assert_receive {:job_phase, 1, phase_one, WorkerRepo}
    assert_receive {:external_effect, effect_key}
    assert_receive {:crash_after_external_effect, ^effect_key}
    refute_receive {:job_phase, 2, _phase_two, WorkerRepo}

    assert phase_one == %{
             principal_id: load_uuid(fixture.principal_id),
             vault_id: load_uuid(fixture.vault_id)
           }

    assert effect_key == envelope.idempotency_key
    assert external_effect_count(external_effects, effect_key) == 1

    assert %{rows: [["retryable", 1]]} =
             query!(
               WorkerRepo,
               "SELECT state, attempt FROM jobs.oban_jobs WHERE id = $1",
               [runner_id]
             )

    assert %{rows: [["uploaded", 1]]} =
             scoped_query(
               envelope,
               "SELECT state, state_revision FROM content.assets WHERE id = $1",
               [fixture.asset_id]
             )

    assert %{rows: [[1, "applied"]]} =
             scoped_query(
               envelope,
               """
               SELECT count(*), max(result)
               FROM jobs.effect_receipts
               WHERE vault_id = $1 AND effect_key = $2
               """,
               [fixture.vault_id, envelope.idempotency_key]
             )

    assert :ok = Oban.retry_job(Singularity.Oban, runner_id)

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(Singularity.Oban, queue: :asset_verify)

    assert_receive {:job_phase, 1, phase_two_start, WorkerRepo}
    assert_receive {:job_phase, 2, phase_two, WorkerRepo}
    assert phase_two_start == phase_one
    assert phase_two == phase_one
    refute_receive {:external_effect, ^effect_key}
    assert external_effect_count(external_effects, effect_key) == 1
    assert external_effect_call_count(external_effects, effect_key) == 2

    assert %{rows: [["completed", 2]]} =
             query!(
               WorkerRepo,
               "SELECT state, attempt FROM jobs.oban_jobs WHERE id = $1",
               [runner_id]
             )

    assert %{rows: [[runner_job_id]]} =
             scoped_query(
               envelope,
               "SELECT runner_job_id FROM jobs.job_submissions WHERE id = $1",
               [Ecto.UUID.dump!(envelope.job_id)]
             )

    assert runner_job_id == Integer.to_string(runner_id)

    assert %{rows: [["uploaded", 1]]} =
             scoped_query(
               envelope,
               """
               SELECT state, state_revision
               FROM content.assets
               WHERE id = $1
               """,
               [fixture.asset_id]
             )

    assert %{rows: [[1, "applied", 1]]} =
             scoped_query(
               envelope,
               """
               SELECT count(*), max(result), max(entity_revision)
               FROM jobs.effect_receipts
               WHERE vault_id = $1 AND effect_key = $2
               """,
               [fixture.vault_id, envelope.idempotency_key]
             )

    assert %{rows: [[0]]} =
             query!(
               WorkerRepo,
               "SELECT count(*) FROM content.assets WHERE id = $1",
               [fixture.asset_id]
             )

    assert_context_absent()
  end

  test "a stale expected revision records one stale receipt without applying an effect",
       %{fixture: fixture} do
    envelope = submitted_envelope(fixture, 99)
    assert {:ok, encoded} = EnvelopeCodec.encode(envelope)

    assert {:ok, %EffectReceipt{result: :stale}} =
             GenericWorker.perform(%Oban.Job{args: encoded})

    assert %{rows: [["staging", 0]]} =
             scoped_query(
               envelope,
               """
               SELECT state, state_revision
               FROM content.assets
               WHERE id = $1
               """,
               [fixture.asset_id]
             )

    assert %{rows: [[1, "stale", 99]]} =
             scoped_query(
               envelope,
               """
               SELECT count(*), max(result), max(entity_revision)
               FROM jobs.effect_receipts
               WHERE vault_id = $1 AND effect_key = $2
               """,
               [fixture.vault_id, envelope.idempotency_key]
             )

    assert_context_absent()
  end

  test "wake_vault retries only the durable waiting-for-unlock job", %{fixture: fixture} do
    waiting_envelope =
      submitted_envelope(fixture, 0, %{
        "wait_for_unlock" => true,
        "checkpoint" => %{"next_chunk_index" => 3}
      })

    unrelated_envelope = submitted_envelope(fixture, 0)

    assert {:ok, encoded} = EnvelopeCodec.encode(waiting_envelope)
    assert {:snooze, 60} = GenericWorker.perform(%Oban.Job{args: encoded})

    assert %{rows: [["waiting_for_unlock", 1, %{"next_chunk_index" => 3}]]} =
             scoped_query(
               waiting_envelope,
               """
               SELECT state, checkpoint_version, checkpoint
               FROM jobs.job_progress
               WHERE submission_id = $1
               """,
               [Ecto.UUID.dump!(waiting_envelope.job_id)]
             )

    assert {:ok, _progress} =
             ScopedRepo.transact(WorkerRepo, unrelated_envelope, fn repo ->
               Progress.put_state(repo, unrelated_envelope, :running)
             end)

    waiting_runner_id = runner_id(waiting_envelope)
    unrelated_runner_id = runner_id(unrelated_envelope)
    put_oban_state(waiting_runner_id, "scheduled")
    put_oban_state(unrelated_runner_id, "retryable")

    assert :ok = ObanAdapter.wake_vault(%{}, waiting_envelope.vault_id)

    assert %{rows: [["available"]]} =
             query!(
               WorkerRepo,
               "SELECT state FROM jobs.oban_jobs WHERE id = $1",
               [waiting_runner_id]
             )

    assert %{rows: [["retryable"]]} =
             query!(
               WorkerRepo,
               "SELECT state FROM jobs.oban_jobs WHERE id = $1",
               [unrelated_runner_id]
             )

    assert_context_absent()
  end

  test "wake_vault honors the caller's bounded limit", %{fixture: fixture} do
    first =
      submitted_envelope(fixture, 0, %{
        "wait_for_unlock" => true,
        "checkpoint" => %{"next_chunk_index" => 1}
      })

    second =
      submitted_envelope(fixture, 0, %{
        "wait_for_unlock" => true,
        "checkpoint" => %{"next_chunk_index" => 2}
      })

    for envelope <- [first, second] do
      assert {:ok, encoded} = EnvelopeCodec.encode(envelope)
      assert {:snooze, 60} = GenericWorker.perform(%Oban.Job{args: encoded})
      put_oban_state(runner_id(envelope), "scheduled")
    end

    assert :ok = ObanAdapter.wake_vault(%{limit: 1}, first.vault_id)

    first_runner_id = runner_id(first)
    second_runner_id = runner_id(second)
    expected_woken = min(first_runner_id, second_runner_id)
    expected_waiting = max(first_runner_id, second_runner_id)

    assert %{rows: [[^expected_woken, "available"], [^expected_waiting, "scheduled"]]} =
             query!(
               WorkerRepo,
               "SELECT id, state FROM jobs.oban_jobs WHERE id IN ($1, $2) ORDER BY id",
               [expected_woken, expected_waiting]
             )

    assert_context_absent()
  end

  test "wake while the worker is executing prevents a full-interval lost snooze",
       %{external_effects: external_effects, fixture: fixture} do
    ref = make_ref()

    Application.put_env(:singularity_storage, :fake_job_dependencies, %{
      crash_after_external_effect?: false,
      external_effects: external_effects,
      observer: self(),
      wait_barrier: %{observer: self(), ref: ref}
    })

    envelope =
      submitted_envelope(fixture, 0, %{
        "wait_for_unlock" => true,
        "checkpoint" => %{"next_chunk_index" => 7}
      })

    runner_id = runner_id(envelope)

    drain =
      Task.async(fn ->
        Oban.drain_queue(Singularity.Oban, queue: :asset_verify)
      end)

    assert_receive {:waiting_progress_committed, ^ref, worker_pid, job_id}, 5_000
    assert worker_pid == drain.pid
    assert job_id == envelope.job_id

    assert %{rows: [["waiting_for_unlock"]]} =
             scoped_query(
               envelope,
               "SELECT state FROM jobs.job_progress WHERE submission_id = $1",
               [Ecto.UUID.dump!(envelope.job_id)]
             )

    assert %{rows: [["executing", 1]]} =
             query!(
               WorkerRepo,
               "SELECT state, attempt FROM jobs.oban_jobs WHERE id = $1",
               [runner_id]
             )

    assert :ok = ObanAdapter.wake_vault(%{}, envelope.vault_id)
    send(drain.pid, {:release_waiting_worker, ref})

    assert %{failure: 0, snoozed: 1, success: 0} = Task.await(drain, 5_000)

    assert %{rows: [["scheduled", scheduled_at, 1]]} =
             query!(
               WorkerRepo,
               "SELECT state, scheduled_at, attempt FROM jobs.oban_jobs WHERE id = $1",
               [runner_id]
             )

    assert NaiveDateTime.diff(
             scheduled_at,
             DateTime.utc_now() |> DateTime.to_naive(),
             :second
           ) <= 5

    Application.put_env(:singularity_storage, :fake_job_dependencies, %{
      crash_after_external_effect?: false,
      external_effects: external_effects,
      observer: self()
    })

    assert %{failure: 0, snoozed: 1, success: 0} =
             Oban.drain_queue(Singularity.Oban,
               queue: :asset_verify,
               with_scheduled: true
             )

    assert %{rows: [["scheduled", 2]]} =
             query!(
               WorkerRepo,
               "SELECT state, attempt FROM jobs.oban_jobs WHERE id = $1",
               [runner_id]
             )

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(Singularity.Oban,
               queue: :maintenance,
               with_scheduled: true
             )

    assert_no_active_wake_reconcilers()
    assert_context_absent()
  end

  test "wake before waiting progress is committed remains durable while the worker executes",
       %{external_effects: external_effects, fixture: fixture} do
    ref = make_ref()

    Application.put_env(:singularity_storage, :fake_job_dependencies, %{
      crash_after_external_effect?: false,
      external_effects: external_effects,
      observer: self(),
      pre_progress_barrier: %{observer: self(), ref: ref}
    })

    envelope =
      submitted_envelope(fixture, 0, %{
        "wait_for_unlock" => true,
        "checkpoint" => %{"next_chunk_index" => 13}
      })

    runner_id = runner_id(envelope)

    drain =
      Task.async(fn ->
        Oban.drain_queue(Singularity.Oban, queue: :asset_verify)
      end)

    assert_receive {:waiting_decision_observed, ^ref, worker_pid, job_id}, 5_000
    assert worker_pid == drain.pid
    assert job_id == envelope.job_id

    assert %{rows: [["executing", 1]]} =
             query!(
               WorkerRepo,
               "SELECT state, attempt FROM jobs.oban_jobs WHERE id = $1",
               [runner_id]
             )

    assert %{rows: [[0]]} =
             scoped_query(
               envelope,
               "SELECT count(*) FROM jobs.job_progress WHERE submission_id = $1",
               [Ecto.UUID.dump!(envelope.job_id)]
             )

    assert :ok = ObanAdapter.wake_vault(%{}, envelope.vault_id)

    assert %{rows: [[1, 0]]} =
             query!(
               WorkerRepo,
               """
               SELECT
                 (meta->>'singularity_wake_requested_generation')::integer,
                 COALESCE(
                   (meta->>'singularity_wake_consumed_generation')::integer,
                   0
                 )
               FROM jobs.oban_jobs
               WHERE id = $1
               """,
               [runner_id]
             )

    assert %{rows: [[1]]} =
             query!(
               WorkerRepo,
               """
               SELECT count(*)
               FROM jobs.oban_jobs
               WHERE worker = $1
                 AND (args->>'target_job_id')::bigint = $2
                 AND (args->>'wake_generation')::integer = 1
                 AND state = 'scheduled'
               """,
               [Oban.Worker.to_string(WakeReconciler), runner_id]
             )

    send(drain.pid, {:release_waiting_progress, ref})

    assert %{failure: 0, snoozed: 1, success: 0} = Task.await(drain, 5_000)

    assert %{rows: [["waiting_for_unlock"]]} =
             scoped_query(
               envelope,
               "SELECT state FROM jobs.job_progress WHERE submission_id = $1",
               [Ecto.UUID.dump!(envelope.job_id)]
             )

    assert %{rows: [["scheduled", scheduled_at, 1, 1, 1]]} =
             query!(
               WorkerRepo,
               """
               SELECT
                 state,
                 scheduled_at,
                 attempt,
                 (meta->>'singularity_wake_requested_generation')::integer,
                 (meta->>'singularity_wake_consumed_generation')::integer
               FROM jobs.oban_jobs
               WHERE id = $1
               """,
               [runner_id]
             )

    assert NaiveDateTime.diff(
             scheduled_at,
             DateTime.utc_now() |> DateTime.to_naive(),
             :second
           ) <= 5

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(Singularity.Oban,
               queue: :maintenance,
               with_scheduled: true
             )

    assert_no_active_wake_reconcilers()
    assert_context_absent()
  end

  test "durable reconciler closes a wake after the worker's final generation check",
       %{fixture: fixture} do
    envelope =
      submitted_envelope(fixture, 0, %{
        "wait_for_unlock" => true,
        "checkpoint" => %{"next_chunk_index" => 9}
      })

    runner_id = runner_id(envelope)
    ref = make_ref()
    handler_id = {__MODULE__, :snooze_barrier, ref}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:oban, :engine, :snooze_job, :start],
               &__MODULE__.pause_before_snooze_ack/4,
               %{observer: self(), ref: ref, runner_id: runner_id}
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    drain =
      Task.async(fn ->
        Oban.drain_queue(Singularity.Oban, queue: :asset_verify)
      end)

    assert_receive {:before_snooze_ack, ^ref, ack_pid}, 5_000
    assert ack_pid == drain.pid

    assert %{rows: [["executing", 1]]} =
             query!(
               WorkerRepo,
               "SELECT state, attempt FROM jobs.oban_jobs WHERE id = $1",
               [runner_id]
             )

    assert %{rows: [["waiting_for_unlock"]]} =
             scoped_query(
               envelope,
               "SELECT state FROM jobs.job_progress WHERE submission_id = $1",
               [Ecto.UUID.dump!(envelope.job_id)]
             )

    assert :ok = ObanAdapter.wake_vault(%{}, envelope.vault_id)

    assert %{rows: [[1, 0]]} =
             query!(
               WorkerRepo,
               """
               SELECT
                 (meta->>'singularity_wake_requested_generation')::integer,
                 COALESCE(
                   (meta->>'singularity_wake_consumed_generation')::integer,
                   0
                 )
               FROM jobs.oban_jobs
               WHERE id = $1
               """,
               [runner_id]
             )

    assert %{rows: [[reconciler_id, "scheduled", ^runner_id, 1]]} =
             query!(
               WorkerRepo,
               """
               SELECT
                 id,
                 state,
                 (args->>'target_job_id')::bigint,
                 (args->>'wake_generation')::integer
               FROM jobs.oban_jobs
               WHERE worker = $1
                 AND (args->>'target_job_id')::bigint = $2
                 AND state = 'scheduled'
               """,
               [Oban.Worker.to_string(WakeReconciler), runner_id]
             )

    send(drain.pid, {:release_snooze_ack, ref})

    assert %{failure: 0, snoozed: 1, success: 0} = Task.await(drain, 5_000)

    assert %{rows: [["scheduled", scheduled_at, 1]]} =
             query!(
               WorkerRepo,
               "SELECT state, scheduled_at, attempt FROM jobs.oban_jobs WHERE id = $1",
               [runner_id]
             )

    assert NaiveDateTime.diff(
             scheduled_at,
             DateTime.utc_now() |> DateTime.to_naive(),
             :second
           ) >= 50

    assert :ok = Application.stop(:singularity_runtime)
    assert {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
    assert Oban.whereis(Singularity.Oban)

    assert %{rows: [[^reconciler_id, "scheduled"]]} =
             query!(
               WorkerRepo,
               """
               SELECT id, state
               FROM jobs.oban_jobs
               WHERE id = $1 AND worker = $2
               """,
               [reconciler_id, Oban.Worker.to_string(WakeReconciler)]
             )

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(Singularity.Oban,
               queue: :maintenance,
               with_scheduled: true
             )

    assert %{rows: [["available", 1, 1]]} =
             query!(
               WorkerRepo,
               """
               SELECT
                 state,
                 (meta->>'singularity_wake_requested_generation')::integer,
                 (meta->>'singularity_wake_consumed_generation')::integer
               FROM jobs.oban_jobs
               WHERE id = $1
               """,
               [runner_id]
             )

    assert_no_active_wake_reconcilers()
    assert_context_absent()
  end

  test "adapter rejects a repository outside the WorkerRepo security boundary",
       %{fixture: fixture} do
    assert {:error, %{code: :invalid}} =
             ObanAdapter.wake_vault(%{repo: RequestRepo}, load_uuid(fixture.vault_id))
  end

  test "reconciler waits for Lifeline when an executor dies before snooze acknowledgement",
       %{external_effects: external_effects, fixture: fixture} do
    wait_ref = make_ref()
    snooze_ref = make_ref()

    Application.put_env(:singularity_storage, :fake_job_dependencies, %{
      crash_after_external_effect?: false,
      external_effects: external_effects,
      observer: self(),
      wait_barrier: %{observer: self(), ref: wait_ref}
    })

    envelope =
      submitted_envelope(fixture, 0, %{
        "wait_for_unlock" => true,
        "checkpoint" => %{"next_chunk_index" => 11}
      })

    runner_id = runner_id(envelope)
    handler_id = {__MODULE__, :orphaned_snooze_barrier, snooze_ref}

    assert :ok =
             :telemetry.attach(
               handler_id,
               [:oban, :engine, :snooze_job, :start],
               &__MODULE__.pause_before_snooze_ack/4,
               %{observer: self(), ref: snooze_ref, runner_id: runner_id}
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    drain =
      Task.async(fn ->
        Oban.drain_queue(Singularity.Oban, queue: :asset_verify)
      end)

    assert_receive {:waiting_progress_committed, ^wait_ref, worker_pid, job_id}, 5_000
    assert worker_pid == drain.pid
    assert job_id == envelope.job_id

    assert :ok = ObanAdapter.wake_vault(%{}, envelope.vault_id)
    send(drain.pid, {:release_waiting_worker, wait_ref})

    assert_receive {:before_snooze_ack, ^snooze_ref, ack_pid}, 5_000
    assert ack_pid == drain.pid

    assert %{rows: [["executing", 1, 1]]} =
             query!(
               WorkerRepo,
               """
               SELECT
                 state,
                 (meta->>'singularity_wake_requested_generation')::integer,
                 (meta->>'singularity_wake_consumed_generation')::integer
               FROM jobs.oban_jobs
               WHERE id = $1
               """,
               [runner_id]
             )

    assert Task.shutdown(drain, :brutal_kill) == nil
    assert :ok = :telemetry.detach(handler_id)

    assert %{failure: 0, snoozed: 1, success: 0} =
             Oban.drain_queue(Singularity.Oban,
               queue: :maintenance,
               with_scheduled: true
             )

    assert %{rows: [["executing"]]} =
             query!(
               WorkerRepo,
               "SELECT state FROM jobs.oban_jobs WHERE id = $1",
               [runner_id]
             )

    target_query = from(job in Oban.Job, where: job.id == ^runner_id)

    assert {:ok, [%{id: ^runner_id, state: "available"}]} =
             Oban.Engine.rescue_jobs(
               Oban.config(Singularity.Oban),
               target_query,
               rescue_after: 0
             )

    assert %{failure: 0, snoozed: 0, success: 1} =
             Oban.drain_queue(Singularity.Oban,
               queue: :maintenance,
               with_scheduled: true
             )

    assert %{rows: [["available"]]} =
             query!(
               WorkerRepo,
               "SELECT state FROM jobs.oban_jobs WHERE id = $1",
               [runner_id]
             )

    assert_no_active_wake_reconcilers()
    assert_context_absent()
  end

  test "configured Oban composition includes orphan rescue" do
    assert Oban.Plugins.Lifeline in (:singularity_storage
                                     |> Application.fetch_env!(Oban)
                                     |> Keyword.fetch!(:plugins))
  end

  def pause_before_snooze_ack(
        _event,
        _measurements,
        %{job: %Oban.Job{id: runner_id}},
        %{observer: observer, ref: ref, runner_id: runner_id}
      ) do
    send(observer, {:before_snooze_ack, ref, self()})

    receive do
      {:release_snooze_ack, ^ref} -> :ok
    after
      5_000 -> raise "snooze acknowledgement barrier timed out"
    end
  end

  def pause_before_snooze_ack(_event, _measurements, _metadata, _config), do: :ok

  defp submitted_envelope(fixture, expected_revision, payload_overrides \\ %{}) do
    event = Fixtures.outbox_event!(fixture)

    assert {:ok, envelope} =
             JobEnvelope.new(%{
               version: 1,
               job_id: load_uuid(event.id),
               job_type: "asset_verify",
               idempotency_key: "effect:#{expected_revision}:#{Ecto.UUID.generate()}",
               vault_id: load_uuid(fixture.vault_id),
               principal_id: load_uuid(fixture.principal_id),
               required_capability: "asset:verify",
               principal_authorization_epoch: 7,
               vault_authorization_epoch: 23,
               classification: :private,
               correlation_id: load_uuid(event.correlation_id),
               causation_id: load_uuid(event.id),
               expected_entity_revision: expected_revision,
               attempt: 0,
               payload:
                 Map.merge(
                   %{"asset_id" => load_uuid(fixture.asset_id)},
                   payload_overrides
                 )
             })

    assert {:ok, _runner_id} = ObanAdapter.submit(%{}, envelope)
    envelope
  end

  defp scoped_query(envelope, statement, parameters) do
    ScopedRepo.transact(WorkerRepo, envelope, fn repo ->
      query!(repo, statement, parameters)
    end)
  end

  defp runner_id(envelope) do
    assert %{rows: [[runner_id]]} =
             query!(
               WorkerRepo,
               "SELECT id FROM jobs.oban_jobs WHERE args->>'job_id' = $1",
               [envelope.job_id]
             )

    runner_id
  end

  defp external_effect_count(external_effects, effect_key) do
    Agent.get(external_effects, fn state ->
      if MapSet.member?(state.applied, effect_key), do: 1, else: 0
    end)
  end

  defp external_effect_call_count(external_effects, effect_key) do
    Agent.get(external_effects, &Map.get(&1.calls, effect_key, 0))
  end

  defp put_oban_state(runner_id, state) do
    assert %{num_rows: 1} =
             query!(
               WorkerRepo,
               """
               UPDATE jobs.oban_jobs
               SET state = $2, scheduled_at = CURRENT_TIMESTAMP + interval '1 hour'
               WHERE id = $1
               """,
               [runner_id, state]
             )

    :ok
  end

  defp complete_existing_oban_jobs! do
    query!(
      WorkerRepo,
      """
      UPDATE jobs.oban_jobs
      SET state = 'completed', completed_at = CURRENT_TIMESTAMP
      WHERE state IN ('available', 'executing', 'retryable', 'scheduled')
      """
    )

    :ok
  end

  defp assert_no_active_wake_reconcilers do
    assert %{rows: [[0]]} =
             query!(
               WorkerRepo,
               """
               SELECT count(*)
               FROM jobs.oban_jobs
               WHERE worker = $1
                 AND state IN ('available', 'executing', 'retryable', 'scheduled')
               """,
               [Oban.Worker.to_string(WakeReconciler)]
             )
  end

  defp assert_context_absent do
    assert %{rows: [[nil, nil]]} =
             query!(WorkerRepo, """
             SELECT
               NULLIF(current_setting('singularity.principal_id', true), ''),
               NULLIF(current_setting('singularity.vault_id', true), '')
             """)
  end

  defp load_uuid(uuid), do: Ecto.UUID.load!(uuid)
end
