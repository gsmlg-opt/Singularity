[
  plugins: [Phoenix.LiveView.HTMLFormatter],
  import_deps: [:ecto, :ecto_sql, :phoenix],
  inputs: [
    "{mix,.formatter}.exs",
    "build/*.exs",
    "config/*.exs",
    "apps/*/{mix,.formatter}.exs",
    "apps/*/{lib,test}/**/*.{ex,exs,heex}"
  ]
]
