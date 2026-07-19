defmodule Singularity.Storage.ObjectLockTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.ObjectLock
  alias Singularity.Storage.VaultLock

  test "requires an already checked-out repository connection" do
    assert_raise ArgumentError,
                 ~r/requires an already checked-out repository connection/,
                 fn ->
                   ObjectLock.with_exclusive(WorkerRepo, Ecto.UUID.generate(), fn ->
                     :unexpected
                   end)
                 end
  end

  test "rejects an invalid object UUID" do
    WorkerRepo.checkout(fn ->
      assert_raise ArgumentError, ~r/requires a valid UUID/, fn ->
        ObjectLock.with_exclusive(WorkerRepo, "not-a-uuid", fn -> :unexpected end)
      end
    end)
  end

  test "serializes operations for the same object and releases after success" do
    object_id = Ecto.UUID.generate()
    parent = self()

    first =
      Task.async(fn ->
        WorkerRepo.checkout(fn ->
          ObjectLock.with_exclusive(WorkerRepo, object_id, fn ->
            send(parent, :first_acquired)

            receive do
              :release_first -> :first_finished
            end
          end)
        end)
      end)

    assert_receive :first_acquired

    second =
      Task.async(fn ->
        WorkerRepo.checkout(fn ->
          ObjectLock.with_exclusive(WorkerRepo, object_id, fn ->
            send(parent, :second_acquired)
            :second_finished
          end)
        end)
      end)

    refute_receive :second_acquired, 100
    send(first.pid, :release_first)
    assert Task.await(first) == :first_finished
    assert_receive :second_acquired
    assert Task.await(second) == :second_finished
  end

  test "releases the lock when the callback raises" do
    object_id = Ecto.UUID.generate()
    parent = self()

    failed =
      Task.async(fn ->
        WorkerRepo.checkout(fn ->
          assert_raise RuntimeError, "callback failed", fn ->
            ObjectLock.with_exclusive(WorkerRepo, object_id, fn ->
              raise "callback failed"
            end)
          end

          send(parent, :failure_caught)

          receive do
            :release_connection -> :failed_operation_finished
          end
        end)
      end)

    assert_receive :failure_caught

    successor =
      Task.async(fn ->
        WorkerRepo.checkout(fn ->
          ObjectLock.with_exclusive(WorkerRepo, object_id, fn ->
            send(parent, :successor_acquired)
            :successor_finished
          end)
        end)
      end)

    assert_receive :successor_acquired
    assert Task.await(successor) == :successor_finished

    send(failed.pid, :release_connection)
    assert Task.await(failed) == :failed_operation_finished
  end

  test "uses a namespace disjoint from vault and authorization locks" do
    object_id = Ecto.UUID.generate()
    parent = self()

    vault_holder =
      Task.async(fn ->
        VaultLock.with_exclusive(WorkerRepo, object_id, fn _repo ->
          send(parent, :vault_lock_acquired)

          receive do
            :release_vault_lock -> :vault_lock_released
          end
        end)
      end)

    assert_receive :vault_lock_acquired
    assert_object_lock_acquirable(object_id)
    send(vault_holder.pid, :release_vault_lock)
    assert Task.await(vault_holder) == :vault_lock_released

    authorization_holder =
      Task.async(fn ->
        WorkerRepo.checkout(fn ->
          AuthorizationLock.with_exclusive(
            WorkerRepo,
            object_id,
            object_id,
            fn _repo ->
              send(parent, :authorization_lock_acquired)

              receive do
                :release_authorization_lock -> :authorization_lock_released
              end
            end
          )
        end)
      end)

    assert_receive :authorization_lock_acquired
    assert_object_lock_acquirable(object_id)
    send(authorization_holder.pid, :release_authorization_lock)
    assert Task.await(authorization_holder) == :authorization_lock_released
  end

  defp assert_object_lock_acquirable(object_id) do
    parent = self()

    object_lock =
      Task.async(fn ->
        WorkerRepo.checkout(fn ->
          ObjectLock.with_exclusive(WorkerRepo, object_id, fn ->
            send(parent, :object_lock_acquired)
            :object_lock_released
          end)
        end)
      end)

    assert_receive :object_lock_acquired
    assert Task.await(object_lock) == :object_lock_released
  end
end
