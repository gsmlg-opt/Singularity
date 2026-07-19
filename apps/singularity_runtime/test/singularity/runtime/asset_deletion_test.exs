defmodule Singularity.Runtime.AssetDeletionTest do
  use ExUnit.Case, async: true

  alias Singularity.Runtime.Assets.Delete
  alias Singularity.Runtime.Assets.Cleanup
  alias Singularity.Core.JobEnvelope
  alias Singularity.Core.ObjectRef
  alias Singularity.Runtime.Assets.ObjectCleanup
  alias Singularity.Runtime.SessionContext

  defmodule ScopeSpy do
    def with_read_request(runtime, _session, requirement, callback) do
      send(runtime.test_pid, {:scope, :read, requirement})
      callback.(:read_repo)
    end

    def with_shared_request(runtime, _session, requirement, callback) do
      send(runtime.test_pid, {:scope, :shared, requirement})
      callback.(:write_repo)
    end
  end

  defmodule DeletionSpy do
    def load_delete_target(test_pid, repo, command) do
      send(test_pid, {:load_delete_target, repo, command})

      {:ok,
       %{
         id: command.asset_id,
         vault_id: command.vault_id,
         classification: :sensitive,
         state: :available,
         state_revision: 3
       }}
    end

    def resolve_delete_lock_target(test_pid, repo, command) do
      send(test_pid, {:resolve_delete_lock_target, repo, command})
      {:ok, %{object_id: command.asset_id}}
    end

    def tombstone_and_release(test_pid, repo, command) do
      send(test_pid, {:tombstone_and_release, repo, command})
      {:ok, %{id: command.asset_id, state: :pending_delete, state_revision: 4}}
    end

    def complete_logical_delete(test_pid, repo, envelope) do
      send(test_pid, {:complete_logical_delete, repo, envelope})
      {:ok, %{id: envelope.payload["asset_id"], state: :deleted, state_revision: 5}}
    end

    def claim_orphan_delete(test_pid, repo, envelope) do
      send(test_pid, {:claim_orphan_delete, repo, envelope})

      {:ok,
       %{
         object_ref: %ObjectRef{object_id: envelope.payload["object_id"]},
         claim_token: envelope.job_id
       }}
    end

    def acknowledge_object_deleted(test_pid, repo, deletion) do
      send(test_pid, {:acknowledge_object_deleted, repo, deletion})
      {:ok, %{id: deletion.object_ref.object_id, lifecycle: :deleted}}
    end
  end

  defmodule JobAuthorizationSpy do
    def check_job(test_pid, authorization, repo, envelope) do
      send(test_pid, {:check_job, authorization, repo, envelope})
      :ok
    end
  end

  defmodule ObjectLockSpy do
    def with_exclusive(test_pid, repo, object_id, callback) do
      send(test_pid, {:object_lock, repo, object_id})
      result = callback.()
      send(test_pid, {:object_unlock, repo, object_id})
      result
    end
  end

  defmodule DeleteRaceSpy do
    def load_delete_target(test_pid, repo, command) do
      send(test_pid, {:load_delete_target, repo, command})

      {:ok,
       %{
         id: command.asset_id,
         vault_id: command.vault_id,
         classification: :sensitive,
         state: :verified,
         state_revision: 2
       }}
    end

    def resolve_delete_lock_target(test_pid, repo, command) do
      send(test_pid, {:resolve_delete_lock_target, self(), repo, command})

      receive do
        {:resolve_as, ^test_pid, object_id} ->
          {:ok, %{object_id: object_id}}
      end
    end

    def tombstone_and_release(test_pid, repo, command) do
      send(test_pid, {:tombstone_and_release, repo, command})
      {:ok, %{id: command.asset_id, state: :pending_delete, state_revision: 3}}
    end
  end

  defmodule StorageDeletionSpy do
    def delete(test_pid, object_ref) do
      send(test_pid, {:storage_delete, object_ref})
      :ok
    end
  end

  test "delete resolves classification then mutates through a shared request scope" do
    asset_id = Ecto.UUID.generate()
    vault_id = Ecto.UUID.generate()
    principal_id = Ecto.UUID.generate()

    session = %SessionContext{
      session_id: Ecto.UUID.generate(),
      principal_id: principal_id,
      vault_id: vault_id,
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 9,
      authorization_epoch: 7,
      unlocked?: false
    }

    runtime = %{
      test_pid: self(),
      operation_scope: ScopeSpy,
      asset_deletions: {DeletionSpy, self()},
      object_lock: {ObjectLockSpy, self()}
    }

    assert {:ok, %{state: :pending_delete, state_revision: 4}} =
             Delete.run(runtime, session, asset_id, 3)

    assert_receive {:scope, :read,
                    %{
                      required_capability: "asset.write",
                      classification: :private,
                      requires_unlocked?: false
                    }}

    assert_receive {:load_delete_target, :read_repo, %{asset_id: ^asset_id, vault_id: ^vault_id}}

    assert_receive {:scope, :shared,
                    %{
                      required_capability: "asset.write",
                      classification: :sensitive,
                      requires_unlocked?: false
                    }}

    assert_receive {:tombstone_and_release, :write_repo,
                    %{
                      asset_id: ^asset_id,
                      vault_id: ^vault_id,
                      principal_id: ^principal_id,
                      classification: :sensitive,
                      expected_state_revision: 3
                    }}
  end

  test "delete redirects without row mutation and tombstones only under the current ObjectLock" do
    asset_id = Ecto.UUID.generate()
    first_object_id = Ecto.UUID.generate()
    current_object_id = Ecto.UUID.generate()

    session = %SessionContext{
      session_id: Ecto.UUID.generate(),
      principal_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.generate(),
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 9,
      authorization_epoch: 7,
      unlocked?: false
    }

    runtime = %{
      test_pid: self(),
      operation_scope: ScopeSpy,
      asset_deletions: {DeleteRaceSpy, self()},
      object_lock: {ObjectLockSpy, self()}
    }

    deletion =
      Task.async(fn ->
        Delete.run(runtime, session, asset_id, 2)
      end)

    assert_receive {:resolve_delete_lock_target, delete_process, :write_repo, command}
    refute_received {:tombstone_and_release, :write_repo, _command}
    send(delete_process, {:resolve_as, self(), first_object_id})

    assert_receive {:object_lock, :write_repo, ^first_object_id}
    assert_receive {:resolve_delete_lock_target, ^delete_process, :write_repo, ^command}
    send(delete_process, {:resolve_as, self(), current_object_id})

    assert_receive {:object_unlock, :write_repo, ^first_object_id}
    refute_received {:tombstone_and_release, :write_repo, _command}

    assert_receive {:object_lock, :write_repo, ^current_object_id}
    assert_receive {:resolve_delete_lock_target, ^delete_process, :write_repo, ^command}
    send(delete_process, {:resolve_as, self(), current_object_id})

    assert {:ok, %{state: :pending_delete, state_revision: 3}} =
             Task.await(deletion)

    assert_receive {:tombstone_and_release, :write_repo, %{locked_object_id: ^current_object_id}}

    assert_receive {:object_unlock, :write_repo, ^current_object_id}
  end

  test "logical cleanup reauthorizes and commits only through the worker transaction" do
    envelope = job_envelope("asset_cleanup", "asset.write")
    test_pid = self()

    context = %{
      asset_deletions: {DeletionSpy, test_pid},
      authorization: :authorization,
      authorize: {JobAuthorizationSpy, test_pid},
      transact: fn options, callback ->
        send(test_pid, {:transact, options})
        callback.(:worker_repo)
      end
    }

    assert {:ok, %{state: :deleted, state_revision: 5}} =
             Cleanup.run(context, envelope)

    assert_receive {:transact, []}
    assert_receive {:check_job, :authorization, :worker_repo, ^envelope}
    assert_receive {:complete_logical_delete, :worker_repo, ^envelope}
  end

  test "physical cleanup takes ObjectLock last and durably acknowledges deletion" do
    object_id = Ecto.UUID.generate()
    envelope = object_cleanup_envelope(object_id)
    test_pid = self()

    context = %{
      repo_handle: :pinned_repo,
      asset_deletions: {DeletionSpy, test_pid},
      authorization: :authorization,
      authorize: {JobAuthorizationSpy, test_pid},
      object_lock: {ObjectLockSpy, test_pid},
      storage: {StorageDeletionSpy, test_pid},
      transact: fn options, callback ->
        send(test_pid, {:transact, options})
        callback.(:worker_repo)
      end
    }

    assert {:ok, %{id: ^object_id, lifecycle: :deleted}} =
             ObjectCleanup.run(context, envelope)

    assert_receive {:object_lock, :pinned_repo, ^object_id}
    assert_receive {:transact, []}
    assert_receive {:check_job, :authorization, :worker_repo, ^envelope}
    assert_receive {:claim_orphan_delete, :worker_repo, ^envelope}
    assert_receive {:storage_delete, %ObjectRef{object_id: ^object_id}}
    assert_receive {:transact, []}

    assert_receive {:acknowledge_object_deleted, :worker_repo,
                    %{
                      object_ref: %ObjectRef{object_id: ^object_id},
                      claim_token: claim_token
                    }}

    assert claim_token == envelope.job_id
    refute_received {:check_job, :authorization, :worker_repo, ^envelope}
  end

  test "physical cleanup rejects a substituted capability before taking ObjectLock" do
    envelope =
      Ecto.UUID.generate()
      |> object_cleanup_envelope()
      |> Map.put(:required_capability, "asset.write")

    assert {:error, %Singularity.Core.Error{code: :invalid}} =
             ObjectCleanup.run(
               %{
                 repo_handle: :pinned_repo,
                 asset_deletions: {DeletionSpy, self()},
                 authorization: :authorization,
                 authorize: {JobAuthorizationSpy, self()},
                 object_lock: {ObjectLockSpy, self()},
                 storage: {StorageDeletionSpy, self()},
                 transact: fn _options, callback ->
                   callback.(:worker_repo)
                 end
               },
               envelope
             )

    refute_received {:object_lock, _repo, _object_id}
    refute_received {:storage_delete, _object_ref}
  end

  defp job_envelope(job_type, required_capability) do
    {:ok, envelope} =
      JobEnvelope.new(%{
        version: 1,
        job_id: Ecto.UUID.generate(),
        job_type: job_type,
        idempotency_key: "#{job_type}:#{Ecto.UUID.generate()}",
        vault_id: Ecto.UUID.generate(),
        principal_id: Ecto.UUID.generate(),
        required_capability: required_capability,
        principal_authorization_epoch: 7,
        vault_authorization_epoch: 9,
        classification: :private,
        correlation_id: Ecto.UUID.generate(),
        causation_id: Ecto.UUID.generate(),
        expected_entity_revision: 4,
        attempt: 0,
        payload: %{"asset_id" => Ecto.UUID.generate()}
      })

    envelope
  end

  defp object_cleanup_envelope(object_id) do
    {:ok, envelope} =
      JobEnvelope.new(%{
        version: 1,
        job_id: Ecto.UUID.generate(),
        job_type: "object_cleanup",
        idempotency_key: "object-cleanup:#{object_id}:2",
        vault_id: Ecto.UUID.generate(),
        principal_id: Ecto.UUID.generate(),
        required_capability: "object.cleanup",
        principal_authorization_epoch: 7,
        vault_authorization_epoch: 9,
        classification: :private,
        correlation_id: Ecto.UUID.generate(),
        causation_id: Ecto.UUID.generate(),
        expected_entity_revision: 2,
        attempt: 0,
        payload: %{"asset_id" => Ecto.UUID.generate(), "object_id" => object_id}
      })

    envelope
  end
end
