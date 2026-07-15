defmodule Singularity.Core.GenerationRequest do
  @moduledoc "A provider-independent answer-generation request with labelled evidence."

  alias Singularity.Core.GenerationEvidence

  @enforce_keys [:question, :evidence, :prompt_program_version, :model_route]
  defstruct [:question, :evidence, :prompt_program_version, :model_route, metadata: %{}]

  @type t :: %__MODULE__{
          question: String.t(),
          evidence: [GenerationEvidence.t()],
          prompt_program_version: String.t(),
          model_route: String.t(),
          metadata: %{optional(String.t()) => term()}
        }
end
