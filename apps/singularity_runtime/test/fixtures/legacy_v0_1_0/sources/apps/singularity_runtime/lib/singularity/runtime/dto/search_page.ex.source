defmodule Singularity.Runtime.DTO.SearchPage do
  @moduledoc "Web-safe bounded page of asset summaries."

  alias Singularity.Runtime.DTO.AssetSummary

  @enforce_keys [:items, :next_cursor]
  defstruct [:items, :next_cursor]

  @type t :: %__MODULE__{
          items: [AssetSummary.t()],
          next_cursor: String.t() | nil
        }
end
