defmodule Singularity.Core.AnswerRun do
  @moduledoc "A terminal answer attempt with its frozen retrieval evidence."

  alias Singularity.Core.Citation
  alias Singularity.Core.Error
  alias Singularity.Core.Retrieval
  alias Singularity.Core.Types

  @enforce_keys [
    :run_id,
    :question,
    :filters,
    :retrieval_snapshot,
    :selected_chunk_ids,
    :prompt_program_version,
    :model_route,
    :status,
    :schema_version,
    :created_at,
    :updated_at
  ]

  defstruct [
    :run_id,
    :question,
    :filters,
    :retrieval_snapshot,
    :selected_chunk_ids,
    :prompt_program_version,
    :model_route,
    :status,
    :schema_version,
    :created_at,
    :updated_at,
    kind: "answer_run",
    answer: nil,
    citations: [],
    usage: %{},
    latency_ms: nil,
    error: nil
  ]

  @type t :: %__MODULE__{
          kind: String.t(),
          run_id: Types.id(),
          question: String.t(),
          filters: Retrieval.Filters.t(),
          retrieval_snapshot: Retrieval.Result.t(),
          selected_chunk_ids: [Types.id()],
          prompt_program_version: Types.version(),
          model_route: String.t(),
          status: :complete | :failed | :insufficient_evidence,
          answer: String.t() | nil,
          citations: [Citation.t()],
          usage: %{optional(String.t()) => term()},
          latency_ms: non_neg_integer() | nil,
          error: Error.t() | nil,
          schema_version: pos_integer(),
          created_at: Types.timestamp(),
          updated_at: Types.timestamp()
        }
end
