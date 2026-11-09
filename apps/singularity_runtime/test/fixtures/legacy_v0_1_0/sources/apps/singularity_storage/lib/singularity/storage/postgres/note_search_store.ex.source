defmodule Singularity.Storage.Postgres.NoteSearchStore do
  @moduledoc false

  @behaviour Singularity.Core.NoteSearchStore

  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Content.NoteConflict
  alias Singularity.Storage.Schema.Content.NoteSearchDocument
  alias Singularity.Storage.Schema.Content.Resource
  alias Singularity.Storage.Schema.Content.ResourceVersion

  @cursor_version 1
  @cursor_mac_label "note-search-cursor"
  @minimum_cursor_secret_bytes 32
  @search_fields [:vault_id, :q, :limit, :cursor, :classification]
  @max_query_bytes 1_024
  @max_cursor_bytes 2_048

  @upsert_fields [
    :resource_id,
    :resource_version_id,
    :vault_id,
    :classification,
    :title,
    :markdown,
    :head_inserted_at
  ]
  @replace_fields [
    :resource_version_id,
    :vault_id,
    :classification,
    :title,
    :markdown,
    :head_inserted_at,
    :updated_at
  ]

  @impl true
  def upsert(repo, attrs) when is_map(attrs) do
    with :ok <- exact_fields(attrs, @upsert_fields),
         :ok <- UUID.validate([attrs.resource_id, attrs.resource_version_id, attrs.vault_id]),
         true <- attrs.classification == :private do
      changeset = NoteSearchDocument.upsert_changeset(%NoteSearchDocument{}, attrs)

      case repo.insert(changeset,
             on_conflict: {:replace, @replace_fields},
             conflict_target: [:resource_id]
           ) do
        {:ok, _document} -> :ok
        {:error, %Ecto.Changeset{}} -> {:error, Error.new(:invalid)}
      end
    else
      false -> invalid()
      {:error, %Error{}} = error -> error
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.CastError] ->
      invalid()

    error in [Ecto.ConstraintError, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def upsert(_repo, _attrs), do: invalid()

  @impl true
  def delete(repo, %{resource_id: resource_id, vault_id: vault_id} = selector)
      when map_size(selector) == 2 do
    with :ok <- UUID.validate([resource_id, vault_id]) do
      case repo.delete_all(
             from(document in NoteSearchDocument,
               where: document.resource_id == ^resource_id and document.vault_id == ^vault_id
             )
           ) do
        {count, _rows} when count in [0, 1] -> :ok
        {_count, _rows} -> {:error, Error.new(:integrity_failure)}
      end
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.CastError] ->
      invalid()

    error in [Ecto.ConstraintError, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def delete(_repo, _selector), do: invalid()

  @impl true
  def search(repo, query) do
    with {:ok, search} <- validate_search(query),
         {:ok, cursor_secret} <- cursor_secret(),
         {:ok, cursor} <- decode_cursor(search, cursor_secret) do
      documents =
        search
        |> search_query(cursor)
        |> repo.all()

      page(documents, search, cursor_secret)
    else
      {:error, %Error{}} = error -> error
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.CastError] ->
      invalid()

    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  defp exact_fields(attrs, fields) do
    if MapSet.new(Map.keys(attrs)) == MapSet.new(fields), do: :ok, else: invalid()
  end

  defp validate_search(query) when is_struct(query),
    do: query |> Map.from_struct() |> validate_search()

  defp validate_search(query) when is_map(query) do
    with :ok <- exact_fields(query, @search_fields),
         :ok <- UUID.validate(query.vault_id),
         true <- String.downcase(query.vault_id) == query.vault_id,
         true <- query.classification == :private,
         true <- valid_query?(query.q),
         true <- is_integer(query.limit) and query.limit in 1..50,
         true <- valid_cursor?(query.cursor) do
      {:ok, %{query | q: String.trim(query.q)}}
    else
      false -> invalid()
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_search(_query), do: invalid()

  defp valid_query?(query) when is_binary(query) do
    byte_size(query) <= @max_query_bytes and String.valid?(query) and
      :binary.match(query, <<0>>) == :nomatch
  end

  defp valid_query?(_query), do: false

  defp valid_cursor?(nil), do: true

  defp valid_cursor?(cursor) when is_binary(cursor) do
    byte_size(cursor) <= @max_cursor_bytes and String.valid?(cursor) and
      :binary.match(cursor, <<0>>) == :nomatch and String.trim(cursor) != ""
  end

  defp valid_cursor?(_cursor), do: false

  defp search_query(search, cursor) do
    search.vault_id
    |> base_query()
    |> text_search(search, cursor)
    |> limit(^(search.limit + 1))
  end

  defp base_query(vault_id) do
    from document in NoteSearchDocument,
      join: resource in Resource,
      on:
        resource.id == document.resource_id and
          resource.vault_id == document.vault_id and
          resource.classification == document.classification and
          resource.current_version_id == document.resource_version_id,
      join: version in ResourceVersion,
      on:
        version.id == document.resource_version_id and
          version.resource_id == document.resource_id and
          version.vault_id == document.vault_id and
          version.classification == document.classification,
      left_join: conflict in NoteConflict,
      on:
        conflict.resource_id == document.resource_id and
          conflict.vault_id == document.vault_id and
          conflict.classification == document.classification and
          conflict.state == :open,
      where:
        document.vault_id == ^vault_id and
          document.classification == :private and
          resource.kind == :note and
          is_nil(resource.deleted_at),
      group_by: [
        document.resource_id,
        document.resource_version_id,
        document.vault_id,
        document.classification,
        document.title,
        document.head_inserted_at,
        version.revision
      ]
  end

  defp text_search(query, %{q: ""}, cursor) do
    query = keyset_without_rank(query, cursor)

    from [document, _resource, version, conflict] in query,
      order_by: [desc: document.head_inserted_at, asc: document.resource_id],
      select: %{
        resource_id: document.resource_id,
        resource_version_id: document.resource_version_id,
        vault_id: document.vault_id,
        classification: document.classification,
        title: document.title,
        revision: version.revision,
        updated_at: document.head_inserted_at,
        deleted?: false,
        open_conflict_count: count(conflict.id),
        __rank__: nil,
        __head_inserted_at__: document.head_inserted_at
      }
  end

  defp text_search(query, %{q: query_text}, cursor) do
    query =
      from [document, _resource, _version, _conflict] in query,
        where: fragment("search_vector @@ websearch_to_tsquery('simple', ?)", ^query_text)

    query = keyset_with_rank(query, query_text, cursor)

    from [document, _resource, version, conflict] in query,
      order_by: [
        desc:
          fragment("ts_rank_cd(search_vector, websearch_to_tsquery('simple', ?))", ^query_text),
        desc: document.head_inserted_at,
        asc: document.resource_id
      ],
      select: %{
        resource_id: document.resource_id,
        resource_version_id: document.resource_version_id,
        vault_id: document.vault_id,
        classification: document.classification,
        title: document.title,
        revision: version.revision,
        updated_at: document.head_inserted_at,
        deleted?: false,
        open_conflict_count: count(conflict.id),
        __rank__:
          fragment("ts_rank_cd(search_vector, websearch_to_tsquery('simple', ?))", ^query_text),
        __head_inserted_at__: document.head_inserted_at
      }
  end

  defp keyset_without_rank(query, nil), do: query

  defp keyset_without_rank(query, cursor) do
    from [document, _resource, _version, _conflict] in query,
      where:
        document.head_inserted_at < ^cursor.head_inserted_at or
          (document.head_inserted_at == ^cursor.head_inserted_at and
             document.resource_id > ^cursor.dumped_resource_id)
  end

  defp keyset_with_rank(query, _query_text, nil), do: query

  defp keyset_with_rank(query, query_text, cursor) do
    from [document, _resource, _version, _conflict] in query,
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
          document.head_inserted_at,
          ^cursor.head_inserted_at,
          ^query_text,
          ^cursor.rank,
          document.head_inserted_at,
          ^cursor.head_inserted_at,
          document.resource_id,
          ^cursor.dumped_resource_id
        )
  end

  defp page(documents, search, cursor_secret) do
    page_documents = Enum.take(documents, search.limit)

    next_cursor =
      if length(documents) > search.limit do
        page_documents
        |> List.last()
        |> encode_cursor(search, cursor_secret)
      else
        :done
      end

    {:ok,
     %{
       items: Enum.map(page_documents, &summary/1),
       next_cursor: next_cursor
     }}
  end

  defp summary(document) do
    Map.drop(document, [:__rank__, :__head_inserted_at__])
  end

  defp encode_cursor(document, search, cursor_secret) do
    data = %{
      "v" => @cursor_version,
      "f" => cursor_fingerprint(search),
      "r" => document.__rank__,
      "t" => DateTime.to_iso8601(document.__head_inserted_at__),
      "i" => document.resource_id
    }

    data
    |> Map.put("h", cursor_integrity(data, cursor_secret))
    |> JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(%{cursor: nil}, _cursor_secret), do: {:ok, nil}

  defp decode_cursor(search, cursor_secret) do
    with {:ok, encoded} <- Base.url_decode64(search.cursor, padding: false),
         {:ok, data} <- JSON.decode(encoded),
         true <- valid_cursor_envelope?(data, search, cursor_secret),
         {:ok, head_inserted_at, 0} <- DateTime.from_iso8601(data["t"]),
         {:ok, dumped_resource_id} <- UUID.dump(data["i"]) do
      {:ok,
       %{
         rank: cursor_rank(data["r"]),
         head_inserted_at: head_inserted_at,
         resource_id: data["i"],
         dumped_resource_id: dumped_resource_id
       }}
    else
      _invalid -> invalid()
    end
  rescue
    _error -> invalid()
  end

  defp valid_cursor_envelope?(data, search, cursor_secret) when is_map(data) do
    integrity = Map.get(data, "h")

    Enum.sort(Map.keys(data)) == ~w[f h i r t v] and
      data["v"] == @cursor_version and
      data["f"] == cursor_fingerprint(search) and
      valid_cursor_rank?(data["r"], search.q) and
      is_binary(data["t"]) and is_binary(data["i"]) and is_binary(integrity) and
      secure_compare(integrity, cursor_integrity(Map.delete(data, "h"), cursor_secret))
  end

  defp valid_cursor_envelope?(_data, _search, _cursor_secret), do: false

  defp valid_cursor_rank?(nil, ""), do: true

  defp valid_cursor_rank?(rank, query) when query != "" and is_number(rank) and rank >= 0,
    do: true

  defp valid_cursor_rank?(_rank, _query), do: false

  defp cursor_rank(nil), do: nil
  defp cursor_rank(rank) when is_integer(rank), do: rank * 1.0
  defp cursor_rank(rank), do: rank

  defp cursor_fingerprint(search) do
    [search.vault_id, search.q, Atom.to_string(search.classification)]
    |> Enum.intersperse(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
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
      data["i"]
    ]
    |> Enum.intersperse(<<0>>)
  end

  defp cursor_rank_text(nil), do: ""
  defp cursor_rank_text(rank), do: :erlang.float_to_binary(rank * 1.0, [:compact])

  defp secure_compare(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_compare(_left, _right), do: false

  defp cursor_secret do
    case Application.fetch_env(:singularity_runtime, :audit_fingerprint_secret) do
      {:ok, secret}
      when is_binary(secret) and byte_size(secret) >= @minimum_cursor_secret_bytes ->
        {:ok, secret}

      _invalid ->
        invalid()
    end
  end

  defp database_error(%Ecto.ConstraintError{}), do: Error.new(:invalid)

  defp database_error(%Postgrex.Error{postgres: %{code: code}})
       when code in [
              :integrity_constraint_violation,
              :restrict_violation,
              :not_null_violation,
              :foreign_key_violation,
              :unique_violation,
              :check_violation,
              :exclusion_violation
            ],
       do: Error.new(:invalid)

  defp database_error(_error), do: Error.new(:storage_unavailable, retryable?: true)
  defp invalid, do: {:error, Error.new(:invalid)}
end
