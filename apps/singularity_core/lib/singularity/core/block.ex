defmodule Singularity.Core.Block do
  @moduledoc """
  A structured block within canonical text.

  Offsets are zero-based and the end offset is exclusive.
  """

  alias Singularity.Core.Types

  @enforce_keys [:kind, :text, :start_offset, :end_offset]
  defstruct [:kind, :text, :start_offset, :end_offset, heading_path: [], metadata: %{}]

  @type kind :: :heading | :paragraph | :code | :list | :quote | :thematic_break

  @type t :: %__MODULE__{
          kind: kind(),
          text: String.t(),
          start_offset: non_neg_integer(),
          end_offset: non_neg_integer(),
          heading_path: [String.t()],
          metadata: Types.metadata()
        }
end
