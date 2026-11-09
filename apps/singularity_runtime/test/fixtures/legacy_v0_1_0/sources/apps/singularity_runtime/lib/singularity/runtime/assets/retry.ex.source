defmodule Singularity.Runtime.Assets.Retry do
  @moduledoc "Requests an idempotent retry for the current retryable asset failure."

  alias Singularity.Core.Asset
  alias Singularity.Core.Error
  alias Singularity.Runtime.Assets.Status
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.AssetRepository

  @spec run(
          map(),
          SessionContext.t(),
          String.t(),
          non_neg_integer()
        ) ::
          {:ok, :accepted | :stale} | {:error, Error.t()}
  def run(
        runtime,
        %SessionContext{} = session,
        asset_id,
        expected_state_revision
      )
      when is_map(runtime) and is_integer(expected_state_revision) and
             expected_state_revision >= 0 do
    with {:ok, adapters} <- adapters(runtime),
         {:ok, %Asset{} = asset} <-
           Status.run(runtime, session, asset_id),
         :ok <- retryable(asset) do
      call_adapter(adapters.operation_scope, :with_shared_request, [
        runtime,
        session,
        requirement(asset.classification),
        fn repo ->
          call_adapter(adapters.assets, :retry, [
            repo,
            %{
              asset_id: asset_id,
              vault_id: session.vault_id,
              principal_id: session.principal_id,
              classification: asset.classification,
              expected_state_revision: expected_state_revision
            }
          ])
        end
      ])
      |> normalize_result()
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_runtime, _session, _asset_id, _expected_state_revision),
    do: {:error, Error.new(:invalid)}

  defp retryable(%Asset{
         failure_code: failure_code,
         retryable?: true,
         failed_operation: failed_operation
       })
       when not is_nil(failure_code) and is_binary(failed_operation) and
              failed_operation != "",
       do: :ok

  defp retryable(_asset), do: {:error, Error.new(:conflict)}

  defp requirement(classification) do
    %{
      required_capability: "asset.write",
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

  defp normalize_result({:ok, result})
       when result in [:accepted, :stale],
       do: {:ok, result}

  defp normalize_result({:error, %Error{}} = error), do: error

  defp normalize_result(_invalid),
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
