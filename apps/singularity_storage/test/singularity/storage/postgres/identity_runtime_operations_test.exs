defmodule Singularity.Storage.Postgres.IdentityRuntimeOperationsTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Core.Error
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.ScopedRepo

  setup do
    %{one: one, two: two} = Fixtures.two_vaults!()

    {:ok,
     one: Map.put(one, :key_material, insert_key_material!(one, 0x11)),
     two: Map.put(two, :key_material, insert_key_material!(two, 0x22))}
  end

  test "loads only the scoped active vault and password material", %{one: one, two: two} do
    resolved_identity = %{identity(one) | account_id: nil}

    assert {:ok, unlock_material} =
             scoped(
               one,
               &IdentityRepository.load_unlock_material(&1, resolved_identity)
             )

    assert %{
             vault_wrapper: %{
               id: wrapper_id,
               vault_key_version_id: vault_key_version_id,
               generation: 3,
               kdf_version: 1,
               kdf_salt: kdf_salt,
               kdf_parameters: %{
                 "m_cost" => 16,
                 "parallelism" => 1,
                 "t_cost" => 3,
                 "version" => 1
               },
               wrapper_algorithm: "aes_256_gcm",
               wrapped_key: wrapped_vault_key
             },
             domain_key_version: %{
               id: domain_key_version_id,
               key_domain_id: key_domain_id,
               classification: :private,
               generation: 5,
               algorithm: "aes_256_gcm",
               wrapped_key: wrapped_domain_key
             },
             domain_dedup_key_wrapper: %{
               id: dedup_wrapper_id,
               key_domain_id: key_domain_id,
               domain_key_version_id: domain_key_version_id,
               algorithm: "aes_256_gcm",
               wrapped_key: wrapped_dedup_key
             }
           } = unlock_material

    assert wrapper_id == canonical(one.key_material.wrapper_id)
    assert vault_key_version_id == canonical(one.key_material.vault_key_version_id)
    assert domain_key_version_id == canonical(one.key_material.domain_key_version_id)
    assert dedup_wrapper_id == canonical(one.key_material.dedup_wrapper_id)
    assert key_domain_id == canonical(one.key_material.key_domain_id)
    assert kdf_salt == :binary.copy(<<0x11>>, 16)
    assert wrapped_vault_key == :binary.copy(<<0x31>>, 48)
    assert wrapped_domain_key == :binary.copy(<<0x41>>, 48)
    assert wrapped_dedup_key == :binary.copy(<<0x51>>, 48)

    assert {:ok, password_material} =
             scoped(
               one,
               &IdentityRepository.load_password_material(&1, resolved_identity)
             )

    assert password_material.vault_wrapper == unlock_material.vault_wrapper
    assert password_material.credential_id == canonical(one.credential_id)
    assert %DateTime{} = password_material.credential_revision

    forged_account = %{identity(one) | account_id: canonical(two.account_id)}

    assert {:ok, ^unlock_material} =
             scoped(
               one,
               &IdentityRepository.load_unlock_material(&1, forged_account)
             )

    assert {:error, %Error{code: :not_found}} =
             scoped(two, &IdentityRepository.load_unlock_material(&1, identity(one)))

    assert {:error, %Error{code: :not_found}} =
             scoped(two, &IdentityRepository.load_password_material(&1, identity(one)))

    forged_principal = %{identity(one) | principal_id: canonical(two.principal_id)}

    assert {:error, %Error{code: :not_found}} =
             scoped(
               one,
               &IdentityRepository.load_unlock_material(&1, forged_principal)
             )
  end

  test "unlock and lock state plus audit participate in the caller transaction", %{one: one} do
    unlock = unlock_command(one)

    assert {:error, :injected_rollback} =
             scoped(one, fn repo ->
               assert :ok = IdentityRepository.unlock_and_audit(repo, unlock)
               repo.rollback(:injected_rollback)
             end)

    assert vault_locked?(one)
    assert audit_operations(one) == []

    assert :ok = scoped(one, &IdentityRepository.unlock_and_audit(&1, unlock))
    refute vault_locked?(one)
    assert audit_operations(one) == ["vault.unlock"]

    lock = mutation_command(one)
    assert :ok = scoped(one, &IdentityRepository.lock_and_audit(&1, lock))
    assert vault_locked?(one)
    assert audit_operations(one) == ["vault.unlock", "vault.lock"]
    assert audit_results(one) == ["allowed", "completed"]

    stale_unlock = %{unlock | domain_key_version_id: Ecto.UUID.generate()}

    assert {:error, %Error{code: :conflict}} =
             scoped(one, &IdentityRepository.unlock_and_audit(&1, stale_unlock))

    assert vault_locked?(one)
    assert audit_operations(one) == ["vault.unlock", "vault.lock"]
  end

  test "logout revocation and audit are atomic and exactly session bound", %{one: one} do
    command = mutation_command(one)
    set_vault_locked!(one, false)

    assert {:error, :injected_rollback} =
             scoped(one, fn repo ->
               assert :ok = IdentityRepository.revoke_session_and_audit(repo, command)
               repo.rollback(:injected_rollback)
             end)

    refute session_revoked?(one)
    refute vault_locked?(one)
    assert audit_operations(one) == []

    assert :ok = scoped(one, &IdentityRepository.revoke_session_and_audit(&1, command))
    assert session_revoked?(one)
    assert vault_locked?(one)
    assert audit_operations(one) == ["identity.logout"]
    assert audit_results(one) == ["completed"]

    assert {:error, %Error{code: :conflict}} =
             scoped(one, &IdentityRepository.revoke_session_and_audit(&1, command))

    assert audit_operations(one) == ["identity.logout"]
  end

  test "idle timeout locks and audits even when the bound session has just expired", %{
    one: one
  } do
    set_vault_locked!(one, false)
    set_session_expired!(one)

    command = Map.put(mutation_command(one), :reason, :idle_timeout)

    assert :ok = scoped(one, &IdentityRepository.lock_and_audit(&1, command))
    assert vault_locked?(one)
    assert audit_operations(one) == ["vault.lock"]
  end

  test "password and wrapper CAS either both commit with audit or both roll back", %{one: one} do
    assert {:ok, material} =
             scoped(one, &IdentityRepository.load_password_material(&1, identity(one)))

    set_vault_locked!(one, false)

    command = %{
      session_id: canonical(one.session_id),
      principal_id: canonical(one.principal_id),
      vault_id: canonical(one.vault_id),
      correlation_id: Ecto.UUID.generate(),
      credential_id: material.credential_id,
      credential_revision: material.credential_revision,
      new_verifier: "new-verifier",
      wrapper_id: material.vault_wrapper.id,
      vault_key_version_id: material.vault_wrapper.vault_key_version_id,
      expected_wrapper_generation: material.vault_wrapper.generation,
      new_wrapper_generation: material.vault_wrapper.generation + 1,
      expected_wrapped_key: material.vault_wrapper.wrapped_key,
      new_kdf_version: 2,
      new_kdf_salt: :binary.copy(<<0x52>>, 16),
      new_kdf_parameters: %{
        "version" => 2,
        "t_cost" => 4,
        "m_cost" => 32,
        "parallelism" => 1
      },
      new_wrapper_algorithm: "aes_256_gcm",
      new_wrapped_key: :binary.copy(<<0x62>>, 48)
    }

    unknown_algorithm = %{command | new_wrapper_algorithm: "unknown"}

    assert {:error, %Error{code: :invalid}} =
             scoped(
               one,
               &IdentityRepository.change_password_and_wrapper(&1, unknown_algorithm)
             )

    stale_wrapper = %{command | expected_wrapped_key: "stale-wrapper"}

    assert {:error, %Error{code: :conflict}} =
             scoped(
               one,
               &IdentityRepository.change_password_and_wrapper(&1, stale_wrapper)
             )

    stale_generation = %{
      command
      | expected_wrapper_generation: command.expected_wrapper_generation + 1,
        new_wrapper_generation: command.new_wrapper_generation + 1
    }

    assert {:error, %Error{code: :conflict}} =
             scoped(
               one,
               &IdentityRepository.change_password_and_wrapper(&1, stale_generation)
             )

    assert credential_and_wrapper(one) == %{
             verifier: one.verifier,
             generation: 3,
             kdf_version: 1,
             kdf_salt: :binary.copy(<<0x11>>, 16),
             kdf_parameters: %{
               "version" => 1,
               "t_cost" => 3,
               "m_cost" => 16,
               "parallelism" => 1
             },
             wrapper_algorithm: "aes_256_gcm",
             wrapped_key: :binary.copy(<<0x31>>, 48)
           }

    refute vault_locked?(one)
    assert audit_operations(one) == []

    assert :ok =
             scoped(one, &IdentityRepository.change_password_and_wrapper(&1, command))

    assert credential_and_wrapper(one) == %{
             verifier: "new-verifier",
             generation: 4,
             kdf_version: 2,
             kdf_salt: :binary.copy(<<0x52>>, 16),
             kdf_parameters: %{
               "version" => 2,
               "t_cost" => 4,
               "m_cost" => 32,
               "parallelism" => 1
             },
             wrapper_algorithm: "aes_256_gcm",
             wrapped_key: :binary.copy(<<0x62>>, 48)
           }

    assert vault_locked?(one)
    assert audit_operations(one) == ["identity.password_change"]
    assert audit_results(one) == ["completed"]

    assert {:error, %Error{code: :conflict}} =
             scoped(one, &IdentityRepository.change_password_and_wrapper(&1, command))

    assert {:error, %Error{code: :conflict}} =
             scoped(one, &IdentityRepository.unlock_and_audit(&1, unlock_command(one)))

    assert audit_operations(one) == ["identity.password_change"]
  end

  defp insert_key_material!(fixture, marker) do
    Fixtures.with_owner(fn ->
      key_domain_id = uuid()
      vault_key_version_id = uuid()
      wrapper_id = uuid()
      domain_key_version_id = uuid()
      dedup_wrapper_id = uuid()

      query!(
        MigrationRepo,
        """
        INSERT INTO core.key_domains (
          id, vault_id, classification, kind, state
        ) VALUES ($1, $2, 'private', 'content', 'active')
        """,
        [key_domain_id, fixture.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 3, 'active', 'aes-256-gcm', CURRENT_TIMESTAMP)
        """,
        [vault_key_version_id, fixture.vault_id]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_wrappers (
          id,
          vault_id,
          vault_key_version_id,
          account_id,
          generation,
          kdf_version,
          kdf_salt,
          kdf_parameters,
          wrapper_algorithm,
          wrapped_key
        ) VALUES ($1, $2, $3, $4, 3, 1, $5, $6::text::jsonb, 'aes_256_gcm', $7)
        """,
        [
          wrapper_id,
          fixture.vault_id,
          vault_key_version_id,
          fixture.account_id,
          :binary.copy(<<marker>>, 16),
          JSON.encode!(%{
            "version" => 1,
            "t_cost" => 3,
            "m_cost" => 16,
            "parallelism" => 1
          }),
          :binary.copy(<<marker + 0x20>>, 48)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.domain_key_versions (
          id,
          vault_id,
          key_domain_id,
          vault_key_version_id,
          generation,
          state,
          algorithm,
          wrapped_key
        ) VALUES ($1, $2, $3, $4, 5, 'active', 'aes_256_gcm', $5)
        """,
        [
          domain_key_version_id,
          fixture.vault_id,
          key_domain_id,
          vault_key_version_id,
          :binary.copy(<<marker + 0x30>>, 48)
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO core.domain_dedup_key_wrappers (
          id,
          vault_id,
          key_domain_id,
          domain_key_version_id,
          algorithm,
          wrapped_key
        ) VALUES ($1, $2, $3, $4, 'aes_256_gcm', $5)
        """,
        [
          dedup_wrapper_id,
          fixture.vault_id,
          key_domain_id,
          domain_key_version_id,
          :binary.copy(<<marker + 0x40>>, 48)
        ]
      )

      %{
        key_domain_id: key_domain_id,
        vault_key_version_id: vault_key_version_id,
        wrapper_id: wrapper_id,
        domain_key_version_id: domain_key_version_id,
        dedup_wrapper_id: dedup_wrapper_id
      }
    end)
  end

  defp identity(fixture) do
    %{
      session_id: canonical(fixture.session_id),
      account_id: canonical(fixture.account_id),
      principal_id: canonical(fixture.principal_id),
      vault_id: canonical(fixture.vault_id)
    }
  end

  defp unlock_command(fixture) do
    fixture
    |> mutation_command()
    |> Map.merge(%{
      wrapper_id: canonical(fixture.key_material.wrapper_id),
      wrapper_generation: 3,
      vault_key_version_id: canonical(fixture.key_material.vault_key_version_id),
      domain_key_version_id: canonical(fixture.key_material.domain_key_version_id)
    })
  end

  defp mutation_command(fixture) do
    %{
      session_id: canonical(fixture.session_id),
      principal_id: canonical(fixture.principal_id),
      vault_id: canonical(fixture.vault_id),
      correlation_id: Ecto.UUID.generate()
    }
  end

  defp scoped(fixture, fun) do
    RequestRepo.checkout(fn ->
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
        fun
      )
    end)
  end

  defp vault_locked?(fixture) do
    owner_value(
      "SELECT locked FROM core.vaults WHERE id = $1",
      [fixture.vault_id]
    )
  end

  defp session_revoked?(fixture) do
    owner_value(
      "SELECT revoked_at IS NOT NULL FROM identity.sessions WHERE id = $1",
      [fixture.session_id]
    )
  end

  defp set_vault_locked!(fixture, locked?) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "UPDATE core.vaults SET locked = $1 WHERE id = $2",
        [locked?, fixture.vault_id]
      )

      :ok
    end)
  end

  defp set_session_expired!(fixture) do
    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        UPDATE identity.sessions
        SET expires_at = CURRENT_TIMESTAMP - INTERVAL '1 second'
        WHERE id = $1
        """,
        [fixture.session_id]
      )

      :ok
    end)
  end

  defp audit_operations(fixture) do
    Fixtures.with_owner(fn ->
      %{rows: rows} =
        query!(
          MigrationRepo,
          """
          SELECT operation
          FROM audit.events
          WHERE vault_id = $1
          ORDER BY inserted_at, id
          """,
          [fixture.vault_id]
        )

      Enum.map(rows, fn [operation] -> operation end)
    end)
  end

  defp audit_results(fixture) do
    Fixtures.with_owner(fn ->
      %{rows: rows} =
        query!(
          MigrationRepo,
          """
          SELECT result
          FROM audit.events
          WHERE vault_id = $1
          ORDER BY inserted_at, id
          """,
          [fixture.vault_id]
        )

      Enum.map(rows, fn [result] -> result end)
    end)
  end

  defp credential_and_wrapper(fixture) do
    Fixtures.with_owner(fn ->
      %{
        rows: [
          [verifier, generation, kdf_version, kdf_salt, kdf_parameters, algorithm, wrapped_key]
        ]
      } =
        query!(
          MigrationRepo,
          """
          SELECT
            credential.verifier,
            wrapper.generation,
            wrapper.kdf_version,
            wrapper.kdf_salt,
            wrapper.kdf_parameters,
            wrapper.wrapper_algorithm,
            wrapper.wrapped_key
          FROM identity.credentials AS credential
          JOIN core.vault_key_wrappers AS wrapper
            ON wrapper.account_id = credential.account_id
          WHERE credential.id = $1 AND wrapper.id = $2
          """,
          [fixture.credential_id, fixture.key_material.wrapper_id]
        )

      %{
        verifier: verifier,
        generation: generation,
        kdf_version: kdf_version,
        kdf_salt: kdf_salt,
        kdf_parameters: kdf_parameters,
        wrapper_algorithm: algorithm,
        wrapped_key: wrapped_key
      }
    end)
  end

  defp owner_value(statement, parameters) do
    Fixtures.with_owner(fn ->
      %{rows: [[value]]} = query!(MigrationRepo, statement, parameters)
      value
    end)
  end

  defp canonical(value), do: Ecto.UUID.load!(value)

  defp uuid do
    Ecto.UUID.generate()
    |> Ecto.UUID.dump!()
  end
end
