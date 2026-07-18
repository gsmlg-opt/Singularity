defmodule Singularity.Runtime.JobRestartTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Jobs.GenericWorker
  alias Singularity.Storage.Jobs.ObanAdapter
  alias Singularity.Runtime.OutboxDispatcher

  setup do
    mark_existing_events_delivered!()
    previous_handler = Application.get_env(:singularity_storage, :job_handler)

    Application.put_env(
      :singularity_storage,
      :job_handler,
      Singularity.Storage.Fake.JobHandler
    )

    on_exit(fn ->
      if previous_handler do
        Application.put_env(:singularity_storage, :job_handler, previous_handler)
      else
        Application.delete_env(:singularity_storage, :job_handler)
      end
    end)

    assert Oban.whereis(Singularity.Oban)
    :ok
  end

  test "runner and worker restart preserve one runner id, domain effect and receipt" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)

    options = %{
      outbox: Singularity.Storage.Postgres.Outbox,
      outbox_context: DispatcherRepo,
      job_runner: ObanAdapter,
      job_runner_context: %{},
      batch_size: 10,
      lease_seconds: 60,
      after_submit: fn _envelope, _runner_id -> :ok end
    }

    assert {:ok, %{submitted: 1, skipped: 0}} =
             OutboxDispatcher.dispatch_once(options)

    assert %{rows: [[runner_id_before]]} =
             owner_query(
               """
               SELECT runner_job_id
               FROM jobs.job_submissions
               WHERE outbox_event_id = $1
               """,
               [event.id]
             )

    assert %{rows: [[encoded]]} =
             query!(
               WorkerRepo,
               """
               SELECT args
               FROM jobs.oban_jobs
               WHERE id = $1
               """,
               [String.to_integer(runner_id_before)]
             )

    assert :ok = Application.stop(:singularity_runtime)
    assert {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
    assert Oban.whereis(Singularity.Oban)

    assert {:ok, envelope} =
             Singularity.Storage.Jobs.EnvelopeCodec.decode(encoded)

    assert {:ok, ^runner_id_before} = ObanAdapter.submit(%{}, envelope)

    assert {:ok, _receipt} = GenericWorker.perform(%Oban.Job{args: encoded})
    assert {:ok, _same_receipt} = GenericWorker.perform(%Oban.Job{args: encoded})

    assert %{rows: [[1, ^runner_id_before]]} =
             owner_query(
               """
               SELECT count(*), max(runner_job_id)
               FROM jobs.job_submissions
               WHERE outbox_event_id = $1
               """,
               [event.id]
             )

    assert %{rows: [[1]]} =
             query!(
               WorkerRepo,
               """
               SELECT count(*)
               FROM jobs.oban_jobs
               WHERE id = $1
               """,
               [String.to_integer(runner_id_before)]
             )

    assert %{rows: [["uploaded", 1]]} =
             owner_query(
               """
               SELECT state, state_revision
               FROM content.assets
               WHERE id = $1
               """,
               [fixture.asset_id]
             )

    assert %{rows: [[1, "applied"]]} =
             owner_query(
               """
               SELECT count(*), max(result)
               FROM jobs.effect_receipts
               WHERE submission_id = $1
               """,
               [event.id]
             )
  end

  defp mark_existing_events_delivered! do
    owner_query(
      """
      UPDATE core.outbox_events
      SET delivered_at = CURRENT_TIMESTAMP
      WHERE delivered_at IS NULL
      """,
      []
    )

    :ok
  end

  defp owner_query(statement, parameters) do
    Fixtures.with_owner(fn ->
      query!(Singularity.Storage.MigrationRepo, statement, parameters)
    end)
  end
end
