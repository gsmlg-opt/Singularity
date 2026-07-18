defmodule Singularity.Runtime.ChangePassword do
  @moduledoc "Atomically rotates the credential verifier and password vault wrapper."

  alias Singularity.Core.Error
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext

  @requirement %{
    required_capability: "vault.password_change",
    classification: :private,
    requires_unlocked?: false
  }

  @spec run(map(), SessionContext.t(), binary(), binary(), String.t()) ::
          {:ok, SessionContext.t()} | {:error, Error.t()}
  def run(
        runtime,
        %SessionContext{} = session,
        old_password,
        new_password,
        correlation_id
      )
      when is_map(runtime) and is_binary(old_password) and
             byte_size(old_password) > 0 and is_binary(new_password) and
             byte_size(new_password) > 0 and is_binary(correlation_id) and
             byte_size(correlation_id) > 0 do
    with {:ok, adapters} <- adapters(runtime),
         {:ok, material} <- load_material(adapters, runtime, session),
         {:ok, old_parameters} <-
           kdf_parameters(material.vault_wrapper.kdf_parameters),
         {:ok, old_kek} <-
           call_adapter(adapters.key_deriver, :derive, [
             old_password,
             material.vault_wrapper.kdf_salt,
             old_parameters
           ]),
         metadata = wrapper_metadata(session, material.vault_wrapper),
         {:ok, vault_key} <-
           call_adapter(adapters.key_wrapper, :unwrap, [
             old_kek,
             material.vault_wrapper.wrapped_key,
             metadata
           ]),
         :ok <- key_size(vault_key),
         {:ok, new_verifier} <-
           call_adapter(adapters.password_hasher, :hash, [new_password]),
         new_salt <- adapters.random_bytes.(16),
         :ok <- salt_size(new_salt),
         {:ok, new_parameters} <- kdf_parameters(adapters.vault_kdf_params),
         {:ok, new_kek} <-
           call_adapter(adapters.key_deriver, :derive, [
             new_password,
             new_salt,
             new_parameters
           ]),
         {:ok, new_wrapper} <-
           call_adapter(adapters.key_wrapper, :wrap, [
             new_kek,
             vault_key,
             metadata
           ]),
         {:ok, encoded_wrapper} <- wrapped_key(new_wrapper),
         {:ok, new_wrapper_algorithm} <- wrapper_algorithm(new_wrapper),
         selector = %{principal_id: session.principal_id},
         :ok <- call_adapter(adapters.custodian, :begin_revoke, [selector]),
         :ok <- call_adapter(adapters.custodian, :await_revoking, [selector]),
         result <-
           persist_change(
             adapters,
             runtime,
             session,
             material,
             new_verifier,
             new_salt,
             new_parameters,
             new_wrapper_algorithm,
             encoded_wrapper,
             correlation_id
           ) do
      change_result(result, session)
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_runtime, _session, _old_password, _new_password, _correlation_id),
    do: {:error, Error.new(:invalid)}

  defp load_material(adapters, runtime, session) do
    call_adapter(adapters.operation_scope, :with_read_request, [
      runtime,
      session,
      @requirement,
      fn repo ->
        call_adapter(adapters.identity, :load_password_material, [
          repo,
          %{
            session_id: session.session_id,
            account_id: session.account_id,
            principal_id: session.principal_id,
            vault_id: session.vault_id
          }
        ])
      end
    ])
  end

  defp persist_change(
         adapters,
         runtime,
         session,
         material,
         new_verifier,
         new_salt,
         new_parameters,
         new_wrapper_algorithm,
         encoded_wrapper,
         correlation_id
       ) do
    call_adapter(adapters.operation_scope, :with_shared_request, [
      runtime,
      session,
      @requirement,
      fn repo ->
        call_adapter(adapters.identity, :change_password_and_wrapper, [
          repo,
          %{
            session_id: session.session_id,
            principal_id: session.principal_id,
            vault_id: session.vault_id,
            correlation_id: correlation_id,
            credential_id: material.credential_id,
            credential_revision: material.credential_revision,
            new_verifier: new_verifier,
            wrapper_id: material.vault_wrapper.id,
            vault_key_version_id: material.vault_wrapper.vault_key_version_id,
            expected_wrapped_key: material.vault_wrapper.wrapped_key,
            new_kdf_version: new_parameters.version,
            new_kdf_salt: new_salt,
            new_kdf_parameters: stringify_keys(new_parameters),
            new_wrapper_algorithm: new_wrapper_algorithm,
            new_wrapped_key: encoded_wrapper
          }
        ])
      end
    ])
  end

  defp change_result(:ok, session), do: {:ok, SessionContext.locked(session)}
  defp change_result({:ok, _value}, session), do: {:ok, SessionContext.locked(session)}
  defp change_result({:error, %Error{}} = error, _session), do: error
  defp change_result(_invalid, _session), do: {:error, Error.new(:storage_unavailable)}

  defp wrapper_metadata(session, wrapper) do
    %{
      purpose: :vault_key,
      generation: wrapper.generation,
      aad: session.vault_id
    }
  end

  defp kdf_parameters(%{
         "version" => version,
         "t_cost" => t_cost,
         "m_cost" => m_cost,
         "parallelism" => parallelism
       }) do
    validate_kdf_parameters(%{
      version: version,
      t_cost: t_cost,
      m_cost: m_cost,
      parallelism: parallelism
    })
  end

  defp kdf_parameters(%{
         version: version,
         t_cost: t_cost,
         m_cost: m_cost,
         parallelism: parallelism
       }) do
    validate_kdf_parameters(%{
      version: version,
      t_cost: t_cost,
      m_cost: m_cost,
      parallelism: parallelism
    })
  end

  defp kdf_parameters(_parameters), do: {:error, Error.new(:invalid)}

  defp validate_kdf_parameters(
         %{
           version: version,
           t_cost: t_cost,
           m_cost: m_cost,
           parallelism: parallelism
         } = parameters
       )
       when is_integer(version) and version > 0 and is_integer(t_cost) and
              t_cost > 0 and is_integer(m_cost) and m_cost >= 8 and
              is_integer(parallelism) and parallelism > 0,
       do: {:ok, parameters}

  defp validate_kdf_parameters(_parameters), do: {:error, Error.new(:invalid)}

  defp key_size(<<_::binary-size(32)>>), do: :ok
  defp key_size(_key), do: {:error, Error.new(:integrity_failure)}

  defp salt_size(salt) when is_binary(salt) and byte_size(salt) >= 8, do: :ok
  defp salt_size(_salt), do: {:error, Error.new(:invalid)}

  defp wrapped_key(%{encoded: encoded}) when is_binary(encoded) and byte_size(encoded) > 0,
    do: {:ok, encoded}

  defp wrapped_key(_wrapper), do: {:error, Error.new(:integrity_failure)}

  defp wrapper_algorithm(%{algorithm: :aes_256_gcm}),
    do: {:ok, "aes_256_gcm"}

  defp wrapper_algorithm(%{algorithm: "aes_256_gcm"}),
    do: {:ok, "aes_256_gcm"}

  defp wrapper_algorithm(_wrapper), do: {:error, Error.new(:integrity_failure)}

  defp stringify_keys(parameters) do
    Map.new(parameters, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp adapters(runtime) do
    required = [
      :custodian,
      :identity,
      :key_deriver,
      :key_wrapper,
      :password_hasher,
      :random_bytes,
      :vault_kdf_params
    ]

    if Enum.all?(required, &(Map.get(runtime, &1) not in [nil, false])) and
         is_function(runtime.random_bytes, 1) do
      {:ok,
       %{
         custodian: runtime.custodian,
         identity: runtime.identity,
         key_deriver: runtime.key_deriver,
         key_wrapper: runtime.key_wrapper,
         operation_scope: Map.get(runtime, :operation_scope, OperationScope),
         password_hasher: runtime.password_hasher,
         random_bytes: runtime.random_bytes,
         vault_kdf_params: runtime.vault_kdf_params
       }}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end
end
