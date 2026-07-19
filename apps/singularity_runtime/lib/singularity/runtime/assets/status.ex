defmodule Singularity.Runtime.Assets.Status do
  @moduledoc "Returns one authorized lifecycle and orthogonal failure snapshot."

  alias Singularity.Core.Asset
  alias Singularity.Core.Error
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.AssetRepository

  @spec run(map(), SessionContext.t(), String.t()) ::
          {:ok, Asset.t()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, asset_id)
      when is_map(runtime) do
    with true <- valid_uuid?(asset_id),
         {:ok, adapters} <- adapters(runtime),
         {:ok, %Asset{} = asset} <-
           load(
             adapters,
             runtime,
             session,
             asset_id,
             :private
           ),
         :ok <- validate_asset(asset, session, asset_id) do
      if asset.classification == :private do
        {:ok, asset}
      else
        with {:ok, %Asset{} = reauthorized} <-
               load(
                 adapters,
                 runtime,
                 session,
                 asset_id,
                 asset.classification
               ),
             :ok <- validate_asset(reauthorized, session, asset_id),
             true <- reauthorized == asset do
          {:ok, reauthorized}
        else
          false -> {:error, Error.new(:conflict)}
          {:error, %Error{}} = error -> error
          _invalid -> {:error, Error.new(:integrity_failure)}
        end
      end
    else
      false -> {:error, Error.new(:invalid)}
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:integrity_failure)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_runtime, _session, _asset_id),
    do: {:error, Error.new(:invalid)}

  defp load(adapters, runtime, session, asset_id, classification) do
    call_adapter(adapters.operation_scope, :with_read_request, [
      runtime,
      session,
      requirement(classification),
      fn repo ->
        call_adapter(adapters.assets, :status, [repo, asset_id])
      end
    ])
  end

  defp validate_asset(
         %Asset{
           asset_id: asset_id,
           vault_id: vault_id,
           classification: classification
         },
         %{vault_id: vault_id},
         asset_id
       )
       when classification in [:private, :sensitive, :restricted],
       do: :ok

  defp validate_asset(_asset, _session, _asset_id),
    do: {:error, Error.new(:integrity_failure)}

  defp requirement(classification) do
    %{
      required_capability: "asset.read",
      classification: classification,
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

  defp valid_uuid?(value),
    do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

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
