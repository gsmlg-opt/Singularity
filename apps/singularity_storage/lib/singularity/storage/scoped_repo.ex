defmodule Singularity.Storage.ScopedRepo do
  @moduledoc """
  Runs request-scoped work with PostgreSQL row-level security context.
  """

  @absent_context_values [nil, ""]

  def transact(repo, context, fun), do: transact(repo, context, [], fun)

  def transact(
        repo,
        %{principal_id: principal_id, vault_id: vault_id},
        transaction_options,
        fun
      ) do
    result =
      case repo.transaction(
             fn ->
               assert_context_absent!(repo)

               principal_id = normalize_uuid!(principal_id, :principal_id)
               vault_id = normalize_uuid!(vault_id, :vault_id)

               Ecto.Adapters.SQL.query!(
                 repo,
                 "SELECT set_config('singularity.principal_id', $1, true), " <>
                   "set_config('singularity.vault_id', $2, true)",
                 [principal_id, vault_id]
               )

               case fun.(repo) do
                 {:error, reason} -> repo.rollback(reason)
                 success -> success
               end
             end,
             transaction_options
           ) do
        {:ok, success} -> success
        {:error, reason} -> {:error, reason}
      end

    assert_context_absent!(repo)
    result
  end

  defp assert_context_absent!(repo) do
    %{rows: [[principal_id, vault_id]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT
          current_setting('singularity.principal_id', true),
          current_setting('singularity.vault_id', true)
        """,
        []
      )

    if principal_id in @absent_context_values and vault_id in @absent_context_values do
      :ok
    else
      raise "pre-existing PostgreSQL request context on checked-out connection"
    end
  end

  defp normalize_uuid!(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} ->
        uuid

      :error ->
        raise ArgumentError,
              "invalid #{field} UUID in PostgreSQL request context; " <>
                "expected canonical UUID text or a 16-byte Ecto UUID dump"
    end
  end
end
