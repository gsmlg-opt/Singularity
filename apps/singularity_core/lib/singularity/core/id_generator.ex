defmodule Singularity.Core.IdGenerator do
  @moduledoc "Injectable opaque identifier generator."

  @type context :: term()

  @callback generate(context()) :: String.t()
end
