defmodule Singularity.Storage.Migrations.DocumentWorkerBridge do
  use Ecto.Migration

  @parameters "requested_resource uuid, requested_version uuid, requested_job uuid, expected_revision bigint, requested_principal_epoch bigint, requested_owner_epoch bigint"
  @arguments "requested_resource, requested_version, requested_job, expected_revision, requested_principal_epoch, requested_owner_epoch"
  @types "uuid,uuid,uuid,bigint,bigint,bigint"
  @signatures [
    "describe_document_worker(#{@types})",
    "claim_document_worker(#{@types},text,integer)",
    "complete_document_worker(#{@types},bigint,text,integer,text,jsonb,bytea,text)",
    "fail_document_worker(#{@types},bigint,text,integer,text,text,text)"
  ]

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")
    create_target()
    create_describe()
    create_claim()

    create_outcome(
      "complete",
      ", claimed_generation bigint, adapter text, format integer, media_type text, fragments jsonb, extracted_digest bytea, language text",
      "content.complete_document_extraction(requested_version, requested_job, claimed_generation, fragments, extracted_digest, language)"
    )

    create_outcome(
      "fail",
      ", claimed_generation bigint, adapter text, format integer, media_type text, outcome text, failure_code text",
      "content.fail_document_extraction(requested_version, requested_job, claimed_generation, outcome, failure_code)"
    )

    execute(
      "REVOKE ALL ON FUNCTION content.document_worker_target(#{@types},boolean) FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth"
    )

    for signature <- @signatures do
      execute(
        "REVOKE ALL ON FUNCTION content.#{signature} FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth"
      )

      execute("GRANT EXECUTE ON FUNCTION content.#{signature} TO singularity_worker")
    end

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "Document worker bridge migration is forward-only")

  defp create_function(name, extras, result, body) do
    execute("""
    CREATE FUNCTION content.#{name}(#{@parameters}#{extras})
    RETURNS #{result}
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, content, core, identity
    AS $function$
    #{body}
    $function$
    """)
  end

  defp create_target do
    create_function(
      "document_worker_target",
      ", lock_rows boolean",
      "content.document_versions",
      """
      DECLARE scoped_principal uuid; scoped_owner uuid; document content.document_versions%ROWTYPE;
      BEGIN
        IF current_setting('transaction_isolation') <> 'read committed'
           OR lock_rows IS NULL OR requested_resource IS NULL OR requested_version IS NULL
           OR requested_job IS NULL OR expected_revision IS NULL OR expected_revision < 0
           OR expected_revision = 9223372036854775807
           OR requested_principal_epoch IS NULL OR requested_principal_epoch < 0
           OR requested_owner_epoch IS NULL OR requested_owner_epoch < 0 THEN
          RAISE EXCEPTION 'invalid Document extraction input'
            USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
        END IF;
        BEGIN
          scoped_principal := nullif(current_setting('singularity.principal_id',true),'')::uuid;
          scoped_owner := nullif(current_setting('singularity.vault_id',true),'')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
          RAISE EXCEPTION 'Document extraction is not authorized'
            USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
        END;
        IF scoped_principal IS NULL OR scoped_owner IS NULL THEN
          RAISE EXCEPTION 'Document extraction is not authorized'
            USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
        END IF;

        PERFORM pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended(
          'singularity:authorization:' || scoped_principal::text || ':' || scoped_owner::text, 0));
        IF NOT EXISTS (
          SELECT 1 FROM core.live_principal_authorization() AS auth
          WHERE auth.principal_id = scoped_principal AND auth.vault_id = scoped_owner
            AND auth.principal_kind = 'owner' AND auth.principal_revoked_at IS NULL
            AND auth.membership_revoked_at IS NULL
            AND auth.clearance IN ('private','sensitive','restricted')
            AND 'asset.read' = ANY(auth.capabilities)
            AND auth.principal_authorization_epoch = requested_principal_epoch
            AND auth.vault_authorization_epoch = requested_owner_epoch
        ) THEN
          RAISE EXCEPTION 'Document extraction is not authorized'
            USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
        END IF;

        IF lock_rows THEN
          PERFORM 1 FROM content.resources AS r
            WHERE r.id = requested_resource AND r.vault_id = scoped_owner
              AND r.classification = 'private' AND r.kind = 'document' FOR UPDATE;
          PERFORM 1 FROM content.document_versions AS d
            WHERE d.resource_version_id = requested_version AND d.resource_id = requested_resource
              AND d.vault_id = scoped_owner AND d.classification = 'private' FOR UPDATE;
        END IF;

        SELECT d.* INTO document
        FROM content.document_versions AS d
        JOIN content.resources AS r ON r.id = d.resource_id
          AND r.vault_id = d.vault_id AND r.classification = d.classification
        JOIN content.resource_versions AS v ON v.id = d.resource_version_id
          AND v.resource_id = d.resource_id AND v.vault_id = d.vault_id
          AND v.classification = d.classification
        JOIN core.outbox_events AS event ON event.id = requested_job
          AND event.vault_id = d.vault_id AND event.principal_id = scoped_principal
        WHERE d.resource_version_id = requested_version AND d.resource_id = requested_resource
          AND d.vault_id = scoped_owner AND d.classification = 'private'
          AND r.kind = 'document' AND d.created_by_principal_id = scoped_principal
          AND event.event_type = 'document.extraction_requested'
          AND event.required_capability = 'asset.read' AND event.classification = 'private'
          AND event.envelope_version = 1
          AND event.principal_authorization_epoch = requested_principal_epoch
          AND event.vault_authorization_epoch = requested_owner_epoch
          AND event.expected_entity_revision = expected_revision
          AND event.payload = jsonb_build_object('resource_id', requested_resource::text,
            'resource_version_id', requested_version::text)
          AND event.idempotency_key = 'document-extraction:' || requested_version::text ||
            CASE WHEN expected_revision = 0 THEN '' ELSE ':' || expected_revision::text END;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Document extraction is not authorized'
            USING ERRCODE = '42501', CONSTRAINT = 'document_extraction_authority_check';
        END IF;
        RETURN document;
      END
      """
    )
  end

  defp create_describe do
    create_function(
      "describe_document_worker",
      "",
      "TABLE (kind text, resource_id uuid, resource_version_id uuid, job_id uuid, state text, generation bigint, object_id uuid, object_generation bigint, source_digest bytea, source_byte_size bigint, media_type text, adapter_name text, format_version integer, started_at timestamptz, deadline_at timestamptz)",
      """
      DECLARE document content.document_versions%ROWTYPE;
      BEGIN
        document := content.document_worker_target(#{@arguments}, false);
        IF document.state IN ('ready','failed','unsupported')
           AND document.attempt_generation = expected_revision + 1
           AND document.attempt_job_id = requested_job THEN
          RETURN QUERY SELECT 'terminal'::text, document.resource_id, document.resource_version_id,
            requested_job, document.state, document.attempt_generation, NULL::uuid, NULL::bigint,
            NULL::bytea, NULL::bigint, NULL::text, NULL::text, NULL::integer,
            NULL::timestamptz, NULL::timestamptz;
          RETURN;
        END IF;

        RETURN QUERY
        SELECT 'source'::text, d.resource_id, d.resource_version_id, requested_job, d.state,
          d.attempt_generation, d.source_object_id, min(e.key_generation)::bigint,
          d.source_digest, d.source_byte_size, d.media_type, d.extraction_adapter,
          d.extraction_format, d.attempt_started_at, d.attempt_deadline_at
        FROM content.document_versions AS d
        JOIN content.resources AS r ON r.id = d.resource_id
          AND r.vault_id = d.vault_id AND r.classification = d.classification
        JOIN content.asset_objects AS o ON o.id = d.source_object_id
          AND o.vault_id = d.vault_id AND o.classification = d.classification
        JOIN content.asset_key_envelopes AS e ON e.asset_object_id = o.id
          AND e.vault_id = o.vault_id AND e.key_domain_id = o.key_domain_id
          AND e.classification = o.classification
        JOIN core.domain_key_versions AS kv ON kv.id = e.domain_key_version_id
          AND kv.vault_id = e.vault_id AND kv.key_domain_id = e.key_domain_id
        JOIN core.key_domains AS domain ON domain.id = e.key_domain_id
          AND domain.vault_id = e.vault_id AND domain.classification = o.classification
        WHERE d.resource_version_id = requested_version AND d.resource_id = requested_resource
          AND d.vault_id = document.vault_id AND d.classification = 'private'
          AND r.kind = 'document' AND d.created_by_principal_id = document.created_by_principal_id
          AND ((d.state = 'pending' AND d.attempt_generation = expected_revision
                AND r.deleted_at IS NULL)
            OR (d.state = 'extracting' AND d.attempt_generation = expected_revision + 1
                AND d.attempt_job_id = requested_job AND d.attempt_deadline_at > clock_timestamp()))
          AND o.lifecycle = 'available' AND o.plaintext_byte_size = d.source_byte_size
          AND d.source_byte_size BETWEEN 0 AND 67108864 AND octet_length(d.source_digest) = 32
          AND d.media_type IN ('application/pdf','text/markdown','text/plain')
          AND kv.state = 'active' AND domain.state = 'active' AND domain.kind = 'content'
        GROUP BY d.resource_version_id HAVING count(*) = 1 AND min(e.key_generation) > 0;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
            USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
        END IF;
      END
      """
    )
  end

  defp create_claim do
    create_function(
      "claim_document_worker",
      ", adapter text, format integer",
      "TABLE (resource_id uuid, resource_version_id uuid, job_id uuid, generation bigint, state text, adapter_name text, format_version integer, started_at timestamptz, deadline_at timestamptz)",
      """
      DECLARE document content.document_versions%ROWTYPE;
      BEGIN
        document := content.document_worker_target(#{@arguments}, true);
        adapter := content.document_trim_name(adapter);
        IF adapter IS NULL OR octet_length(adapter) NOT BETWEEN 1 AND 255
           OR format IS NULL OR format < 1 THEN
          RAISE EXCEPTION 'invalid Document extraction input'
            USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_input_check';
        END IF;
        IF document.state = 'pending' AND document.attempt_generation = expected_revision THEN
          IF NOT EXISTS (SELECT 1 FROM content.resources AS r
                         WHERE r.id = requested_resource AND r.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
              USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
          END IF;
          document := content.claim_document_extraction(requested_version, expected_revision,
            requested_job, adapter, format);
        ELSIF document.state = 'extracting' AND document.attempt_generation = expected_revision + 1
              AND document.attempt_job_id = requested_job THEN
          document := content.lock_document_terminal_extraction(requested_version,
            requested_job, expected_revision + 1);
          IF document.extraction_adapter IS DISTINCT FROM adapter
             OR document.extraction_format IS DISTINCT FROM format
             OR document.attempt_deadline_at <= clock_timestamp() THEN
            RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
              USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
          END IF;
        ELSE
          RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
            USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
        END IF;
        RETURN QUERY SELECT document.resource_id, document.resource_version_id, requested_job,
          document.attempt_generation, document.state, document.extraction_adapter,
          document.extraction_format, document.attempt_started_at, document.attempt_deadline_at;
      END
      """
    )
  end

  defp create_outcome(name, extras, invocation) do
    create_function(
      "#{name}_document_worker",
      extras,
      "TABLE (resource_id uuid, resource_version_id uuid, job_id uuid, generation bigint, state text)",
      """
      DECLARE document content.document_versions%ROWTYPE;
      BEGIN
        document := content.document_worker_target(#{@arguments}, true);
        IF claimed_generation IS DISTINCT FROM expected_revision + 1 THEN
          RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
            USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
        END IF;
        document := content.lock_document_terminal_extraction(requested_version,
          requested_job, claimed_generation);
        IF document.extraction_adapter IS DISTINCT FROM adapter
           OR document.extraction_format IS DISTINCT FROM format
           OR document.media_type IS DISTINCT FROM media_type
           OR (document.state = 'extracting' AND document.attempt_deadline_at <= clock_timestamp()) THEN
          RAISE EXCEPTION 'Document extraction conflicts with the current attempt'
            USING ERRCODE = '23514', CONSTRAINT = 'document_extraction_conflict_check';
        END IF;
        document := #{invocation};
        RETURN QUERY SELECT document.resource_id, document.resource_version_id,
          requested_job, document.attempt_generation, document.state;
      END
      """
    )
  end
end
