[
  plugins: [Phoenix.LiveView.HTMLFormatter, DuskmoonBundler.Formatter],
  import_deps: [:ecto, :ecto_sql, :phoenix],
  inputs: [
    "{mix,.formatter}.exs",
    "build/*.exs",
    "config/*.exs",
    "apps/*/{mix,.formatter}.exs",
    "apps/*/{lib,test}/**/*.{ex,exs,heex}",
    "apps/singularity_web/assets/**/*.{js,ts,jsx,tsx}",
    "playwright.config.ts",
    "test/e2e/**/*.ts"
  ]
]
