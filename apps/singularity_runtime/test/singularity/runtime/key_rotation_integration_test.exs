defmodule Singularity.Runtime.KeyRotationIntegrationTest do
  use Singularity.Storage.DataCase, async: false

  @moduletag :integration

  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.Authorize
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.KeyLeaseSupervisor
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.RotateDomainKey
  alias Singularity.Runtime.RotateVaultKey
  alias Singularity.Runtime.SessionContext
  alias Singularity.Runtime.UnlockVault
  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.Crypto.Argon2KeyDeriver
  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.Fixtures
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.Postgres.KeyRotationRepository
  alias Singularity.Storage.RequestRepo
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.VaultLock

  @password "rotation integration password"
  @kdf_parameters %{version: 1, t_cost: 1, m_cost: 8, parallelism: 1}
  @vault_key :binary.copy(<<0xA1>>, 32)
  @primary_domain_key :binary.copy(<<0xB2>>, 32)
  @secondary_domain_key :binary.copy(<<0xB3>>, 32)
  @dedup_key :binary.copy(<<0xC4>>, 32)
  @object_dek :binary.copy(<<0xD5>>, 32)

  setup do
    %{one: raw_one} = Fixtures.two_vaults!()
    one = load_ids(raw_one)
    key_material = insert_key_material!(one)
    grant_rotation_access!(one)

    live = load_live_session!(one)
    session = session_context(live, true)
    custodian = start_custodian!()

    assert :ok =
             activate_custody!(custodian, session, key_material)

    authorization =
      AuthorizationDependencies.new(%{
        store: IdentityRepository,
        custodian: {KeyCustodian, custodian}
      })
      |> then(fn {:ok, dependencies} -> dependencies end)

    operation_runtime = %{
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      authorizer: Authorize,
      request_repo: RequestRepo,
      scoped_repo: ScopedRepo,
      vault_lock: VaultLock
    }

    rotation_runtime =
      Map.merge(operation_runtime, %{
        custodian: {KeyCustodian, custodian},
        id_generator: &Ecto.UUID.generate/0,
        key_deriver: Argon2KeyDeriver,
        operation_scope: OperationScope,
        repository: KeyRotationRepository,
        utc_now: fn -> DateTime.utc_now(:microsecond) end
      })

    unlock_runtime =
      Map.merge(operation_runtime, %{
        custodian: {KeyCustodian, custodian},
        key_deriver: Argon2KeyDeriver,
        key_wrapper: KeyWrapper,
        operation_scope: OperationScope,
        vaults: IdentityRepository
      })

    {:ok,
     custodian: custodian,
     fixture: one,
     key_material: key_material,
     rotation_runtime: rotation_runtime,
     session: session,
     unlock_runtime: unlock_runtime}
  end

  test "real vault and domain rotations revoke custody, lock the vault, and preserve raw data keys",
       context do
    %{
      custodian: custodian,
      fixture: fixture,
      key_material: key_material,
      rotation_runtime: rotation_runtime,
      session: session,
      unlock_runtime: unlock_runtime
    } = context

    object_before = object_snapshot(fixture, key_material.object_id)
    vault_correlation_id = Ecto.UUID.generate()

    assert {:ok, %SessionContext{unlocked?: false} = locked_after_vault} =
             RotateVaultKey.run(
               rotation_runtime,
               session,
               @password,
               vault_correlation_id
             )

    refute KeyCustodian.unlocked?(custodian, session.session_id)
    assert vault_locked?(fixture)

    assert %{
             version_id: vault_version_id,
             version_generation: 4,
             wrapper_generation: 10,
             wrapped_key: wrapped_vault_key
           } = active_vault_material(fixture)

    vault_kek = derive_vault_kek!()

    assert {:ok, rotated_vault_key} =
             KeyWrapper.unwrap(vault_kek, wrapped_vault_key, %{
               purpose: :vault_key,
               generation: 10,
               aad: fixture.vault_id
             })

    assert byte_size(rotated_vault_key) == 32
    refute rotated_vault_key == @vault_key

    active_domains = active_domains(fixture)
    assert length(active_domains) == 2

    assert %{
             key_domain_id: primary_domain_id,
             vault_key_version_id: ^vault_version_id,
             generation: 5,
             wrapped_key: wrapped_primary_domain
           } =
             Enum.find(
               active_domains,
               &(&1.key_domain_id == key_material.primary_domain_id)
             )

    assert %{
             key_domain_id: secondary_domain_id,
             vault_key_version_id: ^vault_version_id,
             generation: 7,
             wrapped_key: wrapped_secondary_domain
           } =
             Enum.find(
               active_domains,
               &(&1.key_domain_id == key_material.secondary_domain_id)
             )

    assert primary_domain_id == key_material.primary_domain_id
    assert secondary_domain_id == key_material.secondary_domain_id

    assert {:ok, @primary_domain_key} =
             unwrap_domain(
               rotated_vault_key,
               wrapped_primary_domain,
               fixture.vault_id,
               primary_domain_id,
               5
             )

    assert {:ok, @secondary_domain_key} =
             unwrap_domain(
               rotated_vault_key,
               wrapped_secondary_domain,
               fixture.vault_id,
               secondary_domain_id,
               7
             )

    vault_audit =
      scoped(fixture, fn repo ->
        assert_persisted_audit!(
          repo,
          "vault.key_rotated",
          [correlation_id: vault_correlation_id],
          actor_kind: "principal",
          result: "completed",
          target_type: "vault",
          target_id: fixture.vault_id
        )
      end)

    refute_secrets(
      [locked_after_vault, vault_audit],
      [
        vault_kek,
        @vault_key,
        rotated_vault_key,
        @primary_domain_key,
        @secondary_domain_key,
        @dedup_key,
        @object_dek
      ]
    )

    assert {:ok, %SessionContext{unlocked?: true} = unlocked} =
             UnlockVault.run(
               unlock_runtime,
               locked_after_vault,
               @password,
               Ecto.UUID.generate()
             )

    assert KeyCustodian.unlocked?(custodian, session.session_id)
    refute vault_locked?(fixture)

    domain_correlation_id = Ecto.UUID.generate()

    assert {:ok, %SessionContext{unlocked?: false} = locked_after_domain} =
             RotateDomainKey.run(
               rotation_runtime,
               unlocked,
               key_material.primary_domain_id,
               domain_correlation_id
             )

    refute KeyCustodian.unlocked?(custodian, session.session_id)
    assert vault_locked?(fixture)

    assert %{
             id: active_domain_version_id,
             generation: 6,
             vault_key_version_id: ^vault_version_id,
             wrapped_key: wrapped_rotated_domain,
             wrapped_dedup_key: wrapped_dedup_key,
             envelopes: [
               %{
                 asset_object_id: object_id,
                 domain_key_version_id: active_domain_version_id,
                 key_generation: 6,
                 wrapped_dek: wrapped_dek
               }
             ]
           } = active_domain_material(fixture, key_material.primary_domain_id)

    assert object_id == key_material.object_id

    assert {:ok, rotated_domain_key} =
             unwrap_domain(
               rotated_vault_key,
               wrapped_rotated_domain,
               fixture.vault_id,
               key_material.primary_domain_id,
               6
             )

    assert byte_size(rotated_domain_key) == 32
    refute rotated_domain_key == @primary_domain_key

    assert {:ok, @dedup_key} =
             KeyWrapper.unwrap(rotated_domain_key, wrapped_dedup_key, %{
               purpose: :domain_dedup_key,
               generation: 6,
               aad: key_material.primary_domain_id
             })

    assert {:ok, @object_dek} =
             KeyWrapper.unwrap(rotated_domain_key, wrapped_dek, %{
               purpose: :object_dek,
               generation: 6,
               aad: "object:" <> key_material.object_id
             })

    assert object_snapshot(fixture, key_material.object_id) == object_before

    domain_audit =
      scoped(fixture, fn repo ->
        assert_persisted_audit!(
          repo,
          "domain.key_rotated",
          [correlation_id: domain_correlation_id],
          actor_kind: "principal",
          result: "completed",
          target_type: "domain",
          target_id: key_material.primary_domain_id
        )
      end)

    refute_secrets(
      [locked_after_domain, domain_audit],
      [
        vault_kek,
        @vault_key,
        rotated_vault_key,
        @primary_domain_key,
        rotated_domain_key,
        @secondary_domain_key,
        @dedup_key,
        @object_dek
      ]
    )
  end

  defp insert_key_material!(fixture) do
    kdf_salt = :binary.copy(<<0x19>>, 16)

    assert {:ok, vault_kek} =
             Argon2KeyDeriver.derive(@password, kdf_salt, @kdf_parameters)

    vault_key_version_id = Ecto.UUID.generate()
    vault_key_wrapper_id = Ecto.UUID.generate()
    primary_domain_id = Ecto.UUID.generate()
    primary_domain_version_id = Ecto.UUID.generate()
    primary_dedup_wrapper_id = Ecto.UUID.generate()
    secondary_domain_id = Ecto.UUID.generate()
    secondary_domain_version_id = Ecto.UUID.generate()
    object_id = Ecto.UUID.generate()
    envelope_id = Ecto.UUID.generate()

    wrapped_vault_key =
      wrap!(vault_kek, @vault_key, :vault_key, 9, fixture.vault_id)

    wrapped_primary_domain =
      wrap!(
        @vault_key,
        @primary_domain_key,
        :domain_key,
        5,
        fixture.vault_id <> ":" <> primary_domain_id
      )

    wrapped_secondary_domain =
      wrap!(
        @vault_key,
        @secondary_domain_key,
        :domain_key,
        7,
        fixture.vault_id <> ":" <> secondary_domain_id
      )

    wrapped_dedup_key =
      wrap!(
        @primary_domain_key,
        @dedup_key,
        :domain_dedup_key,
        5,
        primary_domain_id
      )

    wrapped_dek =
      wrap!(
        @primary_domain_key,
        @object_dek,
        :object_dek,
        5,
        "object:" <> object_id
      )

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        ) VALUES ($1, $2, 3, 'active', 'aes-256-gcm', CURRENT_TIMESTAMP)
        """,
        [dump(vault_key_version_id), dump(fixture.vault_id)]
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
        ) VALUES (
          $1, $2, $3, $4, 9, 1, $5, $6::text::jsonb, 'aes_256_gcm', $7
        )
        """,
        [
          dump(vault_key_wrapper_id),
          dump(fixture.vault_id),
          dump(vault_key_version_id),
          dump(fixture.account_id),
          kdf_salt,
          JSON.encode!(string_keyed_kdf_parameters()),
          wrapped_vault_key
        ]
      )

      insert_domain!(
        fixture,
        primary_domain_id,
        primary_domain_version_id,
        vault_key_version_id,
        5,
        "content",
        wrapped_primary_domain
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
          dump(primary_dedup_wrapper_id),
          dump(fixture.vault_id),
          dump(primary_domain_id),
          dump(primary_domain_version_id),
          wrapped_dedup_key
        ]
      )

      insert_domain!(
        fixture,
        secondary_domain_id,
        secondary_domain_version_id,
        vault_key_version_id,
        7,
        "metadata",
        wrapped_secondary_domain
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_objects (
          id,
          vault_id,
          key_domain_id,
          classification,
          lookup_digest,
          ciphertext_hash,
          plaintext_byte_size,
          ciphertext_byte_size,
          storage_ref,
          format_version,
          lifecycle
        ) VALUES (
          $1, $2, $3, 'restricted', $4, $5, 37, 85, $6, 1, 'available'
        )
        """,
        [
          dump(object_id),
          dump(fixture.vault_id),
          dump(primary_domain_id),
          :crypto.hash(:sha256, "rotation-integration-lookup"),
          :crypto.hash(:sha256, "rotation-integration-ciphertext"),
          "rotation-integration/#{object_id}"
        ]
      )

      query!(
        MigrationRepo,
        """
        INSERT INTO content.asset_key_envelopes (
          id,
          vault_id,
          asset_object_id,
          domain_key_version_id,
          key_domain_id,
          classification,
          algorithm,
          key_generation,
          wrapped_dek
        ) VALUES (
          $1, $2, $3, $4, $5, 'restricted', 'aes_256_gcm', 5, $6
        )
        """,
        [
          dump(envelope_id),
          dump(fixture.vault_id),
          dump(object_id),
          dump(primary_domain_version_id),
          dump(primary_domain_id),
          wrapped_dek
        ]
      )
    end)

    %{
      kdf_salt: kdf_salt,
      object_id: object_id,
      primary_domain_id: primary_domain_id,
      primary_domain_version_id: primary_domain_version_id,
      secondary_domain_id: secondary_domain_id,
      vault_key_version_id: vault_key_version_id
    }
  end

  defp insert_domain!(
         fixture,
         key_domain_id,
         version_id,
         vault_key_version_id,
         generation,
         kind,
         wrapped_key
       ) do
    query!(
      MigrationRepo,
      """
      INSERT INTO core.key_domains (
        id, vault_id, classification, kind, state
      ) VALUES ($1, $2, 'restricted', $3, 'active')
      """,
      [dump(key_domain_id), dump(fixture.vault_id), kind]
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
      ) VALUES ($1, $2, $3, $4, $5, 'active', 'aes_256_gcm', $6)
      """,
      [
        dump(version_id),
        dump(fixture.vault_id),
        dump(key_domain_id),
        dump(vault_key_version_id),
        generation,
        wrapped_key
      ]
    )
  end

  defp grant_rotation_access!(fixture) do
    Fixtures.with_owner(fn ->
      for capability <- ["vault.password_change", "vault.unlock"] do
        capability_id = Ecto.UUID.generate()

        query!(
          MigrationRepo,
          """
          INSERT INTO core.capabilities (id, name)
          VALUES ($1, $2)
          ON CONFLICT (name) DO NOTHING
          """,
          [dump(capability_id), capability]
        )

        %{rows: [[stored_capability_id]]} =
          query!(
            MigrationRepo,
            "SELECT id FROM core.capabilities WHERE name = $1",
            [capability]
          )

        query!(
          MigrationRepo,
          """
          INSERT INTO core.principal_capabilities (
            principal_id, vault_id, capability_id
          ) VALUES ($1, $2, $3)
          ON CONFLICT DO NOTHING
          """,
          [
            dump(fixture.principal_id),
            dump(fixture.vault_id),
            stored_capability_id
          ]
        )
      end

      query!(
        MigrationRepo,
        """
        UPDATE core.vault_members
        SET clearance = 'restricted', updated_at = CURRENT_TIMESTAMP
        WHERE principal_id = $1 AND vault_id = $2
        """,
        [dump(fixture.principal_id), dump(fixture.vault_id)]
      )

      query!(
        MigrationRepo,
        """
        UPDATE core.vaults
        SET locked = false, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        """,
        [dump(fixture.vault_id)]
      )
    end)
  end

  defp load_live_session!(fixture) do
    assert {:ok, live} =
             scoped(
               fixture,
               &IdentityRepository.load_live_session(&1, fixture.session_id)
             )

    assert live.clearance == :restricted
    assert live.vault_locked == false
    assert "vault.password_change" in live.capabilities
    assert "vault.unlock" in live.capabilities
    live
  end

  defp session_context(live, unlocked?) do
    %SessionContext{
      session_id: live.session_id,
      account_id: live.account_id,
      principal_id: live.principal_id,
      vault_id: live.vault_id,
      expires_at: live.session_expires_at,
      principal_authorization_epoch: live.principal_authorization_epoch,
      vault_authorization_epoch: live.vault_authorization_epoch,
      authorization_epoch: live.principal_authorization_epoch,
      unlocked?: unlocked?
    }
  end

  defp start_custodian! do
    lease_supervisor =
      start_supervised!(
        {KeyLeaseSupervisor, name: nil},
        id: make_ref()
      )

    options =
      Application.fetch_env!(:singularity_runtime, :key_custodian)
      |> Map.merge(%{
        idle_lock: nil,
        idle_timeout_ms: :timer.hours(1),
        key_wrapper: KeyWrapper,
        lease_supervisor: lease_supervisor
      })

    start_supervised!(Supervisor.child_spec({KeyCustodian, options}, id: make_ref()))
  end

  defp activate_custody!(custodian, session, key_material) do
    custody = %{
      session_id: session.session_id,
      principal_id: session.principal_id,
      vault_id: session.vault_id,
      principal_authorization_epoch: session.principal_authorization_epoch,
      vault_authorization_epoch: session.vault_authorization_epoch,
      vault_key: @vault_key,
      domain_key: @primary_domain_key,
      domain_dedup_key: @dedup_key,
      key_domain_id: key_material.primary_domain_id,
      domain_key_version_id: key_material.primary_domain_version_id,
      domain_key_generation: 5,
      domain_classification: :restricted,
      object_keys: %{{key_material.object_id, 5} => @object_dek}
    }

    with {:ok, pending} <- KeyCustodian.prepare_unlock(custodian, custody) do
      KeyCustodian.activate_unlock(custodian, pending)
    end
  end

  defp active_vault_material(fixture) do
    Fixtures.with_owner(fn ->
      %{rows: [[version_id, version_generation, wrapper_generation, wrapped_key]]} =
        query!(
          MigrationRepo,
          """
          SELECT
            version.id,
            version.generation,
            wrapper.generation,
            wrapper.wrapped_key
          FROM core.vault_key_versions AS version
          JOIN core.vault_key_wrappers AS wrapper
            ON wrapper.vault_key_version_id = version.id
           AND wrapper.vault_id = version.vault_id
          WHERE version.vault_id = $1
            AND version.state = 'active'
            AND wrapper.account_id = $2
          """,
          [dump(fixture.vault_id), dump(fixture.account_id)]
        )

      %{
        version_id: Ecto.UUID.load!(version_id),
        version_generation: version_generation,
        wrapper_generation: wrapper_generation,
        wrapped_key: wrapped_key
      }
    end)
  end

  defp active_domains(fixture) do
    Fixtures.with_owner(fn ->
      %{rows: rows} =
        query!(
          MigrationRepo,
          """
          SELECT
            key_domain_id,
            vault_key_version_id,
            generation,
            wrapped_key
          FROM core.domain_key_versions
          WHERE vault_id = $1 AND state = 'active'
          ORDER BY key_domain_id
          """,
          [dump(fixture.vault_id)]
        )

      Enum.map(rows, fn [domain_id, vault_version_id, generation, wrapped_key] ->
        %{
          key_domain_id: Ecto.UUID.load!(domain_id),
          vault_key_version_id: Ecto.UUID.load!(vault_version_id),
          generation: generation,
          wrapped_key: wrapped_key
        }
      end)
    end)
  end

  defp active_domain_material(fixture, key_domain_id) do
    Fixtures.with_owner(fn ->
      %{rows: [[id, generation, vault_version_id, wrapped_key, wrapped_dedup_key]]} =
        query!(
          MigrationRepo,
          """
          SELECT
            version.id,
            version.generation,
            version.vault_key_version_id,
            version.wrapped_key,
            dedup.wrapped_key
          FROM core.domain_key_versions AS version
          JOIN core.domain_dedup_key_wrappers AS dedup
            ON dedup.domain_key_version_id = version.id
           AND dedup.vault_id = version.vault_id
           AND dedup.key_domain_id = version.key_domain_id
          WHERE version.vault_id = $1
            AND version.key_domain_id = $2
            AND version.state = 'active'
          """,
          [dump(fixture.vault_id), dump(key_domain_id)]
        )

      %{rows: envelope_rows} =
        query!(
          MigrationRepo,
          """
          SELECT
            asset_object_id,
            domain_key_version_id,
            key_generation,
            wrapped_dek
          FROM content.asset_key_envelopes
          WHERE vault_id = $1
            AND key_domain_id = $2
            AND domain_key_version_id = $3
          ORDER BY asset_object_id
          """,
          [dump(fixture.vault_id), dump(key_domain_id), id]
        )

      %{
        id: Ecto.UUID.load!(id),
        generation: generation,
        vault_key_version_id: Ecto.UUID.load!(vault_version_id),
        wrapped_key: wrapped_key,
        wrapped_dedup_key: wrapped_dedup_key,
        envelopes:
          Enum.map(
            envelope_rows,
            fn [object_id, domain_version_id, key_generation, wrapped_dek] ->
              %{
                asset_object_id: Ecto.UUID.load!(object_id),
                domain_key_version_id: Ecto.UUID.load!(domain_version_id),
                key_generation: key_generation,
                wrapped_dek: wrapped_dek
              }
            end
          )
      }
    end)
  end

  defp object_snapshot(fixture, object_id) do
    Fixtures.with_owner(fn ->
      %{rows: [row]} =
        query!(
          MigrationRepo,
          """
          SELECT
            lookup_digest,
            ciphertext_hash,
            plaintext_byte_size,
            ciphertext_byte_size,
            storage_ref,
            format_version,
            lifecycle
          FROM content.asset_objects
          WHERE vault_id = $1 AND id = $2
          """,
          [dump(fixture.vault_id), dump(object_id)]
        )

      row
    end)
  end

  defp vault_locked?(fixture) do
    Fixtures.with_owner(fn ->
      %{rows: [[locked?]]} =
        query!(
          MigrationRepo,
          "SELECT locked FROM core.vaults WHERE id = $1",
          [dump(fixture.vault_id)]
        )

      locked?
    end)
  end

  defp derive_vault_kek! do
    assert {:ok, vault_kek} =
             Argon2KeyDeriver.derive(
               @password,
               :binary.copy(<<0x19>>, 16),
               @kdf_parameters
             )

    vault_kek
  end

  defp unwrap_domain(vault_key, wrapped_key, vault_id, key_domain_id, generation) do
    KeyWrapper.unwrap(vault_key, wrapped_key, %{
      purpose: :domain_key,
      generation: generation,
      aad: vault_id <> ":" <> key_domain_id
    })
  end

  defp wrap!(wrapping_key, raw_key, purpose, generation, aad) do
    assert {:ok, %{encoded: encoded}} =
             KeyWrapper.wrap(wrapping_key, raw_key, %{
               purpose: purpose,
               generation: generation,
               aad: aad
             })

    encoded
  end

  defp refute_secrets(values, secrets) do
    refute Enum.any?(leaves(values), fn
             binary when is_binary(binary) ->
               Enum.any?(secrets, &binary_match?(binary, &1))

             _other ->
               false
           end)
  end

  defp binary_match?(candidate, secret)
       when is_binary(secret) and byte_size(secret) > 0 and
              byte_size(candidate) >= byte_size(secret),
       do: :binary.match(candidate, secret) != :nomatch

  defp binary_match?(_candidate, _secret), do: false

  defp leaves(value) when is_struct(value),
    do: value |> Map.from_struct() |> leaves()

  defp leaves(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&leaves/1)

  defp leaves(value) when is_list(value), do: Enum.flat_map(value, &leaves/1)
  defp leaves(value) when is_tuple(value), do: value |> Tuple.to_list() |> leaves()
  defp leaves(value), do: [value]

  defp scoped(fixture, callback) do
    RequestRepo.checkout(fn ->
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: fixture.principal_id, vault_id: fixture.vault_id},
        callback
      )
    end)
  end

  defp string_keyed_kdf_parameters do
    Map.new(@kdf_parameters, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp load_ids(fixture) do
    Map.new(fixture, fn
      {key, value}
      when key in [
             :account_id,
             :asset_id,
             :credential_id,
             :principal_id,
             :resource_id,
             :resource_version_id,
             :session_id,
             :vault_id
           ] ->
        {key, Ecto.UUID.load!(value)}

      pair ->
        pair
    end)
  end

  defp dump(<<_uuid::binary-size(16)>> = value), do: value
  defp dump(value), do: Ecto.UUID.dump!(value)
end
