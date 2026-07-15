defmodule Singularity.Core.ProjectionState do
  @moduledoc "Tracks projection of a knowledge revision into a retrieval collection."

  alias Singularity.Core.Error
  alias Singularity.Core.Types

  @enforce_keys [
    :revision_id,
    :pipeline_version,
    :embedding_model,
    :embedding_dimensions,
    :collection_version,
    :status,
    :attempts,
    :schema_version,
    :created_at,
    :updated_at
  ]

  defstruct [
    :revision_id,
    :pipeline_version,
    :embedding_model,
    :embedding_dimensions,
    :collection_version,
    :status,
    :attempts,
    :schema_version,
    :created_at,
    :updated_at,
    kind: "projection_state",
    last_error: nil,
    indexed_at: nil
  ]

  @type t :: %__MODULE__{
          kind: String.t(),
          revision_id: Types.id(),
          pipeline_version: Types.version(),
          embedding_model: String.t(),
          embedding_dimensions: non_neg_integer(),
          collection_version: Types.version(),
          status: :pending | :processing | :ready | :failed | :stale,
          attempts: non_neg_integer(),
          last_error: Error.t() | nil,
          indexed_at: Types.timestamp() | nil,
          schema_version: pos_integer(),
          created_at: Types.timestamp(),
          updated_at: Types.timestamp()
        }
end
