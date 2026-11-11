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

# Configure Mix tasks and generators
config :singularity,
  ecto_repos: [Singularity.Repo]

config :singularity, Styx,
  repo: Singularity.Repo,
  queues: [default: 5, collect: 1, details: 1],
  plugins: [
    {Styx.Pruner, max_age: 60 * 60 * 24 * 7},
    {Styx.Lifeline, rescue_after: {30, :minutes}},
    {Styx.Cron,
     crontab: [
       {"* * * * *", Singularity.Collection.ScheduleWorker},
       {"0 3 * * *", Singularity.Knowledge.PurgeWorker}
     ]}
  ]

config :singularity, :collectors, [
  Singularity.Collectors.GithubTrending,
  Singularity.Collectors.GithubStars
]

config :singularity_web,
  ecto_repos: [Singularity.Repo],
  generators: [context_app: :singularity]

config :singularity_web, SingularityWeb.Gettext, default_locale: "en"

# Configures the endpoint
config :singularity_web, SingularityWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SingularityWeb.ErrorHTML, json: SingularityWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Singularity.PubSub,
  live_view: [signing_salt: "96PO8N8z"]

# Configure duskmoon_bundler (JS via bun, CSS via tailwind v4)
singularity_root = Path.expand("..", __DIR__)
web_root = Path.join(singularity_root, "apps/singularity_web")

config :duskmoon_bundler, :singularity_web,
  entry: Path.join(web_root, "assets/js/app.js"),
  root: Path.join(web_root, "assets"),
  outdir: Path.join(web_root, "priv/static/assets"),
  resolve_dirs: Enum.map(["apps", "deps"], &Path.join(singularity_root, &1)),
  external: ~w(/fonts/* /images/*),
  sourcemap: :hidden,
  tailwind: [
    css: Path.join(web_root, "assets/css/app.css"),
    sources: [
      %{base: Path.join(web_root, "lib"), pattern: "**/*.{ex,heex}"},
      %{base: Path.join(web_root, "assets"), pattern: "**/*.{css,js,ts,jsx,tsx}"},
      %{
        base: Path.join(singularity_root, "deps/phoenix_duskmoon/lib"),
        pattern: "**/*.{ex,heex}"
      },
      %{
        base: Path.join(singularity_root, "deps/phoenix_duskmoon/assets/js"),
        pattern: "**/*.{js,ts,jsx,tsx}"
      }
    ]
  ],
  server: [
    prefix: "/assets",
    watch_dirs: [
      Path.join(web_root, "lib"),
      Path.join(web_root, "assets"),
      Path.join(singularity_root, "deps/phoenix_duskmoon/lib"),
      Path.join(singularity_root, "deps/phoenix_duskmoon/assets/js")
    ]
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"
