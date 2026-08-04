defmodule Singularity.Retrieval.AssetMetadataSearch do
  @moduledoc "Validates and orchestrates the injected core asset search store."

  alias Singularity.Core.Error
  alias Singularity.Retrieval.AssetSearchPage
  alias Singularity.Retrieval.AssetSearchQuery

  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @spec search(module(), term(), AssetSearchQuery.t()) ::
          {:ok, AssetSearchPage.t()} | {:error, Error.t()}
  def search(store, store_context, %AssetSearchQuery{} = query)
      when is_atom(store) and not is_nil(store) do
    filters = %{
      vault_id: query.vault_id,
      query: query.q,
      state: query.state,
      media_type: query.media_type,
      limit: query.limit,
      cursor: query.cursor
    }

    case store.search(store_context, filters) do
      {:ok, {items, cursor}} when is_list(items) ->
        with :ok <- validate_items(items, query),
             {:ok, page} <- AssetSearchPage.new(items, cursor) do
          {:ok, page}
        end

      {:error, %Error{}} = error ->
        error

      _invalid ->
        integrity_failure()
    end
  rescue
    _error -> integrity_failure()
  catch
    _kind, _reason -> integrity_failure()
  end

  def search(_store, _store_context, _query),
    do: {:error, Error.new(:invalid)}

  @spec fetch(module(), term(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def fetch(store, store_context, vault_id, asset_id)
      when is_atom(store) and not is_nil(store) do
    with :ok <- validate_uuid(vault_id),
         :ok <- validate_uuid(asset_id) do
      case store.fetch(store_context, %{
             vault_id: vault_id,
             asset_id: asset_id
           }) do
        {:ok, item} when is_map(item) ->
          if valid_fetched_item?(item, vault_id, asset_id),
            do: {:ok, item},
            else: integrity_failure()

        {:error, %Error{}} = error ->
          error

        _invalid ->
          integrity_failure()
      end
    end
  rescue
    _error -> integrity_failure()
  catch
    _kind, _reason -> integrity_failure()
  end

  def fetch(_store, _store_context, _vault_id, _asset_id),
    do: {:error, Error.new(:invalid)}

  defp validate_items(items, query) do
    valid? =
      length(items) <= query.limit and
        Enum.all?(items, &valid_item?(&1, query.vault_id))

    if valid?, do: :ok, else: integrity_failure()
  end

  defp valid_item?(item, vault_id) when is_map(item) do
    item[:vault_id] == vault_id and
      nonblank?(item[:asset_id]) and
      nonblank?(item[:resource_version_id])
  end

  defp valid_item?(_item, _vault_id), do: false

  defp valid_fetched_item?(item, vault_id, asset_id) do
    item[:vault_id] == vault_id and item[:asset_id] == asset_id and
      valid_uuid?(item[:resource_version_id])
  end

  defp validate_uuid(value) do
    if valid_uuid?(value), do: :ok, else: {:error, Error.new(:invalid)}
  end

  defp valid_uuid?(value) when is_binary(value) and byte_size(value) == 36,
    do: Regex.match?(@uuid_pattern, value)

  defp valid_uuid?(_value), do: false

  defp nonblank?(value),
    do: is_binary(value) and String.trim(value) != ""

  defp integrity_failure,
    do: {:error, Error.new(:integrity_failure)}
end
