defmodule Singularity.Storage.Migrations.CreateKnowledgeLinksAndOrganization do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")
    create_sources()
    create_organization()
    create_source_guards()
    create_organization_guard()
    create_policies()
    execute("SET LOCAL ROLE NONE")
  end

  def down, do: raise(Ecto.MigrationError, "Knowledge links migration is forward-only")

  defp create_sources do
    execute("""
    CREATE TABLE content.note_attachments (
      note_resource_version_id uuid NOT NULL,
      id uuid NOT NULL,
      note_resource_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      target_resource_id uuid NOT NULL,
      target_resource_version_id uuid NOT NULL,
      target_kind text NOT NULL,
      ordinal bigint NOT NULL,
      role text NOT NULL,
      label text,
      inserted_at timestamptz(6) NOT NULL,
      CONSTRAINT note_attachments_pkey PRIMARY KEY (note_resource_version_id,id),
      CONSTRAINT note_attachments_private_check CHECK (classification = 'private'),
      CONSTRAINT note_attachments_kind_check CHECK (target_kind IN ('asset','note','document')),
      CONSTRAINT note_attachments_role_check CHECK (role = 'source'),
      CONSTRAINT note_attachments_ordinal_check CHECK (ordinal >= 0),
      CONSTRAINT note_attachments_label_check CHECK (label IS NULL OR octet_length(label) <= 255),
      CONSTRAINT note_attachments_self_check CHECK (note_resource_id <> target_resource_id AND note_resource_version_id <> target_resource_version_id),
      CONSTRAINT note_attachments_note_ordinal_key UNIQUE (note_resource_version_id,ordinal),
      CONSTRAINT note_attachments_note_target_role_key UNIQUE (note_resource_version_id,target_resource_version_id,role),
      CONSTRAINT note_attachments_note_fkey FOREIGN KEY (note_resource_version_id,note_resource_id,vault_id,classification)
        REFERENCES content.note_versions(resource_version_id,resource_id,vault_id,classification) DEFERRABLE INITIALLY DEFERRED,
      CONSTRAINT note_attachments_target_fkey FOREIGN KEY (target_resource_version_id,target_resource_id,vault_id,classification)
        REFERENCES content.resource_versions(id,resource_id,vault_id,classification) DEFERRABLE INITIALLY DEFERRED
    )
    """)

    execute("""
    CREATE TABLE content.note_citations (
      note_resource_version_id uuid NOT NULL,
      id uuid NOT NULL,
      note_resource_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      source_resource_id uuid NOT NULL,
      source_resource_version_id uuid NOT NULL,
      fragment_id text NOT NULL,
      locator jsonb NOT NULL,
      ordinal bigint NOT NULL,
      inserted_at timestamptz(6) NOT NULL,
      CONSTRAINT note_citations_pkey PRIMARY KEY (note_resource_version_id,id),
      CONSTRAINT note_citations_private_check CHECK (classification = 'private'),
      CONSTRAINT note_citations_ordinal_check CHECK (ordinal >= 0),
      CONSTRAINT note_citations_self_check CHECK (note_resource_id <> source_resource_id AND note_resource_version_id <> source_resource_version_id),
      CONSTRAINT note_citations_note_ordinal_key UNIQUE (note_resource_version_id,ordinal),
      CONSTRAINT note_citations_note_fkey FOREIGN KEY (note_resource_version_id,note_resource_id,vault_id,classification)
        REFERENCES content.note_versions(resource_version_id,resource_id,vault_id,classification) DEFERRABLE INITIALLY DEFERRED,
      CONSTRAINT note_citations_fragment_fkey FOREIGN KEY (fragment_id,source_resource_id,source_resource_version_id,vault_id,classification)
        REFERENCES content.document_fragments(id,resource_id,resource_version_id,vault_id,classification) DEFERRABLE INITIALLY DEFERRED
    )
    """)
  end

  defp create_organization do
    execute("""
    CREATE TABLE content.tags (
      id uuid CONSTRAINT tags_pkey PRIMARY KEY,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      display_value text NOT NULL,
      normalized_key text NOT NULL,
      created_by_principal_id uuid NOT NULL,
      inserted_at timestamptz(6) NOT NULL,
      CONSTRAINT tags_private_check CHECK (classification = 'private'),
      CONSTRAINT tags_display_value_check CHECK (octet_length(display_value) BETWEEN 1 AND 255 AND display_value !~ '[[:cntrl:]]'),
      CONSTRAINT tags_normalized_key_check CHECK (octet_length(normalized_key) BETWEEN 1 AND 1024 AND normalized_key !~ '[[:cntrl:]]'),
      CONSTRAINT tags_id_vault_key UNIQUE (id,vault_id),
      CONSTRAINT tags_vault_fkey FOREIGN KEY (vault_id) REFERENCES core.vaults(id),
      CONSTRAINT tags_created_by_principal_fkey FOREIGN KEY (created_by_principal_id) REFERENCES identity.principals(id)
    )
    """)

    # Core owns Unicode normalization; SQL enforces bytewise owner/key identity.
    execute(
      "CREATE UNIQUE INDEX tags_owner_normalized_key ON content.tags(vault_id,normalized_key COLLATE \"C\")"
    )

    execute("""
    CREATE TABLE content.resource_tags (
      resource_id uuid NOT NULL,
      tag_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      inserted_at timestamptz(6) NOT NULL,
      CONSTRAINT resource_tags_pkey PRIMARY KEY (resource_id,tag_id,vault_id),
      CONSTRAINT resource_tags_private_check CHECK (classification = 'private'),
      CONSTRAINT resource_tags_resource_fkey FOREIGN KEY (resource_id,vault_id,classification)
        REFERENCES content.resources(id,vault_id,classification),
      CONSTRAINT resource_tags_tag_fkey FOREIGN KEY (tag_id,vault_id) REFERENCES content.tags(id,vault_id)
    )
    """)

    execute("""
    CREATE TABLE content.relationships (
      id uuid CONSTRAINT relationships_pkey PRIMARY KEY,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      source_resource_id uuid NOT NULL,
      target_resource_id uuid NOT NULL,
      target_resource_version_id uuid,
      type text NOT NULL,
      created_by_principal_id uuid NOT NULL,
      inserted_at timestamptz(6) NOT NULL,
      CONSTRAINT relationships_private_check CHECK (classification = 'private'),
      CONSTRAINT relationships_type_check CHECK (type IN ('related_to','references','derived_from')),
      CONSTRAINT relationships_self_check CHECK (source_resource_id <> target_resource_id),
      CONSTRAINT relationships_source_fkey FOREIGN KEY (source_resource_id,vault_id,classification)
        REFERENCES content.resources(id,vault_id,classification),
      CONSTRAINT relationships_target_fkey FOREIGN KEY (target_resource_id,vault_id,classification)
        REFERENCES content.resources(id,vault_id,classification),
      CONSTRAINT relationships_target_version_fkey FOREIGN KEY (target_resource_version_id,target_resource_id,vault_id,classification)
        REFERENCES content.resource_versions(id,resource_id,vault_id,classification) MATCH SIMPLE,
      CONSTRAINT relationships_created_by_principal_fkey FOREIGN KEY (created_by_principal_id) REFERENCES identity.principals(id),
      CONSTRAINT relationships_owner_source_target_type_key UNIQUE (vault_id,source_resource_id,target_resource_id,type)
    )
    """)

    execute(
      "CREATE INDEX relationships_incoming_index ON content.relationships(vault_id,target_resource_id,type,source_resource_id)"
    )
  end

  defp create_source_guards do
    execute("""
    CREATE FUNCTION content.enforce_note_source_immutable() RETURNS trigger
    LANGUAGE plpgsql SET search_path = pg_catalog
    AS $function$
    BEGIN
      RAISE EXCEPTION 'Note source rows are immutable'
        USING ERRCODE = '23514', CONSTRAINT = TG_TABLE_NAME || '_immutable_check';
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.enforce_note_source_set() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, content
    AS $function$
    DECLARE
      target_id uuid;
      target_version_id uuid;
      target_kind text;
      locked_id uuid;
      accepted_asset_id uuid;
      accepted_object_id uuid;
      amount bigint;
      last_ordinal bigint;
    BEGIN
      IF TG_TABLE_NAME = 'note_attachments' THEN
        target_id := NEW.target_resource_id;
        target_version_id := NEW.target_resource_version_id;
        target_kind := NEW.target_kind;
      ELSE
        target_id := NEW.source_resource_id;
        target_version_id := NEW.source_resource_version_id;
        target_kind := 'document';
      END IF;

      -- Match established Asset source/deletion locking before resource locks.
      IF target_kind = 'asset' THEN
        SELECT id,asset_object_id INTO accepted_asset_id,accepted_object_id FROM content.assets
          WHERE resource_version_id = target_version_id AND vault_id = NEW.vault_id FOR SHARE;
        PERFORM 1 FROM content.asset_objects WHERE id = accepted_object_id FOR SHARE;
      END IF;
      -- Parent rows precede the shared Note aggregate advisory lock.
      FOR locked_id IN SELECT id FROM content.resources
        WHERE id IN (NEW.note_resource_id,target_id) ORDER BY id FOR UPDATE
      LOOP
        PERFORM pg_advisory_xact_lock(hashtextextended('singularity.note.aggregate:' || locked_id::text,0));
      END LOOP;

      PERFORM 1 FROM content.resource_versions WHERE id = target_version_id FOR SHARE;
      IF target_kind = 'asset' THEN
        PERFORM 1 FROM content.resource_assets
          WHERE resource_version_id = target_version_id AND asset_id = accepted_asset_id FOR SHARE;
      END IF;

      IF NOT EXISTS (SELECT 1 FROM content.resources r JOIN content.note_versions n
          ON (n.resource_id,n.vault_id,n.classification) = (r.id,r.vault_id,r.classification)
          WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)
            = (NEW.note_resource_version_id,NEW.note_resource_id,NEW.vault_id,'private')
            AND r.kind = 'note' AND r.deleted_at IS NULL)
         OR NOT EXISTS (SELECT 1 FROM content.resources r JOIN content.resource_versions v
          ON (v.resource_id,v.vault_id,v.classification) = (r.id,r.vault_id,r.classification)
          WHERE (v.id,v.resource_id,v.vault_id,v.classification) = (target_version_id,target_id,NEW.vault_id,'private')
            AND r.kind = target_kind AND r.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'invalid Note source identity'
          USING ERRCODE = '23514', CONSTRAINT = TG_TABLE_NAME || '_source_check';
      END IF;

      IF (target_kind = 'note' AND NOT EXISTS (
          SELECT 1 FROM content.note_versions WHERE (resource_version_id,resource_id,vault_id,classification)
            = (target_version_id,target_id,NEW.vault_id,'private')))
        OR (target_kind = 'document' AND NOT EXISTS (
          SELECT 1 FROM content.document_versions WHERE (resource_version_id,resource_id,vault_id,classification)
            = (target_version_id,target_id,NEW.vault_id,'private') AND state = 'ready'))
        OR (target_kind = 'asset' AND NOT EXISTS (
          SELECT 1 FROM content.assets a JOIN content.asset_objects o ON (o.id,o.vault_id) = (a.asset_object_id,a.vault_id)
          JOIN content.resource_assets ra ON (ra.asset_id,ra.resource_version_id,ra.vault_id) = (a.id,a.resource_version_id,a.vault_id)
          WHERE a.id = accepted_asset_id AND a.resource_version_id = target_version_id AND a.vault_id = NEW.vault_id
            AND a.classification = 'private' AND a.state IN ('available','processing','ready')
            AND o.classification = 'private' AND o.lifecycle = 'available' AND o.deleted_at IS NULL
            AND ra.classification = 'private' AND ra.released_at IS NULL)) THEN
        RAISE EXCEPTION 'Note source is not ready'
          USING ERRCODE = '23514', CONSTRAINT = TG_TABLE_NAME || '_source_check';
      END IF;

      IF TG_TABLE_NAME = 'note_citations' THEN
        IF NOT EXISTS (SELECT 1 FROM content.document_fragments
          WHERE (id,resource_id,resource_version_id,vault_id,classification)
            = (NEW.fragment_id,target_id,target_version_id,NEW.vault_id,'private')
            AND locator = NEW.locator) THEN
          RAISE EXCEPTION 'Note citation locator does not match its fragment'
            USING ERRCODE = '23514', CONSTRAINT = 'note_citations_locator_check';
        END IF;
        SELECT count(*),max(ordinal) INTO amount,last_ordinal FROM content.note_citations
          WHERE note_resource_version_id = NEW.note_resource_version_id;
      ELSE
        SELECT count(*),max(ordinal) INTO amount,last_ordinal FROM content.note_attachments
          WHERE note_resource_version_id = NEW.note_resource_version_id;
      END IF;
      IF last_ordinal IS DISTINCT FROM amount - 1 THEN
        RAISE EXCEPTION 'Note source order is incomplete'
          USING ERRCODE = '23514', CONSTRAINT = TG_TABLE_NAME || '_source_set_check';
      END IF;
      RETURN NULL;
    END
    $function$
    """)

    for table <- ~w(note_attachments note_citations) do
      execute(
        "CREATE TRIGGER #{table}_immutable_check BEFORE UPDATE OR DELETE ON content.#{table} FOR EACH ROW EXECUTE FUNCTION content.enforce_note_source_immutable()"
      )

      # This validates inserted rows and complete order, not sealed membership.
      # Enabling live Note publication remains a separate Phase 4 prerequisite.
      execute(
        "CREATE CONSTRAINT TRIGGER #{table}_source_set_check AFTER INSERT ON content.#{table} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION content.enforce_note_source_set()"
      )
    end
  end

  defp create_organization_guard do
    execute("""
    CREATE FUNCTION content.enforce_knowledge_organization_resource() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, content
    AS $function$
    DECLARE resource_ids uuid[]; resource_id uuid;
    BEGIN
      IF TG_TABLE_NAME = 'resource_tags' THEN resource_ids := ARRAY[NEW.resource_id];
      ELSE resource_ids := ARRAY[NEW.source_resource_id,NEW.target_resource_id]; END IF;
      FOR resource_id IN SELECT DISTINCT id FROM unnest(resource_ids) ids(id) ORDER BY id LOOP
        PERFORM 1 FROM content.resources r WHERE r.id = resource_id
          AND r.vault_id = NEW.vault_id AND r.classification = 'private'
          AND r.kind IN ('asset','note','document') AND r.deleted_at IS NULL FOR SHARE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'invalid knowledge organization resource'
            USING ERRCODE = '23514', CONSTRAINT = TG_TABLE_NAME || '_resource_check';
        END IF;
      END LOOP;
      RETURN NEW;
    END
    $function$
    """)

    for table <- ~w(resource_tags relationships) do
      execute(
        "CREATE TRIGGER #{table}_resource_check BEFORE INSERT ON content.#{table} FOR EACH ROW EXECUTE FUNCTION content.enforce_knowledge_organization_resource()"
      )
    end
  end

  defp create_policies do
    predicate = """
    NULLIF(current_setting('singularity.principal_id',true),'') IS NOT NULL
    AND NULLIF(current_setting('singularity.vault_id',true),'') IS NOT NULL
    AND vault_id = NULLIF(current_setting('singularity.vault_id',true),'')::uuid
    AND core.principal_is_authorized(NULLIF(current_setting('singularity.principal_id',true),'')::uuid,vault_id)
    """

    for table <- ~w(note_attachments note_citations tags resource_tags relationships) do
      execute("ALTER TABLE content.#{table} ENABLE ROW LEVEL SECURITY")
      execute("ALTER TABLE content.#{table} FORCE ROW LEVEL SECURITY")

      execute(
        "CREATE POLICY #{table}_table_owner ON content.#{table} FOR ALL TO singularity_table_owner USING (true) WITH CHECK (true)"
      )

      execute(
        "CREATE POLICY #{table}_vault_isolation ON content.#{table} FOR ALL TO singularity_web,singularity_worker USING (#{predicate}) WITH CHECK (#{predicate})"
      )

      execute(
        "REVOKE ALL ON content.#{table} FROM PUBLIC,singularity_web,singularity_worker,singularity_dispatcher,singularity_pre_auth"
      )
    end

    for function <-
          ~w(enforce_note_source_immutable enforce_note_source_set enforce_knowledge_organization_resource) do
      execute(
        "REVOKE ALL ON FUNCTION content.#{function}() FROM PUBLIC,singularity_web,singularity_worker,singularity_dispatcher,singularity_pre_auth"
      )
    end
  end
end
