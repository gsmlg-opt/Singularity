defmodule Singularity.Storage.Backup.RestoreRewrapTest do
  use ExUnit.Case, async: false

  import Singularity.Storage.AuditAssertions, only: [assert_persisted_audit!: 4]

  alias Ecto.Adapters.SQL
  alias Singularity.Core.Error
  alias Singularity.Storage.Backup.IntegrityAudit
  alias Singularity.Storage.Backup.LogicalSchema
  alias Singularity.Storage.Backup.Restorer
  alias Singularity.Storage.MigrationRepo

  @manifest_id "00000000-0000-4000-8000-000000000811"
  @vault_id "00000000-0000-4000-8000-000000000812"
  @person_id "00000000-0000-4000-8000-000000000813"
  @account_id "00000000-0000-4000-8000-000000000814"
  @active_credential_id "00000000-0000-4000-8000-000000000815"
  @revoked_credential_id "00000000-0000-4000-8000-000000000816"
  @owner_principal_id "00000000-0000-4000-8000-000000000817"
  @vault_key_version_id "00000000-0000-4000-8000-000000000818"
  @wrapper_id "00000000-0000-4000-8000-000000000819"
  @conflicting_principal_id "00000000-0000-4000-8000-000000000820"
  @conflicting_capability_id "00000000-0000-4000-8000-000000000821"
  @password "RESTORE_PASSWORD_CANARY_811"
  @verifier "fresh-verifier-811"
  @salt :binary.copy(<<0x81>>, 16)
  @kek :binary.copy(<<0x82>>, 32)
  @vault_key :binary.copy(<<0x83>>, 32)
  @encoded_wrapper "new-owner-wrapper-811"

  defmodule PasswordHasher do
    def hash(password) do
      send(self(), {:password_hash, password})
      {:ok, "fresh-verifier-811"}
    end
  end

  defmodule KeyDeriver do
    def derive(password, salt, params) do
      send(self(), {:derive, password, salt, params})
      {:ok, :binary.copy(<<0x82>>, 32)}
    end
  end

  defmodule RecoveredVaultKey do
    def rewrap(capability, kek, binding) do
      send(self(), {:recovered_rewrap, capability, kek, binding})

      {:ok,
       %{
         algorithm: :aes_256_gcm,
         encoded: "new-owner-wrapper-811",
         generation: binding.generation,
         purpose: :vault_key,
         version: 1
       }}
    end

    def revoke(capability) do
      send(self(), {:recovered_revoke, capability})
      :ok
    end
  end

  defmodule KeyWrapper do
    def unwrap(kek, encoded, metadata) do
      send(self(), {:unwrap, kek, encoded, metadata})
      {:ok, :binary.copy(<<0x83>>, 32)}
    end
  end

  defmodule IntegrityIssuer do
    def issue(options) do
      send(self(), {:integrity_issue, options})
      {:ok, :opaque_integrity_capability}
    end

    def revoke(capability) do
      send(self(), {:integrity_revoke, capability})
      :ok
    end
  end

  defmodule ObjectStorage do
    def stat(_context, _object_ref), do: {:error, Error.new(:not_found)}
    def open(_context, _object_ref), do: {:error, Error.new(:not_found)}
    def read_range(_handle, _offset, _length), do: {:error, Error.new(:not_found)}
  end

  @tag :integration
  test "rewraps the owner, leaves revoked credentials inert, and creates one audit identity" do
    with_clean_destination(fn storage_root ->
      seed_restore_pending!()
      imported = imported()
      context = context(MigrationRepo, storage_root)

      assert {:ok,
              %Restorer.Rewrapped{
                manifest: %{manifest_id: @manifest_id},
                integrity_capability: :opaque_integrity_capability = integrity_capability,
                integrity_principal_id: integrity_principal_id,
                owner: %{wrapper_generation: 10, vault_key_generation: 7}
              } = rewrapped} =
               Restorer.rewrap_owner(context, imported, @password, :opaque_recovered_capability)

      assert_receive {:password_hash, @password}
      assert_receive {:derive, @password, @salt, kdf_params}
      assert kdf_params == context.vault_kdf_params

      assert_receive {:recovered_rewrap, :opaque_recovered_capability, @kek,
                      %{vault_id: @vault_id, generation: 10}}

      assert_receive {:unwrap, @kek, @encoded_wrapper,
                      %{purpose: :vault_key, generation: 10, aad: @vault_id}}

      assert_receive {:integrity_issue,
                      %{
                        owner: owner,
                        vault_key: @vault_key,
                        binding: %{
                          manifest_id: @manifest_id,
                          vault_id: @vault_id,
                          vault_key_version_id: @vault_key_version_id,
                          vault_key_generation: 7
                        },
                        inventory: [],
                        material_loader: {IntegrityAudit, MigrationRepo},
                        object_storage: {ObjectStorage, %{root: object_root}},
                        key_wrapper: KeyWrapper,
                        ttl_ms: 5_000
                      }}

      assert owner == self()
      assert object_root == storage_root
      assert_receive {:recovered_revoke, :opaque_recovered_capability}
      refute_receive {:integrity_revoke, ^integrity_capability}

      assert_rewrapped_rows(integrity_principal_id)
      assert audit_event_count("backup.restore_completed") == 0

      inspected = inspect(rewrapped)

      for secret <- [@password, @verifier, @encoded_wrapper, @kek, @vault_key] do
        refute inspected =~ secret
      end

      assert :ok = Restorer.complete_restore(context, rewrapped)
      assert :ok = Restorer.complete_restore(context, rewrapped)
      assert_completion_is_idempotent()
    end)
  end

  test "revokes the issued integrity capability when the serializable commit fails" do
    context = context(MissingMigrationRepo, "/tmp/restore-rewrap-failure")

    assert {:error, %Error{code: :storage_unavailable}} =
             Restorer.rewrap_owner(
               context,
               imported(),
               @password,
               :opaque_recovered_capability
             )

    assert_receive {:integrity_issue, _options}
    assert_receive {:integrity_revoke, :opaque_integrity_capability}
    assert_receive {:recovered_revoke, :opaque_recovered_capability}
  end

  @tag :integration
  test "rolls back verifier and wrapper changes when the audit identity is over-privileged" do
    with_clean_destination(fn storage_root ->
      seed_restore_pending!()
      seed_over_privileged_integrity_principal!()

      assert {:error, %Error{code: :conflict}} =
               Restorer.rewrap_owner(
                 context(MigrationRepo, storage_root),
                 imported(),
                 @password,
                 :opaque_recovered_capability
               )

      assert_receive {:integrity_issue, _options}
      assert_receive {:integrity_revoke, :opaque_integrity_capability}
      assert_receive {:recovered_revoke, :opaque_recovered_capability}
      assert_restore_still_pending()
    end)
  end

  defp context(migration_repo, object_root) do
    %{
      migration_repo: migration_repo,
      password_hasher: PasswordHasher,
      key_deriver: KeyDeriver,
      key_wrapper: KeyWrapper,
      recovered_vault_key: RecoveredVaultKey,
      integrity_issuer: IntegrityIssuer,
      integrity_ttl_ms: 5_000,
      object_storage: {ObjectStorage, %{root: object_root}},
      random_bytes: fn 16 -> @salt end,
      vault_kdf_params: %{version: 1, t_cost: 2, m_cost: 16, parallelism: 1}
    }
  end

  defp imported do
    %Restorer.Imported{
      manifest: %{manifest_id: @manifest_id},
      manifest_hash: :binary.copy(<<0x84>>, 32),
      manifest_tag: :binary.copy(<<0x85>>, 16),
      cut: %{manifest_id: @manifest_id, vault_id: @vault_id, object_inventory: []},
      object_inventory: [],
      owner: %{
        account_id: @account_id,
        active_credential_ids: [@active_credential_id],
        all_credential_ids: [@active_credential_id, @revoked_credential_id],
        owner_principal_ids: [@owner_principal_id],
        vault_key_wrapper_id: @wrapper_id,
        wrapper_generation: 9,
        vault_key_version_id: @vault_key_version_id,
        vault_key_generation: 7
      }
    }
  end

  defp seed_restore_pending! do
    owner_transaction(fn ->
      %{rows: [[dummy_verifier]]} =
        query!("SELECT dummy_verifier FROM identity.security_settings WHERE singleton")

      now = DateTime.utc_now()

      query!(
        "INSERT INTO identity.people (id, display_name) VALUES ($1, 'Restore Owner')",
        [uuid(@person_id)]
      )

      query!(
        "INSERT INTO identity.accounts (id, person_id) VALUES ($1, $2)",
        [uuid(@account_id), uuid(@person_id)]
      )

      for {id, login, revoked_at} <- [
            {@active_credential_id, "restore-owner@example.test", nil},
            {@revoked_credential_id, "old-restore-owner@example.test", now}
          ] do
        query!(
          """
          INSERT INTO identity.credentials (
            id, account_id, normalized_login, verifier, verifier_version, revoked_at
          )
          VALUES ($1, $2, $3, $4, 1, $5)
          """,
          [uuid(id), uuid(@account_id), login, dummy_verifier, revoked_at]
        )
      end

      query!(
        """
        INSERT INTO identity.principals (id, account_id, kind, metadata)
        VALUES ($1, $2, 'owner', '{"name":"owner"}'::jsonb)
        """,
        [uuid(@owner_principal_id), uuid(@account_id)]
      )

      query!("INSERT INTO core.vaults (id, locked) VALUES ($1, true)", [uuid(@vault_id)])

      query!(
        """
        INSERT INTO core.vault_members (principal_id, vault_id, clearance)
        VALUES ($1, $2, 'restricted')
        """,
        [uuid(@owner_principal_id), uuid(@vault_id)]
      )

      query!(
        """
        INSERT INTO core.vault_key_versions (
          id, vault_id, generation, state, algorithm, activated_at
        )
        VALUES ($1, $2, 7, 'active', 'aes_256_gcm', CURRENT_TIMESTAMP)
        """,
        [uuid(@vault_key_version_id), uuid(@vault_id)]
      )

      query!(
        """
        INSERT INTO core.vault_key_wrappers (
          id, vault_id, vault_key_version_id, account_id, generation,
          kdf_version, kdf_salt, kdf_parameters, wrapper_algorithm, wrapped_key
        )
        VALUES (
          $1, $2, $3, $4, 9, 1, 'restore-pending',
          '{"state":"restore_pending","version":1}'::jsonb,
          'restore_pending', 'restore-pending'
        )
        """,
        [uuid(@wrapper_id), uuid(@vault_id), uuid(@vault_key_version_id), uuid(@account_id)]
      )
    end)
  end

  defp assert_rewrapped_rows(integrity_principal_id) do
    owner_transaction(fn ->
      assert %{rows: credential_rows} =
               query!("""
               SELECT
                 credential.id,
                 credential.verifier,
                 credential.revoked_at IS NULL,
                 credential.verifier = setting.dummy_verifier
               FROM identity.credentials AS credential
               CROSS JOIN identity.security_settings AS setting
               WHERE setting.singleton
               ORDER BY credential.id
               """)

      assert [
               [active_id, @verifier, true, false],
               [revoked_id, _revoked_verifier, false, true]
             ] = credential_rows

      assert Ecto.UUID.load!(active_id) == @active_credential_id
      assert Ecto.UUID.load!(revoked_id) == @revoked_credential_id

      assert %{rows: [[10, 1, @salt, params, "aes_256_gcm", @encoded_wrapper]]} =
               query!(
                 """
                 SELECT generation, kdf_version, kdf_salt, kdf_parameters,
                        wrapper_algorithm, wrapped_key
                 FROM core.vault_key_wrappers
                 WHERE id = $1
                 """,
                 [uuid(@wrapper_id)]
               )

      assert params == %{
               "version" => 1,
               "t_cost" => 2,
               "m_cost" => 16,
               "parallelism" => 1
             }

      assert %{rows: [[true]]} =
               query!("SELECT locked FROM core.vaults WHERE id = $1", [uuid(@vault_id)])

      assert %{rows: [["system", %{"name" => "integrity_audit"}, nil]]} =
               query!(
                 "SELECT kind, metadata, revoked_at FROM identity.principals WHERE id = $1",
                 [uuid(integrity_principal_id)]
               )

      assert %{rows: [["restricted", nil]]} =
               query!(
                 """
                 SELECT clearance, revoked_at
                 FROM core.vault_members
                 WHERE principal_id = $1 AND vault_id = $2
                 """,
                 [uuid(integrity_principal_id), uuid(@vault_id)]
               )

      assert %{rows: [["integrity.audit", nil]]} =
               query!(
                 """
                 SELECT capability.name, assignment.revoked_at
                 FROM core.principal_capabilities AS assignment
                 JOIN core.capabilities AS capability ON capability.id = assignment.capability_id
                 WHERE assignment.principal_id = $1 AND assignment.vault_id = $2
                 """,
                 [uuid(integrity_principal_id), uuid(@vault_id)]
               )

      assert_persisted_audit!(
        MigrationRepo,
        "credential.rewrapped_after_restore",
        [target_id: @manifest_id],
        actor_kind: "system",
        system_principal_name: "integrity_audit",
        result: "completed",
        target_type: "backup_manifest"
      )

      assert %{
               rows: [
                 ["credential.rewrapped_after_restore", "system", "integrity_audit", target_id]
               ]
             } =
               query!("""
               SELECT operation, actor_kind, system_principal_name, target_id
               FROM audit.events
               WHERE operation = 'credential.rewrapped_after_restore'
               """)

      assert Ecto.UUID.load!(target_id) == @manifest_id
    end)
  end

  defp seed_over_privileged_integrity_principal! do
    owner_transaction(fn ->
      query!(
        """
        INSERT INTO identity.principals (id, account_id, kind, metadata)
        VALUES ($1, $2, 'system', '{"name":"integrity_audit"}'::jsonb)
        """,
        [uuid(@conflicting_principal_id), uuid(@account_id)]
      )

      query!(
        """
        INSERT INTO core.vault_members (principal_id, vault_id, clearance)
        VALUES ($1, $2, 'restricted')
        """,
        [uuid(@conflicting_principal_id), uuid(@vault_id)]
      )

      query!(
        "INSERT INTO core.capabilities (id, name) VALUES ($1, 'vault.password_change')",
        [uuid(@conflicting_capability_id)]
      )

      query!(
        """
        INSERT INTO core.principal_capabilities (principal_id, vault_id, capability_id)
        VALUES ($1, $2, $3)
        """,
        [
          uuid(@conflicting_principal_id),
          uuid(@vault_id),
          uuid(@conflicting_capability_id)
        ]
      )
    end)
  end

  defp assert_restore_still_pending do
    owner_transaction(fn ->
      assert %{rows: [[true]]} =
               query!("""
               SELECT bool_and(credential.verifier = setting.dummy_verifier)
               FROM identity.credentials AS credential
               CROSS JOIN identity.security_settings AS setting
               WHERE setting.singleton
               """)

      assert %{rows: [[9, "restore_pending", "restore-pending"]]} =
               query!(
                 """
                 SELECT generation, wrapper_algorithm, wrapped_key
                 FROM core.vault_key_wrappers
                 WHERE id = $1
                 """,
                 [uuid(@wrapper_id)]
               )

      assert audit_event_count_in_transaction("credential.rewrapped_after_restore") == 0
    end)
  end

  defp assert_completion_is_idempotent do
    owner_transaction(fn ->
      assert_persisted_audit!(
        MigrationRepo,
        "backup.restore_completed",
        [target_id: @manifest_id],
        actor_kind: "system",
        system_principal_name: "integrity_audit",
        result: "completed",
        target_type: "backup_manifest"
      )

      assert %{rows: rows} =
               query!("""
               SELECT operation, actor_kind, system_principal_name, target_id
               FROM audit.events
               WHERE operation = 'backup.restore_completed'
               """)

      assert [["backup.restore_completed", "system", "integrity_audit", target_id]] = rows
      assert Ecto.UUID.load!(target_id) == @manifest_id
    end)
  end

  defp audit_event_count(operation) do
    owner_transaction(fn ->
      audit_event_count_in_transaction(operation)
    end)
  end

  defp audit_event_count_in_transaction(operation) do
    %{rows: [[count]]} =
      query!("SELECT count(*) FROM audit.events WHERE operation = $1", [operation])

    count
  end

  defp with_clean_destination(operation) do
    {migration_repo, started_here?} = ensure_migration_repo_started!()

    storage_root =
      :singularity_storage
      |> Application.fetch_env!(:storage_root)
      |> Path.join("restore-rewrap-#{System.unique_integer([:positive])}")

    reset_destination!()
    File.rm_rf!(storage_root)

    try do
      operation.(storage_root)
    after
      reset_destination!()
      File.rm_rf!(storage_root)

      if started_here? and Process.alive?(migration_repo) do
        Supervisor.stop(migration_repo)
      end
    end
  end

  defp ensure_migration_repo_started! do
    case Process.whereis(MigrationRepo) do
      nil ->
        case MigrationRepo.start_link(pool_size: 2) do
          {:ok, migration_repo} -> {migration_repo, true}
          {:error, {:already_started, migration_repo}} -> {migration_repo, false}
        end

      migration_repo ->
        {migration_repo, false}
    end
  end

  defp reset_destination! do
    tables =
      (LogicalSchema.tables() ++
         ~w[
           identity.sessions identity.auth_attempts content.asset_stages
           content.upload_grants content.asset_search_documents audit.backup_manifests
           audit.backup_manifest_objects audit.restore_import_sagas jobs.oban_jobs jobs.oban_peers
         ])
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_join(", ", &quote_table/1)

    owner_transaction(fn ->
      query!("TRUNCATE TABLE #{tables} RESTART IDENTITY CASCADE")
    end)
  end

  defp owner_transaction(operation) do
    {:ok, result} =
      MigrationRepo.transaction(fn ->
        query!("SET LOCAL ROLE singularity_table_owner")
        operation.()
      end)

    result
  end

  defp query!(statement, parameters \\ []) do
    {:ok, result} = SQL.query(MigrationRepo, statement, parameters, log: false)
    result
  end

  defp quote_table(table) do
    table
    |> String.split(".")
    |> Enum.map_join(".", &~s("#{&1}"))
  end

  defp uuid(value), do: Ecto.UUID.dump!(value)
end
