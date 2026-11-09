defmodule Singularity.Storage.Postgres.BackupStatusStore do
  @moduledoc false

  @behaviour Singularity.Core.BackupStatusStore

  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Audit.BackupManifest

  @impl true
  def fetch(repo, %{operation_id: operation_id, vault_id: vault_id} = selector)
      when map_size(selector) == 2 do
    with :ok <- UUID.validate([operation_id, vault_id]) do
      case repo.one(status_query(operation_id, vault_id)) do
        nil -> {:error, Error.new(:not_found)}
        status -> {:ok, status}
      end
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def fetch(_repo, _selector), do: {:error, Error.new(:invalid)}

  defp status_query(operation_id, vault_id) do
    from manifest in BackupManifest,
      where: manifest.id == ^operation_id and manifest.vault_id == ^vault_id,
      select: %{
        operation_id: manifest.id,
        vault_id: manifest.vault_id,
        status: manifest.status,
        requested_at: manifest.inserted_at,
        updated_at: manifest.updated_at
      }
  end
end
