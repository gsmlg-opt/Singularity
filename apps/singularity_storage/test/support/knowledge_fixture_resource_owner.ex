defmodule Singularity.Storage.Backup.KnowledgeFixtureResourceOwner do
  @moduledoc false

  alias Singularity.Storage.MigrationTestEnvironment

  @checkpoint {__MODULE__, :checkpoint}

  defmodule CleanupError do
    defexception [:failures]

    def message(%{failures: failures}),
      do: "knowledge fixture cleanup failed: #{inspect(failures)}"
  end

  defmodule RelationshipError do
    defexception [:reason]

    def message(%{reason: reason}),
      do: "knowledge fixture relationship rejected: #{reason}"
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
    open_owned(nil, options)
  end

  def open_child(parent_owner, options \\ []) when options in [[], [migration_pool_size: 2]] do
    unless is_pid(parent_owner) and parent_owner != self(),
      do: raise(RelationshipError, reason: :invalid_parent)

    unless Process.alive?(parent_owner), do: raise(RelationshipError, reason: :parent_down)
    open_owned(parent_owner, options)
  end

  defp open_owned(parent, options) do
    caller = self()
    checkpoint = Process.get(@checkpoint, fn _stage, _resources -> :ok end)

    owner =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        unarmed(%{
          caller: caller,
          caller_monitor: Process.monitor(caller),
          registered?: false,
          checkpoint: checkpoint,
          parent: nil,
          parent_down?: false,
          child: nil,
          descendant_failures: [],
          local_failures: []
        })
      end)

    try do
      {registered?, cleanup} = register_cleanup(owner)

      case request(owner, {:prepare, registered?, parent}) do
        :ok -> :ok
        {:relationship_error, reason} -> raise(RelationshipError, reason: reason)
      end

      checkpoint.(:before_arm, %{owner: owner, caller: caller, on_exit: cleanup})

      command = if is_nil(parent), do: :acquire, else: :acquire_child

      case request(owner, {command, checkpoint, options}) do
        {:ok, destination} -> {owner, destination}
        {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
        {:relationship_error, reason} -> raise(RelationshipError, reason: reason)
      end
    catch
      kind, reason ->
        stack = __STACKTRACE__
        # Default opens propagate secondary close failures. Child opens retain
        # their primary exception and an independent cleanup receipt.
        if Process.alive?(owner) do
          if is_nil(parent) do
            close(owner)
          else
            try do
              close(owner)
            catch
              _, _ -> :ok
            end
          end
        end

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
      case request(owner, command) do
        {:relationship_error, reason} ->
          raise(RelationshipError, reason: reason)

        {failures, retained?} ->
          unless retained? do
            receive do
              {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
            end
          end

          if failures != [], do: raise(CleanupError, failures: failures)
          :ok
      end
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

  defp unarmed(%{caller: caller, caller_monitor: caller_monitor} = state) do
    receive do
      {{:prepare, retain?, parent}, ^caller, ref} ->
        state = %{state | registered?: retain?}

        case attach_parent(state, parent) do
          {:ok, state} ->
            send(caller, {ref, :ok})
            unarmed(state)

          {:error, reason, state} ->
            send(caller, {ref, {:relationship_error, reason}})
            unarmed(state)
        end

      {{command, checkpoint, options}, ^caller, ref} when command in [:acquire, :acquire_child] ->
        acquire(%{state | checkpoint: checkpoint}, ref, options)

      {:attach_child, child, _caller, edge_ref, reply_ref} ->
        reject_child(child, edge_ref, reply_ref, :parent_not_ready)
        unarmed(state)

      {{:start_infrastructure, _children}, from, ref} ->
        send(from, {ref, {:error, :not_acquired}})
        unarmed(state)

      {:close, from, ref} ->
        finish_unarmed(state, {:close, from, ref})

      {:finish, from, ref} ->
        finish_unarmed(state, {:finish, from, ref})

      {:close_child, parent, edge_ref}
      when not is_nil(state.parent) and parent == state.parent.pid and
             edge_ref == state.parent.ref ->
        finish_unarmed(state, :parent_release)

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        finish_unarmed(state, :caller_down)

      {:DOWN, monitor, :process, parent, _reason}
      when not is_nil(state.parent) and monitor == state.parent.monitor and
             parent == state.parent.pid ->
        finish_unarmed(%{state | parent_down?: true}, :parent_down)
    end
  end

  defp attach_parent(state, nil), do: {:ok, state}

  defp attach_parent(state, parent) do
    edge = %{pid: parent, monitor: Process.monitor(parent), ref: make_ref()}
    reply_ref = make_ref()
    state = observe(%{state | parent: edge}, :child_attach_requested)
    send(parent, {:attach_child, self(), state.caller, edge.ref, reply_ref})
    await_attachment(state, reply_ref)
  end

  defp await_attachment(%{parent: edge} = state, reply_ref) do
    receive do
      {:child_attached, parent, edge_ref, ^reply_ref}
      when parent == edge.pid and edge_ref == edge.ref ->
        {:ok, observe(state, :child_attached)}

      {:child_rejected, parent, edge_ref, ^reply_ref, reason}
      when parent == edge.pid and edge_ref == edge.ref ->
        Process.demonitor(edge.monitor, [:flush])
        {:error, reason, %{state | parent: nil}}

      {:DOWN, monitor, :process, parent, _reason}
      when monitor == edge.monitor and parent == edge.pid ->
        {:error, :parent_down, %{state | parent: nil}}

      {:attach_child, child, _caller, edge_ref, child_reply_ref} ->
        reject_child(child, edge_ref, child_reply_ref, :parent_not_ready)
        await_attachment(state, reply_ref)
    end
  end

  defp finish_unarmed(state, terminal) do
    # An admitted child may lose its caller before acquire is armed. It still
    # owes the exact parent a terminal receipt, although it allocated nothing.
    {state, failures} = acknowledge_parent(state, state.local_failures)
    finish_terminal(state, terminal, failures)
  end

  defp acquire(%{caller: caller, checkpoint: checkpoint} = initial, acquire_ref, options) do
    {native_outcome, own_failures} =
      MigrationTestEnvironment.with_owned_database(
        caller,
        checkpoint,
        fn destination ->
          send(caller, {acquire_ref, {:ok, destination}})
          {terminal, state} = await_release(initial)
          {terminal, observe(state, :owner_cleanup_begin)}
        end,
        options
      )

    {outcome, state} =
      case native_outcome do
        {:ok, {terminal, state}} -> {terminal, state}
        other -> {other, initial}
      end

    state = observe(state, :owner_cleanup_completed)

    dependency_failures =
      case original_terminal(outcome) do
        {:dependency_failed, pid} -> [{:owned_process_exited, pid}]
        _ -> []
      end

    failures =
      state.descendant_failures ++
        dependency_failures ++
        state.local_failures ++ own_failures

    {state, failures} = acknowledge_parent(state, failures)

    case outcome do
      {:raised, kind, reason, stack} ->
        reply =
          if failures == [] or not is_nil(initial.parent),
            do: {:raised, kind, reason, stack},
            else: {:raised, :error, %CleanupError{failures: failures}, stack}

        send(caller, {acquire_ref, reply})
        # The caller must acknowledge even a failed acquisition before an
        # unregistered owner exits; otherwise close races the error reply.
        failed_acquisition(state, failures)

      terminal ->
        finish_terminal(state, terminal, failures)
    end
  end

  defp await_release(%{caller: caller, caller_monitor: caller_monitor} = state) do
    receive do
      {:attach_child, child, requesting_caller, edge_ref, reply_ref} ->
        state = admit_child(state, child, requesting_caller, edge_ref, reply_ref)
        await_release(state)

      {:child_cleanup_completed, child, edge_ref, failures}
      when not is_nil(state.child) and child == state.child.pid and edge_ref == state.child.ref ->
        await_release(settle_child(state, failures))

      {:DOWN, monitor, :process, child, _reason}
      when not is_nil(state.child) and monitor == state.child.monitor and child == state.child.pid ->
        await_release(unconfirmed_child(state))

      {{:start_infrastructure, children}, ^caller, ref} ->
        reply =
          if state.child do
            {:error, :active_child}
          else
            try do
              MigrationTestEnvironment.start_owned_infrastructure(children)
            catch
              kind, reason -> {:raised, kind, reason, __STACKTRACE__}
            end
          end

        send(caller, {ref, reply})
        await_release(state)

      {{:start_infrastructure, _children}, from, ref} ->
        send(from, {ref, {:error, :not_owner}})
        await_release(state)

      {command, from, ref} when command in [:close, :finish] ->
        if from != caller and Process.alive?(caller) and state.child do
          send(from, {ref, {:relationship_error, :not_owner}})
          await_release(state)
        else
          drain_children(observe(state, :release_requested), {command, from, ref})
        end

      {:close_child, parent, edge_ref}
      when not is_nil(state.parent) and parent == state.parent.pid and
             edge_ref == state.parent.ref ->
        drain_children(observe(state, :release_requested), :parent_release)

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        drain_children(observe(state, :release_requested), :caller_down)

      {:DOWN, monitor, :process, parent, _reason}
      when not is_nil(state.parent) and monitor == state.parent.monitor and
             parent == state.parent.pid ->
        drain_children(observe(%{state | parent_down?: true}, :release_requested), :parent_down)

      {:EXIT, _pid, reason} when reason in [:normal, :shutdown] ->
        await_release(state)

      {:EXIT, pid, _reason} ->
        drain_children(observe(state, :release_requested), {:dependency_failed, pid})
    end
  end

  defp admit_child(state, child, caller, edge_ref, reply_ref) do
    reason =
      cond do
        caller != state.caller -> :different_caller
        not Process.alive?(state.caller) -> :parent_closing
        state.descendant_failures != [] -> :parent_cleanup_failed
        not is_nil(state.child) -> :active_child
        not is_pid(child) or child == self() or not is_reference(edge_ref) -> :invalid_parent
        not Process.alive?(child) -> :parent_down
        true -> nil
      end

    if reason do
      reject_child(child, edge_ref, reply_ref, reason)
      state
    else
      edge = %{pid: child, ref: edge_ref, monitor: Process.monitor(child)}
      send(child, {:child_attached, self(), edge_ref, reply_ref})
      %{state | child: edge}
    end
  end

  defp reject_child(child, edge_ref, reply_ref, reason) do
    if is_pid(child), do: send(child, {:child_rejected, self(), edge_ref, reply_ref, reason})
  end

  defp settle_child(%{child: edge} = state, failures) do
    Process.demonitor(edge.monitor, [:flush])
    send(edge.pid, {:child_cleanup_acknowledged, self(), edge.ref})
    %{state | child: nil, descendant_failures: state.descendant_failures ++ failures}
  end

  defp unconfirmed_child(%{child: edge} = state) do
    Process.demonitor(edge.monitor, [:flush])

    %{
      state
      | child: nil,
        descendant_failures: state.descendant_failures ++ [{:unconfirmed_child_cleanup, edge.pid}]
    }
  end

  defp drain_children(%{child: nil} = state, terminal), do: {terminal, state}

  defp drain_children(state, terminal) do
    send(state.child.pid, {:close_child, self(), state.child.ref})
    await_child(observe(state, :waiting_for_child_cleanup), terminal, [])
  end

  defp await_child(%{child: nil} = state, terminal, []), do: {terminal, state}

  defp await_child(%{child: nil} = state, terminal, joins),
    do: {{:joined, terminal, joins}, state}

  defp await_child(%{child: edge} = state, terminal, joins) do
    receive do
      {:child_cleanup_completed, child, edge_ref, failures}
      when child == edge.pid and edge_ref == edge.ref ->
        await_child(settle_child(state, failures), terminal, joins)

      {:DOWN, monitor, :process, child, _reason}
      when monitor == edge.monitor and child == edge.pid ->
        await_child(unconfirmed_child(state), terminal, joins)

      {:attach_child, child, _caller, edge_ref, reply_ref} ->
        reject_child(child, edge_ref, reply_ref, :parent_closing)
        await_child(state, terminal, joins)

      {{:start_infrastructure, _children}, from, ref} ->
        send(from, {ref, {:error, :active_child}})
        await_child(state, terminal, joins)

      {command, from, ref} when command in [:close, :finish] ->
        if from != state.caller and Process.alive?(state.caller) do
          send(from, {ref, {:relationship_error, :not_owner}})
          await_child(state, terminal, joins)
        else
          await_child(state, terminal, [{command, from, ref} | joins])
        end

      {:DOWN, monitor, :process, parent, _reason}
      when not is_nil(state.parent) and monitor == state.parent.monitor and
             parent == state.parent.pid ->
        await_child(%{state | parent_down?: true}, terminal, joins)

      {:EXIT, _pid, reason} when reason in [:normal, :shutdown] ->
        await_child(state, terminal, joins)

      {:EXIT, pid, _reason} ->
        failure = {:owned_process_exited, pid}

        failures =
          if failure in state.local_failures,
            do: state.local_failures,
            else: state.local_failures ++ [failure]

        await_child(%{state | local_failures: failures}, terminal, joins)
    end
  end

  defp acknowledge_parent(%{parent: nil} = state, failures), do: {state, failures}

  defp acknowledge_parent(%{parent: edge} = state, failures) do
    if state.parent_down? or not Process.alive?(edge.pid) do
      Process.demonitor(edge.monitor, [:flush])
      {%{state | parent: nil}, failures ++ [{:unconfirmed_parent_acknowledgment, edge.pid}]}
    else
      send(edge.pid, {:child_cleanup_completed, self(), edge.ref, failures})
      await_parent_acknowledgment(state, failures)
    end
  end

  defp await_parent_acknowledgment(%{parent: edge} = state, failures) do
    receive do
      {:child_cleanup_acknowledged, parent, edge_ref}
      when parent == edge.pid and edge_ref == edge.ref ->
        Process.demonitor(edge.monitor, [:flush])
        prior = length(state.local_failures)
        state = observe(state, :child_cleanup_acknowledged)
        {%{state | parent: nil}, failures ++ Enum.drop(state.local_failures, prior)}

      {:DOWN, monitor, :process, parent, _reason}
      when monitor == edge.monitor and parent == edge.pid ->
        {%{state | parent: nil}, failures ++ [{:unconfirmed_parent_acknowledgment, parent}]}

      {:attach_child, child, _caller, edge_ref, reply_ref} ->
        reject_child(child, edge_ref, reply_ref, :parent_closing)
        await_parent_acknowledgment(state, failures)
    end
  end

  defp observe(state, stage) do
    resources = %{owner: self(), caller: state.caller, parent: state.parent, child: state.child}

    try do
      state.checkpoint.(stage, resources)
      state
    catch
      kind, _reason ->
        # Observer exceptions can contain the private resource map. Only the
        # fixed stage and exception kind belong in a printable cleanup receipt.
        %{state | local_failures: state.local_failures ++ [{:checkpoint_failed, stage, kind}]}
    end
  end

  defp finish_terminal(state, {command, from, ref}, failures) when command in [:close, :finish] do
    retain? = state.registered? and command != :finish
    Process.demonitor(state.caller_monitor, [:flush])
    send(from, {ref, {failures, retain?}})
    complete(failures, retain?)
  end

  defp finish_terminal(state, {:joined, terminal, joins}, failures) do
    requests =
      case terminal do
        {command, _, _} when command in [:close, :finish] -> [terminal | joins]
        _ -> joins
      end

    retain? = state.registered? and not Enum.any?(requests, &(elem(&1, 0) == :finish))
    Process.demonitor(state.caller_monitor, [:flush])
    for {_command, from, ref} <- requests, do: send(from, {ref, {failures, retain?}})
    complete(failures, retain?)
  end

  defp finish_terminal(state, _terminal, failures) do
    Process.demonitor(state.caller_monitor, [:flush])
    complete(failures, state.registered?)
  end

  defp original_terminal({:joined, terminal, _joins}), do: terminal
  defp original_terminal(terminal), do: terminal

  defp complete(failures, true), do: closed(failures)
  defp complete([], false), do: :ok
  defp complete(failures, false), do: exit({:fixture_cleanup_failed, failures})

  defp failed_acquisition(%{caller: caller, caller_monitor: caller_monitor} = state, failures) do
    receive do
      {command, from, ref} when command in [:close, :finish] ->
        finish_terminal(state, {command, from, ref}, failures)

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        finish_terminal(state, :caller_down, failures)

      {:attach_child, child, _caller, edge_ref, reply_ref} ->
        reject_child(child, edge_ref, reply_ref, :parent_closed)
        failed_acquisition(state, failures)

      {:EXIT, _pid, _reason} ->
        failed_acquisition(state, failures)
    end
  end

  # Only the completion receipt remains here: no configuration, capabilities,
  # descriptors, destination handles or repeatable cleanup actions are retained.
  defp closed(failures) do
    receive do
      {{:acquire_child, _checkpoint, _options}, from, ref} ->
        send(from, {ref, {:relationship_error, :parent_closed}})
        closed(failures)

      {:attach_child, child, _caller, edge_ref, reply_ref} ->
        reject_child(child, edge_ref, reply_ref, :parent_closed)
        closed(failures)

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
