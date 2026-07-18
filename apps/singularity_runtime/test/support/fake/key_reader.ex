defmodule Fake.KeyReader do
  @moduledoc false

  use Agent

  alias Singularity.Core.Error

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(options) do
    Agent.start_link(fn ->
      %{
        calls: [],
        checkpoint_loads: [],
        checkpoint_persists: [],
        checkpoints: Keyword.get(options, :checkpoints, %{}),
        chunks: Keyword.fetch!(options, :chunks),
        block_next_read?: false,
        block_after_next_persist?: false,
        fail_next_persist?: false,
        owner: Keyword.fetch!(options, :owner)
      }
    end)
  end

  @spec read_chunk(map(), map(), non_neg_integer()) ::
          {:ok, binary()} | {:error, :not_found}
  def read_chunk(%{key_reader: key_reader}, binding, index)
      when is_map(binding) and is_integer(index) and index >= 0 do
    case Agent.get_and_update(key_reader, &prepare_read(&1, binding, index)) do
      {:ready, result} ->
        result

      {:blocked, owner, token, result} ->
        send(owner, {:key_reader_blocked, self(), token, binding, index})

        receive do
          {:release_key_reader, ^token} -> result
        end
    end
  end

  @spec calls(map()) :: [{map(), non_neg_integer()}]
  def calls(%{key_reader: key_reader}) do
    Agent.get(key_reader, &Enum.reverse(&1.calls))
  end

  @spec load_checkpoint(map(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def load_checkpoint(%{key_reader: key_reader}, binding) do
    Agent.get_and_update(key_reader, fn state ->
      checkpoint = Map.get(state.checkpoints, checkpoint_key(binding))
      load = %{binding: binding, checkpoint: checkpoint}
      state = %{state | checkpoint_loads: [load | state.checkpoint_loads]}

      result =
        if checkpoint do
          {:ok, checkpoint}
        else
          {:error, Error.new(:conflict)}
        end

      {result, state}
    end)
  end

  @spec persist_checkpoint(map(), map(), map(), map()) ::
          :ok | {:error, Error.t()}
  def persist_checkpoint(
        %{key_reader: key_reader} = context,
        binding,
        expected,
        next
      ) do
    case Agent.get_and_update(
           key_reader,
           &persist_checkpoint(&1, context, binding, expected, next)
         ) do
      {:blocked, owner, token} ->
        send(owner, {:checkpoint_persisted_blocked, self(), token, binding, expected, next})

        receive do
          {:release_checkpoint_persist, ^token} -> :ok
        end

      result ->
        result
    end
  end

  @spec checkpoint(map(), map()) :: map() | nil
  def checkpoint(%{key_reader: key_reader}, binding) do
    Agent.get(key_reader, &Map.get(&1.checkpoints, checkpoint_key(binding)))
  end

  @spec load_calls(map()) :: [map()]
  def load_calls(%{key_reader: key_reader}) do
    Agent.get(key_reader, &Enum.reverse(&1.checkpoint_loads))
  end

  @spec persist_calls(map()) :: [map()]
  def persist_calls(%{key_reader: key_reader}) do
    Agent.get(key_reader, &Enum.reverse(&1.checkpoint_persists))
  end

  @spec put_checkpoint(map(), map(), map()) :: :ok
  def put_checkpoint(%{key_reader: key_reader}, binding, checkpoint) do
    Agent.update(key_reader, &put_in(&1, [:checkpoints, checkpoint_key(binding)], checkpoint))
  end

  @spec delete_checkpoint(map(), map()) :: :ok
  def delete_checkpoint(%{key_reader: key_reader}, binding) do
    Agent.update(
      key_reader,
      &update_in(&1.checkpoints, fn checkpoints ->
        Map.delete(checkpoints, checkpoint_key(binding))
      end)
    )
  end

  @spec fail_next_persist(map()) :: :ok
  def fail_next_persist(%{key_reader: key_reader}) do
    Agent.update(key_reader, &%{&1 | fail_next_persist?: true})
  end

  @spec block_next_read(map()) :: :ok
  def block_next_read(%{key_reader: key_reader}) do
    Agent.update(key_reader, &%{&1 | block_next_read?: true})
  end

  @spec block_after_next_persist(map()) :: :ok
  def block_after_next_persist(%{key_reader: key_reader}) do
    Agent.update(key_reader, &%{&1 | block_after_next_persist?: true})
  end

  @spec release_read(pid(), reference()) :: :ok
  def release_read(worker, token) when is_pid(worker) and is_reference(token) do
    send(worker, {:release_key_reader, token})
    :ok
  end

  @spec release_persist(pid(), reference()) :: :ok
  def release_persist(persister, token)
      when is_pid(persister) and is_reference(token) do
    send(persister, {:release_checkpoint_persist, token})
    :ok
  end

  defp prepare_read(state, binding, index) do
    result =
      case Map.fetch(state.chunks, index) do
        {:ok, chunk} -> {:ok, chunk}
        :error -> {:error, :not_found}
      end

    state = %{state | calls: [{binding, index} | state.calls]}

    if state.block_next_read? do
      token = make_ref()
      {{:blocked, state.owner, token, result}, %{state | block_next_read?: false}}
    else
      {{:ready, result}, state}
    end
  end

  defp persist_checkpoint(state, context, binding, expected, next) do
    persist = %{
      binding: binding,
      context: context,
      expected: expected,
      next: next
    }

    state = %{state | checkpoint_persists: [persist | state.checkpoint_persists]}
    key = checkpoint_key(binding)

    cond do
      state.fail_next_persist? ->
        {{:error, Error.new(:storage_unavailable, retryable?: true)},
         %{state | fail_next_persist?: false}}

      Map.get(state.checkpoints, key) != expected ->
        {{:error, Error.new(:conflict)}, state}

      true ->
        index = Map.fetch!(expected, "next_chunk_index")
        send_persisted_chunk(state, index)
        state = put_in(state, [:checkpoints, key], next)

        if state.block_after_next_persist? do
          token = make_ref()
          {{:blocked, state.owner, token}, %{state | block_after_next_persist?: false}}
        else
          {:ok, state}
        end
    end
  end

  defp checkpoint_key(binding),
    do: {binding.job_id, binding.vault_id, binding.object_id}

  defp send_persisted_chunk(state, index) do
    case Map.fetch(state.chunks, index) do
      {:ok, chunk} -> send(state.owner, {:plaintext_chunk, index, chunk})
      :error -> :ok
    end
  end
end
