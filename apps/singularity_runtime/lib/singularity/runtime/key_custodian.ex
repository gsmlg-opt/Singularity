defmodule Singularity.Runtime.KeyCustodian do
  @moduledoc """
  Session-scoped custody and synchronous revocation of opaque key leases.

  Argon2 work is intentionally excluded from this serialized process.
  """

  use GenServer

  alias Singularity.Core.Error
  alias Singularity.Runtime.Assets.UploadReconciler
  alias Singularity.Runtime.BackupKeyLease
  alias Singularity.Runtime.KeyLease
  alias Singularity.Runtime.KeyLeaseSupervisor
  alias Singularity.Storage.Crypto.BackupRecoveryWrapper

  @request_fields ~w[
    job_id vault_id principal_id required_capability
    principal_authorization_epoch vault_authorization_epoch object_id
    object_generation session_id
  ]a
  @metadata_request_fields ~w[
    job_id vault_id principal_id required_capability
    principal_authorization_epoch vault_authorization_epoch object_id
    object_generation processing_revision declared_media_type plaintext_byte_size
  ]a
  @checkpoint_context_fields [:key_reader, :repo, :repository_adapter, :scope]
  @upload_request_fields ~w[
    grant_id asset_id session_id principal_id vault_id
    principal_authorization_epoch vault_authorization_epoch classification
  ]a
  @default_pending_ttl_ms :timer.seconds(30)
  @default_backup_active_ttl_ms :timer.seconds(60)
  @default_idle_timeout_ms :timer.minutes(15)
  @default_upload_revoke_timeout_ms :timer.seconds(5)
  @default_upload_revoke_retry_ms :timer.seconds(1)
  @default_upload_kill_timeout_ms :timer.seconds(1)
  @default_upload_recovery_timeout_ms :timer.seconds(5)
  @default_idle_lock_retry_ms :timer.seconds(1)
  @max_rotation_id_bytes 255
  @max_rotation_items 10_000
  @max_wrapper_bytes 1_024
  @max_wrapper_generation 0xFFFFFFFF
  @rotation_algorithm "aes_256_gcm"
  @rotation_binding_fields [
    :session_id,
    :principal_id,
    :vault_id,
    :principal_authorization_epoch,
    :vault_authorization_epoch
  ]
  @backup_binding_fields [
    :expires_at,
    :manifest_id,
    :principal_authorization_epoch,
    :principal_id,
    :session_id,
    :vault_authorization_epoch,
    :vault_id
  ]
  @vault_rotation_fields @rotation_binding_fields ++
                           [
                             :vault_kek,
                             :current_vault_wrapper,
                             :current_vault_key_version_generation,
                             :next_vault_key_version_id,
                             :next_vault_key_version_generation,
                             :next_vault_wrapper_generation,
                             :active_domain_versions
                           ]
  @domain_rotation_fields @rotation_binding_fields ++
                            [
                              :key_domain_id,
                              :current_domain_wrapper,
                              :current_dedup_wrapper,
                              :next_domain_key_version_id,
                              :next_domain_key_generation,
                              :active_asset_envelopes
                            ]

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(adapters) do
    GenServer.start_link(__MODULE__, configured_backup_cipher(adapters))
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

  @spec discard_pending(GenServer.server(), reference() | binary()) :: :ok
  def discard_pending(server, pending),
    do: GenServer.call(server, {:discard_pending, pending}, :infinity)

  @spec discard_pending(reference() | binary()) :: :ok
  def discard_pending(pending), do: discard_pending(__MODULE__, pending)

  @spec prepare_backup_key(GenServer.server(), map()) ::
          {:ok, binary()} | {:error, Error.t()}
  def prepare_backup_key(server, prepared),
    do: GenServer.call(server, {:prepare_backup_key, prepared}, :infinity)

  @spec prepare_backup_key(
          GenServer.server(),
          map(),
          BackupKeyLease.Derived.t()
        ) :: {:ok, BackupKeyLease.Prepared.t()} | {:error, Error.t()}
  def prepare_backup_key(server, session, %BackupKeyLease.Derived{} = derived),
    do: GenServer.call(server, {:prepare_backup_key, session, derived}, :infinity)

  @spec activate_backup_key(GenServer.server(), binary()) ::
          :ok | {:error, Error.t()}
  def activate_backup_key(server, opaque_ref),
    do: GenServer.call(server, {:activate_backup_key, opaque_ref}, :infinity)

  @spec revoke_backup_key(GenServer.server(), binary()) :: :ok
  def revoke_backup_key(server, opaque_ref),
    do: GenServer.call(server, {:revoke_backup_key, opaque_ref}, :infinity)

  @spec revoke_backup_key(binary()) :: :ok
  def revoke_backup_key(opaque_ref), do: revoke_backup_key(__MODULE__, opaque_ref)

  @spec backup_crypto(GenServer.server(), binary(), binary()) ::
          {:ok, map()} | {:error, :lease_missing | Error.t()}
  def backup_crypto(server, manifest_id, opaque_ref),
    do: GenServer.call(server, {:backup_crypto, manifest_id, opaque_ref}, :infinity)

  @spec backup_key_state(GenServer.server()) :: %{
          active_refs: [binary()],
          pending_refs: [binary()]
        }
  def backup_key_state(server), do: GenServer.call(server, :backup_key_state)

  @spec unlocked?(GenServer.server(), String.t()) :: boolean()
  def unlocked?(server, session_id),
    do: GenServer.call(server, {:unlocked?, session_id})

  @spec unlocked?(String.t()) :: boolean()
  def unlocked?(session_id), do: unlocked?(__MODULE__, session_id)

  @spec assert_unlocked(
          GenServer.server(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          :ok | {:error, Error.t()}
  def assert_unlocked(
        server,
        session_id,
        principal_id,
        vault_id,
        principal_authorization_epoch,
        vault_authorization_epoch
      ),
      do:
        GenServer.call(
          server,
          {:assert_unlocked, session_id, principal_id, vault_id, principal_authorization_epoch,
           vault_authorization_epoch}
        )

  @spec assert_unlocked(
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          :ok | {:error, Error.t()}
  def assert_unlocked(
        session_id,
        principal_id,
        vault_id,
        principal_authorization_epoch,
        vault_authorization_epoch
      ),
      do:
        assert_unlocked(
          __MODULE__,
          session_id,
          principal_id,
          vault_id,
          principal_authorization_epoch,
          vault_authorization_epoch
        )

  @spec begin_revoke(GenServer.server(), map() | tuple()) ::
          {:ok, reference()} | {:error, Error.t()}
  def begin_revoke(server, selector),
    do: GenServer.call(server, {:begin_revoke, selector}, :infinity)

  @spec begin_revoke(map() | tuple()) ::
          {:ok, reference()} | {:error, Error.t()}
  def begin_revoke(selector), do: begin_revoke(__MODULE__, selector)

  @spec finish_revoke(GenServer.server(), reference()) ::
          :ok | {:error, Error.t()}
  def finish_revoke(server, token),
    do: GenServer.call(server, {:finish_revoke, token}, :infinity)

  @spec finish_revoke(reference()) :: :ok | {:error, Error.t()}
  def finish_revoke(token), do: finish_revoke(__MODULE__, token)

  @spec await_revoking(GenServer.server(), map() | tuple()) ::
          :ok | {:error, Error.t()}
  def await_revoking(server, selector),
    do: GenServer.call(server, {:await_revoking, selector}, :infinity)

  @spec await_revoking(map() | tuple()) :: :ok | {:error, Error.t()}
  def await_revoking(selector), do: await_revoking(__MODULE__, selector)

  @spec lease(GenServer.server(), map()) ::
          {:ok, KeyLease.ref()} | {:error, :waiting_for_unlock | Error.t()}
  def lease(server, request), do: GenServer.call(server, {:lease, request})

  @spec prepare_upload(GenServer.server(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepare_upload(server, request),
    do: GenServer.call(server, {:prepare_upload, request}, :infinity)

  @spec prepare_vault_rotation(GenServer.server(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepare_vault_rotation(server, request),
    do: GenServer.call(server, {:prepare_vault_rotation, request}, :infinity)

  @spec prepare_domain_rotation(GenServer.server(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def prepare_domain_rotation(server, request),
    do: GenServer.call(server, {:prepare_domain_rotation, request}, :infinity)

  @spec claim_upload(GenServer.server(), reference(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def claim_upload(server, material_ref, binding),
    do: GenServer.call(server, {:claim_upload, material_ref, binding}, :infinity)

  @spec discard_upload(GenServer.server(), reference()) :: :ok
  def discard_upload(server, material_ref),
    do: GenServer.call(server, {:discard_upload, material_ref}, :infinity)

  @spec attach_upload_worker(GenServer.server(), reference(), pid()) ::
          :ok | {:error, Error.t()}
  def attach_upload_worker(server, custody_ref, worker)
      when is_reference(custody_ref) and is_pid(worker),
      do:
        GenServer.call(
          server,
          {:attach_upload_worker, custody_ref, worker},
          :infinity
        )

  @impl true
  def init(
        %{
          authorization: authorization,
          backup_cipher: backup_cipher,
          clock: clock,
          context: context,
          idle_lock: idle_lock,
          key_reader: key_reader,
          object_key_loader: object_key_loader,
          lease_supervisor: lease_supervisor
        } = adapters
      ) do
    with true <- BackupKeyLease.valid_cipher_adapter?(backup_cipher) do
      {:ok,
       %{
         adapters: %{
           authorization: authorization,
           backup_cipher: backup_cipher,
           backup_recovery_wrapper:
             Map.get(adapters, :backup_recovery_wrapper, BackupRecoveryWrapper),
           backup_key_observer: Map.get(adapters, :backup_key_observer),
           clock: clock,
           idle_lock: idle_lock,
           key_reader: key_reader,
           key_wrapper:
             Map.get(
               adapters,
               :key_wrapper,
               Singularity.Storage.Crypto.KeyWrapper
             ),
           object_key_loader: object_key_loader,
           random_bytes: Map.get(adapters, :random_bytes, &:crypto.strong_rand_bytes/1)
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
         idle_lock_retry_ms:
           positive_option(
             Map.get(
               adapters,
               :idle_lock_retry_ms,
               @default_idle_lock_retry_ms
             ),
             @default_idle_lock_retry_ms
           ),
         lease_supervisor: lease_supervisor,
         leases: %{},
         monitors: %{},
         backup_active: %{},
         backup_active_monitors: %{},
         backup_active_ttl_ms:
           positive_option(
             Map.get(adapters, :backup_active_ttl_ms, @default_backup_active_ttl_ms),
             @default_backup_active_ttl_ms
           ),
         backup_pending: %{},
         backup_pending_monitors: %{},
         backup_pending_ttl_ms:
           positive_option(
             Map.get(adapters, :backup_pending_ttl_ms, @default_pending_ttl_ms),
             @default_pending_ttl_ms
           ),
         pending: %{},
         pending_monitors: %{},
         pending_ttl_ms:
           positive_option(
             Map.get(adapters, :pending_ttl_ms, @default_pending_ttl_ms),
             @default_pending_ttl_ms
           ),
         upload_material_ttl_ms:
           positive_option(
             Map.get(
               adapters,
               :upload_material_ttl_ms,
               @default_pending_ttl_ms
             ),
             @default_pending_ttl_ms
           ),
         upload_materials: %{},
         upload_monitors: %{},
         upload_recovery_monitors: %{},
         upload_recovery:
           Map.get(
             adapters,
             :upload_recovery,
             UploadReconciler.configured_context()
           ),
         upload_reconciler:
           Map.get(
             adapters,
             :upload_reconciler,
             UploadReconciler
           ),
         upload_recovery_supervisor:
           Map.get(
             adapters,
             :upload_recovery_supervisor,
             Singularity.Runtime.UploadRecoveryTaskSupervisor
           ),
         upload_recovery_timeout_ms:
           positive_option(
             Map.get(
               adapters,
               :upload_recovery_timeout_ms,
               @default_upload_recovery_timeout_ms
             ),
             @default_upload_recovery_timeout_ms
           ),
         upload_revocations: %{},
         upload_revoke_retry_ms:
           positive_option(
             Map.get(
               adapters,
               :upload_revoke_retry_ms,
               @default_upload_revoke_retry_ms
             ),
             @default_upload_revoke_retry_ms
           ),
         upload_revoke_timeout_ms:
           positive_option(
             Map.get(
               adapters,
               :upload_revoke_timeout_ms,
               @default_upload_revoke_timeout_ms
             ),
             @default_upload_revoke_timeout_ms
           ),
         upload_kill_timeout_ms:
           positive_option(
             Map.get(
               adapters,
               :upload_kill_timeout_ms,
               @default_upload_kill_timeout_ms
             ),
             @default_upload_kill_timeout_ms
           ),
         uploads: %{},
         revoking: %{},
         revocation_waiter_monitors: %{},
         revocation_waiters: %{},
         sessions: %{},
         wake_limit:
           adapters
           |> Map.get(:wake_limit, 25)
           |> positive_option(25)
           |> min(100),
         wake_waiting: Map.get(adapters, :wake_waiting)
       }}
    else
      false -> {:stop, :invalid_backup_cipher}
    end
  end

  def init(_adapters), do: {:stop, :invalid_backup_cipher}

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} ->
        {:state,
         %{
           active_backup_count: map_size(Map.get(state, :backup_active, %{})),
           active_lease_session_count: map_size(Map.get(state, :leases, %{})),
           active_session_count: map_size(Map.get(state, :sessions, %{})),
           active_upload_count: map_size(Map.get(state, :uploads, %{})),
           custody: "[REDACTED]",
           pending_backup_count: map_size(Map.get(state, :backup_pending, %{})),
           pending_unlock_count: map_size(Map.get(state, :pending, %{})),
           pending_upload_material_count: map_size(Map.get(state, :upload_materials, %{}))
         }}

      {:message, _message} ->
        {:message, "[REDACTED]"}

      {:reason, _reason} ->
        {:reason, "[REDACTED]"}

      {:log, _log} ->
        {:log, "[REDACTED]"}

      key_value ->
        key_value
    end)
  end

  @impl true
  def handle_call({:prepare_unlock, session}, {owner, _tag}, state) do
    case validate_session(session) do
      :ok ->
        if matching_revocation?(state, session) do
          {:reply, {:error, Error.new(:conflict)}, state}
        else
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
        end

      {:error, %Error{}} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:activate_unlock, pending}, {owner, _tag}, state) do
    case Map.get(state.pending, pending) do
      %{owner: ^owner, session: session} ->
        if matching_revocation?(state, session) do
          {:reply, {:error, Error.new(:conflict)}, discard_pending_entry(state, pending)}
        else
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
        end

      _missing_or_foreign ->
        {:reply, {:error, Error.new(:conflict)}, state}
    end
  end

  def handle_call({:prepare_backup_key, prepared}, {owner, _tag}, state) do
    case validate_backup_prepared(prepared) do
      {:ok, opaque_ref, entry} ->
        install_backup_pending(state, owner, opaque_ref, entry, {:ok, opaque_ref})

      {:error, %Error{}} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:prepare_backup_key, session, %BackupKeyLease.Derived{} = derived},
        {owner, _tag},
        state
      ) do
    case prepare_session_backup(state, session, derived) do
      {:ok, opaque_ref, entry, prepared} ->
        install_backup_pending(state, owner, opaque_ref, entry, {:ok, prepared})

      {:error, %Error{}} = error ->
        _cleared = overwrite(derived.key_material)
        {:reply, error, state}
    end
  end

  def handle_call({:activate_backup_key, opaque_ref}, {owner, _tag}, state)
      when is_binary(opaque_ref) do
    case Map.get(state.backup_pending, opaque_ref) do
      %{owner: ^owner} = entry ->
        state = remove_backup_pending(state, opaque_ref, false)

        case start_backup_lease(state, entry) do
          {:ok, lease} ->
            monitor = Process.monitor(lease)

            active_entry = %{
              lease: lease,
              manifest_id: entry.binding.manifest_id,
              monitor: monitor,
              public_header: backup_public_header(entry)
            }

            next_state =
              state
              |> put_in([:backup_active, opaque_ref], active_entry)
              |> put_in([:backup_active_monitors, monitor], {opaque_ref, lease})

            {:reply, :ok, next_state}

          {:error, _reason} ->
            _cleared = overwrite(entry.key_material)
            {:reply, {:error, Error.new(:conflict)}, state}
        end

      _missing_or_foreign ->
        {:reply, {:error, Error.new(:conflict)}, state}
    end
  end

  def handle_call({:activate_backup_key, _opaque_ref}, _from, state),
    do: {:reply, {:error, Error.new(:conflict)}, state}

  def handle_call({:revoke_backup_key, opaque_ref}, _from, state)
      when is_binary(opaque_ref) do
    next_state =
      state
      |> remove_backup_pending(opaque_ref)
      |> revoke_backup_active(opaque_ref)

    {:reply, :ok, next_state}
  end

  def handle_call({:revoke_backup_key, _opaque_ref}, _from, state),
    do: {:reply, :ok, state}

  def handle_call({:backup_crypto, manifest_id, opaque_ref}, _from, state)
      when is_binary(manifest_id) and is_binary(opaque_ref) do
    case Map.get(state.backup_active, opaque_ref) do
      %{lease: lease, manifest_id: ^manifest_id, public_header: public_header}
      when is_pid(lease) ->
        if Process.alive?(lease) do
          {:reply,
           {:ok,
            %{
              adapter: BackupKeyLease.StorageAdapter,
              capability: lease,
              public_header: public_header
            }}, state}
        else
          {:reply, {:error, :lease_missing}, state}
        end

      %{lease: _lease} ->
        {:reply, {:error, Error.new(:backup_invalid)}, state}

      nil ->
        {:reply, {:error, :lease_missing}, state}
    end
  end

  def handle_call({:backup_crypto, _manifest_id, _opaque_ref}, _from, state),
    do: {:reply, {:error, :lease_missing}, state}

  def handle_call(:backup_key_state, _from, state) do
    {:reply,
     %{
       active_refs: state.backup_active |> Map.keys() |> Enum.sort(),
       pending_refs: state.backup_pending |> Map.keys() |> Enum.sort()
     }, state}
  end

  def handle_call({:discard_pending, pending}, _from, state) do
    next_state =
      if is_binary(pending) do
        remove_backup_pending(state, pending)
      else
        discard_pending_entry(state, pending)
      end

    {:reply, :ok, next_state}
  end

  def handle_call({:unlocked?, session_id}, _from, state) do
    {:reply, active_session?(state, session_id), state}
  end

  def handle_call(
        {:assert_unlocked, session_id, principal_id, vault_id, principal_authorization_epoch,
         vault_authorization_epoch},
        _from,
        state
      ) do
    case Map.get(state.sessions, session_id) do
      %{
        principal_id: ^principal_id,
        vault_id: ^vault_id,
        principal_authorization_epoch: ^principal_authorization_epoch,
        vault_authorization_epoch: ^vault_authorization_epoch
      } = session ->
        if matching_revocation?(state, session) do
          {:reply, {:error, Error.new(:vault_locked)}, state}
        else
          {:reply, :ok, touch_session(state, session_id)}
        end

      _locked_or_mismatched ->
        {:reply, {:error, Error.new(:vault_locked)}, state}
    end
  end

  def handle_call({:prepare_vault_rotation, request}, _from, state) do
    with :ok <- validate_vault_rotation_request(request),
         {:ok, session} <- rotation_session(state, request),
         {:ok, plan} <- build_vault_rotation_plan(state, session, request) do
      {:reply, {:ok, plan}, touch_session(state, session.session_id)}
    else
      {:error, %Error{}} = error -> {:reply, error, state}
    end
  end

  def handle_call({:prepare_domain_rotation, request}, _from, state) do
    with :ok <- validate_domain_rotation_request(request),
         {:ok, session} <- rotation_domain_session(state, request),
         {:ok, plan} <- build_domain_rotation_plan(state, session, request) do
      {:reply, {:ok, plan}, touch_session(state, session.session_id)}
    else
      {:error, %Error{}} = error -> {:reply, error, state}
    end
  end

  def handle_call({:begin_revoke, selector}, from, state) do
    case normalize_selector(selector) do
      {:ok, normalized} ->
        token = make_ref()

        {state, pending} =
          state
          |> put_in([:revoking, token], normalized)
          |> begin_revocation(normalized, token)

        if MapSet.size(pending) == 0 do
          {:reply, {:ok, token}, state}
        else
          caller = elem(from, 0)
          monitor = Process.monitor(caller)

          waiter = %{
            completion: :begin_revoke,
            from: from,
            monitor: monitor,
            pending: pending
          }

          {:noreply,
           state
           |> put_in(
             [:revocation_waiters, token],
             waiter
           )
           |> put_in(
             [:revocation_waiter_monitors, monitor],
             token
           )}
        end

      :error ->
        {:reply, {:error, Error.new(:invalid)}, state}
    end
  end

  def handle_call({:finish_revoke, token}, _from, state) when is_reference(token) do
    {:reply, :ok, %{state | revoking: Map.delete(state.revoking, token)}}
  end

  def handle_call({:finish_revoke, _token}, _from, state) do
    {:reply, {:error, Error.new(:invalid)}, state}
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

  def handle_call({:lease, %{purpose: :download} = request}, _from, state) do
    with :ok <- validate_download_request(request),
         binding = Map.take(request, @request_fields),
         %{
           principal_id: principal_id,
           vault_id: vault_id,
           principal_authorization_epoch: principal_authorization_epoch,
           vault_authorization_epoch: vault_authorization_epoch
         } = session <-
           Map.get(state.sessions, binding.session_id),
         false <- matching_revocation?(state, session),
         true <- vault_id == binding.vault_id,
         true <- principal_id == binding.principal_id,
         true <-
           principal_authorization_epoch ==
             binding.principal_authorization_epoch,
         true <-
           vault_authorization_epoch ==
             binding.vault_authorization_epoch,
         {:ok, %{object_dek: object_dek, reader_binding: reader_binding}} <-
           object_key(state, session, binding),
         reader_context =
           Map.put(state.context, :object_binding, reader_binding),
         {:ok, lease} <-
           start_download_lease(
             state,
             binding,
             object_dek,
             reader_context
           ) do
      {:reply, {:ok, lease}, register_lease(state, binding, lease)}
    else
      nil -> {:reply, {:error, :waiting_for_unlock}, state}
      true -> {:reply, {:error, :waiting_for_unlock}, state}
      false -> {:reply, {:error, :waiting_for_unlock}, state}
      {:error, :waiting_for_unlock} -> {:reply, {:error, :waiting_for_unlock}, state}
      {:error, %Error{}} = error -> {:reply, error, state}
      {:error, _reason} -> {:reply, {:error, Error.new(:storage_unavailable)}, state}
    end
  end

  def handle_call({:lease, %{purpose: :metadata} = request}, _from, state) do
    with :ok <- validate_metadata_request(request),
         %{} = session <- metadata_session(state, request),
         checkpoint_binding = Map.take(request, @metadata_request_fields),
         binding = Map.put(checkpoint_binding, :session_id, session.session_id),
         {:ok, %{object_dek: object_dek, reader_binding: reader_binding}} <-
           object_key(state, session, binding),
         reader_context =
           Map.put(state.context, :object_binding, reader_binding),
         checkpoint_context = checkpoint_context(state.context, reader_binding),
         {:ok, checkpoint} <-
           state.adapters.key_reader.load_checkpoint(checkpoint_context, checkpoint_binding),
         {:ok, _next_index, _extractor_state} <-
           KeyLease.validate_metadata_checkpoint(checkpoint, checkpoint_binding),
         {:ok, lease} <-
           start_metadata_lease(
             state,
             binding,
             checkpoint_binding,
             session.session_id,
             checkpoint,
             object_dek,
             reader_context,
             checkpoint_context,
             session.expires_at
           ) do
      {:reply, {:ok, lease}, register_lease(state, session.session_id, lease)}
    else
      nil -> {:reply, {:error, :waiting_for_unlock}, state}
      {:error, :waiting_for_unlock} -> {:reply, {:error, :waiting_for_unlock}, state}
      {:error, %Error{}} = error -> {:reply, error, state}
      {:error, _reason} -> {:reply, {:error, Error.new(:storage_unavailable)}, state}
    end
  end

  def handle_call({:lease, request}, _from, state) do
    with :ok <- validate_request(request),
         binding = Map.take(request, @request_fields),
         %{
           principal_id: principal_id,
           vault_id: vault_id,
           principal_authorization_epoch: principal_authorization_epoch,
           vault_authorization_epoch: vault_authorization_epoch
         } = session <-
           Map.get(state.sessions, binding.session_id),
         false <- matching_revocation?(state, session),
         true <- vault_id == binding.vault_id,
         true <- principal_id == binding.principal_id,
         true <-
           principal_authorization_epoch ==
             binding.principal_authorization_epoch,
         true <-
           vault_authorization_epoch ==
             binding.vault_authorization_epoch,
         {:ok, %{object_dek: object_dek, reader_binding: reader_binding}} <-
           object_key(state, session, binding),
         reader_context =
           Map.put(state.context, :object_binding, reader_binding),
         checkpoint_binding = binding,
         checkpoint_context = checkpoint_context(state.context, reader_binding),
         {:ok, checkpoint} <-
           state.adapters.key_reader.load_checkpoint(checkpoint_context, checkpoint_binding),
         {:ok, _next_index} <- KeyLease.validate_checkpoint(checkpoint, checkpoint_binding),
         {:ok, lease} <-
           start_lease(
             state,
             binding,
             checkpoint_binding,
             checkpoint,
             object_dek,
             reader_context,
             checkpoint_context,
             Map.get(session, :expires_at)
           ) do
      {:reply, {:ok, lease}, register_lease(state, binding, lease)}
    else
      nil -> {:reply, {:error, :waiting_for_unlock}, state}
      true -> {:reply, {:error, :waiting_for_unlock}, state}
      false -> {:reply, {:error, :waiting_for_unlock}, state}
      {:error, :waiting_for_unlock} -> {:reply, {:error, :waiting_for_unlock}, state}
      {:error, %Error{}} = error -> {:reply, error, state}
      {:error, _reason} -> {:reply, {:error, Error.new(:storage_unavailable)}, state}
    end
  end

  def handle_call({:prepare_upload, request}, _from, state) do
    with :ok <- validate_upload_request(request),
         %{
           principal_id: principal_id,
           vault_id: vault_id,
           principal_authorization_epoch: principal_authorization_epoch,
           vault_authorization_epoch: vault_authorization_epoch,
           domain_key: <<_::binary-size(32)>>,
           domain_dedup_key: <<_::binary-size(32)>>,
           domain_classification: classification
         } = session <- Map.get(state.sessions, request.session_id),
         false <- matching_revocation?(state, session),
         true <- principal_id == request.principal_id,
         true <- vault_id == request.vault_id,
         true <-
           principal_authorization_epoch ==
             request.principal_authorization_epoch,
         true <-
           vault_authorization_epoch ==
             request.vault_authorization_epoch,
         true <- classification == request.classification,
         {:ok, prepared, secret} <-
           build_upload_material(state, session, request) do
      timer =
        Process.send_after(
          self(),
          {:expire_upload_material, prepared.material_ref},
          state.upload_material_ttl_ms
        )

      entry =
        secret
        |> Map.put(:binding, upload_binding(request))
        |> Map.put(:recovery, %{
          stage_id: prepared.stage_id,
          storage_ref: prepared.storage_ref
        })
        |> Map.put(:timer, timer)

      next_state =
        state
        |> put_in([:upload_materials, prepared.material_ref], entry)
        |> touch_session(request.session_id)

      {:reply, {:ok, prepared}, next_state}
    else
      nil -> {:reply, {:error, Error.new(:vault_locked)}, state}
      true -> {:reply, {:error, Error.new(:vault_locked)}, state}
      false -> {:reply, {:error, Error.new(:forbidden)}, state}
      {:error, %Error{}} = error -> {:reply, error, state}
      _invalid -> {:reply, {:error, Error.new(:integrity_failure)}, state}
    end
  end

  def handle_call(
        {:claim_upload, material_ref, binding},
        {owner, _tag},
        state
      )
      when is_reference(material_ref) and is_map(binding) do
    case Map.get(state.upload_materials, material_ref) do
      %{
        binding: expected,
        recovery: expected_recovery
      } = entry ->
        with true <- expected == upload_binding(binding),
             {:ok, recovery} <- upload_recovery(binding),
             true <- recovery == expected_recovery do
          Process.cancel_timer(entry.timer)
          custody_ref = make_ref()

          material = %{
            object_dek: entry.object_dek,
            domain_dedup_key: entry.domain_dedup_key,
            custody_ref: custody_ref
          }

          next_state =
            state
            |> Map.put(
              :upload_materials,
              Map.delete(state.upload_materials, material_ref)
            )
            |> register_upload(
              owner,
              expected,
              recovery,
              custody_ref
            )

          {:reply, {:ok, material}, next_state}
        else
          false ->
            {:reply, {:error, Error.new(:conflict)}, state}

          {:error, %Error{}} = error ->
            {:reply, error, state}
        end

      _missing_or_changed ->
        {:reply, {:error, Error.new(:conflict)}, state}
    end
  end

  def handle_call({:claim_upload, _material_ref, _binding}, _from, state) do
    {:reply, {:error, Error.new(:invalid)}, state}
  end

  def handle_call({:discard_upload, material_ref}, _from, state)
      when is_reference(material_ref) do
    {:reply, :ok, discard_upload_material(state, material_ref)}
  end

  def handle_call({:discard_upload, _material_ref}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(
        {:attach_upload_worker, custody_ref, worker},
        {owner, _tag},
        state
      )
      when is_reference(custody_ref) and is_pid(worker) do
    case Map.get(state.uploads, owner) do
      %{custody_ref: ^custody_ref, worker: nil} = entry ->
        monitor = Process.monitor(worker)

        next_state =
          state
          |> put_in(
            [:uploads, owner],
            %{entry | worker: worker, worker_monitor: monitor}
          )
          |> put_in(
            [:upload_monitors, monitor],
            {:worker, owner, worker}
          )
          |> update_revocation_worker(owner, worker)

        {:reply, :ok, next_state}

      _missing_or_already_attached ->
        {:reply, {:error, Error.new(:conflict)}, state}
    end
  end

  def handle_call(
        {:attach_upload_worker, _custody_ref, _worker},
        _from,
        state
      ) do
    {:reply, {:error, Error.new(:invalid)}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, process, reason}, state) do
    next_state =
      case handle_backup_down(state, monitor, process) do
        {:handled, state} ->
          state

        :unhandled ->
          case Map.pop(state.pending_monitors, monitor) do
            {pending, pending_monitors} when is_reference(pending) ->
              state
              |> Map.put(:pending_monitors, pending_monitors)
              |> discard_pending_entry(pending, false)

            {nil, _pending_monitors} ->
              state
              |> handle_revocation_waiter_down(monitor, process)
              |> handle_upload_recovery_down(
                monitor,
                process,
                reason
              )
              |> handle_custody_owner_down(
                monitor,
                process
              )
          end
      end

    {:noreply,
     next_state
     |> progress_upload_recoveries()
     |> complete_upload_revocations()}
  end

  def handle_info(
        {:custody_revoke_result, upload, custody_ref, revocation_ref, result},
        state
      )
      when is_pid(upload) and is_reference(custody_ref) and
             is_reference(revocation_ref) do
    next_state =
      case Map.get(state.upload_revocations, revocation_ref) do
        %{
          upload: ^upload,
          custody_ref: ^custody_ref
        } = revocation ->
          case normalize_revocation_result(result) do
            :ok ->
              cancel_revocation_timer(revocation.timer)

              put_in(
                state,
                [:upload_revocations, revocation_ref],
                %{
                  revocation
                  | fallback?: false,
                    result: :ok,
                    timer: nil
                }
              )

            {:error, %Error{}} ->
              cancel_revocation_timer(revocation.timer)

              state
              |> put_in(
                [:upload_revocations, revocation_ref],
                %{
                  revocation
                  | fallback?: true,
                    result: :pending,
                    timer: nil
                }
              )
              |> kill_revocation_processes(revocation)
          end

        _forged_or_stale ->
          state
      end

    {:noreply,
     next_state
     |> progress_upload_recoveries()
     |> complete_upload_revocations()}
  end

  def handle_info(
        {:upload_terminal, upload, custody_ref, disposition},
        state
      )
      when is_pid(upload) and is_reference(custody_ref) and
             disposition in [:sealed, :abandoned] do
    next_state =
      case Map.get(state.uploads, upload) do
        %{
          custody_ref: ^custody_ref,
          revocation_ref: nil
        } ->
          remove_upload(state, upload)

        %{
          custody_ref: ^custody_ref,
          revocation_ref: revocation_ref
        }
        when is_reference(revocation_ref) ->
          record_terminal_upload(
            state,
            revocation_ref,
            disposition
          )

        _forged_or_stale ->
          state
      end

    {:noreply,
     next_state
     |> progress_upload_recoveries()
     |> complete_upload_revocations()}
  end

  def handle_info(
        {:upload_revocation_timeout, revocation_ref, tag},
        state
      )
      when is_reference(revocation_ref) and is_reference(tag) do
    {:noreply,
     state
     |> handle_upload_revocation_timeout(revocation_ref, tag)
     |> complete_upload_revocations()}
  end

  def handle_info(
        {:upload_recovery_result, revocation_ref, attempt_ref, task, result},
        state
      )
      when is_reference(revocation_ref) and is_reference(attempt_ref) and
             is_pid(task) do
    {:noreply,
     state
     |> record_upload_recovery_result(
       revocation_ref,
       attempt_ref,
       task,
       result
     )
     |> complete_upload_revocations()}
  end

  def handle_info(
        {:upload_recovery_timeout, revocation_ref, attempt_ref, task},
        state
      )
      when is_reference(revocation_ref) and is_reference(attempt_ref) and
             is_pid(task) do
    {:noreply,
     timeout_upload_recovery(
       state,
       revocation_ref,
       attempt_ref,
       task
     )}
  end

  def handle_info({:expire_pending, pending}, state) do
    next_state =
      if is_binary(pending) do
        remove_backup_pending(state, pending)
      else
        discard_pending_entry(state, pending)
      end

    {:noreply, next_state}
  end

  def handle_info({:expire_upload_material, material_ref}, state) do
    {:noreply, discard_upload_material(state, material_ref)}
  end

  def handle_info({:idle_lock, session_id, token}, state) do
    case Map.get(state.idle_timers, session_id) do
      {_timer, ^token} ->
        session = Map.get(state.sessions, session_id)
        selector = %{vault_id: session.vault_id}
        revocation_token = make_ref()

        {state, pending} =
          state
          |> put_in([:revoking, revocation_token], selector)
          |> begin_revocation(selector, revocation_token)

        waiter = %{
          completion: {:idle_lock, session},
          from: nil,
          idle_retry: nil,
          monitor: nil,
          pending: pending
        }

        next_state =
          put_in(
            state,
            [:revocation_waiters, revocation_token],
            waiter
          )

        if MapSet.size(pending) == 0 do
          {:noreply,
           attempt_idle_lock(
             next_state,
             revocation_token
           )}
        else
          {:noreply, next_state}
        end

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

  def handle_info({:idle_lock_retry, token, tag}, state)
      when is_reference(token) and is_reference(tag) do
    case Map.get(state.revocation_waiters, token) do
      %{
        completion: {:idle_lock, _session},
        idle_retry: {_timer, ^tag},
        pending: pending
      } ->
        if MapSet.size(pending) == 0 do
          {:noreply,
           state
           |> put_in(
             [:revocation_waiters, token, :idle_retry],
             nil
           )
           |> attempt_idle_lock(token)}
        else
          {:noreply, state}
        end

      _stale_or_pending ->
        {:noreply, state}
    end
  end

  defp start_lease(
         state,
         binding,
         checkpoint_binding,
         checkpoint,
         object_dek,
         reader_context,
         checkpoint_context,
         session_expires_at
       ) do
    KeyLeaseSupervisor.start_lease(state.lease_supervisor, %{
      authorization: state.adapters.authorization,
      binding: binding,
      checkpoint: checkpoint,
      checkpoint_binding: checkpoint_binding,
      checkpoint_context: checkpoint_context,
      clock: state.adapters.clock,
      context: reader_context,
      custodian: self(),
      key_material: object_dek,
      key_reader: state.adapters.key_reader,
      maximum_expires_at: session_expires_at
    })
  end

  defp start_metadata_lease(
         state,
         binding,
         checkpoint_binding,
         session_id,
         checkpoint,
         object_dek,
         reader_context,
         checkpoint_context,
         session_expires_at
       ) do
    KeyLeaseSupervisor.start_lease(state.lease_supervisor, %{
      authorization: state.adapters.authorization,
      binding: binding,
      checkpoint: checkpoint,
      checkpoint_binding: checkpoint_binding,
      checkpoint_context: checkpoint_context,
      clock: state.adapters.clock,
      context: reader_context,
      custodian: self(),
      key_material: object_dek,
      key_reader: state.adapters.key_reader,
      maximum_expires_at: session_expires_at,
      session_id: session_id
    })
  end

  defp start_download_lease(
         state,
         request,
         object_dek,
         reader_context
       ) do
    KeyLeaseSupervisor.start_download_lease(state.lease_supervisor, %{
      authorization: state.adapters.authorization,
      binding: request,
      clock: state.adapters.clock,
      context: reader_context,
      custodian: self(),
      key_material: object_dek,
      key_reader: state.adapters.key_reader
    })
  end

  defp validate_vault_rotation_request(request) when is_map(request) do
    with true <- exact_keys?(request, @vault_rotation_fields),
         true <- valid_rotation_binding?(request),
         <<_::binary-size(32)>> <- request.vault_kek,
         true <- valid_current_vault_wrapper?(request.current_vault_wrapper),
         true <-
           valid_generation?(request.current_vault_key_version_generation),
         true <- bounded_rotation_id?(request.next_vault_key_version_id),
         true <-
           request.next_vault_key_version_id !=
             request.current_vault_wrapper.vault_key_version_id,
         true <-
           next_generation?(
             request.current_vault_key_version_generation,
             request.next_vault_key_version_generation
           ),
         true <-
           next_generation?(
             request.current_vault_wrapper.generation,
             request.next_vault_wrapper_generation
           ),
         true <- valid_active_domain_versions?(request.active_domain_versions) do
      :ok
    else
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_vault_rotation_request(_request),
    do: {:error, Error.new(:invalid)}

  defp validate_domain_rotation_request(request) when is_map(request) do
    with true <- exact_keys?(request, @domain_rotation_fields),
         true <- valid_rotation_binding?(request),
         true <- bounded_rotation_id?(request.key_domain_id),
         true <- valid_current_domain_wrapper?(request.current_domain_wrapper),
         true <- valid_current_dedup_wrapper?(request.current_dedup_wrapper),
         true <- bounded_rotation_id?(request.next_domain_key_version_id),
         true <-
           request.next_domain_key_version_id !=
             request.current_domain_wrapper.id,
         true <-
           next_generation?(
             request.current_domain_wrapper.generation,
             request.next_domain_key_generation
           ),
         true <-
           valid_active_asset_envelopes?(
             request.active_asset_envelopes,
             request.current_domain_wrapper
           ) do
      :ok
    else
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_domain_rotation_request(_request),
    do: {:error, Error.new(:invalid)}

  defp valid_rotation_binding?(request) do
    Enum.all?(
      [:session_id, :principal_id, :vault_id],
      &bounded_rotation_id?(Map.get(request, &1))
    ) and
      valid_authorization_epoch?(Map.get(request, :principal_authorization_epoch)) and
      valid_authorization_epoch?(Map.get(request, :vault_authorization_epoch))
  end

  defp valid_authorization_epoch?(epoch),
    do: is_integer(epoch) and epoch >= 0

  defp valid_current_vault_wrapper?(wrapper) when is_map(wrapper) do
    exact_keys?(
      wrapper,
      [:algorithm, :generation, :vault_key_version_id, :wrapped_key]
    ) and
      wrapper.algorithm == @rotation_algorithm and
      valid_generation?(wrapper.generation) and
      bounded_rotation_id?(wrapper.vault_key_version_id) and
      valid_rotation_wrapper?(wrapper.wrapped_key)
  end

  defp valid_current_vault_wrapper?(_wrapper), do: false

  defp valid_current_domain_wrapper?(wrapper) when is_map(wrapper) do
    exact_keys?(
      wrapper,
      [
        :algorithm,
        :generation,
        :id,
        :vault_key_version_id,
        :wrapped_key
      ]
    ) and
      wrapper.algorithm == @rotation_algorithm and
      valid_generation?(wrapper.generation) and
      bounded_rotation_id?(wrapper.id) and
      bounded_rotation_id?(wrapper.vault_key_version_id) and
      valid_rotation_wrapper?(wrapper.wrapped_key)
  end

  defp valid_current_domain_wrapper?(_wrapper), do: false

  defp valid_current_dedup_wrapper?(wrapper) when is_map(wrapper) do
    exact_keys?(wrapper, [:algorithm, :wrapped_key]) and
      wrapper.algorithm == @rotation_algorithm and
      valid_rotation_wrapper?(wrapper.wrapped_key)
  end

  defp valid_current_dedup_wrapper?(_wrapper), do: false

  defp valid_active_domain_versions?(versions)
       when is_list(versions) and versions != [] do
    bounded_rotation_list?(versions) and
      Enum.all?(versions, &valid_active_domain_version?/1) and
      unique_rotation_field?(versions, :id) and
      unique_rotation_field?(versions, :key_domain_id)
  end

  defp valid_active_domain_versions?(_versions), do: false

  defp valid_active_domain_version?(version) when is_map(version) do
    exact_keys?(
      version,
      [:algorithm, :generation, :id, :key_domain_id, :wrapped_key]
    ) and
      version.algorithm == @rotation_algorithm and
      valid_generation?(version.generation) and
      bounded_rotation_id?(version.id) and
      bounded_rotation_id?(version.key_domain_id) and
      valid_rotation_wrapper?(version.wrapped_key)
  end

  defp valid_active_domain_version?(_version), do: false

  defp valid_active_asset_envelopes?(envelopes, current_domain)
       when is_list(envelopes) do
    bounded_rotation_list?(envelopes) and
      Enum.all?(
        envelopes,
        &valid_active_asset_envelope?(&1, current_domain)
      ) and
      unique_rotation_field?(envelopes, :id) and
      unique_rotation_field?(envelopes, :asset_object_id)
  end

  defp valid_active_asset_envelopes?(_envelopes, _current_domain),
    do: false

  defp valid_active_asset_envelope?(envelope, current_domain)
       when is_map(envelope) do
    exact_keys?(
      envelope,
      [
        :algorithm,
        :asset_object_id,
        :classification,
        :domain_key_version_id,
        :id,
        :key_generation,
        :wrapped_dek
      ]
    ) and
      envelope.algorithm == @rotation_algorithm and
      envelope.classification in [:private, :sensitive, :restricted] and
      envelope.domain_key_version_id == current_domain.id and
      envelope.key_generation == current_domain.generation and
      bounded_rotation_id?(envelope.id) and
      bounded_rotation_id?(envelope.asset_object_id) and
      valid_rotation_wrapper?(envelope.wrapped_dek)
  end

  defp valid_active_asset_envelope?(_envelope, _current_domain),
    do: false

  defp exact_keys?(map, expected) when is_map(map),
    do: MapSet.new(Map.keys(map)) == MapSet.new(expected)

  defp bounded_rotation_id?(value) when is_binary(value) do
    byte_size(value) > 0 and byte_size(value) <= @max_rotation_id_bytes and
      String.valid?(value) and String.trim(value) != ""
  end

  defp bounded_rotation_id?(_value), do: false

  defp bounded_rotation_list?(values),
    do: bounded_rotation_list?(values, 0)

  defp bounded_rotation_list?([], count),
    do: count <= @max_rotation_items

  defp bounded_rotation_list?([_value | remaining], count)
       when count < @max_rotation_items,
       do: bounded_rotation_list?(remaining, count + 1)

  defp bounded_rotation_list?(_improper_or_oversized, _count), do: false

  defp valid_rotation_wrapper?(wrapper),
    do:
      is_binary(wrapper) and byte_size(wrapper) > 0 and
        byte_size(wrapper) <= @max_wrapper_bytes

  defp valid_generation?(generation),
    do:
      is_integer(generation) and generation > 0 and
        generation <= @max_wrapper_generation

  defp next_generation?(current, next),
    do:
      valid_generation?(current) and valid_generation?(next) and
        current < @max_wrapper_generation and next == current + 1

  defp unique_rotation_field?(values, field) do
    values
    |> Enum.map(&Map.fetch!(&1, field))
    |> then(&(MapSet.size(MapSet.new(&1)) == length(&1)))
  end

  defp rotation_session(state, request) do
    case Map.get(state.sessions, request.session_id) do
      %{
        session_id: session_id,
        principal_id: principal_id,
        vault_id: vault_id,
        principal_authorization_epoch: principal_authorization_epoch,
        vault_authorization_epoch: vault_authorization_epoch,
        vault_key: <<_::binary-size(32)>>
      } = session
      when session_id == request.session_id and
             principal_id == request.principal_id and
             vault_id == request.vault_id and
             principal_authorization_epoch ==
               request.principal_authorization_epoch and
             vault_authorization_epoch ==
               request.vault_authorization_epoch ->
        if matching_revocation?(state, session),
          do: {:error, Error.new(:vault_locked)},
          else: {:ok, session}

      _locked_or_mismatched ->
        {:error, Error.new(:vault_locked)}
    end
  end

  defp rotation_domain_session(state, request) do
    with {:ok, session} <- rotation_session(state, request),
         %{
           key_domain_id: key_domain_id,
           domain_key_version_id: domain_key_version_id,
           domain_key_generation: domain_key_generation,
           domain_classification: domain_classification,
           domain_key: <<_::binary-size(32)>>,
           domain_dedup_key: <<_::binary-size(32)>>
         } <- session,
         true <- key_domain_id == request.key_domain_id,
         true <-
           domain_key_version_id == request.current_domain_wrapper.id,
         true <-
           domain_key_generation ==
             request.current_domain_wrapper.generation,
         true <-
           Enum.all?(
             request.active_asset_envelopes,
             &(&1.classification == domain_classification)
           ) do
      {:ok, session}
    else
      {:error, %Error{}} = error -> error
      _mismatched -> {:error, Error.new(:forbidden)}
    end
  end

  defp build_vault_rotation_plan(state, session, request) do
    with :ok <-
           verify_rotation_wrapper(
             state.adapters.key_wrapper,
             request.vault_kek,
             request.current_vault_wrapper.wrapped_key,
             %{
               purpose: :vault_key,
               generation: request.current_vault_wrapper.generation,
               aad: request.vault_id
             },
             session.vault_key
           ),
         true <- session_domain_listed?(session, request.active_domain_versions),
         {:ok, domain_keys} <-
           unwrap_active_domain_versions(
             state.adapters.key_wrapper,
             session,
             request.active_domain_versions
           ) do
      result =
        prepare_vault_rotation_wrappers(
          state,
          session,
          request,
          domain_keys
        )

      overwrite_rotation_entries(domain_keys)
      result
    else
      false -> {:error, Error.new(:integrity_failure)}
      {:error, %Error{}} = error -> error
    end
  end

  defp session_domain_listed?(
         %{
           key_domain_id: key_domain_id,
           domain_key_version_id: domain_key_version_id,
           domain_key_generation: generation
         },
         versions
       )
       when is_binary(key_domain_id) and is_binary(domain_key_version_id) and
              is_integer(generation) do
    Enum.any?(versions, fn version ->
      version.key_domain_id == key_domain_id and
        version.id == domain_key_version_id and
        version.generation == generation
    end)
  end

  defp session_domain_listed?(_session, _versions), do: false

  defp unwrap_active_domain_versions(wrapper, session, versions),
    do: unwrap_active_domain_versions(wrapper, session, versions, [])

  defp unwrap_active_domain_versions(_wrapper, _session, [], entries),
    do: {:ok, Enum.reverse(entries)}

  defp unwrap_active_domain_versions(
         wrapper,
         session,
         [version | remaining],
         entries
       ) do
    metadata = %{
      purpose: :domain_key,
      generation: version.generation,
      aad: session.vault_id <> ":" <> version.key_domain_id
    }

    case unwrap_rotation_key(
           wrapper,
           session.vault_key,
           version.wrapped_key,
           metadata
         ) do
      {:ok, domain_key} ->
        if retained_domain_matches?(session, version, domain_key) do
          unwrap_active_domain_versions(
            wrapper,
            session,
            remaining,
            [%{key: domain_key, version: version} | entries]
          )
        else
          _ = overwrite(domain_key)
          overwrite_rotation_entries(entries)
          {:error, Error.new(:integrity_failure)}
        end

      {:error, %Error{}} = error ->
        overwrite_rotation_entries(entries)
        error
    end
  end

  defp retained_domain_matches?(
         %{
           key_domain_id: key_domain_id,
           domain_key_version_id: domain_key_version_id,
           domain_key: retained
         },
         %{key_domain_id: key_domain_id, id: domain_key_version_id},
         unwrapped
       ),
       do: secure_rotation_key_equal?(retained, unwrapped)

  defp retained_domain_matches?(_session, _version, _unwrapped), do: true

  defp prepare_vault_rotation_wrappers(state, session, request, domain_keys) do
    case rotation_random_key(state.adapters.random_bytes) do
      {:ok, new_vault_key} ->
        result =
          if secure_rotation_key_equal?(new_vault_key, session.vault_key) do
            {:error, Error.new(:integrity_failure)}
          else
            vault_rotation_wrappers(
              state.adapters.key_wrapper,
              session,
              request,
              domain_keys,
              new_vault_key
            )
          end

        _ = overwrite(new_vault_key)
        result

      {:error, %Error{}} = error ->
        error
    end
  end

  defp vault_rotation_wrappers(
         wrapper,
         session,
         request,
         domain_keys,
         new_vault_key
       ) do
    vault_metadata = %{
      purpose: :vault_key,
      generation: request.next_vault_wrapper_generation,
      aad: request.vault_id
    }

    with {:ok, wrapped_vault_key} <-
           wrap_and_verify_rotation_key(
             wrapper,
             request.vault_kek,
             new_vault_key,
             vault_metadata
           ),
         {:ok, domain_versions} <-
           rewrap_active_domain_versions(
             wrapper,
             new_vault_key,
             session.vault_id,
             domain_keys
           ) do
      {:ok,
       %{
         next_vault_key_version_id: request.next_vault_key_version_id,
         next_vault_key_version_generation: request.next_vault_key_version_generation,
         next_vault_wrapper_generation: request.next_vault_wrapper_generation,
         vault_wrapper: %{
           generation: request.next_vault_wrapper_generation,
           algorithm: @rotation_algorithm,
           wrapped_key: wrapped_vault_key
         },
         domain_versions: domain_versions
       }}
    end
  end

  defp rewrap_active_domain_versions(
         wrapper,
         new_vault_key,
         vault_id,
         domain_keys
       ) do
    Enum.reduce_while(domain_keys, {:ok, []}, fn entry, {:ok, wrapped} ->
      version = entry.version

      metadata = %{
        purpose: :domain_key,
        generation: version.generation,
        aad: vault_id <> ":" <> version.key_domain_id
      }

      case wrap_and_verify_rotation_key(
             wrapper,
             new_vault_key,
             entry.key,
             metadata
           ) do
        {:ok, wrapped_key} ->
          prepared = %{
            id: version.id,
            key_domain_id: version.key_domain_id,
            generation: version.generation,
            algorithm: @rotation_algorithm,
            expected_wrapped_key: version.wrapped_key,
            wrapped_key: wrapped_key
          }

          {:cont, {:ok, [prepared | wrapped]}}

        {:error, %Error{}} = error ->
          {:halt, error}
      end
    end)
    |> reverse_rotation_result()
  end

  defp build_domain_rotation_plan(state, session, request) do
    domain_metadata = %{
      purpose: :domain_key,
      generation: request.current_domain_wrapper.generation,
      aad: request.vault_id <> ":" <> request.key_domain_id
    }

    dedup_metadata = %{
      purpose: :domain_dedup_key,
      generation: request.current_domain_wrapper.generation,
      aad: request.key_domain_id
    }

    with :ok <-
           verify_rotation_wrapper(
             state.adapters.key_wrapper,
             session.vault_key,
             request.current_domain_wrapper.wrapped_key,
             domain_metadata,
             session.domain_key
           ),
         :ok <-
           verify_rotation_wrapper(
             state.adapters.key_wrapper,
             session.domain_key,
             request.current_dedup_wrapper.wrapped_key,
             dedup_metadata,
             session.domain_dedup_key
           ),
         {:ok, object_keys} <-
           unwrap_active_asset_envelopes(
             state.adapters.key_wrapper,
             session,
             request.active_asset_envelopes
           ) do
      result =
        prepare_domain_rotation_wrappers(
          state,
          session,
          request,
          object_keys
        )

      overwrite_rotation_entries(object_keys)
      result
    end
  end

  defp unwrap_active_asset_envelopes(wrapper, session, envelopes),
    do: unwrap_active_asset_envelopes(wrapper, session, envelopes, [])

  defp unwrap_active_asset_envelopes(_wrapper, _session, [], entries),
    do: {:ok, Enum.reverse(entries)}

  defp unwrap_active_asset_envelopes(
         wrapper,
         session,
         [envelope | remaining],
         entries
       ) do
    metadata = %{
      purpose: :object_dek,
      generation: envelope.key_generation,
      aad: "object:" <> envelope.asset_object_id
    }

    case unwrap_rotation_key(
           wrapper,
           session.domain_key,
           envelope.wrapped_dek,
           metadata
         ) do
      {:ok, object_dek} ->
        if cached_object_key_matches?(session, envelope, object_dek) do
          unwrap_active_asset_envelopes(
            wrapper,
            session,
            remaining,
            [%{envelope: envelope, key: object_dek} | entries]
          )
        else
          _ = overwrite(object_dek)
          overwrite_rotation_entries(entries)
          {:error, Error.new(:integrity_failure)}
        end

      {:error, %Error{}} = error ->
        overwrite_rotation_entries(entries)
        error
    end
  end

  defp cached_object_key_matches?(session, envelope, object_dek) do
    case Map.fetch(
           Map.get(session, :object_keys, %{}),
           {envelope.asset_object_id, envelope.key_generation}
         ) do
      {:ok, retained} -> secure_rotation_key_equal?(retained, object_dek)
      :error -> true
    end
  end

  defp prepare_domain_rotation_wrappers(state, session, request, object_keys) do
    case rotation_random_key(state.adapters.random_bytes) do
      {:ok, new_domain_key} ->
        result =
          if secure_rotation_key_equal?(new_domain_key, session.domain_key) do
            {:error, Error.new(:integrity_failure)}
          else
            domain_rotation_wrappers(
              state.adapters.key_wrapper,
              session,
              request,
              object_keys,
              new_domain_key
            )
          end

        _ = overwrite(new_domain_key)
        result

      {:error, %Error{}} = error ->
        error
    end
  end

  defp domain_rotation_wrappers(
         wrapper,
         session,
         request,
         object_keys,
         new_domain_key
       ) do
    generation = request.next_domain_key_generation

    with {:ok, wrapped_domain_key} <-
           wrap_and_verify_rotation_key(
             wrapper,
             session.vault_key,
             new_domain_key,
             %{
               purpose: :domain_key,
               generation: generation,
               aad: request.vault_id <> ":" <> request.key_domain_id
             }
           ),
         {:ok, wrapped_dedup_key} <-
           wrap_and_verify_rotation_key(
             wrapper,
             new_domain_key,
             session.domain_dedup_key,
             %{
               purpose: :domain_dedup_key,
               generation: generation,
               aad: request.key_domain_id
             }
           ),
         {:ok, asset_envelopes} <-
           rewrap_active_asset_envelopes(
             wrapper,
             new_domain_key,
             generation,
             object_keys
           ) do
      {:ok,
       %{
         next_domain_key_version_id: request.next_domain_key_version_id,
         next_domain_key_generation: generation,
         domain_wrapper: %{
           vault_key_version_id: request.current_domain_wrapper.vault_key_version_id,
           algorithm: @rotation_algorithm,
           wrapped_key: wrapped_domain_key
         },
         dedup_wrapper: %{
           algorithm: @rotation_algorithm,
           wrapped_key: wrapped_dedup_key
         },
         asset_envelopes: asset_envelopes
       }}
    end
  end

  defp rewrap_active_asset_envelopes(
         wrapper,
         new_domain_key,
         generation,
         object_keys
       ) do
    Enum.reduce_while(object_keys, {:ok, []}, fn entry, {:ok, wrapped} ->
      envelope = entry.envelope

      metadata = %{
        purpose: :object_dek,
        generation: generation,
        aad: "object:" <> envelope.asset_object_id
      }

      case wrap_and_verify_rotation_key(
             wrapper,
             new_domain_key,
             entry.key,
             metadata
           ) do
        {:ok, wrapped_dek} ->
          prepared = %{
            expected_envelope_id: envelope.id,
            asset_object_id: envelope.asset_object_id,
            expected_key_generation: envelope.key_generation,
            classification: envelope.classification,
            algorithm: @rotation_algorithm,
            key_generation: generation,
            wrapped_dek: wrapped_dek
          }

          {:cont, {:ok, [prepared | wrapped]}}

        {:error, %Error{}} = error ->
          {:halt, error}
      end
    end)
    |> reverse_rotation_result()
  end

  defp reverse_rotation_result({:ok, entries}),
    do: {:ok, Enum.reverse(entries)}

  defp reverse_rotation_result({:error, %Error{}} = error), do: error

  defp verify_rotation_wrapper(
         wrapper,
         wrapping_key,
         encoded,
         metadata,
         expected_key
       ) do
    case unwrap_rotation_key(wrapper, wrapping_key, encoded, metadata) do
      {:ok, unwrapped} ->
        matches? = secure_rotation_key_equal?(unwrapped, expected_key)
        _ = overwrite(unwrapped)

        if matches?,
          do: :ok,
          else: {:error, Error.new(:integrity_failure)}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp wrap_and_verify_rotation_key(
         wrapper,
         wrapping_key,
         raw_key,
         metadata
       ) do
    with {:ok, wrapped} <-
           safe_rotation_adapter_call(wrapper, :wrap, [
             wrapping_key,
             raw_key,
             metadata
           ]),
         %{
           algorithm: :aes_256_gcm,
           encoded: encoded,
           generation: generation,
           purpose: purpose
         } <- wrapped,
         true <- generation == metadata.generation,
         true <- purpose == metadata.purpose,
         true <- valid_rotation_wrapper?(encoded),
         :ok <-
           verify_rotation_wrapper(
             wrapper,
             wrapping_key,
             encoded,
             metadata,
             raw_key
           ) do
      {:ok, encoded}
    else
      _invalid -> {:error, Error.new(:integrity_failure)}
    end
  end

  defp unwrap_rotation_key(wrapper, wrapping_key, encoded, metadata) do
    with {:ok, unwrapped} <-
           safe_rotation_adapter_call(wrapper, :unwrap, [
             wrapping_key,
             encoded,
             metadata
           ]),
         <<_::binary-size(32)>> <- unwrapped do
      {:ok, unwrapped}
    else
      _invalid -> {:error, Error.new(:integrity_failure)}
    end
  end

  defp safe_rotation_adapter_call(adapter, function, arguments) do
    call_adapter(adapter, function, arguments)
  rescue
    _error -> {:error, Error.new(:integrity_failure)}
  catch
    _kind, _reason -> {:error, Error.new(:integrity_failure)}
  end

  defp rotation_random_key(random_bytes) when is_function(random_bytes, 1) do
    case random_bytes.(32) do
      <<_::binary-size(32)>> = key -> {:ok, key}
      _invalid -> {:error, Error.new(:integrity_failure)}
    end
  rescue
    _error -> {:error, Error.new(:integrity_failure)}
  catch
    _kind, _reason -> {:error, Error.new(:integrity_failure)}
  end

  defp rotation_random_key(_random_bytes),
    do: {:error, Error.new(:integrity_failure)}

  defp secure_rotation_key_equal?(
         <<_::binary-size(32)>> = left,
         <<_::binary-size(32)>> = right
       ),
       do: :crypto.hash_equals(left, right)

  defp secure_rotation_key_equal?(_left, _right), do: false

  defp overwrite_rotation_entries(entries) do
    Enum.each(entries, fn
      %{key: key} -> overwrite(key)
      _invalid -> :ok
    end)
  end

  defp validate_session(
         %{
           session_id: session_id,
           principal_id: principal_id,
           vault_id: vault_id,
           principal_authorization_epoch: principal_authorization_epoch,
           vault_authorization_epoch: vault_authorization_epoch,
           vault_key: <<_::binary-size(32)>>
         } = session
       )
       when is_binary(session_id) and byte_size(session_id) > 0 and
              is_binary(principal_id) and byte_size(principal_id) > 0 and
              is_binary(vault_id) and byte_size(vault_id) > 0 and
              is_integer(principal_authorization_epoch) and
              principal_authorization_epoch >= 0 and
              is_integer(vault_authorization_epoch) and
              vault_authorization_epoch >= 0,
       do: validate_optional_keys(session)

  defp validate_session(_session), do: {:error, Error.new(:invalid)}

  defp validate_optional_keys(session) do
    with true <- optional_key?(Map.get(session, :domain_key)),
         true <- optional_key?(Map.get(session, :domain_dedup_key)),
         true <- valid_domain_binding?(session),
         true <- valid_object_keys?(Map.get(session, :object_keys, %{})) do
      :ok
    else
      false -> {:error, Error.new(:invalid)}
    end
  end

  defp optional_key?(nil), do: true
  defp optional_key?(<<_::binary-size(32)>>), do: true
  defp optional_key?(_key), do: false

  defp valid_domain_binding?(
         %{
           domain_key: <<_::binary-size(32)>>,
           domain_dedup_key: <<_::binary-size(32)>>
         } = session
       ) do
    nonempty_binary?(Map.get(session, :key_domain_id)) and
      nonempty_binary?(Map.get(session, :domain_key_version_id)) and
      is_integer(Map.get(session, :domain_key_generation)) and
      Map.get(session, :domain_key_generation) > 0 and
      Map.get(session, :domain_classification) in [
        :private,
        :sensitive,
        :restricted
      ]
  end

  defp valid_domain_binding?(session) do
    is_nil(Map.get(session, :domain_key)) and
      is_nil(Map.get(session, :domain_dedup_key)) and
      is_nil(Map.get(session, :key_domain_id)) and
      is_nil(Map.get(session, :domain_key_version_id)) and
      is_nil(Map.get(session, :domain_key_generation)) and
      is_nil(Map.get(session, :domain_classification))
  end

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
         true <- not Map.has_key?(request, :authorization_epoch),
         true <- not Map.has_key?(request, "authorization_epoch"),
         true <- nonempty_binary?(request.job_id),
         true <- nonempty_binary?(request.vault_id),
         true <- nonempty_binary?(request.principal_id),
         true <- nonempty_binary?(request.required_capability),
         true <- nonempty_binary?(request.object_id),
         true <- nonempty_binary?(request.session_id),
         true <-
           is_integer(request.principal_authorization_epoch) and
             request.principal_authorization_epoch >= 0,
         true <-
           is_integer(request.vault_authorization_epoch) and
             request.vault_authorization_epoch >= 0,
         true <- is_integer(request.object_generation) and request.object_generation > 0 do
      :ok
    else
      false -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_request(_request), do: {:error, Error.new(:invalid)}

  defp validate_metadata_request(%{purpose: :metadata} = request) do
    with true <- Enum.all?(@metadata_request_fields, &Map.has_key?(request, &1)),
         true <- Enum.sort(Map.keys(request)) == Enum.sort([:purpose | @metadata_request_fields]),
         false <- Map.has_key?(request, :session_id),
         false <- Map.has_key?(request, "session_id"),
         false <- Map.has_key?(request, :authorization_epoch),
         false <- Map.has_key?(request, "authorization_epoch"),
         true <- nonempty_binary?(request.job_id),
         true <- nonempty_binary?(request.vault_id),
         true <- nonempty_binary?(request.principal_id),
         true <- request.required_capability == "asset.read",
         true <- nonempty_binary?(request.object_id),
         true <- nonempty_binary?(request.declared_media_type),
         true <-
           is_integer(request.principal_authorization_epoch) and
             request.principal_authorization_epoch >= 0,
         true <-
           is_integer(request.vault_authorization_epoch) and
             request.vault_authorization_epoch >= 0,
         true <- is_integer(request.object_generation) and request.object_generation > 0,
         true <- is_integer(request.processing_revision) and request.processing_revision > 0,
         true <- is_integer(request.plaintext_byte_size) and request.plaintext_byte_size >= 0 do
      :ok
    else
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_metadata_request(_request), do: {:error, Error.new(:invalid)}

  defp validate_download_request(request) do
    with :ok <- validate_request(request),
         true <- request.required_capability == "asset.read",
         true <- request.purpose == :download do
      :ok
    else
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_upload_request(request) when is_map(request) do
    with true <- Enum.all?(@upload_request_fields, &Map.has_key?(request, &1)),
         true <- request.classification in [:private, :sensitive, :restricted],
         true <-
           is_integer(request.principal_authorization_epoch) and
             request.principal_authorization_epoch >= 0,
         true <-
           is_integer(request.vault_authorization_epoch) and
             request.vault_authorization_epoch >= 0,
         true <-
           Enum.all?(
             [:grant_id, :asset_id, :session_id, :principal_id, :vault_id],
             &valid_uuid?(Map.get(request, &1))
           ),
         false <- Map.has_key?(request, :object_dek),
         false <- Map.has_key?(request, :domain_dedup_key) do
      :ok
    else
      _invalid -> {:error, Error.new(:invalid)}
    end
  end

  defp validate_upload_request(_request), do: {:error, Error.new(:invalid)}

  defp nonempty_binary?(value),
    do: is_binary(value) and byte_size(String.trim(value)) > 0

  defp best_effort_overwrite(session) do
    for field <- [:vault_key, :domain_key, :domain_dedup_key] do
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

  defp overwrite(secret) when is_binary(secret),
    do: :binary.copy(<<0>>, byte_size(secret))

  defp overwrite(_secret), do: nil

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
    |> discard_uploads_for_session(session_id)
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
      :vault_key,
      :domain_key,
      :domain_dedup_key,
      :key_domain_id,
      :domain_key_version_id,
      :domain_key_generation,
      :domain_classification,
      :object_keys
    ])
  end

  defp active_session?(state, session_id), do: Map.has_key?(state.sessions, session_id)

  defp metadata_session(state, request) do
    now = state.adapters.clock.utc_now(state.context)

    state.sessions
    |> Enum.sort_by(fn {session_id, _session} -> session_id end)
    |> Enum.find_value(fn {_session_id, session} ->
      if metadata_session_matches?(state, session, request, now),
        do: session,
        else: nil
    end)
  end

  defp metadata_session_matches?(
         state,
         %{
           principal_id: principal_id,
           vault_id: vault_id,
           principal_authorization_epoch: principal_authorization_epoch,
           vault_authorization_epoch: vault_authorization_epoch,
           expires_at: %DateTime{} = expires_at
         } = session,
         %{
           principal_id: principal_id,
           vault_id: vault_id,
           principal_authorization_epoch: principal_authorization_epoch,
           vault_authorization_epoch: vault_authorization_epoch
         },
         %DateTime{} = now
       ) do
    DateTime.compare(now, expires_at) == :lt and
      not matching_revocation?(state, session)
  end

  defp metadata_session_matches?(_state, _session, _request, _now), do: false

  defp matching_revocation?(state, session) do
    Enum.any?(state.revoking, fn {_token, selector} ->
      matches_selector?(session, selector)
    end)
  end

  defp begin_revocation(state, selector, token) do
    session_ids = matching_session_ids(state, selector)

    state =
      Enum.reduce(session_ids, state, fn session_id, current ->
        revoke_session_custody(current, session_id)
      end)

    state =
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

    state =
      Enum.reduce(Map.keys(state.upload_materials), state, fn material_ref, current ->
        case Map.get(current.upload_materials, material_ref) do
          %{binding: binding} ->
            if matches_selector?(binding, selector) do
              discard_upload_material(current, material_ref)
            else
              current
            end

          nil ->
            current
        end
      end)

    start_upload_revocations(state, selector, token)
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

    uploads =
      state.uploads
      |> Map.values()
      |> Enum.map(& &1.binding)
      |> Enum.filter(&matches_selector?(&1, selector))
      |> Enum.map(& &1.session_id)

    MapSet.new(active ++ pending ++ uploads)
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
      end) or
      Enum.any?(state.uploads, fn {_upload, entry} ->
        matches_selector?(entry.binding, selector)
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

  defp validate_backup_prepared(%{
         binding: %{manifest_id: manifest_id, vault_id: vault_id} = binding,
         key_material: <<_::binary-size(32)>> = key_material,
         opaque_ref: opaque_ref,
         public_metadata:
           %{
             "kdf" => kdf,
             "recovery" => %{
               "binding" => %{
                 "manifest_id" => manifest_id,
                 "vault_id" => vault_id
               },
               "label" => "backup_recovery",
               "wrapper" => recovery_wrapper
             }
           } = public_metadata
       })
       when is_binary(manifest_id) and manifest_id != "" and is_binary(vault_id) and
              vault_id != "" and is_binary(opaque_ref) and opaque_ref != "" and is_map(kdf) and
              is_binary(recovery_wrapper) and recovery_wrapper != "" do
    if Map.keys(binding) |> Enum.sort() == [:manifest_id, :vault_id] do
      {:ok, opaque_ref,
       %{
         binding: binding,
         key_material: key_material,
         public_metadata: public_metadata,
         recovery_wrapper: recovery_wrapper
       }}
    else
      {:error, Error.new(:backup_invalid)}
    end
  end

  defp validate_backup_prepared(_prepared),
    do: {:error, Error.new(:backup_invalid)}

  defp prepare_session_backup(
         state,
         session,
         %BackupKeyLease.Derived{
           binding: binding,
           key_material: <<_::binary-size(32)>> = key_material,
           public_metadata: public_metadata
         }
       ) do
    with {:ok, custody} <- validate_backup_session(state, session, binding),
         :ok <- validate_derived_public_metadata(public_metadata, binding),
         {:ok, recovery_wrapper} <-
           call_adapter(state.adapters.backup_recovery_wrapper, :wrap, [
             key_material,
             custody.vault_key,
             %{
               label: :backup_recovery,
               manifest_id: binding.manifest_id,
               vault_id: binding.vault_id
             }
           ]),
         true <- is_binary(recovery_wrapper) and recovery_wrapper != "",
         {:ok, opaque_ref} <- backup_opaque_ref(state.adapters.random_bytes) do
      public_metadata =
        put_in(public_metadata, ["recovery", "wrapper"], recovery_wrapper)

      entry = %{
        binding: %{manifest_id: binding.manifest_id, vault_id: binding.vault_id},
        key_material: key_material,
        public_metadata: public_metadata,
        recovery_wrapper: recovery_wrapper
      }

      prepared = %BackupKeyLease.Prepared{
        opaque_ref: opaque_ref,
        public_metadata: public_metadata
      }

      {:ok, opaque_ref, entry, prepared}
    else
      _invalid -> {:error, Error.new(:backup_invalid)}
    end
  rescue
    _exception -> {:error, Error.new(:backup_invalid)}
  catch
    _kind, _reason -> {:error, Error.new(:backup_invalid)}
  end

  defp prepare_session_backup(_state, _session, _derived),
    do: {:error, Error.new(:backup_invalid)}

  defp validate_backup_session(
         state,
         session,
         %{
           expires_at: %DateTime{} = expires_at,
           manifest_id: manifest_id,
           principal_authorization_epoch: principal_authorization_epoch,
           principal_id: principal_id,
           session_id: session_id,
           vault_authorization_epoch: vault_authorization_epoch,
           vault_id: vault_id
         } = binding
       )
       when is_map(session) and is_binary(manifest_id) and manifest_id != "" and
              is_binary(session_id) and session_id != "" and is_binary(principal_id) and
              principal_id != "" and is_binary(vault_id) and vault_id != "" and
              is_integer(principal_authorization_epoch) and principal_authorization_epoch >= 0 and
              is_integer(vault_authorization_epoch) and vault_authorization_epoch >= 0 do
    now = state.adapters.clock.utc_now(state.context)
    custody = Map.get(state.sessions, session_id)

    with true <- Map.keys(binding) |> Enum.sort() == Enum.sort(@backup_binding_fields),
         true <- backup_session_matches?(session, binding),
         true <- backup_session_matches?(custody, binding),
         %{vault_key: <<_::binary-size(32)>>} <- custody,
         %DateTime{} <- now,
         :lt <- DateTime.compare(now, expires_at),
         false <- matching_revocation?(state, custody) do
      {:ok, custody}
    else
      _invalid -> {:error, Error.new(:backup_invalid)}
    end
  end

  defp validate_backup_session(_state, _session, _binding),
    do: {:error, Error.new(:backup_invalid)}

  defp backup_session_matches?(session, binding) when is_map(session) do
    Enum.all?(
      [
        :expires_at,
        :principal_authorization_epoch,
        :principal_id,
        :session_id,
        :vault_authorization_epoch,
        :vault_id
      ],
      &(Map.get(session, &1) == Map.get(binding, &1))
    )
  end

  defp backup_session_matches?(_session, _binding), do: false

  defp validate_derived_public_metadata(
         %{
           "kdf" =>
             %{
               "domain" => domain,
               "parameters" => parameters,
               "salt" => encoded_salt
             } = kdf,
           "recovery" =>
             %{
               "binding" =>
                 %{
                   "manifest_id" => manifest_id,
                   "vault_id" => vault_id
                 } = recovery_binding,
               "label" => "backup_recovery",
               "wrapper" => nil
             } = recovery
         } = public_metadata,
         %{manifest_id: manifest_id, vault_id: vault_id}
       )
       when is_binary(domain) and domain != "" and is_map(parameters) and
              is_binary(encoded_salt) do
    with true <- Map.keys(public_metadata) |> Enum.sort() == ["kdf", "recovery"],
         true <- Map.keys(kdf) |> Enum.sort() == ["domain", "parameters", "salt"],
         true <-
           Map.keys(recovery) |> Enum.sort() == ["binding", "label", "wrapper"],
         true <- Map.keys(recovery_binding) |> Enum.sort() == ["manifest_id", "vault_id"],
         {:ok, salt} <- Base.decode64(encoded_salt),
         true <- byte_size(salt) == 16 do
      :ok
    else
      _invalid -> {:error, Error.new(:backup_invalid)}
    end
  end

  defp validate_derived_public_metadata(_public_metadata, _binding),
    do: {:error, Error.new(:backup_invalid)}

  defp backup_opaque_ref(random_bytes) when is_function(random_bytes, 1) do
    case random_bytes.(32) do
      <<_::binary-size(32)>> = bytes -> {:ok, Base.url_encode64(bytes, padding: false)}
      _invalid -> {:error, Error.new(:backup_invalid)}
    end
  rescue
    _exception -> {:error, Error.new(:backup_invalid)}
  catch
    _kind, _reason -> {:error, Error.new(:backup_invalid)}
  end

  defp backup_opaque_ref(_random_bytes), do: {:error, Error.new(:backup_invalid)}

  defp install_backup_pending(state, owner, opaque_ref, entry, reply) do
    if Map.has_key?(state.backup_pending, opaque_ref) or
         Map.has_key?(state.backup_active, opaque_ref) do
      _cleared = overwrite(entry.key_material)
      {:reply, {:error, Error.new(:conflict)}, state}
    else
      monitor = Process.monitor(owner)

      timer =
        Process.send_after(
          self(),
          {:expire_pending, opaque_ref},
          state.backup_pending_ttl_ms
        )

      pending_entry =
        entry
        |> Map.put(:monitor, monitor)
        |> Map.put(:owner, owner)
        |> Map.put(:timer, timer)

      next_state =
        state
        |> put_in([:backup_pending, opaque_ref], pending_entry)
        |> put_in([:backup_pending_monitors, monitor], opaque_ref)

      notify_backup_prepared(state.adapters.backup_key_observer, opaque_ref)
      {:reply, reply, next_state}
    end
  end

  defp backup_public_header(entry) do
    %{
      version: 1,
      manifest_id: entry.binding.manifest_id,
      vault_id: entry.binding.vault_id,
      kdf: entry.public_metadata["kdf"]
    }
  end

  defp start_backup_lease(state, entry) do
    DynamicSupervisor.start_child(
      state.lease_supervisor,
      {BackupKeyLease,
       %{
         active_ttl_ms: state.backup_active_ttl_ms,
         binding: entry.binding,
         cipher: state.adapters.backup_cipher,
         custodian: self(),
         key_material: entry.key_material,
         public_header: backup_public_header(entry),
         recovery_wrapper: entry.recovery_wrapper
       }}
    )
  rescue
    _exception -> {:error, :lease_unavailable}
  catch
    :exit, _reason -> {:error, :lease_unavailable}
  end

  defp notify_backup_prepared(nil, _opaque_ref), do: :ok

  defp notify_backup_prepared(observer, opaque_ref) do
    _result = call_adapter(observer, :pending_prepared, [opaque_ref])
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp handle_backup_down(state, monitor, process) do
    case Map.pop(state.backup_pending_monitors, monitor) do
      {opaque_ref, monitors} when is_binary(opaque_ref) ->
        next_state =
          state
          |> Map.put(:backup_pending_monitors, monitors)
          |> remove_backup_pending(opaque_ref, true, false)

        {:handled, next_state}

      {nil, _monitors} ->
        case Map.pop(state.backup_active_monitors, monitor) do
          {{opaque_ref, ^process}, monitors} ->
            {:handled,
             %{
               state
               | backup_active: Map.delete(state.backup_active, opaque_ref),
                 backup_active_monitors: monitors
             }}

          {nil, _monitors} ->
            :unhandled
        end
    end
  end

  defp remove_backup_pending(state, opaque_ref, clear? \\ true, demonitor? \\ true) do
    case Map.pop(state.backup_pending, opaque_ref) do
      {nil, _pending} ->
        state

      {%{key_material: key_material, monitor: monitor, timer: timer}, pending} ->
        Process.cancel_timer(timer)

        if demonitor? do
          Process.demonitor(monitor, [:flush])
        end

        if clear? do
          _cleared = overwrite(key_material)
        end

        %{
          state
          | backup_pending: pending,
            backup_pending_monitors: Map.delete(state.backup_pending_monitors, monitor)
        }
    end
  end

  defp revoke_backup_active(state, opaque_ref) do
    case Map.pop(state.backup_active, opaque_ref) do
      {nil, _active} ->
        state

      {%{lease: lease, monitor: monitor}, active} ->
        Process.demonitor(monitor, [:flush])
        _revoked = BackupKeyLease.revoke(lease)

        %{
          state
          | backup_active: active,
            backup_active_monitors: Map.delete(state.backup_active_monitors, monitor)
        }
    end
  end

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

  defp discard_uploads_for_session(state, session_id) do
    Enum.reduce(Map.keys(state.upload_materials), state, fn material_ref, current ->
      case Map.get(current.upload_materials, material_ref) do
        %{binding: %{session_id: ^session_id}} ->
          discard_upload_material(current, material_ref)

        _other ->
          current
      end
    end)
  end

  defp discard_upload_material(state, material_ref) do
    case Map.pop(state.upload_materials, material_ref) do
      {nil, _materials} ->
        state

      {entry, materials} ->
        Process.cancel_timer(entry.timer)
        _ = overwrite(entry.object_dek)
        _ = overwrite(entry.domain_dedup_key)
        %{state | upload_materials: materials}
    end
  end

  defp register_upload(
         state,
         upload,
         binding,
         recovery,
         custody_ref
       )
       when is_pid(upload) and is_reference(custody_ref) do
    monitor = Process.monitor(upload)

    state
    |> put_in(
      [:uploads, upload],
      %{
        binding: binding,
        custody_ref: custody_ref,
        monitor: monitor,
        recovery: recovery,
        revocation_ref: nil,
        worker: nil,
        worker_monitor: nil
      }
    )
    |> put_in([:upload_monitors, monitor], {:owner, upload})
    |> touch_session(binding.session_id)
  end

  defp start_upload_revocations(state, selector, token) do
    Enum.reduce(
      Map.keys(state.uploads),
      {state, MapSet.new()},
      fn upload, {current, pending} ->
        case Map.get(current.uploads, upload) do
          %{binding: binding} = entry ->
            if matches_selector?(binding, selector) do
              start_or_join_upload_revocation(
                current,
                pending,
                upload,
                entry,
                token
              )
            else
              {current, pending}
            end

          nil ->
            {current, pending}
        end
      end
    )
  end

  defp start_or_join_upload_revocation(
         state,
         pending,
         _upload,
         %{revocation_ref: revocation_ref},
         token
       )
       when is_reference(revocation_ref) do
    case Map.get(state.upload_revocations, revocation_ref) do
      %{tokens: tokens} = revocation ->
        next_state =
          put_in(
            state,
            [:upload_revocations, revocation_ref],
            %{revocation | tokens: MapSet.put(tokens, token)}
          )

        {next_state, MapSet.put(pending, revocation_ref)}

      nil ->
        {state, pending}
    end
  end

  defp start_or_join_upload_revocation(
         state,
         pending,
         upload,
         entry,
         token
       ) do
    revocation_ref = make_ref()
    timer_tag = make_ref()

    timer =
      Process.send_after(
        self(),
        {:upload_revocation_timeout, revocation_ref, timer_tag},
        state.upload_revoke_timeout_ms
      )

    revocation = %{
      custody_ref: entry.custody_ref,
      fallback?: false,
      recovery: entry.recovery,
      recovery_task: nil,
      reason: :custody_revoked,
      result: :pending,
      timer: {timer, timer_tag, :cooperative},
      tokens: MapSet.new([token]),
      upload: upload,
      upload_down?: false,
      worker: entry.worker,
      worker_down?: is_nil(entry.worker)
    }

    send(
      upload,
      {:custody_revoke, entry.custody_ref, revocation_ref, self()}
    )

    next_state =
      state
      |> put_in(
        [:uploads, upload],
        %{entry | revocation_ref: revocation_ref}
      )
      |> put_in(
        [:upload_revocations, revocation_ref],
        revocation
      )

    {next_state, MapSet.put(pending, revocation_ref)}
  end

  defp update_revocation_worker(state, upload, worker) do
    case get_in(state, [:uploads, upload, :revocation_ref]) do
      revocation_ref when is_reference(revocation_ref) ->
        case Map.get(state.upload_revocations, revocation_ref) do
          nil ->
            state

          revocation ->
            put_in(
              state,
              [:upload_revocations, revocation_ref],
              %{
                revocation
                | worker: worker,
                  worker_down?: false
              }
            )
        end

      _not_revoking ->
        state
    end
  end

  defp handle_upload_revocation_timeout(state, revocation_ref, tag) do
    case Map.get(state.upload_revocations, revocation_ref) do
      %{timer: {_timer, ^tag, :cooperative}} = revocation ->
        state
        |> put_in(
          [:upload_revocations, revocation_ref],
          %{
            revocation
            | fallback?: true,
              result: :pending,
              timer: nil
          }
        )
        |> kill_revocation_processes(revocation)
        |> maybe_start_upload_recovery(revocation_ref)

      %{timer: {_timer, ^tag, :retry}} = revocation ->
        state
        |> put_in(
          [:upload_revocations, revocation_ref],
          %{revocation | result: :pending, timer: nil}
        )
        |> maybe_start_upload_recovery(revocation_ref)

      _stale ->
        state
    end
  end

  defp record_terminal_upload(state, revocation_ref, :sealed) do
    case Map.get(state.upload_revocations, revocation_ref) do
      nil ->
        state

      revocation ->
        cancel_revocation_timer(revocation.timer)

        put_in(
          state,
          [:upload_revocations, revocation_ref],
          %{
            revocation
            | fallback?: false,
              result: :ok,
              timer: nil
          }
        )
    end
  end

  defp record_terminal_upload(state, revocation_ref, :abandoned) do
    case Map.get(state.upload_revocations, revocation_ref) do
      nil ->
        state

      revocation ->
        cancel_revocation_timer(revocation.timer)

        put_in(
          state,
          [:upload_revocations, revocation_ref],
          %{
            revocation
            | fallback?: true,
              result: :pending,
              timer: nil
          }
        )
    end
  end

  defp kill_revocation_processes(state, revocation) do
    for process <- [revocation.upload, revocation.worker],
        is_pid(process),
        Process.alive?(process) do
      Process.exit(process, :kill)
    end

    state
  end

  defp maybe_start_upload_recovery(state, revocation_ref) do
    case Map.get(state.upload_revocations, revocation_ref) do
      %{
        fallback?: true,
        recovery_task: nil,
        result: :pending,
        upload_down?: true,
        worker_down?: true
      } = revocation ->
        start_upload_recovery_task(
          state,
          revocation_ref,
          revocation
        )

      _not_ready ->
        state
    end
  end

  defp start_upload_recovery_task(
         state,
         revocation_ref,
         revocation
       ) do
    attempt_ref = make_ref()
    custodian = self()
    reconciler = state.upload_reconciler
    context = state.upload_recovery
    recovery = revocation.recovery
    reason = revocation.reason

    task = fn ->
      result =
        try do
          call_adapter(
            reconciler,
            :reconcile_stage,
            [context, recovery, reason]
          )
        rescue
          _error ->
            {:error,
             Error.new(
               :storage_unavailable,
               retryable?: true
             )}
        catch
          _kind, _reason ->
            {:error,
             Error.new(
               :storage_unavailable,
               retryable?: true
             )}
        end

      send(
        custodian,
        {:upload_recovery_result, revocation_ref, attempt_ref, self(), result}
      )
    end

    case start_recovery_child(
           state.upload_recovery_supervisor,
           task
         ) do
      {:ok, task_pid} ->
        monitor = Process.monitor(task_pid)

        timeout =
          Process.send_after(
            self(),
            {:upload_recovery_timeout, revocation_ref, attempt_ref, task_pid},
            state.upload_recovery_timeout_ms
          )

        recovery_task = %{
          attempt_ref: attempt_ref,
          monitor: monitor,
          pid: task_pid,
          result: :pending,
          timeout: timeout
        }

        state
        |> put_in(
          [:upload_revocations, revocation_ref],
          %{
            revocation
            | recovery_task: recovery_task,
              result: :recovering
          }
        )
        |> put_in(
          [:upload_recovery_monitors, monitor],
          {revocation_ref, attempt_ref, task_pid}
        )

      {:error, _reason} ->
        schedule_upload_recovery_retry(state, revocation_ref)
    end
  end

  defp start_recovery_child(supervisor, task)
       when is_function(task, 0) do
    Task.Supervisor.start_child(supervisor, task)
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp record_upload_recovery_result(
         state,
         revocation_ref,
         attempt_ref,
         task,
         result
       ) do
    case Map.get(state.upload_revocations, revocation_ref) do
      %{
        recovery_task:
          %{
            attempt_ref: ^attempt_ref,
            pid: ^task
          } = recovery_task
      } = revocation ->
        Process.cancel_timer(recovery_task.timeout)

        put_in(
          state,
          [:upload_revocations, revocation_ref],
          %{
            revocation
            | recovery_task: %{
                recovery_task
                | result: normalize_revocation_result(result),
                  timeout: nil
              }
          }
        )

      _forged_or_stale ->
        state
    end
  end

  defp timeout_upload_recovery(
         state,
         revocation_ref,
         attempt_ref,
         task
       ) do
    case Map.get(state.upload_revocations, revocation_ref) do
      %{
        recovery_task: %{
          attempt_ref: ^attempt_ref,
          pid: ^task
        }
      } ->
        Process.exit(task, :kill)
        state

      _stale ->
        state
    end
  end

  defp schedule_upload_recovery_retry(state, revocation_ref) do
    case Map.get(state.upload_revocations, revocation_ref) do
      nil ->
        state

      revocation ->
        cancel_revocation_timer(revocation.timer)
        tag = make_ref()

        timer =
          Process.send_after(
            self(),
            {:upload_revocation_timeout, revocation_ref, tag},
            state.upload_revoke_retry_ms
          )

        put_in(
          state,
          [:upload_revocations, revocation_ref],
          %{
            revocation
            | recovery_task: nil,
              result:
                {:error,
                 Error.new(
                   :storage_unavailable,
                   retryable?: true
                 )},
              timer: {timer, tag, :retry}
          }
        )
    end
  end

  defp complete_upload_revocations(state) do
    state.upload_revocations
    |> Enum.filter(fn {_revocation_ref, revocation} ->
      revocation.result == :ok and
        revocation.upload_down? and
        revocation.worker_down? and
        is_nil(revocation.recovery_task)
    end)
    |> Enum.reduce(state, fn {revocation_ref, _revocation}, current ->
      complete_upload_revocation(current, revocation_ref)
    end)
  end

  defp complete_upload_revocation(state, revocation_ref) do
    case Map.pop(state.upload_revocations, revocation_ref) do
      {nil, _revocations} ->
        state

      {revocation, revocations} ->
        cancel_revocation_timer(revocation.timer)

        state =
          state
          |> Map.put(:upload_revocations, revocations)
          |> remove_upload(revocation.upload)

        Enum.reduce(revocation.tokens, state, fn token, current ->
          complete_revocation_waiter(
            current,
            token,
            revocation_ref
          )
        end)
    end
  end

  defp complete_revocation_waiter(state, token, revocation_ref) do
    case Map.get(state.revocation_waiters, token) do
      nil ->
        state

      waiter ->
        pending = MapSet.delete(waiter.pending, revocation_ref)

        next_state =
          put_in(
            state,
            [:revocation_waiters, token],
            %{waiter | pending: pending}
          )

        if MapSet.size(pending) == 0 do
          finish_revocation_waiter(
            next_state,
            token,
            %{waiter | pending: pending}
          )
        else
          next_state
        end
    end
  end

  defp finish_revocation_waiter(
         state,
         token,
         %{
           completion: :begin_revoke,
           from: from
         } = waiter
       ) do
    state = discard_revocation_waiter(state, token, waiter)
    GenServer.reply(from, {:ok, token})
    state
  end

  defp finish_revocation_waiter(
         state,
         token,
         %{completion: :orphaned_begin_revoke} = waiter
       ) do
    state = discard_revocation_waiter(state, token, waiter)
    %{state | revoking: Map.delete(state.revoking, token)}
  end

  defp finish_revocation_waiter(
         state,
         token,
         %{completion: {:idle_lock, _session}}
       ) do
    attempt_idle_lock(state, token)
  end

  defp attempt_idle_lock(state, token) do
    case Map.get(state.revocation_waiters, token) do
      %{
        completion: {:idle_lock, session},
        idle_retry: nil,
        pending: pending
      } ->
        if MapSet.size(pending) == 0 do
          case persist_idle_lock_safely(state, session) do
            :ok ->
              %{
                state
                | revocation_waiters:
                    Map.delete(
                      state.revocation_waiters,
                      token
                    ),
                  revoking:
                    Map.delete(
                      state.revoking,
                      token
                    )
              }

            {:error, %Error{}} ->
              schedule_idle_lock_retry(state, token)
          end
        else
          state
        end

      _missing_or_already_scheduled ->
        state
    end
  end

  defp schedule_idle_lock_retry(state, token) do
    tag = make_ref()

    timer =
      Process.send_after(
        self(),
        {:idle_lock_retry, token, tag},
        state.idle_lock_retry_ms
      )

    put_in(
      state,
      [:revocation_waiters, token, :idle_retry],
      {timer, tag}
    )
  end

  defp persist_idle_lock_safely(state, session) do
    case persist_idle_lock(state, session) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  defp discard_revocation_waiter(state, token, waiter) do
    monitor = Map.get(waiter, :monitor)

    if is_reference(monitor),
      do: Process.demonitor(monitor, [:flush])

    %{
      state
      | revocation_waiters:
          Map.delete(
            state.revocation_waiters,
            token
          ),
        revocation_waiter_monitors:
          Map.delete(
            state.revocation_waiter_monitors,
            monitor
          )
    }
  end

  defp normalize_revocation_result(:ok), do: :ok
  defp normalize_revocation_result({:ok, _stage}), do: :ok

  defp normalize_revocation_result({:error, %Error{}} = error),
    do: error

  defp normalize_revocation_result(_invalid),
    do:
      {:error,
       Error.new(
         :storage_unavailable,
         retryable?: true
       )}

  defp cancel_revocation_timer({timer, _tag, _kind})
       when is_reference(timer),
       do: Process.cancel_timer(timer)

  defp cancel_revocation_timer(_timer), do: false

  defp remove_upload(state, upload) do
    case Map.pop(state.uploads, upload) do
      {nil, _uploads} ->
        state

      {%{
         monitor: monitor,
         worker_monitor: worker_monitor
       }, uploads} ->
        Process.demonitor(monitor, [:flush])

        if is_reference(worker_monitor),
          do: Process.demonitor(worker_monitor, [:flush])

        %{
          state
          | uploads: uploads,
            upload_monitors:
              state.upload_monitors
              |> Map.delete(monitor)
              |> Map.delete(worker_monitor)
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

  defp handle_revocation_waiter_down(state, monitor, _caller) do
    case Map.pop(state.revocation_waiter_monitors, monitor) do
      {token, monitors} when is_reference(token) ->
        state
        |> Map.put(:revocation_waiter_monitors, monitors)
        |> update_in(
          [:revocation_waiters, token],
          fn
            nil ->
              nil

            waiter ->
              %{
                waiter
                | completion: :orphaned_begin_revoke,
                  from: nil,
                  monitor: nil
              }
          end
        )

      {nil, _monitors} ->
        state
    end
  end

  defp handle_upload_recovery_down(
         state,
         monitor,
         task,
         _reason
       ) do
    case Map.pop(state.upload_recovery_monitors, monitor) do
      {{revocation_ref, attempt_ref, ^task}, monitors} ->
        state = Map.put(state, :upload_recovery_monitors, monitors)

        case Map.get(state.upload_revocations, revocation_ref) do
          %{
            recovery_task:
              %{
                attempt_ref: ^attempt_ref,
                pid: ^task
              } = recovery_task
          } = revocation ->
            if is_reference(recovery_task.timeout),
              do: Process.cancel_timer(recovery_task.timeout)

            state =
              put_in(
                state,
                [:upload_revocations, revocation_ref],
                %{revocation | recovery_task: nil}
              )

            case recovery_task.result do
              :ok ->
                put_in(
                  state,
                  [:upload_revocations, revocation_ref, :result],
                  :ok
                )

              {:error, %Error{retryable?: true}} ->
                schedule_upload_recovery_retry(
                  state,
                  revocation_ref
                )

              {:error, %Error{} = error} ->
                fail_upload_revocation(
                  state,
                  revocation_ref,
                  error
                )

              _missing_result ->
                schedule_upload_recovery_retry(
                  state,
                  revocation_ref
                )
            end

          _stale ->
            state
        end

      {nil, _monitors} ->
        state
    end
  end

  defp progress_upload_recoveries(state) do
    Enum.reduce(
      Map.keys(state.upload_revocations),
      state,
      fn revocation_ref, current ->
        maybe_start_upload_recovery(
          current,
          revocation_ref
        )
      end
    )
  end

  defp fail_upload_revocation(state, revocation_ref, error) do
    case Map.pop(state.upload_revocations, revocation_ref) do
      {nil, _revocations} ->
        state

      {revocation, revocations} ->
        cancel_revocation_timer(revocation.timer)

        state =
          state
          |> Map.put(:upload_revocations, revocations)
          |> remove_upload(revocation.upload)

        Enum.reduce(revocation.tokens, state, fn token, current ->
          fail_revocation_waiter(
            current,
            token,
            revocation_ref,
            error
          )
        end)
    end
  end

  defp fail_revocation_waiter(
         state,
         token,
         revocation_ref,
         error
       ) do
    case Map.get(state.revocation_waiters, token) do
      %{completion: :begin_revoke, from: from} = waiter ->
        state =
          state
          |> discard_revocation_waiter(token, waiter)
          |> detach_failed_revocation_join(token)

        GenServer.reply(from, {:error, error})
        state

      %{completion: :orphaned_begin_revoke} = waiter ->
        state
        |> discard_revocation_waiter(token, waiter)
        |> detach_failed_revocation_join(token)

      %{completion: {:idle_lock, _session}} ->
        complete_revocation_waiter(
          state,
          token,
          revocation_ref
        )

      nil ->
        state
    end
  end

  defp detach_failed_revocation_join(state, token) do
    upload_revocations =
      Map.new(state.upload_revocations, fn {revocation_ref, revocation} ->
        {revocation_ref,
         %{
           revocation
           | tokens: MapSet.delete(revocation.tokens, token)
         }}
      end)

    %{state | upload_revocations: upload_revocations}
  end

  defp handle_custody_owner_down(state, monitor, owner) do
    case Map.pop(state.upload_monitors, monitor) do
      {{:owner, ^owner}, upload_monitors} ->
        next_state = Map.put(state, :upload_monitors, upload_monitors)

        case Map.get(next_state.uploads, owner) do
          %{revocation_ref: revocation_ref}
          when is_reference(revocation_ref) ->
            update_revocation_down(
              next_state,
              revocation_ref,
              :upload
            )

          %{} = entry ->
            start_orphan_upload_recovery(
              next_state,
              owner,
              entry
            )

          nil ->
            next_state
        end

      {{:worker, upload_owner, ^owner}, upload_monitors} ->
        case Map.get(state.uploads, upload_owner) do
          %{
            revocation_ref: revocation_ref,
            worker: ^owner
          } = entry
          when is_reference(revocation_ref) ->
            state
            |> Map.put(:upload_monitors, upload_monitors)
            |> put_in(
              [:uploads, upload_owner],
              %{entry | worker: nil, worker_monitor: nil}
            )
            |> update_revocation_down(
              revocation_ref,
              :worker
            )

          %{worker: ^owner} = entry ->
            state
            |> Map.put(:upload_monitors, upload_monitors)
            |> put_in(
              [:uploads, upload_owner],
              %{entry | worker: nil, worker_monitor: nil}
            )

          _missing_or_changed ->
            %{state | upload_monitors: upload_monitors}
        end

      {nil, _upload_monitors} ->
        handle_lease_down(state, monitor, owner)
    end
  end

  defp update_revocation_down(state, revocation_ref, :upload) do
    update_in(
      state,
      [:upload_revocations, revocation_ref],
      fn
        nil -> nil
        revocation -> %{revocation | upload_down?: true}
      end
    )
  end

  defp update_revocation_down(state, revocation_ref, :worker) do
    update_in(
      state,
      [:upload_revocations, revocation_ref],
      fn
        nil -> nil
        revocation -> %{revocation | worker_down?: true}
      end
    )
  end

  defp start_orphan_upload_recovery(state, upload, entry) do
    revocation_ref = make_ref()

    revocation = %{
      custody_ref: entry.custody_ref,
      fallback?: true,
      recovery: entry.recovery,
      recovery_task: nil,
      reason: :runtime_restarted,
      result: :pending,
      timer: nil,
      tokens: MapSet.new(),
      upload: upload,
      upload_down?: true,
      worker: entry.worker,
      worker_down?: is_nil(entry.worker)
    }

    state =
      state
      |> put_in(
        [:uploads, upload],
        %{entry | revocation_ref: revocation_ref}
      )
      |> put_in(
        [:upload_revocations, revocation_ref],
        revocation
      )

    if is_pid(entry.worker) and Process.alive?(entry.worker),
      do: Process.exit(entry.worker, :kill)

    maybe_start_upload_recovery(state, revocation_ref)
  end

  defp register_lease(state, %{session_id: session_id}, lease),
    do: register_lease(state, session_id, lease)

  defp register_lease(state, session_id, lease) when is_binary(session_id) do
    monitor = Process.monitor(lease)

    leases =
      Map.update(
        state.leases,
        session_id,
        MapSet.new([lease]),
        &MapSet.put(&1, lease)
      )

    state
    |> Map.put(:leases, leases)
    |> Map.put(
      :monitors,
      Map.put(state.monitors, monitor, {session_id, lease})
    )
    |> touch_session(session_id)
  end

  defp checkpoint_context(context, reader_binding) do
    context = Map.take(context, @checkpoint_context_fields)

    case Map.get(reader_binding, :classification) do
      classification when classification in [:private, :sensitive, :restricted] ->
        Map.put(context, :checkpoint_classification, classification)

      _missing ->
        context
    end
  end

  defp object_key(state, session, binding) do
    hierarchy = %{
      domain_key: Map.get(session, :domain_key),
      cached_object_keys: Map.get(session, :object_keys, %{}),
      key_domain_id: Map.get(session, :key_domain_id),
      domain_key_version_id: Map.get(session, :domain_key_version_id),
      domain_key_generation: Map.get(session, :domain_key_generation),
      domain_classification: Map.get(session, :domain_classification)
    }

    case state.adapters.object_key_loader.load_object_key(
           state.context,
           binding,
           hierarchy
         ) do
      {:ok,
       %{
         object_dek: <<_::binary-size(32)>> = object_dek,
         reader_binding: reader_binding
       }}
      when is_map(reader_binding) ->
        validate_loaded_object(
          object_dek,
          reader_binding,
          binding
        )

      {:ok, <<_::binary-size(32)>> = object_dek} ->
        {:ok, %{object_dek: object_dek, reader_binding: binding}}

      {:error, :waiting_for_unlock} ->
        {:error, :waiting_for_unlock}

      {:error, %Error{}} = error ->
        error

      _invalid ->
        {:error, Error.new(:integrity_failure)}
    end
  end

  defp validate_loaded_object(
         object_dek,
         %{
           object_id: object_id,
           object_generation: object_generation,
           vault_id: vault_id
         } = reader_binding,
         %{
           object_id: object_id,
           object_generation: object_generation,
           vault_id: vault_id
         }
       ) do
    {:ok, %{object_dek: object_dek, reader_binding: reader_binding}}
  end

  defp validate_loaded_object(_object_dek, _reader_binding, _binding),
    do: {:error, Error.new(:integrity_failure)}

  defp build_upload_material(state, session, _request) do
    stage_id = Ecto.UUID.generate()
    object_id = Ecto.UUID.generate()
    object_dek = :crypto.strong_rand_bytes(32)

    with {:ok, wrapped} <-
           call_adapter(
             state.adapters.key_wrapper,
             :wrap,
             [
               session.domain_key,
               object_dek,
               %{
                 purpose: :object_dek,
                 generation: session.domain_key_generation,
                 aad: "object:" <> object_id
               }
             ]
           ),
         %{
           algorithm: :aes_256_gcm,
           encoded: encoded,
           generation: generation
         } <- wrapped do
      material_ref = make_ref()

      prepared = %{
        material_ref: material_ref,
        stage_id: stage_id,
        candidate_object_id: object_id,
        key_domain_id: session.key_domain_id,
        domain_key_version_id: session.domain_key_version_id,
        storage_ref: stage_id,
        wrapper_algorithm: "aes_256_gcm",
        key_generation: generation,
        dek_wrapper: encoded
      }

      secret = %{
        object_dek: object_dek,
        domain_dedup_key: session.domain_dedup_key
      }

      {:ok, prepared, secret}
    else
      {:error, %Error{}} = error ->
        _ = overwrite(object_dek)
        error

      _invalid ->
        _ = overwrite(object_dek)
        {:error, Error.new(:integrity_failure)}
    end
  end

  defp upload_binding(binding) do
    Map.take(binding, @upload_request_fields)
  end

  defp upload_recovery(%{
         stage_id: stage_id,
         storage_ref: storage_ref
       })
       when is_binary(storage_ref) and byte_size(storage_ref) > 0 do
    if valid_uuid?(stage_id) do
      {:ok,
       %{
         stage_id: stage_id,
         storage_ref: storage_ref
       }}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp upload_recovery(_binding),
    do: {:error, Error.new(:invalid)}

  defp valid_uuid?(value) do
    match?({:ok, _uuid}, Ecto.UUID.cast(value))
  end

  defp wake_waiting(%{wake_waiting: nil}, _session), do: :ok

  defp wake_waiting(state, session) do
    call_optional_adapter(state.wake_waiting, :wake_waiting, [
      %{
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
      |> Map.drop([:vault_key, :domain_key, :domain_dedup_key, :object_keys])
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

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end

  defp positive_option(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_option(_value, default), do: default

  defp configured_backup_cipher(adapters) when is_map(adapters) do
    if Map.has_key?(adapters, :backup_cipher) do
      adapters
    else
      case Application.get_env(:singularity_runtime, :key_custodian) do
        %{backup_cipher: backup_cipher} -> Map.put(adapters, :backup_cipher, backup_cipher)
        _missing -> adapters
      end
    end
  end

  defp configured_backup_cipher(adapters), do: adapters

  defp merge_key_material(session, key_material) when is_map(key_material),
    do: Map.merge(session, key_material)

  defp merge_key_material(session, <<_::binary-size(32)>> = vault_key),
    do: Map.put(session, :vault_key, vault_key)

  defp merge_key_material(session, _invalid), do: session
end
