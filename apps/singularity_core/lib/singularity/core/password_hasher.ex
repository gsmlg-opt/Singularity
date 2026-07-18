defmodule Singularity.Core.PasswordHasher do
  @moduledoc "Port for password hashing and verification."

  alias Singularity.Core.Error

  @type context :: term()

  @callback hash(context(), binary()) :: {:ok, String.t()} | {:error, Error.t()}
  @callback verify(context(), binary(), String.t()) ::
              {:ok, boolean()} | {:error, Error.t()}
end
