defmodule Singularity.Runtime.ChangePasswordTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.ChangePassword
  alias Singularity.Runtime.SessionContext

  defmodule State do
    use Agent

    def start_link(_options), do: Agent.start_link(fn -> %{events: [], persist: :ok} end)

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

    def with_shared_request(state, runtime, _session, requirement, callback) do
      State.push(state, {:shared_scope, requirement})
      callback.({:write_repo, runtime})
    end
  end

  defmodule Identity do
    def load_password_material(state, _repo, command) do
      State.push(state, {:load, command})

      {:ok,
       %{
         credential_id: "credential-1",
         credential_revision: ~U[2026-07-18 08:00:00Z],
         vault_wrapper: %{
           id: "wrapper-1",
           vault_key_version_id: "vault-version-1",
           generation: 2,
           kdf_salt: :binary.copy(<<0x11>>, 16),
           kdf_parameters: %{
             "version" => 1,
             "t_cost" => 3,
             "m_cost" => 16,
             "parallelism" => 1
           },
           wrapped_key: "old-wrapped-vault-key"
         }
       }}
    end

    def change_password_and_wrapper(state, _repo, command) do
      State.push(state, {:persist, command})
      State.persist(state)
    end
  end

  defmodule KeyDeriver do
    def derive(state, password, salt, parameters) do
      State.push(state, {:derive, password, salt, parameters})

      case password do
        "old-password" -> {:ok, :binary.copy(<<0xAA>>, 32)}
        "new-password" -> {:ok, :binary.copy(<<0xDD>>, 32)}
        _other -> {:ok, :binary.copy(<<0xEE>>, 32)}
      end
    end
  end

  defmodule PasswordHasher do
    def hash(state, password) do
      State.push(state, {:hash, password})
      {:ok, "new-credential-verifier"}
    end
  end

  defmodule KeyWrapper do
    def unwrap(state, key, "old-wrapped-vault-key", metadata) do
      State.push(state, {:unwrap, key, metadata})

      if key == :binary.copy(<<0xAA>>, 32) do
        {:ok, :binary.copy(<<0xBB>>, 32)}
      else
        {:error, Error.new(:integrity_failure)}
      end
    end

    def wrap(state, key, vault_key, metadata) do
      State.push(state, {:wrap, key, vault_key, metadata})

      {:ok,
       %{
         algorithm: :aes_256_gcm,
         encoded: "new-wrapped-vault-key",
         generation: metadata.generation,
         purpose: metadata.purpose,
         version: 1
       }}
    end
  end

  defmodule Custodian do
    def begin_revoke(state, selector) do
      State.push(state, {:begin_revoke, selector})
      :ok
    end

    def await_revoking(state, selector) do
      State.push(state, {:await_revoking, selector})
      :ok
    end
  end

  setup do
    state = start_supervised!({State, []})

    runtime = %{
      custodian: {Custodian, state},
      identity: {Identity, state},
      key_deriver: {KeyDeriver, state},
      key_wrapper: {KeyWrapper, state},
      operation_scope: {Scope, state},
      password_hasher: {PasswordHasher, state},
      random_bytes: fn 16 -> :binary.copy(<<0x22>>, 16) end,
      vault_kdf_params: %{
        version: 1,
        t_cost: 4,
        m_cost: 17,
        parallelism: 1
      }
    }

    session = %SessionContext{
      session_id: "session-1",
      account_id: "account-1",
      principal_id: "principal-1",
      vault_id: "vault-1",
      expires_at: DateTime.add(DateTime.utc_now(), 300),
      authorization_epoch: 3,
      unlocked?: true
    }

    {:ok, runtime: runtime, session: session, state: state}
  end

  test "rewraps the same vault key and atomically replaces only credential and wrapper",
       context do
    assert {:ok, %SessionContext{unlocked?: false}} =
             ChangePassword.run(
               context.runtime,
               context.session,
               "old-password",
               "new-password",
               "correlation-1"
             )

    events = State.events(context.state)

    assert [
             {:read_scope, requirement},
             {:load, _load},
             {:derive, "old-password", _old_salt, _old_parameters},
             {:unwrap, _old_kek, unwrap_metadata},
             {:hash, "new-password"},
             {:derive, "new-password", new_salt, new_parameters},
             {:wrap, _new_kek, vault_key, wrap_metadata},
             {:begin_revoke, %{principal_id: "principal-1"}},
             {:await_revoking, %{principal_id: "principal-1"}},
             {:shared_scope, shared_requirement},
             {:persist, command}
           ] = events

    assert shared_requirement == requirement

    assert requirement == %{
             required_capability: "vault.password_change",
             classification: :private,
             requires_unlocked?: false
           }

    assert unwrap_metadata == wrap_metadata
    assert new_salt == :binary.copy(<<0x22>>, 16)
    assert new_parameters == context.runtime.vault_kdf_params
    assert vault_key == :binary.copy(<<0xBB>>, 32)

    assert command.credential_id == "credential-1"
    assert command.credential_revision == ~U[2026-07-18 08:00:00Z]
    assert command.new_verifier == "new-credential-verifier"
    assert command.wrapper_id == "wrapper-1"
    assert command.expected_wrapped_key == "old-wrapped-vault-key"
    assert command.new_wrapped_key == "new-wrapped-vault-key"
    assert command.new_kdf_salt == :binary.copy(<<0x22>>, 16)

    assert command.new_kdf_parameters == %{
             "version" => 1,
             "t_cost" => 4,
             "m_cost" => 17,
             "parallelism" => 1
           }

    refute inspect(command) =~ "old-password"
    refute inspect(command) =~ "new-password"
    refute Enum.any?(Map.values(command), &(&1 == vault_key))
    refute Map.has_key?(command, :domain_key_version)
  end

  test "wrong old passwords do not hash, wrap, revoke, or persist", context do
    assert {:error, %Error{code: :integrity_failure}} =
             ChangePassword.run(
               context.runtime,
               context.session,
               "wrong-password",
               "new-password",
               "correlation-1"
             )

    events = State.events(context.state)
    refute Enum.any?(events, &match?({:hash, _}, &1))
    refute Enum.any?(events, &match?({:wrap, _, _, _}, &1))
    refute Enum.any?(events, &match?({:begin_revoke, _}, &1))
    refute Enum.any?(events, &match?({:persist, _}, &1))
  end

  test "credential or wrapper CAS failure is returned after custody revocation", context do
    State.fail(context.state, Error.new(:conflict))

    assert {:error, %Error{code: :conflict}} =
             ChangePassword.run(
               context.runtime,
               context.session,
               "old-password",
               "new-password",
               "correlation-1"
             )

    assert Enum.any?(State.events(context.state), &match?({:begin_revoke, _}, &1))
    assert Enum.any?(State.events(context.state), &match?({:persist, _}, &1))
  end
end
