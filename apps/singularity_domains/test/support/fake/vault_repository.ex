defmodule Fake.VaultRepository do
  use Agent

  @behaviour Singularity.Domains.Vaults.Repository

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end)
  end

  def put_authorization(context, authorization) do
    key = {authorization.principal_id, authorization.vault_id}
    Agent.update(context, &Map.put(&1, key, authorization))
  end

  @impl true
  def resolve_authorization(context, %{principal_id: principal_id, vault_id: vault_id}) do
    authorization =
      Agent.get(context, &Map.get(&1, {principal_id, vault_id}))

    {:ok, authorization}
  end
end
