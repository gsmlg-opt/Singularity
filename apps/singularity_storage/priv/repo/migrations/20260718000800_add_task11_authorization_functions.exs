defmodule Singularity.Storage.Migrations.AddTask11AuthorizationFunctions do
  use Ecto.Migration

  @legacy_dummy_verifier "$argon2id$v=19$m=65536,t=3,p=1$c2luZ3VsYXJpdHlkdW1teQ$c2luZ3VsYXJpdHlkdW1teXZlcmlmaWVy"
  @task11_dummy_verifier "$argon2id$v=19$m=65536,t=3,p=1$c2luZ3VsYXJpdHlkdW1teQ$5X38g/2eiHv9wnPQes+dkvbHR0wcGqDoPXStyiEIaHo"

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    add_session_credential_binding()
    add_vault_wrapper_generation()
    drop_outbox_claim_function()
    add_outbox_authorization_epochs()
    create_outbox_claim_function(:task11)
    replace_dummy_verifier(@task11_dummy_verifier)
    create_pre_auth_epoch_policies()
    create_auth_attempt_completion_policy()
    grant_pre_auth_epoch_columns()
    grant_auth_attempt_completion_columns()
    replace_session_resolver(:task11)
    replace_auth_attempt_recorder(:task11)
    create_auth_attempt_completion()
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
          "identity.update_scoped_credential_verifier(uuid, uuid, timestamptz, text)"
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
    execute("SET LOCAL ROLE singularity_table_owner")

    ensure_vault_wrapper_generation_downgrade_safe()
    drop_outbox_claim_function()
    remove_outbox_authorization_epochs()
    create_outbox_claim_function(:legacy)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_auth_definer")

    execute("""
    DROP FUNCTION IF EXISTS identity.complete_authentication_attempt(
      uuid,
      bytea,
      bytea,
      uuid
    )
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_authorization_definer")

    execute("""
    DROP FUNCTION IF EXISTS identity.update_scoped_credential_verifier(
      uuid,
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
    replace_auth_attempt_recorder(:legacy)

    execute("""
    REVOKE SELECT (id, correlation_id), UPDATE (result)
    ON identity.auth_attempts
    FROM singularity_auth_definer
    """)

    execute("""
    DROP POLICY IF EXISTS task11_auth_definer_completes_attempt
    ON identity.auth_attempts
    """)

    execute("""
    REVOKE SELECT (id, account_id, authorization_epoch, revoked_at)
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
    REVOKE SELECT (id, status)
    ON identity.accounts
    FROM singularity_authorization_definer
    """)

    execute("""
    REVOKE SELECT (
      id,
      principal_id,
      vault_id,
      account_id,
      credential_id,
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
          {"identity.accounts", "task11_authorization_reads_accounts"},
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

    execute("""
    REVOKE SELECT (account_id, credential_id)
    ON identity.sessions
    FROM singularity_auth_definer
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")
    remove_session_credential_binding()
    remove_vault_wrapper_generation()

    execute("SET LOCAL ROLE NONE")
  end

  defp add_session_credential_binding do
    execute("""
    ALTER TABLE identity.sessions
    ADD COLUMN credential_id uuid
      REFERENCES identity.credentials(id)
    """)

    execute("""
    GRANT SELECT (account_id, credential_id)
    ON identity.sessions
    TO singularity_auth_definer
    """)
  end

  defp remove_session_credential_binding do
    execute("""
    ALTER TABLE identity.sessions
    DROP COLUMN credential_id
    """)
  end

  defp add_vault_wrapper_generation do
    execute("""
    ALTER TABLE core.vault_key_wrappers
    ADD COLUMN generation integer
    """)

    execute("""
    UPDATE core.vault_key_wrappers AS wrapper
    SET generation = version.generation
    FROM core.vault_key_versions AS version
    WHERE version.id = wrapper.vault_key_version_id
      AND version.vault_id = wrapper.vault_id
    """)

    execute("""
    ALTER TABLE core.vault_key_wrappers
    ALTER COLUMN generation SET NOT NULL
    """)

    execute("""
    ALTER TABLE core.vault_key_wrappers
    ADD CONSTRAINT vault_key_wrappers_generation_check
    CHECK (generation > 0)
    """)
  end

  defp remove_vault_wrapper_generation do
    execute("""
    ALTER TABLE core.vault_key_wrappers
    DROP CONSTRAINT vault_key_wrappers_generation_check
    """)

    execute("""
    ALTER TABLE core.vault_key_wrappers
    DROP COLUMN generation
    """)
  end

  defp ensure_vault_wrapper_generation_downgrade_safe do
    execute("""
    DO $block$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM core.vault_key_wrappers AS wrapper
        JOIN core.vault_key_versions AS version
          ON version.id = wrapper.vault_key_version_id
         AND version.vault_id = wrapper.vault_id
        WHERE wrapper.generation <> version.generation
      ) THEN
        RAISE EXCEPTION
          'cannot downgrade Task 11: rotated vault wrapper generation would be lost';
      END IF;
    END
    $block$
    """)
  end

  defp add_outbox_authorization_epochs do
    execute("""
    ALTER TABLE core.outbox_events
    RENAME COLUMN authorization_epoch TO vault_authorization_epoch
    """)

    execute("""
    ALTER TABLE core.outbox_events
    RENAME CONSTRAINT outbox_events_authorization_epoch_check
    TO outbox_events_vault_authorization_epoch_check
    """)

    execute("""
    ALTER TABLE core.outbox_events
    ADD COLUMN principal_authorization_epoch bigint
    """)

    execute("""
    -- Preserve the queue lifecycle while giving legacy rows the best available
    -- principal checkpoint. Authorization is revalidated again at claim/use time.
    UPDATE core.outbox_events AS event
    SET
      principal_authorization_epoch = principal.authorization_epoch,
      updated_at = CURRENT_TIMESTAMP
    FROM identity.principals AS principal
    WHERE principal.id = event.principal_id
    """)

    execute("""
    ALTER TABLE core.outbox_events
    ALTER COLUMN principal_authorization_epoch SET NOT NULL
    """)

    execute("""
    ALTER TABLE core.outbox_events
    ADD CONSTRAINT outbox_events_principal_authorization_epoch_check
    CHECK (principal_authorization_epoch >= 0)
    """)

    execute("""
    GRANT SELECT (principal_authorization_epoch)
    ON core.outbox_events
    TO singularity_outbox_definer
    """)
  end

  defp remove_outbox_authorization_epochs do
    execute("""
    REVOKE SELECT (principal_authorization_epoch)
    ON core.outbox_events
    FROM singularity_outbox_definer
    """)

    execute("""
    ALTER TABLE core.outbox_events
    DROP CONSTRAINT outbox_events_principal_authorization_epoch_check
    """)

    execute("""
    ALTER TABLE core.outbox_events
    DROP COLUMN principal_authorization_epoch
    """)

    execute("""
    ALTER TABLE core.outbox_events
    RENAME CONSTRAINT outbox_events_vault_authorization_epoch_check
    TO outbox_events_authorization_epoch_check
    """)

    execute("""
    ALTER TABLE core.outbox_events
    RENAME COLUMN vault_authorization_epoch TO authorization_epoch
    """)
  end

  defp drop_outbox_claim_function do
    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_outbox_definer")

    execute("""
    DROP FUNCTION IF EXISTS core.claim_outbox_events(integer, integer, uuid)
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")
  end

  defp create_outbox_claim_function(version) do
    execute("GRANT USAGE, CREATE ON SCHEMA core TO singularity_outbox_definer")
    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_outbox_definer")
    execute(outbox_claim_function_sql(version))

    execute("""
    REVOKE ALL ON FUNCTION core.claim_outbox_events(integer, integer, uuid)
    FROM PUBLIC
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION core.claim_outbox_events(integer, integer, uuid)
    TO singularity_dispatcher
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")
    execute("REVOKE CREATE ON SCHEMA core FROM singularity_outbox_definer")
  end

  defp outbox_claim_function_sql(version) do
    {returned_epochs, claimed_epochs, selected_epochs} =
      case version do
        :task11 ->
          {
            """
                  principal_authorization_epoch bigint,
                  vault_authorization_epoch bigint,
            """,
            """
                      event.principal_authorization_epoch,
                      event.vault_authorization_epoch,
            """,
            """
                    claimed.principal_authorization_epoch,
                    claimed.vault_authorization_epoch,
            """
          }

        :legacy ->
          {
            "      authorization_epoch bigint,\n",
            "          event.authorization_epoch,\n",
            "        claimed.authorization_epoch,\n"
          }
      end

    """
    CREATE FUNCTION core.claim_outbox_events(
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
    #{returned_epochs}  classification text,
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
    #{claimed_epochs}      event.classification,
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
    #{selected_epochs}    claimed.classification,
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
    """
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
    GRANT SELECT (id, account_id, authorization_epoch, revoked_at)
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

  defp create_auth_attempt_completion_policy do
    execute("""
    CREATE POLICY task11_auth_definer_completes_attempt
    ON identity.auth_attempts
    FOR UPDATE
    TO singularity_auth_definer
    USING (true)
    WITH CHECK (true)
    """)
  end

  defp grant_auth_attempt_completion_columns do
    execute("""
    GRANT SELECT (id, correlation_id), UPDATE (result)
    ON identity.auth_attempts
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

  defp replace_auth_attempt_recorder(version) do
    execute("""
    GRANT USAGE, CREATE ON SCHEMA identity
    TO singularity_auth_definer
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_auth_definer")

    execute("""
    DROP FUNCTION IF EXISTS identity.record_auth_attempt(
      bytea,
      bytea,
      text
    )
    """)

    execute("""
    DROP FUNCTION IF EXISTS identity.record_auth_attempt(
      bytea,
      bytea,
      text,
      uuid,
      uuid
    )
    """)

    execute(auth_attempt_recorder_sql(version))

    signature =
      case version do
        :task11 -> "bytea, bytea, text, uuid, uuid"
        :legacy -> "bytea, bytea, text"
      end

    execute("""
    REVOKE ALL ON FUNCTION identity.record_auth_attempt(#{signature})
    FROM PUBLIC
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION identity.record_auth_attempt(#{signature})
    TO singularity_pre_auth
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    REVOKE CREATE ON SCHEMA identity
    FROM singularity_auth_definer
    """)
  end

  defp create_auth_attempt_completion do
    execute("""
    GRANT USAGE, CREATE ON SCHEMA identity
    TO singularity_auth_definer
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_auth_definer")

    execute("""
    CREATE FUNCTION identity.complete_authentication_attempt(
      requested_attempt_id uuid,
      requested_login_fingerprint bytea,
      requested_source_fingerprint bytea,
      requested_correlation_id uuid
    ) RETURNS boolean
    LANGUAGE sql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, identity
    AS $function$
      WITH updated AS (
        UPDATE identity.auth_attempts AS attempt
        SET result = 'succeeded'
        WHERE requested_attempt_id IS NOT NULL
          AND octet_length(requested_login_fingerprint) = 32
          AND octet_length(requested_source_fingerprint) = 32
          AND requested_correlation_id IS NOT NULL
          AND attempt.id = requested_attempt_id
          AND attempt.login_fingerprint = requested_login_fingerprint
          AND attempt.source_fingerprint = requested_source_fingerprint
          AND attempt.correlation_id = requested_correlation_id
          AND attempt.result = 'started'
        RETURNING attempt.id
      )
      SELECT EXISTS(SELECT 1 FROM updated)
    $function$
    """)

    execute("""
    REVOKE ALL ON FUNCTION identity.complete_authentication_attempt(
      uuid,
      bytea,
      bytea,
      uuid
    )
    FROM PUBLIC
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION identity.complete_authentication_attempt(
      uuid,
      bytea,
      bytea,
      uuid
    )
    TO singularity_web
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    REVOKE CREATE ON SCHEMA identity
    FROM singularity_auth_definer
    """)
  end

  defp auth_attempt_recorder_sql(:task11) do
    """
    CREATE FUNCTION identity.record_auth_attempt(
      requested_login_fingerprint bytea,
      requested_source_fingerprint bytea,
      requested_result text,
      requested_correlation_id uuid,
      requested_attempt_id uuid
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
      selected_attempt_id uuid;
      is_accepted boolean := false;
      login_window integer;
      login_limit integer;
      source_window integer;
      source_limit integer;
      login_count bigint;
      source_count bigint;
      updated_count bigint;
      audit_result text;
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

      IF requested_correlation_id IS NULL THEN
        RAISE EXCEPTION 'authentication correlation id is required'
          USING ERRCODE = '22023';
      END IF;

      IF requested_result = 'started' AND requested_attempt_id IS NOT NULL THEN
        RAISE EXCEPTION 'started authentication attempts cannot supply an attempt id'
          USING ERRCODE = '22023';
      END IF;

      IF requested_result <> 'started' AND requested_attempt_id IS NULL THEN
        RAISE EXCEPTION 'completed authentication attempts require an attempt id'
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

      IF requested_result = 'started' THEN
        SELECT
          setting.login_window_seconds,
          setting.login_max_attempts,
          setting.source_window_seconds,
          setting.source_max_attempts
        INTO login_window, login_limit, source_window, source_limit
        FROM identity.security_settings AS setting
        LIMIT 1;

        SELECT count(*)
        INTO login_count
        FROM identity.auth_attempts AS attempt
        WHERE attempt.login_fingerprint = requested_login_fingerprint
          AND attempt.attempted_at >
            CURRENT_TIMESTAMP - make_interval(secs => login_window);

        SELECT count(*)
        INTO source_count
        FROM identity.auth_attempts AS attempt
        WHERE attempt.source_fingerprint = requested_source_fingerprint
          AND attempt.attempted_at >
            CURRENT_TIMESTAMP - make_interval(secs => source_window);

        is_accepted := login_count < login_limit AND source_count < source_limit;
        selected_attempt_id := gen_random_uuid();

        INSERT INTO identity.auth_attempts (
          id,
          login_fingerprint,
          source_fingerprint,
          result,
          correlation_id
        )
        VALUES (
          selected_attempt_id,
          requested_login_fingerprint,
          requested_source_fingerprint,
          requested_result,
          requested_correlation_id
        );
      ELSE
        selected_attempt_id := requested_attempt_id;

        UPDATE identity.auth_attempts AS attempt
        SET result = requested_result
        WHERE attempt.id = requested_attempt_id
          AND attempt.login_fingerprint = requested_login_fingerprint
          AND attempt.source_fingerprint = requested_source_fingerprint
          AND attempt.correlation_id = requested_correlation_id
          AND attempt.result = 'started';

        GET DIAGNOSTICS updated_count = ROW_COUNT;

        IF updated_count <> 1 THEN
          RAISE EXCEPTION 'authentication attempt binding is invalid'
            USING ERRCODE = '22023';
        END IF;
      END IF;

      audit_result :=
        CASE
          WHEN requested_result = 'started' AND is_accepted THEN 'allowed'
          WHEN requested_result = 'succeeded' THEN 'allowed'
          ELSE 'denied'
        END;

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
        audit_result,
        'private',
        requested_correlation_id,
        CURRENT_TIMESTAMP
      );

      RETURN QUERY SELECT selected_attempt_id, is_accepted;
    END
    $function$
    """
  end

  defp auth_attempt_recorder_sql(:legacy) do
    """
    CREATE FUNCTION identity.record_auth_attempt(
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
    """
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
      JOIN identity.accounts AS account
        ON account.id = session.account_id
       AND account.status = 'active'
      JOIN identity.credentials AS credential
        ON credential.id = session.credential_id
       AND credential.account_id = account.id
       AND credential.revoked_at IS NULL
      JOIN identity.principals AS principal
        ON principal.id = session.principal_id
       AND principal.account_id = account.id
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
          {"identity.accounts", "task11_authorization_reads_accounts"},
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
    GRANT SELECT (id, status)
    ON identity.accounts
    TO singularity_authorization_definer
    """)

    execute("""
    GRANT SELECT (
      id,
      principal_id,
      vault_id,
      account_id,
      credential_id,
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
      JOIN identity.accounts AS account
        ON account.id = session.account_id
       AND account.status = 'active'
      JOIN identity.principals AS principal
        ON principal.id = session.principal_id
       AND principal.account_id = account.id
      JOIN identity.credentials AS credential
        ON credential.id = session.credential_id
       AND credential.account_id = account.id
       AND credential.revoked_at IS NULL
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
      JOIN identity.accounts AS account
        ON account.id = principal.account_id
       AND account.status = 'active'
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
      requested_session uuid,
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
        FROM
          scoped,
          identity.sessions AS session,
          identity.principals AS principal
        WHERE requested_session IS NOT NULL
          AND requested_credential IS NOT NULL
          AND expected_revision IS NOT NULL
          AND replacement_verifier IS NOT NULL
          AND btrim(replacement_verifier) <> ''
          AND session.id = requested_session
          AND session.principal_id = scoped.principal_id
          AND session.vault_id = scoped.vault_id
          AND session.credential_id = requested_credential
          AND session.revoked_at IS NULL
          AND session.expires_at > CURRENT_TIMESTAMP
          AND principal.id = session.principal_id
          AND principal.account_id = session.account_id
          AND principal.revoked_at IS NULL
          AND EXISTS (
            SELECT 1
            FROM identity.accounts AS account
            WHERE account.id = session.account_id
              AND account.status = 'active'
          )
          AND credential.id = requested_credential
          AND credential.account_id = session.account_id
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
