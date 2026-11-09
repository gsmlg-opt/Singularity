defmodule Singularity.Core.Account do
  @moduledoc "An authentication identity linked to a person."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [:account_id, :person_id]
  defstruct [:account_id, :person_id, metadata: %{}]

  @type t :: %__MODULE__{
          account_id: Types.id(),
          person_id: Types.id(),
          metadata: Types.metadata()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, account_id} <- Types.opaque_string(attrs, :account_id),
         {:ok, person_id} <- Types.opaque_string(attrs, :person_id),
         {:ok, metadata} <- Types.metadata(attrs) do
      {:ok, %__MODULE__{account_id: account_id, person_id: person_id, metadata: metadata}}
    end
  end
end
