defmodule Singularity.Runtime.OutboxDispatcher do
  @moduledoc false

  use GenServer

  alias Singularity.Storage.SafeSQL, as: SQL
  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.OutboxEvent
  alias Singularity.Runtime.Observability.Telemetry

  @event_jobs %{
    "asset.finalize_requested" => "asset_finalize",
    "asset.verify_requested" => "asset_verify",
    "asset.metadata_requested" => "asset_metadata",
    "asset.cleanup_requested" => "asset_cleanup",
    "object.cleanup_requested" => "object_cleanup",
    "note.current_changed" => "note_projection",
    "note.conflict_created" => "note_projection",
    "note.conflict_resolved" => "note_projection",
    "note.deleted" => "note_projection",
    "note.restored" => "note_projection",
    "backup.requested" => "backup"
  }

  @default_interval_ms 1_000
  @default_batch_size 25
  @default_lease_seconds 30

  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(options) do
    options = normalize_options(options)
    name = Map.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec dispatch_once(GenServer.server() | keyword() | map()) ::
          {:ok, map()} | {:error, Error.t()}
  def dispatch_once(options) when is_map(options) or is_list(options) do
    options
    |> normalize_options()
    |> run_once()
  end

  def dispatch_once(server), do: GenServer.call(server, :dispatch_once, :infinity)

  @impl true
  def init(options) do
    options = validate_options!(options)
    schedule(options)
    {:ok, options}
  end

  @impl true
  def handle_call(:dispatch_once, _from, options) do
    {:reply, run_once(options), options}
  end

  @impl true
  def handle_info(:dispatch, options) do
    _result = run_once(options)
    schedule(options)
    {:noreply, options}
  end

  defp run_once(options) do
    options = validate_options!(options)
    claim_token = Ecto.UUID.generate()

    claim_options = %{
      limit: options.batch_size,
      lease_seconds: options.lease_seconds,
      claim_token: claim_token
    }

    with {:ok, events} <- options.outbox.claim(options.outbox_context, claim_options) do
      summary =
        Enum.reduce(events, %{submitted: 0, skipped: 0, failed: 0}, fn event, summary ->
          dispatch_event(event, claim_token, options, summary)
        end)

      {:ok, summary}
    end
  end

  defp dispatch_event(event, claim_token, options, summary) do
    case with_dispatch_shared_lock(options.outbox_context, event.vault_id, fn ->
           submit_and_acknowledge(event, claim_token, options, summary)
         end) do
      :busy ->
        Map.update!(summary, :skipped, &(&1 + 1))

      {:ok, summary} ->
        summary
    end
  end

  defp submit_and_acknowledge(event, claim_token, options, summary) do
    with {:ok, envelope} <- envelope(event),
         {:ok, runner_job_id} <-
           options.job_runner.submit(options.job_runner_context, envelope),
         :ok <- options.after_submit.(envelope, runner_job_id),
         :ok <-
           options.outbox.acknowledge(options.outbox_context, event.outbox_event_id, %{
             claim_token: claim_token,
             runner_job_id: runner_job_id
           }) do
      emit_dispatch_lag(event)
      Map.update!(summary, :submitted, &(&1 + 1))
    else
      {:error, %Error{}} -> Map.update!(summary, :failed, &(&1 + 1))
    end
  end

  defp envelope(%OutboxEvent{} = event) do
    with {:ok, job_type} <- Map.fetch(@event_jobs, event.event_type),
         {:ok, payload} <- envelope_payload(job_type, event.payload) do
      JobEnvelope.new(%{
        version: 1,
        job_id: event.outbox_event_id,
        job_type: job_type,
        idempotency_key: event.idempotency_key,
        vault_id: event.vault_id,
        principal_id: event.principal_id,
        required_capability: event.required_capability,
        principal_authorization_epoch: event.principal_authorization_epoch,
        vault_authorization_epoch: event.vault_authorization_epoch,
        classification: event.classification,
        correlation_id: event.correlation_id,
        causation_id: event.causation_id,
        expected_entity_revision: event.expected_entity_revision,
        attempt: 0,
        payload: payload
      })
    else
      :error -> {:error, Error.new(:job_failed)}
      {:error, %Error{}} = error -> error
    end
  end

  defp envelope_payload("note_projection", %{"resource_id" => resource_id})
       when is_binary(resource_id),
       do: {:ok, %{"resource_id" => resource_id}}

  defp envelope_payload("note_projection", _payload), do: {:error, Error.new(:job_failed)}
  defp envelope_payload(_job_type, payload) when is_map(payload), do: {:ok, payload}
  defp envelope_payload(_job_type, _payload), do: {:error, Error.new(:job_failed)}

  defp with_dispatch_shared_lock(repo, vault_id, fun) do
    key = "singularity:vault:" <> uuid!(vault_id)

    repo.checkout(fn ->
      %{rows: [[acquired?]]} =
        SQL.query!(
          repo,
          "SELECT pg_try_advisory_lock_shared(hashtextextended($1::text, 0))",
          [key],
          log: false
        )

      if acquired? do
        try do
          {:ok, fun.()}
        after
          %{rows: [[true]]} =
            SQL.query!(
              repo,
              "SELECT pg_advisory_unlock_shared(hashtextextended($1::text, 0))",
              [key],
              log: false
            )
        end
      else
        :busy
      end
    end)
  end

  defp validate_options!(options) do
    required = [:outbox, :outbox_context, :job_runner, :job_runner_context, :after_submit]

    if Enum.all?(required, &Map.has_key?(options, &1)) and
         is_integer(options.batch_size) and options.batch_size in 1..100 and
         is_integer(options.lease_seconds) and options.lease_seconds in 1..3600 and
         is_integer(options.interval_ms) and options.interval_ms > 0 and
         is_function(options.after_submit, 2) do
      options
    else
      raise ArgumentError, "invalid outbox dispatcher composition"
    end
  end

  defp normalize_options(options) when is_list(options),
    do: options |> Map.new() |> normalize_options()

  defp normalize_options(options) when is_map(options) do
    options
    |> Map.put_new(:outbox, Singularity.Storage.Postgres.Outbox)
    |> Map.put_new(:outbox_context, Singularity.Storage.DispatcherRepo)
    |> Map.put_new(:job_runner, Singularity.Storage.Jobs.ObanAdapter)
    |> Map.put_new(:job_runner_context, %{})
    |> Map.put_new(:batch_size, @default_batch_size)
    |> Map.put_new(:lease_seconds, @default_lease_seconds)
    |> Map.put_new(:interval_ms, @default_interval_ms)
    |> Map.put_new(:after_submit, fn _envelope, _runner_job_id -> :ok end)
  end

  defp schedule(options),
    do: Process.send_after(self(), :dispatch, options.interval_ms)

  defp uuid!(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "outbox event vault must be a valid UUID"
    end
  end

  defp emit_dispatch_lag(%OutboxEvent{event_type: event_type, occurred_at: occurred_at}) do
    lag =
      DateTime.utc_now(:microsecond)
      |> DateTime.diff(occurred_at, :microsecond)
      |> max(0)
      |> System.convert_time_unit(:microsecond, :native)

    Telemetry.execute(
      [:outbox, :dispatch],
      %{lag: lag},
      %{job_type: job_type_label(event_type)}
    )
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp job_type_label("asset.finalize_requested"), do: :asset_finalize
  defp job_type_label("asset.verify_requested"), do: :asset_verify
  defp job_type_label("asset.metadata_requested"), do: :asset_metadata
  defp job_type_label("asset.cleanup_requested"), do: :asset_cleanup
  defp job_type_label("object.cleanup_requested"), do: :object_cleanup

  defp job_type_label(event_type)
       when event_type in [
              "note.current_changed",
              "note.conflict_created",
              "note.conflict_resolved",
              "note.deleted",
              "note.restored"
            ],
       do: :note_projection

  defp job_type_label("backup.requested"), do: :backup
  defp job_type_label(_event_type), do: :unknown
end
