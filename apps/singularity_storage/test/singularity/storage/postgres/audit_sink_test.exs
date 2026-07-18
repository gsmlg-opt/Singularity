defmodule Singularity.Storage.Postgres.AuditSinkTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.AuditEvent
  alias Singularity.Core.Error
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Postgres.AuditSink
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: fixture} = Fixtures.two_vaults!()
    {:ok, fixture: load_ids(fixture)}
  end

  test "appends a classified principal audit event", %{fixture: fixture} do
    occurred_at = DateTime.utc_now(:microsecond)

    assert {:ok, event} =
             AuditEvent.new(%{
               audit_event_id: Ecto.UUID.generate(),
               actor_kind: :principal,
               principal_id: fixture.principal_id,
               vault_id: fixture.vault_id,
               action: "asset.uploaded",
               classification: :private,
               correlation_id: Ecto.UUID.generate(),
               occurred_at: occurred_at,
               metadata: %{"asset_id" => fixture.asset_id}
             })

    assert :ok =
             ScopedRepo.transact(
               RequestRepo,
               %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
               fn repo -> AuditSink.append(repo, event) end
             )

    assert :ok =
             ScopedRepo.transact(
               RequestRepo,
               %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
               fn repo ->
                 assert %{rows: [[operation, classification, metadata]]} =
                          query!(
                            repo,
                            """
                            SELECT operation, classification, metadata
                            FROM audit.events
                            WHERE id = $1
                            """,
                            [Ecto.UUID.dump!(event.audit_event_id)]
                          )

                 assert operation == event.action
                 assert classification == "private"
                 assert metadata == event.metadata
                 :ok
               end
             )
  end

  test "maps a primary-key conflict into a Core error", %{fixture: fixture} do
    assert {:ok, event} =
             AuditEvent.new(%{
               audit_event_id: Ecto.UUID.generate(),
               actor_kind: :principal,
               principal_id: fixture.principal_id,
               vault_id: fixture.vault_id,
               action: "asset.uploaded",
               classification: :private,
               correlation_id: Ecto.UUID.generate(),
               occurred_at: DateTime.utc_now(:microsecond),
               metadata: %{"asset_id" => fixture.asset_id}
             })

    context = %{principal_id: fixture.principal_id, vault_id: fixture.vault_id}

    assert :ok =
             ScopedRepo.transact(RequestRepo, context, fn repo ->
               AuditSink.append(repo, event)
             end)

    assert {:error, %Error{code: :conflict}} =
             ScopedRepo.transact(RequestRepo, context, fn repo ->
               AuditSink.append(repo, event)
             end)
  end

  test "append rejects every malformed event UUID without effects", %{fixture: fixture} do
    assert {:ok, event} =
             AuditEvent.new(%{
               audit_event_id: Ecto.UUID.generate(),
               actor_kind: :principal,
               principal_id: fixture.principal_id,
               vault_id: fixture.vault_id,
               action: "asset.invalid_uuid_checked",
               classification: :private,
               correlation_id: Ecto.UUID.generate(),
               occurred_at: DateTime.utc_now(:microsecond),
               metadata: %{}
             })

    context = %{principal_id: fixture.principal_id, vault_id: fixture.vault_id}

    invalid_uuids = [
      "not-a-uuid",
      <<0, 1>>,
      "warehouse worker",
      String.duplicate("x", 36)
    ]

    for field <- [:audit_event_id, :principal_id, :vault_id, :correlation_id],
        invalid_uuid <- invalid_uuids do
      count_before = audit_count(fixture)
      malformed = Map.put(event, field, invalid_uuid)

      assert {:error, %Error{code: :invalid}} =
               ScopedRepo.transact(RequestRepo, context, fn repo ->
                 AuditSink.append(repo, malformed)
               end)

      assert audit_count(fixture) == count_before
    end
  end

  defp audit_count(fixture) do
    ScopedRepo.transact(
      RequestRepo,
      %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
      fn repo ->
        %{rows: [[count]]} =
          query!(
            repo,
            "SELECT count(*) FROM audit.events WHERE vault_id = $1",
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
