defmodule Singularity.Storage.Migrations.KnowledgeRestoreWorkValidation do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    CREATE OR REPLACE FUNCTION audit.knowledge_restore_payload_is_valid(e core.outbox_events)
    RETURNS boolean LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=pg_catalog
    AS $function$
    DECLARE asset_id text; object_id text; payload_resource_id text; version_id text;
      prefix text; capability text; parts text[]; revision bigint:=e.expected_entity_revision;
      conflict_event boolean; valid_key boolean;
    BEGIN
      IF e.envelope_version<>1 OR revision<0 OR e.principal_authorization_epoch<0
        OR e.vault_authorization_epoch<0 OR pg_catalog.jsonb_typeof(e.payload) IS DISTINCT FROM 'object' THEN
        RETURN false;
      END IF;
      CASE e.event_type
      WHEN 'asset.finalize_requested' THEN prefix:='asset-finalize'; capability:='asset.write';
      WHEN 'asset.verify_requested' THEN prefix:='asset-verify'; capability:='asset.write';
      WHEN 'asset.metadata_requested' THEN prefix:='asset-metadata'; capability:='asset.read';
      WHEN 'asset.cleanup_requested' THEN prefix:='asset-cleanup'; capability:='asset.write';
      WHEN 'object.cleanup_requested' THEN
        asset_id:=e.payload->>'asset_id'; object_id:=e.payload->>'object_id';
        RETURN e.payload=pg_catalog.jsonb_build_object('asset_id',asset_id,'object_id',object_id)
          AND e.required_capability='object.cleanup'
          AND EXISTS(SELECT 1 FROM content.assets a WHERE a.id::text=asset_id
            AND (a.vault_id,a.classification)=(e.vault_id,e.classification))
          AND EXISTS(SELECT 1 FROM content.asset_objects o WHERE o.id::text=object_id
            AND (o.vault_id,o.classification)=(e.vault_id,e.classification))
          AND e.idempotency_key IN (
            'object-cleanup:'||object_id||':'||revision::text,
            'object-cleanup:'||object_id||':authority:'||e.principal_authorization_epoch::text||
              ':'||e.vault_authorization_epoch::text||':revision:'||revision::text);
      WHEN 'backup.requested' THEN
        version_id:=e.payload->>'pending_manifest_id';
        RETURN e.required_capability='backup.create'
          AND version_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          AND e.payload=pg_catalog.jsonb_build_object('pending_manifest_id',version_id)
          AND e.idempotency_key='backup:'||version_id;
      WHEN 'document.extraction_requested' THEN
        payload_resource_id:=e.payload->>'resource_id'; version_id:=e.payload->>'resource_version_id';
        RETURN e.required_capability='asset.read' AND e.classification='private'
          AND e.payload=pg_catalog.jsonb_build_object('resource_id',payload_resource_id,'resource_version_id',version_id)
          AND EXISTS(SELECT 1 FROM content.document_versions d WHERE d.resource_id::text=payload_resource_id
            AND d.resource_version_id::text=version_id AND (d.vault_id,d.classification)=(e.vault_id,e.classification)
            AND revision<=d.attempt_generation)
          AND e.idempotency_key=CASE WHEN revision=0 THEN 'document-extraction:'||version_id
            ELSE 'document-extraction:'||version_id||':'||revision::text END;
      WHEN 'document.ready','document.deleted','document.restored' THEN
        payload_resource_id:=e.payload->>'resource_id'; version_id:=e.payload->>'resource_version_id';
        RETURN e.required_capability='asset.read' AND e.classification='private'
          AND e.payload=pg_catalog.jsonb_build_object('resource_id',payload_resource_id,'resource_version_id',version_id)
          AND EXISTS(SELECT 1 FROM content.document_versions d WHERE d.resource_id::text=payload_resource_id
            AND d.resource_version_id::text=version_id AND (d.vault_id,d.classification)=(e.vault_id,e.classification))
          AND e.idempotency_key='document-projection:'||e.id::text;
      WHEN 'note.current_changed','note.conflict_created','note.conflict_resolved','note.deleted','note.restored' THEN
        payload_resource_id:=e.payload->>'resource_id';
        conflict_event:=e.event_type IN ('note.conflict_created','note.conflict_resolved');
        IF e.required_capability<>'note.write' OR e.classification<>'private'
          OR NOT EXISTS(SELECT 1 FROM content.resources r WHERE r.id::text=payload_resource_id
            AND (r.vault_id,r.classification,r.kind)=(e.vault_id,'private','note')) THEN RETURN false; END IF;
        IF conflict_event THEN
          IF e.payload<>pg_catalog.jsonb_build_object('resource_id',payload_resource_id,'conflict_id',e.payload->>'conflict_id')
            OR NOT EXISTS(SELECT 1 FROM content.note_conflicts c WHERE c.id::text=e.payload->>'conflict_id'
              AND c.resource_id::text=payload_resource_id AND c.vault_id=e.vault_id) THEN RETURN false; END IF;
        ELSIF e.payload<>pg_catalog.jsonb_build_object('resource_id',payload_resource_id) THEN RETURN false;
        END IF;
        parts:=pg_catalog.string_to_array(e.idempotency_key,':');
        IF pg_catalog.cardinality(parts)<>3 OR parts[2] IS DISTINCT FROM payload_resource_id THEN RETURN false; END IF;
        IF parts[1] IN ('note-current-changed','note-conflict-created','note-conflict-resolved') THEN
          RETURN audit.knowledge_restore_integer_text(parts[3],revision);
        END IF;
        RETURN parts[1] IN ('note-deleted','note-restored')
          AND parts[3] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
      ELSE RETURN false;
      END CASE;
      asset_id:=e.payload->>'asset_id';
      IF e.payload IS DISTINCT FROM pg_catalog.jsonb_build_object('asset_id',asset_id)
        OR NOT EXISTS(SELECT 1 FROM content.assets a WHERE a.id::text=asset_id
          AND (a.vault_id,a.classification)=(e.vault_id,e.classification)) THEN RETURN false; END IF;
      IF e.event_type='asset.verify_requested' AND e.required_capability='assets.verify'
        AND e.idempotency_key='sealed-upload:'||asset_id THEN RETURN true; END IF;
      IF e.required_capability<>capability THEN RETURN false; END IF;
      valid_key:=e.idempotency_key=prefix||':'||asset_id||':'||revision::text;
      IF NOT valid_key AND e.event_type<>'asset.metadata_requested' THEN
        parts:=pg_catalog.string_to_array(e.idempotency_key,':');
        IF pg_catalog.cardinality(parts)=4 AND parts[1]='asset-retry' AND parts[2]=asset_id
          AND audit.knowledge_restore_integer_text(parts[3],revision)
          AND parts[4] ~ '^[+]?[0-9]+$' THEN
          -- Canonical positive integer text, without a bounded numeric cast.
          valid_key:=pg_catalog.regexp_replace(parts[4],'^[+]?0*','')<>'';
        END IF;
      END IF;
      RETURN valid_key;
    END
    $function$
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "knowledge restore work validation is forward-only")
end
