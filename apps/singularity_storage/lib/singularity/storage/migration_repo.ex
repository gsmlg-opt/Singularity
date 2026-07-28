defmodule Singularity.Storage.MigrationRepo do
  @moduledoc "Task-only repository used for database creation and migrations."

  use Ecto.Repo,
    otp_app: :singularity_storage,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def default_options(_operation), do: [telemetry_event: nil]
end
