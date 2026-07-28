defmodule Singularity.Runtime.DownloadLease do
  @moduledoc """
  One-use opaque custody for an authenticated full or ranged object read.

  The DEK remains inside this process. Revocation kills an in-flight reader
  before replying, so a queued vault lock wins without releasing plaintext.
  """

  use GenServer

  alias Singularity.Core.Error

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
        key_material: <<_::binary-size(32)>> = key_material,
        key_reader: key_reader
      })
      when is_map(binding) and is_pid(custodian) do
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
  def handle_call({:read, _range}, _from, %{pending: pending} = state)
      when not is_nil(pending) do
    {:reply, {:error, Error.new(:conflict)}, state}
  end

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

  def handle_call(:revoke, _from, state) do
    {:reply, :ok, revoke_state(state)}
  end

  @impl true
  def handle_info(
        {:download_read_complete, operation_ref, result},
        %{pending: %{operation_ref: operation_ref} = pending} = state
      ) do
    Process.demonitor(pending.monitor, [:flush])
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
        {:DOWN, monitor, :process, custodian, _reason},
        %{custodian: custodian, custodian_monitor: monitor} = state
      ) do
    {:stop, :normal, revoke_state(state)}
  end

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

    {worker, monitor} =
      spawn_monitor(fn ->
        result = perform_read(operation)
        send(lease, {:download_read_complete, operation_ref, result})
      end)

    %{
      state
      | pending: %{
          from: from,
          monitor: monitor,
          operation_ref: operation_ref,
          pid: worker
        }
    }
  end

  defp perform_read(operation) do
    with :ok <-
           operation.authorization.revalidate(
             operation.public_context,
             operation.binding
           ),
         {:ok, plaintext} <-
           operation.key_reader.read_range(
             operation.reader_context,
             operation.binding,
             operation.range
           ),
         :ok <-
           operation.authorization.revalidate(
             operation.public_context,
             operation.binding
           ) do
      {:ok, plaintext}
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  defp lease_status(%{revoked?: true}), do: :revoked

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
    state = cancel_pending(state)
    _overwritten = overwrite(Map.get(state.reader_context, :key_material))

    %{
      state
      | reader_context: Map.delete(state.reader_context, :key_material),
        revoked?: true
    }
  end

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

  defp overwrite(secret) when is_binary(secret),
    do: :binary.copy(<<0>>, byte_size(secret))

  defp overwrite(_secret), do: nil

  defp public_error(%Error{code: code, retryable?: retryable?}),
    do: Error.new(code, retryable?: retryable?)

  defp unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
