Code.require_file("../../support/fake/vault_repository.ex", __DIR__)

defmodule Singularity.Domains.VaultsTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Domains.Vaults

  @principal_id "principal-1"
  @vault_id "vault-1"
  @capability "assets.read"
  @authorization_epoch 7

  setup do
    context = start_supervised!(Fake.VaultRepository)

    {:ok,
     adapters: %{
       repository: Fake.VaultRepository,
       context: context
     }}
  end

  test "authorizes an active membership with the exact required capability and epoch", %{
    adapters: adapters
  } do
    put_authorization(adapters)

    assert :ok = Vaults.authorize(adapters, command())
  end

  test "rejects a hierarchical capability near-match", %{adapters: adapters} do
    put_authorization(adapters, capabilities: [@capability <> ".sensitive"])

    assert {:error, %Error{code: :forbidden}} =
             Vaults.authorize(adapters, command())
  end

  test "rejects a stale authorization epoch", %{adapters: adapters} do
    put_authorization(adapters)

    assert {:error, %Error{code: :forbidden}} =
             Vaults.authorize(adapters, command(authorization_epoch: @authorization_epoch - 1))
  end

  test "rejects a negative authorization epoch as a denial", %{adapters: adapters} do
    put_authorization(adapters)

    assert {:error, %Error{code: :forbidden}} =
             Vaults.authorize(adapters, command(authorization_epoch: -1))
  end

  test "rejects a missing membership", %{adapters: adapters} do
    assert {:error, %Error{code: :forbidden}} =
             Vaults.authorize(adapters, command())
  end

  test "rejects a revoked membership", %{adapters: adapters} do
    put_authorization(adapters, status: :revoked)

    assert {:error, %Error{code: :forbidden}} =
             Vaults.authorize(adapters, command())
  end

  test "rejects a locked vault before a sensitive effect", %{adapters: adapters} do
    put_authorization(adapters, locked?: true)

    result =
      with :ok <- Vaults.authorize(adapters, command(requires_unlocked?: true)) do
        send(self(), :sensitive_effect)
        :ok
      end

    assert {:error, %Error{code: :vault_locked}} = result
    refute_received :sensitive_effect
  end

  defp put_authorization(adapters, overrides \\ []) do
    authorization =
      %{
        principal_id: @principal_id,
        vault_id: @vault_id,
        status: :active,
        capabilities: [@capability],
        authorization_epoch: @authorization_epoch,
        locked?: false
      }
      |> Map.merge(Map.new(overrides))

    :ok = Fake.VaultRepository.put_authorization(adapters.context, authorization)
  end

  defp command(overrides \\ []) do
    %{
      principal_id: @principal_id,
      vault_id: @vault_id,
      required_capability: @capability,
      authorization_epoch: @authorization_epoch,
      requires_unlocked?: false
    }
    |> Map.merge(Map.new(overrides))
  end
end
