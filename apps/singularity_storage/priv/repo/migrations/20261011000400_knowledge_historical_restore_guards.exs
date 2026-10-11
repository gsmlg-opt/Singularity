defmodule Singularity.Storage.Migrations.KnowledgeHistoricalRestoreGuards do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")
    replace_document_source_guard()
    replace_document_fragment_guard()
    replace_note_source_guard()
    replace_organization_guard()
    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "knowledge historical restore guards are forward-only")

  defp replace_document_source_guard do
    execute("""
    CREATE OR REPLACE FUNCTION content.enforce_document_source()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, content
    AS $function$
    DECLARE accepted_object_id uuid; historical boolean;
    BEGIN
      historical := audit.knowledge_restore_is_bound(NEW.vault_id);
      -- Preserve Asset/object acquisition before Resource/version/association.
      SELECT asset_object_id INTO accepted_object_id FROM content.assets
      WHERE id = NEW.source_asset_id AND vault_id = NEW.vault_id FOR SHARE;
      PERFORM 1 FROM content.asset_objects WHERE id = accepted_object_id FOR SHARE;
      IF historical AND accepted_object_id IS NULL THEN
        PERFORM 1 FROM content.asset_objects WHERE id = NEW.source_object_id FOR SHARE;
      END IF;
      PERFORM 1 FROM content.resources WHERE id = NEW.source_resource_id FOR SHARE;
      PERFORM 1 FROM content.resource_versions WHERE id = NEW.source_resource_version_id FOR SHARE;
      PERFORM 1 FROM content.resource_assets
      WHERE resource_version_id = NEW.source_resource_version_id AND asset_id = NEW.source_asset_id
      FOR SHARE;

      IF historical THEN
        IF NEW.classification IS DISTINCT FROM 'private'
          OR NOT EXISTS (
            SELECT 1 FROM content.resources r JOIN content.resource_versions v
              ON (v.resource_id,v.vault_id,v.classification)=(r.id,r.vault_id,r.classification)
            WHERE (v.id,r.id,r.vault_id,r.classification)=
              (NEW.resource_version_id,NEW.resource_id,NEW.vault_id,'private') AND r.kind='document'
          ) OR (SELECT count(*) FROM content.assets
            WHERE resource_version_id=NEW.source_resource_version_id)<>1 THEN
          RAISE EXCEPTION 'invalid historical Document source identity'
            USING ERRCODE='23514',CONSTRAINT='document_versions_source_check';
        END IF;
        PERFORM 1
        FROM content.resources AS resource
        JOIN content.resource_versions AS version
          ON (version.resource_id,version.vault_id,version.classification)=
            (resource.id,resource.vault_id,resource.classification)
        JOIN content.assets AS asset
          ON (asset.resource_version_id,asset.vault_id,asset.classification)=
            (version.id,version.vault_id,version.classification)
        JOIN content.resource_assets AS association
          ON (association.resource_version_id,association.asset_id,association.vault_id,association.classification)=
            (version.id,asset.id,asset.vault_id,asset.classification)
        JOIN content.asset_objects AS object
          ON (object.id,object.vault_id,object.classification)=
            (NEW.source_object_id,asset.vault_id,asset.classification)
        WHERE (resource.id,resource.vault_id,resource.classification)=
            (NEW.source_resource_id,NEW.vault_id,'private') AND resource.kind='asset'
          AND version.id=NEW.source_resource_version_id AND asset.id=NEW.source_asset_id
          AND (asset.asset_object_id IS NULL OR asset.asset_object_id=object.id)
          AND object.lifecycle='available' AND object.deleted_at IS NULL
          AND object.plaintext_byte_size=NEW.source_byte_size;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'invalid historical Document source identity'
            USING ERRCODE='23514',CONSTRAINT='document_versions_source_check';
        END IF;
      ELSE
        PERFORM 1
        FROM content.resources AS resource
        JOIN content.resource_versions AS version
          ON (version.resource_id, version.vault_id, version.classification)
           = (resource.id, resource.vault_id, resource.classification)
        JOIN content.assets AS asset
          ON asset.resource_version_id = version.id AND asset.vault_id = version.vault_id
        JOIN content.resource_assets AS association
          ON (association.resource_version_id, association.asset_id, association.vault_id)
           = (version.id, asset.id, asset.vault_id)
        JOIN content.asset_objects AS object
          ON (object.id, object.vault_id) = (asset.asset_object_id, asset.vault_id)
        WHERE resource.id = NEW.source_resource_id
          AND resource.kind = 'asset' AND resource.classification = 'private'
          AND resource.deleted_at IS NULL AND resource.vault_id = NEW.vault_id
          AND version.id = NEW.source_resource_version_id AND version.classification = 'private'
          AND asset.id = NEW.source_asset_id AND asset.classification = 'private'
          AND asset.state IN ('available', 'processing', 'ready')
          AND association.released_at IS NULL AND association.classification = 'private'
          AND object.id = NEW.source_object_id AND object.classification = 'private'
          AND object.lifecycle = 'available' AND object.deleted_at IS NULL
          AND object.plaintext_byte_size = NEW.source_byte_size;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Document source is not the accepted live Asset tuple'
            USING ERRCODE = '23514', CONSTRAINT = 'document_versions_source_check';
        END IF;
      END IF;
      RETURN NEW;
    END
    $function$
    """)
  end

  defp replace_document_fragment_guard do
    execute("""
    CREATE OR REPLACE FUNCTION content.enforce_document_fragment() RETURNS trigger
    LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, content
    AS $function$
    DECLARE document content.document_versions%ROWTYPE; historical boolean;
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'Document fragments are immutable'
          USING ERRCODE = '23514', CONSTRAINT = 'document_fragments_immutable_check';
      END IF;
      IF current_user <> 'singularity_table_owner' THEN
        RAISE EXCEPTION 'Document fragments require guarded completion'
          USING ERRCODE = '23514', CONSTRAINT = 'document_fragments_immutable_check';
      END IF;
      -- Runtime invokers must be rejected before calling the private helper.
      historical := audit.knowledge_restore_is_bound(NEW.vault_id);
      PERFORM 1 FROM content.resources WHERE id = NEW.resource_id FOR UPDATE;
      SELECT * INTO document FROM content.document_versions WHERE resource_version_id = NEW.resource_version_id FOR UPDATE;
      IF historical THEN
        IF document.resource_version_id IS NULL OR document.state IS DISTINCT FROM 'ready'
          OR (document.resource_version_id,document.resource_id,document.vault_id,document.classification)
            IS DISTINCT FROM (NEW.resource_version_id,NEW.resource_id,NEW.vault_id,NEW.classification)
          OR NEW.classification IS DISTINCT FROM 'private'
          OR NOT EXISTS(SELECT 1 FROM content.resources r JOIN content.resource_versions v
            ON (v.resource_id,v.vault_id,v.classification)=(r.id,r.vault_id,r.classification)
            WHERE (v.id,r.id,r.vault_id,r.classification)=
              (NEW.resource_version_id,NEW.resource_id,NEW.vault_id,'private') AND r.kind='document') THEN
          RAISE EXCEPTION 'invalid historical Document fragment identity'
            USING ERRCODE='23514',CONSTRAINT='document_fragments_insert_state_check';
        END IF;
      ELSE
        IF document.state = 'ready' THEN
          RAISE EXCEPTION 'Document completion is sealed'
            USING ERRCODE = '23514', CONSTRAINT = 'document_fragments_insert_state_check';
        END IF;
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
  end

  defp replace_note_source_guard do
    execute("""
    CREATE OR REPLACE FUNCTION content.enforce_note_source_set() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,content
    AS $function$
    DECLARE target_id uuid; target_version_id uuid; target_kind text; locked_id uuid;
      accepted_asset_id uuid; accepted_object_id uuid; amount bigint; last_ordinal bigint; retained boolean;
      historical boolean;
    BEGIN
      historical := audit.knowledge_restore_is_bound(NEW.vault_id);
      IF TG_TABLE_NAME='note_attachments' THEN
        target_id:=NEW.target_resource_id; target_version_id:=NEW.target_resource_version_id; target_kind:=NEW.target_kind;
        SELECT EXISTS(SELECT 1 FROM content.note_versions n
          JOIN content.note_versions p ON p.resource_version_id IN (n.parent_version_id,n.merge_parent_version_id)
          JOIN content.note_attachments a ON a.note_resource_version_id=p.resource_version_id
          WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=(NEW.note_resource_version_id,NEW.note_resource_id,NEW.vault_id,'private')
            AND content.note_source_parent_is_valid(n.resource_version_id,p.resource_version_id)
            AND (a.note_resource_id,a.vault_id,a.classification)=(p.resource_id,p.vault_id,'private')
            AND (a.id,a.target_resource_id,a.target_resource_version_id,a.target_kind,a.role,a.label)
              IS NOT DISTINCT FROM (NEW.id,NEW.target_resource_id,NEW.target_resource_version_id,NEW.target_kind,NEW.role,NEW.label)) INTO retained;
      ELSE
        target_id:=NEW.source_resource_id; target_version_id:=NEW.source_resource_version_id; target_kind:='document';
        SELECT EXISTS(SELECT 1 FROM content.note_versions n
          JOIN content.note_versions p ON p.resource_version_id IN (n.parent_version_id,n.merge_parent_version_id)
          JOIN content.note_citations c ON c.note_resource_version_id=p.resource_version_id
          WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=(NEW.note_resource_version_id,NEW.note_resource_id,NEW.vault_id,'private')
            AND content.note_source_parent_is_valid(n.resource_version_id,p.resource_version_id)
            AND (c.note_resource_id,c.vault_id,c.classification)=(p.resource_id,p.vault_id,'private')
            AND (c.id,c.source_resource_id,c.source_resource_version_id,c.fragment_id,c.locator)
              IS NOT DISTINCT FROM (NEW.id,NEW.source_resource_id,NEW.source_resource_version_id,NEW.fragment_id,NEW.locator)) INTO retained;
      END IF;
      IF target_kind='asset' THEN
        SELECT id,asset_object_id INTO accepted_asset_id,accepted_object_id FROM content.assets
          WHERE resource_version_id=target_version_id AND vault_id=NEW.vault_id FOR SHARE;
        PERFORM 1 FROM content.asset_objects WHERE id=accepted_object_id FOR SHARE;
      END IF;
      FOR locked_id IN SELECT id FROM content.resources WHERE id IN (NEW.note_resource_id,target_id) ORDER BY id FOR UPDATE LOOP
        PERFORM pg_advisory_xact_lock(hashtextextended('singularity.note.aggregate:' || locked_id::text,0));
      END LOOP;
      PERFORM 1 FROM content.resource_versions WHERE id=target_version_id FOR SHARE;
      IF target_kind='asset' THEN
        PERFORM 1 FROM content.resource_assets WHERE resource_version_id=target_version_id AND asset_id=accepted_asset_id FOR SHARE;
      END IF;
      IF historical THEN
        IF NEW.classification IS DISTINCT FROM 'private'
          OR NOT EXISTS(SELECT 1 FROM content.resources r JOIN content.note_versions n
            ON (n.resource_id,n.vault_id,n.classification)=(r.id,r.vault_id,r.classification)
            JOIN content.resource_versions v ON (v.id,v.resource_id,v.vault_id,v.classification)=
              (n.resource_version_id,n.resource_id,n.vault_id,n.classification)
            WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=
              (NEW.note_resource_version_id,NEW.note_resource_id,NEW.vault_id,'private') AND r.kind='note')
          OR NOT EXISTS(SELECT 1 FROM content.resources r JOIN content.resource_versions v
            ON (v.resource_id,v.vault_id,v.classification)=(r.id,r.vault_id,r.classification)
            WHERE (v.id,v.resource_id,v.vault_id,v.classification)=
              (target_version_id,target_id,NEW.vault_id,'private') AND r.kind=target_kind) THEN
          RAISE EXCEPTION 'invalid historical Note source identity'
            USING ERRCODE='23514',CONSTRAINT=TG_TABLE_NAME || '_source_check';
        END IF;
        IF (target_kind='note' AND NOT EXISTS(SELECT 1 FROM content.note_versions
            WHERE (resource_version_id,resource_id,vault_id,classification)=
              (target_version_id,target_id,NEW.vault_id,'private')))
          OR (target_kind='document' AND NOT EXISTS(SELECT 1 FROM content.document_versions
            WHERE (resource_version_id,resource_id,vault_id,classification)=
              (target_version_id,target_id,NEW.vault_id,'private') AND state='ready'))
          OR (target_kind='asset' AND ((SELECT count(*) FROM content.assets
              WHERE resource_version_id=target_version_id)<>1 OR NOT EXISTS(
            SELECT 1 FROM content.assets a JOIN content.resource_assets ra
              ON (ra.asset_id,ra.resource_version_id,ra.vault_id,ra.classification)=
                (a.id,a.resource_version_id,a.vault_id,a.classification)
            WHERE (a.id,a.resource_version_id,a.vault_id,a.classification)=
              (accepted_asset_id,target_version_id,NEW.vault_id,'private')))) THEN
          RAISE EXCEPTION 'invalid historical Note source identity'
            USING ERRCODE='23514',CONSTRAINT=TG_TABLE_NAME || '_source_check';
        END IF;
      ELSE
        IF NOT EXISTS(SELECT 1 FROM content.resources r JOIN content.note_versions n
            ON (n.resource_id,n.vault_id,n.classification)=(r.id,r.vault_id,r.classification)
            WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=(NEW.note_resource_version_id,NEW.note_resource_id,NEW.vault_id,'private')
              AND r.kind='note' AND r.deleted_at IS NULL)
          OR NOT EXISTS(SELECT 1 FROM content.resources r JOIN content.resource_versions v
            ON (v.resource_id,v.vault_id,v.classification)=(r.id,r.vault_id,r.classification)
            WHERE (v.id,v.resource_id,v.vault_id,v.classification)=(target_version_id,target_id,NEW.vault_id,'private')
              AND r.kind=target_kind AND (retained OR r.deleted_at IS NULL)) THEN
          RAISE EXCEPTION 'invalid Note source identity'
            USING ERRCODE='23514',CONSTRAINT=TG_TABLE_NAME || '_source_check';
        END IF;
        IF (target_kind='note' AND NOT EXISTS(SELECT 1 FROM content.note_versions WHERE (resource_version_id,resource_id,vault_id,classification)=(target_version_id,target_id,NEW.vault_id,'private')))
          OR (target_kind='document' AND NOT EXISTS(SELECT 1 FROM content.document_versions WHERE (resource_version_id,resource_id,vault_id,classification)=(target_version_id,target_id,NEW.vault_id,'private') AND (retained OR state='ready')))
          OR (target_kind='asset' AND NOT retained AND NOT EXISTS(
            SELECT 1 FROM content.assets a JOIN content.asset_objects o ON (o.id,o.vault_id)=(a.asset_object_id,a.vault_id)
            JOIN content.resource_assets ra ON (ra.asset_id,ra.resource_version_id,ra.vault_id)=(a.id,a.resource_version_id,a.vault_id)
            WHERE a.id=accepted_asset_id AND a.resource_version_id=target_version_id AND a.vault_id=NEW.vault_id
              AND a.classification='private' AND a.state IN ('available','processing','ready')
              AND o.classification='private' AND o.lifecycle='available' AND o.deleted_at IS NULL
              AND ra.classification='private' AND ra.released_at IS NULL)) THEN
          RAISE EXCEPTION 'Note source is not ready'
            USING ERRCODE='23514',CONSTRAINT=TG_TABLE_NAME || '_source_check';
        END IF;
      END IF;
      IF TG_TABLE_NAME='note_citations' THEN
        IF NOT EXISTS(SELECT 1 FROM content.document_fragments
          WHERE (id,resource_id,resource_version_id,vault_id,classification)=(NEW.fragment_id,target_id,target_version_id,NEW.vault_id,'private') AND locator=NEW.locator) THEN
          RAISE EXCEPTION 'Note citation locator does not match its fragment'
            USING ERRCODE='23514',CONSTRAINT='note_citations_locator_check';
        END IF;
        SELECT count(*),max(ordinal) INTO amount,last_ordinal FROM content.note_citations WHERE note_resource_version_id=NEW.note_resource_version_id;
      ELSE
        SELECT count(*),max(ordinal) INTO amount,last_ordinal FROM content.note_attachments WHERE note_resource_version_id=NEW.note_resource_version_id;
      END IF;
      IF last_ordinal IS DISTINCT FROM amount-1 THEN
        RAISE EXCEPTION 'Note source order is incomplete'
          USING ERRCODE='23514',CONSTRAINT=TG_TABLE_NAME || '_source_set_check';
      END IF;
      RETURN NULL;
    END
    $function$
    """)
  end

  defp replace_organization_guard do
    execute("""
    CREATE OR REPLACE FUNCTION content.enforce_knowledge_organization_resource() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, content
    AS $function$
    DECLARE resource_ids uuid[]; resource_id uuid; resource content.resources%ROWTYPE;
      binding record;
    BEGIN
      IF TG_TABLE_NAME='resource_tags' THEN
        resource_ids := ARRAY[NEW.resource_id];
      ELSE
        SELECT array_agg(id ORDER BY id) INTO resource_ids
        FROM unnest(ARRAY[NEW.source_resource_id,NEW.target_resource_id]) AS ids(id);
      END IF;
      IF audit.knowledge_restore_is_bound(NEW.vault_id) THEN
        -- Historical Asset identities still precede their Resource locks.
        FOR binding IN SELECT a.id FROM content.assets a JOIN content.resource_versions v
          ON (v.id,v.vault_id,v.classification)=(a.resource_version_id,a.vault_id,a.classification)
          JOIN content.resources r ON (r.id,r.vault_id,r.classification)=
            (v.resource_id,v.vault_id,v.classification)
          WHERE r.id=ANY(resource_ids) AND r.kind='asset'
            AND r.vault_id=NEW.vault_id AND r.classification='private' ORDER BY a.id
        LOOP
          PERFORM 1 FROM content.assets WHERE id=binding.id FOR SHARE;
        END LOOP;
        FOREACH resource_id IN ARRAY resource_ids LOOP
          SELECT * INTO resource FROM content.resources r
            WHERE (r.id,r.vault_id,r.classification)=(resource_id,NEW.vault_id,'private')
              AND r.kind IN ('asset','note','document') FOR SHARE;
          IF NOT FOUND OR NEW.classification IS DISTINCT FROM 'private' THEN
            RAISE EXCEPTION 'invalid knowledge organization resource'
              USING ERRCODE='23514',CONSTRAINT=TG_TABLE_NAME || '_resource_check';
          END IF;
          IF (resource.kind='note' AND NOT EXISTS(SELECT 1 FROM content.note_versions n
              JOIN content.resource_versions v ON (v.id,v.resource_id,v.vault_id,v.classification)=
                (n.resource_version_id,n.resource_id,n.vault_id,n.classification)
              WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=
                (resource.current_version_id,resource.id,NEW.vault_id,'private')))
            OR (resource.kind='document' AND NOT EXISTS(SELECT 1 FROM content.document_versions d
              JOIN content.resource_versions v ON (v.id,v.resource_id,v.vault_id,v.classification)=
                (d.resource_version_id,d.resource_id,d.vault_id,d.classification)
              WHERE (d.resource_version_id,d.resource_id,d.vault_id,d.classification)=
                (resource.current_version_id,resource.id,NEW.vault_id,'private')))
            OR (resource.kind='asset' AND NOT EXISTS(SELECT 1 FROM content.resource_versions v
              JOIN content.assets a ON (a.resource_version_id,a.vault_id,a.classification)=
                (v.id,v.vault_id,v.classification)
              JOIN content.resource_assets ra ON (ra.asset_id,ra.resource_version_id,ra.vault_id,ra.classification)=
                (a.id,v.id,v.vault_id,v.classification)
              WHERE (v.resource_id,v.vault_id,v.classification)=(resource.id,NEW.vault_id,'private')
                AND (SELECT count(*) FROM content.assets WHERE resource_version_id=v.id)=1)) THEN
            RAISE EXCEPTION 'invalid knowledge organization resource'
              USING ERRCODE='23514',CONSTRAINT=TG_TABLE_NAME || '_resource_check';
          END IF;
        END LOOP;
        IF TG_TABLE_NAME='relationships' THEN
          IF NEW.target_resource_version_id IS NOT NULL AND NOT EXISTS(
            SELECT 1 FROM content.resource_versions v JOIN content.resources r
              ON (r.id,r.vault_id,r.classification)=(v.resource_id,v.vault_id,v.classification)
            WHERE (v.id,v.resource_id,v.vault_id,v.classification)=
              (NEW.target_resource_version_id,NEW.target_resource_id,NEW.vault_id,'private')
              AND ((r.kind='note' AND EXISTS(SELECT 1 FROM content.note_versions n
                WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=
                  (v.id,v.resource_id,v.vault_id,v.classification)))
                OR (r.kind='document' AND EXISTS(SELECT 1 FROM content.document_versions d
                  WHERE (d.resource_version_id,d.resource_id,d.vault_id,d.classification)=
                    (v.id,v.resource_id,v.vault_id,v.classification)))
                OR (r.kind='asset' AND (SELECT count(*) FROM content.assets
                    WHERE resource_version_id=v.id)=1 AND EXISTS(
                  SELECT 1 FROM content.assets a JOIN content.resource_assets ra
                    ON (ra.asset_id,ra.resource_version_id,ra.vault_id,ra.classification)=
                      (a.id,a.resource_version_id,a.vault_id,a.classification)
                  WHERE (a.resource_version_id,a.vault_id,a.classification)=
                    (v.id,v.vault_id,v.classification))))
          ) THEN
            RAISE EXCEPTION 'invalid knowledge organization resource'
              USING ERRCODE='23514',CONSTRAINT=TG_TABLE_NAME || '_resource_check';
          END IF;
        END IF;
      ELSE
        IF NOT content.lock_knowledge_organization_resources(NEW.vault_id,resource_ids) THEN
          RAISE EXCEPTION 'invalid knowledge organization resource'
            USING ERRCODE='23514',CONSTRAINT=TG_TABLE_NAME || '_resource_check';
        END IF;
      END IF;
      RETURN NEW;
    END
    $function$
    """)
  end
end
