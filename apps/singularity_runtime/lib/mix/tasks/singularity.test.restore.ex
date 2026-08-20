defmodule Mix.Tasks.Singularity.Test.Restore do
  use Mix.Task

  import ExUnit.Assertions, only: [assert: 1]

  alias Singularity.Storage.SafeSQL, as: SQL
  alias Singularity.Runtime.AuthorizationDependencies
  alias Singularity.Runtime.Api
  alias Singularity.Runtime.BackupKeyLease
  alias Singularity.Runtime.BootstrapOwner
  alias Singularity.Runtime.IntegrityAudit
  alias Singularity.Runtime.KeyCustodian
  alias Singularity.Runtime.Login
  alias Singularity.Runtime.OperationScope
  alias Singularity.Runtime.ResolveSession
  alias Singularity.Runtime.RestoreAuthenticator
  alias Singularity.Runtime.RestoreIntegrityLease
  alias Singularity.Runtime.RestoreVault
  alias Singularity.Runtime.UnlockVault
  alias Singularity.Storage.AuthorizationLock
  alias Singularity.Storage.Backup.BundleReader
  alias Singularity.Storage.Backup.IntegrityAudit, as: StorageIntegrityAudit
  alias Singularity.Storage.Backup.LocalDestination
  alias Singularity.Storage.Backup.LogicalBundleVerifier
  alias Singularity.Storage.Backup.LogicalRecordCodec
  alias Singularity.Storage.Backup.LogicalSchema
  alias Singularity.Storage.Backup.Reconciler
  alias Singularity.Storage.Backup.Restorer
  alias Singularity.Storage.Crypto.Argon2KeyDeriver
  alias Singularity.Storage.Crypto.Argon2PasswordHasher
  alias Singularity.Storage.Crypto.BackupRecoveryWrapper
  alias Singularity.Storage.Crypto.ChunkedAEAD
  alias Singularity.Storage.Crypto.KeyWrapper
  alias Singularity.Storage.Crypto.RecoveredVaultKey
  alias Singularity.Storage.MigrationRepo
  alias Singularity.Storage.Postgres.BackupRepository
  alias Singularity.Storage.Postgres.IdentityRepository
  alias Singularity.Storage.Postgres.PreAuth
  alias Singularity.Storage.PreAuthRepo
  alias Singularity.Storage.RequestRepo
  alias Singularity.Storage.ScopedRepo
  alias Singularity.Storage.TestEnvironment
  alias Singularity.Storage.VaultLock

  @shortdoc "Runs the encrypted backup and restore oracle in isolated databases"
  @required_tasks ~w[singularity.backup singularity.restore]
  @password_params %{version: 1, t_cost: 1, m_cost: 8, parallelism: 1}
  @backup_kdf_parameters %{
    "version" => 1,
    "t_cost" => 1,
    "m_cost" => 8,
    "parallelism" => 1
  }
  @backup_kdf_domain "singularity.backup.bundle.v1"
  @capture_env "SINGULARITY_CAPTURE_LOGICAL_V1"
  @capture_passphrase "singularity-v1-compatibility-passphrase"
  @note_seed_stage_key {__MODULE__, :note_seed_stage}
  @vault_key_process_key {__MODULE__, :bootstrap_vault_key}
  @storage_env_keys [
    Singularity.Storage.MigrationRepo,
    Singularity.Storage.RequestRepo,
    Singularity.Storage.PreAuthRepo,
    Singularity.Storage.DispatcherRepo,
    Singularity.Storage.WorkerRepo,
    :storage_root
  ]

  defmodule OracleIds do
    @moduledoc false

    def generate, do: Ecto.UUID.generate()
  end

  defmodule OracleBackupKeyDeriver do
    @moduledoc false

    def derive(
          passphrase,
          %{
            domain: "singularity.backup.bundle.v1",
            parameters: parameters,
            salt: salt
          }
        ) do
      Singularity.Storage.Crypto.Argon2KeyDeriver.derive(
        passphrase,
        salt,
        atomize(parameters)
      )
    end

    defp atomize(%{
           "version" => version,
           "t_cost" => t_cost,
           "m_cost" => m_cost,
           "parallelism" => parallelism
         }),
         do: %{
           version: version,
           t_cost: t_cost,
           m_cost: m_cost,
           parallelism: parallelism
         }

    defp atomize(parameters), do: parameters
  end

  defmodule OracleJobs do
    @moduledoc false

    def wake_vault(_vault_id), do: :ok
  end

  defmodule OraclePartialBundles do
    @moduledoc false

    def cleanup(context, destination_ref, manifest_id) do
      Singularity.Storage.Backup.LocalDestination.cleanup_partial(
        context,
        destination_ref,
        manifest_id
      )
    end
  end

  defmodule OracleBackupOperation do
    @moduledoc false

    alias Singularity.Core.Error
    alias Singularity.Runtime.BackupVault
    alias Singularity.Runtime.OutboxDispatcher

    def request(context, runtime, session, passphrase, destination_ref) do
      with {:ok, requested} <- BackupVault.request(runtime, session, passphrase, destination_ref),
           {:ok, %{failed: 0, submitted: 1}} <- OutboxDispatcher.dispatch_once(%{}),
           %{failure: 0, success: 1} <- Oban.drain_queue(Singularity.Oban, queue: :backup),
           {:ok, snapshot} <- context.snapshot.(requested) do
        {:ok, Map.put(requested, :oracle_snapshot, snapshot)}
      else
        {:error, %Error{} = error} -> {:error, error}
        _failure -> {:error, Error.new(:job_failed)}
      end
    end
  end

  defmodule OracleRestoreOperation do
    @moduledoc false

    alias Singularity.Runtime.RestoreVault

    def run(context, restore_context, request) do
      with {:ok, restored} <- restore(restore_context, request),
           {:ok, snapshot} <- context.snapshot.(restored.manifest_id) do
        {:ok, Map.put(restored, :oracle_snapshot, snapshot)}
      end
    end

    defp restore(restore_context, request) do
      result = RestoreVault.run(restore_context, request)

      case result do
        {:error, %{code: code}} ->
          Mix.shell().info("restore_oracle_stage=restore_vault code=#{code}")

        _result ->
          :ok
      end

      result
    end
  end

  defmodule OracleMaintenanceMode do
    @moduledoc false

    alias Singularity.Core.Error

    def require_maintenance(true) do
      Mix.shell().info("restore_oracle_stage=maintenance_mode ok=true")
      :ok
    end

    def require_maintenance(_mode), do: {:error, Error.new(:conflict)}
  end

  defmodule OracleDestination do
    @moduledoc false

    alias Singularity.Storage.SafeSQL, as: SQL
    alias Singularity.Core.Error
    alias Singularity.Storage.Backup.LocalDestination

    def normalize(context, operator_path), do: LocalDestination.normalize(context, operator_path)

    def reader_source(context, destination_ref),
      do: LocalDestination.reader_source(context, destination_ref)

    def require_empty(%{storage_root: storage_root}, repo) do
      result =
        with {:ok, []} <- File.ls(storage_root),
             {:ok, %{rows: [[false]]}} <- empty_database(repo) do
          :ok
        else
          {:ok, _nonempty} -> {:error, Error.new(:conflict)}
          {:error, _reason} -> {:error, Error.new(:storage_unavailable, retryable?: true)}
          _failure -> {:error, Error.new(:conflict)}
        end

      case result do
        :ok ->
          Mix.shell().info("restore_oracle_stage=empty_destination ok=true")

        {:error, %{code: code}} ->
          Mix.shell().info("restore_oracle_stage=empty_destination code=#{code}")
      end

      result
    end

    defp empty_database(repo) do
      repo.transaction(fn ->
        SQL.query!(repo, "SET LOCAL ROLE singularity_table_owner", [], log: false)

        SQL.query!(
          repo,
          """
          SELECT EXISTS (
            SELECT 1 FROM identity.people
            UNION ALL SELECT 1 FROM core.vaults
            UNION ALL SELECT 1 FROM content.resources
            UNION ALL SELECT 1 FROM content.resource_versions
            UNION ALL SELECT 1 FROM content.assets
            UNION ALL SELECT 1 FROM content.note_versions
            UNION ALL SELECT 1 FROM content.note_conflicts
            UNION ALL SELECT 1 FROM content.note_search_documents
            UNION ALL SELECT 1 FROM content.note_mutation_receipts
            UNION ALL SELECT 1 FROM audit.events
          )
          """,
          [],
          log: false
        )
      end)
    rescue
      _exception -> {:error, :unavailable}
    end
  end

  @impl Mix.Task
  def run([]) do
    Mix.Task.run("app.config")
    assert_test_environment!()
    Singularity.Storage.RoleVerifier.verify!()

    source_names = TestEnvironment.allocate!()
    destination_names = TestEnvironment.allocate!()
    v1_destination_names = TestEnvironment.allocate!()
    assert_distinct!(source_names, destination_names)
    assert_distinct!(source_names, v1_destination_names)
    assert_distinct!(destination_names, v1_destination_names)
    print_names(source_names, destination_names)
    print_v1_name(v1_destination_names)
    assert_required_tasks!()
    capture_path = capture_path!()

    previous_env = snapshot_environment()
    bundle_path = bundle_path(source_names, destination_names)
    secrets = oracle_secrets(source_names, destination_names, capture_path)

    try do
      with_secret_descriptors(bundle_path, secrets, fn descriptors ->
        source = backup_source!(source_names, bundle_path, descriptors)

        destination =
          restore_destination!(
            destination_names,
            bundle_path,
            descriptors,
            source,
            secrets.new_password
          )

        assert_restored!(source, destination)
        restore_v1_fixture!(v1_destination_names, descriptors, secrets.v1_new_password)
        capture_bundle!(bundle_path, capture_path)
      end)
    after
      cleanup!(
        source_names,
        destination_names,
        v1_destination_names,
        bundle_path,
        previous_env
      )
    end
  end

  def run(_arguments) do
    Mix.raise("singularity.test.restore accepts no arguments")
  end

  defp backup_source!(names, bundle_path, descriptors) do
    Application.put_env(:singularity_runtime, :maintenance_mode, false)
    TestEnvironment.create!(names)

    {owner, owner_password, vault_key} = bootstrap_source!(names)

    stop_runtime_repositories()
    configure_source_runtime!()
    Application.put_env(:singularity_runtime, :start_infrastructure, true)
    {:ok, _started} = Application.ensure_all_started(:singularity_runtime)

    session = login_and_unlock!(owner, owner_password)
    note_oracle = seed_source_notes!(session)
    drain_note_projection_jobs!()
    runtime = backup_runtime()

    Application.put_env(:singularity_runtime, :backup_task, %{
      operation:
        {OracleBackupOperation,
         %{snapshot: &source_snapshot(&1, names.storage_root, note_oracle)}},
      runtime: runtime,
      session: Map.put(session, :vault_key, vault_key)
    })

    result =
      run_task!("singularity.backup", [
        "--restore-oracle",
        "--passphrase-fd",
        Integer.to_string(descriptors.backup_passphrase.fd),
        "--destination",
        bundle_path
      ])

    stop_runtime_and_repositories()

    result
    |> oracle_snapshot!("singularity.backup")
    |> Map.put(:owner_login, owner.login)
  end

  defp restore_destination!(names, bundle_path, descriptors, source, new_password) do
    Application.put_env(:singularity_runtime, :maintenance_mode, true)
    TestEnvironment.create!(names)
    stop_runtime_repositories()
    Application.put_env(:singularity_runtime, :start_infrastructure, false)
    {:ok, _migration_repo} = MigrationRepo.start_link(pool_size: 2)

    restore_context = restore_context(names)

    Application.put_env(:singularity_runtime, :restore_task, %{
      context: restore_context,
      operation:
        {OracleRestoreOperation,
         %{
           snapshot:
             &destination_snapshot(
               &1,
               source.vault_id,
               names.storage_root,
               source.audit_event_ids
             )
         }}
    })

    result =
      run_task!("singularity.restore", [
        "--restore-oracle",
        "--passphrase-fd",
        Integer.to_string(descriptors.restore_passphrase.fd),
        "--password-fd",
        Integer.to_string(descriptors.new_password.fd),
        "--source",
        bundle_path
      ])

    snapshot = oracle_snapshot!(result, "singularity.restore")
    api_exports = verify_restored_note_api!(source, new_password)
    Map.put(snapshot, :note_exports, api_exports)
  end

  defp restore_v1_fixture!(names, descriptors, new_password) do
    v1_stage(:create_database)
    Application.put_env(:singularity_runtime, :maintenance_mode, true)
    stop_runtime_and_repositories()
    TestEnvironment.create!(names)
    v1_stage(:configure_restore)
    stop_runtime_repositories()
    Application.put_env(:singularity_runtime, :start_infrastructure, false)
    {:ok, _migration_repo} = MigrationRepo.start_link(pool_size: 2)

    Application.put_env(:singularity_runtime, :restore_task, %{
      context: restore_context(names),
      operation: {OracleRestoreOperation, %{snapshot: fn _manifest_id -> {:ok, %{v1: true}} end}}
    })

    v1_stage(:restore_fixture)

    backup_root = Application.fetch_env!(:singularity_storage, :backup_root)
    source_path = Path.join(backup_root, "logical-v1-restore-#{names.suffix}.backup")
    File.cp!(v1_fixture_path(), source_path)

    result =
      try do
        run_task!("singularity.restore", [
          "--restore-oracle",
          "--passphrase-fd",
          Integer.to_string(descriptors.v1_restore_passphrase.fd),
          "--password-fd",
          Integer.to_string(descriptors.v1_new_password.fd),
          "--source",
          source_path
        ])
      after
        File.rm(source_path)
      end

    %{v1: true} = oracle_snapshot!(result, "singularity.restore V1 fixture")
    v1_stage(:load_owner)
    login = restored_owner_login!()

    v1_stage(:start_runtime)
    stop_runtime_and_repositories()
    Application.put_env(:singularity_runtime, :maintenance_mode, false)
    configure_source_runtime!()
    Application.put_env(:singularity_runtime, :start_infrastructure, true)
    {:ok, _started} = Application.ensure_all_started(:singularity_runtime)

    v1_stage(:login)
    session = login_and_unlock!(%{login: login}, new_password) |> api_session()

    v1_stage(:create_note)

    created =
      api_note!(
        Api.create_note(
          session,
          note_create_attrs("V1 restored note", "# V1 restored exact bytes\n")
        )
      )

    {:ok, fetched} = Api.get_note(session, created.resource_id)
    true = fetched == created
    exported = api_export!(Api.export_note(session, created.resource_id))
    true = exported.markdown == "# V1 restored exact bytes\n"

    Process.delete({__MODULE__, :v1_stage})
    :ok
  rescue
    exception ->
      stage = Process.get({__MODULE__, :v1_stage}, :unknown)

      Mix.raise(
        "restore oracle could not verify the logical V1 destination " <>
          "stage=#{stage} exception=#{inspect(exception.__struct__)}"
      )
  end

  defp v1_stage(stage), do: Process.put({__MODULE__, :v1_stage}, stage)

  defp restored_owner_login! do
    {:ok, login} =
      MigrationRepo.transaction(fn ->
        SQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [], log: false)

        %{rows: [[login]]} =
          SQL.query!(
            MigrationRepo,
            """
            SELECT normalized_login
            FROM identity.credentials
            WHERE revoked_at IS NULL
            ORDER BY id
            LIMIT 1
            """,
            [],
            log: false
          )

        login
      end)

    login
  end

  defp v1_fixture_path do
    path =
      Path.expand(
        "../../../../singularity_storage/test/fixtures/backup/logical-v1-pre-notes.backup",
        __DIR__
      )

    if File.regular?(path), do: path, else: Mix.raise("logical V1 fixture is unavailable")
  end

  defp bootstrap_source!(names) do
    login = "restore-oracle-#{names.suffix}@example.test"
    password = secret("owner-password", names.suffix)
    Process.delete(@vault_key_process_key)

    random_bytes = fn size ->
      value = :crypto.strong_rand_bytes(size)

      if size == 32 and is_nil(Process.get(@vault_key_process_key)) do
        Process.put(@vault_key_process_key, value)
      end

      value
    end

    adapters = %{
      repository: IdentityRepository,
      repository_context: MigrationRepo,
      password_hasher: Argon2PasswordHasher,
      password_hasher_context: @password_params,
      key_deriver: Argon2KeyDeriver,
      key_wrapper: KeyWrapper,
      id_generator: &Ecto.UUID.generate/0,
      random_bytes: random_bytes,
      vault_kdf_params: @password_params,
      initial_capabilities: [
        "asset.read",
        "asset.write",
        "backup.create",
        "note.export",
        "note.read",
        "note.write",
        "vault.lock",
        "vault.unlock",
        "vault.password_change"
      ]
    }

    result =
      with_migration_owner(fn ->
        BootstrapOwner.run(adapters, %{
          display_name: "Restore Oracle Owner",
          login: login,
          password: password
        })
      end)

    vault_key = Process.delete(@vault_key_process_key)

    case {result, vault_key} do
      {{:ok, owner}, <<_::binary-size(32)>> = vault_key} ->
        {Map.put(owner, :login, login), password, vault_key}

      _failure ->
        Mix.raise("restore oracle could not bootstrap the source owner")
    end
  end

  defp configure_source_runtime! do
    Application.put_env(:singularity_runtime, :authorization_dependencies, %{
      store: IdentityRepository,
      custodian: KeyCustodian
    })

    Application.put_env(:singularity_runtime, :key_custodian, %{
      authorization: Singularity.Runtime.CustodyReader,
      backup_cipher: ChunkedAEAD,
      clock: Singularity.Runtime.CustodyReader,
      context: %{
        repo: Singularity.Storage.WorkerRepo,
        repository_adapter: Singularity.Storage.Postgres.CustodyRepository,
        key_wrapper: KeyWrapper,
        storage: Singularity.Runtime.StorageAdapter
      },
      idle_lock: Singularity.Runtime.LockVault,
      key_reader: Singularity.Runtime.CustodyReader,
      object_key_loader: Singularity.Runtime.CustodyReader,
      wake_waiting: Singularity.Runtime.JobDispatcher
    })
  end

  defp login_and_unlock!(owner, password) do
    login_adapters = %{
      pre_auth: PreAuth,
      pre_auth_context: PreAuthRepo,
      identity: IdentityRepository,
      identity_context: %{
        repo: RequestRepo,
        clock: fn -> DateTime.utc_now() end,
        session_ttl_seconds: 900
      },
      password_hasher: Argon2PasswordHasher,
      password_hasher_context: @password_params,
      audit_fingerprint_secret: :binary.copy(<<0xA7>>, 32),
      random_bytes: &:crypto.strong_rand_bytes/1
    }

    with {:ok, %{opaque_token: token}} <-
           Login.run(login_adapters, %{
             login: owner.login,
             password: password,
             source: "127.0.0.1",
             correlation_id: Ecto.UUID.generate()
           }),
         {:ok, session} <-
           ResolveSession.run(
             %{
               pre_auth: PreAuth,
               pre_auth_context: PreAuthRepo,
               custodian: KeyCustodian,
               custodian_context: KeyCustodian
             },
             token
           ),
         {:ok, unlocked} <-
           UnlockVault.run(unlock_runtime(), session, password, Ecto.UUID.generate()) do
      unlocked
    else
      _failure -> Mix.raise("restore oracle could not authenticate and unlock the source vault")
    end
  end

  defp seed_source_notes!(session) do
    runtime = note_runtime()
    note_seed_stage(:merged_create)

    merged_initial =
      api_note!(
        Singularity.Runtime.Notes.Create.run(
          runtime,
          session,
          note_create_attrs("Merged", "# Merged initial\n")
        )
      )

    note_seed_stage(:merged_save)

    merged_saved =
      api_save!(
        Singularity.Runtime.Notes.Save.run(runtime, session, merged_initial.resource_id, %{
          mutation_id: Ecto.UUID.generate(),
          base_version_id: merged_initial.resource_version_id,
          title: "Merged canonical",
          markdown: "# Merged canonical\n"
        })
      )

    note_seed_stage(:merged_conflict)

    merged_conflict =
      api_save!(
        Singularity.Runtime.Notes.Save.run(runtime, session, merged_initial.resource_id, %{
          mutation_id: Ecto.UUID.generate(),
          base_version_id: merged_initial.resource_version_id,
          title: "Merged competitor",
          markdown: "# Merged competitor\n"
        })
      )

    true = merged_conflict.outcome == :conflict

    note_seed_stage(:merged_merge)

    merged =
      api_save!(
        Singularity.Runtime.Notes.Merge.run(runtime, session, merged_initial.resource_id, %{
          mutation_id: Ecto.UUID.generate(),
          conflict_id: merged_conflict.conflict_id,
          expected_current_version_id: merged_saved.canonical.resource_version_id,
          competing_version_id: merged_conflict.submitted_version_id,
          title: "Merged final",
          markdown: "# Merged final\n"
        })
      )

    true = merged.outcome == :saved

    note_seed_stage(:conflicted_create)

    conflicted_initial =
      api_note!(
        Singularity.Runtime.Notes.Create.run(
          runtime,
          session,
          note_create_attrs("Conflicted", "# Conflict base\n")
        )
      )

    note_seed_stage(:conflicted_save)

    conflicted_saved =
      api_save!(
        Singularity.Runtime.Notes.Save.run(runtime, session, conflicted_initial.resource_id, %{
          mutation_id: Ecto.UUID.generate(),
          base_version_id: conflicted_initial.resource_version_id,
          title: "Conflict canonical",
          markdown: "# Conflict canonical\n"
        })
      )

    note_seed_stage(:conflicted_conflict)

    open_conflict =
      api_save!(
        Singularity.Runtime.Notes.Save.run(runtime, session, conflicted_initial.resource_id, %{
          mutation_id: Ecto.UUID.generate(),
          base_version_id: conflicted_initial.resource_version_id,
          title: "Conflict competitor",
          markdown: "# Conflict competitor\n"
        })
      )

    true = conflicted_saved.outcome == :saved
    true = open_conflict.outcome == :conflict

    note_seed_stage(:deleted_create)

    deleted =
      api_note!(
        Singularity.Runtime.Notes.Create.run(
          runtime,
          session,
          note_create_attrs("Deleted", "# Deleted bytes\n")
        )
      )

    note_seed_stage(:deleted_delete)

    {:ok, true} =
      Singularity.Runtime.Notes.Delete.run(runtime, session, deleted.resource_id, %{
        mutation_id: Ecto.UUID.generate(),
        expected_current_version_id: deleted.resource_version_id
      })

    note_seed_stage(:restored_create)

    restored_initial =
      api_note!(
        Singularity.Runtime.Notes.Create.run(
          runtime,
          session,
          note_create_attrs("Restored", "# Restored bytes\n")
        )
      )

    note_seed_stage(:restored_delete)

    {:ok, true} =
      Singularity.Runtime.Notes.Delete.run(runtime, session, restored_initial.resource_id, %{
        mutation_id: Ecto.UUID.generate(),
        expected_current_version_id: restored_initial.resource_version_id
      })

    note_seed_stage(:restored_restore)

    restored =
      api_note!(
        Singularity.Runtime.Notes.Restore.run(runtime, session, restored_initial.resource_id, %{
          mutation_id: Ecto.UUID.generate()
        })
      )

    live_resources = [
      merged.canonical.resource_id,
      open_conflict.canonical.resource_id,
      restored.resource_id
    ]

    note_seed_stage(:exports)

    exports =
      Map.new(live_resources, fn resource_id ->
        {resource_id,
         api_export!(Singularity.Runtime.Notes.Export.run(runtime, session, resource_id))}
      end)

    result = %{
      deleted_resource_id: deleted.resource_id,
      exports: exports,
      live_resource_ids: Enum.sort(live_resources)
    }

    Process.delete(@note_seed_stage_key)
    result
  end

  defp note_seed_stage(stage) when is_atom(stage), do: Process.put(@note_seed_stage_key, stage)

  defp note_create_attrs(title, markdown),
    do: %{mutation_id: Ecto.UUID.generate(), title: title, markdown: markdown}

  defp api_note!({:ok, %Singularity.Runtime.DTO.Note{} = note}), do: note
  defp api_note!({:error, code}) when is_atom(code), do: note_seed_failure!(:mutation, code)

  defp api_note!({:error, %Singularity.Core.Error{code: code}}),
    do: note_seed_failure!(:mutation, code)

  defp api_note!({:ok, %{__struct__: module}}) when is_atom(module),
    do: note_seed_failure!(:unexpected_success_struct, module)

  defp api_note!(_result), do: note_seed_failure!(:mutation)

  defp api_save!({:ok, %Singularity.Runtime.DTO.NoteSaveResult{} = result}), do: result
  defp api_save!({:error, code}) when is_atom(code), do: note_seed_failure!(:save, code)
  defp api_save!(_result), do: note_seed_failure!(:save)

  defp api_export!({:ok, %Singularity.Runtime.DTO.NoteExport{} = export}),
    do: Map.from_struct(export)

  defp api_export!({:error, code}) when is_atom(code), do: note_seed_failure!(:export, code)
  defp api_export!(_result), do: note_seed_failure!(:export)

  defp note_seed_failure!(operation, code \\ nil) do
    stage = Process.get(@note_seed_stage_key, :unknown)
    suffix = if is_atom(code), do: " code=#{code}", else: ""
    Mix.raise("restore oracle note #{operation} failed stage=#{stage}#{suffix}")
  end

  defp drain_note_projection_jobs! do
    with {:ok, %{failed: 0}} <- Singularity.Runtime.OutboxDispatcher.dispatch_once(%{}),
         %{failure: 0} <- Oban.drain_queue(Singularity.Oban, queue: :note_projection) do
      :ok
    else
      _failure -> Mix.raise("restore oracle could not drain note projection work")
    end
  end

  defp note_runtime do
    Map.merge(operation_runtime(), %{
      audit: Singularity.Storage.Postgres.AuditSink,
      fingerprint_secret:
        Application.fetch_env!(:singularity_runtime, :mutation_fingerprint_secret),
      mutation_fingerprint: Singularity.Runtime.Notes.MutationFingerprint,
      note_repository: Singularity.Storage.Postgres.NoteRepository,
      notes: Singularity.Domains.Notes
    })
  end

  defp verify_restored_note_api!(source, new_password) do
    stop_runtime_and_repositories()
    Application.put_env(:singularity_runtime, :maintenance_mode, false)
    configure_source_runtime!()
    Application.put_env(:singularity_runtime, :start_infrastructure, true)
    {:ok, _started} = Application.ensure_all_started(:singularity_runtime)

    session = login_and_unlock!(%{login: source.owner_login}, new_password) |> api_session()

    exports =
      Map.new(source.note_live_resource_ids, fn resource_id ->
        {:ok, note} = Api.get_note(session, resource_id)
        true = note.resource_id == resource_id
        {resource_id, api_export!(Api.export_note(session, resource_id))}
      end)

    true = exports == source.note_exports
    {:error, :not_found} = Api.get_note(session, source.note_deleted_resource_id)
    {:error, :not_found} = Api.export_note(session, source.note_deleted_resource_id)

    created =
      api_note!(
        Api.create_note(session, note_create_attrs("Post restore", "# Post restore exact\n"))
      )

    {:ok, fetched} = Api.get_note(session, created.resource_id)
    true = fetched == created
    post_restore_export = api_export!(Api.export_note(session, created.resource_id))
    true = post_restore_export.markdown == "# Post restore exact\n"

    exports
  rescue
    _exception -> Mix.raise("restore oracle could not verify restored note API access")
  end

  defp api_session(%Singularity.Runtime.SessionContext{} = session) do
    session
    |> Map.from_struct()
    |> then(&struct!(Singularity.Runtime.DTO.Session, &1))
  end

  defp unlock_runtime do
    Map.merge(operation_runtime(), %{
      custodian: {KeyCustodian, KeyCustodian},
      key_deriver: Argon2KeyDeriver,
      key_wrapper: KeyWrapper,
      vaults: IdentityRepository
    })
  end

  defp backup_runtime do
    backup_root = Application.fetch_env!(:singularity_storage, :backup_root)
    local_destination = {LocalDestination, %{backup_root: backup_root}}

    Map.merge(operation_runtime(), %{
      backup_kdf_domain: @backup_kdf_domain,
      backup_kdf_parameters: @backup_kdf_parameters,
      backup_key_deriver: OracleBackupKeyDeriver,
      backup_key_lease: BackupKeyLease,
      backup_key_wrapper: BackupRecoveryWrapper,
      backups: BackupRepository,
      custodian: {KeyCustodian, KeyCustodian},
      destination: local_destination,
      ids: OracleIds,
      jobs: OracleJobs,
      operation_scope: OperationScope,
      partial_bundles: {OraclePartialBundles, %{backup_root: backup_root}},
      random_bytes: &:crypto.strong_rand_bytes/1
    })
  end

  defp operation_runtime do
    {:ok, authorization} =
      AuthorizationDependencies.new(%{
        store: IdentityRepository,
        custodian: KeyCustodian
      })

    %{
      authorization: authorization,
      authorization_lock: AuthorizationLock,
      request_repo: RequestRepo,
      scoped_repo: ScopedRepo,
      vault_lock: VaultLock
    }
  end

  defp with_migration_owner(callback) do
    {:ok, repo} = MigrationRepo.start_link(pool_size: 2)

    try do
      MigrationRepo.transaction(fn ->
        SQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [], log: false)
        callback.()
      end)
      |> case do
        {:ok, result} -> result
        {:error, error} -> {:error, error}
      end
    after
      if Process.alive?(repo), do: Supervisor.stop(repo)
    end
  end

  defp restore_context(names) do
    backup_root = Application.fetch_env!(:singularity_storage, :backup_root)
    destination_context = %{backup_root: backup_root, storage_root: names.storage_root}
    object_storage = Singularity.Runtime.StorageAdapter.configured()

    authenticator_context = %{
      backup_cipher: ChunkedAEAD,
      backup_key_deriver: OracleBackupKeyDeriver,
      backup_key_lease: BackupKeyLease,
      bundle_reader: BundleReader,
      destination: {LocalDestination, %{backup_root: backup_root}},
      logical_verifier: LogicalBundleVerifier,
      recovered_vault_key: RecoveredVaultKey,
      restore_crypto_adapter: BackupKeyLease.StorageAdapter,
      restore_key_ttl_ms: :timer.minutes(5)
    }

    restorer_context = %{
      integrity_issuer: RestoreIntegrityLease,
      integrity_ttl_ms: :timer.minutes(5),
      key_deriver: Argon2KeyDeriver,
      key_wrapper: KeyWrapper,
      migration_repo: MigrationRepo,
      object_storage: object_storage,
      password_hasher: Argon2PasswordHasher,
      password_hasher_context: @password_params,
      random_bytes: &:crypto.strong_rand_bytes/1,
      recovered_vault_key: RecoveredVaultKey,
      vault_kdf_params: @password_params
    }

    integrity_context = %{
      audit: {StorageIntegrityAudit, MigrationRepo},
      ciphertext_auditor: StorageIntegrityAudit,
      object_storage: object_storage,
      restore_integrity_lease: RestoreIntegrityLease,
      search_rebuilder: {StorageIntegrityAudit, MigrationRepo}
    }

    %{
      authenticator: {RestoreAuthenticator, authenticator_context},
      destination: {OracleDestination, destination_context},
      integrity: {IntegrityAudit, integrity_context},
      maintenance_mode: {OracleMaintenanceMode, true},
      migration_repo: MigrationRepo,
      reconciler: {Reconciler, MigrationRepo},
      restorer: {Restorer, restorer_context}
    }
  end

  defp oracle_secrets(source, destination, capture_path) do
    passphrase =
      if is_binary(capture_path),
        do: @capture_passphrase,
        else: secret("backup-passphrase", source.suffix <> destination.suffix)

    %{
      backup_passphrase: passphrase,
      new_password: secret("restored-owner-password", destination.suffix),
      restore_passphrase: passphrase,
      v1_new_password: secret("v1-restored-owner-password", destination.suffix),
      v1_restore_passphrase: @capture_passphrase
    }
  end

  defp capture_path! do
    case System.get_env(@capture_env) do
      nil ->
        nil

      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          Mix.raise("#{@capture_env} must name a non-empty destination path")
        end

        path = Path.expand(trimmed)

        _loaded = Code.ensure_loaded(LogicalRecordCodec)

        version =
          if function_exported?(LogicalRecordCodec, :default_version, 0),
            do: apply(LogicalRecordCodec, :default_version, []),
            else: LogicalSchema.version()

        if version != 1 do
          Mix.raise("refusing logical V1 capture because codec default is #{version}")
        end

        if File.exists?(path) do
          Mix.raise("refusing to overwrite logical V1 capture at #{path}")
        end

        path
    end
  end

  defp capture_bundle!(_bundle_path, nil), do: :ok

  defp capture_bundle!(bundle_path, capture_path) do
    File.mkdir_p!(Path.dirname(capture_path))
    File.cp!(bundle_path, capture_path)

    sha256 =
      capture_path
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Mix.shell().info("logical_v1_capture=#{capture_path} sha256=#{sha256}")
    :ok
  end

  defp secret(label, seed) do
    :crypto.hash(:sha256, ["singularity-restore-oracle-v1\0", label, "\0", seed])
    |> Base.url_encode64(padding: false)
  end

  defp with_secret_descriptors(bundle_path, secrets, callback) do
    prefix = bundle_path <> ".secret."

    descriptors =
      Map.new(secrets, fn {purpose, secret} ->
        path = prefix <> Atom.to_string(purpose)
        File.write!(path, secret <> "\n", [:binary])
        File.chmod!(path, 0o600)
        device = File.open!(path, [:read, :binary])
        {purpose, %{device: device, fd: numeric_descriptor_for!(path), path: path}}
      end)

    try do
      callback.(descriptors)
    after
      Enum.each(descriptors, fn {_purpose, descriptor} ->
        File.close(descriptor.device)
        File.rm(descriptor.path)
      end)
    end
  end

  defp numeric_descriptor_for!(path) do
    expanded = Path.expand(path)

    Path.wildcard("/proc/self/fd/*")
    |> Enum.find_value(fn descriptor_path ->
      case File.read_link(descriptor_path) do
        {:ok, ^expanded} -> descriptor_path |> Path.basename() |> String.to_integer()
        _other -> nil
      end
    end)
    |> case do
      nil -> Mix.raise("restore oracle could not obtain an inherited secret descriptor")
      descriptor -> descriptor
    end
  end

  defp source_snapshot(%{id: manifest_id, vault_id: vault_id}, storage_root, note_oracle) do
    snapshot =
      with_migration_owner(fn ->
        snapshot_data(manifest_id, vault_id, storage_root, MapSet.new())
      end)

    {:ok,
     Map.merge(snapshot, %{
       note_deleted_resource_id: note_oracle.deleted_resource_id,
       note_exports: note_oracle.exports,
       note_live_resource_ids: note_oracle.live_resource_ids
     })}
  rescue
    _exception -> {:error, Singularity.Core.Error.new(:storage_unavailable, retryable?: true)}
  end

  defp destination_snapshot(manifest_id, vault_id, storage_root, source_audit_ids) do
    case MigrationRepo.transaction(fn ->
           SQL.query!(MigrationRepo, "SET LOCAL ROLE singularity_table_owner", [], log: false)

           snapshot_data(
             manifest_id,
             vault_id,
             storage_root,
             MapSet.new(source_audit_ids)
           )
         end) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, _reason} ->
        {:error, Singularity.Core.Error.new(:storage_unavailable, retryable?: true)}
    end
  rescue
    _exception -> {:error, Singularity.Core.Error.new(:storage_unavailable, retryable?: true)}
  end

  defp snapshot_data(manifest_id, vault_id, _storage_root, source_audit_ids) do
    %{rows: [[resources, versions, assets, objects, metadata, tombstones]]} =
      SQL.query!(
        MigrationRepo,
        """
        SELECT
          (SELECT count(*) FROM content.resources WHERE deleted_at IS NULL),
          (SELECT count(*) FROM content.resource_versions),
          (SELECT count(*) FROM content.assets WHERE state NOT IN ('pending_delete', 'deleted')),
          (SELECT count(*) FROM content.asset_objects WHERE lifecycle = 'available'),
          (SELECT count(*) FROM content.asset_metadata),
          (SELECT count(*) FROM content.tombstones)
        """,
        [],
        log: false
      )

    %{rows: note_resource_rows} =
      SQL.query!(
        MigrationRepo,
        """
        SELECT
          id::text,
          current_version_id::text,
          classification,
          title,
          deleted_at,
          metadata
        FROM content.resources
        WHERE vault_id = $1
          AND kind = 'note'
        ORDER BY id
        """,
        [Ecto.UUID.dump!(vault_id)],
        log: false
      )

    %{rows: note_version_rows} =
      SQL.query!(
        MigrationRepo,
        """
        SELECT
          note.resource_version_id::text,
          note.resource_id::text,
          version.revision,
          note.classification,
          note.title,
          note.markdown,
          note.created_by_principal_id::text,
          note.parent_version_id::text,
          note.merge_parent_version_id::text,
          note.inserted_at
        FROM content.note_versions AS note
        JOIN content.resource_versions AS version
          ON version.id = note.resource_version_id
         AND version.resource_id = note.resource_id
         AND version.vault_id = note.vault_id
         AND version.classification = note.classification
        WHERE note.vault_id = $1
        ORDER BY note.resource_version_id
        """,
        [Ecto.UUID.dump!(vault_id)],
        log: false
      )

    %{rows: note_conflict_rows} =
      SQL.query!(
        MigrationRepo,
        """
        SELECT
          id::text,
          resource_id::text,
          classification,
          base_version_id::text,
          canonical_version_id::text,
          competing_version_id::text,
          state,
          resolution_version_id::text,
          created_at,
          resolved_at
        FROM content.note_conflicts
        WHERE vault_id = $1
        ORDER BY id
        """,
        [Ecto.UUID.dump!(vault_id)],
        log: false
      )

    %{rows: note_search_rows} =
      SQL.query!(
        MigrationRepo,
        """
        SELECT
          resource_id::text,
          resource_version_id::text,
          classification,
          title,
          markdown,
          head_inserted_at,
          search_vector::text
        FROM content.note_search_documents
        WHERE vault_id = $1
        ORDER BY resource_id
        """,
        [Ecto.UUID.dump!(vault_id)],
        log: false
      )

    %{rows: note_event_rows} =
      SQL.query!(
        MigrationRepo,
        """
        SELECT
          event_type,
          payload ->> 'resource_id',
          idempotency_key,
          classification,
          expected_entity_revision
        FROM core.outbox_events
        WHERE vault_id = $1
          AND event_type IN (
            'note.current_changed',
            'note.conflict_created',
            'note.conflict_resolved',
            'note.deleted',
            'note.restored'
          )
          AND payload ? 'resource_id'
          AND payload - 'resource_id' = '{}'::jsonb
        ORDER BY sequence, id
        """,
        [Ecto.UUID.dump!(vault_id)],
        log: false
      )

    %{rows: audit_rows} =
      SQL.query!(
        MigrationRepo,
        """
        SELECT id, operation
        FROM audit.events
        WHERE vault_id = $1
        ORDER BY id
        """,
        [Ecto.UUID.dump!(vault_id)],
        log: false
      )

    audit =
      Enum.map(audit_rows, fn [id, operation] ->
        {Ecto.UUID.load!(id), operation}
      end)

    %{rows: [[manifest_object_count]]} =
      SQL.query!(
        MigrationRepo,
        "SELECT count(*) FROM audit.backup_manifest_objects WHERE manifest_id = $1",
        [Ecto.UUID.dump!(manifest_id)],
        log: false
      )

    %{rows: ciphertext_rows} =
      SQL.query!(
        MigrationRepo,
        """
        SELECT id, encode(ciphertext_hash, 'hex')
        FROM content.asset_objects
        WHERE lifecycle = 'available'
        ORDER BY id
        """,
        [],
        log: false
      )

    %{rows: search_rows} =
      SQL.query!(
        MigrationRepo,
        """
        SELECT
          asset_id, resource_version_id, vault_id, classification, state,
          detected_media_type, resource_title, original_filename
        FROM content.asset_search_documents
        ORDER BY asset_id
        """,
        [],
        log: false
      )

    %{rows: [[unreconciled_jobs]]} =
      SQL.query!(
        MigrationRepo,
        """
        SELECT count(*)
        FROM core.outbox_events
        WHERE retired_at IS NULL
          AND event_type IN (
            'asset.finalize_requested',
            'asset.verify_requested',
            'asset.metadata_requested',
            'asset.cleanup_requested',
            'object.cleanup_requested',
            'backup.requested'
          )
        """,
        [],
        log: false
      )

    %{
      counts: %{
        assets: assets,
        deleted_notes: Enum.count(note_resource_rows, &(Enum.at(&1, 4) != nil)),
        metadata: metadata,
        note_conflicts: length(note_conflict_rows),
        note_versions: length(note_version_rows),
        notes: length(note_resource_rows),
        objects: objects,
        resources: resources,
        tombstones: tombstones,
        versions: versions
      },
      vault_id: vault_id,
      audit_count: length(audit),
      audit_event_ids: Enum.map(audit, &elem(&1, 0)),
      added_audit_operations:
        audit
        |> Enum.reject(fn {id, _operation} -> MapSet.member?(source_audit_ids, id) end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.sort(),
      manifest_object_count: manifest_object_count,
      live_object_count: objects,
      ciphertext_hashes:
        Enum.map(ciphertext_rows, fn [id, hash] -> {Ecto.UUID.load!(id), hash} end),
      plaintext_hashes: [],
      note_conflicts: note_conflict_rows,
      note_deleted_resource_ids:
        note_resource_rows
        |> Enum.filter(&(Enum.at(&1, 4) != nil))
        |> Enum.map(&hd/1),
      note_events: note_event_rows,
      note_live_resource_ids:
        note_resource_rows
        |> Enum.filter(&is_nil(Enum.at(&1, 4)))
        |> Enum.map(&hd/1),
      note_resources: note_resource_rows,
      note_search_results: note_search_rows,
      note_versions: note_version_rows,
      unreconciled_jobs: unreconciled_jobs,
      search_results:
        Enum.map(search_rows, fn row ->
          Enum.map(row, fn
            <<_::binary-size(16)>> = uuid -> Ecto.UUID.load!(uuid)
            value -> value
          end)
        end)
    }
  end

  defp run_task!(task, args) do
    Mix.Task.reenable(task)
    Mix.Task.run(task, args)
  end

  defp oracle_snapshot!(%{oracle_snapshot: snapshot}, _task) when is_map(snapshot),
    do: snapshot

  defp oracle_snapshot!(_result, task) do
    Mix.raise("#{task} did not return its restore-oracle snapshot")
  end

  defp assert_restored!(source, destination) do
    assert source.counts.notes == 4
    assert source.counts.note_versions == 9
    assert source.counts.note_conflicts == 2
    assert source.counts.deleted_notes == 1
    assert length(source.note_live_resource_ids) == 3
    assert source.note_deleted_resource_ids == [source.note_deleted_resource_id]

    assert destination.counts == source.counts
    assert destination.audit_count == source.audit_count + 3

    assert destination.added_audit_operations ==
             ~w[
               backup.restore_completed
               credential.rewrapped_after_restore
               integrity.audit_completed
             ]

    assert destination.manifest_object_count == source.live_object_count
    assert destination.ciphertext_hashes == source.ciphertext_hashes
    assert destination.plaintext_hashes == source.plaintext_hashes
    assert destination.note_resources == source.note_resources
    assert destination.note_versions == source.note_versions
    assert destination.note_conflicts == source.note_conflicts
    assert destination.note_events == source.note_events
    assert destination.note_search_results == source.note_search_results
    assert destination.note_live_resource_ids == source.note_live_resource_ids
    assert destination.note_deleted_resource_ids == source.note_deleted_resource_ids
    assert destination.note_exports == source.note_exports
    assert destination.unreconciled_jobs == 0
    assert destination.search_results == source.search_results
  end

  defp assert_required_tasks! do
    missing = Enum.filter(@required_tasks, &is_nil(Mix.Task.get(&1)))

    if missing != [] do
      Mix.raise("restore oracle unavailable; missing Mix tasks: #{Enum.join(missing, ", ")}")
    end
  end

  defp assert_distinct!(source, destination) do
    if source.database == destination.database or
         Path.expand(source.storage_root) == Path.expand(destination.storage_root) do
      Mix.raise("restore oracle source and destination must be distinct")
    end
  end

  defp print_names(source, destination) do
    Mix.shell().info(
      "source_database=#{source.database} source_storage_root=#{source.storage_root}"
    )

    Mix.shell().info(
      "destination_database=#{destination.database} " <>
        "destination_storage_root=#{destination.storage_root}"
    )
  end

  defp print_v1_name(destination) do
    Mix.shell().info(
      "v1_destination_database=#{destination.database} " <>
        "v1_destination_storage_root=#{destination.storage_root}"
    )
  end

  defp bundle_path(source, destination) do
    backup_root = Application.fetch_env!(:singularity_storage, :backup_root)
    File.mkdir_p!(backup_root)

    Path.join(
      backup_root,
      "singularity-restore-#{source.suffix}-#{destination.suffix}.bundle"
    )
  end

  defp stop_runtime_and_repositories do
    Application.stop(:singularity_runtime)
    stop_runtime_repositories()
  end

  defp stop_runtime_repositories do
    for repo <- [
          Singularity.Storage.MigrationRepo,
          Singularity.Storage.RequestRepo,
          Singularity.Storage.PreAuthRepo,
          Singularity.Storage.DispatcherRepo,
          Singularity.Storage.WorkerRepo
        ] do
      case Process.whereis(repo) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end
    end
  end

  defp cleanup!(source, destination, v1_destination, bundle_path, previous_env) do
    try do
      try do
        stop_runtime_and_repositories()
      after
        try do
          restore_environment(previous_env)
        after
          File.rm(bundle_path)
        end
      end
    after
      try do
        TestEnvironment.drop!(v1_destination)
      after
        try do
          TestEnvironment.drop!(destination)
        after
          TestEnvironment.drop!(source)
        end
      end
    end
  end

  defp snapshot_environment do
    runtime = [
      {:singularity_runtime, :start_infrastructure},
      {:singularity_runtime, :maintenance_mode},
      {:singularity_runtime, :authorization_dependencies},
      {:singularity_runtime, :key_custodian},
      {:singularity_runtime, :backup_task},
      {:singularity_runtime, :restore_task}
    ]

    storage = Enum.map(@storage_env_keys, &{:singularity_storage, &1})

    Enum.map(runtime ++ storage, fn {app, key} ->
      {app, key, Application.fetch_env(app, key)}
    end)
  end

  defp restore_environment(snapshot) do
    Enum.each(snapshot, fn
      {app, key, {:ok, value}} -> Application.put_env(app, key, value)
      {app, key, :error} -> Application.delete_env(app, key)
    end)
  end

  defp assert_test_environment! do
    if Mix.env() != :test do
      Mix.raise("singularity.test.restore requires MIX_ENV=test")
    end
  end
end
