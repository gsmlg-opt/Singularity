defmodule Singularity.Runtime.CustodyCompensationTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLeaseSupervisor

  @session_id "session-1"
  @principal_id "principal-1"
  @vault_id "vault-1"
  @principal_authorization_epoch 7
  @vault_authorization_epoch 11

  defmodule Callbacks do
    def idle_lock(owner, session) do
      send(owner, {:idle_lock_persisted, session})
      :ok
    end

    def wake_waiting(owner, command) do
      send(owner, {:waiting_work_woken, command})
      :ok
    end
  end

  setup do
    lease_supervisor =
      start_supervised!(
        {KeyLeaseSupervisor, name: nil},
        id: make_ref()
      )

    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Fake.Authorization,
           clock: Fake.Clock,
           context: %{},
           idle_lock: {Callbacks, self()},
           idle_timeout_ms: 50,
           key_reader: Fake.KeyReader,
           lease_supervisor: lease_supervisor,
           object_key_loader: Fake.KeyReader,
           pending_ttl_ms: 500,
           wake_limit: 7,
           wake_waiting: {Callbacks, self()}
         }},
        id: make_ref()
      )

    {:ok, custodian: custodian, lease_supervisor: lease_supervisor}
  end

  test "pending custody cannot authorize until the post-commit activation", %{
    custodian: custodian
  } do
    assert {:ok, pending} = KeyCustodian.prepare_unlock(custodian, custody())
    refute KeyCustodian.unlocked?(custodian, @session_id)

    assert {:error, %Error{code: :vault_locked}} =
             KeyCustodian.assert_unlocked(
               custodian,
               @session_id,
               @principal_id,
               @vault_id,
               @principal_authorization_epoch,
               @vault_authorization_epoch
             )

    assert {:error, :waiting_for_unlock} =
             KeyCustodian.lease(custodian, lease_request())

    refute_receive {:waiting_work_woken, _command}

    assert :ok = KeyCustodian.activate_unlock(custodian, pending)
    assert KeyCustodian.unlocked?(custodian, @session_id)

    assert :ok =
             KeyCustodian.assert_unlocked(
               custodian,
               @session_id,
               @principal_id,
               @vault_id,
               @principal_authorization_epoch,
               @vault_authorization_epoch
             )

    assert_receive {:waiting_work_woken,
                    %{
                      session_id: @session_id,
                      principal_id: @principal_id,
                      vault_id: @vault_id,
                      limit: 7
                    }}

    assert :ok = KeyCustodian.discard_pending(custodian, pending)
    assert KeyCustodian.unlocked?(custodian, @session_id)
  end

  test "rollback compensation discards only unresolved pending custody", %{
    custodian: custodian
  } do
    assert {:ok, pending} = KeyCustodian.prepare_unlock(custodian, custody())
    assert :ok = KeyCustodian.discard_pending(custodian, pending)
    assert :ok = KeyCustodian.discard_pending(custodian, pending)

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.activate_unlock(custodian, pending)

    refute KeyCustodian.unlocked?(custodian, @session_id)
  end

  test "pending custody expires and is discarded when its owner dies", %{
    custodian: custodian
  } do
    owner =
      Task.async(fn ->
        {:ok, pending} = KeyCustodian.prepare_unlock(custodian, custody())
        pending
      end)

    pending = Task.await(owner)

    assert_eventually(fn ->
      match?(
        {:error, %Error{code: :conflict}},
        KeyCustodian.activate_unlock(custodian, pending)
      )
    end)

    assert {:ok, expiring} = KeyCustodian.prepare_unlock(custodian, custody())

    assert_eventually(fn ->
      match?(
        {:error, %Error{code: :conflict}},
        KeyCustodian.activate_unlock(custodian, expiring)
      )
    end)
  end

  test "foreign owners cannot activate pending custody and monitor cleanup is exact", %{
    custodian: custodian
  } do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, pending} = KeyCustodian.prepare_unlock(custodian, custody())
        send(parent, {:owned_pending, self(), pending})

        receive do
          :discard -> KeyCustodian.discard_pending(custodian, pending)
        end
      end)

    assert_receive {:owned_pending, ^owner, pending}

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.activate_unlock(custodian, pending)

    state = :sys.get_state(custodian)
    assert map_size(state.pending) == 1
    assert map_size(state.pending_monitors) == 1

    send(owner, :discard)

    assert_eventually(fn ->
      state = :sys.get_state(custodian)
      map_size(state.pending) == 0 and map_size(state.pending_monitors) == 0
    end)
  end

  test "expiry and custody-first revocation win against unresolved activation", %{
    custodian: custodian
  } do
    assert {:ok, expiring} = KeyCustodian.prepare_unlock(custodian, custody())
    send(custodian, {:expire_pending, expiring})

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.activate_unlock(custodian, expiring)

    assert {:ok, revoked} = KeyCustodian.prepare_unlock(custodian, custody())

    assert {:ok, token} =
             KeyCustodian.begin_revoke(custodian, %{vault_id: @vault_id})

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.activate_unlock(custodian, revoked)

    state = :sys.get_state(custodian)
    assert state.pending == %{}
    assert state.pending_monitors == %{}
    assert state.revoking == %{token => %{vault_id: @vault_id}}
    assert :ok = KeyCustodian.finish_revoke(custodian, token)
    assert :sys.get_state(custodian).revoking == %{}
  end

  test "custody-first revocation is synchronous for session, principal, and vault scopes", %{
    custodian: custodian
  } do
    for selector <- [
          %{session_id: @session_id},
          %{principal_id: @principal_id},
          %{vault_id: @vault_id}
        ] do
      assert :ok = activate!(custodian, custody())
      assert KeyCustodian.unlocked?(custodian, @session_id)

      assert {:ok, token} = KeyCustodian.begin_revoke(custodian, selector)
      assert :ok = KeyCustodian.await_revoking(custodian, selector)
      refute KeyCustodian.unlocked?(custodian, @session_id)
      assert :ok = KeyCustodian.finish_revoke(custodian, token)
    end
  end

  test "revocation gate blocks pending activation and fresh matching prepare until exact cleanup",
       %{custodian: custodian} do
    assert {:ok, pending} = KeyCustodian.prepare_unlock(custodian, epoch_custody())

    assert {:ok, first_token} =
             KeyCustodian.begin_revoke(custodian, %{vault_id: @vault_id})

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.activate_unlock(custodian, pending)

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.prepare_unlock(custodian, epoch_custody())

    assert {:ok, second_token} =
             KeyCustodian.begin_revoke(custodian, %{vault_id: @vault_id})

    assert :ok = KeyCustodian.finish_revoke(custodian, first_token)

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.prepare_unlock(custodian, epoch_custody())

    assert :ok = KeyCustodian.finish_revoke(custodian, make_ref())

    assert {:error, %Error{code: :conflict}} =
             KeyCustodian.prepare_unlock(custodian, epoch_custody())

    assert :ok = KeyCustodian.finish_revoke(custodian, second_token)
    assert {:ok, reopened} = KeyCustodian.prepare_unlock(custodian, epoch_custody())
    assert :ok = KeyCustodian.discard_pending(custodian, reopened)
  end

  test "session principal and vault gates block only matching selectors", %{
    custodian: custodian
  } do
    matching = epoch_custody()

    nonmatching =
      epoch_custody(
        session_id: "session-2",
        principal_id: "principal-2",
        vault_id: "vault-2"
      )

    for selector <- [
          %{session_id: @session_id},
          %{principal_id: @principal_id},
          %{vault_id: @vault_id}
        ] do
      assert {:ok, token} = KeyCustodian.begin_revoke(custodian, selector)

      assert {:error, %Error{code: :conflict}} =
               KeyCustodian.prepare_unlock(custodian, matching)

      assert {:ok, pending} = KeyCustodian.prepare_unlock(custodian, nonmatching)
      assert :ok = KeyCustodian.discard_pending(custodian, pending)
      assert :ok = KeyCustodian.finish_revoke(custodian, token)
    end
  end

  test "custody assertions reject either stale authorization epoch", %{
    custodian: custodian
  } do
    assert :ok = activate!(custodian, epoch_custody())

    assert :ok =
             KeyCustodian.assert_unlocked(
               custodian,
               @session_id,
               @principal_id,
               @vault_id,
               @principal_authorization_epoch,
               @vault_authorization_epoch
             )

    assert {:error, %Error{code: :vault_locked}} =
             KeyCustodian.assert_unlocked(
               custodian,
               @session_id,
               @principal_id,
               @vault_id,
               @principal_authorization_epoch + 1,
               @vault_authorization_epoch
             )

    assert {:error, %Error{code: :vault_locked}} =
             KeyCustodian.assert_unlocked(
               custodian,
               @session_id,
               @principal_id,
               @vault_id,
               @principal_authorization_epoch,
               @vault_authorization_epoch + 1
             )
  end

  test "idle timeout clears active custody", %{custodian: custodian} do
    assert :ok = activate!(custodian, custody())
    assert KeyCustodian.unlocked?(custodian, @session_id)

    assert_eventually(fn -> not KeyCustodian.unlocked?(custodian, @session_id) end)

    assert_receive {:idle_lock_persisted,
                    %{
                      session_id: @session_id,
                      principal_id: @principal_id,
                      vault_id: @vault_id,
                      reason: :idle_timeout
                    }}
  end

  test "successful authorized checks refresh the idle deadline", %{
    custodian: custodian
  } do
    assert :ok = activate!(custodian, custody())
    Process.sleep(35)

    assert :ok =
             KeyCustodian.assert_unlocked(
               custodian,
               @session_id,
               @principal_id,
               @vault_id,
               @principal_authorization_epoch,
               @vault_authorization_epoch
             )

    Process.sleep(35)
    assert KeyCustodian.unlocked?(custodian, @session_id)

    assert_eventually(fn -> not KeyCustodian.unlocked?(custodian, @session_id) end)
  end

  test "idle locking one session revokes every custody entry in its vault", %{
    lease_supervisor: lease_supervisor
  } do
    custodian =
      start_supervised!(
        {KeyCustodian,
         %{
           authorization: Fake.Authorization,
           clock: Fake.Clock,
           context: %{},
           idle_lock: {Callbacks, self()},
           idle_timeout_ms: 60_000,
           key_reader: Fake.KeyReader,
           lease_supervisor: lease_supervisor,
           object_key_loader: Fake.KeyReader,
           pending_ttl_ms: 500,
           wake_limit: 7,
           wake_waiting: {Callbacks, self()}
         }},
        id: make_ref()
      )

    second_session_id = "session-2"

    assert :ok = activate!(custodian, epoch_custody())

    assert :ok =
             activate!(
               custodian,
               epoch_custody(
                 session_id: second_session_id,
                 principal_id: "principal-2"
               )
             )

    {_timer, idle_token} =
      custodian
      |> :sys.get_state()
      |> get_in([:idle_timers, @session_id])

    send(custodian, {:idle_lock, @session_id, idle_token})

    assert_receive {:idle_lock_persisted,
                    %{
                      session_id: @session_id,
                      vault_id: @vault_id,
                      reason: :idle_timeout
                    }}

    refute KeyCustodian.unlocked?(custodian, @session_id)
    refute KeyCustodian.unlocked?(custodian, second_session_id)
  end

  defp custody do
    %{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      principal_authorization_epoch: @principal_authorization_epoch,
      vault_authorization_epoch: @vault_authorization_epoch,
      vault_key: :binary.copy(<<0xA1>>, 32),
      domain_key: :binary.copy(<<0xB2>>, 32),
      object_keys: %{
        {"object-1", 1} => :binary.copy(<<0xC3>>, 32)
      }
    }
  end

  defp epoch_custody(overrides \\ []) do
    custody()
    |> Map.merge(Map.new(overrides))
  end

  defp lease_request do
    %{
      job_id: "job-1",
      vault_id: @vault_id,
      principal_id: @principal_id,
      required_capability: "asset.read",
      principal_authorization_epoch: @principal_authorization_epoch,
      vault_authorization_epoch: @vault_authorization_epoch,
      object_id: "object-1",
      object_generation: 1,
      session_id: @session_id
    }
  end

  defp activate!(custodian, custody) do
    with {:ok, pending} <- KeyCustodian.prepare_unlock(custodian, custody) do
      KeyCustodian.activate_unlock(custodian, pending)
    end
  end

  defp assert_eventually(callback, attempts \\ 100)

  defp assert_eventually(callback, attempts) when attempts > 0 do
    if callback.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(callback, attempts - 1)
    end
  end

  defp assert_eventually(_callback, 0), do: flunk("condition did not become true")
end
