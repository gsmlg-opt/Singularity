import Config

config :singularity_web, Singularity.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base:
    "dev-secret-key-base-for-singularity-web-vault-shell-000000000000000000000000000000",
  server: true

config :singularity_storage,
  backup_root:
    System.get_env(
      "SINGULARITY_BACKUP_ROOT",
      Path.expand("../var/backups", __DIR__)
    ),
  storage_root:
    System.get_env(
      "SINGULARITY_STORAGE_ROOT",
      Path.expand("../var/storage", __DIR__)
    )

config :singularity_storage, Singularity.Storage.MigrationRepo,
  url:
    System.get_env(
      "SINGULARITY_MIGRATION_DATABASE_URL",
      "postgresql://singularity_migration@localhost/singularity_dev"
    )

config :singularity_storage, Singularity.Storage.RequestRepo,
  url:
    System.get_env(
      "SINGULARITY_DATABASE_URL",
      "postgresql://singularity_web@localhost/singularity_dev"
    )

config :singularity_storage, Singularity.Storage.PreAuthRepo,
  url:
    System.get_env(
      "SINGULARITY_PRE_AUTH_DATABASE_URL",
      "postgresql://singularity_pre_auth@localhost/singularity_dev"
    )

config :singularity_storage, Singularity.Storage.DispatcherRepo,
  url:
    System.get_env(
      "SINGULARITY_DISPATCHER_DATABASE_URL",
      "postgresql://singularity_dispatcher@localhost/singularity_dev"
    )

config :singularity_storage, Singularity.Storage.WorkerRepo,
  url:
    System.get_env(
      "SINGULARITY_WORKER_DATABASE_URL",
      "postgresql://singularity_worker@localhost/singularity_dev"
    )
