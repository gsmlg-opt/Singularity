import Config

if config_env() == :prod do
  host = System.get_env("PHX_HOST", "localhost")
  port = String.to_integer(System.get_env("PORT", "4000"))

  config :singularity_web, Singularity.Web.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    server: true

  Application.fetch_env!(:singularity_storage, :job_handler)

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

  backup_root = System.fetch_env!("SINGULARITY_BACKUP_ROOT")
  storage_root = System.fetch_env!("SINGULARITY_STORAGE_ROOT")

  audit_fingerprint_secret =
    case System.fetch_env!("SINGULARITY_AUDIT_FINGERPRINT_SECRET")
         |> Base.decode64() do
      {:ok, secret} when byte_size(secret) >= 32 ->
        secret

      _invalid ->
        raise ArgumentError,
              "SINGULARITY_AUDIT_FINGERPRINT_SECRET must decode to at least 32 bytes"
    end

  mutation_fingerprint_secret =
    case System.fetch_env!("SINGULARITY_MUTATION_FINGERPRINT_SECRET")
         |> Base.decode64() do
      {:ok, <<_::binary-size(32)>> = secret} ->
        secret

      _invalid ->
        raise ArgumentError,
              "SINGULARITY_MUTATION_FINGERPRINT_SECRET must decode to exactly 32 bytes"
    end

  config :singularity_runtime,
    audit_fingerprint_secret: audit_fingerprint_secret,
    mutation_fingerprint_secret: mutation_fingerprint_secret,
    max_concurrent_uploads: max_concurrent_uploads

  config :singularity_storage,
    backup_root: backup_root,
    storage_root: storage_root

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
