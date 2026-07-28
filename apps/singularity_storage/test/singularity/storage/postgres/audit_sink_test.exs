defmodule Singularity.Storage.Postgres.AuditSinkTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.AuditEvent
  alias Singularity.Core.Error
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.AuditSink
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: fixture} = Fixtures.two_vaults!()
    {:ok, fixture: load_ids(fixture)}
  end

  test "appends the complete classified principal audit contract", %{fixture: fixture} do
    occurred_at = DateTime.utc_now(:microsecond)
    target_id = Ecto.UUID.generate()

    assert {:ok, event} =
             AuditEvent.new(%{
               audit_event_id: Ecto.UUID.generate(),
               actor_kind: :principal,
               principal_id: fixture.principal_id,
               vault_id: fixture.vault_id,
               action: "asset.uploaded",
               result: :denied,
               classification: :private,
               correlation_id: Ecto.UUID.generate(),
               target_type: "asset",
               target_id: target_id,
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
                 assert %{
                          rows: [
                            [
                              actor_kind,
                              principal_id,
                              vault_id,
                              anonymous_fingerprint,
                              system_principal_name,
                              operation,
                              result,
                              classification,
                              correlation_id,
                              target_type,
                              stored_target_id,
                              metadata,
                              stored_occurred_at
                            ]
                          ]
                        } =
                          query!(
                            repo,
                            """
                            SELECT
                              actor_kind,
                              principal_id,
                              vault_id,
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
                            FROM audit.events
                            WHERE id = $1
                            """,
                            [Ecto.UUID.dump!(event.audit_event_id)]
                          )

                 assert actor_kind == "principal"
                 assert Ecto.UUID.load!(principal_id) == event.principal_id
                 assert Ecto.UUID.load!(vault_id) == event.vault_id
                 assert anonymous_fingerprint == nil
                 assert system_principal_name == nil
                 assert operation == event.action
                 assert result == "denied"
                 assert classification == "private"
                 assert Ecto.UUID.load!(correlation_id) == event.correlation_id
                 assert target_type == "asset"
                 assert Ecto.UUID.load!(stored_target_id) == target_id
                 assert metadata == event.metadata
                 assert stored_occurred_at == occurred_at
                 :ok
               end
             )
  end

  test "appends named system and anonymous actors as disjoint shapes", %{fixture: fixture} do
    system_event_id = Ecto.UUID.generate()
    anonymous_event_id = Ecto.UUID.generate()
    anonymous_fingerprint = :crypto.hash(:sha256, "anonymous-login")

    assert {:ok, system_event} =
             AuditEvent.new(%{
               audit_event_id: system_event_id,
               actor_kind: :system,
               system_principal_name: "singularity.dispatcher",
               vault_id: fixture.vault_id,
               action: "outbox.claimed",
               result: :completed,
               classification: :private,
               correlation_id: Ecto.UUID.generate(),
               target_type: "outbox_event",
               target_id: Ecto.UUID.generate(),
               occurred_at: DateTime.utc_now(:microsecond),
               metadata: %{}
             })

    assert {:ok, anonymous_event} =
             AuditEvent.new(%{
               audit_event_id: anonymous_event_id,
               actor_kind: :anonymous,
               anonymous_fingerprint: anonymous_fingerprint,
               action: "identity.authentication_attempt",
               result: :denied,
               classification: :private,
               correlation_id: Ecto.UUID.generate(),
               target_type: "authentication_attempt",
               target_id: Ecto.UUID.generate(),
               occurred_at: DateTime.utc_now(:microsecond),
               metadata: %{}
             })

    Fixtures.with_owner(fn ->
      assert :ok = AuditSink.append(MigrationRepo, system_event)
      assert :ok = AuditSink.append(MigrationRepo, anonymous_event)

      assert %{
               rows: [
                 ["system", nil, system_vault_id, nil, "singularity.dispatcher"],
                 ["anonymous", nil, nil, ^anonymous_fingerprint, nil]
               ]
             } =
               query!(
                 MigrationRepo,
                 """
                 SELECT
                   actor_kind,
                   principal_id,
                   vault_id,
                   anonymous_fingerprint,
                   system_principal_name
                 FROM audit.events
                 WHERE id = ANY($1)
                 ORDER BY actor_kind DESC
                 """,
                 [
                   Enum.map(
                     [system_event_id, anonymous_event_id],
                     &Ecto.UUID.dump!/1
                   )
                 ]
               )

      assert Ecto.UUID.load!(system_vault_id) == fixture.vault_id
    end)
  end

  test "maps a primary-key conflict into a Core error", %{fixture: fixture} do
    assert {:ok, event} =
             AuditEvent.new(%{
               audit_event_id: Ecto.UUID.generate(),
               actor_kind: :principal,
               principal_id: fixture.principal_id,
               vault_id: fixture.vault_id,
               action: "asset.uploaded",
               result: :completed,
               classification: :private,
               correlation_id: Ecto.UUID.generate(),
               target_type: "asset",
               target_id: fixture.asset_id,
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
               result: :completed,
               classification: :private,
               correlation_id: Ecto.UUID.generate(),
               target_type: "asset",
               target_id: fixture.asset_id,
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
