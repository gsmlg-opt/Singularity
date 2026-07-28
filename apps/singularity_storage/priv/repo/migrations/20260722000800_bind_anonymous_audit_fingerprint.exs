defmodule Singularity.Storage.Migrations.BindAnonymousAuditFingerprint do
  use Ecto.Migration

  def up, do: replace_auth_attempt_recorder(:combined_final_outcome)
  def down, do: replace_auth_attempt_recorder(:legacy_each_transition)

  defp replace_auth_attempt_recorder(mode) do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    GRANT USAGE, CREATE ON SCHEMA identity
    TO singularity_auth_definer
    """)

    if mode == :combined_final_outcome do
      execute("""
      GRANT INSERT (target_type, target_id)
      ON audit.events
      TO singularity_auth_definer
      """)
    end

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_auth_definer")
    execute(auth_attempt_recorder_sql(mode))

    execute("""
    REVOKE ALL ON FUNCTION identity.record_auth_attempt(
      bytea,
      bytea,
      text,
      uuid,
      uuid
    )
    FROM PUBLIC
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION identity.record_auth_attempt(
      bytea,
      bytea,
      text,
      uuid,
      uuid
    )
    TO singularity_pre_auth
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")

    if mode == :legacy_each_transition do
      execute("""
      REVOKE INSERT (target_type, target_id)
      ON audit.events
      FROM singularity_auth_definer
      """)
    end

    execute("""
    REVOKE CREATE ON SCHEMA identity
    FROM singularity_auth_definer
    """)

    execute("SET LOCAL ROLE NONE")
  end

  defp auth_attempt_recorder_sql(mode) do
    """
    CREATE OR REPLACE FUNCTION identity.record_auth_attempt(
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

      #{audit_insert(mode)}

      RETURN QUERY SELECT selected_attempt_id, is_accepted;
    END
    $function$
    """
  end

  defp audit_insert(:combined_final_outcome) do
    """
    IF (requested_result = 'started' AND NOT is_accepted)
      OR requested_result = 'failed'
    THEN
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
      VALUES (
        gen_random_uuid(),
        NULL,
        'anonymous',
        NULL,
        sha256(requested_login_fingerprint || requested_source_fingerprint),
        'identity.authentication_attempt',
        'denied',
        'private',
        requested_correlation_id,
        'authentication_attempt',
        selected_attempt_id,
        CURRENT_TIMESTAMP
      );
    END IF;
    """
  end

  defp audit_insert(:legacy_each_transition) do
    """
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
    """
  end
end
