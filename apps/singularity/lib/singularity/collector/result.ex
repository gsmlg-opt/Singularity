defmodule Singularity.Collector.Result do
  @moduledoc """
  Outcome of one successful fetch. `complete: true` means the entries are the
  source's whole current list: items it no longer lists leave the source.
  """

  @enforce_keys [:period]
  defstruct [:period, entries: [], skipped: 0, complete: false]

  @type t :: %__MODULE__{
          period: String.t(),
          entries: [Singularity.Collector.Entry.t()],
          skipped: non_neg_integer(),
          complete: boolean()
        }
end
