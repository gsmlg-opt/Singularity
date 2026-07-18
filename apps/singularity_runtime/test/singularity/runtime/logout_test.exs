defmodule Singularity.Runtime.LogoutTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.Logout
  alias Singularity.Runtime.SessionContext

  defmodule State do
    use Agent

    def start_link(_options), do: Agent.start_link(fn -> %{events: [], result: :ok} end)

    def push(pid, event),
      do: Agent.update(pid, &update_in(&1.events, fn events -> events ++ [event] end))

    def events(pid), do: Agent.get(pid, & &1.events)
    def result(pid), do: Agent.get(pid, & &1.result)

    def fail(pid),
      do: Agent.update(pid, &%{&1 | result: {:error, Error.new(:storage_unavailable)}})
  end

  defmodule Custodian do
    def begin_revoke(state, selector) do
      token = make_ref()
      State.push(state, {:begin_revoke, selector, token})
      {:ok, token}
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

  defmodule Scope do
    def with_exclusive_request(state, runtime, _session, requirement, callback) do
      State.push(state, {:scope, requirement})
      callback.({:repo, runtime})
    end
  end

  defmodule Identity do
    def revoke_session_and_audit(state, _repo, command) do
      State.push(state, {:persist, command})
      State.result(state)
    end
  end

  setup do
    state = start_supervised!({State, []})

    runtime = %{
      custodian: {Custodian, state},
      identity: {Identity, state},
      operation_scope: {Scope, state}
    }

    session = %SessionContext{
      session_id: "session-1",
      account_id: "account-1",
      principal_id: "principal-1",
      vault_id: "vault-1",
      expires_at: DateTime.add(DateTime.utc_now(), 300),
      authorization_epoch: 2,
      unlocked?: true
    }

    {:ok, runtime: runtime, session: session, state: state}
  end

  test "terminates custody before revoking the durable session", context do
    assert :ok = Logout.run(context.runtime, context.session, "correlation-1")

    assert [
             {:begin_revoke, %{vault_id: "vault-1"}, token},
             {:await_revoking, %{vault_id: "vault-1"}},
             {:scope,
              %{
                required_capability: "vault.lock",
                classification: :private,
                requires_unlocked?: false
              }},
             {:persist,
              %{
                session_id: "session-1",
                principal_id: "principal-1",
                vault_id: "vault-1",
                correlation_id: "correlation-1"
              }},
             {:finish_revoke, finished_token}
           ] = State.events(context.state)

    assert finished_token == token
  end

  test "a transaction or audit failure leaves custody revoked", context do
    State.fail(context.state)

    assert {:error, %Error{code: :storage_unavailable}} =
             Logout.run(context.runtime, context.session, "correlation-1")

    assert [
             {:begin_revoke, _selector, token},
             {:await_revoking, _},
             {:scope, _},
             {:persist, _},
             {:finish_revoke, finished_token}
           ] = State.events(context.state)

    assert finished_token == token
  end
end
