defmodule Singularity.Storage.DispatcherRepo do
  @moduledoc "Function-only repository for transactional outbox dispatch."

  use Ecto.Repo,
    otp_app: :singularity_storage,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def default_options(_operation), do: [telemetry_event: nil]
end
