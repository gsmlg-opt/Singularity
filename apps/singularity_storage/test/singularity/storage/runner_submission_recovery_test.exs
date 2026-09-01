defmodule Singularity.Storage.RunnerSubmissionRecoveryTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.JobEnvelope
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Jobs.ObanAdapter
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.Outbox
  alias Singularity.Storage.ScopedRepo

  setup do
    assert Oban.whereis(Singularity.Oban)
    mark_existing_events_delivered!()
    fixture = Fixtures.two_vaults!().one
    event = Fixtures.outbox_event!(fixture)
    %{fixture: fixture, event: event}
  end

  test "submission survives a crash before outbox acknowledgement with one permanent identity",
       %{event: event} do
    claim_token = Ecto.UUID.generate()

    assert {:ok, [claimed]} =
             Outbox.claim(DispatcherRepo, %{
               limit: 1,
               lease_seconds: 60,
               claim_token: claim_token
             })

    assert claimed.outbox_event_id == load_uuid(event.id)
    envelope = envelope(claimed)

    assert {:ok, runner_id_before} = ObanAdapter.submit(%{}, envelope)
    assert is_binary(runner_id_before)

    # The dispatcher process dies here, after the submit transaction committed
    # but before it acknowledged the outbox lease.
    assert {:ok, ^runner_id_before} = ObanAdapter.submit(%{}, envelope)

    assert %{rows: [[1, ^runner_id_before, 0, 0]]} =
             scoped_query(
               envelope,
               """
               SELECT
                 count(*),
                 max(runner_job_id),
                 max(wake_requested_generation),
                 max(wake_consumed_generation)
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

    assert :ok =
             Outbox.acknowledge(DispatcherRepo, claimed.outbox_event_id, %{
               claim_token: claim_token,
               runner_job_id: runner_id_before
             })

    assert %{rows: [[^runner_id_before, %DateTime{}]]} =
             Fixtures.with_owner(fn ->
               query!(
                 Singularity.Storage.MigrationRepo,
                 """
                 SELECT runner_job_id, delivered_at
                 FROM core.outbox_events
                 WHERE id = $1
                 """,
                 [event.id]
               )
             end)
  end

  defp envelope(event) do
    assert {:ok, envelope} =
             JobEnvelope.new(%{
               version: 1,
               job_id: event.outbox_event_id,
               job_type: "asset_verify",
               idempotency_key: event.idempotency_key,
               vault_id: event.vault_id,
               principal_id: event.principal_id,
               required_capability: event.required_capability,
               principal_authorization_epoch: event.principal_authorization_epoch,
               vault_authorization_epoch: event.vault_authorization_epoch,
               classification: event.classification,
               correlation_id: event.correlation_id,
               causation_id: event.outbox_event_id,
               expected_entity_revision: event.expected_entity_revision,
               attempt: 0,
               payload: event.payload
             })

    envelope
  end

  defp scoped_query(envelope, statement, parameters) do
    ScopedRepo.transact(WorkerRepo, envelope, fn repo ->
      query!(repo, statement, parameters)
    end)
  end

  defp mark_existing_events_delivered! do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE core.outbox_events
        SET delivered_at = CURRENT_TIMESTAMP
        WHERE delivered_at IS NULL
        """
      )
    end)
  end

  defp load_uuid(uuid), do: Ecto.UUID.load!(uuid)
end
