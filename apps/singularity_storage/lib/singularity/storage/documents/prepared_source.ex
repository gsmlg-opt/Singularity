defmodule Singularity.Storage.Documents.PreparedSource do
  @moduledoc """
  Internal source-preparation result. This value is not an unforgeable capability.

  Consumers must invoke their own trusted preparation dependency and revalidate
  its binding in the create transaction. Live custody composition is deferred.
  """
  @enforce_keys [:source, :binding, :principal_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source: Singularity.Core.DocumentSource.t(),
          binding: map(),
          principal_id: String.t()
        }
end
