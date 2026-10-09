defmodule Singularity.Storage.Jobs.WorkerScope do
  @moduledoc false

  alias Singularity.Core.Error
  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock
  alias Singularity.Storage.WorkerRepo

  @document_checkout_timeout 300_000
  @statement_timeout 15_000
  @settings_options [query_type: :text, timeout: @statement_timeout]

  @spec run(Singularity.Core.JobEnvelope.t(), (map() -> term())) :: term()
  def run(envelope, fun) when is_function(fun, 1) do
    with_vault_lock(envelope, fn repo_handle ->
      AuthorizationLock.with_shared(
        repo_handle,
        envelope.principal_id,
        envelope.vault_id,
        fn _locked_repo ->
          fun.(%{
            repo_handle: repo_handle,
            lock_mode: lock_mode(envelope),
            transact: fn options, phase ->
              ScopedRepo.transact(repo_handle, envelope, options, phase)
            end
          })
        end
      )
    end)
  end

  defp with_vault_lock(%{job_type: "backup"} = envelope, fun),
    do: VaultLock.with_exclusive(WorkerRepo, envelope.vault_id, fun)

  defp with_vault_lock(%{job_type: "document_extract"} = envelope, fun) do
    if WorkerRepo.checked_out?() do
      {:error, Error.new(:invalid)}
    else
      WorkerRepo.checkout(
        fn ->
          saved = statement_timeout!()
          limit = if saved == 0, do: @statement_timeout, else: min(saved, @statement_timeout)

          # Arm restoration before a setting change with uncertain acknowledgement.
          try do
            set_statement_timeout!(limit)
            VaultLock.with_shared_checked_out(WorkerRepo, envelope.vault_id, fun)
          after
            restore_statement_timeout!(saved)
          end
        end,
        timeout: @document_checkout_timeout
      )
    end
  end

  defp with_vault_lock(envelope, fun),
    do: VaultLock.with_shared(WorkerRepo, envelope.vault_id, fun)

  defp statement_timeout! do
    %{rows: [[value]], num_rows: 1} =
      SafeSQL.query!(
        WorkerRepo,
        "SELECT setting FROM pg_catalog.pg_settings WHERE name='statement_timeout'",
        [],
        @settings_options
      )

    case Integer.parse(value) do
      {milliseconds, ""} when milliseconds >= 0 and milliseconds <= 2_147_483_647 ->
        milliseconds

      _ ->
        raise ArgumentError, "invalid Document worker statement timeout"
    end
  end

  defp set_statement_timeout!(milliseconds) do
    %{rows: [[value]], num_rows: 1} =
      SafeSQL.query!(
        WorkerRepo,
        "SELECT set_config('statement_timeout','#{milliseconds}ms',false)",
        [],
        @settings_options
      )

    true = is_binary(value)
    ^milliseconds = statement_timeout!()
    :ok
  end

  defp restore_statement_timeout!(saved) do
    set_statement_timeout!(saved)
  rescue
    _ -> discard_owned_connection()
  catch
    _, _ -> discard_owned_connection()
  end

  defp discard_owned_connection do
    # Borrower death disconnects its holder; never check in uncertain session state.
    Process.exit(self(), :kill)
  end

  defp lock_mode(%{job_type: "backup"}), do: :exclusive
  defp lock_mode(_envelope), do: :shared
end
