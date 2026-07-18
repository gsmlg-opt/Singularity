defmodule Singularity.Storage.WorkerRepo do
  @moduledoc "Least-privilege repository for durable worker transactions."

  use Ecto.Repo,
    otp_app: :singularity_storage,
    adapter: Ecto.Adapters.Postgres
end
