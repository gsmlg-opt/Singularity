defmodule Singularity.Storage.Postgres.AssetSearchStore do
  @moduledoc false

  @behaviour Singularity.Core.AssetSearchStore

  import Ecto.Query

  alias Singularity.Core.Classification
  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Content.Asset, as: StoredAsset
  alias Singularity.Storage.Schema.Content.AssetMetadata
  alias Singularity.Storage.Schema.Content.AssetSearchDocument
  alias Singularity.Storage.Schema.Content.Resource
  alias Singularity.Storage.Schema.Content.ResourceVersion

  @states [
    :staging,
    :uploaded,
    :verified,
    :available,
    :processing,
    :ready,
    :pending_delete,
    :deleted
  ]
  @media_types ["application/pdf", "image/jpeg", "image/png"]
  @cursor_version 1
  @cursor_mac_label "asset-search-cursor"
  @minimum_cursor_secret_bytes 32
  @search_fields [:vault_id, :query, :state, :media_type, :limit, :cursor]
  @max_query_bytes 1_024
  @max_cursor_bytes 2_048

  @impl true
  def upsert(repo, attrs) when is_map(attrs) do
    with :ok <- validate_upsert_ids(attrs),
         :ok <- preserve_classification(repo, attrs) do
      changeset =
        %AssetSearchDocument{}
        |> AssetSearchDocument.upsert_changeset(attrs)
        |> put_canonical_updated_at(attrs)

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
    with :ok <- UUID.validate(vault_id),
         {:ok, search} <- validated_search(filters),
         {:ok, cursor_secret} <- cursor_secret(),
         {:ok, cursor} <-
           decode_cursor(search.cursor, vault_id, search, cursor_secret) do
      documents =
        vault_id
        |> search_query(search, cursor)
        |> repo.all()

      page(documents, vault_id, search, cursor_secret)
    else
      {:error, %Error{}} = error -> error
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def search(_repo, _filters), do: {:error, Error.new(:invalid)}

  defp validated_search(filters) do
    query = Map.get(filters, :query, "")
    state = Map.get(filters, :state)
    media_type = Map.get(filters, :media_type)
    limit = Map.get(filters, :limit, 20)
    cursor = Map.get(filters, :cursor)

    valid? =
      valid_search_keys?(filters) and valid_query?(query) and state in [nil | @states] and
        media_type in [nil | @media_types] and is_integer(limit) and
        limit in 1..50 and valid_cursor?(cursor)

    if valid? do
      {:ok,
       %{
         query: String.trim(query),
         state: state,
         media_type: media_type,
         limit: limit,
         cursor: cursor
       }}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp valid_search_keys?(filters) do
    Enum.all?(Map.keys(filters), &(&1 in @search_fields))
  end

  defp valid_query?(query) when is_binary(query) do
    byte_size(query) <= @max_query_bytes and String.valid?(query) and
      :binary.match(query, <<0>>) == :nomatch
  end

  defp valid_query?(_query), do: false

  defp valid_cursor?(nil), do: true

  defp valid_cursor?(cursor) when is_binary(cursor) do
    byte_size(cursor) <= @max_cursor_bytes and String.valid?(cursor) and
      String.trim(cursor) != ""
  end

  defp valid_cursor?(_cursor), do: false

  defp search_query(vault_id, search, cursor) do
    query =
      from document in AssetSearchDocument,
        join: asset in StoredAsset,
        on:
          asset.id == document.asset_id and
            asset.resource_version_id == document.resource_version_id and
            asset.vault_id == document.vault_id,
        where: document.vault_id == ^vault_id,
        where:
          fragment(
            "core.current_principal_can_discover_classification(?)",
            document.classification
          )

    query
    |> state_filter(search.state)
    |> media_type_filter(search.media_type)
    |> text_search(search, cursor)
    |> limit(^(search.limit + 1))
  end

  defp state_filter(query, nil), do: query

  defp state_filter(query, state) do
    from [_document, asset] in query, where: asset.state == ^state
  end

  defp media_type_filter(query, nil), do: query

  defp media_type_filter(query, media_type) do
    from [document, _asset] in query,
      where: document.detected_media_type == ^media_type
  end

  defp text_search(query, %{query: ""}, cursor) do
    query = keyset_without_rank(query, cursor)

    from [document, asset] in query,
      order_by: [desc: document.updated_at, asc: document.asset_id],
      select: %{
        asset_id: document.asset_id,
        resource_version_id: document.resource_version_id,
        vault_id: document.vault_id,
        classification: document.classification,
        state: asset.state,
        state_revision: asset.state_revision,
        failure_code: asset.failure_code,
        failure_retryable: asset.retryable?,
        failed_operation: asset.failed_operation,
        failure_attempt: asset.attempt,
        detected_media_type: document.detected_media_type,
        resource_title: document.resource_title,
        original_filename: document.original_filename,
        updated_at: document.updated_at,
        __rank__: nil
      }
  end

  defp text_search(query, %{query: query_text}, cursor) do
    query =
      from [document, _asset] in query,
        where:
          fragment(
            "search_vector @@ websearch_to_tsquery('simple', ?)",
            ^query_text
          )

    query = keyset_with_rank(query, query_text, cursor)

    from [document, asset] in query,
      order_by: [
        desc:
          fragment(
            "ts_rank_cd(search_vector, websearch_to_tsquery('simple', ?))",
            ^query_text
          ),
        desc: document.updated_at,
        asc: document.asset_id
      ],
      select: %{
        asset_id: document.asset_id,
        resource_version_id: document.resource_version_id,
        vault_id: document.vault_id,
        classification: document.classification,
        state: asset.state,
        state_revision: asset.state_revision,
        failure_code: asset.failure_code,
        failure_retryable: asset.retryable?,
        failed_operation: asset.failed_operation,
        failure_attempt: asset.attempt,
        detected_media_type: document.detected_media_type,
        resource_title: document.resource_title,
        original_filename: document.original_filename,
        updated_at: document.updated_at,
        __rank__:
          fragment(
            "ts_rank_cd(search_vector, websearch_to_tsquery('simple', ?))",
            ^query_text
          )
      }
  end

  defp keyset_without_rank(query, nil), do: query

  defp keyset_without_rank(query, cursor) do
    from [document, _asset] in query,
      where:
        document.updated_at < ^cursor.updated_at or
          (document.updated_at == ^cursor.updated_at and
             document.asset_id > ^cursor.asset_id)
  end

  defp keyset_with_rank(query, _query_text, nil), do: query

  defp keyset_with_rank(query, query_text, cursor) do
    from [document, _asset] in query,
      where:
        fragment(
          """
          ts_rank_cd(search_vector, websearch_to_tsquery('simple', ?)) < ?::real
          OR (
            ts_rank_cd(search_vector, websearch_to_tsquery('simple', ?)) = ?::real
            AND ? < ?
          )
          OR (
            ts_rank_cd(search_vector, websearch_to_tsquery('simple', ?)) = ?::real
            AND ? = ?
            AND ? > ?
          )
          """,
          ^query_text,
          ^cursor.rank,
          ^query_text,
          ^cursor.rank,
          document.updated_at,
          ^cursor.updated_at,
          ^query_text,
          ^cursor.rank,
          document.updated_at,
          ^cursor.updated_at,
          document.asset_id,
          ^cursor.dumped_asset_id
        )
  end

  defp page(documents, vault_id, search, cursor_secret) do
    page_documents = Enum.take(documents, search.limit)

    next_cursor =
      if length(documents) > search.limit do
        page_documents
        |> List.last()
        |> encode_cursor(vault_id, search, cursor_secret)
      else
        :done
      end

    {:ok, {Enum.map(page_documents, &document_result/1), next_cursor}}
  end

  defp encode_cursor(document, vault_id, search, cursor_secret) do
    fingerprint = cursor_fingerprint(vault_id, search)

    data = %{
      "v" => @cursor_version,
      "f" => fingerprint,
      "r" => document.__rank__,
      "t" => DateTime.to_iso8601(document.updated_at),
      "a" => document.asset_id
    }

    data
    |> Map.put("h", cursor_integrity(data, cursor_secret))
    |> JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil, _vault_id, _search, _cursor_secret), do: {:ok, nil}

  defp decode_cursor(cursor, vault_id, search, cursor_secret) do
    expected_fingerprint = cursor_fingerprint(vault_id, search)

    with {:ok, encoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, data} <- JSON.decode(encoded),
         true <-
           valid_cursor_envelope?(
             data,
             expected_fingerprint,
             search,
             cursor_secret
           ),
         {:ok, updated_at, 0} <- DateTime.from_iso8601(data["t"]),
         {:ok, dumped_asset_id} <- UUID.dump(data["a"]) do
      {:ok,
       %{
         rank: cursor_rank(data["r"]),
         updated_at: updated_at,
         asset_id: data["a"],
         dumped_asset_id: dumped_asset_id
       }}
    else
      _invalid -> {:error, Error.new(:invalid)}
    end
  rescue
    _error -> {:error, Error.new(:invalid)}
  end

  defp valid_cursor_envelope?(
         data,
         expected_fingerprint,
         search,
         cursor_secret
       )
       when is_map(data) do
    integrity = Map.get(data, "h")

    Enum.sort(Map.keys(data)) == ~w[a f h r t v] and
      data["v"] == @cursor_version and
      data["f"] == expected_fingerprint and
      valid_cursor_rank?(data["r"], search.query) and
      is_binary(data["t"]) and is_binary(data["a"]) and
      is_binary(integrity) and
      secure_compare(
        integrity,
        cursor_integrity(Map.delete(data, "h"), cursor_secret)
      )
  end

  defp valid_cursor_envelope?(_data, _fingerprint, _search, _cursor_secret),
    do: false

  defp valid_cursor_rank?(nil, ""), do: true

  defp valid_cursor_rank?(rank, query)
       when query != "" and is_number(rank) and rank >= 0,
       do: true

  defp valid_cursor_rank?(_rank, _query), do: false

  defp cursor_rank(nil), do: nil
  defp cursor_rank(rank) when is_integer(rank), do: rank * 1.0
  defp cursor_rank(rank), do: rank

  defp cursor_fingerprint(vault_id, search) do
    [
      vault_id,
      search.query,
      search.state && Atom.to_string(search.state),
      search.media_type
    ]
    |> Enum.map(&(&1 || ""))
    |> Enum.intersperse(<<0>>)
    |> digest()
    |> Base.url_encode64(padding: false)
  end

  defp cursor_integrity(data, cursor_secret) do
    :crypto.mac(
      :hmac,
      :sha256,
      cursor_secret,
      [@cursor_mac_label, <<0>>, cursor_payload(data)]
    )
    |> Base.url_encode64(padding: false)
  end

  defp cursor_payload(data) do
    [
      Integer.to_string(data["v"]),
      data["f"],
      cursor_rank_text(data["r"]),
      data["t"],
      data["a"]
    ]
    |> Enum.intersperse(<<0>>)
  end

  defp digest(data), do: :crypto.hash(:sha256, data)

  defp cursor_rank_text(nil), do: ""
  defp cursor_rank_text(rank), do: :erlang.float_to_binary(rank * 1.0, [:compact])

  defp secure_compare(left, right)
       when byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_compare(_left, _right), do: false

  defp cursor_secret do
    case Application.fetch_env(
           :singularity_runtime,
           :audit_fingerprint_secret
         ) do
      {:ok, secret}
      when is_binary(secret) and
             byte_size(secret) >= @minimum_cursor_secret_bytes ->
        {:ok, secret}

      _missing_or_invalid ->
        {:error, Error.new(:invalid)}
    end
  end

  defp put_canonical_updated_at(changeset, %{updated_at: %DateTime{} = updated_at}),
    do: Ecto.Changeset.change(changeset, updated_at: updated_at)

  defp put_canonical_updated_at(changeset, _attrs), do: changeset

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
         {:ok, canonical_classifications} <-
           canonical_classifications(repo, asset_id, resource_version_id, vault_id),
         :ok <- assert_canonical_classifications(canonical_classifications, classification) do
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
        join: resource in Resource,
        on:
          resource.id == resource_version.resource_id and
            resource.vault_id == resource_version.vault_id,
        where:
          asset.id == ^asset_id and
            asset.resource_version_id == ^resource_version_id and
            asset.vault_id == ^vault_id,
        select: [
          resource.classification,
          resource_version.classification,
          asset.classification
        ],
        lock: "FOR SHARE"

    case repo.one(query) do
      nil ->
        {:error, Error.new(:not_found)}

      classifications ->
        with {:ok, metadata_classification} <-
               canonical_metadata_classification(
                 repo,
                 asset_id,
                 resource_version_id,
                 vault_id
               ) do
          {:ok, classifications ++ metadata_classification}
        end
    end
  end

  defp canonical_metadata_classification(
         repo,
         asset_id,
         resource_version_id,
         vault_id
       ) do
    query =
      from metadata in AssetMetadata,
        where:
          metadata.asset_id == ^asset_id and
            metadata.vault_id == ^vault_id,
        select: {metadata.resource_version_id, metadata.classification},
        lock: "FOR SHARE"

    case repo.one(query) do
      nil ->
        {:ok, []}

      {^resource_version_id, classification} ->
        {:ok, [classification]}

      {_other_resource_version_id, _classification} ->
        {:error, Error.new(:integrity_failure)}
    end
  end

  defp assert_canonical_classifications(classifications, projected) do
    Enum.reduce_while(classifications, :ok, fn canonical, :ok ->
      case Classification.assert_not_downgraded(canonical, projected) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
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
    document
    |> Map.take([
      :asset_id,
      :resource_version_id,
      :vault_id,
      :classification,
      :state,
      :state_revision,
      :detected_media_type,
      :resource_title,
      :original_filename,
      :updated_at
    ])
    |> Map.put(:failure, failure_result(document))
  end

  defp failure_result(%{
         failure_code: nil,
         failure_retryable: nil,
         failed_operation: nil
       }),
       do: nil

  defp failure_result(document) do
    %{
      code: document.failure_code,
      retryable: document.failure_retryable,
      operation: document.failed_operation,
      attempt: document.failure_attempt
    }
  end
end
