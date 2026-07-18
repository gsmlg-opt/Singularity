defmodule Singularity.Core.Device do
  @moduledoc "An explicitly identified device principal."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [:device_id, :principal_id]
  defstruct [:device_id, :principal_id, metadata: %{}]

  @type t :: %__MODULE__{
          device_id: Types.id(),
          principal_id: Types.id(),
          metadata: Types.metadata()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) do
    with {:ok, attrs} <- Types.attrs(attrs),
         {:ok, device_id} <- Types.opaque_string(attrs, :device_id),
         {:ok, principal_id} <- Types.opaque_string(attrs, :principal_id),
         {:ok, metadata} <- Types.metadata(attrs) do
      {:ok, %__MODULE__{device_id: device_id, principal_id: principal_id, metadata: metadata}}
    end
  end
end
