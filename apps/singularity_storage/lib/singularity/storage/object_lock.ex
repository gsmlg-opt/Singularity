defmodule Singularity.Storage.ObjectLock do
  @moduledoc """
  Serializes operations for one object on an existing repository connection.
  """

  @exclusive_lock_sql """
  SELECT pg_advisory_lock(hashtextextended($1::text, 0))
  """
  @exclusive_unlock_sql """
  SELECT pg_advisory_unlock(hashtextextended($1::text, 0))
  """

  def with_exclusive(repo, object_id, callback) do
    assert_checked_out!(repo)
    key = lock_key(object_id)
    :ok = acquire(repo, key)

    try do
      callback.()
    after
      release(repo, key)
    end
  end

  defp assert_checked_out!(repo) do
    unless repo.checked_out?() do
      raise ArgumentError,
            "object advisory lock requires an already checked-out repository connection"
    end
  end

  defp acquire(repo, key) do
    Ecto.Adapters.SQL.query!(repo, @exclusive_lock_sql, [key])
    :ok
  end

  defp release(repo, key) do
    %{rows: [[true]]} = Ecto.Adapters.SQL.query!(repo, @exclusive_unlock_sql, [key])
    :ok
  end

  defp lock_key(object_id), do: "singularity:object:" <> uuid!(object_id)

  defp uuid!(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "object advisory lock requires a valid UUID"
    end
  end
end
