defmodule Singularity.Runtime.DownloadLease.ExportOwnership do
  @moduledoc false

  def new do
    %{
      deadline_ms: System.monotonic_time(:millisecond) + 5_000,
      state: :atomics.new(1, signed: false)
    }
  end

  def remaining_ms(ticket),
    do: max(ticket.deadline_ms - System.monotonic_time(:millisecond), 0)

  def status(ticket) do
    case :atomics.get(ticket.state, 1) do
      0 -> :pending
      1 -> :accepted
      2 -> :cancelled
    end
  end

  def accept(ticket) do
    if remaining_ms(ticket) > 0 do
      case :atomics.compare_exchange(ticket.state, 1, 0, 1) do
        result when result in [:ok, 1] ->
          if remaining_ms(ticket) > 0 and status(ticket) == :accepted do
            :ok
          else
            cancel(ticket)
            :cancelled
          end

        2 ->
          :cancelled
      end
    else
      cancel(ticket)
      :cancelled
    end
  end

  def cancel(ticket) do
    :atomics.put(ticket.state, 1, 2)
    :ok
  end

  def expire_pending(ticket) do
    case :atomics.compare_exchange(ticket.state, 1, 0, 2) do
      1 -> :accepted
      result when result in [:ok, 2] -> :cancelled
    end
  end
end

defmodule Singularity.Runtime.DownloadLease do
  @moduledoc """
  One-use opaque custody for an authenticated full or ranged object read.

  The DEK remains inside this process. Revocation kills an in-flight reader
  before replying, so a queued vault lock wins without releasing plaintext.
  """

  use GenServer

  alias Singularity.Core.Error
  alias Singularity.Runtime.DownloadLease.ExportOwnership

  @lease_seconds 60

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec read(pid(), :all | Range.t()) ::
          {:ok, binary()} | {:error, :waiting_for_unlock | Error.t()}
  def read(lease, range) when is_pid(lease) do
    GenServer.call(lease, {:read, range}, :infinity)
  catch
    :exit, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def read(_lease, _range), do: {:error, Error.new(:invalid)}

  @spec read_document_chunk(pid(), non_neg_integer()) ::
          {:ok, binary()} | {:error, :waiting_for_unlock | Error.t()}
  def read_document_chunk(lease, index)
      when is_pid(lease) and is_integer(index) and index >= 0 do
    GenServer.call(lease, {:read_document_chunk, index}, :infinity)
  catch
    :exit, _reason -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def read_document_chunk(_lease, _index), do: {:error, Error.new(:invalid)}

  @spec authenticate_empty_document_source(pid()) ::
          :ok | {:error, :waiting_for_unlock | Error.t()}
  def authenticate_empty_document_source(lease) when is_pid(lease) do
    GenServer.call(lease, :authenticate_empty_document_source, :infinity)
  catch
    :exit, _reason -> unavailable()
  end

  def authenticate_empty_document_source(_lease), do: {:error, Error.new(:invalid)}

  @spec authenticate_empty_document_original(pid()) ::
          :ok | {:error, :waiting_for_unlock | Error.t()}
  def authenticate_empty_document_original(lease) when is_pid(lease) do
    GenServer.call(lease, :authenticate_empty_document_original, :infinity)
  catch
    :exit, _reason -> unavailable()
  end

  def authenticate_empty_document_original(_lease), do: {:error, Error.new(:invalid)}

  @spec revoke(pid()) :: :ok
  def revoke(lease) when is_pid(lease),
    do: GenServer.call(lease, :revoke, :infinity)

  @impl true
  def init(%{
        authorization: authorization,
        binding: binding,
        clock: clock,
        context: context,
        custodian: custodian,
        export_ownership: %{owner_pid: owner, ticket: ticket} = ownership,
        key_material: <<_::binary-size(32)>> = key_material,
        key_reader: key_reader
      })
      when is_map(binding) and is_pid(custodian) and is_pid(owner) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)
    Process.send_after(self(), :export_acquisition_expired, ExportOwnership.remaining_ms(ticket))

    with :ok <- export_acquisition_status(ownership),
         now = clock.utc_now(context),
         :ok <- export_acquisition_status(ownership) do
      custodian_monitor = Process.monitor(custodian)
      Process.send_after(self(), :expire, @lease_seconds * 1_000)

      {:ok,
       %{
         authorization: authorization,
         binding: binding,
         clock: clock,
         custodian: custodian,
         custodian_monitor: custodian_monitor,
         expires_at: DateTime.add(now, @lease_seconds, :second),
         export_ownership: ownership,
         export_owner_monitor: owner_monitor,
         key_reader: key_reader,
         mode: nil,
         consumer_pid: nil,
         consumer_monitor: nil,
         next_index: 0,
         pending: nil,
         public_context: Map.delete(context, :key_material),
         reader_context: Map.put(context, :key_material, key_material),
         revoked?: false
       }}
    else
      :cancelled ->
        ExportOwnership.cancel(ticket)
        {:stop, :normal}
    end
  end

  def init(
        %{
          authorization: authorization,
          binding: binding,
          clock: clock,
          context: context,
          custodian: custodian,
          key_material: <<_::binary-size(32)>> = key_material,
          key_reader: key_reader
        } = options
      )
      when is_map(binding) and is_pid(custodian) do
    mode = Map.get(options, :mode)
    consumer = Map.get(options, :consumer_pid)

    consumer_monitor =
      if mode == :document_worker_source do
        Process.flag(:trap_exit, true)
        Process.monitor(consumer)
      end

    expires_at =
      context
      |> clock.utc_now()
      |> DateTime.add(@lease_seconds, :second)

    custodian_monitor = Process.monitor(custodian)
    Process.send_after(self(), :expire, @lease_seconds * 1_000)

    {:ok,
     %{
       authorization: authorization,
       binding: binding,
       clock: clock,
       custodian: custodian,
       custodian_monitor: custodian_monitor,
       expires_at: expires_at,
       key_reader: key_reader,
       mode: mode,
       consumer_pid: consumer,
       consumer_monitor: consumer_monitor,
       next_index: 0,
       pending: nil,
       public_context: Map.delete(context, :key_material),
       reader_context: Map.put(context, :key_material, key_material),
       revoked?: false
     }}
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} ->
        {:state,
         %{
           custody: "[REDACTED]",
           pending?: not is_nil(Map.get(state, :pending)),
           revoked?: Map.get(state, :revoked?, false)
         }}

      {:message, _message} ->
        {:message, "[REDACTED]"}

      key_value ->
        key_value
    end)
  end

  @impl true
  def handle_call({:read, _range}, _from, %{mode: :document_worker_source} = state),
    do: {:reply, {:error, Error.new(:invalid)}, state}

  def handle_call({:read, _range}, _from, %{pending: pending} = state)
      when not is_nil(pending) do
    {:reply, {:error, Error.new(:conflict)}, state}
  end

  def handle_call(
        {:read, _range},
        _from,
        %{binding: %{access: :request, resource_version_id: _}} = state
      ),
      do: {:reply, {:error, Error.new(:invalid)}, state}

  def handle_call({:read, range}, from, state) do
    with :active <- lease_status(state),
         true <- valid_range?(range) do
      {:noreply, start_read(state, from, range)}
    else
      :revoked ->
        {:reply, {:error, :waiting_for_unlock}, state}

      :expired ->
        {:reply, {:error, :waiting_for_unlock}, revoke_state(state)}

      false ->
        {:reply, {:error, Error.new(:invalid)}, state}
    end
  end

  def handle_call(
        {:read_document_chunk, _index},
        {caller, _tag},
        %{mode: :document_worker_source, consumer_pid: consumer} = state
      )
      when caller != consumer,
      do: {:reply, {:error, Error.new(:forbidden)}, state}

  def handle_call({:read_document_chunk, _index}, _from, %{pending: pending} = state)
      when not is_nil(pending),
      do: {:reply, {:error, Error.new(:conflict)}, state}

  def handle_call(
        {:read_document_chunk, index},
        from,
        %{mode: :document_worker_source} = state
      ) do
    with :active <- lease_status(state),
         true <- is_integer(index) and index >= 0 and index == state.next_index do
      {:noreply, start_read(state, from, {:document_chunk, index})}
    else
      :revoked -> {:stop, :normal, {:error, :waiting_for_unlock}, revoke_state(state)}
      :expired -> {:stop, :normal, {:error, :waiting_for_unlock}, revoke_state(state)}
      false -> {:reply, {:error, Error.new(:conflict)}, state}
    end
  end

  def handle_call(
        {:read_document_chunk, index},
        from,
        %{binding: %{access: :request, resource_version_id: _}} = state
      ) do
    with :active <- lease_status(state),
         true <- index == state.next_index do
      {:noreply, start_read(state, from, {:document_chunk, index})}
    else
      :revoked -> {:reply, {:error, :waiting_for_unlock}, state}
      :expired -> {:reply, {:error, :waiting_for_unlock}, revoke_state(state)}
      false -> {:reply, {:error, Error.new(:conflict)}, state}
    end
  end

  def handle_call({:read_document_chunk, _index}, _from, state),
    do: {:reply, {:error, Error.new(:invalid)}, state}

  def handle_call(
        :authenticate_empty_document_source,
        {caller, _tag},
        %{mode: :document_worker_source, consumer_pid: consumer} = state
      )
      when caller != consumer,
      do: {:reply, {:error, Error.new(:forbidden)}, state}

  def handle_call(
        :authenticate_empty_document_source,
        _from,
        %{mode: :document_worker_source, pending: pending} = state
      )
      when not is_nil(pending),
      do: {:reply, {:error, Error.new(:conflict)}, state}

  def handle_call(
        :authenticate_empty_document_source,
        from,
        %{
          mode: :document_worker_source,
          next_index: 0,
          reader_context: %{object_binding: %{plaintext_byte_size: 0}}
        } = state
      ) do
    case lease_status(state) do
      :active -> {:noreply, start_read(state, from, :empty_document_source)}
      _inactive -> {:stop, :normal, {:error, :waiting_for_unlock}, revoke_state(state)}
    end
  end

  def handle_call(:authenticate_empty_document_source, _from, state),
    do: {:reply, {:error, Error.new(:invalid)}, state}

  def handle_call(
        :authenticate_empty_document_original,
        _from,
        %{
          mode: nil,
          binding: %{access: :request, resource_version_id: _},
          pending: pending
        } = state
      )
      when not is_nil(pending),
      do: {:reply, {:error, Error.new(:conflict)}, state}

  def handle_call(
        :authenticate_empty_document_original,
        from,
        %{
          mode: nil,
          binding: %{access: :request, resource_version_id: _},
          next_index: 0,
          reader_context: %{object_binding: %{plaintext_byte_size: 0}}
        } = state
      ) do
    case lease_status(state) do
      :active -> {:noreply, start_read(state, from, :empty_document_original)}
      _inactive -> {:reply, {:error, :waiting_for_unlock}, revoke_state(state)}
    end
  end

  def handle_call(:authenticate_empty_document_original, _from, state),
    do: {:reply, {:error, Error.new(:invalid)}, state}

  def handle_call(:revoke, _from, %{export_ownership: _ownership} = state),
    do: {:stop, :normal, :ok, revoke_state(state)}

  def handle_call(:revoke, _from, %{mode: :document_worker_source} = state),
    do: {:stop, :normal, :ok, revoke_state(state)}

  def handle_call(:revoke, _from, state) do
    {:reply, :ok, revoke_state(state)}
  end

  @impl true
  def handle_info(
        {:download_read_complete, operation_ref, result},
        %{
          mode: :document_worker_source,
          pending: %{operation_ref: operation_ref, range: :empty_document_source} = pending
        } = state
      ) do
    finish_reader(state, pending)
    state = %{state | pending: nil}

    reply =
      case {lease_status(state), result} do
        {:active, {:ok, ""}} ->
          send(state.custodian, {:authorized_activity, state.binding.session_id})
          :ok

        {:active, {:error, :waiting_for_unlock}} ->
          {:error, :waiting_for_unlock}

        {:active, {:error, %Error{} = error}} ->
          {:error, public_error(error)}

        {:active, _invalid} ->
          {:error, Error.new(:integrity_failure)}

        {_inactive, _result} ->
          {:error, :waiting_for_unlock}
      end

    state = revoke_state(state)
    GenServer.reply(pending.from, reply)
    {:stop, :normal, state}
  end

  def handle_info(
        {:download_read_complete, operation_ref, result},
        %{
          mode: nil,
          pending: %{operation_ref: operation_ref, range: :empty_document_original} = pending
        } = state
      ) do
    finish_reader(state, pending)
    state = %{state | pending: nil}

    reply =
      case {lease_status(state), result} do
        {:active, {:ok, ""}} ->
          send(state.custodian, {:authorized_activity, state.binding.session_id})
          :ok

        {:active, {:error, :waiting_for_unlock}} ->
          {:error, :waiting_for_unlock}

        {:active, {:error, %Error{} = error}} ->
          {:error, public_error(error)}

        {:active, _invalid} ->
          {:error, Error.new(:integrity_failure)}

        {_inactive, _result} ->
          {:error, :waiting_for_unlock}
      end

    state = revoke_state(state)
    GenServer.reply(pending.from, reply)
    {:noreply, state}
  end

  def handle_info(
        {:download_read_complete, operation_ref, {:ok, plaintext}},
        %{pending: %{operation_ref: operation_ref, range: {:document_chunk, index}} = pending} =
          state
      )
      when is_binary(plaintext) do
    finish_reader(state, pending)
    state = %{state | pending: nil}

    case lease_status(state) do
      :active ->
        send(state.custodian, {:authorized_activity, state.binding.session_id})
        GenServer.reply(pending.from, {:ok, plaintext})
        {:noreply, %{state | next_index: index + 1}}

      _expired_or_revoked ->
        GenServer.reply(pending.from, {:error, :waiting_for_unlock})
        {:stop, :normal, revoke_state(state)}
    end
  end

  def handle_info(
        {:download_read_complete, operation_ref, result},
        %{pending: %{operation_ref: operation_ref} = pending} = state
      ) do
    finish_reader(state, pending)
    state = %{state | pending: nil}

    case {lease_status(state), result} do
      {:active, {:ok, plaintext}} when is_binary(plaintext) ->
        send(state.custodian, {:authorized_activity, state.binding.session_id})
        GenServer.reply(pending.from, {:ok, plaintext})
        {:stop, :normal, revoke_state(state)}

      {:active, {:error, :waiting_for_unlock}} ->
        GenServer.reply(pending.from, {:error, :waiting_for_unlock})
        {:stop, :normal, revoke_state(state)}

      {:active, {:error, %Error{}} = error} ->
        GenServer.reply(pending.from, {:error, public_error(elem(error, 1))})
        {:stop, :normal, revoke_state(state)}

      {:active, _invalid} ->
        GenServer.reply(
          pending.from,
          {:error, Error.new(:storage_unavailable, retryable?: true)}
        )

        {:stop, :normal, revoke_state(state)}

      {_revoked_or_expired, _result} ->
        GenServer.reply(pending.from, {:error, :waiting_for_unlock})
        {:stop, :normal, revoke_state(state)}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        %{pending: %{monitor: monitor, pid: worker} = pending} = state
      ) do
    GenServer.reply(
      pending.from,
      {:error, Error.new(:storage_unavailable, retryable?: true)}
    )

    {:stop, :normal, state |> Map.put(:pending, nil) |> revoke_state()}
  end

  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{
          export_ownership: %{owner_pid: owner},
          export_owner_monitor: monitor
        } = state
      ),
      do: {:stop, :normal, revoke_state(state)}

  def handle_info(
        {:DOWN, monitor, :process, consumer, _reason},
        %{
          mode: :document_worker_source,
          consumer_pid: consumer,
          consumer_monitor: monitor
        } = state
      ),
      do: {:stop, :normal, revoke_state(state)}

  def handle_info(
        {:DOWN, monitor, :process, custodian, _reason},
        %{custodian: custodian, custodian_monitor: monitor} = state
      ) do
    {:stop, :normal, revoke_state(state)}
  end

  def handle_info(:export_acquisition_expired, %{export_ownership: ownership} = state) do
    case ExportOwnership.expire_pending(ownership.ticket) do
      :accepted -> {:noreply, state}
      :cancelled -> {:stop, :normal, revoke_state(state)}
    end
  end

  def handle_info(:expire, %{export_ownership: _ownership} = state),
    do: {:stop, :normal, revoke_state(state)}

  def handle_info(:expire, %{mode: :document_worker_source} = state),
    do: {:stop, :normal, revoke_state(state)}

  def handle_info(
        {:EXIT, reader, _reason},
        %{mode: :document_worker_source, pending: %{pid: reader}} = state
      ),
      do: {:noreply, state}

  def handle_info(:expire, state),
    do: {:noreply, revoke_state(state)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _state = revoke_state(state)
    :ok
  end

  defp start_read(state, from, range) do
    lease = self()
    operation_ref = make_ref()

    operation = %{
      authorization: state.authorization,
      binding: state.binding,
      key_reader: state.key_reader,
      public_context: state.public_context,
      range: range,
      reader_context: state.reader_context
    }

    operation = Map.merge(operation, Map.take(state, [:export_ownership]))

    reader = fn ->
      result = perform_read(operation)
      send(lease, {:download_read_complete, operation_ref, result})
    end

    {worker, monitor} =
      if state.mode == :document_worker_source or Map.has_key?(state, :export_ownership),
        do: :erlang.spawn_opt(reader, [:link, :monitor]),
        else: spawn_monitor(reader)

    %{
      state
      | pending: %{
          from: from,
          monitor: monitor,
          operation_ref: operation_ref,
          pid: worker,
          range: range
        }
    }
  end

  defp perform_read(operation) do
    with :ok <- export_read_status(operation),
         :ok <-
           operation.authorization.revalidate(
             operation.public_context,
             operation.binding
           ),
         :ok <- export_read_status(operation),
         {:ok, plaintext} <- read_operation(operation),
         :ok <-
           operation.authorization.revalidate(
             operation.public_context,
             operation.binding
           ),
         :ok <- export_read_status(operation) do
      {:ok, plaintext}
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  defp read_operation(%{range: {:document_chunk, index}} = operation),
    do: operation.key_reader.read_chunk(operation.reader_context, operation.binding, index)

  defp read_operation(%{range: :empty_document_source} = operation),
    do: operation.key_reader.read_range(operation.reader_context, operation.binding, :all)

  defp read_operation(%{range: :empty_document_original} = operation),
    do: operation.key_reader.read_range(operation.reader_context, operation.binding, :all)

  defp read_operation(operation),
    do:
      operation.key_reader.read_range(
        operation.reader_context,
        operation.binding,
        operation.range
      )

  defp lease_status(%{revoked?: true}), do: :revoked

  defp lease_status(%{export_ownership: _ownership} = state) do
    with :ok <- export_read_status(state),
         :lt <- DateTime.compare(state.clock.utc_now(state.public_context), state.expires_at),
         :ok <- export_read_status(state) do
      :active
    else
      {:error, :waiting_for_unlock} -> :revoked
      _expired -> :expired
    end
  end

  defp lease_status(state) do
    case DateTime.compare(
           state.clock.utc_now(state.public_context),
           state.expires_at
         ) do
      :lt -> :active
      _expired -> :expired
    end
  end

  defp revoke_state(%{revoked?: true} = state), do: state

  defp revoke_state(state) do
    if Map.has_key?(state, :export_ownership),
      do: ExportOwnership.cancel(state.export_ownership.ticket)

    state = cancel_pending(state)
    _overwritten = overwrite(Map.get(state.reader_context, :key_material))

    %{
      state
      | reader_context: Map.delete(state.reader_context, :key_material),
        revoked?: true
    }
  end

  defp finish_reader(%{export_ownership: _ownership}, pending) do
    Process.exit(pending.pid, :kill)

    receive do
      {:DOWN, monitor, :process, reader, _reason}
      when monitor == pending.monitor and reader == pending.pid ->
        :ok
    end
  end

  defp finish_reader(%{mode: :document_worker_source}, pending) do
    Process.exit(pending.pid, :kill)

    receive do
      {:DOWN, monitor, :process, reader, _reason}
      when monitor == pending.monitor and reader == pending.pid ->
        :ok
    end
  end

  defp finish_reader(_state, pending), do: Process.demonitor(pending.monitor, [:flush])

  defp cancel_pending(%{pending: nil} = state), do: state

  defp cancel_pending(%{pending: pending} = state) do
    Process.exit(pending.pid, :kill)

    receive do
      {:DOWN, monitor, :process, worker, _reason}
      when monitor == pending.monitor and worker == pending.pid ->
        :ok
    end

    GenServer.reply(pending.from, {:error, :waiting_for_unlock})
    %{state | pending: nil}
  end

  defp valid_range?(:all), do: true

  defp valid_range?(%Range{first: first, last: last, step: 1}),
    do:
      is_integer(first) and first >= 0 and is_integer(last) and
        last >= first

  defp valid_range?(_range), do: false

  defp export_acquisition_status(%{owner_pid: owner, ticket: ticket}) do
    if Process.alive?(owner) and ExportOwnership.status(ticket) != :cancelled and
         ExportOwnership.remaining_ms(ticket) > 0,
       do: :ok,
       else: :cancelled
  end

  defp export_read_status(%{export_ownership: %{owner_pid: owner, ticket: ticket}}) do
    if Process.alive?(owner) and ExportOwnership.status(ticket) == :accepted,
      do: :ok,
      else: {:error, :waiting_for_unlock}
  end

  defp export_read_status(_ordinary), do: :ok

  defp overwrite(secret) when is_binary(secret),
    do: :binary.copy(<<0>>, byte_size(secret))

  defp overwrite(_secret), do: nil

  defp public_error(%Error{code: code, retryable?: retryable?}),
    do: Error.new(code, retryable?: retryable?)

  defp unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
