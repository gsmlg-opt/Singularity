\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = SESSION_USER
      AND rolsuper
  ) THEN
    RAISE EXCEPTION 'bootstrap_roles.sql requires a PostgreSQL superuser';
  END IF;
END
$$;

DO $$
DECLARE
  role_name text;
BEGIN
  FOREACH role_name IN ARRAY ARRAY[
    'singularity_table_owner',
    'singularity_auth_definer',
    'singularity_authorization_definer',
    'singularity_outbox_definer',
    'singularity_migration',
    'singularity_pre_auth',
    'singularity_web',
    'singularity_dispatcher',
    'singularity_worker'
  ]
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_roles
      WHERE rolname = role_name
    ) THEN
      EXECUTE format('CREATE ROLE %I', role_name);
    END IF;
  END LOOP;
END
$$;

ALTER ROLE singularity_table_owner
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS NOREPLICATION;
ALTER ROLE singularity_auth_definer
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS NOREPLICATION;
ALTER ROLE singularity_authorization_definer
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS NOREPLICATION;
ALTER ROLE singularity_outbox_definer
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS NOREPLICATION;

ALTER ROLE singularity_migration
  LOGIN NOSUPERUSER CREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS NOREPLICATION;
ALTER ROLE singularity_pre_auth
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS NOREPLICATION;
ALTER ROLE singularity_web
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS NOREPLICATION;
ALTER ROLE singularity_dispatcher
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS NOREPLICATION;
ALTER ROLE singularity_worker
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS NOREPLICATION;

DO $$
DECLARE
  membership_edge record;
  managed_roles CONSTANT text[] := ARRAY[
    'singularity_table_owner',
    'singularity_auth_definer',
    'singularity_authorization_definer',
    'singularity_outbox_definer',
    'singularity_migration',
    'singularity_pre_auth',
    'singularity_web',
    'singularity_dispatcher',
    'singularity_worker'
  ];
BEGIN
  FOR membership_edge IN
    SELECT
      granted.rolname AS granted_role,
      member.rolname AS member_role,
      grantor.rolname AS grantor_role
    FROM pg_catalog.pg_auth_members AS membership
    JOIN pg_catalog.pg_roles AS granted ON granted.oid = membership.roleid
    JOIN pg_catalog.pg_roles AS member ON member.oid = membership.member
    JOIN pg_catalog.pg_roles AS grantor ON grantor.oid = membership.grantor
    WHERE granted.rolname = ANY(managed_roles)
      OR member.rolname = ANY(managed_roles)
    ORDER BY granted.rolname, member.rolname, grantor.rolname
  LOOP
    EXECUTE format(
      'REVOKE %I FROM %I GRANTED BY %I CASCADE',
      membership_edge.granted_role,
      membership_edge.member_role,
      membership_edge.grantor_role
    );
  END LOOP;
END
$$;

GRANT
  singularity_table_owner,
  singularity_auth_definer,
  singularity_authorization_definer,
  singularity_outbox_definer
TO singularity_migration WITH SET TRUE;

GRANT
  singularity_table_owner,
  singularity_auth_definer,
  singularity_authorization_definer,
  singularity_outbox_definer
TO singularity_migration WITH INHERIT FALSE;

GRANT
  singularity_table_owner,
  singularity_auth_definer,
  singularity_authorization_definer,
  singularity_outbox_definer
TO singularity_migration WITH ADMIN FALSE;

DO $$
DECLARE
  invalid_role text;
  managed_membership_count bigint;
  valid_membership_count bigint;
  valid_owner_count bigint;
  managed_roles CONSTANT text[] := ARRAY[
    'singularity_table_owner',
    'singularity_auth_definer',
    'singularity_authorization_definer',
    'singularity_outbox_definer',
    'singularity_migration',
    'singularity_pre_auth',
    'singularity_web',
    'singularity_dispatcher',
    'singularity_worker'
  ];
  owner_roles CONSTANT text[] := ARRAY[
    'singularity_table_owner',
    'singularity_auth_definer',
    'singularity_authorization_definer',
    'singularity_outbox_definer'
  ];
BEGIN
  SELECT role.rolname
  INTO invalid_role
  FROM pg_catalog.pg_roles AS role
  WHERE role.rolname IN (
      'singularity_table_owner',
      'singularity_auth_definer',
      'singularity_authorization_definer',
      'singularity_outbox_definer'
    )
    AND (
      role.rolcanlogin
      OR role.rolsuper
      OR role.rolcreatedb
      OR role.rolcreaterole
      OR role.rolinherit
      OR role.rolbypassrls
      OR role.rolreplication
    )
  LIMIT 1;

  IF invalid_role IS NOT NULL THEN
    RAISE EXCEPTION 'owner role % has unsafe attributes', invalid_role;
  END IF;

  SELECT role.rolname
  INTO invalid_role
  FROM pg_catalog.pg_roles AS role
  WHERE role.rolname IN (
      'singularity_pre_auth',
      'singularity_web',
      'singularity_dispatcher',
      'singularity_worker'
    )
    AND (
      NOT role.rolcanlogin
      OR role.rolsuper
      OR role.rolcreatedb
      OR role.rolcreaterole
      OR role.rolinherit
      OR role.rolbypassrls
      OR role.rolreplication
    )
  LIMIT 1;

  IF invalid_role IS NOT NULL THEN
    RAISE EXCEPTION 'runtime role % has unsafe attributes', invalid_role;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles AS role
    WHERE role.rolname = 'singularity_migration'
      AND role.rolcanlogin
      AND NOT role.rolsuper
      AND role.rolcreatedb
      AND NOT role.rolcreaterole
      AND NOT role.rolinherit
      AND NOT role.rolbypassrls
      AND NOT role.rolreplication
  ) THEN
    RAISE EXCEPTION 'singularity_migration has unsafe attributes';
  END IF;

  SELECT
    count(*),
    count(*) FILTER (
      WHERE granted.rolname = ANY(owner_roles)
        AND member.rolname = 'singularity_migration'
        AND NOT membership.admin_option
        AND NOT membership.inherit_option
        AND membership.set_option
    ),
    count(DISTINCT granted.rolname) FILTER (
      WHERE granted.rolname = ANY(owner_roles)
        AND member.rolname = 'singularity_migration'
        AND NOT membership.admin_option
        AND NOT membership.inherit_option
        AND membership.set_option
    )
  INTO managed_membership_count, valid_membership_count, valid_owner_count
  FROM pg_catalog.pg_auth_members AS membership
  JOIN pg_catalog.pg_roles AS granted ON granted.oid = membership.roleid
  JOIN pg_catalog.pg_roles AS member ON member.oid = membership.member
  WHERE granted.rolname = ANY(managed_roles)
    OR member.rolname = ANY(managed_roles);

  IF managed_membership_count <> 4
    OR valid_membership_count <> 4
    OR valid_owner_count <> 4
  THEN
    RAISE EXCEPTION 'managed-role memberships do not match the exact contract';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'singularity_pre_auth',
      'singularity_web',
      'singularity_dispatcher',
      'singularity_worker'
    ]) AS runtime(role_name)
    CROSS JOIN unnest(ARRAY[
      'singularity_table_owner',
      'singularity_auth_definer',
      'singularity_authorization_definer',
      'singularity_outbox_definer'
    ]) AS owner(role_name)
    WHERE pg_has_role(runtime.role_name, owner.role_name, 'SET')
      OR pg_has_role(runtime.role_name, owner.role_name, 'USAGE')
  ) THEN
    RAISE EXCEPTION 'a runtime role can SET or inherit an owner role';
  END IF;
END
$$;

COMMIT;
