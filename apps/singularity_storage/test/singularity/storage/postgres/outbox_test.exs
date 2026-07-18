defmodule Singularity.Storage.Postgres.OutboxTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Core.OutboxEvent
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Postgres.Outbox
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: fixture, two: other_fixture} = Fixtures.two_vaults!()
    {:ok, fixture: load_ids(fixture), other_fixture: load_ids(other_fixture)}
  end

  test "appends in scope and claims and acknowledges only through dispatcher functions", %{
    fixture: fixture
  } do
    assert {:ok, event} =
             OutboxEvent.new(%{
               outbox_event_id: Ecto.UUID.generate(),
               event_type: "asset.verify_requested",
               idempotency_key: "verify-#{fixture.asset_id}",
               vault_id: fixture.vault_id,
               principal_id: fixture.principal_id,
               required_capability: "assets.verify",
               principal_authorization_epoch: 7,
               vault_authorization_epoch: 23,
               classification: :private,
               correlation_id: Ecto.UUID.generate(),
               causation_id: Ecto.UUID.generate(),
               expected_entity_revision: 0,
               payload: %{"asset_id" => fixture.asset_id},
               occurred_at: DateTime.utc_now(:microsecond)
             })

    assert {:ok, ^event} =
             ScopedRepo.transact(
               RequestRepo,
               %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
               fn repo -> Outbox.append(repo, event) end
             )

    claim_token = Ecto.UUID.generate()

    assert {:ok, claimed_events} =
             Outbox.claim(DispatcherRepo, %{
               limit: 100,
               lease_seconds: 60,
               claim_token: claim_token
             })

    assert ^event = Enum.find(claimed_events, &(&1.outbox_event_id == event.outbox_event_id))

    assert :ok =
             Outbox.acknowledge(DispatcherRepo, event.outbox_event_id, %{
               claim_token: claim_token,
               runner_job_id: "job-1"
             })

    assert {:ok, []} =
             Outbox.claim(DispatcherRepo, %{
               limit: 1,
               lease_seconds: 60,
               claim_token: Ecto.UUID.generate()
             })
  end

  test "maps a primary-key conflict into a Core error", %{
    fixture: fixture,
    other_fixture: other_fixture
  } do
    event_id = Ecto.UUID.generate()

    assert {:ok, first_event} =
             outbox_event(event_id, fixture, "primary-key-first")

    assert {:ok, second_event} =
             outbox_event(event_id, other_fixture, "primary-key-second")

    assert {:ok, ^first_event} =
             ScopedRepo.transact(
               RequestRepo,
               %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
               fn repo -> Outbox.append(repo, first_event) end
             )

    assert {:error, %Error{code: :conflict}} =
             ScopedRepo.transact(
               RequestRepo,
               %{
                 principal_id: other_fixture.principal_id,
                 vault_id: other_fixture.vault_id
               },
               fn repo -> Outbox.append(repo, second_event) end
             )
  end

  test "append rejects every malformed event UUID without effects", %{fixture: fixture} do
    assert {:ok, event} =
             outbox_event(Ecto.UUID.generate(), fixture, "invalid-uuid-append")

    context = %{principal_id: fixture.principal_id, vault_id: fixture.vault_id}

    invalid_uuids = [
      "not-a-uuid",
      <<0, 1>>,
      "warehouse worker",
      String.duplicate("x", 36)
    ]

    for field <- [
          :outbox_event_id,
          :vault_id,
          :principal_id,
          :correlation_id,
          :causation_id
        ],
        invalid_uuid <- invalid_uuids do
      count_before = outbox_count(fixture)
      malformed = Map.put(event, field, invalid_uuid)

      assert {:error, %Error{code: :invalid}} =
               ScopedRepo.transact(RequestRepo, context, fn repo ->
                 Outbox.append(repo, malformed)
               end)

      assert outbox_count(fixture) == count_before
    end
  end

  test "claim rejects malformed string and binary claim tokens" do
    for claim_token <- [
          "not-a-claim-token",
          <<0, 1>>,
          "warehouse worker",
          String.duplicate("x", 36)
        ] do
      assert {:error, %Error{code: :invalid}} =
               Outbox.claim(DispatcherRepo, %{
                 limit: 1,
                 lease_seconds: 60,
                 claim_token: claim_token
               })
    end
  end

  test "acknowledge rejects malformed string and binary event IDs and claim tokens" do
    valid_event_id = Ecto.UUID.generate()
    valid_claim_token = Ecto.UUID.generate()

    invalid_arguments = [
      {"not-an-event-id", valid_claim_token},
      {<<0, 1>>, valid_claim_token},
      {"warehouse worker", valid_claim_token},
      {String.duplicate("x", 36), valid_claim_token},
      {valid_event_id, "not-a-claim-token"},
      {valid_event_id, <<2, 3>>},
      {valid_event_id, "warehouse worker"},
      {valid_event_id, String.duplicate("x", 36)}
    ]

    for {event_id, claim_token} <- invalid_arguments do
      assert {:error, %Error{code: :invalid}} =
               Outbox.acknowledge(DispatcherRepo, event_id, %{
                 claim_token: claim_token,
                 runner_job_id: "job-1"
               })
    end
  end

  defp outbox_event(event_id, fixture, key) do
    OutboxEvent.new(%{
      outbox_event_id: event_id,
      event_type: "asset.verify_requested",
      idempotency_key: "#{key}-#{fixture.asset_id}",
      vault_id: fixture.vault_id,
      principal_id: fixture.principal_id,
      required_capability: "assets.verify",
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      classification: :private,
      correlation_id: Ecto.UUID.generate(),
      causation_id: Ecto.UUID.generate(),
      expected_entity_revision: 0,
      payload: %{"asset_id" => fixture.asset_id},
      occurred_at: DateTime.utc_now(:microsecond)
    })
  end

  defp outbox_count(fixture) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      fn repo ->
        %{rows: [[count]]} =
          query!(
            repo,
            "SELECT count(*) FROM core.outbox_events WHERE vault_id = $1",
            [Ecto.UUID.dump!(fixture.vault_id)]
          )

        count
      end
    )
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value}
      when key in [
             :account_id,
             :asset_id,
             :credential_id,
             :principal_id,
             :resource_id,
             :resource_version_id,
             :session_id,
             :vault_id
           ] ->
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end
end
