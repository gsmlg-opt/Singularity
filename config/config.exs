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

config :phoenix, :json_library, JSON
config :logger_json, :encoder, JSON
config :postgrex, :json_library, JSON

config :singularity_runtime,
  max_upload_bytes: 536_870_912,
  max_concurrent_uploads: 2,
  vault_idle_timeout_ms: :timer.minutes(15),
  start_infrastructure: true

config :singularity_storage,
  job_handler: Singularity.Runtime.JobDispatcher

config :singularity_storage, Singularity.Storage.RequestRepo, pool_size: 10

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
