defmodule Singularity.Storage.Migrations.DocumentTerminalTombstone do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    CREATE FUNCTION content.lock_document_terminal_extraction(version uuid, job_id uuid, generation bigint)
    RETURNS content.document_versions LANGUAGE plpgsql SECURITY INVOKER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    DECLARE scoped_owner uuid; scoped_principal uuid; resource uuid; document content.document_versions%ROWTYPE;
    BEGIN
      BEGIN
        scoped_owner := nullif(current_setting('singularity.vault_id',true),'')::uuid;
        scoped_principal := nullif(current_setting('singularity.principal_id',true),'')::uuid;
      EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Document extraction is not authorized'
          USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
      END;
      IF scoped_owner IS NULL OR scoped_principal IS NULL OR NOT EXISTS (
        SELECT 1 FROM core.vault_members AS membership
        JOIN identity.principals AS principal ON principal.id = membership.principal_id
        JOIN identity.accounts AS account ON account.id = principal.account_id
        WHERE membership.vault_id = scoped_owner AND membership.principal_id = scoped_principal
          AND membership.revoked_at IS NULL AND principal.kind = 'owner'
          AND principal.revoked_at IS NULL AND account.status = 'active'
      ) THEN
        RAISE EXCEPTION 'Document extraction is not authorized'
          USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
      END IF;
      SELECT resource_id INTO resource FROM content.document_versions
        WHERE resource_version_id = version AND vault_id = scoped_owner AND classification = 'private';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Document extraction is not authorized'
          USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
      END IF;
      PERFORM 1 FROM content.resources WHERE id = resource AND vault_id = scoped_owner
        AND classification = 'private' AND kind = 'document' FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Document extraction is not authorized'
          USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
      END IF;
      SELECT * INTO document FROM content.document_versions
        WHERE resource_version_id = version AND resource_id = resource AND vault_id = scoped_owner
          AND classification = 'private' FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Document extraction is not authorized'
          USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
      END IF;
      IF document.state NOT IN ('extracting','ready','failed','unsupported')
         OR document.attempt_generation IS DISTINCT FROM generation
         OR document.attempt_job_id IS DISTINCT FROM job_id THEN
        RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
          USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
      END IF;
      RETURN document;
    END
    $function$
    """)

    # The committed attempt migration owns all terminal validation and fragment
    # insertion. Change only its lock entrypoint; preserve every other guard.
    for signature <- [
          "complete_document_extraction(uuid,uuid,bigint,jsonb,bytea,text)",
          "fail_document_extraction(uuid,uuid,bigint,text,text)"
        ] do
      execute("""
      DO $migration$
      DECLARE definition text; old_call text := 'content.lock_document_extraction(version)';
        new_call text := 'content.lock_document_terminal_extraction(version, job_id, generation)';
      BEGIN
        SELECT pg_get_functiondef(to_regprocedure('content.#{signature}')) INTO definition;
        IF definition IS NULL OR strpos(definition, old_call) = 0
           OR strpos(substr(definition, strpos(definition, old_call) + length(old_call)), old_call) > 0 THEN
          RAISE EXCEPTION 'Unexpected Document terminal function definition';
        END IF;
        EXECUTE replace(definition, old_call, new_call);
      END
      $migration$
      """)
    end

    execute(
      "REVOKE ALL ON FUNCTION content.lock_document_terminal_extraction(uuid,uuid,bigint) FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth"
    )

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "Document terminal tombstone migration is forward-only")
end
