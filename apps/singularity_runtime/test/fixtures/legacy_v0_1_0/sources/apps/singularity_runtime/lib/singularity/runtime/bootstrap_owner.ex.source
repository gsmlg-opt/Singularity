defmodule Singularity.Runtime.BootstrapOwner do
  @moduledoc "Builds and atomically persists the initial owner and key hierarchy."

  alias Singularity.Core.Error

  @default_capabilities [
    "asset.read",
    "asset.write",
    "note.export",
    "note.read",
    "note.write",
    "vault.lock",
    "vault.password_change",
    "vault.unlock"
  ]

  @spec run(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def run(adapters, %{display_name: display_name, login: login, password: password})
      when is_map(adapters) and is_binary(display_name) and is_binary(login) and
             is_binary(password) do
    with {:ok, display_name} <- nonempty_text(display_name),
         {:ok, normalized_login} <- normalize_login(login),
         :ok <- require_secret(password),
         {:ok, credential_hash} <- hash_password(adapters, password),
         {:ok, command} <-
           build_command(
             adapters,
             display_name,
             normalized_login,
             password,
             credential_hash
           ) do
      adapters.repository.bootstrap_owner(adapters.repository_context, command)
    end
  end

  def run(_adapters, _attrs), do: {:error, Error.new(:invalid)}

  @spec normalize_login(binary()) :: {:ok, binary()} | {:error, Error.t()}
  def normalize_login(login) when is_binary(login) do
    login
    |> String.trim()
    |> String.downcase()
    |> nonempty_text()
  end

  def normalize_login(_login), do: {:error, Error.new(:invalid)}

  defp build_command(adapters, display_name, normalized_login, password, credential_hash) do
    owner_id = generate_id(adapters)
    credential_id = generate_id(adapters)
    vault_id = owner_id
    cleanup_principal_id = generate_id(adapters)
    key_domain_id = generate_id(adapters)
    vault_key_version_id = generate_id(adapters)
    vault_key_wrapper_id = generate_id(adapters)
    domain_key_version_id = generate_id(adapters)
    dedup_wrapper_id = generate_id(adapters)

    vault_key = adapters.random_bytes.(32)
    domain_key = adapters.random_bytes.(32)
    dedup_key = adapters.random_bytes.(32)
    kdf_salt = adapters.random_bytes.(16)
    kdf_params = Map.fetch!(adapters, :vault_kdf_params)

    with :ok <- require_size(vault_key, 32),
         :ok <- require_size(domain_key, 32),
         :ok <- require_size(dedup_key, 32),
         :ok <- require_minimum_size(kdf_salt, 8),
         {:ok, kek} <- derive_kek(adapters, password, kdf_salt, kdf_params),
         {:ok, vault_wrapper} <-
           wrap(
             adapters,
             kek,
             vault_key,
             :vault_key,
             1,
             vault_id
           ),
         {:ok, domain_wrapper} <-
           wrap(
             adapters,
             vault_key,
             domain_key,
             :domain_key,
             1,
             vault_id <> ":" <> key_domain_id
           ),
         {:ok, dedup_wrapper} <-
           wrap(
             adapters,
             domain_key,
             dedup_key,
             :domain_dedup_key,
             1,
             key_domain_id
           ) do
      {:ok,
       %{
         idempotency_key: idempotency_key(normalized_login),
         person: %{id: owner_id, display_name: display_name, metadata: %{}},
         account: %{id: owner_id, person_id: owner_id, status: :active, metadata: %{}},
         credential: %{
           id: credential_id,
           account_id: owner_id,
           normalized_login: normalized_login,
           secret_hash: credential_hash,
           verifier_version: 1
         },
         principal: %{
           id: owner_id,
           account_id: owner_id,
           kind: :owner,
           authorization_epoch: 0,
           metadata: %{}
         },
         cleanup_principal: %{
           id: cleanup_principal_id,
           account_id: owner_id,
           kind: :system,
           authorization_epoch: 0,
           metadata: %{"name" => "object_cleanup"}
         },
         vault: %{
           id: vault_id,
           kind: :personal,
           authorization_epoch: 0,
           locked: true,
           metadata: %{}
         },
         membership: %{
           principal_id: owner_id,
           vault_id: vault_id,
           clearance: :restricted
         },
         cleanup_membership: %{
           principal_id: cleanup_principal_id,
           vault_id: vault_id,
           clearance: :restricted
         },
         capabilities: Map.get(adapters, :initial_capabilities, @default_capabilities),
         cleanup_capabilities: ["object.cleanup"],
         key_domain: %{
           id: key_domain_id,
           vault_id: vault_id,
           classification: :private,
           kind: "content",
           state: :active
         },
         vault_key_version: %{
           id: vault_key_version_id,
           vault_id: vault_id,
           generation: 1,
           state: :active,
           algorithm: "aes-256-gcm"
         },
         vault_key_wrapper: %{
           id: vault_key_wrapper_id,
           vault_id: vault_id,
           vault_key_version_id: vault_key_version_id,
           account_id: owner_id,
           generation: 1,
           kdf_version: Map.fetch!(kdf_params, :version),
           kdf_salt: kdf_salt,
           kdf_parameters: stringify_keys(kdf_params),
           wrapper_algorithm: wrapper_algorithm(vault_wrapper),
           wrapped_key: Map.fetch!(vault_wrapper, :encoded)
         },
         domain_key_version: %{
           id: domain_key_version_id,
           vault_id: vault_id,
           key_domain_id: key_domain_id,
           vault_key_version_id: vault_key_version_id,
           generation: 1,
           state: :active,
           algorithm: wrapper_algorithm(domain_wrapper),
           wrapped_key: Map.fetch!(domain_wrapper, :encoded)
         },
         domain_dedup_key_wrapper: %{
           id: dedup_wrapper_id,
           vault_id: vault_id,
           key_domain_id: key_domain_id,
           domain_key_version_id: domain_key_version_id,
           algorithm: wrapper_algorithm(dedup_wrapper),
           wrapped_key: Map.fetch!(dedup_wrapper, :encoded)
         }
       }}
    end
  rescue
    _error in [KeyError] -> {:error, Error.new(:invalid)}
  end

  defp hash_password(adapters, password) do
    context = Map.fetch!(adapters, :password_hasher_context)
    adapters.password_hasher.hash(context, password)
  rescue
    _error in [KeyError] -> {:error, Error.new(:invalid)}
  end

  defp derive_kek(adapters, password, salt, params) do
    case Map.fetch(adapters, :key_deriver_context) do
      {:ok, context} ->
        adapters.key_deriver.derive(context, password, %{salt: salt, params: params})

      :error ->
        adapters.key_deriver.derive(password, salt, params)
    end
  end

  defp wrap(adapters, wrapping_key, raw_key, purpose, generation, aad) do
    metadata = %{purpose: purpose, generation: generation, aad: aad}

    case Map.fetch(adapters, :key_wrapper_context) do
      {:ok, context} ->
        adapters.key_wrapper.wrap(context, wrapping_key, raw_key, metadata)

      :error ->
        adapters.key_wrapper.wrap(wrapping_key, raw_key, metadata)
    end
  end

  defp generate_id(%{id_generator: generator}) when is_function(generator, 0),
    do: generator.()

  defp idempotency_key(normalized_login) do
    digest =
      normalized_login
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "owner-bootstrap:" <> digest
  end

  defp wrapper_algorithm(%{algorithm: algorithm}) when is_atom(algorithm),
    do: Atom.to_string(algorithm)

  defp wrapper_algorithm(%{algorithm: algorithm}) when is_binary(algorithm), do: algorithm

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp nonempty_text(value) do
    case String.trim(value) do
      "" -> {:error, Error.new(:invalid)}
      normalized -> {:ok, normalized}
    end
  end

  defp require_secret(""), do: {:error, Error.new(:invalid)}
  defp require_secret(_password), do: :ok

  defp require_size(value, size) when is_binary(value) and byte_size(value) == size, do: :ok
  defp require_size(_value, _size), do: {:error, Error.new(:invalid)}

  defp require_minimum_size(value, size)
       when is_binary(value) and byte_size(value) >= size,
       do: :ok

  defp require_minimum_size(_value, _size), do: {:error, Error.new(:invalid)}
end
