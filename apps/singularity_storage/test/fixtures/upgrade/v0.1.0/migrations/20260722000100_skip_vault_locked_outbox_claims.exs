defmodule Singularity.Storage.Migrations.SkipVaultLockedOutboxClaims do
  use Ecto.Migration

  def up do
    replace_claim_function(:skip_vault_locks)
  end

  def down do
    replace_claim_function(:legacy_claims)
  end

  defp replace_claim_function(version) do
    execute("SET LOCAL ROLE singularity_table_owner")
    execute("GRANT USAGE, CREATE ON SCHEMA core TO singularity_outbox_definer")
    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_outbox_definer")
    execute(claim_function_sql(version))
    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")
    execute("REVOKE CREATE ON SCHEMA core FROM singularity_outbox_definer")
    execute("SET LOCAL ROLE NONE")
  end

  defp claim_function_sql(version) do
    vault_lock_filter =
      case version do
        :skip_vault_locks ->
          """
          AND pg_try_advisory_xact_lock_shared(
            hashtextextended('singularity:vault:' || event.vault_id::text, 0)
          )
          """

        :legacy_claims ->
          ""
      end

    """
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
      principal_authorization_epoch bigint,
      vault_authorization_epoch bigint,
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
          AND event.retired_at IS NULL
    #{vault_lock_filter}      AND (
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
          event.principal_authorization_epoch,
          event.vault_authorization_epoch,
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
        claimed.principal_authorization_epoch,
        claimed.vault_authorization_epoch,
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
    """
  end
end
