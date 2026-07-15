defmodule Singularity.Core.Embedding do
  @moduledoc "A provider-independent embedding result tied to its input."

  @enforce_keys [:input_id, :vector, :model]
  defstruct [:input_id, :vector, :model, usage: %{}]

  @type t :: %__MODULE__{
          input_id: String.t(),
          vector: [float()],
          model: String.t(),
          usage: %{optional(String.t()) => term()}
        }
end
