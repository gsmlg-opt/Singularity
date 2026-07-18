defmodule Singularity.Storage.Postgres.AssetSearchStore do
  @moduledoc false

  @behaviour Singularity.Core.AssetSearchStore

  import Ecto.Query

  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Content.Asset, as: StoredAsset
  alias Singularity.Storage.Schema.Content.AssetSearchDocument
  alias Singularity.Storage.Schema.Content.ResourceVersion

  @impl true
  def upsert(repo, attrs) when is_map(attrs) do
    with :ok <- validate_upsert_ids(attrs),
         :ok <- preserve_classification(repo, attrs) do
      changeset =
        AssetSearchDocument.upsert_changeset(%AssetSearchDocument{}, attrs)

      case repo.insert(changeset,
             on_conflict: monotonic_conflict_query(),
             conflict_target: [:asset_id],
             allow_stale: true
           ) do
        {:ok, _document} -> :ok
        {:error, %Ecto.Changeset{}} -> {:error, Error.new(:invalid)}
      end
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def upsert(_repo, _attrs), do: {:error, Error.new(:invalid)}

  @impl true
  def delete(repo, %{asset_id: asset_id, vault_id: vault_id}) do
    with :ok <- UUID.validate([asset_id, vault_id]) do
      from(document in AssetSearchDocument,
        where: document.asset_id == ^asset_id and document.vault_id == ^vault_id
      )
      |> repo.delete_all()

      :ok
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def delete(_repo, _attrs), do: {:error, Error.new(:invalid)}

  @impl true
  def search(repo, %{vault_id: vault_id} = filters) do
    query_text = Map.get(filters, :query, "")
    limit = Map.get(filters, :limit, 20)

    with :ok <- UUID.validate(vault_id),
         true <- is_binary(query_text) and is_integer(limit) and limit in 1..100 do
      query =
        from document in AssetSearchDocument,
          where: document.vault_id == ^vault_id,
          order_by: [desc: document.updated_at, asc: document.asset_id],
          limit: ^limit

      query =
        if String.trim(query_text) == "" do
          query
        else
          from document in query,
            where:
              fragment(
                "search_vector @@ websearch_to_tsquery('simple', ?)",
                ^query_text
              )
        end

      documents =
        repo.all(query)
        |> Enum.map(&document_result/1)

      {:ok, {documents, :done}}
    else
      false -> {:error, Error.new(:invalid)}
      {:error, %Error{}} = error -> error
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def search(_repo, _filters), do: {:error, Error.new(:invalid)}

  defp validate_upsert_ids(%{
         asset_id: asset_id,
         resource_version_id: resource_version_id,
         vault_id: vault_id
       }) do
    UUID.validate([asset_id, resource_version_id, vault_id])
  end

  defp validate_upsert_ids(_attrs), do: {:error, Error.new(:invalid)}

  defp preserve_classification(
         repo,
         %{
           asset_id: asset_id,
           resource_version_id: resource_version_id,
           vault_id: vault_id,
           classification: classification
         }
       ) do
    with {:ok, classification} <- Classification.new(classification),
         {:ok, {asset_classification, resource_version_classification}} <-
           canonical_classifications(repo, asset_id, resource_version_id, vault_id),
         :ok <-
           Classification.assert_not_downgraded(
             asset_classification,
             classification
           ),
         :ok <-
           Classification.assert_not_downgraded(
             resource_version_classification,
             classification
           ) do
      preserve_projection_classification(repo, asset_id, classification)
    end
  end

  defp preserve_classification(_repo, _attrs), do: {:error, Error.new(:invalid)}

  defp canonical_classifications(repo, asset_id, resource_version_id, vault_id) do
    query =
      from asset in StoredAsset,
        join: resource_version in ResourceVersion,
        on:
          resource_version.id == asset.resource_version_id and
            resource_version.vault_id == asset.vault_id,
        where:
          asset.id == ^asset_id and
            asset.resource_version_id == ^resource_version_id and
            asset.vault_id == ^vault_id,
        select: {asset.classification, resource_version.classification},
        lock: "FOR SHARE"

    case repo.one(query) do
      nil -> {:error, Error.new(:not_found)}
      classifications -> {:ok, classifications}
    end
  end

  defp preserve_projection_classification(repo, asset_id, classification) do
    case repo.get(AssetSearchDocument, asset_id) do
      nil ->
        :ok

      %{classification: persisted} ->
        Classification.assert_not_downgraded(persisted, classification)
    end
  end

  defp monotonic_conflict_query do
    from document in AssetSearchDocument,
      where:
        fragment(
          """
          CASE EXCLUDED.classification
            WHEN 'private' THEN 0
            WHEN 'sensitive' THEN 1
            WHEN 'restricted' THEN 2
          END >=
          CASE ?
            WHEN 'private' THEN 0
            WHEN 'sensitive' THEN 1
            WHEN 'restricted' THEN 2
          END
          """,
          document.classification
        ),
      update: [
        set: [
          resource_version_id: fragment("EXCLUDED.resource_version_id"),
          vault_id: fragment("EXCLUDED.vault_id"),
          classification: fragment("EXCLUDED.classification"),
          state: fragment("EXCLUDED.state"),
          detected_media_type: fragment("EXCLUDED.detected_media_type"),
          resource_title: fragment("EXCLUDED.resource_title"),
          original_filename: fragment("EXCLUDED.original_filename"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
  end

  defp document_result(document) do
    Map.take(document, [
      :asset_id,
      :resource_version_id,
      :vault_id,
      :classification,
      :state,
      :detected_media_type,
      :resource_title,
      :original_filename,
      :updated_at
    ])
  end
end
