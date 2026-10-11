defmodule Singularity.Storage.Migrations.KnowledgeAssetLifecycleGuards do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")
    create_binding_predicate()
    create_resource_predicate()
    create_lock_guard()
    replace_organization_guard()

    for signature <- [
          "knowledge_asset_binding_is_live(uuid,uuid,uuid)",
          "knowledge_resource_is_live(uuid,uuid)",
          "lock_knowledge_organization_resources(uuid,uuid[])"
        ] do
      execute("REVOKE ALL ON FUNCTION content.#{signature} FROM PUBLIC")

      execute(
        "GRANT EXECUTE ON FUNCTION content.#{signature} TO singularity_web,singularity_table_owner"
      )
    end

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    raise "knowledge Asset lifecycle guards are forward-only"
  end

  defp create_binding_predicate do
    execute("""
    CREATE FUNCTION content.knowledge_asset_binding_is_live(owner_id uuid, version_id uuid, asset_id uuid)
    RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER
    SET search_path = pg_catalog, content
    AS $function$
      SELECT EXISTS (
        SELECT 1 FROM content.resource_versions v
        JOIN content.resources r
          ON (r.id,r.vault_id,r.classification)=(v.resource_id,v.vault_id,v.classification)
        JOIN content.assets a
          ON (a.resource_version_id,a.vault_id,a.classification)=(v.id,v.vault_id,v.classification)
        JOIN content.resource_assets ra
          ON (ra.resource_version_id,ra.asset_id,ra.vault_id,ra.classification)=(v.id,a.id,v.vault_id,v.classification)
        WHERE (v.id,a.id,v.vault_id,v.classification)=($2,$3,$1,'private')
          AND r.kind='asset' AND r.deleted_at IS NULL AND ra.released_at IS NULL
          AND a.state IN ('staging','uploaded','verified','available','processing','ready')
          AND NOT EXISTS (
            SELECT 1 FROM content.tombstones t
            WHERE (t.asset_id,t.vault_id,t.classification)=(a.id,a.vault_id,a.classification)
          )
      )
    $function$
    """)
  end

  defp create_resource_predicate do
    execute("""
    CREATE FUNCTION content.knowledge_resource_is_live(owner_id uuid, resource_id uuid)
    RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER
    SET search_path = pg_catalog, content
    AS $function$
      SELECT EXISTS (
        SELECT 1 FROM content.resources r
        WHERE (r.id,r.vault_id,r.classification)=($2,$1,'private')
          AND r.deleted_at IS NULL AND r.kind IN ('asset','note','document')
          AND (r.kind <> 'asset' OR EXISTS (
            SELECT 1 FROM content.resource_versions v
            JOIN content.assets a
              ON (a.resource_version_id,a.vault_id,a.classification)=(v.id,v.vault_id,v.classification)
            WHERE (v.resource_id,v.vault_id,v.classification)=(r.id,r.vault_id,r.classification)
              AND content.knowledge_asset_binding_is_live($1,v.id,a.id)
          ))
      )
    $function$
    """)
  end

  defp create_lock_guard do
    execute("""
    CREATE FUNCTION content.lock_knowledge_organization_resources(owner_id uuid, resource_ids uuid[])
    RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY INVOKER
    SET search_path = pg_catalog, content
    AS $function$
    DECLARE
      root_count integer;
      asset_roots uuid[];
      witness_roots uuid[] := ARRAY[]::uuid[];
      witness_versions uuid[] := ARRAY[]::uuid[];
      witness_assets uuid[] := ARRAY[]::uuid[];
      candidate record;
      root_id uuid;
      valid boolean;
    BEGIN
      IF owner_id IS NULL OR resource_ids IS NULL
        OR array_ndims(resource_ids) IS DISTINCT FROM 1
        OR array_lower(resource_ids,1) IS DISTINCT FROM 1
        OR cardinality(resource_ids) NOT IN (1,2)
        OR array_position(resource_ids,NULL) IS NOT NULL THEN
        RETURN false;
      END IF;
      IF cardinality(resource_ids)=2 AND resource_ids[1] >= resource_ids[2] THEN
        RETURN false;
      END IF;

      SELECT count(*),coalesce(array_agg(r.id ORDER BY r.id) FILTER (WHERE r.kind='asset'),ARRAY[]::uuid[])
      INTO root_count,asset_roots
      FROM content.resources r
      WHERE r.id=ANY(resource_ids) AND r.vault_id=owner_id
        AND r.classification='private' AND r.deleted_at IS NULL
        AND r.kind IN ('asset','note','document');
      IF root_count <> cardinality(resource_ids) THEN RETURN false; END IF;

      -- This cursor has one discovery snapshot, including across Asset waits.
      -- Only actually locked live identities enter the bounded witness arrays.
      FOR candidate IN
        SELECT v.resource_id,v.id AS version_id,a.id AS asset_id
        FROM content.resource_versions v
        JOIN content.assets a
          ON (a.resource_version_id,a.vault_id,a.classification)=(v.id,v.vault_id,v.classification)
        WHERE v.resource_id=ANY(asset_roots) AND v.vault_id=owner_id
          AND v.classification='private'
          AND content.knowledge_asset_binding_is_live(owner_id,v.id,a.id)
        ORDER BY a.id,v.resource_id,v.id
      LOOP
        IF candidate.resource_id=ANY(witness_roots) THEN CONTINUE; END IF;
        PERFORM a.id FROM content.assets a
        WHERE (a.id,a.resource_version_id,a.vault_id,a.classification)=
          (candidate.asset_id,candidate.version_id,owner_id,'private')
        FOR SHARE OF a;
        IF FOUND THEN
          -- A separate statement observes lifecycle changes committed during a wait.
          SELECT content.knowledge_asset_binding_is_live(owner_id,candidate.version_id,candidate.asset_id)
          INTO valid;
          IF valid THEN
            witness_roots := array_append(witness_roots,candidate.resource_id);
            witness_versions := array_append(witness_versions,candidate.version_id);
            witness_assets := array_append(witness_assets,candidate.asset_id);
          END IF;
        END IF;
        EXIT WHEN cardinality(witness_roots)=cardinality(asset_roots);
      END LOOP;
      IF cardinality(witness_roots) <> cardinality(asset_roots) THEN RETURN false; END IF;

      FOREACH root_id IN ARRAY resource_ids LOOP
        PERFORM r.id FROM content.resources r
        WHERE (r.id,r.vault_id,r.classification)=(root_id,owner_id,'private')
          AND r.kind IN ('asset','note','document') AND r.deleted_at IS NULL
        FOR SHARE OF r;
        IF NOT FOUND THEN RETURN false; END IF;
      END LOOP;

      -- Never admit a newly discovered binding after Resource acquisition.
      SELECT count(*)=cardinality(resource_ids) INTO valid
      FROM content.resources r
      WHERE r.id=ANY(resource_ids) AND r.vault_id=owner_id
        AND r.classification='private' AND r.deleted_at IS NULL
        AND r.kind IN ('asset','note','document')
        AND (r.kind <> 'asset' OR EXISTS (
          SELECT 1 FROM unnest(witness_roots,witness_versions,witness_assets) AS w(root_id,version_id,asset_id)
          JOIN content.resource_versions v
            ON (v.id,v.resource_id,v.vault_id,v.classification)=(w.version_id,w.root_id,owner_id,'private')
          WHERE w.root_id=r.id
            AND content.knowledge_asset_binding_is_live(owner_id,w.version_id,w.asset_id)
        ));
      RETURN valid;
    END
    $function$
    """)
  end

  defp replace_organization_guard do
    execute("""
    CREATE OR REPLACE FUNCTION content.enforce_knowledge_organization_resource() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, content
    AS $function$
    DECLARE resource_ids uuid[];
    BEGIN
      IF TG_TABLE_NAME='resource_tags' THEN
        resource_ids := ARRAY[NEW.resource_id];
      ELSE
        SELECT array_agg(id ORDER BY id) INTO resource_ids
        FROM unnest(ARRAY[NEW.source_resource_id,NEW.target_resource_id]) AS ids(id);
      END IF;
      IF NOT content.lock_knowledge_organization_resources(NEW.vault_id,resource_ids) THEN
        RAISE EXCEPTION 'invalid knowledge organization resource'
          USING ERRCODE='23514',CONSTRAINT=TG_TABLE_NAME || '_resource_check';
      END IF;
      RETURN NEW;
    END
    $function$
    """)
  end
end
