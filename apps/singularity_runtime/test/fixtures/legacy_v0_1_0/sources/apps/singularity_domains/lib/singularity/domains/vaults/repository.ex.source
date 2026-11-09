defmodule Singularity.Domains.Vaults.Repository do
  @moduledoc "Persistence boundary for authoritative vault membership lookup."

  alias Singularity.Core.Error

  @type context :: term()
  @type lookup :: %{
          required(:principal_id) => String.t(),
          required(:vault_id) => String.t()
        }
  @type authorization :: %{
          required(:principal_id) => String.t(),
          required(:vault_id) => String.t(),
          required(:status) => atom(),
          required(:capabilities) => [String.t()],
          required(:authorization_epoch) => non_neg_integer(),
          required(:locked?) => boolean()
        }

  @callback resolve_authorization(context(), lookup()) ::
              {:ok, authorization() | nil} | {:error, Error.t()}
end
