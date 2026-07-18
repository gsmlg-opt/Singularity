defmodule Singularity.Core.InvariantPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Singularity.Core.Asset
  alias Singularity.Core.AssetState
  alias Singularity.Core.Capability
  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.Person
  alias Singularity.Core.StageRef

  @valid [
    {:staging, :uploaded},
    {:uploaded, :verified},
    {:verified, :available},
    {:available, :processing},
    {:processing, :ready},
    {:staging, :pending_delete},
    {:uploaded, :pending_delete},
    {:verified, :pending_delete},
    {:available, :pending_delete},
    {:processing, :pending_delete},
    {:ready, :pending_delete},
    {:pending_delete, :deleted}
  ]

  @states ~w[staging uploaded verified available processing ready pending_delete deleted]a

  property "core identifiers and cursors remain opaque strings" do
    check all(opaque <- non_empty_string()) do
      assert {:ok, %Person{person_id: ^opaque}} =
               Person.new(%{
                 person_id: opaque,
                 metadata: %{}
               })

      assert {:ok, %StageRef{stage_id: ^opaque}} = StageRef.new(%{stage_id: opaque})
    end
  end

  property "asset revisions accept all non-negative integers and reject negative integers" do
    check all(
            revision <- non_negative_integer(),
            negative_revision <- negative_integer()
          ) do
      assert {:ok, %Asset{state_revision: ^revision}} =
               Asset.new(valid_asset(state_revision: revision))

      assert {:error, %{code: :invalid}} =
               Asset.new(valid_asset(state_revision: negative_revision))
    end
  end

  property "idempotency-key normalization is stable" do
    check all(idempotency_key <- non_empty_string()) do
      assert {:ok, first} =
               JobEnvelope.new(valid_envelope(idempotency_key: " \t#{idempotency_key}\r\n"))

      assert first.idempotency_key == idempotency_key
      assert {:ok, second} = JobEnvelope.new(Map.from_struct(first))
      assert second.idempotency_key == first.idempotency_key
    end
  end

  property "capability containment is exact and does not broaden authority" do
    check all(
            names <- uniq_list_of(non_empty_string(), max_length: 12),
            required_name <- non_empty_string()
          ) do
      capabilities =
        Enum.map(names, fn name ->
          assert {:ok, capability} = Capability.new(%{name: name})
          capability
        end)

      assert Capability.contains?(capabilities, required_name) ==
               Enum.any?(capabilities, &(&1.name == required_name))
    end
  end

  property "every lifecycle edge outside the authoritative table is rejected" do
    invalid_transition =
      gen all(
            from <- member_of(@states),
            to <- member_of(@states),
            {from, to} not in @valid
          ) do
        {from, to}
      end

    check all(
            {from, to} <- invalid_transition,
            revision <- non_negative_integer()
          ) do
      assert {:ok, asset} = Asset.new(valid_asset(state: from, state_revision: revision))
      assert {:error, %{code: :invalid}} = AssetState.transition(asset, to, revision)
    end
  end

  defp non_empty_string do
    string(:alphanumeric, min_length: 1, max_length: 64)
  end

  defp negative_integer do
    integer(-1_000_000..-1)
  end

  defp valid_asset(overrides) do
    Map.merge(
      %{
        asset_id: "asset-1",
        vault_id: "vault-1",
        resource_version_id: "resource-version-1",
        classification: :private,
        state: :staging,
        state_revision: 0,
        failure_code: nil,
        retryable?: false,
        failed_operation: nil,
        attempt: 0,
        metadata: %{}
      },
      Map.new(overrides)
    )
  end

  defp valid_envelope(overrides) do
    Map.merge(
      %{
        version: 1,
        job_id: "job-1",
        job_type: "asset_verify",
        idempotency_key: "asset-1:verify:0",
        vault_id: "vault-1",
        principal_id: "principal-1",
        required_capability: "asset:verify",
        principal_authorization_epoch: 3,
        vault_authorization_epoch: 11,
        classification: :private,
        correlation_id: "correlation-1",
        causation_id: "outbox-1",
        expected_entity_revision: 0,
        attempt: 0,
        payload: %{"asset_id" => "asset-1"}
      },
      Map.new(overrides)
    )
  end
end
