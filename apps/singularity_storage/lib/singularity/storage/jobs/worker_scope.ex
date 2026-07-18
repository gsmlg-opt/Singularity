defmodule Singularity.Storage.Jobs.WorkerScope do
  @moduledoc false

  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock
  alias Singularity.Storage.WorkerRepo

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

  defp with_vault_lock(envelope, fun),
    do: VaultLock.with_shared(WorkerRepo, envelope.vault_id, fun)

  defp lock_mode(%{job_type: "backup"}), do: :exclusive
  defp lock_mode(_envelope), do: :shared
end
