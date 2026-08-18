defmodule Singularity.Runtime.JobRestartTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Jobs.GenericWorker
  alias Singularity.Storage.Jobs.ObanAdapter
  alias Singularity.Storage.Jobs.EnvelopeCodec
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

    assert encoded["principal_authorization_epoch"] == 7
    assert encoded["vault_authorization_epoch"] == 23

    assert :ok = Application.stop(:singularity_runtime)
    assert {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
    assert Oban.whereis(Singularity.Oban)

    assert {:ok, envelope} =
             Singularity.Storage.Jobs.EnvelopeCodec.decode(encoded)

    assert envelope.principal_authorization_epoch == 7
    assert envelope.vault_authorization_epoch == 23
    assert {:ok, ^runner_id_before} = ObanAdapter.submit(%{}, envelope)

    assert :ok = GenericWorker.perform(%Oban.Job{args: encoded})
    assert :ok = GenericWorker.perform(%Oban.Job{args: encoded})

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

  test "note projection envelope remains executable across runtime restart" do
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)
    {envelope, encoded} = note_projection_envelope(fixture, event)

    assert {:ok, runner_job_id} = ObanAdapter.submit(%{}, envelope)

    assert %{rows: [["note_projection"]]} =
             query!(
               WorkerRepo,
               "SELECT queue FROM jobs.oban_jobs WHERE id = $1",
               [String.to_integer(runner_job_id)]
             )

    assert :ok = Application.stop(:singularity_runtime)
    assert {:ok, _started} = Application.ensure_all_started(:singularity_runtime)
    assert Oban.whereis(Singularity.Oban)

    assert Keyword.fetch!(Application.fetch_env!(:singularity_storage, Oban), :queues)[
             :note_projection
           ] == 2

    assert {:ok, ^runner_job_id} = ObanAdapter.submit(%{}, envelope)
    assert :ok = GenericWorker.perform(%Oban.Job{args: encoded})
    assert_receive {:job_handler_called, _context, %{job_type: "note_projection"}}
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

  defp note_projection_envelope(fixture, event) do
    resource_id = Ecto.UUID.load!(fixture.resource_id)

    {:ok, envelope} =
      Singularity.Core.JobEnvelope.new(%{
        version: 1,
        job_id: Ecto.UUID.load!(event.id),
        job_type: "note_projection",
        idempotency_key: "note-current-changed:#{resource_id}:0",
        vault_id: Ecto.UUID.load!(fixture.vault_id),
        principal_id: Ecto.UUID.load!(fixture.principal_id),
        required_capability: "note.write",
        principal_authorization_epoch: 0,
        vault_authorization_epoch: 0,
        classification: :private,
        correlation_id: Ecto.UUID.generate(),
        causation_id: Ecto.UUID.generate(),
        expected_entity_revision: 0,
        attempt: 0,
        payload: %{"resource_id" => resource_id}
      })

    {:ok, encoded} = EnvelopeCodec.encode(envelope)
    {envelope, encoded}
  end
end
