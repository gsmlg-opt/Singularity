defmodule Singularity.Runtime.DTO.Session do
  @moduledoc "Non-secret session data exposed by the runtime facade."

  @fields [
    :session_id,
    :account_id,
    :principal_id,
    :vault_id,
    :expires_at,
    :principal_authorization_epoch,
    :vault_authorization_epoch,
    :authorization_epoch,
    :unlocked?
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          session_id: String.t(),
          account_id: String.t() | nil,
          principal_id: String.t(),
          vault_id: String.t(),
          expires_at: DateTime.t(),
          principal_authorization_epoch: non_neg_integer(),
          vault_authorization_epoch: non_neg_integer(),
          authorization_epoch: non_neg_integer(),
          unlocked?: boolean()
        }
end
