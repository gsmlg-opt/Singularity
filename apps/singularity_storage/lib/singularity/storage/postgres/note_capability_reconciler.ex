defmodule Singularity.Storage.Postgres.NoteCapabilityReconciler do
  @moduledoc false

  alias Singularity.Storage.SafeSQL

  @spec reconcile(Ecto.Repo.t()) :: :ok | {:error, Exception.t() | :unexpected_result}
  def reconcile(repo) do
    case SafeSQL.query(repo, "SELECT core.reconcile_note_capabilities()", []) do
      {:ok, %{rows: [[affected]]}} when is_integer(affected) -> :ok
      {:ok, _unexpected} -> {:error, :unexpected_result}
      {:error, error} -> {:error, error}
    end
  end
end
