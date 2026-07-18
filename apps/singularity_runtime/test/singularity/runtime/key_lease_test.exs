Code.require_file("../../support/fake/authorization.ex", __DIR__)
Code.require_file("../../support/fake/clock.ex", __DIR__)
Code.require_file("../../support/fake/key_reader.ex", __DIR__)

defmodule Singularity.Runtime.KeyLeaseTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLease
  alias Singularity.Runtime.KeyLeaseSupervisor

  defmodule IdleLock do
    def idle_lock(_owner, _session), do: :ok
  end

  @now ~U[2026-07-18 08:00:00Z]
  @session_id "session-1"
  @principal_id "principal-1"
  @vault_id "vault-1"
  @object_id "object-1"
  @authorization_epoch 7
  @object_generation 3
  @capability "assets.read"

  setup do
    request = lease_request()
    clock = start_supervised!({Fake.Clock, now: @now})

    authorization =
      start_supervised!({Fake.Authorization, state: authorization_state()})

    key_reader =
      start_supervised!(
        {Fake.KeyReader,
         owner: self(),
         checkpoints: %{checkpoint_key(request) => checkpoint(request, 0)},
         chunks: %{
           0 => "authenticated chunk zero",
           1 => "authenticated chunk one",
           2 => "authenticated chunk two"
         }}
      )

    context = %{
      authorization: authorization,
      clock: clock,
      key_reader: key_reader
    }

    lease_supervisor = start_supervised!({KeyLeaseSupervisor, []})

    custodian_options = %{
      authorization: Fake.Authorization,
      clock: Fake.Clock,
      context: context,
      idle_lock: {IdleLock, self()},
      key_reader: Fake.KeyReader,
      lease_supervisor: lease_supervisor,
      object_key_loader: Fake.KeyReader
    }

    custodian = start_supervised!({KeyCustodian, custodian_options})

    assert :ok = activate!(custodian, unlocked_session())

    {:ok, context: context, custodian: custodian, custodian_options: custodian_options}
  end

  test "binds one lease to the complete authorization context and revalidates every read",
       %{context: context, custodian: custodian} do
    request = lease_request()
    lease = lease!(custodian, request)

    assert_read(lease, 0, "authenticated chunk zero")
    assert_read(lease, 1, "authenticated chunk one")

    assert [^request, ^request, ^request, ^request, ^request, ^request] =
             Fake.Authorization.checks(context)

    assert [{^request, 0}, {^request, 1}] = Fake.KeyReader.calls(context)

    assert [%{binding: ^request, hierarchy: hierarchy}] =
             Fake.KeyReader.object_key_loads(context)

    assert Map.has_key?(hierarchy, :domain_key)
    refute Map.has_key?(hierarchy, :vault_key)
  end

  test "lock wins against a blocked read, terminates its worker, and returns no plaintext", %{
    context: context,
    custodian: custodian
  } do
    request = lease_request()
    lease = lease!(custodian, request)
    assert :ok = Fake.KeyReader.block_next_read(context)

    read = Task.async(fn -> KeyLease.read_chunk(lease, 0) end)

    assert_receive {:key_reader_blocked, worker, token, ^request, 0}, 1_000
    worker_monitor = Process.monitor(worker)

    assert :ok =
             KeyCustodian.begin_revoke(custodian, %{session_id: @session_id})

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    assert {:error, :waiting_for_unlock} = Task.await(read)

    assert Fake.KeyReader.checkpoint(context, request) == checkpoint(request, 0)
    assert Fake.KeyReader.persist_calls(context) == []
    refute_receive {:plaintext_chunk, 0, _}

    lease_state = :sys.get_state(lease)
    assert lease_state.revoked?
    refute Map.has_key?(lease_state.reader_context, :key_material)

    assert :ok = Fake.KeyReader.release_read(worker, token)

    assert :ok = activate!(custodian, unlocked_session())
    replacement = lease!(custodian, request)
    assert_read(replacement, 0, "authenticated chunk zero")
  end

  test "a CAS-linearized read completes before a queued lock can acknowledge", %{
    context: context,
    custodian: custodian
  } do
    request = lease_request()
    lease = lease!(custodian, request)
    assert :ok = Fake.KeyReader.block_after_next_persist(context)

    read = Task.async(fn -> KeyLease.read_chunk(lease, 0) end)

    assert_receive {
                     :checkpoint_persisted_blocked,
                     persister,
                     token,
                     ^request,
                     expected,
                     next
                   },
                   1_000

    assert expected == checkpoint(request, 0)
    assert next == checkpoint(request, 1)

    lock =
      Task.async(fn ->
        KeyCustodian.begin_revoke(custodian, %{session_id: @session_id})
      end)

    assert Task.yield(lock, 100) == nil
    assert :ok = Fake.KeyReader.release_persist(persister, token)
    assert {:ok, "authenticated chunk zero"} = Task.await(read)
    assert :ok = Task.await(lock)

    assert Fake.KeyReader.checkpoint(context, request) == checkpoint(request, 1)
    assert_waiting(lease, 1)
  end

  test "a completed blocked read linearizes before a later lock", %{
    context: context,
    custodian: custodian
  } do
    request = lease_request()
    lease = lease!(custodian, request)
    assert :ok = Fake.KeyReader.block_next_read(context)

    read = Task.async(fn -> KeyLease.read_chunk(lease, 0) end)
    assert_receive {:key_reader_blocked, worker, token, ^request, 0}, 1_000
    assert :ok = Fake.KeyReader.release_read(worker, token)

    assert {:ok, "authenticated chunk zero"} = Task.await(read)
    assert_received {:plaintext_chunk, 0, "authenticated chunk zero"}
    assert Fake.KeyReader.checkpoint(context, request) == checkpoint(request, 1)

    assert :ok =
             KeyCustodian.begin_revoke(custodian, %{session_id: @session_id})

    assert_waiting(lease, 1)
  end

  test "deadline expiry wins against a blocked read and clears custody", %{
    context: context,
    custodian: custodian
  } do
    request = lease_request()
    lease = lease!(custodian, request)
    assert :ok = Fake.KeyReader.block_next_read(context)

    read = Task.async(fn -> KeyLease.read_chunk(lease, 0) end)
    assert_receive {:key_reader_blocked, worker, _token, ^request, 0}, 1_000
    worker_monitor = Process.monitor(worker)

    assert :ok = Fake.Clock.advance(context, 60)
    send(lease, :expire)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    assert {:error, :waiting_for_unlock} = Task.await(read)
    assert Fake.KeyReader.checkpoint(context, request) == checkpoint(request, 0)
    assert Fake.KeyReader.persist_calls(context) == []
    refute_receive {:plaintext_chunk, 0, _}

    lease_state = :sys.get_state(lease)
    assert lease_state.revoked?
    refute Map.has_key?(lease_state.reader_context, :key_material)
  end

  test "deadline reached at worker completion cannot advance the checkpoint", %{
    context: context,
    custodian: custodian
  } do
    request = lease_request()
    lease = lease!(custodian, request)
    assert :ok = Fake.KeyReader.block_next_read(context)

    read = Task.async(fn -> KeyLease.read_chunk(lease, 0) end)
    assert_receive {:key_reader_blocked, worker, token, ^request, 0}, 1_000
    worker_monitor = Process.monitor(worker)

    assert :ok = :sys.suspend(lease)
    assert :ok = Fake.KeyReader.release_read(worker, token)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1_000
    assert :ok = Fake.Clock.advance(context, 60)
    assert :ok = :sys.resume(lease)

    assert {:error, :waiting_for_unlock} = Task.await(read)
    assert Fake.KeyReader.checkpoint(context, request) == checkpoint(request, 0)
    assert Fake.KeyReader.persist_calls(context) == []
    refute_receive {:plaintext_chunk, 0, _}
  end

  test "authorization is revalidated after a blocked read and before persistence", %{
    context: context,
    custodian: custodian
  } do
    request = lease_request()
    lease = lease!(custodian, request)
    assert :ok = Fake.KeyReader.block_next_read(context)

    read = Task.async(fn -> KeyLease.read_chunk(lease, 0) end)
    assert_receive {:key_reader_blocked, worker, token, ^request, 0}, 1_000

    assert :ok = Fake.Authorization.log_out(context, @session_id)
    assert :ok = Fake.KeyReader.release_read(worker, token)
    assert {:error, :waiting_for_unlock} = Task.await(read)

    assert [^request, ^request] = Fake.Authorization.checks(context)
    assert Fake.KeyReader.checkpoint(context, request) == checkpoint(request, 0)
    assert Fake.KeyReader.persist_calls(context) == []
    refute_receive {:plaintext_chunk, 0, _}
  end

  test "custodian death terminates leases and replacement custody starts locked", %{
    context: context,
    custodian: custodian,
    custodian_options: custodian_options
  } do
    old_lease = lease!(custodian)
    lease_monitor = Process.monitor(old_lease)

    assert :ok = stop_supervised(KeyCustodian)
    assert_receive {:DOWN, ^lease_monitor, :process, ^old_lease, :normal}, 1_000

    replacement = start_supervised!({KeyCustodian, custodian_options})
    assert {:error, :waiting_for_unlock} = KeyCustodian.lease(replacement, lease_request())

    assert :ok = activate!(replacement, unlocked_session())
    new_lease = lease!(replacement)
    assert new_lease != old_lease
    assert_read(new_lease, 0, "authenticated chunk zero")
    assert [{_, 0}] = Fake.KeyReader.calls(context)
  end

  test "locking between reads prevents the next plaintext chunk", %{
    context: context,
    custodian: custodian
  } do
    lease = lease!(custodian)
    assert_read(lease, 0, "authenticated chunk zero")

    assert :ok =
             KeyCustodian.begin_revoke(custodian, %{session_id: @session_id})

    assert_waiting(lease, 1)
    assert [{_, 0}] = Fake.KeyReader.calls(context)
  end

  test "principal and vault revocation synchronously interrupt active leases", %{
    custodian: custodian
  } do
    for selector <- [
          %{principal_id: @principal_id},
          %{vault_id: @vault_id}
        ] do
      lease = lease!(custodian)

      assert :ok = KeyCustodian.begin_revoke(custodian, selector)
      assert_waiting(lease, 0)

      assert_eventually(fn ->
        state = :sys.get_state(custodian)
        state.leases == %{} and state.monitors == %{}
      end)

      assert :ok = activate!(custodian, unlocked_session())
    end
  end

  test "custody cannot issue a lease for a different principal binding", %{
    custodian: custodian
  } do
    assert {:error, :waiting_for_unlock} =
             KeyCustodian.lease(
               custodian,
               lease_request(principal_id: "principal-other")
             )
  end

  test "successful chunk activity refreshes idle custody before timeout interrupts its lease", %{
    custodian: custodian
  } do
    lease = lease!(custodian)
    %{idle_timers: %{@session_id => {_timer, initial_token}}} = :sys.get_state(custodian)

    assert_read(lease, 0, "authenticated chunk zero")

    assert_eventually(fn ->
      %{idle_timers: %{@session_id => {_timer, token}}} = :sys.get_state(custodian)
      token != initial_token
    end)

    %{idle_timers: %{@session_id => {_timer, refreshed_token}}} =
      :sys.get_state(custodian)

    send(custodian, {:idle_lock, @session_id, initial_token})
    assert KeyCustodian.unlocked?(custodian, @session_id)

    send(custodian, {:idle_lock, @session_id, refreshed_token})
    assert_eventually(fn -> not KeyCustodian.unlocked?(custodian, @session_id) end)
    assert_waiting(lease, 1)
  end

  test "logout between reads prevents the next plaintext chunk", %{
    context: context,
    custodian: custodian
  } do
    lease = lease!(custodian)
    assert_read(lease, 0, "authenticated chunk zero")

    assert :ok = Fake.Authorization.log_out(context, @session_id)

    assert_waiting(lease, 1)
    assert [{_, 0}] = Fake.KeyReader.calls(context)
  end

  test "session revocation between reads prevents the next plaintext chunk", %{
    context: context,
    custodian: custodian
  } do
    lease = lease!(custodian)
    assert_read(lease, 0, "authenticated chunk zero")

    assert :ok = Fake.Authorization.revoke_session(context, @session_id)

    assert_waiting(lease, 1)
    assert [{_, 0}] = Fake.KeyReader.calls(context)
  end

  test "a lease expires at its 60-second boundary", %{
    context: context,
    custodian: custodian
  } do
    lease = lease!(custodian)
    assert_read(lease, 0, "authenticated chunk zero")

    assert :ok = Fake.Clock.advance(context, 59)
    assert_read(lease, 1, "authenticated chunk one")

    assert :ok = Fake.Clock.advance(context, 1)

    assert_waiting(lease, 2)
    assert [{_, 0}, {_, 1}] = Fake.KeyReader.calls(context)
  end

  test "principal revocation between reads prevents the next plaintext chunk", %{
    context: context,
    custodian: custodian
  } do
    lease = lease!(custodian)
    assert_read(lease, 0, "authenticated chunk zero")

    assert :ok = Fake.Authorization.revoke_principal(context, @principal_id)

    assert_waiting(lease, 1)
    assert [{_, 0}] = Fake.KeyReader.calls(context)
  end

  test "authorization epoch change between reads prevents the next plaintext chunk", %{
    context: context,
    custodian: custodian
  } do
    lease = lease!(custodian)
    assert_read(lease, 0, "authenticated chunk zero")

    assert :ok =
             Fake.Authorization.set_authorization_epoch(
               context,
               @principal_id,
               @vault_id,
               @authorization_epoch + 1
             )

    assert_waiting(lease, 1)
    assert [{_, 0}] = Fake.KeyReader.calls(context)
  end

  test "capability change between reads prevents the next plaintext chunk", %{
    context: context,
    custodian: custodian
  } do
    lease = lease!(custodian)
    assert_read(lease, 0, "authenticated chunk zero")

    assert :ok =
             Fake.Authorization.replace_capabilities(
               context,
               @principal_id,
               @vault_id,
               ["assets.write"]
             )

    assert_waiting(lease, 1)
    assert [{_, 0}] = Fake.KeyReader.calls(context)
  end

  test "object generation change between reads prevents the next plaintext chunk", %{
    context: context,
    custodian: custodian
  } do
    lease = lease!(custodian)
    assert_read(lease, 0, "authenticated chunk zero")

    assert :ok =
             Fake.Authorization.set_object_generation(
               context,
               @vault_id,
               @object_id,
               @object_generation + 1
             )

    assert_waiting(lease, 1)
    assert [{_, 0}] = Fake.KeyReader.calls(context)
  end

  test "a new unlock requires a new lease and resumes from the caller's checkpoint", %{
    context: context,
    custodian: custodian
  } do
    old_lease = lease!(custodian)
    assert_read(old_lease, 0, "authenticated chunk zero")
    assert Fake.KeyReader.checkpoint(context, lease_request()) == checkpoint(lease_request(), 1)

    assert :ok =
             KeyCustodian.begin_revoke(custodian, %{session_id: @session_id})

    assert_waiting(old_lease, 1)
    GenServer.stop(old_lease)
    refute Process.alive?(old_lease)

    new_session = unlocked_session(session_id: "session-2")

    assert :ok =
             Fake.Authorization.add_session(context, %{
               session_id: new_session.session_id,
               principal_id: @principal_id,
               vault_id: @vault_id,
               status: :active
             })

    assert :ok = activate!(custodian, new_session)

    new_request = lease_request(session_id: new_session.session_id)
    new_lease = lease!(custodian, new_request)

    assert new_lease != old_lease
    assert_read(new_lease, 1, "authenticated chunk one")
    assert [{_, 0}, {^new_request, 1}] = Fake.KeyReader.calls(context)

    assert [initial_load, resumed_load] = Fake.KeyReader.load_calls(context)
    assert initial_load.binding == lease_request()
    assert initial_load.checkpoint == checkpoint(lease_request(), 0)
    assert resumed_load.binding == new_request
    assert resumed_load.checkpoint == checkpoint(new_request, 1)
  end

  test "missing, malformed, and stale persisted checkpoints fail closed", %{
    context: context,
    custodian: custodian
  } do
    request = lease_request()

    assert :ok = Fake.KeyReader.delete_checkpoint(context, request)
    assert {:error, %Error{code: :conflict}} = KeyCustodian.lease(custodian, request)

    assert :ok = Fake.KeyReader.put_checkpoint(context, request, %{"version" => 1})

    assert {:error, %Error{code: :integrity_failure}} =
             KeyCustodian.lease(custodian, request)

    stale = checkpoint(request, 0) |> Map.put("authorization_epoch", @authorization_epoch - 1)
    assert :ok = Fake.KeyReader.put_checkpoint(context, request, stale)
    assert {:error, %Error{code: :conflict}} = KeyCustodian.lease(custodian, request)

    assert Fake.KeyReader.calls(context) == []
    refute_receive {:plaintext_chunk, _, _}
  end

  test "a lease rejects checkpoint replay or skipping and requires a new lease", %{
    context: context,
    custodian: custodian
  } do
    skipped = lease!(custodian)
    assert {:error, %Error{code: :conflict}} = KeyLease.read_chunk(skipped, 1)
    assert_waiting(skipped, 0)
    assert Fake.KeyReader.calls(context) == []

    first = lease!(custodian)
    assert_read(first, 0, "authenticated chunk zero")

    assert {:error, %Error{code: :conflict}} = KeyLease.read_chunk(first, 0)
    assert_waiting(first, 1)
    assert [{_, 0}] = Fake.KeyReader.calls(context)

    resumed = lease!(custodian)
    assert_read(resumed, 1, "authenticated chunk one")
    assert [{_, 0}, {_, 1}] = Fake.KeyReader.calls(context)
  end

  test "checkpoint persistence failure returns no plaintext and preserves the durable index", %{
    context: context,
    custodian: custodian
  } do
    request = lease_request()
    assert :ok = Fake.KeyReader.fail_next_persist(context)
    failed = lease!(custodian, request)

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             KeyLease.read_chunk(failed, 0)

    refute_receive {:plaintext_chunk, 0, _}
    assert_waiting(failed, 0)
    assert Fake.KeyReader.checkpoint(context, request) == checkpoint(request, 0)

    assert [
             %{
               binding: ^request,
               context: persist_context,
               expected: expected,
               next: next
             }
           ] =
             Fake.KeyReader.persist_calls(context)

    refute Map.has_key?(persist_context, :key_material)
    assert expected == checkpoint(request, 0)
    assert next == checkpoint(request, 1)
    refute Map.has_key?(next, "plaintext")
    refute Map.has_key?(next, "key_material")

    resumed = lease!(custodian, request)
    assert_read(resumed, 0, "authenticated chunk zero")
    assert Fake.KeyReader.checkpoint(context, request) == checkpoint(request, 1)
  end

  test "replacing an unlocked session revokes leases from its prior custody", %{
    context: context,
    custodian: custodian
  } do
    old_lease = lease!(custodian)
    assert_read(old_lease, 0, "authenticated chunk zero")

    assert :ok =
             activate!(
               custodian,
               unlocked_session(object_dek: :binary.copy(<<0xD4>>, 32))
             )

    assert_waiting(old_lease, 1)
    assert [{_, 0}] = Fake.KeyReader.calls(context)

    new_lease = lease!(custodian)
    assert_read(new_lease, 1, "authenticated chunk one")
  end

  test "the public API returns no vault key, domain key, or object DEK", %{
    custodian: custodian
  } do
    lease = lease!(custodian)

    assert is_pid(lease)
    assert {:ok, plaintext} = KeyLease.read_chunk(lease, 0)

    returned_values = [lease, plaintext]

    refute unlocked_session().vault_key in returned_values
    refute unlocked_session().domain_key in returned_values

    refute Map.fetch!(
             unlocked_session().object_keys,
             {@object_id, @object_generation}
           ) in returned_values
  end

  defp lease!(custodian, request \\ lease_request()) do
    assert {:ok, lease} = KeyCustodian.lease(custodian, request)
    lease
  end

  defp assert_read(lease, index, expected) do
    assert {:ok, ^expected} = KeyLease.read_chunk(lease, index)
    assert_received {:plaintext_chunk, ^index, ^expected}
  end

  defp assert_waiting(lease, index) do
    assert {:error, :waiting_for_unlock} = KeyLease.read_chunk(lease, index)
    refute_receive {:plaintext_chunk, ^index, _chunk}
  end

  defp unlocked_session(overrides \\ []) do
    overrides = Map.new(overrides)
    object_dek = Map.get(overrides, :object_dek, :binary.copy(<<0xC3>>, 32))

    %{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @vault_id,
      vault_key: :binary.copy(<<0xA1>>, 32),
      domain_key: :binary.copy(<<0xB2>>, 32),
      object_keys: %{
        {@object_id, @object_generation} => object_dek
      }
    }
    |> Map.merge(Map.delete(overrides, :object_dek))
  end

  defp activate!(custodian, session) do
    with {:ok, pending} <- KeyCustodian.prepare_unlock(custodian, session) do
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

  defp lease_request(overrides \\ []) do
    %{
      job_id: "job-1",
      vault_id: @vault_id,
      principal_id: @principal_id,
      required_capability: @capability,
      authorization_epoch: @authorization_epoch,
      object_id: @object_id,
      object_generation: @object_generation,
      session_id: @session_id
    }
    |> Map.merge(Map.new(overrides))
  end

  defp authorization_state do
    %{
      sessions: %{
        @session_id => %{
          status: :active,
          principal_id: @principal_id,
          vault_id: @vault_id
        }
      },
      principals: %{@principal_id => :active},
      authorizations: %{
        {@principal_id, @vault_id} => %{
          epoch: @authorization_epoch,
          capabilities: MapSet.new([@capability])
        }
      },
      object_generations: %{
        {@vault_id, @object_id} => @object_generation
      }
    }
  end

  defp checkpoint(request, next_chunk_index) do
    %{
      "version" => 1,
      "next_chunk_index" => next_chunk_index,
      "job_id" => request.job_id,
      "vault_id" => request.vault_id,
      "principal_id" => request.principal_id,
      "required_capability" => request.required_capability,
      "authorization_epoch" => request.authorization_epoch,
      "object_id" => request.object_id,
      "object_generation" => request.object_generation
    }
  end

  defp checkpoint_key(request),
    do: {request.job_id, request.vault_id, request.object_id}
end
