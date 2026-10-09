defmodule Singularity.Storage.Migrations.CreateUnifiedSearchProjection do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")
    verify_search_extension()
    create_projection()
    create_indexes()
    create_rls_and_grants()
    execute("SET LOCAL ROLE NONE")
  end

  def down, do: raise(Ecto.MigrationError, "Unified search projection migration is forward-only")

  defp verify_search_extension do
    execute("""
    DO $guard$
    DECLARE
      owner_oid oid := 'singularity_table_owner'::regrole;
      web_oid oid := 'singularity_web'::regrole;
      namespace_oid oid;
      extension_oid oid;
      expected_functions oid[];
      delegated_functions oid[];
      procedure record;
      web_usage boolean;
    BEGIN
      SELECT extension.oid, namespace.oid INTO extension_oid, namespace_oid
      FROM pg_extension AS extension
      JOIN pg_namespace AS namespace ON namespace.oid = extension.extnamespace
      WHERE extension.extname = 'pg_trgm' AND extension.extversion = '1.6'
        AND extension.extowner = owner_oid AND namespace.nspname = 'search_extensions'
        AND namespace.nspowner = owner_oid;

      IF extension_oid IS NULL THEN
        RAISE EXCEPTION 'unified search requires compatible administrator-provisioned pg_trgm';
      END IF;

      -- Pin the supported pg_trgm 1.6 inventory without consulting mutable
      -- bootstrap code or attempting to repair administrator-owned objects.
      SELECT array_agg(to_regprocedure(signature)::oid) INTO expected_functions
      FROM unnest(ARRAY[
        'search_extensions.set_limit(real)',
        'search_extensions.show_limit()',
        'search_extensions.show_trgm(text)',
        'search_extensions.similarity(text,text)',
        'search_extensions.similarity_op(text,text)',
        'search_extensions.word_similarity(text,text)',
        'search_extensions.word_similarity_op(text,text)',
        'search_extensions.word_similarity_commutator_op(text,text)',
        'search_extensions.similarity_dist(text,text)',
        'search_extensions.word_similarity_dist_op(text,text)',
        'search_extensions.word_similarity_dist_commutator_op(text,text)',
        'search_extensions.gtrgm_in(cstring)',
        'search_extensions.gtrgm_out(search_extensions.gtrgm)',
        'search_extensions.gtrgm_consistent(internal,text,smallint,oid,internal)',
        'search_extensions.gtrgm_distance(internal,text,smallint,oid,internal)',
        'search_extensions.gtrgm_compress(internal)',
        'search_extensions.gtrgm_decompress(internal)',
        'search_extensions.gtrgm_penalty(internal,internal,internal)',
        'search_extensions.gtrgm_picksplit(internal,internal)',
        'search_extensions.gtrgm_union(internal,internal)',
        'search_extensions.gtrgm_same(search_extensions.gtrgm,search_extensions.gtrgm,internal)',
        'search_extensions.gin_extract_value_trgm(text,internal)',
        'search_extensions.gin_extract_query_trgm(text,internal,smallint,internal,internal,internal,internal)',
        'search_extensions.gin_trgm_consistent(internal,smallint,text,integer,internal,internal,internal,internal)',
        'search_extensions.gin_trgm_triconsistent(internal,smallint,text,integer,internal,internal,internal)',
        'search_extensions.strict_word_similarity(text,text)',
        'search_extensions.strict_word_similarity_op(text,text)',
        'search_extensions.strict_word_similarity_commutator_op(text,text)',
        'search_extensions.strict_word_similarity_dist_op(text,text)',
        'search_extensions.strict_word_similarity_dist_commutator_op(text,text)',
        'search_extensions.gtrgm_options(internal)'
      ]) AS expected(signature);

      delegated_functions := ARRAY[
        to_regprocedure('search_extensions.similarity(text,text)')::oid,
        to_regprocedure('search_extensions.similarity_op(text,text)')::oid
      ];

      IF array_position(expected_functions, NULL) IS NOT NULL
        OR array_position(delegated_functions, NULL) IS NOT NULL
        OR (SELECT count(*) FROM pg_proc WHERE pronamespace = namespace_oid) <> cardinality(expected_functions)
        OR EXISTS (SELECT FROM pg_proc WHERE pronamespace = namespace_oid AND NOT oid = ANY(expected_functions))
      THEN
        RAISE EXCEPTION 'unified search extension function inventory is incompatible';
      END IF;

      IF EXISTS (SELECT FROM pg_class WHERE relnamespace = namespace_oid)
        OR (SELECT count(*) FROM pg_type WHERE typnamespace = namespace_oid) <> 2
        OR EXISTS (SELECT FROM pg_type WHERE typnamespace = namespace_oid AND typname NOT IN ('gtrgm', '_gtrgm'))
        OR (SELECT count(*) FROM pg_operator WHERE oprnamespace = namespace_oid) <> 10
        OR EXISTS (SELECT FROM pg_operator WHERE oprnamespace = namespace_oid
                   AND oprname NOT IN ('%', '<%', '%>', '<->', '<<->', '<->>', '<<%', '%>>', '<<<->', '<->>>'))
        OR (SELECT count(*) FROM pg_opclass WHERE opcnamespace = namespace_oid) <> 2
        OR (SELECT count(*) FROM pg_opfamily WHERE opfnamespace = namespace_oid) <> 2
        OR EXISTS (SELECT FROM pg_opclass WHERE opcnamespace = namespace_oid AND opcname NOT IN ('gin_trgm_ops', 'gist_trgm_ops'))
        OR EXISTS (SELECT FROM pg_opfamily WHERE opfnamespace = namespace_oid AND opfname NOT IN ('gin_trgm_ops', 'gist_trgm_ops'))
        OR NOT EXISTS (
          SELECT FROM pg_type AS base JOIN pg_type AS array_type ON array_type.oid = base.typarray
          WHERE base.typnamespace = namespace_oid AND base.typname = 'gtrgm'
            AND array_type.typnamespace = namespace_oid AND array_type.typname = '_gtrgm'
            AND array_type.typelem = base.oid
            AND EXISTS (
              SELECT FROM pg_depend WHERE classid = 'pg_type'::regclass AND objid = array_type.oid
                AND refclassid = 'pg_type'::regclass AND refobjid = base.oid AND deptype IN ('a', 'i')
            )
        )
        OR EXISTS (
          SELECT FROM (
            SELECT 'pg_type'::regclass AS classid, oid AS objid FROM pg_type
              WHERE typnamespace = namespace_oid AND typname = 'gtrgm'
            UNION ALL
            SELECT 'pg_operator'::regclass, oid FROM pg_operator WHERE oprnamespace = namespace_oid
            UNION ALL
            SELECT 'pg_opclass'::regclass, oid FROM pg_opclass WHERE opcnamespace = namespace_oid
            UNION ALL
            SELECT 'pg_opfamily'::regclass, oid FROM pg_opfamily WHERE opfnamespace = namespace_oid
          ) AS member
          WHERE NOT EXISTS (
            SELECT FROM pg_depend WHERE classid = member.classid AND objid = member.objid
              AND refclassid = 'pg_extension'::regclass AND refobjid = extension_oid AND deptype = 'e'
          )
        )
        OR NOT EXISTS (
          SELECT FROM pg_operator WHERE oprnamespace = namespace_oid AND oprname = '%'
            AND oprleft = 'text'::regtype AND oprright = 'text'::regtype
            AND oprresult = 'boolean'::regtype AND oprcode = delegated_functions[2]
            AND EXISTS (
              SELECT FROM pg_depend WHERE classid = 'pg_operator'::regclass
                AND objid = pg_operator.oid AND refclassid = 'pg_extension'::regclass
                AND refobjid = extension_oid AND deptype = 'e'
            )
        )
        OR EXISTS (
          SELECT FROM pg_depend WHERE refclassid = 'pg_extension'::regclass AND refobjid = extension_oid
            AND deptype = 'e' AND classid NOT IN (
              'pg_proc'::regclass, 'pg_type'::regclass, 'pg_operator'::regclass,
              'pg_opclass'::regclass, 'pg_opfamily'::regclass, 'pg_amop'::regclass, 'pg_amproc'::regclass
            )
        )
        OR EXISTS (
          SELECT FROM pg_depend AS member
          CROSS JOIN LATERAL pg_identify_object(member.classid, member.objid, member.objsubid) AS object
          WHERE member.refclassid = 'pg_extension'::regclass AND member.refobjid = extension_oid
            AND member.deptype = 'e' AND member.classid IN (
              'pg_proc'::regclass, 'pg_type'::regclass, 'pg_operator'::regclass,
              'pg_opclass'::regclass, 'pg_opfamily'::regclass
            ) AND object.schema IS DISTINCT FROM 'search_extensions'
        )
        OR NOT EXISTS (
          SELECT FROM pg_opclass AS class JOIN pg_am AS method ON method.oid = class.opcmethod
          WHERE class.opcnamespace = namespace_oid AND class.opcname = 'gin_trgm_ops'
            AND method.amname = 'gin' AND class.opcintype = 'text'::regtype
            AND EXISTS (
              SELECT FROM pg_depend WHERE classid = 'pg_opclass'::regclass
                AND objid = class.oid AND refclassid = 'pg_extension'::regclass
                AND refobjid = extension_oid AND deptype = 'e'
            )
        )
      THEN
        RAISE EXCEPTION 'unified search extension functions operator or GIN class are incompatible';
      END IF;

      SELECT EXISTS (
        SELECT FROM pg_namespace AS namespace
        CROSS JOIN LATERAL aclexplode(namespace.nspacl) AS acl
        WHERE namespace.oid = namespace_oid AND acl.grantee = web_oid
          AND acl.privilege_type = 'USAGE'
      ) INTO web_usage;

      IF EXISTS (
        SELECT FROM pg_namespace AS namespace
        CROSS JOIN LATERAL aclexplode(COALESCE(namespace.nspacl, acldefault('n', namespace.nspowner))) AS acl
        WHERE namespace.oid = namespace_oid AND NOT (
          acl.grantee = owner_oid AND acl.grantor = owner_oid
            AND acl.privilege_type IN ('USAGE', 'CREATE') AND NOT acl.is_grantable
          OR acl.grantee = web_oid AND acl.grantor = owner_oid
            AND acl.privilege_type = 'USAGE' AND NOT acl.is_grantable
        )
      ) OR (SELECT count(*) FROM pg_namespace AS namespace
            CROSS JOIN LATERAL aclexplode(namespace.nspacl) AS acl
            WHERE namespace.oid = namespace_oid AND acl.grantee = owner_oid) <> 2
      THEN
        RAISE EXCEPTION 'unified search extension schema ACL is incompatible';
      END IF;

      FOR procedure IN SELECT oid, proowner, proacl, prosecdef FROM pg_proc
        WHERE pronamespace = namespace_oid LOOP
        IF procedure.proowner <> 10 OR procedure.prosecdef
          OR NOT EXISTS (SELECT FROM pg_roles WHERE oid = procedure.proowner AND rolsuper)
          OR NOT EXISTS (
            SELECT FROM pg_depend WHERE classid = 'pg_proc'::regclass AND objid = procedure.oid
              AND refclassid = 'pg_extension'::regclass AND refobjid = extension_oid AND deptype = 'e'
          )
          OR EXISTS (
            SELECT FROM aclexplode(COALESCE(procedure.proacl, acldefault('f', procedure.proowner))) AS acl
            WHERE NOT (
              acl.grantee = procedure.proowner AND acl.grantor = procedure.proowner
                AND acl.privilege_type = 'EXECUTE' AND NOT acl.is_grantable
              OR procedure.oid = ANY(delegated_functions) AND acl.grantee = owner_oid
                AND acl.grantor = procedure.proowner AND acl.privilege_type = 'EXECUTE' AND acl.is_grantable
              OR web_usage AND procedure.oid = ANY(delegated_functions) AND acl.grantee = web_oid
                AND acl.grantor = owner_oid AND acl.privilege_type = 'EXECUTE' AND NOT acl.is_grantable
            )
          )
          OR (SELECT count(*) FROM aclexplode(procedure.proacl) AS acl
              WHERE acl.grantee = procedure.proowner) <> 1
          OR (procedure.oid = ANY(delegated_functions) AND (
            (SELECT count(*) FROM aclexplode(procedure.proacl) AS acl WHERE acl.grantee = owner_oid) <> 1
            OR (SELECT count(*) FROM aclexplode(procedure.proacl) AS acl WHERE acl.grantee = web_oid)
              <> CASE WHEN web_usage THEN 1 ELSE 0 END
          ))
        THEN
          RAISE EXCEPTION 'unified search extension function ownership or ACL is incompatible';
        END IF;
      END LOOP;
    END
    $guard$;
    """)
  end

  defp create_projection do
    execute("""
    CREATE TABLE content.search_entries (
      entry_id text CONSTRAINT search_entries_pkey PRIMARY KEY,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      resource_id uuid NOT NULL,
      resource_version_id uuid NOT NULL,
      kind text NOT NULL,
      note_resource_version_id uuid,
      fragment_id text,
      ordinal bigint NOT NULL,
      title text NOT NULL,
      body text NOT NULL,
      locator jsonb NOT NULL,
      source_inserted_at timestamptz(6) NOT NULL,
      projection_version integer NOT NULL,
      search_vector tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('simple'::regconfig, title), 'A') ||
        setweight(to_tsvector('simple'::regconfig, body), 'D')
      ) STORED NOT NULL,
      CONSTRAINT search_entries_private_check CHECK (classification = 'private'),
      CONSTRAINT search_entries_kind_check CHECK (kind IN ('note', 'document')),
      CONSTRAINT search_entries_title_check CHECK (btrim(title) <> '' AND octet_length(title) <= 255),
      CONSTRAINT search_entries_projection_version_check CHECK (projection_version = 1),
      CONSTRAINT search_entries_source_time_check CHECK (isfinite(source_inserted_at)),
      CONSTRAINT search_entries_source_shape_check CHECK ((
        kind = 'note' AND note_resource_version_id IS NOT NULL
          AND note_resource_version_id = resource_version_id AND fragment_id IS NULL
          AND ordinal = 0 AND entry_id = 'note:' || resource_version_id::text
          AND octet_length(body) <= 1048576
          AND locator = '{"version":1,"kind":"markdown","heading_path":[]}'::jsonb
          AND locator = content.document_canonical_locator(locator)
        OR kind = 'document' AND note_resource_version_id IS NULL AND fragment_id IS NOT NULL
          AND fragment_id ~ '^[0-9a-f]{64}$' AND ordinal >= 0
          AND entry_id = 'document:' || fragment_id AND octet_length(body) <= 65536
          AND position(chr(13) IN body) = 0
          AND locator = content.document_canonical_locator(locator)
          AND (locator->>'kind' <> 'fragment' OR locator->>'ordinal' = ordinal::text)
          AND fragment_id = content.document_fragment_id(
            resource_version_id, locator, ordinal, sha256(convert_to(body, 'UTF8'))
          )
      ) IS TRUE),
      CONSTRAINT search_entries_resource_version_fkey
        FOREIGN KEY (resource_version_id, resource_id, vault_id, classification)
        REFERENCES content.resource_versions(id, resource_id, vault_id, classification),
      CONSTRAINT search_entries_note_version_fkey
        FOREIGN KEY (note_resource_version_id, resource_id, vault_id, classification)
        REFERENCES content.note_versions(resource_version_id, resource_id, vault_id, classification) MATCH SIMPLE,
      CONSTRAINT search_entries_document_fragment_fkey
        FOREIGN KEY (fragment_id, resource_id, resource_version_id, vault_id, classification)
        REFERENCES content.document_fragments(id, resource_id, resource_version_id, vault_id, classification) MATCH SIMPLE
    )
    """)
  end

  defp create_indexes do
    execute("CREATE INDEX search_entries_fts ON content.search_entries USING gin(search_vector)")

    execute("""
    CREATE INDEX search_entries_title_trigram ON content.search_entries
      USING gin(title search_extensions.gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX search_entries_body_trigram ON content.search_entries
      USING gin(body search_extensions.gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX search_entries_owner_kind_source ON content.search_entries
      (vault_id, kind, source_inserted_at DESC, entry_id)
    """)

    execute("""
    CREATE UNIQUE INDEX search_entries_note_resource ON content.search_entries(resource_id)
      WHERE kind = 'note'
    """)

    execute("""
    CREATE UNIQUE INDEX search_entries_document_fragment ON content.search_entries(fragment_id)
      WHERE kind = 'document'
    """)
  end

  defp create_rls_and_grants do
    execute("ALTER TABLE content.search_entries ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE content.search_entries FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY search_entries_table_owner ON content.search_entries
      FOR ALL TO singularity_table_owner USING (true) WITH CHECK (true)
    """)

    execute("""
    CREATE POLICY search_entries_vault_isolation ON content.search_entries
      FOR SELECT TO singularity_web USING (
        nullif(current_setting('singularity.principal_id', true), '') IS NOT NULL
        AND nullif(current_setting('singularity.vault_id', true), '') IS NOT NULL
        AND vault_id = nullif(current_setting('singularity.vault_id', true), '')::uuid
        AND core.principal_is_authorized(
          nullif(current_setting('singularity.principal_id', true), '')::uuid, vault_id
        )
      )
    """)

    execute("GRANT USAGE ON SCHEMA search_extensions TO singularity_web")

    execute("""
    GRANT EXECUTE ON FUNCTION search_extensions.similarity(text, text),
      search_extensions.similarity_op(text, text) TO singularity_web
    """)

    execute("""
    GRANT SELECT ON content.search_entries, content.tags, content.resource_tags TO singularity_web
    """)
  end
end
