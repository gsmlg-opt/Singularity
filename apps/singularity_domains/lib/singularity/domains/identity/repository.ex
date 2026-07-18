defmodule Singularity.Domains.Identity.Repository do
  @moduledoc "Persistence boundary for identity bootstrap intents."

  alias Singularity.Core.Error

  @type context :: term()
  @type bootstrap_command :: %{
          required(:idempotency_key) => String.t(),
          required(:owner) => %{required(:id) => String.t(), required(:kind) => :owner},
          required(:credential) => %{
            required(:id) => String.t(),
            required(:secret_hash) => String.t()
          }
        }
  @type bootstrap_result :: %{
          required(:owner) => map(),
          required(:credential) => map()
        }

  @callback bootstrap_owner(context(), bootstrap_command()) ::
              {:ok, bootstrap_result()} | {:error, Error.t()}
end
