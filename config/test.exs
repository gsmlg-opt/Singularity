import Config

config :duskmoon_bundler, :singularity_web, server: [vendor_prebundle: false]

browser_test_run? = System.get_env("SINGULARITY_TEST_RUN_ID") != nil

config :singularity_web, Singularity.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  code_reloader: not browser_test_run?,
  secret_key_base:
    "test-secret-key-base-for-singularity-web-vault-shell-00000000000000000000000000000",
  server: false

config :logger, level: :warning

test_run_id =
  System.get_env("SINGULARITY_TEST_RUN_ID", "default")
  |> String.replace(~r/[^[:alnum:]_]/u, "_")

test_database_url = fn role, database ->
  "postgresql://#{role}@127.0.0.1:1/#{database}_#{test_run_id}"
end

config :singularity_storage,
  backup_root: Path.join([System.tmp_dir!(), "singularity-backups", "test", test_run_id]),
  storage_root: Path.join([System.tmp_dir!(), "singularity", "test", test_run_id])

config :singularity_runtime,
  start_infrastructure: false,
  audit_fingerprint_secret: :binary.copy(<<0xA7>>, 32),
  authorization_dependencies: %{
    store: Fake.Authorization,
    custodian: Singularity.Runtime.KeyCustodian
  },
  key_custodian: %{
    authorization: Fake.Authorization,
    backup_cipher: Singularity.Storage.Crypto.ChunkedAEAD,
    backup_recovery_wrapper: Singularity.Storage.Crypto.BackupRecoveryWrapper,
    clock: Fake.Clock,
    context: %{},
    idle_lock: fn _session -> :ok end,
    key_reader: Fake.KeyReader,
    object_key_loader: Fake.KeyReader
  },
  oban_options: [testing: :manual, queues: false, plugins: false],
  outbox_dispatcher_options: [interval_ms: 3_600_000]

config :singularity_storage, Singularity.Storage.MigrationRepo,
  url:
    System.get_env(
      "SINGULARITY_MIGRATION_DATABASE_URL",
      test_database_url.("singularity_migration", "singularity_migration_test")
    )

config :singularity_storage, Singularity.Storage.RequestRepo,
  url:
    System.get_env(
      "SINGULARITY_DATABASE_URL",
      test_database_url.("singularity_web", "singularity_request_test")
    )

config :singularity_storage, Singularity.Storage.PreAuthRepo,
  url:
    System.get_env(
      "SINGULARITY_PRE_AUTH_DATABASE_URL",
      test_database_url.("singularity_pre_auth", "singularity_pre_auth_test")
    )

config :singularity_storage, Singularity.Storage.DispatcherRepo,
  url:
    System.get_env(
      "SINGULARITY_DISPATCHER_DATABASE_URL",
      test_database_url.("singularity_dispatcher", "singularity_dispatcher_test")
    )

config :singularity_storage, Singularity.Storage.WorkerRepo,
  url:
    System.get_env(
      "SINGULARITY_WORKER_DATABASE_URL",
      test_database_url.("singularity_worker", "singularity_worker_test")
    )
