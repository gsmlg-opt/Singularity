defmodule Singularity.Runtime.DTO.UploadGrant do
  @moduledoc "Non-secret canonical upload grant metadata."

  @fields [
    :grant_id,
    :asset_id,
    :filename,
    :byte_size,
    :declared_media_type,
    :classification,
    :expires_at
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          grant_id: String.t(),
          asset_id: String.t(),
          filename: String.t(),
          byte_size: non_neg_integer(),
          declared_media_type: String.t(),
          classification: :private | :sensitive | :restricted,
          expires_at: DateTime.t()
        }
end
