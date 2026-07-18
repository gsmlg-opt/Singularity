defmodule Singularity.Storage.AuthorizationLockTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock

  test "refuses direct use without an already checked-out repository connection" do
    principal_id = Ecto.UUID.generate()
    vault_id = Ecto.UUID.generate()

    for operation <- [&AuthorizationLock.with_shared/4, &AuthorizationLock.with_exclusive/4] do
      assert_raise ArgumentError,
                   ~r/requires an already checked-out repository connection/,
                   fn ->
                     operation.(WorkerRepo, principal_id, vault_id, fn _repo -> :unexpected end)
                   end
    end
  end

  test "uses the existing checked-out handle and serializes shared before exclusive" do
    principal_id = Ecto.UUID.generate()
    vault_id = Ecto.UUID.generate()
    parent = self()

    shared =
      Task.async(fn ->
        VaultLock.with_shared(WorkerRepo, vault_id, fn repo ->
          AuthorizationLock.with_shared(repo, principal_id, vault_id, fn checked_out_repo ->
            send(parent, {:authorization_shared, checked_out_repo})

            receive do
              :release_authorization -> :operation_finished
            end
          end)
        end)
      end)

    assert_receive {:authorization_shared, WorkerRepo}

    exclusive =
      Task.async(fn ->
        VaultLock.with_shared(WorkerRepo, vault_id, fn repo ->
          AuthorizationLock.with_exclusive(repo, principal_id, vault_id, fn _checked_out_repo ->
            send(parent, :authorization_exclusive)
            :revocation_finished
          end)
        end)
      end)

    refute_receive :authorization_exclusive, 100
    send(shared.pid, :release_authorization)
    assert Task.await(shared) == :operation_finished
    assert_receive :authorization_exclusive
    assert Task.await(exclusive) == :revocation_finished
  end

  test "revocation linearized first makes the later operation fail before its effect" do
    %{one: one} = Fixtures.two_vaults!()
    parent = self()

    revocation =
      Task.async(fn ->
        VaultLock.with_shared(WorkerRepo, one.vault_id, fn repo ->
          AuthorizationLock.with_exclusive(
            repo,
            one.principal_id,
            one.vault_id,
            fn _checked_out_repo ->
              Fixtures.revoke_membership!(one)
              send(parent, :revocation_committed)

              receive do
                :release_revocation -> :revoked
              end
            end
          )
        end)
      end)

    assert_receive :revocation_committed

    operation =
      Task.async(fn ->
        VaultLock.with_shared(WorkerRepo, one.vault_id, fn repo ->
          send(parent, :operation_waiting_for_authorization)

          AuthorizationLock.with_shared(
            repo,
            one.principal_id,
            one.vault_id,
            fn checked_out_repo ->
              ScopedRepo.transact(
                checked_out_repo,
                %{principal_id: one.principal_id, vault_id: one.vault_id},
                fn scoped_repo ->
                  %{rows: [[authorized?]]} =
                    query!(
                      scoped_repo,
                      "SELECT core.principal_is_authorized($1, $2)",
                      [one.principal_id, one.vault_id]
                    )

                  if authorized? do
                    send(parent, :effect_written)
                    :effect_written
                  else
                    :unauthorized
                  end
                end
              )
            end
          )
        end)
      end)

    assert_receive :operation_waiting_for_authorization
    refute_receive :effect_written, 100

    send(revocation.pid, :release_revocation)

    assert Task.await(revocation) == :revoked
    assert Task.await(operation) == :unauthorized
    refute_receive :effect_written
  end
end
