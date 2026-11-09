defmodule Singularity.Runtime.RotateDomainKey do
  @moduledoc "Opaque, pending-to-active domain-key rotation orchestration."

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

  @spec run(map(), SessionContext.t(), String.t(), String.t()) ::
          {:ok, SessionContext.t()} | {:error, Error.t()}
  def run(
        runtime,
        %SessionContext{unlocked?: true} = session,
        key_domain_id,
        correlation_id
      )
      when is_map(runtime) and is_binary(key_domain_id) and
             is_binary(correlation_id) do
    with true <- valid_uuid?(key_domain_id),
         true <- valid_uuid?(correlation_id),
         {:ok, adapters} <- adapters(runtime),
         {:ok, material} <-
           load_material(adapters, runtime, session, key_domain_id),
         {:ok, request} <-
           rotation_request(adapters, session, key_domain_id, material),
         {:ok, plan} <-
           call_adapter(adapters.custodian, :prepare_domain_rotation, [request]),
         {:ok, audit} <-
           rotation_audit(adapters, session, key_domain_id, correlation_id),
         selector = %{vault_id: session.vault_id},
         {:ok, revoke_token} <-
           call_adapter(adapters.custodian, :begin_revoke, [selector]),
         result <-
           persist_while_revoking(
             adapters,
             runtime,
             session,
             key_domain_id,
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

  def run(_runtime, _session, _key_domain_id, _correlation_id),
    do: {:error, Error.new(:invalid)}

  defp load_material(adapters, runtime, session, key_domain_id) do
    call_adapter(adapters.operation_scope, :with_read_request, [
      runtime,
      session,
      @prepare_requirement,
      fn repo ->
        call_adapter(adapters.repository, :load_domain_rotation_material, [
          repo,
          %{
            session_id: session.session_id,
            principal_id: session.principal_id,
            vault_id: session.vault_id,
            key_domain_id: key_domain_id
          }
        ])
      end
    ])
  end

  defp rotation_request(
         adapters,
         session,
         key_domain_id,
         %{
           domain_key_version: %{
             id: current_version_id,
             vault_key_version_id: vault_key_version_id,
             key_domain_id: material_domain_id,
             generation: current_generation,
             algorithm: domain_algorithm,
             wrapped_key: wrapped_domain_key
           },
           dedup_key_wrapper: %{
             algorithm: dedup_algorithm,
             wrapped_key: wrapped_dedup_key
           },
           asset_envelopes: envelopes
         }
       )
       when material_domain_id == key_domain_id and is_integer(current_generation) and
              is_list(envelopes) do
    next_version_id = adapters.id_generator.()

    request = %{
      session_id: session.session_id,
      principal_id: session.principal_id,
      vault_id: session.vault_id,
      principal_authorization_epoch: session.principal_authorization_epoch,
      vault_authorization_epoch: session.vault_authorization_epoch,
      key_domain_id: key_domain_id,
      current_domain_wrapper: %{
        id: current_version_id,
        vault_key_version_id: vault_key_version_id,
        generation: current_generation,
        algorithm: domain_algorithm,
        wrapped_key: wrapped_domain_key
      },
      current_dedup_wrapper: %{
        algorithm: dedup_algorithm,
        wrapped_key: wrapped_dedup_key
      },
      next_domain_key_version_id: next_version_id,
      next_domain_key_generation: current_generation + 1,
      active_asset_envelopes:
        Enum.map(envelopes, fn envelope ->
          Map.take(envelope, [
            :id,
            :asset_object_id,
            :domain_key_version_id,
            :classification,
            :algorithm,
            :key_generation,
            :wrapped_dek
          ])
        end)
    }

    if valid_uuid?(next_version_id), do: {:ok, request}, else: {:error, Error.new(:invalid)}
  end

  defp rotation_request(_adapters, _session, _key_domain_id, _material),
    do: {:error, Error.new(:invalid)}

  defp persist_while_revoking(
         adapters,
         runtime,
         session,
         key_domain_id,
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
            call_adapter(adapters.repository, :rotate_domain_key_and_audit, [
              repo,
              %{
                session_id: session.session_id,
                principal_id: session.principal_id,
                vault_id: session.vault_id,
                key_domain_id: key_domain_id,
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

  defp rotation_audit(adapters, session, key_domain_id, correlation_id) do
    AuditEvent.new(%{
      audit_event_id: adapters.id_generator.(),
      actor_kind: :principal,
      principal_id: session.principal_id,
      vault_id: session.vault_id,
      anonymous_fingerprint: nil,
      system_principal_name: nil,
      action: "domain.key_rotated",
      result: :completed,
      classification: :restricted,
      correlation_id: correlation_id,
      target_type: "domain",
      target_id: key_domain_id,
      occurred_at: adapters.utc_now.(),
      metadata: %{}
    })
  end

  defp adapters(runtime) do
    required = [:custodian, :repository]

    if Enum.all?(required, &(Map.get(runtime, &1) not in [nil, false])) and
         is_function(Map.get(runtime, :id_generator), 0) and
         is_function(Map.get(runtime, :utc_now), 0) do
      {:ok,
       %{
         custodian: runtime.custodian,
         id_generator: runtime.id_generator,
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
