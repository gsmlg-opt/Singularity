defmodule Singularity.Runtime.SessionContext do
  @moduledoc "Untrusted identity and epoch hints resolved from an opaque session."

  @enforce_keys [
    :session_id,
    :principal_id,
    :vault_id,
    :expires_at,
    :authorization_epoch,
    :unlocked?
  ]
  defstruct [
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

  @type t :: %__MODULE__{
          session_id: String.t(),
          account_id: String.t() | nil,
          principal_id: String.t(),
          vault_id: String.t(),
          expires_at: DateTime.t(),
          principal_authorization_epoch: non_neg_integer() | nil,
          vault_authorization_epoch: non_neg_integer() | nil,
          authorization_epoch: non_neg_integer(),
          unlocked?: boolean()
        }

  @spec from_resolved(map(), keyword()) :: t()
  def from_resolved(resolved, options) do
    principal_authorization_epoch =
      Map.fetch!(resolved, :principal_authorization_epoch)

    vault_authorization_epoch =
      Map.fetch!(resolved, :vault_authorization_epoch)

    %__MODULE__{
      session_id: Map.fetch!(resolved, :session_id),
      account_id: Map.get(resolved, :account_id),
      principal_id: Map.fetch!(resolved, :principal_id),
      vault_id: Map.fetch!(resolved, :vault_id),
      expires_at: Map.fetch!(resolved, :expires_at),
      principal_authorization_epoch: principal_authorization_epoch,
      vault_authorization_epoch: vault_authorization_epoch,
      authorization_epoch: principal_authorization_epoch,
      unlocked?: Keyword.fetch!(options, :unlocked?)
    }
  end

  @spec unlocked(t()) :: t()
  def unlocked(%__MODULE__{} = session), do: %{session | unlocked?: true}

  @spec locked(t()) :: t()
  def locked(%__MODULE__{} = session), do: %{session | unlocked?: false}
end
