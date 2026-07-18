Code.require_file("../../support/fake/identity_repository.ex", __DIR__)

defmodule Singularity.Domains.IdentityTest do
  use ExUnit.Case, async: true

  alias Singularity.Domains.Identity

  setup do
    start_supervised!(%{
      id: make_ref(),
      start: {Fake.IdentityRepository, :start_link, []}
    })
    |> then(&{:ok, adapters: %{repository: Fake.IdentityRepository, context: &1}})
  end

  test "bootstraps one owner and keeps its original credential across retries", %{
    adapters: adapters
  } do
    command = %{
      idempotency_key: "owner-bootstrap-1",
      owner: %{id: "owner-1", kind: :owner},
      credential: %{id: "credential-1", secret_hash: "first-hash"}
    }

    assert {:ok, %{owner: owner, credential: credential}} =
             Identity.bootstrap_owner(adapters, command)

    assert owner == command.owner
    assert credential == command.credential

    assert {:ok, %{owner: ^owner, credential: ^credential}} =
             Identity.bootstrap_owner(adapters, command)

    replacement_command = %{
      command
      | idempotency_key: "owner-bootstrap-2",
        credential: %{id: "credential-2", secret_hash: "replacement-hash"}
    }

    assert {:ok, %{owner: ^owner, credential: ^credential}} =
             Identity.bootstrap_owner(adapters, replacement_command)
  end

  test "a retry key accepted for an existing owner stays bound to that bootstrap", %{
    adapters: adapters
  } do
    initial_command = %{
      idempotency_key: "owner-bootstrap-initial",
      owner: %{id: "owner-1", kind: :owner},
      credential: %{id: "credential-1", secret_hash: "first-hash"}
    }

    assert {:ok, bootstrap} = Identity.bootstrap_owner(adapters, initial_command)

    accepted_retry = %{
      initial_command
      | idempotency_key: "owner-bootstrap-retry",
        credential: %{id: "credential-replacement", secret_hash: "replacement-hash"}
    }

    assert {:ok, ^bootstrap} = Identity.bootstrap_owner(adapters, accepted_retry)

    conflicting_reuse = %{
      accepted_retry
      | owner: %{id: "owner-2", kind: :owner},
        credential: %{id: "credential-2", secret_hash: "second-hash"}
    }

    assert {:ok, ^bootstrap} = Identity.bootstrap_owner(adapters, conflicting_reuse)
  end
end
