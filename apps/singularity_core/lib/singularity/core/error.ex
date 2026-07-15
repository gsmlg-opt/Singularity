defmodule Singularity.Core.Error do
  @moduledoc "Stable errors returned across adapter boundaries."

  @enforce_keys [:code]
  defstruct [:code, :message, details: %{}, retryable?: false]

  @type code ::
          :not_found
          | :already_exists
          | :conflict
          | :invalid
          | :unsupported
          | :unavailable
          | :timeout

  @type t :: %__MODULE__{
          code: code(),
          message: String.t() | nil,
          details: map(),
          retryable?: boolean()
        }
end
