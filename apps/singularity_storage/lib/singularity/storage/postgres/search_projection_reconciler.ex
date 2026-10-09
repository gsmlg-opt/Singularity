defmodule Singularity.Storage.Postgres.SearchProjectionReconciler do
  @moduledoc false

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Storage.Jobs.EnvelopeCodec
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.Postgres.{KnowledgeError, UUID}

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
