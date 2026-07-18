defmodule Singularity.Storage.VaultLock do
  @moduledoc """
  Serializes vault operations with session-level PostgreSQL advisory locks.
  """

  @shared_lock_sql """
  SELECT pg_advisory_lock_shared(hashtextextended($1::text, 0))
  """
  @shared_unlock_sql """
  SELECT pg_advisory_unlock_shared(hashtextextended($1::text, 0))
  """
  @exclusive_lock_sql """
  SELECT pg_advisory_lock(hashtextextended($1::text, 0))
  """
  @exclusive_unlock_sql """
  SELECT pg_advisory_unlock(hashtextextended($1::text, 0))
  """

  def with_shared(repo, vault_id, callback) do
    repo.checkout(fn ->
      :ok = acquire_shared(repo, vault_id)

      try do
        callback.(repo)
      after
        release_shared(repo, vault_id)
      end
    end)
  end

  def with_exclusive(repo, vault_id, callback) do
    repo.checkout(fn ->
      :ok = acquire_exclusive(repo, vault_id)

      try do
        callback.(repo)
      after
        release_exclusive(repo, vault_id)
      end
    end)
  end

  defp acquire_shared(repo, vault_id) do
    Ecto.Adapters.SQL.query!(repo, @shared_lock_sql, [lock_key(vault_id)])
    :ok
  end

  defp release_shared(repo, vault_id) do
    %{rows: [[true]]} =
      Ecto.Adapters.SQL.query!(repo, @shared_unlock_sql, [lock_key(vault_id)])

    :ok
  end

  defp acquire_exclusive(repo, vault_id) do
    Ecto.Adapters.SQL.query!(repo, @exclusive_lock_sql, [lock_key(vault_id)])
    :ok
  end

  defp release_exclusive(repo, vault_id) do
    %{rows: [[true]]} =
      Ecto.Adapters.SQL.query!(repo, @exclusive_unlock_sql, [lock_key(vault_id)])

    :ok
  end

  defp lock_key(vault_id), do: "singularity:vault:" <> uuid!(vault_id)

  defp uuid!(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "vault advisory lock requires a valid UUID"
    end
  end
end
