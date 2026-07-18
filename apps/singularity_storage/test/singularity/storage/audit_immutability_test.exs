defmodule Singularity.Storage.AuditImmutabilityTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.AuditEvent
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.Postgres.AuditSink
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: fixture} = Fixtures.two_vaults!()
    fixture = load_ids(fixture)

    {:ok, event} =
      AuditEvent.new(%{
        audit_event_id: Ecto.UUID.generate(),
        actor_kind: :principal,
        principal_id: fixture.principal_id,
        vault_id: fixture.vault_id,
        action: "asset.persisted",
        classification: :private,
        correlation_id: Ecto.UUID.generate(),
        occurred_at: DateTime.utc_now(:microsecond)
      })

    :ok =
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
        fn repo -> AuditSink.append(repo, event) end
      )

    {:ok, fixture: fixture, event: event}
  end

  test "audit update and delete are denied for every runtime role", %{
    fixture: fixture,
    event: event
  } do
    for repo <- [RequestRepo, WorkerRepo] do
      assert {:error, %Postgrex.Error{}} =
               ScopedRepo.transact(
                 repo,
                 %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
                 fn checked_out_repo ->
                   try do
                     query!(
                       checked_out_repo,
                       "UPDATE audit.events SET operation = 'tampered' WHERE id = $1",
                       [Ecto.UUID.dump!(event.audit_event_id)]
                     )
                   rescue
                     error in Postgrex.Error -> {:error, error}
                   end
                 end
               )

      assert {:error, %Postgrex.Error{}} =
               ScopedRepo.transact(
                 repo,
                 %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
                 fn checked_out_repo ->
                   try do
                     query!(
                       checked_out_repo,
                       "DELETE FROM audit.events WHERE id = $1",
                       [Ecto.UUID.dump!(event.audit_event_id)]
                     )
                   rescue
                     error in Postgrex.Error -> {:error, error}
                   end
                 end
               )
    end

    for repo <- [PreAuthRepo, DispatcherRepo],
        statement <- [
          "UPDATE audit.events SET operation = 'tampered' WHERE id = $1",
          "DELETE FROM audit.events WHERE id = $1"
        ] do
      assert_raise Postgrex.Error, fn ->
        query!(repo, statement, [Ecto.UUID.dump!(event.audit_event_id)])
      end
    end
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
