defmodule Singularity.Storage.Migrations.DocumentExtractionRecovery do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    CREATE INDEX document_versions_expired_extraction
    ON content.document_versions(attempt_deadline_at, resource_version_id)
    WHERE state = 'extracting'
    """)

    execute("""
    CREATE FUNCTION content.expired_document_extraction_ids(batch_limit integer)
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
          AND r.kind = 'document' AND r.deleted_at IS NULL
        JOIN identity.principals AS p ON p.id = d.created_by_principal_id
          AND p.kind = 'owner' AND p.revoked_at IS NULL
        JOIN identity.accounts AS a ON a.id = p.account_id AND a.status = 'active'
        JOIN core.vault_members AS m ON m.principal_id = p.id AND m.vault_id = d.vault_id
          AND m.revoked_at IS NULL
        WHERE d.state = 'extracting' AND d.attempt_deadline_at < clock_timestamp()
          AND EXISTS (
            SELECT 1 FROM core.principal_capabilities AS pc
            JOIN core.capabilities AS c ON c.id = pc.capability_id
            WHERE pc.principal_id = p.id AND pc.vault_id = d.vault_id
              AND pc.revoked_at IS NULL AND c.name = 'asset.read')
        ORDER BY d.attempt_deadline_at, d.resource_version_id
        LIMIT batch_limit;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.recover_expired_document_with_event(version_id uuid, owner_id uuid)
    RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE found_document content.document_versions%ROWTYPE;
      found_resource uuid; original_job uuid; new_generation bigint;
      original_principal uuid; principal_epoch bigint; owner_epoch bigint;
      recovered content.document_versions%ROWTYPE;
    BEGIN
      -- Read identity only; the resource-before-version locks match guarded lifecycle order.
      SELECT d.resource_id, d.created_by_principal_id INTO found_resource, original_principal
      FROM content.document_versions AS d
      WHERE d.resource_version_id = version_id AND d.vault_id = owner_id
        AND d.classification = 'private';
      IF NOT FOUND THEN RETURN false; END IF;

      PERFORM 1 FROM content.resources AS r
      WHERE r.id = found_resource AND r.vault_id = owner_id
        AND r.classification = 'private' AND r.kind = 'document'
        AND r.deleted_at IS NULL FOR UPDATE;
      IF NOT FOUND THEN RETURN false; END IF;

      SELECT * INTO found_document FROM content.document_versions AS d
      WHERE d.resource_version_id = version_id AND d.resource_id = found_resource
        AND d.vault_id = owner_id AND d.classification = 'private' FOR UPDATE;
      IF NOT FOUND OR found_document.state <> 'extracting'
        OR found_document.attempt_deadline_at >= clock_timestamp()
        OR found_document.attempt_generation = 9223372036854775807 THEN
        RETURN false;
      END IF;

      PERFORM 1 FROM identity.principals AS p
      JOIN identity.accounts AS a ON a.id = p.account_id
      JOIN core.vault_members AS m ON m.principal_id = p.id AND m.vault_id = owner_id
      JOIN core.principal_capabilities AS pc ON pc.principal_id = p.id AND pc.vault_id = owner_id
      JOIN core.capabilities AS c ON c.id = pc.capability_id AND c.name = 'asset.read'
      WHERE p.id = original_principal AND p.kind = 'owner' AND p.revoked_at IS NULL
        AND a.status = 'active' AND m.revoked_at IS NULL AND pc.revoked_at IS NULL
      FOR SHARE OF p, a, m, pc;
      IF NOT FOUND THEN RETURN false; END IF;

      -- The original creator, never a fabricated system principal, authors the successor.
      PERFORM set_config('singularity.principal_id', original_principal::text, true);
      PERFORM set_config('singularity.vault_id', owner_id::text, true);
      SELECT auth.principal_authorization_epoch, auth.vault_authorization_epoch
      INTO principal_epoch, owner_epoch
      FROM core.live_principal_authorization() AS auth
      WHERE auth.principal_id = original_principal AND auth.vault_id = owner_id
        AND auth.principal_kind = 'owner' AND auth.principal_revoked_at IS NULL
        AND auth.membership_revoked_at IS NULL AND 'asset.read' = ANY(auth.capabilities);
      IF NOT FOUND THEN RETURN false; END IF;

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
        'private', version_id, original_job, 0, 1,
        jsonb_build_object('resource_id', found_resource, 'resource_version_id', version_id),
        clock_timestamp());
      RETURN recovered.state = 'pending';
    END
    $function$
    """)

    for signature <- [
          "expired_document_extraction_ids(integer)",
          "recover_expired_document_with_event(uuid,uuid)"
        ] do
      execute(
        "REVOKE ALL ON FUNCTION content.#{signature} FROM PUBLIC, singularity_web, singularity_dispatcher, singularity_pre_auth"
      )

      execute("GRANT EXECUTE ON FUNCTION content.#{signature} TO singularity_worker")
    end

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "Document extraction recovery migration is forward-only")
end
