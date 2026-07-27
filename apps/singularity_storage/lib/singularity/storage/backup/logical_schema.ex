defmodule Singularity.Storage.Backup.LogicalSchema do
  @moduledoc """
  Exact version-one logical backup row schemas.

  Column order is the wire order. Tags are binary values understood by
  `LogicalRecordCodec`; nullable columns alone may carry `{"null"}`. Table
  ordinals and primary-key column positions are zero-based.
  """

  @version 1

  @definitions [
    {
      "identity.people",
      [
        {"id", "uuid", false},
        {"display_name", "text", false},
        {"metadata", "json", false},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "identity.accounts",
      [
        {"id", "uuid", false},
        {"person_id", "uuid", false},
        {"status", "text", false},
        {"metadata", "json", false},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "identity.credentials",
      [
        {"id", "uuid", false},
        {"account_id", "uuid", false},
        {"normalized_login", "text", false},
        {"revoked_at", "timestamp", true},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "identity.principals",
      [
        {"id", "uuid", false},
        {"account_id", "uuid", false},
        {"kind", "text", false},
        {"authorization_epoch", "integer", false},
        {"revoked_at", "timestamp", true},
        {"metadata", "json", false},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "core.capabilities",
      [
        {"id", "uuid", false},
        {"name", "text", false},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "core.vaults",
      [
        {"id", "uuid", false},
        {"kind", "text", false},
        {"authorization_epoch", "integer", false},
        {"locked", "boolean", false},
        {"metadata", "json", false},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false},
        {"object_cleanup_principal_id", "uuid", true}
      ],
      [{0, "uuid"}]
    },
    {
      "core.vault_members",
      [
        {"principal_id", "uuid", false},
        {"vault_id", "uuid", false},
        {"clearance", "text", false},
        {"revoked_at", "timestamp", true},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false}
      ],
      [{0, "uuid"}, {1, "uuid"}]
    },
    {
      "core.principal_capabilities",
      [
        {"principal_id", "uuid", false},
        {"vault_id", "uuid", false},
        {"capability_id", "uuid", false},
        {"revoked_at", "timestamp", true},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}, {1, "uuid"}, {2, "uuid"}]
    },
    {
      "identity.devices",
      [
        {"id", "uuid", false},
        {"principal_id", "uuid", false},
        {"vault_id", "uuid", false},
        {"label", "text", false},
        {"revoked_at", "timestamp", true},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "core.key_domains",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"classification", "text", false},
        {"kind", "text", false},
        {"state", "text", false},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "core.vault_key_versions",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"generation", "integer", false},
        {"state", "text", false},
        {"algorithm", "text", false},
        {"activated_at", "timestamp", true},
        {"retired_at", "timestamp", true},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "core.vault_key_wrappers",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"vault_key_version_id", "uuid", false},
        {"account_id", "uuid", false},
        {"generation", "integer", false},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "core.domain_key_versions",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"key_domain_id", "uuid", false},
        {"vault_key_version_id", "uuid", false},
        {"generation", "integer", false},
        {"state", "text", false},
        {"algorithm", "text", false},
        {"wrapped_key", "bytes", false},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "core.domain_dedup_key_wrappers",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"key_domain_id", "uuid", false},
        {"domain_key_version_id", "uuid", false},
        {"algorithm", "text", false},
        {"wrapped_key", "bytes", false},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "content.resources",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"classification", "text", false},
        {"title", "text", false},
        {"deleted_at", "timestamp", true},
        {"metadata", "json", false},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "content.resource_versions",
      [
        {"id", "uuid", false},
        {"resource_id", "uuid", false},
        {"vault_id", "uuid", false},
        {"classification", "text", false},
        {"revision", "integer", false},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "content.asset_objects",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"key_domain_id", "uuid", false},
        {"classification", "text", false},
        {"lookup_digest", "bytes", false},
        {"ciphertext_hash", "bytes", false},
        {"plaintext_byte_size", "integer", false},
        {"ciphertext_byte_size", "integer", false},
        {"storage_ref", "text", false},
        {"format_version", "integer", false},
        {"lifecycle", "text", false},
        {"retained_until", "timestamp", true},
        {"deleted_at", "timestamp", true},
        {"deletion_evidence", "json", true},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false},
        {"lifecycle_revision", "integer", false},
        {"delete_claim_token", "uuid", true},
        {"delete_claimed_at", "timestamp", true}
      ],
      [{0, "uuid"}]
    },
    {
      "content.assets",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"resource_version_id", "uuid", false},
        {"asset_object_id", "uuid", true},
        {"classification", "text", false},
        {"state", "text", false},
        {"state_revision", "integer", false},
        {"failure_code", "text", true},
        {"retryable", "boolean", true},
        {"failed_operation", "text", true},
        {"attempt", "integer", false},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "content.asset_key_envelopes",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"asset_object_id", "uuid", false},
        {"domain_key_version_id", "uuid", false},
        {"key_domain_id", "uuid", false},
        {"classification", "text", false},
        {"algorithm", "text", false},
        {"key_generation", "integer", false},
        {"wrapped_dek", "bytes", false},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "content.asset_metadata",
      [
        {"id", "uuid", false},
        {"asset_id", "uuid", false},
        {"resource_version_id", "uuid", false},
        {"vault_id", "uuid", false},
        {"classification", "text", false},
        {"projection_version", "integer", false},
        {"original_filename", "text", false},
        {"declared_media_type", "text", false},
        {"detected_media_type", "text", true},
        {"plaintext_byte_size", "integer", false},
        {"pdf_header_version", "text", true},
        {"image_width", "integer", true},
        {"image_height", "integer", true},
        {"extraction_state", "text", false},
        {"extractor_version", "text", true},
        {"completed_at", "timestamp", true},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "content.resource_assets",
      [
        {"resource_version_id", "uuid", false},
        {"asset_id", "uuid", false},
        {"vault_id", "uuid", false},
        {"classification", "text", false},
        {"released_at", "timestamp", true},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}, {1, "uuid"}]
    },
    {
      "content.source_references",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"resource_version_id", "uuid", false},
        {"principal_id", "uuid", false},
        {"classification", "text", false},
        {"kind", "text", false},
        {"observed_at", "timestamp", false},
        {"original_filename", "text", false},
        {"declared_media_type", "text", false},
        {"byte_size", "integer", false},
        {"idempotency_key_digest", "bytes", false},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "content.tombstones",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"asset_id", "uuid", false},
        {"principal_id", "uuid", false},
        {"classification", "text", false},
        {"reason", "text", false},
        {"retention_metadata", "json", false},
        {"deleted_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "audit.events",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", true},
        {"actor_kind", "text", false},
        {"principal_id", "uuid", true},
        {"anonymous_fingerprint", "bytes", true},
        {"operation", "text", false},
        {"result", "text", false},
        {"classification", "text", false},
        {"correlation_id", "uuid", false},
        {"target_type", "text", true},
        {"target_id", "uuid", true},
        {"metadata", "json", false},
        {"occurred_at", "timestamp", false},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "core.outbox_events",
      [
        {"id", "uuid", false},
        {"sequence", "integer", false},
        {"event_type", "text", false},
        {"idempotency_key", "text", false},
        {"vault_id", "uuid", false},
        {"principal_id", "uuid", false},
        {"required_capability", "text", false},
        {"vault_authorization_epoch", "integer", false},
        {"classification", "text", false},
        {"correlation_id", "uuid", false},
        {"causation_id", "uuid", true},
        {"expected_entity_revision", "integer", false},
        {"envelope_version", "integer", false},
        {"payload", "json", false},
        {"occurred_at", "timestamp", false},
        {"claim_token", "uuid", true},
        {"claimed_until", "timestamp", true},
        {"runner_job_id", "text", true},
        {"delivered_at", "timestamp", true},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false},
        {"principal_authorization_epoch", "integer", false},
        {"retired_at", "timestamp", true},
        {"retirement_reason", "text", true}
      ],
      [{0, "uuid"}]
    },
    {
      "jobs.job_submissions",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"outbox_event_id", "uuid", false},
        {"classification", "text", false},
        {"idempotency_key", "text", false},
        {"job_type", "text", false},
        {"runner_job_id", "text", true},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "jobs.job_progress",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"submission_id", "uuid", false},
        {"classification", "text", false},
        {"state", "text", false},
        {"processing_revision", "integer", false},
        {"checkpoint_version", "integer", false},
        {"checkpoint", "json", false},
        {"inserted_at", "timestamp", false},
        {"updated_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    },
    {
      "jobs.effect_receipts",
      [
        {"id", "uuid", false},
        {"vault_id", "uuid", false},
        {"submission_id", "uuid", false},
        {"classification", "text", false},
        {"effect_key", "text", false},
        {"result", "text", false},
        {"entity_revision", "integer", false},
        {"inserted_at", "timestamp", false}
      ],
      [{0, "uuid"}]
    }
  ]

  @schemas @definitions
           |> Enum.with_index()
           |> Enum.map(fn {{table, columns, primary_key}, ordinal} ->
             %{
               version: @version,
               ordinal: ordinal,
               table: table,
               columns:
                 Enum.map(columns, fn {name, tag, nullable?} ->
                   %{name: name, tag: tag, nullable?: nullable?}
                 end),
               primary_key:
                 Enum.map(primary_key, fn {position, tag} ->
                   %{position: position, tag: tag}
                 end)
             }
           end)

  @by_table Map.new(@schemas, fn schema -> {schema.table, schema} end)
  @by_ordinal Map.new(@schemas, fn schema -> {schema.ordinal, schema} end)

  @spec version() :: 1
  def version, do: @version

  @spec all() :: [map()]
  def all, do: @schemas

  @spec tables() :: [binary()]
  def tables, do: Enum.map(@schemas, & &1.table)

  @spec count() :: pos_integer()
  def count, do: length(@schemas)

  @spec fetch_table(term()) :: {:ok, map()} | :error
  def fetch_table(table) when is_binary(table), do: Map.fetch(@by_table, table)
  def fetch_table(_table), do: :error

  @spec fetch_ordinal(term()) :: {:ok, map()} | :error
  def fetch_ordinal(ordinal) when is_integer(ordinal), do: Map.fetch(@by_ordinal, ordinal)
  def fetch_ordinal(_ordinal), do: :error
end
