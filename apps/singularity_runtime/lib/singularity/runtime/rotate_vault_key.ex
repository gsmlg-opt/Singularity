defmodule Singularity.Runtime.RotateVaultKey do
  @moduledoc "Pending-to-active vault-key rotation orchestration."

  @spec rotate(%{repository: module()}, map()) ::
          {:ok, map()} | {:error, term()}
  def rotate(%{repository: repository}, context) when is_atom(repository) do
    with {:ok, pending} <- repository.create_pending_generation(context),
         {:ok, wrappers} <- repository.rewrap_all_children(context, pending),
         :ok <- repository.verify_all_wrappers(context, wrappers),
         {:ok, active} <- repository.activate_generation(context, pending.id) do
      {:ok, active}
    else
      {:error, reason} ->
        repository.abandon_pending_generation(context)
        {:error, reason}
    end
  end
end
