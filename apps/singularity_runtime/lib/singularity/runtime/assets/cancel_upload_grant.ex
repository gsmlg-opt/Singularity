defmodule Singularity.Runtime.Assets.CancelUploadGrant do
  @moduledoc "Cancels an exact unconsumed browser upload grant."

  alias Singularity.Core.Error
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.AssetRepository

  @spec run(map(), SessionContext.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, grant_id)
      when is_map(runtime) and is_binary(grant_id) do
    with {:ok, adapters} <- adapters(runtime),
         {:ok, grant_id} <- Ecto.UUID.cast(grant_id),
         result <-
           call_adapter(adapters.operation_scope, :with_shared_request, [
             runtime,
             session,
             requirement(),
             fn repo ->
               call_adapter(adapters.assets, :cancel_upload_grant, [
                 repo,
                 %{
                   grant_id: grant_id,
                   session_id: session.session_id,
                   principal_id: session.principal_id,
                   vault_id: session.vault_id
                 }
               ])
             end
           ]) do
      normalize_result(result, grant_id, session.vault_id)
    else
      :error -> {:error, Error.new(:invalid)}
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_runtime, _session, _grant_id),
    do: {:error, Error.new(:invalid)}

  defp requirement do
    %{
      required_capability: "asset.write",
      classification: :private,
      requires_unlocked?: false
    }
  end

  defp adapters(runtime) do
    values = %{
      assets: Map.get(runtime, :assets, AssetRepository),
      operation_scope: Map.get(runtime, :operation_scope, OperationScope)
    }

    if Enum.all?(Map.values(values), &concrete?/1),
      do: {:ok, values},
      else: {:error, Error.new(:invalid)}
  end

  defp normalize_result(
         {:ok,
          %{
            status: status,
            grant_id: grant_id,
            asset_id: asset_id,
            vault_id: vault_id
          } = result},
         expected_grant_id,
         expected_vault_id
       )
       when status in [:cancelled, :in_progress, :retired] and map_size(result) == 4 do
    with {:ok, ^expected_grant_id} <- Ecto.UUID.cast(grant_id),
         {:ok, asset_id} <- Ecto.UUID.cast(asset_id),
         {:ok, ^expected_vault_id} <- Ecto.UUID.cast(vault_id) do
      {:ok,
       %{
         status: status,
         grant_id: grant_id,
         asset_id: asset_id,
         vault_id: vault_id
       }}
    else
      _invalid -> {:error, Error.new(:integrity_failure)}
    end
  end

  defp normalize_result({:error, %Error{}} = error, _grant_id, _vault_id),
    do: error

  defp normalize_result(_invalid, _grant_id, _vault_id),
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end

  defp concrete?(value), do: value not in [nil, false]
end
