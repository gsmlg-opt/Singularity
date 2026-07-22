defmodule Singularity.Retrieval.AssetMetadataSearch do
  @moduledoc "Validates and orchestrates the injected core asset search store."

  alias Singularity.Core.Error
  alias Singularity.Retrieval.AssetSearchPage
  alias Singularity.Retrieval.AssetSearchQuery

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

  defp nonblank?(value),
    do: is_binary(value) and String.trim(value) != ""

  defp integrity_failure,
    do: {:error, Error.new(:integrity_failure)}
end
