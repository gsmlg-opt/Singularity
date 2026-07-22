defmodule Singularity.Runtime.JobDispatcher do
  @moduledoc false

  @behaviour Singularity.Core.JobHandler

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Runtime.Application, as: RuntimeApplication
  alias Singularity.Runtime.Assets.Cleanup
  alias Singularity.Runtime.Assets.ExtractMetadata
  alias Singularity.Runtime.Assets.Finalize
  alias Singularity.Runtime.Assets.ObjectCleanup
  alias Singularity.Runtime.Assets.Verify
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
    do: Verify.run(context, envelope)

  def handle(context, %{job_type: "asset_finalize"} = envelope),
    do: Finalize.run(context, envelope)

  def handle(context, %{job_type: "asset_metadata"} = envelope),
    do: ExtractMetadata.run(context, envelope)

  def handle(context, %{job_type: "asset_cleanup"} = envelope),
    do: Cleanup.run(context, envelope)

  def handle(context, %{job_type: "object_cleanup"} = envelope),
    do: ObjectCleanup.run(context, envelope)

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
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def handle_failure(_context, _envelope, _failure, _attempt),
    do: {:error, Error.new(:invalid)}

  defp custody_adapter({module, _context} = adapter)
       when is_atom(module) and not is_nil(module),
       do: adapter

  defp custody_adapter(server) when is_pid(server) or is_atom(server),
    do: {KeyCustodian, server}
end
