defmodule Singularity.Runtime.KeyRotationRuntimeTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.RotateDomainKey
  alias Singularity.Runtime.RotateVaultKey
  alias Singularity.Runtime.SessionContext

  @session_id "00000000-0000-4000-8000-000000007001"
  @account_id "00000000-0000-4000-8000-000000007002"
  @principal_id "00000000-0000-4000-8000-000000007003"
  @vault_id "00000000-0000-4000-8000-000000007004"
  @domain_id "00000000-0000-4000-8000-000000007005"
  @domain_version_id "00000000-0000-4000-8000-000000007008"
  @correlation_id "00000000-0000-4000-8000-000000007012"
  @kek :binary.copy(<<0xA1>>, 32)
  @raw_vault_key :binary.copy(<<0xB2>>, 32)
  @raw_domain_key :binary.copy(<<0xC3>>, 32)
  @raw_dedup_key :binary.copy(<<0xD4>>, 32)
  @raw_dek :binary.copy(<<0xE5>>, 32)

  defmodule State do
    use Agent

    def start_link(_options) do
      Agent.start_link(fn -> %{events: [], persist: :ok} end)
    end

    def push(pid, event),
      do: Agent.update(pid, &update_in(&1.events, fn events -> events ++ [event] end))

    def events(pid), do: Agent.get(pid, & &1.events)
    def persist(pid), do: Agent.get(pid, & &1.persist)
    def fail(pid, error), do: Agent.update(pid, &%{&1 | persist: {:error, error}})
  end

  defmodule Scope do
    def with_read_request(state, runtime, _session, requirement, callback) do
      State.push(state, {:read_scope, requirement})
      callback.({:read_repo, runtime})
    end

    def with_exclusive_request(state, runtime, _session, requirement, callback) do
      State.push(state, {:exclusive_scope, requirement})
      callback.({:write_repo, runtime})
    end
  end

  defmodule Repository do
    @account_id "00000000-0000-4000-8000-000000007002"
    @vault_id "00000000-0000-4000-8000-000000007004"
    @domain_id "00000000-0000-4000-8000-000000007005"
    @vault_version_id "00000000-0000-4000-8000-000000007006"
    @vault_wrapper_id "00000000-0000-4000-8000-000000007007"
    @domain_version_id "00000000-0000-4000-8000-000000007008"
    @dedup_wrapper_id "00000000-0000-4000-8000-000000007009"
    @object_id "00000000-0000-4000-8000-000000007010"
    @envelope_id "00000000-0000-4000-8000-000000007011"

    def load_vault_rotation_material(state, _repo, command) do
      State.push(state, {:load_vault, command})

      {:ok,
       %{
         vault_key_version: %{
           id: @vault_version_id,
           generation: 3,
           algorithm: "aes_256_gcm"
         },
         vault_wrapper: %{
           id: @vault_wrapper_id,
           account_id: @account_id,
           vault_key_version_id: @vault_version_id,
           generation: 9,
           kdf_version: 1,
           kdf_salt: :binary.copy(<<0x11>>, 16),
           kdf_parameters: %{
             "version" => 1,
             "t_cost" => 3,
             "m_cost" => 16,
             "parallelism" => 1
           },
           wrapper_algorithm: "aes_256_gcm",
           wrapped_key: "current-vault-wrapper"
         },
         domain_key_versions: [
           %{
             id: @domain_version_id,
             key_domain_id: @domain_id,
             generation: 5,
             algorithm: "aes_256_gcm",
             wrapped_key: "current-domain-wrapper"
           }
         ]
       }}
    end

    def rotate_vault_key_and_audit(state, _repo, command) do
      State.push(state, {:persist_vault, command})
      State.persist(state)
    end

    def load_domain_rotation_material(state, _repo, command) do
      State.push(state, {:load_domain, command})

      {:ok,
       %{
         domain_key_version: %{
           id: @domain_version_id,
           vault_id: @vault_id,
           key_domain_id: @domain_id,
           vault_key_version_id: @vault_version_id,
           generation: 5,
           classification: :private,
           algorithm: "aes_256_gcm",
           wrapped_key: "current-domain-wrapper"
         },
         dedup_key_wrapper: %{
           id: @dedup_wrapper_id,
           domain_key_version_id: @domain_version_id,
           algorithm: "aes_256_gcm",
           wrapped_key: "current-dedup-wrapper"
         },
         asset_envelopes: [
           %{
             id: @envelope_id,
             asset_object_id: @object_id,
             domain_key_version_id: @domain_version_id,
             key_domain_id: @domain_id,
             classification: :private,
             algorithm: "aes_256_gcm",
             key_generation: 5,
             wrapped_dek: "current-object-wrapper"
           }
         ]
       }}
    end

    def rotate_domain_key_and_audit(state, _repo, command) do
      State.push(state, {:persist_domain, command})
      State.persist(state)
    end
  end

  defmodule KeyDeriver do
    @kek :binary.copy(<<0xA1>>, 32)

    def derive(state, password, salt, parameters) do
      State.push(state, {:derive, password, salt, parameters})

      if password == "correct password",
        do: {:ok, @kek},
        else: {:ok, :binary.copy(<<0xFF>>, 32)}
    end
  end

  defmodule Custodian do
    @kek :binary.copy(<<0xA1>>, 32)

    def prepare_vault_rotation(state, request) do
      State.push(state, {:prepare_vault, request})

      if request.vault_kek == @kek do
        {:ok,
         %{
           next_vault_key_version_id: request.next_vault_key_version_id,
           next_vault_key_version_generation: request.next_vault_key_version_generation,
           next_vault_wrapper_generation: request.next_vault_wrapper_generation,
           vault_wrapper: %{
             generation: request.next_vault_wrapper_generation,
             algorithm: "aes_256_gcm",
             wrapped_key: "next-vault-wrapper"
           },
           domain_versions:
             Enum.map(request.active_domain_versions, fn version ->
               %{
                 id: version.id,
                 key_domain_id: version.key_domain_id,
                 generation: version.generation,
                 algorithm: "aes_256_gcm",
                 expected_wrapped_key: version.wrapped_key,
                 wrapped_key: "next-domain-wrapper"
               }
             end)
         }}
      else
        {:error, Error.new(:integrity_failure)}
      end
    end

    def prepare_domain_rotation(state, request) do
      State.push(state, {:prepare_domain, request})

      {:ok,
       %{
         next_domain_key_version_id: request.next_domain_key_version_id,
         next_domain_key_generation: request.next_domain_key_generation,
         domain_wrapper: %{
           algorithm: "aes_256_gcm",
           wrapped_key: "next-domain-wrapper",
           vault_key_version_id: request.current_domain_wrapper.vault_key_version_id
         },
         dedup_wrapper: %{
           algorithm: "aes_256_gcm",
           wrapped_key: "next-dedup-wrapper"
         },
         asset_envelopes:
           Enum.map(request.active_asset_envelopes, fn envelope ->
             %{
               expected_envelope_id: envelope.id,
               asset_object_id: envelope.asset_object_id,
               expected_key_generation: envelope.key_generation,
               classification: envelope.classification,
               algorithm: "aes_256_gcm",
               key_generation: request.next_domain_key_generation,
               wrapped_dek: "next-object-wrapper"
             }
           end)
       }}
    end

    def begin_revoke(state, selector) do
      State.push(state, {:begin_revoke, selector})
      {:ok, make_ref()}
    end

    def await_revoking(state, selector) do
      State.push(state, {:await_revoking, selector})
      :ok
    end

    def finish_revoke(state, token) do
      State.push(state, {:finish_revoke, token})
      :ok
    end
  end

  setup do
    state = start_supervised!({State, []})

    runtime = %{
      custodian: {Custodian, state},
      id_generator: &Ecto.UUID.generate/0,
      key_deriver: {KeyDeriver, state},
      operation_scope: {Scope, state},
      repository: {Repository, state},
      utc_now: fn -> ~U[2026-07-27 12:34:56.123456Z] end
    }

    session = %SessionContext{
      session_id: @session_id,
      account_id: @account_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      expires_at: ~U[2026-07-27 13:34:56.123456Z],
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: true
    }

    {:ok, runtime: runtime, session: session, state: state}
  end

  test "vault rotation prepares opaque wrappers, persists once, audits, and locks custody",
       context do
    assert {:ok, %SessionContext{unlocked?: false}} =
             RotateVaultKey.run(
               context.runtime,
               context.session,
               "correct password",
               @correlation_id
             )

    assert [
             {:read_scope, requirement},
             {:load_vault, load},
             {:derive, "correct password", _salt, _parameters},
             {:prepare_vault, preparation},
             {:begin_revoke, selector},
             {:await_revoking, awaited_selector},
             {:exclusive_scope, persist_requirement},
             {:persist_vault, command},
             {:finish_revoke, revoke_token}
           ] = State.events(context.state)

    assert is_reference(revoke_token)
    assert awaited_selector == selector
    assert persist_requirement == %{requirement | requires_unlocked?: false}
    assert selector == %{vault_id: @vault_id}
    assert requirement.required_capability == "vault.password_change"
    assert requirement.classification == :restricted
    assert requirement.requires_unlocked?
    assert load.session_id == @session_id
    assert load.principal_id == @principal_id
    assert load.vault_id == @vault_id
    assert preparation.session_id == @session_id
    assert preparation.vault_kek == @kek
    assert command.audit.action == "vault.key_rotated"
    assert command.audit.result == :completed
    assert command.audit.correlation_id == @correlation_id
    assert command.audit.target_id == @vault_id
    assert command.plan.next_vault_key_version_generation == 4
    assert command.plan.next_vault_wrapper_generation == 10
    assert command.plan.vault_wrapper.wrapped_key == "next-vault-wrapper"
    assert [%{wrapped_key: "next-domain-wrapper"}] = command.plan.domain_versions
    refute secret?(command)
  end

  test "domain rotation rewraps the complete opaque child set and locks custody", context do
    assert {:ok, %SessionContext{unlocked?: false}} =
             RotateDomainKey.run(
               context.runtime,
               context.session,
               @domain_id,
               @correlation_id
             )

    assert [
             {:read_scope, requirement},
             {:load_domain, load},
             {:prepare_domain, preparation},
             {:begin_revoke, selector},
             {:await_revoking, awaited_selector},
             {:exclusive_scope, persist_requirement},
             {:persist_domain, command},
             {:finish_revoke, revoke_token}
           ] = State.events(context.state)

    assert is_reference(revoke_token)
    assert awaited_selector == selector
    assert persist_requirement == %{requirement | requires_unlocked?: false}
    assert selector == %{vault_id: @vault_id}
    assert requirement.required_capability == "vault.password_change"
    assert requirement.classification == :restricted
    assert requirement.requires_unlocked?
    assert load.key_domain_id == @domain_id
    assert preparation.current_domain_wrapper.id == @domain_version_id
    assert command.audit.action == "domain.key_rotated"
    assert command.audit.target_id == @domain_id
    assert command.plan.next_domain_key_generation == 6
    assert command.plan.dedup_wrapper.wrapped_key == "next-dedup-wrapper"
    assert [%{wrapped_dek: "next-object-wrapper"}] = command.plan.asset_envelopes
    refute secret?(command)
  end

  test "wrong vault password never revokes or persists", context do
    assert {:error, %Error{code: :integrity_failure}} =
             RotateVaultKey.run(
               context.runtime,
               context.session,
               "wrong password",
               @correlation_id
             )

    events = State.events(context.state)
    refute Enum.any?(events, &match?({:begin_revoke, _}, &1))
    refute Enum.any?(events, &match?({:persist_vault, _}, &1))
  end

  test "persistence failure still closes the revocation boundary", context do
    State.fail(context.state, Error.new(:conflict))

    assert {:error, %Error{code: :conflict}} =
             RotateDomainKey.run(
               context.runtime,
               context.session,
               @domain_id,
               @correlation_id
             )

    assert Enum.any?(State.events(context.state), &match?({:persist_domain, _}, &1))
    assert Enum.any?(State.events(context.state), &match?({:finish_revoke, _}, &1))
  end

  defp secret?(term) do
    encoded = :erlang.term_to_binary(term)

    Enum.any?(
      [@kek, @raw_vault_key, @raw_domain_key, @raw_dedup_key, @raw_dek],
      &(:binary.match(encoded, &1) != :nomatch)
    )
  end
end
