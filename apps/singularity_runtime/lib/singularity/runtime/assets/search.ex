defmodule Singularity.Runtime.Assets.Search do
  @moduledoc "Runs vault-bound asset metadata search inside an authorized read scope."

  alias Singularity.Core.Error
  alias Singularity.Core.Types
  alias Singularity.Retrieval.AssetMetadataSearch
  alias Singularity.Retrieval.AssetSearchQuery
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext
  alias Singularity.Storage.Postgres.AssetSearchStore

  @spec run(map(), SessionContext.t(), map() | keyword()) ::
          {:ok, Singularity.Retrieval.AssetSearchPage.t()} | {:error, Error.t()}
  def run(runtime, %SessionContext{} = session, params) when is_map(runtime) do
    with {:ok, adapters} <- adapters(runtime),
         {:ok, params} <- bind_vault(params, session.vault_id),
         {:ok, query} <- AssetSearchQuery.new(params) do
      call_adapter(adapters.operation_scope, :with_read_request, [
        runtime,
        session,
        requirement(session),
        fn repo ->
          call_adapter(adapters.asset_search, :search, [
            adapters.asset_search_store,
            repo,
            query
          ])
        end
      ])
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_runtime, _session, _params),
    do: {:error, Error.new(:invalid)}

  @spec fetch(map(), SessionContext.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def fetch(runtime, %SessionContext{} = session, asset_id)
      when is_map(runtime) and is_binary(asset_id) do
    with {:ok, ^asset_id} <- Ecto.UUID.cast(asset_id),
         {:ok, adapters} <- adapters(runtime) do
      call_adapter(adapters.operation_scope, :with_read_request, [
        runtime,
        session,
        requirement(session),
        fn repo ->
          call_adapter(adapters.asset_search, :fetch, [
            adapters.asset_search_store,
            repo,
            session.vault_id,
            asset_id
          ])
        end
      ])
    else
      :error -> {:error, Error.new(:invalid)}
      {:ok, _other_asset_id} -> {:error, Error.new(:invalid)}
      {:error, %Error{}} = error -> error
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def fetch(_runtime, _session, _asset_id),
    do: {:error, Error.new(:invalid)}

  defp bind_vault(params, vault_id) do
    with {:ok, params} <- Types.attrs(params),
         :ok <- validate_supplied_vault(params, vault_id) do
      {:ok,
       params
       |> Map.delete("vault_id")
       |> Map.put(:vault_id, vault_id)}
    end
  end

  defp validate_supplied_vault(params, vault_id) do
    supplied =
      [:vault_id, "vault_id"]
      |> Enum.flat_map(fn key ->
        case Map.fetch(params, key) do
          {:ok, value} -> [value]
          :error -> []
        end
      end)

    if Enum.all?(supplied, &(&1 == vault_id)),
      do: :ok,
      else: {:error, Error.new(:invalid)}
  end

  defp requirement(session) do
    %{
      vault_id: session.vault_id,
      required_capability: "asset.read",
      classification: :private,
      requires_unlocked?: true
    }
  end

  defp adapters(runtime) do
    values = %{
      asset_search: Map.get(runtime, :asset_search, AssetMetadataSearch),
      asset_search_store: Map.get(runtime, :asset_search_store, AssetSearchStore),
      operation_scope: Map.get(runtime, :operation_scope, OperationScope)
    }

    if Enum.all?(Map.values(values), &concrete?/1) do
      {:ok, values}
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

  defp concrete?(value), do: value not in [nil, false]
end
