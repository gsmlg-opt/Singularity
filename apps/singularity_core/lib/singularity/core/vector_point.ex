defmodule Singularity.Core.VectorPoint do
  @moduledoc "A provider-independent vector and its indexed payload."

  @enforce_keys [:point_id, :vector, :payload]
  defstruct [:point_id, :vector, :payload]

  @type t :: %__MODULE__{
          point_id: String.t(),
          vector: [float()],
          payload: %{optional(String.t()) => term()}
        }
end
