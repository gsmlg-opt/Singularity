# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

argon2_params = %{
  version: 1,
  t_cost: 3,
  m_cost: 16,
  parallelism: 1
}

config :phoenix, :json_library, JSON
config :logger_json, :encoder, JSON
config :postgrex, :json_library, JSON

config :duskmoon_bundler,
  root: "apps/singularity_web/assets",
  sources: ["**/*.{js,ts,jsx,tsx}"]

config :duskmoon_bundler, :singularity_web,
  root: "apps/singularity_web/assets",
  entry: "apps/singularity_web/assets/js/app.ts",
  outdir: "apps/singularity_web/priv/static/assets",
  resolve_dirs: ["apps", "deps"],
  import_source: "react",
  tailwind: [
    css: "apps/singularity_web/assets/css/app.css",
    sources: [
      %{base: "apps/singularity_web/lib", pattern: "**/*.{ex,exs,heex}"},
      %{base: "apps/singularity_web/assets", pattern: "**/*.{css,js,ts,jsx,tsx}"}
    ]
  ],
  server: [
    watch_dirs: ["apps/singularity_web/lib", "apps/singularity_web/assets"]
  ]

config :duskmoon_bundler_runtime, :singularity_web, outdir: "priv/static/assets"

config :singularity_web,
  ecto_repos: [],
  generators: [context_app: false]

config :singularity_web, Singularity.Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [
      html: Singularity.Web.ErrorHTML,
      json: Singularity.Web.ErrorJSON
    ],
    layout: false
  ],
  pubsub_server: Singularity.Web.PubSub,
  live_view: [signing_salt: "singularity-live"]

config :singularity_web, :runtime_api, Singularity.Runtime.Api

config :phoenix, :filter_parameters, [
  "password",
  "passphrase",
  "token",
  "csrf",
  "csrf_token",
  "upload_token",
  "x-csrf-token",
  "x-upload-token"
]

config :logger, :default_handler,
  formatter:
    {LoggerJSON.Formatters.Basic,
     metadata: [
       :correlation_id,
       :principal_id,
       :vault_id,
       :resource_id,
       :asset_id,
       :outbox_id,
       :job_id,
       :operation,
       :result
     ],
     redactors: [{Singularity.Runtime.Observability.Redactor, []}]}

config :singularity_runtime,
  max_upload_bytes: 536_870_912,
  max_concurrent_uploads: 2,
  password_hash_params: argon2_params,
  vault_kdf_params: argon2_params,
  vault_idle_timeout_ms: :timer.minutes(15),
  start_infrastructure: true,
  authorization_dependencies: %{
    store: Singularity.Storage.Postgres.IdentityRepository,
    custodian: Singularity.Runtime.KeyCustodian
  },
  key_custodian: %{
    authorization: Singularity.Runtime.CustodyReader,
    backup_cipher: Singularity.Storage.Crypto.ChunkedAEAD,
    backup_recovery_wrapper: Singularity.Storage.Crypto.BackupRecoveryWrapper,
    clock: Singularity.Runtime.CustodyReader,
    context: %{
      repo: Singularity.Storage.WorkerRepo,
      repository_adapter: Singularity.Storage.Postgres.CustodyRepository,
      key_wrapper: Singularity.Storage.Crypto.KeyWrapper,
      storage: Singularity.Runtime.StorageAdapter
    },
    idle_lock: Singularity.Runtime.LockVault,
    key_reader: Singularity.Runtime.CustodyReader,
    object_key_loader: Singularity.Runtime.CustodyReader,
    wake_waiting: Singularity.Runtime.JobDispatcher
  },
  bootstrap_owner: %{
    repository: Singularity.Storage.Postgres.IdentityRepository,
    repository_context: Singularity.Storage.MigrationRepo,
    password_hasher: Singularity.Storage.Crypto.Argon2PasswordHasher,
    password_hasher_context: argon2_params,
    key_deriver: Singularity.Storage.Crypto.Argon2KeyDeriver,
    key_wrapper: Singularity.Storage.Crypto.KeyWrapper,
    id_generator: &Ecto.UUID.generate/0,
    random_bytes: &:crypto.strong_rand_bytes/1,
    vault_kdf_params: argon2_params
  }

config :singularity_storage,
  job_handler: Singularity.Runtime.JobDispatcher

config :singularity_storage, Singularity.Storage.MigrationRepo, log: false

config :singularity_storage, Singularity.Storage.RequestRepo,
  pool_size: 10,
  log: false

config :singularity_storage, Singularity.Storage.PreAuthRepo, log: false
config :singularity_storage, Singularity.Storage.DispatcherRepo, log: false
config :singularity_storage, Singularity.Storage.WorkerRepo, log: false

config :singularity_storage, Oban,
  name: Singularity.Oban,
  repo: Singularity.Storage.WorkerRepo,
  prefix: "jobs",
  plugins: [Oban.Plugins.Lifeline],
  queues: [
    asset_finalize: 2,
    asset_verify: 2,
    asset_metadata: 2,
    asset_cleanup: 1,
    object_cleanup: 1,
    backup: 1,
    maintenance: 1
  ]

if config_env() in [:dev, :test] do
  import_config "#{config_env()}.exs"
end
