defmodule Singularity.Storage.Migrations.CreateGuardedSearchCandidates do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    CREATE FUNCTION content.search_candidate_ids(
      requested_q text, requested_kind text, requested_tag_ids uuid[]
    ) RETURNS TABLE(entry_id text)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER PARALLEL UNSAFE
    SET search_path = pg_catalog, content, core, identity, pg_temp
    SET pg_trgm.similarity_threshold = '0.3'
    AS $function$
    DECLARE principal uuid; owner uuid; capabilities text[]; pattern text;
    BEGIN
      IF requested_q IS NULL OR requested_q = ''
         OR pg_catalog.octet_length(pg_catalog.convert_to(requested_q,'UTF8')) > 1024
         OR requested_kind IS NULL OR requested_kind NOT IN ('note','document','all')
         OR requested_tag_ids IS NULL THEN
        RAISE EXCEPTION 'search candidates input is invalid' USING ERRCODE='23514';
      END IF;
      IF COALESCE(pg_catalog.array_ndims(requested_tag_ids),1) <> 1
         OR pg_catalog.cardinality(requested_tag_ids) > 20 THEN
        RAISE EXCEPTION 'search candidates input is invalid' USING ERRCODE='23514';
      END IF;
      IF pg_catalog.array_position(requested_tag_ids,NULL::uuid) IS NOT NULL THEN
        RAISE EXCEPTION 'search candidates input is invalid' USING ERRCODE='23514';
      END IF;
      IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'search candidates are not authorized' USING ERRCODE='42501';
      END IF;
      BEGIN
        principal := NULLIF(pg_catalog.current_setting('singularity.principal_id',true),'')::uuid;
        owner := NULLIF(pg_catalog.current_setting('singularity.vault_id',true),'')::uuid;
      EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'search candidates are not authorized' USING ERRCODE='42501';
      END;
      IF principal IS NULL OR owner IS NULL THEN
        RAISE EXCEPTION 'search candidates are not authorized' USING ERRCODE='42501';
      END IF;
      PERFORM pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended(
        'singularity:authorization:' || principal::text || ':' || owner::text,0));
      SELECT auth.capabilities INTO capabilities
      FROM core.live_principal_authorization() AS auth
      WHERE auth.principal_id=principal AND auth.vault_id=owner AND auth.principal_kind='owner'
        AND auth.principal_revoked_at IS NULL AND auth.membership_revoked_at IS NULL
        AND auth.clearance IN ('private','sensitive','restricted');
      IF NOT FOUND THEN
        RAISE EXCEPTION 'search candidates are not authorized' USING ERRCODE='42501';
      END IF;
      IF (requested_kind IN ('note','all') AND NOT ('note.read'=ANY(capabilities)))
         OR (requested_kind IN ('document','all') AND NOT ('asset.read'=ANY(capabilities))) THEN
        RAISE EXCEPTION 'search candidates are not authorized' USING ERRCODE='42501';
      END IF;
      pattern := '%' || pg_catalog.replace(pg_catalog.replace(pg_catalog.replace(
        requested_q,pg_catalog.chr(92),pg_catalog.chr(92)||pg_catalog.chr(92)),
        '%',pg_catalog.chr(92)||'%'),'_',pg_catalog.chr(92)||'_') || '%';
      RETURN QUERY
      /* singularity:search_candidate_ids:v1 */
      WITH matched AS (
        SELECT e.entry_id FROM content.search_entries AS e
        WHERE e.vault_id=owner AND e.classification='private'
          AND (requested_kind='all' OR e.kind=requested_kind)
          AND e.search_vector @@ pg_catalog.plainto_tsquery('simple'::regconfig,requested_q)
        UNION
        SELECT e.entry_id FROM content.search_entries AS e
        WHERE e.vault_id=owner AND e.classification='private'
          AND (requested_kind='all' OR e.kind=requested_kind)
          AND e.title ILIKE pattern ESCAPE pg_catalog.chr(92)
        UNION
        SELECT e.entry_id FROM content.search_entries AS e
        WHERE e.vault_id=owner AND e.classification='private'
          AND (requested_kind='all' OR e.kind=requested_kind)
          AND e.body ILIKE pattern ESCAPE pg_catalog.chr(92)
        UNION
        SELECT e.entry_id FROM content.search_entries AS e
        WHERE e.vault_id=owner AND e.classification='private'
          AND (requested_kind='all' OR e.kind=requested_kind)
          AND pg_catalog.char_length(requested_q)>=3
          AND e.title OPERATOR(search_extensions.%) requested_q
      )
      SELECT e.entry_id
      FROM matched AS candidate
      JOIN content.search_entries AS e ON e.entry_id=candidate.entry_id
      JOIN content.resources AS resource
        ON resource.id=e.resource_id AND resource.vault_id=e.vault_id
       AND resource.classification=e.classification AND resource.kind=e.kind
       AND resource.current_version_id=e.resource_version_id AND resource.deleted_at IS NULL
      JOIN content.resource_versions AS version
        ON version.id=e.resource_version_id AND version.resource_id=e.resource_id
       AND version.vault_id=e.vault_id AND version.classification=e.classification
      LEFT JOIN content.note_versions AS note
        ON e.kind='note' AND note.resource_version_id=e.note_resource_version_id
       AND note.resource_version_id=e.resource_version_id AND note.resource_id=e.resource_id
       AND note.vault_id=e.vault_id AND note.classification=e.classification
      LEFT JOIN content.document_versions AS document
        ON e.kind='document' AND document.resource_version_id=e.resource_version_id
       AND document.resource_id=e.resource_id AND document.vault_id=e.vault_id
       AND document.classification=e.classification AND document.state='ready'
      LEFT JOIN content.document_fragments AS fragment
        ON e.kind='document' AND fragment.id=e.fragment_id AND fragment.resource_id=document.resource_id
       AND fragment.resource_version_id=document.resource_version_id AND fragment.vault_id=document.vault_id
       AND fragment.classification=document.classification AND fragment.ordinal=e.ordinal
      WHERE e.vault_id=owner AND e.classification='private'
        AND (requested_kind='all' OR e.kind=requested_kind)
        AND ((e.kind='note' AND note.resource_version_id IS NOT NULL)
          OR (e.kind='document' AND fragment.id IS NOT NULL))
        AND NOT EXISTS (
          SELECT FROM pg_catalog.unnest(requested_tag_ids) AS requested(tag_id)
          WHERE NOT EXISTS (
            SELECT FROM content.resource_tags AS membership
            JOIN content.tags AS tag ON tag.id=membership.tag_id AND tag.vault_id=membership.vault_id
             AND tag.classification=membership.classification
            WHERE membership.resource_id=e.resource_id AND membership.vault_id=owner
              AND membership.classification='private' AND tag.vault_id=owner
              AND tag.classification='private' AND tag.id=requested.tag_id
          )
        );
    END
    $function$;
    """)

    execute("""
    ALTER FUNCTION content.search_candidate_ids(text,text,uuid[]) OWNER TO singularity_table_owner
    """)

    execute("""
    REVOKE ALL ON FUNCTION content.search_candidate_ids(text,text,uuid[])
      FROM PUBLIC,singularity_web,singularity_worker,singularity_dispatcher,singularity_pre_auth
    """)

    execute(
      "GRANT EXECUTE ON FUNCTION content.search_candidate_ids(text,text,uuid[]) TO singularity_web"
    )

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "Guarded search candidates migration is forward-only")
end
