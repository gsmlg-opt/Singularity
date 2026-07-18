defmodule Singularity.Storage.Jobs.GenericWorker do
  @moduledoc false

  use Oban.Worker

  alias Singularity.Core.Error
  alias Singularity.Storage.Jobs.EnvelopeCodec
  alias Singularity.Storage.Jobs.WakeHandshake
  alias Singularity.Storage.Jobs.WorkerScope

  @reserved_dependency_keys [
    :repo_handle,
    :lock_mode,
    :transact,
    "repo_handle",
    "lock_mode",
    "transact"
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    with {:ok, envelope} <- EnvelopeCodec.decode(args),
         :ok <- validate_authority_context(envelope),
         {:ok, handler} <- configured_handler(),
         {:ok, dependencies} <- dependencies(handler) do
      WorkerScope.run(envelope, fn worker_context ->
        context = Map.merge(dependencies, worker_context)

        context
        |> handler.handle(envelope)
        |> consume_pending_wake(context, envelope, job)
      end)
      |> map_result()
    else
      {:error, %Error{}} -> cancelled()
    end
  end

  def perform(_job), do: cancelled()

  defp configured_handler do
    with {:ok, handler} <- Application.fetch_env(:singularity_storage, :job_handler),
         true <- is_atom(handler),
         {:module, ^handler} <- Code.ensure_loaded(handler),
         true <- function_exported?(handler, :dependencies, 0),
         true <- function_exported?(handler, :handle, 2) do
      {:ok, handler}
    else
      _invalid -> {:error, Error.new(:job_failed)}
    end
  end

  defp dependencies(handler) do
    dependencies = handler.dependencies()

    if is_map(dependencies) and
         Enum.all?(@reserved_dependency_keys, &(not Map.has_key?(dependencies, &1))) do
      {:ok, dependencies}
    else
      {:error, Error.new(:job_failed)}
    end
  rescue
    _error -> {:error, Error.new(:job_failed)}
  catch
    _kind, _reason -> {:error, Error.new(:job_failed)}
  end

  defp validate_authority_context(envelope) do
    with {:ok, _principal_id} <- Ecto.UUID.cast(envelope.principal_id),
         {:ok, _vault_id} <- Ecto.UUID.cast(envelope.vault_id) do
      :ok
    else
      :error -> {:error, Error.new(:job_failed)}
    end
  end

  defp consume_pending_wake(
         {:snooze, seconds} = result,
         context,
         envelope,
         %Oban.Job{id: runner_job_id} = job
       )
       when is_integer(seconds) and seconds > 0 and is_integer(runner_job_id) and
              runner_job_id > 0 do
    prefix = job_prefix(job)

    case context.transact.([], fn repo ->
           WakeHandshake.consume(repo, prefix, envelope, runner_job_id)
         end) do
      :pending -> {:snooze, 1}
      status when status in [:none, :skipped] -> result
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:job_failed)}
    end
  end

  defp consume_pending_wake(result, _context, _envelope, _job), do: result

  defp job_prefix(%Oban.Job{conf: %{prefix: prefix}}) when is_binary(prefix), do: prefix

  defp job_prefix(_job) do
    :singularity_storage
    |> Application.fetch_env!(Oban)
    |> Keyword.fetch!(:prefix)
  end

  defp map_result(:ok), do: :ok
  defp map_result({:ok, _value} = result), do: result

  defp map_result({:snooze, seconds} = result) when is_integer(seconds) and seconds > 0,
    do: result

  defp map_result({:error, %Error{retryable?: true}}),
    do: {:error, %{code: :job_failed}}

  defp map_result({:error, %Error{}}), do: cancelled()
  defp map_result(_result), do: cancelled()

  defp cancelled, do: {:cancel, %{code: :job_failed}}
end
