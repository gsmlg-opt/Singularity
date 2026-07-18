defmodule Singularity.Core.AssetStateTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Asset
  alias Singularity.Core.AssetState

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

  for {from, to} <- @valid do
    test "#{from} transitions to #{to} and increments the state revision" do
      assert {:ok, asset} = Asset.new(valid_asset(state: unquote(from), state_revision: 7))

      assert {:ok, transitioned} = AssetState.transition(asset, unquote(to), 7)
      assert transitioned == %{asset | state: unquote(to), state_revision: 8}
    end
  end

  test "a stale expected revision returns the stable conflict error" do
    assert {:ok, asset} = Asset.new(valid_asset(state: :uploaded, state_revision: 7))

    assert {:error, %{code: :conflict}} = AssetState.transition(asset, :verified, 6)
  end

  test "failure metadata remains orthogonal to successful lifecycle transitions" do
    assert {:ok, asset} =
             Asset.new(
               valid_asset(
                 state: :available,
                 failure_code: :storage_unavailable,
                 retryable?: true,
                 failed_operation: "finalize",
                 attempt: 3
               )
             )

    assert {:ok, transitioned} = AssetState.transition(asset, :processing, 7)

    assert %Asset{
             state: :processing,
             state_revision: 8,
             failure_code: :storage_unavailable,
             retryable?: true,
             failed_operation: "finalize",
             attempt: 3
           } = transitioned
  end

  test "failed is not a lifecycle state" do
    assert {:error, %{code: :invalid}} = Asset.new(valid_asset(state: :failed))
  end

  defp valid_asset(overrides) do
    Map.merge(
      %{
        asset_id: "asset-1",
        vault_id: "vault-1",
        resource_version_id: "resource-version-1",
        classification: :private,
        state: :staging,
        state_revision: 7,
        failure_code: nil,
        retryable?: false,
        failed_operation: nil,
        attempt: 0,
        metadata: %{}
      },
      Map.new(overrides)
    )
  end
end
