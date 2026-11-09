defmodule Singularity.Core.Principal do
  @moduledoc "An actor evaluated by authorization."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [:principal_id, :kind, :authorization_epoch]
  defstruct [:principal_id, :kind, :authorization_epoch, metadata: %{}]

  @type t :: %__MODULE__{
          principal_id: Types.id(),
          kind: atom(),
          authorization_epoch: non_neg_integer(),
          metadata: Types.metadata()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, principal_id} <- Types.opaque_string(attrs, :principal_id),
         {:ok, kind} <- Types.atom_value(attrs, :kind),
         {:ok, authorization_epoch} <-
           Types.non_neg_integer(attrs, :authorization_epoch),
         {:ok, metadata} <- Types.metadata(attrs) do
      {:ok,
       %__MODULE__{
         principal_id: principal_id,
         kind: kind,
         authorization_epoch: authorization_epoch,
         metadata: metadata
       }}
    end
  end
end
