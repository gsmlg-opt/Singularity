defmodule Singularity.Core.Stored do
  @moduledoc "A domain value paired with an opaque persistence version."

  @enforce_keys [:value, :version]
  defstruct [:value, :version]

  @type t(value) :: %__MODULE__{value: value, version: String.t()}
end
