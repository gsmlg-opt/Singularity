defmodule Singularity.Runtime.RestoreIntegrityLease do
  @moduledoc """
  Owner-bound, one-shot custody for post-restore plaintext integrity checks.

  The restored vault key, unwrapped domain keys, object DEKs, and plaintext
  never leave the lease. Successful verification returns only SHA-256 evidence
  and consumes the capability. Revocation is synchronous and idempotent.
  """

  use GenServer

  alias Singularity.Core.Error
  alias Singularity.Core.ObjectRef
  alias Singularity.Storage.AuthenticatedReader
  alias Singularity.Storage.Backup.IntegrityAudit, as: StorageIntegrityAudit

  @option_keys ~w[
    binding inventory key_wrapper material_loader object_storage owner ttl_ms vault_key
  ]a
  @binding_keys ~w[
    manifest_id vault_id vault_key_generation vault_key_version_id
  ]a
  @material_keys ~w[
    ciphertext_byte_size ciphertext_hash classification domain_algorithm
    domain_classification domain_id domain_key_generation domain_key_version_id
    domain_kind domain_state domain_version_state envelope_algorithm
    envelope_classification format_version key_domain_id lifecycle lookup_digest
    object_generation object_id plaintext_byte_size vault_id vault_key_generation
    vault_key_version_id vault_version_state wrapped_dek wrapped_domain_key
  ]a
  @classifications [:private, :sensitive, :restricted]

  defmodule Capability do
    @moduledoc "Opaque authority for exactly one restore integrity verification."

    @enforce_keys [:lease, :token]
    defstruct @enforce_keys

    @opaque t :: %__MODULE__{lease: pid(), token: reference()}

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(_capability, _options),
        do: concat(["#RestoreIntegrityLease.Capability<REDACTED>"])
    end
  end

  defmodule PlaintextSummary do
    @moduledoc "Safe SHA-256 evidence from authenticated plaintext reads."

    @enforce_keys [:vault_id, :object_count, :inventory_sha256, :plaintext_hashes]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            vault_id: Ecto.UUID.t(),
            object_count: non_neg_integer(),
            inventory_sha256: <<_::256>>,
            plaintext_hashes: [
              %{asset_object_id: Ecto.UUID.t(), sha256: <<_::256>>}
            ]
          }
  end

  @type capability :: Capability.t()

  @spec issue(map()) :: {:ok, capability()} | {:error, Error.t()}
  def issue(options) when is_map(options) do
    with {:ok, normalized} <- validate_options(options, self()),
         {:ok, lease} <- start_link(normalized),
         {:ok, %Capability{} = capability} <- claim(lease) do
      {:ok, capability}
    else
      {:error, %Error{} = error} -> {:error, public_error(error)}
      _malformed -> invalid()
    end
  rescue
    _exception -> invalid()
  catch
    :exit, _reason -> invalid()
    _kind, _reason -> invalid()
  end

  def issue(_options), do: invalid()

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @spec verify_all(capability()) :: {:ok, PlaintextSummary.t()} | {:error, Error.t()}
  def verify_all(%Capability{lease: lease, token: token})
      when is_pid(lease) and is_reference(token) do
    case safe_call(lease, {:verify_all, token}) do
      {:ok, %PlaintextSummary{} = summary} -> {:ok, summary}
      {:error, %Error{} = error} -> {:error, public_error(error)}
      _malformed -> backup_invalid()
    end
  end

  def verify_all(_capability), do: backup_invalid()

  @spec revoke(capability()) :: :ok | {:error, Error.t()}
  def revoke(%Capability{lease: lease, token: token})
      when is_pid(lease) and is_reference(token) do
    case safe_call(lease, {:revoke, token}) do
      :ok -> :ok
      {:error, :lease_unavailable} -> :ok
      {:error, %Error{} = error} -> {:error, public_error(error)}
      _malformed -> backup_invalid()
    end
  end

  def revoke(_capability), do: backup_invalid()

  @impl true
  def init(options) do
    owner_monitor = Process.monitor(options.owner)
    timer = Process.send_after(self(), :expire, options.ttl_ms)

    {:ok,
     Map.merge(options, %{
       owner_monitor: owner_monitor,
       timer: timer,
       token: make_ref(),
       claimed?: false,
       revoked?: false
     })}
  end

  @impl true
  def handle_call(:claim, {owner, _tag}, %{owner: owner, claimed?: false} = state) do
    capability = %Capability{lease: self(), token: state.token}
    {:reply, {:ok, capability}, %{state | claimed?: true}}
  end

  def handle_call(:claim, _from, state), do: {:reply, backup_invalid(), state}

  def handle_call(
        {:verify_all, token},
        {owner, _tag},
        %{owner: owner, token: token, claimed?: true, revoked?: false} = state
      ) do
    result = verify_inventory(state)
    {:stop, :normal, result, revoke_state(state)}
  end

  def handle_call({:verify_all, _token}, _from, state),
    do: {:reply, backup_invalid(), state}

  def handle_call(
        {:revoke, token},
        {owner, _tag},
        %{owner: owner, token: token} = state
      ) do
    {:stop, :normal, :ok, revoke_state(state)}
  end

  def handle_call({:revoke, _token}, _from, state),
    do: {:reply, backup_invalid(), state}

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{owner: owner, owner_monitor: monitor} = state
      ) do
    {:stop, :normal, revoke_state(state)}
  end

  def handle_info(:expire, state), do: {:stop, :normal, revoke_state(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _revoked = revoke_state(state)
    :ok
  end

  defp claim(lease) do
    case safe_call(lease, :claim) do
      {:ok, %Capability{} = capability} -> {:ok, capability}
      {:error, %Error{} = error} -> {:error, error}
      _malformed -> invalid()
    end
  end

  defp validate_options(options, owner) do
    with true <- Enum.sort(Map.keys(options)) == Enum.sort(@option_keys),
         ^owner <- options.owner,
         <<_::binary-size(32)>> <- options.vault_key,
         ttl_ms when is_integer(ttl_ms) and ttl_ms > 0 <- options.ttl_ms,
         :ok <- validate_binding(options.binding),
         {:ok, inventory_sha256} <-
           StorageIntegrityAudit.inventory_sha256(options.binding.vault_id, options.inventory),
         {:ok, material_loader} <- configured_material_loader(options.material_loader),
         {:ok, key_wrapper} <- configured_key_wrapper(options.key_wrapper),
         {:ok, object_storage} <- configured_object_storage(options.object_storage) do
      {:ok,
       %{
         binding: options.binding,
         inventory: options.inventory,
         inventory_sha256: inventory_sha256,
         key_wrapper: key_wrapper,
         material_loader: material_loader,
         object_storage: object_storage,
         owner: owner,
         ttl_ms: ttl_ms,
         vault_key: options.vault_key
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> invalid()
    end
  end

  defp validate_binding(binding) when is_map(binding) do
    with true <- Enum.sort(Map.keys(binding)) == Enum.sort(@binding_keys),
         {:ok, _manifest_id} <- canonical_uuid(binding.manifest_id),
         {:ok, _vault_id} <- canonical_uuid(binding.vault_id),
         {:ok, _version_id} <- canonical_uuid(binding.vault_key_version_id),
         generation when is_integer(generation) and generation > 0 <-
           binding.vault_key_generation do
      :ok
    else
      _invalid -> backup_invalid()
    end
  end

  defp validate_binding(_binding), do: backup_invalid()

  defp configured_material_loader({module, context}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :load_plaintext_material, 3),
      do: {:ok, %{module: module, context: context, arity: 3}},
      else: invalid()
  end

  defp configured_material_loader(module) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :load_plaintext_material, 2),
      do: {:ok, %{module: module, arity: 2}},
      else: invalid()
  end

  defp configured_material_loader(_loader), do: invalid()

  defp configured_key_wrapper(module) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :unwrap, 3),
      do: {:ok, module},
      else: invalid()
  end

  defp configured_key_wrapper(_wrapper), do: invalid()

  defp configured_object_storage({adapter, context})
       when is_atom(adapter) and is_map(context) do
    callbacks = [stat: 2, open: 2, read_range: 3]

    if Code.ensure_loaded?(adapter) and
         Enum.all?(callbacks, fn {function, arity} ->
           function_exported?(adapter, function, arity)
         end),
       do: {:ok, %{adapter: adapter, context: context}},
       else: invalid()
  end

  defp configured_object_storage(%{adapter: adapter, context: context}),
    do: configured_object_storage({adapter, context})

  defp configured_object_storage(_storage), do: invalid()

  defp verify_inventory(state) do
    state.inventory
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, hashes} ->
      case verify_object(state, entry) do
        {:ok, hash} -> {:cont, {:ok, [hash | hashes]}}
        {:error, %Error{} = error} -> {:halt, {:error, public_error(error)}}
      end
    end)
    |> case do
      {:ok, hashes} ->
        {:ok,
         %PlaintextSummary{
           vault_id: state.binding.vault_id,
           object_count: length(state.inventory),
           inventory_sha256: state.inventory_sha256,
           plaintext_hashes: Enum.reverse(hashes)
         }}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  defp verify_object(state, entry) do
    with {:ok, material} <- load_material(state.material_loader, state.binding, entry),
         :ok <- validate_material(material, state.binding, entry),
         {:ok, domain_key} <-
           unwrap(state.key_wrapper, state.vault_key, material.wrapped_domain_key, %{
             purpose: :domain_key,
             generation: material.domain_key_generation,
             aad: material.vault_id <> ":" <> material.key_domain_id
           }) do
      try do
        verify_with_domain_key(state, entry, material, domain_key)
      after
        _overwritten = overwrite(domain_key)
      end
    end
  end

  defp verify_with_domain_key(state, entry, material, domain_key) do
    with {:ok, object_dek} <-
           unwrap(state.key_wrapper, domain_key, material.wrapped_dek, %{
             purpose: :object_dek,
             generation: material.object_generation,
             aad: "object:" <> material.object_id
           }) do
      try do
        verify_with_object_dek(state.object_storage, entry, material, object_dek)
      after
        _overwritten = overwrite(object_dek)
      end
    end
  end

  defp verify_with_object_dek(storage, entry, material, object_dek) do
    reader_storage = %{
      adapter: storage.adapter,
      context:
        Map.merge(storage.context, %{
          ciphertext_hash: entry.ciphertext_hash,
          domain_namespace: entry.key_domain_id,
          lookup_digest: Base.encode16(entry.lookup_digest, case: :lower),
          vault_namespace: entry.vault_id
        })
    }

    binding = %{
      object_ref: %ObjectRef{object_id: entry.storage_ref},
      object_id: material.object_id,
      vault_id: material.vault_id,
      encryption_domain_id: material.key_domain_id,
      plaintext_byte_size: material.plaintext_byte_size,
      ciphertext_byte_size: material.ciphertext_byte_size,
      format_version: material.format_version
    }

    case AuthenticatedReader.read(reader_storage, binding, object_dek, :all) do
      {:ok, plaintext} when is_binary(plaintext) ->
        try do
          {:ok,
           %{
             asset_object_id: entry.asset_object_id,
             sha256: :crypto.hash(:sha256, plaintext)
           }}
        after
          _overwritten = overwrite(plaintext)
        end

      {:error, %Error{} = error} ->
        {:error, public_error(error)}

      _malformed ->
        unavailable()
    end
  end

  defp load_material(%{module: module, context: context, arity: 3}, binding, entry),
    do:
      normalize_material_result(
        safe_apply(module, :load_plaintext_material, [context, binding, entry])
      )

  defp load_material(%{module: module, arity: 2}, binding, entry),
    do: normalize_material_result(safe_apply(module, :load_plaintext_material, [binding, entry]))

  defp normalize_material_result({:ok, material}) when is_map(material), do: {:ok, material}

  defp normalize_material_result({:error, %Error{} = error}),
    do: {:error, public_error(error)}

  defp normalize_material_result(_malformed), do: unavailable()

  defp validate_material(material, binding, entry) when is_map(material) do
    valid? =
      Enum.sort(Map.keys(material)) == Enum.sort(@material_keys) and
        material.object_id == entry.asset_object_id and
        entry.storage_ref == entry.asset_object_id and
        material.vault_id == binding.vault_id and
        material.key_domain_id == entry.key_domain_id and
        material.domain_id == entry.key_domain_id and
        material.vault_key_version_id == binding.vault_key_version_id and
        material.vault_key_generation == binding.vault_key_generation and
        material.classification == entry.classification and
        material.envelope_classification == entry.classification and
        material.domain_classification == entry.classification and
        material.classification in @classifications and
        material.lookup_digest == entry.lookup_digest and
        material.ciphertext_hash == entry.ciphertext_hash and
        material.ciphertext_byte_size == entry.ciphertext_byte_size and
        material.lifecycle == :available and material.domain_kind == "content" and
        material.domain_state == :active and material.domain_version_state == :active and
        material.vault_version_state == :active and
        material.envelope_algorithm == "aes_256_gcm" and
        material.domain_algorithm == "aes_256_gcm" and
        positive?(material.object_generation) and
        positive?(material.domain_key_generation) and
        nonnegative?(material.plaintext_byte_size) and positive?(material.format_version) and
        canonical_uuid?(material.object_id) and canonical_uuid?(material.vault_id) and
        canonical_uuid?(material.key_domain_id) and
        canonical_uuid?(material.domain_key_version_id) and
        canonical_uuid?(material.vault_key_version_id) and
        digest?(material.lookup_digest) and digest?(material.ciphertext_hash) and
        nonempty_binary?(material.wrapped_dek) and nonempty_binary?(material.wrapped_domain_key)

    if valid?, do: :ok, else: integrity_failure()
  end

  defp validate_material(_material, _binding, _entry), do: integrity_failure()

  defp unwrap(module, wrapping_key, encoded, metadata) do
    case safe_apply(module, :unwrap, [wrapping_key, encoded, metadata]) do
      {:ok, <<_::binary-size(32)>> = key} -> {:ok, key}
      {:error, %Error{}} -> integrity_failure()
      _malformed -> integrity_failure()
    end
  end

  defp safe_apply(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    _exception -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  defp safe_call(lease, request) do
    GenServer.call(lease, request, :infinity)
  catch
    :exit, _reason -> {:error, :lease_unavailable}
  end

  defp revoke_state(%{revoked?: true} = state), do: state

  defp revoke_state(state) do
    if is_reference(Map.get(state, :timer)), do: Process.cancel_timer(state.timer)

    if is_reference(Map.get(state, :owner_monitor)),
      do: Process.demonitor(state.owner_monitor, [:flush])

    _overwritten = overwrite(Map.get(state, :vault_key))
    %{state | revoked?: true, vault_key: nil}
  end

  defp overwrite(value) when is_binary(value), do: :crypto.strong_rand_bytes(byte_size(value))
  defp overwrite(_value), do: :ok

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> {:ok, value}
      _invalid -> backup_invalid()
    end
  end

  defp canonical_uuid(_value), do: backup_invalid()
  defp canonical_uuid?(value), do: match?({:ok, ^value}, Ecto.UUID.cast(value))
  defp positive?(value), do: is_integer(value) and value > 0
  defp nonnegative?(value), do: is_integer(value) and value >= 0
  defp nonempty_binary?(value), do: is_binary(value) and value != ""
  defp digest?(value), do: is_binary(value) and byte_size(value) == 32

  defp public_error(%Error{code: code, retryable?: retryable?}),
    do: Error.new(code, retryable?: retryable?)

  defp invalid, do: {:error, Error.new(:invalid)}
  defp backup_invalid, do: {:error, Error.new(:backup_invalid)}
  defp integrity_failure, do: {:error, Error.new(:integrity_failure)}
  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}
end
