defmodule Singularity.Core.KeyDeriver do
  @moduledoc "Port for deriving raw keys from passwords and versioned KDF parameters."

  alias Singularity.Core.Error

  @type context :: term()

  @callback derive(context(), binary(), map()) :: {:ok, binary()} | {:error, Error.t()}
end
