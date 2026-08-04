defmodule Singularity.Runtime.JobDispatcher do
  @moduledoc false

  @behaviour Singularity.Core.JobHandler

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Runtime.Application, as: RuntimeApplication
  alias Singularity.Runtime.AssetEvents
  alias Singularity.Runtime.Assets.Cleanup
  alias Singularity.Runtime.Assets.ExtractMetadata
  alias Singularity.Runtime.Assets.Finalize
  alias Singularity.Runtime.Assets.ObjectCleanup
  alias Singularity.Runtime.Assets.Verify
  alias Singularity.Runtime.BackupVault
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLease
  alias Singularity.Storage.Jobs.Progress
  alias Singularity.Storage.Jobs.ObanAdapter

  @impl true
  def dependencies do
    dependencies = RuntimeApplication.job_dependencies()

    Map.merge(dependencies, %{
      custodian: custody_adapter(dependencies.authorization.custodian),
      job_progress: Progress,
      key_lease: KeyLease
    })
  end

  @impl true
  def handle(context, %{job_type: "asset_verify"} = envelope),
    do: run_asset_job(context, envelope, Verify)

  def handle(context, %{job_type: "asset_finalize"} = envelope),
    do: run_asset_job(context, envelope, Finalize)

  def handle(context, %{job_type: "asset_metadata"} = envelope),
    do: run_asset_job(context, envelope, ExtractMetadata)

  def handle(context, %{job_type: "asset_cleanup"} = envelope),
    do: run_asset_job(context, envelope, Cleanup)

  def handle(context, %{job_type: "object_cleanup"} = envelope),
    do: ObjectCleanup.run(context, envelope)

  def handle(context, %{job_type: "backup"} = envelope),
    do: BackupVault.run(context, envelope)

  def handle(_context, _envelope), do: {:error, Error.new(:job_failed)}

  @doc false
  @spec wake_waiting(map()) :: :ok | {:error, Error.t()}
  def wake_waiting(%{vault_id: vault_id, limit: limit})
      when is_binary(vault_id) and is_integer(limit) and limit > 0 and limit <= 100 do
    ObanAdapter.wake_vault(%{limit: limit}, vault_id)
  end

  def wake_waiting(_command), do: {:error, Error.new(:invalid)}

  @impl true
  def handle_failure(
        context,
        %JobEnvelope{job_type: "asset_metadata"} = envelope,
        %Error{} = failure,
        _attempt
      )
      when is_map(context) do
    result =
      with assets when assets not in [nil, false] <-
             Map.get(context, :assets),
           authorization when authorization not in [nil, false] <-
             Map.get(context, :authorization),
           authorize when authorize not in [nil, false] <-
             Map.get(context, :authorize),
           transact when is_function(transact, 2) <-
             Map.get(context, :transact) do
        transact.([], fn repo ->
          with :ok <-
                 authorize.check_job(
                   authorization,
                   repo,
                   envelope
                 ) do
            assets.record_metadata_exhaustion(
              repo,
              envelope,
              failure
            )
          end
        end)
      else
        _invalid -> {:error, Error.new(:invalid)}
      end

    notify_after_success(context, envelope, result)
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def handle_failure(
        context,
        %JobEnvelope{job_type: "object_cleanup"} = envelope,
        %Error{code: code, retryable?: retryable?} = failure,
        _attempt
      )
      when is_map(context) and
             (retryable? == true or
                (code == :forbidden and retryable? == false)) do
    with deletions when deletions not in [nil, false] <-
           Map.get(context, :asset_deletions),
         transact when is_function(transact, 2) <-
           Map.get(context, :transact) do
      transact.([], fn repo ->
        deletions.reschedule_orphan_delete(
          repo,
          envelope,
          failure
        )
      end)
    else
      _invalid -> {:error, Error.new(:invalid)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  @impl true
  def handle_failure(
        context,
        %JobEnvelope{job_type: job_type} = envelope,
        %Error{} = failure,
        _attempt
      )
      when job_type in [
             "asset_verify",
             "asset_finalize",
             "asset_cleanup"
           ] and is_map(context) do
    result =
      with assets when assets not in [nil, false] <-
             Map.get(context, :assets),
           authorization when authorization not in [nil, false] <-
             Map.get(context, :authorization),
           authorize when authorize not in [nil, false] <-
             Map.get(context, :authorize),
           transact when is_function(transact, 2) <-
             Map.get(context, :transact) do
        transact.([], fn repo ->
          with :ok <-
                 authorize.check_job(
                   authorization,
                   repo,
                   envelope
                 ) do
            assets.record_job_failure(
              repo,
              envelope,
              failure
            )
          end
        end)
      else
        _invalid -> {:error, Error.new(:invalid)}
      end

    notify_after_success(context, envelope, result)
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def handle_failure(_context, _envelope, _failure, _attempt),
    do: {:error, Error.new(:invalid)}

  defp run_asset_job(context, envelope, handler) do
    context
    |> handler.run(envelope)
    |> then(&notify_after_success(context, envelope, &1))
  end

  defp notify_after_success(context, envelope, :ok = result) do
    publish_asset_change(context, envelope)
    result
  end

  defp notify_after_success(context, envelope, {:ok, _value} = result) do
    publish_asset_change(context, envelope)
    result
  end

  defp notify_after_success(
         context,
         envelope,
         {:snooze, seconds} = result
       )
       when is_integer(seconds) and seconds > 0 do
    publish_asset_change(context, envelope)
    result
  end

  defp notify_after_success(_context, _envelope, result), do: result

  defp publish_asset_change(
         context,
         %{
           vault_id: vault_id,
           payload: %{"asset_id" => asset_id}
         }
       )
       when is_map(context) do
    events = Map.get(context, :asset_events, AssetEvents)

    with true <- events not in [nil, false],
         {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         {:ok, asset_id} <- Ecto.UUID.cast(asset_id) do
      _notification =
        call_adapter(events, :publish, [vault_id, asset_id])

      :ok
    else
      _invalid -> :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp publish_asset_change(_context, _envelope), do: :ok

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, adapter_context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [adapter_context | arguments])

  defp custody_adapter({module, _context} = adapter)
       when is_atom(module) and not is_nil(module),
       do: adapter

  defp custody_adapter(server) when is_pid(server) or is_atom(server),
    do: {KeyCustodian, server}
end
