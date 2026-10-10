defmodule Singularity.Storage.Postgres.SearchProjectionReconciler do
  @moduledoc false

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.Types
  alias Singularity.Storage.Jobs.EnvelopeCodec
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.Postgres.{KnowledgeError, UUID}

  @spec resource_kind(Ecto.Repo.t(), String.t()) :: {:ok, :note | :document} | {:error, Error.t()}
  def resource_kind(repo, resource_id) do
    with {:ok, resource_id} <- Types.canonical_uuid(%{id: resource_id}, :id),
         {:ok, owner} <- scoped_owner(repo) do
      case SafeSQL.query(
             repo,
             """
             SELECT kind FROM content.resources
             WHERE id=$1 AND vault_id=$2 AND classification='private'
               AND kind IN ('note','document')
             """,
             [Ecto.UUID.dump!(resource_id), Ecto.UUID.dump!(owner)]
           ) do
        {:ok, %{rows: [["note"]]}} -> {:ok, :note}
        {:ok, %{rows: [["document"]]}} -> {:ok, :document}
        {:ok, %{rows: []}} -> {:error, Error.new(:not_found)}
        {:ok, _} -> {:error, Error.new(:integrity_failure)}
        {:error, error} -> {:error, KnowledgeError.from(error)}
      end
    end
  rescue
    error -> {:error, KnowledgeError.from(error)}
  end

  @spec list_resource_ids(Ecto.Repo.t(), String.t() | nil, pos_integer()) ::
          {:ok, [String.t()]} | {:error, Error.t()}
  def list_resource_ids(repo, after_id, limit) when is_integer(limit) and limit in 1..100 do
    with :ok <- validate_after_id(after_id),
         {:ok, owner} <- scoped_owner(repo) do
      case SafeSQL.query(
             repo,
             """
             SELECT id FROM content.resources
             WHERE vault_id=$1 AND classification='private' AND kind IN ('note','document')
               AND ($2::uuid IS NULL OR id>$2)
             ORDER BY id ASC LIMIT $3
             """,
             [Ecto.UUID.dump!(owner), if(after_id, do: Ecto.UUID.dump!(after_id)), limit]
           ) do
        {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)}
        {:error, error} -> {:error, KnowledgeError.from(error)}
      end
    end
  rescue
    error -> {:error, KnowledgeError.from(error)}
  end

  def list_resource_ids(_, _, _), do: {:error, Error.new(:invalid)}

  defp validate_after_id(nil), do: :ok

  defp validate_after_id(id) do
    case Types.canonical_uuid(%{id: id}, :id) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp scoped_owner(repo) do
    with true <- is_atom(repo) and repo.in_transaction?(),
         {:ok, %{rows: [[principal, owner]]}} <-
           SafeSQL.query(repo, """
           SELECT current_setting('singularity.principal_id',true),
                  current_setting('singularity.vault_id',true)
           """),
         {:ok, _principal} <- Types.canonical_uuid(%{principal: principal}, :principal),
         {:ok, owner} <- Types.canonical_uuid(%{owner: owner}, :owner) do
      {:ok, owner}
    else
      {:error, error} -> {:error, KnowledgeError.from(error)}
      _ -> {:error, Error.new(:invalid)}
    end
  end

  @spec reconcile(Ecto.Repo.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def reconcile(repo, resource_id) do
    execute(repo, resource_id, "SELECT content.reconcile_search_resource($1)")
  end

  @spec reconcile_note(Ecto.Repo.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def reconcile_note(repo, resource_id) do
    execute(repo, resource_id, "SELECT content.reconcile_note_search_resource($1)")
  end

  @spec reconcile_document(Ecto.Repo.t(), JobEnvelope.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def reconcile_document(repo, %JobEnvelope{job_type: "document_projection"} = envelope) do
    with {:ok, _} <- EnvelopeCodec.encode(envelope),
         true <- is_atom(repo) and repo.in_transaction?(),
         :ok <- envelope_scope(repo, envelope) do
      parameters = [
        Ecto.UUID.dump!(envelope.payload["resource_id"]),
        Ecto.UUID.dump!(envelope.payload["resource_version_id"]),
        Ecto.UUID.dump!(envelope.job_id),
        envelope.expected_entity_revision,
        envelope.principal_authorization_epoch,
        envelope.vault_authorization_epoch
      ]

      case SafeSQL.query(
             repo,
             "SELECT content.reconcile_document_search_worker($1,$2,$3,$4,$5,$6)",
             parameters
           ) do
        {:ok, %{rows: [[count]]}} when is_integer(count) and count >= 0 -> {:ok, count}
        {:ok, _} -> {:error, Error.new(:integrity_failure)}
        {:error, error} -> {:error, KnowledgeError.from(error)}
      end
    else
      {:error, %Error{}} = error -> error
      _ -> {:error, Error.new(:invalid)}
    end
  rescue
    error -> {:error, KnowledgeError.from(error)}
  end

  def reconcile_document(_repo, _envelope), do: {:error, Error.new(:invalid)}

  defp envelope_scope(repo, envelope) do
    case SafeSQL.query(
           repo,
           """
           SELECT current_setting('singularity.principal_id',true),
                  current_setting('singularity.vault_id',true)
           """,
           []
         ) do
      {:ok, %{rows: [[principal, owner]]}}
      when principal == envelope.principal_id and owner == envelope.vault_id ->
        :ok

      {:error, error} ->
        {:error, KnowledgeError.from(error)}

      _ ->
        {:error, Error.new(:forbidden)}
    end
  end

  defp execute(repo, resource_id, statement) do
    with :ok <- UUID.validate(resource_id),
         true <- is_atom(repo) and repo.in_transaction?(),
         {:ok, resource} <- UUID.dump(resource_id) do
      case SafeSQL.query(repo, statement, [resource]) do
        {:ok, %{rows: [[count]]}} when is_integer(count) and count >= 0 -> {:ok, count}
        {:ok, %{rows: [[-1]]}} -> {:error, Error.new(:not_found)}
        {:ok, _unexpected} -> {:error, Error.new(:integrity_failure)}
        {:error, error} -> {:error, KnowledgeError.from(error)}
      end
    else
      {:error, %Error{}} = error -> error
      _ -> {:error, Error.new(:invalid)}
    end
  rescue
    error -> {:error, KnowledgeError.from(error)}
  end
end
