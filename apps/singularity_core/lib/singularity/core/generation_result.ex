defmodule Singularity.Core.GenerationResult do
  @moduledoc """
  The completed answer whose returned citation labels map to the supplied evidence labels.
  """

  alias Singularity.Core.Citation

  @enforce_keys [:answer, :citations, :usage]
  defstruct [:answer, :citations, :usage, provider_response_id: nil]

  @type t :: %__MODULE__{
          answer: String.t(),
          citations: [Citation.t()],
          usage: %{optional(String.t()) => term()},
          provider_response_id: String.t() | nil
        }
end
