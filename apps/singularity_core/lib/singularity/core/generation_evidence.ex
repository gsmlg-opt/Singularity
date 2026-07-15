defmodule Singularity.Core.GenerationEvidence do
  @moduledoc """
  A knowledge chunk supplied to generation under a unique label ordered from 1.
  """

  alias Singularity.Core.KnowledgeChunk

  @enforce_keys [:label, :chunk]
  defstruct [:label, :chunk]

  @type t :: %__MODULE__{label: pos_integer(), chunk: KnowledgeChunk.t()}
end
