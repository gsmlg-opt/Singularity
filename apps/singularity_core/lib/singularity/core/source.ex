defmodule Singularity.Core.Source do
  @moduledoc "Describes the origin of canonical knowledge content."

  alias Singularity.Core.BlobRef
  alias Singularity.Core.Types

  @enforce_keys [:kind]
  defstruct [
    :kind,
    original_filename: nil,
    media_type: nil,
    byte_size: nil,
    sha256: nil,
    blob_ref: nil,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          kind: :note | :file,
          original_filename: String.t() | nil,
          media_type: String.t() | nil,
          byte_size: non_neg_integer() | nil,
          sha256: Types.hash() | nil,
          blob_ref: BlobRef.t() | nil,
          metadata: Types.metadata()
        }
end
