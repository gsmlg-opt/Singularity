defmodule Singularity.Collector.Result do
  @moduledoc "Outcome of one successful fetch."

  @enforce_keys [:period]
  defstruct [:period, entries: [], skipped: 0]

  @type t :: %__MODULE__{
          period: String.t(),
          entries: [Singularity.Collector.Entry.t()],
          skipped: non_neg_integer()
        }
end
