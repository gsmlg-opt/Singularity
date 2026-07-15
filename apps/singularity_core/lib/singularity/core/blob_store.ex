defmodule Singularity.Core.BlobStore do
  @moduledoc "Storage contract for source binaries referenced by stable blob metadata."

  alias Singularity.Core.BlobRef
  alias Singularity.Core.Source

  @type context :: term()
  @type error :: Singularity.Core.Error.t()
  @type result(value) :: {:ok, value} | {:error, error()}

  @doc "Stores a source binary and returns its stable reference."
  @callback put(context(), binary(), Source.t()) :: result(BlobRef.t())

  @doc """
  Fetches a binary, returning `{:error, %Singularity.Core.Error{code: :not_found}}`
  when its blob identity is missing.
  """
  @callback fetch(context(), BlobRef.t()) :: result(binary())
end
