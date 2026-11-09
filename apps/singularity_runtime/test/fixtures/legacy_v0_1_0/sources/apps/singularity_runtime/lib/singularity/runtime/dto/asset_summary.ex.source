defmodule Singularity.Runtime.DTO.AssetSummary do
  @moduledoc "Web-safe summary of one authorized asset."

  @fields [
    :id,
    :resource_version_id,
    :title,
    :original_filename,
    :detected_media_type,
    :state,
    :state_revision,
    :label,
    :progress,
    :failure,
    :updated_at
  ]

  @enforce_keys @fields
  defstruct @fields

  @type progress ::
          %{kind: :bytes, sent: non_neg_integer(), total: non_neg_integer()}
          | %{kind: :indeterminate | :complete | :waiting_for_unlock}
          | nil

  @type failure ::
          %{
            code: String.t(),
            retryable: boolean(),
            operation: String.t(),
            attempt: non_neg_integer()
          }
          | nil

  @type t :: %__MODULE__{
          id: String.t(),
          resource_version_id: String.t(),
          title: String.t(),
          original_filename: String.t(),
          detected_media_type: String.t() | nil,
          state: atom(),
          state_revision: non_neg_integer(),
          label: String.t(),
          progress: progress(),
          failure: failure(),
          updated_at: DateTime.t()
        }
end
