defmodule Singularity.Storage.Migrations.DocumentCustodyBinding do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    CREATE FUNCTION content.document_custody_binding(
      requested_owner uuid, requested_principal uuid, requested_version uuid,
      requested_object uuid, requested_generation bigint, requested_access text,
      requested_job uuid, requested_session uuid,
      requested_principal_epoch bigint, requested_owner_epoch bigint
    ) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
      SELECT
        requested_owner IS NOT NULL AND requested_principal IS NOT NULL
        AND requested_version IS NOT NULL AND requested_object IS NOT NULL
        AND requested_generation > 0
        AND requested_principal_epoch >= 0 AND requested_owner_epoch >= 0
        AND NULLIF(current_setting('singularity.principal_id', true), '')::uuid = requested_principal
        AND NULLIF(current_setting('singularity.vault_id', true), '')::uuid = requested_owner
        AND EXISTS (
          SELECT 1 FROM core.live_principal_authorization() AS auth
          WHERE auth.principal_id = requested_principal
            AND auth.vault_id = requested_owner
            AND auth.principal_kind = 'owner'
            AND auth.principal_revoked_at IS NULL
            AND auth.membership_revoked_at IS NULL
            AND auth.vault_locked = false
            AND auth.clearance IN ('private', 'sensitive', 'restricted')
            AND auth.principal_authorization_epoch = requested_principal_epoch
            AND auth.vault_authorization_epoch = requested_owner_epoch
            AND 'asset.read' = ANY(auth.capabilities)
        )
        AND requested_session IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM identity.sessions AS s
          JOIN identity.credentials AS c
            ON c.id = s.credential_id AND c.account_id = s.account_id
          WHERE s.id = requested_session
            AND s.principal_id = requested_principal
            AND s.vault_id = requested_owner
            AND s.revoked_at IS NULL AND s.expires_at > clock_timestamp()
            AND c.revoked_at IS NULL
        )
        AND EXISTS (
          SELECT 1
          FROM content.document_versions AS d
          JOIN content.resources AS r
            ON r.id = d.resource_id AND r.vault_id = d.vault_id
              AND r.classification = d.classification AND r.kind = 'document'
          JOIN content.asset_objects AS o
            ON o.id = d.source_object_id AND o.vault_id = d.vault_id
              AND o.classification = d.classification
          JOIN content.asset_key_envelopes AS k
            ON k.asset_object_id = o.id AND k.vault_id = o.vault_id
              AND k.classification = o.classification
              AND k.key_generation = requested_generation
          WHERE d.resource_version_id = requested_version
            AND d.vault_id = requested_owner AND d.classification = 'private'
            AND d.created_by_principal_id = requested_principal
            AND d.source_object_id = requested_object
            AND d.source_byte_size = o.plaintext_byte_size
            AND d.source_byte_size BETWEEN 0 AND 67108864
            AND o.lifecycle = 'available'
            AND (
              (requested_access = 'request'
                AND requested_job IS NULL AND requested_session IS NOT NULL
                AND r.deleted_at IS NULL)
              OR
              (requested_access = 'worker'
                AND requested_job IS NOT NULL
                AND EXISTS (
                  SELECT 1 FROM core.outbox_events AS e
                  WHERE e.id = requested_job AND e.vault_id = requested_owner
                    AND e.principal_id = requested_principal
                    AND e.event_type = 'document.extraction_requested'
                    AND e.required_capability = 'asset.read'
                    AND e.classification = 'private'
                    AND e.principal_authorization_epoch = requested_principal_epoch
                    AND e.vault_authorization_epoch = requested_owner_epoch
                    AND e.payload = jsonb_build_object(
                      'resource_id', d.resource_id,
                      'resource_version_id', d.resource_version_id)
                    AND (
                      (d.state = 'pending' AND r.deleted_at IS NULL
                        AND e.expected_entity_revision = d.attempt_generation)
                      OR
                      (d.state = 'extracting' AND d.attempt_job_id = requested_job
                        AND d.attempt_deadline_at > clock_timestamp())
                    )
                ))
            )
        )
    $function$
    """)

    execute("""
    REVOKE ALL ON FUNCTION content.document_custody_binding(
      uuid,uuid,uuid,uuid,bigint,text,uuid,uuid,bigint,bigint
    ) FROM PUBLIC, singularity_web, singularity_dispatcher, singularity_pre_auth
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION content.document_custody_binding(
      uuid,uuid,uuid,uuid,bigint,text,uuid,uuid,bigint,bigint
    ) TO singularity_worker
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "Document custody binding migration is forward-only")
end
