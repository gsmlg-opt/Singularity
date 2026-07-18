defmodule Singularity.Core.StageRef do
  @moduledoc "An opaque reference to a staged object."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [:stage_id]
  defstruct [:stage_id]

  @type t :: %__MODULE__{stage_id: Types.id()}

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, stage_id} <- Types.opaque_string(attrs, :stage_id) do
      {:ok, %__MODULE__{stage_id: stage_id}}
    end
  end
end
