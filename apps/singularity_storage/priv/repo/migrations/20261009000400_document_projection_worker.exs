defmodule Singularity.Storage.Migrations.DocumentProjectionWorker do
  use Ecto.Migration

  @signature "content.reconcile_document_search_worker(uuid,uuid,uuid,bigint,bigint,bigint)"

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    CREATE FUNCTION content.reconcile_document_search_worker(
      requested_resource uuid, requested_version uuid, requested_job uuid,
      expected_revision bigint, requested_principal_epoch bigint, requested_owner_epoch bigint)
    RETURNS bigint LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE scoped_principal uuid; scoped_owner uuid;
    BEGIN
      IF current_setting('transaction_isolation') <> 'read committed'
         OR requested_resource IS NULL OR requested_version IS NULL OR requested_job IS NULL
         OR expected_revision IS NULL OR expected_revision < 0
         OR requested_principal_epoch IS NULL OR requested_principal_epoch < 0
         OR requested_owner_epoch IS NULL OR requested_owner_epoch < 0 THEN
        RAISE EXCEPTION 'invalid Document projection input' USING ERRCODE='23514';
      END IF;
      BEGIN
        scoped_principal := nullif(current_setting('singularity.principal_id',true),'')::uuid;
        scoped_owner := nullif(current_setting('singularity.vault_id',true),'')::uuid;
      EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Document projection is not authorized' USING ERRCODE='42501';
      END;
      IF scoped_principal IS NULL OR scoped_owner IS NULL THEN
        RAISE EXCEPTION 'Document projection is not authorized' USING ERRCODE='42501';
      END IF;

      PERFORM pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended(
        'singularity:authorization:' || scoped_principal::text || ':' || scoped_owner::text, 0));
      IF NOT EXISTS (
        SELECT 1 FROM core.live_principal_authorization() auth
        WHERE auth.principal_id=scoped_principal AND auth.vault_id=scoped_owner
          AND auth.principal_kind='owner' AND auth.principal_revoked_at IS NULL
          AND auth.membership_revoked_at IS NULL
          AND auth.clearance IN ('private','sensitive','restricted')
          AND 'asset.read'=ANY(auth.capabilities)
          AND auth.principal_authorization_epoch=requested_principal_epoch
          AND auth.vault_authorization_epoch=requested_owner_epoch
      ) THEN
        RAISE EXCEPTION 'Document projection is not authorized' USING ERRCODE='42501';
      END IF;

      PERFORM 1 FROM content.resources resource
      WHERE resource.id=requested_resource AND resource.vault_id=scoped_owner
        AND resource.classification='private' AND resource.kind='document'
      FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Document projection is not authorized' USING ERRCODE='42501';
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM content.document_versions document
        JOIN content.resource_versions version ON version.id=document.resource_version_id
          AND version.resource_id=document.resource_id AND version.vault_id=document.vault_id
          AND version.classification=document.classification
        JOIN core.outbox_events event ON event.id=requested_job
          AND event.vault_id=document.vault_id AND event.principal_id=scoped_principal
        WHERE document.resource_id=requested_resource AND document.resource_version_id=requested_version
          AND document.vault_id=scoped_owner AND document.classification='private'
          AND document.created_by_principal_id=scoped_principal
          AND event.event_type IN ('document.ready','document.deleted','document.restored')
          AND event.required_capability='asset.read' AND event.classification='private'
          AND event.envelope_version=1 AND event.retired_at IS NULL
          AND event.principal_authorization_epoch=requested_principal_epoch
          AND event.vault_authorization_epoch=requested_owner_epoch
          AND event.expected_entity_revision=expected_revision
          AND event.idempotency_key='document-projection:' || requested_job::text
          AND event.payload=jsonb_build_object('resource_id',requested_resource::text,
            'resource_version_id',requested_version::text)
      ) THEN
        RAISE EXCEPTION 'Document projection is not authorized' USING ERRCODE='42501';
      END IF;

      RETURN content.reconcile_search_resource_internal(scoped_owner,requested_resource);
    END
    $function$
    """)

    execute("ALTER FUNCTION #{@signature} OWNER TO singularity_table_owner")

    execute("""
    REVOKE ALL ON FUNCTION #{@signature}
      FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth
    """)

    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO singularity_worker")
    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "Document projection worker migration is forward-only")
end
