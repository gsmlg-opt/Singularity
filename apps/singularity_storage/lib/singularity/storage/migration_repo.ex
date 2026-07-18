defmodule Singularity.Storage.MigrationRepo do
  @moduledoc "Task-only repository used for database creation and migrations."

  use Ecto.Repo,
    otp_app: :singularity_storage,
    adapter: Ecto.Adapters.Postgres
end
