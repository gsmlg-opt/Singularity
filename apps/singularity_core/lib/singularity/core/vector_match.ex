defmodule Singularity.Core.VectorMatch do
  @moduledoc "A scored provider-independent vector search match."

  @enforce_keys [:point_id, :score, :payload]
  defstruct [:point_id, :score, :payload]

  @type t :: %__MODULE__{
          point_id: String.t(),
          score: float(),
          payload: %{optional(String.t()) => term()}
        }
end
