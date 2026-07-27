defmodule Singularity.Runtime.BackupKeyLease do
  @moduledoc """
  Short-lived, one-shot custody for an encrypted backup or restore.

  Passphrase derivation and recovery-key wrapping happen in the caller before
  custody is prepared. The lease retains only the passphrase-derived backup key
  inside a temporary process. During restore, an authenticated recovery wrapper
  may be claimed into a one-shot, owner-bound rewrap capability; neither raw key
  leaves the process. Retained key references are cleared on consumption,
  revocation, or termination on a best-effort basis.
  """

  use GenServer

  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.Manifest
  alias Singularity.Storage.Crypto.BackupRecoveryWrapper
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.Format
  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.Crypto.RecoveredVaultKey

  @wire_version 1
  @backup_encryption_domain_id "9c22b7fa-ff48-4ee2-a49a-d23464393618"
  @chunk_size 4_194_304
  @final_record_size 68
  @max_manifest_bytes 67_108_864
  @max_frames 1_000_000
  @max_bundle_bytes 4_294_967_296
  @max_storage_records 1_024
  @default_active_ttl_ms :timer.seconds(60)
  @storage_header_size Format.header_size()

  defmodule Prepared do
    @moduledoc "A redacted handle for backup-key custody awaiting activation."

    @enforce_keys [:opaque_ref, :public_metadata]
    defstruct @enforce_keys

    @type t :: %__MODULE__{opaque_ref: binary(), public_metadata: map()}
  end

  defimpl Inspect, for: Prepared do
    import Inspect.Algebra

    def inspect(_prepared, _options), do: concat(["#BackupKeyLease.Prepared<REDACTED>"])
  end

  defmodule State do
    @moduledoc false

    @enforce_keys [
      :active_ttl_ms,
      :binding,
      :cipher,
      :custodian,
      :custodian_monitor,
      :expiry_timer,
      :expiry_token,
      :key_material,
      :mode,
      :owner,
      :owner_monitor,
      :pending,
      :phase,
      :public_header,
      :recovery_wrapper,
      :revoked?
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  defimpl Inspect, for: State do
    import Inspect.Algebra

    def inspect(_state, _options), do: concat(["#BackupKeyLease.State<REDACTED>"])
  end

  defmodule EncryptState do
    @moduledoc false

    @enforce_keys [
      :capability,
      :public_header,
      :sequence
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  defimpl Inspect, for: EncryptState do
    import Inspect.Algebra

    def inspect(state, options) do
      progress = [sequence: state.sequence]

      concat(["#BackupKeyLease.EncryptState<", to_doc(progress, options), ">"])
    end
  end

  defmodule Replay do
    @moduledoc "Opaque one-shot authority for the authenticated restore replay."

    @enforce_keys [:lease, :token]
    defstruct @enforce_keys

    @type t :: %__MODULE__{lease: pid(), token: reference()}
  end

  defimpl Inspect, for: Replay do
    import Inspect.Algebra

    def inspect(_replay, _options), do: concat(["#BackupKeyLease.Replay<REDACTED>"])
  end

  defmodule DecryptState do
    @moduledoc false

    @enforce_keys [:capability, :sequence]
    defstruct @enforce_keys

    @type t :: %__MODULE__{capability: pid() | Replay.t(), sequence: non_neg_integer()}
  end

  defimpl Inspect, for: DecryptState do
    import Inspect.Algebra

    def inspect(state, options) do
      concat(["#BackupKeyLease.DecryptState<", to_doc([sequence: state.sequence], options), ">"])
    end
  end

  defmodule StorageAdapter do
    @moduledoc "Storage-facing streaming adapter for an opaque backup key lease."

    alias Singularity.Runtime.BackupKeyLease

    @spec header_size() :: pos_integer()
    def header_size, do: BackupKeyLease.storage_header_size()

    @spec init_encrypt(pid(), map()) ::
            {:ok, binary(), BackupKeyLease.EncryptState.t()} | {:error, term()}
    def init_encrypt(capability, public_header),
      do: BackupKeyLease.storage_init_encrypt(capability, public_header)

    @spec encrypt_chunk(BackupKeyLease.EncryptState.t(), binary()) ::
            {:ok, binary(), BackupKeyLease.EncryptState.t()} | {:error, term()}
    def encrypt_chunk(state, plaintext),
      do: BackupKeyLease.storage_encrypt_chunk(state, plaintext)

    @spec finalize(BackupKeyLease.EncryptState.t(), map()) ::
            {:ok, binary(), map(), :finalized} | {:error, term()}
    def finalize(state, manifest), do: BackupKeyLease.storage_finalize(state, manifest)

    @spec decrypt_all(pid(), map(), binary()) ::
            {:ok, binary(), map()} | {:error, term()}
    def decrypt_all(capability, public_header, bundle),
      do: BackupKeyLease.storage_decrypt_all(capability, public_header, bundle)

    @spec init_decrypt(pid() | BackupKeyLease.Replay.t(), map(), binary()) ::
            {:ok, BackupKeyLease.DecryptState.t()} | {:error, term()}
    def init_decrypt(capability, public_header, crypto_header),
      do: BackupKeyLease.storage_init_decrypt(capability, public_header, crypto_header)

    @spec decrypt_record(BackupKeyLease.DecryptState.t(), binary()) ::
            {:ok, binary(), BackupKeyLease.DecryptState.t()} | {:error, term()}
    def decrypt_record(state, encrypted_record),
      do: BackupKeyLease.storage_decrypt_record(state, encrypted_record)

    @spec finalize_decrypt(BackupKeyLease.DecryptState.t(), binary(), map()) ::
            {:ok, map(), BackupKeyLease.Replay.t() | :replayed} | {:error, term()}
    def finalize_decrypt(state, final_record, evidence),
      do: BackupKeyLease.storage_finalize_decrypt(state, final_record, evidence)
  end

  @type ref :: pid()

  @doc false
  def valid_cipher_adapter?(module) when is_atom(module) and not is_nil(module) do
    cipher_callbacks?(module, 0)
  end

  def valid_cipher_adapter?({module, _context}) when is_atom(module) and not is_nil(module) do
    cipher_callbacks?(module, 1)
  end

  def valid_cipher_adapter?(_adapter), do: false

  @spec prepare(map(), map(), binary(), binary()) ::
          {:ok, Prepared.t()} | {:error, Error.t()}
  def prepare(runtime, session, manifest_id, passphrase) do
    with {:ok, context} <- prepare_context(runtime, session, manifest_id, passphrase),
         {:ok, derived_key} <-
           safe_adapter_call(context.deriver, :derive, [passphrase, context.kdf]) do
      prepare_with_derived_key(context, derived_key)
    else
      _invalid -> backup_invalid()
    end
  end

  @spec reenter(map(), map(), binary()) :: {:ok, Prepared.t()} | {:error, Error.t()}
  def reenter(runtime, persisted, passphrase) do
    with {:ok, context} <- reentry_context(runtime, persisted, passphrase),
         {:ok, derived_key} <-
           safe_adapter_call(context.deriver, :derive, [passphrase, context.kdf]) do
      reenter_with_derived_key(context, derived_key)
    else
      _invalid -> backup_invalid()
    end
  end

  @spec init_encrypt(ref() | binary(), map()) :: {:ok, term()} | {:error, term()}
  def init_encrypt(lease, binding) when is_pid(lease),
    do: safe_lease_call(lease, {:init_encrypt, binding})

  def init_encrypt(opaque_ref, _binding) when is_binary(opaque_ref),
    do: {:error, :waiting_for_backup_key}

  def init_encrypt(_lease, _binding), do: backup_invalid()

  @spec encrypt_chunk(ref(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def encrypt_chunk(lease, index, plaintext)
      when is_pid(lease) and is_integer(index) and index >= 0 and is_binary(plaintext),
      do: safe_lease_call(lease, {:encrypt_chunk, index, plaintext})

  def encrypt_chunk(_lease, _index, _plaintext), do: backup_invalid()

  @spec finalize(ref(), map()) :: {:ok, term()} | {:error, term()}
  def finalize(lease, manifest) when is_pid(lease) and is_map(manifest),
    do: safe_lease_call(lease, {:finalize, manifest})

  def finalize(_lease, _manifest), do: backup_invalid()

  @spec open(ref(), map(), map()) :: :ok | {:error, term()}
  def open(lease, binding, bundle)
      when is_pid(lease) and is_map(binding) and is_map(bundle),
      do: safe_lease_call(lease, {:open, binding, bundle})

  def open(_lease, _binding, _bundle), do: backup_invalid()

  @spec decrypt(ref(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def decrypt(lease, index, encrypted)
      when is_pid(lease) and is_integer(index) and index >= 0 and is_binary(encrypted),
      do: safe_lease_call(lease, {:decrypt, index, encrypted})

  def decrypt(_lease, _index, _encrypted), do: backup_invalid()

  @spec claim_recovered_vault_key(ref(), map()) ::
          {:ok, RecoveredVaultKey.t()} | {:error, Error.t() | :lease_unavailable}
  def claim_recovered_vault_key(lease, proof) when is_pid(lease) and is_map(proof),
    do: safe_restore_call(lease, {:claim_recovered_vault_key, proof})

  def claim_recovered_vault_key(_lease, _proof), do: backup_invalid()

  @spec revoke(ref()) :: :ok
  def revoke(lease) when is_pid(lease) do
    case safe_lease_call(lease, :revoke) do
      :ok -> :ok
      _missing -> :ok
    end
  end

  def revoke(_lease), do: :ok

  @doc false
  def storage_init_encrypt(capability, public_header)
      when is_pid(capability) and is_map(public_header) do
    with {:ok, cipher_header} <-
           safe_lease_call(capability, {:storage_init_encrypt, public_header}),
         true <- is_binary(cipher_header) and byte_size(cipher_header) == Format.header_size() do
      {:ok, cipher_header,
       %EncryptState{
         capability: capability,
         public_header: public_header,
         sequence: 0
       }}
    else
      {:error, %Error{}} = error -> error
      {:error, :waiting_for_backup_key} = error -> error
      _invalid -> backup_invalid()
    end
  end

  def storage_init_encrypt(_capability, _public_header), do: backup_invalid()

  @doc false
  def storage_encrypt_chunk(%EncryptState{} = state, plaintext) when is_binary(plaintext) do
    with true <- plaintext != "",
         {:ok, encrypted} <-
           safe_lease_call(
             state.capability,
             {:storage_encrypt_chunk, state.sequence, plaintext}
           ),
         true <- is_binary(encrypted) do
      {:ok, encrypted, %{state | sequence: state.sequence + 1}}
    else
      {:error, %Error{}} = error -> error
      {:error, :waiting_for_backup_key} = error -> error
      _invalid -> backup_invalid()
    end
  end

  def storage_encrypt_chunk(_state, _plaintext), do: backup_invalid()

  @doc false
  def storage_finalize(%EncryptState{} = state, manifest) when is_map(manifest) do
    with {:ok, trailer, summary, evidence} <-
           safe_lease_call(
             state.capability,
             {:storage_finalize, state.sequence, manifest}
           ),
         true <- is_binary(trailer) and is_map(summary) and is_map(evidence) do
      {:ok, trailer, Map.merge(summary, evidence), :finalized}
    else
      {:error, %Error{}} = error -> error
      {:error, :waiting_for_backup_key} = error -> error
      _invalid -> backup_invalid()
    end
  end

  def storage_finalize(_state, _manifest), do: backup_invalid()

  @doc false
  def storage_decrypt_all(capability, public_header, encoded_bundle)
      when is_pid(capability) and is_map(public_header) and is_binary(encoded_bundle) and
             byte_size(encoded_bundle) <= @max_bundle_bytes do
    with true <- byte_size(encoded_bundle) > Format.header_size(),
         {:ok, plaintext, evidence} <-
           safe_lease_call(
             capability,
             {:storage_decrypt_all, public_header, encoded_bundle}
           ) do
      {:ok, plaintext, evidence}
    else
      {:error, %Error{}} = error -> error
      {:error, :waiting_for_backup_key} = error -> error
      _invalid -> backup_invalid()
    end
  end

  def storage_decrypt_all(_capability, _public_header, _encoded_bundle), do: backup_invalid()

  @doc false
  @spec storage_header_size() :: pos_integer()
  def storage_header_size, do: @storage_header_size

  @doc false
  @spec storage_init_decrypt(pid() | Replay.t(), map(), binary()) ::
          {:ok, DecryptState.t()} | {:error, term()}
  def storage_init_decrypt(capability, public_header, crypto_header)
      when is_pid(capability) and is_map(public_header) and
             byte_size(crypto_header) == @storage_header_size do
    with :ok <-
           safe_lease_call(
             capability,
             {:storage_init_bounded_decrypt, :authenticate, nil, public_header, crypto_header}
           ) do
      {:ok, %DecryptState{capability: capability, sequence: 0}}
    else
      {:error, %Error{}} = error -> error
      {:error, :waiting_for_backup_key} = error -> error
      _invalid -> backup_invalid()
    end
  end

  def storage_init_decrypt(
        %Replay{lease: lease, token: token} = replay,
        public_header,
        crypto_header
      )
      when is_pid(lease) and is_reference(token) and is_map(public_header) and
             byte_size(crypto_header) == @storage_header_size do
    with :ok <-
           safe_lease_call(
             lease,
             {:storage_init_bounded_decrypt, :replay, token, public_header, crypto_header}
           ) do
      {:ok, %DecryptState{capability: replay, sequence: 0}}
    else
      {:error, %Error{}} = error -> error
      {:error, :waiting_for_backup_key} = error -> error
      _invalid -> backup_invalid()
    end
  end

  def storage_init_decrypt(_capability, _public_header, _crypto_header), do: backup_invalid()

  @doc false
  @spec storage_decrypt_record(DecryptState.t(), binary()) ::
          {:ok, binary(), DecryptState.t()} | {:error, term()}
  def storage_decrypt_record(%DecryptState{} = state, encrypted_record)
      when is_binary(encrypted_record) do
    with {:ok, plaintext} <-
           safe_lease_call(
             decrypt_lease(state.capability),
             {:storage_bounded_decrypt_record, decrypt_mode(state.capability),
              decrypt_token(state.capability), state.sequence, encrypted_record}
           ),
         true <- is_binary(plaintext) and byte_size(plaintext) in 1..@chunk_size do
      {:ok, plaintext, %{state | sequence: state.sequence + 1}}
    else
      {:error, %Error{}} = error -> error
      {:error, :waiting_for_backup_key} = error -> error
      _invalid -> backup_invalid()
    end
  end

  def storage_decrypt_record(_state, _encrypted_record), do: backup_invalid()

  @doc false
  @spec storage_finalize_decrypt(DecryptState.t(), binary(), map()) ::
          {:ok, map(), Replay.t() | :replayed} | {:error, term()}
  def storage_finalize_decrypt(%DecryptState{} = state, final_record, evidence)
      when is_binary(final_record) and is_map(evidence) do
    case safe_lease_call(
           decrypt_lease(state.capability),
           {:storage_finalize_bounded_decrypt, decrypt_mode(state.capability),
            decrypt_token(state.capability), state.sequence, final_record, evidence}
         ) do
      {:ok, authenticated, %Replay{} = replay} -> {:ok, authenticated, replay}
      {:ok, replayed, :replayed} -> {:ok, replayed, :replayed}
      {:error, %Error{}} = error -> error
      {:error, :waiting_for_backup_key} = error -> error
      _invalid -> backup_invalid()
    end
  end

  def storage_finalize_decrypt(_state, _final_record, _evidence), do: backup_invalid()

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @spec start_restore_link(map()) :: GenServer.on_start()
  def start_restore_link(options) when is_map(options) do
    options =
      options
      |> Map.put(:mode, :restore)
      |> Map.put(:owner, self())

    GenServer.start_link(__MODULE__, options)
  end

  def start_restore_link(_options), do: {:error, :invalid}

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
          binding: %{manifest_id: manifest_id, vault_id: vault_id} = binding,
          cipher: cipher,
          custodian: custodian,
          key_material: <<_::binary-size(32)>> = key_material,
          public_header: public_header,
          recovery_wrapper: recovery_wrapper
        } = options
      )
      when is_binary(manifest_id) and manifest_id != "" and is_binary(vault_id) and
             vault_id != "" and is_pid(custodian) and is_map(public_header) and
             is_binary(recovery_wrapper) and recovery_wrapper != "" do
    with :backup <- Map.get(options, :mode, :backup),
         true <- exact_binding?(binding),
         true <- valid_cipher_adapter?(cipher),
         true <- valid_public_header?(public_header, binding),
         active_ttl_ms when is_integer(active_ttl_ms) and active_ttl_ms > 0 <-
           Map.get(options, :active_ttl_ms, @default_active_ttl_ms) do
      monitor = Process.monitor(custodian)

      state = %State{
        active_ttl_ms: active_ttl_ms,
        binding: binding,
        cipher: cipher,
        custodian: custodian,
        custodian_monitor: monitor,
        expiry_timer: nil,
        expiry_token: nil,
        key_material: key_material,
        mode: :backup,
        owner: nil,
        owner_monitor: nil,
        pending: nil,
        phase: :ready,
        public_header: public_header,
        recovery_wrapper: recovery_wrapper,
        revoked?: false
      }

      {:ok, refresh_expiry(state)}
    else
      _invalid -> {:stop, :invalid}
    end
  end

  def init(
        %{
          mode: :restore,
          owner: owner,
          binding: %{manifest_id: manifest_id, vault_id: vault_id} = binding,
          cipher: cipher,
          custodian: custodian,
          key_material: <<_::binary-size(32)>> = key_material,
          public_header: public_header
        } = options
      )
      when is_pid(owner) and is_binary(manifest_id) and manifest_id != "" and
             is_binary(vault_id) and vault_id != "" and is_pid(custodian) and
             is_map(public_header) do
    with false <- Map.has_key?(options, :recovery_wrapper),
         true <- exact_binding?(binding),
         true <- valid_cipher_adapter?(cipher),
         true <- valid_public_header?(public_header, binding),
         active_ttl_ms when is_integer(active_ttl_ms) and active_ttl_ms > 0 <-
           Map.get(options, :active_ttl_ms, @default_active_ttl_ms) do
      custodian_monitor = Process.monitor(custodian)
      owner_monitor = Process.monitor(owner)

      state = %State{
        active_ttl_ms: active_ttl_ms,
        binding: binding,
        cipher: cipher,
        custodian: custodian,
        custodian_monitor: custodian_monitor,
        expiry_timer: nil,
        expiry_token: nil,
        key_material: key_material,
        mode: :restore,
        owner: owner,
        owner_monitor: owner_monitor,
        pending: nil,
        phase: :restore_ready,
        public_header: public_header,
        recovery_wrapper: nil,
        revoked?: false
      }

      {:ok, refresh_expiry(state)}
    else
      _invalid -> {:stop, :invalid}
    end
  end

  def init(_options), do: {:stop, :invalid}

  @impl true
  def handle_call(_request, _from, %State{revoked?: true} = state),
    do: {:reply, {:error, :waiting_for_backup_key}, state}

  def handle_call({:storage_init_encrypt, _candidate}, _from, %State{mode: :restore} = state),
    do: {:reply, backup_invalid(), state}

  def handle_call(
        {:storage_encrypt_chunk, _sequence, _plaintext},
        _from,
        %State{mode: :restore} = state
      ),
      do: {:reply, backup_invalid(), state}

  def handle_call(
        {:storage_finalize, _sequence, _manifest},
        _from,
        %State{mode: :restore} = state
      ),
      do: {:reply, backup_invalid(), state}

  def handle_call({:init_encrypt, _candidate}, _from, %State{mode: :restore} = state),
    do: {:reply, backup_invalid(), state}

  def handle_call({:encrypt_chunk, _index, _plaintext}, _from, %State{mode: :restore} = state),
    do: {:reply, backup_invalid(), state}

  def handle_call({:finalize, _manifest}, _from, %State{mode: :restore} = state),
    do: {:reply, backup_invalid(), state}

  def handle_call({:open, _candidate, _bundle}, _from, %State{mode: :restore} = state),
    do: {:reply, backup_invalid(), state}

  def handle_call({:decrypt, _index, _encrypted}, _from, %State{mode: :restore} = state),
    do: {:reply, backup_invalid(), state}

  def handle_call(
        {:storage_init_encrypt, candidate},
        _from,
        %State{phase: :ready} = state
      ) do
    case binding_from_candidate(candidate, state.public_header) do
      {:ok, binding} when binding == state.binding ->
        context = encryption_context(state.key_material, binding)

        with {:ok, header, cipher_state} <-
               safe_adapter_call(state.cipher, :init_encrypt, [context]),
             :ok <- validate_storage_header(header, context) do
          next_state = %{
            state
            | phase: {:storage_encrypting, cipher_state, 0, byte_size(header), 0}
          }

          {:reply, {:ok, header}, refresh_expiry(next_state)}
        else
          _invalid -> {:reply, backup_invalid(), consume(state)}
        end

      _invalid ->
        {:reply, backup_invalid(), state}
    end
  end

  def handle_call({:storage_init_encrypt, _candidate}, _from, state),
    do: {:reply, conflict(), state}

  def handle_call(
        {:storage_encrypt_chunk, sequence, plaintext},
        _from,
        %State{
          phase: {:storage_encrypting, cipher_state, sequence, encoded_bytes, record_count}
        } = state
      )
      when is_integer(sequence) and sequence >= 0 and is_binary(plaintext) and plaintext != "" do
    with {:ok, encrypted, next_cipher_state} <-
           safe_adapter_call(state.cipher, :encrypt_chunk, [cipher_state, plaintext]),
         true <- is_binary(encrypted),
         {:ok, next_encoded_bytes} <- checked_add(encoded_bytes, byte_size(encrypted)),
         true <- next_encoded_bytes <= @max_bundle_bytes,
         {:ok, next_record_count} <-
           validate_storage_data_output(encrypted, record_count) do
      next_state = %{
        state
        | phase:
            {:storage_encrypting, next_cipher_state, sequence + 1, next_encoded_bytes,
             next_record_count}
      }

      {:reply, {:ok, encrypted}, refresh_expiry(next_state)}
    else
      _invalid ->
        {:reply, backup_invalid(), consume(state)}
    end
  end

  def handle_call({:storage_encrypt_chunk, _sequence, _plaintext}, _from, state),
    do: {:reply, conflict(), state}

  def handle_call(
        {:storage_finalize, sequence, manifest},
        _from,
        %State{
          phase: {:storage_encrypting, cipher_state, sequence, encoded_bytes, record_count}
        } = state
      )
      when is_integer(sequence) and sequence >= 0 and is_map(manifest) do
    with {:ok, manifest} <- Manifest.new(manifest),
         :ok <- validate_manifest(manifest, state),
         {:ok, encoded_manifest} <- Manifest.encode(manifest),
         {:ok, output, summary, _finalized_state} <-
           safe_adapter_call(state.cipher, :finalize, [cipher_state]),
         true <- is_binary(output) and is_map(summary),
         {:ok, next_encoded_bytes} <- checked_add(encoded_bytes, byte_size(output)),
         true <- next_encoded_bytes <= @max_bundle_bytes,
         {:ok, final_record, final_record_count} <-
           validate_storage_final_output(output, record_count),
         true <- Map.get(summary, :chunk_count) == final_record_count,
         {:ok, manifest_tag} <- ChunkedAEAD.final_tag(final_record) do
      evidence = %{
        manifest_hash: :crypto.hash(:sha256, encoded_manifest),
        manifest_tag: manifest_tag
      }

      {:reply, {:ok, output, summary, evidence}, consume(state)}
    else
      _invalid -> {:reply, backup_invalid(), consume(state)}
    end
  end

  def handle_call({:storage_finalize, _sequence, _manifest}, _from, state),
    do: {:reply, conflict(), state}

  def handle_call({:init_encrypt, candidate}, _from, %State{phase: :ready} = state) do
    with {:ok, binding} <- binding_from_candidate(candidate, state.public_header),
         true <- binding == state.binding,
         {:ok, header, cipher_state} <-
           safe_adapter_call(state.cipher, :init_encrypt, [state.key_material, binding]) do
      {:reply, {:ok, header}, %{state | phase: {:encrypting, cipher_state, 0}}}
    else
      _invalid -> {:reply, backup_invalid(), state}
    end
  end

  def handle_call({:init_encrypt, _candidate}, _from, state),
    do: {:reply, conflict(), state}

  def handle_call(
        {:encrypt_chunk, index, plaintext},
        _from,
        %State{phase: {:encrypting, cipher_state, expected}} = state
      ) do
    cond do
      index < expected ->
        {:reply, conflict(), state}

      index > expected ->
        {:reply, backup_invalid(), state}

      true ->
        case safe_adapter_call(state.cipher, :encrypt_chunk, [cipher_state, index, plaintext]) do
          {:ok, encrypted, next_cipher_state} when is_binary(encrypted) ->
            {:reply, {:ok, encrypted},
             %{state | phase: {:encrypting, next_cipher_state, expected + 1}}}

          _invalid ->
            {:reply, backup_invalid(), state}
        end
    end
  end

  def handle_call({:encrypt_chunk, _index, _plaintext}, _from, state),
    do: {:reply, conflict(), state}

  def handle_call(
        {:finalize, manifest},
        _from,
        %State{phase: {:encrypting, cipher_state, _next}} = state
      ) do
    with :ok <- validate_manifest(manifest, state),
         {:ok, trailer} <- safe_adapter_call(state.cipher, :finalize, [cipher_state, manifest]) do
      {:reply, {:ok, trailer}, consume(state)}
    else
      _invalid -> {:reply, backup_invalid(), state}
    end
  end

  def handle_call({:finalize, _manifest}, _from, state),
    do: {:reply, conflict(), state}

  def handle_call(
        {:storage_init_bounded_decrypt, :authenticate, nil, candidate, crypto_header},
        {owner, _tag},
        %State{mode: :restore, owner: owner, phase: :restore_ready} = state
      ) do
    case init_bounded_decrypt(state, candidate, crypto_header, :authenticate, nil) do
      {:ok, decrypt} ->
        {:reply, :ok,
         state
         |> Map.put(:phase, {:storage_bounded_decrypt, :authenticate, nil, decrypt})
         |> refresh_expiry()}

      {:error, %Error{}} = error ->
        {:reply, error, consume(state)}
    end
  end

  def handle_call(
        {:storage_init_bounded_decrypt, :replay, token, candidate, crypto_header},
        {owner, _tag},
        %State{
          mode: :restore,
          owner: owner,
          phase: {:restore_authenticated, token, proof, transcript, record_evidence}
        } = state
      ) do
    case init_bounded_decrypt(state, candidate, crypto_header, :replay, token) do
      {:ok, decrypt} ->
        decrypt =
          Map.merge(decrypt, %{
            expected_proof: proof,
            expected_records: record_evidence,
            expected_transcript: transcript
          })

        {:reply, :ok,
         state
         |> Map.put(:phase, {:storage_bounded_decrypt, :replay, token, decrypt})
         |> refresh_expiry()}

      {:error, %Error{}} = error ->
        {:reply, error, consume(state)}
    end
  end

  def handle_call(
        {:storage_init_bounded_decrypt, _mode, _token, _candidate, _crypto_header},
        _from,
        state
      ),
      do: {:reply, backup_invalid(), state}

  def handle_call(
        {:storage_bounded_decrypt_record, mode, token, index, record},
        {owner, _tag},
        %State{
          mode: :restore,
          owner: owner,
          phase: {:storage_bounded_decrypt, mode, token, %{next_index: index} = decrypt}
        } = state
      )
      when mode in [:authenticate, :replay] and is_integer(index) and index >= 0 and
             index < @max_storage_records and is_binary(record) do
    case bounded_decrypt_record(state, decrypt, index, record) do
      {:ok, plaintext, next_decrypt} ->
        {:reply, {:ok, plaintext},
         state
         |> Map.put(:phase, {:storage_bounded_decrypt, mode, token, next_decrypt})
         |> refresh_expiry()}

      {:error, %Error{}} = error ->
        {:reply, error, consume(state)}
    end
  end

  def handle_call(
        {:storage_bounded_decrypt_record, _mode, _token, _index, _record},
        _from,
        state
      ),
      do: {:reply, backup_invalid(), state}

  def handle_call(
        {:storage_finalize_bounded_decrypt, mode, token, sequence, final_record, evidence},
        {owner, _tag},
        %State{
          mode: :restore,
          owner: owner,
          phase: {:storage_bounded_decrypt, mode, token, %{next_index: sequence} = decrypt}
        } = state
      )
      when mode in [:authenticate, :replay] and is_integer(sequence) and sequence >= 0 and
             sequence <= @max_storage_records and is_binary(final_record) and is_map(evidence) do
    case finalize_bounded_decrypt(state, decrypt, final_record, evidence) do
      {:ok, authenticated, proof, recovery_wrapper, transcript, record_evidence}
      when mode == :authenticate ->
        replay_token = make_ref()
        replay = %Replay{lease: self(), token: replay_token}

        {:reply, {:ok, authenticated, replay},
         state
         |> Map.merge(%{
           phase: {:restore_authenticated, replay_token, proof, transcript, record_evidence},
           recovery_wrapper: recovery_wrapper
         })
         |> refresh_expiry()}

      {:ok, authenticated, proof, recovery_wrapper, transcript, _record_evidence}
      when mode == :replay ->
        with ^proof <- Map.fetch!(decrypt, :expected_proof),
             ^transcript <- Map.fetch!(decrypt, :expected_transcript),
             ^recovery_wrapper <- state.recovery_wrapper do
          {:reply, {:ok, authenticated, :replayed},
           state
           |> Map.put(:phase, {:restore_replayed, proof})
           |> refresh_expiry()}
        else
          _mismatch -> {:reply, backup_invalid(), consume(state)}
        end

      {:error, %Error{}} = error ->
        {:reply, error, consume(state)}
    end
  end

  def handle_call(
        {:storage_finalize_bounded_decrypt, _mode, _token, _sequence, _final_record, _evidence},
        _from,
        state
      ),
      do: {:reply, backup_invalid(), state}

  def handle_call(
        {:storage_decrypt_all, candidate, bundle},
        {owner, _tag} = from,
        %State{mode: :restore, owner: owner, phase: :restore_ready} = state
      ) do
    with {:ok, binding} <- binding_from_candidate(candidate, state.public_header),
         true <- binding == state.binding do
      {:noreply, start_storage_decrypt(refresh_expiry(state), from, bundle)}
    else
      _invalid -> {:reply, backup_invalid(), state}
    end
  end

  def handle_call(
        {:storage_decrypt_all, _candidate, _bundle},
        _from,
        %State{mode: :restore} = state
      ),
      do: {:reply, backup_invalid(), state}

  def handle_call(
        {:storage_decrypt_all, candidate, bundle},
        from,
        %State{phase: :ready} = state
      ) do
    with {:ok, binding} <- binding_from_candidate(candidate, state.public_header),
         true <- binding == state.binding do
      {:noreply, start_storage_decrypt(refresh_expiry(state), from, bundle)}
    else
      _invalid -> {:reply, backup_invalid(), state}
    end
  end

  def handle_call({:storage_decrypt_all, _candidate, _bundle}, _from, state),
    do: {:reply, conflict(), state}

  def handle_call(
        {:storage_decrypt_header, operation_ref, header, nonce_prefix, record_count,
         manifest_tag},
        {worker, _tag},
        %State{
          pending: %{operation_ref: operation_ref, pid: worker} = pending,
          phase: {:storage_decrypting, operation_ref}
        } = state
      ) do
    context = encryption_context(state.key_material, state.binding)

    with nil <- Map.get(pending, :decrypt),
         true <- is_integer(record_count) and record_count >= 0 and record_count <= 1_024,
         <<_::binary-size(8)>> <- nonce_prefix,
         <<_::binary-size(16)>> <- manifest_tag,
         :ok <- validate_storage_header(header, context),
         {:ok, _header, _records, %{nonce_prefix: ^nonce_prefix}} <-
           Format.split_header(header) do
      decrypt = %{
        chunk_count: 0,
        header: header,
        manifest_tag: manifest_tag,
        next_index: 0,
        nonce_prefix: nonce_prefix,
        plaintext_bytes: 0,
        plaintext_fragments: [],
        plaintext_hash: :crypto.hash_init(:sha256),
        record_count: record_count
      }

      next_state = %{state | pending: Map.put(pending, :decrypt, decrypt)}
      {:reply, :ok, refresh_expiry(next_state)}
    else
      _invalid -> fail_storage_decrypt_call(state, pending)
    end
  end

  def handle_call(
        {:storage_decrypt_header, operation_ref, _header, _nonce_prefix, _record_count,
         _manifest_tag},
        {worker, _tag},
        %State{pending: %{operation_ref: operation_ref, pid: worker} = pending} = state
      ),
      do: fail_storage_decrypt_call(state, pending)

  def handle_call(
        {:storage_decrypt_record, operation_ref, index, record, false},
        {worker, _tag},
        %State{
          pending:
            %{
              operation_ref: operation_ref,
              pid: worker,
              decrypt: %{next_index: index} = decrypt
            } = pending,
          phase: {:storage_decrypting, operation_ref}
        } = state
      )
      when is_integer(index) and index >= 0 and is_binary(record) do
    with true <- index < decrypt.record_count,
         <<^index::unsigned-big-32, size::unsigned-big-32, _ciphertext_and_tag::binary>> <-
           record,
         true <- size > 0 and size <= @chunk_size,
         {:ok, plaintext} <-
           safe_adapter_call(state.cipher, :decrypt_data_record, [
             record,
             %{
               counter: index,
               header: decrypt.header,
               key: state.key_material,
               nonce_prefix: decrypt.nonce_prefix,
               plaintext_size: size
             }
           ]),
         true <- is_binary(plaintext) and byte_size(plaintext) == size,
         {:ok, plaintext_bytes} <- checked_add(decrypt.plaintext_bytes, size),
         {:ok, plaintext_hash} <- update_hash(decrypt.plaintext_hash, plaintext) do
      next_decrypt = %{
        decrypt
        | chunk_count: decrypt.chunk_count + 1,
          next_index: index + 1,
          plaintext_bytes: plaintext_bytes,
          plaintext_fragments: [plaintext | decrypt.plaintext_fragments],
          plaintext_hash: plaintext_hash
      }

      next_state = %{state | pending: %{pending | decrypt: next_decrypt}}
      {:reply, :ok, refresh_expiry(next_state)}
    else
      _invalid -> fail_storage_decrypt_call(state, pending)
    end
  end

  def handle_call(
        {:storage_decrypt_record, operation_ref, index, final_record, true},
        {worker, _tag},
        %State{
          pending:
            %{
              operation_ref: operation_ref,
              pid: worker,
              decrypt: %{next_index: index, record_count: index} = decrypt
            } = pending,
          phase: {:storage_decrypting, operation_ref}
        } = state
      )
      when is_integer(index) and index >= 0 and is_binary(final_record) do
    with {:ok, summary} <-
           safe_adapter_call(state.cipher, :decrypt_final_record, [
             final_record,
             %{
               header: decrypt.header,
               key: state.key_material,
               nonce_prefix: decrypt.nonce_prefix
             }
           ]),
         true <- valid_decryption_summary?(summary, decrypt),
         {:ok, plaintext_hash} <- finish_hash(decrypt.plaintext_hash),
         true <- plaintext_hash == summary.plaintext_sha256,
         plaintext =
           decrypt.plaintext_fragments
           |> Enum.reverse()
           |> IO.iodata_to_binary(),
         true <- byte_size(plaintext) == decrypt.plaintext_bytes,
         {:ok, evidence, recovery_wrapper} <-
           verify_authenticated_plaintext(plaintext, state, decrypt.manifest_tag) do
      complete_storage_decrypt(state, pending, plaintext, evidence, recovery_wrapper)
    else
      _invalid -> fail_storage_decrypt_call(state, pending)
    end
  end

  def handle_call(
        {:storage_decrypt_record, operation_ref, _index, _record, _eof},
        {worker, _tag},
        %State{pending: %{operation_ref: operation_ref, pid: worker} = pending} = state
      ),
      do: fail_storage_decrypt_call(state, pending)

  def handle_call(
        {:storage_decrypt_header, _operation_ref, _header, _nonce_prefix, _record_count,
         _manifest_tag},
        _from,
        state
      ),
      do: {:reply, conflict(), state}

  def handle_call(
        {:storage_decrypt_record, _operation_ref, _index, _record, _eof},
        _from,
        state
      ),
      do: {:reply, conflict(), state}

  def handle_call(
        {:claim_recovered_vault_key, proof},
        {owner, _tag},
        %State{
          mode: :restore,
          owner: owner,
          phase: {:restore_authenticated, expected_proof},
          recovery_wrapper: recovery_wrapper
        } = state
      )
      when proof == expected_proof and is_binary(recovery_wrapper) and recovery_wrapper != "" do
    claim_recovered_vault_key(state)
  end

  def handle_call(
        {:claim_recovered_vault_key, proof},
        {owner, _tag},
        %State{
          mode: :restore,
          owner: owner,
          phase: {:restore_replayed, expected_proof},
          recovery_wrapper: recovery_wrapper
        } = state
      )
      when proof == expected_proof and is_binary(recovery_wrapper) and recovery_wrapper != "" do
    claim_recovered_vault_key(state)
  end

  def handle_call({:claim_recovered_vault_key, _proof}, _from, state),
    do: {:reply, backup_invalid(), state}

  def handle_call(
        {:rewrap_recovered_vault_key, token, <<_::binary-size(32)>> = new_kek, binding},
        {owner, _tag},
        %State{
          binding: %{vault_id: vault_id},
          mode: :restore,
          owner: owner,
          phase: {:restore_claimed, token}
        } = state
      ) do
    with {:ok, generation} <- recovered_rewrap_binding(binding, vault_id),
         {:ok,
          %{
            algorithm: :aes_256_gcm,
            encoded: encoded,
            generation: ^generation,
            purpose: :vault_key,
            version: 1
          } = wrapper} <-
           safe_adapter_call(KeyWrapper, :wrap, [
             new_kek,
             state.key_material,
             %{purpose: :vault_key, generation: generation, aad: vault_id}
           ]),
         true <- map_size(wrapper) == 5 and is_binary(encoded) and encoded != "" do
      {:stop, :normal, {:ok, wrapper}, consume(state)}
    else
      _invalid -> {:reply, backup_invalid(), state}
    end
  end

  def handle_call({:rewrap_recovered_vault_key, _token, _new_kek, _binding}, _from, state),
    do: {:reply, backup_invalid(), state}

  def handle_call(
        {:revoke_recovered_vault_key, token},
        {owner, _tag},
        %State{mode: :restore, owner: owner, phase: {:restore_claimed, token}} = state
      ),
      do: {:stop, :normal, :ok, revoke_state(state)}

  def handle_call({:revoke_recovered_vault_key, _token}, _from, state),
    do: {:reply, backup_invalid(), state}

  def handle_call({:open, candidate, bundle}, _from, %State{phase: :ready} = state) do
    with {:ok, binding} <- binding_from_candidate(candidate, state.public_header),
         true <- binding == state.binding,
         :ok <- validate_bundle(bundle, state),
         {:ok, cipher_state} <-
           safe_adapter_call(state.cipher, :open, [state.key_material, binding, bundle]) do
      {:reply, :ok, %{state | phase: {:decrypting, cipher_state, 0}}}
    else
      _invalid -> {:reply, backup_invalid(), state}
    end
  end

  def handle_call({:open, _candidate, _bundle}, _from, state),
    do: {:reply, conflict(), state}

  def handle_call(
        {:decrypt, index, encrypted},
        _from,
        %State{phase: {:decrypting, cipher_state, expected}} = state
      ) do
    cond do
      index < expected ->
        {:reply, conflict(), state}

      index > expected ->
        {:reply, backup_invalid(), state}

      true ->
        case safe_adapter_call(state.cipher, :decrypt, [cipher_state, index, encrypted]) do
          {:ok, plaintext, next_cipher_state} when is_binary(plaintext) ->
            {:reply, {:ok, plaintext},
             %{state | phase: {:decrypting, next_cipher_state, expected + 1}}}

          _invalid ->
            {:reply, backup_invalid(), state}
        end
    end
  end

  def handle_call({:decrypt, _index, _encrypted}, _from, state),
    do: {:reply, conflict(), state}

  def handle_call(:revoke, {owner, _tag}, %State{mode: :restore, owner: owner} = state),
    do: {:stop, :normal, :ok, revoke_state(state)}

  def handle_call(:revoke, _from, %State{mode: :restore} = state),
    do: {:reply, backup_invalid(), state}

  def handle_call(:revoke, _from, state),
    do: {:stop, :normal, :ok, revoke_state(state)}

  @impl true
  def handle_info(
        {:backup_key_storage_decrypt_failed, operation_ref, worker},
        %State{
          pending: %{operation_ref: operation_ref, pid: worker} = pending,
          phase: {:storage_decrypting, operation_ref}
        } = state
      ) do
    Process.demonitor(pending.monitor, [:flush])
    GenServer.reply(pending.from, backup_invalid())
    {:noreply, state |> Map.put(:pending, nil) |> consume()}
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        %State{pending: %{monitor: monitor, pid: worker} = pending} = state
      ) do
    GenServer.reply(pending.from, backup_invalid())
    {:noreply, state |> Map.put(:pending, nil) |> consume()}
  end

  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %State{mode: :restore, owner: owner, owner_monitor: monitor} = state
      ) do
    {:stop, :normal, revoke_state(state)}
  end

  def handle_info(
        {:DOWN, monitor, :process, custodian, _reason},
        %State{custodian: custodian, custodian_monitor: monitor} = state
      ) do
    {:stop, :normal, revoke_state(state)}
  end

  def handle_info({:expire, token}, %State{expiry_token: token} = state),
    do: {:stop, :normal, revoke_state(state)}

  def handle_info({:expire, _stale_token}, state), do: {:noreply, state}

  def handle_info(:expire, state), do: {:stop, :normal, revoke_state(state)}

  def handle_info({:backup_key_storage_decrypt_failed, _operation_ref, _worker}, state),
    do: {:noreply, state}

  def handle_info({:DOWN, _monitor, :process, _process, _reason}, state),
    do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = cancel_pending(state, {:error, :waiting_for_backup_key})
    _cleared = overwrite(state.key_material)
    :ok
  end

  defp start_storage_decrypt(state, from, bundle) do
    lease = self()
    operation_ref = make_ref()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          worker = self()
          _watchdog = spawn_link(fn -> watch_lease(lease, worker) end)
          lease_monitor = Process.monitor(lease)

          result =
            drive_storage_decrypt(
              lease,
              operation_ref,
              bundle,
              state.binding,
              state.cipher,
              lease_monitor
            )

          if result != :ok do
            send(lease, {:backup_key_storage_decrypt_failed, operation_ref, self()})
          end
        end,
        [:monitor]
      )

    %{
      state
      | pending: %{
          from: from,
          monitor: monitor,
          operation_ref: operation_ref,
          pid: worker
        },
        phase: {:storage_decrypting, operation_ref}
    }
  end

  defp watch_lease(lease, worker) do
    lease_monitor = Process.monitor(lease)
    worker_monitor = Process.monitor(worker)

    receive do
      {:DOWN, ^lease_monitor, :process, ^lease, _reason} ->
        Process.exit(worker, :kill)

      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        :ok
    end
  end

  defp drive_storage_decrypt(
         lease,
         operation_ref,
         bundle,
         binding,
         parser_observer,
         lease_monitor
       ) do
    with {:ok, parsed} <- scan_storage_bundle(bundle, binding),
         :ok <-
           parser_call(
             lease,
             lease_monitor,
             {:storage_decrypt_header, operation_ref, parsed.header, parsed.nonce_prefix,
              parsed.record_count, parsed.manifest_tag}
           ),
         :ok <-
           drive_storage_records(
             lease,
             lease_monitor,
             operation_ref,
             parsed.records,
             0,
             parser_observer
           ) do
      :ok
    else
      _invalid -> :error
    end
  end

  defp drive_storage_records(
         lease,
         lease_monitor,
         operation_ref,
         <<0xFFFFFFFF::unsigned-big-32, 44::unsigned-big-32, _ciphertext::binary-size(44),
           _tag::binary-size(16)>> = final_record,
         index,
         parser_observer
       ) do
    with :ok <- parser_boundary(parser_observer, index),
         :ok <-
           parser_call(
             lease,
             lease_monitor,
             {:storage_decrypt_record, operation_ref, index, final_record, true}
           ) do
      :ok
    end
  end

  defp drive_storage_records(
         lease,
         lease_monitor,
         operation_ref,
         <<index::unsigned-big-32, size::unsigned-big-32, _ciphertext::binary-size(size),
           _tag::binary-size(16), remaining::binary>> = records,
         index,
         parser_observer
       )
       when size > 0 and size <= @chunk_size do
    record_size = 8 + size + 16
    <<record::binary-size(record_size), ^remaining::binary>> = records

    with :ok <- parser_boundary(parser_observer, index),
         :ok <-
           parser_call(
             lease,
             lease_monitor,
             {:storage_decrypt_record, operation_ref, index, record, false}
           ) do
      drive_storage_records(
        lease,
        lease_monitor,
        operation_ref,
        remaining,
        index + 1,
        parser_observer
      )
    end
  end

  defp drive_storage_records(
         _lease,
         _lease_monitor,
         _operation_ref,
         _records,
         _index,
         _parser_observer
       ),
       do: :error

  defp parser_call(lease, lease_monitor, request) do
    case GenServer.call(lease, request, :infinity) do
      :ok -> :ok
      _invalid -> :error
    end
  catch
    :exit, _reason ->
      receive do
        {:DOWN, ^lease_monitor, :process, ^lease, _reason} -> :error
      after
        0 -> :error
      end
  end

  defp parser_boundary({module, context}, index) when is_atom(module) do
    if function_exported?(module, :before_storage_record, 2) do
      safe_parser_boundary(module, [context, index])
    else
      :ok
    end
  end

  defp parser_boundary(module, index) when is_atom(module) do
    if function_exported?(module, :before_storage_record, 1) do
      safe_parser_boundary(module, [index])
    else
      :ok
    end
  end

  defp parser_boundary(_observer, _index), do: :error

  defp safe_parser_boundary(module, arguments) do
    case apply(module, :before_storage_record, arguments) do
      :ok -> :ok
      _invalid -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp prepare_context(runtime, session, manifest_id, passphrase)
       when is_map(runtime) and is_map(session) and is_binary(manifest_id) and manifest_id != "" and
              is_binary(passphrase) and passphrase != "" do
    with %{vault_id: vault_id, vault_key: <<_::binary-size(32)>> = vault_key} <- session,
         true <- is_binary(vault_id) and vault_id != "",
         {:ok, domain} <- nonempty_binary(Map.get(runtime, :backup_kdf_domain)),
         parameters when is_map(parameters) <- Map.get(runtime, :backup_kdf_parameters),
         {:ok, deriver} <- adapter(Map.get(runtime, :backup_key_deriver)),
         {:ok, wrapper} <- adapter(Map.get(runtime, :backup_key_wrapper)),
         {:ok, custodian} <- adapter(Map.get(runtime, :custodian)),
         random_bytes when is_function(random_bytes, 1) <- Map.get(runtime, :random_bytes),
         salt when is_binary(salt) and byte_size(salt) == 16 <- safe_random(random_bytes, 16) do
      binding = %{manifest_id: manifest_id, vault_id: vault_id}
      kdf = %{domain: domain, parameters: parameters, salt: salt}

      {:ok,
       %{
         binding: binding,
         custodian: custodian,
         deriver: deriver,
         kdf: kdf,
         public_metadata: public_metadata(kdf, binding, nil),
         vault_key: vault_key,
         wrapper: wrapper
       }}
    else
      _invalid -> backup_invalid()
    end
  end

  defp prepare_context(_runtime, _session, _manifest_id, _passphrase), do: backup_invalid()

  defp prepare_with_derived_key(context, <<_::binary-size(32)>> = derived_key) do
    try do
      wrapper_binding = recovery_binding(context.binding)

      with {:ok, recovery_wrapper} <-
             safe_adapter_call(context.wrapper, :wrap, [
               derived_key,
               context.vault_key,
               wrapper_binding
             ]),
           true <- is_binary(recovery_wrapper) and recovery_wrapper != "",
           public_metadata =
             put_in(context.public_metadata, ["recovery", "wrapper"], recovery_wrapper),
           {:ok, prepared} <-
             install_pending(
               context.custodian,
               context.binding,
               derived_key,
               public_metadata
             ) do
        {:ok, prepared}
      else
        _invalid -> backup_invalid()
      end
    after
      _cleared = overwrite(derived_key)
    end
  end

  defp prepare_with_derived_key(_context, derived_key) do
    _cleared = overwrite(derived_key)
    backup_invalid()
  end

  defp reentry_context(runtime, persisted, passphrase)
       when is_map(runtime) and is_map(persisted) and is_binary(passphrase) and passphrase != "" do
    with {:ok, deriver} <- adapter(Map.get(runtime, :backup_key_deriver)),
         {:ok, wrapper} <- adapter(Map.get(runtime, :backup_key_wrapper)),
         {:ok, custodian} <- adapter(Map.get(runtime, :custodian)),
         {:ok, opaque_ref} <- nonempty_binary(Map.get(persisted, "backup_key_lease_id")),
         manifest when is_map(manifest) <- Map.get(persisted, "manifest"),
         {:ok, vault_id} <- nonempty_binary(Map.get(persisted, "vault_id")),
         public_metadata when is_map(public_metadata) <- Map.get(persisted, "public_metadata"),
         {:ok, kdf, binding, recovery_wrapper} <- persisted_crypto(public_metadata),
         true <- is_binary(opaque_ref) do
      {:ok,
       %{
         binding: binding,
         custodian: custodian,
         deriver: deriver,
         expected_domain: Map.get(runtime, :backup_kdf_domain),
         expected_parameters: Map.get(runtime, :backup_kdf_parameters),
         kdf: kdf,
         manifest: manifest,
         public_metadata: public_metadata,
         recovery_wrapper: recovery_wrapper,
         vault_id: vault_id,
         wrapper: wrapper
       }}
    else
      _invalid -> backup_invalid()
    end
  end

  defp reentry_context(_runtime, _persisted, _passphrase), do: backup_invalid()

  defp reenter_with_derived_key(context, <<_::binary-size(32)>> = derived_key) do
    try do
      unwrap_result =
        safe_adapter_call(context.wrapper, :unwrap, [
          derived_key,
          context.recovery_wrapper,
          recovery_binding(context.binding)
        ])

      case unwrap_result do
        {:ok, <<_::binary-size(32)>> = recovered_vault_key} ->
          try do
            with :ok <- validate_reentry(context),
                 {:ok, prepared} <-
                   install_pending(
                     context.custodian,
                     context.binding,
                     derived_key,
                     context.public_metadata
                   ) do
              {:ok, prepared}
            else
              _invalid -> backup_invalid()
            end
          after
            _cleared = overwrite(recovered_vault_key)
          end

        _invalid ->
          backup_invalid()
      end
    after
      _cleared = overwrite(derived_key)
    end
  end

  defp reenter_with_derived_key(_context, derived_key) do
    _cleared = overwrite(derived_key)
    backup_invalid()
  end

  defp validate_reentry(context) do
    with true <- context.kdf.domain == context.expected_domain,
         true <- context.kdf.parameters == context.expected_parameters,
         true <- byte_size(context.kdf.salt) == 16,
         true <- context.binding.vault_id == context.vault_id,
         :ok <-
           validate_manifest_values(context.manifest, context.binding, context.recovery_wrapper) do
      :ok
    else
      _invalid -> backup_invalid()
    end
  end

  defp install_pending(custodian, binding, key_material, public_metadata) do
    opaque_ref = opaque_ref()

    entry = %{
      binding: binding,
      key_material: key_material,
      opaque_ref: opaque_ref,
      public_metadata: public_metadata
    }

    case safe_adapter_call(custodian, :prepare_backup_key, [entry]) do
      {:ok, ^opaque_ref} ->
        {:ok, %Prepared{opaque_ref: opaque_ref, public_metadata: public_metadata}}

      _invalid ->
        backup_invalid()
    end
  end

  defp public_metadata(kdf, binding, wrapper) do
    %{
      "kdf" => %{
        "domain" => kdf.domain,
        "parameters" => kdf.parameters,
        "salt" => Base.encode64(kdf.salt)
      },
      "recovery" => %{
        "binding" => %{
          "manifest_id" => binding.manifest_id,
          "vault_id" => binding.vault_id
        },
        "label" => "backup_recovery",
        "wrapper" => wrapper
      }
    }
  end

  defp persisted_crypto(%{
         "kdf" => %{
           "domain" => domain,
           "parameters" => parameters,
           "salt" => encoded_salt
         },
         "recovery" => %{
           "binding" => %{
             "manifest_id" => manifest_id,
             "vault_id" => vault_id
           },
           "label" => label,
           "wrapper" => recovery_wrapper
         }
       })
       when is_binary(domain) and domain != "" and is_map(parameters) and
              is_binary(encoded_salt) and is_binary(manifest_id) and manifest_id != "" and
              is_binary(vault_id) and vault_id != "" and is_binary(label) and
              is_binary(recovery_wrapper) and recovery_wrapper != "" do
    with {:ok, salt} <- Base.decode64(encoded_salt),
         true <- byte_size(salt) == 16 do
      {:ok, %{domain: domain, parameters: parameters, salt: salt},
       %{manifest_id: manifest_id, vault_id: vault_id}, recovery_wrapper}
    else
      _invalid -> backup_invalid()
    end
  end

  defp persisted_crypto(_metadata), do: backup_invalid()

  defp recovery_binding(binding) do
    %{
      label: :backup_recovery,
      manifest_id: binding.manifest_id,
      vault_id: binding.vault_id
    }
  end

  defp binding_from_candidate(candidate, public_header) when is_map(candidate) do
    cond do
      candidate == public_header ->
        {:ok,
         %{
           manifest_id: Map.get(public_header, :manifest_id),
           vault_id: Map.get(public_header, :vault_id)
         }}

      exact_binding?(candidate) ->
        {:ok, candidate}

      true ->
        backup_invalid()
    end
  end

  defp binding_from_candidate(_candidate, _public_header), do: backup_invalid()

  defp valid_public_header?(public_header, binding) do
    Map.keys(public_header) |> Enum.sort() == [:kdf, :manifest_id, :vault_id, :version] and
      Map.get(public_header, :version) == @wire_version and
      Map.get(public_header, :manifest_id) == binding.manifest_id and
      Map.get(public_header, :vault_id) == binding.vault_id and
      is_map(Map.get(public_header, :kdf))
  end

  defp exact_binding?(binding) when is_map(binding) do
    Map.keys(binding) |> Enum.sort() == [:manifest_id, :vault_id] and
      is_binary(Map.get(binding, :manifest_id)) and Map.get(binding, :manifest_id) != "" and
      is_binary(Map.get(binding, :vault_id)) and Map.get(binding, :vault_id) != ""
  end

  defp exact_binding?(_binding), do: false

  defp recovered_rewrap_binding(
         %{vault_id: vault_id, generation: generation} = binding,
         vault_id
       )
       when map_size(binding) == 2 and is_integer(generation) and generation > 0 and
              generation <= 0xFFFFFFFF do
    if Ecto.UUID.cast(vault_id) == {:ok, vault_id},
      do: {:ok, generation},
      else: backup_invalid()
  end

  defp recovered_rewrap_binding(_binding, _vault_id), do: backup_invalid()

  defp validate_bundle(
         %{header: _header, frames: frames, manifest: manifest, trailer: _trailer},
         state
       )
       when is_list(frames) do
    with true <- Enum.all?(frames, &is_binary/1),
         :ok <- validate_manifest(manifest, state) do
      :ok
    else
      _invalid -> backup_invalid()
    end
  end

  defp validate_bundle(_bundle, _state), do: backup_invalid()

  defp encryption_context(key, binding) do
    %{
      algorithm: Format.algorithm(),
      chunk_index: 0,
      chunk_size: Format.chunk_size(),
      encryption_domain_id: @backup_encryption_domain_id,
      format_version: Format.format_version(),
      key: key,
      object_id: binding.manifest_id,
      vault_id: binding.vault_id
    }
  end

  defp validate_storage_header(header, context)
       when is_binary(header) and byte_size(header) == 66 do
    with {:ok, ^header, "", parsed} <- Format.split_header(header),
         true <-
           Format.context_matches?(
             parsed,
             Map.put(context, :nonce_prefix, parsed.nonce_prefix)
           ) do
      :ok
    else
      _invalid -> backup_invalid()
    end
  end

  defp validate_storage_header(_header, _context), do: backup_invalid()

  defp init_bounded_decrypt(state, candidate, crypto_header, mode, token)
       when mode in [:authenticate, :replay] do
    with {:ok, binding} <- binding_from_candidate(candidate, state.public_header),
         true <- binding == state.binding,
         context = encryption_context(state.key_material, binding),
         :ok <- validate_storage_header(crypto_header, context),
         {:ok, ^crypto_header, "", %{nonce_prefix: nonce_prefix}} <-
           Format.split_header(crypto_header) do
      {:ok,
       %{
         chunk_count: 0,
         encrypted_record_sizes_hash: :crypto.hash_init(:sha256),
         encrypted_records_hash: :crypto.hash_init(:sha256),
         header: crypto_header,
         mode: mode,
         next_index: 0,
         nonce_prefix: nonce_prefix,
         plaintext_bytes: 0,
         plaintext_hash: :crypto.hash_init(:sha256),
         record_evidence: [],
         short_record_seen?: false,
         token: token
       }}
    else
      _invalid -> backup_invalid()
    end
  end

  defp bounded_decrypt_record(state, decrypt, index, record) do
    with <<^index::unsigned-big-32, size::unsigned-big-32, _ciphertext_and_tag::binary>> <-
           record,
         true <- size in 1..@chunk_size,
         false <- decrypt.short_record_seen?,
         true <- byte_size(record) == 8 + size + 16,
         record_evidence = encrypted_record_evidence(index, size, record),
         :ok <- validate_expected_record(decrypt, record_evidence),
         {:ok, plaintext} <-
           safe_adapter_call(state.cipher, :decrypt_data_record, [
             record,
             %{
               counter: index,
               header: decrypt.header,
               key: state.key_material,
               nonce_prefix: decrypt.nonce_prefix,
               plaintext_size: size
             }
           ]),
         true <- is_binary(plaintext) and byte_size(plaintext) == size,
         {:ok, plaintext_bytes} <- checked_add(decrypt.plaintext_bytes, size),
         true <- plaintext_bytes <= @max_bundle_bytes,
         {:ok, plaintext_hash} <- update_hash(decrypt.plaintext_hash, plaintext),
         {:ok, encrypted_records_hash, encrypted_record_sizes_hash} <-
           update_encrypted_record_hashes(
             decrypt.encrypted_records_hash,
             decrypt.encrypted_record_sizes_hash,
             record_evidence
           ) do
      next_decrypt =
        %{
          decrypt
          | chunk_count: decrypt.chunk_count + 1,
            encrypted_record_sizes_hash: encrypted_record_sizes_hash,
            encrypted_records_hash: encrypted_records_hash,
            next_index: index + 1,
            plaintext_bytes: plaintext_bytes,
            plaintext_hash: plaintext_hash,
            record_evidence: [record_evidence | decrypt.record_evidence],
            short_record_seen?: size < @chunk_size
        }
        |> advance_expected_record()

      {:ok, plaintext, next_decrypt}
    else
      _invalid -> backup_invalid()
    end
  end

  defp finalize_bounded_decrypt(state, decrypt, final_record, evidence) do
    with true <- exact_bounded_evidence?(evidence),
         <<0xFFFFFFFF::unsigned-big-32, 44::unsigned-big-32, _ciphertext::binary-size(44),
           _tag::binary-size(16)>> <- final_record,
         final_record_evidence = encrypted_record_evidence(0xFFFFFFFF, 44, final_record),
         :ok <- validate_expected_final_record(decrypt, final_record_evidence),
         {:ok, encrypted_records_hash, encrypted_record_sizes_hash} <-
           update_encrypted_record_hashes(
             decrypt.encrypted_records_hash,
             decrypt.encrypted_record_sizes_hash,
             final_record_evidence
           ),
         {:ok, encrypted_records_sha256} <- finish_hash(encrypted_records_hash),
         {:ok, encrypted_record_sizes_sha256} <- finish_hash(encrypted_record_sizes_hash),
         true <- encrypted_records_sha256 == evidence.encrypted_records_sha256,
         true <- encrypted_record_sizes_sha256 == evidence.encrypted_record_sizes_sha256,
         {:ok, summary} <-
           safe_adapter_call(state.cipher, :decrypt_final_record, [
             final_record,
             %{
               header: decrypt.header,
               key: state.key_material,
               nonce_prefix: decrypt.nonce_prefix
             }
           ]),
         true <- valid_decryption_summary?(summary, decrypt),
         {:ok, plaintext_hash} <- finish_hash(decrypt.plaintext_hash),
         true <- plaintext_hash == summary.plaintext_sha256,
         {:ok, manifest_tag} <- ChunkedAEAD.final_tag(final_record),
         true <- manifest_tag == evidence.manifest_tag,
         encoded_manifest = evidence.encoded_manifest,
         {:ok, manifest} <- Manifest.decode(encoded_manifest),
         {:ok, ^encoded_manifest} <- Manifest.encode(manifest),
         true <- length(manifest.inventory) == evidence.frame_count,
         true <- state.public_header.version == manifest.version,
         true <- state.public_header.manifest_id == manifest.manifest_id,
         {:ok, recovery_wrapper} <- authenticated_recovery_wrapper(manifest, state),
         manifest_hash = :crypto.hash(:sha256, encoded_manifest),
         true <- manifest_hash == evidence.manifest_hash do
      transcript = %{
        chunk_count: summary.chunk_count,
        encrypted_record_sizes_sha256: encrypted_record_sizes_sha256,
        encrypted_records_sha256: encrypted_records_sha256,
        frame_count: evidence.frame_count,
        frame_digest: evidence.frame_digest,
        manifest_hash: manifest_hash,
        manifest_tag: manifest_tag,
        plaintext_bytes: summary.plaintext_bytes,
        plaintext_sha256: plaintext_hash,
        source_sha256: evidence.source_sha256
      }

      proof = restore_authenticated_proof(state, transcript, recovery_wrapper)
      record_evidence = Enum.reverse([final_record_evidence | decrypt.record_evidence])

      {:ok, Map.put(transcript, :proof, proof), proof, recovery_wrapper, transcript,
       record_evidence}
    else
      _invalid -> backup_invalid()
    end
  end

  defp encrypted_record_evidence(counter, size, record),
    do: {counter, size, :crypto.hash(:sha256, record)}

  defp validate_expected_record(%{mode: :authenticate}, _record_evidence), do: :ok

  defp validate_expected_record(
         %{mode: :replay, expected_records: [record_evidence | _remaining]},
         record_evidence
       ),
       do: :ok

  defp validate_expected_record(_decrypt, _record_evidence), do: backup_invalid()

  defp advance_expected_record(%{mode: :authenticate} = decrypt), do: decrypt

  defp advance_expected_record(
         %{mode: :replay, expected_records: [_record | remaining]} = decrypt
       ),
       do: %{decrypt | expected_records: remaining}

  defp validate_expected_final_record(%{mode: :authenticate}, _record_evidence), do: :ok

  defp validate_expected_final_record(
         %{mode: :replay, expected_records: [record_evidence]},
         record_evidence
       ),
       do: :ok

  defp validate_expected_final_record(_decrypt, _record_evidence), do: backup_invalid()

  defp update_encrypted_record_hashes(
         encrypted_records_hash,
         encrypted_record_sizes_hash,
         {counter, size, <<_::binary-size(32)>> = record_sha256}
       ) do
    with {:ok, encrypted_records_hash} <-
           update_hash(
             encrypted_records_hash,
             <<counter::unsigned-big-32, size::unsigned-big-64, record_sha256::binary-size(32)>>
           ),
         {:ok, encrypted_record_sizes_hash} <-
           update_hash(
             encrypted_record_sizes_hash,
             <<counter::unsigned-big-32, size::unsigned-big-64>>
           ) do
      {:ok, encrypted_records_hash, encrypted_record_sizes_hash}
    else
      _invalid -> backup_invalid()
    end
  rescue
    ArgumentError -> backup_invalid()
  end

  defp exact_bounded_evidence?(evidence) when is_map(evidence) do
    Map.keys(evidence) |> Enum.sort() ==
      [
        :encoded_manifest,
        :encrypted_record_sizes_sha256,
        :encrypted_records_sha256,
        :frame_count,
        :frame_digest,
        :manifest_hash,
        :manifest_tag,
        :source_sha256
      ] and
      is_binary(evidence.encoded_manifest) and
      byte_size(evidence.encoded_manifest) in 1..@max_manifest_bytes and
      is_integer(evidence.frame_count) and evidence.frame_count in 0..@max_frames and
      match?(<<_::binary-size(32)>>, evidence.encrypted_record_sizes_sha256) and
      match?(<<_::binary-size(32)>>, evidence.encrypted_records_sha256) and
      match?(<<_::binary-size(32)>>, evidence.frame_digest) and
      match?(<<_::binary-size(32)>>, evidence.manifest_hash) and
      match?(<<_::binary-size(16)>>, evidence.manifest_tag) and
      match?(<<_::binary-size(32)>>, evidence.source_sha256)
  end

  defp exact_bounded_evidence?(_evidence), do: false

  defp validate_storage_data_output("", record_count)
       when record_count >= 0 and record_count <= 1_024,
       do: {:ok, record_count}

  defp validate_storage_data_output(
         <<counter::unsigned-big-32, @chunk_size::unsigned-big-32,
           _ciphertext::binary-size(@chunk_size), _tag::binary-size(16), rest::binary>>,
         record_count
       )
       when counter == record_count and record_count < 1_024 do
    validate_storage_data_output(rest, record_count + 1)
  end

  defp validate_storage_data_output(_output, _record_count), do: backup_invalid()

  defp validate_storage_final_output(
         <<0xFFFFFFFF::unsigned-big-32, 44::unsigned-big-32, _ciphertext::binary-size(44),
           _tag::binary-size(16)>> = final_record,
         record_count
       )
       when record_count >= 0 and record_count <= 1_024,
       do: {:ok, final_record, record_count}

  defp validate_storage_final_output(
         <<counter::unsigned-big-32, size::unsigned-big-32, rest::binary>>,
         record_count
       )
       when counter == record_count and record_count < 1_024 and size > 0 and
              size <= @chunk_size and byte_size(rest) == size + 16 + @final_record_size do
    <<_ciphertext::binary-size(size), _tag::binary-size(16),
      final_record::binary-size(@final_record_size)>> = rest

    case ChunkedAEAD.final_tag(final_record) do
      {:ok, _manifest_tag} -> {:ok, final_record, record_count + 1}
      _invalid -> backup_invalid()
    end
  end

  defp validate_storage_final_output(_output, _record_count), do: backup_invalid()

  defp scan_storage_bundle(bundle, binding)
       when is_binary(bundle) and byte_size(bundle) <= @max_bundle_bytes do
    expected = encryption_context(nil, binding)

    with {:ok, header, records, parsed} <- Format.split_header(bundle),
         true <- byte_size(header) == Format.header_size(),
         true <- records != "",
         true <-
           Format.context_matches?(
             parsed,
             Map.put(expected, :nonce_prefix, parsed.nonce_prefix)
           ),
         {:ok, record_count, manifest_tag} <- scan_storage_records(records, 0) do
      {:ok,
       %{
         header: header,
         manifest_tag: manifest_tag,
         nonce_prefix: parsed.nonce_prefix,
         record_count: record_count,
         records: records
       }}
    else
      _invalid -> backup_invalid()
    end
  end

  defp scan_storage_bundle(_bundle, _binding), do: backup_invalid()

  defp scan_storage_records(
         <<0xFFFFFFFF::unsigned-big-32, 44::unsigned-big-32, _ciphertext::binary-size(44),
           _tag::binary-size(16)>> = final_record,
         count
       )
       when count >= 0 and count <= 1_024 do
    with {:ok, tag} <- ChunkedAEAD.final_tag(final_record) do
      {:ok, count, tag}
    end
  end

  defp scan_storage_records(
         <<count::unsigned-big-32, size::unsigned-big-32, rest::binary>>,
         count
       )
       when count < 1_024 and size > 0 and size <= @chunk_size and
              byte_size(rest) >= size + 16 do
    <<_ciphertext::binary-size(size), _tag::binary-size(16), remaining::binary>> = rest

    canonical_position? =
      size == @chunk_size or
        match?(<<0xFFFFFFFF::unsigned-big-32, _final::binary>>, remaining)

    if canonical_position? do
      scan_storage_records(remaining, count + 1)
    else
      backup_invalid()
    end
  end

  defp scan_storage_records(_records, _count), do: backup_invalid()

  defp validate_manifest(manifest, state) do
    validate_manifest_values(manifest, state.binding, state.recovery_wrapper)
  end

  defp validate_manifest_values(manifest, binding, recovery_wrapper) do
    with {:ok, ^recovery_wrapper} <- manifest_recovery_wrapper(manifest, binding) do
      :ok
    else
      _invalid -> backup_invalid()
    end
  end

  defp manifest_recovery_wrapper(manifest, binding) when is_map(manifest) do
    manifest_id = binding.manifest_id
    vault_id = binding.vault_id

    with ^manifest_id <- field(manifest, :manifest_id),
         [^vault_id] <- field(manifest, :vault_ids),
         recovery when is_map(recovery) <- field(manifest, :recovery),
         "backup_recovery" <- field(recovery, :label),
         recovery_wrapper when is_binary(recovery_wrapper) and recovery_wrapper != "" <-
           field(recovery, :wrapper),
         recovery_binding when is_map(recovery_binding) <- field(recovery, :binding),
         ^manifest_id <- field(recovery_binding, :manifest_id),
         ^vault_id <- field(recovery_binding, :vault_id) do
      {:ok, recovery_wrapper}
    else
      _invalid -> backup_invalid()
    end
  end

  defp manifest_recovery_wrapper(_manifest, _binding), do: backup_invalid()

  defp authenticated_recovery_wrapper(manifest, %State{mode: :backup} = state) do
    with :ok <- validate_manifest(manifest, state) do
      {:ok, state.recovery_wrapper}
    end
  end

  defp authenticated_recovery_wrapper(manifest, %State{mode: :restore} = state),
    do: manifest_recovery_wrapper(manifest, state.binding)

  defp field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp verify_authenticated_plaintext(plaintext, state, <<_::binary-size(16)>> = manifest_tag)
       when is_binary(plaintext) do
    with {:ok, frames} <- decode_logical_frames(plaintext, [], 0),
         {:ok, records, encoded_manifest} <- split_authenticated_manifest(frames),
         true <- byte_size(encoded_manifest) in 1..@max_manifest_bytes,
         {:ok, manifest} <- Manifest.decode(encoded_manifest),
         {:ok, ^encoded_manifest} <- Manifest.encode(manifest),
         true <- length(manifest.inventory) <= @max_frames,
         true <- state.public_header.version == manifest.version,
         true <- state.public_header.manifest_id == manifest.manifest_id,
         {:ok, recovery_wrapper} <- authenticated_recovery_wrapper(manifest, state),
         :ok <- Manifest.verify(manifest, records) do
      {:ok,
       %{
         manifest_hash: :crypto.hash(:sha256, encoded_manifest),
         manifest_tag: manifest_tag
       }, recovery_wrapper}
    else
      _invalid -> backup_invalid()
    end
  end

  defp verify_authenticated_plaintext(_plaintext, _state, _manifest_tag), do: backup_invalid()

  defp decode_logical_frames("", frames, _count), do: {:ok, Enum.reverse(frames)}

  defp decode_logical_frames(
         <<type::unsigned-big-16, payload_length::unsigned-big-64, rest::binary>>,
         frames,
         count
       )
       when count < @max_frames and payload_length <= @max_bundle_bytes and
              payload_length <= byte_size(rest) do
    <<payload::binary-size(payload_length), remaining::binary>> = rest
    decode_logical_frames(remaining, [%{type: type, payload: payload} | frames], count + 1)
  end

  defp decode_logical_frames(_plaintext, _frames, _count), do: backup_invalid()

  defp split_authenticated_manifest(frames) do
    case List.pop_at(frames, -1) do
      {%{type: 0xFFFF, payload: encoded_manifest}, records} ->
        if Enum.all?(records, &(&1.type != 0xFFFF)) do
          {:ok, records, encoded_manifest}
        else
          backup_invalid()
        end

      _invalid ->
        backup_invalid()
    end
  end

  defp valid_decryption_summary?(summary, decrypt) when is_map(summary) do
    Map.keys(summary) |> Enum.sort() ==
      [:chunk_count, :plaintext_bytes, :plaintext_sha256] and
      summary.chunk_count == decrypt.chunk_count and
      summary.plaintext_bytes == decrypt.plaintext_bytes and
      match?(<<_::binary-size(32)>>, summary.plaintext_sha256)
  end

  defp valid_decryption_summary?(_summary, _decrypt), do: false

  defp update_hash(hash, plaintext) do
    {:ok, :crypto.hash_update(hash, plaintext)}
  rescue
    ArgumentError -> backup_invalid()
  catch
    :error, _reason -> backup_invalid()
  end

  defp finish_hash(hash) do
    case :crypto.hash_final(hash) do
      <<_::binary-size(32)>> = digest -> {:ok, digest}
      _invalid -> backup_invalid()
    end
  rescue
    ArgumentError -> backup_invalid()
  catch
    :error, _reason -> backup_invalid()
  end

  defp complete_storage_decrypt(
         %State{mode: :backup} = state,
         pending,
         plaintext,
         evidence,
         _recovery_wrapper
       ) do
    GenServer.reply(pending.from, {:ok, plaintext, evidence})
    Process.demonitor(pending.monitor, [:flush])
    {:reply, :ok, state |> Map.put(:pending, nil) |> consume()}
  end

  defp complete_storage_decrypt(
         %State{mode: :restore} = state,
         pending,
         plaintext,
         evidence,
         recovery_wrapper
       ) do
    proof = restore_authenticated_proof(state, evidence, recovery_wrapper)
    GenServer.reply(pending.from, {:ok, plaintext, evidence})
    Process.demonitor(pending.monitor, [:flush])

    {:reply, :ok,
     %{
       state
       | pending: nil,
         phase: {:restore_authenticated, proof},
         recovery_wrapper: recovery_wrapper
     }}
  end

  defp restore_authenticated_proof(
         state,
         %{
           manifest_hash: <<_::binary-size(32)>> = manifest_hash,
           manifest_tag: <<_::binary-size(16)>> = manifest_tag
         },
         recovery_wrapper
       ) do
    %{
      vault_id: state.binding.vault_id,
      manifest_id: state.binding.manifest_id,
      manifest_hash: manifest_hash,
      manifest_tag: manifest_tag,
      recovery: %{
        label: "backup_recovery",
        binding: %{
          vault_id: state.binding.vault_id,
          manifest_id: state.binding.manifest_id
        },
        wrapper_sha256: :crypto.hash(:sha256, recovery_wrapper)
      }
    }
  end

  defp claim_recovered_vault_key(state) do
    case safe_adapter_call(BackupRecoveryWrapper, :unwrap, [
           state.key_material,
           state.recovery_wrapper,
           recovery_binding(state.binding)
         ]) do
      {:ok, <<_::binary-size(32)>> = vault_key} ->
        token = make_ref()
        capability = RecoveredVaultKey.issue(self(), token)
        _cleared_backup_key = overwrite(state.key_material)

        next_state = %{state | key_material: vault_key, phase: {:restore_claimed, token}}
        {:reply, {:ok, capability}, refresh_expiry(next_state)}

      _invalid ->
        {:reply, backup_invalid(), consume(state)}
    end
  end

  defp fail_storage_decrypt_call(state, pending) do
    GenServer.reply(pending.from, backup_invalid())
    Process.demonitor(pending.monitor, [:flush])
    {:reply, backup_invalid(), state |> Map.put(:pending, nil) |> consume()}
  end

  defp checked_add(left, right) when left <= 0xFFFFFFFFFFFFFFFF - right,
    do: {:ok, left + right}

  defp checked_add(_left, _right), do: backup_invalid()

  defp decrypt_lease(lease) when is_pid(lease), do: lease
  defp decrypt_lease(%Replay{lease: lease}), do: lease

  defp decrypt_mode(lease) when is_pid(lease), do: :authenticate
  defp decrypt_mode(%Replay{}), do: :replay

  defp decrypt_token(lease) when is_pid(lease), do: nil
  defp decrypt_token(%Replay{token: token}), do: token

  defp safe_lease_call(lease, request) do
    GenServer.call(lease, request, :infinity)
  catch
    :exit, _reason -> {:error, :waiting_for_backup_key}
  end

  defp safe_restore_call(lease, request) do
    GenServer.call(lease, request, :infinity)
  catch
    :exit, _reason -> {:error, :lease_unavailable}
  end

  defp safe_adapter_call(adapter, function, arguments) do
    call_adapter(adapter, function, arguments)
  rescue
    _exception -> backup_invalid()
  catch
    _kind, _reason -> backup_invalid()
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, arguments)

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module),
       do: apply(module, function, [context | arguments])

  defp adapter(module) when is_atom(module) and not is_nil(module), do: {:ok, module}

  defp adapter({module, _context} = adapter) when is_atom(module) and not is_nil(module),
    do: {:ok, adapter}

  defp adapter(_adapter), do: backup_invalid()

  defp cipher_callbacks?(module, context_arity) do
    Code.ensure_loaded?(module) and
      Enum.all?(
        [
          init_encrypt: 1,
          encrypt_chunk: 2,
          finalize: 1,
          decrypt_data_record: 2,
          decrypt_final_record: 2
        ],
        fn {function, arity} ->
          function_exported?(module, function, arity + context_arity)
        end
      )
  end

  defp safe_random(random_bytes, size) do
    random_bytes.(size)
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp nonempty_binary(value) when is_binary(value) and value != "", do: {:ok, value}
  defp nonempty_binary(_value), do: backup_invalid()

  defp opaque_ref,
    do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp consume(state) do
    cleared = overwrite(state.key_material)
    %{state | key_material: cleared, phase: :consumed}
  end

  defp refresh_expiry(%State{active_ttl_ms: active_ttl_ms} = state) do
    if is_reference(state.expiry_timer), do: Process.cancel_timer(state.expiry_timer)

    token = make_ref()
    timer = Process.send_after(self(), {:expire, token}, active_ttl_ms)
    %{state | expiry_timer: timer, expiry_token: token}
  end

  defp revoke_state(%State{revoked?: true} = state), do: state

  defp revoke_state(state) do
    state = cancel_pending(state, {:error, :waiting_for_backup_key})
    cleared = overwrite(state.key_material)
    %{state | key_material: cleared, phase: :revoked, revoked?: true}
  end

  defp cancel_pending(%State{pending: nil} = state, _reply), do: state

  defp cancel_pending(%State{pending: pending} = state, reply) do
    monitor = pending.monitor
    worker = pending.pid
    Process.unlink(worker)
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

  defp backup_invalid, do: {:error, Error.new(:backup_invalid)}
  defp conflict, do: {:error, Error.new(:conflict)}
end
