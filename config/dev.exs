import Config

config :singularity_storage,
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
      "postgresql://singularity_request@localhost/singularity_dev"
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
