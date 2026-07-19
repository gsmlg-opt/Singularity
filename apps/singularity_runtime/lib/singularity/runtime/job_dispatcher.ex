defmodule Singularity.Runtime.JobDispatcher do
  @moduledoc false

  @behaviour Singularity.Core.JobHandler

  alias Singularity.Core.Error
  alias Singularity.Core.JobEnvelope
  alias Singularity.Runtime.Application, as: RuntimeApplication
  alias Singularity.Runtime.Assets.Cleanup
  alias Singularity.Runtime.Assets.Finalize
  alias Singularity.Runtime.Assets.ObjectCleanup
  alias Singularity.Runtime.Assets.Verify

  @impl true
  def dependencies, do: RuntimeApplication.job_dependencies()

  @impl true
  def handle(context, %{job_type: "asset_verify"} = envelope),
    do: Verify.run(context, envelope)

  def handle(context, %{job_type: "asset_finalize"} = envelope),
    do: Finalize.run(context, envelope)

  def handle(context, %{job_type: "asset_cleanup"} = envelope),
    do: Cleanup.run(context, envelope)

  def handle(context, %{job_type: "object_cleanup"} = envelope),
    do: ObjectCleanup.run(context, envelope)

  def handle(_context, _envelope), do: {:error, Error.new(:job_failed)}

  @impl true
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
end
