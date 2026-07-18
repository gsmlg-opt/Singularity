import Config

if config_env() == :prod do
  request_repo_pool_size =
    Application.fetch_env!(:singularity_storage, Singularity.Storage.RequestRepo)
    |> Keyword.fetch!(:pool_size)

  max_concurrent_uploads =
    case System.get_env("SINGULARITY_MAX_CONCURRENT_UPLOADS") do
      nil ->
        2

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 and parsed < request_repo_pool_size ->
            parsed

          _other ->
            raise ArgumentError,
                  "SINGULARITY_MAX_CONCURRENT_UPLOADS must be a positive integer " <>
                    "below RequestRepo pool size #{request_repo_pool_size}"
        end
    end

  config :singularity_runtime,
    max_concurrent_uploads: max_concurrent_uploads

  config :singularity_storage,
    storage_root: System.fetch_env!("SINGULARITY_STORAGE_ROOT")

  config :singularity_storage, Singularity.Storage.MigrationRepo,
    url: System.fetch_env!("SINGULARITY_MIGRATION_DATABASE_URL")

  config :singularity_storage, Singularity.Storage.RequestRepo,
    url: System.fetch_env!("SINGULARITY_DATABASE_URL")

  config :singularity_storage, Singularity.Storage.PreAuthRepo,
    url: System.fetch_env!("SINGULARITY_PRE_AUTH_DATABASE_URL")

  config :singularity_storage, Singularity.Storage.DispatcherRepo,
    url: System.fetch_env!("SINGULARITY_DISPATCHER_DATABASE_URL")

  config :singularity_storage, Singularity.Storage.WorkerRepo,
    url: System.fetch_env!("SINGULARITY_WORKER_DATABASE_URL")
end
