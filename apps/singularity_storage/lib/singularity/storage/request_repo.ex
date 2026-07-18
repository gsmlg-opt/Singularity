defmodule Singularity.Storage.RequestRepo do
  @moduledoc "Least-privilege repository for web request transactions."

  use Ecto.Repo,
    otp_app: :singularity_storage,
    adapter: Ecto.Adapters.Postgres
end
