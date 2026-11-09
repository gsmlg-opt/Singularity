defmodule Singularity.Storage.Migrations.CreateIdentityAndVaultTables do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DO $migration$
    BEGIN
    CREATE TABLE identity.people (
      id uuid PRIMARY KEY,
      display_name text NOT NULL,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE identity.accounts (
      id uuid PRIMARY KEY,
      person_id uuid NOT NULL REFERENCES identity.people(id),
      status text NOT NULL DEFAULT 'active',
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT accounts_status_check
        CHECK (status IN ('active', 'disabled'))
    );

    CREATE TABLE identity.credentials (
      id uuid PRIMARY KEY,
      account_id uuid NOT NULL REFERENCES identity.accounts(id),
      normalized_login text NOT NULL UNIQUE,
      verifier text NOT NULL,
      verifier_version integer NOT NULL DEFAULT 1,
      revoked_at timestamptz(6),
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT credentials_login_check
        CHECK (normalized_login = lower(btrim(normalized_login))
          AND normalized_login <> ''),
      CONSTRAINT credentials_verifier_version_check
        CHECK (verifier_version > 0)
    );

    CREATE TABLE identity.principals (
      id uuid PRIMARY KEY,
      account_id uuid NOT NULL REFERENCES identity.accounts(id),
      kind text NOT NULL,
      authorization_epoch bigint NOT NULL DEFAULT 0,
      revoked_at timestamptz(6),
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT principals_kind_check
        CHECK (kind IN ('owner', 'system')),
      CONSTRAINT principals_authorization_epoch_check
        CHECK (authorization_epoch >= 0)
    );

    CREATE TABLE core.vaults (
      id uuid PRIMARY KEY,
      kind text NOT NULL DEFAULT 'personal',
      authorization_epoch bigint NOT NULL DEFAULT 0,
      locked boolean NOT NULL DEFAULT true,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT vaults_kind_check
        CHECK (kind IN ('personal', 'system')),
      CONSTRAINT vaults_authorization_epoch_check
        CHECK (authorization_epoch >= 0)
    );

    CREATE TABLE core.vault_members (
      principal_id uuid NOT NULL REFERENCES identity.principals(id),
      vault_id uuid NOT NULL REFERENCES core.vaults(id),
      clearance text NOT NULL DEFAULT 'private',
      revoked_at timestamptz(6),
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (principal_id, vault_id),
      CONSTRAINT vault_members_classification_check
        CHECK (clearance IN ('private', 'sensitive', 'restricted'))
    );

    CREATE TABLE core.capabilities (
      id uuid PRIMARY KEY,
      name text NOT NULL UNIQUE,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT capabilities_name_check CHECK (btrim(name) <> '')
    );

    CREATE TABLE core.principal_capabilities (
      principal_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      capability_id uuid NOT NULL REFERENCES core.capabilities(id),
      revoked_at timestamptz(6),
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (principal_id, vault_id, capability_id),
      CONSTRAINT principal_capabilities_membership_fkey
        FOREIGN KEY (principal_id, vault_id)
        REFERENCES core.vault_members(principal_id, vault_id)
        MATCH FULL
    );

    CREATE TABLE core.data_classifications (
      name text PRIMARY KEY,
      rank smallint NOT NULL UNIQUE,
      CONSTRAINT data_classifications_name_check
        CHECK (name IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT data_classifications_rank_check
        CHECK (rank >= 0)
    );

    INSERT INTO core.data_classifications (name, rank)
    VALUES ('private', 0), ('sensitive', 1), ('restricted', 2);

    CREATE TABLE core.key_domains (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL REFERENCES core.vaults(id),
      classification text NOT NULL,
      kind text NOT NULL DEFAULT 'content',
      state text NOT NULL DEFAULT 'active',
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (id, vault_id),
      CONSTRAINT key_domains_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT key_domains_state_check
        CHECK (state IN ('active', 'retired'))
    );

    CREATE TABLE core.vault_key_versions (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL REFERENCES core.vaults(id),
      generation integer NOT NULL,
      state text NOT NULL,
      algorithm text NOT NULL,
      activated_at timestamptz(6),
      retired_at timestamptz(6),
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (id, vault_id),
      UNIQUE (vault_id, generation),
      CONSTRAINT vault_key_versions_generation_check CHECK (generation > 0),
      CONSTRAINT vault_key_versions_state_check
        CHECK (state IN ('pending', 'active', 'retired'))
    );

    CREATE UNIQUE INDEX vault_key_versions_one_active
      ON core.vault_key_versions(vault_id)
      WHERE state = 'active';

    CREATE TABLE core.vault_key_wrappers (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL,
      vault_key_version_id uuid NOT NULL,
      account_id uuid NOT NULL REFERENCES identity.accounts(id),
      kdf_version integer NOT NULL,
      kdf_salt bytea NOT NULL,
      kdf_parameters jsonb NOT NULL,
      wrapper_algorithm text NOT NULL,
      wrapped_key bytea NOT NULL,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT vault_key_wrappers_version_fkey
        FOREIGN KEY (vault_key_version_id, vault_id)
        REFERENCES core.vault_key_versions(id, vault_id)
        MATCH FULL,
      CONSTRAINT vault_key_wrappers_kdf_version_check CHECK (kdf_version > 0)
    );

    CREATE TABLE core.domain_key_versions (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL,
      key_domain_id uuid NOT NULL,
      vault_key_version_id uuid NOT NULL,
      generation integer NOT NULL,
      state text NOT NULL,
      algorithm text NOT NULL,
      wrapped_key bytea NOT NULL,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (id, vault_id),
      UNIQUE (id, vault_id, key_domain_id),
      UNIQUE (key_domain_id, generation),
      CONSTRAINT domain_key_versions_domain_fkey
        FOREIGN KEY (key_domain_id, vault_id)
        REFERENCES core.key_domains(id, vault_id)
        MATCH FULL,
      CONSTRAINT domain_key_versions_vault_key_fkey
        FOREIGN KEY (vault_key_version_id, vault_id)
        REFERENCES core.vault_key_versions(id, vault_id)
        MATCH FULL,
      CONSTRAINT domain_key_versions_generation_check CHECK (generation > 0),
      CONSTRAINT domain_key_versions_state_check
        CHECK (state IN ('pending', 'active', 'retired'))
    );

    CREATE TABLE core.domain_dedup_key_wrappers (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL,
      key_domain_id uuid NOT NULL,
      domain_key_version_id uuid NOT NULL,
      algorithm text NOT NULL,
      wrapped_key bytea NOT NULL,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT domain_dedup_key_wrappers_domain_fkey
        FOREIGN KEY (key_domain_id, vault_id)
        REFERENCES core.key_domains(id, vault_id)
        MATCH FULL,
      CONSTRAINT domain_dedup_key_wrappers_version_fkey
        FOREIGN KEY (domain_key_version_id, vault_id, key_domain_id)
        REFERENCES core.domain_key_versions(id, vault_id, key_domain_id)
        MATCH FULL
    );

    CREATE TABLE identity.sessions (
      id uuid PRIMARY KEY,
      account_id uuid NOT NULL REFERENCES identity.accounts(id),
      principal_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      token_digest bytea NOT NULL UNIQUE,
      expires_at timestamptz(6) NOT NULL,
      revoked_at timestamptz(6),
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (id, vault_id),
      CONSTRAINT sessions_membership_fkey
        FOREIGN KEY (principal_id, vault_id)
        REFERENCES core.vault_members(principal_id, vault_id)
        MATCH FULL,
      CONSTRAINT sessions_token_digest_check
        CHECK (octet_length(token_digest) = 32)
    );

    CREATE TABLE identity.devices (
      id uuid PRIMARY KEY,
      principal_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      label text NOT NULL,
      revoked_at timestamptz(6),
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT devices_membership_fkey
        FOREIGN KEY (principal_id, vault_id)
        REFERENCES core.vault_members(principal_id, vault_id)
        MATCH FULL
    );

    CREATE TABLE identity.auth_attempts (
      id uuid PRIMARY KEY,
      login_fingerprint bytea NOT NULL,
      source_fingerprint bytea NOT NULL,
      result text NOT NULL,
      correlation_id uuid NOT NULL,
      attempted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT auth_attempts_login_fingerprint_check
        CHECK (octet_length(login_fingerprint) = 32),
      CONSTRAINT auth_attempts_source_fingerprint_check
        CHECK (octet_length(source_fingerprint) = 32),
      CONSTRAINT auth_attempts_result_check
        CHECK (result IN ('started', 'failed', 'succeeded'))
    );

    CREATE INDEX auth_attempts_login_bucket
      ON identity.auth_attempts(login_fingerprint, attempted_at DESC);
    CREATE INDEX auth_attempts_source_bucket
      ON identity.auth_attempts(source_fingerprint, attempted_at DESC);

    CREATE TABLE identity.security_settings (
      singleton boolean PRIMARY KEY DEFAULT true,
      dummy_verifier text NOT NULL,
      login_window_seconds integer NOT NULL,
      login_max_attempts integer NOT NULL,
      source_window_seconds integer NOT NULL,
      source_max_attempts integer NOT NULL,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT security_settings_singleton_check CHECK (singleton),
      CONSTRAINT security_settings_limits_check
        CHECK (
          login_window_seconds > 0
          AND login_max_attempts > 0
          AND source_window_seconds > 0
          AND source_max_attempts > 0
        )
    );

    INSERT INTO identity.security_settings (
      singleton,
      dummy_verifier,
      login_window_seconds,
      login_max_attempts,
      source_window_seconds,
      source_max_attempts
    )
    VALUES (
      true,
      '$argon2id$v=19$m=65536,t=3,p=1$c2luZ3VsYXJpdHlkdW1teQ$c2luZ3VsYXJpdHlkdW1teXZlcmlmaWVy',
      300,
      5,
      300,
      20
    );
    END
    $migration$;
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DO $migration$
    BEGIN
    DROP TABLE IF EXISTS identity.security_settings;
    DROP TABLE IF EXISTS identity.auth_attempts;
    DROP TABLE IF EXISTS identity.devices;
    DROP TABLE IF EXISTS identity.sessions;
    DROP TABLE IF EXISTS core.domain_dedup_key_wrappers;
    DROP TABLE IF EXISTS core.domain_key_versions;
    DROP TABLE IF EXISTS core.vault_key_wrappers;
    DROP TABLE IF EXISTS core.vault_key_versions;
    DROP TABLE IF EXISTS core.key_domains;
    DROP TABLE IF EXISTS core.data_classifications;
    DROP TABLE IF EXISTS core.principal_capabilities;
    DROP TABLE IF EXISTS core.capabilities;
    DROP TABLE IF EXISTS core.vault_members;
    DROP TABLE IF EXISTS core.vaults;
    DROP TABLE IF EXISTS identity.principals;
    DROP TABLE IF EXISTS identity.credentials;
    DROP TABLE IF EXISTS identity.accounts;
    DROP TABLE IF EXISTS identity.people;
    END
    $migration$;
    """)

    execute("SET LOCAL ROLE NONE")
  end
end
