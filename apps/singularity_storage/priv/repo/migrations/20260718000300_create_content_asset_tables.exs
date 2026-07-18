defmodule Singularity.Storage.Migrations.CreateContentAssetTables do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DO $migration$
    BEGIN
    CREATE TABLE content.resources (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL REFERENCES core.vaults(id),
      classification text NOT NULL,
      title text NOT NULL,
      deleted_at timestamptz(6),
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (id, vault_id),
      CONSTRAINT resources_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT resources_title_check CHECK (btrim(title) <> '')
    );

    CREATE TABLE content.resource_versions (
      id uuid PRIMARY KEY,
      resource_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      revision bigint NOT NULL,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (id, vault_id),
      UNIQUE (resource_id, vault_id, revision),
      CONSTRAINT resource_versions_resource_vault_fkey
        FOREIGN KEY (resource_id, vault_id)
        REFERENCES content.resources(id, vault_id)
        MATCH FULL,
      CONSTRAINT resource_versions_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT resource_versions_revision_check CHECK (revision >= 0)
    );

    CREATE TABLE content.asset_objects (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL,
      key_domain_id uuid NOT NULL,
      classification text NOT NULL,
      lookup_digest bytea NOT NULL,
      ciphertext_hash bytea NOT NULL,
      plaintext_byte_size bigint NOT NULL,
      ciphertext_byte_size bigint NOT NULL,
      storage_ref text NOT NULL,
      format_version integer NOT NULL,
      lifecycle text NOT NULL,
      retained_until timestamptz(6),
      deleted_at timestamptz(6),
      deletion_evidence jsonb,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (id, vault_id),
      UNIQUE (id, vault_id, key_domain_id),
      UNIQUE (vault_id, key_domain_id, lookup_digest),
      CONSTRAINT asset_objects_key_domain_vault_fkey
        FOREIGN KEY (key_domain_id, vault_id)
        REFERENCES core.key_domains(id, vault_id)
        MATCH FULL,
      CONSTRAINT asset_objects_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT asset_objects_lookup_digest_check
        CHECK (octet_length(lookup_digest) = 32),
      CONSTRAINT asset_objects_ciphertext_hash_check
        CHECK (octet_length(ciphertext_hash) = 32),
      CONSTRAINT asset_objects_sizes_check
        CHECK (plaintext_byte_size >= 0 AND ciphertext_byte_size >= 0),
      CONSTRAINT asset_objects_format_version_check CHECK (format_version > 0),
      CONSTRAINT asset_objects_lifecycle_check
        CHECK (lifecycle IN ('staged', 'available', 'pending_delete', 'deleted'))
    );

    CREATE TABLE content.assets (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL,
      resource_version_id uuid NOT NULL,
      asset_object_id uuid,
      classification text NOT NULL,
      state text NOT NULL,
      state_revision bigint NOT NULL DEFAULT 0,
      failure_code text,
      retryable boolean,
      failed_operation text,
      attempt integer NOT NULL DEFAULT 0,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (id, vault_id),
      CONSTRAINT assets_resource_version_vault_fkey
        FOREIGN KEY (resource_version_id, vault_id)
        REFERENCES content.resource_versions(id, vault_id)
        MATCH FULL,
      CONSTRAINT assets_object_vault_fkey
        FOREIGN KEY (asset_object_id, vault_id)
        REFERENCES content.asset_objects(id, vault_id)
        MATCH SIMPLE,
      CONSTRAINT assets_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT assets_state_check
        CHECK (state IN (
          'staging',
          'uploaded',
          'verified',
          'available',
          'processing',
          'ready',
          'pending_delete',
          'deleted'
        )),
      CONSTRAINT assets_state_revision_check CHECK (state_revision >= 0),
      CONSTRAINT assets_attempt_check CHECK (attempt >= 0),
      CONSTRAINT assets_failure_shape_check
        CHECK (
          (failure_code IS NULL AND retryable IS NULL AND failed_operation IS NULL)
          OR
          (failure_code IS NOT NULL AND retryable IS NOT NULL AND failed_operation IS NOT NULL)
        )
    );

    CREATE TABLE content.asset_stages (
      id uuid PRIMARY KEY,
      asset_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      key_domain_id uuid NOT NULL,
      classification text NOT NULL,
      storage_ref text NOT NULL,
      state text NOT NULL,
      format_version integer NOT NULL,
      plaintext_byte_size bigint NOT NULL,
      ciphertext_byte_size bigint NOT NULL,
      lookup_digest bytea NOT NULL,
      ciphertext_hash bytea NOT NULL,
      sealed_at timestamptz(6),
      abandoned_at timestamptz(6),
      failure_code text,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (id, vault_id),
      CONSTRAINT asset_stages_asset_vault_fkey
        FOREIGN KEY (asset_id, vault_id)
        REFERENCES content.assets(id, vault_id)
        MATCH FULL,
      CONSTRAINT asset_stages_key_domain_vault_fkey
        FOREIGN KEY (key_domain_id, vault_id)
        REFERENCES core.key_domains(id, vault_id)
        MATCH FULL,
      CONSTRAINT asset_stages_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT asset_stages_state_check
        CHECK (state IN ('open', 'sealed', 'finalized', 'abandoned')),
      CONSTRAINT asset_stages_format_version_check CHECK (format_version > 0),
      CONSTRAINT asset_stages_sizes_check
        CHECK (plaintext_byte_size >= 0 AND ciphertext_byte_size >= 0),
      CONSTRAINT asset_stages_lookup_digest_check
        CHECK (octet_length(lookup_digest) = 32),
      CONSTRAINT asset_stages_ciphertext_hash_check
        CHECK (octet_length(ciphertext_hash) = 32)
    );

    CREATE TABLE content.asset_key_envelopes (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL,
      asset_object_id uuid NOT NULL,
      domain_key_version_id uuid NOT NULL,
      key_domain_id uuid NOT NULL,
      classification text NOT NULL,
      algorithm text NOT NULL,
      key_generation integer NOT NULL,
      wrapped_dek bytea NOT NULL,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (asset_object_id, domain_key_version_id),
      CONSTRAINT asset_key_envelopes_object_vault_fkey
        FOREIGN KEY (asset_object_id, vault_id, key_domain_id)
        REFERENCES content.asset_objects(id, vault_id, key_domain_id)
        MATCH FULL,
      CONSTRAINT asset_key_envelopes_domain_version_vault_fkey
        FOREIGN KEY (domain_key_version_id, vault_id, key_domain_id)
        REFERENCES core.domain_key_versions(id, vault_id, key_domain_id)
        MATCH FULL,
      CONSTRAINT asset_key_envelopes_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT asset_key_envelopes_generation_check CHECK (key_generation > 0)
    );

    CREATE TABLE content.asset_metadata (
      id uuid PRIMARY KEY,
      asset_id uuid NOT NULL,
      resource_version_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      projection_version integer NOT NULL,
      original_filename text NOT NULL,
      declared_media_type text NOT NULL,
      detected_media_type text,
      plaintext_byte_size bigint NOT NULL,
      pdf_header_version text,
      image_width integer,
      image_height integer,
      extraction_state text NOT NULL,
      extractor_version text,
      completed_at timestamptz(6),
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (asset_id),
      CONSTRAINT asset_metadata_asset_vault_fkey
        FOREIGN KEY (asset_id, vault_id)
        REFERENCES content.assets(id, vault_id)
        MATCH FULL,
      CONSTRAINT asset_metadata_resource_version_vault_fkey
        FOREIGN KEY (resource_version_id, vault_id)
        REFERENCES content.resource_versions(id, vault_id)
        MATCH FULL,
      CONSTRAINT asset_metadata_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT asset_metadata_projection_version_check CHECK (projection_version > 0),
      CONSTRAINT asset_metadata_plaintext_size_check CHECK (plaintext_byte_size >= 0),
      CONSTRAINT asset_metadata_dimensions_check
        CHECK (
          (image_width IS NULL OR image_width > 0)
          AND (image_height IS NULL OR image_height > 0)
        ),
      CONSTRAINT asset_metadata_extraction_state_check
        CHECK (extraction_state IN ('pending', 'completed', 'failed'))
    );

    CREATE TABLE content.resource_assets (
      resource_version_id uuid NOT NULL,
      asset_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      released_at timestamptz(6),
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (resource_version_id, asset_id),
      CONSTRAINT resource_assets_resource_version_vault_fkey
        FOREIGN KEY (resource_version_id, vault_id)
        REFERENCES content.resource_versions(id, vault_id)
        MATCH FULL,
      CONSTRAINT resource_assets_asset_vault_fkey
        FOREIGN KEY (asset_id, vault_id)
        REFERENCES content.assets(id, vault_id)
        MATCH FULL,
      CONSTRAINT resource_assets_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted'))
    );

    CREATE TABLE content.source_references (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL,
      resource_version_id uuid NOT NULL,
      principal_id uuid NOT NULL,
      classification text NOT NULL,
      kind text NOT NULL,
      observed_at timestamptz(6) NOT NULL,
      original_filename text NOT NULL,
      declared_media_type text NOT NULL,
      byte_size bigint NOT NULL,
      idempotency_key_digest bytea NOT NULL,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT source_references_resource_version_vault_fkey
        FOREIGN KEY (resource_version_id, vault_id)
        REFERENCES content.resource_versions(id, vault_id)
        MATCH FULL,
      CONSTRAINT source_references_membership_fkey
        FOREIGN KEY (principal_id, vault_id)
        REFERENCES core.vault_members(principal_id, vault_id)
        MATCH FULL,
      CONSTRAINT source_references_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT source_references_kind_check CHECK (kind IN ('browser_upload')),
      CONSTRAINT source_references_byte_size_check CHECK (byte_size >= 0),
      CONSTRAINT source_references_idempotency_digest_check
        CHECK (octet_length(idempotency_key_digest) = 32)
    );

    CREATE TABLE content.tombstones (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL,
      asset_id uuid NOT NULL,
      principal_id uuid NOT NULL,
      classification text NOT NULL,
      reason text NOT NULL,
      retention_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      deleted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT tombstones_asset_vault_fkey
        FOREIGN KEY (asset_id, vault_id)
        REFERENCES content.assets(id, vault_id)
        MATCH FULL,
      CONSTRAINT tombstones_membership_fkey
        FOREIGN KEY (principal_id, vault_id)
        REFERENCES core.vault_members(principal_id, vault_id)
        MATCH FULL,
      CONSTRAINT tombstones_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted'))
    );

    CREATE TABLE content.upload_grants (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL,
      session_id uuid NOT NULL,
      principal_id uuid NOT NULL,
      asset_id uuid NOT NULL,
      classification text NOT NULL,
      token_digest bytea NOT NULL UNIQUE,
      filename text NOT NULL,
      byte_size bigint NOT NULL,
      declared_media_type text NOT NULL,
      idempotency_key text NOT NULL,
      authorization_epoch bigint NOT NULL,
      expires_at timestamptz(6) NOT NULL,
      consumed_at timestamptz(6),
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (vault_id, idempotency_key),
      CONSTRAINT upload_grants_session_vault_fkey
        FOREIGN KEY (session_id, vault_id)
        REFERENCES identity.sessions(id, vault_id)
        MATCH FULL,
      CONSTRAINT upload_grants_membership_fkey
        FOREIGN KEY (principal_id, vault_id)
        REFERENCES core.vault_members(principal_id, vault_id)
        MATCH FULL,
      CONSTRAINT upload_grants_asset_vault_fkey
        FOREIGN KEY (asset_id, vault_id)
        REFERENCES content.assets(id, vault_id)
        MATCH FULL,
      CONSTRAINT upload_grants_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT upload_grants_token_digest_check
        CHECK (octet_length(token_digest) = 32),
      CONSTRAINT upload_grants_byte_size_check CHECK (byte_size >= 0),
      CONSTRAINT upload_grants_authorization_epoch_check
        CHECK (authorization_epoch >= 0)
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
    DROP TABLE IF EXISTS content.upload_grants;
    DROP TABLE IF EXISTS content.tombstones;
    DROP TABLE IF EXISTS content.source_references;
    DROP TABLE IF EXISTS content.resource_assets;
    DROP TABLE IF EXISTS content.asset_metadata;
    DROP TABLE IF EXISTS content.asset_key_envelopes;
    DROP TABLE IF EXISTS content.asset_stages;
    DROP TABLE IF EXISTS content.assets;
    DROP TABLE IF EXISTS content.asset_objects;
    DROP TABLE IF EXISTS content.resource_versions;
    DROP TABLE IF EXISTS content.resources;
    END
    $migration$;
    """)

    execute("SET LOCAL ROLE NONE")
  end
end
