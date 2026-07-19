defmodule Singularity.Runtime.AssetStatusRetryTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Asset
  alias Singularity.Core.Error
  alias Singularity.Runtime.Assets.Retry
  alias Singularity.Runtime.Assets.Status
  alias Singularity.Runtime.SessionContext

  @session_id "00000000-0000-4000-8000-000000000601"
  @principal_id "00000000-0000-4000-8000-000000000602"
  @vault_id "00000000-0000-4000-8000-000000000603"
  @resource_version_id "00000000-0000-4000-8000-000000000604"
  @asset_id "00000000-0000-4000-8000-000000000605"

  defmodule Scope do
    def with_read_request(owner, runtime, session, requirement, callback) do
      send(owner, {:read_scope, runtime, session, requirement})
      callback.(:scoped_repo)
    end

    def with_shared_request(owner, runtime, session, requirement, callback) do
      send(owner, {:shared_scope, runtime, session, requirement})
      callback.(:scoped_repo)
    end
  end

  defmodule Assets do
    def status(owner, :scoped_repo, asset_id) do
      send(owner, {:status, asset_id})
      {:ok, Process.get(:status_asset)}
    end

    def retry(owner, :scoped_repo, command) do
      send(owner, {:retry, command})
      Process.get(:retry_result, {:ok, :accepted})
    end
  end

  setup do
    Process.put(:status_asset, failed_asset())

    on_exit(fn ->
      Process.delete(:status_asset)
      Process.delete(:retry_result)
    end)
  end

  test "status authorizes a non-plaintext read and returns exact failure metadata" do
    runtime = runtime()
    session = session()

    assert {:ok, %Asset{} = asset} =
             Status.run(runtime, session, @asset_id)

    assert asset == failed_asset()

    assert_receive {:read_scope, ^runtime, ^session, requirement}
    assert requirement.required_capability == "asset.read"
    assert requirement.classification == :private
    refute requirement.requires_unlocked?
    assert_receive {:status, @asset_id}
  end

  test "retry reauthorizes the exact classification and submits current revision" do
    runtime = runtime()
    session = session()

    assert {:ok, :accepted} =
             Retry.run(runtime, session, @asset_id, 1)

    assert_receive {:shared_scope, ^runtime, ^session, requirement}
    assert requirement.required_capability == "asset.write"
    assert requirement.classification == :private
    refute requirement.requires_unlocked?

    assert_receive {:retry, command}
    assert command.asset_id == @asset_id
    assert command.vault_id == @vault_id
    assert command.principal_id == @principal_id
    assert command.classification == :private
    assert command.expected_state_revision == 1
  end

  test "non-retryable failures never enter the mutation scope" do
    Process.put(:status_asset, %{failed_asset() | retryable?: false})

    assert {:error, %Error{code: :conflict}} =
             Retry.run(runtime(), session(), @asset_id, 1)

    refute_received {:shared_scope, _runtime, _session, _requirement}
    refute_received {:retry, _command}
  end

  test "stale repository retry remains a successful no-op" do
    Process.put(:retry_result, {:ok, :stale})

    assert {:ok, :stale} =
             Retry.run(runtime(), session(), @asset_id, 0)
  end

  defp runtime do
    %{
      assets: {Assets, self()},
      operation_scope: {Scope, self()}
    }
  end

  defp session do
    %SessionContext{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: false
    }
  end

  defp failed_asset do
    %Asset{
      asset_id: @asset_id,
      vault_id: @vault_id,
      resource_version_id: @resource_version_id,
      classification: :private,
      state: :uploaded,
      state_revision: 1,
      failure_code: :storage_unavailable,
      retryable?: true,
      failed_operation: "asset_verify",
      attempt: 2
    }
  end
end
