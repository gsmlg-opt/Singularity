defmodule Singularity.Core.ObjectRef do
  @moduledoc "An opaque reference to an immutable finalized object."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [:object_id]
  defstruct [:object_id]

  @type t :: %__MODULE__{object_id: Types.id()}

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, object_id} <- Types.opaque_string(attrs, :object_id) do
      {:ok, %__MODULE__{object_id: object_id}}
    end
  end
end
