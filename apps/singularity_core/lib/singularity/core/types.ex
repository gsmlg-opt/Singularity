defmodule Singularity.Core.Types do
  @moduledoc "Shared primitive domain types."
  @type id :: String.t()
  @type hash :: String.t()
  @type version :: String.t()
  @type timestamp :: DateTime.t()
  @type metadata :: %{optional(String.t()) => term()}
end
