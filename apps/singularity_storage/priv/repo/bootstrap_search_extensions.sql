\set ON_ERROR_STOP on

BEGIN;
SET LOCAL search_path = pg_catalog, pg_temp;

DO $bootstrap$
DECLARE
  namespace_oid oid;
  extension_oid oid;
  owner_oid oid;
  web_oid oid;
  expected_functions oid[];
  delegated_functions oid[];
  procedure record;
  web_usage boolean;
  managed_roles CONSTANT text[] := ARRAY[
    'singularity_table_owner', 'singularity_auth_definer',
    'singularity_authorization_definer', 'singularity_outbox_definer',
    'singularity_migration', 'singularity_pre_auth', 'singularity_web',
    'singularity_dispatcher', 'singularity_worker'
  ];
  owner_roles CONSTANT text[] := ARRAY[
    'singularity_table_owner', 'singularity_auth_definer',
    'singularity_authorization_definer', 'singularity_outbox_definer'
  ];
BEGIN
  IF CURRENT_USER <> SESSION_USER OR NOT EXISTS (
    SELECT FROM pg_roles WHERE rolname = CURRENT_USER AND rolsuper
  ) THEN
    RAISE EXCEPTION 'search extension bootstrap requires administrator authority';
  END IF;

  IF current_database() !~ '^[a-z_][a-z0-9_]{0,62}$'
    OR current_database() IN ('postgres', 'template0', 'template1')
    OR EXISTS (SELECT FROM pg_database WHERE datname = current_database() AND datistemplate)
  THEN
    RAISE EXCEPTION 'search extension bootstrap requires an application database';
  END IF;

  IF (SELECT count(*) FROM pg_roles WHERE rolname = ANY(managed_roles)) <> 9
    OR EXISTS (
      SELECT FROM pg_roles WHERE rolname = ANY(managed_roles) AND (
        rolsuper OR rolcreaterole OR rolinherit OR rolbypassrls OR rolreplication
        OR rolcanlogin <> (NOT rolname = ANY(owner_roles))
        OR rolcreatedb <> (rolname = 'singularity_migration')
      )
    )
    OR (SELECT count(*) FROM pg_auth_members WHERE roleid = ANY (
      SELECT oid FROM pg_roles WHERE rolname = ANY(managed_roles)
    ) OR member = ANY (
      SELECT oid FROM pg_roles WHERE rolname = ANY(managed_roles)
    )) <> 4
    OR (SELECT count(*) FROM pg_auth_members AS membership
        JOIN pg_roles AS granted ON granted.oid = membership.roleid
        JOIN pg_roles AS member ON member.oid = membership.member
        WHERE granted.rolname = ANY(owner_roles) AND member.rolname = 'singularity_migration'
          AND NOT membership.admin_option AND NOT membership.inherit_option AND membership.set_option) <> 4
  THEN
    RAISE EXCEPTION 'search extension bootstrap role prerequisites are incompatible';
  END IF;

  owner_oid := 'singularity_table_owner'::regrole;
  web_oid := 'singularity_web'::regrole;

  IF NOT has_database_privilege(owner_oid, current_database(), 'CREATE') THEN
    RAISE EXCEPTION 'search extension bootstrap installation authority is missing';
  END IF;

  SELECT oid INTO extension_oid FROM pg_extension WHERE extname = 'pg_trgm';
  SELECT oid INTO namespace_oid FROM pg_namespace WHERE nspname = 'search_extensions';

  IF extension_oid IS NULL THEN
    IF namespace_oid IS NOT NULL THEN
      RAISE EXCEPTION 'search extension bootstrap namespace already exists';
    END IF;

    CREATE SCHEMA search_extensions AUTHORIZATION singularity_table_owner;
    SET LOCAL ROLE singularity_table_owner;
    CREATE EXTENSION pg_trgm WITH SCHEMA search_extensions VERSION '1.6';
    RESET ROLE;

    REVOKE ALL ON SCHEMA search_extensions FROM PUBLIC;
    REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA search_extensions FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION search_extensions.similarity(text, text),
      search_extensions.similarity_op(text, text)
      TO singularity_table_owner WITH GRANT OPTION;

    SELECT oid INTO extension_oid FROM pg_extension WHERE extname = 'pg_trgm';
    SELECT oid INTO namespace_oid FROM pg_namespace WHERE nspname = 'search_extensions';
  END IF;

  IF namespace_oid IS NULL OR NOT EXISTS (
    SELECT FROM pg_extension AS extension JOIN pg_namespace AS namespace ON namespace.oid = extension.extnamespace
    WHERE extension.oid = extension_oid AND extension.extnamespace = namespace_oid
      AND extension.extversion = '1.6' AND extension.extowner = owner_oid
      AND namespace.nspowner = owner_oid
  ) THEN
    RAISE EXCEPTION 'search extension bootstrap ownership namespace or version is incompatible';
  END IF;

  -- PostgreSQL 17 pg_trgm 1.6 has this closed function inventory.
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
    'search_extensions.similarity(text,text)'::regprocedure::oid,
    'search_extensions.similarity_op(text,text)'::regprocedure::oid
  ];

  IF array_position(expected_functions, NULL) IS NOT NULL
    OR (SELECT count(*) FROM pg_proc WHERE pronamespace = namespace_oid) <> cardinality(expected_functions)
    OR EXISTS (
      SELECT FROM pg_proc WHERE pronamespace = namespace_oid AND (
        NOT oid = ANY(expected_functions) OR proowner <> 10 OR prosecdef
        OR NOT EXISTS (SELECT FROM pg_roles WHERE oid = proowner AND rolsuper)
        OR NOT EXISTS (SELECT FROM pg_depend WHERE classid = 'pg_proc'::regclass
                      AND objid = pg_proc.oid AND refclassid = 'pg_extension'::regclass
                      AND refobjid = extension_oid AND deptype = 'e')
      )
    )
  THEN
    RAISE EXCEPTION 'search extension bootstrap function inventory or ownership is incompatible';
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
        AND oprleft = 'text'::regtype AND oprright = 'text'::regtype AND oprresult = 'boolean'::regtype
        AND oprcode = 'search_extensions.similarity_op(text,text)'::regprocedure
    )
    OR NOT EXISTS (
      SELECT FROM pg_opclass AS class JOIN pg_am AS method ON method.oid = class.opcmethod
      WHERE class.opcnamespace = namespace_oid AND class.opcname = 'gin_trgm_ops'
        AND method.amname = 'gin' AND class.opcintype = 'text'::regtype
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
  THEN
    RAISE EXCEPTION 'search extension bootstrap objects are incompatible';
  END IF;

  SELECT EXISTS (
    SELECT FROM pg_namespace AS namespace
    CROSS JOIN LATERAL aclexplode(COALESCE(namespace.nspacl, acldefault('n', namespace.nspowner))) AS acl
    WHERE namespace.oid = namespace_oid AND acl.grantee = web_oid AND acl.privilege_type = 'USAGE'
  ) INTO web_usage;

  IF EXISTS (
    SELECT FROM pg_namespace AS namespace
    CROSS JOIN LATERAL aclexplode(COALESCE(namespace.nspacl, acldefault('n', namespace.nspowner))) AS acl
    WHERE namespace.oid = namespace_oid AND NOT (
      acl.grantee = owner_oid AND acl.grantor = owner_oid AND acl.privilege_type IN ('USAGE', 'CREATE') AND NOT acl.is_grantable
      OR acl.grantee = web_oid AND acl.grantor = owner_oid AND acl.privilege_type = 'USAGE' AND NOT acl.is_grantable
    )
  ) OR (SELECT count(*) FROM pg_namespace AS namespace
        CROSS JOIN LATERAL aclexplode(namespace.nspacl) AS acl
        WHERE namespace.oid = namespace_oid AND acl.grantee = owner_oid) <> 2
  THEN
    RAISE EXCEPTION 'search extension bootstrap schema ACL is incompatible';
  END IF;

  FOR procedure IN SELECT oid, proowner, proacl FROM pg_proc WHERE pronamespace = namespace_oid LOOP
    IF EXISTS (
      SELECT FROM aclexplode(COALESCE(procedure.proacl, acldefault('f', procedure.proowner))) AS acl
      WHERE NOT (
        acl.grantee = procedure.proowner AND acl.grantor = procedure.proowner AND acl.privilege_type = 'EXECUTE' AND NOT acl.is_grantable
        OR procedure.oid = ANY(delegated_functions) AND acl.grantee = owner_oid
           AND acl.grantor = procedure.proowner AND acl.privilege_type = 'EXECUTE' AND acl.is_grantable
        OR web_usage AND procedure.oid = ANY(delegated_functions) AND acl.grantee = web_oid
           AND acl.grantor = owner_oid AND acl.privilege_type = 'EXECUTE' AND NOT acl.is_grantable
      )
    ) OR (SELECT count(*) FROM aclexplode(procedure.proacl) AS acl
          WHERE acl.grantee = procedure.proowner) <> 1
      OR (procedure.oid = ANY(delegated_functions) AND (
        (SELECT count(*) FROM aclexplode(procedure.proacl) AS acl WHERE acl.grantee = owner_oid) <> 1
        OR (SELECT count(*) FROM aclexplode(procedure.proacl) AS acl WHERE acl.grantee = web_oid) <> CASE WHEN web_usage THEN 1 ELSE 0 END
      ))
    THEN
      RAISE EXCEPTION 'search extension bootstrap function ACL is incompatible';
    END IF;
  END LOOP;
END
$bootstrap$;

COMMIT;
