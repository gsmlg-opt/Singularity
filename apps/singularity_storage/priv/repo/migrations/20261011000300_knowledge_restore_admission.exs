defmodule Singularity.Storage.Migrations.KnowledgeRestoreAdmission do
  use Ecto.Migration

  # Frozen V3 wire projection. A released migration must not import application
  # registries or depend on caller-created temporary encoders.
  @schemas [
    {"identity.people",
     [
       {"id", 5, false},
       {"display_name", 4, false},
       {"metadata", 7, false},
       {"inserted_at", 6, false},
       {"updated_at", 6, false}
     ], [0]},
    {"identity.accounts",
     [
       {"id", 5, false},
       {"person_id", 5, false},
       {"status", 4, false},
       {"metadata", 7, false},
       {"inserted_at", 6, false},
       {"updated_at", 6, false}
     ], [0]},
    {"identity.credentials",
     [
       {"id", 5, false},
       {"account_id", 5, false},
       {"normalized_login", 4, false},
       {"revoked_at", 6, true},
       {"inserted_at", 6, false}
     ], [0]},
    {"identity.principals",
     [
       {"id", 5, false},
       {"account_id", 5, false},
       {"kind", 4, false},
       {"authorization_epoch", 2, false},
       {"revoked_at", 6, true},
       {"metadata", 7, false},
       {"inserted_at", 6, false},
       {"updated_at", 6, false}
     ], [0]},
    {"core.capabilities",
     [
       {"id", 5, false},
       {"name", 4, false},
       {"inserted_at", 6, false}
     ], [0]},
    {"core.vaults",
     [
       {"id", 5, false},
       {"kind", 4, false},
       {"authorization_epoch", 2, false},
       {"locked", 1, false},
       {"metadata", 7, false},
       {"inserted_at", 6, false},
       {"updated_at", 6, false},
       {"object_cleanup_principal_id", 5, true}
     ], [0]},
    {"core.vault_members",
     [
       {"principal_id", 5, false},
       {"vault_id", 5, false},
       {"clearance", 4, false},
       {"revoked_at", 6, true},
       {"inserted_at", 6, false},
       {"updated_at", 6, false}
     ], [0, 1]},
    {"core.principal_capabilities",
     [
       {"principal_id", 5, false},
       {"vault_id", 5, false},
       {"capability_id", 5, false},
       {"revoked_at", 6, true},
       {"inserted_at", 6, false}
     ], [0, 1, 2]},
    {"identity.devices",
     [
       {"id", 5, false},
       {"principal_id", 5, false},
       {"vault_id", 5, false},
       {"label", 4, false},
       {"revoked_at", 6, true},
       {"inserted_at", 6, false},
       {"updated_at", 6, false}
     ], [0]},
    {"core.key_domains",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"kind", 4, false},
       {"state", 4, false},
       {"inserted_at", 6, false},
       {"updated_at", 6, false}
     ], [0]},
    {"core.vault_key_versions",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"generation", 2, false},
       {"state", 4, false},
       {"algorithm", 4, false},
       {"activated_at", 6, true},
       {"retired_at", 6, true},
       {"inserted_at", 6, false}
     ], [0]},
    {"core.vault_key_wrappers",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"vault_key_version_id", 5, false},
       {"account_id", 5, false},
       {"generation", 2, false},
       {"inserted_at", 6, false}
     ], [0]},
    {"core.domain_key_versions",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"key_domain_id", 5, false},
       {"vault_key_version_id", 5, false},
       {"generation", 2, false},
       {"state", 4, false},
       {"algorithm", 4, false},
       {"wrapped_key", 3, false},
       {"inserted_at", 6, false}
     ], [0]},
    {"core.domain_dedup_key_wrappers",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"key_domain_id", 5, false},
       {"domain_key_version_id", 5, false},
       {"algorithm", 4, false},
       {"wrapped_key", 3, false},
       {"inserted_at", 6, false}
     ], [0]},
    {"content.resources",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"title", 4, false},
       {"deleted_at", 6, true},
       {"metadata", 7, false},
       {"inserted_at", 6, false},
       {"updated_at", 6, false},
       {"kind", 4, false},
       {"current_version_id", 5, true}
     ], [0]},
    {"content.resource_versions",
     [
       {"id", 5, false},
       {"resource_id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"revision", 2, false},
       {"inserted_at", 6, false},
       {"updated_at", 6, false}
     ], [0]},
    {"content.asset_objects",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"key_domain_id", 5, false},
       {"classification", 4, false},
       {"lookup_digest", 3, false},
       {"ciphertext_hash", 3, false},
       {"plaintext_byte_size", 2, false},
       {"ciphertext_byte_size", 2, false},
       {"storage_ref", 4, false},
       {"format_version", 2, false},
       {"lifecycle", 4, false},
       {"retained_until", 6, true},
       {"deleted_at", 6, true},
       {"deletion_evidence", 7, true},
       {"inserted_at", 6, false},
       {"updated_at", 6, false},
       {"lifecycle_revision", 2, false},
       {"delete_claim_token", 5, true},
       {"delete_claimed_at", 6, true}
     ], [0]},
    {"content.assets",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"resource_version_id", 5, false},
       {"asset_object_id", 5, true},
       {"classification", 4, false},
       {"state", 4, false},
       {"state_revision", 2, false},
       {"failure_code", 4, true},
       {"retryable", 1, true},
       {"failed_operation", 4, true},
       {"attempt", 2, false},
       {"inserted_at", 6, false},
       {"updated_at", 6, false}
     ], [0]},
    {"content.asset_key_envelopes",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"asset_object_id", 5, false},
       {"domain_key_version_id", 5, false},
       {"key_domain_id", 5, false},
       {"classification", 4, false},
       {"algorithm", 4, false},
       {"key_generation", 2, false},
       {"wrapped_dek", 3, false},
       {"inserted_at", 6, false}
     ], [0]},
    {"content.asset_metadata",
     [
       {"id", 5, false},
       {"asset_id", 5, false},
       {"resource_version_id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"projection_version", 2, false},
       {"original_filename", 4, false},
       {"declared_media_type", 4, false},
       {"detected_media_type", 4, true},
       {"plaintext_byte_size", 2, false},
       {"pdf_header_version", 4, true},
       {"image_width", 2, true},
       {"image_height", 2, true},
       {"extraction_state", 4, false},
       {"extractor_version", 4, true},
       {"completed_at", 6, true},
       {"inserted_at", 6, false},
       {"updated_at", 6, false}
     ], [0]},
    {"content.resource_assets",
     [
       {"resource_version_id", 5, false},
       {"asset_id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"released_at", 6, true},
       {"inserted_at", 6, false}
     ], [0, 1]},
    {"content.source_references",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"resource_version_id", 5, false},
       {"principal_id", 5, false},
       {"classification", 4, false},
       {"kind", 4, false},
       {"observed_at", 6, false},
       {"original_filename", 4, false},
       {"declared_media_type", 4, false},
       {"byte_size", 2, false},
       {"idempotency_key_digest", 3, false},
       {"inserted_at", 6, false}
     ], [0]},
    {"content.tombstones",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"asset_id", 5, false},
       {"principal_id", 5, false},
       {"classification", 4, false},
       {"reason", 4, false},
       {"retention_metadata", 7, false},
       {"deleted_at", 6, false}
     ], [0]},
    {"audit.events",
     [
       {"id", 5, false},
       {"vault_id", 5, true},
       {"actor_kind", 4, false},
       {"principal_id", 5, true},
       {"anonymous_fingerprint", 3, true},
       {"system_principal_name", 4, true},
       {"operation", 4, false},
       {"result", 4, false},
       {"classification", 4, false},
       {"correlation_id", 5, false},
       {"target_type", 4, false},
       {"target_id", 5, false},
       {"metadata", 7, false},
       {"occurred_at", 6, false},
       {"inserted_at", 6, false}
     ], [0]},
    {"core.outbox_events",
     [
       {"id", 5, false},
       {"sequence", 2, false},
       {"event_type", 4, false},
       {"idempotency_key", 4, false},
       {"vault_id", 5, false},
       {"principal_id", 5, false},
       {"required_capability", 4, false},
       {"vault_authorization_epoch", 2, false},
       {"classification", 4, false},
       {"correlation_id", 5, false},
       {"causation_id", 5, true},
       {"expected_entity_revision", 2, false},
       {"envelope_version", 2, false},
       {"payload", 7, false},
       {"occurred_at", 6, false},
       {"claim_token", 5, true},
       {"claimed_until", 6, true},
       {"runner_job_id", 4, true},
       {"delivered_at", 6, true},
       {"inserted_at", 6, false},
       {"updated_at", 6, false},
       {"principal_authorization_epoch", 2, false},
       {"retired_at", 6, true},
       {"retirement_reason", 4, true}
     ], [0]},
    {"jobs.job_submissions",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"outbox_event_id", 5, false},
       {"classification", 4, false},
       {"idempotency_key", 4, false},
       {"job_type", 4, false},
       {"runner_job_id", 4, true},
       {"inserted_at", 6, false},
       {"updated_at", 6, false}
     ], [0]},
    {"jobs.job_progress",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"submission_id", 5, false},
       {"classification", 4, false},
       {"state", 4, false},
       {"processing_revision", 2, false},
       {"checkpoint_version", 2, false},
       {"checkpoint", 7, false},
       {"inserted_at", 6, false},
       {"updated_at", 6, false}
     ], [0]},
    {"jobs.effect_receipts",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"submission_id", 5, false},
       {"classification", 4, false},
       {"effect_key", 4, false},
       {"result", 4, false},
       {"entity_revision", 2, false},
       {"inserted_at", 6, false}
     ], [0]},
    {"content.note_versions",
     [
       {"resource_version_id", 5, false},
       {"resource_id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"title", 4, false},
       {"markdown", 4, false},
       {"created_by_principal_id", 5, false},
       {"parent_version_id", 5, true},
       {"merge_parent_version_id", 5, true},
       {"inserted_at", 6, false}
     ], [0]},
    {"content.note_conflicts",
     [
       {"id", 5, false},
       {"resource_id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"base_version_id", 5, false},
       {"canonical_version_id", 5, false},
       {"competing_version_id", 5, false},
       {"state", 4, false},
       {"resolution_version_id", 5, true},
       {"created_at", 6, false},
       {"resolved_at", 6, true}
     ], [0]},
    {"content.document_versions",
     [
       {"resource_version_id", 5, false},
       {"resource_id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"source_asset_id", 5, false},
       {"source_resource_id", 5, false},
       {"source_resource_version_id", 5, false},
       {"source_object_id", 5, false},
       {"source_digest", 3, false},
       {"source_byte_size", 2, false},
       {"media_type", 4, false},
       {"title", 4, false},
       {"created_by_principal_id", 5, false},
       {"state", 4, false},
       {"attempt_generation", 2, false},
       {"extraction_adapter", 4, true},
       {"extraction_format", 2, true},
       {"extracted_text_digest", 3, true},
       {"detected_language", 4, true},
       {"failure_code", 4, true},
       {"attempt_finished_at", 6, true},
       {"inserted_at", 6, false},
       {"attempt_job_id", 5, true},
       {"attempt_started_at", 6, true},
       {"attempt_deadline_at", 6, true}
     ], [0]},
    {"content.document_fragments",
     [
       {"id", 4, false},
       {"resource_id", 5, false},
       {"resource_version_id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"ordinal", 2, false},
       {"text", 4, false},
       {"digest", 3, false},
       {"locator", 7, false},
       {"inserted_at", 6, false}
     ], [0]},
    {"content.document_import_receipts",
     [
       {"vault_id", 5, false},
       {"principal_id", 5, false},
       {"mutation_id", 5, false},
       {"request_fingerprint", 3, false},
       {"state", 4, false},
       {"resource_id", 5, true},
       {"version_id", 5, true},
       {"inserted_at", 6, false}
     ], [0, 1, 2]},
    {"content.note_attachments",
     [
       {"note_resource_version_id", 5, false},
       {"id", 5, false},
       {"note_resource_id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"target_resource_id", 5, false},
       {"target_resource_version_id", 5, false},
       {"target_kind", 4, false},
       {"ordinal", 2, false},
       {"role", 4, false},
       {"label", 4, true},
       {"inserted_at", 6, false}
     ], [0, 1]},
    {"content.note_citations",
     [
       {"note_resource_version_id", 5, false},
       {"id", 5, false},
       {"note_resource_id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"source_resource_id", 5, false},
       {"source_resource_version_id", 5, false},
       {"fragment_id", 4, false},
       {"locator", 7, false},
       {"ordinal", 2, false},
       {"inserted_at", 6, false}
     ], [0, 1]},
    {"content.tags",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"display_value", 4, false},
       {"normalized_key", 4, false},
       {"created_by_principal_id", 5, false},
       {"inserted_at", 6, false}
     ], [0]},
    {"content.resource_tags",
     [
       {"resource_id", 5, false},
       {"tag_id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"inserted_at", 6, false}
     ], [0, 1, 2]},
    {"content.relationships",
     [
       {"id", 5, false},
       {"vault_id", 5, false},
       {"classification", 4, false},
       {"source_resource_id", 5, false},
       {"target_resource_id", 5, false},
       {"target_resource_version_id", 5, true},
       {"type", 4, false},
       {"created_by_principal_id", 5, false},
       {"inserted_at", 6, false}
     ], [0]}
  ]
  @scalar_checks [
    {"identity.accounts", "status IN ('active','disabled')"},
    {"identity.credentials",
     "normalized_login=lower(btrim(normalized_login)) AND normalized_login<>''"},
    {"identity.principals", "kind IN ('owner','system') AND authorization_epoch>=0"},
    {"core.vaults", "kind IN ('personal','system') AND authorization_epoch>=0"},
    {"core.capabilities", "btrim(name)<>''"},
    {"core.vault_members", "clearance IN ('private','sensitive','restricted')"},
    {"core.key_domains", "state IN ('active','retired')"},
    {"core.vault_key_versions",
     "generation>0 AND state IN ('pending','active','retired') AND algorithm='aes_256_gcm'"},
    {"core.vault_key_wrappers", "generation>0"},
    {"core.domain_key_versions",
     "generation>0 AND state IN ('pending','active','retired') AND algorithm='aes_256_gcm' AND octet_length(wrapped_key)>0"},
    {"core.domain_dedup_key_wrappers", "algorithm='aes_256_gcm' AND octet_length(wrapped_key)>0"},
    {"content.resources",
     "kind IN ('asset','note','document') AND btrim(title)<>'' AND (kind='asset' OR (classification='private' AND current_version_id IS NOT NULL))"},
    {"content.resource_versions", "revision>=0"},
    {"content.assets",
     "state IN ('staging','uploaded','verified','available','processing','ready','pending_delete','deleted') AND state_revision>=0 AND attempt>=0 AND ((failure_code IS NULL AND retryable IS NULL AND failed_operation IS NULL) OR (failure_code IS NOT NULL AND retryable IS NOT NULL AND failed_operation IS NOT NULL))"},
    {"content.asset_objects",
     "octet_length(lookup_digest)=32 AND octet_length(ciphertext_hash)=32 AND plaintext_byte_size>=0 AND ciphertext_byte_size>=0 AND format_version=1 AND lifecycle_revision>=0 AND lifecycle IN ('staged','available','pending_delete','orphan_pending','deleting','deleted')"},
    {"content.asset_objects",
     "((lifecycle='deleting' AND delete_claim_token IS NOT NULL AND delete_claimed_at IS NOT NULL) OR (lifecycle<>'deleting' AND delete_claim_token IS NULL AND delete_claimed_at IS NULL)) AND ((lifecycle IN ('orphan_pending','deleting') AND retained_until IS NOT NULL AND deleted_at IS NULL AND deletion_evidence IS NULL) OR (lifecycle='deleted' AND deleted_at IS NOT NULL AND jsonb_typeof(deletion_evidence)='object') OR (lifecycle NOT IN ('orphan_pending','deleting','deleted') AND deleted_at IS NULL AND deletion_evidence IS NULL))"},
    {"content.asset_key_envelopes",
     "algorithm='aes_256_gcm' AND key_generation>0 AND octet_length(wrapped_dek)>0"},
    {"content.asset_metadata",
     "projection_version>0 AND plaintext_byte_size>=0 AND extraction_state IN ('pending','completed','failed') AND ((image_width IS NULL AND image_height IS NULL) OR (image_width>0 AND image_height>0))"},
    {"content.source_references",
     "kind='browser_upload' AND byte_size>=0 AND octet_length(idempotency_key_digest)=32"},
    {"content.note_versions",
     "classification='private' AND btrim(title)<>'' AND octet_length(title)<=255 AND octet_length(markdown)<=1048576 AND (parent_version_id IS NOT NULL OR merge_parent_version_id IS NULL) AND (merge_parent_version_id IS NULL OR merge_parent_version_id<>parent_version_id)"},
    {"content.note_conflicts",
     "classification='private' AND base_version_id<>canonical_version_id AND base_version_id<>competing_version_id AND canonical_version_id<>competing_version_id AND ((state='open' AND resolution_version_id IS NULL AND resolved_at IS NULL) OR (state='resolved' AND resolution_version_id IS NOT NULL AND resolved_at IS NOT NULL AND resolution_version_id NOT IN (base_version_id,canonical_version_id,competing_version_id)))"},
    {"content.document_versions",
     "classification='private' AND octet_length(source_digest)=32 AND source_byte_size BETWEEN 0 AND 67108864 AND media_type IN ('application/pdf','text/plain','text/markdown') AND btrim(title)<>'' AND octet_length(title)<=255 AND attempt_generation>=0 AND (extraction_format IS NULL OR extraction_format>0) AND (extracted_text_digest IS NULL OR octet_length(extracted_text_digest)=32)"},
    {"content.document_versions",
     "(extraction_format IS NULL OR extraction_format=1) AND (extraction_adapter IS NULL OR (octet_length(extraction_adapter) BETWEEN 1 AND 255 AND content.document_trim_name(extraction_adapter)=extraction_adapter)) AND (detected_language IS NULL OR (octet_length(detected_language)<=255 AND content.document_trim_name(detected_language)<>'')) AND (failure_code IS NULL OR failure_code IN ('invalid_utf8','malformed_document','encrypted_document','no_extractable_text','input_too_large','output_too_large','page_limit','timeout','extractor_failed'))"},
    {"content.document_fragments",
     "classification='private' AND ordinal>=0 AND octet_length(text)<=65536 AND position(chr(13) in text)=0 AND octet_length(digest)=32"},
    {"content.document_import_receipts",
     "state='completed' AND resource_id IS NOT NULL AND version_id IS NOT NULL AND octet_length(request_fingerprint)=32"},
    {"content.note_attachments",
     "classification='private' AND ordinal>=0 AND role='source' AND target_kind IN ('asset','document','note') AND note_resource_id<>target_resource_id AND (label IS NULL OR octet_length(label)<=255)"},
    {"content.note_citations",
     "classification='private' AND ordinal>=0 AND note_resource_id<>source_resource_id"},
    {"content.tags", "classification='private'"},
    {"content.resource_tags", "classification='private'"},
    {"content.relationships",
     "classification='private' AND source_resource_id<>target_resource_id AND type IN ('related_to','references','derived_from')"},
    {"core.outbox_events",
     "sequence>=0 AND principal_authorization_epoch>=0 AND vault_authorization_epoch>=0 AND expected_entity_revision>=0 AND envelope_version=1 AND jsonb_typeof(payload)='object'"},
    {"jobs.job_submissions",
     "job_type IN ('asset_finalize','asset_verify','asset_metadata','asset_cleanup','object_cleanup','note_projection','document_extract','document_projection','backup')"},
    {"jobs.job_progress",
     "state IN ('pending','running','waiting_for_unlock','waiting_for_backup_key','completed','failed') AND processing_revision>=0 AND checkpoint_version>0 AND jsonb_typeof(checkpoint)='object'"},
    {"jobs.effect_receipts", "result IN ('applied','stale','failed') AND entity_revision>=0"}
  ]
  @excluded ~w(identity.sessions identity.auth_attempts content.asset_stages
    content.upload_grants content.asset_search_documents content.note_search_documents
    content.search_entries content.note_mutation_receipts audit.backup_manifests
    audit.backup_manifest_objects jobs.oban_jobs jobs.oban_peers)
  @runtime_roles "PUBLIC,singularity_web,singularity_worker,singularity_dispatcher,singularity_pre_auth"
  @signatures [
    "knowledge_restore_json_bytes(jsonb)",
    "knowledge_restore_table_digest(integer)",
    "knowledge_restore_vectors_valid(bigint[],bytea[])",
    "knowledge_restore_lock_is_held()",
    "knowledge_restore_integer_text(text,bigint)",
    "knowledge_restore_payload_is_valid(core.outbox_events)",
    "assert_knowledge_restore_graph(uuid)",
    "assert_knowledge_restore_destination(audit.knowledge_restore_admissions)",
    "enforce_knowledge_restore_admission()",
    "begin_knowledge_restore(uuid,uuid,bytea,bigint[],bytea[])",
    "validate_knowledge_restore(uuid,uuid,bytea)",
    "knowledge_restore_is_bound(uuid)",
    "enforce_knowledge_restore_final()"
  ]

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")
    create_vectors()
    create_admission()
    create_lock_predicate()
    create_json_encoder()
    create_table_digest()
    create_payload_validator()
    create_graph_validator()
    create_destination_validator()
    create_binding()
    create_entrypoints()
    create_guards()

    for signature <- @signatures do
      execute("REVOKE ALL ON FUNCTION audit.#{signature} FROM #{@runtime_roles}")
    end

    execute("SET LOCAL ROLE NONE")
  end

  def down,
    do: raise(Ecto.MigrationError, "knowledge restore admission is forward-only")

  defp create_vectors do
    execute("""
    CREATE FUNCTION audit.knowledge_restore_vectors_valid(counts bigint[],digests bytea[])
    RETURNS boolean LANGUAGE sql IMMUTABLE SECURITY INVOKER SET search_path=pg_catalog
    AS $function$
      SELECT (
        pg_catalog.array_ndims(counts)=1 AND pg_catalog.array_lower(counts,1)=1
        AND pg_catalog.cardinality(counts)=38
        AND pg_catalog.array_position(counts,NULL) IS NULL AND 0<=ALL(counts)
        AND pg_catalog.array_ndims(digests)=1 AND pg_catalog.array_lower(digests,1)=1
        AND pg_catalog.cardinality(digests)=38
        AND pg_catalog.array_position(digests,NULL) IS NULL
        AND NOT EXISTS(SELECT 1 FROM pg_catalog.unnest(digests) AS d(value)
          WHERE pg_catalog.octet_length(value) IS DISTINCT FROM 32)
      ) IS TRUE
    $function$
    """)
  end

  defp create_admission do
    execute("""
    CREATE TABLE audit.knowledge_restore_admissions (
      singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
      manifest_id uuid NOT NULL,
      vault_id uuid NOT NULL,
      manifest_hash bytea NOT NULL CHECK(pg_catalog.octet_length(manifest_hash)=32),
      transaction_id xid8 NOT NULL,
      backend_pid integer NOT NULL CHECK(backend_pid>0),
      expected_counts bigint[] NOT NULL,
      expected_digests bytea[] NOT NULL,
      state text NOT NULL CHECK(state IN ('loading','validated')),
      manifest_tag bytea NOT NULL CHECK(pg_catalog.octet_length(manifest_tag)=16),
      inventory_hash bytea NOT NULL CHECK(pg_catalog.octet_length(inventory_hash)=32),
      destination_root_hash bytea NOT NULL CHECK(pg_catalog.octet_length(destination_root_hash)=32),
      object_count bigint NOT NULL CHECK(object_count>=0),
      CONSTRAINT knowledge_restore_vectors_check
        CHECK(audit.knowledge_restore_vectors_valid(expected_counts,expected_digests))
    )
    """)

    execute("ALTER TABLE audit.knowledge_restore_admissions ENABLE ROW LEVEL SECURITY")
    execute("ALTER TABLE audit.knowledge_restore_admissions FORCE ROW LEVEL SECURITY")

    execute("""
    CREATE POLICY knowledge_restore_admissions_table_owner
    ON audit.knowledge_restore_admissions FOR ALL TO singularity_table_owner
    USING(true) WITH CHECK(true)
    """)

    execute("REVOKE ALL ON audit.knowledge_restore_admissions FROM #{@runtime_roles}")
  end

  defp authority_sql do
    """
    IF session_user<>'singularity_migration'
      OR current_user<>'singularity_table_owner'
      OR NOT pg_catalog.pg_has_role(session_user,'singularity_table_owner','SET') THEN
      RAISE EXCEPTION 'knowledge restore authority unavailable' USING ERRCODE='42501';
    END IF;
    """
  end

  defp create_lock_predicate do
    execute("""
    CREATE FUNCTION audit.knowledge_restore_lock_is_held() RETURNS boolean
    LANGUAGE sql VOLATILE SECURITY INVOKER SET search_path=pg_catalog
    AS $function$
      SELECT EXISTS(
        SELECT 1 FROM pg_catalog.pg_locks l
        WHERE l.locktype='advisory' AND l.pid=pg_catalog.pg_backend_pid()
          AND l.granted AND l.mode='ExclusiveLock'
          AND l.database=(SELECT oid FROM pg_catalog.pg_database
            WHERE datname=pg_catalog.current_database())
          AND l.classid=((pg_catalog.hashtextextended('singularity:restore-import:v1',0)>>32)
            & 4294967295::bigint)::oid
          AND l.objid=(pg_catalog.hashtextextended('singularity:restore-import:v1',0)
            & 4294967295::bigint)::oid
          AND l.objsubid=1
      )
    $function$
    """)
  end

  defp create_json_encoder do
    execute("""
    CREATE FUNCTION audit.knowledge_restore_json_bytes(value jsonb) RETURNS bytea
    LANGUAGE plpgsql IMMUTABLE STRICT SECURITY INVOKER SET search_path=pg_catalog
    AS $function$
    DECLARE kind text; result bytea; bytes bytea; item record;
    BEGIN
      kind:=pg_catalog.jsonb_typeof(value);
      CASE kind
      WHEN 'null' THEN RETURN pg_catalog.decode('00','hex');
      WHEN 'boolean' THEN
        IF value='true'::jsonb THEN RETURN pg_catalog.decode('02','hex'); END IF;
        RETURN pg_catalog.decode('01','hex');
      WHEN 'number' THEN
        bytes:=pg_catalog.convert_to(pg_catalog.trim_scale((value #>> '{}')::numeric)::text,'UTF8');
        RETURN pg_catalog.decode('03','hex')||pg_catalog.int8send(pg_catalog.octet_length(bytes)::bigint)||bytes;
      WHEN 'string' THEN
        bytes:=pg_catalog.convert_to(value #>> '{}','UTF8');
        RETURN pg_catalog.decode('04','hex')||pg_catalog.int8send(pg_catalog.octet_length(bytes)::bigint)||bytes;
      WHEN 'array' THEN
        result:=pg_catalog.decode('05','hex')||pg_catalog.int8send(pg_catalog.jsonb_array_length(value)::bigint);
        FOR item IN SELECT element FROM pg_catalog.jsonb_array_elements(value) AS entries(element)
        LOOP
          bytes:=audit.knowledge_restore_json_bytes(item.element);
          result:=result||pg_catalog.int8send(pg_catalog.octet_length(bytes)::bigint)||bytes;
        END LOOP;
        RETURN result;
      WHEN 'object' THEN
        result:=pg_catalog.decode('06','hex')||
          pg_catalog.int8send((SELECT count(*) FROM pg_catalog.jsonb_each(value)));
        FOR item IN SELECT key,element FROM pg_catalog.jsonb_each(value) AS entries(key,element)
          ORDER BY pg_catalog.convert_to(key,'UTF8')
        LOOP
          bytes:=pg_catalog.convert_to(item.key,'UTF8');
          result:=result||pg_catalog.int8send(pg_catalog.octet_length(bytes)::bigint)||bytes;
          bytes:=audit.knowledge_restore_json_bytes(item.element);
          result:=result||pg_catalog.int8send(pg_catalog.octet_length(bytes)::bigint)||bytes;
        END LOOP;
        RETURN result;
      ELSE
        RAISE EXCEPTION 'invalid knowledge restore JSON' USING ERRCODE='23514';
      END CASE;
    END
    $function$
    """)
  end

  defp create_table_digest do
    branches =
      @schemas
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{table, columns, keys}, ordinal} ->
        projection =
          IO.iodata_to_binary([
            <<length(columns)::unsigned-big-64>>,
            Enum.map(columns, fn {name, tag, nullable} ->
              [frame(name), <<tag>>, if(nullable, do: <<1>>, else: <<0>>)]
            end),
            <<length(keys)::unsigned-big-64>>,
            Enum.map(keys, &<<&1::unsigned-big-64>>)
          ])

        encoded =
          Enum.map_join(columns, "||", fn {name, tag, _nullable} ->
            cell_sql(tag, "source." <> quote_name(name))
          end)

        order =
          Enum.map_join(keys, ",", fn position ->
            {name, tag, _nullable} = Enum.fetch!(columns, position)
            column = "source." <> quote_name(name)
            if tag == 4, do: "pg_catalog.convert_to(#{column},'UTF8')", else: column
          end)

        """
        WHEN #{ordinal} THEN
          table_name:='#{table}';
          projection:=pg_catalog.decode('#{Base.encode16(projection, case: :lower)}','hex');
          OPEN rows FOR SELECT pg_catalog.int8send(#{length(columns)}::bigint)||#{encoded}
            FROM #{table} AS source ORDER BY #{order};
        """
      end)

    execute("""
    CREATE FUNCTION audit.knowledge_restore_table_digest(ordinal integer)
    RETURNS TABLE(row_count bigint,digest bytea)
    LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path=pg_catalog
    AS $function$
    DECLARE table_name text; projection bytea; rows refcursor; encoded bytea; domain bytea;
    BEGIN
      CASE ordinal
      #{branches}
      ELSE RAISE EXCEPTION 'invalid knowledge restore ordinal' USING ERRCODE='23514';
      END CASE;
      domain:=pg_catalog.convert_to('singularity:knowledge-restore-digest:v1','UTF8');
      digest:=pg_catalog.sha256(pg_catalog.decode('00','hex')||
        pg_catalog.int8send(pg_catalog.octet_length(domain)::bigint)||domain||
        pg_catalog.int8send(3::bigint)||
        pg_catalog.int8send(pg_catalog.octet_length(pg_catalog.convert_to(table_name,'UTF8'))::bigint)||
        pg_catalog.convert_to(table_name,'UTF8')||
        pg_catalog.int8send(pg_catalog.octet_length(projection)::bigint)||projection);
      row_count:=0;
      LOOP
        FETCH rows INTO encoded;
        EXIT WHEN NOT FOUND;
        digest:=pg_catalog.sha256(pg_catalog.decode('01','hex')||digest||
          pg_catalog.int8send(pg_catalog.octet_length(encoded)::bigint)||encoded);
        row_count:=row_count+1;
      END LOOP;
      CLOSE rows;
      digest:=pg_catalog.sha256(pg_catalog.decode('02','hex')||digest||pg_catalog.int8send(row_count));
      RETURN NEXT;
    END
    $function$
    """)
  end

  defp cell_sql(tag, column) do
    payload =
      case tag do
        1 -> "pg_catalog.decode(CASE WHEN #{column} THEN '01' ELSE '00' END,'hex')"
        2 -> "pg_catalog.int8send(#{column}::bigint)"
        3 -> column
        4 -> "pg_catalog.convert_to(#{column},'UTF8')"
        5 -> "pg_catalog.uuid_send(#{column})"
        6 -> "pg_catalog.int8send((extract(epoch FROM #{column})*1000000)::bigint)"
        7 -> "audit.knowledge_restore_json_bytes(#{column})"
      end

    hex = tag |> Integer.to_string(16) |> String.pad_leading(2, "0")

    "pg_catalog.decode('#{hex}','hex')||CASE WHEN #{column} IS NULL " <>
      "THEN pg_catalog.decode('000000000000000000','hex') ELSE pg_catalog.decode('01','hex')||" <>
      "pg_catalog.int8send(pg_catalog.octet_length(#{payload})::bigint)||#{payload} END"
  end

  defp frame(value), do: [<<byte_size(value)::unsigned-big-64>>, value]
  defp quote_name(value), do: "\"" <> value <> "\""

  defp empty_destination_sql do
    tables = Enum.map(@schemas, &elem(&1, 0)) ++ @excluded ++ ["content.note_source_set_seals"]

    locks = "LOCK TABLE " <> Enum.join(Enum.sort(tables), ",") <> " IN ACCESS EXCLUSIVE MODE;"
    checks = Enum.map_join(tables, " OR ", &"EXISTS(SELECT 1 FROM #{&1})")

    locks <>
      """
      IF #{checks} THEN
        RAISE EXCEPTION 'knowledge restore destination is not empty' USING ERRCODE='23514';
      END IF;
      """
  end

  defp saga_match_sql(admission, saga) do
    Enum.map_join(
      ~w(manifest_id vault_id manifest_hash manifest_tag inventory_hash destination_root_hash object_count),
      " AND ",
      &"#{admission}.#{&1}=#{saga}.#{&1}"
    )
  end

  defp create_payload_validator do
    execute("""
    CREATE FUNCTION audit.knowledge_restore_integer_text(value text,expected bigint)
    RETURNS boolean LANGUAGE plpgsql IMMUTABLE SECURITY INVOKER SET search_path=pg_catalog
    AS $function$
    DECLARE digits text; negative boolean;
    BEGIN
      IF value IS NULL OR expected IS NULL OR value !~ '^[+-]?[0-9]+$' THEN RETURN false; END IF;
      negative:=pg_catalog.left(value,1)='-';
      digits:=pg_catalog.regexp_replace(value,'^[+-]?0*','');
      IF digits='' THEN digits:='0'; END IF;
      IF pg_catalog.length(digits)>19 THEN RETURN false; END IF;
      RETURN (CASE WHEN negative THEN -digits::numeric ELSE digits::numeric END)=expected::numeric;
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION audit.knowledge_restore_payload_is_valid(e core.outbox_events)
    RETURNS boolean LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=pg_catalog
    AS $function$
    DECLARE asset_id text; object_id text; resource_id text; version_id text;
      prefix text; capability text; parts text[]; revision bigint:=e.expected_entity_revision;
      conflict_event boolean; valid_key boolean;
    BEGIN
      IF e.envelope_version<>1 OR revision<0 OR e.principal_authorization_epoch<0
        OR e.vault_authorization_epoch<0 OR pg_catalog.jsonb_typeof(e.payload) IS DISTINCT FROM 'object' THEN
        RETURN false;
      END IF;
      CASE e.event_type
      WHEN 'asset.finalize_requested' THEN prefix:='asset-finalize'; capability:='asset.write';
      WHEN 'asset.verify_requested' THEN prefix:='asset-verify'; capability:='asset.write';
      WHEN 'asset.metadata_requested' THEN prefix:='asset-metadata'; capability:='asset.read';
      WHEN 'asset.cleanup_requested' THEN prefix:='asset-cleanup'; capability:='asset.write';
      WHEN 'object.cleanup_requested' THEN
        asset_id:=e.payload->>'asset_id'; object_id:=e.payload->>'object_id';
        RETURN e.payload=pg_catalog.jsonb_build_object('asset_id',asset_id,'object_id',object_id)
          AND e.required_capability='object.cleanup'
          AND EXISTS(SELECT 1 FROM content.assets a WHERE a.id::text=asset_id
            AND (a.vault_id,a.classification)=(e.vault_id,e.classification))
          AND EXISTS(SELECT 1 FROM content.asset_objects o WHERE o.id::text=object_id
            AND (o.vault_id,o.classification)=(e.vault_id,e.classification))
          AND e.idempotency_key IN (
            'object-cleanup:'||object_id||':'||revision::text,
            'object-cleanup:'||object_id||':authority:'||e.principal_authorization_epoch::text||
              ':'||e.vault_authorization_epoch::text||':revision:'||revision::text);
      WHEN 'backup.requested' THEN
        version_id:=e.payload->>'pending_manifest_id';
        RETURN e.required_capability='backup.create'
          AND version_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          AND e.payload=pg_catalog.jsonb_build_object('pending_manifest_id',version_id)
          AND e.idempotency_key='backup:'||version_id;
      WHEN 'document.extraction_requested' THEN
        resource_id:=e.payload->>'resource_id'; version_id:=e.payload->>'resource_version_id';
        RETURN e.required_capability='asset.read' AND e.classification='private'
          AND e.payload=pg_catalog.jsonb_build_object('resource_id',resource_id,'resource_version_id',version_id)
          AND EXISTS(SELECT 1 FROM content.document_versions d WHERE d.resource_id::text=resource_id
            AND d.resource_version_id::text=version_id AND (d.vault_id,d.classification)=(e.vault_id,e.classification)
            AND revision<=d.attempt_generation)
          AND e.idempotency_key=CASE WHEN revision=0 THEN 'document-extraction:'||version_id
            ELSE 'document-extraction:'||version_id||':'||revision::text END;
      WHEN 'document.ready','document.deleted','document.restored' THEN
        resource_id:=e.payload->>'resource_id'; version_id:=e.payload->>'resource_version_id';
        RETURN e.required_capability='asset.read' AND e.classification='private'
          AND e.payload=pg_catalog.jsonb_build_object('resource_id',resource_id,'resource_version_id',version_id)
          AND EXISTS(SELECT 1 FROM content.document_versions d WHERE d.resource_id::text=resource_id
            AND d.resource_version_id::text=version_id AND (d.vault_id,d.classification)=(e.vault_id,e.classification))
          AND e.idempotency_key='document-projection:'||e.id::text;
      WHEN 'note.current_changed','note.conflict_created','note.conflict_resolved','note.deleted','note.restored' THEN
        resource_id:=e.payload->>'resource_id';
        conflict_event:=e.event_type IN ('note.conflict_created','note.conflict_resolved');
        IF e.required_capability<>'note.write' OR e.classification<>'private'
          OR NOT EXISTS(SELECT 1 FROM content.resources r WHERE r.id::text=resource_id
            AND (r.vault_id,r.classification,r.kind)=(e.vault_id,'private','note')) THEN RETURN false; END IF;
        IF conflict_event THEN
          IF e.payload<>pg_catalog.jsonb_build_object('resource_id',resource_id,'conflict_id',e.payload->>'conflict_id')
            OR NOT EXISTS(SELECT 1 FROM content.note_conflicts c WHERE c.id::text=e.payload->>'conflict_id'
              AND c.resource_id::text=resource_id AND c.vault_id=e.vault_id) THEN RETURN false; END IF;
        ELSIF e.payload<>pg_catalog.jsonb_build_object('resource_id',resource_id) THEN RETURN false;
        END IF;
        parts:=pg_catalog.string_to_array(e.idempotency_key,':');
        IF pg_catalog.cardinality(parts)<>3 OR parts[2] IS DISTINCT FROM resource_id THEN RETURN false; END IF;
        IF parts[1] IN ('note-current-changed','note-conflict-created','note-conflict-resolved') THEN
          RETURN audit.knowledge_restore_integer_text(parts[3],revision);
        END IF;
        RETURN parts[1] IN ('note-deleted','note-restored')
          AND parts[3] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
      ELSE RETURN false;
      END CASE;
      asset_id:=e.payload->>'asset_id';
      IF e.payload IS DISTINCT FROM pg_catalog.jsonb_build_object('asset_id',asset_id)
        OR NOT EXISTS(SELECT 1 FROM content.assets a WHERE a.id::text=asset_id
          AND (a.vault_id,a.classification)=(e.vault_id,e.classification)) THEN RETURN false; END IF;
      IF e.event_type='asset.verify_requested' AND e.required_capability='assets.verify'
        AND e.idempotency_key='sealed-upload:'||asset_id THEN RETURN true; END IF;
      IF e.required_capability<>capability THEN RETURN false; END IF;
      valid_key:=e.idempotency_key=prefix||':'||asset_id||':'||revision::text;
      IF NOT valid_key AND e.event_type<>'asset.metadata_requested' THEN
        parts:=pg_catalog.string_to_array(e.idempotency_key,':');
        IF pg_catalog.cardinality(parts)=4 AND parts[1]='asset-retry' AND parts[2]=asset_id
          AND audit.knowledge_restore_integer_text(parts[3],revision)
          AND parts[4] ~ '^[+]?[0-9]+$' THEN
          -- Canonical positive integer text, without a bounded numeric cast.
          valid_key:=pg_catalog.regexp_replace(parts[4],'^[+]?0*','')<>'';
        END IF;
      END IF;
      RETURN valid_key;
    END
    $function$
    """)
  end

  defp create_graph_validator do
    scoped =
      Enum.flat_map(@schemas, fn {table, columns, _keys} ->
        checks =
          if Enum.any?(columns, &(elem(&1, 0) == "vault_id")) do
            ["EXISTS(SELECT 1 FROM #{table} WHERE vault_id IS NOT NULL AND vault_id<>owner_id)"]
          else
            []
          end

        if Enum.any?(columns, &(elem(&1, 0) == "classification")) do
          checks ++
            [
              "EXISTS(SELECT 1 FROM #{table} WHERE classification NOT IN ('private','sensitive','restricted'))"
            ]
        else
          checks
        end
      end)

    references =
      [
        {"identity.accounts", ["person_id"], "identity.people", ["id"]},
        {"identity.credentials", ["account_id"], "identity.accounts", ["id"]},
        {"identity.principals", ["account_id"], "identity.accounts", ["id"]},
        {"core.vaults", ["object_cleanup_principal_id"], "identity.principals", ["id"]},
        {"core.principal_capabilities", ["capability_id"], "core.capabilities", ["id"]},
        {"core.vault_key_wrappers", ["account_id"], "identity.accounts", ["id"]},
        {"audit.events", ["principal_id"], "identity.principals", ["id"]}
      ] ++
        Enum.map(
          ~w(core.vault_members core.principal_capabilities identity.devices),
          &{&1, ["principal_id"], "identity.principals", ["id"]}
        ) ++
        Enum.flat_map(@schemas, fn {table, columns, _keys} ->
          if Enum.any?(columns, &(elem(&1, 0) == "vault_id")),
            do: [{table, ["vault_id"], "core.vaults", ["id"]}],
            else: []
        end) ++
        Enum.map(
          ~w(core.principal_capabilities identity.devices content.source_references content.tombstones core.outbox_events content.document_import_receipts),
          &{&1, ["principal_id", "vault_id"], "core.vault_members", ["principal_id", "vault_id"]}
        ) ++
        Enum.map(
          ~w(content.note_versions content.document_versions content.tags content.relationships),
          &{&1, ["created_by_principal_id", "vault_id"], "core.vault_members",
           ["principal_id", "vault_id"]}
        ) ++
        Enum.map(
          [
            {"core.vault_key_wrappers", "vault_key_version_id", "core.vault_key_versions"},
            {"core.domain_key_versions", "vault_key_version_id", "core.vault_key_versions"},
            {"core.domain_key_versions", "key_domain_id", "core.key_domains"},
            {"core.domain_dedup_key_wrappers", "key_domain_id", "core.key_domains"},
            {"core.domain_dedup_key_wrappers", "domain_key_version_id",
             "core.domain_key_versions"},
            {"content.asset_key_envelopes", "domain_key_version_id", "core.domain_key_versions"},
            {"jobs.job_submissions", "outbox_event_id", "core.outbox_events"},
            {"jobs.job_progress", "submission_id", "jobs.job_submissions"},
            {"jobs.effect_receipts", "submission_id", "jobs.job_submissions"}
          ],
          fn {from, key, target} -> {from, [key, "vault_id"], target, ["id", "vault_id"]} end
        ) ++
        Enum.map(
          ~w(jobs.job_progress jobs.effect_receipts),
          &{&1, ["submission_id", "vault_id", "classification"], "jobs.job_submissions",
           ["id", "vault_id", "classification"]}
        ) ++
        Enum.map(
          [
            {"content.resource_versions", "resource_id", "content.resources"},
            {"content.asset_objects", "key_domain_id", "core.key_domains"},
            {"content.assets", "resource_version_id", "content.resource_versions"},
            {"content.assets", "asset_object_id", "content.asset_objects"},
            {"content.asset_key_envelopes", "asset_object_id", "content.asset_objects"},
            {"content.asset_key_envelopes", "key_domain_id", "core.key_domains"},
            {"content.asset_metadata", "asset_id", "content.assets"},
            {"content.asset_metadata", "resource_version_id", "content.resource_versions"},
            {"content.resource_assets", "asset_id", "content.assets"},
            {"content.resource_assets", "resource_version_id", "content.resource_versions"},
            {"content.source_references", "resource_version_id", "content.resource_versions"},
            {"content.tombstones", "asset_id", "content.assets"},
            {"content.document_versions", "source_asset_id", "content.assets"},
            {"content.document_versions", "source_resource_id", "content.resources"},
            {"content.document_versions", "source_resource_version_id",
             "content.resource_versions"},
            {"content.document_versions", "source_object_id", "content.asset_objects"},
            {"content.resource_tags", "resource_id", "content.resources"},
            {"content.resource_tags", "tag_id", "content.tags"},
            {"content.relationships", "source_resource_id", "content.resources"},
            {"content.relationships", "target_resource_id", "content.resources"}
          ],
          fn {from, key, target} ->
            {from, [key, "vault_id", "classification"], target,
             ["id", "vault_id", "classification"]}
          end
        ) ++
        Enum.map(
          ~w(content.note_versions content.document_versions),
          &{&1, ["resource_version_id", "resource_id", "vault_id", "classification"],
           "content.resource_versions", ["id", "resource_id", "vault_id", "classification"]}
        ) ++
        Enum.map(
          ~w(parent_version_id merge_parent_version_id),
          &{"content.note_versions", [&1, "resource_id", "vault_id", "classification"],
           "content.note_versions",
           ["resource_version_id", "resource_id", "vault_id", "classification"]}
        ) ++
        Enum.map(
          ~w(base_version_id canonical_version_id competing_version_id resolution_version_id),
          &{"content.note_conflicts", [&1, "resource_id", "vault_id", "classification"],
           "content.note_versions",
           ["resource_version_id", "resource_id", "vault_id", "classification"]}
        ) ++
        [
          {"content.resources", ["current_version_id", "id", "vault_id", "classification"],
           "content.resource_versions", ["id", "resource_id", "vault_id", "classification"]},
          {"content.document_fragments",
           ["resource_version_id", "resource_id", "vault_id", "classification"],
           "content.document_versions",
           ["resource_version_id", "resource_id", "vault_id", "classification"]},
          {"content.document_import_receipts", ["version_id", "resource_id", "vault_id"],
           "content.document_versions", ["resource_version_id", "resource_id", "vault_id"]},
          {"content.note_attachments",
           ["note_resource_version_id", "note_resource_id", "vault_id", "classification"],
           "content.note_versions",
           ["resource_version_id", "resource_id", "vault_id", "classification"]},
          {"content.note_citations",
           ["note_resource_version_id", "note_resource_id", "vault_id", "classification"],
           "content.note_versions",
           ["resource_version_id", "resource_id", "vault_id", "classification"]},
          {"content.note_attachments",
           ["target_resource_version_id", "target_resource_id", "vault_id", "classification"],
           "content.resource_versions", ["id", "resource_id", "vault_id", "classification"]},
          {"content.note_citations",
           [
             "fragment_id",
             "source_resource_version_id",
             "source_resource_id",
             "vault_id",
             "classification"
           ], "content.document_fragments",
           ["id", "resource_version_id", "resource_id", "vault_id", "classification"]},
          {"content.relationships",
           ["target_resource_version_id", "target_resource_id", "vault_id", "classification"],
           "content.resource_versions", ["id", "resource_id", "vault_id", "classification"]}
        ]

    joined =
      Enum.map(references, fn {from, keys, target, target_keys} ->
        equality =
          Enum.zip(keys, target_keys)
          |> Enum.map_join(" AND ", fn {key, target_key} ->
            "s.#{quote_name(key)}=t.#{quote_name(target_key)}"
          end)

        "EXISTS(SELECT 1 FROM #{from} s WHERE s.#{quote_name(hd(keys))} IS NOT NULL " <>
          "AND NOT EXISTS(SELECT 1 FROM #{target} t WHERE #{equality}))"
      end)

    excluded = Enum.map(@excluded, &"EXISTS(SELECT 1 FROM #{&1})")

    scalar =
      Enum.map(@scalar_checks, fn {table, predicate} ->
        "EXISTS(SELECT 1 FROM #{table} WHERE (#{predicate}) IS NOT TRUE)"
      end)

    execute("""
    CREATE FUNCTION audit.assert_knowledge_restore_graph(owner_id uuid) RETURNS void
    LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path=pg_catalog
    AS $function$
    DECLARE document record; fragment record; bytes bytea; amount bigint; size bigint;
    BEGIN
      IF owner_id IS NULL OR (SELECT count(*) FROM core.vaults)<>1
        OR NOT EXISTS(SELECT 1 FROM core.vaults WHERE id=owner_id AND locked)
        OR #{Enum.join(scoped ++ joined ++ excluded ++ scalar, " OR ")} THEN
        RAISE EXCEPTION 'invalid knowledge restore graph' USING ERRCODE='23514';
      END IF;
      IF (SELECT count(*) FROM identity.accounts)<>1 OR (SELECT count(*) FROM identity.people)<>1
        OR (SELECT count(*) FROM core.vault_key_wrappers)<>1
        OR NOT EXISTS(SELECT 1 FROM identity.accounts a JOIN identity.principals p ON p.account_id=a.id
          JOIN core.vault_members m ON m.principal_id=p.id
          WHERE a.status='active' AND p.kind='owner' AND p.revoked_at IS NULL
            AND m.vault_id=owner_id AND m.revoked_at IS NULL
            AND EXISTS(SELECT 1 FROM identity.credentials c WHERE c.account_id=a.id AND c.revoked_at IS NULL))
        OR EXISTS(SELECT 1 FROM identity.principals p WHERE p.kind='owner' AND p.revoked_at IS NULL
          AND NOT EXISTS(SELECT 1 FROM core.vault_members m WHERE m.principal_id=p.id AND m.revoked_at IS NULL))
        OR NOT EXISTS(SELECT 1 FROM core.vault_key_versions k JOIN core.vault_key_wrappers w
          ON (w.vault_key_version_id,w.vault_id,w.generation)=(k.id,k.vault_id,k.generation)
          WHERE k.vault_id=owner_id AND k.state='active')
        OR EXISTS(SELECT 1 FROM core.vaults v WHERE v.object_cleanup_principal_id IS NOT NULL
          AND NOT EXISTS(SELECT 1 FROM identity.principals p
            JOIN core.vault_members m ON m.principal_id=p.id
            JOIN core.principal_capabilities g ON (g.principal_id,g.vault_id)=(p.id,m.vault_id)
            JOIN core.capabilities c ON c.id=g.capability_id
            WHERE p.id=v.object_cleanup_principal_id AND p.kind='system' AND p.revoked_at IS NULL
              AND m.vault_id=v.id AND m.revoked_at IS NULL AND g.revoked_at IS NULL AND c.name='object.cleanup'))
        OR EXISTS(SELECT 1 FROM core.domain_dedup_key_wrappers w JOIN core.domain_key_versions k
          ON k.id=w.domain_key_version_id WHERE k.key_domain_id<>w.key_domain_id)
        OR EXISTS(SELECT 1 FROM content.asset_key_envelopes e
          JOIN core.domain_key_versions k ON k.id=e.domain_key_version_id
          JOIN content.asset_objects o ON o.id=e.asset_object_id
          WHERE k.key_domain_id<>e.key_domain_id OR k.generation<>e.key_generation OR o.key_domain_id<>e.key_domain_id)
        OR EXISTS(SELECT 1 FROM core.vault_key_wrappers w JOIN core.vault_key_versions k
          ON k.id=w.vault_key_version_id WHERE w.generation<>k.generation) THEN
        RAISE EXCEPTION 'invalid knowledge restore ownership' USING ERRCODE='23514';
      END IF;

      -- These omitted V2 fields are not part of the canonical wire digest.
      IF (SELECT count(*) FROM identity.security_settings WHERE singleton)<>1
        OR EXISTS(SELECT 1 FROM identity.credentials c WHERE c.verifier IS DISTINCT FROM
          (SELECT dummy_verifier FROM identity.security_settings WHERE singleton)
          OR c.verifier_version<>1 OR c.updated_at IS DISTINCT FROM c.inserted_at)
        OR EXISTS(SELECT 1 FROM core.vault_key_wrappers w WHERE w.kdf_version<>1
          OR w.kdf_salt<>pg_catalog.convert_to('restore-pending','UTF8')
          OR w.kdf_parameters<>'{"state":"restore_pending","version":1}'::jsonb
          OR w.wrapper_algorithm<>'restore_pending'
          OR w.wrapped_key<>pg_catalog.convert_to('restore-pending','UTF8')) THEN
        RAISE EXCEPTION 'invalid knowledge restore compatibility values' USING ERRCODE='23514';
      END IF;

      IF EXISTS(SELECT 1 FROM content.resources r WHERE
          (r.kind='asset' AND r.current_version_id IS NOT NULL)
          OR (r.kind='note' AND NOT EXISTS(SELECT 1 FROM content.note_versions n
            WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=(r.current_version_id,r.id,r.vault_id,r.classification)))
          OR (r.kind='document' AND NOT EXISTS(SELECT 1 FROM content.document_versions d
            WHERE (d.resource_version_id,d.resource_id,d.vault_id,d.classification)=(r.current_version_id,r.id,r.vault_id,r.classification))))
        OR EXISTS(SELECT 1 FROM content.note_versions n JOIN content.resources r ON r.id=n.resource_id WHERE r.kind<>'note')
        OR EXISTS(SELECT 1 FROM content.document_versions d JOIN content.resources r ON r.id=d.resource_id WHERE r.kind<>'document')
        OR EXISTS(SELECT 1 FROM content.resource_versions v JOIN content.resources r ON r.id=v.resource_id
          WHERE (r.kind='note' AND NOT EXISTS(SELECT 1 FROM content.note_versions n WHERE n.resource_version_id=v.id))
            OR (r.kind='document' AND NOT EXISTS(SELECT 1 FROM content.document_versions d WHERE d.resource_version_id=v.id)))
        OR EXISTS(SELECT 1 FROM content.note_versions n JOIN content.resource_versions v ON v.id=n.resource_version_id
          WHERE (n.parent_version_id IS NULL)<>(v.revision=0))
        OR EXISTS(SELECT 1 FROM content.note_versions n JOIN content.resource_versions v ON v.id=n.resource_version_id
          JOIN content.resource_versions p ON p.id IN (n.parent_version_id,n.merge_parent_version_id) WHERE p.revision>=v.revision)
        OR EXISTS(SELECT 1 FROM content.note_conflicts c JOIN content.note_versions n ON n.resource_version_id=c.resolution_version_id
          WHERE n.parent_version_id IS DISTINCT FROM c.canonical_version_id OR n.merge_parent_version_id IS DISTINCT FROM c.competing_version_id)
        OR EXISTS(SELECT 1 FROM content.note_conflicts c
          JOIN content.resource_versions b ON b.id=c.base_version_id
          JOIN content.resource_versions a ON a.id=c.canonical_version_id
          JOIN content.resource_versions p ON p.id=c.competing_version_id WHERE b.revision>=a.revision OR b.revision>=p.revision) THEN
        RAISE EXCEPTION 'invalid knowledge restore history' USING ERRCODE='23514';
      END IF;

      IF EXISTS(SELECT 1 FROM content.document_versions d
        JOIN content.assets a ON a.id=d.source_asset_id
        JOIN content.resources r ON r.id=d.source_resource_id
        JOIN content.asset_objects o ON o.id=d.source_object_id
        WHERE r.kind<>'asset' OR a.resource_version_id<>d.source_resource_version_id
          OR (a.asset_object_id IS NOT NULL AND a.asset_object_id<>o.id)
          OR d.source_byte_size<>o.plaintext_byte_size OR o.lifecycle<>'available' OR o.deleted_at IS NOT NULL
          OR (SELECT count(*) FROM content.assets x WHERE x.resource_version_id=d.source_resource_version_id)<>1
          OR NOT EXISTS(SELECT 1 FROM content.resource_assets ra
            WHERE (ra.resource_version_id,ra.asset_id,ra.vault_id,ra.classification)=
              (d.source_resource_version_id,d.source_asset_id,d.vault_id,d.classification)))
        OR EXISTS(SELECT 1 FROM content.document_versions GROUP BY source_object_id
          HAVING count(DISTINCT pg_catalog.encode(source_digest,'hex'))<>1 OR count(DISTINCT source_byte_size)<>1)
        OR EXISTS(SELECT 1 FROM content.document_versions d
          WHERE d.extraction_format IS NOT NULL AND d.extraction_format<>1)
        OR EXISTS(SELECT 1 FROM content.document_fragments f JOIN content.document_versions d ON d.resource_version_id=f.resource_version_id
          WHERE d.state<>'ready' OR f.digest<>pg_catalog.sha256(pg_catalog.convert_to(f.text,'UTF8'))
            OR f.locator IS DISTINCT FROM content.document_canonical_locator(f.locator)
            OR f.id IS DISTINCT FROM content.document_fragment_id(f.resource_version_id,f.locator,f.ordinal,f.digest)
            OR (f.locator->>'kind') NOT IN ('fragment',CASE d.media_type
              WHEN 'application/pdf' THEN 'pdf' WHEN 'text/plain' THEN 'text' WHEN 'text/markdown' THEN 'markdown' END))
        OR EXISTS(SELECT 1 FROM content.document_import_receipts WHERE state<>'completed') THEN
        RAISE EXCEPTION 'invalid knowledge restore Document' USING ERRCODE='23514';
      END IF;
      -- Bounded per-version concatenation, never an unbounded table aggregate.
      FOR document IN SELECT resource_version_id,extracted_text_digest FROM content.document_versions WHERE state='ready'
      LOOP
        SELECT count(*),coalesce(sum(pg_catalog.octet_length(text)),0)
          INTO amount,size FROM content.document_fragments WHERE resource_version_id=document.resource_version_id;
        IF amount NOT BETWEEN 1 AND 4096 OR size NOT BETWEEN 1 AND 16777216 THEN
          RAISE EXCEPTION 'invalid knowledge restore fragments' USING ERRCODE='23514';
        END IF;
        bytes:=pg_catalog.decode('','hex'); amount:=0;
        FOR fragment IN SELECT ordinal,text FROM content.document_fragments
          WHERE resource_version_id=document.resource_version_id ORDER BY ordinal
        LOOP
          IF fragment.ordinal<>amount THEN
            RAISE EXCEPTION 'invalid knowledge restore fragments' USING ERRCODE='23514';
          END IF;
          bytes:=bytes||pg_catalog.convert_to(fragment.text,'UTF8'); amount:=amount+1;
        END LOOP;
        IF pg_catalog.sha256(bytes) IS DISTINCT FROM document.extracted_text_digest THEN
          RAISE EXCEPTION 'invalid knowledge restore fragment digest' USING ERRCODE='23514';
        END IF;
      END LOOP;

      IF EXISTS(SELECT 1 FROM content.note_attachments a JOIN content.resources r ON r.id=a.target_resource_id
          WHERE r.kind<>a.target_kind
            OR (a.target_kind='note' AND NOT EXISTS(SELECT 1 FROM content.note_versions n WHERE n.resource_version_id=a.target_resource_version_id))
            OR (a.target_kind='document' AND NOT EXISTS(SELECT 1 FROM content.document_versions d WHERE d.resource_version_id=a.target_resource_version_id AND d.state='ready'))
            OR (a.target_kind='asset' AND (SELECT count(*) FROM content.assets x JOIN content.resource_assets ra
              ON (ra.asset_id,ra.resource_version_id)=(x.id,x.resource_version_id) WHERE x.resource_version_id=a.target_resource_version_id)<>1))
        OR EXISTS(SELECT 1 FROM content.note_citations c JOIN content.document_fragments f ON f.id=c.fragment_id WHERE c.locator IS DISTINCT FROM f.locator)
        OR EXISTS(SELECT 1 FROM content.note_versions n
          CROSS JOIN LATERAL(SELECT count(*) amount,min(ordinal) first,max(ordinal) last
            FROM content.note_attachments WHERE note_resource_version_id=n.resource_version_id) a
          CROSS JOIN LATERAL(SELECT count(*) amount,min(ordinal) first,max(ordinal) last
            FROM content.note_citations WHERE note_resource_version_id=n.resource_version_id) c
          WHERE a.amount>100 OR c.amount>100
            OR (a.amount>0 AND (a.first<>0 OR a.last<>a.amount-1))
            OR (c.amount>0 AND (c.first<>0 OR c.last<>c.amount-1))
            OR (SELECT count(*) FROM (
              SELECT target_resource_id,target_resource_version_id FROM content.note_attachments WHERE note_resource_version_id=n.resource_version_id
              UNION SELECT source_resource_id,source_resource_version_id FROM content.note_citations WHERE note_resource_version_id=n.resource_version_id) targets)>100
            OR (SELECT count(DISTINCT fragment_id) FROM content.note_citations WHERE note_resource_version_id=n.resource_version_id)>100)
        OR EXISTS(SELECT 1 FROM content.note_versions n LEFT JOIN content.note_source_set_seals s
          ON s.note_resource_version_id=n.resource_version_id
          WHERE s.note_resource_version_id IS NULL
            OR (s.note_resource_id,s.vault_id,s.classification,s.attachment_count,s.citation_count)
              IS DISTINCT FROM (n.resource_id,n.vault_id,n.classification,
                (SELECT count(*) FROM content.note_attachments WHERE note_resource_version_id=n.resource_version_id),
                (SELECT count(*) FROM content.note_citations WHERE note_resource_version_id=n.resource_version_id)))
        OR EXISTS(SELECT 1 FROM content.note_source_set_seals s WHERE NOT EXISTS(SELECT 1 FROM content.note_versions n
          WHERE (n.resource_version_id,n.resource_id,n.vault_id,n.classification)=
            (s.note_resource_version_id,s.note_resource_id,s.vault_id,s.classification))) THEN
        RAISE EXCEPTION 'invalid knowledge restore Note sources' USING ERRCODE='23514';
      END IF;

      IF EXISTS(SELECT 1 FROM content.relationships e JOIN content.resources r ON r.id=e.target_resource_id
        WHERE r.kind='asset' AND e.target_resource_version_id IS NOT NULL
          AND (SELECT count(*) FROM content.assets a JOIN content.resource_assets ra
            ON (ra.asset_id,ra.resource_version_id)=(a.id,a.resource_version_id)
            WHERE a.resource_version_id=e.target_resource_version_id)<>1)
        OR EXISTS(SELECT 1 FROM (
          SELECT resource_id FROM content.resource_tags
          UNION SELECT source_resource_id FROM content.relationships
          UNION SELECT target_resource_id FROM content.relationships) x JOIN content.resources r ON r.id=x.resource_id
          WHERE r.kind='asset' AND NOT EXISTS(SELECT 1 FROM content.resource_versions v
            JOIN content.assets a ON a.resource_version_id=v.id
            JOIN content.resource_assets ra ON (ra.asset_id,ra.resource_version_id)=(a.id,v.id)
            WHERE v.resource_id=r.id))
        OR EXISTS(SELECT 1 FROM content.asset_objects o WHERE o.format_version<>1
          OR (o.lifecycle='available' AND (
            o.storage_ref<>'objects/'||o.vault_id::text||'/'||o.key_domain_id::text||'/hmac-sha256/'||
              pg_catalog.substr(pg_catalog.encode(o.lookup_digest,'hex'),1,2)||'/'||pg_catalog.encode(o.lookup_digest,'hex')
            OR NOT EXISTS(SELECT 1 FROM content.asset_key_envelopes e WHERE e.asset_object_id=o.id)))) THEN
        RAISE EXCEPTION 'invalid knowledge restore object closure' USING ERRCODE='23514';
      END IF;

      IF EXISTS(SELECT 1 FROM core.outbox_events e WHERE audit.knowledge_restore_payload_is_valid(e) IS NOT TRUE)
        OR EXISTS(SELECT 1 FROM jobs.job_submissions s JOIN core.outbox_events e ON e.id=s.outbox_event_id
          WHERE s.idempotency_key<>e.idempotency_key OR s.classification<>e.classification
            OR s.job_type IS DISTINCT FROM CASE e.event_type
              WHEN 'asset.finalize_requested' THEN 'asset_finalize' WHEN 'asset.verify_requested' THEN 'asset_verify'
              WHEN 'asset.metadata_requested' THEN 'asset_metadata' WHEN 'asset.cleanup_requested' THEN 'asset_cleanup'
              WHEN 'object.cleanup_requested' THEN 'object_cleanup' WHEN 'backup.requested' THEN 'backup'
              WHEN 'document.extraction_requested' THEN 'document_extract'
              WHEN 'document.ready' THEN 'document_projection' WHEN 'document.deleted' THEN 'document_projection'
              WHEN 'document.restored' THEN 'document_projection'
              WHEN 'note.current_changed' THEN 'note_projection' WHEN 'note.conflict_created' THEN 'note_projection'
              WHEN 'note.conflict_resolved' THEN 'note_projection' WHEN 'note.deleted' THEN 'note_projection'
              WHEN 'note.restored' THEN 'note_projection' END)
        OR EXISTS(SELECT 1 FROM content.document_versions d WHERE d.state='extracting'
          AND NOT EXISTS(SELECT 1 FROM core.outbox_events e JOIN jobs.job_submissions s ON s.outbox_event_id=e.id
            WHERE e.id=d.attempt_job_id AND e.event_type='document.extraction_requested'
              AND (e.vault_id,e.classification)=(d.vault_id,d.classification)
              AND e.expected_entity_revision=d.attempt_generation-1 AND s.job_type='document_extract'
              AND e.payload=pg_catalog.jsonb_build_object('resource_id',d.resource_id::text,'resource_version_id',d.resource_version_id::text))) THEN
        RAISE EXCEPTION 'invalid knowledge restore work provenance' USING ERRCODE='23514';
      END IF;
    END
    $function$
    """)
  end

  defp create_destination_validator do
    execute("""
    CREATE FUNCTION audit.assert_knowledge_restore_destination(admission audit.knowledge_restore_admissions)
    RETURNS void LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path=pg_catalog
    AS $function$
    DECLARE ordinal integer; actual record; required_count bigint;
    BEGIN
      PERFORM audit.assert_knowledge_restore_graph(admission.vault_id);
      SELECT count(*) INTO required_count FROM (
        SELECT a.asset_object_id id FROM content.assets a JOIN content.asset_objects o ON o.id=a.asset_object_id
        WHERE a.state NOT IN ('pending_delete','deleted') AND o.lifecycle='available'
        UNION SELECT source_object_id FROM content.document_versions) required;
      IF required_count IS DISTINCT FROM admission.object_count THEN
        RAISE EXCEPTION 'invalid knowledge restore inventory count' USING ERRCODE='23514';
      END IF;
      FOR ordinal IN 0..37 LOOP
        SELECT * INTO actual FROM audit.knowledge_restore_table_digest(ordinal);
        IF actual.row_count IS DISTINCT FROM admission.expected_counts[ordinal+1]
          OR actual.digest IS DISTINCT FROM admission.expected_digests[ordinal+1] THEN
          RAISE EXCEPTION 'knowledge restore destination differs from authenticated staging' USING ERRCODE='23514';
        END IF;
      END LOOP;
    END
    $function$
    """)
  end

  defp create_binding do
    execute("""
    CREATE FUNCTION audit.knowledge_restore_is_bound(owner_id uuid) RETURNS boolean
    LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path=pg_catalog
    AS $function$
    BEGIN
      IF session_user<>'singularity_migration'
        OR current_user<>'singularity_table_owner'
        OR NOT pg_catalog.pg_has_role(session_user,'singularity_table_owner','SET') THEN
        RETURN false;
      END IF;
      RETURN EXISTS(
        SELECT 1 FROM audit.knowledge_restore_admissions a
        JOIN audit.restore_import_sagas s ON s.singleton AND #{saga_match_sql("a", "s")}
        WHERE a.singleton AND a.vault_id=owner_id AND a.state='loading' AND s.state='pending'
          AND a.backend_pid=pg_catalog.pg_backend_pid()
          AND a.transaction_id=pg_catalog.pg_current_xact_id()
          AND audit.knowledge_restore_lock_is_held()
      );
    END
    $function$
    """)
  end

  defp create_entrypoints do
    execute("""
    CREATE FUNCTION audit.begin_knowledge_restore(
      manifest uuid,owner_id uuid,authenticated_hash bytea,counts bigint[],digests bytea[])
    RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog
    AS $function$
    DECLARE saga audit.restore_import_sagas%ROWTYPE;
    BEGIN
      #{authority_sql()}
      IF manifest IS NULL OR owner_id IS NULL
        OR pg_catalog.octet_length(authenticated_hash) IS DISTINCT FROM 32
        OR NOT audit.knowledge_restore_vectors_valid(counts,digests)
        OR NOT audit.knowledge_restore_lock_is_held() THEN
        RAISE EXCEPTION 'invalid knowledge restore admission' USING ERRCODE='23514';
      END IF;
      LOCK TABLE audit.restore_import_sagas,audit.knowledge_restore_admissions IN ACCESS EXCLUSIVE MODE;
      SELECT * INTO saga FROM audit.restore_import_sagas WHERE singleton FOR UPDATE;
      IF NOT FOUND OR saga.state<>'pending'
        OR (saga.manifest_id,saga.vault_id,saga.manifest_hash)
          IS DISTINCT FROM (manifest,owner_id,authenticated_hash)
        OR EXISTS(SELECT 1 FROM audit.knowledge_restore_admissions) THEN
        RAISE EXCEPTION 'invalid knowledge restore admission' USING ERRCODE='23514';
      END IF;
      #{empty_destination_sql()}
      INSERT INTO audit.knowledge_restore_admissions(
        singleton,manifest_id,vault_id,manifest_hash,transaction_id,backend_pid,
        expected_counts,expected_digests,state,manifest_tag,inventory_hash,destination_root_hash,object_count)
      VALUES(true,manifest,owner_id,authenticated_hash,pg_catalog.pg_current_xact_id(),
        pg_catalog.pg_backend_pid(),counts,digests,'loading',saga.manifest_tag,saga.inventory_hash,
        saga.destination_root_hash,saga.object_count);
    END
    $function$
    """)

    execute("""
    CREATE FUNCTION audit.validate_knowledge_restore(manifest uuid,owner_id uuid,authenticated_hash bytea)
    RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog
    AS $function$
    DECLARE admission audit.knowledge_restore_admissions%ROWTYPE;
    BEGIN
      #{authority_sql()}
      SELECT * INTO admission FROM audit.knowledge_restore_admissions WHERE singleton FOR UPDATE;
      IF NOT FOUND OR NOT audit.knowledge_restore_is_bound(owner_id)
        OR (admission.manifest_id,admission.vault_id,admission.manifest_hash)
          IS DISTINCT FROM (manifest,owner_id,authenticated_hash) THEN
        RAISE EXCEPTION 'invalid knowledge restore admission' USING ERRCODE='23514';
      END IF;
      PERFORM audit.assert_knowledge_restore_destination(admission);
      UPDATE audit.knowledge_restore_admissions SET state='validated' WHERE singleton;
    END
    $function$
    """)
  end

  defp create_guards do
    execute("""
    CREATE FUNCTION audit.enforce_knowledge_restore_admission() RETURNS trigger
    LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog
    AS $function$
    DECLARE saga audit.restore_import_sagas%ROWTYPE;
    BEGIN
      #{authority_sql()}
      IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'knowledge restore admission is immutable' USING ERRCODE='23514';
      END IF;
      IF NEW.transaction_id IS DISTINCT FROM pg_catalog.pg_current_xact_id()
        OR NEW.backend_pid IS DISTINCT FROM pg_catalog.pg_backend_pid()
        OR NOT audit.knowledge_restore_lock_is_held() THEN
        RAISE EXCEPTION 'invalid knowledge restore admission' USING ERRCODE='23514';
      END IF;
      SELECT * INTO saga FROM audit.restore_import_sagas WHERE singleton FOR UPDATE;
      IF NOT FOUND OR saga.state<>'pending' OR (#{saga_match_sql("NEW", "saga")}) IS NOT TRUE THEN
        RAISE EXCEPTION 'invalid knowledge restore admission' USING ERRCODE='23514';
      END IF;
      IF TG_OP='INSERT' THEN
        IF NEW.state IS DISTINCT FROM 'loading' THEN
          RAISE EXCEPTION 'invalid knowledge restore state' USING ERRCODE='23514';
        END IF;
        #{empty_destination_sql()}
      ELSE
        IF (pg_catalog.to_jsonb(NEW)-'state') IS DISTINCT FROM (pg_catalog.to_jsonb(OLD)-'state')
          OR OLD.state<>'loading' OR NEW.state<>'validated' THEN
          RAISE EXCEPTION 'knowledge restore admission is immutable' USING ERRCODE='23514';
        END IF;
      END IF;
      RETURN NEW;
    END
    $function$
    """)

    execute("""
    CREATE TRIGGER knowledge_restore_admission_immutable_check
    BEFORE INSERT OR UPDATE OR DELETE ON audit.knowledge_restore_admissions
    FOR EACH ROW EXECUTE FUNCTION audit.enforce_knowledge_restore_admission()
    """)

    execute("""
    CREATE FUNCTION audit.enforce_knowledge_restore_final() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog
    AS $function$
    DECLARE admission audit.knowledge_restore_admissions%ROWTYPE;
      saga audit.restore_import_sagas%ROWTYPE;
    BEGIN
      #{authority_sql()}
      SELECT * INTO admission FROM audit.knowledge_restore_admissions WHERE singleton FOR UPDATE;
      IF NOT FOUND OR admission.state<>'validated'
        OR admission.transaction_id IS DISTINCT FROM pg_catalog.pg_current_xact_id()
        OR admission.backend_pid IS DISTINCT FROM pg_catalog.pg_backend_pid()
        OR (pg_catalog.to_jsonb(admission)-'state') IS DISTINCT FROM (pg_catalog.to_jsonb(NEW)-'state')
        OR NOT audit.knowledge_restore_lock_is_held() THEN
        RAISE EXCEPTION 'knowledge restore was not finalized' USING ERRCODE='23514';
      END IF;
      SELECT * INTO saga FROM audit.restore_import_sagas WHERE singleton FOR UPDATE;
      IF NOT FOUND OR saga.state NOT IN ('pending','imported')
        OR (#{saga_match_sql("admission", "saga")}) IS NOT TRUE THEN
        RAISE EXCEPTION 'invalid knowledge restore final marker' USING ERRCODE='23514';
      END IF;
      PERFORM audit.assert_knowledge_restore_destination(admission);
      RETURN NULL;
    END
    $function$
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER knowledge_restore_final_check
    AFTER INSERT OR UPDATE ON audit.knowledge_restore_admissions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
    EXECUTE FUNCTION audit.enforce_knowledge_restore_final()
    """)
  end
end
