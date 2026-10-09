defmodule Singularity.Storage.Postgres.SearchProjectionReconciler do
  @moduledoc false

  alias Singularity.Core.Error
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
