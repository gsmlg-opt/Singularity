defmodule Singularity.Storage.Migrations.ExportCurrentVaultOwnerForBackup do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    CREATE POLICY task14_authorization_reads_people
    ON identity.people
    FOR SELECT
    TO singularity_authorization_definer
    USING (true)
    """)

    grant_identity_columns()

    execute("""
    GRANT CREATE ON SCHEMA identity
    TO singularity_authorization_definer
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_authorization_definer")

    create_export_function()

    execute("""
    REVOKE ALL ON FUNCTION identity.export_current_vault_owner(uuid)
    FROM PUBLIC
    """)

    execute("""
    GRANT EXECUTE ON FUNCTION identity.export_current_vault_owner(uuid)
    TO singularity_worker
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    REVOKE CREATE ON SCHEMA identity
    FROM singularity_authorization_definer
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_authorization_definer")

    execute("""
    DROP FUNCTION IF EXISTS identity.export_current_vault_owner(uuid)
    """)

    execute("SET LOCAL ROLE NONE")
    execute("SET LOCAL ROLE singularity_table_owner")

    revoke_identity_columns()

    execute("""
    DROP POLICY IF EXISTS task14_authorization_reads_people
    ON identity.people
    """)

    execute("SET LOCAL ROLE NONE")
  end

  defp grant_identity_columns do
    execute("""
    GRANT SELECT (id, display_name, metadata, inserted_at, updated_at)
    ON identity.people
    TO singularity_authorization_definer
    """)

    execute("""
    GRANT SELECT (person_id, metadata, inserted_at, updated_at)
    ON identity.accounts
    TO singularity_authorization_definer
    """)

    execute("""
    GRANT SELECT (normalized_login, inserted_at)
    ON identity.credentials
    TO singularity_authorization_definer
    """)

    execute("""
    GRANT SELECT (metadata, inserted_at, updated_at)
    ON identity.principals
    TO singularity_authorization_definer
    """)
  end

  defp revoke_identity_columns do
    execute("""
    REVOKE SELECT (id, display_name, metadata, inserted_at, updated_at)
    ON identity.people
    FROM singularity_authorization_definer
    """)

    execute("""
    REVOKE SELECT (person_id, metadata, inserted_at, updated_at)
    ON identity.accounts
    FROM singularity_authorization_definer
    """)

    execute("""
    REVOKE SELECT (normalized_login, inserted_at)
    ON identity.credentials
    FROM singularity_authorization_definer
    """)

    execute("""
    REVOKE SELECT (metadata, inserted_at, updated_at)
    ON identity.principals
    FROM singularity_authorization_definer
    """)
  end

  defp create_export_function do
    execute("""
    CREATE FUNCTION identity.export_current_vault_owner(
      requested_vault uuid
    ) RETURNS TABLE (
      person_id uuid,
      person_display_name text,
      person_metadata jsonb,
      person_inserted_at timestamptz,
      person_updated_at timestamptz,
      account_id uuid,
      account_person_id uuid,
      account_status text,
      account_metadata jsonb,
      account_inserted_at timestamptz,
      account_updated_at timestamptz,
      credential_id uuid,
      credential_account_id uuid,
      credential_normalized_login text,
      credential_revoked_at timestamptz,
      credential_inserted_at timestamptz,
      principal_id uuid,
      principal_account_id uuid,
      principal_kind text,
      principal_authorization_epoch bigint,
      principal_revoked_at timestamptz,
      principal_metadata jsonb,
      principal_inserted_at timestamptz,
      principal_updated_at timestamptz
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
      ),
      scoped_owner AS (
        SELECT
          person.id AS person_id,
          person.display_name AS person_display_name,
          person.metadata AS person_metadata,
          person.inserted_at AS person_inserted_at,
          person.updated_at AS person_updated_at,
          account.id AS account_id,
          account.person_id AS account_person_id,
          account.status AS account_status,
          account.metadata AS account_metadata,
          account.inserted_at AS account_inserted_at,
          account.updated_at AS account_updated_at
        FROM scoped
        JOIN identity.principals AS owner
          ON owner.id = scoped.principal_id
        JOIN identity.accounts AS account
          ON account.id = owner.account_id
        JOIN identity.people AS person
          ON person.id = account.person_id
        JOIN core.vault_members AS owner_membership
          ON owner_membership.principal_id = owner.id
         AND owner_membership.vault_id = requested_vault
        WHERE requested_vault IS NOT NULL
          AND scoped.vault_id = requested_vault
          AND core.principal_is_authorized(
            scoped.principal_id,
            requested_vault
          )
          AND owner.kind = 'owner'
          AND owner.revoked_at IS NULL
          AND account.status = 'active'
          AND owner_membership.revoked_at IS NULL
      )
      SELECT
        scoped_owner.person_id,
        scoped_owner.person_display_name,
        scoped_owner.person_metadata,
        scoped_owner.person_inserted_at,
        scoped_owner.person_updated_at,
        scoped_owner.account_id,
        scoped_owner.account_person_id,
        scoped_owner.account_status,
        scoped_owner.account_metadata,
        scoped_owner.account_inserted_at,
        scoped_owner.account_updated_at,
        credential.id,
        credential.account_id,
        credential.normalized_login,
        credential.revoked_at,
        credential.inserted_at,
        principal.id,
        principal.account_id,
        principal.kind,
        principal.authorization_epoch,
        principal.revoked_at,
        principal.metadata,
        principal.inserted_at,
        principal.updated_at
      FROM scoped_owner
      JOIN identity.credentials AS credential
        ON credential.account_id = scoped_owner.account_id
      JOIN identity.principals AS principal
        ON principal.account_id = scoped_owner.account_id
      JOIN core.vault_members AS membership
        ON membership.principal_id = principal.id
       AND membership.vault_id = requested_vault
      ORDER BY principal.id, credential.id
    $function$
    """)
  end
end
