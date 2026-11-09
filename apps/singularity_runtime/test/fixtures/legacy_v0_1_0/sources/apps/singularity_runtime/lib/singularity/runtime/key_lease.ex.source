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
  alias Singularity.Ingest.MetadataExtractor
  alias Singularity.Storage.Crypto.Format

  @lease_seconds 60
  @termination_grace_seconds 5
  @checkpoint_version 2
  @checkpoint_keys ~w[
    version next_chunk_index job_id vault_id principal_id required_capability
    principal_authorization_epoch vault_authorization_epoch object_id
    object_generation
  ]
  @metadata_checkpoint_version 3
  @metadata_protocol "asset_metadata_v1"
  @max_bigint 9_223_372_036_854_775_807
  @metadata_checkpoint_keys ~w[
    version protocol next_chunk_index processing_revision extractor_state
    job_id vault_id principal_id required_capability
    principal_authorization_epoch vault_authorization_epoch object_id
    object_generation
  ]
  @metadata_binding_keys ~w[
    job_id vault_id principal_id required_capability
    principal_authorization_epoch vault_authorization_epoch object_id
    object_generation processing_revision declared_media_type plaintext_byte_size
  ]a

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

  @spec metadata_step(ref()) ::
          {:continue, map()}
          | {:done, map(), map()}
          | {:retry, :checkpoint_advanced}
          | {:error, :waiting_for_unlock | Error.t()}
          | {:error, Error.t(), map()}
  def metadata_step(lease) when is_pid(lease) do
    GenServer.call(lease, :metadata_step, :infinity)
  end

  def metadata_step(_lease), do: {:error, Error.new(:invalid)}

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
      "principal_authorization_epoch" => binding.principal_authorization_epoch,
      "vault_authorization_epoch" => binding.vault_authorization_epoch,
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

  @doc false
  @spec metadata_checkpoint(map(), non_neg_integer(), map()) :: map()
  def metadata_checkpoint(
        %{
          job_id: job_id,
          vault_id: vault_id,
          principal_id: principal_id,
          required_capability: required_capability,
          principal_authorization_epoch: principal_authorization_epoch,
          vault_authorization_epoch: vault_authorization_epoch,
          object_id: object_id,
          object_generation: object_generation,
          processing_revision: processing_revision
        },
        next_chunk_index,
        extractor_state
      )
      when is_integer(next_chunk_index) and next_chunk_index >= 0 and
             is_integer(processing_revision) and processing_revision > 0 and
             is_map(extractor_state) do
    %{
      "version" => @metadata_checkpoint_version,
      "protocol" => @metadata_protocol,
      "next_chunk_index" => next_chunk_index,
      "processing_revision" => processing_revision,
      "extractor_state" => extractor_state,
      "job_id" => job_id,
      "vault_id" => vault_id,
      "principal_id" => principal_id,
      "required_capability" => required_capability,
      "principal_authorization_epoch" => principal_authorization_epoch,
      "vault_authorization_epoch" => vault_authorization_epoch,
      "object_id" => object_id,
      "object_generation" => object_generation
    }
  end

  @doc false
  @spec validate_metadata_checkpoint(map(), map()) ::
          {:ok, non_neg_integer(), map()} | {:error, Error.t()}
  def validate_metadata_checkpoint(
        %{
          "version" => @metadata_checkpoint_version,
          "protocol" => @metadata_protocol,
          "next_chunk_index" => next_chunk_index,
          "processing_revision" => persisted_processing_revision,
          "extractor_state" => extractor_state,
          "job_id" => job_id,
          "vault_id" => vault_id,
          "principal_id" => principal_id,
          "required_capability" => required_capability,
          "principal_authorization_epoch" => principal_authorization_epoch,
          "vault_authorization_epoch" => vault_authorization_epoch,
          "object_id" => object_id,
          "object_generation" => object_generation
        } = persisted,
        %{processing_revision: binding_processing_revision} = binding
      )
      when is_integer(next_chunk_index) and next_chunk_index >= 0 and
             is_integer(persisted_processing_revision) and persisted_processing_revision > 0 and
             is_integer(binding_processing_revision) and binding_processing_revision > 0 and
             is_map(extractor_state) and is_map(binding) do
    with true <- Enum.sort(Map.keys(persisted)) == Enum.sort(@metadata_checkpoint_keys),
         true <- next_chunk_index <= @max_bigint,
         true <- persisted_processing_revision <= @max_bigint,
         true <- valid_checkpoint_text?(job_id),
         true <- valid_checkpoint_text?(vault_id),
         true <- valid_checkpoint_text?(principal_id),
         true <- valid_checkpoint_text?(required_capability),
         true <-
           is_integer(principal_authorization_epoch) and
             principal_authorization_epoch in 0..@max_bigint,
         true <-
           is_integer(vault_authorization_epoch) and
             vault_authorization_epoch in 0..@max_bigint,
         true <- valid_checkpoint_text?(object_id),
         true <- is_integer(object_generation) and object_generation in 1..@max_bigint,
         true <- valid_metadata_binding?(binding),
         :ok <- MetadataExtractor.validate_state(extractor_state),
         :ok <- validate_metadata_position(next_chunk_index, extractor_state),
         :ok <- validate_metadata_target(extractor_state, binding) do
      expected = metadata_checkpoint(binding, next_chunk_index, extractor_state)

      if persisted == expected,
        do: {:ok, next_chunk_index, extractor_state},
        else: {:error, Error.new(:conflict)}
    else
      false -> {:error, Error.new(:integrity_failure)}
      {:error, %Error{}} = error -> error
    end
  end

  def validate_metadata_checkpoint(
        %{"version" => @metadata_checkpoint_version},
        _binding
      ),
      do: {:error, Error.new(:integrity_failure)}

  def validate_metadata_checkpoint(_persisted, _binding),
    do: {:error, Error.new(:integrity_failure)}

  defp validate_metadata_position(0, %{"phase" => "start"}), do: :ok

  defp validate_metadata_position(_next_chunk_index, %{"phase" => "start"}),
    do: {:error, Error.new(:integrity_failure)}

  defp validate_metadata_position(
         next_chunk_index,
         %{
           "phase" => "jpeg_scan",
           "plaintext_bytes" => plaintext_bytes,
           "cursor" => cursor
         }
       ) do
    max_chunks = metadata_chunk_count(plaintext_bytes)

    if is_integer(next_chunk_index) and next_chunk_index >= 1 and
         next_chunk_index < max_chunks and
         cursor >= next_chunk_index * Format.chunk_size(),
       do: :ok,
       else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_metadata_position(next_chunk_index, %{"phase" => phase} = state)
       when phase in ["done", "failed"] do
    plaintext_bytes =
      case state do
        %{"phase" => "done", "result" => %{"plaintext_bytes" => value}} -> value
        %{"phase" => "failed", "plaintext_bytes" => value} -> value
      end

    if is_integer(next_chunk_index) and
         next_chunk_index in 1..metadata_chunk_count(plaintext_bytes),
       do: :ok,
       else: {:error, Error.new(:integrity_failure)}
  end

  defp validate_metadata_position(_next_chunk_index, _extractor_state),
    do: {:error, Error.new(:integrity_failure)}

  defp metadata_chunk_count(plaintext_bytes),
    do: max(1, div(plaintext_bytes + Format.chunk_size() - 1, Format.chunk_size()))

  defp valid_checkpoint_text?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
        String.trim(value) != ""

  defp valid_media_type?(value),
    do:
      is_binary(value) and byte_size(value) in 1..255 and String.valid?(value) and
        String.trim(value) != ""

  defp valid_metadata_binding?(
         %{
           job_id: job_id,
           vault_id: vault_id,
           principal_id: principal_id,
           required_capability: required_capability,
           principal_authorization_epoch: principal_authorization_epoch,
           vault_authorization_epoch: vault_authorization_epoch,
           object_id: object_id,
           object_generation: object_generation,
           processing_revision: processing_revision,
           declared_media_type: declared_media_type,
           plaintext_byte_size: plaintext_byte_size
         } = binding
       ) do
    Enum.sort(Map.keys(binding)) == Enum.sort(@metadata_binding_keys) and
      Enum.all?(
        [job_id, vault_id, principal_id, required_capability, object_id],
        &valid_checkpoint_text?/1
      ) and
      is_integer(principal_authorization_epoch) and
      principal_authorization_epoch in 0..@max_bigint and
      is_integer(vault_authorization_epoch) and
      vault_authorization_epoch in 0..@max_bigint and
      is_integer(object_generation) and object_generation in 1..@max_bigint and
      is_integer(processing_revision) and processing_revision in 1..@max_bigint and
      valid_media_type?(declared_media_type) and
      is_integer(plaintext_byte_size) and plaintext_byte_size in 0..@max_bigint
  end

  defp valid_metadata_binding?(_binding), do: false

  defp validate_metadata_target(extractor_state, binding) do
    case metadata_state_target(extractor_state) do
      {media_type, plaintext_bytes}
      when media_type == binding.declared_media_type and
             plaintext_bytes == binding.plaintext_byte_size ->
        :ok

      {_media_type, _plaintext_bytes} ->
        {:error, Error.new(:conflict)}

      :error ->
        {:error, Error.new(:integrity_failure)}
    end
  end

  defp metadata_state_target(%{
         "phase" => phase,
         "declared_media_type" => media_type,
         "plaintext_bytes" => plaintext_bytes
       })
       when phase in ["start", "jpeg_scan", "failed"],
       do: {media_type, plaintext_bytes}

  defp metadata_state_target(%{
         "phase" => "done",
         "result" => %{
           "detected_media_type" => media_type,
           "plaintext_bytes" => plaintext_bytes
         }
       }),
       do: {media_type, plaintext_bytes}

  defp metadata_state_target(_extractor_state), do: :error

  def child_spec(options) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init(
        %{
          authorization: authorization,
          binding: binding,
          checkpoint: checkpoint,
          clock: clock,
          context: context,
          custodian: custodian,
          key_material: <<_::binary-size(32)>> = key_material,
          key_reader: key_reader
        } = options
      )
      when is_pid(custodian) do
    with checkpoint_binding when is_map(checkpoint_binding) <-
           Map.get(options, :checkpoint_binding, binding),
         {:ok, protocol, next_index, extractor_state} <-
           validate_initial_checkpoint(checkpoint, checkpoint_binding),
         session_id when is_binary(session_id) and session_id != "" <-
           Map.get(options, :session_id, Map.get(binding, :session_id)),
         checkpoint_context when is_map(checkpoint_context) <-
           Map.get(options, :checkpoint_context, Map.delete(context, :key_material)),
         now = clock.utc_now(context),
         {:ok, expires_at, expiry_ms} <-
           lease_expiration(now, Map.get(options, :maximum_expires_at)) do
      custodian_monitor = Process.monitor(custodian)
      Process.send_after(self(), :expire, expiry_ms)

      Process.send_after(
        self(),
        :terminate_expired,
        expiry_ms + @termination_grace_seconds * 1_000
      )

      {:ok,
       %{
         authorization: authorization,
         authorization_context: Map.delete(context, :key_material),
         binding: binding,
         checkpoint: checkpoint,
         checkpoint_binding: checkpoint_binding,
         checkpoint_context: checkpoint_context,
         clock: clock,
         custodian: custodian,
         custodian_monitor: custodian_monitor,
         expires_at: expires_at,
         key_reader: key_reader,
         next_index: next_index,
         protocol: protocol,
         extractor_state: extractor_state,
         pending: nil,
         reader_context: Map.put(context, :key_material, key_material),
         session_id: session_id,
         revoked?: false
       }}
    end
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} ->
        {:state,
         %{
           custody: "[REDACTED]",
           next_index: Map.get(state, :next_index),
           pending?: not is_nil(Map.get(state, :pending)),
           protocol: Map.get(state, :protocol),
           revoked?: Map.get(state, :revoked?, false)
         }}

      {:message, _message} ->
        {:message, "[REDACTED]"}

      key_value ->
        key_value
    end)
  end

  @impl true
  def handle_call({:read_chunk, _index}, _from, %{pending: pending} = state)
      when not is_nil(pending) do
    {:reply, {:error, Error.new(:conflict)}, state}
  end

  def handle_call(:metadata_step, _from, %{pending: pending} = state)
      when not is_nil(pending) do
    {:reply, {:error, Error.new(:conflict)}, state}
  end

  def handle_call(:metadata_step, from, %{protocol: :metadata} = state) do
    with false <- state.revoked?,
         :lt <-
           DateTime.compare(
             state.clock.utc_now(state.authorization_context),
             state.expires_at
           ) do
      {:noreply, start_metadata_step(state, from)}
    else
      true -> reply_waiting_and_revoke(from, state)
      :eq -> reply_waiting_and_revoke(from, state)
      :gt -> reply_waiting_and_revoke(from, state)
    end
  end

  def handle_call(:metadata_step, _from, state),
    do: {:reply, {:error, Error.new(:invalid)}, state}

  def handle_call({:read_chunk, index}, from, state) do
    with false <- state.revoked?,
         :lt <-
           DateTime.compare(
             state.clock.utc_now(state.authorization_context),
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

  def handle_info(
        {:key_lease_metadata_complete, operation_ref, result},
        %{pending: %{operation_ref: operation_ref, kind: :metadata} = pending} = state
      ) do
    Process.demonitor(pending.monitor, [:flush])
    state = %{state | pending: nil}

    case lease_status(state) do
      :active ->
        finish_metadata_step(result, pending, state)

      status when status in [:revoked, :expired] ->
        GenServer.reply(pending.from, {:error, :waiting_for_unlock})
        {:noreply, revoke_state(state)}
    end
  end

  def handle_info({:key_lease_metadata_complete, _operation_ref, _result}, state) do
    {:noreply, state}
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
      authorization_context: state.authorization_context,
      binding: state.binding,
      checkpoint: state.checkpoint,
      checkpoint_binding: state.checkpoint_binding,
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
          kind: :read,
          monitor: monitor,
          operation_ref: operation_ref,
          pid: worker
        }
    }
  end

  defp start_metadata_step(state, from) do
    lease = self()
    operation_ref = make_ref()

    operation = %{
      authorization: state.authorization,
      authorization_context: state.authorization_context,
      binding: state.binding,
      checkpoint: state.checkpoint,
      checkpoint_binding: state.checkpoint_binding,
      checkpoint_context: state.checkpoint_context,
      clock: state.clock,
      expires_at: state.expires_at,
      extractor_state: state.extractor_state,
      index: state.next_index,
      key_reader: state.key_reader,
      reader_context: state.reader_context
    }

    {worker, monitor} =
      spawn_monitor(fn ->
        result = perform_metadata_step(operation)
        send(lease, {:key_lease_metadata_complete, operation_ref, result})
      end)

    %{
      state
      | pending: %{
          from: from,
          index: state.next_index,
          kind: :metadata,
          monitor: monitor,
          operation_ref: operation_ref,
          pid: worker
        }
    }
  end

  defp perform_read(operation) do
    with :ok <-
           operation.authorization.revalidate(
             operation.authorization_context,
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
             operation.authorization_context,
             operation.binding
           ) do
      {:ok, chunk}
    end
  rescue
    _exception -> adapter_unavailable()
  catch
    _kind, _reason -> adapter_unavailable()
  end

  defp perform_metadata_step(operation) do
    with :ok <- active_operation(operation),
         :ok <-
           operation.authorization.revalidate(
             operation.authorization_context,
             operation.binding
           ) do
      case MetadataExtractor.state_result(operation.extractor_state) do
        :continue -> perform_metadata_read(operation)
        {:done, metadata} -> {:ok, {:done, metadata}, operation.checkpoint}
        {:error, %Error{} = error} -> {:ok, {:terminal_error, error}, operation.checkpoint}
      end
    end
  rescue
    _exception -> adapter_unavailable()
  catch
    _kind, _reason -> adapter_unavailable()
  end

  defp perform_metadata_read(
         %{
           extractor_state: %{"phase" => "start", "plaintext_bytes" => 0}
         } = operation
       ) do
    operation.extractor_state
    |> MetadataExtractor.step("", 0)
    |> then(&persist_metadata_step(operation, &1))
  end

  defp perform_metadata_read(operation) do
    with {:ok, chunk} <-
           operation.key_reader.read_chunk(
             operation.reader_context,
             operation.binding,
             operation.index
           ) do
      result =
        MetadataExtractor.step(
          operation.extractor_state,
          chunk,
          operation.index * Format.chunk_size()
        )

      persist_metadata_step(operation, result)
    end
  end

  defp persist_metadata_step(operation, result) do
    with {:ok, outcome, extractor_state} <- normalize_metadata_result(result),
         :ok <- active_operation(operation),
         :ok <-
           operation.authorization.revalidate(
             operation.authorization_context,
             operation.binding
           ),
         :ok <- active_operation(operation),
         next_checkpoint =
           metadata_checkpoint(
             operation.checkpoint_binding,
             operation.index + 1,
             extractor_state
           ),
         :ok <-
           operation.key_reader.persist_checkpoint(
             operation.checkpoint_context,
             operation.checkpoint_binding,
             operation.checkpoint,
             next_checkpoint
           ) do
      {:ok, outcome, next_checkpoint}
    end
  end

  defp normalize_metadata_result({:continue, extractor_state}),
    do: {:ok, :continue, extractor_state}

  defp normalize_metadata_result({:done, metadata, extractor_state}),
    do: {:ok, {:done, metadata}, extractor_state}

  defp normalize_metadata_result({:error, %Error{} = error, extractor_state})
       when error.code in [:unsupported_media_type, :integrity_failure],
       do: {:ok, {:terminal_error, error}, extractor_state}

  defp normalize_metadata_result(_invalid),
    do: {:error, Error.new(:integrity_failure)}

  defp active_operation(operation) do
    if DateTime.compare(
         operation.clock.utc_now(operation.authorization_context),
         operation.expires_at
       ) == :lt,
       do: :ok,
       else: {:error, :waiting_for_unlock}
  end

  defp lease_expiration(%DateTime{} = now, nil) do
    expires_at = DateTime.add(now, @lease_seconds, :second)
    {:ok, expires_at, @lease_seconds * 1_000}
  end

  defp lease_expiration(%DateTime{} = now, %DateTime{} = maximum_expires_at) do
    lease_deadline = DateTime.add(now, @lease_seconds, :second)

    expires_at =
      if DateTime.compare(maximum_expires_at, lease_deadline) == :lt,
        do: maximum_expires_at,
        else: lease_deadline

    {:ok, expires_at, max(0, DateTime.diff(expires_at, now, :millisecond))}
  end

  defp lease_expiration(_now, _maximum_expires_at),
    do: {:error, Error.new(:invalid)}

  defp finish_read({:ok, chunk}, pending, state) do
    case persist_completed_read(state, pending.index) do
      {:ok, next_checkpoint} ->
        send(state.custodian, {:authorized_activity, state.session_id})
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
    GenServer.reply(pending.from, {:error, public_error(error)})
    {:noreply, revoke_state(state)}
  end

  defp finish_read({:error, _reason}, pending, state) do
    GenServer.reply(
      pending.from,
      {:error, Error.new(:storage_unavailable, retryable?: true)}
    )

    {:noreply, revoke_state(state)}
  end

  defp finish_read(_unexpected, pending, state) do
    GenServer.reply(pending.from, {:error, Error.new(:job_failed)})
    {:noreply, revoke_state(state)}
  end

  defp finish_metadata_step({:ok, outcome, next_checkpoint}, pending, state) do
    send(state.custodian, {:authorized_activity, state.session_id})
    reply = metadata_reply(outcome, next_checkpoint)
    GenServer.reply(pending.from, reply)

    {:noreply,
     %{
       state
       | checkpoint: next_checkpoint,
         extractor_state: next_checkpoint["extractor_state"],
         next_index: next_checkpoint["next_chunk_index"]
     }}
  end

  defp finish_metadata_step({:error, :waiting_for_unlock}, pending, state) do
    GenServer.reply(pending.from, {:error, :waiting_for_unlock})
    {:noreply, revoke_state(state)}
  end

  defp finish_metadata_step({:error, :checkpoint_advanced}, pending, state) do
    GenServer.reply(pending.from, {:retry, :checkpoint_advanced})
    {:noreply, revoke_state(state)}
  end

  defp finish_metadata_step({:error, %Error{} = error}, pending, state) do
    GenServer.reply(pending.from, {:error, public_error(error)})
    {:noreply, revoke_state(state)}
  end

  defp finish_metadata_step(_unexpected, pending, state) do
    GenServer.reply(pending.from, {:error, Error.new(:job_failed)})
    {:noreply, revoke_state(state)}
  end

  defp metadata_reply(:continue, checkpoint), do: {:continue, checkpoint}
  defp metadata_reply({:done, metadata}, checkpoint), do: {:done, metadata, checkpoint}

  defp metadata_reply({:terminal_error, %Error{} = error}, checkpoint),
    do: {:error, public_error(error), checkpoint}

  defp persist_completed_read(state, index) do
    with :active <- lease_status(state),
         :ok <-
           state.authorization.revalidate(
             state.authorization_context,
             state.binding
           ),
         :active <- lease_status(state),
         next_checkpoint = checkpoint(state.checkpoint_binding, index + 1),
         :ok <-
           state.key_reader.persist_checkpoint(
             state.checkpoint_context,
             state.checkpoint_binding,
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
        {:error, public_error(elem(error, 1))}

      _unexpected ->
        {:error, Error.new(:job_failed)}
    end
  rescue
    _exception -> adapter_unavailable()
  catch
    _kind, _reason -> adapter_unavailable()
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
           state.clock.utc_now(state.authorization_context),
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

  defp public_error(%Error{code: code, retryable?: retryable?}),
    do: Error.new(code, retryable?: retryable?)

  defp adapter_unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp validate_initial_checkpoint(%{"version" => @checkpoint_version} = checkpoint, binding) do
    with {:ok, next_index} <- validate_checkpoint(checkpoint, binding) do
      {:ok, :read, next_index, nil}
    end
  end

  defp validate_initial_checkpoint(
         %{"version" => @metadata_checkpoint_version} = checkpoint,
         binding
       ) do
    with {:ok, next_index, extractor_state} <-
           validate_metadata_checkpoint(checkpoint, binding) do
      {:ok, :metadata, next_index, extractor_state}
    end
  end

  defp validate_initial_checkpoint(_checkpoint, _binding),
    do: {:error, Error.new(:integrity_failure)}
end
