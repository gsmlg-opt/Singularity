defmodule Singularity.Runtime.Knowledge.ExportArtifact.Handle do
  @moduledoc false

  @enforce_keys [:owner, :operation_ref, :binding, :deadline]
  defstruct [:owner, :operation_ref, :binding, :deadline]
end

defimpl Inspect, for: Singularity.Runtime.Knowledge.ExportArtifact.Handle do
  def inspect(_handle, _options), do: "#KnowledgeExport<opaque>"
end

defmodule Singularity.Runtime.Knowledge.ExportArtifact do
  @moduledoc false
  import Kernel, except: [binding: 1]

  alias __MODULE__, as: ExportArtifact
  alias __MODULE__.Handle
  alias Singularity.Core.Error
  alias Singularity.Runtime.{DownloadLease, KeyCustodian, OperationScope, SessionContext}
  alias Singularity.Storage.KnowledgeExport.{ArtifactDirectory, Writer}

  @lifetime 900_000
  @tick 1_000

  defmodule Leases do
    @moduledoc false
    alias Singularity.Core.Error

    def lease(context, request) do
      reference = make_ref()
      companion = context.companion
      monitor = Process.monitor(companion)

      send(companion, {:export_lease, context.operation_ref, self(), reference, request})

      try do
        receive do
          {:export_lease_result, ^reference, result} -> result
          {:DOWN, ^monitor, :process, ^companion, _} -> unavailable()
        end
      after
        Process.demonitor(monitor, [:flush])
      end
    end

    def read(context, lease, mode), do: read_native(context, :read, [lease, mode])

    def read_document_chunk(context, lease, ordinal),
      do: read_native(context, :read_document_chunk, [lease, ordinal])

    def authenticate_empty_document_original(context, lease),
      do: read_native(context, :authenticate_empty_document_original, [lease])

    def revoke(context, lease) do
      reference = make_ref()
      companion = context.companion
      monitor = Process.monitor(companion)
      send(companion, {:export_revoke, context.operation_ref, self(), reference, lease})

      try do
        receive do
          {:export_revoke_result, ^reference, result} -> result
          {:DOWN, ^monitor, :process, ^companion, _} -> unavailable()
        end
      after
        Process.demonitor(monitor, [:flush])
      end
    end

    defp read_native(context, function, arguments) do
      result = safely(fn -> call(context.reader, function, arguments) end)
      if Process.alive?(context.companion), do: result, else: unavailable()
    end

    defp call(module, function, arguments) when is_atom(module),
      do: apply(module, function, arguments)

    defp call({module, context}, function, arguments),
      do: apply(module, function, [context | arguments])

    defp safely(callback) do
      callback.()
    rescue
      _ -> unavailable()
    catch
      _, _ -> unavailable()
    end

    defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def generate(runtime, session, work) when is_function(work, 2) do
    safely(fn ->
      with :ok <- valid_session(session),
           configuration = Map.fetch!(runtime, :knowledge_export),
           clock = Map.fetch!(configuration, :clock),
           created_at when is_integer(created_at) <- clock.() do
        requester = self()
        operation_ref = make_ref()

        case start_task(configuration.task_supervisor, fn ->
               companion_start(runtime, session, work, requester, operation_ref, created_at)
             end) do
          {:ok, companion} ->
            result = safely(fn -> await_generation(companion, operation_ref) end)

            if match?({:error, _}, result),
              do: send(companion, {:export_request_cancel, operation_ref, requester})

            result

          _ ->
            unavailable()
        end
      else
        {:error, %Error{}} = error -> error
        _ -> unavailable()
      end
    end)
  end

  def entries(runtime, session, handle, cursor),
    do: route(runtime, session, handle, :entries, [cursor])

  def read_chunk(runtime, session, handle, path, ordinal),
    do: route(runtime, session, handle, :read_chunk, [path, ordinal])

  def close(runtime, session, handle), do: route(runtime, session, handle, :close, [])

  def writer_opened(operation, writer),
    do: operation_request(operation, {:export_writer, operation.operation_ref, self(), writer})

  def accept_completed(operation, artifact) do
    case operation_request(operation, {:export_prepared, operation.operation_ref, self()}) do
      :ok -> {:ok, artifact}
      error -> error
    end
  end

  def configuration do
    %{
      root: Application.fetch_env!(:singularity_runtime, :knowledge_export_root),
      storage_root: Application.fetch_env!(:singularity_storage, :storage_root),
      backup_root: Application.fetch_env!(:singularity_storage, :backup_root),
      task_supervisor: Singularity.Runtime.UploadRecoveryTaskSupervisor,
      clock: fn -> System.monotonic_time(:millisecond) end
    }
  end

  def start_runtime(children, options, false), do: Supervisor.start_link(children, options)

  def start_runtime(children, options, true) do
    lock = {{__MODULE__, :runtime_start}, self()}

    case :global.trans(lock, fn -> start_guarded(children, options) end, [node()], 0) do
      :aborted -> {:error, :storage_unavailable}
      result -> result
    end
  end

  defp start_guarded(children, options) do
    case Process.whereis(Keyword.fetch!(options, :name)) do
      pid when is_pid(pid) ->
        {:error, {:already_started, pid}}

      nil ->
        case Process.whereis(Singularity.Runtime.UploadRecoveryTaskSupervisor) do
          pid when is_pid(pid) ->
            {:error, :storage_unavailable}

          nil ->
            with {:ok, root} <- prepare_startup_root(),
                 {:ok, _counts} <- ArtifactDirectory.scavenge(root) do
              Supervisor.start_link(children, options)
            else
              _ -> {:error, :storage_unavailable}
            end
        end
    end
  end

  defp prepare_startup_root do
    configuration()
    |> Map.take([:root, :storage_root, :backup_root])
    |> ArtifactDirectory.prepare()
  end

  defp await_generation(companion, operation_ref) do
    monitor = Process.monitor(companion)

    try do
      receive do
        {:export_generated, ^operation_ref, ^companion, {:ok, %Handle{} = handle}} ->
          if Process.alive?(companion) and Process.alive?(handle.owner),
            do: {:ok, handle},
            else: unavailable()

        {:export_generated, ^operation_ref, ^companion, result} ->
          sanitize(result)

        {:DOWN, ^monitor, :process, ^companion, _} ->
          unavailable()
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp companion_start(runtime, session, work, requester, operation_ref, created_at) do
    Process.flag(:trap_exit, true)
    configuration = runtime.knowledge_export

    state = %{
      operation_ref: operation_ref,
      created_at: created_at,
      deadline: created_at + @lifetime,
      clock: fn -> safe_clock(configuration.clock) end,
      requester: requester,
      requester_monitor: Process.monitor(requester),
      owner: nil,
      owner_monitor: nil,
      envelope: nil,
      writer: nil,
      leases: %{},
      lease_error?: false,
      waiter: nil,
      phase: :generating,
      custodian: Map.get(runtime, :custodian, {KeyCustodian, KeyCustodian}),
      reader: Map.get(runtime, :authenticated_reader, DownloadLease)
    }

    with {:ok, root} <-
           ArtifactDirectory.prepare(
             Map.take(configuration, [:root, :storage_root, :backup_root])
           ),
         {:ok, envelope} <- ArtifactDirectory.create(root) do
      state = %{state | envelope: envelope}

      # This is the bootstrap deadline transition, before any producer exists.
      case companion_admission(state, state.clock.()) do
        {:ok, state} ->
          operation = %{
            path: envelope.path,
            envelope: envelope,
            companion: self(),
            operation_ref: operation_ref,
            created_at: created_at,
            deadline: state.deadline,
            clock: state.clock
          }

          case start_task(configuration.task_supervisor, fn ->
                 owner_start(runtime, session, work, operation)
               end) do
            {:ok, owner} ->
              state = %{state | owner: owner, owner_monitor: Process.monitor(owner)}
              send(owner, {:export_begin, operation_ref})
              companion_loop(state)

            _ ->
              cancel(state, {requester, operation_ref, unavailable()})
          end

        {:cancel, state} ->
          cancel(state, {requester, operation_ref, unavailable()})
      end
    else
      error ->
        send(requester, {:export_generated, operation_ref, self(), sanitize(error)})
    end
  end

  defp owner_start(runtime, session, work, operation) do
    Process.flag(:trap_exit, true)
    Process.link(operation.companion)
    owner_generate(runtime, session, work, Map.put(operation, :owner, self()))
  end

  defp owner_generate(runtime, session, work, operation) do
    state = %{
      runtime: runtime,
      session: session,
      binding: binding(session),
      operation_ref: operation.operation_ref,
      companion: operation.companion,
      companion_monitor: Process.monitor(operation.companion),
      task_supervisor: runtime.knowledge_export.task_supervisor,
      envelope: operation.envelope,
      deadline: operation.deadline,
      clock: operation.clock,
      artifact: nil
    }

    await_begin(state)

    lease_context = %{
      companion: state.companion,
      operation_ref: state.operation_ref,
      reader: Map.get(runtime, :authenticated_reader, DownloadLease)
    }

    operation_runtime =
      runtime
      |> Map.put(:custodian, {ExportArtifact.Leases, lease_context})
      |> Map.put(:authenticated_reader, {ExportArtifact.Leases, lease_context})

    result =
      try do
        work.(operation_runtime, operation)
      rescue
        _ -> unavailable()
      catch
        _, _ -> unavailable()
      end

    # Terminal loss handling must remain outside the materializer's catches.
    owner_boundary(state)

    case result do
      {:ok, artifact} ->
        handle = %Handle{
          owner: self(),
          operation_ref: state.operation_ref,
          binding: state.binding,
          deadline: state.deadline
        }

        send(state.companion, {:export_ready, state.operation_ref, self(), handle})
        owner_loop(%{state | artifact: artifact})

      error ->
        send(state.companion, {:export_failed, state.operation_ref, self(), sanitize(error)})
        exit(:normal)
    end
  end

  defp await_begin(state) do
    operation_ref = state.operation_ref
    owner_boundary(state)

    receive do
      {:export_begin, ^operation_ref} -> owner_boundary(state)
    after
      @tick -> await_begin(state)
    end
  end

  defp operation_request(operation, message) do
    companion = operation.companion
    reference = operation.operation_ref
    monitor = Process.monitor(companion)
    send(companion, message)

    try do
      receive do
        {:export_operation_ack, ^reference, result} -> result
        {:DOWN, ^monitor, :process, ^companion, _} -> unavailable()
      end
    after
      # This is a separate monitor. The owner's original DOWN remains queued
      # for terminal recovery after the materialization/COMMIT wrapper unwinds.
      Process.demonitor(monitor, [:flush])
    end
  end

  defp companion_loop(state) do
    operation_ref = state.operation_ref
    owner = state.owner
    owner_monitor = state.owner_monitor
    requester = state.requester
    requester_monitor = state.requester_monitor

    receive do
      {:export_lease, ^operation_ref, ^owner, reply_ref, native_request}
      when is_reference(reply_ref) and state.phase == :generating ->
        case companion_admission(state, state.clock.()) do
          {:ok, state} ->
            case safely(fn -> call(state.custodian, :export_lease, [native_request]) end) do
              {:ok, lease} when is_pid(lease) ->
                record_and_forward(state, %{owner: owner, reply_ref: reply_ref}, lease)

              error ->
                send(owner, {:export_lease_result, reply_ref, sanitize(error)})
                companion_loop(state)
            end

          {:cancel, state} ->
            cancel(state, nil)
        end

      {:export_writer, ^operation_ref, ^owner, writer} when state.phase == :generating ->
        case companion_admission(state, state.clock.()) do
          {:ok, state} when is_nil(state.writer) ->
            state = %{state | writer: writer}
            send(owner, {:export_operation_ack, operation_ref, :ok})
            companion_loop(state)

          _ ->
            cancel(state, nil)
        end

      {:export_prepared, ^operation_ref, ^owner} ->
        accept_prepared(state, owner)

      {:export_ready, ^operation_ref, ^owner, handle} when state.phase == :delivered ->
        case companion_admission(state, state.clock.()) do
          {:ok, state} ->
            send(requester, {:export_generated, operation_ref, self(), {:ok, handle}})
            companion_loop(state)

          {:cancel, state} ->
            cancel(state, nil)
        end

      {:export_failed, ^operation_ref, ^owner, error} ->
        cancel(state, {requester, operation_ref, sanitize(error)})

      {:export_register_close, ^operation_ref, ^owner, caller, reply_ref, result}
      when is_pid(caller) and is_reference(reply_ref) and state.phase == :delivered and
             is_nil(state.waiter) ->
        register_terminal(state, caller, reply_ref, sanitize(result))

      {:export_stop, ^operation_ref, ^owner} ->
        cancel(state, nil)

      {:export_close_waiting, ^operation_ref, reply_ref, caller}
      when not is_nil(state.waiter) and state.waiter.reply_ref == reply_ref and
             state.waiter.caller == caller ->
        companion_loop(%{state | waiter: %{state.waiter | ready: true}})

      {:export_cancel, ^operation_ref, ^owner} ->
        cancel(state, nil)

      {:export_request_cancel, ^operation_ref, ^requester} ->
        cancel(state, nil)

      {:export_revoke, ^operation_ref, ^owner, reply_ref, lease}
      when is_reference(reply_ref) and is_pid(lease) ->
        {result, state} = revoke_recorded_lease(state, lease)
        send(owner, {:export_revoke_result, reply_ref, result})
        companion_loop(state)

      {:DOWN, ^owner_monitor, :process, ^owner, _} ->
        cancel(%{state | owner_monitor: nil}, generation_failure(state))

      {:DOWN, ^requester_monitor, :process, ^requester, _}
      when state.phase == :generating ->
        cancel(state, nil)

      {:DOWN, monitor, :process, caller, _}
      when not is_nil(state.waiter) and state.waiter.monitor == monitor and
             state.waiter.caller == caller ->
        companion_loop(%{state | waiter: nil})

      {:DOWN, monitor, :process, lease, _} ->
        state =
          if Map.get(state.leases, lease) == monitor,
            do: %{state | leases: Map.delete(state.leases, lease)},
            else: state

        companion_loop(state)

      {:EXIT, _supervisor, :shutdown} ->
        cancel(state, generation_failure(state))

      _unrecognized ->
        companion_loop(state)
    after
      remaining(state) ->
        case companion_admission(state, state.clock.()) do
          {:ok, state} -> companion_loop(state)
          {:cancel, state} -> cancel(state, generation_failure(state))
        end
    end
  end

  defp record_and_forward(state, request, lease) do
    state = record_lease(state, lease)
    now = state.clock.()

    case companion_admission(state, now) do
      {:ok, state} ->
        send(request.owner, {:export_lease_result, request.reply_ref, {:ok, lease}})
        companion_loop(state)

      {:cancel, state} ->
        cancel(state, nil)
    end
  end

  defp record_lease(state, lease),
    do: %{state | leases: Map.put(state.leases, lease, Process.monitor(lease))}

  defp revoke_recorded_lease(state, lease) do
    case Map.fetch(state.leases, lease) do
      {:ok, monitor} ->
        if lease_down?(lease, monitor) do
          {:ok, %{state | leases: Map.delete(state.leases, lease)}}
        else
          result = safely(fn -> call(state.reader, :revoke, [lease]) end)

          if result == :ok do
            receive do
              {:DOWN, ^monitor, :process, ^lease, _} ->
                {:ok, %{state | leases: Map.delete(state.leases, lease)}}
            end
          else
            {unavailable(), %{state | lease_error?: true}}
          end
        end

      :error ->
        # Only the recorded owner's fixed adapter reaches this branch. A lease
        # removed from this map already supplied its original exact DOWN.
        {:ok, state}
    end
  end

  defp lease_down?(lease, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^lease, _} -> true
    after
      0 ->
        if Process.alive?(lease) do
          false
        else
          receive do
            {:DOWN, ^monitor, :process, ^lease, _} -> true
          end
        end
    end
  end

  defp register_terminal(state, caller, reply_ref, result) do
    monitor = Process.monitor(caller)

    waiter = %{
      caller: caller,
      reply_ref: reply_ref,
      monitor: monitor,
      result: result,
      ready: false
    }

    state = %{state | phase: :closing, waiter: waiter}
    send(state.owner, {:export_close_registered, state.operation_ref, reply_ref, self()})
    companion_loop(state)
  end

  defp accept_prepared(state, owner) do
    case companion_admission(state, state.clock.()) do
      {:ok, %{phase: :generating} = state} ->
        if Process.alive?(state.requester) do
          Process.demonitor(state.requester_monitor, [:flush])
          state = %{state | phase: :delivered, requester_monitor: nil}
          send(owner, {:export_operation_ack, state.operation_ref, :ok})
          companion_loop(state)
        else
          cancel(state, nil)
        end

      _ ->
        cancel(state, nil)
    end
  end

  defp companion_admission(state, now) do
    operation_ref = state.operation_ref
    owner = state.owner
    owner_monitor = state.owner_monitor
    requester = state.requester
    requester_monitor = state.requester_monitor

    receive do
      {:export_cancel, ^operation_ref, ^owner} ->
        {:cancel, state}

      {:export_request_cancel, ^operation_ref, ^requester} ->
        {:cancel, state}

      {:DOWN, ^owner_monitor, :process, ^owner, _} ->
        {:cancel, %{state | owner_monitor: nil}}

      {:DOWN, ^requester_monitor, :process, ^requester, _}
      when state.phase == :generating ->
        {:cancel, state}

      {:EXIT, _supervisor, :shutdown} ->
        {:cancel, state}
    after
      0 ->
        if is_integer(now) and now < state.deadline and not state.lease_error? and
             (is_nil(owner) or Process.alive?(owner)) and
             (state.phase == :delivered or Process.alive?(requester)),
           do: {:ok, state},
           else: {:cancel, state}
    end
  end

  defp generation_failure(%{phase: :generating} = state),
    do: {state.requester, state.operation_ref, unavailable()}

  defp generation_failure(_state), do: nil

  defp cancel(state, response) do
    state = %{state | phase: :closed}
    if state.writer, do: Writer.abort(state.writer)
    leases_closed? = revoke_leases(state)
    stop_owner(state)
    cleanup = if state.envelope, do: ArtifactDirectory.cleanup(state.envelope), else: :ok
    cleaned? = leases_closed? and cleanup == :ok
    respond_after_cleanup(state, response, cleaned?)

    terminal_reply(
      %{operation_ref: state.operation_ref, deadline: state.deadline, clock: state.clock},
      state.waiter,
      cleaned?
    )
  end

  defp revoke_leases(state) do
    Enum.reduce(state.leases, not state.lease_error?, fn {lease, monitor}, all_closed? ->
      closed? =
        if lease_down?(lease, monitor) do
          true
        else
          result = safely(fn -> call(state.reader, :revoke, [lease]) end)

          if result == :ok do
            receive do
              {:DOWN, ^monitor, :process, ^lease, _} -> true
            end
          else
            false
          end
        end

      closed? and all_closed?
    end)
  end

  defp stop_owner(%{owner: nil}), do: :ok
  defp stop_owner(%{owner_monitor: nil}), do: :ok

  defp stop_owner(state) do
    owner = state.owner
    monitor = state.owner_monitor
    Process.exit(owner, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^owner, _} -> :ok
    end
  end

  defp respond_after_cleanup(_state, nil, _cleaned?), do: :ok

  defp respond_after_cleanup(_state, {requester, reference, result}, cleaned?),
    do:
      send(
        requester,
        {:export_generated, reference, self(), if(cleaned?, do: result, else: unavailable())}
      )

  defp terminal_reply(context, waiter, cleaned?) do
    if is_nil(waiter) do
      if not cleaned?, do: exit({:shutdown, :export_cleanup_failed})
      :ok
    else
      operation_ref = context.operation_ref
      caller = waiter.caller
      reply_ref = waiter.reply_ref
      caller_monitor = waiter.monitor
      result = if(cleaned?, do: waiter.result, else: unavailable())

      if before_deadline?(context) do
        if waiter.ready do
          send(caller, {:export_closed, operation_ref, reply_ref, self(), result})
          Process.demonitor(caller_monitor, [:flush])
          :ok
        else
          receive do
            {:export_close_waiting, ^operation_ref, ^reply_ref, ^caller} ->
              send(caller, {:export_closed, operation_ref, reply_ref, self(), result})
              Process.demonitor(caller_monitor, [:flush])
              :ok

            {:DOWN, ^caller_monitor, :process, ^caller, _} ->
              :ok
          after
            remaining(context) -> terminal_reply(context, waiter, cleaned?)
          end
        end
      else
        Process.demonitor(caller_monitor, [:flush])
        :ok
      end
    end
  end

  defp route(runtime, session, handle, operation, arguments) do
    safely(fn ->
      with :ok <- valid_session(session),
           :ok <- valid_handle(handle),
           true <- binding(session) == handle.binding do
        if Process.alive?(handle.owner) do
          reference = make_ref()
          monitor = Process.monitor(handle.owner)

          try do
            send(
              handle.owner,
              {operation, handle.operation_ref, handle.deadline, self(), reference, session,
               arguments}
            )

            await_route(%{
              owner: handle.owner,
              owner_monitor: monitor,
              operation_ref: handle.operation_ref,
              reply_ref: reference,
              deadline: handle.deadline,
              clock: runtime.knowledge_export.clock
            })
          after
            Process.demonitor(monitor, [:flush])
          end
        else
          if operation == :close, do: authorize(runtime, session, fn -> :ok end), else: invalid()
        end
      else
        false -> forbidden()
        {:error, %Error{}} = error -> error
      end
    end)
  end

  defp await_route(state) do
    owner = state.owner
    owner_monitor = state.owner_monitor
    operation_ref = state.operation_ref
    reply_ref = state.reply_ref

    receive do
      {^reply_ref, result} ->
        sanitize(result)

      {:export_close_route, ^operation_ref, ^reply_ref, ^owner, companion}
      when is_pid(companion) ->
        companion_monitor = Process.monitor(companion)
        send(companion, {:export_close_waiting, operation_ref, reply_ref, self()})

        try do
          await_terminal(
            Map.merge(state, %{
              companion: companion,
              companion_monitor: companion_monitor,
              owner_down?: false,
              companion_down?: false,
              result: nil
            })
          )
        after
          Process.demonitor(companion_monitor, [:flush])
        end

      {:DOWN, ^owner_monitor, :process, ^owner, _} ->
        unavailable()
    end
  end

  defp await_terminal(state) do
    operation_ref = state.operation_ref
    reply_ref = state.reply_ref
    owner = state.owner
    owner_monitor = state.owner_monitor
    companion = state.companion
    companion_monitor = state.companion_monitor

    if before_deadline?(state) do
      if state.owner_down? and state.companion_down? and not is_nil(state.result) do
        sanitize(state.result)
      else
        receive do
          {:DOWN, ^owner_monitor, :process, ^owner, _} ->
            await_terminal(%{state | owner_down?: true})

          {:DOWN, ^companion_monitor, :process, ^companion, :normal} ->
            await_terminal(%{state | companion_down?: true})

          {:DOWN, ^companion_monitor, :process, ^companion, _} ->
            unavailable()

          {:export_closed, ^operation_ref, ^reply_ref, ^companion, result} ->
            await_terminal(%{state | result: result})
        after
          remaining(state) -> await_terminal(state)
        end
      end
    else
      unavailable()
    end
  end

  defp owner_loop(state) do
    owner_boundary(state)
    companion = state.companion
    companion_monitor = state.companion_monitor

    receive do
      {:DOWN, ^companion_monitor, :process, ^companion, _} = down_message ->
        recover_companion_loss(state, down_message)

      {:EXIT, _supervisor, :shutdown} ->
        exit(:shutdown)

      {operation, reference, deadline, caller, reply_ref, session, arguments}
      when is_pid(caller) and is_reference(reply_ref) ->
        if reference == state.operation_ref and deadline == state.deadline and
             binding_matches?(session, state.binding) do
          owner_request(state, operation, caller, reply_ref, session, arguments)
        else
          send(caller, {reply_ref, forbidden()})
          owner_loop(state)
        end

      _unrecognized ->
        owner_loop(state)
    after
      remaining(state) ->
        result = safely(fn -> authorize(state.runtime, state.session, fn -> :ok end) end)
        owner_boundary(state)

        if result == :ok do
          owner_loop(state)
        else
          send(state.companion, {:export_cancel, state.operation_ref, self()})
          exit({:shutdown, :export_authority_lost})
        end
    end
  end

  defp owner_request(state, operation, caller, reply_ref, session, arguments) do
    case delivery_arguments(operation, arguments) do
      :ok ->
        owner_boundary(state)

        result =
          safely(fn ->
            authorize(state.runtime, session, fn ->
              case {operation, arguments} do
                {:entries, [cursor]} -> Writer.entries(state.artifact, cursor)
                {:read_chunk, [path, ordinal]} -> Writer.read_chunk(state.artifact, path, ordinal)
                {:close, []} -> :ok
              end
            end)
          end)

        owner_boundary(state)

        if operation == :close or match?({:error, _}, result) do
          owner_stop(state, caller, reply_ref, result)
        else
          send(caller, {reply_ref, result})
          owner_loop(state)
        end

      _ ->
        send(caller, {reply_ref, invalid()})
        owner_loop(state)
    end
  end

  defp owner_stop(state, caller, reply_ref, result) do
    operation_ref = state.operation_ref
    companion = state.companion
    companion_monitor = state.companion_monitor
    send(companion, {:export_register_close, operation_ref, self(), caller, reply_ref, result})

    receive do
      {:export_close_registered, ^operation_ref, ^reply_ref, ^companion} ->
        send(caller, {:export_close_route, operation_ref, reply_ref, self(), companion})
        send(companion, {:export_stop, operation_ref, self()})
        exit(:normal)

      {:DOWN, ^companion_monitor, :process, ^companion, _} = down_message ->
        recover_companion_loss(state, down_message)

      {:EXIT, _supervisor, :shutdown} ->
        exit(:shutdown)
    after
      remaining(state) ->
        if before_deadline?(state) do
          owner_stop(state, caller, reply_ref, result)
        else
          send(companion, {:export_cancel, operation_ref, self()})
          exit({:shutdown, :export_expired})
        end
    end
  end

  defp authorize(runtime, session, callback) do
    OperationScope.with_shared_request(
      runtime,
      session,
      %{
        vault_id: session.vault_id,
        required_capabilities: ["asset.read", "note.read"],
        classification: :private,
        requires_unlocked?: true,
        principal_authorization_epoch: session.principal_authorization_epoch,
        vault_authorization_epoch: session.vault_authorization_epoch
      },
      fn _repo -> {:after_commit, callback} end
    )
  end

  defp owner_boundary(state) do
    companion = state.companion
    monitor = state.companion_monitor

    receive do
      {:DOWN, ^monitor, :process, ^companion, _} = down_message ->
        recover_companion_loss(state, down_message)

      {:EXIT, _supervisor, :shutdown} ->
        exit(:shutdown)

      {:EXIT, ^companion, _} ->
        owner_boundary(state)
    after
      0 ->
        cond do
          not Process.alive?(companion) ->
            recover_companion_loss(state, await_companion_down(state))

          not before_deadline?(state) ->
            send(companion, {:export_cancel, state.operation_ref, self()})
            exit({:shutdown, :export_expired})

          true ->
            :ok
        end
    end
  end

  defp await_companion_down(state) do
    monitor = state.companion_monitor
    companion = state.companion

    receive do
      {:DOWN, ^monitor, :process, ^companion, _} = message -> message
      {:EXIT, _supervisor, :shutdown} -> exit(:shutdown)
    end
  end

  defp recover_companion_loss(state, down_message) do
    companion = state.companion
    companion_monitor = state.companion_monitor

    case down_message do
      {:DOWN, ^companion_monitor, :process, ^companion, _reason} ->
        cleanup_context = %{
          owner: self(),
          operation_ref: state.operation_ref,
          recovery_ref: make_ref(),
          envelope: state.envelope
        }

        reject_supervisor_shutdown()

        case start_cleanup_replacement(state.task_supervisor, cleanup_context) do
          {:ok, replacement} ->
            replacement_monitor = Process.monitor(replacement)
            operation_ref = cleanup_context.operation_ref
            recovery_ref = cleanup_context.recovery_ref

            receive do
              {:export_cleanup_ready, ^operation_ref, ^recovery_ref, ^replacement} ->
                exit({:shutdown, :export_companion_lost})

              {:DOWN, ^replacement_monitor, :process, ^replacement, _} ->
                exit({:shutdown, :export_cleanup_unavailable})

              {:EXIT, _supervisor, :shutdown} ->
                exit(:shutdown)
            end

          _ ->
            exit({:shutdown, :export_cleanup_unavailable})
        end
    end
  end

  defp start_cleanup_replacement(task_supervisor, cleanup_context) do
    Task.Supervisor.start_child(task_supervisor, fn ->
      cleanup_replacement(cleanup_context)
    end)
  catch
    :exit, _ -> unavailable()
  end

  defp cleanup_replacement(%{
         owner: owner,
         operation_ref: operation_ref,
         recovery_ref: recovery_ref,
         envelope: envelope
       }) do
    owner_monitor = Process.monitor(owner)
    send(owner, {:export_cleanup_ready, operation_ref, recovery_ref, self()})

    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        case ArtifactDirectory.cleanup(envelope) do
          :ok -> :ok
          {:error, %Error{}} -> exit({:shutdown, :export_cleanup_failed})
        end
    end
  end

  defp reject_supervisor_shutdown do
    receive do
      {:EXIT, _supervisor, :shutdown} -> exit(:shutdown)
    after
      0 -> :ok
    end
  end

  defp before_deadline?(state) do
    now = state.clock.()
    is_integer(now) and now < state.deadline
  end

  defp safe_clock(clock) do
    clock.()
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  defp remaining(state) do
    case safely(fn -> state.clock.() end) do
      now when is_integer(now) -> max(0, min(@tick, state.deadline - now))
      _ -> 0
    end
  end

  defp delivery_arguments(:entries, [nil]), do: :ok

  defp delivery_arguments(:entries, [cursor]) when is_map(cursor) and not is_struct(cursor),
    do:
      if(
        Enum.sort(Map.keys(cursor)) == [:after, :operation_id, :proof] and
          uuid?(cursor.operation_id) and relative_path?(cursor.after) and digest?(cursor.proof),
        do: :ok,
        else: invalid()
      )

  defp delivery_arguments(:read_chunk, [path, ordinal])
       when is_binary(path) and is_integer(ordinal) and ordinal >= 0 do
    if relative_path?(path), do: :ok, else: invalid()
  end

  defp delivery_arguments(:close, []), do: :ok
  defp delivery_arguments(_, _), do: invalid()

  defp valid_handle(%Handle{} = handle) do
    if Enum.sort(Map.keys(handle)) == [:__struct__, :binding, :deadline, :operation_ref, :owner] and
         is_pid(handle.owner) and node(handle.owner) == node() and
         is_reference(handle.operation_ref) and is_integer(handle.deadline) and
         valid_binding?(handle.binding),
       do: :ok,
       else: invalid()
  end

  defp valid_handle(_), do: invalid()

  defp valid_session(%SessionContext{} = session),
    do: if(valid_binding?(binding(session)), do: :ok, else: invalid())

  defp valid_session(_), do: invalid()

  defp binding(session),
    do:
      {session.session_id, session.principal_id, session.vault_id,
       session.principal_authorization_epoch, session.vault_authorization_epoch}

  defp binding_matches?(%SessionContext{} = session, expected),
    do: valid_session(session) == :ok and binding(session) == expected

  defp binding_matches?(_, _), do: false

  defp valid_binding?({session, principal, owner, principal_epoch, owner_epoch}) do
    Enum.all?([session, principal, owner], &uuid?/1) and
      is_integer(principal_epoch) and principal_epoch >= 0 and
      is_integer(owner_epoch) and owner_epoch >= 0
  end

  defp valid_binding?(_), do: false

  defp uuid?(value) when is_binary(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp uuid?(_), do: false

  defp relative_path?(path) when is_binary(path) do
    String.valid?(path) and path != "" and Path.type(path) == :relative and
      not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp relative_path?(_), do: false

  defp digest?(digest) when is_binary(digest) and byte_size(digest) == 64,
    do: match?({:ok, <<_::binary-size(32)>>}, Base.decode16(digest, case: :lower))

  defp digest?(_), do: false

  defp start_task(supervisor, callback) do
    Task.Supervisor.start_child(supervisor, callback)
  catch
    :exit, _ -> unavailable()
  end

  defp call(module, function, arguments) when is_atom(module),
    do: apply(module, function, arguments)

  defp call({module, context}, function, arguments),
    do: apply(module, function, [context | arguments])

  defp safely(callback) do
    sanitize(callback.())
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp sanitize({:error, %Error{code: code, retryable?: retryable?}}),
    do: {:error, Error.new(code, retryable?: retryable?)}

  defp sanitize({:error, :waiting_for_unlock}), do: {:error, Error.new(:vault_locked)}
  defp sanitize({:error, _}), do: unavailable()
  defp sanitize(result), do: result
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
  defp invalid, do: {:error, Error.new(:invalid)}
  defp forbidden, do: {:error, Error.new(:forbidden)}
end
