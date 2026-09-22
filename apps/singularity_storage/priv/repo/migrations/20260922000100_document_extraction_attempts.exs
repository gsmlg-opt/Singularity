defmodule Singularity.Storage.Migrations.DocumentExtractionAttempts do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    ALTER TABLE content.document_versions
      ADD COLUMN attempt_job_id uuid,
      ADD COLUMN attempt_started_at timestamptz(6),
      ADD COLUMN attempt_deadline_at timestamptz(6)
    """)

    execute(
      "ALTER TABLE content.document_versions DROP CONSTRAINT document_versions_state_shape_check"
    )

    execute("""
    ALTER TABLE content.document_versions ADD CONSTRAINT document_versions_state_shape_check CHECK ((
      (state = 'pending' AND attempt_job_id IS NULL AND attempt_started_at IS NULL AND attempt_deadline_at IS NULL
        AND extraction_adapter IS NULL AND extraction_format IS NULL AND extracted_text_digest IS NULL
        AND detected_language IS NULL AND failure_code IS NULL AND attempt_finished_at IS NULL)
      OR (state = 'extracting' AND attempt_generation > 0 AND attempt_job_id IS NOT NULL
        AND attempt_started_at IS NOT NULL AND attempt_deadline_at = attempt_started_at + interval '180 seconds'
        AND extraction_adapter IS NOT NULL AND extraction_format IS NOT NULL AND extracted_text_digest IS NULL
        AND detected_language IS NULL AND failure_code IS NULL AND attempt_finished_at IS NULL)
      OR (state = 'ready' AND attempt_generation > 0 AND attempt_job_id IS NOT NULL
        AND attempt_started_at IS NOT NULL AND attempt_deadline_at = attempt_started_at + interval '180 seconds'
        AND extraction_adapter IS NOT NULL AND extraction_format IS NOT NULL AND extracted_text_digest IS NOT NULL
        AND failure_code IS NULL AND attempt_finished_at IS NOT NULL)
      OR (state IN ('failed','unsupported') AND attempt_generation > 0 AND attempt_job_id IS NOT NULL
        AND attempt_started_at IS NOT NULL AND attempt_deadline_at = attempt_started_at + interval '180 seconds'
        AND extraction_adapter IS NOT NULL AND extraction_format IS NOT NULL AND extracted_text_digest IS NULL
        AND detected_language IS NULL AND failure_code IS NOT NULL AND attempt_finished_at IS NOT NULL)
    ) IS TRUE)
    """)

    execute("""
    CREATE OR REPLACE FUNCTION content.enforce_document_lifecycle() RETURNS trigger
    LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, content
    AS $function$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Document identity is immutable'
          USING ERRCODE = '23514', CONSTRAINT = 'document_versions_immutable_check';
      END IF;
      IF (to_jsonb(NEW) - ARRAY['state','attempt_generation','attempt_job_id','attempt_started_at','attempt_deadline_at','extraction_adapter','extraction_format','extracted_text_digest','detected_language','failure_code','attempt_finished_at'])
         IS DISTINCT FROM
         (to_jsonb(OLD) - ARRAY['state','attempt_generation','attempt_job_id','attempt_started_at','attempt_deadline_at','extraction_adapter','extraction_format','extracted_text_digest','detected_language','failure_code','attempt_finished_at']) THEN
        RAISE EXCEPTION 'Document identity is immutable'
          USING ERRCODE = '23514', CONSTRAINT = 'document_versions_immutable_check';
      END IF;
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
          AND NEW.attempt_job_id = OLD.attempt_job_id
          AND NEW.attempt_started_at = OLD.attempt_started_at
          AND NEW.attempt_deadline_at = OLD.attempt_deadline_at
          AND NEW.extraction_adapter IS NOT DISTINCT FROM OLD.extraction_adapter
          AND NEW.extraction_format IS NOT DISTINCT FROM OLD.extraction_format)
        OR (OLD.state = 'extracting' AND NEW.state = 'pending'
          AND OLD.attempt_generation < 9223372036854775807
          AND NEW.attempt_generation::numeric = OLD.attempt_generation::numeric + 1)
        OR (OLD.state IN ('failed','unsupported') AND NEW.state = 'pending'
          AND NEW.attempt_generation = OLD.attempt_generation) THEN RETURN NEW;
      END IF;
      RAISE EXCEPTION 'invalid Document lifecycle transition'
        USING ERRCODE = '23514', CONSTRAINT = 'document_versions_lifecycle_guard_check';
    END
    $function$
    """)

    for signature <- [
          "claim_document_extraction(uuid,bigint,text,integer)",
          "complete_document_extraction(uuid,bigint,jsonb,bytea,text)",
          "fail_document_extraction(uuid,bigint,text,text)",
          "reset_document_extraction(uuid,bigint)"
        ],
        do: execute("DROP FUNCTION content.#{signature}")

    create_lifecycle()

    for signature <- [
          "claim_document_extraction(uuid,bigint,uuid,text,integer)",
          "complete_document_extraction(uuid,uuid,bigint,jsonb,bytea,text)",
          "fail_document_extraction(uuid,uuid,bigint,text,text)",
          "reset_document_extraction(uuid,bigint,text,integer)",
          "recover_document_extraction(uuid,bigint)"
        ],
        do:
          execute(
            "REVOKE ALL ON FUNCTION content.#{signature} FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth"
          )

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "Document extraction attempts migration is forward-only")

  defp create_lifecycle do
    execute("""
    CREATE FUNCTION content.claim_document_extraction(version uuid, expected_generation bigint, claim_job_id uuid, adapter text, format integer)
    RETURNS content.document_versions LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE := content.lock_document_extraction(version);
      claim_time timestamptz := clock_timestamp();
    BEGIN
      adapter := content.document_trim_name(adapter);
      IF claim_job_id IS NULL OR adapter IS NULL OR octet_length(adapter) NOT BETWEEN 1 AND 255 OR format IS NULL OR format < 1 THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      IF document.state = 'extracting' AND document.attempt_generation = expected_generation + 1
         AND document.attempt_job_id = claim_job_id AND document.extraction_adapter = adapter
         AND document.extraction_format = format AND document.attempt_deadline_at >= claim_time THEN
        RETURN document;
      END IF;
      IF document.state <> 'pending' OR document.attempt_generation IS DISTINCT FROM expected_generation
         OR document.attempt_generation = 9223372036854775807 THEN
        RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
      END IF;
      UPDATE content.document_versions SET state = 'extracting', attempt_generation = attempt_generation + 1,
        attempt_job_id = claim_job_id, attempt_started_at = claim_time,
        attempt_deadline_at = claim_time + interval '180 seconds',
        extraction_adapter = adapter, extraction_format = format
      WHERE resource_version_id = version RETURNING * INTO document;
      RETURN document;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.complete_document_extraction(version uuid, job_id uuid, generation bigint, fragments jsonb, extracted_digest bytea, language text)
    RETURNS content.document_versions LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE := content.lock_document_extraction(version);
      canonical jsonb; stored jsonb; bytes bigint; actual_digest bytea;
    BEGIN
      IF document.state NOT IN ('extracting','ready') OR document.attempt_generation IS DISTINCT FROM generation
         OR document.attempt_job_id IS DISTINCT FROM job_id
         OR (document.state = 'extracting' AND document.attempt_deadline_at < clock_timestamp()) THEN
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
    CREATE FUNCTION content.fail_document_extraction(version uuid, job_id uuid, generation bigint, outcome text, failure_code text)
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
      IF document.state <> 'extracting' OR document.attempt_generation IS DISTINCT FROM generation
         OR document.attempt_job_id IS DISTINCT FROM job_id OR document.attempt_deadline_at < clock_timestamp() THEN
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
    CREATE FUNCTION content.reset_document_extraction(version uuid, expected_generation bigint, new_adapter text, new_format integer)
    RETURNS content.document_versions LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE := content.lock_document_extraction(version);
    BEGIN
      new_adapter := content.document_trim_name(new_adapter);
      IF new_adapter IS NULL OR octet_length(new_adapter) NOT BETWEEN 1 AND 255 OR new_format IS NULL OR new_format < 1 THEN
        RAISE EXCEPTION 'invalid Document extraction input'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
      END IF;
      IF document.state NOT IN ('failed','unsupported') OR document.attempt_generation IS DISTINCT FROM expected_generation
         OR (document.state = 'unsupported' AND document.extraction_adapter = new_adapter AND document.extraction_format = new_format) THEN
        RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
      END IF;
      UPDATE content.document_versions SET state = 'pending', attempt_job_id = NULL,
        attempt_started_at = NULL, attempt_deadline_at = NULL,
        extraction_adapter = NULL, extraction_format = NULL, extracted_text_digest = NULL,
        detected_language = NULL, failure_code = NULL, attempt_finished_at = NULL
      WHERE resource_version_id = version RETURNING * INTO document;
      RETURN document;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.recover_document_extraction(version uuid, expected_generation bigint)
    RETURNS content.document_versions LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE := content.lock_document_extraction(version);
    BEGIN
      IF document.state <> 'extracting' OR document.attempt_generation IS DISTINCT FROM expected_generation
         OR document.attempt_generation = 9223372036854775807
         OR document.attempt_deadline_at >= clock_timestamp() THEN
        RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
      END IF;
      UPDATE content.document_versions SET state = 'pending', attempt_generation = attempt_generation + 1,
        attempt_job_id = NULL, attempt_started_at = NULL, attempt_deadline_at = NULL,
        extraction_adapter = NULL, extraction_format = NULL, extracted_text_digest = NULL,
        detected_language = NULL, failure_code = NULL, attempt_finished_at = NULL
      WHERE resource_version_id = version RETURNING * INTO document;
      RETURN document;
    END
    $function$
    """)
  end
end
