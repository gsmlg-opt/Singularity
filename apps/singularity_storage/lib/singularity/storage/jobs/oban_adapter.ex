defmodule Singularity.Storage.Jobs.WakeReconciler do
  @moduledoc false

  use Oban.Worker, queue: :maintenance, max_attempts: 100

  alias Singularity.Core.Error
  alias Singularity.Storage.Jobs.EnvelopeCodec
  alias Singularity.Storage.Jobs.WakeHandshake
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.WorkerRepo

  @impl Oban.Worker
  def perform(%Oban.Job{
        conf: %Oban.Config{
          name: oban_name,
          prefix: prefix,
          repo: WorkerRepo
        },
        args: %{
          "envelope" => encoded,
          "target_job_id" => target_job_id,
          "wake_generation" => wake_generation
        }
      })
      when is_binary(prefix) and is_map(encoded) and is_integer(target_job_id) and
             target_job_id > 0 and
             is_integer(wake_generation) and wake_generation > 0 do
    with {:ok, envelope} <- EnvelopeCodec.decode(encoded) do
      ScopedRepo.transact(WorkerRepo, envelope, fn repo ->
        case WakeHandshake.reconcile(
               repo,
               prefix,
               envelope,
               target_job_id,
               wake_generation
             ) do
          {:retry, target_job} ->
            Oban.retry_job(oban_name, target_job)

          :wait ->
            {:snooze, 1}

          :done ->
            :ok

          {:error, %Error{}} = error ->
            error
        end
      end)
    else
      {:error, %Error{}} -> {:cancel, %{code: :job_failed}}
    end
  rescue
    _error -> {:error, %{code: :storage_unavailable}}
  end

  def perform(_job), do: {:cancel, %{code: :job_failed}}
end

defmodule Singularity.Storage.Jobs.ObanAdapter do
  @moduledoc false

  @behaviour Singularity.Core.JobRunner

  import Ecto.Query

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Storage.Jobs.EnvelopeCodec
  alias Singularity.Storage.Jobs.GenericWorker
  alias Singularity.Storage.Jobs.WakeHandshake
  alias Singularity.Storage.Jobs.WakeReconciler
  alias Singularity.Storage.Schema.Jobs.JobSubmission
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.WorkerRepo

  @queues %{
    "asset_finalize" => :asset_finalize,
    "asset_verify" => :asset_verify,
    "asset_metadata" => :asset_metadata,
    "asset_cleanup" => :asset_cleanup,
    "object_cleanup" => :object_cleanup,
    "backup" => :backup,
    "maintenance" => :maintenance,
    "integrity_audit" => :maintenance
  }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    configured = Application.fetch_env!(:singularity_storage, Oban)
    oban_options = Keyword.merge(configured, options)
    Supervisor.child_spec({Oban, oban_options}, id: __MODULE__)
  end

  @impl true
  def submit(context, %JobEnvelope{} = envelope) do
    with {:ok, encoded} <- EnvelopeCodec.encode(envelope),
         {:ok, queue} <- Map.fetch(@queues, envelope.job_type),
         {:ok, %{oban_name: oban_name, repo: repo}} <- adapter_context(context) do
      ScopedRepo.transact(repo, envelope, fn scoped_repo ->
        with {:ok, submission} <- reserve(scoped_repo, envelope),
             {:ok, runner_job_id} <-
               ensure_runner_job(scoped_repo, oban_name, submission, encoded, queue) do
          {:ok, runner_job_id}
        end
      end)
      |> map_database_result()
    else
      :error -> {:error, Error.new(:job_failed)}
      {:error, %Error{}} = error -> error
    end
  end

  def submit(_context, _envelope), do: {:error, Error.new(:job_failed)}

  @impl true
  def wake_vault(context, vault_id) when is_binary(vault_id) do
    with {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         {:ok, %{oban_name: oban_name, prefix: prefix, repo: repo}} <-
           adapter_context(context) do
      query =
        from(job in Oban.Job,
          where:
            job.state in ["executing", "scheduled", "retryable"] and
              job.worker == ^Oban.Worker.to_string(GenericWorker) and
              fragment("?->>'vault_id' = ?", job.args, ^vault_id)
        )

      query
      |> repo.all(prefix: prefix)
      |> Enum.reduce_while(:ok, fn job, :ok ->
        case wake_waiting_job(repo, oban_name, prefix, vault_id, job) do
          result when result in [:ok, :skipped] -> {:cont, :ok}
          {:error, %Error{}} = error -> {:halt, error}
        end
      end)
    else
      :error -> {:error, Error.new(:invalid)}
      {:error, %Error{}} = error -> error
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def wake_vault(_context, _vault_id), do: {:error, Error.new(:invalid)}

  defp reserve(repo, envelope) do
    now = DateTime.utc_now()

    attrs = %{
      id: envelope.job_id,
      vault_id: envelope.vault_id,
      outbox_event_id: envelope.job_id,
      classification: envelope.classification,
      idempotency_key: envelope.idempotency_key,
      job_type: envelope.job_type,
      inserted_at: now,
      updated_at: now
    }

    case repo.insert_all(
           JobSubmission,
           [attrs],
           on_conflict: :nothing,
           conflict_target: [:outbox_event_id]
         ) do
      {count, _rows} when count in [0, 1] ->
        submission =
          repo.one(
            from(submission in JobSubmission,
              where:
                submission.outbox_event_id == ^envelope.job_id and
                  submission.vault_id == ^envelope.vault_id,
              lock: "FOR UPDATE"
            )
          )

        validate_submission(submission, envelope)
    end
  end

  defp validate_submission(
         %JobSubmission{
           id: id,
           outbox_event_id: outbox_event_id,
           vault_id: vault_id,
           classification: classification,
           idempotency_key: idempotency_key,
           job_type: job_type
         } = submission,
         envelope
       )
       when id == envelope.job_id and outbox_event_id == envelope.job_id and
              vault_id == envelope.vault_id and classification == envelope.classification and
              idempotency_key == envelope.idempotency_key and job_type == envelope.job_type,
       do: {:ok, submission}

  defp validate_submission(_submission, _envelope),
    do: {:error, Error.new(:conflict)}

  defp ensure_runner_job(
         _repo,
         _oban_name,
         %JobSubmission{runner_job_id: runner_job_id},
         _encoded,
         _queue
       )
       when is_binary(runner_job_id) and byte_size(runner_job_id) > 0,
       do: {:ok, runner_job_id}

  defp ensure_runner_job(repo, oban_name, submission, encoded, queue) do
    job =
      GenericWorker.new(encoded,
        queue: queue,
        unique: [period: :infinity, states: :all]
      )

    with {:ok, %Oban.Job{id: id}} when is_integer(id) <- Oban.insert(oban_name, job),
         runner_job_id = Integer.to_string(id),
         {:ok, _submission} <-
           submission
           |> JobSubmission.record_runner_changeset(%{runner_job_id: runner_job_id})
           |> repo.update() do
      {:ok, runner_job_id}
    else
      {:error, _reason} -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp wake_waiting_job(repo, oban_name, prefix, vault_id, %Oban.Job{} = job) do
    with {:ok, envelope} <- EnvelopeCodec.decode(job.args),
         true <- envelope.vault_id == vault_id do
      ScopedRepo.transact(repo, envelope, fn scoped_repo ->
        case WakeHandshake.request(scoped_repo, prefix, envelope, job.id) do
          {:ok, %{generation: generation, state: "executing"}} ->
            enqueue_wake_reconciler(oban_name, envelope, job.id, generation)

          {:ok, %{state: state}} when state in ["scheduled", "retryable"] ->
            with :pending <-
                   WakeHandshake.consume(scoped_repo, prefix, envelope, job.id),
                 :ok <- Oban.retry_job(oban_name, job) do
              :ok
            end

          :skipped ->
            :skipped

          {:error, %Error{}} = error ->
            error
        end
      end)
    else
      _invalid -> :skipped
    end
  end

  defp enqueue_wake_reconciler(oban_name, envelope, target_job_id, generation) do
    with {:ok, encoded} <- EnvelopeCodec.encode(envelope),
         job =
           WakeReconciler.new(
             %{
               "envelope" => encoded,
               "target_job_id" => target_job_id,
               "wake_generation" => generation
             },
             schedule_in: 1,
             unique: [
               period: :infinity,
               states: :all,
               keys: [:target_job_id, :wake_generation]
             ]
           ),
         {:ok, %Oban.Job{}} <- Oban.insert(oban_name, job) do
      :ok
    else
      _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp adapter_context(context) do
    repo = context_value(context, :repo, WorkerRepo)
    oban_name = context_value(context, :oban_name, Singularity.Oban)

    case Oban.config(oban_name) do
      %Oban.Config{prefix: prefix, repo: WorkerRepo}
      when repo == WorkerRepo and is_binary(prefix) ->
        {:ok, %{oban_name: oban_name, prefix: prefix, repo: WorkerRepo}}

      _unsupported ->
        {:error, Error.new(:invalid)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp context_value(context, key, default) when is_map(context),
    do: Map.get(context, key, default)

  defp context_value(context, key, default) when is_list(context),
    do: Keyword.get(context, key, default)

  defp context_value(_context, _key, default), do: default

  defp map_database_result({:ok, runner_job_id}) when is_binary(runner_job_id),
    do: {:ok, runner_job_id}

  defp map_database_result({:error, %Error{}} = error), do: error

  defp map_database_result(_result),
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
