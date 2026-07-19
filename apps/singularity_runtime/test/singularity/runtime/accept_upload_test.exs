defmodule Singularity.Runtime.AcceptUploadTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.Assets.AcceptUpload
  alias Singularity.Runtime.SessionContext

  @session_id "00000000-0000-4000-8000-000000000301"
  @principal_id "00000000-0000-4000-8000-000000000302"
  @vault_id "00000000-0000-4000-8000-000000000303"
  @grant_id "00000000-0000-4000-8000-000000000304"
  @asset_id "00000000-0000-4000-8000-000000000305"

  defmodule Custodian do
    def prepare_upload(owner, request) do
      send(owner, {:prepare_upload, request})

      {:ok,
       %{
         material_ref: make_ref(),
         stage_id: Ecto.UUID.generate(),
         candidate_object_id: Ecto.UUID.generate(),
         key_domain_id: Ecto.UUID.generate(),
         domain_key_version_id: Ecto.UUID.generate(),
         storage_ref: Ecto.UUID.generate(),
         wrapper_algorithm: "aes_256_gcm",
         key_generation: 3,
         dek_wrapper: :crypto.strong_rand_bytes(60)
       }}
    end

    def discard_upload(owner, material_ref) do
      send(owner, {:discard_upload, material_ref})
      :ok
    end
  end

  defmodule UploadSupervisor do
    def begin_upload(owner, runtime, session, grant, controller) do
      send(owner, {:begin_upload, runtime, session, grant, controller})

      case Map.get(runtime, :begin_result) do
        nil ->
          upload = spawn(fn -> Process.sleep(:infinity) end)
          {:ok, upload}

        :raise ->
          raise "upload supervisor unavailable"

        result ->
          result
      end
    end
  end

  test "prepares custody material and starts only an opaque bounded upload handle" do
    runtime = runtime()
    session = session()
    grant = grant()

    assert {:ok, upload} =
             AcceptUpload.begin(runtime, session, grant, self())

    assert is_pid(upload)
    on_exit(fn -> Process.exit(upload, :kill) end)

    assert_receive {:prepare_upload, request}
    assert request.grant_id == @grant_id
    assert request.asset_id == @asset_id
    assert request.session_id == @session_id
    assert request.principal_id == @principal_id
    assert request.vault_id == @vault_id
    assert request.classification == :private
    assert request.principal_authorization_epoch == 7
    assert request.vault_authorization_epoch == 11

    assert_receive {:begin_upload, ^runtime, ^session, internal_grant, controller}
    assert controller == self()
    assert internal_grant.id == @grant_id
    assert is_reference(internal_grant.upload.material_ref)
    refute Map.has_key?(internal_grant.upload, :object_dek)
    refute Map.has_key?(internal_grant.upload, :domain_dedup_key)
    refute_received {:discard_upload, _material_ref}
  end

  test "capacity rejection discards unclaimed custody material" do
    runtime =
      runtime()
      |> Map.put(
        :begin_result,
        {:error, Error.new(:storage_unavailable, retryable?: true)}
      )

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             AcceptUpload.begin(runtime, session(), grant(), self())

    assert_receive {:begin_upload, ^runtime, _session, internal_grant, _controller}
    assert_receive {:discard_upload, material_ref}
    assert material_ref == internal_grant.upload.material_ref
  end

  test "supervisor failure still discards unclaimed custody material" do
    runtime = Map.put(runtime(), :begin_result, :raise)

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             AcceptUpload.begin(runtime, session(), grant(), self())

    assert_receive {:begin_upload, ^runtime, _session, internal_grant, _controller}
    assert_receive {:discard_upload, material_ref}
    assert material_ref == internal_grant.upload.material_ref
  end

  test "rejects a changed session binding before custody" do
    changed = %{grant() | principal_id: Ecto.UUID.generate()}

    assert {:error, %Error{code: :invalid}} =
             AcceptUpload.begin(runtime(), session(), changed, self())

    refute_received {:prepare_upload, _request}
    refute_received {:begin_upload, _runtime, _session, _grant, _controller}
  end

  defp runtime do
    %{
      custodian: {Custodian, self()},
      upload_supervisor: {UploadSupervisor, self()}
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

  defp grant do
    %{
      id: @grant_id,
      grant_id: @grant_id,
      asset_id: @asset_id,
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      classification: :private,
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11
    }
  end
end
