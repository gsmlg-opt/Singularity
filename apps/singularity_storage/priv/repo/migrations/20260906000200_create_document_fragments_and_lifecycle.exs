defmodule Singularity.Storage.Migrations.CreateDocumentFragmentsAndLifecycle do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")
    create_encoding()
    create_fragments()
    create_state_constraints()
    create_guards()
    create_lifecycle()
    create_policies()
    execute("SET LOCAL ROLE NONE")
  end

  def down, do: raise(Ecto.MigrationError, "Document lifecycle migration is forward-only")

  defp create_encoding do
    execute("""
    CREATE FUNCTION content.document_frame(value bytea) RETURNS bytea
    LANGUAGE sql IMMUTABLE STRICT SET search_path = pg_catalog
    AS $function$ SELECT int8send(octet_length(value)::bigint) || value $function$
    """)

    execute("""
    CREATE FUNCTION content.document_json_integer(value jsonb, minimum bigint)
    RETURNS bigint LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog
    AS $function$
    DECLARE decimal_value text;
    BEGIN
      IF jsonb_typeof(value) IS DISTINCT FROM 'number' THEN RETURN NULL; END IF;
      decimal_value := value #>> '{}';
      IF decimal_value !~ '^(0|[1-9][0-9]*)$' OR length(decimal_value) > 19 THEN
        RETURN NULL;
      END IF;
      IF decimal_value::numeric > 9223372036854775807
         OR decimal_value::numeric < minimum THEN RETURN NULL; END IF;
      RETURN decimal_value::bigint;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.document_canonical_locator(value jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, content
    AS $function$
    DECLARE
      kind text;
      allowed text[];
      first_key text;
      last_key text;
      minimum bigint;
      first_value bigint;
      last_value bigint;
      heading jsonb;
      normalized text;
      headings jsonb := '[]'::jsonb;
    BEGIN
      IF jsonb_typeof(value) IS DISTINCT FROM 'object'
         OR content.document_json_integer(value->'version', 1) IS DISTINCT FROM 1::bigint
         OR jsonb_typeof(value->'kind') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      kind := value->>'kind';
      CASE kind
        WHEN 'pdf' THEN
          allowed := ARRAY['version','kind','page','start_char','end_char'];
          IF content.document_json_integer(value->'page', 1) IS NULL THEN
            RAISE EXCEPTION 'invalid Document extraction input'
              USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
          END IF;
          first_key := 'start_char'; last_key := 'end_char'; minimum := 0;
        WHEN 'markdown' THEN
          allowed := ARRAY['version','kind','heading_path','start_line','end_line'];
          IF jsonb_typeof(value->'heading_path') IS DISTINCT FROM 'array' THEN
            RAISE EXCEPTION 'invalid Document extraction input'
              USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
          END IF;
          IF jsonb_array_length(value->'heading_path') > 64 THEN
            RAISE EXCEPTION 'invalid Document extraction input'
              USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
          END IF;
          FOR heading IN SELECT jsonb_array_elements(value->'heading_path') LOOP
            IF jsonb_typeof(heading) IS DISTINCT FROM 'string'
               OR octet_length(heading #>> '{}') > 255 THEN
              RAISE EXCEPTION 'invalid Document extraction input'
                USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
            END IF;
            normalized := normalize(heading #>> '{}', NFC);
            IF octet_length(normalized) > 255 THEN
              RAISE EXCEPTION 'invalid Document extraction input'
                USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
            END IF;
            headings := headings || jsonb_build_array(normalized);
          END LOOP;
          value := jsonb_set(value, '{heading_path}', headings);
          first_key := 'start_line'; last_key := 'end_line'; minimum := 1;
        WHEN 'text' THEN
          allowed := ARRAY['version','kind','start_line','end_line'];
          first_key := 'start_line'; last_key := 'end_line'; minimum := 1;
        WHEN 'fragment' THEN
          allowed := ARRAY['version','kind','ordinal'];
          IF content.document_json_integer(value->'ordinal', 0) IS NULL THEN
            RAISE EXCEPTION 'invalid Document extraction input'
              USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
          END IF;
        ELSE
          RAISE EXCEPTION 'invalid Document extraction input'
            USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END CASE;
      IF EXISTS (SELECT 1 FROM jsonb_object_keys(value) AS keys(key) WHERE NOT key = ANY(allowed)) THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      IF first_key IS NOT NULL AND (kind = 'text' OR value ? first_key OR value ? last_key) THEN
        first_value := content.document_json_integer(value->first_key, minimum);
        last_value := content.document_json_integer(value->last_key, minimum);
        IF first_value IS NULL OR last_value IS NULL OR last_value < first_value
           OR (kind = 'pdf' AND last_value = first_value) THEN
          RAISE EXCEPTION 'invalid Document extraction input'
            USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
        END IF;
      END IF;
      RETURN value;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.document_locator_encoding(value jsonb) RETURNS bytea
    LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, content
    AS $function$
    DECLARE
      locator jsonb := content.document_canonical_locator(value);
      result bytea;
      heading_encoding bytea;
      heading jsonb;
      key text;
      keys text[];
    BEGIN
      result := content.document_frame(convert_to('1','UTF8'))
        || content.document_frame(convert_to(locator->>'kind','UTF8'));
      CASE locator->>'kind'
        WHEN 'pdf' THEN keys := ARRAY['page','start_char','end_char'];
        WHEN 'text' THEN keys := ARRAY['start_line','end_line'];
        WHEN 'fragment' THEN keys := ARRAY['ordinal'];
        WHEN 'markdown' THEN
          heading_encoding := content.document_frame(convert_to(jsonb_array_length(locator->'heading_path')::text,'UTF8'));
          FOR heading IN SELECT jsonb_array_elements(locator->'heading_path') LOOP
            heading_encoding := heading_encoding || content.document_frame(convert_to(heading #>> '{}','UTF8'));
          END LOOP;
          result := result || content.document_frame(heading_encoding);
          keys := ARRAY['start_line','end_line'];
      END CASE;
      FOREACH key IN ARRAY keys LOOP
        result := result || content.document_frame(convert_to(coalesce(locator->>key,''),'UTF8'));
      END LOOP;
      RETURN result;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.document_fragment_id(version uuid, locator jsonb, ordinal bigint, digest bytea)
    RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, content
    AS $function$
    BEGIN
      IF version IS NULL OR ordinal IS NULL OR ordinal < 0 OR digest IS NULL OR octet_length(digest) <> 32 THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      RETURN encode(sha256(convert_to('singularity:document-fragment:v1','UTF8') || decode('00','hex')
        || content.document_frame(convert_to(version::text,'UTF8'))
        || content.document_frame(content.document_locator_encoding(locator))
        || content.document_frame(convert_to(ordinal::text,'UTF8'))
        || content.document_frame(digest)), 'hex');
    END
    $function$
    """)

    execute(~S"""
    CREATE FUNCTION content.document_trim_name(value text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT SET search_path = pg_catalog
    AS $function$
      SELECT btrim(value, U&'\0009\000A\000B\000C\000D\0020\0085\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000')
    $function$
    """)

    execute("""
    CREATE FUNCTION content.document_canonical_fragment(version uuid, media text, expected_ordinal bigint, value jsonb)
    RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, content
    AS $function$
    DECLARE locator jsonb; digest bytea; expected_kind text;
    BEGIN
      -- Internal transport: exact id/ordinal/text/digest/locator keys. The digest
      -- is lowercase SHA-256 hex; aggregate identity is derived by the caller.
      IF jsonb_typeof(value) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      IF (SELECT count(*) FROM jsonb_object_keys(value)) <> 5
         OR NOT value ?& ARRAY['id','ordinal','text','digest','locator']
         OR jsonb_typeof(value->'id') IS DISTINCT FROM 'string'
         OR (value->>'id') !~ '^[0-9a-f]{64}$'
         OR content.document_json_integer(value->'ordinal',0) IS DISTINCT FROM expected_ordinal
         OR jsonb_typeof(value->'text') IS DISTINCT FROM 'string'
         OR octet_length(value->>'text') > 65536
         OR position(chr(13) in value->>'text') > 0
         OR jsonb_typeof(value->'digest') IS DISTINCT FROM 'string'
         OR (value->>'digest') !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      locator := content.document_canonical_locator(value->'locator');
      expected_kind := CASE media WHEN 'application/pdf' THEN 'pdf' WHEN 'text/markdown' THEN 'markdown' WHEN 'text/plain' THEN 'text' END;
      digest := sha256(convert_to(value->>'text','UTF8'));
      IF expected_kind IS NULL OR (locator->>'kind') NOT IN (expected_kind,'fragment')
         OR ((locator->>'kind') = 'fragment' AND content.document_json_integer(locator->'ordinal',0) IS DISTINCT FROM expected_ordinal)
         OR decode(value->>'digest','hex') <> digest
         OR value->>'id' <> content.document_fragment_id(version,locator,expected_ordinal,digest) THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      RETURN jsonb_set(value,'{locator}',locator);
    END
    $function$
    """)
  end

  defp create_fragments do
    execute("""
    CREATE TABLE content.document_fragments (
      id text PRIMARY KEY,
      resource_id uuid NOT NULL,
      resource_version_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      ordinal bigint NOT NULL,
      text text NOT NULL,
      digest bytea NOT NULL,
      locator jsonb NOT NULL,
      inserted_at timestamptz(6) NOT NULL,
      CONSTRAINT document_fragments_id_check CHECK (id ~ '^[0-9a-f]{64}$'),
      CONSTRAINT document_fragments_private_check CHECK (classification = 'private'),
      CONSTRAINT document_fragments_ordinal_check CHECK (ordinal >= 0),
      CONSTRAINT document_fragments_text_check CHECK (octet_length(text) <= 65536 AND position(chr(13) in text) = 0),
      CONSTRAINT document_fragments_digest_check CHECK (octet_length(digest) = 32 AND digest = sha256(convert_to(text,'UTF8'))),
      CONSTRAINT document_fragments_locator_check CHECK ((locator = content.document_canonical_locator(locator)) IS TRUE),
      CONSTRAINT document_fragments_locator_ordinal_check CHECK (((locator->>'kind') <> 'fragment' OR content.document_json_integer(locator->'ordinal',0) = ordinal) IS TRUE),
      CONSTRAINT document_fragments_identity_check CHECK ((id = content.document_fragment_id(resource_version_id,locator,ordinal,digest)) IS TRUE),
      CONSTRAINT document_fragments_version_ordinal_key UNIQUE (resource_version_id,ordinal),
      CONSTRAINT document_fragments_identity_aggregate_key UNIQUE (id,resource_id,resource_version_id,vault_id,classification),
      CONSTRAINT document_fragments_document_version_fkey
        FOREIGN KEY (resource_version_id,resource_id,vault_id,classification)
        REFERENCES content.document_versions(resource_version_id,resource_id,vault_id,classification)
        DEFERRABLE INITIALLY DEFERRED
    )
    """)
  end

  defp create_state_constraints do
    execute("""
    ALTER TABLE content.document_versions
      ADD CONSTRAINT document_versions_adapter_check CHECK (extraction_adapter IS NULL OR
        (octet_length(extraction_adapter) BETWEEN 1 AND 255 AND content.document_trim_name(extraction_adapter) = extraction_adapter)),
      ADD CONSTRAINT document_versions_format_check CHECK (extraction_format IS NULL OR extraction_format > 0),
      ADD CONSTRAINT document_versions_extracted_digest_check CHECK (extracted_text_digest IS NULL OR octet_length(extracted_text_digest) = 32),
      ADD CONSTRAINT document_versions_language_check CHECK (detected_language IS NULL OR
        (octet_length(detected_language) <= 255 AND content.document_trim_name(detected_language) <> '')),
      ADD CONSTRAINT document_versions_failure_code_check CHECK (failure_code IS NULL OR failure_code IN
        ('invalid_utf8','malformed_document','encrypted_document','no_extractable_text','input_too_large','output_too_large','page_limit','timeout','extractor_failed')),
      ADD CONSTRAINT document_versions_state_shape_check CHECK ((
        (state = 'pending' AND extraction_adapter IS NULL AND extraction_format IS NULL
          AND extracted_text_digest IS NULL AND detected_language IS NULL AND failure_code IS NULL AND attempt_finished_at IS NULL)
        OR (state = 'extracting' AND attempt_generation > 0 AND extraction_adapter IS NOT NULL AND extraction_format IS NOT NULL
          AND extracted_text_digest IS NULL AND detected_language IS NULL AND failure_code IS NULL AND attempt_finished_at IS NULL)
        OR (state = 'ready' AND attempt_generation > 0 AND extraction_adapter IS NOT NULL AND extraction_format IS NOT NULL
          AND extracted_text_digest IS NOT NULL AND failure_code IS NULL AND attempt_finished_at IS NOT NULL)
        OR (state IN ('failed','unsupported') AND attempt_generation > 0 AND extraction_adapter IS NOT NULL AND extraction_format IS NOT NULL
          AND extracted_text_digest IS NULL AND detected_language IS NULL AND failure_code IS NOT NULL AND attempt_finished_at IS NOT NULL)
      ) IS TRUE)
    """)
  end

  defp create_guards do
    execute("""
    CREATE FUNCTION content.enforce_document_lifecycle() RETURNS trigger
    LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, content
    AS $function$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Document identity is immutable'
          USING ERRCODE = '23514', CONSTRAINT = 'document_versions_immutable_check';
      END IF;
      IF (to_jsonb(NEW) - ARRAY['state','attempt_generation','extraction_adapter','extraction_format','extracted_text_digest','detected_language','failure_code','attempt_finished_at'])
         IS DISTINCT FROM
         (to_jsonb(OLD) - ARRAY['state','attempt_generation','extraction_adapter','extraction_format','extracted_text_digest','detected_language','failure_code','attempt_finished_at']) THEN
        RAISE EXCEPTION 'Document identity is immutable'
          USING ERRCODE = '23514', CONSTRAINT = 'document_versions_immutable_check';
      END IF;
      -- This must remain an invoker trigger: a definer trigger would elevate
      -- direct runtime UPDATE and make this effective-role guard meaningless.
      IF current_user <> 'singularity_table_owner' THEN
        RAISE EXCEPTION 'Document lifecycle requires its guarded operation'
          USING ERRCODE = '23514', CONSTRAINT = 'document_versions_lifecycle_guard_check';
      END IF;
      IF NEW.state NOT IN ('pending','extracting','ready','failed','unsupported') THEN
        RAISE EXCEPTION 'invalid Document state'
          USING ERRCODE = '23514', CONSTRAINT = 'document_versions_state_check';
      END IF;
      IF NEW.attempt_generation < 0 THEN
        RAISE EXCEPTION 'invalid Document generation'
          USING ERRCODE = '23514', CONSTRAINT = 'document_versions_attempt_generation_check';
      END IF;
      IF NEW IS NOT DISTINCT FROM OLD THEN RETURN NEW; END IF;
      IF (OLD.state = 'pending' AND NEW.state = 'extracting'
          AND OLD.attempt_generation < 9223372036854775807
          AND NEW.attempt_generation::numeric = OLD.attempt_generation::numeric + 1)
        OR (OLD.state = 'extracting' AND NEW.state IN ('ready','failed','unsupported')
          AND NEW.attempt_generation = OLD.attempt_generation
          AND NEW.extraction_adapter IS NOT DISTINCT FROM OLD.extraction_adapter
          AND NEW.extraction_format IS NOT DISTINCT FROM OLD.extraction_format)
        OR (OLD.state IN ('failed','unsupported') AND NEW.state = 'pending'
          AND NEW.attempt_generation = OLD.attempt_generation) THEN RETURN NEW;
      END IF;
      RAISE EXCEPTION 'invalid Document lifecycle transition'
        USING ERRCODE = '23514', CONSTRAINT = 'document_versions_lifecycle_guard_check';
    END
    $function$
    """)

    execute("""
    CREATE TRIGGER document_versions_lifecycle_guard
    BEFORE UPDATE OR DELETE ON content.document_versions
    FOR EACH ROW EXECUTE FUNCTION content.enforce_document_lifecycle()
    """)

    execute("""
    CREATE FUNCTION content.enforce_document_fragment() RETURNS trigger
    LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, content
    AS $function$
    DECLARE document content.document_versions%ROWTYPE;
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Document fragments are immutable'
          USING ERRCODE = '23514', CONSTRAINT = 'document_fragments_immutable_check';
      END IF;
      IF current_user <> 'singularity_table_owner' THEN
        RAISE EXCEPTION 'Document fragments require guarded completion'
          USING ERRCODE = '23514', CONSTRAINT = 'document_fragments_immutable_check';
      END IF;
      PERFORM 1 FROM content.resources WHERE id = NEW.resource_id FOR UPDATE;
      SELECT * INTO document FROM content.document_versions WHERE resource_version_id = NEW.resource_version_id FOR UPDATE;
      IF document.state = 'ready' THEN
        RAISE EXCEPTION 'Document completion is sealed'
          USING ERRCODE = '23514', CONSTRAINT = 'document_fragments_insert_state_check';
      END IF;
      IF FOUND THEN
        PERFORM content.document_canonical_fragment(NEW.resource_version_id, document.media_type, NEW.ordinal,
          jsonb_build_object('id',NEW.id,'ordinal',NEW.ordinal,'text',NEW.text,'digest',encode(NEW.digest,'hex'),'locator',NEW.locator));
        NEW.locator := content.document_canonical_locator(NEW.locator);
      END IF;
      RETURN NEW;
    END
    $function$
    """)

    execute("""
    CREATE TRIGGER document_fragments_immutable_guard
    BEFORE INSERT OR UPDATE OR DELETE ON content.document_fragments
    FOR EACH ROW EXECUTE FUNCTION content.enforce_document_fragment()
    """)

    execute("""
    CREATE FUNCTION content.enforce_document_completion() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, content
    AS $function$
    DECLARE document content.document_versions%ROWTYPE; amount bigint; bytes bigint; first_ordinal bigint; last_ordinal bigint; digest bytea; valid_media boolean;
    BEGIN
      PERFORM 1 FROM content.resources WHERE id = NEW.resource_id FOR UPDATE;
      SELECT * INTO document FROM content.document_versions WHERE resource_version_id = NEW.resource_version_id FOR UPDATE;
      IF NOT FOUND THEN RETURN NULL; END IF;
      -- Only a version transition can make these inserted rows ready. Its
      -- queued version guard validates the whole set once, rather than hashing
      -- up to 16 MiB again for each of the 4096 queued fragment events.
      IF TG_TABLE_NAME = 'document_fragments' AND document.state = 'ready' THEN RETURN NULL; END IF;
      SELECT count(*), coalesce(sum(octet_length(fragment.text)),0), min(ordinal), max(ordinal),
        sha256(convert_to(string_agg(fragment.text,'' ORDER BY ordinal),'UTF8')),
        bool_and((locator->>'kind') IN ('fragment', CASE document.media_type
          WHEN 'application/pdf' THEN 'pdf' WHEN 'text/markdown' THEN 'markdown' WHEN 'text/plain' THEN 'text' END))
      INTO amount, bytes, first_ordinal, last_ordinal, digest, valid_media
      FROM content.document_fragments AS fragment WHERE resource_version_id = document.resource_version_id;
      IF (document.state IN ('pending','failed','unsupported') AND amount <> 0)
        OR (document.state = 'ready' AND
          (amount NOT BETWEEN 1 AND 4096 OR bytes NOT BETWEEN 1 AND 16777216
           OR first_ordinal IS DISTINCT FROM 0::bigint OR last_ordinal IS DISTINCT FROM amount - 1
           OR digest IS DISTINCT FROM document.extracted_text_digest OR valid_media IS DISTINCT FROM true)) THEN
        RAISE EXCEPTION 'Document completion requires its complete fragment set'
          USING ERRCODE = '23514', CONSTRAINT = 'document_versions_completion_check';
      END IF;
      RETURN NULL;
    END
    $function$
    """)

    for table <- ~w(document_versions document_fragments) do
      execute("""
      CREATE CONSTRAINT TRIGGER #{table}_completion_check
      AFTER INSERT OR UPDATE ON content.#{table}
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
      EXECUTE FUNCTION content.enforce_document_completion()
      """)
    end
  end

  defp create_lifecycle do
    execute("""
    CREATE FUNCTION content.lock_document_extraction(version uuid) RETURNS content.document_versions
    LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE scoped_owner uuid; scoped_principal uuid; resource uuid; document content.document_versions%ROWTYPE;
    BEGIN
      BEGIN
        scoped_owner := nullif(current_setting('singularity.vault_id',true),'')::uuid;
        scoped_principal := nullif(current_setting('singularity.principal_id',true),'')::uuid;
      EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Document extraction is not authorized'
          USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
      END;
      IF scoped_owner IS NULL OR scoped_principal IS NULL OR NOT EXISTS (
        SELECT 1 FROM core.vault_members AS membership
        JOIN identity.principals AS principal ON principal.id = membership.principal_id
        JOIN identity.accounts AS account ON account.id = principal.account_id
        WHERE membership.vault_id = scoped_owner AND membership.principal_id = scoped_principal
          AND membership.revoked_at IS NULL AND principal.kind = 'owner'
          AND principal.revoked_at IS NULL AND account.status = 'active'
      ) THEN
        RAISE EXCEPTION 'Document extraction is not authorized'
          USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
      END IF;
      SELECT resource_id INTO resource FROM content.document_versions
        WHERE resource_version_id = version AND vault_id = scoped_owner AND classification = 'private';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Document extraction is not authorized'
          USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
      END IF;
      PERFORM 1 FROM content.resources WHERE id = resource AND vault_id = scoped_owner
        AND classification = 'private' AND kind = 'document' AND deleted_at IS NULL FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Document extraction is not authorized'
          USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
      END IF;
      SELECT * INTO document FROM content.document_versions
        WHERE resource_version_id = version AND resource_id = resource AND vault_id = scoped_owner AND classification = 'private'
        FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Document extraction is not authorized'
          USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
      END IF;
      RETURN document;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.claim_document_extraction(version uuid, expected_generation bigint, adapter text, format integer)
    RETURNS content.document_versions LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE := content.lock_document_extraction(version);
    BEGIN
      adapter := content.document_trim_name(adapter);
      IF adapter IS NULL OR octet_length(adapter) NOT BETWEEN 1 AND 255 OR format IS NULL OR format < 1 THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      IF document.state <> 'pending' OR document.attempt_generation IS DISTINCT FROM expected_generation
         OR document.attempt_generation = 9223372036854775807 THEN
        RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
      END IF;
      UPDATE content.document_versions SET state = 'extracting', attempt_generation = attempt_generation + 1,
        extraction_adapter = adapter, extraction_format = format
      WHERE resource_version_id = version RETURNING * INTO document;
      RETURN document;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.complete_document_extraction(version uuid, generation bigint, fragments jsonb, extracted_digest bytea, language text)
    RETURNS content.document_versions LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE := content.lock_document_extraction(version);
      canonical jsonb; stored jsonb; bytes bigint; actual_digest bytea;
    BEGIN
      IF document.state NOT IN ('extracting','ready') OR document.attempt_generation IS DISTINCT FROM generation THEN
        RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
      END IF;
      IF jsonb_typeof(fragments) IS DISTINCT FROM 'array' OR extracted_digest IS NULL OR octet_length(extracted_digest) <> 32
         OR (language IS NOT NULL AND (octet_length(language) > 255 OR content.document_trim_name(language) = '')) THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      IF jsonb_array_length(fragments) NOT BETWEEN 1 AND 4096 THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      SELECT coalesce(sum(octet_length(value->>'text')),0) INTO bytes FROM jsonb_array_elements(fragments);
      IF bytes NOT BETWEEN 1 AND 16777216 THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      WITH validated AS MATERIALIZED (
        SELECT content.document_canonical_fragment(version,document.media_type,ordinal-1,value) AS fragment, ordinal
        FROM jsonb_array_elements(fragments) WITH ORDINALITY AS entries(value,ordinal)
      )
      SELECT jsonb_agg(fragment ORDER BY ordinal),
        sha256(convert_to(string_agg(fragment->>'text','' ORDER BY ordinal),'UTF8'))
      INTO canonical, actual_digest FROM validated;
      IF actual_digest IS DISTINCT FROM extracted_digest THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      IF document.state = 'ready' THEN
        SELECT jsonb_agg(jsonb_build_object('id',id,'ordinal',ordinal,'text',text,'digest',encode(digest,'hex'),'locator',locator) ORDER BY ordinal)
        INTO stored FROM content.document_fragments WHERE resource_version_id = version;
        IF document.extracted_text_digest IS DISTINCT FROM extracted_digest
           OR document.detected_language IS DISTINCT FROM language OR stored IS DISTINCT FROM canonical THEN
          RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
            USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
        END IF;
        RETURN document;
      END IF;
      INSERT INTO content.document_fragments (id,resource_id,resource_version_id,vault_id,classification,ordinal,text,digest,locator,inserted_at)
      SELECT value->>'id',document.resource_id,version,document.vault_id,document.classification,
        (value->>'ordinal')::bigint,value->>'text',decode(value->>'digest','hex'),value->'locator',CURRENT_TIMESTAMP
      FROM jsonb_array_elements(canonical);
      UPDATE content.document_versions SET state = 'ready', extracted_text_digest = extracted_digest,
        detected_language = language, failure_code = NULL, attempt_finished_at = CURRENT_TIMESTAMP
      WHERE resource_version_id = version RETURNING * INTO document;
      RETURN document;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.fail_document_extraction(version uuid, generation bigint, outcome text, failure_code text)
    RETURNS content.document_versions LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE := content.lock_document_extraction(version);
    BEGIN
      IF outcome IS NULL OR outcome NOT IN ('failed','unsupported') OR failure_code IS NULL OR failure_code NOT IN
        ('invalid_utf8','malformed_document','encrypted_document','no_extractable_text','input_too_large','output_too_large','page_limit','timeout','extractor_failed') THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      IF document.state <> 'extracting' OR document.attempt_generation IS DISTINCT FROM generation THEN
        RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
      END IF;
      UPDATE content.document_versions SET state = outcome, failure_code = fail_document_extraction.failure_code,
        extracted_text_digest = NULL, detected_language = NULL, attempt_finished_at = CURRENT_TIMESTAMP
      WHERE resource_version_id = version RETURNING * INTO document;
      RETURN document;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.reset_document_extraction(version uuid, expected_generation bigint)
    RETURNS content.document_versions LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE := content.lock_document_extraction(version);
    BEGIN
      IF document.state NOT IN ('failed','unsupported') OR document.attempt_generation IS DISTINCT FROM expected_generation THEN
        RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
      END IF;
      UPDATE content.document_versions SET state = 'pending', extraction_adapter = NULL, extraction_format = NULL,
        extracted_text_digest = NULL, detected_language = NULL, failure_code = NULL, attempt_finished_at = NULL
      WHERE resource_version_id = version RETURNING * INTO document;
      RETURN document;
    END
    $function$
    """)
  end

  defp create_policies do
    execute("ALTER TABLE content.document_fragments ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE content.document_fragments FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY document_fragments_table_owner ON content.document_fragments
    FOR ALL TO singularity_table_owner USING (true) WITH CHECK (true)
    """)

    predicate = """
    nullif(current_setting('singularity.principal_id',true),'') IS NOT NULL
    AND nullif(current_setting('singularity.vault_id',true),'') IS NOT NULL
    AND vault_id = nullif(current_setting('singularity.vault_id',true),'')::uuid
    AND core.principal_is_authorized(nullif(current_setting('singularity.principal_id',true),'')::uuid,vault_id)
    """

    execute("""
    CREATE POLICY document_fragments_vault_isolation ON content.document_fragments
    FOR ALL TO singularity_web, singularity_worker USING (#{predicate}) WITH CHECK (#{predicate})
    """)

    execute(
      "REVOKE ALL ON content.document_fragments FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth"
    )

    for signature <- [
          "document_frame(bytea)",
          "document_json_integer(jsonb,bigint)",
          "document_canonical_locator(jsonb)",
          "document_locator_encoding(jsonb)",
          "document_fragment_id(uuid,jsonb,bigint,bytea)",
          "document_trim_name(text)",
          "document_canonical_fragment(uuid,text,bigint,jsonb)",
          "enforce_document_lifecycle()",
          "enforce_document_fragment()",
          "enforce_document_completion()",
          "lock_document_extraction(uuid)",
          "claim_document_extraction(uuid,bigint,text,integer)",
          "complete_document_extraction(uuid,bigint,jsonb,bytea,text)",
          "fail_document_extraction(uuid,bigint,text,text)",
          "reset_document_extraction(uuid,bigint)"
        ] do
      execute(
        "REVOKE ALL ON FUNCTION content.#{signature} FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth"
      )
    end
  end
end
