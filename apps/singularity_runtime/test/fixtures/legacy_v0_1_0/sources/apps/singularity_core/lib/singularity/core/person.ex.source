defmodule Singularity.Core.Person do
  @moduledoc "A real-world person identity, separate from authentication."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [:person_id]
  defstruct [:person_id, metadata: %{}]

  @type t :: %__MODULE__{person_id: Types.id(), metadata: Types.metadata()}

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, person_id} <- Types.opaque_string(attrs, :person_id),
         {:ok, metadata} <- Types.metadata(attrs) do
      {:ok, %__MODULE__{person_id: person_id, metadata: metadata}}
    end
  end
end
