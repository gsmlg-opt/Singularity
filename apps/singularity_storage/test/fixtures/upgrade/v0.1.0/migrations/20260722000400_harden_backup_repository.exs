defmodule Singularity.Storage.Migrations.HardenBackupRepository do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    ALTER TABLE audit.backup_manifest_objects
    ADD CONSTRAINT backup_manifest_objects_manifest_id_inventory_position_key
    UNIQUE (manifest_id, inventory_position)
    """)

    execute("""
    CREATE OR REPLACE FUNCTION audit.reject_backup_inventory_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, audit
    AS $function$
    DECLARE
      parent_status text;
    BEGIN
      IF TG_OP = 'INSERT' THEN
        SELECT status INTO parent_status
        FROM audit.backup_manifests
        WHERE id = NEW.manifest_id AND vault_id = NEW.vault_id
        FOR UPDATE;

        IF parent_status IS DISTINCT FROM 'copying' THEN
          RAISE EXCEPTION 'backup inventory requires a copying manifest'
            USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
      END IF;

      RAISE EXCEPTION 'backup inventory is immutable';
    END
    $function$
    """)

    execute("REVOKE ALL ON FUNCTION audit.reject_backup_inventory_mutation() FROM PUBLIC")

    execute("""
    CREATE TRIGGER backup_manifest_objects_immutable
    BEFORE INSERT OR UPDATE OR DELETE ON audit.backup_manifest_objects
    FOR EACH ROW
    EXECUTE FUNCTION audit.reject_backup_inventory_mutation()
    """)

    create_scope_function()
    create_request_function()
    create_lock_function()
    create_replace_function()
    create_activate_function()
    create_claim_function()
    create_waiting_function()
    create_seal_function()
    restrict_privileges()

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    REVOKE EXECUTE ON FUNCTION audit.create_backup_request(
      uuid, uuid, text, text, integer, bytea, jsonb, bytea, text,
      uuid, uuid, uuid, bigint, bigint, uuid, uuid, timestamp with time zone
    ) FROM singularity_web
    """)

    execute("""
    REVOKE EXECUTE ON FUNCTION audit.lock_backup_manifest(uuid, uuid)
    FROM singularity_web, singularity_worker
    """)

    execute("""
    REVOKE EXECUTE ON FUNCTION audit.replace_backup_custody(
      uuid, uuid, text, text, uuid, uuid, uuid, timestamp with time zone
    )
    FROM singularity_web
    """)

    execute("""
    REVOKE EXECUTE ON FUNCTION audit.activate_backup_manifest(uuid, uuid, text)
    FROM singularity_web
    """)

    execute("""
    REVOKE EXECUTE ON FUNCTION audit.claim_backup_manifest(uuid, uuid)
    FROM singularity_worker
    """)

    execute("""
    REVOKE EXECUTE ON FUNCTION audit.mark_backup_waiting(uuid, uuid, text)
    FROM singularity_web, singularity_worker
    """)

    execute("""
    REVOKE EXECUTE ON FUNCTION audit.seal_backup_manifest(
      uuid, uuid, text, uuid, bigint, bytea, bytea, jsonb
    ) FROM singularity_worker
    """)

    execute(
      "DROP FUNCTION IF EXISTS audit.seal_backup_manifest(uuid, uuid, text, uuid, bigint, bytea, bytea, jsonb)"
    )

    execute(
      "DROP FUNCTION IF EXISTS audit.create_backup_request(uuid, uuid, text, text, integer, bytea, jsonb, bytea, text, uuid, uuid, uuid, bigint, bigint, uuid, uuid, timestamp with time zone)"
    )

    execute("DROP FUNCTION IF EXISTS audit.mark_backup_waiting(uuid, uuid, text)")
    execute("DROP FUNCTION IF EXISTS audit.claim_backup_manifest(uuid, uuid)")
    execute("DROP FUNCTION IF EXISTS audit.activate_backup_manifest(uuid, uuid, text)")

    execute("""
    DROP FUNCTION IF EXISTS audit.replace_backup_custody(
      uuid, uuid, text, text, uuid, uuid, uuid, timestamp with time zone
    )
    """)

    execute("DROP FUNCTION IF EXISTS audit.replace_backup_custody(uuid, uuid, text, text)")
    execute("DROP FUNCTION IF EXISTS audit.lock_backup_manifest(uuid, uuid)")
    execute("DROP FUNCTION IF EXISTS audit.backup_scope_authorized(uuid)")

    execute(
      "DROP TRIGGER IF EXISTS backup_manifest_objects_immutable ON audit.backup_manifest_objects"
    )

    execute("DROP FUNCTION IF EXISTS audit.reject_backup_inventory_mutation()")

    execute("""
    ALTER TABLE audit.backup_manifest_objects
    DROP CONSTRAINT IF EXISTS backup_manifest_objects_manifest_id_inventory_position_key
    """)

    execute("""
    REVOKE SELECT, INSERT, UPDATE, DELETE
    ON audit.backup_manifests, audit.backup_manifest_objects
    FROM singularity_web, singularity_worker
    """)

    execute("""
    GRANT SELECT, INSERT, UPDATE, DELETE
    ON audit.backup_manifests, audit.backup_manifest_objects
    TO singularity_web, singularity_worker
    """)

    execute("SET LOCAL ROLE NONE")
  end

  defp create_scope_function do
    execute("""
    CREATE OR REPLACE FUNCTION audit.backup_scope_authorized(requested_vault uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = pg_catalog, audit, core
    AS $function$
      SELECT COALESCE(
        requested_vault =
          NULLIF(current_setting('singularity.vault_id', true), '')::uuid
        AND EXISTS (
          SELECT 1
          FROM core.vault_members AS membership
          WHERE membership.vault_id = requested_vault
            AND membership.principal_id =
              NULLIF(current_setting('singularity.principal_id', true), '')::uuid
            AND membership.revoked_at IS NULL
        ),
        false
      )
    $function$
    """)

    execute("REVOKE ALL ON FUNCTION audit.backup_scope_authorized(uuid) FROM PUBLIC")
  end

  defp create_lock_function do
    execute("""
    CREATE OR REPLACE FUNCTION audit.lock_backup_manifest(
      requested_manifest uuid,
      requested_vault uuid
    ) RETURNS text
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, audit, core
    AS $function$
    DECLARE
      current_status text;
    BEGIN
      IF NOT audit.backup_scope_authorized(requested_vault) THEN
        RETURN NULL;
      END IF;

      SELECT status INTO current_status
      FROM audit.backup_manifests
      WHERE id = requested_manifest AND vault_id = requested_vault
      FOR UPDATE;

      RETURN current_status;
    END
    $function$
    """)

    execute("REVOKE ALL ON FUNCTION audit.lock_backup_manifest(uuid, uuid) FROM PUBLIC")

    execute("""
    GRANT EXECUTE ON FUNCTION audit.lock_backup_manifest(uuid, uuid)
    TO singularity_web, singularity_worker
    """)
  end

  defp create_request_function do
    execute("""
    CREATE OR REPLACE FUNCTION audit.create_backup_request(
      requested_manifest uuid,
      requested_vault uuid,
      requested_classification text,
      requested_destination text,
      requested_kdf_version integer,
      requested_kdf_salt bytea,
      requested_kdf_parameters jsonb,
      requested_recovery_wrapper bytea,
      requested_custody text,
      requested_audit_event uuid,
      requested_outbox_event uuid,
      requested_principal uuid,
      requested_principal_epoch bigint,
      requested_vault_epoch bigint,
      requested_correlation uuid,
      requested_causation uuid,
      requested_occurred_at timestamp with time zone
    ) RETURNS text
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, audit, core, identity
    AS $function$
    DECLARE
      resulting_status text;
      live_principal_epoch bigint;
      live_vault_epoch bigint;
    BEGIN
      IF NOT audit.backup_scope_authorized(requested_vault)
        OR requested_principal IS DISTINCT FROM
          NULLIF(current_setting('singularity.principal_id', true), '')::uuid
      THEN
        RETURN NULL;
      END IF;

      SELECT principal.authorization_epoch, vault.authorization_epoch
      INTO live_principal_epoch, live_vault_epoch
      FROM identity.principals AS principal
      JOIN core.vault_members AS membership
        ON membership.principal_id = principal.id
       AND membership.vault_id = requested_vault
       AND membership.revoked_at IS NULL
      JOIN core.vaults AS vault ON vault.id = membership.vault_id
      WHERE principal.id = requested_principal
        AND principal.revoked_at IS NULL;

      IF live_principal_epoch IS DISTINCT FROM requested_principal_epoch
        OR live_vault_epoch IS DISTINCT FROM requested_vault_epoch
      THEN
        RETURN NULL;
      ELSIF requested_manifest IS NULL
        OR requested_classification NOT IN ('private', 'sensitive', 'restricted')
        OR requested_destination IS NULL
        OR btrim(requested_destination) = ''
        OR requested_kdf_version IS NULL
        OR requested_kdf_version <= 0
        OR requested_kdf_salt IS NULL
        OR octet_length(requested_kdf_salt) <> 16
        OR requested_kdf_parameters IS NULL
        OR jsonb_typeof(requested_kdf_parameters) <> 'object'
        OR (SELECT count(*) FROM jsonb_object_keys(requested_kdf_parameters)) <> 4
        OR NOT requested_kdf_parameters ?& ARRAY['m_cost', 'parallelism', 't_cost', 'version']
        OR (requested_kdf_parameters->>'m_cost')::bigint <= 0
        OR (requested_kdf_parameters->>'parallelism')::bigint <= 0
        OR (requested_kdf_parameters->>'t_cost')::bigint <= 0
        OR (requested_kdf_parameters->>'version')::integer <> requested_kdf_version
        OR requested_recovery_wrapper IS NULL
        OR octet_length(requested_recovery_wrapper) = 0
        OR requested_custody IS NULL
        OR btrim(requested_custody) = ''
        OR requested_audit_event IS NULL
        OR requested_outbox_event IS NULL
        OR requested_correlation IS NULL
        OR requested_causation IS DISTINCT FROM requested_manifest
        OR requested_occurred_at IS NULL
        OR requested_manifest = requested_audit_event
        OR requested_manifest = requested_outbox_event
        OR requested_manifest = requested_correlation
        OR requested_audit_event = requested_outbox_event
        OR requested_audit_event = requested_correlation
        OR requested_outbox_event = requested_correlation
      THEN
        RAISE EXCEPTION 'backup request evidence invalid'
          USING ERRCODE = '22023';
      END IF;

      INSERT INTO audit.backup_manifests (
        id,
        vault_id,
        classification,
        status,
        destination_ref,
        kdf_version,
        kdf_salt,
        kdf_parameters,
        recovery_wrapper,
        custody_ref
      ) VALUES (
        requested_manifest,
        requested_vault,
        requested_classification,
        'waiting_for_backup_key',
        requested_destination,
        requested_kdf_version,
        requested_kdf_salt,
        requested_kdf_parameters,
        requested_recovery_wrapper,
        requested_custody
      )
      RETURNING status INTO resulting_status;

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
        occurred_at
      ) VALUES (
        requested_audit_event,
        requested_vault,
        'principal',
        requested_principal,
        'backup.requested',
        'completed',
        requested_classification,
        requested_correlation,
        'backup_manifest',
        requested_manifest,
        '{}'::jsonb,
        requested_occurred_at
      );

      INSERT INTO core.outbox_events (
        id,
        event_type,
        idempotency_key,
        vault_id,
        principal_id,
        required_capability,
        principal_authorization_epoch,
        vault_authorization_epoch,
        classification,
        correlation_id,
        causation_id,
        expected_entity_revision,
        envelope_version,
        payload,
        occurred_at
      ) VALUES (
        requested_outbox_event,
        'backup.requested',
        'backup:' || requested_manifest::text,
        requested_vault,
        requested_principal,
        'backup.create',
        requested_principal_epoch,
        requested_vault_epoch,
        requested_classification,
        requested_correlation,
        requested_causation,
        0,
        1,
        jsonb_build_object('pending_manifest_id', requested_manifest::text),
        requested_occurred_at
      );

      RETURN resulting_status;
    END
    $function$
    """)

    execute("""
    REVOKE ALL ON FUNCTION audit.create_backup_request(
      uuid, uuid, text, text, integer, bytea, jsonb, bytea, text,
      uuid, uuid, uuid, bigint, bigint, uuid, uuid, timestamp with time zone
    ) FROM PUBLIC
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION audit.create_backup_request(
      uuid, uuid, text, text, integer, bytea, jsonb, bytea, text,
      uuid, uuid, uuid, bigint, bigint, uuid, uuid, timestamp with time zone
    ) TO singularity_web
    """)
  end

  defp create_replace_function do
    execute("DROP FUNCTION IF EXISTS audit.replace_backup_custody(uuid, uuid, text, text)")

    execute("""
    CREATE OR REPLACE FUNCTION audit.replace_backup_custody(
      requested_manifest uuid,
      requested_vault uuid,
      expected_custody text,
      replacement_custody text,
      requested_audit_event uuid,
      requested_correlation uuid,
      requested_principal uuid,
      requested_occurred_at timestamp with time zone
    ) RETURNS text
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, audit, core
    AS $function$
    DECLARE
      resulting_status text;
      current_status text;
      current_custody text;
      manifest_classification text;
    BEGIN
      IF NOT audit.backup_scope_authorized(requested_vault)
        OR requested_principal IS DISTINCT FROM
          NULLIF(current_setting('singularity.principal_id', true), '')::uuid
      THEN
        RETURN NULL;
      ELSIF requested_manifest IS NULL
        OR expected_custody IS NULL
        OR btrim(expected_custody) = ''
        OR replacement_custody IS NULL
        OR btrim(replacement_custody) = ''
        OR replacement_custody = expected_custody
        OR requested_audit_event IS NULL
        OR requested_correlation IS NULL
        OR requested_occurred_at IS NULL
        OR requested_manifest = requested_audit_event
        OR requested_manifest = requested_correlation
        OR requested_audit_event = requested_correlation
      THEN
        RAISE EXCEPTION 'backup custody replacement evidence invalid'
          USING ERRCODE = '22023';
      END IF;

      UPDATE audit.backup_manifests
      SET custody_ref = replacement_custody, updated_at = CURRENT_TIMESTAMP
      WHERE id = requested_manifest
        AND vault_id = requested_vault
        AND status = 'waiting_for_backup_key'
        AND custody_ref = expected_custody
      RETURNING status, classification
      INTO resulting_status, manifest_classification;

      IF resulting_status IS NOT NULL THEN
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
          occurred_at
        ) VALUES (
          requested_audit_event,
          requested_vault,
          'principal',
          requested_principal,
          'backup.key_reentered',
          'completed',
          manifest_classification,
          requested_correlation,
          'backup_manifest',
          requested_manifest,
          '{}'::jsonb,
          requested_occurred_at
        );

        RETURN resulting_status;
      END IF;

      SELECT status, custody_ref
      INTO current_status, current_custody
      FROM audit.backup_manifests
      WHERE id = requested_manifest AND vault_id = requested_vault;

      IF current_status IS NULL THEN
        RETURN NULL;
      END IF;

      RAISE EXCEPTION 'backup custody replacement conflict'
        USING ERRCODE = '40001';
    END
    $function$
    """)

    execute("""
    REVOKE ALL ON FUNCTION audit.replace_backup_custody(
      uuid, uuid, text, text, uuid, uuid, uuid, timestamp with time zone
    ) FROM PUBLIC
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION audit.replace_backup_custody(
      uuid, uuid, text, text, uuid, uuid, uuid, timestamp with time zone
    ) TO singularity_web
    """)
  end

  defp create_activate_function do
    execute("""
    CREATE OR REPLACE FUNCTION audit.activate_backup_manifest(
      requested_manifest uuid,
      requested_vault uuid,
      expected_custody text
    ) RETURNS text
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, audit, core
    AS $function$
    DECLARE
      current_status text;
      current_custody text;
    BEGIN
      IF NOT audit.backup_scope_authorized(requested_vault) THEN
        RETURN NULL;
      ELSIF expected_custody IS NULL OR btrim(expected_custody) = '' THEN
        RAISE EXCEPTION 'backup activation custody invalid' USING ERRCODE = '22023';
      END IF;

      SELECT status, custody_ref
      INTO current_status, current_custody
      FROM audit.backup_manifests
      WHERE id = requested_manifest AND vault_id = requested_vault
      FOR UPDATE;

      IF current_status IS NULL THEN
        RETURN NULL;
      ELSIF current_custody IS DISTINCT FROM expected_custody THEN
        RAISE EXCEPTION 'backup activation custody conflict' USING ERRCODE = '40001';
      ELSIF current_status = 'pending' THEN
        RETURN current_status;
      ELSIF current_status <> 'waiting_for_backup_key' THEN
        RAISE EXCEPTION 'backup activation state conflict' USING ERRCODE = '40001';
      END IF;

      UPDATE audit.backup_manifests
      SET status = 'pending', updated_at = CURRENT_TIMESTAMP
      WHERE id = requested_manifest AND vault_id = requested_vault;

      RETURN 'pending';
    END
    $function$
    """)

    execute("REVOKE ALL ON FUNCTION audit.activate_backup_manifest(uuid, uuid, text) FROM PUBLIC")

    execute(
      "GRANT EXECUTE ON FUNCTION audit.activate_backup_manifest(uuid, uuid, text) TO singularity_web"
    )
  end

  defp create_claim_function do
    execute("""
    CREATE OR REPLACE FUNCTION audit.claim_backup_manifest(
      requested_manifest uuid,
      requested_vault uuid
    ) RETURNS text
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, audit, core
    AS $function$
    DECLARE
      current_status text;
    BEGIN
      IF NOT audit.backup_scope_authorized(requested_vault) THEN
        RETURN NULL;
      END IF;

      SELECT status INTO current_status
      FROM audit.backup_manifests
      WHERE id = requested_manifest AND vault_id = requested_vault
      FOR UPDATE;

      IF current_status IS NULL THEN
        RETURN NULL;
      ELSIF current_status = 'pending' THEN
        UPDATE audit.backup_manifests
        SET status = 'copying', updated_at = CURRENT_TIMESTAMP
        WHERE id = requested_manifest AND vault_id = requested_vault;
        RETURN 'copying';
      ELSIF current_status = 'copying' THEN
        UPDATE audit.backup_manifests
        SET status = 'waiting_for_backup_key', updated_at = CURRENT_TIMESTAMP
        WHERE id = requested_manifest AND vault_id = requested_vault;
        RETURN 'waiting_for_backup_key';
      ELSIF current_status IN ('waiting_for_backup_key', 'sealed') THEN
        RETURN current_status;
      END IF;

      RAISE EXCEPTION 'backup claim state conflict' USING ERRCODE = '40001';
    END
    $function$
    """)

    execute("REVOKE ALL ON FUNCTION audit.claim_backup_manifest(uuid, uuid) FROM PUBLIC")

    execute(
      "GRANT EXECUTE ON FUNCTION audit.claim_backup_manifest(uuid, uuid) TO singularity_worker"
    )
  end

  defp create_waiting_function do
    execute("""
    CREATE OR REPLACE FUNCTION audit.mark_backup_waiting(
      requested_manifest uuid,
      requested_vault uuid,
      expected_custody text
    ) RETURNS text
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, audit, core
    AS $function$
    DECLARE
      current_status text;
      current_custody text;
    BEGIN
      IF NOT audit.backup_scope_authorized(requested_vault) THEN
        RETURN NULL;
      ELSIF expected_custody IS NULL OR btrim(expected_custody) = '' THEN
        RAISE EXCEPTION 'backup wait custody invalid' USING ERRCODE = '22023';
      END IF;

      SELECT status, custody_ref
      INTO current_status, current_custody
      FROM audit.backup_manifests
      WHERE id = requested_manifest AND vault_id = requested_vault
      FOR UPDATE;

      IF current_status IS NULL THEN
        RETURN NULL;
      ELSIF current_custody IS DISTINCT FROM expected_custody THEN
        RAISE EXCEPTION 'backup wait custody conflict' USING ERRCODE = '40001';
      ELSIF current_status = 'waiting_for_backup_key' THEN
        RETURN current_status;
      ELSIF current_status NOT IN ('pending', 'copying') THEN
        RAISE EXCEPTION 'backup wait state conflict' USING ERRCODE = '40001';
      END IF;

      UPDATE audit.backup_manifests
      SET status = 'waiting_for_backup_key', updated_at = CURRENT_TIMESTAMP
      WHERE id = requested_manifest AND vault_id = requested_vault;

      RETURN 'waiting_for_backup_key';
    END
    $function$
    """)

    execute("REVOKE ALL ON FUNCTION audit.mark_backup_waiting(uuid, uuid, text) FROM PUBLIC")

    execute(
      "GRANT EXECUTE ON FUNCTION audit.mark_backup_waiting(uuid, uuid, text) TO singularity_web, singularity_worker"
    )
  end

  defp create_seal_function do
    execute("""
    CREATE OR REPLACE FUNCTION audit.seal_backup_manifest(
      requested_manifest uuid,
      requested_vault uuid,
      expected_custody text,
      requested_snapshot uuid,
      requested_outbox_high_water bigint,
      requested_manifest_hash bytea,
      requested_manifest_tag bytea,
      requested_inventory jsonb
    ) RETURNS text
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, audit, core
    AS $function$
    DECLARE
      current_status text;
      current_custody text;
    BEGIN
      IF NOT audit.backup_scope_authorized(requested_vault) THEN
        RETURN NULL;
      ELSIF expected_custody IS NULL
        OR btrim(expected_custody) = ''
        OR requested_snapshot IS NULL
        OR requested_outbox_high_water IS NULL
        OR requested_outbox_high_water < 0
        OR requested_manifest_hash IS NULL
        OR octet_length(requested_manifest_hash) <> 32
        OR requested_manifest_tag IS NULL
        OR octet_length(requested_manifest_tag) <> 16
        OR requested_inventory IS NULL
        OR jsonb_typeof(requested_inventory) <> 'array'
      THEN
        RAISE EXCEPTION 'backup seal evidence invalid' USING ERRCODE = '22023';
      END IF;

      SELECT status, custody_ref
      INTO current_status, current_custody
      FROM audit.backup_manifests
      WHERE id = requested_manifest AND vault_id = requested_vault
      FOR UPDATE;

      IF current_status IS NULL THEN
        RETURN NULL;
      ELSIF current_status IS DISTINCT FROM 'copying'
        OR current_custody IS DISTINCT FROM expected_custody
      THEN
        RAISE EXCEPTION 'backup seal conflict' USING ERRCODE = '40001';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(requested_inventory) WITH ORDINALITY AS item(value, position)
        WHERE jsonb_typeof(item.value) <> 'object'
          OR (SELECT count(*) FROM jsonb_object_keys(item.value)) <> 8
          OR NOT item.value ?& ARRAY[
            'asset_object_id',
            'ciphertext_byte_size',
            'ciphertext_hash',
            'classification',
            'id',
            'inventory_position',
            'storage_ref',
            'vault_id'
          ]
          OR item.value->>'id' IS NULL
          OR item.value->>'asset_object_id' IS NULL
          OR item.value->>'inventory_position' IS NULL
          OR (item.value->>'inventory_position')::bigint IS DISTINCT FROM item.position - 1
          OR item.value->>'vault_id' IS NULL
          OR (item.value->>'vault_id')::uuid IS DISTINCT FROM requested_vault
          OR item.value->>'classification' IS NULL
          OR item.value->>'classification' NOT IN ('private', 'sensitive', 'restricted')
          OR item.value->>'ciphertext_byte_size' IS NULL
          OR (item.value->>'ciphertext_byte_size')::bigint < 0
          OR item.value->>'storage_ref' IS NULL
          OR btrim(item.value->>'storage_ref') = ''
          OR item.value->>'ciphertext_hash' IS NULL
          OR octet_length(decode(item.value->>'ciphertext_hash', 'base64')) <> 32
      ) THEN
        RAISE EXCEPTION 'backup inventory evidence invalid' USING ERRCODE = '22023';
      END IF;

      INSERT INTO audit.backup_manifest_objects (
        id,
        manifest_id,
        asset_object_id,
        vault_id,
        classification,
        inventory_position,
        storage_ref,
        ciphertext_byte_size,
        ciphertext_hash
      )
      SELECT
        (item.value->>'id')::uuid,
        requested_manifest,
        (item.value->>'asset_object_id')::uuid,
        requested_vault,
        item.value->>'classification',
        (item.value->>'inventory_position')::bigint,
        item.value->>'storage_ref',
        (item.value->>'ciphertext_byte_size')::bigint,
        decode(item.value->>'ciphertext_hash', 'base64')
      FROM jsonb_array_elements(requested_inventory) AS item(value);

      UPDATE audit.backup_manifests
      SET
        status = 'sealed',
        snapshot_id = requested_snapshot,
        outbox_high_water = requested_outbox_high_water,
        manifest_hash = requested_manifest_hash,
        manifest_tag = requested_manifest_tag,
        sealed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
      WHERE id = requested_manifest AND vault_id = requested_vault;

      RETURN 'sealed';
    END
    $function$
    """)

    execute("""
    REVOKE ALL ON FUNCTION audit.seal_backup_manifest(
      uuid, uuid, text, uuid, bigint, bytea, bytea, jsonb
    ) FROM PUBLIC
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION audit.seal_backup_manifest(
      uuid, uuid, text, uuid, bigint, bytea, bytea, jsonb
    ) TO singularity_worker
    """)
  end

  defp restrict_privileges do
    execute("""
    REVOKE SELECT, INSERT, UPDATE, DELETE
    ON audit.backup_manifests, audit.backup_manifest_objects
    FROM singularity_web, singularity_worker
    """)

    execute("""
    GRANT SELECT
    ON audit.backup_manifests, audit.backup_manifest_objects
    TO singularity_web, singularity_worker
    """)
  end
end
