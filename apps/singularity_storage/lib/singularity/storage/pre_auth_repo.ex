defmodule Singularity.Storage.PreAuthRepo do
  @moduledoc "Function-only repository for pre-authentication operations."

  use Ecto.Repo,
    otp_app: :singularity_storage,
    adapter: Ecto.Adapters.Postgres
end
