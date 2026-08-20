defmodule Singularity.Storage.Postgres.NoteCapabilityReconciler do
  @moduledoc false

  alias Singularity.Core.Error
  alias Singularity.Storage.SafeSQL

  @spec reconcile(Ecto.Repo.t()) :: :ok | {:error, Error.t()}
  def reconcile(repo) do
    case SafeSQL.query(repo, "SELECT core.reconcile_note_capabilities()", []) do
      {:ok, %{rows: [[affected]]}} when is_integer(affected) -> :ok
      _failure -> unavailable()
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
