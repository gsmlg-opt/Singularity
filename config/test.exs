import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
pg_conn =
  case System.get_env("PGHOST") do
    nil -> [hostname: "localhost", username: "postgres", password: "postgres"]
    socket_dir -> [socket_dir: socket_dir, username: System.get_env("USER")]
  end

config :singularity,
       Singularity.Repo,
       pg_conn ++
         [
           database: "singularity_test#{System.get_env("MIX_TEST_PARTITION")}",
           pool: Ecto.Adapters.SQL.Sandbox,
           pool_size: System.schedulers_online() * 2
         ]

config :singularity, Styx, testing: :manual

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :singularity_web, SingularityWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "asOiqGPAz6Xq5SAL68W2n2qb33Fpg9wJTmiSNXi3+hfGxcbUevDVBu5UIAmCnGjF",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
