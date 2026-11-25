defmodule Singularity.Repo.Migrations.IndexKnowledgeSearch do
  use Ecto.Migration

  def change do
    # Long RFCs can exceed the 1 MiB tsvector limit. Store lexemes without
    # positions and use the same text-search parser on those documents.
    execute """
            CREATE FUNCTION knowledge_search_lexemes(document text) RETURNS text[]
            LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
            BEGIN
              RETURN tsvector_to_array(to_tsvector('pg_catalog.simple', document));
            EXCEPTION WHEN program_limit_exceeded THEN
              RETURN ARRAY(
                SELECT DISTINCT term
                FROM ts_debug('pg_catalog.simple', document) AS token
                CROSS JOIN LATERAL unnest(token.lexemes) AS terms(term)
                WHERE octet_length(term) <= 2047
              );
            END;
            $$
            """,
            "DROP FUNCTION knowledge_search_lexemes(text)"

    alter table(:items) do
      add :search_terms, {:array, :text},
        generated: """
        ALWAYS AS (knowledge_search_lexemes(
          translate(title || ' ' || external_id, '/', ' ') || ' ' ||
          coalesce(attributes->>'number', '') || ' ' ||
          coalesce(summary, '') || ' ' || coalesce(content, '') || ' ' ||
          coalesce(readme, '') || ' ' || coalesce(instruction, '')
        )) STORED
        """
    end

    create index(:items, [:search_terms], using: :gin)
  end
end
