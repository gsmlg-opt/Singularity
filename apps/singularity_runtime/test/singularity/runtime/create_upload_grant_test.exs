defmodule Singularity.Runtime.CreateUploadGrantTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.Assets.CreateUploadGrant
  alias Singularity.Runtime.SessionContext

  @csrf_token "exact-issued-csrf-token"

  defmodule Scope do
    def with_shared_request(owner, _runtime, _session, requirement, callback) do
      send(owner, {:requirement, requirement})
      callback.(:repo)
    end
  end

  defmodule Assets do
    def create_upload_grant(owner, :repo, command) do
      send(owner, {:grant_command, command})
      {:ok, Map.put(command, :state, :granted)}
    end
  end

  test "creates a five-minute grant bound to the exact request" do
    owner = self()
    now = ~U[2026-07-19 09:00:00.000000Z]
    token = :binary.copy(<<0xA5>>, 32)
    session = session()
    request = attrs()

    runtime = %{
      assets: {Assets, owner},
      clock: fn -> now end,
      id_generator: fn -> Ecto.UUID.generate() end,
      operation_scope: {Scope, owner},
      random_bytes: fn 32 -> token end
    }

    assert {:ok, grant} =
             CreateUploadGrant.run(
               runtime,
               session,
               request,
               @csrf_token
             )

    assert grant.token == Base.url_encode64(token, padding: false)
    assert DateTime.diff(grant.expires_at, now, :second) == 300
    refute Map.has_key?(grant, :token_digest)
    refute Map.has_key?(grant, :csrf_token_digest)

    assert_receive {:requirement,
                    %{
                      required_capability: "asset.write",
                      classification: :private,
                      requires_unlocked?: true
                    }}

    assert_receive {:grant_command, command}
    assert command.session_id == session.session_id
    assert command.principal_id == session.principal_id
    assert command.vault_id == session.vault_id
    assert command.token_digest == :crypto.hash(:sha256, token)

    assert command.csrf_token_digest ==
             :crypto.hash(:sha256, @csrf_token)

    refute Map.has_key?(command, :csrf_token)
    assert command.filename == "report.pdf"
    assert command.byte_size == 12
    assert command.declared_media_type == "application/pdf"
    assert command.idempotency_key == "upload-1"
    assert command.classification == :private
    assert command.server_owned_resource? == true

    assert Enum.all?(
             [
               command.grant_id,
               command.asset_id,
               command.source_reference_id,
               command.resource_id,
               command.resource_version_id
             ],
             &match?({:ok, _}, Ecto.UUID.cast(&1))
           )

    assert 5 ==
             [
               command.grant_id,
               command.asset_id,
               command.source_reference_id,
               command.resource_id,
               command.resource_version_id
             ]
             |> Enum.uniq()
             |> length()
  end

  test "caps the grant at the session expiry" do
    owner = self()
    now = ~U[2026-07-19 09:00:00.000000Z]
    session = %{session() | expires_at: DateTime.add(now, 90, :second)}

    runtime = %{
      assets: {Assets, owner},
      clock: fn -> now end,
      id_generator: fn -> Ecto.UUID.generate() end,
      operation_scope: {Scope, owner},
      random_bytes: &:crypto.strong_rand_bytes/1
    }

    assert {:ok, grant} =
             CreateUploadGrant.run(
               runtime,
               session,
               attrs(),
               @csrf_token
             )

    assert grant.expires_at == session.expires_at
  end

  test "rejects unsupported media before entering authorization scope" do
    runtime = %{
      assets: {Assets, self()},
      clock: fn -> DateTime.utc_now() end,
      id_generator: fn -> Ecto.UUID.generate() end,
      operation_scope: {Scope, self()},
      random_bytes: &:crypto.strong_rand_bytes/1
    }

    assert {:error, %Error{code: :unsupported_media_type}} =
             CreateUploadGrant.run(
               runtime,
               session(),
               %{attrs() | declared_media_type: "text/plain"},
               @csrf_token
             )

    refute_received {:requirement, _}
    refute_received {:grant_command, _}
  end

  test "enforces the server upload limit before scope" do
    runtime = %{
      assets: {Assets, self()},
      clock: fn -> DateTime.utc_now() end,
      id_generator: fn -> Ecto.UUID.generate() end,
      operation_scope: {Scope, self()},
      random_bytes: &:crypto.strong_rand_bytes/1
    }

    assert {:error, %Error{code: :upload_too_large}} =
             CreateUploadGrant.run(
               runtime,
               session(),
               attrs()
               |> Map.put(:size, 512 * 1024 * 1024 + 1),
               @csrf_token
             )

    refute_received {:requirement, _}
    refute_received {:grant_command, _}
  end

  test "rejects client-owned authority fields before token or ID generation" do
    owner = self()

    runtime = %{
      assets: {Assets, owner},
      clock: fn -> DateTime.utc_now() end,
      id_generator: fn ->
        send(owner, :generated_id)
        Ecto.UUID.generate()
      end,
      operation_scope: {Scope, owner},
      random_bytes: fn 32 ->
        send(owner, :generated_token)
        :crypto.strong_rand_bytes(32)
      end
    }

    for {field, value} <- [
          {:resource_version_id, Ecto.UUID.generate()},
          {:classification, :private},
          {:checksum, "sha256:client-owned"},
          {:size_bytes, 12},
          {:max_bytes, 1024 * 1024 * 1024}
        ] do
      assert {:error, %Error{code: :invalid}} =
               CreateUploadGrant.run(
                 runtime,
                 session(),
                 Map.put(attrs(), field, value),
                 @csrf_token
               )
    end

    refute_received :generated_id
    refute_received :generated_token
    refute_received {:requirement, _}
    refute_received {:grant_command, _}
  end

  test "rejects an invalid session expiry before entering authorization scope" do
    runtime = %{
      assets: {Assets, self()},
      clock: fn -> DateTime.utc_now() end,
      id_generator: fn -> Ecto.UUID.generate() end,
      operation_scope: {Scope, self()},
      random_bytes: &:crypto.strong_rand_bytes/1
    }

    assert {:error, %Error{code: :invalid}} =
             CreateUploadGrant.run(
               runtime,
               %{session() | expires_at: nil},
               attrs(),
               @csrf_token
             )

    refute_received {:requirement, _}
    refute_received {:grant_command, _}
  end

  defp attrs do
    %{
      filename: "report.pdf",
      size: 12,
      declared_media_type: "application/pdf",
      idempotency_key: "upload-1"
    }
  end

  defp session do
    %SessionContext{
      session_id: Ecto.UUID.generate(),
      account_id: Ecto.UUID.generate(),
      principal_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.generate(),
      expires_at: ~U[2026-07-19 10:00:00Z],
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      authorization_epoch: 7,
      unlocked?: true
    }
  end
end
