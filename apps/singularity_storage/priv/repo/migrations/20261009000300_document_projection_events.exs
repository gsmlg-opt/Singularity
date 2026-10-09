defmodule Singularity.Storage.Migrations.DocumentProjectionEvents do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    # Replacing these existing signatures retains their owners and EXECUTE ACLs.
    execute(runtime_target())
    execute(complete_function())
    execute(delete_function())
    execute(restore_function())

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "Document projection events migration is forward-only")

  defp runtime_target do
    """
    CREATE OR REPLACE FUNCTION content.document_runtime_target(requested_resource uuid, include_deleted boolean)
    RETURNS content.document_versions LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE principal uuid := NULLIF(current_setting('singularity.principal_id',true),'')::uuid;
      owner uuid := NULLIF(current_setting('singularity.vault_id',true),'')::uuid;
      resource content.resources%ROWTYPE;
      document content.document_versions%ROWTYPE;
    BEGIN
      IF principal IS NULL OR owner IS NULL OR requested_resource IS NULL THEN RETURN NULL; END IF;
      IF NOT EXISTS (
        SELECT 1 FROM core.live_principal_authorization() auth
        WHERE auth.principal_id=principal AND auth.vault_id=owner
          AND auth.principal_kind='owner' AND auth.principal_revoked_at IS NULL
          AND auth.membership_revoked_at IS NULL AND auth.vault_locked=false
          AND 'asset.read'=ANY(auth.capabilities)
      ) THEN
        RAISE EXCEPTION 'Document runtime authority denied'
          USING ERRCODE='23514', CONSTRAINT='document_extraction_authority_check';
      END IF;
      SELECT r.* INTO resource FROM content.resources r
      WHERE r.id=requested_resource AND r.vault_id=owner
        AND r.classification='private' AND r.kind='document'
        AND (include_deleted OR r.deleted_at IS NULL)
      FOR UPDATE;
      IF NOT FOUND THEN RETURN NULL; END IF;

      SELECT d.* INTO document FROM content.document_versions d
      WHERE d.resource_id=resource.id AND d.vault_id=resource.vault_id
        AND d.classification=resource.classification
        AND d.resource_version_id=resource.current_version_id
        AND d.created_by_principal_id=principal
      FOR UPDATE;
      RETURN document;
    END
    $function$
    """
  end

  defp complete_function do
    """
    CREATE OR REPLACE FUNCTION content.complete_document_extraction(version uuid, job_id uuid, generation bigint, fragments jsonb, extracted_digest bytea, language text)
    RETURNS content.document_versions LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE := content.lock_document_terminal_extraction(version, job_id, generation);
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
      #{projection_event("document.ready")}
      RETURN document;
    END
    $function$
    """
  end

  defp delete_function do
    """
    CREATE OR REPLACE FUNCTION content.delete_document_runtime(requested_resource uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE;
    BEGIN
      document := content.document_runtime_target(requested_resource,true);
      IF document.resource_id IS NULL THEN RETURN NULL; END IF;
      UPDATE content.resources SET deleted_at=COALESCE(deleted_at,clock_timestamp())
      WHERE id=document.resource_id AND vault_id=document.vault_id AND deleted_at IS NULL;
      IF NOT FOUND THEN RETURN document.resource_id; END IF;
      DELETE FROM content.search_entries
      WHERE resource_id=document.resource_id AND vault_id=document.vault_id;
      #{projection_event("document.deleted")}
      RETURN document.resource_id;
    END
    $function$
    """
  end

  defp restore_function do
    """
    CREATE OR REPLACE FUNCTION content.restore_document_runtime(requested_resource uuid, current_adapter text, current_format integer)
    RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE;
      principal uuid := NULLIF(current_setting('singularity.principal_id',true),'')::uuid;
      principal_epoch bigint; owner_epoch bigint; event_key text; was_deleted boolean;
    BEGIN
      document := content.document_runtime_target(requested_resource,true);
      IF document.resource_id IS NULL THEN RETURN NULL; END IF;
      SELECT deleted_at IS NOT NULL INTO was_deleted FROM content.resources
      WHERE id=document.resource_id AND vault_id=document.vault_id;
      IF NOT was_deleted THEN RETURN document.resource_id; END IF;
      UPDATE content.resources SET deleted_at=NULL WHERE id=document.resource_id AND vault_id=document.vault_id;
      IF document.state='pending' THEN
        UPDATE content.document_versions
        SET attempt_generation=attempt_generation+1
        WHERE resource_version_id=document.resource_version_id
          AND attempt_generation < 9223372036854775807
        RETURNING * INTO document;
        IF document.resource_id IS NULL THEN
          RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
            USING ERRCODE='23514', CONSTRAINT='document_extraction_conflict_check';
        END IF;
      ELSIF document.state='failed' OR (document.state='unsupported' AND
         (document.extraction_adapter<>current_adapter OR document.extraction_format<>current_format)) THEN
        UPDATE content.document_versions SET state='pending', attempt_generation=attempt_generation+1,
          attempt_job_id=NULL, attempt_started_at=NULL, attempt_deadline_at=NULL,
          extraction_adapter=NULL, extraction_format=NULL, extracted_text_digest=NULL,
          detected_language=NULL, failure_code=NULL, attempt_finished_at=NULL
        WHERE resource_version_id=document.resource_version_id
          AND attempt_generation=document.attempt_generation
          AND attempt_generation < 9223372036854775807
        RETURNING * INTO document;
        IF document.resource_id IS NULL THEN
          RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
            USING ERRCODE='23514', CONSTRAINT='document_extraction_conflict_check';
        END IF;
      END IF;
      IF document.state='pending' THEN
        event_key := 'document-extraction:' || document.resource_version_id::text || ':' || document.attempt_generation::text;
        SELECT auth.principal_authorization_epoch,auth.vault_authorization_epoch
        INTO principal_epoch,owner_epoch FROM core.live_principal_authorization() auth
        WHERE auth.principal_id=principal AND auth.vault_id=document.vault_id;
        INSERT INTO core.outbox_events (
          id,event_type,idempotency_key,vault_id,principal_id,required_capability,
          principal_authorization_epoch,vault_authorization_epoch,classification,
          correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at)
        VALUES (gen_random_uuid(),'document.extraction_requested',event_key,document.vault_id,principal,
          'asset.read',principal_epoch,owner_epoch,'private',gen_random_uuid(),NULL,
          document.attempt_generation,1,jsonb_build_object('resource_id',document.resource_id,
          'resource_version_id',document.resource_version_id),clock_timestamp())
        ON CONFLICT (vault_id,idempotency_key) DO NOTHING;
      END IF;
      #{projection_event("document.restored")}
      RETURN document.resource_id;
    END
    $function$
    """
  end

  # This expands only at the three fixed transition sites; it creates no SQL API.
  # Public callers have already checked capability/epochs in their owning path.
  # The trusted private completion helper also accepts a live scoped member.
  defp projection_event(type)
       when type in ["document.ready", "document.deleted", "document.restored"] do
    """
    DECLARE projection_event_id uuid := gen_random_uuid();
      projection_actor uuid := NULLIF(current_setting('singularity.principal_id',true),'')::uuid;
      projection_principal_epoch bigint; projection_owner_epoch bigint;
      projection_revision bigint;
    BEGIN
      SELECT auth.principal_authorization_epoch,auth.vault_authorization_epoch,version.revision
      INTO projection_principal_epoch,projection_owner_epoch,projection_revision
      FROM core.live_principal_authorization() auth
      JOIN content.resource_versions version ON version.id=document.resource_version_id
        AND version.resource_id=document.resource_id AND version.vault_id=document.vault_id
        AND version.classification=document.classification
      WHERE auth.principal_id=projection_actor AND auth.vault_id=document.vault_id
        AND auth.principal_kind='owner' AND auth.principal_revoked_at IS NULL
        AND auth.membership_revoked_at IS NULL;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Document extraction is not authorized'
          USING ERRCODE='42501', CONSTRAINT='document_extraction_authority_check';
      END IF;
      INSERT INTO core.outbox_events (
        id,event_type,idempotency_key,vault_id,principal_id,required_capability,
        principal_authorization_epoch,vault_authorization_epoch,classification,
        correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at)
      VALUES (projection_event_id,'#{type}','document-projection:' || projection_event_id::text,
        document.vault_id,projection_actor,'asset.read',projection_principal_epoch,
        projection_owner_epoch,'private',gen_random_uuid(),NULL,projection_revision,1,
        jsonb_build_object('resource_id',document.resource_id,
          'resource_version_id',document.resource_version_id),clock_timestamp());
    END;
    """
  end
end
