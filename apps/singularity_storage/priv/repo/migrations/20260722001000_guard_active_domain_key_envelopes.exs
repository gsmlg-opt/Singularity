defmodule Singularity.Storage.Migrations.GuardActiveDomainKeyEnvelopes do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    CREATE FUNCTION content.enforce_active_domain_key_envelope()
    RETURNS trigger
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = pg_catalog, core, content
    AS $function$
    DECLARE
      referenced_matches boolean;
    BEGIN
      IF session_user = 'singularity_migration' THEN
        PERFORM 1
        FROM core.domain_key_versions AS version
        WHERE version.id = NEW.domain_key_version_id
          AND version.vault_id = NEW.vault_id
          AND version.key_domain_id = NEW.key_domain_id
        FOR SHARE;

        IF FOUND THEN
          RETURN NEW;
        END IF;
      END IF;

      SELECT
        version.state = 'active'
          AND version.vault_id = NEW.vault_id
          AND version.key_domain_id = NEW.key_domain_id
      INTO referenced_matches
      FROM core.domain_key_versions AS version
      WHERE version.id = NEW.domain_key_version_id
      FOR SHARE;

      IF referenced_matches IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION
          'asset key envelope requires a matching active domain key version'
          USING
            ERRCODE = '23514',
            CONSTRAINT = 'asset_key_envelopes_active_domain_key_check';
      END IF;

      RETURN NEW;
    END
    $function$
    """)

    execute("""
    REVOKE ALL ON FUNCTION content.enforce_active_domain_key_envelope()
    FROM PUBLIC
    """)

    execute("""
    CREATE TRIGGER asset_key_envelopes_active_domain_key
    BEFORE INSERT OR UPDATE OF
      vault_id,
      key_domain_id,
      domain_key_version_id,
      key_generation
    ON content.asset_key_envelopes
    FOR EACH ROW
    EXECUTE FUNCTION content.enforce_active_domain_key_envelope()
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DROP TRIGGER IF EXISTS asset_key_envelopes_active_domain_key
    ON content.asset_key_envelopes
    """)

    execute("""
    DROP FUNCTION IF EXISTS content.enforce_active_domain_key_envelope()
    """)

    execute("SET LOCAL ROLE NONE")
  end
end
