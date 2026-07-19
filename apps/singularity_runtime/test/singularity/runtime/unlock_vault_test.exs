defmodule Singularity.Runtime.UnlockVaultTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLeaseSupervisor
  alias Singularity.Runtime.SessionContext
  alias Singularity.Runtime.UnlockVault

  defmodule State do
    use Agent

    def start_link(options) do
      Agent.start_link(fn ->
        %{
          activation_result: :ok,
          events: [],
          persistence_result: :ok,
          test: Keyword.fetch!(options, :test)
        }
      end)
    end

    def push(pid, event),
      do: Agent.update(pid, &update_in(&1.events, fn events -> events ++ [event] end))

    def events(pid), do: Agent.get(pid, & &1.events)
    def get(pid, key), do: Agent.get(pid, &Map.fetch!(&1, key))
    def put(pid, key, value), do: Agent.update(pid, &Map.put(&1, key, value))
  end

  defmodule Scope do
    def with_read_request(state, runtime, _session, requirement, callback) do
      State.push(state, {:read_scope, requirement})
      callback.({:read_repo, runtime})
    end

    def with_shared_request(state, runtime, _session, requirement, callback) do
      State.push(state, {:shared_scope, requirement})

      case callback.({:write_repo, runtime}) do
        {:after_commit, after_commit} ->
          State.push(state, :committed)
          after_commit.()

        result ->
          result
      end
    end
  end

  defmodule Vaults do
    def load_unlock_material(state, _repo, command) do
      State.push(state, {:load, command})

      {:ok,
       %{
         vault_wrapper: %{
           id: "wrapper-1",
           vault_key_version_id: "vault-version-1",
           generation: 3,
           kdf_salt: :binary.copy(<<0x11>>, 16),
           kdf_parameters: %{
             "version" => 1,
             "t_cost" => 3,
             "m_cost" => 16,
             "parallelism" => 1
           },
           wrapped_key: "wrapped-vault-key"
         },
         domain_key_version: %{
           id: "domain-version-1",
           key_domain_id: "domain-1",
           classification: :private,
           generation: 5,
           wrapped_key: "wrapped-domain-key"
         },
         domain_dedup_key_wrapper: %{
           id: "dedup-wrapper-1",
           domain_key_version_id: "domain-version-1",
           key_domain_id: "domain-1",
           algorithm: "aes_256_gcm",
           wrapped_key: "wrapped-dedup-key"
         }
       }}
    end

    def unlock_and_audit(state, _repo, command) do
      State.push(state, {:persist, command})
      State.get(state, :persistence_result)
    end
  end

  defmodule KeyDeriver do
    def derive(state, password, salt, parameters) do
      State.push(state, {:derive, password, salt, parameters})

      if password == "correct-password" do
        {:ok, :binary.copy(<<0xAA>>, 32)}
      else
        {:ok, :binary.copy(<<0xEE>>, 32)}
      end
    end
  end

  defmodule KeyWrapper do
    def unwrap(state, key, "wrapped-vault-key", metadata) do
      State.push(state, {:unwrap_vault, key, metadata})

      if key == :binary.copy(<<0xAA>>, 32) do
        {:ok, :binary.copy(<<0xBB>>, 32)}
      else
        {:error, Error.new(:integrity_failure)}
      end
    end

    def unwrap(state, key, "wrapped-domain-key", metadata) do
      State.push(state, {:unwrap_domain, key, metadata})

      if key == :binary.copy(<<0xBB>>, 32) do
        {:ok, :binary.copy(<<0xCC>>, 32)}
      else
        {:error, Error.new(:integrity_failure)}
      end
    end

    def unwrap(state, key, "wrapped-dedup-key", metadata) do
      State.push(state, {:unwrap_dedup, key, metadata})

      if key == :binary.copy(<<0xCC>>, 32) do
        {:ok, :binary.copy(<<0xDD>>, 32)}
      else
        {:error, Error.new(:integrity_failure)}
      end
    end
  end

  defmodule Custodian do
    def prepare_unlock(state, custody) do
      State.push(state, {:prepare, custody})
      {:ok, make_ref()}
    end

    def activate_unlock(state, pending) do
      State.push(state, {:activate, pending})
      State.get(state, :activation_result)
    end

    def discard_pending(state, pending) do
      State.push(state, {:discard, pending})
      :ok
    end
  end

  defmodule Clock do
    def utc_now(_context), do: DateTime.utc_now()
  end

  setup context do
    state = start_supervised!({State, test: context.test})

    runtime = %{
      custodian: {Custodian, state},
      key_deriver: {KeyDeriver, state},
      key_wrapper: {KeyWrapper, state},
      operation_scope: {Scope, state},
      vaults: {Vaults, state}
    }

    session = %SessionContext{
      session_id: "session-1",
      account_id: "account-1",
      principal_id: "principal-1",
      vault_id: "vault-1",
      expires_at: DateTime.add(DateTime.utc_now(), 300),
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      authorization_epoch: 7,
      unlocked?: false
    }

    {:ok, runtime: runtime, session: session, state: state}
  end

  test "activates prepared custody only after unlock state and audit commit", context do
    assert {:ok, %SessionContext{unlocked?: true}} =
             UnlockVault.run(
               context.runtime,
               context.session,
               "correct-password",
               "correlation-1"
             )

    events = State.events(context.state)

    assert [
             {:read_scope, requirement},
             {:load, load_command},
             {:derive, "correct-password", _salt, _parameters},
             {:unwrap_vault, _kek, vault_metadata},
             {:unwrap_domain, _vault_key, domain_metadata},
             {:unwrap_dedup, _domain_key, dedup_metadata},
             {:prepare, custody},
             {:shared_scope, shared_requirement},
             {:persist, persist_command},
             :committed,
             {:activate, pending},
             {:discard, discarded}
           ] = events

    assert shared_requirement == requirement
    assert discarded == pending

    assert requirement == %{
             required_capability: "vault.unlock",
             classification: :private,
             requires_unlocked?: false
           }

    assert load_command == %{
             session_id: "session-1",
             account_id: "account-1",
             principal_id: "principal-1",
             vault_id: "vault-1"
           }

    assert vault_metadata == %{
             purpose: :vault_key,
             generation: 3,
             aad: "vault-1"
           }

    assert domain_metadata == %{
             purpose: :domain_key,
             generation: 5,
             aad: "vault-1:domain-1"
           }

    assert dedup_metadata == %{
             purpose: :domain_dedup_key,
             generation: 5,
             aad: "domain-1"
           }

    assert custody.session_id == "session-1"
    assert custody.principal_id == "principal-1"
    assert custody.vault_id == "vault-1"
    assert custody.principal_authorization_epoch == 7
    assert custody.vault_authorization_epoch == 23
    refute Map.has_key?(custody, :authorization_epoch)
    assert byte_size(custody.vault_key) == 32
    assert byte_size(custody.domain_key) == 32
    assert byte_size(custody.domain_dedup_key) == 32
    assert custody.key_domain_id == "domain-1"
    assert custody.domain_key_version_id == "domain-version-1"
    assert custody.domain_key_generation == 5
    assert custody.domain_classification == :private
    refute Map.has_key?(custody, :object_dek)

    assert persist_command == %{
             session_id: "session-1",
             principal_id: "principal-1",
             vault_id: "vault-1",
             wrapper_id: "wrapper-1",
             wrapper_generation: 3,
             vault_key_version_id: "vault-version-1",
             domain_key_version_id: "domain-version-1",
             correlation_id: "correlation-1"
           }

    refute inspect(persist_command) =~ "correct-password"
    refute Enum.any?(Map.values(persist_command), &match?(<<_::binary-size(32)>>, &1))
  end

  test "wrong passwords never prepare custody or enter the mutation scope", context do
    assert {:error, %Error{code: :integrity_failure}} =
             UnlockVault.run(
               context.runtime,
               context.session,
               "wrong-password",
               "correlation-1"
             )

    events = State.events(context.state)
    refute Enum.any?(events, &match?({:prepare, _}, &1))
    refute Enum.any?(events, &match?({:shared_scope, _}, &1))
  end

  test "transaction and audit failures discard unresolved custody", context do
    State.put(
      context.state,
      :persistence_result,
      {:error, Error.new(:storage_unavailable)}
    )

    assert {:error, %Error{code: :storage_unavailable}} =
             UnlockVault.run(
               context.runtime,
               context.session,
               "correct-password",
               "correlation-1"
             )

    assert [{:prepare, _custody}, {:shared_scope, _requirement}, {:persist, _}, {:discard, _}] =
             Enum.drop(State.events(context.state), 6)

    refute :committed in State.events(context.state)
    refute Enum.any?(State.events(context.state), &match?({:activate, _}, &1))
  end

  test "post-commit activation failure cannot return an unlocked session", context do
    State.put(
      context.state,
      :activation_result,
      {:error, Error.new(:vault_locked)}
    )

    assert {:error, %Error{code: :vault_locked}} =
             UnlockVault.run(
               context.runtime,
               context.session,
               "correct-password",
               "correlation-1"
             )

    events = State.events(context.state)
    assert :committed in events
    assert Enum.any?(events, &match?({:activate, _}, &1))
    assert Enum.any?(events, &match?({:discard, _}, &1))
  end

  test "wake errors fail activation closed and leave no usable lease", context do
    owner = self()

    custodian =
      start_real_custodian!(fn command ->
        send(owner, {:wake_attempted, command})
        {:error, Error.new(:storage_unavailable, retryable?: true)}
      end)

    runtime = %{context.runtime | custodian: {KeyCustodian, custodian}}

    assert {:error, %Error{code: :storage_unavailable}} =
             UnlockVault.run(
               runtime,
               context.session,
               "correct-password",
               "correlation-1"
             )

    assert_receive {:wake_attempted, %{session_id: "session-1"}}
    refute KeyCustodian.unlocked?(custodian, "session-1")

    assert {:error, :waiting_for_unlock} =
             KeyCustodian.lease(custodian, lease_request())
  end

  test "wake exceptions are contained and leave custody locked", context do
    custodian =
      start_real_custodian!(fn _command ->
        raise "injected wake failure"
      end)

    runtime = %{context.runtime | custodian: {KeyCustodian, custodian}}

    assert {:error, %Error{code: :storage_unavailable}} =
             UnlockVault.run(
               runtime,
               context.session,
               "correct-password",
               "correlation-1"
             )

    assert Process.alive?(custodian)
    refute KeyCustodian.unlocked?(custodian, "session-1")
  end

  defp start_real_custodian!(wake_waiting) do
    lease_supervisor =
      start_supervised!(
        {KeyLeaseSupervisor, name: nil},
        id: make_ref()
      )

    start_supervised!(
      {KeyCustodian,
       %{
         authorization: Fake.Authorization,
         clock: Clock,
         context: %{},
         idle_lock: fn _session -> :ok end,
         key_reader: Fake.KeyReader,
         lease_supervisor: lease_supervisor,
         object_key_loader: Fake.KeyReader,
         wake_waiting: wake_waiting
       }},
      id: make_ref()
    )
  end

  defp lease_request do
    %{
      job_id: "job-1",
      vault_id: "vault-1",
      principal_id: "principal-1",
      required_capability: "asset.read",
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 23,
      object_id: "object-1",
      object_generation: 1,
      session_id: "session-1"
    }
  end
end
