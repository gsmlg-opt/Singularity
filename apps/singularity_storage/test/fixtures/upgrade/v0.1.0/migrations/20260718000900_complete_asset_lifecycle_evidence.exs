defmodule Singularity.Storage.Migrations.CompleteAssetLifecycleEvidence do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DO $guard$
    BEGIN
      IF EXISTS (SELECT 1 FROM content.upload_grants)
         OR EXISTS (SELECT 1 FROM content.asset_stages)
         OR EXISTS (SELECT 1 FROM content.asset_objects) THEN
        RAISE EXCEPTION
          'Task 12 lifecycle migration requires empty pre-release asset tables';
      END IF;
    END
    $guard$
    """)

    execute("""
    ALTER TABLE jobs.effect_receipts
      DROP CONSTRAINT effect_receipts_result_check,
      ADD CONSTRAINT effect_receipts_result_check
        CHECK (result IN ('applied', 'stale', 'failed'))
    """)

    execute("""
    ALTER TABLE content.upload_grants
      RENAME COLUMN authorization_epoch TO principal_authorization_epoch
    """)

    execute("""
    ALTER TABLE content.upload_grants
      DROP CONSTRAINT upload_grants_vault_id_idempotency_key_key
    """)

    execute("""
    CREATE UNIQUE INDEX upload_grants_active_idempotency_key
      ON content.upload_grants(vault_id, idempotency_key)
      WHERE consumed_at IS NULL
    """)

    execute("""
    ALTER TABLE core.vaults
      ADD COLUMN object_cleanup_principal_id uuid,
      ADD CONSTRAINT vaults_object_cleanup_membership_fkey
        FOREIGN KEY (object_cleanup_principal_id, id)
        REFERENCES core.vault_members(principal_id, vault_id)
    """)

    execute("""
    CREATE FUNCTION core.object_cleanup_authorization(requested_vault uuid)
    RETURNS TABLE (
      principal_id uuid,
      principal_authorization_epoch bigint,
      vault_authorization_epoch bigint
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
        cleanup.id,
        cleanup.authorization_epoch,
        vault.authorization_epoch
      FROM scoped
      JOIN core.vaults AS vault
        ON vault.id = requested_vault
       AND vault.id = scoped.vault_id
      JOIN identity.principals AS cleanup
        ON cleanup.id = vault.object_cleanup_principal_id
       AND cleanup.kind = 'system'
       AND cleanup.metadata ->> 'name' = 'object_cleanup'
       AND cleanup.revoked_at IS NULL
      JOIN identity.accounts AS account
        ON account.id = cleanup.account_id
       AND account.status = 'active'
      JOIN core.vault_members AS membership
        ON membership.principal_id = cleanup.id
       AND membership.vault_id = vault.id
       AND membership.revoked_at IS NULL
      JOIN identity.principals AS initiating
        ON initiating.id = scoped.principal_id
       AND initiating.revoked_at IS NULL
      JOIN identity.accounts AS initiating_account
        ON initiating_account.id = initiating.account_id
       AND initiating_account.status = 'active'
      JOIN core.vault_members AS initiating_membership
        ON initiating_membership.principal_id = initiating.id
       AND initiating_membership.vault_id = requested_vault
       AND initiating_membership.revoked_at IS NULL
      WHERE scoped.principal_id IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM core.principal_capabilities AS assignment
          JOIN core.capabilities AS capability
            ON capability.id = assignment.capability_id
          WHERE assignment.principal_id = cleanup.id
            AND assignment.vault_id = vault.id
            AND assignment.revoked_at IS NULL
            AND capability.name = 'object.cleanup'
        )
      LIMIT 1
    $function$
    """)

    execute("""
    REVOKE ALL ON FUNCTION core.object_cleanup_authorization(uuid)
    FROM PUBLIC
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION core.object_cleanup_authorization(uuid)
    TO singularity_worker
    """)

    execute("""
    GRANT CREATE ON SCHEMA core
    TO singularity_authorization_definer
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_authorization_definer")

    execute("""
    CREATE FUNCTION core.current_principal_can_discover_classification(
      requested_classification text
    )
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, core
    AS $function$
      SELECT EXISTS (
        SELECT 1
        FROM core.vault_members AS membership
        WHERE membership.principal_id =
          NULLIF(
            current_setting('singularity.principal_id', true),
            ''
          )::uuid
          AND membership.vault_id =
            NULLIF(
              current_setting('singularity.vault_id', true),
              ''
            )::uuid
          AND membership.revoked_at IS NULL
          AND CASE membership.clearance
            WHEN 'private' THEN 0
            WHEN 'sensitive' THEN 1
            WHEN 'restricted' THEN 2
          END >= CASE requested_classification
            WHEN 'private' THEN 0
            WHEN 'sensitive' THEN 1
            WHEN 'restricted' THEN 2
          END
      )
    $function$
    """)

    execute("""
    REVOKE ALL ON FUNCTION
      core.current_principal_can_discover_classification(text)
    FROM PUBLIC
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION
      core.current_principal_can_discover_classification(text)
    TO singularity_web
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    REVOKE CREATE ON SCHEMA core
    FROM singularity_authorization_definer
    """)

    execute("""
    ALTER TABLE content.upload_grants
      RENAME CONSTRAINT upload_grants_authorization_epoch_check
      TO upload_grants_principal_authorization_epoch_check
    """)

    execute("""
    ALTER TABLE content.upload_grants
      ADD COLUMN vault_authorization_epoch bigint NOT NULL,
      ADD CONSTRAINT upload_grants_id_vault_id_key UNIQUE (id, vault_id),
      ADD CONSTRAINT upload_grants_vault_authorization_epoch_check
        CHECK (vault_authorization_epoch >= 0)
    """)

    execute("""
    ALTER TABLE content.source_references
      ADD CONSTRAINT source_references_id_vault_id_key UNIQUE (id, vault_id)
    """)

    execute("""
    ALTER TABLE content.upload_grants
      ADD COLUMN source_reference_id uuid,
      ADD CONSTRAINT upload_grants_source_reference_vault_fkey
        FOREIGN KEY (source_reference_id, vault_id)
        REFERENCES content.source_references(id, vault_id)
        MATCH SIMPLE
    """)

    execute("""
    ALTER TABLE content.asset_stages
      ADD COLUMN upload_grant_id uuid NOT NULL,
      ADD COLUMN candidate_object_id uuid NOT NULL,
      ADD COLUMN domain_key_version_id uuid NOT NULL,
      ADD COLUMN wrapper_algorithm text NOT NULL,
      ADD COLUMN key_generation integer NOT NULL,
      ADD COLUMN dek_wrapper bytea NOT NULL,
      ADD COLUMN state_revision bigint NOT NULL DEFAULT 0,
      ALTER COLUMN format_version DROP NOT NULL,
      ALTER COLUMN plaintext_byte_size DROP NOT NULL,
      ALTER COLUMN ciphertext_byte_size DROP NOT NULL,
      ALTER COLUMN lookup_digest DROP NOT NULL,
      ALTER COLUMN ciphertext_hash DROP NOT NULL,
      ADD CONSTRAINT asset_stages_domain_version_vault_fkey
        FOREIGN KEY (domain_key_version_id, vault_id, key_domain_id)
        REFERENCES core.domain_key_versions(id, vault_id, key_domain_id)
        MATCH FULL,
      ADD CONSTRAINT asset_stages_upload_grant_vault_fkey
        FOREIGN KEY (upload_grant_id, vault_id)
        REFERENCES content.upload_grants(id, vault_id)
        MATCH FULL,
      ADD CONSTRAINT asset_stages_upload_grant_id_key UNIQUE (upload_grant_id),
      ADD CONSTRAINT asset_stages_candidate_object_vault_key
        UNIQUE (candidate_object_id, vault_id),
      ADD CONSTRAINT asset_stages_wrapper_shape_check
        CHECK (
          btrim(wrapper_algorithm) <> ''
          AND octet_length(dek_wrapper) > 0
        ),
      ADD CONSTRAINT asset_stages_key_generation_check
        CHECK (key_generation > 0),
      ADD CONSTRAINT asset_stages_state_revision_check
        CHECK (state_revision >= 0),
      ADD CONSTRAINT asset_stages_abandonment_shape_check
        CHECK (
          (
            state = 'abandoned'
            AND abandoned_at IS NOT NULL
            AND failure_code IS NOT NULL
            AND btrim(failure_code) <> ''
          )
          OR
          (
            state <> 'abandoned'
            AND abandoned_at IS NULL
            AND failure_code IS NULL
          )
        ),
      ADD CONSTRAINT asset_stages_crypto_state_check
        CHECK (
          (
            state = 'open'
            AND sealed_at IS NULL
            AND format_version IS NULL
            AND plaintext_byte_size IS NULL
            AND ciphertext_byte_size IS NULL
            AND lookup_digest IS NULL
            AND ciphertext_hash IS NULL
          )
          OR
          (
            state IN ('sealed', 'finalized')
            AND sealed_at IS NOT NULL
            AND format_version IS NOT NULL
            AND plaintext_byte_size IS NOT NULL
            AND ciphertext_byte_size IS NOT NULL
            AND lookup_digest IS NOT NULL
            AND ciphertext_hash IS NOT NULL
          )
          OR
          (
            state = 'abandoned'
            AND (
              (
                sealed_at IS NULL
                AND format_version IS NULL
                AND plaintext_byte_size IS NULL
                AND ciphertext_byte_size IS NULL
                AND lookup_digest IS NULL
                AND ciphertext_hash IS NULL
              )
              OR
              (
                sealed_at IS NOT NULL
                AND format_version IS NOT NULL
                AND plaintext_byte_size IS NOT NULL
                AND ciphertext_byte_size IS NOT NULL
                AND lookup_digest IS NOT NULL
                AND ciphertext_hash IS NOT NULL
              )
            )
          )
        )
    """)

    execute("""
    CREATE FUNCTION content.list_open_upload_stages()
    RETURNS TABLE (
      stage_id uuid,
      storage_ref text
    )
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, content, audit
    AS $function$
      SELECT
        stage.id,
        stage.storage_ref
      FROM content.asset_stages AS stage
      JOIN content.upload_grants AS upload_grant
        ON upload_grant.id = stage.upload_grant_id
       AND upload_grant.vault_id = stage.vault_id
      WHERE stage.state = 'open'
        AND upload_grant.consumed_at IS NOT NULL
      ORDER BY stage.inserted_at, stage.id
    $function$
    """)

    execute("""
    CREATE FUNCTION content.upload_stage_recovery_status(
      requested_stage_id uuid,
      requested_storage_ref text
    )
    RETURNS TABLE (
      stage_id uuid,
      storage_ref text,
      state text,
      state_revision bigint,
      failure_code text
    )
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, content
    AS $function$
    DECLARE
      selected_grant_id uuid;
      selected_asset_id uuid;
      selected_vault_id uuid;
    BEGIN
      IF requested_stage_id IS NULL
         OR requested_storage_ref IS NULL
         OR length(requested_storage_ref) = 0
      THEN
        RAISE EXCEPTION 'upload recovery binding is invalid';
      END IF;

      SELECT
        stage.upload_grant_id,
        stage.asset_id,
        stage.vault_id
      INTO
        selected_grant_id,
        selected_asset_id,
        selected_vault_id
      FROM content.asset_stages AS stage
      WHERE stage.id = requested_stage_id
        AND stage.storage_ref = requested_storage_ref;

      IF NOT FOUND THEN
        RETURN;
      END IF;

      PERFORM 1
      FROM content.upload_grants AS upload_grant
      WHERE upload_grant.id = selected_grant_id
        AND upload_grant.vault_id = selected_vault_id
        AND upload_grant.consumed_at IS NOT NULL
      FOR UPDATE;

      IF NOT FOUND THEN
        RETURN;
      END IF;

      PERFORM 1
      FROM content.asset_stages AS stage
      WHERE stage.id = requested_stage_id
        AND stage.storage_ref = requested_storage_ref
        AND stage.upload_grant_id = selected_grant_id
        AND stage.asset_id = selected_asset_id
        AND stage.vault_id = selected_vault_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RETURN;
      END IF;

      PERFORM 1
      FROM content.assets AS asset
      WHERE asset.id = selected_asset_id
        AND asset.vault_id = selected_vault_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RETURN;
      END IF;

      RETURN QUERY
      SELECT
        stage.id,
        stage.storage_ref,
        stage.state,
        stage.state_revision,
        stage.failure_code
      FROM content.asset_stages AS stage
      JOIN content.upload_grants AS upload_grant
        ON upload_grant.id = stage.upload_grant_id
       AND upload_grant.vault_id = stage.vault_id
      WHERE stage.id = requested_stage_id
        AND stage.storage_ref = requested_storage_ref
        AND upload_grant.consumed_at IS NOT NULL
        AND upload_grant.id = selected_grant_id
        AND stage.asset_id = selected_asset_id
        AND stage.vault_id = selected_vault_id;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION content.reconcile_open_upload_stage(
      requested_stage_id uuid,
      requested_storage_ref text,
      requested_abandoned_at timestamptz,
      requested_failure_code text
    )
    RETURNS TABLE (
      stage_id uuid,
      state text,
      state_revision bigint,
      failure_code text,
      applied boolean
    )
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, content, audit
    AS $function$
    DECLARE
      selected_stage_id uuid;
      selected_state text;
      selected_revision bigint;
      selected_failure_code text;
      selected_grant_id uuid;
      selected_asset_id uuid;
      selected_vault_id uuid;
      selected_principal_id uuid;
      selected_classification text;
      selected_consumed_at timestamptz;
    BEGIN
      IF requested_stage_id IS NULL
         OR requested_storage_ref IS NULL
         OR length(requested_storage_ref) = 0
         OR requested_abandoned_at IS NULL
         OR requested_failure_code NOT IN (
           'runtime_restarted',
           'custody_revoked'
         )
      THEN
        RAISE EXCEPTION 'upload abandonment evidence is invalid';
      END IF;

      SELECT
        stage.id,
        stage.state,
        stage.state_revision,
        stage.failure_code,
        upload_grant.id,
        asset.id,
        stage.vault_id,
        upload_grant.principal_id,
        stage.classification,
        upload_grant.consumed_at
      INTO
        selected_stage_id,
        selected_state,
        selected_revision,
        selected_failure_code,
        selected_grant_id,
        selected_asset_id,
        selected_vault_id,
        selected_principal_id,
        selected_classification,
        selected_consumed_at
      FROM content.asset_stages AS stage
      JOIN content.upload_grants AS upload_grant
        ON upload_grant.id = stage.upload_grant_id
       AND upload_grant.vault_id = stage.vault_id
      JOIN content.assets AS asset
        ON asset.id = stage.asset_id
       AND asset.vault_id = stage.vault_id
      WHERE stage.id = requested_stage_id
        AND stage.storage_ref = requested_storage_ref
      FOR UPDATE OF stage, upload_grant, asset;

      IF NOT FOUND OR selected_consumed_at IS NULL THEN
        RETURN;
      END IF;

      IF selected_state = 'open' THEN
        selected_revision := selected_revision + 1;

        UPDATE content.asset_stages AS stage
        SET
          state = 'abandoned',
          state_revision = selected_revision,
          abandoned_at = requested_abandoned_at,
          failure_code = requested_failure_code,
          updated_at = requested_abandoned_at
        WHERE stage.id = selected_stage_id;

        INSERT INTO audit.events (
          id,
          vault_id,
          actor_kind,
          principal_id,
          operation,
          result,
          classification,
          correlation_id,
          target_type,
          target_id,
          metadata,
          occurred_at,
          inserted_at
        ) VALUES (
          gen_random_uuid(),
          selected_vault_id,
          'principal',
          selected_principal_id,
          'asset.upload_abandoned',
          'completed',
          selected_classification,
          gen_random_uuid(),
          'asset',
          selected_asset_id,
          jsonb_build_object(
            'failure_code', requested_failure_code,
            'grant_id', selected_grant_id,
            'stage_id', selected_stage_id
          ),
          requested_abandoned_at,
          requested_abandoned_at
        );

        selected_state := 'abandoned';
        selected_failure_code := requested_failure_code;
        applied := true;
      ELSE
        applied := false;
      END IF;

      stage_id := selected_stage_id;
      state := selected_state;
      state_revision := selected_revision;
      failure_code := selected_failure_code;
      RETURN NEXT;
    END
    $function$
    """)

    execute("""
    REVOKE ALL ON FUNCTION content.list_open_upload_stages()
    FROM PUBLIC
    """)

    execute("""
    REVOKE ALL ON FUNCTION content.reconcile_open_upload_stage(
      uuid,
      text,
      timestamptz,
      text
    )
    FROM PUBLIC
    """)

    execute("""
    REVOKE ALL ON FUNCTION content.upload_stage_recovery_status(
      uuid,
      text
    )
    FROM PUBLIC
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION content.list_open_upload_stages()
    TO singularity_worker
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION content.reconcile_open_upload_stage(
      uuid,
      text,
      timestamptz,
      text
    )
    TO singularity_worker
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION content.upload_stage_recovery_status(
      uuid,
      text
    )
    TO singularity_worker
    """)

    execute("""
    ALTER TABLE content.asset_objects
      DROP CONSTRAINT asset_objects_vault_id_key_domain_id_lookup_digest_key,
      DROP CONSTRAINT asset_objects_lifecycle_check,
      ADD COLUMN lifecycle_revision bigint NOT NULL DEFAULT 0,
      ADD COLUMN delete_claim_token uuid,
      ADD COLUMN delete_claimed_at timestamptz(6),
      ADD CONSTRAINT asset_objects_lifecycle_check
        CHECK (
          lifecycle IN (
            'staged',
            'available',
            'pending_delete',
            'orphan_pending',
            'deleting',
            'deleted'
          )
        ),
      ADD CONSTRAINT asset_objects_lifecycle_revision_check
        CHECK (lifecycle_revision >= 0),
      ADD CONSTRAINT asset_objects_cleanup_claim_check
        CHECK (
          (
            lifecycle = 'deleting'
            AND delete_claim_token IS NOT NULL
            AND delete_claimed_at IS NOT NULL
          )
          OR
          (
            lifecycle <> 'deleting'
            AND delete_claim_token IS NULL
            AND delete_claimed_at IS NULL
          )
        )
      ,
      ADD CONSTRAINT asset_objects_lifecycle_evidence_check
        CHECK (
          (
            lifecycle = 'orphan_pending'
            AND retained_until IS NOT NULL
            AND deleted_at IS NULL
            AND deletion_evidence IS NULL
          )
          OR
          (
            lifecycle = 'deleting'
            AND retained_until IS NOT NULL
            AND deleted_at IS NULL
            AND deletion_evidence IS NULL
          )
          OR
          (
            lifecycle = 'deleted'
            AND deleted_at IS NOT NULL
            AND jsonb_typeof(deletion_evidence) = 'object'
          )
          OR
          (
            lifecycle NOT IN ('orphan_pending', 'deleting', 'deleted')
            AND deleted_at IS NULL
            AND deletion_evidence IS NULL
          )
        )
    """)

    execute("""
    CREATE UNIQUE INDEX asset_objects_live_lookup_key
      ON content.asset_objects(vault_id, key_domain_id, lookup_digest)
      WHERE lifecycle <> 'deleted'
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("LOCK TABLE content.asset_stages IN ACCESS EXCLUSIVE MODE")

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_authorization_definer")

    execute("""
    DROP FUNCTION IF EXISTS
      core.current_principal_can_discover_classification(text)
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DO $guard$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM jobs.effect_receipts
        WHERE result = 'failed'
      ) THEN
        RAISE EXCEPTION
          'cannot downgrade Task 12: failed asset job receipts exist';
      END IF;
    END
    $guard$
    """)

    execute("""
    ALTER TABLE jobs.effect_receipts
      DROP CONSTRAINT effect_receipts_result_check,
      ADD CONSTRAINT effect_receipts_result_check
        CHECK (result IN ('applied', 'stale'))
    """)

    execute("DROP FUNCTION IF EXISTS core.object_cleanup_authorization(uuid)")

    execute(
      "DROP FUNCTION IF EXISTS content.reconcile_open_upload_stage(uuid, text, timestamptz, text)"
    )

    execute("DROP FUNCTION IF EXISTS content.upload_stage_recovery_status(uuid, text)")

    execute("DROP FUNCTION IF EXISTS content.list_open_upload_stages()")

    execute("""
    DO $guard$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM content.asset_stages
        WHERE format_version IS NULL
           OR plaintext_byte_size IS NULL
           OR ciphertext_byte_size IS NULL
           OR lookup_digest IS NULL
           OR ciphertext_hash IS NULL
      ) THEN
        RAISE EXCEPTION
          'cannot downgrade Task 12: unsealed asset stages require nullable crypto evidence';
      END IF;
    END
    $guard$
    """)

    execute("""
    DROP INDEX content.asset_objects_live_lookup_key
    """)

    execute("""
    ALTER TABLE content.asset_objects
      DROP CONSTRAINT asset_objects_cleanup_claim_check,
      DROP CONSTRAINT asset_objects_lifecycle_evidence_check,
      DROP CONSTRAINT asset_objects_lifecycle_revision_check,
      DROP CONSTRAINT asset_objects_lifecycle_check,
      DROP COLUMN delete_claimed_at,
      DROP COLUMN delete_claim_token,
      DROP COLUMN lifecycle_revision,
      ADD CONSTRAINT asset_objects_vault_id_key_domain_id_lookup_digest_key
        UNIQUE (vault_id, key_domain_id, lookup_digest),
      ADD CONSTRAINT asset_objects_lifecycle_check
        CHECK (lifecycle IN ('staged', 'available', 'pending_delete', 'deleted'))
    """)

    execute("""
    ALTER TABLE content.asset_stages
      DROP CONSTRAINT asset_stages_crypto_state_check,
      DROP CONSTRAINT asset_stages_abandonment_shape_check,
      DROP CONSTRAINT asset_stages_state_revision_check,
      DROP CONSTRAINT asset_stages_wrapper_shape_check,
      DROP CONSTRAINT asset_stages_key_generation_check,
      DROP CONSTRAINT asset_stages_candidate_object_vault_key,
      DROP CONSTRAINT asset_stages_upload_grant_id_key,
      DROP CONSTRAINT asset_stages_upload_grant_vault_fkey,
      DROP CONSTRAINT asset_stages_domain_version_vault_fkey,
      DROP COLUMN dek_wrapper,
      DROP COLUMN state_revision,
      DROP COLUMN key_generation,
      DROP COLUMN wrapper_algorithm,
      DROP COLUMN domain_key_version_id,
      DROP COLUMN candidate_object_id,
      DROP COLUMN upload_grant_id,
      ALTER COLUMN format_version SET NOT NULL,
      ALTER COLUMN plaintext_byte_size SET NOT NULL,
      ALTER COLUMN ciphertext_byte_size SET NOT NULL,
      ALTER COLUMN lookup_digest SET NOT NULL,
      ALTER COLUMN ciphertext_hash SET NOT NULL
    """)

    execute("""
    DO $guard$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM content.upload_grants
        GROUP BY vault_id, idempotency_key
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION
          'cannot downgrade Task 12: upload grant attempt history uses repeated idempotency keys';
      END IF;
    END
    $guard$
    """)

    execute("""
    DROP INDEX content.upload_grants_active_idempotency_key
    """)

    execute("""
    ALTER TABLE content.upload_grants
      ADD CONSTRAINT upload_grants_vault_id_idempotency_key_key
        UNIQUE (vault_id, idempotency_key)
    """)

    execute("""
    ALTER TABLE content.upload_grants
      DROP CONSTRAINT upload_grants_source_reference_vault_fkey,
      DROP COLUMN source_reference_id,
      DROP CONSTRAINT upload_grants_vault_authorization_epoch_check,
      DROP CONSTRAINT upload_grants_id_vault_id_key,
      DROP COLUMN vault_authorization_epoch
    """)

    execute("""
    ALTER TABLE content.source_references
      DROP CONSTRAINT source_references_id_vault_id_key
    """)

    execute("""
    ALTER TABLE core.vaults
      DROP CONSTRAINT vaults_object_cleanup_membership_fkey,
      DROP COLUMN object_cleanup_principal_id
    """)

    execute("""
    ALTER TABLE content.upload_grants
      RENAME CONSTRAINT upload_grants_principal_authorization_epoch_check
      TO upload_grants_authorization_epoch_check
    """)

    execute("""
    ALTER TABLE content.upload_grants
      RENAME COLUMN principal_authorization_epoch TO authorization_epoch
    """)

    execute("SET LOCAL ROLE NONE")
  end
end
