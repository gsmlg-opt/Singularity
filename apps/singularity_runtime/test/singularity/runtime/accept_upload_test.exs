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

  defmodule Scope do
    def with_read_request(owner, runtime, session, requirement, callback) do
      send(owner, {:scope, runtime, session, requirement})
      callback.(:repo)
    end
  end

  defmodule Assets do
    def load_upload_grant_descriptor(owner, :repo, selector) do
      send(owner, {:load_upload_grant_descriptor, selector})
      {:ok, Process.get(:upload_grant_descriptor)}
    end
  end

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
    assert internal_grant.token_digest == :binary.copy(<<0xD1>>, 32)
    assert internal_grant.csrf_token_digest == :binary.copy(<<0xD2>>, 32)
    assert internal_grant.request_content_length == 12
    assert internal_grant.request_declared_media_type == "application/pdf"
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

  test "rejects raw credential fields before custody instead of sanitizing them" do
    for field <- [:token, :upload_token, :csrf_token] do
      assert {:error, %Error{code: :invalid}} =
               AcceptUpload.begin(
                 runtime(),
                 session(),
                 Map.put(grant(), field, "RAW_CREDENTIAL_CANARY"),
                 self()
               )
    end

    refute_received {:prepare_upload, _request}
    refute_received {:begin_upload, _runtime, _session, _grant, _controller}
  end

  test "loads the canonical descriptor with the complete digest-only selector before custody" do
    selector = %{
      grant_id: @grant_id,
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      token_digest: :binary.copy(<<0xD1>>, 32),
      csrf_token_digest: :binary.copy(<<0xD2>>, 32),
      request_content_length: 12,
      request_declared_media_type: "application/pdf"
    }

    Process.put(:upload_grant_descriptor, descriptor())
    on_exit(fn -> Process.delete(:upload_grant_descriptor) end)

    runtime = %{
      assets: {Assets, self()},
      operation_scope: {Scope, self()}
    }

    assert {:ok, descriptor} =
             AcceptUpload.load_grant_descriptor(
               runtime,
               session(),
               selector
             )

    assert descriptor.grant_id == @grant_id

    assert_receive {:scope, ^runtime, _session,
                    %{
                      required_capability: "asset.write",
                      classification: :private,
                      requires_unlocked?: true
                    }}

    assert_receive {:load_upload_grant_descriptor, ^selector}
  end

  test "reauthorizes a non-private descriptor and compares an exact reload" do
    Process.put(
      :upload_grant_descriptor,
      %{descriptor() | classification: :sensitive}
    )

    on_exit(fn -> Process.delete(:upload_grant_descriptor) end)

    selector = %{
      grant_id: @grant_id,
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      token_digest: :binary.copy(<<0xD1>>, 32),
      csrf_token_digest: :binary.copy(<<0xD2>>, 32),
      request_content_length: 12,
      request_declared_media_type: "application/pdf"
    }

    runtime = %{
      assets: {Assets, self()},
      operation_scope: {Scope, self()}
    }

    assert {:ok, %{classification: :sensitive}} =
             AcceptUpload.load_grant_descriptor(
               runtime,
               session(),
               selector
             )

    assert_receive {:scope, ^runtime, _session, %{classification: :private}}
    assert_receive {:scope, ^runtime, _session, %{classification: :sensitive}}
    assert_receive {:load_upload_grant_descriptor, ^selector}
    assert_receive {:load_upload_grant_descriptor, ^selector}
  end

  test "fails closed if a descriptor leaks credential material" do
    on_exit(fn -> Process.delete(:upload_grant_descriptor) end)

    selector = %{
      grant_id: @grant_id,
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      token_digest: :binary.copy(<<0xD1>>, 32),
      csrf_token_digest: :binary.copy(<<0xD2>>, 32),
      request_content_length: 12,
      request_declared_media_type: "application/pdf"
    }

    for {field, value} <- [
          token: "RAW_TOKEN_CANARY",
          token_digest: :binary.copy(<<0xD1>>, 32),
          csrf_token_digest: :binary.copy(<<0xD2>>, 32)
        ] do
      Process.put(
        :upload_grant_descriptor,
        Map.put(descriptor(), field, value)
      )

      assert {:error, %Error{code: :integrity_failure}} =
               AcceptUpload.load_grant_descriptor(
                 %{
                   assets: {Assets, self()},
                   operation_scope: {Scope, self()}
                 },
                 session(),
                 selector
               )
    end
  end

  test "rejects raw credential fields in a descriptor selector before repo access" do
    selector = %{
      grant_id: @grant_id,
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      token_digest: :binary.copy(<<0xD1>>, 32),
      csrf_token_digest: :binary.copy(<<0xD2>>, 32),
      request_content_length: 12,
      request_declared_media_type: "application/pdf",
      token: "RAW_TOKEN_CANARY"
    }

    assert {:error, %Error{code: :invalid}} =
             AcceptUpload.load_grant_descriptor(
               %{
                 assets: {Assets, self()},
                 operation_scope: {Scope, self()}
               },
               session(),
               selector
             )

    refute_received {:scope, _runtime, _session, _requirement}
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
      vault_authorization_epoch: 11,
      token_digest: :binary.copy(<<0xD1>>, 32),
      csrf_token_digest: :binary.copy(<<0xD2>>, 32),
      request_content_length: 12,
      request_declared_media_type: "application/pdf"
    }
  end

  defp descriptor do
    Map.drop(grant(), [:token_digest, :csrf_token_digest])
  end
end
