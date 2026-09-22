defmodule Singularity.Storage.Migrations.DocumentRuntimeMutations do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    # Reads remain owner-scoped by forced RLS. Mutation authority stays behind
    # the fixed-signature definers below; no runtime role receives table writes.
    execute(
      "GRANT SELECT ON content.document_versions, content.document_fragments TO singularity_web"
    )

    execute(runtime_helper())
    execute(lifecycle_guard())
    execute(reset_function())
    execute(delete_function())
    execute(retry_function())
    execute(restore_function())

    execute(
      "REVOKE ALL ON FUNCTION content.document_runtime_target(uuid,boolean) FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth"
    )

    for signature <- [
          "delete_document_runtime(uuid)",
          "retry_document_runtime(uuid,text,integer)",
          "restore_document_runtime(uuid,text,integer)"
        ] do
      execute(
        "REVOKE ALL ON FUNCTION content.#{signature} FROM PUBLIC, singularity_worker, singularity_dispatcher, singularity_pre_auth"
      )

      execute("GRANT EXECUTE ON FUNCTION content.#{signature} TO singularity_web")
    end

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "Document runtime mutations migration is forward-only")

  defp runtime_helper do
    """
    CREATE FUNCTION content.document_runtime_target(requested_resource uuid, include_deleted boolean)
    RETURNS content.document_versions LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE principal uuid := NULLIF(current_setting('singularity.principal_id',true),'')::uuid;
      owner uuid := NULLIF(current_setting('singularity.vault_id',true),'')::uuid;
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
      SELECT d.* INTO document FROM content.document_versions d
      JOIN content.resources r ON r.id=d.resource_id AND r.vault_id=d.vault_id
        AND r.classification=d.classification AND r.current_version_id=d.resource_version_id
      WHERE d.resource_id=requested_resource AND d.vault_id=owner
        AND d.classification='private' AND d.created_by_principal_id=principal
        AND r.kind='document' AND (include_deleted OR r.deleted_at IS NULL)
      FOR UPDATE OF d, r;
      RETURN document;
    END
    $function$
    """
  end

  defp delete_function do
    """
    CREATE FUNCTION content.delete_document_runtime(requested_resource uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE;
    BEGIN
      document := content.document_runtime_target(requested_resource,true);
      IF document.resource_id IS NULL THEN RETURN NULL; END IF;
      UPDATE content.resources SET deleted_at=COALESCE(deleted_at,clock_timestamp())
      WHERE id=document.resource_id AND vault_id=document.vault_id;
      RETURN document.resource_id;
    END
    $function$
    """
  end

  defp lifecycle_guard do
    """
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
        OR (OLD.state = 'pending' AND NEW.state = 'pending'
          AND OLD.attempt_generation < 9223372036854775807
          AND NEW.attempt_generation::numeric = OLD.attempt_generation::numeric + 1
          AND (to_jsonb(NEW) - 'attempt_generation') IS NOT DISTINCT FROM
              (to_jsonb(OLD) - 'attempt_generation'))
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
          AND OLD.attempt_generation < 9223372036854775807
          AND NEW.attempt_generation::numeric = OLD.attempt_generation::numeric + 1) THEN RETURN NEW;
      END IF;
      RAISE EXCEPTION 'invalid Document lifecycle transition'
        USING ERRCODE = '23514', CONSTRAINT = 'document_versions_lifecycle_guard_check';
    END
    $function$
    """
  end

  defp retry_function do
    """
    CREATE FUNCTION content.retry_document_runtime(requested_resource uuid, current_adapter text, current_format integer)
    RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE;
      principal uuid := NULLIF(current_setting('singularity.principal_id',true),'')::uuid;
      principal_epoch bigint; owner_epoch bigint; event_key text;
    BEGIN
      document := content.document_runtime_target(requested_resource,false);
      IF document.resource_id IS NULL THEN RETURN NULL; END IF;
      event_key := 'document-extraction:' || document.resource_version_id::text || ':' || document.attempt_generation::text;
      IF document.state='pending' AND EXISTS (
        SELECT 1 FROM core.outbox_events e WHERE e.vault_id=document.vault_id AND e.idempotency_key=event_key
      ) THEN RETURN document.resource_id; END IF;
      IF document.state NOT IN ('failed','unsupported')
         OR (document.state='unsupported' AND document.extraction_adapter=current_adapter
             AND document.extraction_format=current_format) THEN
        RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
          USING ERRCODE='23514', CONSTRAINT='document_extraction_conflict_check';
      END IF;
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
      RETURN document.resource_id;
    END
    $function$
    """
  end

  defp reset_function do
    """
    CREATE OR REPLACE FUNCTION content.reset_document_extraction(version uuid, expected_generation bigint, new_adapter text, new_format integer)
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
         OR document.attempt_generation = 9223372036854775807
         OR (document.state = 'unsupported' AND document.extraction_adapter = new_adapter AND document.extraction_format = new_format) THEN
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
    """
  end

  defp restore_function do
    """
    CREATE FUNCTION content.restore_document_runtime(requested_resource uuid, current_adapter text, current_format integer)
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
      RETURN document.resource_id;
    END
    $function$
    """
  end
end
