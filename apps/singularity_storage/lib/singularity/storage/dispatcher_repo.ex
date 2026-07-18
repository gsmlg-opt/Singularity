defmodule Singularity.Storage.DispatcherRepo do
  @moduledoc "Function-only repository for transactional outbox dispatch."

  use Ecto.Repo,
    otp_app: :singularity_storage,
    adapter: Ecto.Adapters.Postgres
end
