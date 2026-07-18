defmodule Singularity.Runtime.LockVaultTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.LockVault
  alias Singularity.Runtime.SessionContext

  defmodule Recorder do
    use Agent

    def start_link(_options), do: Agent.start_link(fn -> %{events: [], result: :ok} end)

    def record(agent, event),
      do: Agent.update(agent, &update_in(&1.events, fn events -> events ++ [event] end))

    def events(agent), do: Agent.get(agent, & &1.events)
    def result(agent), do: Agent.get(agent, & &1.result)
    def set_result(agent, result), do: Agent.update(agent, &%{&1 | result: result})
  end

  defmodule Custodian do
    def begin_revoke(recorder, selector) do
      token = make_ref()
      Recorder.record(recorder, {:begin_revoke, selector, token})
      {:ok, token}
    end

    def await_revoking(recorder, selector) do
      Recorder.record(recorder, {:await_revoking, selector})
      :ok
    end

    def finish_revoke(recorder, token) do
      Recorder.record(recorder, {:finish_revoke, token})
      :ok
    end
  end

  defmodule Scope do
    def with_exclusive_request(recorder, runtime, _session, requirement, callback) do
      Recorder.record(recorder, {:scope, requirement})
      callback.({:repo, runtime})
    end
  end

  defmodule Vaults do
    def lock_and_audit(recorder, _repo, command) do
      Recorder.record(recorder, {:persist, command})
      Recorder.result(recorder)
    end
  end

  defmodule IdleVaultLock do
    def with_exclusive(recorder, _repo, vault_id, callback) do
      Recorder.record(recorder, {:vault_exclusive, vault_id})
      callback.(:pinned_repo)
    end
  end

  defmodule IdleAuthorizationLock do
    def with_exclusive(recorder, :pinned_repo, principal_id, vault_id, callback) do
      Recorder.record(
        recorder,
        {:authorization_exclusive, principal_id, vault_id}
      )

      callback.(:locked_repo)
    end
  end

  defmodule IdleScopedRepo do
    def transact(recorder, :locked_repo, context, callback) do
      Recorder.record(recorder, {:transaction, context})
      callback.(:scoped_repo)
    end
  end

  setup do
    recorder = start_supervised!({Recorder, []})

    runtime = %{
      custodian: {Custodian, recorder},
      operation_scope: {Scope, recorder},
      vaults: {Vaults, recorder}
    }

    session = %SessionContext{
      session_id: "session-1",
      account_id: "account-1",
      principal_id: "principal-1",
      vault_id: "vault-1",
      expires_at: DateTime.add(DateTime.utc_now(), 300),
      authorization_epoch: 4,
      unlocked?: true
    }

    {:ok, recorder: recorder, runtime: runtime, session: session}
  end

  test "revokes custody before waiting for exclusive database locks", %{
    recorder: recorder,
    runtime: runtime,
    session: session
  } do
    assert {:ok, %SessionContext{unlocked?: false}} =
             LockVault.run(runtime, session, "correlation-1")

    assert [
             {:begin_revoke, %{vault_id: "vault-1"}, token},
             {:await_revoking, %{vault_id: "vault-1"}},
             {:scope, requirement},
             {:persist, command},
             {:finish_revoke, finished_token}
           ] = Recorder.events(recorder)

    assert finished_token == token

    assert requirement == %{
             required_capability: "vault.lock",
             classification: :private,
             requires_unlocked?: false
           }

    assert command == %{
             session_id: "session-1",
             principal_id: "principal-1",
             vault_id: "vault-1",
             correlation_id: "correlation-1"
           }
  end

  test "database failure never restores already-revoked custody", %{
    recorder: recorder,
    runtime: runtime,
    session: session
  } do
    Recorder.set_result(recorder, {:error, Error.new(:storage_unavailable)})

    assert {:error, %Error{code: :storage_unavailable}} =
             LockVault.run(runtime, session, "correlation-1")

    assert [
             {:begin_revoke, _, token},
             {:await_revoking, _},
             {:scope, _},
             {:persist, _},
             {:finish_revoke, finished_token}
           ] = Recorder.events(recorder)

    assert finished_token == token
  end

  test "idle timeout persists an audited lock after custody has already been removed", %{
    recorder: recorder
  } do
    runtime = %{
      request_repo: __MODULE__,
      vault_lock: {IdleVaultLock, recorder},
      authorization_lock: {IdleAuthorizationLock, recorder},
      scoped_repo: {IdleScopedRepo, recorder},
      vaults: {Vaults, recorder}
    }

    assert :ok =
             LockVault.idle_lock(runtime, %{
               session_id: "session-1",
               principal_id: "principal-1",
               vault_id: "vault-1",
               reason: :idle_timeout
             })

    assert [
             {:vault_exclusive, "vault-1"},
             {:authorization_exclusive, "principal-1", "vault-1"},
             {:transaction, %{principal_id: "principal-1", vault_id: "vault-1"}},
             {:persist,
              %{
                session_id: "session-1",
                principal_id: "principal-1",
                vault_id: "vault-1",
                correlation_id: correlation_id,
                reason: :idle_timeout
              }}
           ] = Recorder.events(recorder)

    assert {:ok, _uuid} = Ecto.UUID.cast(correlation_id)
  end
end
