defmodule Singularity.Runtime.Assets.UploadReconciler do
  @moduledoc """
  Reconciles durable open upload stages left behind by a runtime restart.

  Physical staging bytes are removed before the durable abandonment
  transition. If persistence fails, the open stage remains discoverable and a
  later reconciliation run can safely retry both idempotent steps.
  """

  alias Singularity.Core.Error
  alias Singularity.Core.StageRef
  alias Singularity.Runtime.Observability.Telemetry
  alias Singularity.Runtime.StorageAdapter
  alias Singularity.Storage.Postgres.AssetUploadRecoveryRepository
  alias Singularity.Storage.WorkerRepo

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: :ignore | {:error, Error.t()}
  def start_link(options) when is_list(options) do
    options
    |> Keyword.get(:context, configured_context())
    |> run()
    |> case do
      {:ok, _count} -> :ignore
      {:error, %Error{}} = error -> error
    end
  end

  @doc false
  @spec configured_context() :: map()
  def configured_context do
    %{
      repository: {AssetUploadRecoveryRepository, WorkerRepo},
      storage: StorageAdapter.configured()
    }
  end

  @spec run(map()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def run(context) do
    case do_run(context) do
      {:ok, count} = result when is_integer(count) and count >= 0 ->
        Telemetry.execute(
          [:upload, :reconciliation],
          %{count: count},
          %{outcome: :abandoned}
        )

        result

      other ->
        other
    end
  end

  defp do_run(context) when is_map(context) do
    with {:ok, adapters} <- adapters(context),
         %DateTime{} = abandoned_at <- adapters.clock.(),
         {:ok, stages} <-
           call_adapter(adapters.repository, :list_open_stages, []),
         true <- is_list(stages) do
      reconcile(stages, adapters, abandoned_at, 0)
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp do_run(_context), do: {:error, Error.new(:invalid)}

  @spec reconcile_stage(map(), map(), :runtime_restarted | :custody_revoked) ::
          {:ok, map()} | {:error, Error.t()}
  def reconcile_stage(
        context,
        %{stage_id: stage_id, storage_ref: storage_ref},
        reason
      )
      when is_map(context) and is_binary(stage_id) and
             is_binary(storage_ref) and
             reason in [:runtime_restarted, :custody_revoked] do
    with {:ok, adapters} <- adapters(context),
         %DateTime{} = abandoned_at <- adapters.clock.() do
      reconcile_exact_stage(
        adapters,
        stage_id,
        storage_ref,
        abandoned_at,
        reason
      )
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def reconcile_stage(_context, _recovery, _reason),
    do: {:error, Error.new(:invalid)}

  defp reconcile([], _adapters, _abandoned_at, count), do: {:ok, count}

  defp reconcile(
         [%{stage_id: stage_id, storage_ref: storage_ref} = recovery | rest],
         adapters,
         abandoned_at,
         count
       )
       when is_binary(stage_id) and is_binary(storage_ref) do
    with {:ok, stage} <-
           reconcile_exact_stage(
             adapters,
             stage_id,
             storage_ref,
             abandoned_at,
             :runtime_restarted
           ) do
      emit_stage_age(recovery, abandoned_at, stage)
      reconcile(rest, adapters, abandoned_at, count + 1)
    end
  end

  defp reconcile(_stages, _adapters, _abandoned_at, _count),
    do: {:error, Error.new(:invalid)}

  defp reconcile_exact_stage(
         adapters,
         stage_id,
         storage_ref,
         abandoned_at,
         reason
       ) do
    call_adapter(
      adapters.repository,
      :with_locked_stage,
      [
        stage_id,
        storage_ref,
        fn status ->
          recover_locked_stage(
            adapters,
            status,
            stage_id,
            storage_ref,
            abandoned_at,
            reason
          )
        end
      ]
    )
  end

  defp recover_locked_stage(
         adapters,
         %{
           stage_id: stage_id,
           storage_ref: storage_ref,
           state: :open
         },
         stage_id,
         storage_ref,
         abandoned_at,
         reason
       ) do
    with :ok <-
           call_adapter(
             adapters.storage,
             :abort_stage,
             [%StageRef{stage_id: storage_ref}]
           ),
         {:ok, stage} <-
           call_adapter(
             adapters.repository,
             :mark_abandoned,
             [
               stage_id,
               storage_ref,
               abandoned_at,
               reason
             ]
           ) do
      {:ok, stage}
    end
  end

  defp recover_locked_stage(
         _adapters,
         %{
           stage_id: stage_id,
           storage_ref: storage_ref,
           state: state,
           state_revision: revision
         },
         stage_id,
         storage_ref,
         _abandoned_at,
         _reason
       )
       when state in [:sealed, :finalized] do
    {:ok,
     %{
       stage_id: stage_id,
       storage_ref: storage_ref,
       state: state,
       state_revision: revision,
       applied?: false
     }}
  end

  defp recover_locked_stage(
         _adapters,
         %{
           stage_id: stage_id,
           storage_ref: storage_ref,
           state: :abandoned,
           state_revision: revision,
           failure_code: failure_code
         },
         stage_id,
         storage_ref,
         _abandoned_at,
         reason
       ) do
    if failure_code == Atom.to_string(reason) do
      {:ok,
       %{
         stage_id: stage_id,
         storage_ref: storage_ref,
         state: :abandoned,
         state_revision: revision,
         failure_code: failure_code,
         applied?: false
       }}
    else
      {:error, Error.new(:conflict)}
    end
  end

  defp recover_locked_stage(
         _adapters,
         _status,
         _stage_id,
         _storage_ref,
         _abandoned_at,
         _reason
       ),
       do: {:error, Error.new(:integrity_failure)}

  defp emit_stage_age(
         %{inserted_at: %DateTime{} = inserted_at},
         %DateTime{} = observed_at,
         %{state: outcome}
       )
       when outcome in [:abandoned, :sealed, :finalized] do
    Telemetry.execute(
      [:upload, :reconciliation, :stage],
      %{age: max(DateTime.diff(observed_at, inserted_at, :millisecond), 0)},
      %{outcome: outcome}
    )
  end

  defp emit_stage_age(_recovery, _observed_at, _stage), do: :ok

  defp adapters(context) do
    repository = Map.get(context, :repository)
    storage = Map.get(context, :storage)
    clock = Map.get(context, :clock, fn -> DateTime.utc_now(:microsecond) end)

    if concrete?(repository) and concrete?(storage) and is_function(clock, 0) do
      {:ok, %{repository: repository, storage: storage, clock: clock}}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end

  defp concrete?(value), do: value not in [nil, false]
end
