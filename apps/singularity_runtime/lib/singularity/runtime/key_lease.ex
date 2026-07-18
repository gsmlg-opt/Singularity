defmodule Singularity.Runtime.KeyLease do
  @moduledoc """
  Opaque, 60-second custody for one authenticated object reader.

  The process retains only the reader's object key material, revalidates the
  full binding before each chunk, and advances an externally persisted
  compare-and-swap checkpoint before returning plaintext. It overwrites its
  temporary key reference on a best-effort basis when revoked or terminated.
  BEAM binary zeroization is not deterministic and is not claimed here.
  """

  use GenServer

  alias Singularity.Core.Error

  @lease_seconds 60
  @termination_grace_seconds 5
  @checkpoint_version 1
  @checkpoint_keys ~w[
    version next_chunk_index job_id vault_id principal_id required_capability
    authorization_epoch object_id object_generation
  ]

  @type ref :: pid()

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @spec read_chunk(ref(), non_neg_integer()) ::
          {:ok, binary()} | {:error, :waiting_for_unlock | Error.t() | atom()}
  def read_chunk(lease, index) when is_pid(lease) and is_integer(index) and index >= 0 do
    GenServer.call(lease, {:read_chunk, index}, :infinity)
  end

  def read_chunk(_lease, _index), do: {:error, Error.new(:invalid)}

  @spec revoke(ref()) :: :ok
  def revoke(lease) when is_pid(lease), do: GenServer.call(lease, :revoke, :infinity)

  @doc false
  @spec checkpoint(map(), non_neg_integer()) :: map()
  def checkpoint(binding, next_chunk_index)
      when is_map(binding) and is_integer(next_chunk_index) and next_chunk_index >= 0 do
    %{
      "version" => @checkpoint_version,
      "next_chunk_index" => next_chunk_index,
      "job_id" => binding.job_id,
      "vault_id" => binding.vault_id,
      "principal_id" => binding.principal_id,
      "required_capability" => binding.required_capability,
      "authorization_epoch" => binding.authorization_epoch,
      "object_id" => binding.object_id,
      "object_generation" => binding.object_generation
    }
  end

  @doc false
  @spec validate_checkpoint(map(), map()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def validate_checkpoint(
        %{
          "version" => @checkpoint_version,
          "next_chunk_index" => next_chunk_index
        } = persisted,
        binding
      )
      when is_integer(next_chunk_index) and next_chunk_index >= 0 and is_map(binding) do
    expected = checkpoint(binding, next_chunk_index)

    cond do
      Enum.sort(Map.keys(persisted)) != Enum.sort(@checkpoint_keys) ->
        {:error, Error.new(:integrity_failure)}

      persisted != expected ->
        {:error, Error.new(:conflict)}

      true ->
        {:ok, next_chunk_index}
    end
  end

  def validate_checkpoint(_persisted, _binding),
    do: {:error, Error.new(:integrity_failure)}

  def child_spec(options) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init(%{
        authorization: authorization,
        binding: binding,
        checkpoint: checkpoint,
        clock: clock,
        context: context,
        custodian: custodian,
        key_material: <<_::binary-size(32)>> = key_material,
        key_reader: key_reader
      })
      when is_pid(custodian) do
    with {:ok, next_index} <- validate_checkpoint(checkpoint, binding) do
      now = clock.utc_now(context)
      expires_at = DateTime.add(now, @lease_seconds, :second)
      custodian_monitor = Process.monitor(custodian)
      Process.send_after(self(), :expire, @lease_seconds * 1_000)

      Process.send_after(
        self(),
        :terminate_expired,
        (@lease_seconds + @termination_grace_seconds) * 1_000
      )

      {:ok,
       %{
         authorization: authorization,
         binding: binding,
         checkpoint: checkpoint,
         checkpoint_context: Map.delete(context, :key_material),
         clock: clock,
         custodian: custodian,
         custodian_monitor: custodian_monitor,
         expires_at: expires_at,
         key_reader: key_reader,
         next_index: next_index,
         pending: nil,
         reader_context: Map.put(context, :key_material, key_material),
         revoked?: false
       }}
    end
  end

  @impl true
  def handle_call({:read_chunk, _index}, _from, %{pending: pending} = state)
      when not is_nil(pending) do
    {:reply, {:error, Error.new(:conflict)}, state}
  end

  def handle_call({:read_chunk, index}, from, state) do
    with false <- state.revoked?,
         :lt <-
           DateTime.compare(
             state.clock.utc_now(state.checkpoint_context),
             state.expires_at
           ),
         :ok <- require_next_index(index, state.next_index) do
      {:noreply, start_read(state, from, index)}
    else
      true ->
        reply_waiting_and_revoke(from, state)

      :eq ->
        reply_waiting_and_revoke(from, state)

      :gt ->
        reply_waiting_and_revoke(from, state)

      {:error, :checkpoint_sequence} ->
        reply_error_and_revoke(from, Error.new(:conflict), state)
    end
  end

  def handle_call(:revoke, _from, state) do
    {:reply, :ok, revoke_state(state)}
  end

  @impl true
  def handle_info(
        {:key_lease_read_complete, operation_ref, result},
        %{pending: %{operation_ref: operation_ref} = pending} = state
      ) do
    Process.demonitor(pending.monitor, [:flush])
    state = %{state | pending: nil}

    case lease_status(state) do
      :active ->
        finish_read(result, pending, state)

      :revoked ->
        GenServer.reply(pending.from, {:error, :waiting_for_unlock})
        {:noreply, revoke_state(state)}

      :expired ->
        GenServer.reply(pending.from, {:error, :waiting_for_unlock})
        {:noreply, revoke_state(state)}
    end
  end

  def handle_info({:key_lease_read_complete, _operation_ref, _result}, state) do
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        %{pending: %{monitor: monitor, pid: worker} = pending} = state
      ) do
    GenServer.reply(
      pending.from,
      {:error, Error.new(:storage_unavailable, retryable?: true)}
    )

    {:noreply, state |> Map.put(:pending, nil) |> revoke_state()}
  end

  def handle_info(
        {:DOWN, monitor, :process, custodian, _reason},
        %{custodian: custodian, custodian_monitor: monitor} = state
      ) do
    {:stop, :normal, revoke_state(state)}
  end

  def handle_info(:expire, state) do
    {:noreply, revoke_state(state)}
  end

  def handle_info(:terminate_expired, state) do
    {:stop, :normal, revoke_state(state)}
  end

  def handle_info({:DOWN, _monitor, :process, _process, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    state = cancel_pending(state, {:error, :waiting_for_unlock})
    _overwritten = overwrite(Map.get(state.reader_context, :key_material))
    :ok
  end

  defp start_read(state, from, index) do
    lease = self()
    operation_ref = make_ref()

    operation = %{
      authorization: state.authorization,
      binding: state.binding,
      checkpoint: state.checkpoint,
      checkpoint_context: state.checkpoint_context,
      index: index,
      key_reader: state.key_reader,
      reader_context: state.reader_context
    }

    {worker, monitor} =
      spawn_monitor(fn ->
        result = perform_read(operation)
        send(lease, {:key_lease_read_complete, operation_ref, result})
      end)

    %{
      state
      | pending: %{
          from: from,
          index: index,
          monitor: monitor,
          operation_ref: operation_ref,
          pid: worker
        }
    }
  end

  defp perform_read(operation) do
    with :ok <-
           operation.authorization.revalidate(
             operation.checkpoint_context,
             operation.binding
           ),
         {:ok, chunk} <-
           operation.key_reader.read_chunk(
             operation.reader_context,
             operation.binding,
             operation.index
           ),
         :ok <-
           operation.authorization.revalidate(
             operation.checkpoint_context,
             operation.binding
           ) do
      {:ok, chunk}
    end
  end

  defp finish_read({:ok, chunk}, pending, state) do
    case persist_completed_read(state, pending.index) do
      {:ok, next_checkpoint} ->
        send(state.custodian, {:authorized_activity, state.binding.session_id})
        GenServer.reply(pending.from, {:ok, chunk})

        {:noreply, %{state | checkpoint: next_checkpoint, next_index: pending.index + 1}}

      {:error, :waiting_for_unlock} ->
        GenServer.reply(pending.from, {:error, :waiting_for_unlock})
        {:noreply, revoke_state(state)}

      {:error, %Error{} = error} ->
        GenServer.reply(pending.from, {:error, error})
        {:noreply, revoke_state(state)}
    end
  end

  defp finish_read({:error, :waiting_for_unlock}, pending, state) do
    GenServer.reply(pending.from, {:error, :waiting_for_unlock})
    {:noreply, revoke_state(state)}
  end

  defp finish_read({:error, %Error{} = error}, pending, state) do
    GenServer.reply(pending.from, {:error, error})
    {:noreply, revoke_state(state)}
  end

  defp finish_read({:error, reason}, pending, state) do
    GenServer.reply(pending.from, {:error, reason})
    {:noreply, state}
  end

  defp finish_read(_unexpected, pending, state) do
    GenServer.reply(pending.from, {:error, Error.new(:job_failed)})
    {:noreply, revoke_state(state)}
  end

  defp persist_completed_read(state, index) do
    with :active <- lease_status(state),
         :ok <-
           state.authorization.revalidate(
             state.checkpoint_context,
             state.binding
           ),
         :active <- lease_status(state),
         next_checkpoint = checkpoint(state.binding, index + 1),
         :ok <-
           state.key_reader.persist_checkpoint(
             state.checkpoint_context,
             state.binding,
             state.checkpoint,
             next_checkpoint
           ) do
      {:ok, next_checkpoint}
    else
      status when status in [:revoked, :expired] ->
        {:error, :waiting_for_unlock}

      {:error, :waiting_for_unlock} ->
        {:error, :waiting_for_unlock}

      {:error, %Error{}} = error ->
        error

      _unexpected ->
        {:error, Error.new(:job_failed)}
    end
  end

  defp reply_waiting_and_revoke(from, state) do
    GenServer.reply(from, {:error, :waiting_for_unlock})
    {:noreply, revoke_state(state)}
  end

  defp reply_error_and_revoke(from, error, state) do
    GenServer.reply(from, {:error, error})
    {:noreply, revoke_state(state)}
  end

  defp require_next_index(index, index), do: :ok
  defp require_next_index(_index, _expected), do: {:error, :checkpoint_sequence}

  defp lease_status(%{revoked?: true}), do: :revoked

  defp lease_status(state) do
    case DateTime.compare(
           state.clock.utc_now(state.checkpoint_context),
           state.expires_at
         ) do
      :lt -> :active
      _expired -> :expired
    end
  end

  defp revoke_state(%{revoked?: true} = state), do: state

  defp revoke_state(state) do
    state = cancel_pending(state, {:error, :waiting_for_unlock})
    overwritten = overwrite(Map.get(state.reader_context, :key_material))

    %{
      state
      | reader_context:
          state.reader_context
          |> Map.put(:key_material, overwritten)
          |> Map.delete(:key_material),
        revoked?: true
    }
  end

  defp cancel_pending(%{pending: nil} = state, _reply), do: state

  defp cancel_pending(%{pending: pending} = state, reply) do
    monitor = pending.monitor
    worker = pending.pid
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end

    GenServer.reply(pending.from, reply)
    %{state | pending: nil}
  end

  defp overwrite(secret) when is_binary(secret),
    do: :binary.copy(<<0>>, byte_size(secret))

  defp overwrite(_secret), do: nil
end
