defmodule Singularity.Core.Vault do
  @moduledoc "A data ownership, policy, and encryption boundary."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [:vault_id, :authorization_epoch]
  defstruct [:vault_id, :authorization_epoch, metadata: %{}]

  @type t :: %__MODULE__{
          vault_id: Types.id(),
          authorization_epoch: non_neg_integer(),
          metadata: Types.metadata()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, vault_id} <- Types.opaque_string(attrs, :vault_id),
         {:ok, authorization_epoch} <-
           Types.non_neg_integer(attrs, :authorization_epoch),
         {:ok, metadata} <- Types.metadata(attrs) do
      {:ok,
       %__MODULE__{
         vault_id: vault_id,
         authorization_epoch: authorization_epoch,
         metadata: metadata
       }}
    end
  end
end
