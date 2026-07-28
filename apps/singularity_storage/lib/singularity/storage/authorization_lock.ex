defmodule Singularity.Storage.AuthorizationLock do
  @moduledoc """
  Serializes authorization changes on an existing checked-out repository handle.
  """

  alias Singularity.Storage.SafeSQL

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

  def with_shared(repo, principal_id, vault_id, callback) do
    assert_checked_out!(repo)
    :ok = acquire_shared(repo, principal_id, vault_id)

    try do
      callback.(repo)
    after
      release_shared(repo, principal_id, vault_id)
    end
  end

  def with_exclusive(repo, principal_id, vault_id, callback) do
    assert_checked_out!(repo)
    :ok = acquire_exclusive(repo, principal_id, vault_id)

    try do
      callback.(repo)
    after
      release_exclusive(repo, principal_id, vault_id)
    end
  end

  defp assert_checked_out!(repo) do
    unless repo.checked_out?() do
      raise ArgumentError,
            "authorization advisory lock requires an already checked-out repository connection"
    end
  end

  defp acquire_shared(repo, principal_id, vault_id) do
    SafeSQL.query!(repo, @shared_lock_sql, [lock_key(principal_id, vault_id)])
    :ok
  end

  defp release_shared(repo, principal_id, vault_id) do
    %{rows: [[true]]} =
      SafeSQL.query!(repo, @shared_unlock_sql, [lock_key(principal_id, vault_id)])

    :ok
  end

  defp acquire_exclusive(repo, principal_id, vault_id) do
    SafeSQL.query!(repo, @exclusive_lock_sql, [lock_key(principal_id, vault_id)])
    :ok
  end

  defp release_exclusive(repo, principal_id, vault_id) do
    %{rows: [[true]]} =
      SafeSQL.query!(repo, @exclusive_unlock_sql, [lock_key(principal_id, vault_id)])

    :ok
  end

  defp lock_key(principal_id, vault_id) do
    "singularity:authorization:" <> uuid!(principal_id) <> ":" <> uuid!(vault_id)
  end

  defp uuid!(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "authorization advisory lock requires valid UUIDs"
    end
  end
end
