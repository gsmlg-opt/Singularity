defmodule Singularity.Runtime.KeyCustodian do
  @moduledoc """
  Session-scoped custody and synchronous revocation of opaque key leases.

  Argon2 work is intentionally excluded from this serialized process.
  """

  use GenServer

  alias Singularity.Core.Error
  alias Singularity.Runtime.KeyLease
  alias Singularity.Runtime.KeyLeaseSupervisor

  @request_fields ~w[
    job_id vault_id principal_id required_capability authorization_epoch
    object_id object_generation session_id
  ]a
  @default_pending_ttl_ms :timer.seconds(30)
  @default_idle_timeout_ms :timer.minutes(15)

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(adapters) do
    GenServer.start_link(__MODULE__, adapters)
  end

  @spec prepare_unlock(GenServer.server(), map()) ::
          {:ok, reference()} | {:error, Error.t()}
  def prepare_unlock(server, session) when not is_map(server) and is_map(session),
    do: GenServer.call(server, {:prepare_unlock, session}, :infinity)

  @spec prepare_unlock(map(), map() | binary()) ::
          {:ok, reference()} | {:error, Error.t()}
  def prepare_unlock(session, key_material) when is_map(session) do
    prepare_unlock(__MODULE__, merge_key_material(session, key_material))
  end

  @spec activate_unlock(GenServer.server(), reference()) ::
          :ok | {:error, Error.t()}
  def activate_unlock(server, pending),
    do: GenServer.call(server, {:activate_unlock, pending}, :infinity)

  @spec activate_unlock(reference()) :: :ok | {:error, Error.t()}
  def activate_unlock(pending), do: activate_unlock(__MODULE__, pending)

  @spec discard_pending(GenServer.server(), reference()) :: :ok
  def discard_pending(server, pending),
    do: GenServer.call(server, {:discard_pending, pending}, :infinity)

  @spec discard_pending(reference()) :: :ok
  def discard_pending(pending), do: discard_pending(__MODULE__, pending)

  @spec unlocked?(GenServer.server(), String.t()) :: boolean()
  def unlocked?(server, session_id),
    do: GenServer.call(server, {:unlocked?, session_id})

  @spec unlocked?(String.t()) :: boolean()
  def unlocked?(session_id), do: unlocked?(__MODULE__, session_id)

  @spec assert_unlocked(
          GenServer.server(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          :ok | {:error, Error.t()}
  def assert_unlocked(server, session_id, principal_id, vault_id),
    do:
      GenServer.call(
        server,
        {:assert_unlocked, session_id, principal_id, vault_id}
      )

  @spec assert_unlocked(String.t(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  def assert_unlocked(session_id, principal_id, vault_id),
    do: assert_unlocked(__MODULE__, session_id, principal_id, vault_id)

  @spec begin_revoke(GenServer.server(), map() | tuple()) ::
          :ok | {:error, Error.t()}
  def begin_revoke(server, selector),
    do: GenServer.call(server, {:begin_revoke, selector}, :infinity)

  @spec begin_revoke(map() | tuple()) :: :ok | {:error, Error.t()}
  def begin_revoke(selector), do: begin_revoke(__MODULE__, selector)

  @spec await_revoking(GenServer.server(), map() | tuple()) ::
          :ok | {:error, Error.t()}
  def await_revoking(server, selector),
    do: GenServer.call(server, {:await_revoking, selector}, :infinity)

  @spec await_revoking(map() | tuple()) :: :ok | {:error, Error.t()}
  def await_revoking(selector), do: await_revoking(__MODULE__, selector)

  @spec lease(GenServer.server(), map()) ::
          {:ok, KeyLease.ref()} | {:error, :waiting_for_unlock | Error.t()}
  def lease(server, request), do: GenServer.call(server, {:lease, request})

  @impl true
  def init(
        %{
          authorization: authorization,
          clock: clock,
          context: context,
          idle_lock: idle_lock,
          key_reader: key_reader,
          object_key_loader: object_key_loader,
          lease_supervisor: lease_supervisor
        } = adapters
      ) do
    {:ok,
     %{
       adapters: %{
         authorization: authorization,
         clock: clock,
         idle_lock: idle_lock,
         key_reader: key_reader,
         object_key_loader: object_key_loader
       },
       context: context,
       idle_timeout_ms:
         positive_option(
           Map.get(
             adapters,
             :idle_timeout_ms,
             Application.get_env(
               :singularity_runtime,
               :vault_idle_timeout_ms,
               @default_idle_timeout_ms
             )
           ),
           @default_idle_timeout_ms
         ),
       idle_timers: %{},
       lease_supervisor: lease_supervisor,
       leases: %{},
       monitors: %{},
       pending: %{},
       pending_monitors: %{},
       pending_ttl_ms:
         positive_option(
           Map.get(adapters, :pending_ttl_ms, @default_pending_ttl_ms),
           @default_pending_ttl_ms
         ),
       sessions: %{},
       wake_limit:
         adapters
         |> Map.get(:wake_limit, 25)
         |> positive_option(25)
         |> min(100),
       wake_waiting: Map.get(adapters, :wake_waiting)
     }}
  end

  @impl true
  def handle_call({:prepare_unlock, session}, {owner, _tag}, state) do
    case validate_session(session) do
      :ok ->
        pending = make_ref()
        monitor = Process.monitor(owner)
        timer = Process.send_after(self(), {:expire_pending, pending}, state.pending_ttl_ms)

        entry = %{
          monitor: monitor,
          owner: owner,
          session: sanitize_session(session),
          timer: timer
        }

        state =
          state
          |> discard_pending_for_session(session.session_id)
          |> put_in([:pending, pending], entry)
          |> put_in([:pending_monitors, monitor], pending)

        {:reply, {:ok, pending}, state}

      {:error, %Error{}} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:activate_unlock, pending}, {owner, _tag}, state) do
    case Map.get(state.pending, pending) do
      %{owner: ^owner, session: session} ->
        state =
          state
          |> discard_pending_entry(pending)
          |> revoke_session_custody(session.session_id)
          |> install_session(session)

        case activate_wake(state, session) do
          :ok ->
            {:reply, :ok, state}

          {:error, %Error{}} = error ->
            {:reply, error, revoke_session_custody(state, session.session_id)}
        end

      _missing_or_foreign ->
        {:reply, {:error, Error.new(:conflict)}, state}
    end
  end

  def handle_call({:discard_pending, pending}, _from, state) do
    {:reply, :ok, discard_pending_entry(state, pending)}
  end

  def handle_call({:unlocked?, session_id}, _from, state) do
    {:reply, active_session?(state, session_id), state}
  end

  def handle_call(
        {:assert_unlocked, session_id, principal_id, vault_id},
        _from,
        state
      ) do
    case Map.get(state.sessions, session_id) do
      %{principal_id: ^principal_id, vault_id: ^vault_id} ->
        {:reply, :ok, touch_session(state, session_id)}

      _locked_or_mismatched ->
        {:reply, {:error, Error.new(:vault_locked)}, state}
    end
  end

  def handle_call({:begin_revoke, selector}, _from, state) do
    case normalize_selector(selector) do
      {:ok, normalized} ->
        {:reply, :ok, begin_revocation(state, normalized)}

      :error ->
        {:reply, {:error, Error.new(:invalid)}, state}
    end
  end

  def handle_call({:await_revoking, selector}, _from, state) do
    case normalize_selector(selector) do
      {:ok, normalized} ->
        if any_matching_custody?(state, normalized) do
          {:reply, {:error, Error.new(:conflict)}, state}
        else
          {:reply, :ok, state}
        end

      :error ->
        {:reply, {:error, Error.new(:invalid)}, state}
    end
  end

  def handle_call({:lease, request}, _from, state) do
    with :ok <- validate_request(request),
         binding = Map.take(request, @request_fields),
         %{principal_id: principal_id, vault_id: vault_id} = session <-
           Map.get(state.sessions, binding.session_id),
         true <- vault_id == binding.vault_id,
         true <- principal_id == binding.principal_id,
         {:ok, object_dek} <- object_key(state, session, binding),
         {:ok, checkpoint} <-
           state.adapters.key_reader.load_checkpoint(state.context, binding),
         {:ok, _next_index} <- KeyLease.validate_checkpoint(checkpoint, binding),
         {:ok, lease} <- start_lease(state, binding, checkpoint, object_dek) do
      monitor = Process.monitor(lease)

      leases =
        Map.update(
          state.leases,
          binding.session_id,
          MapSet.new([lease]),
          &MapSet.put(&1, lease)
        )

      monitors = Map.put(state.monitors, monitor, {binding.session_id, lease})

      state =
        state
        |> Map.put(:leases, leases)
        |> Map.put(:monitors, monitors)
        |> touch_session(binding.session_id)

      {:reply, {:ok, lease}, state}
    else
      nil -> {:reply, {:error, :waiting_for_unlock}, state}
      false -> {:reply, {:error, :waiting_for_unlock}, state}
      {:error, :waiting_for_unlock} -> {:reply, {:error, :waiting_for_unlock}, state}
      {:error, %Error{}} = error -> {:reply, error, state}
      {:error, _reason} -> {:reply, {:error, Error.new(:storage_unavailable)}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, lease, _reason}, state) do
    case Map.pop(state.pending_monitors, monitor) do
      {pending, pending_monitors} when is_reference(pending) ->
        state =
          state
          |> Map.put(:pending_monitors, pending_monitors)
          |> discard_pending_entry(pending, false)

        {:noreply, state}

      {nil, _pending_monitors} ->
        {:noreply, handle_lease_down(state, monitor, lease)}
    end
  end

  def handle_info({:expire_pending, pending}, state) do
    {:noreply, discard_pending_entry(state, pending)}
  end

  def handle_info({:idle_lock, session_id, token}, state) do
    case Map.get(state.idle_timers, session_id) do
      {_timer, ^token} ->
        session = Map.get(state.sessions, session_id)
        state = begin_revocation(state, %{session_id: session_id})
        _idle_lock_result = persist_idle_lock(state, session)
        {:noreply, state}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:authorized_activity, session_id}, state) do
    if Map.has_key?(state.sessions, session_id) do
      {:noreply, touch_session(state, session_id)}
    else
      {:noreply, state}
    end
  end

  defp start_lease(state, request, checkpoint, object_dek) do
    KeyLeaseSupervisor.start_lease(state.lease_supervisor, %{
      authorization: state.adapters.authorization,
      binding: request,
      checkpoint: checkpoint,
      clock: state.adapters.clock,
      context: state.context,
      custodian: self(),
      key_material: object_dek,
      key_reader: state.adapters.key_reader
    })
  end

  defp validate_session(
         %{
           session_id: session_id,
           principal_id: principal_id,
           vault_id: vault_id,
           vault_key: <<_::binary-size(32)>>
         } = session
       )
       when is_binary(session_id) and byte_size(session_id) > 0 and
              is_binary(principal_id) and byte_size(principal_id) > 0 and
              is_binary(vault_id) and byte_size(vault_id) > 0,
       do: validate_optional_keys(session)

  defp validate_session(_session), do: {:error, Error.new(:invalid)}

  defp validate_optional_keys(session) do
    with true <- optional_key?(Map.get(session, :domain_key)),
         true <- valid_object_keys?(Map.get(session, :object_keys, %{})) do
      :ok
    else
      false -> {:error, Error.new(:invalid)}
    end
  end

  defp optional_key?(nil), do: true
  defp optional_key?(<<_::binary-size(32)>>), do: true
  defp optional_key?(_key), do: false

  defp valid_object_keys?(object_keys) when is_map(object_keys) do
    Enum.all?(object_keys, fn
      {{object_id, generation}, <<_::binary-size(32)>>}
      when is_binary(object_id) and byte_size(object_id) > 0 and
             is_integer(generation) and generation > 0 ->
        true

      _invalid ->
        false
    end)
  end

  defp valid_object_keys?(_object_keys), do: false

  defp validate_request(request) when is_map(request) do
    with true <- Enum.all?(@request_fields, &Map.has_key?(request, &1)),
         true <- nonempty_binary?(request.job_id),
         true <- nonempty_binary?(request.vault_id),
         true <- nonempty_binary?(request.principal_id),
         true <- nonempty_binary?(request.required_capability),
         true <- nonempty_binary?(request.object_id),
         true <- nonempty_binary?(request.session_id),
         true <-
           is_integer(request.authorization_epoch) and request.authorization_epoch >= 0,
         true <- is_integer(request.object_generation) and request.object_generation > 0 do
      :ok
    else
      false -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_request(_request), do: {:error, Error.new(:invalid)}

  defp nonempty_binary?(value),
    do: is_binary(value) and byte_size(String.trim(value)) > 0

  defp best_effort_overwrite(session) do
    for field <- [:vault_key, :domain_key] do
      case Map.get(session, field) do
        secret when is_binary(secret) -> :binary.copy(<<0>>, byte_size(secret))
        _absent -> :ok
      end
    end

    session
    |> Map.get(:object_keys, %{})
    |> Map.values()
    |> Enum.each(fn secret ->
      if is_binary(secret), do: :binary.copy(<<0>>, byte_size(secret))
    end)

    :ok
  end

  defp revoke_session_custody(state, session_id) do
    session_leases = Map.get(state.leases, session_id, MapSet.new())
    Enum.each(session_leases, &safe_revoke/1)

    monitors =
      Enum.reduce(state.monitors, %{}, fn
        {monitor, {^session_id, _lease}}, kept ->
          Process.demonitor(monitor, [:flush])
          kept

        {monitor, binding}, kept ->
          Map.put(kept, monitor, binding)
      end)

    sessions =
      case Map.pop(state.sessions, session_id) do
        {nil, sessions} ->
          sessions

        {session, sessions} ->
          best_effort_overwrite(session)
          sessions
      end

    state
    |> cancel_idle_timer(session_id)
    |> Map.put(:sessions, sessions)
    |> Map.put(:leases, Map.delete(state.leases, session_id))
    |> Map.put(:monitors, monitors)
  end

  defp safe_revoke(lease) do
    monitor = Process.monitor(lease)

    if Process.alive?(lease) do
      try do
        KeyLease.revoke(lease)
      catch
        :exit, _reason -> await_lease_termination(monitor, lease)
      end
    else
      await_lease_termination(monitor, lease)
    end

    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp await_lease_termination(monitor, lease) do
    receive do
      {:DOWN, ^monitor, :process, ^lease, _reason} -> :ok
    end
  end

  defp install_session(state, session) do
    state
    |> put_in([:sessions, session.session_id], session)
    |> touch_session(session.session_id)
  end

  defp sanitize_session(session) do
    Map.take(session, [
      :session_id,
      :account_id,
      :principal_id,
      :vault_id,
      :expires_at,
      :principal_authorization_epoch,
      :vault_authorization_epoch,
      :authorization_epoch,
      :vault_key,
      :domain_key,
      :object_keys
    ])
  end

  defp active_session?(state, session_id), do: Map.has_key?(state.sessions, session_id)

  defp begin_revocation(state, selector) do
    session_ids = matching_session_ids(state, selector)

    state =
      Enum.reduce(session_ids, state, fn session_id, current ->
        revoke_session_custody(current, session_id)
      end)

    Enum.reduce(Map.keys(state.pending), state, fn pending, current ->
      case Map.get(current.pending, pending) do
        %{session: session} ->
          if matches_selector?(session, selector) do
            discard_pending_entry(current, pending)
          else
            current
          end

        nil ->
          current
      end
    end)
  end

  defp matching_session_ids(_state, %{session_id: session_id}) do
    MapSet.new([session_id])
  end

  defp matching_session_ids(state, selector) do
    active =
      state.sessions
      |> Enum.filter(fn {_session_id, session} -> matches_selector?(session, selector) end)
      |> Enum.map(&elem(&1, 0))

    pending =
      state.pending
      |> Map.values()
      |> Enum.map(& &1.session)
      |> Enum.filter(&matches_selector?(&1, selector))
      |> Enum.map(& &1.session_id)

    MapSet.new(active ++ pending)
  end

  defp matches_selector?(session, %{session_id: session_id}),
    do: session.session_id == session_id

  defp matches_selector?(session, %{principal_id: principal_id}),
    do: Map.get(session, :principal_id) == principal_id

  defp matches_selector?(session, %{vault_id: vault_id}),
    do: session.vault_id == vault_id

  defp any_matching_custody?(state, selector) do
    Enum.any?(state.sessions, fn {_session_id, session} ->
      matches_selector?(session, selector)
    end) or
      Enum.any?(state.pending, fn {_pending, entry} ->
        matches_selector?(entry.session, selector)
      end)
  end

  defp normalize_selector(%{session_id: value}) when is_binary(value) and value != "",
    do: {:ok, %{session_id: value}}

  defp normalize_selector(%{principal_id: value}) when is_binary(value) and value != "",
    do: {:ok, %{principal_id: value}}

  defp normalize_selector(%{vault_id: value}) when is_binary(value) and value != "",
    do: {:ok, %{vault_id: value}}

  defp normalize_selector({:session, value}), do: normalize_selector(%{session_id: value})
  defp normalize_selector({:principal, value}), do: normalize_selector(%{principal_id: value})
  defp normalize_selector({:vault, value}), do: normalize_selector(%{vault_id: value})
  defp normalize_selector(_selector), do: :error

  defp discard_pending_for_session(state, session_id) do
    Enum.reduce(Map.keys(state.pending), state, fn pending, current ->
      case Map.get(current.pending, pending) do
        %{session: %{session_id: ^session_id}} ->
          discard_pending_entry(current, pending)

        _other ->
          current
      end
    end)
  end

  defp discard_pending_entry(state, pending, demonitor? \\ true) do
    case Map.pop(state.pending, pending) do
      {nil, _pending} ->
        state

      {%{monitor: monitor, session: session, timer: timer}, pending_entries} ->
        Process.cancel_timer(timer)

        if demonitor? do
          Process.demonitor(monitor, [:flush])
        end

        best_effort_overwrite(session)

        %{
          state
          | pending: pending_entries,
            pending_monitors: Map.delete(state.pending_monitors, monitor)
        }
    end
  end

  defp touch_session(state, session_id) do
    state = cancel_idle_timer(state, session_id)
    token = make_ref()
    timer = Process.send_after(self(), {:idle_lock, session_id, token}, state.idle_timeout_ms)
    put_in(state, [:idle_timers, session_id], {timer, token})
  end

  defp cancel_idle_timer(state, session_id) do
    case Map.pop(state.idle_timers, session_id) do
      {{timer, _token}, idle_timers} ->
        Process.cancel_timer(timer)
        %{state | idle_timers: idle_timers}

      {nil, _idle_timers} ->
        state
    end
  end

  defp handle_lease_down(state, monitor, lease) do
    case Map.pop(state.monitors, monitor) do
      {{session_id, ^lease}, monitors} ->
        session_leases =
          state.leases
          |> Map.get(session_id, MapSet.new())
          |> MapSet.delete(lease)

        leases =
          if MapSet.size(session_leases) == 0 do
            Map.delete(state.leases, session_id)
          else
            Map.put(state.leases, session_id, session_leases)
          end

        %{state | leases: leases, monitors: monitors}

      {nil, _monitors} ->
        state
    end
  end

  defp object_key(state, session, binding) do
    hierarchy = %{
      domain_key: Map.get(session, :domain_key),
      cached_object_keys: Map.get(session, :object_keys, %{})
    }

    case state.adapters.object_key_loader.load_object_key(
           state.context,
           binding,
           hierarchy
         ) do
      {:ok, <<_::binary-size(32)>> = object_dek} ->
        {:ok, object_dek}

      {:error, :waiting_for_unlock} ->
        {:error, :waiting_for_unlock}

      {:error, %Error{}} = error ->
        error

      _invalid ->
        {:error, Error.new(:integrity_failure)}
    end
  end

  defp wake_waiting(%{wake_waiting: nil}, _session), do: :ok

  defp wake_waiting(state, session) do
    call_optional_adapter(state.wake_waiting, :wake_waiting, [
      %{
        session_id: session.session_id,
        principal_id: session.principal_id,
        vault_id: session.vault_id,
        limit: state.wake_limit
      }
    ])
  end

  defp activate_wake(state, session) do
    case wake_waiting(state, session) do
      :ok -> :ok
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp persist_idle_lock(_state, nil), do: :ok

  defp persist_idle_lock(state, session) do
    call_optional_adapter(state.adapters.idle_lock, :idle_lock, [
      session
      |> Map.drop([:vault_key, :domain_key, :object_keys])
      |> Map.put(:reason, :idle_timeout)
    ])
  end

  defp call_optional_adapter(callback, _function, arguments)
       when is_function(callback, 1) do
    callback.(List.first(arguments))
  end

  defp call_optional_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_optional_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end

  defp positive_option(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_option(_value, default), do: default

  defp merge_key_material(session, key_material) when is_map(key_material),
    do: Map.merge(session, key_material)

  defp merge_key_material(session, <<_::binary-size(32)>> = vault_key),
    do: Map.put(session, :vault_key, vault_key)

  defp merge_key_material(session, _invalid), do: session
end
