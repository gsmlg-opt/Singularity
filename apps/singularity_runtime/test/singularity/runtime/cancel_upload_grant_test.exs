defmodule Singularity.Runtime.CancelUploadGrantTest do
  use ExUnit.Case, async: true

  alias Singularity.Runtime.Assets.CancelUploadGrant
  alias Singularity.Runtime.SessionContext

  @grant_id "00000000-0000-4000-8000-000000000701"
  @asset_id "00000000-0000-4000-8000-000000000702"

  defmodule Scope do
    def with_shared_request(owner, _runtime, session, requirement, callback) do
      send(owner, {:scope, session, requirement})
      callback.(:repo)
    end
  end

  defmodule Assets do
    def cancel_upload_grant(owner, :repo, command) do
      send(owner, {:cancel_command, command})

      {:ok,
       %{
         status: :cancelled,
         grant_id: "00000000-0000-4000-8000-000000000701",
         asset_id: "00000000-0000-4000-8000-000000000702",
         vault_id: command.vault_id
       }}
    end
  end

  test "authorizes and binds cancellation to the current session without a token" do
    session = session()

    runtime = %{
      assets: {Assets, self()},
      operation_scope: {Scope, self()}
    }

    assert {:ok,
            %{
              status: :cancelled,
              grant_id: @grant_id,
              asset_id: @asset_id,
              vault_id: vault_id
            }} =
             CancelUploadGrant.run(runtime, session, @grant_id)

    assert vault_id == session.vault_id

    assert_receive {:scope, ^session,
                    %{
                      required_capability: "asset.write",
                      classification: :private,
                      requires_unlocked?: false
                    }}

    assert_receive {:cancel_command,
                    %{
                      grant_id: @grant_id,
                      session_id: session_id,
                      principal_id: principal_id,
                      vault_id: vault_id
                    } = command}

    assert session_id == session.session_id
    assert principal_id == session.principal_id
    assert vault_id == session.vault_id
    refute Map.has_key?(command, :token)
    refute Map.has_key?(command, :token_digest)
  end

  defp session do
    %SessionContext{
      session_id: Ecto.UUID.generate(),
      account_id: Ecto.UUID.generate(),
      principal_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.generate(),
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
      principal_authorization_epoch: 1,
      vault_authorization_epoch: 1,
      authorization_epoch: 1,
      unlocked?: false
    }
  end
end
