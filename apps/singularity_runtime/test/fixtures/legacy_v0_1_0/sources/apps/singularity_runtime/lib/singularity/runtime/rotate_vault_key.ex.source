defmodule Singularity.Runtime.RotateVaultKey do
  @moduledoc "Opaque, pending-to-active vault-key rotation orchestration."

  alias Singularity.Core.AuditEvent
  alias Singularity.Core.Error
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.SessionContext

  @prepare_requirement %{
    required_capability: "vault.password_change",
    classification: :restricted,
    requires_unlocked?: true
  }
  @persist_requirement %{@prepare_requirement | requires_unlocked?: false}

  @spec run(map(), SessionContext.t(), binary(), String.t()) ::
          {:ok, SessionContext.t()} | {:error, Error.t()}
  def run(
        runtime,
        %SessionContext{unlocked?: true} = session,
        password,
        correlation_id
      )
      when is_map(runtime) and is_binary(password) and byte_size(password) > 0 and
             is_binary(correlation_id) do
    with true <- valid_uuid?(correlation_id),
         {:ok, adapters} <- adapters(runtime),
         {:ok, material} <- load_material(adapters, runtime, session),
         {:ok, parameters} <-
           kdf_parameters(material.vault_wrapper.kdf_parameters),
         {:ok, vault_kek} <-
           call_adapter(adapters.key_deriver, :derive, [
             password,
             material.vault_wrapper.kdf_salt,
             parameters
           ]),
         {:ok, request} <-
           rotation_request(adapters, session, material, vault_kek),
         {:ok, plan} <-
           call_adapter(adapters.custodian, :prepare_vault_rotation, [request]),
         {:ok, audit} <-
           rotation_audit(adapters, session, correlation_id),
         selector = %{vault_id: session.vault_id},
         {:ok, revoke_token} <-
           call_adapter(adapters.custodian, :begin_revoke, [selector]),
         result <-
           persist_while_revoking(
             adapters,
             runtime,
             session,
             selector,
             revoke_token,
             plan,
             audit
           ) do
      rotation_result(result, session)
    else
      false -> {:error, Error.new(:invalid)}
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  rescue
    _error -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  catch
    _kind, _reason -> {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def run(_runtime, _session, _password, _correlation_id),
    do: {:error, Error.new(:invalid)}

  defp load_material(adapters, runtime, session) do
    call_adapter(adapters.operation_scope, :with_read_request, [
      runtime,
      session,
      @prepare_requirement,
      fn repo ->
        call_adapter(adapters.repository, :load_vault_rotation_material, [
          repo,
          %{
            session_id: session.session_id,
            principal_id: session.principal_id,
            vault_id: session.vault_id
          }
        ])
      end
    ])
  end

  defp rotation_request(
         adapters,
         session,
         %{
           vault_key_version: %{
             id: current_version_id,
             generation: current_version_generation
           },
           vault_wrapper: %{
             vault_key_version_id: current_version_id,
             generation: current_wrapper_generation,
             wrapper_algorithm: wrapper_algorithm,
             wrapped_key: current_wrapped_key
           },
           domain_key_versions: domain_versions
         },
         <<_::binary-size(32)>> = vault_kek
       )
       when is_integer(current_version_generation) and
              is_integer(current_wrapper_generation) and is_list(domain_versions) do
    next_version_id = adapters.id_generator.()

    request = %{
      session_id: session.session_id,
      principal_id: session.principal_id,
      vault_id: session.vault_id,
      principal_authorization_epoch: session.principal_authorization_epoch,
      vault_authorization_epoch: session.vault_authorization_epoch,
      vault_kek: vault_kek,
      current_vault_wrapper: %{
        algorithm: wrapper_algorithm,
        generation: current_wrapper_generation,
        vault_key_version_id: current_version_id,
        wrapped_key: current_wrapped_key
      },
      current_vault_key_version_generation: current_version_generation,
      next_vault_key_version_id: next_version_id,
      next_vault_key_version_generation: current_version_generation + 1,
      next_vault_wrapper_generation: current_wrapper_generation + 1,
      active_domain_versions:
        Enum.map(domain_versions, fn version ->
          Map.take(version, [
            :id,
            :key_domain_id,
            :generation,
            :algorithm,
            :wrapped_key
          ])
        end)
    }

    if valid_uuid?(next_version_id), do: {:ok, request}, else: {:error, Error.new(:invalid)}
  end

  defp rotation_request(_adapters, _session, _material, _vault_kek),
    do: {:error, Error.new(:invalid)}

  defp persist_while_revoking(
         adapters,
         runtime,
         session,
         selector,
         revoke_token,
         plan,
         audit
       ) do
    try do
      with :ok <- call_adapter(adapters.custodian, :await_revoking, [selector]) do
        call_adapter(adapters.operation_scope, :with_exclusive_request, [
          runtime,
          session,
          @persist_requirement,
          fn repo ->
            call_adapter(adapters.repository, :rotate_vault_key_and_audit, [
              repo,
              %{
                session_id: session.session_id,
                principal_id: session.principal_id,
                vault_id: session.vault_id,
                plan: plan,
                audit: audit
              }
            ])
          end
        ])
      end
    after
      _finish_result =
        call_adapter(adapters.custodian, :finish_revoke, [revoke_token])
    end
  end

  defp rotation_result(:ok, session), do: {:ok, SessionContext.locked(session)}

  defp rotation_result({:ok, _active}, session),
    do: {:ok, SessionContext.locked(session)}

  defp rotation_result({:error, %Error{}} = error, _session), do: error

  defp rotation_result(_invalid, _session),
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp rotation_audit(adapters, session, correlation_id) do
    AuditEvent.new(%{
      audit_event_id: adapters.id_generator.(),
      actor_kind: :principal,
      principal_id: session.principal_id,
      vault_id: session.vault_id,
      anonymous_fingerprint: nil,
      system_principal_name: nil,
      action: "vault.key_rotated",
      result: :completed,
      classification: :restricted,
      correlation_id: correlation_id,
      target_type: "vault",
      target_id: session.vault_id,
      occurred_at: adapters.utc_now.(),
      metadata: %{}
    })
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

  defp validate_kdf_parameters(_parameters),
    do: {:error, Error.new(:invalid)}

  defp adapters(runtime) do
    required = [:custodian, :repository, :key_deriver]

    if Enum.all?(required, &(Map.get(runtime, &1) not in [nil, false])) and
         is_function(Map.get(runtime, :id_generator), 0) and
         is_function(Map.get(runtime, :utc_now), 0) do
      {:ok,
       %{
         custodian: runtime.custodian,
         id_generator: runtime.id_generator,
         key_deriver: runtime.key_deriver,
         operation_scope: Map.get(runtime, :operation_scope, OperationScope),
         repository: runtime.repository,
         utc_now: runtime.utc_now
       }}
    else
      {:error, Error.new(:invalid)}
    end
  end

  defp valid_uuid?(value),
    do: match?({:ok, ^value}, Ecto.UUID.cast(value))

  defp call_adapter(module, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, arguments)
  end

  defp call_adapter({module, context}, function, arguments)
       when is_atom(module) and not is_nil(module) do
    apply(module, function, [context | arguments])
  end
end
