defmodule Singularity.Storage.PreAuthRepo do
  @moduledoc "Function-only repository for pre-authentication operations."

  use Ecto.Repo,
    otp_app: :singularity_storage,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def default_options(_operation), do: [telemetry_event: nil]
end
