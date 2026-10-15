defmodule Singularity.Storage.Migrations.DocumentRestoreRecoveryProvenance do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")
    execute(scanner())
    execute(recovery())
    execute(retry())

    execute("""
    ALTER TABLE core.outbox_events
      DROP CONSTRAINT outbox_events_retirement_shape_check,
      ADD CONSTRAINT outbox_events_retirement_shape_check CHECK (
        (retired_at IS NULL AND retirement_reason IS NULL)
        OR (retired_at IS NOT NULL AND retirement_reason IS NOT NULL
          AND retirement_reason IN (
            'legacy_missing_principal_authorization_epoch_provenance',
            'restore_effect_already_reflected', 'restore_stale_destructive'))
        OR (retired_at IS NOT NULL AND retirement_reason IS NOT NULL
          AND retirement_reason = 'restore_document_authorization_invalid'
          AND event_type = 'document.extraction_requested')
      )
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do:
      raise(Ecto.MigrationError, "Document restore recovery provenance migration is forward-only")

  defp scanner do
    """
    CREATE OR REPLACE FUNCTION content.expired_document_extraction_ids(batch_limit integer)
    RETURNS TABLE(version_id uuid, owner_id uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    BEGIN
      IF batch_limit IS NULL OR batch_limit NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'invalid Document recovery batch' USING ERRCODE = '22023';
      END IF;
      RETURN QUERY
        SELECT d.resource_version_id, d.vault_id
        FROM content.document_versions AS d
        JOIN content.resources AS r ON r.id = d.resource_id AND r.vault_id = d.vault_id
          AND r.kind = 'document' AND r.classification = 'private' AND r.deleted_at IS NULL
          AND r.current_version_id = d.resource_version_id
        JOIN identity.principals AS p ON p.id = d.created_by_principal_id
          AND p.kind = 'owner' AND p.revoked_at IS NULL
        JOIN identity.accounts AS a ON a.id = p.account_id AND a.status = 'active'
        JOIN core.vaults AS v ON v.id = d.vault_id
        JOIN core.vault_members AS m ON m.principal_id = p.id AND m.vault_id = d.vault_id
          AND m.revoked_at IS NULL
        LEFT JOIN core.outbox_events AS e ON e.id = d.attempt_job_id
        LEFT JOIN jobs.job_submissions AS s ON s.outbox_event_id = e.id
        WHERE d.state = 'extracting' AND d.classification = 'private'
          AND d.attempt_deadline_at < clock_timestamp()
          AND d.attempt_generation > 0 AND d.attempt_generation < 9223372036854775807
          AND EXISTS (
            SELECT 1 FROM core.principal_capabilities AS pc
            JOIN core.capabilities AS c ON c.id = pc.capability_id
            WHERE pc.principal_id = p.id AND pc.vault_id = d.vault_id
              AND pc.revoked_at IS NULL AND c.name = 'asset.read')
          AND (e.id IS NULL OR (
            e.vault_id = d.vault_id AND e.principal_id = d.created_by_principal_id
            AND e.event_type = 'document.extraction_requested'
            AND e.required_capability = 'asset.read' AND e.classification = 'private'
            AND e.envelope_version = 1 AND e.correlation_id IS NOT NULL
            AND e.expected_entity_revision = d.attempt_generation - 1
            AND e.principal_authorization_epoch >= 0 AND e.vault_authorization_epoch >= 0
            AND e.principal_authorization_epoch = p.authorization_epoch
            AND e.vault_authorization_epoch = v.authorization_epoch
            AND e.payload = jsonb_build_object('resource_id', d.resource_id,
              'resource_version_id', d.resource_version_id)
            AND e.idempotency_key = CASE WHEN d.attempt_generation = 1
              THEN 'document-extraction:' || d.resource_version_id::text
              ELSE 'document-extraction:' || d.resource_version_id::text || ':' ||
                (d.attempt_generation - 1)::text END
            AND ((e.retired_at IS NULL AND e.retirement_reason IS NULL)
              OR (e.retired_at IS NOT NULL AND e.retirement_reason = 'restore_effect_already_reflected'))
            AND ((s.id IS NULL AND e.retired_at IS NULL)
              OR (s.id = e.id AND s.outbox_event_id = e.id AND s.vault_id = d.vault_id
                AND s.classification = 'private' AND s.job_type = 'document_extract'
                AND s.idempotency_key = e.idempotency_key))))
        ORDER BY d.attempt_deadline_at, d.resource_version_id
        LIMIT batch_limit;
    END
    $function$
    """
  end

  defp recovery do
    """
    CREATE OR REPLACE FUNCTION content.recover_expired_document_with_event(version_id uuid, owner_id uuid)
    RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE found_document content.document_versions%ROWTYPE;
      found_resource uuid; original_job uuid; new_generation bigint;
      original_principal uuid; principal_epoch bigint; owner_epoch bigint;
      recovered content.document_versions%ROWTYPE;
      original_event core.outbox_events%ROWTYPE; event_exists boolean;
      original_submission jobs.job_submissions%ROWTYPE; submission_exists boolean;
    BEGIN
      SELECT d.resource_id, d.created_by_principal_id INTO found_resource, original_principal
      FROM content.document_versions AS d
      WHERE d.resource_version_id = version_id AND d.vault_id = owner_id
        AND d.classification = 'private';
      IF NOT FOUND THEN RETURN false; END IF;

      PERFORM pg_advisory_xact_lock_shared(hashtextextended(
        'singularity:authorization:' || original_principal::text || ':' || owner_id::text, 0));

      PERFORM 1 FROM content.resources AS r
      WHERE r.id = found_resource AND r.vault_id = owner_id
        AND r.classification = 'private' AND r.kind = 'document'
        AND r.deleted_at IS NULL AND r.current_version_id = version_id FOR UPDATE;
      IF NOT FOUND THEN RETURN false; END IF;

      SELECT * INTO found_document FROM content.document_versions AS d
      WHERE d.resource_version_id = version_id AND d.resource_id = found_resource
        AND d.vault_id = owner_id AND d.classification = 'private' FOR UPDATE;
      IF NOT FOUND OR found_document.state <> 'extracting'
        OR found_document.created_by_principal_id IS DISTINCT FROM original_principal
        OR found_document.attempt_deadline_at >= clock_timestamp()
        OR found_document.attempt_generation < 1
        OR found_document.attempt_generation = 9223372036854775807 THEN RETURN false; END IF;

      PERFORM 1 FROM identity.principals AS p
      JOIN identity.accounts AS a ON a.id = p.account_id
      JOIN core.vault_members AS m ON m.principal_id = p.id AND m.vault_id = owner_id
      JOIN core.principal_capabilities AS pc ON pc.principal_id = p.id AND pc.vault_id = owner_id
      JOIN core.capabilities AS c ON c.id = pc.capability_id AND c.name = 'asset.read'
      WHERE p.id = original_principal AND p.kind = 'owner' AND p.revoked_at IS NULL
        AND a.status = 'active' AND m.revoked_at IS NULL AND pc.revoked_at IS NULL
      FOR SHARE OF p, a, m, pc;
      IF NOT FOUND THEN RETURN false; END IF;

      PERFORM set_config('singularity.principal_id', original_principal::text, true);
      PERFORM set_config('singularity.vault_id', owner_id::text, true);
      SELECT auth.principal_authorization_epoch, auth.vault_authorization_epoch
      INTO principal_epoch, owner_epoch
      FROM core.live_principal_authorization() AS auth
      WHERE auth.principal_id = original_principal AND auth.vault_id = owner_id
        AND auth.principal_kind = 'owner' AND auth.principal_revoked_at IS NULL
        AND auth.membership_revoked_at IS NULL AND 'asset.read' = ANY(auth.capabilities);
      IF NOT FOUND THEN RETURN false; END IF;

      SELECT e.* INTO original_event FROM core.outbox_events AS e
      WHERE e.id = found_document.attempt_job_id;
      event_exists := FOUND;
      IF event_exists THEN
        IF (original_event.vault_id = owner_id
          AND original_event.principal_id = original_principal
          AND original_event.event_type = 'document.extraction_requested'
          AND original_event.required_capability = 'asset.read'
          AND original_event.classification = 'private' AND original_event.envelope_version = 1
          AND original_event.correlation_id IS NOT NULL
          AND original_event.expected_entity_revision = found_document.attempt_generation - 1
          AND original_event.principal_authorization_epoch >= 0
          AND original_event.vault_authorization_epoch >= 0
          AND original_event.principal_authorization_epoch = principal_epoch
          AND original_event.vault_authorization_epoch = owner_epoch
          AND original_event.payload = jsonb_build_object('resource_id', found_resource,
            'resource_version_id', version_id)
          AND original_event.idempotency_key = CASE WHEN found_document.attempt_generation = 1
            THEN 'document-extraction:' || version_id::text
            ELSE 'document-extraction:' || version_id::text || ':' ||
              (found_document.attempt_generation - 1)::text END
          AND ((original_event.retired_at IS NULL AND original_event.retirement_reason IS NULL)
            OR (original_event.retired_at IS NOT NULL
              AND original_event.retirement_reason = 'restore_effect_already_reflected')))
          IS NOT TRUE THEN RETURN false; END IF;

        SELECT s.* INTO original_submission FROM jobs.job_submissions s
        WHERE s.outbox_event_id = original_event.id;
        submission_exists := FOUND;
        IF NOT submission_exists THEN
          IF original_event.retired_at IS NOT NULL THEN RETURN false; END IF;
        ELSIF (original_submission.id = original_event.id
          AND original_submission.outbox_event_id = original_event.id
          AND original_submission.vault_id = owner_id
          AND original_submission.classification = 'private'
          AND original_submission.job_type = 'document_extract'
          AND original_submission.idempotency_key = original_event.idempotency_key)
          IS NOT TRUE THEN RETURN false; END IF;
      END IF;

      original_job := found_document.attempt_job_id;
      new_generation := found_document.attempt_generation + 1;
      recovered := content.recover_document_extraction(version_id, found_document.attempt_generation);
      INSERT INTO core.outbox_events (
        id, event_type, idempotency_key, vault_id, principal_id, required_capability,
        principal_authorization_epoch, vault_authorization_epoch, classification,
        correlation_id, causation_id, expected_entity_revision, envelope_version,
        payload, occurred_at)
      VALUES (
        gen_random_uuid(), 'document.extraction_requested',
        'document-extraction:' || version_id::text || ':' || new_generation::text,
        owner_id, original_principal, 'asset.read', principal_epoch, owner_epoch,
        'private', version_id, original_job, new_generation, 1,
        jsonb_build_object('resource_id', found_resource, 'resource_version_id', version_id),
        clock_timestamp());
      RETURN recovered.state = 'pending';
    END
    $function$
    """
  end

  defp retry do
    """
    CREATE OR REPLACE FUNCTION content.retry_document_runtime(requested_resource uuid, current_adapter text, current_format integer)
    RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE document content.document_versions%ROWTYPE;
      principal uuid := NULLIF(current_setting('singularity.principal_id',true),'')::uuid;
      owner uuid := NULLIF(current_setting('singularity.vault_id',true),'')::uuid;
      principal_epoch bigint; owner_epoch bigint; event_key text;
      original_event core.outbox_events%ROWTYPE; event_exists boolean;
      original_submission jobs.job_submissions%ROWTYPE; submission_exists boolean;
      expected_revision bigint; authorization_invalid boolean;
    BEGIN
      IF principal IS NOT NULL AND owner IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock_shared(hashtextextended(
          'singularity:authorization:' || principal::text || ':' || owner::text, 0));
      END IF;
      document := content.document_runtime_target(requested_resource,false);
      IF document.resource_id IS NULL THEN RETURN NULL; END IF;
      SELECT auth.principal_authorization_epoch,auth.vault_authorization_epoch
      INTO principal_epoch,owner_epoch FROM core.live_principal_authorization() auth
      WHERE auth.principal_id=principal AND auth.vault_id=document.vault_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Document runtime authority denied'
          USING ERRCODE='23514', CONSTRAINT='document_extraction_authority_check';
      END IF;

      IF document.state IN ('pending','extracting') THEN
        IF document.state = 'pending' THEN
          expected_revision := document.attempt_generation;
          event_key := CASE WHEN expected_revision = 0
            THEN 'document-extraction:' || document.resource_version_id::text
            ELSE 'document-extraction:' || document.resource_version_id::text || ':' || expected_revision::text END;
          SELECT e.* INTO original_event FROM core.outbox_events e
          WHERE e.vault_id=document.vault_id AND e.idempotency_key=event_key;
          event_exists := FOUND;
        ELSE
          expected_revision := document.attempt_generation - 1;
          SELECT e.* INTO original_event FROM core.outbox_events e
          WHERE e.id=document.attempt_job_id;
          event_exists := FOUND;
          event_key := CASE WHEN expected_revision = 0
            THEN 'document-extraction:' || document.resource_version_id::text
            ELSE 'document-extraction:' || document.resource_version_id::text || ':' || expected_revision::text END;
        END IF;

        IF NOT event_exists OR (original_event.vault_id = document.vault_id
          AND original_event.principal_id = principal
          AND original_event.principal_id = document.created_by_principal_id
          AND original_event.event_type = 'document.extraction_requested'
          AND original_event.required_capability = 'asset.read'
          AND original_event.classification = 'private' AND original_event.envelope_version = 1
          AND original_event.correlation_id IS NOT NULL
          AND original_event.expected_entity_revision = expected_revision AND expected_revision >= 0
          AND original_event.principal_authorization_epoch >= 0
          AND original_event.vault_authorization_epoch >= 0
          AND original_event.idempotency_key = event_key
          AND original_event.payload = jsonb_build_object('resource_id', document.resource_id,
            'resource_version_id', document.resource_version_id)
          AND ((original_event.retired_at IS NULL AND original_event.retirement_reason IS NULL)
            OR (original_event.retired_at IS NOT NULL AND original_event.retirement_reason IN (
              'restore_effect_already_reflected', 'restore_document_authorization_invalid'))))
          IS NOT TRUE THEN
          RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
            USING ERRCODE='23514', CONSTRAINT='document_extraction_conflict_check';
        END IF;

        SELECT s.* INTO original_submission FROM jobs.job_submissions s
        WHERE s.outbox_event_id=original_event.id;
        submission_exists := FOUND;
        IF submission_exists AND (original_submission.id = original_event.id
          AND original_submission.outbox_event_id = original_event.id
          AND original_submission.vault_id = document.vault_id
          AND original_submission.classification = 'private'
          AND original_submission.job_type = 'document_extract'
          AND original_submission.idempotency_key = original_event.idempotency_key)
          IS NOT TRUE THEN
          RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
            USING ERRCODE='23514', CONSTRAINT='document_extraction_conflict_check';
        END IF;

        authorization_invalid := original_event.principal_authorization_epoch <> principal_epoch
          OR original_event.vault_authorization_epoch <> owner_epoch
          OR original_event.retirement_reason = 'restore_document_authorization_invalid';
        IF document.state = 'pending' AND authorization_invalid IS NOT TRUE
          AND original_event.retired_at IS NULL THEN RETURN document.resource_id; END IF;

        IF authorization_invalid IS NOT TRUE OR NOT submission_exists
          OR (document.state = 'extracting' AND document.attempt_deadline_at >= clock_timestamp())
          OR (document.state = 'pending' AND original_event.retired_at IS NOT NULL
            AND original_event.retirement_reason <> 'restore_document_authorization_invalid') THEN
          RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
            USING ERRCODE='23514', CONSTRAINT='document_extraction_conflict_check';
        END IF;
      ELSIF document.state NOT IN ('failed','unsupported')
         OR (document.state='unsupported' AND document.extraction_adapter=current_adapter
             AND document.extraction_format=current_format) THEN
        RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
          USING ERRCODE='23514', CONSTRAINT='document_extraction_conflict_check';
      END IF;

      IF document.state = 'pending' THEN
        UPDATE content.document_versions SET attempt_generation=attempt_generation+1
        WHERE resource_version_id=document.resource_version_id
          AND attempt_generation=document.attempt_generation
          AND attempt_generation < 9223372036854775807
        RETURNING * INTO document;
      ELSE
        UPDATE content.document_versions SET state='pending', attempt_generation=attempt_generation+1,
          attempt_job_id=NULL, attempt_started_at=NULL, attempt_deadline_at=NULL,
          extraction_adapter=NULL, extraction_format=NULL, extracted_text_digest=NULL,
          detected_language=NULL, failure_code=NULL, attempt_finished_at=NULL
        WHERE resource_version_id=document.resource_version_id
          AND attempt_generation=document.attempt_generation
          AND attempt_generation < 9223372036854775807
        RETURNING * INTO document;
      END IF;
      IF document.resource_id IS NULL THEN
        RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
          USING ERRCODE='23514', CONSTRAINT='document_extraction_conflict_check';
      END IF;
      event_key := 'document-extraction:' || document.resource_version_id::text || ':' || document.attempt_generation::text;
      INSERT INTO core.outbox_events (
        id,event_type,idempotency_key,vault_id,principal_id,required_capability,
        principal_authorization_epoch,vault_authorization_epoch,classification,
        correlation_id,causation_id,expected_entity_revision,envelope_version,payload,occurred_at)
      VALUES (gen_random_uuid(),'document.extraction_requested',event_key,document.vault_id,principal,
        'asset.read',principal_epoch,owner_epoch,'private',gen_random_uuid(),NULL,
        document.attempt_generation,1,jsonb_build_object('resource_id',document.resource_id,
        'resource_version_id',document.resource_version_id),clock_timestamp());
      RETURN document.resource_id;
    END
    $function$
    """
  end
end
