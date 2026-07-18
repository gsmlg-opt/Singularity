defmodule Singularity.Storage.Jobs.Progress do
  @moduledoc false

  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Storage.Schema.Jobs.EffectReceipt
  alias Singularity.Storage.Schema.Jobs.JobProgress

  @states [
    :pending,
    :running,
    :waiting_for_unlock,
    :waiting_for_backup_key,
    :completed,
    :failed
  ]

  @spec record_effect(module(), JobEnvelope.t(), map()) ::
          {:ok, EffectReceipt.t()} | {:error, Error.t()}
  def record_effect(
        repo,
        %JobEnvelope{} = envelope,
        %{
          effect_key: effect_key,
          result: result,
          entity_revision: entity_revision
        }
      )
      when is_binary(effect_key) and byte_size(effect_key) > 0 and
             result in [:applied, :stale] and is_integer(entity_revision) and
             entity_revision >= 0 do
    now = DateTime.utc_now()

    attrs = %{
      id: Ecto.UUID.generate(),
      vault_id: envelope.vault_id,
      submission_id: envelope.job_id,
      classification: envelope.classification,
      effect_key: effect_key,
      result: result,
      entity_revision: entity_revision,
      inserted_at: now
    }

    case repo.insert_all(
           EffectReceipt,
           [attrs],
           on_conflict: :nothing,
           conflict_target: [:vault_id, :effect_key]
         ) do
      {count, _rows} when count in [0, 1] ->
        receipt =
          repo.one(
            from(receipt in EffectReceipt,
              where:
                receipt.vault_id == ^envelope.vault_id and
                  receipt.effect_key == ^effect_key,
              lock: "FOR UPDATE"
            )
          )

        validate_receipt(receipt, envelope, effect_key)
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.ConstraintError, Postgrex.Error] ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def record_effect(_repo, _envelope, _attrs), do: {:error, Error.new(:invalid)}

  @spec put_state(module(), JobEnvelope.t(), atom(), map()) ::
          {:ok, JobProgress.t()} | {:error, Error.t()}
  def put_state(repo, envelope, state, options \\ %{})

  def put_state(repo, %JobEnvelope{} = envelope, state, options)
      when state in @states and is_map(options) do
    attrs = %{
      id: Ecto.UUID.generate(),
      vault_id: envelope.vault_id,
      submission_id: envelope.job_id,
      classification: envelope.classification,
      state: state,
      processing_revision: Map.get(options, :processing_revision, 0),
      checkpoint_version: Map.get(options, :checkpoint_version, 1),
      checkpoint: Map.get(options, :checkpoint, %{})
    }

    changeset = JobProgress.create_changeset(%JobProgress{}, attrs)

    case repo.insert(
           changeset,
           on_conflict: [
             set: [
               state: state,
               processing_revision: attrs.processing_revision,
               checkpoint_version: attrs.checkpoint_version,
               checkpoint: attrs.checkpoint,
               updated_at: DateTime.utc_now()
             ]
           ],
           conflict_target: [:submission_id],
           returning: true
         ) do
      {:ok, progress} -> validate_progress(progress, envelope)
      {:error, %Ecto.Changeset{}} -> {:error, Error.new(:invalid)}
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.ConstraintError, Postgrex.Error] ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def put_state(_repo, _envelope, _state, _options), do: {:error, Error.new(:invalid)}

  defp validate_receipt(
         %EffectReceipt{
           vault_id: vault_id,
           submission_id: submission_id,
           classification: classification,
           effect_key: effect_key
         } = receipt,
         envelope,
         effect_key
       )
       when vault_id == envelope.vault_id and submission_id == envelope.job_id and
              classification == envelope.classification,
       do: {:ok, receipt}

  defp validate_receipt(_receipt, _envelope, _effect_key),
    do: {:error, Error.new(:conflict)}

  defp validate_progress(
         %JobProgress{
           vault_id: vault_id,
           submission_id: submission_id,
           classification: classification
         } = progress,
         envelope
       )
       when vault_id == envelope.vault_id and submission_id == envelope.job_id and
              classification == envelope.classification,
       do: {:ok, progress}

  defp validate_progress(_progress, _envelope), do: {:error, Error.new(:conflict)}
end

defmodule Singularity.Storage.Jobs.WakeHandshake do
  @moduledoc false

  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Storage.Schema.Jobs.JobProgress
  alias Singularity.Storage.Schema.Jobs.JobSubmission

  @generic_worker "Singularity.Storage.Jobs.GenericWorker"
  @requested_key "singularity_wake_requested_generation"
  @consumed_key "singularity_wake_consumed_generation"
  @wakeable_states ["executing", "scheduled", "retryable"]

  @spec request(module(), String.t(), JobEnvelope.t(), pos_integer()) ::
          {:ok, %{generation: pos_integer(), state: String.t()}}
          | :skipped
          | {:error, Error.t()}
  def request(repo, prefix, %JobEnvelope{} = envelope, runner_job_id)
      when is_binary(prefix) and is_integer(runner_job_id) and runner_job_id > 0 do
    case lock_job(repo, prefix, envelope, runner_job_id, @wakeable_states) do
      %Oban.Job{state: "executing"} = job ->
        request_generation(repo, job)

      %Oban.Job{} = job ->
        if waiting_for_unlock?(repo, envelope, runner_job_id) do
          request_generation(repo, job)
        else
          :skipped
        end

      nil ->
        :skipped
    end
  end

  def request(_repo, _prefix, _envelope, _runner_job_id),
    do: {:error, Error.new(:invalid)}

  @spec consume(module(), String.t(), JobEnvelope.t(), pos_integer()) ::
          :pending | :none | :skipped | {:error, Error.t()}
  def consume(repo, prefix, %JobEnvelope{} = envelope, runner_job_id)
      when is_binary(prefix) and is_integer(runner_job_id) and runner_job_id > 0 do
    with %Oban.Job{} = job <-
           lock_job(repo, prefix, envelope, runner_job_id, @wakeable_states),
         true <- waiting_for_unlock?(repo, envelope, runner_job_id) do
      requested = generation(job.meta, @requested_key)
      consumed = generation(job.meta, @consumed_key)

      if requested > consumed do
        case put_generation(repo, job, @consumed_key, requested) do
          {:ok, _job} -> :pending
          {:error, %Ecto.Changeset{}} -> storage_unavailable()
        end
      else
        :none
      end
    else
      nil -> :skipped
      false -> :skipped
    end
  end

  def consume(_repo, _prefix, _envelope, _runner_job_id),
    do: {:error, Error.new(:invalid)}

  @spec reconcile(module(), String.t(), JobEnvelope.t(), pos_integer(), pos_integer()) ::
          {:retry, Oban.Job.t()} | :wait | :done | {:error, Error.t()}
  def reconcile(repo, prefix, %JobEnvelope{} = envelope, runner_job_id, wake_generation)
      when is_binary(prefix) and is_integer(runner_job_id) and runner_job_id > 0 and
             is_integer(wake_generation) and wake_generation > 0 do
    case lock_job(repo, prefix, envelope, runner_job_id, :all) do
      nil ->
        :done

      %Oban.Job{} = job ->
        requested = generation(job.meta, @requested_key)
        consumed = generation(job.meta, @consumed_key)

        cond do
          requested < wake_generation ->
            :done

          job.state == "executing" ->
            :wait

          not waiting_for_unlock?(repo, envelope, runner_job_id) ->
            consume_generation(repo, job, wake_generation, :done)

          consumed >= wake_generation ->
            :done

          job.state in ["scheduled", "retryable"] ->
            consume_generation(repo, job, wake_generation, {:retry, job})

          true ->
            consume_generation(repo, job, wake_generation, :done)
        end
    end
  end

  def reconcile(_repo, _prefix, _envelope, _runner_job_id, _wake_generation),
    do: {:error, Error.new(:invalid)}

  defp lock_job(repo, prefix, envelope, runner_job_id, states) do
    query =
      from(job in Oban.Job,
        where:
          job.id == ^runner_job_id and
            job.worker == ^@generic_worker and
            fragment("?->>'job_id' = ?", job.args, ^envelope.job_id) and
            fragment("?->>'vault_id' = ?", job.args, ^envelope.vault_id) and
            fragment("?->>'principal_id' = ?", job.args, ^envelope.principal_id),
        lock: "FOR UPDATE"
      )

    query =
      if states == :all do
        query
      else
        where(query, [job], job.state in ^states)
      end

    repo.one(query, prefix: prefix)
  end

  defp waiting_for_unlock?(repo, envelope, runner_job_id) do
    query =
      from(progress in JobProgress,
        join: submission in JobSubmission,
        on:
          submission.id == progress.submission_id and
            submission.vault_id == progress.vault_id,
        where:
          progress.submission_id == ^envelope.job_id and
            progress.vault_id == ^envelope.vault_id and
            progress.state == :waiting_for_unlock and
            submission.runner_job_id == ^Integer.to_string(runner_job_id) and
            submission.job_type == ^envelope.job_type and
            submission.classification == ^envelope.classification,
        select: progress.id,
        limit: 1,
        lock: "FOR UPDATE"
      )

    not is_nil(repo.one(query))
  end

  defp consume_generation(repo, job, wake_generation, result) do
    case put_generation(repo, job, @consumed_key, wake_generation) do
      {:ok, _job} -> result
      {:error, %Ecto.Changeset{}} -> storage_unavailable()
    end
  end

  defp request_generation(repo, job) do
    requested = generation(job.meta, @requested_key)
    consumed = generation(job.meta, @consumed_key)
    next_generation = max(requested, consumed) + 1

    case put_generation(repo, job, @requested_key, next_generation) do
      {:ok, _job} -> {:ok, %{generation: next_generation, state: job.state}}
      {:error, %Ecto.Changeset{}} -> storage_unavailable()
    end
  end

  defp put_generation(repo, job, key, value) do
    job
    |> Ecto.Changeset.change(meta: Map.put(job.meta, key, value))
    |> repo.update()
  end

  defp generation(meta, key) do
    case Map.get(meta, key, 0) do
      generation when is_integer(generation) and generation >= 0 -> generation
      _invalid -> 0
    end
  end

  defp storage_unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
