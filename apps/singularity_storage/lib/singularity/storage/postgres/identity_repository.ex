defmodule Singularity.Storage.Postgres.IdentityRepository do
  @moduledoc false

  @behaviour Singularity.Domains.Identity.Repository

  alias Ecto.Adapters.SQL
  alias Ecto.Multi
  import Ecto.Query
  alias Singularity.Core.Error
  alias Singularity.Storage.Postgres.UUID
  alias Singularity.Storage.Schema.Core.Capability
  alias Singularity.Storage.Schema.Core.DomainDedupKeyWrapper
  alias Singularity.Storage.Schema.Core.DomainKeyVersion
  alias Singularity.Storage.Schema.Core.KeyDomain
  alias Singularity.Storage.Schema.Core.PrincipalCapability
  alias Singularity.Storage.Schema.Core.Vault
  alias Singularity.Storage.Schema.Core.VaultKeyVersion
  alias Singularity.Storage.Schema.Core.VaultKeyWrapper
  alias Singularity.Storage.Schema.Core.VaultMember
  alias Singularity.Storage.Schema.Audit.Event
  alias Singularity.Storage.Schema.Identity.Account
  alias Singularity.Storage.Schema.Identity.Credential
  alias Singularity.Storage.Schema.Identity.Person
  alias Singularity.Storage.Schema.Identity.Principal
  alias Singularity.Storage.Schema.Identity.Session
  alias Singularity.Storage.ScopedRepo

  @bootstrap_digests_key "bootstrap_idempotency_key_digests"
  @live_session_columns ~w[
    session_id
    account_id
    session_expires_at
    session_revoked_at
    credential_id
    credential_revision
    principal_id
    principal_kind
    principal_authorization_epoch
    principal_revoked_at
    vault_id
    vault_authorization_epoch
    vault_locked
    membership_revoked_at
    clearance
    capabilities
  ]
  @live_principal_columns ~w[
    principal_id
    principal_kind
    principal_authorization_epoch
    principal_revoked_at
    vault_id
    vault_authorization_epoch
    vault_locked
    membership_revoked_at
    clearance
    capabilities
  ]

  @impl true
  def bootstrap_owner(
        repo,
        %{
          person: %{id: owner_id},
          account: %{id: owner_id},
          credential: %{id: credential_id},
          principal: %{id: owner_id, kind: :owner},
          vault: %{id: vault_id},
          key_domain: %{id: key_domain_id},
          vault_key_version: %{id: vault_key_version_id},
          vault_key_wrapper: %{id: vault_key_wrapper_id},
          domain_key_version: %{id: domain_key_version_id},
          domain_dedup_key_wrapper: %{id: dedup_wrapper_id}
        } = command
      ) do
    ids = [
      owner_id,
      credential_id,
      vault_id,
      key_domain_id,
      vault_key_version_id,
      vault_key_wrapper_id,
      domain_key_version_id,
      dedup_wrapper_id
    ]

    with :ok <- UUID.validate(ids),
         :ok <- validate_complete_command(command) do
      command = Map.put(command, :owner, %{id: owner_id, kind: :owner})
      bootstrap_in_transaction(repo, command, :complete)
    end
  rescue
    _error in [Ecto.Query.CastError, KeyError] ->
      {:error, Error.new(:invalid)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def bootstrap_owner(
        repo,
        %{owner: %{id: owner_id, kind: :owner}, credential: %{id: credential_id}} = command
      ) do
    with :ok <- UUID.validate([owner_id, credential_id]) do
      bootstrap_in_transaction(repo, command, :minimal)
    end
  rescue
    _error in [Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  def bootstrap_owner(_repo, _command), do: {:error, Error.new(:invalid)}

  def create_session_and_audit(
        %{
          repo: repo,
          clock: clock,
          session_ttl_seconds: session_ttl_seconds
        },
        %{
          account_id: account_id,
          principal_id: principal_id,
          vault_id: vault_id
        } = scoped_context,
        %{
          token_digest: <<_::binary-size(32)>> = token_digest,
          correlation_id: correlation_id
        },
        audit_result: "allowed"
      )
      when is_atom(repo) and is_function(clock, 0) and
             is_integer(session_ttl_seconds) and session_ttl_seconds > 0 do
    with :ok <- UUID.validate([account_id, principal_id, vault_id, correlation_id]) do
      repo.checkout(fn ->
        ScopedRepo.transact(repo, scoped_context, fn transaction_repo ->
          insert_session_and_audit(
            transaction_repo,
            scoped_context,
            token_digest,
            correlation_id,
            clock.(),
            session_ttl_seconds
          )
        end)
      end)
    end
  rescue
    _error in [Ecto.Query.CastError, ArgumentError] ->
      {:error, Error.new(:invalid)}

    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, Error.new(:storage_unavailable, retryable?: true)}
  end

  def create_session_and_audit(_context, _scope, _command, _options),
    do: {:error, Error.new(:invalid)}

  def load_live_session(repo, session_id) when is_binary(session_id) do
    with {:ok, dumped_session_id} <- UUID.dump(session_id) do
      case SQL.query(
             repo,
             "SELECT * FROM core.live_session_authorization($1)",
             [dumped_session_id],
             log: false
           ) do
        {:ok, %{columns: @live_session_columns, rows: []}} ->
          {:ok, nil}

        {:ok, %{columns: @live_session_columns, rows: [row]}} ->
          load_live_session_row(row)

        {:ok, _unexpected_result} ->
          invalid_snapshot()

        {:error, _reason} ->
          storage_unavailable()
      end
    else
      :error -> {:error, Error.new(:invalid)}
    end
  end

  def load_live_session(_repo, _session_id), do: {:error, Error.new(:invalid)}

  def load_live_principal(repo, principal_id, vault_id)
      when is_binary(principal_id) and is_binary(vault_id) do
    with {:ok, dumped_principal_id} <- UUID.dump(principal_id),
         {:ok, dumped_vault_id} <- UUID.dump(vault_id) do
      case SQL.query(
             repo,
             """
             SELECT *
             FROM core.live_principal_authorization()
             WHERE principal_id = $1 AND vault_id = $2
             """,
             [dumped_principal_id, dumped_vault_id],
             log: false
           ) do
        {:ok, %{columns: @live_principal_columns, rows: []}} ->
          {:ok, nil}

        {:ok, %{columns: @live_principal_columns, rows: [row]}} ->
          load_live_principal_row(row)

        {:ok, _unexpected_result} ->
          invalid_snapshot()

        {:error, _reason} ->
          storage_unavailable()
      end
    else
      :error -> {:error, Error.new(:invalid)}
    end
  end

  def load_live_principal(_repo, _principal_id, _vault_id),
    do: {:error, Error.new(:invalid)}

  def update_credential_verifier(
        repo,
        session_id,
        credential_id,
        %DateTime{} = credential_revision,
        verifier
      )
      when is_binary(session_id) and is_binary(credential_id) and is_binary(verifier) do
    with true <- byte_size(String.trim(verifier)) > 0,
         {:ok, dumped_session_id} <- UUID.dump(session_id),
         {:ok, dumped_credential_id} <- UUID.dump(credential_id) do
      case SQL.query(
             repo,
             """
             SELECT identity.update_scoped_credential_verifier($1, $2, $3, $4)
             """,
             [
               dumped_session_id,
               dumped_credential_id,
               credential_revision,
               verifier
             ],
             log: false
           ) do
        {:ok, %{rows: [[updated?]]}} when is_boolean(updated?) ->
          {:ok, updated?}

        {:ok, _unexpected_result} ->
          invalid_snapshot()

        {:error, _reason} ->
          storage_unavailable()
      end
    else
      false -> {:error, Error.new(:invalid)}
      :error -> {:error, Error.new(:invalid)}
    end
  end

  def update_credential_verifier(
        _repo,
        _session_id,
        _credential_id,
        _credential_revision,
        _verifier
      ),
      do: {:error, Error.new(:invalid)}

  def load_unlock_material(
        repo,
        %{
          session_id: session_id,
          principal_id: principal_id,
          vault_id: vault_id
        } = command
      ) do
    runtime_operation(fn ->
      with :ok <- UUID.validate([session_id, principal_id, vault_id]),
           :ok <-
             ensure_scoped_identity(
               repo,
               principal_id,
               vault_id,
               :not_found
             ),
           {:ok, live_session} <- load_scoped_live_session(repo, command),
           {:ok, vault_wrapper} <-
             load_active_vault_wrapper(repo, %{
               account_id: live_session.account_id,
               vault_id: vault_id
             }),
           {:ok, domain_key_version} <-
             load_active_domain_key_version(
               repo,
               vault_id,
               vault_wrapper.vault_key_version_id
             ) do
        {:ok,
         %{
           vault_wrapper: vault_wrapper,
           domain_key_version: domain_key_version
         }}
      end
    end)
  end

  def load_unlock_material(_repo, _command),
    do: {:error, Error.new(:invalid)}

  def load_password_material(
        repo,
        %{
          session_id: session_id,
          principal_id: principal_id,
          vault_id: vault_id
        } = command
      ) do
    runtime_operation(fn ->
      with :ok <- UUID.validate([session_id, principal_id, vault_id]),
           {:ok, %{vault_wrapper: vault_wrapper}} <-
             load_unlock_material(repo, command),
           {:ok, credential} <- load_scoped_credential(repo, command) do
        {:ok,
         %{
           credential_id: credential.id,
           credential_revision: credential.revision,
           vault_wrapper: vault_wrapper
         }}
      end
    end)
  end

  def load_password_material(_repo, _command),
    do: {:error, Error.new(:invalid)}

  def unlock_and_audit(
        repo,
        %{
          session_id: session_id,
          principal_id: principal_id,
          vault_id: vault_id,
          vault_key_version_id: vault_key_version_id,
          domain_key_version_id: domain_key_version_id,
          correlation_id: correlation_id
        } = command
      ) do
    runtime_operation(fn ->
      with :ok <-
             UUID.validate([
               session_id,
               principal_id,
               vault_id,
               vault_key_version_id,
               domain_key_version_id,
               correlation_id
             ]),
           :ok <-
             ensure_scoped_identity(
               repo,
               principal_id,
               vault_id,
               :conflict
             ),
           :ok <- ensure_live_session_binding(repo, command),
           :ok <- ensure_active_unlock_versions(repo, command),
           :ok <- set_vault_lock(repo, vault_id, false),
           :ok <- append_runtime_audit(repo, command, "vault.unlock", :allowed) do
        :ok
      end
    end)
  end

  def unlock_and_audit(_repo, _command),
    do: {:error, Error.new(:invalid)}

  def lock_and_audit(
        repo,
        %{
          session_id: session_id,
          principal_id: principal_id,
          vault_id: vault_id,
          correlation_id: correlation_id
        } = command
      ) do
    runtime_operation(fn ->
      with :ok <- UUID.validate([session_id, principal_id, vault_id, correlation_id]),
           :ok <-
             ensure_scoped_identity(
               repo,
               principal_id,
               vault_id,
               :conflict
             ),
           :ok <- ensure_lock_session_binding(repo, command),
           :ok <- set_vault_lock(repo, vault_id, true),
           :ok <- append_runtime_audit(repo, command, "vault.lock", :completed) do
        :ok
      end
    end)
  end

  def lock_and_audit(_repo, _command),
    do: {:error, Error.new(:invalid)}

  def revoke_session_and_audit(
        repo,
        %{
          session_id: session_id,
          principal_id: principal_id,
          vault_id: vault_id,
          correlation_id: correlation_id
        } = command
      ) do
    runtime_operation(fn ->
      with :ok <- UUID.validate([session_id, principal_id, vault_id, correlation_id]),
           :ok <-
             ensure_scoped_identity(
               repo,
               principal_id,
               vault_id,
               :conflict
             ),
           :ok <- revoke_live_session(repo, command),
           :ok <- set_vault_lock(repo, vault_id, true),
           :ok <-
             append_runtime_audit(
               repo,
               command,
               "identity.logout",
               :completed
             ) do
        :ok
      end
    end)
  end

  def revoke_session_and_audit(_repo, _command),
    do: {:error, Error.new(:invalid)}

  def change_password_and_wrapper(
        repo,
        %{
          session_id: session_id,
          principal_id: principal_id,
          vault_id: vault_id,
          correlation_id: correlation_id,
          credential_id: credential_id,
          credential_revision: %DateTime{} = credential_revision,
          new_verifier: new_verifier,
          wrapper_id: wrapper_id,
          vault_key_version_id: vault_key_version_id,
          expected_wrapped_key: expected_wrapped_key,
          new_kdf_version: new_kdf_version,
          new_kdf_salt: new_kdf_salt,
          new_kdf_parameters: new_kdf_parameters,
          new_wrapper_algorithm: new_wrapper_algorithm,
          new_wrapped_key: new_wrapped_key
        } = command
      )
      when is_binary(new_verifier) and is_binary(expected_wrapped_key) and
             is_integer(new_kdf_version) and is_binary(new_kdf_salt) and
             is_map(new_kdf_parameters) and is_binary(new_wrapper_algorithm) and
             is_binary(new_wrapped_key) do
    runtime_operation(fn ->
      with :ok <-
             UUID.validate([
               session_id,
               principal_id,
               vault_id,
               correlation_id,
               credential_id,
               wrapper_id,
               vault_key_version_id
             ]),
           :ok <-
             ensure_scoped_identity(
               repo,
               principal_id,
               vault_id,
               :conflict
             ),
           :ok <-
             validate_password_replacement(
               new_verifier,
               expected_wrapped_key,
               new_kdf_version,
               new_kdf_salt,
               new_kdf_parameters,
               new_wrapper_algorithm,
               new_wrapped_key
             ),
           :ok <- ensure_live_session_binding(repo, command),
           :ok <-
             update_credential_revision(
               repo,
               session_id,
               credential_id,
               credential_revision,
               new_verifier
             ),
           :ok <- update_vault_wrapper(repo, command),
           :ok <- set_vault_lock(repo, vault_id, true),
           :ok <-
             append_runtime_audit(
               repo,
               command,
               "identity.password_change",
               :completed
             ) do
        :ok
      end
    end)
  end

  def change_password_and_wrapper(_repo, _command),
    do: {:error, Error.new(:invalid)}

  defp bootstrap_in_transaction(repo, command, mode) do
    if repo.in_transaction?() do
      bootstrap_transaction(repo, command, mode)
    else
      case repo.transaction(fn ->
             case bootstrap_transaction(repo, command, mode) do
               {:ok, aggregate} -> aggregate
               {:error, reason} -> repo.rollback(reason)
             end
           end) do
        {:ok, aggregate} -> {:ok, aggregate}
        {:error, %Error{} = error} -> {:error, error}
        {:error, _reason} -> {:error, Error.new(:storage_unavailable, retryable?: true)}
      end
    end
  end

  defp bootstrap_transaction(repo, command, mode) do
    digest = idempotency_digest(command.idempotency_key)
    owner_id = command.owner.id
    credential_id = command.credential.id

    lock_bootstrap(repo, digest, owner_id, credential_id)

    case owner_by_idempotency_digest(repo, digest) do
      nil -> bootstrap_unbound_key(repo, command, digest, mode)
      %Principal{} = owner -> existing_owner(repo, owner, mode)
    end
  end

  defp insert_session_and_audit(
         repo,
         scoped_context,
         token_digest,
         correlation_id,
         now,
         session_ttl_seconds
       ) do
    session_id = Ecto.UUID.generate()
    expires_at = DateTime.add(now, session_ttl_seconds, :second)

    session_changeset =
      Session.create_changeset(%Session{}, %{
        id: session_id,
        account_id: scoped_context.account_id,
        principal_id: scoped_context.principal_id,
        vault_id: scoped_context.vault_id,
        token_digest: token_digest,
        expires_at: expires_at
      })

    audit_changeset =
      Event.append_changeset(%Event{}, %{
        id: Ecto.UUID.generate(),
        vault_id: scoped_context.vault_id,
        actor_kind: :principal,
        principal_id: scoped_context.principal_id,
        operation: "identity.login",
        result: :allowed,
        classification: :private,
        correlation_id: correlation_id,
        metadata: %{},
        occurred_at: now
      })

    with {:ok, session} <- repo.insert(session_changeset),
         {:ok, _audit} <- repo.insert(audit_changeset) do
      {:ok,
       %{
         id: session.id,
         account_id: session.account_id,
         principal_id: session.principal_id,
         vault_id: session.vault_id,
         expires_at: session.expires_at
       }}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_error(changeset)}
    end
  end

  defp bootstrap_unbound_key(repo, command, digest, mode) do
    case repo.get(Principal, command.owner.id) do
      nil -> insert_owner_if_credential_available(repo, command, digest, mode)
      %Principal{kind: :owner} = owner -> bind_idempotency_digest(repo, owner, digest, mode)
      %Principal{} -> {:error, Error.new(:conflict)}
    end
  end

  defp insert_owner_if_credential_available(repo, command, digest, mode) do
    case repo.get(Credential, command.credential.id) do
      nil -> insert_owner(repo, command, digest, mode)
      %Credential{} -> {:error, Error.new(:conflict)}
    end
  end

  defp insert_owner(repo, command, digest, :minimal) do
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
        {:ok, minimal_domain_result(principal, stored_credential)}

      {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset_error(changeset)}

      {:error, _operation, _reason, _changes} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp insert_owner(repo, command, digest, :complete) do
    command =
      update_in(command.principal.metadata, fn metadata ->
        Map.put(metadata, @bootstrap_digests_key, [digest])
      end)

    Multi.new()
    |> Multi.insert(:person, Person.create_changeset(%Person{}, command.person))
    |> Multi.insert(:account, Account.create_changeset(%Account{}, command.account))
    |> Multi.insert(
      :credential,
      Credential.create_changeset(%Credential{}, %{
        id: command.credential.id,
        account_id: command.credential.account_id,
        normalized_login: command.credential.normalized_login,
        verifier: command.credential.secret_hash,
        verifier_version: command.credential.verifier_version
      })
    )
    |> Multi.insert(
      :principal,
      Principal.create_changeset(%Principal{}, command.principal)
    )
    |> Multi.insert(:vault, Vault.create_changeset(%Vault{}, command.vault))
    |> Multi.insert(
      :membership,
      VaultMember.create_changeset(%VaultMember{}, command.membership)
    )
    |> Multi.run(:capabilities, fn transaction_repo, _changes ->
      insert_capabilities(
        transaction_repo,
        command.principal.id,
        command.vault.id,
        command.capabilities
      )
    end)
    |> Multi.insert(
      :key_domain,
      KeyDomain.create_changeset(%KeyDomain{}, command.key_domain)
    )
    |> Multi.insert(
      :vault_key_version,
      VaultKeyVersion.create_changeset(
        %VaultKeyVersion{},
        command.vault_key_version
      )
    )
    |> Multi.insert(
      :vault_key_wrapper,
      VaultKeyWrapper.create_changeset(
        %VaultKeyWrapper{},
        command.vault_key_wrapper
      )
    )
    |> Multi.insert(
      :domain_key_version,
      DomainKeyVersion.create_changeset(
        %DomainKeyVersion{},
        command.domain_key_version
      )
    )
    |> Multi.insert(
      :domain_dedup_key_wrapper,
      DomainDedupKeyWrapper.create_changeset(
        %DomainDedupKeyWrapper{},
        command.domain_dedup_key_wrapper
      )
    )
    |> repo.transaction()
    |> case do
      {:ok, %{principal: principal, credential: credential, vault: vault}} ->
        {:ok, complete_domain_result(principal, credential, vault.id)}

      {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset_error(changeset)}

      {:error, _operation, %Error{} = error, _changes} ->
        {:error, error}

      {:error, _operation, _reason, _changes} ->
        {:error, Error.new(:storage_unavailable, retryable?: true)}
    end
  end

  defp bind_idempotency_digest(repo, owner, digest, mode) do
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
      {:ok, updated_owner} -> existing_owner(repo, updated_owner, mode)
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

  defp existing_owner(repo, owner, mode) do
    case repo.one(
           from credential in Credential,
             where: credential.account_id == ^owner.account_id,
             order_by: [asc: credential.inserted_at],
             limit: 1
         ) do
      nil -> {:error, Error.new(:not_found)}
      credential -> existing_domain_result(repo, owner, credential, mode)
    end
  end

  defp existing_domain_result(_repo, owner, credential, :minimal),
    do: {:ok, minimal_domain_result(owner, credential)}

  defp existing_domain_result(repo, owner, credential, :complete) do
    vault_id =
      repo.one(
        from member in VaultMember,
          join: vault in Vault,
          on: vault.id == member.vault_id,
          where: member.principal_id == ^owner.id,
          where: is_nil(member.revoked_at),
          where: vault.kind == :personal,
          order_by: [asc: member.inserted_at],
          select: member.vault_id,
          limit: 1
      )

    if is_nil(vault_id),
      do: {:error, Error.new(:not_found)},
      else: {:ok, complete_domain_result(owner, credential, vault_id)}
  end

  defp minimal_domain_result(owner, credential) do
    %{
      owner: %{id: owner.id, kind: owner.kind},
      credential: %{id: credential.id, secret_hash: credential.verifier}
    }
  end

  defp complete_domain_result(owner, credential, vault_id) do
    %{
      account_id: owner.account_id,
      credential_id: credential.id,
      credential_hash: credential.verifier,
      principal_id: owner.id,
      vault_id: vault_id
    }
  end

  defp insert_capabilities(repo, principal_id, vault_id, names) do
    now = DateTime.utc_now()

    rows =
      Enum.map(names, fn name ->
        %{id: Ecto.UUID.generate(), name: name, inserted_at: now}
      end)

    repo.insert_all(Capability, rows,
      on_conflict: :nothing,
      conflict_target: [:name]
    )

    capabilities =
      repo.all(
        from capability in Capability,
          where: capability.name in ^names
      )

    Enum.reduce_while(capabilities, {:ok, []}, fn capability, {:ok, assignments} ->
      changeset =
        PrincipalCapability.create_changeset(%PrincipalCapability{}, %{
          principal_id: principal_id,
          vault_id: vault_id,
          capability_id: capability.id
        })

      case repo.insert(changeset) do
        {:ok, assignment} -> {:cont, {:ok, [assignment | assignments]}}
        {:error, changeset} -> {:halt, {:error, changeset_error(changeset)}}
      end
    end)
  end

  defp validate_complete_command(command) do
    with true <- command.person.id == command.account.person_id,
         true <- command.account.id == command.credential.account_id,
         true <- command.account.id == command.principal.account_id,
         true <- command.principal.id == command.membership.principal_id,
         true <- command.vault.id == command.membership.vault_id,
         true <- command.vault.id == command.key_domain.vault_id,
         true <- command.vault.id == command.vault_key_version.vault_id,
         true <- command.vault.id == command.vault_key_wrapper.vault_id,
         true <- command.vault.id == command.domain_key_version.vault_id,
         true <- command.vault.id == command.domain_dedup_key_wrapper.vault_id,
         true <-
           command.vault_key_version.id ==
             command.vault_key_wrapper.vault_key_version_id,
         true <-
           command.vault_key_version.id ==
             command.domain_key_version.vault_key_version_id,
         true <- command.key_domain.id == command.domain_key_version.key_domain_id,
         true <-
           command.key_domain.id ==
             command.domain_dedup_key_wrapper.key_domain_id,
         true <-
           command.domain_key_version.id ==
             command.domain_dedup_key_wrapper.domain_key_version_id,
         true <- valid_capabilities?(command.capabilities) do
      :ok
    else
      false -> {:error, Error.new(:invalid)}
    end
  end

  defp valid_capabilities?(capabilities) when is_list(capabilities) do
    capabilities != [] and
      Enum.all?(capabilities, fn name ->
        is_binary(name) and name == String.trim(name) and byte_size(name) > 0
      end) and Enum.uniq(capabilities) == capabilities
  end

  defp valid_capabilities?(_capabilities), do: false

  defp load_live_session_row([
         session_id,
         account_id,
         session_expires_at,
         session_revoked_at,
         credential_id,
         credential_revision,
         principal_id,
         principal_kind,
         principal_authorization_epoch,
         principal_revoked_at,
         vault_id,
         vault_authorization_epoch,
         vault_locked,
         membership_revoked_at,
         clearance,
         capabilities
       ]) do
    with {:ok, session_id} <- Ecto.UUID.load(session_id),
         {:ok, account_id} <- Ecto.UUID.load(account_id),
         {:ok, credential_id} <- Ecto.UUID.load(credential_id),
         {:ok, principal_id} <- Ecto.UUID.load(principal_id),
         {:ok, vault_id} <- Ecto.UUID.load(vault_id),
         {:ok, principal_kind} <- principal_kind(principal_kind),
         {:ok, clearance} <- clearance(clearance),
         true <- is_struct(session_expires_at, DateTime),
         true <- is_struct(credential_revision, DateTime),
         true <-
           valid_optional_live_times?([
             session_revoked_at,
             principal_revoked_at,
             membership_revoked_at
           ]),
         true <-
           valid_live_state?(
             principal_authorization_epoch,
             vault_authorization_epoch,
             vault_locked,
             capabilities
           ) do
      {:ok,
       %{
         session_id: session_id,
         account_id: account_id,
         session_expires_at: session_expires_at,
         session_revoked_at: session_revoked_at,
         credential_id: credential_id,
         credential_revision: credential_revision,
         principal_id: principal_id,
         principal_kind: principal_kind,
         principal_authorization_epoch: principal_authorization_epoch,
         principal_revoked_at: principal_revoked_at,
         vault_id: vault_id,
         vault_authorization_epoch: vault_authorization_epoch,
         vault_locked: vault_locked,
         membership_revoked_at: membership_revoked_at,
         clearance: clearance,
         capabilities: capabilities
       }}
    else
      _invalid -> invalid_snapshot()
    end
  end

  defp load_live_session_row(_row), do: invalid_snapshot()

  defp load_live_principal_row([
         principal_id,
         principal_kind,
         principal_authorization_epoch,
         principal_revoked_at,
         vault_id,
         vault_authorization_epoch,
         vault_locked,
         membership_revoked_at,
         clearance,
         capabilities
       ]) do
    with {:ok, principal_id} <- Ecto.UUID.load(principal_id),
         {:ok, vault_id} <- Ecto.UUID.load(vault_id),
         {:ok, principal_kind} <- principal_kind(principal_kind),
         {:ok, clearance} <- clearance(clearance),
         true <-
           valid_optional_live_times?([
             principal_revoked_at,
             membership_revoked_at
           ]),
         true <-
           valid_live_state?(
             principal_authorization_epoch,
             vault_authorization_epoch,
             vault_locked,
             capabilities
           ) do
      {:ok,
       %{
         principal_id: principal_id,
         principal_kind: principal_kind,
         principal_authorization_epoch: principal_authorization_epoch,
         principal_revoked_at: principal_revoked_at,
         vault_id: vault_id,
         vault_authorization_epoch: vault_authorization_epoch,
         vault_locked: vault_locked,
         membership_revoked_at: membership_revoked_at,
         clearance: clearance,
         capabilities: capabilities
       }}
    else
      _invalid -> invalid_snapshot()
    end
  end

  defp load_live_principal_row(_row), do: invalid_snapshot()

  defp principal_kind("owner"), do: {:ok, :owner}
  defp principal_kind("system"), do: {:ok, :system}
  defp principal_kind(_kind), do: :error

  defp clearance("private"), do: {:ok, :private}
  defp clearance("sensitive"), do: {:ok, :sensitive}
  defp clearance("restricted"), do: {:ok, :restricted}
  defp clearance(_clearance), do: :error

  defp valid_optional_live_times?(times),
    do: Enum.all?(times, &(is_nil(&1) or is_struct(&1, DateTime)))

  defp valid_live_state?(
         principal_authorization_epoch,
         vault_authorization_epoch,
         vault_locked,
         capabilities
       ) do
    is_integer(principal_authorization_epoch) and
      principal_authorization_epoch >= 0 and
      is_integer(vault_authorization_epoch) and
      vault_authorization_epoch >= 0 and
      is_boolean(vault_locked) and
      is_list(capabilities) and Enum.all?(capabilities, &is_binary/1)
  end

  defp load_active_vault_wrapper(repo, %{account_id: account_id, vault_id: vault_id}) do
    repo.all(
      from wrapper in VaultKeyWrapper,
        join: version in VaultKeyVersion,
        on:
          version.id == wrapper.vault_key_version_id and
            version.vault_id == wrapper.vault_id,
        where: wrapper.account_id == ^account_id,
        where: wrapper.vault_id == ^vault_id,
        where: version.state == :active,
        order_by: [asc: wrapper.id],
        limit: 2,
        select: %{
          id: wrapper.id,
          vault_key_version_id: wrapper.vault_key_version_id,
          generation: version.generation,
          kdf_version: wrapper.kdf_version,
          kdf_salt: wrapper.kdf_salt,
          kdf_parameters: wrapper.kdf_parameters,
          wrapper_algorithm: wrapper.wrapper_algorithm,
          wrapped_key: wrapper.wrapped_key
        }
    )
    |> one_runtime_material()
  end

  defp load_active_domain_key_version(repo, vault_id, vault_key_version_id) do
    repo.all(
      from version in DomainKeyVersion,
        join: domain in KeyDomain,
        on:
          domain.id == version.key_domain_id and
            domain.vault_id == version.vault_id,
        where: version.vault_id == ^vault_id,
        where: version.vault_key_version_id == ^vault_key_version_id,
        where: version.state == :active,
        where: domain.state == :active,
        where: domain.kind == "content",
        order_by: [asc: domain.id],
        limit: 2,
        select: %{
          id: version.id,
          key_domain_id: version.key_domain_id,
          generation: version.generation,
          algorithm: version.algorithm,
          wrapped_key: version.wrapped_key
        }
    )
    |> one_runtime_material()
  end

  defp one_runtime_material([]), do: {:error, Error.new(:not_found)}
  defp one_runtime_material([material]), do: {:ok, material}
  defp one_runtime_material([_first, _second]), do: {:error, Error.new(:conflict)}

  defp ensure_scoped_identity(repo, principal_id, vault_id, error_code) do
    case load_live_principal(repo, principal_id, vault_id) do
      {:ok, %{principal_id: ^principal_id, vault_id: ^vault_id}} ->
        :ok

      {:ok, _missing_or_mismatched} ->
        {:error, Error.new(error_code)}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp load_scoped_live_session(
         repo,
         %{
           session_id: session_id,
           principal_id: principal_id,
           vault_id: vault_id
         }
       ) do
    with {:ok, live} when not is_nil(live) <-
           load_live_session(repo, session_id),
         true <- live.principal_id == principal_id,
         true <- live.vault_id == vault_id do
      {:ok, live}
    else
      {:ok, nil} -> {:error, Error.new(:not_found)}
      false -> {:error, Error.new(:not_found)}
      {:error, %Error{}} = error -> error
      _invalid -> invalid_snapshot()
    end
  end

  defp load_scoped_credential(repo, command) do
    with {:ok,
          %{
            credential_id: credential_id,
            credential_revision: credential_revision
          }}
         when not is_nil(credential_id) <-
           load_scoped_live_session(repo, command) do
      {:ok, %{id: credential_id, revision: credential_revision}}
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid_snapshot()
    end
  end

  defp ensure_live_session_binding(
         repo,
         %{session_id: session_id, principal_id: principal_id, vault_id: vault_id}
       ) do
    if repo.exists?(
         from session in Session,
           where: session.id == ^session_id,
           where: session.principal_id == ^principal_id,
           where: session.vault_id == ^vault_id,
           where: is_nil(session.revoked_at),
           where: session.expires_at > fragment("CURRENT_TIMESTAMP")
       ),
       do: :ok,
       else: {:error, Error.new(:conflict)}
  end

  defp ensure_lock_session_binding(
         repo,
         %{reason: :idle_timeout} = command
       ),
       do: ensure_session_binding(repo, command)

  defp ensure_lock_session_binding(repo, command),
    do: ensure_live_session_binding(repo, command)

  defp ensure_session_binding(
         repo,
         %{session_id: session_id, principal_id: principal_id, vault_id: vault_id}
       ) do
    if repo.exists?(
         from session in Session,
           where: session.id == ^session_id,
           where: session.principal_id == ^principal_id,
           where: session.vault_id == ^vault_id
       ),
       do: :ok,
       else: {:error, Error.new(:conflict)}
  end

  defp ensure_active_unlock_versions(
         repo,
         %{
           vault_id: vault_id,
           vault_key_version_id: vault_key_version_id,
           domain_key_version_id: domain_key_version_id
         }
       ) do
    if repo.exists?(
         from vault_version in VaultKeyVersion,
           join: domain_version in DomainKeyVersion,
           on:
             domain_version.vault_id == vault_version.vault_id and
               domain_version.vault_key_version_id == vault_version.id,
           where: vault_version.id == ^vault_key_version_id,
           where: vault_version.vault_id == ^vault_id,
           where: vault_version.state == :active,
           where: domain_version.id == ^domain_key_version_id,
           where: domain_version.state == :active
       ),
       do: :ok,
       else: {:error, Error.new(:conflict)}
  end

  defp set_vault_lock(repo, vault_id, locked?) do
    case repo.update_all(
           from(vault in Vault, where: vault.id == ^vault_id),
           set: [locked: locked?, updated_at: DateTime.utc_now()]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, Error.new(:conflict)}
    end
  end

  defp revoke_live_session(
         repo,
         %{session_id: session_id, principal_id: principal_id, vault_id: vault_id}
       ) do
    case repo.update_all(
           from(
             session in Session,
             where: session.id == ^session_id,
             where: session.principal_id == ^principal_id,
             where: session.vault_id == ^vault_id,
             where: is_nil(session.revoked_at),
             where: session.expires_at > fragment("CURRENT_TIMESTAMP")
           ),
           set: [revoked_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, Error.new(:conflict)}
    end
  end

  defp update_credential_revision(
         repo,
         session_id,
         credential_id,
         credential_revision,
         new_verifier
       ) do
    case update_credential_verifier(
           repo,
           session_id,
           credential_id,
           credential_revision,
           new_verifier
         ) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, Error.new(:conflict)}
      {:error, %Error{}} = error -> error
    end
  end

  defp update_vault_wrapper(
         repo,
         %{
           vault_id: vault_id,
           wrapper_id: wrapper_id,
           vault_key_version_id: vault_key_version_id,
           expected_wrapped_key: expected_wrapped_key,
           new_kdf_version: new_kdf_version,
           new_kdf_salt: new_kdf_salt,
           new_kdf_parameters: new_kdf_parameters,
           new_wrapper_algorithm: new_wrapper_algorithm,
           new_wrapped_key: new_wrapped_key
         }
       ) do
    query =
      from wrapper in VaultKeyWrapper,
        join: version in VaultKeyVersion,
        on:
          version.id == wrapper.vault_key_version_id and
            version.vault_id == wrapper.vault_id,
        where: wrapper.id == ^wrapper_id,
        where: wrapper.vault_id == ^vault_id,
        where: wrapper.vault_key_version_id == ^vault_key_version_id,
        where: wrapper.wrapped_key == ^expected_wrapped_key,
        where: version.state == :active

    case repo.update_all(query,
           set: [
             kdf_version: new_kdf_version,
             kdf_salt: new_kdf_salt,
             kdf_parameters: new_kdf_parameters,
             wrapper_algorithm: new_wrapper_algorithm,
             wrapped_key: new_wrapped_key
           ]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, Error.new(:conflict)}
    end
  end

  defp validate_password_replacement(
         new_verifier,
         expected_wrapped_key,
         new_kdf_version,
         new_kdf_salt,
         new_kdf_parameters,
         new_wrapper_algorithm,
         new_wrapped_key
       ) do
    if byte_size(String.trim(new_verifier)) > 0 and
         byte_size(expected_wrapped_key) > 0 and new_kdf_version > 0 and
         byte_size(new_kdf_salt) >= 8 and json_value?(new_kdf_parameters) and
         new_wrapper_algorithm == String.trim(new_wrapper_algorithm) and
         new_wrapper_algorithm not in ["", "unknown"] and
         byte_size(new_wrapped_key) > 0,
       do: :ok,
       else: {:error, Error.new(:invalid)}
  end

  defp json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and json_value?(nested)
    end)
  end

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  defp json_value?(value) when is_binary(value) or is_number(value), do: true
  defp json_value?(value) when is_boolean(value) or is_nil(value), do: true
  defp json_value?(_value), do: false

  defp append_runtime_audit(
         repo,
         %{
           session_id: session_id,
           principal_id: principal_id,
           vault_id: vault_id,
           correlation_id: correlation_id
         },
         operation,
         result
       ) do
    %Event{}
    |> Event.append_changeset(%{
      id: Ecto.UUID.generate(),
      vault_id: vault_id,
      actor_kind: :principal,
      principal_id: principal_id,
      operation: operation,
      result: result,
      classification: :private,
      correlation_id: correlation_id,
      target_type: "session",
      target_id: session_id,
      metadata: %{},
      occurred_at: DateTime.utc_now()
    })
    |> repo.insert()
    |> case do
      {:ok, _event} -> :ok
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_error(changeset)}
    end
  end

  defp runtime_operation(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _error in [ArgumentError, Ecto.Query.CastError] ->
      {:error, Error.new(:invalid)}

    error in [Ecto.ConstraintError, Postgrex.Error] ->
      {:error, database_error(error)}
  end

  defp invalid_snapshot, do: {:error, Error.new(:storage_unavailable)}

  defp storage_unavailable,
    do: {:error, Error.new(:storage_unavailable, retryable?: true)}

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
