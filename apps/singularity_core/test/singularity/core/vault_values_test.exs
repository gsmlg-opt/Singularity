defmodule Singularity.Core.VaultValuesTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.AuditEvent
  alias Singularity.Core.Capability
  alias Singularity.Core.Classification
  alias Singularity.Core.OutboxEvent
  alias Singularity.Core.Vault

  test "vaults carry a non-negative authorization epoch" do
    assert {:ok, %Vault{vault_id: "vault-1", authorization_epoch: 0}} =
             Vault.new(%{vault_id: "vault-1", authorization_epoch: 0})

    assert {:error, %{code: :invalid}} =
             Vault.new(%{vault_id: "vault-1", authorization_epoch: -1})
  end

  test "classification may be preserved or strengthened but never weakened" do
    assert :ok = Classification.assert_not_downgraded(:private, :private)
    assert :ok = Classification.assert_not_downgraded(:private, :sensitive)
    assert :ok = Classification.assert_not_downgraded(:private, :restricted)
    assert :ok = Classification.assert_not_downgraded(:sensitive, :restricted)

    assert {:error, %{code: :forbidden}} =
             Classification.assert_not_downgraded(:restricted, :sensitive)

    assert {:error, %{code: :forbidden}} =
             Classification.assert_not_downgraded(:sensitive, :private)
  end

  test "capability keys normalize surrounding whitespace and containment is exact" do
    assert {:ok, %Capability{name: "asset:read"}} =
             Capability.new(%{name: "  asset:read\t"})

    assert Capability.contains?(
             [%Capability{name: "asset:read"}, %Capability{name: "asset:write"}],
             " asset:read "
           )

    refute Capability.contains?([%Capability{name: "asset:read"}], "asset")
    refute Capability.contains?([%Capability{name: "asset:read"}], "asset:read:metadata")
  end

  test "audit events require UTC time and string-keyed metadata" do
    assert {:ok,
            %AuditEvent{
              audit_event_id: "audit-1",
              actor_kind: :principal,
              principal_id: "principal-1",
              vault_id: "vault-1",
              classification: :sensitive,
              occurred_at: ~U[2026-07-18 08:00:00Z]
            }} =
             AuditEvent.new(%{
               audit_event_id: "audit-1",
               actor_kind: :principal,
               principal_id: "principal-1",
               vault_id: "vault-1",
               action: "asset.read",
               classification: :sensitive,
               correlation_id: "correlation-1",
               occurred_at: ~U[2026-07-18 08:00:00Z],
               metadata: %{"asset_id" => "asset-1"}
             })

    assert {:error, %{code: :invalid}} =
             AuditEvent.new(%{
               audit_event_id: "audit-1",
               actor_kind: :principal,
               principal_id: "principal-1",
               vault_id: "vault-1",
               action: "asset.read",
               classification: :private,
               correlation_id: "correlation-1",
               occurred_at: ~N[2026-07-18 08:00:00],
               metadata: %{}
             })
  end

  test "outbox events carry stable authority and revision context" do
    assert {:ok,
            %OutboxEvent{
              outbox_event_id: "outbox-1",
              vault_id: "vault-1",
              principal_authorization_epoch: 2,
              vault_authorization_epoch: 7,
              expected_entity_revision: 7,
              idempotency_key: "asset-1:verify:7"
            }} = OutboxEvent.new(valid_outbox_event())

    assert {:error, %{code: :invalid}} =
             OutboxEvent.new(valid_outbox_event(payload: %{asset_id: "asset-1"}))

    for field <- [:principal_authorization_epoch, :vault_authorization_epoch] do
      assert {:error, %{code: :invalid}} =
               valid_outbox_event()
               |> Map.delete(field)
               |> OutboxEvent.new()
    end

    for field <- [:principal_authorization_epoch, :vault_authorization_epoch] do
      assert {:error, %{code: :invalid}} =
               OutboxEvent.new(valid_outbox_event([{field, -1}]))
    end
  end

  defp valid_outbox_event(overrides \\ []) do
    Map.merge(
      %{
        outbox_event_id: "outbox-1",
        event_type: "asset.verify",
        idempotency_key: " asset-1:verify:7 ",
        vault_id: "vault-1",
        principal_id: "principal-1",
        required_capability: "asset:verify",
        principal_authorization_epoch: 2,
        vault_authorization_epoch: 7,
        classification: :private,
        correlation_id: "correlation-1",
        causation_id: "upload-1",
        expected_entity_revision: 7,
        payload: %{"asset_id" => "asset-1"},
        occurred_at: ~U[2026-07-18 08:00:00Z]
      },
      Map.new(overrides)
    )
  end
end
