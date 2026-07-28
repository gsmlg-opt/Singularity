defmodule Singularity.Core.AuditEventTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.AuditEvent

  @fingerprint :crypto.hash(:sha256, "anonymous-login")

  test "constructs each disjoint audit actor shape" do
    actor_attrs = [
      %{
        actor_kind: :principal,
        principal_id: "principal-1",
        vault_id: "vault-1"
      },
      %{
        actor_kind: :system,
        system_principal_name: "singularity.dispatcher",
        vault_id: "vault-1"
      },
      %{
        actor_kind: :anonymous,
        anonymous_fingerprint: @fingerprint
      }
    ]

    for attrs <- actor_attrs do
      assert {:ok, event} = attrs |> valid_event() |> AuditEvent.new()
      assert Map.fetch!(event, :result) == :completed
      assert Map.fetch!(event, :target_type) == "asset"
      assert Map.fetch!(event, :target_id) == "asset-1"
    end
  end

  test "rejects actor shapes that overlap or omit required identity" do
    invalid_actor_attrs = [
      %{actor_kind: :principal, vault_id: "vault-1"},
      %{actor_kind: :principal, principal_id: "principal-1"},
      %{
        actor_kind: :principal,
        principal_id: "principal-1",
        vault_id: "vault-1",
        anonymous_fingerprint: @fingerprint
      },
      %{
        actor_kind: :principal,
        principal_id: "principal-1",
        vault_id: "vault-1",
        system_principal_name: "singularity.dispatcher"
      },
      %{actor_kind: :system, vault_id: "vault-1"},
      %{actor_kind: :system, system_principal_name: " ", vault_id: "vault-1"},
      %{
        actor_kind: :system,
        system_principal_name: "singularity.dispatcher",
        principal_id: "principal-1",
        vault_id: "vault-1"
      },
      %{actor_kind: :anonymous, anonymous_fingerprint: "short"},
      %{
        actor_kind: :anonymous,
        anonymous_fingerprint: @fingerprint,
        vault_id: "vault-1"
      },
      %{actor_kind: :unknown}
    ]

    for attrs <- invalid_actor_attrs do
      assert {:error, %{code: :invalid}} =
               attrs
               |> valid_event()
               |> AuditEvent.new()
    end
  end

  test "accepts only the immutable audit result vocabulary" do
    for result <- [:allowed, :denied, :completed, :failed] do
      assert {:ok, event} =
               %{result: result}
               |> valid_event()
               |> AuditEvent.new()

      assert Map.fetch!(event, :result) == result
    end

    for result <- [:started, "completed", nil] do
      assert {:error, %{code: :invalid}} =
               %{result: result}
               |> valid_event()
               |> AuditEvent.new()
    end
  end

  test "requires explicit nonblank redacted target fields when supplied" do
    for {field, value} <- [
          {:target_type, nil},
          {:target_type, " "},
          {:target_id, nil},
          {:target_id, ""}
        ] do
      assert {:error, %{code: :invalid}} =
               %{field => value}
               |> valid_event()
               |> AuditEvent.new()
    end
  end

  test "rejects omitted result and target fields" do
    for field <- [:result, :target_type, :target_id] do
      assert {:error, %{code: :invalid}} =
               valid_event()
               |> Map.delete(field)
               |> AuditEvent.new()
    end
  end

  defp valid_event(overrides \\ %{}) do
    actor_attrs = %{
      actor_kind: :principal,
      principal_id: "principal-1",
      vault_id: "vault-1"
    }

    attrs =
      Map.merge(
        %{
          audit_event_id: "audit-1",
          action: "asset.read",
          result: :completed,
          classification: :sensitive,
          correlation_id: "correlation-1",
          target_type: "asset",
          target_id: "asset-1",
          occurred_at: ~U[2026-07-18 08:00:00Z],
          metadata: %{"reason" => "acceptance"}
        },
        actor_attrs
      )

    normalize_actor_override(attrs, overrides)
  end

  defp normalize_actor_override(attrs, overrides) do
    if Map.has_key?(overrides, :actor_kind) do
      attrs
      |> Map.drop([:principal_id, :vault_id, :anonymous_fingerprint, :system_principal_name])
      |> Map.merge(overrides)
    else
      Map.merge(attrs, overrides)
    end
  end
end
