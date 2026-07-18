defmodule Singularity.Storage.Migrations.AddTask11AuthorizationFunctions do
  use Ecto.Migration

  @legacy_dummy_verifier "$argon2id$v=19$m=65536,t=3,p=1$c2luZ3VsYXJpdHlkdW1teQ$c2luZ3VsYXJpdHlkdW1teXZlcmlmaWVy"
  @task11_dummy_verifier "$argon2id$v=19$m=65536,t=3,p=1$c2luZ3VsYXJpdHlkdW1teQ$5X38g/2eiHv9wnPQes+dkvbHR0wcGqDoPXStyiEIaHo"

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    replace_dummy_verifier(@task11_dummy_verifier)
    create_pre_auth_epoch_policies()
    grant_pre_auth_epoch_columns()
    replace_session_resolver(:task11)
    create_read_policies()
    create_credential_update_policy()
    grant_exact_columns()

    execute("""
    GRANT USAGE, CREATE ON SCHEMA identity, core
    TO singularity_authorization_definer
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_authorization_definer")

    create_live_session_snapshot()
    create_live_principal_snapshot()
    create_credential_update()

    for signature <- [
          "core.live_session_authorization(uuid)",
          "core.live_principal_authorization()",
          "identity.update_scoped_credential_verifier(uuid, timestamptz, text)"
        ] do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
    end

    execute("""
    GRANT EXECUTE ON FUNCTION core.live_session_authorization(uuid)
    TO singularity_web
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION core.live_principal_authorization()
    TO singularity_web, singularity_worker
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION identity.update_scoped_credential_verifier(
      uuid,
      timestamptz,
      text
    )
    TO singularity_web
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    REVOKE CREATE ON SCHEMA identity, core
    FROM singularity_authorization_definer
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_authorization_definer")

    execute("""
    DROP FUNCTION IF EXISTS identity.update_scoped_credential_verifier(
      uuid,
      timestamptz,
      text
    )
    """)

    execute("DROP FUNCTION IF EXISTS core.live_principal_authorization()")
    execute("DROP FUNCTION IF EXISTS core.live_session_authorization(uuid)")

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")

    replace_dummy_verifier(@legacy_dummy_verifier)
    replace_session_resolver(:legacy)

    execute("""
    REVOKE SELECT (id, authorization_epoch, revoked_at)
    ON identity.principals
    FROM singularity_auth_definer
    """)

    execute("""
    REVOKE SELECT (id, authorization_epoch)
    ON core.vaults
    FROM singularity_auth_definer
    """)

    execute("""
    REVOKE SELECT (principal_id, vault_id, revoked_at)
    ON core.vault_members
    FROM singularity_auth_definer
    """)

    for {table, policy} <- [
          {"identity.principals", "task11_auth_definer_reads_principal_epoch"},
          {"core.vaults", "task11_auth_definer_reads_vault_epoch"},
          {"core.vault_members", "task11_auth_definer_reads_membership"}
        ] do
      execute("DROP POLICY IF EXISTS #{policy} ON #{table}")
    end

    execute("REVOKE USAGE ON SCHEMA core FROM singularity_auth_definer")

    execute("""
    REVOKE SELECT (id, account_id, updated_at, revoked_at),
      UPDATE (verifier, updated_at)
    ON identity.credentials
    FROM singularity_authorization_definer
    """)

    execute("""
    REVOKE SELECT (
      id,
      principal_id,
      vault_id,
      account_id,
      expires_at,
      revoked_at
    )
    ON identity.sessions
    FROM singularity_authorization_definer
    """)

    execute("""
    REVOKE SELECT (
      id,
      account_id,
      kind,
      authorization_epoch,
      revoked_at
    )
    ON identity.principals
    FROM singularity_authorization_definer
    """)

    execute("""
    REVOKE SELECT (id, authorization_epoch, locked)
    ON core.vaults
    FROM singularity_authorization_definer
    """)

    execute("""
    REVOKE SELECT (clearance)
    ON core.vault_members
    FROM singularity_authorization_definer
    """)

    execute("""
    REVOKE SELECT (principal_id, vault_id, capability_id, revoked_at)
    ON core.principal_capabilities
    FROM singularity_authorization_definer
    """)

    execute("""
    REVOKE SELECT (id, name)
    ON core.capabilities
    FROM singularity_authorization_definer
    """)

    for {table, policy} <- [
          {"identity.sessions", "task11_authorization_reads_sessions"},
          {"identity.principals", "task11_authorization_reads_principals"},
          {"identity.credentials", "task11_authorization_reads_credentials"},
          {"identity.credentials", "task11_authorization_updates_credentials"},
          {"core.vaults", "task11_authorization_reads_vaults"},
          {"core.principal_capabilities", "task11_authorization_reads_assignments"},
          {"core.capabilities", "task11_authorization_reads_capabilities"}
        ] do
      execute("DROP POLICY IF EXISTS #{policy} ON #{table}")
    end

    execute("""
    REVOKE USAGE ON SCHEMA identity
    FROM singularity_authorization_definer
    """)

    execute("SET LOCAL ROLE NONE")
  end

  defp replace_dummy_verifier(verifier) do
    execute("""
    UPDATE identity.security_settings
    SET
      dummy_verifier = '#{verifier}',
      updated_at = CURRENT_TIMESTAMP
    WHERE singleton
    """)
  end

  defp create_pre_auth_epoch_policies do
    for {table, policy} <- [
          {"identity.principals", "task11_auth_definer_reads_principal_epoch"},
          {"core.vaults", "task11_auth_definer_reads_vault_epoch"},
          {"core.vault_members", "task11_auth_definer_reads_membership"}
        ] do
      execute("""
      CREATE POLICY #{policy}
      ON #{table}
      FOR SELECT
      TO singularity_auth_definer
      USING (true)
      """)
    end
  end

  defp grant_pre_auth_epoch_columns do
    execute("""
    GRANT SELECT (id, authorization_epoch, revoked_at)
    ON identity.principals
    TO singularity_auth_definer
    """)

    execute("""
    GRANT SELECT (id, authorization_epoch)
    ON core.vaults
    TO singularity_auth_definer
    """)

    execute("""
    GRANT SELECT (principal_id, vault_id, revoked_at)
    ON core.vault_members
    TO singularity_auth_definer
    """)
  end

  defp replace_session_resolver(version) do
    execute("""
    GRANT USAGE, CREATE ON SCHEMA identity
    TO singularity_auth_definer
    """)

    if version == :task11 do
      execute("GRANT USAGE ON SCHEMA core TO singularity_auth_definer")
    end

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_auth_definer")
    execute("DROP FUNCTION IF EXISTS identity.resolve_session(bytea)")

    execute(session_resolver_sql(version))

    execute("REVOKE ALL ON FUNCTION identity.resolve_session(bytea) FROM PUBLIC")

    execute("""
    GRANT EXECUTE ON FUNCTION identity.resolve_session(bytea)
    TO singularity_pre_auth
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    REVOKE CREATE ON SCHEMA identity
    FROM singularity_auth_definer
    """)
  end

  defp session_resolver_sql(:task11) do
    """
    CREATE FUNCTION identity.resolve_session(
      requested_token_digest bytea
    ) RETURNS TABLE (
      session_id uuid,
      principal_id uuid,
      vault_id uuid,
      expires_at timestamptz,
      principal_authorization_epoch bigint,
      vault_authorization_epoch bigint
    )
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, identity, core
    AS $function$
      SELECT
        session.id,
        principal.id,
        vault.id,
        session.expires_at,
        principal.authorization_epoch,
        vault.authorization_epoch
      FROM identity.sessions AS session
      JOIN identity.principals AS principal
        ON principal.id = session.principal_id
       AND principal.revoked_at IS NULL
      JOIN core.vaults AS vault
        ON vault.id = session.vault_id
      JOIN core.vault_members AS membership
        ON membership.principal_id = principal.id
       AND membership.vault_id = vault.id
       AND membership.revoked_at IS NULL
      WHERE octet_length(requested_token_digest) = 32
        AND session.token_digest = requested_token_digest
        AND session.revoked_at IS NULL
        AND session.expires_at > CURRENT_TIMESTAMP
      LIMIT 1
    $function$
    """
  end

  defp session_resolver_sql(:legacy) do
    """
    CREATE FUNCTION identity.resolve_session(
      requested_token_digest bytea
    ) RETURNS TABLE (
      session_id uuid,
      principal_id uuid,
      vault_id uuid,
      expires_at timestamptz
    )
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, identity, core, audit
    AS $function$
      SELECT
        session.id,
        session.principal_id,
        session.vault_id,
        session.expires_at
      FROM identity.sessions AS session
      WHERE octet_length(requested_token_digest) = 32
        AND session.token_digest = requested_token_digest
        AND session.revoked_at IS NULL
        AND session.expires_at > CURRENT_TIMESTAMP
      LIMIT 1
    $function$
    """
  end

  defp create_read_policies do
    for {table, policy} <- [
          {"identity.sessions", "task11_authorization_reads_sessions"},
          {"identity.principals", "task11_authorization_reads_principals"},
          {"identity.credentials", "task11_authorization_reads_credentials"},
          {"core.vaults", "task11_authorization_reads_vaults"},
          {"core.principal_capabilities", "task11_authorization_reads_assignments"},
          {"core.capabilities", "task11_authorization_reads_capabilities"}
        ] do
      execute("""
      CREATE POLICY #{policy}
      ON #{table}
      FOR SELECT
      TO singularity_authorization_definer
      USING (true)
      """)
    end
  end

  defp create_credential_update_policy do
    execute("""
    CREATE POLICY task11_authorization_updates_credentials
    ON identity.credentials
    FOR UPDATE
    TO singularity_authorization_definer
    USING (true)
    WITH CHECK (true)
    """)
  end

  defp grant_exact_columns do
    execute("""
    GRANT SELECT (
      id,
      principal_id,
      vault_id,
      account_id,
      expires_at,
      revoked_at
    )
    ON identity.sessions
    TO singularity_authorization_definer
    """)

    execute("""
    GRANT SELECT (
      id,
      account_id,
      kind,
      authorization_epoch,
      revoked_at
    )
    ON identity.principals
    TO singularity_authorization_definer
    """)

    execute("""
    GRANT SELECT (id, account_id, updated_at, revoked_at),
      UPDATE (verifier, updated_at)
    ON identity.credentials
    TO singularity_authorization_definer
    """)

    execute("""
    GRANT SELECT (id, authorization_epoch, locked)
    ON core.vaults
    TO singularity_authorization_definer
    """)

    execute("""
    GRANT SELECT (clearance)
    ON core.vault_members
    TO singularity_authorization_definer
    """)

    execute("""
    GRANT SELECT (principal_id, vault_id, capability_id, revoked_at)
    ON core.principal_capabilities
    TO singularity_authorization_definer
    """)

    execute("""
    GRANT SELECT (id, name)
    ON core.capabilities
    TO singularity_authorization_definer
    """)
  end

  defp create_live_session_snapshot do
    execute("""
    CREATE OR REPLACE FUNCTION core.live_session_authorization(
      requested_session uuid
    ) RETURNS TABLE (
      session_id uuid,
      account_id uuid,
      session_expires_at timestamptz,
      session_revoked_at timestamptz,
      credential_id uuid,
      credential_revision timestamptz,
      principal_id uuid,
      principal_kind text,
      principal_authorization_epoch bigint,
      principal_revoked_at timestamptz,
      vault_id uuid,
      vault_authorization_epoch bigint,
      vault_locked boolean,
      membership_revoked_at timestamptz,
      clearance text,
      capabilities text[]
    )
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, identity, core
    AS $function$
      WITH scoped AS (
        SELECT
          NULLIF(
            current_setting('singularity.principal_id', true),
            ''
          )::uuid AS principal_id,
          NULLIF(
            current_setting('singularity.vault_id', true),
            ''
          )::uuid AS vault_id
      )
      SELECT
        session.id,
        principal.account_id,
        session.expires_at,
        session.revoked_at,
        credential.id,
        credential.updated_at,
        principal.id,
        principal.kind,
        principal.authorization_epoch,
        principal.revoked_at,
        vault.id,
        vault.authorization_epoch,
        vault.locked,
        membership.revoked_at,
        membership.clearance,
        COALESCE(
          (
            SELECT array_agg(capability.name ORDER BY capability.name)
            FROM core.principal_capabilities AS assignment
            JOIN core.capabilities AS capability
              ON capability.id = assignment.capability_id
            WHERE assignment.principal_id = principal.id
              AND assignment.vault_id = vault.id
              AND assignment.revoked_at IS NULL
          ),
          ARRAY[]::text[]
        )
      FROM scoped
      JOIN identity.sessions AS session
        ON session.id = requested_session
       AND session.principal_id = scoped.principal_id
       AND session.vault_id = scoped.vault_id
      JOIN identity.principals AS principal
        ON principal.id = session.principal_id
       AND principal.account_id = session.account_id
      JOIN LATERAL (
        SELECT candidate.id, candidate.updated_at
        FROM identity.credentials AS candidate
        WHERE candidate.account_id = principal.account_id
          AND candidate.revoked_at IS NULL
        ORDER BY candidate.id
        LIMIT 1
      ) AS credential ON true
      JOIN core.vaults AS vault
        ON vault.id = session.vault_id
      JOIN core.vault_members AS membership
        ON membership.principal_id = principal.id
       AND membership.vault_id = vault.id
      LIMIT 1
    $function$
    """)
  end

  defp create_live_principal_snapshot do
    execute("""
    CREATE OR REPLACE FUNCTION core.live_principal_authorization()
    RETURNS TABLE (
      principal_id uuid,
      principal_kind text,
      principal_authorization_epoch bigint,
      principal_revoked_at timestamptz,
      vault_id uuid,
      vault_authorization_epoch bigint,
      vault_locked boolean,
      membership_revoked_at timestamptz,
      clearance text,
      capabilities text[]
    )
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, identity, core
    AS $function$
      WITH scoped AS (
        SELECT
          NULLIF(
            current_setting('singularity.principal_id', true),
            ''
          )::uuid AS principal_id,
          NULLIF(
            current_setting('singularity.vault_id', true),
            ''
          )::uuid AS vault_id
      )
      SELECT
        principal.id,
        principal.kind,
        principal.authorization_epoch,
        principal.revoked_at,
        vault.id,
        vault.authorization_epoch,
        vault.locked,
        membership.revoked_at,
        membership.clearance,
        COALESCE(
          (
            SELECT array_agg(capability.name ORDER BY capability.name)
            FROM core.principal_capabilities AS assignment
            JOIN core.capabilities AS capability
              ON capability.id = assignment.capability_id
            WHERE assignment.principal_id = principal.id
              AND assignment.vault_id = vault.id
              AND assignment.revoked_at IS NULL
          ),
          ARRAY[]::text[]
        )
      FROM scoped
      JOIN identity.principals AS principal
        ON principal.id = scoped.principal_id
      JOIN core.vaults AS vault
        ON vault.id = scoped.vault_id
      JOIN core.vault_members AS membership
        ON membership.principal_id = principal.id
       AND membership.vault_id = vault.id
      LIMIT 1
    $function$
    """)
  end

  defp create_credential_update do
    execute("""
    CREATE OR REPLACE FUNCTION identity.update_scoped_credential_verifier(
      requested_credential uuid,
      expected_revision timestamptz,
      replacement_verifier text
    ) RETURNS boolean
    LANGUAGE sql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, identity, core
    AS $function$
      WITH scoped AS (
        SELECT
          NULLIF(
            current_setting('singularity.principal_id', true),
            ''
          )::uuid AS principal_id,
          NULLIF(
            current_setting('singularity.vault_id', true),
            ''
          )::uuid AS vault_id
      ),
      updated AS (
        UPDATE identity.credentials AS credential
        SET
          verifier = replacement_verifier,
          updated_at = clock_timestamp()
        FROM scoped, identity.principals AS principal
        WHERE requested_credential IS NOT NULL
          AND expected_revision IS NOT NULL
          AND replacement_verifier IS NOT NULL
          AND btrim(replacement_verifier) <> ''
          AND principal.id = scoped.principal_id
          AND principal.revoked_at IS NULL
          AND credential.id = requested_credential
          AND credential.account_id = principal.account_id
          AND credential.updated_at = expected_revision
          AND credential.revoked_at IS NULL
          AND EXISTS (
            SELECT 1
            FROM core.vault_members AS membership
            WHERE membership.principal_id = principal.id
              AND membership.vault_id = scoped.vault_id
              AND membership.revoked_at IS NULL
          )
        RETURNING credential.id
      )
      SELECT EXISTS(SELECT 1 FROM updated)
    $function$
    """)
  end
end
