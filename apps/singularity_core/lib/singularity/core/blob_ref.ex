defmodule Singularity.Core.BlobRef do
  @moduledoc "A content-addressed reference to a stored blob."

  alias Singularity.Core.Types

  @enforce_keys [:blob_id, :sha256, :byte_size]
  defstruct [:blob_id, :sha256, :byte_size, media_type: nil, original_filename: nil]

  @type t :: %__MODULE__{
          blob_id: Types.id(),
          sha256: Types.hash(),
          byte_size: non_neg_integer(),
          media_type: String.t() | nil,
          original_filename: String.t() | nil
        }
end
