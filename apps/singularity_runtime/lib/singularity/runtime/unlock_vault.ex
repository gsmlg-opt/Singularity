defmodule Singularity.Runtime.UnlockVault do
  @moduledoc "Authenticates and activates vault custody only after durable audit commit."

  alias Singularity.Core.Error
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext

  @requirement %{
    required_capability: "vault.unlock",
    classification: :private,
    requires_unlocked?: false
  }

  @spec run(map(), SessionContext.t(), binary(), String.t()) ::
          {:ok, SessionContext.t()} | {:error, Error.t()}
  def run(
        runtime,
        %SessionContext{} = session,
        password,
        correlation_id
      )
      when is_map(runtime) and is_binary(password) and byte_size(password) > 0 and
             is_binary(correlation_id) and byte_size(correlation_id) > 0 do
    with {:ok, adapters} <- adapters(runtime),
         {:ok, material} <- load_material(adapters, runtime, session),
         {:ok, parameters} <- kdf_parameters(material.vault_wrapper.kdf_parameters),
         {:ok, kek} <-
           call_adapter(adapters.key_deriver, :derive, [
             password,
             material.vault_wrapper.kdf_salt,
             parameters
           ]),
         {:ok, vault_key} <-
           call_adapter(adapters.key_wrapper, :unwrap, [
             kek,
             material.vault_wrapper.wrapped_key,
             %{
               purpose: :vault_key,
               generation: material.vault_wrapper.generation,
               aad: session.vault_id
             }
           ]),
         {:ok, domain_key} <-
           call_adapter(adapters.key_wrapper, :unwrap, [
             vault_key,
             material.domain_key_version.wrapped_key,
             %{
               purpose: :domain_key,
               generation: material.domain_key_version.generation,
               aad:
                 session.vault_id <>
                   ":" <> material.domain_key_version.key_domain_id
             }
           ]),
         :ok <- key_size(vault_key),
         :ok <- key_size(domain_key),
         {:ok, pending} <-
           call_adapter(adapters.custodian, :prepare_unlock, [
             %{
               session_id: session.session_id,
               account_id: session.account_id,
               principal_id: session.principal_id,
               vault_id: session.vault_id,
               expires_at: session.expires_at,
               principal_authorization_epoch: session.principal_authorization_epoch,
               vault_authorization_epoch: session.vault_authorization_epoch,
               authorization_epoch: session.authorization_epoch,
               vault_key: vault_key,
               domain_key: domain_key
             }
           ]) do
      try do
        activate_after_commit(
          adapters,
          runtime,
          session,
          material,
          pending,
          correlation_id
        )
      after
        _discard_result =
          call_adapter(adapters.custodian, :discard_pending, [pending])
      end
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_runtime, _session, _password, _correlation_id),
    do: {:error, Error.new(:invalid)}

  defp load_material(adapters, runtime, session) do
    call_adapter(adapters.operation_scope, :with_read_request, [
      runtime,
      session,
      @requirement,
      fn repo ->
        call_adapter(adapters.vaults, :load_unlock_material, [
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

  defp activate_after_commit(
         adapters,
         runtime,
         session,
         material,
         pending,
         correlation_id
       ) do
    call_adapter(adapters.operation_scope, :with_shared_request, [
      runtime,
      session,
      @requirement,
      fn repo ->
        result =
          call_adapter(adapters.vaults, :unlock_and_audit, [
            repo,
            %{
              session_id: session.session_id,
              principal_id: session.principal_id,
              vault_id: session.vault_id,
              vault_key_version_id: material.vault_wrapper.vault_key_version_id,
              domain_key_version_id: material.domain_key_version.id,
              correlation_id: correlation_id
            }
          ])

        after_commit(result, adapters.custodian, pending, session)
      end
    ])
  end

  defp after_commit(:ok, custodian, pending, session),
    do: activation_callback(custodian, pending, session)

  defp after_commit({:ok, _value}, custodian, pending, session),
    do: activation_callback(custodian, pending, session)

  defp after_commit({:error, %Error{}} = error, _custodian, _pending, _session),
    do: error

  defp after_commit(_invalid, _custodian, _pending, _session),
    do: {:error, Error.new(:storage_unavailable)}

  defp activation_callback(custodian, pending, session) do
    {:after_commit,
     fn ->
       with :ok <- call_adapter(custodian, :activate_unlock, [pending]) do
         {:ok, SessionContext.unlocked(session)}
       end
     end}
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

  defp adapters(runtime) do
    required = [:custodian, :key_deriver, :key_wrapper, :vaults]

    if Enum.all?(required, &(Map.get(runtime, &1) not in [nil, false])) do
      {:ok,
       %{
         custodian: runtime.custodian,
         key_deriver: runtime.key_deriver,
         key_wrapper: runtime.key_wrapper,
         operation_scope: Map.get(runtime, :operation_scope, OperationScope),
         vaults: runtime.vaults
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
