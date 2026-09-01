defmodule Singularity.Storage.Migrations.MoveWakeGenerationsToJobSubmissions do
  use Ecto.Migration

  @generic_worker "Singularity.Storage.Jobs.GenericWorker"
  @wake_reconciler "Singularity.Storage.Jobs.WakeReconciler"
  @active_states ~w(available scheduled executing retryable)
  @max_bigint "9223372036854775807"

  def up do
    execute("SET LOCAL ROLE singularity_table_owner")

    lock_wake_tables()

    execute("""
    ALTER TABLE jobs.job_submissions
      ADD COLUMN wake_requested_generation bigint NOT NULL DEFAULT 0,
      ADD COLUMN wake_consumed_generation bigint NOT NULL DEFAULT 0
    """)

    validate_legacy_generations()
    validate_active_reconciler_generations()
    backfill_wake_generations()

    execute("""
    ALTER TABLE jobs.job_submissions
      ADD CONSTRAINT job_submissions_wake_generations_check
      CHECK (
        wake_requested_generation >= 0
        AND wake_consumed_generation >= 0
        AND wake_consumed_generation <= wake_requested_generation
      )
    """)

    execute("SET LOCAL ROLE NONE")
  end

  def down do
    execute("SET LOCAL ROLE singularity_table_owner")

    lock_wake_tables()

    execute("""
    DO $guard$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM jobs.oban_peers
        WHERE expires_at > (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')
      ) THEN
        RAISE EXCEPTION 'cannot remove wake generations while Oban peers are active'
          USING ERRCODE = '55000';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM jobs.job_submissions
        WHERE wake_requested_generation <> wake_consumed_generation
      ) THEN
        RAISE EXCEPTION 'cannot remove wake generations while pending wake generations exist'
          USING ERRCODE = '55000';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM jobs.job_submissions AS submission
        JOIN jobs.oban_jobs AS target
          ON target.id::text = submission.runner_job_id
         AND target.worker = '#{@generic_worker}'
        JOIN jobs.oban_jobs AS reconciler
          ON reconciler.worker = '#{@wake_reconciler}'
         AND reconciler.state IN (#{quoted_active_states()})
         AND reconciler.args->>'target_job_id' = target.id::text
      ) THEN
        RAISE EXCEPTION 'cannot remove wake generations while active wake reconcilers exist'
          USING ERRCODE = '55000';
      END IF;
    END
    $guard$
    """)

    execute("""
    ALTER TABLE jobs.job_submissions
      DROP CONSTRAINT job_submissions_wake_generations_check,
      DROP COLUMN wake_requested_generation,
      DROP COLUMN wake_consumed_generation
    """)

    execute("SET LOCAL ROLE NONE")
  end

  defp lock_wake_tables do
    execute("LOCK TABLE jobs.oban_jobs IN SHARE ROW EXCLUSIVE MODE")
    execute("LOCK TABLE jobs.oban_peers IN SHARE ROW EXCLUSIVE MODE")
    execute("LOCK TABLE jobs.job_submissions IN ACCESS EXCLUSIVE MODE")
  end

  defp validate_legacy_generations do
    execute("""
    DO $guard$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM jobs.job_submissions AS submission
        JOIN jobs.oban_jobs AS target
          ON target.id::text = submission.runner_job_id
         AND target.worker = '#{@generic_worker}'
        CROSS JOIN LATERAL unnest(ARRAY[
          'singularity_wake_requested_generation',
          'singularity_wake_consumed_generation'
        ]::text[]) AS legacy(key)
        WHERE target.meta ? legacy.key
          AND (
            jsonb_typeof(target.meta->legacy.key) = 'number'
            AND target.meta->>legacy.key ~ '^(0|[1-9][0-9]*)$'
            AND (
              length(target.meta->>legacy.key) < 19
              OR (
                length(target.meta->>legacy.key) = 19
                AND (target.meta->>legacy.key) COLLATE "C" <= '#{@max_bigint}' COLLATE "C"
              )
            )
          ) IS NOT TRUE
      ) THEN
        RAISE EXCEPTION 'invalid legacy Singularity wake generation'
          USING ERRCODE = '22023';
      END IF;
    END
    $guard$
    """)
  end

  defp validate_active_reconciler_generations do
    execute("""
    DO $guard$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM jobs.job_submissions AS submission
        JOIN jobs.oban_jobs AS target
          ON target.id::text = submission.runner_job_id
         AND target.worker = '#{@generic_worker}'
        JOIN jobs.oban_jobs AS reconciler
          ON reconciler.worker = '#{@wake_reconciler}'
         AND reconciler.state IN (#{quoted_active_states()})
         AND reconciler.args->>'target_job_id' = target.id::text
        WHERE (
          jsonb_typeof(reconciler.args->'target_job_id') = 'number'
          AND reconciler.args->>'target_job_id' ~ '^[1-9][0-9]*$'
          AND (
            length(reconciler.args->>'target_job_id') < 19
            OR (
              length(reconciler.args->>'target_job_id') = 19
              AND (reconciler.args->>'target_job_id') COLLATE "C"
                <= '#{@max_bigint}' COLLATE "C"
            )
          )
          AND jsonb_typeof(reconciler.args->'wake_generation') = 'number'
          AND reconciler.args->>'wake_generation' ~ '^[1-9][0-9]*$'
          AND (
            length(reconciler.args->>'wake_generation') < 19
            OR (
              length(reconciler.args->>'wake_generation') = 19
              AND (reconciler.args->>'wake_generation') COLLATE "C"
                <= '#{@max_bigint}' COLLATE "C"
            )
          )
        ) IS NOT TRUE
      ) THEN
        RAISE EXCEPTION 'invalid active wake reconciler generation'
          USING ERRCODE = '22023';
      END IF;
    END
    $guard$
    """)
  end

  defp backfill_wake_generations do
    execute("""
    WITH active_reconciler_generations AS (
      SELECT
        target.id AS target_id,
        max((reconciler.args->>'wake_generation')::bigint) AS active_requested
      FROM jobs.job_submissions AS submission
      JOIN jobs.oban_jobs AS target
        ON target.id::text = submission.runner_job_id
       AND target.worker = '#{@generic_worker}'
      JOIN jobs.oban_jobs AS reconciler
        ON reconciler.worker = '#{@wake_reconciler}'
       AND reconciler.state IN (#{quoted_active_states()})
       AND reconciler.args->>'target_job_id' = target.id::text
      GROUP BY target.id
    ),
    backfill AS (
      SELECT
        submission.id AS submission_id,
        COALESCE(
          (target.meta->>'singularity_wake_requested_generation')::bigint,
          0
        ) AS legacy_requested,
        COALESCE(
          (target.meta->>'singularity_wake_consumed_generation')::bigint,
          0
        ) AS legacy_consumed,
        COALESCE(active.active_requested, 0) AS active_requested
      FROM jobs.job_submissions AS submission
      JOIN jobs.oban_jobs AS target
        ON target.id::text = submission.runner_job_id
       AND target.worker = '#{@generic_worker}'
      LEFT JOIN active_reconciler_generations AS active
        ON active.target_id = target.id
    )
    UPDATE jobs.job_submissions AS submission
    SET
      wake_requested_generation = greatest(
        backfill.legacy_requested,
        backfill.legacy_consumed,
        backfill.active_requested
      ),
      wake_consumed_generation = backfill.legacy_consumed
    FROM backfill
    WHERE submission.id = backfill.submission_id
    """)
  end

  defp quoted_active_states do
    Enum.map_join(@active_states, ", ", &"'#{&1}'")
  end
end
