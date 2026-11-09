defmodule Singularity.Core.KeyWrapper do
  @moduledoc "Port for authenticated wrapping and unwrapping of raw key material."

  alias Singularity.Core.Error

  @type context :: term()

  @callback wrap(context(), binary(), map()) :: {:ok, map()} | {:error, Error.t()}
  @callback unwrap(context(), binary(), map()) :: {:ok, binary()} | {:error, Error.t()}
end
