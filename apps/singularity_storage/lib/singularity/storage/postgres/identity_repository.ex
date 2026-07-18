defmodule Singularity.Storage.Postgres.IdentityRepository do
  @moduledoc false

  @behaviour Singularity.Domains.Identity.Repository

  alias Ecto.Adapters.SQL
  alias Ecto.Multi
  import Ecto.Query
  alias Singularity.Core.Error
  alias Singularity.Storage.Schema.Identity.Account
  alias Singularity.Storage.Schema.Identity.Credential
  alias Singularity.Storage.Schema.Identity.Person
  alias Singularity.Storage.Schema.Identity.Principal
  alias Singularity.Storage.Postgres.UUID

  @bootstrap_digests_key "bootstrap_idempotency_key_digests"

  @impl true
  def bootstrap_owner(
        repo,
        %{owner: %{id: owner_id, kind: :owner}, credential: %{id: credential_id}} = command
      ) do
    with :ok <- UUID.validate([owner_id, credential_id]) do
      digest = idempotency_digest(command.idempotency_key)

      lock_bootstrap(repo, digest, owner_id, credential_id)

      case owner_by_idempotency_digest(repo, digest) do
        nil -> bootstrap_unbound_key(repo, command, digest)
        %Principal{} = owner -> existing_owner(repo, owner)
      end
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def bootstrap_owner(_repo, _command), do: {:error, Error.new(:invalid)}

  defp bootstrap_unbound_key(repo, command, digest) do
    case repo.get(Principal, command.owner.id) do
      nil -> insert_owner_if_credential_available(repo, command, digest)
      %Principal{kind: :owner} = owner -> bind_idempotency_digest(repo, owner, digest)
      %Principal{} -> {:error, Error.new(:conflict)}
    end
  end

  defp insert_owner_if_credential_available(repo, command, digest) do
    case repo.get(Credential, command.credential.id) do
      nil -> insert_owner(repo, command, digest)
      %Credential{} -> {:error, Error.new(:conflict)}
    end
  end

  defp insert_owner(repo, command, digest) do
    owner_id = command.owner.id
    credential = command.credential

    Multi.new()
    |> Multi.insert(
      :person,
      Person.create_changeset(%Person{}, %{
        id: owner_id,
        display_name: "Owner",
        metadata: %{}
      })
    )
    |> Multi.insert(
      :account,
      Account.create_changeset(%Account{}, %{
        id: owner_id,
        person_id: owner_id,
        status: :active,
        metadata: %{}
      })
    )
    |> Multi.insert(
      :credential,
      Credential.create_changeset(%Credential{}, %{
        id: credential.id,
        account_id: owner_id,
        normalized_login: "owner+#{String.downcase(owner_id)}@singularity.local",
        verifier: credential.secret_hash,
        verifier_version: 1
      })
    )
    |> Multi.insert(
      :principal,
      Principal.create_changeset(%Principal{}, %{
        id: owner_id,
        account_id: owner_id,
        kind: :owner,
        authorization_epoch: 0,
        metadata: %{@bootstrap_digests_key => [digest]}
      })
    )
    |> repo.transaction()
    |> case do
      {:ok, %{principal: principal, credential: stored_credential}} ->
        {:ok, domain_result(principal, stored_credential)}

      {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset_error(changeset)}

      {:error, _operation, _reason, _changes} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp bind_idempotency_digest(repo, owner, digest) do
    digests =
      owner.metadata
      |> Map.get(@bootstrap_digests_key, [])
      |> then(fn digests ->
        if digest in digests, do: digests, else: [digest | digests]
      end)

    owner
    |> Principal.create_changeset(%{
      metadata: Map.put(owner.metadata, @bootstrap_digests_key, digests)
    })
    |> repo.update()
    |> case do
      {:ok, updated_owner} -> existing_owner(repo, updated_owner)
      {:error, changeset} -> {:error, changeset_error(changeset)}
    end
  end

  defp owner_by_idempotency_digest(repo, digest) do
    repo.one(
      from principal in Principal,
        where: principal.kind == :owner,
        where:
          fragment(
            "? @> ?",
            principal.metadata,
            type(^%{@bootstrap_digests_key => [digest]}, :map)
          ),
        limit: 1
    )
  end

  defp lock_bootstrap(repo, digest, owner_id, credential_id) do
    ["key:" <> digest, "owner:" <> owner_id, "credential:" <> credential_id]
    |> Enum.each(fn lock_key ->
      SQL.query!(
        repo,
        "SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))",
        ["singularity:owner-bootstrap:" <> lock_key],
        log: false
      )
    end)
  end

  defp idempotency_digest(idempotency_key) do
    idempotency_key
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp existing_owner(repo, owner) do
    case repo.one(
           from credential in Credential,
             where: credential.account_id == ^owner.account_id,
             order_by: [asc: credential.inserted_at],
             limit: 1
         ) do
      nil -> {:error, Error.new(:not_found)}
      credential -> {:ok, domain_result(owner, credential)}
    end
  end

  defp domain_result(owner, credential) do
    %{
      owner: %{id: owner.id, kind: owner.kind},
      credential: %{id: credential.id, secret_hash: credential.verifier}
    }
  end

  defp changeset_error(changeset) do
    if Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
         metadata[:constraint] == :unique
       end),
       do: Error.new(:conflict),
       else: Error.new(:invalid)
  end

  defp database_error(%Postgrex.Error{postgres: %{code: :unique_violation}}),
    do: Error.new(:conflict)

  defp database_error(_error),
    do: Error.new(:storage_unavailable, retryable?: true)
end
