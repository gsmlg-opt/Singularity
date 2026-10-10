defmodule Singularity.Storage.Migrations.SealNoteSourceSets do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")
    # Exclude writers before inspecting any historical membership or ancestry.
    execute(
      "LOCK TABLE content.resources, content.resource_versions, content.note_versions, content.note_attachments, content.note_citations IN SHARE ROW EXCLUSIVE MODE"
    )

    create_seals()
    create_parent_predicate()
    preflight()
    create_finalizer()
    create_source_guard()
    create_triggers_and_acl()

    execute(
      "SELECT content.finalize_note_source_set(resource_version_id) FROM content.note_versions ORDER BY resource_version_id"
    )

    execute("SET LOCAL ROLE NONE")
  end

  def down, do: raise(Ecto.MigrationError, "Note source set sealing migration is forward-only")

  defp create_seals do
    execute("""
    CREATE TABLE content.note_source_set_seals (
      note_resource_version_id uuid CONSTRAINT note_source_set_seals_pkey PRIMARY KEY,
      note_resource_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      attachment_count integer NOT NULL,
      citation_count integer NOT NULL,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT note_source_set_seals_private_check CHECK (classification='private'),
      CONSTRAINT note_source_set_seals_counts_check CHECK (attachment_count BETWEEN 0 AND 100 AND citation_count BETWEEN 0 AND 100),
      CONSTRAINT note_source_set_seals_note_fkey FOREIGN KEY (note_resource_version_id,note_resource_id,vault_id,classification)
        REFERENCES content.note_versions(resource_version_id,resource_id,vault_id,classification) DEFERRABLE INITIALLY DEFERRED
    )
    """)
  end

  defp create_parent_predicate do
    execute("""
    CREATE FUNCTION content.note_source_parent_is_valid(version uuid, parent uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,content
    AS $function$
      SELECT EXISTS (
        SELECT 1 FROM content.note_versions n
        JOIN content.resource_versions nv ON (nv.id,nv.resource_id,nv.vault_id,nv.classification)=(n.resource_version_id,n.resource_id,n.vault_id,n.classification)
        JOIN content.note_versions p ON p.resource_version_id=parent
        JOIN content.resource_versions pv ON (pv.id,pv.resource_id,pv.vault_id,pv.classification)=(p.resource_version_id,p.resource_id,p.vault_id,p.classification)
        WHERE n.resource_version_id=version AND n.classification='private'
          AND (p.resource_id,p.vault_id,p.classification)=(n.resource_id,n.vault_id,n.classification)
          AND pv.revision<nv.revision
      )
    $function$
    """)
  end

  defp preflight do
    execute("""
    DO $block$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM content.note_versions n
        LEFT JOIN content.resources r ON (r.id,r.vault_id,r.classification)=(n.resource_id,n.vault_id,n.classification)
        LEFT JOIN content.resource_versions v ON (v.id,v.resource_id,v.vault_id,v.classification)=(n.resource_version_id,n.resource_id,n.vault_id,n.classification)
        WHERE r.kind IS DISTINCT FROM 'note' OR n.classification<>'private' OR v.id IS NULL
          OR (n.parent_version_id IS NOT NULL AND NOT content.note_source_parent_is_valid(n.resource_version_id,n.parent_version_id))
          OR (n.merge_parent_version_id IS NOT NULL AND NOT content.note_source_parent_is_valid(n.resource_version_id,n.merge_parent_version_id))
      ) OR EXISTS (
        SELECT 1 FROM content.note_attachments a
        LEFT JOIN content.note_versions n ON (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=(a.note_resource_version_id,a.note_resource_id,a.vault_id,a.classification)
        LEFT JOIN content.resources r ON (r.id,r.vault_id,r.classification)=(a.target_resource_id,a.vault_id,a.classification)
        LEFT JOIN content.resource_versions v ON (v.id,v.resource_id,v.vault_id,v.classification)=(a.target_resource_version_id,a.target_resource_id,a.vault_id,a.classification)
        WHERE n.resource_version_id IS NULL OR v.id IS NULL OR r.kind IS DISTINCT FROM a.target_kind
          OR (a.target_kind='note' AND NOT EXISTS(SELECT 1 FROM content.note_versions t WHERE (t.resource_version_id,t.resource_id,t.vault_id,t.classification)=(v.id,r.id,a.vault_id,a.classification)))
          OR (a.target_kind='document' AND NOT EXISTS(SELECT 1 FROM content.document_versions t WHERE (t.resource_version_id,t.resource_id,t.vault_id,t.classification)=(v.id,r.id,a.vault_id,a.classification)))
          OR (a.target_kind='asset' AND NOT EXISTS(SELECT 1 FROM content.assets t WHERE (t.resource_version_id,t.vault_id,t.classification)=(v.id,a.vault_id,a.classification)))
      ) OR EXISTS (
        SELECT 1 FROM content.note_citations c
        LEFT JOIN content.note_versions n ON (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=(c.note_resource_version_id,c.note_resource_id,c.vault_id,c.classification)
        LEFT JOIN content.document_fragments f ON (f.id,f.resource_id,f.resource_version_id,f.vault_id,f.classification)=(c.fragment_id,c.source_resource_id,c.source_resource_version_id,c.vault_id,c.classification)
        WHERE n.resource_version_id IS NULL OR f.id IS NULL OR c.locator IS DISTINCT FROM f.locator
      ) OR EXISTS (
        SELECT 1 FROM content.note_versions n
        CROSS JOIN LATERAL (SELECT count(*) amount,max(ordinal) last_ordinal FROM content.note_attachments WHERE note_resource_version_id=n.resource_version_id) a
        CROSS JOIN LATERAL (SELECT count(*) amount,max(ordinal) last_ordinal FROM content.note_citations WHERE note_resource_version_id=n.resource_version_id) c
        WHERE a.amount>100 OR c.amount>100 OR (a.amount>0 AND a.last_ordinal<>a.amount-1) OR (c.amount>0 AND c.last_ordinal<>c.amount-1)
          OR (SELECT count(*) FROM (
            SELECT target_resource_id,target_resource_version_id FROM content.note_attachments WHERE note_resource_version_id=n.resource_version_id
            UNION SELECT source_resource_id,source_resource_version_id FROM content.note_citations WHERE note_resource_version_id=n.resource_version_id
          ) targets)>100
          OR (SELECT count(DISTINCT fragment_id) FROM content.note_citations WHERE note_resource_version_id=n.resource_version_id)>100
      ) THEN
        RAISE EXCEPTION 'Historical Note source set is invalid'
          USING ERRCODE='23514',CONSTRAINT='note_source_set_seals_preflight_check';
      END IF;
    END
    $block$
    """)
  end

  defp create_finalizer do
    execute("""
    CREATE FUNCTION content.finalize_note_source_set(version uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,content
    AS $function$
    DECLARE note content.note_versions%ROWTYPE; seal content.note_source_set_seals%ROWTYPE;
      attachments bigint; citations bigint; last_attachment bigint; last_citation bigint;
    BEGIN
      SELECT * INTO note FROM content.note_versions WHERE resource_version_id=version;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Note source set has no typed Note'
          USING ERRCODE='23503',CONSTRAINT='note_source_set_seals_note_fkey';
      END IF;
      IF (note.parent_version_id IS NOT NULL AND NOT content.note_source_parent_is_valid(version,note.parent_version_id))
        OR (note.merge_parent_version_id IS NOT NULL AND NOT content.note_source_parent_is_valid(version,note.merge_parent_version_id)) THEN
        RAISE EXCEPTION 'Note source parent is not a lower revision of the same Note'
          USING ERRCODE='23514',CONSTRAINT='note_versions_source_parent_check';
      END IF;
      IF EXISTS(SELECT 1 FROM content.note_attachments WHERE note_resource_version_id=version
          AND (note_resource_id,vault_id,classification) IS DISTINCT FROM (note.resource_id,note.vault_id,note.classification)) THEN
        RAISE EXCEPTION 'Invalid attachment Note identity'
          USING ERRCODE='23503',CONSTRAINT='note_attachments_note_fkey';
      END IF;
      IF EXISTS(SELECT 1 FROM content.note_citations WHERE note_resource_version_id=version
          AND (note_resource_id,vault_id,classification) IS DISTINCT FROM (note.resource_id,note.vault_id,note.classification)) THEN
        RAISE EXCEPTION 'Invalid citation Note identity'
          USING ERRCODE='23503',CONSTRAINT='note_citations_note_fkey';
      END IF;
      SELECT count(*),max(ordinal) INTO attachments,last_attachment FROM content.note_attachments WHERE note_resource_version_id=version;
      SELECT count(*),max(ordinal) INTO citations,last_citation FROM content.note_citations WHERE note_resource_version_id=version;
      IF attachments>0 AND last_attachment<>attachments-1 THEN
        RAISE EXCEPTION 'Note attachment order is incomplete'
          USING ERRCODE='23514',CONSTRAINT='note_attachments_source_set_check';
      END IF;
      IF citations>0 AND last_citation<>citations-1 THEN
        RAISE EXCEPTION 'Note citation order is incomplete'
          USING ERRCODE='23514',CONSTRAINT='note_citations_source_set_check';
      END IF;
      IF attachments>100 OR citations>100 OR (SELECT count(*) FROM (
          SELECT target_resource_id,target_resource_version_id FROM content.note_attachments WHERE note_resource_version_id=version
          UNION SELECT source_resource_id,source_resource_version_id FROM content.note_citations WHERE note_resource_version_id=version
        ) targets)>100 OR (SELECT count(DISTINCT fragment_id) FROM content.note_citations WHERE note_resource_version_id=version)>100 THEN
        RAISE EXCEPTION 'Note source set exceeds its bounds'
          USING ERRCODE='23514',CONSTRAINT='note_source_set_seals_bounds_check';
      END IF;
      SELECT * INTO seal FROM content.note_source_set_seals WHERE note_resource_version_id=version;
      IF NOT FOUND THEN
        INSERT INTO content.note_source_set_seals(note_resource_version_id,note_resource_id,vault_id,classification,attachment_count,citation_count)
        VALUES(version,note.resource_id,note.vault_id,note.classification,attachments,citations)
        ON CONFLICT (note_resource_version_id) DO NOTHING;
        -- A conflicting invisible row is never treated as a successful finalization.
        SELECT * INTO seal FROM content.note_source_set_seals WHERE note_resource_version_id=version;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Concurrent Note source seal is not visible'
            USING ERRCODE='23514',CONSTRAINT='note_source_set_seals_consistency_check';
        END IF;
      END IF;
      IF (seal.note_resource_id,seal.vault_id,seal.classification,seal.attachment_count,seal.citation_count)
        IS DISTINCT FROM (note.resource_id,note.vault_id,note.classification,attachments,citations) THEN
        RAISE EXCEPTION 'Note source seal does not match its complete set'
          USING ERRCODE='23514',CONSTRAINT='note_source_set_seals_consistency_check';
      END IF;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.enforce_note_source_seal() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,content
    AS $function$
    BEGIN
      IF TG_TABLE_NAME='note_versions' THEN PERFORM content.finalize_note_source_set(NEW.resource_version_id);
      ELSE PERFORM content.finalize_note_source_set(NEW.note_resource_version_id); END IF;
      RETURN NULL;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.reject_sealed_note_source_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,content
    AS $function$
    BEGIN
      -- This read-only guard uses the caller's existing forced-RLS seal SELECT.
      -- Unauthorized web rows see no seal and reach native child WITH CHECK;
      -- excluded roles have no seal SELECT. The write finalizers remain definer.
      IF EXISTS(SELECT 1 FROM content.note_source_set_seals
          WHERE (note_resource_version_id,note_resource_id,vault_id,classification)
            =(NEW.note_resource_version_id,NEW.note_resource_id,NEW.vault_id,NEW.classification)) THEN
        RAISE EXCEPTION 'Note source set is sealed'
          USING ERRCODE='23514',CONSTRAINT=TG_TABLE_NAME || '_sealed_check';
      END IF;
      RETURN NEW;
    END
    $function$
    """)
  end

  defp create_source_guard do
    execute("""
    CREATE OR REPLACE FUNCTION content.enforce_note_source_set() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,content
    AS $function$
    DECLARE target_id uuid; target_version_id uuid; target_kind text; locked_id uuid;
      accepted_asset_id uuid; accepted_object_id uuid; amount bigint; last_ordinal bigint; retained boolean;
    BEGIN
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

  defp create_triggers_and_acl do
    execute(
      "CREATE TRIGGER note_source_set_seals_immutable_check BEFORE UPDATE OR DELETE ON content.note_source_set_seals FOR EACH ROW EXECUTE FUNCTION content.enforce_note_source_immutable()"
    )

    execute(
      "CREATE CONSTRAINT TRIGGER note_versions_source_set_seal_check AFTER INSERT ON content.note_versions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION content.enforce_note_source_seal()"
    )

    for table <- ~w(note_attachments note_citations) do
      execute(
        "CREATE TRIGGER #{table}_sealed_check BEFORE INSERT ON content.#{table} FOR EACH ROW EXECUTE FUNCTION content.reject_sealed_note_source_insert()"
      )

      execute(
        "CREATE CONSTRAINT TRIGGER #{table}_source_set_seal_check AFTER INSERT ON content.#{table} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION content.enforce_note_source_seal()"
      )
    end

    execute("ALTER TABLE content.note_source_set_seals ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE content.note_source_set_seals FORCE ROW LEVEL SECURITY")

    execute(
      "CREATE POLICY note_source_set_seals_table_owner ON content.note_source_set_seals FOR ALL TO singularity_table_owner USING(true) WITH CHECK(true)"
    )

    execute("""
    CREATE POLICY note_source_set_seals_owner_read ON content.note_source_set_seals FOR SELECT TO singularity_web
    USING(NULLIF(current_setting('singularity.principal_id',true),'') IS NOT NULL
      AND vault_id=NULLIF(current_setting('singularity.vault_id',true),'')::uuid
      AND core.principal_is_authorized(NULLIF(current_setting('singularity.principal_id',true),'')::uuid,vault_id))
    """)

    execute(
      "REVOKE ALL ON content.note_source_set_seals FROM PUBLIC,singularity_web,singularity_worker,singularity_dispatcher,singularity_pre_auth"
    )

    execute("GRANT SELECT ON content.note_source_set_seals TO singularity_web")

    for signature <- [
          "note_source_parent_is_valid(uuid,uuid)",
          "finalize_note_source_set(uuid)",
          "enforce_note_source_seal()",
          "reject_sealed_note_source_insert()",
          "enforce_note_source_set()"
        ] do
      execute(
        "REVOKE ALL ON FUNCTION content.#{signature} FROM PUBLIC,singularity_web,singularity_worker,singularity_dispatcher,singularity_pre_auth"
      )
    end
  end
end
