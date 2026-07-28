defmodule Singularity.Storage.Postgres.IdentityRepositoryTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Ecto.Adapters.SQL
  import Ecto.Query
  alias Singularity.Core.Error
  alias Singularity.Domains.Identity
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.Postgres.PreAuth
  alias Singularity.Storage.PreAuthRepo
  alias Singularity.Storage.Schema.Identity.Account
  alias Singularity.Storage.Schema.Identity.Credential
  alias Singularity.Storage.Schema.Identity.Person
  alias Singularity.Storage.Schema.Identity.Principal

  setup do
    Fixtures.reset_bootstrap_state!()
    start_supervised!({MigrationRepo, pool_size: 4})
    :ok
  end

  test "concurrent owner bootstrap preserves the first credential" do
    owner_id = Ecto.UUID.generate()

    command = %{
      idempotency_key: "owner-bootstrap-#{owner_id}",
      owner: %{id: owner_id, kind: :owner},
      credential: %{id: Ecto.UUID.generate(), secret_hash: "first-hash"}
    }

    results =
      1..2
      |> Task.async_stream(
        fn _attempt ->
          owner_transaction(fn repo ->
            Identity.bootstrap_owner(
              %{repository: IdentityRepository, context: repo},
              command
            )
          end)
        end,
        max_concurrency: 2,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    assert [first, second] = results
    assert first == second
    assert first.owner == command.owner
    assert first.credential == command.credential

    replacement = %{
      command
      | idempotency_key: "replacement-#{owner_id}",
        credential: %{id: Ecto.UUID.generate(), secret_hash: "replacement-hash"}
    }

    assert {:ok, persisted} =
             owner_transaction(fn repo ->
               Identity.bootstrap_owner(
                 %{repository: IdentityRepository, context: repo},
                 replacement
               )
             end)

    assert persisted == first
  end

  test "a normalized idempotency key remains bound to its first owner aggregate" do
    owner_id = Ecto.UUID.generate()
    other_owner_id = Ecto.UUID.generate()
    idempotency_key = "owner-bootstrap-shared-#{owner_id}"

    first_command =
      bootstrap_command(owner_id, "  #{idempotency_key}  ", "first-hash")

    conflicting_command =
      bootstrap_command(other_owner_id, idempotency_key, "replacement-hash")

    counts_before = identity_counts()

    assert {:ok, first} = bootstrap(first_command)
    assert {:ok, persisted} = bootstrap(conflicting_command)

    assert persisted == first
    assert first.owner == first_command.owner

    assert incremented(identity_counts(), counts_before) == %{
             accounts: 1,
             credentials: 1,
             people: 1,
             principals: 1
           }

    assert [metadata] =
             owner_transaction(fn repo ->
               repo.all(
                 from principal in Principal,
                   where: principal.id == ^owner_id,
                   select: principal.metadata
               )
             end)

    digest = :crypto.hash(:sha256, idempotency_key) |> Base.encode16(case: :lower)

    assert metadata["bootstrap_idempotency_key_digests"] == [digest]
    refute inspect(metadata) =~ idempotency_key
  end

  test "a new key accepted for an existing owner becomes a durable alias" do
    owner_id = Ecto.UUID.generate()
    other_owner_id = Ecto.UUID.generate()

    initial_command =
      bootstrap_command(owner_id, "owner-bootstrap-initial-#{owner_id}", "first-hash")

    alias_key = "owner-bootstrap-alias-#{owner_id}"

    accepted_alias =
      bootstrap_command(owner_id, alias_key, "replacement-hash")

    conflicting_reuse =
      bootstrap_command(other_owner_id, alias_key, "other-hash")

    counts_before = identity_counts()

    assert {:ok, first} = bootstrap(initial_command)
    assert {:ok, ^first} = bootstrap(accepted_alias)
    assert {:ok, ^first} = bootstrap(conflicting_reuse)

    assert incremented(identity_counts(), counts_before) == %{
             accounts: 1,
             credentials: 1,
             people: 1,
             principals: 1
           }
  end

  test "concurrent different bootstrap keys create one global owner aggregate" do
    first_owner_id = Ecto.UUID.generate()
    second_owner_id = Ecto.UUID.generate()

    commands = [
      bootstrap_command(
        first_owner_id,
        "owner-bootstrap-first-#{first_owner_id}",
        "first-hash"
      ),
      bootstrap_command(
        second_owner_id,
        "owner-bootstrap-second-#{second_owner_id}",
        "second-hash"
      )
    ]

    counts_before = identity_counts()

    results =
      commands
      |> Task.async_stream(&bootstrap/1, max_concurrency: 2, timeout: 5_000)
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    assert [first, second] = results
    assert first == second
    assert first.owner.id in [first_owner_id, second_owner_id]

    assert incremented(identity_counts(), counts_before) == %{
             accounts: 1,
             credentials: 1,
             people: 1,
             principals: 1
           }
  end

  test "a later bootstrap reusing a credential id returns the global owner" do
    first_owner_id = Ecto.UUID.generate()

    first_command =
      bootstrap_command(first_owner_id, "owner-bootstrap-first-#{first_owner_id}", "first-hash")

    assert {:ok, first} = bootstrap(first_command)

    second_owner_id = Ecto.UUID.generate()

    second_command =
      second_owner_id
      |> bootstrap_command("owner-bootstrap-second-#{second_owner_id}", "second-hash")
      |> put_in([:credential, :id], first_command.credential.id)

    counts_before = identity_counts()

    assert {:ok, ^first} = bootstrap(second_command)
    assert identity_counts() == counts_before
  end

  test "bootstrap rejects every malformed structured UUID without effects" do
    owner_id = Ecto.UUID.generate()

    command =
      bootstrap_command(
        owner_id,
        "invalid-uuid-bootstrap-#{owner_id}",
        "stored-verifier"
      )

    cases = [
      {:owner_id, [:owner, :id]},
      {:credential_id, [:credential, :id]}
    ]

    for {field, path} <- cases,
        invalid_uuid <- invalid_uuids() do
      counts_before = identity_counts()
      malformed = put_path(command, path, invalid_uuid)

      assert {:error, %Error{code: :invalid}} = bootstrap(malformed),
             "expected #{field}=#{inspect(invalid_uuid)} to be rejected"

      assert identity_counts() == counts_before
    end
  end

  test "identity metadata recursively accepts JSON and rejects non-JSON values" do
    id = Ecto.UUID.generate()

    schemas_and_attrs = [
      {Person, %{id: id, display_name: "Owner"}},
      {Account, %{id: id, person_id: id, status: :active}},
      {Principal, %{id: id, account_id: id, kind: :owner, authorization_epoch: 0}}
    ]

    invalid_metadata = [
      %{"profile" => [%{"valid" => true}, %{invalid: "atom key"}]},
      %{"profile" => %{"value" => :not_json}},
      %{"profile" => %{"value" => {:not, "json"}}},
      %{"profile" => %{"value" => self()}}
    ]

    valid_metadata = %{
      "profile" => [
        %{"name" => "Owner", "enabled" => true, "score" => 1.5},
        %{"aliases" => ["primary", nil], "count" => 2}
      ]
    }

    for {schema, attrs} <- schemas_and_attrs do
      assert schema.create_changeset(struct(schema), Map.put(attrs, :metadata, valid_metadata)).valid?

      for metadata <- invalid_metadata do
        changeset = schema.create_changeset(struct(schema), Map.put(attrs, :metadata, metadata))

        refute changeset.valid?
        assert {"must use string keys and JSON values", _options} = changeset.errors[:metadata]
      end
    end
  end

  test "pre-auth adapter exposes only the approved definer functions" do
    owner_id = Ecto.UUID.generate()

    command = %{
      idempotency_key: "pre-auth-owner-#{owner_id}",
      owner: %{id: owner_id, kind: :owner},
      credential: %{id: Ecto.UUID.generate(), secret_hash: "stored-verifier"}
    }

    assert {:ok, _owner} =
             owner_transaction(fn repo ->
               Identity.bootstrap_owner(
                 %{repository: IdentityRepository, context: repo},
                 command
               )
             end)

    login = "owner+#{owner_id}@singularity.local"
    credential_id = command.credential.id

    assert {:ok,
            %{
              credential_id: ^credential_id,
              account_id: ^owner_id,
              verifier: "stored-verifier",
              verifier_version: 1
            }} = PreAuth.authentication_candidate(PreAuthRepo, login)

    assert {:ok, %{accepted?: true}} =
             PreAuth.record_auth_attempt(PreAuthRepo, %{
               login_fingerprint: :crypto.hash(:sha256, login),
               source_fingerprint: :crypto.hash(:sha256, "127.0.0.1"),
               audit_fingerprint: :crypto.hash(:sha256, [login, <<0>>, "127.0.0.1"]),
               result: :started,
               correlation_id: Ecto.UUID.generate()
             })
  end

  test "pre-auth callbacks reject malformed non-UUID boundary inputs without effects" do
    counts_before = identity_counts()

    assert {:error, %Error{code: :invalid}} =
             PreAuth.authentication_candidate(PreAuthRepo, nil)

    assert {:error, %Error{code: :invalid}} =
             PreAuth.resolve_session(PreAuthRepo, <<0, 1>>)

    assert {:error, %Error{code: :invalid}} =
             PreAuth.record_auth_attempt(PreAuthRepo, %{
               login_fingerprint: <<0, 1>>,
               source_fingerprint: :crypto.hash(:sha256, "source"),
               result: :started
             })

    assert identity_counts() == counts_before
  end

  defp owner_transaction(fun) do
    case MigrationRepo.transaction(fn ->
           SQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [], log: false)
           fun.(MigrationRepo)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp bootstrap(command) do
    owner_transaction(fn repo ->
      Identity.bootstrap_owner(
        %{repository: IdentityRepository, context: repo},
        command
      )
    end)
  end

  defp bootstrap_command(owner_id, idempotency_key, secret_hash) do
    %{
      idempotency_key: idempotency_key,
      owner: %{id: owner_id, kind: :owner},
      credential: %{id: Ecto.UUID.generate(), secret_hash: secret_hash}
    }
  end

  defp identity_counts do
    owner_transaction(fn repo ->
      %{
        accounts: repo.aggregate(Account, :count),
        credentials: repo.aggregate(Credential, :count),
        people: repo.aggregate(Person, :count),
        principals: repo.aggregate(Principal, :count)
      }
    end)
  end

  defp incremented(current, previous) do
    Map.new(current, fn {key, value} -> {key, value - Map.fetch!(previous, key)} end)
  end

  defp invalid_uuids,
    do: ["not-a-uuid", <<0, 1>>, "warehouse worker", String.duplicate("x", 36)]

  defp put_path(data, path, value) do
    put_in(data, Enum.map(path, &Access.key/1), value)
  end
end
