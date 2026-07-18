defmodule Singularity.Core.Clock do
  @moduledoc "Injectable UTC clock."

  @type context :: term()

  @callback utc_now(context()) :: DateTime.t()
end
