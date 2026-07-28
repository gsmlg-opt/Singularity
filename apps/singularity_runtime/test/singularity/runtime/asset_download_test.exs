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
  @correlation_id "00000000-0000-4000-8000-000000000406"

  defmodule Scope do
    def with_read_request(owner, runtime, session, requirement, callback) do
      send(owner, {:scope, runtime, session, requirement})
      callback.(:scoped_repo)
    end
  end

  defmodule Assets do
    def authorized_download_descriptor(owner, :scoped_repo, asset_id) do
      send(owner, {:authorized_download_descriptor, asset_id})

      object = Process.get(:download_object, %{})

      descriptor =
        %{
          asset_id: asset_id,
          vault_id: Map.get(object, :vault_id),
          classification: Map.get(object, :classification, :private),
          plaintext_byte_size: Map.get(object, :plaintext_byte_size),
          detected_media_type: Map.get(object, :detected_media_type)
        }
        |> Map.merge(Map.get(object, :descriptor_extras, %{}))

      {:ok, descriptor}
    end

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
         object_generation: 3,
         plaintext_byte_size:
           Map.get(
             Process.get(:download_object, %{}),
             :plaintext_byte_size
           ),
         detected_media_type:
           Map.get(
             Process.get(:download_object, %{}),
             :detected_media_type
           )
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

  defmodule Audit do
    def append(owner, repo, event) do
      send(owner, {:audit, repo, event})

      case Process.get(:download_audit_result) do
        nil -> :ok
        result -> result
      end
    end
  end

  setup do
    Process.put(:download_object, %{
      vault_id: @vault_id,
      object_id: @object_id,
      plaintext_byte_size: 19,
      detected_media_type: "application/pdf"
    })

    on_exit(fn ->
      Process.delete(:download_object)
      Process.delete(:download_lease_result)
      Process.delete(:download_audit_result)
    end)
  end

  test "authorizes a read, obtains an opaque exact lease, and returns only authenticated bytes" do
    runtime = runtime()
    session = session()

    assert {:ok, "authenticated bytes"} =
             Download.run(runtime, session, @asset_id, 2..8, @correlation_id)

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

    assert_receive {:audit, :scoped_repo, audit}
    assert audit.action == "asset.downloaded"
    assert audit.result == :completed
    assert audit.correlation_id == @correlation_id
    assert audit.principal_id == @principal_id
    assert audit.vault_id == @vault_id
    assert audit.target_type == "asset"
    assert audit.target_id == @asset_id
    assert audit.metadata == %{}
  end

  test "describes only the authoritative plaintext size and safe detected media type" do
    runtime = runtime()
    session = session()

    assert {:ok,
            %{
              plaintext_byte_size: 19,
              detected_media_type: "application/pdf"
            } = descriptor} =
             Download.describe(runtime, session, @asset_id)

    assert map_size(descriptor) == 2
    assert_receive {:scope, ^runtime, ^session, _requirement}
    assert_receive {:authorized_download_descriptor, @asset_id}
    refute_received {:authorized_object, @asset_id}
    refute_received {:lease, _request}
    refute_received {:read, _lease, _range}
  end

  test "allows the safe generic media fallback before extraction completes" do
    Process.put(:download_object, %{
      vault_id: @vault_id,
      object_id: @object_id,
      plaintext_byte_size: 19,
      detected_media_type: "application/octet-stream"
    })

    assert {:ok,
            %{
              plaintext_byte_size: 19,
              detected_media_type: "application/octet-stream"
            }} =
             Download.describe(runtime(), session(), @asset_id)

    assert_receive {:authorized_download_descriptor, @asset_id}
    refute_received {:authorized_object, @asset_id}
  end

  test "rejects otherwise-valid download descriptors containing custody fields" do
    Process.put(:download_object, %{
      vault_id: @vault_id,
      object_id: @object_id,
      plaintext_byte_size: 19,
      detected_media_type: "application/pdf",
      descriptor_extras: %{
        object_id: @object_id,
        storage_ref: "must-not-cross-runtime-boundary"
      }
    })

    assert {:error, %Error{code: :integrity_failure}} =
             Download.describe(runtime(), session(), @asset_id)

    assert_receive {:authorized_download_descriptor, @asset_id}
    refute_received {:authorized_object, @asset_id}
    refute_received {:lease, _request}
    refute_received {:read, _lease, _range}
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

    assert_receive {:audit, :scoped_repo, download_audit}
    assert download_audit.action == "asset.downloaded"
    assert download_audit.classification == :sensitive

    assert_receive {:audit, :scoped_repo, sensitive_audit}
    assert sensitive_audit.action == "asset.sensitive_read"
    assert sensitive_audit.classification == :sensitive
  end

  test "never returns plaintext when the immutable audit append fails" do
    Process.put(
      :download_audit_result,
      {:error, Error.new(:storage_unavailable, retryable?: true)}
    )

    assert {:error, %Error{code: :storage_unavailable}} =
             Download.run(
               runtime(),
               session(),
               @asset_id,
               :all,
               @correlation_id
             )

    assert_receive {:read, _lease, :all}
    assert_receive {:audit, :scoped_repo, _event}
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
      audit: {Audit, self()},
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
