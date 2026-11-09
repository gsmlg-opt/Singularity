defmodule Singularity.Retrieval.NoteLexicalSearch do
  @moduledoc """
  Validates private note lexical search pages from the injected core port.

  A valid internal summary has exactly these atom keys: `:resource_id`,
  `:resource_version_id`, `:vault_id`, `:classification`, `:title`, `:revision`,
  `:updated_at`, `:deleted?`, and `:open_conflict_count`.
  """

  alias Singularity.Core.Error
  alias Singularity.Core.Types
  alias Singularity.Retrieval.NoteSearchPage
  alias Singularity.Retrieval.NoteSearchQuery

  @summary_fields [
    :resource_id,
    :resource_version_id,
    :vault_id,
    :classification,
    :title,
    :revision,
    :updated_at,
    :deleted?,
    :open_conflict_count
  ]

  @spec search(module(), term(), NoteSearchQuery.t()) ::
          {:ok, NoteSearchPage.t()} | {:error, Error.t()}
  def search(store, context, %NoteSearchQuery{} = query)
      when is_atom(store) and not is_nil(store) do
    case store.search(context, query) do
      {:ok, page} when is_map(page) ->
        with :ok <- validate_page(page, query),
             {:ok, result} <- NoteSearchPage.new(page.items, page.next_cursor) do
          {:ok, result}
        else
          _invalid -> storage_unavailable()
        end

      {:error, %Error{}} = error ->
        error

      _invalid ->
        storage_unavailable()
    end
  rescue
    _error -> storage_unavailable()
  catch
    _kind, _reason -> storage_unavailable()
  end

  def search(_store, _context, _query), do: {:error, Error.new(:invalid)}

  defp validate_page(%{items: items, next_cursor: cursor} = page, query) when is_list(items) do
    if Map.keys(page) |> MapSet.new() == MapSet.new([:items, :next_cursor]) and
         length(items) <= query.limit and
         Enum.all?(items, &valid_item?(&1, query.vault_id)) and
         valid_cursor?(cursor) do
      :ok
    else
      :error
    end
  end

  defp validate_page(_page, _query), do: :error

  defp valid_item?(item, vault_id) when is_map(item) do
    Map.keys(item) |> MapSet.new() == MapSet.new(@summary_fields) and
      valid_uuid?(item, :resource_id) and
      valid_uuid?(item, :resource_version_id) and
      valid_uuid?(item, :vault_id) and
      item.vault_id == vault_id and
      item.classification == :private and
      valid_title?(item.title) and
      non_neg_integer?(item.revision) and
      valid_datetime?(item.updated_at) and
      item.deleted? == false and
      non_neg_integer?(item.open_conflict_count)
  end

  defp valid_item?(_item, _vault_id), do: false

  defp valid_uuid?(attrs, key), do: match?({:ok, _}, Types.canonical_uuid(attrs, key))

  defp valid_title?(title) when is_binary(title),
    do: byte_size(title) <= 255 and String.valid?(title) and String.trim(title) != ""

  defp valid_title?(_title), do: false

  defp non_neg_integer?(value), do: is_integer(value) and value >= 0

  defp valid_datetime?(value),
    do: match?({:ok, _}, Types.utc_datetime(%{updated_at: value}, :updated_at))

  defp valid_cursor?(:done), do: true

  defp valid_cursor?(cursor) when is_binary(cursor) do
    byte_size(cursor) <= 2_048 and String.valid?(cursor) and
      :binary.match(cursor, <<0>>) == :nomatch and String.trim(cursor) != ""
  end

  defp valid_cursor?(_cursor), do: false

  defp storage_unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
