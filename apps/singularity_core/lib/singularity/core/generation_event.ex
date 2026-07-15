defmodule Singularity.Core.GenerationEvent do
  @moduledoc "An ordered content or usage event emitted during answer generation."

  @enforce_keys [:kind, :data]
  defstruct [:kind, :data]

  @type t :: %__MODULE__{
          kind: :content | :usage,
          data: String.t() | map()
        }
end
