defmodule Singularity.Storage.Postgres.KnowledgeSearchStore do
  @moduledoc false

  alias Singularity.Core.Error
  alias Singularity.Storage.SafeSQL
  alias Singularity.Storage.Postgres.{KnowledgeError, KnowledgeSearchCursor}

  @key_fields ~w(rank source_inserted_at resource_id resource_version_id ordinal entry_id)a

  @spec search(module(), map()) :: {:ok, map()} | {:error, Error.t()}
  def search(repo, query) do
    token = if is_map(query), do: Map.get(query, :cursor), else: nil

    with {:ok, secret} <- cursor_secret(),
         {:ok, cursor} <- KnowledgeSearchCursor.decode(token, query, secret),
         true <- repo.in_transaction?(),
         {:ok, _settings} <- fixed_settings(repo),
         {:ok, context} <- request_context(repo),
         true <- matching_context?(context, query.owner_scope_id),
         {:ok, %{rows: rows}} <-
           SafeSQL.query(repo, statement(query.q), parameters(query, cursor)) do
      page(rows, query, secret)
    else
      false -> invalid()
      {:error, error} -> {:error, KnowledgeError.from(error)}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, KnowledgeError.from(error)}
  end

  defp cursor_secret do
    case Application.fetch_env(:singularity_runtime, :audit_fingerprint_secret) do
      {:ok, secret} when is_binary(secret) and byte_size(secret) >= 32 -> {:ok, secret}
      _ -> invalid()
    end
  end

  defp fixed_settings(repo) do
    SafeSQL.query(repo, """
    SELECT set_config('statement_timeout', '5000ms', true),
           set_config('pg_trgm.similarity_threshold', '0.3', true)
    """)
  end

  defp request_context(repo) do
    SafeSQL.query(repo, """
    SELECT current_setting('singularity.principal_id', true),
           current_setting('singularity.vault_id', true)
    """)
  end

  defp matching_context?(%{rows: [[principal, owner]]}, owner)
       when is_binary(principal) and principal != "",
       do: true

  defp matching_context?(_, _), do: false

  defp parameters(query, cursor) do
    [
      Ecto.UUID.dump!(query.owner_scope_id),
      query.q,
      Atom.to_string(query.kind),
      literal_pattern(query.q),
      Enum.map(query.tag_ids, &Ecto.UUID.dump!/1),
      not is_nil(cursor),
      cursor_value(cursor, :rank),
      cursor_value(cursor, :source_inserted_at),
      cursor_uuid(cursor, :resource_id),
      cursor_uuid(cursor, :resource_version_id),
      cursor_value(cursor, :ordinal),
      cursor_value(cursor, :entry_id),
      query.limit + 1
    ]
  end

  defp cursor_value(nil, _), do: nil
  defp cursor_value(cursor, field), do: Map.fetch!(cursor, field)
  defp cursor_uuid(nil, _), do: nil
  defp cursor_uuid(cursor, field), do: cursor |> Map.fetch!(field) |> Ecto.UUID.dump!()

  defp literal_pattern(q) do
    escaped =
      q
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%" <> escaped <> "%"
  end

  defp statement(q) do
    """
    WITH input AS (
      SELECT $1::uuid AS owner, $2::text AS q, $3::text AS kind,
             $4::text AS pattern, $5::uuid[] AS tags
    ), scored AS MATERIALIZED (
      SELECT entry.vault_id, entry.classification, entry.kind,
             entry.resource_id, entry.resource_version_id, entry.fragment_id,
             entry.entry_id, entry.ordinal, entry.title, left(entry.body, 160) AS snippet,
             entry.locator, version.inserted_at AS source_inserted_at,
             #{rank_expression(q)} AS rank
      FROM content.search_entries AS entry
      CROSS JOIN input
      JOIN content.resources AS resource
        ON resource.id = entry.resource_id
       AND resource.vault_id = entry.vault_id
       AND resource.classification = entry.classification
       AND resource.kind = entry.kind
       AND resource.current_version_id = entry.resource_version_id
       AND resource.deleted_at IS NULL
      JOIN content.resource_versions AS version
        ON version.id = entry.resource_version_id
       AND version.resource_id = entry.resource_id
       AND version.vault_id = entry.vault_id
       AND version.classification = entry.classification
      LEFT JOIN content.note_versions AS note
        ON entry.kind = 'note'
       AND note.resource_version_id = entry.note_resource_version_id
       AND note.resource_version_id = entry.resource_version_id
       AND note.resource_id = entry.resource_id
       AND note.vault_id = entry.vault_id
       AND note.classification = entry.classification
      LEFT JOIN content.document_versions AS document
        ON entry.kind = 'document'
       AND document.resource_version_id = entry.resource_version_id
       AND document.resource_id = entry.resource_id
       AND document.vault_id = entry.vault_id
       AND document.classification = entry.classification
       AND document.state = 'ready'
      LEFT JOIN content.document_fragments AS fragment
        ON entry.kind = 'document'
       AND fragment.id = entry.fragment_id
       AND fragment.resource_id = document.resource_id
       AND fragment.resource_version_id = document.resource_version_id
       AND fragment.vault_id = document.vault_id
       AND fragment.classification = document.classification
       AND fragment.ordinal = entry.ordinal
      WHERE entry.vault_id = input.owner AND entry.classification = 'private'
        AND (input.kind = 'all' OR entry.kind = input.kind)
        AND (
          (entry.kind = 'note' AND note.resource_version_id IS NOT NULL)
          OR (entry.kind = 'document' AND fragment.id IS NOT NULL)
        )
        AND NOT EXISTS (
          SELECT FROM unnest(input.tags) AS requested(tag_id)
          WHERE NOT EXISTS (
            SELECT FROM content.resource_tags AS membership
            JOIN content.tags AS tag
              ON tag.id = membership.tag_id AND tag.vault_id = membership.vault_id
             AND tag.classification = membership.classification
            WHERE membership.resource_id = entry.resource_id
              AND membership.vault_id = input.owner AND membership.classification = 'private'
              AND tag.vault_id = input.owner AND tag.classification = 'private'
              AND tag.id = requested.tag_id
          )
        )
        #{text_predicate(q)}
    )
    SELECT vault_id, classification, kind, resource_id, resource_version_id, fragment_id,
           entry_id, ordinal, title, snippet, locator, source_inserted_at, rank
    FROM scored
    WHERE NOT $6::boolean OR rank < $7::bigint
       OR (rank = $7::bigint AND source_inserted_at < $8::timestamptz)
       OR (rank = $7::bigint AND source_inserted_at = $8::timestamptz
           AND (resource_id, resource_version_id, ordinal, entry_id COLLATE "C")
             > ($9::uuid, $10::uuid, $11::bigint, $12::text COLLATE "C"))
    ORDER BY rank DESC, source_inserted_at DESC, resource_id ASC, resource_version_id ASC,
             ordinal ASC, entry_id COLLATE "C" ASC
    LIMIT $13::integer
    """
  end

  defp rank_expression(""), do: "0::bigint"

  defp rank_expression(_) do
    """
    4 * CASE WHEN entry.search_vector @@ plainto_tsquery('simple', input.q)
          THEN floor(1000000 * ts_rank_cd(entry.search_vector, plainto_tsquery('simple', input.q), 32))::bigint
          ELSE 0 END
    + 2 * CASE WHEN char_length(input.q) >= 3 AND entry.title OPERATOR(search_extensions.%) input.q
          THEN floor(1000000 * search_extensions.similarity(entry.title, input.q))::bigint
          ELSE 0 END
    + CASE WHEN entry.title ILIKE input.pattern ESCAPE chr(92)
             OR entry.body ILIKE input.pattern ESCAPE chr(92)
          THEN 1000000 ELSE 0 END
    """
  end

  defp text_predicate(""), do: ""

  defp text_predicate(_) do
    """
    AND (entry.search_vector @@ plainto_tsquery('simple', input.q)
      OR entry.title ILIKE input.pattern ESCAPE chr(92)
      OR entry.body ILIKE input.pattern ESCAPE chr(92)
      OR (char_length(input.q) >= 3 AND entry.title OPERATOR(search_extensions.%) input.q))
    """
  end

  defp page(rows, query, secret) do
    items = rows |> Enum.take(query.limit) |> Enum.map(&item/1)

    with {:ok, cursor} <- next_cursor(items, length(rows) > query.limit, query, secret) do
      {:ok, %{items: items, next_cursor: cursor}}
    end
  end

  defp next_cursor(_, false, _, _), do: {:ok, :done}

  defp next_cursor(items, true, query, secret) do
    items |> List.last() |> Map.take(@key_fields) |> KnowledgeSearchCursor.encode(query, secret)
  end

  defp item([
         owner,
         "private",
         kind,
         resource,
         version,
         fragment,
         entry,
         ordinal,
         title,
         snippet,
         locator,
         timestamp,
         rank
       ]) do
    %{
      owner_scope_id: Ecto.UUID.load!(owner),
      classification: :private,
      kind: kind(kind),
      resource_id: Ecto.UUID.load!(resource),
      resource_version_id: Ecto.UUID.load!(version),
      fragment_id: fragment,
      entry_id: entry,
      ordinal: ordinal,
      title: title,
      snippet: snippet,
      locator: locator,
      source_inserted_at: timestamp,
      rank: rank
    }
  end

  defp kind("note"), do: :note
  defp kind("document"), do: :document
  defp invalid, do: {:error, Error.new(:invalid)}
end
