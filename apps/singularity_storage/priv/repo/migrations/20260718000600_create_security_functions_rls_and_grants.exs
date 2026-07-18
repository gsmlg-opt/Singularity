defmodule Singularity.Storage.Migrations.CreateSecurityFunctionsRlsAndGrants do
  use Ecto.Migration

  @protected_tables ~w(
    identity.people
    identity.accounts
    identity.credentials
    identity.principals
    identity.sessions
    identity.devices
    identity.auth_attempts
    identity.security_settings
    core.vaults
    core.vault_members
    core.capabilities
    core.principal_capabilities
    core.data_classifications
    core.key_domains
    core.vault_key_versions
    core.vault_key_wrappers
    core.domain_key_versions
    core.domain_dedup_key_wrappers
    core.outbox_events
    content.resources
    content.resource_versions
    content.assets
    content.asset_stages
    content.asset_objects
    content.asset_key_envelopes
    content.asset_metadata
    content.resource_assets
    content.source_references
    content.tombstones
    content.upload_grants
    jobs.job_submissions
    jobs.job_progress
    jobs.effect_receipts
    audit.events
    audit.backup_manifests
    audit.backup_manifest_objects
  )

  @mutable_vault_tables [
    {"identity.sessions", "vault_id"},
    {"identity.devices", "vault_id"},
    {"core.vaults", "id"},
    {"core.vault_members", "vault_id"},
    {"core.principal_capabilities", "vault_id"},
    {"core.key_domains", "vault_id"},
    {"core.vault_key_versions", "vault_id"},
    {"core.vault_key_wrappers", "vault_id"},
    {"core.domain_key_versions", "vault_id"},
    {"core.domain_dedup_key_wrappers", "vault_id"},
    {"content.resources", "vault_id"},
    {"content.resource_versions", "vault_id"},
    {"content.assets", "vault_id"},
    {"content.asset_stages", "vault_id"},
    {"content.asset_objects", "vault_id"},
    {"content.asset_key_envelopes", "vault_id"},
    {"content.asset_metadata", "vault_id"},
    {"content.resource_assets", "vault_id"},
    {"content.source_references", "vault_id"},
    {"content.tombstones", "vault_id"},
    {"content.upload_grants", "vault_id"},
    {"jobs.job_submissions", "vault_id"},
    {"jobs.job_progress", "vault_id"},
    {"jobs.effect_receipts", "vault_id"},
    {"audit.backup_manifests", "vault_id"},
    {"audit.backup_manifest_objects", "vault_id"}
  ]

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    Enum.each(@protected_tables, fn table ->
      policy = String.replace(table, ".", "_") <> "_table_owner"

      execute("ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY")
      execute("ALTER TABLE #{table} FORCE ROW LEVEL SECURITY")

      execute("""
      CREATE POLICY #{policy}
      ON #{table}
      FOR ALL
      TO singularity_table_owner
      USING (true)
      WITH CHECK (true)
      """)
    end)

    create_authorization_function()
    create_runtime_policies()
    create_pre_auth_functions()
    create_outbox_functions()
    grant_oban_access()

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_auth_definer")

    execute("DROP FUNCTION IF EXISTS identity.record_auth_attempt(bytea, bytea, text)")

    execute("DROP FUNCTION IF EXISTS identity.resolve_session(bytea)")
    execute("DROP FUNCTION IF EXISTS identity.authentication_candidate(text)")
    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_outbox_definer")

    execute("DROP FUNCTION IF EXISTS core.acknowledge_outbox_event(uuid, uuid, text)")

    execute("DROP FUNCTION IF EXISTS core.claim_outbox_events(integer, integer, uuid)")

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")

    Enum.each(@mutable_vault_tables, fn {table, _vault_column} ->
      policy = String.replace(table, ".", "_") <> "_vault_isolation"
      execute("DROP POLICY IF EXISTS #{policy} ON #{table}")
    end)

    execute("DROP POLICY IF EXISTS outbox_events_vault_select ON core.outbox_events")

    execute("DROP POLICY IF EXISTS outbox_events_vault_insert ON core.outbox_events")

    execute("DROP POLICY IF EXISTS events_vault_select ON audit.events")
    execute("DROP POLICY IF EXISTS events_vault_insert ON audit.events")

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_authorization_definer")
    execute("DROP FUNCTION IF EXISTS core.principal_is_authorized(uuid, uuid)")
    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")

    revoke_privileges()

    execute("DROP POLICY IF EXISTS capabilities_runtime_read ON core.capabilities")

    execute("DROP POLICY IF EXISTS classifications_runtime_read ON core.data_classifications")

    execute("DROP POLICY IF EXISTS authorization_definer_reads_membership ON core.vault_members")

    execute("DROP POLICY IF EXISTS auth_definer_reads_candidate ON identity.credentials")

    execute("DROP POLICY IF EXISTS auth_definer_reads_account_status ON identity.accounts")

    execute("DROP POLICY IF EXISTS auth_definer_resolves_session ON identity.sessions")

    execute("DROP POLICY IF EXISTS auth_definer_reads_settings ON identity.security_settings")

    execute("DROP POLICY IF EXISTS auth_definer_reads_attempts ON identity.auth_attempts")

    execute("DROP POLICY IF EXISTS auth_definer_records_attempt ON identity.auth_attempts")

    execute("DROP POLICY IF EXISTS auth_definer_writes_audit ON audit.events")

    execute("DROP POLICY IF EXISTS outbox_definer_claims_events ON core.outbox_events")

    execute("DROP POLICY IF EXISTS outbox_definer_updates_events ON core.outbox_events")

    execute("DROP POLICY IF EXISTS outbox_definer_writes_audit ON audit.events")

    Enum.each(@protected_tables, fn table ->
      policy = String.replace(table, ".", "_") <> "_table_owner"
      execute("DROP POLICY IF EXISTS #{policy} ON #{table}")
      execute("ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY")
      execute("ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY")
    end)

    execute("SET LOCAL ROLE NONE")
  end

  defp revoke_privileges do
    Enum.each(@mutable_vault_tables, fn {table, _vault_column} ->
      execute("""
      REVOKE SELECT, INSERT, UPDATE, DELETE
      ON #{table}
      FROM singularity_web, singularity_worker
      """)
    end)

    execute("""
    REVOKE SELECT, INSERT
    ON core.outbox_events, audit.events
    FROM singularity_web, singularity_worker
    """)

    execute("""
    REVOKE SELECT
    ON core.capabilities, core.data_classifications
    FROM singularity_web, singularity_worker
    """)

    execute("""
    REVOKE USAGE, SELECT ON SEQUENCE core.outbox_events_sequence_seq
    FROM singularity_web, singularity_worker
    """)

    execute("""
    REVOKE SELECT, INSERT, UPDATE, DELETE
    ON jobs.oban_jobs, jobs.oban_peers
    FROM singularity_worker
    """)

    execute("""
    REVOKE USAGE, SELECT ON ALL SEQUENCES IN SCHEMA jobs
    FROM singularity_worker
    """)

    execute("""
    REVOKE USAGE ON SCHEMA identity, core, content, jobs, audit
    FROM singularity_web, singularity_worker
    """)

    execute("REVOKE USAGE ON SCHEMA identity FROM singularity_pre_auth")
    execute("REVOKE USAGE ON SCHEMA core FROM singularity_dispatcher")

    execute("""
    REVOKE SELECT (principal_id, vault_id, revoked_at)
    ON core.vault_members
    FROM singularity_authorization_definer
    """)

    execute("""
    REVOKE SELECT (id, status)
    ON identity.accounts
    FROM singularity_auth_definer
    """)

    execute("""
    REVOKE SELECT (id, account_id, normalized_login, verifier, verifier_version, revoked_at)
    ON identity.credentials
    FROM singularity_auth_definer
    """)

    execute("""
    REVOKE SELECT (id, principal_id, vault_id, token_digest, expires_at, revoked_at)
    ON identity.sessions
    FROM singularity_auth_definer
    """)

    execute("""
    REVOKE SELECT (
      dummy_verifier,
      login_window_seconds,
      login_max_attempts,
      source_window_seconds,
      source_max_attempts
    )
    ON identity.security_settings
    FROM singularity_auth_definer
    """)

    execute("""
    REVOKE SELECT (login_fingerprint, source_fingerprint, result, attempted_at),
      INSERT (id, login_fingerprint, source_fingerprint, result, correlation_id)
    ON identity.auth_attempts
    FROM singularity_auth_definer
    """)

    execute("""
    REVOKE INSERT (
      id,
      vault_id,
      actor_kind,
      principal_id,
      anonymous_fingerprint,
      operation,
      result,
      classification,
      correlation_id,
      occurred_at
    )
    ON audit.events
    FROM singularity_auth_definer
    """)

    execute("""
    REVOKE SELECT (
      id,
      sequence,
      event_type,
      idempotency_key,
      vault_id,
      principal_id,
      required_capability,
      authorization_epoch,
      classification,
      correlation_id,
      causation_id,
      expected_entity_revision,
      envelope_version,
      payload,
      occurred_at,
      claim_token,
      claimed_until,
      runner_job_id,
      delivered_at
    ),
    UPDATE (claim_token, claimed_until, runner_job_id, delivered_at, updated_at)
    ON core.outbox_events
    FROM singularity_outbox_definer
    """)

    execute("""
    REVOKE INSERT (
      id,
      vault_id,
      actor_kind,
      principal_id,
      anonymous_fingerprint,
      operation,
      result,
      classification,
      correlation_id,
      target_type,
      target_id,
      occurred_at
    )
    ON audit.events
    FROM singularity_outbox_definer
    """)

    execute("REVOKE USAGE ON SCHEMA core FROM singularity_authorization_definer")

    execute("REVOKE USAGE ON SCHEMA identity, audit FROM singularity_auth_definer")

    execute("REVOKE USAGE ON SCHEMA core, audit FROM singularity_outbox_definer")
  end

  defp create_authorization_function do
    execute("""
    CREATE POLICY authorization_definer_reads_membership
    ON core.vault_members
    FOR SELECT
    TO singularity_authorization_definer
    USING (true)
    """)

    execute("GRANT USAGE, CREATE ON SCHEMA core TO singularity_authorization_definer")

    execute("""
    GRANT SELECT (principal_id, vault_id, revoked_at)
    ON core.vault_members
    TO singularity_authorization_definer
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_authorization_definer")

    execute("""
    CREATE OR REPLACE FUNCTION core.principal_is_authorized(
      requested_principal uuid,
      requested_vault uuid
    ) RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, core
    AS $function$
      SELECT COALESCE(
        requested_principal =
            NULLIF(
              current_setting('singularity.principal_id', true),
              ''
            )::uuid
          AND requested_vault =
            NULLIF(
              current_setting('singularity.vault_id', true),
              ''
            )::uuid
          AND EXISTS (
            SELECT 1
            FROM core.vault_members AS membership
            WHERE membership.principal_id = requested_principal
              AND membership.vault_id = requested_vault
              AND membership.revoked_at IS NULL
          ),
        false
      )
    $function$
    """)

    execute("REVOKE ALL ON FUNCTION core.principal_is_authorized(uuid, uuid) FROM PUBLIC")

    execute("""
    GRANT EXECUTE ON FUNCTION core.principal_is_authorized(uuid, uuid)
    TO singularity_web, singularity_worker
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("REVOKE CREATE ON SCHEMA core FROM singularity_authorization_definer")
  end

  defp create_runtime_policies do
    execute("""
    GRANT USAGE ON SCHEMA identity, core, content, jobs, audit
    TO singularity_web, singularity_worker
    """)

    Enum.each(@mutable_vault_tables, fn {table, vault_column} ->
      policy = String.replace(table, ".", "_") <> "_vault_isolation"

      execute("""
      CREATE POLICY #{policy}
      ON #{table}
      FOR ALL
      TO singularity_web, singularity_worker
      USING (#{vault_predicate(vault_column)})
      WITH CHECK (#{vault_predicate(vault_column)})
      """)

      execute("""
      GRANT SELECT, INSERT, UPDATE, DELETE
      ON #{table}
      TO singularity_web, singularity_worker
      """)
    end)

    create_select_insert_policies(
      "core.outbox_events",
      "outbox_events",
      "vault_id"
    )

    create_select_insert_policies("audit.events", "events", "vault_id")

    execute("""
    CREATE POLICY capabilities_runtime_read
    ON core.capabilities
    FOR SELECT
    TO singularity_web, singularity_worker
    USING (true)
    """)

    execute("""
    CREATE POLICY classifications_runtime_read
    ON core.data_classifications
    FOR SELECT
    TO singularity_web, singularity_worker
    USING (true)
    """)

    execute("""
    GRANT SELECT ON core.capabilities, core.data_classifications
    TO singularity_web, singularity_worker
    """)

    execute("""
    GRANT USAGE, SELECT ON SEQUENCE core.outbox_events_sequence_seq
    TO singularity_web, singularity_worker
    """)
  end

  defp create_pre_auth_functions do
    execute("""
    CREATE POLICY auth_definer_reads_account_status
    ON identity.accounts
    FOR SELECT
    TO singularity_auth_definer
    USING (true)
    """)

    execute("""
    CREATE POLICY auth_definer_reads_candidate
    ON identity.credentials
    FOR SELECT
    TO singularity_auth_definer
    USING (true)
    """)

    execute("""
    CREATE POLICY auth_definer_resolves_session
    ON identity.sessions
    FOR SELECT
    TO singularity_auth_definer
    USING (true)
    """)

    execute("""
    CREATE POLICY auth_definer_reads_settings
    ON identity.security_settings
    FOR SELECT
    TO singularity_auth_definer
    USING (true)
    """)

    execute("""
    CREATE POLICY auth_definer_reads_attempts
    ON identity.auth_attempts
    FOR SELECT
    TO singularity_auth_definer
    USING (true)
    """)

    execute("""
    CREATE POLICY auth_definer_records_attempt
    ON identity.auth_attempts
    FOR INSERT
    TO singularity_auth_definer
    WITH CHECK (true)
    """)

    execute("""
    CREATE POLICY auth_definer_writes_audit
    ON audit.events
    FOR INSERT
    TO singularity_auth_definer
    WITH CHECK (
      actor_kind = 'anonymous'
      AND principal_id IS NULL
      AND vault_id IS NULL
      AND octet_length(anonymous_fingerprint) = 32
    )
    """)

    execute("GRANT USAGE, CREATE ON SCHEMA identity TO singularity_auth_definer")
    execute("GRANT USAGE ON SCHEMA audit TO singularity_auth_definer")

    execute("""
    GRANT SELECT (id, status)
    ON identity.accounts
    TO singularity_auth_definer
    """)

    execute("""
    GRANT SELECT (id, account_id, normalized_login, verifier, verifier_version, revoked_at)
    ON identity.credentials
    TO singularity_auth_definer
    """)

    execute("""
    GRANT SELECT (id, principal_id, vault_id, token_digest, expires_at, revoked_at)
    ON identity.sessions
    TO singularity_auth_definer
    """)

    execute("""
    GRANT SELECT (
      dummy_verifier,
      login_window_seconds,
      login_max_attempts,
      source_window_seconds,
      source_max_attempts
    )
    ON identity.security_settings
    TO singularity_auth_definer
    """)

    execute("""
    GRANT SELECT (login_fingerprint, source_fingerprint, result, attempted_at),
      INSERT (id, login_fingerprint, source_fingerprint, result, correlation_id)
    ON identity.auth_attempts
    TO singularity_auth_definer
    """)

    execute("""
    GRANT INSERT (
      id,
      vault_id,
      actor_kind,
      principal_id,
      anonymous_fingerprint,
      operation,
      result,
      classification,
      correlation_id,
      occurred_at
    )
    ON audit.events
    TO singularity_auth_definer
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_auth_definer")

    execute("""
    CREATE OR REPLACE FUNCTION identity.authentication_candidate(
      requested_login text
    ) RETURNS TABLE (
      credential_id uuid,
      account_id uuid,
      verifier text,
      verifier_version integer
    )
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, identity, core, audit
    AS $function$
      WITH candidate AS (
        SELECT
          credential.id AS credential_id,
          credential.account_id,
          credential.verifier,
          credential.verifier_version
        FROM identity.credentials AS credential
        JOIN identity.accounts AS account
          ON account.id = credential.account_id
        WHERE credential.normalized_login =
          lower(btrim(COALESCE(requested_login, '')))
          AND credential.revoked_at IS NULL
          AND account.status = 'active'
        LIMIT 1
      )
      SELECT
        candidate.credential_id,
        candidate.account_id,
        candidate.verifier,
        candidate.verifier_version
      FROM candidate
      UNION ALL
      SELECT
        NULL::uuid,
        NULL::uuid,
        setting.dummy_verifier,
        1
      FROM identity.security_settings AS setting
      WHERE NOT EXISTS (SELECT 1 FROM candidate)
      LIMIT 1
    $function$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION identity.resolve_session(
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
    """)

    execute("""
    CREATE OR REPLACE FUNCTION identity.record_auth_attempt(
      requested_login_fingerprint bytea,
      requested_source_fingerprint bytea,
      requested_result text
    ) RETURNS TABLE (
      attempt_id uuid,
      accepted boolean
    )
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, identity, core, audit
    AS $function$
    DECLARE
      generated_attempt_id uuid := gen_random_uuid();
      generated_correlation_id uuid := gen_random_uuid();
      is_accepted boolean := false;
      login_window integer;
      login_limit integer;
      source_window integer;
      source_limit integer;
      login_count bigint;
      source_count bigint;
    BEGIN
      IF requested_login_fingerprint IS NULL
        OR requested_source_fingerprint IS NULL
        OR octet_length(requested_login_fingerprint) <> 32
        OR octet_length(requested_source_fingerprint) <> 32
      THEN
        RAISE EXCEPTION 'authentication fingerprints must be 32 bytes'
          USING ERRCODE = '22023';
      END IF;

      IF requested_result IS NULL
        OR requested_result NOT IN ('started', 'failed', 'succeeded')
      THEN
        RAISE EXCEPTION 'invalid authentication attempt result'
          USING ERRCODE = '22023';
      END IF;

      PERFORM pg_advisory_xact_lock(
        hashtextextended(
          'singularity:auth:login:' ||
            encode(requested_login_fingerprint, 'hex'),
          0
        )
      );

      PERFORM pg_advisory_xact_lock(
        hashtextextended(
          'singularity:auth:source:' ||
            encode(requested_source_fingerprint, 'hex'),
          0
        )
      );

      SELECT
        setting.login_window_seconds,
        setting.login_max_attempts,
        setting.source_window_seconds,
        setting.source_max_attempts
      INTO login_window, login_limit, source_window, source_limit
      FROM identity.security_settings AS setting
      LIMIT 1;

      IF requested_result = 'started' THEN
        SELECT count(*)
        INTO login_count
        FROM identity.auth_attempts AS attempt
        WHERE attempt.login_fingerprint = requested_login_fingerprint
          AND attempt.result = 'started'
          AND attempt.attempted_at >
            CURRENT_TIMESTAMP - make_interval(secs => login_window);

        SELECT count(*)
        INTO source_count
        FROM identity.auth_attempts AS attempt
        WHERE attempt.source_fingerprint = requested_source_fingerprint
          AND attempt.result = 'started'
          AND attempt.attempted_at >
            CURRENT_TIMESTAMP - make_interval(secs => source_window);

        is_accepted := login_count < login_limit AND source_count < source_limit;
      END IF;

      INSERT INTO identity.auth_attempts (
        id,
        login_fingerprint,
        source_fingerprint,
        result,
        correlation_id
      )
      VALUES (
        generated_attempt_id,
        requested_login_fingerprint,
        requested_source_fingerprint,
        requested_result,
        generated_correlation_id
      );

      INSERT INTO audit.events (
        id,
        vault_id,
        actor_kind,
        principal_id,
        anonymous_fingerprint,
        operation,
        result,
        classification,
        correlation_id,
        occurred_at
      )
      VALUES (
        gen_random_uuid(),
        NULL,
        'anonymous',
        NULL,
        requested_login_fingerprint,
        'identity.authentication_attempt',
        CASE WHEN is_accepted THEN 'allowed' ELSE 'denied' END,
        'private',
        generated_correlation_id,
        CURRENT_TIMESTAMP
      );

      RETURN QUERY SELECT generated_attempt_id, is_accepted;
    END
    $function$
    """)

    execute("REVOKE ALL ON FUNCTION identity.authentication_candidate(text) FROM PUBLIC")

    execute("REVOKE ALL ON FUNCTION identity.resolve_session(bytea) FROM PUBLIC")

    execute("REVOKE ALL ON FUNCTION identity.record_auth_attempt(bytea, bytea, text) FROM PUBLIC")

    execute("""
    GRANT EXECUTE ON FUNCTION identity.authentication_candidate(text)
    TO singularity_pre_auth
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION identity.resolve_session(bytea)
    TO singularity_pre_auth
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION identity.record_auth_attempt(bytea, bytea, text)
    TO singularity_pre_auth
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")
    execute("REVOKE CREATE ON SCHEMA identity FROM singularity_auth_definer")
    execute("GRANT USAGE ON SCHEMA identity TO singularity_pre_auth")
  end

  defp create_outbox_functions do
    execute("""
    CREATE POLICY outbox_definer_claims_events
    ON core.outbox_events
    FOR SELECT
    TO singularity_outbox_definer
    USING (true)
    """)

    execute("""
    CREATE POLICY outbox_definer_updates_events
    ON core.outbox_events
    FOR UPDATE
    TO singularity_outbox_definer
    USING (true)
    WITH CHECK (true)
    """)

    execute("""
    CREATE POLICY outbox_definer_writes_audit
    ON audit.events
    FOR INSERT
    TO singularity_outbox_definer
    WITH CHECK (
      actor_kind = 'system'
      AND principal_id IS NOT NULL
      AND vault_id IS NOT NULL
      AND anonymous_fingerprint IS NULL
    )
    """)

    execute("GRANT USAGE, CREATE ON SCHEMA core TO singularity_outbox_definer")
    execute("GRANT USAGE ON SCHEMA audit TO singularity_outbox_definer")

    execute("""
    GRANT SELECT (
      id,
      sequence,
      event_type,
      idempotency_key,
      vault_id,
      principal_id,
      required_capability,
      authorization_epoch,
      classification,
      correlation_id,
      causation_id,
      expected_entity_revision,
      envelope_version,
      payload,
      occurred_at,
      claim_token,
      claimed_until,
      runner_job_id,
      delivered_at
    ),
    UPDATE (claim_token, claimed_until, runner_job_id, delivered_at, updated_at)
    ON core.outbox_events
    TO singularity_outbox_definer
    """)

    execute("""
    GRANT INSERT (
      id,
      vault_id,
      actor_kind,
      principal_id,
      anonymous_fingerprint,
      operation,
      result,
      classification,
      correlation_id,
      target_type,
      target_id,
      occurred_at
    )
    ON audit.events
    TO singularity_outbox_definer
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_outbox_definer")

    execute("""
    CREATE OR REPLACE FUNCTION core.claim_outbox_events(
      requested_limit integer,
      requested_lease_seconds integer,
      requested_claim_token uuid
    ) RETURNS TABLE (
      outbox_event_id uuid,
      event_type text,
      idempotency_key text,
      vault_id uuid,
      principal_id uuid,
      required_capability text,
      authorization_epoch bigint,
      classification text,
      correlation_id uuid,
      causation_id uuid,
      expected_entity_revision bigint,
      envelope_version integer,
      payload jsonb,
      occurred_at timestamptz,
      claim_token uuid
    )
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, identity, core, audit
    AS $function$
    BEGIN
      IF requested_limit IS NULL OR requested_limit < 1 OR requested_limit > 100
        OR requested_lease_seconds IS NULL
        OR requested_lease_seconds < 1
        OR requested_lease_seconds > 3600
        OR requested_claim_token IS NULL
      THEN
        RAISE EXCEPTION 'invalid outbox claim parameters'
          USING ERRCODE = '22023';
      END IF;

      RETURN QUERY
      WITH candidates AS (
        SELECT event.id
        FROM core.outbox_events AS event
        WHERE event.delivered_at IS NULL
          AND (
            event.claimed_until IS NULL
            OR event.claimed_until < CURRENT_TIMESTAMP
          )
        ORDER BY event.sequence
        FOR UPDATE SKIP LOCKED
        LIMIT requested_limit
      ),
      claimed AS (
        UPDATE core.outbox_events AS event
        SET
          claim_token = requested_claim_token,
          claimed_until =
            CURRENT_TIMESTAMP + make_interval(secs => requested_lease_seconds),
          updated_at = CURRENT_TIMESTAMP
        FROM candidates
        WHERE event.id = candidates.id
        RETURNING
          event.id,
          event.event_type,
          event.idempotency_key,
          event.vault_id,
          event.principal_id,
          event.required_capability,
          event.authorization_epoch,
          event.classification,
          event.correlation_id,
          event.causation_id,
          event.expected_entity_revision,
          event.envelope_version,
          event.payload,
          event.occurred_at,
          event.claim_token
      ),
      audited AS (
        INSERT INTO audit.events (
          id,
          vault_id,
          actor_kind,
          principal_id,
          anonymous_fingerprint,
          operation,
          result,
          classification,
          correlation_id,
          target_type,
          target_id,
          occurred_at
        )
        SELECT
          gen_random_uuid(),
          claimed.vault_id,
          'system',
          claimed.principal_id,
          NULL,
          'outbox.claim',
          'completed',
          claimed.classification,
          claimed.correlation_id,
          'outbox_event',
          claimed.id,
          CURRENT_TIMESTAMP
        FROM claimed
        RETURNING 1
      )
      SELECT
        claimed.id,
        claimed.event_type,
        claimed.idempotency_key,
        claimed.vault_id,
        claimed.principal_id,
        claimed.required_capability,
        claimed.authorization_epoch,
        claimed.classification,
        claimed.correlation_id,
        claimed.causation_id,
        claimed.expected_entity_revision,
        claimed.envelope_version,
        claimed.payload,
        claimed.occurred_at,
        claimed.claim_token
      FROM claimed
      WHERE (SELECT count(*) FROM audited) >= 0;
    END
    $function$
    """)

    execute("""
    CREATE OR REPLACE FUNCTION core.acknowledge_outbox_event(
      requested_event_id uuid,
      requested_claim_token uuid,
      submitted_runner_job_id text
    ) RETURNS boolean
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, identity, core, audit
    AS $function$
    DECLARE
      was_acknowledged boolean;
    BEGIN
      IF requested_event_id IS NULL
        OR requested_claim_token IS NULL
        OR NULLIF(btrim(submitted_runner_job_id), '') IS NULL
      THEN
        RAISE EXCEPTION 'invalid outbox acknowledgement parameters'
          USING ERRCODE = '22023';
      END IF;

      WITH acknowledged AS (
        UPDATE core.outbox_events AS event
        SET
          runner_job_id = submitted_runner_job_id,
          delivered_at = CURRENT_TIMESTAMP,
          claim_token = NULL,
          claimed_until = NULL,
          updated_at = CURRENT_TIMESTAMP
        WHERE event.id = requested_event_id
          AND event.claim_token = requested_claim_token
          AND event.delivered_at IS NULL
        RETURNING
          event.id,
          event.vault_id,
          event.principal_id,
          event.classification,
          event.correlation_id
      ),
      audited AS (
        INSERT INTO audit.events (
          id,
          vault_id,
          actor_kind,
          principal_id,
          anonymous_fingerprint,
          operation,
          result,
          classification,
          correlation_id,
          target_type,
          target_id,
          occurred_at
        )
        SELECT
          gen_random_uuid(),
          acknowledged.vault_id,
          'system',
          acknowledged.principal_id,
          NULL,
          'outbox.acknowledge',
          'completed',
          acknowledged.classification,
          acknowledged.correlation_id,
          'outbox_event',
          acknowledged.id,
          CURRENT_TIMESTAMP
        FROM acknowledged
        RETURNING 1
      )
      SELECT EXISTS(SELECT 1 FROM audited)
      INTO was_acknowledged;

      RETURN was_acknowledged;
    END
    $function$
    """)

    execute("""
    REVOKE ALL ON FUNCTION core.claim_outbox_events(integer, integer, uuid)
    FROM PUBLIC
    """)

    execute("""
    REVOKE ALL ON FUNCTION core.acknowledge_outbox_event(uuid, uuid, text)
    FROM PUBLIC
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION core.claim_outbox_events(integer, integer, uuid)
    TO singularity_dispatcher
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION core.acknowledge_outbox_event(uuid, uuid, text)
    TO singularity_dispatcher
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")
    execute("REVOKE CREATE ON SCHEMA core FROM singularity_outbox_definer")
    execute("GRANT USAGE ON SCHEMA core TO singularity_dispatcher")
  end

  defp grant_oban_access do
    execute("GRANT USAGE ON SCHEMA jobs TO singularity_worker")

    execute("""
    GRANT SELECT, INSERT, UPDATE, DELETE
    ON jobs.oban_jobs, jobs.oban_peers
    TO singularity_worker
    """)

    execute("""
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA jobs
    TO singularity_worker
    """)
  end

  defp create_select_insert_policies(table, policy_prefix, vault_column) do
    execute("""
    CREATE POLICY #{policy_prefix}_vault_select
    ON #{table}
    FOR SELECT
    TO singularity_web, singularity_worker
    USING (#{vault_predicate(vault_column)})
    """)

    execute("""
    CREATE POLICY #{policy_prefix}_vault_insert
    ON #{table}
    FOR INSERT
    TO singularity_web, singularity_worker
    WITH CHECK (#{vault_predicate(vault_column)})
    """)

    execute("""
    GRANT SELECT, INSERT
    ON #{table}
    TO singularity_web, singularity_worker
    """)
  end

  defp vault_predicate(vault_column) do
    """
    NULLIF(current_setting('singularity.principal_id', true), '') IS NOT NULL
    AND NULLIF(current_setting('singularity.vault_id', true), '') IS NOT NULL
    AND #{vault_column} =
      NULLIF(current_setting('singularity.vault_id', true), '')::uuid
    AND core.principal_is_authorized(
      NULLIF(current_setting('singularity.principal_id', true), '')::uuid,
      #{vault_column}
    )
    """
  end
end
