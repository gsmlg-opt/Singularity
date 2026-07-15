defmodule Singularity.Core.EmbeddingInput do
  @moduledoc "Provider-independent text and metadata submitted for embedding."

  @enforce_keys [:input_id, :text]
  defstruct [:input_id, :text, metadata: %{}]

  @type t :: %__MODULE__{
          input_id: String.t(),
          text: String.t(),
          metadata: %{optional(String.t()) => term()}
        }
end
