defmodule Singularity.Storage.Postgres.DocumentMutationReceipts do
  @moduledoc "Internal transaction-local Document receipt ownership; callers supply only a storage-derived HMAC."
  alias Singularity.Core.Error
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.Postgres.{KnowledgeError, UUID}

  def with_claim(
        repo,
        %{
          owner_scope_id: owner,
          principal_id: principal,
          mutation_id: mutation,
          fingerprint: <<_::256>>,
          inserted_at: %DateTime{}
        } = claim,
        callback
      )
      when is_function(callback, 0) do
    with true <- repo.in_transaction?(),
         :ok <- UUID.validate([owner, principal, mutation]),
         :ok <- matching_context(repo, owner, principal) do
      params = [Ecto.UUID.dump!(owner), Ecto.UUID.dump!(principal), Ecto.UUID.dump!(mutation)]

      case SafeSQL.query!(
             repo,
             """
             INSERT INTO content.document_import_receipts
               (vault_id,principal_id,mutation_id,request_fingerprint,state,inserted_at)
             VALUES ($1,$2,$3,$4,'pending',$5)
             ON CONFLICT (vault_id,principal_id,mutation_id) DO NOTHING RETURNING mutation_id
             """,
             params ++ [claim.fingerprint, claim.inserted_at]
           ) do
        %{rows: [[_]]} -> complete(repo, params, callback)
        %{rows: []} -> replay(repo, params, claim.fingerprint)
      end
    else
      false -> error(:invalid)
      {:error, %Error{}} = result -> result
    end
  rescue
    exception -> {:error, KnowledgeError.from(exception)}
  end

  def with_claim(_, _, _), do: error(:invalid)

  defp matching_context(repo, owner, principal) do
    case SafeSQL.query!(
           repo,
           "SELECT current_setting('singularity.principal_id',true), current_setting('singularity.vault_id',true)",
           []
         ) do
      %{rows: [[^principal, ^owner]]} -> :ok
      _ -> error(:forbidden)
    end
  end

  defp complete(repo, params, callback) do
    with {:ok, %{resource_id: resource, resource_version_id: version}} <- callback.(),
         :ok <- UUID.validate([resource, version]) do
      SafeSQL.query!(
        repo,
        """
        UPDATE content.document_import_receipts SET state='completed',resource_id=$4,version_id=$5
        WHERE vault_id=$1 AND principal_id=$2 AND mutation_id=$3 AND state='pending'
        """,
        params ++ [Ecto.UUID.dump!(resource), Ecto.UUID.dump!(version)]
      )

      SafeSQL.query!(
        repo,
        """
        SET CONSTRAINTS content.document_import_receipts_version_fkey,
          content.document_import_receipts_completed_check IMMEDIATE
        """,
        []
      )

      {:ok, %{resource_id: resource, resource_version_id: version}}
    else
      {:error, %Error{} = reason} -> {:error, KnowledgeError.from(reason)}
      _ -> error(:invalid)
    end
  end

  defp replay(repo, params, fingerprint) do
    case SafeSQL.query!(
           repo,
           """
           SELECT request_fingerprint,state,resource_id,version_id
           FROM content.document_import_receipts
           WHERE vault_id=$1 AND principal_id=$2 AND mutation_id=$3 FOR UPDATE
           """,
           params
         ) do
      %{rows: [[^fingerprint, "completed", resource, version]]}
      when not is_nil(resource) and not is_nil(version) ->
        {:ok,
         %{resource_id: Ecto.UUID.load!(resource), resource_version_id: Ecto.UUID.load!(version)}}

      %{rows: [[_, _, _, _]]} ->
        error(:conflict)

      _ ->
        error(:not_found)
    end
  end

  defp error(code), do: {:error, Error.new(code)}
end
