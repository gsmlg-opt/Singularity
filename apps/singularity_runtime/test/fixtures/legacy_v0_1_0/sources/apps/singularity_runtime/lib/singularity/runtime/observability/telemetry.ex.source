defmodule Singularity.Runtime.Observability.Telemetry do
  @moduledoc """
  Owns Singularity's backend-neutral telemetry contract.

  Runtime operations emit numeric measurements and bounded metadata through
  this module. The supervised process owns the lifecycle of handlers that
  derive safe Singularity events from Oban events.

  No reporter or exporter is started here. Reporters consume `metrics/0` at
  the application boundary.
  """

  use GenServer

  import Telemetry.Metrics

  alias Singularity.Runtime.Observability.Redactor

  @handler_id __MODULE__
  @oban_events [
    [:oban, :job, :exception],
    [:oban, :job, :stop]
  ]
  @source_events @oban_events
  @generic_worker "Elixir.Singularity.Storage.Jobs.GenericWorker"
  @queues %{
    "asset_finalize" => :asset_finalize,
    :asset_finalize => :asset_finalize,
    "asset_verify" => :asset_verify,
    :asset_verify => :asset_verify,
    "asset_metadata" => :asset_metadata,
    :asset_metadata => :asset_metadata,
    "asset_cleanup" => :asset_cleanup,
    :asset_cleanup => :asset_cleanup,
    "object_cleanup" => :object_cleanup,
    :object_cleanup => :object_cleanup,
    "note_projection" => :note_projection,
    :note_projection => :note_projection,
    "backup" => :backup,
    :backup => :backup
  }
  @sensitive_keys MapSet.new([
                    :password,
                    :passphrase,
                    :token,
                    :csrf,
                    :audit_fingerprint_secret,
                    :vault_key,
                    :domain_key,
                    :domain_dedup_key,
                    :dek,
                    :object_key,
                    :object_keys,
                    :plaintext,
                    :authorization,
                    :cookie,
                    :path,
                    :mutation_fingerprint_secret,
                    :title,
                    :note_title,
                    :markdown,
                    :raw_search_query,
                    :rendered_html,
                    :export_bytes,
                    "password",
                    "passphrase",
                    "token",
                    "csrf",
                    "audit_fingerprint_secret",
                    "vault_key",
                    "domain_key",
                    "domain_dedup_key",
                    "dek",
                    "object_key",
                    "object_keys",
                    "plaintext",
                    "authorization",
                    "cookie",
                    "path",
                    "mutation_fingerprint_secret",
                    "title",
                    "note_title",
                    "markdown",
                    "raw_search_query",
                    "rendered_html",
                    "export_bytes"
                  ])

  @type event_suffix :: [atom()]

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: Keyword.get(options, :id, __MODULE__),
      start: {__MODULE__, :start_link, [options]},
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) when is_list(options) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name_option(name))
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    handler_id = Keyword.get(options, :handler_id, @handler_id)
    source_events = Keyword.get(options, :source_events, @source_events)

    :telemetry.detach(handler_id)

    case :telemetry.attach_many(
           handler_id,
           source_events,
           &__MODULE__.handle_event/4,
           nil
         ) do
      :ok ->
        {:ok, %{handler_id: handler_id}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
  end

  @doc """
  Emits a prefixed event only when every measurement is numeric.

  Instrumentation is deliberately failure-isolated: invalid or malformed
  telemetry is dropped rather than changing the result of a domain operation.
  """
  @spec execute(event_suffix(), map(), map()) :: :ok
  def execute(event, measurements, metadata \\ %{})

  def execute(event, measurements, metadata)
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    if valid_event?(event) and numeric_measurements?(measurements) do
      :telemetry.execute(
        [:singularity | event],
        measurements,
        redact_metadata(metadata)
      )
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  def execute(_event, _measurements, _metadata), do: :ok

  @doc """
  Measures an operation without exposing callback results or exceptions.

  The callback result is returned unchanged. Stop/exception metadata contains
  only the caller's redacted metadata plus bounded outcome atoms.
  """
  @spec span(event_suffix(), map(), (-> result)) :: result when result: term()
  def span(event, metadata, callback)
      when is_list(event) and is_map(metadata) and is_function(callback, 0) do
    started_at = System.monotonic_time()

    execute(
      event ++ [:start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result = callback.()
      duration = System.monotonic_time() - started_at

      execute(
        event ++ [:stop],
        %{duration: duration},
        Map.put(metadata, :result, result_category(result))
      )

      emit_integrity_failure(event, result)
      result
    rescue
      exception ->
        emit_exception(event, metadata, started_at, :error)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        emit_exception(event, metadata, started_at, bounded_kind(kind))
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "Returns the stable metric definitions consumed by a reporter."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      sum("singularity.upload.stop.bytes",
        unit: :byte,
        description: "Durably sealed plaintext upload bytes"
      ),
      summary("singularity.upload.stop.duration",
        unit: {:native, :millisecond},
        description: "Durably sealed upload latency"
      ),
      counter("singularity.asset.dedup.count",
        tags: [:outcome],
        description: "Canonical object publish and reuse outcomes"
      ),
      counter("singularity.integrity.failure.count",
        tags: [:operation],
        description: "Integrity failures at runtime operation boundaries"
      ),
      summary("singularity.outbox.dispatch.lag",
        unit: {:native, :millisecond},
        tags: [:job_type],
        description: "Outbox occurrence to durable runner acknowledgement"
      ),
      counter("singularity.job.retry.count",
        tags: [:queue],
        description: "Retryable durable job failures"
      ),
      counter("singularity.job.failure.count",
        tags: [:queue],
        description: "Terminal durable job failures"
      ),
      counter("singularity.authentication.audit_write_failure.count",
        description: "Authentication audit persistence failures"
      ),
      counter("singularity.authorization.rls_denial.count",
        tags: [:repo],
        description: "PostgreSQL insufficient-privilege denials"
      ),
      summary("singularity.vault.unlock.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result],
        description: "Vault unlock operation latency"
      ),
      summary("singularity.backup.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result],
        description: "Backup worker operation latency"
      ),
      summary("singularity.restore.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result],
        description: "Restore operation latency"
      ),
      counter("singularity.orphan.cleanup.count",
        tags: [:outcome],
        description: "Durably acknowledged orphan deletion outcomes"
      ),
      sum("singularity.upload.reconciliation.count",
        tags: [:outcome],
        description: "Open upload stages reconciled after restart"
      ),
      summary("singularity.upload.reconciliation.stage.age",
        unit: :millisecond,
        tags: [:outcome],
        description: "Durable age of upload stages observed during restart recovery"
      )
    ]
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(
        [:oban, :job, :exception],
        _measurements,
        metadata,
        _config
      )
      when is_map(metadata) do
    with true <- generic_worker?(metadata),
         {:ok, attempt, max_attempts} <- attempts(metadata) do
      suffix =
        if attempt < max_attempts,
          do: [:job, :retry],
          else: [:job, :failure]

      execute(
        suffix,
        %{count: 1},
        safe_job_metadata(metadata, attempt, max_attempts)
      )
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  def handle_event(
        [:oban, :job, :stop],
        _measurements,
        %{state: state} = metadata,
        _config
      )
      when state in [:cancelled, :discard] do
    with true <- generic_worker?(metadata),
         {:ok, attempt, max_attempts} <- attempts(metadata) do
      execute(
        [:job, :failure],
        %{count: 1},
        safe_job_metadata(metadata, attempt, max_attempts)
      )
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp emit_integrity_failure(
         event,
         {:error, %{__struct__: Singularity.Core.Error, code: :integrity_failure}}
       ) do
    execute(
      [:integrity, :failure],
      %{count: 1},
      %{operation: operation_label(event)}
    )
  end

  defp emit_integrity_failure(_event, _result), do: :ok

  defp emit_exception(event, metadata, started_at, kind) do
    execute(
      event ++ [:exception],
      %{duration: System.monotonic_time() - started_at},
      metadata
      |> Map.put(:kind, kind)
      |> Map.put(:result, :exception)
    )
  end

  defp valid_event?(event),
    do: event != [] and Enum.all?(event, &is_atom/1)

  defp numeric_measurements?(measurements),
    do: Enum.all?(measurements, fn {_key, value} -> is_number(value) end)

  defp redact_metadata(metadata) do
    if Code.ensure_loaded?(Redactor) and function_exported?(Redactor, :redact, 1) do
      apply(Redactor, :redact, [metadata])
    else
      fallback_redact(metadata)
    end
  end

  defp fallback_redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if MapSet.member?(@sensitive_keys, key),
        do: {key, "[REDACTED]"},
        else: {key, fallback_redact(nested)}
    end)
  end

  defp fallback_redact(value) when is_list(value), do: Enum.map(value, &fallback_redact/1)

  defp fallback_redact(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&fallback_redact/1) |> List.to_tuple()

  defp fallback_redact(value), do: value

  defp result_category(:ok), do: :ok
  defp result_category({:ok, _value}), do: :ok
  defp result_category({:snooze, _seconds}), do: :snoozed
  defp result_category({:error, _reason}), do: :error
  defp result_category(_result), do: :unknown

  defp bounded_kind(kind) when kind in [:exit, :throw], do: kind
  defp bounded_kind(_kind), do: :error

  defp operation_label([:asset, :verify]), do: :asset_verify
  defp operation_label([:backup]), do: :backup
  defp operation_label([:restore]), do: :restore
  defp operation_label([:vault, :unlock]), do: :vault_unlock
  defp operation_label(_event), do: :runtime_operation

  defp generic_worker?(metadata) do
    worker =
      Map.get(metadata, :worker) ||
        get_in(metadata, [:job, Access.key(:worker)])

    worker in [Singularity.Storage.Jobs.GenericWorker, @generic_worker]
  end

  defp attempts(metadata) do
    attempt =
      Map.get(metadata, :attempt) ||
        get_in(metadata, [:job, Access.key(:attempt)])

    max_attempts =
      Map.get(metadata, :max_attempts) ||
        get_in(metadata, [:job, Access.key(:max_attempts)])

    if is_integer(attempt) and attempt > 0 and
         is_integer(max_attempts) and max_attempts > 0 do
      {:ok, attempt, max_attempts}
    else
      :error
    end
  end

  defp safe_job_metadata(metadata, attempt, max_attempts) do
    queue =
      Map.get(metadata, :queue) ||
        get_in(metadata, [:job, Access.key(:queue)])

    %{
      attempt: attempt,
      max_attempts: max_attempts,
      queue: Map.get(@queues, queue, :unknown),
      worker: :generic_worker
    }
  end

  defp name_option(nil), do: []
  defp name_option(name), do: [name: name]
end
