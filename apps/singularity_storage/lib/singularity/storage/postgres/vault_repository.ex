defmodule Singularity.Storage.Postgres.VaultRepository do
  @moduledoc false

  @behaviour Singularity.Domains.Vaults.Repository

  alias Ecto.Adapters.SQL
  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.UUID

  @impl true
  def resolve_authorization(
        repo,
        %{principal_id: principal_id, vault_id: vault_id}
      )
      when is_binary(principal_id) and is_binary(vault_id) do
    with {:ok, dumped_principal_id} <- UUID.dump(principal_id),
         {:ok, dumped_vault_id} <- UUID.dump(vault_id) do
      case SQL.query(
             repo,
             """
             SELECT
               member.revoked_at,
               vault.authorization_epoch,
               vault.locked,
               COALESCE(
                 array_agg(capability.name ORDER BY capability.name)
                   FILTER (
                     WHERE assignment.capability_id IS NOT NULL
                       AND assignment.revoked_at IS NULL
                   ),
                 ARRAY[]::text[]
               )
             FROM core.vault_members AS member
             JOIN core.vaults AS vault ON vault.id = member.vault_id
             LEFT JOIN core.principal_capabilities AS assignment
               ON assignment.principal_id = member.principal_id
              AND assignment.vault_id = member.vault_id
             LEFT JOIN core.capabilities AS capability
               ON capability.id = assignment.capability_id
             WHERE member.principal_id = $1
               AND member.vault_id = $2
             GROUP BY member.revoked_at, vault.authorization_epoch, vault.locked
             """,
             [dumped_principal_id, dumped_vault_id],
             log: false
           ) do
        {:ok, %{rows: []}} ->
          {:ok, nil}

        {:ok, %{rows: [[revoked_at, authorization_epoch, locked?, capabilities]]}} ->
          {:ok,
           %{
             principal_id: canonical_uuid(principal_id),
             vault_id: canonical_uuid(vault_id),
             status: if(is_nil(revoked_at), do: :active, else: :revoked),
             capabilities: capabilities,
             authorization_epoch: authorization_epoch,
             locked?: locked?
           }}

        {:error, _reason} ->
          {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    else
      :error -> {:error, Error.new(:invalid)}
    end
  end

  def resolve_authorization(_repo, _lookup), do: {:error, Error.new(:invalid)}

  defp canonical_uuid(value) do
    case UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end
end
