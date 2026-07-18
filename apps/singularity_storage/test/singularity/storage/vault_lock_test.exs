defmodule Singularity.Storage.VaultLockTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.VaultLock

  test "checkout callback is arity zero and exclusive waits for a shared vault lock" do
    vault_id = Ecto.UUID.generate()
    parent = self()

    shared =
      Task.async(fn ->
        VaultLock.with_shared(WorkerRepo, vault_id, fn repo ->
          send(parent, {:shared_acquired, repo})

          receive do
            :release_shared -> :shared_finished
          end
        end)
      end)

    assert_receive {:shared_acquired, WorkerRepo}

    exclusive =
      Task.async(fn ->
        result =
          VaultLock.with_exclusive(WorkerRepo, vault_id, fn _repo ->
            send(parent, :exclusive_acquired)
            :exclusive_finished
          end)

        result
      end)

    refute_receive :exclusive_acquired, 100
    send(shared.pid, :release_shared)
    assert Task.await(shared) == :shared_finished
    assert_receive :exclusive_acquired
    assert Task.await(exclusive) == :exclusive_finished
  end
end
