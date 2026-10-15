defmodule Singularity.Storage.Backup.KnowledgeFixtureResourceOwner do
  @moduledoc false

  alias Singularity.Storage.MigrationTestEnvironment

  @checkpoint {__MODULE__, :checkpoint}

  defmodule CleanupError do
    defexception [:failures]

    def message(%{failures: failures}),
      do: "knowledge fixture cleanup failed: #{inspect(failures)}"
  end

  # Test-only checkpoints observe real lifecycle stages. They never substitute
  # acquisition or run the user's destination callback in the resource owner.
  def with_checkpoint(checkpoint, fun) when is_function(checkpoint, 2) do
    previous = Process.get(@checkpoint)
    Process.put(@checkpoint, checkpoint)

    try do
      fun.()
    after
      if previous, do: Process.put(@checkpoint, previous), else: Process.delete(@checkpoint)
    end
  end

  def open(options \\ []) when options in [[], [migration_pool_size: 2]] do
    caller = self()
    checkpoint = Process.get(@checkpoint, fn _stage, _resources -> :ok end)

    owner =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        unarmed(caller, Process.monitor(caller), false)
      end)

    try do
      {registered?, cleanup} = register_cleanup(owner)
      :ok = request(owner, {:prepare, registered?})
      checkpoint.(:before_arm, %{owner: owner, caller: caller, on_exit: cleanup})

      case request(owner, {:acquire, checkpoint, options}) do
        {:ok, destination} -> {owner, destination}
        {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
      end
    catch
      kind, reason ->
        stack = __STACKTRACE__
        if Process.alive?(owner), do: close(owner)
        :erlang.raise(kind, reason, stack)
    end
  end

  def close(owner), do: release(owner, :close)

  def start_infrastructure(owner, children) when is_pid(owner) and is_list(children) do
    case request(owner, {:start_infrastructure, children}) do
      {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
      reply -> reply
    end
  end

  defp register_cleanup(owner) do
    if Code.ensure_loaded?(ExUnit) and match?({:ok, _}, ExUnit.fetch_test_supervisor()) do
      id = make_ref()
      cleanup = fn -> release(owner, :finish) end
      ExUnit.Callbacks.on_exit(id, cleanup)
      {true, {id, cleanup}}
    else
      {false, nil}
    end
  end

  defp release(owner, command) do
    monitor = Process.monitor(owner)

    try do
      {failures, retained?} = request(owner, command)

      unless retained? do
        receive do
          {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
        end
      end

      if failures != [], do: raise(CleanupError, failures: failures)
      :ok
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp request(owner, command) do
    monitor = Process.monitor(owner)
    send(owner, {command, self(), monitor})

    try do
      receive do
        {^monitor, reply} -> reply
        {:DOWN, ^monitor, :process, ^owner, reason} -> exit({:fixture_owner_down, reason})
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp unarmed(caller, caller_monitor, registered?) do
    receive do
      {{:prepare, retain?}, ^caller, ref} ->
        send(caller, {ref, :ok})
        unarmed(caller, caller_monitor, retain?)

      {{:acquire, checkpoint, options}, ^caller, ref} ->
        acquire(caller, caller_monitor, registered?, ref, checkpoint, options)

      {{:start_infrastructure, _children}, from, ref} ->
        send(from, {ref, {:error, :not_acquired}})
        unarmed(caller, caller_monitor, registered?)

      {:close, from, ref} ->
        send(from, {ref, {[], registered?}})
        if registered?, do: closed([])

      {:finish, from, ref} ->
        send(from, {ref, {[], false}})

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        if registered?, do: closed([])
    end
  end

  defp acquire(caller, caller_monitor, registered?, acquire_ref, checkpoint, options) do
    {outcome, failures} =
      MigrationTestEnvironment.with_owned_database(
        caller,
        checkpoint,
        fn destination ->
          send(caller, {acquire_ref, {:ok, destination}})
          await_release(caller, caller_monitor)
        end,
        options
      )

    failures =
      case outcome do
        {:ok, {:dependency_failed, pid}} -> [{:owned_process_exited, pid} | failures]
        _ -> failures
      end

    case outcome do
      {:ok, {command, from, ref}} when command in [:close, :finish] ->
        retain? = registered? and command != :finish
        send(from, {ref, {failures, retain?}})
        complete(failures, retain?)

      {:raised, kind, reason, stack} ->
        reply =
          if failures == [],
            do: {:raised, kind, reason, stack},
            else: {:raised, :error, %CleanupError{failures: failures}, stack}

        send(caller, {acquire_ref, reply})
        # The caller must acknowledge even a failed acquisition before an
        # unregistered owner exits; otherwise close races the error reply.
        failed_acquisition(caller, caller_monitor, failures, registered?)

      _caller_or_dependency_down ->
        complete(failures, registered?)
    end
  end

  defp await_release(caller, caller_monitor) do
    receive do
      {{:start_infrastructure, children}, ^caller, ref} ->
        reply =
          try do
            MigrationTestEnvironment.start_owned_infrastructure(children)
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        send(caller, {ref, reply})
        await_release(caller, caller_monitor)

      {{:start_infrastructure, _children}, from, ref} ->
        send(from, {ref, {:error, :not_owner}})
        await_release(caller, caller_monitor)

      {command, from, ref} when command in [:close, :finish] ->
        {command, from, ref}

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        :caller_down

      {:EXIT, _pid, reason} when reason in [:normal, :shutdown] ->
        await_release(caller, caller_monitor)

      {:EXIT, pid, _reason} ->
        {:dependency_failed, pid}
    end
  end

  defp complete(failures, true), do: closed(failures)
  defp complete([], false), do: :ok
  defp complete(failures, false), do: exit({:fixture_cleanup_failed, failures})

  defp failed_acquisition(caller, caller_monitor, failures, registered?) do
    receive do
      {command, from, ref} when command in [:close, :finish] ->
        retain? = registered? and command != :finish
        send(from, {ref, {failures, retain?}})
        complete(failures, retain?)

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        complete(failures, registered?)

      {:EXIT, _pid, _reason} ->
        failed_acquisition(caller, caller_monitor, failures, registered?)
    end
  end

  # Only the completion receipt remains here: no configuration, capabilities,
  # descriptors, destination handles or repeatable cleanup actions are retained.
  defp closed(failures) do
    receive do
      {{:start_infrastructure, _children}, from, ref} ->
        send(from, {ref, {:error, :not_acquired}})
        closed(failures)

      {:close, from, ref} ->
        send(from, {ref, {failures, true}})
        closed(failures)

      {:finish, from, ref} ->
        send(from, {ref, {failures, false}})

      _message ->
        closed(failures)
    end
  end
end
