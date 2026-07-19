defmodule Singularity.Runtime.AssetDownloadTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.Assets.Download
  alias Singularity.Runtime.SessionContext

  @session_id "00000000-0000-4000-8000-000000000401"
  @principal_id "00000000-0000-4000-8000-000000000402"
  @vault_id "00000000-0000-4000-8000-000000000403"
  @asset_id "00000000-0000-4000-8000-000000000404"
  @object_id "00000000-0000-4000-8000-000000000405"

  defmodule Scope do
    def with_read_request(owner, runtime, session, requirement, callback) do
      send(owner, {:scope, runtime, session, requirement})
      callback.(:scoped_repo)
    end
  end

  defmodule Assets do
    def authorized_object(owner, :scoped_repo, asset_id) do
      send(owner, {:authorized_object, asset_id})

      {:ok,
       %{
         asset_id: asset_id,
         vault_id: Map.get(Process.get(:download_object, %{}), :vault_id),
         classification:
           Map.get(
             Process.get(:download_object, %{}),
             :classification,
             :private
           ),
         object_id: Map.get(Process.get(:download_object, %{}), :object_id),
         object_generation: 3
       }}
    end
  end

  defmodule Custodian do
    def lease(owner, request) do
      send(owner, {:lease, request})

      case Process.get(:download_lease_result) do
        nil -> {:ok, {:opaque_lease, make_ref()}}
        result -> result
      end
    end
  end

  defmodule Reader do
    def read(owner, lease, range) do
      send(owner, {:read, lease, range})
      {:ok, "authenticated bytes"}
    end
  end

  setup do
    Process.put(:download_object, %{
      vault_id: @vault_id,
      object_id: @object_id
    })

    on_exit(fn ->
      Process.delete(:download_object)
      Process.delete(:download_lease_result)
    end)
  end

  test "authorizes a read, obtains an opaque exact lease, and returns only authenticated bytes" do
    runtime = runtime()
    session = session()

    assert {:ok, "authenticated bytes"} =
             Download.run(runtime, session, @asset_id, 2..8)

    assert_receive {:scope, ^runtime, ^session, requirement}
    assert requirement.required_capability == "asset.read"
    assert requirement.classification == :private
    assert requirement.requires_unlocked?
    assert requirement.vault_id == @vault_id

    assert_receive {:authorized_object, @asset_id}
    assert_receive {:lease, lease_request}
    assert lease_request.session_id == @session_id
    assert lease_request.principal_id == @principal_id
    assert lease_request.vault_id == @vault_id
    assert lease_request.required_capability == "asset.read"
    assert lease_request.principal_authorization_epoch == 7
    assert lease_request.vault_authorization_epoch == 11
    assert lease_request.object_id == @object_id
    assert lease_request.object_generation == 3

    assert_receive {:read, lease, 2..8}
    assert match?({:opaque_lease, _reference}, lease)
    refute_received {:read, %{object_dek: _secret}, _range}
  end

  test "maps unavailable custody to the stable locked result without reading" do
    Process.put(:download_lease_result, {:error, :waiting_for_unlock})

    assert {:error, %Error{code: :vault_locked}} =
             Download.run(runtime(), session(), @asset_id, :all)

    refute_received {:read, _lease, _range}
  end

  test "reauthorizes the discovered object at its exact non-private classification" do
    Process.put(:download_object, %{
      vault_id: @vault_id,
      object_id: @object_id,
      classification: :sensitive
    })

    runtime = runtime()
    session = session()

    assert {:ok, "authenticated bytes"} =
             Download.run(runtime, session, @asset_id, :all)

    assert_receive {:scope, ^runtime, ^session, %{classification: :private}}
    assert_receive {:scope, ^runtime, ^session, %{classification: :sensitive}}
    assert_receive {:lease, _lease_request}
    assert_receive {:read, _lease, :all}
  end

  test "fails closed if the authorized object crosses the session vault" do
    Process.put(:download_object, %{
      vault_id: Ecto.UUID.generate(),
      object_id: @object_id
    })

    assert {:error, %Error{code: :integrity_failure}} =
             Download.run(runtime(), session(), @asset_id, :all)

    refute_received {:lease, _request}
    refute_received {:read, _lease, _range}
  end

  defp runtime do
    %{
      assets: {Assets, self()},
      authenticated_reader: {Reader, self()},
      custodian: {Custodian, self()},
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
      unlocked?: true
    }
  end
end
