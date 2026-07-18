defmodule Singularity.Core.AssetSearchStore do
  @moduledoc "Port for the rebuildable vault-scoped asset metadata search projection."

  alias Singularity.Core.Error

  @type context :: term()
  @type cursor :: :done | String.t()

  @callback upsert(context(), map()) :: :ok | {:error, Error.t()}
  @callback delete(context(), map()) :: :ok | {:error, Error.t()}
  @callback search(context(), map()) ::
              {:ok, {[map()], cursor()}} | {:error, Error.t()}
end
