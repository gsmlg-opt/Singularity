defmodule Singularity.Storage.Postgres.KnowledgeSearchCursor do
  @moduledoc false

  alias Singularity.Core.{Error, KnowledgeEncoding, KnowledgeValidation, SearchPolicy, Types}

  @filter_domain "knowledge-search-filter:v1"
  @cursor_domain "knowledge-search-cursor:v1"
  @query_fields [
    :owner_scope_id,
    :classification,
    :q,
    :kind,
    :tag_ids,
    :limit,
    :cursor,
    :policy_version
  ]
  @key_fields [
    :rank,
    :source_inserted_at,
    :resource_id,
    :resource_version_id,
    :ordinal,
    :entry_id
  ]
  @payload_fields ~w[e f h i j o r t v]
  @datetime_fields DateTime.__struct__() |> Map.keys() |> Enum.sort()
  @document_entry ~r/\Adocument:[0-9a-f]{64}\z/

  @spec encode(term(), term(), term()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(last_key, query, secret) do
    with true <- valid_secret?(secret),
         true <- valid_query?(query),
         true <- valid_key?(last_key, query) do
      data = %{
        "v" => 1,
        "f" => fingerprint(query, secret),
        "r" => last_key.rank,
        "t" => DateTime.to_iso8601(last_key.source_inserted_at),
        "i" => last_key.resource_id,
        "j" => last_key.resource_version_id,
        "o" => last_key.ordinal,
        "e" => last_key.entry_id
      }

      token =
        data
        |> Map.put("h", integrity(data, secret))
        |> JSON.encode!()
        |> Base.url_encode64(padding: false)

      if valid_cursor?(token), do: {:ok, token}, else: invalid()
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  @spec decode(term(), term(), term()) :: {:ok, map() | nil} | {:error, Error.t()}
  def decode(token, query, secret) do
    with true <- valid_secret?(secret),
         true <- valid_query?(query),
         true <- valid_cursor?(token) do
      decode_validated(token, query, secret)
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  defp decode_validated(nil, _query, _secret), do: {:ok, nil}

  defp decode_validated(token, query, secret) do
    with {:ok, encoded} <- Base.url_decode64(token, padding: false),
         true <- Base.url_encode64(encoded, padding: false) == token,
         {:ok, data} <- JSON.decode(encoded),
         true <- exact_fields?(data, @payload_fields),
         # This version accepts only producer canonical bytes, rejecting duplicate JSON keys.
         true <- JSON.encode!(data) == encoded,
         1 <- data["v"],
         true <- is_integer(data["v"]),
         {:ok, timestamp, 0} <- DateTime.from_iso8601(data["t"]),
         true <- DateTime.to_iso8601(timestamp) == data["t"],
         last_key = %{
           rank: data["r"],
           source_inserted_at: timestamp,
           resource_id: data["i"],
           resource_version_id: data["j"],
           ordinal: data["o"],
           entry_id: data["e"]
         },
         true <- valid_key?(last_key, query),
         true <- secure_compare(data["f"], fingerprint(query, secret)),
         true <- secure_compare(data["h"], integrity(data, secret)) do
      {:ok, last_key}
    else
      _ -> invalid()
    end
  end

  defp valid_query?(query) do
    policy = SearchPolicy.current()

    with true <- exact_fields?(query, @query_fields),
         {:ok, _owner} <- Types.canonical_uuid(query, :owner_scope_id),
         :private <- query.classification,
         1 <- query.policy_version,
         true <- is_integer(query.policy_version),
         {:ok, q} <- KnowledgeValidation.string(query.q, policy.query_bytes),
         true <- q == String.trim(q),
         true <- query.kind in [:all, :note, :document],
         true <- valid_tags?(query.tag_ids, policy.tag_count),
         {:ok, limit} <- KnowledgeValidation.integer(query.limit, 1),
         true <- limit <= policy.page_limit,
         true <- valid_cursor?(query.cursor) do
      true
    else
      _ -> false
    end
  end

  defp valid_tags?(tags, maximum) when is_list(tags) and length(tags) <= maximum do
    tags == Enum.sort(Enum.uniq(tags)) and
      Enum.all?(tags, &match?({:ok, _}, Types.canonical_uuid(%{id: &1}, :id)))
  end

  defp valid_tags?(_, _), do: false

  defp valid_key?(last_key, query) do
    with true <- exact_fields?(last_key, @key_fields),
         {:ok, rank} <- KnowledgeValidation.integer(last_key.rank),
         true <- rank <= SearchPolicy.current().max_rank,
         true <- query.q != "" or rank == 0,
         {:ok, _resource} <- Types.canonical_uuid(last_key, :resource_id),
         {:ok, _version} <- Types.canonical_uuid(last_key, :resource_version_id),
         {:ok, _ordinal} <- KnowledgeValidation.integer(last_key.ordinal),
         true <- valid_timestamp?(last_key),
         true <- valid_entry?(last_key, query.kind) do
      true
    else
      _ -> false
    end
  end

  defp valid_timestamp?(last_key) do
    with {:ok, timestamp} <- KnowledgeValidation.utc_datetime(last_key, :source_inserted_at),
         true <- Enum.sort(Map.keys(timestamp)) == @datetime_fields,
         "UTC" <- timestamp.zone_abbr,
         {:ok, decoded, 0} <- timestamp |> DateTime.to_iso8601() |> DateTime.from_iso8601() do
      # A forged microsecond precision must not silently change the ordering tuple.
      decoded === timestamp
    else
      _ -> false
    end
  end

  defp valid_entry?(
         %{entry_id: "note:" <> version, resource_version_id: version, ordinal: 0},
         kind
       ),
       do: kind in [:all, :note]

  defp valid_entry?(%{entry_id: entry_id}, kind) when is_binary(entry_id) do
    kind in [:all, :document] and Regex.match?(@document_entry, entry_id)
  end

  defp valid_entry?(_, _), do: false

  defp fingerprint(query, secret) do
    fields = [
      query.owner_scope_id,
      "private",
      query.q,
      Atom.to_string(query.kind),
      Integer.to_string(query.policy_version),
      Integer.to_string(length(query.tag_ids))
    ]

    mac(@filter_domain, fields ++ query.tag_ids, secret)
  end

  defp integrity(data, secret) do
    mac(
      @cursor_domain,
      [
        Integer.to_string(data["v"]),
        data["f"],
        Integer.to_string(data["r"]),
        data["t"],
        data["i"],
        data["j"],
        Integer.to_string(data["o"]),
        data["e"]
      ],
      secret
    )
  end

  defp mac(domain, fields, secret) do
    :crypto.mac(:hmac, :sha256, secret, [
      domain,
      <<0>>,
      Enum.map(fields, &KnowledgeEncoding.frame/1)
    ])
    |> Base.url_encode64(padding: false)
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_compare(_, _), do: false

  defp exact_fields?(map, fields) when is_map(map) and not is_struct(map),
    do: map_size(map) == length(fields) and Enum.all?(fields, &Map.has_key?(map, &1))

  defp exact_fields?(_, _), do: false

  defp valid_cursor?(nil), do: true

  defp valid_cursor?(cursor) do
    with {:ok, value} <- KnowledgeValidation.string(cursor, SearchPolicy.current().cursor_bytes),
         true <- String.trim(value) != "" do
      true
    else
      _ -> false
    end
  end

  defp valid_secret?(secret), do: is_binary(secret) and byte_size(secret) >= 32
  defp invalid, do: {:error, Error.new(:invalid)}
end
