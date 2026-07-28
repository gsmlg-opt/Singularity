defmodule Singularity.Runtime.Assets.UploadSession.MessageStream do
  @moduledoc false

  @enforce_keys [:owner]
  defstruct [:owner]
end

defimpl Enumerable,
  for: Singularity.Runtime.Assets.UploadSession.MessageStream do
  alias Singularity.Runtime.Assets.UploadSession.MessageStream

  def reduce(%MessageStream{owner: owner}, accumulator, reducer) do
    reduce_messages(owner, accumulator, reducer)
  end

  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _value), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}

  defp reduce_messages(_owner, {:halt, accumulator}, _reducer),
    do: {:halted, accumulator}

  defp reduce_messages(owner, {:suspend, accumulator}, reducer) do
    {:suspended, accumulator, &reduce_messages(owner, &1, reducer)}
  end

  defp reduce_messages(owner, {:cont, accumulator}, reducer) do
    receive do
      {:"$upload_stream_chunk", ^owner, reference, chunk} ->
        reduce_chunk(owner, reference, chunk, accumulator, reducer)

      {:"$upload_stream_finish", ^owner} ->
        {:done, accumulator}
    end
  end

  defp reduce_chunk(owner, reference, chunk, accumulator, reducer) do
    case reducer.(chunk, accumulator) do
      {:cont, next} ->
        send(owner, {:upload_chunk_applied, self(), reference})
        reduce_messages(owner, {:cont, next}, reducer)

      {:halt, next} ->
        send(owner, {:upload_chunk_halted, self(), reference})
        {:halted, next}

      {:suspend, next} ->
        send(owner, {:upload_chunk_applied, self(), reference})
        {:suspended, next, &reduce_messages(owner, &1, reducer)}
    end
  end
end

defmodule Singularity.Runtime.Assets.UploadSession do
  @moduledoc """
  Owns one short-lived, lock-pinned encrypted upload.

  The public process identifier is an opaque handle. The request controller
  supplies binary chunks only after `await_ready/2` confirms that the grant
  was consumed and the durable stage row committed.
  """

  alias Singularity.Core.Error
  alias Singularity.Core.StageRef
  alias Singularity.Ingest.UploadRequest
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.Assets.UploadSession.MessageStream
  alias Singularity.Runtime.Observability.Telemetry
  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.EncryptedStageWriter
  alias Singularity.Storage.Postgres.AssetRepository
  alias Singularity.Storage.RequestRepo
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock

  @default_call_timeout 30_000
  @stage_fields [
    :stage_id,
    :candidate_object_id,
    :key_domain_id,
    :domain_key_version_id,
    :storage_ref,
    :wrapper_algorithm,
    :key_generation,
    :dek_wrapper
  ]
  @grant_fields [
    :session_id,
    :principal_id,
    :vault_id,
    :asset_id,
    :filename,
    :byte_size,
    :declared_media_type,
    :idempotency_key,
    :classification,
    :principal_authorization_epoch,
    :vault_authorization_epoch
  ]
  @request_binding_fields [
    :token_digest,
    :csrf_token_digest,
    :request_content_length,
    :request_declared_media_type
  ]

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      shutdown: 15_000
    }
  end

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(options) when is_list(options) do
    :proc_lib.start_link(__MODULE__, :init, [options])
  end

  def start_link(_options), do: {:error, Error.new(:invalid)}

  @doc false
  def init(options) do
    :proc_lib.init_ack({:ok, self()})
    run(options)
  end

  @spec await_ready(pid(), timeout()) :: {:ok, pid()} | {:error, Error.t()}
  def await_ready(session, timeout \\ @default_call_timeout),
    do: call(session, :await_ready, timeout)

  @spec append(pid(), binary(), timeout()) :: :ok | {:error, Error.t()}
  def append(session, chunk, timeout \\ @default_call_timeout)

  def append(session, chunk, timeout) when is_binary(chunk),
    do: call(session, {:append, chunk}, timeout)

  def append(_session, _chunk, _timeout), do: {:error, Error.new(:invalid)}

  @spec finish(pid(), timeout()) :: {:ok, map()} | {:error, Error.t()}
  def finish(session, timeout \\ :infinity),
    do: call(session, :finish, timeout)

  @spec abandon(pid()) :: :ok | {:error, Error.t()}
  def abandon(session), do: abandon(session, :controller_aborted)

  @spec abandon(pid(), term()) :: :ok | {:error, Error.t()}
  def abandon(session, reason),
    do: abandon(session, reason, @default_call_timeout)

  @spec abandon(pid(), term(), timeout()) :: :ok | {:error, Error.t()}
  def abandon(session, reason, timeout),
    do: call(session, {:abandon, reason}, timeout)

  defp run(options) do
    case initial_state(options) do
      {:ok, state} ->
        state = monitor_lifecycle(state)

        try do
          case with_pinned_locks(state) do
            {:setup_error, %Error{} = error, failed_state} ->
              failed_loop(failed_state, error)

            {:done, _state} ->
              :ok

            {:error, %Error{} = error, failed_state} ->
              failed_loop(failed_state, error)
          end
        rescue
          _exception ->
            failed_loop(
              state,
              Error.new(:storage_unavailable, retryable?: true)
            )
        catch
          _kind, _reason ->
            failed_loop(
              state,
              Error.new(:storage_unavailable, retryable?: true)
            )
        after
          release_lifecycle(state)
        end

      {:error, %Error{} = error, owner} ->
        failed_loop(%{owner: owner}, error)
    end

    exit(:normal)
  end

  defp with_pinned_locks(state) do
    call_adapter(state.adapters.request_repo, :checkout, [
      fn ->
        repo = adapter_module(state.adapters.request_repo)

        call_adapter(
          state.adapters.vault_lock,
          :with_shared_checked_out,
          [
            repo,
            state.session.vault_id,
            fn vault_repo ->
              call_adapter(state.adapters.authorization_lock, :with_shared, [
                vault_repo,
                state.session.principal_id,
                state.session.vault_id,
                fn locked_repo -> locked_session(state, locked_repo) end
              ])
            end
          ]
        )
      end
    ])
  end

  defp locked_session(state, repo) do
    case consume_grant(state, repo) do
      {:ok, stage} ->
        state = %{state | repo: repo, stage: stage}

        if expired?(state) do
          _result = abandon_stage(state, :upload_expired)
          {:setup_error, Error.new(:upload_expired), state}
        else
          case start_writer(state) do
            {:ok, ready_state} ->
              try do
                ready_loop(ready_state)
              after
                stop_writer(ready_state)
              end

            {:error, %Error{} = error} ->
              _result = abandon_stage(state, error)
              {:setup_error, error, state}

            {:error, %Error{} = error, failed_state} ->
              result = abandon_stage(failed_state, error)

              if normalize_abandonment_result(result) == :ok,
                do:
                  notify_custody_terminal(
                    failed_state,
                    :abandoned
                  )

              {:setup_error, error, failed_state}
          end
        end

      {:error, %Error{} = error} ->
        {:setup_error, error, state}
    end
  end

  defp consume_grant(state, repo) do
    transact_authorized(state, repo, fn scoped_repo ->
      call_adapter(state.adapters.assets, :consume_grant_and_create_stage, [
        scoped_repo,
        state.consume_command
      ])
      |> normalize_repository_result()
    end)
  end

  defp ready_loop(state) do
    if expired?(state) do
      terminate_abandoned(state, :upload_expired, nil)
    else
      receive do
        {:"$upload_call", caller, reference, :await_ready} ->
          reply(caller, reference, {:ok, self()})
          ready_loop(state)

        {:"$upload_call", caller, reference, {:append, chunk}}
        when is_binary(chunk) ->
          append_chunk(state, caller, reference, chunk)

        {:"$upload_call", caller, reference, :finish}
        when not state.media_validated? ->
          error = Error.new(:unsupported_media_type)
          reply(caller, reference, {:error, error})
          terminate_abandoned(state, error, nil)

        {:"$upload_call", caller, reference, :finish} ->
          send(state.writer, {:"$upload_stream_finish", self()})
          await_finish(state, caller, reference)

        {:"$upload_call", caller, reference, {:abandon, reason}} ->
          terminate_abandoned(state, reason, {caller, reference})

        {:custody_revoke, custody_ref, revocation_ref, custodian}
        when is_reference(custody_ref) and is_reference(revocation_ref) ->
          if matching_custody?(state, custodian, custody_ref) do
            terminate_custody_revoked(
              state,
              custodian,
              custody_ref,
              revocation_ref,
              nil
            )
          else
            ready_loop(state)
          end

        {:DOWN, owner_monitor, :process, owner, _reason}
        when owner_monitor == state.owner_monitor and owner == state.owner ->
          terminate_abandoned(state, :controller_disconnected, nil)

        :upload_expired ->
          terminate_abandoned(state, :upload_expired, nil)

        {:writer_result, writer, {:error, %Error{} = error, _stage_ref}}
        when writer == state.writer ->
          terminate_abandoned(state, error, nil)

        {:DOWN, writer_monitor, :process, writer, _reason}
        when writer_monitor == state.writer_monitor and writer == state.writer ->
          terminate_abandoned(
            state,
            Error.new(:storage_unavailable, retryable?: true),
            nil
          )

        {:"$upload_call", caller, reference, _invalid} ->
          reply(caller, reference, {:error, Error.new(:conflict)})
          ready_loop(state)

        _other ->
          ready_loop(state)
      end
    end
  end

  defp append_chunk(
         %{media_validated?: true} = state,
         caller,
         reference,
         chunk
       ) do
    send(
      state.writer,
      {:"$upload_stream_chunk", self(), reference, chunk}
    )

    await_chunk(state, caller, reference)
  end

  defp append_chunk(state, caller, reference, "") do
    reply(caller, reference, :ok)
    ready_loop(state)
  end

  defp append_chunk(state, caller, reference, chunk) do
    missing = state.signature_bytes - byte_size(state.magic_prefix)
    take = min(missing, byte_size(chunk))

    prefix =
      state.magic_prefix <>
        binary_part(chunk, 0, take)

    pending_chunks = state.pending_magic_chunks ++ [chunk]

    if byte_size(prefix) < state.signature_bytes do
      reply(caller, reference, :ok)

      ready_loop(%{
        state
        | magic_prefix: prefix,
          pending_magic_chunks: pending_chunks
      })
    else
      case validate_magic(prefix, state.declared_media_type) do
        :ok ->
          ready_state = %{
            state
            | magic_prefix: "",
              pending_magic_chunks: [],
              media_validated?: true
          }

          case flush_magic_chunks(ready_state, pending_chunks) do
            :ok ->
              reply(caller, reference, :ok)
              ready_loop(ready_state)

            {:error, %Error{} = error} ->
              reply(caller, reference, {:error, error})
              terminate_abandoned(ready_state, error, nil)

            {:custody_revoke, custodian, custody_ref, revocation_ref} ->
              terminate_custody_revoked(
                ready_state,
                custodian,
                custody_ref,
                revocation_ref,
                {caller, reference}
              )
          end

        {:error, %Error{} = error} ->
          reply(caller, reference, {:error, error})
          terminate_abandoned(state, error, nil)
      end
    end
  end

  defp flush_magic_chunks(state, chunks) do
    Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
      reference = make_ref()

      send(
        state.writer,
        {:"$upload_stream_chunk", self(), reference, chunk}
      )

      case await_buffered_chunk(state, reference) do
        :ok ->
          {:cont, :ok}

        {:error, %Error{}} = error ->
          {:halt, error}

        {:custody_revoke, _custodian, _custody_ref, _revocation_ref} = revoke ->
          {:halt, revoke}
      end
    end)
  end

  defp await_buffered_chunk(state, reference) do
    receive do
      {:upload_chunk_applied, writer, ^reference}
      when writer == state.writer ->
        :ok

      {:upload_chunk_halted, writer, ^reference}
      when writer == state.writer ->
        await_buffered_writer_failure(state)

      {:writer_result, writer, {:error, %Error{} = error, _stage_ref}}
      when writer == state.writer ->
        {:error, error}

      {:"$upload_call", caller, ready_reference, :await_ready} ->
        reply(caller, ready_reference, {:ok, self()})
        await_buffered_chunk(state, reference)

      {:"$upload_call", caller, other_reference, _request} ->
        reply(caller, other_reference, {:error, Error.new(:conflict)})
        await_buffered_chunk(state, reference)

      {:custody_revoke, custody_ref, revocation_ref, custodian}
      when is_reference(custody_ref) and is_reference(revocation_ref) ->
        if matching_custody?(state, custodian, custody_ref) do
          {:custody_revoke, custodian, custody_ref, revocation_ref}
        else
          await_buffered_chunk(state, reference)
        end

      {:DOWN, writer_monitor, :process, writer, _reason}
      when writer_monitor == state.writer_monitor and writer == state.writer ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}

      _other ->
        await_buffered_chunk(state, reference)
    after
      @default_call_timeout ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp await_buffered_writer_failure(state) do
    receive do
      {:writer_result, writer, {:error, %Error{} = error, _stage_ref}}
      when writer == state.writer ->
        {:error, error}

      {:custody_revoke, custody_ref, revocation_ref, custodian}
      when is_reference(custody_ref) and is_reference(revocation_ref) ->
        if matching_custody?(state, custodian, custody_ref) do
          {:custody_revoke, custodian, custody_ref, revocation_ref}
        else
          await_buffered_writer_failure(state)
        end

      {:DOWN, writer_monitor, :process, writer, _reason}
      when writer_monitor == state.writer_monitor and writer == state.writer ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    after
      @default_call_timeout ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp await_chunk(state, caller, reference) do
    receive do
      {:upload_chunk_applied, writer, ^reference}
      when writer == state.writer ->
        reply(caller, reference, :ok)
        ready_loop(state)

      {:upload_chunk_halted, writer, ^reference}
      when writer == state.writer ->
        await_failed_writer(state, caller, reference)

      {:writer_result, writer, {:error, %Error{} = error, _stage_ref}}
      when writer == state.writer ->
        reply(caller, reference, {:error, error})
        terminate_abandoned(state, error, nil)

      {:DOWN, owner_monitor, :process, owner, _reason}
      when owner_monitor == state.owner_monitor and owner == state.owner ->
        reply(caller, reference, {:error, Error.new(:conflict)})
        terminate_abandoned(state, :controller_disconnected, nil)

      :upload_expired ->
        error = Error.new(:upload_expired)
        reply(caller, reference, {:error, error})
        terminate_abandoned(state, :upload_expired, nil)

      {:"$upload_call", abandon_caller, abandon_reference, {:abandon, reason}} ->
        reply(caller, reference, {:error, Error.new(:conflict)})

        terminate_abandoned(
          state,
          reason,
          {abandon_caller, abandon_reference}
        )

      {:custody_revoke, custody_ref, revocation_ref, custodian}
      when is_reference(custody_ref) and is_reference(revocation_ref) ->
        if matching_custody?(state, custodian, custody_ref) do
          terminate_custody_revoked(
            state,
            custodian,
            custody_ref,
            revocation_ref,
            {caller, reference}
          )
        else
          await_chunk(state, caller, reference)
        end

      {:"$upload_call", ready_caller, ready_reference, :await_ready} ->
        reply(ready_caller, ready_reference, {:ok, self()})
        await_chunk(state, caller, reference)

      {:"$upload_call", other_caller, other_reference, _request} ->
        reply(other_caller, other_reference, {:error, Error.new(:conflict)})
        await_chunk(state, caller, reference)

      {:DOWN, writer_monitor, :process, writer, _reason}
      when writer_monitor == state.writer_monitor and writer == state.writer ->
        error = Error.new(:storage_unavailable, retryable?: true)
        reply(caller, reference, {:error, error})
        terminate_abandoned(state, error, nil)

      _other ->
        await_chunk(state, caller, reference)
    end
  end

  defp await_failed_writer(state, caller, reference) do
    receive do
      {:writer_result, writer, {:error, %Error{} = error, _stage_ref}}
      when writer == state.writer ->
        reply(caller, reference, {:error, error})
        terminate_abandoned(state, error, nil)

      {:custody_revoke, custody_ref, revocation_ref, custodian}
      when is_reference(custody_ref) and is_reference(revocation_ref) ->
        if matching_custody?(state, custodian, custody_ref) do
          terminate_custody_revoked(
            state,
            custodian,
            custody_ref,
            revocation_ref,
            {caller, reference}
          )
        else
          await_failed_writer(state, caller, reference)
        end

      {:DOWN, writer_monitor, :process, writer, _reason}
      when writer_monitor == state.writer_monitor and writer == state.writer ->
        error = Error.new(:storage_unavailable, retryable?: true)
        reply(caller, reference, {:error, error})
        terminate_abandoned(state, error, nil)
    after
      @default_call_timeout ->
        error = Error.new(:storage_unavailable, retryable?: true)
        reply(caller, reference, {:error, error})
        terminate_abandoned(state, error, nil)
    end
  end

  defp await_finish(state, caller, reference) do
    receive do
      {:writer_result, writer, {:ok, sealed}}
      when writer == state.writer ->
        case acknowledge_sealed(state, sealed) do
          {:ok, uploaded} ->
            notify_custody_terminal(state, :sealed)
            reply(caller, reference, {:ok, uploaded})
            {:done, state}

          {:error, %Error{} = error} ->
            reply(caller, reference, {:error, error})
            {:done, state}
        end

      {:writer_result, writer, {:error, %Error{} = error, _stage_ref}}
      when writer == state.writer ->
        reply(caller, reference, {:error, error})
        terminate_abandoned(state, error, nil)

      {:DOWN, owner_monitor, :process, owner, _reason}
      when owner_monitor == state.owner_monitor and owner == state.owner ->
        reply(caller, reference, {:error, Error.new(:conflict)})
        terminate_abandoned(state, :controller_disconnected, nil)

      :upload_expired ->
        error = Error.new(:upload_expired)
        reply(caller, reference, {:error, error})
        terminate_abandoned(state, :upload_expired, nil)

      {:"$upload_call", abandon_caller, abandon_reference, {:abandon, reason}} ->
        reply(caller, reference, {:error, Error.new(:conflict)})

        terminate_abandoned(
          state,
          reason,
          {abandon_caller, abandon_reference}
        )

      {:custody_revoke, custody_ref, revocation_ref, custodian}
      when is_reference(custody_ref) and is_reference(revocation_ref) ->
        if matching_custody?(state, custodian, custody_ref) do
          terminate_custody_revoked(
            state,
            custodian,
            custody_ref,
            revocation_ref,
            {caller, reference}
          )
        else
          await_finish(state, caller, reference)
        end

      {:"$upload_call", ready_caller, ready_reference, :await_ready} ->
        reply(ready_caller, ready_reference, {:ok, self()})
        await_finish(state, caller, reference)

      {:"$upload_call", other_caller, other_reference, _request} ->
        reply(other_caller, other_reference, {:error, Error.new(:conflict)})
        await_finish(state, caller, reference)

      {:DOWN, writer_monitor, :process, writer, _reason}
      when writer_monitor == state.writer_monitor and writer == state.writer ->
        error = Error.new(:storage_unavailable, retryable?: true)
        reply(caller, reference, {:error, error})
        terminate_abandoned(state, error, nil)

      _other ->
        await_finish(state, caller, reference)
    end
  end

  defp acknowledge_sealed(state, sealed) do
    with {:ok, checkpoint} <- checkpoint(state, sealed) do
      result =
        transact_authorized(state, state.repo, fn scoped_repo ->
          call_adapter(state.adapters.assets, :record_sealed_stage, [
            scoped_repo,
            checkpoint
          ])
          |> normalize_repository_result()
        end)

      case result do
        {:ok, _uploaded} ->
          Telemetry.execute(
            [:upload, :stop],
            %{
              bytes: checkpoint.plaintext_byte_size,
              duration: System.monotonic_time() - state.telemetry_started_at
            },
            %{result: :ok}
          )

          result

        _failure ->
          result
      end
    end
  end

  defp terminate_abandoned(state, reason, reply_to) do
    stop_writer(state)

    result =
      with :ok <- abort_physical_stage(state) do
        abandon_stage(state, reason)
      end

    if normalize_abandonment_result(result) == :ok,
      do: notify_custody_terminal(state, :abandoned)

    if reply_to do
      {caller, reference} = reply_to
      reply(caller, reference, normalize_abandonment_result(result))
    end

    {:done, state}
  end

  defp terminate_custody_revoked(
         state,
         custodian,
         custody_ref,
         revocation_ref,
         reply_to
       ) do
    stop_writer(state)

    result =
      with :ok <- abort_physical_stage(state) do
        abandon_stage(state, :custody_revoked)
      end

    if reply_to do
      {caller, reference} = reply_to
      reply(caller, reference, {:error, Error.new(:vault_locked)})
    end

    send(
      adapter_pid(custodian),
      {:custody_revoke_result, self(), custody_ref, revocation_ref, result}
    )

    {:done, state}
  end

  defp abort_physical_stage(%{stage: nil}), do: :ok

  defp abort_physical_stage(%{
         stage: stage,
         storage: %{adapter: adapter, context: context}
       })
       when is_atom(adapter) and not is_nil(adapter) do
    with {:ok, %StageRef{} = stage_ref} <- stage_ref(stage) do
      case call_adapter({adapter, context}, :abort_stage, [stage_ref]) do
        :ok -> :ok
        {:error, %Error{}} = error -> error
        _invalid -> {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    end
  rescue
    _exception -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp abort_physical_stage(_state),
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp abandon_stage(%{stage: nil}, _reason), do: :ok

  defp abandon_stage(state, reason) do
    command = %{
      stage_id: field(state.stage, :id),
      grant_id: state.consume_command.grant_id,
      asset_id: state.consume_command.asset_id,
      session_id: state.consume_command.session_id,
      principal_id: state.consume_command.principal_id,
      vault_id: state.consume_command.vault_id,
      classification: state.consume_command.classification,
      storage_ref: field(state.stage, :storage_ref),
      expected_stage_revision: field(state.stage, :state_revision, 0),
      failure_code: failure_code(reason),
      abandoned_at: state.adapters.clock.()
    }

    call_adapter(state.adapters.scoped_repo, :transact, [
      state.repo,
      transaction_context(state),
      fn scoped_repo ->
        call_adapter(state.adapters.assets, :mark_stage_abandoned, [
          scoped_repo,
          command
        ])
        |> normalize_repository_result()
      end
    ])
    |> normalize_repository_result()
  rescue
    _exception -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp transact_authorized(state, repo, callback) do
    call_adapter(state.adapters.scoped_repo, :transact, [
      repo,
      transaction_context(state),
      fn scoped_repo ->
        with :ok <-
               call_adapter(state.adapters.authorizer, :check, [
                 state.adapters.authorization,
                 scoped_repo,
                 state.session,
                 state.requirement
               ]) do
          callback.(scoped_repo)
        end
      end
    ])
    |> normalize_repository_result()
  end

  defp start_writer(state) do
    with {:ok, stage_ref} <- stage_ref(state.stage),
         {:ok, secret_material, custody} <-
           claim_upload_material(state) do
      upload =
        state.upload
        |> Map.merge(secret_material)
        |> Map.put(:stage_ref, stage_ref)
        |> Map.put(:vault_id, state.consume_command.vault_id)
        |> Map.put(
          :encryption_domain_id,
          state.consume_command.key_domain_id
        )
        |> Map.put(
          :object_id,
          state.consume_command.candidate_object_id
        )
        |> Map.put(:expected_bytes, state.consume_command.byte_size)
        |> Map.put(:max_bytes, max_upload_bytes())

      owner = self()
      writer_adapter = state.adapters.stage_writer
      storage = state.storage
      stream = %MessageStream{owner: owner}

      {writer, monitor} =
        spawn_monitor(fn ->
          await_writer_start(owner, stage_ref)
        end)

      _guard = spawn(fn -> terminate_writer_with_owner(owner, writer) end)

      claimed_state = %{
        state
        | writer: writer,
          writer_monitor: monitor,
          custody: custody
      }

      case attach_custody_worker(custody, writer) do
        :ok ->
          send(
            writer,
            {:start_upload_writer, owner, writer_adapter, storage, upload, stream}
          )

          {:ok, claimed_state}

        {:error, %Error{} = error} ->
          Process.exit(writer, :kill)
          Process.demonitor(monitor, [:flush])
          {:error, error, claimed_state}
      end
    end
  end

  defp await_writer_start(owner, stage_ref) do
    receive do
      {:start_upload_writer, ^owner, writer_adapter, storage, upload, stream} ->
        result =
          try do
            call_adapter(
              writer_adapter,
              :stream_and_seal_stage,
              [storage, upload, stream]
            )
            |> normalize_writer_result()
          rescue
            _exception ->
              {:error, Error.new(:storage_unavailable, retryable?: true), stage_ref}
          catch
            _kind, _reason ->
              {:error, Error.new(:storage_unavailable, retryable?: true), stage_ref}
          end

        send(owner, {:writer_result, self(), result})
    end
  end

  defp attach_custody_worker(:direct, _writer), do: :ok

  defp attach_custody_worker(
         {:custodian, custodian, custody_ref},
         writer
       ) do
    case call_adapter(custodian, :attach_upload_worker, [
           custody_ref,
           writer
         ]) do
      :ok -> :ok
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  rescue
    _exception -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp claim_upload_material(%{
         upload: %{
           object_dek: <<_::binary-size(32)>> = object_dek,
           domain_dedup_key: <<_::binary-size(32)>> = domain_dedup_key
         }
       }) do
    {:ok,
     %{
       object_dek: object_dek,
       domain_dedup_key: domain_dedup_key
     }, :direct}
  end

  defp claim_upload_material(%{
         adapters: %{custodian: custodian},
         consume_command: command,
         upload: %{material_ref: material_ref}
       })
       when not is_nil(custodian) and is_reference(material_ref) do
    binding =
      command
      |> Map.take([
        :grant_id,
        :asset_id,
        :session_id,
        :principal_id,
        :vault_id,
        :principal_authorization_epoch,
        :vault_authorization_epoch,
        :classification
      ])
      |> Map.put(:stage_id, command.stage_id)
      |> Map.put(:storage_ref, command.storage_ref)

    case call_adapter(custodian, :claim_upload, [
           material_ref,
           binding
         ])
         |> normalize_repository_result() do
      {:ok,
       %{
         object_dek: <<_::binary-size(32)>>,
         domain_dedup_key: <<_::binary-size(32)>>,
         custody_ref: custody_ref
       } = claimed}
      when is_reference(custody_ref) ->
        {:ok, Map.delete(claimed, :custody_ref), {:custodian, custodian, custody_ref}}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp claim_upload_material(_state),
    do: {:error, Error.new(:vault_locked)}

  defp checkpoint(state, sealed) when is_map(sealed) do
    expected_stage_ref = %StageRef{stage_id: field(state.stage, :id)}

    with %StageRef{} = stage_ref <- Map.get(sealed, :stage_ref),
         true <- stage_ref == expected_stage_ref,
         plaintext_size when is_integer(plaintext_size) and plaintext_size >= 0 <-
           Map.get(sealed, :plaintext_byte_size),
         true <- plaintext_size == state.consume_command.byte_size,
         ciphertext_size when is_integer(ciphertext_size) and ciphertext_size >= 0 <-
           Map.get(sealed, :ciphertext_byte_size),
         <<_::binary-size(32)>> = lookup_digest <-
           Map.get(sealed, :lookup_digest),
         <<_::binary-size(32)>> = ciphertext_hash <-
           Map.get(sealed, :ciphertext_hash),
         format_version when is_integer(format_version) and format_version > 0 <-
           Map.get(sealed, :format_version),
         %DateTime{} = sealed_at <- state.adapters.clock.() do
      {:ok,
       %{
         stage_ref: stage_ref,
         storage_ref: field(state.stage, :storage_ref),
         grant_id: state.consume_command.grant_id,
         session_id: state.consume_command.session_id,
         principal_id: state.consume_command.principal_id,
         vault_id: state.consume_command.vault_id,
         asset_id: state.consume_command.asset_id,
         classification: state.consume_command.classification,
         expected_stage_revision: field(state.stage, :state_revision, 0),
         expected_asset_revision: 0,
         format_version: format_version,
         plaintext_byte_size: plaintext_size,
         ciphertext_byte_size: ciphertext_size,
         lookup_digest: lookup_digest,
         ciphertext_hash: ciphertext_hash,
         sealed_at: sealed_at
       }}
    else
      _invalid -> {:error, Error.new(:integrity_failure)}
    end
  end

  defp checkpoint(_state, _sealed),
    do: {:error, Error.new(:integrity_failure)}

  @doc false
  @spec initial_state(keyword()) ::
          {:ok, map()} | {:error, Error.t(), pid() | nil}
  def initial_state(options) do
    owner = Keyword.get(options, :owner)

    with runtime when is_map(runtime) <- Keyword.get(options, :runtime),
         session when is_map(session) <- Keyword.get(options, :session),
         grant when is_map(grant) <- Keyword.get(options, :grant),
         true <- is_pid(owner),
         upload when is_map(upload) <-
           Keyword.get(options, :upload, Map.get(grant, :upload)),
         storage when is_map(storage) <-
           Keyword.get(
             options,
             :storage,
             Map.get(runtime, :asset_storage, Map.get(runtime, :storage))
           ),
         {:ok, adapters} <- adapters(runtime),
         %DateTime{} = now <- adapters.clock.(),
         %DateTime{} = expires_at <- Map.get(grant, :expires_at),
         :gt <- DateTime.compare(expires_at, now),
         :ok <- validate_binding(session, grant),
         :ok <- raw_credentials_absent(grant),
         {:ok, signature_bytes} <-
           signature_bytes(Map.get(grant, :declared_media_type)),
         {:ok, consume_command} <- consume_command(grant, upload),
         {:ok, expiry_ms} <- expiry_ms(now, expires_at) do
      {:ok,
       %{
         adapters: adapters,
         consume_command: consume_command,
         expires_at: expires_at,
         expiry_ms: expiry_ms,
         expiry_timer: nil,
         declared_media_type: Map.get(grant, :declared_media_type),
         magic_prefix: "",
         media_validated?: false,
         owner: owner,
         owner_monitor: nil,
         repo: nil,
         requirement: requirement(session, grant),
         session: session,
         signature_bytes: signature_bytes,
         stage: nil,
         storage: storage,
         pending_magic_chunks: [],
         telemetry_started_at: System.monotonic_time(),
         upload: upload,
         custody: :direct,
         writer: nil,
         writer_monitor: nil
       }}
    else
      :eq -> {:error, Error.new(:upload_expired), owner}
      :lt -> {:error, Error.new(:upload_expired), owner}
      {:error, %Error{} = error} -> {:error, error, owner}
      _invalid -> {:error, Error.new(:invalid), owner}
    end
  rescue
    _exception ->
      {:error, Error.new(:invalid), Keyword.get(options, :owner)}
  end

  defp adapters(runtime) do
    values = %{
      assets: Map.get(runtime, :assets, AssetRepository),
      authorization: Map.get(runtime, :authorization),
      authorization_lock: Map.get(runtime, :authorization_lock, AuthorizationLock),
      authorizer: Map.get(runtime, :authorizer, Authorize),
      clock: Map.get(runtime, :clock, fn -> DateTime.utc_now(:microsecond) end),
      custodian: Map.get(runtime, :custodian),
      request_repo: Map.get(runtime, :request_repo, RequestRepo),
      scoped_repo: Map.get(runtime, :scoped_repo, ScopedRepo),
      stage_writer: Map.get(runtime, :stage_writer, EncryptedStageWriter),
      vault_lock: Map.get(runtime, :vault_lock, VaultLock)
    }

    if Enum.all?(
         [
           values.assets,
           values.authorization,
           values.authorization_lock,
           values.authorizer,
           values.request_repo,
           values.scoped_repo,
           values.stage_writer,
           values.vault_lock
         ],
         &concrete?/1
       ) and is_function(values.clock, 0) do
      {:ok, values}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp validate_binding(session, grant) do
    if Map.get(grant, :session_id) == Map.get(session, :session_id) and
         Map.get(grant, :principal_id) == Map.get(session, :principal_id) and
         Map.get(grant, :vault_id) == Map.get(session, :vault_id) do
      :ok
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp consume_command(grant, upload) do
    grant_id = Map.get(grant, :grant_id, Map.get(grant, :id))

    command =
      upload
      |> Map.take(@stage_fields)
      |> Map.merge(
        Map.take(
          grant,
          @grant_fields ++ @request_binding_fields
        )
      )
      |> Map.put(:grant_id, grant_id)

    required =
      [:grant_id] ++
        @grant_fields ++ @request_binding_fields ++ @stage_fields

    valid? =
      Enum.all?(required, &concrete?(Map.get(command, &1))) and
        valid_digest?(command.token_digest) and
        valid_digest?(command.csrf_token_digest) and
        command.request_content_length == command.byte_size and
        command.request_declared_media_type ==
          command.declared_media_type

    if valid? do
      {:ok, command}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp raw_credentials_absent(grant) do
    if Enum.all?(
         [
           :token,
           "token",
           :upload_token,
           "upload_token",
           :csrf_token,
           "csrf_token"
         ],
         &(not Map.has_key?(grant, &1))
       ),
       do: :ok,
       else: {:error, Error.new(:invalid)}
  end

  defp valid_digest?(value),
    do: is_binary(value) and byte_size(value) == 32

  defp requirement(session, grant) do
    %{
      vault_id: Map.get(session, :vault_id),
      principal_authorization_epoch:
        Map.get(
          grant,
          :principal_authorization_epoch,
          Map.get(session, :principal_authorization_epoch)
        ),
      vault_authorization_epoch:
        Map.get(
          grant,
          :vault_authorization_epoch,
          Map.get(session, :vault_authorization_epoch)
        ),
      required_capability: "asset.write",
      classification: Map.get(grant, :classification),
      requires_unlocked?: true
    }
  end

  defp transaction_context(state) do
    %{
      principal_id: state.session.principal_id,
      vault_id: state.session.vault_id
    }
  end

  defp monitor_lifecycle(state) do
    %{
      state
      | owner_monitor: Process.monitor(state.owner),
        expiry_timer: Process.send_after(self(), :upload_expired, state.expiry_ms)
    }
  end

  defp release_lifecycle(%{
         expiry_timer: timer,
         owner_monitor: owner_monitor
       }) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    if is_reference(owner_monitor), do: Process.demonitor(owner_monitor, [:flush])
    :ok
  end

  defp release_lifecycle(_state), do: :ok

  defp stop_writer(%{writer: writer, writer_monitor: monitor}) do
    if is_pid(writer) and Process.alive?(writer), do: Process.exit(writer, :kill)
    if is_reference(monitor), do: Process.demonitor(monitor, [:flush])
    :ok
  end

  defp stop_writer(_state), do: :ok

  defp terminate_writer_with_owner(owner, writer) do
    owner_monitor = Process.monitor(owner)
    writer_monitor = Process.monitor(writer)

    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        Process.exit(writer, :kill)

        receive do
          {:DOWN, ^writer_monitor, :process, ^writer, _reason} -> :ok
        end

      {:DOWN, ^writer_monitor, :process, ^writer, _reason} ->
        Process.demonitor(owner_monitor, [:flush])
        :ok
    end
  end

  defp expired?(state) do
    case state.adapters.clock.() do
      %DateTime{} = now -> DateTime.compare(state.expires_at, now) != :gt
      _invalid -> true
    end
  end

  defp expiry_ms(now, expires_at) do
    case DateTime.diff(expires_at, now, :millisecond) do
      milliseconds when milliseconds > 0 -> {:ok, milliseconds}
      _expired -> {:error, Error.new(:upload_expired)}
    end
  end

  defp signature_bytes("application/pdf"), do: {:ok, 5}
  defp signature_bytes("image/jpeg"), do: {:ok, 3}
  defp signature_bytes("image/png"), do: {:ok, 8}

  defp signature_bytes(_declared_media_type),
    do: {:error, Error.new(:unsupported_media_type)}

  defp validate_magic(prefix, declared_media_type) do
    case UploadRequest.detect_media_type(prefix) do
      {:ok, ^declared_media_type} ->
        :ok

      {:ok, _other_media_type} ->
        {:error, Error.new(:unsupported_media_type)}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp stage_ref(stage) do
    case field(stage, :id) do
      stage_id when is_binary(stage_id) ->
        case Ecto.UUID.cast(stage_id) do
          {:ok, _uuid} -> {:ok, %StageRef{stage_id: stage_id}}
          :error -> {:error, Error.new(:invalid)}
        end

      _invalid ->
        {:error, Error.new(:invalid)}
    end
  end

  defp normalize_repository_result({:ok, result}), do: {:ok, result}

  defp normalize_repository_result({:error, %Error{}} = error), do: error

  defp normalize_repository_result(_invalid),
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp normalize_writer_result({:ok, result}) when is_map(result),
    do: {:ok, result}

  defp normalize_writer_result({:error, %Error{} = error, %StageRef{} = stage_ref}),
    do: {:error, error, stage_ref}

  defp normalize_writer_result({:error, %Error{} = error, nil}),
    do: {:error, error, nil}

  defp normalize_writer_result(_invalid),
    do: {:error, Error.new(:storage_unavailable, retryable?: true), nil}

  defp normalize_abandonment_result({:ok, _stage}), do: :ok
  defp normalize_abandonment_result(:ok), do: :ok

  defp normalize_abandonment_result({:error, %Error{}} = error),
    do: error

  defp normalize_abandonment_result(_invalid),
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp failure_code(:controller_disconnected),
    do: "controller_disconnected"

  defp failure_code(:custody_revoked), do: "custody_revoked"
  defp failure_code(:upload_expired), do: "upload_expired"
  defp failure_code(%Error{code: code}), do: Atom.to_string(code)
  defp failure_code(_reason), do: "controller_aborted"

  defp failed_loop(state, error) do
    owner = Map.get(state, :owner)

    receive do
      {:custody_revoke, custody_ref, revocation_ref, custodian}
      when is_reference(custody_ref) and is_reference(revocation_ref) ->
        if matching_custody?(state, custodian, custody_ref) do
          _result =
            terminate_custody_revoked(
              state,
              custodian,
              custody_ref,
              revocation_ref,
              nil
            )

          reply_queued(Error.new(:vault_locked))
        else
          failed_loop(state, error)
        end

      {:"$upload_call", caller, reference, _request} ->
        reply(caller, reference, {:error, error})
        reply_queued(error)

      {:DOWN, _monitor, :process, ^owner, _reason} ->
        :ok
    after
      1_000 -> :ok
    end
  end

  defp reply_queued(error) do
    receive do
      {:"$upload_call", caller, reference, _request} ->
        reply(caller, reference, {:error, error})
        reply_queued(error)
    after
      0 -> :ok
    end
  end

  defp call(session, request, timeout)
       when is_pid(session) and
              (timeout == :infinity or
                 (is_integer(timeout) and timeout >= 0)) do
    monitor = Process.monitor(session)
    reference = make_ref()
    send(session, {:"$upload_call", self(), reference, request})

    receive do
      {:upload_reply, ^reference, response} ->
        Process.demonitor(monitor, [:flush])
        response

      {:DOWN, ^monitor, :process, ^session, _reason} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp call(_session, _request, _timeout),
    do: {:error, Error.new(:invalid)}

  defp reply(caller, reference, response) do
    send(caller, {:upload_reply, reference, response})
    :ok
  end

  defp field(struct_or_map, key, default \\ nil)
  defp field(%_{} = struct, key, default), do: Map.get(struct, key, default)
  defp field(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp field(_value, _key, default), do: default

  defp adapter_module(module) when is_atom(module), do: module
  defp adapter_module({module, _context}) when is_atom(module), do: module

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end

  defp matching_custody?(
         %{custody: {:custodian, custodian, custody_ref}},
         sender,
         custody_ref
       ),
       do: adapter_pid(custodian) == sender

  defp matching_custody?(_state, _custodian, _custody_ref),
    do: false

  defp notify_custody_terminal(
         %{
           custody: {:custodian, custodian, custody_ref}
         },
         disposition
       )
       when disposition in [:sealed, :abandoned] do
    send(
      adapter_pid(custodian),
      {:upload_terminal, self(), custody_ref, disposition}
    )

    :ok
  end

  defp notify_custody_terminal(_state, _disposition), do: :ok

  defp adapter_pid({_module, pid}) when is_pid(pid), do: pid
  defp adapter_pid({_module, name}) when is_atom(name), do: Process.whereis(name)
  defp adapter_pid(pid) when is_pid(pid), do: pid
  defp adapter_pid(name) when is_atom(name), do: Process.whereis(name)

  defp concrete?(value), do: value not in [nil, false]

  defp max_upload_bytes do
    Application.get_env(
      :singularity_runtime,
      :max_upload_bytes,
      512 * 1024 * 1024
    )
  end
end
