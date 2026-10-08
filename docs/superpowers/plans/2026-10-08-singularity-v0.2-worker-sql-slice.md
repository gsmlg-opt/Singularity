# Document Worker SQL Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the four approved worker-only SQL functions without expanding canonical table or raw lifecycle access.

**Architecture:** An ungranted helper validates transaction isolation, scoped live authority, retained event identity and the canonical target. Exposed wrappers return explicit bounded descriptors or receipts, use the existing lifecycle operations, and preserve source retention and deadline fences. This slice does not wire Runtime or implement the adapter.

**Tech Stack:** PostgreSQL 17, Ecto migrations, Postgrex, ExUnit integration alias, devenv.

**Readiness:** Implemented and accepted locally for this SQL slice only at `b8db6d562d072c2de5dc77635d29159080d1401a`, with independent spec/quality approval and post-commit scoped verification. Adapter and Runtime implementation remain governed by their separate detailed steps. Missing functions in the initial red run are the intended failure, not a failed repair attempt.

---

## Scope and ownership

The approved [worker amendment](../specs/2026-10-08-singularity-v0.2-phase-2-worker-bridge-proposal.md) governs this slice. This plan makes only its SQL component executable; the [parent bridge plan](2026-10-08-singularity-v0.2-phase-2-worker-bridge.md) still owns adapter, exhaustion, adversarial acceptance and Runtime obligations.

Work only in `/home/gao/Workspace/gsmlg-opt/Singularity/.trees/v0.2-phase-2-import-extraction`, branch `codex/v0.2-phase-2-import-extraction`, starting source `80bbcd538586bca6f1c38569e357e77f8ac361c3`.

- SQL implementer: create `apps/singularity_storage/priv/repo/migrations/20261008000000_document_worker_bridge.exs`; extend `apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs`.
- Coordinator: this plan and the [execution record](../../verification/2026-10-08-document-worker-sql-bridge.md).
- Reviewers: read-only spec review followed by code-quality review.

Preserve other changes. Do not edit historical migrations, canonical grants/RLS, public repositories, WorkerScope/ScopedRepo, GenericWorker, custody adapters, or Vault. No E2E, public import activation, release, merge, push or deployment. No temporary grants or RequestRepo substitution in verified calls.

The denied table contracts apply to `content.document_versions` and
`content.document_fragments`. Legacy `content.resources` and
`content.resource_versions` already grant worker CRUD subject to existing RLS;
preserve and characterize those ACLs instead of revoking them or claiming they
are denied. The initial new test's contrary assumption was corrected before
production implementation, with a separate actual-role characterization pass
(seed `985932`, one executed test, 14 excluded, exit 0). This is not a waiver
of Document-table denial or any unchanged-ACL requirement.

## Task 1: Establish the actual-role red contract

- [x] Create and format the focused test file using separate administrative fixtures and real WorkerRepo scoped calls. Its initial 13 tests cover catalog/ACL properties, source allowlists, claim/resume, tombstone outcomes, ready replay, atomic invalid completion, source Asset deletion, locked metadata, missing/malformed scope, unsupported isolation, target/revision/epoch/overflow rejection, forged event payload/key, and revoked capability.
- [x] Run the exact command below before any migration exists. Implementer result: exit 2, seed `461915`, 13 tests, 13 missing-feature failures. The coordinator read the full test file and requested SafeSQL calls and `SourceLocator.to_map/1` serialization before green.

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
```

## Task 2: Add the complete forward migration

- [x] Recheck timestamp uniqueness and the worktree diff; preserve unrelated files.
- [x] Create the migration with the exact implementation recorded below. All four wrappers and their ACLs must be present before executing it. The helper is private; source returns and terminal receipts have no canonical composite outputs.
- [x] Format the two owned Elixir files and run Task 1's exact integration command. Expected: the current contracts pass with zero failures. An unexpected failure requires diagnosis and a focused repair; after two failed Sol repair rounds or an evidenced technical impasse, hand off to parent-managed Astra for at most three repair attempts.

```bash
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix format apps/singularity_storage/priv/repo/migrations/20261008000000_document_worker_bridge.exs apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/Singularity/deps devenv shell -- mix singularity.test.integration apps/singularity_storage/test/singularity/storage/postgres/document_worker_repository_test.exs
```
- [x] Extend focused tests for post-wait revocation, all four isolation guards, denied raw/helper execution, complete durable-event/live-authority matrices, source binding and stale successor fences, fragment validation, and privacy. Write each contract before changing enforced behavior; record initial-slice gaps instead of claiming full bridge acceptance.
- [x] Obtain spec review, repair findings, then code-quality review. Coordinator reruns the exact focused command and the selected lifecycle/custody regression command in the execution record. Commit only reviewed, passing owned files and evidence.

## Migration implementation

```elixir
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

    execute("REVOKE ALL ON FUNCTION content.document_worker_target(#{@types},boolean) FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth")
    for signature <- @signatures do
      execute("REVOKE ALL ON FUNCTION content.#{signature} FROM PUBLIC, singularity_web, singularity_worker, singularity_dispatcher, singularity_pre_auth")
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
    create_function("document_worker_target", ", lock_rows boolean", "content.document_versions", """
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
    """)
  end

  defp create_describe do
    create_function(
      "describe_document_worker", "",
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
      "claim_document_worker", ", adapter text, format integer",
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
      "#{name}_document_worker", extras,
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
```

## Coordinator self-review

Passed for the bounded production implementation step: the coordinator read
the approved amendment and all initial test code, then reviewed every helper
and wrapper body above. Six-argument envelope mapping, overflow/isolation
guards, authorization lock before fresh authority, retained-event/creator
binding, resource-before-version locking, consistent source/attempt query,
terminal NULLs, tombstone-safe unchanged-deadline resume, outcome metadata
fences, canonical delegation, explicit output types and ACLs are represented.
Method/signature/type names match the initial contracts. No undefined helper
or placeholder production body remains. The identified legacy resource-ACL
assumption is explicitly characterized and preserved. Full adversarial matrix
and independent review remain required before SQL component acceptance;
adapter, Runtime and Phase 2 acceptance are not implied.
