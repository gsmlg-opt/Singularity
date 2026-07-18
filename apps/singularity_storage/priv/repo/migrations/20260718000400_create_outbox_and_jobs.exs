defmodule Singularity.Storage.Migrations.CreateOutboxAndJobs do
  use Ecto.Migration

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    execute("""
    DO $migration$
    BEGIN
    CREATE TABLE core.outbox_events (
      id uuid PRIMARY KEY,
      sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
      event_type text NOT NULL,
      idempotency_key text NOT NULL,
      vault_id uuid NOT NULL,
      principal_id uuid NOT NULL,
      required_capability text NOT NULL,
      authorization_epoch bigint NOT NULL,
      classification text NOT NULL,
      correlation_id uuid NOT NULL,
      causation_id uuid,
      expected_entity_revision bigint NOT NULL,
      envelope_version integer NOT NULL,
      payload jsonb NOT NULL,
      occurred_at timestamptz(6) NOT NULL,
      claim_token uuid,
      claimed_until timestamptz(6),
      runner_job_id text,
      delivered_at timestamptz(6),
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (id, vault_id),
      UNIQUE (vault_id, idempotency_key),
      CONSTRAINT outbox_events_membership_fkey
        FOREIGN KEY (principal_id, vault_id)
        REFERENCES core.vault_members(principal_id, vault_id)
        MATCH FULL,
      CONSTRAINT outbox_events_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT outbox_events_authorization_epoch_check
        CHECK (authorization_epoch >= 0),
      CONSTRAINT outbox_events_expected_revision_check
        CHECK (expected_entity_revision >= 0),
      CONSTRAINT outbox_events_envelope_version_check
        CHECK (envelope_version > 0),
      CONSTRAINT outbox_events_claim_shape_check
        CHECK (
          (claim_token IS NULL AND claimed_until IS NULL)
          OR
          (claim_token IS NOT NULL AND claimed_until IS NOT NULL)
        )
    );

    CREATE INDEX outbox_events_dispatchable
      ON core.outbox_events(sequence)
      WHERE delivered_at IS NULL;
    END
    $migration$;
    """)

    Oban.Migrations.up(prefix: "jobs")

    execute("""
    DO $migration$
    BEGIN
    CREATE TABLE jobs.job_submissions (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL REFERENCES core.vaults(id),
      outbox_event_id uuid NOT NULL,
      classification text NOT NULL,
      idempotency_key text NOT NULL,
      job_type text NOT NULL,
      runner_job_id text,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (outbox_event_id),
      UNIQUE (vault_id, idempotency_key),
      UNIQUE (id, vault_id),
      CONSTRAINT job_submissions_outbox_vault_fkey
        FOREIGN KEY (outbox_event_id, vault_id)
        REFERENCES core.outbox_events(id, vault_id)
        MATCH FULL,
      CONSTRAINT job_submissions_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted'))
    );

    CREATE TABLE jobs.job_progress (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL,
      submission_id uuid NOT NULL,
      classification text NOT NULL,
      state text NOT NULL,
      processing_revision bigint NOT NULL DEFAULT 0,
      checkpoint_version integer NOT NULL,
      checkpoint jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (submission_id),
      UNIQUE (id, vault_id),
      CONSTRAINT job_progress_submission_vault_fkey
        FOREIGN KEY (submission_id, vault_id)
        REFERENCES jobs.job_submissions(id, vault_id)
        MATCH FULL,
      CONSTRAINT job_progress_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT job_progress_state_check
        CHECK (state IN (
          'pending',
          'running',
          'waiting_for_unlock',
          'waiting_for_backup_key',
          'completed',
          'failed'
        )),
      CONSTRAINT job_progress_revision_check CHECK (processing_revision >= 0),
      CONSTRAINT job_progress_checkpoint_version_check CHECK (checkpoint_version > 0)
    );

    CREATE TABLE jobs.effect_receipts (
      id uuid PRIMARY KEY,
      vault_id uuid NOT NULL,
      submission_id uuid NOT NULL,
      classification text NOT NULL,
      effect_key text NOT NULL,
      result text NOT NULL,
      entity_revision bigint NOT NULL,
      inserted_at timestamptz(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE (vault_id, effect_key),
      CONSTRAINT effect_receipts_submission_vault_fkey
        FOREIGN KEY (submission_id, vault_id)
        REFERENCES jobs.job_submissions(id, vault_id)
        MATCH FULL,
      CONSTRAINT effect_receipts_classification_check
        CHECK (classification IN ('private', 'sensitive', 'restricted')),
      CONSTRAINT effect_receipts_result_check
        CHECK (result IN ('applied', 'stale')),
      CONSTRAINT effect_receipts_entity_revision_check CHECK (entity_revision >= 0)
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
    DROP TABLE IF EXISTS jobs.effect_receipts;
    DROP TABLE IF EXISTS jobs.job_progress;
    DROP TABLE IF EXISTS jobs.job_submissions;
    END
    $migration$;
    """)

    Oban.Migrations.down(prefix: "jobs")
    execute("DROP TABLE IF EXISTS core.outbox_events")
    execute("SET LOCAL ROLE NONE")
  end
end
