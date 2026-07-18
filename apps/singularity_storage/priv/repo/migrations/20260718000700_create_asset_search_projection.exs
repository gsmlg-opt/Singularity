defmodule Singularity.Storage.Migrations.CreateAssetSearchProjection do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DO $migration$
    BEGIN
    CREATE TABLE content.asset_search_documents (
      asset_id uuid PRIMARY KEY,
      resource_version_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      classification text NOT NULL,
      state text NOT NULL,
      detected_media_type text,
      resource_title text NOT NULL,
      original_filename text NOT NULL,
      search_vector tsvector GENERATED ALWAYS AS (
        to_tsvector(
          'simple',
          coalesce(resource_title, '') || ' ' || coalesce(original_filename, '')
        )
      ) STORED,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT asset_search_documents_asset_vault_fkey
        FOREIGN KEY (asset_id, vault_id)
        REFERENCES content.assets(id, vault_id)
        MATCH FULL,
      CONSTRAINT asset_search_documents_resource_version_vault_fkey
        FOREIGN KEY (resource_version_id, vault_id)
        REFERENCES content.resource_versions(id, vault_id)
        MATCH FULL,
      CONSTRAINT asset_search_documents_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT asset_search_documents_state_check
        CHECK (state IN (
          'staging',
          'uploaded',
          'verified',
          'available',
          'processing',
          'ready',
          'pending_delete',
          'deleted'
        ))
    );

    CREATE INDEX asset_search_documents_vector_index
      ON content.asset_search_documents USING gin(search_vector);

    CREATE INDEX asset_search_documents_filters
      ON content.asset_search_documents(
        vault_id,
        state,
        detected_media_type,
        updated_at DESC,
        asset_id
      );

    CREATE INDEX asset_search_documents_vault_recency
      ON content.asset_search_documents(vault_id, updated_at DESC, asset_id);
    END
    $migration$;
    """)

    execute(
      "ALTER TABLE content.asset_search_documents ENABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE content.asset_search_documents FORCE ROW LEVEL SECURITY"
    )

    execute("""
    CREATE POLICY asset_search_documents_table_owner
    ON content.asset_search_documents
    FOR ALL
    TO singularity_table_owner
    USING (true)
    WITH CHECK (true)
    """)

    execute("""
    CREATE POLICY asset_search_documents_vault_isolation
    ON content.asset_search_documents
    FOR ALL
    TO singularity_web, singularity_worker
    USING (
      NULLIF(current_setting('singularity.principal_id', true), '') IS NOT NULL
      AND NULLIF(current_setting('singularity.vault_id', true), '') IS NOT NULL
      AND vault_id =
        NULLIF(current_setting('singularity.vault_id', true), '')::uuid
      AND core.principal_is_authorized(
        NULLIF(current_setting('singularity.principal_id', true), '')::uuid,
        vault_id
      )
    )
    WITH CHECK (
      NULLIF(current_setting('singularity.principal_id', true), '') IS NOT NULL
      AND NULLIF(current_setting('singularity.vault_id', true), '') IS NOT NULL
      AND vault_id =
        NULLIF(current_setting('singularity.vault_id', true), '')::uuid
      AND core.principal_is_authorized(
        NULLIF(current_setting('singularity.principal_id', true), '')::uuid,
        vault_id
      )
    )
    """)

    execute("""
    GRANT SELECT, INSERT, UPDATE, DELETE
    ON content.asset_search_documents
    TO singularity_web, singularity_worker
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")
    execute("DROP TABLE IF EXISTS content.asset_search_documents")
    execute("SET LOCAL ROLE NONE")
  end
end
