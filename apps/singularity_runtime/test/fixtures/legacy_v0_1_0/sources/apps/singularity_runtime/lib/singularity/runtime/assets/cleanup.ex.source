defmodule Singularity.Runtime.Assets.Cleanup do
  @moduledoc "Completes logical deletion independently of physical object retention."

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Runtime.Authorize

  @spec run(map(), JobEnvelope.t()) :: {:ok, map()} | {:error, Error.t()}
  def run(
        context,
        %JobEnvelope{
          job_type: "asset_cleanup",
          required_capability: "asset.write"
        } = envelope
      )
      when is_map(context) do
    with {:ok, adapters} <- adapters(context) do
      adapters.transact.([], fn repo ->
        with :ok <-
               call_adapter(adapters.authorize, :check_job, [
                 adapters.authorization,
                 repo,
                 envelope
               ]) do
          call_adapter(adapters.deletions, :complete_logical_delete, [
            repo,
            envelope
          ])
        end
      end)
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_context, _envelope), do: {:error, Error.new(:invalid)}

  defp adapters(context) do
    deletions =
      Map.get(context, :asset_deletions) ||
        Map.get(context, :assets)

    authorization = Map.get(context, :authorization)
    authorize = Map.get(context, :authorize, Authorize)
    transact = Map.get(context, :transact)

    if deletions not in [nil, false] and
         authorization not in [nil, false] and
         authorize not in [nil, false] and
         is_function(transact, 2) do
      {:ok,
       %{
         deletions: deletions,
         authorization: authorization,
         authorize: authorize,
         transact: transact
       }}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end
end
